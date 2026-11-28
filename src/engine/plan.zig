const std = @import("std");
const engine_mod = @import("../engine.zig");
const Engine = engine_mod.Engine;
const sql = @import("../sql.zig");
const Table = engine_mod.Table;
const Value = engine_mod.Value;
const Result = engine_mod.Result;
const EngineError = engine_mod.EngineError;
const RowIndex = engine_mod.RowIndex;
const valueKeyOwned = engine_mod.valueKeyOwned;
const materializeRow = engine_mod.materializeRow;
const formatTid = engine_mod.formatTid;
const isRowDeleted = engine_mod.isRowDeleted;
const isAggCall = engine_mod.isAggCall;
const exprName = engine_mod.exprName;
const findColSlice = engine_mod.findColSlice;
const oneText = engine_mod.oneText;
const stripSchema = Engine.stripSchema;

pub const CostEst = struct { startup: f64, total: f64, rows: f64, width: u32 };
pub const ScanPlan = struct { kind: enum { seq, index, bitmap } = .seq, idx: ?[]const u8 = null, cost: CostEst };
pub const JoinChoice = struct { nl_total: f64, hj_total: f64, out: f64, use_nl: bool };

pub fn costWidth(self: *Engine, t: *Table) u32 {
    _ = self;
    var w: u32 = 0;
    for (t.cols) |c| w += switch (c.ty) {
        .int => 4,
        .float => 8,
        .boolean => 1,
        else => 32,
    };
    return @max(w, 1);
}

pub fn costSeq(self: *Engine, t: *Table, where: ?*sql.Expr, alias: ?[]const u8) CostEst {
    const n: f64 = @floatFromInt(t.rows.items.len);
    const sel: f64 = if (where != null) self.whereSelectivityAlias(t.name, where, alias) else 1.0;
    const floor: f64 = if (where != null) 1.0 else 0.0;
    const out = @max(if (where != null) n * sel else n, floor);
    const w = self.costWidth(t);
    const bytes = n * @as(f64, @floatFromInt(w));
    const pages = @max(@ceil(bytes / 8192.0), 1.0);
    const total = pages * 1.0 + n * 0.01 + (if (where != null) n * 0.0025 else 0.0);
    return .{ .startup = 0, .total = total, .rows = out, .width = w };
}

pub fn costConstlike(e: *sql.Expr) bool {
    return switch (e.*) {
        .int, .float, .string, .null_lit => true,
        .cast => |c| costConstlike(c.operand),
        else => false,
    };
}

pub fn costPredCol(self: *Engine, t: *Table, where: ?*sql.Expr, alias: ?[]const u8) ?usize {
    const w = where orelse return null;
    if (w.* != .binary) return null;
    const b = w.binary;
    if (b.op != .eq and b.op != .lt and b.op != .le and b.op != .gt and b.op != .ge) return null;
    if (self.tableColOfAlias(t.name, b.lhs, alias)) |ci| {
        if (costConstlike(b.rhs)) return ci;
    }
    if (self.tableColOfAlias(t.name, b.rhs, alias)) |ci| {
        if (costConstlike(b.lhs)) return ci;
    }
    return null;
}

pub fn findIndexForCol(self: *Engine, t: *Table, col: usize) ?[]const u8 {
    const cn = t.cols[col].name;
    var it = self.index_names.iterator();
    while (it.next()) |e| {
        if (!std.ascii.eqlIgnoreCase(stripSchema(e.value_ptr.*), stripSchema(t.name))) continue;
        const m = self.index_meta.get(e.key_ptr.*) orelse continue;
        for (m.cols) |mc| {
            if (mc.include) continue;
            if (std.ascii.eqlIgnoreCase(mc.name, cn)) return e.key_ptr.*;
            break;
        }
    }
    return null;
}

pub fn costIndex(self: *Engine, t: *Table, col: usize, where: ?*sql.Expr, alias: ?[]const u8) CostEst {
    const n: f64 = @floatFromInt(t.rows.items.len);
    const sel = if (where != null) self.whereSelectivityAlias(t.name, where, alias) else 1.0;
    const m = @max(n * sel, 1.0);
    _ = self.ensureColStatQuick(t, col);
    const ndv: f64 = if (col < t.stats.len and t.stats[col].ndv > 0) @floatFromInt(t.stats[col].ndv) else @max(n / 100.0, 1.0);
    const idx_pages = @max(@ceil(ndv * 16.0 / 8192.0), 1.0);
    const startup = 0.29 + 0.01 * std.math.log2(@max(n, 2.0));
    const total = startup + idx_pages * 1.0 + m * (4.0 * 0.5 + 0.0125);
    return .{ .startup = startup, .total = total, .rows = m, .width = self.costWidth(t) };
}

pub fn costBitmapIndex(self: *Engine, t: *Table, col: usize, where: ?*sql.Expr, alias: ?[]const u8) CostEst {
    const n: f64 = @floatFromInt(t.rows.items.len);
    const sel: f64 = if (where != null) self.whereSelectivityAlias(t.name, where, alias) else 1.0;
    const m = @max(n * sel, 1.0);
    _ = self.ensureColStatQuick(t, col);
    const ndv: f64 = if (col < t.stats.len and t.stats[col].ndv > 0) @floatFromInt(t.stats[col].ndv) else @max(n / 100.0, 1.0);
    const idx_pages = @max(@ceil(ndv * 16.0 / 8192.0), 1.0);
    const startup = 0.29 + 0.01 * std.math.log2(@max(n, 2.0));
    return .{ .startup = startup, .total = startup + idx_pages * 1.0 + m * 0.005, .rows = m, .width = 0 };
}

pub fn costBitmap(self: *Engine, t: *Table, col: usize, where: ?*sql.Expr, alias: ?[]const u8) CostEst {
    const n: f64 = @floatFromInt(t.rows.items.len);
    const sel: f64 = if (where != null) self.whereSelectivityAlias(t.name, where, alias) else 1.0;
    const m = @max(n * sel, 1.0);
    const ic = self.costBitmapIndex(t, col, where, alias);
    const w: f64 = @floatFromInt(self.costWidth(t));
    const heap_pages = @max(@ceil(m * w / 8192.0), 1.0);
    const total = ic.total + heap_pages * 1.0 + n * 0.0025 + m * 0.01;
    return .{ .startup = ic.startup, .total = total, .rows = m, .width = self.costWidth(t) };
}

pub fn planScan(self: *Engine, t: *Table, where: ?*sql.Expr, alias: ?[]const u8, seq_off: bool) ScanPlan {
    const seq = self.costSeq(t, where, alias);
    var best = ScanPlan{ .kind = .seq, .cost = seq };
    if (where != null) {
        if (self.costPredCol(t, where, alias)) |ci| {
            if (self.findIndexForCol(t, ci)) |ix| {
                const ic = self.costIndex(t, ci, where, alias);
                const bc = self.costBitmap(t, ci, where, alias);
                if (bc.total < best.cost.total and bc.total <= ic.total) best = .{ .kind = .bitmap, .idx = ix, .cost = bc };
                if (ic.total < best.cost.total) best = .{ .kind = .index, .idx = ix, .cost = ic };
                if (seq_off and best.kind == .seq) {
                    best = if (ic.total <= bc.total) .{ .kind = .index, .idx = ix, .cost = ic } else .{ .kind = .bitmap, .idx = ix, .cost = bc };
                }
            }
        }
    }
    return best;
}

pub fn buildRowIndex(self: *Engine, t: *Table, col: usize) EngineError!*RowIndex {
    if (t.row_idx) |old| {
        old.deinit();
        self.gpa.destroy(old);
        t.row_idx = null;
    }
    const ri = try self.gpa.create(RowIndex);
    ri.* = .{
        .col = col,
        .ver = self.table_ver.get(t.name) orelse 0,
        .map = std.StringHashMap(std.ArrayListUnmanaged(u32)).init(self.gpa),
        .gpa = self.gpa,
    };
    for (t.rows.items, 0..) |row, idx| {
        if (isRowDeleted(t, idx)) continue;
        if (col >= row.len) continue;
        const key = (try valueKeyOwned(self.gpa, row[col])) orelse continue;
        const gop = ri.map.getOrPut(key) catch {
            self.gpa.free(key);
            return error.OutOfMemory;
        };
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        } else self.gpa.free(key);
        gop.value_ptr.append(self.gpa, @intCast(idx)) catch return error.OutOfMemory;
    }
    t.row_idx = ri;
    return ri;
}

pub fn rowIndexFor(self: *Engine, t: *Table, col: usize) EngineError!*RowIndex {
    const ver = self.table_ver.get(t.name) orelse 0;
    if (t.row_idx) |ri| if (ri.col == col and ri.ver == ver) return ri;
    return self.buildRowIndex(t, col);
}

pub fn eqPredInfo(self: *Engine, t: *Table, where: ?*sql.Expr, alias: ?[]const u8) ?struct { col: usize, lit: *sql.Expr } {
    const w = where orelse return null;
    if (w.* != .binary) return null;
    const b = w.binary;
    if (b.op != .eq) return null;
    if (self.tableColOfAlias(t.name, b.lhs, alias)) |ci| if (costConstlike(b.rhs)) return .{ .col = ci, .lit = b.rhs };
    if (self.tableColOfAlias(t.name, b.rhs, alias)) |ci| if (costConstlike(b.lhs)) return .{ .col = ci, .lit = b.lhs };
    return null;
}

pub fn appendTableRow(self: *Engine, alloc: std.mem.Allocator, t: *Table, ri: usize, n_sys: usize, want_tableoid: bool, want_ctid: bool, want_cmin: bool, rows: *std.ArrayList([]Value), map: ?[]const usize, src_name: []const u8) EngineError!void {
    const base_row = try materializeRow(alloc, t, ri);
    var br: []Value = base_row;
    if (map) |m| {
        const rb = try alloc.alloc(Value, m.len);
        for (m, 0..) |ci, pi| rb[pi] = if (ci != std.math.maxInt(usize) and ci < base_row.len) base_row[ci] else .null;
        br = rb;
    }
    if (n_sys == 0) {
        try rows.append(alloc, br);
        const code = self.rowCompAt(t, ri);
        if (code != 0) self.row_comp_ptr.put(@intFromPtr(br.ptr), code) catch {};
        return;
    }
    const rr = try alloc.alloc(Value, br.len + n_sys);
    @memcpy(rr[0..br.len], br);
    var sx: usize = br.len;
    if (want_tableoid) {
        rr[sx] = .{ .text = stripSchema(src_name) };
        sx += 1;
    }
    if (want_ctid) {
        const num: u32 = if (ri < t.ctid_num.items.len and t.ctid_num.items[ri] != 0) t.ctid_num.items[ri] else @intCast(ri + 1);
        rr[sx] = .{ .text = try formatTid(alloc, .{ .block = 0, .off = @intCast(@min(num, 65535)) }) };
        sx += 1;
    }
    if (want_cmin) {
        const cv: u32 = if (ri < t.cmin.items.len) t.cmin.items[ri] else 0;
        rr[sx] = .{ .int = @intCast(cv) };
    }
    try rows.append(alloc, rr);
    const code = self.rowCompAt(t, ri);
    if (code != 0) self.row_comp_ptr.put(@intFromPtr(rr.ptr), code) catch {};
}

pub fn costNode(alloc: std.mem.Allocator, label: []const u8, c: CostEst) EngineError![]Value {
    const r: i64 = @intFromFloat(@round(@max(c.rows, 1.0)));
    return oneText(alloc, try std.fmt.allocPrint(alloc, "{s}  (cost={d:.2}..{d:.2} rows={d} width={d})", .{ label, c.startup, c.total, r, c.width }));
}

pub fn seqOff(self: *Engine) bool {
    const sv = self.settings.get("enable_seqscan") orelse return false;
    return std.ascii.eqlIgnoreCase(sv, "off") or std.mem.eql(u8, sv, "0") or std.ascii.eqlIgnoreCase(sv, "false");
}

pub fn explainCosts(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select) EngineError!Result {
    if (sel.extra_from.len > 0 or sel.more_joins.len > 0 or sel.union_all != null or sel.distinct or
        sel.order_by.len > 0 or sel.limit != null or sel.offset != null or sel.group_by.len > 0 or sel.having != null) return error.Unsupported;
    for (sel.items) |it| {
        if (isAggCall(exprName(it.expr)) and it.expr.* == .call) return error.Unsupported;
    }
    if (sel.join) |j| return self.explainJoinCosts(alloc, sel, j);
    const table = switch (sel.from orelse return error.Unsupported) {
        .table => |t| t,
        else => return error.Unsupported,
    };
    const t = self.find(table) orelse return error.TableNotFound;
    const plan = self.planScan(t, sel.where, null, self.seqOff());
    var lines = std.ArrayList([]Value).empty;
    if (plan.kind == .bitmap) {
        const ix = plan.idx.?;
        try lines.append(alloc, try costNode(alloc, try std.fmt.allocPrint(alloc, "Bitmap Heap Scan on {s}", .{table}), plan.cost));
        if (sel.where) |w| {
            const d = try self.deparseExpr(alloc, w, t.cols);
            try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Recheck Cond: ({s})", .{d})));
            const ci2 = self.costPredCol(t, sel.where, null).?;
            const ic = self.costBitmapIndex(t, ci2, sel.where, null);
            try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  ->  Bitmap Index Scan on {s}  (cost={d:.2}..{d:.2} rows={d} width=0)", .{ ix, ic.startup, ic.total, @as(i64, @intFromFloat(@round(ic.rows))) })));
            try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "        Index Cond: ({s})", .{d})));
        }
    } else if (plan.kind == .index) {
        const ix = plan.idx.?;
        try lines.append(alloc, try costNode(alloc, try std.fmt.allocPrint(alloc, "Index Scan using {s} on {s}", .{ ix, table }), plan.cost));
        if (sel.where) |w| {
            const d = try self.deparseExpr(alloc, w, t.cols);
            try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Index Cond: ({s})", .{d})));
        }
    } else {
        try lines.append(alloc, try costNode(alloc, try std.fmt.allocPrint(alloc, "Seq Scan on {s}", .{table}), plan.cost));
        if (sel.where) |w| {
            const d = try self.deparseExpr(alloc, w, t.cols);
            try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Filter: ({s})", .{d})));
        }
    }
    const cols = try alloc.alloc([]const u8, 1);
    cols[0] = "QUERY PLAN";
    return .{ .columns = cols, .rows = try lines.toOwnedSlice(alloc) };
}

pub fn joinChoice(self: *Engine, lt: *Table, rt: *Table, lsel: f64, rsel: f64, ndv: f64) JoinChoice {
    const nl: f64 = @floatFromInt(lt.rows.items.len);
    const nr: f64 = @floatFromInt(rt.rows.items.len);
    const rl = @max(nl * lsel, 1.0);
    const rr = @max(nr * rsel, 1.0);
    const out = @max(rl * rr / @max(ndv, 1.0), 1.0);
    const lc0 = self.costSeq(lt, null, null);
    const rc0 = self.costSeq(rt, null, null);
    const nl_total = lc0.total + rl * (rc0.total + rr * 0.0025);
    const hj_total = rc0.total + lc0.total + (rl + rr) * 0.0025 + out * 0.01;
    return .{ .nl_total = nl_total, .hj_total = hj_total, .out = out, .use_nl = nl_total < hj_total };
}

pub fn explainJoinCosts(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select, j: sql.Join) EngineError!Result {
    const lname = switch (sel.from orelse return error.Unsupported) {
        .table => |t| t,
        else => return error.Unsupported,
    };
    const lt = self.find(lname) orelse return error.TableNotFound;
    const rt = self.find(j.table) orelse return error.TableNotFound;
    const nl: f64 = @floatFromInt(lt.rows.items.len);
    const nr: f64 = @floatFromInt(rt.rows.items.len);
    const lsel = if (sel.where != null) self.whereSelectivityAlias(lname, sel.where, sel.alias) else 1.0;
    const rsel = if (sel.where != null) self.whereSelectivityAlias(j.table, sel.where, j.alias) else 1.0;
    const rl = @max(nl * lsel, 1.0);
    const rr = @max(nr * rsel, 1.0);
    var ndv: f64 = @max(@max(nl, nr) / 100.0, 1.0);
    var on_eq = false;
    if (j.on.* == .binary and j.on.binary.op == .eq) {
        on_eq = true;
        const lc = self.tableColOfAlias(lname, j.on.binary.lhs, sel.alias) orelse self.tableColOfAlias(lname, j.on.binary.rhs, sel.alias);
        const rc = self.tableColOfAlias(j.table, j.on.binary.lhs, j.alias) orelse self.tableColOfAlias(j.table, j.on.binary.rhs, j.alias);
        if (lc != null and rc != null) {
            _ = self.ensureColStatQuick(lt, lc.?);
            _ = self.ensureColStatQuick(rt, rc.?);
            const ln: f64 = if (lc.? < lt.stats.len and lt.stats[lc.?].ndv > 0) @floatFromInt(lt.stats[lc.?].ndv) else @max(nl / 100.0, 1.0);
            const rn: f64 = if (rc.? < rt.stats.len and rt.stats[rc.?].ndv > 0) @floatFromInt(rt.stats[rc.?].ndv) else @max(nr / 100.0, 1.0);
            ndv = @max(@min(ln, rn), 1.0);
        }
    }
    const jc = self.joinChoice(lt, rt, lsel, rsel, ndv);
    const out = jc.out;
    const lc0 = self.costSeq(lt, null, null);
    const rc0 = self.costSeq(rt, null, null);
    const nl_start: f64 = 0;
    const nl_total = jc.nl_total;
    const hj_start = rc0.total;
    const hj_total = jc.hj_total;
    const width: u32 = self.costWidth(lt) + self.costWidth(rt);
    const jt: i64 = @intFromFloat(@round(out));
    var lines = std.ArrayList([]Value).empty;
    const use_hash = on_eq and !jc.use_nl;
    if (use_hash) {
        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "Hash Join  (cost={d:.2}..{d:.2} rows={d} width={d})", .{ hj_start, hj_total, jt, width })));
        const cd = try self.deparseExpr(alloc, j.on, &.{});
        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Hash Cond: ({s})", .{cd})));
        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  ->  Seq Scan on {s}  (cost={d:.2}..{d:.2} rows={d} width={d})", .{ lname, lc0.startup, lc0.total, @as(i64, @intFromFloat(@round(rl))), self.costWidth(lt) })));
        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  ->  Hash  (cost={d:.2}..{d:.2} rows={d} width={d})", .{ rc0.total, rc0.total, @as(i64, @intFromFloat(@round(rr))), self.costWidth(rt) })));
        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "        ->  Seq Scan on {s}  (cost={d:.2}..{d:.2} rows={d} width={d})", .{ j.table, rc0.startup, rc0.total, @as(i64, @intFromFloat(@round(rr))), self.costWidth(rt) })));
    } else {
        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "Nested Loop  (cost={d:.2}..{d:.2} rows={d} width={d})", .{ nl_start, nl_total, jt, width })));
        const cd = try self.deparseExpr(alloc, j.on, &.{});
        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Join Filter: ({s})", .{cd})));
        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  ->  Seq Scan on {s}  (cost={d:.2}..{d:.2} rows={d} width={d})", .{ lname, lc0.startup, lc0.total, @as(i64, @intFromFloat(@round(rl))), self.costWidth(lt) })));
        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  ->  Seq Scan on {s}  (cost={d:.2}..{d:.2} rows={d} width={d})", .{ j.table, rc0.startup, rc0.total, @as(i64, @intFromFloat(@round(rr))), self.costWidth(rt) })));
    }
    const cols = try alloc.alloc([]const u8, 1);
    cols[0] = "QUERY PLAN";
    return .{ .columns = cols, .rows = try lines.toOwnedSlice(alloc) };
}

pub fn execExplain(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select, costs: bool) EngineError!Result {
    if (costs) {
        if (self.explainCosts(alloc, sel)) |r| return r else |e| {
            if (e != error.Unsupported) return e;
        }
    }
    return self.execExplainOff(alloc, sel);
}

pub fn execExplainOff(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select) EngineError!Result {
    if (sel.extra_from.len > 0) return self.explainFunctionCross(alloc, sel);
    const table = switch (sel.from orelse return error.SyntaxError) {
        .table => |t| t,
        else => return error.Unsupported,
    };
    const t = self.find(table) orelse return error.TableNotFound;
    var lines = std.ArrayList([]Value).empty;
    var is_agg = false;
    for (sel.items) |it| {
        if (it.expr.* == .call and std.ascii.eqlIgnoreCase(it.expr.call.name, "count")) is_agg = true;
    }
    if (!is_agg) {
        const seq_off = blk0: {
            const sv = self.settings.get("enable_seqscan") orelse break :blk0 false;
            break :blk0 std.ascii.eqlIgnoreCase(sv, "off") or std.mem.eql(u8, sv, "0") or std.ascii.eqlIgnoreCase(sv, "false");
        };
        if (sel.where) |w| {
            if (w.* == .binary and w.binary.lhs.* == .row and w.binary.rhs.* == .row and (w.binary.op == .lt or w.binary.op == .le or w.binary.op == .gt or w.binary.op == .ge)) {
                const b0 = w.binary;
                const lrow = b0.lhs.row;
                const rrow = b0.rhs.row;
                var idxname: ?[]const u8 = null;
                var keyn: usize = 0;
                var iit0 = self.index_names.iterator();
                while (iit0.next()) |ie| {
                    if (!std.ascii.eqlIgnoreCase(ie.value_ptr.*, table)) continue;
                    const m0 = self.index_meta.get(ie.key_ptr.*) orelse continue;
                    var k0: usize = 0;
                    var ok0 = true;
                    for (m0.cols) |mc| {
                        if (mc.include) continue;
                        if (k0 >= lrow.len) {
                            ok0 = false;
                            break;
                        }
                        const le = switch (lrow[k0].*) {
                            .column => |n| n,
                            .column_idx => |c| c.name,
                            else => "",
                        };
                        const leaf = if (std.mem.lastIndexOfScalar(u8, le, '.')) |d| le[d + 1 ..] else le;
                        if (leaf.len == 0 or !std.ascii.eqlIgnoreCase(leaf, mc.name)) {
                            ok0 = false;
                            break;
                        }
                        k0 += 1;
                    }
                    if (ok0 and k0 > 0 and k0 <= lrow.len) {
                        idxname = ie.key_ptr.*;
                        keyn = k0;
                        break;
                    }
                }
                if (idxname) |ix| {
                    const op0: []const u8 = switch (b0.op) {
                        .lt => if (keyn < lrow.len) "<=" else "<",
                        .le => "<=",
                        .gt => if (keyn < lrow.len) ">=" else ">",
                        .ge => ">=",
                        else => "",
                    };
                    var lb = std.ArrayList(u8).empty;
                    try lb.appendSlice(alloc, "ROW(");
                    for (lrow[0..keyn], 0..) |x, i| {
                        if (i > 0) try lb.appendSlice(alloc, ", ");
                        const le = switch (x.*) {
                            .column => |n| n,
                            .column_idx => |c| c.name,
                            else => "",
                        };
                        try lb.appendSlice(alloc, if (std.mem.lastIndexOfScalar(u8, le, '.')) |d| le[d + 1 ..] else le);
                    }
                    try lb.append(alloc, ')');
                    var rb = std.ArrayList(u8).empty;
                    try rb.appendSlice(alloc, "ROW(");
                    for (rrow[0..@min(keyn, rrow.len)], 0..) |x, i| {
                        if (i > 0) try rb.appendSlice(alloc, ", ");
                        try rb.appendSlice(alloc, try self.deparseExpr(alloc, x, t.cols));
                    }
                    try rb.append(alloc, ')');
                    const cond = try std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ lb.items, op0, rb.items });
                    const filt = try self.deparseExpr(alloc, w, t.cols);
                    if (sel.limit != null and seq_off) {
                        try lines.append(alloc, try oneText(alloc, "Limit"));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  ->  Index Only Scan using {s} on {s}", .{ ix, table })));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "        Index Cond: {s}", .{cond})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "        Filter: {s}", .{filt})));
                    } else {
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "Bitmap Heap Scan on {s}", .{table})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Filter: {s}", .{filt})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  ->  Bitmap Index Scan on {s}", .{ix})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "        Index Cond: {s}", .{cond})));
                    }
                    const c2 = try alloc.alloc([]const u8, 1);
                    c2[0] = "QUERY PLAN";
                    return .{ .columns = c2, .rows = try lines.toOwnedSlice(alloc) };
                }
            }
            if (w.* == .binary and w.binary.op == .and_op and seq_off) {
                var conj = std.ArrayList(*sql.Expr).empty;
                defer conj.deinit(alloc);
                var stack = std.ArrayList(*sql.Expr).empty;
                defer stack.deinit(alloc);
                try stack.append(alloc, w);
                while (stack.pop()) |x| {
                    if (x.* == .binary and x.binary.op == .and_op) {
                        try stack.append(alloc, x.binary.rhs);
                        try stack.append(alloc, x.binary.lhs);
                    } else try conj.append(alloc, x);
                }
                var iit1 = self.index_names.iterator();
                while (iit1.next()) |ie| {
                    if (!std.ascii.eqlIgnoreCase(ie.value_ptr.*, table)) continue;
                    const m1 = self.index_meta.get(ie.key_ptr.*) orelse continue;
                    var pieces = std.ArrayList([]const u8).empty;
                    defer pieces.deinit(alloc);
                    var all = true;
                    for (m1.cols) |mc| {
                        if (mc.include) continue;
                        var found: ?*sql.Expr = null;
                        for (conj.items) |cj| {
                            if (cj.* != .binary or cj.binary.op != .eq) continue;
                            const cj_l = cj.binary.lhs;
                            const cj_r = cj.binary.rhs;
                            const leafOf = struct {
                                fn f(x: *sql.Expr) ?[]const u8 {
                                    const nm = switch (x.*) {
                                        .column => |n| n,
                                        .column_idx => |c| c.name,
                                        else => return null,
                                    };
                                    return if (std.mem.lastIndexOfScalar(u8, nm, '.')) |d| nm[d + 1 ..] else nm;
                                }
                            }.f;
                            const lf = leafOf(cj_l);
                            const rf = leafOf(cj_r);
                            if ((lf != null and std.ascii.eqlIgnoreCase(lf.?, mc.name)) or (rf != null and std.ascii.eqlIgnoreCase(rf.?, mc.name))) {
                                found = cj;
                                break;
                            }
                        }
                        if (found == null) {
                            all = false;
                            break;
                        }
                        const cj = found.?;
                        var colx = cj.binary.lhs;
                        var valx = cj.binary.rhs;
                        const lf2 = switch (colx.*) {
                            .column => |n| n,
                            .column_idx => |c| c.name,
                            else => "",
                        };
                        const leafl2 = if (std.mem.lastIndexOfScalar(u8, lf2, '.')) |d| lf2[d + 1 ..] else lf2;
                        if (!std.ascii.eqlIgnoreCase(leafl2, mc.name)) {
                            const tx = colx;
                            colx = valx;
                            valx = tx;
                        }
                        const ctype = if (findColSlice(t.cols, mc.name)) |ci3| t.cols[ci3].type_name else "";
                        const vtxt = switch (valx.*) {
                            .int => |v| try std.fmt.allocPrint(alloc, "{d}", .{v}),
                            .float => |v| try std.fmt.allocPrint(alloc, "{d}", .{v}),
                            .string => |v| if (std.ascii.eqlIgnoreCase(ctype, "name")) try std.fmt.allocPrint(alloc, "'{s}'::name", .{v}) else if (std.ascii.eqlIgnoreCase(ctype, "text")) try std.fmt.allocPrint(alloc, "'{s}'::text", .{v}) else try std.fmt.allocPrint(alloc, "'{s}'", .{v}),
                            else => "",
                        };
                        try pieces.append(alloc, try std.fmt.allocPrint(alloc, "({s} = {s})", .{ mc.name, vtxt }));
                    }
                    if (!all or pieces.items.len == 0) continue;
                    var covered = true;
                    for (sel.items) |it| {
                        const nm = switch (it.expr.*) {
                            .column => |n| n,
                            .column_idx => |c| c.name,
                            else => return error.Unsupported,
                        };
                        const leaf = if (std.mem.lastIndexOfScalar(u8, nm, '.')) |d| nm[d + 1 ..] else nm;
                        var inidx = false;
                        for (m1.cols) |mc| if (std.ascii.eqlIgnoreCase(mc.name, leaf)) {
                            inidx = true;
                            break;
                        };
                        if (!inidx) {
                            covered = false;
                            break;
                        }
                    }
                    if (!covered) continue;
                    var cb = std.ArrayList(u8).empty;
                    if (pieces.items.len > 1) try cb.append(alloc, '(');
                    for (pieces.items, 0..) |pc, i| {
                        if (i > 0) try cb.appendSlice(alloc, " AND ");
                        try cb.appendSlice(alloc, pc);
                    }
                    if (pieces.items.len > 1) try cb.append(alloc, ')');
                    try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "Index Only Scan using {s} on {s}", .{ ie.key_ptr.*, table })));
                    try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Index Cond: {s}", .{cb.items})));
                    const c2 = try alloc.alloc([]const u8, 1);
                    c2[0] = "QUERY PLAN";
                    return .{ .columns = c2, .rows = try lines.toOwnedSlice(alloc) };
                }
            }
            if (w.* == .binary and (w.binary.op == .contains or w.binary.op == .subcontains)) {
                var cname: []const u8 = "";
                const lhs = w.binary.lhs;
                if (lhs.* == .column) cname = if (std.mem.lastIndexOfScalar(u8, lhs.column, '.')) |d| lhs.column[d + 1 ..] else lhs.column else if (lhs.* == .column_idx) cname = if (std.mem.lastIndexOfScalar(u8, lhs.column_idx.name, '.')) |d| lhs.column_idx.name[d + 1 ..] else lhs.column_idx.name;
                const rv = self.eval(alloc, w.binary.rhs, null, &.{}, null) catch Value.null;
                if (cname.len > 0 and rv == .text) {
                    var iname: ?[]const u8 = null;
                    var iit = self.index_names.iterator();
                    while (iit.next()) |e| {
                        if (!std.ascii.eqlIgnoreCase(e.value_ptr.*, table)) continue;
                        if (self.index_meta.get(e.key_ptr.*)) |m| {
                            if (std.ascii.eqlIgnoreCase(m.am, "gist")) {
                                iname = e.key_ptr.*;
                                break;
                            }
                        }
                    }
                    if (iname) |ix| {
                        const op = if (w.binary.op == .contains) "<@" else "@>";
                        const cond = try std.fmt.allocPrint(alloc, "({s} {s} '{s}'::box)", .{ cname, op, rv.text });
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "Index Only Scan using {s} on {s}", .{ ix, table })));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Index Cond: {s}", .{cond})));
                        const c2 = try alloc.alloc([]const u8, 1);
                        c2[0] = "QUERY PLAN";
                        return .{ .columns = c2, .rows = try lines.toOwnedSlice(alloc) };
                    }
                }
            }
            if (w.* == .binary and w.binary.op == .eq) {
                var colname: ?[]const u8 = null;
                var lit: ?[]const u8 = null;
                const lhs = w.binary.lhs;
                const rhs = w.binary.rhs;
                if ((lhs.* == .column or lhs.* == .column_idx) and rhs.* == .string) {
                    colname = if (lhs.* == .column) lhs.column else lhs.column_idx.name;
                    lit = rhs.string;
                } else if ((rhs.* == .column or rhs.* == .column_idx) and lhs.* == .string) {
                    colname = if (rhs.* == .column) rhs.column else rhs.column_idx.name;
                    lit = lhs.string;
                }
                if (colname != null and lit != null) {
                    var tbuf: [256]u8 = undefined;
                    const tlow = std.ascii.lowerString(tbuf[0..@min(table.len, tbuf.len)], table[0..@min(table.len, tbuf.len)]);
                    var idx_name: ?[]const u8 = null;
                    var iit = self.index_names.iterator();
                    while (iit.next()) |e| {
                        if (std.ascii.eqlIgnoreCase(e.value_ptr.*, tlow)) {
                            idx_name = e.key_ptr.*;
                            break;
                        }
                    }
                    if (idx_name) |iname| {
                        const ci = findColSlice(t.cols, colname.?) orelse 0;
                        const texty = ci < t.cols.len and t.cols[ci].ty == .text;
                        const cond = if (texty) try std.fmt.allocPrint(alloc, "(({s})::text = '{s}'::text)", .{ colname.?, lit.? }) else try std.fmt.allocPrint(alloc, "({s} = '{s}')", .{ colname.?, lit.? });
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "Bitmap Heap Scan on {s}", .{table})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Recheck Cond: {s}", .{cond})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  ->  Bitmap Index Scan on {s}", .{iname})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "        Index Cond: {s}", .{cond})));
                        const c2 = try alloc.alloc([]const u8, 1);
                        c2[0] = "QUERY PLAN";
                        return .{ .columns = c2, .rows = try lines.toOwnedSlice(alloc) };
                    }
                }
            }
        }
    }
    if (!is_agg) if (sel.where) |w| {
        if (w.* == .binary and w.binary.op == .eq) {
            var colname: ?[]const u8 = null;
            var iv: i64 = 0;
            const lhs = w.binary.lhs;
            const rhs = w.binary.rhs;
            if ((lhs.* == .column or lhs.* == .column_idx) and rhs.* == .int) {
                colname = if (lhs.* == .column) lhs.column else lhs.column_idx.name;
                iv = rhs.int;
            } else if ((rhs.* == .column or rhs.* == .column_idx) and lhs.* == .int) {
                colname = if (rhs.* == .column) rhs.column else rhs.column_idx.name;
                iv = lhs.int;
            }
            if (colname) |cn0| {
                const cn = if (std.mem.lastIndexOfScalar(u8, cn0, '.')) |d| cn0[d + 1 ..] else cn0;
                var iname: ?[]const u8 = null;
                var iit2 = self.index_names.iterator();
                while (iit2.next()) |ie| {
                    if (!std.ascii.eqlIgnoreCase(ie.value_ptr.*, table)) continue;
                    const m2 = self.index_meta.get(ie.key_ptr.*) orelse continue;
                    if (!std.ascii.eqlIgnoreCase(m2.am, "brin")) continue;
                    for (m2.cols) |mc| if (std.ascii.eqlIgnoreCase(mc.name, cn)) {
                        iname = ie.key_ptr.*;
                        break;
                    };
                    if (iname != null) break;
                }
                if (iname) |ix| {
                    const ci0 = findColSlice(t.cols, cn) orelse 0;
                    var mono = true;
                    var prev: ?i64 = null;
                    for (t.rows.items, 0..) |_, ri| {
                        if (isRowDeleted(t, ri)) continue;
                        const mr = try materializeRow(alloc, t, ri);
                        if (ci0 >= mr.len or mr[ci0] != .int) continue;
                        if (prev) |pv| if (mr[ci0].int < pv) {
                            mono = false;
                            break;
                        };
                        prev = mr[ci0].int;
                    }
                    const cond = try std.fmt.allocPrint(alloc, "({s} = {d})", .{ cn, iv });
                    if (mono) {
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "Bitmap Heap Scan on {s}", .{table})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Recheck Cond: {s}", .{cond})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  ->  Bitmap Index Scan on {s}", .{ix})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "        Index Cond: {s}", .{cond})));
                    } else {
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "Seq Scan on {s}", .{table})));
                        try lines.append(alloc, try oneText(alloc, try std.fmt.allocPrint(alloc, "  Filter: {s}", .{cond})));
                    }
                    const c3 = try alloc.alloc([]const u8, 1);
                    c3[0] = "QUERY PLAN";
                    return .{ .columns = c3, .rows = try lines.toOwnedSlice(alloc) };
                }
            }
        }
    };
    if (is_agg) try lines.append(alloc, try oneText(alloc, "Aggregate"));
    const scan = try std.fmt.allocPrint(alloc, "  ->  Seq Scan on {s}", .{table});
    try lines.append(alloc, try oneText(alloc, scan));
    if (sel.where) |w| {
        const d = try self.deparseExpr(alloc, w, t.cols);
        const fl = try std.fmt.allocPrint(alloc, "        Filter: {s}", .{d});
        try lines.append(alloc, try oneText(alloc, fl));
    }
    const cols = try alloc.alloc([]const u8, 1);
    cols[0] = "QUERY PLAN";
    return .{ .columns = cols, .rows = try lines.toOwnedSlice(alloc) };
}
