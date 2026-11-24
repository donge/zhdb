-- String functions and pattern matching.
CREATE TABLE str_t (id INT, v TEXT);
INSERT INTO str_t VALUES
    (1, 'Alpha'),
    (2, 'beta'),
    (3, 'GAMMA'),
    (4, ''),
    (5, NULL);

SELECT 'case-functions' AS section;
SELECT id, upper(v), lower(v) FROM str_t ORDER BY id;

SELECT 'length-substr' AS section;
SELECT id, length(v), substr(v, 1, 2), substr(v, 2) FROM str_t ORDER BY id;

SELECT 'concat' AS section;
SELECT id, concat(v, '!'), concat('x', v) FROM str_t ORDER BY id;

SELECT 'like' AS section;
SELECT id FROM str_t WHERE v LIKE '%a' ORDER BY id;
SELECT id FROM str_t WHERE v LIKE 'A%' ORDER BY id;
SELECT id FROM str_t WHERE v NOT LIKE '%a%' ORDER BY id;

DROP TABLE str_t;
