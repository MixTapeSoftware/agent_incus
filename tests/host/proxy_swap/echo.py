#!/usr/bin/env python3
import socket, threading
def serve(c):
    with c:
        while True:
            d = c.recv(4096)
            if not d: return
            c.sendall(d)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 4760)); s.listen(128)
while True:
    c, _ = s.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
