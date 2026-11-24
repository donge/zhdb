const std = @import("std");
const sql = @import("sql.zig");
pub const columnar = @import("columnar.zig");
pub const Value = @import("value.zig").Value;
const regex_mod = @import("regex.zig");
const wal_mod = @import("wal.zig");
const lockmgr = @import("lockmgr.zig");
const btree = @import("btree.zig");

pub const ColType = enum { int, float, text, boolean, date, timestamp };

pub fn mapType(name: []const u8) ColType {
    var buf: [64]u8 = undefined;
    const n = @min(name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], name[0..n]);
    if (std.mem.startsWith(u8, lower, "lowcardinality") or
        std.mem.startsWith(u8, lower, "nullable") or
        std.mem.startsWith(u8, lower, "string") or
        std.mem.startsWith(u8, lower, "text") or
        std.mem.startsWith(u8, lower, "varchar") or
        std.mem.startsWith(u8, lower, "char") or
        std.mem.startsWith(u8, lower, "uuid") or
        std.mem.startsWith(u8, lower, "json")) return .text;
    if (std.mem.startsWith(u8, lower, "float") or std.mem.startsWith(u8, lower, "double") or
        std.mem.startsWith(u8, lower, "real") or std.mem.startsWith(u8, lower, "decimal") or
        std.mem.startsWith(u8, lower, "numeric")) return .float;
    if (std.mem.startsWith(u8, lower, "bool")) return .boolean;
    if (std.mem.startsWith(u8, lower, "\"char\"")) return .text;
    if (std.mem.startsWith(u8, lower, "date") and !std.mem.startsWith(u8, lower, "datetime")) return .date;
    if (std.mem.startsWith(u8, lower, "datetime") or std.mem.startsWith(u8, lower, "timestamp")) return .timestamp;
    // PostgreSQL types used by the official regression fixtures. The engine
    // does not implement them natively yet, but storing their text form lets
    // test_setup create and populate the shared tables.
    if (std.mem.startsWith(u8, lower, "name") or std.mem.startsWith(u8, lower, "bytea") or
        std.mem.startsWith(u8, lower, "point") or std.mem.startsWith(u8, lower, "path") or
        std.mem.startsWith(u8, lower, "line") or std.mem.startsWith(u8, lower, "lseg") or
        std.mem.startsWith(u8, lower, "box") or std.mem.startsWith(u8, lower, "polygon") or
        std.mem.startsWith(u8, lower, "circle") or std.mem.startsWith(u8, lower, "inet") or
        std.mem.startsWith(u8, lower, "cidr") or std.mem.startsWith(u8, lower, "macaddr") or
        std.mem.startsWith(u8, lower, "bit") or std.mem.startsWith(u8, lower, "money") or
        std.mem.startsWith(u8, lower, "interval") or std.mem.startsWith(u8, lower, "timetz") or
        std.mem.startsWith(u8, lower, "time")) return .text;
    return .int;
}

pub const Column = struct {
    name: []const u8,
    ty: ColType,
    /// Qualifier used by `table.column` / `table.*` resolution.
    source: []const u8 = "",
    /// char(n)/varchar(n) length limit; 0 means unbounded.
    max_len: u16 = 0,
    /// CHAR(n) pads values with spaces; VARCHAR(n) does not.
    pad_char: bool = false,
    /// PostgreSQL `oid`: unsigned 32-bit stored in the i64 payload.
    is_oid: bool = false,
    /// Explicit int2/int4/int8 width (0 = generic int column).
    int_bits: u8 = 0,
    /// SERIAL column: fill omitted values from the table counter.
    serial: bool = false,
    /// PostgreSQL macaddr stored as canonical text.
    is_macaddr: bool = false,
    /// PostgreSQL lseg stored as canonical text.
    is_lseg: bool = false,
    /// PostgreSQL path stored as canonical text.
    is_path: bool = false,
    /// Numeric/arbitrary precision input (affects float→int rounding).
    is_numeric: bool = false,
};

/// ClickHouse's type names imply a zero/empty default for omitted INSERT
/// columns; PostgreSQL's do not.
fn isClickHouseTypeName(name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n = @min(name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], name[0..n]);
    return std.mem.startsWith(u8, lower, "uint") or
        std.mem.startsWith(u8, lower, "int8") or
        std.mem.startsWith(u8, lower, "int16") or
        std.mem.startsWith(u8, lower, "int32") or
        std.mem.startsWith(u8, lower, "int64") or
        std.mem.startsWith(u8, lower, "float32") or
        std.mem.startsWith(u8, lower, "float64") or
        std.mem.startsWith(u8, lower, "string");
}

pub const ColumnDef = sql.ColumnDef;

pub const McvEntry = struct { v: i64, freq: f64 };
pub const McvStr = struct { s: []u8, freq: f64 };
pub const NgramStat = struct { g: [3]u8, freq: f64 };
pub const DictEntry = struct { s: []u8, count: u32 };
pub const SuffixStat = struct { s: [3]u8 = @splat(0), len: u8 = 0, freq: f64 = 0 };
const GramCount = struct { g: u32, c: u32 };
/// One observed `OR` pair: the two predicate trees (cloned into the table arena
/// and bound to column indexes) plus the sampled counts A, B and A∧B.
/// A resolved `IN (SELECT ...)` inside an OR pair: the node in the stored
/// predicate tree plus its membership set (keys owned by the table arena).
pub const OrSubSet = struct {
    node: *sql.Expr,
    set: std.StringHashMap(void),
    has_null: bool,
    /// Correlated membership: bound outer key expressions (empty when
    /// uncorrelated). The set is keyed by `<key parts>\x1f<value>`.
    keys: []*sql.Expr = &.{},
    /// Range correlation `inner.k OP outer.k`: per value, the extreme inner key
    /// (max for `ge`/`gt`, min for `le`/`lt`); membership is a bound comparison.
    range_map: ?*std.StringHashMap(RangeBound) = null,
    range_keys: [2]?*sql.Expr = @splat(null),
    range_ops: [2]sql.BinOp = @splat(.ge),
    range_n: u8 = 0,
};

/// Exact per-value row counts for a float column (cached per table+column).
pub const FloatCountEntry = struct { map: std.AutoHashMap(i64, u32) };

pub const OrReq = struct {
    a: *sql.Expr,
    b: *sql.Expr,
    /// Structural hashes of the two sides (subqueries included), used as the
    /// cache key across statements.
    ha: u64 = 0,
    hb: u64 = 0,
    a_cnt: u32 = 0,
    b_cnt: u32 = 0,
    both: u32 = 0,
    sampled: u32 = 0,
    done: bool = false,
    /// Estimated resident size of this entry (predicate trees + subquery sets),
    /// used by the memory-bounded LRU cache.
    bytes: usize = 0,
    /// LRU stamp (engine-global monotonic tick at last use).
    stamp: u64 = 0,
    subs: std.ArrayList(OrSubSet) = .empty,
    /// Combined per-table version the counts/sets were measured at; stale when
    /// any of `tables` (the pair table + subquery sources) changes.
    ver: u64 = 0,
    /// Tables whose versions the counts depend on (arena-owned names).
    tables: [][]const u8 = &.{},
    /// Arena holding the membership-set keys, so a refresh can reset them.
    sub_arena: ?*std.heap.ArenaAllocator = null,
    /// Arena holding this entry's cloned predicate trees (freed on eviction, so
    /// evicting an entry really releases its memory).
    pred_arena: ?*std.heap.ArenaAllocator = null,
};

/// One explicit key value with an absolute estimated row count.
pub const KeyCnt = struct { v: i64, c: f64 };
/// A `(table, column)` whose key is known equal to a KeyDist's key.
pub const KeyMember = struct { t: []const u8, c: usize };

/// Qualifier -> temp-column mapping carried through a join chain, so predicates
/// like `d.j` resolve to the right side even when several inputs share a column
/// name (self-joins / same-named columns across tables).
pub const ChainQual = struct { qual: []const u8, col: usize };

fn chainQualCol(t: *Table, quals: []const ChainQual, e: *sql.Expr) ?usize {
    switch (e.*) {
        .column_idx => |c| return c.idx,
        .column => |name| {
            if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                const q = name[0..dot];
                const cn = name[dot + 1 ..];
                for (quals) |m| {
                    if (!std.ascii.eqlIgnoreCase(m.qual, q)) continue;
                    if (m.col < t.cols.len and columnMatches(t.cols[m.col].name, cn)) return m.col;
                }
                return null;
            }
            return keyCol(t, e);
        },
        else => return null,
    }
}

/// One input side of a join for predicate binding: a base table (by name and
/// optional alias) or a chain intermediate (via the qualifier -> column map).
pub const ExprSide = struct {
    t: *Table,
    name: []const u8,
    alias: ?[]const u8 = null,
    quals: ?[]const ChainQual = null,

    fn colAt(self: ExprSide, e: *sql.Expr) ?usize {
        if (self.quals) |q| {
            if (chainQualCol(self.t, q, e)) |c| return c;
        }
        return colOfSide(self.t, self.name, self.alias, e);
    }
};

/// Deep-copy `e` binding every column reference to a column index of `side`.
/// Returns null when any reference does not belong to that side, which is what
/// classifies a multi-key ON conjunct as a per-side filter.
fn rebindExprSide(alloc: std.mem.Allocator, e: *sql.Expr, side: ExprSide) ?*sql.Expr {
    const n = alloc.create(sql.Expr) catch return null;
    switch (e.*) {
        .column => |nm| {
            const ci = side.colAt(e) orelse return null;
            n.* = .{ .column_idx = .{ .idx = @intCast(ci), .name = nm } };
        },
        .column_idx => |c| {
            if (c.idx >= side.t.cols.len) return null;
            n.* = .{ .column_idx = c };
        },
        .int => |v| n.* = .{ .int = v },
        .float => |v| n.* = .{ .float = v },
        .string => |v| n.* = .{ .string = v },
        .null_lit => n.* = .null_lit,
        .binary => |b| {
            const l = rebindExprSide(alloc, b.lhs, side) orelse return null;
            const r = rebindExprSide(alloc, b.rhs, side) orelse return null;
            n.* = .{ .binary = .{ .op = b.op, .lhs = l, .rhs = r } };
        },
        .negate => |x| n.* = .{ .negate = rebindExprSide(alloc, x, side) orelse return null },
        .not => |x| n.* = .{ .not = rebindExprSide(alloc, x, side) orelse return null },
        .cast => |c| n.* = .{ .cast = .{
            .operand = rebindExprSide(alloc, c.operand, side) orelse return null,
            .type_name = c.type_name,
        } },
        .call => |c| {
            const args = alloc.alloc(*sql.Expr, c.args.len) catch return null;
            for (c.args, 0..) |x, i| args[i] = rebindExprSide(alloc, x, side) orelse return null;
            n.* = .{ .call = .{ .name = c.name, .args = args, .distinct = c.distinct, .star = c.star } };
        },
        .case_expr => |c| {
            const whens = alloc.alloc(sql.Case.When, c.whens.len) catch return null;
            for (c.whens, 0..) |w, i| {
                whens[i] = .{
                    .cond = rebindExprSide(alloc, w.cond, side) orelse return null,
                    .then = rebindExprSide(alloc, w.then, side) orelse return null,
                };
            }
            n.* = .{ .case_expr = .{
                .whens = whens,
                .else_expr = if (c.else_expr) |x| rebindExprSide(alloc, x, side) orelse return null else null,
            } };
        },
        .is_null => |x| n.* = .{ .is_null = .{
            .operand = rebindExprSide(alloc, x.operand, side) orelse return null,
            .negated = x.negated,
        } },
        .like => |x| n.* = .{ .like = .{
            .operand = rebindExprSide(alloc, x.operand, side) orelse return null,
            .pattern = rebindExprSide(alloc, x.pattern, side) orelse return null,
            .negated = x.negated,
        } },
        .in_list => |x| {
            const items = alloc.alloc(*sql.Expr, x.items.len) catch return null;
            for (x.items, 0..) |it, i| items[i] = rebindExprSide(alloc, it, side) orelse return null;
            n.* = .{ .in_list = .{
                .operand = rebindExprSide(alloc, x.operand, side) orelse return null,
                .items = items,
                .negated = x.negated,
            } };
        },
        .between => |x| n.* = .{ .between = .{
            .operand = rebindExprSide(alloc, x.operand, side) orelse return null,
            .low = rebindExprSide(alloc, x.low, side) orelse return null,
            .high = rebindExprSide(alloc, x.high, side) orelse return null,
            .negated = x.negated,
        } },
        else => return null,
    }
    return n;
}

/// Deep-copy `e` binding left-side columns to their indexes and right-side
/// columns to `nl + index`, so the predicate can be evaluated against a
/// combined (left ++ right) row. Returns null when a column belongs to neither
/// side.
fn rebindCombined(
    alloc: std.mem.Allocator,
    e: *sql.Expr,
    lside: ExprSide,
    rside: ExprSide,
    nl: usize,
) ?*sql.Expr {
    const n = alloc.create(sql.Expr) catch return null;
    switch (e.*) {
        .column => |nm| {
            if (lside.colAt(e)) |ci| {
                n.* = .{ .column_idx = .{ .idx = @intCast(ci), .name = nm } };
            } else if (rside.colAt(e)) |ci| {
                n.* = .{ .column_idx = .{ .idx = @intCast(nl + ci), .name = nm } };
            } else return null;
        },
        .column_idx => |c| {
            if (c.idx < nl) {
                n.* = .{ .column_idx = c };
            } else if (c.idx - nl < rside.t.cols.len) {
                n.* = .{ .column_idx = c };
            } else return null;
        },
        .int => |v| n.* = .{ .int = v },
        .float => |v| n.* = .{ .float = v },
        .string => |v| n.* = .{ .string = v },
        .null_lit => n.* = .null_lit,
        .binary => |b| {
            const l = rebindCombined(alloc, b.lhs, lside, rside, nl) orelse return null;
            const r = rebindCombined(alloc, b.rhs, lside, rside, nl) orelse return null;
            n.* = .{ .binary = .{ .op = b.op, .lhs = l, .rhs = r } };
        },
        .negate => |x| n.* = .{ .negate = rebindCombined(alloc, x, lside, rside, nl) orelse return null },
        .not => |x| n.* = .{ .not = rebindCombined(alloc, x, lside, rside, nl) orelse return null },
        .cast => |c| n.* = .{ .cast = .{
            .operand = rebindCombined(alloc, c.operand, lside, rside, nl) orelse return null,
            .type_name = c.type_name,
        } },
        .call => |c| {
            const args = alloc.alloc(*sql.Expr, c.args.len) catch return null;
            for (c.args, 0..) |x, i| {
                args[i] = rebindCombined(alloc, x, lside, rside, nl) orelse return null;
            }
            n.* = .{ .call = .{ .name = c.name, .args = args, .distinct = c.distinct, .star = c.star } };
        },
        .case_expr => |c| {
            const whens = alloc.alloc(sql.Case.When, c.whens.len) catch return null;
            for (c.whens, 0..) |w, i| {
                whens[i] = .{
                    .cond = rebindCombined(alloc, w.cond, lside, rside, nl) orelse return null,
                    .then = rebindCombined(alloc, w.then, lside, rside, nl) orelse return null,
                };
            }
            n.* = .{ .case_expr = .{
                .whens = whens,
                .else_expr = if (c.else_expr) |x| rebindCombined(alloc, x, lside, rside, nl) orelse return null else null,
            } };
        },
        .is_null => |x| n.* = .{ .is_null = .{
            .operand = rebindCombined(alloc, x.operand, lside, rside, nl) orelse return null,
            .negated = x.negated,
        } },
        .like => |x| n.* = .{ .like = .{
            .operand = rebindCombined(alloc, x.operand, lside, rside, nl) orelse return null,
            .pattern = rebindCombined(alloc, x.pattern, lside, rside, nl) orelse return null,
            .negated = x.negated,
        } },
        .in_list => |x| {
            const items = alloc.alloc(*sql.Expr, x.items.len) catch return null;
            for (x.items, 0..) |it, i| {
                items[i] = rebindCombined(alloc, it, lside, rside, nl) orelse return null;
            }
            n.* = .{ .in_list = .{
                .operand = rebindCombined(alloc, x.operand, lside, rside, nl) orelse return null,
                .items = items,
                .negated = x.negated,
            } };
        },
        .between => |x| n.* = .{ .between = .{
            .operand = rebindCombined(alloc, x.operand, lside, rside, nl) orelse return null,
            .low = rebindCombined(alloc, x.low, lside, rside, nl) orelse return null,
            .high = rebindCombined(alloc, x.high, lside, rside, nl) orelse return null,
            .negated = x.negated,
        } },
        else => return null,
    }
    return n;
}

/// Bounded key-frequency sketch for a (partial) join result. The DP uses it so
/// planning-time cardinality is duplicate-aware (`Σ f_l·f_r`) instead of
/// `1/max(ndv)`, and it can be propagated through chain steps.
pub const KeyDist = struct {
    vals: [48]KeyCnt = undefined,
    /// String keys (used when `is_str`): the explicit values; `min`/`max` are
    /// then unused and `kmin`/`kmax` hold their order-preserving keys.
    svals: [48][]const u8 = undefined,
    is_str: bool = false,
    is_float: bool = false,
    n: usize = 0,
    res_rows: f64 = 0,
    res_ndv: f64 = 1,
    rows: f64 = 0,
    min: i64 = 0,
    max: i64 = 0,
    kmin: u64 = 0,
    kmax: u64 = 0,
    members: [10]KeyMember = undefined,
    nm: usize = 0,
    valid: bool = false,
    /// True when the counts were scaled by an intermediate's row multiplicity,
    /// so they no longer match the base table's exact encodings.
    scaled: bool = false,
};

/// Scale a key distribution by a uniform row multiplier (intermediate fan-out).
fn scaleKeyDist(d: KeyDist, m: f64) KeyDist {
    var out = d;
    out.rows *= m;
    out.res_rows *= m;
    var i: usize = 0;
    while (i < out.n) : (i += 1) out.vals[i].c *= m;
    out.scaled = true;
    return out;
}

/// Order-preserving map from f64 to i64: IEEE-754 sign-aware (positives keep
/// their order with the sign bit set, negatives are fully inverted). `-0.0` is
/// normalised to `+0.0` so SQL equality holds; callers must skip NaN.
/// One resolved `IN (SELECT ...)` used while sampling OR pairs.
const OrSubq = struct {
    expr: *sql.Expr,
    set: *std.StringHashMap(void),
    has_null: bool,
    keys: []*sql.Expr = &.{},
    range_map: ?*std.StringHashMap(RangeBound) = null,
    range_keys: [2]?*sql.Expr = @splat(null),
    range_ops: [2]sql.BinOp = @splat(.ge),
    range_n: u8 = 0,
};

/// Active subquery sets during OR-pair measurement (single-threaded planning).
threadlocal var or_subq: ?[]const OrSubq = null;

/// Append one value to a membership key (same textual form used when the set
/// was built). Text is appended whole — no fixed-size buffer, so long string
/// values cannot collide by truncation. Numeric formatting fits easily in the
/// small stack buffer (i64 ≤ 20 chars, f64 ≤ ~24).
fn appendKeyPart(list: *std.ArrayList(u8), v: Value, alloc: std.mem.Allocator) !bool {
    switch (v) {
        .text => |t| try list.appendSlice(alloc, t),
        .int => |i| {
            var b: [32]u8 = undefined;
            const x = std.fmt.bufPrint(&b, "{d}", .{i}) catch return false;
            try list.appendSlice(alloc, x);
        },
        .float => |f| {
            var b: [64]u8 = undefined;
            const x = std.fmt.bufPrint(&b, "{d}", .{f}) catch return false;
            try list.appendSlice(alloc, x);
        },
        .boolean => |x| try list.appendSlice(alloc, if (x) "true" else "false"),
        .null => return false,
    }
    return true;
}

/// Per-thread growable scratch for membership-key evaluation (no size cap).
threadlocal var eval_key_buf: std.ArrayList(u8) = .empty;


fn mixHash(h0: u64, v: u64) u64 {
    return (h0 ^ v) *% 1099511628211;
}

fn mixStr(h0: u64, s: []const u8) u64 {
    var h = h0;
    for (s) |b| h = mixHash(h, b);
    return h;
}

/// Structural hash of a predicate tree. Subqueries hash their operand, the
/// negation flag and the sub-SELECT's shape, so identical SQL texts match
/// across statements without keeping a live AST pointer for comparison.
fn exprHash(e: *sql.Expr) u64 {
    var h: u64 = 0xcbf29ce484222325;
    switch (e.*) {
        .column => |n| {
            h = mixHash(h, 1);
            h = mixStr(h, n);
        },
        .column_idx => |c| {
            h = mixHash(h, 2);
            h = mixHash(h, c.idx);
        },
        .int => |v| {
            h = mixHash(h, 3);
            h = mixHash(h, @bitCast(v));
        },
        .float => |v| {
            h = mixHash(h, 4);
            h = mixHash(h, @bitCast(v));
        },
        .string => |v| {
            h = mixHash(h, 5);
            h = mixStr(h, v);
        },
        .null_lit => h = mixHash(h, 6),
        .star => h = mixHash(h, 7),
        .star_table => |q| { h = mixHash(h, 8); h = mixStr(h, q); },
        .binary => |b| {
            h = mixHash(h, 8);
            h = mixHash(h, @intFromEnum(b.op));
            h = mixHash(h, exprHash(b.lhs));
            h = mixHash(h, exprHash(b.rhs));
        },
        .negate => |x| {
            h = mixHash(h, 9);
            h = mixHash(h, exprHash(x));
        },
        .bitnot => |x| {
            h = mixHash(h, 20);
            h = mixHash(h, exprHash(x));
        },
        .not => |x| {
            h = mixHash(h, 10);
            h = mixHash(h, exprHash(x));
        },
        .is_null => |x| {
            h = mixHash(h, 11);
            h = mixHash(h, if (x.negated) 1 else 0);
            h = mixHash(h, exprHash(x.operand));
        },
        .like => |x| {
            h = mixHash(h, 12);
            h = mixHash(h, if (x.negated) 1 else 0);
            h = mixHash(h, exprHash(x.operand));
            h = mixHash(h, exprHash(x.pattern));
        },
        .in_list => |x| {
            h = mixHash(h, 13);
            h = mixHash(h, if (x.negated) 1 else 0);
            h = mixHash(h, exprHash(x.operand));
            for (x.items) |it| h = mixHash(h, exprHash(it));
        },
        .between => |x| {
            h = mixHash(h, 14);
            h = mixHash(h, if (x.negated) 1 else 0);
            h = mixHash(h, exprHash(x.operand));
            h = mixHash(h, exprHash(x.low));
            h = mixHash(h, exprHash(x.high));
        },
        .in_subquery => |x| {
            h = mixHash(h, 15);
            h = mixHash(h, if (x.negated) 1 else 0);
            h = mixHash(h, exprHash(x.operand));
            h = mixHash(h, selectHash(x.sub));
        },
        .exists => |x| {
            h = mixHash(h, 16);
            h = mixHash(h, if (x.negated) 1 else 0);
            h = mixHash(h, selectHash(x.sub));
        },
        .cast => |x| {
            h = mixHash(h, 17);
            h = mixStr(h, x.type_name);
            h = mixHash(h, exprHash(x.operand));
        },
        .call => |c| {
            h = mixHash(h, 18);
            h = mixStr(h, c.name);
            for (c.args) |a| h = mixHash(h, exprHash(a));
        },
        .case_expr => |c| {
            h = mixHash(h, 19);
            for (c.whens) |w| {
                h = mixHash(h, exprHash(w.cond));
                h = mixHash(h, exprHash(w.then));
            }
            if (c.else_expr) |x| h = mixHash(h, exprHash(x));
        },
    }
    return h;
}

/// Collect the base-table names a SELECT reads (from + joins, recursing into
/// derived tables). Used to decide which table versions an OR pair depends on.
fn collectSelectTables(sel: *sql.Select, list: *std.ArrayList([]const u8), alloc: std.mem.Allocator) void {
    if (sel.from) |f| {
        switch (f) {
            .table => |n| list.append(alloc, n) catch {},
            .subquery => |sq| collectSelectTables(sq, list, alloc),
            .function => {},
            .values => {},
        }
    }
    if (sel.join) |j| list.append(alloc, j.table) catch {};
    for (sel.more_joins) |j| list.append(alloc, j.table) catch {};
}

/// Rough resident size of a predicate tree (nodes, names and literals).
fn exprBytesOf(e: *sql.Expr) usize {
    var n: usize = 24;
    switch (e.*) {
        .column => |x| n += x.len,
        .column_idx => |c| n += c.name.len,
        .string => |x| n += x.len,
        .star_table => |q| n += q.len,
        .binary => |b| n += exprBytesOf(b.lhs) + exprBytesOf(b.rhs),
        .negate => |x| n += exprBytesOf(x),
        .not => |x| n += exprBytesOf(x),
        .is_null => |x| n += exprBytesOf(x.operand),
        .like => |x| n += exprBytesOf(x.operand) + exprBytesOf(x.pattern),
        .in_list => |x| {
            n += exprBytesOf(x.operand);
            for (x.items) |it| n += exprBytesOf(it);
        },
        .between => |x| n += exprBytesOf(x.operand) + exprBytesOf(x.low) + exprBytesOf(x.high),
        .cast => |x| n += exprBytesOf(x.operand) + x.type_name.len,
        .call => |c| {
            n += c.name.len;
            for (c.args) |a| n += exprBytesOf(a);
        },
        .case_expr => |c| {
            for (c.whens) |w| n += exprBytesOf(w.cond) + exprBytesOf(w.then);
            if (c.else_expr) |x| n += exprBytesOf(x);
        },
        .in_subquery => |x| n += exprBytesOf(x.operand),
        else => {},
    }
    return n;
}

fn selectHash(s: *sql.Select) u64 {
    var h: u64 = 0x9e3779b97f4a7c15;
    if (s.from) |f| {
        switch (f) {
            .table => |n| {
                h = mixHash(h, 1);
                h = mixStr(h, n);
            },
            .subquery => |sub| {
                h = mixHash(h, 2);
                h = mixHash(h, selectHash(sub));
            },
            .function => |fnf| {
                h = mixHash(h, 3);
                h = mixStr(h, fnf.name);
            },
            .values => h = mixHash(h, 9),
        }
    }
    for (s.items) |it| h = mixHash(h, exprHash(it.expr));
    if (s.where) |w| h = mixHash(h, exprHash(w));
    return h;
}

/// Allocation-free `~` / `!~` used by predicate sampling: text operands are
/// compared directly, numbers are formatted into stack buffers.
fn regexMatchValues(a: Value, b: Value) bool {
    var ba: [64]u8 = undefined;
    var bb: [64]u8 = undefined;
    const hay = switch (a) {
        .text => |t| t,
        .int => |i| std.fmt.bufPrint(&ba, "{d}", .{i}) catch return false,
        .float => |f| std.fmt.bufPrint(&ba, "{d}", .{f}) catch return false,
        .boolean => |x| if (x) "true" else "false",
        .null => return false,
    };
    var pat = switch (b) {
        .text => |t| t,
        .int => |i| std.fmt.bufPrint(&bb, "{d}", .{i}) catch return false,
        .float => |f| std.fmt.bufPrint(&bb, "{d}", .{f}) catch return false,
        .boolean => |x| if (x) "true" else "false",
        .null => return false,
    };
    var prefix = false;
    var suffix = false;
    if (pat.len > 0 and pat[0] == '^') {
        prefix = true;
        pat = pat[1..];
    }
    if (pat.len > 0 and pat[pat.len - 1] == '$') {
        suffix = true;
        pat = pat[0 .. pat.len - 1];
    }
    // Minimal `.*` support (the regex subset used by test_setup and several
    // catalog queries): any text between the literal prefix and suffix.
    if (std.mem.indexOf(u8, pat, ".*")) |star| {
        const pre = pat[0..star];
        const post = pat[star + 2 ..];
        if (prefix and suffix) {
            if (!std.mem.startsWith(u8, hay, pre) or !std.mem.endsWith(u8, hay, post)) return false;
            return hay.len >= pre.len + post.len;
        }
        if (prefix) return std.mem.startsWith(u8, hay, pre);
        if (suffix) return std.mem.endsWith(u8, hay, post);
        if (pre.len == 0) return std.mem.indexOf(u8, hay, post) != null;
        const at = std.mem.indexOf(u8, hay, pre) orelse return false;
        return std.mem.indexOfPos(u8, hay, at + pre.len, post) != null;
    }
    if (prefix and suffix) return std.mem.eql(u8, hay, pat);
    if (prefix) return std.mem.startsWith(u8, hay, pat);
    if (suffix) return std.mem.endsWith(u8, hay, pat);
    return std.mem.indexOf(u8, hay, pat) != null;
}

/// Numeric key value of columnar row `row` (floats use the order-preserving
/// transform so the same i64 key space is used everywhere).
fn numericKeyAt(ct: *columnar.Table, ci: usize, row: usize) ?i64 {
    if (ci >= ct.data.len) return null;
    return switch (ct.data[ci]) {
        .ints => |v| if (row < v.len) v[row] else null,
        .floats => |v| if (row < v.len) f64Key(v[row]) else null,
        else => null,
    };
}

fn f64Key(x: f64) i64 {
    const xz: f64 = if (x == 0.0) 0.0 else x;
    const bits: u64 = @bitCast(xz);
    const mask: u64 = if (bits & (1 << 63) != 0)
        0xFFFF_FFFF_FFFF_FFFF
    else
        0x8000_0000_0000_0000;
    return @bitCast(bits ^ mask);
}

/// Inverse of `f64Key` (bijective; NaN keys never occur in statistics).
fn f64FromKey(k: i64) f64 {
    const bits: u64 = @bitCast(k);
    const mask: u64 = if (bits & (1 << 63) != 0)
        0x8000_0000_0000_0000
    else
        0xFFFF_FFFF_FFFF_FFFF;
    const orig: u64 = bits ^ mask;
    return @bitCast(orig);
}

/// Order-preserving key of a string's first 8 bytes (same as the residual
/// histogram's `strKey`), used for string key-domain overlap.
fn distStrKey(s: []const u8) u64 {
    var h: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const b: u64 = if (i < s.len) s[i] else 0;
        h = (h << 8) | b;
    }
    return h;
}

fn keyDistKnows(d: KeyDist, t: []const u8, c: usize) bool {
    for (d.members[0..d.nm]) |m| {
        if (m.c == c and std.ascii.eqlIgnoreCase(m.t, t)) return true;
    }
    return false;
}

/// Column of `t` referenced by `e`, honouring a qualifier when present: `d.j`
/// only resolves in table `d` (or its alias), never in `f` that also has `j`.
fn colOfSide(t: *Table, tname: []const u8, alias: ?[]const u8, e: *sql.Expr) ?usize {
    switch (e.*) {
        .column => |n| {
            if (std.mem.lastIndexOfScalar(u8, n, '.')) |dot| {
                const q = n[0..dot];
                const ok = std.ascii.eqlIgnoreCase(q, tname) or
                    (alias != null and std.ascii.eqlIgnoreCase(q, alias.?));
                if (!ok) return null;
                return findCol(t, n[dot + 1 ..]);
            }
            return findCol(t, n);
        },
        .column_idx => |c| if (c.idx < t.cols.len) return c.idx else return null,
        else => return null,
    }
}

/// Key column of `t` named by one side of an equi-join ON (qualifier-aware).
fn keyColOfJoin(t: *Table, tname: []const u8, alias: ?[]const u8, on: *sql.Expr) ?usize {
    if (on.* != .binary) return null;
    return colOfSide(t, tname, alias, on.binary.lhs) orelse colOfSide(t, tname, alias, on.binary.rhs);
}

/// Combine two key distributions: `rows = Σ f_l(v)·f_r(v) + residual`.
fn joinKeyDist(l: KeyDist, r: KeyDist) KeyDist {
    var out = KeyDist{};
    if (!l.valid or !r.valid) return out;
    if (l.is_str != r.is_str) return out;
    out.is_str = l.is_str;
    out.is_float = l.is_float;
    out.scaled = l.scaled or r.scaled;
    // Domain overlap: string keys use their order-preserving prefix key, float
    // keys decode back to value space (key spans are not linear in value), and
    // integers use their range directly.
    const llo: f64 = if (l.is_str) @floatFromInt(l.kmin) else if (l.is_float) f64FromKey(l.min) else @floatFromInt(l.min);
    const lhi: f64 = if (l.is_str) @floatFromInt(l.kmax) else if (l.is_float) f64FromKey(l.max) else @floatFromInt(l.max);
    const rlo: f64 = if (r.is_str) @floatFromInt(r.kmin) else if (r.is_float) f64FromKey(r.min) else @floatFromInt(r.min);
    const rhi: f64 = if (r.is_str) @floatFromInt(r.kmax) else if (r.is_float) f64FromKey(r.max) else @floatFromInt(r.max);
    const sl = lhi - llo + 1.0;
    const sr = rhi - rlo + 1.0;
    const lo = @max(llo, rlo);
    const hi = @min(lhi, rhi);
    const ov = @max(hi - lo + 1.0, 0.0);
    const domain = @min(ov / @max(@min(sl, sr), 1.0), 1.0);
    out.min = @intFromFloat(lo);
    out.max = @intFromFloat(hi);
    out.kmin = @intFromFloat(lo);
    out.kmax = @intFromFloat(hi);
    out.valid = true;
    if (domain <= 0) {
        out.rows = 0;
        return out;
    }
    var pairs: f64 = 0;
    var i: usize = 0;
    while (i < l.n) : (i += 1) {
        const lv = if (l.is_str) l.svals[i] else "";
        const lk: f64 = if (l.is_str) @floatFromInt(distStrKey(lv)) else @floatFromInt(l.vals[i].v);
        var cr: f64 = 0;
        var j: usize = 0;
        while (j < r.n) : (j += 1) {
            if (l.is_str) {
                if (std.mem.eql(u8, lv, r.svals[j])) {
                    cr = r.vals[j].c;
                    break;
                }
            } else if (l.vals[i].v == r.vals[j].v) {
                cr = r.vals[j].c;
                break;
            }
        }
        if (cr == 0 and lk >= rlo and lk <= rhi and r.res_ndv > 0) cr = r.res_rows / r.res_ndv;
        const pr = l.vals[i].c * cr;
        if (pr > 0) {
            pairs += pr;
            if (out.n < out.vals.len) {
                out.vals[out.n] = .{ .v = l.vals[i].v, .c = pr };
                out.svals[out.n] = lv;
                out.n += 1;
            }
        }
    }
    i = 0;
    while (i < r.n) : (i += 1) {
        const rv = if (r.is_str) r.svals[i] else "";
        const rk: f64 = if (r.is_str) @floatFromInt(distStrKey(rv)) else @floatFromInt(r.vals[i].v);
        var in_l = false;
        var j: usize = 0;
        while (j < l.n) : (j += 1) {
            if (l.is_str) {
                if (std.mem.eql(u8, rv, l.svals[j])) {
                    in_l = true;
                    break;
                }
            } else if (r.vals[i].v == l.vals[j].v) {
                in_l = true;
                break;
            }
        }
        if (in_l or rk < llo or rk > lhi or l.res_ndv <= 0) continue;
        const cl = l.res_rows / l.res_ndv;
        const pr = cl * r.vals[i].c;
        if (pr > 0) {
            pairs += pr;
            if (out.n < out.vals.len) {
                out.vals[out.n] = .{ .v = r.vals[i].v, .c = pr };
                out.svals[out.n] = rv;
                out.n += 1;
            }
        }
    }
    pairs += l.res_rows * r.res_rows * domain / @max(l.res_ndv, r.res_ndv);
    out.rows = pairs;
    var explicit_sum: f64 = 0;
    for (out.vals[0..out.n]) |e| explicit_sum += e.c;
    out.res_rows = @max(pairs - explicit_sum, 0.0);
    out.res_ndv = @max(@min(l.res_ndv, r.res_ndv), 1.0);
    for (l.members[0..l.nm]) |m| {
        if (out.nm < out.members.len) {
            out.members[out.nm] = m;
            out.nm += 1;
        }
    }
    for (r.members[0..r.nm]) |m| {
        if (out.nm < out.members.len) {
            out.members[out.nm] = m;
            out.nm += 1;
        }
    }
    return out;
}

pub const ColStat = struct {
    ndv: usize = 0,
    nulls: usize = 0,
    min: i64 = 0,
    max: i64 = 0,
    /// Most-common values (top 16) with sampled frequencies (sum <= 1).
    mcv: []McvEntry = &.{},
    /// Equi-depth histogram boundaries (sorted increasing, last = max+1).
    hist: []i64 = &.{},
    /// Distinct values per histogram bucket (sampled); used to integrate the
    /// surviving residual ndv over a filtered range instead of scaling linearly.
    hist_ndv: []u32 = &.{},
    /// Per-bucket value bounds, so partial-bucket overlap is measured in value
    /// space (not by mass fraction).
    hist_lo: []i64 = &.{},
    hist_hi: []i64 = &.{},
    mcv_mass: f64 = 0,
    /// String columns: top-16 MCVs, lexicographic equi-depth boundaries and
    /// the sampled [min,max] strings.
    mcv_str: []McvStr = &.{},
    mcv_str_mass: f64 = 0,
    hist_str: [][]u8 = &.{},
    /// Distinct values per string histogram bucket (sampled).
    hist_str_ndv: []u32 = &.{},
    /// Per-bucket string value bounds (first/last sampled value), used for
    /// value-space overlap via an order-preserving 8-byte key.
    hist_str_lo: [][]u8 = &.{},
    hist_str_hi: [][]u8 = &.{},
    /// Value -> row-count map for string dictionaries: exact for ndv <= 65536,
    /// otherwise a bounded sample (top-512) with `dict_sampled` set.
    dict: []DictEntry = &.{},
    dict_sampled: bool = false,
    dict_sample_rows: usize = 0,
    rows_nonnull: usize = 0,
    /// Residual (non-Map) sampled value range and equi-depth histogram.
    res_min: []u8 = &.{},
    res_max: []u8 = &.{},
    res_hist: [][]u8 = &.{},
    res_hist_ndv: []u32 = &.{},
    /// Sampled row count per residual histogram bucket (actual mass, so the
    /// residual CDF does not assume 1/nb per bucket).
    res_hist_mass: []u32 = &.{},
    /// Second-level histogram: `res_sub_per_bucket + 1` boundaries per residual
    /// bucket (flattened) plus per-sub-bucket mass and distinct counts. The
    /// residual CDF integrates over these, so interpolation only happens
    /// inside a sub-bucket (1/64 of the residual instead of 1/16).
    res_sub: [][]u8 = &.{},
    res_sub_mass: []u32 = &.{},
    res_sub_ndv: []u32 = &.{},
    /// Cumulative sampled mass per second-level sub-bucket (prefix sums of
    /// `res_sub_mass`), so the residual CDF is a binary search + one in-bucket
    /// interpolation — no value sample needed.
    res_sub_cum: []u32 = &.{},
    /// Exact residual CDF (when it fits the byte budget): sorted distinct
    /// residual values plus cumulative row counts. Makes range selectivity
    /// exact instead of a 1/2048 histogram approximation.
    res_cdf_vals: [][]u8 = &.{},
    res_cdf_cum: []u32 = &.{},
    min_str: []u8 = &.{},
    max_str: []u8 = &.{},
    /// Top trigrams with document frequencies (fraction of sampled values that
    /// contain the trigram); used for `%infix%` / `%suffix` LIKE estimates.
    ngram: []NgramStat = &.{},
    /// Top 1..3 byte suffix document frequencies (helps patterns that end with a
    /// short literal run, e.g. `%google_5` where `_` is a wildcard).
    suf: []SuffixStat = &.{},
};

/// Calibrated cost constants (see P65): a filtered scan costs 4.6 ns/row,
/// compaction rewrites at ~79 ns/row, and tombstoned tables pay ~4x per row.
const COST_SCAN_ROW_NS: f64 = 4.6;
const COST_COMPACT_ROW_NS: f64 = 79.0;
const COST_TOMB_FACTOR: f64 = 4.0;

/// Rows per reclamation segment (matches the columnar block size).
const seg_rows: usize = 8192;

/// Tiny spin lock for engine-internal pools (no `std.Io` needed here).
const SpinLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// Per-thread transaction context: one session per thread, and a statement runs
/// synchronously on its session's thread. This is what lets two transactions
/// execute on different tables at the same time (no shared `active_txn` field).
threadlocal var tls_txn: ?*TxnCtx = null;
/// Per-thread aggregate-expression stack (read by `eval` for placeholder
/// resolution inside one statement).
threadlocal var tls_agg_exprs: []const *sql.Expr = &.{};
/// Per-statement JOIN result tables / their columnar copies: never inserted
/// into the shared catalogs, so two concurrent JOINs cannot collide.
threadlocal var tls_temp_tables: ?std.StringHashMap(*Table) = null;
threadlocal var tls_temp_columnar: ?std.StringHashMap(*columnar.Table) = null;
/// Per-statement subquery state (IN/EXISTS sets and correlated predicates).
const StmtState = struct {
    sets: std.ArrayList(SubqSet) = .empty,
    exists: std.ArrayList(SubqExists) = .empty,
    corr: std.ArrayList(CorrPlan) = .empty,
};
/// One state object per thread (statement scratch). Statically preallocated so
/// initialisation cannot fail (and cannot panic on OOM).
threadlocal var tls_state_storage: StmtState = .{};

fn stmtState() *StmtState {
    return &tls_state_storage;
}
threadlocal var tls_join_seq: usize = 0;
/// Temp table produced by a non-finalised join step (multi-join chains).
threadlocal var tls_kept_join: ?[]const u8 = null;
threadlocal var tls_diag_buf: [512]u8 = undefined;
threadlocal var tls_diag_len: usize = 0;

pub fn setDiag(comptime fmt: []const u8, args: anytype) void {
    tls_diag_len = (std.fmt.bufPrint(&tls_diag_buf, fmt, args) catch return).len;
}

pub fn diagMessage() ?[]const u8 {
    return if (tls_diag_len > 0) tls_diag_buf[0..tls_diag_len] else null;
}

/// Temporary JOIN results use a `__` prefix and live per statement.
fn isTempName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "__");
}

const SelFeedback = struct { name: []const u8, factor: f64 };
const ScanCount = struct { name: []const u8, count: usize };

const Table = struct {
    /// Bench-only: every row slice aliases one dummy row, so row buffers must
    /// not be freed individually (the columnar image carries the data).
    rows_shared_dummy: bool = false,
    name: []const u8,
    cols: []Column,
    /// ClickHouse-style types (`UInt64`, `String`, ...) define an implicit
    /// zero/empty default for omitted INSERT columns; PostgreSQL-style types
    /// default to NULL.  This keeps both dialects usable without a mode flag.
    ch_defaults: bool = false,
    /// Created by CREATE TEMP TABLE (shadowed table restoration on DROP).
    is_temp: bool = false,
    /// Next SERIAL value for INSERTs that omit the column.
    serial_next: i64 = 1,
    rows: std.ArrayList([]Value),
    arena: std.heap.ArenaAllocator,
    stats: []ColStat = &.{},
    /// Demand-driven OR statistics: `A OR B` predicate pairs the planner saw,
    /// with sampled counts for A, B and A∧B so inclusion-exclusion uses measured
    /// joint mass instead of the independence product.
    or_req: std.ArrayList(OrReq) = .empty,
    /// Resident bytes of the OR cache for this table (LRU-bounded).
    or_bytes: usize = 0,
    /// 1 byte per row: 1 = deleted (tombstone); row ids stay stable.
    deleted: std.ArrayList(u8) = .empty,
    /// Row id in the columnar copy (an UPDATE creates a new row version whose
    /// `ctid` points at the original slot: the copy has one row per logical row).
    ctid: std.ArrayList(u32) = .empty,
    /// Number of dead row versions (tombstoned or superseded by an UPDATE).
    /// Maintained incrementally so the background GC never has to rescan a
    /// whole table just to decide whether to reclaim.
    dead_rows: usize = 0,
    /// Segment-level free-space map: rows are grouped into fixed-size segments
    /// (`seg_rows`), each with a dead-row count. `free_segments` lists only the
    /// segments that currently contain reclaimable rows, so VACUUM / GC touch
    /// just those instead of rewriting the table.
    seg_dead: std.ArrayList(u32) = .empty,
    seg_dirty: std.ArrayList(u8) = .empty,
    free_segments: std.ArrayList(u32) = .empty,
    /// Slot ids freed by reclamation, ready for reuse by INSERT. Consumed
    /// front-to-back (`free_head`) in ascending row-id order, i.e. whole freed
    /// segments are refilled before any later segment and before appending.
    free_slots: std.ArrayList(u32) = .empty,
    free_head: usize = 0,
    /// Per-segment free-space map: reusable (reclaimed) slots in each
    /// `seg_rows` segment. Written by reclamation, read by INSERT's reuse
    /// decision and reported by EXPLAIN.
    seg_free_rows: std.ArrayList(u32) = .empty,
    /// Slot contents after reclamation: a table-owned all-placeholder row, so
    /// scans that skip tombstones never touch freed memory.
    placeholder: []Value = &.{},
    /// Per-column validity bitmap (1 = present), mirroring the columnar
    /// `Table.valid`. `null` means "column has no NULLs" (fast path).
    nulls: []?[]u8 = &.{},
    /// MVCC row versions: creator txid (0 = visible to everyone) and deleter
    /// txid (0 = live). Parallel to `rows`.
    xmin: std.ArrayList(u64) = .empty,
    xmax: std.ArrayList(u64) = .empty,

    fn create(gpa: std.mem.Allocator, name: []const u8, defs: []const ColumnDef) !*Table {
        const t = try gpa.create(Table);
        t.* = .{
            .name = try gpa.dupe(u8, name),
            .cols = try gpa.alloc(Column, defs.len),
            .rows = .empty,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        t.nulls = try gpa.alloc(?[]u8, defs.len);
        @memset(t.nulls, null);
        // Reclaimed slots point at this shared placeholder row.
        t.placeholder = try gpa.alloc(Value, defs.len);
        for (t.placeholder) |*c| c.* = .{ .int = 0 };
        for (defs, 0..) |d, i| {
            t.cols[i] = .{
                .name = try gpa.dupe(u8, d.name),
                .ty = mapType(d.type_name),
                .source = t.name,
                .max_len = @intCast(typeCharLen(d.type_name) orelse 0),
                .pad_char = isCharTypeName(d.type_name),
                .is_oid = isOidTypeName(d.type_name),
                .int_bits = intTypeBits(d.type_name),
                .is_numeric = std.ascii.eqlIgnoreCase(d.type_name, "numeric") or std.ascii.eqlIgnoreCase(d.type_name, "decimal"),
                .serial = d.serial,
                .is_macaddr = std.ascii.eqlIgnoreCase(d.type_name, "macaddr"),
                .is_lseg = std.ascii.eqlIgnoreCase(d.type_name, "lseg"),
                .is_path = std.ascii.eqlIgnoreCase(d.type_name, "path"),
            };
            if (isClickHouseTypeName(d.type_name)) t.ch_defaults = true;
        }
        return t;
    }

    fn destroy(self: *Table, gpa: std.mem.Allocator) void {
        for (self.rows.items) |row| {
            if (self.placeholder.len == self.cols.len and row.ptr == self.placeholder.ptr) continue;
            gpa.free(row);
        }
        self.rows.deinit(gpa);
        if (self.placeholder.len > 0) gpa.free(self.placeholder);
        self.seg_dead.deinit(gpa);
        self.seg_dirty.deinit(gpa);
        self.free_segments.deinit(gpa);
        self.free_slots.deinit(gpa);
        self.seg_free_rows.deinit(gpa);
        for (self.or_req.items) |*r| {
            for (r.subs.items) |*ss| {
                ss.set.deinit();
                if (ss.range_map) |m0| {
                    m0.deinit();
                    gpa.destroy(m0);
                    ss.range_map = null;
                }
            }
            r.subs.deinit(gpa);
            if (r.sub_arena) |ar| {
                ar.deinit();
                gpa.destroy(ar);
            }
            if (r.pred_arena) |ar| {
                ar.deinit();
                gpa.destroy(ar);
            }
        }
        self.or_req.deinit(gpa);
        for (self.nulls) |maybe| {
            if (maybe) |bits| gpa.free(bits);
        }
        if (self.nulls.len > 0) gpa.free(self.nulls);
        self.deleted.deinit(gpa);
        self.ctid.deinit(gpa);
        self.xmin.deinit(gpa);
        self.xmax.deinit(gpa);
        for (self.stats) |st| {
            if (st.mcv.len > 0) gpa.free(st.mcv);
            if (st.hist.len > 0) gpa.free(st.hist);
            if (st.hist_ndv.len > 0) gpa.free(st.hist_ndv);
            if (st.hist_lo.len > 0) gpa.free(st.hist_lo);
            if (st.hist_hi.len > 0) gpa.free(st.hist_hi);
            for (st.mcv_str) |m| gpa.free(m.s);
            if (st.mcv_str.len > 0) gpa.free(st.mcv_str);
            for (st.hist_str) |h| gpa.free(h);
            if (st.hist_str.len > 0) gpa.free(st.hist_str);
            if (st.min_str.len > 0) gpa.free(st.min_str);
            if (st.max_str.len > 0) gpa.free(st.max_str);
            if (st.ngram.len > 0) gpa.free(st.ngram);
            if (st.suf.len > 0) gpa.free(st.suf);
            if (st.hist_str_ndv.len > 0) gpa.free(st.hist_str_ndv);
        }
        if (self.stats.len > 0) gpa.free(self.stats);
        for (self.cols) |c| gpa.free(c.name);
        gpa.free(self.cols);
        gpa.free(self.name);
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn dupValue(self: *Table, v: Value) !Value {
        return switch (v) {
            .text => |s| .{ .text = try self.arena.allocator().dupe(u8, s) },
            else => v,
        };
    }
};

pub const Result = struct {
    columns: []const []const u8 = &.{},
    rows: []const []Value = &.{},
    affected: usize = 0,
    format_json: bool = false,
};

pub const RowCtx = struct {
    row: ?[]Value,
    group: ?[]const []Value = null,
    agg: ?[]const Value = null,
    agg_exprs: []const *sql.Expr = &.{},
};

pub const AggCtx = struct {
    exprs: []const *sql.Expr,
    vals: []const Value,
};

const AggKind = enum { count_all, count, count_distinct, sum, avg, min, max };

const AggSpec = struct {
    expr: *sql.Expr,
    kind: AggKind,
    arg: ?*sql.Expr,
    arg_idx: i32 = -1,
};

const Acc = struct {
    isum: i128 = 0,
    fsum: f64 = 0,
    n: i64 = 0,
    best: Value = .null,
    has_best: bool = false,
    has_float: bool = false,
    set: ?*std.StringHashMap(void) = null,
};

const GroupState = struct {
    first: ?[]Value = null,
    accs: []Acc,
};

pub const EngineError = error{ TableNotFound, TableExists, ValueTooLong, InvalidOid, OidOutOfRange, InvalidBoolean, InvalidInt, IntOutOfRange, SmallintOutOfRange, IntegerOutOfRange, BigintOutOfRange, StepZero, DivisionByZero, TableColumnMismatch, UngroupedColumn, InvalidTableAlias, InvalidMacaddr, InvalidLseg, InvalidPath, SyntaxError, OutOfMemory, TooManyColumns, UnknownColumn, Unsupported, UnsupportedJoin, FileNotFound, CorrelatedSubquery, NotAnIntColumn, SerializationFailure };

const SubqSet = struct {
    expr: *sql.Expr,
    set: std.StringHashMap(void),
    has_null: bool,
    negated: bool,
};

const SubqExists = struct { expr: *sql.Expr, val: bool };

/// A correlated EXISTS/IN: the subquery's equality predicates that mention the
/// outer query become join keys; the rest of its WHERE is evaluated once.
const CorrPlan = struct {
    expr: *sql.Expr,
    /// Outer-side key expressions (bound to the outer row's columns).
    keys: []*sql.Expr,
    /// Distinct inner key tuples (composite key, parts joined by 0x1f).
    set: std.StringHashMap(void),
    negated: bool,
    /// `IN` semantics: a NULL key or a NULL in the set never satisfies NOT IN.
    for_in: bool,
    has_null: bool,
    /// Range correlation `inner.k OP outer.k`: per inner value, the [min,max]
    /// inner key interval (up to two conditions, e.g. an interval correlation).
    range_map: ?*std.StringHashMap(RangeBound) = null,
    range_keys: [2]?*sql.Expr = @splat(null),
    range_ops: [2]sql.BinOp = @splat(.ge),
    range_n: u8 = 0,
    operand: ?*sql.Expr = null,
};

pub const TxnView = struct { name: []const u8, ct: *columnar.Table };

pub const TxnCtx = struct {
    in_txn: bool = false,
    txid: u64 = 0,
    snapshot: u64 = 0,
    stmts: std.ArrayList([]u8) = .empty,
    undo: std.ArrayList(Undo) = .empty,
    /// Private columnar copies of tables this transaction has written, built
    /// from its own snapshot-visible rows (a per-transaction delta view).
    views: std.ArrayList(TxnView) = .empty,
};

const Undo = struct {
    name: []const u8,
    rows: []([]Value),
};

/// Default memory budget for the per-table OR-pair cache (bytes).
const OR_MEM_BUDGET: usize = 4 << 20;

/// Type-tagged, length-prefixed row key so set operations compare rows exactly.
fn setRowKey(alloc: std.mem.Allocator, row: []const Value) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, row.len * 9 + 8);
    for (row) |v| {
        switch (v) {
            .null => try out.append(alloc, 0),
            .int => |x| {
                try out.append(alloc, 1);
                try out.appendSlice(alloc, &std.mem.toBytes(x));
            },
            .float => |f| {
                try out.append(alloc, 2);
                const b: u64 = @bitCast(f);
                try out.appendSlice(alloc, &std.mem.toBytes(b));
            },
            .boolean => |b| {
                try out.append(alloc, 3);
                try out.append(alloc, @intFromBool(b));
            },
            .text => |t| {
                try out.append(alloc, 4);
                const l: u32 = @intCast(t.len);
                try out.appendSlice(alloc, &std.mem.toBytes(l));
                try out.appendSlice(alloc, t);
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

pub const Engine = struct {
    gpa: std.mem.Allocator,
    /// I/O handle for statement-level file access (COPY). CLI/serve set this
    /// after construction; unit tests that never use COPY may leave it null.
    io: ?std.Io = null,
    /// Monotonic LRU tick for OR-cache entries.
    or_tick: u64 = 0,
    tables: std.StringHashMap(*Table),
    columnar: std.StringHashMap(*columnar.Table),
    /// Public tables hidden by CREATE TEMP TABLE, restored on DROP.
    shadowed_tables: std.StringHashMap(*Table),
    /// Per-table mutation versions; cached OR statistics refresh only when a
    /// table they depend on changes.
    table_ver: std.StringHashMap(u64) = undefined,
    /// Cached exact per-value counts for float columns ("name\tcol" keys),
    /// built once from the columnar image and dropped when that image is
    /// rebuilt/replaced. Avoids rescanning on every plan/DP mask.
    float_counts: std.StringHashMap(FloatCountEntry),
    /// Exact per-value counts for materialised join intermediates ("name\tcol"),
    /// so chain step estimates on a temp column are exact instead of sampled.
    temp_counts: std.StringHashMap(FloatCountEntry),
    agg_ctx: ?AggCtx = null,
    agg_exprs: []const *sql.Expr = &.{},
    // ---- transactions / WAL ------------------------------------------------
    wal: ?wal_mod.Wal = null,
    /// MVCC: per-session transaction context. The server points this at the
    /// connection's context while its statement runs; CLI mode uses the
    /// built-in one.
    /// Writes are serialised per table; engine-wide transaction bookkeeping
    /// (`in_flight`) has its own lock.
    txn_lock: SpinLock = .{},
    default_txn: TxnCtx = .{},
    next_txid: u64 = 1,
    /// Number of sessions with an open transaction: while > 0 every query uses
    /// the row engine so uncommitted changes never leak through the shared
    /// columnar copy.
    open_txns: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// When a background GC thread runs, eager compaction is skipped so the
    /// thread is the one reclaiming (observable in its log).
    background_gc: bool = false,
    /// Pool of per-query scratch buffers. Each query borrows one, so two
    /// concurrent statements never share mutable execution state.
    scratch_pool: std.ArrayList([]u8) = .empty,
    scratch_lock: SpinLock = .{},
    /// Guards transaction-id allocation: concurrent read-only statements run
    /// under a shared lock and still take a snapshot id.
    id_lock: SpinLock = .{},
    /// Catalog (pg_*) rows are rebuilt lazily; a spin lock keeps concurrent
    /// statements from rebuilding them at the same time, and `catalogs_fresh`
    /// lets read-only statements skip the refresh entirely so they can run
    /// under the shared lock.
    catalog_lock: SpinLock = .{},
    catalogs_fresh: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Rows mutated since the last snapshot write-back, and whether a full
    /// rewrite is required (compaction renumbered rows).
    wb_dirty: std.ArrayList(u32) = .empty,
    wb_full: bool = true,
    /// Adaptive join selectivity: per-table correction factor learned from the
    /// last executed plans (actual/estimated rows), plus a mutation counter that
    /// triggers automatic ANALYZE.
    sel_feedback: std.ArrayList(SelFeedback) = .empty,
    mut_rows: usize = 0,
    /// During VACUUM compaction: old row id -> new row id for surviving rows, so
    /// the B+ tree can be remapped incrementally instead of rebuilt.
    index_remap: ?[]const u32 = null,
    /// Observed scans per table, used to learn the expected number of future
    /// scans (`Q`) in the compaction cost model.
    scan_counts: std.ArrayList(ScanCount) = .empty,
    /// Per-process cost constants, measured on first use.
    costs_calibrated: bool = false,
    cost_scan_row: f64 = COST_SCAN_ROW_NS,
    cost_index_row: f64 = 18.0,
    cost_index_probe: f64 = 1000.0,
    /// Planner constants came from the snapshot trailer (skip the one-off
    /// microbenchmark so it cannot overwrite learned values).
    costs_restored: bool = false,
    /// Snapshot path this engine was loaded from (checkpoint target).
    snapshot_path: ?[]const u8 = null,
    /// Learned constants changed since the last trailer refresh.
    costs_dirty: bool = false,
    last_cost_save_ns: u64 = 0,
    /// Write-back cost model, learned from observed save/replay timings
    /// (EMA). Seeds only; every full/delta save and every delta replay
    /// updates them, so the merge policy adapts to the actual storage device.
    wb_write_ns_byte: f64 = 1.0,
    wb_encode_ns_row: f64 = 60.0,
    wb_replay_ns_row: f64 = 250.0,
    wb_samples: usize = 0,
    /// Learned interior-compaction rewrite cost (ns per surviving row).
    compact_row_ns: f64 = COST_COMPACT_ROW_NS,
    compact_samples: usize = 0,
    /// Number of observed full-scan timings folded into `cost_scan_row`.
    scan_samples: usize = 0,
    /// Learned per-row cost of touching one string column, split by the
    /// executor path (raw text compare vs dictionary ids). Updated from real
    /// single-string-column scans, replacing the static microbenchmark.
    cost_str_raw_row: f64 = 0.60,
    cost_str_dict_row: f64 = 0.12,
    str_samples_raw: usize = 0,
    str_samples_dict: usize = 0,
    /// Highest txid whose commits are reflected in the shared columnar copy.
    columnar_version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Txids of transactions that are still running (their writes are not
    /// visible to other snapshots).
    in_flight: std.ArrayList(u64) = .empty,
    auto_txid: u64 = 0,
    auto_snapshot: u64 = 0,
    // Prepared subquery sets for IN (SELECT ...) / EXISTS (SELECT ...).
    // Subquery / join scratch lives in thread-local storage (see `sqs`, `sqe`,
    // `corrList`, `tempTables`) so statements on different sessions never share
    // mutable state.
    /// Correlated EXISTS/IN rewritten into a hash semi/anti join.



    pub fn init(gpa: std.mem.Allocator) Engine {
        return .{
            .gpa = gpa,
            .tables = std.StringHashMap(*Table).init(gpa),
            .columnar = std.StringHashMap(*columnar.Table).init(gpa),
            .shadowed_tables = std.StringHashMap(*Table).init(gpa),
            .float_counts = std.StringHashMap(FloatCountEntry).init(gpa),
            .temp_counts = std.StringHashMap(FloatCountEntry).init(gpa),
            .table_ver = std.StringHashMap(u64).init(gpa),
        };
    }

    pub fn deinit(self: *Engine) void {
        var it = self.tables.valueIterator();
        while (it.next()) |t| t.*.destroy(self.gpa);
        self.tables.deinit();
        var sit = self.shadowed_tables.valueIterator();
        while (sit.next()) |t| t.*.destroy(self.gpa);
        self.shadowed_tables.deinit();
        var cit = self.columnar.valueIterator();
        while (cit.next()) |t| {
            t.*.destroy(self.gpa);
        }
        self.columnar.deinit();
        var fcit = self.float_counts.iterator();
        while (fcit.next()) |e| {
            e.value_ptr.map.deinit();
            self.gpa.free(e.key_ptr.*);
        }
        self.float_counts.deinit();
        var tcit = self.temp_counts.iterator();
        while (tcit.next()) |e| {
            e.value_ptr.map.deinit();
            self.gpa.free(e.key_ptr.*);
        }
        self.temp_counts.deinit();
        var tvit = self.table_ver.iterator();
        while (tvit.next()) |e| self.gpa.free(e.key_ptr.*);
        self.table_ver.deinit();
        self.default_txn.stmts.deinit(self.gpa);
        self.default_txn.undo.deinit(self.gpa);
        self.default_txn.views.deinit(self.gpa);
        self.in_flight.deinit(self.gpa);
        for (self.scratch_pool.items) |b| self.gpa.free(b);
        self.scratch_pool.deinit(self.gpa);
        self.wb_dirty.deinit(self.gpa);
        for (self.sel_feedback.items) |f| self.gpa.free(f.name);
        self.sel_feedback.deinit(self.gpa);
        for (self.scan_counts.items) |c| self.gpa.free(c.name);
        self.scan_counts.deinit(self.gpa);
        // Per-thread statement state of the calling thread.

        if (tls_temp_tables) |*m| {
            m.deinit();
            tls_temp_tables = null;
        }
        if (tls_temp_columnar) |*m| {
            m.deinit();
            tls_temp_columnar = null;
        }
    }

    fn markDirty(self: *Engine, ri: usize) void {
        self.wb_dirty.append(self.gpa, @intCast(ri)) catch {};
        self.mut_rows += 1;
        if (self.mut_rows >= 20000) {
            self.mut_rows = 0;
            self.analyzeAll();
        }
    }

    /// Automatic statistics refresh (sampled) after enough mutations.
    fn analyzeAll(self: *Engine) void {
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(self.gpa);
        var it = self.tables.iterator();
        while (it.next()) |e| {
            const nm = e.value_ptr.*.name;
            if (std.mem.startsWith(u8, nm, "pg_")) continue;
            names.append(self.gpa, nm) catch continue;
        }
        for (names.items) |nm| {
            _ = self.execAnalyze(nm) catch continue;
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] auto-analyze {d} table(s)\n", .{names.items.len});
        }
    }

    fn noteScan(self: *Engine, name: []const u8) void {
        for (self.scan_counts.items) |*c| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) {
                c.count += 1;
                return;
            }
        }
        const key = self.gpa.dupe(u8, name) catch return;
        self.scan_counts.append(self.gpa, .{ .name = key, .count = 1 }) catch {
            self.gpa.free(key);
        };
    }

    fn scansOf(self: *Engine, name: []const u8) usize {
        for (self.scan_counts.items) |c| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) return c.count;
        }
        return 0;
    }

    /// Monotonic nanosecond clock (libc, so calibration needs no `Io` handle).
    fn nowNs() u64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }

    /// Automatic cost calibration: measures this process's scan throughput and
    /// index-probe latency on a real columnar table, then publishes the
    /// coefficients to the planner (`columnar.setCosts`). Runs once per process;
    /// only a concrete table handed over by the executor is sampled.
    fn calibrateCostsFor(self: *Engine, given: ?*columnar.Table) void {
        if (self.costs_calibrated) return;
        const ct = given orelse return;
        // Widest int column in this table: the planner's scan model is per fixed-
        // width row, and int columns are the common ClickBench shape.
        var vals: []const i64 = &.{};
        for (ct.data) |d| switch (d) {
            .ints => |v| {
                if (v.len > vals.len) vals = v;
            },
            else => {},
        };
        if (vals.len < 4096) {
            if (std.c.getenv("ZHDB_DBG_CAL") != null) {
                std.debug.print("[calib] skip: nrows={d} int_rows={d}\n", .{ ct.nrows, vals.len });
            }
            return;
        }

        // Scan: mimic the executor instead of a single-column sum -- read up to
        // three fixed-width columns, apply two filter predicates, and accumulate
        // the survivors through a dependent chain (which also keeps LLVM from
        // turning this into a pure memcpy benchmark).
        var cols: [3][]const i64 = undefined;
        var ncols: usize = 0;
        for (ct.data) |d| switch (d) {
            .ints => |v| {
                if (v.len >= 4096 and ncols < cols.len) {
                    cols[ncols] = v;
                    ncols += 1;
                }
            },
            else => {},
        };
        if (ncols == 0) return;
        var n = cols[0].len;
        for (cols[0..ncols]) |c| n = @min(n, c.len);
        n = @min(n, 262_144);
        if (n < 4096) return;
        const pivot: [3]i64 = .{ cols[0][n / 2], if (ncols > 1) cols[1][n / 2] else 0, if (ncols > 2) cols[2][n / 2] else 0 };
        var scan_ns: f64 = std.math.inf(f64);
        var acc: i64 = 0;
        for (0..3) |_| {
            const t0 = nowNs();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const v0 = cols[0][i];
                if (v0 < pivot[0]) continue;
                if (ncols > 1 and cols[1][i] < pivot[1]) continue;
                acc = acc *% 31 +% v0;
                if (ncols > 1) acc +%= cols[1][i];
                if (ncols > 2) acc +%= cols[2][i];
            }
            const t1 = nowNs();
            if (std.c.getenv("ZHDB_DBG_CAL") != null) {
                std.debug.print("[calib] pass n={d} elapsed={d} ns\n", .{ n, t1 - t0 });
            }
            const per = @as(f64, @floatFromInt(@max(t1 - t0, 1))) / @as(f64, @floatFromInt(n));
            if (per < scan_ns) scan_ns = per;
        }

        // String columns: dictionary-id equality (JIT path) and raw text
        // comparison (fallback path). The planner's scan cost must not price a
        // string-heavy scan as a fixed-width one.
        var dict_s: f64 = 0;
        var raw_s: f64 = 0;
        var str_cols: usize = 0;
        var len_cnt: [3]usize = .{ 0, 0, 0 };
        var raw_c: [3]f64 = .{ 0, 0, 0 };
        var dict_c: [3]f64 = .{ 0, 0, 0 };
        for (ct.data, 0..) |d, ci2| {
            if (d != .strs) continue;
            if (str_cols >= 4) break;
            const sd = d.strs;
            if (sd.offsets.len < 2) continue;
            const sn = @min(@min(sd.offsets.len - 1, n), 65_536);
            if (sn < 4096) continue;
            var ids: []const u32 = &.{};
            if (ci2 < ct.enc.len and ct.enc[ci2] != null) ids = ct.enc[ci2].?.ids;
            const plen = sd.at(sn / 2).len;
            const bucket: usize = if (plen <= 8) 0 else if (plen <= 32) 1 else 2;
            {
                var c0: usize = 0;
                var c1: usize = 0;
                var ii: usize = 0;
                while (ii < sn) : (ii += 1) {
                    const L = sd.at(ii).len;
                    if (L <= 8) c0 += 1 else if (L <= 32) c1 += 1;
                }
                len_cnt[0] += c0;
                len_cnt[1] += c1;
                len_cnt[2] += sn - c0 - c1;
            }
            if (ids.len >= sn) {
                const pid = ids[sn / 2];
                var best = std.math.inf(f64);
                for (0..3) |_| {
                    const t0 = nowNs();
                    var jj: usize = 0;
                    while (jj < sn) : (jj += 1) {
                        if (ids[jj] == pid) acc +%= 1;
                    }
                    const t1 = nowNs();
                    const per = @as(f64, @floatFromInt(@max(t1 - t0, 1))) / @as(f64, @floatFromInt(sn));
                    if (per < best) best = per;
                }
                if (best > dict_c[bucket]) dict_c[bucket] = best;
                if (best > dict_s) dict_s = best;
            }
            const pv = sd.at(sn / 2);
            var best2 = std.math.inf(f64);
            for (0..3) |_| {
                const t0 = nowNs();
                var jj: usize = 0;
                while (jj < sn) : (jj += 1) {
                    const s2 = sd.at(jj);
                    if (s2.len == pv.len and std.mem.eql(u8, s2, pv)) acc +%= 1;
                }
                const t1 = nowNs();
                const per = @as(f64, @floatFromInt(@max(t1 - t0, 1))) / @as(f64, @floatFromInt(sn));
                if (per < best2) best2 = per;
            }
            if (best2 > raw_c[bucket]) raw_c[bucket] = best2;
            if (best2 > raw_s) raw_s = best2;
            str_cols += 1;
        }

        // Index probe: measure `lookup` on a real index of this table.
        var probe_ns: f64 = 1000.0;
        var idx_ok = false;
        for (ct.keyidx) |maybe_idx| {
            const idx = maybe_idx orelse continue;
            if (idx.keys.len == 0) continue;
            const reps: usize = 512;
            const t0 = nowNs();
            var r: usize = 0;
            while (r < reps) : (r += 1) {
                const k = idx.keys[(r *% 2654435761) % idx.keys.len];
                if (idx.lookup(k)) |_| acc +%= 1;
            }
            const t1 = nowNs();
            probe_ns = @as(f64, @floatFromInt(@max(t1 - t0, 1))) / @as(f64, @floatFromInt(reps));
            idx_ok = true;
            break;
        }

        // Force the scan/probe accumulations to stay live (they are pure loops;
        // without reading `acc` LLVM removes them and the clocks see 0 ns).
        if (acc == std.math.minInt(i64)) self.costs_calibrated = false;

        // Guard-rail: keep the sampled value inside the band where the P65
        // plan-quality calibration was validated (a single-column microbenchmark
        // can never represent a 17-column gather+fuse scan).
        // Publish the worst of the measured per-row costs (int gather, dictionary
        // equality, raw text compare) so string scans are not underpriced.
        // Weight by the observed length distribution (<=8 / 9..32 / >32).
        const tot_len = len_cnt[0] + len_cnt[1] + len_cnt[2];
        var wr: f64 = 0;
        var wd: f64 = 0;
        if (tot_len > 0) {
            for (0..3) |bi7| {
                if (len_cnt[bi7] == 0) continue;
                const w = @as(f64, @floatFromInt(len_cnt[bi7]));
                wr += w * raw_c[bi7];
                wd += w * dict_c[bi7];
            }
            wr /= @as(f64, @floatFromInt(tot_len));
            wd /= @as(f64, @floatFromInt(tot_len));
        }
        const str_weighted = @max(wr, wd);
        const str_best = @max(str_weighted, 0.0);
        const measured = @max(scan_ns, str_best);
        self.cost_scan_row = std.math.clamp(measured, 0.5, 12.0);
        self.cost_index_probe = std.math.clamp(probe_ns, 50.0, 20_000.0);
        // A matched index row still has to be gathered/decoded; P65's 25%
        // cut-over calibration put that at ~4x a sequential row.
        self.cost_index_row = self.cost_scan_row * 4.0;
        columnar.setCosts(self.cost_scan_row, self.cost_index_row, self.cost_index_probe);
        self.costs_calibrated = true;
        if (std.c.getenv("ZHDB_EXPLAIN") != null or std.c.getenv("ZHDB_DBG_CAL") != null) {
            std.debug.print("[calib] cols={d} strings={d} rows={d} sampled={d} scan_row={d:.2} ns (int={d:.2} dict_s={d:.2} dict_l={d:.2} raw_s={d:.2} raw_l={d:.2}) index_row={d:.2} ns probe={d:.0} ns idx={s}\n", .{
                ncols, str_cols, vals.len, n, self.cost_scan_row, scan_ns, dict_s, dict_c[2], raw_s, raw_c[2],
                self.cost_index_row, self.cost_index_probe,
                if (idx_ok) "measured" else "default",
            });
        }
    }

    /// Learned correction factor for a join input (clamped to a sane range).
    fn selCorrection(self: *Engine, table: []const u8) f64 {
        for (self.sel_feedback.items) |f| {
            if (std.ascii.eqlIgnoreCase(f.name, table)) return std.math.clamp(f.factor, 0.001, 1000.0);
        }
        return 1.0;
    }

    /// Record actual/estimated rows for a join step (EMA over runs).
    fn recordJoinFeedback(self: *Engine, table: []const u8, est: f64, actual: usize) void {
        if (est <= 0) return;
        // Multiplicative correction: `est` already includes the current factor,
        // so scaling by actual/est converges without oscillating.
        const ratio = std.math.clamp(@as(f64, @floatFromInt(actual)) / est, 0.01, 100.0);
        for (self.sel_feedback.items) |*f| {
            if (std.ascii.eqlIgnoreCase(f.name, table)) {
                f.factor = std.math.clamp(f.factor * ratio, 0.001, 1000.0);
                return;
            }
        }
        const key = self.gpa.dupe(u8, table) catch return;
        self.sel_feedback.append(self.gpa, .{ .name = key, .factor = ratio }) catch {
            self.gpa.free(key);
        };
    }

    /// Borrow a scratch buffer with at least `need` bytes (best fit).
    fn borrowScratch(self: *Engine, need: usize) []u8 {
        self.scratch_lock.lock();
        var best: ?usize = null;
        for (self.scratch_pool.items, 0..) |b, i| {
            if (b.len < need) continue;
            if (best == null or b.len < self.scratch_pool.items[best.?].len) best = i;
        }
        if (best) |i| {
            const b = self.scratch_pool.swapRemove(i);
            self.scratch_lock.unlock();
            return b;
        }
        self.scratch_lock.unlock();
        return self.gpa.alloc(u8, need) catch &.{};
    }

    fn returnScratch(self: *Engine, buf: []u8) void {
        if (buf.len == 0) return;
        self.scratch_lock.lock();
        if (self.scratch_pool.items.len < 3) {
            self.scratch_pool.append(self.gpa, buf) catch {
                self.scratch_lock.unlock();
                self.gpa.free(buf);
                return;
            };
        } else {
            self.scratch_lock.unlock();
            self.gpa.free(buf);
            return;
        }
        self.scratch_lock.unlock();
    }

    fn tempTables(self: *Engine) *std.StringHashMap(*Table) {
        if (tls_temp_tables == null) tls_temp_tables = std.StringHashMap(*Table).init(self.gpa);
        return &tls_temp_tables.?;
    }

    fn tempColumnar(self: *Engine) *std.StringHashMap(*columnar.Table) {
        if (tls_temp_columnar == null) tls_temp_columnar = std.StringHashMap(*columnar.Table).init(self.gpa);
        return &tls_temp_columnar.?;
    }

    fn sqs(self: *Engine) *std.ArrayList(SubqSet) {
        _ = self;
        return &stmtState().sets;
    }

    fn sqe(self: *Engine) *std.ArrayList(SubqExists) {
        _ = self;
        return &stmtState().exists;
    }

    fn corrList(self: *Engine) *std.ArrayList(CorrPlan) {
        _ = self;
        return &stmtState().corr;
    }

    fn find(self: *Engine, name: []const u8) ?*Table {
        if (isTempName(name)) {
            if (self.tempTables().get(name)) |t| return t;
        }
        var it = self.tables.iterator();
        while (it.next()) |e| {
            if (std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) return e.value_ptr.*;
        }
        return null;
    }

    /// Create a table directly from a schema (used by the bulk loader).
    pub fn createIfMissing(self: *Engine, name: []const u8, defs: []const ColumnDef) EngineError!void {
        if (self.find(name) != null) return;
        const t = try Table.create(self.gpa, name, defs);
        try self.tables.put(t.name, t);
    }

    /// Append one already-parsed row (used by the bulk loader).
    pub fn insertRow(self: *Engine, name: []const u8, vals: []const Value) EngineError!void {
        const t = self.find(name) orelse return error.TableNotFound;
        const row = try self.gpa.alloc(Value, t.cols.len);
        for (row) |*cell| cell.* = defaultValue(.int);
        for (vals, 0..) |v, i| {
            if (i >= row.len) break;
            row[i] = try coerce(t, i, v);
        }
        const nri = try appendStoredRow(self.gpa, t, row);
        t.xmin.items[nri] = self.curTxid();
        self.gpa.free(row);
    }

    /// Build the columnar representation used by the fast execution path.
    /// Cheap consistency gate for block compaction: spot-check a few surviving
    /// rows against the old columnar image. A mismatch means the shared copy was
    /// out of sync, so the caller must re-encode from the row store.
    fn columnarMatchesRows(self: *Engine, ct: *columnar.Table, t: *Table, map: []const u32) bool {
        _ = self;
        const step: usize = @max(map.len / 4, 1);
        var ri: usize = 0;
        var checked: usize = 0;
        while (ri < map.len and checked < 5) : (ri += step) {
            const nn = map[ri];
            if (nn == 0xFFFF_FFFF) continue;
            if (nn >= t.rows.items.len) return false;
            const row = t.rows.items[nn];
            for (ct.cols, 0..) |c, ci| {
                if (ci >= row.len) return false;
                const is_nl = row[ci] == .null;
                if (ct.isNull(ci, ri) != is_nl) return false;
                if (is_nl) continue;
                switch (c.kind) {
                    .int => {
                        if (ct.data[ci] != .ints) return false;
                        const want: i64 = switch (row[ci]) {
                            .int => |v| v,
                            .float => |f| @intFromFloat(f),
                            .boolean => |b| @intFromBool(b),
                            else => return false,
                        };
                        if (ct.data[ci].ints[ri] != want) return false;
                    },
                    .float => {
                        if (ct.data[ci] != .floats) return false;
                        const want: f64 = switch (row[ci]) {
                            .float => |f| f,
                            .int => |v| @floatFromInt(v),
                            else => return false,
                        };
                        if (ct.data[ci].floats[ri] != want) return false;
                    },
                    .str => {
                        if (ct.data[ci] != .strs) return false;
                        const want = switch (row[ci]) {
                            .text => |x| x,
                            else => return false,
                        };
                        if (!std.mem.eql(u8, ct.data[ci].strs.at(ri), want)) return false;
                    },
                }
            }
            checked += 1;
        }
        return true;
    }

    const DictSemi = struct { ci: usize, mask: []const u8, negated: bool, has_null: bool, est_rows: usize };

    /// Resolve a bare `col IN (SELECT ...)` / `NOT IN` to a dictionary-id mask.
    /// Returns null when the shape is unsupported (correlated, non-string column,
    /// not dictionary-encoded), so the row engine takes over.
    /// The `IN (SELECT ...)` leaf anywhere in the predicate tree.
    fn findSemiLeaf(e: *sql.Expr) ?*sql.Expr {
        if (e.* == .in_subquery) return e;
        if (e.* == .not) return findSemiLeaf(e.not);
        if (e.* == .binary) {
            return findSemiLeaf(e.binary.lhs) orelse findSemiLeaf(e.binary.rhs);
        }
        return null;
    }

    /// Resolve a same-column predicate to a set of dictionary ids.
    /// `negated=true` means "exclude these ids" (`<>`, `NOT IN`).
    fn resolveSameColIds(
        self: *Engine,
        alloc: std.mem.Allocator,
        tname: []const u8,
        ct: *columnar.Table,
        ci: usize,
        e: *sql.Expr,
        ids: *std.ArrayList(i64),
        negated: *bool,
        has_null_lit: *bool,
    ) bool {
        switch (e.*) {
            .binary => |b| {
                var lit: ?[]const u8 = null;
                if (b.rhs.* == .string) {
                    lit = b.rhs.string;
                } else if (b.lhs.* == .string) {
                    lit = b.lhs.string;
                } else return false;
                const col_left = self.tableColOf(tname, b.lhs);
                const col = col_left orelse self.tableColOf(tname, b.rhs) orelse return false;
                if (col != ci) return false;
                const enc = ct.enc[ci].?;
                const sd = ct.data[ci].strs;
                if (b.op == .eq or b.op == .neq) {
                    const id = dictIdOf(ct, ci, lit.?);
                    if (id >= 0) ids.append(self.gpa, id) catch {};
                    negated.* = b.op == .neq;
                    return true;
                }
                // Range on the same dictionary column: collect every id whose
                // value satisfies the predicate (normalised to col OP lit).
                var op = b.op;
                if (col_left == null) op = flipCmp(op);
                if (op != .lt and op != .le and op != .gt and op != .ge) return false;
                for (enc.first, 0..) |row, k| {
                    const ord = std.mem.order(u8, sd.at(row), lit.?);
                    const hit = switch (op) {
                        .lt => ord == .lt,
                        .le => ord != .gt,
                        .gt => ord == .gt,
                        .ge => ord != .lt,
                        else => false,
                    };
                    if (hit) ids.append(self.gpa, @intCast(k)) catch {};
                }
                negated.* = false;
                return true;
            },
            .in_subquery => |x| {
                // Nested `s IN (SELECT ...)`: resolve the subquery result too.
                const col = self.tableColOf(tname, x.operand) orelse return false;
                if (col != ci) return false;
                checkSubqueryScope(x.sub) catch return false;
                const res = self.execSelect(alloc, x.sub, false) catch return false;
                if (res.columns.len == 0) return false;
                for (res.rows) |r| {
                    if (r[0] != .text) continue;
                    const id = dictIdOf(ct, ci, r[0].text);
                    if (id >= 0) ids.append(self.gpa, id) catch {};
                }
                negated.* = x.negated;
                return true;
            },
            .in_list => |l| {
                const col = self.tableColOf(tname, l.operand) orelse return false;
                if (col != ci) return false;
                for (l.items) |it| {
                    if (it.* == .null_lit) {
                        has_null_lit.* = true;
                        continue;
                    }
                    if (it.* != .string) return false;
                    const id = dictIdOf(ct, ci, it.string);
                    if (id >= 0) ids.append(self.gpa, id) catch {};
                }
                negated.* = l.negated;
                return true;
            },
            else => return false,
        }
    }

    /// Apply an id set to a mask copy: positive sets **intersect** (so several
    /// predicates on the same column compose), negative sets subtract.
    fn applyIdSet(mask: []u8, ids: []const i64, negated: bool, first_positive: *bool) void {
        if (negated) {
            for (ids) |id| {
                if (id >= 0 and @as(usize, @intCast(id)) < mask.len) mask[@intCast(id)] = 0;
            }
            return;
        }
        if (first_positive.*) {
            first_positive.* = false;
            @memset(mask, 0);
            for (ids) |id| {
                if (id >= 0 and @as(usize, @intCast(id)) < mask.len) mask[@intCast(id)] = 1;
            }
            return;
        }
        var id: usize = 0;
        while (id < mask.len) : (id += 1) {
            if (mask[id] == 0) continue;
            var keep = false;
            for (ids) |k| {
                if (k >= 0 and @as(usize, @intCast(k)) == id) {
                    keep = true;
                    break;
                }
            }
            if (!keep) mask[id] = 0;
        }
    }

    /// Rows covered by a mask, from the per-id counts.
    fn maskRows(ct: *columnar.Table, ci: usize, mask: []const u8) usize {
        const enc = ct.enc[ci].?;
        if (enc.counts.len != enc.first.len) return 0;
        var n: usize = 0;
        for (mask, 0..) |m, id| {
            if (m != 0) n += enc.counts[id];
        }
        return n;
    }

    /// Estimate for an AND tree containing the semi leaf: every same-column
    /// conjunct is intersected (or subtracted) against the mask, so several
    /// predicates on the joined column stay exact; other conjuncts scale by
    /// their selectivity.
    fn estimateSemiAndTree(
        self: *Engine,
        alloc: std.mem.Allocator,
        tname: []const u8,
        ct: *columnar.Table,
        ci: usize,
        mask: []const u8,
        e: *sql.Expr,
        leaf: *sql.Expr,
    ) usize {
        var combo: ?[]u8 = null;
        // Every positive set intersects the mask copy (never replaces it).
        var first_positive = false;
        var resid_sel: f64 = 1.0;
        var stack = std.ArrayList(*sql.Expr).empty;
        defer stack.deinit(self.gpa);
        stack.append(self.gpa, e) catch {};
        while (stack.pop()) |node| {
            if (node == leaf) continue;
            if (node.* == .binary and node.binary.op == .and_op) {
                stack.append(self.gpa, node.binary.lhs) catch {};
                stack.append(self.gpa, node.binary.rhs) catch {};
                continue;
            }
            var ids = std.ArrayList(i64).empty;
            defer ids.deinit(self.gpa);
            var negated = false;
            var has_null_lit = false;
            if (self.resolveSameColIds(alloc, tname, ct, ci, node, &ids, &negated, &has_null_lit)) {
                if (negated and has_null_lit) {
                    // `col NOT IN (..., NULL)` is never true.
                    return 0;
                }
                if (combo == null) {
                    combo = alloc.dupe(u8, mask) catch null;
                }
                if (combo) |m| applyIdSet(m, ids.items, negated, &first_positive);
                continue;
            }
            resid_sel *= self.whereSelectivity(tname, node);
        }
        const base = if (combo) |m| maskRows(ct, ci, m) else maskRows(ct, ci, mask);
        return @intFromFloat(@max(@as(f64, @floatFromInt(base)) * resid_sel, 0.0));
    }

    /// Exact same-column union for `IN (…) OR col = 'x'` / `IN (…) OR col IN (…)`.
    fn sameColUnionRows(
        self: *Engine,
        tname: []const u8,
        ct: *columnar.Table,
        ci: usize,
        mask: []const u8,
        semi_rows: usize,
        other: *sql.Expr,
    ) ?usize {
        var ids = std.ArrayList(i64).empty;
        defer ids.deinit(self.gpa);
        var negated = false;
        var has_null_lit = false;
        if (!self.resolveSameColIds(self.gpa, tname, ct, ci, other, &ids, &negated, &has_null_lit)) return null;
        const enc = ct.enc[ci].?;
        if (enc.counts.len != enc.first.len) return null;
        if (negated) {
            // `semi OR col <> x` / `semi OR col NOT IN (...)`: exact complement,
            // computed within the non-null domain that `counts` represents.
            // `col NOT IN (..., NULL)` is never TRUE: the union is just the
            // semi-join side.
            if (has_null_lit) return semi_rows;
            var total: usize = 0;
            for (enc.counts) |c| total += c;
            var excluded_outside: usize = 0;
            for (ids.items) |id| {
                if (id < 0) continue;
                const u: usize = @intCast(id);
                if (u >= mask.len or mask[u] == 0) excluded_outside += enc.counts[u];
            }
            return total - @min(excluded_outside, total);
        }
        var other_rows: usize = 0;
        var inter: usize = 0;
        for (ids.items) |id| {
            if (id < 0) continue;
            const u: usize = @intCast(id);
            other_rows += enc.counts[u];
            if (u < mask.len and mask[u] != 0) inter += enc.counts[u];
        }
        return semi_rows + other_rows - inter;
    }

    fn dictIdOf(ct: *columnar.Table, ci: usize, lit: []const u8) i64 {
        const enc = ct.enc[ci].?;
        const sd = ct.data[ci].strs;
        for (enc.first, 0..) |row, k| {
            if (std.mem.eql(u8, sd.at(row), lit)) return @intCast(k);
        }
        return -1;
    }

    /// Row count for a predicate on the *same* dictionary column as the semi
    /// join, intersected with the mask (correlation-aware; not independence).
    fn sameColCount(self: *Engine, tname: []const u8, ct: *columnar.Table, ci: usize, mask: []const u8, e: *sql.Expr) ?usize {
        const enc = ct.enc[ci].?;
        if (enc.counts.len != enc.first.len) return null;
        var count: usize = 0;
        switch (e.*) {
            .binary => |b| {
                if (b.op != .eq) return null;
                var lit: ?[]const u8 = null;
                if (b.rhs.* == .string) {
                    lit = b.rhs.string;
                } else if (b.lhs.* == .string) {
                    lit = b.lhs.string;
                } else return null;
                const col = self.tableColOf(tname, b.lhs) orelse self.tableColOf(tname, b.rhs) orelse return null;
                if (col != ci) return null;
                const id = dictIdOf(ct, ci, lit.?);
                if (id < 0 or mask[@intCast(id)] == 0) return 0;
                return enc.counts[@intCast(id)];
            },
            .in_list => |l| {
                const col = self.tableColOf(tname, l.operand) orelse return null;
                if (col != ci) return null;
                for (l.items) |it| {
                    if (it.* != .string) return null;
                    const id = dictIdOf(ct, ci, it.string);
                    if (id >= 0 and mask[@intCast(id)] != 0) count += enc.counts[@intCast(id)];
                }
                return if (l.negated) null else count;
            },
            else => return null,
        }
    }

    fn semiUnderAndExpr(e: *sql.Expr, leaf: *sql.Expr) bool {
        if (e == leaf) return true;
        if (e.* == .binary and e.binary.op == .and_op) {
            return semiUnderAndExpr(e.binary.lhs, leaf) or semiUnderAndExpr(e.binary.rhs, leaf);
        }
        return false;
    }

    fn containsLeaf(e: *sql.Expr, leaf: *sql.Expr) bool {
        if (e == leaf) return true;
        if (e.* == .not) return containsLeaf(e.not, leaf);
        if (e.* == .binary) return containsLeaf(e.binary.lhs, leaf) or containsLeaf(e.binary.rhs, leaf);
        return false;
    }

    /// Estimated rows for a predicate tree containing the semi leaf, handling
    /// AND (correlation-aware on the same dictionary column), OR
    /// (inclusion-exclusion) and NOT (complement).
    fn estimateSemiExpr(
        self: *Engine,
        tname: []const u8,
        ct: *columnar.Table,
        ci: usize,
        mask: []const u8,
        e: *sql.Expr,
        leaf: *sql.Expr,
        semi_rows: usize,
    ) usize {
        const nrows_f: f64 = @floatFromInt(@max(ct.nrows, 1));
        if (e == leaf) return semi_rows;
        if (e.* == .not) {
            const inner = self.estimateSemiExpr(tname, ct, ci, mask, e.not, leaf, semi_rows);
            return ct.nrows - @min(inner, ct.nrows);
        }
        if (e.* == .binary and e.binary.op == .or_op) {
            const lhs_has = containsLeaf(e.binary.lhs, leaf);
            const other = if (lhs_has) e.binary.rhs else e.binary.lhs;
            const semi_side = if (lhs_has) e.binary.lhs else e.binary.rhs;
            if (self.sameColUnionRows(tname, ct, ci, mask, semi_rows, other)) |union_rows| {
                // Scale by any non-semi part of the semi side (rare in practice).
                const side_rows = self.estimateSemiExpr(tname, ct, ci, mask, semi_side, leaf, semi_rows);
                const extra: f64 = if (semi_rows > 0)
                    @as(f64, @floatFromInt(side_rows)) / @as(f64, @floatFromInt(semi_rows))
                else
                    1.0;
                return @intFromFloat(@min(@as(f64, @floatFromInt(union_rows)) * extra, nrows_f));
            }
            const a = self.estimateSemiExpr(tname, ct, ci, mask, e.binary.lhs, leaf, semi_rows);
            const b = self.estimateSemiExpr(tname, ct, ci, mask, e.binary.rhs, leaf, semi_rows);
            const fa: f64 = @floatFromInt(a);
            const fb: f64 = @floatFromInt(b);
            const both = fa * fb / nrows_f;
            if (fa + fb <= nrows_f) return @intFromFloat(fa + fb - both);
            return ct.nrows;
        }
        if (e.* == .binary and e.binary.op == .and_op) {
            // If the semi leaf is directly under this AND tree, intersect all
            // same-column conjuncts (not just the first).
            if (semiUnderAndExpr(e, leaf)) {
                return self.estimateSemiAndTree(self.gpa, tname, ct, ci, mask, e, leaf);
            }
            const l_has = containsLeaf(e.binary.lhs, leaf);
            const seed = self.estimateSemiExpr(
                tname,
                ct,
                ci,
                mask,
                if (l_has) e.binary.lhs else e.binary.rhs,
                leaf,
                semi_rows,
            );
            const other = if (l_has) e.binary.rhs else e.binary.lhs;
            if (self.sameColCount(tname, ct, ci, mask, other)) |n| {
                return @min(seed, n);
            }
            const sel_o = self.whereSelectivity(tname, other);
            return @intFromFloat(@max(@as(f64, @floatFromInt(seed)) * sel_o, 0.0));
        }
        return @intFromFloat(@max(nrows_f * self.whereSelectivity(tname, e), 0.0));
    }

    fn walkSemiResiduals(
        self: *Engine,
        tname: []const u8,
        ct: *columnar.Table,
        ci: usize,
        mask: []const u8,
        e: *sql.Expr,
        skip: *sql.Expr,
        acc: *f64,
        exact: *?usize,
        semi_rows: usize,
    ) void {
        if (e.* == .binary and e.binary.op == .and_op) {
            self.walkSemiResiduals(tname, ct, ci, mask, e.binary.lhs, skip, acc, exact, semi_rows);
            self.walkSemiResiduals(tname, ct, ci, mask, e.binary.rhs, skip, acc, exact, semi_rows);
            return;
        }
        if (e == skip) return;
        if (self.sameColCount(tname, ct, ci, mask, e)) |n| {
            if (exact.* == null) {
                exact.* = n;
            } else if (semi_rows > 0) {
                acc.* *= @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(semi_rows));
            }
            return;
        }
        acc.* *= self.whereSelectivity(tname, e);
    }

    fn accumulateResidualSel(self: *Engine, table: []const u8, e: *sql.Expr, skip: *sql.Expr, acc: *f64) void {
        if (e.* == .binary and e.binary.op == .and_op) {
            self.accumulateResidualSel(table, e.binary.lhs, skip, acc);
            self.accumulateResidualSel(table, e.binary.rhs, skip, acc);
            return;
        }
        if (e == skip) return;
        acc.* *= self.whereSelectivity(table, e);
    }

    fn buildDictSemi(self: *Engine, alloc: std.mem.Allocator, ct: *columnar.Table, sel: *sql.Select, tname: []const u8) !?DictSemi {
        if (std.c.getenv("ZHDB_NO_DICT_SEMI") != null) return null;
        const w = sel.where orelse return null;
        const leaf = findSemiLeaf(w) orelse return null;
        const x = if (leaf.* == .not) leaf.not.in_subquery else leaf.in_subquery;
        const negated = if (leaf.* == .not) !x.negated else x.negated;
        const ci: usize = switch (x.operand.*) {
            .column => |name| ct.find(name),
            .column_idx => |c| c.idx,
            else => null,
        } orelse return null;
        if (ci >= ct.cols.len or ct.cols[ci].kind != .str) return null;
        if (ci >= ct.enc.len or ct.enc[ci] == null) return null;
        if (ct.data[ci] != .strs) return null;
        // Correlated subqueries need the row engine's join machinery.
        checkSubqueryScope(x.sub) catch return null;
        // Prefer the columnar executor for the subquery too: the row engine
        // materialises every base row before filtering.
        var col_res: ?columnar.QueryResult = null;
        if (x.sub.from) |sub_from| {
            if (sub_from == .table) {
                if (self.findColumnar(sub_from.table)) |sct| {
                    const need_s = sct.nrows * 48 + (1 << 20);
                    const sbuf = self.borrowScratch(need_s);
                    var scr = columnar.Scratch{ .buf = sbuf };
                    col_res = columnar.tryRunScratch(sct, alloc, x.sub, &scr) catch null;
                    self.returnScratch(sbuf);
                }
            }
        }
        const rows: []const []Value = if (col_res) |cr| blk: {
            if (cr.columns.len == 0) return null;
            break :blk cr.rows;
        } else blk2: {
            const res = try self.execSelect(alloc, x.sub, false);
            if (res.columns.len == 0) return null;
            break :blk2 res.rows;
        };
        const enc = ct.enc[ci].?;
        const sd = ct.data[ci].strs;
        const mask = try alloc.alloc(u8, enc.first.len);
        @memset(mask, 0);
        var has_null = false;
        var nset: usize = 0;
        // Value -> id once (a per-row linear dictionary search made a 500-value
        // subquery cost tens of milliseconds).
        var vmap = std.StringHashMap(u32).init(alloc);
        defer vmap.deinit();
        try vmap.ensureTotalCapacity(@intCast(enc.first.len));
        for (enc.first, 0..) |row, k| {
            try vmap.put(sd.at(row), @intCast(k));
        }
        for (rows) |r| {
            if (r[0] == .null) {
                has_null = true;
                continue;
            }
            const val = switch (r[0]) {
                .text => |t| t,
                else => return null,
            };
            const id = vmap.get(val) orelse continue;
            if (mask[id] == 0) {
                mask[id] = 1;
                nset += 1;
            }
        }
        // Exact row estimate from per-id counts when available.
        var est: usize = 0;
        if (enc.counts.len == enc.first.len) {
            for (mask, 0..) |m2, id| {
                if (m2 != 0) est += enc.counts[id];
            }
        } else {
            const n: usize = ct.nrows;
            est = if (enc.first.len > 0) nset * n / enc.first.len else 0;
        }
        // Estimate the combined predicate (correlation-aware on the same column).
        const semi_rows = est;
        if (semiUnderAndExpr(w, leaf)) {
            est = self.estimateSemiAndTree(alloc, tname, ct, ci, mask, w, leaf);
        } else {
            est = self.estimateSemiExpr(tname, ct, ci, mask, w, leaf, semi_rows);
        }
        const resid_sel: f64 = if (semi_rows > 0)
            @as(f64, @floatFromInt(est)) / @as(f64, @floatFromInt(semi_rows))
        else
            1.0;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] semi dict-bind col={d} ndv={d} set_ids={d} resid_sel={d:.3} est_rows={d} negated={} has_null={}\n", .{
                ci, enc.first.len, nset, resid_sel, est, negated, has_null,
            });
        }
        return .{ .ci = ci, .mask = mask, .negated = negated, .has_null = has_null, .est_rows = est };
    }

    /// Drop a columnar copy (used when a rebuild fails: the row engine remains
    /// authoritative and queries stay correct, just without the JIT path).
    fn dropColumnar(self: *Engine, name: []const u8) void {
        self.dropFloatCounts(name);
        if (self.columnar.fetchRemove(name)) |kv| kv.value.destroy(self.gpa);
    }

    /// Bench-only: release the row store after the columnar image is built, so
    /// large in-memory loads do not keep both representations resident. The
    /// columnar image keeps its own row count; row-based fallbacks are not
    /// available in this mode (used to measure columnar workloads without swap).
    pub fn dropRowsForBench(self: *Engine, name: []const u8) void {
        const t = self.find(name) orelse return;
        if (!t.rows_shared_dummy) for (t.rows.items) |r| self.gpa.free(r);
        t.rows.clearAndFree(self.gpa);
        if (t.xmin.items.len > 0) t.xmin.clearAndFree(self.gpa);
        if (t.xmax.items.len > 0) t.xmax.clearAndFree(self.gpa);
    }

    /// Bench-only: give the planner the real row count after a columnar-only
    /// load by filling the row array with aliases of one dummy row. All query
    /// data comes from the columnar image; row fallbacks must not be used.
    pub fn fillDummyRowsForBench(self: *Engine, name: []const u8, n: usize) void {
        const t = self.find(name) orelse return;
        const row = self.gpa.alloc(Value, t.cols.len) catch return;
        for (row) |*v| v.* = .{ .int = 0 };
        t.rows.ensureTotalCapacity(self.gpa, n) catch return;
        var i: usize = 0;
        while (i < n) : (i += 1) t.rows.appendAssumeCapacity(row);
        t.rows_shared_dummy = true;
        t.xmin.resize(self.gpa, n) catch return;
        @memset(t.xmin.items, 0);
        t.xmax.resize(self.gpa, n) catch return;
        @memset(t.xmax.items, 0);
    }

    /// Install a columnar image produced by the streaming loader (no row store).
    pub fn installColumnarForLoad(self: *Engine, name: []const u8, ct: *columnar.Table) !void {
        if (self.columnar.fetchRemove(name)) |kv| {
            kv.value.destroy(self.gpa);
            self.gpa.free(kv.key);
        }
        try self.columnar.put(try self.gpa.dupe(u8, name), ct);
        self.wb_full = true;
    }

    pub fn buildColumnar(self: *Engine, name: []const u8) EngineError!void {
        self.buildColumnarInner(name) catch |e| {
            // Never leave a stale image behind (row ids may have been renumbered).
            self.dropColumnar(name);
            return e;
        };
    }

    fn buildColumnarInner(self: *Engine, name: []const u8) EngineError!void {
        const t = self.find(name) orelse return error.TableNotFound;
        // A rebuild replaces the columnar image, so the persisted base must be
        // rewritten on the next save.
        self.wb_full = true;
        const cols = try self.gpa.alloc(columnar.Column, t.cols.len);
        defer self.gpa.free(cols);
        for (t.cols, 0..) |c, i| {
            cols[i] = .{ .name = c.name, .kind = switch (c.ty) {
                .int, .boolean => .int,
                .float => .float,
                .text, .date, .timestamp => .str,
            } };
        }
        if (isTempName(t.name)) {
            const ct_tmp = try columnar.Table.buildWithNulls(self.gpa, cols, t.rows.items, t.nulls);
            const tc = self.tempColumnar();
            if (tc.getPtr(t.name)) |slot| {
                const old = @atomicLoad(*columnar.Table, slot, .acquire);
                @atomicStore(*columnar.Table, slot, ct_tmp, .release);
                old.destroy(self.gpa);
            } else {
                try tc.put(try self.gpa.dupe(u8, t.name), ct_tmp);
            }
            return;
        }
        // Build straight from the row store; NULLs come from its validity
        // bitmap, so no materialised copy of the rows is needed. Dead MVCC
        // versions and tombstoned rows are excluded.
        // Row ids must stay aligned with the row store (free-slot reuse relies on
        // it): build over *all* slots and carry the tombstone bits over. Dead
        // slots are excluded by the columnar path's tombstone filter.
        // Physical block reclaim: after a compaction the row store carries the
        // survivor renumbering (`index_remap`), so the columnar image can be
        // rebuilt block-by-block -- live blocks memcpy'd, fully dead blocks
        // dropped anywhere in the middle, partial blocks rewritten. Only when the
        // old image provably matches the row store; otherwise fall back to the
        // full encode from rows.
        const ct = blk: {
            if (self.index_remap) |map| {
                if (self.findColumnar(t.name)) |old_ct| {
                    if (old_ct.nrows == map.len and old_ct.cols.len == cols.len and
                        old_ct.nrows > 0 and self.columnarMatchesRows(old_ct, t, map))
                    {
                        var kinds_ok = true;
                        for (old_ct.cols, cols) |oc, nc| {
                            if (oc.kind != nc.kind) {
                                kinds_ok = false;
                                break;
                            }
                        }
                        if (kinds_ok) {
                            if (old_ct.compactBlocks(self.gpa, map)) |nct| break :blk nct else |_| {}
                        }
                    }
                }
            }
            break :blk try columnar.Table.buildWithNulls(self.gpa, cols, t.rows.items, t.nulls);
        };
        for (t.cols) |c| {
            if (c.ty == .boolean) ct.has_bool = true;
            if (c.int_bits != 0) ct.has_int2 = true;
            if (c.is_macaddr or c.is_lseg or c.is_path) ct.has_int2 = true;
        }
        if (t.rows.items.len > 0) {
            const ka = ct.arena.allocator();
            const words = (ct.nrows + 7) / 8;
            const bits = try ka.alloc(u8, words);
            @memset(bits, 0);
            var dead_count: usize = 0;
            for (t.rows.items, 0..) |_, ri| {
                const xm: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
                const dead = isRowDeleted(t, ri) or (xm != 0 and !self.isInFlight(xm));
                if (dead) {
                    bits[ri / 8] |= @as(u8, 1) << @intCast(ri % 8);
                    dead_count += 1;
                }
            }
            // No dead rows: leave `tomb` null so queries keep the untombed fast
            // path (the tombstone check costs a pass over every selection).
            if (dead_count > 0) ct.tomb = bits;
        }
        // CREATE INDEX survives DML: rebuild the indexes the previous columnar
        // version carried for this table.
        if (self.findColumnar(t.name)) |old| {
            if (old.keyidx.len > 0) {
                const ka = ct.arena.allocator();
                ct.keyidx = try ka.alloc(?*columnar.KeyIndex, ct.cols.len);
                @memset(ct.keyidx, null);
                for (old.keyidx, 0..) |maybe, ci| {
                    if (maybe == null or ci >= ct.cols.len) continue;
                    const idx = maybe.?;
                    const vals = switch (ct.data[ci]) {
                        .ints => |v| v,
                        else => continue,
                    };
                    // Incremental remap: compaction only renumbers rows, so the
                    // existing tree keeps its keys/pages and only its posting ids
                    // move through `map`. There is no rebuild fallback: on an
                    // allocation failure the index is dropped (queries stay
                    // correct via a scan) rather than rebuilt from the table.
                    if (self.index_remap) |map| {
                        if (idx.tree) |*tr_old| {
                            // Guaranteed remap: the posting remap is allocation-
                            // free (in-place per list), and the remaining small
                            // metadata allocations retry on the page allocator
                            // instead of ever dropping the index.
                            var tr = tr_old.copy(ka) catch
                                (tr_old.copy(std.heap.page_allocator) catch return error.OutOfMemory);
                            const moved = tr.remapRows(map);
                            const flat = tr.flatten(ka) catch
                                (tr.flatten(std.heap.page_allocator) catch {
                                    tr.deinit();
                                    return error.OutOfMemory;
                                });
                            const ni = ka.create(columnar.KeyIndex) catch
                                (std.heap.page_allocator.create(columnar.KeyIndex) catch {
                                    tr.deinit();
                                    return error.OutOfMemory;
                                });
                            ni.* = .{
                                .keys = flat.keys,
                                .offsets = flat.offsets,
                                .rows = flat.rows,
                                .block_rows = ct.block_rows,
                                .tree = tr,
                            };
                            ct.keyidx[ci] = ni;
                            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                                std.debug.print("[plan] index remap col={d} moved={d} keys={d}\n", .{ ci, moved, flat.keys.len });
                            }
                            continue;
                        }
                    }
                    const appended = old.nrows <= ct.nrows and idx.tree != null and old.nrows > 0;
                    if (appended) {
                        var tree = try idx.tree.?.copy(ka);
                        var ok = true;
                        var ri: usize = old.nrows;
                        while (ri < ct.nrows) : (ri += 1) {
                            tree.insert(vals[ri], @intCast(ri)) catch {
                                ok = false;
                                break;
                            };
                        }
                        if (ok) {
                            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                                std.debug.print("[plan] index append: col={d} rows {d}..{d} (incremental)\n", .{ ci, old.nrows, ct.nrows });
                            }
                            const flat = try tree.flatten(ka);
                            const ni = try ka.create(columnar.KeyIndex);
                            ni.* = .{
                                .keys = flat.keys,
                                .offsets = flat.offsets,
                                .rows = flat.rows,
                                .block_rows = ct.block_rows,
                                .tree = tree,
                            };
                            ct.keyidx[ci] = ni;
                            continue;
                        }
                        tree.deinit();
                    }
                    ct.keyidx[ci] = try columnar.KeyIndex.build(ka, vals, ct.block_rows);
                }
            }
        }
        // Replace the entry *in place*: a DML on table A rebuilds only A's
        // columnar copy, and must not restructure the catalog map while another
        // session is looking up table B (that would be a concurrent HashMap
        // write). The pointer itself is swapped atomically.
        self.dropFloatCounts(t.name);
        if (self.columnar.getPtr(t.name)) |slot| {
            const old = @atomicLoad(*columnar.Table, slot, .acquire);
            @atomicStore(*columnar.Table, slot, ct, .release);
            old.destroy(self.gpa);
        } else {
            try self.columnar.put(t.name, ct);
        }
        self.id_lock.lock();
        if (self.next_txid > 0) self.columnar_version.store(self.next_txid - 1, .release);
        self.id_lock.unlock();
    }

    pub fn setTxnContext(self: *Engine, ctx: *TxnCtx) void {
        _ = self;
        tls_txn = ctx;
    }

    pub fn resetTxnContext(self: *Engine) void {
        _ = self;
        tls_txn = null;
    }

    fn txnCtx(self: *Engine) *TxnCtx {
        return tls_txn orelse &self.default_txn;
    }

    fn inTxn(self: *Engine) bool {
        return self.txnCtx().in_txn;
    }

    fn snap(self: *Engine) u64 {
        const t = self.txnCtx();
        return if (t.in_txn) t.snapshot else self.auto_snapshot;
    }

    fn curTxid(self: *Engine) u64 {
        const t = self.txnCtx();
        return if (t.in_txn) t.txid else self.auto_txid;
    }

    pub fn openWal(self: *Engine, path: []const u8) void {
        self.wal = wal_mod.Wal.init(path);
    }

    /// Replay committed statements onto the current (snapshot) state.
    pub fn replayWal(self: *Engine, io: std.Io, gpa: std.mem.Allocator) !usize {
        var w = &(self.wal orelse return 0);
        const bytes = try w.load(io, gpa);
        defer gpa.free(bytes);
        const stmts = try w.committed(gpa, bytes);
        defer gpa.free(stmts);
        var n: usize = 0;
        for (stmts) |text| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            var parser = sql.Parser.init(a, text) catch continue;
            const stmt = parser.parseStatement() catch continue;
            _ = self.exec(a, stmt) catch continue;
            n += 1;
        }
        // Keep the durable prefix for the next append.
        w.buf.clearRetainingCapacity();
        var pos: usize = 0;
        while (pos + 4 <= bytes.len) {
            const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            pos += 4;
            if (len == 0) {
                try w.buf.appendSlice(gpa, bytes[0..pos]);
                continue;
            }
            if (pos + len > bytes.len) break;
            pos += len;
        }
        return n;
    }

    /// Allocate a snapshot id for an autocommit statement (thread-safe).
    fn beginAutoSnapshot(self: *Engine) void {
        self.id_lock.lock();
        const id = self.next_txid;
        self.next_txid += 1;
        self.auto_txid = id;
        self.auto_snapshot = id;
        self.id_lock.unlock();
    }

    pub fn beginTxn(self: *Engine) void {
        const t = self.txnCtx();
        t.in_txn = true;
        self.id_lock.lock();
        t.txid = self.next_txid;
        self.next_txid += 1;
        self.id_lock.unlock();
        t.snapshot = t.txid;
        t.stmts.clearRetainingCapacity();
        t.undo.clearRetainingCapacity();
        _ = self.open_txns.fetchAdd(1, .acq_rel);
        self.txn_lock.lock();
        self.in_flight.append(self.gpa, t.txid) catch {};
        self.txn_lock.unlock();
    }

    /// Record a statement for durability. Inside an explicit transaction the
    /// statement is buffered until COMMIT.
    pub fn logStmt(self: *Engine, io: std.Io, text: []const u8) !void {
        if (self.inTxn()) {
            const gpa = self.gpa;
            try self.txnCtx().stmts.append(gpa, try gpa.dupe(u8, text));
            return;
        }
        var w = &(self.wal orelse return);
        try w.appendStmt(self.gpa, text);
        try w.appendCommit(self.gpa);
        try w.flush(io);
    }

    pub fn commitTxn(self: *Engine, io: std.Io) !void {
        const ctx = self.txnCtx();
        if (!ctx.in_txn) return;
        const gpa = self.gpa;
        if (self.wal) |*w| {
            for (ctx.stmts.items) |t| try w.appendStmt(gpa, t);
            try w.appendCommit(gpa);
            try w.flush(io);
        }
        for (ctx.stmts.items) |t| gpa.free(t);
        ctx.stmts.clearRetainingCapacity();
        self.dropAllViews(ctx);
        // Our txid is no longer in flight: dead versions can be reclaimed and
        // the columnar copy rebuilt from the surviving ones.
        self.removeInFlight(ctx.txid);
        for (ctx.undo.items) |u| {
            if (!self.background_gc) self.compactTable(u.name) else self.buildColumnar(u.name) catch {};
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[plan] commit compact: {s}\n", .{u.name});
            }
            if (u.rows.len > 0) gpa.free(u.rows);
            gpa.free(u.name);
        }
        ctx.undo.clearRetainingCapacity();
        ctx.in_txn = false;
        _ = self.open_txns.fetchSub(1, .acq_rel);
        self.removeInFlight(ctx.txid);
    }

    /// Undo the in-memory changes of the current transaction.
    pub fn rollbackTxn(self: *Engine) void {
        const ctx = self.txnCtx();
        if (!ctx.in_txn) return;
        self.dropAllViews(ctx);
        const gpa = self.gpa;
        const mine = ctx.txid;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] rollback txn={d} tables={d}\n", .{ mine, ctx.undo.items.len });
        }
        for (ctx.undo.items) |u| {
            if (self.find(u.name)) |t| {
                if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                    std.debug.print("[plan] rollback table={s} rows={d} xmin={d} xmax={d}\n", .{ u.name, t.rows.items.len, t.xmin.items.len, t.xmax.items.len });
                    for (t.xmin.items, 0..) |x, i| std.debug.print("  row{d} xmin={d} xmax={d}\n", .{ i, x, if (i < t.xmax.items.len) t.xmax.items[i] else 0 });
                }
                // Restore our deletes and drop the versions we inserted.
                var ri: usize = 0;
                while (ri < t.xmax.items.len) : (ri += 1) {
                    if (t.xmax.items[ri] == mine) t.xmax.items[ri] = 0;
                }
                var w: usize = 0;
                ri = 0;
                while (ri < t.rows.items.len) : (ri += 1) {
                    if (ri < t.xmin.items.len and t.xmin.items[ri] == mine) {
                        gpa.free(t.rows.items[ri]);
                        continue;
                    }
                    t.rows.items[w] = t.rows.items[ri];
                    if (ri < t.xmin.items.len) t.xmin.items[w] = t.xmin.items[ri];
                    if (ri < t.xmax.items.len) t.xmax.items[w] = t.xmax.items[ri];
                    w += 1;
                }
                t.rows.items.len = w;
                if (t.xmin.items.len > w) t.xmin.items.len = w;
                if (t.xmax.items.len > w) t.xmax.items.len = w;
                // Rebuild tombstones from the (restored) versions.
                t.dead_rows = 0;
                t.deleted.clearRetainingCapacity();
                for (t.rows.items, 0..) |_, idx| {
                    const dead = idx < t.xmax.items.len and t.xmax.items[idx] != 0 and
                        !self.isInFlight(t.xmax.items[idx]);
                    if (dead) t.deleted.append(gpa, 1) catch break else t.deleted.append(gpa, 0) catch break;
                }
                self.buildColumnar(u.name) catch {};
            }
        }
        for (ctx.stmts.items) |t| gpa.free(t);
        ctx.stmts.clearRetainingCapacity();
        for (ctx.undo.items) |u| {
            if (u.rows.len > 0) gpa.free(u.rows);
            gpa.free(u.name);
        }
        ctx.undo.clearRetainingCapacity();
        ctx.in_txn = false;
        _ = self.open_txns.fetchSub(1, .acq_rel);
        self.removeInFlight(ctx.txid);
    }

    fn removeInFlight(self: *Engine, id: u64) void {
        self.txn_lock.lock();
        defer self.txn_lock.unlock();
        var i: usize = 0;
        while (i < self.in_flight.items.len) : (i += 1) {
            if (self.in_flight.items[i] == id) {
                _ = self.in_flight.orderedRemove(i);
                return;
            }
        }
    }

    fn isInFlight(self: *Engine, id: u64) bool {
        self.txn_lock.lock();
        defer self.txn_lock.unlock();
        for (self.in_flight.items) |x| {
            if (x == id) return true;
        }
        return false;
    }

    /// MVCC visibility for the current snapshot (uncommitted writes of other
    /// sessions stay invisible; our own writes are visible).
    fn visibleRow(self: *Engine, t: *const Table, ri: usize) bool {
        const horizon = self.snap();
        const mine = self.curTxid();
        const lo: u64 = if (ri < t.xmin.items.len) t.xmin.items[ri] else 0;
        if (lo != 0 and lo != mine) {
            if (lo > horizon) return false;
            if (self.isInFlight(lo)) return false;
        }
        const hi: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
        if (hi != 0) {
            if (hi == mine) return false;
            if (hi <= horizon and !self.isInFlight(hi)) return false;
            if (hi > horizon) return true;
        }
        return true;
    }

    /// Snapshot a table's row pointers the first time it is modified in a txn.
    fn txSnapshot(self: *Engine, gpa: std.mem.Allocator, name: []const u8) !void {
        if (!self.inTxn()) return;
        _ = gpa;
        const g = self.gpa;
        const ctx = self.txnCtx();
        for (ctx.undo.items) |u| if (std.ascii.eqlIgnoreCase(u.name, name)) return;
        const t = self.find(name) orelse return;
        const copy = try g.dupe([]Value, t.rows.items);
        try ctx.undo.append(g, .{ .name = try g.dupe(u8, name), .rows = copy });
    }

    /// Adopt an already-materialised columnar table (snapshot load).
    pub fn adoptColumnar(self: *Engine, name: []const u8, t: *columnar.Table) !void {
        self.dropFloatCounts(name);
        if (self.columnar.getPtr(name)) |slot| {
            const old = @atomicLoad(*columnar.Table, slot, .acquire);
            @atomicStore(*columnar.Table, slot, t, .release);
            old.destroy(self.gpa);
            return;
        }
        const key = try self.gpa.dupe(u8, name);
        try self.columnar.put(key, t);
    }

    pub fn columnarTable(self: *Engine, name: []const u8) ?*columnar.Table {
        return self.findColumnar(name);
    }

    /// True when a table exists only as a columnar snapshot and its row store
    /// has not been materialised yet (first access would mutate it).
    pub fn isLazy(self: *Engine, name: []const u8) bool {
        const t = self.find(name) orelse return false;
        if (t.rows.items.len > 0) return false;
        const ct = self.findColumnar(name) orelse return false;
        return ct.nrows > 0;
    }

    /// Materialise a lazy snapshot table (caller must hold the exclusive lock).
    pub fn materialize(self: *Engine, name: []const u8) void {
        self.ensureRowsMaterialized(name);
    }

    /// Row count of a table, or null when it does not exist. Used by the server
    /// to decide whether a statement can run under shared locks (lazy snapshot
    /// tables materialise on first read, which mutates them).
    pub fn rowCount(self: *Engine, name: []const u8) ?usize {
        if (isTempName(name)) {
            const t = self.tempTables().get(name) orelse return null;
            return t.rows.items.len;
        }
        const t = self.find(name) orelse return null;
        return t.rows.items.len;
    }

    fn findColumnar(self: *Engine, name: []const u8) ?*columnar.Table {
        if (isTempName(name)) {
            if (self.tempColumnar().get(name)) |t| return t;
        }
        var it = self.columnar.iterator();
        while (it.next()) |e| {
            // Atomic: another session may rebuild this table's columnar copy
            // concurrently (the map itself is not restructured).
            if (std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) {
                return @atomicLoad(*columnar.Table, e.value_ptr, .acquire);
            }
        }
        return null;
    }

    fn verifyNulls(self: *Engine) void {
        if (std.c.getenv("ZHDB_VERIFY") == null) return;
        var it = self.tables.iterator();
        while (it.next()) |e| {
            const t = e.value_ptr.*;
            // Invariant: stored cells never carry Value.null; NULL lives only in
            // the validity bitmap.
            for (t.rows.items, 0..) |row, ri| {
                var ci: usize = 0;
                while (ci < t.cols.len) : (ci += 1) {
                    if (row[ci] == .null) {
                        std.debug.print("[verify] stored null payload table={s} row={d} col={d}\n", .{ t.name, ri, ci });
                    }
                }
            }
            // Cross-check the row bitmap against the columnar validity bitmap.
            if (self.findColumnar(t.name)) |ct| {
                if (ct.nrows == t.rows.items.len) {
                    for (t.rows.items, 0..) |_, ri| {
                        var ci: usize = 0;
                        while (ci < t.cols.len) : (ci += 1) {
                            const a = tableIsNull(t, ci, ri);
                            const b = ct.isNull(ci, ri);
                            if (a != b) {
                                std.debug.print("[verify] row/columnar null mismatch table={s} row={d} col={d} row_null={} col_null={}\n", .{ t.name, ri, ci, a, b });
                            }
                        }
                    }
                }
            }
        }
    }

    /// Rewrite `alias.col` to `table.col` in a select's expressions, so every
    /// planner path (`tableColOf`, `keyPred`, pushdown, columnar lint) works the
    /// same with and without a table alias.
    fn rewriteAliasExpr(alloc: std.mem.Allocator, e: *sql.Expr, alias: []const u8, table: []const u8) void {
        switch (e.*) {
            .column => |name| {
                if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                    if (dot > 0 and std.ascii.eqlIgnoreCase(name[0..dot], alias)) {
                        const n = std.fmt.allocPrint(alloc, "{s}.{s}", .{ table, name[dot + 1 ..] }) catch return;
                        e.* = .{ .column = n };
                    }
                }
            },
            .binary => |b| {
                rewriteAliasExpr(alloc, b.lhs, alias, table);
                rewriteAliasExpr(alloc, b.rhs, alias, table);
            },
            .negate => |x| rewriteAliasExpr(alloc, x, alias, table),
            .not => |x| rewriteAliasExpr(alloc, x, alias, table),
            .is_null => |x| rewriteAliasExpr(alloc, x.operand, alias, table),
            .like => |x| {
                rewriteAliasExpr(alloc, x.operand, alias, table);
                rewriteAliasExpr(alloc, x.pattern, alias, table);
            },
            .in_list => |x| {
                rewriteAliasExpr(alloc, x.operand, alias, table);
                for (x.items) |it| rewriteAliasExpr(alloc, it, alias, table);
            },
            .between => |x| {
                rewriteAliasExpr(alloc, x.operand, alias, table);
                rewriteAliasExpr(alloc, x.low, alias, table);
                rewriteAliasExpr(alloc, x.high, alias, table);
            },
            .call => |c| for (c.args) |a| rewriteAliasExpr(alloc, a, alias, table),
            .case_expr => |c| {
                for (c.whens) |w| {
                    rewriteAliasExpr(alloc, w.cond, alias, table);
                    rewriteAliasExpr(alloc, w.then, alias, table);
                }
                if (c.else_expr) |x| rewriteAliasExpr(alloc, x, alias, table);
            },
            .cast => |x| rewriteAliasExpr(alloc, x.operand, alias, table),
            else => {},
        }
    }

    fn rewriteAliases(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select) void {
        const from_table: ?[]const u8 = switch (sel.from orelse return) {
            .table => |n| n,
            .subquery => |sub| blk: {
                self.rewriteAliases(alloc, sub);
                break :blk null;
            },
            .function => null,
            .values => null,
        };
        // A self-join (`FROM t a JOIN t b`) must keep its two aliases: rewriting
        // both to `t` would make the predicate indistinguishable between the
        // sides. The planner resolves aliases directly in that case.
        const self_join = if (sel.join) |j| (from_table != null and
            std.ascii.eqlIgnoreCase(j.table, from_table.?)) else false;
        if (self_join) return;
        if (sel.alias) |al| {
            if (from_table) |tn| rewriteSelectExprs(alloc, sel, al, tn);
        }
        // Join aliases also appear in the WHERE/select list, not just in ON.
        if (sel.join) |j| {
            if (j.alias) |al| rewriteSelectExprs(alloc, sel, al, j.table);
        }
        for (sel.more_joins) |j| {
            if (j.alias) |al| rewriteSelectExprs(alloc, sel, al, j.table);
        }
    }

    fn rewriteSelectExprs(alloc: std.mem.Allocator, sel: *sql.Select, al: []const u8, tn: []const u8) void {
        for (sel.items) |it| rewriteAliasExpr(alloc, it.expr, al, tn);
        if (sel.where) |w| rewriteAliasExpr(alloc, w, al, tn);
        if (sel.having) |h| rewriteAliasExpr(alloc, h, al, tn);
        for (sel.group_by) |g| rewriteAliasExpr(alloc, g, al, tn);
        for (sel.order_by) |o| rewriteAliasExpr(alloc, o.expr, al, tn);
        if (sel.join) |j| rewriteAliasExpr(alloc, j.on, al, tn);
        for (sel.more_joins) |j| rewriteAliasExpr(alloc, j.on, al, tn);
    }

    /// Resolve `GROUP BY <select alias>` and `GROUP BY <ordinal>` to the
    /// select-list expression. PostgreSQL allows both forms; the planners below
    /// only understand column names and expressions.
    fn expandGroupAliases(sel: *sql.Select) void {
        for (sel.group_by) |g| {
            if (g.* == .column) {
                const nm = g.column;
                // Only bare names can be aliases; `t.col` stays a column ref.
                if (std.mem.indexOfScalar(u8, nm, '.') != null) continue;
                for (sel.items) |it| {
                    const al = it.alias orelse continue;
                    if (std.ascii.eqlIgnoreCase(al, nm)) {
                        g.* = it.expr.*;
                        break;
                    }
                }
            } else if (g.* == .int) {
                const idx = g.int;
                if (idx >= 1 and idx <= @as(i64, @intCast(sel.items.len))) {
                    g.* = sel.items[@intCast(idx - 1)].expr.*;
                }
            }
        }
    }

    pub fn exec(self: *Engine, alloc: std.mem.Allocator, stmt: sql.Stmt) EngineError!Result {
        tls_diag_len = 0;
        self.verifyNulls();
        // Autocommit statements run under a fresh snapshot; explicit
        // transactions keep the one taken at BEGIN.
        if (!self.inTxn()) self.beginAutoSnapshot();
        return switch (stmt) {
            .select => |s| blk: {
                // `FROM t alias` predicates are normalised to `t.col` once, so
                // every planner path sees the same column names.
                self.rewriteAliases(alloc, s);
                expandGroupAliases(s);
                if (s.from) |f| {
                    if (f == .table and std.mem.startsWith(u8, f.table, "pg_")) self.refreshCatalogIfNeeded();
                }
                if (s.from) |f| {
                    // A JOIN must go through the join executor, not the single-
                    // table columnar fast path.
                    // A read-only transaction may use the shared columnar copy when
                    // its snapshot already covers every commit it reflects.
                    // A written table uses this transaction's private columnar
                    // view (its own snapshot + writes); a clean one may use the
                    // shared copy when its snapshot covers every commit.
                    // Only build a private view for aggregate/group-by shapes:
                    // for plain projections the row engine is already fast and
                    // the one-off O(n) view build would be wasted work.
                    const dirty = self.inTxn() and self.txnWrote(f.table) and selWantsView(s);
                    // Another transaction may be overlaying its uncommitted
                    // changes on the shared copy: it is not ours to read.
                    const shared_ct = self.findColumnar(f.table);
                    const foreign_delta = if (shared_ct) |ct|
                        (ct.delta_owner != 0 and ct.delta_owner != self.curTxid())
                    else
                        false;
                    const txn_clean = (!self.inTxn() or (self.snap() >= self.columnar_version.load(.acquire) and !dirty)) and !foreign_delta;
                    const base_ct = shared_ct;
                    const delta_ok = if (base_ct) |ct|
                        (ct.delta_owner == self.curTxid() and !ct.delta_inserts)
                    else
                        false;
                    const view_ct: ?*columnar.Table = if (dirty and !delta_ok)
                        (self.txnViewGet(f.table) orelse (self.txnViewBuild(f.table) catch null))
                    else if (dirty)
                        base_ct
                    else
                        null;
                    if ((txn_clean or view_ct != null) and (self.open_txns.load(.acquire) == 0 or self.inTxn()) and f == .table and s.join == null) {
                        self.noteScan(f.table);
                        if (view_ct orelse self.findColumnar(f.table)) |ct| {
                            self.calibrateCostsFor(ct);
                            const need = ct.nrows * 48 + (1 << 20);
                            const sbuf = self.borrowScratch(need);
                            var scr = columnar.Scratch{ .buf = sbuf };
                            defer self.returnScratch(sbuf);
                            const has_index = blk2: {
                                for (ct.keyidx) |mi| {
                                    if (mi != null) break :blk2 true;
                                }
                                break :blk2 false;
                            };
                            // `s IN (SELECT ...)` on a dictionary-encoded column:
                            // resolve the subquery result to ids once, so the scan
                            // filters by dense id membership.
                            const semi = self.buildDictSemi(alloc, ct, s, f.table) catch null;
                            if (semi) |m| {
                                columnar.setSemiEstimate(m.est_rows);
                                columnar.setSemi(m.ci, m.mask, m.negated, m.has_null);
                            }
                            defer columnar.clearSemi();
                            const ts0 = nowNs();
                            if (columnar.tryRunScratch(ct, alloc, s, &scr) catch null) |r| {
                                const ts1 = nowNs();
                                if (!has_index and ct.nrows >= 10_000 and ts1 > ts0) {
                                    const per = @as(f64, @floatFromInt(ts1 - ts0)) / @as(f64, @floatFromInt(ct.nrows));
                                    const shape = columnar.queryStrShape();
                                    if (per > 0.05 and per < 500.0) {
                                        if (shape.nstr == 0) {
                                            // Pure fixed-width scan: learns the base per-row cost.
                                            if (self.scan_samples == 0) {
                                                // First observed scan: use it directly instead
                                                // of the synthetic calibration seed.
                                                self.cost_scan_row = std.math.clamp(per, 0.3, 12.0);
                                            } else {
                                                const alpha: f64 = if (self.scan_samples < 8) 0.3 else 0.1;
                                                self.cost_scan_row = std.math.clamp((1.0 - alpha) * self.cost_scan_row + alpha * per, 0.3, 12.0);
                                            }
                                            self.scan_samples += 1;
                                            self.costs_dirty = true;
                                            columnar.setCosts(self.cost_scan_row, self.cost_index_row, self.cost_index_probe);
                                            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                                                std.debug.print("[calib] scan timing rows={d} ns/row={d:.2} (ema {d:.2})\n", .{ ct.nrows, per, self.cost_scan_row });
                                            }
                                        } else if (shape.nstr == 1 and s.where != null) {
                                            // One string column + a predicate: attribute the
                                            // *marginal* per-row time (total minus the base
                                            // fixed-width row cost) to that string column, so
                                            // scan_cost = rows x (base + nstr x str) does not
                                            // double count.
                                            const marginal = @max(per - self.cost_scan_row, 0.03);
                                            const old_v = if (shape.dict) self.cost_str_dict_row else self.cost_str_raw_row;
                                            const cnt = if (shape.dict) self.str_samples_dict else self.str_samples_raw;
                                            const nv = if (cnt == 0)
                                                std.math.clamp(marginal, 0.03, 20.0)
                                            else blk3: {
                                                const alpha: f64 = if (cnt < 4) 0.5 else 0.2;
                                                break :blk3 std.math.clamp((1.0 - alpha) * old_v + alpha * marginal, 0.03, 20.0);
                                            };
                                            if (shape.dict) {
                                                self.cost_str_dict_row = nv;
                                                self.str_samples_dict += 1;
                                            } else {
                                                self.cost_str_raw_row = nv;
                                                self.str_samples_raw += 1;
                                            }
                                            self.costs_dirty = true;
                                            columnar.setStrCosts(self.cost_str_raw_row, self.cost_str_dict_row);
                                            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                                                std.debug.print("[calib] str timing rows={d} path={s} total={d:.2} ns/row marginal={d:.2} ns/col/row (ema raw={d:.2} dict={d:.2})\n", .{
                                                    ct.nrows, if (shape.dict) "dict" else "raw", per, marginal,
                                                    self.cost_str_raw_row, self.cost_str_dict_row,
                                                });
                                            }
                                        }
                                    }
                                }
                                break :blk .{
                                    .columns = r.columns,
                                    .rows = r.rows,
                                    .affected = r.affected,
                                    .format_json = r.format_json,
                                };
                            }
                        }
                    }
                }
                break :blk self.execSelect(alloc, s, true);
            },
            .create_table => |c| blk: {
                self.invalidateCatalogs();
                break :blk self.execCreate(alloc, c);
            },
            .drop_table => |d| blk: {
                self.invalidateCatalogs();
                break :blk self.execDrop(d);
            },
            .insert => |ins| self.execInsert(alloc, ins),
            .insert_select => |ins| self.execInsertSelect(alloc, ins),
            .copy => |cp| self.execCopy(alloc, cp),
            .delete => |d| self.execDelete(alloc, d),
            .update => |u| self.execUpdate(alloc, u),
            .analyze => |name| self.execAnalyze(name),
            .create_index => |ci| self.execCreateIndex(ci.name, ci.table, ci.col),
            .vacuum => |name| self.execVacuum(name),
            .truncate => |name| blk: {
                const t = self.find(name) orelse return error.TableNotFound;
                const n = t.rows.items.len;
                if (!t.rows_shared_dummy) for (t.rows.items) |r| self.gpa.free(r);
                t.rows.clearRetainingCapacity();
                _ = t.arena.reset(.retain_capacity);
                break :blk .{ .affected = n };
            },
            .noop => .{},
        };
    }

    fn execCreate(self: *Engine, alloc: std.mem.Allocator, c: anytype) EngineError!Result {
        if (self.find(c.name)) |old| {
            if (c.temp) {
                var it = self.tables.iterator();
                while (it.next()) |e| {
                    if (std.ascii.eqlIgnoreCase(e.key_ptr.*, c.name)) {
                        const key = e.key_ptr.*;
                        _ = self.tables.remove(key);
                        self.dropColumnar(c.name);
                        if (self.shadowed_tables.get(c.name) == null) {
                            self.shadowed_tables.put(key, old) catch {};
                        } else {
                            old.destroy(self.gpa);
                        }
                        break;
                    }
                }
            } else if (c.if_not_exists) {
                return .{};
            } else {
                return error.TableExists;
            }
        }
        var defs = c.cols;
        if (c.inherits.len > 0) {
            var merged = std.ArrayList(ColumnDef).empty;
            defer merged.deinit(alloc);
            for (c.inherits) |pname| {
                const parent = self.find(pname) orelse return error.TableNotFound;
                for (parent.cols) |pc| {
                    var seen = false;
                    for (merged.items) |m| {
                        if (std.ascii.eqlIgnoreCase(m.name, pc.name)) { seen = true; break; }
                    }
                    if (!seen) try merged.append(alloc, .{ .name = pc.name, .type_name = typeName(pc.ty) });
                }
            }
            for (c.cols) |cc| {
                var seen = false;
                for (merged.items) |m| {
                    if (std.ascii.eqlIgnoreCase(m.name, cc.name)) { seen = true; break; }
                }
                if (!seen) try merged.append(alloc, cc);
            }
            defs = try merged.toOwnedSlice(alloc);
        }
        if (c.as_select) |sel| {
            const res = try self.execSelect(alloc, sel, true);
            const out_defs = try alloc.alloc(ColumnDef, res.columns.len);
            for (res.columns, 0..) |cn, i| {
                var ty: ColType = .text;
                if (res.rows.len > 0 and i < res.rows[0].len) {
                    ty = switch (res.rows[0][i]) {
                        .int => .int,
                        .float => .float,
                        .boolean => .boolean,
                        else => .text,
                    };
                }
                out_defs[i] = .{ .name = cn, .type_name = typeName(ty) };
            }
            defs = out_defs;
            const t = try Table.create(self.gpa, c.name, defs);
            t.is_temp = c.temp;
            try self.tables.put(t.name, t);
            for (res.rows) |row| try self.insertRow(c.name, row);
            self.bumpTableVer(c.name);
            return .{ .affected = res.rows.len };
        }
        const t = try Table.create(self.gpa, c.name, defs);
        t.is_temp = c.temp;
        try self.tables.put(t.name, t);
        return .{};
    }

    fn execInsertSelect(self: *Engine, alloc: std.mem.Allocator, ins: anytype) EngineError!Result {
        const t = self.find(ins.table) orelse return error.TableNotFound;
        const res = try self.execSelect(alloc, ins.select, true);
        var n: usize = 0;
        for (res.rows) |row| {
            const vals = try alloc.alloc(Value, t.cols.len);
            for (vals) |*v| v.* = .null;
            if (ins.columns.len == 0) {
                for (row, 0..) |v, i| { if (i < vals.len) vals[i] = v; }
            } else {
                for (ins.columns, 0..) |cn, ci| {
                    const idx = findCol(t, cn) orelse return error.UnknownColumn;
                    if (ci < row.len) vals[idx] = row[ci];
                }
            }
            try self.insertRow(ins.table, vals);
            n += 1;
        }
        if (n > 0) { self.dropFloatCounts(ins.table); self.bumpTableVer(ins.table); }
        return .{ .affected = n };
    }

    fn execCopy(self: *Engine, alloc: std.mem.Allocator, cp: anytype) EngineError!Result {
        const io = self.io orelse return error.Unsupported;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, cp.path, alloc, .limited(1 << 30)) catch
            return error.FileNotFound;
        const t = self.find(cp.table) orelse return error.TableNotFound;
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            const vals = try alloc.alloc(Value, t.cols.len);
            for (vals) |*v| v.* = .null;
            var it = std.mem.splitScalar(u8, line, '\t');
            var ci: usize = 0;
            while (it.next()) |cell| : (ci += 1) {
                if (ci >= vals.len) break;
                const out_i = if (cp.columns.len == 0) ci else blk: {
                    const target = findCol(t, cp.columns[ci]) orelse return error.UnknownColumn;
                    break :blk target;
                };
                if (std.mem.eql(u8, cell, "\\N")) vals[out_i] = .null else vals[out_i] = .{ .text = cell };
            }
            try self.insertRow(cp.table, vals);
            n += 1;
        }
        if (n > 0) { self.dropFloatCounts(cp.table); self.bumpTableVer(cp.table); }
        return .{ .affected = n };
    }

    fn execDrop(self: *Engine, d: anytype) EngineError!Result {
        var it = self.tables.iterator();
        while (it.next()) |e| {
            if (std.ascii.eqlIgnoreCase(e.key_ptr.*, d.name)) {
                const t = e.value_ptr.*;
                const key = e.key_ptr.*;
                const was_temp = t.is_temp;
                _ = self.tables.remove(key);
                const shadow = if (was_temp) self.shadowed_tables.fetchRemove(d.name) else null;
                t.destroy(self.gpa);
                self.dropColumnar(d.name);
                if (shadow) |kv| {
                    self.tables.put(kv.key, kv.value) catch {};
                }
                return .{};
            }
        }
        if (d.if_exists) return .{};
        return error.TableNotFound;
    }

    /// A snapshot-backed table starts with no row store (SELECT reads the
    /// columnar copy). DML needs rows, so materialise them on first write.
    fn ensureRowsMaterialized(self: *Engine, name: []const u8) void {
        const t = self.find(name) orelse return;
        if (t.rows.items.len > 0) return;
        const ct = self.findColumnar(name) orelse return;
        if (ct.nrows == 0) return;
        // Persisted tombstones (write-back without compaction) must survive the
        // materialisation, otherwise row-engine paths would see dead rows.
        if (t.deleted.items.len < ct.nrows) {
            const old = t.deleted.items.len;
            t.deleted.resize(self.gpa, ct.nrows) catch return;
            @memset(t.deleted.items[old..], 0);
        }
        var ri_del: usize = 0;
        while (ri_del < ct.nrows) : (ri_del += 1) {
            if (ct.isDeleted(ri_del)) {
                t.deleted.items[ri_del] = 1;
                t.dead_rows += 1;
            }
        }
        var ri: usize = 0;
        const ta = t.arena.allocator();
        while (ri < ct.nrows) : (ri += 1) {
            const row = self.gpa.alloc(Value, t.cols.len) catch return;
            for (0..t.cols.len) |ci| {
                const v = columnar.cellValue(ct, ci, ri);
                // Materialised strings must not alias the columnar arena: a later
                // `buildColumnar` replaces (and frees) it.
                row[ci] = switch (v) {
                    .text => |txt| .{ .text = ta.dupe(u8, txt) catch txt },
                    else => v,
                };
            }
            const row_idx = t.rows.items.len;
            t.rows.append(self.gpa, row) catch return;
            // Mirror the columnar validity bitmap into the row store.
            for (0..t.cols.len) |ci| {
                if (ct.isNull(ci, ri)) tableSetNull(self.gpa, t, ci, row_idx, true) catch {};
            }
        }
    }

    fn rebuildAfterDml(self: *Engine, name: []const u8) void {
        self.buildColumnar(name) catch {};
    }

    fn execInsert(self: *Engine, alloc: std.mem.Allocator, ins: anytype) EngineError!Result {
        const t = self.find(ins.table) orelse return error.TableNotFound;
        self.ensureRowsMaterialized(ins.table);
        try self.txSnapshot(alloc, ins.table);
        var count: usize = 0;
        var appended_ct = true;
        var reused: usize = 0;
        for (ins.rows) |val_exprs| {
            const row = try self.gpa.alloc(Value, t.cols.len);
            // PostgreSQL: omitted columns default to NULL. ClickHouse's
            // `UInt*/String/...` columns keep their implicit zero/default.
            for (row, 0..) |*cell, ci| cell.* = if (t.ch_defaults) defaultValue(t.cols[ci].ty) else .null;
            if (ins.columns.len == 0) {
                if (val_exprs.len != t.cols.len) {
                    self.gpa.free(row);
                    return error.SyntaxError;
                }
                for (val_exprs, 0..) |ve, i| {
                    const v = try self.eval(alloc, ve, null, &.{}, null);
                    row[i] = try coerce(t, i, v);
                }
            } else {
                for (ins.columns, 0..) |cname, ci| {
                    const idx = findCol(t, cname) orelse return error.SyntaxError;
                    const v = try self.eval(alloc, val_exprs[ci], null, &.{}, null);
                    row[idx] = try coerce(t, idx, v);
                }
            }
            for (0..t.cols.len) |ci| {
                if (t.cols[ci].serial and row[ci] == .null) {
                    row[ci] = .{ .int = t.serial_next };
                    t.serial_next += 1;
                }
            }
            // Own inserted text values: expression slices may point into the
            // per-statement source buffer, which is freed after execution.
            {
                const ta = t.arena.allocator();
                for (row) |*cell| {
                    if (cell.* == .text) cell.* = .{ .text = try ta.dupe(u8, cell.text) };
                }
            }
            if (std.c.getenv("ZHDB_DBG_STR") != null and count == 0) {
                std.debug.print("[eval] row0 {any}\n", .{row});
            }
            if (!self.inTxn() and t.free_slots.items.len > 0 and self.reuseSlot(t, row)) {
                self.gpa.free(row);
                count += 1;
                reused += 1;
                continue;
            }
            const nri = try appendStoredRow(self.gpa, t, row);
            t.xmin.items[nri] = self.curTxid();
            self.markDirty(nri);
            if (!self.inTxn() and !t.is_temp) {
                // Incremental write-back needs a stable row id: append the row
                // to the shared columnar copy (no full rebuild) when it is
                // still aligned with the row store.
                if (self.findColumnar(t.name)) |ct| {
                    const ca = ct.arena.allocator();
                    // Align the copy (tombstoned placeholders) instead of
                    // falling back to a full rebuild + full base save.
                    if (ct.nrows < nri and !ct.padRows(ca, nri)) appended_ct = false;
                    if (ct.nrows == nri) {
                        if (!ct.appendRow(ca, row)) appended_ct = false;
                    } else {
                        appended_ct = false;
                    }
                } else {
                    appended_ct = false;
                }
            }
            if (self.inTxn()) {
                // Delta overlay: append the new row to the shared columnar copy
                // so this transaction keeps reading it (no private rebuild).
                if (self.findColumnar(t.name)) |ct| {
                    if (ct.delta_owner == 0 or ct.delta_owner == self.curTxid()) {
                        const ca = ct.arena.allocator();
                        if (ct.appendRow(ca, row)) {
                            ct.delta_owner = self.curTxid();
                        } else {
                            ct.delta_inserts = true;
                        }
                    } else {
                        ct.delta_inserts = true;
                    }
                }
            }
            self.gpa.free(row);
            count += 1;
        }
        // Any row addition can change the shared columnar image (in-place
        // append or rebuild), so cached float value counts are stale.
        if (count > 0) {
            self.dropFloatCounts(t.name);
            self.bumpTableVer(t.name);
        }
        // Inside a transaction the shared columnar copy stays untouched (it is
        // rebuilt at COMMIT), otherwise uncommitted rows would leak. The
        // transaction's private view is stale now and gets rebuilt on demand.
        if (std.c.getenv("ZHDB_DBG_STR") != null and count > 0 and t.rows.items.len > 0) {
            const first = t.rows.items[0][0];
            if (first == .text) {
                std.debug.print("[ins] {s} row0 len={d} text='{s}'\n", .{ t.name, first.text.len, first.text });
            }
            if (self.findColumnar(t.name)) |ct0| {
                if (ct0.data.len > 0 and ct0.data[0] == .strs and ct0.nrows > 0) {
                    const sd = ct0.data[0].strs;
                    std.debug.print("[ins] {s} ct0 len={d} text='{s}'\n", .{ t.name, sd.at(0).len, sd.at(0) });
                }
            }
        }
        if (self.inTxn() and count > 0) self.txnViewDrop(t.name);
        if (count > 0 and !self.inTxn() and !t.is_temp) {
            // Only rebuild when a row could not be patched/appended in place
            // (e.g. the copy was out of sync); the row write itself is done.
            if (!appended_ct) try self.buildColumnar(t.name);
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                var free_segs: usize = 0;
                for (t.seg_free_rows.items) |n| {
                    if (n > 0) free_segs += 1;
                }
                std.debug.print("[insert] {s}: reused={d} appended={d} rebuild={} rows={d} free_slots={d} free_segments={d}\n", .{
                    t.name, reused, count - reused, !appended_ct, t.rows.items.len,
                    t.free_slots.items.len - t.free_head, free_segs,
                });
            }
        }
        return .{ .affected = count };
    }

    /// UPDATE <table> SET col = expr [, ...] [WHERE expr]: in-place on the row
    /// store, then rebuild the columnar copy so SELECT sees the change.
    fn execUpdate(self: *Engine, alloc: std.mem.Allocator, u: anytype) EngineError!Result {
        const t = self.find(u.table) orelse return error.TableNotFound;
        self.dropFloatCounts(u.table);
        self.bumpTableVer(u.table);
        self.ensureRowsMaterialized(u.table);
        try self.txSnapshot(alloc, u.table);
        try ensureVersionArrays(self.gpa, t);
        const mine = self.curTxid();

        // First pass: find visible rows to update and detect write conflicts.
        var targets = std.ArrayList(usize).empty;
        defer targets.deinit(self.gpa);
        for (t.rows.items, 0..) |_, ri| {
            if (isRowDeleted(t, ri)) continue;
            if (!self.visibleRow(t, ri)) continue;
            const mrow = try materializeRow(alloc, t, ri);
            if (u.where) |w| {
                const v = try self.eval(alloc, w, mrow, t.cols, null);
                if (!truthy(v)) continue;
            }
            // First-updater-wins: a concurrently deleted/updated row aborts us.
            if (ri < t.xmax.items.len) {
                const xm = t.xmax.items[ri];
                if (xm != 0 and xm != mine and self.isInFlight(xm)) return error.SerializationFailure;
            }
            try targets.append(self.gpa, ri);
        }
        if (targets.items.len == 0) return .{ .affected = 0 };

        // Second pass: MVCC update = mark the old version deleted and insert a
        // new version with the assigned values.
        var n: usize = 0;
        for (targets.items) |ri| {
            const mrow = try materializeRow(alloc, t, ri);
            const newv = try alloc.alloc(Value, t.cols.len);
            @memcpy(newv, mrow);
            for (u.assignments) |a| {
                const idx = findCol(t, a.col) orelse return error.UnknownColumn;
                const v = try self.eval(alloc, a.value, mrow, t.cols, null);
                newv[idx] = try coerce(t, idx, v);
            }
            // delete old version
            if (ri < t.xmax.items.len) t.xmax.items[ri] = mine;
            // Visibility is driven by xmax; the tombstone bitmap is rebuilt at
            // COMMIT / compaction.
            // Own the new version's text values (expression slices are transient).
            {
                const ta = t.arena.allocator();
                for (newv) |*cell| {
                    if (cell.* == .text) cell.* = .{ .text = try ta.dupe(u8, cell.text) };
                }
            }
            // insert new version
            const nri = try appendStoredRow(self.gpa, t, newv);
            t.xmin.items[nri] = mine;
            if (t.ctid.items.len <= nri) {
                const old = t.ctid.items.len;
                t.ctid.resize(self.gpa, nri + 1) catch {};
                var k = old;
                while (k < nri + 1) : (k += 1) t.ctid.items[k] = @intCast(k);
            }
            const cid = ctIdOf(t, ri);
            t.ctid.items[nri] = cid;
            self.markDirty(cid);
            const was_txn = self.inTxn();
            if (!was_txn) {
                t.dead_rows += 1;
                self.noteDeadSlot(t, ri);
            }
            if (self.findColumnar(t.name)) |ct| {
                if (ct.delta_owner == 0 or ct.delta_owner == mine) {
                    if (ct.patchRow(cid, newv)) {
                        for (0..ct.cols.len) |ci| ct.refreshBlockStats(ci, cid);
                        if (was_txn) ct.delta_owner = mine;
                        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                            std.debug.print("[plan] update overlay: row={d} ct={d} owner={d}\n", .{ ri, cid, if (was_txn) mine else 0 });
                        }
                    }
                }
            }
            n += 1;
        }
        if (self.inTxn()) self.txnViewDrop(t.name);
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] update mvcc: {d} versions\n", .{n});
        }
        // Dead versions stay in the row store and are reclaimed by VACUUM/GC;
        // row ids are stable, so the persisted base image stays valid and
        // write-back can be incremental.
        return .{ .affected = n };
    }

    fn execDelete(self: *Engine, alloc: std.mem.Allocator, d: anytype) EngineError!Result {
        if (d.alias) |al| {
            if (d.where) |w| {
                if (referencesQualifier(w, d.table, al)) return error.InvalidTableAlias;
            }
        }
        if (self.find(d.table)) |_| self.dropFloatCounts(d.table);
        if (self.find(d.table)) |_| self.bumpTableVer(d.table);
        const t = self.find(d.table) orelse return error.TableNotFound;
        var del_cols_storage: ?[]Column = null;
        if (d.alias) |al| {
            const copy = try alloc.dupe(Column, t.cols);
            for (copy) |*c| c.source = al;
            del_cols_storage = copy;
        }
        const del_cols = del_cols_storage orelse t.cols;
        self.ensureRowsMaterialized(d.table);
        try self.txSnapshot(alloc, d.table);
        try ensureVersionArrays(self.gpa, t);
        const ct = self.findColumnar(d.table);
        // Row ids stay stable: deleted rows are tombstoned and only those row
        // ids are removed from the B+ tree (no full rebuild).
        if (t.deleted.items.len < t.rows.items.len) {
            const old_len = t.deleted.items.len;
            try t.deleted.resize(self.gpa, t.rows.items.len);
            @memset(t.deleted.items[old_len..], 0);
        }
        if (ct) |c| {
            if (c.tomb == null) {
                const a = c.arena.allocator();
                const bits = try a.alloc(u8, (c.nrows + 7) / 8);
                @memset(bits, 0);
                c.tomb = bits;
            }
        }
        var removed: usize = 0;
        var idx_dirty: [32]bool = @splat(false);
        for (t.rows.items, 0..) |row, ri| {
            if (isRowDeleted(t, ri)) continue;
            const mrow = try materializeRow(alloc, t, ri);
            if (d.where) |w| {
                const v = try self.eval(alloc, w, mrow, del_cols, null);
                if (!truthy(v)) continue;
            }
            if (!self.inTxn()) {
                if (t.deleted.items.len < ri + 1) {
                    const old_len = t.deleted.items.len;
                    try t.deleted.resize(self.gpa, t.rows.items.len);
                    @memset(t.deleted.items[old_len..], 0);
                }
                t.deleted.items[ri] = 1;
            }
            if (ri < t.xmax.items.len) t.xmax.items[ri] = self.curTxid();
            removed += 1;
            self.markDirty(ctIdOf(t, ri));
            if (!self.inTxn()) {
                t.dead_rows += 1;
                self.noteDeadSlot(t, ri);
            }
            if (ct) |c| {
                if (c.delta_owner == 0) c.delta_owner = self.curTxid();
                const cid = ctIdOf(t, ri);
                c.tomb.?[cid / 8] |= @as(u8, 1) << @intCast(cid % 8);
                for (c.keyidx, 0..) |maybe, ci| {
                    if (maybe == null or ci >= row.len or ci >= idx_dirty.len) continue;
                    const idx = maybe.?;
                    if (idx.tree) |*tr| {
                        if (row[ci] == .int) {
                            _ = tr.remove(row[ci].int, @intCast(ri)) catch false;
                            idx_dirty[ci] = true;
                        }
                    }
                }
            }
        }
        if (removed > 0) {
            // Flattening is O(keys): doing it once per statement instead of once
            // per deleted row keeps large DELETEs linear (it used to exhaust the
            // arena on a 300k-row delete with an index).
            if (ct) |c| {
                for (c.keyidx, 0..) |maybe, ci| {
                    if (maybe == null or ci >= idx_dirty.len or !idx_dirty[ci]) continue;
                    const idx = maybe.?;
                    if (idx.tree) |*tr| {
                        const a2 = c.arena.allocator();
                        if (tr.flatten(a2)) |flat| {
                            idx.keys = flat.keys;
                            idx.offsets = flat.offsets;
                            idx.rows = flat.rows;
                        } else |_| {}
                    }
                }
            }
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[plan] delete tombstones: {d} rows\n", .{removed});
            }
            if (self.inTxn()) {
                // The columnar copy is rebuilt at COMMIT.
            } else {
                // Whole dead segments become reusable slots immediately: the
                // next INSERT refills them instead of growing the table, and no
                // row renumbering (full compaction) is needed.
                const freed = self.reclaimFreeSegments(t);
                if (freed > 0 and std.c.getenv("ZHDB_EXPLAIN") != null) {
                    std.debug.print("[reclaim] {s}: {d} rows of whole segments registered for reuse\n", .{ d.table, freed });
                }
                if (!self.background_gc) {
                    // Reclaim dead versions automatically once they dominate.
                    self.maybeAutoVacuum(d.table);
                }
            }
            if (self.inTxn()) self.txnViewDrop(d.table);
        }
        return .{ .affected = removed };
    }

    /// Build minimal real rows for the PostgreSQL catalogs so clients (psql
    /// \dt, ORMs) get metadata instead of empty sets.
    /// Rebuild the pg_* catalogs unless they are already current. DDL clears
    /// the flag. Safe to call from concurrent readers.
    pub fn refreshCatalogIfNeeded(self: *Engine) void {
        if (self.catalogs_fresh.load(.acquire)) return;
        self.catalog_lock.lock();
        defer self.catalog_lock.unlock();
        if (self.catalogs_fresh.load(.acquire)) return;
        self.refreshCatalog();
        self.catalogs_fresh.store(true, .release);
    }

    fn invalidateCatalogs(self: *Engine) void {
        self.catalogs_fresh.store(false, .release);
    }

    fn refreshCatalog(self: *Engine) void {
        const gpa = self.gpa;
        const defs_ns = [_]sql.ColumnDef{ .{ .name = "oid", .type_name = "int" }, .{ .name = "nspname", .type_name = "text" } };
        const defs_cl = [_]sql.ColumnDef{ .{ .name = "oid", .type_name = "int" }, .{ .name = "relname", .type_name = "text" }, .{ .name = "relnamespace", .type_name = "int" }, .{ .name = "relkind", .type_name = "text" }, .{ .name = "relowner", .type_name = "int" } };
        const defs_ty = [_]sql.ColumnDef{ .{ .name = "oid", .type_name = "int" }, .{ .name = "typname", .type_name = "text" } };
        const defs_at = [_]sql.ColumnDef{ .{ .name = "attrelid", .type_name = "int" }, .{ .name = "attname", .type_name = "text" }, .{ .name = "atttypid", .type_name = "int" }, .{ .name = "attnum", .type_name = "int" } };
        const defs_db = [_]sql.ColumnDef{ .{ .name = "oid", .type_name = "int" }, .{ .name = "datname", .type_name = "text" } };

        const cats = [_]struct { name: []const u8, defs: []const sql.ColumnDef }{
            .{ .name = "pg_namespace", .defs = &defs_ns },
            .{ .name = "pg_class", .defs = &defs_cl },
            .{ .name = "pg_type", .defs = &defs_ty },
            .{ .name = "pg_attribute", .defs = &defs_at },
            .{ .name = "pg_database", .defs = &defs_db },
        };
        for (cats) |c| {
            if (self.find(c.name)) |t| {
                if (!t.rows_shared_dummy) for (t.rows.items) |row| gpa.free(row);
                t.rows.clearRetainingCapacity();
            } else {
                const t = Table.create(gpa, c.name, c.defs) catch continue;
                self.tables.put(t.name, t) catch continue;
            }
        }
        const add = struct {
            fn row(e: *Engine, name: []const u8, vals: []const Value) void {
                const t = e.find(name) orelse return;
                const r = e.gpa.alloc(Value, t.cols.len) catch return;
                for (0..t.cols.len) |i| r[i] = if (i < vals.len) vals[i] else Value.null;
                t.rows.append(e.gpa, r) catch return;
            }
        }.row;
        add(self, "pg_namespace", &.{ .{ .int = 2200 }, .{ .text = "public" } });
        // The catalog itself is a relation in PostgreSQL.
        add(self, "pg_class", &.{ .{ .int = 1259 }, .{ .text = "pg_class" }, .{ .int = 11 }, .{ .text = "r" }, .{ .int = 10 } });
        add(self, "pg_database", &.{ .{ .int = 5 }, .{ .text = "postgres" } });
        const types = [_]struct { oid: i64, name: []const u8 }{
            .{ .oid = 23, .name = "int4" }, .{ .oid = 701, .name = "float8" },
            .{ .oid = 25, .name = "text" }, .{ .oid = 16, .name = "bool" },
        };
        for (types) |ty| add(self, "pg_type", &.{ .{ .int = ty.oid }, .{ .text = ty.name } });

        var oid: i64 = 16384;
        var it = self.tables.iterator();
        while (it.next()) |e| {
            const t = e.value_ptr.*;
            if (std.mem.startsWith(u8, t.name, "pg_")) continue;
            oid += 1;
            add(self, "pg_class", &.{ .{ .int = oid }, .{ .text = t.name }, .{ .int = 2200 }, .{ .text = "r" }, .{ .int = 1 } });
            for (t.cols, 0..) |c, i| {
                const ty: i64 = switch (c.ty) {
                    .int, .boolean => 23,
                    .float => 701,
                    else => 25,
                };
                add(self, "pg_attribute", &.{ .{ .int = oid }, .{ .text = c.name }, .{ .int = ty }, .{ .int = @intCast(i + 1) } });
            }
        }
        for (cats) |c| self.buildColumnar(c.name) catch {};
    }

    /// Physically remove tombstoned rows (used before INSERT after DELETE and
    /// before writing a snapshot, where row ids may be renumbered).
    /// One periodic GC tick: reclaim tables whose dead versions dominate.
    /// Called by the background thread (and safe to call from VACUUM).
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
            // A snapshot-loaded table only has the columnar image; materialise
            // the row store when that image carries tombstones so the block map
            // can be inspected (clean tables are left untouched).
            if (t.rows.items.len == 0) {
                if (self.findColumnar(nm)) |ct| {
                    if (ct.nrows > 0 and ct.anyDeleted()) self.ensureRowsMaterialized(nm);
                }
                t = self.find(nm) orelse continue;
            }
            if (t.rows.items.len < 64) continue;
            // Background physical block reclamation: whole dead columnar blocks
            // (anywhere in the image) are rewritten/dropped without waiting for
            // an explicit VACUUM. Bounded work: at most one table per tick.
            const db = self.deadBlocks(t);
            // Whole dead blocks always pay off. Partially dead blocks are
            // rewritten when at least a quarter of their rows are gone, or when
            // the scan-penalty cost model (learned scan count Q) says the
            // rewrite pays for itself over the expected future scans.
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
            // The counter is maintained by DELETE/UPDATE, so deciding costs
            // O(1) instead of scanning every row of every table on each tick.
            if (t.dead_rows * 8 >= t.rows.items.len and t.dead_rows >= 64) {
                // Bounded work per tick: reclaim at most one table, and only the
                // segments that actually contain dead rows.
                const st = self.reclaimSegments(nm);
                const dropped = self.truncateDeadTail(nm);
                if (st.rows + dropped > 0) reclaimed += 1;
                break;
            }
        }
        return reclaimed;
    }

    /// Automatic reclamation: compact when more than 1/4 of the versions are
    /// dead (committed deletes) and the table is non-trivial.
    fn maybeAutoVacuum(self: *Engine, name: []const u8) void {
        const t = self.find(name) orelse return;
        if (t.rows.items.len < 64) return;
        if (!self.background_gc and t.dead_rows * 8 >= t.rows.items.len and t.dead_rows >= 64) {
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[vacuum] {s}: {d} dead rows -> interior compaction\n", .{ name, t.dead_rows });
            }
            self.compactTable(name);
        } else if (std.c.getenv("ZHDB_EXPLAIN") != null and t.free_head < t.free_slots.items.len) {
            std.debug.print("[vacuum] {s}: keep (free segments already hold {d} reusable slots; no rewrite)\n", .{ name, t.free_slots.items.len - t.free_head });
        }
    }

    /// Write one inserted row into a reclaimed slot, patching the columnar copy
    /// in place (value + validity + that block's min/max) instead of rebuilding.
    fn reuseSlot(self: *Engine, t: *Table, row: []const Value) bool {
        if (t.free_head >= t.free_slots.items.len) {
            t.free_slots.clearRetainingCapacity();
            t.free_head = 0;
            return false;
        }
        const slot: usize = t.free_slots.items[t.free_head];
        const ct = self.findColumnar(t.name) orelse return false;
        if (ct.nrows != t.rows.items.len) return false;
        if (slot >= t.rows.items.len or slot >= t.deleted.items.len) {
            t.free_head += 1;
            return false;
        }
        if (!ct.patchRow(slot, row)) return false; // variable-length strings
        const a = ct.arena.allocator();
        ct.setTomb(a, slot, false) catch return false;
        for (0..ct.cols.len) |ci| ct.refreshBlockStats(ci, slot);
        const words = (t.rows.items.len + 7) / 8;
        for (0..t.cols.len) |ci| {
            const is_null = ci < row.len and row[ci] == .null;
            if (is_null and ci < t.nulls.len and t.nulls[ci] == null) {
                const bits = self.gpa.alloc(u8, words) catch return false;
                @memset(bits, 0xff);
                t.nulls[ci] = bits;
            }
            tableSetNull(self.gpa, t, ci, slot, is_null) catch {};
            if (ci < ct.valid.len) {
                if (ct.valid[ci]) |bits| {
                    if (is_null) {
                        bits[slot / 8] &= ~(@as(u8, 1) << @intCast(slot % 8));
                    } else {
                        bits[slot / 8] |= @as(u8, 1) << @intCast(slot % 8);
                    }
                } else if (is_null) {
                    const words_c = (ct.nrows + 7) / 8;
                    const bits = a.alloc(u8, words_c) catch return false;
                    @memset(bits, 0xff);
                    bits[slot / 8] &= ~(@as(u8, 1) << @intCast(slot % 8));
                    ct.valid[ci] = bits;
                }
            }
        }
        const old = t.rows.items[slot];
        if (t.placeholder.len != t.cols.len or old.ptr != t.placeholder.ptr) self.gpa.free(old);
        const stored = self.gpa.alloc(Value, t.cols.len) catch return false;
        for (stored, 0..) |*c, ci| {
            const v: Value = if (ci < row.len) row[ci] else defaultValue(t.cols[ci].ty);
            c.* = if (v == .null) storedSentinel(t.cols[ci].ty) else v;
        }
        t.rows.items[slot] = stored;
        t.deleted.items[slot] = 0;
        // The patched slot must reach the next incremental/full write-back.
        self.markDirty(slot);
        if (slot < t.xmin.items.len) t.xmin.items[slot] = self.curTxid();
        if (slot < t.xmax.items.len) t.xmax.items[slot] = 0;
        // The slot was already removed from `dead_rows` by reclamation.
        const seg = slot / seg_rows;
        if (seg < t.seg_free_rows.items.len and t.seg_free_rows.items[seg] > 0) {
            t.seg_free_rows.items[seg] -= 1;
        }
        t.free_head += 1;
        if (t.free_head >= t.free_slots.items.len) {
            t.free_slots.clearRetainingCapacity();
            t.free_head = 0;
        }
        return true;
    }

    /// Did this transaction already write `name`? (cheap: usually 0-2 entries)
    fn txnWrote(self: *Engine, name: []const u8) bool {
        for (self.txnCtx().undo.items) |u| {
            if (std.ascii.eqlIgnoreCase(u.name, name)) return true;
        }
        return false;
    }

    fn txnViewGet(self: *Engine, name: []const u8) ?*columnar.Table {
        for (self.txnCtx().views.items) |v| {
            if (std.ascii.eqlIgnoreCase(v.name, name)) return v.ct;
        }
        return null;
    }

    fn txnViewDrop(self: *Engine, name: []const u8) void {
        const ctx = self.txnCtx();
        var i: usize = 0;
        while (i < ctx.views.items.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(ctx.views.items[i].name, name)) {
                const v = ctx.views.orderedRemove(i);
                v.ct.destroy(self.gpa);
                self.gpa.free(v.name);
                return;
            }
        }
    }

    fn dropAllViews(self: *Engine, ctx: *TxnCtx) void {
        for (ctx.views.items) |v| {
            v.ct.destroy(self.gpa);
            self.gpa.free(v.name);
        }
        ctx.views.clearRetainingCapacity();
    }

    /// Build (and cache) a private columnar copy of `name` containing exactly
    /// the rows visible to the current transaction: committed rows plus this
    /// transaction's own writes. Reads inside the transaction then keep using
    /// the columnar/JIT path instead of the row engine.
    fn txnViewBuild(self: *Engine, name: []const u8) !*columnar.Table {
        const t = self.find(name) orelse return error.TableNotFound;
        var rows = std.ArrayList([]Value).empty;
        defer {
            for (rows.items) |r| self.gpa.free(r);
            rows.deinit(self.gpa);
        }
        for (t.rows.items, 0..) |_, ri| {
            if (isRowDeleted(t, ri)) continue;
            if (!self.visibleRow(t, ri)) continue;
            const m = try self.gpa.alloc(Value, t.cols.len);
            for (0..t.cols.len) |ci| m[ci] = cellValueFromRow(t, ci, ri);
            try rows.append(self.gpa, m);
        }
        const cols = try self.gpa.alloc(columnar.Column, t.cols.len);
        defer self.gpa.free(cols);
        for (t.cols, 0..) |c, i| {
            cols[i] = .{ .name = c.name, .kind = switch (c.ty) {
                .int, .boolean => .int,
                .float => .float,
                .text, .date, .timestamp => .str,
            } };
        }
        const ct = try columnar.Table.buildForView(self.gpa, cols, rows.items);
        const ctx = self.txnCtx();
        try ctx.views.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name), .ct = ct });
        return ct;
    }

    /// Record one dead row in its segment (and mark the segment dirty).
    fn noteDeadSlot(self: *Engine, t: *Table, ri: usize) void {
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

    /// Register one reclaimed slot in the free-segment map + reuse queue.
    fn noteFreeSlot(self: *Engine, t: *Table, ri: usize) void {
        t.free_slots.append(self.gpa, @intCast(ri)) catch return;
        const seg = ri / seg_rows;
        if (t.seg_free_rows.items.len <= seg) {
            const old = t.seg_free_rows.items.len;
            t.seg_free_rows.resize(self.gpa, seg + 1) catch return;
            @memset(t.seg_free_rows.items[old..], 0);
        }
        t.seg_free_rows.items[seg] += 1;
    }

    /// Keep `free_slots` sorted ascending so FIFO consumption fills the lowest
    /// freed segment first. Also drops the already-consumed prefix.
    fn sortFreeSlots(self: *Engine, t: *Table) void {
        _ = self;
        if (t.free_head > 0) {
            const rem = t.free_slots.items[t.free_head..];
            if (rem.len > 0) std.mem.copyForwards(u32, t.free_slots.items[0..rem.len], rem);
            t.free_slots.items.len = rem.len;
            t.free_head = 0;
        }
        std.mem.sort(u32, t.free_slots.items, {}, std.sort.asc(u32));
    }

    /// Free every row of segments that are **completely dead** (all rows
    /// tombstoned, committed, not in flight) and publish them in the
    /// free-segment map. These segments are then refilled by INSERT instead of
    /// appending new ones, and interior compaction is unnecessary.
    fn reclaimFreeSegments(self: *Engine, t: *Table) usize {
        var freed: usize = 0;
        var si: usize = 0;
        var w: usize = 0;
        while (si < t.free_segments.items.len) : (si += 1) {
            const seg = t.free_segments.items[si];
            const lo: usize = @as(usize, seg) * seg_rows;
            const hi: usize = @min(lo + seg_rows, t.rows.items.len);
            // O(1) filter: only fully-dead segments are candidates.
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
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[reclaim] {s}: segment {d} fully free ({d} rows) -> reuse\n", .{ t.name, seg, hi - lo });
            }
        }
        t.free_segments.items.len = w;
        if (t.dead_rows >= freed) t.dead_rows -= freed else t.dead_rows = 0;
        if (freed > 0) self.sortFreeSlots(t);
        return freed;
    }

    pub const ReclaimStats = struct { segments: usize = 0, rows: usize = 0, blocks_dropped: usize = 0 };

    /// Drop fully-dead trailing rows from the row store *and* the columnar copy.
    /// This is the one case where a columnar block can be reclaimed without
    /// renumbering anything: whole tail blocks simply disappear.
    fn truncateDeadTail(self: *Engine, name: []const u8) usize {
        const t = self.find(name) orelse return 0;
        var k: usize = 0;
        while (k < t.rows.items.len) : (k += 1) {
            const ri = t.rows.items.len - 1 - k;
            const xm: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
            const dead = isRowDeleted(t, ri) or
                (xm != 0 and !self.isInFlight(xm));
            if (!dead) break;
        }
        if (k == 0) return 0;
        // free payloads of the dropped rows
        var k_dead: usize = 0;
        var i: usize = t.rows.items.len - k;
        while (i < t.rows.items.len) : (i += 1) {
            const row = t.rows.items[i];
            if (t.placeholder.len != t.cols.len or row.ptr != t.placeholder.ptr) {
                // A placeholder was already accounted for by reclamation.
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
        // columnar: the trailing blocks are gone, nothing to renumber
        if (self.findColumnar(name)) |ct| {
            if (ct.nrows > keep) ct.truncateRows(keep);
        }
        return k;
    }

    /// Segment-level reclamation: only segments listed in the free-space map are
    /// visited. Dead slot payloads are freed and replaced by the table's
    /// placeholder; row ids stay stable, so the columnar tombstone bits and the
    /// B+ tree remain valid and no full rebuild is needed.
    fn reclaimSegments(self: *Engine, name: []const u8) ReclaimStats {
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
                // Already handed to the free-segment map by an earlier pass.
                if (t.placeholder.len == t.cols.len and row.ptr == t.placeholder.ptr) continue;
                const xm: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
                if (xm != 0 and self.isInFlight(xm)) continue; // not committed yet
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

    fn compactTable(self: *Engine, name: []const u8) void {
        const t = self.find(name) orelse return;
        const rows_before = t.rows.items.len;
        const t_start = nowNs();
        // Compaction moves rows: cached delta row ids would be wrong.
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
            const dead = isRowDeleted(t, ri) or
                (ri < t.xmax.items.len and t.xmax.items[ri] != 0 and !self.isInFlight(t.xmax.items[ri]));
            if (dead) {
                // Reclaimed slots already point at the table placeholder.
                if (t.placeholder.len != t.cols.len or row.ptr != t.placeholder.ptr) self.gpa.free(row);
                continue;
            }
            if (w < remap.items.len) remap.items[ri] = @intCast(w);
            t.rows.items[w] = row;
            if (ri < t.xmin.items.len) t.xmin.items[w] = t.xmin.items[ri];
            // Keep pending deletes (owned by an in-flight transaction); only
            // committed dead versions are cleared.
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
        // Compaction renumbers rows: any queued slot ids are stale and must not
        // be handed to a later INSERT (they may now name live rows).
        t.free_slots.clearRetainingCapacity();
        t.free_head = 0;
        t.seg_free_rows.clearRetainingCapacity();
        // Rebuild the validity bitmap for the compacted rows.
        for (t.nulls) |*slot| slot.* = null;
        for (t.rows.items, 0..) |row, ri| {
            for (0..t.cols.len) |ci| {
                if (row[ci] == .null) tableSetNull(self.gpa, t, ci, ri, true) catch {};
            }
        }
        self.index_remap = remap.items;
        defer self.index_remap = null;
        self.buildColumnar(name) catch {};
        // Learn the rewrite cost from the observed duration.
        const dt = nowNs() - t_start;
        if (rows_before > 0 and dt > 0) {
            const sample = @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(rows_before));
            const alpha: f64 = if (self.compact_samples < 4) 0.5 else 0.2;
            self.compact_row_ns = std.math.clamp((1.0 - alpha) * self.compact_row_ns + alpha * sample, 5.0, 5000.0);
            self.compact_samples += 1;
            self.costs_dirty = true;
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[compact] {s}: rows={d} ns/row={d:.1} (learned {d:.1})\n", .{
                    name, rows_before, sample, self.compact_row_ns,
                });
            }
        }
    }

    /// Persist the current columnar state of `table` back into a ZDB1 file.
    /// Used by snapshot write-back so DML and CREATE INDEX survive restarts.
    fn learnAlpha(self: *Engine) f64 {
        return if (self.wb_samples < 6) 0.5 else 0.2;
    }

    fn learnWrite(self: *Engine, bytes: usize, ns: anytype) void {
        if (bytes == 0 or std.c.getenv("ZHDB_WB_NO_LEARN") != null) return;
        const sample = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(bytes));
        const a = self.learnAlpha();
        self.wb_write_ns_byte = std.math.clamp((1.0 - a) * self.wb_write_ns_byte + a * sample, 0.05, 50.0);
        self.wb_samples += 1;
        self.costs_dirty = true;
    }

    fn learnEncode(self: *Engine, rows: usize, ns: anytype) void {
        if (rows == 0 or std.c.getenv("ZHDB_WB_NO_LEARN") != null) return;
        const sample = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(rows));
        const a = self.learnAlpha();
        self.wb_encode_ns_row = std.math.clamp((1.0 - a) * self.wb_encode_ns_row + a * sample, 1.0, 2000.0);
        self.wb_samples += 1;
        self.costs_dirty = true;
    }

    /// Called from snapshot load after replaying the sidecar delta.
    pub fn noteReplaySample(self: *Engine, rows: usize, ns: anytype) void {
        if (rows == 0 or std.c.getenv("ZHDB_WB_NO_LEARN") != null) return;
        const sample = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(rows));
        const a = self.learnAlpha();
        self.wb_replay_ns_row = std.math.clamp((1.0 - a) * self.wb_replay_ns_row + a * sample, 5.0, 20000.0);
        self.wb_samples += 1;
        self.costs_dirty = true;
    }

    /// Refresh the v8 trailer in the base image without rewriting the data
    /// (used after an incremental save, so a delta-only period still persists
    /// the latest learned costs).
    fn refreshWbTrailer(self: *Engine, io: std.Io, path: []const u8) void {
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
        // Newest layout first; older trailers are upgraded in place.
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
            // Grow the file and append the newer trailer.
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
                off, self.wb_write_ns_byte, self.wb_encode_ns_row, self.wb_replay_ns_row,
                self.cost_scan_row, self.cost_str_raw_row, self.cost_str_dict_row, self.wb_samples,
            });
        }
    }

    /// Checkpoint the learned planner constants into the snapshot trailer even
    /// in a query-only process (no DML write-back ever happens there). Called
    /// after each completed statement by the server; throttled to once a second.
    pub fn checkpointCosts(self: *Engine, io: std.Io) void {
        if (!self.costs_dirty) return;
        const now = nowNs();
        if (self.last_cost_save_ns != 0 and now >= self.last_cost_save_ns and
            now - self.last_cost_save_ns < 1_000_000_000) return;
        self.flushCostsNow(io, now);
    }

    /// Unthrottled checkpoint (connection close / idle / shutdown).
    pub fn flushCosts(self: *Engine, io: std.Io) void {
        if (!self.costs_dirty) return;
        self.flushCostsNow(io, nowNs());
    }

    fn flushCostsNow(self: *Engine, io: std.Io, now: u64) void {
        const path = self.snapshot_path orelse return;
        self.refreshWbTrailer(io, path);
        self.costs_dirty = false;
        self.last_cost_save_ns = now;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[calib] checkpoint planner costs scan_row={d:.2} str_raw={d:.2} str_dict={d:.2} -> {s}\n", .{
                self.cost_scan_row, self.cost_str_raw_row, self.cost_str_dict_row, path,
            });
        }
    }

    /// Persist the learned write-back cost model next to the snapshot so a
    /// restarted engine keeps the policy it converged to.
    pub fn saveWbCosts(self: *Engine, io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
        var tmp: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, "zhdb-meta 1\nwrite_ns_byte {d:.9}\nencode_ns_row {d:.9}\nreplay_ns_row {d:.9}\nsamples {d}\n", .{
            self.wb_write_ns_byte, self.wb_encode_ns_row, self.wb_replay_ns_row, self.wb_samples,
        }) catch return;
        const mp = std.fmt.allocPrint(gpa, "{s}.meta", .{path}) catch return;
        defer gpa.free(mp);
        const f = std.Io.Dir.cwd().createFile(io, mp, .{}) catch return;
        defer f.close(io);
        f.writeStreamingAll(io, text) catch {};
    }

    /// Restore the cost model embedded in the snapshot trailer (v8).
    pub fn restoreWbCosts(self: *Engine, c: columnar.WbCosts) void {
        self.wb_write_ns_byte = std.math.clamp(c.write_ns_byte, 0.05, 50.0);
        self.wb_encode_ns_row = std.math.clamp(c.encode_ns_row, 1.0, 2000.0);
        self.wb_replay_ns_row = std.math.clamp(c.replay_ns_row, 5.0, 20000.0);
        self.compact_row_ns = std.math.clamp(c.compact_row_ns, 5.0, 5000.0);
        self.wb_samples = @intCast(@min(c.samples, 1 << 40));
        // Planner constants: 0 means the trailer predates this field, keep the
        // seed and let the first real execution calibrate.
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
            // Do not let the one-off microbenchmark overwrite learned values.
            self.costs_calibrated = true;
            self.costs_restored = true;
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[writeback] restored costs (snapshot v8) write={d:.2}ns/B enc={d:.1}ns/row rep={d:.1}ns/row compact={d:.1}ns/row samples={d}\n", .{
                self.wb_write_ns_byte, self.wb_encode_ns_row, self.wb_replay_ns_row, self.compact_row_ns, self.wb_samples,
            });
            if (restored_plan) {
                std.debug.print("[calib] restored planner costs scan_row={d:.2}ns/row str_raw={d:.2} str_dict={d:.2} (from trailer)\n", .{
                    self.cost_scan_row, self.cost_str_raw_row, self.cost_str_dict_row,
                });
            } else {
                std.debug.print("[calib] planner costs seeded scan_row={d:.2}ns/row str_raw={d:.2} str_dict={d:.2} (trailer predates planner fields)\n", .{
                    self.cost_scan_row, self.cost_str_raw_row, self.cost_str_dict_row,
                });
            }
        }
    }

    /// Legacy fallback for snapshots without a trailer (`.meta` sidecar).
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

        // Write-back policy: keep a `.delta` sidecar while replaying it stays
        // cheaper than rewriting the base image, and fold it into the base as
        // soon as the accumulated delta crosses that point. The estimates are
        // relative costs (ns) so the policy adapts to the actual base size and
        // row count instead of a fixed byte threshold.
        const READ_NS_PER_BYTE: f64 = 0.8;
        const WRITE_NS_PER_BYTE: f64 = self.wb_write_ns_byte;
        const ENCODE_ROW_NS: f64 = self.wb_encode_ns_row;
        const REPLAY_ROW_NS: f64 = self.wb_replay_ns_row;

        const n_dirty = self.wb_dirty.items.len;
        if (!self.wb_full and n_dirty == 0) return; // nothing changed

        const dpath = try std.fmt.allocPrint(gpa, "{s}.delta", .{path});
        defer gpa.free(dpath);

        // Base image size drives the rewrite side of the comparison.
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
            // Keep older delta sections: a row mutated earlier must still be
            // replayed after a restart.
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
            const replay_ns = delta_bytes * READ_NS_PER_BYTE +
                @as(f64, @floatFromInt(delta_rows)) * REPLAY_ROW_NS;
            const rewrite_ns = @as(f64, @floatFromInt(base_bytes + buf.items.len)) * WRITE_NS_PER_BYTE +
                @as(f64, @floatFromInt(t.nrows)) * ENCODE_ROW_NS;

            const ratio_ok = n_dirty * 4 <= t.nrows;
            const have_base = base_bytes > 0;
            var use_delta = ratio_ok and have_base and replay_ns < rewrite_ns;
            var why: []const u8 = if (!ratio_ok)
                "dirty>25%"
            else if (!have_base)
                "no-base"
            else if (replay_ns >= rewrite_ns)
                "replay>rewrite"
            else
                "cost";
            if (std.c.getenv("ZHDB_DELTA_MAX")) |v| {
                const delta_max = std.fmt.parseInt(usize, std.mem.span(v), 10) catch 0;
                if (delta_max > 0 and buf.items.len > delta_max) {
                    use_delta = false;
                    why = "ZHDB_DELTA_MAX";
                }
            }
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[writeback] {s}: policy dirty={d} delta_rows={d} delta_bytes={d} base_bytes={d} replay={d:.1}us rewrite={d:.1}us (write={d:.2}ns/B enc={d:.1}ns/row rep={d:.1}ns/row) -> {s} ({s})\n", .{
                    table, n_dirty, delta_rows, buf.items.len, base_bytes, replay_ns / 1000.0, rewrite_ns / 1000.0,
                    WRITE_NS_PER_BYTE, ENCODE_ROW_NS, REPLAY_ROW_NS,
                    if (use_delta) "delta" else "full", why,
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

        // Full path: persist the current image (tombstones and in-place string
        // patches are part of the format), and drop the sidecar delta.
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

    /// VACUUM [table]: physically reclaim tombstoned rows (incremental on top of
    /// the tombstone bitmap; the snapshot is compacted at save time anyway).
    /// Physically rewrite a table when its interior dead rows dominate: this is
    /// the only way to reclaim middle blocks (row ids are renumbered, so the
    /// columnar copy and any B+ tree are rebuilt in the same step).
    /// Cost-model decision for interior compaction. Compacting rewrites every
    /// surviving row (measured ~79 ns/row for the 1M-row table); *not*
    /// compacting makes every future scan pay for the dead rows and lose the
    /// tombstone-free fast path (measured ~4x slower per scanned row). Compare
    /// the one-off rewrite against the penalty over the expected number of
    /// future scans (`ZHDB_COMPACT_Q`, default 20).
    /// Cost model: does rewriting the table now pay for itself over the expected
    /// remaining scans (learned from observed scan counts)?
    fn compactPays(self: *Engine, name: []const u8, dead_hint: usize) bool {
        const t = self.find(name) orelse return false;
        const rows = t.rows.items.len;
        const dead = @max(t.dead_rows, dead_hint);
        if (rows < 64 or dead == 0) return false;
        self.calibrateCostsFor(self.findColumnar(name));
        var q: f64 = 20;
        const observed: f64 = @floatFromInt(self.scansOf(name));
        if (observed > q) q = observed;
        if (std.c.getenv("ZHDB_COMPACT_Q")) |v| q = std.fmt.parseFloat(f64, std.mem.span(v)) catch q;
        const n: f64 = @floatFromInt(rows);
        const d: f64 = @floatFromInt(dead);
        const rewrite_cost = n * COST_COMPACT_ROW_NS;
        const scan_penalty = d * self.cost_scan_row * COST_TOMB_FACTOR;
        return scan_penalty * q > rewrite_cost;
    }

    fn compactIfDense(self: *Engine, name: []const u8, dead_hint: usize) usize {
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
                name, dead, rows, d / n * 100.0, scan_penalty / 1e6, scan_penalty * q / 1e6, rewrite_cost / 1e6, q, self.scansOf(name), if (should) "compact" else "keep",
            });
        }
        if (!should) return 0;
        const before = rows;
        self.compactTable(name);
        const after = (self.find(name) orelse return 0).rows.items.len;
        return before - after;
    }

    /// Physically present dead rows (tombstoned or superseded, committed) and how
    /// many whole columnar blocks they occupy. VACUUM uses this to decide whether
    /// block compaction can hand space back to the file.
    const DeadBlocks = struct { rows: usize = 0, full: usize = 0, partial: usize = 0 };

    fn deadBlocks(self: *Engine, t: *Table) DeadBlocks {
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
            // A block worth rewriting in the background: at least a quarter of
            // its rows are dead (and it is not already a whole dead block).
            if (seg_len > 0 and dead >= (seg_len + 3) / 4 and dead < seg_len) partial += 1;
        }
        return .{ .rows = rows, .full = full, .partial = partial };
    }

    /// Cost/space model for reclaiming dead blocks, evaluated **per block**:
    /// rewrite cost vs (scan penalty over the learned expected scans + the
    /// reclaimed space share). Any block that pays off triggers compaction.
    fn compactionWorthIt(self: *Engine, name: []const u8, db: DeadBlocks) bool {
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
                    name, b, dead, r1 - r0, d / blen * 100.0, q,
                    rewrite_b / 1e6, scan_b / 1e6, space_b / 1e6,
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

    fn execVacuum(self: *Engine, name: ?[]const u8) EngineError!Result {
        if (name) |n| {
            // A freshly loaded snapshot has only the columnar image; VACUUM needs
            // the row store to inspect tombstones and renumber survivors.
            self.ensureRowsMaterialized(n);
            const db = if (self.find(n)) |tt| self.deadBlocks(tt) else DeadBlocks{};
            var st = self.reclaimSegments(n);
            const dropped = self.truncateDeadTail(n);
            // Explicit VACUUM returns physical space. A whole dead block is
            // space only compaction can hand back to the file (free slots just
            // wait for a future INSERT), so compact block-wise -- live blocks are
            // copied, dead blocks dropped, partial blocks rewritten.
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
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[vacuum] {s}: segments={d} rows={d} tail_rows={d} blocks_dropped={d}\n", .{ n, st.segments, st.rows - dropped, dropped, st.blocks_dropped });
            }
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
            var block_compact = false;
            const comp = if (db.full > 0) blk: {
                block_compact = true;
                self.compactTable(nm);
                break :blk 1;
            } else self.compactIfDense(nm, db.rows);
            if (comp > 0 and std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[vacuum] {s}: {s} ({d} rows)\n", .{
                    nm, if (block_compact) "block compaction" else "compacted interior", comp,
                });
            }
            if (st.rows + dropped > 0 and std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[vacuum] {s}: segments={d} rows={d} tail_rows={d}\n", .{ nm, st.segments, st.rows, dropped });
            }
        }
        return .{ .affected = 0 };
    }

    /// CREATE INDEX: build a sorted key index over one int column so point and
    /// range predicates can seek instead of scanning.
    fn execCreateIndex(self: *Engine, name: []const u8, table: []const u8, col: []const u8) EngineError!Result {
        _ = name;
        const ct = self.findColumnar(table) orelse return error.TableNotFound;
        const ci = ct.find(col) orelse return error.UnknownColumn;
        // Only integer columns get a key index; other types keep the
        // declared index as a no-op (correctness is unaffected).
        const vals = switch (ct.data[ci]) {
            .ints => |v| v,
            else => return .{},
        };
        if (ct.keyidx.len == 0) {
            ct.keyidx = try ct.arena.allocator().alloc(?*columnar.KeyIndex, ct.cols.len);
            @memset(ct.keyidx, null);
        }
        ct.keyidx[ci] = try columnar.KeyIndex.build(ct.arena.allocator(), vals, ct.block_rows);
        return .{ .affected = 1 };
    }

    /// ANALYZE: sample the key columns to get NDV / NULL count / range. NDV comes
    /// from the dictionary when available (exact), otherwise from a 20k sample.
    fn execAnalyze(self: *Engine, name: []const u8) EngineError!Result {
        const t = self.find(name) orelse return error.TableNotFound;
        self.ensureRowsMaterialized(name);
        const gpa = self.gpa;
        if (t.stats.len != t.cols.len) {
            t.stats = try gpa.alloc(ColStat, t.cols.len);
            @memset(t.stats, .{});
        }
        const ct = self.findColumnar(name);
        if (std.c.getenv("ZHDB_DBG_STATS") != null) {
            if (ct) |tab| {
                std.debug.print("[stats] analyze {s}: requests p={d} t={d} s={d}\n", .{ name, tab.pair_req.len, tab.triple_req.len, tab.multi_req.len });
            } else {
                std.debug.print("[stats] analyze {s}: no columnar copy\n", .{name});
            }
        }
        for (t.cols, 0..) |c, ci| {
            // A re-ANALYZE replaces the arrays; release the previous ones first.
            if (ci < t.stats.len) {
                const prev = t.stats[ci];
                if (prev.mcv.len > 0) gpa.free(prev.mcv);
                if (prev.hist.len > 0) gpa.free(prev.hist);
                if (prev.hist_ndv.len > 0) gpa.free(prev.hist_ndv);
                if (prev.hist_lo.len > 0) gpa.free(prev.hist_lo);
                if (prev.hist_hi.len > 0) gpa.free(prev.hist_hi);
                for (prev.mcv_str) |m| gpa.free(m.s);
                if (prev.mcv_str.len > 0) gpa.free(prev.mcv_str);
                for (prev.hist_str) |x| gpa.free(x);
                if (prev.hist_str.len > 0) gpa.free(prev.hist_str);
                if (prev.hist_str_ndv.len > 0) gpa.free(prev.hist_str_ndv);
                if (prev.min_str.len > 0) gpa.free(prev.min_str);
                if (prev.max_str.len > 0) gpa.free(prev.max_str);
                if (prev.ngram.len > 0) gpa.free(prev.ngram);
                if (prev.suf.len > 0) gpa.free(prev.suf);
                for (prev.dict) |e| gpa.free(e.s);
                if (prev.dict.len > 0) gpa.free(prev.dict);
                if (prev.res_min.len > 0) gpa.free(prev.res_min);
                if (prev.res_max.len > 0) gpa.free(prev.res_max);
                for (prev.res_hist) |x| gpa.free(x);
                if (prev.res_hist.len > 0) gpa.free(prev.res_hist);
                if (prev.res_hist_ndv.len > 0) gpa.free(prev.res_hist_ndv);
                if (prev.res_hist_mass.len > 0) gpa.free(prev.res_hist_mass);
                for (prev.res_sub) |x| gpa.free(x);
                if (prev.res_sub.len > 0) gpa.free(prev.res_sub);
                if (prev.res_sub_mass.len > 0) gpa.free(prev.res_sub_mass);
                if (prev.res_sub_ndv.len > 0) gpa.free(prev.res_sub_ndv);
                if (prev.res_sub_cum.len > 0) gpa.free(prev.res_sub_cum);
                for (prev.res_cdf_vals) |x| gpa.free(x);
                if (prev.res_cdf_vals.len > 0) gpa.free(prev.res_cdf_vals);
                if (prev.res_cdf_cum.len > 0) gpa.free(prev.res_cdf_cum);
            }
            var st = ColStat{};
            if (ct) |tab| {
                if (tab.enc.len > ci) {
                    if (tab.enc[ci]) |e| st.ndv = e.first.len;
                }
            }
            st.nulls = 0;
            st.min = std.math.maxInt(i64);
            st.max = std.math.minInt(i64);
            var sampled: usize = 0;
            var seen = std.AutoHashMap(i64, usize).init(gpa);
            defer seen.deinit();
            var vals = std.ArrayList(i64).empty;
            defer vals.deinit(gpa);
            var sseen = std.StringHashMap(usize).init(gpa);
            defer sseen.deinit();
            var svals = std.ArrayList([]const u8).empty;
            defer svals.deinit(gpa);
            var ri: usize = 0;
            // Small/medium tables are scanned exhaustively (exact counts, ndv and
            // dictionaries); larger ones sample ~20k rows. An even stride aliases
            // periodic data, so keep it odd.
            var step: usize = if (t.rows.items.len <= 262_144)
                1
            else
                @max(1, t.rows.items.len / 20000);
            if (step > 1 and step % 2 == 0) step += 1;
            while (ri < t.rows.items.len) : (ri += step) {
                const v = t.rows.items[ri][ci];
                if (tableIsNull(t, ci, ri)) {
                    st.nulls += 1;
                    continue;
                }
                sampled += 1;
                switch (v) {
                    .int => |x| {
                        st.min = @min(st.min, x);
                        st.max = @max(st.max, x);
                        const gop = seen.getOrPut(x) catch continue;
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                        vals.append(gpa, x) catch {};
                    },
                    .float => |x| {
                        if (std.math.isNan(x)) continue;
                        const k = f64Key(x);
                        st.min = @min(st.min, k);
                        st.max = @max(st.max, k);
                        const gop = seen.getOrPut(k) catch continue;
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                        vals.append(gpa, k) catch {};
                    },
                    .text => |x| {
                        const gop = sseen.getOrPut(x) catch continue;
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                        svals.append(gpa, x) catch {};
                    },
                    else => {},
                }
            }
            if (st.ndv == 0 and seen.count() > 0) st.ndv = seen.count();
            if (st.min > st.max) st.min = 0;
            // Skew-aware statistics for integer columns: top-16 MCVs and a
            // 32-bucket equi-depth histogram (both replace the uniform model).
            if (st.mcv.len > 0) gpa.free(st.mcv);
            if (st.hist.len > 0) gpa.free(st.hist);
            if (st.hist_ndv.len > 0) gpa.free(st.hist_ndv);
            if (st.hist_lo.len > 0) gpa.free(st.hist_lo);
            if (st.hist_hi.len > 0) gpa.free(st.hist_hi);
            st.mcv = &.{};
            st.hist = &.{};
            st.hist_ndv = &.{};
            st.hist_lo = &.{};
            st.hist_hi = &.{};
            st.mcv_mass = 0;
            const is_int = switch (c.ty) {
                .int, .boolean, .float => true,
                else => false,
            };
            if (is_int and sampled >= 64) {
                const total: f64 = @floatFromInt(sampled);
                var entries = std.ArrayList(McvEntry).empty;
                defer entries.deinit(gpa);
                var it2 = seen.iterator();
                while (it2.next()) |e| {
                    const cnt = e.value_ptr.*;
                    if (cnt < 2) continue;
                    const freq = @as(f64, @floatFromInt(cnt)) / total;
                    if (freq < 0.005) continue;
                    entries.append(gpa, .{ .v = e.key_ptr.*, .freq = freq }) catch {};
                }
                std.mem.sort(McvEntry, entries.items, {}, struct {
                    fn gt(_: void, a: McvEntry, b: McvEntry) bool {
                        return a.freq > b.freq;
                    }
                }.gt);
                const take = @min(entries.items.len, 16);
                if (take > 0) {
                    if (gpa.alloc(McvEntry, take)) |m| {
                        @memcpy(m, entries.items[0..take]);
                        st.mcv = m;
                        for (m) |e2| st.mcv_mass += e2.freq;
                        st.mcv_mass = @min(st.mcv_mass, 1.0);
                    } else |_| {}
                }
                std.mem.sort(i64, vals.items, {}, std.sort.asc(i64));
                const B: usize = 32;
                var bounds = std.ArrayList(i64).empty;
                defer bounds.deinit(gpa);
                var bpos = std.ArrayList(usize).empty;
                defer bpos.deinit(gpa);
                var bi: usize = 0;
                // Keep duplicate quantile values: dropping them would break the
                // equi-depth property on low-cardinality (skewed) columns.
                while (bi <= B) : (bi += 1) {
                    const idx = @min((bi * sampled) / B, sampled - 1);
                    bounds.append(gpa, vals.items[idx]) catch {};
                    bpos.append(gpa, idx) catch {};
                }
                if (bounds.items.len > 0) {
                    if (st.max != std.math.maxInt(i64)) {
                        const last = bounds.items[bounds.items.len - 1];
                        if (last <= st.max) {
                            bounds.append(gpa, st.max + 1) catch {};
                            bpos.append(gpa, sampled - 1) catch {};
                        }
                    }
                    if (gpa.alloc(i64, bounds.items.len)) |h| {
                        @memcpy(h, bounds.items);
                        st.hist = h;
                    } else |_| {}
                    const nb = bounds.items.len - 1;
                    if (nb > 0) {
                        if (gpa.alloc(u32, nb)) |hndv| {
                            const hlo = gpa.alloc(i64, nb) catch null;
                            const hhi = gpa.alloc(i64, nb) catch null;
                            var bj: usize = 0;
                            while (bj < nb) : (bj += 1) {
                                const lo2 = bpos.items[bj];
                                const hi2 = @min(bpos.items[bj + 1] + 1, sampled);
                                var distinct: u32 = 0;
                                if (hi2 > lo2) {
                                    distinct = 1;
                                    var z = lo2 + 1;
                                    while (z < hi2) : (z += 1) {
                                        if (vals.items[z] != vals.items[z - 1]) distinct += 1;
                                    }
                                }
                                hndv[bj] = distinct;
                                if (hlo != null and hhi != null) {
                                    hlo.?[bj] = vals.items[lo2];
                                    hhi.?[bj] = vals.items[@min(hi2 - 1, sampled - 1)];
                                }
                            }
                            st.hist_ndv = hndv;
                            if (hlo != null and hhi != null) {
                                st.hist_lo = hlo.?;
                                st.hist_hi = hhi.?;
                            } else {
                                if (hlo) |x| gpa.free(x);
                                if (hhi) |x| gpa.free(x);
                            }
                        } else |_| {}
                    }
                }
            }
            // String columns: dictionary-value MCVs + lexicographic equi-depth
            // histogram (used for string equality and string join keys).
            for (st.mcv_str) |m| gpa.free(m.s);
            if (st.mcv_str.len > 0) gpa.free(st.mcv_str);
            for (st.hist_str) |h| gpa.free(h);
            if (st.hist_str.len > 0) gpa.free(st.hist_str);
            if (st.min_str.len > 0) gpa.free(st.min_str);
            if (st.max_str.len > 0) gpa.free(st.max_str);
            if (st.ngram.len > 0) gpa.free(st.ngram);
            if (st.suf.len > 0) gpa.free(st.suf);
            if (st.hist_str_ndv.len > 0) gpa.free(st.hist_str_ndv);
            for (st.hist_str_lo) |x| gpa.free(x);
            if (st.hist_str_lo.len > 0) gpa.free(st.hist_str_lo);
            for (st.hist_str_hi) |x| gpa.free(x);
            if (st.hist_str_hi.len > 0) gpa.free(st.hist_str_hi);
            for (st.dict) |e| gpa.free(e.s);
            if (st.dict.len > 0) gpa.free(st.dict);
            if (st.res_min.len > 0) gpa.free(st.res_min);
            if (st.res_max.len > 0) gpa.free(st.res_max);
            for (st.res_hist) |x| gpa.free(x);
            if (st.res_hist.len > 0) gpa.free(st.res_hist);
            if (st.res_hist_ndv.len > 0) gpa.free(st.res_hist_ndv);
            if (st.res_hist_mass.len > 0) gpa.free(st.res_hist_mass);
            for (st.res_sub) |x| gpa.free(x);
            if (st.res_sub.len > 0) gpa.free(st.res_sub);
            if (st.res_sub_mass.len > 0) gpa.free(st.res_sub_mass);
            if (st.res_sub_ndv.len > 0) gpa.free(st.res_sub_ndv);
            if (st.res_sub_cum.len > 0) gpa.free(st.res_sub_cum);
            for (st.res_cdf_vals) |x| gpa.free(x);
            if (st.res_cdf_vals.len > 0) gpa.free(st.res_cdf_vals);
            if (st.res_cdf_cum.len > 0) gpa.free(st.res_cdf_cum);
            st.ngram = &.{};
            st.suf = &.{};
            st.hist_str_ndv = &.{};
            st.hist_str_lo = &.{};
            st.hist_str_hi = &.{};
            st.mcv_str = &.{};
            st.hist_str = &.{};
            st.min_str = &.{};
            st.max_str = &.{};
            st.mcv_str_mass = 0;
            if ((c.ty == .text or c.ty == .date or c.ty == .timestamp) and sampled >= 64 and svals.items.len > 0) {
                const total: f64 = @floatFromInt(sampled);
                var sentries = std.ArrayList(McvStr).empty;
                defer sentries.deinit(gpa);
                var sit = sseen.iterator();
                while (sit.next()) |e| {
                    const cnt = e.value_ptr.*;
                    if (cnt < 2) continue;
                    const freq = @as(f64, @floatFromInt(cnt)) / total;
                    if (freq < 0.005) continue;
                    const dup = gpa.dupe(u8, e.key_ptr.*) catch continue;
                    sentries.append(gpa, .{ .s = dup, .freq = freq }) catch gpa.free(dup);
                }
                std.mem.sort(McvStr, sentries.items, {}, struct {
                    fn gt(_: void, a: McvStr, b: McvStr) bool {
                        return a.freq > b.freq;
                    }
                }.gt);
                const stake = @min(sentries.items.len, 16);
                if (stake > 0) {
                    if (gpa.alloc(McvStr, stake)) |m| {
                        @memcpy(m, sentries.items[0..stake]);
                        for (m) |e2| st.mcv_str_mass += e2.freq;
                        st.mcv_str_mass = @min(st.mcv_str_mass, 1.0);
                        st.mcv_str = m;
                        // Moved into `st.mcv_str`; free the unselected tail and
                        // detach the list buffer from the deferred cleanup.
                        for (sentries.items[stake..]) |e2| gpa.free(e2.s);
                        sentries.items.len = 0;
                    } else |_| {
                        for (sentries.items) |e2| gpa.free(e2.s);
                        sentries.items.len = 0;
                    }
                } else {
                    for (sentries.items) |e2| gpa.free(e2.s);
                    sentries.items.len = 0;
                }
                const Ctx = struct {
                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                };
                std.mem.sort([]const u8, svals.items, {}, Ctx.lt);
                const S = svals.items.len;
                st.min_str = gpa.dupe(u8, svals.items[0]) catch &.{};
                st.max_str = gpa.dupe(u8, svals.items[S - 1]) catch &.{};
                const B: usize = 32;
                var sb = std.ArrayList([]u8).empty;
                defer {
                    for (sb.items) |x| gpa.free(x);
                    sb.deinit(gpa);
                }
                var spos = std.ArrayList(usize).empty;
                defer spos.deinit(gpa);
                var bi: usize = 0;
                while (bi <= B) : (bi += 1) {
                    const idx = @min((bi * S) / B, S - 1);
                    const dup2 = gpa.dupe(u8, svals.items[idx]) catch continue;
                    sb.append(gpa, dup2) catch gpa.free(dup2);
                    spos.append(gpa, idx) catch {};
                }
                if (sb.items.len > 0) {
                    const nbounds = sb.items.len;
                    if (gpa.alloc([]u8, nbounds)) |h| {
                        @memcpy(h, sb.items);
                        st.hist_str = h;
                        sb.items.len = 0;
                    } else |_| {}
                    const nb = if (nbounds > 0) nbounds - 1 else 0;
                    if (nb > 0 and spos.items.len >= nbounds) {
                        if (gpa.alloc(u32, nb)) |hsn| {
                            const hslo = gpa.alloc([]u8, nb) catch null;
                            const hshi = gpa.alloc([]u8, nb) catch null;
                            var bj: usize = 0;
                            while (bj < nb) : (bj += 1) {
                                const lo2 = spos.items[bj];
                                const hi2 = @min(spos.items[bj + 1] + 1, S);
                                var distinct: u32 = 0;
                                if (hi2 > lo2) {
                                    distinct = 1;
                                    var z = lo2 + 1;
                                    while (z < hi2) : (z += 1) {
                                        if (!std.mem.eql(u8, svals.items[z], svals.items[z - 1])) distinct += 1;
                                    }
                                }
                                hsn[bj] = distinct;
                                if (hslo != null and hshi != null) {
                                    hslo.?[bj] = gpa.dupe(u8, svals.items[lo2]) catch &.{};
                                    hshi.?[bj] = gpa.dupe(u8, svals.items[@min(hi2 - 1, S - 1)]) catch &.{};
                                }
                            }
                            st.hist_str_ndv = hsn;
                            if (hslo != null and hshi != null) {
                                st.hist_str_lo = hslo.?;
                                st.hist_str_hi = hshi.?;
                            } else {
                                if (hslo) |x| gpa.free(x);
                                if (hshi) |x| gpa.free(x);
                            }
                        } else |_| {}
                    }
                }
                // Large dictionaries: bounded sampled frequency map (top-512).
                if (st.ndv > 65_536 and sampled >= 64) {
                    var sents = std.ArrayList(DictEntry).empty;
                    defer sents.deinit(gpa);
                    var sit4 = sseen.iterator();
                    while (sit4.next()) |e| {
                        const dup = gpa.dupe(u8, e.key_ptr.*) catch continue;
                        sents.append(gpa, .{ .s = dup, .count = @intCast(e.value_ptr.*) }) catch gpa.free(dup);
                    }
                    std.mem.sort(DictEntry, sents.items, {}, struct {
                        fn gt(_: void, a: DictEntry, b: DictEntry) bool {
                            return a.count > b.count;
                        }
                    }.gt);
                    const stk = @min(sents.items.len, 512);
                    if (stk > 0) {
                        if (gpa.alloc(DictEntry, stk)) |dm| {
                            @memcpy(dm, sents.items[0..stk]);
                            for (sents.items[stk..]) |e| gpa.free(e.s);
                            sents.items.len = 0;
                            st.dict = dm;
                            st.dict_sampled = true;
                            st.dict_sample_rows = sampled;
                            // Residual (non-map) value range for the skew-aware
                            // join residual.
                            var mapset = std.StringHashMap(void).init(gpa);
                            defer mapset.deinit();
                            for (dm) |e| mapset.put(e.s, {}) catch {};
                            var rmin: ?[]const u8 = null;
                            var rmax: ?[]const u8 = null;
                            var rvals = std.ArrayList([]const u8).empty;
                            defer rvals.deinit(gpa);
                            for (svals.items) |vv2| {
                                if (mapset.contains(vv2)) continue;
                                if (rmin == null or std.mem.order(u8, vv2, rmin.?) == .lt) rmin = vv2;
                                if (rmax == null or std.mem.order(u8, vv2, rmax.?) == .gt) rmax = vv2;
                                rvals.append(gpa, vv2) catch {};
                            }
                            if (rmin != null and rmax != null) {
                                st.res_min = gpa.dupe(u8, rmin.?) catch &.{};
                                st.res_max = gpa.dupe(u8, rmax.?) catch &.{};
                                // Equi-depth residual histogram (16 buckets) with
                                // per-bucket distinct counts.
                                const RB: usize = 16;
                                const RS = rvals.items.len;
                                if (RS > 0) {
                                    std.mem.sort([]const u8, rvals.items, {}, struct {
                                        fn lt(_: void, a: []const u8, b: []const u8) bool {
                                            return std.mem.order(u8, a, b) == .lt;
                                        }
                                    }.lt);
                                    const rpos = gpa.alloc(usize, RB + 1) catch null;
                                    if (rpos) |rp| {
                                        var bi4: usize = 0;
                                        while (bi4 <= RB) : (bi4 += 1) rp[bi4] = @min((bi4 * RS) / RB, RS - 1);
                                        if (gpa.alloc(u32, RB)) |rndv| {
                                            const rmass = gpa.alloc(u32, RB) catch null;
                                            var bj5: usize = 0;
                                            while (bj5 < RB) : (bj5 += 1) {
                                                const lo4 = rp[bj5];
                                                const hi4 = @min(rp[bj5 + 1] + 1, RS);
                                                var dst: u32 = 0;
                                                if (hi4 > lo4) {
                                                    dst = 1;
                                                    var z6 = lo4 + 1;
                                                    while (z6 < hi4) : (z6 += 1) {
                                                        if (!std.mem.eql(u8, rvals.items[z6], rvals.items[z6 - 1])) dst += 1;
                                                    }
                                                }
                                                rndv[bj5] = dst;
                                                if (rmass) |rm| rm[bj5] = @intCast(hi4 - lo4);
                                            }
                                            st.res_hist_ndv = rndv;
                                            if (rmass) |rm| {
                                                st.res_hist_mass = rm;
                                            }
                                        } else |_| {}
                                        if (gpa.alloc([]u8, RB + 1)) |rh| {
                                            var bj6: usize = 0;
                                            while (bj6 <= RB) : (bj6 += 1) {
                                                rh[bj6] = gpa.dupe(u8, rvals.items[rp[bj6]]) catch &.{};
                                            }
                                            st.res_hist = rh;
                                        } else |_| {}
                                        // Second level: S sub-buckets per residual
                                        // bucket (boundaries, mass, distinct count).
                                        {
                                            // 128 sub-buckets per residual bucket =>
                                            // 1/2048-of-the-residual CDF resolution.
                                            const SUB: usize = 128;
                                            const nsub = RB * SUB;
                                            const smass = gpa.alloc(u32, nsub) catch null;
                                            const sndv = gpa.alloc(u32, nsub) catch null;
                                            var sub = std.ArrayList([]u8).empty;
                                            var ok = smass != null and sndv != null;
                                            var bb: usize = 0;
                                            while (bb < RB and ok) : (bb += 1) {
                                                const lo5 = rp[bb];
                                                const hi5 = @min(rp[bb + 1] + 1, RS);
                                                const width = hi5 - lo5;
                                                var ss: usize = 0;
                                                while (ss <= SUB) : (ss += 1) {
                                                    const idx = lo5 + (ss * width) / SUB;
                                                    const cidx = @min(idx, hi5 - 1);
                                                    const dup = gpa.dupe(u8, rvals.items[cidx]) catch {
                                                        ok = false;
                                                        break;
                                                    };
                                                    sub.append(gpa, dup) catch {
                                                        gpa.free(dup);
                                                        ok = false;
                                                        break;
                                                    };
                                                }
                                                ss = 0;
                                                while (ss < SUB) : (ss += 1) {
                                                    const a0 = lo5 + (ss * width) / SUB;
                                                    const a1 = lo5 + ((ss + 1) * width) / SUB;
                                                    smass.?[bb * SUB + ss] = @intCast(a1 - a0);
                                                    var dst: u32 = 0;
                                                    if (a1 > a0) {
                                                        dst = 1;
                                                        var z7 = a0 + 1;
                                                        while (z7 < a1) : (z7 += 1) {
                                                            if (!std.mem.eql(u8, rvals.items[z7], rvals.items[z7 - 1])) dst += 1;
                                                        }
                                                    }
                                                    sndv.?[bb * SUB + ss] = dst;
                                                }
                                            }
                                            if (ok and sub.items.len == RB * (SUB + 1)) {
                                                if (gpa.alloc(u32, nsub)) |scum| {
                                                    var acc: u32 = 0;
                                                    var zi: usize = 0;
                                                    while (zi < nsub) : (zi += 1) {
                                                        acc += smass.?[zi];
                                                        scum[zi] = acc;
                                                    }
                                                    st.res_sub_cum = scum;
                                                } else |_| {}
                                                st.res_sub = sub.items;
                                                st.res_sub_mass = smass.?;
                                                st.res_sub_ndv = sndv.?;
                                                sub.items.len = 0; // detach
                                            } else {
                                                for (sub.items) |x| gpa.free(x);
                                                sub.deinit(gpa);
                                                if (smass) |x| gpa.free(x);
                                                if (sndv) |x| gpa.free(x);
                                            }
                                        }
                                        // Exact residual CDF (sorted distinct
                                        // values + cumulative counts) when it
                                        // fits the byte budget. From a partial
                                        // sample it is exact for the sample.
                                        {
                                            var uniq = std.ArrayList([]u8).empty;
                                            var cum = std.ArrayList(u32).empty;
                                            var bytes: usize = 0;
                                            var ui: usize = 0;
                                            var fits = true;
                                            while (ui < RS) {
                                                const v0 = rvals.items[ui];
                                                var uj = ui + 1;
                                                while (uj < RS and std.mem.eql(u8, rvals.items[uj], v0)) uj += 1;
                                                bytes += v0.len + 24;
                                                if (bytes > RES_CDF_BUDGET) {
                                                    fits = false;
                                                    break;
                                                }
                                                const dup = gpa.dupe(u8, v0) catch {
                                                    fits = false;
                                                    break;
                                                };
                                                uniq.append(gpa, dup) catch {
                                                    gpa.free(dup);
                                                    fits = false;
                                                    break;
                                                };
                                                const prevc: u32 = if (cum.items.len > 0) cum.items[cum.items.len - 1] else 0;
                                                cum.append(gpa, prevc + @as(u32, @intCast(uj - ui))) catch {
                                                    fits = false;
                                                    break;
                                                };
                                                ui = uj;
                                            }
                                            if (fits and uniq.items.len > 0 and uniq.items.len == cum.items.len) {
                                                st.res_cdf_vals = uniq.items;
                                                st.res_cdf_cum = cum.items;
                                            } else {
                                                for (uniq.items) |x| gpa.free(x);
                                                uniq.deinit(gpa);
                                                cum.deinit(gpa);
                                            }
                                        }
                                        gpa.free(rp);
                                    }
                                }
                            }
                        } else |_| {
                            for (sents.items) |e| gpa.free(e.s);
                            sents.items.len = 0;
                        }
                    }
                }
                // Exact small-dictionary counts (full scan, ndv <= 4096).
                if (st.ndv > 0 and st.ndv <= 65_536) {
                    var dmap = std.StringHashMap(u32).init(gpa);
                    defer dmap.deinit();
                    var ri2: usize = 0;
                    while (ri2 < t.rows.items.len) : (ri2 += 1) {
                        const vv = t.rows.items[ri2][ci];
                        if (vv != .text) continue;
                        const gop = dmap.getOrPut(vv.text) catch continue;
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                    }
                    if (dmap.count() > 0 and dmap.count() <= 65_536) {
                        if (gpa.alloc(DictEntry, dmap.count())) |de| {
                            var it3 = dmap.iterator();
                            var idx3: usize = 0;
                            var okall = true;
                            while (it3.next()) |e| {
                                de[idx3] = .{ .s = gpa.dupe(u8, e.key_ptr.*) catch {
                                    okall = false;
                                    break;
                                }, .count = e.value_ptr.* };
                                idx3 += 1;
                            }
                            if (okall) {
                                st.dict = de;
                                var tot3: usize = 0;
                                for (de) |e| tot3 += e.count;
                                st.dict_sample_rows = tot3;
                                st.dict_sampled = false;
                            } else {
                                for (de[0..idx3]) |e| gpa.free(e.s);
                                gpa.free(de);
                            }
                        } else |_| {}
                    }
                }
                // Trigram document frequencies for infix/suffix LIKE.
                {
                    var grams = std.AutoHashMap(u32, u32).init(gpa);
                    defer grams.deinit();
                    var vseen: [64]u32 = undefined;
                    for (svals.items) |v3| {
                        var nseen: usize = 0;
                        const lim = @min(v3.len, 64);
                        if (lim >= 3) {
                            var k3: usize = 0;
                            while (k3 + 3 <= lim) : (k3 += 1) {
                                const g = (@as(u32, v3[k3]) << 16) | (@as(u32, v3[k3 + 1]) << 8) | @as(u32, v3[k3 + 2]);
                                var dup = false;
                                for (vseen[0..nseen]) |x| {
                                    if (x == g) {
                                        dup = true;
                                        break;
                                    }
                                }
                                if (dup or nseen >= vseen.len) continue;
                                vseen[nseen] = g;
                                nseen += 1;
                                if (grams.count() >= 8192) {
                                    if (grams.getPtr(g)) |p| p.* += 1;
                                } else {
                                    const gop = grams.getOrPut(g) catch continue;
                                    if (!gop.found_existing) gop.value_ptr.* = 0;
                                    gop.value_ptr.* += 1;
                                }
                            }
                        }
                    }
                    var top = std.ArrayList(GramCount).empty;
                    defer top.deinit(gpa);
                    var git = grams.iterator();
                    while (git.next()) |e| {
                        top.append(gpa, .{ .g = e.key_ptr.*, .c = e.value_ptr.* }) catch {};
                    }
                    std.mem.sort(GramCount, top.items, {}, struct {
                        fn gt(_: void, a: GramCount, b: GramCount) bool {
                            return a.c > b.c;
                        }
                    }.gt);
                    const ntake = @min(top.items.len, 256);
                    if (ntake > 0) {
                        if (gpa.alloc(NgramStat, ntake)) |ns| {
                            for (top.items[0..ntake], 0..) |e, i| {
                                ns[i] = .{
                                    .g = .{ @truncate(e.g >> 16), @truncate(e.g >> 8), @truncate(e.g) },
                                    .freq = @as(f64, @floatFromInt(e.c)) / total,
                                };
                            }
                            st.ngram = ns;
                        } else |_| {}
                    }
                    // Suffix 1..3-byte document frequencies.
                    var smap = std.AutoHashMap(u32, u32).init(gpa);
                    defer smap.deinit();
                    for (svals.items) |v3| {
                        var L: usize = 1;
                        while (L <= 3 and L <= v3.len) : (L += 1) {
                            const start3 = v3.len - L;
                            var key: u32 = @intCast(L);
                            var kk: usize = 0;
                            while (kk < 3) : (kk += 1) {
                                const b: u8 = if (kk < L) v3[start3 + kk] else 0;
                                key = (key << 8) | @as(u32, b);
                            }
                            const gop = smap.getOrPut(key) catch continue;
                            if (!gop.found_existing) gop.value_ptr.* = 0;
                            gop.value_ptr.* += 1;
                        }
                    }
                    var stop = std.ArrayList(GramCount).empty;
                    defer stop.deinit(gpa);
                    var sit2 = smap.iterator();
                    while (sit2.next()) |e| stop.append(gpa, .{ .g = e.key_ptr.*, .c = e.value_ptr.* }) catch {};
                    std.mem.sort(GramCount, stop.items, {}, struct {
                        fn gt(_: void, a: GramCount, b: GramCount) bool {
                            return a.c > b.c;
                        }
                    }.gt);
                    const stail = @min(stop.items.len, 128);
                    if (stail > 0) {
                        if (gpa.alloc(SuffixStat, stail)) |ss| {
                            for (stop.items[0..stail], 0..) |e, i| {
                                ss[i] = .{
                                    .len = @truncate(e.g >> 24),
                                    .s = .{ @truncate(e.g >> 16), @truncate(e.g >> 8), @truncate(e.g) },
                                    .freq = @as(f64, @floatFromInt(e.c)) / total,
                                };
                            }
                            st.suf = ss;
                        } else |_| {}
                    }
                }
            }
            if (std.c.getenv("ZHDB_DBG_STATS") != null and st.mcv_str.len > 0) {
                std.debug.print("[stats] {s}.{s}: ndv={d} mcv_str={d} mass={d:.3} hist_str={d} ngram={d}\n", .{ name, c.name, st.ndv, st.mcv_str.len, st.mcv_str_mass, st.hist_str.len, st.ngram.len });
                for (st.mcv_str[0..@min(st.mcv_str.len, 4)]) |m| {
                    std.debug.print("[stats]   mcv '{s}' freq={d:.3}\n", .{ m.s, m.freq });
                }
                for (st.ngram[0..@min(st.ngram.len, 40)]) |ng| {
                    std.debug.print("[stats]   ng '{c}{c}{c}' f={d:.3}\n", .{ ng.g[0], ng.g[1], ng.g[2], ng.freq });
                }
            }
            t.stats[ci] = st;
        }

        // Column-pair NDV: only the pairs the planner actually asked for (the
        // two equality predicates it combines in AND pushdown). Collected here,
        // bounded, so planning never samples statistics on the query path.
        if (ct) |tab| {
            var pairs: usize = 0;
            for (tab.pair_req) |req| {
                _ = tab.pairNdvOf(gpa, req.a, req.b);
                pairs += 1;
                if (pairs >= 4096) break; // sanity bound only
            }
            var triples: usize = 0;
            for (tab.triple_req) |req| {
                _ = tab.tripleNdvOf(gpa, req.a, req.b, req.c);
                triples += 1;
                if (triples >= 4096) break;
            }
            var sets: usize = 0;
            for (tab.multi_req) |req| {
                var cols: [8]usize = undefined;
                for (req.cols[0..req.n], 0..) |c, i| cols[i] = c;
                _ = tab.multiNdvOf(gpa, cols[0..req.n]);
                sets += 1;
                if (sets >= 4096) break;
            }
            if (std.c.getenv("ZHDB_EXPLAIN") != null and (tab.pair_req.len + tab.triple_req.len + tab.multi_req.len) > 0) {
                std.debug.print("[stats] {s}: ndv collected {d} pair(s) + {d} triple(s) + {d} set(s) (requested {d}/{d}/{d})\n", .{
                    name, pairs, triples, sets, tab.pair_req.len, tab.triple_req.len, tab.multi_req.len,
                });
            }
        }
        // Demand-driven OR pairs: count A, B and A∧B on the statistics sample so
        // inclusion-exclusion uses measured joint mass (correlation-aware).
        {
            var pairs_done: usize = 0;
            for (t.or_req.items) |*r| {
                if (r.done) continue;
                self.measureOrReq(t, r);
                pairs_done += 1;
            }
            if (std.c.getenv("ZHDB_EXPLAIN") != null and pairs_done > 0) {
                std.debug.print("[stats] {s}: or pairs measured={d} resident={d} bytes={d}\n", .{
                    name, pairs_done, t.or_req.items.len, t.or_bytes,
                });
            }
        }
        return .{ .affected = 0 };
    }

    /// Split an ON expression into equality conjuncts. `and_op` chains are
    /// flattened; non-equality conjuncts are kept as filters (returned in
    /// `others`), equalities in `eqs`.
    fn splitOnConjuncts(
        alloc: std.mem.Allocator,
        e: *sql.Expr,
        eqs: *std.ArrayList(*sql.Expr),
        others: *std.ArrayList(*sql.Expr),
    ) EngineError!void {
        if (e.* == .binary and e.binary.op == .and_op) {
            try splitOnConjuncts(alloc, e.binary.lhs, eqs, others);
            try splitOnConjuncts(alloc, e.binary.rhs, eqs, others);
            return;
        }
        if (e.* == .binary and e.binary.op == .eq) {
            try eqs.append(alloc, e);
        } else {
            try others.append(alloc, e);
        }
    }

    /// Resolve a multi-key join's extra equalities to column pairs on the two
    /// given tables. Returns the number of resolved pairs (0 when none).
    fn resolveExtraPairs(
        self: *Engine,
        j: sql.Join,
        lt: *Table,
        lname: []const u8,
        lalias: ?[]const u8,
        rt: *Table,
        rname: []const u8,
        ralias: ?[]const u8,
        out: *[8][2]usize,
    ) usize {
        _ = self;
        var n: usize = 0;
        for (j.extra_eqs) |e| {
            if (e.* != .binary or e.binary.op != .eq) continue;
            const a1 = colOfSide(lt, lname, lalias, e.binary.lhs);
            const b1 = colOfSide(rt, rname, ralias, e.binary.lhs);
            const a2 = colOfSide(lt, lname, lalias, e.binary.rhs);
            const b2 = colOfSide(rt, rname, ralias, e.binary.rhs);
            var li: ?usize = null;
            var ri: ?usize = null;
            if (a1 != null and b2 != null) {
                li = a1;
                ri = b2;
            } else if (a2 != null and b1 != null) {
                li = a2;
                ri = b1;
            }
            if (li == null or ri == null) return 0;
            out[n] = .{ li.?, ri.? };
            n += 1;
        }
        return n;
    }

    fn pairKey(buf: []u8, vals: []const i64) []const u8 {
        var pos: usize = 0;
        for (vals) |v| {
            if (pos + 9 > buf.len) return buf[0..pos];
            std.mem.writeInt(i64, buf[pos..][0..8], v, .little);
            pos += 8;
            buf[pos] = 0x1f;
            pos += 1;
        }
        return buf[0..pos];
    }

    /// Exact ratio of (all equality keys) to (primary key only) matched pairs
    /// between two tables, from their columnar rows. Returns null when the keys
    /// are not fully resolvable/numeric or the tables exceed the work budget.
    /// Append one encoded column value to a tuple key. Numeric values use their
    /// 8-byte key; strings use a 4-byte length plus the bytes (lexicographic
    /// order is preserved by the length prefix for equal lengths, and equality
    /// is exact regardless).
    fn appendColKey(
        self: *Engine,
        buf: *std.ArrayList(u8),
        ct: *columnar.Table,
        col: usize,
        row: usize,
        alloc: std.mem.Allocator,
    ) bool {
        _ = self;
        switch (ct.data[col]) {
            .ints, .ints8, .ints16, .ints32 => {
                var b: [8]u8 = undefined;
                std.mem.writeInt(i64, &b, ct.data[col].intAt(row), .little);
                buf.appendSlice(alloc, &b) catch return false;
            },
            .floats => |v| {
                var b: [8]u8 = undefined;
                std.mem.writeInt(i64, &b, f64Key(v[row]), .little);
                buf.appendSlice(alloc, &b) catch return false;
            },
            .strs => |sd| {
                const t = sd.at(row);
                var lb: [4]u8 = undefined;
                std.mem.writeInt(u32, &lb, @intCast(t.len), .little);
                buf.appendSlice(alloc, &lb) catch return false;
                buf.appendSlice(alloc, t) catch return false;
            },
        }
        return true;
    }

    /// Exact ratio of (all equality keys) to (primary key only) matched pairs
    /// between two tables, from their columnar rows. Works for numeric and
    /// string keys. Returns null when the tables exceed the work budget.
    fn exactExtraRatio(
        self: *Engine,
        lt: *Table,
        rt: *Table,
        keys: []const [2]usize,
    ) ?f64 {
        if (keys.len == 0 or keys.len > 8) return null;
        const lct = self.findColumnar(lt.name) orelse return null;
        const rct = self.findColumnar(rt.name) orelse return null;
        const ln = lct.nrows;
        const rn = rct.nrows;
        if (ln > 2_000_000 or rn > 2_000_000) return null;
        for (keys) |k| {
            if (k[0] >= lct.data.len or k[1] >= rct.data.len) return null;
        }
        var all_map = std.StringHashMap(u32).init(self.gpa);
        defer {
            var it = all_map.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            all_map.deinit();
        }
        var prim_map = std.StringHashMap(u32).init(self.gpa);
        defer {
            var it = prim_map.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            prim_map.deinit();
        }
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.gpa);
        var ri: usize = 0;
        while (ri < rn) : (ri += 1) {
            if (rct.isDeleted(ri)) continue;
            var ok = true;
            for (keys) |k| {
                if (rct.isNull(k[1], ri)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            buf.clearRetainingCapacity();
            for (keys) |k| {
                if (!self.appendColKey(&buf, rct, k[1], ri, self.gpa)) return null;
            }
            const gop = all_map.getOrPut(buf.items) catch return null;
            if (!gop.found_existing) {
                gop.key_ptr.* = self.gpa.dupe(u8, buf.items) catch {
                    _ = all_map.remove(buf.items);
                    return null;
                };
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
            buf.clearRetainingCapacity();
            if (!self.appendColKey(&buf, rct, keys[0][1], ri, self.gpa)) return null;
            const gp2 = prim_map.getOrPut(buf.items) catch return null;
            if (!gp2.found_existing) {
                gp2.key_ptr.* = self.gpa.dupe(u8, buf.items) catch {
                    _ = prim_map.remove(buf.items);
                    return null;
                };
                gp2.value_ptr.* = 0;
            }
            gp2.value_ptr.* += 1;
            if (all_map.count() > 1_000_000) return null;
        }
        var total: f64 = 0;
        var prim: f64 = 0;
        ri = 0;
        while (ri < ln) : (ri += 1) {
            if (lct.isDeleted(ri)) continue;
            var ok = true;
            for (keys) |k| {
                if (lct.isNull(k[0], ri)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            buf.clearRetainingCapacity();
            for (keys) |k| {
                if (!self.appendColKey(&buf, lct, k[0], ri, self.gpa)) return null;
            }
            if (all_map.get(buf.items)) |c| total += @floatFromInt(c);
            buf.clearRetainingCapacity();
            if (!self.appendColKey(&buf, lct, keys[0][0], ri, self.gpa)) return null;
            if (prim_map.get(buf.items)) |c| prim += @floatFromInt(c);
        }
        if (prim <= 0) return null;
        return total / prim;
    }

    /// Classified non-primary ON conjuncts, applied per candidate row pair.
    pub const ExtraPlan = struct {
        xl: []const usize = &.{},
        xr: []const usize = &.{},
        nx: usize = 0,
        lf: []const *sql.Expr = &.{},
        nlf: usize = 0,
        rf: []const *sql.Expr = &.{},
        nrf: usize = 0,
        /// Conjuncts bound to a combined (left ++ right) row.
        pc: []const *sql.Expr = &.{},
        npc: usize = 0,
        nl: usize = 0,
    };

    fn extraRowOk(
        self: *Engine,
        alloc: std.mem.Allocator,
        p: ExtraPlan,
        lrow: []Value,
        rrow: []Value,
        combined: []Value,
    ) EngineError!bool {
        var qi: usize = 0;
        while (qi < p.nlf) : (qi += 1) {
            if (!evalPredRow(p.lf[qi], lrow)) return false;
        }
        qi = 0;
        while (qi < p.nrf) : (qi += 1) {
            if (!evalPredRow(p.rf[qi], rrow)) return false;
        }
        qi = 0;
        while (qi < p.nx) : (qi += 1) {
            const a = lrow[p.xl[qi]];
            const b2 = rrow[p.xr[qi]];
            if (a == .null or b2 == .null) return false;
            if (!Value.eql(a, b2)) return false;
        }
        if (p.npc > 0) {
            if (p.nl + rrow.len > combined.len or lrow.len > p.nl) return error.UnsupportedJoin;
            @memcpy(combined[0..lrow.len], lrow);
            @memcpy(combined[p.nl .. p.nl + rrow.len], rrow);
            qi = 0;
            while (qi < p.npc) : (qi += 1) {
                const v = try self.eval(alloc, p.pc[qi], combined, &[_]Column{}, null);
                if (!truthy(v)) return false;
            }
        }
        return true;
    }

    /// First column reference of `e` on `side` (used to estimate expression
    /// pairs like `p.b + 1 = q.b`).
    fn firstColIn(self: *Engine, side: ExprSide, e: *sql.Expr) ?usize {
        switch (e.*) {
            .column, .column_idx => return side.colAt(e),
            .binary => |b| return self.firstColIn(side, b.lhs) orelse self.firstColIn(side, b.rhs),
            .negate => |x| return self.firstColIn(side, x),
            .not => |x| return self.firstColIn(side, x),
            .cast => |c| return self.firstColIn(side, c.operand),
            .is_null => |x| return self.firstColIn(side, x.operand),
            .like => |x| return self.firstColIn(side, x.operand),
            .between => |x| return self.firstColIn(side, x.operand) orelse self.firstColIn(side, x.low),
            .in_list => |x| return self.firstColIn(side, x.operand),
            .call => |c| {
                for (c.args) |a| {
                    if (self.firstColIn(side, a)) |v| return v;
                }
                return null;
            },
            .case_expr => |c| {
                for (c.whens) |w| {
                    if (self.firstColIn(side, w.cond)) |v| return v;
                    if (self.firstColIn(side, w.then)) |v| return v;
                }
                if (c.else_expr) |x| return self.firstColIn(side, x);
                return null;
            },
            else => return null,
        }
    }

    /// Exact fraction of rows of `t` where columns `ca` and `cb` are equal
    /// (numeric or string), scanned from the columnar image (≤2M rows).
    fn colPairSameSel(self: *Engine, t: *Table, ca: usize, cb: usize) ?f64 {
        const ct = self.findColumnar(t.name) orelse return null;
        const n = ct.nrows;
        if (n == 0 or n > 2_000_000) return null;
        if (ca >= ct.data.len or cb >= ct.data.len) return null;
        var matched: usize = 0;
        var total: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (ct.isDeleted(i) or ct.isNull(ca, i) or ct.isNull(cb, i)) continue;
            const eq = switch (ct.data[ca]) {
                .ints, .ints8, .ints16, .ints32 => switch (ct.data[cb]) {
                    .ints, .ints8, .ints16, .ints32 => ct.data[ca].intAt(i) == ct.data[cb].intAt(i),
                    .floats => |w| @as(f64, @floatFromInt(ct.data[ca].intAt(i))) == w[i],
                    else => false,
                },
                .floats => |v| switch (ct.data[cb]) {
                    .floats => |w| v[i] == w[i],
                    .ints => |w| v[i] == @as(f64, @floatFromInt(w[i])),
                    else => false,
                },
                .strs => |sd| switch (ct.data[cb]) {
                    .strs => |sd2| std.mem.eql(u8, sd.at(i), sd2.at(i)),
                    else => false,
                },
            };
            total += 1;
            if (eq) matched += 1;
        }
        if (total == 0) return null;
        return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(total));
    }

    /// Exact fraction of rows where column `ci` equals a literal (columnar scan,
    /// ≤2M rows). Returns null for non-equality or unsupported literal/column.
    fn colEqLitSel(self: *Engine, t: *Table, ci: usize, lit: *sql.Expr) ?f64 {
        const ct = self.findColumnar(t.name) orelse return null;
        const n = ct.nrows;
        if (n == 0 or n > 2_000_000) return null;
        if (ci >= ct.data.len) return null;
        var matched: usize = 0;
        var total: usize = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (ct.isDeleted(i) or ct.isNull(ci, i)) continue;
            const eq = switch (lit.*) {
                .int => |x| switch (ct.data[ci]) {
                    .ints => |v| v[i] == x,
                    .floats => |v| v[i] == @as(f64, @floatFromInt(x)),
                    else => false,
                },
                .float => |x| switch (ct.data[ci]) {
                    .ints => |v| @as(f64, @floatFromInt(v[i])) == x,
                    .floats => |v| v[i] == x,
                    else => false,
                },
                .string => |x| switch (ct.data[ci]) {
                    .strs => |sd| std.mem.eql(u8, sd.at(i), x),
                    else => false,
                },
                else => return null,
            };
            total += 1;
            if (eq) matched += 1;
        }
        if (total == 0) return null;
        return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(total));
    }

    /// Selectivity of one single-side ON conjunct (all columns belong to `t`).
    /// Column = column is measured exactly from the columnar image (falling back
    /// to 1/max(ndv)); column = literal via the columnar image, then the normal
    /// predicate estimator.
    fn extraConjunctSel(
        self: *Engine,
        t: *Table,
        name: []const u8,
        alias: ?[]const u8,
        quals: ?[]const ChainQual,
        e: *sql.Expr,
    ) f64 {
        if (e.* == .binary and e.binary.op == .eq) {
            const side = ExprSide{ .t = t, .name = name, .alias = alias, .quals = quals };
            const a = side.colAt(e.binary.lhs);
            const b = side.colAt(e.binary.rhs);
            if (a != null and b != null) {
                if (self.colPairSameSel(t, a.?, b.?)) |sel| return std.math.clamp(sel, 1e-9, 1.0);
                _ = self.ensureColStatQuick(t, a.?);
                _ = self.ensureColStatQuick(t, b.?);
                var na: usize = 0;
                var nb: usize = 0;
                if (a.? < t.stats.len) na = t.stats[a.?].ndv;
                if (b.? < t.stats.len) nb = t.stats[b.?].ndv;
                const m = @max(na, nb);
                if (m > 0) return 1.0 / @as(f64, @floatFromInt(m));
            }
            if (a != null and isLiteral(e.binary.rhs)) {
                if (self.colEqLitSel(t, a.?, e.binary.rhs)) |sel| {
                    return std.math.clamp(sel, 1e-9, 1.0);
                }
            } else if (b != null and isLiteral(e.binary.lhs)) {
                if (self.colEqLitSel(t, b.?, e.binary.lhs)) |sel| {
                    return std.math.clamp(sel, 1e-9, 1.0);
                }
            }
        }
        return self.whereSelectivityAlias(name, e, alias);
    }

    /// Default selectivity for a cross-side non-equality conjunct (standard
    /// planner defaults; there is no exact enumeration for arbitrary
    /// comparisons).
    fn compareDefaultSel(self: *Engine, e: *sql.Expr) f64 {
        _ = self;
        return switch (e.*) {
            .binary => |b| switch (b.op) {
                .neq => 0.9,
                .lt, .le, .gt, .ge => 1.0 / 3.0,
                else => 0.5,
            },
            .like => 0.1,
            .between => 1.0 / 3.0,
            .is_null => 0.05,
            .in_list => 0.1,
            else => 0.5,
        };
    }

    /// Selectivity factor of a join's non-primary ON conjuncts: column-pair
    /// equalities (exact tuple ratio when available, else 1/max(ndv)) times the
    /// per-side filter selectivities of conjuncts that touch only one input.
    fn extraEstimate(
        self: *Engine,
        alloc: std.mem.Allocator,
        j: sql.Join,
        lt: *Table,
        lname: []const u8,
        lalias: ?[]const u8,
        lquals: ?[]const ChainQual,
        rt: *Table,
        rname: []const u8,
        ralias: ?[]const u8,
    ) f64 {
        if (j.extra_eqs.len == 0) return 1.0;
        const lside = ExprSide{ .t = lt, .name = lname, .alias = lalias, .quals = lquals };
        const rside = ExprSide{ .t = rt, .name = rname, .alias = ralias };
        var sel: f64 = 1.0;
        var pair_keys: [8][2]usize = undefined;
        var np: usize = 0;
        for (j.extra_eqs) |e| {
            if (e.* != .binary or e.binary.op != .eq) {
                if (rebindExprSide(alloc, e, lside) != null) {
                    sel *= self.extraConjunctSel(lt, lname, lalias, lquals, e);
                    continue;
                }
                if (rebindExprSide(alloc, e, rside) != null) {
                    sel *= self.extraConjunctSel(rt, rname, ralias, null, e);
                    continue;
                }
                if (rebindCombined(alloc, e, lside, rside, lt.cols.len) != null) {
                    sel *= self.compareDefaultSel(e);
                    continue;
                }
                // Execution rejects this conjunct; keep the estimate tiny.
                sel *= 1e-9;
                continue;
            }
            if (rebindExprSide(alloc, e, lside) != null) {
                sel *= self.extraConjunctSel(lt, lname, lalias, lquals, e);
                continue;
            }
            if (rebindExprSide(alloc, e, rside) != null) {
                sel *= self.extraConjunctSel(rt, rname, ralias, null, e);
                continue;
            }
            const ll = lside.colAt(e.binary.lhs);
            const rr = rside.colAt(e.binary.rhs);
            const rl = lside.colAt(e.binary.rhs);
            const lr = rside.colAt(e.binary.lhs);
            var pair: ?[2]usize = null;
            if (ll != null and rr != null) {
                pair = .{ ll.?, rr.? };
            } else if (rl != null and lr != null) {
                pair = .{ rl.?, lr.? };
            }
            if (pair) |pk| {
                if (np >= pair_keys.len) return 0.0;
                pair_keys[np] = pk;
                np += 1;
                continue;
            }
            // Expression pair (`p.b + 1 = q.b`): estimate from the first column
            // of each side.
            var el_expr: ?*sql.Expr = null;
            var er_expr: ?*sql.Expr = null;
            if (rebindExprSide(alloc, e.binary.lhs, lside) != null) {
                if (rebindExprSide(alloc, e.binary.rhs, rside) != null) {
                    el_expr = e.binary.lhs;
                    er_expr = e.binary.rhs;
                }
            } else if (rebindExprSide(alloc, e.binary.rhs, lside) != null) {
                if (rebindExprSide(alloc, e.binary.lhs, rside) != null) {
                    el_expr = e.binary.rhs;
                    er_expr = e.binary.lhs;
                }
            }
            if (el_expr != null and er_expr != null) {
                const cl = self.firstColIn(lside, el_expr.?);
                const cr = self.firstColIn(rside, er_expr.?);
                if (cl != null and cr != null) {
                    _ = self.ensureColStatQuick(lt, cl.?);
                    _ = self.ensureColStatQuick(rt, cr.?);
                    var na: usize = 0;
                    var nb: usize = 0;
                    if (cl.? < lt.stats.len) na = lt.stats[cl.?].ndv;
                    if (cr.? < rt.stats.len) nb = rt.stats[cr.?].ndv;
                    const m = @max(na, nb);
                    sel *= if (m > 0) 1.0 / @as(f64, @floatFromInt(m)) else 0.1;
                } else {
                    sel *= 0.1;
                }
            } else {
                // Execution rejects this conjunct; keep the estimate tiny.
                sel *= 1e-9;
            }
        }
        if (np > 0) {
            var all: [9][2]usize = undefined;
            var have_primary = false;
            if (j.on.* == .binary) {
                const pl = lside.colAt(j.on.binary.lhs);
                const pr = rside.colAt(j.on.binary.rhs);
                const ql = lside.colAt(j.on.binary.rhs);
                const qr = rside.colAt(j.on.binary.lhs);
                if (pl != null and pr != null) {
                    all[0] = .{ pl.?, pr.? };
                    have_primary = true;
                } else if (ql != null and qr != null) {
                    all[0] = .{ ql.?, qr.? };
                    have_primary = true;
                }
            }
            if (have_primary) {
                for (pair_keys[0..np], 0..) |pk, i| all[i + 1] = pk;
                if (self.exactExtraRatio(lt, rt, all[0 .. np + 1])) |ratio| {
                    sel *= ratio;
                } else {
                    for (pair_keys[0..np]) |pk| {
                        _ = self.ensureColStatQuick(lt, pk[0]);
                        _ = self.ensureColStatQuick(rt, pk[1]);
                        var na: usize = 0;
                        var nb: usize = 0;
                        if (pk[0] < lt.stats.len) na = lt.stats[pk[0]].ndv;
                        if (pk[1] < rt.stats.len) nb = rt.stats[pk[1]].ndv;
                        const m = @max(na, nb);
                        if (m > 0) sel *= 1.0 / @as(f64, @floatFromInt(m));
                    }
                }
            }
        }
        return sel;
    }

    /// Selectivity of the extra equality conjuncts of a multi-key join
    /// (`1/max(ndv_l, ndv_r)` with key-domain overlap), resolved across the
    /// tables/aliases participating in the chain.
    fn extraEqSelectivity(self: *Engine, j: sql.Join, names: []const []const u8, aliases: []const ?[]const u8) f64 {
        var sel: f64 = 1.0;
        for (j.extra_eqs) |e| {
            const b = e.binary;
            var lndv: usize = 0;
            var rndv: usize = 0;
            var lspan: ?[2]i64 = null;
            var rspan: ?[2]i64 = null;
            for (names, 0..) |nm, i| {
                const al = if (i < aliases.len) aliases[i] else null;
                const t = self.find(nm) orelse continue;
                if (self.tableColOfAlias(nm, b.lhs, al)) |c| {
                    _ = self.ensureColStatQuick(t, c);
                    if (c < t.stats.len) {
                        lndv = t.stats[c].ndv;
                        if (!(t.cols[c].ty == .text or t.cols[c].ty == .date or t.cols[c].ty == .timestamp)) {
                            lspan = .{ t.stats[c].min, t.stats[c].max };
                        }
                    }
                }
                if (self.tableColOfAlias(nm, b.rhs, al)) |c| {
                    _ = self.ensureColStatQuick(t, c);
                    if (c < t.stats.len) {
                        rndv = t.stats[c].ndv;
                        if (!(t.cols[c].ty == .text or t.cols[c].ty == .date or t.cols[c].ty == .timestamp)) {
                            rspan = .{ t.stats[c].min, t.stats[c].max };
                        }
                    }
                }
            }
            if (lndv == 0 or rndv == 0) continue;
            var s2 = 1.0 / @as(f64, @floatFromInt(@max(lndv, rndv)));
            if (lspan != null and rspan != null) {
                const lo = @max(lspan.?[0], rspan.?[0]);
                const hi = @min(lspan.?[1], rspan.?[1]);
                if (hi < lo) {
                    s2 = 1e-9;
                } else {
                    const lr: f64 = @floatFromInt(@max(lspan.?[1] - lspan.?[0] + 1, 1));
                    const rr: f64 = @floatFromInt(@max(rspan.?[1] - rspan.?[0] + 1, 1));
                    s2 = @min(@as(f64, @floatFromInt(hi - lo + 1)) / (lr * rr), 1.0);
                }
            }
            sel *= s2;
        }
        return sel;
    }

    /// Rewrite multi-key ONs in `sel` (and its extra joins): the first equality
    /// becomes the hash-join key; the rest become post-join WHERE filters and
    /// are recorded on the join for estimation.
    fn flattenAnd(alloc: std.mem.Allocator, e: *sql.Expr, out: *std.ArrayList(*sql.Expr)) EngineError!void {
        if (e.* == .binary and e.binary.op == .and_op) {
            try flattenAnd(alloc, e.binary.lhs, out);
            try flattenAnd(alloc, e.binary.rhs, out);
            return;
        }
        try out.append(alloc, e);
    }

    /// If `w` is an equality joining a column of the first table with a column
    /// of `j.table` (by qualifier), fold it into `j`'s extra equalities.
    fn foldWhereEq(
        self: *Engine,
        w: *sql.Expr,
        lname: []const u8,
        lalias: ?[]const u8,
        j: *sql.Join,
        extra: *std.ArrayList(*sql.Expr),
    ) bool {
        if (w.* != .binary or w.binary.op != .eq) return false;
        const lt = self.find(lname) orelse return false;
        const rt = self.find(j.table) orelse return false;
        const a1 = colOfSide(lt, lname, lalias, w.binary.lhs);
        const b1 = colOfSide(rt, j.table, j.alias, w.binary.lhs);
        const a2 = colOfSide(lt, lname, lalias, w.binary.rhs);
        const b2 = colOfSide(rt, j.table, j.alias, w.binary.rhs);
        if ((a1 != null and b2 != null) or (a2 != null and b1 != null)) {
            extra.append(self.gpa, w) catch return false;
            return true;
        }
        return false;
    }

    fn normalizeMultiKeyJoins(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select) EngineError!*sql.Select {
        var changed = false;
        var extra_where = std.ArrayList(*sql.Expr).empty;
        defer extra_where.deinit(alloc);
        const lname = switch (sel.from.?) {
            .table => |nm| nm,
            else => return sel,
        };
        const new_more = try alloc.alloc(sql.Join, sel.more_joins.len);
        // Per-join extra equality lists (ON extras + folded WHERE equalities).
        var more_extra = try alloc.alloc(std.ArrayList(*sql.Expr), sel.more_joins.len);
        for (more_extra) |*l| l.* = .empty;
        defer for (more_extra) |*l| l.deinit(alloc);
        var first_extra = std.ArrayList(*sql.Expr).empty;
        defer first_extra.deinit(alloc);
        for (sel.more_joins, 0..) |jj, i| {
            var j = jj;
            if (j.on.* == .binary and j.on.binary.op == .and_op) {
                var eqs = std.ArrayList(*sql.Expr).empty;
                defer eqs.deinit(alloc);
                var others = std.ArrayList(*sql.Expr).empty;
                defer others.deinit(alloc);
                try splitOnConjuncts(alloc, j.on, &eqs, &others);
                if (eqs.items.len >= 1) {
                    j.on = eqs.items[0];
                    for (eqs.items[1..]) |e| try more_extra[i].append(alloc, e);
                    // Non-equality conjuncts stay on the join as per-pair
                    // residuals (they cannot rely on temp-table qualifiers).
                    for (others.items) |o| try more_extra[i].append(alloc, o);
                    changed = true;
                }
            }
            new_more[i] = j;
        }
        var first = sel.join.?;
        if (first.on.* == .binary and first.on.binary.op == .and_op) {
            var eqs = std.ArrayList(*sql.Expr).empty;
            defer eqs.deinit(alloc);
            var others = std.ArrayList(*sql.Expr).empty;
            defer others.deinit(alloc);
            try splitOnConjuncts(alloc, first.on, &eqs, &others);
            if (eqs.items.len >= 1) {
                first.on = eqs.items[0];
                for (eqs.items[1..]) |e| try first_extra.append(alloc, e);
                for (others.items) |o| try first_extra.append(alloc, o);
                changed = true;
            }
        }
        // Standalone cross-table WHERE equalities between a join's two tables
        // are folded into that join's extras (they then act as pair filters and
        // participate in estimation).
        if (sel.where) |w| {
            var parts = std.ArrayList(*sql.Expr).empty;
            defer parts.deinit(alloc);
            try flattenAnd(alloc, w, &parts);
            var kept = std.ArrayList(*sql.Expr).empty;
            defer kept.deinit(alloc);
            for (parts.items) |part| {
                var folded = false;
                if (self.foldWhereEq(part, lname, sel.alias, &first, &first_extra)) {
                    folded = true;
                } else {
                    var mi: usize = 0;
                    while (mi < new_more.len) : (mi += 1) {
                        if (self.foldWhereEq(part, lname, sel.alias, &new_more[mi], &more_extra[mi])) {
                            folded = true;
                            break;
                        }
                    }
                }
                if (folded) {
                    changed = true;
                } else {
                    try kept.append(alloc, part);
                }
            }
            if (changed) {
                extra_where.deinit(alloc);
                extra_where = std.ArrayList(*sql.Expr).empty;
                for (kept.items) |k| try extra_where.append(alloc, k);
            }
        }
        if (!changed) return sel;
        for (new_more, 0..) |*j, i| {
            if (more_extra[i].items.len > 0) {
                j.extra_eqs = try alloc.dupe(*sql.Expr, more_extra[i].items);
            }
        }
        if (first_extra.items.len > 0) {
            first.extra_eqs = try alloc.dupe(*sql.Expr, first_extra.items);
        }
        const n = try alloc.create(sql.Select);
        n.* = sel.*;
        n.more_joins = new_more;
        n.join = first;
        var where: ?*sql.Expr = null;
        for (extra_where.items) |w| where = try andAll(alloc, &.{ where orelse w, w });
        n.where = where;
        return n;
    }

    /// INNER hash join: build a hash table on the right input's key, probe with
    /// the left, materialise the joined rows into a temporary table and run the
    /// original SELECT against it (so aggregates/JIT/ORDER BY are reused).
    fn execJoin(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select, j: sql.Join) EngineError!Result {
        if (j.cross) return self.execCrossJoin(alloc, sel, j);
        const lname = switch (sel.from.?) {
            .table => |n| n,
            else => return error.UnsupportedJoin,
        };
        var names = [_][]const u8{ lname, j.table };
        const filters = try self.buildJoinFilters(alloc, sel, &names);
        if (j.left or j.right) {
            return self.execJoinImpl(alloc, sel, j, true, null, null, null);
        }
        return self.execJoinImpl(alloc, sel, j, true, filters[0], filters[1], null);
    }

    fn execCrossJoin(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select, j: sql.Join) EngineError!Result {
        const lname = switch (sel.from.?) { .table => |n| n, else => return error.UnsupportedJoin };
        const lt = self.find(lname) orelse return error.TableNotFound;
        const rt = self.find(j.table) orelse return error.TableNotFound;
        self.ensureRowsMaterialized(lname);
        self.ensureRowsMaterialized(j.table);
        var out_rows = std.ArrayList([]Value).empty;
        for (lt.rows.items, 0..) |lrow, lri| {
            if (isRowDeleted(lt, lri) or !self.visibleRow(lt, lri)) continue;
            for (rt.rows.items, 0..) |rrow, rri| {
                if (isRowDeleted(rt, rri) or !self.visibleRow(rt, rri)) continue;
                const row = try self.gpa.alloc(Value, lt.cols.len + rt.cols.len);
                @memcpy(row[0..lt.cols.len], lrow);
                @memcpy(row[lt.cols.len..], rrow);
                try out_rows.append(self.gpa, row);
            }
        }
        const name = try std.fmt.allocPrint(self.gpa, "__join_{d}", .{tls_join_seq});
        tls_join_seq += 1;
        const defs = try self.gpa.alloc(sql.ColumnDef, lt.cols.len + rt.cols.len);
        for (0..lt.cols.len) |i| defs[i] = .{ .name = lt.cols[i].name, .type_name = typeName(lt.cols[i].ty) };
        for (0..rt.cols.len) |i| defs[lt.cols.len + i] = .{ .name = rt.cols[i].name, .type_name = typeName(rt.cols[i].ty) };
        const tmp = try Table.create(self.gpa, name, defs);
        for (0..lt.cols.len) |i| tmp.cols[i].source = sel.alias orelse lname;
        for (0..rt.cols.len) |i| tmp.cols[lt.cols.len + i].source = j.alias orelse j.table;
        tmp.rows = out_rows;
        try self.tempTables().put(name, tmp);
        self.buildColumnar(name) catch {};
        defer self.dropJoinTemp(name);
        var sel2 = sel.*;
        sel2.from = .{ .table = name };
        sel2.join = null;
        sel2.more_joins = &.{};
        return self.execSelect(alloc, &sel2, true);
    }

    fn execJoinImpl(
        self: *Engine,
        alloc: std.mem.Allocator,
        sel: *sql.Select,
        j: sql.Join,
        finalize: bool,
        lfilt: ?*sql.Expr,
        rfilt: ?*sql.Expr,
        lquals: ?[]const ChainQual,
    ) EngineError!Result {
        if (std.c.getenv("ZHDB_DBG_JOIN2") != null) {
            std.debug.print("[join] enter table={s} on={any} left={}\n", .{ j.table, j.on.*, j.left });
        }
        const lname = switch (sel.from.?) {
            .table => |n| n,
            else => return error.UnsupportedJoin,
        };
        const lt = self.find(lname) orelse return error.TableNotFound;
        const rt = self.find(j.table) orelse return error.TableNotFound;
        // Snapshot-backed tables only materialise their row store lazily.
        self.ensureRowsMaterialized(lname);
        self.ensureRowsMaterialized(j.table);
        self.noteScan(lname);
        self.noteScan(j.table);
        if (j.on.* != .binary) return error.UnsupportedJoin;
        if (j.on.binary.op != .eq) return self.execRangeJoin(alloc, sel, j);
        // Outer joins must go through the nullable-producing path; the streaming
        // aggregate over joins only handles inner joins.
        // The streaming aggregate-over-join only applies to a single join; in a
        // multi-join chain every step must materialise its result.
        if (finalize and !j.left and !j.right) {
            if (try self.joinAggregate(alloc, sel, j, lname, lt, rt)) |res| return res;
        }

        const lhs = j.on.binary.lhs;
        const rhs = j.on.binary.rhs;
        const lname_s = colName(lhs) orelse return error.UnknownColumn;
        const rname_s = colName(rhs) orelse return error.UnknownColumn;
        // Qualifier-aware, bounds-checked resolution: `d.j` only matches table
        // `d`, and an explicit index only matches a table with that many columns.
        const lhs_l = colOfSide(lt, lname, sel.alias, lhs);
        const lhs_r = colOfSide(rt, j.table, j.alias, lhs);
        const rhs_l = colOfSide(lt, lname, sel.alias, rhs);
        const rhs_r = colOfSide(rt, j.table, j.alias, rhs);
        var lcol: usize = undefined;
        var rcol: usize = undefined;
        if (lhs_l != null and rhs_r != null and !(rhs_l != null and lhs_r != null)) {
            lcol = lhs_l.?;
            rcol = rhs_r.?;
        } else if (rhs_l != null and lhs_r != null and !(lhs_l != null and rhs_r != null)) {
            // `ON right.x = left.y` (e.g. pg_namespace.oid = pg_class.relnamespace)
            lcol = rhs_l.?;
            rcol = lhs_r.?;
        } else if (lhs_l != null and rhs_r != null) {
            lcol = lhs_l.?;
            rcol = rhs_r.?;
        } else if (rhs_l != null and lhs_r != null) {
            lcol = rhs_l.?;
            rcol = lhs_r.?;
        } else {
            _ = lname_s;
            _ = rname_s;
            return error.UnknownColumn;
        }

        // Record the (join key, local filter) composite for ANALYZE and, once
        // materialised, use it for the key NDV.
        const join_ndv = self.joinNdvAlias(j, lname, sel.where, null, sel.alias, j.alias);
        // Evaluate both local selectivities unconditionally: this is also where
        // demand-driven statistics requests (OR pairs) are recorded, so they must
        // not depend on EXPLAIN being enabled.
        const self_join = std.ascii.eqlIgnoreCase(lname, j.table);
        var cross_union: ?f64 = null;
        var cross_pairs: ?f64 = null;
        if (self_join and sel.where != null and
            crossAliasOr(sel.where.?, sel.alias, j.alias, lname))
        {
            // Duplicate-key-aware: Σ_v U(v)·f(v) from the key dictionary.
            var lk: ?usize = null;
            if (j.on.* == .binary) {
                lk = keyCol(lt, j.on.binary.lhs) orelse keyCol(lt, j.on.binary.rhs);
            }
            if (lk) |kc| cross_pairs = self.selfJoinUnionPairs(lt, sel.where.?, kc);
            if (cross_pairs == null) cross_union = self.orUnionOnTable(lt, sel.where.?);
        }
        const lsel = if (cross_union != null or cross_pairs != null) 1.0 else self.whereSelectivityAlias(lname, sel.where, sel.alias);
        const rsel = if (cross_union != null or cross_pairs != null) 1.0 else self.whereSelectivityAlias(j.table, sel.where, j.alias);
        if (std.c.getenv("ZHDB_EXPLAIN") != null and sel.where != null) {
            const lrows: f64 = @floatFromInt(lt.rows.items.len);
            const rrows: f64 = @floatFromInt(rt.rows.items.len);
            const jsel: f64 = if (join_ndv > 0) 1.0 / join_ndv else 0.1;
            const extra_sel = self.extraEstimate(alloc, j, lt, lname, sel.alias, null, rt, j.table, j.alias);
            const est_rows = if (cross_pairs) |cp|
                cp
            else
                lrows * lsel * rrows * rsel * jsel * (cross_union orelse 1.0) * extra_sel;
            std.debug.print("[plan] join est_rows={d:.0} ndv={d:.1} cross_union={?d:.4} cross_pairs={?d:.0} (filters applied in the final SELECT)\n", .{
                est_rows, join_ndv, cross_union, cross_pairs,
            });
        }
        // Cost-based build/probe choice: build on the side with fewer distinct
        // keys (falls back to row count before ANALYZE has run).
        const ndv_l: usize = if (lt.stats.len > lcol) lt.stats[lcol].ndv else 0;
        const ndv_r: usize = if (rt.stats.len > rcol) rt.stats[rcol].ndv else 0;
        const cost_l: usize = if (ndv_l > 0) ndv_l else lt.rows.items.len;
        const cost_r: usize = if (ndv_r > 0) ndv_r else rt.rows.items.len;
        // Outer joins must probe with the preserved side: LEFT keeps left rows,
        // RIGHT keeps right rows (so it builds on the left).
        const build_left = if (j.left) false else if (j.right) true else cost_l < cost_r;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] join build={s} rows_l={d} rows_r={d} ndv_l={d} ndv_r={d} cost_l={d} cost_r={d}\n", .{
                if (build_left) "left" else "right",
                lt.rows.items.len,
                rt.rows.items.len,
                ndv_l,
                ndv_r,
                cost_l,
                cost_r,
            });
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] join key l={s}(ndv={d}) r={s}(ndv={d}) -> build={s}\n", .{
                lt.cols[lcol].name, ndv_l, rt.cols[rcol].name, ndv_r,
                if (build_left) "left" else "right",
            });
        }

        // Extra ON conjuncts of a multi-key join. Each is classified as
        //   * a column = column pair on the two inputs, or
        //   * a filter whose columns all belong to the left input, or
        //   * a filter whose columns all belong to the right input, or
        //   * an expression pair (left expression = right expression, e.g.
        //     `p.b + 1 = q.b`), evaluated per row pair.
        // Anything else is rejected loudly (never dropped).
        var xl: [8]usize = @splat(0);
        var xr: [8]usize = @splat(0);
        var nx: usize = 0;
        var lf: [8]*sql.Expr = undefined;
        var nlf: usize = 0;
        var rf: [8]*sql.Expr = undefined;
        var nrf: usize = 0;
        var pc: [8]*sql.Expr = undefined;
        var npc: usize = 0;
        const lside = ExprSide{ .t = lt, .name = lname, .alias = sel.alias, .quals = lquals };
        const rside = ExprSide{ .t = rt, .name = j.table, .alias = j.alias };
        for (j.extra_eqs) |e| {
            if (rebindExprSide(alloc, e, lside)) |bx| {
                if (nlf >= lf.len) return error.UnsupportedJoin;
                lf[nlf] = bx;
                nlf += 1;
                continue;
            }
            if (rebindExprSide(alloc, e, rside)) |bx| {
                if (nrf >= rf.len) return error.UnsupportedJoin;
                rf[nrf] = bx;
                nrf += 1;
                continue;
            }
            // Fast path: `left_col = right_col`.
            if (e.* == .binary and e.binary.op == .eq) {
                const el = lside.colAt(e.binary.lhs);
                const er = rside.colAt(e.binary.lhs);
                const fl = lside.colAt(e.binary.rhs);
                const fr = rside.colAt(e.binary.rhs);
                var li: ?usize = null;
                var ri: ?usize = null;
                if (el != null and fr != null) {
                    li = el;
                    ri = fr;
                } else if (fl != null and er != null) {
                    li = fl;
                    ri = er;
                }
                if (li != null and ri != null) {
                    if (nx >= xl.len) return error.UnsupportedJoin;
                    xl[nx] = li.?;
                    xr[nx] = ri.?;
                    nx += 1;
                    continue;
                }
            }
            // General cross-side conjunct: bind left columns and right columns
            // into one combined-row expression and evaluate it per row pair.
            // Covers `p.b + 1 = q.b`, `p.b > q.b`, cross-side LIKE/BETWEEN, ...
            if (rebindCombined(alloc, e, lside, rside, lt.cols.len)) |ce| {
                if (npc >= pc.len) return error.UnsupportedJoin;
                pc[npc] = ce;
                npc += 1;
                continue;
            }
            // A conjunct that cannot be evaluated on these two inputs would
            // otherwise be silently dropped (wrong rows).
            // A/B switch restores the old (unsound) skip for comparison.
            if (std.c.getenv("ZHDB_LENIENT_EXTRAS") != null) continue;
            return error.UnsupportedJoin;
        }
        const extra_plan = ExtraPlan{
            .xl = &xl,
            .xr = &xr,
            .nx = nx,
            .lf = &lf,
            .nlf = nlf,
            .rf = &rf,
            .nrf = nrf,
            .pc = &pc,
            .npc = npc,
            .nl = lt.cols.len,
        };
        var combined: []Value = &.{};
        if (npc > 0) {
            combined = try self.gpa.alloc(Value, lt.cols.len + rt.cols.len);
        }
        defer if (combined.len > 0) self.gpa.free(combined);

        const build_t = if (build_left) lt else rt;
        const build_col = if (build_left) lcol else rcol;
        const probe_t = if (build_left) rt else lt;
        const probe_col = if (build_left) rcol else lcol;
        const is_full = j.left and j.right;
        var build_matched: []bool = &.{};
        if (is_full) {
            build_matched = try self.gpa.alloc(bool, build_t.rows.items.len);
            @memset(build_matched, false);
        }
        defer if (is_full) self.gpa.free(build_matched);
        // Local predicates of each input (predicate pushdown): rows that cannot
        // take part in the join are dropped before hashing, so intermediates
        // match the planner's filter-aware estimates.
        const build_filter = if (build_left) lfilt else rfilt;
        const probe_filter = if (build_left) rfilt else lfilt;

        // Radix-partitioned hash join: both inputs are scattered into `parts`
        // buckets by hash(key), then each bucket is built/probed independently.
        // Bounding the hash table to one partition is what keeps memory flat on
        // large joins (the ClickHouse/Umbra radix approach).
        const parts: usize = 256;
        const part_mask: u64 = parts - 1;
        var bparts = try self.gpa.alloc(std.ArrayList(u32), parts);
        defer {
            for (bparts) |*l| l.deinit(self.gpa);
            self.gpa.free(bparts);
        }
        for (bparts) |*l| l.* = .empty;
        var pparts = try self.gpa.alloc(std.ArrayList(u32), parts);
        defer {
            for (pparts) |*l| l.deinit(self.gpa);
            self.gpa.free(pparts);
        }
        for (pparts) |*l| l.* = .empty;

        for (build_t.rows.items, 0..) |row, ri| {
            // Tombstoned (persisted or reclaimed) rows never participate, and
            // neither do uncommitted versions of other sessions.
            if (isRowDeleted(build_t, ri)) continue;
            if (!self.visibleRow(build_t, ri)) continue;
            if (tableIsNull(build_t, build_col, ri)) continue; // NULL keys never match
            if (build_filter) |f| {
                if (!truthy(try self.eval(alloc, f, row, build_t.cols, null))) continue;
            }
            try bparts[keyHash(row[build_col]) & part_mask].append(self.gpa, @intCast(ri));
        }
        // Probe rows whose key is NULL can never match; outer joins still keep
        // them, so they bypass partitioning.
        var null_probe = std.ArrayList(u32).empty;
        defer null_probe.deinit(self.gpa);
        for (probe_t.rows.items, 0..) |row, ri| {
            if (isRowDeleted(probe_t, ri)) continue;
            if (!self.visibleRow(probe_t, ri)) continue;
            if (probe_filter) |f| {
                if (!truthy(try self.eval(alloc, f, row, probe_t.cols, null))) continue;
            }
            if (tableIsNull(probe_t, probe_col, ri)) {
                try null_probe.append(self.gpa, @intCast(ri));
                continue;
            }
            try pparts[keyHash(row[probe_col]) & part_mask].append(self.gpa, @intCast(ri));
        }

        var out_rows = std.ArrayList([]Value).empty;
        if (j.left or j.right) {
            for (null_probe.items) |pi| {
                const prow = probe_t.rows.items[pi];
                try emitOuterNulls(self.gpa, &out_rows, lt, rt, if (build_left) null else prow, if (build_left) prow else null);
            }
        }

        // Index nested-loop join is only chosen when the index is selective:
        // compare the average posting length (matches per key) against the cost
        // of building a hash table over the build side. Many-to-many keys fall
        // back to the radix hash join.
        var build_idx: ?*columnar.KeyIndex = null;
        if (std.c.getenv("ZHDB_NO_INDEX_JOIN") == null) {
            if (self.findColumnar(build_t.name)) |bct| {
                if (bct.keyidx.len > build_col) {
                    if (bct.keyidx[build_col]) |idx| {
                        const avg_posting: usize = if (idx.keys.len > 0) idx.rows.len / idx.keys.len else 0;
                        const est_matches = probe_t.rows.items.len * avg_posting;
                        const use = avg_posting <= 4 and est_matches <= build_t.rows.items.len * 2;
                        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                            std.debug.print("[plan] join index: avg_posting={d} est_matches={d} build_rows={d} -> {s}\n", .{
                                avg_posting, est_matches, build_t.rows.items.len, if (use) "index-nl" else "hash",
                            });
                        }
                        if (use) build_idx = idx;
                    }
                }
            }
        }

        if (build_idx) |idx| {
            // Index nested loop: seek the build side per probe row.
            for (probe_t.rows.items, 0..) |prow, pri| {
                if (isRowDeleted(probe_t, pri)) continue;
                if (!self.visibleRow(probe_t, pri)) continue;
                const kv = if (tableIsNull(probe_t, probe_col, pri)) Value.null else prow[probe_col];
                if (kv == .null) {
                    if (j.left or j.right) try emitOuterNulls(self.gpa, &out_rows, lt, rt, if (build_left) null else prow, if (build_left) prow else null);
                    continue;
                }
                var matched = false;
                if (kv == .int) {
                    var rids = std.ArrayList(u32).empty;
                    defer rids.deinit(self.gpa);
                    try idx.range(self.gpa, kv.int, kv.int, &rids);
                    for (rids.items) |bi| {
                        if (build_filter) |f| {
                            if (!truthy(try self.eval(alloc, f, build_t.rows.items[bi], build_t.cols, null))) continue;
                        }
                        matched = true;
                        const lrow = if (build_left) build_t.rows.items[bi] else prow;
                        const rrow = if (build_left) prow else build_t.rows.items[bi];
                        if (!try self.extraRowOk(alloc, extra_plan, lrow, rrow, combined)) continue;
                        const row = try self.gpa.alloc(Value, lt.cols.len + rt.cols.len);
                        @memcpy(row[0..lt.cols.len], lrow);
                        @memcpy(row[lt.cols.len..], rrow);
                        try out_rows.append(self.gpa, row);
                        if (is_full) build_matched[bi] = true;
                    }
                }
                if (!matched and (j.left or j.right)) {
                    try emitOuterNulls(self.gpa, &out_rows, lt, rt, if (build_left) null else prow, if (build_left) prow else null);
                }
            }
        } else {
            const Buckets = std.StringHashMap(std.ArrayList(u32));
            var map = Buckets.init(self.gpa);
            defer map.deinit();
            var p: usize = 0;
            while (p < parts) : (p += 1) {
                if (pparts[p].items.len == 0) continue;
                // Build this partition's hash table, then stream the probe side.
                for (bparts[p].items) |bi| {
                    const row = build_t.rows.items[bi];
                    const k = try formatValue(alloc, row[build_col]);
                    const gop = try map.getOrPut(k);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.gpa, bi);
                }
                for (pparts[p].items) |pi| {
                    const prow = probe_t.rows.items[pi];
                    const k = try formatValue(alloc, prow[probe_col]);
                    var matched = false;
                    if (map.get(k)) |list| {
                        matched = list.items.len > 0;
                        for (list.items) |bi| {
                            const lrow = if (build_left) build_t.rows.items[bi] else prow;
                            const rrow = if (build_left) prow else build_t.rows.items[bi];
                            if (!try self.extraRowOk(alloc, extra_plan, lrow, rrow, combined)) continue;
                            const row = try self.gpa.alloc(Value, lt.cols.len + rt.cols.len);
                            @memcpy(row[0..lt.cols.len], lrow);
                            @memcpy(row[lt.cols.len..], rrow);
                            try out_rows.append(self.gpa, row);
                            if (is_full) build_matched[bi] = true;
                        }
                    }
                    if (!matched and (j.left or j.right)) {
                        try emitOuterNulls(self.gpa, &out_rows, lt, rt, if (build_left) null else prow, if (build_left) prow else null);
                    }
                }
                var it = map.valueIterator();
                while (it.next()) |v| v.deinit(self.gpa);
                map.clearRetainingCapacity();
            }

        }

        if (is_full) {
            for (build_t.rows.items, 0..) |brow, bi| {
                if (build_matched[bi]) continue;
                if (isRowDeleted(build_t, bi)) continue;
                if (!self.visibleRow(build_t, bi)) continue;
                if (build_filter) |f| {
                    if (!truthy(try self.eval(alloc, f, brow, build_t.cols, null))) continue;
                }
                try emitOuterNulls(self.gpa, &out_rows, lt, rt, if (build_left) brow else null, if (build_left) null else brow);
            }
        }
        const name = try std.fmt.allocPrint(self.gpa, "__join_{d}", .{tls_join_seq});
        tls_join_seq += 1;
        const defs = try self.gpa.alloc(sql.ColumnDef, lt.cols.len + rt.cols.len);
        defer self.gpa.free(defs);
        for (0..lt.cols.len) |i| defs[i] = .{ .name = lt.cols[i].name, .type_name = typeName(lt.cols[i].ty) };
        for (0..rt.cols.len) |i| defs[lt.cols.len + i] = .{ .name = rt.cols[i].name, .type_name = typeName(rt.cols[i].ty) };
        const tmp = try Table.create(self.gpa, name, defs);
        for (0..lt.cols.len) |i| tmp.cols[i].source = sel.alias orelse lname;
        for (0..rt.cols.len) |i| tmp.cols[lt.cols.len + i].source = j.alias orelse j.table;
        tmp.rows = out_rows;
        // Per-key statistics so the next chain step can estimate duplicate-key
        // fan-out instead of falling back to 1/max(ndv).
        self.computeTempStats(tmp);
        if (std.c.getenv("ZHDB_DBG_JOIN2") != null) {
            std.debug.print("[join] tmp={s} ncols={d} rows={d} leftcols={d}:", .{ name, tmp.cols.len, tmp.rows.items.len, lt.cols.len });
            for (tmp.cols, 0..) |c, i| std.debug.print(" {d}:{s}", .{ i, c.name });
            std.debug.print("\n", .{});
            for (sel.items, 0..) |it, i| std.debug.print("[join] item{d}={any}\n", .{ i, it.expr.* });
        }
        try self.tempTables().put(name, tmp);
        self.buildColumnar(name) catch {};
        if (!finalize) {
            tls_kept_join = name;
            return .{ .columns = &.{}, .rows = &.{}, .affected = tmp.rows.items.len };
        }
        defer self.dropJoinTemp(name);
        var sel2 = sel.*;
        sel2.from = .{ .table = name };
        sel2.join = null;
        sel2.more_joins = &.{};
        if (j.extra_eqs.len > 0) {
            // Rewrite the extra equality conjuncts to positions in the temp
            // (qualifiers no longer resolve after the join has been applied).
            var extra_where = sel.where;
            for (j.extra_eqs) |e| {
                if (e.* != .binary) continue;
                const el = colOfSide(lt, lname, sel.alias, e.binary.lhs);
                const er = colOfSide(rt, j.table, j.alias, e.binary.lhs);
                const fl = colOfSide(lt, lname, sel.alias, e.binary.rhs);
                const fr = colOfSide(rt, j.table, j.alias, e.binary.rhs);
                var li: ?usize = null;
                var ri: ?usize = null;
                if (el != null and fr != null) {
                    li = el;
                    ri = fr;
                } else if (fl != null and er != null) {
                    li = fl;
                    ri = er;
                }
                if (li == null or ri == null) continue;
                const clhs = try alloc.create(sql.Expr);
                clhs.* = .{ .column_idx = .{ .idx = @intCast(li.?), .name = "" } };
                const crhs = try alloc.create(sql.Expr);
                crhs.* = .{ .column_idx = .{ .idx = @intCast(lt.cols.len + ri.?), .name = "" } };
                const cmp = try alloc.create(sql.Expr);
                cmp.* = .{ .binary = .{ .op = .eq, .lhs = clhs, .rhs = crhs } };
                extra_where = try andAll(alloc, &.{ extra_where orelse cmp, cmp });
            }
            sel2.where = extra_where;
        }
        return self.execSelect(alloc, &sel2, true);
    }

    /// Insert `(v, c)` into a bounded, count-descending key list.
    fn pushKeyCand(d: *KeyDist, sv: []const u8, iv: i64, c: f64) void {
        var pos: usize = 0;
        while (pos < d.n and d.vals[pos].c >= c) : (pos += 1) {}
        if (pos >= d.vals.len) return;
        var k: usize = @min(d.n, d.vals.len - 1);
        while (k > pos) : (k -= 1) {
            d.vals[k] = d.vals[k - 1];
            d.svals[k] = d.svals[k - 1];
        }
        d.vals[pos] = .{ .v = iv, .c = c };
        d.svals[pos] = sv;
        if (d.n < d.vals.len) d.n += 1;
    }

    /// Exact per-value row counts for a float column (keys via `f64Key`),
    /// cached per (table, column). Built once from the columnar image with no
    /// planning-row cap; the cache is dropped whenever the image is rebuilt.
    fn floatKeyCounts(self: *Engine, name: []const u8, ct: *columnar.Table, ci: usize) ?*FloatCountEntry {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\t{d}", .{ name, ci }) catch return null;
        if (self.float_counts.getPtr(key)) |e| return e;
        if (ci >= ct.data.len or ct.data[ci] != .floats) return null;
        const n = ct.nrows;
        if (n == 0) return null;
        var m = std.AutoHashMap(i64, u32).init(self.gpa);
        const v = ct.data[ci].floats;
        var ri: usize = 0;
        while (ri < n) : (ri += 1) {
            if (ct.isDeleted(ri) or ct.isNull(ci, ri)) continue;
            const x = v[ri];
            if (std.math.isNan(x)) continue;
            const gop = m.getOrPut(f64Key(x)) catch {
                m.deinit();
                return null;
            };
            if (!gop.found_existing) {
                // Memory bound only (2M distinct values per column).
                if (m.count() > 2_000_000) {
                    m.deinit();
                    return null;
                }
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] float-counts {s}.c{d} values={d} (cached)\n", .{ name, ci, m.count() });
        }
        const owned = self.gpa.dupe(u8, key) catch {
            m.deinit();
            return null;
        };
        self.float_counts.put(owned, .{ .map = m }) catch {
            self.gpa.free(owned);
            m.deinit();
            return null;
        };
        return self.float_counts.getPtr(owned);
    }

    /// Drop cached float counts for `name` (columnar image rebuilt/replaced or
    /// a temporary table destroyed).
    fn dropFloatCounts(self: *Engine, name: []const u8) void {
        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(self.gpa);
        var it = self.float_counts.keyIterator();
        while (it.next()) |k| {
            const ks = k.*;
            if (ks.len > name.len and std.mem.startsWith(u8, ks, name) and ks[name.len] == '\t') {
                keys.append(self.gpa, ks) catch {};
            }
        }
        for (keys.items) |k| {
            if (self.float_counts.fetchRemove(k)) |kv| {
                var mm = kv.value.map;
                mm.deinit();
                self.gpa.free(kv.key);
            }
        }
    }

    /// Equi-join cardinality over a set of base tables whose key distributions
    /// are all known: `Σ_v Π_t count_t(v)·sel_t`.
    ///
    /// - String keys: exact value dictionaries (≤20k entries); sampled maps are
    ///   scaled and the uncovered mass becomes a residual term.
    /// - Numeric keys: the columnar dictionary encoding's per-value row counts
    ///   (ints), or float value counts derived from the columnar image via
    ///   `f64Key` (floats). Both are exact for all non-null rows.
    ///
    /// Returns null when a map is missing, too large, or the members mix kinds.
    fn exactKeyProduct(self: *Engine, members: []const KeyMember, where: ?*sql.Expr) ?f64 {
        if (members.len == 0 or members.len > 10) return null;
        const Kind = enum { str, num };
        var kind: ?Kind = null;
        var tbls: [10]*Table = undefined;
        var cols: [10]usize = undefined;
        var sels: [10]f64 = undefined;
        var scales: [10]f64 = undefined;
        var res_rows: [10]f64 = undefined;
        var rest_ndv: [10]f64 = undefined;
        var nmaps: [10]?std.AutoHashMap(i64, f64) = @splat(null);
        defer for (&nmaps) |*mp| {
            if (mp.*) |*m2| m2.deinit();
        };
        var sizes: [10]usize = undefined;
        var smallest: usize = 0;
        for (members, 0..) |m, i| {
            const t = self.find(m.t) orelse return null;
            if (m.c >= t.cols.len) return null;
            _ = self.ensureColStatQuick(t, m.c);
            if (m.c >= t.stats.len) return null;
            const st = t.stats[m.c];
            tbls[i] = t;
            cols[i] = m.c;
            sels[i] = self.whereSelectivity(m.t, where);
            if (st.dict.len > 0) {
                if (kind != null and kind.? != .str) return null;
                kind = .str;
                if (st.dict.len > 20000) return null;
                sizes[i] = st.dict.len;
                scales[i] = if (st.dict_sampled and st.dict_sample_rows > 0)
                    @as(f64, @floatFromInt(t.rows.items.len)) / @as(f64, @floatFromInt(st.dict_sample_rows))
                else
                    1.0;
                var kept: f64 = 0;
                for (st.dict) |e| kept += @as(f64, @floatFromInt(e.count)) * scales[i] * sels[i];
                const r: f64 = @as(f64, @floatFromInt(t.rows.items.len)) * sels[i];
                res_rows[i] = if (st.dict_sampled) @max(r - kept, 0.0) else 0.0;
                rest_ndv[i] = @max(@as(f64, @floatFromInt(st.ndv)) - @as(f64, @floatFromInt(st.dict.len)), 1.0);
            } else {
                const ct = self.findColumnar(m.t) orelse return null;
                if (kind != null and kind.? != .num) return null;
                kind = .num;
                var mp = std.AutoHashMap(i64, f64).init(self.gpa);
                var built = false;
                if (m.c < ct.enc.len and ct.enc[m.c] != null) {
                    const e = ct.enc[m.c].?;
                    if (e.counts.len == e.first.len and e.first.len > 0 and e.first.len <= 20000) {
                        for (e.first, 0..) |row, id| {
                            const val = numericKeyAt(ct, m.c, row) orelse {
                                mp.deinit();
                                return null;
                            };
                            mp.put(val, @as(f64, @floatFromInt(e.counts[id])) * sels[i]) catch {
                                mp.deinit();
                                return null;
                            };
                        }
                        built = true;
                    }
                }
                if (!built and t.cols[m.c].ty == .float) {
                    const cm = self.floatKeyCounts(m.t, ct, m.c) orelse {
                        mp.deinit();
                        return null;
                    };
                    var it = cm.map.iterator();
                    while (it.next()) |e| {
                        mp.put(e.key_ptr.*, @as(f64, @floatFromInt(e.value_ptr.*)) * sels[i]) catch {
                            mp.deinit();
                            return null;
                        };
                    }
                    built = true;
                }
                if (!built) {
                    mp.deinit();
                    return null;
                }
                sizes[i] = mp.count();
                nmaps[i] = mp;
                res_rows[i] = 0.0;
                rest_ndv[i] = 1.0;
            }
            if (sizes[i] < sizes[smallest]) smallest = i;
        }
        if (kind == null) return null;
        if (kind.? == .num) {
            var smi: ?usize = null;
            for (0..members.len) |i| {
                if (nmaps[i] == null) return null;
                if (smi == null or nmaps[i].?.count() < nmaps[smi.?].?.count()) smi = i;
            }
            const si = smi.?;
            var total: f64 = 0;
            var it = nmaps[si].?.iterator();
            while (it.next()) |e| {
                var prod = e.value_ptr.*;
                for (0..members.len) |i| {
                    if (i == si) continue;
                    const cv = nmaps[i].?.get(e.key_ptr.*) orelse {
                        prod = 0;
                        break;
                    };
                    prod *= cv;
                }
                total += prod;
            }
            return total;
        }
        // String dictionaries (exact or sampled).
        var maps: [10]std.StringHashMap(f64) = undefined;
        for (&maps) |*mp| mp.* = std.StringHashMap(f64).init(self.gpa);
        defer for (&maps) |*mp| mp.deinit();
        for (0..members.len) |i| {
            if (i == smallest) continue;
            const st = tbls[i].stats[cols[i]];
            maps[i].ensureTotalCapacity(@intCast(st.dict.len)) catch return null;
            for (st.dict) |e| {
                const c = @as(f64, @floatFromInt(e.count)) * scales[i] * sels[i];
                if (c > 0) maps[i].put(e.s, c) catch return null;
            }
        }
        const base_st = tbls[smallest].stats[cols[smallest]];
        var total: f64 = 0;
        for (base_st.dict) |e| {
            var prod = @as(f64, @floatFromInt(e.count)) * scales[smallest] * sels[smallest];
            if (prod == 0) continue;
            for (0..members.len) |i| {
                if (i == smallest) continue;
                const cv = maps[i].get(e.s) orelse blk: {
                    if (res_rows[i] <= 0) {
                        prod = 0;
                        break;
                    }
                    break :blk res_rows[i] / rest_ndv[i];
                };
                prod *= cv;
            }
            total += prod;
        }
        if (members.len >= 2) {
            var min_ndv: f64 = rest_ndv[0];
            var prod_rows: f64 = 1.0;
            var prod_ndv: f64 = 1.0;
            var any = false;
            for (0..members.len) |i| {
                min_ndv = @min(min_ndv, rest_ndv[i]);
                prod_rows *= res_rows[i];
                prod_ndv *= rest_ndv[i];
                if (res_rows[i] > 0) any = true;
            }
            if (any and prod_ndv > 0) total += min_ndv * prod_rows / prod_ndv;
        }
        return total;
    }

    /// Exact per-value row counts of a numeric column, from its dictionary
    /// encoding when present (integer columns with a bounded value space).
    fn encValueCounts(self: *Engine, ct: *columnar.Table, ci: usize) ?std.AutoHashMap(i64, f64) {
        if (ci >= ct.enc.len or ct.enc[ci] == null) return null;
        const e = ct.enc[ci].?;
        if (e.counts.len != e.first.len or e.first.len == 0) return null;
        var m = std.AutoHashMap(i64, f64).init(self.gpa);
        for (e.first, 0..) |row, id| {
            const val = numericKeyAt(ct, ci, row) orelse {
                m.deinit();
                return null;
            };
            m.put(val, @floatFromInt(e.counts[id])) catch {
                m.deinit();
                return null;
            };
        }
        return m;
    }

    const JoinedDist = struct { pairs: f64, kd: KeyDist };

    /// Exact fan-out join when the partial result is a **star centered on
    /// `t`** (every mask join constrains a column of `t`): each row of `t` is
    /// repeated by the product of the matching new-table rows for its keys, so
    /// the switched column's distribution and its join with `bt.bc` are exact.
    fn maskFanoutJoin(
        self: *Engine,
        center_name: []const u8,
        center_alias: ?[]const u8,
        lname: []const u8,
        lalias: ?[]const u8,
        pending: []sql.Join,
        mask: usize,
        m: usize,
        c_new: usize,
        bt: *Table,
        bc: usize,
    ) ?JoinedDist {
        if (std.c.getenv("ZHDB_NO_MASK_FANOUT") != null) return null;
        if (std.c.getenv("ZHDB_NO_SHAPE_FANOUT") != null) return null;
        const t = self.find(center_name) orelse return null;
        const ct = self.findColumnar(t.name) orelse return null;
        if (c_new >= ct.data.len) return null;
        const bct = self.findColumnar(bt.name) orelse return null;
        const bmp = self.exactCountsCached(bt.name, bct, bc) orelse return null;
        _ = self.ensureColStatQuick(bt, bc);
        if (bc >= bt.stats.len) return null;
        // Resolve each mask join's column on `t` and its matching counts map.
        var tcols: [8]usize = @splat(0);
        var maps: [8]*FloatCountEntry = undefined;
        var nj: usize = 0;
        var kk: usize = 0;
        while (kk < m) : (kk += 1) {
            if (mask & (@as(usize, 1) << @intCast(kk)) == 0) continue;
            const j = pending[kk];
            if (j.on.* != .binary) return null;
            // Aliased self-join: the joined side is the same base table under a
            // different alias, which is legitimate (its counts come from that
            // same table's column).
            const tl = colOfSide(t, t.name, center_alias, j.on.binary.lhs);
            const tr = colOfSide(t, t.name, center_alias, j.on.binary.rhs);
            if ((tl != null) == (tr != null)) return null;
            const tside = tl orelse tr.?;
            // The join's other endpoint is whichever mask table matches the
            // opposite operand (it may be the first table, another joined table,
            // or the same base table under a different alias).
            const other_expr = if (tl != null) j.on.binary.rhs else j.on.binary.lhs;
            var found_other = false;
            var cand: [10]struct { name: []const u8, alias: ?[]const u8 } = undefined;
            var ncand: usize = 0;
            cand[ncand] = .{ .name = lname, .alias = lalias };
            ncand += 1;
            var kb: usize = 0;
            while (kb < m) : (kb += 1) {
                if (mask & (@as(usize, 1) << @intCast(kb)) == 0) continue;
                if (ncand < cand.len) {
                    cand[ncand] = .{ .name = pending[kb].table, .alias = pending[kb].alias };
                    ncand += 1;
                }
            }
            var ci2: usize = 0;
            while (ci2 < ncand) : (ci2 += 1) {
                const cnm = cand[ci2].name;
                const cal = cand[ci2].alias;
                if (std.ascii.eqlIgnoreCase(cnm, center_name) and
                    ((cal == null and center_alias == null) or
                        (cal != null and center_alias != null and std.ascii.eqlIgnoreCase(cal.?, center_alias.?)))) continue;
                const jt = self.find(cnm) orelse continue;
                const jside = colOfSide(jt, cnm, cal, other_expr) orelse continue;
                const jct = self.findColumnar(cnm) orelse continue;
                maps[nj] = self.exactCountsCached(cnm, jct, jside) orelse continue;
                found_other = true;
                break;
            }
            if (!found_other) return null;
            tcols[nj] = tside;
            nj += 1;
        }
        if (nj == 0) return null;
        const n = ct.nrows;
        if (n == 0) return null;
        var acc = std.AutoHashMap(i64, f64).init(self.gpa);
        defer acc.deinit();
        var pairs: f64 = 0;
        var step: usize = if (n <= 2_000_000) 1 else @max(1, n / 20000);
        if (step > 1 and step % 2 == 0) step += 1;
        const scale: f64 = if (step > 1) @floatFromInt(step) else 1.0;
        var ri: usize = 0;
        while (ri < n) : (ri += step) {
            if (ct.isDeleted(ri)) continue;
            var factor: f64 = 1;
            var zi: usize = 0;
            while (zi < nj) : (zi += 1) {
                if (ct.isNull(tcols[zi], ri)) {
                    factor = 0;
                    break;
                }
                const v = numericKeyAt(ct, tcols[zi], ri) orelse {
                    factor = 0;
                    break;
                };
                const c = maps[zi].map.get(v) orelse {
                    factor = 0;
                    break;
                };
                factor *= @floatFromInt(c);
            }
            if (factor <= 0) continue;
            if (ct.isNull(c_new, ri)) continue;
            const vn = numericKeyAt(ct, c_new, ri) orelse continue;
            const cr = bmp.map.get(vn) orelse continue;
            const prod = factor * scale * @as(f64, @floatFromInt(cr));
            pairs += prod;
            const gop = acc.getOrPut(vn) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += prod;
        }
        if (pairs <= 0) return null;
        var out = KeyDist{};
        out.is_float = bt.cols[bc].ty == .float;
        out.scaled = true;
        out.min = bt.stats[bc].min;
        out.max = bt.stats[bc].max;
        out.rows = pairs;
        out.members[0] = .{ .t = t.name, .c = c_new };
        out.members[1] = .{ .t = bt.name, .c = bc };
        out.nm = 2;
        var it = acc.iterator();
        while (it.next()) |e| pushKeyCand(&out, "", e.key_ptr.*, e.value_ptr.*);
        var explicit_sum: f64 = 0;
        for (out.vals[0..out.n]) |e| explicit_sum += e.c;
        out.res_rows = @max(pairs - explicit_sum, 0.0);
        out.res_ndv = @max(@as(f64, @floatFromInt(bt.stats[bc].ndv)) - @as(f64, @floatFromInt(out.n)), 1.0);
        out.valid = true;
        return .{ .pairs = pairs, .kd = out };
    }

    const FNode = struct { name: []const u8, alias: ?[]const u8, t: *Table, ct: *columnar.Table };
    const FEdge = struct { a: usize, ca: usize, b: usize, cb: usize };

    fn fanResolveNode(nodes: []const FNode, e: *sql.Expr) ?struct { idx: usize, col: usize } {
        var found: ?usize = null;
        var col: usize = 0;
        for (nodes, 0..) |nd, i| {
            if (colOfSide(nd.t, nd.name, nd.alias, e)) |c| {
                if (found != null) return null; // ambiguous
                found = i;
                col = c;
            }
        }
        if (found) |i| return .{ .idx = i, .col = col };
        return null;
    }

    /// Chained masks: center -> hub -> branch tables. Every mask join touches a
    /// single hub `H` (one edge to the center, the rest to branch tables), so the
    /// center row's multiplicity is the hub-weighted sum per join-key value.
    fn hubFanoutJoin(
        self: *Engine,
        center_name: []const u8,
        center_alias: ?[]const u8,
        lname: []const u8,
        lalias: ?[]const u8,
        pending: []sql.Join,
        mask: usize,
        m: usize,
        c_new: usize,
        bt: *Table,
        bc: usize,
    ) ?JoinedDist {
        if (std.c.getenv("ZHDB_NO_MASK_FANOUT") != null) return null;
        if (std.c.getenv("ZHDB_NO_SHAPE_FANOUT") != null) return null;
        var nodes: [9]FNode = undefined;
        var nn: usize = 0;
        const lt0 = self.find(lname) orelse return null;
        const lct0 = self.findColumnar(lname) orelse return null;
        nodes[nn] = .{ .name = lname, .alias = lalias, .t = lt0, .ct = lct0 };
        nn += 1;
        var kk: usize = 0;
        while (kk < m) : (kk += 1) {
            if (mask & (@as(usize, 1) << @intCast(kk)) == 0) continue;
            const nm = pending[kk].table;
            const nt = self.find(nm) orelse return null;
            const nct = self.findColumnar(nm) orelse return null;
            nodes[nn] = .{ .name = nm, .alias = pending[kk].alias, .t = nt, .ct = nct };
            nn += 1;
        }
        var center_idx: ?usize = null;
        for (nodes[0..nn], 0..) |nd, i| {
            if (!std.ascii.eqlIgnoreCase(nd.name, center_name)) continue;
            const amatch = (nd.alias == null and center_alias == null) or
                (nd.alias != null and center_alias != null and std.ascii.eqlIgnoreCase(nd.alias.?, center_alias.?));
            if (amatch) {
                if (center_idx != null) return null;
                center_idx = i;
            }
        }
        const ci = center_idx orelse return null;
        var edges: [8]FEdge = undefined;
        var ne: usize = 0;
        kk = 0;
        while (kk < m) : (kk += 1) {
            if (mask & (@as(usize, 1) << @intCast(kk)) == 0) continue;
            const j = pending[kk];
            if (j.on.* != .binary) return null;
            const la = fanResolveNode(nodes[0..nn], j.on.binary.lhs) orelse return null;
            const rb = fanResolveNode(nodes[0..nn], j.on.binary.rhs) orelse return null;
            if (la.idx == rb.idx) return null;
            edges[ne] = .{ .a = la.idx, .ca = la.col, .b = rb.idx, .cb = rb.col };
            ne += 1;
        }
        // Find a hub: every edge touches it, and exactly one edge links it to
        // the center.
        var hub: ?usize = null;
        var hub_center_edge: ?usize = null;
        var h: usize = 0;
        while (h < nn) : (h += 1) {
            if (h == ci) continue;
            var all = true;
            var ce: ?usize = null;
            for (edges[0..ne], 0..) |e, ei| {
                const touches = e.a == h or e.b == h;
                if (!touches) {
                    all = false;
                    break;
                }
                const to_center = (e.a == h and e.b == ci) or (e.b == h and e.a == ci);
                if (to_center) {
                    if (ce != null) {
                        all = false;
                        break;
                    }
                    ce = ei;
                }
            }
            if (all and ce != null) {
                hub = h;
                hub_center_edge = ce;
                break;
            }
        }
        const hu = hub orelse return null;
        const cei = hub_center_edge orelse return null;
        const cedge = edges[cei];
        const center_col = if (cedge.a == ci) cedge.ca else cedge.cb;
        const hub_col = if (cedge.a == hu) cedge.ca else cedge.cb;
        const hu_node = nodes[hu];
        if (center_col >= nodes[ci].ct.data.len or hu_node.ct.nrows == 0) return null;
        if (self.findColumnar(bt.name) == null) return null;
        const bct = self.findColumnar(bt.name).?;
        const bmp = self.exactCountsCached(bt.name, bct, bc) orelse return null;
        _ = self.ensureColStatQuick(bt, bc);
        if (bc >= bt.stats.len) return null;
        // Branch edges (hub <-> branch table): per-hub-column factor maps.
        var branch_cols: [8]usize = @splat(0);
        var branch_maps: [8]*FloatCountEntry = undefined;
        var nb: usize = 0;
        for (edges[0..ne], 0..) |e, ei| {
            if (ei == cei) continue;
            if (e.a != hu and e.b != hu) return null;
            const other = if (e.a == hu) e.b else e.a;
            const hcol = if (e.a == hu) e.ca else e.cb;
            const ocol = if (e.a == hu) e.cb else e.ca;
            const om = self.exactCountsCached(nodes[other].name, nodes[other].ct, ocol) orelse return null;
            branch_maps[nb] = om;
            branch_cols[nb] = hcol;
            nb += 1;
        }
        // Hub scan: weight of each hub row = product of branch match counts,
        // aggregated by the hub's center-join key.
        var acc = std.AutoHashMap(i64, f64).init(self.gpa);
        defer acc.deinit();
        const hn = hu_node.ct.nrows;
        if (hn > 4_000_000) return null;
        var ri: usize = 0;
        while (ri < hn) : (ri += 1) {
            if (hu_node.ct.isDeleted(ri)) continue;
            var w: f64 = 1;
            var bi: usize = 0;
            while (bi < nb) : (bi += 1) {
                if (hu_node.ct.isNull(branch_cols[bi], ri)) {
                    w = 0;
                    break;
                }
                const v = numericKeyAt(hu_node.ct, branch_cols[bi], ri) orelse {
                    w = 0;
                    break;
                };
                const c = branch_maps[bi].map.get(v) orelse {
                    w = 0;
                    break;
                };
                w *= @floatFromInt(c);
            }
            if (w <= 0) continue;
            if (hu_node.ct.isNull(hub_col, ri)) continue;
            const hv = numericKeyAt(hu_node.ct, hub_col, ri) orelse continue;
            const gop = acc.getOrPut(hv) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += w;
        }
        if (acc.count() == 0) return null;
        // Center scan: multiplicity from the hub weights, join with `bt.bc`.
        const ct = nodes[ci].ct;
        var out_acc = std.AutoHashMap(i64, f64).init(self.gpa);
        defer out_acc.deinit();
        var pairs: f64 = 0;
        const cn = ct.nrows;
        if (cn > 4_000_000) return null;
        const c_new_col = c_new;
        if (c_new_col >= ct.data.len) return null;
        ri = 0;
        while (ri < cn) : (ri += 1) {
            if (ct.isDeleted(ri) or ct.isNull(center_col, ri) or ct.isNull(c_new_col, ri)) continue;
            const cv = numericKeyAt(ct, center_col, ri) orelse continue;
            const w = acc.get(cv) orelse continue;
            if (w <= 0) continue;
            const nv = numericKeyAt(ct, c_new_col, ri) orelse continue;
            const cr = bmp.map.get(nv) orelse continue;
            const prod = w * @as(f64, @floatFromInt(cr));
            pairs += prod;
            const gop = out_acc.getOrPut(nv) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += prod;
        }
        if (pairs <= 0) return null;
        var out = KeyDist{};
        out.is_float = bt.cols[bc].ty == .float;
        out.scaled = true;
        out.min = bt.stats[bc].min;
        out.max = bt.stats[bc].max;
        out.rows = pairs;
        out.members[0] = .{ .t = nodes[ci].name, .c = c_new };
        out.members[1] = .{ .t = bt.name, .c = bc };
        out.nm = 2;
        var it = out_acc.iterator();
        while (it.next()) |e| pushKeyCand(&out, "", e.key_ptr.*, e.value_ptr.*);
        var explicit_sum: f64 = 0;
        for (out.vals[0..out.n]) |e| explicit_sum += e.c;
        out.res_rows = @max(pairs - explicit_sum, 0.0);
        out.res_ndv = @max(@as(f64, @floatFromInt(bt.stats[bc].ndv)) - @as(f64, @floatFromInt(out.n)), 1.0);
        out.valid = true;
        return .{ .pairs = pairs, .kd = out };
    }

    /// Exact per-value counts of an equality class (`members`), as the product
    /// of each member's exact value counts. No top-48 truncation: every value
    /// present in all members is represented.
    fn classCountsInto(self: *Engine, members: []const KeyMember, out: *std.AutoHashMap(i64, f64)) bool {
        if (members.len == 0 or members.len > 10) return false;
        var maps: [10]*const std.AutoHashMap(i64, u32) = undefined;
        var smallest: usize = 0;
        for (members, 0..) |m, i| {
            const t = self.find(m.t) orelse return false;
            if (m.c >= t.cols.len) return false;
            if (self.tempTables().get(m.t) != null) {
                if (self.exactTempCounts(t, m.c)) |e| {
                    maps[i] = &e.map;
                } else return false;
            } else {
                const ct = self.findColumnar(m.t) orelse return false;
                if (self.exactCountsCached(m.t, ct, m.c)) |e| {
                    maps[i] = &e.map;
                } else return false;
            }
            if (maps[i].count() < maps[smallest].count()) smallest = i;
        }
        if (maps[smallest].count() > 2_000_000) return false;
        out.clearRetainingCapacity();
        out.ensureTotalCapacity(@intCast(maps[smallest].count())) catch return false;
        var it = maps[smallest].iterator();
        while (it.next()) |e| {
            var prod: f64 = @floatFromInt(e.value_ptr.*);
            var ok = true;
            for (0..members.len) |i| {
                if (i == smallest) continue;
                const cv = maps[i].get(e.key_ptr.*) orelse {
                    ok = false;
                    break;
                };
                prod *= @floatFromInt(cv);
            }
            if (!ok or prod <= 0) continue;
            out.put(e.key_ptr.*, prod) catch return false;
        }
        return out.count() > 0;
    }

    /// Recursive tree factorization: for `node`, return a map from the value of
    /// its column on `parent_e` to the total number of result rows contributed
    /// by the subtree under it (including node's own row repetitions).
    fn treeMap(
        self: *Engine,
        nodes: []const FNode,
        edges: []const FEdge,
        adj: *const [9][8]usize,
        adjn: *const [9]usize,
        node: usize,
        parent_e: usize,
        depth: usize,
    ) ?std.AutoHashMap(i64, f64) {
        if (depth > 8) return null;
        const ct = nodes[node].ct;
        const n = ct.nrows;
        if (n > 4_000_000) return null;
        // Resolve child edges and their subtree maps.
        var child_maps: [8]std.AutoHashMap(i64, f64) = undefined;
        var child_cols: [8]usize = @splat(0);
        var child_n: usize = 0;
        var ok = true;
        var ai: usize = 0;
        while (ai < adjn[node]) : (ai += 1) {
            const ei = adj[node][ai];
            if (ei == parent_e) continue;
            const e = edges[ei];
            const child = if (e.a == node) e.b else e.a;
            const ncol = if (e.a == node) e.ca else e.cb;
            const cm = self.treeMap(nodes, edges, adj, adjn, child, ei, depth + 1) orelse {
                ok = false;
                break;
            };
            child_maps[child_n] = cm;
            child_cols[child_n] = ncol;
            child_n += 1;
        }
        if (!ok) {
            for (child_maps[0..child_n]) |*m| m.deinit();
            return null;
        }
        defer for (child_maps[0..child_n]) |*m| m.deinit();
        const e = edges[parent_e];
        const pcol = if (e.a == node) e.ca else e.cb;
        var acc = std.AutoHashMap(i64, f64).init(self.gpa);
        var ri: usize = 0;
        while (ri < n) : (ri += 1) {
            if (ct.isDeleted(ri)) continue;
            var w: f64 = 1;
            var cj: usize = 0;
            while (cj < child_n) : (cj += 1) {
                if (ct.isNull(child_cols[cj], ri)) {
                    w = 0;
                    break;
                }
                const v = numericKeyAt(ct, child_cols[cj], ri) orelse {
                    w = 0;
                    break;
                };
                const c = child_maps[cj].get(v) orelse {
                    w = 0;
                    break;
                };
                w *= c;
            }
            if (w <= 0) continue;
            if (ct.isNull(pcol, ri)) continue;
            const pv = numericKeyAt(ct, pcol, ri) orelse continue;
            const gop = acc.getOrPut(pv) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += w;
        }
        if (acc.count() == 0) {
            acc.deinit();
            return null;
        }
        return acc;
    }

    /// General tree fan-out: the mask's join graph is rooted at the center; each
    /// node's subtree multiplicity is factored bottom-up, so a switch to any
    /// column of any table in the mask is computed exactly (no single-hub
    /// restriction, no top-48 sketch).
    fn treeFanoutJoin(
        self: *Engine,
        center_name: []const u8,
        center_alias: ?[]const u8,
        lname: []const u8,
        lalias: ?[]const u8,
        pending: []sql.Join,
        mask: usize,
        m: usize,
        c_new: usize,
        bt: *Table,
        bc: usize,
    ) ?JoinedDist {
        if (std.c.getenv("ZHDB_NO_MASK_FANOUT") != null) return null;
        if (std.c.getenv("ZHDB_NO_SHAPE_FANOUT") != null) return null;
        var nodes: [9]FNode = undefined;
        var nn: usize = 0;
        const lt0 = self.find(lname) orelse return null;
        const lct0 = self.findColumnar(lname) orelse return null;
        nodes[nn] = .{ .name = lname, .alias = lalias, .t = lt0, .ct = lct0 };
        nn += 1;
        var kk: usize = 0;
        while (kk < m) : (kk += 1) {
            if (mask & (@as(usize, 1) << @intCast(kk)) == 0) continue;
            const nm = pending[kk].table;
            const nt = self.find(nm) orelse return null;
            const nct = self.findColumnar(nm) orelse return null;
            nodes[nn] = .{ .name = nm, .alias = pending[kk].alias, .t = nt, .ct = nct };
            nn += 1;
        }
        var ci: ?usize = null;
        for (nodes[0..nn], 0..) |nd, i| {
            if (!std.ascii.eqlIgnoreCase(nd.name, center_name)) continue;
            const amatch = (nd.alias == null and center_alias == null) or
                (nd.alias != null and center_alias != null and std.ascii.eqlIgnoreCase(nd.alias.?, center_alias.?));
            if (amatch) {
                if (ci != null) return null;
                ci = i;
            }
        }
        const cidx = ci orelse return null;
        var edges: [8]FEdge = undefined;
        var ne: usize = 0;
        var adj: [9][8]usize = @splat(@splat(0));
        var adjn: [9]usize = @splat(0);
        kk = 0;
        while (kk < m) : (kk += 1) {
            if (mask & (@as(usize, 1) << @intCast(kk)) == 0) continue;
            const j = pending[kk];
            if (j.on.* != .binary) return null;
            const la = fanResolveNode(nodes[0..nn], j.on.binary.lhs) orelse return null;
            const rb = fanResolveNode(nodes[0..nn], j.on.binary.rhs) orelse return null;
            if (la.idx == rb.idx) return null;
            edges[ne] = .{ .a = la.idx, .ca = la.col, .b = rb.idx, .cb = rb.col };
            if (adjn[la.idx] < 8) {
                adj[la.idx][adjn[la.idx]] = ne;
                adjn[la.idx] += 1;
            }
            if (adjn[rb.idx] < 8) {
                adj[rb.idx][adjn[rb.idx]] = ne;
                adjn[rb.idx] += 1;
            }
            ne += 1;
        }
        const ct = nodes[cidx].ct;
        if (c_new >= ct.data.len) return null;
        const bct = self.findColumnar(bt.name) orelse return null;
        const bmp = self.exactCountsCached(bt.name, bct, bc) orelse return null;
        _ = self.ensureColStatQuick(bt, bc);
        if (bc >= bt.stats.len) return null;
        // Root subtree maps.
        var root_maps: [8]std.AutoHashMap(i64, f64) = undefined;
        var root_cols: [8]usize = @splat(0);
        var root_n: usize = 0;
        var ok = true;
        var ai: usize = 0;
        while (ai < adjn[cidx]) : (ai += 1) {
            const ei = adj[cidx][ai];
            const e = edges[ei];
            const child = if (e.a == cidx) e.b else e.a;
            const ncol = if (e.a == cidx) e.ca else e.cb;
            const cm = self.treeMap(nodes[0..], edges[0..], &adj, &adjn, child, ei, 1) orelse {
                ok = false;
                break;
            };
            root_maps[root_n] = cm;
            root_cols[root_n] = ncol;
            root_n += 1;
        }
        if (!ok) {
            for (root_maps[0..root_n]) |*m2| m2.deinit();
            return null;
        }
        defer for (root_maps[0..root_n]) |*m2| m2.deinit();
        var out_acc = std.AutoHashMap(i64, f64).init(self.gpa);
        defer out_acc.deinit();
        var pairs: f64 = 0;
        const cn = ct.nrows;
        if (cn > 4_000_000) return null;
        var ri: usize = 0;
        while (ri < cn) : (ri += 1) {
            if (ct.isDeleted(ri) or ct.isNull(c_new, ri)) continue;
            var w: f64 = 1;
            var cj: usize = 0;
            while (cj < root_n) : (cj += 1) {
                if (ct.isNull(root_cols[cj], ri)) {
                    w = 0;
                    break;
                }
                const v = numericKeyAt(ct, root_cols[cj], ri) orelse {
                    w = 0;
                    break;
                };
                const c = root_maps[cj].get(v) orelse {
                    w = 0;
                    break;
                };
                w *= c;
            }
            if (w <= 0) continue;
            const nv = numericKeyAt(ct, c_new, ri) orelse continue;
            const cr = bmp.map.get(nv) orelse continue;
            const prod = w * @as(f64, @floatFromInt(cr));
            pairs += prod;
            const gop = out_acc.getOrPut(nv) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += prod;
        }
        if (pairs <= 0) return null;
        var out = KeyDist{};
        out.is_float = bt.cols[bc].ty == .float;
        out.scaled = true;
        out.min = bt.stats[bc].min;
        out.max = bt.stats[bc].max;
        out.rows = pairs;
        out.members[0] = .{ .t = nodes[cidx].name, .c = c_new };
        out.members[1] = .{ .t = bt.name, .c = bc };
        out.nm = 2;
        var it = out_acc.iterator();
        while (it.next()) |e| pushKeyCand(&out, "", e.key_ptr.*, e.value_ptr.*);
        var explicit_sum: f64 = 0;
        for (out.vals[0..out.n]) |e| explicit_sum += e.c;
        out.res_rows = @max(pairs - explicit_sum, 0.0);
        out.res_ndv = @max(@as(f64, @floatFromInt(bt.stats[bc].ndv)) - @as(f64, @floatFromInt(out.n)), 1.0);
        out.valid = true;
        return .{ .pairs = pairs, .kd = out };
    }

    /// Same-key continuation: join the exact per-value counts of the tracked
    /// equality class with the new table's exact counts (no top-48 sketch).
    fn classJoinPairs(self: *Engine, members: []const KeyMember, bt: *Table, bc: usize) ?JoinedDist {
        if (std.c.getenv("ZHDB_NO_CLASS_SAMEKEY") != null) return null;
        var cls = std.AutoHashMap(i64, f64).init(self.gpa);
        defer cls.deinit();
        if (!self.classCountsInto(members, &cls)) return null;
        var bmp: ?*FloatCountEntry = null;
        if (self.tempTables().get(bt.name) != null) {
            bmp = self.exactTempCounts(bt, bc);
        } else if (self.findColumnar(bt.name)) |bct| {
            bmp = self.exactCountsCached(bt.name, bct, bc);
        }
        const bm = bmp orelse return null;
        _ = self.ensureColStatQuick(bt, bc);
        if (bc >= bt.stats.len) return null;
        var acc = std.AutoHashMap(i64, f64).init(self.gpa);
        defer acc.deinit();
        var pairs: f64 = 0;
        if (cls.count() <= bm.map.count()) {
            var it = cls.iterator();
            while (it.next()) |e| {
                const cb = bm.map.get(e.key_ptr.*) orelse continue;
                const prod = e.value_ptr.* * @as(f64, @floatFromInt(cb));
                pairs += prod;
                const gop = acc.getOrPut(e.key_ptr.*) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += prod;
            }
        } else {
            var it = bm.map.iterator();
            while (it.next()) |e| {
                const cl = cls.get(e.key_ptr.*) orelse continue;
                const prod = cl * @as(f64, @floatFromInt(e.value_ptr.*));
                pairs += prod;
                const gop = acc.getOrPut(e.key_ptr.*) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += prod;
            }
        }
        if (pairs <= 0) return null;
        var out = KeyDist{};
        out.is_float = bt.cols[bc].ty == .float;
        out.scaled = true;
        out.min = bt.stats[bc].min;
        out.max = bt.stats[bc].max;
        out.rows = pairs;
        for (members) |mem| {
            if (out.nm < out.members.len) {
                out.members[out.nm] = mem;
                out.nm += 1;
            }
        }
        if (out.nm < out.members.len) {
            out.members[out.nm] = .{ .t = bt.name, .c = bc };
            out.nm += 1;
        }
        var it = acc.iterator();
        while (it.next()) |e| pushKeyCand(&out, "", e.key_ptr.*, e.value_ptr.*);
        var explicit_sum: f64 = 0;
        for (out.vals[0..out.n]) |e| explicit_sum += e.c;
        out.res_rows = @max(pairs - explicit_sum, 0.0);
        out.res_ndv = @max(@as(f64, @floatFromInt(bt.stats[bc].ndv)) - @as(f64, @floatFromInt(out.n)), 1.0);
        out.valid = true;
        return .{ .pairs = pairs, .kd = out };
    }

    const TupleEntry = struct { map: std.StringHashMap(u32) };
    const NeighborFan = struct {
        name: []const u8,
        alias: ?[]const u8,
        t: *Table,
        center_cols: [8]usize = @splat(0),
        other_cols: [8]usize = @splat(0),
        ncols: usize = 0,
        tuple: std.StringHashMap(u32) = undefined,
    };

    fn freeNeighborMaps(self: *Engine, list: []NeighborFan) void {
        for (list) |*nf| {
            var it = nf.tuple.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            nf.tuple.deinit();
        }
    }

    /// Star fan-out for multi-key masks: every mask join (with all its equali-
    /// ties) connects the center to one neighbor; each neighbor's rows are
    /// indexed by the exact tuple of join values, so correlated extra keys are
    /// handled exactly (no uniform multiplicity, no 1/max(ndv) factor).
    fn multiKeyStarFanout(
        self: *Engine,
        center_name: []const u8,
        center_alias: ?[]const u8,
        lname: []const u8,
        lalias: ?[]const u8,
        pending: []sql.Join,
        mask: usize,
        m: usize,
        c_new: usize,
        bt: *Table,
        bc: usize,
    ) ?JoinedDist {
        if (std.c.getenv("ZHDB_NO_MASK_FANOUT") != null) return null;
        if (std.c.getenv("ZHDB_NO_SHAPE_FANOUT") != null) return null;
        const t = self.find(center_name) orelse return null;
        const ct = self.findColumnar(t.name) orelse return null;
        if (c_new >= ct.data.len) return null;
        const bct = self.findColumnar(bt.name) orelse return null;
        const bmp = self.exactCountsCached(bt.name, bct, bc) orelse return null;
        _ = self.ensureColStatQuick(bt, bc);
        if (bc >= bt.stats.len) return null;
        var nb: [8]NeighborFan = undefined;
        var nn: usize = 0;
        var kk: usize = 0;
        while (kk < m) : (kk += 1) {
            if (mask & (@as(usize, 1) << @intCast(kk)) == 0) continue;
            const j = pending[kk];
            if (j.on.* != .binary) return null;
            const jt = self.find(j.table) orelse return null;
            // center side / other side for the primary equality
            const tl = colOfSide(t, t.name, center_alias, j.on.binary.lhs);
            const tr = colOfSide(t, t.name, center_alias, j.on.binary.rhs);
            if ((tl != null) == (tr != null)) return null;
            const tside = tl orelse tr.?;
            const other_expr = if (tl != null) j.on.binary.rhs else j.on.binary.lhs;
            // The opposite endpoint may be the joined table itself or the first
            // table (when the center is a later-joined table): resolve by
            // qualifier, like the star fan-out does.
            var oname: []const u8 = j.table;
            var oalias: ?[]const u8 = j.alias;
            var ot: *Table = jt;
            var ocol: ?usize = colOfSide(jt, j.table, j.alias, other_expr);
            if (ocol == null) {
                if (self.find(lname)) |lt0| {
                    if (colOfSide(lt0, lname, lalias, other_expr)) |c| {
                        oname = lname;
                        oalias = lalias;
                        ot = lt0;
                        ocol = c;
                    }
                }
            }
            const orow_col = ocol orelse return null;
            // one NeighborFan per (table, alias)
            var idx: ?usize = null;
            var bi: usize = 0;
            while (bi < nn) : (bi += 1) {
                const same_name = std.ascii.eqlIgnoreCase(nb[bi].name, oname);
                const same_alias = (nb[bi].alias == null and oalias == null) or
                    (nb[bi].alias != null and oalias != null and std.ascii.eqlIgnoreCase(nb[bi].alias.?, oalias.?));
                if (same_name and same_alias) {
                    idx = bi;
                    break;
                }
            }
            if (idx == null) {
                idx = nn;
                nb[nn] = .{ .name = oname, .alias = oalias, .t = ot };
                nb[nn].tuple = std.StringHashMap(u32).init(self.gpa);
                nn += 1;
            }
            const ni = idx.?;
            if (nb[ni].ncols >= 8) return null;
            nb[ni].center_cols[nb[ni].ncols] = tside;
            nb[ni].other_cols[nb[ni].ncols] = orow_col;
            nb[ni].ncols += 1;
            // extra equalities must also connect the same pair
            for (j.extra_eqs) |e| {
                if (e.* != .binary or e.binary.op != .eq) return null;
                const el = colOfSide(t, t.name, center_alias, e.binary.lhs);
                const er = colOfSide(ot, oname, oalias, e.binary.lhs);
                const fl = colOfSide(t, t.name, center_alias, e.binary.rhs);
                const fr = colOfSide(ot, oname, oalias, e.binary.rhs);
                var ccol: ?usize = null;
                var ocol2: ?usize = null;
                if (el != null and fr != null) {
                    ccol = el;
                    ocol2 = fr;
                } else if (fl != null and er != null) {
                    ccol = fl;
                    ocol2 = er;
                }
                if (ccol == null or ocol2 == null) return null;
                if (nb[ni].ncols >= 8) return null;
                nb[ni].center_cols[nb[ni].ncols] = ccol.?;
                nb[ni].other_cols[nb[ni].ncols] = ocol2.?;
                nb[ni].ncols += 1;
            }
            if (nb[ni].t != ot) return null;
        }
        if (nn == 0) return null;
        // Build tuple maps for each neighbor.
        var ok = true;
        for (nb[0..nn]) |*nf| {
            const nct2 = self.findColumnar(nf.name) orelse {
                ok = false;
                break;
            };
            if (nct2.nrows > 2_000_000) {
                ok = false;
                break;
            }
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(self.gpa);
            var ri: usize = 0;
            while (ri < nct2.nrows) : (ri += 1) {
                if (nct2.isDeleted(ri)) continue;
                var any_null = false;
                for (nf.other_cols[0..nf.ncols]) |oc| {
                    if (nct2.isNull(oc, ri)) {
                        any_null = true;
                        break;
                    }
                }
                if (any_null) continue;
                buf.clearRetainingCapacity();
                for (nf.other_cols[0..nf.ncols]) |oc| {
                    if (!self.appendColKey(&buf, nct2, oc, ri, self.gpa)) {
                        ok = false;
                        break;
                    }
                }
                if (!ok) break;
                const gop = nf.tuple.getOrPut(buf.items) catch {
                    ok = false;
                    break;
                };
                if (!gop.found_existing) {
                    gop.key_ptr.* = self.gpa.dupe(u8, buf.items) catch {
                        _ = nf.tuple.remove(buf.items);
                        ok = false;
                        break;
                    };
                    gop.value_ptr.* = 0;
                }
                gop.value_ptr.* += 1;
                if (nf.tuple.count() > 1_000_000) {
                    ok = false;
                    break;
                }
            }
            if (!ok) break;
        }
        if (!ok) {
            self.freeNeighborMaps(nb[0..nn]);
            return null;
        }
        defer self.freeNeighborMaps(nb[0..nn]);
        var out_acc = std.AutoHashMap(i64, f64).init(self.gpa);
        defer out_acc.deinit();
        var pairs: f64 = 0;
        const cn = ct.nrows;
        if (cn > 4_000_000) return null;
        var buf2 = std.ArrayList(u8).empty;
        defer buf2.deinit(self.gpa);
        var ri: usize = 0;
        while (ri < cn) : (ri += 1) {
            if (ct.isDeleted(ri) or ct.isNull(c_new, ri)) continue;
            var w: f64 = 1;
            var bi2: usize = 0;
            while (bi2 < nn) : (bi2 += 1) {
                buf2.clearRetainingCapacity();
                for (nb[bi2].center_cols[0..nb[bi2].ncols]) |cc| {
                    if (ct.isNull(cc, ri)) {
                        w = 0;
                        break;
                    }
                    if (!self.appendColKey(&buf2, ct, cc, ri, self.gpa)) {
                        w = 0;
                        break;
                    }
                }
                if (w == 0) break;
                const c = nb[bi2].tuple.get(buf2.items) orelse {
                    w = 0;
                    break;
                };
                w *= @floatFromInt(c);
            }
            if (w <= 0) continue;
            const nv = numericKeyAt(ct, c_new, ri) orelse continue;
            const cr = bmp.map.get(nv) orelse continue;
            const prod = w * @as(f64, @floatFromInt(cr));
            pairs += prod;
            const gop = out_acc.getOrPut(nv) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += prod;
        }
        if (pairs <= 0) return null;
        var out = KeyDist{};
        out.is_float = bt.cols[bc].ty == .float;
        out.scaled = true;
        out.min = bt.stats[bc].min;
        out.max = bt.stats[bc].max;
        out.rows = pairs;
        out.members[0] = .{ .t = t.name, .c = c_new };
        out.members[1] = .{ .t = bt.name, .c = bc };
        out.nm = 2;
        var it = out_acc.iterator();
        while (it.next()) |e| pushKeyCand(&out, "", e.key_ptr.*, e.value_ptr.*);
        var explicit_sum: f64 = 0;
        for (out.vals[0..out.n]) |e| explicit_sum += e.c;
        out.res_rows = @max(pairs - explicit_sum, 0.0);
        out.res_ndv = @max(@as(f64, @floatFromInt(bt.stats[bc].ndv)) - @as(f64, @floatFromInt(out.n)), 1.0);
        out.valid = true;
        return .{ .pairs = pairs, .kd = out };
    }

    const MFEdge = struct {
        a: usize,
        b: usize,
        pairs: [8][2]usize = undefined,
        np: usize = 0,
    };

    fn mkFreeTupleMap(self: *Engine, map: *std.StringHashMap(u64)) void {
        var it = map.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        map.deinit();
    }

    fn mkFreeMaps(self: *Engine, maps: []std.StringHashMap(u64)) void {
        for (maps) |*mp| self.mkFreeTupleMap(mp);
    }

    /// Tuple-indexed subtree map for multi-key masks: keyed by the node's
    /// columns on the parent join (all equalities, in pair order), valued by the
    /// number of result rows contributed by the subtree under it.
    fn mkTreeMap(
        self: *Engine,
        nodes: []const FNode,
        edges: []const MFEdge,
        adj: *const [9][8]usize,
        adjn: *const [9]usize,
        node: usize,
        parent_e: usize,
        depth: usize,
    ) ?std.StringHashMap(u64) {
        if (depth > 8) return null;
        const ct = nodes[node].ct;
        const n = ct.nrows;
        if (n > 2_000_000) return null;
        const pe = edges[parent_e];
        if (pe.a != node and pe.b != node) return null;
        const pside: usize = if (pe.a == node) 0 else 1;
        var child_maps: [8]std.StringHashMap(u64) = undefined;
        var child_edges: [8]usize = @splat(0);
        var child_n: usize = 0;
        var ai: usize = 0;
        while (ai < adjn[node]) : (ai += 1) {
            const ei = adj[node][ai];
            if (ei == parent_e) continue;
            const ce = edges[ei];
            if (ce.a != node and ce.b != node) return null;
            const child = if (ce.a == node) ce.b else ce.a;
            if (child == node) return null;
            const cm = self.mkTreeMap(nodes, edges, adj, adjn, child, ei, depth + 1) orelse {
                self.mkFreeMaps(child_maps[0..child_n]);
                return null;
            };
            child_maps[child_n] = cm;
            child_edges[child_n] = ei;
            child_n += 1;
        }
        var acc = std.StringHashMap(u64).init(self.gpa);
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.gpa);
        var ri: usize = 0;
        while (ri < n) : (ri += 1) {
            if (ct.isDeleted(ri)) continue;
            var w: u64 = 1;
            var cj: usize = 0;
            while (cj < child_n) : (cj += 1) {
                const ce = edges[child_edges[cj]];
                const cside: usize = if (ce.a == node) 0 else 1;
                buf.clearRetainingCapacity();
                var good = true;
                var pi: usize = 0;
                while (pi < ce.np) : (pi += 1) {
                    const col = ce.pairs[pi][cside];
                    if (ct.isNull(col, ri) or
                        !self.appendColKey(&buf, ct, col, ri, self.gpa))
                    {
                        good = false;
                        break;
                    }
                }
                if (!good) {
                    w = 0;
                    break;
                }
                const c = child_maps[cj].get(buf.items) orelse {
                    w = 0;
                    break;
                };
                w *|= c;
            }
            if (w == 0) continue;
            buf.clearRetainingCapacity();
            var good2 = true;
            var pi2: usize = 0;
            while (pi2 < pe.np) : (pi2 += 1) {
                const col = pe.pairs[pi2][pside];
                if (ct.isNull(col, ri) or
                    !self.appendColKey(&buf, ct, col, ri, self.gpa))
                {
                    good2 = false;
                    break;
                }
            }
            if (!good2) continue;
            const owned = self.gpa.dupe(u8, buf.items) catch {
                self.mkFreeMaps(child_maps[0..child_n]);
                self.mkFreeTupleMap(&acc);
                return null;
            };
            const gop = acc.getOrPut(owned) catch {
                self.gpa.free(owned);
                self.mkFreeMaps(child_maps[0..child_n]);
                self.mkFreeTupleMap(&acc);
                return null;
            };
            if (gop.found_existing) {
                self.gpa.free(owned);
            } else {
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* +|= w;
            if (acc.count() > 1_000_000) {
                self.mkFreeMaps(child_maps[0..child_n]);
                self.mkFreeTupleMap(&acc);
                return null;
            }
        }
        self.mkFreeMaps(child_maps[0..child_n]);
        if (acc.count() == 0) {
            self.mkFreeTupleMap(&acc);
            return null;
        }
        return acc;
    }

    /// Multi-key tree fan-out: like `treeFanoutJoin`, but every edge carries all
    /// of its equality columns (primary ON + `extra_eqs`), so multi-key joins
    /// inside a chained mask (centre -> hub -> branch) are exact too.
    fn multiKeyTreeFanout(
        self: *Engine,
        center_name: []const u8,
        center_alias: ?[]const u8,
        lname: []const u8,
        lalias: ?[]const u8,
        pending: []sql.Join,
        mask: usize,
        m: usize,
        c_new: usize,
        bt: *Table,
        bc: usize,
    ) ?JoinedDist {
        if (std.c.getenv("ZHDB_NO_MASK_FANOUT") != null) return null;
        if (std.c.getenv("ZHDB_NO_SHAPE_FANOUT") != null) return null;
        var nodes: [9]FNode = undefined;
        var nn: usize = 0;
        const lt0 = self.find(lname) orelse return null;
        const lct0 = self.findColumnar(lname) orelse return null;
        nodes[nn] = .{ .name = lname, .alias = lalias, .t = lt0, .ct = lct0 };
        nn += 1;
        var kk: usize = 0;
        while (kk < m) : (kk += 1) {
            if (mask & (@as(usize, 1) << @intCast(kk)) == 0) continue;
            const nm = pending[kk].table;
            if (nn >= nodes.len) return null;
            const nt = self.find(nm) orelse return null;
            const nct = self.findColumnar(nm) orelse return null;
            nodes[nn] = .{ .name = nm, .alias = pending[kk].alias, .t = nt, .ct = nct };
            nn += 1;
        }
        var ci: ?usize = null;
        for (nodes[0..nn], 0..) |nd, i| {
            if (!std.ascii.eqlIgnoreCase(nd.name, center_name)) continue;
            const amatch = (nd.alias == null and center_alias == null) or
                (nd.alias != null and center_alias != null and std.ascii.eqlIgnoreCase(nd.alias.?, center_alias.?));
            if (amatch) {
                if (ci != null) return null;
                ci = i;
            }
        }
        const cidx = ci orelse return null;
        var edges: [8]MFEdge = undefined;
        var ne: usize = 0;
        var adj: [9][8]usize = @splat(@splat(0));
        var adjn: [9]usize = @splat(0);
        kk = 0;
        while (kk < m) : (kk += 1) {
            if (mask & (@as(usize, 1) << @intCast(kk)) == 0) continue;
            const j = pending[kk];
            if (j.on.* != .binary) return null;
            const la = fanResolveNode(nodes[0..nn], j.on.binary.lhs) orelse return null;
            const rb = fanResolveNode(nodes[0..nn], j.on.binary.rhs) orelse return null;
            if (la.idx == rb.idx) return null;
            if (ne >= edges.len) return null;
            edges[ne] = .{ .a = la.idx, .b = rb.idx };
            edges[ne].pairs[0] = .{ la.col, rb.col };
            edges[ne].np = 1;
            for (j.extra_eqs) |e| {
                if (e.* != .binary or e.binary.op != .eq) return null;
                const xa = fanResolveNode(nodes[0..nn], e.binary.lhs) orelse return null;
                const xb = fanResolveNode(nodes[0..nn], e.binary.rhs) orelse return null;
                var ca: usize = undefined;
                var cb2: usize = undefined;
                if (xa.idx == edges[ne].a and xb.idx == edges[ne].b) {
                    ca = xa.col;
                    cb2 = xb.col;
                } else if (xa.idx == edges[ne].b and xb.idx == edges[ne].a) {
                    ca = xb.col;
                    cb2 = xa.col;
                } else return null;
                if (edges[ne].np >= 8) return null;
                edges[ne].pairs[edges[ne].np] = .{ ca, cb2 };
                edges[ne].np += 1;
            }
            if (adjn[la.idx] < 8) {
                adj[la.idx][adjn[la.idx]] = ne;
                adjn[la.idx] += 1;
            }
            if (adjn[rb.idx] < 8) {
                adj[rb.idx][adjn[rb.idx]] = ne;
                adjn[rb.idx] += 1;
            }
            ne += 1;
        }
        const ct = nodes[cidx].ct;
        if (c_new >= ct.data.len) return null;
        const bct = self.findColumnar(bt.name) orelse return null;
        const bmp = self.exactCountsCached(bt.name, bct, bc) orelse return null;
        _ = self.ensureColStatQuick(bt, bc);
        if (bc >= bt.stats.len) return null;
        if (ct.nrows > 2_000_000) return null;
        var root_maps: [8]std.StringHashMap(u64) = undefined;
        var root_edges: [8]usize = @splat(0);
        var root_n: usize = 0;
        var ai: usize = 0;
        while (ai < adjn[cidx]) : (ai += 1) {
            const ei = adj[cidx][ai];
            const ce = edges[ei];
            const child = if (ce.a == cidx) ce.b else ce.a;
            const cm = self.mkTreeMap(nodes[0..nn], edges[0..], &adj, &adjn, child, ei, 1) orelse {
                self.mkFreeMaps(root_maps[0..root_n]);
                return null;
            };
            root_maps[root_n] = cm;
            root_edges[root_n] = ei;
            root_n += 1;
        }
        defer self.mkFreeMaps(root_maps[0..root_n]);
        var out_acc = std.AutoHashMap(i64, f64).init(self.gpa);
        defer out_acc.deinit();
        var pairs: f64 = 0;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.gpa);
        const cn = ct.nrows;
        var ri: usize = 0;
        while (ri < cn) : (ri += 1) {
            if (ct.isDeleted(ri) or ct.isNull(c_new, ri)) continue;
            var w: u64 = 1;
            var cj: usize = 0;
            while (cj < root_n) : (cj += 1) {
                const ce = edges[root_edges[cj]];
                const cside: usize = if (ce.a == cidx) 0 else 1;
                buf.clearRetainingCapacity();
                var good = true;
                var pi: usize = 0;
                while (pi < ce.np) : (pi += 1) {
                    const col = ce.pairs[pi][cside];
                    if (ct.isNull(col, ri) or
                        !self.appendColKey(&buf, ct, col, ri, self.gpa))
                    {
                        good = false;
                        break;
                    }
                }
                if (!good) {
                    w = 0;
                    break;
                }
                const c = root_maps[cj].get(buf.items) orelse {
                    w = 0;
                    break;
                };
                w *|= c;
            }
            if (w == 0) continue;
            const nv = numericKeyAt(ct, c_new, ri) orelse continue;
            const cr = bmp.map.get(nv) orelse continue;
            const prod = @as(f64, @floatFromInt(w)) * @as(f64, @floatFromInt(cr));
            pairs += prod;
            const gop = out_acc.getOrPut(nv) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += prod;
        }
        if (pairs <= 0) return null;
        var out = KeyDist{};
        out.is_float = bt.cols[bc].ty == .float;
        out.scaled = true;
        out.min = bt.stats[bc].min;
        out.max = bt.stats[bc].max;
        out.rows = pairs;
        out.members[0] = .{ .t = nodes[cidx].name, .c = c_new };
        out.members[1] = .{ .t = bt.name, .c = bc };
        out.nm = 2;
        var it = out_acc.iterator();
        while (it.next()) |e| pushKeyCand(&out, "", e.key_ptr.*, e.value_ptr.*);
        var explicit_sum: f64 = 0;
        for (out.vals[0..out.n]) |e| explicit_sum += e.c;
        out.res_rows = @max(pairs - explicit_sum, 0.0);
        out.res_ndv = @max(@as(f64, @floatFromInt(bt.stats[bc].ndv)) - @as(f64, @floatFromInt(out.n)), 1.0);
        out.valid = true;
        return .{ .pairs = pairs, .kd = out };
    }

    /// Pair count between the intermediate's switched column and a base table
    /// column, computed from the base rows weighted by each row's per-key
    /// fan-out (exact for encoded columns), together with the joined key
    /// distribution (top-48 + residual) for later steps. This avoids losing the
    /// hot/cold split through the intermediate's 48-entry sketch.
    fn switchedJoinPairs(
        self: *Engine,
        t: *Table,
        members: []const KeyMember,
        c_anchor: usize,
        c_new: usize,
        bt: *Table,
        bc: usize,
    ) ?JoinedDist {
        if (std.c.getenv("ZHDB_NO_CLASS_FANOUT") != null) return null;
        const ct = self.findColumnar(t.name) orelse return null;
        if (self.findColumnar(bt.name) == null) return null;
        if (c_anchor >= ct.data.len or c_new >= ct.data.len) return null;
        const cntp = self.exactCountsCached(t.name, ct, c_anchor) orelse return null;
        const bct = self.findColumnar(bt.name).?;
        const bmp = self.exactCountsCached(bt.name, bct, bc) orelse return null;
        _ = self.ensureColStatQuick(bt, bc);
        if (bc >= bt.stats.len or bt.stats[bc].ndv == 0) return null;
        var cls = std.AutoHashMap(i64, f64).init(self.gpa);
        defer cls.deinit();
        if (!self.classCountsInto(members, &cls)) return null;
        const n = ct.nrows;
        if (n == 0) return null;
        var acc = std.AutoHashMap(i64, f64).init(self.gpa);
        defer acc.deinit();
        var pairs: f64 = 0;
        const handle_row = struct {
            fn f(
                eng: *Engine,
                acc2: *std.AutoHashMap(i64, f64),
                pairs2: *f64,
                counts2: *const std.AutoHashMap(i64, u32),
                bm2: *const std.AutoHashMap(i64, u32),
                cls2: *const std.AutoHashMap(i64, f64),
                va: i64,
                vn: i64,
                wscale: f64,
            ) void {
                const tcnt = @as(f64, @floatFromInt(counts2.get(va) orelse return));
                if (tcnt <= 0) return;
                const cr = @as(f64, @floatFromInt(bm2.get(vn) orelse return));
                if (cr <= 0) return;
                const kcnt = cls2.get(va) orelse return;
                const w = (kcnt / tcnt) * wscale;
                if (w <= 0) return;
                const prod = w * cr;
                pairs2.* += prod;
                const gop = acc2.getOrPut(vn) catch return;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += prod;
                _ = eng;
            }
        }.f;
        var exact_done = false;
        if (std.c.getenv("ZHDB_FAN_SAMPLE") == null and n <= 8_000_000 and
            c_anchor < ct.enc.len and c_new < ct.enc.len and
            ct.enc[c_anchor] != null and ct.enc[c_new] != null)
        {
            const ea = ct.enc[c_anchor].?;
            const en = ct.enc[c_new].?;
            if (ea.ids.len >= n and en.ids.len >= n) {
                var ri: usize = 0;
                while (ri < n) : (ri += 1) {
                    if (ct.isDeleted(ri) or ct.isNull(c_anchor, ri) or ct.isNull(c_new, ri)) continue;
                    const ia = ea.ids[ri];
                    const inw = en.ids[ri];
                    if (ia < 0 or inw < 0) continue;
                    const va = numericKeyAt(ct, c_anchor, @intCast(ia)) orelse continue;
                    const vn = numericKeyAt(ct, c_new, @intCast(inw)) orelse continue;
                    handle_row(self, &acc, &pairs, &cntp.map, &bmp.map, &cls, va, vn, 1.0);
                }
                exact_done = true;
            }
        }
        if (!exact_done) {
            var step: usize = if (n <= 262_144) 1 else @max(1, n / 20000);
            if (step > 1 and step % 2 == 0) step += 1;
            const scale: f64 = if (step > 1) @floatFromInt(step) else 1.0;
            var ri: usize = 0;
            while (ri < n) : (ri += step) {
                if (ct.isDeleted(ri) or ct.isNull(c_anchor, ri) or ct.isNull(c_new, ri)) continue;
                const va = numericKeyAt(ct, c_anchor, ri) orelse continue;
                const vn = numericKeyAt(ct, c_new, ri) orelse continue;
                handle_row(self, &acc, &pairs, &cntp.map, &bmp.map, &cls, va, vn, scale);
            }
        }
        if (pairs <= 0) return null;
        var out = KeyDist{};
        out.is_float = bt.cols[bc].ty == .float;
        out.scaled = true;
        out.min = bt.stats[bc].min;
        out.max = bt.stats[bc].max;
        out.rows = pairs;
        out.members[0] = .{ .t = t.name, .c = c_new };
        out.members[1] = .{ .t = bt.name, .c = bc };
        out.nm = 2;
        var it = acc.iterator();
        while (it.next()) |e| pushKeyCand(&out, "", e.key_ptr.*, e.value_ptr.*);
        var explicit_sum: f64 = 0;
        for (out.vals[0..out.n]) |e| explicit_sum += e.c;
        out.res_rows = @max(pairs - explicit_sum, 0.0);
        out.res_ndv = @max(@as(f64, @floatFromInt(bt.stats[bc].ndv)) - @as(f64, @floatFromInt(out.n)), 1.0);
        out.valid = true;
        return .{ .pairs = pairs, .kd = out };
    }

    /// Pair count and joined key distribution between a (possibly scaled)
    /// intermediate key distribution and an exact base-table column: iterate the
    /// base encoding's values, evaluating the intermediate's count per value
    /// (explicit entries, else the residual density). Exact for base tables with
    /// a dictionary encoding, and immune to top-16-MCV truncation on the new side.
    fn joinDistWithBase(self: *Engine, dist: KeyDist, t: *Table, c: usize) ?JoinedDist {
        const ct = self.findColumnar(t.name) orelse return null;
        if (c >= ct.data.len) return null;
        const counts = self.exactCountsCached(t.name, ct, c) orelse return null;
        _ = self.ensureColStatQuick(t, c);
        if (c >= t.stats.len) return null;
        var ex = std.AutoHashMap(i64, f64).init(self.gpa);
        defer ex.deinit();
        for (dist.vals[0..dist.n]) |e| ex.put(e.v, e.c) catch {};
        const res_density = if (dist.res_ndv > 0) dist.res_rows / dist.res_ndv else 0;
        var out = KeyDist{};
        out.is_float = dist.is_float;
        out.scaled = dist.scaled;
        out.min = t.stats[c].min;
        out.max = t.stats[c].max;
        for (dist.members[0..dist.nm]) |mem| {
            if (out.nm < out.members.len) {
                out.members[out.nm] = mem;
                out.nm += 1;
            }
        }
        if (out.nm < out.members.len) {
            out.members[out.nm] = .{ .t = t.name, .c = c };
            out.nm += 1;
        }
        var total: f64 = 0;
        var it = counts.map.iterator();
        while (it.next()) |e| {
            const v = e.key_ptr.*;
            const cr = @as(f64, @floatFromInt(e.value_ptr.*));
            var cl = ex.get(v) orelse 0;
            if (cl == 0 and v >= dist.min and v <= dist.max) cl = res_density;
            if (cl <= 0) continue;
            const prod = cl * cr;
            total += prod;
            pushKeyCand(&out, "", v, prod);
        }
        out.rows = total;
        var explicit_sum: f64 = 0;
        for (out.vals[0..out.n]) |e| explicit_sum += e.c;
        out.res_rows = @max(total - explicit_sum, 0.0);
        out.res_ndv = @max(@as(f64, @floatFromInt(t.stats[c].ndv)) - @as(f64, @floatFromInt(out.n)), 1.0);
        out.valid = true;
        return .{ .pairs = total, .kd = out };
    }

    /// Exact key distribution of an equi-join between two base tables that both
    /// carry dictionary encodings: `count(v) = count_l(v)·count_r(v)`, keeping
    /// the 48 largest values explicitly plus the residual mass.
    fn exactJoinedDist(self: *Engine, lt: *Table, lc: usize, rt: *Table, rc: usize) ?KeyDist {
        const lct = self.findColumnar(lt.name) orelse return null;
        const rct = self.findColumnar(rt.name) orelse return null;
        const lmp = self.exactCountsCached(lt.name, lct, lc) orelse return null;
        const rmp = self.exactCountsCached(rt.name, rct, rc) orelse return null;
        _ = self.ensureColStatQuick(lt, lc);
        _ = self.ensureColStatQuick(rt, rc);
        if (lc >= lt.stats.len or rc >= rt.stats.len) return null;
        var out = KeyDist{};
        out.min = @max(lt.stats[lc].min, rt.stats[rc].min);
        out.max = @min(lt.stats[lc].max, rt.stats[rc].max);
        if (out.min > out.max) {
            out.valid = true;
            out.rows = 0;
            out.res_rows = 0;
            out.res_ndv = 1;
            return out;
        }
        var total: f64 = 0;
        var common: usize = 0;
        if (lmp.map.count() <= rmp.map.count()) {
            var it = lmp.map.iterator();
            while (it.next()) |e| {
                const c2 = rmp.map.get(e.key_ptr.*) orelse continue;
                const prod = @as(f64, @floatFromInt(e.value_ptr.*)) * @as(f64, @floatFromInt(c2));
                total += prod;
                common += 1;
                pushKeyCand(&out, "", e.key_ptr.*, prod);
            }
        } else {
            var it = rmp.map.iterator();
            while (it.next()) |e| {
                const c1 = lmp.map.get(e.key_ptr.*) orelse continue;
                const prod = @as(f64, @floatFromInt(e.value_ptr.*)) * @as(f64, @floatFromInt(c1));
                total += prod;
                common += 1;
                pushKeyCand(&out, "", e.key_ptr.*, prod);
            }
        }
        out.rows = total;
        var explicit_sum: f64 = 0;
        for (out.vals[0..out.n]) |e| explicit_sum += e.c;
        out.res_rows = @max(total - explicit_sum, 0.0);
        out.res_ndv = @max(@as(f64, @floatFromInt(common)) - @as(f64, @floatFromInt(out.n)), 1.0);
        out.members[0] = .{ .t = lt.name, .c = lc };
        out.members[1] = .{ .t = rt.name, .c = rc };
        out.nm = 2;
        out.valid = true;
        return out;
    }

    /// Cached exact per-value counts for any numeric column (dictionary
    /// encoding when available, else a bounded scan of the columnar image).
    /// Shares the float-count cache, which is invalidated on DML/rebuild.
    fn exactCountsCached(self: *Engine, name: []const u8, ct: *columnar.Table, ci: usize) ?*FloatCountEntry {
        if (ci >= ct.data.len) return null;
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\t{d}", .{ name, ci }) catch return null;
        if (self.float_counts.getPtr(key)) |e| return e;
        var m = std.AutoHashMap(i64, u32).init(self.gpa);
        var ok_all = true;
        if (ci < ct.enc.len and ct.enc[ci] != null) {
            const e = ct.enc[ci].?;
            if (e.counts.len != e.first.len) return null;
            for (e.first, 0..) |row, id| {
                const val = numericKeyAt(ct, ci, row) orelse {
                    ok_all = false;
                    break;
                };
                m.put(val, e.counts[id]) catch {
                    ok_all = false;
                    break;
                };
            }
        } else {
            const n = ct.nrows;
            if (n == 0 or n > 2_000_000) return null;
            var ri: usize = 0;
            while (ri < n) : (ri += 1) {
                if (ct.isDeleted(ri) or ct.isNull(ci, ri)) continue;
                const val: i64 = switch (ct.data[ci]) {
                    .ints => |v| v[ri],
                    .floats => |v| if (std.math.isNan(v[ri])) continue else f64Key(v[ri]),
                    else => return null,
                };
                const gop = m.getOrPut(val) catch {
                    ok_all = false;
                    break;
                };
                if (!gop.found_existing) {
                    if (m.count() > 1_000_000) {
                        ok_all = false;
                        break;
                    }
                    gop.value_ptr.* = 0;
                }
                gop.value_ptr.* += 1;
            }
        }
        if (!ok_all) {
            m.deinit();
            return null;
        }
        const owned = self.gpa.dupe(u8, key) catch {
            m.deinit();
            return null;
        };
        self.float_counts.put(owned, .{ .map = m }) catch {
            self.gpa.free(owned);
            m.deinit();
            return null;
        };
        return self.float_counts.getPtr(owned);
    }

    /// Exact per-value counts of a materialised join intermediate's column
    /// (cached; bounded to 2M rows / 1M distinct values). Returns null for base
    /// tables (their encodings are used instead) or oversized temps.
    fn exactTempCounts(self: *Engine, t: *Table, ci: usize) ?*FloatCountEntry {
        if (ci >= t.cols.len) return null;
        if (self.tempTables().get(t.name) == null) return null;
        const n = t.rows.items.len;
        if (n == 0 or n > 2_000_000) return null;
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\t{d}", .{ t.name, ci }) catch return null;
        if (self.temp_counts.getPtr(key)) |e| return e;
        var m = std.AutoHashMap(i64, u32).init(self.gpa);
        var ri: usize = 0;
        while (ri < n) : (ri += 1) {
            const v = t.rows.items[ri][ci];
            const k: i64 = switch (v) {
                .int => |x| x,
                .boolean => |b| @intFromBool(b),
                .float => |f| if (std.math.isNan(f)) continue else f64Key(f),
                else => continue,
            };
            const gop = m.getOrPut(k) catch {
                m.deinit();
                return null;
            };
            if (!gop.found_existing) {
                if (m.count() > 1_000_000) {
                    m.deinit();
                    return null;
                }
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
        }
        const owned = self.gpa.dupe(u8, key) catch {
            m.deinit();
            return null;
        };
        self.temp_counts.put(owned, .{ .map = m }) catch {
            self.gpa.free(owned);
            m.deinit();
            return null;
        };
        return self.temp_counts.getPtr(owned);
    }

    /// Distribution of `c_new` in a partial join, given that the intermediate
    /// repeats each row of `t` by its per-key fan-out on `c_anchor` (tracked by
    /// `kd`). Uses the exact (or, for large tables, strided-sampled) base rows
    /// to weight each row by its fan-out, so skewed fan-out is handled without
    /// the uniform-multiplicity assumption.
    fn switchedKeyDist(self: *Engine, t: *Table, kd: KeyDist, c_anchor: usize, c_new: usize) ?KeyDist {
        if (c_anchor >= t.cols.len or c_new >= t.cols.len) return null;
        const ct = self.findColumnar(t.name) orelse return null;
        if (c_anchor >= ct.data.len or c_new >= ct.data.len) return null;
        _ = self.ensureColStatQuick(t, c_new);
        if (c_new >= t.stats.len or t.stats[c_new].ndv == 0) return null;
        var counts = self.encValueCounts(ct, c_anchor) orelse return null;
        defer counts.deinit();
        const n = ct.nrows;
        if (n == 0) return null;
        const res_per_val = if (kd.res_ndv > 0) kd.res_rows / kd.res_ndv else 0;
        var weights = std.AutoHashMap(i64, f64).init(self.gpa);
        defer weights.deinit();
        // Exact joint over the base rows when both columns carry dictionary
        // encodings (no sampling noise) and the table is within the work budget.
        var exact_done = false;
        if (std.c.getenv("ZHDB_FAN_SAMPLE") == null and n <= 8_000_000 and
            c_anchor < ct.enc.len and c_new < ct.enc.len and
            ct.enc[c_anchor] != null and ct.enc[c_new] != null)
        {
            const ea = ct.enc[c_anchor].?;
            const en = ct.enc[c_new].?;
            if (ea.ids.len >= n and en.ids.len >= n and
                ea.counts.len == ea.first.len and en.counts.len == en.first.len)
            {
                const fans = self.gpa.alloc(f64, ea.first.len) catch null;
                if (fans) |fo| {
                    defer self.gpa.free(fo);
                    for (ea.first, 0..) |row, id| {
                        const val = numericKeyAt(ct, c_anchor, row) orelse {
                            fo[id] = 0;
                            continue;
                        };
                        const base = @as(f64, @floatFromInt(ea.counts[id]));
                        var kcnt: f64 = res_per_val;
                        for (kd.vals[0..kd.n]) |e| {
                            if (e.v == val) {
                                kcnt = e.c;
                                break;
                            }
                        }
                        fo[id] = if (base > 0) kcnt / base else 0;
                    }
                    var ri: usize = 0;
                    while (ri < n) : (ri += 1) {
                        if (ct.isDeleted(ri) or ct.isNull(c_anchor, ri) or ct.isNull(c_new, ri)) continue;
                        const ia = ea.ids[ri];
                        const inw = en.ids[ri];
                        if (ia < 0 or inw < 0) continue;
                        const aie: usize = @intCast(ia);
                        const nie: usize = @intCast(inw);
                        if (aie >= fo.len or nie >= en.first.len) continue;
                        const w = fo[aie];
                        if (w <= 0) continue;
                        const val = numericKeyAt(ct, c_new, en.first[nie]) orelse continue;
                        const gop = weights.getOrPut(val) catch continue;
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += w;
                    }
                    exact_done = true;
                }
            }
        }
        if (!exact_done) {
            var step: usize = if (n <= 262_144) 1 else @max(1, n / 20000);
            if (step > 1 and step % 2 == 0) step += 1;
            var ri: usize = 0;
            while (ri < n) : (ri += step) {
                if (ct.isDeleted(ri) or ct.isNull(c_anchor, ri) or ct.isNull(c_new, ri)) continue;
                const va = numericKeyAt(ct, c_anchor, ri) orelse continue;
                const vn = numericKeyAt(ct, c_new, ri) orelse continue;
                const tcnt = counts.get(va) orelse continue;
                if (tcnt <= 0) continue;
                var kcnt: f64 = 0;
                var found = false;
                for (kd.vals[0..kd.n]) |e| {
                    if (e.v == va) {
                        kcnt = e.c;
                        found = true;
                        break;
                    }
                }
                if (!found) kcnt = res_per_val;
                const w = (kcnt / tcnt) * (if (step > 1) @as(f64, @floatFromInt(step)) else 1.0);
                if (w <= 0) continue;
                const gop = weights.getOrPut(vn) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += w;
            }
        }
        if (weights.count() == 0) return null;
        var out = KeyDist{};
        out.is_float = t.cols[c_new].ty == .float;
        out.min = t.stats[c_new].min;
        out.max = t.stats[c_new].max;
        out.rows = kd.rows;
        out.scaled = true;
        out.members[0] = .{ .t = t.name, .c = c_new };
        out.nm = 1;
        var total_w: f64 = 0;
        var it = weights.iterator();
        while (it.next()) |e| {
            total_w += e.value_ptr.*;
            pushKeyCand(&out, "", e.key_ptr.*, e.value_ptr.*);
        }
        if (total_w <= 0) return null;
        // Explicit entries are the largest weights; the remainder is residual.
        var explicit_sum: f64 = 0;
        for (out.vals[0..out.n]) |e| explicit_sum += e.c;
        out.res_rows = @max(kd.rows - explicit_sum, 0.0);
        out.res_ndv = @max(@as(f64, @floatFromInt(t.stats[c_new].ndv)) - @as(f64, @floatFromInt(out.n)), 1.0);
        out.valid = true;
        return out;
    }

    /// Key distribution of a (filtered) base table column, from ANALYZE stats or
    /// the quick columnar stats. Supports integer and string keys; float keys
    /// return `.valid = false` so the caller falls back.
    fn baseKeyDist(self: *Engine, tname: []const u8, ci: usize, sel: f64) KeyDist {
        var d = KeyDist{};
        const t = self.find(tname) orelse return d;
        if (ci >= t.cols.len) return d;
        const is_str = t.cols[ci].ty == .text or t.cols[ci].ty == .date or t.cols[ci].ty == .timestamp;
        if (!is_str) switch (t.cols[ci].ty) {
            .int, .boolean, .float => {},
            else => return d,
        };
        _ = self.ensureColStatQuick(t, ci);
        if (ci >= t.stats.len or t.stats[ci].ndv == 0) return d;
        const st = t.stats[ci];
        const rows = @as(f64, @floatFromInt(t.rows.items.len)) * std.math.clamp(sel, 0.0, 1.0);
        if (rows <= 0) return d;
        d.rows = rows;
        d.is_str = is_str;
        d.is_float = t.cols[ci].ty == .float;
        d.members[0] = .{ .t = tname, .c = ci };
        d.nm = 1;
        if (!is_str) {
            d.min = st.min;
            d.max = st.max;
            var mass: f64 = 0;
            for (st.mcv) |e| {
                if (d.n < d.vals.len) {
                    d.vals[d.n] = .{ .v = e.v, .c = e.freq * rows };
                    d.n += 1;
                }
                mass += e.freq;
            }
            d.res_rows = @max(rows * (1.0 - @min(mass, 1.0)), 0.0);
            d.res_ndv = @max(@as(f64, @floatFromInt(st.ndv)) - @as(f64, @floatFromInt(st.mcv.len)), 1.0);
            d.valid = true;
            return d;
        }
        // String keys: prefer the exact dictionary (per-value counts), else the
        // top-16 MCV frequencies. Keep the 48 largest counts; everything else
        // is residual (its mass is what the kept entries do **not** cover).
        var any_val: []const u8 = &.{};
        var smin: []const u8 = st.min_str;
        var smax: []const u8 = st.max_str;
        if (st.dict.len > 0) {
            const scale: f64 = if (st.dict_sampled and st.dict_sample_rows > 0)
                @as(f64, @floatFromInt(t.rows.items.len)) / @as(f64, @floatFromInt(st.dict_sample_rows))
            else
                1.0;
            for (st.dict) |e| {
                const c = @as(f64, @floatFromInt(e.count)) * scale * std.math.clamp(sel, 0.0, 1.0);
                if (c <= 0) continue;
                if (any_val.len == 0) any_val = e.s;
                if (smin.len == 0 or std.mem.order(u8, e.s, smin) == .lt) smin = e.s;
                if (smax.len == 0 or std.mem.order(u8, e.s, smax) == .gt) smax = e.s;
                pushKeyCand(&d, e.s, 0, c);
            }
        } else {
            for (st.mcv_str) |e| {
                const c = e.freq * rows;
                if (c <= 0) continue;
                if (any_val.len == 0) any_val = e.s;
                if (smin.len == 0 or std.mem.order(u8, e.s, smin) == .lt) smin = e.s;
                if (smax.len == 0 or std.mem.order(u8, e.s, smax) == .gt) smax = e.s;
                pushKeyCand(&d, e.s, 0, c);
            }
        }
        if (d.n == 0) return d;
        if (smin.len == 0) smin = any_val;
        if (smax.len == 0) smax = any_val;
        d.kmin = distStrKey(smin);
        d.kmax = distStrKey(smax);
        var kept: f64 = 0;
        for (d.vals[0..d.n]) |e| kept += e.c;
        d.res_rows = @max(rows - kept, 0.0);
        d.res_ndv = @max(@as(f64, @floatFromInt(st.ndv)) - @as(f64, @floatFromInt(d.n)), 1.0);
        d.valid = true;
        return d;
    }

    /// Estimated matched pairs for an equi-join from per-key frequency stats:
    /// `Σ_{v∈MCV_l∩MCV_r} f_l(v)·f_r(v)` plus a residual term
    /// `rest_l·rest_r/max(rest_ndv_l, rest_ndv_r)`, scaled by `rows_l·rows_r`.
    /// Works for materialised intermediates (which carry sampled MCV/ndv) and
    /// for base tables with ANALYZE / quick columnar stats.
    fn estimateJoinPairs(self: *Engine, lt: *Table, lc: usize, rt: *Table, rc: usize) ?f64 {
        const lrows = lt.rows.items.len;
        const rrows = rt.rows.items.len;
        if (lrows == 0 or rrows == 0) return null;
        if (lc >= lt.cols.len or rc >= rt.cols.len) return null;
        _ = self.ensureColStatQuick(lt, lc);
        _ = self.ensureColStatQuick(rt, rc);
        if (lc >= lt.stats.len or rc >= rt.stats.len) return null;
        const lst = lt.stats[lc];
        const rst = rt.stats[rc];
        if (lst.ndv == 0 or rst.ndv == 0) return null;
        const l_is_str = lt.cols[lc].ty == .text or lt.cols[lc].ty == .date or lt.cols[lc].ty == .timestamp;
        const r_is_str = rt.cols[rc].ty == .text or rt.cols[rc].ty == .date or rt.cols[rc].ty == .timestamp;
        if (l_is_str != r_is_str) return null;
        // String stats driven by value lists, scaled from sample counts
        // (Horvitz–Thompson; 1.0 for a full scan).
        if (l_is_str and r_is_str and lst.dict_sampled and rst.dict_sampled and
            colStatFullScan(lst, lt) and colStatFullScan(rst, rt))
        {
            const sa = statScale(lst, lt);
            const sb = statScale(rst, rt);
            if (self.cdfPairs(lst, rst, null, null, sa, sb)) |pairs| {
                if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                    std.debug.print("[plan] join cdf-exact-unfiltered pairs={d:.0} scale={d:.2}/{d:.2}\n", .{ pairs, sa, sb });
                }
                return pairs;
            }
        }
        // Exact equality-join cardinality when both sides have an exact value
        // dictionary (ndv <= 65,536): `Σ count_l(v)·count_r(v)`. This is exact
        // for duplicate-key string chains and needs no range approximation.
        if (l_is_str and lst.dict.len > 0 and rst.dict.len > 0 and
            !lst.dict_sampled and !rst.dict_sampled)
        {
            var pairs: f64 = 0;
            var map = std.StringHashMap(u32).init(self.gpa);
            defer map.deinit();
            if (lst.dict.len <= rst.dict.len) {
                for (rst.dict) |e| map.put(e.s, e.count) catch return null;
                for (lst.dict) |a| {
                    if (map.get(a.s)) |cr| {
                        pairs += @as(f64, @floatFromInt(a.count)) * @as(f64, @floatFromInt(cr));
                    }
                }
            } else {
                for (lst.dict) |e| map.put(e.s, e.count) catch return null;
                for (rst.dict) |a| {
                    if (map.get(a.s)) |cl| {
                        pairs += @as(f64, @floatFromInt(a.count)) * @as(f64, @floatFromInt(cl));
                    }
                }
            }
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[plan] join dict-exact ldict={d} rdict={d} -> {d:.0}\n", .{
                    lst.dict.len, rst.dict.len, pairs,
                });
            }
            return pairs;
        }
        // Exact per-value join from cached value counts (encoding or bounded
        // column scan) whenever both numeric columns have them.
        if (!l_is_str and !r_is_str) {
            const lct0 = self.findColumnar(lt.name);
            const rct0 = self.findColumnar(rt.name);
            if (lct0 != null and rct0 != null) {
                if (self.exactCountsCached(lt.name, lct0.?, lc)) |lm| {
                    if (self.exactCountsCached(rt.name, rct0.?, rc)) |rm| {
                        var pairs: f64 = 0;
                        if (lm.map.count() <= rm.map.count()) {
                            var it = lm.map.iterator();
                            while (it.next()) |e| {
                                const cr = rm.map.get(e.key_ptr.*) orelse continue;
                                pairs += @as(f64, @floatFromInt(e.value_ptr.*)) * @as(f64, @floatFromInt(cr));
                            }
                        } else {
                            var it = rm.map.iterator();
                            while (it.next()) |e| {
                                const cl = lm.map.get(e.key_ptr.*) orelse continue;
                                pairs += @as(f64, @floatFromInt(e.value_ptr.*)) * @as(f64, @floatFromInt(cl));
                            }
                        }
                        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                            std.debug.print("[plan] join val-exact {s}.c{d} x {s}.c{d} -> {d:.0}\n", .{
                                lt.name, lc, rt.name, rc, pairs,
                            });
                        }
                        return pairs;
                    }
                }
            }
        }
        // Numeric keys where one side is a materialised intermediate: the temp
        // column's exact per-value counts joined against the base encoding make
        // the chain step estimate exact (no sampled temp statistics).
        if (!l_is_str and !r_is_str and std.c.getenv("ZHDB_NO_TEMP_EXACT") == null) {
            const lt_temp = self.tempTables().get(lt.name) != null;
            const rt_temp = self.tempTables().get(rt.name) != null;
            if (lt_temp != rt_temp) {
                const tt = if (lt_temp) lt else rt;
                const tc = if (lt_temp) lc else rc;
                const bt = if (lt_temp) rt else lt;
                const bc = if (lt_temp) rc else lc;
                if (self.exactTempCounts(tt, tc)) |tm| {
                    if (self.findColumnar(bt.name)) |bct| {
                        if (bc < bct.enc.len and bct.enc[bc] != null) {
                            if (self.encValueCounts(bct, bc)) |bm0| {
                                var bm = bm0;
                                defer bm.deinit();
                                var pairs: f64 = 0;
                                if (tm.map.count() <= bm.count()) {
                                    var it = tm.map.iterator();
                                    while (it.next()) |e| {
                                        const cb = bm.get(e.key_ptr.*) orelse continue;
                                        pairs += @as(f64, @floatFromInt(e.value_ptr.*)) * cb;
                                    }
                                } else {
                                    var it = bm.iterator();
                                    while (it.next()) |e| {
                                        const ct2 = tm.map.get(e.key_ptr.*) orelse continue;
                                        pairs += @as(f64, @floatFromInt(ct2)) * e.value_ptr.*;
                                    }
                                }
                                if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                                    std.debug.print("[plan] join temp-exact temp={s}.c{d} base={s}.c{d} -> {d:.0}\n", .{
                                        tt.name, tc, bt.name, bc, pairs,
                                    });
                                }
                                return pairs;
                            }
                        }
                    }
                }
            }
        }
        // Numeric keys: exact equality-join cardinality from the columnar
        // dictionary encodings (per-value row counts), when both sides carry one.
        if (!l_is_str and !r_is_str) {
            if (self.findColumnar(lt.name)) |lct| {
                if (self.findColumnar(rt.name)) |rct| {
                    if (lc < lct.enc.len and rc < rct.enc.len and
                        lct.enc[lc] != null and rct.enc[rc] != null)
                    {
                        const le = lct.enc[lc].?;
                        const re = rct.enc[rc].?;
                        if (le.counts.len == le.first.len and re.counts.len == re.first.len and
                            le.first.len > 0 and re.first.len > 0)
                        {
                            var pairs: f64 = 0;
                            if (le.first.len <= re.first.len) {
                                var map = std.AutoHashMap(i64, u32).init(self.gpa);
                                defer map.deinit();
                                for (re.first, 0..) |row, id| {
                                    const val = numericKeyAt(rct, rc, row) orelse return null;
                                    map.put(val, re.counts[id]) catch return null;
                                }
                                for (le.first, 0..) |row, id| {
                                    const val = numericKeyAt(lct, lc, row) orelse return null;
                                    if (map.get(val)) |cr| {
                                        pairs += @as(f64, @floatFromInt(le.counts[id])) * @as(f64, @floatFromInt(cr));
                                    }
                                }
                            } else {
                                var map = std.AutoHashMap(i64, u32).init(self.gpa);
                                defer map.deinit();
                                for (le.first, 0..) |row, id| {
                                    const val = numericKeyAt(lct, lc, row) orelse return null;
                                    map.put(val, le.counts[id]) catch return null;
                                }
                                for (re.first, 0..) |row, id| {
                                    const val = numericKeyAt(rct, rc, row) orelse return null;
                                    if (map.get(val)) |cl| {
                                        pairs += @as(f64, @floatFromInt(cl)) * @as(f64, @floatFromInt(re.counts[id]));
                                    }
                                }
                            }
                            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                                std.debug.print("[plan] join enc-exact lndv={d} rndv={d} -> {d:.0}\n", .{
                                    le.first.len, re.first.len, pairs,
                                });
                            }
                            return pairs;
                        }
                    }
                }
            }
            // Float keys: exact per-value counts from the columnar image
            // (`f64Key`), since float columns carry no dictionary encoding.
            if (lt.cols[lc].ty == .float and rt.cols[rc].ty == .float) {
                if (self.findColumnar(lt.name)) |lct| {
                    if (self.findColumnar(rt.name)) |rct| {
                        if (self.floatKeyCounts(lt.name, lct, lc)) |lm| {
                            if (self.floatKeyCounts(rt.name, rct, rc)) |rm| {
                                var pairs: f64 = 0;
                                if (lm.map.count() <= rm.map.count()) {
                                    var it = lm.map.iterator();
                                    while (it.next()) |e2| {
                                        if (rm.map.get(e2.key_ptr.*)) |cr| {
                                            pairs += @as(f64, @floatFromInt(e2.value_ptr.*)) * @as(f64, @floatFromInt(cr));
                                        }
                                    }
                                } else {
                                    var it = rm.map.iterator();
                                    while (it.next()) |e2| {
                                        if (lm.map.get(e2.key_ptr.*)) |cl| {
                                            pairs += @as(f64, @floatFromInt(e2.value_ptr.*)) * @as(f64, @floatFromInt(cl));
                                        }
                                    }
                                }
                                if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                                    std.debug.print("[plan] join fenc-exact lndv={d} rndv={d} -> {d:.0}\n", .{
                                        lm.map.count(), rm.map.count(), pairs,
                                    });
                                }
                                return pairs;
                            }
                        }
                    }
                }
            }
        }
        const n_mcv_l: f64 = if (l_is_str) @floatFromInt(lst.mcv_str.len) else @floatFromInt(lst.mcv.len);
        const n_mcv_r: f64 = if (r_is_str) @floatFromInt(rst.mcv_str.len) else @floatFromInt(rst.mcv.len);
        const rest_l = @max(1.0 - (if (l_is_str) lst.mcv_str_mass else lst.mcv_mass), 0.0);
        const rest_r = @max(1.0 - (if (r_is_str) rst.mcv_str_mass else rst.mcv_mass), 0.0);
        const rest_ndv_l = @max(@as(f64, @floatFromInt(lst.ndv)) - n_mcv_l, 1.0);
        const rest_ndv_r = @max(@as(f64, @floatFromInt(rst.ndv)) - n_mcv_r, 1.0);
        // Sampled dictionaries (ndv > 65,536): the top-512 value map is a much
        // richer sketch than the top-16 MCV list. Use its scaled counts plus a
        // residual term for the long tail.
        if (l_is_str and lst.dict.len > 0 and rst.dict.len > 0 and
            (lst.dict_sampled or rst.dict_sampled) and
            std.c.getenv("ZHDB_NO_SAMP_DICT") == null)
        {
            const lrows_f: f64 = @floatFromInt(lt.rows.items.len);
            const rrows_f: f64 = @floatFromInt(rt.rows.items.len);
            const lscale: f64 = if (lst.dict_sampled and lst.dict_sample_rows > 0)
                lrows_f / @as(f64, @floatFromInt(lst.dict_sample_rows))
            else
                1.0;
            const rscale: f64 = if (rst.dict_sampled and rst.dict_sample_rows > 0)
                rrows_f / @as(f64, @floatFromInt(rst.dict_sample_rows))
            else
                1.0;
            const lrest_ndv = @max(@as(f64, @floatFromInt(lst.ndv)) - @as(f64, @floatFromInt(lst.dict.len)), 1.0);
            const rrest_ndv = @max(@as(f64, @floatFromInt(rst.ndv)) - @as(f64, @floatFromInt(rst.dict.len)), 1.0);
            var lkept: f64 = 0;
            for (lst.dict) |e| lkept += @as(f64, @floatFromInt(e.count)) * lscale;
            var rkept: f64 = 0;
            for (rst.dict) |e| rkept += @as(f64, @floatFromInt(e.count)) * rscale;
            const lres = @max(lrows_f - lkept, 0.0);
            const rres = @max(rrows_f - rkept, 0.0);
            var rmap = std.StringHashMap(f64).init(self.gpa);
            defer rmap.deinit();
            rmap.ensureTotalCapacity(@intCast(rst.dict.len)) catch return null;
            for (rst.dict) |e| {
                rmap.put(e.s, @as(f64, @floatFromInt(e.count)) * rscale) catch return null;
            }
            var pairs: f64 = 0;
            for (lst.dict) |a| {
                const ca = @as(f64, @floatFromInt(a.count)) * lscale;
                if (ca <= 0) continue;
                const cr = rmap.get(a.s) orelse blk: {
                    if (rres <= 0) break :blk @as(f64, 0);
                    if (rst.min_str.len > 0 and
                        (std.mem.order(u8, a.s, rst.min_str) == .lt or
                            std.mem.order(u8, a.s, rst.max_str) == .gt)) break :blk @as(f64, 0);
                    break :blk rres / rrest_ndv;
                };
                pairs += ca * cr;
            }
            var lmap = std.StringHashMap(void).init(self.gpa);
            defer lmap.deinit();
            lmap.ensureTotalCapacity(@intCast(lst.dict.len)) catch return null;
            for (lst.dict) |a| lmap.put(a.s, {}) catch return null;
            for (rst.dict) |a| {
                if (lmap.contains(a.s)) continue;
                if (lres <= 0) continue;
                if (lst.min_str.len > 0 and
                    (std.mem.order(u8, a.s, lst.min_str) == .lt or
                        std.mem.order(u8, a.s, lst.max_str) == .gt)) continue;
                const cr = @as(f64, @floatFromInt(a.count)) * rscale;
                pairs += (lres / lrest_ndv) * cr;
            }
            // Residual × residual with string key-domain overlap.
            var domain: f64 = 1.0;
            if (lst.min_str.len > 0 and rst.min_str.len > 0) {
                const llo = @as(f64, @floatFromInt(distStrKey(lst.min_str)));
                const lhi = @as(f64, @floatFromInt(distStrKey(lst.max_str)));
                const rlo = @as(f64, @floatFromInt(distStrKey(rst.min_str)));
                const rhi = @as(f64, @floatFromInt(distStrKey(rst.max_str)));
                const sl = lhi - llo + 1.0;
                const sr = rhi - rlo + 1.0;
                const ov = @max(@min(lhi, rhi) - @max(llo, rlo) + 1.0, 0.0);
                domain = @min(ov / @max(@min(sl, sr), 1.0), 1.0);
            }
            pairs += domain * lres * rres / @max(lrest_ndv, rrest_ndv);
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[plan] join samp-dict ldict={d} rdict={d} lscale={d:.2} rscale={d:.2} res={d:.0}/{d:.0} -> {d:.0}\n", .{
                    lst.dict.len, rst.dict.len, lscale, rscale, lres, rres, pairs,
                });
            }
            return pairs;
        }
        // MCV↔MCV exact, plus MCV↔residual for values the other side only has in
        // its residual (a frequent value meeting a near-unique value). Without
        // the cross terms, a side whose MCV mass is 1.0 zeroed the whole estimate.
        var mcv_sel: f64 = 0;
        if (!l_is_str) {
            for (lst.mcv) |a| {
                var matched = false;
                for (rst.mcv) |b| {
                    if (a.v == b.v) {
                        mcv_sel += a.freq * b.freq;
                        matched = true;
                        break;
                    }
                }
                if (!matched and a.v >= rst.min and a.v <= rst.max) {
                    mcv_sel += a.freq * rest_r / rest_ndv_r;
                }
            }
            for (rst.mcv) |b| {
                var matched = false;
                for (lst.mcv) |a| {
                    if (a.v == b.v) {
                        matched = true;
                        break;
                    }
                }
                if (!matched and b.v >= lst.min and b.v <= lst.max) {
                    mcv_sel += b.freq * rest_l / rest_ndv_l;
                }
            }
        } else {
            for (lst.mcv_str) |a| {
                var matched = false;
                for (rst.mcv_str) |b| {
                    if (std.mem.eql(u8, a.s, b.s)) {
                        mcv_sel += a.freq * b.freq;
                        matched = true;
                        break;
                    }
                }
                if (!matched and rst.min_str.len > 0 and rst.max_str.len > 0 and
                    std.mem.order(u8, a.s, rst.min_str) != .lt and
                    std.mem.order(u8, a.s, rst.max_str) != .gt)
                {
                    mcv_sel += a.freq * rest_r / rest_ndv_r;
                }
            }
            for (rst.mcv_str) |b| {
                var matched = false;
                for (lst.mcv_str) |a| {
                    if (std.mem.eql(u8, a.s, b.s)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched and lst.min_str.len > 0 and lst.max_str.len > 0 and
                    std.mem.order(u8, b.s, lst.min_str) != .lt and
                    std.mem.order(u8, b.s, lst.max_str) != .gt)
                {
                    mcv_sel += b.freq * rest_l / rest_ndv_l;
                }
            }
        }
        // Key-domain overlap: uniform distinct sets only match on shared values.
        // `ov / min(span)` is the fraction of the smaller side's value range the
        // other side can cover (1.0 for identical/superset domains).
        var domain: f64 = 1.0;
        if (!l_is_str) {
            // Numeric keys: value-space ranges (float keys decode back; integer
            // keys convert directly), with a density factor so sparse or
            // fine-grained value sets are not confused with their span.
            const isf = lt.cols[lc].ty == .float or rt.cols[rc].ty == .float;
            const llo = if (isf) f64FromKey(lst.min) else @as(f64, @floatFromInt(lst.min));
            const lhi = if (isf) f64FromKey(lst.max) else @as(f64, @floatFromInt(lst.max));
            const rlo = if (isf) f64FromKey(rst.min) else @as(f64, @floatFromInt(rst.min));
            const rhi = if (isf) f64FromKey(rst.max) else @as(f64, @floatFromInt(rst.max));
            const sl = @max(lhi - llo + 1.0, 1.0);
            const sr = @max(rhi - rlo + 1.0, 1.0);
            const ovl = @max(@min(lhi, rhi) - @max(llo, rlo) + 1.0, 0.0);
            if (ovl <= 0) {
                domain = 0.0;
            } else {
                const lndv = @as(f64, @floatFromInt(lst.ndv));
                const rndv = @as(f64, @floatFromInt(rst.ndv));
                const dl = lndv / sl;
                const dr = rndv / sr;
                const common = @min(ovl * @max(dl, dr), @min(lndv, rndv));
                domain = common / @max(@min(lndv, rndv), 1.0);
            }
        } else if (lst.min_str.len > 0 and rst.min_str.len > 0) {
            // String key domains: order-preserving key spans, so a partial
            // lexicographic overlap is scaled (not just "intersects or not").
            const llo = @as(f64, @floatFromInt(distStrKey(lst.min_str)));
            const lhi = @as(f64, @floatFromInt(distStrKey(lst.max_str)));
            const rlo = @as(f64, @floatFromInt(distStrKey(rst.min_str)));
            const rhi = @as(f64, @floatFromInt(distStrKey(rst.max_str)));
            const sl = lhi - llo + 1.0;
            const sr = rhi - rlo + 1.0;
            const ov = @max(@min(lhi, rhi) - @max(llo, rlo) + 1.0, 0.0);
            domain = @min(ov / @max(@min(sl, sr), 1.0), 1.0);
        }
        const sel = mcv_sel + domain * rest_l * rest_r / @max(rest_ndv_l, rest_ndv_r);
        const pairs = @as(f64, @floatFromInt(lrows)) * @as(f64, @floatFromInt(rrows)) * sel;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] join pairs lrows={d} rrows={d} ndv={d}/{d} mcv={d:.6} rest={d:.4}/{d:.4} rndv={d:.0}/{d:.0} domain={d:.3} -> {d:.0}\n", .{
                lrows, rrows, lst.ndv, rst.ndv, mcv_sel, rest_l, rest_r, rest_ndv_l, rest_ndv_r, domain, pairs,
            });
        }
        return pairs;
    }

    /// Per-key statistics for a materialised join intermediate: ndv, min/max and
    /// the top-16 MCVs with sampled frequencies (bounded to 20k rows). The next
    /// join step then estimates Σ f_l(v)·f_r(v) instead of 1/max(ndv).
    fn computeTempStats(self: *Engine, t: *Table) void {
        const n = t.rows.items.len;
        if (n == 0) return;
        if (t.stats.len != t.cols.len) {
            const grown = self.gpa.alloc(ColStat, t.cols.len) catch return;
            @memset(grown, .{});
            const k = @min(t.stats.len, grown.len);
            @memcpy(grown[0..k], t.stats[0..k]);
            if (t.stats.len > 0) self.gpa.free(t.stats);
            t.stats = grown;
        }
        var step: usize = if (n <= 262_144) 1 else @max(1, n / 20000);
        if (step > 1 and step % 2 == 0) step += 1;
        const samp_f_of = struct {
            fn f(nn: usize, sampled: u32) f64 {
                const n_f: f64 = @floatFromInt(nn);
                const s_f: f64 = @floatFromInt(sampled);
                return if (s_f > 0) n_f / s_f else 1.0;
            }
        }.f;
        for (t.cols, 0..) |c, ci| {
            const is_str = c.ty == .text or c.ty == .date or c.ty == .timestamp;
            if (!is_str) switch (c.ty) {
                .int, .boolean, .float => {},
                else => continue,
            };
            if (!is_str) {
                var st = ColStat{};
                var counts = std.AutoHashMap(i64, u32).init(self.gpa);
                defer counts.deinit();
                var sampled: u32 = 0;
                st.min = std.math.maxInt(i64);
                st.max = std.math.minInt(i64);
                var ri: usize = 0;
                while (ri < n) : (ri += step) {
                    const v = t.rows.items[ri][ci];
                    const x: i64 = switch (v) {
                        .int => |iv| iv,
                        .boolean => |b| @intFromBool(b),
                        .float => |f| if (std.math.isNan(f)) continue else f64Key(f),
                        else => continue,
                    };
                    const gop = counts.getOrPut(x) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                    st.min = @min(st.min, x);
                    st.max = @max(st.max, x);
                    sampled += 1;
                }
                if (sampled == 0) continue;
                if (st.min > st.max) {
                    st.min = 0;
                    st.max = 0;
                }
                const d: f64 = @floatFromInt(counts.count());
                var ones: u64 = 0;
                var cit = counts.valueIterator();
                while (cit.next()) |cv| {
                    if (cv.* == 1) ones += 1;
                }
                const n_f: f64 = @floatFromInt(n);
                const samp_f: f64 = @floatFromInt(sampled);
                st.ndv = if (sampled >= n)
                    counts.count()
                else
                    @intFromFloat(@max(d + @as(f64, @floatFromInt(ones)) * (n_f / samp_f - 1.0), d));
                var entries = std.ArrayList(McvEntry).empty;
                defer entries.deinit(self.gpa);
                var it2 = counts.iterator();
                const tot: f64 = @floatFromInt(sampled);
                while (it2.next()) |e| {
                    if (e.value_ptr.* < 2) continue;
                    entries.append(self.gpa, .{ .v = e.key_ptr.*, .freq = @as(f64, @floatFromInt(e.value_ptr.*)) / tot }) catch {};
                }
                std.mem.sort(McvEntry, entries.items, {}, struct {
                    fn gt(_: void, a: McvEntry, b: McvEntry) bool {
                        return a.freq > b.freq;
                    }
                }.gt);
                const take = @min(entries.items.len, 16);
                if (take > 0) {
                    if (self.gpa.alloc(McvEntry, take)) |m| {
                        @memcpy(m, entries.items[0..take]);
                        st.mcv = m;
                        for (m) |e2| st.mcv_mass += e2.freq;
                        st.mcv_mass = @min(st.mcv_mass, 1.0);
                    } else |_| {}
                }
                t.stats[ci] = st;
                continue;
            }
            // String keys: same bounded sampling, with the top-16 MCV strings.
            var st = ColStat{};
            var counts = std.StringHashMap(u32).init(self.gpa);
            defer counts.deinit();
            var sampled: u32 = 0;
            var smin: []const u8 = &.{};
            var smax: []const u8 = &.{};
            var ri: usize = 0;
            while (ri < n) : (ri += step) {
                const v = t.rows.items[ri][ci];
                const s2 = switch (v) {
                    .text => |x| x,
                    else => continue,
                };
                const gop = counts.getOrPut(s2) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
                if (smin.len == 0 or std.mem.order(u8, s2, smin) == .lt) smin = s2;
                if (smax.len == 0 or std.mem.order(u8, s2, smax) == .gt) smax = s2;
                sampled += 1;
            }
            if (sampled == 0) continue;
            var ones: u64 = 0;
            var cit = counts.valueIterator();
            while (cit.next()) |cv| {
                if (cv.* == 1) ones += 1;
            }
            const d: f64 = @floatFromInt(counts.count());
            const scale = samp_f_of(n, sampled);
            st.ndv = if (sampled >= n)
                counts.count()
            else
                @intFromFloat(@max(d + @as(f64, @floatFromInt(ones)) * (scale - 1.0), d));
            st.min_str = self.gpa.dupe(u8, smin) catch &.{};
            st.max_str = self.gpa.dupe(u8, smax) catch &.{};
            var entries = std.ArrayList(McvStr).empty;
            defer {
                for (entries.items) |e3| self.gpa.free(e3.s);
                entries.deinit(self.gpa);
            }
            var it2 = counts.iterator();
            const tot: f64 = @floatFromInt(sampled);
            while (it2.next()) |e| {
                if (e.value_ptr.* < 2) continue;
                const dup = self.gpa.dupe(u8, e.key_ptr.*) catch continue;
                entries.append(self.gpa, .{ .s = dup, .freq = @as(f64, @floatFromInt(e.value_ptr.*)) / tot }) catch {
                    self.gpa.free(dup);
                };
            }
            std.mem.sort(McvStr, entries.items, {}, struct {
                fn gt(_: void, a: McvStr, b: McvStr) bool {
                    return a.freq > b.freq;
                }
            }.gt);
            const take = @min(entries.items.len, 16);
            if (take > 0) {
                if (self.gpa.alloc(McvStr, take)) |m| {
                    @memcpy(m, entries.items[0..take]);
                    // Ownership moves into ColStat; detach from the temp list.
                    for (entries.items[0..take]) |*e4| e4.s = &.{};
                    st.mcv_str = m;
                    for (m) |e2| st.mcv_str_mass += e2.freq;
                    st.mcv_str_mass = @min(st.mcv_str_mass, 1.0);
                } else |_| {}
            }
            // Value map for the intermediate (top-512, count >= 2), mirroring
            // ANALYZE so the next chain step can use dictionary cardinality
            // instead of the top-16 MCV list.
            {
                var dentries = std.ArrayList(DictEntry).empty;
                var dit = counts.iterator();
                while (dit.next()) |e| {
                    if (e.value_ptr.* < 2) continue;
                    const dup = self.gpa.dupe(u8, e.key_ptr.*) catch continue;
                    dentries.append(self.gpa, .{ .s = dup, .count = e.value_ptr.* }) catch {
                        self.gpa.free(dup);
                        continue;
                    };
                }
                std.mem.sort(DictEntry, dentries.items, {}, struct {
                    fn gt(_: void, a: DictEntry, b: DictEntry) bool {
                        return a.count > b.count;
                    }
                }.gt);
                const dtake = @min(dentries.items.len, 512);
                for (dentries.items[dtake..]) |e5| self.gpa.free(e5.s);
                if (dtake > 0) {
                    if (self.gpa.alloc(DictEntry, dtake)) |dm| {
                        @memcpy(dm, dentries.items[0..dtake]);
                        st.dict = dm;
                        // Incomplete if the sample was partial *or* the 512-entry
                        // cap dropped values; only then is the residual needed.
                        st.dict_sampled = sampled < n or dtake < counts.count();
                        st.dict_sample_rows = sampled;
                    } else |_| {
                        for (dentries.items[0..dtake]) |e5| self.gpa.free(e5.s);
                    }
                }
                dentries.deinit(self.gpa);
            }
            t.stats[ci] = st;
        }
    }

    /// Fused star-join aggregation: hash-build every dimension, probe the fact
    /// rows through all steps and aggregate on the fly — no `__join_N`.
    fn qualifierOf(e: *sql.Expr) ?[]const u8 {
        const n: []const u8 = switch (e.*) {
            .column => |x| x,
            .column_idx => |c| c.name,
            else => return null,
        };
        if (std.mem.lastIndexOfScalar(u8, n, '.')) |dot| return n[0..dot];
        return null;
    }

    /// Resolve a column reference on `t`, honouring an explicit qualifier: `c.k`
    /// must NOT resolve on `a` just because both have a `k` column.
    fn keyColFor(t: *Table, e: *sql.Expr, tname: []const u8) ?usize {
        if (qualifierOf(e)) |q| {
            if (!std.ascii.eqlIgnoreCase(q, tname)) return null;
        }
        return keyCol(t, e);
    }

    const FusedSpec = struct { kind: u8, expr: ?*sql.Expr, name: []const u8 };

    fn colExprName(e: *sql.Expr) ?[]const u8 {
        return switch (e.*) {
            .column => |n| n,
            .column_idx => |c| c.name,
            else => null,
        };
    }

    fn fusedSpecOfCall(specs: []const FusedSpec, c: sql.Call) ?usize {
        for (specs, 0..) |sp, i| {
            if (!std.ascii.eqlIgnoreCase(sp.name, c.name)) continue;
            if (sp.expr != null and c.args.len == 1 and sp.expr.? != c.args[0]) {
                // HAVING re-parses the aggregate: match by argument column name.
                const a = colExprName(sp.expr.?) orelse continue;
                const b = colExprName(c.args[0]) orelse continue;
                if (!std.ascii.eqlIgnoreCase(a, b)) continue;
            }
            return i;
        }
        return null;
    }

    fn fusedAggValue(sp: FusedSpec, g: anytype, si: usize) f64 {
        return switch (sp.kind) {
            1 => @floatFromInt(g.counts[si]),
            2 => @floatFromInt(g.sums[si]),
            3 => @floatFromInt(g.mins[si]),
            4 => @floatFromInt(g.maxs[si]),
            else => if (g.counts[si] > 0) @as(f64, @floatFromInt(g.sums[si])) / @as(f64, @floatFromInt(g.counts[si])) else 0,
        };
    }

    fn fusedLiteral(e: *sql.Expr) ?f64 {
        return switch (e.*) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
            else => null,
        };
    }

    /// HAVING over aggregate results: comparisons against literals, AND/OR/NOT.
    fn fusedHavingOk(specs: []const FusedSpec, g: anytype, e: *sql.Expr) ?bool {
        switch (e.*) {
            .binary => |b| {
                if (b.op == .and_op) {
                    const l = fusedHavingOk(specs, g, b.lhs) orelse return null;
                    if (!l) return false;
                    return fusedHavingOk(specs, g, b.rhs);
                }
                if (b.op == .or_op) {
                    const l = fusedHavingOk(specs, g, b.lhs) orelse return null;
                    if (l) return true;
                    return fusedHavingOk(specs, g, b.rhs);
                }
                var call_idx: ?usize = null;
                var lit: ?f64 = null;
                var flip = false;
                if (b.lhs.* == .call) {
                    call_idx = fusedSpecOfCall(specs, b.lhs.call);
                    lit = fusedLiteral(b.rhs);
                } else if (b.rhs.* == .call) {
                    call_idx = fusedSpecOfCall(specs, b.rhs.call);
                    lit = fusedLiteral(b.lhs);
                    flip = true;
                }
                const si = call_idx orelse return null;
                const k = lit orelse return null;
                const v = fusedAggValue(specs[si], g, si);
                const op = if (flip) switch (b.op) {
                    .lt => sql.BinOp.gt,
                    .gt => sql.BinOp.lt,
                    .le => sql.BinOp.ge,
                    .ge => sql.BinOp.le,
                    else => b.op,
                } else b.op;
                return switch (op) {
                    .eq => v == k,
                    .neq => v != k,
                    .lt => v < k,
                    .le => v <= k,
                    .gt => v > k,
                    .ge => v >= k,
                    else => null,
                };
            },
            .not => |x| {
                const inner = fusedHavingOk(specs, g, x) orelse return null;
                return !inner;
            },
            else => return null,
        }
    }

    fn fusedHavingShape(specs: []const FusedSpec, e: *sql.Expr) bool {
        return switch (e.*) {
            .binary => |b| blk: {
                if (b.op == .and_op or b.op == .or_op) {
                    break :blk fusedHavingShape(specs, b.lhs) and fusedHavingShape(specs, b.rhs);
                }
                var si: ?usize = null;
                var has_lit = false;
                if (b.lhs.* == .call) {
                    si = fusedSpecOfCall(specs, b.lhs.call);
                    has_lit = fusedLiteral(b.rhs) != null;
                } else if (b.rhs.* == .call) {
                    si = fusedSpecOfCall(specs, b.rhs.call);
                    has_lit = fusedLiteral(b.lhs) != null;
                }
                break :blk si != null and has_lit;
            },
            .not => |x| fusedHavingShape(specs, x),
            else => false,
        };
    }

    fn starJoinAggregate(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select, fact: []const u8) EngineError!?Result {
        // Multi-key ON residuals must run as post-join filters.
        if (sel.join) |j0| {
            if (j0.extra_eqs.len > 0) return null;
        }
        for (sel.more_joins) |jj| {
            if (jj.extra_eqs.len > 0) return null;
        }
        // DISTINCT over (group keys + aggregates) cannot change the result:
        // group keys are unique per row, and pure aggregates produce one row.
        // So the fused path may simply ignore it.
        if (sel.distinct and sel.group_by.len == 0 and sel.items.len > 0) {
            var any_agg = false;
            for (sel.items) |it| {
                if (it.expr.* == .call) any_agg = true;
            }
            if (!any_agg) return null;
        }
        var joins = std.ArrayList(sql.Join).empty;
        defer joins.deinit(self.gpa);
        if (sel.join) |j| try joins.append(self.gpa, j);
        try joins.appendSlice(self.gpa, sel.more_joins);
        if (joins.items.len < 2) return null;

        const ft = self.find(fact) orelse return null;
        const Spec = FusedSpec;
        var specs = std.ArrayList(Spec).empty;
        defer specs.deinit(self.gpa);
        var key_names = std.ArrayList([]const u8).empty;
        defer key_names.deinit(self.gpa);
        for (sel.items) |it| {
            switch (it.expr.*) {
                .call => |c| {
                    var kind: u8 = 0;
                    if (std.ascii.eqlIgnoreCase(c.name, "count")) {
                        kind = 1;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "sum")) {
                        kind = 2;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "min")) {
                        kind = 3;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "max")) {
                        kind = 4;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "avg")) {
                        kind = 5;
                    } else return null;
                    var arg: ?*sql.Expr = null;
                    if (c.args.len == 1) arg = c.args[0];
                    try specs.append(self.gpa, .{ .kind = kind, .expr = arg, .name = c.name });
                },
                .column => |n| try key_names.append(self.gpa, n),
                .column_idx => |c| try key_names.append(self.gpa, c.name),
                else => return null,
            }
        }
        if (specs.items.len == 0) return null;
        if (sel.having) |h| {
            if (!fusedHavingShape(specs.items, h)) return null;
        }

        // Resolve each join against the relations already joined so far
        // (fact first, then dimensions in order). Qualified names are honoured,
        // so `cb.k = cc.k` is not misread as a fact-table key.
        const Rel = struct { table: *Table, name: []const u8 };
        const Dim = struct {
            table: *Table,
            /// Relation providing the probe value (index into `rels`).
            src_rel: usize,
            src_col: usize,
            dcol: usize,
            map: std.StringHashMap(std.ArrayList(u32)),
        };
        var rels = std.ArrayList(Rel).empty;
        defer rels.deinit(self.gpa);
        try rels.append(self.gpa, .{ .table = ft, .name = fact });
        var dims = std.ArrayList(Dim).empty;
        defer {
            for (dims.items) |*d| {
                var it = d.map.valueIterator();
                while (it.next()) |v| v.deinit(self.gpa);
                d.map.deinit();
            }
            dims.deinit(self.gpa);
        }
        for (joins.items) |j| {
            if (j.on.* != .binary or j.on.binary.op != .eq) return null;
            const dt = self.find(j.table) orelse return null;
            self.ensureRowsMaterialized(j.table);
            var found_src: ?usize = null;
            var src_col: usize = 0;
            var dcol: usize = 0;
            for (rels.items, 0..) |r, ri| {
                if (keyColFor(r.table, j.on.binary.lhs, r.name)) |c| {
                    src_col = c;
                    found_src = ri;
                    dcol = keyColFor(dt, j.on.binary.rhs, j.table) orelse continue;
                    break;
                }
                if (keyColFor(r.table, j.on.binary.rhs, r.name)) |c| {
                    src_col = c;
                    found_src = ri;
                    dcol = keyColFor(dt, j.on.binary.lhs, j.table) orelse continue;
                    break;
                }
            }
            const src_rel = found_src orelse return null;
            var map = std.StringHashMap(std.ArrayList(u32)).init(self.gpa);
            for (dt.rows.items, 0..) |row, ri| {
                if (isRowDeleted(dt, ri) or !self.visibleRow(dt, ri)) continue;
                if (tableIsNull(dt, dcol, ri)) continue;
                const k = try formatValue(alloc, row[dcol]);
                const gop = try map.getOrPut(k);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.gpa, @intCast(ri));
            }
            try dims.append(self.gpa, .{ .table = dt, .src_rel = src_rel, .src_col = src_col, .dcol = dcol, .map = map });
            try rels.append(self.gpa, .{ .table = dt, .name = j.table });
        }

        // Combined column list for evaluating aggregate arguments.
        var cols_total: usize = ft.cols.len;
        for (dims.items) |d| cols_total += d.table.cols.len;
        const cols = try alloc.alloc(Column, cols_total);
        @memcpy(cols[0..ft.cols.len], ft.cols);
        var off: usize = ft.cols.len;
        for (dims.items) |d| {
            @memcpy(cols[off .. off + d.table.cols.len], d.table.cols);
            off += d.table.cols.len;
        }
        const joined = try alloc.alloc(Value, cols_total);

        const G = struct { key: []Value, counts: []i64, sums: []i128, mins: []i64, maxs: []i64 };
        var groups = std.ArrayList(G).empty;
        defer groups.deinit(self.gpa);
        var gmap = std.StringHashMap(u32).init(self.gpa);
        defer gmap.deinit();
        var keybuf = std.ArrayList(u8).empty;
        defer keybuf.deinit(alloc);

        var key_cols = try alloc.alloc(usize, key_names.items.len);
        defer alloc.free(key_cols);
        for (key_names.items, 0..) |kn, i| key_cols[i] = findColSlice(cols, kn) orelse return null;
        if (sel.group_by.len != 0 and sel.group_by.len != key_names.items.len) return null;

        // Explicit recursive probe over the dimension list: the value for
        // dim[k] comes from the fact row or from an already-picked dimension.
        const pick = try alloc.alloc(u32, dims.items.len);
        defer alloc.free(pick);
        const Ctx = struct {
            pick: []u32,
            dims: []Dim,
            ft: *Table,
            joined: []Value,
            cols: []Column,
            key_cols: []usize,
            keybuf: *std.ArrayList(u8),
            groups: *std.ArrayList(G),
            gmap: *std.StringHashMap(u32),
            specs: []const Spec,
            engine: *Engine,
            alloc: std.mem.Allocator,
            where: ?*sql.Expr,

            fn rec(c: *@This(), depth: usize, frow: []Value) EngineError!void {
                const d = c.dims[depth];
                const src_row: []Value = if (d.src_rel == 0)
                    frow
                else
                    c.dims[d.src_rel - 1].table.rows.items[c.pick[d.src_rel - 1]];
                const fv = src_row[d.src_col];
                if (fv == .null) return;
                const k = try formatValue(c.alloc, fv);
                const list = d.map.get(k) orelse return;
                for (list.items) |rid| {
                    c.pick[depth] = rid;
                    if (depth + 1 < c.dims.len) {
                        try c.rec(depth + 1, frow);
                    } else {
                        try c.emit(frow);
                    }
                }
            }

            fn emit(c: *@This(), frow: []Value) EngineError!void {
                @memcpy(c.joined[0..c.ft.cols.len], frow);
                var o3: usize = c.ft.cols.len;
                for (c.dims, 0..) |d2, di| {
                    @memcpy(c.joined[o3 .. o3 + d2.table.cols.len], d2.table.rows.items[c.pick[di]]);
                    o3 += d2.table.cols.len;
                }
                // Filter on the joined row before accumulating.
                if (c.where) |w| {
                    const keep = try c.engine.eval(c.alloc, w, c.joined, c.cols, null);
                    if (!truthy(keep)) return;
                }
                c.keybuf.clearRetainingCapacity();
                for (c.key_cols, 0..) |kc, i| {
                    if (i > 0) try c.keybuf.append(c.alloc, 0x1f);
                    try c.keybuf.appendSlice(c.alloc, try formatValue(c.alloc, c.joined[kc]));
                }
                var gi: u32 = undefined;
                const gop = try c.gmap.getOrPut(c.keybuf.items);
                if (!gop.found_existing) {
                    const kv = try c.alloc.alloc(Value, c.key_cols.len);
                    for (c.key_cols, 0..) |kc, i| kv[i] = c.joined[kc];
                    gi = @intCast(c.groups.items.len);
                    gop.value_ptr.* = gi;
                    gop.key_ptr.* = try c.alloc.dupe(u8, c.keybuf.items);
                    try c.groups.append(c.engine.gpa, .{
                        .key = kv,
                        .counts = try c.alloc.alloc(i64, c.specs.len),
                        .sums = try c.alloc.alloc(i128, c.specs.len),
                        .mins = try c.alloc.alloc(i64, c.specs.len),
                        .maxs = try c.alloc.alloc(i64, c.specs.len),
                    });
                    @memset(c.groups.items[gi].counts, 0);
                    @memset(c.groups.items[gi].sums, 0);
                } else gi = gop.value_ptr.*;
                const g = &c.groups.items[gi];
                for (c.specs, 0..) |sp, si| {
                    const v: Value = if (sp.expr) |e| try c.engine.eval(c.alloc, e, c.joined, c.cols, null) else Value{ .int = 1 };
                    if (v == .null) continue;
                    const iv: i64 = switch (v) {
                        .int => |x| x,
                        .float => |f| @intFromFloat(f),
                        .text => |t| @intCast(t.len),
                        else => 0,
                    };
                    g.counts[si] += 1;
                    g.sums[si] += iv;
                    if (g.counts[si] == 1) {
                        g.mins[si] = iv;
                        g.maxs[si] = iv;
                    } else {
                        g.mins[si] = @min(g.mins[si], iv);
                        g.maxs[si] = @max(g.maxs[si], iv);
                    }
                }
            }
        };
        const ctx0 = Ctx{
            .pick = pick,
            .dims = dims.items,
            .ft = ft,
            .joined = joined,
            .cols = cols,
            .key_cols = key_cols,
            .keybuf = &keybuf,
            .groups = &groups,
            .gmap = &gmap,
            .specs = specs.items,
            .engine = self,
            .alloc = alloc,
            .where = sel.where,
        };
        var ctx = ctx0;
        for (ft.rows.items, 0..) |frow, fri| {
            if (isRowDeleted(ft, fri) or !self.visibleRow(ft, fri)) continue;
            try ctx.rec(0, frow);
        }

        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] fused-stream-aggregate dims={d} groups={d}\n", .{ dims.items.len, groups.items.len });
        }
        var out_cols = std.ArrayList([]const u8).empty;
        var out_rows = std.ArrayList([]Value).empty;
        if (groups.items.len == 0 and key_names.items.len == 0) {
            // empty input: one row of zeros/NULLs
            const row = try alloc.alloc(Value, specs.items.len);
            for (specs.items, 0..) |sp, si| {
                row[si] = if (sp.kind == 1) .{ .int = 0 } else .null;
            }
            try out_rows.append(alloc, row);
        }
        // ORDER BY (one or more aggregate / group-key columns) + LIMIT over the
        // (small) group result.
        const OrdKey = struct { spec: ?usize, group: ?usize, desc: bool };
        var keys = std.ArrayList(OrdKey).empty;
        defer keys.deinit(alloc);
        for (sel.order_by) |ob| {
            var spec: ?usize = null;
            var group: ?usize = null;
            const desc = ob.desc;
            switch (ob.expr.*) {
                .int => |n| {
                    const nn: usize = @intCast(n);
                    if (nn >= 1 and nn <= key_names.items.len) {
                        group = nn - 1;
                    } else if (nn > key_names.items.len and nn - key_names.items.len <= specs.items.len) {
                        spec = nn - key_names.items.len - 1;
                    } else return null;
                },
                .call => |c| {
                    var hit = false;
                    for (specs.items, 0..) |sp, si| {
                        if (std.ascii.eqlIgnoreCase(sp.name, c.name)) {
                            spec = si;
                            hit = true;
                        }
                    }
                    if (!hit) return null;
                },
                .column => |alias| {
                    var hit = false;
                    for (sel.items, 0..) |it, i| {
                        if (it.alias) |a| {
                            if (std.ascii.eqlIgnoreCase(a, alias)) {
                                if (i < key_names.items.len) {
                                    group = i;
                                } else {
                                    spec = i - key_names.items.len;
                                }
                                hit = true;
                            }
                        }
                    }
                    if (!hit) {
                        // fall back to a plain group column name
                        for (key_names.items, 0..) |kn, i| {
                            if (std.ascii.eqlIgnoreCase(kn, alias)) {
                                group = i;
                                hit = true;
                            }
                        }
                    }
                    if (!hit) return null;
                },
                else => return null,
            }
            try keys.append(alloc, .{ .spec = spec, .group = group, .desc = desc });
        }

        const specValue = struct {
            fn get(g: anytype, sp: anytype, si: usize) f64 {
                return switch (sp.kind) {
                    1 => @floatFromInt(g.counts[si]),
                    2 => @floatFromInt(g.sums[si]),
                    3 => @floatFromInt(g.mins[si]),
                    4 => @floatFromInt(g.maxs[si]),
                    else => if (g.counts[si] > 0) @as(f64, @floatFromInt(g.sums[si])) / @as(f64, @floatFromInt(g.counts[si])) else 0,
                };
            }
        }.get;

        var order = std.ArrayList(usize).empty;
        defer order.deinit(alloc);
        for (groups.items, 0..) |_, gi| try order.append(alloc, gi);
        if (keys.items.len > 0) {
            const SortCtx = struct {
                groups: []G,
                specs: []const Spec,
                keys: []const OrdKey,
                fn less(c: @This(), a: usize, b: usize) bool {
                    for (c.keys) |k| {
                        var av: f64 = 0;
                        var bv: f64 = 0;
                        if (k.spec) |si| {
                            av = specValue(c.groups[a], c.specs[si], si);
                            bv = specValue(c.groups[b], c.specs[si], si);
                        } else if (k.group) |g2| {
                            const ord = Value.order(c.groups[a].key[g2], c.groups[b].key[g2]);
                            av = switch (ord) {
                                .lt => -1,
                                .eq => 0,
                                .gt => 1,
                            };
                            bv = 0;
                        }
                        if (av == bv) continue;
                        return if (k.desc) av > bv else av < bv;
                    }
                    return a < b;
                }
            };
            std.mem.sort(usize, order.items, SortCtx{ .groups = groups.items, .specs = specs.items, .keys = keys.items }, SortCtx.less);
        }
        var limit: usize = order.items.len;
        if (sel.limit) |le| {
            if (le.* == .int and le.int >= 0) limit = @min(limit, @as(usize, @intCast(le.int)));
        }
        var emitted: usize = 0;
        for (order.items) |gi| {
            if (emitted >= limit) break;
            emitted += 1;
            const g = groups.items[gi];
            if (sel.having) |h| {
                if (!(fusedHavingOk(specs.items, g, h) orelse true)) continue;
            }
            const row = try alloc.alloc(Value, key_names.items.len + specs.items.len);
            for (g.key, 0..) |kv, i| row[i] = kv;
            for (specs.items, 0..) |sp, si| {
                row[key_names.items.len + si] = switch (sp.kind) {
                    1 => .{ .int = g.counts[si] },
                    2 => .{ .int = @intCast(g.sums[si]) },
                    3 => .{ .int = g.mins[si] },
                    4 => .{ .int = g.maxs[si] },
                    else => .{ .float = if (g.counts[si] > 0) @as(f64, @floatFromInt(g.sums[si])) / @as(f64, @floatFromInt(g.counts[si])) else 0 },
                };
            }
            try out_rows.append(alloc, row);
        }
        for (sel.items) |it| {
            try out_cols.append(alloc, it.alias orelse switch (it.expr.*) {
                .column => |n| n,
                .call => |c| c.name,
                else => "?column?",
            });
        }
        return .{ .columns = try out_cols.toOwnedSlice(alloc), .rows = try out_rows.toOwnedSlice(alloc) };
    }

    /// Multi-join (`FROM a JOIN b ON … JOIN c ON …`): materialise one join at a
    /// time, choosing the next table greedily by estimated output size.
    fn execJoinChain(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select, first: sql.Join) EngineError!Result {
        const lname = switch (sel.from.?) {
            .table => |n| n,
            else => return error.UnsupportedJoin,
        };
        var pending = std.ArrayList(sql.Join).empty;
        defer pending.deinit(self.gpa);
        try pending.append(self.gpa, first);
        try pending.appendSlice(self.gpa, sel.more_joins);

        // Fully fused star-join aggregation (no intermediate temp tables).
        // Fused streaming aggregate over the whole join chain (star and chain
        // predicates). `ZHDB_NO_FUSE=1` disables it for A/B comparison.
        if (std.c.getenv("ZHDB_NO_FUSE") == null) {
            if (try self.starJoinAggregate(alloc, sel, lname)) |res| return res;
        }

        self.calibrateCostsFor(self.findColumnar(lname));

        // Per-input local predicates (pushdown) for every real table in the chain.
        var filter_names = std.ArrayList([]const u8).empty;
        defer filter_names.deinit(self.gpa);
        try filter_names.append(self.gpa, lname);
        for (pending.items) |j| try filter_names.append(self.gpa, j.table);
        const join_filters = try self.buildJoinFilters(alloc, sel, filter_names.items);

        // Automatic statistics (so ndv is available without ANALYZE).
        self.ensureStats(lname);
        for (pending.items) |j| self.ensureStats(j.table);

        // Bounded DP over the join graph (mask = subset of the pending joins).
        const m = @min(pending.items.len, 8);
        const nmask: usize = @as(usize, 1) << @intCast(m);
        var cost: [256]f64 = undefined;
        for (&cost) |*c| c.* = std.math.inf(f64);
        var rows: [256]f64 = @splat(0);
        var tie: [256]f64 = @splat(std.math.inf(f64));
        var prev: [256]u16 = @splat(0);
        var added: [256]u8 = @splat(255);
        // Key-domain range of a partial join (overlap-corrected selectivity).
        var key_rng: [256]?[2]i64 = undefined;
        for (&key_rng) |*r| r.* = null;
        // Per-mask key-frequency state for duplicate-aware DP cardinality.
        var kd: [256]KeyDist = undefined;
        for (&kd) |*x| x.* = .{};
        const start_rows: f64 = @as(f64, @floatFromInt((self.find(lname) orelse return error.TableNotFound).rows.items.len)) *
            self.whereSelectivity(lname, sel.where);
        cost[0] = 0;
        rows[0] = start_rows;
        var mask: usize = 0;
        while (mask < nmask) : (mask += 1) {
            if (std.math.isInf(cost[mask])) continue;
            var i: usize = 0;
            while (i < m) : (i += 1) {
                const bit: usize = @as(usize, 1) << @intCast(i);
                if (mask & bit != 0) continue;
                const j = pending.items[i];
                // Connected? the ON must relate some already-joined table to j.
                var connected = self.joinConnects(lname, sel.alias, j);
                if (!connected) {
                    var k: usize = 0;
                    while (k < m) : (k += 1) {
                        if (mask & (@as(usize, 1) << @intCast(k)) == 0) continue;
                        if (self.joinConnects(pending.items[k].table, pending.items[k].alias, j)) {
                            connected = true;
                            break;
                        }
                    }
                }
                if (!connected) continue;
                const rn: f64 = @floatFromInt((self.find(j.table) orelse continue).rows.items.len);
                const ndv = self.joinNdv(j, lname, sel.where, key_rng[mask]);
                const base_sel: f64 = if (ndv > 0) 1.0 / ndv else 0.1;
                // Adaptive correction learned from previously executed plans.
                const jsel: f64 = base_sel * self.selCorrection(j.table);
                if (std.c.getenv("ZHDB_DBG_DP") != null) {
                    std.debug.print("[dp] mask={d} +{s} ndv={d:.1} rng={any} jsel={d:.6}\n", .{ mask, j.table, ndv, key_rng[mask], jsel });
                }
                // Duplicate-aware estimate: combine the partial result's key
                // distribution with the new input's, if both are available and
                // the connecting key is the one the distribution describes.
                const nxt = mask | bit;
                // A mask containing multi-key joins has residuals applied at
                // the step that added them; shape/class fan-outs would recompute
                // the multiplicity without those residuals, so use the scaled
                // pair estimate (which scales the already-correct mask rows).
                var mask_has_extra = false;
                var me: usize = 0;
                while (me < m) : (me += 1) {
                    if (mask & (@as(usize, 1) << @intCast(me)) == 0) continue;
                    if (pending.items[me].extra_eqs.len > 0) {
                        mask_has_extra = true;
                        break;
                    }
                }
                var cand_kd = KeyDist{};
                var new_rows: f64 = 0;
                var dup_ok = false;
                var dp_rows_set = false;
                var ct_name_o: ?[]const u8 = null;
                var ct_alias_o: ?[]const u8 = null;
                if (j.on.* == .binary) {
                    var ct_name: []const u8 = lname;
                    var ct_alias: ?[]const u8 = sel.alias;
                    var ct_ok = self.joinConnects(lname, sel.alias, j);
                    if (!ct_ok) {
                        var kk: usize = 0;
                        while (kk < m) : (kk += 1) {
                            if (mask & (@as(usize, 1) << @intCast(kk)) == 0) continue;
                            if (self.joinConnects(pending.items[kk].table, pending.items[kk].alias, j)) {
                                ct_name = pending.items[kk].table;
                                ct_alias = pending.items[kk].alias;
                                ct_ok = true;
                                break;
                            }
                        }
                    }
                    if (ct_ok) {
                        ct_name_o = ct_name;
                        ct_alias_o = ct_alias;
                        if (self.find(ct_name)) |ctt| {
                            if (self.find(j.table)) |jtt| {
                                if (keyColOfJoin(ctt, ct_name, ct_alias, j.on)) |ck| {
                                    if (keyColOfJoin(jtt, j.table, j.alias, j.on)) |jk| {
                                        const jd = self.baseKeyDist(j.table, jk, self.whereSelectivity(j.table, sel.where));
                                        var ld = KeyDist{};
                                        var scaled_from = false;
                                        var exact_pair: ?KeyDist = null;
                                        if (mask == 0) {
                                            if (self.find(lname)) |ltx| {
                                                if (self.exactJoinedDist(ltx, ck, jtt, jk)) |ed| exact_pair = ed;
                                            }
                                            ld = if (exact_pair) |ed| ed else self.baseKeyDist(lname, ck, self.whereSelectivity(lname, sel.where));
                                        } else if (!mask_has_extra and kd[mask].valid and keyDistKnows(kd[mask], ct_name, ck)) {
                                            // Same key: continue over exact class
                                            // counts instead of the top-48 sketch.
                                            if (self.classJoinPairs(kd[mask].members[0..kd[mask].nm], jtt, jk)) |jn| {
                                                cand_kd = jn.kd;
                                                new_rows = jn.pairs;
                                                dup_ok = true;
                                                dp_rows_set = true;
                                                scaled_from = true;
                                            } else {
                                                ld = kd[mask];
                                            }
                                        } else if (mask != 0) {
                                            // Qualified provenance: the connecting
                                            // column belongs to `ct_name` but the
                                            // partial result tracks a different key.
                                            // Build the switched column's distribution
                                            // from the base rows, weighting each row by
                                            // its per-key fan-out (no uniform
                                            // multiplicity assumption); fall back to
                                            // uniform scaling when unavailable.
                                            var got = false;
                                            const allow_scan = std.c.getenv("ZHDB_NO_FANOUT") == null;
                                            // Mask-shaped fan-out is independent of
                                            // which key the partial result tracks, so
                                            // try it once before the per-key paths.
                                            if (allow_scan and mask_has_extra) {
                                                // Multi-key masks: exact tuple-indexed
                                                // star fan-out, which honours the extra
                                                // equalities (no uniform multiplicity).
                                                if (self.multiKeyStarFanout(ct_name, ct_alias, lname, sel.alias, pending.items, mask, m, ck, jtt, jk)) |jn| {
                                                    cand_kd = jn.kd;
                                                    new_rows = jn.pairs;
                                                    dup_ok = true;
                                                    dp_rows_set = true;
                                                    scaled_from = true;
                                                    got = true;
                                                } else if (self.multiKeyTreeFanout(ct_name, ct_alias, lname, sel.alias, pending.items, mask, m, ck, jtt, jk)) |jn| {
                                                    cand_kd = jn.kd;
                                                    new_rows = jn.pairs;
                                                    dup_ok = true;
                                                    dp_rows_set = true;
                                                    scaled_from = true;
                                                    got = true;
                                                }
                                            } else if (allow_scan) {
                                                // The general tree factorisation is exact for any
                                                // mask shape and never depends on the top-48 key
                                                // sketch, so it is the primary path for a switch
                                                // to a different column.
                                                if (self.treeFanoutJoin(ct_name, ct_alias, lname, sel.alias, pending.items, mask, m, ck, jtt, jk)) |jn| {
                                                    cand_kd = jn.kd;
                                                    new_rows = jn.pairs;
                                                    dup_ok = true;
                                                    dp_rows_set = true;
                                                    scaled_from = true;
                                                    got = true;
                                                } else if (self.maskFanoutJoin(ct_name, ct_alias, lname, sel.alias, pending.items, mask, m, ck, jtt, jk)) |jn| {
                                                    cand_kd = jn.kd;
                                                    new_rows = jn.pairs;
                                                    dup_ok = true;
                                                    dp_rows_set = true;
                                                    scaled_from = true;
                                                    got = true;
                                                } else if (self.hubFanoutJoin(ct_name, ct_alias, lname, sel.alias, pending.items, mask, m, ck, jtt, jk)) |jn| {
                                                    cand_kd = jn.kd;
                                                    new_rows = jn.pairs;
                                                    dup_ok = true;
                                                    dp_rows_set = true;
                                                    scaled_from = true;
                                                    got = true;
                                                }
                                            }
                                            for (kd[mask].members[0..kd[mask].nm]) |mem| {
                                                if (got) break;
                                                if (!allow_scan or mask_has_extra) break;
                                                if (!std.ascii.eqlIgnoreCase(mem.t, ct_name)) continue;
                                                if (mem.c == ck) continue;
                                                if (self.switchedJoinPairs(ctt, kd[mask].members[0..kd[mask].nm], mem.c, ck, jtt, jk)) |jn| {
                                                    cand_kd = jn.kd;
                                                    new_rows = jn.pairs;
                                                    dup_ok = true;
                                                    dp_rows_set = true;
                                                    scaled_from = true;
                                                    got = true;
                                                    break;
                                                }
                                                if (self.switchedKeyDist(ctt, kd[mask], mem.c, ck)) |sd| {
                                                    ld = sd;
                                                    got = true;
                                                    break;
                                                }
                                            }
                                            if (!got) {
                                                const bd = self.baseKeyDist(ct_name, ck, 1.0);
                                                const ct_rows: f64 = @floatFromInt(ctt.rows.items.len);
                                                if (bd.valid and ct_rows > 0 and rows[mask] > 0) {
                                                    ld = scaleKeyDist(bd, rows[mask] / ct_rows);
                                                    scaled_from = true;
                                                }
                                            } else {
                                                scaled_from = true;
                                            }
                                        }
                                        if (exact_pair) |ed| {
                                            cand_kd = ed;
                                            new_rows = ed.rows;
                                            dup_ok = true;
                                            dp_rows_set = true;
                                        } else if (!dup_ok and !dp_rows_set and !mask_has_extra and ld.valid and mask != 0 and scaled_from) {
                                            // Switched column: join the scaled
                                            // distribution against the exact base
                                            // encoding of the new table.
                                            if (self.joinDistWithBase(ld, jtt, jk)) |jn| {
                                                cand_kd = jn.kd;
                                                new_rows = jn.pairs;
                                                dup_ok = true;
                                                dp_rows_set = true;
                                            }
                                        }
                                        if (!dup_ok and !dp_rows_set and ld.valid and jd.valid) {
                                            cand_kd = joinKeyDist(ld, jd);
                                            if (cand_kd.valid) {
                                                new_rows = cand_kd.rows;
                                                dup_ok = true;
                                                // Exact product only when no
                                                // multiplicity scaling is involved
                                                // (encodings describe base counts).
                                                if (!cand_kd.scaled and !scaled_from) {
                                                    if (self.exactKeyProduct(cand_kd.members[0..cand_kd.nm], sel.where)) |prod| {
                                                        new_rows = prod;
                                                        if (std.c.getenv("ZHDB_DBG_DP") != null) {
                                                            std.debug.print("[dp] exact-product members={d} -> {d:.0}\n", .{ cand_kd.nm, prod });
                                                        }
                                                    } else if (std.c.getenv("ZHDB_DBG_DP") != null) {
                                                        std.debug.print("[dp] exact-product null members={d}\n", .{cand_kd.nm});
                                                    }
                                                }
                                                if (scaled_from and std.c.getenv("ZHDB_DBG_DP") != null) {
                                                    const ctr: f64 = @floatFromInt(ctt.rows.items.len);
                                                    std.debug.print("[dp] prov-scaled ct={s} ck={d} mult={d:.3} members={d} -> {d:.0}\n", .{
                                                        ct_name, ck, if (ctr > 0) rows[mask] / ctr else 1, cand_kd.nm, new_rows,
                                                    });
                                                }
                                            }
                                        }
                                        if (!dup_ok) {
                                            // The connecting column is not the one the
                                            // partial result's key distribution tracks
                                            // (e.g. joining on `d.j` after `f.k=d.k`).
                                            // Use exact base-base pairs scaled by how many
                                            // times the connecting table appears so far.
                                            if (self.estimateJoinPairs(ctt, ck, jtt, jk)) |pe| {
                                                const ct_rows: f64 = @floatFromInt(ctt.rows.items.len);
                                                if (ct_rows > 0) {
                                                    new_rows = pe * rows[mask] / ct_rows *
                                                        self.whereSelectivity(j.table, sel.where);
                                                    dp_rows_set = true;
                                                    if (std.c.getenv("ZHDB_DBG_DP") != null) {
                                                        std.debug.print("[dp] pair-scaled +{s} pairs={d:.0} rows={d:.0}\n", .{ j.table, pe, new_rows });
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // Cost = sum of intermediate result sizes (materialisation work);
                // the final result size does not depend on the order.
                if (!dup_ok and !dp_rows_set) new_rows = rows[mask] * rn * self.whereSelectivity(j.table, sel.where) * jsel;
                if (j.extra_eqs.len > 0) {
                    if (ct_name_o) |ctn| {
                        if (self.find(ctn)) |ctt2| {
                            if (self.find(j.table)) |jtt2| {
                                new_rows *= self.extraEstimate(
                                    alloc,
                                    j,
                                    ctt2,
                                    ctn,
                                    ct_alias_o,
                                    null,
                                    jtt2,
                                    j.table,
                                    j.alias,
                                );
                            }
                        }
                    }
                }
                if (std.c.getenv("ZHDB_DBG_DP") != null) {
                    std.debug.print("[dp] dup mask={d} +{s} ok={} rows={d:.0}\n", .{ mask, j.table, dup_ok, new_rows });
                }
                const c = cost[mask] + new_rows;
                // Tie-break: deterministic preference for the smaller input.
                const better = c < cost[nxt] - 1e-9 or
                    (@abs(c - cost[nxt]) <= 1e-9 and rn < tie[nxt]);
                if (better) {
                    cost[nxt] = c;
                    rows[nxt] = new_rows;
                    tie[nxt] = rn;
                    prev[nxt] = @intCast(mask);
                    added[nxt] = @intCast(i);
                    kd[nxt] = if (dup_ok) cand_kd else .{};
                    var rng: ?[2]i64 = key_rng[mask];
                    if (rng == null) {
                        if (self.find(lname)) |lt3| {
                            const lk = keyCol(lt3, j.on.binary.lhs) orelse keyCol(lt3, j.on.binary.rhs);
                            if (lk) |k3| {
                                if (k3 < lt3.stats.len and lt3.stats[k3].ndv > 0) rng = .{ lt3.stats[k3].min, lt3.stats[k3].max };
                            }
                        }
                    }
                    if (self.find(j.table)) |jt| {
                        const rk = keyCol(jt, j.on.binary.lhs) orelse keyCol(jt, j.on.binary.rhs);
                        if (rk) |k4| {
                            if (k4 < jt.stats.len and jt.stats[k4].ndv > 0) {
                                const rmin = jt.stats[k4].min;
                                const rmax = jt.stats[k4].max;
                                rng = if (rng) |r0| .{ @max(r0[0], rmin), @min(r0[1], rmax) } else .{ rmin, rmax };
                            }
                        }
                    }
                    key_rng[nxt] = rng;
                }
            }
        }
        const full: usize = nmask - 1;
        if (std.math.isInf(cost[full])) return error.UnsupportedJoin;
        // Reconstruct the order (reverse).
        var seq = std.ArrayList(usize).empty;
        defer seq.deinit(self.gpa);
        var walk: usize = full;
        while (walk != 0) {
            try seq.append(self.gpa, added[walk]);
            walk = prev[walk];
        }
        std.mem.reverse(usize, seq.items);

        var cur: []const u8 = lname;
        var cur_tmp = false;
        var cur_range: ?[2]i64 = null;
        // Qualifier -> column mapping of the current input (updated per step).
        var cur_quals = std.ArrayList(ChainQual).empty;
        defer cur_quals.deinit(self.gpa);
        if (self.find(lname)) |lt0| {
            for (lt0.cols, 0..) |_, ci0| {
                if (sel.alias) |al| cur_quals.append(self.gpa, .{ .qual = al, .col = ci0 }) catch {};
                cur_quals.append(self.gpa, .{ .qual = lname, .col = ci0 }) catch {};
            }
        }
        // The executor's own step estimate (per-key statistics), reported at the
        // end; the DP figure above is the pre-execution ordering estimate.
        var exec_est: f64 = rows[full];
        var order = std.ArrayList([]const u8).empty;
        defer order.deinit(self.gpa);
        try order.append(self.gpa, lname);
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] join dp tables={d} est_rows={d:.0} work={d:.0}\n", .{ m + 1, rows[full], cost[full] });
        }
        for (seq.items, 0..) |i, step_idx| {
            const j = pending.items[i];
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[plan] join step {s} + {s}\n", .{ cur, j.table });
            }
            // Resolve `cur`-side qualified references to explicit temp column
            // indexes so neither the executor nor the stream-aggregate tail can
            // suffix-match a same-named column from another input (`d.j` vs an
            // earlier `f.j`).
            var j2 = j;
            if (j.on.* == .binary and j.on.binary.op == .eq) {
                if (self.find(cur)) |cur_t0| {
                    const lci = chainQualCol(cur_t0, cur_quals.items, j.on.binary.lhs);
                    const rci = chainQualCol(cur_t0, cur_quals.items, j.on.binary.rhs);
                    const which_left = (lci != null and rci == null);
                    const pick: ?usize = if (which_left) lci else if (rci != null and lci == null) rci else null;
                    if (pick) |idx| {
                        if (sql.cloneExpr(alloc, j.on)) |on2| {
                            if (alloc.create(sql.Expr)) |nd| {
                                const orig = if (which_left) j.on.binary.lhs else j.on.binary.rhs;
                                const nm: []const u8 = switch (orig.*) {
                                    .column => |x| x,
                                    else => "",
                                };
                                nd.* = .{ .column_idx = .{ .idx = @intCast(idx), .name = nm } };
                                if (which_left) on2.binary.lhs = nd else on2.binary.rhs = nd;
                                j2 = .{
                                    .table = j.table,
                                    .on = on2,
                                    .left = j.left,
                                    .right = j.right,
                                    .alias = j.alias,
                                    .extra_eqs = j.extra_eqs,
                                };
                            } else |_| {}
                        } else |_| {}
                    }
                }
            }
            // Last step + aggregate-only query: aggregate while probing instead
            // of materialising the joined result (no `__join_N` for the tail).
            const is_last = step_idx + 1 == seq.items.len;
            if (is_last and std.c.getenv("ZHDB_NO_CHAIN_STREAM") == null and
                sel.where == null and sel.having == null and !sel.distinct and selWantsView(sel))
            {
                var agg_sel = sel.*;
                agg_sel.from = .{ .table = cur };
                agg_sel.join = j2;
                agg_sel.more_joins = &.{};
                if (self.find(cur)) |lt2| {
                    if (self.find(j.table)) |rt2| {
                        if (try self.joinAggregate(alloc, &agg_sel, j2, cur, lt2, rt2)) |res| {
                            // A plain aggregate over an empty input must still emit
                            // one row (COUNT(*)=0, SUM=NULL, ...). The fused tail
                            // only initialises accumulators on a match, so fall
                            // through to the materialised path in that case.
                            const needs_empty_row = res.rows.len == 0 and
                                sel.group_by.len == 0 and sel.having == null;
                            if (!needs_empty_row) {
                                if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                                    std.debug.print("[plan] join stream-aggregate tail rows={d}\n", .{res.rows.len});
                                }
                                if (cur_tmp) self.dropJoinTemp(cur);
                                return res;
                            }
                        }
                    }
                }
            }
            var step = sel.*;
            step.from = .{ .table = cur };
            step.join = j2;
            step.more_joins = &.{};
            step.where = null;
            step.group_by = &.{};
            step.having = null;
            step.order_by = &.{};
            step.limit = null;
            step.offset = null;
            const cur_t = self.find(cur) orelse return error.TableNotFound;
            const next_t = self.find(j.table) orelse return error.TableNotFound;
            const cur_rows: f64 = @floatFromInt(cur_t.rows.items.len);
            const rn2: f64 = @floatFromInt(next_t.rows.items.len);
            const ndv2 = self.joinNdvAlias(j, lname, sel.where, cur_range, if (std.ascii.eqlIgnoreCase(cur, lname)) sel.alias else null, j.alias);
            const base2: f64 = if (ndv2 > 0) 1.0 / ndv2 else 0.1;
            // The inputs are filtered before hashing (predicate pushdown), so the
            // step estimate must apply the same local selectivity. Temp tables
            // already carry their filters (whereSelectivity returns 1).
            const cur_sel = self.whereSelectivity(cur, sel.where);
            const next_sel = self.whereSelectivity(j.table, sel.where);
            // Per-key frequency estimate (Σ f_l·f_r) when both inputs carry
            // MCV/ndv statistics — chained intermediates get them on creation.
            var pair_est: ?f64 = null;
            if (j.on.* == .binary) {
                const lk = chainQualCol(cur_t, cur_quals.items, j.on.binary.lhs) orelse
                    chainQualCol(cur_t, cur_quals.items, j.on.binary.rhs);
                // Resolve the new input's side by **qualifier**: `b.j = c.k`
                // must pick column `k` of `c`, not `j` of `c` just because the
                // name exists there too (self-joins share every column name).
                const rl = colOfSide(next_t, j.table, j.alias, j.on.binary.lhs);
                const rr = colOfSide(next_t, j.table, j.alias, j.on.binary.rhs);
                const rk = rl orelse rr;
                if (lk != null and rk != null) {
                    pair_est = self.estimateJoinPairs(cur_t, lk.?, next_t, rk.?);
                }
            }
            var step_est = if (pair_est) |pe|
                // Measured pair count already reflects the key frequencies, so
                // no learned correction is applied.
                pe * cur_sel * next_sel
            else
                cur_rows * cur_sel * rn2 * next_sel * base2 * self.selCorrection(j.table);
            if (j.extra_eqs.len > 0) {
                const lalias2: ?[]const u8 = if (std.ascii.eqlIgnoreCase(cur, lname)) sel.alias else null;
                step_est *= self.extraEstimate(
                    alloc,
                    j,
                    cur_t,
                    cur,
                    lalias2,
                    cur_quals.items,
                    next_t,
                    j.table,
                    j.alias,
                );
            }
            exec_est = step_est;
            var cur_filt: ?*sql.Expr = null;
            for (filter_names.items, 0..) |nm2, fi| {
                if (std.ascii.eqlIgnoreCase(nm2, cur)) {
                    cur_filt = join_filters[fi];
                    break;
                }
            }
            var next_filt: ?*sql.Expr = null;
            for (filter_names.items, 0..) |nm2, fi| {
                if (std.ascii.eqlIgnoreCase(nm2, j.table)) {
                    next_filt = join_filters[fi];
                    break;
                }
            }
            if (j.left or j.right) {
                cur_filt = null;
                next_filt = null;
            }
            _ = try self.execJoinImpl(alloc, &step, j2, false, cur_filt, next_filt, cur_quals.items);
            const next = tls_kept_join orelse return error.UnsupportedJoin;
            const step_actual: usize = if (self.tempTables().get(next)) |tp| tp.rows.items.len else 0;
            self.recordJoinFeedback(j.table, step_est, step_actual);
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[plan] join step {s} est={d:.0} actual={d} sel_corr={d:.3}\n", .{
                    j.table, step_est, step_actual, self.selCorrection(j.table),
                });
            }
            // Track the intermediate's key range: intersection of both inputs.
            if (self.find(j.table)) |jt| {
                const rk = keyCol(jt, j.on.binary.lhs) orelse keyCol(jt, j.on.binary.rhs);
                if (rk) |k4| {
                    if (k4 < jt.stats.len and jt.stats[k4].ndv > 0) {
                        if (cur_range == null) {
                            if (self.find(cur)) |lt3| {
                                const lk = keyCol(lt3, j.on.binary.lhs) orelse keyCol(lt3, j.on.binary.rhs);
                                if (lk) |k3| {
                                    if (k3 < lt3.stats.len and lt3.stats[k3].ndv > 0) cur_range = .{ lt3.stats[k3].min, lt3.stats[k3].max };
                                }
                            }
                        }
                        const rmin = jt.stats[k4].min;
                        const rmax = jt.stats[k4].max;
                        cur_range = if (cur_range) |r0| .{ @max(r0[0], rmin), @min(r0[1], rmax) } else .{ rmin, rmax };
                    }
                }
            }
            // The temp's columns are [current input cols..., next input cols...];
            // remember which qualifier owns each so later steps resolve by side.
            {
                const base_len = cur_t.cols.len;
                if (j.alias) |al| {
                    for (next_t.cols, 0..) |_, ci1| {
                        cur_quals.append(self.gpa, .{ .qual = al, .col = base_len + ci1 }) catch {};
                    }
                }
                for (next_t.cols, 0..) |_, ci1| {
                    cur_quals.append(self.gpa, .{ .qual = j.table, .col = base_len + ci1 }) catch {};
                }
            }
            if (cur_tmp) self.dropJoinTemp(cur);
            cur = next;
            cur_tmp = true;
            try order.append(self.gpa, j.table);
        }
        // Estimated vs actual intermediate size.
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            const actual = if (self.tempTables().get(cur)) |tp| tp.rows.items.len else 0;
            std.debug.print("[plan] join rows est={d:.0} actual={d} (dp est {d:.0})\n", .{ exec_est, actual, rows[full] });
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] join order:", .{});
            for (order.items) |nm2| std.debug.print(" {s}", .{nm2});
            std.debug.print("\n", .{});
        }
        defer if (cur_tmp) self.dropJoinTemp(cur);

        var final = sel.*;
        final.from = .{ .table = cur };
        final.join = null;
        final.more_joins = &.{};
        return self.execSelect(alloc, &final, true);
    }

    /// Collect statistics on demand (used by the planner so ndv is available
    /// without a manual ANALYZE).
    fn ensureStats(self: *Engine, name: []const u8) void {
        const t = self.find(name) orelse return;
        if (t.stats.len == t.cols.len and t.rows.items.len > 0) return;
        _ = self.execAnalyze(name) catch {};
    }

    /// Does `j`'s ON predicate relate the current result `cur` to `j.table`?
    /// Qualifiers are honoured, so `d.j = e.j` does not "connect" a table `f`
    /// that merely has its own `j` column.
    fn joinConnects(self: *Engine, cur: []const u8, cur_alias: ?[]const u8, j: sql.Join) bool {
        if (j.on.* != .binary or j.on.binary.op != .eq) return false;
        const lt = self.find(cur) orelse return false;
        const rt = self.find(j.table) orelse return false;
        const a_in_cur = colOfSide(lt, cur, cur_alias, j.on.binary.lhs) != null;
        const b_in_cur = colOfSide(lt, cur, cur_alias, j.on.binary.rhs) != null;
        const a_in_new = colOfSide(rt, j.table, j.alias, j.on.binary.lhs) != null;
        const b_in_new = colOfSide(rt, j.table, j.alias, j.on.binary.rhs) != null;
        return (a_in_cur and b_in_new) or (b_in_cur and a_in_new);
    }

    /// Distinct-value estimate of the join key (ANALYZE stats, else 1/10 of rows).
    /// Join-key ndv estimate. Standard practice is `1/max(ndv_l, ndv_r)`: the
    /// side with more distinct values dominates the result size.
    /// Column of `table` named by `e` (qualifier must match when present).
    fn tableColOf(self: *Engine, table: []const u8, e: *sql.Expr) ?usize {
        return self.tableColOfAlias(table, e, null);
    }

    /// Alias-aware column resolution: `qualifier.col` matches either the table
    /// name or this side's alias (self-joins keep two aliases of one table).
    fn tableColOfAlias(self: *Engine, table: []const u8, e: *sql.Expr, alias: ?[]const u8) ?usize {
        const t = self.find(table) orelse return null;
        return switch (e.*) {
            .column => |name| blk: {
                if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                    const q = name[0..dot];
                    const ok = std.ascii.eqlIgnoreCase(q, table) or
                        (alias != null and std.ascii.eqlIgnoreCase(q, alias.?));
                    if (!ok) break :blk null;
                    break :blk findCol(t, name[dot + 1 ..]);
                }
                break :blk findCol(t, name);
            },
            .column_idx => |c| c.idx,
            else => null,
        };
    }

    fn isLiteral(e: *sql.Expr) bool {
        return e.* == .int or e.* == .float or e.* == .string or e.* == .null_lit;
    }

    /// First equality predicate on `table`'s column (the join-key + local
    /// predicate combination whose composite ndv refines join cardinality).
    fn filterEqCol(self: *Engine, where: ?*sql.Expr, table: []const u8) ?usize {
        return self.filterEqColAlias(where, table, null);
    }

    fn filterEqColAlias(self: *Engine, where: ?*sql.Expr, table: []const u8, alias: ?[]const u8) ?usize {
        const e = where orelse return null;
        switch (e.*) {
            .binary => |b| {
                if (b.op == .and_op) {
                    return self.filterEqColAlias(b.lhs, table, alias) orelse self.filterEqColAlias(b.rhs, table, alias);
                }
                if (b.op != .eq) return null;
                if (self.tableColOfAlias(table, b.lhs, alias)) |ci| {
                    if (isLiteral(b.rhs)) return ci;
                }
                if (self.tableColOfAlias(table, b.rhs, alias)) |ci| {
                    if (isLiteral(b.lhs)) return ci;
                }
                return null;
            },
            else => return null,
        }
    }

    /// Collect the tables referenced by one conjunct. `ok=false` means the
    /// conjunct is ambiguous or references something we do not push.
    fn exprTables(self: *Engine, e: *sql.Expr, names: []const []const u8, owner: *?usize, ok: *bool) void {
        if (!ok.*) return;
        switch (e.*) {
            .column => |name| {
                var idx: ?usize = null;
                if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                    for (names, 0..) |nm, i| {
                        if (std.ascii.eqlIgnoreCase(nm, name[0..dot])) {
                            idx = i;
                            break;
                        }
                    }
                    if (idx == null) {
                        ok.* = false;
                        return;
                    }
                    if (self.find(names[idx.?])) |t| {
                        if (findCol(t, name[dot + 1 ..]) == null) {
                            ok.* = false;
                            return;
                        }
                    }
                } else {
                    var count: usize = 0;
                    for (names, 0..) |nm, i| {
                        if (self.find(nm)) |t| {
                            if (findCol(t, name) != null) {
                                count += 1;
                                idx = i;
                            }
                        }
                    }
                    if (count != 1) {
                        ok.* = false;
                        return;
                    }
                }
                if (owner.*) |o| {
                    if (o != idx.?) ok.* = false;
                } else owner.* = idx;
            },
            .column_idx => ok.* = false,
            .binary => |b| {
                self.exprTables(b.lhs, names, owner, ok);
                self.exprTables(b.rhs, names, owner, ok);
            },
            .negate => |x| self.exprTables(x, names, owner, ok),
            .not => |x| self.exprTables(x, names, owner, ok),
            .is_null => |x| self.exprTables(x.operand, names, owner, ok),
            .like => |x| {
                self.exprTables(x.operand, names, owner, ok);
                self.exprTables(x.pattern, names, owner, ok);
            },
            .in_list => |x| {
                self.exprTables(x.operand, names, owner, ok);
                for (x.items) |it| self.exprTables(it, names, owner, ok);
            },
            .between => |x| {
                self.exprTables(x.operand, names, owner, ok);
                self.exprTables(x.low, names, owner, ok);
                self.exprTables(x.high, names, owner, ok);
            },
            .call => |c| for (c.args) |a| self.exprTables(a, names, owner, ok),
            .in_subquery, .exists, .star, .star_table => ok.* = false,
            else => {},
        }
    }

    fn assignConjuncts(self: *Engine, alloc: std.mem.Allocator, e: *sql.Expr, names: []const []const u8, out: []?*sql.Expr) !void {
        switch (e.*) {
            .binary => |b| {
                if (b.op == .and_op) {
                    try self.assignConjuncts(alloc, b.lhs, names, out);
                    try self.assignConjuncts(alloc, b.rhs, names, out);
                    return;
                }
            },
            else => {},
        }
        var owner: ?usize = null;
        var ok = true;
        self.exprTables(e, names, &owner, &ok);
        if (!ok or owner == null) return;
        const i = owner.?;
        if (out[i]) |prev| {
            const n = try alloc.create(sql.Expr);
            n.* = .{ .binary = .{ .op = .and_op, .lhs = prev, .rhs = e } };
            out[i] = n;
        } else out[i] = e;
    }

    /// Build one AND-filter per input table from the WHERE conjuncts, so join
    /// scans produce the same (filtered) rows the planner estimated instead of
    /// materialising everything and filtering at the end.
    fn buildJoinFilters(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select, names: []const []const u8) ![]?*sql.Expr {
        const out = try alloc.alloc(?*sql.Expr, names.len);
        @memset(out, null);
        if (sel.where) |w| try self.assignConjuncts(alloc, w, names, out);
        // Bind each input's predicate to that table's column indexes **once**;
        // the shared WHERE tree stays untouched for the final SELECT.
        if (std.c.getenv("ZHDB_NO_JOIN_BIND") == null) {
            for (out, 0..) |maybe, i| {
                const tree = maybe orelse continue;
                const t = self.find(names[i]) orelse {
                    out[i] = null;
                    continue;
                };
                const copy = sql.cloneExpr(alloc, tree) catch {
                    out[i] = null;
                    continue;
                };
                bindExpr(copy, t.cols) catch {
                    out[i] = null;
                    continue;
                };
                out[i] = copy;
            }
        }
        return out;
    }

    /// Equality selectivity from MCVs (fallback: uniform over the remaining ndv).
    fn statEqSel(st: ColStat, k: i64) f64 {
        for (st.mcv) |m| {
            if (m.v == k) return m.freq;
        }
        const rest = @as(f64, @floatFromInt(@max(st.ndv - st.mcv.len, 1)));
        return @max(1.0 - st.mcv_mass, 1e-9) / rest;
    }

    /// CDF P(x < k) from the equi-depth histogram (fallback 0.5).
    fn statLtFrac(st: ColStat, k: i64) f64 {
        if (st.hist.len < 2) return 0.5;
        var lo: usize = 0;
        while (lo < st.hist.len and st.hist[lo] < k) : (lo += 1) {}
        const denom: f64 = @floatFromInt(st.hist.len - 1);
        return std.math.clamp(@as(f64, @floatFromInt(lo)) / denom, 0.0, 1.0);
    }

    /// String equality selectivity from string MCVs.
    fn statStrEqSel(st: ColStat, s: []const u8) f64 {
        for (st.mcv_str) |m| {
            if (std.mem.eql(u8, m.s, s)) return m.freq;
        }
        const rest = @as(f64, @floatFromInt(@max(st.ndv - st.mcv_str.len, 1)));
        return @max(1.0 - st.mcv_str_mass, 1e-9) / rest;
    }

    /// CDF P(x < s) over the lexicographic equi-depth histogram.
    fn statStrLtFrac(st: ColStat, s: []const u8) f64 {
        if (st.hist_str.len < 2) return 0.5;
        var lo: usize = 0;
        while (lo < st.hist_str.len and std.mem.order(u8, st.hist_str[lo], s) == .lt) : (lo += 1) {}
        const denom: f64 = @floatFromInt(st.hist_str.len - 1);
        return std.math.clamp(@as(f64, @floatFromInt(lo)) / denom, 0.0, 1.0);
    }

    /// First equality predicate on `table` together with its literal value.
    fn filterEqLit(self: *Engine, where: ?*sql.Expr, table: []const u8) ?struct { ci: usize, lit: Value } {
        return self.filterEqLitAlias(where, table, null);
    }

    fn filterEqLitAlias(self: *Engine, where: ?*sql.Expr, table: []const u8, alias: ?[]const u8) ?struct { ci: usize, lit: Value } {
        const e = where orelse return null;
        switch (e.*) {
            .binary => |b| {
                if (b.op == .and_op) {
                    return self.filterEqLitAlias(b.lhs, table, alias) orelse self.filterEqLitAlias(b.rhs, table, alias);
                }
                if (b.op != .eq) return null;
                if (self.tableColOfAlias(table, b.lhs, alias)) |ci| {
                    if (b.rhs.* == .int) return .{ .ci = ci, .lit = .{ .int = b.rhs.int } };
                    if (b.rhs.* == .string) return .{ .ci = ci, .lit = .{ .text = b.rhs.string } };
                }
                if (self.tableColOfAlias(table, b.rhs, alias)) |ci| {
                    if (b.lhs.* == .int) return .{ .ci = ci, .lit = .{ .int = b.lhs.int } };
                    if (b.lhs.* == .string) return .{ .ci = ci, .lit = .{ .text = b.lhs.string } };
                }
                return null;
            },
            else => return null,
        }
    }

    /// Sampled frequency of one value (MCV lookup, else residual/uniform).
    fn statFreqOf(st: ColStat, lit: Value) f64 {
        switch (lit) {
            .int => |v| {
                for (st.mcv) |m| {
                    if (m.v == v) return m.freq;
                }
                const rest = @as(f64, @floatFromInt(@max(st.ndv - st.mcv.len, 1)));
                return @max(1.0 - st.mcv_mass, 1e-9) / rest;
            },
            .text => |s| {
                for (st.mcv_str) |m| {
                    if (std.mem.eql(u8, m.s, s)) return m.freq;
                }
                const rest = @as(f64, @floatFromInt(@max(st.ndv - st.mcv_str.len, 1)));
                return @max(1.0 - st.mcv_str_mass, 1e-9) / rest;
            },
            else => return 1e-9,
        }
    }

    fn ngramFreq(st: ColStat, a: u8, b: u8, c: u8) ?f64 {
        for (st.ngram) |n| {
            if (n.g[0] == a and n.g[1] == b and n.g[2] == c) return n.freq;
        }
        return null;
    }

    fn suffixFreq(st: ColStat, s: []const u8) ?f64 {
        if (s.len == 0 or s.len > 3) return null;
        for (st.suf) |e| {
            if (e.len != s.len) continue;
            var ok = true;
            for (s, 0..) |ch, i| {
                if (e.s[i] != ch) {
                    ok = false;
                    break;
                }
            }
            if (ok) return e.freq;
        }
        return null;
    }

    fn runSel(st: ColStat, run: []const u8) f64 {
        if (run.len >= 3) {
            var sel: f64 = 1.0;
            var found: usize = 0;
            var k: usize = 0;
            while (k + 3 <= run.len) : (k += 1) {
                if (ngramFreq(st, run[k], run[k + 1], run[k + 2])) |f| {
                    if (f > 0) {
                        if (found == 0 or f < sel) sel = f;
                        found += 1;
                    }
                }
            }
            if (found > 0) return sel;
        }
        if (suffixFreq(st, run)) |f| return f;
        return 0.05;
    }

    /// Infix/suffix LIKE: split into literal runs; the longest run gives the main
    /// selectivity and a short trailing run (e.g. `%google_5`, `_` = wildcard) is
    /// multiplied in via suffix n-gram frequencies.
    fn statInfixLikeSel(st: ColStat, pat: []const u8) f64 {
        var best: []const u8 = "";
        var last: []const u8 = "";
        var start: usize = 0;
        var i: usize = 0;
        while (i <= pat.len) : (i += 1) {
            if (i == pat.len or pat[i] == '%' or pat[i] == '_') {
                const run = pat[start..i];
                if (run.len > 0) last = run;
                if (run.len > best.len) best = run;
                start = i + 1;
            }
        }
        if (best.len == 0) return 1.0;
        var sel = runSel(st, best);
        // A short trailing literal run (e.g. `%google_5`, `_` = wildcard) is
        // combined multiplicatively via suffix n-gram frequencies.
        if (last.len > 0 and last.len <= 3 and !std.mem.eql(u8, last, best)) {
            if (suffixFreq(st, last)) |tf| sel *= tf;
        }
        return std.math.clamp(sel, 1e-4, 1.0);
    }

    /// LIKE selectivity: exact pattern -> equality; `prefix%` -> lexicographic
    /// interval from the histogram (plus MCV prefix mass); other shapes -> 0.1.
    fn statLikeSel(st: ColStat, pat: []const u8) f64 {
        var star: ?usize = null;
        for (pat, 0..) |ch, i| {
            if (ch == '%' or ch == '_') {
                star = i;
                break;
            }
        }
        const sp = star orelse return statStrEqSel(st, pat);
        // Infix/suffix or embedded wildcards: trigram estimate.
        if (sp == 0 or sp + 1 != pat.len or pat[sp] != '%') return statInfixLikeSel(st, pat);
        const prefix = pat[0..sp];
        if (prefix.len == 0) return 1.0;
        // Smallest string greater than every string with this prefix: increment
        // the last byte that can be incremented.
        var buf: [256]u8 = undefined;
        if (prefix.len > buf.len) return 0.1;
        @memcpy(buf[0..prefix.len], prefix);
        var ulen = prefix.len;
        while (ulen > 0) {
            ulen -= 1;
            if (buf[ulen] < 0xFF) {
                buf[ulen] += 1;
                ulen += 1;
                break;
            }
        }
        if (ulen == 0) return 1.0;
        const upper = buf[0..ulen];
        const lo = statStrLtFrac(st, prefix);
        const hi = statStrLtFrac(st, upper);
        var sel = @max(hi - lo, 0.0);
        var m: f64 = 0;
        for (st.mcv_str) |e| {
            if (e.s.len >= prefix.len and std.mem.eql(u8, e.s[0..prefix.len], prefix)) m += e.freq;
        }
        sel = @max(sel, m);
        return std.math.clamp(sel, 1e-6, 1.0);
    }

    /// Fill `t.stats[ci]` from the columnar image when ANALYZE has not run yet
    /// (snapshot-backed tables). Cheap: dictionary NDV + block min/max, no row
    /// materialisation; MCV/histograms still require ANALYZE.
    fn ensureColStatQuick(self: *Engine, t: *Table, ci: usize) bool {
        if (ci >= t.cols.len) return false;
        if (ci < t.stats.len and (t.stats[ci].ndv > 0 or t.stats[ci].min != t.stats[ci].max)) return true;
        const ct = self.findColumnar(t.name) orelse return false;
        if (ci >= ct.cols.len) return false;
        if (t.stats.len != t.cols.len) {
            const grown = self.gpa.alloc(ColStat, t.cols.len) catch return false;
            @memset(grown, .{});
            const n = @min(t.stats.len, grown.len);
            @memcpy(grown[0..n], t.stats[0..n]);
            if (t.stats.len > 0) self.gpa.free(t.stats);
            t.stats = grown;
        }
        var st = t.stats[ci];
        if (ci < ct.enc.len and ct.enc[ci] != null) st.ndv = ct.enc[ci].?.first.len;
        switch (ct.data[ci]) {
            .ints => |v| {
                if (v.len > 0) {
                    st.min = v[0];
                    st.max = v[0];
                    for (v[1..]) |x| {
                        st.min = @min(st.min, x);
                        st.max = @max(st.max, x);
                    }
                    if (st.ndv == 0) st.ndv = @intCast(@min(v.len, 20000));
                }
            },
            .floats => |v| {
                // Order-preserving keys, so the same range/domain math as ints.
                var have = false;
                for (v) |x| {
                    if (std.math.isNan(x)) continue;
                    const k = f64Key(x);
                    if (!have) {
                        st.min = k;
                        st.max = k;
                        have = true;
                    } else {
                        st.min = @min(st.min, k);
                        st.max = @max(st.max, k);
                    }
                }
                if (have and st.ndv == 0) st.ndv = @intCast(@min(v.len, 20000));
            },
            else => {},
        }
        t.stats[ci] = st;
        return st.ndv > 0;
    }

    /// Predicate shapes the OR sampler can evaluate on a stored row.
    fn orExprSupported(e: *sql.Expr) bool {
        return switch (e.*) {
            .column, .column_idx, .int, .float, .string, .null_lit => true,
            .binary => |b| orExprSupported(b.lhs) and orExprSupported(b.rhs),
            .negate => |x| orExprSupported(x),
            .not => |x| orExprSupported(x),
            .is_null => |x| orExprSupported(x.operand),
            .in_list => |x| blk: {
                if (!orExprSupported(x.operand)) break :blk false;
                for (x.items) |it| if (!orExprSupported(it)) break :blk false;
                break :blk true;
            },
            .between => |x| orExprSupported(x.operand) and orExprSupported(x.low) and orExprSupported(x.high),
            .like => |x| orExprSupported(x.operand) and orExprSupported(x.pattern),
            .in_subquery => |x| orExprSupported(x.operand),
            .call => |c| blk: {
                for (c.args) |a| if (!orExprSupported(a)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    /// Copy every string literal into `alloc` so a stored predicate tree does
    /// not alias the (per-statement) parser arena.
    fn dupeStringLits(alloc: std.mem.Allocator, e: *sql.Expr) void {
        switch (e.*) {
            .string => |txt| e.* = .{ .string = alloc.dupe(u8, txt) catch txt },
            .binary => |b| {
                dupeStringLits(alloc, b.lhs);
                dupeStringLits(alloc, b.rhs);
            },
            .negate => |x| dupeStringLits(alloc, x),
            .not => |x| dupeStringLits(alloc, x),
            .is_null => |x| dupeStringLits(alloc, x.operand),
            .like => |x| {
                dupeStringLits(alloc, x.operand);
                dupeStringLits(alloc, x.pattern);
            },
            .in_list => |x| {
                dupeStringLits(alloc, x.operand);
                for (x.items) |it| dupeStringLits(alloc, it);
            },
            .between => |x| {
                dupeStringLits(alloc, x.operand);
                dupeStringLits(alloc, x.low);
                dupeStringLits(alloc, x.high);
            },
            .call => |c| for (c.args) |a| dupeStringLits(alloc, a),
            else => {},
        }
    }

    fn orExprSame(a: *sql.Expr, b: *sql.Expr) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .column => |n| std.mem.eql(u8, n, b.column),
            .column_idx => |c| c.idx == b.column_idx.idx,
            .int => |v| v == b.int,
            .float => |v| v == b.float,
            .string => |v| std.mem.eql(u8, v, b.string),
            .null_lit => true,
            .binary => |x| x.op == b.binary.op and
                orExprSame(x.lhs, b.binary.lhs) and orExprSame(x.rhs, b.binary.rhs),
            .negate => |x| orExprSame(x, b.negate),
            .not => |x| orExprSame(x, b.not),
            .is_null => |x| x.negated == b.is_null.negated and orExprSame(x.operand, b.is_null.operand),
            .in_list => |x| blk: {
                const y = b.in_list;
                if (x.negated != y.negated or x.items.len != y.items.len) break :blk false;
                if (!orExprSame(x.operand, y.operand)) break :blk false;
                for (x.items, y.items) |e1, e2| {
                    if (!orExprSame(e1, e2)) break :blk false;
                }
                break :blk true;
            },
            .between => |x| x.negated == b.between.negated and
                orExprSame(x.operand, b.between.operand) and
                orExprSame(x.low, b.between.low) and orExprSame(x.high, b.between.high),
            .like => |x| x.negated == b.like.negated and
                orExprSame(x.operand, b.like.operand) and orExprSame(x.pattern, b.like.pattern),
            else => false,
        };
    }

    /// True when the predicate contains an OR whose branches belong to two
    /// different aliases of the same (self-joined) table.
    fn crossAliasOr(e: *sql.Expr, al: ?[]const u8, ar: ?[]const u8, table: []const u8) bool {
        if (al == null or ar == null) return false;
        return switch (e.*) {
            .binary => |b| blk: {
                if (b.op == .or_op) {
                    const l_l = exprBelongsTo(b.lhs, table, al);
                    const l_r = exprBelongsTo(b.lhs, table, ar);
                    const r_l = exprBelongsTo(b.rhs, table, al);
                    const r_r = exprBelongsTo(b.rhs, table, ar);
                    if ((l_l and !l_r and r_r and !r_l) or (l_r and !l_l and r_l and !r_r)) break :blk true;
                }
                break :blk crossAliasOr(b.lhs, al, ar, table) or crossAliasOr(b.rhs, al, ar, table);
            },
            .not => |x| crossAliasOr(x, al, ar, table),
            else => false,
        };
    }

    /// Row-level union fraction of the whole WHERE over one table instance (used
    /// for cross-alias ORs in self-joins, where a per-side split is impossible).
    fn orUnionOnTable(self: *Engine, t: *Table, where: *sql.Expr) ?f64 {
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        const bound = sql.cloneExpr(tmp.allocator(), where) catch return null;
        bindExpr(bound, t.cols) catch return null;
        const ct = self.findColumnar(t.name);
        var n: usize = t.rows.items.len;
        if (n == 0) {
            if (ct) |c| n = c.nrows else return null;
        }
        if (n == 0) return null;
        var step: usize = @max(1, n / 20000);
        if (step > 1 and step % 2 == 0) step += 1;
        var i: usize = 0;
        var samp: u32 = 0;
        var hits: u32 = 0;
        if (t.rows.items.len > 0) {
            while (i < n) : (i += step) {
                samp += 1;
                if (evalPredRow(bound, t.rows.items[i])) hits += 1;
            }
        } else if (ct) |c| {
            while (i < n) : (i += step) {
                samp += 1;
                if (evalPredCtx(.{ .col = c }, bound, i)) hits += 1;
            }
        }
        if (samp == 0) return null;
        const frac = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(samp));
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] {s}: cross-alias or union hits={d}/{d} = {d:.4}\n", .{ t.name, hits, samp, frac });
        }
        return frac;
    }

    /// Exact pair count for a self-join whose WHERE has an OR across the two
    /// aliases: `Σ_v U(v)·f(v)`, where `f(v)` is the key frequency and `U(v)`
    /// the number of rows with key `v` that satisfy the (single-table) WHERE.
    /// This keeps duplicate-key correlation instead of multiplying a row-level
    /// union fraction by an assumed 1:1 join.
    fn selfJoinUnionPairs(self: *Engine, t: *Table, where: *sql.Expr, key_col: usize) ?f64 {
        const ct = self.findColumnar(t.name) orelse return null;
        if (key_col >= ct.cols.len or key_col >= ct.data.len) return null;
        const n = ct.nrows;
        if (n == 0) return null;
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        const bound = sql.cloneExpr(tmp.allocator(), where) catch return null;
        bindExpr(bound, t.cols) catch return null;
        const Agg = struct { f: u32 = 0, u: u32 = 0 };
        const cap: usize = 500_000;
        var pairs: f64 = 0;
        switch (ct.data[key_col]) {
            .ints, .ints8, .ints16, .ints32 => {
                var m = std.AutoHashMap(i64, Agg).init(self.gpa);
                defer m.deinit();
                var ri: usize = 0;
                while (ri < n) : (ri += 1) {
                    if (ct.isDeleted(ri) or ct.isNull(key_col, ri)) continue;
                    const gop = m.getOrPut(ct.data[key_col].intAt(ri)) catch return null;
                    if (!gop.found_existing) {
                        if (m.count() > cap) return null;
                        gop.value_ptr.* = .{};
                    }
                    gop.value_ptr.f += 1;
                    if (evalPredCtx(.{ .col = ct }, bound, ri)) gop.value_ptr.u += 1;
                }
                var it = m.valueIterator();
                while (it.next()) |a| pairs += @as(f64, @floatFromInt(a.u)) * @as(f64, @floatFromInt(a.f));
            },
            .floats => |v| {
                var m = std.AutoHashMap(i64, Agg).init(self.gpa);
                defer m.deinit();
                var ri: usize = 0;
                while (ri < n) : (ri += 1) {
                    if (ct.isDeleted(ri) or ct.isNull(key_col, ri)) continue;
                    const gop = m.getOrPut(f64Key(v[ri])) catch return null;
                    if (!gop.found_existing) {
                        if (m.count() > cap) return null;
                        gop.value_ptr.* = .{};
                    }
                    gop.value_ptr.f += 1;
                    if (evalPredCtx(.{ .col = ct }, bound, ri)) gop.value_ptr.u += 1;
                }
                var it = m.valueIterator();
                while (it.next()) |a| pairs += @as(f64, @floatFromInt(a.u)) * @as(f64, @floatFromInt(a.f));
            },
            .strs => |sd| {
                var m = std.StringHashMap(Agg).init(self.gpa);
                defer m.deinit();
                var ri: usize = 0;
                while (ri < n) : (ri += 1) {
                    if (ct.isDeleted(ri) or ct.isNull(key_col, ri)) continue;
                    const gop = m.getOrPut(sd.at(ri)) catch return null;
                    if (!gop.found_existing) {
                        if (m.count() > cap) return null;
                        gop.value_ptr.* = .{};
                    }
                    gop.value_ptr.f += 1;
                    if (evalPredCtx(.{ .col = ct }, bound, ri)) gop.value_ptr.u += 1;
                }
                var it = m.valueIterator();
                while (it.next()) |a| pairs += @as(f64, @floatFromInt(a.u)) * @as(f64, @floatFromInt(a.f));
            },
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] {s}: self-join cross-alias pairs={d:.0} (per-key)\n", .{ t.name, pairs });
        }
        return pairs;
    }

    /// True when every column reference in `e` belongs to `table` (or `alias`).
    fn exprBelongsTo(e: *sql.Expr, table: []const u8, alias: ?[]const u8) bool {
        return switch (e.*) {
            .column => |n| blk: {
                if (std.mem.lastIndexOfScalar(u8, n, '.')) |dot| {
                    const q = n[0..dot];
                    break :blk std.ascii.eqlIgnoreCase(q, table) or
                        (alias != null and std.ascii.eqlIgnoreCase(q, alias.?));
                }
                break :blk true;
            },
            .binary => |b| exprBelongsTo(b.lhs, table, alias) and exprBelongsTo(b.rhs, table, alias),
            .negate => |x| exprBelongsTo(x, table, alias),
            .not => |x| exprBelongsTo(x, table, alias),
            .is_null => |x| exprBelongsTo(x.operand, table, alias),
            .like => |x| exprBelongsTo(x.operand, table, alias) and exprBelongsTo(x.pattern, table, alias),
            .in_list => |x| blk: {
                if (!exprBelongsTo(x.operand, table, alias)) break :blk false;
                for (x.items) |it| if (!exprBelongsTo(it, table, alias)) break :blk false;
                break :blk true;
            },
            .between => |x| exprBelongsTo(x.operand, table, alias) and
                exprBelongsTo(x.low, table, alias) and exprBelongsTo(x.high, table, alias),
            .cast => |x| exprBelongsTo(x.operand, table, alias),
            .call => |c| blk: {
                for (c.args) |a| if (!exprBelongsTo(a, table, alias)) break :blk false;
                break :blk true;
            },
            else => true,
        };
    }

    /// Measure one recorded-but-unmeasured OR pair on a bounded sample (<=20k
    /// rows), caching the counts so the very next plan uses joint mass. Uses the
    /// columnar image when the row store is empty (snapshot-backed tables).
    /// Collect the `IN (SELECT ...)` nodes of a predicate tree (dedup by node).
    fn collectInSubqueries(e: *sql.Expr, out: *std.ArrayList(*sql.Expr), alloc: std.mem.Allocator) void {
        switch (e.*) {
            .in_subquery => |x| {
                for (out.items) |p| {
                    if (p == e) return;
                }
                out.append(alloc, e) catch return;
                collectInSubqueries(x.operand, out, alloc);
            },
            .binary => |b| {
                collectInSubqueries(b.lhs, out, alloc);
                collectInSubqueries(b.rhs, out, alloc);
            },
            .negate => |x| collectInSubqueries(x, out, alloc),
            .not => |x| collectInSubqueries(x, out, alloc),
            .is_null => |x| collectInSubqueries(x.operand, out, alloc),
            .like => |x| {
                collectInSubqueries(x.operand, out, alloc);
                collectInSubqueries(x.pattern, out, alloc);
            },
            .in_list => |x| {
                collectInSubqueries(x.operand, out, alloc);
                for (x.items) |it| collectInSubqueries(it, out, alloc);
            },
            .between => |x| {
                collectInSubqueries(x.operand, out, alloc);
                collectInSubqueries(x.low, out, alloc);
                collectInSubqueries(x.high, out, alloc);
            },
            .call => |c| for (c.args) |a| collectInSubqueries(a, out, alloc),
            .case_expr => |c| {
                for (c.whens) |w| {
                    collectInSubqueries(w.cond, out, alloc);
                    collectInSubqueries(w.then, out, alloc);
                }
                if (c.else_expr) |x| collectInSubqueries(x, out, alloc);
            },
            .cast => |x| collectInSubqueries(x.operand, out, alloc),
            else => {},
        }
    }

    /// Release an OrReq's membership sets and key arena (record failure paths).
    fn destroyOrReqSubs(self: *Engine, r: *OrReq) void {
        if (r.pred_arena) |ar| {
            ar.deinit();
            self.gpa.destroy(ar);
            r.pred_arena = null;
        }
        for (r.subs.items) |*ss| {
            ss.set.deinit();
            if (ss.range_map) |m0| {
                m0.deinit();
                self.gpa.destroy(m0);
                ss.range_map = null;
            }
        }
        r.subs.deinit(self.gpa);
        if (r.sub_arena) |ar| {
            ar.deinit();
            self.gpa.destroy(ar);
            r.sub_arena = null;
        }
    }

    /// Resolve one `IN (SELECT ...)` node into a membership set. Uncorrelated
    /// subqueries store plain values; correlated ones (`inner.k = outer.k`) are
    /// rewritten to `SELECT <keys+value> FROM ... WHERE <local preds>` and
    /// keyed by the outer key values.
    ///
    /// Turn collected per-value inner keys into the final map: sorted, deduped
    /// slices (any length) plus min/max, for numeric and text keys alike.
    fn materializeRangeMap(
        self: *Engine,
        acc: *RangeAcc,
        key_arena: std.mem.Allocator,
    ) ?*std.StringHashMap(RangeBound) {
        const map = self.gpa.create(std.StringHashMap(RangeBound)) catch return null;
        map.* = std.StringHashMap(RangeBound).init(self.gpa);
        // A/B switch: force the old [min,max]-only behaviour.
        const no_keys = std.c.getenv("ZHDB_NO_IVL_KEYS") != null;
        var budget: usize = RANGE_KEY_BUDGET;
        var str_budget: usize = RANGE_STR_BUDGET;
        var stored: usize = 0;
        var stored_str: usize = 0;
        var it = acc.nums.iterator();
        while (it.next()) |e| {
            const vals = e.value_ptr.*;
            if (vals.items.len == 0) continue;
            // Drop NaN keys (not orderable; they can never satisfy a comparison),
            // then sort and dedupe in place so the stored slice is minimal.
            var w: usize = 0;
            for (vals.items) |x| {
                if (std.math.isNan(x)) continue;
                vals.items[w] = x;
                w += 1;
            }
            if (w == 0) continue;
            std.mem.sort(f64, vals.items[0..w], {}, std.sort.asc(f64));
            var u: usize = 1;
            for (vals.items[1..w]) |x| {
                if (x != vals.items[u - 1]) {
                    vals.items[u] = x;
                    u += 1;
                }
            }
            var keys: []const f64 = &.{};
            if (!no_keys and u <= budget) {
                if (key_arena.dupe(f64, vals.items[0..u])) |ks| {
                    keys = ks;
                    budget -= u;
                    stored += u;
                } else |_| {}
            } else if (!no_keys) {
                budget = 0;
            }
            const dup = key_arena.dupe(u8, e.key_ptr.*) catch continue;
            map.put(dup, .{
                .lo = vals.items[0],
                .hi = vals.items[u - 1],
                .keys = keys,
            }) catch {};
        }
        var it2 = acc.strs.iterator();
        while (it2.next()) |e| {
            const vals = e.value_ptr.*;
            if (vals.items.len == 0) continue;
            std.mem.sort([]const u8, vals.items, {}, struct {
                fn gt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.gt);
            var u: usize = 1;
            for (vals.items[1..]) |x| {
                if (!std.mem.eql(u8, x, vals.items[u - 1])) {
                    vals.items[u] = x;
                    u += 1;
                }
            }
            var bytes: usize = 0;
            for (vals.items[0..u]) |x| bytes += x.len;
            var skeys: []const []const u8 = &.{};
            if (!no_keys and bytes <= str_budget) {
                if (key_arena.alloc([]const u8, u)) |sl| {
                    var ok_all = true;
                    for (vals.items[0..u], 0..) |x, i| {
                        sl[i] = key_arena.dupe(u8, x) catch {
                            ok_all = false;
                            break;
                        };
                    }
                    if (ok_all) {
                        skeys = sl;
                        str_budget -= bytes;
                        stored_str += bytes;
                    }
                } else |_| {}
            } else if (!no_keys) {
                str_budget = 0;
            }
            const dup = key_arena.dupe(u8, e.key_ptr.*) catch continue;
            map.put(dup, .{
                .is_str = true,
                .slo = key_arena.dupe(u8, vals.items[0]) catch &.{},
                .shi = key_arena.dupe(u8, vals.items[u - 1]) catch &.{},
                .skeys = skeys,
            }) catch {};
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null and (acc.nums.count() > 0 or acc.strs.count() > 0)) {
            std.debug.print("[stats] ivl keys values={d} stored={d}/{d} str_bytes={d}/{d}\n", .{
                acc.nums.count() + acc.strs.count(),
                stored,
                RANGE_KEY_BUDGET,
                stored_str,
                RANGE_STR_BUDGET,
            });
        }
        return map;
    }

    /// Resolve a range-correlated `IN (SELECT value FROM t2 WHERE inner.k OP
    /// outer.k)`: one query projects (value, inner key); per value we keep the
    /// extreme key (max for ge/gt, min for le/lt), so membership for an outer row
    /// is a single bound comparison — exact, no bucketing error.
    fn buildRangeOrSubSet(
        self: *Engine,
        t: *Table,
        ss: *OrSubSet,
        x: anytype,
        ta: std.mem.Allocator,
        key_arena: std.mem.Allocator,
        inner_key: *sql.Expr,
        outer_key: *sql.Expr,
        op: sql.BinOp,
        preds: []*sql.Expr,
    ) bool {
        const sub = x.sub;
        if (sub.items.len != 1) return false;
        var sub2 = sub.*;
        sub2.items = ta.alloc(sql.SelectItem, 2) catch return false;
        sub2.items[0] = .{ .expr = sub.items[0].expr, .alias = null };
        sub2.items[1] = .{ .expr = inner_key, .alias = null };
        sub2.where = andAll(ta, preds) catch return false;
        sub2.order_by = &.{};
        sub2.limit = null;
        sub2.offset = null;
        sub2.distinct = false;
        const res = self.execSelect(ta, &sub2, false) catch return false;
        if (res.columns.len < 2) return false;
        if (ss.range_map) |old_map| {
            old_map.deinit();
            self.gpa.destroy(old_map);
        }
        var acc = RangeAcc.init(ta);
        defer acc.deinit(ta);
        for (res.rows) |row| {
            if (row[0] == .null) {
                ss.has_null = true;
                continue;
            }
            if (row[1] == .null) continue;
            var key = std.ArrayList(u8).empty;
            defer key.deinit(ta);
            const ok = appendKeyPart(&key, row[0], ta) catch false;
            if (!ok) continue;
            switch (row[1]) {
                .int => |i| acc.addNum(ta, key.items, @floatFromInt(i)),
                .float => |f| if (!std.math.isNan(f)) acc.addNum(ta, key.items, f),
                .boolean => |b| acc.addNum(ta, key.items, @floatFromInt(@intFromBool(b))),
                .text => |tv2| acc.addStr(ta, key.items, tv2),
                .null => {},
            }
        }
        const map = self.materializeRangeMap(&acc, key_arena) orelse return false;
        const kc = sql.cloneExprDeep(key_arena, outer_key) catch {
            map.deinit();
            self.gpa.destroy(map);
            return false;
        };
        bindExpr(kc, t.cols) catch {
            map.deinit();
            self.gpa.destroy(map);
            return false;
        };
        ss.range_map = map;
        ss.range_keys[0] = kc;
        ss.range_ops[0] = op;
        ss.range_n = 1;
        ss.set.clearRetainingCapacity();
        ss.keys = &.{};
        return true;
    }

    fn buildOrSubSet(
        self: *Engine,
        t: *Table,
        ss: *OrSubSet,
        key_arena: std.mem.Allocator,
        persist: std.mem.Allocator,
    ) bool {
        const x = switch (ss.node.*) {
            .in_subquery => |q| q,
            else => return false,
        };
        ss.set.clearRetainingCapacity();
        ss.has_null = false;
        ss.keys = &.{};
        if (ss.range_map) |m0| {
            m0.deinit();
            self.gpa.destroy(m0);
            ss.range_map = null;
        }
        ss.range_keys = @splat(null);
        ss.range_n = 0;
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        const ta = tmp.allocator();
        if (checkSubqueryScope(x.sub)) |_| {
            const res = self.execSelect(ta, x.sub, false) catch return false;
            if (res.columns.len == 0) return false;
            for (res.rows) |row| {
                if (row[0] == .null) {
                    ss.has_null = true;
                    continue;
                }
                var key = std.ArrayList(u8).empty;
                defer key.deinit(ta);
                const ok = appendKeyPart(&key, row[0], ta) catch false;
                if (!ok) continue;
                const dup = key_arena.dupe(u8, key.items) catch continue;
                ss.set.put(dup, {}) catch {};
            }
            return true;
        } else |_| {}
        // Correlated: split `inner = outer` conjuncts from local predicates.
        const sub = x.sub;
        if (sub.join != null or sub.group_by.len != 0 or sub.having != null or sub.union_all != null) return false;
        const allowed = scopeNames(ta, sub) catch return false;
        if (sub.items.len != 1 or refsOuter(sub.items[0].expr, allowed)) return false;
        var outer_keys = std.ArrayList(*sql.Expr).empty;
        var inner_items = std.ArrayList(*sql.Expr).empty;
        var preds = std.ArrayList(*sql.Expr).empty;
        outer_keys.append(ta, x.operand) catch return false;
        inner_items.append(ta, sub.items[0].expr) catch return false;
        var range_cs: [2]?RangeCorr = @splat(null);
        var range_n: u8 = 0;
        if (sub.where) |w| {
            const ok = splitCorrelated(ta, w, allowed, &outer_keys, &inner_items, &preds, &range_cs, &range_n) catch false;
            if (!ok) {
                // `inner.k OP outer.k` (range correlation): per-value bound map.
                var inner_r: ?*sql.Expr = null;
                var outer_r: ?*sql.Expr = null;
                var rop: ?sql.BinOp = null;
                var rpreds = std.ArrayList(*sql.Expr).empty;
                const ok2 = splitRangeCorrelated(ta, w, allowed, &inner_r, &outer_r, &rop, &rpreds) catch false;
                if (ok2 and inner_r != null and outer_r != null and rop != null) {
                    return self.buildRangeOrSubSet(t, ss, x, ta, key_arena, inner_r.?, outer_r.?, rop.?, rpreds.items);
                }
                return false;
            }
        }
        if (outer_keys.items.len == 0) return false;
        // All range conditions must share one inner expression (an interval).
        if (range_n == 2) {
            const a = range_cs[0].?.inner;
            const b = range_cs[1].?.inner;
            if (exprHash(a) != exprHash(b)) return false;
        }
        const nkeys = inner_items.items.len;
        const nproj = nkeys + (if (range_n > 0) @as(usize, 1) else 0);
        var sub2 = sub.*;
        sub2.items = ta.alloc(sql.SelectItem, nproj) catch return false;
        for (inner_items.items, 0..) |it, i| sub2.items[i] = .{ .expr = it, .alias = null };
        if (range_n > 0) sub2.items[nkeys] = .{ .expr = range_cs[0].?.inner, .alias = null };
        sub2.where = andAll(ta, preds.items) catch return false;
        sub2.order_by = &.{};
        sub2.limit = null;
        sub2.offset = null;
        sub2.distinct = false;
        const res = self.execSelect(ta, &sub2, false) catch return false;
        if (res.columns.len < nproj) return false;
        if (range_n > 0) {
            // Combined equality + range/interval: key -> inner keys (sorted).
            var acc = RangeAcc.init(ta);
            defer acc.deinit(ta);
            for (res.rows) |row| {
                var any_null = false;
                for (row) |v| {
                    if (v == .null) any_null = true;
                }
                if (any_null) {
                    ss.has_null = true;
                    continue;
                }
                var key = std.ArrayList(u8).empty;
                defer key.deinit(ta);
                var key_ok = true;
                for (row[0..nkeys], 0..) |v, i| {
                    if (i > 0) key.append(ta, 0x1f) catch {
                        key_ok = false;
                        break;
                    };
                    const okk = appendKeyPart(&key, v, ta) catch false;
                    if (!okk) {
                        key_ok = false;
                        break;
                    }
                }
                if (!key_ok) continue;
                switch (row[nkeys]) {
                    .int => |i| acc.addNum(ta, key.items, @floatFromInt(i)),
                    .float => |f| if (!std.math.isNan(f)) acc.addNum(ta, key.items, f),
                    .boolean => |b| acc.addNum(ta, key.items, @floatFromInt(@intFromBool(b))),
                    .text => |tv2| acc.addStr(ta, key.items, tv2),
                    .null => {},
                }
            }
            const map = self.materializeRangeMap(&acc, key_arena) orelse return false;
            var ok_all = true;
            var i: usize = 0;
            while (i < range_n) : (i += 1) {
                const rc = range_cs[i].?;
                const rkc = sql.cloneExprDeep(key_arena, rc.outer) catch {
                    ok_all = false;
                    break;
                };
                bindExpr(rkc, t.cols) catch {
                    ok_all = false;
                    break;
                };
                ss.range_keys[i] = rkc;
                ss.range_ops[i] = rc.op;
            }
            if (!ok_all) {
                map.deinit();
                self.gpa.destroy(map);
                return false;
            }
            ss.range_n = range_n;
            ss.range_map = map;
        } else {
            for (res.rows) |row| {
                var any_null = false;
                for (row) |v| {
                    if (v == .null) any_null = true;
                }
                if (any_null) {
                    ss.has_null = true;
                    continue;
                }
                var key = std.ArrayList(u8).empty;
                defer key.deinit(ta);
                for (row, 0..) |v, i| {
                    if (i > 0) key.append(ta, 0x1f) catch return false;
                    const ok = appendKeyPart(&key, v, ta) catch false;
                    if (!ok) {
                        any_null = true;
                        break;
                    }
                }
                if (any_null) continue;
                const dup = key_arena.dupe(u8, key.items) catch continue;
                ss.set.put(dup, {}) catch {};
            }
        }
        // Persist the bound outer key expressions (their slice lives in the
        // key arena so a refresh can rebuild it).
        const keys = key_arena.alloc(*sql.Expr, outer_keys.items.len) catch return false;
        for (outer_keys.items, 0..) |k, i| {
            // Bind a *clone*: the original AST node must stay a `.column` so a
            // later refresh can still classify `inner = outer` conjuncts.
            const kc = sql.cloneExprDeep(key_arena, k) catch return false;
            bindExpr(kc, t.cols) catch return false;
            keys[i] = kc;
        }
        ss.keys = keys;
        _ = persist;
        return true;
    }

    /// Re-resolve `IN (SELECT ...)` membership sets and re-measure after the
    /// data changed (engine mutation version advanced).
    fn refreshOrReq(self: *Engine, t: *Table, r: *OrReq) void {
        r.done = false;
        r.sampled = 0;
        r.a_cnt = 0;
        r.b_cnt = 0;
        r.both = 0;
        if (r.subs.items.len > 0) {
            if (r.sub_arena) |ar| {
                _ = ar.reset(.retain_capacity);
                const ka = ar.allocator();
                for (r.subs.items) |*ss| {
                    _ = self.buildOrSubSet(t, ss, ka, ka);
                }
            }
        }
        r.ver = self.orReqVers(r);
        {
            // Subquery sets were rebuilt: update this entry's resident size.
            const nb = self.orReqBytes(r);
            t.or_bytes = t.or_bytes -| r.bytes;
            t.or_bytes += nb;
            r.bytes = nb;
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] {s}: or pair refreshed tables={d} sets={d} bytes={d}\n", .{
                t.name, r.tables.len, r.subs.items.len, r.bytes,
            });
        }
        self.measureOrReq(t, r);
    }

    fn measureOrReq(self: *Engine, t: *Table, r: *OrReq) void {
        if (r.done) return;
        // Resolved `IN (SELECT ...)` sets (built when the pair was recorded, so
        // the stored predicate tree never needs the original AST pointer).
        const prev_subq = or_subq;
        defer or_subq = prev_subq;
        var matches = std.ArrayList(OrSubq).empty;
        defer matches.deinit(self.gpa);
        for (r.subs.items) |*ss| {
            matches.append(self.gpa, .{
                .expr = ss.node,
                .set = &ss.set,
                .has_null = ss.has_null,
                .keys = ss.keys,
                .range_map = ss.range_map,
                .range_keys = ss.range_keys,
                .range_ops = ss.range_ops,
                .range_n = ss.range_n,
            }) catch {};
        }
        if (matches.items.len > 0) or_subq = matches.items;
        const ct = self.findColumnar(t.name);
        var n: usize = t.rows.items.len;
        if (n == 0) {
            if (ct) |c| n = c.nrows else return;
        }
        if (n == 0) return;
        var step: usize = @max(1, n / 20000);
        if (step > 1 and step % 2 == 0) step += 1;
        var i: usize = 0;
        var samp: u32 = 0;
        var ac: u32 = 0;
        var bc: u32 = 0;
        var bo: u32 = 0;
        if (t.rows.items.len > 0) {
            while (i < n) : (i += step) {
                const row = t.rows.items[i];
                const av = evalPredRow(r.a, row);
                const bv = evalPredRow(r.b, row);
                samp += 1;
                if (av) {
                    ac += 1;
                    if (bv) bo += 1;
                }
                if (bv) bc += 1;
            }
        } else if (ct) |c| {
            while (i < n) : (i += step) {
                const av = evalPredCtx(.{ .col = c }, r.a, i);
                const bv = evalPredCtx(.{ .col = c }, r.b, i);
                samp += 1;
                if (av) {
                    ac += 1;
                    if (bv) bo += 1;
                }
                if (bv) bc += 1;
            }
        }
        r.a_cnt = ac;
        r.b_cnt = bc;
        r.both = bo;
        r.sampled = samp;
        r.done = samp > 0;
        if (std.c.getenv("ZHDB_EXPLAIN") != null and samp > 0) {
            std.debug.print("[stats] {s}: lazy or pair a={d} b={d} both={d} sampled={d} (columnar={})\n", .{
                t.name, ac, bc, bo, samp, t.rows.items.len == 0,
            });
        }
    }

    /// Union fraction for `lhs OR rhs` from measured joint mass, or null after
    /// recording the request (any supported predicate shape, not just constants).
    /// Increment a table's mutation version (DML only; columnar rebuilds do
    /// not change the data).
    fn bumpTableVer(self: *Engine, name: []const u8) void {
        const gop = self.table_ver.getOrPut(name) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, name) catch {
                _ = self.table_ver.remove(name);
                return;
            };
            gop.value_ptr.* = 1;
        } else {
            gop.value_ptr.* +%= 1;
        }
    }

    /// Combined version of all tables an OR pair depends on.
    fn orReqVers(self: *Engine, r: *const OrReq) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (r.tables) |n| {
            h = mixStr(h, n);
            h = mixHash(h, self.table_ver.get(n) orelse 0);
        }
        return h;
    }

    /// Resident-memory budget for the OR cache (env override for tests).
    fn orMemBudget(self: *Engine) usize {
        _ = self;
        if (std.c.getenv("ZHDB_OR_MEM")) |v| {
            return std.fmt.parseInt(usize, std.mem.span(v), 10) catch OR_MEM_BUDGET;
        }
        return OR_MEM_BUDGET;
    }

    fn nextOrStamp(self: *Engine) u64 {
        self.or_tick +%= 1;
        return self.or_tick;
    }

    /// Estimated resident bytes of one OR-cache entry.
    fn orReqBytes(self: *Engine, r: *const OrReq) usize {
        _ = self;
        var n: usize = 128 + exprBytesOf(r.a) + exprBytesOf(r.b);
        for (r.subs.items) |ss| {
            n += 96;
            var it = ss.set.keyIterator();
            while (it.next()) |k| n += k.len + 24;
            if (ss.range_map) |m0| {
                n += m0.count() * 96;
                var mit = m0.iterator();
                while (mit.next()) |e| {
                    n += e.value_ptr.keys.len * 8;
                    n += e.value_ptr.skeys.len * 16;
                    for (e.value_ptr.skeys) |sk| n += sk.len;
                }
            }
        }
        return n;
    }

    /// Evict least-recently-used entries until `need` more bytes fit the budget.
    fn evictOrReq(self: *Engine, t: *Table, need: usize) void {
        const budget = self.orMemBudget();
        var evicted: usize = 0;
        while (t.or_req.items.len > 0 and t.or_bytes + need > budget) {
            var bi: usize = 0;
            var bs: u64 = std.math.maxInt(u64);
            for (t.or_req.items, 0..) |r, i| {
                if (r.stamp < bs) {
                    bs = r.stamp;
                    bi = i;
                }
            }
            var ev = t.or_req.swapRemove(bi);
            t.or_bytes -= @min(t.or_bytes, ev.bytes);
            self.destroyOrReqSubs(&ev);
            evicted += 1;
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null and evicted > 0) {
            std.debug.print("[stats] {s}: or cache evicted={d} resident={d} bytes={d} budget={d}\n", .{
                t.name, evicted, t.or_req.items.len, t.or_bytes, budget,
            });
        }
    }

    fn orJointFrac(self: *Engine, t: *Table, lhs: *sql.Expr, rhs: *sql.Expr) ?f64 {
        if (std.c.getenv("ZHDB_NO_OR_STATS") != null) return null;
        if (!orExprSupported(lhs) or !orExprSupported(rhs)) return null;
        const ha = exprHash(lhs);
        const hb = exprHash(rhs);
        for (t.or_req.items) |*r| {
            if (!((r.ha == ha and r.hb == hb) or (r.ha == hb and r.hb == ha))) continue;
            r.stamp = self.nextOrStamp();
            // Version-aware: data changed since measurement -> re-resolve the
            // subquery sets and re-measure before answering.
            if (self.orReqVers(r) != r.ver) self.refreshOrReq(t, r);
            if (!r.done) self.measureOrReq(t, r);
            if (!r.done or r.sampled == 0) return null;
            const smp: f64 = @floatFromInt(r.sampled);
            const a: f64 = @floatFromInt(r.a_cnt);
            const b: f64 = @floatFromInt(r.b_cnt);
            const both: f64 = @floatFromInt(r.both);
            return (a + b - both) / smp;
        }

        const pred_arena = self.gpa.create(std.heap.ArenaAllocator) catch return null;
        pred_arena.* = std.heap.ArenaAllocator.init(self.gpa);
        const arena = pred_arena.allocator();
        const ra = sql.cloneExpr(arena, lhs) catch {
            pred_arena.deinit();
            self.gpa.destroy(pred_arena);
            return null;
        };
        dupeStringLits(arena, ra);
        bindExpr(ra, t.cols) catch {
            pred_arena.deinit();
            self.gpa.destroy(pred_arena);
            return null;
        };
        const rb = sql.cloneExpr(arena, rhs) catch {
            pred_arena.deinit();
            self.gpa.destroy(pred_arena);
            return null;
        };
        dupeStringLits(arena, rb);
        bindExpr(rb, t.cols) catch {
            pred_arena.deinit();
            self.gpa.destroy(pred_arena);
            return null;
        };
        var req = OrReq{ .a = ra, .b = rb, .ha = ha, .hb = hb, .pred_arena = pred_arena };
        // Resolve `IN (SELECT ...)` once; the membership sets and a deep clone
        // of each sub-SELECT live in the arena so later planning (and ANALYZE,
        // and post-DML refreshes) can re-execute without the original AST.
        var nodes = std.ArrayList(*sql.Expr).empty;
        defer nodes.deinit(self.gpa);
        collectInSubqueries(ra, &nodes, self.gpa);
        collectInSubqueries(rb, &nodes, self.gpa);
        const key_arena = self.gpa.create(std.heap.ArenaAllocator) catch return null;
        key_arena.* = std.heap.ArenaAllocator.init(self.gpa);
        req.sub_arena = key_arena;
        var tbl_names = std.ArrayList([]const u8).empty;
        defer tbl_names.deinit(self.gpa);
        tbl_names.append(self.gpa, t.name) catch {};
        for (nodes.items) |se| {
            switch (se.*) {
                .in_subquery => |*x| {
                    const deep = sql.cloneSelectDeep(arena, x.sub) catch {
                        self.destroyOrReqSubs(&req);
                        return null;
                    };
                    x.sub = deep;
                    collectSelectTables(deep, &tbl_names, self.gpa);
                },
                else => continue,
            }
            var ss = OrSubSet{
                .node = se,
                .set = std.StringHashMap(void).init(self.gpa),
                .has_null = false,
            };
            if (!self.buildOrSubSet(t, &ss, key_arena.allocator(), arena)) {
                ss.set.deinit();
                self.destroyOrReqSubs(&req);
                return null;
            }
            req.subs.append(self.gpa, ss) catch {
                ss.set.deinit();
                self.destroyOrReqSubs(&req);
                return null;
            };
        }
        {
            const names = arena.alloc([]const u8, tbl_names.items.len) catch {
                self.destroyOrReqSubs(&req);
                return null;
            };
            @memcpy(names, tbl_names.items);
            req.tables = names;
            req.ver = self.orReqVers(&req);
        }
        req.bytes = self.orReqBytes(&req);
        req.stamp = self.nextOrStamp();
        self.evictOrReq(t, req.bytes);
        t.or_req.append(self.gpa, req) catch {
            self.destroyOrReqSubs(&req);
            return null;
        };
        t.or_bytes += req.bytes;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[stats] or request recorded (resident={d} bytes={d} budget={d})\n", .{
                t.or_req.items.len, t.or_bytes, self.orMemBudget(),
            });
        }
        // Materialise now so this same plan uses joint mass.
        const back = &t.or_req.items[t.or_req.items.len - 1];
        self.measureOrReq(t, back);
        if (back.done and back.sampled > 0) {
            const smp: f64 = @floatFromInt(back.sampled);
            const a: f64 = @floatFromInt(back.a_cnt);
            const b: f64 = @floatFromInt(back.b_cnt);
            const both: f64 = @floatFromInt(back.both);
            return (a + b - both) / smp;
        }
        return null;
    }

    /// Estimated selectivity of the WHERE conjuncts that bind to `table`
    /// (equality 1/ndv, range/other 0.3 each).
    fn whereSelectivity(self: *Engine, table: []const u8, where: ?*sql.Expr) f64 {
        return self.whereSelectivityAlias(table, where, null);
    }

    fn whereSelectivityAlias(self: *Engine, table: []const u8, where: ?*sql.Expr, alias: ?[]const u8) f64 {
        const e = where orelse return 1.0;
        const t = self.find(table) orelse return 1.0;
        switch (e.*) {
            .like => |l| {
                if (l.pattern.* == .string) {
                    if (self.tableColOfAlias(table, l.operand, alias)) |ci| {
                        if (ci < t.stats.len) {
                            const sel = statLikeSel(t.stats[ci], l.pattern.string);
                            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                                std.debug.print("[plan] like col={d} pat={s} sel={d:.3} mcv={d} hist={d}\n", .{ ci, l.pattern.string, sel, t.stats[ci].mcv_str.len, t.stats[ci].hist_str.len });
                            }
                            return if (l.negated) @max(1.0 - sel, 1e-6) else sel;
                        }
                    }
                }
                // LIKE on another input (or without string stats): neutral for
                // this table, not a generic 0.3.
                return 1.0;
            },
            .in_list => |l| {
                const ci = self.tableColOfAlias(table, l.operand, alias) orelse return 1.0;
                _ = self.ensureColStatQuick(t, ci);
                if (ci >= t.stats.len) return 1.0;
                const st = t.stats[ci];
                var sel: f64 = 0;
                for (l.items) |it| {
                    switch (it.*) {
                        .int => |v| sel += statEqSel(st, v),
                        .string => |v| sel += statStrEqSel(st, v),
                        else => {},
                    }
                }
                sel = std.math.clamp(sel, 0.0, 1.0);
                return if (l.negated) @max(1.0 - sel, 1e-6) else sel;
            },
            .between => |bt| {
                const ci = self.tableColOfAlias(table, bt.operand, alias) orelse return 1.0;
                _ = self.ensureColStatQuick(t, ci);
                if (ci >= t.stats.len) return 1.0;
                const st = t.stats[ci];
                var sel: f64 = 0.3;
                if (bt.low.* == .int and bt.high.* == .int and st.hist.len >= 2) {
                    const lo = bt.low.int;
                    const hi = bt.high.int;
                    sel = @max(statLtFrac(st, hi + 1) - statLtFrac(st, lo), 0.0);
                } else if (bt.low.* == .string and bt.high.* == .string and st.hist_str.len >= 2) {
                    const lo = statStrLtFrac(st, bt.low.string);
                    const hi = statStrLtFrac(st, bt.high.string) + statStrEqSel(st, bt.high.string);
                    sel = @max(hi - lo, 0.0);
                }
                sel = std.math.clamp(sel, 0.0, 1.0);
                return if (bt.negated) @max(1.0 - sel, 1e-6) else sel;
            },
            .binary => |b| {
                if (b.op == .or_op) {
                    if (std.c.getenv("ZHDB_DBG_OR") != null) {
                        std.debug.print("[or-dbg] or_op reached table={s} lhs_tag={s} rhs_tag={s}\n", .{
                            table, @tagName(b.lhs.*), @tagName(b.rhs.*),
                        });
                    }
                    // Per-input attribution: a branch on another join input does
                    // not constrain this one, and a row-level union measurement
                    // only applies when both branches belong to this input.
                    const a_here = exprBelongsTo(b.lhs, table, alias);
                    const b_here = exprBelongsTo(b.rhs, table, alias);
                    if (!a_here and !b_here) return 1.0;
                    if (!b_here) return self.whereSelectivityAlias(table, b.lhs, alias);
                    if (!a_here) return self.whereSelectivityAlias(table, b.rhs, alias);
                    if (self.orJointFrac(t, b.lhs, b.rhs)) |union_frac| {
                        return std.math.clamp(union_frac, 0.0, 1.0);
                    }
                    const sa = self.whereSelectivityAlias(table, b.lhs, alias);
                    const sb = self.whereSelectivityAlias(table, b.rhs, alias);
                    return std.math.clamp(sa + sb - sa * sb, 0.0, 1.0);
                }
                if (b.op == .and_op) {
                    return self.whereSelectivityAlias(table, b.lhs, alias) * self.whereSelectivityAlias(table, b.rhs, alias);
                }
                const col = self.tableColOfAlias(table, b.lhs, alias) orelse self.tableColOfAlias(table, b.rhs, alias) orelse return 1.0;
                _ = self.ensureColStatQuick(t, col);
                const has_stats = col < t.stats.len and t.stats[col].ndv > 0;
                const ndv: f64 = if (has_stats)
                    @floatFromInt(t.stats[col].ndv)
                else
                    @floatFromInt(@max(t.rows.items.len / 100, 1));
                const slit: ?[]const u8 = blk: {
                    if (b.rhs.* == .string and self.tableColOfAlias(table, b.lhs, alias) != null) break :blk b.rhs.string;
                    if (b.lhs.* == .string and self.tableColOfAlias(table, b.rhs, alias) != null) break :blk b.lhs.string;
                    break :blk null;
                };
                if (has_stats and slit != null) {
                    const sst = t.stats[col];
                    const col_left_s = self.tableColOfAlias(table, b.lhs, alias) != null;
                    // Exact-dictionary selectivity. A *sampled* map is only a
                    // conditional distribution, so it must go through
                    // `filterSelFor` (which adds the residual mass); using
                    // pass/tot here overstated it (0.89 vs 0.13).
                    if (sst.dict.len > 0 and !sst.dict_sampled) {
                        const pred = KeyPred{ .op = if (col_left_s) b.op else flipCmp(b.op), .lit = .{ .text = slit.? } };
                        var pass: f64 = 0;
                        var tot: f64 = 0;
                        for (sst.dict) |de| {
                            const c = @as(f64, @floatFromInt(de.count));
                            tot += c;
                            if (predPassStr(pred, de.s)) pass += c;
                        }
                        if (tot > 0) return std.math.clamp(pass / tot, 1e-6, 1.0);
                    }
                    // A dictionary (exact or sampled) is the single source of
                    // truth for string selectivity; keeps cov/sel consistent.
                    if (sst.dict.len > 0) {
                        const pred = KeyPred{ .op = if (col_left_s) b.op else flipCmp(b.op), .lit = .{ .text = slit.? } };
                        const fs = self.filterSelFor(t, col, pred);
                        return std.math.clamp(fs.sel, 1e-6, 1.0);
                    }
                    if (b.op == .eq) return statStrEqSel(sst, slit.?);
                    var sop = b.op;
                    if (!col_left_s) sop = switch (sop) {
                        .lt => .gt,
                        .le => .ge,
                        .gt => .lt,
                        .ge => .le,
                        else => sop,
                    };
                    const s = slit.?;
                    const lt = statStrLtFrac(sst, s);
                    const eqf = statStrEqSel(sst, s);
                    const frac: f64 = switch (sop) {
                        .lt => lt,
                        .le => @min(lt + eqf, 1.0),
                        .gt => @max(1.0 - (lt + eqf), 0.0),
                        .ge => @max(1.0 - lt, 0.0),
                        .neq => 1.0 - eqf,
                        else => 0.3,
                    };
                    return std.math.clamp(frac, 1e-6, 1.0);
                }
                const col_is_float = col < t.cols.len and t.cols[col].ty == .float;
                // Literal as a comparison key: floats map through `f64Key` so
                // the same MCV/histogram machinery applies.
                const litKey = struct {
                    fn get(eng: *Engine, tb: []const u8, al: ?[]const u8, x: *sql.Expr, isf: bool) ?i64 {
                        _ = eng;
                        _ = tb;
                        _ = al;
                        return switch (x.*) {
                            .int => |v| if (isf) f64Key(@floatFromInt(v)) else v,
                            .float => |v| if (isf) f64Key(v) else null,
                            else => null,
                        };
                    }
                }.get;
                if (b.op == .eq) {
                    const lit0: ?i64 = blk: {
                        if (self.tableColOfAlias(table, b.lhs, alias) != null) {
                            if (litKey(self, table, alias, b.rhs, col_is_float)) |k| break :blk k;
                        }
                        if (self.tableColOfAlias(table, b.rhs, alias) != null) {
                            if (litKey(self, table, alias, b.lhs, col_is_float)) |k| break :blk k;
                        }
                        break :blk null;
                    };
                    if (has_stats and lit0 != null) return statEqSel(t.stats[col], lit0.?);
                    return if (ndv > 0) 1.0 / ndv else 0.3;
                }
                // Range predicates: use sampled [min,max] so a non-filtering
                // bound (e.g. `v >= 0` on a non-negative column) does not cost 0.3.
                if (has_stats) {
                    const st = t.stats[col];
                    const col_left = self.tableColOfAlias(table, b.lhs, alias) != null;
                    const lit: ?i64 = blk: {
                        const x = if (col_left) b.rhs else b.lhs;
                        switch (x.*) {
                            .int => |v| break :blk if (col_is_float) f64Key(@floatFromInt(v)) else v,
                            .float => |v| if (col_is_float) break :blk f64Key(v),
                            else => {},
                        }
                        break :blk null;
                    };
                    if (lit) |k| {
                        const lo: f64 = @floatFromInt(st.min);
                        const hi: f64 = @floatFromInt(st.max);
                        const rng: f64 = @max(hi - lo + 1.0, 1.0);
                        const kf: f64 = @floatFromInt(k);
                        var op = b.op;
                        if (!col_left) op = switch (op) {
                            .lt => .gt,
                            .le => .ge,
                            .gt => .lt,
                            .ge => .le,
                            else => op,
                        };
                        const stx = t.stats[col];
                        const hist_ok = stx.hist.len >= 2;
                        const eq_k = statEqSel(stx, k);
                        // Float keys: the histogram is equi-depth in key space,
                        // which is not linear in value space. Interpolate in
                        // value space instead (uniform model).
                        if (col_is_float) {
                            const vmin = f64FromKey(stx.min);
                            const vmax = f64FromKey(stx.max);
                            const rngv = @max(vmax - vmin, 1e-12);
                            const kv = f64FromKey(k);
                            const lt_f = std.math.clamp((kv - vmin) / rngv, 0.0, 1.0);
                            const frac_f: f64 = switch (op) {
                                .lt => lt_f,
                                .le => @min(lt_f + eq_k, 1.0),
                                .gt => @max(1.0 - lt_f - eq_k, 0.0),
                                .ge => @max(1.0 - lt_f, 0.0),
                                .neq => 1.0 - eq_k,
                                else => 0.3,
                            };
                            return std.math.clamp(frac_f, 0.0, 1.0);
                        }
                        const lt_k = if (hist_ok) statLtFrac(stx, k) else (kf - lo) / rng;
                        const frac: f64 = switch (op) {
                            // Float keys are exact per value: `<= k` is `< k` plus
                            // equality, not `< k+1` (the next representable float).
                            .lt => lt_k,
                            .le => if (col_is_float) @min(lt_k + eq_k, 1.0) else if (hist_ok) statLtFrac(stx, k + 1) else (kf - lo + 1.0) / rng,
                            .gt => if (col_is_float) @max(1.0 - lt_k - eq_k, 0.0) else if (hist_ok) 1.0 - statLtFrac(stx, k + 1) else (hi - kf) / rng,
                            .ge => if (col_is_float) @max(1.0 - lt_k, 0.0) else if (hist_ok) 1.0 - statLtFrac(stx, k) else (hi - kf + 1.0) / rng,
                            .neq => 1.0 - eq_k,
                            else => 0.3,
                        };
                        return std.math.clamp(frac, 0.0, 1.0);
                    }
                }
                return 0.3;
            },
            else => return 1.0,
        }
    }

    /// NDV of `table.k` restricted to one value of the local filter column `f`:
    /// `ndv(k,f) / ndv(f)` (uniformity). Falls back to the plain key ndv until
    /// ANALYZE materialises the composite.
    fn filteredKeyNdv(self: *Engine, table: []const u8, k: usize, f: usize) usize {
        const t = self.find(table) orelse return 0;
        const base: usize = if (k < t.stats.len and t.stats[k].ndv > 0) t.stats[k].ndv else 0;
        var nf: usize = 0;
        if (f < t.stats.len and t.stats[f].ndv > 0) nf = t.stats[f].ndv;
        if (nf == 0) {
            if (self.findColumnar(table)) |ct| {
                if (f < ct.enc.len and ct.enc[f] != null) nf = ct.enc[f].?.first.len;
            }
        }
        var pair: usize = 0;
        if (self.findColumnar(table)) |ct| pair = ct.requestPairNdv(self.gpa, k, f);
        const filtered: usize = if (pair > 0 and nf > 0) @max(pair / nf, 1) else 0;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] join ndv {s}: key=c{d} filter=c{d} base={d} pair={d} ndv_f={d} -> {d}\n", .{
                table, k, f, base, pair, nf, if (filtered > 0) filtered else base,
            });
        }
        return if (filtered > 0) filtered else base;
    }

    const KeyPred = struct { op: sql.BinOp, lit: Value };

    fn predBoundsInt(st: ColStat, p: ?KeyPred) [2]i64 {
        var lo: i64 = st.min;
        var hi: i64 = st.max;
        if (p) |q| {
            if (q.lit == .int) {
                const v = q.lit.int;
                switch (q.op) {
                    .eq => {
                        lo = v;
                        hi = v;
                    },
                    .ge => lo = @max(lo, v),
                    .gt => lo = @max(lo, v +| 1),
                    .le => hi = @min(hi, v),
                    .lt => hi = @min(hi, v -| 1),
                    else => {},
                }
            }
        }
        return .{ lo, hi };
    }

    fn strBoundsMissing(st: ColStat) bool {
        return st.min_str.len == 0 or st.max_str.len == 0;
    }

    /// Bounds of the surviving string domain (stats + predicate).
    fn predBoundsStr(st: ColStat, p: ?KeyPred, out: *[2][]const u8) void {
        out[0] = st.min_str;
        out[1] = st.max_str;
        if (p) |q| {
            if (q.lit == .text) {
                const v = q.lit.text;
                switch (q.op) {
                    .eq => {
                        out[0] = v;
                        out[1] = v;
                    },
                    .ge, .gt => {
                        if (std.mem.order(u8, v, out[0]) == .gt) out[0] = v;
                    },
                    .le, .lt => {
                        if (std.mem.order(u8, v, out[1]) == .lt) out[1] = v;
                    },
                    else => {},
                }
            }
        }
    }

    fn flipCmp(op: sql.BinOp) sql.BinOp {
        return switch (op) {
            .lt => .gt,
            .le => .ge,
            .gt => .lt,
            .ge => .le,
            else => op,
        };
    }

    /// Comparison predicate on `table.key` (equality or range, literal side).
    fn keyPred(self: *Engine, where: ?*sql.Expr, table: []const u8, key: usize) ?KeyPred {
        return self.keyPredAlias(where, table, key, null);
    }

    fn keyPredAlias(self: *Engine, where: ?*sql.Expr, table: []const u8, key: usize, alias: ?[]const u8) ?KeyPred {
        const e = where orelse return null;
        switch (e.*) {
            .binary => |b| {
                if (b.op == .and_op) {
                    return self.keyPredAlias(b.lhs, table, key, alias) orelse self.keyPredAlias(b.rhs, table, key, alias);
                }
                const col_is_float = if (self.find(table)) |t|
                    (key < t.cols.len and t.cols[key].ty == .float)
                else
                    false;
                var lit: ?Value = null;
                var col_left = false;
                if (self.tableColOfAlias(table, b.lhs, alias)) |ci| {
                    if (ci == key) {
                        switch (b.rhs.*) {
                            .int => |x| lit = .{ .int = if (col_is_float) f64Key(@floatFromInt(x)) else x },
                            .float => |x| {
                                if (col_is_float) lit = .{ .int = f64Key(x) };
                            },
                            .string => |x| lit = .{ .text = x },
                            else => {},
                        }
                        col_left = true;
                    }
                }
                if (lit == null) {
                    if (self.tableColOfAlias(table, b.rhs, alias)) |ci| {
                        if (ci == key) {
                            switch (b.lhs.*) {
                                .int => |x| lit = .{ .int = if (col_is_float) f64Key(@floatFromInt(x)) else x },
                                .float => |x| {
                                    if (col_is_float) lit = .{ .int = f64Key(x) };
                                },
                                .string => |x| lit = .{ .text = x },
                                else => {},
                            }
                        }
                    }
                }
                const v = lit orelse return null;
                return .{ .op = if (col_left) b.op else flipCmp(b.op), .lit = v };
            },
            else => return null,
        }
    }

    fn predSelInt(st: ColStat, p: KeyPred) f64 {
        const v = switch (p.lit) {
            .int => |x| x,
            else => return 1.0,
        };
        return switch (p.op) {
            .eq => statEqSel(st, v),
            .neq => @max(1.0 - statEqSel(st, v), 1e-6),
            .lt => statLtFrac(st, v),
            .le => statLtFrac(st, v + 1),
            .gt => @max(1.0 - statLtFrac(st, v + 1), 1e-6),
            .ge => @max(1.0 - statLtFrac(st, v), 1e-6),
            else => 1.0,
        };
    }

    fn predPassInt(p: ?KeyPred, x: i64) bool {
        const q = p orelse return true;
        const v = switch (q.lit) {
            .int => |y| y,
            else => return true,
        };
        return switch (q.op) {
            .eq => x == v,
            .neq => x != v,
            .lt => x < v,
            .le => x <= v,
            .gt => x > v,
            .ge => x >= v,
            else => true,
        };
    }

    fn predSelStr(st: ColStat, p: KeyPred) f64 {
        const v = switch (p.lit) {
            .text => |x| x,
            else => return 1.0,
        };
        const lt = statStrLtFrac(st, v);
        const eq = statStrEqSel(st, v);
        return switch (p.op) {
            .eq => eq,
            .neq => @max(1.0 - eq, 1e-6),
            .lt => lt,
            .le => @min(lt + eq, 1.0),
            .gt => @max(1.0 - lt - eq, 1e-6),
            .ge => @max(1.0 - lt, 1e-6),
            else => 1.0,
        };
    }

    fn predPassStr(p: ?KeyPred, s: []const u8) bool {
        const q = p orelse return true;
        const v = switch (q.lit) {
            .text => |x| x,
            else => return true,
        };
        const ord = std.mem.order(u8, s, v);
        return switch (q.op) {
            .eq => ord == .eq,
            .neq => ord != .eq,
            .lt => ord == .lt,
            .le => ord != .gt,
            .gt => ord == .gt,
            .ge => ord != .lt,
            else => true,
        };
    }

    fn histPosLt(st: ColStat, x: i64) f64 {
        var lo: usize = 0;
        while (lo < st.hist.len and st.hist[lo] < x) : (lo += 1) {}
        return @floatFromInt(lo);
    }

    /// Distinct residual values surviving an int range predicate, integrated
    /// over the histogram buckets (instead of scaling ndv linearly by mass).
    fn histNdvInRange(st: ColStat, p: KeyPred) f64 {
        const nb = st.hist_ndv.len;
        if (nb == 0) return 0;
        const v = switch (p.lit) {
            .int => |x| x,
            else => return 0,
        };
        var a: f64 = 0;
        var b: f64 = @floatFromInt(nb);
        switch (p.op) {
            .eq, .neq => return 1,
            .lt => b = histPosLt(st, v),
            .le => b = histPosLt(st, v + 1),
            .gt => a = histPosLt(st, v + 1),
            .ge => a = histPosLt(st, v),
            else => return 0,
        }
        if (b <= a) return 1;
        // Value-space integration with per-bucket [lo,hi] when available.
        if (st.hist_lo.len == nb and st.hist_hi.len == nb) {
            var flo: i64 = std.math.minInt(i64);
            var fhi: i64 = std.math.maxInt(i64);
            switch (p.op) {
                .lt => fhi = std.math.sub(i64, v, 1) catch return 1,
                .le => fhi = v,
                .gt => flo = std.math.add(i64, v, 1) catch return 1,
                .ge => flo = v,
                else => return 1,
            }
            if (flo > fhi) return 1;
            var sum2: f64 = 0;
            var j: usize = 0;
            while (j < nb) : (j += 1) {
                const b_lo = st.hist_lo[j];
                const b_hi = st.hist_hi[j];
                if (b_hi < b_lo) continue;
                const lo3 = @max(b_lo, flo);
                const hi3 = @min(b_hi, fhi);
                if (hi3 < lo3) continue;
                const span: f64 = @floatFromInt(@max(b_hi - b_lo + 1, 1));
                const ovl: f64 = @floatFromInt(hi3 - lo3 + 1);
                sum2 += (ovl / span) * @as(f64, @floatFromInt(st.hist_ndv[j]));
            }
            return @max(sum2, 1.0);
        }
        var sum: f64 = 0;
        var i: usize = 0;
        while (i < nb) : (i += 1) {
            const lo2 = @as(f64, @floatFromInt(i));
            const hi2 = lo2 + 1.0;
            const ov = @min(b, hi2) - @max(a, lo2);
            if (ov > 0) sum += ov * @as(f64, @floatFromInt(st.hist_ndv[i]));
        }
        return @max(sum, 1.0);
    }

    fn histStrPosLt(st: ColStat, s: []const u8) f64 {
        var lo: usize = 0;
        while (lo < st.hist_str.len and std.mem.order(u8, st.hist_str[lo], s) == .lt) : (lo += 1) {}
        return @floatFromInt(lo);
    }

    fn histStrPosLe(st: ColStat, s: []const u8) f64 {
        var lo: usize = 0;
        while (lo < st.hist_str.len and std.mem.order(u8, st.hist_str[lo], s) != .gt) : (lo += 1) {}
        return @floatFromInt(lo);
    }

    /// Order-preserving 8-byte key (zero padding; SQL strings do not contain
    /// NUL), used to measure value-space overlap inside a string bucket.
    fn strKey(s: []const u8) u64 {
        var h: u64 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const b: u64 = if (i < s.len) s[i] else 0;
            h = (h << 8) | b;
        }
        return h;
    }

    /// Distinct residual strings surviving a range predicate, integrated over
    /// the lexicographic histogram buckets (mirrors histNdvInRange for ints).
    fn histStrNdvInRange(st: ColStat, p: KeyPred) f64 {
        const nb = st.hist_str_ndv.len;
        if (nb == 0) return 0;
        const v = switch (p.lit) {
            .text => |x| x,
            else => return 0,
        };
        var a: f64 = 0;
        var b: f64 = @floatFromInt(nb);
        switch (p.op) {
            .eq, .neq => return 1,
            .lt => b = histStrPosLt(st, v),
            .le => b = histStrPosLe(st, v),
            .gt => a = histStrPosLe(st, v),
            .ge => a = histStrPosLt(st, v),
            else => return 0,
        }
        if (b <= a) return 1;
        // NOTE: an 8-byte-key value-space overlap was tried for strings but the
        // duplicate-heavy equi-depth buckets make it less accurate than the
        // mass-weighted index fraction (23% vs 4.4% error on the skew join), so
        // strings keep the mass weighting; ints use hist_lo/hist_hi (P114).
        var sum: f64 = 0;
        var i: usize = 0;
        while (i < nb) : (i += 1) {
            const lo2 = @as(f64, @floatFromInt(i));
            const hi2 = lo2 + 1.0;
            const ov = @min(b, hi2) - @max(a, lo2);
            if (ov > 0) sum += ov * @as(f64, @floatFromInt(st.hist_str_ndv[i]));
        }
        return @max(sum, 1.0);
    }

    /// Exact distinct-value count inside a string predicate range, for small
    /// dictionaries (<= 4096 distinct values): iterate the dictionary rather
    /// than approximating from equi-depth buckets.
    fn exactStrNdvInRange(self: *Engine, tname: []const u8, ci: usize, p: KeyPred, lo: []const u8, hi: []const u8) ?usize {
        const ct = self.findColumnar(tname) orelse return null;
        if (ci >= ct.enc.len) return null;
        const e = ct.enc[ci] orelse return null;
        if (e.first.len == 0 or e.first.len > 4096) return null;
        if (p.lit != .text) return null;
        if (ct.data[ci] != .strs) return null;
        const sd = ct.data[ci].strs;
        var n: usize = 0;
        for (e.first) |row| {
            const s2 = sd.at(row);
            if (std.mem.order(u8, s2, lo) == .lt or std.mem.order(u8, s2, hi) == .gt) continue;
            // Respect the predicate exactly (min/max bounds above are necessary
            // but not sufficient for strict/inclusive comparisons).
            switch (p.op) {
                .lt => if (std.mem.order(u8, s2, p.lit.text) != .lt) continue,
                .le => if (std.mem.order(u8, s2, p.lit.text) == .gt) continue,
                .gt => if (std.mem.order(u8, s2, p.lit.text) != .gt) continue,
                .ge => if (std.mem.order(u8, s2, p.lit.text) == .lt) continue,
                .neq => if (std.mem.eql(u8, s2, p.lit.text)) continue,
                else => {},
            }
            n += 1;
        }
        return n;
    }

    /// One per-input filter estimate: selectivity, map coverage and residual
    /// share all come from the *same* sampled source, so `cov` and `sel` can
    /// never be computed with different denominators.
    const FilterSel = struct {
        sel: f64 = 1.0,
        map_pass: f64 = 0.0,
        res_frac: f64 = 0.0,
        sampled: bool = false,
        has_map: bool = false,
    };

    fn filterSelFor(self: *Engine, t: *Table, ci: usize, p: ?KeyPred) FilterSel {
        _ = self;
        if (ci >= t.stats.len or ci >= t.cols.len) return .{ .sel = 1.0, .map_pass = 0.0, .res_frac = 0.0 };
        const st = t.stats[ci];
        const is_str = t.cols[ci].ty == .text or t.cols[ci].ty == .date or t.cols[ci].ty == .timestamp;
        if (is_str and st.dict.len > 0) {
            var pass_c: f64 = 0;
            var all_c: f64 = 0;
            var pass_n: usize = 0;
            for (st.dict) |e| {
                const c = @as(f64, @floatFromInt(e.count));
                all_c += c;
                if (predPassStr(p, e.s)) {
                    pass_c += c;
                    pass_n += 1;
                }
            }
            if (st.dict_sampled) {
                if (st.dict_sample_rows == 0 or st.ndv == 0) {
                    return .{ .sel = 1.0, .map_pass = 0.0, .res_frac = 0.0 };
                }
                const samp: f64 = @floatFromInt(st.dict_sample_rows);
                const ndv_f: f64 = @floatFromInt(st.ndv);
                // Principled coverage split (no avg-count threshold):
                // entries seen >= 2 times carry their Horvitz–Thompson sampled
                // mass (count / sampled_rows); entries seen exactly once are
                // indistinguishable from near-unique values selected out of the
                // sample, so they contribute the *uniform value share* 1/ndv.
                var sing: usize = 0;
                var pass_sing: usize = 0;
                for (st.dict) |e| {
                    if (e.count != 1) continue;
                    sing += 1;
                    if (predPassStr(p, e.s)) pass_sing += 1;
                }
                const rep_c = all_c - @as(f64, @floatFromInt(sing));
                const rep_pass = pass_c - @as(f64, @floatFromInt(pass_sing));
                const sing_f: f64 = @floatFromInt(sing);
                const pass_sing_f: f64 = @floatFromInt(pass_sing);
                // With an exhaustive scan the singleton counts are exact, so
                // their mass is sing/sampled; otherwise they are values selected
                // out of a partial sample and only their uniform value share
                // (1/ndv) is identifiable.
                const full_scan = st.dict_sample_rows >= t.rows.items.len;
                const sing_mass = if (full_scan) sing_f / samp else sing_f / ndv_f;
                const pass_sing_mass = if (full_scan) pass_sing_f / samp else pass_sing_f / ndv_f;
                const map_all = std.math.clamp(rep_c / samp + sing_mass, 0.0, 1.0);
                const map_pass = @min(std.math.clamp(rep_pass / samp + pass_sing_mass, 0.0, 1.0), map_all);
                const res_all = @max(1.0 - map_all, 0.0);
                // Equality on a value that is not in the map: the residual holds
                // it as one of its distinct values.
                var rmass = resMassFrac(st, p);
                if (pass_n == 0 and p != null and p.?.op == .eq) {
                    const rest_ndv = @max(ndv_f - @as(f64, @floatFromInt(st.dict.len)), 1.0);
                    rmass = 1.0 / rest_ndv;
                }
                const sel = @max(map_pass + res_all * rmass, 1e-9);
                return .{
                    .sel = sel,
                    .map_pass = @min(map_pass, sel),
                    .res_frac = std.math.clamp(1.0 - @min(map_pass, sel) / sel, 0.0, 1.0),
                    .sampled = true,
                    .has_map = true,
                };
            }
            if (all_c <= 0) return .{ .sel = 1.0, .map_pass = 0.0, .res_frac = 0.0 };
            const sel = @max(pass_c / all_c, 1e-9);
            return .{ .sel = sel, .map_pass = sel, .res_frac = 0.0, .has_map = true };
        }
        const sel = @max(if (p) |q| (if (is_str) predSelStr(st, q) else predSelInt(st, q)) else 1.0, 1e-6);
        return .{ .sel = sel, .map_pass = 0.0, .res_frac = 1.0 };
    }

    /// Distinct residual values surviving the predicate, integrated over the
    /// residual (non-Map) histogram buckets using order-preserving keys.
    fn resNdvInRange(st: ColStat, p: ?KeyPred) f64 {
        const nb = st.res_hist_ndv.len;
        if (nb == 0 or st.res_hist.len != nb + 1) return 0;
        var flo: u64 = 0;
        var fhi: u64 = std.math.maxInt(u64);
        if (p) |q| {
            if (q.lit == .text) {
                const v = q.lit.text;
                switch (q.op) {
                    .eq, .neq => return 1,
                    .lt => fhi = strKey(v) -| 1,
                    .le => fhi = strKey(v),
                    .gt => flo = strKey(v) +| 1,
                    .ge => flo = strKey(v),
                    else => {},
                }
            }
        }
        const per: usize = if (use_sub_possible(st, nb)) st.res_sub.len / nb - 1 else 0;
        const use_sub = per > 0 and std.c.getenv("ZHDB_NO_RES_SUB") == null;
        const n_iter: usize = if (use_sub) st.res_sub_ndv.len else nb;
        var sum: f64 = 0;
        var i: usize = 0;
        while (i < n_iter) : (i += 1) {
            var lo_b: usize = i;
            var hi_b: usize = i + 1;
            if (use_sub) {
                const b = i / per;
                const s2 = i % per;
                lo_b = b * (per + 1) + s2;
                hi_b = lo_b + 1;
            }
            const klo = strKey(if (use_sub) st.res_sub[lo_b] else st.res_hist[i]);
            const khi = strKey(if (use_sub) st.res_sub[hi_b] else st.res_hist[i + 1]);
            if (khi < klo) continue;
            const lo3 = @max(klo, flo);
            const hi3 = @min(khi, fhi);
            if (hi3 < lo3) continue;
            const span: f64 = @as(f64, @floatFromInt(khi)) - @as(f64, @floatFromInt(klo)) + 1.0;
            const ovl: f64 = @as(f64, @floatFromInt(hi3)) - @as(f64, @floatFromInt(lo3)) + 1.0;
            const ndv_i: f64 = if (use_sub)
                @floatFromInt(st.res_sub_ndv[i])
            else
                @floatFromInt(st.res_hist_ndv[i]);
            sum += (ovl / span) * ndv_i;
        }
        return @max(sum, 1.0);
    }

    /// True when the second-level residual histogram is complete.
    fn use_sub_possible(st: ColStat, nb: usize) bool {
        if (nb == 0 or st.res_sub.len == 0) return false;
        if (st.res_sub.len % nb != 0) return false;
        const per = st.res_sub.len / nb;
        if (per < 2) return false;
        return st.res_sub_mass.len == nb * (per - 1);
    }

    /// Fraction of the sampled non-Map residual rows that satisfy the predicate,
    /// weighted by each bucket's **actual sampled mass** and interpolated inside
    /// the partially covered edge buckets (not a 1/nb step function).
    /// Start boundary of flattened sub-bucket `g` (buckets are `per+1` apart).
    fn resSubKey(st: ColStat, g: usize, per: usize) []const u8 {
        return st.res_sub[(g / per) * (per + 1) + (g % per)];
    }

    fn resSubEndKey(st: ColStat, g: usize, per: usize) []const u8 {
        return st.res_sub[(g / per) * (per + 1) + (g % per) + 1];
    }

    /// Exact residual mass fraction from the sorted distinct residual values and
    /// their cumulative counts. Returns null when the exact CDF is unavailable
    /// (budget exceeded or older stats).
    fn resExactFrac(st: ColStat, op: sql.BinOp, v: []const u8) ?f64 {
        const n = st.res_cdf_vals.len;
        if (n == 0 or st.res_cdf_cum.len != n) return null;
        // First value >= v.
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, st.res_cdf_vals[mid], v) == .lt) lo = mid + 1 else hi = mid;
        }
        const total = @as(f64, @floatFromInt(st.res_cdf_cum[n - 1]));
        if (total <= 0) return null;
        const lt = if (lo == 0) 0.0 else @as(f64, @floatFromInt(st.res_cdf_cum[lo - 1]));
        var eq: f64 = 0;
        if (lo < n and std.mem.eql(u8, st.res_cdf_vals[lo], v)) {
            eq = @as(f64, @floatFromInt(st.res_cdf_cum[lo])) - lt;
        }
        return switch (op) {
            .lt => lt / total,
            .le => (lt + eq) / total,
            .gt => 1.0 - (lt + eq) / total,
            .ge => 1.0 - lt / total,
            .eq => 0.0,
            else => null,
        };
    }

    /// Residual CDF: fraction of sampled residual rows with value <= `v`.
    ///
    /// The sub-bucket containing `v` is located by **full lexicographic**
    /// comparison of the stored boundaries (so long shared-prefix values are
    /// positioned correctly). Inside that sub-bucket the position is
    /// interpolated in the 8-byte order-preserving key space when the boundary
    /// prefixes differ (the order is then fully determined by those 8 bytes);
    /// when the prefixes are identical (so the 8-byte keys collapse) the value
    /// is assumed mid-bucket. Resolution is 1/2048 of the residual, so either
    /// choice moves the estimate by well under one sub-bucket of mass.
    fn resSubCdf(st: ColStat, v: []const u8, per: usize) f64 {
        const nsub = st.res_sub_mass.len;
        if (nsub == 0 or st.res_sub_cum.len != nsub or per == 0) return 0.5;
        // First sub-bucket whose end boundary is > v.
        var g: usize = 0;
        var hi: usize = nsub;
        while (g < hi) {
            const mid = g + (hi - g) / 2;
            const end = resSubEndKey(st, mid, per);
            if (std.mem.order(u8, end, v) != .gt) g = mid + 1 else hi = mid;
        }
        const total = @as(f64, @floatFromInt(st.res_sub_cum[nsub - 1]));
        if (total <= 0) return 0.5;
        var mass: f64 = if (g == 0) 0.0 else @floatFromInt(st.res_sub_cum[g - 1]);
        if (g < nsub) {
            const bstart = resSubKey(st, g, per);
            if (std.mem.order(u8, bstart, v) != .gt) {
                const bend = resSubEndKey(st, g, per);
                const sk = strKey(bstart);
                const ek = strKey(bend);
                const bm = @as(f64, @floatFromInt(st.res_sub_mass[g]));
                if (ek > sk) {
                    const kv = strKey(v);
                    const frac = std.math.clamp(
                        @as(f64, @floatFromInt(kv -| sk)) / @as(f64, @floatFromInt(ek - sk)),
                        0.0,
                        1.0,
                    );
                    mass += frac * bm;
                } else {
                    // 8-byte prefixes identical: assume the midpoint.
                    mass += 0.5 * bm;
                }
            }
        }
        return std.math.clamp(mass / total, 0.0, 1.0);
    }

    fn resMassFrac(st: ColStat, p: ?KeyPred) f64 {
        const nb = st.res_hist_ndv.len;
        if (nb == 0 or st.res_hist.len != nb + 1) return 1.0;
        if (p == null or p.?.lit != .text) return 1.0;
        const v = p.?.lit.text;
        var flo: u64 = 0;
        var fhi: u64 = std.math.maxInt(u64);
        switch (p.?.op) {
            .lt => fhi = strKey(v) -| 1,
            .le => fhi = strKey(v),
            .gt => flo = strKey(v) +| 1,
            .ge => flo = strKey(v),
            .eq => return 0.0,
            else => {},
        }
        // A/B: the previous step function that counted whole equi-depth buckets.
        if (std.c.getenv("ZHDB_NO_RES_MASS") != null) {
            var lo_idx: f64 = 0;
            var hi_idx: f64 = @floatFromInt(nb);
            switch (p.?.op) {
                .lt => {
                    var i: usize = 0;
                    while (i < st.res_hist.len and std.mem.order(u8, st.res_hist[i], v) == .lt) : (i += 1) {}
                    hi_idx = @floatFromInt(i);
                },
                .le => {
                    var i: usize = 0;
                    while (i < st.res_hist.len and std.mem.order(u8, st.res_hist[i], v) != .gt) : (i += 1) {}
                    hi_idx = @floatFromInt(i);
                },
                .gt => {
                    var i: usize = 0;
                    while (i < st.res_hist.len and std.mem.order(u8, st.res_hist[i], v) != .gt) : (i += 1) {}
                    lo_idx = @floatFromInt(i);
                },
                .ge => {
                    var i: usize = 0;
                    while (i < st.res_hist.len and std.mem.order(u8, st.res_hist[i], v) == .lt) : (i += 1) {}
                    lo_idx = @floatFromInt(i);
                },
                else => {},
            }
            const nbf: f64 = @floatFromInt(nb);
            const frac = (@min(hi_idx, nbf) - @min(lo_idx, hi_idx)) / nbf;
            return std.math.clamp(frac, 0.0, 1.0);
        }
        // Exact CDF when the distinct residual values fit the byte budget.
        if (resExactFrac(st, p.?.op, v)) |f| {
            if (std.c.getenv("ZHDB_DBG_MASS") != null) {
                std.debug.print("[mass-exact] n={d} frac={d:.6}\n", .{ st.res_cdf_vals.len, f });
            }
            return std.math.clamp(f, 0.0, 1.0);
        }
        // Second-level CDF from cumulative per-sub-bucket masses (no value
        // sample): binary search over sub-bucket boundaries + one in-bucket
        // interpolation.
        const per: usize = if (use_sub_possible(st, nb)) st.res_sub.len / nb - 1 else 0;
        const use_sub = per > 0 and std.c.getenv("ZHDB_NO_RES_SUB") == null;
        if (use_sub) {
            const cdf = resSubCdf(st, v, per);
            const frac: f64 = switch (p.?.op) {
                .lt, .le => cdf,
                .gt, .ge => 1.0 - cdf,
                .eq => 0.0,
                else => 1.0,
            };
            if (std.c.getenv("ZHDB_DBG_MASS") != null) {
                std.debug.print("[mass-cdf] sub={d} cdf={d:.6} frac={d:.6}\n", .{ st.res_sub_mass.len, cdf, frac });
            }
            return std.math.clamp(frac, 0.0, 1.0);
        }
        var total: f64 = 0;
        var hit: f64 = 0;
        const n_iter: usize = nb;
        var i: usize = 0;
        while (i < n_iter) : (i += 1) {
            const mass: f64 = if (i >= st.res_hist_mass.len)
                1.0
            else
                @floatFromInt(st.res_hist_mass[i]);
            total += mass;
            const klo = strKey(st.res_hist[i]);
            const khi = strKey(st.res_hist[i + 1]);
            if (khi <= klo) {
                // Duplicate boundary (equal-mass bucket): pass iff the whole
                // bucket is inside the predicate range.
                if (klo >= flo and klo <= fhi) hit += mass;
                continue;
            }
            const lo3 = @max(klo, flo);
            const hi3 = @min(khi - 1, fhi);
            if (hi3 < lo3) continue;
            const span: f64 = @floatFromInt(khi - klo);
            const ovl: f64 = @floatFromInt(hi3 - lo3 + 1);
            hit += (ovl / span) * mass;
        }
        if (total <= 0) return 1.0;
        if (std.c.getenv("ZHDB_DBG_MASS") != null) {
            std.debug.print("[mass] nb={d} sub={d} mass={d} use_sub={} total={d:.0} hit={d:.1} frac={d:.6}\n", .{
                nb, st.res_sub.len, st.res_sub_mass.len, use_sub, total, hit, hit / total,
            });
        }
        return std.math.clamp(hit / total, 0.0, 1.0);
    }

    /// True when this column's statistics came from an exhaustive scan, so the
    /// dictionary counts and the exact residual CDF describe the whole table.
    fn colStatFullScan(st: ColStat, t: *Table) bool {
        return st.dict_sample_rows > 0 and st.dict_sample_rows >= t.rows.items.len;
    }

    /// Horvitz–Thompson scaling from sample counts to estimated table counts
    /// (1.0 for an exhaustive scan).
    fn statScale(st: ColStat, t: *Table) f64 {
        if (st.dict_sample_rows > 0 and st.dict_sample_rows < t.rows.items.len) {
            return @as(f64, @floatFromInt(t.rows.items.len)) / @as(f64, @floatFromInt(st.dict_sample_rows));
        }
        return 1.0;
    }

    /// Pair contribution of one common value. Counts seen >= 2 times in a sample
    /// identify row multiplicity, so they are scaled by `rows/sample`; a value
    /// seen once is indistinguishable from a unique value (true multiplicity 1),
    /// so it contributes exactly one pair per side.
    fn pairCount(ca: f64, cb: f64, sa: f64, sb: f64) f64 {
        if (ca <= 0 or cb <= 0) return 0;
        const a_known = ca > 1.5;
        const b_known = cb > 1.5;
        if (a_known and b_known) return (ca * sa) * (cb * sb);
        if (a_known) return (ca * sa) * cb;
        if (b_known) return ca * (cb * sb);
        return ca * cb;
    }

    /// Matched pairs over the two value maps, with repeated values scaled from
    /// sample counts (singletons kept at multiplicity 1).
    fn mapPairsScaled(a: ColStat, b: ColStat, ap: ?KeyPred, bp: ?KeyPred, sa: f64, sb: f64) f64 {
        var pairs: f64 = 0;
        for (a.dict) |x| {
            if (!predPassStr(ap, x.s)) continue;
            for (b.dict) |y| {
                if (!predPassStr(bp, y.s)) continue;
                if (std.mem.eql(u8, x.s, y.s)) {
                    pairs += pairCount(@floatFromInt(x.count), @floatFromInt(y.count), sa, sb);
                }
            }
        }
        return pairs;
    }

    /// Exact matched pairs over map + residual value lists (same-column stats),
    /// covering map↔map, residual↔residual, and the two cross combinations.
    /// Counts are sample counts; callers scale by `statScale` for sampled stats.
    fn cdfPairs(self: *Engine, a: ColStat, b: ColStat, ap: ?KeyPred, bp: ?KeyPred, sa: f64, sb: f64) ?f64 {
        if (a.res_cdf_vals.len == 0 or b.res_cdf_vals.len == 0) return null;
        if (a.res_cdf_cum.len != a.res_cdf_vals.len or b.res_cdf_cum.len != b.res_cdf_vals.len) return null;
        var pairs: f64 = 0;
        // map ↔ map
        for (a.dict) |x| {
            if (!predPassStr(ap, x.s)) continue;
            for (b.dict) |y| {
                if (!predPassStr(bp, y.s)) continue;
                if (std.mem.eql(u8, x.s, y.s)) {
                    pairs += pairCount(@floatFromInt(x.count), @floatFromInt(y.count), sa, sb);
                }
            }
        }
        // residual ↔ residual
        {
            var i: usize = 0;
            var j: usize = 0;
            const na = a.res_cdf_vals.len;
            const nb = b.res_cdf_vals.len;
            while (i < na and j < nb) {
                const ord = std.mem.order(u8, a.res_cdf_vals[i], b.res_cdf_vals[j]);
                switch (ord) {
                    .lt => i += 1,
                    .gt => j += 1,
                    .eq => {
                        if (predPassStr(ap, a.res_cdf_vals[i]) and predPassStr(bp, b.res_cdf_vals[j])) {
                            const ca: f64 = @floatFromInt(a.res_cdf_cum[i] - (if (i > 0) a.res_cdf_cum[i - 1] else 0));
                            const cb: f64 = @floatFromInt(b.res_cdf_cum[j] - (if (j > 0) b.res_cdf_cum[j - 1] else 0));
                            pairs += pairCount(ca, cb, sa, sb);
                        }
                        i += 1;
                        j += 1;
                    },
                }
            }
        }
        // Cross terms: a map value meeting b's residual (and vice versa).
        var mb = std.StringHashMap(u32).init(self.gpa);
        defer mb.deinit();
        for (b.dict) |x| mb.put(x.s, x.count) catch {};
        var ma = std.StringHashMap(u32).init(self.gpa);
        defer ma.deinit();
        for (a.dict) |x| ma.put(x.s, x.count) catch {};
        if (b.dict.len > 0) {
            for (a.res_cdf_vals, 0..) |v, i| {
                if (!predPassStr(ap, v)) continue;
                const cb = mb.get(v) orelse continue;
                if (!predPassStr(bp, v)) continue;
                const ca: f64 = @floatFromInt(a.res_cdf_cum[i] - (if (i > 0) a.res_cdf_cum[i - 1] else 0));
                pairs += pairCount(ca, @floatFromInt(cb), sa, sb);
            }
        }
        if (a.dict.len > 0) {
            for (b.res_cdf_vals, 0..) |v, i| {
                if (!predPassStr(bp, v)) continue;
                const ca = ma.get(v) orelse continue;
                if (!predPassStr(ap, v)) continue;
                const cb: f64 = @floatFromInt(b.res_cdf_cum[i] - (if (i > 0) b.res_cdf_cum[i - 1] else 0));
                pairs += pairCount(@floatFromInt(ca), cb, sa, sb);
            }
        }
        return pairs;
    }

    /// Exact matched pairs over the two value maps (values present in both),
    /// honouring the local predicates.
    fn dictPassPairs(a: ColStat, b: ColStat, ap: ?KeyPred, bp: ?KeyPred) f64 {
        var pairs: f64 = 0;
        for (a.dict) |x| {
            if (!predPassStr(ap, x.s)) continue;
            for (b.dict) |y| {
                if (!predPassStr(bp, y.s)) continue;
                if (std.mem.eql(u8, x.s, y.s)) {
                    pairs += @as(f64, @floatFromInt(x.count)) * @as(f64, @floatFromInt(y.count));
                }
            }
        }
        return pairs;
    }

    /// Exact matched pairs between two *residual* value lists (which exclude the
    /// map values), by merging the sorted distinct lists. Null unless both exact
    /// CDFs are present.
    fn resPassPairs(a: ColStat, b: ColStat, ap: ?KeyPred, bp: ?KeyPred) ?f64 {
        const na = a.res_cdf_vals.len;
        const nb = b.res_cdf_vals.len;
        if (na == 0 or nb == 0 or a.res_cdf_cum.len != na or b.res_cdf_cum.len != nb) return null;
        var i: usize = 0;
        var j: usize = 0;
        var pairs: f64 = 0;
        while (i < na and j < nb) {
            const ord = std.mem.order(u8, a.res_cdf_vals[i], b.res_cdf_vals[j]);
            switch (ord) {
                .lt => i += 1,
                .gt => j += 1,
                .eq => {
                    if (predPassStr(ap, a.res_cdf_vals[i]) and predPassStr(bp, b.res_cdf_vals[j])) {
                        const ca: f64 = @floatFromInt(a.res_cdf_cum[i] - (if (i > 0) a.res_cdf_cum[i - 1] else 0));
                        const cb: f64 = @floatFromInt(b.res_cdf_cum[j] - (if (j > 0) b.res_cdf_cum[j - 1] else 0));
                        pairs += ca * cb;
                    }
                    i += 1;
                    j += 1;
                },
            }
        }
        return pairs;
    }

    /// Join selectivity given both sides' local key predicates: the conditional
    /// distribution (MCV mass renormalised by the predicate's selectivity plus a
    /// scaled uniform residual). Handles int and string keys.
    fn joinSelFiltered(
        self: *Engine,
        lt: ?*Table,
        cj2: ?usize,
        rt: *Table,
        ci: usize,
        where: ?*sql.Expr,
        ndv_l0: usize,
        ndv_r0: usize,
        lrange: ?[2]i64,
        lalias: ?[]const u8,
        ralias: ?[]const u8,
    ) f64 {
        var ndv_l = ndv_l0;
        var ndv_r = ndv_r0;
        if (ndv_l == 0) ndv_l = 1;
        if (ndv_r == 0) ndv_r = 1;
        const ltab = lt orelse return 1.0 / @as(f64, @floatFromInt(@max(ndv_l, ndv_r)));
        const lk = cj2 orelse return 1.0 / @as(f64, @floatFromInt(@max(ndv_l, ndv_r)));
        if (lk >= ltab.cols.len or ci >= rt.cols.len) return 1.0 / @as(f64, @floatFromInt(@max(ndv_l, ndv_r)));
        const l_is_str = ltab.cols[lk].ty == .text or ltab.cols[lk].ty == .date or ltab.cols[lk].ty == .timestamp;
        const r_is_str = rt.cols[ci].ty == .text or rt.cols[ci].ty == .date or rt.cols[ci].ty == .timestamp;
        if (l_is_str != r_is_str) return 1.0 / @as(f64, @floatFromInt(@max(ndv_l, ndv_r)));
        const lst = if (lk < ltab.stats.len) ltab.stats[lk] else ColStat{};
        const rst = if (ci < rt.stats.len) rt.stats[ci] else ColStat{};
        const lp = self.keyPredAlias(where, ltab.name, lk, lalias);
        const rp = self.keyPredAlias(where, rt.name, ci, ralias);
        if (std.c.getenv("ZHDB_DBG_ALIAS") != null) {
            std.debug.print("[alias] joinSel lalias={?s} ralias={?s} lp={} rp={}\n", .{
                lalias, ralias, lp != null, rp != null,
            });
        }
        const fl = self.filterSelFor(ltab, lk, lp);
        const fr = self.filterSelFor(rt, ci, rp);
        const lsel = fl.sel;
        const rsel = fr.sel;
        // String statistics driven by value lists: map + residual pairs, scaled
        // from sample counts to estimated table counts (1.0 for a full scan).
        if (l_is_str and r_is_str and lst.dict_sampled and rst.dict_sampled and
            colStatFullScan(lst, ltab) and colStatFullScan(rst, rt))
        {
            const sa = statScale(lst, ltab);
            const sb = statScale(rst, rt);
            if (self.cdfPairs(lst, rst, lp, rp, sa, sb)) |pairs| {
                const denom = @as(f64, @floatFromInt(ltab.rows.items.len)) * lsel *
                    @as(f64, @floatFromInt(rt.rows.items.len)) * rsel;
                if (denom > 0) {
                    const sel = pairs / denom;
                    if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                        std.debug.print("[plan] join cdf-exact pairs={d:.0} scale={d:.2}/{d:.2} sel={d:.6}\n", .{
                            pairs, sa, sb, sel,
                        });
                    }
                    return @max(sel, 1e-9);
                }
            }
        }
            // Exact key-set intersection for small string dictionaries.
            if (l_is_str and r_is_str and lst.dict.len > 0 and rst.dict.len > 0) {
                var nl: f64 = 0;
                var nr: f64 = 0;
                for (lst.dict) |a| {
                    if (predPassStr(lp, a.s)) nl += @as(f64, @floatFromInt(a.count));
                }
                for (rst.dict) |b| {
                    if (predPassStr(rp, b.s)) nr += @as(f64, @floatFromInt(b.count));
                }
                if (nl > 0 and nr > 0) {
                    var num: f64 = 0;
                    if (lst.dict.len * rst.dict.len <= 262_144) {
                        for (lst.dict) |a| {
                            if (!predPassStr(lp, a.s)) continue;
                            for (rst.dict) |b| {
                                if (!predPassStr(rp, b.s)) continue;
                                if (std.mem.eql(u8, a.s, b.s)) {
                                    num += @as(f64, @floatFromInt(a.count)) * @as(f64, @floatFromInt(b.count));
                                }
                            }
                        }
                    } else {
                        // Large dictionaries: hash the smaller side once.
                        var map = std.StringHashMap(u32).init(self.gpa);
                        defer map.deinit();
                        const small = if (lst.dict.len <= rst.dict.len) lst.dict else rst.dict;
                        for (small) |a| map.put(a.s, a.count) catch {};
                        const big = if (lst.dict.len <= rst.dict.len) rst.dict else lst.dict;
                        const big_is_r = lst.dict.len <= rst.dict.len;
                        for (big) |b| {
                            const pass = if (big_is_r) predPassStr(rp, b.s) else predPassStr(lp, b.s);
                            if (!pass) continue;
                            if (map.get(b.s)) |c| {
                                num += @as(f64, @floatFromInt(c)) * @as(f64, @floatFromInt(b.count));
                            }
                        }
                    }
                    const sel_map = num / (nl * nr);
                    if (lst.dict_sampled or rst.dict_sampled) {
                        // cov and the residual share come from the same FilterSel
                        // source as `sel`, so identical tables are symmetric.
                        const cov_l = if (fl.sel > 0) @min(fl.map_pass / fl.sel, 1.0) else 0.0;
                        const cov_r = if (fr.sel > 0) @min(fr.map_pass / fr.sel, 1.0) else 0.0;
                        var rest_l: f64 = @max(@as(f64, @floatFromInt(ndv_l)) - @as(f64, @floatFromInt(lst.dict.len)), 1.0);
                        var rest_r: f64 = @max(@as(f64, @floatFromInt(ndv_r)) - @as(f64, @floatFromInt(rst.dict.len)), 1.0);
                        // Histogram integration refines the residual distinct
                        // count, but never below the flat (ndv - map) bound.
                        if (lst.res_hist_ndv.len > 0) rest_l = @max(rest_l, resNdvInRange(lst, lp));
                        if (rst.res_hist_ndv.len > 0) rest_r = @max(rest_r, resNdvInRange(rst, rp));
                        var res_ov: f64 = 1.0;
                        if (lst.res_min.len > 0 and rst.res_min.len > 0) {
                            const inter = std.mem.order(u8, lst.res_min, rst.res_max) != .gt and
                                std.mem.order(u8, rst.res_min, lst.res_max) != .gt;
                            if (!inter) res_ov = 1e-9;
                        }
                        // Map contribution: exact matched pairs with repeated
                        // values scaled from sample counts (singletons stay at
                        // multiplicity 1). Falls back to the coverage split when
                        // the merge has no map pairs.
                        const rows_l: f64 = @floatFromInt(ltab.rows.items.len);
                        const rows_r: f64 = @floatFromInt(rt.rows.items.len);
                        const mps = mapPairsScaled(lst, rst, lp, rp, statScale(lst, ltab), statScale(rst, rt));
                        const use_old = std.c.getenv("ZHDB_OLD_SAMPMAP") != null;
                        const map_term = if (!use_old and mps > 0)
                            mps / @max(rows_l * lsel * rows_r * rsel, 1e-9)
                        else
                            cov_l * cov_r * sel_map;
                        const sel = map_term + fl.res_frac * fr.res_frac * res_ov / @max(rest_l, rest_r);
                        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                            std.debug.print("[plan] join cdf-sampled map_pairs={d:.0} old={d:.6} sel={d:.6}\n", .{
                                mps, cov_l * cov_r * sel_map, sel,
                            });
                        }
                        return @max(sel, 1e-9);
                    }
                    if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                        std.debug.print("[plan] join exact-dict nl={d:.0} nr={d:.0} matches={d:.0} sel={d:.6}\n", .{
                            nl, nr, num, sel_map,
                        });
                    }
                    return @max(sel_map, 1e-9);
                }
            }
        var sm: f64 = 0;
        var l_mcv_surv: f64 = 0;
        var r_mcv_surv: f64 = 0;
        var l_mcv_surv_n: usize = 0;
        var r_mcv_surv_n: usize = 0;
        const l_mcv_n: usize = if (l_is_str) lst.mcv_str.len else lst.mcv.len;
        const r_mcv_n: usize = if (r_is_str) rst.mcv_str.len else rst.mcv.len;
        if (l_is_str) {
            for (lst.mcv_str) |a| {
                if (!predPassStr(lp, a.s)) continue;
                l_mcv_surv += a.freq;
                l_mcv_surv_n += 1;
                for (rst.mcv_str) |b| {
                    if (!predPassStr(rp, b.s)) continue;
                    if (std.mem.eql(u8, a.s, b.s)) sm += (a.freq / lsel) * (b.freq / rsel);
                }
            }
            for (rst.mcv_str) |b| {
                if (predPassStr(rp, b.s)) {
                    r_mcv_surv += b.freq;
                    r_mcv_surv_n += 1;
                }
            }
        } else {
            for (lst.mcv) |a| {
                if (!predPassInt(lp, a.v)) continue;
                l_mcv_surv += a.freq;
                l_mcv_surv_n += 1;
                for (rst.mcv) |b| {
                    if (!predPassInt(rp, b.v)) continue;
                    if (a.v == b.v) sm += (a.freq / lsel) * (b.freq / rsel);
                }
            }
            for (rst.mcv) |b| {
                if (predPassInt(rp, b.v)) {
                    r_mcv_surv += b.freq;
                    r_mcv_surv_n += 1;
                }
            }
        }
        const l_rest = @max(lsel - l_mcv_surv, 0.0) / lsel;
        const r_rest = @max(rsel - r_mcv_surv, 0.0) / rsel;
        if (l_mcv_n == 0 and r_mcv_n == 0) {
            // No MCVs: uniform model with key-domain overlap (value space for
            // floats, whose order-preserving keys span the whole i64 range).
            var sel = 1.0 / @as(f64, @floatFromInt(@max(ndv_l, ndv_r)));
            if (l_is_str and r_is_str and lk < ltab.stats.len and ci < rt.stats.len and
                lst.min_str.len > 0 and rst.min_str.len > 0)
            {
                // String keys: order-preserving prefix spans of the *predicate-
                // restricted* ranges (string columns have no numeric min/max).
                var lb: [2][]const u8 = undefined;
                var rb: [2][]const u8 = undefined;
                predBoundsStr(lst, lp, &lb);
                predBoundsStr(rst, rp, &rb);
                const llo = @as(f64, @floatFromInt(strKey(lb[0])));
                const lhi = @as(f64, @floatFromInt(strKey(lb[1])));
                const rlo = @as(f64, @floatFromInt(strKey(rb[0])));
                const rhi = @as(f64, @floatFromInt(strKey(rb[1])));
                const sl = @max(lhi - llo + 1.0, 1.0);
                const sr = @max(rhi - rlo + 1.0, 1.0);
                const ovl = @max(@min(lhi, rhi) - @max(llo, rlo) + 1.0, 0.0);
                const domain = @min(ovl / @max(@min(sl, sr), 1.0), 1.0);
                sel = domain / @as(f64, @floatFromInt(@max(ndv_l, ndv_r)));
            } else if (lk < ltab.stats.len and ci < rt.stats.len and ltab.stats[lk].ndv > 0 and rt.stats[ci].ndv > 0) {
                const a_min = if (lrange) |r| r[0] else ltab.stats[lk].min;
                const a_max = if (lrange) |r| r[1] else ltab.stats[lk].max;
                const b_min = rt.stats[ci].min;
                const b_max = rt.stats[ci].max;
                const is_float_key = ltab.cols[lk].ty == .float or rt.cols[ci].ty == .float;
                const alo: f64 = if (is_float_key) f64FromKey(a_min) else @floatFromInt(a_min);
                const ahi: f64 = if (is_float_key) f64FromKey(a_max) else @floatFromInt(a_max);
                const blo: f64 = if (is_float_key) f64FromKey(b_min) else @floatFromInt(b_min);
                const bhi: f64 = if (is_float_key) f64FromKey(b_max) else @floatFromInt(b_max);
                const lo2 = @max(alo, blo);
                const hi2 = @min(ahi, bhi);
                const rl2 = @max(ahi - alo + 1.0, 1.0);
                const rr2 = @max(bhi - blo + 1.0, 1.0);
                if (hi2 >= lo2) {
                    // Distinct-value overlap: values are spread with density
                    // ndv/span (floats: 0.1-step values are 10x denser than
                    // their numeric span suggests).
                    const ov2 = hi2 - lo2 + 1.0;
                    // Density may exceed 1 (float values finer than their span).
                    // Use the *denser* side: a single outlier (a far-away max
                    // value) makes the other side's density collapse and would
                    // otherwise underestimate the overlap by orders of magnitude.
                    const dl = @as(f64, @floatFromInt(ndv_l)) / rl2;
                    const dr = @as(f64, @floatFromInt(ndv_r)) / rr2;
                    const common = @min(ov2 * @max(dl, dr), @as(f64, @floatFromInt(@min(ndv_l, ndv_r))));
                    sel = common / (@as(f64, @floatFromInt(ndv_l)) * @as(f64, @floatFromInt(ndv_r)));
                } else {
                    sel = 1e-9;
                }
            }
            return @max(sel, 1e-9);
        }
        const l_full_rest = @max(1.0 - lst.mcv_mass, 1e-9);
        const r_full_rest = @max(1.0 - rst.mcv_mass, 1e-9);
        var rest_ndv_l = @max(@as(f64, @floatFromInt(ndv_l)) - @as(f64, @floatFromInt(l_mcv_n)), 1.0) * (l_rest / l_full_rest);
        var rest_ndv_r = @max(@as(f64, @floatFromInt(ndv_r)) - @as(f64, @floatFromInt(r_mcv_n)), 1.0) * (r_rest / r_full_rest);
        // Range predicates: integrate per-bucket distinct counts instead of the
        // uniform mass-scaled residual (skew-aware).
        if (lp != null and !l_is_str and lst.hist_ndv.len > 0) {
            if (lp.?.op != .eq and lp.?.op != .neq) {
                const hi_n = @min(histNdvInRange(lst, lp.?), @as(f64, @floatFromInt(ndv_l)));
                rest_ndv_l = @max(hi_n - @as(f64, @floatFromInt(l_mcv_surv_n)), 1.0);
            }
        }
        if (rp != null and !r_is_str and rst.hist_ndv.len > 0) {
            if (rp.?.op != .eq and rp.?.op != .neq) {
                const hi_n = @min(histNdvInRange(rst, rp.?), @as(f64, @floatFromInt(ndv_r)));
                rest_ndv_r = @max(hi_n - @as(f64, @floatFromInt(r_mcv_surv_n)), 1.0);
            }
        }
        if (lp != null and l_is_str and lst.hist_str_ndv.len > 0) {
            if (lp.?.op != .eq and lp.?.op != .neq) {
                const hi_n = @min(histStrNdvInRange(lst, lp.?), @as(f64, @floatFromInt(ndv_l)));
                rest_ndv_l = @max(hi_n - @as(f64, @floatFromInt(l_mcv_surv_n)), 1.0);
            }
        }
        if (rp != null and r_is_str and rst.hist_str_ndv.len > 0) {
            if (rp.?.op != .eq and rp.?.op != .neq) {
                const hi_n = @min(histStrNdvInRange(rst, rp.?), @as(f64, @floatFromInt(ndv_r)));
                rest_ndv_r = @max(hi_n - @as(f64, @floatFromInt(r_mcv_surv_n)), 1.0);
            }
        }
        const rest_ndv = @max(@max(rest_ndv_l, rest_ndv_r), 1.0);
        // Mixed terms: MCV values on one side join the other side's residual.
        var mixed: f64 = 0;
        if (l_is_str) {
            for (lst.mcv_str) |a| {
                if (!predPassStr(lp, a.s)) continue;
                var in_other_mcv = false;
                for (rst.mcv_str) |b| {
                    if (std.mem.eql(u8, a.s, b.s)) {
                        in_other_mcv = true;
                        break;
                    }
                }
                if (!in_other_mcv) mixed += (a.freq / lsel) * (r_rest / rest_ndv_r);
            }
            for (rst.mcv_str) |b| {
                if (!predPassStr(rp, b.s)) continue;
                var in_other_mcv = false;
                for (lst.mcv_str) |a| {
                    if (std.mem.eql(u8, a.s, b.s)) {
                        in_other_mcv = true;
                        break;
                    }
                }
                if (!in_other_mcv) mixed += (b.freq / rsel) * (l_rest / rest_ndv_l);
            }
        } else {
            for (lst.mcv) |a| {
                if (!predPassInt(lp, a.v)) continue;
                var in_other_mcv = false;
                for (rst.mcv) |b| {
                    if (a.v == b.v) {
                        in_other_mcv = true;
                        break;
                    }
                }
                if (!in_other_mcv) mixed += (a.freq / lsel) * (r_rest / rest_ndv_r);
            }
            for (rst.mcv) |b| {
                if (!predPassInt(rp, b.v)) continue;
                var in_other_mcv = false;
                for (lst.mcv) |a| {
                    if (a.v == b.v) {
                        in_other_mcv = true;
                        break;
                    }
                }
                if (!in_other_mcv) mixed += (b.freq / rsel) * (l_rest / rest_ndv_l);
            }
        }
        // Residual domains must overlap (filtered range vs the other side).
        var range_factor: f64 = 1.0;
        if (l_is_str and lk < ltab.stats.len and ci < rt.stats.len and
            lst.min_str.len > 0 and rst.min_str.len > 0)
        {
            var a_lo: []const u8 = lst.min_str;
            var a_hi: []const u8 = lst.max_str;
            if (lp) |p2| {
                if (p2.lit == .text) {
                    const sv = p2.lit.text;
                    switch (p2.op) {
                        .ge, .eq, .gt => a_lo = sv,
                        .le, .lt => a_hi = sv,
                        else => {},
                    }
                }
            }
            var b_lo: []const u8 = rst.min_str;
            var b_hi: []const u8 = rst.max_str;
            if (rp) |p2| {
                if (p2.lit == .text) {
                    const sv = p2.lit.text;
                    switch (p2.op) {
                        .ge, .eq, .gt => b_lo = sv,
                        .le, .lt => b_hi = sv,
                        else => {},
                    }
                }
            }
            const inter = std.mem.order(u8, a_lo, b_hi) != .gt and std.mem.order(u8, b_lo, a_hi) != .gt;
            if (!inter) range_factor = 1e-9;
        }
        if (!l_is_str and lk < ltab.stats.len and ci < rt.stats.len) {
            const a_lo = if (lp) |p2| (switch (p2.lit) { .int => |x| (switch (p2.op) { .ge, .eq => x, .gt => x + 1, else => ltab.stats[lk].min }), else => ltab.stats[lk].min }) else ltab.stats[lk].min;
            const a_hi = if (lp) |p2| (switch (p2.lit) { .int => |x| (switch (p2.op) { .le, .eq => x, .lt => x - 1, else => ltab.stats[lk].max }), else => ltab.stats[lk].max }) else ltab.stats[lk].max;
            const b_lo = if (rp) |p2| (switch (p2.lit) { .int => |x| (switch (p2.op) { .ge, .eq => x, .gt => x + 1, else => rt.stats[ci].min }), else => rt.stats[ci].min }) else rt.stats[ci].min;
            const b_hi = if (rp) |p2| (switch (p2.lit) { .int => |x| (switch (p2.op) { .le, .eq => x, .lt => x - 1, else => rt.stats[ci].max }), else => rt.stats[ci].max }) else rt.stats[ci].max;
            const lo3 = @max(a_lo, b_lo);
            const hi3 = @min(a_hi, b_hi);
            if (hi3 < lo3) {
                range_factor = 1e-9;
            } else {
                const ol: f64 = @floatFromInt(hi3 - lo3 + 1);
                const rl3: f64 = @floatFromInt(@max(a_hi - a_lo + 1, 1));
                const rr3: f64 = @floatFromInt(@max(b_hi - b_lo + 1, 1));
                range_factor = ol / @min(rl3, rr3);
            }
        }
        const sel = range_factor * (sm + mixed) + l_rest * r_rest * range_factor / rest_ndv;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[plan] join-sel lsel={d:.3} rsel={d:.3} lrest={d:.3} rrest={d:.3} rest_ndv={d:.1} sm={d:.5} mixed={d:.5} sel={d:.5}\n", .{
                lsel, rsel, l_rest, r_rest, rest_ndv, sm, mixed, sel,
            });
        }
        return @max(sel, 1e-9);
    }

    fn joinNdv(self: *Engine, j: sql.Join, other: ?[]const u8, where: ?*sql.Expr, lrange: ?[2]i64) f64 {
        return self.joinNdvAlias(j, other, where, lrange, null, null);
    }

    fn joinNdvAlias(
        self: *Engine,
        j: sql.Join,
        other: ?[]const u8,
        where: ?*sql.Expr,
        lrange: ?[2]i64,
        lalias: ?[]const u8,
        ralias: ?[]const u8,
    ) f64 {
        const rt = self.find(j.table) orelse return 0;
        const ci = keyCol(rt, j.on.binary.lhs) orelse keyCol(rt, j.on.binary.rhs) orelse return 0;
        // Snapshot-backed tables may have no ANALYZE statistics yet; derive
        // NDV/min/max from the columnar image so the join estimate is sane on
        // the first post-load query.
        _ = self.ensureColStatQuick(rt, ci);
        var ndv_r: usize = 0;
        if (ci < rt.stats.len and rt.stats[ci].ndv > 0) ndv_r = rt.stats[ci].ndv;
        // Composite (join key, local filter column): a filter correlated with the
        // key shrinks the join key's NDV far more than the marginal 1/ndv.
        if (self.filterEqColAlias(where, j.table, ralias)) |fc| {
            if (fc != ci) {
                const f = self.filteredKeyNdv(j.table, ci, fc);
                if (f > 0) ndv_r = f;
            }
        }
        var ndv_l: usize = 0;
        if (other) |on| {
            if (self.find(on)) |lt| {
                const cj = keyCol(lt, j.on.binary.lhs) orelse keyCol(lt, j.on.binary.rhs) orelse null;
                if (cj) |c2| {
                    _ = self.ensureColStatQuick(lt, c2);
                    if (c2 < lt.stats.len and lt.stats[c2].ndv > 0) ndv_l = lt.stats[c2].ndv;
                    if (self.filterEqColAlias(where, on, lalias)) |fc| {
                        if (fc != c2) {
                            const f = self.filteredKeyNdv(on, c2, fc);
                            if (f > 0) ndv_l = f;
                        }
                    }
                }
            }
        }
        if (ndv_l > 0 and ndv_r > 0) {
            var ltab: ?*Table = null;
            var lkey_col: ?usize = null;
            if (other) |on| {
                if (self.find(on)) |lt| {
                    ltab = lt;
                    lkey_col = keyCol(lt, j.on.binary.lhs) orelse keyCol(lt, j.on.binary.rhs);
                }
            }
            const sel = self.joinSelFiltered(ltab, lkey_col, rt, ci, where, ndv_l, ndv_r, lrange, lalias, ralias);
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[plan] join sel={d:.6} ndv_l={d} ndv_r={d} lkey={?d}\n", .{ sel, ndv_l, ndv_r, lkey_col });
            }
            return @max(@min(1.0 / @max(sel, 1e-9), 1e9), 1.0);
        }
        return if (ndv_l > 0) @floatFromInt(ndv_l) else @floatFromInt(ndv_r);
    }

    fn dropJoinTemp(self: *Engine, name: []const u8) void {
        const tmp = self.tempTables().get(name) orelse return;
        _ = self.tempTables().remove(name);
        const tc = self.tempColumnar();
        if (tc.fetchRemove(name)) |kv| kv.value.destroy(self.gpa);
        for (tmp.rows.items) |row| self.gpa.free(row);
        tmp.rows.deinit(self.gpa);
        self.gpa.free(tmp.name);
    }

    /// Outer join with no match: the preserved side keeps its values, the other
    /// side is NULL-filled. Exactly one of `lrow` / `rrow` is non-null.
    fn emitOuterNulls(
        gpa: std.mem.Allocator,
        out: *std.ArrayList([]Value),
        lt: *Table,
        rt: *Table,
        lrow: ?[]Value,
        rrow: ?[]Value,
    ) !void {
        const row = try gpa.alloc(Value, lt.cols.len + rt.cols.len);
        if (lrow) |l| {
            @memcpy(row[0..lt.cols.len], l);
            for (lt.cols.len..row.len) |i| row[i] = .null;
        } else {
            for (0..lt.cols.len) |i| row[i] = .null;
            if (rrow) |r| @memcpy(row[lt.cols.len..], r);
        }
        try out.append(gpa, row);
    }

    fn execSelect(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select, apply_tail: bool) EngineError!Result {
        if (sel.join != null) {
            const norm = try self.normalizeMultiKeyJoins(alloc, sel);
            if (norm != sel) return self.execSelect(alloc, norm, apply_tail);
        }
        if (sel.join) |j| {
            if (sel.more_joins.len > 0) return self.execJoinChain(alloc, sel, j);
            return self.execJoin(alloc, sel, j);
        }
        if (sel.union_all) |right| {
            const left_res = try self.execSelect(alloc, stripTail(sel), true);
            const right_res = try self.execSelect(alloc, stripTail(right), true);
            const cols = left_res.columns;
            var rows = std.ArrayList([]Value).empty;
            defer rows.deinit(alloc);
            switch (sel.set_op) {
                .union_all => {
                    try rows.appendSlice(alloc, left_res.rows);
                    try rows.appendSlice(alloc, right_res.rows);
                },
                .union_distinct => {
                    var seen = std.StringHashMap(void).init(alloc);
                    defer seen.deinit();
                    for (left_res.rows) |r| {
                        const k = try setRowKey(alloc, r);
                        const gop = try seen.getOrPut(k);
                        if (!gop.found_existing) try rows.append(alloc, r);
                    }
                    for (right_res.rows) |r| {
                        const k = try setRowKey(alloc, r);
                        const gop = try seen.getOrPut(k);
                        if (!gop.found_existing) try rows.append(alloc, r);
                    }
                },
                .intersect, .except => {
                    // Hash the right side once, then emit each distinct left row
                    // that is present (INTERSECT) or absent (EXCEPT).
                    var rhs = std.StringHashMap(void).init(alloc);
                    defer rhs.deinit();
                    for (right_res.rows) |r| {
                        const k = try setRowKey(alloc, r);
                        try rhs.put(k, {});
                    }
                    var emitted = std.StringHashMap(void).init(alloc);
                    defer emitted.deinit();
                    for (left_res.rows) |r| {
                        const k = try setRowKey(alloc, r);
                        const in_rhs = rhs.contains(k);
                        if (sel.set_op == .intersect) {
                            if (!in_rhs) continue;
                        } else {
                            if (in_rhs) continue;
                        }
                        const gop = try emitted.getOrPut(k);
                        if (!gop.found_existing) try rows.append(alloc, r);
                    }
                },
            }
            var res = Result{ .columns = cols, .rows = try rows.toOwnedSlice(alloc), .format_json = sel.format_json };
            // The tail (ORDER BY/LIMIT/OFFSET) belongs to the combined result,
            // not to the right-hand member.
            if (apply_tail) res = try self.applyTail(alloc, res, sel, &.{}, &.{});
            return res;
        }
        _ = deterministicReset();
        return self.execSimple(alloc, sel, apply_tail);
    }

    /// Execute the subqueries inside a WHERE tree once and remember their value
    /// sets; `eval` then consults them (hash semi/anti join).
    fn prepareSubqueries(self: *Engine, alloc: std.mem.Allocator, e: *sql.Expr, cols: []Column) EngineError!void {
        switch (e.*) {
            .binary => |b| {
                try self.prepareSubqueries(alloc, b.lhs, cols);
                try self.prepareSubqueries(alloc, b.rhs, cols);
            },
            .not => |x| try self.prepareSubqueries(alloc, x, cols),
            .in_subquery => |x| {
                try self.prepareSubqueries(alloc, x.operand, cols);
                if (checkSubqueryScope(x.sub)) |_| {
                } else |_| {
                    // Correlated: rewrite `outer IN (SELECT item ... WHERE inner=outer)`
                    // into a hash semi/anti join on (operand, correlation keys).
                    if (try self.prepareCorrelated(alloc, e, x.sub, x.operand, cols, x.negated, true)) return;
                    return error.CorrelatedSubquery;
                }
                // `IN (SELECT col FROM t)` over an indexed column: the index keys
                // *are* the distinct values, so no scan is needed.
                if (try self.inSubqueryFromIndex(alloc, e, x.sub, x.negated)) return;
                const res = try self.execSelect(alloc, x.sub, false);
                var set = std.StringHashMap(void).init(self.gpa);
                var has_null = false;
                if (res.columns.len > 0) {
                    for (res.rows) |r| {
                        if (r[0] == .null) {
                            has_null = true;
                            continue;
                        }
                        const k = try formatValue(alloc, r[0]);
                        const gop = try set.getOrPut(k);
                        if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, k);
                    }
                }
                try self.sqs().append(std.heap.page_allocator, .{
                    .expr = e,
                    .set = set,
                    .has_null = has_null,
                    .negated = x.negated,
                });
            },
            .exists => |x| {
                if (checkSubqueryScope(x.sub)) |_| {
                } else |_| {
                    if (try self.prepareCorrelated(alloc, e, x.sub, null, cols, x.negated, false)) return;
                    return error.CorrelatedSubquery;
                }
                const res = try self.execSelect(alloc, x.sub, false);
                try self.sqe().append(std.heap.page_allocator, .{ .expr = e, .val = res.rows.len > 0 });
            },
            .negate => |x| try self.prepareSubqueries(alloc, x, cols),
            .is_null => |x| try self.prepareSubqueries(alloc, x.operand, cols),
            .like => |x| {
                try self.prepareSubqueries(alloc, x.operand, cols);
                try self.prepareSubqueries(alloc, x.pattern, cols);
            },
            .in_list => |x| {
                try self.prepareSubqueries(alloc, x.operand, cols);
                for (x.items) |it| try self.prepareSubqueries(alloc, it, cols);
            },
            .between => |x| {
                try self.prepareSubqueries(alloc, x.operand, cols);
                try self.prepareSubqueries(alloc, x.low, cols);
                try self.prepareSubqueries(alloc, x.high, cols);
            },
            .cast => |x| try self.prepareSubqueries(alloc, x.operand, cols),
            .call => |c| for (c.args) |a| try self.prepareSubqueries(alloc, a, cols),
            .case_expr => |c| {
                for (c.whens) |w| {
                    try self.prepareSubqueries(alloc, w.cond, cols);
                    try self.prepareSubqueries(alloc, w.then, cols);
                }
                if (c.else_expr) |el| try self.prepareSubqueries(alloc, el, cols);
            },
            else => {},
        }
    }

    /// Build the IN-set straight from a persisted index when the subquery is a
    /// bare `SELECT <col> FROM <table>` over an indexed int column.
    fn inSubqueryFromIndex(self: *Engine, alloc: std.mem.Allocator, e: *sql.Expr, sub: *sql.Select, negated: bool) EngineError!bool {
        if (sub.join != null or sub.group_by.len != 0 or sub.having != null or sub.order_by.len != 0 or
            sub.limit != null or sub.offset != null or sub.union_all != null or sub.where != null) return false;
        if (sub.items.len != 1) return false;
        const col_name = switch (sub.items[0].expr.*) {
            .column => |n| n,
            .column_idx => |c| c.name,
            else => return false,
        };
        const from = sub.from orelse return false;
        if (from != .table) return false;
        const ct = self.findColumnar(from.table) orelse return false;
        const ci = ct.find(col_name) orelse return false;
        if (ct.keyidx.len <= ci) return false;
        const idx = ct.keyidx[ci] orelse return false;

        var set = std.StringHashMap(void).init(self.gpa);
        for (idx.keys) |k| {
            const ks = try std.fmt.allocPrint(alloc, "{d}", .{k});
            const gop = try set.getOrPut(ks);
            if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, ks);
        }
        try self.sqs().append(std.heap.page_allocator, .{
            .expr = e,
            .set = set,
            .has_null = false,
            .negated = negated,
        });
        return true;
    }

    /// Aggregate-over-join without GROUP BY is computed while probing, so the
    /// joined rows are never materialised into a temp table.
    /// Aggregate (optionally grouped) over an equi join, computed while probing
    /// so the joined rows are never materialised into a `__join_N` table.
    fn joinAggregate(
        self: *Engine,
        alloc: std.mem.Allocator,
        sel: *sql.Select,
        j: sql.Join,
        lname: []const u8,
        lt: *Table,
        rt: *Table,
    ) EngineError!?Result {
        // This single-join fused path does not evaluate WHERE/HAVING/DISTINCT
        // (nor multi-key ON residuals); those shapes must go through the
        // materialised join + final SELECT.
        if (sel.where != null or sel.having != null or sel.distinct or j.extra_eqs.len > 0) return null;
        const Spec = struct { kind: sql.BinOp, expr: ?*sql.Expr, name: []const u8 };
        var specs = std.ArrayList(Spec).empty;
        defer specs.deinit(self.gpa);
        var key_names = std.ArrayList([]const u8).empty;
        defer key_names.deinit(self.gpa);
        for (sel.items) |it| {
            switch (it.expr.*) {
                .call => |c| {
                    if (c.distinct) return null;
                    var kind: sql.BinOp = undefined;
                    if (std.ascii.eqlIgnoreCase(c.name, "count")) {
                        kind = .eq;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "sum")) {
                        kind = .lt;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "min")) {
                        kind = .gt;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "max")) {
                        kind = .le;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "avg")) {
                        kind = .ge;
                    } else return null;
                    var arg: ?*sql.Expr = null;
                    if (c.args.len == 1) {
                        arg = c.args[0];
                    } else if (!std.ascii.eqlIgnoreCase(c.name, "count")) {
                        return null;
                    }
                    try specs.append(self.gpa, .{ .kind = kind, .expr = arg, .name = c.name });
                },
                .column => |n| try key_names.append(self.gpa, n),
                .column_idx => |c| try key_names.append(self.gpa, c.name),
                else => return null,
            }
        }
        if (specs.items.len == 0) return null;
        if (sel.group_by.len != 0 and sel.group_by.len != key_names.items.len) return null;

        // join keys (equi only, already validated by the caller's dispatch)
        const lhs = j.on.binary.lhs;
        const rhs = j.on.binary.rhs;
        var lcol: usize = undefined;
        var rcol: usize = undefined;
        const lhs_l = colOfSide(lt, lname, sel.alias, lhs);
        const lhs_r = colOfSide(rt, j.table, j.alias, lhs);
        const rhs_l = colOfSide(lt, lname, sel.alias, rhs);
        const rhs_r = colOfSide(rt, j.table, j.alias, rhs);
        if (lhs_l != null and rhs_r != null) {
            lcol = lhs_l.?;
            rcol = rhs_r.?;
        } else if (rhs_l != null and lhs_r != null) {
            lcol = rhs_l.?;
            rcol = lhs_r.?;
        } else return null;

        var map = std.StringHashMap(std.ArrayList(u32)).init(self.gpa);
        defer {
            var it = map.valueIterator();
            while (it.next()) |v| v.deinit(self.gpa);
            map.deinit();
        }
        for (rt.rows.items, 0..) |row, ri| {
            if (isRowDeleted(rt, ri)) continue;
            if (!self.visibleRow(rt, ri)) continue;
            if (tableIsNull(rt, rcol, ri)) continue;
            const k = try formatValue(alloc, row[rcol]);
            const gop = try map.getOrPut(k);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.gpa, @intCast(ri));
        }

        const cols = try alloc.alloc(Column, lt.cols.len + rt.cols.len);
        for (lt.cols, 0..) |c, i| cols[i] = c;
        for (rt.cols, 0..) |c, i| cols[lt.cols.len + i] = c;
        const joined = try alloc.alloc(Value, cols.len);

        const G = struct {
            key: []Value,
            counts: []i64,
            sums: []i128,
            mins: []i64,
            maxs: []i64,
        };
        var groups = std.ArrayList(G).empty;
        var gmap = std.StringHashMap(u32).init(self.gpa);
        defer gmap.deinit();
        // Key bytes live in the query arena (they are also copied into groups).
        var keybuf = std.ArrayList(u8).empty;
        defer keybuf.deinit(alloc);
        var out_rows = std.ArrayList([]Value).empty;
        var out_cols = std.ArrayList([]const u8).empty;

        var key_cols = try alloc.alloc(usize, key_names.items.len);
        for (key_names.items, 0..) |kn, i| {
            key_cols[i] = findColSlice(cols, kn) orelse return null;
        }

        for (lt.rows.items, 0..) |lrow, lri| {
            if (isRowDeleted(lt, lri)) continue;
            if (!self.visibleRow(lt, lri)) continue;
            if (tableIsNull(lt, lcol, lri)) continue;
            const k = try formatValue(alloc, lrow[lcol]);
            const list = map.get(k) orelse continue;
            for (list.items) |ri| {
                const rrow = rt.rows.items[ri];
                @memcpy(joined[0..lt.cols.len], lrow);
                @memcpy(joined[lt.cols.len..], rrow);

                // group key
                keybuf.clearRetainingCapacity();
                for (key_cols, 0..) |kc, i| {
                    if (i > 0) try keybuf.append(alloc, 0x1f);
                    try keybuf.appendSlice(alloc, try formatValue(alloc, joined[kc]));
                }
                var gi: u32 = undefined;
                const gop = try gmap.getOrPut(keybuf.items);
                if (!gop.found_existing) {
                    const key_vals = try alloc.alloc(Value, key_cols.len);
                    for (key_cols, 0..) |kc, i| key_vals[i] = joined[kc];
                    gi = @intCast(groups.items.len);
                    gop.value_ptr.* = gi;
                    gop.key_ptr.* = try alloc.dupe(u8, keybuf.items);
                    try groups.append(self.gpa, .{
                        .key = key_vals,
                        .counts = try alloc.alloc(i64, specs.items.len),
                        .sums = try alloc.alloc(i128, specs.items.len),
                        .mins = try alloc.alloc(i64, specs.items.len),
                        .maxs = try alloc.alloc(i64, specs.items.len),
                    });
                    @memset(groups.items[gi].counts, 0);
                    @memset(groups.items[gi].sums, 0);
                } else {
                    gi = gop.value_ptr.*;
                }
                const g = &groups.items[gi];
                for (specs.items, 0..) |sp, si| {
                    const v: Value = if (sp.expr) |e| try self.eval(alloc, e, joined, cols, null) else Value{ .int = 1 };
                    if (v == .null) continue;
                    const iv: i64 = switch (v) {
                        .int => |x| x,
                        .float => |f| @intFromFloat(f),
                        .text => |t| @intCast(t.len),
                        else => 0,
                    };
                    g.counts[si] += 1;
                    g.sums[si] += iv;
                    if (g.counts[si] == 1) {
                        g.mins[si] = iv;
                        g.maxs[si] = iv;
                    } else {
                        g.mins[si] = @min(g.mins[si], iv);
                        g.maxs[si] = @max(g.maxs[si], iv);
                    }
                }
            }
        }

        // order by: ordinal or matching aggregate name
        var order_idx: ?usize = null;
        var order_desc = true;
        for (sel.order_by) |ob| {
            order_desc = ob.desc;
            switch (ob.expr.*) {
                .int => |n| {
                    const nn: usize = @intCast(n);
                    if (nn > key_names.items.len and nn - key_names.items.len <= specs.items.len) {
                        order_idx = nn - key_names.items.len - 1;
                    }
                },
                .call => |c| {
                    for (specs.items, 0..) |sp, i| {
                        if (std.ascii.eqlIgnoreCase(sp.name, c.name)) order_idx = i;
                    }
                },
                .column => |alias| {
                    for (sel.items, 0..) |it, i| {
                        if (it.alias) |a| {
                            if (std.ascii.eqlIgnoreCase(a, alias) and i >= key_names.items.len) {
                                order_idx = i - key_names.items.len;
                            }
                        }
                    }
                },
                else => {},
            }
        }
        if (order_idx) |oi| {
            const Ctx = struct {
                idx: usize,
                desc: bool,
                fn less(ctx: @This(), a: G, b: G) bool {
                    const av: i128 = a.sums[ctx.idx];
                    const bv: i128 = b.sums[ctx.idx];
                    if (av != bv) return if (ctx.desc) av > bv else av < bv;
                    // Full sort key: aggregate value, then *all* group keys in
                    // the same direction, so the order is total and stable.
                    var i: usize = 0;
                    while (i < a.key.len and i < b.key.len) : (i += 1) {
                        const ord = Value.order(a.key[i], b.key[i]);
                        if (ord == .eq) continue;
                        return if (ctx.desc) ord == .gt else ord == .lt;
                    }
                    return a.key.len < b.key.len;
                }
            };
            std.mem.sort(G, groups.items, Ctx{ .idx = oi, .desc = order_desc }, Ctx.less);
        }

        var limit: usize = groups.items.len;
        if (sel.limit) |le| {
            if (le.* == .int and le.int >= 0) limit = @min(limit, @as(usize, @intCast(le.int)));
        }

        for (sel.items) |it| {
            try out_cols.append(alloc, it.alias orelse switch (it.expr.*) {
                .column => |n| n,
                .call => |c| c.name,
                else => "?column?",
            });
        }

        var produced: usize = 0;
        for (groups.items) |g| {
            if (produced >= limit) break;
            produced += 1;
            const row = try alloc.alloc(Value, key_names.items.len + specs.items.len);
            for (g.key, 0..) |kv, i| row[i] = kv;
            for (specs.items, 0..) |sp, si| {
                row[key_names.items.len + si] = if (std.ascii.eqlIgnoreCase(sp.name, "count"))
                    .{ .int = g.counts[si] }
                else if (std.ascii.eqlIgnoreCase(sp.name, "sum"))
                    .{ .int = @intCast(g.sums[si]) }
                else if (std.ascii.eqlIgnoreCase(sp.name, "min"))
                    .{ .int = g.mins[si] }
                else if (std.ascii.eqlIgnoreCase(sp.name, "max"))
                    .{ .int = g.maxs[si] }
                else
                    .{ .float = if (g.counts[si] > 0) @as(f64, @floatFromInt(g.sums[si])) / @as(f64, @floatFromInt(g.counts[si])) else 0 };
            }
            try out_rows.append(alloc, row);
        }

        return .{
            .columns = try out_cols.toOwnedSlice(alloc),
            .rows = try out_rows.toOwnedSlice(alloc),
        };
    }

    /// Non-equi join (`<`, `>`, `<=`, `>=`): index range scan on the right table
    /// when it has an index on the join column, else a bounded nested loop.
    fn execRangeJoin(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select, j: sql.Join) EngineError!Result {
        const lname = switch (sel.from.?) {
            .table => |n| n,
            else => return error.UnsupportedJoin,
        };
        const lt = self.find(lname) orelse return error.TableNotFound;
        const rt = self.find(j.table) orelse return error.TableNotFound;
        self.ensureRowsMaterialized(lname);
        self.ensureRowsMaterialized(j.table);

        const b = j.on.binary;
        const lhs = b.lhs;
        const rhs = b.rhs;
        const lhs_left = keyCol(lt, lhs) != null;
        const lhs_right = keyCol(rt, lhs) != null;
        const rhs_left = keyCol(lt, rhs) != null;
        const rhs_right = keyCol(rt, rhs) != null;
        var lcol: usize = undefined;
        var rcol: usize = undefined;
        // `op` always means `left_value OP right_value`.
        var op = b.op;
        if (lhs_left and rhs_right) {
            lcol = keyCol(lt, lhs) orelse return error.UnknownColumn;
            rcol = keyCol(rt, rhs) orelse return error.UnknownColumn;
        } else if (lhs_right and rhs_left) {
            lcol = keyCol(lt, rhs) orelse return error.UnknownColumn;
            rcol = keyCol(rt, lhs) orelse return error.UnknownColumn;
            op = switch (op) {
                .lt => .gt,
                .gt => .lt,
                .le => .ge,
                .ge => .le,
                else => op,
            };
        } else {
            return error.UnsupportedJoin;
        }

        // Index on the right join column turns the inner loop into a range scan.
        var ridx: ?*columnar.KeyIndex = null;
        if (self.findColumnar(j.table)) |ct| {
            if (ct.keyidx.len > rcol) ridx = ct.keyidx[rcol];
        }

        var out_rows = std.ArrayList([]Value).empty;
        var rids = std.ArrayList(u32).empty;
        defer rids.deinit(self.gpa);
        for (lt.rows.items, 0..) |lrow, lri| {
            if (!self.visibleRow(lt, lri)) continue;
            const lv = if (tableIsNull(lt, lcol, lri)) Value.null else lrow[lcol];
            var matched = false;
            if (lv == .int and ridx != null) {
                const k = lv.int;
                const maxi = std.math.maxInt(i64);
                const mini = std.math.minInt(i64);
                var lo: i64 = mini;
                var hi: i64 = maxi;
                var empty = false;
                // `left OP right` as a range over the right key.
                switch (op) {
                    .lt => { // right > left
                        if (k == maxi) empty = true else lo = k + 1;
                    },
                    .le => lo = k, // right >= left
                    .gt => { // right < left
                        if (k == mini) empty = true else hi = k - 1;
                    },
                    .ge => hi = k, // right <= left
                    else => empty = true,
                }
                if (!empty) {
                    rids.clearRetainingCapacity();
                    try ridx.?.range(self.gpa, lo, hi, &rids);
                    for (rids.items) |ri| {
                        matched = true;
                        const rrow = rt.rows.items[ri];
                        const row = try self.gpa.alloc(Value, lt.cols.len + rt.cols.len);
                        @memcpy(row[0..lt.cols.len], lrow);
                        @memcpy(row[lt.cols.len..], rrow);
                        try out_rows.append(self.gpa, row);
                    }
                }
            } else {
                // Bounded nested loop (no index): refuse pathological sizes.
                if (lt.rows.items.len * rt.rows.items.len > 100_000_000) return error.UnsupportedJoin;
                for (rt.rows.items, 0..) |rrow, rri| {
                    if (isRowDeleted(rt, rri)) continue;
                    if (!self.visibleRow(rt, rri)) continue;
                    const rv = if (tableIsNull(rt, rcol, rri)) Value.null else rrow[rcol];
                    if (lv == .null or rv == .null) continue;
                    const ord = Value.order(lv, rv);
                    const keep = switch (op) {
                        .lt => ord == .lt,
                        .gt => ord == .gt,
                        .le => ord != .gt,
                        .ge => ord != .lt,
                        else => false,
                    };
                    if (!keep) continue;
                    matched = true;
                    const row = try self.gpa.alloc(Value, lt.cols.len + rt.cols.len);
                    @memcpy(row[0..lt.cols.len], lrow);
                    @memcpy(row[lt.cols.len..], rrow);
                    try out_rows.append(self.gpa, row);
                }
            }
            if (!matched and j.left) try emitOuterNulls(self.gpa, &out_rows, lt, rt, lrow, null);
        }

        const name = try std.fmt.allocPrint(self.gpa, "__join_{d}", .{tls_join_seq});
        tls_join_seq += 1;
        const defs = try self.gpa.alloc(sql.ColumnDef, lt.cols.len + rt.cols.len);
        defer self.gpa.free(defs);
        for (0..lt.cols.len) |i| defs[i] = .{ .name = lt.cols[i].name, .type_name = typeName(lt.cols[i].ty) };
        for (0..rt.cols.len) |i| defs[lt.cols.len + i] = .{ .name = rt.cols[i].name, .type_name = typeName(rt.cols[i].ty) };
        const tmp = try Table.create(self.gpa, name, defs);
        for (0..lt.cols.len) |i| tmp.cols[i].source = sel.alias orelse lname;
        for (0..rt.cols.len) |i| tmp.cols[lt.cols.len + i].source = j.alias orelse j.table;
        tmp.rows = out_rows;
        try self.tempTables().put(name, tmp);
        defer {
            _ = self.tempTables().remove(name);
            const tc = self.tempColumnar();
            if (tc.fetchRemove(name)) |kv| kv.value.destroy(self.gpa);
            for (tmp.rows.items) |row| self.gpa.free(row);
            tmp.rows.deinit(self.gpa);
            self.gpa.free(name);
        }
        self.buildColumnar(name) catch {};

        var sel2 = sel.*;
        sel2.from = .{ .table = name };
        sel2.join = null;
        return self.execSelect(alloc, &sel2, true);
    }

    /// Rewrite a correlated EXISTS/IN into a hash semi/anti join:
    /// equality predicates that mix inner and outer columns become join keys,
    /// the remaining inner predicates are evaluated once to build the key set.
    fn prepareCorrelated(
        self: *Engine,
        alloc: std.mem.Allocator,
        e: *sql.Expr,
        sub: *sql.Select,
        in_operand: ?*sql.Expr,
        cols: []Column,
        negated: bool,
        for_in: bool,
    ) EngineError!bool {
        if (sub.join != null or sub.group_by.len != 0 or sub.having != null or sub.union_all != null) return false;
        const allowed = try scopeNames(alloc, sub);
        defer alloc.free(allowed);

        var outer_keys = std.ArrayList(*sql.Expr).empty;
        var inner_items = std.ArrayList(*sql.Expr).empty;
        if (in_operand) |op| {
            // `outer IN (SELECT item ...)`: item must reference only the subquery.
            if (sub.items.len != 1 or refsOuter(sub.items[0].expr, allowed)) return false;
            try outer_keys.append(alloc, op);
            try inner_items.append(alloc, sub.items[0].expr);
        }
        var preds = std.ArrayList(*sql.Expr).empty;
        var eq_ok = true;
        var range_cs: [2]?RangeCorr = @splat(null);
        var range_n: u8 = 0;
        if (sub.where) |w| {
            eq_ok = splitCorrelated(alloc, w, allowed, &outer_keys, &inner_items, &preds, &range_cs, &range_n) catch false;
        }
        if (!eq_ok) {
            // Range correlation `inner.k OP outer.k` -> per-value bound map.
            if (in_operand == null or sub.items.len != 1) return false;
            var inner_r: ?*sql.Expr = null;
            var outer_r: ?*sql.Expr = null;
            var rop: ?sql.BinOp = null;
            var rpreds = std.ArrayList(*sql.Expr).empty;
            if (sub.where) |w| {
                const ok2 = splitRangeCorrelated(alloc, w, allowed, &inner_r, &outer_r, &rop, &rpreds) catch false;
                if (!ok2) return false;
            }
            if (inner_r == null or outer_r == null or rop == null) return false;
            var sub2 = sub.*;
            sub2.items = try alloc.alloc(sql.SelectItem, 2);
            sub2.items[0] = .{ .expr = sub.items[0].expr, .alias = null };
            sub2.items[1] = .{ .expr = inner_r.?, .alias = null };
            sub2.where = try andAll(alloc, rpreds.items);
            sub2.order_by = &.{};
            sub2.limit = null;
            sub2.offset = null;
            sub2.distinct = false;
            const res = try self.execSelect(alloc, &sub2, false);
            var acc = RangeAcc.init(alloc);
            defer acc.deinit(alloc);
            var has_null = false;
            for (res.rows) |r| {
                if (r[0] == .null) {
                    has_null = true;
                    continue;
                }
                if (r[1] == .null) continue;
                const kstr = try fmtKey(alloc, r[0]);
                switch (r[1]) {
                    .int => |i| acc.addNum(alloc, kstr, @floatFromInt(i)),
                    .float => |f| if (!std.math.isNan(f)) acc.addNum(alloc, kstr, f),
                    .boolean => |b| acc.addNum(alloc, kstr, @floatFromInt(@intFromBool(b))),
                    .text => |tv2| acc.addStr(alloc, kstr, tv2),
                    .null => {},
                }
            }
            try bindExpr(outer_r.?, cols);
            const mp = self.materializeRangeMap(&acc, self.gpa) orelse return false;
            try self.corrList().append(std.heap.page_allocator, .{
                .expr = e,
                .keys = &.{},
                .set = std.StringHashMap(void).init(self.gpa),
                .negated = negated,
                .for_in = for_in,
                .has_null = has_null,
                .range_map = mp,
                .range_keys = .{ outer_r.?, null },
                .range_ops = .{ rop.?, .ge },
                .range_n = 1,
                .operand = in_operand.?,
            });
            return true;
        }
        if (outer_keys.items.len == 0) return false;

        // Build the inner probe query: SELECT <inner keys> [, <range key>] FROM ...
        if (range_n == 2 and exprHash(range_cs[0].?.inner) != exprHash(range_cs[1].?.inner)) return false;
        const nkeys = inner_items.items.len;
        const nproj = nkeys + (if (range_n > 0) @as(usize, 1) else 0);
        var sub2 = sub.*;
        sub2.items = try alloc.alloc(sql.SelectItem, nproj);
        for (inner_items.items, 0..) |it, i| sub2.items[i] = .{ .expr = it, .alias = null };
        if (range_n > 0) sub2.items[nkeys] = .{ .expr = range_cs[0].?.inner, .alias = null };
        sub2.where = try andAll(alloc, preds.items);
        sub2.order_by = &.{};
        sub2.limit = null;
        sub2.offset = null;
        sub2.distinct = false;
        const res = try self.execSelect(alloc, &sub2, false);

        var set = std.StringHashMap(void).init(self.gpa);
        var has_null = false;
        var acc = RangeAcc.init(alloc);
        defer acc.deinit(alloc);
        var rmap: ?*std.StringHashMap(RangeBound) = null;
        for (res.rows) |r| {
            var key = std.ArrayList(u8).empty;
            defer key.deinit(alloc);
            var any_null = false;
            for (r) |v| {
                if (v == .null) any_null = true;
            }
            if (any_null) {
                has_null = true;
                continue;
            }
            for (r[0..nkeys], 0..) |v, i| {
                if (i > 0) try key.append(alloc, 0x1f);
                try key.appendSlice(alloc, try fmtKey(alloc, v));
            }
            if (range_n > 0) {
                switch (r[nkeys]) {
                    .int => |i| acc.addNum(alloc, key.items, @floatFromInt(i)),
                    .float => |f| if (!std.math.isNan(f)) acc.addNum(alloc, key.items, f),
                    .boolean => |b| acc.addNum(alloc, key.items, @floatFromInt(@intFromBool(b))),
                    .text => |tv2| acc.addStr(alloc, key.items, tv2),
                    .null => {},
                }
            } else {
                const gop = try set.getOrPut(key.items);
                if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, key.items);
            }
        }
        if (range_n > 0) {
            rmap = self.materializeRangeMap(&acc, self.gpa) orelse return false;
        }
        // Bind the outer key expressions to the outer row's columns.
        for (outer_keys.items) |k| try bindExpr(k, cols);
        {
            var ri: usize = 0;
            while (ri < range_n) : (ri += 1) try bindExpr(range_cs[ri].?.outer, cols);
        }
        try self.corrList().append(std.heap.page_allocator, .{
            .expr = e,
            .keys = try outer_keys.toOwnedSlice(alloc),
            .set = set,
            .negated = negated,
            .for_in = for_in,
            .has_null = has_null,
            .range_map = rmap,
            .range_keys = .{ if (range_n > 0) range_cs[0].?.outer else null, if (range_n > 1) range_cs[1].?.outer else null },
            .range_ops = .{ if (range_n > 0) range_cs[0].?.op else .ge, if (range_n > 1) range_cs[1].?.op else .ge },
            .range_n = range_n,
            .operand = null,
        });
        return true;
    }

    /// Evaluate a rewritten correlated predicate for one outer row.
    fn corrMatch(self: *Engine, alloc: std.mem.Allocator, cp: *const CorrPlan, row: ?[]Value, cols: []Column, group: ?[]const []Value) EngineError!bool {
        if (cp.range_map) |rm| {
            var kbuf = std.ArrayList(u8).empty;
            defer kbuf.deinit(alloc);
            if (cp.keys.len > 0) {
                for (cp.keys, 0..) |k, i| {
                    const v = try self.eval(alloc, k, row, cols, group);
                    if (v == .null) return false;
                    if (i > 0) try kbuf.append(alloc, 0x1f);
                    try kbuf.appendSlice(alloc, try fmtKey(alloc, v));
                }
            } else {
                const v = try self.eval(alloc, cp.operand.?, row, cols, group);
                if (v == .null) return false;
                try kbuf.appendSlice(alloc, try fmtKey(alloc, v));
            }
            const bound = rm.get(kbuf.items) orelse {
                if (cp.for_in and cp.negated and cp.has_null) return false;
                return cp.negated;
            };
            if (bound.is_str) {
                var has_lo = false;
                var lo_s: []const u8 = &.{};
                var lo_strict = false;
                var has_hi = false;
                var hi_s: []const u8 = &.{};
                var hi_strict = false;
                var ri: usize = 0;
                while (ri < cp.range_n) : (ri += 1) {
                    const rk = cp.range_keys[ri] orelse return false;
                    const ko = try self.eval(alloc, rk, row, cols, group);
                    if (ko == .null) return false;
                    if (ko != .text) return false;
                    const sv = ko.text;
                    switch (cp.range_ops[ri]) {
                        .ge, .gt => {
                            const strict = cp.range_ops[ri] == .gt;
                            if (!has_lo) {
                                has_lo = true;
                                lo_s = sv;
                                lo_strict = strict;
                            } else switch (std.mem.order(u8, sv, lo_s)) {
                                .gt => {
                                    lo_s = sv;
                                    lo_strict = strict;
                                },
                                .eq => lo_strict = lo_strict or strict,
                                .lt => {},
                            }
                        },
                        .le, .lt => {
                            const strict = cp.range_ops[ri] == .lt;
                            if (!has_hi) {
                                has_hi = true;
                                hi_s = sv;
                                hi_strict = strict;
                            } else switch (std.mem.order(u8, sv, hi_s)) {
                                .lt => {
                                    hi_s = sv;
                                    hi_strict = strict;
                                },
                                .eq => hi_strict = hi_strict or strict,
                                .gt => {},
                            }
                        },
                        else => return false,
                    }
                }
                const sh_hit = bound.hitsStrRange(has_lo, lo_s, lo_strict, has_hi, hi_s, hi_strict);
                if (cp.for_in and cp.negated and cp.has_null and !sh_hit) return false;
                return if (cp.negated) !sh_hit else sh_hit;
            }
            var lower: f64 = -std.math.inf(f64);
            var lower_strict = false;
            var upper: f64 = std.math.inf(f64);
            var upper_strict = false;
            var ri: usize = 0;
            while (ri < cp.range_n) : (ri += 1) {
                const rk = cp.range_keys[ri] orelse return false;
                const ko = try self.eval(alloc, rk, row, cols, group);
                if (ko == .null) return false;
                const kv: f64 = switch (ko) {
                    .int => |i| @floatFromInt(i),
                    .float => |f| f,
                    .boolean => |b| @floatFromInt(@intFromBool(b)),
                    else => return false,
                };
                switch (cp.range_ops[ri]) {
                    .ge, .gt => {
                        const strict = cp.range_ops[ri] == .gt;
                        if (kv > lower) {
                            lower = kv;
                            lower_strict = strict;
                        } else if (kv == lower) {
                            lower_strict = lower_strict or strict;
                        }
                    },
                    .le, .lt => {
                        const strict = cp.range_ops[ri] == .lt;
                        if (kv < upper) {
                            upper = kv;
                            upper_strict = strict;
                        } else if (kv == upper) {
                            upper_strict = upper_strict or strict;
                        }
                    },
                    else => return false,
                }
            }
            const hit = bound.hits(lower, lower_strict, upper, upper_strict);
            if (cp.for_in and cp.negated and cp.has_null and !hit) return false;
            return if (cp.negated) !hit else hit;
        }
        var key = std.ArrayList(u8).empty;
        defer key.deinit(alloc);
        var any_null = false;
        for (cp.keys, 0..) |k, i| {
            const v = try self.eval(alloc, k, row, cols, group);
            if (v == .null) any_null = true;
            if (i > 0) try key.append(alloc, 0x1f);
            if (v != .null) try key.appendSlice(alloc, try formatValue(alloc, v));
        }
        if (any_null) {
            // NULL never matches: EXISTS false, NOT EXISTS true; IN/NOT IN is
            // unknown -> filtered out.
            return if (cp.for_in) false else !cp.negated;
        }
        const has = cp.set.contains(key.items);
        if (cp.for_in and cp.negated and cp.has_null and !has) return false;
        return if (cp.negated) !has else has;
    }

    fn clearSubqueries(self: *Engine, sets_base: usize, exists_base: usize) void {
        while (self.sqs().items.len > sets_base) {
            var si = self.sqs().pop().?;
            var it = si.set.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            si.set.deinit();
        }
        while (self.sqe().items.len > exists_base) _ = self.sqe().pop();
        while (self.corrList().items.len > 0) {
            var cp = self.corrList().pop().?;
            var it = cp.set.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            cp.set.deinit();
            if (cp.range_map) |m0| {
                var kit = m0.iterator();
                while (kit.next()) |e| {
                    if (e.value_ptr.keys.len > 0) self.gpa.free(@constCast(e.value_ptr.keys));
                    if (e.value_ptr.skeys.len > 0) {
                        for (e.value_ptr.skeys) |sk| self.gpa.free(@constCast(sk));
                        self.gpa.free(@constCast(e.value_ptr.skeys));
                    }
                    if (e.value_ptr.is_str) {
                        self.gpa.free(@constCast(e.value_ptr.slo));
                        self.gpa.free(@constCast(e.value_ptr.shi));
                    }
                    self.gpa.free(e.key_ptr.*);
                }
                m0.deinit();
                self.gpa.destroy(m0);
            }
        }
    }

    fn execSimple(self: *Engine, alloc: std.mem.Allocator, sel: *sql.Select, apply_tail: bool) EngineError!Result {
        var rows = std.ArrayList([]Value).empty;
        defer rows.deinit(alloc);
        var cols: []Column = &.{};
        var name_buf: [256]u8 = undefined;
        _ = &name_buf;

        if (sel.from == null) {
            try rows.append(alloc, &.{});
        }
        if (sel.from) |from| {
            switch (from) {
                .table => |tn| {
                    // Snapshot-backed tables materialise their row store lazily;
                    // the row engine (e.g. subquery predicates) needs it.
                    self.ensureRowsMaterialized(tn);
                    // Row-engine scans count toward the learned Q as well.
                    self.noteScan(tn);
                    const t = self.find(tn) orelse return error.TableNotFound;
                    cols = t.cols;
                    if (sel.alias_cols.len > 0 and sel.alias_cols.len != cols.len) return error.TableColumnMismatch;
                    if (sel.alias) |al| {
                        cols = try alloc.dupe(Column, t.cols);
                        for (cols) |*c| c.source = al;
                    }
                    for (t.rows.items, 0..) |_, ri| {
                        if (isRowDeleted(t, ri)) continue;
                        if (!self.visibleRow(t, ri)) continue;
                        try rows.append(alloc, try materializeRow(alloc, t, ri));
                    }
                },
                .values => |vrows| {
                    const ncols = if (vrows.len > 0) vrows[0].len else sel.alias_cols.len;
                    cols = try alloc.alloc(Column, ncols);
                    for (0..ncols) |i| {
                        const nm = if (i < sel.alias_cols.len) sel.alias_cols[i] else try std.fmt.allocPrint(alloc, "column{d}", .{i + 1});
                        var bits: u8 = 0;
                        if (vrows.len > 0 and i < vrows[0].len) bits = exprIntBits(vrows[0][i], &.{});
                        cols[i] = .{ .name = nm, .ty = .int, .int_bits = bits };
                    }
                    for (vrows) |vr| {
                        const row = try alloc.alloc(Value, ncols);
                        for (vr, 0..) |e, i| {
                            if (i >= ncols) break;
                            row[i] = try self.eval(alloc, e, null, &.{}, null);
                            if (row[i] == .float) {
                                var is_num = false;
                                switch (e.*) {
                                    .cast => |c| is_num = std.ascii.eqlIgnoreCase(c.type_name, "numeric"),
                                    else => {},
                                }
                                if (is_num) cols[i].is_numeric = true;
                            }
                        }
                        try rows.append(alloc, row);
                    }
                },
                .subquery => |sub| {
                    const sub_res = try self.execSelect(alloc, sub, true);
                    const ncols = sub_res.columns.len;
                    var defs = try alloc.alloc(ColumnDef, ncols);
                    for (sub_res.columns, 0..) |cn, i| {
                        defs[i] = .{ .name = cn, .type_name = "int" };
                    }
                    cols = try alloc.alloc(Column, ncols);
                    for (sub_res.columns, 0..) |cn, i| {
                        cols[i] = .{ .name = cn, .ty = .int };
                    }
                    if (sel.alias_cols.len > 0 and sel.alias_cols.len != cols.len) return error.TableColumnMismatch;
                    for (sub_res.rows) |r| try rows.append(alloc, r);
                },
                .function => |f| {
                    if (std.ascii.eqlIgnoreCase(f.name, "generate_series")) {
                        if (f.args.len < 2) return error.SyntaxError;
                        const lo = try self.eval(alloc, f.args[0], null, &.{}, null);
                        const hi = try self.eval(alloc, f.args[1], null, &.{}, null);
                        var step: i64 = 1;
                        if (f.args.len >= 3) {
                            const sv = try self.eval(alloc, f.args[2], null, &.{}, null);
                            step = switch (sv) { .int => |x| x, else => 1 };
                        }
                        if (step == 0) return error.StepZero;
                        cols = try alloc.alloc(Column, 1);
                        cols[0] = .{ .name = "generate_series", .ty = .int };
                        var x: i64 = switch (lo) { .int => |v| v, else => 0 };
                        const end: i64 = switch (hi) { .int => |v| v, else => 0 };
                        while ((step > 0 and x <= end) or (step < 0 and x >= end)) {
                            const row = try alloc.alloc(Value, 1);
                            row[0] = .{ .int = x };
                            try rows.append(alloc, row);
                            const nx = @addWithOverflow(x, step);
                            if (nx[1] != 0) break;
                            x = nx[0];
                        }
                    } else if (std.ascii.eqlIgnoreCase(f.name, "pg_input_error_info")) {
                    if (f.args.len < 2) return error.SyntaxError;
                    const val = try self.eval(alloc, f.args[0], null, &.{}, null);
                    const typ = try self.eval(alloc, f.args[1], null, &.{}, null);
                    const val_s = try formatValue(alloc, val);
                    const typ_s = try formatValue(alloc, typ);
                    if (inputErrorInfo(alloc, val_s, typ_s)) |err| {
                        const names = [_][]const u8{ "message", "detail", "hint", "sql_error_code" };
                        cols = try alloc.alloc(Column, names.len);
                        for (names, 0..) |cn, i| cols[i] = .{ .name = cn, .ty = .text };
                        const row = try alloc.alloc(Value, names.len);
                        row[0] = .{ .text = err.message };
                        row[1] = .null;
                        row[2] = .null;
                        row[3] = .{ .text = err.code };
                        try rows.append(alloc, row);
                    } else {
                        cols = try alloc.alloc(Column, 0);
                    }
                    } else return error.Unsupported;
                },
            }
        }

        // Bind column references to positional indexes once per query.
        for (sel.items) |it| try bindExpr(it.expr, cols);
        if (sel.where) |w| try bindExpr(w, cols);
        for (sel.group_by) |g| try bindExpr(g, cols);
        if (sel.having) |h| try bindExpr(h, cols);
        for (sel.order_by) |o| bindExpr(o.expr, cols) catch {};

        // HAVING without GROUP BY: bare columns are invalid, and when neither
        // the target list nor HAVING has aggregates the result is decided
        // without scanning the table (so WHERE is not evaluated either).
        if (sel.having) |h| {
            if (sel.group_by.len == 0) {
                for (sel.items) |it| try rejectBareColumns(it.expr, cols);
                try rejectBareColumns(h, cols);
                if (!anyAggregate(sel.items) and !exprHasAgg(h)) {
                    var quick_cols = std.ArrayList([]const u8).empty;
                    defer quick_cols.deinit(alloc);
                    for (sel.items) |it| try quick_cols.append(alloc, it.alias orelse exprName(it.expr));
                    const hv = try self.eval(alloc, h, null, cols, null);
                    if (!truthy(hv)) {
                        return .{ .columns = try quick_cols.toOwnedSlice(alloc), .rows = try alloc.alloc([]Value, 0) };
                    }
                    const row = try alloc.alloc(Value, sel.items.len);
                    for (sel.items, 0..) |it, i| row[i] = try self.eval(alloc, it.expr, null, cols, null);
                    const rows_out = try alloc.alloc([]Value, 1);
                    rows_out[0] = row;
                    return .{ .columns = try quick_cols.toOwnedSlice(alloc), .rows = rows_out };
                }
            }
        }

        // WHERE (prepared subqueries first: IN (SELECT ...) / EXISTS (...))
        // NOTE: the cleanup defer must live in the *function* scope; inside the
        // `if` block it would run before the filter loop and empty the sets.
        var subq_base: usize = self.sqs().items.len;
        var subq_exists_base: usize = self.sqe().items.len;
        defer self.clearSubqueries(subq_base, subq_exists_base);
        if (sel.where) |w| {
            subq_base = self.sqs().items.len;
            subq_exists_base = self.sqe().items.len;
            try self.prepareSubqueries(alloc, w, cols);
        }
        if (sel.where) |w| {
            var filtered = std.ArrayList([]Value).empty;
            if (rows.items.len >= 100_000) {
                try filterParallel(self, alloc, rows.items, cols, w, &filtered);
            } else {
                for (rows.items) |row| {
                    const v = try self.eval(alloc, w, row, cols, null);
                    if (truthy(v)) try filtered.append(alloc, row);
                }
            }
            rows.deinit(alloc);
            rows = filtered;
        }

        const aggregate_query = sel.group_by.len > 0 or anyAggregate(sel.items) or sel.having != null;

        var out = std.ArrayList([]Value).empty;
        defer out.deinit(alloc);
        var ctxs = std.ArrayList(RowCtx).empty;
        defer ctxs.deinit(alloc);
        var out_cols = std.ArrayList([]const u8).empty;
        defer out_cols.deinit(alloc);

        if (aggregate_query) {
            try self.runAggregated(alloc, sel, rows.items, cols, &out, &ctxs, &out_cols);
        } else {
            for (rows.items) |row| {
                const projected = try self.project(alloc, sel.items, row, cols, null, &out_cols, out.items.len == 0);
                try out.append(alloc, projected);
                try ctxs.append(alloc, .{ .row = row });
            }
        }

        if (sel.distinct) {
            var seen = std.StringHashMap(void).init(alloc);
            var uniq = std.ArrayList([]Value).empty;
            defer uniq.deinit(alloc);
            for (out.items) |r| {
                var key = std.ArrayList(u8).empty;
                defer key.deinit(alloc);
                for (r) |v| {
                    const s = try formatValue(alloc, v);
                    try key.appendSlice(alloc, s);
                    try key.append(alloc, 0x1f);
                }
                const gop = try seen.getOrPut(key.items);
                if (!gop.found_existing) try uniq.append(alloc, r);
            }
            seen.deinit();
            out.deinit(alloc);
            out = uniq;
        }

        if (out.items.len == 0 and out_cols.items.len == 0) {
            for (sel.items) |it| {
                if (it.expr.* == .star) {
                    for (cols) |c| try out_cols.append(alloc, c.name);
                } else if (it.expr.* == .star_table) {
                    const q = it.expr.star_table;
                    for (cols) |c| if (std.ascii.eqlIgnoreCase(c.source, q)) try out_cols.append(alloc, c.name);
                } else {
                    try out_cols.append(alloc, it.alias orelse exprName(it.expr));
                }
            }
        }
        var res = Result{ .columns = try out_cols.toOwnedSlice(alloc), .rows = try out.toOwnedSlice(alloc), .format_json = sel.format_json };
        if (apply_tail) res = try self.applyTail(alloc, res, sel, try ctxs.toOwnedSlice(alloc), cols);
        return res;
    }

    fn applyTail(self: *Engine, alloc: std.mem.Allocator, res_in: Result, sel: *sql.Select, ctxs: []RowCtx, cols: []Column) EngineError!Result {
        var res = res_in;
        if (sel.order_by.len > 0) {
            // sort rows, using alias/column/expression evaluation
            const items = sel.order_by;
            const Entry = struct {
                row: []Value,
                ctx: ?[]Value,
                group: ?[]const []Value,
                agg: ?[]const Value,
                agg_exprs: []const *sql.Expr,
            };
            const entries = try alloc.alloc(Entry, res.rows.len);
            for (res.rows, 0..) |row, i| {
                if (i < ctxs.len) {
                    entries[i] = .{ .row = row, .ctx = ctxs[i].row, .group = ctxs[i].group, .agg = ctxs[i].agg, .agg_exprs = ctxs[i].agg_exprs };
                } else {
                    entries[i] = .{ .row = row, .ctx = null, .group = null, .agg = null, .agg_exprs = &.{} };
                }
            }
            const SortCtx = struct {
                engine: *Engine,
                alloc: std.mem.Allocator,
                cols: []Column,
                items: []sql.OrderItem,
                columns: []const []const u8,

                fn lessThanFn(c: *@This(), a: Entry, b: Entry) bool {
                    for (c.items) |item| {
                        const av = evalOrder(c, item.expr, a.row, a.ctx, a.group, a.agg, a.agg_exprs) catch Value.null;
                        const bv = evalOrder(c, item.expr, b.row, b.ctx, b.group, b.agg, b.agg_exprs) catch Value.null;
                        const ord = Value.order(av, bv);
                        if (ord == .eq) continue;
                        const less = ord == .lt;
                        return if (item.desc) !less else less;
                    }
                    return false;
                }

                fn evalOrder(c: *@This(), e: *sql.Expr, out_row: []Value, ctx_row: ?[]Value, group: ?[]const []Value, agg: ?[]const Value, agg_exprs: []const *sql.Expr) !Value {
                    switch (e.*) {
                        .column => |name| {
                            if (ctx_row) |r| {
                                if (findColSlice(c.cols, name)) |idx| {
                                    if (idx < r.len) return r[idx];
                                }
                            }
                            for (c.columns, 0..) |cn, idx| {
                                if (std.ascii.eqlIgnoreCase(cn, name) and idx < out_row.len) return out_row[idx];
                            }
                            return Value.null;
                        },
                        .column_idx => |ci| {
                            if (ctx_row) |r| {
                                if (ci.idx < r.len) return r[ci.idx];
                            }
                            if (ci.idx < out_row.len) return out_row[ci.idx];
                            return Value.null;
                        },
                        .int => |v| return .{ .int = v },
                        else => {
                            const saved = c.engine.agg_ctx;
                            if (agg) |vals| c.engine.agg_ctx = .{ .exprs = agg_exprs, .vals = vals };
                            defer c.engine.agg_ctx = saved;
                            if (ctx_row) |r| return c.engine.eval(c.alloc, e, r, c.cols, group);
                            return c.engine.eval(c.alloc, e, null, c.cols, group);
                        },
                    }
                }
            };
            var ctx = SortCtx{
                .engine = self,
                .alloc = alloc,
                .cols = cols,
                .items = items,
                .columns = res.columns,
            };

            // Top-K: keep only offset+limit rows when the result set is much
            // larger than the requested window (Umbra's Frequent/top-k path).
            var top_k: ?usize = null;
            if (sel.limit) |l| {
                const lim = try exprToUsize(try self.eval(alloc, l, null, &.{}, null));
                const off = if (sel.offset) |o| try exprToUsize(try self.eval(alloc, o, null, &.{}, null)) else 0;
                const k = lim + off;
                if (k > 0 and k * 4 < entries.len) top_k = k;
            }

            if (top_k) |kk| {
                const heap = try alloc.alloc(Entry, kk);
                @memcpy(heap, entries[0..kk]);
                var hi: usize = kk / 2;
                while (hi > 0) {
                    hi -= 1;
                    siftDown(&ctx, heap, hi);
                }
                for (entries[kk..]) |en| {
                    if (SortCtx.lessThanFn(&ctx, en, heap[0])) {
                        heap[0] = en;
                        siftDown(&ctx, heap, 0);
                    }
                }
                std.mem.sort(Entry, heap, &ctx, SortCtx.lessThanFn);
                const rows = try alloc.alloc([]Value, heap.len);
                for (heap, 0..) |en, i| rows[i] = en.row;
                res.rows = rows;
            } else {
                std.mem.sort(Entry, entries, &ctx, SortCtx.lessThanFn);
                const rows = try alloc.alloc([]Value, entries.len);
                for (entries, 0..) |en, i| rows[i] = en.row;
                res.rows = rows;
            }
        }
        if (sel.offset) |o| {
            const off = try exprToUsize(try self.eval(alloc, o, null, &.{}, null));
            if (off >= res.rows.len) {
                res.rows = &.{};
            } else {
                res.rows = res.rows[off..];
            }
        }
        if (sel.limit) |l| {
            const lim = try exprToUsize(try self.eval(alloc, l, null, &.{}, null));
            if (lim < res.rows.len) res.rows = res.rows[0..lim];
        }
        return res;
    }

    fn runAggregated(
        self: *Engine,
        alloc: std.mem.Allocator,
        sel: *sql.Select,
        rows: []const []Value,
        cols: []Column,
        out: *std.ArrayList([]Value),
        ctxs: *std.ArrayList(RowCtx),
        out_cols: *std.ArrayList([]const u8),
    ) EngineError!void {
        var specs_list = std.ArrayList(AggSpec).empty;
        defer specs_list.deinit(alloc);
        var exprs = std.ArrayList(*sql.Expr).empty;
        defer exprs.deinit(alloc);
        for (sel.items) |it| try collectAggCalls(alloc, it.expr, &specs_list, &exprs);
        if (sel.having) |h| try collectAggCalls(alloc, h, &specs_list, &exprs);
        for (sel.order_by) |o| try collectAggCalls(alloc, o.expr, &specs_list, &exprs);
        const specs = specs_list.items;

        const saved_exprs = tls_agg_exprs;
        tls_agg_exprs = exprs.items;
        defer tls_agg_exprs = saved_exprs;

        var map = std.StringHashMap(u32).init(alloc);
        defer map.deinit();
        var states = std.ArrayList(GroupState).empty;
        defer states.deinit(alloc);

        if (canParallel(specs) and rows.len >= 100_000) {
            try self.aggregateParallel(alloc, rows, cols, sel.group_by, specs, &map, &states);
        } else {
            try self.aggregateSerial(alloc, rows, cols, sel.group_by, specs, &map, &states);
        }

        if (states.items.len == 0 and sel.group_by.len == 0) {
            const accs = try alloc.alloc(Acc, specs.len);
            for (accs) |*a| a.* = .{};
            try states.append(alloc, .{ .first = null, .accs = accs });
        }

        for (states.items) |*st| {
            const vals = try alloc.alloc(Value, specs.len);
            for (specs, 0..) |spec, si| vals[si] = try finalizeAcc(alloc, &st.accs[si], spec);
            const ctx = AggCtx{ .exprs = exprs.items, .vals = vals };

            if (sel.having) |h| {
                self.agg_ctx = ctx;
                const hv = self.eval(alloc, h, st.first, cols, null) catch |e| {
                    self.agg_ctx = null;
                    return e;
                };
                self.agg_ctx = null;
                if (!truthy(hv)) continue;
            }

            const projected = try self.projectCtx(alloc, sel.items, st.first, cols, ctx, out_cols, out.items.len == 0);
            try out.append(alloc, projected);
            try ctxs.append(alloc, .{ .row = st.first, .agg = vals, .agg_exprs = exprs.items });
        }
    }

    fn filterParallel(
        self: *Engine,
        alloc: std.mem.Allocator,
        rows: []const []Value,
        cols: []Column,
        where: *sql.Expr,
        out: *std.ArrayList([]Value),
    ) EngineError!void {
        const cpu = std.Thread.getCpuCount() catch 4;
        const nthreads = @min(@max(cpu, 2), 8);
        const chunk = (rows.len + nthreads - 1) / nthreads;
        var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
        defer alloc.free(arenas);
        var workers = try alloc.alloc(FilterWorker, nthreads);
        defer alloc.free(workers);
        var threads = try alloc.alloc(?std.Thread, nthreads);
        defer alloc.free(threads);

        for (0..nthreads) |i| {
            const start_i = i * chunk;
            const end_i = @min(start_i + chunk, rows.len);
            arenas[i] = std.heap.ArenaAllocator.init(self.gpa);
            workers[i] = .{
                .engine = self,
                .rows = rows[start_i..end_i],
                .cols = cols,
                .where = where,
                .alloc = arenas[i].allocator(),
                .subq_sets = self.sqs().items,
                .subq_exists = self.sqe().items,
                .corr = self.corrList().items,
            };
            threads[i] = null;
            if (start_i < end_i) {
                threads[i] = std.Thread.spawn(.{}, FilterWorker.run, .{&workers[i]}) catch null;
            }
        }
        for (0..nthreads) |i| if (threads[i]) |t| t.join();
        defer for (arenas) |*a| a.deinit();

        for (workers) |*w| {
            if (w.err) |e| return e;
            try out.appendSlice(alloc, w.out.items);
        }
    }

    fn aggregateSerial(
        self: *Engine,
        alloc: std.mem.Allocator,
        rows: []const []Value,
        cols: []Column,
        group_by: []*sql.Expr,
        specs: []const AggSpec,
        map: *std.StringHashMap(u32),
        states: *std.ArrayList(GroupState),
    ) EngineError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(alloc);
        for (rows) |row| {
            key.clearRetainingCapacity();
            for (group_by) |g| {
                const v = try self.eval(alloc, g, row, cols, null);
                try appendKey(alloc, &key, v);
            }
            const gop = try map.getOrPut(key.items);
            var idx: u32 = undefined;
            if (!gop.found_existing) {
                gop.key_ptr.* = try alloc.dupe(u8, key.items);
                idx = @intCast(states.items.len);
                gop.value_ptr.* = idx;
                const accs = try alloc.alloc(Acc, specs.len);
                for (accs) |*a| a.* = .{};
                try states.append(alloc, .{ .first = row, .accs = accs });
            } else {
                idx = gop.value_ptr.*;
            }
            const st = &states.items[idx];
            for (specs, 0..) |spec, si| try self.updateAcc(alloc, &st.accs[si], spec, row, cols);
        }
    }

    fn aggregateParallel(
        self: *Engine,
        alloc: std.mem.Allocator,
        rows: []const []Value,
        cols: []Column,
        group_by: []*sql.Expr,
        specs: []const AggSpec,
        map: *std.StringHashMap(u32),
        states: *std.ArrayList(GroupState),
    ) EngineError!void {
        const cpu = std.Thread.getCpuCount() catch 4;
        const nthreads = @min(@max(cpu, 2), 8);
        const chunk = (rows.len + nthreads - 1) / nthreads;

        var arenas = try alloc.alloc(std.heap.ArenaAllocator, nthreads);
        defer alloc.free(arenas);
        var workers = try alloc.alloc(AggWorker, nthreads);
        defer alloc.free(workers);
        var threads = try alloc.alloc(?std.Thread, nthreads);
        defer alloc.free(threads);

        for (0..nthreads) |i| {
            const start_i = i * chunk;
            const end_i = @min(start_i + chunk, rows.len);
            arenas[i] = std.heap.ArenaAllocator.init(self.gpa);
            workers[i] = .{
                .engine = self,
                .rows = rows[start_i..end_i],
                .cols = cols,
                .group_by = group_by,
                .specs = specs,
                .alloc = arenas[i].allocator(),
            };
            threads[i] = null;
            if (start_i < end_i) {
                threads[i] = std.Thread.spawn(.{}, AggWorker.run, .{&workers[i]}) catch null;
            } else {
                workers[i].run();
            }
        }

        for (0..nthreads) |i| {
            if (threads[i]) |t| t.join();
        }
        defer for (arenas) |*a| a.deinit();

        for (workers) |*w| {
            if (w.err) |e| return e;
            var it = w.map.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                const local = w.states.items[e.value_ptr.*];
                const gop = try map.getOrPut(key);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try alloc.dupe(u8, key);
                    gop.value_ptr.* = @intCast(states.items.len);
                    const accs = try alloc.alloc(Acc, specs.len);
                    for (accs, 0..) |*a, si| a.* = local.accs[si];
                    try states.append(alloc, .{ .first = local.first, .accs = accs });
                } else {
                    const dst = &states.items[gop.value_ptr.*];
                    for (dst.accs, local.accs, 0..) |*d, src, si| try mergeAcc(alloc, d, src, specs[si]);
                }
            }
        }
    }

    fn projectCtx(
        self: *Engine,
        alloc: std.mem.Allocator,
        items: []sql.SelectItem,
        row: ?[]Value,
        cols: []Column,
        ctx: AggCtx,
        out_cols: *std.ArrayList([]const u8),
        fill_names: bool,
    ) EngineError![]Value {
        var vals = std.ArrayList(Value).empty;
        defer vals.deinit(alloc);
        self.agg_ctx = ctx;
        defer self.agg_ctx = null;
        for (items) |item| {
            switch (item.expr.*) {
                .star => {
                    if (row) |r| {
                        for (r) |v| try vals.append(alloc, v);
                        if (fill_names) for (cols) |c| try out_cols.append(alloc, c.name);
                    }
                },
                .star_table => |q| {
                    if (row) |r| {
                        for (cols, 0..) |c, ci| {
                            if (ci < r.len and std.ascii.eqlIgnoreCase(c.source, q)) {
                                try vals.append(alloc, r[ci]);
                                if (fill_names) try out_cols.append(alloc, c.name);
                            }
                        }
                    }
                },
                else => {
                    try vals.append(alloc, try self.eval(alloc, item.expr, row, cols, null));
                    if (fill_names) try out_cols.append(alloc, item.alias orelse exprName(item.expr));
                },
            }
        }
        return vals.toOwnedSlice(alloc);
    }

    fn updateAcc(self: *Engine, alloc: std.mem.Allocator, acc: *Acc, spec: AggSpec, row: []Value, cols: []Column) EngineError!void {
        var v: Value = .null;
        if (spec.arg) |a| {
            if (spec.arg_idx >= 0) {
                const i: usize = @intCast(spec.arg_idx);
                v = if (i < row.len) row[i] else .null;
            } else {
                v = try self.eval(alloc, a, row, cols, null);
            }
        }
        switch (spec.kind) {
            .count_all => acc.n += 1,
            .count => {
                if (!v.isNull()) acc.n += 1;
            },
            .count_distinct => {
                if (v.isNull()) return;
                if (acc.set == null) {
                    const set = try alloc.create(std.StringHashMap(void));
                    set.* = std.StringHashMap(void).init(alloc);
                    acc.set = set;
                }
                const s = try formatValue(alloc, v);
                const gop = try acc.set.?.getOrPut(s);
                if (!gop.found_existing) acc.n += 1;
            },
            .sum, .avg => switch (v) {
                .int => |x| {
                    acc.isum += x;
                    acc.n += 1;
                },
                .float => |x| {
                    acc.has_float = true;
                    acc.fsum += x;
                    acc.n += 1;
                },
                else => {},
            },
            .min, .max => {
                if (v.isNull()) return;
                if (!acc.has_best) {
                    acc.best = v;
                    acc.has_best = true;
                } else {
                    const ord = Value.order(v, acc.best);
                    const better = if (spec.kind == .min) ord == .lt else ord == .gt;
                    if (better) acc.best = v;
                }
            },
        }
    }

    fn project(self: *Engine, alloc: std.mem.Allocator, items: []sql.SelectItem, row: ?[]Value, cols: []Column, group: ?[]const []Value, out_cols: *std.ArrayList([]const u8), fill_names: bool) EngineError![]Value {
        var vals = std.ArrayList(Value).empty;
        defer vals.deinit(alloc);
        for (items) |item| {
            switch (item.expr.*) {
                .star => {
                    if (row) |r| {
                        for (r) |v| try vals.append(alloc, v);
                        if (fill_names) {
                            for (cols) |c| try out_cols.append(alloc, c.name);
                        }
                    }
                },
                .star_table => |q| {
                    if (row) |r| {
                        for (cols, 0..) |c, ci| {
                            if (ci < r.len and std.ascii.eqlIgnoreCase(c.source, q)) {
                                try vals.append(alloc, r[ci]);
                                if (fill_names) try out_cols.append(alloc, c.name);
                            }
                        }
                    }
                },
                else => {
                    const v = try self.eval(alloc, item.expr, row, cols, group);
                    try vals.append(alloc, v);
                    if (fill_names) try out_cols.append(alloc, item.alias orelse exprName(item.expr));
                },
            }
        }
        return vals.toOwnedSlice(alloc);
    }

    fn eval(self: *Engine, alloc: std.mem.Allocator, e: *sql.Expr, row: ?[]Value, cols: []Column, group: ?[]const []Value) EngineError!Value {
        switch (e.*) {
            .column_idx => |ci| {
                if (row) |r| {
                    if (ci.idx < r.len) return r[ci.idx];
                }
                return Value.null;
            },
            .int => |v| return .{ .int = v },
            .float => |v| return .{ .float = v },
            .string => |s| return .{ .text = s },
            .null_lit => return .null,
            .star, .star_table => return .null,
            .column => |name| {
                if (row) |r| {
                    if (findColSlice(cols, name)) |idx| {
                        if (idx < r.len) return r[idx];
                    }
                    return error.UnknownColumn;
                }
                return Value.null;
            },
            .negate => |op| {
                const v = try self.eval(alloc, op, row, cols, group);
                if (v == .int) {
                    const bits = exprIntBits(op, cols);
                    if ((bits == 8 and v.int == std.math.minInt(i64)) or
                        (bits == 4 and v.int == std.math.minInt(i32)) or
                        (bits == 2 and v.int == std.math.minInt(i16))) {
                        return if (bits == 8) error.BigintOutOfRange else if (bits == 4) error.IntegerOutOfRange else error.SmallintOutOfRange;
                    }
                }
                return switch (v) {
                    .int => |x| .{ .int = -x },
                    .float => |x| .{ .float = -x },
                    else => .null,
                };
            },
            .bitnot => |op| {
                const v = try self.eval(alloc, op, row, cols, group);
                if (v == .text) {
                    if (parseMacaddr(v.text)) |m0| {
                        var m = m0;
                        for (&m) |*b| b.* = ~b.*;
                        return .{ .text = try formatMacaddr(alloc, m) };
                    }
                }
                return switch (v) {
                    .int => |x| .{ .int = ~x },
                    else => .null,
                };
            },
            .not => |op| {
                const v = try self.eval(alloc, op, row, cols, group);
                // Three-valued logic: NOT UNKNOWN is UNKNOWN.
                if (v == .null) return .null;
                return .{ .boolean = !truthy(v) };
            },
            .binary => |b| {
                const l = try self.eval(alloc, b.lhs, row, cols, group);
                const r = try self.eval(alloc, b.rhs, row, cols, group);
                const arith0 = b.op == .add or b.op == .sub or b.op == .mul or b.op == .div or b.op == .mod;
                if (arith0 and l == .int and r == .int) {
                    const bits0 = @max(exprIntBits(b.lhs, cols), exprIntBits(b.rhs, cols));
                    if ((b.op == .div or b.op == .mod) and r.int == 0) return error.DivisionByZero;
                    if (bits0 == 8) {
                        if ((b.op == .div or b.op == .mod) and l.int == std.math.minInt(i64) and r.int == -1) {
                            if (b.op == .div) return error.BigintOutOfRange;
                            return .{ .int = 0 };
                        }
                        const p: i128 = switch (b.op) {
                            .add => @as(i128, l.int) + @as(i128, r.int),
                            .sub => @as(i128, l.int) - @as(i128, r.int),
                            .mul => @as(i128, l.int) * @as(i128, r.int),
                            else => 0,
                        };
                        if (b.op == .add or b.op == .sub or b.op == .mul) {
                            if (p < std.math.minInt(i64) or p > std.math.maxInt(i64)) return error.BigintOutOfRange;
                            return .{ .int = @intCast(p) };
                        }
                    }
                }
                const res = try applyBinary(alloc, b.op, l, r);
                const arith = b.op == .add or b.op == .sub or b.op == .mul or b.op == .div;
                if (arith and res == .int) {
                    const bits = @max(exprIntBits(b.lhs, cols), exprIntBits(b.rhs, cols));
                    if (bits == 2 and (res.int < -32768 or res.int > 32767)) return error.SmallintOutOfRange;
                    if (bits == 4 and (res.int < -2147483648 or res.int > 2147483647)) return error.IntegerOutOfRange;
                }
                return res;
            },
            .is_null => |n| {
                const v = try self.eval(alloc, n.operand, row, cols, group);
                const is_null = v.isNull();
                return .{ .boolean = if (n.negated) !is_null else is_null };
            },
            .like => |l| {
                const v = try self.eval(alloc, l.operand, row, cols, group);
                const p = try self.eval(alloc, l.pattern, row, cols, group);
                if (v.isNull() or p.isNull()) return .null;
                const vs = try formatValue(alloc, v);
                const ps = try formatValue(alloc, p);
                const m = likeMatch(vs, ps);
                return .{ .boolean = if (l.negated) !m else m };
            },
            .in_list => |in| {
                const v = try self.eval(alloc, in.operand, row, cols, group);
                if (v == .null) return .null;
                var found = false;
                var has_null = false;
                for (in.items) |it| {
                    const cand = try self.eval(alloc, it, row, cols, group);
                    if (cand == .null) {
                        has_null = true;
                        continue;
                    }
                    if (Value.eql(v, cand)) {
                        found = true;
                        break;
                    }
                }
                if (!found and has_null) return .null;
                return .{ .boolean = if (in.negated) !found else found };
            },
            .between => |bt| {
                const v = try self.eval(alloc, bt.operand, row, cols, group);
                const lo = try self.eval(alloc, bt.low, row, cols, group);
                const hi = try self.eval(alloc, bt.high, row, cols, group);
                if (v.isNull() or lo.isNull() or hi.isNull()) return .null;
                const ge = Value.order(v, lo) != .lt;
                const le = Value.order(v, hi) != .gt;
                const ok = ge and le;
                return .{ .boolean = if (bt.negated) !ok else ok };
            },
            .cast => |c| {
                const v = try self.eval(alloc, c.operand, row, cols, group);
                var numeric_mode = false;
                switch (c.operand.*) {
                    .cast => |inner| numeric_mode = std.ascii.eqlIgnoreCase(inner.type_name, "numeric") or std.ascii.eqlIgnoreCase(inner.type_name, "decimal"),
                    .column_idx => |ci| numeric_mode = ci.idx < cols.len and cols[ci.idx].is_numeric,
                    .column => |nm| {
                        if (findColSlice(cols, nm)) |ci| numeric_mode = cols[ci].is_numeric;
                    },
                    else => {},
                }
                return castValueMode(alloc, v, c.type_name, numeric_mode);
            },
            .case_expr => |c| {
                for (c.whens) |w| {
                    const cond = try self.eval(alloc, w.cond, row, cols, group);
                    if (truthy(cond)) return self.eval(alloc, w.then, row, cols, group);
                }
                if (c.else_expr) |el| return self.eval(alloc, el, row, cols, group);
                return .null;
            },
            .in_subquery => |x| {
                for (self.corrList().items) |*cp| {
                    if (cp.expr == e) return .{ .boolean = try self.corrMatch(alloc, cp, row, cols, group) };
                }
                const lhs = try self.eval(alloc, x.operand, row, cols, group);
                // SQL: a NULL left operand makes IN/NOT IN UNKNOWN.
                if (lhs == .null) return .null;
                const key = try formatValue(alloc, lhs);
                for (self.sqs().items) |si| {
                    if (si.expr != e) continue;
                    const has = si.set.contains(key);
                    if (!has and si.has_null) return .null;
                    return .{ .boolean = if (si.negated) !has else has };
                }
                return .{ .boolean = false };
            },
            .exists => |x| {
                for (self.corrList().items) |*cp| {
                    if (cp.expr == e) return .{ .boolean = try self.corrMatch(alloc, cp, row, cols, group) };
                }
                for (self.sqe().items) |ei| {
                    if (ei.expr == e) return .{ .boolean = if (x.negated) !ei.val else ei.val };
                }
                return .{ .boolean = false };
            },
            .call => |c| {
                if (self.agg_ctx) |ctx| {
                    for (ctx.exprs, 0..) |x, i| {
                        if (x == e) return ctx.vals[i];
                    }
                }
                return self.evalCall(alloc, c, row, cols, group);
            },
        }
    }

    fn evalCall(self: *Engine, alloc: std.mem.Allocator, c: sql.Call, row: ?[]Value, cols: []Column, group: ?[]const []Value) EngineError!Value {
        const lname = c.name;
        if ((std.ascii.eqlIgnoreCase(lname, "gcd") or std.ascii.eqlIgnoreCase(lname, "lcm")) and c.args.len == 2) {
            const a = try self.eval(alloc, c.args[0], row, cols, group);
            const b = try self.eval(alloc, c.args[1], row, cols, group);
            if (a == .null or b == .null) return .null;
            if (a != .int or b != .int) return .null;
            const bits = @max(exprIntBits(c.args[0], cols), exprIntBits(c.args[1], cols));
            return gcdLcmTyped(bits, a.int, b.int, std.ascii.eqlIgnoreCase(lname, "lcm"));
        }
        if (std.ascii.eqlIgnoreCase(lname, "count")) {
            if (group) |g| {
                if (c.star or c.args.len == 0) return .{ .int = @intCast(g.len) };
                var n: i64 = 0;
                if (c.distinct) {
                    var seen = std.StringHashMap(void).init(alloc);
                    for (g) |r| {
                        const v = try self.eval(alloc, c.args[0], r, cols, null);
                        if (v.isNull()) continue;
                        const s = try formatValue(alloc, v);
                        const gop = try seen.getOrPut(s);
                        if (!gop.found_existing) n += 1;
                    }
                } else {
                    for (g) |r| {
                        const v = try self.eval(alloc, c.args[0], r, cols, null);
                        if (!v.isNull()) n += 1;
                    }
                }
                return .{ .int = n };
            }
            return .{ .int = 0 };
        }
        if (std.ascii.eqlIgnoreCase(lname, "sum") or std.ascii.eqlIgnoreCase(lname, "avg")) {
            if (group) |g| {
                var is_float = false;
                var isum: i128 = 0;
                var fsum: f64 = 0;
                var n: i64 = 0;
                for (g) |r| {
                    const v = try self.eval(alloc, c.args[0], r, cols, null);
                    switch (v) {
                        .null => continue,
                        .float => |x| {
                            is_float = true;
                            fsum += x;
                            n += 1;
                        },
                        .int => |x| {
                            isum += x;
                            fsum += @floatFromInt(x);
                            n += 1;
                        },
                        else => {},
                    }
                }
                if (std.ascii.eqlIgnoreCase(lname, "avg")) {
                    if (n == 0) return .null;
                    if (!is_float) return .{ .float = @as(f64, @floatFromInt(isum)) / @as(f64, @floatFromInt(n)) };
                    return .{ .float = fsum / @as(f64, @floatFromInt(n)) };
                }
                if (is_float) return .{ .float = fsum };
                if (isum > std.math.maxInt(i64) or isum < std.math.minInt(i64)) {
                    return .{ .float = @floatFromInt(isum) };
                }
                return .{ .int = @intCast(isum) };
            }
            return .null;
        }
        if (std.ascii.eqlIgnoreCase(lname, "min") or std.ascii.eqlIgnoreCase(lname, "max")) {
            const want_min = std.ascii.eqlIgnoreCase(lname, "min");
            if (group) |g| {
                var best: Value = .null;
                for (g) |r| {
                    const v = try self.eval(alloc, c.args[0], r, cols, null);
                    if (v.isNull()) continue;
                    if (best.isNull()) {
                        best = v;
                        continue;
                    }
                    const ord = Value.order(v, best);
                    if ((want_min and ord == .lt) or (!want_min and ord == .gt)) best = v;
                }
                return best;
            }
            return .null;
        }
        // scalar functions
        var args = std.ArrayList(Value).empty;
        defer args.deinit(alloc);
        for (c.args) |a| try args.append(alloc, try self.eval(alloc, a, row, cols, group));
        return scalarFunc(alloc, c.name, args.items);
    }
};

fn siftDown(ctx: anytype, heap: anytype, start: usize) void {
    const Entry = @TypeOf(heap[0]);
    var i = start;
    while (true) {
        var worst = i;
        const l = 2 * i + 1;
        const r = 2 * i + 2;
        if (l < heap.len and @TypeOf(ctx.*).lessThanFn(ctx, heap[worst], heap[l])) worst = l;
        if (r < heap.len and @TypeOf(ctx.*).lessThanFn(ctx, heap[worst], heap[r])) worst = r;
        if (worst == i) break;
        std.mem.swap(Entry, &heap[i], &heap[worst]);
        i = worst;
    }
}

fn stripTail(sel: *sql.Select) *sql.Select {
    // Union members are executed without their order/limit; the tail belongs to
    // the combined result.
    const copy = std.heap.page_allocator.create(sql.Select) catch unreachable;
    copy.* = sel.*;
    copy.union_all = null;
    copy.order_by = &.{};
    copy.limit = null;
    copy.offset = null;
    copy.format_json = false;
    return copy;
}

fn deterministicReset() bool {
    return true;
}

const FilterWorker = struct {
    engine: *Engine,
    rows: []const []Value,
    cols: []Column,
    where: *sql.Expr,
    alloc: std.mem.Allocator,
    /// Statement-level subquery state borrowed from the driving thread: the
    /// worker installs a non-owning alias into its own thread-local slot so
    /// `eval` sees the same sets (thread-local state is per thread).
    subq_sets: []SubqSet = &.{},
    subq_exists: []SubqExists = &.{},
    corr: []CorrPlan = &.{},
    out: std.ArrayList([]Value) = .empty,
    err: ?EngineError = null,

    fn run(self: *FilterWorker) void {
        // Copy the statement's subquery state into this thread's slot (entries
        // are shallow: they point at sets owned by the driving thread).
        const st = stmtState();
        st.sets.clearRetainingCapacity();
        st.exists.clearRetainingCapacity();
        st.corr.clearRetainingCapacity();
        st.sets.appendSlice(self.alloc, self.subq_sets) catch {
            self.err = error.OutOfMemory;
            return;
        };
        st.exists.appendSlice(self.alloc, self.subq_exists) catch {
            self.err = error.OutOfMemory;
            return;
        };
        st.corr.appendSlice(self.alloc, self.corr) catch {
            self.err = error.OutOfMemory;
            return;
        };
        defer {
            st.sets.clearRetainingCapacity();
            st.exists.clearRetainingCapacity();
            st.corr.clearRetainingCapacity();
        }
        for (self.rows) |row| {
            const v = self.engine.eval(self.alloc, self.where, row, self.cols, null) catch |e| {
                self.err = e;
                return;
            };
            if (truthy(v)) {
                self.out.append(self.alloc, row) catch |e| {
                    self.err = e;
                    return;
                };
            }
        }
    }
};

const AggWorker = struct {
    engine: *Engine,
    rows: []const []Value,
    cols: []Column,
    group_by: []*sql.Expr,
    specs: []const AggSpec,
    alloc: std.mem.Allocator,
    map: std.StringHashMap(u32) = undefined,
    states: std.ArrayList(GroupState) = .empty,
    err: ?EngineError = null,

    fn run(self: *AggWorker) void {
        self.map = std.StringHashMap(u32).init(self.alloc);
        var key = std.ArrayList(u8).empty;
        for (self.rows) |row| {
            key.clearRetainingCapacity();
            for (self.group_by) |g| {
                const v = self.engine.eval(self.alloc, g, row, self.cols, null) catch |e| {
                    self.err = e;
                    return;
                };
                appendKey(self.alloc, &key, v) catch |e| {
                    self.err = e;
                    return;
                };
            }
            const gop = self.map.getOrPut(key.items) catch |e| {
                self.err = e;
                return;
            };
            var idx: u32 = undefined;
            if (!gop.found_existing) {
                gop.key_ptr.* = self.alloc.dupe(u8, key.items) catch |e| {
                    self.err = e;
                    return;
                };
                idx = @intCast(self.states.items.len);
                gop.value_ptr.* = idx;
                const accs = self.alloc.alloc(Acc, self.specs.len) catch |e| {
                    self.err = e;
                    return;
                };
                for (accs) |*a| a.* = .{};
                self.states.append(self.alloc, .{ .first = row, .accs = accs }) catch |e| {
                    self.err = e;
                    return;
                };
            } else {
                idx = gop.value_ptr.*;
            }
            const st = &self.states.items[idx];
            for (self.specs, 0..) |spec, si| {
                if (spec.kind != .count_distinct and spec.arg_idx >= 0) {
                    const i: usize = @intCast(spec.arg_idx);
                    const v = if (i < row.len) row[i] else Value.null;
                    updateAccValue(&st.accs[si], spec, v);
                } else {
                    self.engine.updateAcc(self.alloc, &st.accs[si], spec, row, self.cols) catch |e| {
                        self.err = e;
                        return;
                    };
                }
            }
        }
    }
};

fn updateAccValue(acc: *Acc, spec: AggSpec, v: Value) void {
    switch (spec.kind) {
        .count_all => acc.n += 1,
        .count => {
            if (!v.isNull()) acc.n += 1;
        },
        .sum, .avg => switch (v) {
            .int => |x| {
                acc.isum += x;
                acc.n += 1;
            },
            .float => |x| {
                acc.has_float = true;
                acc.fsum += x;
                acc.n += 1;
            },
            else => {},
        },
        .min, .max => {
            if (v.isNull()) return;
            if (!acc.has_best) {
                acc.best = v;
                acc.has_best = true;
            } else {
                const ord = Value.order(v, acc.best);
                const better = if (spec.kind == .min) ord == .lt else ord == .gt;
                if (better) acc.best = v;
            }
        },
        .count_distinct => {},
    }
}

fn mergeAcc(alloc: std.mem.Allocator, dst: *Acc, src: Acc, spec: AggSpec) EngineError!void {
    if (spec.kind == .count_distinct) {
        if (src.set) |sset| {
            if (dst.set == null) {
                const set = try alloc.create(std.StringHashMap(void));
                set.* = std.StringHashMap(void).init(alloc);
                dst.set = set;
            }
            var it = sset.iterator();
            while (it.next()) |e| {
                const gop = try dst.set.?.getOrPut(e.key_ptr.*);
                if (!gop.found_existing) dst.n += 1;
            }
        }
        return;
    }
    dst.isum += src.isum;
    dst.fsum += src.fsum;
    dst.n += src.n;
    dst.has_float = dst.has_float or src.has_float;
    if (src.has_best) {
        if (!dst.has_best) {
            dst.best = src.best;
            dst.has_best = true;
        } else {
            const ord = Value.order(src.best, dst.best);
            const better = if (spec.kind == .min) ord == .lt else ord == .gt;
            if (better) dst.best = src.best;
        }
    }
}

fn canParallel(specs: []const AggSpec) bool {
    _ = specs;
    return true;
}

fn isAggName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "count") or
        std.ascii.eqlIgnoreCase(name, "sum") or
        std.ascii.eqlIgnoreCase(name, "avg") or
        std.ascii.eqlIgnoreCase(name, "min") or
        std.ascii.eqlIgnoreCase(name, "max");
}

fn collectAggCalls(
    alloc: std.mem.Allocator,
    e: *sql.Expr,
    specs: *std.ArrayList(AggSpec),
    exprs: *std.ArrayList(*sql.Expr),
) EngineError!void {
    switch (e.*) {
        .call => |c| {
            if (isAggName(c.name)) {
                for (exprs.items) |x| if (x == e) return;
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
                var arg: ?*sql.Expr = null;
                var arg_idx: i32 = -1;
                if (!c.star and c.args.len > 0) {
                    const a0 = c.args[0];
                    arg = a0;
                    switch (a0.*) {
                        .column_idx => |ci| arg_idx = @intCast(ci.idx),
                        else => {},
                    }
                }
                try exprs.append(alloc, e);
                try specs.append(alloc, .{ .expr = e, .kind = kind, .arg = arg, .arg_idx = arg_idx });
                return;
            }
            for (c.args) |a| try collectAggCalls(alloc, a, specs, exprs);
        },
        .binary => |b| {
            try collectAggCalls(alloc, b.lhs, specs, exprs);
            try collectAggCalls(alloc, b.rhs, specs, exprs);
        },
        .negate => |x| try collectAggCalls(alloc, x, specs, exprs),
        .not => |x| try collectAggCalls(alloc, x, specs, exprs),
        .is_null => |x| try collectAggCalls(alloc, x.operand, specs, exprs),
        .like => |x| {
            try collectAggCalls(alloc, x.operand, specs, exprs);
            try collectAggCalls(alloc, x.pattern, specs, exprs);
        },
        .in_list => |x| try collectAggCalls(alloc, x.operand, specs, exprs),
        .between => |x| {
            try collectAggCalls(alloc, x.operand, specs, exprs);
            try collectAggCalls(alloc, x.low, specs, exprs);
            try collectAggCalls(alloc, x.high, specs, exprs);
        },
        .cast => |x| try collectAggCalls(alloc, x.operand, specs, exprs),
        .case_expr => |c| {
            for (c.whens) |w| {
                try collectAggCalls(alloc, w.cond, specs, exprs);
                try collectAggCalls(alloc, w.then, specs, exprs);
            }
            if (c.else_expr) |el| try collectAggCalls(alloc, el, specs, exprs);
        },
        else => {},
    }
}

fn finalizeAcc(alloc: std.mem.Allocator, acc: *Acc, spec: AggSpec) EngineError!Value {
    switch (spec.kind) {
        .count_all, .count, .count_distinct => return .{ .int = acc.n },
        .sum => {
            if (acc.n == 0) return .null;
            if (acc.has_float) return .{ .float = acc.fsum };
            if (acc.isum > std.math.maxInt(i64) or acc.isum < std.math.minInt(i64)) {
                return .{ .float = @floatFromInt(acc.isum) };
            }
            return .{ .int = @intCast(acc.isum) };
        },
        .avg => {
            if (acc.n == 0) return .null;
            if (acc.has_float) return .{ .float = acc.fsum / @as(f64, @floatFromInt(acc.n)) };
            return .{ .float = @as(f64, @floatFromInt(acc.isum)) / @as(f64, @floatFromInt(acc.n)) };
        },
        .min, .max => return if (acc.has_best) acc.best else .null,
    }
    _ = alloc;
}

fn appendKey(alloc: std.mem.Allocator, key: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .null => try key.appendSlice(alloc, "N"),
        .int => |i| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, i, .little);
            try key.append(alloc, 'I');
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

pub fn bindExpr(e: *sql.Expr, cols: []Column) EngineError!void {
    switch (e.*) {
        .column => |name| {
            if (findColSlice(cols, name)) |idx| {
                e.* = .{ .column_idx = .{ .idx = @intCast(idx), .name = name } };
            } else {
                return error.UnknownColumn;
            }
        },
        .binary => |b| {
            try bindExpr(b.lhs, cols);
            try bindExpr(b.rhs, cols);
        },
        .negate => |x| try bindExpr(x, cols),
        .not => |x| try bindExpr(x, cols),
        .is_null => |x| try bindExpr(x.operand, cols),
        .like => |x| {
            try bindExpr(x.operand, cols);
            try bindExpr(x.pattern, cols);
        },
        .in_list => |x| {
            try bindExpr(x.operand, cols);
            for (x.items) |it| try bindExpr(it, cols);
        },
        .between => |x| {
            try bindExpr(x.operand, cols);
            try bindExpr(x.low, cols);
            try bindExpr(x.high, cols);
        },
        .cast => |x| try bindExpr(x.operand, cols),
        .call => |c| for (c.args) |a| try bindExpr(a, cols),
        .in_subquery => |x| try bindExpr(x.operand, cols),
        .exists => {},
        .case_expr => |c| {
            for (c.whens) |w| {
                try bindExpr(w.cond, cols);
                try bindExpr(w.then, cols);
            }
            if (c.else_expr) |el| try bindExpr(el, cols);
        },
        else => {},
    }
}

fn colName(e: *sql.Expr) ?[]const u8 {
    return switch (e.*) {
        .column => |n| n,
        .column_idx => |c| c.name,
        else => null,
    };
}

/// Partition hash for join keys (radix join). Stable per value type.
fn keyHash(v: Value) u64 {
    return switch (v) {
        .int => |i| std.hash.Wyhash.hash(0, std.mem.asBytes(&i)),
        .float => |f| std.hash.Wyhash.hash(1, std.mem.asBytes(&f)),
        .text => |t| std.hash.Wyhash.hash(2, t),
        .boolean => |b| if (b) 3 else 4,
        .null => 5,
    };
}

/// Scalar value of a bound expression on a stored row.
fn rowScalar(e: *sql.Expr, row: []const Value) Value {
    return switch (e.*) {
        .column_idx => |c| if (c.idx < row.len) row[c.idx] else .null,
        .column => |n| blk: {
            // Bound expressions only use column_idx; a leftover name is unknown.
            _ = n;
            break :blk .null;
        },
        .int => |v| .{ .int = v },
        .float => |v| .{ .float = v },
        .string => |s2| .{ .text = s2 },
        .null_lit => .null,
        .negate => |x| switch (rowScalar(x, row)) {
            .int => |v| .{ .int = -v },
            .float => |v| .{ .float = -v },
            else => .null,
        },
        else => .null,
    };
}

fn rowOrder(a: Value, b: Value) ?std.math.Order {
    switch (a) {
        .text => |x| {
            const y = switch (b) {
                .text => |t| t,
                else => return null,
            };
            return std.mem.order(u8, x, y);
        },
        else => {},
    }
    const fa: f64 = switch (a) {
        .int => |v| @floatFromInt(v),
        .float => |v| v,
        .boolean => |v| @floatFromInt(@intFromBool(v)),
        else => return null,
    };
    const fb: f64 = switch (b) {
        .int => |v| @floatFromInt(v),
        .float => |v| v,
        .boolean => |v| @floatFromInt(@intFromBool(v)),
        else => return null,
    };
    if (fa < fb) return .lt;
    if (fa > fb) return .gt;
    return .eq;
}

fn rowCmp(a: Value, b: Value, op: sql.BinOp) bool {
    if (a == .null or b == .null) return false;
    if (op == .eq) return Value.eql(a, b);
    if (op == .neq) return !Value.eql(a, b);
    const ord = rowOrder(a, b) orelse return false;
    return switch (op) {
        .lt => ord == .lt,
        .le => ord != .gt,
        .gt => ord == .gt,
        .ge => ord != .lt,
        else => false,
    };
}

/// Evaluation context for predicate sampling: a stored row, or a row index in
/// the columnar image (so snapshot-backed tables need no materialisation).
const EvalCtx = union(enum) {
    row: []const Value,
    col: *columnar.Table,
};

fn ctxScalar(c: EvalCtx, e: *sql.Expr, idx: usize) Value {
    return switch (e.*) {
        .column_idx => |cc| switch (c) {
            .row => |row| if (cc.idx < row.len) row[cc.idx] else .null,
            .col => |ct| blk: {
                if (cc.idx >= ct.cols.len) break :blk .null;
                if (ct.isNull(cc.idx, idx)) break :blk .null;
                break :blk switch (ct.data[cc.idx]) {
                    .ints, .ints8, .ints16, .ints32 => .{ .int = ct.data[cc.idx].intAt(idx) },
                    .floats => |v| .{ .float = v[idx] },
                    .strs => |sd| .{ .text = sd.at(idx) },
                };
            },
        },
        .column => .null, // stored predicates are bound to column_idx
        .int => |v| .{ .int = v },
        .float => |v| .{ .float = v },
        .string => |s2| .{ .text = s2 },
        .null_lit => .null,
        .negate => |x| switch (ctxScalar(c, x, idx)) {
            .int => |v| .{ .int = -v },
            .float => |v| .{ .float = -v },
            else => .null,
        },
        // Arithmetic on column expressions: predicate sampling must evaluate
        // `t.lo + 100` etc. exactly like the executor does, otherwise sampled
        // selectivity (and every estimate derived from it) is silently wrong.
        .binary => |b| blk: {
            switch (b.op) {
                .add, .sub, .mul, .div, .mod => {},
                else => break :blk .null,
            }
            const l = ctxScalar(c, b.lhs, idx);
            const r = ctxScalar(c, b.rhs, idx);
            if (l == .null or r == .null) break :blk .null;
            if (l == .int and r == .int) {
                const a = l.int;
                const d = r.int;
                break :blk switch (b.op) {
                    .add => .{ .int = a +% d },
                    .sub => .{ .int = a -% d },
                    .mul => .{ .int = a *% d },
                    .div => if (d == 0) .null else .{ .int = @divTrunc(a, d) },
                    .mod => if (d == 0) .null else .{ .int = @rem(a, d) },
                    else => .null,
                };
            }
            const a = l.asFloat();
            const d = r.asFloat();
            break :blk switch (b.op) {
                .add => .{ .float = a + d },
                .sub => .{ .float = a - d },
                .mul => .{ .float = a * d },
                .div => if (d == 0) .null else .{ .float = a / d },
                .mod => if (d == 0) .null else .{ .float = @mod(a, d) },
                else => .null,
            };
        },
        .cast => |x| switch (ctxScalar(c, x.operand, idx)) {
            .int => |v| if (mapType(x.type_name) == .float) .{ .float = @floatFromInt(v) } else .{ .int = v },
            .float => |v| if (mapType(x.type_name) == .float) .{ .float = v } else .{ .int = @intFromFloat(v) },
            else => |v| v,
        },
        .call => |cl| ctxCall(c, cl.name, cl.args, idx),
        else => .null,
    };
}

/// Rotating scratch buffers for sampled string functions (valid until the next
/// few calls, which covers `lower(a) = lower(b)`-style comparisons).
threadlocal var ctx_str_ring: [4]std.ArrayList(u8) = .{ .empty, .empty, .empty, .empty };
threadlocal var ctx_str_pos: usize = 0;

fn ctxText(v: Value, buf: *[64]u8) ?[]const u8 {
    return switch (v) {
        .text => |x| x,
        .int => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch null,
        .float => |x| std.fmt.bufPrint(buf, "{d}", .{x}) catch null,
        .boolean => |x| if (x) "true" else "false",
        .null => null,
    };
}

/// Planning-time evaluation of the scalar functions that commonly appear in
/// sampled predicates. Mirrors `scalarFunc` semantics (length = byte length of
/// the formatted value, ASCII lower/upper) without allocating per row.
/// Copy `t` into the rotating scratch ring and return it (valid across the
/// next few sampled calls, enough for comparison expressions).
fn ctxScratchText(t: []const u8) Value {
    ctx_str_pos = (ctx_str_pos + 1) % ctx_str_ring.len;
    const buf = &ctx_str_ring[ctx_str_pos];
    buf.clearRetainingCapacity();
    buf.appendSlice(std.heap.page_allocator, t) catch return .null;
    return .{ .text = buf.items };
}

fn ctxCall(c: EvalCtx, name: []const u8, args: []const *sql.Expr, idx: usize) Value {
    if (std.c.getenv("ZHDB_NO_CTX_FUNCS") != null) return .null;
    var vals: [8]Value = @splat(.null);
    const n = @min(args.len, vals.len);
    for (args[0..n], 0..) |call_arg, i| vals[i] = ctxScalar(c, call_arg, idx);
    if (std.ascii.eqlIgnoreCase(name, "booleq") or std.ascii.eqlIgnoreCase(name, "boolne")) {
        if (n < 2 or vals[0].isNull() or vals[1].isNull()) return .null;
        const eq = Value.eql(vals[0], vals[1]);
        return .{ .boolean = if (std.ascii.eqlIgnoreCase(name, "booleq")) eq else !eq };
    }
    if (std.ascii.eqlIgnoreCase(name, "coalesce")) {
        for (vals[0..n]) |v| if (v != .null) return v;
        return .null;
    }
    if (n == 0) return .null;
    const a = vals[0];
    if (std.ascii.eqlIgnoreCase(name, "length") or std.ascii.eqlIgnoreCase(name, "char_length") or std.ascii.eqlIgnoreCase(name, "character_length")) {
        var b: [64]u8 = undefined;
        const t = ctxText(a, &b) orelse return .null;
        return .{ .int = @intCast(t.len) };
    }
    if (std.ascii.eqlIgnoreCase(name, "abs")) {
        return switch (a) {
            .int => |v| .{ .int = if (v == std.math.minInt(i64)) v else @intCast(@abs(v)) },
            .float => |v| .{ .float = @abs(v) },
            else => .null,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "round")) {
        return switch (a) {
            .float => |v| .{ .float = @round(v) },
            .int => |v| .{ .int = v },
            else => .null,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "floor")) {
        return switch (a) {
            .float => |v| .{ .float = @floor(v) },
            .int => |v| .{ .int = v },
            else => .null,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "ceil") or std.ascii.eqlIgnoreCase(name, "ceiling")) {
        return switch (a) {
            .float => |v| .{ .float = @ceil(v) },
            .int => |v| .{ .int = v },
            else => .null,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "tostring")) {
        var b: [64]u8 = undefined;
        const t = ctxText(a, &b) orelse return .null;
        return ctxScratchText(t);
    }
    if (std.ascii.eqlIgnoreCase(name, "concat")) {
        ctx_str_pos = (ctx_str_pos + 1) % ctx_str_ring.len;
        const buf = &ctx_str_ring[ctx_str_pos];
        buf.clearRetainingCapacity();
        for (vals[0..n]) |v| {
            if (v == .null) continue;
            var b: [64]u8 = undefined;
            const t = ctxText(v, &b) orelse return .null;
            buf.appendSlice(std.heap.page_allocator, t) catch return .null;
        }
        return .{ .text = buf.items };
    }
    if (std.ascii.eqlIgnoreCase(name, "substr") or std.ascii.eqlIgnoreCase(name, "substring")) {
        if (n < 2) return .null;
        var b: [64]u8 = undefined;
        const t = ctxText(a, &b) orelse return .null;
        const start_i: i64 = switch (vals[1]) {
            .int => |x| x,
            .float => |f| @as(i64, @intFromFloat(f)),
            else => return .null,
        };
        if (start_i == 0) return .{ .text = "" };
        var begin: usize = undefined;
        if (start_i > 0) {
            begin = @min(@as(usize, @intCast(start_i - 1)), t.len);
        } else {
            const from_end = @as(usize, @intCast(-start_i));
            begin = if (from_end >= t.len) 0 else t.len - from_end;
        }
        var end: usize = t.len;
        if (n >= 3) {
            const len_i: i64 = switch (vals[2]) {
                .int => |x| x,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => return .null,
            };
            if (len_i <= 0) return .{ .text = "" };
            end = @min(begin + @as(usize, @intCast(len_i)), t.len);
        }
        return ctxScratchText(t[begin..end]);
    }
    const cdate_parts = [_]struct { fn_name: []const u8, idx: usize }{
        .{ .fn_name = "toyear", .idx = 0 },
        .{ .fn_name = "tomonth", .idx = 1 },
        .{ .fn_name = "todayofmonth", .idx = 2 },
        .{ .fn_name = "tohour", .idx = 3 },
        .{ .fn_name = "tominute", .idx = 4 },
        .{ .fn_name = "tosecond", .idx = 5 },
    };
    for (cdate_parts) |dp| {
        if (std.ascii.eqlIgnoreCase(name, dp.fn_name)) {
            var b: [64]u8 = undefined;
            const t = ctxText(a, &b) orelse return .null;
            const parts = dateParts(t);
            return .{ .int = @intCast(parts[dp.idx]) };
        }
    }
    if (std.ascii.eqlIgnoreCase(name, "lower") or std.ascii.eqlIgnoreCase(name, "upper")) {
        var b: [64]u8 = undefined;
        const t = std.mem.trimEnd(u8, ctxText(a, &b) orelse return .null, " ");
        ctx_str_pos = (ctx_str_pos + 1) % ctx_str_ring.len;
        const buf = &ctx_str_ring[ctx_str_pos];
        buf.clearRetainingCapacity();
        buf.appendSlice(std.heap.page_allocator, t) catch return .null;
        if (std.ascii.eqlIgnoreCase(name, "lower")) {
            for (buf.items) |*ch| ch.* = std.ascii.toLower(ch.*);
        } else {
            for (buf.items) |*ch| ch.* = std.ascii.toUpper(ch.*);
        }
        return .{ .text = buf.items };
    }
    return .null;
}

fn evalPredCtx(c: EvalCtx, e: *sql.Expr, idx: usize) bool {
    switch (e.*) {
        .binary => |b| {
            switch (b.op) {
                .and_op => return evalPredCtx(c, b.lhs, idx) and evalPredCtx(c, b.rhs, idx),
                .or_op => return evalPredCtx(c, b.lhs, idx) or evalPredCtx(c, b.rhs, idx),
                else => {},
            }
            if (b.op == .regex or b.op == .regex_ne) {
                const m = regexMatchValues(ctxScalar(c, b.lhs, idx), ctxScalar(c, b.rhs, idx));
                return if (b.op == .regex_ne) !m else m;
            }
            return rowCmp(ctxScalar(c, b.lhs, idx), ctxScalar(c, b.rhs, idx), b.op);
        },
        .not => |x| {
            // NOT UNKNOWN is not TRUE.
            if (ctxScalar(c, x, idx) == .null) return false;
            return !evalPredCtx(c, x, idx);
        },
        .in_list => |x| {
            const v = ctxScalar(c, x.operand, idx);
            if (v == .null) return false;
            var found = false;
            var has_null = false;
            for (x.items) |it| {
                const cand = ctxScalar(c, it, idx);
                if (cand == .null) {
                    has_null = true;
                    continue;
                }
                if (Value.eql(v, cand)) {
                    found = true;
                    break;
                }
            }
            if (x.negated and has_null) return false;
            return if (x.negated) !found else found;
        },
        .between => |x| {
            const v = ctxScalar(c, x.operand, idx);
            const ok = rowCmp(v, ctxScalar(c, x.low, idx), .ge) and rowCmp(v, ctxScalar(c, x.high, idx), .le);
            return if (x.negated) !ok else ok;
        },
        .is_null => |x| {
            const isn = ctxScalar(c, x.operand, idx) == .null;
            return if (x.negated) !isn else isn;
        },
        .in_subquery => |x| {
            const list = or_subq orelse return false;
            for (list) |m| {
                if (m.expr != e) continue;
                eval_key_buf.clearRetainingCapacity();
                const ka = std.heap.page_allocator;
                if (m.range_map) |rm| {
                    if (m.keys.len > 0) {
                        for (m.keys, 0..) |k, ki| {
                            const comp = ctxScalar(c, k, idx);
                            if (comp == .null) return false;
                            if (ki > 0) eval_key_buf.append(ka, 0x1f) catch return false;
                            const ok = appendKeyPart(&eval_key_buf, comp, ka) catch return false;
                            if (!ok) return false;
                        }
                    } else {
                        const v = ctxScalar(c, x.operand, idx);
                        if (v == .null) return false;
                        const ok = appendKeyPart(&eval_key_buf, v, ka) catch return false;
                        if (!ok) return false;
                    }
                    const bound = rm.get(eval_key_buf.items) orelse {
                        if (x.negated and m.has_null) return false;
                        return x.negated;
                    };
                    if (bound.is_str) {
                        var has_lo = false;
                        var lo_s: []const u8 = &.{};
                        var lo_strict = false;
                        var has_hi = false;
                        var hi_s: []const u8 = &.{};
                        var hi_strict = false;
                        var ri: usize = 0;
                        while (ri < m.range_n) : (ri += 1) {
                            const rk = m.range_keys[ri] orelse return false;
                            const ko = ctxScalar(c, rk, idx);
                            if (ko == .null) return false;
                            if (ko != .text) return false;
                            const sv = ko.text;
                            switch (m.range_ops[ri]) {
                                .ge, .gt => {
                                    const strict = m.range_ops[ri] == .gt;
                                    if (!has_lo) {
                                        has_lo = true;
                                        lo_s = sv;
                                        lo_strict = strict;
                                    } else switch (std.mem.order(u8, sv, lo_s)) {
                                        .gt => {
                                            lo_s = sv;
                                            lo_strict = strict;
                                        },
                                        .eq => lo_strict = lo_strict or strict,
                                        .lt => {},
                                    }
                                },
                                .le, .lt => {
                                    const strict = m.range_ops[ri] == .lt;
                                    if (!has_hi) {
                                        has_hi = true;
                                        hi_s = sv;
                                        hi_strict = strict;
                                    } else switch (std.mem.order(u8, sv, hi_s)) {
                                        .lt => {
                                            hi_s = sv;
                                            hi_strict = strict;
                                        },
                                        .eq => hi_strict = hi_strict or strict,
                                        .gt => {},
                                    }
                                },
                                else => return false,
                            }
                        }
                        const sh_hit = bound.hitsStrRange(has_lo, lo_s, lo_strict, has_hi, hi_s, hi_strict);
                        if (x.negated and m.has_null) return false;
                        return if (x.negated) !sh_hit else sh_hit;
                    }
                    var lower: f64 = -std.math.inf(f64);
                    var lower_strict = false;
                    var upper: f64 = std.math.inf(f64);
                    var upper_strict = false;
                    var ri: usize = 0;
                    while (ri < m.range_n) : (ri += 1) {
                        const rk = m.range_keys[ri] orelse return false;
                        const ko = ctxScalar(c, rk, idx);
                        if (ko == .null) return false;
                        const kv: f64 = switch (ko) {
                            .int => |i| @floatFromInt(i),
                            .float => |f| f,
                            .boolean => |b| @floatFromInt(@intFromBool(b)),
                            else => return false,
                        };
                        switch (m.range_ops[ri]) {
                            .ge, .gt => {
                                const strict = m.range_ops[ri] == .gt;
                                if (kv > lower) {
                                    lower = kv;
                                    lower_strict = strict;
                                } else if (kv == lower) {
                                    lower_strict = lower_strict or strict;
                                }
                            },
                            .le, .lt => {
                                const strict = m.range_ops[ri] == .lt;
                                if (kv < upper) {
                                    upper = kv;
                                    upper_strict = strict;
                                } else if (kv == upper) {
                                    upper_strict = upper_strict or strict;
                                }
                            },
                            else => return false,
                        }
                    }
                    const hit = bound.hits(lower, lower_strict, upper, upper_strict);
                    if (x.negated and m.has_null) return false;
                    return if (x.negated) !hit else hit;
                }
                if (m.keys.len > 0) {
                    // Correlated membership: `<operand>\x1f<outer keys...>`.
                    for (m.keys, 0..) |k, ki| {
                        const comp = ctxScalar(c, k, idx);
                        if (comp == .null) return false;
                        if (ki > 0) eval_key_buf.append(ka, 0x1f) catch return false;
                        const ok = appendKeyPart(&eval_key_buf, comp, ka) catch return false;
                        if (!ok) return false;
                    }
                } else {
                    const v = ctxScalar(c, x.operand, idx);
                    if (v == .null) return false;
                    const ok = appendKeyPart(&eval_key_buf, v, ka) catch return false;
                    if (!ok) return false;
                }
                const in_set = m.set.contains(eval_key_buf.items);
                if (x.negated and m.has_null) return false;
                return if (x.negated) !in_set else in_set;
            }
            return false;
        },
        .exists => return false,
        .like => |l| {
            const v = ctxScalar(c, l.operand, idx);
            const pat = ctxScalar(c, l.pattern, idx);
            if (v != .text or pat != .text) return false;
            const m = likeMatch(v.text, pat.text);
            return if (l.negated) !m else m;
        },
        else => {
            const v = ctxScalar(c, e, idx);
            return switch (v) {
                .int => |i| i != 0,
                .float => |f| f != 0,
                .boolean => |b| b,
                else => false,
            };
        },
    }
}

fn evalPredRow(e: *sql.Expr, row: []const Value) bool {
    return evalPredCtx(.{ .row = row }, e, 0);
}

fn keyCol(t: *Table, e: *sql.Expr) ?usize {
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

fn typeName(ty: ColType) []const u8 {
    return switch (ty) {
        .int => "int",
        .boolean => "boolean",
        .float => "double",
        .text, .date, .timestamp => "text",
    };
}

/// Row-store validity: `nulls[ci]` is a bitmap (1 = present), mirroring the
/// columnar `Table.valid`. `null` means the column has no NULLs.
fn tableIsNull(t: *const Table, ci: usize, ri: usize) bool {
    if (t.nulls.len <= ci) return false;
    const bits = t.nulls[ci] orelse return false;
    if (ri / 8 >= bits.len) return false; // beyond the bitmap = present
    return (bits[ri / 8] >> @intCast(ri % 8)) & 1 == 0;
}

fn tableSetNull(a: std.mem.Allocator, t: *Table, ci: usize, ri: usize, is_null: bool) !void {
    if (t.nulls.len <= ci) return;
    if (t.nulls[ci] == null) {
        if (!is_null) return;
        const bits = try a.alloc(u8, @max((t.rows.items.len + 7) / 8, ri / 8 + 1));
        @memset(bits, 0xff);
        t.nulls[ci] = bits;
    } else if (is_null and ri / 8 >= t.nulls[ci].?.len) {
        // The bitmap was allocated for an earlier, shorter prefix of rows.
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

/// Stored cells never hold `Value.null`: NULL is carried by the validity
/// bitmap, and the cell keeps a type-appropriate placeholder.
fn storedSentinel(ty: ColType) Value {
    return switch (ty) {
        .float => .{ .float = 0 },
        .text, .date, .timestamp => .{ .text = "" },
        else => .{ .int = 0 },
    };
}

fn rowIsNull(t: *const Table, ri: usize, ci: usize) bool {
    return tableIsNull(t, ci, ri);
}

/// Materialise a stored row for the row engine: placeholders become `.null`
/// wherever the bitmap says NULL.
fn materializeRow(alloc: std.mem.Allocator, t: *const Table, ri: usize) ![]Value {
    const row = try alloc.alloc(Value, t.cols.len);
    @memcpy(row, t.rows.items[ri]);
    var ci: usize = 0;
    while (ci < t.cols.len) : (ci += 1) {
        if (tableIsNull(t, ci, ri)) row[ci] = .null;
    }
    return row;
}

/// Append a row to a table store, converting `.null` into placeholders plus
/// bitmap bits (the single representation invariant).
fn ctIdOf(t: *const Table, ri: usize) u32 {
    if (ri < t.ctid.items.len) return t.ctid.items[ri];
    return @intCast(ri);
}

fn ensureVersionArrays(gpa: std.mem.Allocator, t: *Table) !void {
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
}

fn appendStoredRow(gpa: std.mem.Allocator, t: *Table, vals: []const Value) !usize {
    const row = try gpa.alloc(Value, t.cols.len);
    errdefer gpa.free(row);
    var ci: usize = 0;
    while (ci < t.cols.len) : (ci += 1) {
        const v: Value = if (ci < vals.len) vals[ci] else defaultValue(t.cols[ci].ty);
        row[ci] = if (v == .null) storedSentinel(t.cols[ci].ty) else v;
    }
    const ri = t.rows.items.len;
    // Rows materialised from a snapshot (and reclaimed slots) may leave the
    // version arrays shorter than the row array; keep them aligned.
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
    ci = 0;
    while (ci < t.cols.len) : (ci += 1) {
        if (ci < vals.len and vals[ci] == .null) {
            if (std.c.getenv("ZHDB_DBG_NULL") != null) {
                std.debug.print("[null] {s} col={d} ri={d}\n", .{ t.name, ci, ri });
            }
            try tableSetNull(gpa, t, ci, ri, true);
        }
    }
    return ri;
}

/// MVCC visibility: a row is visible when it was created at or before the
/// snapshot and not deleted before it.
/// Aggregations and GROUP BY are where the row engine is slow enough that a
/// private columnar view pays for itself.
fn selWantsView(sel: *sql.Select) bool {
    if (sel.group_by.len > 0 or sel.having != null or sel.distinct) return true;
    for (sel.items) |it| {
        switch (it.expr.*) {
            .call => |c| {
                const n = c.name;
                if (std.ascii.eqlIgnoreCase(n, "count") or std.ascii.eqlIgnoreCase(n, "sum") or
                    std.ascii.eqlIgnoreCase(n, "min") or std.ascii.eqlIgnoreCase(n, "max") or
                    std.ascii.eqlIgnoreCase(n, "avg")) return true;
            },
            else => {},
        }
    }
    return false;
}

/// One cell of the row store shaped as a `columnar.Value` (NULL from the bitmap).
fn cellValueFromRow(t: *Table, ci: usize, ri: usize) Value {
    if (tableIsNull(t, ci, ri)) return .null;
    if (ri < t.rows.items.len) {
        const v = t.rows.items[ri][ci];
        if (v == .null) return .null;
        return v;
    }
    return .null;
}

fn rowVisible(t: *const Table, ri: usize, snap: u64) bool {
    const lo: u64 = if (ri < t.xmin.items.len) t.xmin.items[ri] else 0;
    if (lo > snap) return false;
    const hi: u64 = if (ri < t.xmax.items.len) t.xmax.items[ri] else 0;
    if (hi != 0 and hi <= snap) return false;
    return true;
}

fn isRowDeleted(t: *const Table, ri: usize) bool {
    return ri < t.deleted.items.len and t.deleted.items[ri] != 0;
}

fn findCol(t: *Table, name: []const u8) ?usize {
    return findColSlice(t.cols, name);
}

/// Does the reference `ref` (possibly `table.col`) name the column `col`?


/// Table/alias names visible inside a subquery (used to tell inner from outer).
fn scopeNames(alloc: std.mem.Allocator, sub: *sql.Select) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    const add = struct {
        fn f(l: *std.ArrayList([]const u8), al: std.mem.Allocator, name: []const u8) !void {
            var base = name;
            if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base = base[dot + 1 ..];
            try l.append(al, base);
        }
    }.f;
    switch (sub.from orelse return try list.toOwnedSlice(alloc)) {
        .table => |t| try add(&list, alloc, t),
        .subquery => {},
        .function => |f| try add(&list, alloc, f.name),
        .values => {},
    }
    if (sub.alias) |a| try add(&list, alloc, a);
    if (sub.join) |j| try add(&list, alloc, j.table);
    return try list.toOwnedSlice(alloc);
}

/// Does `e` reference a column qualified with a name outside `allowed`?
fn refsOuter(e: *sql.Expr, allowed: []const []const u8) bool {
    return switch (e.*) {
        .column => |n| !qualifierAllowed(n, allowed),
        .column_idx => false,
        .binary => |b| refsOuter(b.lhs, allowed) or refsOuter(b.rhs, allowed),
        .negate => |x| refsOuter(x, allowed),
        .not => |x| refsOuter(x, allowed),
        .is_null => |x| refsOuter(x.operand, allowed),
        .like => |x| refsOuter(x.operand, allowed) or refsOuter(x.pattern, allowed),
        .in_list => |x| blk: {
            if (refsOuter(x.operand, allowed)) break :blk true;
            for (x.items) |it| if (refsOuter(it, allowed)) break :blk true;
            break :blk false;
        },
        .between => |x| refsOuter(x.operand, allowed) or refsOuter(x.low, allowed) or refsOuter(x.high, allowed),
        .cast => |x| refsOuter(x.operand, allowed),
        .call => |c| blk: {
            for (c.args) |a| if (refsOuter(a, allowed)) break :blk true;
            break :blk false;
        },
        .case_expr => |c| blk: {
            for (c.whens) |w| {
                if (refsOuter(w.cond, allowed) or refsOuter(w.then, allowed)) break :blk true;
            }
            if (c.else_expr) |el| if (refsOuter(el, allowed)) break :blk true;
            break :blk false;
        },
        .in_subquery => |x| refsOuter(x.operand, allowed),
        else => false,
    };
}

/// Split a subquery WHERE into correlation equalities (outer = inner) and
/// predicates that only mention the subquery's own columns.
/// Split a correlated subquery WHERE into one range correlation
/// (`inner OP outer`) plus local predicates. Only a single range correlation is
/// supported; equality correlations must go through `splitCorrelated`.
fn splitRangeCorrelated(
    alloc: std.mem.Allocator,
    e: *sql.Expr,
    allowed: []const []const u8,
    inner_expr: *?*sql.Expr,
    outer_expr: *?*sql.Expr,
    op_out: *?sql.BinOp,
    preds: *std.ArrayList(*sql.Expr),
) EngineError!bool {
    switch (e.*) {
        .binary => |b| {
            if (b.op == .and_op) {
                if (!try splitRangeCorrelated(alloc, b.lhs, allowed, inner_expr, outer_expr, op_out, preds)) return false;
                return try splitRangeCorrelated(alloc, b.rhs, allowed, inner_expr, outer_expr, op_out, preds);
            }
            if (b.op == .lt or b.op == .le or b.op == .gt or b.op == .ge) {
                const lo = refsOuter(b.lhs, allowed);
                const ro = refsOuter(b.rhs, allowed);
                if (lo and !ro) {
                    // `outer OP inner` -> `inner FLIP(OP) outer`.
                    if (outer_expr.* != null) return false;
                    outer_expr.* = b.lhs;
                    inner_expr.* = b.rhs;
                    op_out.* = switch (b.op) {
                        .lt => .gt,
                        .le => .ge,
                        .gt => .lt,
                        .ge => .le,
                        else => b.op,
                    };
                    return true;
                }
                if (ro and !lo) {
                    // `inner OP outer` already.
                    if (outer_expr.* != null) return false;
                    outer_expr.* = b.rhs;
                    inner_expr.* = b.lhs;
                    op_out.* = b.op;
                    return true;
                }
                if (!lo and !ro) {
                    try preds.append(alloc, e);
                    return true;
                }
                return false;
            }
            if (refsOuter(e, allowed)) return false;
            try preds.append(alloc, e);
            return true;
        },
        else => {
            if (refsOuter(e, allowed)) return false;
            try preds.append(alloc, e);
            return true;
        },
    }
}

/// One range correlation predicate `inner OP outer` (normalised).
const RangeCorr = struct { inner: *sql.Expr, outer: *sql.Expr, op: sql.BinOp };

/// Per-value inner keys for range/interval correlations: sorted key list (up to
/// a cap) for exact interval tests, plus min/max for the long-list fallback.
pub const RangeBound = struct {
    /// Numeric keys (integers / floats / booleans).
    lo: f64 = 0,
    hi: f64 = 0,
    keys: []const f64 = &.{},
    /// Text keys (lexicographic comparison; exact for any prefix length).
    is_str: bool = false,
    slo: []const u8 = &.{},
    shi: []const u8 = &.{},
    skeys: []const []const u8 = &.{},

    /// True when any numeric inner key lies in the (possibly open) interval
    /// [lower, upper]. `keys` is a sorted, deduplicated slice (any length); when
    /// absent (memory budget exhausted) the [min,max] bounds are used instead.
    pub fn hits(self: RangeBound, lower: f64, lower_strict: bool, upper: f64, upper_strict: bool) bool {
        if (self.keys.len > 0) {
            // First key >= lower (or > lower when strict).
            var lo: usize = 0;
            var hi: usize = self.keys.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const k = self.keys[mid];
                const before = if (lower_strict) k <= lower else k < lower;
                if (before) lo = mid + 1 else hi = mid;
            }
            if (lo >= self.keys.len) return false;
            const k = self.keys[lo];
            return if (upper_strict) k < upper else k <= upper;
        }
        // Fallback: [min,max] overlap (conservative for gapped key sets).
        const lower_ok = if (lower_strict) self.hi > lower else self.hi >= lower;
        const upper_ok = if (upper_strict) self.lo < upper else self.lo <= upper;
        return lower_ok and upper_ok;
    }

    /// True when any text inner key lies in the (possibly open) interval
    /// [lower, upper] in lexicographic order. Uses the full strings, so long
    /// keys sharing a prefix are still distinguished exactly.
    pub fn hitsStr(self: RangeBound, lower: []const u8, lower_strict: bool, upper: []const u8, upper_strict: bool) bool {
        if (self.skeys.len > 0) {
            var lo: usize = 0;
            var hi: usize = self.skeys.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const ord = std.mem.order(u8, self.skeys[mid], lower);
                const before = if (lower_strict) ord != .gt else ord == .lt;
                if (before) lo = mid + 1 else hi = mid;
            }
            if (lo >= self.skeys.len) return false;
            const ord2 = std.mem.order(u8, self.skeys[lo], upper);
            return if (upper_strict) ord2 == .lt else ord2 != .gt;
        }
        const lower_ok = if (lower_strict)
            std.mem.order(u8, self.shi, lower) == .gt
        else
            std.mem.order(u8, self.shi, lower) != .lt;
        const upper_ok = if (upper_strict)
            std.mem.order(u8, self.slo, upper) == .lt
        else
            std.mem.order(u8, self.slo, upper) != .gt;
        return lower_ok and upper_ok;
    }

    /// Same as `hitsStr`, but either side may be absent (one-sided range).
    pub fn hitsStrRange(
        self: RangeBound,
        has_lo: bool,
        lower: []const u8,
        lower_strict: bool,
        has_hi: bool,
        upper: []const u8,
        upper_strict: bool,
    ) bool {
        if (self.skeys.len > 0) {
            var lo: usize = 0;
            if (has_lo) {
                var hi: usize = self.skeys.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const ord = std.mem.order(u8, self.skeys[mid], lower);
                    const before = if (lower_strict) ord != .gt else ord == .lt;
                    if (before) lo = mid + 1 else hi = mid;
                }
            }
            if (lo >= self.skeys.len) return false;
            if (!has_hi) return true;
            const ord2 = std.mem.order(u8, self.skeys[lo], upper);
            return if (upper_strict) ord2 == .lt else ord2 != .gt;
        }
        var ok = true;
        if (has_lo) {
            ok = ok and if (lower_strict)
                std.mem.order(u8, self.shi, lower) == .gt
            else
                std.mem.order(u8, self.shi, lower) != .lt;
        }
        if (has_hi) {
            ok = ok and if (upper_strict)
                std.mem.order(u8, self.slo, upper) == .lt
            else
                std.mem.order(u8, self.slo, upper) != .gt;
        }
        return ok;
    }
};

/// Collects per-value inner keys (numeric and text) while a range map is built.
/// The temporary keys/lists live in the caller's arena; the final map owns
/// copies in its key arena.
pub const RangeAcc = struct {
    nums: std.StringHashMap(std.ArrayList(f64)),
    strs: std.StringHashMap(std.ArrayList([]const u8)),

    pub fn init(a: std.mem.Allocator) RangeAcc {
        return .{
            .nums = std.StringHashMap(std.ArrayList(f64)).init(a),
            .strs = std.StringHashMap(std.ArrayList([]const u8)).init(a),
        };
    }

    pub fn deinit(self: *RangeAcc, a: std.mem.Allocator) void {
        var it = self.nums.valueIterator();
        while (it.next()) |v| v.deinit(a);
        self.nums.deinit();
        var it2 = self.strs.valueIterator();
        while (it2.next()) |v| v.deinit(a);
        self.strs.deinit();
    }

    pub fn addNum(self: *RangeAcc, a: std.mem.Allocator, key: []const u8, v: f64) void {
        if (self.nums.getPtr(key)) |l| {
            l.append(a, v) catch {};
            return;
        }
        const kd = a.dupe(u8, key) catch return;
        var l = std.ArrayList(f64).empty;
        l.append(a, v) catch {};
        self.nums.put(kd, l) catch {};
    }

    pub fn addStr(self: *RangeAcc, a: std.mem.Allocator, key: []const u8, v: []const u8) void {
        if (self.strs.getPtr(key)) |l| {
            const vd = a.dupe(u8, v) catch return;
            l.append(a, vd) catch {};
            return;
        }
        const kd = a.dupe(u8, key) catch return;
        const vd = a.dupe(u8, v) catch return;
        var l = std.ArrayList([]const u8).empty;
        l.append(a, vd) catch {};
        self.strs.put(kd, l) catch {};
    }
};

/// At most two range conditions (an interval uses both bounds).
const RANGE_MAX: usize = 2;

/// Memory guard for exact per-value inner key lists: total f64 keys stored per
/// range map (8M keys = 64 MiB). Values beyond the budget fall back to the
/// [min,max] test; there is no *per-value* limit, so any realistically dense
/// key set is tested exactly.
const RANGE_KEY_BUDGET: usize = 8_000_000;
/// Byte budget for exact per-value *text* inner keys (64 MiB per range map).
const RANGE_STR_BUDGET: usize = 64 << 20;

/// Byte budget for the exact residual string CDF (distinct keys) per column.
const RES_CDF_BUDGET: usize = 8 << 20;

fn splitCorrelated(
    alloc: std.mem.Allocator,
    e: *sql.Expr,
    allowed: []const []const u8,
    outer_keys: *std.ArrayList(*sql.Expr),
    inner_items: *std.ArrayList(*sql.Expr),
    preds: *std.ArrayList(*sql.Expr),
    range_out: *[2]?RangeCorr,
    range_n: *u8,
) EngineError!bool {
    switch (e.*) {
        .binary => |b| {
            if (b.op == .and_op) {
                if (!try splitCorrelated(alloc, b.lhs, allowed, outer_keys, inner_items, preds, range_out, range_n)) return false;
                return try splitCorrelated(alloc, b.rhs, allowed, outer_keys, inner_items, preds, range_out, range_n);
            }
            if (b.op == .lt or b.op == .le or b.op == .gt or b.op == .ge) {
                const lo = refsOuter(b.lhs, allowed);
                const ro = refsOuter(b.rhs, allowed);
                var rc: ?RangeCorr = null;
                if (lo and !ro) {
                    // `outer OP inner` -> `inner FLIP(OP) outer`.
                    rc = .{
                        .inner = b.rhs,
                        .outer = b.lhs,
                        .op = switch (b.op) {
                            .lt => .gt,
                            .le => .ge,
                            .gt => .lt,
                            .ge => .le,
                            else => b.op,
                        },
                    };
                } else if (ro and !lo) {
                    // `inner OP outer` already.
                    rc = .{ .inner = b.lhs, .outer = b.rhs, .op = b.op };
                } else if (!lo and !ro) {
                    try preds.append(alloc, e);
                    return true;
                } else return false;
                if (range_n.* >= RANGE_MAX) return false;
                range_out[range_n.*] = rc;
                range_n.* += 1;
                return true;
            }
            if (b.op == .eq) {
                const lo = refsOuter(b.lhs, allowed);
                const ro = refsOuter(b.rhs, allowed);
                if (lo and !ro) {
                    try outer_keys.append(alloc, b.lhs);
                    try inner_items.append(alloc, b.rhs);
                    return true;
                }
                if (ro and !lo) {
                    try outer_keys.append(alloc, b.rhs);
                    try inner_items.append(alloc, b.lhs);
                    return true;
                }
                if (!lo and !ro) {
                    try preds.append(alloc, e);
                    return true;
                }
                return false; // both sides reference the outer query
            }
            if (refsOuter(e, allowed)) return false;
            try preds.append(alloc, e);
            return true;
        },
        else => {
            if (refsOuter(e, allowed)) return false;
            try preds.append(alloc, e);
            return true;
        },
    }
}

fn andAll(alloc: std.mem.Allocator, preds: []const *sql.Expr) EngineError!?*sql.Expr {
    if (preds.len == 0) return null;
    var acc = preds[0];
    var i: usize = 1;
    while (i < preds.len) : (i += 1) {
        const e = try alloc.create(sql.Expr);
        e.* = .{ .binary = .{ .op = .and_op, .lhs = acc, .rhs = preds[i] } };
        acc = e;
    }
    return acc;
}

/// Reject correlated subqueries: we cannot evaluate them, and evaluating them
/// as if they were uncorrelated silently returns wrong rows. Every qualified
/// column inside the subquery must name the subquery's own table/alias.
fn checkSubqueryScope(sub: *sql.Select) EngineError!void {
    var allowed: [4][]const u8 = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(list: *[4][]const u8, count: *usize, name: []const u8) void {
            var base = name;
            if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base = base[dot + 1 ..];
            if (count.* < list.len) {
                list[count.*] = base;
                count.* += 1;
            }
        }
    }.f;
    switch (sub.from orelse return) {
        .table => |t| add(&allowed, &n, t),
        .subquery => |sq| {
            _ = sq;
            return; // derived table: skip the conservative check
        },
        .function => |f| add(&allowed, &n, f.name),
        .values => {},
    }
    if (sub.alias) |a| add(&allowed, &n, a);
    if (sub.join) |j| add(&allowed, &n, j.table);

    for (sub.items) |it| try checkExprScope(it.expr, allowed[0..n]);
    if (sub.where) |w| try checkExprScope(w, allowed[0..n]);
    for (sub.group_by) |g| try checkExprScope(g, allowed[0..n]);
    if (sub.having) |h| try checkExprScope(h, allowed[0..n]);
    for (sub.order_by) |o| try checkExprScope(o.expr, allowed[0..n]);
}

fn qualifierAllowed(name: []const u8, allowed: []const []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return true; // unqualified
    const q = name[0..dot];
    for (allowed) |a| {
        if (std.ascii.eqlIgnoreCase(q, a)) return true;
    }
    return false;
}

fn checkExprScope(e: *sql.Expr, allowed: []const []const u8) EngineError!void {
    switch (e.*) {
        .column => |n| {
            if (!qualifierAllowed(n, allowed)) return error.CorrelatedSubquery;
        },
        .binary => |b| {
            try checkExprScope(b.lhs, allowed);
            try checkExprScope(b.rhs, allowed);
        },
        .negate => |x| try checkExprScope(x, allowed),
        .not => |x| try checkExprScope(x, allowed),
        .is_null => |x| try checkExprScope(x.operand, allowed),
        .like => |x| {
            try checkExprScope(x.operand, allowed);
            try checkExprScope(x.pattern, allowed);
        },
        .in_list => |x| {
            try checkExprScope(x.operand, allowed);
            for (x.items) |it| try checkExprScope(it, allowed);
        },
        .between => |x| {
            try checkExprScope(x.operand, allowed);
            try checkExprScope(x.low, allowed);
            try checkExprScope(x.high, allowed);
        },
        .cast => |x| try checkExprScope(x.operand, allowed),
        .call => |c| for (c.args) |a| try checkExprScope(a, allowed),
        .case_expr => |c| {
            for (c.whens) |w| {
                try checkExprScope(w.cond, allowed);
                try checkExprScope(w.then, allowed);
            }
            if (c.else_expr) |el| try checkExprScope(el, allowed);
        },
        .in_subquery => |x| try checkExprScope(x.operand, allowed),
        else => {},
    }
}

fn columnMatches(col: []const u8, ref: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(col, ref)) return true;
    if (std.mem.lastIndexOfScalar(u8, ref, '.')) |dot| {
        return std.ascii.eqlIgnoreCase(col, ref[dot + 1 ..]);
    }
    return false;
}

fn findColSlice(cols: []Column, name: []const u8) ?usize {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    for (cols, 0..) |c, i| {
        if (dot) |d| {
            const q = name[0..d];
            const base = name[d + 1 ..];
            if (c.source.len > 0 and std.ascii.eqlIgnoreCase(c.source, q) and std.ascii.eqlIgnoreCase(c.name, base)) return i;
            continue;
        }
        if (columnMatches(c.name, name)) return i;
    }
    // A qualifier may have been rewritten away by an alias pass; accept the
    // bare name only when it is unambiguous.
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

fn defaultValue(ty: ColType) Value {
    return switch (ty) {
        .int => .{ .int = 0 },
        .float => .{ .float = 0 },
        .text, .date, .timestamp => .{ .text = "" },
        .boolean => .{ .boolean = false },
    };
}

fn coerce(t: *Table, idx: usize, v: Value) EngineError!Value {
    if (v == .null) return .null; // NULL is preserved for every column type
    if (t.cols[idx].is_path) {
        const raw = switch (v) {
            .text => |x| x,
            else => try formatValue(t.arena.allocator(), v),
        };
        const p = parsePath(raw) orelse return error.InvalidPath;
        return .{ .text = try t.arena.allocator().dupe(u8, p) };
    }
    if (t.cols[idx].is_lseg) {
        const raw = switch (v) {
            .text => |x| x,
            else => try formatValue(t.arena.allocator(), v),
        };
        const p = parseLseg(raw) orelse return error.InvalidLseg;
        return .{ .text = try formatLseg(t.arena.allocator(), p) };
    }
    if (t.cols[idx].is_macaddr) {
        const raw = switch (v) {
            .text => |x| x,
            else => try formatValue(t.arena.allocator(), v),
        };
        const m = parseMacaddr(raw) orelse return error.InvalidMacaddr;
        return .{ .text = try formatMacaddr(t.arena.allocator(), m) };
    }
    const ty = t.cols[idx].ty;
    const out: Value = switch (ty) {
        .int => blk: {
            if (t.cols[idx].is_oid) {
                const s = switch (v) {
                    .text => |x| x,
                    else => try formatValue(t.arena.allocator(), v),
                };
                switch (parseOidText(s)) {
                    .value => |x| break :blk .{ .int = x },
                    .invalid => return error.InvalidOid,
                    .out_of_range => return error.OidOutOfRange,
                }
            }
            if (t.cols[idx].int_bits != 0) {
                const bits = t.cols[idx].int_bits;
                const s = switch (v) {
                    .text => |x| x,
                    else => try formatValue(t.arena.allocator(), v),
                };
                switch (parseTypedInt(s, bits)) {
                    .value => |x| break :blk .{ .int = x },
                    .invalid => return error.InvalidInt,
                    .out_of_range => return error.IntOutOfRange,
                }
            }
            break :blk switch (v) {
                .int => v,
                .float => |f| .{ .int = @as(i64, @intFromFloat(f)) },
                .text => |s| .{ .int = std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch 0 },
                .boolean => |b| .{ .int = @intFromBool(b) },
                .null => .{ .int = 0 },
            };
        },
        .float => switch (v) {
            .float => v,
            .int => |i| .{ .float = @as(f64, @floatFromInt(i)) },
            .text => |s| .{ .float = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch 0 },
            .boolean => |b| .{ .float = @as(f64, @floatFromInt(@intFromBool(b))) },
            .null => .{ .float = 0 },
        },
        .text, .date, .timestamp => blk: {
            const raw = switch (v) {
                .text => |x| x,
                .null => "",
                else => try formatValue(t.arena.allocator(), v),
            };
            const max = t.cols[idx].max_len;
            const s2 = if (max > 0) std.mem.trimEnd(u8, raw, " ") else raw;
            if (max > 0 and s2.len > max) return error.ValueTooLong;
            if (t.cols[idx].pad_char and max > s2.len) {
                const padded = try t.arena.allocator().alloc(u8, max);
                @memcpy(padded[0..s2.len], s2);
                @memset(padded[s2.len..], ' ');
                break :blk .{ .text = padded };
            }
            break :blk .{ .text = try t.arena.allocator().dupe(u8, s2) };
        },
        .boolean => switch (v) {
            .boolean => v,
            .int => |i| .{ .boolean = i != 0 },
            else => .{ .boolean = false },
        },
    };
    return out;
}

fn truthy(v: Value) bool {
    return switch (v) {
        .boolean => |b| b,
        .int => |i| i != 0,
        .float => |f| f != 0,
        .text => |s| s.len > 0,
        .null => false,
    };
}

fn exprToUsize(v: Value) EngineError!usize {
    return switch (v) {
        .int => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        else => 0,
    };
}

/// Minimal regex support for catalog queries (`~ '^pg_'`, `!~ '^pg_toast'`):
/// leading `^` = prefix match, trailing `$` = suffix match, otherwise substring.
fn simpleRegex(alloc: std.mem.Allocator, hay_v: Value, pat_v: Value) bool {
    const hay = formatValue(alloc, hay_v) catch return false;
    var pat = formatValue(alloc, pat_v) catch return false;
    var prefix = false;
    var suffix = false;
    if (pat.len > 0 and pat[0] == '^') {
        prefix = true;
        pat = pat[1..];
    }
    if (pat.len > 0 and pat[pat.len - 1] == '$') {
        suffix = true;
        pat = pat[0 .. pat.len - 1];
    }
    // Minimal `.*` support (the regex subset used by test_setup and several
    // catalog queries): any text between the literal prefix and suffix.
    if (std.mem.indexOf(u8, pat, ".*")) |star| {
        const pre = pat[0..star];
        const post = pat[star + 2 ..];
        if (prefix and suffix) {
            if (!std.mem.startsWith(u8, hay, pre) or !std.mem.endsWith(u8, hay, post)) return false;
            return hay.len >= pre.len + post.len;
        }
        if (prefix) return std.mem.startsWith(u8, hay, pre);
        if (suffix) return std.mem.endsWith(u8, hay, post);
        if (pre.len == 0) return std.mem.indexOf(u8, hay, post) != null;
        const at = std.mem.indexOf(u8, hay, pre) orelse return false;
        return std.mem.indexOfPos(u8, hay, at + pre.len, post) != null;
    }
    if (prefix and suffix) return std.mem.eql(u8, hay, pat);
    if (prefix) return std.mem.startsWith(u8, hay, pat);
    if (suffix) return std.mem.endsWith(u8, hay, pat);
    return std.mem.indexOf(u8, hay, pat) != null;
}

fn applyBinary(alloc: std.mem.Allocator, op: sql.BinOp, l: Value, r: Value) EngineError!Value {
    switch (op) {
        .band, .bor, .bxor => {
            if (l == .text and r == .text) {
                if (parseMacaddr(l.text)) |lm| {
                    if (parseMacaddr(r.text)) |rm| {
                        var m: [6]u8 = undefined;
                        for (0..6) |i| m[i] = switch (op) {
                            .band => lm[i] & rm[i],
                            .bor => lm[i] | rm[i],
                            .bxor => lm[i] ^ rm[i],
                            else => unreachable,
                        };
                        return .{ .text = try formatMacaddr(alloc, m) };
                    }
                }
            }
            if (l == .int and r == .int) return .{ .int = switch (op) {
                .band => l.int & r.int,
                .bor => l.int | r.int,
                .bxor => l.int ^ r.int,
                else => unreachable,
            } };
            return .null;
        },
        .and_op => {
            // SQL three-valued logic: FALSE dominates, then UNKNOWN.
            if ((!l.isNull() and !truthy(l)) or (!r.isNull() and !truthy(r))) return .{ .boolean = false };
            if (l.isNull() or r.isNull()) return .null;
            return .{ .boolean = true };
        },
        .or_op => {
            if ((!l.isNull() and truthy(l)) or (!r.isNull() and truthy(r))) return .{ .boolean = true };
            if (l.isNull() or r.isNull()) return .null;
            return .{ .boolean = false };
        },
        .eq, .neq, .lt, .gt, .le, .ge => {
            if (l.isNull() or r.isNull()) return .null;
            // An untyped string literal compared with a numeric column is
            // coerced by PostgreSQL (`oid = '1234'`, `int8 < '456'`).
            var lv = l;
            var rv = r;
            if (l == .int and r == .text) {
                rv = .{ .int = std.fmt.parseInt(i64, std.mem.trim(u8, r.text, " \t\r\n"), 10) catch 0 };
            } else if (l == .text and r == .int) {
                lv = .{ .int = std.fmt.parseInt(i64, std.mem.trim(u8, l.text, " \t\r\n"), 10) catch 0 };
            }
            return .{ .boolean = switch (op) {
                .eq => Value.eql(lv, rv),
                .neq => !Value.eql(lv, rv),
                .lt => Value.order(lv, rv) == .lt,
                .gt => Value.order(lv, rv) == .gt,
                .le => Value.order(lv, rv) != .gt,
                .ge => Value.order(lv, rv) != .lt,
                else => unreachable,
            } };
        },
        .regex => {
            if (l.isNull() or r.isNull()) return .null;
            return .{ .boolean = simpleRegex(alloc, l, r) };
        },
        .regex_ne => {
            if (l.isNull() or r.isNull()) return .null;
            return .{ .boolean = !simpleRegex(alloc, l, r) };
        },
        else => {},
    }
    if (l.isNull() or r.isNull()) return .null;
    const both_int = l == .int and r == .int;
    switch (op) {
        .add => {
            if (both_int) return .{ .int = l.int + r.int };
            if (l == .text and r == .text) {
                const out = try std.fmt.allocPrint(alloc, "{s}{s}", .{ l.text, r.text });
                return .{ .text = out };
            }
            return .{ .float = l.asFloat() + r.asFloat() };
        },
        .sub => {
            if (both_int) return .{ .int = l.int - r.int };
            return .{ .float = l.asFloat() - r.asFloat() };
        },
        .mul => {
            if (both_int) return .{ .int = l.int * r.int };
            return .{ .float = l.asFloat() * r.asFloat() };
        },
        .div => {
            if (both_int) {
                if (r.int == 0) return .null;
                return .{ .int = @divTrunc(l.int, r.int) };
            }
            const d = r.asFloat();
            if (d == 0) return .null;
            return .{ .float = l.asFloat() / d };
        },
        .shl, .shr => {
            if (both_int) {
                const sh: u6 = @intCast(@as(u64, @bitCast(r.int)) & 63);
                const u: u64 = @bitCast(l.int);
                const shifted: u64 = if (op == .shl) u << sh else u >> sh;
                return .{ .int = @bitCast(shifted) };
            }
            return .null;
        },
        .mod => {
            if (both_int) {
                if (r.int == 0) return .null;
                return .{ .int = @rem(l.int, r.int) };
            }
            const d = r.asFloat();
            if (d == 0) return .null;
            return .{ .float = @mod(l.asFloat(), d) };
        },
        else => return .null,
    }
}

fn roundHalfEven(x: f64) i64 {
    const fl = @floor(x);
    const diff = x - fl;
    if (diff < 0.5) return @intFromFloat(fl);
    if (diff > 0.5) return @intFromFloat(fl + 1);
    const i: i64 = @intFromFloat(fl);
    return if (@mod(i, 2) == 0) i else i + 1;
}

fn castValue(alloc: std.mem.Allocator, v: Value, type_name: []const u8) EngineError!Value {
    return castValueMode(alloc, v, type_name, false);
}

fn castValueMode(alloc: std.mem.Allocator, v: Value, type_name: []const u8, numeric_mode: bool) EngineError!Value {
    if (v == .null) return .null;
    const ib = intTypeBits(type_name);
    if (ib != 0) {
        if (v == .text) {
            switch (parseTypedInt(v.text, ib)) {
                .value => |x| return .{ .int = x },
                .invalid => return error.InvalidInt,
                .out_of_range => return if (ib == 2) error.SmallintOutOfRange else if (ib == 4) error.IntegerOutOfRange else error.BigintOutOfRange,
            }
        }
        if (v == .int) {
            const lo: i64 = if (ib == 2) -32768 else if (ib == 4) -2147483648 else std.math.minInt(i64);
            const hi: i64 = if (ib == 2) 32767 else if (ib == 4) 2147483647 else std.math.maxInt(i64);
            if (v.int < lo or v.int > hi) return if (ib == 2) error.SmallintOutOfRange else if (ib == 4) error.IntegerOutOfRange else error.BigintOutOfRange;
            return v;
        }
        if (v == .float) {
            const lo: f64 = if (ib == 2) -32768 else if (ib == 4) -2147483648 else -9223372036854775808.0;
            const hi: f64 = if (ib == 2) 32767 else if (ib == 4) 2147483647 else 9223372036854775807.0;
            if (v.float < lo or v.float > hi) return if (ib == 2) error.SmallintOutOfRange else if (ib == 4) error.IntegerOutOfRange else error.BigintOutOfRange;
            return .{ .int = if (numeric_mode) @intFromFloat(@round(v.float)) else roundHalfEven(v.float) };
        }
    }
    if (std.ascii.eqlIgnoreCase(type_name, "path")) {
        const s = switch (v) {
            .text => |x| x,
            else => try formatValue(alloc, v),
        };
        const p = parsePath(s) orelse return error.InvalidPath;
        return .{ .text = try alloc.dupe(u8, p) };
    }
    if (std.ascii.eqlIgnoreCase(type_name, "lseg")) {
        const s = switch (v) {
            .text => |x| x,
            else => try formatValue(alloc, v),
        };
        const p = parseLseg(s) orelse return error.InvalidLseg;
        return .{ .text = try formatLseg(alloc, p) };
    }
    if (std.ascii.eqlIgnoreCase(type_name, "macaddr")) {
        const s = switch (v) {
            .text => |x| x,
            else => try formatValue(alloc, v),
        };
        const m = parseMacaddr(s) orelse return error.InvalidMacaddr;
        return .{ .text = try formatMacaddr(alloc, m) };
    }
    if (std.ascii.eqlIgnoreCase(type_name, "float4") or std.ascii.eqlIgnoreCase(type_name, "real")) {
        const f: f64 = switch (v) {
            .float => |x| x,
            .int => |x| @floatFromInt(x),
            .text => |t| std.fmt.parseFloat(f64, std.mem.trim(u8, t, " \t\r\n")) catch 0,
            else => 0,
        };
        return .{ .float = @as(f64, @as(f32, @floatCast(f))) };
    }
    if (std.ascii.eqlIgnoreCase(type_name, "bool") or std.ascii.eqlIgnoreCase(type_name, "boolean")) {
        return switch (v) {
            .boolean => v,
            .int => |x| .{ .boolean = x != 0 },
            .float => |x| .{ .boolean = x != 0 },
            .text => |t| if (parseBoolInput(t)) |b| .{ .boolean = b } else error.InvalidBoolean,
            .null => .null,
        };
    }
    if (std.mem.eql(u8, type_name, "oid")) {
        const s = switch (v) {
            .text => |x| x,
            else => try formatValue(alloc, v),
        };
        return switch (parseOidText(s)) {
            .value => |x| .{ .int = x },
            .invalid => error.InvalidOid,
            .out_of_range => error.OidOutOfRange,
        };
    }
    if (std.mem.eql(u8, type_name, "\"char\"")) {
        const s = switch (v) {
            .text => |x| x,
            else => try formatValue(alloc, v),
        };
        // PostgreSQL's ad-hoc one-byte "char": octal escapes, NUL truncates.
        var out = std.ArrayList(u8).empty;
        defer out.deinit(alloc);
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '\\' and i + 3 < s.len and s[i+1] >= '0' and s[i+1] <= '7' and s[i+2] >= '0' and s[i+2] <= '7' and s[i+3] >= '0' and s[i+3] <= '7') {
                const code = (s[i+1]-'0')*64 + (s[i+2]-'0')*8 + (s[i+3]-'0');
                if (code == 0) break;
                if (code < 128) try out.append(alloc, code) else {
                    try out.appendSlice(alloc, s[i..i+4]);
                }
                i += 4;
            } else {
                try out.append(alloc, s[i]);
                i += 1;
            }
        }
        return .{ .text = try out.toOwnedSlice(alloc) };
    }
    const ty = mapType(type_name);
    return switch (ty) {
        .int => switch (v) {
            .int => v,
            .float => |f| .{ .int = if (numeric_mode) @intFromFloat(@round(f)) else roundHalfEven(f) },
            .text => |s| .{ .int = std.fmt.parseInt(i64, s, 10) catch 0 },
            else => .{ .int = 0 },
        },
        .float => switch (v) {
            .float => v,
            .int => |i| .{ .float = @as(f64, @floatFromInt(i)) },
            .text => |s| .{ .float = std.fmt.parseFloat(f64, s) catch 0 },
            else => .{ .float = 0 },
        },
        .text, .date, .timestamp => .{ .text = try formatValue(alloc, v) },
        .boolean => .{ .boolean = truthy(v) },
    };
}

/// Membership-key text for a value: text as-is, numbers via `{d}` (the same
/// form `appendKeyPart` uses when the sets are built).
fn fmtKey(alloc: std.mem.Allocator, v: Value) EngineError![]const u8 {
    return switch (v) {
        .text => |t| t,
        .int => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(alloc, "{d}", .{f}),
        .boolean => |b| if (b) "true" else "false",
        .null => "",
    };
}

pub fn formatValue(alloc: std.mem.Allocator, v: Value) EngineError![]const u8 {
    return switch (v) {
        .null => "\\N",
        .int => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| blk: {
            const s = try std.fmt.allocPrint(alloc, "{d}", .{f});
            if (std.mem.indexOfAny(u8, s, ".eE") == null) {
                break :blk try std.fmt.allocPrint(alloc, "{s}.0", .{s});
            }
            break :blk s;
        },
        .text => |s| s,
        .boolean => |b| if (b) "true" else "false",
    };
}

const InputErrorInfo = struct { message: []const u8, code: []const u8 };

fn parseBoolInput(text: []const u8) ?bool {
    const s = std.mem.trim(u8, text, " \t\r\n");
    const true_vals = [_][]const u8{ "t", "tr", "tru", "true", "y", "ye", "yes", "on", "1" };
    const false_vals = [_][]const u8{ "f", "fa", "fal", "fals", "false", "n", "no", "of", "off", "0" };
    for (true_vals) |v| if (std.ascii.eqlIgnoreCase(s, v)) return true;
    for (false_vals) |v| if (std.ascii.eqlIgnoreCase(s, v)) return false;
    return null;
}

fn intTypeBits(type_name: []const u8) u8 {
    var buf: [64]u8 = undefined;
    const n = @min(type_name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], type_name[0..n]);
    if (std.mem.eql(u8, lower, "int2") or std.mem.eql(u8, lower, "smallint")) return 2;
    if (std.mem.eql(u8, lower, "int4") or std.mem.eql(u8, lower, "integer") or std.mem.eql(u8, lower, "int")) return 4;
    if (std.mem.eql(u8, lower, "int8") or std.mem.eql(u8, lower, "bigint")) return 8;
    return 0;
}

fn parseTypedInt(text: []const u8, bits: u8) union(enum) { value: i64, invalid, out_of_range } {
    var s = std.mem.trim(u8, text, " \t\r\n");
    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) { neg = s[0] == '-'; s = s[1..]; }
    if (s.len == 0) return .invalid;
    var base: u8 = 10;
    var had_prefix = false;
    if (s.len >= 2 and s[0] == '0') {
        if (s[1] == 'b' or s[1] == 'B') { base = 2; s = s[2..]; had_prefix = true; }
        else if (s[1] == 'o' or s[1] == 'O') { base = 8; s = s[2..]; had_prefix = true; }
        else if (s[1] == 'x' or s[1] == 'X') { base = 16; s = s[2..]; had_prefix = true; }
    }
    if (s.len == 0) return .invalid;
    var v: i128 = 0;
    var prev_us = false;
    for (s, 0..) |c, i| {
        if (c == '_') {
            if (i + 1 == s.len or prev_us) return .invalid;
            if (i == 0 and (!had_prefix or s.len < 2 or s[1] == '_')) return .invalid;
            prev_us = true;
            continue;
        }
        const d: u8 = if (c >= '0' and c <= '9') c - '0' else if (c >= 'a' and c <= 'f') c - 'a' + 10 else if (c >= 'A' and c <= 'F') c - 'A' + 10 else return .invalid;
        if (d >= base) return .invalid;
        v = v * base + d;
        if (v > 0x1_0000_0000_0000_0000) return .out_of_range;
        prev_us = false;
    }
    if (neg) v = -v;
    const lo: i128 = if (bits == 2) -32768 else if (bits == 4) -2147483648 else -9223372036854775808;
    const hi: i128 = if (bits == 2) 32767 else if (bits == 4) 2147483647 else 9223372036854775807;
    if (v < lo or v > hi) return .out_of_range;
    return .{ .value = @intCast(v) };
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn geomFloat(text: []const u8) ?f64 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(t, "nan")) return std.math.nan(f64);
    if (std.ascii.eqlIgnoreCase(t, "inf") or std.ascii.eqlIgnoreCase(t, "infinity")) return std.math.inf(f64);
    if (std.ascii.eqlIgnoreCase(t, "-inf") or std.ascii.eqlIgnoreCase(t, "-infinity")) return -std.math.inf(f64);
    // Reject PostgreSQL-invalid spellings such as "4r2".
    for (t) |c| {
        if (!(std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-')) return null;
    }
    return std.fmt.parseFloat(f64, t) catch null;
}

fn geomNextNumber(s: []const u8, i: *usize) ?f64 {
    while (i.* < s.len and std.ascii.isWhitespace(s[i.*])) i.* += 1;
    const start = i.*;
    if (i.* < s.len and std.ascii.isAlphabetic(s[i.*])) {
        while (i.* < s.len and std.ascii.isAlphabetic(s[i.*])) i.* += 1;
    } else {
        while (i.* < s.len and !(std.ascii.isWhitespace(s[i.*]) or s[i.*] == ',' or s[i.*] == ')' or s[i.*] == ']')) i.* += 1;
    }
    if (i.* == start) return null;
    return geomFloat(s[start..i.*]);
}

fn geomSkipSpace(s: []const u8, i: *usize) void {
    while (i.* < s.len and std.ascii.isWhitespace(s[i.*])) i.* += 1;
}

fn parsePoint(text: []const u8) ?[2]f64 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    var i: usize = 0;
    if (i < s.len and s[i] == '(') i += 1;
    const x = geomNextNumber(s, &i) orelse return null;
    geomSkipSpace(s, &i);
    if (i >= s.len or s[i] != ',') return null;
    i += 1;
    const y = geomNextNumber(s, &i) orelse return null;
    geomSkipSpace(s, &i);
    if (i < s.len and s[i] == ')') i += 1;
    geomSkipSpace(s, &i);
    if (i != s.len) return null;
    return .{ x, y };
}

fn parseLseg(text: []const u8) ?[4]f64 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    var i: usize = 0;
    var had_bracket = false;
    if (i < s.len and s[i] == '[') { i += 1; had_bracket = true; }
    geomSkipSpace(s, &i);
    var nums: [4]f64 = undefined;
    var n: usize = 0;
    if (i < s.len and s[i] == '(') {
        while (n < 4) {
            geomSkipSpace(s, &i);
            if (i >= s.len or s[i] != '(') return null;
            i += 1;
            nums[n] = geomNextNumber(s, &i) orelse return null;
            n += 1;
            geomSkipSpace(s, &i);
            if (i >= s.len or s[i] != ',') return null;
            i += 1;
            nums[n] = geomNextNumber(s, &i) orelse return null;
            n += 1;
            geomSkipSpace(s, &i);
            if (i >= s.len or s[i] != ')') return null;
            i += 1;
            geomSkipSpace(s, &i);
            if (n < 4) {
                if (i >= s.len or s[i] != ',') return null;
                i += 1;
            }
        }
    } else {
        while (n < 4) {
            nums[n] = geomNextNumber(s, &i) orelse return null;
            n += 1;
            geomSkipSpace(s, &i);
            if (n < 4) {
                if (i >= s.len or s[i] != ',') return null;
                i += 1;
            }
        }
    }
    geomSkipSpace(s, &i);
    if (i < s.len and s[i] == ']') {
        i += 1;
    } else if (had_bracket) return null;
    geomSkipSpace(s, &i);
    if (i != s.len) return null;
    return nums;
}

fn formatGeomNum(alloc: std.mem.Allocator, f: f64) ![]const u8 {
    if (std.math.isNan(f)) return "NaN";
    if (std.math.isInf(f)) return if (f < 0) "-Infinity" else "Infinity";
    if (f == @trunc(f) and @abs(f) < 1e15) {
        return std.fmt.allocPrint(alloc, "{d}", .{@as(i64, @intFromFloat(f))});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{f});
}

fn formatLseg(alloc: std.mem.Allocator, p: [4]f64) ![]const u8 {
    return std.fmt.allocPrint(alloc, "[({s},{s}),({s},{s})]", .{
        try formatGeomNum(alloc, p[0]), try formatGeomNum(alloc, p[1]),
        try formatGeomNum(alloc, p[2]), try formatGeomNum(alloc, p[3]),
    });
}

fn parsePath(text: []const u8) ?[]const u8 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    var body = s;
    var open = false;
    if (body.len > 0 and body[0] == '[') {
        open = true;
        if (body.len < 2 or body[body.len - 1] != ']') return null;
        body = body[1 .. body.len - 1];
    } else if (body.len > 0 and body[0] == '(') {
        if (body[body.len - 1] != ')') return null;
        var depth: i32 = 0;
        for (body) |c| {
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth < 0) return null;
            }
        }
        if (depth != 0) return null;
        body = body[1 .. body.len - 1];
    }
    var points = std.ArrayList([]const u8).empty;
    defer points.deinit(std.heap.page_allocator);
    var i: usize = 0;
    geomSkipSpace(body, &i);
    if (i < body.len and body[i] == '(') {
        // Sequence of (x,y) points.
        while (i < body.len) {
            geomSkipSpace(body, &i);
            if (i >= body.len or body[i] != '(') return null;
            const start = i;
            var depth: usize = 0;
            while (i < body.len) {
                if (body[i] == '(') depth += 1;
                if (body[i] == ')') {
                    depth -= 1;
                    i += 1;
                    if (depth == 0) break;
                    continue;
                }
                i += 1;
            }
            if (depth != 0) return null;
            if (parsePoint(body[start..i]) == null) return null;
            points.append(std.heap.page_allocator, body[start..i]) catch return null;
            geomSkipSpace(body, &i);
            if (i < body.len) {
                if (body[i] != ',') return null;
                i += 1;
            }
        }
    } else {
        // Flat number list: pairs of coordinates.
        var nums = std.ArrayList(f64).empty;
        defer nums.deinit(std.heap.page_allocator);
        while (i < body.len) {
            const v = geomNextNumber(body, &i) orelse return null;
            nums.append(std.heap.page_allocator, v) catch return null;
            geomSkipSpace(body, &i);
            if (i < body.len) {
                if (body[i] != ',') return null;
                i += 1;
            }
        }
        if (nums.items.len < 2 or nums.items.len % 2 != 0) return null;
        var k: usize = 0;
        while (k < nums.items.len) : (k += 2) {
            const pt = std.fmt.allocPrint(std.heap.page_allocator, "({d},{d})", .{ nums.items[k], nums.items[k + 1] }) catch return null;
            points.append(std.heap.page_allocator, pt) catch return null;
        }
        // Fall through to formatting below.
        var out = std.ArrayList(u8).empty;
        defer out.deinit(std.heap.page_allocator);
        out.append(std.heap.page_allocator, if (open) '[' else '(') catch return null;
        for (points.items, 0..) |p, pi| {
            if (pi > 0) out.append(std.heap.page_allocator, ',') catch return null;
            out.appendSlice(std.heap.page_allocator, normalizePoint(p)) catch return null;
        }
        out.append(std.heap.page_allocator, if (open) ']' else ')') catch return null;
        return out.toOwnedSlice(std.heap.page_allocator) catch null;
    }
    if (points.items.len == 0) return null;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.heap.page_allocator);
    out.append(std.heap.page_allocator, if (open) '[' else '(') catch return null;
    for (points.items, 0..) |p, pi| {
        if (pi > 0) out.append(std.heap.page_allocator, ',') catch return null;
        out.appendSlice(std.heap.page_allocator, normalizePoint(p)) catch return null;
    }
    out.append(std.heap.page_allocator, if (open) ']' else ')') catch return null;
    return out.toOwnedSlice(std.heap.page_allocator) catch null;
}

fn normalizePoint(p: []const u8) []const u8 {
    // Points are already validated; normalize spacing by reparsing.
    const q = parsePoint(p) orelse return p;
    const buf = &geom_scratch;
    buf.clearRetainingCapacity();
    var tmp: [64]u8 = undefined;
    const x = geomFmtInto(&tmp, q[0]);
    buf.appendSlice(std.heap.page_allocator, "(") catch return p;
    buf.appendSlice(std.heap.page_allocator, x) catch return p;
    buf.appendSlice(std.heap.page_allocator, ",") catch return p;
    const y = geomFmtInto(&tmp, q[1]);
    buf.appendSlice(std.heap.page_allocator, y) catch return p;
    buf.appendSlice(std.heap.page_allocator, ")") catch return p;
    return buf.items;
}

threadlocal var geom_scratch: std.ArrayList(u8) = .empty;

fn geomFmtInto(buf: []u8, f: f64) []const u8 {
    if (std.math.isNan(f)) return "NaN";
    if (std.math.isInf(f)) return if (f < 0) "-Infinity" else "Infinity";
    if (f == @trunc(f) and @abs(f) < 1e15) {
        const n = std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(f))}) catch return "0";
        return n;
    }
    return std.fmt.bufPrint(buf, "{d}", .{f}) catch "0";
}

fn parseMacaddr(text: []const u8) ?[6]u8 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    var out: [6]u8 = undefined;
    // 12 hex digits, no separators.
    if (s.len == 12) {
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            const hi = hexVal(s[i * 2]) orelse return null;
            const lo = hexVal(s[i * 2 + 1]) orelse return null;
            out[i] = hi * 16 + lo;
        }
        return out;
    }
    // 6 groups of 2, separators ':' or '-'.
    if (s.len == 17 and (s[2] == ':' or s[2] == '-')) {
        const sep = s[2];
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            const p = i * 3;
            if (i < 5 and s[p + 2] != sep) return null;
            const hi = hexVal(s[p]) orelse return null;
            const lo = hexVal(s[p + 1]) orelse return null;
            out[i] = hi * 16 + lo;
        }
        return out;
    }
    // 3 groups of 4, separators '.' or '-'.
    if (s.len == 14 and (s[4] == '.' or s[4] == '-')) {
        const sep = s[4];
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const p = i * 5;
            if (i < 2 and s[p + 4] != sep) return null;
            const h0 = hexVal(s[p]) orelse return null;
            const h1 = hexVal(s[p + 1]) orelse return null;
            const h2 = hexVal(s[p + 2]) orelse return null;
            const h3 = hexVal(s[p + 3]) orelse return null;
            out[i * 2] = h0 * 16 + h1;
            out[i * 2 + 1] = h2 * 16 + h3;
        }
        return out;
    }
    // 2 groups of 6, separators ':' or '-'.
    if (s.len == 13 and (s[6] == ':' or s[6] == '-')) {
        const sep = s[6];
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            const p = i * 7;
            if (i == 0 and s[p + 6] != sep) return null;
            var j: usize = 0;
            while (j < 3) : (j += 1) {
                const hi = hexVal(s[p + j * 2]) orelse return null;
                const lo = hexVal(s[p + j * 2 + 1]) orelse return null;
                out[i * 3 + j] = hi * 16 + lo;
            }
        }
        return out;
    }
    return null;
}

fn formatMacaddr(alloc: std.mem.Allocator, m: [6]u8) ![]const u8 {
    const hex = "0123456789abcdef";
    const out = try alloc.alloc(u8, 17);
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        out[i * 3] = hex[m[i] >> 4];
        out[i * 3 + 1] = hex[m[i] & 0xf];
        if (i < 5) out[i * 3 + 2] = ':';
    }
    return out;
}

fn isOidTypeName(type_name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n = @min(type_name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], type_name[0..n]);
    return std.mem.startsWith(u8, lower, "oid") and !std.mem.startsWith(u8, lower, "oidvector");
}

const OidParse = union(enum) { value: i64, invalid, out_of_range };

fn parseOidText(text: []const u8) OidParse {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (s.len == 0) return .invalid;
    var i: usize = 0;
    if (s[0] == '+' or s[0] == '-') i = 1;
    if (i >= s.len) return .invalid;
    for (s[i..]) |c| if (!std.ascii.isDigit(c)) return .invalid;
    const x = std.fmt.parseInt(i64, s, 10) catch return .out_of_range;
    if (x > 4294967295 or x < -2147483648) return .out_of_range;
    if (x < 0) {
        const u: u32 = @truncate(@as(u64, @bitCast(x)));
        return .{ .value = @as(i64, u) };
    }
    return .{ .value = x };
}

fn isCharTypeName(type_name: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n = @min(type_name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], type_name[0..n]);
    return std.mem.startsWith(u8, lower, "char") and !std.mem.startsWith(u8, lower, "\"char\"");
}

fn typeCharLen(type_name: []const u8) ?usize {
    var buf: [64]u8 = undefined;
    const n = @min(type_name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], type_name[0..n]);
    if (!(std.mem.startsWith(u8, lower, "char") or std.mem.startsWith(u8, lower, "varchar"))) return null;
    const open = std.mem.indexOfScalar(u8, lower, '(') orelse return if (std.mem.startsWith(u8, lower, "char")) 1 else 0;
    const close = std.mem.indexOfScalarPos(u8, lower, open, ')') orelse return null;
    const digits = std.mem.trim(u8, lower[open + 1 .. close], " ");
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

fn inputErrorInfo(alloc: std.mem.Allocator, val: []const u8, typ: []const u8) ?InputErrorInfo {
    var lbuf: [64]u8 = undefined;
    const n = @min(typ.len, lbuf.len);
    const lower = std.ascii.lowerString(lbuf[0..n], typ[0..n]);
    if (std.mem.startsWith(u8, lower, "bool")) {
        if (parseBoolInput(val) != null) return null;
        return .{
            .message = std.fmt.allocPrint(alloc, "invalid input syntax for type boolean: \"{s}\"", .{val}) catch "invalid input syntax for type boolean",
            .code = "22P02",
        };
    }
    if (std.mem.startsWith(u8, lower, "char") or std.mem.startsWith(u8, lower, "varchar")) {
        const max = typeCharLen(typ) orelse 0;
        const trimmed = std.mem.trimEnd(u8, val, " ");
        if (max == 0 or trimmed.len <= max) return null;
        const kind = if (std.mem.startsWith(u8, lower, "varchar")) "character varying" else "character";
        return .{
            .message = std.fmt.allocPrint(alloc, "value too long for type {s}({d})", .{ kind, max }) catch "value too long",
            .code = "22001",
        };
    }
    if (std.mem.startsWith(u8, lower, "oidvector")) {
        var it = std.mem.tokenizeAny(u8, val, " \t\r\n");
        while (it.next()) |tok| {
            switch (parseOidText(tok)) {
                .value => {},
                .invalid => {
                    var bad = tok;
                    while (bad.len > 0 and std.ascii.isDigit(bad[0])) bad = bad[1..];
                    if (bad.len == 0) bad = tok;
                    return .{ .message = std.fmt.allocPrint(alloc, "invalid input syntax for type oid: \"{s}\"", .{bad}) catch "invalid input syntax for type oid", .code = "22P02" };
                },
                .out_of_range => return .{ .message = std.fmt.allocPrint(alloc, "value \"{s}\" is out of range for type oid", .{tok}) catch "out of range for type oid", .code = "22003" },
            }
        }
        return null;
    }
    if (std.mem.eql(u8, lower, "path")) {
        if (parsePath(val) != null) return null;
        return .{ .message = std.fmt.allocPrint(alloc, "invalid input syntax for type path: \"{s}\"", .{val}) catch "invalid input syntax for type path", .code = "22P02" };
    }
    if (std.mem.eql(u8, lower, "lseg")) {
        if (parseLseg(val) != null) return null;
        return .{ .message = std.fmt.allocPrint(alloc, "invalid input syntax for type lseg: \"{s}\"", .{val}) catch "invalid input syntax for type lseg", .code = "22P02" };
    }
    if (std.mem.eql(u8, lower, "macaddr") or std.mem.eql(u8, lower, "macaddr8")) {
        if (parseMacaddr(val) != null) return null;
        return .{ .message = std.fmt.allocPrint(alloc, "invalid input syntax for type macaddr: \"{s}\"", .{val}) catch "invalid input syntax for type macaddr", .code = "22P02" };
    }
    if (std.mem.startsWith(u8, lower, "oid")) {
        return switch (parseOidText(val)) {
            .value => null,
            .invalid => .{ .message = std.fmt.allocPrint(alloc, "invalid input syntax for type oid: \"{s}\"", .{val}) catch "invalid input syntax for type oid", .code = "22P02" },
            .out_of_range => .{ .message = std.fmt.allocPrint(alloc, "value \"{s}\" is out of range for type oid", .{val}) catch "out of range for type oid", .code = "22003" },
        };
    }
    if (std.mem.startsWith(u8, lower, "int2vector")) {
        var it = std.mem.tokenizeAny(u8, val, " \t\r\n");
        while (it.next()) |tok| switch (parseTypedInt(tok, 2)) {
            .value => {},
            .invalid => return .{ .message = std.fmt.allocPrint(alloc, "invalid input syntax for type smallint: \"{s}\"", .{tok}) catch "invalid input syntax", .code = "22P02" },
            .out_of_range => return .{ .message = std.fmt.allocPrint(alloc, "value \"{s}\" is out of range for type smallint", .{tok}) catch "out of range", .code = "22003" },
        };
        return null;
    }
    if (std.mem.startsWith(u8, lower, "int2") or std.mem.startsWith(u8, lower, "int4") or std.mem.startsWith(u8, lower, "int8")) {
        const bits: u8 = if (std.mem.startsWith(u8, lower, "int2")) 2 else if (std.mem.startsWith(u8, lower, "int4")) 4 else 8;
        const tname = if (bits == 2) "smallint" else if (bits == 4) "integer" else "bigint";
        return switch (parseTypedInt(val, bits)) {
            .value => null,
            .invalid => .{ .message = std.fmt.allocPrint(alloc, "invalid input syntax for type {s}: \"{s}\"", .{ tname, val }) catch "invalid input syntax", .code = "22P02" },
            .out_of_range => .{ .message = std.fmt.allocPrint(alloc, "value \"{s}\" is out of range for type {s}", .{ val, tname }) catch "out of range", .code = "22003" },
        };
    }
    return null;
}

fn pgToChar(alloc: std.mem.Allocator, value: Value, fmt: []const u8) EngineError![]const u8 {
    var neg = false;
    var mag: u64 = 0;
    switch (value) {
        .int => |x| { neg = x < 0; mag = if (x < 0) @as(u64, @intCast(-(x + 1))) + 1 else @intCast(x); },
        .float => |f| { neg = f < 0; mag = @intFromFloat(@abs(@round(f))); },
        else => return error.SyntaxError,
    }
    if (std.mem.eql(u8, fmt, "FMRN")) return pgRoman(alloc, mag);
    if (std.mem.indexOf(u8, fmt, "EEEE") != null or std.mem.indexOf(u8, fmt, "eeee") != null) {
        const s = try std.fmt.allocPrint(alloc, "{d}", .{mag});
        const exp: i32 = @intCast(s.len - 1);
        const lead = s[0];
        const rest = if (s.len > 1) s[1..] else "0";
        const frac = if (rest.len > 2) rest[0..2] else rest;
        return std.fmt.allocPrint(alloc, "{s}{c}.{s}e{s}{d:0>2}", .{ if (neg) "-" else " ", lead, frac, if (exp >= 0) "+" else "-", @abs(exp) });
    }
    if (std.mem.indexOfScalar(u8, fmt, 'V')) |vp| {
        var zeros: usize = 0;
        for (fmt[vp + 1 ..]) |c| if (c == '9' or c == '0') { zeros += 1; };
        var mul: u64 = 1;
        var z: usize = 0;
        while (z < zeros) : (z += 1) mul *= 10;
        const v = mag * mul;
        const before = digitsBefore(fmt);
        const width = before + zeros;
        const body = try std.fmt.allocPrint(alloc, "{d}", .{v});
        var out = try alloc.alloc(u8, width + 1);
        out[0] = if (neg) '-' else ' ';
        @memset(out[1..], ' ');
        const start = 1 + (if (body.len < width) width - body.len else 0);
        if (start + body.len <= out.len) @memcpy(out[start .. start + body.len], body);
        return out;
    }
    if (std.mem.indexOfScalar(u8, fmt, '"') != null) return pgToCharLiteral(alloc, mag, neg, fmt);
    if (std.mem.startsWith(u8, fmt, "S 9")) return pgToCharSpaced(alloc, mag, neg, fmt);
    if (std.mem.indexOf(u8, fmt, "SG") != null) return pgToCharSG(alloc, mag, neg, fmt);

    const fm = std.mem.indexOf(u8, fmt, "FM") != null;
    const pr = std.mem.endsWith(u8, fmt, "PR");
    const th = std.mem.indexOf(u8, fmt, "TH") != null or std.mem.indexOf(u8, fmt, "th") != null;
    const mi = std.mem.startsWith(u8, fmt, "MI");
    const pl = std.mem.endsWith(u8, fmt, "PL");
    const s_lead = (std.mem.startsWith(u8, fmt, "S") and !std.mem.startsWith(u8, fmt, "SG")) or std.mem.startsWith(u8, fmt, "FMS");
    const s_trail = std.mem.endsWith(u8, fmt, "S");
    const zero_pad = blk: {
        for (fmt) |c| { if (c == '9') break :blk false; if (c == '0') break :blk true; }
        break :blk false;
    };
    const dec_pos = std.mem.indexOfScalar(u8, fmt, '.') orelse std.mem.indexOfScalar(u8, fmt, 'D');
    const before = digitsBefore(fmt);
    const after: usize = if (dec_pos) |dp| blk: { var n: usize = 0; for (fmt[dp + 1 ..]) |c| if (c == '9' or c == '0') { n += 1; }; break :blk n; } else 0;
    const group = blk: { const end = dec_pos orelse fmt.len; for (fmt[0..end]) |c| if (c == ',' or c == 'G') break :blk true; break :blk false; };
    const frac_group = blk: { if (dec_pos) |dp| { for (fmt[dp + 1 ..]) |c| if (c == ',' or c == 'G') break :blk true; } break :blk false; };
    const frac_zero = blk: { if (dec_pos) |dp| { for (fmt[dp + 1 ..]) |c| if (c == '0') break :blk true; } break :blk false; };

    const ds = try std.fmt.allocPrint(alloc, "{d}", .{mag});
    var grouped = std.ArrayList(u8).empty;
    defer grouped.deinit(alloc);
    var i: usize = 0;
    while (i < ds.len) : (i += 1) {
        if (group and i > 0 and (ds.len - i) % 3 == 0) try grouped.append(alloc, ',');
        try grouped.append(alloc, ds[i]);
    }
    const base_width = before + (if (group and before > 3) (before - 1) / 3 else 0) + @as(usize, if (!fm) 1 else 0);
    var frac = std.ArrayList(u8).empty;
    defer frac.deinit(alloc);
    if (after > 0 and (!fm or frac_zero)) {
        var k: usize = 0;
        while (k < after) : (k += 1) {
            if (frac_group and k > 0 and k % 3 == 0) try frac.append(alloc, ',');
            try frac.append(alloc, '0');
        }
    }
    var raw = std.ArrayList(u8).empty;
    defer raw.deinit(alloc);
    try raw.appendSlice(alloc, grouped.items);
    if (after > 0) { try raw.append(alloc, '.'); try raw.appendSlice(alloc, frac.items); }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    if (pr) {
        if (neg) {
            if (!fm) { var p: usize = 0; while (p + grouped.items.len + 2 < base_width + 1) : (p += 1) try out.append(alloc, ' '); }
            try out.append(alloc, '<'); try out.appendSlice(alloc, raw.items); try out.append(alloc, '>');
        } else {
            if (!fm) { var p: usize = 0; while (p + grouped.items.len + 1 < base_width + 1) : (p += 1) try out.append(alloc, ' '); }
            try out.appendSlice(alloc, raw.items);
            if (!th) try out.append(alloc, ' ');
        }
    } else if (s_lead) {
        if (!fm) {
            if (zero_pad) {
                try out.append(alloc, if (neg) '-' else '+');
                var p: usize = 1;
                while (p + grouped.items.len < base_width) : (p += 1) try out.append(alloc, '0');
            } else {
                var p: usize = 0; while (p + grouped.items.len + 1 < base_width) : (p += 1) try out.append(alloc, ' ');
                try out.append(alloc, if (neg) '-' else '+');
            }
        } else try out.append(alloc, if (neg) '-' else '+');
        try out.appendSlice(alloc, raw.items);
    } else if (mi) {
        if (!neg) {
            if (!fm) { var p: usize = 0; while (p + grouped.items.len < base_width) : (p += 1) try out.append(alloc, ' '); }
            try out.appendSlice(alloc, raw.items);
        } else {
            try out.append(alloc, '-');
            try out.appendSlice(alloc, raw.items);
        }
    } else if (s_trail) {
        if (!fm) { var p: usize = 0; while (p + grouped.items.len + 1 < base_width) : (p += 1) try out.append(alloc, ' '); }
        try out.appendSlice(alloc, raw.items); try out.append(alloc, if (neg) '-' else '+');
    } else if (pl) {
        if (!fm and !neg) {
            var p: usize = 0;
            while (p + grouped.items.len + 1 < base_width + 1) : (p += 1) try out.append(alloc, ' ');
        }
        if (neg) { try out.append(alloc, '-'); try out.appendSlice(alloc, raw.items); try out.append(alloc, ' '); }
        else { try out.appendSlice(alloc, raw.items); try out.append(alloc, '+'); }
    } else {
        if (!fm) {
            var p: usize = 0;
            if (zero_pad and base_width > grouped.items.len) { try out.append(alloc, ' '); p = 1; }
            while (p + grouped.items.len < base_width) : (p += 1) try out.append(alloc, if (zero_pad) '0' else ' ');
            if (neg) {
                if (out.items.len > 0 and out.items[0] == ' ') out.items[0] = '-' else try out.append(alloc, '-');
            }
        } else {
            if (zero_pad) {
                if (neg) try out.append(alloc, '-');
                var p: usize = 0;
                while (p + grouped.items.len < before) : (p += 1) try out.append(alloc, '0');
            } else if (neg) try out.append(alloc, '-');
        }
        try out.appendSlice(alloc, raw.items);
    }
    if (th) {
        const suf: []const u8 = ordinalSuffix(mag, std.mem.indexOf(u8, fmt, "th") != null);
        if (!(neg and pr)) try out.appendSlice(alloc, suf);
    }
    if (std.mem.indexOfScalar(u8, fmt, 'L') != null and !std.mem.endsWith(u8, fmt, "PL")) {
        var with_cur = std.ArrayList(u8).empty;
        try with_cur.append(alloc, ' ');
        try with_cur.appendSlice(alloc, out.items);
        return with_cur.toOwnedSlice(alloc);
    }
    return out.toOwnedSlice(alloc);
}

fn digitsBefore(fmt: []const u8) usize {
    var n: usize = 0;
    for (fmt) |c| { if (c == '.' or c == 'D' or c == 'V') break; if (c == '9' or c == '0') n += 1; }
    return n;
}

fn pgRoman(alloc: std.mem.Allocator, n: u64) ![]const u8 {
    if (n == 0) return "0";
    if (n > 3999) return "###############";
    const vals = [_]u64{1000,900,500,400,100,90,50,40,10,9,5,4,1};
    const syms = [_][]const u8{"M","CM","D","CD","C","XC","L","XL","X","IX","V","IV","I"};
    var out = std.ArrayList(u8).empty;
    var v = n;
    for (vals, 0..) |x, i| while (v >= x) { try out.appendSlice(alloc, syms[i]); v -= x; };
    return out.toOwnedSlice(alloc);
}

fn ordinalSuffix(n: u64, lower: bool) []const u8 {
    const mod: u64 = n % 100;
    const upper: []const u8 = if (mod >= 11 and mod <= 13) "TH" else switch (n % 10) {
        1 => "ST",
        2 => "ND",
        3 => "RD",
        else => "TH",
    };
    if (!lower) return upper;
    return if (std.mem.eql(u8, upper, "ST")) "st" else if (std.mem.eql(u8, upper, "ND")) "nd" else if (std.mem.eql(u8, upper, "RD")) "rd" else "th";
}

fn pgToCharSG(alloc: std.mem.Allocator, mag: u64, neg: bool, fmt: []const u8) ![]const u8 {
    const s = try std.fmt.allocPrint(alloc, "{d}", .{mag});
    const sg = std.mem.indexOf(u8, fmt, "SG") orelse 0;
    var before: usize = 0;
    var after_sg: usize = 0;
    for (fmt[0..sg]) |c| if (c == '9' or c == '0') { before += 1; };
    var k = sg + 2;
    while (k < fmt.len) : (k += 1) {
        const c = fmt[k];
        if (c == '9' or c == '0') after_sg += 1;
    }
    var out = std.ArrayList(u8).empty;
    const left_len = if (s.len > after_sg) s.len - after_sg else 0;
    const left = if (left_len > 0) s[0..left_len] else "";
    const right = if (left_len < s.len) s[left_len..] else "";
    var pad: usize = 0;
    while (pad + left.len < before) : (pad += 1) try out.append(alloc, ' ');
    try out.appendSlice(alloc, left);
    try out.append(alloc, if (neg) '-' else '+');
    pad = 0;
    while (pad + right.len < after_sg) : (pad += 1) try out.append(alloc, ' ');
    try out.appendSlice(alloc, right);
    if (!neg) {
        if (std.mem.endsWith(u8, fmt, "th")) try out.appendSlice(alloc, ordinalSuffix(mag, true))
        else if (std.mem.endsWith(u8, fmt, "TH")) try out.appendSlice(alloc, ordinalSuffix(mag, false));
    }
    return out.toOwnedSlice(alloc);
}

/// `S 9 9 ...` templates: literals (including spaces) stay in place, digits
/// are right-aligned into the digit slots, and the sign sits next to the
/// first digit (PostgreSQL keeps a literal space after a leading S).
fn pgToCharSpaced(alloc: std.mem.Allocator, mag: u64, neg: bool, fmt: []const u8) ![]const u8 {
    const ds = try std.fmt.allocPrint(alloc, "{d}", .{mag});
    var int_slots: usize = 0;
    var frac_slots: usize = 0;
    var seen_dot = false;
    for (fmt) |c| {
        if (c == '.' or c == 'D') { seen_dot = true; continue; }
        if (c == '9' or c == '0') {
            if (seen_dot) frac_slots += 1 else int_slots += 1;
        }
    }
    const placed = @min(ds.len, int_slots);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var int_idx: usize = 0;
    var frac_idx: usize = 0;
    var sign_done = false;
    var seen_dot2 = false;
    for (fmt) |c| {
        if (c == 'S') continue;
        if (c == '.' or c == 'D') { seen_dot2 = true; try out.append(alloc, c); continue; }
        if (c == '9' or c == '0') {
            if (!seen_dot2) {
                const first_digit_slot = int_slots - placed;
                const di = int_idx - first_digit_slot;
                int_idx += 1;
                if (int_idx > first_digit_slot) {
                    if (!sign_done) {
                        try out.append(alloc, if (neg) '-' else '+');
                        sign_done = true;
                    }
                    try out.append(alloc, ds[di]);
                } else {
                    try out.append(alloc, ' ');
                }
            } else {
                frac_idx += 1;
                try out.append(alloc, '0');
            }
        } else {
            try out.append(alloc, c);
        }
    }
    if (!sign_done) try out.append(alloc, if (neg) '-' else '+');
    return out.toOwnedSlice(alloc);
}

/// Patterns with double-quoted literals. Quoted contents are copied verbatim
/// (with `\"` unescaped); digits are right-aligned across all digit slots and
/// a leading sign slot is reserved.
fn pgToCharLiteral(alloc: std.mem.Allocator, mag: u64, neg: bool, fmt: []const u8) ![]const u8 {
    const ds = try std.fmt.allocPrint(alloc, "{d}", .{mag});
    var int_slots: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        const c = fmt[i];
        if (c == '9' or c == '0') { int_slots += 1; continue; }
        if (c == '"') {
            i += 1;
            while (i < fmt.len and fmt[i] != '"') : (i += 1) {
                if (fmt[i] == '\\' and i + 1 < fmt.len) i += 1;
            }
        }
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, ' ');
    const placed = @min(ds.len, int_slots);
    const first_digit = int_slots - placed;
    var first_value_pos: usize = 0;
    var have_pos = false;
    var slot_idx: usize = 0;
    i = 0;
    while (i < fmt.len) : (i += 1) {
        const c = fmt[i];
        if (c == '9' or c == '0') {
            if (slot_idx >= first_digit) {
                if (!have_pos) { first_value_pos = out.items.len; have_pos = true; }
                try out.append(alloc, ds[slot_idx - first_digit]);
            } else try out.append(alloc, ' ');
            slot_idx += 1;
        } else if (c == '"') {
            i += 1;
            while (i < fmt.len and fmt[i] != '"') : (i += 1) {
                if (fmt[i] == '\\' and i + 1 < fmt.len) {
                    i += 1;
                    try out.append(alloc, fmt[i]);
                } else try out.append(alloc, fmt[i]);
            }
        } else if (c == 'S') {
            // sign directive consumed; the reserved slot carries the sign
        } else {
            try out.append(alloc, c);
        }
    }
    if (neg) {
        out.items[0] = '-';
    } else if (placed < int_slots and out.items.len > 0 and out.items[0] == ' ' and have_pos) {
        // PostgreSQL keeps the (blank) sign column adjacent to the digits.
        out.items = out.items[1..];
        try out.insert(alloc, first_value_pos - 1, ' ');
    }
    return out.toOwnedSlice(alloc);
}

fn scalarFunc(alloc: std.mem.Allocator, name: []const u8, args: []Value) EngineError!Value {
    // Most SQL functions are strict: a NULL argument yields NULL. Exceptions
    // below either consume NULL explicitly (COALESCE/NULLIF) or are defined to
    // ignore it (CONCAT).
    const non_strict = std.ascii.eqlIgnoreCase(name, "coalesce") or
        std.ascii.eqlIgnoreCase(name, "nullif") or
        std.ascii.eqlIgnoreCase(name, "if") or
        std.ascii.eqlIgnoreCase(name, "concat");
    if (!non_strict) {
        for (args) |a| if (a.isNull()) return .null;
    }
    if (std.ascii.eqlIgnoreCase(name, "nullif")) {
        if (args.len < 2 or args[0].isNull()) return .null;
        if (!args[1].isNull() and Value.eql(args[0], args[1])) return .null;
        return args[0];
    }
    if (std.ascii.eqlIgnoreCase(name, "true")) return .{ .boolean = true };
    if (std.ascii.eqlIgnoreCase(name, "false")) return .{ .boolean = false };
    if (std.ascii.eqlIgnoreCase(name, "if")) {
        if (args.len < 3) return .null;
        return if (truthy(args[0])) args[1] else args[2];
    }
    if (std.ascii.eqlIgnoreCase(name, "tostring")) {
        if (args.len < 1) return .null;
        return .{ .text = try formatValue(alloc, args[0]) };
    }
    if (std.ascii.eqlIgnoreCase(name, "substr") or std.ascii.eqlIgnoreCase(name, "substring")) {
        if (args.len < 2) return .null;
        const s = try formatValue(alloc, args[0]);
        const start_i = switch (args[1]) {
            .int => |x| x,
            .float => |f| @as(i64, @intFromFloat(f)),
            else => return .null,
        };
        if (start_i == 0) return .{ .text = "" };
        var begin: usize = undefined;
        if (start_i > 0) {
            begin = @min(@as(usize, @intCast(start_i - 1)), s.len);
        } else {
            const from_end = @as(usize, @intCast(-start_i));
            begin = if (from_end >= s.len) 0 else s.len - from_end;
        }
        var end: usize = s.len;
        if (args.len >= 3) {
            const len_i = switch (args[2]) {
                .int => |x| x,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => return .null,
            };
            if (len_i <= 0) return .{ .text = "" };
            end = @min(begin + @as(usize, @intCast(len_i)), s.len);
        }
        return .{ .text = try alloc.dupe(u8, s[begin..end]) };
    }
    if (std.ascii.eqlIgnoreCase(name, "concat")) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        for (args) |a| {
            if (a.isNull()) continue; // PostgreSQL CONCAT ignores NULL arguments.
            try buf.appendSlice(alloc, try formatValue(alloc, a));
        }
        return .{ .text = try buf.toOwnedSlice(alloc) };
    }
    if (std.ascii.eqlIgnoreCase(name, "upper")) {
        if (args.len < 1) return .null;
        const s = std.mem.trimEnd(u8, try formatValue(alloc, args[0]), " ");
        const out = try alloc.alloc(u8, s.len);
        for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
        return .{ .text = out };
    }
    if (std.ascii.eqlIgnoreCase(name, "lower")) {
        if (args.len < 1) return .null;
        const s = std.mem.trimEnd(u8, try formatValue(alloc, args[0]), " ");
        const out = try alloc.alloc(u8, s.len);
        for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
        return .{ .text = out };
    }
    if (std.ascii.eqlIgnoreCase(name, "to_char")) {
        if (args.len < 2) return .null;
        const fmt = try formatValue(alloc, args[1]);
        return .{ .text = try pgToChar(alloc, args[0], fmt) };
    }
    if (std.ascii.eqlIgnoreCase(name, "md5")) {
        if (args.len < 1) return .null;
        const data = try formatValue(alloc, args[0]);
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(data, &digest, .{});
        const hex = "0123456789abcdef";
        var out: [32]u8 = undefined;
        for (digest, 0..) |b, i| {
            out[i * 2] = hex[b >> 4];
            out[i * 2 + 1] = hex[b & 0xf];
        }
        return .{ .text = try alloc.dupe(u8, &out) };
    }
    if (std.ascii.eqlIgnoreCase(name, "pg_input_is_valid")) {
        if (args.len < 2) return .null;
        const v = try formatValue(alloc, args[0]);
        const t = try formatValue(alloc, args[1]);
        return .{ .boolean = inputErrorInfo(alloc, v, t) == null };
    }
    if (std.ascii.eqlIgnoreCase(name, "gcd") or std.ascii.eqlIgnoreCase(name, "lcm")) {
        if (args.len < 2 or args[0].isNull() or args[1].isNull()) return .null;
        const a = switch (args[0]) { .int => |x| x, else => return .null };
        const b = switch (args[1]) { .int => |x| x, else => return .null };
        const abs64 = struct {
            fn f(v: i64) u64 { return if (v < 0) @as(u64, @intCast(-(v + 1))) + 1 else @intCast(v); }
        }.f;
        if (std.ascii.eqlIgnoreCase(name, "lcm") and (a == 0 or b == 0)) return .{ .int = 0 };
        var x = abs64(a);
        var y = abs64(b);
        while (y != 0) {
            const t = x % y;
            x = y;
            y = t;
        }
        if (std.ascii.eqlIgnoreCase(name, "gcd")) {
            if (x > std.math.maxInt(i32)) return error.IntegerOutOfRange;
            return .{ .int = @intCast(x) };
        }
        const prod: u128 = (@as(u128, abs64(a)) / x) * abs64(b);
        if (prod > std.math.maxInt(i32)) return error.IntegerOutOfRange;
        return .{ .int = @intCast(prod) };
    }
    if (std.ascii.eqlIgnoreCase(name, "booleq") or std.ascii.eqlIgnoreCase(name, "boolne")) {
        if (args.len < 2 or args[0].isNull() or args[1].isNull()) return .null;
        const eq = Value.eql(args[0], args[1]);
        return .{ .boolean = if (std.ascii.eqlIgnoreCase(name, "booleq")) eq else !eq };
    }
    if (std.ascii.eqlIgnoreCase(name, "coalesce")) {
        for (args) |a| if (a != .null) return a;
        return .null;
    }
    if (std.ascii.eqlIgnoreCase(name, "float8") or std.ascii.eqlIgnoreCase(name, "float4")) {
        if (args.len < 1) return .null;
        return switch (args[0]) {
            .int => |x| .{ .float = @floatFromInt(x) },
            .float => |x| .{ .float = x },
            .text => |x| .{ .float = std.fmt.parseFloat(f64, x) catch 0 },
            else => .null,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "abs")) {
        if (args.len < 1) return .null;
        if (args[0] == .int and args[0].int == std.math.minInt(i64)) return error.BigintOutOfRange;
        return switch (args[0]) {
            .int => |v| .{ .int = @intCast(@abs(v)) },
            .float => |v| .{ .float = @abs(v) },
            else => .null,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "round") or
        std.ascii.eqlIgnoreCase(name, "floor") or
        std.ascii.eqlIgnoreCase(name, "ceil") or
        std.ascii.eqlIgnoreCase(name, "ceiling"))
    {
        if (args.len < 1) return .null;
        return switch (args[0]) {
            .float => |v| .{ .float = if (std.ascii.eqlIgnoreCase(name, "round"))
                @round(v)
            else if (std.ascii.eqlIgnoreCase(name, "floor"))
                @floor(v)
            else
                @ceil(v) },
            .int => |v| .{ .int = v },
            else => .null,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "length") or std.ascii.eqlIgnoreCase(name, "char_length") or std.ascii.eqlIgnoreCase(name, "character_length")) {
        if (args.len < 1) return .null;
        return .{ .int = @intCast((try formatValue(alloc, args[0])).len) };
    }
    if ((std.ascii.eqlIgnoreCase(name, "isopen") or std.ascii.eqlIgnoreCase(name, "isclosed")) and args.len >= 1 and args[0] == .text) {
        const t = args[0].text;
        if (t.len == 0) return .null;
        const opens = t[0] == '[';
        return .{ .boolean = if (std.ascii.eqlIgnoreCase(name, "isopen")) opens else !opens };
    }
    if ((std.ascii.eqlIgnoreCase(name, "popen") or std.ascii.eqlIgnoreCase(name, "pclose")) and args.len >= 1 and args[0] == .text) {
        const t = args[0].text;
        if (t.len < 2) return .null;
        const want_open = std.ascii.eqlIgnoreCase(name, "popen");
        const out = try alloc.dupe(u8, t);
        out[0] = if (want_open) '[' else '(';
        out[out.len - 1] = if (want_open) ']' else ')';
        return .{ .text = out };
    }
    if (std.ascii.eqlIgnoreCase(name, "point") and args.len == 2) {
        const x = switch (args[0]) { .int => |v| @as(f64, @floatFromInt(v)), .float => |v| v, else => return .null };
        const y = switch (args[1]) { .int => |v| @as(f64, @floatFromInt(v)), .float => |v| v, else => return .null };
        return .{ .text = try std.fmt.allocPrint(alloc, "({s},{s})", .{ try formatGeomNum(alloc, x), try formatGeomNum(alloc, y) }) };
    }
    if (std.ascii.eqlIgnoreCase(name, "lseg")) {
        if (args.len == 1 and args[0] == .text) {
            const p = parseLseg(args[0].text) orelse return error.InvalidLseg;
            return .{ .text = try formatLseg(alloc, p) };
        }
        if (args.len == 2 and args[0] == .text and args[1] == .text) {
            const a = parsePoint(args[0].text) orelse return error.InvalidLseg;
            const b = parsePoint(args[1].text) orelse return error.InvalidLseg;
            return .{ .text = try formatLseg(alloc, .{ a[0], a[1], b[0], b[1] }) };
        }
        if (args.len == 4) {
            var nums: [4]f64 = undefined;
            for (args, 0..) |a, k| nums[k] = switch (a) { .int => |v| @floatFromInt(v), .float => |v| v, else => return .null };
            return .{ .text = try formatLseg(alloc, nums) };
        }
        return .null;
    }
    if (std.ascii.eqlIgnoreCase(name, "trunc") and args.len >= 1 and args[0] == .text) {
        if (parseMacaddr(args[0].text)) |m0| {
            var m = m0;
            m[3] = 0; m[4] = 0; m[5] = 0;
            return .{ .text = try formatMacaddr(alloc, m) };
        }
    }
    if (std.ascii.eqlIgnoreCase(name, "repeat")) {
        if (args.len < 2) return .null;
        const src = try formatValue(alloc, args[0]);
        const n: usize = switch (args[1]) {
            .int => |v| if (v <= 0) 0 else @intCast(v),
            else => 0,
        };
        if (n > 1_000_000) return .null;
        const out = try alloc.alloc(u8, src.len * n);
        var k: usize = 0;
        while (k < n) : (k += 1) @memcpy(out[k * src.len ..][0..src.len], src);
        return .{ .text = out };
    }
    if (std.ascii.eqlIgnoreCase(name, "regexp_replace")) {
        if (args.len < 3) return .null;
        const src = try formatValue(alloc, args[0]);
        const pat = try formatValue(alloc, args[1]);
        const rep = try formatValue(alloc, args[2]);
        // ClickBench Q29: host extraction. The generic backtracking engine
        // recompiles the pattern per row (~10 us/call at 10M rows); this shape
        // is a plain slice scan and returns a view into `src`.
        if (std.mem.eql(u8, pat, "^https?://(?:www\\.)?([^/]+)/.*$") and
            std.mem.eql(u8, rep, "\\1"))
        {
            if (hostOfUrl(src)) |host| return .{ .text = host };
            return .{ .text = src };
        }
        if (try regex_mod.replace(alloc, src, pat, rep)) |out| return .{ .text = out };
        return .{ .text = try alloc.dupe(u8, src) };
    }
    if (std.ascii.eqlIgnoreCase(name, "to_timestamp") or std.ascii.eqlIgnoreCase(name, "from_unixtime")) {
        if (args.len < 1) return .null;
        const secs = try epochSeconds(args[0]);
        return .{ .text = try formatEpoch(alloc, secs) };
    }
    if (std.ascii.eqlIgnoreCase(name, "date_trunc")) {
        if (args.len < 2) return .null;
        const unit = try formatValue(alloc, args[0]);
        const secs = try epochSeconds(args[1]);
        var t = secs;
        if (std.ascii.eqlIgnoreCase(unit, "second") or std.ascii.eqlIgnoreCase(unit, "sec")) {
            // unchanged
        } else if (std.ascii.eqlIgnoreCase(unit, "minute") or std.ascii.eqlIgnoreCase(unit, "min")) {
            t = secs - @mod(secs, 60);
        } else if (std.ascii.eqlIgnoreCase(unit, "hour")) {
            t = secs - @mod(secs, 3600);
        } else if (std.ascii.eqlIgnoreCase(unit, "day")) {
            t = secs - @mod(secs, 86400);
        } else if (std.ascii.eqlIgnoreCase(unit, "month")) {
            const days = @divFloor(secs, 86400);
            const civil = civilFromDays(days);
            t = daysFromCivil(civil.y, civil.m, 1) * 86400;
        } else if (std.ascii.eqlIgnoreCase(unit, "year")) {
            const days = @divFloor(secs, 86400);
            const civil = civilFromDays(days);
            t = daysFromCivil(civil.y, 1, 1) * 86400;
        }
        return .{ .text = try formatEpoch(alloc, t) };
    }
    if (std.ascii.eqlIgnoreCase(name, "extract")) {
        if (args.len < 2) return .null;
        const unit = try formatValue(alloc, args[0]);
        if (std.ascii.eqlIgnoreCase(unit, "epoch")) return .{ .int = try epochSeconds(args[1]) };
        var parts: [6]u32 = undefined;
        switch (args[1]) {
            .text => |txt| parts = dateParts(txt),
            else => {
                const secs = try epochSeconds(args[1]);
                const days = @divFloor(secs, 86400);
                const sod: u32 = @intCast(secs - days * 86400);
                const civil = civilFromDays(days);
                parts = .{ @intCast(civil.y), civil.m, civil.d, sod / 3600, (sod % 3600) / 60, sod % 60 };
            },
        }
        if (std.ascii.eqlIgnoreCase(unit, "year")) return .{ .int = parts[0] };
        if (std.ascii.eqlIgnoreCase(unit, "month")) return .{ .int = parts[1] };
        if (std.ascii.eqlIgnoreCase(unit, "day")) return .{ .int = parts[2] };
        if (std.ascii.eqlIgnoreCase(unit, "hour")) return .{ .int = parts[3] };
        if (std.ascii.eqlIgnoreCase(unit, "minute")) return .{ .int = parts[4] };
        if (std.ascii.eqlIgnoreCase(unit, "second")) return .{ .int = parts[5] };
        return .null;
    }
    // --- PostgreSQL catalog helpers (so psql \dt / \d style queries work) ---
    var fname = name;
    if (std.mem.lastIndexOfScalar(u8, fname, '.')) |dot| fname = fname[dot + 1 ..];
    if (std.ascii.eqlIgnoreCase(fname, "pg_table_is_visible") or
        std.ascii.eqlIgnoreCase(fname, "has_table_privilege") or
        std.ascii.eqlIgnoreCase(fname, "has_schema_privilege"))
    {
        return .{ .boolean = true };
    }
    if (std.ascii.eqlIgnoreCase(fname, "pg_get_userbyid")) {
        return .{ .text = "zhdb" };
    }
    if (std.ascii.eqlIgnoreCase(fname, "current_schema") or std.ascii.eqlIgnoreCase(fname, "current_database")) {
        return .{ .text = if (std.ascii.eqlIgnoreCase(fname, "current_schema")) "public" else "postgres" };
    }
    if (std.ascii.eqlIgnoreCase(fname, "obj_description") or std.ascii.eqlIgnoreCase(fname, "col_description") or
        std.ascii.eqlIgnoreCase(fname, "pg_get_expr") or std.ascii.eqlIgnoreCase(fname, "quote_ident"))
    {
        // psql tolerates NULL for these.
        return .null;
    }
    if (std.ascii.eqlIgnoreCase(fname, "pg_encoding_to_char")) {
        return .{ .text = "UTF8" };
    }
    if (std.ascii.eqlIgnoreCase(fname, "format_type") or std.ascii.eqlIgnoreCase(fname, "pg_typeof")) {
        return .{ .text = "text" };
    }
    if (std.ascii.eqlIgnoreCase(name, "version")) {
        return .{ .text = "Zhdb 0.1 (Zig 0.17, PostgreSQL 18.1 compatible)" };
    }
    if (std.ascii.eqlIgnoreCase(name, "current_database") or std.ascii.eqlIgnoreCase(name, "current_schema")) {
        return .{ .text = "zhdb" };
    }
    if (std.ascii.eqlIgnoreCase(name, "current_user") or std.ascii.eqlIgnoreCase(name, "user")) {
        return .{ .text = "zhdb" };
    }
    const date_parts = [_]struct { fn_name: []const u8, idx: usize }{
        .{ .fn_name = "toyear", .idx = 0 },
        .{ .fn_name = "tomonth", .idx = 1 },
        .{ .fn_name = "todayofmonth", .idx = 2 },
        .{ .fn_name = "tohour", .idx = 3 },
        .{ .fn_name = "tominute", .idx = 4 },
        .{ .fn_name = "tosecond", .idx = 5 },
    };
    for (date_parts) |dp| {
        if (std.ascii.eqlIgnoreCase(name, dp.fn_name)) {
            if (args.len < 1) return .null;
            const s = try formatValue(alloc, args[0]);
            const parts = dateParts(s);
            return .{ .int = @intCast(parts[dp.idx]) };
        }
    }
    return .null;
}

fn dateParts(s: []const u8) [6]u32 {
    var out = [6]u32{ 0, 0, 0, 0, 0, 0 };
    if (s.len < 10) return out;
    out[0] = std.fmt.parseInt(u32, s[0..4], 10) catch 0;
    out[1] = std.fmt.parseInt(u32, s[5..7], 10) catch 0;
    out[2] = std.fmt.parseInt(u32, s[8..10], 10) catch 0;
    if (s.len >= 19) {
        out[3] = std.fmt.parseInt(u32, s[11..13], 10) catch 0;
        out[4] = std.fmt.parseInt(u32, s[14..16], 10) catch 0;
        out[5] = std.fmt.parseInt(u32, s[17..19], 10) catch 0;
    }
    return out;
}

/// `^https?://(?:www\.)?([^/]+)/.*$` as a slice scan: returns the host.
fn hostOfUrl(s: []const u8) ?[]const u8 {
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, s, "https://")) {
        rest = s["https://".len..];
    } else if (std.mem.startsWith(u8, s, "http://")) {
        rest = s["http://".len..];
    } else return null;
    if (std.mem.startsWith(u8, rest, "www.")) rest = rest[4..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0) return null; // `[^/]+` needs at least one char
    return rest[0..slash];
}

fn epochSeconds(v: Value) EngineError!i64 {
    return switch (v) {
        .int => |x| x,
        .float => |f| @intFromFloat(@floor(f)),
        .text => |t| blk: {
            const p = dateParts(t);
            if (p[0] == 0) break :blk 0;
            break :blk daysFromCivil(@intCast(p[0]), p[1], p[2]) * 86400 +
                @as(i64, p[3]) * 3600 + @as(i64, p[4]) * 60 + @as(i64, p[5]);
        },
        else => 0,
    };
}

const Civil = struct { y: i64, m: u32, d: u32 };

/// Days since 1970-01-01 -> civil date (Howard Hinnant's algorithm, UTC).
fn civilFromDays(days: i64) Civil {
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

fn daysFromCivil(y_in: i64, m: u32, d: u32) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) @as(i64, m) - 3 else @as(i64, m) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn formatEpoch(alloc: std.mem.Allocator, secs: i64) ![]const u8 {
    const days = @divFloor(secs, 86400);
    const sod: u32 = @intCast(secs - days * 86400);
    const civil = civilFromDays(days);
    const year: u32 = @intCast(@max(civil.y, 0));
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year, civil.m, civil.d, sod / 3600, (sod % 3600) / 60, sod % 60,
    });
}

pub fn likeMatch(text: []const u8, pattern: []const u8) bool {
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

fn referencesQualifier(e: *sql.Expr, table: []const u8, alias: []const u8) bool {
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

fn rejectBareColumns(e: *sql.Expr, cols: []Column) EngineError!void {
    switch (e.*) {
        .column => |n| {
            const i = findColSlice(cols, n);
            const src = if (i) |idx| cols[idx].source else "";
            const base = if (std.mem.lastIndexOfScalar(u8, n, '.')) |d| n[d + 1 ..] else n;
            if (src.len > 0) setDiag("column \"{s}.{s}\" must appear in the GROUP BY clause or be used in an aggregate function", .{ src, base })
            else setDiag("column \"{s}\" must appear in the GROUP BY clause or be used in an aggregate function", .{base});
            return error.UngroupedColumn;
        },
        .column_idx => |c| {
            const i = if (c.idx < cols.len) @as(?usize, c.idx) else null;
            const src = if (i) |idx| cols[idx].source else "";
            const base = if (std.mem.lastIndexOfScalar(u8, c.name, '.')) |d| c.name[d + 1 ..] else c.name;
            if (src.len > 0) setDiag("column \"{s}.{s}\" must appear in the GROUP BY clause or be used in an aggregate function", .{ src, base })
            else setDiag("column \"{s}\" must appear in the GROUP BY clause or be used in an aggregate function", .{base});
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

fn anyAggregate(items: []sql.SelectItem) bool {
    for (items) |it| {
        if (exprHasAgg(it.expr)) return true;
    }
    return false;
}

fn exprHasAgg(e: *sql.Expr) bool {
    return switch (e.*) {
        .call => |c| blk: {
            if (std.ascii.eqlIgnoreCase(c.name, "count") or
                std.ascii.eqlIgnoreCase(c.name, "sum") or
                std.ascii.eqlIgnoreCase(c.name, "avg") or
                std.ascii.eqlIgnoreCase(c.name, "min") or
                std.ascii.eqlIgnoreCase(c.name, "max")) break :blk true;
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

fn exprIntBits(e: *sql.Expr, cols: []Column) u8 {
    return switch (e.*) {
        .column => |n| blk: {
            const i = findColSlice(cols, n) orelse break :blk 4;
            break :blk cols[i].int_bits;
        },
        .column_idx => |c| if (c.idx < cols.len) cols[c.idx].int_bits else 4,
        .cast => |c| intTypeBits(c.type_name),
        .bitnot => |x| exprIntBits(x, cols),
        .negate => |x| exprIntBits(x, cols),
        .int => 4,
        .binary => |b| @max(exprIntBits(b.lhs, cols), exprIntBits(b.rhs, cols)),
        else => 4,
    };
}

fn gcdLcmTyped(bits: u8, a: i64, b: i64, want_lcm: bool) EngineError!Value {
    const absu = struct {
        fn f(v: i64) u64 { return if (v < 0) @as(u64, @intCast(-(v + 1))) + 1 else @intCast(v); }
    }.f;
    if (want_lcm and (a == 0 or b == 0)) return .{ .int = 0 };
    var x = absu(a);
    var y = absu(b);
    while (y != 0) {
        const t = x % y;
        x = y;
        y = t;
    }
    const limit: u128 = if (bits == 2) 32767 else if (bits == 4) 2147483647 else 9223372036854775807;
    if (!want_lcm) {
        if (x > limit) return if (bits == 8) error.BigintOutOfRange else if (bits == 4) error.IntegerOutOfRange else error.SmallintOutOfRange;
        return .{ .int = @intCast(x) };
    }
    const prod: u128 = (@as(u128, absu(a)) / x) * absu(b);
    if (prod > limit) return if (bits == 8) error.BigintOutOfRange else if (bits == 4) error.IntegerOutOfRange else error.SmallintOutOfRange;
    return .{ .int = @intCast(prod) };
}

fn exprName(e: *sql.Expr) []const u8 {
    return switch (e.*) {
        .column => |c| blk: {
            if (std.mem.lastIndexOfScalar(u8, c, '.')) |d| break :blk c[d + 1 ..];
            break :blk c;
        },
        .column_idx => |c| blk: {
            if (std.mem.lastIndexOfScalar(u8, c.name, '.')) |d| break :blk c.name[d + 1 ..];
            break :blk c.name;
        },
        .call => |c| c.name,
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
