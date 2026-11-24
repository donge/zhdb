# 能否照搬 pgrust 的机器码？

结论：**不能直接照搬**，但它的**方法**可以复用（我们已经在用）。下面是基于仓库实际代码的判断。

## 1. 许可证：最直接的门槛

- pgrust 是 **AGPL-3.0**（`LICENSE`）。
- 把它的 emitter / stencil / IR 后端代码拷进 zhdb，zhdb 在分发时就必须整体按 AGPL 开源，
  包括网络服务场景（AGPL 的 network copyleft）。
- 另外仓库里还包含 `crates/postgres-18.6-reference/`（PostgreSQL 参考实现），这部分是
  PostgreSQL License，和 AGPL 部分混在同一仓库，复制时更容易踩错。

可以合法借鉴的是**思想与事实**：ARM64 指令编码、copy-and-patch 结构、可执行内存映射方式。
这些不受版权保护；具体的代码/注释/表结构不能照抄。

## 2. 技术上：它生成的不是“通用机器码”，而是绑定自己 ABI 的代码

看两个实际文件：

`crates/gravity/kernels/src/table/fold_jit.rs`

```rust
#[repr(C)]
pub struct FoldCall {
    pub ring: [u64; FOLD_PF],
    pub base: *mut u8,
    pub mask: u64,
    pub full_at: u64,
    pub used: u64,
    pub shr: u64,
    pub len: u64,
    pub recs: *const u8,
    pub nrecs: u64,
    pub cand: *mut Candidates,
    pub layout: *const RecordLayout,
}
```

生成代码按 `offset_of!` 直接读写这些字段，并且默认：

- 哈希表是它自己的 ring + `Candidates` + `RecordLayout` 布局；
- key 哈希用 `KeyHash::home` 的 `shr`/`mask`；
- 累加器是它的 `HashAgg`/`FOLD_*` 约定；
- 还有它自己的 `Ctx`、错误/溢出处理、ring 槽位生命周期。

换到 zhdb：列是 `[]i64` / `[]f64` / `{offsets, bytes}`，分组表是 `slots: []u32` + `groups/accs`，
key 比较是逐列类型比较。把它的机器码原样贴过来，第一条 `ldr` 的偏移就是错的。

## 3. 它的“stencil”其实是完整的编译器后端

仓库里不是一个 `stencils.rs`，而是一整套后端：

- `crates/gravity/backend/tpde/`：IR 视图、寄存器分配、phi/coalesce、scratch、fixed regs、
  cold call、x64 前端 `frontend_x64.rs`；
- `crates/gravity/ir/src/jit_tags.rs`、`crates/gravity/lowerv4/src/frame/jit.rs`；
- `crates/gravity/backend/tpde/tests/` 里有大量 `phi_*`、`scratch`、`disasm`、`ops_vector` 测试；
- `crates/gravity/lint/testdata/gravity/asm/par_*.s` 是**LLVM 生成的对照汇编**（oracle），
  用来校验自己生成代码的正确性，例如 `par_scan_count.s`、`par_hashagg.s`。

也就是说，博客里 5μs 的 copy-and-patch 是入门示意；生产实现是“IR → 后端 → 机器码”，
并且有 x64/arm64 两套。只搬博客里的 stencil 片段，得不到它的能力。

## 4. 哪些可以复用（我们已经在用）

| 内容 | 结论 |
|---|---|
| ARM64 指令编码、`ldp/add/movz/b.cond` 的位布局 | 可复用（架构事实，且我们已用 `as`/`otool` 校验） |
| copy-and-patch：拼 stencil + 回填立即数/分支偏移 | 可复用（`src/jit.zig` 已是这个结构） |
| `mmap(RW) → 写码 → mprotect(RX)` + 函数指针 | 可复用（我们已实现，含 macOS `sys_icache_invalidate`） |
| 每查询编译、常量内联、慢路径外提 | 可复用（思路） |
| 具体 stencil 代码、`FoldCall`/`HashAgg` ABI、TPDE 后端 | **不可照搬**（AGPL + ABI 绑定） |
| 用它生成的 `.s` 作为 oracle 做差分测试 | 可借鉴方法（自己生成自己的 oracle） |

## 5. 如果要继续，正确的做法

1. **定义 zhdb 自己的 JIT ABI**：例如
   ```zig
   const GroupCall = extern struct {
       keys: [*]const u8,        // 打包后的 key 列
       n: u64,
       slots: [*]u32,
       mask: u64,
       groups: [*]Group,
       accs: [*]Acc,
       nspecs: u64,
   };
   ```
2. 为这个 ABI 写**针对性 emitter**（不是通用编译器）：key 类型/列数在编译期固定，
   生成 hash → probe → compare → accumulate 的直线代码。
3. 用“小 IR + 线性扫描寄存器分配”即可覆盖分组聚合；不需要 TPDE 那么大的后端。
4. 继续用 `as`/`otool` 对照编码、用 LLVM 生成的函数做 oracle，保证正确性。

这样做既避开 AGPL 代码，又能拿到 pgrust 那套“按计划定制机器码”的收益。
