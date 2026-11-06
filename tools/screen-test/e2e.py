#!/usr/bin/env python3
"""End-to-end test of the Vitals Screen relay, on this Mac, against a fake Screen Sharing.

    python3 tools/screen-test/e2e.py --agent build/vitals-agent

What it does, with nothing but the Python standard library:
  1. Writes a throwaway control.json (screen on, three fake devices) in a temp folder and runs the agent
     against it with CFFIXED_USER_HOME, which NSHomeDirectory() honours (HOME alone is ignored). The
     installed agent, its launchd jobs and ~/Library/Application Support/Vitals are never touched; the
     harness checks that the real control.json/control.log did not change.
  2. Starts fake_vnc.py (RFB 3.8, security None, 640x400 Raw) and the agent by hand on spare ports,
     `serve --port 18787 --screen-port 15900 --screen-idle 8`, and stops both by their own pids.
  3. Talks to the agent over plain HTTP on 127.0.0.1 with the headers `tailscale serve` adds (Host,
     Tailscale-User-Login, X-Forwarded-For) and the ones a same-origin page sends (Origin,
     Sec-Fetch-Site, X-Vitals on POSTs), and checks Control.gate refuses each one that is wrong.
  4. Opens /screen/ws (masked client frames, 'binary' subprotocol), completes the RFB handshake through
     the relay, sends keys, pointer, cut text, fragments, pings, oversize and malformed frames, and
     checks what fake_vnc received and how the relay ends sessions.
  5. Measures input round trip through the relay (N samples, p50/p95), against a direct connection to
     fake_vnc as a baseline, and server->page throughput with pipelined full-screen updates.
  6. Tests POST /screen/clipboard/read and /write (skipped if they return 404): text, HTML, rich text,
     pictures. These use this Mac's real clipboard: all of it (every item, every type, pictures
     included) is saved first with pb.swift, compiled into the temp folder, and put back at the end;
     without swiftc, only its text (pbpaste/pbcopy). If someone copies on this Mac mid-run, their copy
     is left in place and its text is never printed.
  7. GET /screen/link (how Tailscale carries the session) against saved `tailscale status --json`
     files (--tailscale-status), and POST /screen/file (a file dropped on the page) into the throwaway
     home's Downloads, never the real one.

Results: PASS, FAIL (exit status 1), WARN (a finding against the intended behaviour, reported but not
fatal), SKIP, NOTE (measurements). --quick skips the 20 s clipboard timeout; --keep keeps the temp folder.
"""
import argparse, base64, hashlib, json, os, plistlib, queue, shutil, socket, struct, subprocess, sys, tempfile, threading, time, urllib.parse, uuid, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = "vitals-e2e.tail00000.ts.net"
LOGIN = "e2e-tester@example.com"
DEV_A, DEV_B, DEV_C = "100.64.0.9", "100.64.0.10", "100.64.0.11"     # iPhone, MacBook, iPad (fake)
REAL_DIR = os.path.expanduser("~/Library/Application Support/Vitals")

# ---------------------------------------------------------------------------------------------- results

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(("PASS" if ok else "FAIL", name, detail))
    print("  %s  %s%s" % ("PASS" if ok else "FAIL", name, ("  -- " + detail) if detail else ""), flush=True)
    return ok


def skip(name, why):
    RESULTS.append(("SKIP", name, why))
    print("  SKIP  %s  -- %s" % (name, why), flush=True)


def warn(name, ok, detail=""):
    """A finding against the intended behaviour that the relay doesn't meet yet: reported, not fatal."""
    RESULTS.append(("PASS" if ok else "WARN", name, detail))
    print("  %s  %s%s" % ("PASS" if ok else "WARN", name, ("  -- " + detail) if detail else ""), flush=True)
    return ok


def note(name, detail):
    RESULTS.append(("NOTE", name, detail))
    print("  NOTE  %s  -- %s" % (name, detail), flush=True)


def section(t):
    print("\n== " + t, flush=True)


def pct(xs, p):
    s = sorted(xs)
    return s[min(len(s) - 1, max(0, int(round(p / 100 * len(s) + 0.5)) - 1))]

# ---------------------------------------------------------------------------------------------- HTTP


class Agent:
    def __init__(self, port):
        self.port = port

    def headers(self, device=DEV_A, method="GET", **over):
        h = {"Host": HOST, "Tailscale-User-Login": LOGIN, "Tailscale-User-Name": "E2E Tester",
             "X-Forwarded-For": device, "X-Forwarded-Proto": "https", "Sec-Fetch-Site": "same-origin",
             "Origin": "https://" + HOST}
        if method == "POST":
            h["X-Vitals"] = "1"
        for k, v in over.items():
            k = k.replace("_", "-")
            if v is None:
                h.pop(k, None)
            else:
                h[k] = v
        return h

    def raw_request(self, method, path, body=b"", headers=None):
        head = "%s %s HTTP/1.1\r\n" % (method, path)
        head += "".join("%s: %s\r\n" % kv for kv in (headers or {}).items())
        if method == "POST" or body:
            head += "Content-Length: %d\r\n" % len(body)
        return head.encode() + b"\r\n" + body

    def http(self, method, path, body=b"", device=DEV_A, timeout=10, **over):
        """(status, headers, body) or (None, {}, b'') when the agent closed without answering."""
        if isinstance(body, str):
            body = body.encode()
        if path == "/screen/clipboard/write":
            OURS.add(body)
        s = socket.create_connection(("127.0.0.1", self.port), timeout=timeout)
        try:
            s.sendall(self.raw_request(method, path, body, self.headers(device, method, **over)))
            data = bytearray()
            while True:
                try:
                    c = s.recv(262144)
                except (ConnectionResetError, BrokenPipeError):
                    break
                if not c:
                    break
                data += c
        except (ConnectionResetError, BrokenPipeError):
            data = bytearray()
        finally:
            s.close()
        return parse_response(bytes(data))

    def json(self, method, path, body=b"", device=DEV_A, timeout=10, **over):
        st, h, b = self.http(method, path, body, device, timeout, **over)
        try:
            j = json.loads(b)
        except ValueError:
            return st, b
        if path == "/screen/clipboard/write" and st == 200 and isinstance(j, dict):
            MINE[0] = j.get("count")
        # Never print or keep text someone else copied on this Mac while the test ran.
        if isinstance(j, dict) and isinstance(j.get("text"), str) and j["text"].encode() not in OURS:
            j["text"] = "<%d chars copied outside this test>" % len(j["text"])
            j["foreign"] = True
        return st, j


def parse_response(data):
    if b"\r\n\r\n" not in data:
        return None, {}, data
    head, _, body = data.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    try:
        status = int(lines[0].split()[1])
    except (IndexError, ValueError):
        return None, {}, data
    h = {}
    for l in lines[1:]:
        k, _, v = l.partition(":")
        h[k.strip().lower()] = v.strip()
    if "content-length" in h:
        body = body[:int(h["content-length"])]
    return status, h, body

# ---------------------------------------------------------------------------------------------- byte streams


class Stream:
    """Bytes arriving on a background thread; read_exact blocks until they are there."""

    def __init__(self):
        self.buf = bytearray()
        self.cv = threading.Condition()
        self.eof = False
        self.total = 0

    def push(self, b):
        with self.cv:
            self.buf += b
            self.total += len(b)
            self.cv.notify_all()

    def end(self):
        with self.cv:
            self.eof = True
            self.cv.notify_all()

    def read_exact(self, n, timeout=10):
        deadline = time.monotonic() + timeout
        with self.cv:
            while len(self.buf) < n:
                if self.eof:
                    raise EOFError("stream closed after %d bytes" % self.total)
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError("waited %.1fs for %d bytes, have %d" % (timeout, n, len(self.buf)))
                self.cv.wait(left)
            out = bytes(self.buf[:n])
            del self.buf[:n]
            return out


class Direct:
    """A plain TCP connection to fake_vnc: the baseline without the relay."""

    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.stream = Stream()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            while True:
                b = self.sock.recv(262144)
                if not b:
                    break
                self.stream.push(b)
        except OSError:
            pass
        self.stream.end()

    def send(self, b):
        self.sock.sendall(b)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class WS:
    """A minimal RFC 6455 client: masked frames out, the server's binary payloads into a Stream."""

    def __init__(self, agent, device=DEV_A, protocol="binary", **over):
        self.sock = socket.create_connection(("127.0.0.1", agent.port), timeout=10)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        key = base64.b64encode(os.urandom(16)).decode()
        h = agent.headers(device, "GET", Upgrade="websocket", Connection="Upgrade", Sec_WebSocket_Version="13",
                          Sec_WebSocket_Key=key, **over)
        if protocol:
            h["Sec-WebSocket-Protocol"] = protocol
        self.sock.sendall(agent.raw_request("GET", "/screen/ws", b"", h))
        data = bytearray()
        while b"\r\n\r\n" not in data:
            c = self.sock.recv(4096)
            if not c:
                break
            data += c
        head, _, rest = bytes(data).partition(b"\r\n\r\n")
        self.status, self.headers, self.body = parse_response(bytes(data))
        if self.status != 101:
            # The rest of an error reply.
            try:
                while True:
                    c = self.sock.recv(4096)
                    if not c:
                        break
                    rest += c
            except OSError:
                pass
            self.body = rest
            self.sock.close()
            return
        want = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.accept_ok = self.headers.get("sec-websocket-accept") == want
        self.sock.settimeout(None)
        self.wlock = threading.Lock()
        self.stream = Stream()
        self.close_code = None           # from the server's close frame
        self.closed = threading.Event()  # the TCP connection ended
        self.pongs = queue.Queue()
        self.pings = 0
        self.frames = 0
        self._pending = bytearray(rest)
        threading.Thread(target=self._read, daemon=True).start()

    @property
    def ok(self):
        return self.status == 101

    def frame(self, op, payload=b"", fin=True, mask=True, length_override=None):
        n = len(payload) if length_override is None else length_override
        b0 = (0x80 if fin else 0) | op
        mbit = 0x80 if mask else 0
        if n < 126:
            head = struct.pack(">BB", b0, mbit | n)
        elif n < 65536:
            head = struct.pack(">BBH", b0, mbit | 126, n)
        else:
            head = struct.pack(">BBQ", b0, mbit | 127, n)
        if mask:
            m = os.urandom(4)
            # XOR in one go with int arithmetic: fast enough for megabytes.
            k = (m * (len(payload) // 4 + 1))[:len(payload)]
            payload = (int.from_bytes(payload, "big") ^ int.from_bytes(k, "big")).to_bytes(len(payload), "big") if payload else b""
            head += m
        return head + payload

    def send_raw(self, b):
        with self.wlock:
            self.sock.sendall(b)

    def send(self, payload):
        """One binary message: what noVNC sends for each RFB message."""
        self.send_raw(self.frame(0x2, payload))

    def _read(self):
        buf = self._pending
        try:
            def need(n):
                while len(buf) < n:
                    c = self.sock.recv(262144)
                    if not c:
                        raise EOFError
                    buf.extend(c)
            while True:
                need(2)
                b0, b1 = buf[0], buf[1]
                op, n, off = b0 & 0x0F, b1 & 0x7F, 2
                if n == 126:
                    need(4); n = struct.unpack(">H", buf[2:4])[0]; off = 4
                elif n == 127:
                    need(10); n = struct.unpack(">Q", buf[2:10])[0]; off = 10
                if b1 & 0x80:
                    raise ValueError("server sent a masked frame")
                need(off + n)
                payload = bytes(buf[off:off + n])
                del buf[:off + n]
                self.frames += 1
                if op in (0x0, 0x2):
                    self.stream.push(payload)
                elif op == 0x8:
                    self.close_code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else 1005
                elif op == 0x9:
                    self.pings += 1
                    self.send_raw(self.frame(0xA, payload))
                elif op == 0xA:
                    self.pongs.put(payload)
        except (EOFError, OSError, ValueError):
            pass
        self.stream.end()
        self.closed.set()

    def close(self, code=1000):
        try:
            self.send_raw(self.frame(0x8, struct.pack(">H", code)))
        except OSError:
            pass
        self.closed.wait(3)
        try:
            self.sock.close()
        except OSError:
            pass

    def abort(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
            self.sock.close()
        except OSError:
            pass

# ---------------------------------------------------------------------------------------------- RFB client


class RFB:
    def __init__(self, transport):
        self.t = transport
        self.cuts = queue.Queue()          # (monotonic time received, text)
        self.fcv = threading.Condition()
        self.frames_done = 0
        self.pixel_bytes = 0
        self.rects = []
        self.error = None

    def handshake(self):
        s = self.t.stream
        self.server_version = s.read_exact(12)
        self.t.send(b"RFB 003.008\n")
        n = s.read_exact(1)[0]
        self.sec_types = list(s.read_exact(n))
        self.t.send(b"\x01")
        self.sec_result = struct.unpack(">I", s.read_exact(4))[0]
        self.t.send(b"\x01")                 # shared, as noVNC asks
        w, h = struct.unpack(">HH", s.read_exact(4))
        self.pixfmt = s.read_exact(16)
        nl = struct.unpack(">I", s.read_exact(4))[0]
        self.name = s.read_exact(nl)
        self.size = (w, h)
        threading.Thread(target=self._parse, daemon=True).start()

    def _parse(self):
        s = self.t.stream
        try:
            while True:
                t = s.read_exact(1, timeout=3600)[0]
                if t == 0:
                    _, n = struct.unpack(">BH", s.read_exact(3))
                    got = 0
                    for _ in range(n):
                        x, y, w, h, enc = struct.unpack(">HHHHi", s.read_exact(12))
                        if enc != 0:
                            raise ValueError("unexpected encoding %d" % enc)
                        s.read_exact(w * h * 4, timeout=60)
                        got += w * h * 4
                        self.rects.append((x, y, w, h))
                    with self.fcv:
                        self.frames_done += 1
                        self.pixel_bytes += got
                        self.fcv.notify_all()
                elif t == 2:
                    pass                                    # Bell
                elif t == 3:
                    n = struct.unpack(">3xI", s.read_exact(7))[0]
                    text = s.read_exact(n).decode("latin-1")
                    self.cuts.put((time.monotonic(), text))
                else:
                    raise ValueError("unexpected server message %d" % t)
        except EOFError:
            pass
        except Exception as e:  # noqa: BLE001 - reported by the test that waits on it
            self.error = repr(e)

    def wait_frames(self, n, timeout=10):
        deadline = time.monotonic() + timeout
        with self.fcv:
            while self.frames_done < n:
                left = deadline - time.monotonic()
                if left <= 0:
                    return False
                self.fcv.wait(left)
        return True

    # Client messages
    @staticmethod
    def set_encodings(encs):
        return struct.pack(">BxH", 2, len(encs)) + b"".join(struct.pack(">i", e) for e in encs)

    @staticmethod
    def fbur(inc, x, y, w, h):
        return struct.pack(">BBHHHH", 3, inc, x, y, w, h)

    @staticmethod
    def key(keysym, down):
        return struct.pack(">BB2xI", 4, 1 if down else 0, keysym)

    @staticmethod
    def pointer(mask, x, y):
        return struct.pack(">BBHH", 5, mask, x, y)

    @staticmethod
    def cut(text):
        b = text.encode("latin-1")
        return struct.pack(">B3xI", 6, len(b)) + b

# ---------------------------------------------------------------------------------------------- fake_vnc control


class Fake:
    def __init__(self, port):
        self.port = port

    def call(self, method, path, body=b""):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        if isinstance(body, str):
            body = body.encode()
        s.sendall(("%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                   % (method, path, len(body))).encode() + body)
        data = bytearray()
        while True:
            c = s.recv(65536)
            if not c:
                break
            data += c
        s.close()
        return json.loads(parse_response(bytes(data))[2])

    def mark(self):
        return self.call("GET", "/events?since=999999999")["next"]

    def events(self, since, kinds=None):
        ev = self.call("GET", "/events?since=%d" % since)["events"]
        return [e for e in ev if kinds is None or e["type"] in kinds]

    def wait_events(self, since, kinds, n, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            ev = self.events(since, kinds)
            if len(ev) >= n or time.monotonic() > deadline:
                return ev
            time.sleep(0.02)

# ---------------------------------------------------------------------------------------------- setup


def port_free(p):
    s = socket.socket()
    try:
        return s.connect_ex(("127.0.0.1", p)) != 0
    finally:
        s.close()


def wait_port(p, proc, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return False
        if not port_free(p):
            return True
        time.sleep(0.05)
    return False


def real_state():
    out = {}
    for f in ("control.json", "control.log"):
        p = os.path.join(REAL_DIR, f)
        try:
            st = os.stat(p)
            out[f] = (st.st_size, st.st_mtime_ns)
        except FileNotFoundError:
            out[f] = None
    return out


OURS = set()     # every text this run put on the clipboard, so a copy made by someone else is told apart
MINE = [None]    # the clipboard's change count after this run's last write, when known


class PB:
    """pb.swift, compiled into the temp folder: the whole clipboard (pictures, rich text), not only its text."""

    def __init__(self, home):
        self.dir = home
        self.bin = os.path.join(home, "pb")
        r = subprocess.run(["swiftc", "-O", "-o", self.bin, os.path.join(HERE, "pb.swift")], capture_output=True)
        self.ok = r.returncode == 0
        self.why = r.stderr.decode("utf-8", "replace")[-200:]
        self.n = 0

    def run(self, *a):
        return subprocess.run([self.bin, *a], capture_output=True)

    def count(self):
        return int(self.run("count").stdout or -1)

    def set(self, **types):
        """pb.set(**{"public.png": b"..."}): one item with exactly these types; returns the change count."""
        args = []
        for t, v in types.items():
            self.n += 1
            f = os.path.join(self.dir, "pb-%d" % self.n)
            open(f, "wb").write(v if isinstance(v, bytes) else v.encode())
            args.append("%s=%s" % (t, f))
        c = int(self.run("set", *args).stdout)
        MINE[0] = c
        return c

    def get(self, t):
        r = self.run("get", t)
        return r.stdout if r.returncode == 0 else None


PBX = None       # a PB once built
PBX_WHY = [""]


def save_clipboard(tag):
    """This Mac's clipboard as it is now: its text, and all of it when pb is built."""
    path = None
    if PBX:
        path = os.path.join(PBX.dir, "clipboard-%s.plist" % tag)
        if PBX.run("save", path).returncode != 0:
            path = None
    return pbpaste(), path


def restore_clipboard(before, label):
    """Put the saved clipboard back, unless someone copied something else meanwhile: then leave theirs."""
    text, path = before
    cur = pbpaste()
    theirs = (PBX.count() != MINE[0]) if PBX and MINE[0] is not None else cur not in OURS
    if cur != text and theirs:
        return note(label, "someone copied on this Mac during the test (%d bytes): left that in place" % len(cur))
    if path:
        PBX.run("restore", path)
        now = os.path.join(PBX.dir, "clipboard-now.plist")
        PBX.run("save", now)
        same = plistlib.load(open(path, "rb")) == plistlib.load(open(now, "rb"))
        types = sorted({t for item in plistlib.load(open(path, "rb")) for t in item})
        return check(label + " (every type)", same and pbpaste() == text, "%d bytes of text; types %s" % (len(text), ", ".join(types)[:160] or "none"))
    pbcopy(text)
    check(label, pbpaste() == text, "%d bytes" % len(text))


def pbpaste():
    return subprocess.run(["pbpaste"], capture_output=True).stdout


def pbcopy(data):
    if isinstance(data, str):
        data = data.encode()
    OURS.add(data)
    subprocess.run(["pbcopy"], input=data, check=True)
    if PBX:
        MINE[0] = PBX.count()


def png_bytes(w=4, h=3, rgb=(200, 30, 60)):
    """A small real PNG, built by hand."""
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def png_size(d):
    return struct.unpack(">II", d[16:24]) if d and d.startswith(b"\x89PNG") else None


def converted(png, fmt, folder):
    """The PNG as another format (jpeg, tiff), through sips."""
    src, dst = os.path.join(folder, "src.png"), os.path.join(folder, "out." + fmt)
    open(src, "wb").write(png)
    subprocess.run(["sips", "-s", "format", fmt, src, "--out", dst], capture_output=True, check=True)
    return open(dst, "rb").read()

# ---------------------------------------------------------------------------------------------- tests


def test_gate(agent):
    section("Gate (Control.gate) and plain pages")
    st, cfg = agent.json("GET", "/config")
    check("agent reads the throwaway config (GET /config apps+screen true)",
          st == 200 and isinstance(cfg, dict) and cfg.get("apps") is True and cfg.get("screen") is True, str(cfg)[:120])
    st, h, b = agent.http("GET", "/screen/")
    check("GET /screen/ serves the page", st == 200 and b"<html" in b[:200] and h.get("x-frame-options") == "DENY", "status %s" % st)
    st, h, b = agent.http("GET", "/screen/info")
    check("GET /screen/info", st == 200 and b"user" in b, b[:80].decode("utf-8", "replace"))
    st, _, _ = agent.http("GET", "/screen/ws")
    check("GET /screen/ws without Upgrade -> 400", st == 400, "status %s" % st)
    cases = [
        ("wrong Host (another tailnet name)", dict(Host="other.tail00000.ts.net"), 403),
        ("Host not *.ts.net (DNS rebinding)", dict(Host="evil.example.com"), 403),
        ("wrong Tailscale-User-Login", dict(Tailscale_User_Login="someone@else.com"), 403),
        ("no Tailscale-User-Login", dict(Tailscale_User_Login=None), 403),
        ("device not on the list", dict(X_Forwarded_For="100.64.0.99"), 403),
        ("cross-site Origin", dict(Origin="https://evil.example.com"), 403),
        ("no Origin", dict(Origin=None), 403),
        ("Sec-Fetch-Site cross-site", dict(Sec_Fetch_Site="cross-site"), 403),
    ]
    for name, over, want in cases:
        ws = WS(agent, **over)
        check("WS refused: " + name, ws.status == want, "status %s" % ws.status)
        if ws.ok:
            ws.abort()
    st, _, _ = agent.http("POST", "/screen/alive", X_Vitals=None)
    check("POST without X-Vitals -> 403", st == 403, "status %s" % st)
    st, _, _ = agent.http("POST", "/screen/alive")
    check("POST /screen/alive allowed -> 204", st == 204, "status %s" % st)
    st, _, _ = agent.http("GET", "/screen/info", Sec_Fetch_Site="cross-site")
    check("GET with Sec-Fetch-Site cross-site -> 403", st == 403, "status %s" % st)


def open_session(agent, fake, device=DEV_A):
    ws = WS(agent, device)
    if not ws.ok:
        return ws, None
    r = RFB(ws)
    r.handshake()
    return ws, r


def test_relay(agent, fake):
    section("Relay: handshake, input, cut text, framing")
    m = fake.mark()
    ws = WS(agent)
    check("WS upgrade -> 101", ws.status == 101, "status %s %s" % (ws.status, ws.body[:80]))
    if not ws.ok:
        return None, None
    check("Sec-WebSocket-Accept is right", ws.accept_ok)
    check("'binary' subprotocol echoed", ws.headers.get("sec-websocket-protocol") == "binary", str(ws.headers.get("sec-websocket-protocol")))
    r = RFB(ws)
    try:
        r.handshake()
    except Exception as e:  # noqa: BLE001
        check("RFB handshake through the relay", False, repr(e))
        return ws, None
    check("RFB handshake through the relay",
          r.server_version == b"RFB 003.008\n" and r.sec_types == [1] and r.sec_result == 0 and r.size == (640, 400) and r.name == b"fake-vnc",
          "%r types=%s size=%s name=%r" % (r.server_version, r.sec_types, r.size, r.name))
    ev = fake.wait_events(m, ["ClientVersion", "SecurityType", "ClientInit"], 3)
    check("fake_vnc saw version, security None, shared ClientInit",
          [e["type"] for e in ev] == ["ClientVersion", "SecurityType", "ClientInit"] and ev[0]["version"] == "RFB 003.008"
          and ev[1]["chosen"] == 1 and ev[2]["shared"] == 1, str(ev))

    m = fake.mark()
    ws.send(RFB.set_encodings([0, -223]))
    ws.send(RFB.fbur(0, 0, 0, 640, 400))
    got = r.wait_frames(1)
    check("full-screen update arrives (640x400x4 bytes)", got and r.pixel_bytes == 640 * 400 * 4, "frames=%d bytes=%d err=%s" % (r.frames_done, r.pixel_bytes, r.error))
    ws.send(RFB.fbur(1, 0, 0, 640, 400))
    check("incremental update arrives (32x32 square)", r.wait_frames(2) and r.rects[-1][2:] == (32, 32), str(r.rects[-1:]))
    ev = fake.wait_events(m, ["SetEncodings", "FramebufferUpdateRequest"], 3)
    check("fake_vnc saw SetEncodings and both update requests",
          len(ev) == 3 and ev[0]["encodings"] == [0, -223] and ev[1]["incremental"] == 0 and ev[2]["incremental"] == 1, str(ev)[:200])

    # Keys and pointer, in order, exactly.
    m = fake.mark()
    keys = [(0x61, True), (0x61, False), (0xFF0D, True), (0xFF0D, False), (0xFFE9, True), (0x20AC, True), (0x20AC, False), (0xFFE9, False)]
    ptrs = [(0, 10, 20), (1, 10, 20), (0, 11, 21), (4, 639, 399), (0, 639, 399), (8, 300, 200), (16, 300, 200)]
    for k, d in keys:
        ws.send(RFB.key(k, d))
    for p in ptrs:
        ws.send(RFB.pointer(*p))
    ev = fake.wait_events(m, ["KeyEvent", "PointerEvent"], len(keys) + len(ptrs))
    gk = [(int(e["keysym"], 16), e["down"]) for e in ev if e["type"] == "KeyEvent"]
    gp = [(e["mask"], e["x"], e["y"]) for e in ev if e["type"] == "PointerEvent"]
    check("8 KeyEvents arrive in order (keysym + down)", gk == keys, str(gk))
    check("7 PointerEvents arrive in order (mask, x, y)", gp == ptrs, str(gp))

    # Many messages coalesced into one WS frame, as a busy page might.
    m = fake.mark()
    ws.send(b"".join(RFB.key(0x30 + i, True) for i in range(10)))
    ev = fake.wait_events(m, ["KeyEvent"], 10)
    check("10 messages in one WS frame all arrive", [int(e["keysym"], 16) for e in ev] == [0x30 + i for i in range(10)], str(len(ev)))

    # One message split over a fragmented binary message (FIN=0 then a continuation).
    m = fake.mark()
    msg = RFB.key(0x7A, True)
    ws.send_raw(ws.frame(0x2, msg[:3], fin=False) + ws.frame(0x0, msg[3:5], fin=False))
    time.sleep(0.05)
    ws.send_raw(ws.frame(0x9, b"mid") + ws.frame(0x0, msg[5:], fin=True))   # a ping between fragments is legal
    ev = fake.wait_events(m, ["KeyEvent"], 1)
    check("fragmented binary message (with a ping in between) reassembles", len(ev) == 1 and ev[0]["keysym"] == "0x7a", str(ev))
    try:
        check("pong answers the mid-fragment ping", ws.pongs.get(timeout=2) == b"mid")
    except queue.Empty:
        check("pong answers the mid-fragment ping", False, "no pong")

    try:
        while True:
            ws.pongs.get_nowait()
    except queue.Empty:
        pass
    ws.send_raw(ws.frame(0x9, b"hello-ping-125"))
    try:
        check("ping -> pong with the same payload", ws.pongs.get(timeout=2) == b"hello-ping-125")
    except queue.Empty:
        check("ping -> pong with the same payload", False, "no pong")

    # Cut text both ways.
    m = fake.mark()
    ws.send(RFB.cut("hello from the page"))
    ev = fake.wait_events(m, ["ClientCutText"], 1)
    check("ClientCutText reaches Screen Sharing", len(ev) == 1 and ev[0]["text"] == "hello from the page", str(ev)[:120])
    big = ("0123456789abcdef" * 12500)              # 200,000 bytes: a 64-bit length frame
    m = fake.mark()
    ws.send(RFB.cut(big))
    ev = fake.wait_events(m, ["ClientCutText"], 1)
    check("200 KB ClientCutText in one frame (64-bit length)", len(ev) == 1 and ev[0]["length"] == len(big) and ev[0]["text"] == big,
          str(ev[0]["length"]) if ev else "none")
    fake.call("POST", "/cut", "hello from the Mac")
    try:
        t, text = r.cuts.get(timeout=3)
        check("ServerCutText reaches the page", text == "hello from the Mac", text)
    except queue.Empty:
        check("ServerCutText reaches the page", False, "nothing")
    check("RFB stream still in sync", r.error is None, str(r.error))
    return ws, r


def measure_latency(send, rfb, fake, n):
    """Alternating key and pointer events; fake_vnc answers each with a ServerCutText ack."""
    fake.call("POST", "/echo", "on")
    m = fake.mark()
    rtt, sent = [], []
    try:
        for i in range(n):
            if i % 2 == 0:
                ks, down = 0x61 + (i // 2) % 26, (i // 2) % 2 == 0
                msg, want = RFB.key(ks, down), "ack key 0x%x %d" % (ks, down)
            else:
                x, y = (i * 7) % 640, (i * 3) % 400
                msg, want = RFB.pointer(0, x, y), "ack ptr 0 %d %d" % (x, y)
            t0 = time.monotonic()
            send(msg)
            sent.append(t0)
            while True:
                t1, text = rfb.cuts.get(timeout=5)
                if text == want:
                    break
            rtt.append((t1 - t0) * 1000)
    finally:
        fake.call("POST", "/echo", "off")
    ev = fake.wait_events(m, ["KeyEvent", "PointerEvent"], n)
    one = [(e["t"] - t0) * 1000 for e, t0 in zip(ev, sent)]
    return rtt, one


def measure_throughput(send, rfb, seconds, depth=4):
    """Full-screen non-incremental requests, `depth` outstanding at a time, for `seconds`."""
    start_frames, start_bytes = rfb.frames_done, rfb.pixel_bytes
    req = RFB.fbur(0, 0, 0, 640, 400)
    asked = 0
    for _ in range(depth):
        send(req); asked += 1
    t0 = time.monotonic()
    while time.monotonic() - t0 < seconds:
        # Wait for the oldest outstanding request, then top back up to `depth` outstanding.
        if not rfb.wait_frames(start_frames + asked - depth + 1, timeout=10):
            raise TimeoutError("update stalled")
        while asked - (rfb.frames_done - start_frames) < depth:
            send(req); asked += 1
    rfb.wait_frames(start_frames + asked, timeout=20)
    dt = time.monotonic() - t0
    frames = rfb.frames_done - start_frames
    mb = (rfb.pixel_bytes - start_bytes) / 1e6
    return mb / dt, frames / dt, mb


def test_performance(agent, fake, ws, r, args):
    section("Latency and throughput")
    rtt, one = measure_latency(ws.send, r, fake, args.samples)
    d = Direct(args.vnc_port)
    dr = RFB(d)
    dr.handshake()
    brtt, bone = measure_latency(d.send, dr, fake, args.samples)
    check("latency: %d input samples answered through the relay" % args.samples, len(rtt) == args.samples)
    fmt = "p50 %.3f ms  p95 %.3f ms  max %.3f ms"
    note("round trip via relay (page->relay->VNC->relay->page)", fmt % (pct(rtt, 50), pct(rtt, 95), max(rtt)))
    note("round trip direct to fake_vnc (baseline)", fmt % (pct(brtt, 50), pct(brtt, 95), max(brtt)))
    note("one way via relay (page send -> VNC receive)", fmt % (pct(one, 50), pct(one, 95), max(one)))
    note("one way direct (baseline)", fmt % (pct(bone, 50), pct(bone, 95), max(bone)))
    note("relay adds to the round trip", "p50 +%.3f ms, p95 +%.3f ms" % (pct(rtt, 50) - pct(brtt, 50), pct(rtt, 95) - pct(brtt, 95)))
    check("relay round trip p95 under 20 ms on loopback", pct(rtt, 95) < 20, "%.2f ms" % pct(rtt, 95))

    mbs, fps, mb = measure_throughput(ws.send, r, args.seconds)
    bmbs, bfps, _ = measure_throughput(d.send, dr, args.seconds)
    note("throughput via relay (server->page, 1 MB Raw frames)", "%.0f MB/s, %.0f frames/s (%.0f MB in %.0f s)" % (mbs, fps, mb, args.seconds))
    note("throughput direct to fake_vnc (baseline)", "%.0f MB/s, %.0f frames/s" % (bmbs, bfps))
    note("WS frames from the relay so far", "%d frames carrying %d bytes (avg %.0f KB/frame)" % (ws.frames, ws.stream.total, ws.stream.total / max(1, ws.frames) / 1024))
    check("RFB stream still in sync after the flood", r.error is None and dr.error is None, "%s %s" % (r.error, dr.error))
    d.close()


def test_sessions(agent, fake):
    section("Session limits and endings")
    extra = []
    while len(extra) < 5:
        ws = WS(agent, DEV_B)
        if not ws.ok:
            break
        extra.append(ws)
    check("at most 3 sessions: the next upgrade gets 503", len(extra) == 2 and ws.status == 503 and b"3 places" in ws.body,
          "opened %d more beside the main one, then %s %r" % (len(extra), ws.status, ws.body[:60]))
    for w in extra:
        w.close()
    time.sleep(0.3)

    # Clean close from the page: the relay echoes the close and drops Screen Sharing.
    m = fake.mark()
    ws, r = open_session(agent, fake, DEV_B)
    ev = fake.wait_events(m, ["Connect"], 1)
    cid = ev[0]["cid"] if ev else None
    ws.close(1000)
    dis = fake.wait_events(m, ["Disconnect"], 1)
    check("page close 1000: relay echoes 1000 and closes", ws.close_code == 1000 and ws.closed.is_set(), "code %s" % ws.close_code)
    check("page close: Screen Sharing connection dropped", any(e["cid"] == cid for e in dis), str(dis))

    # Page vanishes without a close frame.
    m = fake.mark()
    ws, r = open_session(agent, fake, DEV_B)
    cid = fake.wait_events(m, ["Connect"], 1)[0]["cid"]
    ws.abort()
    dis = fake.wait_events(m, ["Disconnect"], 1)
    check("page drops TCP: Screen Sharing connection dropped", any(e["cid"] == cid for e in dis), str(dis))


def test_bad_frames(agent, fake):
    section("Malformed frames end the session")
    cases = [
        ("unmasked frame", lambda ws: ws.send_raw(ws.frame(0x2, RFB.key(0x61, True), mask=False))),
        ("text frame (opcode 1)", lambda ws: ws.send_raw(ws.frame(0x1, b"hi"))),
        ("frame over 1 MiB", lambda ws: ws.send_raw(ws.frame(0x2, b"", length_override=(1 << 20) + 1))),
        ("RSV bit set", lambda ws: ws.send_raw(bytes([0xC2]) + ws.frame(0x2, b"x")[1:])),
        ("continuation with nothing to continue", lambda ws: ws.send_raw(ws.frame(0x0, b"x"))),
        ("control frame over 125 bytes", lambda ws: ws.send_raw(ws.frame(0x9, b"p" * 126))),
    ]
    for name, act in cases:
        m = fake.mark()
        ws, r = open_session(agent, fake, DEV_B)
        cid = fake.wait_events(m, ["Connect"], 1)[0]["cid"]
        act(ws)
        ended = ws.closed.wait(3)
        dis = fake.wait_events(m, ["Disconnect"], 1, timeout=3)
        check("%s -> session ends (close %s)" % (name, ws.close_code), ended and any(e["cid"] == cid for e in dis),
              "closed=%s vnc dropped=%s" % (ended, bool(dis)))
        ws.abort()


def test_vnc_drop(agent, fake):
    section("Screen Sharing goes away")
    ws, r = open_session(agent, fake, DEV_B)
    fake.call("POST", "/kick")
    ended = ws.closed.wait(3)
    check("Screen Sharing closes -> page gets close 1001", ended and ws.close_code == 1001, "code %s" % ws.close_code)
    ws.abort()


def test_idle(agent, fake, idle):
    """DEV_C opens a session and never reports a touch: the relay ends it after --screen-idle."""
    ws, r = open_session(agent, fake, DEV_C)
    t0 = time.monotonic()
    out = {}

    def wait():
        ended = ws.closed.wait(idle + 15)
        out["ended"], out["after"], out["code"] = ended, time.monotonic() - t0, ws.close_code
    th = threading.Thread(target=wait, daemon=True)
    th.start()
    return th, out


def test_clipboard(agent, fake, args):
    section("Clipboard: POST /screen/clipboard/read and /write")
    st, body = agent.json("POST", "/screen/clipboard/read", b"", DEV_B)
    if st == 404:
        skip("clipboard endpoints", "POST /screen/clipboard/read returned 404 (not merged in this build)")
        return
    # DEV_B has no session open at this point.
    check("read without a screen session -> 409", st == 409 and isinstance(body, dict) and body.get("error") == "no screen session", "%s %s" % (st, body))
    st, body = agent.json("POST", "/screen/clipboard/write", "nope", DEV_B)
    check("write without a screen session -> 409", st == 409, "%s %s" % (st, body))
    before = save_clipboard("before")
    try:
        _clipboard_tests(agent, args)
        if PBX:
            _rich_clipboard_tests(agent, args)
        else:
            skip("pictures and rich text on the clipboard", "pb.swift didn't build: " + PBX_WHY[0])
    finally:
        restore_clipboard(before, "clipboard put back as it was")


def _clipboard_tests(agent, args):
    st, body = agent.json("POST", "/screen/clipboard/read", X_Vitals=None)
    check("read without X-Vitals -> 403", st == 403, str(st))
    st, body = agent.json("POST", "/screen/clipboard/write", "x", Origin="https://evil.example.com")
    check("write from another Origin -> 403", st == 403, str(st))
    st, body = agent.json("POST", "/screen/clipboard/read")
    ok = st == 200 and isinstance(body, dict) and isinstance(body.get("count"), int) and "text" not in body
    check("read, empty body -> {count} at once, no text", ok, "%s %s" % (st, body))
    if not ok:
        return
    n = body["count"]

    text = "vitals e2e ✓ café \U0001F600 %s\nsecond line\n" % uuid.uuid4()
    st, body = agent.json("POST", "/screen/clipboard/write", text)
    check("write -> {count} changed", st == 200 and isinstance(body, dict) and body.get("count", n) != n, "%s %s" % (st, body))
    m = body.get("count") if isinstance(body, dict) else None
    check("write set this Mac's clipboard exactly (UTF-8, newlines)", pbpaste().decode("utf-8", "replace") == text, repr(pbpaste()[:60]))
    st, body = agent.json("POST", "/screen/clipboard/read")
    check("read count matches the write's count", st == 200 and body.get("count") == m, str(body))

    st, body = agent.json("POST", "/screen/clipboard/read", str(n))
    check("read with an old count -> text at once", st == 200 and body.get("text") == text and body.get("count") == m, str(body)[:120])

    # A waiting read answered by a copy on the Mac.
    res = {}

    def waiter():
        t = time.monotonic()
        res["r"] = agent.json("POST", "/screen/clipboard/read", str(m), timeout=30)
        res["t"] = time.monotonic()
        res["took"] = res["t"] - t
    th = threading.Thread(target=waiter)
    th.start()
    time.sleep(0.5)
    copied = "copied on the Mac %s" % uuid.uuid4()
    tc = time.monotonic()
    pbcopy(copied)
    th.join(25)
    st, body = res.get("r", (None, None))
    check("waiting read returns when the Mac's clipboard changes", st == 200 and isinstance(body, dict) and body.get("text") == copied and body.get("count") != m,
          str(body)[:120])
    if "t" in res:
        note("clipboard change -> waiting read answered", "%.0f ms after pbcopy returned (polls every 50 ms)" % ((res["t"] - tc) * 1000))

    # 1 MB paste.
    big = ("abcdefghijklmnop" * 65536)            # exactly 1 << 20 bytes
    t = time.monotonic()
    st, body = agent.json("POST", "/screen/clipboard/write", big, timeout=30)
    check("1 MB write accepted", st == 200 and isinstance(body, dict) and "count" in body, "%s %s (%.0f ms)" % (st, str(body)[:80], (time.monotonic() - t) * 1000))
    check("1 MB write landed on the clipboard", pbpaste() == big.encode(), "%d bytes" % len(pbpaste()))
    cb = body.get("count") if isinstance(body, dict) else 0
    st, body = agent.json("POST", "/screen/clipboard/read", str(cb - 1), timeout=30)
    check("1 MB read back as text", st == 200 and isinstance(body, dict) and body.get("text") == big, "%s len=%s skipped=%s" % (st, len(body.get("text") or "") if isinstance(body, dict) else "?", body.get("skipped") if isinstance(body, dict) else body))
    pbcopy(big + "x")
    cnow = agent.json("POST", "/screen/clipboard/read")[1].get("count", 0)
    st, body = agent.json("POST", "/screen/clipboard/read", str(cnow - 1), timeout=30)
    check("over 1 MB on the clipboard -> skipped: too big", st == 200 and body.get("skipped") == "too big" and "text" not in body, str(body)[:100])
    over = big + "y" * (128 * 1024)
    st, body = agent.json("POST", "/screen/clipboard/write", over, timeout=30)
    over_st = st
    note("write of 1 MB + 128 KB", "status %s, body %s, clipboard now %d bytes" % (st, str(body)[:60], len(pbpaste())))
    check("write over 1 MB + headroom is refused (not set)", st != 200 and len(pbpaste()) == len(big) + 1, "status %s" % st)
    over2 = big + "y" * 1000
    st, body = agent.json("POST", "/screen/clipboard/write", over2, timeout=30)
    landed = len(pbpaste())
    note("write of 1 MB + 1000 bytes (inside the read buffer's headroom)", "status %s, clipboard now %d bytes" % (st, landed))
    warn("write just over 1 MB is refused", st != 200, "status %s: accepted %d bytes" % (st, landed))
    warn("oversize write gets an HTTP error, not a dropped connection", over_st is not None, "1 MB+128 KB -> status %s" % over_st)

    # A waiting read whose page goes away: no crash, no stray reply on a reused socket.
    st, body = agent.json("POST", "/screen/clipboard/read")
    c0 = body["count"]
    socks = []
    for _ in range(5):
        s = socket.create_connection(("127.0.0.1", agent.port))
        s.sendall(agent.raw_request("POST", "/screen/clipboard/read", str(c0).encode(), agent.headers(DEV_A, "POST")))
        socks.append(s)
    time.sleep(0.3)
    for s in socks:
        s.close()
    time.sleep(0.2)
    # New connections, likely on the same socket numbers, left half-sent while the clipboard changes.
    half = []
    for _ in range(5):
        s = socket.create_connection(("127.0.0.1", agent.port), timeout=10)
        req = agent.raw_request("GET", "/config", b"", agent.headers(DEV_A))
        s.sendall(req[:20])
        half.append((s, req))
    pbcopy("changed while readers were gone %s" % uuid.uuid4())
    time.sleep(0.4)
    stray = []
    for s, req in half:
        s.sendall(req[20:])
        data = bytearray()
        while True:
            c = s.recv(65536)
            if not c:
                break
            data += c
        s.close()
        st, h, b = parse_response(bytes(data))
        if st != 200 or b'"apps"' not in b or b'"count"' in b or data.count(b"HTTP/1.1") != 1:
            stray.append(bytes(data[:120]))
    check("abandoned waiting reads: no stray reply on reused sockets", not stray, str(stray[:2]))
    check("agent still running after abandoned reads", args.agent_proc.poll() is None)
    st, body = agent.json("POST", "/screen/clipboard/read")
    check("requests after abandoned reads answer correctly", st == 200 and isinstance(body.get("count"), int), str(body))

    # A read already waiting when its device's screen closes: does it still hand over the clipboard?
    wsb, rb = open_session(agent, None, DEV_B)
    cb = agent.json("POST", "/screen/clipboard/read", b"", DEV_B)[1]["count"]
    res = {}
    th = threading.Thread(target=lambda: res.setdefault("r", agent.json("POST", "/screen/clipboard/read", str(cb), DEV_B, timeout=30)))
    th.start()
    time.sleep(0.3)
    wsb.close()
    time.sleep(0.3)
    secret = "copied after the session closed %s" % uuid.uuid4()
    pbcopy(secret)
    th.join(25)
    st, body = res.get("r", (None, None))
    if isinstance(body, dict) and body.get("foreign"):
        skip("read waiting across a session close", "the clipboard changed outside the test")
    else:
        warn("a read waiting when its session closes doesn't return what's copied after",
             not (isinstance(body, dict) and body.get("text") == secret), "%s %s" % (st, str(body)[:80]))


    if args.quick:
        skip("read timeout (~20 s)", "--quick")
        return
    st, body = agent.json("POST", "/screen/clipboard/read")
    c1 = body["count"]
    t = time.monotonic()
    st, body = agent.json("POST", "/screen/clipboard/read", str(c1), timeout=40)
    took = time.monotonic() - t
    if isinstance(body, dict) and body.get("foreign"):
        return skip("read timeout (~20 s)", "the clipboard changed outside the test after %.1f s" % took)
    check("waiting read with no change times out ~20 s with {count} only",
          st == 200 and body == {"count": c1} and 18 <= took <= 23, "%s %s after %.1f s" % (st, body, took))


def _rich_clipboard_tests(agent, args):
    """HTML, rich text and pictures, both ways: set on the clipboard with pb, read and written by the agent."""
    section("Clipboard: pictures and rich text")
    J = {"Content-Type": "application/json"}

    def write(obj, **over):
        return agent.json("POST", "/screen/clipboard/write", json.dumps(obj), timeout=30, **dict(J, **over))

    def read_after(count):
        return agent.json("POST", "/screen/clipboard/read", str(count), timeout=30)

    # Page -> Mac: text and HTML together.
    text = "rich paste %s" % uuid.uuid4()
    html = "<meta charset=utf-8><b>rich</b> paste <i>%s</i> café" % text[-8:]
    OURS.add(text.encode())
    st, body = write({"text": text, "html": html})
    check("write {text, html} -> 200 {count}", st == 200 and isinstance(body, dict) and "count" in body, "%s %s" % (st, body))
    c = body.get("count", 0) if isinstance(body, dict) else 0
    check("both on the Mac's clipboard: public.html and the plain text", PBX.get("public.html") == html.encode() and pbpaste() == text.encode(),
          repr((PBX.get("public.html") or b"")[:60]))
    st, body = read_after(c - 1)
    check("read -> text and html", st == 200 and body.get("text") == text and body.get("html") == html and "png" not in body, str(body)[:120])

    # Page -> Mac: a picture alone, then a JPEG (turned into PNG), then wrong ones.
    png = png_bytes(5, 4)
    st, body = write({"png": base64.b64encode(png).decode()})
    check("write {png} -> 200", st == 200 and "count" in body, "%s %s" % (st, body))
    check("the PNG is on the Mac's clipboard, byte for byte", PBX.get("public.png") == png, "%s bytes" % len(PBX.get("public.png") or b""))
    check("no stale text left beside the picture", PBX.get("public.utf8-plain-text") is None, repr(pbpaste()[:40]))
    st, body = read_after(body.get("count", 1) - 1)
    check("read -> the PNG back (base64), no text", st == 200 and body.get("png") and base64.b64decode(body["png"]) == png and "text" not in body and "skipped" not in body,
          str(body)[:120])
    jpg = converted(png_bytes(8, 6, (10, 120, 240)), "jpeg", args.home)
    st, body = write({"png": base64.b64encode(jpg).decode(), "text": "a caption"})
    on = PBX.get("public.png")
    check("write a JPEG -> stored as PNG, same size", st == 200 and png_size(on) == (8, 6) and pbpaste() == b"a caption", "%s %s" % (st, png_size(on)))
    OURS.add(b"a caption")
    for name, obj, want in [("png not base64 -> 400", {"png": "not base64!!"}, 400),
                            ("png that isn't a picture -> 400", {"png": base64.b64encode(b"hello, not an image").decode()}, 400),
                            ("nothing to paste {} -> 400", {}, 400),
                            ("html over 1 MB -> 413", {"text": "x", "html": "h" * ((1 << 20) + 1)}, 413),
                            ("text over 1 MB -> 413", {"text": "t" * ((1 << 20) + 1)}, 413),
                            ("a picture over 8 MB -> 413", {"png": base64.b64encode(os.urandom((8 << 20) + 1)).decode()}, 413)]:
        before = PBX.count()
        st, body = write(obj)
        check("write " + name + ", clipboard unchanged", st == want and PBX.count() == before, "%s %s" % (st, str(body)[:80]))
    st, body = agent.json("POST", "/screen/clipboard/write", json.dumps({"png": base64.b64encode(png).decode()}), timeout=10,
                          Content_Type="application/json", Origin="https://evil.example.com")
    check("rich write from another Origin -> 403", st == 403, str(st))
    st, body = agent.json("POST", "/screen/clipboard/write", json.dumps({"text": "x"}), DEV_B, Content_Type="application/json")
    check("rich write without a screen session -> 409", st == 409, str(st))

    # Mac -> page: what apps put there.
    c = PBX.set(**{"public.tiff": converted(png_bytes(7, 3), "tiff", args.home)})
    st, body = read_after(c - 1)
    check("a TIFF on the clipboard (Preview, some apps) -> read as PNG", st == 200 and png_size(base64.b64decode(body.get("png") or "")) == (7, 3), str(body)[:100])
    rtf = r"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0 plain {\b boldword} end}"
    c = PBX.set(**{"public.rtf": rtf, "public.utf8-plain-text": "plain boldword end"})
    OURS.add(b"plain boldword end")
    st, body = read_after(c - 1)
    h = (body.get("html") or "") if isinstance(body, dict) else ""
    check("rich text (RTF, from TextEdit or Notes) -> read as HTML with its bold", st == 200 and body.get("text") == "plain boldword end" and "boldword" in h and ("<b>" in h or "font-weight: bold" in h),
          h[:160].replace("\n", " "))
    icon = converted(png_bytes(16, 16), "tiff", args.home)
    copied = os.path.join(args.home, "vitals-e2e-copied-in-finder.txt")     # macOS drops a file URL to nothing
    open(copied, "w").write("a file")
    c = PBX.set(**{"public.file-url": "file://" + urllib.parse.quote(copied), "public.tiff": icon, "public.utf8-plain-text": "vitals-e2e-copied-in-finder.txt"})
    OURS.add(b"vitals-e2e-copied-in-finder.txt")
    st, body = read_after(c - 1)
    check("a file copied in Finder -> its name, not its icon as a picture", st == 200 and body.get("text") == "vitals-e2e-copied-in-finder.txt" and "png" not in body, str(body)[:100])
    c = PBX.set(**{"public.png": os.urandom((8 << 20) + 16)})
    st, body = read_after(c - 1)
    check("a picture over 8 MB -> skipped: too big", st == 200 and body.get("skipped") == "too big" and "png" not in body, str(body)[:100])
    c = PBX.set(**{"com.example.vitals-e2e": b"\x00\x01"})
    st, body = read_after(c - 1)
    check("nothing readable -> skipped: not text or a picture", st == 200 and body.get("skipped") == "not text or a picture", str(body)[:100])

    # A waiting read answered by a picture copied on the Mac (the page's Copy of an image).
    c = agent.json("POST", "/screen/clipboard/read")[1]["count"]
    res = {}
    th = threading.Thread(target=lambda: res.setdefault("r", read_after(c)))
    th.start()
    time.sleep(0.4)
    shot = png_bytes(9, 9, (1, 2, 3))
    t = time.monotonic()
    PBX.set(**{"public.png": shot})
    th.join(25)
    took = time.monotonic() - t
    st, body = res.get("r", (None, None))
    check("waiting read returns a picture copied on the Mac", st == 200 and isinstance(body, dict) and body.get("png") and base64.b64decode(body["png"]) == shot,
          "%s %s" % (st, str(body)[:80]))
    note("picture copied -> waiting read answered", "%.0f ms" % (took * 1000))


# ---------------------------------------------------------------------------------------------- how Tailscale carries it

def tailscale_fixture(devices):
    """A saved `tailscale status --json` with these peers: {address: (CurAddr, Relay, PeerRelay)}."""
    peers = {}
    for i, (addr, (cur, relay, peer_relay)) in enumerate(devices.items()):
        peers["nodekey:%d" % i] = {"DNSName": "device-%d.tail00000.ts.net." % i, "HostName": "device-%d" % i, "OS": "iOS",
                                   "Online": True, "UserID": 1, "TailscaleIPs": [addr, "fd7a:115c:a1e0::%d" % (i + 9)],
                                   "CurAddr": cur, "Relay": relay, "PeerRelay": peer_relay}
    return {"Self": {"DNSName": HOST + ".", "HostName": "vitals-e2e", "OS": "macOS", "UserID": 1, "TailscaleIPs": ["100.64.0.1"]},
            "User": {"1": {"LoginName": LOGIN}}, "Peer": peers}


def test_link(agent, args):
    section("Speed box: GET /screen/link (direct, peer relay or DERP)")
    st, body = agent.json("GET", "/screen/link")
    if st == 404:
        return skip("link", "GET /screen/link returned 404 (not in this build)")
    check("this device direct over the same network -> {via: direct, lan: true}", st == 200 and body == {"via": "direct", "lan": True}, "%s %s" % (st, body))
    st, body = agent.json("GET", "/screen/link", device=DEV_B)
    check("a device through DERP -> {via: DERP, region}", st == 200 and body == {"via": "DERP", "region": "fra"}, "%s %s" % (st, body))
    st, body = agent.json("GET", "/screen/link", device=DEV_C)
    check("a device through a peer relay -> {via: peer relay}", st == 200 and body == {"via": "peer relay"}, "%s %s" % (st, body))
    for name, over in [("device not on the list", dict(device="100.64.0.99")), ("cross-site", dict(Sec_Fetch_Site="cross-site")),
                       ("wrong account", dict(Tailscale_User_Login="someone@else.com"))]:
        st, _ = agent.json("GET", "/screen/link", **over)
        check("link refused: %s -> 403" % name, st == 403, str(st))
    # Tailscale changes its mind (a direct path found over the internet, a device gone): seen within ~5 s.
    json.dump(tailscale_fixture({DEV_A: ("[2001:db8::5]:41641", "fra", ""), DEV_B: ("", "", "")}), open(args.ts_status, "w"))
    t = time.monotonic()
    first = agent.json("GET", "/screen/link")[1]
    seen = None
    while time.monotonic() - t < 9:
        time.sleep(0.25)
        st, body = agent.json("GET", "/screen/link")
        if body == {"via": "direct", "lan": False}:
            seen = time.monotonic() - t
            break
    check("answers at once from what it knows, then sees the change within ~5 s", first == {"via": "direct", "lan": True} and seen is not None and seen < 7,
          "first %s; new answer after %s s" % (first, "%.1f" % seen if seen else "never"))
    st, body = agent.json("GET", "/screen/link", device=DEV_B)
    check("DERP with no region known -> {via: DERP}", body == {"via": "DERP"}, str(body))
    st, body = agent.json("GET", "/screen/link", device=DEV_C)
    check("a device Tailscale doesn't list -> {via: unknown}", st == 200 and body == {"via": "unknown"}, "%s %s" % (st, body))


# ---------------------------------------------------------------------------------------------- files dropped on the page

def test_upload(agent, args, real_names):
    section("Files: POST /screen/file into Downloads")
    dl = os.path.join(args.home, "Downloads")
    tag = uuid.uuid4().hex[:8]

    def post(name, data, device=DEV_A, timeout=30, **over):
        return agent.json("POST", "/screen/file?name=" + urllib.parse.quote(name, safe=""), data, device, timeout,
                          **dict({"Content-Type": "application/octet-stream"}, **over))
    st, body = post("vitals-e2e-x.txt", b"x", DEV_B)
    if st == 404:
        return skip("files", "POST /screen/file returned 404 (not in this build)")
    check("file without a screen session -> 409", st == 409, "%s %s" % (st, body))
    for name, over, want in [("no X-Vitals", dict(X_Vitals=None), 403), ("another Origin", dict(Origin="https://evil.example.com"), 403),
                             ("device not on the list", dict(device="100.64.0.99"), 403)]:
        dev = over.pop("device", DEV_A)
        st, _ = post("vitals-e2e-refused.txt", b"no", dev, **over)
        check("file refused: %s -> %d" % (name, want), st == want, str(st))
    check("nothing saved by the refused ones", not os.path.exists(os.path.join(dl, "vitals-e2e-refused.txt")))

    data = ("hello from the page %s ✓\n" % tag).encode()
    name = "vitals-e2e-%s.txt" % tag
    real_names.append(name)
    st, body = post(name, data)
    path = os.path.join(dl, name)
    check("file -> 200 {name, bytes}, saved in Downloads byte for byte", st == 200 and body == {"name": name, "bytes": str(len(data))}
          and os.path.exists(path) and open(path, "rb").read() == data, "%s %s" % (st, body))
    q = subprocess.run(["xattr", "-p", "com.apple.quarantine", path], capture_output=True, text=True).stdout.strip()
    check("marked as downloaded (com.apple.quarantine, from Vitals)", ";Vitals;" in q, q)
    st, body = post(name, b"second")
    want = "vitals-e2e-%s (1).txt" % tag
    check("same name again -> saved beside it, not over it", st == 200 and body.get("name") == want and open(path, "rb").read() == data
          and open(os.path.join(dl, want), "rb").read() == b"second", str(body))
    real_names.append(want)

    cases = [("../../vitals-e2e-%s-up.sh" % tag, "vitals-e2e-%s-up.sh" % tag),
             ("/etc/vitals-e2e-%s-abs" % tag, "vitals-e2e-%s-abs" % tag),
             ("..\\..\\vitals-e2e-%s-win.txt" % tag, "vitals-e2e-%s-win.txt" % tag),
             (".vitals-e2e-%s-hidden" % tag, "vitals-e2e-%s-hidden" % tag),
             ("vitals-e2e-%s-‮gpj.app" % tag, "vitals-e2e-%s-gpj.app" % tag),
             ("vitals-e2e-%s-ctl\x01\x7f.txt" % tag, "vitals-e2e-%s-ctl.txt" % tag),
             ("vitals-e2e-%s-meeting 10:30.txt" % tag, "vitals-e2e-%s-meeting 10-30.txt" % tag),
             ("C:\\Users\\me\\vitals-e2e-%s-pc.txt" % tag, "vitals-e2e-%s-pc.txt" % tag),
             ("", "file"), ("...", "file"),
             ("vitals-e2e-%s-" % tag + "é" * 150 + ".pdf", None)]
    for raw, want in cases:
        st, body = post(raw, b"payload")
        got = body.get("name") if isinstance(body, dict) else None
        if want is None:            # long: at most 200 bytes, the extension kept
            ok = st == 200 and got and len(got.encode()) <= 200 and got.endswith(".pdf") and got.startswith("vitals-e2e-")
        else:
            ok = st == 200 and got in (want, want.replace(".", " (1).", 1) if "." in want else want + " (1)")
        on_disk = bool(got) and os.path.exists(os.path.join(dl, got))
        check("name %r -> %r, inside Downloads" % (raw[:40], got and got[:40]), ok and on_disk and "/" not in got, "%s %s" % (st, body))
        if got:
            real_names.append(got)
    check("nothing written outside Downloads", not any(os.path.exists(os.path.join(args.home, n)) for n in ("vitals-e2e-%s-up.sh" % tag, "vitals-e2e-%s-win.txt" % tag))
          and not os.path.exists("/etc/vitals-e2e-%s-abs" % tag))

    # A link already in Downloads with that name: not followed, the file goes beside it.
    target = os.path.join(args.home, "target-%s.txt" % tag)
    open(target, "wb").write(b"untouched")
    os.symlink(target, os.path.join(dl, "vitals-e2e-%s-link.txt" % tag))
    st, body = post("vitals-e2e-%s-link.txt" % tag, b"overwrite?")
    check("a symlink in the way is not followed", st == 200 and body.get("name") == "vitals-e2e-%s-link (1).txt" % tag and open(target, "rb").read() == b"untouched", str(body))

    st, body = post("vitals-e2e-empty.txt", b"")
    check("empty file -> 400", st == 400, "%s %s" % (st, body))

    big = os.urandom(1 << 20) * 100                   # exactly 100 MB
    t = time.monotonic()
    st, body = post("vitals-e2e-%s-100mb.bin" % tag, big, timeout=120)
    took = time.monotonic() - t
    p = os.path.join(dl, "vitals-e2e-%s-100mb.bin" % tag)
    ok = st == 200 and os.path.exists(p) and os.path.getsize(p) == len(big)
    if ok:
        with open(p, "rb") as f:
            ok = hashlib.sha256(f.read()).digest() == hashlib.sha256(big).digest()
    check("100 MB file -> saved whole", ok, "%s %s in %.1f s" % (st, str(body)[:60], took))
    note("100 MB through the agent on loopback", "%.1f s (%.0f MB/s)" % (took, 100 / took if took else 0))
    st, body = post("vitals-e2e-%s-over.bin" % tag, big + b"x", timeout=120)
    check("100 MB + 1 byte -> 413 (or dropped once it says its size), not saved", st in (413, None) and not os.path.exists(os.path.join(dl, "vitals-e2e-%s-over.bin" % tag)), "%s %s" % (st, body))
    st, body = post("vitals-e2e-%s-way-over.bin" % tag, big + os.urandom(1 << 20), timeout=120)
    check("100 MB + 1 MB -> connection dropped, not saved", st in (None, 413) and not os.path.exists(os.path.join(dl, "vitals-e2e-%s-way-over.bin" % tag)), "status %s" % st)
    del big
    check("agent still running after the big files", args.agent_proc.poll() is None)

    # A big body from a device that may not send one is refused when its headers arrive, not held.
    def early(device, length, **over):
        s = socket.create_connection(("127.0.0.1", agent.port), timeout=10)
        hdr = agent.headers(device, "POST", **over)
        req = agent.raw_request("POST", "/screen/file?name=vitals-e2e-early.bin", b"", hdr).replace(b"Content-Length: 0", b"Content-Length: %d" % length)
        t = time.monotonic()
        data = bytearray()
        try:
            s.sendall(req + b"z" * (1 << 20))
            s.settimeout(5)
            while True:
                c = s.recv(65536)
                if not c:
                    break
                data += c
        except OSError:
            pass
        finally:
            s.close()
        return parse_response(bytes(data))[0], time.monotonic() - t
    for who, dev, over in [("a device not on the list", "100.64.0.99", {}), ("no X-Vitals", DEV_A, dict(X_Vitals=None)),
                           ("another Origin", DEV_A, dict(Origin="https://evil.example.com"))]:
        st, took = early(dev, 50 << 20, **over)
        check("50 MB upload, %s: refused after 1 MB, not held for the rest" % who, st in (403, None) and took < 3, "status %s after %.1f s" % (st, took))
    st, took = early(DEV_A, (100 << 20) + 1)
    check("an upload that says it is over 100 MB: refused at once", st in (413, None) and took < 3, "status %s after %.1f s" % (st, took))
    check("none of them saved", not os.path.exists(os.path.join(dl, "vitals-e2e-early.bin")))

    # A file arriving slowly (a phone on a poor link) is kept; a request that stops sending is dropped.
    def trickle(n, gap):
        s = socket.create_connection(("127.0.0.1", agent.port), timeout=40)
        hdr = agent.headers(DEV_A, "POST")
        hdr["Content-Type"] = "application/octet-stream"
        req = agent.raw_request("POST", "/screen/file?name=vitals-e2e-%s-slow.txt" % tag, b"s" * n, hdr)
        head = req[:len(req) - n]
        s.sendall(head)
        try:
            for _ in range(n):
                time.sleep(gap)
                s.sendall(b"s")
            return parse_response(s.recv(65536))[0]
        except OSError:
            return None
        finally:
            s.close()
    res = {}
    th = threading.Thread(target=lambda: res.setdefault("slow", trickle(7, 2.0)))
    th2 = threading.Thread(target=lambda: res.setdefault("stalled", trickle(1, 16.0)))
    th.start(); th2.start()
    th.join(40); th2.join(40)
    check("a file still arriving after 14 s is kept (a byte every 2 s)", res.get("slow") == 200, str(res.get("slow")))
    real_names.append("vitals-e2e-%s-slow.txt" % tag)
    check("a request that sends nothing for 16 s is dropped", res.get("stalled") is None, str(res.get("stalled")))

    log = read_agent_log(args.home)
    check("activity log: one line per saved file, with its name and the device",
          any("Received %s (" % name in l and "from iPhone, saved to Downloads" in l for l in log), str([l for l in log if "Received" in l][:1]))
    real_names.extend([n for n in os.listdir(dl) if n.startswith("vitals-e2e-")])


def test_slow_reader(agent, fake):
    """A page that stops reading a 1 MB clipboard reply. Replies are written on the main queue, so this
    runs last, on its own session: a stall there can also hold up every other page."""
    section("A page that stops reading a big reply")
    if agent.json("POST", "/screen/clipboard/read")[0] == 404:
        return skip("slow reader", "no clipboard endpoints")
    before = save_clipboard("slow")
    ws, r = open_session(agent, fake, DEV_B)
    try:
        big = "abcdefghijklmnop" * 65536
        pbcopy(big)
        cnow = agent.json("POST", "/screen/clipboard/read", b"", DEV_B)[1]["count"]
        slow = socket.socket()
        slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        slow.connect(("127.0.0.1", agent.port))
        slow.sendall(agent.raw_request("POST", "/screen/clipboard/read", str(cnow - 1).encode(), agent.headers(DEV_B, "POST")))
        time.sleep(0.2)
        t = time.monotonic()
        st, _, _ = agent.http("GET", "/config", timeout=30)
        stall = time.monotonic() - t
        slow.close()
        note("GET /config while another page doesn't read its 1 MB reply", "status %s after %.2f s" % (st, stall))
        warn("a page that stops reading doesn't stall the agent (< 0.5 s)", st == 200 and stall < 0.5, "%.2f s" % stall)
    finally:
        ws.close()
        restore_clipboard(before, "clipboard put back as it was after the slow-reader probe")


def test_clipboard_sessionless_after(agent):
    st, body = agent.json("POST", "/screen/clipboard/read", b"", DEV_C)
    if st == 404:
        return
    check("read after that device's session ended -> 409", st == 409, "%s %s" % (st, body))


def read_agent_log(home):
    p = os.path.join(home, "Library/Application Support/Vitals/control.log")
    try:
        return open(p).read().splitlines()
    except FileNotFoundError:
        return []

# ---------------------------------------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--agent", default="build/vitals-agent", help="the built agent (default build/vitals-agent)")
    ap.add_argument("--port", type=int, default=18787, help="agent port (default 18787)")
    ap.add_argument("--vnc-port", type=int, default=15900, help="fake_vnc RFB port (default 15900)")
    ap.add_argument("--control-port", type=int, default=15901, help="fake_vnc control port (default 15901)")
    ap.add_argument("--samples", type=int, default=200, help="latency samples (default 200)")
    ap.add_argument("--seconds", type=float, default=3, help="throughput run length (default 3)")
    ap.add_argument("--idle", type=float, default=8, help="--screen-idle for the agent (default 8, min 5)")
    ap.add_argument("--quick", action="store_true", help="skip the 20 s clipboard timeout")
    ap.add_argument("--no-clipboard", action="store_true", help="skip the tests that use this Mac's clipboard")
    ap.add_argument("--keep", action="store_true", help="keep the temp folder (config, logs)")
    args = ap.parse_args()

    agent_bin = os.path.abspath(args.agent)
    if not os.access(agent_bin, os.X_OK):
        sys.exit("no agent at %s: run ./build.sh first" % agent_bin)
    for p in (args.port, args.vnc_port, args.control_port):
        if not port_free(p):
            sys.exit("port %d is in use: pick others with --port/--vnc-port/--control-port" % p)

    real_before = real_state()
    home = tempfile.mkdtemp(prefix="vitals-e2e-")
    sup = os.path.join(home, "Library/Application Support/Vitals")
    os.makedirs(sup)
    cfg = {"login": LOGIN, "host": HOST, "devices": {DEV_A: "iPhone", DEV_B: "MacBook", DEV_C: "iPad"}, "screen": True}
    fd = os.open(os.path.join(sup, "control.json"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, json.dumps(cfg).encode())
    os.close(fd)
    print("throwaway home: %s" % home)
    global PBX
    if not args.no_clipboard:
        pb = PB(home)
        PBX, PBX_WHY[0] = (pb if pb.ok else None), pb.why
    # How Tailscale reaches each fake device, as `tailscale status --json` would say (GET /screen/link).
    args.home, args.ts_status = home, os.path.join(home, "tailscale-status.json")
    json.dump(tailscale_fixture({DEV_A: ("192.168.1.20:41641", "fra", ""), DEV_B: ("", "fra", ""), DEV_C: ("", "fra", "100.64.0.50:7000")}),
              open(args.ts_status, "w"))
    real_dl = os.path.expanduser("~/Downloads")
    real_names = []

    fake_proc = agent_proc = None
    t_start = time.monotonic()
    try:
        fake_log = open(os.path.join(home, "fake_vnc.out"), "w")
        fake_proc = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_vnc.py"), "--port", str(args.vnc_port),
                                      "--control", str(args.control_port), "--log", os.path.join(home, "fake_vnc.jsonl")],
                                     stdout=fake_log, stderr=subprocess.STDOUT)
        if not wait_port(args.control_port, fake_proc) or not wait_port(args.vnc_port, fake_proc):
            sys.exit("fake_vnc did not start; see %s/fake_vnc.out" % home)
        env = dict(os.environ, CFFIXED_USER_HOME=home, HOME=home)
        agent_log = open(os.path.join(home, "agent.out"), "w")
        agent_proc = subprocess.Popen([agent_bin, "serve", "--port", str(args.port), "--screen-port", str(args.vnc_port),
                                       "--screen-idle", str(args.idle), "--tailscale-status", args.ts_status], env=env, stdout=agent_log, stderr=subprocess.STDOUT)
        args.agent_proc = agent_proc
        print("fake_vnc pid %d on %d (control %d); agent pid %d on %d" % (fake_proc.pid, args.vnc_port, args.control_port, agent_proc.pid, args.port))
        if not wait_port(args.port, agent_proc):
            sys.exit("agent did not start; see %s/agent.out" % home)
        agent, fake = Agent(args.port), Fake(args.control_port)

        test_gate(agent)
        if not args.no_clipboard:
            st, body = agent.json("POST", "/screen/clipboard/read")
            if st != 404:
                check("clipboard read before any session (this device) -> 409", st == 409, "%s %s" % (st, body))
        ws, r = test_relay(agent, fake)
        if r is None:
            return 1

        # The main session reports a touch every 2 s, as the page does, so --screen-idle doesn't end it.
        stop = threading.Event()

        def keepalive():
            while not stop.wait(2):
                agent.http("POST", "/screen/alive")
        threading.Thread(target=keepalive, daemon=True).start()

        test_sessions(agent, fake)
        test_bad_frames(agent, fake)
        idle_thread, idle = test_idle(agent, fake, args.idle)
        t_idle = time.monotonic()
        test_performance(agent, fake, ws, r, args)
        test_link(agent, args)
        test_upload(agent, args, real_names)
        if args.no_clipboard:
            skip("clipboard", "--no-clipboard")
        else:
            test_clipboard(agent, fake, args)

        section("Idle limit, keepalive, and the end")
        idle_thread.join(max(0, args.idle + 16 - (time.monotonic() - t_idle)))
        check("session with no touches ends after --screen-idle %g s (close 1001)" % args.idle,
              idle.get("ended") and idle.get("code") == 1001 and args.idle <= idle["after"] <= args.idle + 7,
              "ended=%s after %.1f s code %s" % (idle.get("ended"), idle.get("after", -1), idle.get("code")))
        if not args.no_clipboard:
            test_clipboard_sessionless_after(agent)
        check("main session kept open by /screen/alive (%.0f s, past the idle limit)" % (time.monotonic() - t_start),
              not ws.closed.is_set() and r.error is None, "closed=%s err=%s" % (ws.closed.is_set(), r.error))
        note("server pings answered on the main session", str(ws.pings))
        test_vnc_drop(agent, fake)       # also ends the main session (kicks every VNC client)
        ws.closed.wait(3)
        check("main session ended by Screen Sharing going away -> 1001", ws.close_code == 1001, str(ws.close_code))
        stop.set()
        time.sleep(0.5)
        log = read_agent_log(home)
        opened = sum("\tScreen opened from" in l for l in log)
        closed = [l.split("\t", 2)[2] for l in log if "\tScreen closed from" in l]
        check("control.log (throwaway) records each session open and close", opened > 0 and opened == len(closed), "%d opened, %d closed" % (opened, len(closed)))
        mains = [c for c in closed if "iPhone" in c]
        if mains:
            note("agent's own record of the main session", mains[-1])
        refused = sum("\trefused\t" in l for l in log)
        note("refusals logged (once per address+reason per 10 min)", str(refused))
        if not args.no_clipboard:
            test_slow_reader(agent, fake)
        check("agent still running", agent_proc.poll() is None)
        return 0
    except Exception:  # noqa: BLE001 - a harness error is a failure, with its traceback
        import traceback
        traceback.print_exc()
        check("harness ran to the end", False, "exception above")
        return 1
    finally:
        for name, p in (("agent", agent_proc), ("fake_vnc", fake_proc)):
            if p and p.poll() is None:
                p.terminate()
                try:
                    p.wait(5)
                except subprocess.TimeoutExpired:
                    p.kill(); p.wait(5)
        real_after = real_state()
        check("installed agent's real control.json/control.log untouched", real_before == real_after, "%s -> %s" % (real_before, real_after))
        if real_names:
            landed = [n for n in set(real_names) if os.path.exists(os.path.join(real_dl, n))]
            check("nothing landed in the real ~/Downloads", not landed, str(landed[:3]))
        if args.keep:
            print("kept %s" % home)
        else:
            shutil.rmtree(home, ignore_errors=True)
        counts = {k: sum(1 for r in RESULTS if r[0] == k) for k in ("PASS", "FAIL", "WARN", "SKIP")}
        print("\n%d passed, %d failed, %d warnings (findings), %d skipped in %.0f s"
              % (counts["PASS"], counts["FAIL"], counts["WARN"], counts["SKIP"], time.monotonic() - t_start))
        for st, name, detail in RESULTS:
            if st in ("FAIL", "WARN"):
                print("  %s  %s  -- %s" % (st, name, detail))
        sys.stdout.flush()
        if counts["FAIL"]:
            os._exit(1)


if __name__ == "__main__":
    sys.exit(main())
