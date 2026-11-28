# zhdb

[English](README.md) | [简体中文](README.zh-CN.md)

[![CI](https://github.com/donge/zhdb/actions/workflows/ci.yml/badge.svg)](https://github.com/donge/zhdb/actions/workflows/ci.yml)
[![Release](https://github.com/donge/zhdb/actions/workflows/release.yml/badge.svg)](https://github.com/donge/zhdb/actions/workflows/release.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

**zhdb** 是用 **Zig 0.17** 从零实现的分析型 SQL 数据库，支持
**PostgreSQL v3 线协议**、列式快照存储，并通过 **copy-and-patch JIT** 执行聚合内核。

项目把协议、SQL 引擎、存储和执行分别做成可验证的模块，并用 PostgreSQL 官方回归
测试与完整的 ClickBench 43 条查询衡量自己。

## 当前状态

| 项目 | 结果 |
|---|---|
| PostgreSQL 18.6 官方回归 | **100 / 100 个文件**逐字节匹配 |
| 内部回归套件 | **18 通过，0 失败** |
| ClickBench 10M × 43 条 | **43 / 43**，已与 DuckDB 对拍 |
| Zig 源码规模 | **49,758 行**（预算 50,000） |
| 线协议 | SCRAM-SHA-256、TLS 1.3、CancelRequest、简单/扩展查询、COPY |
| 许可证 | AGPL-3.0 |

## ClickBench：官方 10M 行、43 条查询

同一台机器、同一份数据（`hits_10m_25col.tsv`）、同一组 43 条 SQL，每条查询取
3 次中的最好成绩。耗时和内存越低越好；落盘为加载后引擎自身格式的占用。

| 引擎 | 43 条合计 | 峰值内存 | 落盘 |
|---|---:|---:|---:|
| **zhdb** | **1345.0–1584.7 ms**（JIT：1220.8–1227.4 ms） | **2.44–2.77 GB** | **776,836,151 B** |
| Umbra | 3088.5 ms | 3.59 GB | 1,935,034,257 B |
| DuckDB 2.0.1（文件库） | 2360.1–2503.2 ms | 2.93–3.15 GB | 1.29 GB |

- 43 条查询全部执行；除 `ORDER BY … LIMIT` 的并列取行和 `length()` 的字节/字符
  语义外，结果与 DuckDB 逐值一致。
- 同一负载下 JIT 路径比 `ZHDB_NO_JIT=1` 快约 **3.8 倍**（1220.8 vs 4765.5 ms），
  峰值内存也更低。
- v9 快照使用全局字符串字典、排序 front-coding 和 deflate，把 10M 数据压到 0.78 GB。

完整测量记录在开发树的 `bench/CLICKBENCH.md`（25 列 TSV 与 43 条 SQL 不随仓库分发）。
回归脚本见 [`tests/clickbench43_test.sh`](tests/clickbench43_test.sh)。

## 快速开始

依赖：

- **Zig 0.17.0**
- **Linux：** ICU 开发文件（`sudo apt install libicu-dev`）
- **macOS：** Xcode 命令行工具（使用系统 ICU 与 iconv）

```bash
git clone --recurse-submodules https://github.com/donge/zhdb.git
cd zhdb

zig build --release=fast
./zig-out/bin/zhdb serve --port=5432
```

用任意 PostgreSQL 客户端连接：

```bash
psql "host=127.0.0.1 port=5432 user=zhdb dbname=postgres sslmode=disable" \
  -c "create table t(id int, name text)" \
  -c "insert into t values (1,'a'),(2,'b')" \
  -c "select * from t order by id"
```

常用 CLI：

```bash
./zig-out/bin/zhdb query "select 1 + 1"
./zig-out/bin/zhdb run script.sql
./zig-out/bin/zhdb bench --load=hits.tsv --repeat=3 queries.sql
./zig-out/bin/zhdb copy hits.tsv hits.zdb
./zig-out/bin/zhdb stat hits.zdb
./zig-out/bin/zhdb lookup --db=hits.zdb --column=CounterID --value=62
```

服务端选项包括 `--password=...`、`--scram-sha-256`、`--tls` 和
`--load=<db.zdb>`。

## 构建与测试

```bash
# 发布构建与单元测试
zig build --release=fast
zig build test

# 内部 pg_regress 风格套件（SQL 语义 + 列式分析）
./test/run.sh

# PostgreSQL 18.6 官方回归（100 个文件）
./test/pg18/run.sh

# 单个官方测试
./test/pg18/run.sh select_having
```

协议探针需要先启动服务：

```bash
./zig-out/bin/zhdb serve --port=5432 --scram-sha-256 --password=postgres &
python3 tests/pg_protocol_probe.py 5432 postgres
python3 tests/pg_extended_probe.py 5432
```

其他检查：`tests/index_scan_test.sh`、`tests/join_plan_test.sh`、
`tests/jit_test.sh`、`tests/storage_test.sh`、`tests/tls_test.sh`、
`tests/clickbench43_test.sh`、`tests/pg_catalog_test.py`。

## 持续集成

GitHub Actions 在每次推送到 `main` 和每个 Pull Request 上运行：

| 工作流 | 内容 |
|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | 行数预算、发布构建 + 单元测试、18 个内部套件、100 个官方 PostgreSQL 测试、协议探针 |
| [`release.yml`](.github/workflows/release.yml) | 推送 `v*` 标签时构建 Linux x86_64/aarch64 与 macOS arm64 压缩包并发布 GitHub Release |

完整 CI 设计为在几分钟内完成；每个 job 都有固定超时，并复用 Zig 构建缓存。

## 架构

| 文件 | 职责 |
|---|---|
| `src/sql.zig` | 词法与递归下降解析（SELECT/DDL/DML、JOIN、子查询、集合运算） |
| `src/engine.zig` | 目录、类型/值语义、表达式求值、行式执行、事务 |
| `src/columnar.zig` | 列式编码、谓词、分组哈希、排序、DISTINCT、Top-K、物化键 |
| `src/jit.zig` | ARM64 copy-and-patch JIT，用于分组聚合 |
| `src/storage.zig` | 快照块、min/max 剪枝、流式聚合、稀疏索引 |
| `src/pg.zig` | PostgreSQL v3 协议：认证、TLS、简单/扩展查询、prepared statement、COPY IN |
| `src/wal.zig` | 语句 WAL 与崩溃恢复重放 |
| `src/lockmgr.zig` | 表锁与死锁检测 |
| `deps/zhdb-support` | 可复用 Zig 库：btree、LZ4、正则 VM、TLS 1.3、分配器 |

### 存储模型

- 列式连续数组；字符串字典编码，整型按值域选择 i8/i16/i32/i64，块内位打包。
- 块级 min/max 统计用于谓词剪枝；字典有序 rank 让字符串范围比较走整数。
- 自描述快照块使用 LZ4/deflate 压缩，配合语句 WAL 重放与可选回写实现崩溃恢复。
- 语句级 arena 复用与对 OS 友好的分配器，使 10M 行查询峰值低于 3 GB。

## SQL 覆盖

目前支持：

- **查询：** 投影、`WHERE`、`GROUP BY` 表达式、`HAVING`、多键 `ORDER BY`、
  `LIMIT`/`OFFSET`、`DISTINCT`、`DISTINCT ON`、`INNER`/`LEFT`/`RIGHT`/`FULL`/`CROSS JOIN`、
  多表 JOIN、`IN`/`EXISTS`（含相关子查询）、FROM 子查询、CTE、集合运算、
  窗口函数（`row_number`、`lag`）、`CASE`、`COALESCE`、`NULLIF`、`CAST`。
- **聚合：** `count`、`sum`、`avg`、`min`、`max`、`count(distinct)`。
- **字符串与正则：** `LIKE`、`ILIKE`、`SIMILAR TO`、POSIX 正则 `~`/`~*`、
  `regexp_replace`、Unicode 规范化函数。
- **DDL/DML：** `CREATE`/`DROP TABLE`、`CREATE INDEX`、`CREATE VIEW`、
  多行 `INSERT`、`INSERT … SELECT`、`UPDATE`、`DELETE`、`TRUNCATE`、
  `ANALYZE`、`VACUUM`、`EXPLAIN`、`SHOW`、`RETURNING`。
- **事务：** `BEGIN`/`COMMIT`/`ROLLBACK`、savepoint；回滚对其他会话不可见。
- **时间：** `date_trunc`、`extract`、`to_timestamp`、`CURRENT_DATE` /
  `CURRENT_TIMESTAMP`（可带或不带括号）。

并非所有 PostgreSQL 特性都已实现：约束只覆盖一部分，暂不支持 `WITH RECURSIVE`，
二进制结果格式会明确报错而不是静默编错，`SIMILAR TO` 尚未展开 `{m,n}` 重复语法。
权威差距清单见 [`docs/pg-compatibility-gap-and-todo.md`](docs/pg-compatibility-gap-and-todo.md)
与 [`test/known_unsupported.md`](test/known_unsupported.md)。

## 查询计划

`EXPLAIN (COSTS ON)` 由基于统计的代价模型生成，而不是固定模板：

- 用行数与列统计（NDV、min/max、MCV、直方图；`ANALYZE` 后生效）计算选择率；
- 单表在顺序扫描、索引扫描、Bitmap Heap Scan 之间选择；
- 两表等值连接在 Nested Loop 与 Hash Join 之间选择；
- 执行与计划一致：索引等值谓词使用惰性构建的哈希索引，连接使用所选算法。

`EXPLAIN (COSTS OFF)` 输出保持稳定，官方回归的 expected 仍逐字节匹配。

## 许可证

AGPL-3.0，见 [`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)。
