#!/usr/bin/env bash
# JIT correctness and speedup: the generated sum kernels must return the same
# result as the Zig loop, and the NEON16 kernel must beat the scalar Zig loop.
# Also checks the JIT group-count kernel (1000 groups, duplicates).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="$REPO/zig-out/bin/zhdb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[[ -x "$BIN" ]] || { echo "missing $BIN"; exit 1; }

python3 - "$TMP/hits.tsv" <<'PY'
import sys
with open(sys.argv[1], 'w') as f:
    f.write('#schema: UserID:int8\tAdvEngineID:int8\tResolutionWidth:int8\n')
    for i in range(1, 2000001):
        f.write(f"{i % 1000}\t{i % 2}\t{i % 100}\n")
PY
# ResolutionWidth is 0..99 repeating; 20k repetitions => 99,000,000.
EXPECTED_SUM=99000000

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: $2 != $3"; fail=$((fail+1)); fi }

"$BIN" jitbench --load="$TMP/hits.tsv" > /dev/null 2> "$TMP/jitbench.err"
check "JIT scalar/NEON sums match Zig" "check neon8=$EXPECTED_SUM neon16=$EXPECTED_SUM" "$(grep 'check neon' "$TMP/jitbench.err")"
check "JIT row count" "rows=2000000" "$(grep '^rows=' "$TMP/jitbench.err")"

"$BIN" jitgroup --load="$TMP/hits.tsv" --iters=3 > /dev/null 2> "$TMP/jitgroup.err"
check "JIT group count" "groups=1000 rows=2000000 sum_counts=2000000 iters=3 acc=3000" "$(grep 'groups=' "$TMP/jitgroup.err")"

for k in zig neon16; do
    /usr/bin/time -p "$BIN" jitloop --load="$TMP/hits.tsv" --kernel=$k --iters=5000 > /dev/null 2> "$TMP/$k.err"
    eval "${k}_real=$(awk '/^real/{print $2}' "$TMP/$k.err")"
    eval "${k}_acc=$(sed -n 's/.*acc=//p' "$TMP/$k.err")"
done
check "JIT loop acc matches Zig" "$zig_acc" "$neon16_acc"
python3 - "$zig_real" "$neon16_real" <<'PY' > "$TMP/speed"
import sys
z=float(sys.argv[1]); j=float(sys.argv[2])
print("ok" if j < z * 0.98 else "slow")
PY
check "NEON16 faster than Zig ($neon16_real s vs $zig_real s)" "ok" "$(cat "$TMP/speed")"

if [[ $fail -eq 0 ]]; then echo "jit: all checks passed"; exit 0; fi
echo "jit: $fail check(s) failed"; exit 1
