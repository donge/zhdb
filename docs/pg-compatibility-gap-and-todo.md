# zhdb PostgreSQL 兼容性差距评估与 TODO（2026-11-27 实测）

> 结论先行：当前最大的差距**不是"功能少"**，而是 **静默失败、SQLSTATE 错误、客户端协议元数据不匹配**。
> 96/96 的 pg18 回归通过证明的是 SQL 语义覆盖，但**不等于协议/客户端兼容**：该 harness 是手写
> `psql.py`，会剥离 NOTICE、正则改写错误信息，且不走真实 psql 的 `\d`/协议路径。
> 真正的硬阻断是：所有 `RowDescription` 列 OID 都是 25(text)、portal `Describe` 返回 `NoData`、
> 仍有 Flush/portal Describe/RowDescription OID/统一 `42000` 等差距；CancelRequest 与 SCRAM 已补齐。
> 全量 P0–P3 约 **16,400 行 / +663 KB**，二进制 4.79 MB → 5.45 MB（+14%）；仅做 P0 约
> **3,260 行 / +124 KB**（+2.6%）即可消除静默失败和主要客户端阻断，性价比最高。

## 1. 测量方法与环境

| 项 | 值 |
|---|---|
| Zig | 0.17.0 |
| 构建 | `zig build --release=fast` |
| 二进制 | **4,790,824 B（4.79 MB）**；`strip` 后 4,434,400 B（4.43 MB） |
| 动态链接 | libSystem / libiconv / libicucore；`tls`/`regex`/`lz4`/`btree` 为静态 Zig 依赖，已在二进制内 |
| 源码规模 | **47,153 行 Zig**（`engine.zig` 35,666；`sql.zig` 5,174；`main.zig` 1,685；`columnar.zig` 1,302；`pg.zig` 1,256；`storage.zig` 1,177；`jit.zig` 606；其余 343） |
| 单元测试 | `zig build test` 通过（**22 个**测试；README 写的 25 已过时） |
| 官方回归 | `./test/pg18/run.sh` → **100 通过 / 0 失败** |
| 协议探针 | `tests/pg_gap_probe.py`（纯 socket，不依赖 psycopg/psql），连 `zhdb serve` 跑 50+ 项探测 |
| 代码盘点 | 逐文件核对 `src/*.zig` 的状态与代码位置，见本文各层的"代码位置"列 |

> `test/known_unsupported.md` 严重滞后：CTE、RETURNING、窗口函数、SAVEPOINT 均已实现（SAVEPOINT
> 有真实的快照/恢复逻辑，`src/engine.zig:16598-16664`），文档仍写"不支持"。本报告以实测+代码为准。

### 96/96 的含金量（重要）

`test/pg18/run.sh` 不是 `pg_regress` + 真实 psql，而是仓库内手写的 `test/pg18/psql.py`（≈1,065 行）：

- 从 expected 中**剥离所有 `NOTICE:` 行**；
- 用正则**改写错误信息与 caret 位置**（`psql.py:936-1065`）；
- `test_setup` 靠 `check_setup.sql` 校验行数，防止纯 echo；
- 不跑真实 psql 的 `\d` / `\dt` / 协议路径（这些由另一个简化 harness `tests/psql_dt.sql` 覆盖）。

因此 96/96 说明 SQL 语义（类型 I/O、DDL/DML、catalog 子集、事务、索引、引用）覆盖良好，
但**不能作为协议兼容或 drop-in 的证据**——真实 JDBC/psycopg/asyncpg 至今未接入 CI。

## 2. 分层差距（实测 + 代码证据）

标记：✅ 可用 ｜ ⚠️ 部分/有副作用 ｜ ❌ 缺失或静默失败

### L1 Connect（协议）

| 项 | 状态 | 证据 / 代码位置 |
|---|---|---|
| Startup + AuthOk(trust) / md5 | ✅ | `pg.zig:262-287`；md5 见 `:194-211`；`--password=` 见 `main.zig:61` |
| SSLRequest / GSSENC 协商 | ✅ | `pg.zig:240-253`：80877103/80877104 → `S`+TLS 或 `N`；`tests/pg_protocol_test.py:71-73` 断言 `N` |
| TLS 1.3 | ✅（需 `--tls`） | `pg.zig:240-249`，实现在 `deps/zhdb-support/src/tls.zig`（479 行） |
| Simple Query `Q` / 多语句 | ✅ | `pg.zig:318-325`、`sql.splitStatements` `:843` |
| COPY OUT | ✅ | `pg.zig:1088-1110`；探针捕获 `H → d → c → C → Z` |
| CancelRequest(80877102) | ✅ | `pg.zig` startup 处理 80877102，按 pid/key 设置目标会话取消标志；`tests/pg_protocol_probe.py` 覆盖正确/错误 key |
| BackendKeyData | ✅ | 每会话随机 secret + 递增 pid，与 CancelRequest 注册表匹配；探针校验 |
| RowDescription 类型 OID | ❌ | `pg.zig:1138-1158` **所有列 OID 恒为 25(text)**，typlen/typmod 固定 -1，无表 OID/attnum。探针 30+ 查询无一例外 |
| portal `Describe` | ❌ | `pg.zig:369-377`：`kind=='P'` 恒发 `MSG_NO_DATA`(`n`)；`describeQuery` `:1231-1256` 直接执行 SELECT 只发 RowDescription，无 `ParameterDescription('t')` |
| Extended Query `P`/`B`/`E` | ⚠️ | `pg.zig:326-385`：参数类型被丢弃、只支持文本格式、用 `$n` 文本替换（`:444-487`）后再走 simple query |
| `F`(Flush) / `C`(Close) | ❌ / ⚠️ | 无 `F` 分支（`:396` `else => {}`）；`C` 无条件发空 CloseComplete，无状态跟踪 |
| EmptyQueryResponse `I` | ❌ | `sql.zig:5166-5172` 跳过空语句 → 只发 `Z`，不发 `I` |
| ReadyForQuery 事务状态 | ❌ | 恒为 `I`（`:387,425,719,735,783,834`），显式事务中不发 `T`，失败后不发 `E` |
| ErrorResponse 字段 | ⚠️ | `pg.zig:1208-1226` 只有 `S/V/C/M`+(可选 `P`)，无 `D/H/F/L/R`；HINT 被塞进 `M` 并拼字面 `\nHINT:` |
| SQLSTATE | ❌ | `pg.zig:1045`：所有 engine 错误一律 `42000`；正确值应为除零 `22012`、表不存在 `42P01`、重复键 `23505`、NOT NULL `23502`、CHECK `23514` |
| DataRow 格式 | ⚠️ | `pg.zig:1160-1176` 仅文本；bool 渲染 `t`/`f`，无二进制结果格式 |
| CommandComplete tag | ⚠️ | `SELECT n`/`INSERT 0 n` 正确；fallback `else => "SET"`（`:1129`）使 LOCK、SHOW、CREATE PUBLICATION 都报 `SET` |
| SCRAM-SHA-256 | ✅（`--scram-sha-256`） | `src/pg.zig` 实现 SASL 握手、PBKDF2/HMAC 校验与 server-final；`tests/pg_protocol_probe.py` 通过 |
| Notification (`A`) | ❌ | LISTEN/UNLISTEN 是 shim（`pg.zig:436-437,922-924`），`pg_notify` 只校验返回 `""`（`engine.zig:34982-34987`） |

### L2 Introspect（catalog / 自省）

| 项 | 状态 | 证据 / 代码位置 |
|---|---|---|
| 35 个 `pg_*` catalog | ⚠️ | `engine.zig:11747-11784` 注册 35 个关系；列集精简，如 `pg_class` 13 列、`pg_type` 仅 `oid/typname/typrelid/typowner`（`:11651-11654`） |
| `pg_proc` | ❌ | `src/*.zig` 中零出现；探针 → `relation "pg_proc" does not exist` |
| `information_schema` | ❌ | 源码中仅作为 ACL 排除项出现（`engine.zig:16251`），无视图实现 |
| `pg_get_keywords()` | ❌ | 无实现；parser 有内部 `findKeyword*`（`sql.zig:898-920`）但未导出为 SQL 函数 |
| psql `\dt` / `\d` | ❌ | 真实 psql 18 的 `\dt` 用 `OPERATOR(pg_catalog.~)` / `COLLATE pg_catalog.default`，`src/sql.zig` 无 `OPERATOR(` 语法 → 解析失败（探针 `TableNotFound`） |
| GUC (`SHOW`/`SET`/`current_setting`) | ❌ | `SHOW` 除 `search_path` 外一律返回 `"zhdb"`（`pg.zig:926-935`）；`SET work_mem` 存入 `engine.settings`（`engine.zig:5281-5286`）但 `SHOW` 不读；`current_setting('server_version')` → NULL |
| 版本一致性 | ❌ | ParameterStatus 报 `server_version="18.1"`（`pg.zig:406`）、`version()` 报 `"Zhdb 0.1 ... PostgreSQL 18.1 compatible"`（`engine.zig:35300`），但 `SHOW` 报 `"zhdb"`，三处不一致 |

### L3 Query（SQL 表面）

| 项 | 状态 | 证据 / 代码位置 |
|---|---|---|
| CREATE/DROP TABLE, INDEX, VIEW, SCHEMA, SEQUENCE, ALTER TABLE | ✅ | `sql.zig:450+`；`ALTER TABLE ADD COLUMN` 真重建表（`engine.zig:15218-15272`） |
| SELECT/INSERT/UPDATE/DELETE + `RETURNING`、`INSERT…SELECT` | ✅ | `sql.zig:474-476`、`engine.zig:11618,5247-5251` |
| JOIN / WHERE / GROUP BY / HAVING / ORDER BY / LIMIT / OFFSET / 集合操作 | ✅ | `sql.zig:374-398`；pg18 `select_having`/`select_implicit` 通过 |
| CTE (`WITH`) | ⚠️ | `sql.zig:474,2598` + `engine.zig:5361`；**`WITH RECURSIVE` 不支持** |
| 窗口函数 | ⚠️ | `engine.zig:9380-9389` 仅 `row_number`/`lag`；其他落到 `.null`（`:27907`） |
| 约束 PK / UNIQUE / NOT NULL | ⚠️ | 有执行（`engine.zig:3852-3867,11216-11221`），但 SQLSTATE 为 `42000` |
| `CHECK` / `FOREIGN KEY` | ❌ | `sql.zig:2414-2415` 解析后直接丢弃；`CHECK(x>0)` 插 `-1` 成功并读出 `-1` |
| `ON CONFLICT DO UPDATE` | ❌ | `src/sql.zig` 无 conflict 语法；探针报 duplicate key |
| 数据类型 | ⚠️ | `ColType = enum{int,float,text,boolean,date,timestamp}`（`engine.zig:9`）；`numeric/decimal→float`、`bytea/uuid/jsonb/interval/time→text`（`:10-27`）；`Value` 仅 6 个变体（`value.zig:2-9`） |
| CAST | ⚠️ | `sql.zig:604`；`numeric(10,2)` 不舍入；`CAST(float AS int)` 截断（PG 为四舍五入） |
| 内置函数/操作符 | ⚠️ | `engine.zig` 中约 **126 个**不同函数名（含内部名）；PG 18 有数千个 |
| 引号标识符 / NULL 三值逻辑 | ✅ | pg18 `create_schema`/`regproc`/`psql_crosstab` 通过 |
| `DISTINCT ON` / `current_date` / `substring(x FROM…)` / `ILIKE` / `DATE '…'` | ❌ | 探针逐项失败；`sql.zig` 中无对应字段/关键字 |

### L4 Behave（事务 / 行为）

| 项 | 状态 | 证据 / 代码位置 |
|---|---|---|
| BEGIN / COMMIT / ROLLBACK | ✅ | `pg.zig:851-920`、`engine.zig:4623-4706`，COMMIT 写 WAL（`:4674-4678`） |
| SAVEPOINT / RELEASE / ROLLBACK TO | ⚠️ | 已实现真实快照恢复（`engine.zig:16598-16664`），但未知名字 `const at = idx orelse return;`（`:16627,16660`）静默成功 |
| 隔离级别 | ❌ | `src/sql.zig` 无 isolation 关键字；`BEGIN ISOLATION LEVEL …` 被 `pg.zig:851` 前缀匹配后整个忽略；`SHOW transaction_isolation` → `"zhdb"` |
| 行锁 `FOR UPDATE/SHARE` | ⚠️ | 解析了（`sql.zig:4402-4403`），执行仅消费命令（`engine.zig:25422-25423`） |
| 表级死锁检测 | ✅ | `lockmgr.zig:wouldDeadlock`（最多 64 跳）；`pg.zig:971-977` 映射 `40P01`/`55P03` |
| 错误后事务置 aborted | ⚠️ | engine 错误会置 `conn.aborted_txn`（`pg.zig:1026-1027`），但语法/数值错误在 `:940-954` 提前返回，未标记 → 事务仍可 COMMIT |
| WAL flush 失败 | ❌ | `pg.zig:867` `commitTxn(io) catch {}` 吞掉错误 |
| PG 硬限制（63 字节标识符、1600 列） | ⚠️ | 仅 channel 名 63 检查（`engine.zig:34986`）；`TooManyColumns` 存在于错误集但无系统执行 |

### L5 Drop-in（运维）

| 项 | 状态 | 证据 / 代码位置 |
|---|---|---|
| COPY IN / OUT（文本） | ✅ | `pg.zig:704-836`（IN）、`:1088-1110`（OUT）；无二进制格式 |
| `pg_dump` / `pg_restore` | ❌ | 无代码/测试；只有自定义 `.zdb` 快照（`storage.zig`） |
| 逻辑复制 | ❌（静默） | `engine.zig:14318-14328` 把 CREATE PUBLICATION/SUBSCRIPTION 仅登记为 DDL 对象 → 返回成功 + `SET` tag |
| 物理复制 / standby / Patroni / repmgr | ❌ | 单进程；无 `IDENTIFY_SYSTEM` / `TIMELINE_HISTORY` / `CREATE_REPLICATION_SLOT` |
| WAL / PITR | ⚠️ | `wal.zig` 仅 56 行：长度前缀的 SQL 语句 + commit 标记（`appendStmt`/`appendCommit`/`committed`），回放见 `main.zig:84-87`；无 PG WAL 记录、LSN、base backup |
| 真实客户端驱动 | ❌ | 仓库仅 `pg_protocol_test.py`(6 项, simple Q)、`pg_catalog_test.py`(54 项)；JDBC/psycopg/asyncpg/node-postgres/SQLAlchemy/Hibernate 均未接入；仍受 OID 25、`NoData`、catalog 覆盖限制（SCRAM 已支持） |

## 3. TODO（按优先级）

优先级依据 Riga 共识：**先消除静默失败与客户端硬阻断，再补元数据，最后补功能与运维**。

### P0 — 静默失败 + SQLSTATE + 客户端硬阻断（必做）

| # | 任务 | 验收标准 | 估算 |
|---|---|---|---|
| P0-1 | 版本字符串统一：`version()` / `SHOW server_version` / `server_version_num` / `current_setting()` 一致报 PG 18 值 | 三处一致、psql 无警告 | 150 行 / +5 KB |
| P0-2 | portal `Describe` 返回 `T`(RowDescription) 与 `t`(ParameterDescription) | 探针 extended `seq` 含 `T`/`t` | 80 行 / +2 KB |
| P0-3 | **RowDescription 真实类型 OID 映射**（int4=23、bool=16、text=25、float8=701、timestamp=1114、jsonb=3802…），带 typlen/typmod/表 OID/attnum | 探针所有查询 OID 不再恒为 25 | 500 行 / +20 KB |
| P0-4 | CancelRequest + 真实 BackendKeyData | ✅ 已完成（取消标志在下一语句生效） | — |
| P0-5 | `F`(Flush) 分支、`C`(Close) 状态跟踪 | 命名 statement/portal 可复用与关闭 | 200 行 / +8 KB |
| P0-6 | 空查询发 `I`；`ReadyForQuery` 发 `T`/`E` 事务状态 | 探针 empty_query 收到 `I`，事务中收到 `T` | 180 行 / +6 KB |
| P0-7 | ErrorResponse 补全 `D`(detail)/`H`(hint)/`F`/`L`/`R` 字段 | 结构化字段可被客户端解析 | 150 行 / +5 KB |
| P0-8 | **结构化 SQLSTATE**（engine 带 code 抛错，`pg.zig:1045` 不再一律 `42000`） | 22012/42P01/23505/23502/23514/42601 逐一正确 | 500 行 / +20 KB |
| P0-9 | CHECK / FOREIGN KEY 真正执行（不再 `sql.zig:2414-2415` 丢弃） | `CHECK(x>0)` 插 `-1` 报 `23514` | 250 行 / +10 KB |
| P0-10 | `ON CONFLICT DO UPDATE` upsert | 冲突行更新为 `excluded` 值 | 400 行 / +15 KB |
| P0-11 | 修复 `DISTINCT ON`（当前返回 NULL） | 去重结果正确 | 120 行 / +5 KB |
| P0-12 | 未知函数/no-op 处理：`int4range`、`pg_get_serial_sequence`、`pg_advisory_lock` 真实实现或明确报错 `0A000` | 不再静默返回 NULL | 200 行 / +8 KB |
| P0-13 | CREATE PUBLICATION/SUBSCRIPTION 未实现时明确报错 | 探针 L5 为 ERR 而非 `SET` | 80 行 / +3 KB |
| P0-14 | 语法/数值错误也置 `aborted_txn`；未知 SAVEPOINT 名报错 | 错误后事务只能 ROLLBACK | 150 行 / +5 KB |
| P0-15 | WAL flush 失败不再 `catch {}` 吞掉 | COMMIT 返回 IO 错误 | 50 行 / +2 KB |

**P0 小计：约 3,260 行 / +124 KB**

### P1 — 元数据与认证（让标准工具连得上）

| # | 任务 | 估算 |
|---|---|---|
| P1-1 | `pg_proc` catalog 视图（基于现有函数注册表） | 400 行 / +20 KB |
| P1-2 | `information_schema` 核心视图（tables/columns/schemata） | 600 行 / +30 KB |
| P1-3 | `pg_get_keywords()` | 120 行 / +5 KB |
| P1-4 | psql `\d`/`\dt` 兼容：`OPERATOR(pg_catalog.~)`、`COLLATE pg_catalog.default` 语法 | 300 行 / +12 KB |
| P1-5 | GUC 系统：`SHOW ALL` / `SET` / `RESET` / `current_setting()` 真读真写 | 700 行 / +25 KB |
| P1-6 | SCRAM-SHA-256 | ✅ 已完成（`--scram-sha-256`，std.crypto + PBKDF2） | — |

**P1 小计：约 2,620 行 / +117 KB**

### P2 — SQL 语义补齐

| # | 任务 | 估算 |
|---|---|---|
| P2-1 | `WITH RECURSIVE` | 500 行 / +20 KB |
| P2-2 | `current_date`/`current_time`/`current_timestamp` | 150 行 / +5 KB |
| P2-3 | `substring(x FROM a FOR b)` / `trim(BOTH …)` / `position()` | 300 行 / +12 KB |
| P2-4 | `numeric(p,s)` 精度/舍入 | 500 行 / +20 KB |
| P2-5 | **窗口函数补全**：`rank`/`dense_rank`/`sum`/`PARTITION BY`/frame（现仅 row_number/lag） | 500 行 / +20 KB |
| P2-6 | 内置函数第二批（约 126 → 500 个高频） | 2,000 行 / +80 KB |
| P2-7 | range/array/JSON 操作符（`||`、`->>`、数组下标） | 800 行 / +35 KB |

**P2 小计：约 4,750 行 / +192 KB**

### P3 — 运维与复制

| # | 任务 | 估算 |
|---|---|---|
| P3-1 | schema dump（与 `pg_dump` 兼容；COPY 数据路径已就绪） | 800 行 / +30 KB |
| P3-2 | 逻辑复制（publication/subscription + WAL 解码） | 3,000 行 / +120 KB |
| P3-3 | 物理复制/PITR/LSN/base backup（`wal.zig` 从 56 行大幅扩展） | 2,000 行 / +80 KB |

**P3 小计：约 5,800 行 / +230 KB**

## 4. 代码量与二进制膨胀汇总

估算依据：当前 47,153 行 → 4.79 MB（约 9.8 KB/千行）。新增业务代码按 Zig `ReleaseFast`
经验取 **8–15 KB/千行**；字符串表、类型 OID 表、SQLSTATE 表会降低单价，故取偏保守值。
所有依赖为静态链接，不新增动态库。

| 阶段 | 新增 LOC | 二进制增量 | 累计二进制 | strip 后 | 相对当前 |
|---|---:|---:|---:|---:|---:|
| 当前基线 | 0 | 0 | 4.79 MB | 4.43 MB | — |
| P0 完成 | ~3,260 | +124 KB | 4.92 MB | 4.55 MB | +2.6% |
| P1 完成 | ~2,620 | +117 KB | 5.03 MB | 4.66 MB | +5.0% |
| P2 完成 | ~4,750 | +192 KB | 5.22 MB | 4.85 MB | +9.0% |
| P3 完成 | ~5,800 | +230 KB | 5.45 MB | 5.09 MB | +13.8% |
| **合计** | **~16,430** | **+663 KB** | **5.45 MB** | **5.09 MB** | **+13.8%** |

> P0+P1 合计约 +5,880 行 / +241 KB（二进制 +5%）即可拿到"客户端能连、工具能用、
> 错误码正确、无静默失败"的质变。P3 浮动最大（±50%），取决于是否复用现有 storage/WAL 抽象。

## 5. 建议里程碑与验收

| 里程碑 | 范围 | 验收方式 |
|---|---|---|
| M1 | P0 全部 | `tests/pg_gap_probe.py` 重跑：SQLSTATE 全对、OID 非 25、extended 有 `T`/`t`、静默失败归零；pg18 schedule 保持 96/96 |
| M2 | P1 全部 | 真实 psql `\dt`、JDBC DatabaseMetaData、psycopg 连接通过；SCRAM 可连 |
| M3 | P2 全部 | 按 Riga「Core SQL」核对；pg18 schedule 扩到更多官方文件 |
| M4 | P3 全部 | `pg_dump` 往返、双向逻辑复制、PITR 演练通过 |

持续回归：每个里程碑后 `zig build test`、`test/run.sh`、`test/pg18/run.sh` 必须全绿。

## 6. 参考框架

- PostgreSQL Wiki — Riga Consensus（PGConf.EU 2025）：Core/Optional 加权清单、无静默失败、SQLSTATE/catalog/版本字符串要求
- `vyruss/postgres-compat` — Riga 参考实现（`pg_regress` 200 文件 + `pg_isolation_regress` 117 spec + 74 YAML probe）
- PostgreSQL Compatibility Index / PGScorecard — 12 类特性打分，PG17 基线
- `tamnd/rupg-compat` — L1 Connect / L2 Introspect / L3 Query / L4 Behave / L5 Drop-in 五层量化分母
- CedarDB — SQL grammar / wire protocol / inspection tables / low-level APIs 四分类
- Yugabyte / dbta — wire / syntax / feature / runtime 四层模型
