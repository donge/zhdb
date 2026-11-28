const std = @import("std");
const engine_mod = @import("../engine.zig");
const sql = @import("../sql.zig");
const Value = engine_mod.Value;
const Column = engine_mod.Column;
const Table = engine_mod.Table;
const ColType = engine_mod.ColType;
const EngineError = engine_mod.EngineError;
const formatValue = engine_mod.formatValue;
const fmtKey = engine_mod.fmtKey;
const isAggName = engine_mod.isAggName;
const setDiag = engine_mod.setDiag;

pub fn findCol(t: *Table, name: []const u8) ?usize {
    return findColSlice(t.cols, name);
}

pub fn findColSlice(cols: []Column, name: []const u8) ?usize {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    for (cols, 0..) |c, i| {
        if (dot) |d| {
            const q = name[0..d];
            const base = name[d + 1 ..];
            if ((c.source.len > 0 and std.ascii.eqlIgnoreCase(c.source, q)) or
                (c.table_name.len > 0 and std.ascii.eqlIgnoreCase(c.table_name, q)))
            {
                if (std.ascii.eqlIgnoreCase(c.name, base)) return i;
            }
            continue;
        }
        if (columnMatches(c.name, name)) return i;
    }
    if (dot) |d| {
        const base = name[d + 1 ..];
        var found: ?usize = null;
        for (cols, 0..) |c, i| {
            if (std.ascii.eqlIgnoreCase(c.name, base)) {
                if (found != null) return null;
                found = i;
            }
        }
        return found;
    }
    return null;
}

pub fn columnMatches(col: []const u8, ref: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(col, ref)) return true;
    if (std.mem.lastIndexOfScalar(u8, ref, '.')) |dot| {
        return std.ascii.eqlIgnoreCase(col, ref[dot + 1 ..]);
    }
    return false;
}

pub fn baseColName(n: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, n, '.')) |d| n[d + 1 ..] else n;
}

pub fn colName(e: *sql.Expr) ?[]const u8 {
    return switch (e.*) {
        .column => |n| n,
        .column_idx => |c| c.name,
        else => null,
    };
}

pub fn keyHash(v: Value) u64 {
    return switch (v) {
        .int => |i| std.hash.Wyhash.hash(0, std.mem.asBytes(&i)),
        .uint => |i| std.hash.Wyhash.hash(6, std.mem.asBytes(&i)),
        .float => |f| std.hash.Wyhash.hash(1, std.mem.asBytes(&f)),
        .text => |t| std.hash.Wyhash.hash(2, t),
        .boolean => |b| if (b) 3 else 4,
        .null => 5,
    };
}

pub fn appendKey(alloc: std.mem.Allocator, key: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .null => try key.appendSlice(alloc, "N"),
        .int => |i| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, i, .little);
            try key.append(alloc, 'I');
            try key.appendSlice(alloc, &buf);
        },
        .uint => |i| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, i, .little);
            try key.append(alloc, 'U');
            try key.appendSlice(alloc, &buf);
        },
        .float => |f| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @bitCast(f), .little);
            try key.append(alloc, 'F');
            try key.appendSlice(alloc, &buf);
        },
        .boolean => |b| try key.appendSlice(alloc, if (b) "T" else "B"),
        .text => |s| {
            try key.append(alloc, 'S');
            try key.appendSlice(alloc, s);
        },
    }
    try key.append(alloc, 0x1f);
}

pub fn keyCol(t: *Table, e: *sql.Expr) ?usize {
    return switch (e.*) {
        .column => |n| blk: {
            for (t.cols, 0..) |c, i| {
                if (columnMatches(c.name, n)) break :blk i;
            }
            break :blk null;
        },
        .column_idx => |c| c.idx,
        else => null,
    };
}

pub fn typeName(ty: ColType) []const u8 {
    return switch (ty) {
        .int => "int",
        .boolean => "boolean",
        .float => "double",
        .text, .date, .timestamp => "text",
    };
}

pub fn tableIsNull(t: *const Table, ci: usize, ri: usize) bool {
    if (t.nulls.len <= ci) return false;
    const bits = t.nulls[ci] orelse return false;
    if (ri / 8 >= bits.len) return false;
    return (bits[ri / 8] >> @intCast(ri % 8)) & 1 == 0;
}

pub fn tableSetNull(a: std.mem.Allocator, t: *Table, ci: usize, ri: usize, is_null: bool) !void {
    if (t.nulls.len <= ci) return;
    if (t.nulls[ci] == null) {
        if (!is_null) return;
        const bits = try a.alloc(u8, @max((t.rows.items.len + 7) / 8, ri / 8 + 1));
        @memset(bits, 0xff);
        t.nulls[ci] = bits;
    } else if (is_null and ri / 8 >= t.nulls[ci].?.len) {
        const old = t.nulls[ci].?;
        const nw = ri / 8 + 1;
        const grown = try a.alloc(u8, nw);
        @memset(grown, 0xff);
        @memcpy(grown[0..old.len], old);
        a.free(old);
        t.nulls[ci] = grown;
    }
    const bits = t.nulls[ci].?;
    if (is_null) {
        bits[ri / 8] &= ~(@as(u8, 1) << @intCast(ri % 8));
    } else {
        bits[ri / 8] |= @as(u8, 1) << @intCast(ri % 8);
    }
}

pub fn storedSentinel(ty: ColType) Value {
    return switch (ty) {
        .float => .{ .float = 0 },
        .text, .date, .timestamp => .{ .text = "" },
        else => .{ .int = 0 },
    };
}

pub fn materializeRow(alloc: std.mem.Allocator, t: *const Table, ri: usize) ![]Value {
    const row = try alloc.alloc(Value, t.cols.len);
    @memcpy(row, t.rows.items[ri]);
    var ci: usize = 0;
    while (ci < t.cols.len) : (ci += 1) {
        if (tableIsNull(t, ci, ri)) {
            row[ci] = .null;
            continue;
        }
        if (t.cols[ci].is_numeric and row[ci] == .float) {
            const f = row[ci].float;
            if (f == @trunc(f) and @abs(f) < 9.0e18) row[ci] = .{ .int = @intFromFloat(f) };
        }
    }
    return row;
}

pub fn ctIdOf(t: *const Table, ri: usize) u32 {
    if (ri < t.ctid.items.len) return t.ctid.items[ri];
    return @intCast(ri);
}

pub fn ensureVersionArrays(gpa: std.mem.Allocator, t: *Table) !void {
    const n = t.rows.items.len;
    if (t.ctid.items.len < n) {
        const old = t.ctid.items.len;
        try t.ctid.resize(gpa, n);
        var i = old;
        while (i < n) : (i += 1) t.ctid.items[i] = @intCast(i);
    }
    if (t.xmin.items.len < n) {
        const old = t.xmin.items.len;
        try t.xmin.resize(gpa, n);
        @memset(t.xmin.items[old..], 0);
    }
    if (t.xmax.items.len < n) {
        const old = t.xmax.items.len;
        try t.xmax.resize(gpa, n);
        @memset(t.xmax.items[old..], 0);
    }
    if (t.cmin.items.len < n) {
        const old = t.cmin.items.len;
        try t.cmin.resize(gpa, n);
        @memset(t.cmin.items[old..], 0);
    }
    if (t.ctid_num.items.len < n) {
        const old = t.ctid_num.items.len;
        try t.ctid_num.resize(gpa, n);
        var i = old;
        while (i < n) : (i += 1) {
            t.ctid_num.items[i] = t.next_ctid_num;
            t.next_ctid_num +%= 1;
        }
    }
}

pub fn appendStoredRow(gpa: std.mem.Allocator, t: *Table, vals: []const Value) !usize {
    const row = try gpa.alloc(Value, t.cols.len);
    errdefer gpa.free(row);
    var ci: usize = 0;
    while (ci < t.cols.len) : (ci += 1) {
        const v: Value = if (ci < vals.len) vals[ci] else defaultValue(t.cols[ci].ty);
        row[ci] = if (v == .null) storedSentinel(t.cols[ci].ty) else v;
    }
    const ri = t.rows.items.len;
    if (t.xmin.items.len < ri) {
        const old = t.xmin.items.len;
        try t.xmin.resize(gpa, ri);
        @memset(t.xmin.items[old..], 0);
    }
    if (t.xmax.items.len < ri) {
        const old = t.xmax.items.len;
        try t.xmax.resize(gpa, ri);
        @memset(t.xmax.items[old..], 0);
    }
    try t.rows.append(gpa, row);
    try t.xmin.append(gpa, 0);
    try t.xmax.append(gpa, 0);
    try t.cmin.append(gpa, 0);
    try t.ctid_num.append(gpa, 0);
    ci = 0;
    while (ci < t.cols.len) : (ci += 1) {
        if (ci < vals.len and vals[ci] == .null) {
            if (std.c.getenv("ZHDB_DBG_NULL") != null) std.debug.print("[null] {s} col={d} ri={d}\n", .{ t.name, ci, ri });
            try tableSetNull(gpa, t, ci, ri, true);
        }
    }
    return ri;
}

pub fn cellValueFromRow(t: *Table, ci: usize, ri: usize) Value {
    if (tableIsNull(t, ci, ri)) return .null;
    if (ri < t.rows.items.len) {
        const v = t.rows.items[ri][ci];
        if (v == .null) return .null;
        return v;
    }
    return .null;
}

pub fn isRowDeleted(t: *const Table, ri: usize) bool {
    return ri < t.deleted.items.len and t.deleted.items[ri] != 0;
}

pub fn exprName(e: *sql.Expr) []const u8 {
    if (e.* == .call and std.ascii.eqlIgnoreCase(e.call.name, "__alias") and e.call.args.len == 2 and e.call.args[1].* == .string)
        return e.call.args[1].string;
    return switch (e.*) {
        .column => |c| blk: {
            if (std.mem.lastIndexOfScalar(u8, c, '.')) |d| break :blk c[d + 1 ..];
            break :blk c;
        },
        .column_idx => |c| blk: {
            if (std.mem.lastIndexOfScalar(u8, c.name, '.')) |d| break :blk c.name[d + 1 ..];
            break :blk c.name;
        },
        .call => |c| blk: {
            if (std.mem.startsWith(u8, c.name, "__")) break :blk "?column?";
            if (std.mem.lastIndexOfScalar(u8, c.name, '.')) |d| break :blk c.name[d + 1 ..];
            break :blk c.name;
        },
        .case_expr => "case",
        .cast => |c| blk: {
            switch (c.operand.*) {
                .column => |n| {
                    if (std.mem.lastIndexOfScalar(u8, n, '.')) |d| break :blk n[d + 1 ..];
                    break :blk n;
                },
                .column_idx => |ci| {
                    if (std.mem.lastIndexOfScalar(u8, ci.name, '.')) |d| break :blk ci.name[d + 1 ..];
                    break :blk ci.name;
                },
                .call => |cc| break :blk cc.name,
                else => {},
            }
            var t = c.type_name;
            if (t.len > 0 and t[0] == '"') {
                t = t[1..];
                if (std.mem.indexOfScalar(u8, t, '"')) |q| t = t[0..q];
            }
            if (std.mem.indexOfScalar(u8, t, ' ')) |sp| t = t[0..sp];
            if (std.ascii.eqlIgnoreCase(t, "boolean")) break :blk "bool";
            break :blk t;
        },
        else => "?column?",
    };
}

pub fn anyAggregate(items: []sql.SelectItem) bool {
    for (items) |it| {
        if (exprHasAgg(it.expr)) return true;
    }
    return false;
}

pub fn exprHasAgg(e: *sql.Expr) bool {
    return switch (e.*) {
        .call => |c| blk: {
            if (isAggName(c.name)) break :blk true;
            for (c.args) |a| if (exprHasAgg(a)) break :blk true;
            break :blk false;
        },
        .binary => |b| exprHasAgg(b.lhs) or exprHasAgg(b.rhs),
        .negate => |x| exprHasAgg(x),
        .not => |x| exprHasAgg(x),
        .is_null => |x| exprHasAgg(x.operand),
        .like => |x| exprHasAgg(x.operand) or exprHasAgg(x.pattern),
        .in_list => |x| exprHasAgg(x.operand),
        .between => |x| exprHasAgg(x.operand),
        .cast => |x| exprHasAgg(x.operand),
        .case_expr => |c| blk: {
            for (c.whens) |w| {
                if (exprHasAgg(w.cond) or exprHasAgg(w.then)) break :blk true;
            }
            if (c.else_expr) |el| break :blk exprHasAgg(el);
            break :blk false;
        },
        else => false,
    };
}

pub fn isAggCall(name: []const u8) bool {
    const aggs = [_][]const u8{ "sum", "count", "avg", "min", "max", "bool_and", "bool_or", "every", "string_agg", "array_agg", "json_agg", "jsonb_agg", "stddev", "stddev_pop", "stddev_samp", "variance", "var_pop", "var_samp" };
    for (aggs) |a| if (std.ascii.eqlIgnoreCase(name, a)) return true;
    return false;
}

pub fn referencesQualifier(e: *sql.Expr, table: []const u8, alias: []const u8) bool {
    switch (e.*) {
        .column => |n| {
            if (std.mem.lastIndexOfScalar(u8, n, '.')) |d| {
                const q = n[0..d];
                if (std.ascii.eqlIgnoreCase(q, table) and !std.ascii.eqlIgnoreCase(q, alias)) return true;
            }
            return false;
        },
        .column_idx => |c| {
            if (std.mem.lastIndexOfScalar(u8, c.name, '.')) |d| {
                const q = c.name[0..d];
                if (std.ascii.eqlIgnoreCase(q, table) and !std.ascii.eqlIgnoreCase(q, alias)) return true;
            }
            return false;
        },
        .call => |c| {
            for (c.args) |a| if (referencesQualifier(a, table, alias)) return true;
            return false;
        },
        .binary => |b| return referencesQualifier(b.lhs, table, alias) or referencesQualifier(b.rhs, table, alias),
        .negate, .not, .bitnot => |x| return referencesQualifier(x, table, alias),
        .subscript => |x| return referencesQualifier(x.operand, table, alias) or referencesQualifier(x.index, table, alias),
        .is_null => |x| return referencesQualifier(x.operand, table, alias),
        .cast => |x| return referencesQualifier(x.operand, table, alias),
        .in_list => |x| {
            if (referencesQualifier(x.operand, table, alias)) return true;
            for (x.items) |it| if (referencesQualifier(it, table, alias)) return true;
            return false;
        },
        .between => |x| return referencesQualifier(x.operand, table, alias) or referencesQualifier(x.low, table, alias) or referencesQualifier(x.high, table, alias),
        .like => |x| return referencesQualifier(x.operand, table, alias) or referencesQualifier(x.pattern, table, alias),
        .case_expr => |x| {
            for (x.whens) |w| if (referencesQualifier(w.cond, table, alias) or referencesQualifier(w.then, table, alias)) return true;
            if (x.else_expr) |el| return referencesQualifier(el, table, alias);
            return false;
        },
        else => return false,
    }
}

pub fn rejectBareColumns(e: *sql.Expr, cols: []Column) EngineError!void {
    switch (e.*) {
        .column => |n| {
            const i = findColSlice(cols, n);
            const src = if (i) |idx| cols[idx].source else "";
            const base = if (std.mem.lastIndexOfScalar(u8, n, '.')) |d| n[d + 1 ..] else n;
            if (src.len > 0) setDiag("column \"{s}.{s}\" must appear in the GROUP BY clause or be used in an aggregate function", .{ src, base }) else setDiag("column \"{s}\" must appear in the GROUP BY clause or be used in an aggregate function", .{base});
            return error.UngroupedColumn;
        },
        .column_idx => |c| {
            const i = if (c.idx < cols.len) @as(?usize, c.idx) else null;
            const src = if (i) |idx| cols[idx].source else "";
            const base = if (std.mem.lastIndexOfScalar(u8, c.name, '.')) |d| c.name[d + 1 ..] else c.name;
            if (src.len > 0) setDiag("column \"{s}.{s}\" must appear in the GROUP BY clause or be used in an aggregate function", .{ src, base }) else setDiag("column \"{s}\" must appear in the GROUP BY clause or be used in an aggregate function", .{base});
            return error.UngroupedColumn;
        },
        .call => |c| {
            if (isAggName(c.name)) return;
            for (c.args) |a| try rejectBareColumns(a, cols);
        },
        .binary => |b| {
            try rejectBareColumns(b.lhs, cols);
            try rejectBareColumns(b.rhs, cols);
        },
        .negate, .not, .bitnot => |x| try rejectBareColumns(x, cols),
        .subscript => |x| {
            try rejectBareColumns(x.operand, cols);
            try rejectBareColumns(x.index, cols);
        },
        .is_null => |x| try rejectBareColumns(x.operand, cols),
        .cast => |x| try rejectBareColumns(x.operand, cols),
        .in_list => |x| {
            try rejectBareColumns(x.operand, cols);
            for (x.items) |it| try rejectBareColumns(it, cols);
        },
        .between => |x| {
            try rejectBareColumns(x.operand, cols);
            try rejectBareColumns(x.low, cols);
            try rejectBareColumns(x.high, cols);
        },
        .like => |x| {
            try rejectBareColumns(x.operand, cols);
            try rejectBareColumns(x.pattern, cols);
        },
        .case_expr => |x| {
            for (x.whens) |w| {
                try rejectBareColumns(w.cond, cols);
                try rejectBareColumns(w.then, cols);
            }
            if (x.else_expr) |el| try rejectBareColumns(el, cols);
        },
        else => {},
    }
}

pub fn defaultValue(ty: ColType) Value {
    return switch (ty) {
        .int => .{ .int = 0 },
        .float => .{ .float = 0 },
        .text, .date, .timestamp => .{ .text = "" },
        .boolean => .{ .boolean = false },
    };
}
