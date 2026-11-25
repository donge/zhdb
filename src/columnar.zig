const std = @import("std");
const lz4 = @import("lz4.zig");
extern "c" fn memmem(haystack: ?*const anyopaque, haystacklen: usize, needle: ?*const anyopaque, needlelen: usize) ?*anyopaque;
fn containsSub(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    const first = needle[0];
    const last_start = hay.len - needle.len;
    if (needle.len <= 16 and hay.len >= 32) {
        const V = @Vector(16, u8);
        const splat: V = @splat(first);
        const lastch = needle[needle.len - 1];
        const last_v: V = @splat(lastch);
        if (needle.len >= 2) {
            var i: usize = 0;
            while (i + 16 + needle.len - 1 <= hay.len) : (i += 16) {
                const v: V = hay[i..][0..16].*;
                const w: V = hay[i + needle.len - 1 ..][0..16].*;
                var mask: u16 = @bitCast((v == splat) & (w == last_v));
                while (mask != 0) {
                    const bit = @ctz(mask);
                    const pos = i + bit;
                    if (std.mem.eql(u8, hay[pos .. pos + needle.len], needle)) return true;
                    mask &= mask - 1;
                }
            }
            while (i <= last_start) : (i += 1) {
                if (hay[i] == first and hay[i + needle.len - 1] == lastch and
                    std.mem.eql(u8, hay[i .. i + needle.len], needle)) return true;
            }
            return false;
        }
        var i: usize = 0;
        while (i + 16 <= hay.len) : (i += 16) {
            const v: V = hay[i..][0..16].*;
            var mask: u16 = @bitCast(v == splat);
            while (mask != 0) {
                const bit = @ctz(mask);
                const pos = i + bit;
                if (pos <= last_start and std.mem.eql(u8, hay[pos .. pos + needle.len], needle)) return true;
                mask &= mask - 1;
            }
            if (i >= last_start) return false;
        }
        while (i <= last_start) : (i += 1) {
            if (hay[i] == first and std.mem.eql(u8, hay[i .. i + needle.len], needle)) return true;
        }
        return false;
    }
    if (hay.len <= 128 and needle.len <= 16) {
        var j: usize = 0;
        while (j <= last_start) : (j += 1) {
            if (hay[j] == first and std.mem.eql(u8, hay[j .. j + needle.len], needle)) return true;
        }
        return false;
    }
    return memmem(hay.ptr, hay.len, needle.ptr, needle.len) != null;
}
const sql = @import("sql.zig");
const storage = @import("storage.zig");
const btree = @import("btree.zig");
const jit = @import("jit.zig");
const Value = @import("value.zig").Value;
pub const Kind = enum { int, float, str };
pub const Scratch = struct {
    buf: []u8 = &.{},
    used: usize = 0,
    pub fn reset(self: *Scratch) void {
        self.used = 0;
    }
    pub fn alloc(self: *Scratch, comptime T: type, count: usize) ?[]T {
        const al = @alignOf(T);
        const used = std.mem.alignForward(usize, self.used, al);
        const bytes = count * @sizeOf(T);
        if (used + bytes > self.buf.len) return null;
        self.used = used + bytes;
        const base: [*]u8 = self.buf.ptr + used;
        return @as([*]T, @ptrCast(@alignCast(base)))[0..count];
    }
};
pub const Column = struct {
    name: []const u8,
    kind: Kind,
};
pub const delta_magic = "ZDBD";
const D_INT: u8 = 0;
const D_FLOAT: u8 = 1;
const D_TEXT: u8 = 2;
const D_NULL: u8 = 3;
pub const str_none: u32 = std.math.maxInt(u32);
pub const StrData = struct {
    offsets: []u32, // nrows + 1
    bytes: []u8,
    row_ref: ?[]u32 = null,
    row_len: ?[]u32 = null,
    patched: []u8 = &.{},
    patched_cap: usize = 0,
    patched_owner: ?std.mem.Allocator = null,
    bytes_owner: ?std.mem.Allocator = null,
    refs_owner: ?std.mem.Allocator = null,
    dict_ids: []const u32 = &.{},
    bytes_cap: usize = 0,
    offsets_cap: usize = 0,
    offsets_owner: ?std.mem.Allocator = null,
    pub inline fn at(self: StrData, i: usize) []const u8 {
        if (self.row_ref) |rr| {
            const r = rr[i];
            if (r != str_none) return self.patched[r .. r + self.row_len.?[i]];
        }
        if (self.dict_ids.len != 0) {
            const id = self.dict_ids[i];
            return self.bytes[self.offsets[id]..self.offsets[id + 1]];
        }
        return self.bytes[self.offsets[i]..self.offsets[i + 1]];
    }
    pub fn patchAt(self: *StrData, a: std.mem.Allocator, ri: usize, text: []const u8, nrows: usize) bool {
        return self.patchAtOwner(a, null, ri, text, nrows);
    }
    pub fn patchAtOwner(
        self: *StrData,
        a: std.mem.Allocator,
        owner: ?std.mem.Allocator,
        ri: usize,
        text: []const u8,
        nrows: usize,
    ) bool {
        if (ri >= nrows) return false;
        if (self.row_ref == null) {
            const rr_alloc = owner orelse a;
            const rr = rr_alloc.alloc(u32, nrows) catch return false;
            const rl = rr_alloc.alloc(u32, nrows) catch return false;
            @memset(rr, str_none);
            @memset(rl, 0);
            self.row_ref = rr;
            self.row_len = rl;
            self.refs_owner = owner;
        }
        const off = self.patched.len;
        const need = off + text.len;
        if (need > self.patched_cap) {
            const newcap = @max(need, @max(64, self.patched_cap * 2));
            const buf_alloc = owner orelse a;
            const nb = buf_alloc.alloc(u8, newcap) catch return false;
            if (off > 0) @memcpy(nb[0..off], self.patched);
            if (self.patched_owner) |o| {
                if (self.patched_cap > 0) o.free(self.patched.ptr[0..self.patched_cap]);
            }
            self.patched = nb[0..off];
            self.patched_cap = newcap;
            self.patched_owner = owner;
        }
        if (text.len > 0) @memcpy(self.patched.ptr[off..need], text);
        self.patched = self.patched.ptr[0..need];
        self.row_ref.?[ri] = @intCast(off);
        self.row_len.?[ri] = @intCast(text.len);
        return true;
    }
};
pub const DictLoad = struct {
    tab: []u64 = &.{},
    mask: usize = 0,
    offs: []u32,
    bytes: []u8,
    ids: []u32,
    used: usize = 0,
    ndv: usize = 0,
    gpa: std.mem.Allocator,
    fn hashOf(text: []const u8) u32 {
        const len = text.len;
        var a: u64 = @as(u64, len) *% 0x9E3779B97F4A7C15;
        if (len >= 8) {
            a ^= std.mem.readInt(u64, text[0..8], .little);
            a ^= std.mem.readInt(u64, text[len - 8 ..][0..8], .little) *% 0xC2B2AE3D27D4EB4F;
            if (len >= 32) {
                const mid = (len / 2) - 4;
                a ^= std.mem.readInt(u64, text[mid..][0..8], .little) *% 0x165667B19E3779F9;
            }
        } else if (len > 0) {
            var v: u64 = 0;
            for (text, 0..) |b, i| v |= @as(u64, b) << @intCast(8 * i);
            a ^= v;
        }
        a ^= a >> 33;
        a *%= 0xFF51AFD7ED558CCD;
        a ^= a >> 33;
        return @as(u32, @truncate(a)) | 1;
    }
    fn grow(self: *DictLoad) !void {
        const ncap: usize = if (self.tab.len == 0) 1 << 12 else self.tab.len * 2;
        const nt = try self.gpa.alloc(u64, ncap);
        @memset(nt, 0);
        const nmask = ncap - 1;
        for (0..self.ndv) |id| {
            const h = hashOf(self.bytes[self.offs[id]..self.offs[id + 1]]);
            var slot = @as(usize, h) & nmask;
            while (nt[slot] != 0) slot = (slot + 1) & nmask;
            nt[slot] = (@as(u64, h) << 32) | @as(u64, id + 1);
        }
        if (self.tab.len > 0) self.gpa.free(self.tab);
        self.tab = nt;
        self.mask = nmask;
    }
    fn intern(self: *DictLoad, text: []const u8) !u32 {
        if (self.tab.len == 0 or (self.ndv + 1) * 10 >= self.tab.len * 7) try self.grow();
        const h = hashOf(text);
        var slot = @as(usize, h) & self.mask;
        while (true) {
            const e = self.tab[slot];
            if (e == 0) {
                if (self.used + text.len > self.bytes.len or self.ndv + 1 >= self.offs.len) return error.NoSpaceLeft;
                const off = self.used;
                if (text.len > 0) @memcpy(self.bytes[off .. off + text.len], text);
                self.used += text.len;
                self.offs[self.ndv] = @intCast(off);
                self.ndv += 1;
                self.offs[self.ndv] = @intCast(self.used);
                const id: u32 = @intCast(self.ndv - 1);
                self.tab[slot] = (@as(u64, h) << 32) | @as(u64, id + 1);
                return id;
            }
            const id: u32 = @as(u32, @truncate(e)) - 1;
            if (@as(u32, @truncate(e >> 32)) == h and
                std.mem.eql(u8, text, self.bytes[self.offs[id]..self.offs[id + 1]])) return id;
            slot = (slot + 1) & self.mask;
        }
    }
    fn deinit(self: *DictLoad) void {
        if (self.tab.len > 0) self.gpa.free(self.tab);
        self.tab = &.{};
    }
};
pub const Data = union(enum) {
    ints: []i64,
    ints8: []i8,
    ints16: []i16,
    ints32: []i32,
    floats: []f64,
    strs: StrData,
    pub inline fn isInt(self: Data) bool {
        return switch (self) {
            .ints, .ints8, .ints16, .ints32 => true,
            else => false,
        };
    }
    pub inline fn intAt(self: Data, ri: usize) i64 {
        return switch (self) {
            .ints => |a| a[ri],
            .ints8 => |a| a[ri],
            .ints16 => |a| a[ri],
            .ints32 => |a| a[ri],
            else => 0,
        };
    }
    pub inline fn i64Slice(self: Data) ?[]const i64 {
        return switch (self) {
            .ints => |a| a,
            else => null,
        };
    }
};
pub const Encoding = struct {
    ids: []u32,
    first: []u32,
    counts: []u32 = &.{},
    rank: []u32 = &.{},
    byrank: []u32 = &.{},
};
pub const WbCosts = struct {
    write_ns_byte: f64 = 1.0,
    encode_ns_row: f64 = 60.0,
    replay_ns_row: f64 = 250.0,
    compact_row_ns: f64 = 79.0,
    samples: u64 = 0,
    scan_row_ns: f64 = 0,
    str_raw_ns: f64 = 0,
    str_dict_ns: f64 = 0,
};
pub const trailer_len_v3: usize = 68;
pub const trailer_len_v2: usize = 44;
pub const trailer_len_v1: usize = 36;
pub const BlockStat = struct { min: i64, max: i64 };
pub const PairNdv = struct { a: u16, b: u16, ndv: u32 };
pub const TupleNdv = struct { a: u16, b: u16, c: u16, ndv: u32 };
pub const MultiNdv = struct { cols: [32]u16 = @splat(0), n: u8 = 0, ndv: u32 = 0 };
pub const KeyIndex = struct {
    keys: []i64,
    offsets: []u32,
    rows: []u32,
    block_rows: usize = 8192,
    tree: ?btree.BTree = null,
    pub fn build(a: std.mem.Allocator, vals: []const i64, block_rows: usize) !*KeyIndex {
        var map = std.AutoHashMap(i64, u32).init(a);
        defer map.deinit();
        var lists = std.ArrayList(std.ArrayList(u32)).empty;
        defer {
            for (lists.items) |*l| l.deinit(a);
            lists.deinit(a);
        }
        for (vals, 0..) |v, i| {
            const gop = try map.getOrPut(v);
            if (!gop.found_existing) {
                try lists.append(a, .empty);
                gop.value_ptr.* = @intCast(lists.items.len - 1);
            }
            try lists.items[gop.value_ptr.*].append(a, @intCast(i));
        }
        const keys = try a.alloc(i64, lists.items.len);
        var it = map.keyIterator();
        var k: usize = 0;
        while (it.next()) |kv| : (k += 1) keys[k] = kv.*;
        std.mem.sort(i64, keys, {}, std.sort.asc(i64));
        var total: usize = 0;
        for (lists.items) |l| total += l.items.len;
        const offsets = try a.alloc(u32, keys.len + 1);
        const rows = try a.alloc(u32, total);
        var w: usize = 0;
        for (keys, 0..) |key, i| {
            offsets[i] = @intCast(w);
            const li = map.get(key).?;
            @memcpy(rows[w .. w + lists.items[li].items.len], lists.items[li].items);
            w += lists.items[li].items.len;
        }
        offsets[keys.len] = @intCast(w);
        const idx = try a.create(KeyIndex);
        idx.* = .{ .keys = keys, .offsets = offsets, .rows = rows, .block_rows = block_rows };
        idx.tree = try btree.BTree.build(a, keys, offsets, rows);
        return idx;
    }
    pub fn range(self: *const KeyIndex, a: std.mem.Allocator, lo: i64, hi: i64, out: *std.ArrayList(u32)) !void {
        if (self.tree) |*t| {
            const mut: *btree.BTree = @constCast(t);
            return mut.range(a, lo, hi, out);
        }
        var i = std.sort.lowerBound(i64, self.keys, lo, struct {
            fn cmp(key: i64, item: i64) std.math.Order {
                return std.math.order(key, item);
            }
        }.cmp);
        while (i < self.keys.len and self.keys[i] <= hi) : (i += 1) {
            const off_a: usize = self.offsets[i];
            const off_b: usize = self.offsets[i + 1];
            try out.appendSlice(a, self.rows[off_a..off_b]);
        }
    }
    pub fn countKeysInRange(self: *const KeyIndex, lo: i64, hi: i64) usize {
        if (self.tree) |*t| {
            const mut: *btree.BTree = @constCast(t);
            return mut.countKeysInRange(lo, hi);
        }
        var n: usize = 0;
        var i = std.sort.lowerBound(i64, self.keys, lo, struct {
            fn cmp(key: i64, item: i64) std.math.Order {
                return std.math.order(key, item);
            }
        }.cmp);
        while (i < self.keys.len and self.keys[i] <= hi) : (i += 1) n += 1;
        return n;
    }
    pub fn lookup(self: *const KeyIndex, key: i64) ?[]const u32 {
        if (self.tree) |*t| {
            const mut: *btree.BTree = @constCast(t);
            return mut.lookup(key);
        }
        const i = std.sort.lowerBound(i64, self.keys, key, struct {
            fn cmp(k: i64, item: i64) std.math.Order {
                return std.math.order(k, item);
            }
        }.cmp);
        if (i < self.keys.len and self.keys[i] == key) {
            return self.rows[self.offsets[i]..self.offsets[i + 1]];
        }
        return null;
    }
};
pub const Table = struct {
    nrows: usize,
    cols: []Column,
    data: []Data,
    enc: []?Encoding,
    stats: []?[]BlockStat = &.{},
    block_rows: usize = 8192,
    valid: []?[]u8 = &.{},
    has_bool: bool = false,
    has_int2: bool = false,
    tomb: ?[]u8 = null,
    delta_owner: u64 = 0,
    delta_inserts: bool = false,
    row_cap: usize = 0,
    heap: std.mem.Allocator = std.heap.page_allocator,
    pair_ndv: []PairNdv = &.{},
    pair_req: []PairNdv = &.{},
    triple_req: []TupleNdv = &.{},
    triple_ndv: []TupleNdv = &.{},
    multi_req: []MultiNdv = &.{},
    multi_ndv: []MultiNdv = &.{},
    wb_costs: ?WbCosts = null,
    enc_maps: []?std.StringHashMap(u32) = &.{},
    keyidx: []?*KeyIndex = &.{},
    scratch: []u8 = &.{},
    dict_load: []?DictLoad = &.{},
    scratch_used: usize = 0,
    arena: std.heap.ArenaAllocator,
    pub fn buildEmpty(gpa: std.mem.Allocator, cols: []const Column, cap: usize, str_bytes: ?[]const usize, int_col: ?[]const bool, int_min: ?[]const i64, int_max: ?[]const i64) !*Table {
        const t = try gpa.create(Table);
        errdefer gpa.destroy(t);
        t.* = .{
            .nrows = 0,
            .cols = &.{},
            .data = &.{},
            .enc = &.{},
            .arena = std.heap.ArenaAllocator.init(gpa),
            .row_cap = cap,
        };
        const a = t.arena.allocator();
        t.cols = try a.alloc(Column, cols.len);
        for (cols, 0..) |c, i| t.cols[i] = .{ .name = try a.dupe(u8, c.name), .kind = c.kind };
        t.data = try a.alloc(Data, cols.len);
        t.enc = try a.alloc(?Encoding, cols.len);
        @memset(t.enc, null);
        t.valid = try a.alloc(?[]u8, cols.len);
        @memset(t.valid, null);
        for (cols, 0..) |c, ci| {
            switch (c.kind) {
                .int => {
                    const want = if (int_col != null and ci < int_col.?.len and int_col.?[ci]) blk: {
                        const lo = int_min.?[ci];
                        const hi = int_max.?[ci];
                        if (lo > hi) break :blk @as(u8, 0);
                        if (lo >= std.math.minInt(i8) and hi <= std.math.maxInt(i8)) break :blk @as(u8, 1);
                        if (lo >= std.math.minInt(i16) and hi <= std.math.maxInt(i16)) break :blk @as(u8, 2);
                        if (lo >= std.math.minInt(i32) and hi <= std.math.maxInt(i32)) break :blk @as(u8, 3);
                        break :blk @as(u8, 0);
                    } else @as(u8, 0);
                    t.data[ci] = switch (want) {
                        1 => .{ .ints8 = try a.alloc(i8, cap) },
                        2 => .{ .ints16 = try a.alloc(i16, cap) },
                        3 => .{ .ints32 = try a.alloc(i32, cap) },
                        else => .{ .ints = try gpa.alloc(i64, cap) },
                    };
                },
                .float => t.data[ci] = .{ .floats = try a.alloc(f64, cap) },
                .str => {
                    if (str_bytes != null) {
                        const want = if (ci < str_bytes.?.len) str_bytes.?[ci] + 4096 else cap * 8 + 4096;
                        const bbuf = try gpa.alloc(u8, want);
                        const boffs = try gpa.alloc(u32, cap + 1);
                        const bids = try gpa.alloc(u32, cap);
                        @memset(boffs, 0);
                        t.data[ci] = .{ .strs = .{ .offsets = &.{}, .bytes = &.{}, .dict_ids = &.{} } };
                        if (t.dict_load.len == 0) {
                            t.dict_load = try a.alloc(?DictLoad, cols.len);
                            for (t.dict_load) |*d| d.* = null;
                        }
                        t.dict_load[ci] = .{
                            .offs = boffs,
                            .bytes = bbuf,
                            .ids = bids,
                            .gpa = gpa,
                        };
                        continue;
                    }
                    const offsets = try gpa.alloc(u32, cap + 1);
                    @memset(offsets, 0);
                    var sd = StrData{ .offsets = offsets, .bytes = &.{}, .offsets_owner = gpa, .offsets_cap = cap + 1 };
                    if (str_bytes) |caps| {
                        if (ci < caps.len) {
                            const want = caps[ci] + 4096;
                            const buf = try gpa.alloc(u8, want);
                            sd.patched = buf[0..0];
                            sd.patched_cap = want;
                            sd.patched_owner = gpa;
                        }
                    }
                    t.data[ci] = .{ .strs = sd };
                },
            }
        }
        t.heap = gpa;
        t.scratch = &.{};
        t.scratch_used = 0;
        t.stats = try a.alloc(?[]BlockStat, cols.len);
        @memset(t.stats, null);
        return t;
    }
    pub fn build(gpa: std.mem.Allocator, cols: []const Column, rows: []const []Value) !*Table {
        return self_build(gpa, cols, rows, null);
    }
    pub fn buildForView(gpa: std.mem.Allocator, cols: []const Column, rows: []const []Value) !*Table {
        return self_build2(gpa, cols, rows, null, true);
    }
    pub fn buildWithNulls(
        gpa: std.mem.Allocator,
        cols: []const Column,
        rows: []const []Value,
        nulls: []const ?[]const u8,
    ) !*Table {
        return self_build(gpa, cols, rows, nulls);
    }
    fn self_build(gpa: std.mem.Allocator, cols: []const Column, rows: []const []Value, nulls: ?[]const ?[]const u8) !*Table {
        return self_build2(gpa, cols, rows, nulls, false);
    }
    fn self_build2(
        gpa: std.mem.Allocator,
        cols: []const Column,
        rows: []const []Value,
        nulls: ?[]const ?[]const u8,
        skip_enc: bool,
    ) !*Table {
        const t = try gpa.create(Table);
        errdefer gpa.destroy(t);
        t.* = .{
            .nrows = rows.len,
            .cols = &.{},
            .data = &.{},
            .enc = &.{},
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        const a = t.arena.allocator();
        t.cols = try a.alloc(Column, cols.len);
        t.data = try a.alloc(Data, cols.len);
        t.enc = try a.alloc(?Encoding, cols.len);
        @memset(t.enc, null);
        t.valid = try a.alloc(?[]u8, cols.len);
        @memset(t.valid, null);
        @memcpy(t.cols, cols);
        for (cols, 0..) |c, ci| {
            _ = c;
            const words = (rows.len + 7) / 8;
            if (nulls) |nz| {
                if (ci < nz.len) {
                    if (nz[ci]) |bits| {
                        const flags = try a.alloc(u8, words);
                        @memset(flags, 0xff);
                        const n = @min(bits.len, words);
                        @memcpy(flags[0..n], bits[0..n]);
                        t.valid[ci] = flags;
                        continue;
                    }
                }
            }
            var has_null = false;
            for (rows) |row| {
                if (row[ci] == .null) {
                    has_null = true;
                    break;
                }
            }
            if (!has_null) continue;
            const flags = try a.alloc(u8, words);
            @memset(flags, 0);
            for (rows, 0..) |row, ri| {
                if (row[ci] != .null) flags[ri / 8] |= @as(u8, 1) << @intCast(ri % 8);
            }
            t.valid[ci] = flags;
        }
        for (cols, 0..) |c, ci| {
            switch (c.kind) {
                .int => {
                    const arr = try a.alloc(i64, rows.len);
                    for (rows, 0..) |row, ri| arr[ri] = asInt(row[ci]);
                    t.data[ci] = .{ .ints = arr };
                },
                .float => {
                    const arr = try a.alloc(f64, rows.len);
                    for (rows, 0..) |row, ri| arr[ri] = asFloat(row[ci]);
                    t.data[ci] = .{ .floats = arr };
                },
                .str => {
                    const offsets = try a.alloc(u32, rows.len + 1);
                    var bytes = std.ArrayList(u8).empty;
                    offsets[0] = 0;
                    for (rows, 0..) |row, ri| {
                        const s = asText(row[ci]);
                        try bytes.appendSlice(a, s);
                        offsets[ri + 1] = @intCast(bytes.items.len);
                    }
                    t.data[ci] = .{ .strs = .{ .offsets = offsets, .bytes = bytes.items } };
                },
            }
        }
        t.heap = gpa;
        t.scratch = &.{};
        t.scratch_used = 0;
        t.stats = try a.alloc(?[]BlockStat, cols.len);
        @memset(t.stats, null);
        for (cols, 0..) |c, ci| {
            if (c.kind != .int) continue;
            try t.computeStats(a, ci);
        }
        if (!skip_enc) try t.buildEncodings(a);
        return t;
    }
    pub fn compactStrings(self: *Table) void {
        const a = self.arena.allocator();
        for (self.cols, 0..) |c, ci| {
            if (c.kind != .str) continue;
            const sd = &self.data[ci].strs;
            if (sd.row_ref == null) continue;
            if (sd.dict_ids.len != 0) continue;
            const off = if (sd.offsets.len > self.nrows) sd.offsets else
                (a.alloc(u32, self.nrows + 1) catch continue);
            off[0] = 0;
            var acc: u64 = 0;
            for (0..self.nrows) |i| {
                acc += sd.row_len.?[i];
                off[i + 1] = @intCast(acc);
            }
            sd.offsets = off;
            sd.bytes = sd.patched;
            sd.bytes_owner = sd.patched_owner;
            sd.bytes_cap = sd.patched_cap;
            sd.offsets_cap = 0;
            if (sd.refs_owner) |o| {
                if (sd.row_ref) |rr| o.free(rr);
                if (sd.row_len) |rl| o.free(rl);
                sd.refs_owner = null;
            }
            sd.row_ref = null;
            sd.row_len = null;
            sd.patched = &.{};
            sd.patched_cap = 0;
            sd.patched_owner = null;
        }
    }
    fn finishDictLoad(self: *Table) !void {
        const a = self.arena.allocator();
        for (0..self.dict_load.len) |ci| {
            const dlp = &self.dict_load[ci];
            if (dlp.* == null) continue;
            const dl = &dlp.*.?;
            const nrows = self.nrows;
            if (dl.ndv == 0) {
                self.data[ci] = .{ .strs = .{ .offsets = &.{}, .bytes = &.{} } };
                dl.deinit();
                dlp.* = null;
                continue;
            }
            const first = try a.alloc(u32, dl.ndv);
            @memset(first, std.math.maxInt(u32));
            for (dl.ids[0..nrows], 0..) |id, ri| {
                if (first[id] == std.math.maxInt(u32)) first[id] = @intCast(ri);
            }
            const counts = try a.alloc(u32, dl.ndv);
            @memset(counts, 0);
            for (dl.ids[0..nrows]) |id| counts[id] += 1;
            var rank: []u32 = &.{};
            var byrank: []u32 = &.{};
            if (dl.ndv <= 100_000 and dl.ndv > 1) {
                const ord_opt: ?[]u32 = a.alloc(u32, dl.ndv) catch null;
                const rk_opt: ?[]u32 = a.alloc(u32, dl.ndv) catch null;
                if (ord_opt != null and rk_opt != null) {
                    const ord = ord_opt.?;
                    const rk = rk_opt.?;
                    for (ord, 0..) |*o, i| o.* = @intCast(i);
                    const Ctx = struct {
                        offs: []const u32,
                        bytes: []const u8,
                        fn less(ctx: @This(), x: u32, y: u32) bool {
                            const sx = ctx.bytes[ctx.offs[x]..ctx.offs[x + 1]];
                            const sy = ctx.bytes[ctx.offs[y]..ctx.offs[y + 1]];
                            return std.mem.order(u8, sx, sy) == .lt;
                        }
                    };
                    std.mem.sort(u32, ord, Ctx{ .offs = dl.offs, .bytes = dl.bytes[0..dl.used] }, Ctx.less);
                    for (ord, 0..) |id, pos| rk[id] = @intCast(pos);
                    rank = rk;
                    byrank = ord;
                }
            }
            self.enc[ci] = .{
                .ids = dl.ids[0..nrows],
                .first = first,
                .rank = rank,
                .byrank = byrank,
                .counts = if (dl.ndv <= 2_000_000) counts else &.{},
            };
            // The loader sized `offs` for every row; the dictionary only needs
            // one offset per distinct value, so shrink it to release the rest.
            var offs: []u32 = dl.offs[0 .. dl.ndv + 1];
            if (dl.offs.len > offs.len) {
                if (a.alloc(u32, offs.len)) |sh| {
                    @memcpy(sh, offs);
                    if (dl.offs.len > 0) self.heap.free(dl.offs.ptr[0..dl.offs.len]);
                    offs = sh;
                } else |_| {}
            }
            // The loader pre-sized the byte buffer from the raw row total; the
            // dictionary is usually smaller. Shrinking in place avoids a copy
            // (and keeps peak RSS down).
            var bytes: []u8 = dl.bytes[0..dl.used];
            if (dl.bytes.len > bytes.len + 65536) {
                if (self.heap.remap(dl.bytes[0..dl.bytes.len], bytes.len)) |nb| bytes = nb;
            }
            self.data[ci] = .{ .strs = .{
                .offsets = offs,
                .bytes = bytes,
                .dict_ids = dl.ids[0..nrows],
            } };
            dl.deinit();
            dlp.* = null;
        }
    }
    pub fn finalizeLoad(self: *Table) !void {
        try self.finishDictLoad();
        self.compactStrings();
        const a = self.arena.allocator();
        for (self.cols, 0..) |c, ci| {
            if (c.kind == .int) try self.computeStats(a, ci);
        }
        try self.buildEncodings(a);
        self.dictEncodeStrings();
        if (self.row_cap > self.nrows) {
            for (self.data) |*d| switch (d.*) {
                .ints => |x| d.* = .{ .ints = x[0..self.nrows] },
                .ints8 => |x| d.* = .{ .ints8 = x[0..self.nrows] },
                .ints16 => |x| d.* = .{ .ints16 = x[0..self.nrows] },
                .ints32 => |x| d.* = .{ .ints32 = x[0..self.nrows] },
                .floats => |x| d.* = .{ .floats = x[0..self.nrows] },
                else => {},
            };
            self.row_cap = self.nrows;
        }
    }
    pub fn dictEncodeStrings(self: *Table) void {
        const a = self.arena.allocator();
        for (self.cols, 0..) |c, ci| {
            if (c.kind != .str) continue;
            if (ci >= self.enc.len) continue;
            const e = self.enc[ci] orelse continue;
            const sd = &self.data[ci].strs;
            if (sd.dict_ids.len != 0 or sd.row_ref != null) continue;
            if (sd.bytes_owner == null) continue; // arena-owned text: cannot free
            const ndv = e.first.len;
            if (ndv == 0 or ndv >= self.nrows or ndv > e.ids.len) continue;
            var total: usize = 0;
            for (e.first) |row| total += sd.at(row).len;
            const row_cost = sd.bytes.len + (self.nrows + 1) * 4;
            const dict_cost = total + (ndv + 1) * 4;
            if (dict_cost * 10 > row_cost * 8) continue; // need a clear win
            const buf = a.alloc(u8, total) catch continue;
            const doffs = a.alloc(u32, ndv + 1) catch continue;
            var pos: usize = 0;
            doffs[0] = 0;
            for (e.first, 0..) |row, id| {
                const s = sd.at(row);
                @memcpy(buf[pos .. pos + s.len], s);
                pos += s.len;
                doffs[id + 1] = @intCast(pos);
            }
            if (sd.bytes_owner) |o| {
                if (sd.bytes_cap > 0) o.free(sd.bytes.ptr[0..sd.bytes_cap]);
            }
            if (sd.offsets_owner) |o| {
                if (sd.offsets_cap > 0) o.free(sd.offsets.ptr[0..sd.offsets_cap]);
            }
            sd.offsets = doffs;
            sd.offsets_owner = null;
            sd.offsets_cap = 0;
            sd.bytes_owner = null;
            sd.bytes_cap = 0;
            sd.bytes = buf;
            sd.dict_ids = e.ids;
        }
    }
    pub fn demoteDictStrings(self: *Table) void {
        if (self.data.len == 0) return;
        const a = self.arena.allocator();
        for (self.cols, 0..) |c, ci| {
            if (c.kind != .str) continue;
            const sd = &self.data[ci].strs;
            if (sd.dict_ids.len == 0) continue;
            const offs = a.alloc(u32, self.nrows + 1) catch return;
            var total: usize = 0;
            for (0..self.nrows) |i| total += sd.at(i).len;
            const buf = a.alloc(u8, total) catch return;
            var pos: usize = 0;
            offs[0] = 0;
            for (0..self.nrows) |i| {
                const s = sd.at(i);
                @memcpy(buf[pos .. pos + s.len], s);
                pos += s.len;
                offs[i + 1] = @intCast(pos);
            }
            sd.offsets = offs;
            sd.offsets_owner = null;
            sd.offsets_cap = 0;
            sd.bytes = buf;
            sd.bytes_owner = null;
            sd.bytes_cap = 0;
            sd.dict_ids = &.{};
        }
    }
    pub fn isDeleted(self: *const Table, ri: usize) bool {
        const tb = self.tomb orelse return false;
        return (tb[ri / 8] >> @intCast(ri % 8)) & 1 != 0;
    }
    pub fn anyDeleted(self: *const Table) bool {
        const tb = self.tomb orelse return false;
        for (tb) |b| {
            if (b != 0) return true;
        }
        return false;
    }
    pub fn isNull(self: *const Table, ci: usize, ri: usize) bool {
        if (self.valid.len <= ci) return false;
        const v = self.valid[ci] orelse return false;
        if (ri / 8 >= v.len) return false; // beyond the bitmap = present
        return (v[ri / 8] >> @intCast(ri % 8)) & 1 == 0;
    }
    fn encMapFor(self: *Table, a: std.mem.Allocator, ci: usize) ?*std.StringHashMap(u32) {
        if (self.enc_maps.len != self.cols.len) {
            self.enc_maps = a.alloc(?std.StringHashMap(u32), self.cols.len) catch return null;
            for (self.enc_maps) |*m| m.* = null;
        }
        if (self.enc_maps[ci] == null) {
            const e = self.enc[ci] orelse return null;
            var m = std.StringHashMap(u32).init(a);
            for (e.first, 0..) |first_row, id| {
                m.put(self.data[ci].strs.at(first_row), @intCast(id)) catch return null;
            }
            self.enc_maps[ci] = m;
        }
        return &self.enc_maps[ci].?;
    }
    pub fn padRows(self: *Table, a: std.mem.Allocator, target: usize) bool {
        if (self.nrows >= target) return true;
        const blank = a.alloc(Value, self.cols.len) catch return false;
        defer a.free(blank);
        for (blank) |*c| c.* = .{ .int = 0 };
        while (self.nrows < target) {
            const ri = self.nrows;
            if (!self.appendRow(a, blank)) return false;
            self.setTomb(a, ri, true) catch return false;
        }
        return true;
    }
    pub fn appendRow(self: *Table, a: std.mem.Allocator, vals: []const Value) bool {
        if (self.data.len == 0) return false;
        if (self.dict_load.len == 0) self.demoteDictStrings();
        const need = self.nrows + 1;
        if (need > self.row_cap) {
            const newcap = @max(need, @max(1024, self.row_cap + self.row_cap / 2));
            for (self.data) |*slot| {
                switch (slot.*) {
                    .ints => |old| {
                        const nb = a.alloc(i64, newcap) catch return false;
                        @memcpy(nb[0..old.len], old);
                        slot.* = .{ .ints = nb };
                    },
                    .ints8 => |old| {
                        const nb = a.alloc(i8, newcap) catch return false;
                        @memcpy(nb[0..old.len], old);
                        slot.* = .{ .ints8 = nb };
                    },
                    .ints16 => |old| {
                        const nb = a.alloc(i16, newcap) catch return false;
                        @memcpy(nb[0..old.len], old);
                        slot.* = .{ .ints16 = nb };
                    },
                    .ints32 => |old| {
                        const nb = a.alloc(i32, newcap) catch return false;
                        @memcpy(nb[0..old.len], old);
                        slot.* = .{ .ints32 = nb };
                    },
                    .floats => |old| {
                        const nb = a.alloc(f64, newcap) catch return false;
                        @memcpy(nb[0..old.len], old);
                        slot.* = .{ .floats = nb };
                    },
                    .strs => |*sd| {
                        const no = a.alloc(u32, newcap + 1) catch return false;
                        @memcpy(no[0 .. sd.offsets.len], sd.offsets);
                        var rr = sd.row_ref orelse blk: {
                            const nr0 = a.alloc(u32, newcap) catch return false;
                            @memset(nr0, str_none);
                            break :blk nr0;
                        };
                        var rl = sd.row_len orelse blk: {
                            const nl0 = a.alloc(u32, newcap) catch return false;
                            @memset(nl0, 0);
                            break :blk nl0;
                        };
                        if (rr.len < newcap) {
                            const nr = a.alloc(u32, newcap) catch return false;
                            @memcpy(nr[0..rr.len], rr);
                            @memset(nr[rr.len..], str_none);
                            rr = nr;
                            const nl = a.alloc(u32, newcap) catch return false;
                            @memcpy(nl[0..rl.len], rl);
                            @memset(nl[rl.len..], 0);
                            rl = nl;
                        }
                        sd.offsets = no;
                        sd.row_ref = rr;
                        sd.row_len = rl;
                    },
                }
            }
            self.row_cap = newcap;
        }
        const ri = self.nrows;
        for (self.data, 0..) |*slot, ci| {
            const v: Value = if (ci < vals.len) vals[ci] else Value{ .int = 0 };
            switch (slot.*) {
                .ints => |arr| arr[ri] = switch (v) {
                    .int => |x| x,
                    .boolean => |b| if (b) 1 else 0,
                    .float => |f| @intFromFloat(f),
                    else => 0,
                },
                .ints8 => |arr| arr[ri] = @intCast(std.math.clamp(intOf(v), -128, 127)),
                .ints16 => |arr| arr[ri] = @intCast(std.math.clamp(intOf(v), -32768, 32767)),
                .ints32 => |arr| arr[ri] = @intCast(std.math.clamp(intOf(v), std.math.minInt(i32), std.math.maxInt(i32))),
                .floats => |arr| arr[ri] = switch (v) {
                    .float => |f| f,
                    .int => |x| @floatFromInt(x),
                    else => 0,
                },
                .strs => |*sd| {
                    const text: []const u8 = switch (v) {
                        .text => |t| t,
                        else => "",
                    };
                    if (self.dict_load.len > ci) {
                        if (self.dict_load[ci]) |*dl| {
                            dl.ids[ri] = dl.intern(text) catch return false;
                            continue;
                        }
                    }
                    if (!sd.patchAtOwner(a, self.heap, ri, text, self.row_cap)) return false;
                    if (self.enc[ci]) |*e| {
                        if (e.ids.len < self.row_cap) {
                            const ni = a.alloc(u32, self.row_cap) catch return false;
                            @memcpy(ni[0..e.ids.len], e.ids);
                            e.ids = ni;
                        }
                        if (self.encMapFor(a, ci)) |m| {
                            const gop = m.getOrPut(text) catch return false;
                            if (!gop.found_existing) {
                                gop.value_ptr.* = @intCast(e.first.len);
                                const nf = a.alloc(u32, e.first.len + 1) catch return false;
                                @memcpy(nf[0..e.first.len], e.first);
                                nf[e.first.len] = @intCast(ri);
                                e.first = nf;
                                if (e.rank.len > 0) {
                                    const dim = e.first.len;
                                    const new_id = dim - 1;
                                    var pos: u32 = 0;
                                    for (0..new_id) |id| {
                                        const prev = self.data[ci].strs.at(e.first[id]);
                                        if (std.mem.order(u8, prev, text) == .lt) pos += 1;
                                    }
                                    const nr = a.alloc(u32, dim) catch return false;
                                    for (0..new_id) |id| {
                                        const r = e.rank[id];
                                        nr[id] = if (r >= pos) r + 1 else r;
                                    }
                                    nr[new_id] = pos;
                                    e.rank = nr;
                                }
                            }
                            e.ids[ri] = gop.value_ptr.*;
                        }
                    }
                },
            }
        }
        self.nrows = need;
        for (self.valid, 0..) |maybe, ci| {
            if (maybe == null and ci < vals.len and vals[ci] == .null) {
                const words = (self.nrows + 7) / 8;
                const nb = a.alloc(u8, words) catch return false;
                @memset(nb, 0xff);
                self.valid[ci] = nb;
            }
            if (self.valid[ci]) |bits| {
                const words = (self.nrows + 7) / 8;
                const is_null = ci < vals.len and vals[ci] == .null;
                if (bits.len < words) {
                    const nb = a.alloc(u8, words) catch return false;
                    @memset(nb, 0xff);
                    @memcpy(nb[0..bits.len], bits);
                    self.valid[ci] = nb;
                }
                const dst = self.valid[ci].?;
                if (is_null) {
                    dst[ri / 8] &= ~(@as(u8, 1) << @intCast(ri % 8));
                } else {
                    dst[ri / 8] |= @as(u8, 1) << @intCast(ri % 8);
                }
            }
        }
        if (self.tomb) |tb| {
            const words = (self.nrows + 7) / 8;
            if (tb.len < words) {
                const nb = a.alloc(u8, words) catch return false;
                @memset(nb, 0);
                @memcpy(nb[0..tb.len], tb);
                self.tomb = nb;
            }
        }
        for (0..self.cols.len) |ci| {
            if (ci >= self.stats.len) continue;
            if (self.stats[ci] == null) continue;
            if (!self.data[ci].isInt()) continue;
            const nb = (self.nrows + self.block_rows - 1) / self.block_rows;
            const st = self.stats[ci].?;
            if (st.len < nb) {
                const ns = a.alloc(BlockStat, nb) catch return false;
                @memcpy(ns[0..st.len], st);
                self.stats[ci] = ns;
            }
            self.refreshBlockStats(ci, ri);
        }
        for (self.keyidx, 0..) |maybe, ci| {
            const idx = maybe orelse continue;
            if (idx.tree) |*tr| {
                if (ci < vals.len and vals[ci] == .int) {
                    tr.insert(vals[ci].int, @intCast(ri)) catch return false;
                }
            }
        }
        return true;
    }
    pub fn dropPatches(self: *Table) usize {
        var freed: usize = 0;
        for (self.data) |*slot| {
            switch (slot.*) {
                .strs => |*sd| {
                    if (sd.patched_owner) |o| {
                        if (sd.patched_cap > 0) {
                            o.free(sd.patched.ptr[0..sd.patched_cap]);
                            freed += sd.patched_cap;
                        }
                    }
                    if (sd.bytes_owner) |o| {
                        if (sd.bytes.len > 0) {
                            o.free(sd.bytes.ptr[0..sd.bytes.len]);
                            freed += sd.bytes.len;
                            sd.bytes = &.{};
                        }
                        sd.bytes_owner = null;
                    }
                    sd.patched = &.{};
                    sd.patched_cap = 0;
                    sd.patched_owner = null;
                    if (sd.refs_owner) |o| {
                        if (sd.row_ref) |rr| o.free(rr);
                        if (sd.row_len) |rl| o.free(rl);
                        sd.refs_owner = null;
                    }
                    sd.row_ref = null;
                    sd.row_len = null;
                },
                else => {},
            }
        }
        return freed;
    }
    pub fn truncateRows(self: *Table, nrows: usize) void {
        if (nrows >= self.nrows) return;
        self.nrows = nrows;
        if (self.tomb) |tb| {
            var i = nrows;
            const words = (self.row_cap + 7) / 8;
            while (i < words * 8) : (i += 1) {
                if (i / 8 < tb.len) tb[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
            }
        }
        for (0..self.cols.len) |ci| {
            if (ci >= self.stats.len) continue;
            if (self.stats[ci] == null) continue;
            if (!self.data[ci].isInt()) continue;
            const nb = (self.nrows + self.block_rows - 1) / self.block_rows;
            if (self.stats[ci].?.len > nb) {
                const st = self.stats[ci].?;
                self.stats[ci] = st[0..nb];
            }
            if (nb > 0) self.refreshBlockStats(ci, nrows - 1);
        }
    }
    pub fn putDeltaValue(self: *Table, a: std.mem.Allocator, ci: usize, ri: usize, v: Value) bool {
        if (ri >= self.nrows or ci >= self.data.len) return false;
        if (self.data[ci].isInt() and self.data[ci].i64Slice() == null) {
            if (!self.widenIntColumn(a, ci)) return false;
        }
        switch (self.data[ci]) {
            .ints => |arr| arr[ri] = switch (v) {
                .int => |x| x,
                .boolean => |b| if (b) 1 else 0,
                .float => |f| @intFromFloat(f),
                else => 0,
            },
            .ints8, .ints16, .ints32 => {
                if (!self.widenIntColumn(a, ci)) return false;
                self.data[ci].ints[ri] = intOf(v);
            },
            .floats => |arr| arr[ri] = switch (v) {
                .float => |f| f,
                .int => |x| @floatFromInt(x),
                else => 0,
            },
            .strs => |*sd| {
                const txt: []const u8 = switch (v) {
                    .text => |t| t,
                    else => "",
                };
                if (!sd.patchAtOwner(a, self.heap, ri, txt, self.nrows)) return false;
                self.enc[ci] = null;
            },
        }
        if (ci < self.valid.len) {
            if (self.valid[ci] == null and v == .null) {
                const words = (self.nrows + 7) / 8;
                const bits = a.alloc(u8, words) catch return false;
                @memset(bits, 0xff);
                bits[ri / 8] &= ~(@as(u8, 1) << @intCast(ri % 8));
                self.valid[ci] = bits;
            }
            if (self.valid[ci]) |bits| {
                if (v == .null) {
                    bits[ri / 8] &= ~(@as(u8, 1) << @intCast(ri % 8));
                } else {
                    bits[ri / 8] |= @as(u8, 1) << @intCast(ri % 8);
                }
            }
        }
        self.refreshBlockStats(ci, ri);
        return true;
    }
    pub fn applyDeltas(self: *Table, a: std.mem.Allocator, bytes: []const u8) !usize {
        var pos: usize = 0;
        var applied: usize = 0;
        while (pos + 12 <= bytes.len) {
            if (!std.mem.eql(u8, bytes[pos .. pos + 4], delta_magic)) break;
            pos += 4;
            const ver = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            pos += 4;
            if (ver != 1) return error.BadSnapshot;
            const n: usize = @intCast(std.mem.readInt(u32, bytes[pos..][0..4], .little));
            pos += 4;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (pos + 5 > bytes.len) return error.BadSnapshot;
                const ri: usize = @intCast(std.mem.readInt(u32, bytes[pos..][0..4], .little));
                pos += 4;
                const deleted = bytes[pos] != 0;
                pos += 1;
                if (ri > self.nrows) return error.BadSnapshot;
                const vals = try a.alloc(Value, self.cols.len);
                defer a.free(vals);
                for (0..self.cols.len) |ci| {
                    if (pos >= bytes.len) return error.BadSnapshot;
                    const tag = bytes[pos];
                    pos += 1;
                    switch (tag) {
                        D_NULL => vals[ci] = .null,
                        D_INT => {
                            if (pos + 8 > bytes.len) return error.BadSnapshot;
                            vals[ci] = .{ .int = std.mem.readInt(i64, bytes[pos..][0..8], .little) };
                            pos += 8;
                        },
                        D_FLOAT => {
                            if (pos + 8 > bytes.len) return error.BadSnapshot;
                            const raw = std.mem.readInt(u64, bytes[pos..][0..8], .little);
                            vals[ci] = .{ .float = @bitCast(raw) };
                            pos += 8;
                        },
                        D_TEXT => {
                            if (pos + 4 > bytes.len) return error.BadSnapshot;
                            const len: usize = @intCast(std.mem.readInt(u32, bytes[pos..][0..4], .little));
                            pos += 4;
                            if (pos + len > bytes.len) return error.BadSnapshot;
                            vals[ci] = .{ .text = bytes[pos .. pos + len] };
                            pos += len;
                        },
                        else => return error.BadSnapshot,
                    }
                }
                if (ri == self.nrows) {
                    if (!self.appendRow(a, vals)) return error.BadSnapshot;
                } else {
                    for (0..self.cols.len) |ci| _ = self.putDeltaValue(a, ci, ri, vals[ci]);
                }
                try self.setTomb(a, ri, deleted);
                applied += 1;
            }
        }
        return applied;
    }
    pub fn appendDelta(self: *Table, alloc: std.mem.Allocator, rows: []const u32, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(alloc, delta_magic);
        try appendBytes(out, alloc, &@as(u32, 1));
        try appendBytes(out, alloc, &@as(u32, @intCast(rows.len)));
        for (rows) |ri| {
            if (ri >= self.nrows) continue;
            try appendBytes(out, alloc, &ri);
            var deleted: u8 = 0;
            if (self.tomb != null and self.isDeleted(ri)) deleted = 1;
            try out.append(alloc, deleted);
            for (0..self.cols.len) |ci| {
                if (self.isNull(ci, ri)) {
                    try out.append(alloc, D_NULL);
                    continue;
                }
                switch (self.data[ci]) {
                    .ints, .ints8, .ints16, .ints32 => {
                        var iv = self.data[ci].intAt(ri);
                        try out.append(alloc, D_INT);
                        try appendBytes(out, alloc, &iv);
                    },
                    .floats => |arr| {
                        try out.append(alloc, D_FLOAT);
                        try appendBytes(out, alloc, &arr[ri]);
                    },
                    .strs => |sd| {
                        const txt = sd.at(ri);
                        try out.append(alloc, D_TEXT);
                        try appendBytes(out, alloc, &@as(u32, @intCast(txt.len)));
                        try out.appendSlice(alloc, txt);
                    },
                }
            }
        }
    }
    pub fn patchRow(self: *Table, ri: usize, vals: []const Value) bool {
        if (ri >= self.nrows) return false;
        const a = self.arena.allocator();
        for (self.data, 0..) |*slot, ci| {
            const v: Value = if (ci < vals.len) vals[ci] else Value{ .int = 0 };
            switch (slot.*) {
                .ints => |arr| arr[ri] = switch (v) {
                    .int => |x| x,
                    .boolean => |b| if (b) 1 else 0,
                    .float => |f| @intFromFloat(f),
                    else => 0,
                },
                .ints8 => |arr| arr[ri] = @intCast(std.math.clamp(intOf(v), -128, 127)),
                .ints16 => |arr| arr[ri] = @intCast(std.math.clamp(intOf(v), -32768, 32767)),
                .ints32 => |arr| arr[ri] = @intCast(std.math.clamp(intOf(v), std.math.minInt(i32), std.math.maxInt(i32))),
                .floats => |arr| arr[ri] = switch (v) {
                    .float => |f| f,
                    .int => |x| @floatFromInt(x),
                    else => 0,
                },
                .strs => |*sd| {
                    const text: []const u8 = switch (v) {
                        .text => |t| t,
                        else => "",
                    };
                    if (!sd.patchAtOwner(a, self.heap, ri, text, self.nrows)) return false;
                    self.enc[ci] = null;
                },
            }
            if (ci < self.valid.len) {
                const words = (self.nrows + 7) / 8;
                if (self.valid[ci] == null and v == .null) {
                    const bits = a.alloc(u8, words) catch return false;
                    @memset(bits, 0xff);
                    self.valid[ci] = bits;
                }
                if (self.valid[ci]) |bits| {
                    if (bits.len < words) {
                        const nb = a.alloc(u8, words) catch return false;
                        @memset(nb, 0xff);
                        @memcpy(nb[0..bits.len], bits);
                        self.valid[ci] = nb;
                    }
                    const dst = self.valid[ci].?;
                    if (v == .null) {
                        dst[ri / 8] &= ~(@as(u8, 1) << @intCast(ri % 8));
                    } else {
                        dst[ri / 8] |= @as(u8, 1) << @intCast(ri % 8);
                    }
                }
            }
        }
        return true;
    }
    pub fn refreshBlockStats(self: *Table, ci: usize, ri: usize) void {
        if (!self.data[ci].isInt()) return;
        if (ci >= self.stats.len) return;
        const st = self.stats[ci] orelse return;
        const b = ri / self.block_rows;
        if (b >= st.len) return;
        const r0 = b * self.block_rows;
        const r1 = @min(r0 + self.block_rows, self.nrows);
        var mn = self.data[ci].intAt(r0);
        var mx = mn;
        var i = r0 + 1;
        while (i < r1) : (i += 1) {
            const v = self.data[ci].intAt(i);
            mn = @min(mn, v);
            mx = @max(mx, v);
        }
        st[b] = .{ .min = mn, .max = mx };
    }
    pub fn requestPairNdv(self: *Table, a: std.mem.Allocator, ca: usize, cb: usize) usize {
        _ = a;
        if (ca >= 65535 or cb >= 65535) return 0;
        for (self.pair_ndv) |p| {
            if (p.a == ca and p.b == cb) return p.ndv;
        }
        for (self.pair_req) |p| {
            if (p.a == ca and p.b == cb) return 0;
        }
        const grown = self.arena.allocator().alloc(PairNdv, self.pair_req.len + 1) catch return 0;
        @memcpy(grown[0..self.pair_req.len], self.pair_req);
        grown[self.pair_req.len] = .{ .a = @intCast(ca), .b = @intCast(cb), .ndv = 0 };
        self.pair_req = grown;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] pair_ndv request c{d},c{d}\n", .{ ca, cb });
        }
        return 0;
    }
    pub fn pairNdvOf(self: *Table, a: std.mem.Allocator, ca: usize, cb: usize) usize {
        for (self.pair_ndv) |p| {
            if (p.a == ca and p.b == cb) return p.ndv;
        }
        if (!self.data[ca].isInt() or !self.data[cb].isInt()) return 0;
        const va = &self.data[ca];
        const vb = &self.data[cb];
        var seen = std.AutoHashMap(u64, void).init(a);
        defer seen.deinit();
        var step: usize = @max(1, self.nrows / 20000);
        if (step > 1 and step % 2 == 0) step += 1; // avoid aliasing periodic data
        var i: usize = 0;
        while (i < self.nrows) : (i += step) {
            const key: u64 = @as(u64, @bitCast(va.intAt(i))) *% 0x9E3779B97F4A7C15 ^ @as(u64, @bitCast(vb.intAt(i)));
            seen.put(key, {}) catch return 0;
        }
        const ndv: u32 = @intCast(@max(seen.count(), 1));
        const grown = self.arena.allocator().alloc(PairNdv, self.pair_ndv.len + 1) catch return ndv;
        @memcpy(grown[0..self.pair_ndv.len], self.pair_ndv);
        grown[self.pair_ndv.len] = .{ .a = @intCast(ca), .b = @intCast(cb), .ndv = ndv };
        self.pair_ndv = grown;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] pair_ndv c{d},c{d} -> {d}\n", .{ ca, cb, ndv });
        }
        return ndv;
    }
    fn order3(a: usize, b: usize, c: usize) [3]u16 {
        var v = [3]usize{ a, b, c };
        if (v[0] > v[1]) std.mem.swap(usize, &v[0], &v[1]);
        if (v[1] > v[2]) std.mem.swap(usize, &v[1], &v[2]);
        if (v[0] > v[1]) std.mem.swap(usize, &v[0], &v[1]);
        return .{ @intCast(v[0]), @intCast(v[1]), @intCast(v[2]) };
    }
    pub fn requestTripleNdv(self: *Table, a: std.mem.Allocator, ca: usize, cb: usize, cc: usize) usize {
        _ = a;
        const k = order3(ca, cb, cc);
        for (self.triple_ndv) |t| {
            if (t.a == k[0] and t.b == k[1] and t.c == k[2]) return t.ndv;
        }
        for (self.triple_req) |t| {
            if (t.a == k[0] and t.b == k[1] and t.c == k[2]) return 0;
        }
        const grown = self.arena.allocator().alloc(TupleNdv, self.triple_req.len + 1) catch return 0;
        @memcpy(grown[0..self.triple_req.len], self.triple_req);
        grown[self.triple_req.len] = .{ .a = k[0], .b = k[1], .c = k[2], .ndv = 0 };
        self.triple_req = grown;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] triple_ndv request c{d},c{d},c{d}\n", .{ k[0], k[1], k[2] });
        }
        return 0;
    }
    pub fn tripleNdvOf(self: *Table, a: std.mem.Allocator, ca: usize, cb: usize, cc: usize) usize {
        const k = order3(ca, cb, cc);
        for (self.triple_ndv) |t| {
            if (t.a == k[0] and t.b == k[1] and t.c == k[2]) return t.ndv;
        }
        if (!self.data[ca].isInt() or !self.data[cb].isInt() or !self.data[cc].isInt()) return 0;
        const va = &self.data[ca];
        const vb = &self.data[cb];
        const vc = &self.data[cc];
        var seen = std.AutoHashMap(u64, void).init(a);
        defer seen.deinit();
        var step: usize = @max(1, self.nrows / 20000);
        if (step > 1 and step % 2 == 0) step += 1; // avoid aliasing periodic data
        var i: usize = 0;
        while (i < self.nrows) : (i += step) {
            const h1: u64 = @as(u64, @bitCast(va.intAt(i))) *% 0x9E3779B97F4A7C15;
            const h2: u64 = @as(u64, @bitCast(vb.intAt(i))) *% 0xC2B2AE3D27D4EB4F;
            const h3: u64 = @as(u64, @bitCast(vc.intAt(i)));
            seen.put(h1 ^ std.math.rotl(u64, h2, 17) ^ h3, {}) catch return 0;
        }
        const ndv: u32 = @intCast(@max(seen.count(), 1));
        const grown = self.arena.allocator().alloc(TupleNdv, self.triple_ndv.len + 1) catch return ndv;
        @memcpy(grown[0..self.triple_ndv.len], self.triple_ndv);
        grown[self.triple_ndv.len] = .{ .a = k[0], .b = k[1], .c = k[2], .ndv = ndv };
        self.triple_ndv = grown;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] triple_ndv c{d},c{d},c{d} -> {d}\n", .{ k[0], k[1], k[2], ndv });
        }
        return ndv;
    }
    fn sortedSet(cols: []const usize) MultiNdv {
        var out = MultiNdv{ .n = @intCast(@min(cols.len, 32)) };
        for (cols[0..out.n], 0..) |c, i| out.cols[i] = @intCast(c);
        var i: usize = 1;
        while (i < out.n) : (i += 1) {
            const v = out.cols[i];
            var j = i;
            while (j > 0 and out.cols[j - 1] > v) : (j -= 1) out.cols[j] = out.cols[j - 1];
            out.cols[j] = v;
        }
        return out;
    }
    fn sameSet(a: MultiNdv, b: MultiNdv) bool {
        if (a.n != b.n) return false;
        for (a.cols[0..a.n], b.cols[0..b.n]) |x, y| {
            if (x != y) return false;
        }
        return true;
    }
    pub fn requestMultiNdv(self: *Table, a: std.mem.Allocator, cols: []const usize) usize {
        _ = a;
        if (cols.len < 2 or cols.len > 32) return 0;
        const key = sortedSet(cols);
        for (self.multi_ndv) |m| {
            if (sameSet(m, key)) return m.ndv;
        }
        for (self.multi_req) |m| {
            if (sameSet(m, key)) return 0;
        }
        const grown = self.arena.allocator().alloc(MultiNdv, self.multi_req.len + 1) catch return 0;
        @memcpy(grown[0..self.multi_req.len], self.multi_req);
        grown[self.multi_req.len] = key;
        self.multi_req = grown;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] multi_ndv request", .{});
            for (key.cols[0..key.n]) |c| std.debug.print(" c{d}", .{c});
            std.debug.print("\n", .{});
        }
        return 0;
    }
    pub fn multiNdvOf(self: *Table, a: std.mem.Allocator, cols: []const usize) usize {
        if (cols.len < 2 or cols.len > 32) return 0;
        const key = sortedSet(cols);
        for (self.multi_ndv) |m| {
            if (sameSet(m, key)) return m.ndv;
        }
        for (key.cols[0..key.n]) |c| {
            if (!self.data[c].isInt()) return 0;
        }
        var seen = std.AutoHashMap(u64, void).init(a);
        defer seen.deinit();
        var step: usize = @max(1, self.nrows / 20000);
        if (step > 1 and step % 2 == 0) step += 1; // avoid aliasing periodic data
        var ri: usize = 0;
        while (ri < self.nrows) : (ri += step) {
            var h: u64 = 0x9E3779B97F4A7C15;
            for (key.cols[0..key.n]) |c| {
                const v: u64 = @bitCast(self.data[c].intAt(ri));
                h = (h ^ v) *% 0x100000001B3;
                h ^= h >> 29;
            }
            seen.put(h, {}) catch return 0;
        }
        const ndv: u32 = @intCast(@max(seen.count(), 1));
        const grown = self.arena.allocator().alloc(MultiNdv, self.multi_ndv.len + 1) catch return ndv;
        @memcpy(grown[0..self.multi_ndv.len], self.multi_ndv);
        var rec = key;
        rec.ndv = ndv;
        grown[self.multi_ndv.len] = rec;
        self.multi_ndv = grown;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] multi_ndv", .{});
            for (key.cols[0..key.n]) |c| std.debug.print(" c{d}", .{c});
            std.debug.print(" -> {d}\n", .{ndv});
        }
        return ndv;
    }
    pub fn setTomb(self: *Table, a: std.mem.Allocator, ri: usize, deleted: bool) !void {
        if (ri >= self.nrows) return;
        if (self.tomb == null) {
            if (!deleted) return;
            const words = (self.nrows + 7) / 8;
            const bits = try a.alloc(u8, words);
            @memset(bits, 0);
            self.tomb = bits;
        }
        const tb = self.tomb.?;
        if (deleted) {
            tb[ri / 8] |= @as(u8, 1) << @intCast(ri % 8);
        } else {
            tb[ri / 8] &= ~(@as(u8, 1) << @intCast(ri % 8));
        }
    }
    pub fn computeStats(self: *Table, a: std.mem.Allocator, ci: usize) !void {
        if (!self.data[ci].isInt()) return;
        const nb = (self.nrows + self.block_rows - 1) / self.block_rows;
        if (nb == 0) return;
        const st = try a.alloc(BlockStat, nb);
        var b: usize = 0;
        while (b < nb) : (b += 1) {
            const r0 = b * self.block_rows;
            const r1 = @min(r0 + self.block_rows, self.nrows);
            var mn = self.data[ci].intAt(r0);
            var mx = mn;
            for (r0..r1) |ri2| {
                const v = self.data[ci].intAt(ri2);
                mn = @min(mn, v);
                mx = @max(mx, v);
            }
            st[b] = .{ .min = mn, .max = mx };
        }
        self.stats[ci] = st;
    }
    pub fn buildEncodings(self: *Table, a: std.mem.Allocator) !void {
        for (self.cols, 0..) |c, ci| {
            if (c.kind != .int) continue;
            if (std.c.getenv("ZHDB_NO_INTENC") != null) continue;
            if (ci < self.stats.len) {
                if (self.stats[ci]) |st| {
                    var lo: i64 = std.math.maxInt(i64);
                    var hi: i64 = std.math.minInt(i64);
                    for (st) |b| {
                        lo = @min(lo, b.min);
                        hi = @max(hi, b.max);
                    }
                    const span: u64 = @bitCast(hi -% lo);
                    if (st.len > 0 and span <= 16_384 and std.c.getenv("ZHDB_IDS_ALL") == null) continue;
                }
            }
            const limit: usize = @max(1024, self.nrows / 4);
            const ids = try a.alloc(u32, self.nrows);
            var first = std.ArrayList(u32).empty;
            var map = std.AutoHashMap(i64, u32).init(self.heap);
            defer map.deinit();
            var ok = true;
            for (0..self.nrows) |ri| {
                const gop = try map.getOrPut(self.data[ci].intAt(ri));
                if (!gop.found_existing) {
                    if (first.items.len >= limit) {
                        ok = false;
                        break;
                    }
                    gop.value_ptr.* = @intCast(first.items.len);
                    try first.append(a, @intCast(ri));
                }
                ids[ri] = @intCast(gop.value_ptr.*);
            }
            if (ok) {
                const counts = try a.alloc(u32, first.items.len);
                @memset(counts, 0);
                const has_nulls = self.valid.len > ci and self.valid[ci] != null;
                for (ids, 0..) |id, ri| {
                    if (has_nulls and self.isNull(ci, ri)) continue;
                    counts[@intCast(id)] += 1;
                }
                self.enc[ci] = .{ .ids = ids, .first = first.items, .counts = counts };
            }
        }
        for (self.cols, 0..) |c, ci| {
            if (c.kind != .str) continue;
            if (self.enc[ci] != null) continue; // built by the dictionary loader
            const strs = self.data[ci].strs;
            const ids = try a.alloc(u32, self.nrows);
            var first = std.ArrayList(u32).empty;
            var map = std.StringHashMap(u32).init(self.heap);
            defer map.deinit();
            for (0..self.nrows) |ri| {
                const gop = try map.getOrPut(strs.at(ri));
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(first.items.len);
                    try first.append(a, @intCast(ri));
                }
                ids[ri] = @intCast(gop.value_ptr.*);
            }
            const counts = try a.alloc(u32, first.items.len);
            @memset(counts, 0);
            const has_nulls_s = self.valid.len > ci and self.valid[ci] != null;
            for (ids, 0..) |id, ri| {
                if (has_nulls_s and self.isNull(ci, ri)) continue;
                counts[@intCast(id)] += 1;
            }
            if (first.items.len > 100_000) {
                self.enc[ci] = .{
                    .ids = ids,
                    .first = first.items,
                    .counts = if (first.items.len <= 2_000_000) counts else &.{},
                };
                continue;
            }
            const rank = try a.alloc(u32, first.items.len);
            const ord = try a.alloc(u32, first.items.len);
            for (ord, 0..) |*o, i| o.* = @intCast(i);
            const Ctx = struct {
                strs: StrData,
                first: []const u32,
                fn less(ctx: @This(), x: u32, y: u32) bool {
                    return std.mem.order(u8, ctx.strs.at(ctx.first[x]), ctx.strs.at(ctx.first[y])) == .lt;
                }
            };
            std.mem.sort(u32, ord, Ctx{ .strs = strs, .first = first.items }, Ctx.less);
            for (ord, 0..) |id, pos| rank[id] = @intCast(pos);
            self.enc[ci] = .{ .ids = ids, .first = first.items, .rank = rank, .byrank = ord, .counts = counts };
        }
    }
    const snapshot_block_rows: usize = 8192;
    fn ci_has_nulls(self: *Table, ci: usize) bool {
        if (self.valid.len <= ci) return false;
        return self.valid[ci] != null;
    }
    pub fn compactBlocks(self: *Table, gpa: std.mem.Allocator, map: []const u32) !*Table {
        const dead_mark: u32 = 0xFFFF_FFFF;
        if (map.len != self.nrows) return error.BadRemap;
        var survivors: usize = 0;
        for (map) |nn| {
            if (nn != dead_mark) survivors += 1;
        }
        const br: usize = if (self.block_rows == 0) 8192 else self.block_rows;
        const nblocks = (self.nrows + br - 1) / br;
        var order_ok = true;
        var expect: u32 = 0;
        for (map) |nn| {
            if (nn == dead_mark) continue;
            if (nn != expect) {
                order_ok = false;
                break;
            }
            expect += 1;
        }
        const class = try gpa.alloc(u8, @max(nblocks, 1));
        defer gpa.free(class);
        var copied: usize = 0;
        var rewritten: usize = 0;
        var dropped: usize = 0;
        {
            var b: usize = 0;
            while (b < nblocks) : (b += 1) {
                const r0 = b * br;
                const r1 = @min(r0 + br, self.nrows);
                var dead: usize = 0;
                for (map[r0..r1]) |nn| {
                    if (nn == dead_mark) dead += 1;
                }
                if (dead == 0 and order_ok) {
                    class[b] = 0;
                    copied += 1;
                } else if (dead == r1 - r0) {
                    class[b] = 2;
                    dropped += 1;
                } else {
                    class[b] = 1;
                    rewritten += 1;
                }
            }
        }
        const t = try gpa.create(Table);
        errdefer gpa.destroy(t);
        t.* = .{
            .nrows = survivors,
            .cols = &.{},
            .data = &.{},
            .enc = &.{},
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        errdefer t.arena.deinit();
        const a = t.arena.allocator();
        t.cols = try a.alloc(Column, self.cols.len);
        for (self.cols, 0..) |c, i| t.cols[i] = .{ .name = try a.dupe(u8, c.name), .kind = c.kind };
        t.data = try a.alloc(Data, self.cols.len);
        t.enc = try a.alloc(?Encoding, self.cols.len);
        @memset(t.enc, null);
        t.valid = try a.alloc(?[]u8, self.cols.len);
        @memset(t.valid, null);
        t.block_rows = br;
        t.has_bool = self.has_bool;
        t.has_int2 = self.has_int2;
        t.heap = gpa;
        t.scratch = &.{};
        t.stats = try a.alloc(?[]BlockStat, self.cols.len);
        @memset(t.stats, null);
        var enc_dropped = false;
        for (self.cols, 0..) |c, ci| {
            switch (c.kind) {
                .int => {
                    const out = try a.alloc(i64, survivors);
                    var b: usize = 0;
                    while (b < nblocks) : (b += 1) {
                        const r0 = b * br;
                        const r1 = @min(r0 + br, self.nrows);
                        switch (class[b]) {
                            0 => {
                                for (r0..r1) |ri| out[map[ri]] = self.data[ci].intAt(ri);
                            },
                            2 => {},
                            else => {
                                var ri = r0;
                                while (ri < r1) : (ri += 1) {
                                    const nn = map[ri];
                                    if (nn != dead_mark) out[nn] = self.data[ci].intAt(ri);
                                }
                            },
                        }
                    }
                    t.data[ci] = .{ .ints = out };
                },
                .float => {
                    const old = self.data[ci].floats;
                    const out = try a.alloc(f64, survivors);
                    var b: usize = 0;
                    while (b < nblocks) : (b += 1) {
                        const r0 = b * br;
                        const r1 = @min(r0 + br, self.nrows);
                        switch (class[b]) {
                            0 => @memcpy(out[map[r0]..][0 .. r1 - r0], old[r0..r1]),
                            2 => {},
                            else => {
                                var ri = r0;
                                while (ri < r1) : (ri += 1) {
                                    const nn = map[ri];
                                    if (nn != dead_mark) out[nn] = old[ri];
                                }
                            },
                        }
                    }
                    t.data[ci] = .{ .floats = out };
                },
                .str => {
                    const old_s = self.data[ci].strs;
                    const offsets = try a.alloc(u32, survivors + 1);
                    var bytes = std.ArrayList(u8).empty;
                    offsets[0] = 0;
                    var b: usize = 0;
                    while (b < nblocks) : (b += 1) {
                        const r0 = b * br;
                        const r1 = @min(r0 + br, self.nrows);
                        switch (class[b]) {
                            0 => {
                                const base: usize = map[r0];
                                var k: usize = 0;
                                while (k < r1 - r0) : (k += 1) {
                                    const txt = old_s.at(r0 + k);
                                    offsets[base + k] = @intCast(bytes.items.len);
                                    try bytes.appendSlice(a, txt);
                                    offsets[base + k + 1] = @intCast(bytes.items.len);
                                }
                            },
                            2 => {},
                            else => {
                                var ri = r0;
                                while (ri < r1) : (ri += 1) {
                                    const nn = map[ri];
                                    if (nn == dead_mark) continue;
                                    const txt = old_s.at(ri);
                                    offsets[nn] = @intCast(bytes.items.len);
                                    try bytes.appendSlice(a, txt);
                                    offsets[nn + 1] = @intCast(bytes.items.len);
                                }
                            },
                        }
                    }
                    if (bytes.items.len != offsets[survivors]) return error.BadRemap;
                    t.data[ci] = .{ .strs = .{ .offsets = offsets, .bytes = bytes.items } };
                },
            }
            if (c.kind == .int) try t.computeStats(a, ci);
            if (self.valid.len > ci) {
                if (self.valid[ci]) |vb| {
                    const words = (survivors + 7) / 8;
                    const outb = try a.alloc(u8, words);
                    @memset(outb, 0);
                    var b: usize = 0;
                    while (b < nblocks) : (b += 1) {
                        if (class[b] == 2) continue;
                        const r0 = b * br;
                        const r1 = @min(r0 + br, self.nrows);
                        var ri = r0;
                        while (ri < r1) : (ri += 1) {
                            const nn = map[ri];
                            if (nn == dead_mark) continue;
                            if ((vb[ri / 8] >> @intCast(ri % 8)) & 1 != 0) {
                                outb[nn / 8] |= @as(u8, 1) << @intCast(nn % 8);
                            }
                        }
                    }
                    t.valid[ci] = outb;
                }
            }
            if (self.enc[ci]) |e| {
                const old = e.ids;
                const ids = try a.alloc(u32, survivors);
                var b: usize = 0;
                while (b < nblocks) : (b += 1) {
                    const r0 = b * br;
                    const r1 = @min(r0 + br, self.nrows);
                    switch (class[b]) {
                        0 => @memcpy(ids[map[r0]..][0 .. r1 - r0], old[r0..r1]),
                        2 => {},
                        else => {
                            var ri = r0;
                            while (ri < r1) : (ri += 1) {
                                const nn = map[ri];
                                if (nn != dead_mark) ids[nn] = old[ri];
                            }
                        },
                    }
                }
                const seen = try gpa.alloc(bool, e.first.len);
                defer gpa.free(seen);
                @memset(seen, false);
                const first = try a.alloc(u32, e.first.len);
                var dense = true;
                var w: usize = 0;
                for (ids) |id| {
                    if (id >= e.first.len) {
                        dense = false;
                        break;
                    }
                    const u: usize = id;
                    if (!seen[u]) {
                        seen[u] = true;
                        first[u] = @intCast(w);
                    }
                    w += 1;
                }
                if (dense) {
                    for (seen) |ok| {
                        if (!ok) {
                            dense = false;
                            break;
                        }
                    }
                }
                if (dense) {
                    const counts = try a.alloc(u32, first.len);
                    @memset(counts, 0);
                    const has_nulls_c = t.valid.len > ci and t.valid[ci] != null;
                    for (ids, 0..) |id, ri| {
                        if (has_nulls_c and t.isNull(ci, ri)) continue;
                        counts[@intCast(id)] += 1;
                    }
                    t.enc[ci] = .{
                        .ids = ids,
                        .first = first,
                        .rank = if (e.rank.len > 0) try a.dupe(u32, e.rank) else &.{},
                        .counts = counts,
                    };
                } else {
                    enc_dropped = true;
                }
            }
        }
        if (enc_dropped) try t.buildEncodings(a);
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] block reclaim: blocks_in={d} out_blocks={d} copied={d} rewritten={d} dropped={d} rows={d}->{d}\n", .{
                nblocks, (survivors + br - 1) / br, copied, rewritten, dropped, self.nrows, survivors,
            });
        }
        return t;
    }
    fn appendBytes(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: anytype) !void {
        try out.appendSlice(alloc, std.mem.asBytes(v));
    }
    pub fn save(self: *Table, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try self.saveWithCosts(alloc, out, null);
    }
    pub fn encodeWbTrailer(costs: WbCosts, out: *[trailer_len_v3]u8) void {
        @memcpy(out[0..4], "ZBT1");
        const vals = [8]u64{
            @bitCast(costs.write_ns_byte),
            @bitCast(costs.encode_ns_row),
            @bitCast(costs.replay_ns_row),
            @bitCast(costs.compact_row_ns),
            costs.samples,
            @bitCast(costs.scan_row_ns),
            @bitCast(costs.str_raw_ns),
            @bitCast(costs.str_dict_ns),
        };
        for (vals, 0..) |v, i| std.mem.writeInt(u64, out[4 + i * 8 ..][0..8], v, .little);
    }
    pub fn saveWithCosts(self: *Table, alloc: std.mem.Allocator, out: *std.ArrayList(u8), costs: ?WbCosts) !void {
        try out.appendSlice(alloc, "ZDB1");
        try appendBytes(out, alloc, &@as(u32, 8));
        try appendBytes(out, alloc, &@as(u64, @intCast(self.nrows)));
        try appendBytes(out, alloc, &@as(u32, @intCast(self.cols.len)));
        for (self.cols, 0..) |c, ci| {
            try appendBytes(out, alloc, &@as(u16, @intCast(c.name.len)));
            try out.appendSlice(alloc, c.name);
            const k: u8 = switch (c.kind) {
                .int => 0,
                .float => 1,
                .str => 2,
            };
            try appendBytes(out, alloc, &k);
            const has_nulls: u8 = if (ci_has_nulls(self, ci)) 1 else 0;
            try appendBytes(out, alloc, &has_nulls);
        }
        for (0..self.cols.len) |ci| {
            if (!ci_has_nulls(self, ci)) continue;
            const words = (self.nrows + 7) / 8;
            const buf = try alloc.alloc(u8, words);
            defer alloc.free(buf);
            const flags = self.valid[ci].?;
            @memcpy(buf, flags[0..words]);
            try out.appendSlice(alloc, buf);
        }
        var ci: usize = 0;
        while (ci < self.cols.len) : (ci += 1) {
            const nblocks = (self.nrows + snapshot_block_rows - 1) / snapshot_block_rows;
            try appendBytes(out, alloc, &@as(u32, @intCast(nblocks)));
            var b: usize = 0;
            while (b < nblocks) : (b += 1) {
                const r0 = b * snapshot_block_rows;
                const r1 = @min(r0 + snapshot_block_rows, self.nrows);
                const rows = r1 - r0;
                var mn: i64 = 0;
                var mx: i64 = 0;
                var data = std.ArrayList(u8).empty;
                defer data.deinit(alloc);
                var enc: u8 = 0;
                switch (self.data[ci]) {
                    .ints, .ints8, .ints16, .ints32 => {
                        mn = self.data[ci].intAt(r0);
                        mx = mn;
                        for (r0..r1) |ri2| {
                            const v = self.data[ci].intAt(ri2);
                            mn = @min(mn, v);
                            mx = @max(mx, v);
                        }
                        const du: u64 = @as(u64, @bitCast(mx)) -% @as(u64, @bitCast(mn));
                        const w: u8 = if (du == 0) 0 else @intCast(64 - @clz(du));
                        if (w <= 32) {
                            enc = if (w == 0) 64 else w;
                            if (w > 0) {
                                var acc: u64 = 0;
                                var nbits: u32 = 0;
                                for (r0..r1) |ri2| {
                                    const v = self.data[ci].intAt(ri2);
                                    const d: u64 = @as(u64, @bitCast(v)) -% @as(u64, @bitCast(mn));
                                    acc |= d << @intCast(nbits);
                                    nbits += w;
                                    while (nbits >= 8) {
                                        try data.append(alloc, @truncate(acc));
                                        acc >>= 8;
                                        nbits -= 8;
                                    }
                                }
                                if (nbits > 0) try data.append(alloc, @truncate(acc));
                            }
                        } else {
                            enc = 0;
                            const tmp = try alloc.alloc(i64, r1 - r0);
                            defer alloc.free(tmp);
                            for (r0..r1, 0..) |ri2, k2| tmp[k2] = self.data[ci].intAt(ri2);
                            try data.appendSlice(alloc, std.mem.sliceAsBytes(tmp));
                        }
                    },
                    .floats => |a| {
                        try data.appendSlice(alloc, std.mem.sliceAsBytes(a[r0..r1]));
                    },
                    .strs => |sd| {
                        var block = std.ArrayList(u8).empty;
                        defer block.deinit(alloc);
                        try appendBytes(&data, alloc, &@as(u32, 0));
                        var i: usize = r0;
                        while (i < r1) : (i += 1) {
                            try block.appendSlice(alloc, sd.at(i));
                            try appendBytes(&data, alloc, &@as(u32, @intCast(block.items.len)));
                        }
                        try data.appendSlice(alloc, block.items);
                        if (std.c.getenv("ZHDB_NO_BLKCOMP") == null) {
                            if (lz4.compress(alloc, data.items)) |comp| {
                                defer alloc.free(comp);
                                var roundtrip_ok = false;
                                if (alloc.alloc(u8, data.items.len)) |chk| {
                                    defer alloc.free(chk);
                                    if (lz4.decompress(chk, comp)) |_| {
                                        roundtrip_ok = std.mem.eql(u8, chk, data.items);
                                        if (!roundtrip_ok) std.debug.print("[blkcomp] mismatch (raw={d} comp={d})\n", .{ data.items.len, comp.len });
                                    } else |e| {
                                        std.debug.print("[blkcomp] decode failed: {s} (raw={d} comp={d})\n", .{ @errorName(e), data.items.len, comp.len });
                                    }
                                } else |_| {}
                                if (roundtrip_ok and comp.len + 4 < data.items.len) {
                                    var payload = try alloc.alloc(u8, comp.len + 4);
                                    defer alloc.free(payload);
                                    std.mem.writeInt(u32, payload[0..4], @intCast(data.items.len), .little);
                                    @memcpy(payload[4..], comp);
                                    data.clearRetainingCapacity();
                                    try data.appendSlice(alloc, payload);
                                    enc = 200;
                                }
                            } else |_| {}
                        }
                    },
                }
                try appendBytes(out, alloc, &@as(u32, @intCast(rows)));
                try appendBytes(out, alloc, &mn);
                try appendBytes(out, alloc, &mx);
                try appendBytes(out, alloc, &enc);
                try appendBytes(out, alloc, &@as(u32, @intCast(data.items.len)));
                try out.appendSlice(alloc, data.items);
            }
        }
        if (self.tomb) |tb| {
            try appendBytes(out, alloc, &@as(u8, 1));
            const words = (self.nrows + 7) / 8;
            try appendBytes(out, alloc, &@as(u32, @intCast(words)));
            try out.appendSlice(alloc, tb[0..words]);
        } else {
            try appendBytes(out, alloc, &@as(u8, 0));
        }
        var nidx: u32 = 0;
        if (self.keyidx.len == self.cols.len) {
            for (self.keyidx) |k| {
                if (k != null) nidx += 1;
            }
        }
        try appendBytes(out, alloc, &nidx);
        if (nidx > 0) {
            for (self.keyidx, 0..) |maybe, ci2| {
                const idx = maybe orelse continue;
                try appendBytes(out, alloc, &@as(u32, @intCast(ci2)));
                if (idx.tree) |*tr| {
                    var tb = std.ArrayList(u8).empty;
                    defer tb.deinit(alloc);
                    try tr.serialize(alloc, &tb);
                    try out.appendSlice(alloc, tb.items);
                } else {
                    return error.BadIndex;
                }
            }
        }
        if (costs) |c| {
            var tr: [trailer_len_v3]u8 = undefined;
            Table.encodeWbTrailer(c, &tr);
            try out.appendSlice(alloc, &tr);
        }
    }
    pub fn loadBytes(gpa: std.mem.Allocator, bytes: []const u8) !*Table {
        var pos: usize = 0;
        if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "ZDB1")) return error.BadSnapshot;
        pos = 4;
        const rd = struct {
            fn u32at(b: []const u8, p: *usize) !u32 {
                if (p.* + 4 > b.len) return error.BadSnapshot;
                const v = std.mem.readInt(u32, b[p.*..][0..4], .little);
                p.* += 4;
                return v;
            }
            fn u64at(b: []const u8, p: *usize) !u64 {
                if (p.* + 8 > b.len) return error.BadSnapshot;
                const v = std.mem.readInt(u64, b[p.*..][0..8], .little);
                p.* += 8;
                return v;
            }
        };
        const version = try rd.u32at(bytes, &pos);
        const nrows: usize = @intCast(try rd.u64at(bytes, &pos));
        const ncols: usize = @intCast(try rd.u32at(bytes, &pos));
        const t = try gpa.create(Table);
        errdefer gpa.destroy(t);
        t.* = .{
            .nrows = nrows,
            .cols = &.{},
            .data = &.{},
            .enc = &.{},
            .stats = &.{},
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        const a = t.arena.allocator();
        t.cols = try a.alloc(Column, ncols);
        t.data = try a.alloc(Data, ncols);
        t.enc = try a.alloc(?Encoding, ncols);
        t.stats = try a.alloc(?[]BlockStat, ncols);
        @memset(t.enc, null);
        @memset(t.stats, null);
        var has_nulls = try a.alloc(bool, ncols);
        @memset(has_nulls, false);
        t.valid = try a.alloc(?[]u8, ncols);
        @memset(t.valid, null);
        for (0..ncols) |ci| {
            if (pos + 2 > bytes.len) return error.BadSnapshot;
            const nlen = std.mem.readInt(u16, bytes[pos..][0..2], .little);
            pos += 2;
            if (pos + nlen + 1 > bytes.len) return error.BadSnapshot;
            const name = try a.dupe(u8, bytes[pos .. pos + nlen]);
            pos += nlen;
            const k = bytes[pos];
            pos += 1;
            t.cols[ci] = .{ .name = name, .kind = switch (k) {
                0 => .int,
                1 => .float,
                else => .str,
            } };
            if (version >= 2) {
                if (pos >= bytes.len) return error.BadSnapshot;
                has_nulls[ci] = bytes[pos] != 0;
                pos += 1;
            }
        }
        for (0..ncols) |ci| {
            if (!has_nulls[ci]) continue;
            const words = (nrows + 7) / 8;
            if (pos + words > bytes.len) return error.BadSnapshot;
            const flags = try a.alloc(u8, words);
            @memcpy(flags, bytes[pos .. pos + words]);
            pos += words;
            t.valid[ci] = flags;
        }
        for (0..ncols) |ci| {
            const nblocks: usize = @intCast(try rd.u32at(bytes, &pos));
            switch (t.cols[ci].kind) {
                .int => {
                    const arr = try a.alloc(i64, nrows);
                    const st = try a.alloc(BlockStat, @max(nblocks, 1));
                    var r: usize = 0;
                    var dec = std.ArrayList(u8).empty;
                    defer dec.deinit(gpa);
                    for (0..nblocks) |bi| {
                        const rows: usize = @intCast(try rd.u32at(bytes, &pos));
                        const mn: i64 = @bitCast(try rd.u64at(bytes, &pos));
                        const mx: i64 = @bitCast(try rd.u64at(bytes, &pos));
                        st[bi] = .{ .min = mn, .max = mx };
                        var enc: u8 = 0;
                        if (version >= 3) {
                            if (pos >= bytes.len) return error.BadSnapshot;
                            enc = bytes[pos];
                            pos += 1;
                        }
                        const dlen: usize = @intCast(try rd.u32at(bytes, &pos));
                        if (pos + dlen > bytes.len) return error.BadSnapshot;
                        const src = bytes[pos .. pos + dlen];
                        pos += dlen;
                        if (enc == 200) {
                            if (src.len < 4) return error.BadSnapshot;
                            const ulen: usize = @intCast(std.mem.readInt(u32, src[0..4], .little));
                            if (dec.items.len < ulen) try dec.resize(gpa, ulen);
                            try lz4.decompress(dec.items[0..ulen], src[4..]);
                            if (ulen < rows * 8) return error.BadSnapshot;
                            @memcpy(std.mem.sliceAsBytes(arr[r .. r + rows]), dec.items[0 .. rows * 8]);
                        } else if (enc == 0) {
                            @memcpy(std.mem.sliceAsBytes(arr[r .. r + rows]), src);
                        } else if (enc == 64) {
                            for (arr[r .. r + rows]) |*v| v.* = mn;
                        } else {
                            const w: u32 = enc;
                            var bitpos: usize = 0;
                            for (arr[r .. r + rows]) |*v| {
                                var d: u64 = 0;
                                var got: u32 = 0;
                                while (got < w) {
                                    const byte = src[bitpos / 8];
                                    const avail: u32 = 8 - @as(u32, @intCast(bitpos % 8));
                                    const take = @min(w - got, avail);
                                    const chunk: u64 = (byte >> @intCast(bitpos % 8)) & (@as(u64, 1) << @intCast(take)) - 1;
                                    d |= chunk << @intCast(got);
                                    got += take;
                                    bitpos += take;
                                }
                                v.* = mn +% @as(i64, @bitCast(d));
                            }
                        }
                        r += rows;
                    }
                    t.data[ci] = .{ .ints = arr };
                },
                .float => {
                    const arr = try a.alloc(f64, nrows);
                    var r: usize = 0;
                    for (0..nblocks) |_| {
                        const rows: usize = @intCast(try rd.u32at(bytes, &pos));
                        _ = try rd.u64at(bytes, &pos);
                        _ = try rd.u64at(bytes, &pos);
                        if (version >= 3) {
                            if (pos >= bytes.len) return error.BadSnapshot;
                            pos += 1;
                        }
                        const dlen: usize = @intCast(try rd.u32at(bytes, &pos));
                        if (pos + dlen > bytes.len) return error.BadSnapshot;
                        @memcpy(std.mem.sliceAsBytes(arr[r .. r + rows]), bytes[pos .. pos + dlen]);
                        pos += dlen;
                        r += rows;
                    }
                    t.data[ci] = .{ .floats = arr };
                },
                .str => {
                    const offsets = try a.alloc(u32, nrows + 1);
                    var blob = std.ArrayList(u8).empty;
                    var dec = std.ArrayList(u8).empty;
                    defer dec.deinit(gpa);
                    var r: usize = 0;
                    for (0..nblocks) |_| {
                        const rows: usize = @intCast(try rd.u32at(bytes, &pos));
                        _ = try rd.u64at(bytes, &pos);
                        _ = try rd.u64at(bytes, &pos);
                        var blk_enc: u8 = 0;
                        if (version >= 3) {
                            if (pos >= bytes.len) return error.BadSnapshot;
                            blk_enc = bytes[pos];
                            pos += 1;
                        }
                        const dlen: usize = @intCast(try rd.u32at(bytes, &pos));
                        if (pos + dlen > bytes.len) return error.BadSnapshot;
                        const raw = bytes[pos .. pos + dlen];
                        pos += dlen;
                        const blk: []const u8 = if (blk_enc == 200) blk: {
                            if (raw.len < 4) return error.BadSnapshot;
                            const ulen: usize = @intCast(std.mem.readInt(u32, raw[0..4], .little));
                            if (dec.items.len < ulen) try dec.resize(gpa, ulen);
                            try lz4.decompress(dec.items[0..ulen], raw[4..]);
                            break :blk dec.items[0..ulen];
                        } else raw;
                        const base: u32 = @intCast(blob.items.len);
                        var i: usize = 0;
                        while (i <= rows) : (i += 1) {
                            const off = std.mem.readInt(u32, blk[i * 4 ..][0..4], .little);
                            offsets[r + i] = base + off;
                        }
                        try blob.appendSlice(a, blk[(rows + 1) * 4 ..]);
                        r += rows;
                    }
                    t.data[ci] = .{ .strs = .{ .offsets = offsets, .bytes = blob.items } };
                },
            }
        }
        t.heap = gpa;
        t.scratch = &.{};
        t.scratch_used = 0;
        try t.buildEncodings(a);
        if (version >= 7) {
            if (pos >= bytes.len) return error.BadSnapshot;
            const has_tomb = bytes[pos] != 0;
            pos += 1;
            if (has_tomb) {
                if (pos + 4 > bytes.len) return error.BadSnapshot;
                const words: usize = @intCast(std.mem.readInt(u32, bytes[pos..][0..4], .little));
                pos += 4;
                if (pos + words > bytes.len) return error.BadSnapshot;
                const bits = try a.alloc(u8, words);
                @memcpy(bits, bytes[pos .. pos + words]);
                pos += words;
                t.tomb = bits;
            }
        }
        if (version >= 6) {
            if (pos + 4 > bytes.len) return error.BadSnapshot;
            const nidx = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            pos += 4;
            if (nidx > 0) {
                t.keyidx = try a.alloc(?*KeyIndex, ncols);
                @memset(t.keyidx, null);
                var k: usize = 0;
                while (k < nidx) : (k += 1) {
                    if (pos + 4 > bytes.len) return error.BadSnapshot;
                    const ci2: usize = @intCast(std.mem.readInt(u32, bytes[pos..][0..4], .little));
                    pos += 4;
                    if (ci2 >= ncols) return error.BadSnapshot;
                    var tree = try btree.BTree.deserialize(a, bytes, &pos);
                    const ni = try a.create(KeyIndex);
                    const flat = try tree.flatten(a);
                    ni.* = .{
                        .keys = flat.keys,
                        .offsets = flat.offsets,
                        .rows = flat.rows,
                        .block_rows = t.block_rows,
                        .tree = tree,
                    };
                    t.keyidx[ci2] = ni;
                }
            }
        } else if (version == 4) {
            if (pos + 4 > bytes.len) return error.BadSnapshot;
            const nidx = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            pos += 4;
            if (nidx > 0) {
                t.keyidx = try a.alloc(?*KeyIndex, ncols);
                @memset(t.keyidx, null);
                var k: usize = 0;
                while (k < nidx) : (k += 1) {
                    if (pos + 4 > bytes.len) return error.BadSnapshot;
                    const ci2: usize = @intCast(std.mem.readInt(u32, bytes[pos..][0..4], .little));
                    pos += 4;
                    const nkeys: usize = @intCast(std.mem.readInt(u32, bytes[pos..][0..4], .little));
                    pos += 4;
                    const npost: usize = @intCast(std.mem.readInt(u64, bytes[pos..][0..8], .little));
                    pos += 8;
                    if (ci2 >= ncols) return error.BadSnapshot;
                    const idx = try a.create(KeyIndex);
                    idx.keys = try a.alloc(i64, nkeys);
                    @memcpy(std.mem.sliceAsBytes(idx.keys), bytes[pos .. pos + nkeys * 8]);
                    pos += nkeys * 8;
                    idx.offsets = try a.alloc(u32, nkeys + 1);
                    @memcpy(std.mem.sliceAsBytes(idx.offsets), bytes[pos .. pos + (nkeys + 1) * 4]);
                    pos += (nkeys + 1) * 4;
                    idx.rows = try a.alloc(u32, npost);
                    @memcpy(std.mem.sliceAsBytes(idx.rows), bytes[pos .. pos + npost * 4]);
                    pos += npost * 4;
                    idx.block_rows = t.block_rows;
                    idx.tree = try btree.BTree.build(a, idx.keys, idx.offsets, idx.rows);
                    t.keyidx[ci2] = idx;
                }
            }
        }
        if (bytes.len >= pos + 4 and std.mem.eql(u8, bytes[pos .. pos + 4], "ZBT1")) {
            const avail = bytes.len - pos;
            var vals: [8]u64 = @splat(0);
            var nvals: usize = 0;
            if (avail >= trailer_len_v3) {
                nvals = 8;
            } else if (avail >= trailer_len_v2) {
                nvals = 5;
            } else if (avail >= trailer_len_v1) {
                nvals = 4;
            } else return error.BadSnapshot;
            pos += 4;
            var vi: usize = 0;
            while (vi < nvals) : (vi += 1) {
                vals[vi] = std.mem.readInt(u64, bytes[pos..][0..8], .little);
                pos += 8;
            }
            if (nvals == 4) {
                vals[4] = vals[3];
                vals[3] = @bitCast(@as(f64, 79.0));
            } else if (nvals == 5) {
            }
            t.wb_costs = .{
                .write_ns_byte = @bitCast(vals[0]),
                .encode_ns_row = @bitCast(vals[1]),
                .replay_ns_row = @bitCast(vals[2]),
                .compact_row_ns = @bitCast(vals[3]),
                .samples = vals[4],
                .scan_row_ns = @bitCast(vals[5]),
                .str_raw_ns = @bitCast(vals[6]),
                .str_dict_ns = @bitCast(vals[7]),
            };
        }
        return t;
    }
    pub fn orderKeyCodes(self: *Table, ci: usize) ?[]const i64 {
        return switch (self.data[ci]) {
            .ints => |a| a,
            .strs => null,
            else => null,
        };
    }
    pub fn scratchReset(self: *Table) void {
        self.scratch_used = 0;
    }
    pub fn scratchAlloc(self: *Table, comptime T: type, count: usize) ?[]T {
        const al = @alignOf(T);
        const used = std.mem.alignForward(usize, self.scratch_used, al);
        const bytes = count * @sizeOf(T);
        if (used + bytes > self.scratch.len) return null;
        self.scratch_used = used + bytes;
        const p: [*]u8 = self.scratch.ptr + used;
        return @as([*]T, @ptrCast(@alignCast(p)))[0..count];
    }
    pub fn groupKeyPtr(self: *Table, ci: usize) ?[*]const i64 {
        return switch (self.data[ci]) {
            .ints => |a| a.ptr,
            else => null,
        };
    }
    pub fn groupKeyIds(self: *Table, ci: usize) ?[]const u32 {
        return if (ci < self.enc.len) (if (self.enc[ci]) |e| e.ids else null) else null;
    }
    pub inline fn intAt(self: *const Table, ci: usize, ri: usize) i64 {
        return self.data[ci].intAt(ri);
    }
    pub fn narrowIntColumns(self: *Table) !void {
        if (std.c.getenv("ZHDB_NO_INTNARROW") != null) return;
        for (self.cols, 0..) |c, ci| {
            if (c.kind != .int) continue;
            const old = self.data[ci].i64Slice() orelse continue;
            const st = if (ci < self.stats.len) self.stats[ci] else null;
            var lo: i64 = 0;
            var hi: i64 = 0;
            if (st) |ss| {
                if (ss.len == 0) continue;
                lo = ss[0].min;
                hi = ss[0].max;
                for (ss) |b| {
                    lo = @min(lo, b.min);
                    hi = @max(hi, b.max);
                }
            } else continue;
            const n = self.nrows;
            if (lo >= std.math.minInt(i8) and hi <= std.math.maxInt(i8)) {
                const out = try self.arena.allocator().alloc(i8, n);
                for (old[0..n], 0..) |v, i| out[i] = @intCast(v);
                self.data[ci] = .{ .ints8 = out };
            } else if (lo >= std.math.minInt(i16) and hi <= std.math.maxInt(i16)) {
                const out = try self.arena.allocator().alloc(i16, n);
                for (old[0..n], 0..) |v, i| out[i] = @intCast(v);
                self.data[ci] = .{ .ints16 = out };
            } else if (lo >= std.math.minInt(i32) and hi <= std.math.maxInt(i32)) {
                const out = try self.arena.allocator().alloc(i32, n);
                for (old[0..n], 0..) |v, i| out[i] = @intCast(v);
                self.data[ci] = .{ .ints32 = out };
            } else continue;
            self.heap.free(old.ptr[0..old.len]);
        }
    }
    pub fn widenIntColumn(self: *Table, a: std.mem.Allocator, ci: usize) bool {
        if (self.data[ci].i64Slice() != null) return true;
        const n = self.nrows;
        const out = a.alloc(i64, n) catch return false;
        for (0..n) |i| out[i] = self.data[ci].intAt(i);
        self.data[ci] = .{ .ints = out };
        return true;
    }
    pub fn intsView(self: *const Table, alloc: std.mem.Allocator, ci: usize) ![]const i64 {
        if (self.data[ci].i64Slice()) |a| return a;
        const n = self.nrows;
        const out = try alloc.alloc(i64, n);
        for (0..n) |i| out[i] = self.data[ci].intAt(i);
        return out;
    }
    pub inline fn keyAt(self: *Table, ci: usize, ri: usize) i64 {
        if (self.enc[ci]) |e| return e.ids[ri];
        return self.data[ci].intAt(ri);
    }
    pub fn dictText(self: *Table, ci: usize, id: u32) []const u8 {
        const e = self.enc[ci] orelse return "";
        return self.data[ci].strs.at(e.first[id]);
    }
    pub fn destroy(self: *Table, gpa: std.mem.Allocator) void {
        _ = self.dropPatches();
        self.arena.deinit();
        gpa.destroy(self);
    }
    pub fn find(self: *const Table, name: []const u8) ?usize {
        for (self.cols, 0..) |c, i| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) return i;
            if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                if (std.ascii.eqlIgnoreCase(c.name, name[dot + 1 ..])) return i;
            }
        }
        return null;
    }
};
fn asInt(v: Value) i64 {
    return switch (v) {
        .int => |x| x,
        .float => |f| @intFromFloat(f),
        .boolean => |b| @intFromBool(b),
        .text => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        .null => 0,
    };
}
fn asFloat(v: Value) f64 {
    return switch (v) {
        .float => |f| f,
        .int => |x| @floatFromInt(x),
        .boolean => |b| @floatFromInt(@intFromBool(b)),
        .text => |s| std.fmt.parseFloat(f64, s) catch 0,
        .null => 0,
    };
}
fn asText(v: Value) []const u8 {
    return switch (v) {
        .text => |s| s,
        else => "",
    };
}
pub const QueryResult = struct {
    columns: [][]const u8,
    rows: [][]Value,
    affected: usize = 0,
    format_json: bool = false,
};
const Scalar = union(enum) {
    null,
    int: i64,
    float: f64,
    str: []const u8,
    boolean: bool,
    fn asF(self: Scalar) f64 {
        return switch (self) {
            .null => 0,
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            .str => 0,
            .boolean => |b| if (b) 1 else 0,
        };
    }
};
const AggKind = enum { count_all, count, count_distinct, sum, avg, min, max };
const AggSpec = struct {
    kind: AggKind,
    col: i32,
    expr: ?*sql.Expr = null,
    offset: i64 = 0,
};
fn exprStrMask(t: *Table, e: *sql.Expr) u32 {
    var m: u32 = 0;
    switch (e.*) {
        .column => |name| {
            if (t.find(name)) |ci| {
                if (ci < 32 and ci < t.cols.len and t.cols[ci].kind == .str) m |= (@as(u32, 1) << @intCast(ci));
            }
        },
        .column_idx => |c| {
            if (c.idx < 32 and c.idx < t.cols.len and t.cols[c.idx].kind == .str) m |= (@as(u32, 1) << @intCast(c.idx));
        },
        .binary => |b| m |= exprStrMask(t, b.lhs) | exprStrMask(t, b.rhs),
        .negate => |x| m |= exprStrMask(t, x),
        .not => |x| m |= exprStrMask(t, x),
        .is_null => |x| m |= exprStrMask(t, x.operand),
        .like => |x| m |= exprStrMask(t, x.operand) | exprStrMask(t, x.pattern),
        .in_list => |x| {
            m |= exprStrMask(t, x.operand);
            for (x.items) |it| m |= exprStrMask(t, it);
        },
        .between => |x| m |= exprStrMask(t, x.operand) | exprStrMask(t, x.low) | exprStrMask(t, x.high),
        .call => |c| for (c.args) |a| {
            m |= exprStrMask(t, a);
        },
        .case_expr => |c| {
            for (c.whens) |w| m |= exprStrMask(t, w.cond) | exprStrMask(t, w.then);
            if (c.else_expr) |x| m |= exprStrMask(t, x);
        },
        .cast => |x| m |= exprStrMask(t, x.operand),
        else => {},
    }
    return m;
}
fn exprDictSafe(t: *Table, e: *sql.Expr) bool {
    switch (e.*) {
        .like, .between => return false,
        .in_list => |x| {
            const ci = rootColumnIndex(t, x.operand) orelse return exprDictSafe(t, x.operand);
            if (ci < t.cols.len and t.cols[ci].kind == .str) return false;
            return true;
        },
        .binary => |b| {
            const ci = rootColumnIndex(t, b.lhs) orelse rootColumnIndex(t, b.rhs);
            if (ci) |c| {
                if (c < t.cols.len and t.cols[c].kind == .str) {
                    if (b.op != .eq) return false;
                    return c < t.enc.len and t.enc[c] != null;
                }
            }
            return exprDictSafe(t, b.lhs) and exprDictSafe(t, b.rhs);
        },
        .negate => |x| return exprDictSafe(t, x),
        .not => |x| return exprDictSafe(t, x),
        .call => |c| {
            for (c.args) |a| {
                if (!exprDictSafe(t, a)) return false;
            }
            return true;
        },
        .cast => |x| return exprDictSafe(t, x.operand),
        else => return true,
    }
}
pub fn tryRun(t: *Table, alloc: std.mem.Allocator, sel: *sql.Select) !?QueryResult {
    var s = Scratch{ .buf = t.scratch };
    return tryRunScratch(t, alloc, sel, &s);
}
pub fn tryRunScratch(t: *Table, alloc: std.mem.Allocator, sel: *sql.Select, s: *Scratch) !?QueryResult {
    if (sel.from == null or sel.from.? != .table) return null;
    if (t.has_bool or t.has_int2) return null;
    if (sel.alias_cols.len > 0) return null;
    if (sel.union_all != null) return null;
    for (sel.items) |it| {
        if (it.expr.* == .star) continue;
        if (!supportedExpr(it.expr) or !columnsResolve(t, it.expr)) return null;
    }
    if (sel.where) |w| if (!columnsResolve(t, w)) return null;
    if (sel.where) |w| {
        if (hasInSubquery(w) and !semiShapeOk(w)) return null;
    }
    if (sel.having) |h| if (!columnsResolve(t, h)) return null;
    for (sel.group_by) |g| if (!columnsResolve(t, g)) return null;
    if (sel.where) |w| if (!supportedExpr(w)) return null;
    for (sel.group_by) |g| {
        switch (g.*) {
            .int, .float, .string, .null_lit => continue,
            else => {},
        }
        if (rootColumnIndex(t, g) == null and baseKeyColumn(t, g) == null and
            !strExprOk(t, g) and !exprEpochKeyOk(t, g)) return null;
    }
    if (sel.having) |h| if (!supportedExpr(h)) return null;
    for (sel.order_by) |o| if (!supportedExpr(o.expr)) return null;
    {
        var mask: u32 = 0;
        for (sel.items) |it| mask |= exprStrMask(t, it.expr);
        if (sel.where) |w| mask |= exprStrMask(t, w);
        for (sel.group_by) |g| mask |= exprStrMask(t, g);
        for (sel.order_by) |o| mask |= exprStrMask(t, o.expr);
        if (sel.having) |h| mask |= exprStrMask(t, h);
        const nstr: u32 = @intCast(@popCount(mask));
        const dp = if (sel.where) |w| exprDictSafe(t, w) else true;
        last_query_nstr = nstr;
        last_query_dict = dp;
        const nf: f64 = @floatFromInt(nstr);
        cal_query_str = nf * (if (dp) cal_str_dict else cal_str_raw);
    }
    var specs = std.ArrayList(AggSpec).empty;
    defer specs.deinit(alloc);
    for (sel.items) |it| try collectAggs(t, alloc, it.expr, &specs);
    if (sel.having) |h| try collectAggs(t, alloc, h, &specs);
    var selection = std.ArrayList(u32).empty;
    defer selection.deinit(alloc);
    if (sel.where) |w| try filter(t, alloc, w, &selection);
    const grouped = sel.group_by.len > 0 or specs.items.len > 0 or sel.having != null;
    if (t.tomb != null) {
        var w: usize = 0;
        for (selection.items) |ri| {
            if (!t.isDeleted(ri)) {
                selection.items[w] = ri;
                w += 1;
            }
        }
        selection.items.len = w;
        if (sel.where == null) {
            try selection.ensureTotalCapacity(alloc, t.nrows);
            var i: usize = 0;
            while (i < t.nrows) : (i += 1) {
                if (!t.isDeleted(i)) selection.appendAssumeCapacity(@intCast(i));
            }
        }
    }
    if (!grouped) {
        if (sel.where == null and t.tomb == null) {
            try selection.ensureTotalCapacity(alloc, t.nrows);
            var i: usize = 0;
            while (i < t.nrows) : (i += 1) selection.appendAssumeCapacity(@intCast(i));
        }
        return try projectRows(t, alloc, sel, selection.items);
    }
    const has_tomb = t.tomb != null;
    const srows = Sel{ .list = if (sel.where == null and !has_tomb) null else selection.items, .n = t.nrows };
    return try aggregate(t, alloc, sel, specs.items, srows, sel.where == null and !has_tomb, s);
}
fn columnsResolve(t: *const Table, e: *sql.Expr) bool {
    return switch (e.*) {
        .in_subquery => |x| columnsResolve(t, x.operand),
        .exists => true,
        .column => |name| t.find(name) != null,
        .column_idx => true,
        .binary => |b| columnsResolve(t, b.lhs) and columnsResolve(t, b.rhs),
        .negate => |x| columnsResolve(t, x),
        .not => |x| columnsResolve(t, x),
        .is_null => |x| columnsResolve(t, x.operand),
        .like => |x| columnsResolve(t, x.operand) and columnsResolve(t, x.pattern),
        .in_list => |x| blk: {
            if (!columnsResolve(t, x.operand)) break :blk false;
            for (x.items) |it| if (!columnsResolve(t, it)) break :blk false;
            break :blk true;
        },
        .between => |x| columnsResolve(t, x.operand) and columnsResolve(t, x.low) and columnsResolve(t, x.high),
        .cast => |x| columnsResolve(t, x.operand),
        .call => |c| blk: {
            for (c.args) |a| if (!columnsResolve(t, a)) break :blk false;
            break :blk true;
        },
        .case_expr => |c| blk: {
            for (c.whens) |w| {
                if (!columnsResolve(t, w.cond) or !columnsResolve(t, w.then)) break :blk false;
            }
            if (c.else_expr) |el| if (!columnsResolve(t, el)) break :blk false;
            break :blk true;
        },
        else => true,
    };
}
fn supportedExpr(e: *sql.Expr) bool {
    return switch (e.*) {
        .column, .column_idx, .int, .float, .string, .null_lit => true,
        .star, .star_table, .subscript, .json_get, .window, .ordered_agg, .param, .at_zone, .at_local, .field, .scalar_sub, .prefix_op => false,
        .in_subquery => semi_mask != null,
        .exists => false,
        .binary => |b| (b.op != .regex and b.op != .regex_ne) and
            supportedExpr(b.lhs) and supportedExpr(b.rhs),
        .negate => |x| supportedExpr(x),
        .bitnot => |x| supportedExpr(x),
        .not => |x| supportedExpr(x),
        .is_null => |x| supportedExpr(x.operand),
        .like => |x| supportedExpr(x.operand) and supportedExpr(x.pattern),
        .in_list => |x| blk: {
            if (!supportedExpr(x.operand)) break :blk false;
            for (x.items) |it| if (!supportedExpr(it)) break :blk false;
            break :blk true;
        },
        .between => |x| supportedExpr(x.operand) and supportedExpr(x.low) and supportedExpr(x.high),
        .cast => |x| blk: {
            if (!supportedExpr(x.operand)) break :blk false;
            var buf: [32]u8 = undefined;
            const n = @min(x.type_name.len, buf.len);
            const ty = std.ascii.lowerString(buf[0..n], x.type_name[0..n]);
            break :blk std.mem.indexOf(u8, ty, "int") != null or
                std.mem.indexOf(u8, ty, "float") != null or
                std.mem.indexOf(u8, ty, "double") != null;
        },
        .call => |c| blk: {
            if (std.ascii.eqlIgnoreCase(c.name, "length")) {
                if (c.args.len != 1 or !supportedExpr(c.args[0])) break :blk false;
                break :blk true;
            }
            if (std.ascii.eqlIgnoreCase(c.name, "regexp_replace") and c.args.len == 3 and
                c.args[1].* == .string and c.args[2].* == .string and
                std.mem.eql(u8, c.args[1].string, "^https?://(?:www\\.)?([^/]+)/.*$") and
                std.mem.eql(u8, c.args[2].string, "\\1"))
            {
                for (c.args) |a| if (!supportedExpr(a)) break :blk false;
                break :blk true;
            }
            if (std.ascii.eqlIgnoreCase(c.name, "extract") or
                std.ascii.eqlIgnoreCase(c.name, "date_trunc") or
                std.ascii.eqlIgnoreCase(c.name, "to_timestamp") or
                std.ascii.eqlIgnoreCase(c.name, "from_unixtime"))
            {
                for (c.args) |a| if (!supportedExpr(a)) break :blk false;
                break :blk true;
            }
            if (isAggName(c.name)) break :blk true;
            break :blk false;
        },
        .case_expr => |c| blk: {
            if (c.else_expr == null) break :blk false;
            for (c.whens) |w| {
                if (!supportedExpr(w.cond) or !supportedExpr(w.then)) break :blk false;
            }
            if (!supportedExpr(c.else_expr.?)) break :blk false;
            break :blk true;
        },
    };
}
fn rootColumnIndex(t: *const Table, e: *sql.Expr) ?usize {
    return switch (e.*) {
        .column => |name| t.find(name),
        .column_idx => |ci| ci.idx,
        else => null,
    };
}
fn colIndex(t: *const Table, e: *sql.Expr) ?usize {
    return rootColumnIndex(t, e);
}
fn evalScalar(t: *const Table, e: *sql.Expr, row: usize) Scalar {
    switch (e.*) {
        .int => |v| return .{ .int = v },
        .float => |v| return .{ .float = v },
        .string => |s| return .{ .str = s },
        .null_lit => return .null,
        .column => |name| {
            const ci = t.find(name) orelse return .{ .int = 0 };
            return valueOf(t, ci, row);
        },
        .column_idx => |c| return valueOf(t, c.idx, row),
        .negate => |x| switch (evalScalar(t, x, row)) {
            .null => return .null,
            .int => |i| return .{ .int = -i },
            .float => |f| return .{ .float = -f },
            .str, .boolean => return .{ .int = 0 },
        },
        .not => |x| {
            if (boolUnknown(t, x, row)) return .null;
            return .{ .boolean = !evalBool(t, x, row) };
        },
        .is_null => |x| return .{ .boolean = if (x.negated) !boolNullCheck(t, x.operand, row) else boolNullCheck(t, x.operand, row) },
        .like => |l| {
            if (scalarUnknown(t, l.operand, row) or scalarUnknown(t, l.pattern, row)) return .null;
            return .{ .boolean = evalBool(t, e, row) };
        },
        .in_list => |in| {
            if (scalarUnknown(t, in.operand, row)) return .null;
            const v = evalScalar(t, in.operand, row);
            var found = false;
            var has_null = false;
            for (in.items) |it| {
                if (scalarUnknown(t, it, row)) {
                    has_null = true;
                    continue;
                }
                if (compareScalar(v, evalScalar(t, it, row), .eq)) {
                    found = true;
                    break;
                }
            }
            if (!found and has_null) return .null;
            return .{ .boolean = if (in.negated) !found else found };
        },
        .between => |b| {
            if (scalarUnknown(t, b.operand, row) or scalarUnknown(t, b.low, row) or scalarUnknown(t, b.high, row)) return .null;
            return .{ .boolean = evalBool(t, e, row) };
        },
        .binary => |b| return binaryScalar(t, b.op, evalScalar(t, b.lhs, row), evalScalar(t, b.rhs, row)),
        .cast => |c| {
            const v = evalScalar(t, c.operand, row);
            if (v == .null) return .null;
            var buf: [32]u8 = undefined;
            const n = @min(c.type_name.len, buf.len);
            const ty = std.ascii.lowerString(buf[0..n], c.type_name[0..n]);
            if (std.mem.indexOf(u8, ty, "int") != null or std.mem.indexOf(u8, ty, "bigint") != null) {
                return switch (v) {
                    .null => .null,
                    .int => v,
                    .float => |f| .{ .int = @intFromFloat(f) },
                    .str => |x| .{ .int = std.fmt.parseInt(i64, x, 10) catch 0 },
                    .boolean => |b| .{ .int = @intFromBool(b) },
                };
            }
            if (std.mem.indexOf(u8, ty, "float") != null or std.mem.indexOf(u8, ty, "double") != null) {
                return switch (v) {
                    .null => .null,
                    .float => v,
                    .int => |i| .{ .float = @floatFromInt(i) },
                    .str => |x| .{ .float = std.fmt.parseFloat(f64, x) catch 0 },
                    .boolean => |b| .{ .float = if (b) 1 else 0 },
                };
            }
            return .{ .str = switch (v) {
                .str => |x| x,
                else => "",
            } };
        },
        .case_expr => |ce| {
            for (ce.whens) |w| {
                const cv = evalScalar(t, w.cond, row);
                const truth = switch (cv) {
                    .null => false,
                    .int => |x| x != 0,
                    .float => |x| x != 0,
                    .str => |x| x.len != 0,
                    .boolean => |b| b,
                };
                if (truth) return evalScalar(t, w.then, row);
            }
            if (ce.else_expr) |el| return evalScalar(t, el, row);
            return .null;
        },
        .call => |c| {
            if (std.ascii.eqlIgnoreCase(c.name, "regexp_replace") and c.args.len == 3 and
                c.args[1].* == .string and c.args[2].* == .string and
                std.mem.eql(u8, c.args[1].string, "^https?://(?:www\\.)?([^/]+)/.*$") and
                std.mem.eql(u8, c.args[2].string, "\\1"))
            {
                const v = evalScalar(t, c.args[0], row);
                if (v == .null) return .null;
                if (v == .str) {
                    if (hostOfUrl(v.str)) |hh| return .{ .str = hh };
                    return v;
                }
                return .{ .str = "" };
            }
            if (std.ascii.eqlIgnoreCase(c.name, "date_trunc") and c.args.len == 2 and
                c.args[0].* == .string)
            {
                const buf: *[32]u8 = &ts_buf;
                const v = evalScalar(t, c.args[1], row);
                if (v == .null) return .null;
                const secs: i64 = switch (v) {
                    .int => |x| x,
                    .float => |f| @intFromFloat(@floor(f)),
                    else => 0,
                };
                var tr = secs;
                const unit = c.args[0].string;
                if (std.ascii.eqlIgnoreCase(unit, "minute")) {
                    tr = secs - @mod(secs, 60);
                } else if (std.ascii.eqlIgnoreCase(unit, "hour")) {
                    tr = secs - @mod(secs, 3600);
                } else if (std.ascii.eqlIgnoreCase(unit, "day")) {
                    tr = secs - @mod(secs, 86400);
                } else if (std.ascii.eqlIgnoreCase(unit, "month")) {
                    const cv = civilOfDays(@divFloor(secs, 86400));
                    tr = daysOfCivil(cv.y, cv.m, 1) * 86400;
                } else if (std.ascii.eqlIgnoreCase(unit, "year")) {
                    const cv = civilOfDays(@divFloor(secs, 86400));
                    tr = daysOfCivil(cv.y, 1, 1) * 86400;
                }
                const days = @divFloor(tr, 86400);
                const sod: u32 = @intCast(tr - days * 86400);
                const cv = civilOfDays(days);
                const n = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
                    @as(u32, @intCast(@max(cv.y, 0))), cv.m, cv.d, sod / 3600, (sod % 3600) / 60, sod % 60,
                }) catch "";
                return .{ .str = n };
            }
            if (std.ascii.eqlIgnoreCase(c.name, "length") and c.args.len == 1) {
                const v = evalScalar(t, c.args[0], row);
                return switch (v) {
                    .null => .null,
                    .str => |s| .{ .int = @intCast(s.len) },
                    else => .{ .int = 0 },
                };
            }
            if ((std.ascii.eqlIgnoreCase(c.name, "to_timestamp") or
                std.ascii.eqlIgnoreCase(c.name, "from_unixtime")) and c.args.len == 1)
            {
                const v = evalScalar(t, c.args[0], row);
                return switch (v) {
                    .null => .null,
                    .int => v,
                    .float => |f| .{ .int = @intFromFloat(@floor(f)) },
                    else => .{ .int = 0 },
                };
            }
            if (std.ascii.eqlIgnoreCase(c.name, "extract") and c.args.len == 2 and
                c.args[0].* == .string)
            {
                const unit = c.args[0].string;
                const v = evalScalar(t, c.args[1], row);
                if (v == .null) return .null;
                const secs: i64 = switch (v) {
                    .int => |x| x,
                    .float => |f| @intFromFloat(@floor(f)),
                    else => 0,
                };
                const days = @divFloor(secs, 86400);
                const sod: i64 = secs - days * 86400;
                if (std.ascii.eqlIgnoreCase(unit, "epoch")) return .{ .int = secs };
                if (std.ascii.eqlIgnoreCase(unit, "hour")) return .{ .int = @divFloor(sod, 3600) };
                if (std.ascii.eqlIgnoreCase(unit, "minute")) return .{ .int = @divFloor(sod, 60) - @divFloor(sod, 3600) * 60 };
                if (std.ascii.eqlIgnoreCase(unit, "second")) return .{ .int = @mod(sod, 60) };
                const civ = civilOfDays(days);
                if (std.ascii.eqlIgnoreCase(unit, "year")) return .{ .int = civ.y };
                if (std.ascii.eqlIgnoreCase(unit, "month")) return .{ .int = civ.m };
                if (std.ascii.eqlIgnoreCase(unit, "day")) return .{ .int = civ.d };
                return .{ .int = 0 };
            }
            return .{ .int = 0 };
        },
        else => return .{ .int = 0 },
    }
}
fn intOf(v: Value) i64 {
    return switch (v) {
        .int => |x| x,
        .boolean => |b| if (b) 1 else 0,
        .float => |f| @intFromFloat(f),
        else => 0,
    };
}
fn valueOf(t: *const Table, ci: usize, row: usize) Scalar {
    if (t.isNull(ci, row)) return .null;
    return switch (t.data[ci]) {
        .ints, .ints8, .ints16, .ints32 => .{ .int = t.data[ci].intAt(row) },
        .floats => |a| .{ .float = a[row] },
        .strs => |s| .{ .str = s.at(row) },
    };
}
fn scalarTruthy(v: Scalar) bool {
    return switch (v) {
        .null => false,
        .int => |x| x != 0,
        .float => |x| x != 0,
        .str => |x| x.len != 0,
        .boolean => |b| b,
    };
}
fn binaryScalar(t: *const Table, op: sql.BinOp, l: Scalar, r: Scalar) Scalar {
    if (op == .and_op) {
        if ((l != .null and !scalarTruthy(l)) or (r != .null and !scalarTruthy(r))) return .{ .boolean = false };
        if (l == .null or r == .null) return .null;
        return .{ .boolean = true };
    }
    if (op == .or_op) {
        if ((l != .null and scalarTruthy(l)) or (r != .null and scalarTruthy(r))) return .{ .boolean = true };
        if (l == .null or r == .null) return .null;
        return .{ .boolean = false };
    }
    if (l == .null or r == .null) return .null;
    switch (op) {
        .add => {
            if (l == .int and r == .int) return .{ .int = l.int + r.int };
            return .{ .float = l.asF() + r.asF() };
        },
        .sub => {
            if (l == .int and r == .int) return .{ .int = l.int - r.int };
            return .{ .float = l.asF() - r.asF() };
        },
        .mul => {
            if (l == .int and r == .int) return .{ .int = l.int * r.int };
            return .{ .float = l.asF() * r.asF() };
        },
        .div => {
            if (l == .int and r == .int and r.int != 0) return .{ .int = @divTrunc(l.int, r.int) };
            const d = r.asF();
            if (d == 0) return .null;
            return .{ .float = l.asF() / d };
        },
        .mod => {
            if (l == .int and r == .int and r.int != 0) return .{ .int = @rem(l.int, r.int) };
            return .null;
        },
        .eq, .neq, .lt, .gt, .le, .ge => return .{ .boolean = compareScalar(l, r, op) },
        else => return .null,
    }
    _ = t;
}
fn compareScalar(a: Scalar, b: Scalar, op: sql.BinOp) bool {
    if (a == .null or b == .null) return false;
    if (a == .str or b == .str) {
        if (a == .int and b == .str) return compareScalar(a, .{ .int = std.fmt.parseInt(i64, std.mem.trim(u8, b.str, " \t\r\n"), 10) catch 0 }, op);
        if (a == .str and b == .int) return compareScalar(.{ .int = std.fmt.parseInt(i64, std.mem.trim(u8, a.str, " \t\r\n"), 10) catch 0 }, b, op);
        if (a == .float and b == .str) return compareScalar(a, .{ .float = std.fmt.parseFloat(f64, std.mem.trim(u8, b.str, " \t\r\n")) catch 0 }, op);
        if (a == .str and b == .float) return compareScalar(.{ .float = std.fmt.parseFloat(f64, std.mem.trim(u8, a.str, " \t\r\n")) catch 0 }, b, op);
        if (a != .str or b != .str) return false;
        const ord = std.mem.order(u8, a.str, b.str);
        return switch (op) {
            .eq => ord == .eq,
            .neq => ord != .eq,
            .lt => ord == .lt,
            .gt => ord == .gt,
            .le => ord != .gt,
            .ge => ord != .lt,
            else => false,
        };
    }
    if (a == .int and b == .int) {
        return switch (op) {
            .eq => a.int == b.int,
            .neq => a.int != b.int,
            .lt => a.int < b.int,
            .gt => a.int > b.int,
            .le => a.int <= b.int,
            .ge => a.int >= b.int,
            else => false,
        };
    }
    const x = a.asF();
    const y = b.asF();
    return switch (op) {
        .eq => x == y,
        .neq => x != y,
        .lt => x < y,
        .gt => x > y,
        .le => x <= y,
        .ge => x >= y,
        else => false,
    };
}
fn scalarUnknown(t: *const Table, e: *sql.Expr, row: usize) bool {
    return switch (e.*) {
        .null_lit => true,
        .column => |name| blk: {
            const ci = t.find(name) orelse break :blk false;
            break :blk t.isNull(ci, row);
        },
        .column_idx => |c| t.isNull(c.idx, row),
        else => false,
    };
}
fn boolUnknown(t: *const Table, e: *sql.Expr, row: usize) bool {
    switch (e.*) {
        .binary => |b| {
            if (b.op == .and_op or b.op == .or_op) return false;
            if (rootColumnIndex(t, b.lhs)) |c| {
                if (c < t.cols.len and t.isNull(c, row)) return true;
            }
            if (rootColumnIndex(t, b.rhs)) |c| {
                if (c < t.cols.len and t.isNull(c, row)) return true;
            }
            return false;
        },
        .in_list => |x| {
            if (rootColumnIndex(t, x.operand)) |c| {
                if (c < t.cols.len and t.isNull(c, row)) return true;
            }
            return false;
        },
        .like => |x| {
            if (rootColumnIndex(t, x.operand)) |c| {
                if (c < t.cols.len and t.isNull(c, row)) return true;
            }
            return false;
        },
        .not => |x| return boolUnknown(t, x, row),
        .is_null => return false,
        else => return false,
    }
}
fn evalBool(t: *const Table, e: *sql.Expr, row: usize) bool {
    switch (e.*) {
        .binary => |b| switch (b.op) {
            .and_op => return evalBool(t, b.lhs, row) and evalBool(t, b.rhs, row),
            .or_op => return evalBool(t, b.lhs, row) or evalBool(t, b.rhs, row),
            else => return compareScalar(evalScalar(t, b.lhs, row), evalScalar(t, b.rhs, row), b.op),
        },
        .not => |x| {
            if (boolUnknown(t, x, row)) return false;
            return !evalBool(t, x, row);
        },
        .is_null => |x| {
            const is_n = boolNullCheck(t, x.operand, row);
            return if (x.negated) !is_n else is_n;
        },
        .like => |l| {
            if (l.pattern.* == .string) {
                const lit = l.pattern.string;
                const s = switch (l.operand.*) {
                    .column_idx => |c| if (t.data[c.idx] == .strs) t.data[c.idx].strs.at(row) else null,
                    .column => |name| blk: {
                        const ci = t.find(name) orelse break :blk null;
                        break :blk if (t.data[ci] == .strs) t.data[ci].strs.at(row) else null;
                    },
                    else => null,
                };
                if (s) |str| {
                    const m = likeMatch(str, lit);
                    return if (l.negated) !m else m;
                }
            }
            const v = evalScalar(t, l.operand, row);
            const p = evalScalar(t, l.pattern, row);
            if (v != .str or p != .str) return false;
            const m = likeMatch(v.str, p.str);
            return if (l.negated) !m else m;
        },
        .in_list => |in| {
            const operand_ci: ?usize = switch (in.operand.*) {
                .column => |name| t.find(name),
                .column_idx => |c| c.idx,
                else => null,
            };
            if (operand_ci) |ci| {
                if (ci < t.cols.len and t.isNull(ci, row)) return false;
            }
            const v = evalScalar(t, in.operand, row);
            var found = false;
            var has_null = false;
            for (in.items) |it| {
                if (it.* == .null_lit) {
                    has_null = true;
                    continue;
                }
                if (compareScalar(v, evalScalar(t, it, row), .eq)) {
                    found = true;
                    break;
                }
            }
            if (in.negated and has_null) return false;
            return if (in.negated) !found else found;
        },
        .between => |b| {
            const v = evalScalar(t, b.operand, row);
            const lo = evalScalar(t, b.low, row);
            const hi = evalScalar(t, b.high, row);
            const ok = compareScalar(v, lo, .ge) and compareScalar(v, hi, .le);
            return if (b.negated) !ok else ok;
        },
        else => {
            const v = evalScalar(t, e, row);
            return switch (v) {
                .null => false,
                .int => |i| i != 0,
                .float => |f| f != 0,
                .str => |s| s.len > 0,
                .boolean => |b| b,
            };
        },
    }
}
fn boolNullCheck(t: *const Table, e: *sql.Expr, row: usize) bool {
    return switch (e.*) {
        .null_lit => true,
        .column => |name| blk: {
            const ci = t.find(name) orelse break :blk false;
            break :blk t.isNull(ci, row);
        },
        .column_idx => |c| t.isNull(c.idx, row),
        else => false,
    };
}
const Sel = struct {
    list: ?[]const u32 = null,
    n: usize = 0,
    fn len(self: Sel) usize {
        return if (self.list) |l| l.len else self.n;
    }
    fn at(self: Sel, i: usize) u32 {
        return if (self.list) |l| l[i] else @intCast(i);
    }
};
const FastPred = union(enum) {
    like: struct { ci: u32, lit: []const u8, negated: bool },
    nonempty: struct { ci: u32, want_nonempty: bool },
    dict_eq: struct { ci: u32, id: i64, negated: bool },
    int_cmp: struct { ci: u32, op: sql.BinOp, k: i64 },
    int_in: struct { ci: u32, vals: []const i64 },
    dict_rank: struct { ci: u32, lo: i64, hi: i64 },
};
fn dictRankPos(t: *const Table, ci: usize, lit: []const u8) ?struct { k: usize, exists: bool } {
    if (ci >= t.enc.len) return null;
    const e = t.enc[ci] orelse return null;
    if (e.rank.len == 0 or e.byrank.len != e.rank.len) return null;
    const strs = t.data[ci].strs;
    var lo: usize = 0;
    var hi: usize = e.byrank.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const s = strs.at(e.first[e.byrank[mid]]);
        if (std.mem.order(u8, s, lit) == .lt) lo = mid + 1 else hi = mid;
    }
    const exists = lo < e.byrank.len and
        std.mem.eql(u8, strs.at(e.first[e.byrank[lo]]), lit);
    return .{ .k = lo, .exists = exists };
}
fn collectFastPreds(t: *const Table, e: *sql.Expr, list: *std.ArrayList(FastPred), alloc: std.mem.Allocator) !bool {
    switch (e.*) {
        .binary => |b| {
            if (b.op == .and_op) {
                if (!try collectFastPreds(t, b.lhs, list, alloc)) return false;
                return try collectFastPreds(t, b.rhs, list, alloc);
            }
            if (intCmpSpec(t, e)) |spec| {
                try list.append(alloc, .{ .int_cmp = .{ .ci = @intCast(spec.ci), .op = spec.op, .k = spec.k } });
                return true;
            }
            if (b.op == .neq or b.op == .eq) {
                var col_side: ?*sql.Expr = null;
                var str_side: ?*sql.Expr = null;
                if (b.lhs.* == .string) {
                    str_side = b.lhs;
                    col_side = b.rhs;
                } else if (b.rhs.* == .string) {
                    str_side = b.rhs;
                    col_side = b.lhs;
                }
                if (col_side != null) {
                    const ci: usize = switch (col_side.?.*) {
                        .column_idx => |c| c.idx,
                        .column => |name| t.find(name) orelse return false,
                        else => return false,
                    };
                    if (ci >= t.cols.len or t.data[ci] != .strs) return false;
                    const lit = str_side.?.string;
                    if (lit.len == 0) {
                        try list.append(alloc, .{ .nonempty = .{ .ci = @intCast(ci), .want_nonempty = b.op == .neq } });
                        return true;
                    }
                    if (ci < t.enc.len and t.enc[ci] != null) {
                        const enc = t.enc[ci].?;
                        const sd = t.data[ci].strs;
                        var id: i64 = -1;
                        for (enc.first, 0..) |row, k| {
                            if (std.mem.eql(u8, sd.at(row), lit)) {
                                id = @intCast(k);
                                break;
                            }
                        }
                        try list.append(alloc, .{ .dict_eq = .{ .ci = @intCast(ci), .id = id, .negated = b.op == .neq } });
                        return true;
                    }
                }
            }
            if (b.op == .lt or b.op == .le or b.op == .gt or b.op == .ge or b.op == .eq) {
                var col_side: ?*sql.Expr = null;
                var str_side: ?*sql.Expr = null;
                var flip = false;
                if (b.lhs.* == .string) {
                    str_side = b.lhs;
                    col_side = b.rhs;
                    flip = true;
                } else if (b.rhs.* == .string) {
                    str_side = b.rhs;
                    col_side = b.lhs;
                }
                if (col_side != null) {
                    const ci: usize = switch (col_side.?.*) {
                        .column_idx => |c| c.idx,
                        .column => |name| t.find(name) orelse return false,
                        else => return false,
                    };
                    if (ci >= t.cols.len or t.data[ci] != .strs) return false;
                    const rp = dictRankPos(t, ci, str_side.?.string) orelse return false;
                    const ndv: i64 = @intCast(t.enc[ci].?.byrank.len);
                    const k: i64 = @intCast(rp.k);
                    const op: sql.BinOp = if (!flip) b.op else switch (b.op) {
                        .lt => .gt,
                        .le => .ge,
                        .gt => .lt,
                        .ge => .le,
                        else => b.op,
                    };
                    var lo: i64 = 0;
                    var hi: i64 = ndv - 1;
                    switch (op) {
                        .eq => {
                            lo = k;
                            hi = if (rp.exists) k else -1;
                        },
                        .lt => hi = k - 1,
                        .le => hi = if (rp.exists) k else k - 1,
                        .gt => lo = if (rp.exists) k + 1 else k,
                        .ge => lo = k,
                        else => return false,
                    }
                    try list.append(alloc, .{ .dict_rank = .{ .ci = @intCast(ci), .lo = lo, .hi = hi } });
                    return true;
                }
            }
            return false;
        },
        .in_list => |x| {
            if (x.negated) return false;
            const ci: usize = switch (x.operand.*) {
                .column_idx => |c| c.idx,
                .column => |name| t.find(name) orelse return false,
                else => return false,
            };
            if (ci >= t.cols.len or !t.data[ci].isInt() or x.items.len > 32) return false;
            const vals = try alloc.alloc(i64, x.items.len);
            for (x.items, 0..) |it, k| switch (it.*) {
                .int => |v| vals[k] = v,
                .negate => |in| switch (in.*) {
                    .int => |v| vals[k] = -v,
                    else => return false,
                },
                else => return false,
            };
            try list.append(alloc, .{ .int_in = .{ .ci = @intCast(ci), .vals = vals } });
            return true;
        },
        .like => |l| {
            if (l.pattern.* != .string) return false;
            const ci: usize = switch (l.operand.*) {
                .column_idx => |c| c.idx,
                .column => |name| t.find(name) orelse return false,
                else => return false,
            };
            if (t.data[ci] != .strs) return false;
            const lit = l.pattern.string;
            if (lit.len < 3 or lit[0] != '%' or lit[lit.len - 1] != '%') return false;
            const inner = lit[1 .. lit.len - 1];
            for (inner) |ch| if (ch == '%' or ch == '_') return false;
            try list.append(alloc, .{ .like = .{ .ci = @intCast(ci), .lit = inner, .negated = l.negated } });
            return true;
        },
        else => return false,
    }
}
fn filterPredChain(t: *Table, alloc: std.mem.Allocator, preds: []const FastPred, out: *std.ArrayList(u32)) !void {
    const n = t.nrows;
    const nthreads = filterThreads();
    const W = struct {
        t: *Table,
        preds: []const FastPred,
        start: usize,
        end: usize,
        out: std.ArrayList(u32) = .empty,
        alloc: std.mem.Allocator,
        fn run(self: *@This()) void {
            var i = self.start;
            while (i < self.end) : (i += 1) {
                var ok = true;
                for (self.preds) |p| {
                    switch (p) {
                        .int_cmp => |c| {
                            if (c.ci >= self.t.data.len or !self.t.data[c.ci].isInt()) {
                                ok = false;
                                break;
                            }
                            if (c.ci < self.t.valid.len and self.t.valid[c.ci] != null and self.t.isNull(c.ci, i)) {
                                ok = false;
                                break;
                            }
                            const v = self.t.data[c.ci].intAt(i);
                            const hit = switch (c.op) {
                                .eq => v == c.k,
                                .neq => v != c.k,
                                .lt => v < c.k,
                                .le => v <= c.k,
                                .gt => v > c.k,
                                .ge => v >= c.k,
                                else => false,
                            };
                            if (!hit) {
                                ok = false;
                                break;
                            }
                        },
                        .dict_eq => |d| {
                            if (d.ci >= self.t.enc.len or self.t.enc[d.ci] == null) {
                                ok = false;
                                break;
                            }
                            if (d.ci < self.t.valid.len and self.t.valid[d.ci] != null and self.t.isNull(d.ci, i)) {
                                ok = false;
                                break;
                            }
                            const hit = if (d.id < 0) false else self.t.enc[d.ci].?.ids[i] == @as(u32, @intCast(d.id));
                            if (hit == d.negated) {
                                ok = false;
                                break;
                            }
                        },
                        .like => |l| {
                            const hay = self.t.data[l.ci].strs.at(i);
                            const hit = containsSub(hay, l.lit);
                            if (hit == l.negated) {
                                ok = false;
                                break;
                            }
                        },
                        .int_in => |c| {
                            const v = self.t.data[c.ci].intAt(i);
                            var hit = false;
                            for (c.vals) |x| {
                                if (v == x) {
                                    hit = true;
                                    break;
                                }
                            }
                            if (!hit) {
                                ok = false;
                                break;
                            }
                        },
                        .dict_rank => |d| {
                            if (d.ci >= self.t.enc.len or self.t.enc[d.ci] == null) {
                                ok = false;
                                break;
                            }
                            if (d.ci < self.t.valid.len and self.t.valid[d.ci] != null and self.t.isNull(d.ci, i)) {
                                ok = false;
                                break;
                            }
                            const e = self.t.enc[d.ci].?;
                            const r = e.rank[e.ids[i]];
                            if (r < d.lo or r > d.hi) {
                                ok = false;
                                break;
                            }
                        },
                        .nonempty => |ne| {
                            const hay = self.t.data[ne.ci].strs.at(i);
                            const nonempty = hay.len != 0;
                            if (nonempty != ne.want_nonempty) {
                                ok = false;
                                break;
                            }
                        },
                    }
                }
                if (ok) self.out.append(self.alloc, @intCast(i)) catch return;
            }
        }
    };
    const chunk = (n + nthreads - 1) / nthreads;
    var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
    defer alloc.free(arenas);
    var workers = try alloc.alloc(W, nthreads);
    defer alloc.free(workers);
    var threads = try alloc.alloc(?std.Thread, nthreads);
    defer alloc.free(threads);
    for (0..nthreads) |i| {
        const s0 = i * chunk;
        const e0 = @min(s0 + chunk, n);
        arenas[i] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        workers[i] = .{ .t = t, .preds = preds, .start = s0, .end = e0, .alloc = arenas[i].allocator() };
        threads[i] = null;
        threads[i] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{&workers[i]}) catch null;
        if (threads[i] == null and s0 < e0) W.run(&workers[i]);
    }
    for (0..nthreads) |i| if (threads[i]) |th| th.join();
    for (workers, 0..) |*w, i| {
        try out.appendSlice(alloc, w.out.items);
        arenas[i].deinit();
    }
}
fn gatherAnd(e: *sql.Expr, list: *std.ArrayList(*sql.Expr), alloc: std.mem.Allocator) !void {
    if (e.* == .binary and e.binary.op == .and_op) {
        try gatherAnd(e.binary.lhs, list, alloc);
        try gatherAnd(e.binary.rhs, list, alloc);
        return;
    }
    try list.append(alloc, e);
}
fn filterIndexedConjunct(t: *Table, alloc: std.mem.Allocator, e: *sql.Expr, out: *std.ArrayList(u32)) !bool {
    if (e.* != .binary or e.binary.op != .and_op) return false;
    var list = std.ArrayList(*sql.Expr).empty;
    defer list.deinit(alloc);
    try gatherAnd(e, &list, alloc);
    for (0..t.cols.len) |ci| {
        if (ci >= t.keyidx.len) continue;
        const idx = t.keyidx[ci] orelse continue;
        var lo: i64 = std.math.minInt(i64);
        var hi: i64 = std.math.maxInt(i64);
        var used_lo: ?usize = null;
        var used_hi: ?usize = null;
        for (list.items, 0..) |c, j| {
            const sp = intCmpSpec(t, c) orelse continue;
            if (sp.ci != ci) continue;
            switch (sp.op) {
                .eq => {
                    lo = sp.k;
                    hi = sp.k;
                    used_lo = j;
                    used_hi = j;
                },
                .gt => {
                    if (sp.k == std.math.maxInt(i64)) {
                        out.items.len = 0;
                        return true;
                    }
                    lo = sp.k + 1;
                    used_lo = j;
                },
                .ge => {
                    lo = sp.k;
                    used_lo = j;
                },
                .lt => {
                    if (sp.k == std.math.minInt(i64)) {
                        out.items.len = 0;
                        return true;
                    }
                    hi = sp.k - 1;
                    used_hi = j;
                },
                .le => {
                    hi = sp.k;
                    used_hi = j;
                },
                else => {},
            }
        }
        if (used_lo == null and used_hi == null) continue;
        if (lo > hi) {
            out.items.len = 0;
            return true;
        }
        const nkeys = idx.countKeysInRange(lo, hi);
        const avg_posting: usize = if (idx.keys.len > 0) idx.rows.len / idx.keys.len else 0;
        const est: usize = nkeys * @max(avg_posting, 1);
        const n: f64 = @floatFromInt(@max(t.nrows, 1));
        const matches: f64 = @floatFromInt(est);
        const keys_f: f64 = @floatFromInt(@max(nkeys, 1));
        const scan_cost = n * scanRowCost();
        const index_cost = cal_index_probe + matches * (cal_index_row + cal_query_str) +
            keys_f * COST_INDEX_KEY_NS + @log(keys_f + 1.0) * 64.0;
        const use_index = index_cost < scan_cost;
        var eqs: [32]usize = undefined;
        var neqs: usize = 0;
        if (lo == hi and ci < t.enc.len and t.enc[ci] != null) {
            eqs[0] = ci;
            neqs = 1;
        }
        for (list.items, 0..) |c2, j| {
            if (j == used_lo or j == used_hi) continue;
            const sp2 = intCmpSpec(t, c2) orelse continue;
            if (sp2.op != .eq) continue;
            var dup = false;
            for (eqs[0..neqs]) |ec| {
                if (ec == sp2.ci) {
                    dup = true;
                    break;
                }
            }
            if (!dup and neqs < eqs.len) {
                eqs[neqs] = sp2.ci;
                neqs += 1;
            }
        }
        for (0..neqs) |i| {
            for (i + 1..neqs) |j| _ = t.requestPairNdv(alloc, eqs[i], eqs[j]);
        }
        const m3 = @min(neqs, 4);
        for (0..m3) |i| {
            for (i + 1..m3) |j| {
                for (j + 1..m3) |k| _ = t.requestTripleNdv(alloc, eqs[i], eqs[j], eqs[k]);
            }
        }
        var joint_cols: [32]usize = undefined;
        var joint_n: usize = 0;
        var joint_ndv: usize = 0;
        var joint_triple = false;
        var joint_set = false;
        if (neqs >= 2) {
            const sn = t.requestMultiNdv(alloc, eqs[0..neqs]);
            if (sn > 0) {
                joint_ndv = sn;
                joint_n = neqs;
                for (eqs[0..neqs], 0..) |c, i| joint_cols[i] = c;
                joint_set = true;
            }
        }
        if (joint_ndv == 0 and neqs >= 3) {
            for (0..m3) |i| {
                for (i + 1..m3) |j| {
                    for (j + 1..m3) |k| {
                        const v = t.requestTripleNdv(alloc, eqs[i], eqs[j], eqs[k]);
                        if (v > 0 and (joint_ndv == 0 or v < joint_ndv)) {
                            joint_ndv = v;
                            joint_n = 3;
                            joint_cols[0] = eqs[i];
                            joint_cols[1] = eqs[j];
                            joint_cols[2] = eqs[k];
                            joint_triple = true;
                        }
                    }
                }
            }
        }
        if (joint_ndv == 0 and neqs >= 2) {
            for (0..neqs) |i| {
                for (i + 1..neqs) |j| {
                    const v = t.requestPairNdv(alloc, eqs[i], eqs[j]);
                    if (v > 0 and (joint_ndv == 0 or v < joint_ndv)) {
                        joint_ndv = v;
                        joint_n = 2;
                        joint_cols[0] = eqs[i];
                        joint_cols[1] = eqs[j];
                    }
                }
            }
        }
        var joint_ok = joint_ndv > 0;
        if (joint_ok) {
            for (joint_cols[0..joint_n]) |jc| {
                if (jc >= t.enc.len or t.enc[jc] == null) joint_ok = false;
            }
        }
        var sel_total: f64 = if (n > 0) @as(f64, @floatFromInt(est)) / n else 1.0;
        if (joint_ok) {
            var bound_in = false;
            for (joint_cols[0..joint_n]) |jc| {
                if (jc == ci) bound_in = true;
            }
            const nd_bound: f64 = if (bound_in)
                @floatFromInt(@max(t.enc[ci].?.first.len, 1))
            else
                1.0;
            const jn: f64 = @floatFromInt(joint_ndv);
            const joint_rows = if (bound_in)
                @as(f64, @floatFromInt(est)) * nd_bound / jn
            else
                @as(f64, @floatFromInt(est)) / jn;
            sel_total = joint_rows / n;
        }
        var residual_n: usize = 0;
        for (list.items, 0..) |c2, j| {
            if (j == used_lo or j == used_hi) continue;
            const sp2 = intCmpSpec(t, c2) orelse continue;
            var in_joint = false;
            for (joint_cols[0..joint_n]) |jc| {
                if (jc == sp2.ci) in_joint = true;
            }
            if (in_joint) continue;
            if (lo == hi and sp2.ci == ci) continue;
            residual_n += 1;
            const ndv2: f64 = if (sp2.ci < t.enc.len and t.enc[sp2.ci] != null)
                @floatFromInt(t.enc[sp2.ci].?.first.len)
            else
                @floatFromInt(@max(t.nrows / 100, 1));
            sel_total *= switch (sp2.op) {
                .eq => if (ndv2 > 0) 1.0 / ndv2 else 0.3,
                else => 0.3,
            };
        }
        const est_total: usize = @intFromFloat(@max(sel_total, 0.0) * n);
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] and-pushdown col={d} lo={d} hi={d} est_index={d} est_total={d} multi_ndv={s} joint_cols={d} index_cost={d:.0} scan_cost={d:.0} -> {s} (then {d} residual preds)\n", .{
                ci, lo, hi, est, est_total,
                if (!joint_ok) "independence" else if (joint_set) "jointN" else if (joint_triple) "joint3" else "joint",
                joint_n, index_cost, scan_cost,
                if (use_index) "index-range" else "scan", residual_n,
            });
        }
        if (!use_index) continue;
        try idx.range(alloc, lo, hi, out);
        var w: usize = 0;
        for (out.items) |rid| {
            var keep = true;
            for (list.items, 0..) |c2, j| {
                if (j == used_lo or j == used_hi) continue;
                if (!evalBool(t, c2, rid)) {
                    keep = false;
                    break;
                }
            }
            if (keep) {
                out.items[w] = rid;
                w += 1;
            }
        }
        out.items.len = w;
        return true;
    }
    return false;
}
const COST_SCAN_ROW_NS: f64 = 4.6;
const COST_INDEX_PROBE_NS: f64 = 1000.0;
const COST_INDEX_ROW_NS: f64 = 18.0;
const COST_INDEX_KEY_NS: f64 = 40.0;
const COST_STR_RAW_NS: f64 = 0.60;
const COST_STR_DICT_NS: f64 = 0.12;
var cal_scan_row: f64 = COST_SCAN_ROW_NS;
var cal_index_row: f64 = COST_INDEX_ROW_NS;
var cal_index_probe: f64 = COST_INDEX_PROBE_NS;
var cal_str_raw: f64 = COST_STR_RAW_NS;
var cal_str_dict: f64 = COST_STR_DICT_NS;
var cal_query_str: f64 = 0.0;
var last_query_nstr: u32 = 0;
var last_query_dict: bool = false;
threadlocal var semi_ci: ?usize = null;
threadlocal var semi_mask: ?[]const u8 = null;
threadlocal var semi_negated: bool = false;
threadlocal var semi_has_null: bool = false;
threadlocal var semi_est_rows: usize = 0;
pub fn setSemi(ci: usize, mask: []const u8, negated: bool, has_null: bool) void {
    semi_ci = ci;
    semi_mask = mask;
    semi_negated = negated;
    semi_has_null = has_null;
}
pub fn clearSemi() void {
    semi_ci = null;
    semi_mask = null;
    semi_negated = false;
    semi_has_null = false;
}
pub fn semiEstimate() usize {
    return semi_est_rows;
}
pub fn setSemiEstimate(n: usize) void {
    semi_est_rows = n;
}
fn hasInSubquery(e: *sql.Expr) bool {
    return switch (e.*) {
        .in_subquery => true,
        .exists => false,
        .binary => |b| hasInSubquery(b.lhs) or hasInSubquery(b.rhs),
        .negate => |x| hasInSubquery(x),
        .not => |x| hasInSubquery(x),
        .is_null => |x| hasInSubquery(x.operand),
        .like => |x| hasInSubquery(x.operand) or hasInSubquery(x.pattern),
        .in_list => |x| blk: {
            if (hasInSubquery(x.operand)) break :blk true;
            for (x.items) |it| if (hasInSubquery(it)) break :blk true;
            break :blk false;
        },
        .between => |x| hasInSubquery(x.operand) or hasInSubquery(x.low) or hasInSubquery(x.high),
        .call => |c| blk: {
            for (c.args) |a| if (hasInSubquery(a)) break :blk true;
            break :blk false;
        },
        .case_expr => |c| blk: {
            for (c.whens) |w| if (hasInSubquery(w.cond) or hasInSubquery(w.then)) break :blk true;
            if (c.else_expr) |x| if (hasInSubquery(x)) break :blk true;
            break :blk false;
        },
        .cast => |x| hasInSubquery(x.operand),
        else => false,
    };
}
pub fn setCosts(scan_row: f64, index_row: f64, index_probe: f64) void {
    cal_scan_row = scan_row;
    cal_index_row = index_row;
    cal_index_probe = index_probe;
}
pub fn setStrCosts(raw_row: f64, dict_row: f64) void {
    cal_str_raw = raw_row;
    cal_str_dict = dict_row;
}
pub fn strCosts() struct { raw: f64, dict: f64 } {
    return .{ .raw = cal_str_raw, .dict = cal_str_dict };
}
pub fn queryStrShape() struct { nstr: u32, dict: bool } {
    return .{ .nstr = last_query_nstr, .dict = last_query_dict };
}
fn scanRowCost() f64 {
    return cal_scan_row + cal_query_str;
}
pub fn measuredCosts() struct { f64, f64, f64 } {
    return .{ cal_scan_row, cal_index_row, cal_index_probe };
}
fn filterIntCmpNarrow(comptime T: type, t: *Table, alloc: std.mem.Allocator, ci: usize, vals: []const T, op: sql.BinOp, k: i64, out: *std.ArrayList(u32)) !void {
    const n = t.nrows;
    const nthreads = filterThreads();
    const W = struct {
        vals: []const T,
        op: sql.BinOp,
        k: i64,
        start: usize,
        end: usize,
        stats: ?[]const BlockStat,
        block_rows: usize,
        out: std.ArrayList(u32) = .empty,
        alloc: std.mem.Allocator,
        fn blockMayMatch(self: *@This(), b: usize) bool {
            const st = self.stats orelse return true;
            if (b >= st.len) return true;
            const sop: storage.Op = switch (self.op) {
                .eq => .eq,
                .neq => .neq,
                .lt => .lt,
                .gt => .gt,
                .le => .le,
                .ge => .ge,
                else => return true,
            };
            return storage.rangeMayMatch(st[b].min, st[b].max, sop, self.k);
        }
        fn run(self: *@This()) void {
            const br = self.block_rows;
            var b = self.start / br;
            while (b * br < self.end) : (b += 1) {
                const bs = @max(b * br, self.start);
                const be = @min((b + 1) * br, self.end);
                if (!self.blockMayMatch(b)) continue;
                var i = bs;
                while (i < be) : (i += 1) {
                    const v: i64 = self.vals[i];
                    const keep = switch (self.op) {
                        .eq => v == self.k,
                        .neq => v != self.k,
                        .lt => v < self.k,
                        .gt => v > self.k,
                        .le => v <= self.k,
                        .ge => v >= self.k,
                        else => false,
                    };
                    if (keep) self.out.append(self.alloc, @intCast(i)) catch return;
                }
            }
        }
    };
    const chunk = (n + nthreads - 1) / nthreads;
    const stats = t.stats[ci];
    var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
    defer alloc.free(arenas);
    var workers = try alloc.alloc(W, nthreads);
    defer alloc.free(workers);
    var threads = try alloc.alloc(?std.Thread, nthreads);
    defer alloc.free(threads);
    for (0..nthreads) |i| {
        const s0 = i * chunk;
        const e0 = @min(s0 + chunk, n);
        arenas[i] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        workers[i] = .{ .vals = vals, .op = op, .k = k, .start = s0, .end = e0, .alloc = arenas[i].allocator(), .stats = stats, .block_rows = t.block_rows };
        threads[i] = null;
        threads[i] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{&workers[i]}) catch null;
        if (threads[i] == null and s0 < e0) W.run(&workers[i]);
    }
    for (0..nthreads) |i| if (threads[i]) |th| th.join();
    for (workers, 0..) |*w, i| {
        try out.appendSlice(alloc, w.out.items);
        arenas[i].deinit();
    }
}
fn filterIntCmp(t: *Table, alloc: std.mem.Allocator, ci: usize, op: sql.BinOp, k: i64, out: *std.ArrayList(u32)) !void {
    switch (t.data[ci]) {
        .ints8 => |a| return filterIntCmpNarrow(i8, t, alloc, ci, a, op, k, out),
        .ints16 => |a| return filterIntCmpNarrow(i16, t, alloc, ci, a, op, k, out),
        .ints32 => |a| return filterIntCmpNarrow(i32, t, alloc, ci, a, op, k, out),
        .ints => {},
        else => return,
    }
    const vals: []const i64 = t.data[ci].ints;
    if (t.keyidx.len > ci) {
        if (t.keyidx[ci]) |idx| {
            if (op != .neq) {
                var lo: i64 = std.math.minInt(i64);
                var hi: i64 = std.math.maxInt(i64);
                var empty = false;
                switch (op) {
                    .eq => {
                        lo = k;
                        hi = k;
                    },
                    .lt => {
                        if (k == std.math.minInt(i64)) empty = true else hi = k - 1;
                    },
                    .le => hi = k,
                    .gt => {
                        if (k == std.math.maxInt(i64)) empty = true else lo = k + 1;
                    },
                    .ge => lo = k,
                    else => {},
                }
                if (empty) return;
                const nkeys = idx.countKeysInRange(lo, hi);
                const avg_posting: usize = if (idx.keys.len > 0) idx.rows.len / idx.keys.len else 0;
                const est: usize = nkeys * @max(avg_posting, 1);
                const n: f64 = @floatFromInt(@max(t.nrows, 1));
                const matches: f64 = @floatFromInt(est);
                const keys_f: f64 = @floatFromInt(@max(nkeys, 1));
                const scan_cost = n * scanRowCost();
                const index_cost = cal_index_probe + matches * (cal_index_row + cal_query_str) +
                    keys_f * COST_INDEX_KEY_NS + @log(keys_f + 1.0) * 64.0;
                const use_index = index_cost < scan_cost;
                if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                    std.debug.print("[plan] filter col={d} op={s} rows={d} est={d} sel={d:.3} index_cost={d:.0} scan_cost={d:.0} -> {s}\n", .{
                        ci, @tagName(op), t.nrows, est, matches / n, index_cost, scan_cost, if (use_index) "index-range" else "scan",
                    });
                }
                if (!use_index) {
                } else {
                var tmp = std.ArrayList(u32).empty;
                defer tmp.deinit(alloc);
                try idx.range(alloc, lo, hi, &tmp);
                std.mem.sort(u32, tmp.items, {}, std.sort.asc(u32));
                const before = out.items.len;
                for (tmp.items) |rid| {
                    const v = vals[rid];
                    const keep = switch (op) {
                        .eq => v == k,
                        .lt => v < k,
                        .le => v <= k,
                        .gt => v > k,
                        .ge => v >= k,
                        else => false,
                    };
                    if (keep) try out.append(alloc, rid);
                }
                if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                    std.debug.print("[plan] index-range actual={d} (est={d})\n", .{ out.items.len - before, est });
                }
                return;
                }
            }
        }
    }
    const n = t.nrows;
    const V = @Vector(2, i64);
    const kv: V = @splat(k);
    const nthreads = filterThreads();
    const W = struct {
        vals: []const i64,
        kv: V,
        op: sql.BinOp,
        start: usize,
        end: usize,
        stats: ?[]const BlockStat,
        valid: ?[]const u8,
        block_rows: usize,
        out: std.ArrayList(u32) = .empty,
        alloc: std.mem.Allocator,
        fn blockMayMatch(self: *@This(), b: usize) bool {
            const st = self.stats orelse return true;
            if (b >= st.len) return true;
            const kk = self.kv[0];
            const sop: storage.Op = switch (self.op) {
                .eq => .eq,
                .neq => .neq,
                .lt => .lt,
                .gt => .gt,
                .le => .le,
                .ge => .ge,
                else => return true,
            };
            return storage.rangeMayMatch(st[b].min, st[b].max, sop, kk);
        }
        fn run(self: *@This()) void {
            if (self.stats != null) {
                const br = self.block_rows;
                var b = self.start / br;
                while (b * br < self.end) : (b += 1) {
                    const bs = @max(b * br, self.start);
                    const be = @min((b + 1) * br, self.end);
                    if (!self.blockMayMatch(b)) continue;
                    var i = bs;
                    while (i < be) : (i += 1) {
                        if (self.valid) |vf| {
                            if (vf[i] == 0) continue;
                        }
                        const v = self.vals[i];
                        const keep = switch (self.op) {
                            .eq => v == self.kv[0],
                            .neq => v != self.kv[0],
                            .lt => v < self.kv[0],
                            .gt => v > self.kv[0],
                            .le => v <= self.kv[0],
                            .ge => v >= self.kv[0],
                            else => unreachable,
                        };
                        if (keep) self.out.append(self.alloc, @intCast(i)) catch return;
                    }
                }
                return;
            }
            var i = self.start;
            while (i + 2 <= self.end) : (i += 2) {
                if (self.valid) |vf| {
                    if ((vf[i / 8] >> @intCast(i % 8)) & 1 == 0) continue;
                }
                const v: V = self.vals[i..][0..2].*;
                const m: @Vector(2, bool) = switch (self.op) {
                    .eq => v == self.kv,
                    .neq => v != self.kv,
                    .lt => v < self.kv,
                    .gt => v > self.kv,
                    .le => v <= self.kv,
                    .ge => v >= self.kv,
                    else => unreachable,
                };
                const bits: u2 = @bitCast(m);
                if (bits & 1 != 0) self.out.append(self.alloc, @intCast(i)) catch return;
                if (bits & 2 != 0) self.out.append(self.alloc, @intCast(i + 1)) catch return;
            }
            while (i < self.end) : (i += 1) {
                const v = self.vals[i];
                const keep = switch (self.op) {
                    .eq => v == self.kv[0],
                    .neq => v != self.kv[0],
                    .lt => v < self.kv[0],
                    .gt => v > self.kv[0],
                    .le => v <= self.kv[0],
                    .ge => v >= self.kv[0],
                    else => unreachable,
                };
                if (keep) self.out.append(self.alloc, @intCast(i)) catch return;
            }
        }
    };
    const chunk = (n + nthreads - 1) / nthreads;
    const stats = t.stats[ci];
    var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
    defer alloc.free(arenas);
    var workers = try alloc.alloc(W, nthreads);
    defer alloc.free(workers);
    var threads = try alloc.alloc(?std.Thread, nthreads);
    defer alloc.free(threads);
    for (0..nthreads) |i| {
        const s0 = i * chunk;
        const e0 = @min(s0 + chunk, n);
        arenas[i] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        workers[i] = .{ .vals = vals, .kv = kv, .op = op, .start = s0, .end = e0, .alloc = arenas[i].allocator(), .stats = stats, .valid = (if (ci < t.valid.len) t.valid[ci] else null), .block_rows = t.block_rows };
        threads[i] = null;
        threads[i] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{&workers[i]}) catch null;
        if (threads[i] == null and s0 < e0) W.run(&workers[i]);
    }
    for (0..nthreads) |i| if (threads[i]) |th| th.join();
    for (workers, 0..) |*w, i| {
        try out.appendSlice(alloc, w.out.items);
        arenas[i].deinit();
    }
}
fn intCmpSpec(t: *const Table, e: *sql.Expr) ?struct { ci: u32, op: sql.BinOp, k: i64 } {
    if (e.* != .binary) return null;
    const b = e.binary;
    switch (b.op) {
        .eq, .neq, .lt, .gt, .le, .ge => {},
        else => return null,
    }
    var col_side: ?*sql.Expr = null;
    var num_side: ?*sql.Expr = null;
    if (b.lhs.* == .int) {
        num_side = b.lhs;
        col_side = b.rhs;
    } else if (b.rhs.* == .int) {
        num_side = b.rhs;
        col_side = b.lhs;
    }
    const cs = col_side orelse return null;
    const ns = num_side orelse return null;
    const ci: usize = switch (cs.*) {
        .column_idx => |c| c.idx,
        .column => |name| t.find(name) orelse return null,
        else => return null,
    };
    if (!t.data[ci].isInt()) return null;
    const k: i64 = switch (ns.*) {
        .int => |v| v,
        .negate => |inner| switch (inner.*) {
            .int => |v| -v,
            else => return null,
        },
        else => return null,
    };
    var op = b.op;
    if (b.lhs.* == .int) op = switch (op) {
        .lt => .gt,
        .gt => .lt,
        .le => .ge,
        .ge => .le,
        else => op,
    };
    return .{ .ci = @intCast(ci), .op = op, .k = k };
}
fn fastLikeSpec(t: *const Table, e: *sql.Expr) ?struct { ci: u32, lit: []const u8, negated: bool } {
    if (e.* != .like) return null;
    const l = e.like;
    if (l.pattern.* != .string) return null;
    const ci: usize = switch (l.operand.*) {
        .column_idx => |c| c.idx,
        .column => |name| t.find(name) orelse return null,
        else => return null,
    };
    if (t.data[ci] != .strs) return null;
    const lit = l.pattern.string;
    if (lit.len < 3 or lit[0] != '%' or lit[lit.len - 1] != '%') return null;
    const inner = lit[1 .. lit.len - 1];
    for (inner) |ch| if (ch == '%' or ch == '_') return null;
    return .{ .ci = @intCast(ci), .lit = inner, .negated = l.negated };
}
fn filterLikeConst(t: *Table, alloc: std.mem.Allocator, spec: anytype, out: *std.ArrayList(u32)) !void {
    const n = t.nrows;
    const strs = t.data[spec.ci].strs;
    const nthreads = filterThreads();
    const W = struct {
        strs: StrData,
        lit: []const u8,
        neg: bool,
        start: usize,
        end: usize,
        out: std.ArrayList(u32) = .empty,
        alloc: std.mem.Allocator,
        fn run(self: *@This()) void {
            var i = self.start;
            while (i < self.end) : (i += 1) {
                const hay = self.strs.at(i);
                const hit = containsSub(hay, self.lit);
                if (hit != self.neg) self.out.append(self.alloc, @intCast(i)) catch return;
            }
        }
    };
    const chunk = (n + nthreads - 1) / nthreads;
    var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
    defer alloc.free(arenas);
    var workers = try alloc.alloc(W, nthreads);
    defer alloc.free(workers);
    var threads = try alloc.alloc(?std.Thread, nthreads);
    defer alloc.free(threads);
    for (0..nthreads) |i| {
        const s0 = i * chunk;
        const e0 = @min(s0 + chunk, n);
        arenas[i] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        workers[i] = .{ .strs = strs, .lit = spec.lit, .neg = spec.negated, .start = s0, .end = e0, .alloc = arenas[i].allocator() };
        threads[i] = null;
        threads[i] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{&workers[i]}) catch null;
        if (threads[i] == null and s0 < e0) W.run(&workers[i]);
    }
    for (0..nthreads) |i| if (threads[i]) |th| th.join();
    for (workers, 0..) |*w, i| {
        try out.appendSlice(alloc, w.out.items);
        arenas[i].deinit();
    }
}
fn filterThreads() usize {
    if (std.c.getenv("ZHDB_SERIAL_FILTER") != null) return 1;
    return @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
}
fn findSemiLeaf(e: *sql.Expr) ?*sql.Expr {
    if (e.* == .in_subquery) return e;
    if (e.* == .not) return findSemiLeaf(e.not);
    if (e.* == .binary) {
        return findSemiLeaf(e.binary.lhs) orelse findSemiLeaf(e.binary.rhs);
    }
    return null;
}
fn semiUnderAnd(e: *sql.Expr) ?*sql.Expr {
    if (isSemiNode(e)) return e;
    if (e.* == .binary and e.binary.op == .and_op) {
        return semiUnderAnd(e.binary.lhs) orelse semiUnderAnd(e.binary.rhs);
    }
    return null;
}
fn isSemiNode(e: *sql.Expr) bool {
    if (e.* == .in_subquery) return true;
    if (e.* == .not and e.not.* == .in_subquery) return true;
    return false;
}
fn semiShapeOk(e: *sql.Expr) bool {
    if (isSemiNode(e)) return true;
    if (e.* == .binary and (e.binary.op == .and_op or e.binary.op == .or_op)) {
        return semiShapeOk(e.binary.lhs) and semiShapeOk(e.binary.rhs);
    }
    if (e.* == .not) return semiShapeOk(e.not);
    return supportedExpr(e);
}
fn evalSemiTree(t: *Table, e: *sql.Expr, ri: usize) bool {
    if (isSemiNode(e)) {
        const ci = semi_ci orelse return false;
        if (ci >= t.enc.len or t.enc[ci] == null) return false;
        if (ci < t.valid.len and t.valid[ci] != null and t.isNull(ci, ri)) return false;
        const negated = if (e.* == .not) !e.not.in_subquery.negated else e.in_subquery.negated;
        if (negated and semi_has_null) return false;
        const mask = semi_mask orelse return false;
        const id = t.enc[ci].?.ids[ri];
        const in_set = id >= 0 and @as(usize, @intCast(id)) < mask.len and mask[@intCast(id)] != 0;
        return if (negated) !in_set else in_set;
    }
    if (e.* == .binary) {
        switch (e.binary.op) {
            .and_op => return evalSemiTree(t, e.binary.lhs, ri) and evalSemiTree(t, e.binary.rhs, ri),
            .or_op => return evalSemiTree(t, e.binary.lhs, ri) or evalSemiTree(t, e.binary.rhs, ri),
            else => {},
        }
    }
    if (e.* == .not) return !evalSemiTree(t, e.not, ri);
    return evalBool(t, e, ri);
}
fn filterSemiScan(t: *Table, alloc: std.mem.Allocator, e: *sql.Expr, out: *std.ArrayList(u32)) !void {
    try out.ensureTotalCapacity(alloc, t.nrows);
    var ri: usize = 0;
    while (ri < t.nrows) : (ri += 1) {
        if (!evalSemiTree(t, e, ri)) continue;
        out.appendAssumeCapacity(@intCast(ri));
    }
    if (std.c.getenv("ZHDB_EXPLAIN") != null) {
        std.debug.print("[plan] semi-scan rows={d} hits={d} est_rows={d}\n", .{ t.nrows, out.items.len, semi_est_rows });
    }
}
fn keepSelection(t: *Table, sel: *std.ArrayList(u32), e: *sql.Expr) void {
    if (intCmpSpec(t, e)) |spec| {
        if (spec.ci >= t.data.len or !t.data[spec.ci].isInt()) return;
        const vals = &t.data[spec.ci];
        const has_nulls = spec.ci < t.valid.len and t.valid[spec.ci] != null;
        var w: usize = 0;
        for (sel.items) |ri| {
            if (has_nulls and t.isNull(spec.ci, ri)) continue;
            const v = vals.intAt(ri);
            const hit = switch (spec.op) {
                .eq => v == spec.k,
                .neq => v != spec.k,
                .lt => v < spec.k,
                .le => v <= spec.k,
                .gt => v > spec.k,
                .ge => v >= spec.k,
                else => false,
            };
            if (!hit) continue;
            sel.items[w] = ri;
            w += 1;
        }
        sel.items.len = w;
        return;
    }
    if (dictEqSpec(t, e)) |spec| {
        const ids = t.enc[spec.ci].?.ids;
        const has_nulls = spec.ci < t.valid.len and t.valid[spec.ci] != null;
        var w: usize = 0;
        for (sel.items) |ri| {
            if (has_nulls and t.isNull(spec.ci, ri)) continue;
            if (spec.id < 0 or ids[ri] != spec.id) continue;
            sel.items[w] = ri;
            w += 1;
        }
        sel.items.len = w;
        return;
    }
    var w: usize = 0;
    for (sel.items) |ri| {
        if (!evalBool(t, e, ri)) continue;
        sel.items[w] = ri;
        w += 1;
    }
    sel.items.len = w;
}
fn applyResiduals(t: *Table, sel: *std.ArrayList(u32), e: *sql.Expr, skip: ?*sql.Expr) void {
    if (e.* == .binary and e.binary.op == .and_op) {
        applyResiduals(t, sel, e.binary.lhs, skip);
        applyResiduals(t, sel, e.binary.rhs, skip);
        return;
    }
    if (skip != null and e == skip.?) return;
    keepSelection(t, sel, e);
}
fn filterSemiAnd(t: *Table, alloc: std.mem.Allocator, e: *sql.Expr, out: *std.ArrayList(u32)) !void {
    const leaf = findSemiLeaf(e) orelse return error.BadSemiMask;
    const mask = semi_mask orelse return error.BadSemiMask;
    try filterSemi(t, alloc, mask, out);
    applyResiduals(t, out, e, leaf);
}
fn filterSemi(t: *Table, alloc: std.mem.Allocator, mask: []const u8, out: *std.ArrayList(u32)) !void {
    const ci = semi_ci orelse return error.BadSemiMask;
    if (ci >= t.enc.len or t.enc[ci] == null) return error.BadSemiMask;
    if (semi_negated and semi_has_null) return;
    const enc = t.enc[ci].?;
    const ids = enc.ids;
    const has_nulls = t.valid.len > ci and t.valid[ci] != null;
    try out.ensureTotalCapacity(alloc, ids.len);
    var ri: usize = 0;
    while (ri < ids.len) : (ri += 1) {
        const id = ids[ri];
        if (id < 0 or @as(usize, @intCast(id)) >= mask.len) continue;
        if (has_nulls and t.isNull(ci, ri)) continue;
        const in_set = mask[@intCast(id)] != 0;
        if (in_set == semi_negated) continue;
        out.appendAssumeCapacity(@intCast(ri));
    }
    if (std.c.getenv("ZHDB_EXPLAIN") != null) {
        std.debug.print("[plan] semi-mask col={d} ids={d} est_rows={d} negated={}\n", .{
            ci, enc.first.len, semi_est_rows, semi_negated,
        });
    }
}
const DictEq = struct { ci: usize, id: i64 };
fn dictEqSpec(t: *Table, e: *sql.Expr) ?DictEq {
    if (e.* != .binary) return null;
    const b = e.binary;
    if (b.op != .eq) return null;
    var lit: ?[]const u8 = null;
    var ci: ?usize = null;
    if (b.rhs.* == .string) {
        lit = b.rhs.string;
        ci = rootColumnIndex(t, b.lhs);
    } else if (b.lhs.* == .string) {
        lit = b.lhs.string;
        ci = rootColumnIndex(t, b.rhs);
    }
    const c = ci orelse return null;
    if (c >= t.cols.len or t.cols[c].kind != .str) return null;
    if (c >= t.enc.len or t.enc[c] == null) return null;
    if (t.data[c] != .strs) return null;
    const enc = t.enc[c].?;
    const sd = t.data[c].strs;
    var id: i64 = -1;
    for (enc.first, 0..) |row, k| {
        if (std.mem.eql(u8, sd.at(row), lit.?)) {
            id = @intCast(k);
            break;
        }
    }
    return .{ .ci = c, .id = id };
}
const DictIn = struct { ci: usize, ids: []i64, negated: bool };
fn dictInSpec(t: *Table, e: *sql.Expr, alloc: std.mem.Allocator) !?DictIn {
    if (e.* != .in_list) return null;
    const l = e.in_list;
    if (l.items.len == 0) return null;
    const ci = rootColumnIndex(t, l.operand) orelse return null;
    if (ci >= t.cols.len or t.cols[ci].kind != .str) return null;
    if (ci >= t.enc.len or t.enc[ci] == null) return null;
    if (t.data[ci] != .strs) return null;
    const enc = t.enc[ci].?;
    const sd = t.data[ci].strs;
    var ids = try alloc.alloc(i64, l.items.len);
    var n: usize = 0;
    for (l.items) |it| {
        if (it.* != .string) return null;
        const lit = it.string;
        var id: i64 = -1;
        for (enc.first, 0..) |row, k| {
            if (std.mem.eql(u8, sd.at(row), lit)) {
                id = @intCast(k);
                break;
            }
        }
        if (id >= 0) {
            ids[n] = id;
            n += 1;
        }
    }
    return .{ .ci = ci, .ids = ids[0..n], .negated = l.negated };
}
fn filterDictIn(t: *Table, alloc: std.mem.Allocator, spec: DictIn, out: *std.ArrayList(u32)) !void {
    const enc = t.enc[spec.ci].?;
    const ndict = enc.first.len;
    if (ndict == 0) return;
    const keep = try alloc.alloc(u8, ndict);
    defer alloc.free(keep);
    @memset(keep, if (spec.negated) 1 else 0);
    for (spec.ids) |id| {
        if (id >= 0 and id < ndict) keep[@intCast(id)] = if (spec.negated) 0 else 1;
    }
    const has_nulls = t.valid.len > spec.ci and t.valid[spec.ci] != null;
    const ids = enc.ids;
    try out.ensureTotalCapacity(alloc, ids.len);
    var ri: usize = 0;
    while (ri < ids.len) : (ri += 1) {
        if (has_nulls and t.isNull(spec.ci, ri)) continue;
        const id = ids[ri];
        if (id < 0) continue;
        if (keep[@intCast(id)] == 0) continue;
        out.appendAssumeCapacity(@intCast(ri));
    }
}
fn filterDictEq(t: *Table, alloc: std.mem.Allocator, ci: usize, id: i64, out: *std.ArrayList(u32)) !void {
    if (id < 0) return; // literal absent from the dictionary -> empty selection
    const ids = t.enc[ci].?.ids;
    const has_nulls = t.valid.len > ci and t.valid[ci] != null;
    try out.ensureTotalCapacity(alloc, ids.len);
    var ri: usize = 0;
    while (ri < ids.len) : (ri += 1) {
        if (ids[ri] != id) continue;
        if (has_nulls and t.isNull(ci, ri)) continue;
        out.appendAssumeCapacity(@intCast(ri));
    }
}
fn filter(t: *Table, alloc: std.mem.Allocator, e: *sql.Expr, out: *std.ArrayList(u32)) !void {
    if (semi_mask) |mask| {
        if (isSemiNode(e)) {
            try filterSemi(t, alloc, mask, out);
            return;
        }
        if (hasInSubquery(e)) {
            if (e.* == .binary and e.binary.op == .and_op and semiUnderAnd(e) != null) {
                try filterSemiAnd(t, alloc, e, out);
            } else {
                try filterSemiScan(t, alloc, e, out);
            }
            return;
        }
    }
    if (try filterIndexedConjunct(t, alloc, e, out)) return;
    if (std.c.getenv("ZHDB_NO_DICT_FILTER") == null) {
        if (dictEqSpec(t, e)) |spec| {
            try filterDictEq(t, alloc, spec.ci, spec.id, out);
            return;
        }
        if (try dictInSpec(t, e, alloc)) |spec| {
            try filterDictIn(t, alloc, spec, out);
            return;
        }
    }
    if (intCmpSpec(t, e)) |spec| {
        try filterIntCmp(t, alloc, spec.ci, spec.op, spec.k, out);
        return;
    }
    if (fastLikeSpec(t, e)) |spec| {
        try filterLikeConst(t, alloc, spec, out);
        return;
    }
    {
        var preds = std.ArrayList(FastPred).empty;
        defer preds.deinit(alloc);
        if (try collectFastPreds(t, e, &preds, alloc)) {
            if (preds.items.len > 0) {
                std.mem.sort(FastPred, preds.items, {}, struct {
                    fn rank(p: FastPred) u8 {
                        return switch (p) {
                            .int_cmp, .dict_eq => 0,
                            .int_in => 1,
                            .dict_rank => 1,
                            .nonempty => 2,
                            .like => 3,
                        };
                    }
                    fn less(_: void, a: FastPred, b: FastPred) bool {
                        return rank(a) < rank(b);
                    }
                }.less);
                try filterPredChain(t, alloc, preds.items, out);
                return;
            }
        }
    }
    const n = t.nrows;
    const nthreads = filterThreads();
    if (n < 100_000) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (evalBool(t, e, i)) try out.append(alloc, @intCast(i));
        }
        return;
    }
    const Worker = struct {
        t: *Table,
        e: *sql.Expr,
        start: usize,
        end: usize,
        out: std.ArrayList(u32) = .empty,
        alloc: std.mem.Allocator,
        fn run(self: *@This()) void {
            var i = self.start;
            while (i < self.end) : (i += 1) {
                if (evalBool(self.t, self.e, i)) self.out.append(self.alloc, @intCast(i)) catch return;
            }
        }
    };
    const chunk = (n + nthreads - 1) / nthreads;
    var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
    defer alloc.free(arenas);
    var workers = try alloc.alloc(Worker, nthreads);
    defer alloc.free(workers);
    var threads = try alloc.alloc(?std.Thread, nthreads);
    defer alloc.free(threads);
    for (0..nthreads) |i| {
        const s = i * chunk;
        const en = @min(s + chunk, n);
        arenas[i] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        workers[i] = .{ .t = t, .e = e, .start = s, .end = en, .alloc = arenas[i].allocator() };
        threads[i] = null;
        threads[i] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, Worker.run, .{&workers[i]}) catch null;
        if (threads[i] == null and s < en) Worker.run(&workers[i]);
    }
    for (0..nthreads) |i| if (threads[i]) |th| th.join();
    for (workers, 0..) |*w, i| {
        try out.appendSlice(alloc, w.out.items);
        arenas[i].deinit();
    }
}
fn topKInt(
    t: *Table,
    alloc: std.mem.Allocator,
    ci: usize,
    desc: bool,
    rows: *std.ArrayList(u32),
    k: usize,
) !void {
    const vals: []const i64 = try t.intsView(alloc, ci);
    const K = struct { key: i64, ri: u32 };
    var best = std.ArrayList(K).empty;
    defer best.deinit(alloc);
    for (rows.items) |ri| {
        const key = vals[ri];
        if (best.items.len == k) {
            const worst = best.items[k - 1].key;
            const better = if (desc) key > worst else key < worst;
            if (!better) continue;
            _ = best.pop();
        }
        var at: usize = 0;
        while (at < best.items.len) : (at += 1) {
            const cur = best.items[at].key;
            const after = if (desc) key > cur else key < cur;
            if (after) break;
        }
        try best.insert(alloc, at, .{ .key = key, .ri = ri });
    }
    rows.clearRetainingCapacity();
    for (best.items) |b| try rows.append(alloc, b.ri);
}
fn topKRank(
    t: *Table,
    alloc: std.mem.Allocator,
    enc: Encoding,
    desc: bool,
    rows: *std.ArrayList(u32),
    k: usize,
) !void {
    _ = t;
    const K = struct { key: u32, ri: u32 };
    var best = std.ArrayList(K).empty;
    defer best.deinit(alloc);
    for (rows.items) |ri| {
        const key = enc.rank[@intCast(enc.ids[ri])];
        if (best.items.len == k) {
            const worst = best.items[k - 1].key;
            const better = if (desc) key > worst else key < worst;
            if (!better) continue;
            _ = best.pop();
        }
        var at: usize = 0;
        while (at < best.items.len) : (at += 1) {
            const cur = best.items[at].key;
            const after = if (desc) key > cur else key < cur;
            if (after) break;
        }
        try best.insert(alloc, at, .{ .key = key, .ri = ri });
    }
    rows.clearRetainingCapacity();
    for (best.items) |b| try rows.append(alloc, b.ri);
}
fn topKIntRank(
    t: *Table,
    alloc: std.mem.Allocator,
    ci: usize,
    enc: Encoding,
    desc: bool,
    rows: *std.ArrayList(u32),
    k: usize,
) !void {
    const vals: []const i64 = try t.intsView(alloc, ci);
    const K = struct { ki: i64, kr: u32, ri: u32 };
    var best = std.ArrayList(K).empty;
    defer best.deinit(alloc);
    for (rows.items) |ri| {
        const ki = vals[ri];
        const kr = enc.rank[@intCast(enc.ids[ri])];
        if (best.items.len == k) {
            const w = best.items[k - 1];
            const better = if (desc) (ki > w.ki or (ki == w.ki and kr > w.kr)) else (ki < w.ki or (ki == w.ki and kr < w.kr));
            if (!better) continue;
            _ = best.pop();
        }
        var at: usize = 0;
        while (at < best.items.len) : (at += 1) {
            const cur = best.items[at];
            const after = if (desc) (ki > cur.ki or (ki == cur.ki and kr > cur.kr)) else (ki < cur.ki or (ki == cur.ki and kr < cur.kr));
            if (after) break;
        }
        try best.insert(alloc, at, .{ .ki = ki, .kr = kr, .ri = ri });
    }
    rows.clearRetainingCapacity();
    for (best.items) |b| try rows.append(alloc, b.ri);
}
fn projectRows(t: *Table, alloc: std.mem.Allocator, sel: *sql.Select, selection: []u32) !?QueryResult {
    var rows = std.ArrayList([]Value).empty;
    defer rows.deinit(alloc);
    var cols = std.ArrayList([]const u8).empty;
    defer cols.deinit(alloc);
    var idx_list = std.ArrayList(u32).empty;
    defer idx_list.deinit(alloc);
    try idx_list.appendSlice(alloc, selection);
    if (sel.order_by.len > 0) {
        for (sel.order_by) |o| if (!supportedOrder(t, o.expr, sel)) return null;
        const limit = if (sel.limit) |l| exprUsize(t, l) else null;
        const offset = if (sel.offset) |o| exprUsize(t, o) else 0;
        if (limit) |lim| {
            const k = lim + offset;
            var done = false;
            if (sel.order_by.len == 2 and k * 4 < idx_list.items.len and !sel.order_by[0].desc and !sel.order_by[1].desc) {
                const c0: ?usize = switch (sel.order_by[0].expr.*) {
                    .column_idx => |x| x.idx,
                    .column => |name| t.find(name),
                    else => null,
                };
                const c1: ?usize = switch (sel.order_by[1].expr.*) {
                    .column_idx => |x| x.idx,
                    .column => |name| t.find(name),
                    else => null,
                };
                if (c0 != null and c1 != null) {
                    const ci0 = c0.?;
                    const ci1 = c1.?;
                    if (t.data[ci0].isInt()) {
                        if (t.enc[ci1]) |e1| {
                            if (e1.rank.len > 0) {
                                try topKIntRank(t, alloc, ci0, e1, false, &idx_list, k);
                                done = true;
                            }
                        }
                    }
                }
            }
            if (!done and sel.order_by.len == 1 and k * 4 < idx_list.items.len) {
                const item = sel.order_by[0];
                const ci: ?usize = switch (item.expr.*) {
                    .column_idx => |c| c.idx,
                    .column => |name| t.find(name),
                    else => null,
                };
                if (ci) |cci| {
                    if (t.data[cci] == .ints) {
                        try topKInt(t, alloc, cci, item.desc, &idx_list, k);
                        done = true;
                    } else if (t.enc[cci]) |e| {
                        if (e.rank.len > 0) {
                            try topKRank(t, alloc, e, item.desc, &idx_list, k);
                            done = true;
                        }
                    }
                }
            }
            if (done) {
            } else if (k * 4 < idx_list.items.len) {
                if (!try topKFast(t, alloc, sel, &idx_list, k)) {
                    try topK(t, alloc, sel, &idx_list, k);
                }
            } else {
                std.mem.sort(u32, idx_list.items, SortCtx{ .t = t, .sel = sel }, orderLess);
            }
        } else {
            std.mem.sort(u32, idx_list.items, SortCtx{ .t = t, .sel = sel }, orderLess);
        }
    }
    var start: usize = if (sel.offset) |o| exprUsize(t, o) else 0;
    var end: usize = idx_list.items.len;
    if (sel.limit) |l| {
        const lim = exprUsize(t, l);
        if (start + lim < end) end = start + lim;
    }
    if (start > end) start = end;
    for (idx_list.items[start..end]) |ri| {
        var row = std.ArrayList(Value).empty;
        for (sel.items) |it| {
            if (it.expr.* == .star) {
                for (t.cols, 0..) |c, ci| {
                    _ = c;
                    try row.append(alloc, cellValue(t, ci, ri));
                }
            } else {
                try row.append(alloc, toValue(evalScalar(t, it.expr, ri)));
            }
        }
        try rows.append(alloc, try row.toOwnedSlice(alloc));
    }
    if (sel.distinct) {
        var seen = std.StringHashMap(void).init(alloc);
        defer seen.deinit();
        var uniq = std.ArrayList([]Value).empty;
        defer uniq.deinit(alloc);
        for (rows.items) |r| {
            const key = try distinctRowKey(alloc, r);
            const gop = try seen.getOrPut(key);
            if (!gop.found_existing) try uniq.append(alloc, r);
        }
        rows.deinit(alloc);
        rows = uniq;
    }
    if (sel.items.len > 0 and sel.items[0].expr.* == .star) {
        for (t.cols) |c| try cols.append(alloc, c.name);
    } else {
        for (sel.items) |it| try cols.append(alloc, it.alias orelse exprLabel(it.expr));
    }
    return .{ .columns = try cols.toOwnedSlice(alloc), .rows = try rows.toOwnedSlice(alloc), .format_json = sel.format_json };
}
fn distinctRowKey(alloc: std.mem.Allocator, row: []const Value) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (row) |v| {
        switch (v) {
            .null => try out.append(alloc, 0),
            .int => |x| {
                try out.append(alloc, 1);
                try out.appendSlice(alloc, std.mem.asBytes(&x));
            },
            .float => |f| {
                try out.append(alloc, 2);
                const b: u64 = @bitCast(f);
                try out.appendSlice(alloc, std.mem.asBytes(&b));
            },
            .text => |s| {
                try out.append(alloc, 3);
                var n: u32 = @intCast(s.len);
                try out.appendSlice(alloc, std.mem.asBytes(&n));
                try out.appendSlice(alloc, s);
            },
            .boolean => |b| {
                try out.append(alloc, 4);
                try out.append(alloc, @intFromBool(b));
            },
        }
    }
    return out.toOwnedSlice(alloc);
}
fn supportedOrder(t: *Table, e: *sql.Expr, sel: *sql.Select) bool {
    return switch (e.*) {
        .column => |name| blk: {
            if (t.find(name) != null) break :blk true;
            for (sel.items) |it| {
                if (it.alias) |al| if (std.ascii.eqlIgnoreCase(al, name)) break :blk true;
            }
            break :blk false;
        },
        .column_idx => true,
        .int, .float, .string => true,
        else => false,
    };
}
fn exprLabel(e: *sql.Expr) []const u8 {
    return switch (e.*) {
        .column => |c| c,
        .column_idx => |c| c.name,
        else => "?column?",
    };
}
pub fn cellValue(t: *Table, ci: usize, ri: usize) Value {
    if (t.isNull(ci, ri)) return .null;
    return switch (t.data[ci]) {
        .ints, .ints8, .ints16, .ints32 => .{ .int = t.data[ci].intAt(ri) },
        .floats => |a| .{ .float = a[ri] },
        .strs => |s| .{ .text = s.at(ri) },
    };
}
fn evalOwned(t: *const Table, alloc: std.mem.Allocator, e: *sql.Expr, row: usize) !Value {
    return switch (evalScalar(t, e, row)) {
        .null => .null,
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .str => |x| .{ .text = try alloc.dupe(u8, x) },
        .boolean => |b| .{ .boolean = b },
    };
}
fn toValue(s: Scalar) Value {
    return switch (s) {
        .null => .null,
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .str => |x| .{ .text = x },
        .boolean => |b| .{ .boolean = b },
    };
}
const SortCtx = struct { t: *Table, sel: *sql.Select };
fn orderLess(ctx: SortCtx, a: u32, b: u32) bool {
    for (ctx.sel.order_by) |item| {
        const av = orderValue(ctx.t, ctx.sel, item.expr, a);
        const bv = orderValue(ctx.t, ctx.sel, item.expr, b);
        const ord = Value.order(av, bv);
        if (ord == .eq) continue;
        const less = ord == .lt;
        return if (item.desc) !less else less;
    }
    return false;
}
fn orderValue(t: *Table, sel: *sql.Select, e: *sql.Expr, ri: u32) Value {
    switch (e.*) {
        .column => |name| {
            if (t.find(name)) |ci| return cellValue(t, ci, ri);
            for (sel.items, 0..) |it, oi| {
                if (it.alias) |al| {
                    if (std.ascii.eqlIgnoreCase(al, name)) return toValue(evalScalar(t, sel.items[oi].expr, ri));
                }
            }
            return .null;
        },
        else => return toValue(evalScalar(t, e, ri)),
    }
}
fn radixSortU64(alloc: std.mem.Allocator, keys: []u64, bits: usize) !void {
    if (keys.len < 2 or bits == 0) return;
    const rb: usize = 11;
    const R: usize = 1 << rb;
    const mask: u64 = R - 1;
    const tmp = try alloc.alloc(u64, keys.len);
    defer alloc.free(tmp);
    var src: []u64 = keys;
    var dst: []u64 = tmp;
    var counts: [R]usize = @splat(0);
    var shift: usize = 0;
    while (shift < bits and shift < 64) : (shift += rb) {
        for (&counts) |*c| c.* = 0;
        for (src) |k| counts[@intCast((k >> @intCast(shift)) & mask)] += 1;
        var sum: usize = 0;
        for (&counts) |*c| {
            const t = c.*;
            c.* = sum;
            sum += t;
        }
        for (src) |k| {
            const b: usize = @intCast((k >> @intCast(shift)) & mask);
            dst[counts[b]] = k;
            counts[b] += 1;
        }
        const t2 = src;
        src = dst;
        dst = t2;
    }
    if (src.ptr != keys.ptr) @memcpy(keys, src);
}
fn topKFast(t: *Table, alloc: std.mem.Allocator, sel: *sql.Select, idx: *std.ArrayList(u32), k: usize) !bool {
    const nk = sel.order_by.len;
    if (nk == 0 or nk > 3 or k == 0 or k >= idx.items.len) return false;
    var cis: [3]usize = undefined;
    var descs: [3]bool = undefined;
    for (sel.order_by, 0..) |item, i| {
        const ci: usize = switch (item.expr.*) {
            .column_idx => |c| c.idx,
            .column => |nm| t.find(nm) orelse return false,
            else => return false,
        };
        if (ci >= t.data.len) return false;
        cis[i] = ci;
        descs[i] = item.desc;
    }
    const Ctx = struct {
        t: *Table,
        cis: []const usize,
        descs: []const bool,
        fn less(c: @This(), a: u32, b: u32) bool {
            var i: usize = 0;
            while (i < c.cis.len) : (i += 1) {
                const ord: std.math.Order = switch (c.t.data[c.cis[i]]) {
                    .ints, .ints8, .ints16, .ints32 => std.math.order(c.t.data[c.cis[i]].intAt(a), c.t.data[c.cis[i]].intAt(b)),
                    .floats => |v| std.math.order(v[a], v[b]),
                    .strs => |sd| std.mem.order(u8, sd.at(a), sd.at(b)),
                };
                if (ord == .eq) continue;
                const lt = ord == .lt;
                return if (c.descs[i]) !lt else lt;
            }
            return false;
        }
    };
    const ctx = Ctx{ .t = t, .cis = cis[0..nk], .descs = descs[0..nk] };
    const heap = try alloc.alloc(u32, k);
    defer alloc.free(heap);
    @memcpy(heap, idx.items[0..k]);
    var i: usize = k / 2;
    while (i > 0) {
        i -= 1;
        siftDownFast(ctx, heap, i);
    }
    for (idx.items[k..]) |ri| {
        if (ctx.less(ri, heap[0])) {
            heap[0] = ri;
            siftDownFast(ctx, heap, 0);
        }
    }
    std.mem.sort(u32, heap, ctx, Ctx.less);
    idx.clearRetainingCapacity();
    try idx.appendSlice(alloc, heap);
    return true;
}
fn siftDownFast(ctx: anytype, heap: []u32, start: usize) void {
    var i = start;
    while (true) {
        var worst = i;
        const l = 2 * i + 1;
        const r = 2 * i + 2;
        if (l < heap.len and ctx.less(heap[worst], heap[l])) worst = l;
        if (r < heap.len and ctx.less(heap[worst], heap[r])) worst = r;
        if (worst == i) break;
        const tmp = heap[i];
        heap[i] = heap[worst];
        heap[worst] = tmp;
        i = worst;
    }
}
fn topK(t: *Table, alloc: std.mem.Allocator, sel: *sql.Select, idx: *std.ArrayList(u32), k: usize) !void {
    const heap = try alloc.alloc(u32, k);
    @memcpy(heap, idx.items[0..k]);
    var i: usize = k / 2;
    while (i > 0) {
        i -= 1;
        siftDown(t, sel, heap, i);
    }
    for (idx.items[k..]) |ri| {
        if (orderLess(SortCtx{ .t = t, .sel = sel }, ri, heap[0])) {
            heap[0] = ri;
            siftDown(t, sel, heap, 0);
        }
    }
    std.mem.sort(u32, heap, SortCtx{ .t = t, .sel = sel }, orderLess);
    idx.clearRetainingCapacity();
    try idx.appendSlice(alloc, heap);
}
fn siftDown(t: *Table, sel: *sql.Select, heap: []u32, start: usize) void {
    var i = start;
    while (true) {
        var worst = i;
        const l = 2 * i + 1;
        const r = 2 * i + 2;
        if (l < heap.len and orderLess(SortCtx{ .t = t, .sel = sel }, heap[worst], heap[l])) worst = l;
        if (r < heap.len and orderLess(SortCtx{ .t = t, .sel = sel }, heap[worst], heap[r])) worst = r;
        if (worst == i) break;
        std.mem.swap(u32, &heap[i], &heap[worst]);
        i = worst;
    }
}
fn exprUsize(t: *Table, e: *sql.Expr) usize {
    const v = evalScalar(t, e, 0);
    return switch (v) {
        .null, .str => 0,
        .int => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        .boolean => |b| @intFromBool(b),
    };
}
fn isAggName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "count") or std.ascii.eqlIgnoreCase(name, "sum") or
        std.ascii.eqlIgnoreCase(name, "avg") or std.ascii.eqlIgnoreCase(name, "min") or
        std.ascii.eqlIgnoreCase(name, "max");
}
fn collectAggs(t: *Table, alloc: std.mem.Allocator, e: *sql.Expr, specs: *std.ArrayList(AggSpec)) !void {
    switch (e.*) {
        .call => |c| {
            if (isAggName(c.name)) {
                const kind: AggKind = if (std.ascii.eqlIgnoreCase(c.name, "count"))
                    (if (c.star or c.args.len == 0) .count_all else if (c.distinct) .count_distinct else .count)
                else if (std.ascii.eqlIgnoreCase(c.name, "sum"))
                    .sum
                else if (std.ascii.eqlIgnoreCase(c.name, "avg"))
                    .avg
                else if (std.ascii.eqlIgnoreCase(c.name, "min"))
                    .min
                else
                    .max;
                var col: i32 = -1;
                var arg_expr: ?*sql.Expr = null;
                var offset: i64 = 0;
                if (!c.star and c.args.len > 0) {
                    arg_expr = c.args[0];
                    if (colIndex(t, c.args[0])) |ci| col = @intCast(ci);
                    if (c.args[0].* == .binary) {
                        const b = c.args[0].binary;
                        if (b.op == .add or b.op == .sub) {
                            if (colIndex(t, b.lhs)) |ci| {
                                if (b.rhs.* == .int) {
                                    col = @intCast(ci);
                                    offset = if (b.op == .add) b.rhs.int else -b.rhs.int;
                                    arg_expr = null;
                                }
                            }
                        }
                    }
                }
                try specs.append(alloc, .{ .kind = kind, .col = col, .expr = arg_expr, .offset = offset });
                return;
            }
            for (c.args) |a| try collectAggs(t, alloc, a, specs);
        },
        .binary => |b| {
            try collectAggs(t, alloc, b.lhs, specs);
            try collectAggs(t, alloc, b.rhs, specs);
        },
        .negate => |x| try collectAggs(t, alloc, x, specs),
        .not => |x| try collectAggs(t, alloc, x, specs),
        .is_null => |x| try collectAggs(t, alloc, x.operand, specs),
        .like => |x| {
            try collectAggs(t, alloc, x.operand, specs);
            try collectAggs(t, alloc, x.pattern, specs);
        },
        .in_list => |x| try collectAggs(t, alloc, x.operand, specs),
        .between => |x| {
            try collectAggs(t, alloc, x.operand, specs);
            try collectAggs(t, alloc, x.low, specs);
            try collectAggs(t, alloc, x.high, specs);
        },
        .cast => |x| try collectAggs(t, alloc, x.operand, specs),
        else => {},
    }
}
const Acc = struct {
    isum: i128 = 0,
    fsum: f64 = 0,
    n: i64 = 0,
    best: Value = .null,
    has_best: bool = false,
    has_float: bool = false,
    set: ?*std.StringHashMap(void) = null,
    iset: ?*std.AutoHashMap(i64, void) = null,
};
const Group = struct {
    first: u32,
    acc_off: usize,
};
const GroupTable = struct {
    t: *Table,
    group_cols: []u32,
    slots: []u32,
    mask: u64,
    groups: std.ArrayList(Group),
    accs: std.ArrayList(Acc),
    nspecs: usize,
    alloc: std.mem.Allocator,
    fn init(t: *Table, alloc: std.mem.Allocator, group_cols: []u32, cap_hint: usize) !GroupTable {
        var cap: usize = 16;
        while (cap < cap_hint * 2) cap <<= 1;
        const slots = try alloc.alloc(u32, cap);
        @memset(slots, 0);
        return .{
            .t = t,
            .group_cols = group_cols,
            .slots = slots,
            .mask = cap - 1,
            .groups = .empty,
            .accs = .empty,
            .nspecs = 0,
            .alloc = alloc,
        };
    }
    fn deinit(self: *GroupTable) void {
        self.groups.deinit(self.alloc);
        self.accs.deinit(self.alloc);
        if (self.slots.len > 0) self.alloc.free(self.slots);
    }
    fn initEmpty(t: *Table, alloc: std.mem.Allocator, group_cols: []u32) GroupTable {
        return .{
            .t = t,
            .group_cols = group_cols,
            .slots = &.{},
            .mask = 0,
            .groups = .empty,
            .accs = .empty,
            .nspecs = 0,
            .alloc = alloc,
        };
    }
    fn groupAccs(self: *GroupTable, gi: usize) []Acc {
        const off = self.groups.items[gi].acc_off;
        return self.accs.items[off .. off + self.nspecs];
    }
    fn hashRow(self: *const GroupTable, ri: u32) u64 {
        var h: u64 = 0x9e3779b97f4a7c15;
        for (self.group_cols) |ci| {
            switch (self.t.data[ci]) {
                .ints, .ints8, .ints16, .ints32 => {
                    h ^= @bitCast(self.t.data[ci].intAt(ri));
                    h *%= 0x100000001b3;
                },
                .floats => |a| {
                    h ^= @bitCast(a[ri]);
                    h *%= 0x100000001b3;
                },
                .strs => |s| {
                    if (self.t.enc[ci]) |e| {
                        h ^= e.ids[ri];
                    } else {
                        h ^= std.hash.Wyhash.hash(0, s.at(ri));
                    }
                    h *%= 0x100000001b3;
                },
            }
        }
        return h;
    }
    fn keysEqual(self: *GroupTable, a: u32, b: u32) bool {
        for (self.group_cols) |ci| {
            switch (self.t.data[ci]) {
                .ints, .ints8, .ints16, .ints32 => if (self.t.data[ci].intAt(a) != self.t.data[ci].intAt(b)) return false,
                .floats => |arr| if (arr[a] != arr[b]) return false,
                .strs => |s| {
                    const ea = self.t.enc[ci];
                    if (ea != null) {
                        if (ea.?.ids[a] != ea.?.ids[b]) return false;
                    } else if (!std.mem.eql(u8, s.at(a), s.at(b))) return false;
                },
            }
        }
        return true;
    }
    fn findOrPut(self: *GroupTable, ri: u32, specs: []const AggSpec) !u32 {
        return self.findOrPutHashed(ri, self.hashRow(ri), specs);
    }
    fn growSlots(self: *GroupTable) !void {
        const old = self.slots;
        var cap: usize = if (old.len == 0) 64 else old.len * 2;
        while (cap < (self.groups.items.len + 1) * 2) cap <<= 1;
        const slots = try self.alloc.alloc(u32, cap);
        @memset(slots, 0);
        self.slots = slots;
        self.mask = cap - 1;
        if (old.len > 0) self.alloc.free(old);
        for (self.groups.items, 0..) |g, gi| {
            var idx: usize = @intCast(self.hashRow(g.first) & self.mask);
            while (slots[idx] != 0) idx = (idx + 1) & @as(usize, @intCast(self.mask));
            slots[idx] = @intCast(gi + 1);
        }
    }
    fn findOrPutHashed(self: *GroupTable, ri: u32, h: u64, specs: []const AggSpec) !u32 {
        if (self.slots.len == 0 or (self.groups.items.len + 1) * 4 >= self.slots.len * 3) try self.growSlots();
        var idx: usize = @intCast(h & self.mask);
        while (true) {
            const slot = self.slots[idx];
            if (slot == 0) {
                const gidx: u32 = @intCast(self.groups.items.len);
                if (self.nspecs == 0) self.nspecs = specs.len;
                const off = self.accs.items.len;
                try self.accs.resize(self.alloc, off + specs.len);
                for (self.accs.items[off .. off + specs.len]) |*a| a.* = .{};
                try self.groups.append(self.alloc, .{ .first = ri, .acc_off = off });
                self.slots[idx] = gidx + 1;
                return gidx;
            }
            const g = slot - 1;
            if (self.keysEqual(self.groups.items[g].first, ri)) return g;
            idx = (idx + 1) & @as(usize, @intCast(self.mask));
        }
    }
};
fn accUpdate(acc: *Acc, spec: AggSpec, t: *Table, ri: u32, alloc: std.mem.Allocator) !void {
    if (spec.kind != .count_all and spec.col >= 0 and t.isNull(@intCast(spec.col), ri)) return;
    if (spec.kind == .count_distinct and spec.col >= 0 and t.isNull(@intCast(spec.col), ri)) return;
    switch (spec.kind) {
        .count_all => acc.n += 1,
        .count => {
            if (spec.col >= 0) acc.n += 1 else if (spec.expr != null) acc.n += 1;
        },
        .sum, .avg => {
            if (spec.col < 0) {
                if (spec.expr) |e| {
                    switch (evalScalar(t, e, ri)) {
                        .null, .boolean => {},
                        .int => |x| {
                            acc.isum += x;
                            acc.n += 1;
                        },
                        .float => |x| {
                            acc.has_float = true;
                            acc.fsum += x;
                            acc.n += 1;
                        },
                        .str => {},
                    }
                }
                return;
            }
            switch (t.data[@intCast(spec.col)]) {
                .ints, .ints8, .ints16, .ints32 => {
                    acc.isum += t.data[@intCast(spec.col)].intAt(ri) + spec.offset;
                    acc.n += 1;
                },
                .floats => |a| {
                    acc.has_float = true;
                    acc.fsum += a[ri];
                    acc.n += 1;
                },
                .strs => {},
            }
        },
        .min, .max => {
            if (spec.col >= 0) {
                const ci: usize = @intCast(spec.col);
                if (t.data[ci] == .strs) {
                    if (t.enc[ci]) |e| {
                        if (e.rank.len > 0) {
                            const r = e.rank[@intCast(e.ids[ri])];
                            const better = !acc.has_best or
                                (if (spec.kind == .min) r < @as(u32, @intCast(acc.n)) else r > @as(u32, @intCast(acc.n)));
                            if (better) {
                                acc.best = .{ .text = t.data[ci].strs.at(ri) };
                                acc.n = @intCast(r);
                                acc.has_best = true;
                            }
                            return;
                        }
                    }
                }
            }
            const v: Value = if (spec.col < 0)
                (if (spec.expr) |e| toValue(evalScalar(t, e, ri)) else return)
            else
                cellValue(t, @intCast(spec.col), ri);
            if (!acc.has_best) {
                acc.best = v;
                acc.has_best = true;
            } else {
                const ord = Value.order(v, acc.best);
                const better = if (spec.kind == .min) ord == .lt else ord == .gt;
                if (better) acc.best = v;
            }
        },
        .count_distinct => {
            if (spec.col < 0) return;
            switch (t.data[@intCast(spec.col)]) {
                .ints, .ints8, .ints16, .ints32 => {
                    if (acc.iset == null) {
                        const set = try alloc.create(std.AutoHashMap(i64, void));
                        set.* = std.AutoHashMap(i64, void).init(alloc);
                        acc.iset = set;
                    }
                    const gop = try acc.iset.?.getOrPut(t.data[@intCast(spec.col)].intAt(ri));
                    if (!gop.found_existing) acc.n += 1;
                },
                .floats => |a| {
                    if (acc.set == null) {
                        const set = try alloc.create(std.StringHashMap(void));
                        set.* = std.StringHashMap(void).init(alloc);
                        acc.set = set;
                    }
                    const key = try std.fmt.allocPrint(alloc, "{d}", .{a[ri]});
                    const gop = try acc.set.?.getOrPut(key);
                    if (!gop.found_existing) acc.n += 1;
                },
                .strs => |st| {
                    if (acc.set == null) {
                        const set = try alloc.create(std.StringHashMap(void));
                        set.* = std.StringHashMap(void).init(alloc);
                        acc.set = set;
                    }
                    const gop = try acc.set.?.getOrPut(st.at(ri));
                    if (!gop.found_existing) acc.n += 1;
                },
            }
        },
    }
}
fn finalize(acc: *Acc, spec: AggSpec) Value {
    return switch (spec.kind) {
        .count_all, .count, .count_distinct => .{ .int = acc.n },
        .sum => {
            if (acc.n == 0) return .null;
            if (acc.has_float) return .{ .float = acc.fsum };
            return .{ .int = @intCast(acc.isum) };
        },
        .avg => {
            if (acc.n == 0) return .null;
            if (acc.has_float) return .{ .float = acc.fsum / @as(f64, @floatFromInt(acc.n)) };
            return .{ .float = @as(f64, @floatFromInt(acc.isum)) / @as(f64, @floatFromInt(acc.n)) };
        },
        .min, .max => if (acc.has_best) acc.best else .null,
    };
}
fn findSpecIndex(specs: []const AggSpec, t: *Table, e: *sql.Expr) ?usize {
    if (e.* != .call) return null;
    const c = e.call;
    const kind: AggKind = if (std.ascii.eqlIgnoreCase(c.name, "count"))
        (if (c.star or c.args.len == 0) .count_all else if (c.distinct) .count_distinct else .count)
    else if (std.ascii.eqlIgnoreCase(c.name, "sum"))
        .sum
    else if (std.ascii.eqlIgnoreCase(c.name, "avg"))
        .avg
    else if (std.ascii.eqlIgnoreCase(c.name, "min"))
        .min
    else if (std.ascii.eqlIgnoreCase(c.name, "max"))
        .max
    else
        return null;
    var col: i32 = -1;
    var offset: i64 = 0;
    if (!c.star and c.args.len > 0) {
        const a0 = c.args[0];
        if (colIndex(t, a0)) |ci| col = @intCast(ci);
        if (a0.* == .binary) {
            const b = a0.binary;
            if (b.op == .add or b.op == .sub) {
                if (colIndex(t, b.lhs)) |ci| {
                    if (b.rhs.* == .int) {
                        col = @intCast(ci);
                        offset = if (b.op == .add) b.rhs.int else -b.rhs.int;
                    }
                }
            }
        }
    }
    for (specs, 0..) |sp, i| {
        if (sp.kind == kind and sp.col == col and sp.offset == offset) return i;
    }
    return null;
}
fn jitPrecompute(t: *Table, alloc: std.mem.Allocator, specs: []const AggSpec) ![]?i64 {
    const n = t.nrows;
    const out = try alloc.alloc(?i64, specs.len);
    for (out) |*o| o.* = null;
    if (n < 16) return out;
    var exe = try jit.compileSumI64Vec16(alloc);
    defer exe.deinit();
    const f = exe.as(*const fn ([*]const i64, usize) callconv(.c) i64);
    for (specs, 0..) |spec, si| {
        if ((spec.kind != .sum and spec.kind != .avg) or spec.col < 0) continue;
        if (!t.data[@intCast(spec.col)].isInt()) continue;
        const dvals = &t.data[@intCast(spec.col)];
        var reused = false;
        for (specs[0..si], 0..) |prev, pi| {
            if ((prev.kind == .sum or prev.kind == .avg) and prev.col == spec.col) {
                if (out[pi]) |v| {
                    out[si] = v;
                    reused = true;
                    break;
                }
            }
        }
        if (reused) continue;
        var max_abs: u64 = 0;
        const step = @max(n / 1024, 1);
        var i: usize = 0;
        while (i < n) : (i += step) {
            const v = dvals.intAt(i);
            const a: u64 = @intCast(if (v < 0) -%v else v);
            if (a > max_abs) max_abs = a;
        }
        const limit: u128 = @as(u128, max_abs) * n;
        if (limit > @as(u128, std.math.maxInt(i64))) continue;
        const groups = n / 16;
        var total: i64 = 0;
        if (dvals.i64Slice()) |vals| {
            if (groups > 0) total = f(@ptrCast(vals.ptr), groups);
            var j: usize = groups * 16;
            while (j < n) : (j += 1) total += vals[j];
        } else {
            var j: usize = 0;
            while (j < n) : (j += 1) total += dvals.intAt(j);
        }
        out[si] = total;
    }
    return out;
}
fn countDistinctI64(t: *Table, alloc: std.mem.Allocator, col: usize, sel: Sel, s: *Scratch) !i64 {
    if (!t.data[col].isInt()) return 0;
    if (t.data[col].i64Slice()) |a| return countDistinctInts(t, alloc, a, sel, s);
    const tmp = try alloc.alloc(i64, t.nrows);
    defer alloc.free(tmp);
    for (0..t.nrows) |i| tmp[i] = t.data[col].intAt(i);
    return countDistinctInts(t, alloc, tmp, sel, s);
}
fn countDistinctDense(alloc: std.mem.Allocator, arr: []const u32, sel: Sel, dcount: usize) !i64 {
    const n = sel.len();
    if (n == 0 or dcount == 0) return 0;
    const words = (dcount + 63) / 64;
    const T = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
    const bits = try alloc.alloc(u64, words * T);
    defer alloc.free(bits);
    @memset(bits, 0);
    const W = struct {
        arr: []const u32,
        sel: Sel,
        bits: []u64,
        start: usize,
        end: usize,
        fn run(self: *@This()) void {
            var i = self.start;
            while (i < self.end) : (i += 1) {
                const id: u64 = self.arr[self.sel.at(i)];
                self.bits[@intCast(id >> 6)] |= @as(u64, 1) << @intCast(id & 63);
            }
        }
    };
    var workers = try alloc.alloc(W, T);
    defer alloc.free(workers);
    var threads: [8]?std.Thread = undefined;
    const chunk = (n + T - 1) / T;
    for (0..T) |t| {
        const s0 = t * chunk;
        const e0 = @min(s0 + chunk, n);
        workers[t] = .{ .arr = arr, .sel = sel, .bits = bits[t * words .. (t + 1) * words], .start = s0, .end = e0 };
        threads[t] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{&workers[t]}) catch null;
        if (threads[t] == null) W.run(&workers[t]);
        if (threads[t] == null) workers[t].run();
    }
    for (0..T) |t| if (threads[t]) |th| th.join();
    var total: i64 = 0;
    for (0..words) |w| {
        var acc: u64 = 0;
        for (0..T) |t| acc |= bits[t * words + w];
        total += @popCount(acc);
    }
    return total;
}
inline fn fibHash(bits: u6, v: i64) u64 {
    const h = @as(u64, @bitCast(v)) *% 0x9E3779B97F4A7C15;
    return h >> @intCast(64 - @as(u32, bits));
}
fn countDistinctInts(t: *Table, alloc: std.mem.Allocator, arr: []const i64, sel: Sel, s: *Scratch) !i64 {
    _ = t; // values arrive via `arr`; the table is only read for metadata
    const n = sel.len();
    if (n == 0) return 0;
    const T: usize = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
    profReset();
    const buckets = try alloc.alloc(usize, T + 1);
    defer alloc.free(buckets);
    @memset(buckets, 0);
    for (0..n) |i| {
        const b: usize = @intCast(fibHash(3, arr[sel.at(i)]) & (T - 1));
        buckets[b + 1] += 1;
    }
    for (1..T + 1) |k| buckets[k] += buckets[k - 1];
    const part_reuse = s.alloc(i64, n);
    const part = part_reuse orelse try alloc.alloc(i64, n);
    defer if (part_reuse == null) alloc.free(part);
    const cur = try alloc.alloc(usize, T);
    defer alloc.free(cur);
    @memcpy(cur, buckets[0..T]);
    for (0..n) |i| {
        const v = arr[sel.at(i)];
        const b: usize = @intCast(fibHash(3, v) & (T - 1));
        part[cur[b]] = v;
        cur[b] += 1;
    }
    prof("cd:scatter");
    const W = struct {
        vals: []const i64,
        out: *i64,
        alloc: std.mem.Allocator,
        fn run(self: *@This()) void {
            const m = self.vals.len;
            var cap2: usize = 16;
            while (cap2 < m * 2 + 16) cap2 <<= 1;
            const keys = self.alloc.alloc(u64, cap2) catch return;
            defer self.alloc.free(keys);
            const occ = self.alloc.alloc(u64, cap2 / 64) catch return;
            defer self.alloc.free(occ);
            @memset(keys, 0);
            @memset(occ, 0);
            const mask = cap2 - 1;
            var count: i64 = 0;
            for (self.vals) |v| {
                const bits: u64 = @bitCast(v);
                var idx: usize = @intCast(fibHash(32, v) & mask);
                while (true) {
                    const w = idx >> 6;
                    const bit = @as(u64, 1) << @intCast(idx & 63);
                    if (occ[w] & bit == 0) {
                        occ[w] |= bit;
                        keys[idx] = bits;
                        count += 1;
                        break;
                    }
                    if (keys[idx] == bits) break;
                    idx = (idx + 1) & mask;
                }
            }
            self.out.* = count;
        }
    };
    var counts = try alloc.alloc(i64, T);
    defer alloc.free(counts);
    @memset(counts, 0);
    var workers = try alloc.alloc(W, T);
    defer alloc.free(workers);
    var threads: [8]?std.Thread = undefined;
    for (0..T) |i| {
        workers[i] = .{ .vals = part[buckets[i]..buckets[i + 1]], .out = &counts[i], .alloc = std.heap.page_allocator };
        threads[i] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{&workers[i]}) catch null;
        if (threads[i] == null) workers[i].run();
    }
    for (0..T) |i| if (threads[i]) |th| th.join();
    prof("cd:dedupe");
    var total: i64 = 0;
    for (counts) |c| total += c;
    return total;
}
fn countDistinctStr(t: *Table, alloc: std.mem.Allocator, col: usize, sel: Sel) !?i64 {
    const n = sel.len();
    if (n == 0) return 0;
    const strs = t.data[col].strs;
    const nthreads = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
    const buckets = try alloc.alloc(usize, nthreads + 1);
    defer alloc.free(buckets);
    @memset(buckets, 0);
    for (0..n) |i| {
        const s = strs.at(sel.at(i));
        const h = std.hash.Wyhash.hash(0, s);
        buckets[(h & (nthreads - 1)) + 1] += 1;
    }
    for (1..nthreads + 1) |i| buckets[i] += buckets[i - 1];
    const part = try alloc.alloc(u32, n);
    defer alloc.free(part);
    const cur = try alloc.alloc(usize, nthreads);
    defer alloc.free(cur);
    @memcpy(cur, buckets[0..nthreads]);
    for (0..n) |i| {
        const ri = sel.at(i);
        const s = strs.at(ri);
        const b = std.hash.Wyhash.hash(0, s) & (nthreads - 1);
        part[cur[b]] = ri;
        cur[b] += 1;
    }
    const W = struct {
        strs: StrData,
        rows: []const u32,
        out: *i64,
        alloc: std.mem.Allocator,
        fn run(self: *@This()) void {
            var set = std.StringHashMap(void).init(self.alloc);
            defer set.deinit();
            for (self.rows) |ri| set.put(self.strs.at(ri), {}) catch return;
            self.out.* = @intCast(set.count());
        }
    };
    var counts = try alloc.alloc(i64, nthreads);
    defer alloc.free(counts);
    @memset(counts, 0);
    var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
    defer alloc.free(arenas);
    var workers = try alloc.alloc(W, nthreads);
    defer alloc.free(workers);
    var threads: [8]?std.Thread = undefined;
    for (0..nthreads) |i| {
        arenas[i] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        workers[i] = .{ .strs = strs, .rows = part[buckets[i]..buckets[i + 1]], .out = &counts[i], .alloc = arenas[i].allocator() };
        threads[i] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{&workers[i]}) catch null;
        if (threads[i] == null) workers[i].run();
    }
    for (0..nthreads) |i| if (threads[i]) |th| th.join();
    var total: i64 = 0;
    for (counts) |c| total += c;
    for (arenas) |*a| a.deinit();
    return total;
}
fn denseGroupAgg(
    t: *Table,
    alloc: std.mem.Allocator,
    group_col: u32,
    specs: []const AggSpec,
    selection: Sel,
    s: *Scratch,
) !?ShardedGroups {
    _ = s;
    if (group_col >= t.enc.len) return null;
    const ge = t.enc[group_col] orelse return null;
    if (t.valid.len > group_col and t.valid[group_col] != null) return null;
    const gvals: []const u32 = ge.ids;
    const ng = ge.first.len;
    const n = selection.len();
    if (ng == 0 or n < 16_384) return null;
    const nspec = specs.len;
    if (nspec == 0 or nspec > 8) return null;
    var kind: [8]u8 = @splat(0); // 0=count_all/count, 1=int column, 2=length(str)
    var src_col: [8]usize = @splat(0);
    var lens_by_col: [32]?[]i64 = @splat(null);
    defer for (&lens_by_col) |*lp| if (lp.*) |l| alloc.free(l);
    for (specs, 0..) |sp, si| {
        switch (sp.kind) {
            .count_all => kind[si] = 0,
            .count => {
                if (sp.col < 0) return null;
                const ci: usize = @intCast(sp.col);
                if (!t.data[ci].isInt()) return null;
                kind[si] = 0;
            },
            .sum, .avg => {
                if (sp.col >= 0) {
                    const ci: usize = @intCast(sp.col);
                    if (!t.data[ci].isInt()) return null;
                    kind[si] = 1;
                    src_col[si] = ci;
                } else if (sp.expr) |e| {
                    if (e.* != .call) return null;
                    const c = e.call;
                    if (!std.ascii.eqlIgnoreCase(c.name, "length") or c.args.len != 1) return null;
                    const ci = colIndex(t, c.args[0]) orelse return null;
                    if (ci >= t.data.len or t.data[ci] != .strs) return null;
                    const se = t.enc[ci] orelse return null;
                    if (lens_by_col[ci] == null) {
                        const lens = try alloc.alloc(i64, se.first.len);
                        for (se.first, 0..) |row, id| lens[id] = @intCast(t.data[ci].strs.at(row).len);
                        lens_by_col[ci] = lens;
                    }
                    kind[si] = 2;
                    src_col[si] = ci;
                } else return null;
            },
            .count_distinct => return null,
            .min, .max => return null,
        }
    }
    const per = ng * nspec;
    var need_sums = false;
    for (specs) |sp| {
        if (sp.kind == .sum or sp.kind == .avg) need_sums = true;
    }
    const T: usize = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
    const bytes_per = per * 4 + (if (need_sums) per * 16 else 0);
    const nth = if (bytes_per * T <= (96 << 20)) T else 1;
    const sums_opt: ?[]i128 = if (need_sums) try alloc.alloc(i128, nth * per) else null;
    defer if (sums_opt) |sl| alloc.free(sl);
    const sums: []i128 = sums_opt orelse &.{};
    const cnts = try alloc.alloc(u32, nth * per);
    defer alloc.free(cnts);
    if (sums.len > 0) @memset(sums, 0);
    @memset(cnts, 0);
    const W = struct {
        t: *Table,
        gvals: []const u32,
        specs: []const AggSpec,
        kind: []const u8,
        src_col: []const usize,
        lens: []const ?[]i64,
        sel: Sel,
        sums: []i128,
        cnts: []u32,
        start: usize,
        end: usize,
        fn run(self: *@This()) void {
            const ns = self.specs.len;
            var i = self.start;
            while (i < self.end) : (i += 1) {
                const ri = self.sel.at(i);
                const gid: usize = self.gvals[ri];
                const base = gid * ns;
                for (self.specs, 0..) |sp, si| {
                    switch (sp.kind) {
                        .count_all => self.cnts[base + si] += 1,
                        .count => {
                            if (sp.col >= 0 and self.t.isNull(@intCast(sp.col), ri)) continue;
                            self.cnts[base + si] += 1;
                        },
                        .sum, .avg => {
                            var v: i64 = 0;
                            switch (self.kind[si]) {
                                1 => {
                                    if (self.t.isNull(self.src_col[si], ri)) continue;
                                    v = self.t.data[self.src_col[si]].intAt(ri);
                                },
                                2 => {
                                    const l = self.lens[self.src_col[si]] orelse continue;
                                    const ids = self.t.enc[self.src_col[si]].?.ids;
                                    v = l[@intCast(ids[ri])];
                                },
                                else => return,
                            }
                            if (self.sums.len > 0) self.sums[base + si] += v + sp.offset;
                            self.cnts[base + si] += 1;
                        },
                        .count_distinct, .min, .max => {},
                    }
                }
            }
        }
    };
    var workers = try alloc.alloc(W, nth);
    defer alloc.free(workers);
    var threads: [8]?std.Thread = undefined;
    const chunk = (n + nth - 1) / nth;
    for (0..nth) |ti| {
        workers[ti] = .{
            .t = t,
            .gvals = gvals,
            .specs = specs,
            .kind = &kind,
            .src_col = &src_col,
            .lens = &lens_by_col,
            .sel = selection,
            .sums = if (sums.len > 0) sums[ti * per .. (ti + 1) * per] else &.{},
            .cnts = cnts[ti * per .. (ti + 1) * per],
            .start = ti * chunk,
            .end = @min((ti + 1) * chunk, n),
        };
        threads[ti] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{&workers[ti]}) catch null;
        if (threads[ti] == null) workers[ti].run();
    }
    for (0..nth) |ti| if (threads[ti]) |th| th.join();
    var present: usize = 0;
    for (0..ng) |g| {
        var any = false;
        for (specs, 0..) |_, si| {
            var sn: i64 = 0;
            for (0..nth) |ti| sn += @as(i64, cnts[ti * per + g * nspec + si]);
            if (sn > 0) any = true;
        }
        if (any) present += 1;
    }
    const groups = try alloc.alloc(Group, present);
    const accs = try alloc.alloc(Acc, present * nspec);
    var gp: usize = 0;
    for (0..ng) |g| {
        var any = false;
        for (specs, 0..) |_, si| {
            var sn: i64 = 0;
            for (0..nth) |ti| sn += @as(i64, cnts[ti * per + g * nspec + si]);
            if (sn > 0) any = true;
        }
        if (!any) continue;
        groups[gp] = .{ .first = ge.first[g], .acc_off = gp * nspec };
        for (specs, 0..) |sp, si| {
            const k = g * nspec + si;
            var sn: i64 = 0;
            var ss: i128 = 0;
            for (0..nth) |ti| {
                sn += @as(i64, cnts[ti * per + k]);
                if (sums.len > 0) ss += sums[ti * per + k];
            }
            var acc = Acc{};
            switch (sp.kind) {
                .count_all, .count => acc.n = sn,
                .sum => {
                    acc.isum = ss;
                    acc.n = 1;
                },
                .avg => {
                    acc.isum = ss;
                    acc.n = sn;
                },
                .count_distinct, .min, .max => {},
            }
            accs[gp * nspec + si] = acc;
        }
        gp += 1;
    }
    return .{ .groups = groups, .accs = accs };
}
fn radixSortInto(comptime rb: usize, keys: []u64, tmp: []u64, bits: usize) void {
    if (keys.len < 2 or bits == 0) return;
    const R: usize = 1 << rb;
    const mask: u64 = R - 1;
    var src: []u64 = keys;
    var dst: []u64 = tmp;
    var counts: [R]usize = @splat(0);
    var shift: usize = 0;
    while (shift < bits and shift < 64) : (shift += rb) {
        for (&counts) |*c| c.* = 0;
        for (src) |k| counts[@intCast((k >> @intCast(shift)) & mask)] += 1;
        var sum: usize = 0;
        for (&counts) |*c| {
            const t = c.*;
            c.* = sum;
            sum += t;
        }
        for (src) |k| {
            const b: usize = @intCast((k >> @intCast(shift)) & mask);
            dst[counts[b]] = k;
            counts[b] += 1;
        }
        const t2 = src;
        src = dst;
        dst = t2;
    }
    if (src.ptr != keys.ptr) @memcpy(keys, src);
}
fn sortedGroupedDistinct(
    t: *Table,
    alloc: std.mem.Allocator,
    group_cols: []const u32,
    specs: []const AggSpec,
    selection: Sel,
    s: *Scratch,
) !?ShardedGroups {
    if (group_cols.len == 0 or group_cols.len > 2) return null;
    for (group_cols) |gc| {
        if (t.valid.len > gc and t.valid[gc] != null) return null;
    }
    const ids_a: []const u32 = t.groupKeyIds(group_cols[0]) orelse return null;
    const ndv_a = t.enc[group_cols[0]].?.first.len;
    if (ndv_a == 0) return null;
    var ids_b: []const u32 = &.{};
    var ng_b: usize = 0;
    var two = false;
    if (group_cols.len == 2) {
        two = true;
        ids_b = t.groupKeyIds(group_cols[1]) orelse return null;
        ng_b = t.enc[group_cols[1]].?.first.len;
        if (ng_b == 0) return null;
        if (@as(u64, ndv_a) * @as(u64, ng_b) > (1 << 21)) return null;
    }
    const ng: usize = if (two) ndv_a * ng_b else ndv_a;
    if (ng > (1 << 21)) return null;
    var dsi: ?usize = null;
    for (specs, 0..) |sp, si| {
        switch (sp.kind) {
            .count_distinct => {
                if (dsi != null) return null;
                dsi = si;
            },
            .count_all, .count => {},
            .sum, .avg => {
                if (sp.col < 0) return null;
                const ci: usize = @intCast(sp.col);
                if (!t.data[ci].isInt()) return null;
                if (t.valid.len > ci and t.valid[ci] != null) return null;
            },
            .min, .max => return null,
        }
    }
    const dist_si = dsi orelse return null;
    const dcol: usize = @intCast(specs[dist_si].col);
    if (t.valid.len > dcol and t.valid[dcol] != null) return null;
    const uids: []const u32 = t.groupKeyIds(dcol) orelse return null;
    const D = t.enc[dcol].?.first.len;
    if (D == 0) return null;
    const ib0 = std.math.log2_int_ceil(usize, D);
    const gb0 = std.math.log2_int_ceil(usize, ng);
    if (ib0 > 31 or gb0 + ib0 > 63) return null;
    const n = selection.len();
    if (n < 65_536) return null;
    const T0 = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
    var T: usize = 1;
    while (T * 2 <= T0) T *= 2;
    const ib: u6 = @intCast(ib0);
    const nspec = specs.len;
    const keys_scr = s.alloc(u64, n);
    const keys = keys_scr orelse try alloc.alloc(u64, n);
    defer if (keys_scr == null) alloc.free(keys);
    const tmp_scr = s.alloc(u64, n);
    const tmp = tmp_scr orelse (std.heap.page_allocator.alloc(u64, n) catch return null);
    defer if (tmp_scr == null) std.heap.page_allocator.free(tmp);
    const firsts_t = try alloc.alloc(u32, T * ng);
    defer alloc.free(firsts_t);
    @memset(firsts_t, std.math.maxInt(u32));
    const cnts = try alloc.alloc(u32, T * ng);
    defer alloc.free(cnts);
    @memset(cnts, 0);
    const ns = try alloc.alloc(i64, T * ng * nspec);
    defer alloc.free(ns);
    @memset(ns, 0);
    const sums = try alloc.alloc(i128, T * ng * nspec);
    defer alloc.free(sums);
    @memset(sums, 0);
    const chunk = (n + T - 1) / T;
    const A = struct {
        t: *Table,
        ids_a: []const u32,
        ids_b: []const u32,
        ng_b: usize,
        two: bool,
        uids: []const u32,
        ib: u6,
        specs: []const AggSpec,
        sel: Sel,
        start: usize,
        end: usize,
        keys: []u64,
        firsts: []u32,
        ns: []i64,
        sums: []i128,
        fn run(self: *@This()) void {
            var i = self.start;
            while (i < self.end) : (i += 1) {
                const ri = self.sel.at(i);
                const gid: usize = if (self.two)
                    @as(usize, self.ids_a[ri]) * self.ng_b + self.ids_b[ri]
                else
                    self.ids_a[ri];
                if (self.firsts[gid] == std.math.maxInt(u32)) self.firsts[gid] = @intCast(ri);
                self.keys[i] = (@as(u64, gid) << self.ib) | @as(u64, self.uids[ri]);
                for (self.specs, 0..) |sp, si| {
                    switch (sp.kind) {
                        .count_all, .count => self.ns[gid * self.specs.len + si] += 1,
                        .sum, .avg => {
                            self.sums[gid * self.specs.len + si] +=
                                self.t.data[@intCast(sp.col)].intAt(ri) + sp.offset;
                            self.ns[gid * self.specs.len + si] += 1;
                        },
                        .count_distinct, .min, .max => {},
                    }
                }
            }
        }
    };
    var aw: [8]A = undefined;
    var at: [8]?std.Thread = undefined;
    for (0..T) |ti| {
        const s0 = ti * chunk;
        const e0 = @min(s0 + chunk, n);
        aw[ti] = .{
            .t = t,
            .ids_a = ids_a,
            .ids_b = ids_b,
            .ng_b = ng_b,
            .two = two,
            .uids = uids,
            .ib = ib,
            .specs = specs,
            .sel = selection,
            .start = s0,
            .end = e0,
            .keys = keys,
            .firsts = firsts_t[ti * ng .. (ti + 1) * ng],
            .ns = ns[ti * ng * nspec .. (ti + 1) * ng * nspec],
            .sums = sums[ti * ng * nspec .. (ti + 1) * ng * nspec],
        };
        at[ti] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, A.run, .{&aw[ti]}) catch null;
        if (at[ti] == null) aw[ti].run();
    }
    for (0..T) |ti| if (at[ti]) |th| th.join();
    const B = struct {
        keys: []u64,
        tmp: []u64,
        ib: u6,
        bits: usize,
        rs: usize,
        re: usize,
        uniq: usize = 0,
        fn run(self: *@This()) void {
            if (self.re <= self.rs) return;
            radixSortInto(17, self.keys[self.rs..self.re], self.tmp[self.rs..self.re], self.bits);
            var w = self.rs;
            var prev: u64 = 0;
            var i = self.rs;
            while (i < self.re) : (i += 1) {
                const k = self.keys[i];
                if (i == self.rs or k != prev) {
                    self.keys[w] = k;
                    w += 1;
                    prev = k;
                }
            }
            self.uniq = w - self.rs;
        }
    };
    var bw: [8]B = undefined;
    var bt: [8]?std.Thread = undefined;
    for (0..T) |ti| {
        bw[ti] = .{
            .keys = keys,
            .tmp = tmp,
            .ib = ib,
            .bits = gb0 + ib0,
            .rs = ti * chunk,
            .re = @min((ti + 1) * chunk, n),
        };
        bt[ti] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, B.run, .{&bw[ti]}) catch null;
        if (bt[ti] == null) bw[ti].run();
    }
    for (0..T) |ti| if (bt[ti]) |th| th.join();
    var u_total: usize = 0;
    for (0..T) |ti| {
        const u = bw[ti].uniq;
        if (u == 0) continue;
        const src = bw[ti].rs;
        if (u_total != src) @memmove(keys[u_total .. u_total + u], keys[src .. src + u]);
        u_total += u;
    }
    if (u_total > 0) {
        radixSortInto(17, keys[0..u_total], tmp[0..u_total], gb0 + ib0);
        var prev: u64 = 0;
        for (0..u_total) |i| {
            const k = keys[i];
            if (i == 0 or k != prev) {
                cnts[@intCast(k >> ib)] += 1;
                prev = k;
            }
        }
    }
    var present: usize = 0;
    for (0..ng) |g| {
        var best: u32 = std.math.maxInt(u32);
        for (0..T) |ti| best = @min(best, firsts_t[ti * ng + g]);
        if (best != std.math.maxInt(u32)) present += 1;
    }
    if (present == 0) return null;
    const gsel = try alloc.alloc(Group, present);
    const asel = try alloc.alloc(Acc, present * nspec);
    var w: usize = 0;
    for (0..ng) |g| {
        var best: u32 = std.math.maxInt(u32);
        var dcount: i64 = 0;
        for (0..T) |ti| {
            best = @min(best, firsts_t[ti * ng + g]);
            dcount += cnts[ti * ng + g];
        }
        if (best == std.math.maxInt(u32)) continue;
        gsel[w] = .{ .first = best, .acc_off = w * nspec };
        for (specs, 0..) |sp, si| {
            var sn: i64 = 0;
            var ss: i128 = 0;
            for (0..T) |ti| {
                sn += ns[ti * ng * nspec + g * nspec + si];
                ss += sums[ti * ng * nspec + g * nspec + si];
            }
            var macc = Acc{};
            switch (sp.kind) {
                .count_all, .count => macc.n = sn,
                .count_distinct => macc.n = dcount,
                .sum => {
                    macc.isum = ss;
                    macc.n = 1;
                },
                .avg => {
                    macc.isum = ss;
                    macc.n = sn;
                },
                .min, .max => {},
            }
            asel[w * nspec + si] = macc;
        }
        w += 1;
    }
    return .{ .groups = gsel, .accs = asel };
}
fn groupedDistinctAgg(
    t: *Table,
    alloc: std.mem.Allocator,
    group_cols: []const u32,
    specs: []const AggSpec,
    selection: Sel,
    s: *Scratch,
) !?ShardedGroups {
    if (group_cols.len == 0 or group_cols.len > 2) return null;
    for (group_cols) |gc| {
        if (t.valid.len > gc and t.valid[gc] != null) return null;
    }
    const gcol_a = group_cols[0];
    const ids_a: []const u32 = t.groupKeyIds(gcol_a) orelse return null;
    const gen = t.enc[gcol_a].?;
    const two = group_cols.len == 2;
    var ids_b: []const u32 = &.{};
    var ng_b: usize = 0;
    if (two) {
        ids_b = t.groupKeyIds(group_cols[1]) orelse return null;
        ng_b = t.enc[group_cols[1]].?.first.len;
        if (ng_b == 0) return null;
        if (@as(u64, gen.first.len) * @as(u64, ng_b) > (1 << 21)) return null;
    }
    const n = selection.len();
    if (n < 64) return null;
    var distinct_col: ?usize = null;
    for (specs) |sp| {
        switch (sp.kind) {
            .count_distinct => {
                if (sp.col < 0) return null;
                const ci: usize = @intCast(sp.col);
                if (t.groupKeyIds(ci) == null) return null;
                if (distinct_col == null) distinct_col = ci;
            },
            .count_all, .count => {},
            .sum, .avg => {
                if (sp.col < 0) return null;
                if (!t.data[@intCast(sp.col)].isInt()) return null;
            },
            .min, .max => return null,
        }
    }
    const dcol = distinct_col orelse return null;
    const dv: []const u32 = t.groupKeyIds(dcol) orelse return null;
    profReset();
    const ndv = gen.first.len;
    if (ndv == 0) return null;
    const ng: usize = if (two) ndv * ng_b else ndv;
    var firsts_buf: ?[]u32 = null;
    defer if (firsts_buf) |b| alloc.free(b);
    const need_firsts = two or selection.list != null;
    if (need_firsts) {
        const fb = try alloc.alloc(u32, ng);
        @memset(fb, std.math.maxInt(u32));
        var bi: usize = 0;
        while (bi < n) : (bi += 1) {
            const ri = selection.at(bi);
            const gid: usize = if (two)
                @as(usize, ids_a[ri]) * ng_b + ids_b[ri]
            else
                ids_a[ri];
            if (fb[gid] == std.math.maxInt(u32)) fb[gid] = @intCast(ri);
        }
        firsts_buf = fb;
    }
    const firsts: []const u32 = if (need_firsts) firsts_buf.? else gen.first;
    prof("gd:minmax");
    var i: usize = 0;
    const T: usize = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
    if (t.enc[dcol]) |e| {
        const words = (e.first.len + 63) / 64;
        const budget = 48 << 20;
        if (words > 0 and ng * words * 8 <= budget) {
            const bm = try alloc.alloc(u64, ng * words);
            defer alloc.free(bm);
            @memset(bm, 0);
            const per2 = ng * specs.len;
            const nsv2 = try alloc.alloc(i64, T * per2);
            defer alloc.free(nsv2);
            const sums2 = try alloc.alloc(i128, T * per2);
            defer alloc.free(sums2);
            @memset(nsv2, 0);
            @memset(sums2, 0);
            const BW = struct {
                t: *Table,
                ids_a: []const u32,
                ids_b: []const u32,
                ng_b: usize,
                two: bool,
                ids: []const u32,
                specs: []const AggSpec,
                words: usize,
                bm: []u64,
                ns: []i64,
                sums: []i128,
                start: usize,
                end: usize,
                sel: Sel,
                fn run(self: *@This()) void {
                    const ns = self.specs.len;
                    var bi = self.start;
                    while (bi < self.end) : (bi += 1) {
                        const ri = self.sel.at(bi);
                        const gid: usize = if (self.two)
                            @as(usize, self.ids_a[ri]) * self.ng_b + self.ids_b[ri]
                        else
                            self.ids_a[ri];
                        for (self.specs, 0..) |sp, si| {
                            switch (sp.kind) {
                                .count_all, .count => self.ns[gid * ns + si] += 1,
                                .sum, .avg => {
                                    self.sums[gid * ns + si] +=
                                        self.t.data[@intCast(sp.col)].intAt(ri) + sp.offset;
                                    self.ns[gid * ns + si] += 1;
                                },
                                .count_distinct => {
                                    const id: u64 = @intCast(self.ids[ri]);
                                    const slot = gid * self.words + @as(usize, @intCast(id >> 6));
                                    _ = @atomicRmw(u64, &self.bm[slot], .Or, @as(u64, 1) << @intCast(id & 63), .monotonic);
                                },
                                .min, .max => {},
                            }
                        }
                    }
                }
            };
            var bw: [8]BW = undefined;
            var bt: [8]?std.Thread = undefined;
            const chunk2 = (n + T - 1) / T;
            for (0..T) |ti| {
                const s0 = ti * chunk2;
                const e0 = @min(s0 + chunk2, n);
                bw[ti] = .{ .t = t, .ids_a = ids_a, .ids_b = ids_b, .ng_b = ng_b, .two = two, .ids = e.ids, .specs = specs, .words = words, .bm = bm, .ns = nsv2[ti * per2 .. (ti + 1) * per2], .sums = sums2[ti * per2 .. (ti + 1) * per2], .start = s0, .end = e0, .sel = selection };
                bt[ti] = null;
                bt[ti] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, BW.run, .{&bw[ti]}) catch null;
                if (bt[ti] == null and s0 < e0) BW.run(&bw[ti]);
                if (bt[ti] == null and s0 < e0) bw[ti].run();
            }
            for (0..T) |ti| if (bt[ti]) |th| th.join();
            const groups2 = try alloc.alloc(Group, ng);
            const accs2 = try alloc.alloc(Acc, ng * specs.len);
            for (0..ng) |g| {
                groups2[g] = .{ .first = firsts[g], .acc_off = g  * specs.len };
                var dn: i64 = 0;
                for (0..words) |w| dn += @popCount(bm[g * words + w]);
                for (specs, 0..) |sp, si| {
                    const k = g  * specs.len + si;
                    var sn: i64 = 0;
                    var ss: i128 = 0;
                    for (0..T) |ti| {
                        sn += nsv2[ti * per2 + k];
                        ss += sums2[ti * per2 + k];
                    }
                    var acc = Acc{};
                    switch (sp.kind) {
                        .count_all, .count => acc.n = sn,
                        .count_distinct => acc.n = dn,
                        .sum => {
                            acc.isum = ss;
                            acc.n = 1;
                        },
                        .avg => {
                            acc.isum = ss;
                            acc.n = sn;
                        },
                        .min, .max => {},
                    }
                    accs2[k] = acc;
                }
            }
            prof("gd:bitmap");
            if (need_firsts) {
                var w: usize = 0;
                for (0..ng) |g| if (firsts[g] != std.math.maxInt(u32)) {
                    w += 1;
                };
                const gsel = try alloc.alloc(Group, w);
                const asel = try alloc.alloc(Acc, w * specs.len);
                var k: usize = 0;
                for (0..ng) |g| {
                    if (firsts[g] == std.math.maxInt(u32)) continue;
                    gsel[k] = .{ .first = firsts[g], .acc_off = k * specs.len };
                    @memcpy(asel[k * specs.len ..][0..specs.len], accs2[g * specs.len ..][0..specs.len]);
                    k += 1;
                }
                alloc.free(groups2);
                alloc.free(accs2);
                return .{ .groups = gsel, .accs = asel };
            }
            return .{ .groups = groups2, .accs = accs2 };
        }
    }
    if (t.enc[dcol]) |e| {
        if (specs.len == 1 and specs[0].kind == .count_distinct and e.first.len > 1 and ng > 1 and ng > 1024) {
            const gb = std.math.log2_int_ceil(usize, ng);
            const ib = std.math.log2_int_ceil(usize, e.first.len);
            if (gb + ib <= 64) {
                const sh: u6 = @intCast(ib);
                const keys = try alloc.alloc(u64, n);
                defer alloc.free(keys);
                const iw: u64 = if (ib >= 64) 0 else (@as(u64, 1) << @intCast(ib)) - 1;
                i = 0;
                while (i < n) : (i += 1) {
                    const ri = selection.at(i);
                    const gid: u64 = if (two)
                        @as(u64, ids_a[ri]) * ng_b + ids_b[ri]
                    else
                        ids_a[ri];
                    keys[i] = (gid << sh) | (@as(u64, @intCast(e.ids[ri])) & iw);
                }
                try radixSortU64(alloc, keys, gb + ib);
                const dcounts = try alloc.alloc(i64, ng);
                defer alloc.free(dcounts);
                @memset(dcounts, 0);
                var prev: u64 = std.math.maxInt(u64);
                for (keys) |k2| {
                    if (k2 != prev) {
                        dcounts[@intCast(k2 >> sh)] += 1;
                        prev = k2;
                    }
                }
                const groups3 = try alloc.alloc(Group, ng);
                const accs3 = try alloc.alloc(Acc, ng);
                if (need_firsts) {
                    var w3: usize = 0;
                    for (0..ng) |g| if (firsts[g] != std.math.maxInt(u32)) {
                        w3 += 1;
                    };
                    const gsel = try alloc.alloc(Group, w3);
                    const asel = try alloc.alloc(Acc, w3);
                    var k: usize = 0;
                    for (0..ng) |g| {
                        if (firsts[g] == std.math.maxInt(u32)) continue;
                        gsel[k] = .{ .first = firsts[g], .acc_off = k };
                        asel[k] = .{ .n = dcounts[g] };
                        k += 1;
                    }
                    alloc.free(groups3);
                    alloc.free(accs3);
                    prof("gd:sortpairs");
                    return .{ .groups = gsel, .accs = asel };
                }
                prof("gd:sortpairs");
                return .{ .groups = groups3, .accs = accs3 };
            }
        }
    }
    prof("gd:gids+part");
    if (ng == 0 or (!two and ng > n)) return null;
    const B: usize = 64;
    const capb = n / B + n / (4 * B) + 64;
    const order_scratch = s.alloc(u32, capb * B);
    const order: []u32 = order_scratch orelse try alloc.alloc(u32, capb * B);
    defer if (order_scratch == null) alloc.free(order);
    var curs: [B]usize = @splat(0);
    var overflow = false;
    i = 0;
    while (i < n) : (i += 1) {
        const ri = selection.at(i);
        const b: usize = @intCast(fibHash(6, dv[ri]) & (B - 1));
        if (curs[b] == capb) {
            overflow = true;
            break;
        }
        order[b * capb + curs[b]] = ri;
        curs[b] += 1;
        if (two) {
            const gid: usize = @as(usize, ids_a[ri]) * ng_b + ids_b[ri];
            if (firsts_buf.?.ptr[gid] == std.math.maxInt(u32)) firsts_buf.?.ptr[gid] = @intCast(ri);
        }
    }
    if (overflow) return null;
    prof("gd:hash+scatter");
    const cnt = curs;
    const W = struct {
        t: *Table,
        order: []const u32,
        capb: usize,
        cnt: []const usize,
        worker: usize,
        nworkers: usize,
        ids_a: []const u32,
        ids_b: []const u32,
        ng_b: usize,
        two: bool,
        dcol: usize,
        dv: []const u32,
        specs: []const AggSpec,
        ng: usize,
        distinct: []i64,
        sums: []i128,
        ns: []i64,
        pairs: []u64,
        pairs_owned: ?[]u64 = null,
        failed: bool = false,
        fn run(self: *@This()) void {
            const nt = self.pairs.len;
            if (nt == 0) return;
            var pairs = self.pairs;
            @memset(pairs, 0xFFFF_FFFF_FFFF_FFFF);
            var mask = nt - 1;
            var filled: usize = 0;
            const dvw: []const u32 = self.dv;
            var b = self.worker;
            while (b < self.cnt.len) : (b += self.nworkers) {
                const start = b * self.capb;
                const c = self.cnt[b];
                const rows = self.order[start .. start + c];
                const BATCH: usize = blk: {
                    if (std.c.getenv("ZHDB_GD_SERIAL") != null) break :blk 1;
                    if (std.c.getenv("ZHDB_GD_BATCH")) |bv| {
                        const v = std.fmt.parseInt(usize, std.mem.span(bv), 10) catch 16;
                        if (v >= 1 and v <= 64) break :blk v;
                    }
                    break :blk 16;
                };
                var rbi: usize = 0;
                while (rbi < rows.len) {
                    const bend = @min(rbi + BATCH, rows.len);
                    var k_gid: [64]u32 = undefined;
                    var k_key: [64]u64 = undefined;
                    var k_idx: [64]u32 = undefined;
                    const nb = bend - rbi;
                    for (rows[rbi..bend], 0..) |ri, kk| {
                        const gid: u32 = @intCast(if (self.two)
                            @as(usize, self.ids_a[ri]) * self.ng_b + self.ids_b[ri]
                        else
                            self.ids_a[ri]);
                        const v = dvw[ri];
                        k_gid[kk] = gid;
                        k_key[kk] = (@as(u64, gid) << 32) | @as(u64, v);
                        k_idx[kk] = @intCast(fibHash(32, v) & mask);
                        @prefetch(&pairs[k_idx[kk]], .{ .rw = .write, .locality = 1 });
                    }
                    for (0..nb) |kk| {
                    const ri = rows[rbi + kk];
                    const gid: usize = k_gid[kk];
                    const key: u64 = k_key[kk];
                    for (self.specs, 0..) |sp, si| {
                        switch (sp.kind) {
                            .count_all, .count => self.ns[gid * self.specs.len + si] += 1,
                            .sum, .avg => {
                                const a: []const i64 = self.t.data[@intCast(sp.col)].ints;
                                self.sums[gid * self.specs.len + si] += a[ri] + sp.offset;
                                self.ns[gid * self.specs.len + si] += 1;
                            },
                            .count_distinct => {
                                var idx: usize = k_idx[kk];
                                {
                                    while (true) {
                                        const cur = pairs[idx];
                                        if (cur == 0xFFFF_FFFF_FFFF_FFFF) {
                                            pairs[idx] = key;
                                            filled += 1;
                                            self.distinct[gid * self.specs.len + si] += 1;
                                            break;
                                        }
                                        if (cur == key) break;
                                        idx = (idx + 1) & mask;
                                    }
                                }
                            },
                            .min, .max => {},
                        }
                    }
                    }
                    if (filled * 10 >= pairs.len * 7 and pairs.len < (1 << 22)) {
                        const ncap = pairs.len * 2;
                        const np = std.heap.page_allocator.alloc(u64, ncap) catch {
                            self.failed = true;
                            return;
                        };
                        @memset(np, 0xFFFF_FFFF_FFFF_FFFF);
                        const nmask = ncap - 1;
                        for (pairs) |k| {
                            if (k == 0xFFFF_FFFF_FFFF_FFFF) continue;
                            var j: usize = @intCast(fibHash(32, @intCast(@as(u32, @truncate(k)))) & nmask);
                            while (np[j] != 0xFFFF_FFFF_FFFF_FFFF) j = (j + 1) & nmask;
                            np[j] = k;
                        }
                        if (self.pairs_owned) |old| std.heap.page_allocator.free(old);
                        self.pairs_owned = np;
                        pairs = np;
                        mask = nmask;
                    }
                    rbi = bend;
                }
            }
        }
    };
    const nspec = specs.len;
    prof("gd:dedupe");
    const per = ng * nspec;
    const distinct = try alloc.alloc(i64, T * per);
    defer alloc.free(distinct);
    const sums = try alloc.alloc(i128, T * per);
    defer alloc.free(sums);
    const nsv = try alloc.alloc(i64, T * per);
    defer alloc.free(nsv);
    @memset(distinct, 0);
    @memset(sums, 0);
    @memset(nsv, 0);
    var per_worker: [8]usize = @splat(0);
    for (cnt, 0..) |c, b| per_worker[b % T] += c;
    var pair_tables: [8][]u64 = undefined;
    var pair_owned: [8]bool = .{ false, false, false, false, false, false, false, false };
    defer for (0..T) |ti| {
        if (pair_owned[ti]) alloc.free(pair_tables[ti]);
    };
    for (0..T) |ti| {
        const m = per_worker[ti];
        var cap: usize = 16;
        while (cap < m + m / 2 + 16) cap <<= 1;
        if (std.c.getenv("ZHDB_GD_SMALL") != null) {
            var small: usize = 1024;
            while (small < cap and small < (1 << 15)) small <<= 1;
            cap = small;
        }
        if (s.alloc(u64, cap)) |slice| {
            pair_tables[ti] = slice;
        } else {
            pair_tables[ti] = try alloc.alloc(u64, cap);
            pair_owned[ti] = true;
        }
    }
    var workers = try alloc.alloc(W, T);
    defer alloc.free(workers);
    var threads: [8]?std.Thread = undefined;
    for (0..T) |ti| {
        workers[ti] = .{
            .t = t,
            .order = order,
            .capb = capb,
            .cnt = &cnt,
            .worker = ti,
            .nworkers = T,
            .ids_a = ids_a,
            .ids_b = ids_b,
            .ng_b = ng_b,
            .two = two,
            .dcol = dcol,
            .dv = dv,
            .specs = specs,
            .ng = ng,
            .distinct = distinct[ti * per .. (ti + 1) * per],
            .sums = sums[ti * per .. (ti + 1) * per],
            .ns = nsv[ti * per .. (ti + 1) * per],
            .pairs = pair_tables[ti],
        };
        threads[ti] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{&workers[ti]}) catch null;
        if (threads[ti] == null) workers[ti].run();
    }
    for (0..T) |ti| if (threads[ti]) |th| th.join();
    defer for (0..T) |ti| if (workers[ti].pairs_owned) |buf| std.heap.page_allocator.free(buf);
    for (0..T) |ti| if (workers[ti].failed) return null;
    const groups = try alloc.alloc(Group, ng);
    const accs = try alloc.alloc(Acc, ng * nspec);
    for (0..ng) |g| {
        groups[g] = .{ .first = firsts[g], .acc_off = g * nspec };
        for (specs, 0..) |sp, si| {
            const k = g * nspec + si;
            var acc = Acc{};
            var dn: i64 = 0;
            var sn: i64 = 0;
            var ss: i128 = 0;
            for (0..T) |ti| {
                dn += distinct[ti * per + k];
                sn += nsv[ti * per + k];
                ss += sums[ti * per + k];
            }
            switch (sp.kind) {
                .count_all, .count => acc.n = sn,
                .count_distinct => acc.n = dn,
                .sum => {
                    acc.isum = ss;
                    acc.n = 1;
                },
                .avg => {
                    acc.isum = ss;
                    acc.n = sn;
                },
                .min, .max => {},
            }
            accs[k] = acc;
        }
    }
    if (need_firsts) {
        var w: usize = 0;
        for (0..ng) |g| if (firsts[g] != std.math.maxInt(u32)) {
            w += 1;
        };
        const gsel = try alloc.alloc(Group, w);
        const asel = try alloc.alloc(Acc, w * nspec);
        var k: usize = 0;
        for (0..ng) |g| {
            if (firsts[g] == std.math.maxInt(u32)) continue;
            gsel[k] = .{ .first = firsts[g], .acc_off = k * nspec };
            @memcpy(asel[k * nspec ..][0..nspec], accs[g * nspec ..][0..nspec]);
            k += 1;
        }
        alloc.free(groups);
        alloc.free(accs);
        return .{ .groups = gsel, .accs = asel };
    }
    return .{ .groups = groups, .accs = accs };
}
fn scalarAggParallel(t: *Table, alloc: std.mem.Allocator, specs: []const AggSpec, selection: Sel, pre: ?[]?i64) ![]Value {
    var uniques = std.ArrayList(AggSpec).empty;
    defer uniques.deinit(alloc);
    const uid = try alloc.alloc(i32, specs.len);
    for (specs, 0..) |spec, si| {
        uid[si] = -1;
        if ((spec.kind == .sum or spec.kind == .avg) and spec.col >= 0) {
            var found: i32 = -1;
            for (uniques.items, 0..) |u, ui| {
                if (u.kind == spec.kind and u.col == spec.col) {
                    found = @intCast(ui);
                    break;
                }
            }
            if (found < 0) {
                found = @intCast(uniques.items.len);
                try uniques.append(alloc, .{ .kind = spec.kind, .col = spec.col, .offset = 0 });
            }
            uid[si] = found;
        } else {
            uid[si] = @intCast(uniques.items.len);
            try uniques.append(alloc, spec);
        }
    }
    const uspecs = uniques.items;
    const nthreads = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
    const chunk = (selection.len() + nthreads - 1) / nthreads;
    var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
    defer alloc.free(arenas);
    var locals = try alloc.alloc([]Acc, nthreads);
    defer alloc.free(locals);
    var threads = try alloc.alloc(?std.Thread, nthreads);
    defer alloc.free(threads);
    const Worker = struct {
        t: *Table,
        specs: []const AggSpec,
        sel: Sel,
        start: usize,
        end: usize,
        accs: []Acc,
        alloc: std.mem.Allocator,
        err: bool = false,
        pre: ?[]?i64,
        fn run(self: *@This()) void {
            var ri_i = self.start;
            while (ri_i < self.end) : (ri_i += 1) {
                const ri = self.sel.at(ri_i);
                for (self.specs, 0..) |spec, si| {
                    if (self.pre) |pv| {
                        if (pv[si] != null) continue;
                    }
                    accUpdate(&self.accs[si], spec, self.t, ri, self.alloc) catch {
                        self.err = true;
                        return;
                    };
                }
            }
        }
    };
    var workers = try alloc.alloc(Worker, nthreads);
    defer alloc.free(workers);
    for (0..nthreads) |i| {
        const s0 = i * chunk;
        const e0 = @min(s0 + chunk, selection.len());
        arenas[i] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const a = arenas[i].allocator();
        locals[i] = try a.alloc(Acc, uspecs.len);
        for (locals[i]) |*x| x.* = .{};
        workers[i] = .{ .t = t, .specs = uspecs, .sel = selection, .start = s0, .end = e0, .accs = locals[i], .alloc = a, .pre = pre };
        threads[i] = null;
        threads[i] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, Worker.run, .{&workers[i]}) catch null;
        if (threads[i] == null and s0 < e0) Worker.run(&workers[i]);
    }
    for (0..nthreads) |i| if (threads[i]) |th| th.join();
    const total = try alloc.alloc(Acc, uspecs.len);
    for (total) |*x| x.* = .{};
    for (0..nthreads) |i| {
        for (uspecs, 0..) |spec, si| {
            const src = locals[i][si];
            total[si].isum += src.isum;
            total[si].fsum += src.fsum;
            total[si].n += src.n;
            total[si].has_float = total[si].has_float or src.has_float;
            if (src.has_best) {
                if (!total[si].has_best) {
                    total[si].best = src.best;
                    total[si].has_best = true;
                } else if (spec.kind == .min or spec.kind == .max) {
                    const ord = Value.order(src.best, total[si].best);
                    if ((spec.kind == .min and ord == .lt) or (spec.kind == .max and ord == .gt)) total[si].best = src.best;
                }
            }
        }
        arenas[i].deinit();
    }
    const vals = try alloc.alloc(Value, specs.len);
    for (specs, 0..) |spec, si| {
        const ui: usize = @intCast(uid[si]);
        if (pre) |pv| {
            if (pv[si]) |base| {
                const n: i128 = @intCast(selection.len());
                const jt: i128 = @as(i128, base) + @as(i128, spec.offset) * n;
                if (spec.kind == .sum) {
                    if (jt > std.math.maxInt(i64) or jt < std.math.minInt(i64)) {
                        vals[si] = .{ .float = @floatFromInt(jt) };
                    } else {
                        vals[si] = .{ .int = @intCast(jt) };
                    }
                } else {
                    vals[si] = .{ .float = @as(f64, @floatFromInt(jt)) / @as(f64, @floatFromInt(n)) };
                }
                continue;
            }
        }
        if (spec.offset != 0 and (spec.kind == .sum or spec.kind == .avg)) {
            const a = &total[ui];
            const n = a.n;
            const delta: i128 = @as(i128, spec.offset) * n;
            if (spec.kind == .sum) {
                if (a.has_float) {
                    vals[si] = .{ .float = a.fsum + @as(f64, @floatFromInt(delta)) };
                } else if (a.isum + delta > std.math.maxInt(i64)) {
                    vals[si] = .{ .float = @floatFromInt(a.isum + delta) };
                } else {
                    vals[si] = .{ .int = @intCast(a.isum + delta) };
                }
            } else {
                const s: f64 = if (a.has_float) a.fsum else @floatFromInt(a.isum);
                vals[si] = .{ .float = (s + @as(f64, @floatFromInt(delta))) / @as(f64, @floatFromInt(n)) };
            }
        } else {
            vals[si] = finalize(&total[ui], spec);
        }
    }
    return vals;
}
fn emitScalar(t: *Table, alloc: std.mem.Allocator, sel: *sql.Select, specs: []const AggSpec, vals: []const Value) !QueryResult {
    var row = std.ArrayList(Value).empty;
    var cols = std.ArrayList([]const u8).empty;
    for (sel.items) |it| {
        if (findSpecIndex(specs, t, it.expr)) |si| {
            try row.append(alloc, vals[si]);
        } else {
            try row.append(alloc, toValue(evalScalar(t, it.expr, 0)));
        }
        try cols.append(alloc, it.alias orelse exprLabel(it.expr));
    }
    const rows = try alloc.alloc([]Value, 1);
    rows[0] = try row.toOwnedSlice(alloc);
    return .{ .columns = try cols.toOwnedSlice(alloc), .rows = rows, .format_json = sel.format_json };
}
fn lengthCallCol(t: *const Table, e: ?*sql.Expr) ?usize {
    const ex = e orelse return null;
    if (ex.* != .call) return null;
    const c = ex.call;
    if (!std.ascii.eqlIgnoreCase(c.name, "length") or c.args.len != 1) return null;
    const ci: usize = switch (c.args[0].*) {
        .column_idx => |x| x.idx,
        .column => |name| t.find(name) orelse return null,
        else => return null,
    };
    if (t.data[ci] != .strs) return null;
    return ci;
}
var prof_t0: i128 = 0;
fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}
fn profReset() void {
    prof_t0 = nowNs();
}
fn prof(label: []const u8) void {
    if (std.c.getenv("ZHDB_PROF") == null) return;
    const now = nowNs();
    std.debug.print("  [prof] {s}: {d:.2} ms\n", .{ label, @as(f64, @floatFromInt(now - prof_t0)) / 1e6 });
    prof_t0 = now;
}
const Civil = struct { y: i64, m: u32, d: u32 };
threadlocal var ts_buf: [32]u8 = undefined;
fn civilOfDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else -9);
    if (m <= 2) y += 1;
    return .{ .y = y, .m = @intCast(m), .d = @intCast(d) };
}
fn daysOfCivil(y_in: i64, m: u32, d: u32) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) @as(i64, m) - 3 else @as(i64, m) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}
fn baseKeyColumn(t: *const Table, e: *sql.Expr) ?usize {
    switch (e.*) {
        .column_idx => |c| return c.idx,
        .column => |name| return t.find(name),
        .binary => |b| {
            const is_add = b.op == .add or b.op == .sub;
            if (!is_add) return null;
            const lhs_col: ?usize = switch (b.lhs.*) {
                .column_idx => |c| c.idx,
                .column => |name| t.find(name),
                else => null,
            };
            const rhs_const = switch (b.rhs.*) {
                .int => true,
                else => false,
            };
            if (lhs_col != null and rhs_const) return lhs_col;
            return null;
        },
        else => return null,
    }
}
fn bindExprIdx(t: *const Table, e: *sql.Expr) void {
    switch (e.*) {
        .column => |name| {
            if (t.find(name)) |ci| {
                e.* = .{ .column_idx = .{ .idx = @intCast(ci), .name = name } };
            }
        },
        .binary => |b| {
            bindExprIdx(t, b.lhs);
            bindExprIdx(t, b.rhs);
        },
        .negate => |x| bindExprIdx(t, x),
        .not => |x| bindExprIdx(t, x),
        .is_null => |x| bindExprIdx(t, x.operand),
        .like => |x| {
            bindExprIdx(t, x.operand);
            bindExprIdx(t, x.pattern);
        },
        .in_list => |x| {
            bindExprIdx(t, x.operand);
            for (x.items) |it| bindExprIdx(t, it);
        },
        .between => |x| {
            bindExprIdx(t, x.operand);
            bindExprIdx(t, x.low);
            bindExprIdx(t, x.high);
        },
        .cast => |x| bindExprIdx(t, x.operand),
        .call => |c| for (c.args) |a| {
            bindExprIdx(t, a);
        },
        .case_expr => |c| {
            for (c.whens) |w| {
                bindExprIdx(t, w.cond);
                bindExprIdx(t, w.then);
            }
            if (c.else_expr) |x| bindExprIdx(t, x);
        },
        else => {},
    }
}
fn exprEpochKeyOk(t: *const Table, e: *sql.Expr) bool {
    if (e.* != .call) return false;
    const c = e.call;
    var src: ?*sql.Expr = null;
    if (std.ascii.eqlIgnoreCase(c.name, "extract") or std.ascii.eqlIgnoreCase(c.name, "date_trunc")) {
        if (c.args.len != 2 or c.args[0].* != .string) return false;
        src = c.args[1];
    } else if (std.ascii.eqlIgnoreCase(c.name, "to_timestamp") or
        std.ascii.eqlIgnoreCase(c.name, "from_unixtime"))
    {
        if (c.args.len != 1) return false;
        src = c.args[0];
    } else return false;
    var s2 = src.?;
    if (s2.* == .call) {
        const inner = s2.call;
        if ((std.ascii.eqlIgnoreCase(inner.name, "to_timestamp") or
            std.ascii.eqlIgnoreCase(inner.name, "from_unixtime")) and inner.args.len == 1)
        {
            s2 = inner.args[0];
        } else return false;
    }
    const ci: usize = switch (s2.*) {
        .column_idx => |x| x.idx,
        .column => |name| t.find(name) orelse return false,
        else => return false,
    };
    return t.data[ci].isInt();
}
fn earlyPickGroups(
    alloc: std.mem.Allocator,
    group_keys: []const KeySrc,
    specs: []const AggSpec,
    selection: Sel,
    k: usize,
) !?ShardedGroups {
    if (k == 0 or k > 1024 or group_keys.len == 0 or group_keys.len > 3) return null;
    for (specs) |sp| {
        if (sp.kind != .count_all and sp.kind != .count) return null;
    }
    const n = selection.len();
    if (n == 0) return null;
    const cap0: usize = 64;
    var cap = cap0;
    while (cap < k * 4 + 64) cap <<= 1;
    const mask = cap - 1;
    const reps = try alloc.alloc(u32, cap); // 0 = empty, else row+1
    defer alloc.free(reps);
    @memset(reps, 0);
    const fps = try alloc.alloc(u64, cap);
    defer alloc.free(fps);
    @memset(fps, 0);
    const fpOf = struct {
        fn f(keys: []const KeySrc, row: usize) u64 {
            var h: u64 = 0x9E3779B97F4A7C15;
            for (keys) |kk| {
                const v = kk.at(row);
                h = (h ^ @as(u64, @bitCast(v))) *% 0x9E3779B97F4A7C15;
                h ^= h >> 29;
            }
            return h;
        }
    }.f;
    const eq = struct {
        fn f(keys: []const KeySrc, a: usize, b: usize) bool {
            for (keys) |kk| {
                if (kk.at(a) != kk.at(b)) return false;
            }
            return true;
        }
    }.f;
    var ng: usize = 0;
    const collect_cap = @min(n, @max(8192, k * 64));
    var i: usize = 0;
    while (i < collect_cap and ng < k) : (i += 1) {
        const ri = selection.at(i);
        const fp = fpOf(group_keys, ri);
        var idx: usize = @intCast(fp & mask);
        while (true) {
            if (reps[idx] == 0) {
                reps[idx] = @intCast(ri + 1);
                fps[idx] = fp;
                ng += 1;
                break;
            }
            const other: usize = reps[idx] - 1;
            if (fps[idx] == fp and eq(group_keys, other, ri)) break;
            idx = (idx + 1) & mask;
        }
    }
    if (ng < k) return null;
    const counts = try alloc.alloc(i64, cap);
    defer alloc.free(counts);
    @memset(counts, 0);
    var si: usize = 0;
    while (si < n) : (si += 1) {
        const ri = selection.at(si);
        const fp = fpOf(group_keys, ri);
        var idx: usize = @intCast(fp & mask);
        while (reps[idx] != 0) {
            if (fps[idx] == fp and eq(group_keys, reps[idx] - 1, ri)) {
                counts[idx] += 1;
                break;
            }
            idx = (idx + 1) & mask;
        }
    }
    const groups = try alloc.alloc(Group, ng);
    errdefer alloc.free(groups);
    const accs = try alloc.alloc(Acc, ng * specs.len);
    var w: usize = 0;
    for (0..cap) |idx| {
        if (reps[idx] == 0) continue;
        groups[w] = .{ .first = reps[idx] - 1, .acc_off = w * specs.len };
        for (0..specs.len) |s2| {
            accs[w * specs.len + s2] = .{ .n = counts[idx] };
        }
        w += 1;
    }
    return .{ .groups = groups, .accs = accs };
}
fn exprEpochKey(t: *const Table, alloc: std.mem.Allocator, e: *sql.Expr, selection: ?Sel) !?[]i64 {
    if (e.* != .call) return null;
    const c = e.call;
    var src: ?*sql.Expr = null;
    var unit: []const u8 = "";
    var mode: enum { extract, trunc, plain } = .plain;
    if (std.ascii.eqlIgnoreCase(c.name, "extract")) {
        if (c.args.len != 2 or c.args[0].* != .string) return null;
        unit = c.args[0].string;
        src = c.args[1];
        mode = .extract;
    } else if (std.ascii.eqlIgnoreCase(c.name, "date_trunc")) {
        if (c.args.len != 2 or c.args[0].* != .string) return null;
        unit = c.args[0].string;
        src = c.args[1];
        mode = .trunc;
    } else if (std.ascii.eqlIgnoreCase(c.name, "to_timestamp") or
        std.ascii.eqlIgnoreCase(c.name, "from_unixtime"))
    {
        if (c.args.len != 1) return null;
        src = c.args[0];
    } else return null;
    var s2 = src.?;
    if (s2.* == .call) {
        const inner = s2.call;
        if ((std.ascii.eqlIgnoreCase(inner.name, "to_timestamp") or
            std.ascii.eqlIgnoreCase(inner.name, "from_unixtime")) and inner.args.len == 1)
        {
            s2 = inner.args[0];
        } else return null;
    }
    const ci: usize = switch (s2.*) {
        .column_idx => |x| x.idx,
        .column => |name| t.find(name) orelse return null,
        else => return null,
    };
    if (!t.data[ci].isInt()) return null;
    const out = try alloc.alloc(i64, t.nrows);
    const nsel: usize = if (selection) |sel| sel.len() else t.nrows;
    var si: usize = 0;
    while (si < nsel) : (si += 1) {
        const ri: usize = if (selection) |sel| sel.at(si) else si;
        const secs = t.data[ci].intAt(ri);
        switch (mode) {
            .plain => out[ri] = secs,
            .trunc => {
                if (std.ascii.eqlIgnoreCase(unit, "minute")) {
                    out[ri] = secs - @mod(secs, 60);
                } else if (std.ascii.eqlIgnoreCase(unit, "hour")) {
                    out[ri] = secs - @mod(secs, 3600);
                } else if (std.ascii.eqlIgnoreCase(unit, "day")) {
                    out[ri] = secs - @mod(secs, 86400);
                } else if (std.ascii.eqlIgnoreCase(unit, "month")) {
                    const civ = civilOfDays(@divFloor(secs, 86400));
                    out[ri] = daysOfCivil(civ.y, civ.m, 1) * 86400;
                } else if (std.ascii.eqlIgnoreCase(unit, "year")) {
                    const civ = civilOfDays(@divFloor(secs, 86400));
                    out[ri] = daysOfCivil(civ.y, 1, 1) * 86400;
                } else out[ri] = secs;
            },
            .extract => {
                const days = @divFloor(secs, 86400);
                const sod: i64 = secs - days * 86400;
                if (std.ascii.eqlIgnoreCase(unit, "epoch")) {
                    out[ri] = secs;
                } else if (std.ascii.eqlIgnoreCase(unit, "hour")) {
                    out[ri] = @divFloor(sod, 3600);
                } else if (std.ascii.eqlIgnoreCase(unit, "minute")) {
                    out[ri] = @divFloor(sod, 60) - @divFloor(sod, 3600) * 60;
                } else if (std.ascii.eqlIgnoreCase(unit, "second")) {
                    out[ri] = @mod(sod, 60);
                } else if (std.ascii.eqlIgnoreCase(unit, "year")) {
                    out[ri] = civilOfDays(days).y;
                } else if (std.ascii.eqlIgnoreCase(unit, "month")) {
                    out[ri] = civilOfDays(days).m;
                } else if (std.ascii.eqlIgnoreCase(unit, "day")) {
                    out[ri] = civilOfDays(days).d;
                } else return null;
            },
        }
    }
    return out;
}
fn maxIdCount(t: *Table, ci: usize) u32 {
    const e = t.enc[ci] orelse return 0;
    var mx: u32 = 0;
    for (e.counts) |c| mx = @max(mx, c);
    return mx;
}
const no_col: u32 = 0xFFFF_FFFF;
const KeySrc = struct {
    ids: ?[]const u32 = null,
    raw: ?[*]const i64 = null,
    narrow: ?Data = null,
    inline fn at(self: KeySrc, ri: usize) i64 {
        if (self.ids) |s| return s[ri];
        if (self.raw) |p| return p[ri];
        return self.narrow.?.intAt(ri);
    }
};
fn jitGroupAgg(t: *Table, alloc: std.mem.Allocator, group_keys: []const KeySrc, group_cols: []const u32, specs: []const AggSpec, rows_sel: Sel, sel_q: *sql.Select, s: *Scratch) !?ShardedGroups {
    if (group_keys.len < 1 or group_keys.len > 3 or group_cols.len != group_keys.len) return null;
    for (group_cols, 0..) |gc, ki| {
        if (gc == no_col) {
            if (group_keys[ki].raw == null) return null;
            continue;
        }
        if (t.valid.len > gc and t.valid[gc] != null) return null; // NULL keys: generic path
        switch (t.data[gc]) {
            .ints, .ints8, .ints16, .ints32 => {},
            .strs => if (t.enc[gc] == null) return null,
            else => return null,
        }
    }
    const n = rows_sel.len();
    if (n < 16) return null;
    profReset();
    var kinds = std.ArrayList(jit.GroupSpec).empty;
    defer kinds.deinit(alloc);
    var sum_src = std.ArrayList([*]const i64).empty;
    defer sum_src.deinit(alloc);
    var sum_views: [3]?Data = .{ null, null, null };
    var derived_len = std.ArrayList([]i64).empty;
    defer derived_len.deinit(alloc);
    const map = try alloc.alloc(i32, specs.len);
    var avg_count: ?usize = null;
    for (specs, 0..) |sp, si| {
        map[si] = -1;
        switch (sp.kind) {
            .count_all => {
                map[si] = @intCast(kinds.items.len);
                try kinds.append(alloc, .count_all);
            },
            .count => {
                map[si] = @intCast(kinds.items.len);
                try kinds.append(alloc, .count_all);
            },
            .sum, .avg => {
                if (sp.col < 0) {
                    const strcol = lengthCallCol(t, sp.expr) orelse return null;
                    const lenarr = try alloc.alloc(i64, t.nrows);
                    for (0..t.nrows) |ri| lenarr[ri] = @intCast(t.data[strcol].strs.at(ri).len);
                    if (kinds.items.len >= 3) return null;
                    const ptr_idx: u8 = @intCast(sum_src.items.len);
                    map[si] = @intCast(kinds.items.len);
                    try kinds.append(alloc, .{ .sum = .{ .ptr = ptr_idx, .width = 8 } });
                    try sum_src.append(alloc, lenarr.ptr);
                    try derived_len.append(alloc, lenarr);
                    sum_views[ptr_idx] = .{ .ints = lenarr };
                    continue;
                }
                if (!t.data[@intCast(sp.col)].isInt()) return null;
                if (kinds.items.len >= 3) return null;
                const ptr_idx: u8 = @intCast(sum_src.items.len);
                map[si] = @intCast(kinds.items.len);
                const sum_data = t.data[@intCast(sp.col)];
                const width: u8 = switch (sum_data) {
                    .ints8 => 1,
                    .ints16 => 2,
                    .ints32 => 4,
                    else => 8,
                };
                const sptr: [*]const i64 = switch (sum_data) {
                    .ints => |a| a.ptr,
                    .ints8 => |a| @ptrFromInt(@intFromPtr(a.ptr)),
                    .ints16 => |a| @ptrFromInt(@intFromPtr(a.ptr)),
                    .ints32 => |a| @ptrFromInt(@intFromPtr(a.ptr)),
                    else => unreachable,
                };
                try kinds.append(alloc, .{ .sum = .{ .ptr = ptr_idx, .width = width } });
                try sum_src.append(alloc, sptr);
                sum_views[ptr_idx] = sum_data;
            },
            .count_distinct, .min, .max => return null,
        }
    }
    for (specs, 0..) |sp, si| {
        _ = si;
        if (sp.kind == .avg) {
            var have = false;
            for (specs) |o| if (o.kind == .count_all or o.kind == .count) {
                have = true;
            };
            if (!have) {
                if (kinds.items.len >= 3) return null;
                avg_count = kinds.items.len;
                try kinds.append(alloc, .count_all);
            }
        }
    }
    const kc: usize = group_cols.len;
    if (kc > 3) return null;
    var has_expr_key = false;
    for (group_cols) |gc| {
        if (gc == no_col) has_expr_key = true;
    }
    const T: usize = 8;
    const k0 = group_keys[0];
    if (k0.ids == null and k0.raw == null and k0.narrow == null) return null;
    const k1 = if (kc > 1) group_keys[1] else k0;
    if (kc > 1 and k1.ids == null and k1.raw == null and k1.narrow == null) return null;
    const k2 = if (kc > 2) group_keys[2] else k0;
    if (kc > 2 and k2.ids == null and k2.raw == null and k2.narrow == null) return null;
    const all_raw = k0.raw != null and (kc < 2 or k1.raw != null) and (kc < 3 or k2.raw != null);
    const all_ids = k0.ids != null and (kc < 2 or k1.ids != null) and (kc < 3 or k2.ids != null);
    const collapse = kc == 2 and all_ids and std.c.getenv("ZHDB_NO_COLLAPSE") == null;
    const pack_hi_skewed = collapse and maxIdCount(t, group_cols[0]) >= maxIdCount(t, group_cols[1]);
    const eff_kc: usize = if (collapse) 1 else kc;
    var dummy_key: i64 = 0;
    const dummy_ptr: [*]const i64 = @ptrCast(&dummy_key);
    var sums: [3][*]const i64 = .{ k0.raw orelse dummy_ptr, k0.raw orelse dummy_ptr, k0.raw orelse dummy_ptr };
    for (sum_src.items, 0..) |ptr, idx| {
        if (idx < 3) sums[idx] = ptr;
    }
    const low_card = blk: {
        for (group_keys) |k| {
            if (k.ids == null) break :blk false;
            if (k.ids.?.len > 65_536) break :blk false;
        }
        break :blk true;
    };
    const rescan = rows_sel.list == null and low_card and (all_raw or all_ids) and !collapse;
    const key32_live = rescan and all_ids and std.c.getenv("ZHDB_NO_KEY32") == null;
    if (!rescan) {
        for (kinds.items) |*k| switch (k.*) {
            .sum => |*ss| ss.width = 8,
            else => {},
        };
    }
    var exe = try jit.compileGroupAgg(alloc, @intCast(eff_kc), kinds.items, key32_live);
    defer exe.deinit();
    const f = exe.as(*const fn (*jit.GroupCtx) callconv(.c) u64);
    const P: usize = blk: {
        if (std.c.getenv("ZHDB_GP")) |v| {
            const gpn = std.fmt.parseInt(usize, std.mem.span(v), 10) catch 64;
            if (gpn >= 1 and gpn <= 64 and std.math.isPowerOfTwo(gpn)) break :blk gpn;
        }
        break :blk 64;
    };
    const nb: usize = if (rescan) T else P;
    const counts = try alloc.alloc(usize, nb + 1);
    defer alloc.free(counts);
    @memset(counts, 0);
    var offs: [64]usize = @splat(0);
    var sizes: [64]usize = @splat(0);
    var order: []u32 = &.{};
    var ga_all: []i64 = &.{};
    var gb_all: []i64 = &.{};
    var gc_all: []i64 = &.{};
    var gs_all: [3][]i64 = .{ &.{}, &.{}, &.{} };
    var own: [7]bool = @splat(false);
    defer {
        if (own[0]) alloc.free(order);
        if (own[1]) alloc.free(ga_all);
        if (own[2]) alloc.free(gb_all);
        if (own[3]) alloc.free(gc_all);
        for (0..3) |q| if (own[4 + q]) alloc.free(gs_all[q]);
    }
    if (!rescan) {
    const nsums2: usize = sum_src.items.len;
    var single = false;
    {
        const capb = n / nb + n / (nb * 4) + 64;
        const total_cap = capb * nb;
        const so = s.alloc(u32, total_cap);
        const sa = s.alloc(i64, total_cap);
        const sb = if (kc > 1 and !collapse) s.alloc(i64, total_cap) else sa;
        const sc = if (kc > 2) s.alloc(i64, total_cap) else sa;
        var sg: [3][]i64 = .{ sa orelse &.{}, sa orelse &.{}, sa orelse &.{} };
        var sg_ok = true;
        for (0..nsums2) |q| {
            if (s.alloc(i64, total_cap)) |sl| {
                sg[q] = sl;
            } else {
                sg_ok = false;
            }
        }
        if (so != null and sa != null and sb != null and sc != null and sg_ok) {
            const mix1 = struct {
                fn mix2(x: i64) u64 {
                    const cc: u64 = 0x9E3779B97F4A7C15;
                    const h = @as(u64, @bitCast(x)) *% cc;
                    return h ^ (h >> 29);
                }
            }.mix2;
            var cur: [64]usize = @splat(0);
            var overflow = false;
            var pi: usize = 0;
            while (pi < n) : (pi += 1) {
                const ri = rows_sel.at(pi);
                const ka: i64 = if (collapse) blk: {
                    const ia: i64 = k0.ids.?[ri];
                    const ib: i64 = k1.ids.?[ri];
                    break :blk if (pack_hi_skewed) (ia << 32) | ib else (ib << 32) | ia;
                } else k0.at(ri);
                var h = mix1(ka);
                if (kc > 1 and !collapse) h ^= mix1(k1.at(ri));
                if (kc > 2) h ^= mix1(k2.at(ri));
                const b: usize = @intCast(h & (nb - 1));
                if (cur[b] == capb) {
                    overflow = true;
                    break;
                }
                const pos = b * capb + cur[b];
                so.?[pos] = ri;
                sa.?[pos] = ka;
                if (kc > 1 and !collapse) sb.?[pos] = k1.at(ri);
                if (kc > 2) sc.?[pos] = k2.at(ri);
                if (nsums2 > 0) sg[0][pos] = if (sum_views[0]) |v| v.intAt(ri) else 0;
                if (nsums2 > 1) sg[1][pos] = if (sum_views[1]) |v| v.intAt(ri) else 0;
                if (nsums2 > 2) sg[2][pos] = if (sum_views[2]) |v| v.intAt(ri) else 0;
                cur[b] += 1;
            }
            if (overflow and std.c.getenv("ZHDB_PROF") != null) {
                std.debug.print("  [prof] single-pass OVERFLOW -> two-pass\n", .{});
            }
            if (!overflow) {
                single = true;
                order = so.?;
                ga_all = sa.?;
                gb_all = sb.?;
                gc_all = sc.?;
                gs_all = sg;
                for (0..nb) |ti| {
                    offs[ti] = ti * capb;
                    sizes[ti] = cur[ti];
                }
            }
        }
    }
    if (!single) {
        const bkt_reuse = s.alloc(u8, n);
        const bkt = bkt_reuse orelse try alloc.alloc(u8, n);
        defer if (bkt_reuse == null) alloc.free(bkt);
        {
            const HW = struct {
                a: KeySrc,
                b: KeySrc,
                c: KeySrc,
                kc: usize,
                sel: Sel,
                counts: []usize,
                nb: usize, // bucket count (power of two)
                bkt: []u8,
                start: usize,
                end: usize,
                fn run(self: *@This()) void {
                    const m = struct {
                        fn mix1(x: i64) u64 {
                            const cc: u64 = 0x9E3779B97F4A7C15;
                            const h = @as(u64, @bitCast(x)) *% cc;
                            return h ^ (h >> 29);
                        }
                    }.mix1;
                    var local: [64]usize = @splat(0);
                    const mask = self.nb - 1;
                    var i = self.start;
                    while (i < self.end) : (i += 1) {
                        const ri = self.sel.at(i);
                        var h = m(self.a.at(ri));
                        if (self.kc > 1) h ^= m(self.b.at(ri));
                        if (self.kc > 2) h ^= m(self.c.at(ri));
                        _ = &h;
                        const b = @as(usize, @intCast(h & mask));
                        local[b] += 1;
                        self.bkt[i] = @intCast(b);
                    }
                    for (0..self.nb) |k| self.counts[k] += local[k];
                }
            };
            const nthreads = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
            const chunk = (n + nthreads - 1) / nthreads;
            var hw: [8]HW = undefined;
            var ht: [8]?std.Thread = undefined;
            for (0..nthreads) |i| {
                const s0 = i * chunk;
                const e0 = @min(s0 + chunk, n);
                hw[i] = .{ .a = k0, .b = k1, .c = k2, .kc = kc, .sel = rows_sel, .counts = counts[1..], .nb = nb, .bkt = bkt, .start = s0, .end = e0 };
                ht[i] = null;
                if (s0 < e0) ht[i] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, HW.run, .{&hw[i]}) catch null;
                if (ht[i] == null and s0 < e0) hw[i].run();
            }
            for (0..nthreads) |i| if (ht[i]) |th| th.join();
        }
        for (1..nb + 1) |i| counts[i] += counts[i - 1];
        for (0..nb) |ti| {
            offs[ti] = counts[ti];
            sizes[ti] = counts[ti + 1] - counts[ti];
        }
        order = try alloc.alloc(u32, n);
        own[0] = true;
        const ga_reuse = s.alloc(i64, n);
        ga_all = ga_reuse orelse blk: {
            own[1] = true;
            break :blk try alloc.alloc(i64, n);
        };
        if (kc > 1 and !collapse) {
            const r = s.alloc(i64, n);
            gb_all = r orelse blk: {
                own[2] = true;
                break :blk try alloc.alloc(i64, n);
            };
        } else gb_all = ga_all;
        if (kc > 2) {
            const r = s.alloc(i64, n);
            gc_all = r orelse blk: {
                own[3] = true;
                break :blk try alloc.alloc(i64, n);
            };
        } else gc_all = ga_all;
        for (0..3) |q| gs_all[q] = ga_all;
        for (0..nsums2) |q| {
            const r = s.alloc(i64, n);
            if (r) |sl| {
                gs_all[q] = sl;
            } else {
                gs_all[q] = try alloc.alloc(i64, n);
                own[4 + q] = true;
            }
        }
        {
            const mix1 = struct {
                fn mix2(x: i64) u64 {
                    const cc: u64 = 0x9E3779B97F4A7C15;
                    const h = @as(u64, @bitCast(x)) *% cc;
                    return h ^ (h >> 29);
                }
            }.mix2;
            _ = mix1;
            const cursor = try alloc.alloc(usize, nb);
            defer alloc.free(cursor);
            @memcpy(cursor, counts[0..nb]);
            var pi: usize = 0;
            while (pi < n) : (pi += 1) {
                const ri = rows_sel.at(pi);
                const b: usize = bkt[pi];
                const pos = cursor[b];
                order[pos] = ri;
                ga_all[pos] = if (collapse) blk: {
                    const ia: i64 = k0.ids.?[ri];
                    const ib: i64 = k1.ids.?[ri];
                    break :blk if (pack_hi_skewed) (ia << 32) | ib else (ib << 32) | ia;
                } else k0.at(ri);
                if (kc > 1 and !collapse) gb_all[pos] = k1.at(ri);
                if (kc > 2) gc_all[pos] = k2.at(ri);
                if (nsums2 > 0) gs_all[0][pos] = sums[0][ri];
                if (nsums2 > 1) gs_all[1][pos] = sums[1][ri];
                if (nsums2 > 2) gs_all[2][pos] = sums[2][ri];
                cursor[b] += 1;
            }
        }
    }
    }
    prof("hash+partition");
    const nsums: usize = sum_src.items.len;
    _ = &nsums;
    const Worker = struct {
        ctx: jit.GroupCtx,
        ng: u64 = 0,
    };
    var workers: [64]Worker = undefined;
    var slots_t: [64][]u32 = undefined;
    const rstride: usize = if (kinds.items.len == 1) 2 else 4;
    var recs_t: [64][]i64 = undefined;
    var rows_t: [64][]u32 = undefined;
    const rescan_cap = n / T + n / (T * 4) + 64;
    for (0..nb) |ti| {
        const cnt = if (rescan) rescan_cap else sizes[ti];
        rows_t[ti] = if (rescan) order[0..0] else order[offs[ti] .. offs[ti] + cnt];
        var cap: usize = 16;
        while (cap < cnt * 2 + 16) cap <<= 1;
        slots_t[ti] = try alloc.alloc(u32, cap);
        @memset(slots_t[ti], 0);
        recs_t[ti] = try alloc.alloc(i64, (cnt + 1) * rstride);
        @memset(recs_t[ti], 0);
        workers[ti] = .{
            .ctx = if (rescan) .{
                .a = if (k0.ids) |v| @ptrFromInt(@intFromPtr(v.ptr)) else k0.raw.?,
                .b = if (k1.ids) |v| @ptrFromInt(@intFromPtr(v.ptr)) else k1.raw.?,
                .c = if (k2.ids) |v| @ptrFromInt(@intFromPtr(v.ptr)) else k2.raw.?,
                .n = t.nrows,
                .slots = slots_t[ti].ptr,
                .mask = cap - 1,
                .firsts = @ptrCast(recs_t[ti].ptr),
                .acc0 = @constCast(k0.raw orelse dummy_ptr),
                .acc1 = @constCast(k0.raw orelse dummy_ptr),
                .acc2 = @constCast(k0.raw orelse dummy_ptr),
                .sum0 = sums[0],
                .sum1 = sums[1],
                .sum2 = sums[2],
                .ng = undefined,
                .shard_mask = T - 1,
                .shard_id = ti,
            } else .{
                .a = ga_all.ptr + offs[ti],
                .b = gb_all.ptr + offs[ti],
                .c = gc_all.ptr + offs[ti],
                .n = cnt,
                .slots = slots_t[ti].ptr,
                .mask = cap - 1,
                .firsts = @ptrCast(recs_t[ti].ptr),
                .acc0 = @constCast(ga_all.ptr),
                .acc1 = @constCast(ga_all.ptr),
                .acc2 = @constCast(ga_all.ptr),
                .sum0 = gs_all[0].ptr + offs[ti],
                .sum1 = gs_all[1].ptr + offs[ti],
                .sum2 = gs_all[2].ptr + offs[ti],
                .ng = undefined,
                .shard_mask = 0,
                .shard_id = 0,
            },
        };
        workers[ti].ctx.ng = &workers[ti].ng;
    }
    const Runner = struct {
        f: *const fn (*jit.GroupCtx) callconv(.c) u64,
        ws: []Worker,
        start: usize,
        stride: usize,
        fn run(self: *@This()) void {
            var p = self.start;
            while (p < self.ws.len) : (p += self.stride) {
                const w = &self.ws[p];
                w.ng = if (w.ctx.n == 0) 0 else self.f(&w.ctx);
            }
        }
    };
    var runners: [T]Runner = undefined;
    var threads: [T]?std.Thread = undefined;
    for (0..T) |ti| {
        runners[ti] = .{ .f = f, .ws = workers[0..nb], .start = ti, .stride = T };
        threads[ti] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, Runner.run, .{&runners[ti]}) catch null;
        if (threads[ti] == null) runners[ti].run();
    }
    for (0..T) |ti| if (threads[ti]) |th| th.join();
    {
        var counted: ?usize = null;
        for (specs, 0..) |sp, si| {
            if (sp.kind == .count_all or sp.kind == .count) {
                counted = si;
                break;
            }
        }
        if (counted) |si| {
            const ui: usize = @intCast(map[si]);
            var total: i64 = 0;
            for (0..nb) |ti| {
                const cnt: usize = @intCast(workers[ti].ng);
                const recs = recs_t[ti];
                for (0..cnt) |gi| total += recs[gi * rstride + 1 + ui];
            }
            if (total != @as(i64, @intCast(n))) {
                if (std.c.getenv("ZHDB_PROF") != null) {
                    std.debug.print("  [prof] jitGroupAgg integrity FAIL total={d} n={d}\n", .{ total, n });
                }
                return null;
            }
        }
    }
    var keep_specs: ?usize = null;
    var keep_desc = false;
    var keep_k: usize = 0;
    if (sel_q.order_by.len == 1 and sel_q.limit != null) {
        const item = sel_q.order_by[0];
        var order_expr = item.expr;
        if (order_expr.* == .column) {
            const name = order_expr.column;
            for (sel_q.items) |it| {
                if (it.alias) |al| {
                    if (std.ascii.eqlIgnoreCase(al, name)) {
                        order_expr = it.expr;
                        break;
                    }
                }
            }
        }
        if (findSpecIndex(specs, t, order_expr)) |si| {
            const lim = exprUsize(t, sel_q.limit.?);
            const off = if (sel_q.offset) |o| exprUsize(t, o) else 0;
            keep_specs = si;
            keep_desc = item.desc;
            keep_k = lim + off;
        }
    }
    const Keyed = struct { key: f64, ti: usize, gi: usize };
    var selected = std.ArrayList(Keyed).empty;
    defer selected.deinit(alloc);
    prof("gather+kernel");
    var total_groups: usize = 0;
    for (0..nb) |ti| total_groups += @intCast(workers[ti].ng);
    prof("group-count");
    if (keep_specs != null) {
        if (keep_k > total_groups) keep_k = 0;
        if (keep_k > 512) keep_specs = null;
    }
    if (keep_specs != null and keep_k == 0) {
        total_groups = 0;
        prof("topk-scan");
    } else if (keep_specs) |si| {
        const ui: usize = @intCast(map[si]);
        const sp = specs[si];
        const cidx: ?usize = if (sp.kind == .avg) (avg_count orelse blk: {
            for (specs, 0..) |o, oi| {
                if (o.kind == .count_all or o.kind == .count) break :blk @as(usize, @intCast(map[oi]));
            }
            break :blk ui;
        }) else null;
        for (0..nb) |ti| {
            const cnt: usize = @intCast(workers[ti].ng);
            const recs = recs_t[ti];
            for (0..cnt) |gi| {
                const raw = recs[gi * rstride + 1 + ui];
                var key: f64 = @floatFromInt(raw);
                if (cidx) |ci| {
                    const gc = recs[gi * rstride + 1 + ci];
                    if (gc > 0) key = @as(f64, @floatFromInt(raw)) / @as(f64, @floatFromInt(gc));
                }
                if (selected.items.len == keep_k) {
                    const worst = selected.items[keep_k - 1].key;
                    const better = if (keep_desc) key > worst else key < worst;
                    if (!better) continue;
                    _ = selected.pop();
                }
                var at: usize = 0;
                while (at < selected.items.len) : (at += 1) {
                    const cur = selected.items[at].key;
                    const after = if (keep_desc) key > cur else key < cur;
                    if (after) break;
                }
                try selected.insert(alloc, at, .{ .key = key, .ti = ti, .gi = gi });
            }
        }
        total_groups = selected.items.len;
        prof("topk-scan");
    }
    var out_cap: ?usize = null;
    if (keep_specs == null and sel_q.order_by.len == 0 and sel_q.having == null and sel_q.limit != null) {
        const off = if (sel_q.offset) |o| exprUsize(t, o) else 0;
        out_cap = exprUsize(t, sel_q.limit.?) + off;
        total_groups = @min(total_groups, out_cap.?);
    }
    const g = try alloc.alloc(Group, total_groups);
    const accs = try alloc.alloc(Acc, total_groups * specs.len);
    var pos: usize = 0;
    var scan_ti: usize = 0;
    while (scan_ti < nb) : (scan_ti += 1) {
        const cnt: usize = if (keep_specs != null) blk: {
            var c: usize = 0;
            for (selected.items) |it| if (it.ti == scan_ti) {
                c += 1;
            };
            break :blk c;
        } else @intCast(workers[scan_ti].ng);
        var col: usize = 0;
        const take = if (out_cap) |cap| @min(cnt, cap - pos) else cnt;
        while (col < take) : (col += 1) {
            const gi: usize = if (keep_specs != null) blk: {
                var idx: usize = 0;
                var found: usize = 0;
                for (selected.items) |it| {
                    if (it.ti == scan_ti) {
                        if (idx == col) break :blk it.gi;
                        idx += 1;
                    }
                    _ = &found;
                }
                break :blk 0;
            } else col;
            const local: usize = @intCast(recs_t[scan_ti][gi * rstride]);
            const grow: u32 = if (rescan) @intCast(local) else rows_t[scan_ti][local];
            g[pos] = .{ .first = grow, .acc_off = pos * specs.len };
            for (specs, 0..) |sp, si2| {
                const ui: usize = @intCast(map[si2]);
                var acc = Acc{};
                if (sp.kind == .sum) {
                    acc.isum = recs_t[scan_ti][gi * rstride + 1 + ui];
                    acc.n = 1;
                } else if (sp.kind == .avg) {
                    acc.isum = recs_t[scan_ti][gi * rstride + 1 + ui];
                    const ci = avg_count orelse blk: {
                        for (specs, 0..) |o, oi| {
                            if (o.kind == .count_all or o.kind == .count) break :blk @as(usize, @intCast(map[oi]));
                        }
                        break :blk ui;
                    };
                    acc.n = recs_t[scan_ti][gi * rstride + 1 + ci];
                } else {
                    acc.n = recs_t[scan_ti][gi * rstride + 1 + ui];
                }
                accs[pos * specs.len + si2] = acc;
            }
            pos += 1;
        }
    }
    {
        var total: i64 = 0;
        for (0..total_groups) |gi| {
            for (specs, 0..) |sp, si| {
                if (sp.kind == .count_all or sp.kind == .count) total += accs[gi * specs.len + si].n;
            }
        }
        if (keep_specs == null and out_cap == null and specs.len > 0 and total != 0 and
            total != @as(i64, @intCast(n))) return null;
    }
    if (std.c.getenv("ZHDB_VERIFY") != null and total_groups > 0 and !has_expr_key) {
        var csi: ?usize = null;
        for (specs, 0..) |sp, si| {
            if (sp.kind == .count_all or sp.kind == .count) {
                csi = si;
                break;
            }
        }
        if (csi) |ci| {
            const rep = g[0].first;
            var tally: i64 = 0;
            var vi: usize = 0;
            while (vi < rows_sel.len()) : (vi += 1) {
                const ri = rows_sel.at(vi);
                var same = true;
                for (group_cols) |gc| {
                    const a = cellValue(t, gc, rep);
                    const b = cellValue(t, gc, ri);
                    if (Value.order(a, b) != .eq) {
                        same = false;
                        break;
                    }
                }
                if (same) tally += 1;
            }
            const want = accs[ci].n;
            std.debug.print("[verify] top group: emitted={d} actual={d} gcols={d}{s}\n", .{ want, tally, group_cols.len, if (tally == want) "" else "  <<< MISMATCH" });
        }
    }
    return .{ .groups = g, .accs = accs };
}
const ShardedGroups = struct {
    groups: []Group,
    accs: []Acc,
    fn deinit(self: *ShardedGroups, alloc: std.mem.Allocator) void {
        alloc.free(self.groups);
        alloc.free(self.accs);
    }
};
fn denseShardedAggregate(
    t: *Table,
    alloc: std.mem.Allocator,
    specs: []const AggSpec,
    ci: u32,
    selection: Sel,
) !ShardedGroups {
    const enc = t.enc[ci].?;
    const ndv = enc.first.len;
    const ids = enc.ids;
    var nthreads = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
    while (nthreads > 2 and @as(u64, nthreads) * ndv * 4 > 512 * 1024 * 1024) nthreads -= 1;
    const n = selection.len();
    var counts = try alloc.alloc(usize, nthreads + 1);
    defer alloc.free(counts);
    @memset(counts, 0);
    for (0..n) |i| counts[(ids[selection.at(i)] & @as(u32, @intCast(nthreads - 1))) + 1] += 1;
    var i: usize = 0;
    while (i < nthreads) : (i += 1) counts[i + 1] += counts[i];
    const order = try alloc.alloc(u32, n);
    defer alloc.free(order);
    var cursor = try alloc.alloc(usize, nthreads);
    defer alloc.free(cursor);
    @memcpy(cursor, counts[0..nthreads]);
    for (0..n) |k| {
        const ri = selection.at(k);
        const b = ids[ri] & @as(u32, @intCast(nthreads - 1));
        order[cursor[b]] = ri;
        cursor[b] += 1;
    }
    var lens: [16]?[]i64 = @splat(null);
    var lens_ci: [16]usize = @splat(0);
    for (specs, 0..) |sp, si| {
        if (si >= lens.len) break;
        if (sp.kind != .sum and sp.kind != .avg) continue;
        if (sp.col >= 0) continue;
        const e = sp.expr orelse continue;
        if (e.* != .call) continue;
        const c = e.call;
        if (c.args.len != 1 or !std.ascii.eqlIgnoreCase(c.name, "length")) continue;
        const lci = colIndex(t, c.args[0]) orelse continue;
        if (lci >= t.data.len or t.data[lci] != .strs) continue;
        const se = t.enc[lci] orelse continue;
        const arr = try alloc.alloc(i64, se.first.len);
        for (se.first, 0..) |row, id| arr[id] = @intCast(t.data[lci].strs.at(row).len);
        lens[si] = arr;
        lens_ci[si] = lci;
    }
    const Worker = struct {
        t: *Table,
        specs: []const AggSpec,
        ids: []const u32,
        rows: []const u32,
        ndv: usize,
        lens: *const [16]?[]i64,
        lens_ci: *const [16]usize,
        alloc: std.mem.Allocator,
        query_alloc: std.mem.Allocator,
        groups: std.ArrayList(Group) = .empty,
        accs: std.ArrayList(Acc) = .empty,
        okay: bool = true,
        fn run(self: *@This()) void {
            const gmap = self.alloc.alloc(i32, self.ndv) catch {
                self.okay = false;
                return;
            };
            @memset(gmap, -1);
            for (self.rows) |ri| {
                const id = self.ids[ri];
                var gi = gmap[id];
                if (gi < 0) {
                    gi = @intCast(self.groups.items.len);
                    gmap[id] = gi;
                    const off = self.accs.items.len;
                    self.accs.resize(self.alloc, off + self.specs.len) catch {
                        self.okay = false;
                        return;
                    };
                    for (self.accs.items[off .. off + self.specs.len]) |*a| a.* = .{};
                    self.groups.append(self.alloc, .{ .first = ri, .acc_off = off }) catch {
                        self.okay = false;
                        return;
                    };
                }
                const off = self.groups.items[@intCast(gi)].acc_off;
                const gaccs = self.accs.items[off .. off + self.specs.len];
                for (self.specs, 0..) |spec, si| {
                    if (si < self.lens.len) {
                        if (self.lens[si]) |arr| {
                            const lci = self.lens_ci[si];
                            const acc = &gaccs[si];
                            acc.isum += arr[self.t.enc[lci].?.ids[ri]] + spec.offset;
                            acc.n += 1;
                            continue;
                        }
                    }
                    accUpdate(&gaccs[si], spec, self.t, ri, self.query_alloc) catch {
                        self.okay = false;
                        return;
                    };
                }
            }
        }
    };
    var workers = try alloc.alloc(Worker, nthreads);
    defer alloc.free(workers);
    var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
    defer alloc.free(arenas);
    var threads = try alloc.alloc(?std.Thread, nthreads);
    defer alloc.free(threads);
    for (0..nthreads) |ti| {
        arenas[ti] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        workers[ti] = .{
            .t = t,
            .specs = specs,
            .ids = ids,
            .rows = order[counts[ti]..counts[ti + 1]],
            .ndv = ndv,
            .lens = &lens,
            .lens_ci = &lens_ci,
            .alloc = arenas[ti].allocator(),
            .query_alloc = alloc,
        };
        threads[ti] = null;
        threads[ti] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, Worker.run, .{&workers[ti]}) catch null;
        if (threads[ti] == null and counts[ti] < counts[ti + 1]) Worker.run(&workers[ti]);
    }
    for (0..nthreads) |ti| if (threads[ti]) |th| th.join();
    var total_groups: usize = 0;
    for (workers) |*w| {
        if (w.okay) total_groups += w.groups.items.len;
    }
    const groups = try alloc.alloc(Group, total_groups);
    const accs = try alloc.alloc(Acc, total_groups * specs.len);
    var gpos: usize = 0;
    for (workers) |*w| {
        if (!w.okay) continue;
        for (w.groups.items) |g| {
            const newoff = gpos * specs.len;
            @memcpy(accs[newoff .. newoff + specs.len], w.accs.items[g.acc_off .. g.acc_off + specs.len]);
            groups[gpos] = .{ .first = g.first, .acc_off = newoff };
            gpos += 1;
        }
    }
    for (0..nthreads) |ti| {
        workers[ti].groups.deinit(arenas[ti].allocator());
        workers[ti].accs.deinit(arenas[ti].allocator());
        arenas[ti].deinit();
    }
    return .{ .groups = groups, .accs = accs };
}
fn shardedAggregate(
    t: *Table,
    alloc: std.mem.Allocator,
    specs: []const AggSpec,
    group_cols: []const u32,
    selection: Sel,
) !ShardedGroups {
    const nthreads = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
    const hashes = try alloc.alloc(u32, selection.len());
    defer alloc.free(hashes);
    const ht = GroupTable.initEmpty(t, alloc, @constCast(group_cols));
    for (0..selection.len()) |i| hashes[i] = @truncate(ht.hashRow(selection.at(i)));
    var counts = try alloc.alloc(usize, nthreads + 1);
    defer alloc.free(counts);
    @memset(counts, 0);
    for (hashes) |h| counts[(@as(usize, h) & (nthreads - 1)) + 1] += 1;
    var i: usize = 0;
    while (i < nthreads) : (i += 1) counts[i + 1] += counts[i];
    const order = try alloc.alloc(u32, selection.len());
    defer alloc.free(order);
    var cursor = try alloc.alloc(usize, nthreads);
    defer alloc.free(cursor);
    @memcpy(cursor, counts[0..nthreads]);
    for (0..selection.len()) |ri_i| {
        const ri = selection.at(ri_i);
        const b = @as(usize, hashes[ri_i]) & (nthreads - 1);
        order[cursor[b]] = ri;
        cursor[b] += 1;
    }
    var cap_hint: usize = 1024;
    {
        const sample = @min(selection.len(), 8192);
        var seen = std.AutoHashMap(u32, void).init(alloc);
        defer seen.deinit();
        var si: usize = 0;
        while (si < sample) : (si += 1) seen.put(hashes[si], {}) catch {
            si = sample;
        };
        if (si == sample and seen.count() < sample) {
            cap_hint = @max(64, seen.count() * 4 + 64);
        }
    }
    const Worker = struct {
        t: *Table,
        specs: []const AggSpec,
        group_cols: []const u32,
        rows: []const u32,
        cap_hint: usize,
        alloc: std.mem.Allocator,
        query_alloc: std.mem.Allocator,
        table: ?GroupTable = null,
        err: bool = false,
        fn run(self: *@This()) void {
            var gt = GroupTable.init(self.t, self.alloc, @constCast(self.group_cols), self.cap_hint) catch {
                self.err = true;
                return;
            };
            for (self.rows) |ri| {
                const h = gt.hashRow(ri);
                const gidx = gt.findOrPutHashed(ri, h, self.specs) catch {
                    self.err = true;
                    return;
                };
                const off = gt.groups.items[gidx].acc_off;
                const gaccs = gt.accs.items[off .. off + self.specs.len];
                for (self.specs, 0..) |spec, si| accUpdate(&gaccs[si], spec, self.t, ri, self.query_alloc) catch {
                    self.err = true;
                    return;
                };
            }
            self.table = gt;
        }
    };
    var workers = try alloc.alloc(Worker, nthreads);
    defer alloc.free(workers);
    var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
    defer alloc.free(arenas);
    var threads = try alloc.alloc(?std.Thread, nthreads);
    defer alloc.free(threads);
    for (0..nthreads) |ti| {
        arenas[ti] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        workers[ti] = .{
            .t = t,
            .specs = specs,
            .group_cols = group_cols,
            .rows = order[counts[ti]..counts[ti + 1]],
            .cap_hint = @min(counts[ti + 1] - counts[ti] + 1, cap_hint),
            .alloc = arenas[ti].allocator(),
            .query_alloc = alloc,
        };
        threads[ti] = null;
        threads[ti] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, Worker.run, .{&workers[ti]}) catch null;
        if (threads[ti] == null and counts[ti] < counts[ti + 1]) Worker.run(&workers[ti]);
    }
    for (0..nthreads) |ti| if (threads[ti]) |th| th.join();
    var total_groups: usize = 0;
    for (workers) |*w| {
        if (w.err or w.table == null) continue;
        total_groups += w.table.?.groups.items.len;
    }
    const groups = try alloc.alloc(Group, total_groups);
    const accs = try alloc.alloc(Acc, total_groups * specs.len);
    var gpos: usize = 0;
    for (workers) |*w| {
        if (w.err or w.table == null) continue;
        var gt = &w.table.?;
        for (gt.groups.items, 0..) |g, gi| {
            const gaccs = gt.accs.items[g.acc_off .. g.acc_off + specs.len];
            const newoff = gpos * specs.len;
            @memcpy(accs[newoff .. newoff + specs.len], gaccs);
            groups[gpos] = .{ .first = g.first, .acc_off = newoff };
            gpos += 1;
            _ = gi;
        }
    }
    for (0..nthreads) |ti| {
        if (workers[ti].table) |*gt| gt.deinit();
        arenas[ti].deinit();
    }
    return .{ .groups = groups, .accs = accs };
}
fn hostOfUrl(s: []const u8) ?[]const u8 {
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, s, "https://")) {
        rest = s["https://".len..];
    } else if (std.mem.startsWith(u8, s, "http://")) {
        rest = s["http://".len..];
    } else return null;
    if (std.mem.startsWith(u8, rest, "www.")) rest = rest[4..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0) return null;
    return rest[0..slash];
}
fn strExprSlice(t: *const Table, e: *sql.Expr, ri: usize) ?[]const u8 {
    switch (e.*) {
        .string => |v| return v,
        .column => |name| {
            const ci = t.find(name) orelse return null;
            if (t.data[ci] != .strs) return null;
            return t.data[ci].strs.at(ri);
        },
        .column_idx => |c| {
            if (t.data[c.idx] != .strs) return null;
            return t.data[c.idx].strs.at(ri);
        },
        .case_expr => |ce| {
            for (ce.whens) |w| {
                const cv = evalScalar(t, w.cond, ri);
                const truth = switch (cv) {
                    .null => false,
                    .int => |x| x != 0,
                    .float => |x| x != 0,
                    .str => |x| x.len != 0,
                    .boolean => |b| b,
                };
                if (truth) return strExprSlice(t, w.then, ri);
            }
            if (ce.else_expr) |el| return strExprSlice(t, el, ri);
            return null;
        },
        .call => |c| {
            if (std.ascii.eqlIgnoreCase(c.name, "regexp_replace") and c.args.len == 3 and
                c.args[1].* == .string and c.args[2].* == .string and
                std.mem.eql(u8, c.args[1].string, "^https?://(?:www\\.)?([^/]+)/.*$") and
                std.mem.eql(u8, c.args[2].string, "\\1"))
            {
                const v = evalScalar(t, c.args[0], ri);
                if (v == .str) return hostOfUrl(v.str) orelse v.str;
                return "";
            }
            return null;
        },
        else => return null,
    }
}
fn strExprOk(t: *const Table, e: *sql.Expr) bool {
    switch (e.*) {
        .string => return true,
        .column => |name| {
            const ci = t.find(name) orelse return false;
            return t.data[ci] == .strs;
        },
        .column_idx => |c| return t.data[c.idx] == .strs,
        .case_expr => |ce| {
            if (ce.else_expr == null) return false;
            for (ce.whens) |w| {
                if (!supportedExpr(w.cond) or !strExprOk(t, w.then)) return false;
            }
            return strExprOk(t, ce.else_expr.?);
        },
        .call => return hostExprCol(t, e) != null,
        else => return false,
    }
}
fn hostExprCol(t: *const Table, e: *sql.Expr) ?usize {
    if (e.* != .call) return null;
    const c = e.call;
    if (!std.ascii.eqlIgnoreCase(c.name, "regexp_replace") or c.args.len != 3) return null;
    if (c.args[1].* != .string or c.args[2].* != .string) return null;
    if (!std.mem.eql(u8, c.args[1].string, "^https?://(?:www\\.)?([^/]+)/.*$")) return null;
    if (!std.mem.eql(u8, c.args[2].string, "\\1")) return null;
    const ci: usize = switch (c.args[0].*) {
        .column_idx => |x| x.idx,
        .column => |name| t.find(name) orelse return null,
        else => return null,
    };
    if (t.data[ci] != .strs) return null;
    return ci;
}
fn buildStrEncodingSel(t: *Table, alloc: std.mem.Allocator, ci: usize, keep: ?[]const u64, selection: Sel) !void {
    const n = t.nrows;
    const strs = t.data[ci].strs;
    const ids = try alloc.alloc(u32, n);
    @memset(ids, 0);
    var first = std.ArrayList(u32).empty;
    var map = std.StringHashMap(u32).init(t.heap);
    defer map.deinit();
    if (keep != null and selection.list != null) {
        for (selection.list.?) |ri| {
            const gop = try map.getOrPut(strs.at(ri));
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(first.items.len);
                try first.append(alloc, @intCast(ri));
            }
            ids[ri] = @intCast(gop.value_ptr.*);
        }
    } else for (0..n) |ri| {
        const gop = try map.getOrPut(strs.at(ri));
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(first.items.len);
            try first.append(alloc, @intCast(ri));
        }
        ids[ri] = @intCast(gop.value_ptr.*);
    }
    const counts = try alloc.alloc(u32, first.items.len);
    @memset(counts, 0);
    if (keep != null and selection.list != null) {
        for (selection.list.?) |ri| counts[ids[ri]] += 1;
    } else for (0..n) |ri| {
        counts[ids[ri]] += 1;
    }
    if (first.items.len <= 100_000 and first.items.len > 1) {
        const rank = try alloc.alloc(u32, first.items.len);
        const ord = try alloc.alloc(u32, first.items.len);
        for (ord, 0..) |*o, i| o.* = @intCast(i);
        const Ctx = struct {
            strs: StrData,
            first: []const u32,
            fn less(ctx: @This(), x: u32, y: u32) bool {
                return std.mem.order(u8, ctx.strs.at(ctx.first[x]), ctx.strs.at(ctx.first[y])) == .lt;
            }
        };
        std.mem.sort(u32, ord, Ctx{ .strs = strs, .first = first.items }, Ctx.less);
        for (ord, 0..) |id, pos| rank[id] = @intCast(pos);
        t.enc[ci] = .{ .ids = ids, .first = first.items, .rank = rank, .byrank = ord, .counts = counts };
    } else {
        t.enc[ci] = .{ .ids = ids, .first = first.items, .counts = counts };
    }
}
const CaseColLit = struct { col: usize, lit: []const u8, cond: *sql.Expr };
fn caseColLit(t: *const Table, e: *sql.Expr) ?CaseColLit {
    if (e.* != .case_expr) return null;
    const ce = e.case_expr;
    if (ce.whens.len != 1 or ce.else_expr == null) return null;
    const w = ce.whens[0];
    const col: usize = switch (w.then.*) {
        .column => |name| t.find(name) orelse return null,
        .column_idx => |c| c.idx,
        else => return null,
    };
    if (col >= t.data.len or t.data[col] != .strs) return null;
    const lit: []const u8 = switch (ce.else_expr.?.*) {
        .string => |x| x,
        else => return null,
    };
    return .{ .col = col, .lit = lit, .cond = w.cond };
}
fn rankStrDict(t: *Table, alloc: std.mem.Allocator, ci: usize) !void {
    if (ci >= t.enc.len) return;
    const e: *Encoding = if (t.enc[ci]) |*p| p else return;
    const ndv = e.first.len;
    if (ndv <= 1 or ndv > 100_000) return;
    const strs = t.data[ci].strs;
    const rank = try alloc.alloc(u32, ndv);
    const ord = try alloc.alloc(u32, ndv);
    for (ord, 0..) |*o, i| o.* = @intCast(i);
    const Ctx = struct {
        strs: StrData,
        first: []const u32,
        fn less(ctx: @This(), x: u32, y: u32) bool {
            return std.mem.order(u8, ctx.strs.at(ctx.first[x]), ctx.strs.at(ctx.first[y])) == .lt;
        }
    };
    std.mem.sort(u32, ord, Ctx{ .strs = strs, .first = e.first }, Ctx.less);
    for (ord, 0..) |id, pos| rank[id] = @intCast(pos);
    e.rank = rank;
    e.byrank = ord;
}
fn materializeStrColumn(t: *Table, alloc: std.mem.Allocator, expr: *sql.Expr, selection: Sel) !?*Table {
    const n = t.nrows;
    const ncols = t.cols.len;
    const t2 = try alloc.create(Table);
    t2.* = t.*;
    const cols = try alloc.alloc(Column, ncols + 1);
    @memcpy(cols[0..ncols], t.cols);
    cols[ncols] = .{ .name = "__host", .kind = .str };
    const data = try alloc.alloc(Data, ncols + 1);
    @memcpy(data[0..ncols], t.data);
    const enc = try alloc.alloc(?Encoding, ncols + 1);
    @memcpy(enc[0..ncols], t.enc);
    enc[ncols] = null;
    const valid = try alloc.alloc(?[]u8, ncols + 1);
    @memcpy(valid[0..ncols], t.valid);
    valid[ncols] = null;
    const keyidx = try alloc.alloc(?*KeyIndex, ncols + 1);
    @memset(keyidx, null);
    const stats = try alloc.alloc(?[]BlockStat, ncols + 1);
    @memset(stats, null);
    var keep: ?[]u64 = null;
    if (selection.list) |list| {
        if (list.len < n) {
            const bits = try alloc.alloc(u64, (n + 63) / 64);
            @memset(bits, 0);
            for (list) |r| bits[r >> 6] |= @as(u64, 1) << @intCast(r & 63);
            keep = bits;
        }
    }
    const offs = try alloc.alloc(u32, n + 1);
    @memset(offs, 0);
    var bytes = std.ArrayList(u8).empty;
    try bytes.ensureTotalCapacity(alloc, n * 16 + 1024);
    var blen: u32 = 0;
    if (caseColLit(t, expr)) |shape| {
        if (t.enc[shape.col]) |be| {
            const sd = t.data[shape.col].strs;
            const map_ids = try alloc.alloc(i32, be.first.len);
            @memset(map_ids, -1);
            var hoffs = std.ArrayList(u32).empty;
            try hoffs.append(alloc, 0);
            var hbytes = std.ArrayList(u8).empty;
            try hbytes.appendSlice(alloc, shape.lit);
            try hoffs.append(alloc, @intCast(hbytes.items.len));
            var hfirst = std.ArrayList(u32).empty;
            try hfirst.append(alloc, std.math.maxInt(u32));
            const ids = try alloc.alloc(u32, n);
            @memset(ids, 0);
            const nsel = selection.len();
            var si: usize = 0;
            while (si < nsel) : (si += 1) {
                const ri = selection.at(si);
                const cv = evalScalar(t, shape.cond, ri);
                const truth = switch (cv) {
                    .null => false,
                    .int => |x| x != 0,
                    .float => |x| x != 0,
                    .str => |x| x.len != 0,
                    .boolean => |b| b,
                };
                if (!truth) {
                    if (hfirst.items[0] == std.math.maxInt(u32)) hfirst.items[0] = @intCast(ri);
                    continue;
                }
                const bid = be.ids[ri];
                var mid = map_ids[bid];
                if (mid < 0) {
                    if (std.mem.eql(u8, sd.at(be.first[bid]), shape.lit)) {
                        mid = 0;
                        if (hfirst.items[0] == std.math.maxInt(u32)) hfirst.items[0] = @intCast(ri);
                    } else {
                        mid = @intCast(hfirst.items.len);
                        try hbytes.appendSlice(alloc, sd.at(be.first[bid]));
                        try hoffs.append(alloc, @intCast(hbytes.items.len));
                        try hfirst.append(alloc, @intCast(ri));
                    }
                    map_ids[bid] = mid;
                }
                ids[ri] = @intCast(mid);
            }
            const nh = hfirst.items.len;
            const counts = try alloc.alloc(u32, nh);
            @memset(counts, 0);
            if (selection.list) |list| {
                for (list) |ri| {
                    counts[ids[ri]] += 1;
                }
            } else {
                for (ids) |id| {
                    counts[id] += 1;
                }
            }
            for (hfirst.items) |*f| {
                if (f.* == std.math.maxInt(u32)) f.* = 0;
            }
            data[ncols] = .{ .strs = .{ .offsets = hoffs.items, .bytes = hbytes.items } };
            enc[ncols] = .{ .ids = ids, .first = hfirst.items, .counts = counts };
            t2.cols = cols;
            t2.data = data;
            t2.enc = enc;
            t2.valid = valid;
            t2.keyidx = keyidx;
            t2.stats = stats;
            try rankStrDict(t2, alloc, ncols);
            prof("materialize-dict");
            return t2;
        }
    }
    const host_src = hostExprCol(t, expr);
    if (host_src) |src| {
        if (t.enc[src]) |be| {
            const sd = t.data[src].strs;
            var map = std.StringHashMap(u32).init(t.heap);
            defer map.deinit();
            const host_of_src = try alloc.alloc(u32, be.first.len);
            var hoffs = std.ArrayList(u32).empty;
            try hoffs.append(alloc, 0);
            var hbytes = std.ArrayList(u8).empty;
            try hbytes.ensureTotalCapacity(alloc, be.first.len * 16 + 1024);
            for (be.first, 0..) |row, k| {
                const u = sd.at(row);
                const hs = hostOfUrl(u) orelse u;
                const gop = try map.getOrPut(hs);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(hoffs.items.len - 1);
                    try hbytes.appendSlice(alloc, hs);
                    try hoffs.append(alloc, @intCast(hbytes.items.len));
                }
                host_of_src[k] = gop.value_ptr.*;
            }
            const nh = hoffs.items.len - 1;
            const ids = try alloc.alloc(u32, n);
            const bidi = be.ids;
            for (0..n) |ri| ids[ri] = host_of_src[bidi[ri]];
            const counts = try alloc.alloc(u32, nh);
            @memset(counts, 0);
            const firsts = try alloc.alloc(u32, nh);
            @memset(firsts, std.math.maxInt(u32));
            const nsel = selection.len();
            var si: usize = 0;
            while (si < nsel) : (si += 1) {
                const ri = selection.at(si);
                const id = ids[ri];
                if (firsts[id] == std.math.maxInt(u32)) firsts[id] = @intCast(ri);
                counts[id] += 1;
            }
            for (firsts) |*f| {
                if (f.* == std.math.maxInt(u32)) f.* = 0;
            }
            data[ncols] = .{ .strs = .{ .offsets = hoffs.items, .bytes = hbytes.items } };
            enc[ncols] = .{ .ids = ids, .first = firsts, .counts = counts };
            t2.cols = cols;
            t2.data = data;
            t2.enc = enc;
            t2.valid = valid;
            t2.keyidx = keyidx;
            t2.stats = stats;
            try rankStrDict(t2, alloc, ncols);
            prof("materialize-dict");
            return t2;
        }
    }
    if (keep != null and selection.list != null) {
        const list = selection.list.?;
        var asc = true;
        var k: usize = 1;
        while (k < list.len) : (k += 1) {
            if (list[k] < list[k - 1]) {
                asc = false;
                break;
            }
        }
        if (!asc) std.mem.sort(u32, @constCast(list), {}, std.sort.asc(u32));
        for (list) |ri| {
            offs[ri] = blen;
            const piece: []const u8 = if (host_src) |h| blk: {
                const u = t.data[h].strs.at(ri);
                break :blk hostOfUrl(u) orelse u;
            } else strExprSlice(t, expr, ri) orelse "";
            try bytes.appendSlice(alloc, piece);
            blen = @intCast(bytes.items.len);
            offs[ri + 1] = blen;
        }
        offs[n] = blen;
    } else if (host_src != null) {
        const sd = t.data[host_src.?].strs;
        for (0..n) |ri| {
            offs[ri] = blen;
            const u = sd.at(ri);
            try bytes.appendSlice(alloc, hostOfUrl(u) orelse u);
            blen = @intCast(bytes.items.len);
        }
        offs[n] = blen;
    } else {
        for (0..n) |ri| {
            offs[ri] = blen;
            const res = strExprSlice(t, expr, ri) orelse "";
            try bytes.appendSlice(alloc, res);
            blen = @intCast(bytes.items.len);
        }
        offs[n] = blen;
    }
    data[ncols] = .{ .strs = .{ .offsets = offs, .bytes = bytes.items } };
    t2.cols = cols;
    t2.data = data;
    t2.enc = enc;
    t2.valid = valid;
    t2.keyidx = keyidx;
    t2.stats = stats;
    prof("materialize-bytes");
    try buildStrEncodingSel(t2, alloc, ncols, keep, selection);
    prof("materialize-dict");
    return t2;
}
fn materializeIntKeyColumn(t: *Table, alloc: std.mem.Allocator, expr: *sql.Expr, selection: Sel) !?*Table {
    const arr = (try exprEpochKey(t, alloc, expr, selection)) orelse return null;
    const ncols = t.cols.len;
    const t2 = try alloc.create(Table);
    t2.* = t.*;
    const cols = try alloc.alloc(Column, ncols + 1);
    @memcpy(cols[0..ncols], t.cols);
    cols[ncols] = .{ .name = "__ekey", .kind = .int };
    const data = try alloc.alloc(Data, ncols + 1);
    @memcpy(data[0..ncols], t.data);
    data[ncols] = .{ .ints = arr };
    const enc = try alloc.alloc(?Encoding, ncols + 1);
    @memcpy(enc[0..ncols], t.enc);
    enc[ncols] = null;
    const valid = try alloc.alloc(?[]u8, ncols + 1);
    @memcpy(valid[0..ncols], t.valid);
    valid[ncols] = null;
    const keyidx = try alloc.alloc(?*KeyIndex, ncols + 1);
    @memset(keyidx, null);
    const stats = try alloc.alloc(?[]BlockStat, ncols + 1);
    @memset(stats, null);
    t2.cols = cols;
    t2.data = data;
    t2.enc = enc;
    t2.valid = valid;
    t2.keyidx = keyidx;
    t2.stats = stats;
    return t2;
}
fn aggregate(t: *Table, alloc: std.mem.Allocator, sel: *sql.Select, specs: []const AggSpec, selection: Sel, full_scan: bool, s: *Scratch) !?QueryResult {
    s.reset();
    profReset();
    if (sel.group_by.len > 0) {
        var replaced = false;
        var cur: *Table = t;
        const gb = try alloc.alloc(*sql.Expr, sel.group_by.len);
        const items = try alloc.alloc(sql.SelectItem, sel.items.len);
        @memcpy(items, sel.items);
        for (sel.group_by, 0..) |g, gi| {
            gb[gi] = g;
            if (colIndex(cur, g) != null) continue;
            if (!strExprOk(cur, g)) {
                const gb_expr = try sql.cloneExpr(alloc, g);
                bindExprIdx(cur, gb_expr);
                if (try materializeIntKeyColumn(cur, alloc, gb_expr, selection)) |t3| {
                    const nc3 = t3.cols.len - 1;
                    const kexpr = try alloc.create(sql.Expr);
                    kexpr.* = .{ .column_idx = .{ .idx = @intCast(nc3), .name = t3.cols[nc3].name } };
                    gb[gi] = kexpr;
                    cur = t3;
                    replaced = true;
                    prof("materialize-int-key");
                }
                continue;
            }
            const is_host = hostExprCol(cur, g) != null;
            if (!is_host and g.* != .case_expr) continue;
            const gb_expr = try sql.cloneExpr(alloc, g);
            bindExprIdx(cur, gb_expr);
            const t2 = (try materializeStrColumn(cur, alloc, gb_expr, selection)) orelse continue;
            const nc = t2.cols.len - 1;
            const gexpr = try alloc.create(sql.Expr);
            gexpr.* = .{ .column_idx = .{ .idx = @intCast(nc), .name = t2.cols[nc].name } };
            gb[gi] = gexpr;
            for (items) |*it| {
                if (it.expr == g) it.expr = gexpr;
            }
            cur = t2;
            replaced = true;
            prof("materialize-agg-key");
        }
        if (replaced) {
            const sel2 = sel.*;
            var sel2m = sel2;
            sel2m.group_by = gb;
            sel2m.items = items;
            return try aggregate(cur, alloc, &sel2m, specs, selection, full_scan, s);
        }
    }
    var group_cols = std.ArrayList(u32).empty;
    defer group_cols.deinit(alloc);
    var group_keys = std.ArrayList(KeySrc).empty;
    defer group_keys.deinit(alloc);
    var used_bases: [8]?usize = @splat(null);
    var nused: usize = 0;
    for (sel.group_by) |g| {
        switch (g.*) {
            .int, .float, .string, .null_lit => continue,
            else => {},
        }
        if (baseKeyColumn(t, g)) |bc| {
            var seen = false;
            for (used_bases[0..nused]) |u| {
                if (u != null and u.? == bc) seen = true;
            }
            if (seen) continue;
            if (nused < used_bases.len) {
                used_bases[nused] = bc;
                nused += 1;
            }
        }
        if (colIndex(t, g)) |ci| {
            try group_cols.append(alloc, @intCast(ci));
            const gids = t.groupKeyIds(ci);
            const graw: ?[*]const i64 = t.groupKeyPtr(ci);
            try group_keys.append(alloc, .{
                .ids = gids,
                .raw = graw,
                .narrow = if (gids == null and graw == null and t.data[ci].isInt()) t.data[ci] else null,
            });
        } else {
            const arr = (try exprEpochKey(t, alloc, g, null)) orelse return null;
            try group_cols.append(alloc, no_col);
            try group_keys.append(alloc, .{ .ids = null, .raw = arr.ptr });
        }
    }
    var has_expr_key = false;
    for (group_cols.items) |gc| {
        if (gc == no_col) has_expr_key = true;
    }
    prof("agg:pre");
    if (group_cols.items.len == 0 and sel.having == null and specs.len > 0) {
        var all_counts = true;
        for (specs) |sp| {
            if (sp.kind != .count_all and sp.kind != .count) all_counts = false;
        }
        if (all_counts) {
            const vals = try alloc.alloc(Value, specs.len);
            for (vals) |*v| v.* = .{ .int = @intCast(selection.len()) };
            return try emitScalar(t, alloc, sel, specs, vals);
        }
    }
    prof("agg:pre");
    if (group_cols.items.len == 0 and specs.len > 0 and selection.len() >= 16_384 and sel.having == null) {
        var ok = true;
        for (specs) |sp| {
            if (sp.kind != .min and sp.kind != .max) {
                ok = false;
                break;
            }
            if (sp.col < 0 or t.data[@intCast(sp.col)] != .ints) {
                ok = false;
                break;
            }
        }
        if (ok) {
            const W = 8;
            const chunk = (selection.len() + W - 1) / W;
            var lo = [_]i64{ std.math.maxInt(i64), std.math.maxInt(i64), std.math.maxInt(i64), std.math.maxInt(i64), std.math.maxInt(i64), std.math.maxInt(i64), std.math.maxInt(i64), std.math.maxInt(i64) };
            var hi = [_]i64{ std.math.minInt(i64), std.math.minInt(i64), std.math.minInt(i64), std.math.minInt(i64), std.math.minInt(i64), std.math.minInt(i64), std.math.minInt(i64), std.math.minInt(i64) };
            const R = struct {
                t: *Table,
                specs: []const AggSpec,
                sel: Sel,
                start: usize,
                end: usize,
                lo: []i64,
                hi: []i64,
                fn run(self: *@This()) void {
                    for (self.specs, 0..) |sp, si| {
                        const a: []const i64 = self.t.data[@intCast(sp.col)].ints;
                        var mn: i64 = std.math.maxInt(i64);
                        var mx: i64 = std.math.minInt(i64);
                        var i = self.start;
                        while (i < self.end) : (i += 1) {
                            const v = a[self.sel.at(i)];
                            mn = @min(mn, v);
                            mx = @max(mx, v);
                        }
                        if (sp.kind == .min) self.lo[si] = @min(self.lo[si], mn) else self.hi[si] = @max(self.hi[si], mx);
                    }
                }
            };
            var workers: [W]R = undefined;
            var threads: [W]?std.Thread = undefined;
            const ts = 8;
            for (0..ts) |ti| {
                const s0 = ti * chunk;
                const e0 = @min(s0 + chunk, selection.len());
                workers[ti] = .{ .t = t, .specs = specs, .sel = selection, .start = s0, .end = e0, .lo = lo[0..], .hi = hi[0..] };
                threads[ti] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, R.run, .{&workers[ti]}) catch null;
                if (threads[ti] == null) workers[ti].run();
            }
            for (0..ts) |ti| if (threads[ti]) |th| th.join();
            const vals = try alloc.alloc(Value, specs.len);
            for (specs, 0..) |sp, si| {
                vals[si] = .{ .int = if (sp.kind == .min) lo[si] else hi[si] };
            }
            return try emitScalar(t, alloc, sel, specs, vals);
        }
    }
    if (group_cols.items.len == 0 and specs.len == 1 and specs[0].kind == .count_distinct and
        specs[0].col >= 0 and selection.len() >= 100_000)
    {
        const ci: usize = @intCast(specs[0].col);
        const cnt: ?i64 = switch (t.data[ci]) {
            .ints => if (t.enc[ci]) |e|
                try countDistinctDense(alloc, e.ids, selection, e.first.len)
            else
                try countDistinctI64(t, alloc, ci, selection, s),
            .strs => if (t.enc[ci]) |e|
                try countDistinctDense(alloc, e.ids, selection, e.first.len)
            else
                try countDistinctStr(t, alloc, ci, selection),
            else => null,
        };
        prof("agg:scalar-distinct");
        if (cnt) |c| {
            const vals = try alloc.alloc(Value, 1);
            vals[0] = .{ .int = c };
            const r = try emitScalar(t, alloc, sel, specs, vals);
            prof("agg:emit");
            return r;
        }
    }
    if (group_cols.items.len == 0 and selection.len() >= 100_000) {
        var parallel_ok = true;
        for (specs) |sp| if (sp.kind == .count_distinct) {
            parallel_ok = false;
        };
        if (parallel_ok) {
            var pre: ?[]?i64 = null;
            defer if (pre) |p| alloc.free(p);
            if (full_scan and jit.supported and std.c.getenv("ZHDB_NO_JIT") == null) {
                pre = try jitPrecompute(t, alloc, specs);
            }
            const vals = try scalarAggParallel(t, alloc, specs, selection, pre);
            return try emitScalar(t, alloc, sel, specs, vals);
        }
    }
    var sharded: ?ShardedGroups = null;
    defer if (sharded) |*sh| sh.deinit(alloc);
    if (std.c.getenv("ZHDB_PROF") != null) {
        std.debug.print("  [prof] jit gate: full_scan={} list={} sel_n={d} gcols={d} supported={} sharded={}\n", .{ full_scan, selection.list != null, selection.len(), group_cols.items.len, jit.supported, sharded != null });
    }
    if (sharded == null and group_cols.items.len >= 1 and sel.order_by.len == 0 and
        sel.having == null and sel.limit != null and selection.len() >= 65_536)
    {
        const k0 = exprUsize(t, sel.limit.?) + (if (sel.offset) |o| exprUsize(t, o) else 0);
        if (try earlyPickGroups(alloc, group_keys.items, specs, selection, k0)) |sg| {
            sharded = sg;
        }
    }
    if (sharded == null and group_cols.items.len == 1 and group_cols.items[0] != no_col and selection.len() >= 16_384) {
        if (try denseGroupAgg(t, alloc, group_cols.items[0], specs, selection, s)) |sg| {
            sharded = sg;
        }
    }
    var has_distinct_spec = false;
    for (specs) |sp| {
        if (sp.kind == .count_distinct) has_distinct_spec = true;
    }
    if (sharded == null and !has_distinct_spec and group_cols.items.len == 1 and
        group_cols.items[0] < t.enc.len and t.enc[group_cols.items[0]] != null and
        t.enc[group_cols.items[0]].?.first.len > 0 and selection.len() >= 200_000)
    {
        sharded = try denseShardedAggregate(t, alloc, specs, group_cols.items[0], selection);
    }
    if (sharded == null and group_cols.items.len >= 1 and group_cols.items.len <= 2 and
        !has_expr_key and
        selection.len() >= 65_536 and specs.len > 0 and
        std.c.getenv("ZHDB_NO_SORTD") == null)
    {
        if (try sortedGroupedDistinct(t, alloc, group_cols.items, specs, selection, s)) |sg| {
            sharded = sg;
        }
    }
    if (sharded == null and group_cols.items.len >= 1 and group_cols.items.len <= 2 and
        !has_expr_key and
        selection.len() >= 16_384 and specs.len > 0)
    {
        if (try groupedDistinctAgg(t, alloc, group_cols.items, specs, selection, s)) |sg| {
            sharded = sg;
        }
    }
    if (sharded == null and (full_scan or selection.list != null) and group_cols.items.len >= 1 and group_cols.items.len <= 3 and
        selection.len() >= 16_384 and jit.supported and std.c.getenv("ZHDB_NO_JIT") == null)
    {
        const maybe = try jitGroupAgg(t, alloc, group_keys.items, group_cols.items, specs, selection, sel, s);
        if (maybe) |sg| {
            sharded = sg;
        } else if (std.c.getenv("ZHDB_PROF") != null) {
            std.debug.print("  [prof] jitGroupAgg DECLINED (gcols={d} specs={d})\n", .{ group_cols.items.len, specs.len });
        }
    }
    if (sharded == null and group_cols.items.len > 0 and !has_expr_key and selection.len() >= 200_000) {
        sharded = try shardedAggregate(t, alloc, specs, group_cols.items, selection);
    }
    var gt = if (sharded == null)
        try GroupTable.init(t, alloc, group_cols.items, selection.len() + 1)
    else
        GroupTable.initEmpty(t, alloc, group_cols.items);
    defer gt.deinit();
    var groups_slice: []Group = if (sharded) |sh| sh.groups else gt.groups.items;
    var accs_slice: []Acc = if (sharded) |sh| sh.accs else gt.accs.items;
    const accsFor = struct {
        fn get(groups: []Group, accs: []Acc, nspecs: usize, gi: usize) []Acc {
            const off = groups[gi].acc_off;
            return accs[off .. off + nspecs];
        }
    }.get;
    if (sharded == null and group_cols.items.len == 1 and
        group_cols.items[0] < t.enc.len and t.enc[group_cols.items[0]] != null and
        t.enc[group_cols.items[0]].?.first.len > 0)
    {
        const ci = group_cols.items[0];
        const enc = t.enc[ci].?;
        const ndv = enc.first.len;
        const gmap = try alloc.alloc(i32, ndv);
        defer alloc.free(gmap);
        @memset(gmap, -1);
        gt.nspecs = specs.len;
        const nsel = selection.len();
        var ri_i: usize = 0;
        while (ri_i < nsel) : (ri_i += 1) {
            const ri = selection.at(ri_i);
            const id = enc.ids[ri];
            var gi = gmap[id];
            if (gi < 0) {
                gi = @intCast(gt.groups.items.len);
                gmap[id] = gi;
                const off = gt.accs.items.len;
                try gt.accs.resize(alloc, off + specs.len);
                for (gt.accs.items[off .. off + specs.len]) |*a| a.* = .{};
                try gt.groups.append(alloc, .{ .first = ri, .acc_off = off });
            }
            const gaccs = accsFor(gt.groups.items, gt.accs.items, specs.len, @intCast(gi));
            for (specs, 0..) |spec, si| try accUpdate(&gaccs[si], spec, t, ri, alloc);
        }
    } else if (sharded == null) {
        var ri_i: usize = 0;
        while (ri_i < selection.len()) : (ri_i += 1) {
            const ri = selection.at(ri_i);
        const gidx = try gt.findOrPut(ri, specs);
        const gaccs = accsFor(gt.groups.items, gt.accs.items, specs.len, gidx);
        for (specs, 0..) |spec, si| try accUpdate(&gaccs[si], spec, t, ri, alloc);
        }
    }
    if (sharded == null) {
        groups_slice = gt.groups.items;
        accs_slice = gt.accs.items;
    }
    if (groups_slice.len == 0 and group_cols.items.len == 0) {
        const off = gt.accs.items.len;
        try gt.accs.resize(alloc, off + specs.len);
        for (gt.accs.items[off .. off + specs.len]) |*a| a.* = .{};
        try gt.groups.append(alloc, .{ .first = 0, .acc_off = off });
        groups_slice = gt.groups.items;
        accs_slice = gt.accs.items;
    }
    const Out = struct { g: u32, vals: []Value };
    var out_groups = std.ArrayList(Out).empty;
    defer out_groups.deinit(alloc);
    var picked: ?[]u32 = null;
    defer if (picked) |pl| alloc.free(pl);
    if (sel.having == null and sel.offset != null) {
        if (exprUsize(t, sel.offset.?) >= groups_slice.len) picked = try alloc.alloc(u32, 0);
    }
    if (picked == null and sel.having == null and sel.order_by.len == 1 and sel.limit != null and
        groups_slice.len > 0 and std.c.getenv("ZHDB_NO_PICK") == null)
    {
        const item = sel.order_by[0];
        var order_expr = item.expr;
        if (order_expr.* == .column) {
            const name = order_expr.column;
            for (sel.items) |it| {
                if (it.alias) |al| {
                    if (std.ascii.eqlIgnoreCase(al, name)) {
                        order_expr = it.expr;
                        break;
                    }
                }
            }
        }
        if (findSpecIndex(specs, t, order_expr)) |si| {
            const off = if (sel.offset) |o| exprUsize(t, o) else 0;
            const k = exprUsize(t, sel.limit.?) + off;
            if (k < groups_slice.len and k <= 65_536 and k > 0) {
                const Keyed = struct { key: f64, gi: u32 };
                const Cmp = struct {
                    desc: bool,
                    fn worse(self: @This(), x: f64, y: f64) bool {
                        return if (self.desc) x < y else x > y;
                    }
                };
                const cmp = Cmp{ .desc = item.desc };
                const heap = try alloc.alloc(Keyed, k);
                defer alloc.free(heap);
                var hlen: usize = 0;
                var ok = true;
                for (0..groups_slice.len) |gi| {
                    const gaccs = accsFor(groups_slice, accs_slice, specs.len, gi);
                    const key: f64 = switch (finalize(&gaccs[si], specs[si])) {
                        .int => |x| @floatFromInt(x),
                        .float => |x| x,
                        else => blk: {
                            ok = false;
                            break :blk 0;
                        },
                    };
                    if (!ok) break;
                    const item_k = Keyed{ .key = key, .gi = @intCast(gi) };
                    if (hlen < k) {
                        var i = hlen;
                        hlen += 1;
                        while (i > 0) {
                            const parent = (i - 1) / 2;
                            if (!cmp.worse(item_k.key, heap[parent].key)) break;
                            heap[i] = heap[parent];
                            i = parent;
                        }
                        heap[i] = item_k;
                    } else if (cmp.worse(heap[0].key, item_k.key)) {
                        var i: usize = 0;
                        while (true) {
                            const l = 2 * i + 1;
                            if (l >= hlen) break;
                            const r = l + 1;
                            var c = l;
                            if (r < hlen and cmp.worse(heap[r].key, heap[l].key)) c = r;
                            if (!cmp.worse(heap[c].key, item_k.key)) break;
                            heap[i] = heap[c];
                            i = c;
                        }
                        heap[i] = item_k;
                    }
                }
                if (ok) {
                    const pl = try alloc.alloc(u32, hlen);
                    for (heap[0..hlen], 0..) |it, idx| pl[idx] = it.gi;
                    picked = pl;
                }
            }
        }
    }
    {
        const total = if (picked) |pl| pl.len else groups_slice.len;
        var sel_i: usize = 0;
        while (sel_i < total) : (sel_i += 1) {
            const gi: usize = if (picked) |pl| pl[sel_i] else sel_i;
            const g = &groups_slice[gi];
            const vals = try alloc.alloc(Value, specs.len);
            const gaccs = accsFor(groups_slice, accs_slice, specs.len, gi);
            for (specs, 0..) |spec, si| vals[si] = finalize(&gaccs[si], spec);
            if (sel.having) |h| {
                if (!havingOk(t, sel, h, g.first, specs, vals)) continue;
            }
            try out_groups.append(alloc, .{ .g = @intCast(gi), .vals = vals });
        }
    }
    var sorted_fast = false;
    if (sel.order_by.len == 1) {
        const item = sel.order_by[0];
        if (findSpecIndex(specs, t, item.expr)) |si| {
            const KCtx = struct {
                si: usize,
                desc: bool,
                fn less(c: @This(), a: Out, b: Out) bool {
                    const ord = Value.order(a.vals[c.si], b.vals[c.si]);
                    if (ord == .eq) return false;
                    return if (c.desc) ord == .gt else ord == .lt;
                }
            };
            std.mem.sort(Out, out_groups.items, KCtx{ .si = si, .desc = item.desc }, KCtx.less);
            sorted_fast = true;
        }
    }
    if (sel.order_by.len > 0 and !sorted_fast) {
        const Ctx = struct {
            t: *Table,
            sel: *sql.Select,
            specs: []const AggSpec,
            groups: []Group,
            outs: []Out,
        };
        var ctx = Ctx{ .t = t, .sel = sel, .specs = specs, .groups = groups_slice, .outs = out_groups.items };
        const Cmp = struct {
            fn less(c: *Ctx, a: Out, b: Out) bool {
                for (c.sel.order_by) |item| {
                    const av = aggOrderValue(c, item.expr, a);
                    var abuf: [160]u8 = undefined;
                    const av2: Value = if (av == .text and av.text.len <= abuf.len) blk: {
                        @memcpy(abuf[0..av.text.len], av.text);
                        break :blk .{ .text = abuf[0..av.text.len] };
                    } else av;
                    const bv = aggOrderValue(c, item.expr, b);
                    const ord = Value.order(av2, bv);
                    if (ord == .eq) continue;
                    const less_ = ord == .lt;
                    return if (item.desc) !less_ else less_;
                }
                return false;
            }
            fn aggOrderValue(c: *Ctx, e: *sql.Expr, o: Out) Value {
                if (findSpecIndex(c.specs, c.t, e)) |si| return o.vals[si];
                switch (e.*) {
                    .column => |name| {
                        for (c.sel.items, 0..) |it, oi| {
                            if (it.alias) |al| {
                                if (std.ascii.eqlIgnoreCase(al, name)) return itemValue(c, it.expr, o, oi);
                            }
                        }
                        if (c.t.find(name)) |ci| return cellValue(c.t, ci, c.groups[o.g].first);
                        return .null;
                    },
                    else => return toValue(evalScalar(c.t, e, c.groups[o.g].first)),
                }
            }
            fn itemValue(c: *Ctx, e: *sql.Expr, o: Out, oi: usize) Value {
                _ = oi;
                if (e.* == .call) {
                    if (findSpecIndex(c.specs, c.t, e)) |si| return o.vals[si];
                    return toValue(evalScalar(c.t, e, c.groups[o.g].first));
                }
                return toValue(evalScalar(c.t, e, c.groups[o.g].first));
            }
        };
        std.mem.sort(Out, out_groups.items, &ctx, Cmp.less);
    }
    var start: usize = if (sel.offset) |o| exprUsize(t, o) else 0;
    var end: usize = out_groups.items.len;
    if (sel.limit) |l| {
        const lim = exprUsize(t, l);
        if (start + lim < end) end = start + lim;
    }
    if (start > end) start = end;
    var rows = std.ArrayList([]Value).empty;
    defer rows.deinit(alloc);
    var cols = std.ArrayList([]const u8).empty;
    defer cols.deinit(alloc);
    for (out_groups.items[start..end]) |o| {
        var vals = std.ArrayList(Value).empty;
        for (sel.items) |it| {
            if (it.expr.* == .star) {
                for (t.cols, 0..) |c, ci| {
                    _ = c;
                    try vals.append(alloc, cellValue(t, ci, groups_slice[o.g].first));
                }
            } else if (findSpecIndex(specs, t, it.expr)) |si| {
                try vals.append(alloc, o.vals[si]);
            } else {
                try vals.append(alloc, try evalOwned(t, alloc, it.expr, groups_slice[o.g].first));
            }
        }
        try rows.append(alloc, try vals.toOwnedSlice(alloc));
    }
    for (sel.items) |it| try cols.append(alloc, it.alias orelse exprLabel(it.expr));
    return .{ .columns = try cols.toOwnedSlice(alloc), .rows = try rows.toOwnedSlice(alloc), .format_json = sel.format_json };
}
fn havingOk(t: *Table, sel: *sql.Select, e: *sql.Expr, row: u32, specs: []const AggSpec, vals: []const Value) bool {
    switch (e.*) {
        .binary => |b| switch (b.op) {
            .and_op => return havingOk(t, sel, b.lhs, row, specs, vals) and havingOk(t, sel, b.rhs, row, specs, vals),
            .or_op => return havingOk(t, sel, b.lhs, row, specs, vals) or havingOk(t, sel, b.rhs, row, specs, vals),
            else => {},
        },
        .not => |x| return !havingOk(t, sel, x, row, specs, vals),
        else => {},
    }
    const lv = havingValue(t, sel, e, row, specs, vals);
    return switch (lv) {
        .null => false,
        .int => |i| i != 0,
        .float => |f| f != 0,
        .str => |s| s.len > 0,
        .boolean => |b| b,
    };
}
fn havingValue(t: *Table, sel: *sql.Select, e: *sql.Expr, row: u32, specs: []const AggSpec, vals: []const Value) Scalar {
    switch (e.*) {
        .binary => |b| {
            const l = havingValue(t, sel, b.lhs, row, specs, vals);
            const r = havingValue(t, sel, b.rhs, row, specs, vals);
            return switch (b.op) {
                .eq, .neq, .lt, .gt, .le, .ge => .{ .int = @intFromBool(compareScalar(l, r, b.op)) },
                else => binaryScalar(t, b.op, l, r),
            };
        },
        .call => |c| {
            if (isAggName(c.name)) {
                if (findSpecIndex(specs, t, e)) |si| return valueToScalar(vals[si]);
                return .{ .int = 0 };
            }
            return evalScalar(t, e, row);
        },
        else => return evalScalar(t, e, row),
    }
}
fn valueToScalar(v: Value) Scalar {
    return switch (v) {
        .null => .null,
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .text => |s| .{ .str = s },
        .boolean => |b| .{ .boolean = b },
    };
}
fn likeMatch(text: []const u8, pattern: []const u8) bool {
    var has_wild = false;
    for (pattern) |c| {
        if (c == '%' or c == '_') {
            has_wild = true;
            break;
        }
    }
    if (!has_wild) return std.mem.eql(u8, text, pattern);
    const lead = pattern.len > 0 and pattern[0] == '%';
    const trail = pattern.len > 0 and pattern[pattern.len - 1] == '%';
    if (lead and trail) {
        const inner = pattern[1 .. pattern.len - 1];
        var inner_wild = false;
        for (inner) |c| {
            if (c == '%' or c == '_') {
                inner_wild = true;
                break;
            }
        }
        if (!inner_wild) return std.mem.indexOf(u8, text, inner) != null;
    } else if (lead) {
        const inner = pattern[1..];
        var inner_wild = false;
        for (inner) |c| if (c == '%' or c == '_') {
            inner_wild = true;
        };
        if (!inner_wild) return std.mem.endsWith(u8, text, inner);
    } else if (trail) {
        const inner = pattern[0 .. pattern.len - 1];
        var inner_wild = false;
        for (inner) |c| if (c == '%' or c == '_') {
            inner_wild = true;
        };
        if (!inner_wild) return std.mem.startsWith(u8, text, inner);
    }
    return likeRec(text, 0, pattern, 0);
}
fn likeRec(t: []const u8, ti: usize, p: []const u8, pi: usize) bool {
    var i = pi;
    var s = ti;
    while (i < p.len) {
        switch (p[i]) {
            '%' => {
                var k = s;
                while (true) {
                    if (likeRec(t, k, p, i + 1)) return true;
                    if (k >= t.len) return false;
                    k += 1;
                }
            },
            '_' => {
                if (s >= t.len) return false;
                s += 1;
                i += 1;
            },
            else => {
                if (s >= t.len or t[s] != p[i]) return false;
                s += 1;
                i += 1;
            },
        }
    }
    return s == t.len;
}
test "per-query scratch: two threads on one table agree" {
    const alloc = std.testing.allocator;
    const n: usize = 60_000;
    const rows = try alloc.alloc([]Value, n);
    defer {
        for (rows) |r| alloc.free(r);
        alloc.free(rows);
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = try alloc.alloc(Value, 2);
        r[0] = .{ .int = @intCast(i % 97) };
        r[1] = .{ .int = @intCast(i % 7) };
        rows[i] = r;
    }
    const cols = [_]Column{
        .{ .name = "g", .kind = .int },
        .{ .name = "v", .kind = .int },
    };
    const t = try Table.build(alloc, &cols, rows);
    defer t.destroy(alloc);
    const W = struct {
        t: *Table,
        fn run(self: @This(), buf: []u8, ok: *bool) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var parser = sql.Parser.init(a, "SELECT g, COUNT(*) FROM t GROUP BY g") catch return;
            const stmt = parser.parseStatement() catch return;
            var scr = Scratch{ .buf = buf };
            switch (stmt) {
                .select => |sel| {
                    const res = (tryRunScratch(self.t, a, sel, &scr) catch return) orelse return;
                    if (res.rows.len != 97) return;
                    var total: i64 = 0;
                    for (res.rows) |row| total += row[1].int;
                    ok.* = total == n;
                },
                else => return,
            }
        }
    };
    const buf_size = n * 48 + (1 << 20);
    const b1 = try alloc.alloc(u8, buf_size);
    defer alloc.free(b1);
    const b2 = try alloc.alloc(u8, buf_size);
    defer alloc.free(b2);
    var ok1 = false;
    var ok2 = false;
    const w1 = W{ .t = t };
    const w2 = W{ .t = t };
    var th1 = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{ w1, b1, &ok1 });
    var th2 = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{ w2, b2, &ok2 });
    th1.join();
    th2.join();
    try std.testing.expect(ok1);
    try std.testing.expect(ok2);
}
test "save/load string column roundtrip" {
    const alloc = std.testing.allocator;
    var rows: [2][]Value = undefined;
    const r0 = try alloc.alloc(Value, 1);
    defer alloc.free(r0);
    r0[0] = .{ .text = "abc" };
    const r1 = try alloc.alloc(Value, 1);
    defer alloc.free(r1);
    r1[0] = .{ .text = "de" };
    rows[0] = r0;
    rows[1] = r1;
    const cols = [_]Column{.{ .name = "s", .kind = .str }};
    const t = try Table.build(alloc, &cols, &rows);
    defer t.destroy(alloc);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try t.save(alloc, &buf);
    const L = try Table.loadBytes(alloc, buf.items);
    defer L.destroy(alloc);
    try std.testing.expectEqualStrings("abc", L.data[0].strs.at(0));
    try std.testing.expectEqualStrings("de", L.data[0].strs.at(1));
}
test "string patch buffer is in-place and reclaimed on destroy" {
    const alloc = std.testing.allocator;
    var rows: [2][]Value = undefined;
    const r0 = try alloc.alloc(Value, 1);
    defer alloc.free(r0);
    r0[0] = .{ .text = "alpha" };
    const r1 = try alloc.alloc(Value, 1);
    defer alloc.free(r1);
    r1[0] = .{ .text = "beta" };
    rows[0] = r0;
    rows[1] = r1;
    const cols = [_]Column{.{ .name = "s", .kind = .str }};
    const t = try Table.build(alloc, &cols, &rows);
    defer t.destroy(alloc); // leak-checked: frees the gpa-owned patch buffer
    try std.testing.expectEqualStrings("alpha", t.data[0].strs.at(0));
    const v = [_]Value{.{ .text = "patched-alpha" }};
    try std.testing.expect(t.patchRow(0, &v));
    try std.testing.expectEqualStrings("patched-alpha", t.data[0].strs.at(0));
    try std.testing.expectEqualStrings("beta", t.data[0].strs.at(1));
    try std.testing.expect(t.data[0].strs.patched_owner != null);
}
