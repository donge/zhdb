# zhdb

[English](README.md) | [简体中文](README.zh-CN.md)

[![CI](https://github.com/donge/zhdb/actions/workflows/ci.yml/badge.svg)](https://github.com/donge/zhdb/actions/workflows/ci.yml)
[![Release](https://github.com/donge/zhdb/actions/workflows/release.yml/badge.svg)](https://github.com/donge/zhdb/actions/workflows/release.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

**zhdb** is an analytical SQL database written from scratch in **Zig 0.17**. It
speaks the **PostgreSQL v3 wire protocol**, stores data in a columnar snapshot
format, and executes aggregation kernels through a **copy-and-patch JIT**.

The project treats the protocol, SQL engine, storage layer, and execution engine
as separately testable pieces, and measures itself against the official
PostgreSQL regression suite and the full 43-query ClickBench workload.

## Status

| Item | Result |
|---|---|
| PostgreSQL 18.6 official regression | **100 / 100 files** byte-for-byte |
| Internal regression suites | **18 passed, 0 failed** |
| ClickBench 10M × 43 queries | **43 / 43**, validated against DuckDB |
| Source size | **48,364 lines** of Zig (budget: 50,000) |
| Wire protocol | SCRAM-SHA-256, TLS 1.3, CancelRequest, simple + extended query, COPY |
| License | AGPL-3.0 |

## ClickBench: official 10M rows, 43 queries

Same machine, same data (`hits_10m_25col.tsv`), same 43 SQL statements, best of
3 per query. Lower is better for time and memory; disk is the engine's own
on-disk footprint after loading.

| Engine | 43 queries | Peak RSS | On-disk |
|---|---:|---:|---:|
| **zhdb** | **1345.0–1584.7 ms** (JIT: 1220.8–1227.4 ms) | **2.44–2.77 GB** | **776,836,151 B** |
| Umbra | 3088.5 ms | 3.59 GB | 1,935,034,257 B |
| DuckDB 2.0.1 (file DB) | 2360.1–2503.2 ms | 2.93–3.15 GB | 1.29 GB |

- All 43 queries execute; results match DuckDB value-for-value except known
  tie-breaking in `ORDER BY … LIMIT` and byte-vs-character `length()` semantics.
- The JIT path is about **3.8×** faster than `ZHDB_NO_JIT=1` on the same
  workload (1220.8 vs 4765.5 ms), with lower peak memory.
- The v9 snapshot uses a global string dictionary, sorted front-coding, and
  deflate, cutting the 10M dataset to 0.78 GB.

The full measurement log lives in `bench/CLICKBENCH.md` in the development
tree (the 25-column TSV and the 43-query file are not vendored here). The
regression harness is [`tests/clickbench43_test.sh`](tests/clickbench43_test.sh).

## Quick start

Requirements:

- **Zig 0.17.0**
- **Linux:** ICU development files (`sudo apt install libicu-dev`)
- **macOS:** Xcode command-line tools (system ICU and iconv are used)

```bash
git clone --recurse-submodules https://github.com/donge/zhdb.git
cd zhdb

zig build --release=fast
./zig-out/bin/zhdb serve --port=5432
```

Connect with any PostgreSQL client:

```bash
psql "host=127.0.0.1 port=5432 user=zhdb dbname=postgres sslmode=disable" \
  -c "create table t(id int, name text)" \
  -c "insert into t values (1,'a'),(2,'b')" \
  -c "select * from t order by id"
```

Useful CLI commands:

```bash
./zig-out/bin/zhdb query "select 1 + 1"
./zig-out/bin/zhdb run script.sql
./zig-out/bin/zhdb bench --load=hits.tsv --repeat=3 queries.sql
./zig-out/bin/zhdb copy hits.tsv hits.zdb
./zig-out/bin/zhdb stat hits.zdb
./zig-out/bin/zhdb lookup --db=hits.zdb --column=CounterID --value=62
```

Server options include `--password=...`, `--scram-sha-256`, `--tls`, and
`--load=<db.zdb>`.

## Build and test

```bash
# Release build and unit tests
zig build --release=fast
zig build test

# Internal pg_regress-style suites (SQL semantics + columnar analytics)
./test/run.sh

# Official PostgreSQL 18.6 regression (100 files)
./test/pg18/run.sh

# One official test
./test/pg18/run.sh select_having
```

Protocol probes run against a live server:

```bash
./zig-out/bin/zhdb serve --port=5432 --scram-sha-256 --password=postgres &
python3 tests/pg_protocol_probe.py 5432 postgres
python3 tests/pg_extended_probe.py 5432
```

Additional checks: `tests/index_scan_test.sh`, `tests/join_plan_test.sh`,
`tests/jit_test.sh`, `tests/storage_test.sh`, `tests/tls_test.sh`,
`tests/clickbench43_test.sh`, `tests/pg_catalog_test.py`.

## Continuous integration

GitHub Actions runs on every push to `main` and every pull request:

| Workflow | What it does |
|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | line budget, release build + unit tests, 18 internal suites, 100 official PostgreSQL tests, protocol probes |
| [`release.yml`](.github/workflows/release.yml) | on a `v*` tag, builds Linux x86_64/aarch64 and macOS arm64 tarballs and publishes a GitHub Release |

The official PostgreSQL schedule runs with `PG18_JOBS=4`, and the whole CI run
takes about 4–5 minutes on GitHub-hosted runners. Each job has a fixed timeout
and the Zig build cache is restored between runs.

## Architecture

| File | Responsibility |
|---|---|
| `src/sql.zig` | lexer and recursive-descent parser (SELECT/DDL/DML, joins, subqueries, set operations) |
| `src/engine.zig` | catalog, type/value semantics, expression evaluation, row execution, transactions |
| `src/columnar.zig` | columnar encoding, predicates, group hash, sort, DISTINCT, Top-K, materialized keys |
| `src/jit.zig` | ARM64 copy-and-patch JIT for grouped aggregation |
| `src/storage.zig` | snapshot blocks, min/max pruning, streaming aggregation, sparse indexes |
| `src/pg.zig` | PostgreSQL v3 protocol: auth, TLS, simple/extended query, prepared statements, COPY IN |
| `src/wal.zig` | statement WAL and replay for crash recovery |
| `src/lockmgr.zig` | table locks and deadlock detection |
| `deps/zhdb-support` | reusable Zig libraries: btree, LZ4, regex VM, TLS 1.3, allocator, geometry, JSON, datetime, CSV, text, decimal |

### Storage model

- Columnar contiguous arrays with dictionary-encoded strings and adaptive
  integer widths (i8/i16/i32/i64), bit-packed per block.
- Block-level min/max statistics prune predicates; sorted dictionary ranks let
  string range comparisons run as integer comparisons.
- Self-describing snapshot blocks with LZ4/deflate compression, plus statement
  WAL replay and optional write-back for crash recovery.
- Statement-scoped arena reuse and an OS-friendly allocator keep the 10M-row
  query peak below 3 GB.

## SQL coverage

Supported today includes:

- **Queries:** projection, `WHERE`, `GROUP BY` expressions, `HAVING`,
  multi-key `ORDER BY`, `LIMIT`/`OFFSET`, `DISTINCT`, `DISTINCT ON`,
  `INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS JOIN`, multi-table joins, `IN`/`EXISTS`
  (including correlated forms), FROM-subqueries, CTEs, set operations,
  window functions (`row_number`, `lag`), `CASE`, `COALESCE`, `NULLIF`, `CAST`.
- **Aggregates:** `count`, `sum`, `avg`, `min`, `max`, `count(distinct)`.
- **Strings and regex:** `LIKE`, `ILIKE`, `SIMILAR TO`, POSIX regex `~`/`~*`,
  `regexp_replace`, normalization helpers.
- **DDL/DML:** `CREATE`/`DROP TABLE`, `CREATE INDEX`, `CREATE VIEW`,
  multi-row `INSERT`, `INSERT … SELECT`, `UPDATE`, `DELETE`, `TRUNCATE`,
  `ANALYZE`, `VACUUM`, `EXPLAIN`, `SHOW`, `RETURNING`.
- **Transactions:** `BEGIN`/`COMMIT`/`ROLLBACK`, savepoints, rollback that is
  invisible to other sessions.
- **Time:** `date_trunc`, `extract`, `to_timestamp`, `CURRENT_DATE` /
  `CURRENT_TIMESTAMP` (with or without parentheses).

Not every PostgreSQL feature is implemented. Constraints are partial,
`WITH RECURSIVE` is unsupported, binary result format is rejected explicitly
rather than silently mis-encoded, and `SIMILAR TO` does not yet expand `{m,n}`
repetition. The authoritative gap list is
[`docs/pg-compatibility-gap-and-todo.md`](docs/pg-compatibility-gap-and-todo.md)
and [`test/known_unsupported.md`](test/known_unsupported.md).

## Query planning

`EXPLAIN (COSTS ON)` is produced by a statistics-based cost model rather than a
fixed template:

- selectivity from row counts and column statistics (NDV, min/max, MCV,
  histograms after `ANALYZE`);
- sequential scan vs. index scan vs. bitmap heap scan for single tables;
- nested loop vs. hash join for two-table equality joins;
- execution follows the chosen plan: indexed equality predicates use a lazily
  built hash index, and joins use the selected algorithm.

`EXPLAIN (COSTS OFF)` output remains stable so official regression expected
files continue to match byte-for-byte.

## License

AGPL-3.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
