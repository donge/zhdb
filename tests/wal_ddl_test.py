#!/usr/bin/env python3
"""WAL persistence test: DDL and DML must both survive a crash + restart.

Starts zhdb with --wal, creates a table and inserts a row over the PG wire
protocol, kills the process with SIGKILL, starts it again on the same WAL and
checks that the row is still there.

Usage: python3 tests/wal_ddl_test.py
"""
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "zig-out", "bin", "zhdb")


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
    cols, rows, err = [], [], None
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
                pos = end + 19
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
            err = body.decode("utf-8", "replace")
        elif tag == b"Z":
            if err is not None:
                return None, err
            return rows, None


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def start_server(port, wal):
    return subprocess.Popen(
        [BIN, "serve", "--port=%d" % port, "--wal=%s" % wal],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
    )


def connect(port, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=2)
            break
        except OSError:
            time.sleep(0.05)
    else:
        raise SystemExit("server did not start listening on %d" % port)

    sock.sendall(struct.pack("!II", 8, 80877103))
    if sock.recv(1) != b"N":
        raise SystemExit("server should refuse TLS")
    params = b"user\x00zhdb\x00database\x00postgres\x00\x00"
    sock.sendall(struct.pack("!I", len(params) + 8) + struct.pack("!I", 196608) + params)
    while True:
        tag, body = read_msg(sock)
        if tag == b"E":
            raise SystemExit("startup failed: " + body.decode("utf-8", "replace"))
        if tag == b"Z":
            return sock


def main():
    if not os.access(BIN, os.X_OK):
        print("missing %s (run: zig build --release=fast)" % BIN)
        return 1

    port = free_port()
    with tempfile.TemporaryDirectory() as tmp:
        wal = os.path.join(tmp, "test.wal")

        srv = start_server(port, wal)
        sock = connect(port)
        _, err = query(sock, "create table t(id bigint, v text)")
        if err is None:
            _, err = query(sock, "insert into t values (1,'a')")
        sock.close()
        if err is not None:
            srv.kill()
            print("FAIL initial write: %s" % err)
            return 1

        # Simulate a crash: no graceful shutdown, only the WAL remains.
        srv.send_signal(signal.SIGKILL)
        srv.wait()
        log1 = srv.stderr.read()

        srv = start_server(port, wal)
        sock = connect(port)
        rows, err = query(sock, "select count(*) from t")
        sock.close()
        srv.send_signal(signal.SIGKILL)
        srv.wait()
        log2 = srv.stderr.read()

        if err is None and rows == [["1"]]:
            print("wal ddl: ok (schema + row replayed after crash)")
            return 0
        print("FAIL expected [['1']], got %r" % (rows,))
        print("--- first run ---\n%s--- restart ---\n%s" % (log1, log2))
        return 1


if __name__ == "__main__":
    sys.exit(main())
