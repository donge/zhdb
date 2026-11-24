-- Set operations with duplicates and NULLs.
CREATE TABLE set_a (x INT);
CREATE TABLE set_b (x INT);
INSERT INTO set_a VALUES (1), (2), (2), (3), (NULL);
INSERT INTO set_b VALUES (2), (3), (3), (4), (NULL);

SELECT 'union' AS section;
SELECT x FROM set_a UNION SELECT x FROM set_b ORDER BY x;

SELECT 'union-all' AS section;
SELECT x FROM set_a UNION ALL SELECT x FROM set_b ORDER BY x;

SELECT 'intersect' AS section;
SELECT x FROM set_a INTERSECT SELECT x FROM set_b ORDER BY x;

SELECT 'except' AS section;
SELECT x FROM set_a EXCEPT SELECT x FROM set_b ORDER BY x;

SELECT 'projection' AS section;
SELECT x, x + 1 FROM set_a UNION ALL SELECT x, x + 10 FROM set_b ORDER BY 1, 2;

DROP TABLE set_b;
DROP TABLE set_a;
