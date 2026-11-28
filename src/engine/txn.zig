const std = @import("std");
const engine_mod = @import("../engine.zig");
const Engine = engine_mod.Engine;
const Table = engine_mod.Table;
const Value = engine_mod.Value;
const EngineError = engine_mod.EngineError;
const Result = engine_mod.Result;
const TableSnap = engine_mod.TableSnap;
const tableSetNull = engine_mod.tableSetNull;
const COST_TOMB_FACTOR = engine_mod.COST_TOMB_FACTOR;
const columnar = @import("../columnar.zig");
const findCol = engine_mod.findCol;
const stripSchema = Engine.stripSchema;
const isRowDeleted = engine_mod.isRowDeleted;
const Savepoint = engine_mod.Savepoint;
const ReclaimStats = Engine.ReclaimStats;
const nowNs = Engine.nowNs;
const seg_rows = engine_mod.seg_rows;
const COST_COMPACT_ROW_NS = engine_mod.COST_COMPACT_ROW_NS;

pub const DeadBlocks = struct { rows: usize = 0, full: usize = 0, partial: usize = 0 };

pub fn savepointCreate(self: *Engine, name: []const u8) !void {
    var sp = Savepoint{ .name = try self.gpa.dupe(u8, name) };
    errdefer sp.deinit(self.gpa);
    var it = self.tables.valueIterator();
    while (it.next()) |tp| {
        const t = tp.*;
        if (std.mem.startsWith(u8, t.name, "pg_")) continue;
        const dn = t.deleted.items.len;
        var sn = TableSnap{
            .t = t,
            .rows_len = t.rows.items.len,
            .dead_rows = t.dead_rows,
        };
        sn.deleted = try self.gpa.dupe(u8, t.deleted.items[0..dn]);
        sn.xmax = try self.gpa.dupe(u64, t.xmax.items);
        try sp.tables.append(self.gpa, sn);
    }
    try self.savepoints.append(self.gpa, sp);
}

pub fn savepointRollbackTo(self: *Engine, name: []const u8) void {
    var idx: ?usize = null;
    var i: usize = self.savepoints.items.len;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(self.savepoints.items[i].name, name)) {
            idx = i;
            break;
        }
    }
    const at = idx orelse return;
    while (self.savepoints.items.len > at + 1) {
        var last = self.savepoints.pop().?;
        last.deinit(self.gpa);
    }
    const sp = &self.savepoints.items[at];
    for (sp.tables.items) |sn| {
        const t = sn.t;
        var r = sn.rows_len;
        while (r < t.rows.items.len) : (r += 1) self.gpa.free(t.rows.items[r]);
        if (t.rows.items.len > sn.rows_len) t.rows.shrinkRetainingCapacity(sn.rows_len);
        t.deleted.clearRetainingCapacity();
        t.deleted.appendSlice(self.gpa, sn.deleted) catch {};
        t.xmax.clearRetainingCapacity();
        t.xmax.appendSlice(self.gpa, sn.xmax) catch {};
        while (t.xmin.items.len > t.rows.items.len) _ = t.xmin.pop();
        while (t.cmin.items.len > t.rows.items.len) _ = t.cmin.pop();
        while (t.ctid_num.items.len > t.rows.items.len) _ = t.ctid_num.pop();
        while (t.ctid.items.len > t.rows.items.len) _ = t.ctid.pop();
        t.dead_rows = sn.dead_rows;
    }
    self.invalidateCatalogs();
}

pub fn savepointRelease(self: *Engine, name: []const u8) void {
    var idx: ?usize = null;
    var i: usize = self.savepoints.items.len;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(self.savepoints.items[i].name, name)) {
            idx = i;
            break;
        }
    }
    const at = idx orelse return;
    while (self.savepoints.items.len > at) {
        var last = self.savepoints.pop().?;
        last.deinit(self.gpa);
    }
}

pub fn gcTick(self: *Engine) usize {
    var reclaimed: usize = 0;
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(self.gpa);
    var it = self.tables.iterator();
    while (it.next()) |e| {
        const nm = e.value_ptr.*.name;
        if (std.mem.startsWith(u8, nm, "pg_")) continue;
        names.append(self.gpa, nm) catch continue;
    }
    for (names.items) |nm| {
        var t = self.find(nm) orelse continue;
        if (t.rows.items.len == 0) {
            if (self.findColumnar(nm)) |ct| {
                if (ct.nrows > 0 and ct.anyDeleted()) self.ensureRowsMaterialized(nm);
            }
            t = self.find(nm) orelse continue;
        }
        if (t.rows.items.len < 64) continue;
        const db = self.deadBlocks(t);
        const dense = self.compactionWorthIt(nm, db);
        if (dense) {
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                const rows = t.rows.items.len;
                std.debug.print("[gc] {s}: dead={d}/{d} ({d:.1}%) full_blocks={d} partial_blocks={d} -> block compaction\n", .{
                    nm, db.rows, rows, if (rows > 0) @as(f64, @floatFromInt(db.rows)) / @as(f64, @floatFromInt(rows)) * 100.0 else 0, db.full, db.partial,
                });
            }
            self.compactTable(nm);
            reclaimed += 1;
            break;
        }
        if (t.dead_rows * 8 >= t.rows.items.len and t.dead_rows >= 64) {
            const st = self.reclaimSegments(nm);
            const dropped = self.truncateDeadTail(nm);
            if (st.rows + dropped > 0) reclaimed += 1;
            break;
        }
    }
    return reclaimed;
}

pub fn maybeAutoVacuum(self: *Engine, name: []const u8) void {
    const t = self.find(name) orelse return;
    if (t.rows.items.len < 64) return;
    if (!self.background_gc and t.dead_rows * 8 >= t.rows.items.len and t.dead_rows >= 64) {
        if (std.c.getenv("ZHDB_EXPLAIN") != null) std.debug.print("[vacuum] {s}: {d} dead rows -> interior compaction\n", .{ name, t.dead_rows });
        self.compactTable(name);
    } else if (std.c.getenv("ZHDB_EXPLAIN") != null and t.free_head < t.free_slots.items.len) {
        std.debug.print("[vacuum] {s}: keep (free segments already hold {d} reusable slots; no rewrite)\n", .{ name, t.free_slots.items.len - t.free_head });
    }
}

pub fn noteDeadSlot(self: *Engine, t: *Table, ri: usize) void {
    const seg = ri / seg_rows;
    if (t.seg_dead.items.len <= seg) {
        const old = t.seg_dead.items.len;
        t.seg_dead.resize(self.gpa, seg + 1) catch return;
        @memset(t.seg_dead.items[old..], 0);
        const old2 = t.seg_dirty.items.len;
        t.seg_dirty.resize(self.gpa, seg + 1) catch return;
        @memset(t.seg_dirty.items[old2..], 0);
    }
    t.seg_dead.items[seg] += 1;
    if (t.seg_dirty.items[seg] == 0) {
        t.seg_dirty.items[seg] = 1;
        t.free_segments.append(self.gpa, @intCast(seg)) catch {};
    }
}

pub fn noteFreeSlot(self: *Engine, t: *Table, ri: usize) void {
    t.free_slots.append(self.gpa, @intCast(ri)) catch return;
    const seg = ri / seg_rows;
    if (t.seg_free_rows.items.len <= seg) {
        const old = t.seg_free_rows.items.len;
        t.seg_free_rows.resize(self.gpa, seg + 1) catch return;
        @memset(t.seg_free_rows.items[old..], 0);
    }
    t.seg_free_rows.items[seg] += 1;
}

pub fn sortFreeSlots(self: *Engine, t: *Table) void {
    _ = self;
    if (t.free_head > 0) {
        const rem = t.free_slots.items[t.free_head..];
        if (rem.len > 0) std.mem.copyForwards(u32, t.free_slots.items[0..rem.len], rem);
        t.free_slots.items.len = rem.len;
        t.free_head = 0;
    }
    std.mem.sort(u32, t.free_slots.items, {}, std.sort.asc(u32));
}

pub fn reclaimFreeSegments(self: *Engine, t: *Table) usize {
    var freed: usize = 0;
    var si: usize = 0;
    var w: usize = 0;
    while (si < t.free_segments.items.len) : (si += 1) {
        const seg = t.free_segments.items[si];
        const lo: usize = @as(usize, seg) * seg_rows;
        const hi: usize = @min(lo + seg_rows, t.rows.items.len);
        const seg_len = hi - lo;
        const dcount: usize = if (seg < t.seg_dead.items.len) t.seg_dead.items[seg] else 0;
        if (lo >= hi or dcount < seg_len) {
            t.free_segments.items[w] = seg;
            w += 1;
            continue;
        }
        var all_dead = true;
        var ri = lo;
        while (ri < hi and all_dead) : (ri += 1) {
            if (!isRowDeleted(t, ri)) {
                all_dead = false;
                break;
            }
            const xm: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
            if (xm != 0 and self.isInFlight(xm)) all_dead = false;
        }
        if (!all_dead) {
            t.free_segments.items[w] = seg;
            w += 1;
            continue;
        }
        ri = lo;
        while (ri < hi) : (ri += 1) {
            const row = t.rows.items[ri];
            if (t.placeholder.len == t.cols.len and row.ptr == t.placeholder.ptr) continue;
            self.gpa.free(row);
            t.rows.items[ri] = t.placeholder;
            self.noteFreeSlot(t, ri);
            freed += 1;
        }
        if (t.seg_dead.items.len > seg) t.seg_dead.items[seg] = 0;
        if (t.seg_dirty.items.len > seg) t.seg_dirty.items[seg] = 0;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) std.debug.print("[reclaim] {s}: segment {d} fully free ({d} rows) -> reuse\n", .{ t.name, seg, hi - lo });
    }
    t.free_segments.items.len = w;
    if (t.dead_rows >= freed) t.dead_rows -= freed else t.dead_rows = 0;
    if (freed > 0) self.sortFreeSlots(t);
    return freed;
}

pub fn truncateDeadTail(self: *Engine, name: []const u8) usize {
    const t = self.find(name) orelse return 0;
    var k: usize = 0;
    while (k < t.rows.items.len) : (k += 1) {
        const ri = t.rows.items.len - 1 - k;
        const xm: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
        const dead = isRowDeleted(t, ri) or (xm != 0 and !self.isInFlight(xm));
        if (!dead) break;
    }
    if (k == 0) return 0;
    var k_dead: usize = 0;
    var i: usize = t.rows.items.len - k;
    while (i < t.rows.items.len) : (i += 1) {
        const row = t.rows.items[i];
        if (t.placeholder.len != t.cols.len or row.ptr != t.placeholder.ptr) {
            self.gpa.free(row);
            k_dead += 1;
        }
    }
    const keep = t.rows.items.len - k;
    t.rows.items.len = keep;
    if (t.deleted.items.len > keep) t.deleted.items.len = keep;
    if (t.xmin.items.len > keep) t.xmin.items.len = keep;
    if (t.xmax.items.len > keep) t.xmax.items.len = keep;
    if (t.dead_rows >= k_dead) t.dead_rows -= k_dead else t.dead_rows = 0;
    t.seg_dead.clearRetainingCapacity();
    t.seg_dirty.clearRetainingCapacity();
    t.free_segments.clearRetainingCapacity();
    var w: usize = 0;
    var si: usize = 0;
    for (t.free_slots.items) |slot| {
        if (slot < keep) {
            t.free_slots.items[w] = slot;
            w += 1;
        }
    }
    t.free_slots.items.len = w;
    t.free_head = 0;
    t.seg_free_rows.clearRetainingCapacity();
    for (t.free_slots.items) |slot| {
        si = slot / seg_rows;
        if (t.seg_free_rows.items.len <= si) {
            const old = t.seg_free_rows.items.len;
            t.seg_free_rows.resize(self.gpa, si + 1) catch break;
            @memset(t.seg_free_rows.items[old..], 0);
        }
        t.seg_free_rows.items[si] += 1;
    }
    if (self.findColumnar(name)) |ct| {
        if (ct.nrows > keep) ct.truncateRows(keep);
    }
    return k;
}

pub fn reclaimSegments(self: *Engine, name: []const u8) ReclaimStats {
    var st = ReclaimStats{};
    const t = self.find(name) orelse return st;
    for (t.free_segments.items) |seg| {
        const lo: usize = @as(usize, seg) * seg_rows;
        const hi: usize = @min(lo + seg_rows, t.rows.items.len);
        st.segments += 1;
        var ri = lo;
        while (ri < hi) : (ri += 1) {
            if (!isRowDeleted(t, ri)) continue;
            const row = t.rows.items[ri];
            if (t.placeholder.len == t.cols.len and row.ptr == t.placeholder.ptr) continue;
            const xm: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
            if (xm != 0 and self.isInFlight(xm)) continue;
            self.gpa.free(row);
            t.rows.items[ri] = t.placeholder;
            self.noteFreeSlot(t, ri);
            st.rows += 1;
        }
        if (t.seg_dead.items.len > seg) t.seg_dead.items[seg] = 0;
        if (t.seg_dirty.items.len > seg) t.seg_dirty.items[seg] = 0;
    }
    t.free_segments.clearRetainingCapacity();
    if (t.dead_rows >= st.rows) t.dead_rows -= st.rows else t.dead_rows = 0;
    if (st.rows > 0) self.sortFreeSlots(t);
    return st;
}

pub fn compactTable(self: *Engine, name: []const u8) void {
    const t = self.find(name) orelse return;
    const rows_before = t.rows.items.len;
    const t_start = nowNs();
    self.wb_full = true;
    self.wb_dirty.clearRetainingCapacity();
    const had_tomb = t.deleted.items.len > 0;
    const had_versions = t.xmax.items.len > 0;
    if (!had_tomb and !had_versions) return;
    var w: usize = 0;
    var remap = std.ArrayList(u32).empty;
    defer remap.deinit(self.gpa);
    remap.resize(self.gpa, t.rows.items.len) catch {};
    @memset(remap.items, 0xFFFF_FFFF);
    for (t.rows.items, 0..) |row, ri| {
        const dead = isRowDeleted(t, ri) or (ri < t.xmax.items.len and t.xmax.items[ri] != 0 and !self.isInFlight(t.xmax.items[ri]));
        if (dead) {
            if (t.placeholder.len != t.cols.len or row.ptr != t.placeholder.ptr) self.gpa.free(row);
            continue;
        }
        if (w < remap.items.len) remap.items[ri] = @intCast(w);
        t.rows.items[w] = row;
        if (ri < t.xmin.items.len) t.xmin.items[w] = t.xmin.items[ri];
        if (ri < t.xmax.items.len) {
            const xm = t.xmax.items[ri];
            t.xmax.items[w] = if (xm != 0 and self.isInFlight(xm)) xm else 0;
        }
        w += 1;
    }
    t.rows.items.len = w;
    if (t.xmin.items.len > w) t.xmin.items.len = w;
    if (t.xmax.items.len > w) t.xmax.items.len = w;
    t.deleted.clearRetainingCapacity();
    t.dead_rows = 0;
    t.seg_dead.clearRetainingCapacity();
    t.seg_dirty.clearRetainingCapacity();
    t.free_segments.clearRetainingCapacity();
    t.free_slots.clearRetainingCapacity();
    t.free_head = 0;
    t.seg_free_rows.clearRetainingCapacity();
    for (t.nulls) |*slot| slot.* = null;
    for (t.rows.items, 0..) |row, ri| {
        for (0..t.cols.len) |ci| {
            if (row[ci] == .null) tableSetNull(self.gpa, t, ci, ri, true) catch {};
        }
    }
    self.index_remap = remap.items;
    defer self.index_remap = null;
    self.buildColumnar(name) catch {};
    const dt = nowNs() - t_start;
    if (rows_before > 0 and dt > 0) {
        const sample = @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(rows_before));
        const alpha: f64 = if (self.compact_samples < 4) 0.5 else 0.2;
        self.compact_row_ns = std.math.clamp((1.0 - alpha) * self.compact_row_ns + alpha * sample, 5.0, 5000.0);
        self.compact_samples += 1;
        self.costs_dirty = true;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[compact] {s}: rows={d} ns/row={d:.1} (learned {d:.1})\n", .{
                name,
                rows_before,
                sample,
                self.compact_row_ns,
            });
        }
    }
}

pub fn learnAlpha(self: *Engine) f64 {
    return if (self.wb_samples < 6) 0.5 else 0.2;
}

pub fn learnWrite(self: *Engine, bytes: usize, ns: anytype) void {
    if (bytes == 0 or std.c.getenv("ZHDB_WB_NO_LEARN") != null) return;
    const sample = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(bytes));
    const a = self.learnAlpha();
    self.wb_write_ns_byte = std.math.clamp((1.0 - a) * self.wb_write_ns_byte + a * sample, 0.05, 50.0);
    self.wb_samples += 1;
    self.costs_dirty = true;
}

pub fn learnEncode(self: *Engine, rows: usize, ns: anytype) void {
    if (rows == 0 or std.c.getenv("ZHDB_WB_NO_LEARN") != null) return;
    const sample = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(rows));
    const a = self.learnAlpha();
    self.wb_encode_ns_row = std.math.clamp((1.0 - a) * self.wb_encode_ns_row + a * sample, 1.0, 2000.0);
    self.wb_samples += 1;
    self.costs_dirty = true;
}

pub fn noteReplaySample(self: *Engine, rows: usize, ns: anytype) void {
    if (rows == 0 or std.c.getenv("ZHDB_WB_NO_LEARN") != null) return;
    const sample = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(rows));
    const a = self.learnAlpha();
    self.wb_replay_ns_row = std.math.clamp((1.0 - a) * self.wb_replay_ns_row + a * sample, 5.0, 20000.0);
    self.wb_samples += 1;
    self.costs_dirty = true;
}

pub fn refreshWbTrailer(self: *Engine, io: std.Io, path: []const u8) void {
    var tr: [columnar.trailer_len_v3]u8 = undefined;
    columnar.Table.encodeWbTrailer(.{
        .write_ns_byte = self.wb_write_ns_byte,
        .encode_ns_row = self.wb_encode_ns_row,
        .replay_ns_row = self.wb_replay_ns_row,
        .compact_row_ns = self.compact_row_ns,
        .samples = self.wb_samples,
        .scan_row_ns = self.cost_scan_row,
        .str_raw_ns = self.cost_str_raw_row,
        .str_dict_ns = self.cost_str_dict_row,
    }, &tr);
    const f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch return;
    defer f.close(io);
    const size = (f.stat(io) catch return).size;
    var has: usize = 0;
    const lens = [3]usize{ columnar.trailer_len_v3, columnar.trailer_len_v2, columnar.trailer_len_v1 };
    for (lens) |l| {
        if (size < l) continue;
        var tail: [4]u8 = undefined;
        const n = f.readPositionalAll(io, &tail, size - l) catch 0;
        if (n == 4 and std.mem.eql(u8, &tail, "ZBT1")) {
            has = l;
            break;
        }
    }
    if (has != 0 and has != columnar.trailer_len_v3) {
        f.setLength(io, size - has + columnar.trailer_len_v3) catch return;
        f.writePositionalAll(io, &tr, size - has) catch return;
        f.sync(io) catch {};
        return;
    }
    const off: u64 = if (has == columnar.trailer_len_v3) size - columnar.trailer_len_v3 else size;
    f.writePositionalAll(io, &tr, off) catch return;
    f.sync(io) catch {};
    if (std.c.getenv("ZHDB_EXPLAIN") != null) {
        std.debug.print("[writeback] trailer refreshed at {d} write={d:.2}ns/B enc={d:.1}ns/row rep={d:.1}ns/row scan={d:.2}ns/row str_raw={d:.2} str_dict={d:.2} samples={d}\n", .{
            off,                self.wb_write_ns_byte, self.wb_encode_ns_row,  self.wb_replay_ns_row,
            self.cost_scan_row, self.cost_str_raw_row, self.cost_str_dict_row, self.wb_samples,
        });
    }
}

pub fn checkpointCosts(self: *Engine, io: std.Io) void {
    if (!self.costs_dirty) return;
    const now = nowNs();
    if (self.last_cost_save_ns != 0 and now >= self.last_cost_save_ns and now - self.last_cost_save_ns < 1_000_000_000) return;
    self.flushCostsNow(io, now);
}

pub fn flushCosts(self: *Engine, io: std.Io) void {
    if (!self.costs_dirty) return;
    self.flushCostsNow(io, nowNs());
}

pub fn flushCostsNow(self: *Engine, io: std.Io, now: u64) void {
    const path = self.snapshot_path orelse return;
    self.refreshWbTrailer(io, path);
    self.costs_dirty = false;
    self.last_cost_save_ns = now;
    if (std.c.getenv("ZHDB_EXPLAIN") != null) {
        std.debug.print("[calib] checkpoint planner costs scan_row={d:.2} str_raw={d:.2} str_dict={d:.2} -> {s}\n", .{
            self.cost_scan_row,
            self.cost_str_raw_row,
            self.cost_str_dict_row,
            path,
        });
    }
}

pub fn restoreWbCosts(self: *Engine, c: columnar.WbCosts) void {
    self.wb_write_ns_byte = std.math.clamp(c.write_ns_byte, 0.05, 50.0);
    self.wb_encode_ns_row = std.math.clamp(c.encode_ns_row, 1.0, 2000.0);
    self.wb_replay_ns_row = std.math.clamp(c.replay_ns_row, 5.0, 20000.0);
    self.compact_row_ns = std.math.clamp(c.compact_row_ns, 5.0, 5000.0);
    self.wb_samples = @intCast(@min(c.samples, 1 << 40));
    var restored_plan = false;
    if (c.scan_row_ns > 0) {
        self.cost_scan_row = std.math.clamp(c.scan_row_ns, 0.3, 12.0);
        restored_plan = true;
    }
    if (c.str_raw_ns > 0) self.cost_str_raw_row = std.math.clamp(c.str_raw_ns, 0.03, 20.0);
    if (c.str_dict_ns > 0) self.cost_str_dict_row = std.math.clamp(c.str_dict_ns, 0.03, 20.0);
    columnar.setCosts(self.cost_scan_row, self.cost_index_row, self.cost_index_probe);
    columnar.setStrCosts(self.cost_str_raw_row, self.cost_str_dict_row);
    if (restored_plan) {
        self.costs_calibrated = true;
        self.costs_restored = true;
    }
    if (std.c.getenv("ZHDB_EXPLAIN") != null) {
        std.debug.print("[writeback] restored costs (snapshot v8) write={d:.2}ns/B enc={d:.1}ns/row rep={d:.1}ns/row compact={d:.1}ns/row samples={d}\n", .{
            self.wb_write_ns_byte,
            self.wb_encode_ns_row,
            self.wb_replay_ns_row,
            self.compact_row_ns,
            self.wb_samples,
        });
        if (restored_plan) {
            std.debug.print("[calib] restored planner costs scan_row={d:.2}ns/row str_raw={d:.2} str_dict={d:.2} (from trailer)\n", .{
                self.cost_scan_row,
                self.cost_str_raw_row,
                self.cost_str_dict_row,
            });
        } else {
            std.debug.print("[calib] planner costs seeded scan_row={d:.2}ns/row str_raw={d:.2} str_dict={d:.2} (trailer predates planner fields)\n", .{
                self.cost_scan_row,
                self.cost_str_raw_row,
                self.cost_str_dict_row,
            });
        }
    }
}

pub fn loadWbCosts(self: *Engine, io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
    const mp = std.fmt.allocPrint(gpa, "{s}.meta", .{path}) catch return;
    defer gpa.free(mp);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, mp, gpa, .limited(1 << 20)) catch return;
    defer gpa.free(bytes);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    const head = it.next() orelse return;
    if (!std.mem.startsWith(u8, head, "zhdb-meta")) return;
    while (it.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const key = parts.next() orelse continue;
        const val = parts.next() orelse continue;
        if (std.mem.eql(u8, key, "write_ns_byte")) {
            self.wb_write_ns_byte = std.fmt.parseFloat(f64, val) catch self.wb_write_ns_byte;
        } else if (std.mem.eql(u8, key, "encode_ns_row")) {
            self.wb_encode_ns_row = std.fmt.parseFloat(f64, val) catch self.wb_encode_ns_row;
        } else if (std.mem.eql(u8, key, "replay_ns_row")) {
            self.wb_replay_ns_row = std.fmt.parseFloat(f64, val) catch self.wb_replay_ns_row;
        } else if (std.mem.eql(u8, key, "samples")) {
            self.wb_samples = std.fmt.parseInt(usize, val, 10) catch self.wb_samples;
        }
    }
    self.wb_write_ns_byte = std.math.clamp(self.wb_write_ns_byte, 0.05, 50.0);
    self.wb_encode_ns_row = std.math.clamp(self.wb_encode_ns_row, 1.0, 2000.0);
    self.wb_replay_ns_row = std.math.clamp(self.wb_replay_ns_row, 5.0, 20000.0);
    if (std.c.getenv("ZHDB_EXPLAIN") != null) {
        std.debug.print("[writeback] restored costs write={d:.2}ns/B enc={d:.1}ns/row rep={d:.1}ns/row samples={d}\n", .{
            self.wb_write_ns_byte, self.wb_encode_ns_row, self.wb_replay_ns_row, self.wb_samples,
        });
    }
}

pub fn saveSnapshotFile(self: *Engine, io: std.Io, gpa: std.mem.Allocator, table: []const u8, path: []const u8) !void {
    const t0 = std.Io.Clock.now(.awake, io).nanoseconds;
    const t = self.findColumnar(table) orelse return error.TableNotFound;
    const READ_NS_PER_BYTE: f64 = 0.8;
    const WRITE_NS_PER_BYTE: f64 = self.wb_write_ns_byte;
    const ENCODE_ROW_NS: f64 = self.wb_encode_ns_row;
    const REPLAY_ROW_NS: f64 = self.wb_replay_ns_row;
    const n_dirty = self.wb_dirty.items.len;
    if (!self.wb_full and n_dirty == 0) return;
    const dpath = try std.fmt.allocPrint(gpa, "{s}.delta", .{path});
    defer gpa.free(dpath);
    var base_bytes: u64 = 0;
    {
        const bf = std.Io.Dir.cwd().openFile(io, path, .{}) catch null;
        if (bf) |f| {
            defer f.close(io);
            const st = f.stat(io) catch null;
            if (st) |stt| base_bytes = stt.size;
        }
    }
    if (!self.wb_full and n_dirty > 0) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(gpa);
        var old_len: usize = 0;
        if (std.Io.Dir.cwd().readFileAlloc(io, dpath, gpa, .limited(64 << 20))) |old| {
            defer gpa.free(old);
            old_len = old.len;
            try buf.appendSlice(gpa, old);
        } else |_| {}
        const a0 = std.Io.Clock.now(.awake, io).nanoseconds;
        try t.appendDelta(gpa, self.wb_dirty.items, &buf);
        const a1 = std.Io.Clock.now(.awake, io).nanoseconds;
        const new_section = buf.items.len - old_len;
        const per_row: usize = if (n_dirty > 0) @max(new_section / n_dirty, 1) else 1;
        const delta_rows: usize = if (per_row > 0) old_len / per_row + n_dirty else n_dirty;
        const delta_bytes: f64 = @floatFromInt(buf.items.len);
        const replay_ns = delta_bytes * READ_NS_PER_BYTE + @as(f64, @floatFromInt(delta_rows)) * REPLAY_ROW_NS;
        const rewrite_ns = @as(f64, @floatFromInt(base_bytes + buf.items.len)) * WRITE_NS_PER_BYTE +
            @as(f64, @floatFromInt(t.nrows)) * ENCODE_ROW_NS;
        const ratio_ok = n_dirty * 4 <= t.nrows;
        const have_base = base_bytes > 0;
        var use_delta = ratio_ok and have_base and replay_ns < rewrite_ns;
        var why: []const u8 = if (!ratio_ok) "dirty>25%" else if (!have_base) "no-base" else if (replay_ns >= rewrite_ns) "replay>rewrite" else "cost";
        if (std.c.getenv("ZHDB_DELTA_MAX")) |v| {
            const delta_max = std.fmt.parseInt(usize, std.mem.span(v), 10) catch 0;
            if (delta_max > 0 and buf.items.len > delta_max) {
                use_delta = false;
                why = "ZHDB_DELTA_MAX";
            }
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[writeback] {s}: policy dirty={d} delta_rows={d} delta_bytes={d} base_bytes={d} replay={d:.1}us rewrite={d:.1}us (write={d:.2}ns/B enc={d:.1}ns/row rep={d:.1}ns/row) -> {s} ({s})\n", .{
                table, n_dirty, delta_rows, buf.items.len, base_bytes, replay_ns / 1000.0, rewrite_ns / 1000.0, WRITE_NS_PER_BYTE, ENCODE_ROW_NS, REPLAY_ROW_NS, if (use_delta) "delta" else "full", why,
            });
        }
        if (use_delta) {
            const f = try std.Io.Dir.cwd().createFile(io, dpath, .{});
            defer f.close(io);
            const w0 = std.Io.Clock.now(.awake, io).nanoseconds;
            try f.writeStreamingAll(io, buf.items);
            const w1 = std.Io.Clock.now(.awake, io).nanoseconds;
            self.learnEncode(n_dirty, a1 - a0);
            self.learnWrite(buf.items.len, w1 - w0);
            self.refreshWbTrailer(io, path);
            self.wb_dirty.clearRetainingCapacity();
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                const dt = @as(f64, @floatFromInt(std.Io.Clock.now(.awake, io).nanoseconds - t0)) / 1e6;
                std.debug.print("[writeback] {s}: delta rows={d} bytes={d} {d:.1} ms\n", .{ table, n_dirty, buf.items.len, dt });
            }
            return;
        }
    }
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(gpa);
    const e0 = std.Io.Clock.now(.awake, io).nanoseconds;
    try t.saveWithCosts(gpa, &buf, .{
        .write_ns_byte = self.wb_write_ns_byte,
        .encode_ns_row = self.wb_encode_ns_row,
        .replay_ns_row = self.wb_replay_ns_row,
        .compact_row_ns = self.compact_row_ns,
        .samples = self.wb_samples,
        .scan_row_ns = self.cost_scan_row,
        .str_raw_ns = self.cost_str_raw_row,
        .str_dict_ns = self.cost_str_dict_row,
    });
    const e1 = std.Io.Clock.now(.awake, io).nanoseconds;
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    const w0 = std.Io.Clock.now(.awake, io).nanoseconds;
    try f.writeStreamingAll(io, buf.items);
    const w1 = std.Io.Clock.now(.awake, io).nanoseconds;
    self.learnEncode(t.nrows, e1 - e0);
    self.learnWrite(buf.items.len, w1 - w0);
    self.refreshWbTrailer(io, path);
    self.wb_dirty.clearRetainingCapacity();
    self.wb_full = false;
    std.Io.Dir.cwd().deleteFile(io, dpath) catch {};
    if (std.c.getenv("ZHDB_EXPLAIN") != null) {
        const dt = @as(f64, @floatFromInt(std.Io.Clock.now(.awake, io).nanoseconds - t0)) / 1e6;
        std.debug.print("[writeback] {s}: full rows={d} bytes={d} {d:.1} ms\n", .{ table, t.nrows, buf.items.len, dt });
    }
}

pub fn compactIfDense(self: *Engine, name: []const u8, dead_hint: usize) usize {
    const t = self.find(name) orelse return 0;
    const rows = t.rows.items.len;
    const dead = @max(t.dead_rows, dead_hint);
    if (rows < 64 or dead == 0) return 0;
    self.calibrateCostsFor(self.findColumnar(name));
    var q: f64 = 20;
    const observed: f64 = @floatFromInt(self.scansOf(name));
    if (observed > q) q = observed;
    if (std.c.getenv("ZHDB_COMPACT_Q")) |v| q = std.fmt.parseFloat(f64, std.mem.span(v)) catch q;
    const n: f64 = @floatFromInt(rows);
    const d: f64 = @floatFromInt(dead);
    const rewrite_cost = n * COST_COMPACT_ROW_NS;
    const scan_penalty = d * self.cost_scan_row * COST_TOMB_FACTOR;
    const should = scan_penalty * q > rewrite_cost;
    if (std.c.getenv("ZHDB_EXPLAIN") != null) {
        std.debug.print("[vacuum] {s}: dead={d}/{d} ({d:.1}%) penalty/scan={d:.2} ms expected={d:.0} ms rewrite={d:.1} ms q={d:.0} (observed={d}) -> {s}\n", .{
            name,
            dead,
            rows,
            d / n * 100.0,
            scan_penalty / 1e6,
            scan_penalty * q / 1e6,
            rewrite_cost / 1e6,
            q,
            self.scansOf(name),
            if (should) "compact" else "keep",
        });
    }
    if (!should) return 0;
    const before = rows;
    self.compactTable(name);
    const after = (self.find(name) orelse return 0).rows.items.len;
    return before - after;
}

pub fn deadBlocks(self: *Engine, t: *Table) DeadBlocks {
    var rows: usize = 0;
    var full: usize = 0;
    var partial: usize = 0;
    const nb = (t.rows.items.len + seg_rows - 1) / seg_rows;
    var b: usize = 0;
    while (b < nb) : (b += 1) {
        const r0 = b * seg_rows;
        const r1 = @min(r0 + seg_rows, t.rows.items.len);
        var dead: usize = 0;
        var ri = r0;
        while (ri < r1) : (ri += 1) {
            const xm: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
            const d = isRowDeleted(t, ri) or (xm != 0 and !self.isInFlight(xm));
            if (d) dead += 1;
        }
        rows += dead;
        const seg_len = r1 - r0;
        if (dead == seg_len and seg_len > 0) full += 1;
        if (seg_len > 0 and dead >= (seg_len + 3) / 4 and dead < seg_len) partial += 1;
    }
    return .{ .rows = rows, .full = full, .partial = partial };
}

pub fn compactionWorthIt(self: *Engine, name: []const u8, db: DeadBlocks) bool {
    _ = db;
    const t = self.find(name) orelse return false;
    const rows = t.rows.items.len;
    if (rows < 64) return false;
    self.calibrateCostsFor(self.findColumnar(name));
    var q: f64 = 20;
    const observed: f64 = @floatFromInt(self.scansOf(name));
    if (observed > q) q = observed;
    if (std.c.getenv("ZHDB_COMPACT_Q")) |v| q = std.fmt.parseFloat(f64, std.mem.span(v)) catch q;
    const nb = (rows + seg_rows - 1) / seg_rows;
    var should = false;
    var b: usize = 0;
    while (b < nb) : (b += 1) {
        const r0 = b * seg_rows;
        const r1 = @min(r0 + seg_rows, rows);
        var dead: usize = 0;
        var ri = r0;
        while (ri < r1) : (ri += 1) {
            const xm: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
            if (isRowDeleted(t, ri) or (xm != 0 and !self.isInFlight(xm))) dead += 1;
        }
        if (dead == 0) continue;
        const blen: f64 = @floatFromInt(r1 - r0);
        const d: f64 = @floatFromInt(dead);
        const rewrite_b = blen * self.compact_row_ns;
        const scan_b = d * self.cost_scan_row * COST_TOMB_FACTOR * q;
        const space_b = (d / blen) * rewrite_b;
        const block_pays = dead >= (r1 - r0) or scan_b + space_b > rewrite_b;
        if (block_pays) should = true;
        if (std.c.getenv("ZHDB_EXPLAIN") != null and block_pays) {
            std.debug.print("[gc] {s}: block {d} dead={d}/{d} ({d:.0}%) q={d:.0} rewrite={d:.2}ms scan={d:.2}ms space={d:.2}ms -> compact\n", .{
                name,
                b,
                dead,
                r1 - r0,
                d / blen * 100.0,
                q,
                rewrite_b / 1e6,
                scan_b / 1e6,
                space_b / 1e6,
            });
        }
    }
    if (!should and std.c.getenv("ZHDB_EXPLAIN") != null) {
        var total_dead: usize = 0;
        for (0..rows) |ri| {
            const xm: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
            if (isRowDeleted(t, ri) or (xm != 0 and !self.isInFlight(xm))) total_dead += 1;
        }
        std.debug.print("[gc] {s}: dead={d}/{d} q={d:.0} -> keep (no block pays off)\n", .{ name, total_dead, rows, q });
    }
    return should;
}

pub fn markVacuumSize(self: *Engine, n: []const u8) void {
    const t = self.find(n) orelse return;
    if (t.rows.items.len > 0) return;
    var tb: [256]u8 = undefined;
    const tl = std.ascii.lowerString(tb[0..@min(n.len, tb.len)], n[0..@min(n.len, tb.len)]);
    if (self.relopts.get(tl)) |st| {
        for (st.opts) |o| if (std.ascii.eqlIgnoreCase(o.name, "vacuum_truncate") and std.ascii.eqlIgnoreCase(o.value, "false")) return;
    }
    const k = self.gpa.dupe(u8, tl) catch return;
    self.zero_size.put(k, {}) catch {};
}

pub fn execVacuum(self: *Engine, name: ?[]const u8) EngineError!Result {
    if (name) |n| {
        self.execMaintenance(n, 1);
        self.ensureRowsMaterialized(n);
        const db = if (self.find(n)) |tt| self.deadBlocks(tt) else DeadBlocks{};
        var st = self.reclaimSegments(n);
        const dropped = self.truncateDeadTail(n);
        var block_compact = false;
        const compacted = if (db.full > 0) blk: {
            block_compact = true;
            self.compactTable(n);
            break :blk 1;
        } else self.compactIfDense(n, db.rows);
        if (compacted > 0 and std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[vacuum] {s}: {s} ({d} rows)\n", .{
                n, if (block_compact) "block compaction" else "compacted interior", compacted,
            });
        }
        st.blocks_dropped = (dropped + seg_rows - 1) / seg_rows;
        if (dropped > 0) st.rows += dropped;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) std.debug.print("[vacuum] {s}: segments={d} rows={d} tail_rows={d} blocks_dropped={d}\n", .{ n, st.segments, st.rows - dropped, dropped, st.blocks_dropped });
        self.markVacuumSize(n);
        return .{ .affected = 0 };
    }
    var it = self.tables.iterator();
    while (it.next()) |e| {
        const nm = e.value_ptr.*.name;
        if (std.mem.startsWith(u8, nm, "pg_")) continue;
        self.ensureRowsMaterialized(nm);
        const db = if (self.find(nm)) |tt| self.deadBlocks(tt) else DeadBlocks{};
        const st = self.reclaimSegments(nm);
        const dropped = self.truncateDeadTail(nm);
        self.markVacuumSize(nm);
        var block_compact = false;
        const comp = if (db.full > 0) blk: {
            block_compact = true;
            self.compactTable(nm);
            break :blk 1;
        } else self.compactIfDense(nm, db.rows);
        if (comp > 0 and std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[vacuum] {s}: {s} ({d} rows)\n", .{
                nm,
                if (block_compact) "block compaction" else "compacted interior",
                comp,
            });
        }
        if (st.rows + dropped > 0 and std.c.getenv("ZHDB_EXPLAIN") != null) std.debug.print("[vacuum] {s}: segments={d} rows={d} tail_rows={d}\n", .{ nm, st.segments, st.rows, dropped });
    }
    return .{ .affected = 0 };
}
