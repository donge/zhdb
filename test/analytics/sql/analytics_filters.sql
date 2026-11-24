-- load: data/sales.tsv
-- Predicate pushdown, Top-K and dictionary filters on the columnar path.
SELECT 'filter-year' AS section;
SELECT region, SUM(units) FROM hits WHERE year = 2024 GROUP BY region ORDER BY region;

SELECT 'filter-range' AS section;
SELECT region, SUM(units) FROM hits WHERE units BETWEEN 3 AND 7 GROUP BY region ORDER BY region;

SELECT 'filter-like' AS section;
SELECT COUNT(*), SUM(units) FROM hits WHERE region LIKE 'E%';

SELECT 'filter-in' AS section;
SELECT COUNT(*), SUM(units) FROM hits WHERE channel IN ('web', 'mobile');

SELECT 'top-k' AS section;
SELECT sale_id, region, units FROM hits WHERE units >= 8 ORDER BY units DESC, sale_id LIMIT 8;

SELECT 'distinct-regions' AS section;
SELECT DISTINCT region FROM hits ORDER BY region;

SELECT 'projection-expression' AS section;
SELECT sale_id, units * 2, price_cents - discount_pct FROM hits WHERE sale_id <= 1004 ORDER BY sale_id;
