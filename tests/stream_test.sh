#!/usr/bin/env bash
# Streaming scan test: aggregates must be correct while the column is decoded
# block-by-block through the buffer pool (never fully resident).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="$REPO/zig-out/bin/zhdb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -x "$BIN" ]] || { echo "missing $BIN (run: zig build --release=fast)"; exit 1; }

fail=0
check() { # name expect actual
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=$((fail+1)); fi
}

{
    printf '#schema: k:int\tg:int\ts:text\n'
    for i in $(seq 0 19999); do printf '%d\t%d\tx%d\n' "$i" "$((i % 10))" "$((i % 5))"; done
} > "$TMP/t.tsv"
"$BIN" copy "$TMP/t.tsv" "$TMP/t.zdb" >/dev/null 2>&1

stream() { "$BIN" stream --db="$TMP/t.zdb" --cache=4 "$1" 2>/dev/null; }

check "count(*)"            "20000"      "$(stream 'SELECT COUNT(*) FROM t')"
check "sum(k)"              "199990000"   "$(stream 'SELECT SUM(k) FROM t')"
check "sum(g)"              "90000"       "$(stream 'SELECT SUM(g) FROM t')"
check "min(k)"              "0"           "$(stream 'SELECT MIN(k) FROM t')"
check "max(k)"              "19999"       "$(stream 'SELECT MAX(k) FROM t')"
check "eq filter"           "1"           "$(stream 'SELECT COUNT(*) FROM t WHERE k = 12345')"
check "range filter"        "10"          "$(stream 'SELECT COUNT(*) FROM t WHERE k >= 19990')"
check "filter on other col" "2000"        "$(stream 'SELECT COUNT(*) FROM t WHERE g = 3')"
check "string predicate"    "16000"       "$(stream "SELECT COUNT(*) FROM t WHERE s <> 'x0'")"

# --- grouped aggregates (partitioned, mergeable state) ---
g() { "$BIN" stream --db="$TMP/t.zdb" --cache=4 "$1" 2>/dev/null; }
check "group count"      "0	2000"  "$(g 'SELECT g, COUNT(*) FROM t GROUP BY g ORDER BY g LIMIT 1')"
check "group by top sum" "9	20008000" "$(g 'SELECT g, SUM(k) FROM t GROUP BY g ORDER BY SUM(k) DESC LIMIT 1')"
check "group rows"       "10"       "$(g 'SELECT g, COUNT(*) FROM t GROUP BY g' | wc -l | tr -d ' ')"
check "string key top"   "x4	40006000" "$(g 'SELECT s, SUM(k) FROM t GROUP BY s ORDER BY SUM(k) DESC LIMIT 1')"
check "group + filter"   "0	1000"   "$(g 'SELECT g, COUNT(*) FROM t WHERE k >= 10000 GROUP BY g ORDER BY g LIMIT 1')"

# --- exact DISTINCT aggregates ---
check "count distinct"       "20000" "$(stream 'SELECT COUNT(DISTINCT k) FROM t')"
check "count distinct g"     "10"    "$(stream 'SELECT COUNT(DISTINCT g) FROM t')"
check "distinct with filter" "16000" "$(stream "SELECT COUNT(DISTINCT k) FROM t WHERE s <> 'x0'")"
check "grouped distinct"     "0	2000" "$(g 'SELECT g, COUNT(DISTINCT k) FROM t GROUP BY g ORDER BY g LIMIT 1')"
check "multi-agg row"        "0	19990000	2000	2000" "$(g 'SELECT g, SUM(k), COUNT(*), COUNT(DISTINCT k) FROM t GROUP BY g ORDER BY g LIMIT 1')"

# --- cost-based path selection: small table goes in-memory ---
plan="$("$BIN" stream --auto --db="$TMP/t.zdb" 'SELECT COUNT(DISTINCT k) FROM t' 2>&1 >/dev/null | grep -o 'streaming\|in-memory' | head -1)"
check "auto plan (small -> mem)" "in-memory" "$plan"

if [[ $fail -eq 0 ]]; then echo "stream: all checks passed"; exit 0; fi
echo "stream: $fail check(s) failed"
exit 1
