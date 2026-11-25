const std = @import("std");
const sql = @import("sql.zig");
const storage = @import("storage.zig");
const tls_mod = @import("tls.zig");
const lockmgr = @import("lockmgr.zig");
const engine_mod = @import("engine.zig");
const value = @import("value.zig");
const Value = @import("value.zig").Value;

pub const Server = struct {
    engine: *engine_mod.Engine,
    /// Offer TLS 1.3 (SSLRequest -> 'S' instead of 'N').
    tls: bool = false,
    /// Snapshot file to write back to after DML / CREATE INDEX.
    db_path: ?[]const u8 = null,
    writeback: bool = false,
    /// Background GC interval in milliseconds (0 = disabled).
    gc_interval_ms: u64 = 0,
    /// Per-table write locks with a wait-for graph (deadlock -> 40P01).
    locks: lockmgr.LockMgr = undefined,
    /// Per-table reader/writer locks: statement-level exclusion between readers
    /// and writers of the *same* table, without serialising other tables.
    table_rw: std.StringHashMap(*std.Io.RwLock) = undefined,
    table_rw_spin: SpinLock = .{},
    /// Monotonic id for autocommit statements (lock ownership).
    next_stmt_owner: std.atomic.Value(u64) = std.atomic.Value(u64).init(1 << 62),
    /// When set, the column store does not fit the memory budget: eligible
    /// aggregate queries are executed block-at-a-time through this handle
    /// instead of the in-memory engine (lazy / larger-than-RAM mode).
    lazy_db: ?*storage.Db = null,
    /// When set, clients must authenticate with AuthenticationMD5Password.
    password: ?[]const u8 = null,
    /// Catalog/engine lock: many concurrent readers, one writer.
    mutex: std.Io.RwLock = .init,
};

const MSG_AUTH_OK = 'R';
const MSG_PARAM = 'S';
const MSG_BACKEND_KEY = 'K';
const MSG_READY = 'Z';
const MSG_ROW_DESC = 'T';
const MSG_DATA_ROW = 'D';
const MSG_COMMAND_COMPLETE = 'C';
const MSG_ERROR = 'E';
const MSG_NO_DATA = 'n';
const MSG_CLOSE_COMPLETE = '3';

pub fn serve(server: *Server, io: std.Io, port: u16) !void {
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    server.locks = lockmgr.LockMgr.init(std.heap.page_allocator, io);
    server.table_rw = std.StringHashMap(*std.Io.RwLock).init(std.heap.page_allocator);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.debug.print("zhdb listening on 0.0.0.0:{d}\n", .{port});
    if (server.gc_interval_ms > 0) {
        const g = std.Thread.spawn(.{}, gcLoop, .{ server, io }) catch null;
        if (g) |t| t.detach() else std.debug.print("gc thread failed to start\n", .{});
    }

    while (true) {
        const stream = listener.accept(io) catch |e| {
            std.debug.print("accept failed: {s}\n", .{@errorName(e)});
            continue;
        };
        const t = std.Thread.spawn(.{}, handleConnection, .{ server, io, stream }) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
}


/// Buffered writer that can switch to TLS mid-session (after SSLRequest).
const Out = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    tls: ?*tls_mod.Server = null,
    buf: [16384]u8 = undefined,
    writer: std.Io.Writer = undefined,

    fn init(self: *Out, io: std.Io, stream: std.Io.net.Stream) void {
        self.io = io;
        self.stream = stream;
        self.tls = null;
        self.writer = .{ .buffer = &self.buf, .vtable = &vtable };
    }

    fn emit(self: *Out, bytes: []const u8) !void {
        if (self.tls) |t| {
            try t.writeAll(bytes);
        } else {
            var tmp: [4096]u8 = undefined;
            var sw = self.stream.writer(self.io, &tmp);
            try sw.interface.writeAll(bytes);
            try sw.interface.flush();
        }
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Out = @alignCast(@fieldParentPtr("writer", w));
        const buffered = w.buffered();
        if (buffered.len > 0) self.emit(buffered) catch return error.WriteFailed;
        var consumed: usize = 0;
        for (data, 0..) |chunk, idx| {
            const times = if (idx + 1 == data.len) @max(splat, 1) else 1;
            var t: usize = 0;
            while (t < times) : (t += 1) {
                self.emit(chunk) catch return error.WriteFailed;
                consumed += chunk.len;
            }
        }
        w.end = 0;
        return consumed;
    }

    const vtable = std.Io.Writer.VTable{ .drain = drain };
};

/// Background vacuum: periodically reclaims dead MVCC versions / tombstones.
fn gcLoop(server: *Server, io: std.Io) void {
    while (true) {
        const ns: u64 = server.gc_interval_ms * 1_000_000;
        std.Io.sleep(io, .{ .nanoseconds = @intCast(ns) }, .awake) catch {};
        server.mutex.lockUncancelable(io);
        const n = server.engine.gcTick();
        if (n > 0 and server.writeback) {
            if (server.db_path) |dp| {
                server.engine.saveSnapshotFile(io, std.heap.page_allocator, "hits", dp) catch {};
            }
        }
        server.mutex.unlock(io);
        if (n > 0) std.debug.print("[gc] reclaimed {d} table(s)\n", .{n});
    }
}

fn handleConnection(server: *Server, io: std.Io, stream: std.Io.net.Stream) void {
    const gpa = std.heap.page_allocator;
    _ = gpa;
    defer stream.close(io);
    var out = Out{ .io = io, .stream = stream };
    out.init(io, stream);
    var conn = Conn{ .stream = stream, .io = io };
    handleSession(server, io, std.heap.page_allocator, &conn, &out) catch |e| {
        std.debug.print("session ended: {s}\n", .{@errorName(e)});
    };
    // Connection close: flush any learned cost model immediately (the periodic
    // checkpoint is throttled, so the last updates could otherwise be lost).
    server.engine.flushCosts(io);
    out.writer.flush() catch {};
}


/// Blocking buffered message reader. Uses the Io net_read operation directly
/// so message framing does not depend on std.Io.Reader internals.
const Conn = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    /// Set once the TLS handshake completed; all reads go through it.
    tls: ?*tls_mod.Server = null,
    buf: [65536]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,
    /// MVCC transaction context for this session.
    txn: engine_mod.TxnCtx = .{},

    const max_msg: u32 = 64 * 1024 * 1024;

    fn fill(self: *Conn, want: usize) !void {
        if (self.len - self.pos >= want) return;
        const rem = self.len - self.pos;
        if (rem > 0 and self.pos > 0) {
            std.mem.copyForwards(u8, self.buf[0..rem], self.buf[self.pos..self.len]);
        }
        self.pos = 0;
        self.len = rem;
        while (self.len < want) {
            var n: usize = 0;
            if (self.tls) |t| {
                n = try t.read(self.buf[self.len..]);
            } else {
                var iov = [1][]u8{self.buf[self.len..]};
                const op: std.Io.Operation = .{ .net_read = .{
                    .socket_handle = self.stream.socket.handle,
                    .data = &iov,
                } };
                const res = try self.io.operate(op);
                n = (try res.net_read).data_len;
            }
            if (n == 0) return error.EndOfStream;
            self.len += n;
        }
    }

    fn readExact(self: *Conn, n: usize) ![]u8 {
        if (n > self.buf.len) return error.MessageTooLong;
        try self.fill(n);
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    /// Read exactly `dst.len` bytes into `dst`, draining buffered bytes first.
    /// Used for messages larger than the (fixed) connection buffer, e.g. a
    /// multi-megabyte INSERT.
    fn readExactInto(self: *Conn, dst: []u8) !void {
        var off: usize = 0;
        while (off < dst.len) {
            if (self.pos < self.len) {
                const take = @min(self.len - self.pos, dst.len - off);
                @memcpy(dst[off .. off + take], self.buf[self.pos .. self.pos + take]);
                self.pos += take;
                off += take;
                continue;
            }
            var n: usize = 0;
            if (self.tls) |t| {
                n = try t.read(dst[off..]);
            } else {
                var iov = [1][]u8{dst[off..]};
                const op: std.Io.Operation = .{ .net_read = .{
                    .socket_handle = self.stream.socket.handle,
                    .data = &iov,
                } };
                const res = try self.io.operate(op);
                n = (try res.net_read).data_len;
            }
            if (n == 0) return error.EndOfStream;
            off += n;
        }
    }
};


/// PostgreSQL's MD5 scheme: md5("md5(password+user)" ++ salt) in hex, prefixed
/// with "md5".
fn checkMd5Password(alloc: std.mem.Allocator, pw: []const u8, user: []const u8, salt: [4]u8, payload: []const u8) bool {
    if (payload.len < 35 or !std.mem.eql(u8, payload[0..3], "md5")) return false;
    var inner_buf: [128]u8 = undefined;
    if (pw.len + user.len > inner_buf.len) return false;
    @memcpy(inner_buf[0..pw.len], pw);
    @memcpy(inner_buf[pw.len .. pw.len + user.len], user);
    var inner: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(inner_buf[0 .. pw.len + user.len], &inner, .{});
    const inner_hex = std.fmt.bytesToHex(inner, .lower);

    var outer_buf: [36]u8 = undefined;
    @memcpy(outer_buf[0..32], &inner_hex);
    @memcpy(outer_buf[32..36], &salt);
    var outer: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(&outer_buf, &outer, .{});
    const outer_hex = std.fmt.bytesToHex(outer, .lower);
    _ = alloc;
    return std.ascii.eqlIgnoreCase(payload[3..35], &outer_hex);
}

fn writeCommandComplete(writer: *std.Io.Writer, tag: []const u8) !void {
    var buf: [256]u8 = undefined;
    if (tag.len + 1 > buf.len) return error.TagTooLong;
    @memcpy(buf[0..tag.len], tag);
    buf[tag.len] = 0;
    try writeMsg(writer, MSG_COMMAND_COMPLETE, buf[0 .. tag.len + 1]);
}

fn writeMsg(writer: *std.Io.Writer, tag: u8, payload: []const u8) !void {
    var lb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lb, @intCast(payload.len + 4), .big);
    try writer.writeAll(&[_]u8{tag});
    try writer.writeAll(&lb);
    try writer.writeAll(payload);
}

fn writeInt32(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: i32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(i32, &b, v, .big);
    try buf.appendSlice(alloc, &b);
}

fn handleSession(server: *Server, io: std.Io, alloc: std.mem.Allocator, conn: *Conn, out: *Out) !void {
    const writer = &out.writer;
    // Startup phase
    var user: []const u8 = "zhdb";
    while (true) {
        const lb = try conn.readExact(4);
        const len = std.mem.readInt(u32, lb[0..4], .big);
        if (len < 8 or len > 1024 * 1024) return error.InvalidStartup;
        const body = try conn.readExact(len - 4);
        const code = std.mem.readInt(u32, body[0..4], .big);
        if (code == 80877103 or code == 80877104) { // SSLRequest / GSSENCRequest
            if (code == 80877103 and server.tls) {
                try writer.writeAll("S");
                try writer.flush();
                const ts = try alloc.create(tls_mod.Server);
                ts.* = tls_mod.Server.init(io, conn.stream);
                try ts.handshake();
                out.tls = ts;
                conn.tls = ts;
                continue;
            }
            try writer.writeAll("N");
            try writer.flush();
            continue;
        }
        // key\0value\0 ... \0
        var it = std.mem.splitScalar(u8, body[4..], 0);
        while (it.next()) |k| {
            const v = it.next() orelse break;
            // Copy: the startup buffer is reused by later message reads.
            if (std.ascii.eqlIgnoreCase(k, "user") and v.len > 0) user = alloc.dupe(u8, v) catch user;
        }
        break;
    }

    if (server.password) |pw| {
        var salt: [4]u8 = undefined;
        // CSPRNG salt (std.Io exposes the platform RNG).
        io.random(&salt);
        var ab = std.ArrayList(u8).empty;
        defer ab.deinit(alloc);
        try writeInt32(&ab, alloc, 5); // AuthenticationMD5Password
        try ab.appendSlice(alloc, &salt);
        try writeMsg(writer, MSG_AUTH_OK, ab.items);
        try writer.flush();

        // PasswordMessage: 'p' + len + "md5" + 32 hex chars
        const hdr = conn.readExact(5) catch return;
        if (hdr[0] != 'p') return error.AuthFailed;
        var hb: [4]u8 = undefined;
        @memcpy(&hb, hdr[1..5]);
        const plen = std.mem.readInt(u32, &hb, .big);
        if (plen < 8 or plen > 1024) return error.AuthFailed;
        const payload = conn.readExact(plen - 4) catch return;
        if (!checkMd5Password(alloc, pw, user, salt, payload)) {
            try sendError(alloc, writer, "28P01", "password authentication failed");
            try writer.flush();
            return error.AuthFailed;
        }
    }
    server.mutex.lockUncancelable(io);
    server.engine.fireLoginTriggers(alloc);
    server.mutex.unlock(io);
    try sendAuthOk(alloc, writer);
    try writer.flush();

    var last_query: ?[]u8 = null;
    defer if (last_query) |q| alloc.free(q);
    // Bound parameter values (text format; null = SQL NULL).
    var bind_params: std.ArrayList(?[]u8) = .empty;
    defer {
        for (bind_params.items) |v| if (v) |x| alloc.free(x);
        bind_params.deinit(alloc);
    }

    while (true) {
        const hdr = conn.readExact(5) catch return;
        const tag: u8 = hdr[0];
        var hb: [4]u8 = undefined;
        @memcpy(&hb, hdr[1..5]);
        const mlen = std.mem.readInt(u32, &hb, .big);
        if (mlen < 4 or mlen > Conn.max_msg) return;
        const need: usize = mlen - 4;
        var heap: ?[]u8 = null;
        var payload: []u8 = undefined;
        if (need > conn.buf.len) {
            // Large message (e.g. a multi-row INSERT): read it into a heap
            // buffer instead of dropping the connection.
            heap = alloc.alloc(u8, need) catch return;
            payload = heap.?;
            conn.readExactInto(payload) catch {
                alloc.free(heap.?);
                return;
            };
        } else {
            payload = conn.readExact(need) catch return;
        }
        defer if (heap) |h| alloc.free(h);
        switch (tag) {
            'Q' => {
                const q = std.mem.trimEnd(u8, payload, &[_]u8{0});
                if (startsWithIgnoreCase(q, "copy ") and containsIgnoreCase(q, "from stdin")) {
                    try handleCopy(server, io, alloc, conn, writer, q);
                } else {
                    try runSimpleQuery(server, io, alloc, conn, writer, q);
                }
            },
            'P' => {
                // Parse: name\0 query\0 ...
                var it = std.mem.splitScalar(u8, payload, 0);
                _ = it.next();
                const q = it.next() orelse "";
                if (last_query) |old| alloc.free(old);
                last_query = try alloc.dupe(u8, q);
                try writeMsg(writer, '1', ""); // ParseComplete
                try writer.flush();
            },
            'B' => {
                // Bind: portal\0 stmt\0 [int16 nfmt, int16 fmt...]
                //       int16 nparams, (int32 len, bytes)... [int16 nres, int16...]
                for (bind_params.items) |v| if (v) |x| alloc.free(x);
                bind_params.clearRetainingCapacity();
                var bi: usize = 0;
                var z: usize = 0;
                while (z < 2) : (z += 1) {
                    const end = std.mem.indexOfScalarPos(u8, payload, bi, 0) orelse payload.len;
                    bi = end + 1;
                    if (bi > payload.len) break;
                }
                if (bi + 2 <= payload.len) {
                    const nfmt = std.mem.readInt(u16, payload[bi..][0..2], .big);
                    bi += 2 + @as(usize, nfmt) * 2;
                }
                if (bi + 2 <= payload.len) {
                    const np = std.mem.readInt(u16, payload[bi..][0..2], .big);
                    bi += 2;
                    var pi: usize = 0;
                    while (pi < np and bi + 4 <= payload.len) : (pi += 1) {
                        const vlen = std.mem.readInt(i32, payload[bi..][0..4], .big);
                        bi += 4;
                        if (vlen < 0) {
                            bind_params.append(alloc, null) catch {};
                        } else {
                            const n: usize = @intCast(vlen);
                            if (bi + n > payload.len) break;
                            bind_params.append(alloc, alloc.dupe(u8, payload[bi .. bi + n]) catch null) catch {};
                            bi += n;
                        }
                    }
                }
                try writeMsg(writer, '2', ""); // BindComplete
                try writer.flush();
            },
            'D' => {
                const kind = payload[0];
                if (kind == 'S' and last_query != null) {
                    try describeQuery(server, io, alloc, writer, last_query.?);
                } else {
                    try writeMsg(writer, MSG_NO_DATA, "");
                    try writer.flush();
                }
            },
            'E' => {
                if (last_query) |q| {
                    const text = substituteParams(alloc, q, bind_params.items) catch q;
                    defer if (text.ptr != q.ptr) alloc.free(text);
                    try runSimpleQueryNoReady(server, io, alloc, conn, writer, text);
                }
                try writer.flush();
            },
            'S' => {
                try writeMsg(writer, MSG_READY, "I");
                try writer.flush();
            },
            'H' => try writer.flush(),
            'C' => {
                try writeMsg(writer, MSG_CLOSE_COMPLETE, "");
                try writer.flush();
            },
            'X' => return,
            else => {},
        }
    }
}

fn sendAuthOk(alloc: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try writeInt32(&buf, alloc, 0);
    try writeMsg(writer, MSG_AUTH_OK, buf.items);

    const params = [_][2][]const u8{
        .{ "server_version", "18.1" },
        .{ "server_encoding", "UTF8" },
        .{ "client_encoding", "UTF8" },
        .{ "DateStyle", "ISO, MDY" },
        .{ "TimeZone", "UTC" },
        .{ "integer_datetimes", "on" },
        .{ "standard_conforming_strings", "on" },
        .{ "is_superuser", "on" },
        .{ "session_authorization", "zhdb" },
    };
    for (params) |p| {
        var pb = std.ArrayList(u8).empty;
        defer pb.deinit(alloc);
        try pb.appendSlice(alloc, p[0]);
        try pb.append(alloc, 0);
        try pb.appendSlice(alloc, p[1]);
        try pb.append(alloc, 0);
        try writeMsg(writer, MSG_PARAM, pb.items);
    }
    var kb = std.ArrayList(u8).empty;
    defer kb.deinit(alloc);
    try writeInt32(&kb, alloc, 4242);
    try writeInt32(&kb, alloc, 1234);
    try writeMsg(writer, MSG_BACKEND_KEY, kb.items);
    var ni: usize = 0;
    while (ni < engine_mod.noticeCount()) : (ni += 1) try sendNotice(alloc, writer, ni);
    try writeMsg(writer, MSG_READY, "I");
}

/// Statements every PG client sends that zhdb can accept as no-ops.
fn shimStatement(t: []const u8) ?[]const u8 {
    const prefixes = [_]struct { p: []const u8, tag: []const u8 }{
        .{ .p = "BEGIN", .tag = "BEGIN" },
        .{ .p = "START TRANSACTION", .tag = "BEGIN" },
        .{ .p = "COMMIT", .tag = "COMMIT" },
        .{ .p = "ROLLBACK", .tag = "ROLLBACK" },
        .{ .p = "END", .tag = "COMMIT" },
        .{ .p = "DISCARD ", .tag = "DISCARD ALL" },
        .{ .p = "LISTEN ", .tag = "LISTEN" },
        .{ .p = "UNLISTEN ", .tag = "UNLISTEN" },
    };
    for (prefixes) |x| {
        if (std.ascii.startsWithIgnoreCase(t, x.p)) return x.tag;
    }
    return null;
}

/// System-catalog introspection (`pg_catalog.*`, `pg_class`, `information_schema`).
fn isCatalogQuery(t: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(t, "SELECT ") and !std.ascii.startsWithIgnoreCase(t, "WITH ")) return false;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        if (!std.ascii.isAlphabetic(t[i])) continue;
        inline for ([_][]const u8{ "pg_catalog.", "pg_class", "pg_attribute", "pg_type", "pg_namespace", "pg_database", "pg_settings", "information_schema." }) |needle| {
            if (i + needle.len <= t.len and std.ascii.eqlIgnoreCase(t[i .. i + needle.len], needle)) return true;
        }
    }
    return false;
}



/// Replace `$N` with the bound literal. Text is quoted ('' escaped), numbers are
/// emitted bare, NULL becomes the NULL keyword. This is literal substitution at
/// Execute time — correct and simple; it does not reuse a plan.
fn substituteParams(alloc: std.mem.Allocator, q: []const u8, params: []const ?[]const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    var changed = false;
    while (i < q.len) {
        if (q[i] == '$' and i + 1 < q.len and std.ascii.isDigit(q[i + 1])) {
            var j = i + 1;
            var n: usize = 0;
            while (j < q.len and std.ascii.isDigit(q[j])) : (j += 1) n = n * 10 + (q[j] - '0');
            const idx = n - 1;
            if (idx < params.len) {
                changed = true;
                if (params[idx]) |v| {
                    var numeric = v.len > 0;
                    for (v) |ch| if (!std.ascii.isDigit(ch) and ch != '-' and ch != '.') {
                        numeric = false;
                    };
                    if (numeric) {
                        try out.appendSlice(alloc, v);
                    } else {
                        try out.append(alloc, '\'');
                        for (v) |ch| {
                            if (ch == '\'') try out.append(alloc, '\'');
                            try out.append(alloc, ch);
                        }
                        try out.append(alloc, '\'');
                    }
                } else {
                    try out.appendSlice(alloc, "NULL");
                }
                i = j;
                continue;
            }
        }
        try out.append(alloc, q[i]);
        i += 1;
    }
    if (!changed) {
        out.deinit(alloc);
        return @constCast(q);
    }
    return out.toOwnedSlice(alloc);
}


/// Cost-based routing in lazy mode: only single-table aggregates are served
/// from disk (block-at-a-time); everything else needs the in-memory store.
fn lazyAggregate(db: *storage.Db, stmt: sql.Stmt) !value.Value {
    if (stmt != .select) return error.LazyModeOnlyAggregates;
    const plan = try db.planLazy(stmt.select);
    const r = try db.streamAgg(plan.ci, plan.agg, plan.filter, null);
    if (plan.avg) {
        const avg = if (r.count > 0)
            @as(f64, @floatFromInt(r.sum)) / @as(f64, @floatFromInt(r.count))
        else
            0;
        return .{ .float = avg };
    }
    return switch (plan.agg) {
        .count => .{ .int = @intCast(r.count) },
        .sum => .{ .int = @intCast(r.sum) },
        .min => .{ .int = r.min },
        .max => .{ .int = r.max },
    };
}

const SpinLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fn lock(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// Lock object for one table (created on first use).
fn tableRw(server: *Server, name: []const u8) *std.Io.RwLock {
    server.table_rw_spin.lock();
    defer server.table_rw_spin.unlock();
    if (server.table_rw.get(name)) |l| return l;
    const l = std.heap.page_allocator.create(std.Io.RwLock) catch @panic("table lock oom");
    l.* = std.Io.RwLock.init;
    const key = std.heap.page_allocator.dupe(u8, name) catch @panic("table lock oom");
    server.table_rw.put(key, l) catch @panic("table lock oom");
    return l;
}

/// How a statement may be scheduled.
const Kind = enum {
    /// Single-table SELECT: shared per-table + shared global lock.
    read,
    /// Autocommit DML on one table: exclusive per-table, shared global lock, so
    /// writers on *different* tables run in parallel.
    dml,
    /// Everything else (DDL, join, subquery, transaction): exclusive global.
    other,
};

fn exprHasSubqueryPg(e: *sql.Expr) bool {
    return exprHasSubquery(e);
}

/// DML statements that carry a subquery mutate engine-wide subquery sets, so
/// they must keep the exclusive lock.
fn dmlHasSubquery(stmt: sql.Stmt) bool {
    return switch (stmt) {
        .insert => |i| blk: {
            for (i.rows) |row| for (row) |e| if (exprHasSubqueryPg(e)) break :blk true;
            break :blk false;
        },
        .update => |u| blk: {
            for (u.assignments) |a| if (exprHasSubqueryPg(a.value)) break :blk true;
            if (u.where) |w| if (exprHasSubqueryPg(w)) break :blk true;
            break :blk false;
        },
        .delete => |d| if (d.where) |w| exprHasSubqueryPg(w) else false,
        else => false,
    };
}

/// Collect every base table a SELECT reads (outer, join and all subqueries).
/// Returns false when a table name cannot be determined (e.g. a FROM subquery
/// we do not model), so the caller can fall back to the exclusive lock.
fn collectTables(sel: *sql.Select, out: *[64][]const u8, n: *usize, depth: usize) bool {
    if (depth > 4) return false;
    switch (sel.from orelse return false) {
        .table => |t| {
            if (n.* < out.len) {
                out[n.*] = t;
                n.* += 1;
            } else return false;
        },
        .subquery => |sub| if (!collectTables(sub, out, n, depth + 1)) return false,
        .function => return false,
        .values => return false,
    }
    if (sel.join) |j| {
        if (n.* < out.len) {
            out[n.*] = j.table;
            n.* += 1;
        } else return false;
        if (!collectExprTables(j.on, out, n, depth)) return false;
    }
    if (sel.union_all) |u| if (!collectTables(u, out, n, depth + 1)) return false;
    for (sel.items) |it| if (!collectExprTables(it.expr, out, n, depth)) return false;
    if (sel.where) |w| if (!collectExprTables(w, out, n, depth)) return false;
    if (sel.having) |h| if (!collectExprTables(h, out, n, depth)) return false;
    for (sel.group_by) |g| if (!collectExprTables(g, out, n, depth)) return false;
    for (sel.order_by) |o| if (!collectExprTables(o.expr, out, n, depth)) return false;
    return true;
}

fn collectExprTables(e: *sql.Expr, out: *[64][]const u8, n: *usize, depth: usize) bool {
    switch (e.*) {
        .in_subquery => |x| {
            if (!collectExprTables(x.operand, out, n, depth)) return false;
            return collectTables(x.sub, out, n, depth + 1);
        },
        .exists => |x| return collectTables(x.sub, out, n, depth + 1),
        .binary => |b| return collectExprTables(b.lhs, out, n, depth) and collectExprTables(b.rhs, out, n, depth),
        .negate => |x| return collectExprTables(x, out, n, depth),
        .not => |x| return collectExprTables(x, out, n, depth),
        .call => |c| {
            for (c.args) |a| if (!collectExprTables(a, out, n, depth)) return false;
            return true;
        },
        .case_expr => |c| {
            for (c.whens) |w| {
                if (!collectExprTables(w.cond, out, n, depth)) return false;
                if (!collectExprTables(w.then, out, n, depth)) return false;
            }
            if (c.else_expr) |el| if (!collectExprTables(el, out, n, depth)) return false;
            return true;
        },
        .is_null => |x| return collectExprTables(x.operand, out, n, depth),
        .like => |x| return collectExprTables(x.operand, out, n, depth) and collectExprTables(x.pattern, out, n, depth),
        .in_list => |x| {
            if (!collectExprTables(x.operand, out, n, depth)) return false;
            for (x.items) |it| if (!collectExprTables(it, out, n, depth)) return false;
            return true;
        },
        .between => |x| return collectExprTables(x.operand, out, n, depth) and
            collectExprTables(x.low, out, n, depth) and collectExprTables(x.high, out, n, depth),
        .cast => |x| return collectExprTables(x.operand, out, n, depth),
        else => return true,
    }
}

/// Materialise lazy snapshot tables before any shared lock is taken (filling a
/// row store is a write). Runs under the exclusive lock only when needed.
fn materializeReferenced(server: *Server, io: std.Io, stmt: sql.Stmt) void {
    if (stmt != .select) return;
    var names: [64][]const u8 = undefined;
    var n: usize = 0;
    if (!collectTables(stmt.select, &names, &n, 0)) return;
    var any_lazy = false;
    var any_catalog = false;
    for (0..n) |i| {
        if (server.engine.isLazy(names[i])) any_lazy = true;
        if (std.mem.startsWith(u8, names[i], "pg_")) any_catalog = true;
    }
    if (!any_lazy and !any_catalog) return;
    // Both operations mutate shared state, so do them under the exclusive lock
    // *before* any shared lock is taken.
    server.mutex.lockUncancelable(io);
    if (any_catalog) server.engine.refreshCatalogIfNeeded();
    if (any_lazy) {
        for (0..n) |i| server.engine.materialize(names[i]);
    }
    server.mutex.unlock(io);
}

/// A SELECT is shareable when every table it reads exists and is materialised
/// (lazy snapshot tables are filled in by `materializeReferenced` first, and
/// `pg_` catalogs are refreshed there too). Temp JOIN tables are per-thread, so
/// they need neither locks nor catalog access.
fn canShareSelect(server: *Server, sel: *sql.Select) bool {
    var names: [64][]const u8 = undefined;
    var n: usize = 0;
    if (!collectTables(sel, &names, &n, 0)) return false;
    for (0..n) |i| {
        const nm = names[i];
        const rc = server.engine.rowCount(nm) orelse return false;
        if (rc == 0 and server.engine.isLazy(nm)) return false;
    }
    return true;
}

fn classifyStmt(server: *Server, stmt: sql.Stmt) Kind {
    if (stmt == .select and canShareSelect(server, stmt.select)) return .read;
    switch (stmt) {
        .insert, .update, .delete, .truncate, .create_index => {
            if (dmlHasSubquery(stmt)) return .other;
            return .dml;
        },
        else => return .other,
    }
}

/// True when a statement can run under a *shared* engine lock: a plain
/// single-table SELECT with no join and no subquery. Everything else (DML, DDL,
/// joins, subqueries, transactions) takes the exclusive lock, because those
/// paths mutate engine state (temp tables, subquery sets, catalogs).
fn canShareLock(stmt: sql.Stmt) bool {
    if (stmt != .select) return false;
    const sel = stmt.select;
    if (sel.join != null or sel.union_all != null) return false;
    const from = sel.from orelse return false;
    if (from != .table) return false;
    if (std.mem.startsWith(u8, from.table, "pg_")) return false;
    for (sel.items) |it| if (exprHasSubquery(it.expr)) return false;
    if (sel.where) |w| if (exprHasSubquery(w)) return false;
    if (sel.having) |h| if (exprHasSubquery(h)) return false;
    for (sel.group_by) |g| if (exprHasSubquery(g)) return false;
    for (sel.order_by) |o| if (exprHasSubquery(o.expr)) return false;
    return true;
}

fn exprHasSubquery(e: *sql.Expr) bool {
    return switch (e.*) {
        .in_subquery, .exists => true,
        .binary => |b| exprHasSubquery(b.lhs) or exprHasSubquery(b.rhs),
        .negate => |x| exprHasSubquery(x),
        .not => |x| exprHasSubquery(x),
        .call => |c| blk: {
            for (c.args) |a| if (exprHasSubquery(a)) break :blk true;
            break :blk false;
        },
        .case_expr => |c| blk: {
            for (c.whens) |w| if (exprHasSubquery(w.cond) or exprHasSubquery(w.then)) break :blk true;
            if (c.else_expr) |el| if (exprHasSubquery(el)) break :blk true;
            break :blk false;
        },
        .is_null => |x| exprHasSubquery(x.operand),
        .like => |x| exprHasSubquery(x.operand) or exprHasSubquery(x.pattern),
        .in_list => |x| blk: {
            if (exprHasSubquery(x.operand)) break :blk true;
            for (x.items) |it| if (exprHasSubquery(it)) break :blk true;
            break :blk false;
        },
        .between => |x| exprHasSubquery(x.operand) or exprHasSubquery(x.low) or exprHasSubquery(x.high),
        .cast => |x| exprHasSubquery(x.operand),
        else => false,
    };
}

/// Table a write statement modifies (used for the write lock).
fn writeTable(stmt: sql.Stmt) ?[]const u8 {
    return switch (stmt) {
        .insert => |i| i.table,
        .update => |u| u.table,
        .delete => |d| d.table,
        .truncate => |t| t,
        .create_index => |c| c.table,
        .vacuum => |v| v,
        else => null,
    };
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn startsWithIgnoreCase(hay: []const u8, needle: []const u8) bool {
    const t = std.mem.trimStart(u8, hay, " \t\r\n");
    return t.len >= needle.len and std.ascii.eqlIgnoreCase(t[0..needle.len], needle);
}

/// `COPY <table> FROM STDIN | '<file>' [WITH (FORMAT ..., DELIMITER ...)]`.
/// Text/CSV only; `\N` (and an unquoted NULL) load as SQL NULL.
fn handleCopy(
    server: *Server,
    io: std.Io,
    alloc: std.mem.Allocator,
    conn: *Conn,
    writer: *std.Io.Writer,
    q: []const u8,
) !void {
    // The connection read buffer is reused for CopyData messages, so the
    // command text must be copied before streaming.
    const qcopy = try alloc.dupe(u8, q);
    defer alloc.free(qcopy);
    const text = std.mem.trim(u8, qcopy, " \t\r\n;");
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    _ = it.next(); // COPY
    const table = it.next() orelse {
        try sendError(alloc, writer, "42601", "COPY: missing table");
        try writeMsg(writer, MSG_READY, "I");
        try writer.flush();
        return;
    };
    // Optional column list / FROM keyword.
    var from_kw = it.next() orelse "";
    if (from_kw.len > 0 and from_kw[0] == '(') {
        // skip "( col, ... )" then expect FROM
        while (it.next()) |t| {
            if (t[0] == ')') break;
        }
        from_kw = it.next() orelse "";
    }
    if (!std.ascii.eqlIgnoreCase(from_kw, "from")) {
        try sendError(alloc, writer, "42601", "COPY: expected FROM");
        try writeMsg(writer, MSG_READY, "I");
        try writer.flush();
        return;
    }
    const src = it.next() orelse "";

    // Delimiter: default TAB; `WITH (FORMAT csv, DELIMITER ',')` / E'\t'.
    var delim: u8 = '\t';
    if (std.mem.indexOf(u8, text, "DELIMITER") orelse std.mem.indexOf(u8, text, "delimiter")) |dpos| {
        var i = dpos + "delimiter".len;
        while (i < text.len and (text[i] == ' ' or text[i] == '=')) i += 1;
        if (i < text.len and (text[i] == '\'' or text[i] == 'E' or text[i] == 'e')) {
            if (text[i] == 'E' or text[i] == 'e') i += 1;
            if (i < text.len and text[i] == '\'') {
                i += 1;
                if (i < text.len) {
                    if (text[i] == '\\' and i + 1 < text.len) {
                        delim = switch (text[i + 1]) {
                            't' => '\t',
                            'n' => '\n',
                            else => text[i + 1],
                        };
                    } else delim = text[i];
                }
            }
        }
    }

    // Collect the payload.
    var data = std.ArrayList(u8).empty;
    defer data.deinit(alloc);
    if (std.ascii.eqlIgnoreCase(src, "stdin")) {
        // CopyInResponse: overall format 0 (text), 0 columns, no per-column formats.
        var body = std.ArrayList(u8).empty;
        defer body.deinit(alloc);
        try body.append(alloc, 0);
        try body.appendSlice(alloc, &[_]u8{ 0, 0 }); // int16 0 columns
        try writeMsg(writer, 'G', body.items);
        try writer.flush();
        while (true) {
            const hdr = conn.readExact(5) catch break;
            const tag = hdr[0];
            var hb: [4]u8 = undefined;
            @memcpy(&hb, hdr[1..5]);
            const mlen = std.mem.readInt(u32, &hb, .big);
            const payload = conn.readExact(mlen - 4) catch break;
            switch (tag) {
                'd' => try data.appendSlice(alloc, payload),
                'c' => break, // CopyDone
                'f' => {
                    try sendError(alloc, writer, "57014", "COPY aborted");
                    try writeMsg(writer, MSG_READY, "I");
                    try writer.flush();
                    return;
                },
                'H' => try writer.flush(),
                'S' => {},
                else => {},
            }
        }
    } else {
        // Server-side file: strip quotes.
        var path = src;
        if (path.len >= 2 and path[0] == '\'') {
            var end: usize = 1;
            while (end < path.len and path[end] != '\'') end += 1;
            path = path[1..end];
        }
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 * 1024 * 1024 * 1024)) catch {
            try sendError(alloc, writer, "58030", "COPY: cannot read file");
            try writeMsg(writer, MSG_READY, "I");
            try writer.flush();
            return;
        };
        defer alloc.free(bytes);
        try data.appendSlice(alloc, bytes);
    }

    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, data.items, '\n');
    var vals = std.ArrayList(Value).empty;
    defer vals.deinit(alloc);
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        vals.clearRetainingCapacity();
        var cells = std.mem.splitScalar(u8, line, delim);
        while (cells.next()) |cell| {
            if (std.mem.eql(u8, cell, "\\N") or std.ascii.eqlIgnoreCase(cell, "NULL")) {
                try vals.append(alloc, .null);
            } else if (std.fmt.parseInt(i64, cell, 10)) |iv| {
                try vals.append(alloc, .{ .int = iv });
            } else |_| {
                try vals.append(alloc, .{ .text = cell });
            }
        }
        server.engine.insertRow(table, vals.items) catch |e| {
            std.debug.print("[copy] insert failed: {s} (ncols={d} vals={d})\n", .{ @errorName(e), 0, vals.items.len });
            try sendError(alloc, writer, "22P02", "COPY: bad row");
            try writeMsg(writer, MSG_READY, "I");
            try writer.flush();
            return;
        };
        n += 1;
    }
    server.engine.buildColumnar(table) catch {};

    var tag: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&tag, "COPY {d}", .{n}) catch "COPY";
    try writeCommandComplete(writer, t);
    try writeMsg(writer, MSG_READY, "I");
    try writer.flush();
}

fn runSimpleQuery(server: *Server, io: std.Io, alloc: std.mem.Allocator, conn: *Conn, writer: *std.Io.Writer, q: []const u8) !void {
    try runSimpleQueryNoReady(server, io, alloc, conn, writer, q);
    try writeMsg(writer, MSG_READY, "I");
    try writer.flush();
}

fn runSimpleQueryNoReady(server: *Server, io: std.Io, alloc: std.mem.Allocator, conn: *Conn, writer: *std.Io.Writer, q: []const u8) !void {
    const stmts = sql.splitStatements(alloc, q) catch {
        try sendError(alloc, writer, "42601", "could not split statements");
        return;
    };
    defer alloc.free(stmts);

    for (stmts) |text| {
        // Session/DDL no-ops and catalog introspection: real PostgreSQL clients
        // (psql \dt, ORMs, BI tools) issue these before any user query. Answering
        // them keeps the connection usable instead of failing on the first one.
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) continue;
        // Real transaction control (statement-level logical WAL).
        if (std.ascii.startsWithIgnoreCase(t, "BEGIN") or std.ascii.startsWithIgnoreCase(t, "START TRANSACTION")) {
            // BEGIN allocates a txid and registers it as in-flight: exclusive.
            server.mutex.lockUncancelable(io);
            server.engine.setTxnContext(&conn.txn);
            server.engine.beginTxn();
            server.engine.resetTxnContext();
            server.mutex.unlock(io);
            try writeCommandComplete(writer, "BEGIN");
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(t, "COMMIT") or
            (std.ascii.startsWithIgnoreCase(t, "END") and (t.len == 3 or t[3] == ' ' or t[3] == ';')))
        {
            // COMMIT drops dead versions and rebuilds the columnar copies of
            // the tables this transaction touched: exclusive.
            server.mutex.lockUncancelable(io);
            server.engine.setTxnContext(&conn.txn);
            server.engine.commitTxn(io) catch {};
            server.engine.resetTxnContext();
            server.mutex.unlock(io);
            server.locks.releaseAll(conn.txn.txid);
            try writeCommandComplete(writer, "COMMIT");
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(t, "ROLLBACK")) {
            server.mutex.lockUncancelable(io);
            server.engine.setTxnContext(&conn.txn);
            server.engine.rollbackTxn();
            server.engine.resetTxnContext();
            server.mutex.unlock(io);
            server.locks.releaseAll(conn.txn.txid);
            try writeCommandComplete(writer, "ROLLBACK");
            continue;
        }
        if (shimStatement(t)) |tag| {
            try writeCommandComplete(writer, tag);
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(t, "SHOW ")) {
            const show_name = std.mem.trim(u8, t[5..], " \t\r\n;");
            const is_sp = std.ascii.eqlIgnoreCase(show_name, "search_path");
            var cols = [_][]const u8{if (is_sp) "search_path" else "setting"};
            try sendRowDescription(alloc, writer, &cols);
            const sp = server.engine.currentSearchPath();
            var row = [_]value.Value{.{ .text = if (is_sp) sp else "zhdb" }};
            try sendDataRow(alloc, writer, &row);
            try writeCommandComplete(writer, "SHOW");
            continue;
        }

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var parser = sql.Parser.init(a, text) catch {
            try sendError(alloc, writer, "42601", "syntax error");
            return;
        };
        const stmt = parser.parseStatement() catch {
            try sendError(alloc, writer, "42601", "syntax error");
            return;
        };

        if (server.lazy_db) |ldb| {
            const v = lazyAggregate(ldb, stmt) catch |e| {
                try sendError(alloc, writer, "0A000", @errorName(e));
                continue;
            };
            var cols = [_][]const u8{"?column?"};
            try sendRowDescription(alloc, writer, &cols);
            var row = [_]value.Value{v};
            try sendDataRow(alloc, writer, &row);
            try writeCommandComplete(writer, "SELECT 1");
            continue;
        }

        // Write statements take a per-table lock *before* the global engine
        // mutex, so a blocked writer waits without blocking everyone else.
        const wt = writeTable(stmt);
        const owner: u64 = if (conn.txn.in_txn) conn.txn.txid else server.next_stmt_owner.fetchAdd(1, .monotonic);
        if (wt) |name| {
            if (std.c.getenv("ZHDB_EXPLAIN") != null) {
                std.debug.print("[lock] acquire owner={d} table={s} txn={}\n", .{ owner, name, conn.txn.in_txn });
            }
            server.locks.acquire(owner, name, 5_000_000_000) catch |e| {
                if (e == error.DeadlockDetected) {
                    try sendError(alloc, writer, "40P01", "deadlock detected");
                } else {
                    try sendError(alloc, writer, "55P03", "lock timeout");
                }
                // runSimpleQuery adds the single ReadyForQuery for this query.
                return;
            };
        }

        // Lazy snapshot tables must be filled in *before* any shared lock is
        // taken (that filling is a write).
        materializeReferenced(server, io, stmt);

        const kind = classifyStmt(server, stmt);
        const in_txn = conn.txn.in_txn;
        // Every table this statement touches, locked in lexicographic order so
        // concurrent statements can never deadlock on each other.
        var names: [64][]const u8 = undefined;
        var n_names: usize = 0;
        switch (stmt) {
            .select => |sel| {
                _ = collectTables(sel, &names, &n_names, 0);
            },
            else => {
                if (wt) |n| {
                    names[0] = n;
                    n_names = 1;
                }
            },
        }
        // insertion sort + dedupe
        var sort_i: usize = 1;
        while (sort_i < n_names) : (sort_i += 1) {
            const key = names[sort_i];
            var j = sort_i;
            while (j > 0 and std.mem.order(u8, names[j - 1], key) == .gt) : (j -= 1) names[j] = names[j - 1];
            names[j] = key;
        }
        var uniq: usize = 0;
        for (0..n_names) |k| {
            if (uniq > 0 and std.mem.eql(u8, names[uniq - 1], names[k])) continue;
            names[uniq] = names[k];
            uniq += 1;
        }
        n_names = uniq;

        const shared_global = kind != .other;
        if (std.c.getenv("ZHDB_EXPLAIN") != null) {
            std.debug.print("[lock] kind={s} tables={d} shared_global={}\n", .{ @tagName(kind), n_names, shared_global });
        }
        var locks_held: [64]?*std.Io.RwLock = undefined;
        @memset(&locks_held, null);
        var held: usize = 0;
        if (kind == .read or kind == .dml) {
            for (0..n_names) |k| {
                const l = tableRw(server, names[k]);
                if (kind == .dml) l.lockUncancelable(io) else l.lockSharedUncancelable(io);
                locks_held[held] = l;
                held += 1;
            }
        }
        if (shared_global) server.mutex.lockSharedUncancelable(io) else server.mutex.lockUncancelable(io);
        if (in_txn) server.engine.setTxnContext(&conn.txn);
        const res = server.engine.exec(a, stmt) catch |e| {
            server.engine.resetTxnContext();
            // A failed statement aborts the transaction; undo its writes and
            // session GUCs (PostgreSQL reports the abort at COMMIT time).
            if (in_txn and conn.txn.in_txn) {
                server.engine.setTxnContext(&conn.txn);
                server.engine.rollbackTxn();
                server.engine.resetTxnContext();
                server.locks.releaseAll(conn.txn.txid);
            }
            if (wt) |name| {
                if (!conn.txn.in_txn) server.locks.release(owner, name);
            }
            if (shared_global) server.mutex.unlockShared(io) else server.mutex.unlock(io);
            for (0..held) |i| {
                const l = locks_held[i].?;
                if (kind == .dml) l.unlock(io) else l.unlockShared(io);
            }
            var ni2: usize = 0;
            while (ni2 < engine_mod.noticeCount()) : (ni2 += 1) try sendNotice(alloc, writer, ni2);
            try sendError(alloc, writer, "42000", engine_mod.diagMessage() orelse @errorName(e));
            return;
        };
        if (shared_global) server.mutex.unlockShared(io) else server.mutex.unlock(io);
        for (0..held) |i| {
            const l = locks_held[i].?;
            if (kind == .dml) l.unlock(io) else l.unlockShared(io);
        }
        var ni: usize = 0;
        while (ni < engine_mod.noticeCount()) : (ni += 1) try sendNotice(alloc, writer, ni);

        // Durability: log DML statements (autocommit => flush, txn => buffer).
        switch (stmt) {
            .insert, .update, .delete, .truncate => server.engine.logStmt(io, t) catch {},
            else => {},
        }
        // Snapshot write-back: persist the mutated column store (and its
        // indexes) so a restart sees the same data.
        if (in_txn) server.engine.setTxnContext(&conn.txn);
        if (server.writeback) {
            if (server.db_path) |dp| {
                switch (stmt) {
                    .insert, .update, .delete, .truncate, .create_index, .vacuum => {
                        // Snapshot write-back mutates engine state (compaction):
                        // serialise it with the exclusive lock.
                        server.mutex.lockUncancelable(io);
                        server.engine.saveSnapshotFile(io, alloc, "hits", dp) catch {};
                        server.mutex.unlock(io);
                    },
                    else => {},
                }
            }
        }
        // Query-only processes never write data, so checkpoint the learned
        // planner constants into the snapshot trailer from here.
        server.engine.checkpointCosts(io);
        if (in_txn) server.engine.resetTxnContext();
        if (wt) |name| {
            if (!conn.txn.in_txn) server.locks.release(owner, name);
        }

        try sendResult(alloc, writer, res, stmt);
    }
}

fn sendResult(alloc: std.mem.Allocator, writer: *std.Io.Writer, res: engine_mod.Result, stmt: sql.Stmt) !void {
    if (res.columns.len > 0) {
        try sendRowDescription(alloc, writer, res.columns);
        for (res.rows) |row| try sendDataRow(alloc, writer, row);
        var tag: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&tag, "SELECT {d}", .{res.rows.len}) catch "SELECT";
        try writeCommandComplete(writer, t);
        return;
    }
    const verb: []const u8 = switch (stmt) {
        .insert => "INSERT 0",
        .delete => "DELETE",
        .update => "UPDATE",
        .create_index => "CREATE INDEX",
        .vacuum => "VACUUM",
        .create_table => "CREATE TABLE",
        .drop_table => "DROP TABLE",
        .truncate => "TRUNCATE TABLE",
        else => "SET",
    };
    var tag: [96]u8 = undefined;
    const t = switch (stmt) {
        .insert, .delete, .update => std.fmt.bufPrint(&tag, "{s} {d}", .{ verb, res.affected }) catch verb,
        else => verb,
    };
    try writeCommandComplete(writer, t);
}

fn sendRowDescription(alloc: std.mem.Allocator, writer: *std.Io.Writer, columns: []const []const u8) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    var n: [2]u8 = undefined;
    std.mem.writeInt(u16, &n, @intCast(columns.len), .big);
    try buf.appendSlice(alloc, &n);
    for (columns) |c| {
        try buf.appendSlice(alloc, c);
        try buf.append(alloc, 0);
        try writeInt32(&buf, alloc, 0); // table oid
        var f: [6]u8 = undefined;
        std.mem.writeInt(i16, f[0..2], 0, .big); // attnum
        std.mem.writeInt(u32, f[2..6], 25, .big); // text
        try buf.appendSlice(alloc, &f);
        var meta: [6]u8 = undefined;
        std.mem.writeInt(i16, meta[0..2], -1, .big); // typlen
        std.mem.writeInt(i32, meta[2..6], -1, .big); // typmod
        try buf.appendSlice(alloc, &meta);
        try buf.appendSlice(alloc, &[_]u8{0, 0}); // format text
    }
    try writeMsg(writer, MSG_ROW_DESC, buf.items);
}

fn sendDataRow(alloc: std.mem.Allocator, writer: *std.Io.Writer, row: []const Value) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    var n: [2]u8 = undefined;
    std.mem.writeInt(u16, &n, @intCast(row.len), .big);
    try buf.appendSlice(alloc, &n);
    for (row) |v| {
        if (v.isNull()) {
            try writeInt32(&buf, alloc, -1);
            continue;
        }
        const s = if (v == .boolean) (if (v.boolean) "t" else "f") else engine_mod.formatValue(alloc, v) catch "";
        try writeInt32(&buf, alloc, @intCast(s.len));
        try buf.appendSlice(alloc, s);
    }
    try writeMsg(writer, MSG_DATA_ROW, buf.items);
}

fn sendNotice(alloc: std.mem.Allocator, writer: *std.Io.Writer, idx: usize) !void {
    const sev = if (engine_mod.noticeIsWarning(idx)) "WARNING" else if (engine_mod.noticeIsInfo(idx)) "INFO" else "NOTICE";
    var b = std.ArrayList(u8).empty;
    defer b.deinit(alloc);
    try b.append(alloc, 'S');
    try b.appendSlice(alloc, sev);
    try b.append(alloc, 0);
    try b.append(alloc, 'V');
    try b.appendSlice(alloc, sev);
    try b.append(alloc, 0);
    try b.append(alloc, 'C');
    try b.appendSlice(alloc, "00000");
    try b.append(alloc, 0);
    try b.append(alloc, 'M');
    try b.appendSlice(alloc, engine_mod.noticeAt(idx));
    try b.append(alloc, 0);
    const det = engine_mod.noticeDetail(idx);
    if (det.len > 0) {
        try b.append(alloc, 'D');
        try b.appendSlice(alloc, det);
        try b.append(alloc, 0);
    }
    const hint = engine_mod.noticeHint(idx);
    if (hint.len > 0) {
        try b.append(alloc, 'H');
        try b.appendSlice(alloc, hint);
        try b.append(alloc, 0);
    }
    try b.append(alloc, 0);
    try writeMsg(writer, 'N', b.items);
}

fn sendError(alloc: std.mem.Allocator, writer: *std.Io.Writer, code: []const u8, msg: []const u8) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, "SERROR\x00VERROR\x00C");
    try buf.appendSlice(alloc, code);
    try buf.append(alloc, 0);
    try buf.append(alloc, 'M');
    try buf.appendSlice(alloc, msg);
    try buf.append(alloc, 0);
    try buf.append(alloc, 0);
    try writeMsg(writer, MSG_ERROR, buf.items);
    try writer.flush();
}

fn describeQuery(server: *Server, io: std.Io, alloc: std.mem.Allocator, writer: *std.Io.Writer, q: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var parser = sql.Parser.init(a, q) catch {
        try writeMsg(writer, MSG_NO_DATA, "");
        return;
    };
    const stmt = parser.parseStatement() catch {
        try writeMsg(writer, MSG_NO_DATA, "");
        return;
    };
    if (stmt == .select) {
        server.mutex.lockUncancelable(io);
        const res = server.engine.exec(a, stmt) catch {
            server.mutex.unlock(io);
            try writeMsg(writer, MSG_NO_DATA, "");
            return;
        };
        server.mutex.unlock(io);
        try sendRowDescription(alloc, writer, res.columns);
    } else {
        try writeMsg(writer, MSG_NO_DATA, "");
    }
    try writer.flush();
}
