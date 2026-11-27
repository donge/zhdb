# zhdb PostgreSQL 兼容性差距评估与 TODO（2026-11-27 实测）

> 结论先行：当前最大的差距**不是"功能少"**，而是 **静默失败、错误码错误、元数据/版本字符串不匹配**。
> 这三类正是 PGConf.EU 2025「Riga 共识」里最扣分的项（`No silent failures`、SQLSTATE 一致、
> `pg_catalog` 可用、版本字符串满足客户端）。优先修完 P0（约 1,800 行 / +69 KB，二进制 +1.4%），
> 兼容性观感会有质变；全量 P0–P3 约 14,500 行 / +590 KB，二进制从 4.79 MB 增至约 5.38 MB（+12%）。

## 1. 测量方法与环境

| 项 | 值 |
|---|---|
| Zig | 0.17.0 |
| 构建 | `zig build --release=fast`（增量，未重编） |
| 二进制 | `zig-out/bin/zhdb` = **4,790,824 B（4.79 MB）**；`strip` 后 4,434,400 B（4.43 MB） |
| 动态链接 | libSystem / libiconv / libicucore（`tls`、`regex`、`lz4`、`btree` 为静态 Zig 依赖，已在二进制内） |
| 源码规模 | **47,153 行 Zig**（`engine.zig` 35,666；`sql.zig` 5,174；`main.zig` 1,685；`columnar.zig` 1,302；`pg.zig` 1,256；`storage.zig` 1,177；`jit.zig` 606；其余 343） |
| 单元测试 | `zig build test` 通过 |
| 官方回归 | `./test/pg18/run.sh` → **96 通过 / 0 失败**（schedule 全量；README 记录的 90 已过时） |
| 协议探针 | `tests/pg_gap_probe.py`（纯 socket，不依赖 psycopg/psql），启动 `zhdb serve` 后跑 50+ 项 SQL/协议探测 |

> 注意：`test/known_unsupported.md` 已明显滞后（仍写 CTE/RETURNING/窗口不支持），实测这些功能已可用。
> 本报告以实测为准，文档仅作历史参考。

## 2. 分层差距（实测证据）

标记：✅ 可用 ｜ ⚠️ 部分/有副作用 ｜ ❌ 缺失或静默失败

### L1 Connect（协议）

| 项 | 状态 | 实测证据 |
|---|---|---|
| 启动序列 | ✅ | `R`(AuthOk) → `S`×9(ParameterStatus) → `K`(BackendKeyData) → `Z` |
| Simple Query `Q` | ✅ | `SELECT 1` / 多语句 / 空查询均正常，CommandComplete tag 正确 |
| Extended Query `P/B/D/E/S` | ⚠️ | 序列 `1,2,n,T,D,C,Z`；**Describe 返回 `n`(NoData) 而非 `T`(RowDescription)** → JDBC/psycopg 拿元数据会失败 |
| CommandComplete tag | ⚠️ | `SELECT n` / `INSERT 0 n` 正确；`LOCK TABLE` 返回 `SET`（可疑） |
| SSLRequest 协商 | ❌ | 默认启动下发送 SSLRequest(80877103) **超时无响应**（server 把它当 startup 读）；`--tls` 模式下已实现 TLS |
| 认证 | ⚠️ | md5 已实现（`pg.zig:195,272-287`）；未见 SCRAM-SHA-256 |
| 版本字符串 | ❌ | `version()` = `Zhdb 0.1 ... PostgreSQL 18.1 compatible`；`SHOW server_version` / `server_version_num` = `zhdb`；`current_setting('server_version')` = NULL |
| 错误码 | ❌ | engine 抛出的错误统一 fallback 到 **`42000`**（`pg.zig:1045`）：除零应 `22012`、表不存在应 `42P01`、重复键应 `23505`、NOT NULL 应 `23502` |

### L2 Introspect（catalog / 自省）

| 项 | 状态 | 实测证据 |
|---|---|---|
| `pg_class` / `pg_attribute` / `pg_type` / `pg_namespace` / `pg_index` / `pg_settings` / `pg_database` | ✅ | 均可查询并返回合理行 |
| `pg_proc` | ❌ | `relation "pg_proc" does not exist` |
| `information_schema.tables` / `.columns` | ❌ | `relation "tables" does not exist` |
| `pg_get_keywords()` | ❌ | `Unsupported`（DBeaver 连接时必查） |
| psql `\dt` / `\d` 查询 | ❌ | 用真实表 `foo` 跑 psql 18 的 `\dt` SQL → `TableNotFound`（`OPERATOR(pg_catalog.~)` / `COLLATE pg_catalog.default` 解析不过） |
| GUC | ❌ | `SHOW ALL` 只返回一行 `zhdb`；`SET work_mem='1MB'; SHOW work_mem` 仍返回 `zhdb` |

### L3 Query（SQL 表面）

| 项 | 状态 | 实测证据 |
|---|---|---|
| CTE / 窗口函数 / `RETURNING` / `ALTER TABLE ADD COLUMN` / `CREATE VIEW` / JSONB 取值 / ARRAY / INTERVAL / `now()` / `ILIKE` / SERIAL | ✅ | 探针全部返回正确结果；`ALTER ADD COLUMN` 后插入/查询真实生效 |
| `ON CONFLICT ... DO UPDATE` | ❌ | 冲突时仍报 `duplicate key`，未走 upsert |
| CHECK 约束 | ❌ | `CHECK(x>0)` 表插入 `-1` **成功并读出 `-1`**（静默失败） |
| `DISTINCT ON` | ❌ | 4 行输入返回 `[NULL]`（静默错误结果） |
| `WITH RECURSIVE` | ❌ | `syntax error at or near "t"` |
| `current_date` / `current_timestamp` | ❌ | `column ... does not exist` |
| `substring(x FROM a FOR b)` | ❌ | `syntax error at or near "FROM"` |
| `numeric(10,2)` 精度 | ⚠️ | `1.234::numeric(10,2)` 返回 `1.234`（未舍入） |
| `int4range` / `pg_get_serial_sequence` / `pg_advisory_lock` | ❌ | 均返回 NULL（静默 no-op） |

### L4 Behave（事务 / 行为）

| 项 | 状态 | 实测证据 |
|---|---|---|
| BEGIN/COMMIT/ROLLBACK、SAVEPOINT 回滚 | ✅ | SAVEPOINT 后回滚只保留第 1 行 |
| SQLSTATE 一致性 | ❌ | 见 L1；错误文本正确但 code 全错 |
| 隔离级别 | ❌ | `BEGIN ISOLATION LEVEL REPEATABLE READ; SHOW transaction_isolation` → `zhdb` |
| UNIQUE / NOT NULL 约束 | ⚠️ | 有执行，但 SQLSTATE 为 `42000` |
| `LOCK TABLE` / advisory lock | ⚠️ | 接受但无可见效果（tag 为 `SET` / 返回 NULL） |

### L5 Drop-in（运维）

| 项 | 状态 | 实测证据 |
|---|---|---|
| `COPY TO STDOUT` | ✅ | 原始消息序列 `H`(CopyOutResponse) → `d`(CopyData `1\t10\n`) → `c`(CopyDone) → `C`(`COPY 1`) → `Z` |
| `CREATE PUBLICATION` / `SUBSCRIPTION` | ❌ | 返回 `SET` tag，纯 no-op |
| schema dump / 逻辑复制 / 物理复制 / PITR | ❌ | 未实现 |

## 3. TODO（按优先级）

优先级依据 Riga 共识：**先消除静默失败与客户端硬阻断，再补元数据，最后补功能与运维**。
每项给出验收条件与估算（LOC / 二进制增量）。

### P0 — 消除静默失败与客户端阻断（必做，收益最高）

| # | 任务 | 验收标准 | 估算 |
|---|---|---|---|
| P0-1 | 版本字符串标准化：`version()` 返回 PG 风格、`SHOW server_version` / `server_version_num` / `current_setting('server_version')` 返回 PG 18 值 | 探针 L1 `version` 三项通过；psql 无版本警告 | 150 行 / +5 KB |
| P0-2 | 默认响应 SSLRequest（未启用 `--tls` 时回 `N`），不要把它当 startup 读 | SSL 探测在 1.5 s 内收到 `N` | 30 行 / +1 KB |
| P0-3 | Extended Query 的 Describe portal 返回 `T`(RowDescription) 而非 `n` | 探针 extended `seq` 含 `T` 且 cols=`['n']` | 80 行 / +2 KB |
| P0-4 | 结构化 SQLSTATE：在 engine 侧带 code 抛错，pg.zig:1045 不再一律 `42000` | 除零 `22012`、表不存在 `42P01`、重复键 `23505`、NOT NULL `23502`、CHECK `23514`、语法 `42601` | 500 行 / +20 KB |
| P0-5 | CHECK 约束真正执行 | `CHECK(x>0)` 插 `-1` 报 `23514` | 250 行 / +10 KB |
| P0-6 | `ON CONFLICT DO UPDATE` 实现 upsert | 冲突行被更新为 `excluded` 值 | 400 行 / +15 KB |
| P0-7 | 修复 `DISTINCT ON` 结果 | `SELECT DISTINCT ON (x) x ...` 返回去重后的值而非 NULL | 120 行 / +5 KB |
| P0-8 | 消除 no-op：`int4range`、`pg_get_serial_sequence`、`pg_advisory_lock` 等改为真实实现或明确报错 | 不再静默返回 NULL | 200 行 / +8 KB |
| P0-9 | `CREATE PUBLICATION` / `SUBSCRIPTION` 未实现时明确报 `0A000`，不要返回 `SET` | 探针 L5 两项为 ERR 而非 OK | 80 行 / +3 KB |

**P0 小计：约 1,810 行 / +69 KB**

### P1 — 元数据与认证（让标准工具连得上）

| # | 任务 | 验收标准 | 估算 |
|---|---|---|---|
| P1-1 | `pg_proc`  catalog 视图（基于现有函数注册表生成） | `SELECT proname FROM pg_proc LIMIT 5` 有行 | 400 行 / +20 KB |
| P1-2 | `information_schema` 核心视图（`tables` / `columns` / `schemata`） | JDBC `DatabaseMetaData` 风格查询可跑 | 600 行 / +30 KB |
| P1-3 | `pg_get_keywords()` | DBeaver 连接查询通过 | 120 行 / +5 KB |
| P1-4 | psql `\d` / `\dt` 查询兼容（`OPERATOR(pg_catalog.~)`、`COLLATE pg_catalog.default`） | 用真实表跑 psql 18 的 `\dt` SQL 返回正确行 | 300 行 / +12 KB |
| P1-5 | GUC 系统：`SHOW ALL` / `SET` / `RESET` / `current_setting()` 真正生效 | `SHOW work_mem` 返回 `1MB`，`SHOW ALL` 多行 | 700 行 / +25 KB |
| P1-6 | SCRAM-SHA-256 认证（复用现有 tls 依赖；密码学部分利用 std crypto） | 以 SCRAM 用户可连接 | 500 行 / +25 KB |

**P1 小计：约 2,620 行 / +117 KB**

### P2 — SQL 语义补齐

| # | 任务 | 估算 |
|---|---|---|
| P2-1 | `WITH RECURSIVE` 递归执行 | 500 行 / +20 KB |
| P2-2 | `current_date` / `current_time` / `current_timestamp` 系列 | 150 行 / +5 KB |
| P2-3 | `substring(x FROM a FOR b)` / `trim(BOTH ...)` / `position()` 语法形式 | 300 行 / +12 KB |
| P2-4 | `numeric(p,s)` 精度/舍入（当前按文本/float 近似） | 500 行 / +20 KB |
| P2-5 | 内置函数第二批（按 `pg_proc` 高频子集，约 100 个） | 2,000 行 / +80 KB |
| P2-6 | range/array/JSON 操作符增强（`||`、`->>`、数组下标等） | 800 行 / +35 KB |

**P2 小计：约 4,250 行 / +172 KB**

### P3 — 运维与复制

| # | 任务 | 估算 |
|---|---|---|
| P3-1 | schema dump（与 `pg_dump` 兼容的 DDL 导出；COPY 数据路径已就绪） | 800 行 / +30 KB |
| P3-2 | 逻辑复制（publication/subscription + WAL 解码） | 3,000 行 / +120 KB |
| P3-3 | 物理复制 / PITR / WAL 访问（现有 `wal.zig` 仅 56 行，需大幅扩展） | 2,000 行 / +80 KB |

**P3 小计：约 5,800 行 / +230 KB**

## 4. 代码量与二进制膨胀汇总

估算依据：当前 47,153 行 → 4.79 MB，约 9.8 KB/千行（含已链接库）。
新增业务代码的边际成本按 Zig `ReleaseFast` 经验取 **8–15 KB/千行**；字符串表、SQLSTATE 表、
catalog 元数据会降低单价（取偏保守值）。以上依赖均为静态链接，无新增动态库。

| 阶段 | 新增 LOC | 二进制增量 | 累计二进制 | strip 后累计 | 相对当前 |
|---|---:|---:|---:|---:|---:|
| 当前基线 | 0 | 0 | 4.79 MB | 4.43 MB | — |
| P0 完成 | ~1,810 | +69 KB | 4.86 MB | 4.50 MB | +1.4% |
| P1 完成 | ~2,620 | +117 KB | 4.98 MB | 4.61 MB | +3.9% |
| P2 完成 | ~4,250 | +172 KB | 5.15 MB | 4.78 MB | +7.5% |
| P3 完成 | ~5,800 | +230 KB | 5.38 MB | 5.00 MB | +12.3% |
| **合计** | **~14,480** | **+588 KB** | **5.38 MB** | **5.00 MB** | **+12.3%** |

> 说明：若只做到 P0+P1（约 +4,430 行 / +186 KB），二进制约 4.98 MB（+4%）
> 即可获得"客户端能连、工具能用、错误码正确、无静默失败"的可用性质变，性价比最高。
> P3 的二进制估算浮动最大（±50%），取决于是否复用现有 storage/WAL 抽象。

## 5. 建议里程碑与验收

| 里程碑 | 范围 | 验收方式 |
|---|---|---|
| M1 | P0 全部 | `tests/pg_gap_probe.py` 重跑：所有 ERR 的 SQLSTATE 符合 PG，静默失败项归零；pg18 schedule 保持 96/96 |
| M2 | P1 全部 | psql/pgjdbc/psycopg 免改连接；`\dt` 与 `information_schema` 查询通过；SCRAM 用户可连 |
| M3 | P2 全部 | 按 Riga「Core SQL」逐项核对；扩展 pg18 schedule 至更多官方文件 |
| M4 | P3 全部 | `pg_dump` 往返、双向逻辑复制、PITR 演练通过 |

持续回归：每个里程碑后 `zig build test`、`test/run.sh`、`test/pg18/run.sh` 必须全绿。

## 6. 参考框架

- PostgreSQL Wiki — Riga Consensus（PGConf.EU 2025）：Core/Optional 加权清单、无静默失败、SQLSTATE/catalog/版本字符串要求
- `vyruss/postgres-compat` — Riga 框架参考实现（`pg_regress` 200 文件 + `pg_isolation_regress` 117 spec + 74 YAML probe）
- PostgreSQL Compatibility Index / PGScorecard — 12 类特性打分，PG17 基线
- `tamnd/rupg-compat` — L1 Connect / L2 Introspect / L3 Query / L4 Behave / L5 Drop-in 五层量化分母
- CedarDB — SQL grammar / wire protocol / inspection tables / low-level APIs 四分类
- Yugabyte / dbta — wire / syntax / feature / runtime 四层模型
