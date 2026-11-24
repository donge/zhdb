#!/usr/bin/env bash
# PostgreSQL 18.6 official regression: first milestone (test_setup).
#
#   test/pg18/run.sh                 # run test_setup
#   test/pg18/run.sh <name>          # run sql/<name>.sql against expected/<name>.out
#   test/pg18/run.sh --list          # show available tests
#
# The official SQL uses psql backslash commands (\getenv, \set) and COPY data
# files. prep.py expands those for execution; the displayed output is the
# official psql -a -q echo (input without blank lines). Query-result formatting
# will be added as later official tests are ported.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BIN="${ZHDB_BIN:-$REPO/zig-out/bin/zhdb}"
NAME="${1:-test_setup}"

if [[ "$NAME" == "--list" || "$NAME" == "-l" ]]; then
  (cd "$HERE/sql" && ls *.sql 2>/dev/null | sed 's/\.sql$//')
  exit 0
fi

SQL="$HERE/sql/$NAME.sql"
EXP="$HERE/expected/$NAME.out"
[[ -f "$SQL" ]] || { echo "missing $SQL"; exit 1; }
[[ -f "$EXP" ]] || { echo "missing $EXP"; exit 1; }
[[ -x "$BIN" ]] || { echo "missing $BIN (run: zig build --release=fast)"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# pg_regress supplies these variables to test_setup.sql; our data lives next
# to this runner instead of in the upstream source tree.
export PG_ABS_SRCDIR="$HERE"
export PG_LIBDIR="${PG_LIBDIR:-/tmp}"
export PG_DLSUFFIX="${PG_DLSUFFIX:-.so}"

python3 "$HERE/prep.py" "$SQL" > "$tmp/exec.sql" || exit 1
if [[ "$NAME" == "test_setup" ]]; then
  cat "$HERE/check_setup.sql" >> "$tmp/exec.sql"
fi

"$BIN" run "$tmp/exec.sql" > "$tmp/actual" 2> "$tmp/stderr"
status=$?
if [[ $status -ne 0 ]] || grep -q '^ERROR:' "$tmp/actual"; then
  echo "FAIL $NAME: execution failed (exit $status)"
  cat "$tmp/stderr" | head -20
  grep -n '^ERROR:' "$tmp/actual" | head -20
  exit 1
fi

if [[ "$NAME" == "test_setup" ]]; then
  if ! diff -u "$HERE/expected/test_setup_checks.out" "$tmp/actual" > "$tmp/check.diff"; then
    echo "FAIL $NAME: setup data check mismatch"
    head -80 "$tmp/check.diff"
    exit 1
  fi
fi

# The official .out is the psql -a -q echo plus any NOTICE lines. We do not
# emit inheritance NOTICEs yet, so compare with NOTICE lines normalized out.
grep -v '^NOTICE:' "$EXP" | grep -v '^[[:space:]]*$' > "$tmp/expected"
grep -v '^[[:space:]]*$' "$SQL" > "$tmp/echo"
if diff -u "$tmp/expected" "$tmp/echo" > "$tmp/diff"; then
  echo "pg18 $NAME: ok"
  exit 0
fi

echo "FAIL $NAME: output mismatch (official expected vs official SQL echo)"
head -80 "$tmp/diff"
exit 1
