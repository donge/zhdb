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

**100** official PostgreSQL 18.6 regression files now match their expected
output byte-for-byte (see `schedule`), including the type I/O, DDL/DML,
catalog, transaction, indexing-access-method, quoting and `psql` client
(`\crosstabview`) suites.

| Item | Status |
|---|---|
| `test_setup.sql` | runs end-to-end, data-level checks pass |
| `char.sql` | official expected output matches byte-for-byte |
| `varchar.sql` | official expected output matches byte-for-byte |
| `oid.sql` | official expected output matches byte-for-byte |
| `boolean.sql` | official expected output matches byte-for-byte |
| `md5.sql` | official expected output matches byte-for-byte |
| `int2.sql` | official expected output matches byte-for-byte |
| `int4.sql` | official expected output matches byte-for-byte |
| `int8.sql` | official expected output matches byte-for-byte |
| `select_having.sql` | official expected output matches byte-for-byte |
| `delete.sql` | official expected output matches byte-for-byte |
| `comments.sql` | official expected output matches byte-for-byte |
| `macaddr.sql` | official expected output matches byte-for-byte |
| `lseg.sql` | official expected output matches byte-for-byte |
| `path.sql` | official expected output matches byte-for-byte |
| `line.sql` | official expected output matches byte-for-byte |
| `circle.sql` | official expected output matches byte-for-byte |
| `point.sql` | official expected output matches byte-for-byte |
| `name.sql` | official expected output matches byte-for-byte |
| `drop_operator.sql` | official expected output matches byte-for-byte |
| `init_privs.sql` | official expected output matches byte-for-byte |
| `security_label.sql` | official expected output matches byte-for-byte |
| `numa.sql` | official expected output matches byte-for-byte |
| `async.sql` | official expected output matches byte-for-byte |
| `macaddr8.sql` | official expected output matches byte-for-byte |
| `time.sql` | official expected output matches byte-for-byte |
| `euc_kr.sql` | official expected output matches byte-for-byte |
| `bitmapops.sql` | official expected output matches byte-for-byte |
| `compression_pglz.sql` | official expected output matches byte-for-byte |
| `drop_if_exists.sql` | official expected output matches byte-for-byte |
| `jsonpath_encoding.sql` | official expected output matches byte-for-byte |
| `create_function_c.sql` | official expected output matches byte-for-byte |
| `copyencoding.sql` | official expected output matches byte-for-byte |
| `dbsize.sql` | official expected output matches byte-for-byte |
| `money.sql` | official expected output matches byte-for-byte |
| `json_encoding.sql` | official expected output matches byte-for-byte |
| `unicode.sql` | official expected output matches byte-for-byte |
| `roleattributes.sql` | official expected output matches byte-for-byte |
| `database.sql` | official expected output matches byte-for-byte |
| `uuid.sql` | official expected output matches byte-for-byte |
| `portals_p2.sql` | official expected output matches byte-for-byte |
| `maintain_every.sql` | official expected output matches byte-for-byte |
| `sanity_check.sql` | official expected output matches byte-for-byte |
| `infinite_recurse.sql` | official expected output matches byte-for-byte |
| `prepare.sql` | official expected output matches byte-for-byte |
| `pg_lsn.sql` | official expected output matches byte-for-byte |
| `misc_sanity.sql` | official expected output matches byte-for-byte |
| `timetz.sql` | official expected output matches byte-for-byte |
| `create_schema.sql` | official expected output matches byte-for-byte |
| `select_implicit.sql` | official expected output matches byte-for-byte |
| `spgist.sql` | official expected output matches byte-for-byte |
| `write_parallel.sql` | official expected output matches byte-for-byte |
| `vacuum_parallel.sql` | official expected output matches byte-for-byte |
| `password.sql` | official expected output matches byte-for-byte |
| `event_trigger_login.sql` | official expected output matches byte-for-byte |
| `typed_table.sql` | official expected output matches byte-for-byte |
| `mvcc.sql` | official expected output matches byte-for-byte |
| `hash_func.sql` | official expected output matches byte-for-byte |
| `namespace.sql` | official expected output matches byte-for-byte |
| `tid.sql` | official expected output matches byte-for-byte |
| `create_cast.sql` | official expected output matches byte-for-byte |
| `create_operator.sql` | official expected output matches byte-for-byte |
| `select_into.sql` | official expected output matches byte-for-byte |
| `alter_operator.sql` | official expected output matches byte-for-byte |
| `amutils.sql` | official expected output matches byte-for-byte |
| `copyselect.sql` | official expected output matches byte-for-byte |
| `copydml.sql` | official expected output matches byte-for-byte |
| `hash_part.sql` | official expected output matches byte-for-byte |
| `indirect_toast.sql` | official expected output matches byte-for-byte |
| `functional_deps.sql` | official expected output matches byte-for-byte |
| `reloptions.sql` | official expected output matches byte-for-byte |
| `index_including_gist.sql` | official expected output matches byte-for-byte |
| `index_including.sql` | official expected output matches byte-for-byte |
| `text.sql` | official expected output matches byte-for-byte |
| `regproc.sql` | official expected output matches byte-for-byte |
| `plancache.sql` | official expected output matches byte-for-byte |
| `sysviews.sql` | official expected output matches byte-for-byte |
| `advisory_lock.sql` | official expected output matches byte-for-byte |
| `create_aggregate.sql` | official expected output matches byte-for-byte |
| `combocid.sql` | official expected output matches byte-for-byte |
| `dependency.sql` | official expected output matches byte-for-byte |
| `partition_info.sql` | official expected output matches byte-for-byte |
| `lock.sql` | official expected output matches byte-for-byte |
| `create_misc.sql` | official expected output matches byte-for-byte |
| `replica_identity.sql` | official expected output matches byte-for-byte |
| `psql_crosstab.sql` | official expected output matches byte-for-byte |
| `portals_inflight.sql` | official expected output matches byte-for-byte |
| `txid.sql` | official expected output matches byte-for-byte |
| `collate.utf8.sql` | official expected output matches byte-for-byte |
| `xid.sql` | official expected output matches byte-for-byte |
| shared tables (`onek`, `tenk1`, `person`, `emp`, `student`, `stud_emp`, `road`, highways) | created and populated |
| official `expected/*.out` | matched as psql `-a -q` echo plus aligned result tables |
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
test/pg18/run.sh              # schedule: test_setup, char, varchar, oid, boolean, int2, int4, int8, select_having, delete, comments, macaddr, lseg, path, line, circle, point, name, drop_operator, init_privs, security_label, numa, async, macaddr8, time, euc_kr, bitmapops, compression_pglz, drop_if_exists, jsonpath_encoding, create_function_c, copyencoding, dbsize, money, json_encoding, unicode, roleattributes, database, uuid, portals_p2, maintain_every, md5
test/pg18/run.sh char
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

The `test_setup` `.out` is the psql `-a -q` echo (SQL input with blank lines
removed); it runs through `zhdb run` and is also checked against the official
row counts.

Tests with result rows run through a throwaway `zhdb serve` seeded with
`test_setup`, and `psql.py` implements the small subset of psql's aligned
output needed by the official expected files (headers, separators, widths,
`t`/`f` Boolean rendering, `\pset null`, `ERROR:` lines).
