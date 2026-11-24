# Umbra → zhdb 结构映射

本表把静态/运行时分析得到的 Umbra 内部结构，对应到 Zig 0.17 重写版 `zhdb` 的落点，
并标注当前实现状态。

| Umbra 观察到的组件 | 证据来源 | zhdb 对应实现 | 状态 |
|---|---|---|---|
| PostgreSQL v3 线协议、SSLRequest、`server_version` 参数 | 实测 psql/裸 socket | `src/pg.zig`：startup、`N` 拒绝 TLS、simple query、Parse/Bind/Describe/Execute/Sync、RowDescription/DataRow/ErrorResponse | 已实现（无 TLS） |
| `pg_settings` 493 项兼容垫片、`server_version_num=110003` | `show all` | 未实现；`version()` 直接返回自述字符串 | 未实现 |
| `UmbraDB\0` 文件头 + u32 版本/格式 + JSON 元数据 | `xxd` 文件头 | 无持久化 | 未实现 |
| `*.db.pages` 8 KB 页文件 | 文件布局、`block_size` | 无 | 未实现 |
| `*.db.wal` + 分段 WAL、checkpoint/recovery 字符串 | 文件布局、strings | 无 | 未实现 |
| 列式 `RelationColumn` / `RelationPagedPartition` | 断言字符串 | 行存 `Table.rows: [][]Value` | 简化实现 |
| morsel 并行 + `Morsel`(146 次) | 断言字符串 | 单线程执行，连接级互斥锁 | 未实现 |
| LLVM 21 + xbyak JIT、`umbra::codegen::` 1.4 万符号 | `ldd`、strings | 解释执行表达式树 | 未实现 |
| 算子：`HybridGroupJoin`、`HashTrieJoin`(WCOJ)、`KdBandJoin`、`BandJoin`、`BNLJoin` | strings | 仅 `groupby`/`tablescan`/hash 聚合语义，无 JOIN | 未实现 |
| 排序/Top-N：`SortOperator`、`FrequentOperator` | strings、`EXPLAIN` | `ORDER BY` + `LIMIT/OFFSET`（全量排序） | 简化实现 |
| `ParquetScanOperator` / `CSVScanOperator` / `BTreeBulkLoadOperator` | strings | 无导入 | 未实现 |
| 哈希表族：Compact/KeyValue/RobinHood/Chaining | strings | `StringHashMap` 做分组键 | 简化实现 |
| 定点 `numeric(38,6)`、`BigNumericRuntime` | 实测 `numeric` 截断 | `float`（f64） | 退化实现 |
| 类型运行时 Text/Array/ByteArray/Bit/Date/Time/Timestamp/Interval | strings、`pg_type` 43 项 | int/float/text/bool/date/timestamp（日期按 ISO 文本） | 子集 |
| 表达式语义：LIKE、IN、BETWEEN、CASE、CAST、IS NULL | 实测 | `src/engine.zig` 同名分支 | 已实现 |
| 聚合：count/sum/avg/min/max、`count(distinct)`、`HAVING` | 实测 | 同上，分组哈希 + 累加器 | 已实现 |
| 方言兼容：`ENGINE=`、`UInt*`/`Date`/`DateTime('tz')`/`LowCardinality`、`count()`、`if()`、`toString()`、`toYear...` | zighouse 用例 | `src/sql.zig` 类型/子句忽略 + `scalarFunc` | 已实现 |
| 缺失能力：MERGE、游标、SAVEPOINT、隔离级别、触发器、物化视图、GRANT、扩展、PL/pgSQL | `not implemented yet` 字符串与实测 | 同样未实现（解析层直接忽略或报错） | 一致 |
| `pg_roles` → `FATAL: bad optional access`（可复现缺陷） | 实测 | 无 `pg_roles` 表，返回 TableNotFound | 不复刻缺陷 |

## 测试对应关系

- 功能语料：`../zighouse/tests/functional`，40 通过 / 0 失败 / 4 跳过（parquet 导入、compactor、物化视图、`system.disks`）。
- 线协议：`tests/pg_protocol_test.py`（6 项）+ 真实 `psql` 18 手工验证。
- 单元测试：`zig build test`（字面量、聚合+排序、LIKE+LIMIT）。

## 下一步优先级

1. 页式存储 + WAL + 重启恢复（先把 `UmbraDB` 文件头级别的元数据持久化做出来）。
2. 事务/快照隔离，移除全局锁。
3. 哈希连接与 GroupJoin；再评估 HashTrieJoin（WCOJ）。
4. 列式 chunk 执行 + morsel 并行。
5. 可选：Zig 侧 codegen 替换解释器。

## 第三轮：按 REA 证据做的性能改造

| REA 证据 | 改造 | 位置 |
|---|---|---|
| `cts/codegen/**`：表达式编译期特化 | `bindExpr` 把列引用改写为下标 | `src/engine.zig` |
| `HybridGroupJoin` / `CompactHashTable` | 单趟分组 + 每累加器状态 | `runAggregated` / `updateAcc` |
| `_pickMorsel` / 各算子 `Morsel` 类 | 8 路行区间并行 + 线程内哈希表 | `aggregateParallel` |
| `FrequentOperator` / `frequentProbe` | 有界 Top-K 堆 | `applyTail` + `siftDown` |
| `ChainingHashTable::ScanMorsel` | 并行 distinct（分片集合并集） | `AggWorker` + `mergeAcc` |
| `DataBlockJob` | 并行谓词过滤 | `filterParallel` |

## 第四轮：反编译内核 → Zig 直译

| 反编译证据 | Zig 实现（`src/columnar.zig`） |
|---|---|
| `rts/storage/column/*` 列存 | `Data{ints,floats,strs}` 连续数组 |
| `CompactHashTable`（`hashTableShift`/`extraSlots`） | 2 的幂开放寻址表 + 连续 `[]Acc` |
| `CompactHashTable::RangeScanJob::Morsel` | 按 key hash 分片到 8 线程，无合并 |
| `_pickMorsel` | selection 分块并行（`u32` 行号） |
| `FrequentOperator::RangeJob::Morsel`/`frequentProbe` | `limit+offset` 有界堆 |
| `cts/codegen` 表达式特化 | 类型化 `Scalar` 求值、列下标直接访问 |

ClikBench 1M×17 列：6386 → 1165 → **472 ms**（DuckDB 71、Umbra 99、zighouse 93）。

## JIT 原型

`src/jit.zig` + `docs/jit.md`；`zhdb jitbench --load=...` 对比 Zig 循环与手写 JIT 内核。

## 第五轮：Top-K 直出（对齐 Frequent/early-stop）

分组 JIT 输出阶段按排序键保留 top-k 组，避免为 1M 组物化 Group/Acc（~100 MB）；
`ORDER BY` 别名解析回聚合表达式。Q31 68.6→16.7 ms、Q30 104→16.7 ms、Q16 11.9→5.2 ms，合计 285→217 ms。

## 第六轮：SIMD 子串扫描

`containsSub`：`@Vector(16,u8)` 比较首字节 + `@bitCast` 得掩码，逐候选 `memcmp`；
短串（≤128B）走内联循环，长串回退 libc memmem。Q20 10.7→3.4 ms、Q22 16.7→2.5 ms，合计 217→181 ms。

## 第七轮：DISTINCT 分区去重

`countDistinctI64` / `countDistinctStr`：按 hash 把值/行号分到 8 个互斥桶，线程内建集合，无合并。
Q5 9.1→4.4 ms，Q6 8.6→7.5 ms；filtered JIT 的顺序依赖已用串行 filter 实验证实。

## 第八轮：DISTINCT 分区 + 复用 hash

`countDistinctI64/Str` 按 hash 分桶避免集合合并；`shardedAggregate` 复用分区 hash 做探测。
合计 178→166 ms；分组内核单独复现出 3 个多余分组（排序输入，键 22973），filtered JIT 仍禁用。

## 第九轮：x18 平台保留寄存器（关键正确性缺陷）

Darwin/ARM64 的 `x18` 是平台保留寄存器，OS 可随时改写。分组 JIT 曾用它存探测下标，
造成"同一分组被拆成两个"的非确定性错误（组数 48608↔48617 波动、Q27 计数 393034–393038 波动）。
改用 `x11` 后内核结果完全确定，filtered 分组 JIT 因此得以启用：Q27 18.1→5.8 ms，
31 条合计 165.5→154.7 ms。回归测试 `group kernel is deterministic and exact` 固定该行为。

## 第十轮：分组 DISTINCT 的"稠密 gid + 值分区"

`groupedDistinctAgg`：组值映射为稠密 gid（小范围用 LUT），再按 distinct 值 hash 分桶，
各线程用定长 `{gid,val}` 开放寻址表去重，线程私有计数最后相加。Q9 11.6→6.7 ms、Q10 14.3→8.0 ms；
合计 154.7→144.0 ms。值仍与 DuckDB 一致（Q9 28195、Q10 37978/422834/1604.16784/28195）。

## 第十一轮：字符串字典编码 → 走整数分组内核

`Table.enc[ci] = {ids, first}` 在列存转换时构建；`groupKeyPtr` 让字符串分组列以 id 数组进入
多键 int JIT 内核（`GROUP BY UserID, SearchPhrase` → `GROUP BY UserID, code`，精确无碰撞）。
`COUNT(DISTINCT string)` 同样对 id 去重。Q17 17.7→5.0、Q18 11.0→5.8、Q6 8.0→5.1 ms；
合计 144.0→124.7 ms。转换时间 0.23→0.35 s。

## 第十二轮：紧凑组记录 + 有界 Top-K

- 组记录内联为 `[first, acc0(, acc1, acc2)]`（16/32 B），一次探测一条 cache line，对应 Umbra compact hash entry；
- Top-K 预选改为有界有序表（满 k 后仅一次比较，并列跳过），Q31 的 `topk-scan` 11.0→1.2 ms；
- 无 ORDER BY 且带 LIMIT 时只物化前 k 组（Q18 由 ~600k 组降到 10 组）。
Q31 16.0→7.2 ms（已快于 Umbra 9.3），合计 124.7→120.0 ms。

## 第十三轮：DISTINCT 路径（常驻 scratch / 高位分区 / Fibonacci 哈希）

1. `Table.scratch`（32 B/行，常驻）供分区缓冲复用，消除每查询新 mmap 的缺页成本；
2. 分区改为取哈希**高位**并按实际桶大小 scatter —— 低位偏斜曾导致某桶溢出、退化成串行哈希表（Q5 +5 ms）；
3. `fibHash` 一次乘法取高位；`groupedDistinctAgg` 合并 gid 分配与分区分桶为一遍。
Q5 4.8→3.6、Q6 5.6→3.9、Q9 7.0→5.2、Q10 7.7→6.3 ms；合计 120.0→112.1 ms。

## 第十四轮：门槛、SIMD 谓词、字典位图 + 两个缺陷修复

- 分组 JIT 门槛 100k → 16,384（过滤后 71k 行的 Q29/Q30 不再退回通用路径）：7.35→0.97、6.13→0.94 ms；
- `COUNT(DISTINCT 字典列)` 用稠密 id 位图 + popcount：Q6 5.14→0.35 ms；
- 常量整型谓词用 `@Vector(2,i64)`：Q19 1.92→0.22、Q2 2.53→0.35、Q8 2.67→0.52 ms；
- 分组分区第二趟重算哈希（不落 8 MB 哈希数组）：hash+partition 4.0→2.2 ms。
- 修 `Table` header 在自己的 arena 里却用 gpa 释放（无效释放）；修 DISTINCT worker 用非线程安全的
  查询 arena 分配私有表（内存破坏，曾导致 Q29/Q17 偶发错值）。
合计 112.1→82.2 ms（Umbra 98.9），19/31 条已快于 Umbra。
## 第十五轮：分组 DISTINCT 接受字典键
Q14（GROUP BY SearchPhrase + COUNT(DISTINCT UserID)）原先因字符串分组列与 100k 行门槛走通用路径；改为接受字典 id 并把门槛降到 16,384 后 6.30→4.12 ms。去重表改用常驻 scratch。
## 第十六轮：字典 + 位图 DISTINCT
低基数 int 列在转换期建字典（n/4 基数上限）；`COUNT(DISTINCT)` 变为位图 popcount，分组版用每组位图 + 原子 OR，组数很多时改用 (gid,id) 打包排序。Q5 4.35→0.35、Q9 7.12→3.13、Q10 7.76→3.75 ms；合计 81.4→71.3 ms。
## 第十七轮：通用输出 Top-K
通用分组输出在 `ORDER BY <agg> LIMIT k` 时先用 Acc 状态算排序键、保留 top-k 组再物化（省掉 19,743 组 ×Value 与全量排序）。Q14 4.86→1.94 ms；合计 71.3→67.1 ms，22/31 条快于 Umbra。
## 第十八轮：ORDER BY 列直接 Top-K
ORDER BY 单列（int）直接用列数组做有界选择；字符串列用字典的字典序 rank 比较整数；双键 (int,rank) 同理。Q24 1.93→0.46、Q25 1.55→0.48、Q26 1.84→0.51 ms；合计 67.1→64.9 ms，25/31 条快于 Umbra。
## 第十九轮：融合 gather、向量化 MIN/MAX、spawn 兜底
① 分区散射时顺带写入 gather 好的键列，去掉一次 1M 行随机 gather（Q16 4.83→2.74、Q17 4.08→3.00、Q18 4.04→2.90）；② 标量 MIN/MAX 用 8 路 @min/@max 扫描（Q7 1.87→0.26）；③ 所有线程 spawn 增加内联兜底，避免 spawn 失败时静默丢行（Q13 一次性错值的可疑来源）。合计 64.9→59.5 ms，27/31 快于 Umbra。
## 第二十轮：字符串 MIN 走字典 rank + 稳定性复核
MIN/MAX(<str>) 在有 rank 的字典列上比较整数（≤100k 项字典才建 rank，URL/Title 走原路径）。5 次连跑：合计 59.3–64.2 ms（Umbra 98.9），值差异 5/5 均为 [4,18,27,30,31]，27/31 条快于 Umbra；剩余 Q16/Q17/Q21/Q22 差 0.13–0.51 ms。加上 spawn 兜底后 11 次全量运行未再出现 Q13 异常。
