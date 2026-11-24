-- Expression semantics: three-valued logic, CASE, COALESCE, NULLIF, IN.
CREATE TABLE expr_t (id INT, v INT, s TEXT);
INSERT INTO expr_t VALUES (1, 10, 'a'), (2, NULL, NULL), (3, 30, 'c');

SELECT 'three-valued' AS section;
SELECT id, v = NULL, v <> NULL, v IS NULL, v IS NOT NULL FROM expr_t ORDER BY id;
SELECT id, v IN (10, NULL), v NOT IN (10, NULL) FROM expr_t ORDER BY id;
SELECT id, v BETWEEN 10 AND 30 FROM expr_t ORDER BY id;

SELECT 'case' AS section;
SELECT id, CASE WHEN v IS NULL THEN 'unknown' WHEN v > 20 THEN 'high' ELSE 'low' END FROM expr_t ORDER BY id;
SELECT id, CASE v WHEN 10 THEN 'ten' ELSE 'other' END FROM expr_t ORDER BY id;

SELECT 'coalesce-nullif' AS section;
SELECT id, COALESCE(v, -1), COALESCE(s, 'none') FROM expr_t ORDER BY id;
SELECT id, NULLIF(v, 10), NULLIF(s, 'c') FROM expr_t ORDER BY id;

SELECT 'arithmetic-null' AS section;
SELECT id, v + 1, v * 2, v / 0 FROM expr_t ORDER BY id;

DROP TABLE expr_t;
