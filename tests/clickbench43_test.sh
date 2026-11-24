#!/usr/bin/env bash
# ClickBench 43-query regression: every official query must execute and return
# exactly the same (order-insensitive) row set as the golden baseline.
#
#   tests/clickbench43_test.sh            # verify
#   tests/clickbench43_test.sh --update   # regenerate the golden file
#
# Uses the 1M-row slice (bench/hits_1m_ext.tsv) so the check takes a few seconds;
# the 10M/43 value verification lives in the benchmark workflow
# (ZHDB_DUMP_ALL=1 bench/clickbench_43.sql, diffed against DuckDB).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UMBRA_DIR="$(cd "$REPO_DIR/.." && pwd)"
BIN="$REPO_DIR/zig-out/bin/zhdb"
# Default to the 1M slice; point CLICKBENCH_DATA at bench/hits_10m_25col.tsv for the full run.
DATA="${CLICKBENCH_DATA:-$UMBRA_DIR/bench/hits_1m_ext.tsv}"
QUERIES="$UMBRA_DIR/bench/clickbench_43.sql"
GOLDEN="$SCRIPT_DIR/clickbench43.golden"

[[ -x "$BIN" ]] || { echo "missing $BIN (run: zig build)"; exit 1; }
[[ -f "$DATA" ]] || { echo "missing $DATA"; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
ZHDB_DUMP_ALL=1 ZHDB_COL_LOAD=1 "$BIN" bench --load="$DATA" --repeat=1 "$QUERIES" 2>"$tmp" >/dev/null

# Build one line per query: qN<TAB>rows<TAB>sha256(sorted result rows).
python3 - "$tmp" > "$tmp.summary" <<'PY'
import hashlib, re, sys
qs = {}
cur = None
for line in open(sys.argv[1], errors="replace"):
    s = line.rstrip("\n")
    if s.startswith("   -> "):
        if cur is not None:
            qs[cur].append(s[6:])
        continue
    m = re.match(r"^q(\d+)\t(?:[\d.]+ ms\t)?(\d+)(?: rows)?$", s)
    if m:
        cur = int(m.group(1))
        qs[cur] = []
for q in sorted(qs):
    rows = sorted(qs[q])
    h = hashlib.sha256("\n".join(rows).encode()).hexdigest()[:16]
    print("q%d\t%d\t%s" % (q, len(rows), h))
PY

if [[ "${1:-}" == "--update" ]]; then
  cp "$tmp.summary" "$GOLDEN"
  echo "clickbench 43: golden updated ($(wc -l < "$GOLDEN" | tr -d ' ') queries)"
  exit 0
fi

[[ -f "$GOLDEN" ]] || { echo "missing $GOLDEN (run with --update)"; exit 1; }

# These official queries end in LIMIT/OFFSET without a total ordering. When
# the cutoff falls inside a run of equal counts, the exact rows returned are
# implementation-defined (the 10M value check documents the same tie choices).
# Check the row count for them, not the row-set hash.
tie_sensitive() {
  case "$1" in
    q18|q21|q27|q30|q31|q33|q39|q40|q41) return 0 ;;
    *) return 1 ;;
  esac
}

fail=0
executed=0
while IFS=$'\t' read -r q rows hash; do
  executed=$((executed + 1))
  want="$(grep -P "^$q\t" "$GOLDEN" 2>/dev/null || awk -v k="$q" -F'\t' '$1==k' "$GOLDEN")"
  if [[ -z "$want" ]]; then
    echo "FAIL $q: not in golden"; fail=$((fail + 1))
  elif tie_sensitive "$q"; then
    want_rows="$(printf '%s' "$want" | cut -f2)"
    if [[ "$want_rows" != "$rows" ]]; then
      echo "FAIL $q: got rows=$rows, want rows=$want_rows (tie-sensitive query)"
      fail=$((fail + 1))
    fi
  elif [[ "$want" != "$q"$'\t'"$rows"$'\t'"$hash" ]]; then
    echo "FAIL $q: got rows=$rows hash=$hash, want $want"
    fail=$((fail + 1))
  fi
done < "$tmp.summary"

if [[ "$executed" -ne 43 ]]; then
  echo "FAIL: executed $executed queries, expected 43"; fail=$((fail + 1))
fi
if [[ "$fail" -eq 0 ]]; then
  echo "clickbench 43: $executed/43 queries executed, result checksums match golden"
  exit 0
fi
echo "clickbench 43: $fail failure(s)"
exit 1
