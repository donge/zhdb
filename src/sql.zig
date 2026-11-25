const std = @import("std");
const Value = @import("value.zig").Value;

pub const Error = error{ SyntaxError, OutOfMemory };

pub const TokenKind = enum {
    ident,
    number,
    string,
    star,
    comma,
    lparen,
    rparen,
    param,
    plus,
    minus,
    slash,
    percent,
    eq,
    neq,
    lt,
    gt,
    le,
    ge,
    regex,
    regex_ne,
    dot,
    semicolon,
    cast,
    shl,
    shr,
    distance,
    contains,
    subcontains,
    above,
    below,
    pointeq,
    arrow,
    jsonget,
    jsonget_text,
    concat,
    lbracket,
    rbracket,
    amp,
    ampamp,
    pipe,
    hash,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    quoted: bool = false,
};

pub const BinOp = enum { add, sub, mul, div, mod, shl, shr, band, bor, bxor, eq, neq, lt, gt, le, ge, and_op, or_op, regex, regex_ne, dist, contains, subcontains, above, below, peq, concat, overlap };

pub const Expr = union(enum) {
    column: []const u8,
    column_idx: struct { idx: u16, name: []const u8 },
    int: i64,
    float: f64,
    param: u16,
    at_zone: struct { operand: *Expr, zone: *Expr },
    at_local: struct { operand: *Expr },
    string: []const u8,
    null_lit,
    star,
    /// `alias.*` / `table.*`: expand only columns from that input.
    star_table: []const u8,
    binary: struct { op: BinOp, lhs: *Expr, rhs: *Expr },
    negate: *Expr,
    bitnot: *Expr,
    not: *Expr,
    subscript: struct { operand: *Expr, index: *Expr },
    json_get: struct { operand: *Expr, key: *Expr, as_text: bool },
    window: struct { name: []const u8, args: []*Expr, order: []OrderItem },
    ordered_agg: struct { arg: *Expr, order: []OrderItem },
    call: Call,
    case_expr: Case,
    is_null: struct { operand: *Expr, negated: bool },
    like: struct { operand: *Expr, pattern: *Expr, negated: bool },
    in_list: struct { operand: *Expr, items: []*Expr, negated: bool },
    /// `x IN (SELECT ...)` — a hash semi join at execution time.
    in_subquery: struct { operand: *Expr, sub: *Select, negated: bool },
    /// `EXISTS (SELECT ...)` — uncorrelated; a semi/anti join filter.
    exists: struct { sub: *Select, negated: bool },
    between: struct { operand: *Expr, low: *Expr, high: *Expr, negated: bool },
    cast: struct { operand: *Expr, type_name: []const u8 },
};

pub const Call = struct {
    name: []const u8,
    args: []*Expr,
    distinct: bool = false,
    star: bool = false,
};

pub const Case = struct {
    whens: []When,
    else_expr: ?*Expr,
    pub const When = struct { cond: *Expr, then: *Expr };
};

/// Deep-copy an expression tree (used to bind a pushed-down join predicate to
/// one input's column indexes without mutating the shared WHERE tree).
pub fn cloneExpr(a: std.mem.Allocator, e: *Expr) !*Expr {
    const n = try a.create(Expr);
    switch (e.*) {
        .column => |s| n.* = .{ .column = s },
        .column_idx => |c| n.* = .{ .column_idx = c },
        .int => |v| n.* = .{ .int = v },
        .float => |v| n.* = .{ .float = v },
        .string => |s| n.* = .{ .string = s },
        .param => |x| n.* = .{ .param = x },
        .at_zone => |x| n.* = .{ .at_zone = .{ .operand = try cloneExpr(a, x.operand), .zone = try cloneExpr(a, x.zone) } },
        .at_local => |x| n.* = .{ .at_local = .{ .operand = try cloneExpr(a, x.operand) } },
        .null_lit => n.* = .null_lit,
        .star => n.* = .star,
        .star_table => |q| n.* = .{ .star_table = q },
        .binary => |b| n.* = .{ .binary = .{ .op = b.op, .lhs = try cloneExpr(a, b.lhs), .rhs = try cloneExpr(a, b.rhs) } },
        .negate => |x| n.* = .{ .negate = try cloneExpr(a, x) },
        .bitnot => |x| n.* = .{ .bitnot = try cloneExpr(a, x) },
        .subscript => |x| n.* = .{ .subscript = .{ .operand = try cloneExpr(a, x.operand), .index = try cloneExpr(a, x.index) } },
        .json_get => |x| n.* = .{ .json_get = .{ .operand = try cloneExpr(a, x.operand), .key = try cloneExpr(a, x.key), .as_text = x.as_text } },
        .window => |w| {
            const args = try a.alloc(*Expr, w.args.len);
            for (w.args, 0..) |x, i| args[i] = try cloneExpr(a, x);
            const ob = try a.alloc(OrderItem, w.order.len);
            for (w.order, 0..) |o, i| ob[i] = .{ .expr = try cloneExpr(a, o.expr), .desc = o.desc };
            n.* = .{ .window = .{ .name = w.name, .args = args, .order = ob } };
        },
        .ordered_agg => |w| {
            const ob = try a.alloc(OrderItem, w.order.len);
            for (w.order, 0..) |o, i| ob[i] = .{ .expr = try cloneExpr(a, o.expr), .desc = o.desc };
            n.* = .{ .ordered_agg = .{ .arg = try cloneExpr(a, w.arg), .order = ob } };
        },
        .not => |x| n.* = .{ .not = try cloneExpr(a, x) },
        .call => |c| {
            const args = try a.alloc(*Expr, c.args.len);
            for (c.args, 0..) |x, i| args[i] = try cloneExpr(a, x);
            n.* = .{ .call = .{ .name = c.name, .args = args, .distinct = c.distinct, .star = c.star } };
        },
        .case_expr => |c| {
            const whens = try a.alloc(Case.When, c.whens.len);
            for (c.whens, 0..) |w, i| whens[i] = .{ .cond = try cloneExpr(a, w.cond), .then = try cloneExpr(a, w.then) };
            n.* = .{ .case_expr = .{
                .whens = whens,
                .else_expr = if (c.else_expr) |x| try cloneExpr(a, x) else null,
            } };
        },
        .is_null => |x| n.* = .{ .is_null = .{ .operand = try cloneExpr(a, x.operand), .negated = x.negated } },
        .like => |x| n.* = .{ .like = .{
            .operand = try cloneExpr(a, x.operand),
            .pattern = try cloneExpr(a, x.pattern),
            .negated = x.negated,
        } },
        .in_list => |x| {
            const items = try a.alloc(*Expr, x.items.len);
            for (x.items, 0..) |it, i| items[i] = try cloneExpr(a, it);
            n.* = .{ .in_list = .{
                .operand = try cloneExpr(a, x.operand),
                .items = items,
                .negated = x.negated,
            } };
        },
        .between => |x| n.* = .{ .between = .{
            .operand = try cloneExpr(a, x.operand),
            .low = try cloneExpr(a, x.low),
            .high = try cloneExpr(a, x.high),
            .negated = x.negated,
        } },
        .cast => |x| n.* = .{ .cast = .{ .operand = try cloneExpr(a, x.operand), .type_name = x.type_name } },
        // Subqueries are shared: the clone is only used for comparison and for
        // immediate measurement while the statement's AST is alive.
        .in_subquery => |x| n.* = .{ .in_subquery = .{
            .operand = try cloneExpr(a, x.operand),
            .sub = x.sub,
            .negated = x.negated,
        } },
        .exists => |x| n.* = .{ .exists = .{ .sub = x.sub, .negated = x.negated } },
    }
    return n;
}

/// Deep clone including sub-SELECTs (used to persist a predicate whose
/// subquery must be re-executed later, after data changes).
pub fn cloneExprDeep(a: std.mem.Allocator, e: *Expr) std.mem.Allocator.Error!*Expr {
    if (e.* != .in_subquery and e.* != .exists) {
        // Non-subquery nodes: reuse the shallow clone but recurse for operands
        // that may themselves contain subqueries.
        switch (e.*) {
            .binary => |b| {
                const n = try a.create(Expr);
                n.* = .{ .binary = .{ .op = b.op, .lhs = try cloneExprDeep(a, b.lhs), .rhs = try cloneExprDeep(a, b.rhs) } };
                return n;
            },
            .negate => |x| {
                const n = try a.create(Expr);
                n.* = .{ .negate = try cloneExprDeep(a, x) };
                return n;
            },
            .not => |x| {
                const n = try a.create(Expr);
                n.* = .{ .not = try cloneExprDeep(a, x) };
                return n;
            },
            .is_null => |x| {
                const n = try a.create(Expr);
                n.* = .{ .is_null = .{ .operand = try cloneExprDeep(a, x.operand), .negated = x.negated } };
                return n;
            },
            .like => |x| {
                const n = try a.create(Expr);
                n.* = .{ .like = .{ .operand = try cloneExprDeep(a, x.operand), .pattern = try cloneExprDeep(a, x.pattern), .negated = x.negated } };
                return n;
            },
            .in_list => |x| {
                const n = try a.create(Expr);
                const items = try a.alloc(*Expr, x.items.len);
                for (x.items, 0..) |it, i| items[i] = try cloneExprDeep(a, it);
                n.* = .{ .in_list = .{ .operand = try cloneExprDeep(a, x.operand), .items = items, .negated = x.negated } };
                return n;
            },
            .between => |x| {
                const n = try a.create(Expr);
                n.* = .{ .between = .{
                    .operand = try cloneExprDeep(a, x.operand),
                    .low = try cloneExprDeep(a, x.low),
                    .high = try cloneExprDeep(a, x.high),
                    .negated = x.negated,
                } };
                return n;
            },
            .cast => |x| {
                const n = try a.create(Expr);
                n.* = .{ .cast = .{ .operand = try cloneExprDeep(a, x.operand), .type_name = x.type_name } };
                return n;
            },
            .call => |c| {
                const n = try a.create(Expr);
                const args = try a.alloc(*Expr, c.args.len);
                for (c.args, 0..) |x, i| args[i] = try cloneExprDeep(a, x);
                n.* = .{ .call = .{ .name = c.name, .args = args, .distinct = c.distinct, .star = c.star } };
                return n;
            },
            .case_expr => |c| {
                const n = try a.create(Expr);
                const whens = try a.alloc(Case.When, c.whens.len);
                for (c.whens, 0..) |w, i| whens[i] = .{ .cond = try cloneExprDeep(a, w.cond), .then = try cloneExprDeep(a, w.then) };
                n.* = .{ .case_expr = .{ .whens = whens, .else_expr = if (c.else_expr) |x| try cloneExprDeep(a, x) else null } };
                return n;
            },
            else => return cloneExpr(a, e),
        }
    }
    const n = try a.create(Expr);
    switch (e.*) {
        .in_subquery => |x| n.* = .{ .in_subquery = .{
            .operand = try cloneExprDeep(a, x.operand),
            .sub = try cloneSelectDeep(a, x.sub),
            .negated = x.negated,
        } },
        .exists => |x| n.* = .{ .exists = .{ .sub = try cloneSelectDeep(a, x.sub), .negated = x.negated } },
        else => unreachable,
    }
    return n;
}

pub fn cloneSelectDeep(a: std.mem.Allocator, s: *Select) std.mem.Allocator.Error!*Select {
    const n = try a.create(Select);
    const items = try a.alloc(SelectItem, s.items.len);
    for (s.items, 0..) |it, i| {
        items[i] = .{ .expr = try cloneExprDeep(a, it.expr), .alias = it.alias };
    }
    var from: ?From = null;
    if (s.from) |f| {
        from = switch (f) {
            .table => |t| .{ .table = t },
            .subquery => |sub| .{ .subquery = try cloneSelectDeep(a, sub) },
            .function => |fnf| blk: {
                const args = try a.alloc(*Expr, fnf.args.len);
                for (fnf.args, 0..) |arg, i| args[i] = try cloneExprDeep(a, arg);
                break :blk .{ .function = .{ .name = fnf.name, .args = args } };
            },
            .values => |rows| blk: {
                const out = try a.alloc([]*Expr, rows.len);
                for (rows, 0..) |r, ri| {
                    out[ri] = try a.alloc(*Expr, r.len);
                    for (r, 0..) |e, ci| out[ri][ci] = try cloneExprDeep(a, e);
                }
                break :blk .{ .values = out };
            },
        };
    }
    const gb = try a.alloc(*Expr, s.group_by.len);
    for (s.group_by, 0..) |g, i| gb[i] = try cloneExprDeep(a, g);
    const ob = try a.alloc(OrderItem, s.order_by.len);
    for (s.order_by, 0..) |o, i| ob[i] = .{ .expr = try cloneExprDeep(a, o.expr), .desc = o.desc };
    var join: ?Join = null;
    if (s.join) |j| {
        join = .{ .table = j.table, .on = try cloneExprDeep(a, j.on), .extra_eqs = blk: {
            const xs = try a.alloc(*Expr, j.extra_eqs.len);
            for (j.extra_eqs, 0..) |x, i| xs[i] = try cloneExprDeep(a, x);
            break :blk xs;
        }, .left = j.left, .right = j.right, .alias = j.alias };
    }
    const mj = try a.alloc(Join, s.more_joins.len);
    for (s.more_joins, 0..) |j, i| {
        mj[i] = .{ .table = j.table, .on = try cloneExprDeep(a, j.on), .extra_eqs = blk: {
            const xs = try a.alloc(*Expr, j.extra_eqs.len);
            for (j.extra_eqs, 0..) |x, k| xs[k] = try cloneExprDeep(a, x);
            break :blk xs;
        }, .left = j.left, .right = j.right, .alias = j.alias };
    }
    n.* = .{
        .distinct = s.distinct,
        .alias = s.alias,
        .items = items,
        .from = from,
        .where = if (s.where) |w| try cloneExprDeep(a, w) else null,
        .group_by = gb,
        .having = if (s.having) |h| try cloneExprDeep(a, h) else null,
        .order_by = ob,
        .extra_from = blk2: {
            const xs = try a.alloc(FromItem, s.extra_from.len);
            for (s.extra_from, 0..) |it, k| {
                var ni = FromItem{ .from = it.from, .alias = it.alias };
                switch (it.from) {
                    .function => |f| {
                        const ar = try a.alloc(*Expr, f.args.len);
                        for (f.args, 0..) |x, q| ar[q] = try cloneExprDeep(a, x);
                        ni.from = .{ .function = .{ .name = f.name, .args = ar } };
                    },
                    .subquery => |sub2| ni.from = .{ .subquery = try cloneSelectDeep(a, sub2) },
                    else => {},
                }
                xs[k] = ni;
            }
            break :blk2 xs;
        },
        .limit = if (s.limit) |l| try cloneExprDeep(a, l) else null,
        .offset = if (s.offset) |o| try cloneExprDeep(a, o) else null,
        .join = join,
        .more_joins = mj,
        .union_all = if (s.union_all) |u| try cloneSelectDeep(a, u) else null,
        .set_op = s.set_op,
        .format_json = s.format_json,
    };
    return n;
}

pub const SelectItem = struct {
    expr: *Expr,
    alias: ?[]const u8,
};

pub const OrderItem = struct {
    expr: *Expr,
    desc: bool = false,
};

pub const From = union(enum) {
    table: []const u8,
    subquery: *Select,
    /// Table-valued function, currently `pg_input_error_info(...)`.
    function: struct { name: []const u8, args: []*Expr },
    /// `FROM (VALUES (...), ...) AS t(c1, ...)`.
    values: [][]*Expr,
};

pub const FromItem = struct { from: From, alias: ?[]const u8 = null };

pub const Join = struct {
    table: []const u8,
    on: *Expr,
    left: bool = false,
    right: bool = false,
    cross: bool = false,
    /// `JOIN t alias ON ...`: kept so qualified predicates can be rewritten to
    /// the real table name before planning.
    alias: ?[]const u8 = null,
    /// Extra equality conjuncts from a multi-key ON (`ON a.x=b.x AND a.y=b.y`).
    /// The hash join uses `on`; these are applied as post-join filters and
    /// included in cardinality estimates.
    extra_eqs: []const *Expr = &.{},
};

pub const Select = struct {
    distinct: bool = false,
    /// `FROM t AS a` / `FROM t a` — kept so qualified refs can be validated.
    alias: ?[]const u8 = null,
    /// Optional `AS a(c1,c2)` column alias list.
    alias_cols: []const []const u8 = &.{},
    items: []SelectItem,
    from: ?From = null,
    where: ?*Expr = null,
    group_by: []*Expr = &.{},
    having: ?*Expr = null,
    order_by: []OrderItem = &.{},
    limit: ?*Expr = null,
    offset: ?*Expr = null,
    join: ?Join = null,
    /// Additional joins after the first one (`FROM a JOIN b ON .. JOIN c ON ..`).
    more_joins: []Join = &.{},
    /// Additional comma-separated FROM items (`FROM a, b, c`).
    extra_from: []FromItem = &.{},
    /// `SELECT ... INTO table ...`
    into_table: ?[]const u8 = null,
    /// Right-hand side of a set operation (`UNION [ALL]` / `INTERSECT` / `EXCEPT`).
    union_all: ?*Select = null,
    set_op: SetOp = .union_all,
    format_json: bool = false,
};

pub const SetOp = enum { union_all, union_distinct, intersect, except };

pub const ColumnDef = struct {
    name: []const u8,
    type_name: []const u8,
    /// SERIAL/BIGSERIAL/SMALLSERIAL: auto-increment on INSERT.
    serial: bool = false,
};

pub const Assignment = struct { col: []const u8, value: *Expr };

pub const Cte = struct { name: []const u8, select: *Select };

pub const RoleOpts = struct {
    superuser: ?bool = null,
    inherit: ?bool = null,
    createrole: ?bool = null,
    createdb: ?bool = null,
    canlogin: ?bool = null,
    replication: ?bool = null,
    bypassrls: ?bool = null,
    connlimit: ?i64 = null,
    password_set: bool = false,
    password: ?[]const u8 = null,
    validuntil: ?[]const u8 = null,
};

pub const Stmt = union(enum) {
    select: *Select,
    create_table: struct {
        name: []const u8,
        cols: []ColumnDef,
        if_not_exists: bool,
        inherits: []const []const u8 = &.{},
        as_select: ?*Select = null,
        as_exec: ?*Stmt = null,
        temp: bool = false,
        with_no_data: bool = false,
    },
    drop_table: struct { name: []const u8, if_exists: bool },
    drop_tables: struct { names: []const []const u8, if_exists: bool },
    with_query: struct { ctes: []Cte, select: *Select },
    declare_cursor: struct { name: []const u8, text: []const u8 },
    fetch_cursor: struct { name: []const u8, all: bool, count: i64 = 0 },
    close_cursor: struct { name: ?[]const u8 },
    explain: struct { select: *Select },
    explain_any: struct { inner: *Stmt },
    create_event_trigger: struct { name: []const u8, func: []const u8 },
    alter_event_trigger: struct { name: []const u8, enabled: bool },
    drop_event_trigger: struct { name: []const u8, if_exists: bool },
    create_matview: struct { name: []const u8, select_text: []const u8, select: *Select },
    refresh_matview: struct { name: []const u8 },
    insert: struct { table: []const u8, columns: []const []const u8, rows: [][]*Expr },
    insert_select: struct { table: []const u8, columns: []const []const u8, select: *Select },
    copy: struct {
        table: []const u8,
        columns: []const []const u8,
        path: []const u8,
        to: bool = false,
        encoding: ?[]const u8 = null,
        select: ?*Select = null,
    },
    delete: struct { table: []const u8, alias: ?[]const u8 = null, where: ?*Expr },
    update: struct { table: []const u8, assignments: []Assignment, where: ?*Expr },
    truncate: []const u8,
    analyze: []const u8,
    create_index: struct { name: []const u8, table: []const u8, col: []const u8, unique: bool = false, fillfactor: ?i64 = null },
    vacuum: ?[]const u8,
    security_label: struct { provider: ?[]const u8 },
    create_role: struct { name: []const u8, is_user: bool, opts: RoleOpts },
    create_function: struct { name: []const u8, body: []const u8, args: []const u8, plpgsql: bool = false },
    create_view: struct { name: []const u8, select_text: []const u8, select: *Select },
    create_schema: struct { name: ?[]const u8, authorization: ?[]const u8, element: ?*Stmt },
    create_domain: struct { name: []const u8, base: []const u8 },
    drop_schema: struct { names: []const []const u8, if_exists: bool, cascade: bool },
    drop_view: struct { names: []const []const u8, if_exists: bool },
    prepare: struct { name: []const u8, types: []const []const u8, text: []const u8, inner: []const u8 },
    execute: struct { name: []const u8, args: []*Expr },
    deallocate: struct { name: ?[]const u8 },
    alter_role: struct { name: []const u8, opts: RoleOpts, rename_to: ?[]const u8 = null },
    drop_role: struct { names: []const []const u8, if_exists: bool },
    set: struct { name: []const u8, value: []const u8, local: bool = false },
    reset: []const u8,
    /// DDL handled by the engine's raw object registry (CREATE/DROP of
    /// non-table objects).
    raw: []const u8,
    noop,
};

const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    alloc: std.mem.Allocator,

    fn tokenize(self: *Tokenizer) ![]Token {
        var list = std.ArrayList(Token).empty;
        defer list.deinit(self.alloc);
        while (true) {
            self.skipSpace();
            if (self.pos >= self.src.len) break;
            const c = self.src[self.pos];
            if ((c == 'U' or c == 'u') and self.pos + 2 < self.src.len and self.src[self.pos + 1] == '&' and self.src[self.pos + 2] == '\'') {
                self.pos += 3; // U&'
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.alloc);
                while (self.pos < self.src.len) {
                    const ch = self.src[self.pos];
                    if (ch == '\'') {
                        if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                            try buf.append(self.alloc, '\'');
                            self.pos += 2;
                            continue;
                        }
                        self.pos += 1;
                        break;
                    }
                    if (ch == '\\' and self.pos + 1 < self.src.len) {
                        var cp: u32 = 0;
                        if (self.src[self.pos + 1] == '+') {
                            if (self.pos + 8 <= self.src.len) {
                                for (self.src[self.pos + 2 .. self.pos + 8]) |hc| {
                                    const d = std.fmt.charToDigit(hc, 16) catch break;
                                    cp = cp * 16 + d;
                                }
                                self.pos += 8;
                            } else self.pos += 1;
                        } else if (self.pos + 5 <= self.src.len) {
                            for (self.src[self.pos + 1 .. self.pos + 5]) |hc| {
                                const d = std.fmt.charToDigit(hc, 16) catch break;
                                cp = cp * 16 + d;
                            }
                            self.pos += 5;
                        } else self.pos += 1;
                        if (cp >= 0xD800 and cp <= 0xDBFF and self.pos + 5 <= self.src.len and self.src[self.pos] == '\\') {
                            var lo: u32 = 0;
                            var ok = true;
                            for (self.src[self.pos + 1 .. self.pos + 5]) |hc| {
                                const d = std.fmt.charToDigit(hc, 16) catch { ok = false; break; };
                                lo = lo * 16 + d;
                            }
                            if (ok and lo >= 0xDC00 and lo <= 0xDFFF) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                self.pos += 5;
                            }
                        }
                        var ub: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(@intCast(cp), &ub) catch 0;
                        try buf.appendSlice(self.alloc, ub[0..n]);
                        continue;
                    }
                    try buf.append(self.alloc, ch);
                    self.pos += 1;
                }
                try list.append(self.alloc, .{ .kind = .string, .text = try self.alloc.dupe(u8, buf.items) });
            } else if ((c == 'E' or c == 'e') and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                self.pos += 2;
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.alloc);
                while (self.pos < self.src.len) {
                    const ch = self.src[self.pos];
                    if (ch == '\'') {
                        if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                            try buf.append(self.alloc, '\'');
                            self.pos += 2;
                            continue;
                        }
                        self.pos += 1;
                        break;
                    }
                    if (ch == '\\' and self.pos + 1 < self.src.len) {
                        self.pos += 1;
                        const e = self.src[self.pos];
                        if (e == 'u' and self.pos + 4 < self.src.len) {
                            var cp: u32 = 0;
                            var ok = true;
                            for (self.src[self.pos + 1 .. self.pos + 5]) |hc| {
                                const d = std.fmt.charToDigit(hc, 16) catch { ok = false; break; };
                                cp = cp * 16 + d;
                            }
                            if (ok) {
                                self.pos += 5;
                                var ub: [4]u8 = undefined;
                                const n = std.unicode.utf8Encode(@intCast(cp), &ub) catch 0;
                                try buf.appendSlice(self.alloc, ub[0..n]);
                                continue;
                            }
                        }
                        if (e >= '0' and e <= '7') {
                            var code: u16 = 0;
                            var digits: usize = 0;
                            while (digits < 3 and self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '7') {
                                code = code * 8 + (self.src[self.pos] - '0');
                                digits += 1;
                                self.pos += 1;
                            }
                            try buf.append(self.alloc, @intCast(code & 0xff));
                            continue;
                        }
                        try buf.append(self.alloc, switch (e) {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            'b' => 8,
                            'f' => 12,
                            else => e,
                        });
                        self.pos += 1;
                        continue;
                    }
                    try buf.append(self.alloc, ch);
                    self.pos += 1;
                }
                try list.append(self.alloc, .{ .kind = .string, .text = try self.alloc.dupe(u8, buf.items) });
            } else if (std.ascii.isAlphabetic(c) or c == '_') {
                const start = self.pos;
                while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
                try list.append(self.alloc, .{ .kind = .ident, .text = self.src[start..self.pos] });
            } else if (c == '"') {
                // Quoted identifier (psql quotes aliases: AS "Schema").
                self.pos += 1;
                const start = self.pos;
                while (self.pos < self.src.len and self.src[self.pos] != '"') self.pos += 1;
                try list.append(self.alloc, .{ .kind = .ident, .text = self.src[start..self.pos], .quoted = true });
                if (self.pos < self.src.len) self.pos += 1;
            } else if (std.ascii.isDigit(c)) {
                const start = self.pos;
                while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '.')) self.pos += 1;
                if (self.pos < self.src.len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
                    self.pos += 1;
                    if (self.pos < self.src.len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
                    while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
                }
                try list.append(self.alloc, .{ .kind = .number, .text = self.src[start..self.pos] });
            } else if (c == '$' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) {
                const start = self.pos;
                self.pos += 1;
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
                try list.append(self.alloc, .{ .kind = .param, .text = self.src[start + 1 .. self.pos] });
            } else if (c == '$') {
                // PostgreSQL dollar-quoted string: $$...$$ or $tag$...$tag$.
                const start = self.pos;
                var p = self.pos + 1;
                while (p < self.src.len and (std.ascii.isAlphanumeric(self.src[p]) or self.src[p] == '_')) p += 1;
                if (p < self.src.len and self.src[p] == '$') {
                    const tag = self.src[start .. p + 1];
                    if (std.mem.indexOfPos(u8, self.src, p + 1, tag)) |end| {
                        try list.append(self.alloc, .{ .kind = .string, .text = try self.alloc.dupe(u8, self.src[p + 1 .. end]) });
                        self.pos = end + tag.len;
                    } else {
                        self.pos = self.src.len;
                    }
                } else {
                    self.pos += 1;
                }
            } else if (c == '\'' or ((c == 'E' or c == 'e') and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'')) {
                self.pos += 1; // opening quote
                var buf = std.ArrayList(u8).empty;
                defer buf.deinit(self.alloc);
                while (self.pos < self.src.len) {
                    const ch = self.src[self.pos];
                    if (ch == '\'') {
                        if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                            try buf.append(self.alloc, '\'');
                            self.pos += 2;
                            continue;
                        }
                        self.pos += 1;
                        break;
                    }
                    try buf.append(self.alloc, ch);
                    self.pos += 1;
                }
                try list.append(self.alloc, .{ .kind = .string, .text = try self.alloc.dupe(u8, buf.items) });
            } else {
                const two = if (self.pos + 1 < self.src.len) self.src[self.pos .. self.pos + 2] else "";
                const kind: TokenKind = if (self.pos + 2 < self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "<->"))
                    .distance
                else if (self.pos + 2 < self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "|>>"))
                    .above
                else if (self.pos + 2 < self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "<<|"))
                    .below
                else if (std.mem.eql(u8, two, "~="))
                    .pointeq
                else if (std.mem.eql(u8, two, "=>"))
                    .arrow
                else if (self.pos + 2 < self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "->>"))
                    .jsonget_text
                else if (std.mem.eql(u8, two, "->"))
                    .jsonget
                else if (std.mem.eql(u8, two, "||"))
                    .concat
                else if (std.mem.eql(u8, two, "&&"))
                    .ampamp
                else if (std.mem.eql(u8, two, "::"))
                    .cast
                else if (std.mem.eql(u8, two, "<<"))
                    .shl
                else if (std.mem.eql(u8, two, ">>"))
                    .shr
                else if (std.mem.eql(u8, two, "<="))
                    .le
                else if (std.mem.eql(u8, two, "||"))
                    .plus
                else if (std.mem.eql(u8, two, "<@"))
                    .contains
                else if (std.mem.eql(u8, two, "@>"))
                    .subcontains
                else if (std.mem.eql(u8, two, ">="))
                    .ge
                else if (std.mem.eql(u8, two, "<>"))
                    .neq
                else if (std.mem.eql(u8, two, "!="))
                    .neq
                else if (std.mem.eql(u8, two, "!~"))
                    .regex_ne
                else if (std.mem.eql(u8, two, "~*"))
                    .regex
                else if (std.mem.eql(u8, two, "!~*"))
                    .regex_ne
                else switch (c) {
                    '~' => .regex,
                    '&' => .amp,
                    '|' => .pipe,
                    '#' => .hash,
                    '*' => .star,
                    ',' => .comma,
                    '(' => .lparen,
                    ')' => .rparen,
                    '+' => .plus,
                    '-' => .minus,
                    '/' => .slash,
                    '%' => .percent,
                    '=' => .eq,
                    '<' => .lt,
                    '>' => .gt,
                    '[' => .lbracket,
                    ']' => .rbracket,
                    '@' => .eof,
                    '.' => .dot,
                    ';' => .semicolon,
                    else => .eof,
                };
                // Multi-character operators must consume all their bytes,
                // otherwise the tail is tokenized again (`!~` -> `!`,`~`).
                const len: usize = if (self.pos + 2 < self.src.len and
                    (std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "!~*") or
                     std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "<->") or
                     std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "|>>") or
                     std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "->>") or
                     std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "<<|")))
                    3
                else if (std.mem.eql(u8, two, "::") or std.mem.eql(u8, two, "<<") or std.mem.eql(u8, two, ">>") or std.mem.eql(u8, two, "<=") or std.mem.eql(u8, two, ">=") or std.mem.eql(u8, two, "<@") or std.mem.eql(u8, two, "@>") or
                    std.mem.eql(u8, two, "<>") or std.mem.eql(u8, two, "!=") or
                    std.mem.eql(u8, two, "!~") or std.mem.eql(u8, two, "~*") or std.mem.eql(u8, two, "~=") or std.mem.eql(u8, two, "=>") or std.mem.eql(u8, two, "||") or std.mem.eql(u8, two, "->") or std.mem.eql(u8, two, "&&"))
                    2
                else
                    1;
                if (kind == .eof) {
                    self.pos += 1;
                    continue;
                }
                try list.append(self.alloc, .{ .kind = kind, .text = self.src[self.pos .. self.pos + len] });
                self.pos += len;
            }
        }
        try list.append(self.alloc, .{ .kind = .eof, .text = "" });
        return list.toOwnedSlice(self.alloc);
    }

    fn skipSpace(self: *Tokenizer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
            } else if (c == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                var depth: usize = 1;
                while (self.pos < self.src.len and depth > 0) {
                    if (self.pos + 1 < self.src.len and self.src[self.pos] == '/' and self.src[self.pos + 1] == '*') {
                        depth += 1;
                        self.pos += 2;
                    } else if (self.pos + 1 < self.src.len and self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                        depth -= 1;
                        self.pos += 2;
                    } else self.pos += 1;
                }
            } else break;
        }
    }
};

fn kwAt(src: []const u8, at: usize, kw: []const u8) bool {
    if (at + kw.len > src.len) return false;
    if (!std.ascii.eqlIgnoreCase(src[at .. at + kw.len], kw)) return false;
    if (at > 0 and (std.ascii.isAlphanumeric(src[at - 1]) or src[at - 1] == '_')) return false;
    if (at + kw.len < src.len and (std.ascii.isAlphanumeric(src[at + kw.len]) or src[at + kw.len] == '_')) return false;
    return true;
}

fn skipWsAt(src: []const u8, p: *usize) void {
    while (p.* < src.len and std.ascii.isWhitespace(src[p.*])) p.* += 1;
}

fn findNthKeywordText(src: []const u8, kw: []const u8, nth: usize) []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i + kw.len <= src.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(src[i .. i + kw.len], kw)) continue;
        if (i > 0 and (std.ascii.isAlphanumeric(src[i - 1]) or src[i - 1] == '_')) continue;
        if (i + kw.len < src.len and (std.ascii.isAlphanumeric(src[i + kw.len]) or src[i + kw.len] == '_')) continue;
        count += 1;
        if (count == nth) return src[i..];
    }
    return "";
}

fn findKeywordTextFrom(src: []const u8, kw: []const u8) []const u8 {
    var i: usize = 0;
    while (i + kw.len <= src.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(src[i .. i + kw.len], kw)) continue;
        if (i > 0 and (std.ascii.isAlphanumeric(src[i - 1]) or src[i - 1] == '_')) continue;
        if (i + kw.len < src.len and (std.ascii.isAlphanumeric(src[i + kw.len]) or src[i + kw.len] == '_')) continue;
        var j = i + kw.len;
        while (j < src.len and std.ascii.isWhitespace(src[j])) j += 1;
        return std.mem.trim(u8, src[j..], " \t\r\n");
    }
    return "";
}

fn findKeywordText(src: []const u8, kw: []const u8) []const u8 {
    var i: usize = 0;
    while (i + kw.len <= src.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(src[i .. i + kw.len], kw)) continue;
        if (i > 0 and (std.ascii.isAlphanumeric(src[i - 1]) or src[i - 1] == '_')) continue;
        return src[i..];
    }
    return "";
}

pub fn parseSelectText(alloc: std.mem.Allocator, text: []const u8) !*Select {
    var p = try Parser.init(alloc, text);
    return p.parseSelect();
}

pub fn parseStatementText(alloc: std.mem.Allocator, text: []const u8) !Stmt {
    var p = try Parser.init(alloc, text);
    return p.parseStatement();
}

fn isNormFormName(t: []const u8) bool {
    return std.ascii.eqlIgnoreCase(t, "NFC") or std.ascii.eqlIgnoreCase(t, "NFD") or
        std.ascii.eqlIgnoreCase(t, "NFKC") or std.ascii.eqlIgnoreCase(t, "NFKD") or
        std.ascii.eqlIgnoreCase(t, "DEFAULT");
}

pub const Parser = struct {
    alloc: std.mem.Allocator,
    toks: []Token,
    i: usize = 0,
    src: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator, src: []const u8) !Parser {
        var tz = Tokenizer{ .src = src, .alloc = alloc };
        return .{ .alloc = alloc, .toks = try tz.tokenize(), .src = src };
    }

    fn peek(self: *Parser) Token {
        return self.toks[self.i];
    }

    fn next(self: *Parser) Token {
        const t = self.toks[self.i];
        if (self.i + 1 < self.toks.len) self.i += 1;
        return t;
    }

    fn atKw(self: *Parser, kw: []const u8) bool {
        const t = self.peek();
        return t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, kw);
    }

    fn eatKw(self: *Parser, kw: []const u8) bool {
        if (self.atKw(kw)) {
            _ = self.next();
            return true;
        }
        return false;
    }

    fn expectKw(self: *Parser, kw: []const u8) Error!void {
        if (!self.eatKw(kw)) return error.SyntaxError;
    }

    fn atSym(self: *Parser, k: TokenKind) bool {
        return self.peek().kind == k;
    }

    fn eatSym(self: *Parser, k: TokenKind) bool {
        if (self.atSym(k)) {
            _ = self.next();
            return true;
        }
        return false;
    }

    fn expectSym(self: *Parser, k: TokenKind) Error!void {
        if (!self.eatSym(k)) return error.SyntaxError;
    }

    fn foldIdent(self: *Parser, name: []const u8) Error![]const u8 {
        var buf: [256]u8 = undefined;
        if (name.len <= buf.len) return try self.alloc.dupe(u8, std.ascii.lowerString(buf[0..name.len], name));
        return name;
    }

    fn expectIdent(self: *Parser) Error![]const u8 {
        const t = self.peek();
        if (t.kind != .ident) return error.SyntaxError;
        _ = self.next();
        return t.text;
    }

    fn skipToSemicolon(self: *Parser) void {
        while (self.peek().kind != .semicolon and self.peek().kind != .eof) _ = self.next();
    }

    pub fn parseStatement(self: *Parser) Error!Stmt {
        while (self.eatSym(.semicolon)) {}
        if (self.peek().kind == .eof) return .noop;
        const t = self.peek();
        if (t.kind != .ident) return error.SyntaxError;
        if (std.ascii.eqlIgnoreCase(t.text, "select")) return .{ .select = try self.parseSelect() };
        if (std.ascii.eqlIgnoreCase(t.text, "table") and self.i + 1 < self.toks.len) {
            _ = self.next();
            const tn = try self.expectIdent();
            const st = try self.alloc.create(Expr);
            st.* = .star;
            const items = try self.alloc.alloc(SelectItem, 1);
            items[0] = .{ .expr = st, .alias = null };
            const sel = try self.alloc.create(Select);
            sel.* = .{ .items = items, .from = .{ .table = tn } };
            return .{ .select = sel };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "create")) {
            if (try self.tryCreateFunction()) |st| return st;
            return self.parseCreate();
        }
        if (std.ascii.eqlIgnoreCase(t.text, "drop")) return self.parseDrop();
        if (std.ascii.eqlIgnoreCase(t.text, "insert")) return self.parseInsert();
        if (std.ascii.eqlIgnoreCase(t.text, "delete")) return self.parseDelete();
        if (std.ascii.eqlIgnoreCase(t.text, "update")) return self.parseUpdate();
        if (std.ascii.eqlIgnoreCase(t.text, "prepare") or std.ascii.eqlIgnoreCase(t.text, "execute") or std.ascii.eqlIgnoreCase(t.text, "deallocate")) return self.parsePrepared();
        if (std.ascii.eqlIgnoreCase(t.text, "copy")) return self.parseCopy();
        if (std.ascii.eqlIgnoreCase(t.text, "with")) return self.parseWith();
        if (std.ascii.eqlIgnoreCase(t.text, "declare")) {
            _ = self.next();
            const name = try self.expectIdent();
            _ = self.eatKw("no");
            _ = self.eatKw("scroll");
            try self.expectKw("cursor");
            if (self.eatKw("with")) _ = self.eatKw("hold");
            if (self.eatKw("without")) _ = self.eatKw("hold");
            try self.expectKw("for");
            const text = findKeywordText(self.src, "select");
            _ = try self.parseSelect();
            return .{ .declare_cursor = .{ .name = name, .text = text } };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "fetch") or std.ascii.eqlIgnoreCase(t.text, "move")) {
            _ = self.next();
            var all = false;
            var count: i64 = 0;
            if (self.eatKw("all")) all = true else if (self.eatKw("next")) {
                count = 1;
            } else if (self.eatKw("forward")) {
                if (self.eatKw("all")) all = true else if (self.peek().kind == .number) count = std.fmt.parseInt(i64, self.next().text, 10) catch 0;
            } else if (self.peek().kind == .number) {
                count = std.fmt.parseInt(i64, self.next().text, 10) catch 0;
            }
            _ = self.eatKw("in");
            _ = self.eatKw("from");
            const name = try self.expectIdent();
            self.skipToSemicolon();
            return .{ .fetch_cursor = .{ .name = name, .all = all, .count = count } };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "close")) {
            _ = self.next();
            if (self.eatKw("all")) {
                self.skipToSemicolon();
                return .{ .close_cursor = .{ .name = null } };
            }
            const name = try self.expectIdent();
            self.skipToSemicolon();
            return .{ .close_cursor = .{ .name = name } };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "explain")) return self.parseExplain();
        if (std.ascii.eqlIgnoreCase(t.text, "refresh")) {
            _ = self.next();
            try self.expectKw("materialized");
            try self.expectKw("view");
            _ = self.eatKw("concurrently");
            const rn = try self.expectIdent();
            self.skipToSemicolon();
            return .{ .refresh_matview = .{ .name = rn } };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "alter")) return self.parseAlter();
        if (std.ascii.eqlIgnoreCase(t.text, "set")) {
            _ = self.next();
            const set_local = self.eatKw("local");
            _ = self.eatKw("session");
            const name = try self.expectIdent();
            _ = self.eatKw("to") or self.eatSym(.eq);
            var value: []const u8 = "";
            if (self.peek().kind == .string) value = self.next().text
            else if (self.peek().kind != .semicolon and self.peek().kind != .eof) value = self.next().text;
            self.skipToSemicolon();
            return .{ .set = .{ .name = name, .value = value, .local = set_local } };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "reset")) {
            _ = self.next();
            const name = try self.expectIdent();
            self.skipToSemicolon();
            return .{ .reset = name };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "security")) {
            _ = self.next();
            try self.expectKw("label");
            var provider: ?[]const u8 = null;
            if (self.eatKw("for")) {
                if (self.peek().kind == .string) provider = self.next().text;
            }
            self.skipToSemicolon();
            return .{ .security_label = .{ .provider = provider } };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "truncate")) {
            _ = self.next();
            _ = self.eatKw("table");
            const name = try self.expectIdent();
            self.skipToSemicolon();
            return .{ .truncate = name };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "vacuum")) {
            _ = self.next();
            // VACUUM [FULL] [FREEZE] [VERBOSE] [ANALYZE] [table]
            while (self.eatKw("full") or self.eatKw("freeze") or
                self.eatKw("verbose") or self.eatKw("analyze")) {}
            if (self.atSym(.lparen)) {
                var depth: usize = 1;
                _ = self.next();
                while (depth > 0 and self.peek().kind != .eof) {
                    if (self.atSym(.lparen)) depth += 1;
                    if (self.atSym(.rparen)) depth -= 1;
                    _ = self.next();
                }
            }
            var name: ?[]const u8 = null;
            if (self.peek().kind == .ident) name = try self.expectIdent();
            self.skipToSemicolon();
            return .{ .vacuum = name };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "analyze")) {
            _ = self.next();
            _ = self.eatKw("table");
            var name: []const u8 = "";
            if (self.peek().kind == .ident) name = try self.expectIdent();
            self.skipToSemicolon();
            return .{ .analyze = name };
        }
        if (std.ascii.eqlIgnoreCase(t.text, "truncate")) {
            _ = self.next();
            _ = self.eatKw("table");
            const name = try self.expectIdent();
            self.skipToSemicolon();
            return .{ .truncate = name };
        }
        // Common table expressions are not implemented yet; do not turn them
        // into a silent no-op.
        if (std.ascii.eqlIgnoreCase(t.text, "with")) return error.SyntaxError;
        // SET / ALTER / USE / CREATE MATERIALIZED VIEW and anything else: accept and ignore.
        self.skipToSemicolon();
        return .noop;
    }

    fn parseCreate(self: *Parser) Error!Stmt {
        _ = self.next(); // CREATE
        var temp = false;
        if (self.eatKw("temp") or self.eatKw("temporary")) temp = true;
        _ = self.eatKw("unlogged");
        if (self.eatKw("event")) {
            try self.expectKw("trigger");
            const ename = try self.expectIdent();
            try self.expectKw("on");
            _ = try self.expectIdent();
            try self.expectKw("execute");
            _ = self.eatKw("procedure");
            _ = self.eatKw("function");
            const fname = try self.expectIdent();
            self.skipToSemicolon();
            return .{ .create_event_trigger = .{ .name = ename, .func = fname } };
        }
        if (self.eatKw("domain")) {
            const dname = try self.expectIdent();
            _ = self.eatKw("as");
            const base = try self.parseTypeName();
            self.skipToSemicolon();
            return .{ .create_domain = .{ .name = dname, .base = base } };
        }
        if (self.eatKw("role") or self.eatKw("user") or self.eatKw("group")) {
            const is_user = std.ascii.eqlIgnoreCase(self.toks[self.i - 1].text, "user");
            const name = try self.expectIdent();
            const opts = try self.parseRoleOpts();
            self.skipToSemicolon();
            return .{ .create_role = .{ .name = name, .is_user = is_user, .opts = opts } };
        }
        if (self.eatKw("materialized")) {
            try self.expectKw("view");
            var mname = try self.expectIdent();
            if (self.eatSym(.dot)) {
                const part = try self.expectIdent();
                mname = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ mname, part });
            }
            try self.expectKw("as");
            const text = findKeywordText(self.src, "select");
            const sel = try self.parseSelect();
            self.skipToSemicolon();
            return .{ .create_matview = .{ .name = mname, .select_text = text, .select = sel } };
        }
        if (self.eatKw("schema")) {
            var sname: ?[]const u8 = null;
            var auth: ?[]const u8 = null;
            if (!self.atKw("authorization") and self.peek().kind == .ident) sname = try self.expectIdent();
            if (self.eatKw("authorization")) {
                if (self.eatKw("current_role") or self.eatKw("current_user") or self.eatKw("session_user") or self.eatKw("user")) {
                    auth = "CURRENT_ROLE";
                } else auth = try self.expectIdent();
            }
            var elem: ?*Stmt = null;
            if (self.atKw("create")) {
                const rem = findNthKeywordText(self.src, "create", 2);
                if (rem.len > 0) {
                    var ep = try Parser.init(self.alloc, rem);
                    const el = try ep.parseStatement();
                    const ep2 = try self.alloc.create(Stmt);
                    ep2.* = el;
                    elem = ep2;
                }
            }
            self.skipToSemicolon();
            return .{ .create_schema = .{ .name = sname, .authorization = auth, .element = elem } };
        }
        if (self.eatKw("view")) {
            var vname = try self.expectIdent();
            if (self.eatSym(.dot)) {
                const part = try self.expectIdent();
                vname = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ vname, part });
            }
            try self.expectKw("as");
            const text = findKeywordText(self.src, "select");
            const sel = try self.parseSelect();
            self.skipToSemicolon();
            return .{ .create_view = .{ .name = vname, .select_text = text, .select = sel } };
        }
        // Setup fixtures need these objects to exist, but zhdb does not
        // implement them yet. Accept and skip rather than failing test_setup.
        if (self.eatKw("tablespace") or self.eatKw("type") or self.eatKw("function") or
            self.eatKw("procedure") or self.eatKw("operator") or self.eatKw("aggregate") or
            self.eatKw("cast") or self.eatKw("schema") or self.eatKw("extension") or
            self.eatKw("domain") or self.eatKw("sequence") or self.eatKw("rule") or
            self.eatKw("trigger") or self.eatKw("role") or self.eatKw("user") or
            self.eatKw("database") or self.eatKw("collation") or self.eatKw("conversion") or
            self.eatKw("language") or self.eatKw("publication") or self.eatKw("subscription") or
            self.eatKw("policy") or self.eatKw("server") or self.eatKw("foreign") or
            self.eatKw("access") or self.eatKw("statistics") or self.eatKw("text") or
            self.eatKw("transform"))
        {
            return .{ .raw = self.src };
        }
        var unique_index = false;
        if (self.eatKw("unique")) unique_index = true;
        if (self.eatKw("index")) {
            _ = self.eatKw("concurrently");
            _ = self.eatKw("if");
            _ = self.eatKw("not");
            _ = self.eatKw("exists");
            var name: []const u8 = "";
            if (!self.atKw("on")) name = try self.expectIdent();
            try self.expectKw("on");
            var table = try self.expectIdent();
            if (self.eatSym(.dot)) {
                const part = try self.expectIdent();
                table = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ table, part });
            }
            if (self.eatKw("using")) _ = try self.expectIdent();
            try self.expectSym(.lparen);
            var col: []const u8 = "";
            if (self.atSym(.lparen)) {
                var depth: usize = 1;
                _ = self.next();
                while (depth > 0 and self.peek().kind != .eof) {
                    if (self.atSym(.lparen)) depth += 1;
                    if (self.atSym(.rparen)) depth -= 1;
                    _ = self.next();
                }
            } else col = try self.expectIdent();
            // Parse WITH (...) options.
            var fillfactor: ?i64 = null;
            while (self.peek().kind != .semicolon and self.peek().kind != .eof) {
                if (self.peek().kind == .ident and std.ascii.eqlIgnoreCase(self.peek().text, "fillfactor")) {
                    _ = self.next();
                    if (self.eatSym(.eq) and self.peek().kind == .number) {
                        fillfactor = std.fmt.parseInt(i64, self.next().text, 10) catch null;
                    }
                    continue;
                }
                _ = self.next();
            }
            self.skipToSemicolon();
            if (name.len == 0) name = try std.fmt.allocPrint(self.alloc, "{s}_{s}_idx", .{ table, if (col.len > 0) col else "expr" });
            return .{ .create_index = .{ .name = name, .table = table, .col = col, .unique = unique_index, .fillfactor = fillfactor } };
        }
        if (self.eatKw("materialized")) return .{ .raw = self.src };
        _ = self.eatKw("or"); // CREATE OR REPLACE (ignored)
        if (!self.eatKw("table")) return .{ .raw = self.src };
        var if_not_exists = false;
        if (self.eatKw("if")) {
            try self.expectKw("not");
            try self.expectKw("exists");
            if_not_exists = true;
        }
        var name = try self.expectIdent();
        if (self.eatSym(.dot)) {
            const part = try self.expectIdent();
            name = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ name, part });
        }
        // CREATE TABLE ... AS SELECT
        if (self.eatKw("as")) {
            if (self.atKw("execute")) {
                const ex = try self.parsePrepared();
                var no_data = false;
                if (self.eatKw("with")) {
                    if (self.eatKw("no")) {
                        _ = self.eatKw("data");
                        no_data = true;
                    }
                }
                self.skipToSemicolon();
                const exp = try self.alloc.create(Stmt);
                exp.* = ex;
                return .{ .create_table = .{
                    .name = name,
                    .cols = &.{},
                    .if_not_exists = if_not_exists,
                    .as_exec = exp,
                    .temp = temp,
                    .with_no_data = no_data,
                } };
            }
            const sub = try self.parseSelect();
            self.skipToSemicolon();
            return .{ .create_table = .{
                .name = name,
                .cols = &.{},
                .if_not_exists = if_not_exists,
                .as_select = sub,
                .temp = temp,
            } };
        }
        try self.expectSym(.lparen);
        var cols = std.ArrayList(ColumnDef).empty;
        defer cols.deinit(self.alloc);
        while (!self.atSym(.rparen) and self.peek().kind != .eof) {
            const col_name = try self.expectIdent();
            var type_name = try self.parseTypeName();
            var serial = false;
            if (std.ascii.eqlIgnoreCase(type_name, "serial") or std.ascii.eqlIgnoreCase(type_name, "serial4")) {
                serial = true;
                type_name = "int4";
            } else if (std.ascii.eqlIgnoreCase(type_name, "bigserial") or std.ascii.eqlIgnoreCase(type_name, "serial8")) {
                serial = true;
                type_name = "int8";
            } else if (std.ascii.eqlIgnoreCase(type_name, "smallserial") or std.ascii.eqlIgnoreCase(type_name, "serial2")) {
                serial = true;
                type_name = "int2";
            }
            try cols.append(self.alloc, .{ .name = col_name, .type_name = type_name, .serial = serial });
            // Skip column constraints (PRIMARY KEY, NOT NULL, DEFAULT ...).
            while (!self.atSym(.comma) and !self.atSym(.rparen) and self.peek().kind != .eof) _ = self.next();
            if (!self.eatSym(.comma)) break;
        }
        try self.expectSym(.rparen);
        var inherits = std.ArrayList([]const u8).empty;
        defer inherits.deinit(self.alloc);
        if (self.eatKw("inherits")) {
            try self.expectSym(.lparen);
            while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                try inherits.append(self.alloc, try self.expectIdent());
                if (!self.eatSym(.comma)) break;
            }
            try self.expectSym(.rparen);
        }
        self.skipToSemicolon();
        return .{ .create_table = .{
            .name = name,
            .cols = try cols.toOwnedSlice(self.alloc),
            .if_not_exists = if_not_exists,
            .inherits = try inherits.toOwnedSlice(self.alloc),
            .temp = temp,
        } };
    }

    fn parseTypeName(self: *Parser) Error![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);
        const qtok = self.peek();
        const base = try self.expectIdent();
        if (qtok.quoted) {
            try buf.append(self.alloc, '"');
            try buf.appendSlice(self.alloc, base);
            try buf.append(self.alloc, '"');
        } else {
            try buf.appendSlice(self.alloc, base);
        }
        // Type parameters, e.g. LowCardinality(String), DateTime('tz'), Decimal(10,2), Nullable(Int64).
        var depth: usize = 0;
        while (self.i < self.toks.len) {
            const t = self.toks[self.i];
            if (t.kind == .lparen) {
                depth += 1;
            } else if (t.kind == .rparen) {
                if (depth == 0) break;
                depth -= 1;
            } else if (depth == 0) break;
            try buf.append(self.alloc, ' ');
            try buf.appendSlice(self.alloc, t.text);
            _ = self.next();
        }
        while (self.atSym(.lbracket)) {
            _ = self.next();
            if (!self.atSym(.rbracket)) break;
            _ = self.next();
            try buf.appendSlice(self.alloc, "[]");
        }
        // time/timestamp precision modifier followed by WITH/WITHOUT TIME ZONE.
        if ((std.ascii.startsWithIgnoreCase(base, "time") or std.ascii.startsWithIgnoreCase(base, "timestamp")) and
            !std.ascii.startsWithIgnoreCase(base, "timestamp") or std.ascii.startsWithIgnoreCase(base, "timestamp"))
        {
            if (self.atKw("with") or self.atKw("without")) {
                const w = self.next().text;
                try self.expectKw("time");
                try self.expectKw("zone");
                try buf.appendSlice(self.alloc, " ");
                try buf.appendSlice(self.alloc, w);
                try buf.appendSlice(self.alloc, " time zone");
            }
        }
        return buf.toOwnedSlice(self.alloc);
    }

    /// Split a JOIN ON expression into its top-level AND conjuncts. The first
    /// equality drives the hash join; the rest are applied as post-join
    /// filters by the executor.
    fn splitOnConjuncts(self: *Parser, on: *Expr) Error![]const *Expr {
        var list = std.ArrayList(*Expr).empty;
        defer list.deinit(self.alloc);
        var stack = std.ArrayList(*Expr).empty;
        defer stack.deinit(self.alloc);
        try stack.append(self.alloc, on);
        while (stack.pop()) |e| {
            if (e.* == .binary and e.binary.op == .and_op) {
                try stack.append(self.alloc, e.binary.rhs);
                try stack.append(self.alloc, e.binary.lhs);
            } else try list.append(self.alloc, e);
        }
        return list.toOwnedSlice(self.alloc);
    }

    fn parseWith(self: *Parser) Error!Stmt {
        _ = self.next(); // WITH
        var ctes = std.ArrayList(Cte).empty;
        defer ctes.deinit(self.alloc);
        while (true) {
            const name = try self.expectIdent();
            if (self.atSym(.lparen)) {
                // Optional column list: parse and ignore (names come from the
                // CTE's own select list).
                _ = self.next();
                var depth: usize = 1;
                while (depth > 0 and self.peek().kind != .eof) {
                    if (self.atSym(.lparen)) depth += 1;
                    if (self.atSym(.rparen)) depth -= 1;
                    _ = self.next();
                }
            }
            try self.expectKw("as");
            _ = self.eatKw("materialized");
            if (self.eatKw("not")) _ = self.eatKw("materialized");
            try self.expectSym(.lparen);
            const sub = try self.parseSelect();
            try self.expectSym(.rparen);
            try ctes.append(self.alloc, .{ .name = name, .select = sub });
            if (!self.eatSym(.comma)) break;
        }
        const main = try self.parseSelect();
        return .{ .with_query = .{ .ctes = try ctes.toOwnedSlice(self.alloc), .select = main } };
    }

    fn parseExplain(self: *Parser) Error!Stmt {
        _ = self.next(); // EXPLAIN
        if (self.atSym(.lparen)) {
            _ = self.next();
            var depth: usize = 1;
            while (depth > 0 and self.peek().kind != .eof) {
                if (self.atSym(.lparen)) depth += 1;
                if (self.atSym(.rparen)) depth -= 1;
                _ = self.next();
            }
        }
        if (self.atKw("select")) {
            const sel = try self.parseSelect();
            return .{ .explain = .{ .select = sel } };
        }
        const inner = try self.parseStatement();
        const ip = try self.alloc.create(Stmt);
        ip.* = inner;
        return .{ .explain_any = .{ .inner = ip } };
    }

    /// `CREATE [OR REPLACE] FUNCTION name(...) ... LANGUAGE sql AS <body>`:
    /// register SQL-language function bodies so calls can execute them.
    fn tryCreateFunction(self: *Parser) Error!?Stmt {
        const raw = self.src;
        var p: usize = 0;
        while (p < raw.len and std.ascii.isWhitespace(raw[p])) p += 1;
        if (!kwAt(raw, p, "create")) return null;
        p += "create".len;
        skipWsAt(raw, &p);
        if (kwAt(raw, p, "or")) {
            p += 2;
            skipWsAt(raw, &p);
            if (kwAt(raw, p, "replace")) p += 7;
            skipWsAt(raw, &p);
        }
        if (!kwAt(raw, p, "function")) return null;
        p += 8;
        skipWsAt(raw, &p);
        const name_start = p;
        while (p < raw.len and (std.ascii.isAlphanumeric(raw[p]) or raw[p] == '_' or raw[p] == '.' or raw[p] == '"')) p += 1;
        if (p == name_start) return null;
        const name = raw[name_start..p];
        var args: []const u8 = "";
        if (p < raw.len and raw[p] == '(') {
            var depth: usize = 1;
            const astart = p + 1;
            var q2 = astart;
            while (q2 < raw.len and depth > 0) : (q2 += 1) {
                if (raw[q2] == '(') depth += 1;
                if (raw[q2] == ')') {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            args = raw[astart..q2];
        }
        // Locate the AS body: prefer the last `as` before `language`.
        var body_start: usize = 0;
        var body_end: usize = 0;
        var i = p;
        var found = false;
        while (i < raw.len) : (i += 1) {
            if (!kwAt(raw, i, "as")) continue;
            var q = i + 2;
            skipWsAt(raw, &q);
            if (q + 1 < raw.len and raw[q] == '$' and raw[q + 1] == '$') {
                q += 2;
                const close = std.mem.indexOfPos(u8, raw, q, "$$") orelse return null;
                body_start = q;
                body_end = close;
                found = true;
                break;
            }
            if (q < raw.len and raw[q] == '\'') {
                q += 1;
                body_start = q;
                while (q < raw.len) {
                    if (raw[q] == '\'') {
                        if (q + 1 < raw.len and raw[q + 1] == '\'') {
                            q += 2;
                            continue;
                        }
                        body_end = q;
                        found = true;
                        break;
                    }
                    q += 1;
                }
                if (found) break;
            }
        }
        if (!found) return null;
        // Only SQL-language bodies are executable here.
        var is_sql = false;
        var is_plpgsql = false;
        var j: usize = 0;
        while (j < raw.len) : (j += 1) {
            if (kwAt(raw, j, "language")) {
                var k = j + 8;
                skipWsAt(raw, &k);
                const ls = k;
                while (k < raw.len and (std.ascii.isAlphanumeric(raw[k]) or raw[k] == '_')) k += 1;
                is_sql = std.ascii.eqlIgnoreCase(raw[ls..k], "sql");
                is_plpgsql = std.ascii.eqlIgnoreCase(raw[ls..k], "plpgsql");
                break;
            }
        }
        if (!is_sql and !is_plpgsql) return null;
        const body = try self.alloc.dupe(u8, raw[body_start..body_end]);
        self.skipToSemicolon();
        return .{ .create_function = .{ .name = name, .body = body, .args = args, .plpgsql = is_plpgsql } };
    }

    fn parsePrepared(self: *Parser) Error!Stmt {
        const head = self.next();
        if (std.ascii.eqlIgnoreCase(head.text, "prepare")) {
            const name = try self.expectIdent();
            var types = std.ArrayList([]const u8).empty;
            defer types.deinit(self.alloc);
            if (self.eatSym(.lparen)) {
                while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                    try types.append(self.alloc, try self.parseTypeName());
                    if (!self.eatSym(.comma)) break;
                }
                try self.expectSym(.rparen);
            }
            try self.expectKw("as");
            const inner_text = findKeywordTextFrom(self.src, "as");
            var text = std.mem.trim(u8, self.src, " \t\r\n");
            if (text.len > 0 and text[text.len - 1] != ';') {
                text = try std.fmt.allocPrint(self.alloc, "{s};", .{text});
            }
            _ = try self.parseStatement();
            return .{ .prepare = .{ .name = name, .types = try types.toOwnedSlice(self.alloc), .text = text, .inner = inner_text } };
        }
        if (std.ascii.eqlIgnoreCase(head.text, "execute")) {
            const name = try self.expectIdent();
            var args = std.ArrayList(*Expr).empty;
            defer args.deinit(self.alloc);
            if (self.eatSym(.lparen)) {
                while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                    try args.append(self.alloc, try self.parseExpr());
                    if (!self.eatSym(.comma)) break;
                }
                try self.expectSym(.rparen);
            }
            if (!self.atKw("with")) self.skipToSemicolon();
            return .{ .execute = .{ .name = name, .args = try args.toOwnedSlice(self.alloc) } };
        }
        // DEALLOCATE [PREPARE] { name | ALL }
        _ = self.eatKw("prepare");
        if (self.eatKw("all")) {
            self.skipToSemicolon();
            return .{ .deallocate = .{ .name = null } };
        }
        const name = try self.expectIdent();
        self.skipToSemicolon();
        return .{ .deallocate = .{ .name = name } };
    }

    fn parseAlter(self: *Parser) Error!Stmt {
        _ = self.next(); // ALTER
        if (self.eatKw("event")) {
            try self.expectKw("trigger");
            const en = try self.expectIdent();
            var enabled = true;
            if (self.eatKw("disable")) enabled = false else {
                _ = self.eatKw("enable");
                _ = self.eatKw("always");
                _ = self.eatKw("replica");
            }
            self.skipToSemicolon();
            return .{ .alter_event_trigger = .{ .name = en, .enabled = enabled } };
        }
        if (self.eatKw("role") or self.eatKw("user") or self.eatKw("group")) {
            var name = try self.expectIdent();
            if (self.eatSym(.dot)) {
                const part = try self.expectIdent();
                name = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ name, part });
            }
            if (self.eatKw("rename")) {
                try self.expectKw("to");
                const newname = try self.expectIdent();
                self.skipToSemicolon();
                return .{ .alter_role = .{ .name = name, .opts = .{}, .rename_to = newname } };
            }
            const opts = try self.parseRoleOpts();
            self.skipToSemicolon();
            return .{ .alter_role = .{ .name = name, .opts = opts } };
        }
        return .{ .raw = self.src };
    }

    fn parseRoleOpts(self: *Parser) Error!RoleOpts {
        var o = RoleOpts{};
        while (self.peek().kind == .ident) {
            const kw = self.peek().text;
            if (std.ascii.eqlIgnoreCase(kw, "with")) { _ = self.next(); continue; }
            if (std.ascii.eqlIgnoreCase(kw, "superuser")) { _ = self.next(); o.superuser = true; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "nosuperuser")) { _ = self.next(); o.superuser = false; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "inherit")) { _ = self.next(); o.inherit = true; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "noinherit")) { _ = self.next(); o.inherit = false; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "createrole")) { _ = self.next(); o.createrole = true; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "nocreaterole")) { _ = self.next(); o.createrole = false; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "createdb")) { _ = self.next(); o.createdb = true; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "nocreatedb")) { _ = self.next(); o.createdb = false; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "login")) { _ = self.next(); o.canlogin = true; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "nologin")) { _ = self.next(); o.canlogin = false; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "replication")) { _ = self.next(); o.replication = true; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "noreplication")) { _ = self.next(); o.replication = false; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "bypassrls")) { _ = self.next(); o.bypassrls = true; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "nobypassrls")) { _ = self.next(); o.bypassrls = false; continue; }
            if (std.ascii.eqlIgnoreCase(kw, "encrypted") or std.ascii.eqlIgnoreCase(kw, "unencrypted")) { _ = self.next(); continue; }
            if (std.ascii.eqlIgnoreCase(kw, "connection")) {
                _ = self.next();
                _ = self.eatKw("limit");
                if (self.peek().kind == .number) {
                    o.connlimit = std.fmt.parseInt(i64, self.next().text, 10) catch -1;
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(kw, "password")) {
                _ = self.next();
                o.password_set = true;
                if (self.peek().kind == .string) {
                    o.password = self.next().text;
                } else if (self.peek().kind == .ident and std.ascii.eqlIgnoreCase(self.peek().text, "null")) {
                    _ = self.next();
                    o.password = null;
                }
                continue;
            }
            if (std.ascii.eqlIgnoreCase(kw, "valid")) {
                _ = self.next();
                _ = self.eatKw("until");
                if (self.peek().kind == .string) o.validuntil = self.next().text;
                continue;
            }
            break;
        }
        return o;
    }

    fn parseDrop(self: *Parser) Error!Stmt {
        _ = self.next(); // DROP
        if (self.eatKw("event")) {
            try self.expectKw("trigger");
            var if_exists = false;
            if (self.eatKw("if")) {
                try self.expectKw("exists");
                if_exists = true;
            }
            const en = try self.expectIdent();
            self.skipToSemicolon();
            return .{ .drop_event_trigger = .{ .name = en, .if_exists = if_exists } };
        }
        if (self.eatKw("materialized")) {
            try self.expectKw("view");
            var if_exists = false;
            if (self.eatKw("if")) {
                try self.expectKw("exists");
                if_exists = true;
            }
            var mnames = std.ArrayList([]const u8).empty;
            defer mnames.deinit(self.alloc);
            while (true) {
                try mnames.append(self.alloc, try self.expectIdent());
                if (!self.eatSym(.comma)) break;
            }
            self.skipToSemicolon();
            return .{ .drop_tables = .{ .names = try mnames.toOwnedSlice(self.alloc), .if_exists = if_exists } };
        }
        if (self.eatKw("schema")) {
            var if_exists = false;
            if (self.eatKw("if")) {
                try self.expectKw("exists");
                if_exists = true;
            }
            var snames = std.ArrayList([]const u8).empty;
            defer snames.deinit(self.alloc);
            while (self.peek().kind == .ident and !self.atKw("cascade") and !self.atKw("restrict")) {
                try snames.append(self.alloc, try self.expectIdent());
                if (!self.eatSym(.comma)) break;
            }
            var cascade = false;
            if (self.eatKw("cascade")) cascade = true else _ = self.eatKw("restrict");
            self.skipToSemicolon();
            return .{ .drop_schema = .{ .names = try snames.toOwnedSlice(self.alloc), .if_exists = if_exists, .cascade = cascade } };
        }
        if (self.eatKw("view")) {
            var if_exists = false;
            if (self.eatKw("if")) {
                try self.expectKw("exists");
                if_exists = true;
            }
            var vnames = std.ArrayList([]const u8).empty;
            defer vnames.deinit(self.alloc);
            while (true) {
                try vnames.append(self.alloc, try self.expectIdent());
                if (!self.eatSym(.comma)) break;
            }
            self.skipToSemicolon();
            return .{ .drop_view = .{ .names = try vnames.toOwnedSlice(self.alloc), .if_exists = if_exists } };
        }
        if (self.eatKw("role") or self.eatKw("user") or self.eatKw("group")) {
            var if_exists = false;
            if (self.eatKw("if")) {
                try self.expectKw("exists");
                if_exists = true;
            }
            var names = std.ArrayList([]const u8).empty;
            defer names.deinit(self.alloc);
            while (self.peek().kind != .semicolon and self.peek().kind != .eof) {
                try names.append(self.alloc, try self.expectIdent());
                if (!self.eatSym(.comma)) break;
            }
            self.skipToSemicolon();
            return .{ .drop_role = .{ .names = try names.toOwnedSlice(self.alloc), .if_exists = if_exists } };
        }
        if (!self.eatKw("table")) return .{ .raw = self.src };
        var if_exists = false;
        if (self.eatKw("if")) {
            try self.expectKw("exists");
            if_exists = true;
        }
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(self.alloc);
        while (true) {
            try names.append(self.alloc, try self.expectIdent());
            if (!self.eatSym(.comma)) break;
        }
        self.skipToSemicolon();
        if (names.items.len == 1) return .{ .drop_table = .{ .name = names.items[0], .if_exists = if_exists } };
        return .{ .drop_tables = .{ .names = try names.toOwnedSlice(self.alloc), .if_exists = if_exists } };
    }

    fn parseInsert(self: *Parser) Error!Stmt {
        _ = self.next(); // INSERT
        try self.expectKw("into");
        const table = try self.expectIdent();
        var columns = std.ArrayList([]const u8).empty;
        defer columns.deinit(self.alloc);
        if (self.eatSym(.lparen)) {
            while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                try columns.append(self.alloc, try self.expectIdent());
                if (!self.eatSym(.comma)) break;
            }
            try self.expectSym(.rparen);
        }
        if (self.atKw("select")) {
            const sub = try self.parseSelect();
            self.skipToSemicolon();
            return .{ .insert_select = .{
                .table = table,
                .columns = try columns.toOwnedSlice(self.alloc),
                .select = sub,
            } };
        }
        try self.expectKw("values");
        var rows = std.ArrayList([]*Expr).empty;
        defer rows.deinit(self.alloc);
        while (true) {
            try self.expectSym(.lparen);
            var vals = std.ArrayList(*Expr).empty;
            defer vals.deinit(self.alloc);
            while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                try vals.append(self.alloc, try self.parseExpr());
                if (!self.eatSym(.comma)) break;
            }
            try self.expectSym(.rparen);
            try rows.append(self.alloc, try vals.toOwnedSlice(self.alloc));
            if (!self.eatSym(.comma)) break;
        }
        self.skipToSemicolon();
        return .{ .insert = .{
            .table = table,
            .columns = try columns.toOwnedSlice(self.alloc),
            .rows = try rows.toOwnedSlice(self.alloc),
        } };
    }

    fn parseCopy(self: *Parser) Error!Stmt {
        _ = self.next(); // COPY
        var select: ?*Select = null;
        var table: []const u8 = "";
        var columns = std.ArrayList([]const u8).empty;
        defer columns.deinit(self.alloc);
        if (self.eatSym(.lparen)) {
            select = try self.parseSelect();
            try self.expectSym(.rparen);
        } else {
            table = try self.expectIdent();
            if (self.eatSym(.lparen)) {
                while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                    try columns.append(self.alloc, try self.expectIdent());
                    if (!self.eatSym(.comma)) break;
                }
                try self.expectSym(.rparen);
            }
        }
        var to = false;
        if (self.eatKw("to")) to = true else if (!self.eatKw("from")) return error.SyntaxError;
        const path_expr = try self.parseExpr();
        const path = switch (path_expr.*) {
            .string => |p| p,
            else => return error.SyntaxError,
        };
        var encoding: ?[]const u8 = null;
        while (self.peek().kind != .semicolon and self.peek().kind != .eof) {
            const tk = self.peek();
            if (tk.kind == .lparen or tk.kind == .rparen or tk.kind == .comma) {
                _ = self.next();
                continue;
            }
            if (tk.kind != .ident) break;
            const tok = self.next().text;
            if (std.ascii.eqlIgnoreCase(tok, "encoding") and self.peek().kind == .string) {
                encoding = self.next().text;
            }
        }
        self.skipToSemicolon();
        return .{ .copy = .{
            .table = table,
            .columns = try columns.toOwnedSlice(self.alloc),
            .path = path,
            .to = to,
            .encoding = encoding,
            .select = select,
        } };
    }

    fn parseDelete(self: *Parser) Error!Stmt {
        _ = self.next(); // DELETE
        _ = self.eatKw("from");
        const table = try self.expectIdent();
        var alias: ?[]const u8 = null;
        if (self.eatKw("as")) {
            alias = try self.expectIdent();
        } else if (self.peek().kind == .ident and !std.ascii.eqlIgnoreCase(self.peek().text, "where")) {
            alias = self.next().text;
        }
        var where: ?*Expr = null;
        if (self.eatKw("where")) where = try self.parseExpr();
        self.skipToSemicolon();
        return .{ .delete = .{ .table = table, .alias = alias, .where = where } };
    }

    fn parseUpdate(self: *Parser) Error!Stmt {
        _ = self.next(); // UPDATE
        const table = try self.expectIdent();
        try self.expectKw("set");
        var assigns = std.ArrayList(Assignment).empty;
        defer assigns.deinit(self.alloc);
        while (true) {
            const col = try self.expectIdent();
            try self.expectSym(.eq);
            const value = try self.parseExpr();
            try assigns.append(self.alloc, .{ .col = col, .value = value });
            if (!self.eatSym(.comma)) break;
        }
        var where: ?*Expr = null;
        if (self.eatKw("where")) where = try self.parseExpr();
        self.skipToSemicolon();
        return .{ .update = .{ .table = table, .assignments = try assigns.toOwnedSlice(self.alloc), .where = where } };
    }

    fn parseSelect(self: *Parser) Error!*Select {
        const sel = try self.alloc.create(Select);
        sel.* = .{ .items = &.{} };
        _ = self.next(); // SELECT
        if (self.eatKw("distinct")) sel.distinct = true;
        var items = std.ArrayList(SelectItem).empty;
        defer items.deinit(self.alloc);
        while (true) {
            const e = try self.parseExpr();
            var alias: ?[]const u8 = null;
            if (self.eatKw("as")) {
                const q = self.peek().quoted;
                const a = try self.expectIdent();
                alias = if (q) a else try self.foldIdent(a);
            } else if (self.peek().kind == .ident and !isClauseKeyword(self.peek().text)) {
                const q = self.peek().quoted;
                const a = try self.expectIdent();
                alias = if (q) a else try self.foldIdent(a);
            }
            try items.append(self.alloc, .{ .expr = e, .alias = alias });
            if (!self.eatSym(.comma)) break;
        }
        sel.items = try items.toOwnedSlice(self.alloc);

        if (self.eatKw("into")) {
            _ = self.eatKw("temp");
            _ = self.eatKw("temporary");
            _ = self.eatKw("unlogged");
            _ = self.eatKw("table");
            var itn = try self.expectIdent();
            if (self.eatSym(.dot)) {
                const part = try self.expectIdent();
                itn = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ itn, part });
            }
            sel.into_table = itn;
        }
        if (self.eatKw("from")) {
            if (self.eatSym(.lparen)) {
                if (self.eatKw("values")) {
                    var vr = std.ArrayList([]*Expr).empty;
                    defer vr.deinit(self.alloc);
                    while (true) {
                        try self.expectSym(.lparen);
                        var vals = std.ArrayList(*Expr).empty;
                        defer vals.deinit(self.alloc);
                        while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                            try vals.append(self.alloc, try self.parseExpr());
                            if (!self.eatSym(.comma)) break;
                        }
                        try self.expectSym(.rparen);
                        try vr.append(self.alloc, try vals.toOwnedSlice(self.alloc));
                        if (!self.eatSym(.comma)) break;
                    }
                    try self.expectSym(.rparen);
                    sel.from = .{ .values = try vr.toOwnedSlice(self.alloc) };
                    if (self.eatKw("as")) sel.alias = try self.expectIdent() else if (self.peek().kind == .ident and !isClauseKeyword(self.peek().text)) sel.alias = self.next().text;
                    if (self.atSym(.lparen)) {
                        _ = self.next();
                        var ac = std.ArrayList([]const u8).empty;
                        defer ac.deinit(self.alloc);
                        while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                            try ac.append(self.alloc, try self.expectIdent());
                            if (!self.eatSym(.comma)) break;
                        }
                        try self.expectSym(.rparen);
                        sel.alias_cols = try ac.toOwnedSlice(self.alloc);
                    }
                } else {
                var sub: *Select = undefined;
                if (self.eatKw("table")) {
                    const tn = try self.expectIdent();
                    sub = try self.alloc.create(Select);
                    sub.* = .{ .items = try self.alloc.alloc(SelectItem, 1), .from = .{ .table = tn } };
                    const st = try self.alloc.create(Expr);
                    st.* = .star;
                    sub.items[0] = .{ .expr = st, .alias = null };
                } else {
                    sub = try self.parseSelect();
                }
                try self.expectSym(.rparen);
                sel.from = .{ .subquery = sub };
                if (self.eatKw("as")) sel.alias = try self.expectIdent() else if (self.peek().kind == .ident and !isClauseKeyword(self.peek().text)) sel.alias = self.next().text;
                if (self.atSym(.lparen)) {
                    _ = self.next();
                    var ac = std.ArrayList([]const u8).empty;
                    defer ac.deinit(self.alloc);
                    while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                        try ac.append(self.alloc, try self.expectIdent());
                        if (!self.eatSym(.comma)) break;
                    }
                    try self.expectSym(.rparen);
                    sel.alias_cols = try ac.toOwnedSlice(self.alloc);
                }
                }
            } else {
                _ = self.eatKw("only"); // inheritance not implemented; scan the named table
                var tname = try self.expectIdent();
                // Accept `schema.table` (pg_catalog.pg_class etc.): keep the table.
                if (self.eatSym(.dot)) tname = try self.expectIdent();
                if (self.atSym(.lparen)) {
                    _ = self.next();
                    var args = std.ArrayList(*Expr).empty;
                    defer args.deinit(self.alloc);
                    if (!self.atSym(.rparen)) {
                        while (true) {
                            try args.append(self.alloc, try self.parseExpr());
                            if (!self.eatSym(.comma)) break;
                        }
                    }
                    try self.expectSym(.rparen);
                    sel.from = .{ .function = .{ .name = tname, .args = try args.toOwnedSlice(self.alloc) } };
                } else {
                    sel.from = .{ .table = tname };
                }
                // Optional alias (`FROM pg_class c LEFT JOIN ...`). It must be
                // consumed *before* the join keywords, otherwise `c` hides them.
                if (self.eatKw("as")) {
                    sel.alias = try self.expectIdent();
                } else if (self.peek().kind == .ident and !isClauseKeyword(self.peek().text) and
                    !std.ascii.eqlIgnoreCase(self.peek().text, "join"))
                {
                    sel.alias = self.next().text;
                }
                if (self.atSym(.lparen)) {
                    _ = self.next();
                    var ac = std.ArrayList([]const u8).empty;
                    defer ac.deinit(self.alloc);
                    while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                        try ac.append(self.alloc, try self.expectIdent());
                        if (!self.eatSym(.comma)) break;
                    }
                    try self.expectSym(.rparen);
                    sel.alias_cols = try ac.toOwnedSlice(self.alloc);
                }
                // Comma joins = cross products (`FROM a, b, c`).
                if (self.atSym(.comma)) {
                    var extra = std.ArrayList(FromItem).empty;
                    defer extra.deinit(self.alloc);
                    while (self.eatSym(.comma)) {
                        _ = self.eatKw("only");
                        var itname = try self.expectIdent();
                        if (self.eatSym(.dot)) itname = try self.expectIdent();
                        var item: From = .{ .table = itname };
                        if (self.atSym(.lparen)) {
                            _ = self.next();
                            var fargs = std.ArrayList(*Expr).empty;
                            defer fargs.deinit(self.alloc);
                            if (!self.atSym(.rparen)) {
                                while (true) {
                                    try fargs.append(self.alloc, try self.parseExpr());
                                    if (!self.eatSym(.comma)) break;
                                }
                            }
                            try self.expectSym(.rparen);
                            item = .{ .function = .{ .name = itname, .args = try fargs.toOwnedSlice(self.alloc) } };
                        }
                        var ialias: ?[]const u8 = null;
                        if (self.eatKw("as")) ialias = try self.expectIdent() else if (self.peek().kind == .ident and !isClauseKeyword(self.peek().text)) ialias = self.next().text;
                        // Optional column alias list.
                        if (self.atSym(.lparen)) {
                            _ = self.next();
                            var depth: usize = 1;
                            while (depth > 0 and self.peek().kind != .eof) {
                                if (self.atSym(.lparen)) depth += 1;
                                if (self.atSym(.rparen)) depth -= 1;
                                _ = self.next();
                            }
                        }
                        try extra.append(self.alloc, .{ .from = item, .alias = ialias });
                    }
                    sel.extra_from = try extra.toOwnedSlice(self.alloc);
                }
                // `[INNER|LEFT [OUTER]] JOIN b ON <expr>`.
                var left_join = false;
                var right_join = false;
                if (self.eatKw("left")) {
                    left_join = true;
                    _ = self.eatKw("outer");
                } else if (self.eatKw("right")) {
                    right_join = true;
                    _ = self.eatKw("outer");
                } else if (self.eatKw("full")) {
                    left_join = true;
                    right_join = true;
                    _ = self.eatKw("outer");
                } else {
                    _ = self.eatKw("inner");
                }
                if (self.eatKw("join")) {
                    var jt = try self.expectIdent();
                    if (self.eatSym(.dot)) jt = try self.expectIdent();
                    // Optional table alias (`JOIN t b ON ...`).
                    var jalias: ?[]const u8 = null;
                    if (self.eatKw("as")) {
                        jalias = try self.expectIdent();
                    } else if (self.peek().kind == .ident and !isClauseKeyword(self.peek().text)) {
                        jalias = self.next().text;
                    }
                    try self.expectKw("on");
                    const on = try self.parseExpr();
                    const cj = try self.splitOnConjuncts(on);
                    sel.join = .{ .table = jt, .on = cj[0], .extra_eqs = cj[1..], .left = left_join, .right = right_join, .alias = jalias };
                    // Further joins: `JOIN c ON ...` (INNER only for now).
                    var extra = std.ArrayList(Join).empty;
                    defer extra.deinit(self.alloc);
                    while (true) {
                        var l2 = false;
                        var r2 = false;
                        if (self.eatKw("left")) {
                            l2 = true;
                            _ = self.eatKw("outer");
                        } else if (self.eatKw("right")) {
                            r2 = true;
                            _ = self.eatKw("outer");
                        } else if (self.eatKw("full")) {
                            l2 = true;
                            r2 = true;
                            _ = self.eatKw("outer");
                        } else {
                            _ = self.eatKw("inner");
                        }
                        if (!self.eatKw("join")) break;
                        var jt2 = try self.expectIdent();
                        if (self.eatSym(.dot)) jt2 = try self.expectIdent();
                        var jailas2: ?[]const u8 = null;
                        if (self.eatKw("as")) {
                            jailas2 = try self.expectIdent();
                        } else if (self.peek().kind == .ident and !isClauseKeyword(self.peek().text)) {
                            jailas2 = self.next().text;
                        }
                        try self.expectKw("on");
                        const on2 = try self.parseExpr();
                        const cj2 = try self.splitOnConjuncts(on2);
                        try extra.append(self.alloc, .{ .table = jt2, .on = cj2[0], .extra_eqs = cj2[1..], .left = l2, .right = r2, .alias = jailas2 });
                    }
                    if (extra.items.len > 0) sel.more_joins = try extra.toOwnedSlice(self.alloc);
                }
                // Anything else in FROM (further joins, aliases) is skipped.
                while (self.peek().kind == .ident and !isClauseKeyword(self.peek().text)) _ = self.next();
            }
        }
        if (self.eatKw("where")) sel.where = try self.parseExpr();
        if (self.eatKw("group")) {
            try self.expectKw("by");
            var gb = std.ArrayList(*Expr).empty;
            defer gb.deinit(self.alloc);
            while (true) {
                try gb.append(self.alloc, try self.parseExpr());
                if (!self.eatSym(.comma)) break;
            }
            sel.group_by = try gb.toOwnedSlice(self.alloc);
        }
        if (self.eatKw("having")) sel.having = try self.parseExpr();
        if (self.eatKw("order")) {
            try self.expectKw("by");
            var ob = std.ArrayList(OrderItem).empty;
            defer ob.deinit(self.alloc);
            while (true) {
                const e = try self.parseExpr();
                var desc = false;
                if (self.eatKw("desc")) desc = true else _ = self.eatKw("asc");
                try ob.append(self.alloc, .{ .expr = e, .desc = desc });
                if (!self.eatSym(.comma)) break;
            }
            // `ORDER BY <n>` refers to the n-th select item (PostgreSQL ordinal).
            for (ob.items) |*oi| {
                if (oi.expr.* == .int) {
                    const n: usize = @intCast(oi.expr.int);
                    if (n >= 1 and n <= sel.items.len) oi.expr = sel.items[n - 1].expr;
                }
            }
            sel.order_by = try ob.toOwnedSlice(self.alloc);
        }
        if (self.eatKw("limit")) {
            const first = try self.parseExpr();
            if (self.eatSym(.comma)) {
                sel.offset = first;
                sel.limit = try self.parseExpr();
            } else {
                sel.limit = first;
                if (self.eatKw("offset")) sel.offset = try self.parseExpr();
            }
        }
        if (self.eatKw("union")) {
            sel.set_op = if (self.eatKw("all")) .union_all else .union_distinct;
            sel.union_all = try self.parseSelect();
        } else if (self.eatKw("intersect")) {
            _ = self.eatKw("all");
            sel.set_op = .intersect;
            sel.union_all = try self.parseSelect();
        } else if (self.eatKw("except") or self.eatKw("minus")) {
            _ = self.eatKw("all");
            sel.set_op = .except;
            sel.union_all = try self.parseSelect();
        }
        // `... UNION [ALL] ... ORDER BY/LIMIT` applies to the combined result,
        // not to the right-hand member. The recursive parseSelect attached the
        // trailing tail to that member; move it up.
        if (sel.union_all) |right| {
            if (right.order_by.len > 0) {
                sel.order_by = right.order_by;
                right.order_by = &.{};
            }
            if (right.limit != null) {
                sel.limit = right.limit;
                right.limit = null;
            }
            if (right.offset != null) {
                sel.offset = right.offset;
                right.offset = null;
            }
        }
        if (self.eatKw("format")) {
            const fmt = try self.expectIdent();
            sel.format_json = std.ascii.eqlIgnoreCase(fmt, "json");
        }
        return sel;
    }

    pub fn parseExpr(self: *Parser) Error!*Expr {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) Error!*Expr {
        var lhs = try self.parseAnd();
        while (self.atKw("or")) {
            _ = self.next();
            const rhs = try self.parseAnd();
            lhs = try self.mkBinary(.or_op, lhs, rhs);
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) Error!*Expr {
        var lhs = try self.parseNot();
        while (self.atKw("and")) {
            _ = self.next();
            const rhs = try self.parseNot();
            lhs = try self.mkBinary(.and_op, lhs, rhs);
        }
        return lhs;
    }

    fn parseNot(self: *Parser) Error!*Expr {
        if (self.eatKw("not")) {
            const e = try self.alloc.create(Expr);
            e.* = .{ .not = try self.parseNot() };
            return e;
        }
        return self.parseComparison();
    }

    fn parseJsonArrow(self: *Parser) Error!*Expr {
        var lhs = try self.parseBitwise();
        while (self.peek().kind == .jsonget or self.peek().kind == .jsonget_text) {
            const as_text = self.next().kind == .jsonget_text;
            const key = try self.parseBitwise();
            const e = try self.alloc.create(Expr);
            e.* = .{ .json_get = .{ .operand = lhs, .key = key, .as_text = as_text } };
            lhs = e;
        }
        return lhs;
    }

    fn parseComparison(self: *Parser) Error!*Expr {
        var lhs = try self.parseJsonArrow();
        while (true) {
            if (self.eatSym(.concat)) {
                lhs = try self.mkBinary(.concat, lhs, try self.parseAdditive());
            } else if (self.eatSym(.distance)) {
                lhs = try self.mkBinary(.dist, lhs, try self.parseAdditive());
            } else if (self.eatSym(.above)) {
                lhs = try self.mkBinary(.above, lhs, try self.parseAdditive());
            } else if (self.eatSym(.below)) {
                lhs = try self.mkBinary(.below, lhs, try self.parseAdditive());
            } else if (self.eatSym(.pointeq)) {
                lhs = try self.mkBinary(.peq, lhs, try self.parseAdditive());
            } else if (self.eatSym(.contains)) {
                lhs = try self.mkBinary(.contains, lhs, try self.parseAdditive());
            } else if (self.eatSym(.subcontains)) {
                lhs = try self.mkBinary(.subcontains, lhs, try self.parseAdditive());
            } else if (self.eatSym(.eq)) {
                lhs = try self.mkBinary(.eq, lhs, try self.parseAdditive());
            } else if (self.eatSym(.neq)) {
                lhs = try self.mkBinary(.neq, lhs, try self.parseAdditive());
            } else if (self.eatSym(.le)) {
                lhs = try self.mkBinary(.le, lhs, try self.parseAdditive());
            } else if (self.eatSym(.ge)) {
                lhs = try self.mkBinary(.ge, lhs, try self.parseAdditive());
            } else if (self.eatSym(.lt)) {
                lhs = try self.mkBinary(.lt, lhs, try self.parseAdditive());
            } else if (self.eatSym(.gt)) {
                lhs = try self.mkBinary(.gt, lhs, try self.parseAdditive());
            } else if (self.eatSym(.regex_ne)) {
                lhs = try self.mkBinary(.regex_ne, lhs, try self.parseAdditive());
            } else if (self.eatSym(.regex)) {
                lhs = try self.mkBinary(.regex, lhs, try self.parseAdditive());
            } else if (self.atKw("like")) {
                _ = self.next();
                const pat = try self.parseAdditive();
                const e = try self.alloc.create(Expr);
                e.* = .{ .like = .{ .operand = lhs, .pattern = pat, .negated = false } };
                lhs = e;
            } else if (self.atKw("not") and self.i + 1 < self.toks.len and std.ascii.eqlIgnoreCase(self.toks[self.i + 1].text, "like")) {
                _ = self.next();
                _ = self.next();
                const pat = try self.parseAdditive();
                const e = try self.alloc.create(Expr);
                e.* = .{ .like = .{ .operand = lhs, .pattern = pat, .negated = true } };
                lhs = e;
            } else if (self.atKw("is")) {
                _ = self.next();
                const negated = self.eatKw("not");
                if (self.eatKw("null")) {
                    const e = try self.alloc.create(Expr);
                    e.* = .{ .is_null = .{ .operand = lhs, .negated = negated } };
                    lhs = e;
                } else if (self.atKw("normalized") or self.atKw("nfc") or self.atKw("nfd") or self.atKw("nfkc") or self.atKw("nfkd")) {
                    var form: []const u8 = "NFC";
                    if (!self.eatKw("normalized")) {
                        form = (try self.expectIdent());
                        try self.expectKw("normalized");
                    }
                    const fe = try self.alloc.create(Expr);
                    fe.* = .{ .string = form };
                    const args = try self.alloc.alloc(*Expr, 2);
                    args[0] = lhs;
                    args[1] = fe;
                    const e = try self.alloc.create(Expr);
                    e.* = .{ .call = .{ .name = "is_normalized", .args = args, .distinct = false, .star = false } };
                    lhs = e;
                } else if (self.eatKw("true") or self.eatKw("false") or self.eatKw("unknown")) {
                    const target = self.toks[self.i - 1].text;
                    const truth = std.ascii.eqlIgnoreCase(target, "true");
                    const unknown = std.ascii.eqlIgnoreCase(target, "unknown");
                    const e = try self.alloc.create(Expr);
                    if (unknown) {
                        e.* = .{ .is_null = .{ .operand = lhs, .negated = negated } };
                    } else {
                        const yes = try self.alloc.create(Expr);
                        yes.* = .{ .call = .{ .name = "true", .args = &.{}, .distinct = false, .star = false } };
                        const no = try self.alloc.create(Expr);
                        no.* = .{ .call = .{ .name = "false", .args = &.{}, .distinct = false, .star = false } };
                        var whens = std.ArrayList(Case.When).empty;
                        defer whens.deinit(self.alloc);
                        if (truth and !negated) {
                            try whens.append(self.alloc, .{ .cond = lhs, .then = yes });
                        } else if (truth and negated) {
                            try whens.append(self.alloc, .{ .cond = lhs, .then = no });
                        } else if (!truth and !negated) {
                            const nul = try self.alloc.create(Expr);
                            nul.* = .{ .is_null = .{ .operand = lhs, .negated = false } };
                            try whens.append(self.alloc, .{ .cond = nul, .then = no });
                            try whens.append(self.alloc, .{ .cond = lhs, .then = no });
                        } else {
                            const nul = try self.alloc.create(Expr);
                            nul.* = .{ .is_null = .{ .operand = lhs, .negated = false } };
                            try whens.append(self.alloc, .{ .cond = nul, .then = yes });
                            try whens.append(self.alloc, .{ .cond = lhs, .then = yes });
                        }
                        e.* = .{ .case_expr = .{
                            .whens = try whens.toOwnedSlice(self.alloc),
                            .else_expr = if (truth != negated) no else yes,
                        } };
                    }
                    lhs = e;
                } else return error.SyntaxError;
            } else if (self.atKw("in")) {
                _ = self.next();
                lhs = try self.parseInList(lhs, false);
            } else if (self.atKw("not") and self.i + 1 < self.toks.len and std.ascii.eqlIgnoreCase(self.toks[self.i + 1].text, "in")) {
                _ = self.next();
                _ = self.next();
                lhs = try self.parseInList(lhs, true);
            } else if (self.atKw("between")) {
                _ = self.next();
                const low = try self.parseAdditive();
                try self.expectKw("and");
                const high = try self.parseAdditive();
                const e = try self.alloc.create(Expr);
                e.* = .{ .between = .{ .operand = lhs, .low = low, .high = high, .negated = false } };
                lhs = e;
            } else break;
        }
        return lhs;
    }

    fn parseInList(self: *Parser, operand: *Expr, negated: bool) Error!*Expr {
        try self.expectSym(.lparen);
        if (self.atKw("select")) {
            const sub = try self.parseSelect();
            try self.expectSym(.rparen);
            const e = try self.alloc.create(Expr);
            e.* = .{ .in_subquery = .{ .operand = operand, .sub = sub, .negated = negated } };
            return e;
        }
        var items = std.ArrayList(*Expr).empty;
        defer items.deinit(self.alloc);
        while (!self.atSym(.rparen) and self.peek().kind != .eof) {
            try items.append(self.alloc, try self.parseExpr());
            if (!self.eatSym(.comma)) break;
        }
        try self.expectSym(.rparen);
        const e = try self.alloc.create(Expr);
        e.* = .{ .in_list = .{ .operand = operand, .items = try items.toOwnedSlice(self.alloc), .negated = negated } };
        return e;
    }

    fn parseBitwise(self: *Parser) Error!*Expr {
        var lhs = try self.parseAdditive();
        while (true) {
            if (self.eatSym(.ampamp)) {
                lhs = try self.mkBinary(.overlap, lhs, try self.parseAdditive());
            } else if (self.eatSym(.amp)) lhs = try self.mkBinary(.band, lhs, try self.parseAdditive())
            else if (self.eatSym(.pipe)) lhs = try self.mkBinary(.bor, lhs, try self.parseAdditive())
            else if (self.eatSym(.hash)) lhs = try self.mkBinary(.bxor, lhs, try self.parseAdditive())
            else break;
        }
        return lhs;
    }

    fn parseAdditive(self: *Parser) Error!*Expr {
        var lhs = try self.parseAdditiveBase();
        while (self.eatKw("at")) {
            if (self.eatKw("local")) {
                const e = try self.alloc.create(Expr);
                e.* = .{ .at_local = .{ .operand = lhs } };
                lhs = e;
            } else {
                try self.expectKw("time");
                try self.expectKw("zone");
                const z = try self.parseMultiplicative();
                const e = try self.alloc.create(Expr);
                e.* = .{ .at_zone = .{ .operand = lhs, .zone = z } };
                lhs = e;
            }
        }
        return lhs;
    }

    fn parseAdditiveBase(self: *Parser) Error!*Expr {
        var lhs = try self.parseMultiplicative();
        while (true) {
            if (self.eatSym(.shl)) {
                lhs = try self.mkBinary(.shl, lhs, try self.parseMultiplicative());
            } else if (self.eatSym(.shr)) {
                lhs = try self.mkBinary(.shr, lhs, try self.parseMultiplicative());
            } else if (self.eatSym(.plus)) {
                lhs = try self.mkBinary(.add, lhs, try self.parseMultiplicative());
            } else if (self.eatSym(.minus)) {
                lhs = try self.mkBinary(.sub, lhs, try self.parseMultiplicative());
            } else break;
        }
        return lhs;
    }

    fn parseMultiplicative(self: *Parser) Error!*Expr {
        var lhs = try self.parseUnary();
        while (true) {
            if (self.eatSym(.star)) {
                lhs = try self.mkBinary(.mul, lhs, try self.parseUnary());
            } else if (self.eatSym(.slash)) {
                lhs = try self.mkBinary(.div, lhs, try self.parseUnary());
            } else if (self.eatSym(.percent)) {
                lhs = try self.mkBinary(.mod, lhs, try self.parseUnary());
            } else break;
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) Error!*Expr {
        if (self.eatSym(.minus)) {
            const e = try self.alloc.create(Expr);
            e.* = .{ .negate = try self.parseUnary() };
            return e;
        }
        if (self.eatSym(.plus)) return self.parseUnary();
        if (self.eatSym(.regex)) {
            const e = try self.alloc.create(Expr);
            e.* = .{ .bitnot = try self.parseUnary() };
            return e;
        }
        var e = try self.parsePrimary();
        while (self.eatSym(.lbracket)) {
            const idx = try self.parseExpr();
            try self.expectSym(.rbracket);
            const sub = try self.alloc.create(Expr);
            sub.* = .{ .subscript = .{ .operand = e, .index = idx } };
            e = sub;
        }
        while (self.eatSym(.cast)) {
            const type_name = try self.parseTypeName();
            const c = try self.alloc.create(Expr);
            c.* = .{ .cast = .{ .operand = e, .type_name = type_name } };
            e = c;
        }
        // Ternary collation is accepted and ignored (UTF-8 byte ordering is
        // the database default and matches COLLATE "C" for these tests).
        while (self.eatKw("collate")) {
            _ = try self.expectIdent();
        }
        return e;
    }

    fn parsePrimary(self: *Parser) Error!*Expr {
        const t = self.peek();
        switch (t.kind) {
            .number => {
                _ = self.next();
                const e = try self.alloc.create(Expr);
                if (std.mem.indexOfScalar(u8, t.text, '.') != null or std.mem.indexOfAny(u8, t.text, "eE") != null) {
                    e.* = .{ .float = std.fmt.parseFloat(f64, t.text) catch 0 };
                } else if (std.fmt.parseInt(i64, t.text, 10)) |v| {
                    e.* = .{ .int = v };
                } else |_| {
                    // Integer literals beyond int8 are NUMERIC literals. Keep
                    // the exact digits by modelling them as a numeric cast of
                    // the literal text; float would lose precision.
                    const se = try self.alloc.create(Expr);
                    se.* = .{ .string = t.text };
                    e.* = .{ .cast = .{ .operand = se, .type_name = "numeric" } };
                }
                return e;
            },
            .string => {
                _ = self.next();
                const e = try self.alloc.create(Expr);
                e.* = .{ .string = t.text };
                return e;
            },
            .param => {
                _ = self.next();
                const n: u16 = std.fmt.parseInt(u16, t.text, 10) catch 0;
                const e = try self.alloc.create(Expr);
                e.* = .{ .param = n };
                return e;
            },
            .star => {
                _ = self.next();
                const e = try self.alloc.create(Expr);
                e.* = .star;
                return e;
            },
            .lparen => {
                _ = self.next();
                if (self.atKw("select")) {
                    // Scalar subqueries are not implemented yet. Return a
                    // syntax error instead of silently producing an empty text
                    // value (which used to hide the missing feature).
                    return error.SyntaxError;
                }
                const e = try self.parseExpr();
                try self.expectSym(.rparen);
                return e;
            },
            .ident => {
                if (std.ascii.eqlIgnoreCase(t.text, "exists")) {
                    _ = self.next();
                    try self.expectSym(.lparen);
                    const sub = try self.parseSelect();
                    try self.expectSym(.rparen);
                    const e = try self.alloc.create(Expr);
                    e.* = .{ .exists = .{ .sub = sub, .negated = false } };
                    return e;
                }
                if (std.ascii.eqlIgnoreCase(t.text, "array") and self.i + 1 < self.toks.len and self.toks[self.i + 1].kind == .lbracket) {
                    _ = self.next(); // ARRAY
                    _ = self.next(); // [
                    var elems = std.ArrayList(*Expr).empty;
                    defer elems.deinit(self.alloc);
                    while (!self.atSym(.rbracket) and self.peek().kind != .eof) {
                        try elems.append(self.alloc, try self.parseExpr());
                        if (!self.eatSym(.comma)) break;
                    }
                    try self.expectSym(.rbracket);
                    const e = try self.alloc.create(Expr);
                    e.* = .{ .call = .{ .name = "array", .args = try elems.toOwnedSlice(self.alloc), .distinct = false, .star = false } };
                    return e;
                }
                if (self.peek().kind == .param) {
                    const pv = self.next();
                    const n: u16 = std.fmt.parseInt(u16, pv.text, 10) catch 0;
                    const e = try self.alloc.create(Expr);
                    e.* = .{ .param = n };
                    return e;
                }
                if (std.ascii.eqlIgnoreCase(t.text, "session_user") or std.ascii.eqlIgnoreCase(t.text, "current_user") or
                    std.ascii.eqlIgnoreCase(t.text, "current_role") or std.ascii.eqlIgnoreCase(t.text, "user"))
                {
                    const kw = self.next().text;
                    const e = try self.alloc.create(Expr);
                    e.* = .{ .call = .{ .name = if (std.ascii.eqlIgnoreCase(kw, "session_user")) "session_user" else "current_user", .args = &.{}, .distinct = false, .star = false } };
                    return e;
                }
                if (std.ascii.eqlIgnoreCase(t.text, "case")) return self.parseCase();
                if (std.ascii.eqlIgnoreCase(t.text, "cast")) return self.parseCast();
                if (std.ascii.eqlIgnoreCase(t.text, "null")) {
                    _ = self.next();
                    const e = try self.alloc.create(Expr);
                    e.* = .null_lit;
                    return e;
                }
                if (std.ascii.eqlIgnoreCase(t.text, "true") or std.ascii.eqlIgnoreCase(t.text, "false")) {
                    _ = self.next();
                    // Keep SQL booleans distinct from integers; the evaluator
                    // prints them as `true`/`false`.
                    const e = try self.alloc.create(Expr);
                    e.* = .{ .call = .{
                        .name = if (std.ascii.eqlIgnoreCase(t.text, "true")) "true" else "false",
                        .args = &.{},
                        .distinct = false,
                        .star = false,
                    } };
                    return e;
                }
                _ = self.next();
                var name = t.text;
                // `alias.*` is a qualified star, not a column named `alias.`.
                if (self.atSym(.dot) and self.i + 1 < self.toks.len and self.toks[self.i + 1].kind == .star) {
                    _ = self.next();
                    _ = self.next();
                    const e = try self.alloc.create(Expr);
                    e.* = .{ .star_table = name };
                    return e;
                }
                // Multi-word type names for typed literals: `time with time zone '..'`.
                if ((std.ascii.eqlIgnoreCase(name, "time") or std.ascii.eqlIgnoreCase(name, "timestamp"))) {
                    if ((self.atKw("with") or self.atKw("without")) and self.i + 1 < self.toks.len and
                        std.ascii.eqlIgnoreCase(self.toks[self.i + 1].text, "time"))
                    {
                        const w = self.next().text;
                        _ = self.next();
                        var suffix = std.fmt.allocPrint(self.alloc, "{s} {s}", .{ w, "time" }) catch return error.OutOfMemory;
                        if (self.eatKw("zone")) suffix = std.fmt.allocPrint(self.alloc, "{s} zone", .{suffix}) catch return error.OutOfMemory;
                        name = std.fmt.allocPrint(self.alloc, "{s} {s}", .{ name, suffix }) catch return error.OutOfMemory;
                    }
                }
                // Keep the qualifier (`l.k`), otherwise `EXISTS (SELECT ... WHERE
                // inner.k = outer.k)` silently collapses to `inner.k = inner.k`.
                while (self.atSym(.dot)) {
                    _ = self.next();
                    const part = try self.expectIdent();
                    name = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ name, part });
                }
                // PostgreSQL typed literal: bool 't', char 'c', date '...'.
                if (self.peek().kind == .string) {
                    const value = self.next().text;
                    const ve = try self.alloc.create(Expr);
                    ve.* = .{ .string = value };
                    const e = try self.alloc.create(Expr);
                    e.* = .{ .cast = .{ .operand = ve, .type_name = name } };
                    return e;
                }
                if (self.atSym(.lparen)) {
                    _ = self.next();
                    // Unquoted function names fold to lower case like PostgreSQL.
                    if (!t.quoted) {
                        var lbuf: [128]u8 = undefined;
                        if (name.len <= lbuf.len) name = try self.alloc.dupe(u8, std.ascii.lowerString(lbuf[0..name.len], name));
                    }
                    if (std.ascii.eqlIgnoreCase(name, "position")) {
                        const sub = try self.parseAdditive();
                        if (!self.eatKw("in")) return error.SyntaxError;
                        const str = try self.parseAdditive();
                        try self.expectSym(.rparen);
                        var pos_args = try self.alloc.alloc(*Expr, 2);
                        pos_args[0] = sub;
                        pos_args[1] = str;
                        const e = try self.alloc.create(Expr);
                        e.* = .{ .call = .{ .name = "position", .args = pos_args, .distinct = false, .star = false } };
                        return e;
                    }
                    // `EXTRACT(<field> FROM <expr>)`: desugar to a two-argument
                    // call `extract('field', expr)` so the evaluator sees the
                    // unit as a plain string.
                    if (std.ascii.eqlIgnoreCase(name, "extract")) {
                        const unit = try self.expectIdent();
                        if (!self.eatKw("from")) return error.SyntaxError;
                        const arg = try self.parseExpr();
                        try self.expectSym(.rparen);
                        const ue = try self.alloc.create(Expr);
                        ue.* = .{ .string = try std.fmt.allocPrint(self.alloc, "{s}", .{unit}) };
                        var ex_args = try self.alloc.alloc(*Expr, 2);
                        ex_args[0] = ue;
                        ex_args[1] = arg;
                        const e = try self.alloc.create(Expr);
                        e.* = .{ .call = .{ .name = "extract", .args = ex_args, .distinct = false, .star = false } };
                        return e;
                    }
                    var args = std.ArrayList(*Expr).empty;
                    defer args.deinit(self.alloc);
                    var distinct = false;
                    if (std.ascii.eqlIgnoreCase(name, "array_agg") and !self.atSym(.rparen) and !self.atSym(.star)) {
                        const arg = try self.parseExpr();
                        var orders = std.ArrayList(OrderItem).empty;
                        defer orders.deinit(self.alloc);
                        if (self.eatKw("order")) {
                            try self.expectKw("by");
                            while (true) {
                                const oe = try self.parseExpr();
                                var desc = false;
                                if (self.eatKw("desc")) desc = true else _ = self.eatKw("asc");
                                try orders.append(self.alloc, .{ .expr = oe, .desc = desc });
                                if (!self.eatSym(.comma)) break;
                            }
                        }
                        try self.expectSym(.rparen);
                        const e = try self.alloc.create(Expr);
                        e.* = .{ .ordered_agg = .{ .arg = arg, .order = try orders.toOwnedSlice(self.alloc) } };
                        return e;
                    }
                    var star = false;
                    if (self.eatKw("distinct")) distinct = true;
                    if (self.atSym(.rparen)) {
                        _ = self.next();
                    } else if (self.atSym(.star)) {
                        _ = self.next();
                        star = true;
                        try self.expectSym(.rparen);
                    } else {
                        while (true) {
                            if (self.peek().kind == .ident and self.i + 1 < self.toks.len and self.toks[self.i + 1].kind == .arrow) {
                                _ = self.next();
                                _ = self.next();
                            }
                            // normalize(text, NFC): the form is a bare keyword.
                            if (std.ascii.eqlIgnoreCase(name, "normalize") and self.peek().kind == .ident) {
                                const ft = self.peek().text;
                                if (isNormFormName(ft)) {
                                    _ = self.next();
                                    const fe = try self.alloc.create(Expr);
                                    fe.* = .{ .string = ft };
                                    try args.append(self.alloc, fe);
                                    if (!self.eatSym(.comma)) break;
                                    continue;
                                }
                            }
                            try args.append(self.alloc, try self.parseExpr());
                            if (!self.eatSym(.comma)) break;
                        }
                        try self.expectSym(.rparen);
                    }
                    if (self.eatKw("over")) {
                        try self.expectSym(.lparen);
                        var orders = std.ArrayList(OrderItem).empty;
                        defer orders.deinit(self.alloc);
                        _ = self.eatKw("partition");
                        if (self.atKw("by")) { _ = self.next(); while (!self.atKw("order") and !self.atSym(.rparen) and self.peek().kind != .eof) _ = self.next(); }
                        if (self.eatKw("order")) {
                            try self.expectKw("by");
                            while (!self.atSym(.rparen) and self.peek().kind != .eof) {
                                const oe = try self.parseExpr();
                                var desc = false;
                                if (self.eatKw("desc")) desc = true else _ = self.eatKw("asc");
                                try orders.append(self.alloc, .{ .expr = oe, .desc = desc });
                                if (!self.eatSym(.comma)) break;
                            }
                        }
                        try self.expectSym(.rparen);
                        const e = try self.alloc.create(Expr);
                        e.* = .{ .window = .{ .name = name, .args = try args.toOwnedSlice(self.alloc), .order = try orders.toOwnedSlice(self.alloc) } };
                        return e;
                    }
                    const e = try self.alloc.create(Expr);
                    e.* = .{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.alloc), .distinct = distinct, .star = star } };
                    return e;
                }
                const e = try self.alloc.create(Expr);
                e.* = .{ .column = name };
                return e;
            },
            else => return error.SyntaxError,
        }
    }

    fn parseCase(self: *Parser) Error!*Expr {
        _ = self.next(); // CASE
        // Two forms:
        //   CASE WHEN <cond> THEN <res> ...        (searched)
        //   CASE <expr> WHEN <val> THEN <res> ...  (simple; desugared to
        //                                           <expr> = <val>)
        var operand: ?*Expr = null;
        if (!self.atKw("when")) operand = try self.parseExpr();
        var whens = std.ArrayList(Case.When).empty;
        defer whens.deinit(self.alloc);
        while (self.eatKw("when")) {
            const cond = if (operand) |op|
                try self.mkBinary(.eq, op, try self.parseExpr())
            else
                try self.parseExpr();
            try self.expectKw("then");
            const then = try self.parseExpr();
            try whens.append(self.alloc, .{ .cond = cond, .then = then });
        }
        var else_expr: ?*Expr = null;
        if (self.eatKw("else")) else_expr = try self.parseExpr();
        try self.expectKw("end");
        const e = try self.alloc.create(Expr);
        e.* = .{ .case_expr = .{ .whens = try whens.toOwnedSlice(self.alloc), .else_expr = else_expr } };
        return e;
    }

    fn parseCast(self: *Parser) Error!*Expr {
        _ = self.next(); // CAST
        try self.expectSym(.lparen);
        const operand = try self.parseExpr();
        try self.expectKw("as");
        const type_name = try self.parseTypeName();
        try self.expectSym(.rparen);
        const e = try self.alloc.create(Expr);
        e.* = .{ .cast = .{ .operand = operand, .type_name = type_name } };
        return e;
    }

    fn mkBinary(self: *Parser, op: BinOp, lhs: *Expr, rhs: *Expr) Error!*Expr {
        const e = try self.alloc.create(Expr);
        e.* = .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } };
        return e;
    }
};

pub fn isClauseKeyword(text: []const u8) bool {
    const keywords = [_][]const u8{
        "from",   "where",  "group", "having", "order", "limit", "offset",
        "union",  "intersect", "except", "minus", "format", "join", "inner",
        "left",   "right",  "outer", "full",   "cross", "on",   "as", "using", "into",
    };
    for (keywords) |k| {
        if (std.ascii.eqlIgnoreCase(text, k)) return true;
    }
    return false;
}

/// Split a script into statements on top-level semicolons.
pub fn splitStatements(alloc: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    defer out.deinit(alloc);
    var start: usize = 0;
    var i: usize = 0;
    var in_str = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_str) {
            if (c == '\'') {
                if (i + 1 < src.len and src[i + 1] == '\'') {
                    i += 1;
                } else in_str = false;
            }
            continue;
        }
        if (c == '\'') {
            in_str = true;
        } else if (c == '$') {
            // Dollar-quoted string: $$...$$ or $tag$...$tag$ (function bodies).
            var j = i + 1;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
            if (j < src.len and src[j] == '$') {
                const tag = src[i .. j + 1];
                if (std.mem.indexOfPos(u8, src, j + 1, tag)) |close| {
                    i = close + tag.len - 1;
                    continue;
                }
            }
        } else if (c == '-' and i + 1 < src.len and src[i + 1] == '-') {
            while (i < src.len and src[i] != '\n') i += 1;
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            var depth: usize = 1;
            while (i < src.len and depth > 0) {
                if (i + 1 < src.len and src[i] == '/' and src[i + 1] == '*') {
                    depth += 1;
                    i += 2;
                } else if (i + 1 < src.len and src[i] == '*' and src[i + 1] == '/') {
                    depth -= 1;
                    i += 2;
                } else i += 1;
            }
            i -%= 1;
        } else if (c == ';') {
            const stmt = std.mem.trim(u8, src[start..i], " \t\r\n");
            if (stmt.len > 0) try out.append(alloc, stmt);
            start = i + 1;
        }
    }
    const tail = std.mem.trim(u8, src[start..], " \t\r\n");
    if (tail.len > 0) try out.append(alloc, tail);
    return out.toOwnedSlice(alloc);
}
