-- Join variants: inner, outer and cross joins, including NULL keys.
CREATE TABLE jl (id INT, v TEXT);
CREATE TABLE jr (id INT, w TEXT);
INSERT INTO jl VALUES (1, 'l1'), (2, 'l2'), (3, 'l3');
INSERT INTO jr VALUES (1, 'r1'), (3, 'r3'), (4, 'r4');

SELECT 'inner' AS section;
SELECT jl.id, jl.v, jr.w FROM jl JOIN jr ON jl.id = jr.id ORDER BY jl.id;

SELECT 'left' AS section;
SELECT jl.id, jr.w FROM jl LEFT JOIN jr ON jl.id = jr.id ORDER BY jl.id;

SELECT 'right' AS section;
SELECT jl.id, jr.w FROM jl RIGHT JOIN jr ON jl.id = jr.id ORDER BY jr.w;

SELECT 'full' AS section;
SELECT jl.id, jl.v, jr.w FROM jl FULL JOIN jr ON jl.id = jr.id ORDER BY jl.id, jr.w;

SELECT 'cross' AS section;
SELECT jl.id, jr.id FROM jl CROSS JOIN jr WHERE jl.id = 1 AND jr.id <= 2 ORDER BY jr.id;

SELECT 'null-key' AS section;
CREATE TABLE jn (k INT, v TEXT);
INSERT INTO jn VALUES (NULL, 'null-key'), (1, 'one');
SELECT jl.id, jn.v FROM jl JOIN jn ON jl.id = jn.k ORDER BY jl.id;

DROP TABLE jn;
DROP TABLE jr;
DROP TABLE jl;
