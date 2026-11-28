# engine.zig 拆分设计

## 1. 现状

`src/engine.zig` 目前 **36,239 行**，占核心源码的 75%。文件内同时包含：

- `Engine` 状态结构（约 700 个字段）
- `Column` / `Table` / 统计 / 事务 / 结果集 / 计划代价等共享类型
- 约 500 个 `Engine` 方法
- 约 325 个顶层工具函数
- 大量 threadlocal 会话状态
- catalog、DDL、DML、执行器、JOIN、代价模型、EXPLAIN、函数库、权限

最大的几个方法：

| 方法 | 行数 |
|---|---:|
| `evalCall` | 948 |
| `exec` | 907 |
| `Engine.destroy` | 885 |
| `refreshCatalog` | 751 |
| `execAnalyze` | 710 |
| `execSimple` | 612 |
| `execJoinChain` | 511 |
| `rawCreateDdl` | 437 |
| `estimateJoinPairs` | 391 |
| `starJoinAggregate` | 382 |
| `joinSelFiltered` | 371 |
| `rawDropDdl` | 369 |
| `execExplainOff` | 340 |

这带来三个问题：

1. 单文件导航困难，review 和 merge conflict 成本高；
2. 无法按领域建立依赖边界，DDL 代码可以直接调用执行器内部；
3. 后续把通用能力继续提到 `zhdb-support` 时，边界不清晰。

## 2. 目标与非目标

### 目标

- `engine.zig` 最终只保留 **Engine 状态、共享类型导出、方法别名、顶层 dispatch**，目标 **≤ 3,000 行**。
- 单个领域文件目标 **1,000–5,000 行**，不超过约 5,000 行。
- 不改变 SQL 行为、不改变调用点、不改变公开 API。
- 每个阶段都可独立编译、跑完整回归。
- 为后续把纯函数模块提到 `zhdb-support` 建立清晰边界。

### 非目标

- 不把 `Engine` 拆成多个互相持有的子结构（例如 `self.catalog.tables`），那会造成数千处 `self.` 修改。
- 不按 SQL 关键字拆成一堆 200 行小文件。
- 不在这一轮移动 `sql.zig` 解析器。
- 不声称拆分能显著降低运行时间；主要收益是导航、review、依赖边界和后续库化。

## 3. Zig 约束与核心方案

Zig 没有“partial struct”，不能把 `Engine` 的方法分散到多个文件后直接写 `impl Engine`。本设计使用两个已在本项目验证过的机制：

### 3.1 方法别名

领域文件里写普通函数：

```zig
// src/engine/plan.zig
const engine_mod = @import("../engine.zig");
const Engine = engine_mod.Engine;

pub fn execExplain(
    self: *Engine,
    alloc: std.mem.Allocator,
    sel: *sql.Select,
    costs: bool,
) EngineError!Result {
    ...
}
```

`engine.zig` 的 `Engine` 内只加一行别名：

```zig
pub const Engine = struct {
    // fields ...

    pub const execExplain = @import("engine/plan.zig").execExplain;
};
```

这样：

- 所有 `self.execExplain(...)` 调用点不变；
- 方法仍然有 `self` 参数；
- 不需要 `usingnamespace`；
- 别名只占一行。

已在 Zig 0.17 本机验证 `s.add(3)` 可以通过 struct 内的函数别名调用。

### 3.2 循环 import

领域文件需要 `Engine` 类型，会 `@import("../engine.zig")`；`engine.zig` 又 import 领域文件。Zig 对这类类型级循环 import 是支持的，已在 Zig 0.17 本机验证。

为了避免循环过深，只允许：

```text
engine.zig  ──import──>  domain.zig
     ^                         │
     └────────import───────────┘
```

领域文件之间尽量只通过 `model.zig` / `primitives.zig` 交互。

### 3.3 共享状态

当前大量 `threadlocal` 和常量散落在 `engine.zig`：

- `tls_diag`、`tls_notice_*`
- `tls_coll`
- `tls_params`
- `tls_row_arg`
- `tls_outer_row`
- `tls_kept_join`
- `uuidv7_*`
- `deterministicReset` 状态
- `HASH_SEED`、`COST_*`、预算常量

这些应集中到 `engine/state.zig`，领域文件 import 该模块，避免多个文件各自维护同名全局。

## 4. 目标目录

第一阶段采用 **扁平 14 个文件**，避免目录层级过深；`functions`、`catalog`、`ddl` 变大后再拆子目录。

```text
src/engine.zig                 # 入口 facade：Engine 字段 + 方法别名 + exec dispatch
src/engine/
  model.zig                    # Column/Table/统计/事务/Result/Cost 等共享类型
  state.zig                    # threadlocal、notice、diag、常量
  primitives.zig               # findCol、bindExpr、名称/作用域等无状态工具
  values.zig                   # Value 比较、coerce、cast、format、binary op
  functions.zig                # scalarFunc、evalCall、pgToChar、pgFormatString
  plan.zig                     # 代价模型、索引选择、EXPLAIN
  analyze.zig                  # ANALYZE、MCV/直方图/统计
  select.zig                   # execSelect/execSimple/applyTail/聚合/窗口
  join.zig                     # JOIN 规划/执行/fanout/join selectivity
  dml.zig                      # INSERT/UPDATE/DELETE/COPY/触发器/约束检查
  ddl.zig                      # CREATE/ALTER/DROP/raw DDL/index/view/schema
  catalog.zig                  # pg_catalog、information_schema、pg_get_*
  session.zig                  # 角色/ACL/认证/GUC/prepared/cursor
  txn.zig                      # 事务/savepoint/WAL/vacuum/GC/locks
```

### 依赖分层

```text
L0  model / state / primitives
L1  values / functions
L2  plan / analyze
L3  select / join
L4  dml / ddl / catalog / session / txn
    engine.zig（facade，import 所有层）
```

规则：

- L0 不 import 任何 `engine/*` 领域模块；
- L1 只 import L0；
- L2 import L0/L1；
- L3 import L0–L2；
- L4 可以 import L0–L3；
- 只有 `engine.zig` 可以 import L4；
- 领域模块之间禁止反向 import（例如 `plan` 不 import `ddl`）。

实际操作中允许通过 `Engine` 的方法别名调用跨层能力，而不是直接 import 对方文件。

## 5. 模块职责与目标行数

| 文件 | 预估行数 | 主要内容 |
|---|---:|---|
| `engine.zig` | 2,000–3,000 | Engine 字段、方法别名、`exec` dispatch、init/deinit |
| `engine/model.zig` | 1,800–2,500 | `Column`、`Table`、`Result`、`TxnCtx`、统计、计划类型、`EngineError` |
| `engine/state.zig` | 200–400 | threadlocal、notice/diag、collation、params、常量 |
| `engine/primitives.zig` | 800–1,500 | `findCol`、`bindExpr`、`colName`、作用域/名称工具 |
| `engine/values.zig` | 1,200–2,000 | `coerce`、`castValue`、`applyBinary`、`formatValue`、`like` |
| `engine/functions.zig` | 4,000–5,000 | `scalarFunc`、`evalCall`、`pgToChar`、`pgFormatString`、输入解析 |
| `engine/plan.zig` | 1,200–2,000 | `cost*`、`planScan`、`joinChoice`、`execExplain*` |
| `engine/analyze.zig` | 1,500–2,500 | `execAnalyze`、MCV/直方图/NDV、`ANALYZE` |
| `engine/select.zig` | 3,000–4,000 | `execSelect`、`execSimple`、`applyTail`、聚合、窗口、project |
| `engine/join.zig` | 4,000–5,500 | join DP、fanout、KeyDist、join selectivity、chain |
| `engine/dml.zig` | 2,000–3,000 | INSERT/UPDATE/DELETE/COPY/trigger/constraint |
| `engine/ddl.zig` | 3,000–5,000 | CREATE/ALTER/DROP/raw DDL/view/schema/index |
| `engine/catalog.zig` | 3,500–5,000 | `refreshCatalog`、系统表、`pg_get_*`、info_schema |
| `engine/session.zig` | 1,500–2,500 | role/ACL/auth/prepared/cursor/GUC |
| `engine/txn.zig` | 1,000–2,000 | txn/savepoint/WAL/vacuum/GC/lock |

这是目标区间，不要求一次到位。单文件超过 5,000 行时再拆子目录：

```text
engine/functions/scalar.zig
engine/functions/format.zig
engine/catalog/pg_class.zig
engine/catalog/pg_type.zig
engine/ddl/table.zig
engine/ddl/index.zig
```

## 6. 分阶段迁移

### Phase 0：基线

- 记录 `src/*.zig` 行数、`zig build test`、`./test/run.sh`、`PG18_JOBS=4 ./test/pg18/run.sh`。
- 不在同一步做行为修改。

### Phase 1：状态与类型（低风险）

1. 新建 `engine/state.zig`，移动 threadlocal/notice/diag/常量。
2. 新建 `engine/model.zig`，移动：
   - `Column`、`Table`、`RowIndex`、`ColumnDef`
   - `ColStat`、`Mcv*`、`Hist*`、`KeyDist`
   - `Result`、`RowCtx`、`AggCtx`、`TxnCtx`、`ViewDef`
   - `EngineError`、`CostEst`、`DeadBlocks`
3. `engine.zig` 顶部改成 re-export：

```zig
pub const Column = @import("engine/model.zig").Column;
pub const Table = @import("engine/model.zig").Table;
```

验收：只移动定义，100/100 回归不变。

### Phase 2：pilot，先拆 `plan.zig`

选择 `plan.zig` 作为第一个方法模块，因为它边界清楚、调用点少：

- `costWidth`、`costSeq`、`costIndex`、`costBitmap`、`planScan`
- `joinChoice`、`explainJoinCosts`
- `execExplain`、`execExplainOff`
- `buildRowIndex`、`rowIndexFor`

做法：

1. 把 `CostEst`、`JoinCost` 等嵌套类型移到 `model.zig`。
2. 把方法体复制到 `plan.zig`，函数名不变，加 `pub`。
3. 删除 `engine.zig` 中的方法体，在 `Engine` 内加别名。
4. 编译 + 回归。

验收：

- `engine.zig` 减少约 1,500 行；
- 调用点无改动；
- `EXPLAIN` 相关官方测试保持通过。

### Phase 3：叶子模块

按依赖从低到高：

1. `txn.zig`：savepoint、txn view、WAL、vacuum、GC、compaction。
2. `analyze.zig`：`execAnalyze` 及统计辅助。
3. `primitives.zig`：`findCol`、`bindExpr`、`colName`、作用域检查。
4. `values.zig`：`coerce`、`castValue`、`applyBinary`、`formatValue`。
5. `functions.zig`：`scalarFunc`、`evalCall`、`pgToChar`、`pgFormatString`。

每步都跑完整回归，不把多个领域混在同一个 commit。

### Phase 4：DML 与执行器

1. `dml.zig`：INSERT/UPDATE/DELETE/COPY/trigger/constraint。
2. `select.zig`：`execSelect`、`execSimple`、`applyTail`、聚合、窗口。
3. `join.zig`：join DP、fanout、selectivity、chain。

`select.zig` / `join.zig` 依赖最多，放在中间层完成之后。

### Phase 5：DDL 与 catalog

这两个文件最大、耦合最多，最后拆：

1. `catalog.zig`：先拆 `refreshCatalog` 的内部构建函数，再整体移动。
2. `ddl.zig`：CREATE/ALTER/DROP、raw DDL、view、schema、index。
3. `session.zig`：role/ACL/auth/prepared/cursor。

`refreshCatalog` 建议拆成：

```text
buildNamespaces()
buildPgClass()
buildPgAttribute()
buildPgType()
buildPgIndex()
buildPgConstraint()
buildPgProc()
buildInformationSchema()
```

先把它从 751 行降到若干 80–150 行的 helper，再移动文件。

### Phase 6：收尾

- `engine.zig` 只保留：
  - `Engine` 字段
  - 方法别名
  - `init` / `deinit` / `destroy`
  - `exec` 顶层 dispatch
- 目标 ≤ 3,000 行。
- 在 `build.zig` 中不需要新增模块：这些文件属于同一个 root module，直接 `@import`。
- CI 增加一条软检查：`engine.zig` 不超过 3,500 行，单文件不超过 6,000 行。

## 7. 每个阶段的验收标准

```bash
zig build --release=fast
zig build test
./test/run.sh
PG18_JOBS=4 ./test/pg18/run.sh
```

附加检查：

- `wc -l src/engine.zig` 单调下降；
- 没有新增 `@import("engine.zig")` 之外的跨层依赖；
- `git diff --stat` 只包含移动和别名，不包含逻辑改动；
- 单次 commit 不超过一个领域。

## 8. 风险与规避

| 风险 | 规避 |
|---|---|
| 循环 import 过深 | 只允许 domain ↔ engine.zig；domain 之间通过别名调用 |
| 私有类型无法跨文件使用 | Phase 1 把共享类型移到 `model.zig` 并 `pub` |
| threadlocal 被复制 | 统一放 `state.zig`，禁止领域文件自建同名全局 |
| 方法别名漏加导致编译错误 | 每移一个方法就编译；别名集中放在 Engine 尾部 |
| 移动时误改逻辑 | 只做 copy/delete + `pub`，不改函数体 |
| `refreshCatalog` 太大 | 先拆内部 helper，再移动文件 |
| 调用点大量修改 | 使用 `pub const method = module.method`，保持 `self.method()` |
| 拆得太碎 | 单文件目标 ≥ 800 行；小于 500 行的领域先合并 |

## 9. 建议的第一批实际改动

按收益/风险，建议顺序：

1. `engine/model.zig` + `engine/state.zig`（约 2,500 行移出）
2. `engine/plan.zig`（约 1,500 行，pilot）
3. `engine/txn.zig`（约 1,000 行）
4. `engine/analyze.zig`（约 1,500 行）
5. `engine/values.zig` + `engine/functions.zig`（约 4,000 行）

完成前 5 步后，`engine.zig` 预计从 **36,239** 降到 **25,000 左右**，同时不改变任何 SQL 行为。

## 10. 实施进度（2026-11-28）

已完成第一批拆分，方法别名模式验证通过：

| 模块 | 行数 | 内容 |
|---|---:|---|
| `engine/plan.zig` | 692 | 代价模型、索引选择、EXPLAIN、JOIN 代价 |
| `engine/analyze.zig` | 746 | `execAnalyze`、统计收集 |
| `engine/dml.zig` | 1,276 | INSERT/UPDATE/DELETE/COPY/触发器/约束检查 |
| `engine/txn.zig` | 839 | savepoint、GC、vacuum、compaction、WAL/cost 持久化 |
| `engine/primitives.zig` | 457 | 列查找、绑定、key/行渲染等基础工具 |

结果：

```text
engine.zig      36,239 → 32,538
engine/*.zig            3,835
核心 src 合计          48,674（含子目录）
```

注意：拆分不会减少总代码量；方法别名和新模块 import 会带来少量增量。
CI 的行数预算已改为递归统计 `src/**/*.zig`。

- 所有 `self.method()` 调用点未改动；
- 只需把跨模块使用的内部方法标记为 `pub`；
- `./test/run.sh` 18/18，PostgreSQL 18.6 官方回归 100/100。

下一批：`txn.zig`、`values.zig`、`functions.zig`、`primitives.zig`。
