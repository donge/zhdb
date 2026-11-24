#!/usr/bin/env bash
# TLS 1.3 end-to-end: SSLRequest -> 'S' -> handshake -> PG startup -> SELECT 1.
# Uses openssl s_client (OpenSSL 3.x) as an independent TLS implementation.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="$REPO/zig-out/bin/zhdb"
PORT="${1:-56190}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; pkill -f "zhdb serve --port=$PORT" 2>/dev/null' EXIT

[[ -x "$BIN" ]] || { echo "missing $BIN (run: zig build --release=fast)"; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found"; exit 1; }

("$BIN" serve --port="$PORT" --tls >"$TMP/server.log" 2>&1 &)
sleep 1.5

python3 - "$TMP/req.bin" <<'PY'
import struct, sys
params = b"user\x00zhdb\x00\x00"
startup = struct.pack(">I", len(params) + 8) + b"\x00\x03\x00\x00" + params
q = b"SELECT 1\x00"
msg = b"Q" + struct.pack(">I", len(q) + 4) + q
open(sys.argv[1], "wb").write(startup + msg)
PY

(cat "$TMP/req.bin"; sleep 1.5) | timeout 10 openssl s_client -starttls postgres -connect "127.0.0.1:$PORT" -tls1_3 -brief 2>"$TMP/client.err" >"$TMP/resp.bin"

fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=$((fail+1)); fi }

# AuthenticationOk: 'R' 00 00 00 08 00 00 00 00
check "startup auth ok" "yes" "$(grep -qa $'\x52\x00\x00\x00\x08\x00\x00\x00\x00' "$TMP/resp.bin" && echo yes || echo no)"
check "query result 1" "yes" "$(grep -qa $'\x00\x00\x00\x011' "$TMP/resp.bin" && echo yes || echo no)"
check "command complete" "yes" "$(grep -qa 'SELECT 1' "$TMP/resp.bin" && echo yes || echo no)"
check "tls1.3 negotiated" "yes" "$(grep -q "TLSv1.3" "$TMP/client.err" && echo yes || echo no)"
check "no tls alert" "yes" "$(grep -qE "alert|SSL routines" "$TMP/client.err" && echo no || echo yes)"

if [[ $fail -eq 0 ]]; then echo "tls: all checks passed"; exit 0; fi
echo "tls: $fail check(s) failed"
cat "$TMP/client.err" | head -5
exit 1
