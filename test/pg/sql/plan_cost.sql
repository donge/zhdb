-- Statistics-driven planner costs (COSTS ON).
-- Costs use table row counts, column NDV/min/max and the selectivity model;
-- the golden output records the chosen access path and the cost numbers.
CREATE TABLE pc (id int, grp int, val int);
INSERT INTO pc SELECT i, i % 100, i * 2 FROM generate_series(1, 10000) i;
CREATE INDEX pc_id_idx ON pc(id);
CREATE INDEX pc_grp_idx ON pc(grp);
ANALYZE pc;

-- 1% of rows (NDV=100): bitmap heap scan beats seq scan.
EXPLAIN (COSTS ON) SELECT * FROM pc WHERE grp = 1;

-- unique equality: index scan is cheapest.
EXPLAIN (COSTS ON) SELECT * FROM pc WHERE id = 42;

-- matches every row: seq scan wins over the index.
EXPLAIN (COSTS ON) SELECT * FROM pc WHERE id > -1;

-- one-row outer side: nested loop beats hash join.
CREATE TABLE pc_tiny (id int, grp int);
INSERT INTO pc_tiny VALUES (1, 7);
ANALYZE pc_tiny;
EXPLAIN (COSTS ON) SELECT * FROM pc_tiny t JOIN pc p ON t.grp = p.grp;

-- large x large equi-join: hash join wins.
EXPLAIN (COSTS ON) SELECT * FROM pc a JOIN pc b ON a.grp = b.grp;

DROP TABLE pc_tiny, pc;
