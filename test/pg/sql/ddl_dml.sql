-- DDL and DML: create/insert/update/delete/truncate/drop.
DROP TABLE IF EXISTS dml_t;
CREATE TABLE dml_t (id INT, v TEXT);
INSERT INTO dml_t VALUES (1, 'a'), (2, 'b'), (3, 'c');
SELECT id, v FROM dml_t ORDER BY id;

UPDATE dml_t SET v = upper(v) WHERE id = 2;
SELECT id, v FROM dml_t ORDER BY id;

UPDATE dml_t SET v = NULL WHERE id = 3;
SELECT id, v FROM dml_t ORDER BY id;

DELETE FROM dml_t WHERE id = 1;
SELECT id, v FROM dml_t ORDER BY id;

TRUNCATE TABLE dml_t;
SELECT COUNT(*) FROM dml_t;

DROP TABLE dml_t;
