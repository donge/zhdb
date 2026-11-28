#!/usr/bin/env python3
"""Protocol probes for zhdb: SCRAM-SHA-256 login and CancelRequest.

Usage: tests/pg_protocol_probe.py [port] [password]
Starts an already-running server externally; exits non-zero on failure.
"""
import base64, hashlib, hmac, os, socket, struct, sys, time

def msg(tag, payload=b""):
    return tag + struct.pack("!I", len(payload) + 4) + payload

class Client:
    def __init__(self, port, password):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=15)
        self.pid = self.key = None
        p = b"user\x00zhdb\x00database\x00postgres\x00\x00"
        self.s.sendall(struct.pack("!I", len(p) + 8) + struct.pack("!I", 196608) + p)
        self._auth(password)
    def _recv(self):
        h = b""
        while len(h) < 5:
            c = self.s.recv(5 - len(h))
            if not c: raise EOFError
            h += c
        n = struct.unpack("!I", h[1:5])[0]
        b = b""
        while len(b) < n - 4:
            c = self.s.recv(n - 4 - len(b))
            if not c: raise EOFError
            b += c
        return h[:1], b
    def _auth(self, password):
        first_sent = False
        while True:
            tag, b = self._recv()
            if tag == b"R":
                code = struct.unpack("!I", b[:4])[0]
                if code == 0:
                    continue
                if code == 10:
                    self.nonce = base64.b64encode(os.urandom(18)).decode()
                    self.cfirst_bare = "n=,r=" + self.nonce
                    first = ("n,," + self.cfirst_bare).encode()
                    self.s.sendall(msg(b"p", b"SCRAM-SHA-256\x00" + struct.pack("!I", len(first)) + first))
                    first_sent = True
                    continue
                if code == 11:
                    sf = b[4:].decode()
                    d = dict(x.split("=", 1) for x in sf.split(","))
                    salt = base64.b64decode(d["s"])
                    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, int(d["i"]), 32)
                    ck = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
                    sk = hashlib.sha256(ck).digest()
                    cfwo = "c=biws,r=" + d["r"]
                    am = (self.cfirst_bare + "," + sf + "," + cfwo).encode()
                    sig = hmac.new(sk, am, hashlib.sha256).digest()
                    proof = bytes(a ^ c for a, c in zip(ck, sig))
                    final = (cfwo + ",p=" + base64.b64encode(proof).decode()).encode()
                    self.last_auth_msg = (am, salted)
                    self.s.sendall(msg(b"p", final))
                    continue
                if code == 12:
                    continue
                raise RuntimeError("auth code %d" % code)
            if tag == b"K":
                self.pid, self.key = struct.unpack("!II", b[:8])
            if tag == b"E":
                raise RuntimeError("auth failed: " + repr(b))
            if tag == b"Z":
                return
    def query(self, q):
        self.s.sendall(msg(b"Q", q.encode() + b"\x00"))
        rows = []
        while True:
            tag, b = self._recv()
            if tag == b"D":
                n = struct.unpack("!H", b[:2])[0]; off = 2; r = []
                for _ in range(n):
                    ln = struct.unpack("!i", b[off:off+4])[0]; off += 4
                    if ln < 0: r.append(None)
                    else:
                        r.append(b[off:off+ln].decode(errors="replace")); off += ln
                rows.append(r)
            elif tag == b"E":
                return ("ERROR", b)
            elif tag == b"Z":
                return ("OK", rows)

def cancel(port, pid, key):
    s = socket.create_connection(("127.0.0.1", port), timeout=15)
    s.sendall(struct.pack("!I", 16) + struct.pack("!I", 80877102) + struct.pack("!II", pid, key))
    s.close()

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5432
    password = sys.argv[2] if len(sys.argv) > 2 else "postgres"
    try:
        Client(port, password + "-wrong")
        raise SystemExit("SCRAM accepted a wrong password")
    except RuntimeError:
        pass
    c = Client(port, password)
    if not c.pid or not c.key:
        raise SystemExit("missing BackendKeyData")
    st, rows = c.query("SELECT 1")
    if st != "OK" or rows[0][0] != "1":
        raise SystemExit("basic query failed")
    cancel(port, c.pid + 1, c.key)
    time.sleep(0.1)
    st, _ = c.query("SELECT 2")
    if st != "OK":
        raise SystemExit("wrong-key cancel cancelled a statement")
    cancel(port, c.pid, c.key)
    time.sleep(0.1)
    st, err = c.query("SELECT 3")
    if st != "ERROR" or b"canceling statement" not in err:
        raise SystemExit("CancelRequest did not mark the session")
    print("protocol probe: SCRAM-SHA-256 ok; CancelRequest ok")

if __name__ == "__main__":
    main()
