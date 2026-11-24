#!/usr/bin/env bash
# Core SQL semantics regression: set operations, correlated subqueries, joins,
# aggregates and NULL handling. Runs a single script through the row engine and
# diffs against a reference file, so a silent semantic change fails loudly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$REPO_DIR/zig-out/bin/zhdb"

[[ -x "$BIN" ]] || { echo "missing $BIN (run: zig build)"; exit 1; }

actual="$(mktemp)"
trap 'rm -f "$actual"' EXIT

cat > "$actual.sql" <<'SQL'
CREATE TABLE a (id INT, x INT);
CREATE TABLE b (id INT, y INT);
INSERT INTO a VALUES (1,10),(2,20),(3,30);
INSERT INTO b VALUES (1,100),(3,300),(4,400);

SELECT 'UNION' AS t;
SELECT id FROM a UNION SELECT id FROM b ORDER BY id;
SELECT 'UNION ALL' AS t;
SELECT id FROM a UNION ALL SELECT id FROM b ORDER BY id;
SELECT 'INTERSECT' AS t;
SELECT id FROM a INTERSECT SELECT id FROM b ORDER BY id;
SELECT 'EXCEPT' AS t;
SELECT id FROM a EXCEPT SELECT id FROM b ORDER BY id;

SELECT 'INNER JOIN' AS t;
SELECT a.id, b.y FROM a JOIN b ON a.id = b.id ORDER BY a.id;
SELECT 'LEFT JOIN' AS t;
SELECT a.id, b.y FROM a LEFT JOIN b ON a.id = b.id ORDER BY a.id;
SELECT 'JOIN COUNT' AS t;
SELECT COUNT(*) FROM a JOIN b ON a.id = b.id;

SELECT 'CORR IN' AS t;
SELECT id FROM a WHERE id IN (SELECT id FROM b WHERE y > 150) ORDER BY id;
SELECT 'CORR EXISTS' AS t;
SELECT id FROM a WHERE EXISTS (SELECT 1 FROM b WHERE b.id = a.id) ORDER BY id;
SELECT 'CORR NOT EXISTS' AS t;
SELECT id FROM a WHERE NOT EXISTS (SELECT 1 FROM b WHERE b.id = a.id) ORDER BY id;

SELECT 'GROUP' AS t;
SELECT x % 20, COUNT(*), SUM(x) FROM a GROUP BY x % 20 HAVING COUNT(*) > 0 ORDER BY 1;
SELECT 'DISTINCT' AS t;
SELECT DISTINCT x FROM a ORDER BY x;
SELECT 'NULL' AS t;
SELECT (NULL = NULL), (NULL IS NULL), (1 = NULL);
SELECT 'LIMIT-OFFSET' AS t;
SELECT id FROM a ORDER BY id LIMIT 2 OFFSET 1;
SQL

"$BIN" run "$actual.sql" > "$actual" 2>/tmp/zhdb-semantics-err.log
if diff -u "$SCRIPT_DIR/sql_semantics.reference" "$actual" > /tmp/zhdb-semantics-diff.log; then
  echo "sql semantics: all checks passed"
  exit 0
fi
echo "sql semantics: MISMATCH"
head -40 /tmp/zhdb-semantics-diff.log
exit 1
