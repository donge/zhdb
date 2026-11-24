#!/usr/bin/env python3
"""Catalog / psql-compatibility test for zhdb (no psql needed).

Runs the exact SQL psql 18 sends for `\\dt` plus the catalog functions and join
shapes real clients rely on, and asserts the rows.

Usage: python3 tests/pg_catalog_test.py [port]
"""
import os
import socket
import struct
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5432
HERE = os.path.dirname(os.path.abspath(__file__))


def msg(tag, payload=b""):
    return tag + struct.pack("!I", len(payload) + 4) + payload


def read_msg(sock):
    hdr = b""
    while len(hdr) < 5:
        chunk = sock.recv(5 - len(hdr))
        if not chunk:
            return None, b""
        hdr += chunk
    length = struct.unpack("!I", hdr[1:5])[0]
    body = b""
    while len(body) < length - 4:
        chunk = sock.recv(length - 4 - len(body))
        if not chunk:
            break
        body += chunk
    return hdr[0:1], body


def connect():
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    sock.sendall(struct.pack("!II", 8, 80877103))
    assert sock.recv(1) == b"N", "server should refuse TLS (not implemented)"
    params = b"user\x00zhdb\x00database\x00postgres\x00\x00"
    sock.sendall(struct.pack("!I", len(params) + 8) + struct.pack("!I", 196608) + params)
    while True:
        tag, body = read_msg(sock)
        if tag == b"E":
            raise SystemExit("startup failed: " + body.decode("utf-8", "replace"))
        if tag == b"Z":
            return sock


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
    sock = connect()
    checks = 0
    failures = []

    def check(name, sql, expect_rows=None, expect_cols=None):
        nonlocal checks
        checks += 1
        cols, rows = query(sock, sql)
        if cols is None:
            failures.append(f"{name}: error {rows.splitlines()[-1] if rows else rows}")
            return
        if expect_cols is not None and cols != expect_cols:
            failures.append(f"{name}: columns {cols} != {expect_cols}")
            return
        if expect_rows is not None and rows != expect_rows:
            failures.append(f"{name}: rows {rows} != {expect_rows}")

    check("create", "CREATE TABLE zc (k int, v text)", [])
    check("insert", "INSERT INTO zc VALUES (1,'a'),(2,'b')", [])
    check("analyze", "ANALYZE zc", [])

    # The real `\dt` query (LEFT JOIN + simple CASE + !~ + ORDER BY ordinals).
    with open(os.path.join(HERE, "psql_dt.sql"), "r", encoding="utf-8") as f:
        dt_sql = f.read()
    check(
        "psql \\dt",
        dt_sql,
        [["public", "zc", "table", "zhdb"]],
        ["Schema", "Name", "Type", "Owner"],
    )

    # Catalog functions.
    check("current_schema", "SELECT current_schema()", [["public"]])
    check("pg_get_userbyid", "SELECT pg_get_userbyid(1)", [["zhdb"]])
    check("pg_table_is_visible", "SELECT pg_table_is_visible(1)", [["true"]])
    check("pg_encoding_to_char", "SELECT pg_encoding_to_char(6)", [["UTF8"]])

    # Catalog tables really hold rows.
    cols, rows = query(sock, "SELECT COUNT(*) FROM pg_catalog.pg_attribute")
    checks += 1
    if cols is None or int(rows[0][0]) < 2:
        failures.append(f"pg_attribute: {rows}")

    cols, rows = query(sock, "SELECT relname FROM pg_catalog.pg_class WHERE relkind = 'r'")
    checks += 1
    names = [r[0] for r in rows or []]
    if "zc" not in names:
        failures.append(f"pg_class: {names}")

    # LEFT JOIN semantics against a user table pair.
    check("create r", "CREATE TABLE zr (k int, w text)", [])
    check("insert r", "INSERT INTO zr VALUES (1,'p'),(3,'q')", [])
    check(
        "left join",
        "SELECT zc.v, zr.w FROM zc LEFT JOIN zr ON zc.k = zr.k ORDER BY zc.k",
        [["a", "p"], ["b", None]],
    )
    check(
        "inner join",
        "SELECT COUNT(*) FROM zc JOIN zr ON zc.k = zr.k",
        [["1"]],
    )
    check(
        "right join",
        "SELECT zc.v, zr.w FROM zc RIGHT JOIN zr ON zc.k = zr.k ORDER BY zr.k",
        [["a", "p"], [None, "q"]],
    )
    # --- semi / anti join: IN (subquery) and EXISTS -----------------------
    check("create sa", "CREATE TABLE sa (k int, v int)", [])
    check("insert sa", "INSERT INTO sa VALUES (1,10),(2,20),(3,30),(4,40)", [])
    check("create sb", "CREATE TABLE sb (k int)", [])
    check("insert sb", "INSERT INTO sb VALUES (2),(4),(NULL)", [])
    check(
        "semi join (IN)",
        "SELECT COUNT(*) FROM sa WHERE k IN (SELECT k FROM sb)",
        [["2"]],
    )
    check(
        "anti join (NOT IN, NULL poisons)",
        "SELECT COUNT(*) FROM sa WHERE k NOT IN (SELECT k FROM sb)",
        [["0"]],
    )
    check(
        "anti join (NULL filtered out)",
        "SELECT COUNT(*) FROM sa WHERE k NOT IN (SELECT k FROM sb WHERE k IS NOT NULL)",
        [["2"]],
    )
    check(
        "semi join rows",
        "SELECT k FROM sa WHERE k IN (SELECT k FROM sb) ORDER BY k",
        [["2"], ["4"]],
    )
    check("exists true", "SELECT COUNT(*) FROM sa WHERE EXISTS (SELECT 1 FROM sb)", [["4"]])
    check("exists false", "SELECT COUNT(*) FROM sa WHERE EXISTS (SELECT 1 FROM sb WHERE k = 99)", [["0"]])
    check(
        "semi + residual predicate",
        "SELECT COUNT(*) FROM sa WHERE k IN (SELECT k FROM sb) AND v > 20",
        [["1"]],
    )

    # Correlated subqueries are rewritten into hash semi/anti joins.
    check(
        "correlated EXISTS",
        "SELECT COUNT(*) FROM sa WHERE EXISTS (SELECT 1 FROM sb WHERE sb.k = sa.k)",
        [["2"]],
    )
    check(
        "correlated NOT EXISTS",
        "SELECT COUNT(*) FROM sa WHERE NOT EXISTS (SELECT 1 FROM sb WHERE sb.k = sa.k)",
        [["2"]],
    )
    check(
        "correlated IN",
        "SELECT COUNT(*) FROM sa WHERE sa.k IN (SELECT sb.k FROM sb WHERE sb.k = sa.k)",
        [["2"]],
    )
    check(
        "correlated rows",
        "SELECT k FROM sa WHERE EXISTS (SELECT 1 FROM sb WHERE sb.k = sa.k) ORDER BY k",
        [["2"], ["4"]],
    )
    check(
        "correlated + inner filter",
        "SELECT COUNT(*) FROM sa WHERE EXISTS (SELECT 1 FROM sb WHERE sb.k = sa.k AND sb.k > 3)",
        [["1"]],
    )
    # Non-equality correlation is not rewritable: it must error, never guess.
    cols, rows = query(sock, "SELECT COUNT(*) FROM sa WHERE EXISTS (SELECT 1 FROM sb WHERE sb.k > sa.k)")
    checks += 1
    if cols is not None and rows:
        failures.append(f"non-equi correlation returned {rows} instead of an error")

    # --- 4-table chain join aggregate (regression guard) ---------------------
    for name, ddl, rows in (
        ("ca", "CREATE TABLE ca (k int, v int)", "(1,10),(2,20),(3,30),(4,40),(5,50)"),
        ("cb", "CREATE TABLE cb (k int, w int)", "(1,100),(2,200),(2,201),(3,300),(4,400)"),
        ("cc", "CREATE TABLE cc (k int, z int)", "(1,1000),(2,2000),(2,2001),(3,3000),(5,5000)"),
        ("cd", "CREATE TABLE cd (k int, q int)", "(1,7),(2,8),(3,9),(4,10),(5,11)"),
    ):
        check(f"create {name}", ddl, [])
        check(f"insert {name}", f"INSERT INTO {name} VALUES {rows}", [])
    chain = "FROM ca JOIN cb ON ca.k = cb.k JOIN cc ON cb.k = cc.k JOIN cd ON cc.k = cd.k"
    check("chain4 count/sum", f"SELECT COUNT(*), SUM(cb.w) {chain}", [["6", "1202"]])
    check(
        "chain4 group by",
        f"SELECT ca.k, COUNT(*) AS n, SUM(cc.z) AS sz {chain} GROUP BY ca.k ORDER BY ca.k",
        [["1", "1", "1000"], ["2", "4", "8002"], ["3", "1", "3000"]],
    )

    # --- non-equi join (< > <= >=) ------------------------------------------
    check("create sja", "CREATE TABLE sja (k int, v text)", [])
    check("insert sja", "INSERT INTO sja VALUES (1,'a1'),(3,'a3'),(5,'a5')", [])
    check("create sjb", "CREATE TABLE sjb (k int, w text)", [])
    check("insert sjb", "INSERT INTO sjb VALUES (2,'b2'),(4,'b4'),(6,'b6')", [])
    check(
        "non-equi <",
        "SELECT COUNT(*) FROM sja JOIN sjb ON sja.k < sjb.k",
        [["6"]],
    )
    check(
        "non-equi >=",
        "SELECT COUNT(*) FROM sja JOIN sjb ON sja.k >= sjb.k",
        [["3"]],
    )
    check(
        "non-equi rows",
        "SELECT sja.v, sjb.w FROM sja JOIN sjb ON sja.k < sjb.k ORDER BY sja.v, sjb.w LIMIT 3",
        [["a1", "b2"], ["a1", "b4"], ["a1", "b6"]],
    )
    check(
        "non-equi left join pads NULL",
        "SELECT sja.v, sjb.w FROM sja LEFT JOIN sjb ON sja.k > sjb.k ORDER BY sja.v",
        [["a1", None], ["a3", "b2"], ["a5", "b2"], ["a5", "b4"]],
    )
    check(
        "non-equi with index (same rows)",
        "CREATE INDEX sjb_ix ON sjb(k)",
        [],
    )
    check(
        "non-equi < after index",
        "SELECT COUNT(*) FROM sja JOIN sjb ON sja.k < sjb.k",
        [["6"]],
    )

    # Inclusive join with regex on the left side (psql's `!~`).
    # `zc` and `zr` are the two user tables; no catalog table starts with pg_ in
    # pg_class (refreshCatalog skips system tables).
    check(
        "regex negate",
        "SELECT COUNT(*) FROM pg_class c WHERE c.relname !~ '^pg_'",
        [["10"]],
    )
    check(
        "regex positive",
        "SELECT COUNT(*) FROM pg_class c WHERE c.relname ~ '^pg'",
        [["0"]],
    )

    if failures:
        print(f"pg catalog: {checks - len(failures)}/{checks} checks passed")
        for f in failures:
            print("  FAIL:", f)
        return 1
    print(f"pg catalog: {checks}/{checks} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
