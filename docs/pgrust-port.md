# 参考 pgrust 实现分组 JIT（AGPL-3.0）

zhdb 与 pgrust 同为 AGPL-3.0（见 `LICENSE` / `NOTICE`），因此可以**参考其实现**。
但两边运行时不同（Rust/PostgreSQL ABI vs Zig 列存），我们只复用**算法结构与机器码形态**，
重新生成属于 zhdb ABI 的代码；没有拷贝 pgrust 源码。

## 从 pgrust 借鉴了什么

| pgrust（`crates/gravity/...`） | zhdb（`src/jit.zig`） |
|---|---|
| `kernels/src/table/fold_jit.rs`：`FoldCall` 用 `offset_of!` 固定字段偏移，编译期把偏移写进指令 | `GroupCall` 风格：keys/slots/mask/firsts/counts 通过寄存器约定传入，kernel 内地址 stride 固定 |
| 分组折叠循环：hash → probe → compare → accumulate，慢路径外提 | 相同的直线循环；表满/扩容留待调用方（预分配 2×n 槽） |
| `SETS/WAYS` 缓存已编译代码，按 layout 复用 | 每次查询编译（~10μs），后续可加缓存 |
| 用 LLVM 汇编（如 `par_hashagg.s`）做 oracle 对拍 | 用 Zig 参考实现 + DuckDB 结果对拍 |

## 我们生成的 kernel

ABI（单 i64 key + `COUNT(*)`）：

```zig
fn (keys: [*]const i64,       // x0
    n: usize,                 // x1
    slots: [*]u32,            // x2  预置 0，容量 2n（2 的幂）
    mask: u64,                // x3
    firsts: [*]u32,           // x4  每个组的首行号
    counts: [*]i64,           // x5
    ng_out: [*]u64)           // x6
    callconv(.c) u64
```

核心循环（约 39 条指令）：

```text
loop:
  key = *keys++;  h = key * 0x9E3779B97F4A7C15
  h ^= h >> 29;   idx = h & mask
probe:
  slot = slots[idx]; if slot == 0 -> new
  g = slot - 1
  if keys[firsts[g]] == key -> counts[g]++
  else idx = (idx + 1) & mask; goto probe
new:
  firsts[ng] = i; counts[ng] = 1; slots[idx] = ng + 1; ng++
```

- 无扩容、无锁，`slots` 由调用方预分配并清零；
- 分支偏移与常量在生成时回填，运行期没有函数调用；
- 编码全部用 `as -arch arm64` + `otool` 校验过（`ldr w13,[x2,x11,lsl#2]` 等）。

## 接入与效果

`src/columnar.zig` 在「单 int 分组列 + 只有 `COUNT(*)`」且全表扫描时走该 kernel：

- Q16 `SELECT UserID, COUNT(*) FROM hits GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 5`
  - 关闭 JIT：14.46 ms
  - 开启 JIT：**8.53 ms**（1.7×）
  - kernel 本身约 1.8 ms；剩余是 83k 组的收尾/排序/投影
- 31 条 ClickBench 全集：430.6 ms → 417.3 ms（约 3.2%）

## 下一步

1. 多 key（`WatchID, ClientIP, IsRefresh`）版本：key 打包 + 逐列比较，直接打 Q31（当前最大热点）。
2. 表增长/溢出走 outline 调用（pgrust 的 cold-call 思路），kernel 只保留热路径。
3. 把排序键预计算进 kernel 输出，省掉 83k 组的比较器调用。
