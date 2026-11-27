#!/usr/bin/env bash
# `timestamp with time zone` must keep the date part; it used to be matched as
# `time with time zone` because isTimetzTypeName() only checked the "time" prefix.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../zig-out/bin/zhdb"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -x "$BIN" ]] || { echo "missing $BIN (run: zig build --release=fast)"; exit 1; }

cat > "$TMP/tz.sql" <<'SQL'
CREATE TABLE tz_long (a TIMESTAMP WITH TIME ZONE);
INSERT INTO tz_long VALUES ('2025-11-26 18:00:00+08');
SELECT a FROM tz_long;
CREATE TABLE tz_short (a TIMESTAMPTZ);
INSERT INTO tz_short VALUES ('2025-11-26 18:00:00+08');
SELECT a FROM tz_short;
SQL

actual="$("$BIN" run "$TMP/tz.sql" 2>/dev/null)"
expected=$'2025-11-26 18:00:00+08\n2025-11-26 18:00:00+08'

if [[ "$actual" == "$expected" ]]; then
  echo "timestamp with time zone: ok"
  exit 0
fi
echo "timestamp with time zone: FAIL"
echo "expected:"
printf '%s\n' "$expected"
echo "actual:"
printf '%s\n' "$actual"
exit 1
