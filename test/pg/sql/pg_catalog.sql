-- Basic pg_catalog visibility and session functions.
CREATE TABLE cat_t (id INT, name TEXT);
INSERT INTO cat_t VALUES (1, 'one');
SELECT 'relations' AS section;
SELECT relname FROM pg_class WHERE relname = 'cat_t';
SELECT 'session' AS section;
SELECT current_database(), current_user();
DROP TABLE cat_t;
