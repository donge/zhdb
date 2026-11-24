# zhdb

用 **Zig 0.17** 从零实现的**分析型数据库**：PostgreSQL 线协议 + 列式存储 + JIT 聚合。
目标是把「协议 / SQL / 存储 / 执行」四层都做成可验证的真实实现，并用 ClickBench 官方
10M 数据集、全部 43 条查询与 Umbra / DuckDB 对比。

## ClickBench 官方 10M（43 条全查，同机同窗口）

| 指标 | zhdb | Umbra (8 vCPU) | DuckDB (8 线程) |
|---|---|---|---|
| 43 条 best-of-3 | **1161–1204 ms** | 1226 ms | 2456 ms |
| cold 合计（首轮） | **1455 ms** | 2386 ms | 2566 ms |
| 峰值内存 | **2.98–3.04 GiB** | 3.27 GiB | 4.35 GiB |
| 落盘（自身格式） | **1.57 GB** | 1.95 GB | 1.76 GB |
| 加载 10M | 7.8 s | 14.6 s | 3.17 s |

- 43/43 全部执行；与 DuckDB 全量结果对拍，34 条逐值一致，9 条差异均为
  `ORDER BY … LIMIT` 的并列取行或 `length()` 字节 vs 字符语义，已逐行重算证明。
- 最长查询 Q29（`REGEXP_REPLACE` 取 host）252–275 ms（Umbra 427、DuckDB 1162）。
- 与同机 zighouse 对比：41 条共同查询 warm 1066 ms vs 1404 ms，cold 1317 ms vs 6385 ms。

## 构建与运行

```bash
zig build --release=fast      # Zig 0.17：发布构建用 --release
zig build test                # 25 个单测

./zig-out/bin/zhdb serve --port=5432                     # PG 线协议
./zig-out/bin/zhdb run tests/../path.sql                 # 批量脚本（TSV 输出）
./zig-out/bin/zhdb query "select 1+1"
./zig-out/bin/zhdb bench --load=hits.tsv --repeat=3 queries.sql
./zig-out/bin/zhdb copy hits.tsv hits.zdb                # 生成 LZ4 快照
./zig-out/bin/zhdb stat hits.zdb                         # 目录/块索引/压缩率
./zig-out/bin/zhdb lookup --db=hits.zdb --column=CounterID --value=62
```

`psql` 实测：

```bash
psql "host=127.0.0.1 port=5432 user=zhdb dbname=postgres sslmode=disable" \
  -c "create table t(id int, name text)" \
  -c "insert into t values (1,'a'),(2,'b')" \
  -c "select * from t order by id"
```

## 架构

| 文件 | 职责 |
|---|---|
| `src/sql.zig` | 词法、递归下降解析（SELECT/DDL/DML、JOIN、子查询、集合运算） |
| `src/engine.zig` | 目录、类型/值语义、表达式求值、行式执行（JOIN/集合运算/子查询） |
| `src/columnar.zig` | 列式存储与执行：编码、谓词、分组哈希、排序、DISTINCT、Top-K、物化视图化键 |
| `src/jit.zig` | ARM64 copy-and-patch JIT：分组聚合内核（u32 key32、原生宽度求和载入） |
| `src/storage.zig` | 快照块读取、块级 min/max 剪枝、流式聚合、稀疏索引 |
| `src/btree.zig` | 主键/索引 B+ 树 |
| `src/wal.zig` + `src/engine.zig` | WAL 记录与重放、快照 + 增量回写（kill -9 后可恢复） |
| `src/lz4.zig` | 自研 LZ4 block 编解码（快照落盘压缩/加载解压） |
| `src/pg.zig` | PG v3：SCRAM 认证、TLS 1.3、简单/扩展查询、prepared statement、COPY IN、pg_catalog |
| `src/tls.zig` | TLS 1.3 服务端（自签 Ed25519 证书） |

### 存储模型

- 列式连续数组；字符串列**字典编码**（每行 u32 id，值表只存唯一串），整型列按值域
  选 **i8/i16/i32/i64**，块内按最小值 **bitpack**。
- 字符串/整型**块级 min/max 统计**做谓词剪枝；字典有序 rank 让字符串范围比较走整数。
- 快照为自描述块格式，文本块 **LZ4** 压缩（10M×25 列 1.57 GB），加载时解压并重建编码。
- 持久化：`.zdb` 快照 + `.wal` 重放 + 可选写回（`--writeback`）、增量 delta。
- 查询内存：语句级 arena 复用（`reset(.retain_capacity)`）+ `smp_allocator`，
  大缓冲及时归还 OS，10M 峰值 2.98–3.04 GiB。

## 已验证的 SQL 面

SELECT（投影、`*`、别名、`WHERE`、`GROUP BY` 表达式、`HAVING`、多键 `ORDER BY`、
`LIMIT/OFFSET`、`DISTINCT`）、INNER/LEFT/RIGHT/FULL/CROSS JOIN、多表 JOIN、
子查询（`IN`/`EXISTS`/`NOT EXISTS`/相关 `IN`/相关 `EXISTS`/FROM 子查询）、
`UNION`/`UNION ALL`/`INTERSECT`/`EXCEPT`、
`count/sum/avg/min/max/count(distinct)`、`CASE`/`COALESCE`/`NULLIF`、`CAST`、
字符串函数、`LIKE`、正则 `~`、`date_trunc`/`extract`/`to_timestamp`；
CREATE/DROP TABLE、多行 INSERT、UPDATE、DELETE、TRUNCATE、CREATE INDEX、
ANALYZE、VACUUM、EXPLAIN、SHOW TABLES；
BEGIN/COMMIT/ROLLBACK（回滚生效、未提交对其他会话不可见）。

## 测试

```bash
zig build test                      # 25 个单测
tests/run_functional.sh             # zighouse 功能语料：40 passed, 0 failed, 4 skipped
tests/storage_test.sh               # 快照/块/索引/流式
tests/stream_test.sh                # 流式聚合（含压缩快照）
tests/tls_test.sh                   # TLS 1.3（openssl s_client 端到端）
tests/sql_semantics_test.sh         # 集合运算/连接/相关子查询/NULL 等 20 项
tests/clickbench43_test.sh          # ClickBench 43 条执行 + 结果校验和（1M，1.2 s）
python3 tests/pg_protocol_test.py PORT   # 6/6
python3 tests/pg_catalog_test.py  PORT   # 54/54

./test/run.sh                       # pg_regress 风格：14 个标准语义 + 分析类测试
./test/run.sh pg                    # PostgreSQL 语义
./test/run.sh analytics             # 列存小数据集
./test/run.sh --update              # 有意改动后重写 expected/*.out
./test/pg18/run.sh                  # PostgreSQL 18.6 官方 test_setup/char/varchar
```

`test/pg` 覆盖字面量/运算/三值 NULL、类型与 CAST、字符串、聚合/GROUP BY/HAVING、
INNER/LEFT/RIGHT/FULL/CROSS JOIN、IN/EXISTS/FROM 子查询、集合运算、DDL/DML、
事务/回滚、错误路径和基础 `pg_catalog`；`test/analytics` 用 240 行 TSV fixture
覆盖列存谓词、字典过滤、单/双键分组、HAVING、DISTINCT、COUNT(DISTINCT)、Top-K。
未覆盖的能力见 `test/known_unsupported.md`。官方 PostgreSQL 18.6 测试从
`test/pg18/` 开始逐波接入：当前 `test_setup`、`char`、`varchar` 已跑通并
逐字节核对官方 expected，后续类型/查询组尚未移植。

4 个 skip 是需要尚未实现能力的 ClickHouse 专用用例：Parquet 导入、compactor、
物化视图、`system.disks`。

## ClickBench 复现

仓库不含数据。用官方 `athena_partitioned/hits_{0..9}.parquet`（前 10M 行）转成
25 列 TSV 后：

```bash
ZHDB_COL_LOAD=1 ./zig-out/bin/zhdb bench \
  --load=../bench/hits_10m_25col.tsv --repeat=3 ../bench/clickbench_43.sql
```

（`ZHDB_COL_LOAD=1` 表示列式流式加载；逐值核对时加 `ZHDB_DUMP_ALL=1` 并与
DuckDB 的结果集做多重集比较。）

## 已知缺口

约束（`PRIMARY KEY`/`NOT NULL`/`UNIQUE`/`DEFAULT`/`FK`/`CHECK`，尚未实现）、
`INSERT … SELECT`、`CREATE VIEW`/物化视图、窗口函数、CTE（`WITH`）、标量子查询
（相关 `IN`/`EXISTS` 已支持）、`ALTER TABLE ADD/RENAME`（兼容性 no-op）、
`||` 字符串拼接（用 `concat()`）、`DATE '...'` 字面量、`now()`/`current_date`、
`ILIKE`、`DISTINCT ON`、`NULLS FIRST/LAST`、SAVEPOINT 语义、`system.*` 表、
Parquet 导入、compactor；单机（无复制/HA），暂无自增序列。

更细的清单和每个缺口的当前行为见 `test/known_unsupported.md`。

## 许可

AGPL-3.0（见 `LICENSE`）。JIT/列式设计参考了 pgrust 的架构（见 `NOTICE`），未复制其源码。
