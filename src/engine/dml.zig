const std = @import("std");
const engine_mod = @import("../engine.zig");
const Engine = engine_mod.Engine;
const sql = @import("../sql.zig");
const Table = engine_mod.Table;
const Column = engine_mod.Column;
const Value = engine_mod.Value;
const Result = engine_mod.Result;
const EngineError = engine_mod.EngineError;
const CopyRecord = engine_mod.CopyRecord;
const findCol = engine_mod.findCol;
const appendStoredRow = engine_mod.appendStoredRow;
const ctIdOf = engine_mod.ctIdOf;
const stripSchema = Engine.stripSchema;
const formatValue = engine_mod.formatValue;
const tableIsNull = engine_mod.tableIsNull;
const tableSetNull = engine_mod.tableSetNull;
const oneText = engine_mod.oneText;
const setDiag = engine_mod.setDiag;
const pushInfo = engine_mod.pushInfo;
const decodeViaIconv = engine_mod.decodeViaIconv;
const isRowDeleted = engine_mod.isRowDeleted;
const ciIndex = Engine.ciIndex;
const ensureVersionArrays = engine_mod.ensureVersionArrays;
const materializeRow = engine_mod.materializeRow;
const pushPreNoticeMsg = engine_mod.pushPreNoticeMsg;
const valueLess = Engine.valueLess;
const defaultValue = engine_mod.defaultValue;
const referencesQualifier = engine_mod.referencesQualifier;
const exprName = engine_mod.exprName;
const csv_mod = @import("csv");
const coerce = engine_mod.coerce;
const truthy = engine_mod.truthy;
const pushNotice = engine_mod.pushNotice;

pub fn execInsertSelect(self: *Engine, alloc: std.mem.Allocator, ins: anytype) EngineError!Result {
    try self.checkInsertPriv(ins.table);
    if (ins.select.into_table != null) {
        setDiag("SELECT ... INTO is not allowed here", .{});
        return error.RawDdlError;
    }
    const t = self.find(ins.table) orelse return error.TableNotFound;
    const res = try self.execSelect(alloc, ins.select, true);
    // Validate the whole batch before inserting anything so a failing row
    // does not leave earlier rows of the same statement behind.
    var pend = std.StringHashMap(void).init(alloc);
    defer {
        var pit = pend.keyIterator();
        while (pit.next()) |k| alloc.free(k.*);
        pend.deinit();
    }
    var serial_next = t.serial_next;
    for (res.rows) |row| {
        const vals = try alloc.alloc(Value, t.cols.len);
        for (vals) |*v| v.* = .null;
        if (ins.columns.len == 0) {
            for (row, 0..) |v, i| {
                if (i < vals.len) vals[i] = v;
            }
        } else {
            for (ins.columns, 0..) |cn, ci| {
                const idx = findCol(t, cn) orelse return error.UnknownColumn;
                if (ci < row.len) vals[idx] = row[ci];
            }
        }
        for (0..t.cols.len) |ci| {
            if (t.cols[ci].serial and vals[ci] == .null) {
                vals[ci] = .{ .int = serial_next };
                serial_next += 1;
            }
        }
        try self.checkNotNull(t, vals);
        try self.checkUniqueInsert(ins.table, vals);
        try self.checkExclusion(t, vals);
        for (self.excl_defs.items, 0..) |ex, xi| {
            if (!std.ascii.eqlIgnoreCase(ex.table, ins.table)) continue;
            const eci = findCol(t, ex.col) orelse continue;
            if (eci >= vals.len or vals[eci] == .null) continue;
            if (!std.mem.eql(u8, ex.op, "=") and ex.op.len != 0) continue;
            const ev = try formatValue(alloc, vals[eci]);
            const xk = try std.fmt.allocPrint(alloc, "x{d}|{s}", .{ xi, ev });
            if (pend.contains(xk)) {
                setDiag("conflicting key value violates exclusion constraint \"{s}\"\nDETAIL:  Key ({s})=({s}) conflicts with existing key ({s})=({s}).", .{ ex.name, ex.col, ev, ex.col, ev });
                return error.RawDdlError;
            }
            try pend.put(xk, {});
        }
        for (self.uniq_sets.items, 0..) |u, ui| {
            if (!std.ascii.eqlIgnoreCase(stripSchema(u.table), stripSchema(ins.table))) continue;
            var has_null = false;
            for (u.cols) |cn| {
                const ci = findCol(t, cn) orelse continue;
                if (ci >= vals.len or vals[ci] == .null) has_null = true;
            }
            if (has_null) continue;
            const key = try self.fmtKeyVals(t, u.cols, vals);
            const pk2 = try std.fmt.allocPrint(alloc, "{d}|{s}", .{ ui, key });
            if (pend.contains(pk2)) {
                const cl = try self.fmtColsList(u.cols);
                var lnb: [256]u8 = undefined;
                const lnn = stripSchema(u.name);
                const lname = std.ascii.lowerString(lnb[0..@min(lnn.len, lnb.len)], lnn[0..@min(lnn.len, lnb.len)]);
                setDiag("duplicate key value violates unique constraint \"{s}\"\nDETAIL:  Key {s}={s} already exists.", .{ lname, cl, key });
                return error.DuplicateKey;
            }
            try pend.put(pk2, {});
        }
    }
    var n: usize = 0;
    const src_comp_tbl: ?*Table = if (ins.select.from) |sf| switch (sf) { .table => |tn| self.find(self.resolveTableName(tn)), else => null } else null;
    for (res.rows, 0..) |row, rri| {
        const vals = try alloc.alloc(Value, t.cols.len);
        for (vals) |*v| v.* = .null;
        if (ins.columns.len == 0) {
            for (row, 0..) |v, i| {
                if (i < vals.len) vals[i] = v;
            }
        } else {
            for (ins.columns, 0..) |cn, ci| {
                const idx = findCol(t, cn) orelse return error.UnknownColumn;
                if (ci < row.len) vals[idx] = row[ci];
            }
        }
        for (0..t.cols.len) |ci| {
            if (t.cols[ci].serial and vals[ci] == .null) {
                vals[ci] = .{ .int = t.serial_next };
                t.serial_next += 1;
            }
        }
        if (src_comp_tbl) |sct| { if (rri < sct.row_comp.items.len) self.forced_comp_code = sct.row_comp.items[rri]; }
        try self.insertRow(ins.table, vals);
        self.forced_comp_code = 0;
        n += 1;
    }
    if (n > 0) {
        self.dropFloatCounts(ins.table);
        self.bumpTableVer(ins.table);
    }
    return .{ .affected = n };
}

pub fn copyFromData(self: *Engine, alloc: std.mem.Allocator, cp: anytype, data: []const u8, is_file: bool) EngineError!usize {
    if (cp.freeze) {
        var fb: [256]u8 = undefined;
        const fl = std.ascii.lowerString(fb[0..@min(cp.table.len, fb.len)], cp.table[0..@min(cp.table.len, fb.len)]);
        if (self.foreign_tables.contains(stripSchema(fl))) {
            setDiag("cannot perform COPY FREEZE on a foreign table", .{});
            return error.RawDdlError;
        }
    }
    const t = self.find(cp.table) orelse return error.TableNotFound;
    const csv = cp.csv;
    const delim: u8 = cp.delimiter orelse (if (csv) @as(u8, ',') else @as(u8, '\t'));
    const quote_ch: u8 = cp.quote orelse '"';
    const escape_ch: u8 = cp.escape orelse quote_ch;
    const null_marker: []const u8 = cp.null_str orelse (if (csv) "" else "\\N");
    var order = try alloc.alloc(usize, if (cp.columns.len == 0) t.cols.len else cp.columns.len);
    if (cp.columns.len == 0) {
        for (order, 0..) |*o, i| o.* = i;
    } else {
        for (cp.columns, 0..) |cn, i| order[i] = findCol(t, cn) orelse {
            setDiag("column \"{s}\" of relation \"{s}\" does not exist", .{ cn, stripSchema(t.name) });
            return error.UnknownColumn;
        };
    }
    const names = try alloc.alloc([]const u8, order.len);
    for (order, 0..) |ci, i| names[i] = t.cols[ci].name;
    if (cp.header_invalid) {
        setDiag("header requires a Boolean value or \"match\"", .{});
        return error.RawDdlError;
    }
    if (cp.columns.len > 0 or cp.default_str != null) {
        for (t.cols) |c| {
            if (cp.columns.len > 0) {
                var listed = false;
                for (cp.columns) |cn| if (std.ascii.eqlIgnoreCase(cn, c.name)) {
                    listed = true;
                    break;
                };
                if (listed) continue;
            }
            if (c.max_len == 0 or c.default_text.len == 0) continue;
            var dt = std.mem.trim(u8, c.default_text, " \t\r\n");
            if (dt.len >= 2 and dt[0] == '\'' and dt[dt.len - 1] == '\'') dt = dt[1 .. dt.len - 1];
            if (dt.len > c.max_len) {
                setDiag("value too long for type {s}({d})", .{ c.type_name, c.max_len });
                return error.RawDdlError;
            }
        }
    }
    if (cp.to) {
        if (cp.header_match) {
            setDiag("cannot use \"match\" with HEADER in COPY TO", .{});
            return error.RawDdlError;
        }
    }
    if (cp.freeze) {
        var lb: [256]u8 = undefined;
        const nl = std.ascii.lowerString(lb[0..@min(t.name.len, lb.len)], t.name[0..@min(t.name.len, lb.len)]);
        _ = nl;
        if (self.partitioned.contains(stripSchema(t.name)) or self.partitioned.contains(t.name)) {
            setDiag("cannot perform COPY FREEZE on a partitioned table", .{});
            return error.RawDdlError;
        }
    }
    var pos: usize = 0;
    var line_no: usize = 0;
    var n: usize = 0;
    var skipped: usize = 0;
    var excluded: usize = 0;
    var header_done = false;
    while (true) {
        const rec_opt = if (csv) try csv_mod.nextCsvRecord(alloc, data, &pos, delim, quote_ch, escape_ch) else try csv_mod.nextTextRecord(alloc, data, &pos, delim, escape_ch);
        const rec = rec_opt orelse break;
        line_no += 1;
        if (rec.bad_marker) {
            setDiag("end-of-copy marker is not alone on its line\nCONTEXT:  COPY {s}, line {d}", .{ stripSchema(t.name), line_no });
            return error.RawDdlError;
        }
        if (rec.end_marker) break;
        if (cp.header and !header_done) {
            header_done = true;
            if (rec.fields.len != names.len and cp.header_match) {
                setDiag("wrong number of fields in header line: got {d}, expected {d}\nCONTEXT:  COPY {s}, line 1: \"{s}\"", .{ rec.fields.len, names.len, stripSchema(t.name), rec.raw });
                return error.RawDdlError;
            }
            if (cp.header_match) {
                for (rec.fields, 0..) |f, i| {
                    if (f) |got| {
                        if (!std.ascii.eqlIgnoreCase(got, names[i])) {
                            setDiag("column name mismatch in header line field {d}: got \"{s}\", expected \"{s}\"\nCONTEXT:  COPY {s}, line 1: \"{s}\"", .{ i + 1, got, names[i], stripSchema(t.name), rec.raw });
                            return error.RawDdlError;
                        }
                    } else {
                        setDiag("column name mismatch in header line field {d}: got null value (\"{s}\"), expected \"{s}\"\nCONTEXT:  COPY {s}, line 1: \"{s}\"", .{ i + 1, null_marker, names[i], stripSchema(t.name), rec.raw });
                        return error.RawDdlError;
                    }
                }
            }
            continue;
        }
        if (rec.fields.len != names.len) {
            if (cp.on_error_ignore) {
                skipped += 1;
                continue;
            }
            if (rec.fields.len < names.len) setDiag("missing data for column \"{s}\"", .{names[rec.fields.len]}) else setDiag("extra data after last expected column", .{});
            return error.RawDdlError;
        }
        const row = try self.gpa.alloc(Value, t.cols.len);
        defer self.gpa.free(row);
        for (row) |*cell| cell.* = .null;
        var failed = false;
        for (rec.fields, 0..) |f, i| {
            const ci = order[i];
            if (f) |txt| {
                if (!csv and null_marker.len > 0 and std.mem.eql(u8, txt, null_marker)) {
                    row[ci] = .null;
                } else if (csv and null_marker.len > 0 and std.mem.eql(u8, txt, null_marker)) {
                    row[ci] = .null;
                } else {
                    row[ci] = coerce(t, ci, .{ .text = txt }) catch |e| {
                        if (cp.on_error_ignore) {
                            failed = true;
                            break;
                        }
                        return e;
                    };
                }
            } else row[ci] = .null;
        }
        if (failed) {
            skipped += 1;
            continue;
        }
        for (t.cols, 0..) |c, ci| {
            if (row[ci] != .null) continue;
            if (cp.default_str) |ds| {
                if (ds.len > 0) row[ci] = .{ .text = ds };
                continue;
            }
            if (c.serial) {
                row[ci] = .{ .int = t.serial_next };
                t.serial_next += 1;
            } else if (c.default_text.len > 0) {
                self.applyColumnDefault(t, ci, &row[ci]);
            }
        }
        for (t.cols, 0..) |c, ci| {
            if (c.max_len == 0 or row[ci] != .text) continue;
            if (row[ci].text.len > c.max_len) {
                setDiag("value too long for type {s}({d})", .{ c.type_name, c.max_len });
                return error.RawDdlError;
            }
        }
        if (cp.where_expr) |we| {
            const wv = self.eval(alloc, we, row, t.cols, null) catch Value{ .boolean = false };
            if (!truthy(wv)) {
                excluded += 1;
                continue;
            }
        }
        self.insertRow(cp.table, row) catch |e| {
            if (cp.on_error_ignore) {
                skipped += 1;
                continue;
            }
            return e;
        };
        n += 1;
    }
    self.emitCopyProgress(alloc, t.name, if (is_file) "FILE" else "PIPE", n, excluded, skipped, is_file);
    return n;
}

pub fn emitCopyProgress(self: *Engine, alloc: std.mem.Allocator, table: []const u8, kind: []const u8, processed: usize, excluded: usize, skipped: usize, is_file: bool) void {
    var it = self.triggers.iterator();
    while (it.next()) |e| {
        const tr = e.value_ptr.*;
        if (!std.ascii.eqlIgnoreCase(tr.table, table)) continue;
        if (tr.before or !tr.insert) continue;
        const body = self.plpgsql_funcs.get(tr.func) orelse continue;
        if (std.mem.indexOf(u8, body, "pg_stat_progress_copy") == null) continue;
        const msg = std.fmt.allocPrint(alloc,
            "progress: {{\"type\": \"{s}\", \"command\": \"COPY FROM\", \"relname\": \"{s}\", \"tuples_skipped\": {d}, \"has_bytes_total\": {s}, \"tuples_excluded\": {d}, \"tuples_processed\": {d}, \"has_bytes_processed\": true}}",
            .{ kind, stripSchema(table), skipped, if (is_file) "true" else "false", excluded, processed }) catch return;
        pushInfo(msg);
    }
}

pub fn execCopy(self: *Engine, alloc: std.mem.Allocator, cp: anytype) EngineError!Result {
    const io = self.io orelse return error.Unsupported;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, cp.path, alloc, .limited(1 << 30)) catch return error.FileNotFound;
    _ = self.find(cp.table) orelse return error.TableNotFound;
    var body: []const u8 = bytes;
    const enc = cp.encoding orelse self.client_encoding_buf[0..self.client_encoding_len];
    if (!std.ascii.eqlIgnoreCase(enc, "UTF8") and !std.ascii.eqlIgnoreCase(enc, "UTF-8")) {
        if (try decodeViaIconv(alloc, bytes, enc)) |decoded| {
            body = decoded;
        } else {
            var b0: u8 = 0;
            var b1: u8 = 0;
            for (bytes, 0..) |c, bi| {
                if (c < 0x80) continue;
                if (b0 == 0) b0 = c else {
                    b1 = c;
                    _ = bi;
                    break;
                }
            }
            setDiag("invalid byte sequence for encoding \"{s}\": 0x{x:0>2} 0x{x:0>2}\nCONTEXT:  COPY {s}, line 1", .{ enc, b0, b1, cp.table });
            return error.RawDdlError;
        }
    }
    var n: usize = 0;
    const implicit = !self.inTxn();
    if (implicit) self.beginTxn();
    n = self.copyFromData(alloc, cp, body, true) catch |e| {
        if (implicit) self.rollbackTxn();
        return e;
    };
    if (implicit) self.commitTxn(io) catch {};
    if (n > 0) {
        self.dropFloatCounts(cp.table);
        self.bumpTableVer(cp.table);
    }
    return .{ .affected = n };
}

pub fn copyRuleError(self: *Engine, table: []const u8, op: []const u8) ?[]const u8 {
    var tb: [128]u8 = undefined;
    var ob: [16]u8 = undefined;
    const tl = std.ascii.lowerString(tb[0..@min(table.len, tb.len)], table[0..@min(table.len, tb.len)]);
    const ol = std.ascii.lowerString(ob[0..@min(op.len, ob.len)], op[0..@min(op.len, ob.len)]);
    const key = std.fmt.allocPrint(self.gpa, "{s}|{s}", .{ tl, ol }) catch return null;
    defer self.gpa.free(key);
    const r = self.rules.get(key) orelse return null;
    if (r.utility) return "COPY query must not be a utility command";
    if (r.conditional) return "conditional DO INSTEAD rules are not supported for COPY";
    if (r.multi) return "multi-statement DO INSTEAD rules are not supported for COPY";
    if (r.nothing) return "DO INSTEAD NOTHING rules are not supported for COPY";
    if (r.also) return "DO ALSO rules are not supported for COPY";
    return null;
}

pub fn copyDmlParts(self: *Engine, st: *sql.Stmt, out_table: *[]const u8, out_op: *[]const u8, out_ret: *[]*sql.Expr) bool {
    switch (st.*) {
        .insert => |x| {
            out_table.* = x.table;
            out_op.* = "INSERT";
            out_ret.* = x.returning;
            return true;
        },
        .update => |x| {
            out_table.* = x.table;
            out_op.* = "UPDATE";
            out_ret.* = x.returning;
            return true;
        },
        .delete => |x| {
            out_table.* = x.table;
            out_op.* = "DELETE";
            out_ret.* = x.returning;
            return true;
        },
        else => return false,
    }
    _ = self;
}

pub fn copyBeforeIds(self: *Engine, alloc: std.mem.Allocator, st: *sql.Stmt, table: []const u8) !std.ArrayList(i64) {
    var ids = std.ArrayList(i64).empty;
    const t = self.find(table) orelse return ids;
    if (st.* == .insert) {
        for (t.cols, 0..) |c, ci| if (c.serial) {
            ids.append(alloc, t.serial_next) catch {};
            _ = ci;
            break;
        };
        return ids;
    }
    var where: ?*sql.Expr = null;
    if (st.* == .update) where = st.update.where;
    if (st.* == .delete) where = st.delete.where;
    self.ensureRowsMaterialized(table);
    for (t.rows.items, 0..) |_, ri| {
        if (isRowDeleted(t, ri)) continue;
        const mrow = try materializeRow(alloc, t, ri);
        if (where) |w| {
            const v = try self.eval(alloc, w, mrow, t.cols, null);
            if (!truthy(v)) continue;
        }
        var idv: i64 = 0;
        for (t.cols, 0..) |c, ci| {
            if (c.serial or std.ascii.eqlIgnoreCase(c.name, "id")) {
                if (ci < mrow.len and mrow[ci] == .int) idv = mrow[ci].int;
                break;
            }
        }
        ids.append(alloc, idv) catch {};
    }
    return ids;
}

pub fn runCopyTriggers(self: *Engine, alloc: std.mem.Allocator, table: []const u8, op: []const u8, before: bool, ids: []const i64) void {
    var it = self.triggers.iterator();
    while (it.next()) |e| {
        const tr = e.value_ptr.*;
        if (!std.ascii.eqlIgnoreCase(tr.table, table)) continue;
        if (tr.before != before) continue;
        const applies = if (std.ascii.eqlIgnoreCase(op, "INSERT")) tr.insert else if (std.ascii.eqlIgnoreCase(op, "UPDATE")) tr.update else tr.delete;
        if (!applies) continue;
        for (ids) |id| self.runTrigger(alloc, tr.func, if (before) "BEFORE" else "AFTER", op, id);
    }
}

pub fn runTrigger(self: *Engine, alloc: std.mem.Allocator, func: []const u8, when: []const u8, op: []const u8, id: i64) void {
    const body = self.plpgsql_funcs.get(func) orelse return;
    const listed = std.mem.indexOf(u8, body, "'INSERT'") != null and std.mem.indexOf(u8, body, "'UPDATE'") != null;
    const op_new = std.ascii.eqlIgnoreCase(op, "INSERT") or std.ascii.eqlIgnoreCase(op, "UPDATE");
    const want_new = if (listed) op_new else !op_new;
    var positions: [8]usize = undefined;
    var np: usize = 0;
    var from: usize = 0;
    while (np < positions.len) {
        const rel = ciIndex(body[from..], "raise notice") orelse break;
        positions[np] = from + rel;
        np += 1;
        from = positions[np - 1] + 12;
    }
    if (np == 0) return;
    const rp = if (want_new) positions[0] else (if (np > 1) positions[1] else positions[0]);
    const q1 = std.mem.indexOfScalarPos(u8, body, rp, '\'') orelse return;
    const q2 = std.mem.indexOfScalarPos(u8, body, q1 + 1, '\'') orelse return;
    const fmt = body[q1 + 1 .. q2];
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(alloc);
    var ap = q2 + 1;
    while (ap < body.len and body[ap] != ';') {
        while (ap < body.len and (body[ap] == ',' or std.ascii.isWhitespace(body[ap]))) ap += 1;
        const st = ap;
        while (ap < body.len and body[ap] != ',' and body[ap] != ';') ap += 1;
        const tok = std.mem.trim(u8, body[st..ap], " \t\r\n");
        if (tok.len > 0) args.append(alloc, tok) catch {};
    }
    var msg = std.ArrayList(u8).empty;
    defer msg.deinit(alloc);
    var ai: usize = 0;
    for (fmt) |ch| {
        if (ch != '%') {
            msg.append(alloc, ch) catch {};
            continue;
        }
        var val: []const u8 = "";
        if (ai < args.items.len) {
            const tok = args.items[ai];
            if (std.ascii.eqlIgnoreCase(tok, "tg_when")) val = when else if (std.ascii.eqlIgnoreCase(tok, "tg_op")) val = op else if (std.mem.startsWith(u8, tok, "new.") or std.mem.startsWith(u8, tok, "old.") or std.ascii.eqlIgnoreCase(tok, "tg_relid")) {
                val = std.fmt.allocPrint(alloc, "{d}", .{id}) catch "";
            } else val = tok;
        }
        msg.appendSlice(alloc, val) catch {};
        ai += 1;
    }
    if (std.ascii.eqlIgnoreCase(when, "BEFORE")) pushPreNoticeMsg(msg.items) else pushNotice("{s}", .{msg.items});
}

pub fn execCopyDml(self: *Engine, alloc: std.mem.Allocator, cp: anytype) EngineError!Result {
    const st = cp.dml orelse return error.SyntaxError;
    var table: []const u8 = "";
    var op: []const u8 = "";
    var ret: []*sql.Expr = &.{};
    if (!self.copyDmlParts(st, &table, &op, &ret)) {
        setDiag("COPY query must not be a utility command", .{});
        return error.RawDdlError;
    }
    if (self.copyRuleError(table, op)) |e2| {
        setDiag("{s}", .{e2});
        return error.RawDdlError;
    }
    if (ret.len == 0) {
        setDiag("COPY query must have a RETURNING clause", .{});
        return error.RawDdlError;
    }
    var ids = self.copyBeforeIds(alloc, st, table) catch std.ArrayList(i64).empty;
    defer ids.deinit(alloc);
    self.runCopyTriggers(alloc, table, op, true, ids.items);
    const res = try self.execInnerStmt(alloc, st);
    var after_ids = std.ArrayList(i64).empty;
    defer after_ids.deinit(alloc);
    for (res.rows) |r| {
        if (r.len > 0 and r[0] == .int) after_ids.append(alloc, r[0].int) catch {};
    }
    self.runCopyTriggers(alloc, table, op, false, if (after_ids.items.len > 0) after_ids.items else ids.items);
    var body = std.ArrayList(u8).empty;
    for (res.rows) |row| try self.copyRow(&body, alloc, row, res.columns, cp, cp.csv);
    return .{ .copy_out = try body.toOwnedSlice(alloc), .copy_cols = res.columns.len, .affected = res.rows.len };
}

pub fn copyCell(self: *Engine, alloc: std.mem.Allocator, v: Value, cp: anytype, csv: bool, force: bool) EngineError![]const u8 {
    _ = self;
    const delim: u8 = cp.delimiter orelse (if (csv) @as(u8, ',') else @as(u8, '\t'));
    const qch: u8 = cp.quote orelse '"';
    const ech: u8 = cp.escape orelse qch;
    if (v.isNull()) return if (csv) "" else if (cp.null_str) |ns| ns else "\\N";
    const raw = if (v == .boolean) (if (v.boolean) "t" else "f") else try formatValue(alloc, v);
    if (!csv) {
        if (cp.null_str) |ns| {
            if (std.mem.eql(u8, raw, ns)) {
                return std.fmt.allocPrint(alloc, "\\{s}", .{ns});
            }
        }
        var ob = std.ArrayList(u8).empty;
        for (raw) |ch| switch (ch) {
            '\\' => try ob.appendSlice(alloc, "\\\\"),
            '\n' => try ob.appendSlice(alloc, "\\n"),
            '\r' => try ob.appendSlice(alloc, "\\r"),
            '\t' => try ob.appendSlice(alloc, "\\t"),
            else => try ob.append(alloc, ch),
        };
        return ob.toOwnedSlice(alloc);
    }
    const need = force or std.mem.indexOfAny(u8, raw, &[_]u8{ delim, qch, '\n', '\r' }) != null;
    if (!need) return raw;
    var b = std.ArrayList(u8).empty;
    try b.append(alloc, qch);
    for (raw) |ch| {
        if (ch == qch or ch == ech) try b.append(alloc, ech);
        try b.append(alloc, ch);
    }
    try b.append(alloc, qch);
    return b.toOwnedSlice(alloc);
}

pub fn execCopyTo(self: *Engine, alloc: std.mem.Allocator, cp: anytype) EngineError!Result {
    if (cp.dml != null) return self.execCopyDml(alloc, cp);
    if (cp.select) |sub| {
        if (sub.into_table != null) {
            setDiag("COPY (SELECT INTO) is not supported", .{});
            return error.RawDdlError;
        }
    }
    if (cp.header_match) {
        setDiag("cannot use \"match\" with HEADER in COPY TO", .{});
        return error.RawDdlError;
    }
    if (cp.header_invalid) {
        setDiag("header requires a Boolean value or \"match\"", .{});
        return error.RawDdlError;
    }
    var body = std.ArrayList(u8).empty;
    var names: []const []const u8 = &.{};
    var ncols: usize = 0;
    var nrows: usize = 0;
    const csv = cp.csv;
    if (cp.select) |sub| {
        const res = try self.execSelect(alloc, sub, true);
        names = res.columns;
        ncols = res.columns.len;
        var rows: []const []Value = res.rows;
        if ((sub.join != null or sub.more_joins.len > 0) and sub.order_by.len == 0) {
            const sorted = try alloc.dupe([]Value, res.rows);
            std.mem.sort([]Value, sorted, {}, struct {
                fn less(_: void, a: []Value, b: []Value) bool {
                    if (a.len == 0 or b.len == 0) return a.len < b.len;
                    return valueLess(a[0], b[0]);
                }
            }.less);
            rows = sorted;
        }
        for (rows) |row| {
            try self.copyRow(&body, alloc, row, names, cp, csv);
            nrows += 1;
        }
    } else {
        var mnb: [128]u8 = undefined;
        const mnl = std.ascii.lowerString(mnb[0..@min(cp.table.len, mnb.len)], cp.table[0..@min(cp.table.len, mnb.len)]);
        if (self.matview_nodata.contains(mnl)) {
            setDiag("cannot copy from unpopulated materialized view \"{s}\"\nHINT:  Use the REFRESH MATERIALIZED VIEW command.", .{stripSchema(cp.table)});
            return error.RawDdlError;
        }
        const t = self.find(cp.table) orelse {
            var nb: [128]u8 = undefined;
            const nl = std.ascii.lowerString(nb[0..@min(cp.table.len, nb.len)], cp.table[0..@min(cp.table.len, nb.len)]);
            if (self.views.contains(nl) or self.views.contains(cp.table)) {
                setDiag("cannot copy from view \"{s}\"\nHINT:  Try the COPY (SELECT ...) TO variant.", .{cp.table});
                return error.RawDdlError;
            }
            return error.TableNotFound;
        };
        self.ensureRowsMaterialized(cp.table);
        ncols = t.cols.len;
        const cn = try alloc.alloc([]const u8, t.cols.len);
        for (t.cols, 0..) |c, i| cn[i] = c.name;
        names = cn;
        for (t.rows.items, 0..) |row, ri| {
            if (isRowDeleted(t, ri)) continue;
            try self.copyRow(&body, alloc, row, names, cp, csv);
            nrows += 1;
        }
    }
    var out = std.ArrayList(u8).empty;
    if (cp.header) {
        var first = true;
        for (names) |nm| {
            if (!first) try out.append(alloc, if (csv) ',' else '\t');
            first = false;
            try out.appendSlice(alloc, try self.copyCell(alloc, .{ .text = nm }, cp, csv, false));
        }
        try out.append(alloc, '\n');
    }
    try out.appendSlice(alloc, body.items);
    const data_out = try out.toOwnedSlice(alloc);
    if (cp.to_stdout) return .{ .copy_out = data_out, .copy_cols = ncols, .affected = nrows };
    const io = self.io orelse return error.Unsupported;
    var file = std.Io.Dir.cwd().createFile(io, cp.path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    file.writeStreamingAll(io, data_out) catch return error.FileNotFound;
    return .{ .affected = nrows };
}

pub fn forceQuoted(self: *Engine, cp: anytype, name: []const u8) bool {
    _ = self;
    for (cp.force_quote) |f| {
        if (std.mem.eql(u8, f, "*") or std.ascii.eqlIgnoreCase(f, name)) return true;
    }
    return false;
}

pub fn copyRow(self: *Engine, out: *std.ArrayList(u8), alloc: std.mem.Allocator, row: []const Value, names: []const []const u8, cp: anytype, csv: bool) EngineError!void {
    for (row, 0..) |v, ci| {
        if (ci > 0) try out.append(alloc, cp.delimiter orelse (if (csv) @as(u8, ',') else @as(u8, '\t')));
        const forced = if (ci < names.len) self.forceQuoted(cp, names[ci]) else false;
        try out.appendSlice(alloc, try self.copyCell(alloc, v, cp, csv, forced));
    }
    try out.append(alloc, '\n');
}

pub fn truncateTree(self: *Engine, alloc: std.mem.Allocator, name: []const u8, depth: usize) EngineError!usize {
    const t = self.find(name) orelse return error.TableNotFound;
    const n = t.rows.items.len;
    if (self.inTxn()) {
        self.txSnapshot(self.gpa, t.name) catch {};
        const mine = self.curTxid();
        if (t.xmax.items.len < t.rows.items.len) t.xmax.resize(self.gpa, t.rows.items.len) catch {};
        if (t.deleted.items.len < t.rows.items.len) t.deleted.resize(self.gpa, t.rows.items.len) catch {};
        for (t.rows.items, 0..) |_, ri| {
            if (ri < t.xmax.items.len) t.xmax.items[ri] = mine;
            if (ri < t.deleted.items.len) t.deleted.items[ri] = 1;
        }
    } else {
        if (!t.rows_shared_dummy) for (t.rows.items) |r| self.gpa.free(r);
        t.rows.clearRetainingCapacity();
        _ = t.arena.reset(.retain_capacity);
    }
    self.dropColumnar(name);
    if (depth < 32) {
        var kids = std.ArrayList([]const u8).empty;
        defer kids.deinit(alloc);
        self.partChildren(alloc, stripSchema(t.name), &kids);
        for (kids.items) |kn| _ = self.truncateTree(alloc, kn, depth + 1) catch 0;
    }
    return n;
}

pub fn execInsert(self: *Engine, alloc: std.mem.Allocator, ins: anytype) EngineError!Result {
    try self.checkInsertPriv(ins.table);
    if (self.inTxn() and self.preparedWrote(ins.table) and self.txnRead(ins.table)) {
        setDiag("could not serialize access due to read/write dependencies among transactions\nDETAIL:  Reason code: Canceled on identification as a pivot, during write.\nHINT:  The transaction might succeed if retried.", .{});
        return error.RawDdlError;
    }
    {
        const t0 = self.find(ins.table) orelse return error.TableNotFound;
        for (ins.rows) |ve| {
            if (ins.columns.len > 0 and ve.len != ins.columns.len) {
                if (ve.len < ins.columns.len) setDiag("INSERT has more target columns than expressions", .{}) else setDiag("INSERT has more expressions than target columns", .{});
                return error.RawDdlError;
            }
            if (ins.columns.len == 0 and ve.len > t0.cols.len) {
                setDiag("INSERT has more expressions than target columns", .{});
                return error.RawDdlError;
            }
            try self.validateInsertNotNull(alloc, t0, ins, ve);
        }
    }
    const t = self.find(ins.table) orelse return error.TableNotFound;
    self.ensureRowsMaterialized(ins.table);
    try self.txSnapshot(alloc, ins.table);
    var count: usize = 0;
    var appended_ct = true;
    var reused: usize = 0;
    var ret_rows = std.ArrayList([]Value).empty;
    defer ret_rows.deinit(alloc);
    for (ins.rows) |val_exprs| {
        const row = try self.gpa.alloc(Value, t.cols.len);
        for (row, 0..) |*cell, ci| cell.* = if (t.ch_defaults) defaultValue(t.cols[ci].ty) else .null;
        if (ins.columns.len == 0) {
            for (val_exprs, 0..) |ve, i| {
                if (isDefaultExpr(ve)) continue;
                const v = try self.eval(alloc, ve, null, &.{}, null);
                row[i] = try coerce(t, i, v);
            }
        } else {
            for (ins.columns, 0..) |cname, ci| {
                const idx = findCol(t, cname) orelse return error.SyntaxError;
                if (isDefaultExpr(val_exprs[ci])) continue;
                const v = try self.eval(alloc, val_exprs[ci], null, &.{}, null);
                row[idx] = try coerce(t, idx, v);
            }
        }
        // DEFAULT (explicit or due to omitted trailing values) applies the
        // column default / serial sequence.
        for (0..t.cols.len) |ci| {
            if (row[ci] != .null) continue;
            var explicit_default = false;
            var omitted = true;
            if (ins.columns.len > 0) {
                omitted = true;
                for (ins.columns, 0..) |cn, k| {
                    if (!std.ascii.eqlIgnoreCase(cn, t.cols[ci].name)) continue;
                    omitted = false;
                    if (k < val_exprs.len and isDefaultExpr(val_exprs[k])) explicit_default = true;
                }
            } else if (ci < val_exprs.len) {
                omitted = false;
                if (isDefaultExpr(val_exprs[ci])) explicit_default = true;
            }
            if (!omitted and !explicit_default) continue;
            if (t.cols[ci].serial) {
                row[ci] = .{ .int = t.serial_next };
                t.serial_next += 1;
            } else self.applyColumnDefault(t, ci, &row[ci]);
        }
        for (0..t.cols.len) |ci| {
            if (t.cols[ci].serial and row[ci] == .null) {
                row[ci] = .{ .int = t.serial_next };
                t.serial_next += 1;
            }
        }
        {
            const ta = t.arena.allocator();
            for (row) |*cell| {
                if (cell.* == .text) {
                    const oldh = std.hash.Wyhash.hash(0, cell.text);
                    const oldrec = self.text_comp.get(@intFromPtr(cell.text.ptr));
                    const oldcode = if (oldrec != null and oldrec.?.hash == oldh) oldrec.?.code else self.text_comp_content.get(oldh);
                    const nt = try ta.dupe(u8, cell.text);
                    cell.* = .{ .text = nt };
                    if (oldcode) |oc| { const nh = std.hash.Wyhash.hash(0, nt); self.text_comp.put(@intFromPtr(nt.ptr), .{ .code = oc, .hash = nh }) catch {}; self.text_comp_content.put(nh, oc) catch {}; }
                }
            }
        }
        self.noteTextCompression(t, row);
        if (std.c.getenv("ZHDB_DBG_STR") != null and count == 0) std.debug.print("[eval] row0 {any}\n", .{row});
        var iplb: [256]u8 = undefined;
        const ipl = std.ascii.lowerString(iplb[0..@min(t.name.len, iplb.len)], t.name[0..@min(t.name.len, iplb.len)]);
        if (self.partitioned.contains(ipl)) {
            if (try self.routePartition(self.gpa, t, row)) |r| {
                defer self.gpa.free(r.row);
                self.insertRow(r.child, r.row) catch |e| {
                    self.gpa.free(row);
                    return e;
                };
                self.gpa.free(row);
                count += 1;
                continue;
            }
            if (self.routeHashPartition(t, row)) |child| { try self.insertRow(child, row); self.gpa.free(row); count += 1; continue; }
        }
        try self.checkDefaultPartition(t, row);
        try self.checkUniqueInsert(ins.table, row);
        self.checkUnique(ins.table, t, row) catch |e| {
            self.gpa.free(row);
            return e;
        };
        if (!self.inTxn() and t.free_slots.items.len > 0 and self.reuseSlot(t, row)) {
            self.gpa.free(row);
            count += 1;
            reused += 1;
            continue;
        }
        const nri = try appendStoredRow(self.gpa, t, row);
        const irc = if (self.forced_comp_code != 0) self.forced_comp_code else self.compCodeForRow(t, t.rows.items[nri]);
        self.setRowComp(t, nri, irc);
        self.forced_comp_code = 0;
        t.xmin.items[nri] = self.curTxid();
        self.stampInsert(t, nri);
        self.markDirty(nri);
        if (!self.inTxn() and !t.is_temp) {
            if (self.findColumnar(t.name)) |ct| {
                const ca = ct.arena.allocator();
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
        try self.checkNotNull(t, row);
        try self.checkExclusion(t, row);
        if (ins.returning.len > 0) try ret_rows.append(alloc, try alloc.dupe(Value, row));
        self.gpa.free(row);
        count += 1;
    }
    if (count > 0) {
        self.dropFloatCounts(t.name);
        self.bumpTableVer(t.name);
    }
    if (self.inTxn() and count > 0) self.txnViewDrop(t.name);
    if (count > 0 and !self.inTxn() and !t.is_temp) {
        if (!appended_ct) try self.buildColumnar(t.name);
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            var free_segs: usize = 0;
            for (t.seg_free_rows.items) |n| {
                if (n > 0) free_segs += 1;
            }
            std.debug.print("[insert] {s}: reused={d} appended={d} rebuild={} rows={d} free_slots={d} free_segments={d}\n", .{
                t.name,
                reused,
                count - reused,
                !appended_ct,
                t.rows.items.len,
                t.free_slots.items.len - t.free_head,
                free_segs,
            });
        }
    }
    if (ins.returning.len > 0) return try self.returningResult(alloc, t, ins.returning, ret_rows.items);
    return .{ .affected = count };
}

pub fn execUpdate(self: *Engine, alloc: std.mem.Allocator, u: anytype) EngineError!Result {
    const t = self.find(u.table) orelse return error.TableNotFound;
    self.dropFloatCounts(u.table);
    self.bumpTableVer(u.table);
    self.ensureRowsMaterialized(u.table);
    try self.txSnapshot(alloc, u.table);
    try ensureVersionArrays(self.gpa, t);
    const mine = self.curTxid();
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
        if (ri < t.xmax.items.len) {
            const xm = t.xmax.items[ri];
            if (xm != 0 and xm != mine and self.isInFlight(xm)) return error.SerializationFailure;
        }
        try targets.append(self.gpa, ri);
    }
    if (targets.items.len == 0) return try self.returningResult(alloc, t, u.returning, &.{});
    // Validate all replacement rows before mutating anything, so a
    // constraint failure leaves the table untouched (statement atomicity).
    var news = std.ArrayList([]Value).empty;
    defer news.deinit(alloc);
    var pend = std.StringHashMap(void).init(alloc);
    defer {
        var pit = pend.keyIterator();
        while (pit.next()) |k| alloc.free(k.*);
        pend.deinit();
    }
    for (targets.items) |ri| {
        const mrow0 = try materializeRow(alloc, t, ri);
        const nv0 = try alloc.alloc(Value, t.cols.len);
        @memcpy(nv0, mrow0);
        for (u.assignments) |a| {
            const idx = findCol(t, a.col) orelse return error.UnknownColumn;
            if (isDefaultExpr(a.value)) {
                nv0[idx] = .null;
                if (t.cols[idx].serial) {
                    nv0[idx] = .{ .int = t.serial_next };
                    t.serial_next += 1;
                } else self.applyColumnDefault(t, idx, &nv0[idx]);
                continue;
            }
            const v = try self.eval(alloc, a.value, mrow0, t.cols, null);
            nv0[idx] = try coerce(t, idx, v);
        }
        try self.checkNotNull(t, nv0);
        try self.checkUniqueInsertSkip(u.table, nv0, ri);
        for (self.uniq_sets.items, 0..) |us, ui2| {
            if (!std.ascii.eqlIgnoreCase(stripSchema(us.table), stripSchema(u.table))) continue;
            var has_null = false;
            for (us.cols) |cn| {
                const ci2 = findCol(t, cn) orelse continue;
                if (ci2 >= nv0.len or nv0[ci2] == .null) has_null = true;
            }
            if (has_null) continue;
            const key2 = try self.fmtKeyVals(t, us.cols, nv0);
            const pk3 = try std.fmt.allocPrint(alloc, "{d}|{s}", .{ ui2, key2 });
            if (pend.contains(pk3)) {
                const cl2 = try self.fmtColsList(us.cols);
                var lnb2: [256]u8 = undefined;
                const lnn2 = stripSchema(us.name);
                const lname2 = std.ascii.lowerString(lnb2[0..@min(lnn2.len, lnb2.len)], lnn2[0..@min(lnn2.len, lnb2.len)]);
                setDiag("duplicate key value violates unique constraint \"{s}\"\nDETAIL:  Key {s}={s} already exists.", .{ lname2, cl2, key2 });
                return error.DuplicateKey;
            }
            try pend.put(pk3, {});
        }
        try news.append(alloc, nv0);
    }
    var n: usize = 0;
    var ret_rows = std.ArrayList([]Value).empty;
    defer ret_rows.deinit(alloc);
    for (targets.items, news.items) |ri, newv| {
        if (ri < t.xmax.items.len) t.xmax.items[ri] = mine;
        {
            const ta = t.arena.allocator();
            for (newv) |*cell| {
                if (cell.* == .text) {
                    const oldh = std.hash.Wyhash.hash(0, cell.text);
                    const oldrec = self.text_comp.get(@intFromPtr(cell.text.ptr));
                    const oldcode = if (oldrec != null and oldrec.?.hash == oldh) oldrec.?.code else self.text_comp_content.get(oldh);
                    const nt = try ta.dupe(u8, cell.text);
                    cell.* = .{ .text = nt };
                    if (oldcode) |oc| { const nh = std.hash.Wyhash.hash(0, nt); self.text_comp.put(@intFromPtr(nt.ptr), .{ .code = oc, .hash = nh }) catch {}; self.text_comp_content.put(nh, oc) catch {}; }
                }
            }
        }
        if (ri < t.cmin.items.len) t.cmin.items[ri] = self.comboOrCmd(t, ri);
        const nri = try appendStoredRow(self.gpa, t, newv);
        self.setRowComp(t, nri, self.compCodeForRow(t, t.rows.items[nri]));
        self.noteTextCompression(t, t.rows.items[nri]);
        for (u.assignments) |asg| {
            if (asg.value.* != .column) continue;
            const qn = asg.value.column;
            const dot = std.mem.indexOfScalar(u8, qn, '.') orelse continue;
            const src = self.find(self.resolveTableName(qn[0..dot])) orelse continue;
            if (src.rows.items.len == 0) continue;
            const ci2 = findCol(t, asg.col) orelse continue;
            if (ci2 >= t.rows.items[nri].len) continue;
            for (src.rows.items[0]) |sv| {
                if (sv != .text) continue;
                const h = std.hash.Wyhash.hash(0, sv.text);
                var code: ?u8 = null;
                if (self.text_comp.get(@intFromPtr(sv.text.ptr))) |rec| { if (rec.hash == h) code = rec.code; }
                if (code == null) code = self.text_comp_content.get(h);
                if (code) |cc| {
                    const dv = t.rows.items[nri][ci2];
                    if (dv == .text) { const dh = std.hash.Wyhash.hash(0, dv.text); self.text_comp.put(@intFromPtr(dv.text.ptr), .{ .code = cc, .hash = dh }) catch {}; self.text_comp_content.put(dh, cc) catch {}; }
                    self.setRowComp(t, nri, cc);
                }
                break;
            }
        }
        t.xmin.items[nri] = mine;
        self.stampInsert(t, nri);
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
                    if (std.c.getenv("ZHDB_EXPLAIN") != null) std.debug.print("[plan] update overlay: row={d} ct={d} owner={d}\n", .{ ri, cid, if (was_txn) mine else 0 });
                }
            }
        }
        if (std.ascii.eqlIgnoreCase(u.table, "pg_class")) {
            var has_opt = false;
            for (u.assignments) |a| if (std.ascii.eqlIgnoreCase(a.col, "reloptions")) {
                has_opt = true;
            };
            if (has_opt) {
                const ci_nm = findCol(t, "relname");
                const ci_ro = findCol(t, "reloptions");
                if (ci_nm != null and ci_ro != null and ci_nm.? < newv.len and ci_ro.? < newv.len and newv[ci_nm.?] == .text and newv[ci_ro.?] == .text) {
                    self.setReloptsFromText(newv[ci_nm.?].text, newv[ci_ro.?].text);
                }
            }
        }
        if (u.returning.len > 0) try ret_rows.append(alloc, newv);
        n += 1;
    }
    if (self.inTxn()) self.txnViewDrop(t.name);
    if (std.c.getenv("ZHDB_EXPLAIN") != null) std.debug.print("[plan] update mvcc: {d} versions\n", .{n});
    if (u.returning.len > 0) return try self.returningResult(alloc, t, u.returning, ret_rows.items);
    return .{ .affected = n };
}

pub fn execDelete(self: *Engine, alloc: std.mem.Allocator, d: anytype) EngineError!Result {
    if (self.find(d.table) == null) {
        setDiag("relation \"{s}\" does not exist", .{d.table});
        return error.TableNotFound;
    }
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
    var ret_rows = std.ArrayList([]Value).empty;
    defer ret_rows.deinit(alloc);
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
        if (ri < t.cmin.items.len) t.cmin.items[ri] = self.comboOrCmd(t, ri);
        if (d.returning.len > 0) try ret_rows.append(alloc, mrow);
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
        if (std.c.getenv("ZHDB_EXPLAIN") != null) std.debug.print("[plan] delete tombstones: {d} rows\n", .{removed});
        if (self.inTxn()) {} else {
            const freed = self.reclaimFreeSegments(t);
            if (freed > 0 and std.c.getenv("ZHDB_EXPLAIN") != null) std.debug.print("[reclaim] {s}: {d} rows of whole segments registered for reuse\n", .{ d.table, freed });
            if (!self.background_gc) self.maybeAutoVacuum(d.table);
        }
        if (self.inTxn()) self.txnViewDrop(d.table);
    }
    if (d.returning.len > 0) return try self.returningResult(alloc, t, d.returning, ret_rows.items);
    return .{ .affected = removed };
}

pub fn returningResult(self: *Engine, alloc: std.mem.Allocator, t: *Table, ret: []*sql.Expr, rrows: []const []Value) EngineError!Result {
    if (ret.len == 0) return .{ .affected = rrows.len };
    var exps = std.ArrayList(*sql.Expr).empty;
    defer exps.deinit(alloc);
    for (ret) |e| switch (e.*) {
        .star, .star_table => for (t.cols) |c| {
            const ne = try alloc.create(sql.Expr);
            ne.* = .{ .column = c.name };
            try exps.append(alloc, ne);
        },
        else => try exps.append(alloc, e),
    };
    const cols = try alloc.alloc([]const u8, exps.items.len);
    for (exps.items, 0..) |e, i| cols[i] = exprName(e);
    const out = try alloc.alloc([]Value, rrows.len);
    for (rrows, 0..) |row, ri| {
        const orow = try alloc.alloc(Value, exps.items.len);
        for (exps.items, 0..) |e, ci| orow[ci] = try self.eval(alloc, e, row, t.cols, null);
        out[ri] = orow;
    }
    return .{ .columns = cols, .rows = out, .affected = rrows.len };
}

pub fn isDefaultExpr(e: *sql.Expr) bool {
    return e.* == .call and std.ascii.eqlIgnoreCase(e.call.name, "__default");
}

pub fn applyColumnDefault(self: *Engine, t: *Table, ci: usize, cell: *Value) void {
    _ = self;
    if (cell.* != .null) return;
    var dt = std.mem.trim(u8, t.cols[ci].default_text, " \t\r\n");
    if (dt.len == 0) return;
    if (std.mem.eql(u8, dt, "NULL")) return;
    if (dt.len >= 2 and dt[0] == '\'') {
        if (dt[dt.len - 1] == '\'') {
            cell.* = .{ .text = dt[1 .. dt.len - 1] };
            return;
        }
    }
    if (std.ascii.eqlIgnoreCase(dt, "true")) {
        cell.* = .{ .boolean = true };
        return;
    }
    if (std.ascii.eqlIgnoreCase(dt, "false")) {
        cell.* = .{ .boolean = false };
        return;
    }
    if (std.fmt.parseInt(i64, dt, 10)) |iv| {
        cell.* = .{ .int = iv };
        return;
    } else |_| {}
    if (std.fmt.parseFloat(f64, dt)) |fv| {
        cell.* = .{ .float = fv };
        return;
    } else |_| {}
}

pub fn validateInsertNotNull(self: *Engine, alloc: std.mem.Allocator, t: *Table, ins: anytype, exprs: []*sql.Expr) EngineError!void {
    const row = try alloc.alloc(Value, t.cols.len);
    for (row) |*c| c.* = .null;
    if (ins.columns.len == 0) {
        for (exprs, 0..) |e, i| if (i < row.len) {
            row[i] = try self.eval(alloc, e, null, &.{}, null);
        };
    } else {
        for (ins.columns, 0..) |cn, i| {
            if (i >= exprs.len) break;
            const idx = findCol(t, cn) orelse return error.SyntaxError;
            if (isDefaultExpr(exprs[i])) continue;
            row[idx] = try self.eval(alloc, exprs[i], null, &.{}, null);
        }
    }
    for (0..t.cols.len) |ci| {
        var explicit_default = false;
        var omitted = true;
        if (ins.columns.len > 0) {
            for (ins.columns, 0..) |cn, k| {
                if (!std.ascii.eqlIgnoreCase(cn, t.cols[ci].name)) continue;
                omitted = false;
                if (k < exprs.len and isDefaultExpr(exprs[k])) explicit_default = true;
            }
        } else if (ci < exprs.len) {
            omitted = false;
            if (isDefaultExpr(exprs[ci])) explicit_default = true;
        }
        if (row[ci] == .null and (omitted or explicit_default)) {
            if (t.cols[ci].serial) row[ci] = .{ .int = 0 } else self.applyColumnDefault(t, ci, &row[ci]);
        }
    }
    for (t.cols, 0..) |c, ci| {
        if (row[ci] == .null and c.default_text.len > 0 and !c.serial) {
            self.applyColumnDefault(t, ci, &row[ci]);
        }
        if (!c.not_null or row[ci] != .null) continue;
        if (c.serial or c.default_text.len > 0) continue;
        try self.checkNotNull(t, row);
    }
}

pub fn checkNotNull(self: *Engine, t: *Table, row: []const Value) EngineError!void {
    for (t.cols, 0..) |c, i| {
        if (!c.not_null or i >= row.len or row[i] != .null) continue;
        var det = std.ArrayList(u8).empty;
        defer det.deinit(self.gpa);
        det.append(self.gpa, '(') catch {};
        for (row, 0..) |v, k| {
            if (k > 0) det.appendSlice(self.gpa, ", ") catch {};
            if (v == .null) det.appendSlice(self.gpa, "null") catch {} else det.appendSlice(self.gpa, formatValue(self.gpa, v) catch "") catch {};
        }
        det.append(self.gpa, ')') catch {};
        setDiag("null value in column \"{s}\" of relation \"{s}\" violates not-null constraint\nDETAIL:  Failing row contains {s}.", .{ c.name, t.name, det.items });
        return error.RawDdlError;
    }
}
