-- Error paths must be explicit and stable (never a silently empty result).
SELECT * FROM missing_table;
CREATE TABLE err_t (id INT);
SELECT no_such_column FROM err_t;
INSERT INTO err_t VALUES (1, 2);
SELECT 1 +;
DROP TABLE err_t;
