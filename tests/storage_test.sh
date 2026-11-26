#!/usr/bin/env bash
# Buffer-manager / sparse-index test: build a small ZDB1, then verify that a
# point lookup (a) returns the right row count and (b) is pruned by the
# block-level min/max index.
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

# 20000 rows with a sorted key, so blocks have disjoint [min,max].
{
    printf '#schema: k:int\tpad:text\n'
    for i in $(seq 0 19999); do printf '%d\tx%d\n' "$i" "$((i % 97))"; done
} > "$TMP/sorted.tsv"

"$BIN" copy "$TMP/sorted.tsv" "$TMP/sorted.zdb" >/dev/null 2>&1

out="$("$BIN" lookup --db="$TMP/sorted.zdb" --column=k --value=12345 --cache=4)"
check "matched rows" "1" "$(grep 'matched rows' <<<"$out" | awk '{print $4}')"
check "blocks examined" "1" "$(grep 'blocks' <<<"$out" | awk '{print $3}')"
check "pruned > 0" "yes" "$(grep 'blocks' <<<"$out" | grep -q 'pruned [1-9]' && echo yes || echo no)"

out="$("$BIN" lookup --db="$TMP/sorted.zdb" --column=k --value=999999 --cache=4)"
check "out-of-range rows" "0" "$(grep 'matched rows' <<<"$out" | awk '{print $4}')"
check "out-of-range blocks" "0" "$(grep 'blocks' <<<"$out" | awk '{print $3}')"

# `stat` must report the block count and the compressed byte size.
out="$("$BIN" stat "$TMP/sorted.zdb")"
check "stat version" "9" "$(grep -o 'version [0-9]*' <<<"$out" | awk '{print $2}')"
check "stat rows" "20000" "$(grep -o '[0-9]* rows' <<<"$out" | awk '{print $1}')"

# --- lazy bench: eligible aggregates stream, else explicit error ---
printf 'SELECT COUNT(*) FROM t;\nSELECT SUM(k) FROM t;\nSELECT k, COUNT(*) FROM t GROUP BY k;\n' > "$TMP/lazy.sql"
lazy_out="$("$BIN" bench --db="$TMP/sorted.zdb" --mem-budget=1K --repeat=1 "$TMP/lazy.sql" 2>&1)"
check "lazy count" "20000" "$(grep -B1 '^q1' <<<"$lazy_out" | head -1 | sed 's/.*-> //')"
check "lazy sum"   "199990000" "$(grep -B1 '^q2' <<<"$lazy_out" | head -1 | sed 's/.*-> //')"
check "lazy rejects grouped query" "yes" "$(grep -q 'q3.*NotLazyEligible' <<<"$lazy_out" && echo yes || echo no)"

# --- persistent key index (sorted keys + posting lists) ---
"$BIN" index --db="$TMP/sorted.zdb" --column=k --out="$TMP/k.idx" >/dev/null
idx_out="$("$BIN" lookup --db="$TMP/sorted.zdb" --column=k --value=12345 --index="$TMP/k.idx")"
check "index point lookup" "1" "$(grep 'matched rows' <<<"$idx_out" | awk '{print $4}')"
check "index is used" "yes" "$(grep -q 'index        : keys=' <<<"$idx_out" && echo yes || echo no)"
range_idx="$("$BIN" lookup --db="$TMP/sorted.zdb" --column=k --value=100 --hi=110 --index="$TMP/k.idx" | grep 'matched rows' | awk '{print $4}')"
range_scan="$("$BIN" lookup --db="$TMP/sorted.zdb" --column=k --value=100 --hi=110 | grep 'matched rows' | awk '{print $4}')"
check "index range == scan" "$range_scan" "$range_idx"
check "index range rows" "11" "$range_idx"

if [[ $fail -eq 0 ]]; then echo "storage: all checks passed"; exit 0; fi
echo "storage: $fail check(s) failed"
exit 1
