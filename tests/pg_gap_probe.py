#!/usr/bin/env python3
"""Gap-assessment probe against a running zhdb server (pure socket, no psycopg)."""
import socket, struct, sys, json

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 25432

def msg(tag, payload=b""):
    return tag + struct.pack("!I", len(payload) + 4) + payload

def read_msg(s):
    hdr = b""
    while len(hdr) < 5:
        c = s.recv(5 - len(hdr))
        if not c: return None, b""
        hdr += c
    ln = struct.unpack("!I", hdr[1:5])[0]
    body = b""
    while len(body) < ln - 4:
        c = s.recv(ln - 4 - len(body))
        if not c: break
        body += c
    return hdr[0:1], body

def connect():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    # SSLRequest response is a bare byte ('N'/'S'), NOT a 5-byte protocol message.
    s.sendall(struct.pack("!II", 8, 80877103))
    ssl = s.recv(1).decode("ascii", "replace")
    params = b"user\x00zhdb\x00database\x00postgres\x00client_encoding\x00UTF8\x00\x00"
    s.sendall(struct.pack("!I", len(params) + 8) + struct.pack("!I", 196608) + params)
    msgs = []
    while True:
        tag, body = read_msg(s)
        if tag is None: raise SystemExit("closed during startup")
        msgs.append(tag.decode("ascii", "replace"))
        if tag == b"E": raise SystemExit("startup error: " + body.decode("utf-8", "replace"))
        if tag == b"Z": return s, ssl, msgs

def parse_row_desc(body):
    n = struct.unpack("!H", body[:2])[0]; pos = 2; cols = []
    for _ in range(n):
        end = body.index(b"\x00", pos); name = body[pos:end].decode(); pos = end + 1
        # tableoid(4) attnum(2) typid(4) typlen(2) typmod(4) format(2)
        tid = struct.unpack("!I", body[pos+6:pos+10])[0]
        pos += 18
        cols.append((name, tid))
    return cols

def parse_data_row(body):
    n = struct.unpack("!H", body[:2])[0]; pos = 2; row = []
    for _ in range(n):
        ln = struct.unpack("!i", body[pos:pos+4])[0]; pos += 4
        row.append(None if ln < 0 else body[pos:pos+ln].decode("utf-8", "replace"))
        pos += max(ln, 0)
    return row

def query(s, sql):
    s.sendall(msg(b"Q", sql.encode() + b"\x00"))
    cols, rows, tags, err, notice = [], [], [], None, 0
    while True:
        tag, body = read_msg(s)
        if tag is None: break
        if tag == b"T": cols = parse_row_desc(body)
        elif tag == b"D": rows.append(parse_data_row(body))
        elif tag == b"C": tags.append(body.rstrip(b"\x00").decode())
        elif tag == b"E":
            fields = {}
            pos = 0
            while pos < len(body) and body[pos:pos+1] != b"\x00":
                f = body[pos:pos+1].decode(); pos += 1
                end = body.index(b"\x00", pos); fields[f] = body[pos:end].decode("utf-8", "replace"); pos = end + 1
            err = {"sqlstate": fields.get("C"), "severity": fields.get("S"), "message": fields.get("M")}
        elif tag == b"N": notice += 1
        elif tag == b"Z": break
    return {"cols": [c[0] for c in cols], "oids": [c[1] for c in cols], "rows": rows, "tags": tags, "err": err, "notice": notice}

def extended(s, sql, params=None):
    params = params or []
    out = []
    # Parse
    p = sql.encode() + b"\x00" + struct.pack("!H", 0)
    s.sendall(msg(b"P", b"stmt\x00" + p))
    # Bind: portal, stmt, format codes(0=text all), params, result formats(0=text all)
    b = b"portal\x00stmt\x00" + struct.pack("!H", 0)
    b += struct.pack("!H", len(params))
    for v in params:
        raw = str(v).encode(); b += struct.pack("!i", len(raw)) + raw
    b += struct.pack("!H", 0)
    s.sendall(msg(b"B", b))
    # Describe portal
    s.sendall(msg(b"D", b"Pportal\x00"))
    # Execute
    s.sendall(msg(b"E", b"portal\x00" + struct.pack("!I", 0)))
    s.sendall(msg(b"S"))
    cols, rows, tags, err, seq = [], [], [], None, []
    while True:
        tag, body = read_msg(s)
        if tag is None: break
        seq.append(tag.decode("ascii", "replace"))
        if tag == b"T": cols = parse_row_desc(body)
        elif tag == b"D": rows.append(parse_data_row(body))
        elif tag == b"C": tags.append(body.rstrip(b"\x00").decode())
        elif tag == b"E":
            fields = {}; pos = 0
            while pos < len(body) and body[pos:pos+1] != b"\x00":
                f = body[pos:pos+1].decode(); pos += 1
                end = body.index(b"\x00", pos); fields[f] = body[pos:end].decode("utf-8", "replace"); pos = end + 1
            err = {"sqlstate": fields.get("C"), "message": fields.get("M")}
        elif tag == b"Z": break
    return {"seq": seq, "cols": [c[0] for c in cols], "rows": rows, "tags": tags, "err": err}

s, ssl, startup = connect()
print(json.dumps({"_startup": {"ssl_byte": ssl, "msgs": startup}}, ensure_ascii=False))

GROUPS = {
"L1_protocol": {
  "select1": "SELECT 1 AS n",
  "version": "SELECT version()",
  "show_server_version": "SHOW server_version",
  "show_server_version_num": "SHOW server_version_num",
  "multi_stmt": "SELECT 1; SELECT 2",
  "empty_query": "",
  "divide_by_zero": "SELECT 1/0",
  "undefined_table": "SELECT * FROM no_such_table_xyz",
  "syntax_error": "SELCT 1",
},
"L2_catalog": {
  "pg_class": "SELECT relname, relkind FROM pg_catalog.pg_class ORDER BY relname LIMIT 5",
  "pg_attribute": "SELECT attname, atttypid FROM pg_catalog.pg_attribute LIMIT 5",
  "pg_type": "SELECT typname, oid FROM pg_catalog.pg_type ORDER BY oid LIMIT 5",
  "pg_proc": "SELECT proname FROM pg_catalog.pg_proc LIMIT 5",
  "pg_namespace": "SELECT nspname FROM pg_catalog.pg_namespace ORDER BY nspname LIMIT 5",
  "pg_index": "SELECT indexrelid, indrelid FROM pg_catalog.pg_index LIMIT 5",
  "pg_settings": "SELECT name, setting FROM pg_catalog.pg_settings LIMIT 5",
  "pg_database": "SELECT datname FROM pg_catalog.pg_database",
  "information_schema_columns": "SELECT table_name, column_name FROM information_schema.columns LIMIT 5",
  "pg_get_keywords": "SELECT word FROM pg_catalog.pg_get_keywords() LIMIT 5",
  "psql_dt_query": "SELECT n.nspname as \"Schema\", c.relname as \"Name\", CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized view' WHEN 'i' THEN 'index' WHEN 'S' THEN 'sequence' WHEN 't' THEN 'TOAST table' WHEN 'f' THEN 'foreign table' WHEN 'p' THEN 'partitioned table' WHEN 'I' THEN 'partitioned index' END as \"Type\", pg_catalog.pg_get_userbyid(c.relowner) as \"Owner\" FROM pg_catalog.pg_class c LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam WHERE c.relkind IN ('r','p','t','s','') AND c.relname OPERATOR(pg_catalog.~) '^(foo)$' COLLATE pg_catalog.default AND pg_catalog.pg_table_is_visible(c.oid) ORDER BY 1,2",
},
"L3_sql": {
  "cte": "WITH t AS (SELECT 1 AS x) SELECT x FROM t",
  "recursive_cte": "WITH RECURSIVE t(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM t WHERE n<3) SELECT n FROM t",
  "window": "SELECT row_number() OVER (ORDER BY x) AS rn FROM (VALUES(2),(1)) v(x)",
  "returning": "CREATE TABLE ins_ret(id int); INSERT INTO ins_ret VALUES (1) RETURNING id",
  "on_conflict": "CREATE TABLE oc(id int primary key); INSERT INTO oc VALUES(1) ON CONFLICT(id) DO UPDATE SET id=2",
  "jsonb": "SELECT '{\"a\":1}'::jsonb -> 'a'",
  "array": "SELECT ARRAY[1,2,3]",
  "interval": "SELECT INTERVAL '1 day'",
  "now": "SELECT now() IS NOT NULL",
  "current_date": "SELECT current_date IS NOT NULL",
  "ilike": "SELECT 'ABC' ILIKE 'abc'",
  "distinct_on": "SELECT DISTINCT ON (x) x FROM (VALUES(1),(1)) v(x)",
  "nulls_first": "SELECT x FROM (VALUES(1),(NULL)) v(x) ORDER BY x NULLS FIRST",
  "substring_from": "SELECT substring('abcdef' FROM 2 FOR 3)",
  "serial": "CREATE TABLE ser(id serial)",
  "numeric_precision": "SELECT 1.234::numeric(10,2)",
  "alter_add_column": "CREATE TABLE ac(a int); ALTER TABLE ac ADD COLUMN b int; SELECT b FROM ac",
  "create_view": "CREATE VIEW vv AS SELECT 1 AS x; SELECT x FROM vv",
  "foreign_key": "CREATE TABLE fk1(id int primary key); CREATE TABLE fk2(id int references fk1(id))",
  "range_type": "SELECT int4range(1,3)",
},
"L4_behave": {
  "txn_begin_commit": "BEGIN; SELECT 1; COMMIT",
  "txn_rollback": "BEGIN; SELECT 1; ROLLBACK",
  "savepoint": "BEGIN; SAVEPOINT s1; SELECT 1; ROLLBACK TO s1; COMMIT",
  "isolation_level": "BEGIN ISOLATION LEVEL SERIALIZABLE; SHOW transaction_isolation; COMMIT",
  "select_for_update": "SELECT 1 FOR UPDATE",
  "duplicate_key_sqlstate": "CREATE TABLE dk(id int primary key); INSERT INTO dk VALUES(1); INSERT INTO dk VALUES(1)",
  "check_violation": "CREATE TABLE cv(x int CHECK (x>0)); INSERT INTO cv VALUES(-1)",
  "lock_table": "LOCK TABLE dk IN ACCESS EXCLUSIVE MODE",
  "advisory_lock": "SELECT pg_advisory_lock(123)",
  "set_guc": "SET work_mem = '1MB'; SHOW work_mem",
},
"L5_ops": {
  "copy_to_stdout": "COPY dk TO STDOUT",
  "publication": "CREATE PUBLICATION pub FOR ALL TABLES",
  "subscription": "CREATE SUBSCRIPTION sub CONNECTION '' PUBLICATION pub",
  "pg_dump_style": "SELECT pg_get_serial_sequence('dk','id')",
},
}

results = {}
for group, cases in GROUPS.items():
    results[group] = {}
    for name, sql in cases.items():
        try:
            results[group][name] = query(s, sql)
        except Exception as e:
            results[group][name] = {"exception": str(e)}
print(json.dumps(results, ensure_ascii=False, indent=1))

print(json.dumps({"_extended": extended(s, "SELECT $1::int AS n", [42])}, ensure_ascii=False))
s.close()
