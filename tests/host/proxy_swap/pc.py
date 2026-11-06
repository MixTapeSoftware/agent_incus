#!/usr/bin/env python3
"""Test client for the proxy prototype: CONNECT through the proxy to an echo server.
Each tunnel starts with a ClientHello for its host, as a TLS client's does."""
import os, socket, ssl, sys, time

PROXY = ("127.0.0.1", int(os.environ.get("PROXY_PORT", "4750")))
ECHO_PORT = 4760

def client_hello(name):
    """The first TLS record a client sends for name."""
    out = ssl.MemoryBIO()
    tls = ssl.create_default_context().wrap_bio(ssl.MemoryBIO(), out, server_hostname=name)
    try:
        tls.do_handshake()
    except ssl.SSLWantReadError:
        pass
    return out.read()

def echoed(s, sent):
    """True when the echo server sends back what was sent, before the tunnel closes."""
    got = b""
    while len(got) < len(sent):
        d = s.recv(65536)
        if not d:
            return False
        got += d
    return got == sent

def tunnel(host, timeout=5, hello=True):
    s = socket.create_connection(PROXY, timeout=timeout)
    s.sendall(f"CONNECT {host}:{ECHO_PORT} HTTP/1.1\r\nHost: {host}:{ECHO_PORT}\r\n\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d:
            raise ConnectionError("closed during CONNECT")
        buf += d
    code = int(buf.split(b" ", 2)[1])
    # The proxy's TLS name check passes a tunnel on only after a ClientHello
    # for its host; the echo server sends it back.
    if code == 200 and hello:
        h = client_hello(host)
        s.sendall(h)
        if not echoed(s, h):
            raise ConnectionError("closed after the ClientHello")
    return s, code

def first(host, name):
    """A tunnel for host whose first bytes name another host, or aren't TLS
    (name "-"): ok when they come back, closed when the proxy ends it."""
    try:
        s, code = tunnel(host, hello=False)
        if code != 200:
            s.close(); return f"denied{code}"
        sent = client_hello(name) if name != "-" else b"ping SENTINEL-tls-7f3a\n"
        s.sendall(sent)
        r = echoed(s, sent); s.close()
        return "ok" if r else "closed"
    except OSError:
        return "closed"

def once(host):
    t = time.time()
    try:
        s, code = tunnel(host)
        if code != 200:
            s.close(); return f"denied{code}", time.time() - t
        s.sendall(b"ping\n"); r = s.recv(16); s.close()
        return ("ok" if r == b"ping\n" else "bad"), time.time() - t
    except ConnectionRefusedError:
        return "refused", time.time() - t
    except Exception as e:
        return "error:" + type(e).__name__, time.time() - t

def stream(host, secs, status):
    s, code = tunnel(host)
    if code != 200:
        open(status, "w").write(f"denied{code}\n"); return
    end, n = time.time() + secs, 0
    while time.time() < end:
        try:
            s.sendall(b"tick\n")
            if s.recv(16) != b"tick\n":
                raise ConnectionError("bad echo")
            n += 1
        except Exception as e:
            open(status, "w").write(f"broken after {n} ticks: {type(e).__name__}\n"); return
        open(status, "w").write(f"alive {n}\n")
        time.sleep(0.2)
    open(status, "w").write(f"done {n}\n")

def hammer(host, secs):
    counts, worst, end = {}, 0.0, time.time() + secs
    while time.time() < end:
        r, dt = once(host)
        counts[r] = counts.get(r, 0) + 1
        worst = max(worst, dt)
        time.sleep(0.01)
    print(" ".join(f"{k}={v}" for k, v in sorted(counts.items())), f"worst={worst*1000:.0f}ms")

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "once": print(once(sys.argv[2])[0])
    elif cmd == "stream": stream(sys.argv[2], float(sys.argv[3]), sys.argv[4])
    elif cmd == "hammer": hammer(sys.argv[2], float(sys.argv[3]))
    elif cmd == "first": print(first(sys.argv[2], sys.argv[3]))
