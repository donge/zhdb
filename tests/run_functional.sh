#!/usr/bin/env bash
# Reuse the ZigHouse functional corpus against zhdb.
# Every .sql file runs in a fresh engine process, so per-file state is isolated.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="${TESTS_DIR:-$(cd "$REPO_DIR/../../zighouse/tests/functional" && pwd)}"
BIN="$REPO_DIR/zig-out/bin/zhdb"

# ClickHouse-only features that zhdb does not implement yet.
SKIP=(
  zh_28_import_parquet zh_29_compactor zh_31_materialized_view
  zh_34_system_tables
)

is_skipped() {
  local name="$1"
  for s in "${SKIP[@]}"; do [[ "$s" == "$name" ]] && return 0; done
  return 1
}

[[ -x "$BIN" ]] || { echo "missing $BIN (run: zig build)"; exit 1; }

pass=0; fail=0; skipped=0
failed_names=()

for sql_file in "$TESTS_DIR"/*.sql; do
  name="$(basename "$sql_file" .sql)"
  ref="$TESTS_DIR/$name.reference"
  [[ -f "$ref" ]] || continue
  if is_skipped "$name"; then
    skipped=$((skipped+1)); continue
  fi
  actual="$(mktemp)"
  "$BIN" run "$sql_file" >"$actual" 2>/tmp/zhdb-test-err.log
  if diff -u "$ref" "$actual" >/tmp/zhdb-diff.log 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed_names+=("$name")
    if [[ "${VERBOSE:-0}" == "1" ]]; then
      echo "FAIL $name"; cat /tmp/zhdb-diff.log; cat /tmp/zhdb-test-err.log
    fi
  fi
  rm -f "$actual"
done

echo "zhdb functional: $pass passed, $fail failed, $skipped skipped"
if (( fail > 0 )); then
  printf 'failed: %s\n' "${failed_names[*]}"
  exit 1
fi
