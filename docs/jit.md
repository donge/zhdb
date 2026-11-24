# pgrust 的 JIT 思路与 Zig 可行性验证

参考：https://github.com/malisper/pgrust 、
[《JIT Compiling Code in 5μs》](https://malisper.me/how-ai-changes-the-economics-of-jit-compilers/)

## pgrust 做了什么

- Postgres 的 Rust 重写，查询引擎叫 **Gravity**：vectorized、push-based、**每条 SQL 都 JIT**。
- JIT 不走 LLVM，也不生成 C，而是 **copy-and-patch**：
  1. 把常用操作写成若干条 ARM64 机器码模板（stencil），例如字符比较、循环回跳、栈回退；
  2. 编译时按 AST 拼接 stencil，并把常量、跳转偏移、地址**直接写进指令字**；
  3. 把生成的 `u32` 指令序列拷进可执行内存，按函数指针调用。
- 编译耗时约 **5μs/查询**，所以不需要“只 JIT 热点查询”的策略，可以每条都编译。
- 收益来源：**计划级特化**（常量内联、去掉解释器 dispatch、按算子组合生成专用循环），
  而不是“手写汇编一定比编译器快”。

## Zig 能否实现

可以，而且不需要任何外部依赖。`src/jit.zig` 就是一个可直接运行的原型：

```zig
try c.emit(movz(2, 0));          // acc = 0
const loop = c.here();
try c.emit(ldrX(3, 0, 0));       // x3 = *ptr
try c.emit(addReg(2, 2, 3));     // acc += x3
try c.emit(addImm(0, 0, 8));     // ptr += 8
try c.emit(subsImm(1, 1, 1));    // n -= 1
try c.emit(bCond(1, loop, ...)); // b.ne loop
```

- 指令编码：`movz / add / subs / ldr / cbz / cbnz / b.cond / b / ret`，约 100 行。
- 可执行内存：`std.posix.mmap(RW)` → 写入 → `mprotect(RX)` → `@ptrCast` 成函数指针。
  macOS ARM64 实测可用（无需 MAP_JIT，因为 CLI 没有 hardened runtime）。
- 已实现三个内核：`sum(i64[])`、`sum(filter!=0)`、`sum(col + k)`。
- 每条内核编译耗时 **约 12μs**（pgrust 约 5μs，同一量级）。

```bash
./zig-out/bin/zhdb jitbench --load=../bench/hits_1m17_schema.tsv
```

## 实测（Apple M4，1M 行）

`SUM(ResolutionWidth)` over 1M i64（外部 wall-clock，3000–10000 次取平均）：

| 实现 | ms/次 | 说明 |
|---|---|---|
| Zig 循环（LLVM） | 0.095 | 标量 4 路展开 + `ldp`，LLVM 没有向量化 |
| JIT 标量（4 acc / 8 elem） | 0.254 | 每元素一次 load+add+分支 |
| JIT NEON8（4× `v.2d` / 8 elem） | 0.125 | 有向量化，但 `ldr q` 串在 x0 写回链上 |
| **JIT NEON16（8× `v.2d` / 16 elem）** | **0.074** | **比 Zig 循环快约 1.3×** |

结论修正：之前“JIT 更慢”是**只做了 8 元素/4 累加器的 NEON**。改成
16 元素/8 累加器、用 4 条 `ldp q`（一条指令载入 2 个 128-bit）后，
JIT 反超 LLVM 约 28%。差距来源是：累加器数量（隐藏 add 延迟）、
每条分支覆盖 16 个元素、`ldp` 把访存指令数减半并去掉逐条 post-index 的地址依赖链。

JIT 编译耗时约 10 μs/内核。

结论：**“手写汇编”本身不会打败 LLVM**。同样的循环，Zig 生成的代码已经自动向量化，
标量 ARM64 手写码更慢。pgrust 的 3× ClickHouse 来自：

1. 把常量、谓词、投影、聚合**融合进一个循环**，消除解释器与算子间的数据搬运；
2. 每条查询重新生成代码，按实际列类型/空值属性特化；
3. 生成的循环可以针对谓词分支做布局优化。

## 在 zhdb 里已经吃到的“特化”收益

不写 JIT 也能拿到大部分收益——把特化提前到计划期：

- 列式存储 + 列下标绑定，消除运行时 dispatch；
- `SUM(col + k)` 家族**共享一次基础累加**，`k` 在收尾时用 `k * count` 算出：
  Q28（90 个 SUM）**42 ms → 1.0 ms**，已经快于 DuckDB 的 2.1 ms。

## 下一步（如果要继续做真 JIT）

1. 生成 `filter + project + aggregate` 融合内核（目前列式路径已是单趟，但仍是 C 风格的函数调用）；
2. 用 NEON `add v.2d` 一次处理 2 个 i64，配合 4 路展开；
3. 每查询编译一次（12μs 可接受），把 WHERE 常量和投影列号直接内联进指令；
4. 只对 `SUM/COUNT/MIN/MAX + 简单谓词` 用 JIT，其余回退列式解释路径。

## 参考接口

```zig
var exe = try jit.compileSumI64(gpa);
defer exe.deinit();
const f = exe.as(*const fn ([*]const i64, usize) callconv(.c) i64);
const total = f(vals.ptr, vals.len);
```


## 接入查询执行（JIT 预计算 SUM）

`src/columnar.zig` 的标量聚合现在会尝试 JIT：

1. 查询是**全表扫描**（无 `WHERE`），聚合是 `SUM/AVG(col)`；
2. 抽样检查 `max|col| * n` 不会溢出 i64（`UserID`/`WatchID` 自动跳过）；
3. 用 `compileSumI64Vec16` 一次算出基础和，`SUM(col + k)` 再用 `k * count` 推导；
4. 其余聚合仍走并行累加器。可用 `ZHDB_NO_JIT=1` 关闭对比。

外部计时（1M 行，2000 次重复）：

| 查询 | 关闭 JIT | 开启 JIT | 加速 |
|---|---|---|---|
| Q3 `SUM/COUNT/AVG` | 1.96 ms | 1.27 ms | 1.54× |
| Q28 `SUM(col)`/`SUM(col+1)` | 0.96 ms | 0.61 ms | 1.59× |
| 31 条 ClickBench 全集 | 522.8 ms | 501.5 ms | 1.04× |

全集只有 4% 提升——这是 Amdahl：剩余时间主要在分组哈希（Q31 126 ms）、
LIKE 字符串扫描（Q20–23）和点查扫描，JIT 求和只覆盖其中很小一块。
