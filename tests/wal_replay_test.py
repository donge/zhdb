#!/usr/bin/env python3
"""WAL replay must not grow memory with the number of commits.

Writes a synthetic WAL with many tiny committed statements, starts zhdb on it
and checks that the process starts quickly and does not use a huge amount of
memory while replaying.

Usage: python3 tests/wal_replay_test.py
"""
import os
import platform
import resource
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "zig-out", "bin", "zhdb")

N_COMMITS = 20000
MAX_START_SECONDS = 30.0
MAX_RSS_BYTES = 512 * 1024 * 1024


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def make_wal(path):
    stmt = b"select 1"
    rec = struct.pack("<I", len(stmt)) + stmt + b"\x00\x00\x00\x00"
    with open(path, "wb") as f:
        f.write(rec * N_COMMITS)


def max_rss_bytes():
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    # macOS reports bytes, Linux reports kilobytes.
    return rss if platform.system() == "Darwin" else rss * 1024


def main():
    if not os.access(BIN, os.X_OK):
        print("missing %s (run: zig build --release=fast)" % BIN)
        return 1

    port = free_port()
    with tempfile.TemporaryDirectory() as tmp:
        wal = os.path.join(tmp, "replay.wal")
        make_wal(wal)
        print("wal: %d commits, %.1f KiB" % (N_COMMITS, os.path.getsize(wal) / 1024.0))

        t0 = time.time()
        srv = subprocess.Popen(
            [BIN, "serve", "--port=%d" % port, "--wal=%s" % wal],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        listened = False
        while time.time() - t0 < MAX_START_SECONDS:
            if srv.poll() is not None:
                break
            try:
                s = socket.create_connection(("127.0.0.1", port), timeout=0.2)
                s.close()
                listened = True
                break
            except OSError:
                time.sleep(0.05)
        elapsed = time.time() - t0

        if srv.poll() is None:
            srv.send_signal(signal.SIGKILL)
        srv.wait()
        rss = max_rss_bytes()

        if not listened:
            print("FAIL not listening after %.1fs (limit %.0fs), maxrss=%.0f MiB"
                  % (elapsed, MAX_START_SECONDS, rss / 1048576.0))
            return 1
        if rss > MAX_RSS_BYTES:
            print("FAIL maxrss=%.0f MiB > %.0f MiB (replay buffer grows with commit count)"
                  % (rss / 1048576.0, MAX_RSS_BYTES / 1048576.0))
            return 1
        print("wal replay: ok (started in %.2fs, maxrss=%.0f MiB)"
              % (elapsed, rss / 1048576.0))
        return 0


if __name__ == "__main__":
    sys.exit(main())
