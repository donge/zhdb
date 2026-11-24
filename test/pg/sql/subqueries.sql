-- Subqueries: IN, EXISTS and FROM subqueries.
CREATE TABLE sq_a (id INT, v INT);
CREATE TABLE sq_b (id INT, v INT);
INSERT INTO sq_a VALUES (1, 10), (2, 20), (3, 30), (4, NULL);
INSERT INTO sq_b VALUES (2, 200), (3, 300), (5, 500);

SELECT 'in' AS section;
SELECT id FROM sq_a WHERE id IN (SELECT id FROM sq_b) ORDER BY id;
SELECT id FROM sq_a WHERE id NOT IN (SELECT id FROM sq_b) ORDER BY id;

SELECT 'exists' AS section;
SELECT id FROM sq_a WHERE EXISTS (SELECT 1 FROM sq_b WHERE sq_b.id = sq_a.id) ORDER BY id;
SELECT id FROM sq_a WHERE NOT EXISTS (SELECT 1 FROM sq_b WHERE sq_b.id = sq_a.id) ORDER BY id;

SELECT 'from-subquery' AS section;
SELECT x.id FROM (SELECT id FROM sq_b WHERE v >= 300) AS x ORDER BY x.id;

DROP TABLE sq_b;
DROP TABLE sq_a;
