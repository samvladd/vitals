#!/usr/bin/env python3
"""A stand-in for macOS Screen Sharing: a small RFB 3.8 server for testing the Vitals Screen relay.

Security type None, a 640x400 32bpp framebuffer, Raw encoding only. Every client message is logged as a
JSON line with a time.monotonic() timestamp (system-wide on macOS, so another process can compare it).

    python3 fake_vnc.py --port 15900 --control 15901 --log events.jsonl

Control port (HTTP on 127.0.0.1, for the test harness):
    GET  /events?since=N   -> {"next": M, "events": [...]}   events logged since index N
    GET  /stats            -> connections, bytes sent/received
    POST /cut              body = text: ServerCutText to every connected client (latin-1, as RFB says)
    POST /echo             body = "on"/"off": answer each KeyEvent/PointerEvent with a ServerCutText
                           "ack key <keysym> <down>" / "ack ptr <mask> <x> <y>" (round-trip latency)
    POST /kick             close every client connection (Screen Sharing going away)
    POST /quit             stop the server
"""
import argparse, json, socket, struct, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

W, H = 640, 400
NAME = b"fake-vnc"
# 32 bpp, depth 24, little-endian, true colour, 8 bits per channel, red at bit 16.
PIXFMT = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)


class Hub:
    def __init__(self, log_path):
        self.lock = threading.Lock()
        self.events = []
        self.clients = set()
        self.echo = False
        self.conns = 0
        self.sent = 0
        self.received = 0
        self.log = open(log_path, "a", buffering=1) if log_path else None

    def record(self, kind, **kw):
        e = {"t": time.monotonic(), "type": kind, **kw}
        with self.lock:
            e["i"] = len(self.events)
            self.events.append(e)
            if self.log:
                self.log.write(json.dumps(e) + "\n")
        return e


class Client:
    def __init__(self, hub, sock, cid):
        self.hub, self.sock, self.cid = hub, sock, cid
        self.wlock = threading.Lock()
        self.frame = 0
        self.alive = True
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def send(self, data):
        with self.wlock:
            if not self.alive:
                return False
            try:
                self.sock.sendall(data)
            except OSError:
                self.alive = False
                return False
        with self.hub.lock:
            self.hub.sent += len(data)
        return True

    def recv_exact(self, n):
        b = bytearray()
        while len(b) < n:
            chunk = self.sock.recv(n - len(b))
            if not chunk:
                raise EOFError
            b += chunk
        with self.hub.lock:
            self.hub.received += n
        return bytes(b)

    def cut_text(self, text):
        data = text.encode("latin-1", "replace")
        return self.send(struct.pack(">B3xI", 3, len(data)) + data)

    def update(self, x, y, w, h):
        """One FramebufferUpdate, Raw, with a picture that changes each frame."""
        self.frame += 1
        shade = (self.frame * 37) & 0xFF
        px = struct.pack("<I", (shade << 16) | ((255 - shade) << 8) | (self.frame & 0xFF))
        body = px * (w * h)
        self.send(struct.pack(">BxH", 0, 1) + struct.pack(">HHHHi", x, y, w, h, 0) + body)

    def run(self):
        hub = self.hub
        try:
            self.send(b"RFB 003.008\n")
            ver = self.recv_exact(12)
            hub.record("ClientVersion", cid=self.cid, version=ver.decode("ascii", "replace").strip())
            self.send(bytes([1, 1]))                      # one security type: None
            st = self.recv_exact(1)[0]
            hub.record("SecurityType", cid=self.cid, chosen=st)
            if st != 1:
                self.send(struct.pack(">I", 1) + struct.pack(">I", 11) + b"unsupported")
                return
            self.send(struct.pack(">I", 0))               # SecurityResult OK
            shared = self.recv_exact(1)[0]
            hub.record("ClientInit", cid=self.cid, shared=shared)
            self.send(struct.pack(">HH", W, H) + PIXFMT + struct.pack(">I", len(NAME)) + NAME)
            while True:
                t = self.recv_exact(1)[0]
                now = time.monotonic()
                if t == 0:
                    self.recv_exact(3); pf = self.recv_exact(16)
                    hub.record("SetPixelFormat", cid=self.cid, t=now, bpp=pf[0])
                elif t == 2:
                    (n,) = struct.unpack(">xH", self.recv_exact(3))
                    encs = list(struct.unpack(">%di" % n, self.recv_exact(4 * n))) if n else []
                    hub.record("SetEncodings", cid=self.cid, t=now, encodings=encs)
                elif t == 3:
                    inc, x, y, w, h = struct.unpack(">BHHHH", self.recv_exact(9))
                    hub.record("FramebufferUpdateRequest", cid=self.cid, t=now, incremental=inc, x=x, y=y, w=w, h=h)
                    x, y = min(x, W - 1), min(y, H - 1)
                    w, h = max(1, min(w, W - x)), max(1, min(h, H - y))
                    if inc:
                        # Something changed: a 32x32 square that walks across the screen.
                        sx = (self.frame * 32) % (W - 32)
                        threading.Timer(0.02, self.update, (sx, 0, 32, 32)).start()
                    else:
                        self.update(x, y, w, h)
                elif t == 4:
                    down, keysym = struct.unpack(">B2xI", self.recv_exact(7))
                    hub.record("KeyEvent", cid=self.cid, t=now, keysym="0x%x" % keysym, down=bool(down))
                    if hub.echo:
                        self.cut_text("ack key 0x%x %d" % (keysym, down))
                elif t == 5:
                    mask, x, y = struct.unpack(">BHH", self.recv_exact(5))
                    hub.record("PointerEvent", cid=self.cid, t=now, mask=mask, x=x, y=y)
                    if hub.echo:
                        self.cut_text("ack ptr %d %d %d" % (mask, x, y))
                elif t == 6:
                    (n,) = struct.unpack(">3xi", self.recv_exact(7))
                    data = self.recv_exact(abs(n))
                    hub.record("ClientCutText", cid=self.cid, t=now, length=len(data), text=data.decode("latin-1"))
                else:
                    hub.record("Unknown", cid=self.cid, t=now, msgtype=t)
                    return
        except (EOFError, OSError):
            pass
        finally:
            self.alive = False
            with hub.lock:
                hub.clients.discard(self)
            try:
                self.sock.close()
            except OSError:
                pass
            hub.record("Disconnect", cid=self.cid)


def listen(port):
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", port))
    ls.listen(16)
    return ls


def serve_rfb(hub, ls):
    while True:
        s, _ = ls.accept()
        with hub.lock:
            hub.conns += 1
            cid = hub.conns
        c = Client(hub, s, cid)
        with hub.lock:
            hub.clients.add(c)
        hub.record("Connect", cid=cid)
        threading.Thread(target=c.run, daemon=True).start()


def control_handler(hub):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, obj, code=200):
            b = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            if self.path.startswith("/events"):
                since = int(self.path.partition("since=")[2] or 0)
                with hub.lock:
                    ev = hub.events[since:]
                    nxt = len(hub.events)
                self.reply({"next": nxt, "events": ev})
            elif self.path == "/stats":
                with hub.lock:
                    self.reply({"connections": hub.conns, "open": len(hub.clients), "sent": hub.sent, "received": hub.received})
            else:
                self.reply({"error": "not found"}, 404)

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode("utf-8")
            with hub.lock:
                clients = list(hub.clients)
            if self.path == "/cut":
                t = time.monotonic()
                n = sum(c.cut_text(body) for c in clients)
                hub.record("ServerCutText", t=t, text=body, clients=n)
                self.reply({"sent": n})
            elif self.path == "/echo":
                hub.echo = body.strip() == "on"
                self.reply({"echo": hub.echo})
            elif self.path == "/kick":
                for c in clients:
                    try:
                        c.sock.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                self.reply({"kicked": len(clients)})
            elif self.path == "/quit":
                self.reply({"bye": True})
                threading.Thread(target=self.server.shutdown).start()
            else:
                self.reply({"error": "not found"}, 404)
    return H


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=15900)
    ap.add_argument("--control", type=int, default=15901)
    ap.add_argument("--log", default=None, help="append JSON lines here")
    a = ap.parse_args()
    hub = Hub(a.log)
    threading.Thread(target=serve_rfb, args=(hub, listen(a.port)), daemon=True).start()
    httpd = ThreadingHTTPServer(("127.0.0.1", a.control), control_handler(hub))
    print("fake_vnc listening on 127.0.0.1:%d, control on 127.0.0.1:%d" % (a.port, a.control), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
