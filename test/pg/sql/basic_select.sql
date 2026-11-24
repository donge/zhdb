-- PostgreSQL core: literals, arithmetic, predicates, ORDER BY, LIMIT.
SELECT 'literals' AS section;
SELECT 1, -2, 3.5, 'text', true, false;

SELECT 'arithmetic' AS section;
SELECT 1 + 2, 7 - 3, 6 * 7, 7 / 2, 7 % 2, (1 + 2) * 3, 7.0 / 2;

SELECT 'comparisons' AS section;
SELECT 1 = 1, 1 <> 2, 1 < 2, 2 <= 2, 2 > 1, 2 >= 3;
SELECT true, false, NOT true, NOT false;

SELECT 'precedence' AS section;
SELECT 1 + 2 * 3, (1 + 2) * 3, NOT 1 = 2, 1 = 1 AND 2 = 2 OR 1 = 2;

SELECT 'nulls' AS section;
SELECT NULL, NULL = NULL, NULL <> NULL, 1 = NULL, NULL IS NULL, NULL IS NOT NULL;
SELECT NULL AND TRUE, NULL AND FALSE, NULL OR TRUE, NULL OR FALSE, NOT NULL;

SELECT 'order-limit' AS section;
CREATE TABLE basic_t (id INT, v TEXT);
INSERT INTO basic_t VALUES (3, 'c'), (1, 'a'), (2, 'b'), (4, NULL);
SELECT id, v FROM basic_t ORDER BY id;
SELECT id, v FROM basic_t ORDER BY id DESC;
SELECT id FROM basic_t ORDER BY id LIMIT 2 OFFSET 1;
SELECT DISTINCT v FROM basic_t ORDER BY v;

SELECT 'where' AS section;
SELECT id FROM basic_t WHERE id >= 2 AND id < 4 ORDER BY id;
SELECT id FROM basic_t WHERE id IN (1, 4) ORDER BY id;
SELECT id FROM basic_t WHERE id BETWEEN 2 AND 3 ORDER BY id;
SELECT id FROM basic_t WHERE v LIKE 'a%' ORDER BY id;

DROP TABLE basic_t;
