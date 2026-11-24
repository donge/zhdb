# zhdb 架构评审：与 Umbra / DuckDB / ClickHouse 的关键实现对比

> 依据：本仓库当前代码（8,186 行 Zig，`src/*.zig`）+ 本次会话中的实测数据；
> Umbra/DuckDB/ClickHouse 侧为公开论文/文档层面的架构事实，个别细节标注为"近似"。

## 0. 一句话定位

zhdb 是**单进程、纯内存、列式 + 手写 JIT 内核**的执行器，**没有存储层**（无 buffer manager、
无压缩、无持久化、无 MVCC），优化器是**代码中的规则分支**而非代价模型。它在 1M 行 ClickBench
上靠"列存 + 分片 + 紧凑分组记录 + Top-K + SIMD 谓词"跑赢 Umbra 的**冷态单次执行**（0.54×），
但这是**同规模数据集上的工程对齐**，不是引擎能力的对齐。

## 1. 代码地图（8,186 行）

| 文件 | 行数 | 职责 |
|---|---|---|
| `src/columnar.zig` | 3,752 | 列存执行器：谓词、分组、聚合、DISTINCT、Top-K、输出 |
| `src/engine.zig` | 1,706 | 行存表（`rows: [][]Value`）、catalog、列存物化、**回退解释执行** |
| `src/jit.zig` | 946 | ARM64 copy-and-patch 内核（sum/分组聚合/内联记录） |
| `src/sql.zig` | 795 | 词法/语法/AST |
| `src/main.zig` | 552 | CLI（serve/run/query/load/bench/jitbench/jitloop/jitgroup）、bench 计时 |
| `src/pg.zig` | 374 | PostgreSQL v3 线协议（Q/P/B/D/E/S） |
| `src/value.zig` | 61 | `Value` 联合体（null/int/float/text/boolean） |

数据结构：`Table{cols, data: []Data, enc: []?Encoding, scratch}`；`Data = ints|floats|strs{offsets,bytes}`；
`Encoding{ids, first, rank}`（字典 id + 首次出现行 + 字典序 rank）。

## 2. 关键架构对比

| 维度 | zhdb | Umbra | DuckDB | ClickHouse |
|---|---|---|---|---|
| 存储 | 纯内存；行存 `[][]Value` + 列存副本（`buildColumnar`） | 磁盘块（约 64 KiB）+ buffer manager + 指针 swizzling | 单文件、块 + buffer manager + WAL/checkpoint | MergeTree parts（granule 8192）+ 稀疏主键索引 |
| 压缩 | **无**（字符串有字典） | 块内紧凑布局（近似的列压缩有限） | 轻量压缩：RLE/bitpack/dict/**FSST**，可**直接压缩执行** | 每列 codec：LZ4/ZSTD + Delta/DoubleDelta/Gorilla/T64；LowCardinality |
| 跳数索引 | **无**（无 zonemap/统计） | 无显式 zonemap（有块级 min/max 的过滤能力） | zonemap + 统计信息传播 | minmax/set/bloom/ngrambf 跳过索引 + PREWHERE |
| 执行模型 | 列式，按算子函数分段；`Sel{list,n}` 表达选择集 | **编译执行**（LLVM pipeline）+ 数据驱动 | **向量化 push pipeline**（morsel + selection vector） | **processor/port push 管道** + 列 Block 向量化 |
| 并行 | `std.Thread`，固定 8 线程，按 key hash 分片 | **morsel-driven** + 任务调度器 | **morsel-driven** + 任务调度器（可扩展） | 按 part/stream 并行，pipeline 内并行 |
| 分组哈希表 | 开放寻址；**紧凑记录** `[first, acc0..2]`（16/32 B），组键通过代表行比较 | **HAT（hash array table）**，8 B 条目；**compact** 变体把组键+聚合状态内联进表 | 线性探测 8 B 条目；**perfect hash**（小域）+ **radix 分区两阶段**聚合 | 两层聚合（hash→256 桶再合并）；低基数走 per-key 聚合 |
| 聚合累加 | JIT 内核内联累加（AVG 用 count 派生） | 编译内联 | 向量化 + 压缩执行；分组聚合有专门的 hash 表实现 | SIMD 聚合函数（`AggregateFunction` 状态机） |
| Join | **未实现**（仅词法识别） | hash join + bloom/SIP，编译 | hash join（radix）、piecewise merge、IEJoin、delim join | hash join / partial merge / grace hash |
| 排序 | 有界 Top-K（int/rank/双键专用 + 通用堆）；无全排序优化 | 排序 + Top-K | radix sort（定长）/ merge（变长）+ Top-N 堆 | 外部归并排序（可落盘）；`ORDER BY ... LIMIT` 优化 |
| 谓词/SIMD | `@Vector` 16 B 首字节掩码 LIKE；int 比较 2 lane；**按代价排序谓词**；短路 | 编译进 pipeline | 向量化 + selection vector + filter pushdown | 向量化函数 + PREWHERE 提前过滤 |
| 代码生成 | **手写 ARM64 stencil**（`jit.zig`，约 39 条指令/内核） | **LLVM** 全查询编译 | 向量化解释（部分实验性 JIT），主路径不开 JIT | `compile_expressions` / `compile_aggregate_expressions`（LLVM，可选） |
| 优化器 | **规则分支**（按 group_cols/specs/selection 形状选路径），无代价/统计 | 代价模型（HyPer 血统）+ 基数估计 | 代价模型：join order DP、统计传播、filter pushdown、压缩物化 | 规则 + 部分代价；基于统计的 join 顺序 |
| 事务/恢复 | **无** | MVCC（原地更新 + undo） | MVCC + WAL + checkpoint | 有限（语句级原子性；多语句事务实验性） |
| 字符串 | 字典（id + rank）+ offset/bytes；LIKE 走 SIMD 子串扫描 | 块内变长/字典（近似） | FSST + 字典 + string heap | LowCardinality + 字典；`ngrambf` 加速 LIKE |
| 类型/NULL | `Value.null` 存在，但**列存无 null 位图**（聚合按"无 NULL"处理） | 完整 NULL 语义 | 完整 NULL 语义（validity mask） | 完整 NULL 语义 |
| 协议/接口 | PG v3（Parse/Bind/Describe/Execute/Sync） | PG 兼容 | C API/多种 | 自有 TCP 协议 + PG 兼容层 |

## 3. zhdb 的实现细节（评审锚点）

### 3.1 列存与字典
- `Table.build`（columnar.zig:100 起）：一次性把行存转列存；字符串列同时建 `Encoding{ids, first}`；
  低基数 int 列（`distinct ≤ max(1024, n/4)`）也建字典。字符串字典在 ≤100k 项时再建**字典序 rank**，
  让 `ORDER BY <str>` 与 `MIN(<str>)` 退化成整数比较。
- `Table.groupKeyPtr/groupKeySlice`：分组/去重统一走"int 值或字典 id"，这是把字符串分组塞进
  整数 JIT 内核的关键抽象（等价、无哈希碰撞）。

### 3.2 谓词
- `filter`（927）：先尝试 AND 链的 `collectFastPreds`（`LIKE '%lit%'`、`col <> ''`），
  **按代价排序**（长度检查在前、子串扫描在后）→ Q21/Q22 的 LIKE 只对 71k 行执行；
- `filterIntCmp`（750）：`<int col> <op> <const>` 用 `@Vector(2,i64)`；
- `containsSub`（18）：16 B NEON 首字节掩码 + 候选 `mem.eql`，长串回退 `memmem`；
  （试过 32 B 双字符前置过滤与双向量展开，**均更慢**，已回退并记录在 `bench/CLICKBENCH.md`。）

### 3.3 分组与聚合
- `jitGroupAgg`（2527）：JIT 分组聚合的统一入口。三条路径：
  1. **重扫路径**（`rescan`：全表扫描且所有分组键有字典）——不物化 gather，内核用 `shard_mask` 只处理本分片的行，`first` 即全局行号；
  2. **单趟定容分区**（`capb = n/T + 25%`）——一趟完成"哈希 → 定位桶 → 写行号 + 写已 gather 的键值"；
  3. **两趟精确分区**（溢出/内存不足时的回退）。
- 组记录紧凑化：`rstride = 1 个累加器 ? 2 : 4` 个 i64，一次探测一条 cache line（Umbra compact entry 的对应物）。
- Top-K：先在记录上做**有界有序表**预选，只物化 k 组（Q31 从 16 ms 降到 6–7 ms 的主因）。
- 完整性校验：`Σ count == 输入行数`，不符回退通用路径。

### 3.4 DISTINCT
- `countDistinctDense`：字典列 → 位图 + popcount（Q5/Q6 0.35 ms）；
- `groupedDistinctAgg`（1951）：组值→稠密 gid；distinct 列有字典时用**每组位图 + `@atomicRmw(.Or)`**；
  组数多时把 `(gid,id)` 打包 u64 排序按 run 计数；否则按值 hash 分区 + 每线程定长表。

### 3.5 JIT（`jit.zig`）
- copy-and-patch：`DynCode` 发指令字 → mmap RW → memcpy → `sys_icache_invalidate` → mprotect RX；
- 内核：`compileSumI64`、`compileSumI64Vec/16`、`compileGroupAgg`（1–3 键 + count/sum/avg）；
- **平台陷阱**：Darwin/ARM64 的 `x18` 是平台保留寄存器，早期内核用它存探测下标，
  导致 OS 抢占时随机改写 → 分组被拆开（非确定性错值）。现已改用 `x11` 并写进注释 + 回归测试。

## 4. 代码评审：技术债与风险

**未使用的内核**（死代码，占 `jit.zig` 约 1/3）：
`compileSumFilteredI64`、`compileSumOffsetI64`、`compileGroupCountI64`、`compileGroupInline`
在 `columnar.zig` 引用数为 0（后两者是早期/实验版本）。建议删除或加 `test` 覆盖后再接入。

**NULL 语义缺口**：`Value` 有 `null`，但列存 `Data` 无 validity 位图，
`accUpdate` 对 `count(col)` 直接等同 `count(*)`（columnar.zig:1394 附近注释"No NULLs in columnar data"）。
这在 ClickBench 数据上成立，但**不是通用语义**——是当前最大的语义债。

**无存储层**：`engine.zig` 的行存 `rows: [][]Value` 只为加载存在，列存是"全量副本"；
没有 buffer manager / 压缩 / 持久化 / 事务。1M 行内存约 150–200 MB（含 `scratch` 48 B/行）。
数据规模从 1M 涨到 100M 时该设计不可用（内存与加载时间均线性）。

**并行是"固定 8 线程 + 每个算子自行 spawn"**：每个算子各自 `std.Thread.spawn`（14 处），
没有任务队列/morsel 调度，线程创建开销在短查询上可达 5–10%。
且所有 `spawn` 都有 `catch null` 内联兜底（正确的兜底，但也说明没有真正的调度器）。

**优化器**：`aggregate`/`projectRows` 里是一串"形状匹配"的 `if`（字典列？单键？Top-K 别名？）。
没有统计信息（`ANALYZE` 无）、没有代价比较、没有 join 顺序——一旦查询形状超出预设分支，
就退化到 `GroupTable` 通用路径（最慢可差 10×，见 Q9 早期 11.6 → 5.2 的演进）。

**诊断设施已内建但非常驻**：`ZHDB_PROF`（分段计时）、`ZHDB_VERIFY`（逐组重算）、
`ZHDB_NO_JIT`、`ZHDB_SERIAL_FILTER`。建议把 `VERIFY` 做成 CI 门禁（5 次全量 + 值比对）。

**PG 协议**部分实现：无 `COPY`、无真实参数绑定（`Bind` 只回 `BindComplete`）、
无 `TextDescribe`/`Binary` 格式协商；够测试用，不足以接 BI 工具。

## 5. 与 Umbra 的对齐度（原始目标为"参考 Umbra 架构"）

| Umbra 机制 | zhdb 对应 | 对齐度 |
|---|---|---|
| 编译执行（LLVM 全查询） | 手写 stencil 的**算子级** JIT（分组/求和） | 部分：只覆盖最热的两个算子 |
| 紧凑分组记录（compact HAT） | 16/32 B 记录 + 单次探测一条 cache line | **已对齐**（Q31 6.6 ms vs 9.3） |
| morsel-driven 并行 + 任务调度 | 固定 8 线程 + 算子内 spawn | 未对齐（无调度器、无 work-stealing） |
| 早聚合 / 预聚合 | Top-K 预选 + 分片内先聚合 | 部分 |
| bloom / SIP 做 join 过滤 | 无 join | 不适用 |
| 代价模型 + 基数估计 | 规则分支 | 未对齐 |
| 块存储 + buffer manager + MVCC | 无 | 未对齐（不在当前目标范围） |

结论：zhdb 在 **"单机内存内、单表聚合/过滤/排序"** 这一子集上把 Umbra 的**关键执行技巧**
（列存、紧凑组记录、JIT 内核、Top-K、分片并行）落到了实处并跑赢；但在**存储、优化器、
并行调度、join、事务**五个维度上与 Umbra 不是同一类系统。

## 6. 与 DuckDB / ClickHouse 的可借鉴点（按 ROI）

1. **zonemap / min-max 跳数索引**（DuckDB、CH 都有）：`Sel` 之前先按 1024/8192 行的块做 min-max
   剪枝，对 `CounterID = 62`、`EventTime` 范围类谓词可直接跳过 90%+ 的块。zhdb 现在**逐行过滤**，
   这是最容易拿到数量级收益的一项。
2. **压缩存储**（DuckDB 的 bitpack/RLE/FSST、CH 的 codec）：目前 `i64` 全量存储，
   `RegionID`、`AdvEngineID`、`IsRefresh` 这类列用 bitpack 可省 4–8× 内存与带宽。
3. **radix 分区两阶段聚合**（DuckDB）：zhdb 用"单趟定容桶 + 溢出回退"达到同样目的，
   但 DuckDB 的两阶段对**倾斜键**更稳（无回退）。zhdb 的 25% 余量就是为低 3 位偏斜打的补丁。
4. **PREWHERE / 谓词下推顺序**（CH）：zhdb 已做"按代价排序谓词"（Q21 3.37→0.54 ms），
   可以进一步做"按选择率排序"（需要统计信息）。
5. **两级聚合 + 每个 key 的聚合（perfect hash）**（CH/DuckDB）：zhdb 对低基数分组已用
   字典 + 稠密 gid，接近 perfect hash；但缺少"按行块预聚合再合并"的中间层。
6. **表达式级 JIT**（CH 的 `compile_expressions`）：zhdb 的 JIT 只覆盖分组/求和，
   若把 `WHERE` 组合谓词也编译成一条内核（而不是逐谓词函数调用），Q20–Q23 还有下降空间。
7. **selection vector 统一表示**（DuckDB）：zhdb 用 `Sel{list,n}` + 各算子自建 `ArrayList(u32)`，
   在算子链上是"物化选择集"；DuckDB 的 selection vector 在算子间传递更省。

## 7. 建议的下一步（按收益/风险）

| 优先级 | 事项 | 预期收益 | 风险 |
|---|---|---|---|
| P0 | **块级 min-max 剪枝**（zonemap，加载期建） | 过滤类 Q2/Q19/Q20–Q26 可能 2–5×；总量再降 10–20% | 低（纯新增，可开关） |
| P0 | 把 `ZHDB_VERIFY` 做成 CI 门禁 | 防止再次出现"偶发错值" | 极低 |
| P1 | 删除 4 个未使用 JIT 内核 + 清理 `_ = &nsums` 等占位 | 可维护性 | 极低 |
| P1 | 低基数列 bitpack 存储 | 内存/带宽 2–4×，Q9/Q10/Q13–Q15 受益 | 中（需改 `Data` 与内核读法） |
| P2 | 统一 selection vector（避免算子间多次物化） | 中 | 中 |
| P2 | morsel 调度器（线程池替代 spawn） | 短查询 5–10% | 中 |
| P3 | join（hash join + bloom） | 打开 TPC-H 类查询 | 高 |
| P3 | NULL 位图 | 通用语义 | 中（触及所有聚合/比较） |

## 8. 复现证据

```bash
# 31 条 ClickBench（1M 行，冷态 repeat=1）
./zig-out/bin/zhdb bench --load=../bench/hits_1m17_schema.tsv --repeat=1 ../bench/clickbench_1m.sql

# 最近的实测：合计 52.7–53.9 ms（Umbra 98.9），31/31 条不慢于 Umbra
# 值校验：diffs = [4, 18, 27, 30, 31]（浮点打印 / 无 ORDER BY 与并列顺序 / length() 按字节）
# 正确性诊断：ZHDB_VERIFY=1（逐组重算），22 次全量 0 次 mismatch
```
