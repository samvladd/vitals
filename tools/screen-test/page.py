#!/usr/bin/env python3
"""The Screen page in a browser on this Mac, against a throwaway agent and the stand-in Screen Sharing.

    python3 tools/screen-test/page.py --agent build/vitals-agent      then open http://localhost:18788/screen/

Starts fake_vnc.py and the agent (throwaway control.json in a temp folder, CFFIXED_USER_HOME, so the
installed agent and its files are never touched; files dropped on the page land in that folder's
Downloads), and a small proxy on localhost that adds what `tailscale serve` would: this Mac's tailnet
name as Host (and as Origin, for the page's own requests), the Tailscale account and a device address.
Everything else passes through unchanged, WebSocket included. Ctrl-C stops all three.

--via direct|lan|derp|peer sets what the speed box is told about the path (a saved `tailscale status`).
"""
import argparse, json, os, socket, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from e2e import HOST, LOGIN, DEV_A, DEV_B, DEV_C, tailscale_fixture, wait_port  # noqa: E402

PATHS = {"lan": ("192.168.1.20:41641", "fra", ""), "direct": ("203.0.113.7:41641", "fra", ""),
         "derp": ("", "fra", ""), "peer": ("", "fra", "100.64.0.50:7000")}


def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


AGENT = {}       # the running agent, started again when it leaves (it exits a minute after the last page)
LOCK = threading.Lock()


def start_agent():
    a = AGENT["args"]
    AGENT["proc"] = subprocess.Popen([os.path.abspath(a.agent), "serve", "--port", str(a.port), "--screen-port", str(a.vnc_port),
                                      "--tailscale-status", AGENT["status"]], env=dict(os.environ, CFFIXED_USER_HOME=AGENT["home"], HOME=AGENT["home"]),
                                     stdout=open(os.path.join(AGENT["home"], "agent.out"), "a"), stderr=subprocess.STDOUT)
    return wait_port(a.port, AGENT["proc"])


def handle(client, agent_port):
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = client.recv(65536)
        if not d:
            return client.close()
        buf += d
    head, rest = buf.split(b"\r\n\r\n", 1)
    lines = head.decode("latin-1").split("\r\n")
    out = [lines[0]]
    for l in lines[1:]:
        k = l.split(":", 1)[0].strip().lower()
        if k in ("host", "origin", "tailscale-user-login", "tailscale-user-name", "x-forwarded-for"):
            if k == "origin":
                out.append("Origin: https://" + HOST)
            continue
        out.append(l)
    out += ["Host: " + HOST, "Tailscale-User-Login: " + LOGIN, "Tailscale-User-Name: Page Tester", "X-Forwarded-For: " + DEV_A]
    with LOCK:
        if AGENT["proc"].poll() is not None:
            start_agent()
    up = socket.create_connection(("127.0.0.1", agent_port))
    up.sendall(("\r\n".join(out) + "\r\n\r\n").encode("latin-1") + rest)
    threading.Thread(target=pipe, args=(client, up), daemon=True).start()
    pipe(up, client)
    client.close(); up.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--agent", default="build/vitals-agent")
    ap.add_argument("--listen", type=int, default=18788, help="the page, on localhost (default 18788)")
    ap.add_argument("--port", type=int, default=18797, help="the agent (default 18797)")
    ap.add_argument("--vnc-port", type=int, default=15910)
    ap.add_argument("--control-port", type=int, default=15911)
    ap.add_argument("--via", choices=sorted(PATHS), default="lan")
    args = ap.parse_args()

    home = tempfile.mkdtemp(prefix="vitals-page-")
    sup = os.path.join(home, "Library/Application Support/Vitals")
    os.makedirs(sup)
    json.dump({"login": LOGIN, "host": HOST, "devices": {DEV_A: "iPhone", DEV_B: "MacBook", DEV_C: "iPad"}, "screen": True},
              open(os.path.join(sup, "control.json"), "w"))
    status = os.path.join(home, "tailscale-status.json")
    json.dump(tailscale_fixture({DEV_A: PATHS[args.via]}), open(status, "w"))
    fake = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_vnc.py"), "--port", str(args.vnc_port), "--control", str(args.control_port)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    AGENT.update(args=args, home=home, status=status)
    try:
        if not wait_port(args.vnc_port, fake) or not start_agent():
            sys.exit("fake_vnc or the agent did not start; see %s" % home)
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", args.listen))
        srv.listen(64)
        print("home %s\nagent pid %d, fake_vnc pid %d\nopen http://localhost:%d/screen/" % (home, AGENT["proc"].pid, fake.pid, args.listen), flush=True)
        while True:
            c, _ = srv.accept()
            threading.Thread(target=handle, args=(c, args.port), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        for p in (AGENT.get("proc"), fake):
            if not p:
                continue
            p.terminate()
            try:
                p.wait(5)
            except subprocess.TimeoutExpired:
                p.kill()


if __name__ == "__main__":
    main()
