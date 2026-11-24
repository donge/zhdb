#!/usr/bin/env bash
# pg_regress-style runner for zhdb.
#
#   test/run.sh                 # run every suite (pg, analytics)
#   test/run.sh pg              # one suite
#   test/run.sh -k              # keep going after a failure (default: also keeps)
#   test/run.sh --update        # rewrite expected/*.out from the current engine
#
# A suite is test/<name>/ with `sql/*.sql` + `expected/*.out` and an optional
# `schedule` file listing the test names in order (default: alphabetical).
#
# A test file may start with a directive line
#   -- load: data/sales.tsv
# which loads that TSV (columnar streaming loader) and runs the queries through
# `zhdb bench`, capturing the result rows. Otherwise the file runs through
# `zhdb run` (row engine, TSV output, errors printed as `ERROR: <name>`).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="${ZHDB_BIN:-$REPO/zig-out/bin/zhdb}"
UPDATE=0
SUITES=()

for a in "$@"; do
  case "$a" in
    --update) UPDATE=1 ;;
    -k) ;;
    -h|--help)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "unknown option: $a"; exit 2 ;;
    *) SUITES+=("$a") ;;
  esac
done
[[ ${#SUITES[@]} -eq 0 ]] && SUITES=(pg analytics)

[[ -x "$BIN" ]] || { echo "missing $BIN (run: zig build --release=fast)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

pass=0; fail=0; skip=0; failed_names=()

# Extract the result rows from `zhdb bench` stderr (the `   -> ` lines).
extract_rows() {
  python3 - "$1" <<'PY'
import sys, re
out = []
for line in open(sys.argv[1], errors="replace"):
    if line.startswith("   -> "):
        out.append(line[6:].rstrip("\n"))
    elif line.startswith("q") and "\tERROR\t" in line:
        out.append("ERROR: " + line.split("\t")[2].strip())
sys.stdout.write("\n".join(out))
if out:
    sys.stdout.write("\n")
PY
}

run_one() {
  local suite="$1" name="$2"
  local sql="$HERE/$suite/sql/$name.sql"
  local exp="$HERE/$suite/expected/$name.out"
  local actual
  actual="$(mktemp)"

  local load
  load="$(sed -n '1s/^-- *load: *//p' "$sql")"
  if [[ -n "$load" ]]; then
    local data="$HERE/$suite/$load"
    if [[ ! -f "$data" ]]; then
      echo "SKIP $suite/$name (missing $load)"; skip=$((skip + 1)); rm -f "$actual"; return
    fi
    ZHDB_DUMP_ALL=1 ZHDB_COL_LOAD=1 "$BIN" bench --load="$data" --repeat=1 "$sql" \
      >/dev/null 2>"$actual.err"
    extract_rows "$actual.err" > "$actual"
    rm -f "$actual.err"
  else
    # Row engine: single process, statements in order (transactions work).
    "$BIN" run "$sql" >"$actual" 2>&1
  fi

  if [[ "$UPDATE" -eq 1 ]]; then
    mkdir -p "$HERE/$suite/expected"
    cp "$actual" "$exp"
    echo "updated $suite/$name"
    rm -f "$actual"
    return
  fi
  if [[ ! -f "$exp" ]]; then
    echo "FAIL $suite/$name (missing $suite/expected/$name.out; run --update)"
    fail=$((fail + 1)); failed_names+=("$suite/$name"); rm -f "$actual"; return
  fi
  if diff -u "$exp" "$actual" > /tmp/zhdb-test-diff.log 2>&1; then
    pass=$((pass + 1))
  else
    echo "FAIL $suite/$name"
    head -30 /tmp/zhdb-test-diff.log
    fail=$((fail + 1)); failed_names+=("$suite/$name")
  fi
  rm -f "$actual"
}

for suite in "${SUITES[@]}"; do
  dir="$HERE/$suite"
  [[ -d "$dir/sql" ]] || { echo "SKIP suite $suite (no sql/)"; continue; }
  names=()
  if [[ -f "$dir/schedule" ]]; then
    while IFS= read -r n; do names+=("$n"); done < <(grep -vE '^[[:space:]]*(#|$)' "$dir/schedule")
  else
    while IFS= read -r n; do names+=("$n"); done < <(cd "$dir/sql" && ls *.sql 2>/dev/null | sed 's/\.sql$//')
  fi
  for name in "${names[@]}"; do
    run_one "$suite" "$name"
  done
done

echo
if [[ "$UPDATE" -eq 1 ]]; then
  echo "expected files updated"
  exit 0
fi
if [[ $fail -eq 0 ]]; then
  echo "zhdb tests: $pass passed, 0 failed, $skip skipped"
  exit 0
fi
echo "zhdb tests: $pass passed, $fail failed, $skip skipped"
printf '  failed: %s\n' "${failed_names[*]}"
exit 1
