-- Transaction control: rollback visibility and commit durability.
CREATE TABLE tx_t (id INT, v TEXT);
INSERT INTO tx_t VALUES (1, 'base');

SELECT 'rollback-insert' AS section;
BEGIN;
INSERT INTO tx_t VALUES (2, 'rolled-back');
SELECT id FROM tx_t ORDER BY id;
ROLLBACK;
SELECT id FROM tx_t ORDER BY id;

SELECT 'commit-insert' AS section;
BEGIN;
INSERT INTO tx_t VALUES (3, 'committed');
COMMIT;
SELECT id, v FROM tx_t ORDER BY id;

SELECT 'rollback-update' AS section;
BEGIN;
UPDATE tx_t SET v = 'changed' WHERE id = 1;
SELECT id, v FROM tx_t ORDER BY id;
ROLLBACK;
SELECT id, v FROM tx_t ORDER BY id;

SELECT 'rollback-delete' AS section;
BEGIN;
DELETE FROM tx_t WHERE id = 3;
SELECT COUNT(*) FROM tx_t;
ROLLBACK;
SELECT COUNT(*) FROM tx_t;

DROP TABLE tx_t;
