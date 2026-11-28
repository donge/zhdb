#!/usr/bin/env python3
"""Extended-query protocol probe: text params, binary params, result formats."""
import socket, struct, sys

def msg(t, p=b""):
    return t + struct.pack("!I", len(p) + 4) + p

def recv(s):
    h = b""
    while len(h) < 5:
        h += s.recv(5 - len(h))
    n = struct.unpack("!I", h[1:5])[0]
    b = b""
    while len(b) < n - 4:
        b += s.recv(n - 4 - len(b))
    return h[:1], b

class Client:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        p = b"user\x00zhdb\x00database\x00postgres\x00\x00"
        self.s.sendall(struct.pack("!I", len(p) + 8) + struct.pack("!I", 196608) + p)
        while True:
            t, b = recv(self.s)
            if t == b"R" and struct.unpack("!I", b[:4])[0] != 0:
                raise RuntimeError("unexpected auth")
            if t == b"Z":
                return
    def sync(self):
        self.s.sendall(msg(b"S", b""))
        while True:
            t, _ = recv(self.s)
            if t == b"Z":
                return
    def parse(self, sql, oids):
        body = b"\x00" + sql.encode() + b"\x00" + struct.pack("!H", len(oids))
        body += b"".join(struct.pack("!I", o) for o in oids)
        self.s.sendall(msg(b"P", body)); self.sync()
    def bind(self, fmts, vals, rfmts=()):
        body = b"\x00\x00" + struct.pack("!H", len(fmts))
        body += b"".join(struct.pack("!H", f) for f in fmts)
        body += struct.pack("!H", len(vals))
        for v in vals:
            if v is None:
                body += struct.pack("!i", -1)
            else:
                body += struct.pack("!i", len(v)) + v
        body += struct.pack("!H", len(rfmts))
        body += b"".join(struct.pack("!H", f) for f in rfmts)
        self.s.sendall(msg(b"B", body)); self.sync()
    def execute(self):
        self.s.sendall(msg(b"E", b"\x00" + struct.pack("!I", 0)))
        self.s.sendall(msg(b"S", b""))
        rows = []
        while True:
            t, b = recv(self.s)
            if t == b"D":
                n = struct.unpack("!H", b[:2])[0]; off = 2; r = []
                for _ in range(n):
                    ln = struct.unpack("!i", b[off:off+4])[0]; off += 4
                    r.append(None if ln < 0 else b[off:off+ln].decode()); off += max(ln, 0)
                rows.append(r)
            elif t == b"E":
                return ("ERR", b)
            elif t == b"Z":
                return ("OK", rows)

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5432
    c = Client(port)
    c.parse("SELECT $1::text", [25]); c.bind([0], [b"007"])
    st, rows = c.execute()
    assert st == "OK" and rows[0][0] == "007", (st, rows)
    c.parse("SELECT $1::int", [23]); c.bind([1], [struct.pack("!i", 42)])
    st, rows = c.execute()
    assert st == "OK" and rows[0][0] == "42", (st, rows)
    c.parse("SELECT $1::bigint + 1", [20]); c.bind([1], [struct.pack("!q", 41)])
    st, rows = c.execute()
    assert st == "OK" and rows[0][0] == "42", (st, rows)
    c.parse("SELECT 1", []); c.bind([], [], [1])
    st, err = c.execute()
    assert st == "ERR" and b"binary result format" in err, (st, err)
    print("extended probe: text/binary params ok; binary result rejected explicitly")

if __name__ == "__main__":
    main()
