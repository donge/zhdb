#!/usr/bin/env bash
# DuckDB 2.0.1 side of the official 10M/43 ClickBench comparison.
#
#   tests/duckdb_43_10m.sh [repeat] [db-path]
#
# Data/query defaults point at the workspace bench/ directory:
#   ../bench/hits_10m_25col.tsv, ../bench/clickbench_43.sql
# Override with DUCKDB_DATA / DUCKDB_QUERIES / DUCKDB_PYTHON.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"
PY="${DUCKDB_PYTHON:-$WS/.venv-duckdb201/bin/python}"
DATA="${DUCKDB_DATA:-$WS/bench/hits_10m_25col.tsv}"
QUERIES="${DUCKDB_QUERIES:-$WS/bench/clickbench_43.sql}"
REPEAT="${1:-3}"
DB="${2:-}"

[[ -x "$PY" ]] || { echo "missing $PY (create ../.venv-duckdb201 with duckdb 2.0.1)" >&2; exit 1; }
[[ -f "$DATA" ]] || { echo "missing $DATA" >&2; exit 1; }
[[ -f "$QUERIES" ]] || { echo "missing $QUERIES" >&2; exit 1; }

if [[ -n "$DB" ]]; then
  "$PY" "$HERE/duckdb_43_10m.py" "$DATA" "$QUERIES" "$REPEAT" "$DB"
else
  "$PY" "$HERE/duckdb_43_10m.py" "$DATA" "$QUERIES" "$REPEAT"
fi
