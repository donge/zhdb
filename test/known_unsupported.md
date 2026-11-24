# Known gaps (not asserted as passing)

These are deliberately out of the current test matrix. Several return an error
or are accepted as no-ops; none should be mistaken for working PostgreSQL
semantics. Add a test here only after the feature is implemented.

## SQL surface

| Gap | Current behaviour |
|---|---|
| `WITH ...` CTEs | `ERROR: syntax error` (previous builds returned no rows) |
| Scalar subqueries `(SELECT ...)` in an expression | `ERROR: syntax error` |
| Window functions (`OVER`, `ROW_NUMBER`, ...) | syntax error / not parsed |
| `INSERT ... SELECT` | syntax error |
| `CREATE VIEW`, `CREATE TABLE AS`, materialized views | not implemented |
| `ALTER TABLE ... ADD COLUMN/RENAME` | accepted as a no-op (ClickHouse compatibility); columns do not change |
| `SAVEPOINT`/`RELEASE` real semantics | not implemented |
| `PRIMARY KEY`, `NOT NULL`, `UNIQUE`, `DEFAULT`, `FOREIGN KEY`, `CHECK` | `CREATE TABLE` syntax error; no constraint enforcement |
| Sequences / `SERIAL` / `ON CONFLICT` | not implemented |
| `||` string concatenation | syntax error; use `concat(a, b)` |
| `substring(x FROM a FOR b)`, `trim(BOTH ...)`, `replace()` | not implemented |
| `ILIKE`, `SIMILAR TO`, `DISTINCT ON`, `NULLS FIRST/LAST` | not implemented |
| `DATE '...'`, `TIMESTAMP '...'`, `INTERVAL '...'` literals | not implemented; use `CAST('...' AS DATE)` |
| `now()`, `current_date`, `current_time` | `now()` returns NULL; `current_date` is unknown |
| `NUMERIC/DECIMAL` precision, arrays, JSON operators, ranges | mapped to text/float or unsupported |
| `EXTRACT`/`date_trunc` beyond the supported units | partial |

## Execution / storage

| Gap | Current behaviour |
|---|---|
| Duplicate column names after a join | `SELECT jl.id, jr.id FROM ... RIGHT/FULL JOIN ...` resolves both `id`s to the left column; alias the selected columns or select unique names |
| NULL payload columns in joins | join temporaries historically copied sentinel values instead of materialising NULLs; use non-NULL payloads in join fixtures, or select the join keys |
| Nullable `GROUP BY` keys on the loader-built columnar path | the columnar executor falls back to the row engine, which has no rows in `bench --load` mode; keep analytics fixtures non-null |
| BOOLEAN columns in a columnar snapshot | stored as 0/1 by the columnar image; the in-memory row engine keeps `true`/`false` |
| `CAST(float AS int)` | truncates (PostgreSQL rounds to nearest) |
| Parquet import, compactor, materialized views, `system.*` tables | the existing functional suite skips these four cases |
| Replication / HA / cross-node transactions | single process only |

## PostgreSQL 18.6 official suite

`test_setup`, `char`, `varchar`, `oid`, `boolean`, `int2`, `int4`, `int8`, `select_having`, `delete`, `comments`, `macaddr`, `lseg`, `path`, `line`, `circle`, `point`, `name`, `drop_operator`, `init_privs`, `security_label`, `numa`, `async`, `macaddr8`, `time`, `euc_kr`, `bitmapops`, `compression_pglz` and `md5` are ported into `test/pg18/` so far. The
remaining official regression tests, isolation suites and TAP tests are not part
of this repository yet. `test/pg18/README.md` lists the current stubs and the exact
setup dependencies that were implemented.

## Notes

* PostgreSQL-style types (`INT`, `TEXT`, `BOOLEAN`, ...) get NULL for omitted
  INSERT columns. ClickHouse-style types (`UInt64`, `String`, ...) keep the
  implicit zero/empty default so the ClickHouse functional corpus still passes.
* `FULL JOIN` is implemented for unique column names and simple equi-ON
  conditions; the duplicate-name projection limit above still applies.
* The tests are a regression baseline for the behaviours zhdb implements. They
  do not replace the PostgreSQL regression suite.
