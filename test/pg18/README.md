# PostgreSQL 18.6 official regression: first milestone

This directory vendors the **test_setup** step from the official PostgreSQL
18.6 `src/test/regress` tree:

```text
sql/test_setup.sql
expected/test_setup.out
data/*.data
```

The source is covered by the PostgreSQL License (see
`LICENSE-postgresql.txt`). It is vendored verbatim so the setup data and
fixtures match the official suite.

## Status

| Item | Status |
|---|---|
| `test_setup.sql` | runs end-to-end, data-level checks pass |
| shared tables (`onek`, `tenk1`, `person`, `emp`, `student`, `stud_emp`, `road`, highways) | created and populated |
| official `expected/test_setup.out` | matched as the `psql -a -q` echo (NOTICE lines normalized) |
| remaining official regression tests | not ported yet |

`test/pg18/check_setup.sql` additionally verifies the loaded row counts, so the
test cannot pass by merely echoing SQL:

```text
onek 1000, tenk1 10000, onek2 1000, tenk2 10000
person 50, emp 3, student 2, stud_emp 3
road 5124, ihighway 479, shighway 77
```

## Run

```bash
test/pg18/run.sh              # test_setup
test/pg18/run.sh --list
```

`prep.py` expands the psql variables used by the official file
(`\getenv`, `\set`, `:'filename'`) and sets `PG_ABS_SRCDIR` to this directory,
so `COPY` reads `data/*.data` without requiring a PostgreSQL source tree.

## Dependencies implemented for this milestone

- `CREATE TABLE ... AS SELECT`
- `COPY table FROM 'file'`
- `CREATE TABLE ... INHERITS (...)` with inherited-column merging
- `INSERT INTO ... SELECT ...`
- `FROM ONLY <table>` (accepted; inheritance scans are not implemented yet)
- `VACUUM [ANALYZE] table`
- PostgreSQL-style type names used by the fixtures (`char`, `varchar`, `name`,
  `point`, `path`, `bytea`, `int2/4/8`, `float8`) — unsupported types are stored
  in text form
- psql `\getenv` / `\set` preprocessing and `:'var'` substitution

## Deliberate stubs (for later waves)

These statements are accepted and skipped so `test_setup` can create its
environment, but the objects are not functional yet:

- `CREATE TABLESPACE`
- `CREATE TYPE ... AS ENUM/RANGE`
- `CREATE FUNCTION` (C and SQL bodies)
- `CREATE OPERATOR CLASS`

`NOTICE` output for duplicate inherited columns is normalized out by the
runner until the psql-compatible notice path is implemented.

## Output comparison

The official `.out` for `test_setup` is the psql `-a -q` echo (SQL input with
blank lines removed). The runner executes the SQL through `zhdb run` and fails
on any error; then it compares the official echo with the original SQL. For
tests that return rows, a psql-aligned formatter will be needed; that is the
next step before porting the type tests.
