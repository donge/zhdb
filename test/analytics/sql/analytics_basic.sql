-- load: data/sales.tsv
-- Columnar analytics on a small deterministic fixture (240 rows).
SELECT 'overall' AS section;
SELECT COUNT(*), SUM(units), AVG(units), MIN(units), MAX(units) FROM hits;

SELECT 'by-region' AS section;
SELECT region, COUNT(*), SUM(units), AVG(units) FROM hits GROUP BY region ORDER BY region;

SELECT 'by-product' AS section;
SELECT product, COUNT(*), SUM(units) FROM hits GROUP BY product ORDER BY product;

SELECT 'by-channel' AS section;
SELECT channel, COUNT(*), SUM(units), MIN(price_cents), MAX(price_cents)
FROM hits GROUP BY channel ORDER BY channel;

SELECT 'two-keys' AS section;
SELECT year, month, COUNT(*), SUM(units) FROM hits GROUP BY year, month ORDER BY year, month;

SELECT 'having' AS section;
SELECT product, COUNT(*) FROM hits GROUP BY product HAVING COUNT(*) > 50 ORDER BY product;

SELECT 'distinct' AS section;
SELECT COUNT(DISTINCT region), COUNT(DISTINCT product), COUNT(DISTINCT channel) FROM hits;
