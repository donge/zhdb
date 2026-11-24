# zhdb regression tests

`test/run.sh` is a small pg_regress-style runner. It keeps expected output next
to the SQL, so a semantic change fails loudly instead of being silently
rewritten.

```
test/
  run.sh                 # runner
  pg/                    # PostgreSQL semantics (row engine)
    schedule
    sql/*.sql
    expected/*.out
  analytics/             # columnar analytics (small deterministic fixture)
    schedule
    sql/*.sql
    expected/*.out
    data/sales.tsv       # first line: #schema:<name>:<type>\t...
  pg18/                  # official PostgreSQL 18.6 regression (first wave)
    run.sh
    sql/test_setup.sql
    expected/test_setup.out
    data/*.data
  known_unsupported.md   # gaps, with the SQL that is not covered yet
```

## Run

```bash
./test/run.sh                 # all suites: pg + analytics
./test/run.sh pg              # one suite
./test/run.sh analytics
./test/run.sh --update        # regenerate expected/*.out from the current engine
./test/pg18/run.sh            # official PG 18.6 test_setup
```

The runner exits non-zero on the first failing test and prints a unified diff.
`--update` is for intentional changes only; review the diff before committing.

### How a test runs

* By default a file is executed with `zhdb run` (one fresh process per file), so
  `CREATE`/`INSERT`/`BEGIN`/`COMMIT`/`ROLLBACK` work and errors are stable
  `ERROR: <name>` lines. Output is TSV, with SQL NULL as `\N`.
* A file whose first line is

  ```sql
  -- load: data/sales.tsv
  ```

  is loaded once through the columnar streaming loader and its `SELECT`s run
  through `zhdb bench` (one repeat). This exercises the columnar path on a
  table named `hits`; the fixture header supplies the schema.

## Coverage

`pg/` covers literals, arithmetic, comparisons, three-valued NULL logic,
`IS NULL`, `IN`/`BETWEEN`/`LIKE`, `CASE`/`COALESCE`/`NULLIF`, casts, strings,
aggregates and `GROUP BY`/`HAVING`, inner/left/right/full/cross joins,
`IN`/`EXISTS`/`FROM` subqueries, `UNION`/`INTERSECT`/`EXCEPT`, DDL/DML,
transactions and rollback, errors, and basic `pg_catalog`.

`analytics/` covers scans, predicates, dictionary filters, `GROUP BY` on one
and two keys, `HAVING`, `DISTINCT`, `COUNT(DISTINCT ...)`, Top-K ordering and
projection expressions on 240 rows.

The expected files were generated with `--update` and then checked against
PostgreSQL semantics by hand. They are a compatibility baseline, not a claim
that every PostgreSQL feature is implemented; see `known_unsupported.md`.

## Adding a test

1. Add `pg/sql/<name>.sql` (or `analytics/sql/<name>.sql`).
2. Add `<name>` to the suite's `schedule`.
3. Run `./test/run.sh --update <suite>` and inspect the new expected file.
4. Run `./test/run.sh <suite>`; it must pass without `--update`.
