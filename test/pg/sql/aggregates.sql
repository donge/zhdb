-- Aggregates, GROUP BY, HAVING and NULL handling.
CREATE TABLE agg_t (g TEXT, v INT, f FLOAT);
INSERT INTO agg_t VALUES
    ('a', 1, 1.5),
    ('a', 2, 2.5),
    ('a', NULL, NULL),
    ('b', 4, 4.0),
    ('b', 4, NULL),
    (NULL, 5, 5.5);

SELECT 'global' AS section;
SELECT COUNT(*), COUNT(v), COUNT(f), SUM(v), AVG(v), MIN(v), MAX(v) FROM agg_t;

SELECT 'group' AS section;
SELECT g, COUNT(*), COUNT(v), SUM(v), AVG(v), MIN(v), MAX(v)
FROM agg_t GROUP BY g ORDER BY g;

SELECT 'having' AS section;
SELECT g, COUNT(*) FROM agg_t GROUP BY g HAVING COUNT(*) >= 2 ORDER BY g;

SELECT 'distinct' AS section;
SELECT COUNT(DISTINCT v), COUNT(DISTINCT g) FROM agg_t;

SELECT 'empty' AS section;
SELECT COUNT(*), SUM(v), AVG(v), MIN(v), MAX(v) FROM agg_t WHERE v > 100;

SELECT 'group-expression' AS section;
SELECT v % 2, COUNT(*) FROM agg_t WHERE v IS NOT NULL GROUP BY v % 2 ORDER BY 1;

DROP TABLE agg_t;
