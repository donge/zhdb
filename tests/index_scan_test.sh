#!/usr/bin/env bash
# Cost-model plan/execution consistency: a single-table equality predicate on
# an indexed row table must be executed through the row hash index (the plan
# chosen by EXPLAIN), not by scanning every row.
#
# The test builds the same 200k-row table with and without an index, runs 100
# equality lookups plus UPDATE/DELETE invalidation checks, and asserts:
#   * both runs return identical results;
#   * EXPLAIN picks Index Scan for the indexed table and Seq Scan otherwise;
#   * the indexed run is substantially faster.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="$REPO/zig-out/bin/zhdb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[[ -x "$BIN" ]] || { echo "missing $BIN"; exit 1; }

gen() { # name indexed
    local n="$1" idx="$2"
    {
        printf 'CREATE TABLE %s (k int, v int);\n' "$n"
        printf 'INSERT INTO %s SELECT i, i*2 FROM generate_series(1, 200000) i;\n' "$n"
        [[ "$idx" == yes ]] && printf 'CREATE INDEX %s_k_idx ON %s(k);\n' "$n" "$n"
        printf 'ANALYZE %s;\n' "$n"
        for i in $(seq 1 100); do printf 'SELECT count(*) FROM %s WHERE k = %d;\n' "$n" "$((i * 1999 + 1))"; done
        printf 'UPDATE %s SET k = k + 1 WHERE k = 3001;\n' "$n"
        printf 'SELECT count(*) FROM %s WHERE k = 3001;\n' "$n"
        printf 'DELETE FROM %s WHERE k = 5001;\n' "$n"
        printf 'SELECT count(*) FROM %s WHERE k = 5001;\n' "$n"
    } > "$TMP/$n.sql"
}

gen ti yes
gen ts no
for n in ti ts; do
    /usr/bin/time -p "$BIN" run "$TMP/$n.sql" > "$TMP/$n.out" 2> "$TMP/$n.time"
    eval "${n}_real=$(awk '/^real/{print $2}' "$TMP/$n.time")"
done

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: $2 != $3"; fail=$((fail+1)); fi }
check "indexed and seq results identical" "$(cat "$TMP/ti.out")" "$(cat "$TMP/ts.out")"

cat > "$TMP/ex2.sql" <<SQL
CREATE TABLE ti_ex (k int, v int);
INSERT INTO ti_ex SELECT i, i * 2 FROM generate_series(1, 2000) i;
CREATE INDEX ti_ex_k_idx ON ti_ex(k);
ANALYZE ti_ex;
CREATE TABLE ts_ex (k int, v int);
INSERT INTO ts_ex SELECT i, i * 2 FROM generate_series(1, 2000) i;
ANALYZE ts_ex;
EXPLAIN (COSTS ON) SELECT * FROM ti_ex WHERE k = 1999;
EXPLAIN (COSTS ON) SELECT * FROM ts_ex WHERE k = 1999;
SQL
"$BIN" run "$TMP/ex2.sql" > "$TMP/ex2.out" 2>&1
check "EXPLAIN indexed = Index Scan" "yes" "$(grep -q 'Index Scan using ti_ex_k_idx on ti_ex' "$TMP/ex2.out" && echo yes || echo no)"
check "EXPLAIN unindexed = Seq Scan" "yes" "$(grep -q 'Seq Scan on ts_ex' "$TMP/ex2.out" && echo yes || echo no)"

python3 - "$ti_real" "$ts_real" <<'PY' > "$TMP/speed"
import sys
ti=float(sys.argv[1]); ts=float(sys.argv[2])
print("ok" if ti*2.0 < ts else "slow")
PY
check "indexed run at least 2x faster ($ti_real s vs $ts_real s)" "ok" "$(cat "$TMP/speed")"
check "UPDATE invalidated index" "0" "$(tail -2 "$TMP/ti.out" | head -1)"
check "DELETE invalidated index" "0" "$(tail -1 "$TMP/ti.out")"

if [[ $fail -eq 0 ]]; then echo "index scan: all checks passed"; exit 0; fi
echo "index scan: $fail check(s) failed"; exit 1
