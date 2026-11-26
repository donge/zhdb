-- PostgreSQL types and casts (date/timestamp values are stored as ISO text).
CREATE TABLE types_t (
    i INT,
    bi BIGINT,
    f FLOAT,
    s TEXT,
    b BOOLEAN,
    d DATE,
    ts TIMESTAMP
);
INSERT INTO types_t VALUES
    (42, 9000000000, 3.5, 'hello', true, '2024-01-02', '2024-01-02 03:04:05'),
    (-7, -9000000000, -0.25, 'world', false, '1999-12-31', '1999-12-31 23:59:59');

SELECT 'row' AS section;
SELECT i, bi, f, s, b, d, ts FROM types_t ORDER BY i;

SELECT 'casts' AS section;
SELECT CAST('123' AS INT), CAST(12.4 AS INT), CAST(7 AS FLOAT), CAST(0 AS BOOLEAN), CAST(1 AS BOOLEAN);
SELECT CAST(NULL AS INT), CAST(NULL AS FLOAT), CAST(NULL AS TEXT), CAST(NULL AS BOOLEAN);
SELECT 42::TEXT, '7'::INT, '2.5'::FLOAT;

SELECT 'func-casts' AS section;
SELECT int4('123'), int2('7'), int8('9'), float4('2.5'), float8('3'), text(42), bool('t');

SELECT 'null-cast' AS section;
SELECT i, CAST(i AS FLOAT), CAST(i AS TEXT) FROM types_t ORDER BY i;

DROP TABLE types_t;
