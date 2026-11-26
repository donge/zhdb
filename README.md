# zhdb

用 **Zig 0.17** 从零实现的**分析型数据库**：PostgreSQL 线协议 + 列式存储 + JIT 聚合。
目标是把「协议 / SQL / 存储 / 执行」四层都做成可验证的真实实现，并用 ClickBench 官方
10M 数据集、全部 43 条查询与 Umbra / DuckDB 对比。

## ClickBench 官方 10M（43 条全查，同机同窗口）

| 指标 | zhdb | Umbra (8 vCPU) | DuckDB 2.0.1 (8 线程) |
|---|---|---|---|
| 43 条 best-of-3 | **1109.6–1169.6 ms** | 1222.8–1360.3 ms | 2117.9–2376.0 ms（文件库）/ 2210.6–2296.8 ms（内存库） |
| 峰值内存 | **3.48–3.57 GB** | 3.19–3.49 GB | 2.92–4.30 GB（文件库）/ 4.98–5.29 GB（内存库） |
| 落盘（自身格式） | **0.78 GB**（776,836,151 B） | 1.95 GB | 1.29 GB |
| 加载 10M | 4.6–4.8 s | 14.6 s | 2.2 s（内存库）/ 4.9 s（文件库） |

> 2026-11-26 同机同窗口复测（每引擎 best-of-3，两轮）：zhdb **1109.6 / 1169.6 ms**，
> 峰值 **3.48 / 3.57 GB**；DuckDB 2.0.1 内存库 **2210.6 / 2296.8 ms**，峰值
> **4.98 / 5.29 GB**。Umbra 行为同一 M4 机器最近一次可复现测量（容器客户端不可用）。
>
> DuckDB 已统一到 **2.0.1**（`../.venv-duckdb201`），复现：
> `tests/duckdb_43_10m.sh [repeat] [db-path]`（默认读取 `../bench/` 的同一份 TSV 与 43 条 SQL，
> 版本不是 2.0.1 时直接报错），细节见 `../bench/CLICKBENCH.md`。
> 快照格式 v9：字符串列按**全局字典 + 排序后的 front-coding + raw deflate**存储，
> 块内 ID 位打包后再尝试 deflate；10M 数据落盘从 **1.57 GB 降到 0.78 GB**，
> 现在比 DuckDB 2.0.1（1.29 GB）小约 40%、比 Umbra（1.95 GB）小约 60%。
> 快照编码约 45 s（一次性 `copy`），加载 7.2 s；查询路径与峰值内存不受影响。

- 43/43 全部执行；与 DuckDB 全量结果对拍，34 条逐值一致，9 条差异均为
  `ORDER BY … LIMIT` 的并列取行或 `length()` 字节 vs 字符语义，已逐行重算证明。
- 最长查询 Q29（`REGEXP_REPLACE` 取 host）252–275 ms（Umbra 427、DuckDB 1162）。
- 与同机 zighouse 对比：41 条共同查询 warm 1066 ms vs 1404 ms，cold 1317 ms vs 6385 ms。

## 查询计划（统计代价）

`EXPLAIN (COSTS ON)` 现在由可验证的统计代价模型产生，而不是固定模板：

- 估算使用表的行数与列统计（NDV、min/max、MCV/直方图；`ANALYZE` 后生效），
  选择率由 `whereSelectivity` 计算；
- 单表在 **Seq Scan / Index Scan / Bitmap Heap Scan** 三者中按启动代价与总代价取最小
  （代价含页 I/O、CPU tuple/operator，索引页按 NDV 估算）；
- 两表等值连接比较 **Nested Loop** 与 **Hash Join**（使用过滤后行数与连接列 NDV）。
- `EXPLAIN (COSTS OFF)` 输出保持不变，官方回归测试仍逐字节匹配。
- `test/pg/plan_cost.sql` 固定了 5 个计划的代价输出（1% 选择率走 Bitmap、唯一等值走
  Index、全表范围走 Seq、单行外侧走 Nested Loop、大表等值走 Hash Join）。
- **执行与计划一致（单表等值）**：计划选择 Index/Bitmap 时，行表执行器用按索引首列
  惰性构建的哈希索引取候选行，而不是全表扫描；表版本变化（INSERT/UPDATE/DELETE）
  会自动失效并重建。`tests/index_scan_test.sh` 在 20 万行上验证索引/顺序扫描结果
  完全一致、索引执行快 2 倍以上，并检查 UPDATE/DELETE 后的失效正确性。
- **连接执行与计划一致**：两表等值连接按同一代价模型在 Nested Loop 与 Hash Join
  之间选择并执行；EXPLAIN 的节点/rows/代价与执行器的 `[plan] join method=...` 完全
  对应。`tests/join_plan_test.sh` 验证 1 行外侧走 Nested Loop、大表等值走 Hash Join，
  结果正确（100 行 / 40000 行）且两种方法代价与 EXPLAIN 一致。

## JIT 证据

JIT 生成的 ARM64 内核有可重复的正确性与加速比测试：

- `jitbench`：2,000,000 行上 JIT scalar 与 NEON8/NEON16 求和均为
  **99,000,000**，与 Zig 标量循环一致；
- `jitgroup`：JIT 分组计数 1000 组 / 2,000,000 行，`sum_counts=2,000,000`；
- `jitloop`：同一数据 5000 次迭代，Zig 标量 **1.01 s**，JIT NEON16
  **0.82 s**（约 19% 加速），两者累加和相同（495,000,000,000）。
- 复现：`tests/jit_test.sh`（临时生成数据并断言正确性/加速比）。
  同时修复了分组内核把 `ng` 指针误用作哈希掩码导致越界/死循环的问题。

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

./test/run.sh                       # pg_regress 风格：17 个标准语义 + 分析类测试
./test/run.sh pg                    # PostgreSQL 语义
./test/run.sh analytics             # 列存小数据集
./test/run.sh --update              # 有意改动后重写 expected/*.out
./test/pg18/run.sh                  # PostgreSQL 18.6 官方回归（86 个文件逐字节匹配）
```

`test/pg` 覆盖字面量/运算/三值 NULL、类型与 CAST、字符串、聚合/GROUP BY/HAVING、
INNER/LEFT/RIGHT/FULL/CROSS JOIN、IN/EXISTS/FROM 子查询、集合运算、DDL/DML、
事务/回滚、错误路径和基础 `pg_catalog`；`test/analytics` 用 240 行 TSV fixture
覆盖列存谓词、字典过滤、单/双键分组、HAVING、DISTINCT、COUNT(DISTINCT)、Top-K。
未覆盖的能力见 `test/known_unsupported.md`。官方 PostgreSQL 18.6 回归已接入
**86 个测试文件**（类型 I/O、DDL/DML、目录视图、事务、索引访问方法、引号标识符、
`psql` 客户端 `\crosstabview` 等），全部逐字节核对官方 expected；清单与运行方式见
`test/pg18/README.md`。

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
