#!/usr/bin/env python3
"""Minimal PG v3 protocol smoke test for zhdb (no psql required).

Usage: python3 tests/pg_protocol_test.py [port]
"""
import socket
import struct
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5432


def msg(tag, payload=b""):
    return tag + struct.pack("!I", len(payload) + 4) + payload


def read_msg(sock):
    hdr = b""
    while len(hdr) < 5:
        chunk = sock.recv(5 - len(hdr))
        if not chunk:
            return None, b""
        hdr += chunk
    tag = hdr[0:1]
    length = struct.unpack("!I", hdr[1:5])[0]
    body = b""
    while len(body) < length - 4:
        chunk = sock.recv(length - 4 - len(body))
        if not chunk:
            break
        body += chunk
    return tag, body


def query(sock, sql):
    sock.sendall(msg(b"Q", sql.encode() + b"\x00"))
    cols, rows = [], []
    err = None
    while True:
        tag, body = read_msg(sock)
        if tag is None:
            raise SystemExit("connection closed")
        if tag == b"T":
            n = struct.unpack("!H", body[:2])[0]
            pos = 2
            for _ in range(n):
                end = body.index(b"\x00", pos)
                cols.append(body[pos:end].decode())
                pos = end + 1 + 18
        elif tag == b"D":
            n = struct.unpack("!H", body[:2])[0]
            pos = 2
            row = []
            for _ in range(n):
                ln = struct.unpack("!i", body[pos:pos + 4])[0]
                pos += 4
                row.append(None if ln < 0 else body[pos:pos + ln].decode())
                pos += max(ln, 0)
            rows.append(row)
        elif tag == b"E":
            # Keep draining: ReadyForQuery still follows ErrorResponse.
            err = body.decode("utf-8", "replace")
        elif tag == b"Z":
            if err is not None:
                return None, err
            return cols, rows


def main():
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    # SSLRequest must be refused with 'N'.
    sock.sendall(struct.pack("!II", 8, 80877103))
    assert sock.recv(1) == b"N", "server should refuse TLS"

    params = b"user\x00zhdb\x00database\x00postgres\x00\x00"
    sock.sendall(struct.pack("!I", len(params) + 8) + struct.pack("!I", 196608) + params)
    ready = False
    while not ready:
        tag, body = read_msg(sock)
        if tag == b"E":
            raise SystemExit("startup failed: " + body.decode("utf-8", "replace"))
        ready = tag == b"Z"

    checks = [
        ("select 1", [["1"]]),
        ("create table proto_t(id int, name text)", None),
        ("insert into proto_t values (1,'a'),(2,'b')", None),
        ("select count(*) from proto_t", [["2"]]),
        ("select name from proto_t order by id", [["a"], ["b"]]),
        ("select sum(id), avg(id) from proto_t", [["3", "1.5"]]),
    ]
    ok = 0
    for sql, expected in checks:
        _, rows = query(sock, sql)
        if expected is None:
            ok += 1
            continue
        if rows == expected:
            ok += 1
        else:
            print(f"FAIL {sql}: got {rows} want {expected}")
    sock.close()
    print(f"pg protocol: {ok}/{len(checks)} checks passed")
    sys.exit(0 if ok == len(checks) else 1)


if __name__ == "__main__":
    main()
