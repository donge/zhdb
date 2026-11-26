#!/usr/bin/env bash
# Join execution follows the cost model: a one-row outer side must run as a
# Nested Loop, a large equi-join as a Hash Join, and EXPLAIN must report the
# same choice and costs that the executor uses.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="$REPO/zig-out/bin/zhdb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[[ -x "$BIN" ]] || { echo "missing $BIN"; exit 1; }

cat > "$TMP/j.sql" <<'SQL'
CREATE TABLE pc (id int, grp int, val int);
INSERT INTO pc SELECT i, i % 100, i * 2 FROM generate_series(1, 10000) i;
ANALYZE pc;
CREATE TABLE tiny (id int, grp int);
INSERT INTO tiny VALUES (1, 7);
ANALYZE tiny;
CREATE TABLE la (id int, grp int);
INSERT INTO la SELECT i, i % 100 FROM generate_series(1, 2000) i;
CREATE TABLE lb (id int, grp int);
INSERT INTO lb SELECT i, i % 100 FROM generate_series(1, 2000) i;
ANALYZE la; ANALYZE lb;
EXPLAIN (COSTS ON) SELECT t.id, p.id FROM tiny t JOIN pc p ON t.grp = p.grp;
EXPLAIN (COSTS ON) SELECT a.id, b.id FROM la a JOIN lb b ON a.grp = b.grp;
SELECT t.id, p.id FROM tiny t JOIN pc p ON t.grp = p.grp ORDER BY p.id;
SELECT count(*) FROM (SELECT a.id, b.id FROM la a JOIN lb b ON a.grp = b.grp) s;
SQL

ZHDB_EXPLAIN=1 "$BIN" run "$TMP/j.sql" > "$TMP/out" 2> "$TMP/err"

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: $2 != $3"; fail=$((fail+1)); fi }
check "EXPLAIN tiny = Nested Loop" yes "$(grep -q '^Nested Loop  (cost=0.00..141.01 rows=10000' "$TMP/out" && echo yes || echo no)"
check "EXPLAIN large = Hash Join" yes "$(grep -q '^Hash Join  (cost=22.00..454.00 rows=40000' "$TMP/out" && echo yes || echo no)"
check "executor used Nested Loop" yes "$(grep -q 'join method=nested_loop nl=141.01' "$TMP/err" && echo yes || echo no)"
check "executor used Hash Join" yes "$(grep -q 'join method=hash nl=54022.00 hash=454.00' "$TMP/err" && echo yes || echo no)"
check "nested-loop rows" 100 "$(sed -n '/^1\t7$/,/^1\t9907$/p' "$TMP/out" | wc -l | tr -d ' ')"
check "nested-loop first/last" "1	7|1	9907" "$(grep -m1 '^1	7$' "$TMP/out")|$(grep -m1 '^1	9907$' "$TMP/out")"
check "hash-join row count" 40000 "$(tail -1 "$TMP/out")"
if [[ $fail -eq 0 ]]; then echo "join plan: all checks passed"; exit 0; fi
echo "join plan: $fail check(s) failed"; exit 1
