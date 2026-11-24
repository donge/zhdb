#!/usr/bin/env bash
# PostgreSQL 18.6 official regression harness.
#
#   test/pg18/run.sh                 # run schedule (test_setup, char, varchar)
#   test/pg18/run.sh <name>          # one test
#   test/pg18/run.sh --list
#
# test_setup runs through `zhdb run` (it has no query output). Tests with
# result rows use the wire-protocol psql formatter (psql.py) against a
# throwaway zhdb server, seeded with the official test_setup fixture.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BIN="${ZHDB_BIN:-$REPO/zig-out/bin/zhdb}"

if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
  (cd "$HERE/sql" && ls *.sql 2>/dev/null | sed 's/\.sql$//')
  exit 0
fi

if [[ $# -eq 0 ]]; then
  fail=0
  while IFS= read -r n; do
    [[ -z "$n" || "$n" == \#* ]] && continue
    "$0" "$n" || fail=1
  done < "$HERE/schedule"
  exit $fail
fi

NAME="$1"
SQL="$HERE/sql/$NAME.sql"
EXP="$HERE/expected/$NAME.out"
[[ -f "$SQL" ]] || { echo "missing $SQL"; exit 1; }
[[ -f "$EXP" ]] || { echo "missing $EXP"; exit 1; }
[[ -x "$BIN" ]] || { echo "missing $BIN (run: zig build --release=fast)"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null' EXIT

export PG_ABS_SRCDIR="$HERE"
export PG_LIBDIR="${PG_LIBDIR:-/tmp}"
export PG_DLSUFFIX="${PG_DLSUFFIX:-.so}"

# Official expected output is psql -a -q echo: input minus blank lines, plus
# result tables. NOTICE lines are normalized until notices are wired through.
if [[ "$NAME" == "test_setup" ]]; then
  grep -v '^NOTICE:' "$EXP" | grep -v '^[[:space:]]*$' > "$tmp/expected"
else
  grep -v '^NOTICE:' "$EXP" > "$tmp/expected"
fi

if [[ "$NAME" == "test_setup" ]]; then
  python3 "$HERE/prep.py" "$SQL" > "$tmp/exec_raw.sql" || exit 1
  grep -v '^\\_echo ' "$tmp/exec_raw.sql" > "$tmp/exec.sql" || true
  cat "$HERE/check_setup.sql" >> "$tmp/exec.sql"
  "$BIN" run "$tmp/exec.sql" > "$tmp/actual" 2> "$tmp/stderr"
  status=$?
  if [[ $status -ne 0 ]] || grep -q '^ERROR:' "$tmp/actual"; then
    echo "FAIL $NAME: execution failed (exit $status)"
    head -20 "$tmp/stderr"
    grep -n '^ERROR:' "$tmp/actual" | head -20
    exit 1
  fi
  if ! diff -u "$HERE/expected/test_setup_checks.out" "$tmp/actual" > "$tmp/check.diff"; then
    echo "FAIL $NAME: setup data check mismatch"
    head -80 "$tmp/check.diff"
    exit 1
  fi
  grep -v '^[[:space:]]*$' "$SQL" > "$tmp/echo"
  if diff -u "$tmp/expected" "$tmp/echo" > "$tmp/diff"; then
    echo "pg18 $NAME: ok"
    exit 0
  fi
  echo "FAIL $NAME: output mismatch"
  head -80 "$tmp/diff"
  exit 1
fi

# Port for the throwaway server.
PORT=$((20000 + ($$ % 20000)))
python3 - "$PORT" <<'PY' &
import socket, sys, time
port=int(sys.argv[1])
for _ in range(100):
    try:
        s=socket.create_connection(("127.0.0.1", port), timeout=0.1); s.close(); sys.exit(0)
    except OSError: time.sleep(0.05)
sys.exit(1)
PY
WAIT_PID=$!
"$BIN" serve --port="$PORT" > "$tmp/server.log" 2>&1 &
SERVER_PID=$!
wait "$WAIT_PID" || { echo "FAIL $NAME: server did not start"; cat "$tmp/server.log"; exit 1; }

python3 "$HERE/prep.py" "$HERE/sql/test_setup.sql" > "$tmp/setup.sql" || exit 1
python3 "$HERE/psql.py" "$PORT" "$tmp/setup.sql" --fail-on-error > /dev/null || {
  echo "FAIL $NAME: test_setup failed"; exit 1;
}
python3 "$HERE/prep.py" "$SQL" > "$tmp/test.sql" || exit 1
python3 "$HERE/psql.py" "$PORT" "$tmp/test.sql" --echo > "$tmp/actual" 2> "$tmp/stderr" || {
  echo "FAIL $NAME: psql client failed"; cat "$tmp/stderr" | head -20; exit 1;
}

if diff -u "$tmp/expected" "$tmp/actual" > "$tmp/diff"; then
  echo "pg18 $NAME: ok"
  exit 0
fi
echo "FAIL $NAME: output mismatch"
head -100 "$tmp/diff"
exit 1
