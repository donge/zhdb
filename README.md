# zhdb

用 **Zig 0.17** 重写 Umbra 风格数据库的一次落地实现：PostgreSQL 线协议 + 原生 SQL 执行器，
测试直接复用 `../zighouse/tests/functional` 语料。

> 目标不是复刻 Umbra 的 JIT/列存/缓冲池，而是先把**可观察行为**（协议、SQL 语义、输出格式）
> 用 Zig 重建出来，让同一批 .sql/.reference 用例在新引擎上跑通，作为后续替换内部实现的基线。

## 构建与运行

```bash
zig build --release=fast      # 发布构建（Zig 0.17 用 --release，不是 -Doptimize）
zig build                     # Debug，带边界检查

./zig-out/bin/zhdb serve --port=5432
./zig-out/bin/zhdb run tests/../path/to/file.sql   # 按行输出 TSV（无表头）
./zig-out/bin/zhdb query "select 1+1"
```

已用 `psql` 18 实测：

```bash
psql "host=127.0.0.1 port=5432 user=zhdb dbname=postgres sslmode=disable" \
  -c "create table t(id int, name text)" \
  -c "insert into t values (1,'a'),(2,'b')" \
  -c "select * from t order by id"
```

## 测试（复用 zighouse 用例）

```bash
bash tests/run_functional.sh
# zhdb functional: 40 passed, 0 failed, 4 skipped
```

用例目录通过 `TESTS_DIR=/path/to/functional` 覆盖，默认 `../../zighouse/tests/functional`。
跳过项是 ClickHouse 专有的 parquet 导入、compactor、物化视图和 `system.disks`。`FORMAT JSON` 已实现并与参考输出逐字节一致。

线协议另有独立脚本（无需 psql）：

```bash
./zig-out/bin/zhdb serve --port=55432 &
python3 tests/pg_protocol_test.py 55432   # pg protocol: 6/6 checks passed
```

为跑通 ClickHouse 方言，词法/语法层直接接受：`ENGINE = MergeTree ORDER BY ...`（忽略）、
`UInt8/16/32/64`、`Int*`、`Float64`、`String`、`Date`、`DateTime('tz')`、`LowCardinality(T)`、
`count()`、`if()`、`toString()`、`concat()`、`toYear/toMonth/toDayOfMonth/toHour/toMinute/toSecond()`、
`CAST(x AS String)`、`ALTER TABLE ... DROP PARTITION`（no-op）。

## ClickBench（1M 行）

```bash
./zig-out/bin/zhdb bench --load=../bench/hits_1m17_schema.tsv --repeat=3 ../bench/clickbench_1m.sql
```

- 43 条官方查询中 **36 条可执行**（31 条比较集 + 34–43 中的 5 条）；缺口是
  `extract()`、`REGEXP_REPLACE()`、`DATE_TRUNC()` 与 11 个未加载的列。
- 同一份 1M×17 列数据、每查询 3 次最好成绩：行解释 6386 ms → 行+并行 1165 ms
  → **列式 472 ms**。DuckDB 71 ms、Umbra 99 ms、zighouse 93 ms（**4.8–6.6×**）。
- 列式路径见 `src/columnar.zig`：连续列数组、类型化谓词、开放寻址分组哈希、
  按 hash 分片的 morsel 并行、有界 Top-K、LIKE 子串快路径。
- `src/jit.zig`：ARM64 copy-and-patch JIT 原型（约 12μs/内核），见 `docs/jit.md`。
- `SUM(col + k)` 家族共享一次基础累加：Q28 从 42 ms 降到 **1.0 ms**。
- 最差的是 90 个 `SUM()` 的查询（3.1 s vs 2 ms），因为每个聚合各扫一遍全表。
- 明细与逐条对比见 [`../bench/CLICKBENCH.md`](../bench/CLICKBENCH.md)。

## 结构

| 文件 | 职责 |
|---|---|
| `src/sql.zig` | 词法、递归下降 SQL 解析、语句切分 |
| `src/engine.zig` | 内存目录、类型/值语义、表达式求值、聚合/分组/排序/去重/limit、TSV/JSON 格式化 |
| `src/pg.zig` | PG v3 线协议（startup、SSLRequest 拒绝、simple query、Parse/Bind/Describe/Execute/Sync、RowDescription/DataRow/ErrorResponse） |
| `src/main.zig` | CLI：`serve` / `run` / `query` / `version`，脚本模式与 JSON 输出 |

### 已验证的 SQL 面

SELECT（投影、`*`、别名、`WHERE`、`GROUP BY`、`HAVING`、`ORDER BY` 多键升降序、
`LIMIT/OFFSET`、`DISTINCT`、`UNION ALL`、FROM 子查询）、
`count/sum/avg/min/max` 与 `count(distinct x)`、
`CASE WHEN`、`IN`、`BETWEEN`、`LIKE`/`NOT LIKE`、`IS [NOT] NULL`、`CAST`、
CREATE/DROP/TRUNCATE TABLE、INSERT（含列子集、默认值）、DELETE。
类型系统：int/float/text/bool/date/timestamp（日期按 ISO 文本存储）。

## 与 Umbra / PostgreSQL 的差距（明确未实现）

- **无持久化**：目录和表都在内存，进程退出即丢；Umbra 有 `umbra.db` + `.pages` + WAL。
- **无 MVCC/事务**：没有 begin/commit/snapshot、没有隔离级别；并发连接用一把互斥锁串行化。
- **无 WAL/checkpoint/崩溃恢复**、无 buffer manager、无压缩（AnyBlob/zstd/lz4）。
- **无 JIT/codegen**：表达式解释执行；Umbra 走 LLVM + xych（xbyak）生成机器码。
- **无索引、无 JOIN、无窗口函数、无 `MERGE`/游标/SAVEPOINT/触发器/视图/序列/权限**。
- PG 兼容子集：`pg_settings` 等系统目录未实现，`psql \d`/`\l` 不可用；`server_version` 报 18.1。

## 路线图

1. 磁盘页式存储 + WAL + 重启恢复（对齐 Umbra 的 `*.db.pages` / `*.db.wal` 形态）。
2. 事务与 MVCC（快照隔离），去掉全局锁。
3. 列式执行 + morsel 并行（对应 Umbra 的 `RelationPagedPartition`）。
4. 哈希连接 / GroupJoin / HashTrieJoin（WCOJ）算子。
5. 可选 Zig 侧 codegen 或 LLVM 绑定，替代解释执行。
