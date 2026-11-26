const std = @import("std");
const builtin = @import("builtin");
extern "c" fn sys_icache_invalidate(start: ?*anyopaque, len: usize) void;
pub const supported = builtin.cpu.arch == .aarch64 and
    (builtin.os.tag == .macos or builtin.os.tag == .linux);
fn movz(rd: u5, imm16: u16) u32 {
    return 0xD2800000 | (@as(u32, imm16) << 5) | rd;
}
fn movReg(rd: u5, rm: u5) u32 {
    return 0xAA0003E0 | (@as(u32, rm) << 16) | rd;
}
fn addImm(rd: u5, rn: u5, imm12: u12) u32 {
    return 0x91000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
}
fn addShiftReg(rd: u5, rn: u5, rm: u5, shift: u6) u32 {
    return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, shift) << 10) | (@as(u32, rn) << 5) | rd;
}
fn addReg(rd: u5, rn: u5, rm: u5) u32 {
    return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
fn subsImm(rd: u5, rn: u5, imm12: u12) u32 {
    return 0xF1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
}
fn ldrX(rt: u5, rn: u5, byte_off: u32) u32 {
    return 0xF9400000 | ((byte_off / 8) << 10) | (@as(u32, rn) << 5) | rt;
}
fn ldrW(rt: u5, rn: u5, byte_off: u32) u32 {
    return 0xB9400000 | ((byte_off / 4) << 10) | (@as(u32, rn) << 5) | rt;
}
fn imm19(target: i64, here: i64) u32 {
    const off: i32 = @intCast(target - here); return @as(u32, @bitCast(off)) & 0x7FFFF;
}
fn imm26(target: i64, here: i64) u32 {
    const off: i32 = @intCast(target - here); return @as(u32, @bitCast(off)) & 0x03FFFFFF;
}
fn cbnzW(rt: u5, target: i64, here: i64) u32 {
    return 0x35000000 | (imm19(target, here) << 5) | rt;
}
fn cbzW(rt: u5, target: i64, here: i64) u32 {
    return 0x34000000 | (imm19(target, here) << 5) | rt;
}
fn bCond(cond: u4, target: i64, here: i64) u32 {
    return 0x54000000 | (imm19(target, here) << 5) | cond;
}
fn b(target: i64, here: i64) u32 {
    return 0x14000000 | imm26(target, here);
}
fn ret() u32 {
    return 0xD65F03C0;
}
const DynCode = struct {
    words: std.ArrayList(u32) = .empty,
    alloc: std.mem.Allocator,
    fn init(alloc: std.mem.Allocator) DynCode {
        return .{ .alloc = alloc };
    }
    fn deinit(self: *DynCode) void {
        self.words.deinit(self.alloc);
    }
    fn emit(self: *DynCode, w: u32) !void {
        try self.words.append(self.alloc, w);
    }
    fn here(self: *DynCode) i64 {
        return @intCast(self.words.items.len);
    }
    fn finalize(self: *DynCode, gpa: std.mem.Allocator) !Executable {
        const bytes = std.mem.sliceAsBytes(self.words.items);
        const page = std.heap.pageSize();
        const len = std.mem.alignForward(usize, @max(bytes.len, 1), page);
        const rw: std.posix.PROT = .{ .READ = true, .WRITE = true };
        const mem = try std.posix.mmap(null, len, rw, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        errdefer std.posix.munmap(mem); @memcpy(mem[0..bytes.len], bytes);
        if (builtin.os.tag == .macos) sys_icache_invalidate(mem.ptr, bytes.len);
        const rx: std.posix.PROT = .{ .READ = true, .EXEC = true };
        _ = std.c.mprotect(mem.ptr, mem.len, rx); return .{ .mem = mem, .gpa = gpa };
    }
};
pub const Executable = struct {
    mem: []align(std.heap.page_size_min) u8,
    gpa: std.mem.Allocator,
    pub fn deinit(self: *Executable) void {
        std.posix.munmap(self.mem); _ = self.gpa;
    }
    pub fn as(self: Executable, comptime Fn: type) Fn {
        return @ptrCast(@alignCast(self.mem.ptr));
    }
};
pub fn compileSumI64(gpa: std.mem.Allocator) !Executable {
    var c = DynCode.init(gpa); defer c.deinit();
    try c.emit(movz(2, 0));
    const loop = c.here(); try c.emit(ldrX(3, 0, 0));
    try c.emit(addReg(2, 2, 3)); try c.emit(addImm(0, 0, 8));
    try c.emit(subsImm(1, 1, 1));
    const br = c.here(); try c.emit(0);
    const after = c.here(); c.words.items[@intCast(br)] = bCond(1, loop, br);
    _ = after; try c.emit(movReg(0, 2));
    try c.emit(ret()); return c.finalize(gpa);
}
pub fn compileSumFilteredI64(gpa: std.mem.Allocator, eq_zero: bool) !Executable {
    var c = DynCode.init(gpa); defer c.deinit();
    try c.emit(movz(3, 0));
    const loop = c.here(); try c.emit(ldrW(4, 1, 0));
    const branch_pos = c.here(); try c.emit(0);
    try c.emit(ldrX(5, 0, 0)); try c.emit(addReg(3, 3, 5));
    const skip = c.here();
    c.words.items[@intCast(branch_pos)] = if (eq_zero)
        cbnzW(4, skip, branch_pos)
    else
        cbzW(4, skip, branch_pos);
    try c.emit(addImm(0, 0, 8)); try c.emit(addImm(1, 1, 8));
    try c.emit(subsImm(2, 2, 1));
    const br = c.here(); try c.emit(bCond(1, loop, br));
    try c.emit(movReg(0, 3)); try c.emit(ret());
    if (std.c.getenv("ZHDB_JIT_DUMP") != null) {
        for (c.words.items, 0..) |w, i| std.debug.print("{d:>3}: {x:0>8}\n", .{ i, w });
    }
    return c.finalize(gpa);
}
pub fn compileSumOffsetI64(gpa: std.mem.Allocator, k: i64) !Executable {
    var c = DynCode.init(gpa); defer c.deinit();
    try c.emit(movz(2, 0)); try c.emit(movz(6, @intCast(@as(u64, @bitCast(k)) & 0xFFFF)));
    if ((@as(u64, @bitCast(k)) >> 16) != 0) try c.emit(0xF2A00006 | ((@as(u32, @intCast((@as(u64, @bitCast(k)) >> 16) & 0xFFFF))) << 5));
    if ((@as(u64, @bitCast(k)) >> 32) != 0) try c.emit(0xF2C00006 | ((@as(u32, @intCast((@as(u64, @bitCast(k)) >> 32) & 0xFFFF))) << 5));
    const loop = c.here(); try c.emit(ldrX(3, 0, 0));
    try c.emit(addReg(3, 3, 6)); try c.emit(addReg(2, 2, 3));
    try c.emit(addImm(0, 0, 8)); try c.emit(subsImm(1, 1, 1));
    const br = c.here(); try c.emit(bCond(1, loop, br));
    try c.emit(movReg(0, 2)); try c.emit(ret());
    return c.finalize(gpa);
}
fn dupV2D(rd: u5, rn: u5) u32 {
    return 0x4E080C00 | (@as(u32, rn) << 5) | rd;
}
fn addV2D(rd: u5, rn: u5, rm: u5) u32 {
    return 0x4EE08400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
fn ldrQPost(rt: u5, rn: u5, imm: u9) u32 {
    return 0x3CC00400 | (@as(u32, imm) << 12) | (@as(u32, rn) << 5) | rt;
}
fn addpD(rd: u5, rn: u5) u32 {
    return 0x5EF1B800 | (@as(u32, rn) << 5) | rd;
}
fn umovX(rd: u5, rn: u5) u32 {
    return 0x4E083C00 | (@as(u32, rn) << 5) | rd;
}
pub fn compileSumI64Vec(gpa: std.mem.Allocator) !Executable {
    var c = DynCode.init(gpa); defer c.deinit();
    try c.emit(movz(3, 0)); try c.emit(dupV2D(0, 3));
    try c.emit(dupV2D(1, 3)); try c.emit(dupV2D(2, 3));
    try c.emit(dupV2D(3, 3));
    const loop = c.here(); try c.emit(ldrQPost(4, 0, 16));
    try c.emit(addV2D(0, 0, 4)); try c.emit(ldrQPost(5, 0, 16));
    try c.emit(addV2D(1, 1, 5)); try c.emit(ldrQPost(6, 0, 16));
    try c.emit(addV2D(2, 2, 6)); try c.emit(ldrQPost(7, 0, 16));
    try c.emit(addV2D(3, 3, 7)); try c.emit(subsImm(1, 1, 1));
    const br = c.here(); try c.emit(bCond(1, loop, br));
    try c.emit(addV2D(0, 0, 1)); try c.emit(addV2D(2, 2, 3));
    try c.emit(addV2D(0, 0, 2)); try c.emit(addpD(0, 0));
    try c.emit(umovX(0, 0)); try c.emit(ret());
    if (std.c.getenv("ZHDB_JIT_DUMP") != null) {
        for (c.words.items, 0..) |w, i| std.debug.print("{d:>3}: {x:0>8}\n", .{ i, w });
    }
    return c.finalize(gpa);
}
fn ldpQPost(rt: u5, rt2: u5, rn: u5, imm: u7) u32 {
    return 0xACC00000 | (@as(u32, imm) << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | rt;
}
pub fn compileSumI64Vec16(gpa: std.mem.Allocator) !Executable {
    var c = DynCode.init(gpa); defer c.deinit();
    try c.emit(movz(3, 0)); inline for (0..8) |i| try c.emit(dupV2D(@intCast(i), 3));
    const loop = c.here();
    inline for (0..4) |i| {
        try c.emit(ldpQPost(@intCast(8 + i * 2), @intCast(9 + i * 2), 0, 2));
    }
    inline for (0..8) |i| {
        try c.emit(addV2D(@intCast(i), @intCast(i), @intCast(8 + i)));
    }
    try c.emit(subsImm(1, 1, 1));
    const br = c.here(); try c.emit(bCond(1, loop, br));
    inline for (0..4) |i| try c.emit(addV2D(@intCast(i), @intCast(i), @intCast(4 + i)));
    try c.emit(addV2D(0, 0, 1)); try c.emit(addV2D(2, 2, 3));
    try c.emit(addV2D(0, 0, 2)); try c.emit(addpD(0, 0));
    try c.emit(umovX(0, 0)); try c.emit(ret());
    return c.finalize(gpa);
}
fn ldrXReg(rt: u5, rn: u5, rm: u5, shift: u2) u32 {
    _ = shift; return 0xF8607800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
}
fn strXReg(rt: u5, rn: u5, rm: u5, shift: u2) u32 {
    _ = shift; return 0xF8207800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
}
fn ldrWReg(rt: u5, rn: u5, rm: u5, shift: u2) u32 {
    _ = shift; return 0xB8607800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
}
fn strWReg(rt: u5, rn: u5, rm: u5, shift: u2) u32 {
    _ = shift; return 0xB8207800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
}
fn mulX(rd: u5, rn: u5, rm: u5) u32 {
    return 0x9B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
fn lsrX(rd: u5, rn: u5, sh: u6) u32 {
    const immr: u32 = sh;
    const imms: u32 = 63;
    return 0xD3400000 | (immr << 16) | (imms << 10) | (@as(u32, rn) << 5) | rd;
}
fn eorX(rd: u5, rn: u5, rm: u5) u32 {
    return 0xCA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
fn andX(rd: u5, rn: u5, rm: u5) u32 {
    return 0x8A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
fn cmpX(rn: u5, rm: u5) u32 {
    return 0xEB00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
}
fn subImm(rd: u5, rn: u5, imm12: u12) u32 {
    return 0xD1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
}
fn cbzX(rt: u5, target: i64, here: i64) u32 {
    return 0xB4000000 | (imm19(target, here) << 5) | rt;
}
fn strWImm(rt: u5, rn: u5, byte_off: u32) u32 {
    return 0xB9000000 | ((byte_off / 4) << 10) | (@as(u32, rn) << 5) | rt;
}
fn strXImm(rt: u5, rn: u5, byte_off: u32) u32 {
    return 0xF9000000 | ((byte_off / 8) << 10) | (@as(u32, rn) << 5) | rt;
}
pub fn compileGroupCountI64(gpa: std.mem.Allocator) !Executable {
    var c = DynCode.init(gpa); defer c.deinit();
    try c.emit(movz(7, 0)); try c.emit(movz(8, 0));
    try c.emit(movReg(9, 0)); try c.emit(movz(15, 0x7C15));
    try c.emit(0xF2A0000F | (@as(u32, 0x9E37) << 5));
    try c.emit(0xF2C0000F | (@as(u32, 0x79B9) << 5));
    try c.emit(0xF2E0000F | (@as(u32, 0x7F4A) << 5));
    const loop = c.here(); try c.emit(ldrX(10, 9, 0));
    try c.emit(addImm(9, 9, 8)); try c.emit(mulX(11, 10, 15));
    try c.emit(lsrX(12, 11, 29)); try c.emit(eorX(11, 11, 12));
    try c.emit(andX(11, 11, 6));
    const probe = c.here(); try c.emit(ldrWReg(13, 2, 11, 2));
    const b_new_pos = c.here(); try c.emit(0);
    try c.emit(subImm(14, 13, 1)); try c.emit(ldrWReg(16, 4, 14, 2));
    try c.emit(ldrXReg(17, 0, 16, 3)); try c.emit(cmpX(17, 10));
    const b_hit_pos = c.here(); try c.emit(0);
    try c.emit(addImm(11, 11, 1)); try c.emit(andX(11, 11, 6));
    try c.emit(b(probe, c.here()));
    const hit = c.here(); try c.emit(ldrXReg(16, 5, 14, 3));
    try c.emit(addImm(16, 16, 1)); try c.emit(strXReg(16, 5, 14, 3));
    const next_pos = c.here(); try c.emit(0);
    const new_group = c.here(); try c.emit(strWReg(7, 4, 8, 2));
    try c.emit(movz(16, 1)); try c.emit(strXReg(16, 5, 8, 3));
    try c.emit(addImm(13, 8, 1)); try c.emit(strWReg(13, 2, 11, 2));
    try c.emit(addImm(8, 8, 1));
    const next = c.here(); try c.emit(addImm(7, 7, 1));
    try c.emit(subsImm(1, 1, 1)); try c.emit(bCond(1, loop, c.here()));
    try c.emit(strXImm(8, 6, 0)); try c.emit(movReg(0, 8));
    try c.emit(ret());
    c.words.items[@intCast(b_new_pos)] = cbzW(13, new_group, b_new_pos);
    c.words.items[@intCast(b_hit_pos)] = bCond(0, hit, b_hit_pos);
    c.words.items[@intCast(next_pos)] = b(next, next_pos);
    if (std.c.getenv("ZHDB_JIT_DUMP") != null) {
        for (c.words.items, 0..) |w, i| std.debug.print("{d:>3}: {x:0>8}\n", .{ i, w });
    }
    return c.finalize(gpa);
}
pub const GroupSpec = union(enum) {
    count_all,
    sum: struct { ptr: u8, width: u8 },
};
fn ldrSum(width: u8, rt: u5, rn: u5, rm: u5) u32 {
    const base: u32 = switch (width) {
        1 => 0x38A07800,
        2 => 0x78A07800,
        4 => 0xB8A07800,
        else => 0xF8607800,
    }; return base | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
}
pub const GroupCtx = extern struct {
    a: [*]const i64,
    b: [*]const i64,
    c: [*]const i64,
    n: u64,
    slots: [*]u32,
    mask: u64,
    firsts: [*]u32,
    acc0: [*]i64,
    acc1: [*]i64,
    acc2: [*]i64,
    sum0: [*]const i64,
    sum1: [*]const i64,
    sum2: [*]const i64,
    ng: *u64,
    shard_mask: u64 = 0,
    shard_id: u64 = 0,
    trace: [*]u64 = undefined,
    trace2: [*]u64 = undefined,
};
fn ldrXImm(rt: u5, rn: u5, off: u32) u32 {
    return 0xF9400000 | ((off / 8) << 10) | (@as(u32, rn) << 5) | rt;
}
fn ldrXOff(rt: u5, rn: u5, off: u32) u32 {
    return ldrX(rt, rn, off);
}
fn strXOff(rt: u5, rn: u5, off: u32) u32 {
    return strXImm(rt, rn, off);
}
pub fn compileGroupAgg(gpa: std.mem.Allocator, key_count: u8, specs: []const GroupSpec, key32: bool) !Executable {
    return compileGroupAggImpl(gpa, key_count, specs, key32, false);
}
pub fn compileGroupAggTrace(gpa: std.mem.Allocator, key_count: u8, specs: []const GroupSpec, key32: bool) !Executable {
    return compileGroupAggImpl(gpa, key_count, specs, key32, true);
}
fn compileGroupAggImpl(gpa: std.mem.Allocator, key_count: u8, specs: []const GroupSpec, key32: bool, comptime trace: bool) !Executable {
    const stride_shift: u6 = if (specs.len == 1) 4 else 5;
    var c = DynCode.init(gpa); defer c.deinit();
    try c.emit(0xD10183FF); try c.emit(0xA90053F3);
    try c.emit(0xA9015BF5); try c.emit(0xA90263F7);
    try c.emit(0xA9036BF9); try c.emit(0xA90473FB);
    try c.emit(ldrXOff(1, 0, 0)); try c.emit(ldrXOff(2, 0, 8));
    try c.emit(ldrXOff(3, 0, 16)); try c.emit(ldrXOff(4, 0, 24));
    try c.emit(ldrXOff(5, 0, 32)); try c.emit(ldrXOff(6, 0, 40));
    try c.emit(ldrXOff(8, 0, 48)); try c.emit(ldrXOff(24, 0, 80));
    try c.emit(ldrXOff(25, 0, 88)); try c.emit(ldrXOff(26, 0, 96));
    try c.emit(ldrXOff(27, 0, 104)); try c.emit(ldrXOff(28, 0, 112));
    if (trace) {
        try c.emit(ldrXOff(0, 0, 128)); try c.emit(ldrXOff(7, 0, 136));
        try c.emit(strXReg(6, 7, 4, 3)); try c.emit(addReg(20, 4, 4));
        try c.emit(addImm(20, 20, 1)); try c.emit(strXReg(5, 7, 20, 3));
    }
    try c.emit(movz(12, 0)); try c.emit(movz(13, 0));
    try c.emit(movz(14, 0x7C15)); try c.emit(0xF2A0000E | (@as(u32, 0x9E37) << 5));
    try c.emit(0xF2C0000E | (@as(u32, 0x79B9) << 5));
    try c.emit(0xF2E0000E | (@as(u32, 0x7F4A) << 5));
    const loop = c.here();
    if (key32) {
        try c.emit(ldrWReg(15, 1, 13, 2));
        if (key_count >= 2) try c.emit(ldrWReg(16, 2, 13, 2));
        if (key_count >= 3) try c.emit(ldrWReg(17, 3, 13, 2));
    } else {
        try c.emit(ldrXReg(15, 1, 13, 3));
        if (key_count >= 2) try c.emit(ldrXReg(16, 2, 13, 3));
        if (key_count >= 3) try c.emit(ldrXReg(17, 3, 13, 3));
    }
    try c.emit(mulX(11, 15, 14)); try c.emit(lsrX(21, 11, 29));
    try c.emit(eorX(11, 11, 21));
    if (key_count >= 2) {
        try c.emit(mulX(22, 16, 14)); try c.emit(lsrX(21, 22, 29));
        try c.emit(eorX(22, 22, 21)); try c.emit(eorX(11, 11, 22));
    }
    if (key_count >= 3) {
        try c.emit(mulX(22, 17, 14)); try c.emit(lsrX(21, 22, 29));
        try c.emit(eorX(22, 22, 21)); try c.emit(eorX(11, 11, 22));
    }
    try c.emit(andX(20, 11, 28)); try c.emit(ldrXImm(21, 0, 120));
    try c.emit(cmpX(20, 21));
    const b_skip = c.here(); try c.emit(0);
    try c.emit(lsrX(11, 11, 3)); try c.emit(andX(11, 11, 6));
    if (trace) try c.emit(strXReg(11, 0, 13, 3));
    const probe = c.here(); try c.emit(ldrWReg(19, 5, 11, 2));
    const b_new = c.here(); try c.emit(0);
    try c.emit(subImm(20, 19, 1)); try c.emit(addShiftReg(9, 8, 20, stride_shift));
    try c.emit(ldrX(21, 9, 0));
    if (key32) try c.emit(ldrWReg(22, 1, 21, 2)) else try c.emit(ldrXReg(22, 1, 21, 3));
    var ne_sites: [3]i64 = .{ -1, -1, -1 }; try c.emit(cmpX(22, 15));
    ne_sites[0] = c.here(); try c.emit(0);
    if (key_count >= 2) {
        if (key32) try c.emit(ldrWReg(22, 2, 21, 2)) else try c.emit(ldrXReg(22, 2, 21, 3));
        try c.emit(cmpX(22, 16)); ne_sites[1] = c.here();
        try c.emit(0);
    }
    if (key_count >= 3) {
        if (key32) try c.emit(ldrWReg(22, 3, 21, 2)) else try c.emit(ldrXReg(22, 3, 21, 3));
        try c.emit(cmpX(22, 17)); ne_sites[2] = c.here();
        try c.emit(0);
    }
    for (specs, 0..) |sp, si| {
        switch (sp) {
            .count_all => {
                const off: u32 = 8 + 8 * @as(u32, @intCast(si));
                try c.emit(ldrX(23, 9, off)); try c.emit(addImm(23, 23, 1));
                try c.emit(strXImm(23, 9, off));
            },
            .sum => |ss| {
                const sum_reg: u5 = @intCast(24 + ss.ptr);
                const off: u32 = 8 + 8 * @as(u32, @intCast(si));
                try c.emit(ldrSum(ss.width, 23, sum_reg, 13));
                try c.emit(ldrX(22, 9, off)); try c.emit(addReg(23, 23, 22));
                try c.emit(strXImm(23, 9, off));
            },
        }
    }
    const b_next = c.here(); try c.emit(0);
    const nextprobe = c.here();
    for (ne_sites) |site| {
        if (site >= 0) c.words.items[@intCast(site)] = bCond(1, nextprobe, site);
    }
    try c.emit(addImm(11, 11, 1)); try c.emit(andX(11, 11, 6));
    try c.emit(b(probe, c.here()));
    const new_group = c.here(); if (trace) try c.emit(strXReg(11, 7, 12, 3));
    try c.emit(addShiftReg(9, 8, 12, stride_shift)); try c.emit(strXImm(13, 9, 0));
    for (specs, 0..) |sp, si| {
        const off: u32 = 8 + 8 * @as(u32, @intCast(si));
        switch (sp) {
            .count_all => {
                try c.emit(movz(23, 1)); try c.emit(strXImm(23, 9, off));
            },
            .sum => |ss| {
                const sum_reg: u5 = @intCast(24 + ss.ptr);
                try c.emit(ldrSum(ss.width, 23, sum_reg, 13));
                try c.emit(strXImm(23, 9, off));
            },
        }
    }
    try c.emit(addImm(21, 12, 1)); try c.emit(strWReg(21, 5, 11, 2));
    try c.emit(addImm(12, 12, 1));
    const next = c.here(); c.words.items[@intCast(b_next)] = b(next, b_next);
    c.words.items[@intCast(b_skip)] = bCond(1, next, b_skip);
    c.words.items[@intCast(b_new)] = cbzW(19, new_group, b_new);
    try c.emit(addImm(13, 13, 1)); try c.emit(subsImm(4, 4, 1));
    try c.emit(bCond(1, loop, c.here())); try c.emit(strXImm(12, 27, 0));
    try c.emit(movReg(0, 12)); try c.emit(0xA94473FB);
    try c.emit(0xA9436BF9); try c.emit(0xA94263F7);
    try c.emit(0xA9415BF5); try c.emit(0xA94053F3);
    try c.emit(0x910183FF); try c.emit(ret());
    if (std.c.getenv("ZHDB_JIT_DUMP") != null) {
        for (c.words.items, 0..) |w, i| std.debug.print("{d:>3}: {x:0>8}\n", .{ i, w });
    }
    return c.finalize(gpa);
}
pub const InlineCtx = extern struct {
    a: [*]const i64,
    b: [*]const i64,
    c: [*]const i64,
    n: u64,
    entries: [*]i64,
    mask: u64,
    ng: *u64,
    sum0: [*]const i64,
    sum1: [*]const i64,
    sum2: [*]const i64,
    shard_mask: u64 = 0,
    shard_id: u64 = 0,
};
fn addShift(rd: u5, rn: u5, rm: u5, shift: u6) u32 {
    return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, shift) << 10) | (@as(u32, rn) << 5) | rd;
}
fn ldrXRegOff(rt: u5, rn: u5, rm: u5, shift: u2, off: u32) u32 {
    return 0xF8600800 | (@as(u32, rm) << 16) | (@as(u32, shift) << 12) | (@as(u32, off / 8) << 10) | (@as(u32, rn) << 5) | rt;
}
pub fn compileGroupInline(gpa: std.mem.Allocator, key_count: u8, specs: []const GroupSpec, key32: bool) !Executable {
    var c = DynCode.init(gpa); defer c.deinit();
    try c.emit(0xD10183FF); try c.emit(0xA90053F3);
    try c.emit(0xA9015BF5); try c.emit(0xA90263F7);
    try c.emit(0xA9036BF9); try c.emit(0xA90473FB);
    try c.emit(ldrXImm(1, 0, 0)); try c.emit(ldrXImm(2, 0, 8));
    try c.emit(ldrXImm(3, 0, 16)); try c.emit(ldrXImm(4, 0, 24));
    try c.emit(ldrXImm(5, 0, 32)); try c.emit(ldrXImm(6, 0, 40));
    try c.emit(ldrXImm(27, 0, 48)); try c.emit(ldrXImm(24, 0, 56));
    try c.emit(ldrXImm(25, 0, 64)); try c.emit(ldrXImm(26, 0, 72));
    try c.emit(ldrXImm(28, 0, 80)); try c.emit(movz(12, 0));
    try c.emit(movz(13, 0)); try c.emit(movz(14, 0x7C15));
    try c.emit(0xF2A0000E | (@as(u32, 0x9E37) << 5));
    try c.emit(0xF2C0000E | (@as(u32, 0x79B9) << 5));
    try c.emit(0xF2E0000E | (@as(u32, 0x7F4A) << 5));
    const loop = c.here();
    if (key32) {
        try c.emit(ldrWReg(15, 1, 13, 2));
        if (key_count >= 2) try c.emit(ldrWReg(16, 2, 13, 2));
        if (key_count >= 3) try c.emit(ldrWReg(17, 3, 13, 2));
    } else {
        try c.emit(ldrXReg(15, 1, 13, 3));
        if (key_count >= 2) try c.emit(ldrXReg(16, 2, 13, 3));
        if (key_count >= 3) try c.emit(ldrXReg(17, 3, 13, 3));
    }
    try c.emit(mulX(11, 15, 14)); try c.emit(lsrX(21, 11, 29));
    try c.emit(eorX(11, 11, 21));
    if (key_count >= 2) {
        try c.emit(mulX(22, 16, 14)); try c.emit(lsrX(21, 22, 29));
        try c.emit(eorX(22, 22, 21)); try c.emit(eorX(11, 11, 22));
    }
    if (key_count >= 3) {
        try c.emit(mulX(22, 17, 14)); try c.emit(lsrX(21, 22, 29));
        try c.emit(eorX(22, 22, 21)); try c.emit(eorX(11, 11, 22));
    }
    try c.emit(andX(20, 11, 28)); try c.emit(ldrXImm(21, 0, 88));
    try c.emit(cmpX(20, 21));
    const b_skip = c.here(); try c.emit(0);
    try c.emit(lsrX(11, 11, 3)); try c.emit(andX(11, 11, 6));
    const probe = c.here(); try c.emit(addShift(19, 5, 11, 6));
    try c.emit(ldrXImm(20, 19, 24));
    const b_new = c.here(); try c.emit(0);
    try c.emit(subImm(21, 20, 1));
    if (key32) try c.emit(ldrWReg(22, 1, 21, 2)) else try c.emit(ldrXReg(22, 1, 21, 3));
    try c.emit(cmpX(22, 15));
    var miss_sites: [3]i64 = .{ -1, -1, -1 }; miss_sites[0] = c.here();
    try c.emit(0);
    if (key_count >= 2) {
        if (key32) try c.emit(ldrWReg(22, 2, 21, 2)) else try c.emit(ldrXReg(22, 2, 21, 3));
        try c.emit(cmpX(22, 16)); miss_sites[1] = c.here();
        try c.emit(0);
    }
    if (key_count >= 3) {
        if (key32) try c.emit(ldrWReg(22, 3, 21, 2)) else try c.emit(ldrXReg(22, 3, 21, 3));
        try c.emit(cmpX(22, 17)); miss_sites[2] = c.here();
        try c.emit(0);
    }
    for (specs, 0..) |sp, si| {
        const off: u32 = 32 + @as(u32, @intCast(si)) * 8;
        switch (sp) {
            .count_all => {
                try c.emit(ldrXImm(22, 19, off)); try c.emit(addImm(22, 22, 1));
                try c.emit(strXImm(22, 19, off));
            },
            .sum => |ss| {
                const sreg: u5 = @intCast(24 + ss.ptr);
                try c.emit(ldrSum(ss.width, 23, sreg, 13));
                try c.emit(ldrXImm(22, 19, off)); try c.emit(addReg(23, 23, 22));
                try c.emit(strXImm(23, 19, off));
            },
        }
    }
    const b_next = c.here(); try c.emit(0);
    const nextprobe = c.here();
    for (miss_sites) |site| {
        if (site >= 0) c.words.items[@intCast(site)] = bCond(1, nextprobe, site);
    }
    try c.emit(addImm(11, 11, 1)); try c.emit(andX(11, 11, 6));
    try c.emit(b(probe, c.here()));
    const new_group = c.here(); try c.emit(strXImm(15, 19, 0));
    if (key_count >= 2) try c.emit(strXImm(16, 19, 8));
    if (key_count >= 3) try c.emit(strXImm(17, 19, 16)); try c.emit(addImm(21, 13, 1));
    try c.emit(strXImm(21, 19, 24));
    for (specs, 0..) |sp, si| {
        const off: u32 = 32 + @as(u32, @intCast(si)) * 8;
        switch (sp) {
            .count_all => {
                try c.emit(movz(22, 1)); try c.emit(strXImm(22, 19, off));
            },
            .sum => |ss| {
                const sreg: u5 = @intCast(24 + ss.ptr);
                try c.emit(ldrSum(ss.width, 22, sreg, 13));
                try c.emit(strXImm(22, 19, off));
            },
        }
    }
    try c.emit(addImm(12, 12, 1));
    const next = c.here(); c.words.items[@intCast(b_next)] = b(next, b_next);
    c.words.items[@intCast(b_new)] = cbzX(20, new_group, b_new);
    c.words.items[@intCast(b_skip)] = bCond(1, next, b_skip);
    try c.emit(addImm(13, 13, 1)); try c.emit(subsImm(4, 4, 1));
    try c.emit(bCond(1, loop, c.here())); try c.emit(strXImm(12, 27, 0));
    try c.emit(movReg(0, 12)); try c.emit(0xA94473FB);
    try c.emit(0xA9436BF9); try c.emit(0xA94263F7);
    try c.emit(0xA9415BF5); try c.emit(0xA94053F3);
    try c.emit(0x910183FF); try c.emit(ret());
    if (std.c.getenv("ZHDB_JIT_DUMP") != null) {
        for (c.words.items, 0..) |w, i| std.debug.print("{d:>3}: {x:0>8}\n", .{ i, w });
    }
    return c.finalize(gpa);
}
test "jit sum matches zig loop" {
    if (!supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var vals: [1000]i64 = undefined;
    var i: usize = 0; while (i < vals.len) : (i += 1) vals[i] = @intCast(i);
    var want: i64 = 0; for (vals) |v| want += v;
    var exe = try compileSumI64(alloc); defer exe.deinit();
    const f = exe.as(*const fn ([*]const i64, usize) callconv(.c) i64);
    try std.testing.expectEqual(want, f(&vals, vals.len));
}
test "jit filtered sum" {
    if (!supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const vals = [_]i64{ 10, 20, 30, 40 };
    const filt = [_]i64{ 0, 1, 0, 1 };
    var exe = try compileSumFilteredI64(alloc, false); defer exe.deinit();
    const f = exe.as(*const fn ([*]const i64, [*]const i64, usize) callconv(.c) i64);
    try std.testing.expectEqual(@as(i64, 60), f(&vals, &filt, vals.len));
}
test "group kernel is deterministic and exact (no reserved x18)" {
    if (!supported) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const n = 20000;
    const keys = try alloc.alloc(i64, n); defer alloc.free(keys);
    var rnd = std.Random.DefaultPrng.init(7);
    for (keys) |*k| k.* = rnd.random().intRangeAtMost(i64, 0, 9000);
    std.mem.sort(i64, keys, {}, comptime std.sort.asc(i64));
    const cap: usize = 1 << 16;
    const slots = try alloc.alloc(u32, cap); defer alloc.free(slots);
    const recs = try alloc.alloc(i64, (n + 1) * 2); defer alloc.free(recs);
    var exe = try compileGroupAgg(alloc, 1, &.{.count_all}, false); defer exe.deinit();
    const f = exe.as(*const fn (*GroupCtx) callconv(.c) u64);
    var map = std.AutoHashMap(i64, i64).init(alloc); defer map.deinit();
    for (keys) |k| {
        const gop = try map.getOrPut(k); if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    for (0..4) |_| {
        @memset(slots, 0); @memset(recs, 0);
        var ng: u64 = 0;
        var ctx = GroupCtx{
            .a = keys.ptr,
            .b = keys.ptr,
            .c = keys.ptr,
            .n = n,
            .slots = slots.ptr,
            .mask = cap - 1,
            .firsts = @ptrCast(recs.ptr),
            .acc0 = recs.ptr,
            .acc1 = recs.ptr,
            .acc2 = recs.ptr,
            .sum0 = keys.ptr,
            .sum1 = keys.ptr,
            .sum2 = keys.ptr,
            .ng = &ng,
        };
        const got = f(&ctx);
        try std.testing.expectEqual(@as(u64, @intCast(map.count())), got);
        var sum: i64 = 0; for (0..@intCast(got)) |gi| sum += recs[gi * 2 + 1];
        try std.testing.expectEqual(@as(i64, n), sum);
        for (0..@intCast(got)) |gi| {
            const first: usize = @intCast(recs[gi * 2]);
            try std.testing.expectEqual(map.get(keys[first]).?, recs[gi * 2 + 1]);
        }
    }
}