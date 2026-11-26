const std = @import("std");
const builtin = @import("builtin");
extern "c" fn malloc_zone_pressure_relief(zone: ?*anyopaque, goal: usize) usize;
const sql = @import("sql.zig");
const engine_mod = @import("engine.zig");
const columnar_mod = @import("columnar.zig");
const pg = @import("pg.zig");
const jit = @import("jit.zig");
const columnar = @import("columnar.zig");
const storage = @import("storage.zig");
const tls_mod = @import("tls.zig");
const lockmgr = @import("lockmgr.zig");
const mutex_alloc = @import("mutex_alloc.zig");
const Value = @import("value.zig").Value;
const usage =
    \\zhdb - a PostgreSQL-wire-compatible SQL engine written in Zig 0.17
    \\
    \\Usage:
    \\  zhdb serve [--port=5432]
    \\  zhdb run <file.sql> [--json]
    \\  zhdb query "<sql>"
    \\  zhdb load <file.tsv>        # first line: #schema: name:type<TAB>...
    \\  zhdb bench <queries.txt> [--repeat=N]
    \\  zhdb stat <db.zdb>          # catalog + block index + compression ratio
    \\  zhdb lookup --db=<db.zdb> --column=<name> --value=<int> [--hi=<int>] [--index=<idx>] [--cache=<pages>]\n    \\  zhdb index  --db=<db.zdb> --column=<name> --out=<idx>   # sorted key index\n    \\  zhdb scan --db=<db.zdb> --column=<name> --agg=count|sum|min|max [--filter-col= --filter-op= --filter-value=]
    \\  zhdb jitbench --load=<tsv>   # JIT vs Zig kernel comparison
    \\  zhdb version
    \\
;
pub fn main(init: std.process.Init) !void {
    const gpa: std.mem.Allocator = if (std.c.getenv("ZHDB_LIBC_ALLOC") != null) std.heap.c_allocator else std.heap.smp_allocator;
    const io = init.io;
    const safe = mutex_alloc.MutexAlloc.init(io, gpa);
    const engine_gpa = safe.allocator();
    const stdout = std.Io.File.stdout();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit(); _ = args.next();
    const cmd = args.next() orelse {
        try stdout.writeStreamingAll(io, usage); return;
    };
    var engine = engine_mod.Engine.init(engine_gpa); engine.io = io;
    defer engine.deinit();
    if (std.mem.eql(u8, cmd, "serve")) {
        var port: u16 = 5432;
        var load_path: ?[]const u8 = null;
        var db_path: ?[]const u8 = null;
        var wal_path: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var mem_budget: u64 = std.math.maxInt(u64);
        var use_tls = false;
        var writeback = false;
        var gc_ms: u64 = 0;
        while (args.next()) |a| {
            if (std.mem.startsWith(u8, a, "--port=")) port = std.fmt.parseInt(u16, a["--port=".len..], 10) catch 5432;
            if (std.mem.startsWith(u8, a, "--load=")) load_path = a["--load=".len..];
            if (std.mem.startsWith(u8, a, "--db=")) db_path = a["--db=".len..];
            if (std.mem.startsWith(u8, a, "--wal=")) wal_path = a["--wal=".len..];
            if (std.mem.startsWith(u8, a, "--password=")) password = a["--password=".len..];
            if (std.mem.startsWith(u8, a, "--mem-budget=")) mem_budget = parseSize(a["--mem-budget=".len..]) catch std.math.maxInt(u64);
            if (std.mem.eql(u8, a, "--tls")) use_tls = true;
            if (std.mem.eql(u8, a, "--writeback")) writeback = true;
            if (std.mem.startsWith(u8, a, "--gc-ms=")) gc_ms = std.fmt.parseInt(u64, a["--gc-ms=".len..], 10) catch 0;
        }
        var lazy: ?storage.Db = null;
        if (db_path) |dp| {
            const f0 = try std.Io.Dir.cwd().openFile(io, dp, .{});
            const fsize = (try f0.stat(io)).size; f0.close(io);
            if (fsize > mem_budget) {
                const f1 = try std.Io.Dir.cwd().openFile(io, dp, .{});
                lazy = try storage.Db.open(gpa, io, f1, fsize, 64);
                std.debug.print("[plan] lazy mode: {s} is {d} MB > budget {d} MB -> streaming aggregates\n", .{
                    dp, fsize / (1024 * 1024), mem_budget / (1024 * 1024),
                });
            } else {
                try loadSnapshot(&engine, io, gpa, dp);
            }
        } else if (load_path) |lp| try loadFile(&engine, io, gpa, lp);
        if (wal_path) |wp| {
            engine.openWal(wp);
            const n = try engine.replayWal(io, gpa);
            std.debug.print("wal replayed: {d} statements from {s}\n", .{ n, wp });
        }
        var server = pg.Server{
            .engine = &engine,
            .password = password,
            .lazy_db = if (lazy) |*l| l else null,
            .tls = use_tls,
            .db_path = db_path,
            .writeback = writeback,
            .gc_interval_ms = gc_ms,
        }; engine.background_gc = gc_ms > 0;
        try pg.serve(&server, io, port);
    } else if (std.mem.eql(u8, cmd, "run")) {
        const path = args.next() orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        var force_json = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--json")) force_json = true;
        }
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
        defer gpa.free(src);
        var out = std.ArrayList(u8).empty; defer out.deinit(gpa);
        const had_error = try runScript(&engine, io, gpa, src, force_json, &out);
        try stdout.writeStreamingAll(io, out.items); if (had_error) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "query")) {
        const q = args.next() orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        var out = std.ArrayList(u8).empty; defer out.deinit(gpa);
        const had_error = try runScript(&engine, io, gpa, q, false, &out);
        try stdout.writeStreamingAll(io, out.items); if (had_error) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "load")) {
        const path = args.next() orelse {
            try stdout.writeStreamingAll(io, usage); return;
        }; try loadFile(&engine, io, gpa, path);
    } else if (std.mem.eql(u8, cmd, "copy")) {
        const src = args.next() orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        const dst = args.next() orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        if (std.c.getenv("ZHDB_COL_LOAD") != null) {
            try loadFileColumnar(&engine, io, gpa, src);
        } else {
            try loadFile(&engine, io, gpa, src);
        }
        try saveSnapshot(&engine, io, gpa, "hits", dst);
    } else if (std.mem.eql(u8, cmd, "bench")) {
        var repeat: usize = 1;
        var load_path: ?[]const u8 = null;
        var db_path: ?[]const u8 = null;
        var mem_budget: u64 = std.math.maxInt(u64);
        var path: ?[]const u8 = null;
        while (args.next()) |a| {
            if (std.mem.startsWith(u8, a, "--repeat=")) {
                repeat = std.fmt.parseInt(usize, a["--repeat=".len..], 10) catch 1;
            } else if (std.mem.startsWith(u8, a, "--load=")) {
                load_path = a["--load=".len..];
            } else if (std.mem.startsWith(u8, a, "--db=")) {
                db_path = a["--db=".len..];
            } else if (std.mem.startsWith(u8, a, "--mem-budget=")) {
                mem_budget = parseSize(a["--mem-budget=".len..]) catch std.math.maxInt(u64);
            } else {
                path = a;
            }
        }
        if (path == null) {
            try stdout.writeStreamingAll(io, usage); return;
        }
        if (db_path) |dp| {
            const f0 = try std.Io.Dir.cwd().openFile(io, dp, .{});
            const fsize = (try f0.stat(io)).size; f0.close(io);
            if (fsize > mem_budget) {
                const f1 = try std.Io.Dir.cwd().openFile(io, dp, .{}); defer f1.close(io);
                var db = try storage.Db.open(gpa, io, f1, fsize, 64); defer db.deinit();
                std.debug.print("[plan] lazy bench: {d} MB > budget {d} MB\n", .{ fsize / (1024 * 1024), mem_budget / (1024 * 1024) });
                try benchFileLazy(&db, io, gpa, path.?, repeat); return;
            }
            try loadSnapshot(&engine, io, gpa, dp);
        } else if (load_path) |lp| {
            if (std.c.getenv("ZHDB_COL_LOAD") != null) {
                try loadFileColumnar(&engine, io, gpa, lp);
            } else {
                try loadFile(&engine, io, gpa, lp);
            }
            if (std.c.getenv("ZHDB_BENCH_DROP_ROWS") != null) engine.dropRowsForBench("hits");
        }
        try benchFile(&engine, io, gpa, path.?, repeat);
    } else if (std.mem.eql(u8, cmd, "stat")) {
        const path = args.next() orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        const file = try std.Io.Dir.cwd().openFile(io, path, .{}); defer file.close(io);
        const size = (try file.stat(io)).size;
        var db = try storage.Db.open(gpa, io, file, size, 8); defer db.deinit();
        var out = std.ArrayList(u8).empty; defer out.deinit(gpa);
        const head = try std.fmt.allocPrint(gpa, "zhdb db {s}: version {d}, {d} rows, {d} cols, {d} bytes\n", .{ path, db.version, db.nrows, db.cols.len, size });
        defer gpa.free(head); try out.appendSlice(gpa, head);
        for (db.cols, 0..) |c, ci| {
            var data_bytes: u64 = 0; for (c.blocks) |b| data_bytes += b.dlen;
            if (c.kind == .str) data_bytes += c.dict_clen;
            const kind: []const u8 = switch (c.kind) {
                .int => "int",
                .float => "float",
                .str => "text",
            };
            const line = try std.fmt.allocPrint(gpa, "  {d:>2} {s:<20} {s:<6} blocks={d:<4} data={d:>10} ({d:.1}% of file)\n", .{
                ci, c.name, kind, c.blocks.len, data_bytes, @as(f64, @floatFromInt(data_bytes)) * 100.0 / @as(f64, @floatFromInt(size)),
            }); defer gpa.free(line);
            try out.appendSlice(gpa, line);
        }
        try stdout.writeStreamingAll(io, out.items);
    } else if (std.mem.eql(u8, cmd, "index")) {
        var db_path: ?[]const u8 = null;
        var column: ?[]const u8 = null;
        var out_path: ?[]const u8 = null;
        var embed = false;
        while (args.next()) |a| {
            if (std.mem.startsWith(u8, a, "--db=")) db_path = a["--db=".len..];
            if (std.mem.startsWith(u8, a, "--column=")) column = a["--column=".len..];
            if (std.mem.startsWith(u8, a, "--out=")) out_path = a["--out=".len..];
            if (std.mem.eql(u8, a, "--embed")) embed = true;
        }
        const path = db_path orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        const col = column orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        const outp = out_path orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        if (embed) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024 * 1024));
            defer gpa.free(bytes);
            const t = try columnar_mod.Table.loadBytes(gpa, bytes); defer t.destroy(gpa);
            const ci2 = t.find(col) orelse {
                try stdout.writeStreamingAll(io, "no such column\n"); return;
            };
            const vals = switch (t.data[ci2]) {
                .ints => |v| v,
                else => {
                    try stdout.writeStreamingAll(io, "index: only int columns\n"); return;
                },
            };
            if (t.keyidx.len == 0) {
                t.keyidx = try t.arena.allocator().alloc(?*columnar_mod.KeyIndex, t.cols.len);
                @memset(t.keyidx, null);
            }
            const t0 = std.Io.Clock.now(.awake, io).nanoseconds;
            t.keyidx[ci2] = try columnar_mod.KeyIndex.build(t.arena.allocator(), vals, t.block_rows);
            const dt = @as(f64, @floatFromInt(std.Io.Clock.now(.awake, io).nanoseconds - t0)) / 1e6;
            var buf = std.ArrayList(u8).empty; defer buf.deinit(gpa);
            try t.save(gpa, &buf);
            const dst = out_path orelse path;
            const outf = try std.Io.Dir.cwd().createFile(io, dst, .{});
            defer outf.close(io); try outf.writeStreamingAll(io, buf.items);
            const line = try std.fmt.allocPrint(gpa, "embedded index {s}.{s}: keys={d} rows={d} bytes={d} build={d:.1} ms -> {s}\n", .{
                path, col, t.keyidx[ci2].?.keys.len, t.keyidx[ci2].?.rows.len, buf.items.len, dt, dst,
            }); defer gpa.free(line);
            try stdout.writeStreamingAll(io, line); return;
        }
        const file = try std.Io.Dir.cwd().openFile(io, path, .{}); defer file.close(io);
        const size = (try file.stat(io)).size;
        var db = try storage.Db.open(gpa, io, file, size, 64); defer db.deinit();
        const ci = db.findColumn(col) orelse {
            try stdout.writeStreamingAll(io, "no such column\n"); return;
        };
        const t0 = std.Io.Clock.now(.awake, io).nanoseconds;
        var idx = try storage.Index.build(&db, ci, gpa); defer idx.deinit();
        const dt = @as(f64, @floatFromInt(std.Io.Clock.now(.awake, io).nanoseconds - t0)) / 1e6;
        var buf = std.ArrayList(u8).empty; defer buf.deinit(gpa);
        try idx.serialize(gpa, &buf);
        const out_file = try std.Io.Dir.cwd().createFile(io, outp, .{});
        defer out_file.close(io); try out_file.writeStreamingAll(io, buf.items);
        const line = try std.fmt.allocPrint(gpa, "index {s}.{s}: keys={d} rows={d} bytes={d} build={d:.1} ms -> {s}\n", .{
            path, col, idx.keys.len, idx.rows.len, buf.items.len, dt, outp,
        }); defer gpa.free(line);
        try stdout.writeStreamingAll(io, line);
    } else if (std.mem.eql(u8, cmd, "lookup")) {
        var db_path: ?[]const u8 = null;
        var column: ?[]const u8 = null;
        var value: i64 = 0;
        var hi: ?i64 = null;
        var index_path: ?[]const u8 = null;
        var cache_pages: usize = 16;
        while (args.next()) |a| {
            if (std.mem.startsWith(u8, a, "--db=")) {
                db_path = a["--db=".len..];
            } else if (std.mem.startsWith(u8, a, "--column=")) {
                column = a["--column=".len..];
            } else if (std.mem.startsWith(u8, a, "--value=")) {
                value = std.fmt.parseInt(i64, a["--value=".len..], 10) catch 0;
            } else if (std.mem.startsWith(u8, a, "--hi=")) {
                hi = std.fmt.parseInt(i64, a["--hi=".len..], 10) catch null;
            } else if (std.mem.startsWith(u8, a, "--index=")) {
                index_path = a["--index=".len..];
            } else if (std.mem.startsWith(u8, a, "--cache=")) {
                cache_pages = std.fmt.parseInt(usize, a["--cache=".len..], 10) catch 16;
            }
        }
        const path = db_path orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        const col = column orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        const file = try std.Io.Dir.cwd().openFile(io, path, .{}); defer file.close(io);
        const size = (try file.stat(io)).size;
        var db = try storage.Db.open(gpa, io, file, size, cache_pages); defer db.deinit();
        const ci = db.findColumn(col) orelse {
            try stdout.writeStreamingAll(io, "no such column\n"); return;
        };
        const cand = try db.candidates(ci, value, hi orelse value, gpa);
        defer gpa.free(cand);
        var matched: usize = 0;
        var via_index = false;
        var index_keys: usize = 0;
        var index_rows: usize = 0;
        if (index_path) |ip| {
            const ibytes = try std.Io.Dir.cwd().readFileAlloc(io, ip, gpa, .limited(1024 * 1024 * 1024));
            defer gpa.free(ibytes);
            var idx = try storage.Index.load(gpa, ibytes); defer idx.deinit();
            via_index = true; index_keys = idx.keys.len;
            index_rows = idx.rows.len;
            var rowids = std.ArrayList(u32).empty; defer rowids.deinit(gpa);
            try idx.range(value, hi orelse value, &rowids);
            var last_block: i64 = -1;
            const buf = try gpa.alloc(i64, storage.max_block_rows); defer gpa.free(buf);
            for (rowids.items) |rid| {
                const bi: i64 = @intCast(rid / storage.max_block_rows);
                if (bi == last_block) continue; last_block = bi;
                const b = db.cols[ci].blocks[@intCast(bi)];
                try db.readIntBlock(ci, @intCast(bi), buf);
                const start: usize = @intCast(rid % storage.max_block_rows); _ = start;
                const rows_n: usize = b.rows;
                for (buf[0..rows_n]) |v| {
                    const keep = if (hi) |h| (v >= value and v <= h) else (v == value);
                    if (keep) matched += 1;
                }
            }
        } else if (hi) |h| {
            const buf = try gpa.alloc(i64, storage.max_block_rows); defer gpa.free(buf);
            for (cand) |bi| {
                try db.readIntBlock(ci, bi, buf);
                const rows_n: usize = db.cols[ci].blocks[bi].rows;
                for (buf[0..rows_n]) |v| {
                    if (v >= value and v <= h) matched += 1;
                }
            }
        } else {
            matched = try db.countEqual(ci, value);
        }
        var out = std.ArrayList(u8).empty; defer out.deinit(gpa);
        const line1 = if (hi) |h|
            try std.fmt.allocPrint(gpa, "lookup {s} in [{d}, {d}]\n", .{ col, value, h })
        else
            try std.fmt.allocPrint(gpa, "lookup {s} = {d}\n", .{ col, value });
        defer gpa.free(line1); try out.appendSlice(gpa, line1);
        const line2 = try std.fmt.allocPrint(gpa, "  matched rows : {d}\n", .{matched});
        defer gpa.free(line2); try out.appendSlice(gpa, line2);
        const line3 = if (via_index)
            try std.fmt.allocPrint(gpa, "  index        : keys={d} postings={d} (used for lookup)\n", .{ index_keys, index_rows })
        else
            try std.fmt.allocPrint(gpa, "  blocks       : {d} of {d} examined (sparse index pruned {d})\n", .{
                cand.len, db.blockCount(ci), db.blockCount(ci) - cand.len,
            });
        defer gpa.free(line3); try out.appendSlice(gpa, line3);
        const line4 = try std.fmt.allocPrint(gpa, "  page cache   : {d} pages x {d} KiB, hits={d} misses={d} evictions={d}\n", .{
            cache_pages, storage.page_size / 1024, db.pool.stats.hits, db.pool.stats.misses, db.pool.stats.evictions,
        }); defer gpa.free(line4);
        try out.appendSlice(gpa, line4); try stdout.writeStreamingAll(io, out.items);
    } else if (std.mem.eql(u8, cmd, "stream")) {
        var db_path: ?[]const u8 = null;
        var sql_text: ?[]const u8 = null;
        var cache_pages: usize = 8;
        var auto_pick = false;
        while (args.next()) |a| {
            if (std.mem.startsWith(u8, a, "--db=")) {
                db_path = a["--db=".len..];
            } else if (std.mem.startsWith(u8, a, "--cache=")) {
                cache_pages = std.fmt.parseInt(usize, a["--cache=".len..], 10) catch 8;
            } else if (std.mem.eql(u8, a, "--auto")) {
                auto_pick = true;
            } else {
                sql_text = a;
            }
        }
        const path = db_path orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        const text = sql_text orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        var arena = std.heap.ArenaAllocator.init(gpa); defer arena.deinit();
        const a2 = arena.allocator();
        var parser = sql.Parser.init(a2, text) catch {
            try stdout.writeStreamingAll(io, "syntax error\n"); return;
        };
        const stmt = parser.parseStatement() catch {
            try stdout.writeStreamingAll(io, "syntax error\n"); return;
        };
        if (stmt != .select) {
            try stdout.writeStreamingAll(io, "stream: only SELECT is supported\n");
            return;
        }
        const sel = stmt.select;
        switch (sel.from orelse {
            try stdout.writeStreamingAll(io, "stream: need FROM\n"); return;
        }) {
            .table => {},
            else => {
                try stdout.writeStreamingAll(io, "stream: table only\n"); return;
            },
        }
        const KeyName = []const u8;
        const AggItem = struct { kind: storage.Agg, col: ?KeyName, distinct: bool, avg: bool };
        var keys = std.ArrayList(KeyName).empty; defer keys.deinit(gpa);
        var aggs = std.ArrayList(AggItem).empty; defer aggs.deinit(gpa);
        for (sel.items) |it| {
            switch (it.expr.*) {
                .call => |c| {
                    var kind: storage.Agg = undefined;
                    var avg = false;
                    if (std.ascii.eqlIgnoreCase(c.name, "sum")) {
                        kind = .sum;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "min")) {
                        kind = .min;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "max")) {
                        kind = .max;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "avg")) {
                        kind = .sum; avg = true;
                    } else if (std.ascii.eqlIgnoreCase(c.name, "count")) {
                        kind = .count;
                    } else {
                        try stdout.writeStreamingAll(io, "stream: count/sum/min/max/avg only\n");
                        return;
                    }
                    var col: ?KeyName = null;
                    if (c.args.len == 1) {
                        col = switch (c.args[0].*) {
                            .column => |n| n,
                            .column_idx => |ci| ci.name,
                            else => null,
                        };
                        if (col == null) {
                            try stdout.writeStreamingAll(io, "stream: aggregate needs a plain column\n");
                            return;
                        }
                    } else if (kind != .count) {
                        try stdout.writeStreamingAll(io, "stream: aggregate needs a column\n");
                        return;
                    }
                    try aggs.append(gpa, .{ .kind = kind, .col = col, .distinct = c.distinct, .avg = avg });
                },
                .column => |n| try keys.append(gpa, n),
                .column_idx => |ci| try keys.append(gpa, ci.name),
                else => {
                    try stdout.writeStreamingAll(io, "stream: keys must be plain columns\n");
                    return;
                },
            }
        }
        if (aggs.items.len == 0) {
            try stdout.writeStreamingAll(io, "stream: need at least one aggregate\n");
            return;
        }
        if (keys.items.len > 0 and sel.group_by.len != keys.items.len) {
            try stdout.writeStreamingAll(io, "stream: GROUP BY must list the selected keys\n");
            return;
        }
        const file = try std.Io.Dir.cwd().openFile(io, path, .{}); defer file.close(io);
        const size = (try file.stat(io)).size;
        var db = try storage.Db.open(gpa, io, file, size, cache_pages); defer db.deinit();
        var filter: ?storage.ScanFilter = null;
        var str_filter: ?storage.StrFilter = null;
        if (sel.where) |w| {
            if (w.* != .binary) {
                try stdout.writeStreamingAll(io, "stream: predicate must be a single comparison\n");
                return;
            }
            const b = w.binary;
            const col_e = if (b.lhs.* == .int or b.lhs.* == .string) b.rhs else b.lhs;
            const val_e = if (col_e == b.lhs) b.rhs else b.lhs;
            const cname = switch (col_e.*) {
                .column => |n| n,
                .column_idx => |c| c.name,
                else => {
                    try stdout.writeStreamingAll(io, "stream: predicate needs a column\n");
                    return;
                },
            };
            const fci = db.findColumn(cname) orelse {
                try stdout.writeStreamingAll(io, "stream: unknown filter column\n");
                return;
            };
            if (val_e.* == .string) {
                if (b.op != .eq and b.op != .neq) {
                    try stdout.writeStreamingAll(io, "stream: string predicate supports = / <>\n");
                    return;
                }
                str_filter = .{ .ci = fci, .want = val_e.string, .negated = b.op == .neq };
            } else {
                if (val_e.* != .int) {
                    try stdout.writeStreamingAll(io, "stream: predicate literal must be int\n");
                    return;
                }
                const op: storage.Op = switch (b.op) {
                    .eq => .eq,
                    .neq => .neq,
                    .lt => .lt,
                    .gt => .gt,
                    .le => .le,
                    .ge => .ge,
                    else => {
                        try stdout.writeStreamingAll(io, "stream: unsupported operator\n");
                        return;
                    },
                }; filter = .{ .ci = fci, .op = op, .k = val_e.int };
            }
        }
        const key_idx = try gpa.alloc(usize, keys.items.len); defer gpa.free(key_idx);
        for (keys.items, 0..) |kn, i| {
            key_idx[i] = db.findColumn(kn) orelse {
                try stdout.writeStreamingAll(io, "stream: unknown key column\n"); return;
            };
        }
        const specs = try gpa.alloc(storage.AggSpec, aggs.items.len);
        defer gpa.free(specs);
        for (aggs.items, 0..) |ai, i| {
            const ci: ?usize = if (ai.col) |n| db.findColumn(n) orelse {
                try stdout.writeStreamingAll(io, "stream: unknown aggregate column\n");
                return;
            } else null;
            specs[i] = .{ .kind = ai.kind, .col = ci, .distinct = ai.distinct, .avg = ai.avg };
        }
        if (auto_pick) {
            var bytes: u64 = 0;
            for (key_idx) |ci| {
                var n: usize = 0; for (db.cols[ci].blocks) |b| n += b.dlen;
                bytes += n;
            }
            for (specs) |sp| {
                if (sp.col) |ci| {
                    for (db.cols[ci].blocks) |b| bytes += b.dlen;
                }
            }
            const use_mem = bytes < 2 * 1024 * 1024 and db.nrows < 100_000;
            std.debug.print("[plan] stream-cost: rows={d} bytes={d} -> {s}\n", .{
                db.nrows, bytes, if (use_mem) "in-memory" else "streaming",
            });
            if (use_mem) {
                db.deinit();
                var eng = engine_mod.Engine.init(engine_gpa); eng.io = io;
                defer eng.deinit(); try loadSnapshot(&eng, io, gpa, path);
                const res = try eng.exec(a2, stmt);
                var out2 = std.ArrayList(u8).empty; defer out2.deinit(gpa);
                for (res.rows) |row| {
                    for (row, 0..) |v, i| {
                        if (i > 0) try out2.append(gpa, '\t');
                        const sv = try engine_mod.formatValue(gpa, v); defer gpa.free(sv);
                        try out2.appendSlice(gpa, sv);
                    }
                    try out2.append(gpa, '\n');
                }
                try stdout.writeStreamingAll(io, out2.items); return;
            }
        }
        var limit: usize = 10;
        if (sel.limit) |le| {
            if (le.* == .int and le.int > 0) limit = @intCast(le.int);
        }
        var desc = true;
        var order_spec: usize = 0;
        for (sel.order_by) |ob| {
            desc = ob.desc;
            switch (ob.expr.*) {
                .int => |n| {
                    const nn: usize = @intCast(n);
                    if (nn > keys.items.len and nn - keys.items.len <= specs.len) order_spec = nn - keys.items.len - 1;
                },
                .column => |alias| {
                    var agg_i: usize = 0;
                    for (sel.items) |it| {
                        const is_agg = it.expr.* == .call;
                        const name = it.alias orelse {
                            if (is_agg) agg_i += 1; continue;
                        };
                        if (is_agg and std.ascii.eqlIgnoreCase(name, alias)) order_spec = agg_i;
                        if (is_agg) agg_i += 1;
                    }
                },
                .call => |c| {
                    for (aggs.items, 0..) |ai, i| {
                        if (ai.kind == .count and std.ascii.eqlIgnoreCase(c.name, "count")) order_spec = i;
                        if (std.ascii.eqlIgnoreCase(c.name, "sum") and ai.kind == .sum and !ai.avg) order_spec = i;
                        if (std.ascii.eqlIgnoreCase(c.name, "min") and ai.kind == .min) order_spec = i;
                        if (std.ascii.eqlIgnoreCase(c.name, "max") and ai.kind == .max) order_spec = i;
                        if (std.ascii.eqlIgnoreCase(c.name, "avg") and ai.avg) order_spec = i;
                    }
                },
                else => {},
            }
        }
        const t0 = std.Io.Clock.now(.awake, io).nanoseconds;
        const rows = db.streamGroupMulti(a2, key_idx, specs, filter, str_filter, limit, order_spec, desc) catch |e| {
            const msg = try std.fmt.allocPrint(gpa, "stream error: {s}\n", .{@errorName(e)});
            defer gpa.free(msg); try stdout.writeStreamingAll(io, msg);
            return;
        };
        const dt = @as(f64, @floatFromInt(std.Io.Clock.now(.awake, io).nanoseconds - t0)) / 1e6;
        var out = std.ArrayList(u8).empty; defer out.deinit(gpa);
        for (rows) |r| {
            if (keys.items.len > 0) {
                for (r.key) |ch| {
                    try out.append(gpa, if (ch == 0x1f) '\t' else ch);
                }
                try out.append(gpa, '\t');
            }
            for (specs, 0..) |sp, j| {
                if (j > 0) try out.append(gpa, '\t');
                if (sp.avg) {
                    const t = try std.fmt.allocPrint(gpa, "{d}", .{r.fl[j]});
                    defer gpa.free(t); try out.appendSlice(gpa, t);
                } else {
                    const t = try std.fmt.allocPrint(gpa, "{d}", .{r.vals[j]});
                    defer gpa.free(t); try out.appendSlice(gpa, t);
                }
            }
            try out.append(gpa, '\n');
        }
        std.debug.print("stream-group: rows={d} {d:.2} ms cache={d} hits={d} misses={d}\n", .{
            rows.len, dt, cache_pages, db.pool.stats.hits, db.pool.stats.misses,
        }); try stdout.writeStreamingAll(io, out.items);
    } else if (std.mem.eql(u8, cmd, "scan")) {
        var db_path: ?[]const u8 = null;
        var column: ?[]const u8 = null;
        var agg_name: []const u8 = "count";
        var filter_col: ?[]const u8 = null;
        var filter_op_name: []const u8 = "eq";
        var filter_value: i64 = 0;
        var has_filter = false;
        var cache_pages: usize = 8;
        while (args.next()) |a| {
            if (std.mem.startsWith(u8, a, "--db=")) {
                db_path = a["--db=".len..];
            } else if (std.mem.startsWith(u8, a, "--column=")) {
                column = a["--column=".len..];
            } else if (std.mem.startsWith(u8, a, "--agg=")) {
                agg_name = a["--agg=".len..];
            } else if (std.mem.startsWith(u8, a, "--filter-col=")) {
                filter_col = a["--filter-col=".len..];
            } else if (std.mem.startsWith(u8, a, "--filter-op=")) {
                filter_op_name = a["--filter-op=".len..];
            } else if (std.mem.startsWith(u8, a, "--filter-value=")) {
                filter_value = std.fmt.parseInt(i64, a["--filter-value=".len..], 10) catch 0;
                has_filter = true;
            } else if (std.mem.startsWith(u8, a, "--cache=")) {
                cache_pages = std.fmt.parseInt(usize, a["--cache=".len..], 10) catch 8;
            }
        }
        const path = db_path orelse {
            try stdout.writeStreamingAll(io, usage); return;
        };
        const col = column orelse "UserID";
        const file = try std.Io.Dir.cwd().openFile(io, path, .{}); defer file.close(io);
        const size = (try file.stat(io)).size;
        var db = try storage.Db.open(gpa, io, file, size, cache_pages); defer db.deinit();
        const ci = db.findColumn(col) orelse {
            try stdout.writeStreamingAll(io, "no such column\n"); return;
        };
        const agg: storage.Agg = if (std.mem.eql(u8, agg_name, "sum"))
            .sum
        else if (std.mem.eql(u8, agg_name, "min"))
            .min
        else if (std.mem.eql(u8, agg_name, "max"))
            .max
        else
            .count;
        var filter: ?storage.ScanFilter = null;
        if (has_filter) {
            const fci = db.findColumn(filter_col orelse col) orelse {
                try stdout.writeStreamingAll(io, "no such filter column\n"); return;
            };
            const op: storage.Op = if (std.mem.eql(u8, filter_op_name, "ne") or std.mem.eql(u8, filter_op_name, "<>"))
                .neq
            else if (std.mem.eql(u8, filter_op_name, "lt"))
                .lt
            else if (std.mem.eql(u8, filter_op_name, "gt"))
                .gt
            else if (std.mem.eql(u8, filter_op_name, "le"))
                .le
            else if (std.mem.eql(u8, filter_op_name, "ge"))
                .ge
            else
                .eq;
            filter = .{ .ci = fci, .op = op, .k = filter_value };
        }
        const t0 = std.Io.Clock.now(.awake, io).nanoseconds;
        const res = db.streamAgg(ci, agg, filter, null) catch |e| {
            const msg = try std.fmt.allocPrint(gpa, "stream error: {s}\n", .{@errorName(e)});
            defer gpa.free(msg); try stdout.writeStreamingAll(io, msg);
            return;
        };
        const dt = @as(f64, @floatFromInt(std.Io.Clock.now(.awake, io).nanoseconds - t0)) / 1e6;
        var out = std.ArrayList(u8).empty; defer out.deinit(gpa);
        const lines = [_][]const u8{
            try std.fmt.allocPrint(gpa, "stream {s}({s}){s}\n", .{
                agg_name, col,
                if (filter != null) " WHERE filter" else "",
            }),
            try std.fmt.allocPrint(gpa, "  rows   : {d}\n", .{res.count}),
            try std.fmt.allocPrint(gpa, "  sum    : {d}\n", .{res.sum}),
            try std.fmt.allocPrint(gpa, "  min    : {d}   max: {d}\n", .{ res.min, res.max }),
            try std.fmt.allocPrint(gpa, "  blocks : {d} of {d} decoded\n", .{ res.blocks_read, db.blockCount(ci) }),
            try std.fmt.allocPrint(gpa, "  time   : {d:.3} ms\n", .{dt}),
            try std.fmt.allocPrint(gpa, "  cache  : {d} pages, hits={d} misses={d} evictions={d}\n", .{
                cache_pages, db.pool.stats.hits, db.pool.stats.misses, db.pool.stats.evictions,
            }),
        }; defer for (lines) |l| gpa.free(l);
        for (lines) |l| try out.appendSlice(gpa, l);
        try stdout.writeStreamingAll(io, out.items);
    } else if (std.mem.eql(u8, cmd, "jitbench")) {
        var load_path: ?[]const u8 = null;
        while (args.next()) |a| {
            if (std.mem.startsWith(u8, a, "--load=")) load_path = a["--load=".len..];
        }
        if (load_path) |lp| try loadFile(&engine, io, gpa, lp);
        try jitBench(&engine, io, gpa);
    } else if (std.mem.eql(u8, cmd, "jitloop")) {
        var load_path: ?[]const u8 = null;
        var kernel: []const u8 = "neon16";
        var iters: usize = 100;
        while (args.next()) |a| {
            if (std.mem.startsWith(u8, a, "--load=")) load_path = a["--load=".len..];
            if (std.mem.startsWith(u8, a, "--kernel=")) kernel = a["--kernel=".len..];
            if (std.mem.startsWith(u8, a, "--iters=")) iters = std.fmt.parseInt(usize, a["--iters=".len..], 10) catch 100;
        }
        if (load_path) |lp| try loadFile(&engine, io, gpa, lp);
        try jitLoop(&engine, gpa, kernel, iters);
    } else if (std.mem.eql(u8, cmd, "jitgroup")) {
        var load_path: ?[]const u8 = null;
        var iters: usize = 20;
        while (args.next()) |a| {
            if (std.mem.startsWith(u8, a, "--load=")) load_path = a["--load=".len..];
            if (std.mem.startsWith(u8, a, "--iters=")) iters = std.fmt.parseInt(usize, a["--iters=".len..], 10) catch 20;
        }
        if (load_path) |lp| try loadFile(&engine, io, gpa, lp);
        try jitGroup(&engine, gpa, iters);
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try stdout.writeStreamingAll(io, "zhdb 0.1.0 (Zig 0.17, PostgreSQL 18.1 wire compatible)\n");
    } else {
        try stdout.writeStreamingAll(io, usage);
    }
}
fn runScript(engine: *engine_mod.Engine, io: std.Io, gpa: std.mem.Allocator, src: []const u8, force_json: bool, out: *std.ArrayList(u8)) !bool {
    const stmts = try sql.splitStatements(gpa, src); defer gpa.free(stmts);
    var had_error = false;
    for (stmts) |text| {
        var arena = std.heap.ArenaAllocator.init(gpa); defer arena.deinit();
        const a = arena.allocator();
        const tt = std.mem.trim(u8, text, " \t\r\n");
        if (std.ascii.startsWithIgnoreCase(tt, "BEGIN") or std.ascii.startsWithIgnoreCase(tt, "START TRANSACTION")) {
            engine.beginTxn(); continue;
        }
        if (std.ascii.startsWithIgnoreCase(tt, "COMMIT") or std.ascii.startsWithIgnoreCase(tt, "END")) {
            engine.commitTxn(io) catch {}; continue;
        }
        if (std.ascii.startsWithIgnoreCase(tt, "ROLLBACK")) {
            engine.rollbackTxn(); continue;
        }
        var parser = sql.Parser.init(a, text) catch {
            had_error = true; try out.appendSlice(gpa, "ERROR: syntax error\n");
            continue;
        };
        const stmt = parser.parseStatement() catch {
            had_error = true; try out.appendSlice(gpa, "ERROR: syntax error\n");
            continue;
        };
        const res = engine.exec(a, stmt) catch |e| {
            had_error = true; try out.appendSlice(gpa, "ERROR: ");
            try out.appendSlice(gpa, engine_mod.diagMessage() orelse @errorName(e));
            try out.append(gpa, '\n'); continue;
        }; if (res.columns.len == 0) continue;
        if (res.format_json or force_json) {
            try emitJson(a, out, gpa, res); continue;
        }
        for (res.rows) |row| {
            for (row, 0..) |v, i| {
                if (i > 0) try out.append(gpa, '\t');
                const s = try engine_mod.formatValue(a, v); try out.appendSlice(gpa, s);
            }
            try out.append(gpa, '\n');
        }
    }
    return had_error;
}
fn emitJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), gpa: std.mem.Allocator, res: engine_mod.Result) !void {
    try out.appendSlice(gpa, "{\"meta\":[");
    for (res.columns, 0..) |c, i| {
        if (i > 0) try out.append(gpa, ',');
        const item = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"type\":\"String\"}}", .{c});
        try out.appendSlice(gpa, item);
    }
    try out.appendSlice(gpa, "],\"data\":[");
    for (res.rows, 0..) |row, ri| {
        if (ri > 0) try out.append(gpa, ','); try out.append(gpa, '{');
        for (row, 0..) |v, ci| {
            if (ci > 0) try out.append(gpa, ','); try out.append(gpa, '"');
            try out.appendSlice(gpa, res.columns[ci]); try out.appendSlice(gpa, "\":");
            switch (v) {
                .int => |x| {
                    const s = try std.fmt.allocPrint(alloc, "{d}", .{x});
                    try out.appendSlice(gpa, s);
                },
                .float => |x| {
                    const s = try std.fmt.allocPrint(alloc, "{d}", .{x});
                    try out.appendSlice(gpa, s);
                },
                .null => try out.appendSlice(gpa, "null"),
                .boolean => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
                .text => |s| {
                    try out.append(gpa, '"'); try out.appendSlice(gpa, s);
                    try out.append(gpa, '"');
                },
            }
        }
        try out.append(gpa, '}');
    }
    const tail = try std.fmt.allocPrint(alloc, "],\"rows\":{d},\"statistics\":{{\"elapsed\":0.001,\"rows_read\":{d},\"bytes_read\":0}}}}\n", .{ res.rows.len, res.rows.len });
    try out.appendSlice(gpa, tail);
}
test "select literal" {
    var engine = engine_mod.Engine.init(std.testing.allocator); defer engine.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    var parser = try sql.Parser.init(a, "SELECT 1");
    const stmt = try parser.parseStatement();
    const res = try engine.exec(a, stmt);
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqual(@as(i64, 1), res.rows[0][0].int);
}
fn runForTest(engine: *engine_mod.Engine, a: std.mem.Allocator, text: []const u8) !engine_mod.Result {
    var parser = try sql.Parser.init(a, text);
    const stmt = try parser.parseStatement(); return engine.exec(a, stmt);
}
test "group by and order by" {
    var engine = engine_mod.Engine.init(std.testing.allocator); defer engine.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    _ = try runForTest(&engine, a, "create table g(grp int, val int)");
    _ = try runForTest(&engine, a, "insert into g values (1,10),(1,20),(2,5),(2,15)");
    const res = try runForTest(&engine, a, "select grp, sum(val) from g group by grp order by grp desc");
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
    try std.testing.expectEqual(@as(i64, 2), res.rows[0][0].int);
    try std.testing.expectEqual(@as(i64, 20), res.rows[0][1].int);
    try std.testing.expectEqual(@as(i64, 30), res.rows[1][1].int);
}
test "where like and limit" {
    var engine = engine_mod.Engine.init(std.testing.allocator); defer engine.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    _ = try runForTest(&engine, a, "create table u(id int, url text)");
    _ = try runForTest(&engine, a, "insert into u values (1,'http://google.com'),(2,'http://bing.com'),(3,'https://google.com/x')");
    const res = try runForTest(&engine, a, "select id from u where url like '%google%' order by id limit 2");
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);
    try std.testing.expectEqual(@as(i64, 1), res.rows[0][0].int);
    try std.testing.expectEqual(@as(i64, 3), res.rows[1][0].int);
}
fn parseSchemaDefs(a: std.mem.Allocator, line: []const u8) ![]engine_mod.ColumnDef {
    var list = std.ArrayList(engine_mod.ColumnDef).empty;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \r"); if (trimmed.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        try list.append(a, .{
            .name = try a.dupe(u8, std.mem.trim(u8, trimmed[0..colon], " ")),
            .type_name = try a.dupe(u8, std.mem.trim(u8, trimmed[colon + 1 ..], " ")),
        });
    }
    return list.toOwnedSlice(a);
}
fn parseSize(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidSize;
    var mult: u64 = 1;
    var end = text.len;
    switch (text[text.len - 1]) {
        'k', 'K' => {
            mult = 1024; end -= 1;
        },
        'm', 'M' => {
            mult = 1024 * 1024; end -= 1;
        },
        'g', 'G' => {
            mult = 1024 * 1024 * 1024; end -= 1;
        },
        else => {},
    }
    const n = try std.fmt.parseInt(u64, text[0..end], 10); return n * mult;
}
fn rssNow() usize {
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    return @intCast(@max(ru.maxrss, 0));
}
fn readFileChunked(io: std.Io, gpa: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{}); defer file.close(io);
    const size: usize = @intCast((try file.stat(io)).size);
    if (size > max) return error.FileTooBig;
    const bytes = try gpa.alloc(u8, size); errdefer gpa.free(bytes);
    var rbuf: [1 << 20]u8 = undefined;
    var r = file.reader(io, &rbuf);
    const rd = &r.interface;
    var off: usize = 0;
    while (off < size) {
        const end = @min(off + (64 << 20), size);
        rd.readSliceAll(bytes[off..end]) catch return error.UnexpectedEof; off = end;
    }
    return bytes;
}
fn writeFileChunked(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const out = try std.Io.Dir.cwd().createFile(io, path, .{}); defer out.close(io);
    var off: usize = 0;
    while (off < bytes.len) {
        const end = @min(off + (64 << 20), bytes.len);
        try out.writeStreamingAll(io, bytes[off..end]); off = end;
    }
}
fn saveSnapshot(engine: *engine_mod.Engine, io: std.Io, gpa: std.mem.Allocator, table: []const u8, path: []const u8) !void {
    const t = engine.columnarTable(table) orelse return error.TableNotFound;
    var buf = std.ArrayList(u8).empty; defer buf.deinit(gpa);
    t.save(gpa, &buf) catch |e| {
        std.debug.print("snapshot encode failed after {d} bytes: {s}\n", .{ buf.items.len, @errorName(e) });
        return e;
    }; std.debug.print("snapshot encoded: {d} bytes, now writing\n", .{buf.items.len});
    try writeFileChunked(io, path, buf.items);
    std.debug.print("snapshot {s}: {d} rows, {d} cols, {d} bytes\n", .{ path, t.nrows, t.cols.len, buf.items.len });
}
fn loadSnapshot(engine: *engine_mod.Engine, io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
    const t0 = std.Io.Clock.now(.awake, io).nanoseconds;
    const bytes = try readFileChunked(io, gpa, path, 8 * 1024 * 1024 * 1024);
    defer gpa.free(bytes);
    const t = try columnar_mod.Table.loadBytes(gpa, bytes);
    {
        const dpath = try std.fmt.allocPrint(gpa, "{s}.delta", .{path});
        defer gpa.free(dpath);
        if (std.Io.Dir.cwd().readFileAlloc(io, dpath, gpa, .limited(1 << 30))) |db| {
            defer gpa.free(db);
            const r0 = std.Io.Clock.now(.awake, io).nanoseconds;
            const applied = t.applyDeltas(t.arena.allocator(), db) catch 0;
            const r1 = std.Io.Clock.now(.awake, io).nanoseconds;
            engine.noteReplaySample(applied, r1 - r0);
            if (std.c.getenv("ZHDB_EXPLAIN") != null) std.debug.print("[writeback] replayed {d} delta rows from {s}\n", .{ applied, dpath });
        } else |_| {}
    }
    try engine.adoptColumnar("hits", t); engine.wb_full = false;
    if (engine.snapshot_path == null) engine.snapshot_path = try gpa.dupe(u8, path);
    if (t.wb_costs) |c| engine.restoreWbCosts(c) else engine.loadWbCosts(io, gpa, path);
    const ncols = t.cols.len;
    const defs = try gpa.alloc(engine_mod.ColumnDef, ncols); defer gpa.free(defs);
    for (t.cols, 0..) |c, i| {
        defs[i] = .{
            .name = c.name,
            .type_name = switch (c.kind) {
                .int => "int",
                .float => "double",
                .str => "text",
            },
        };
    }
    try engine.createIfMissing("hits", defs);
    const dt = @as(f64, @floatFromInt(std.Io.Clock.now(.awake, io).nanoseconds - t0)) / 1e9;
    std.debug.print("snapshot loaded: {s} ({d} rows) in {d:.3} s\n", .{ path, t.nrows, dt });
}
fn parseIntFast(s: []const u8) i64 {
    if (s.len == 0) return 0;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') {
        neg = true; i = 1;
        if (s.len == 1) return 0;
    }
    var v: i64 = 0;
    while (i < s.len) : (i += 1) {
        const d = s[i] -% '0'; if (d > 9) return std.fmt.parseInt(i64, s, 10) catch 0;
        v = v * 10 + d;
    }
    return if (neg) -v else v;
}
const TextStats = struct {
    caps: []usize,
    rows: usize,
    isint: []bool,
    imin: []i64,
    imax: []i64,
};
fn textColumnBytes(io: std.Io, path: []const u8, defs: anytype, gpa: std.mem.Allocator) !TextStats {
    const caps = try gpa.alloc(usize, defs.len); @memset(caps, 0);
    const isint = try gpa.alloc(bool, defs.len);
    const imin = try gpa.alloc(i64, defs.len);
    const imax = try gpa.alloc(i64, defs.len);
    for (defs, 0..) |d, i| {
        isint[i] = switch (engine_mod.mapType(d.type_name)) { .int, .boolean => true, else => false };
        imin[i] = std.math.maxInt(i64); imax[i] = std.math.minInt(i64);
    }
    const empty = TextStats{ .caps = caps, .rows = 0, .isint = isint, .imin = imin, .imax = imax };
    const file = try std.Io.Dir.cwd().openFile(io, path, .{}); defer file.close(io);
    const size: usize = @intCast((try file.stat(io)).size); if (size == 0) return empty;
    var probe: [1 << 16]u8 = undefined;
    const hdr_n = try file.readPositionalAll(io, &probe, 0);
    const nl0 = std.mem.indexOfScalar(u8, probe[0..hdr_n], '\n') orelse return empty;
    const hdr_end: usize = nl0 + 1;
    const T: usize = @min(@max(std.Thread.getCpuCount() catch 4, 2), 8);
    const W = struct {
        file: std.Io.File,
        io: std.Io,
        buf: []u8,
        start: usize,
        end: usize,
        ncols: usize,
        caps: []usize,
        isint: []bool,
        imin: []i64,
        imax: []i64,
        rows: usize = 0,
        fn run(self: *@This()) void {
            var col: usize = 0;
            var seg: usize = 0;
            var cur: u64 = 0;
            var neg = false;
            var bad = false;
            var pos = self.start;
            while (pos < self.end) {
                const want = @min(self.buf.len, self.end - pos);
                const got = self.file.readPositionalAll(self.io, self.buf[0..want], pos) catch return;
                if (got == 0) break;
                for (self.buf[0..got]) |b| {
                    if (b == '\t' or b == '\n') {
                        if (col < self.ncols) {
                            self.caps[col] += seg;
                            if (self.isint[col] and !bad and seg > 0) {
                                if (cur <= 922337203685477580) {
                                    const v: i64 = if (neg) -@as(i64, @intCast(cur)) else @intCast(cur);
                                    if (v < self.imin[col]) self.imin[col] = v;
                                    if (v > self.imax[col]) self.imax[col] = v;
                                }
                            }
                        }
                        if (b == '\n') self.rows += 1; col += 1;
                        if (b == '\n') col = 0; seg = 0;
                        cur = 0; neg = false;
                        bad = false;
                    } else {
                        seg += 1;
                        if (col < self.ncols and self.isint[col]) {
                            if (b >= '0' and b <= '9') {
                                if (cur <= 922337203685477580) cur = cur * 10 + (b - '0') else bad = true;
                            } else if (b == '-' and seg == 1) {
                                neg = true;
                            } else bad = true;
                        }
                    }
                }
                pos += got;
            }
            if (seg > 0) {
                if (col < self.ncols) {
                    self.caps[col] += seg;
                    if (self.isint[col] and !bad and cur <= 922337203685477580) {
                        const v: i64 = if (neg) -@as(i64, @intCast(cur)) else @intCast(cur);
                        if (v < self.imin[col]) self.imin[col] = v;
                        if (v > self.imax[col]) self.imax[col] = v;
                    }
                }
                self.rows += 1;
            }
        }
    };
    const approx = (size - hdr_end) / T;
    var bounds: [9]usize = undefined; bounds[0] = hdr_end;
    for (1..T) |i| {
        var b = hdr_end + i * approx;
        var win: [1 << 16]u8 = undefined;
        while (b < size) {
            const n = file.readPositionalAll(io, &win, b) catch 0; if (n == 0) break;
            if (std.mem.indexOfScalar(u8, win[0..n], '\n')) |k| {
                b += k + 1; break;
            }
            b += n;
        }
        bounds[i] = b;
    }
    bounds[T] = size;
    var workers: [8]W = undefined;
    var threads: [8]?std.Thread = undefined;
    var bufs: [8][]u8 = undefined;
    for (0..T) |i| {
        bufs[i] = try gpa.alloc(u8, 1 << 20);
        const local = try gpa.alloc(usize, defs.len); @memset(local, 0);
        const li = try gpa.alloc(bool, defs.len); @memcpy(li, isint);
        const lmin = try gpa.alloc(i64, defs.len); @memset(lmin, std.math.maxInt(i64));
        const lmax = try gpa.alloc(i64, defs.len); @memset(lmax, std.math.minInt(i64));
        workers[i] = .{ .file = file, .io = io, .buf = bufs[i], .start = bounds[i], .end = bounds[i + 1], .ncols = defs.len, .caps = local, .isint = li, .imin = lmin, .imax = lmax };
        threads[i] = null;
        threads[i] = std.Thread.spawn(.{ .stack_size = 1 << 20 }, W.run, .{&workers[i]}) catch null;
        if (threads[i] == null) W.run(&workers[i]);
    }
    for (0..T) |i| if (threads[i]) |th| th.join();
    var rows: usize = 0;
    for (0..T) |i| {
        for (workers[i].caps, 0..) |v, k| caps[k] += v;
        for (workers[i].imin, 0..) |v, k| if (v < imin[k]) {
            imin[k] = v;
        };
        for (workers[i].imax, 0..) |v, k| if (v > imax[k]) {
            imax[k] = v;
        }; rows += workers[i].rows;
        gpa.free(workers[i].caps); gpa.free(workers[i].isint);
        gpa.free(workers[i].imin); gpa.free(workers[i].imax);
        gpa.free(bufs[i]);
    }
    return .{ .caps = caps, .rows = rows, .isint = isint, .imin = imin, .imax = imax };
}
fn loadFileColumnar(engine: *engine_mod.Engine, io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{}); defer file.close(io);
    var rbuf: [1 << 20]u8 = undefined;
    var r = file.reader(io, &rbuf);
    const rd = &r.interface;
    var arena = std.heap.ArenaAllocator.init(gpa); defer arena.deinit();
    const a = arena.allocator();
    const header = (rd.takeDelimiterInclusive('\n') catch return error.BadHeader);
    const schema_line = if (std.mem.startsWith(u8, header, "#schema:")) header["#schema:".len..] else return error.BadHeader;
    const defs = try parseSchemaDefs(a, schema_line);
    try engine.createIfMissing("hits", defs);
    var cols = try a.alloc(engine_mod.columnar.Column, defs.len);
    for (defs, 0..) |d, i| {
        cols[i] = .{ .name = d.name, .kind = switch (engine_mod.mapType(d.type_name)) {
            .int, .boolean => .int,
            .float => .float,
            else => .str,
        } };
    }
    var cap: usize = 1024;
    if (std.c.getenv("ZHDB_COL_ROWS")) |v| {
        cap = std.fmt.parseInt(usize, std.mem.span(v), 10) catch cap;
    }
    const tstats = try textColumnBytes(io, path, defs, gpa); defer gpa.free(tstats.caps);
    if (std.c.getenv("ZHDB_COL_ROWS") == null) cap = tstats.rows + 1;
    const str_caps = tstats.caps; defer gpa.free(tstats.isint);
    defer gpa.free(tstats.imin); defer gpa.free(tstats.imax);
    const ct = try engine_mod.columnar.Table.buildEmpty(gpa, cols, cap, str_caps, tstats.isint, tstats.imin, tstats.imax);
    const kinds = try a.alloc(@TypeOf(engine_mod.mapType("int")), defs.len);
    for (defs, 0..) |d, i| kinds[i] = engine_mod.mapType(d.type_name);
    const vals = try a.alloc(engine_mod.Value, defs.len);
    const start = std.Io.Clock.now(.awake, io).nanoseconds;
    var n: usize = 0;
    while (true) {
        const line = rd.takeDelimiterInclusive('\n') catch break;
        if (line.len == 0) break;
        const trimmed = std.mem.trimEnd(u8, line, "\r\n"); if (trimmed.len == 0) continue;
        if (n >= cap) return error.OutOfMemory;
        var it = std.mem.splitScalar(u8, trimmed, '\t');
        var ci: usize = 0;
        while (it.next()) |cell| : (ci += 1) {
            if (ci >= defs.len) break;
            if (cell.len == 2 and cell[0] == '\\' and cell[1] == 'N') {
                vals[ci] = .null; continue;
            }
            if (cell.len == 4 and std.ascii.eqlIgnoreCase(cell, "NULL")) {
                vals[ci] = .null; continue;
            }
            const ty = kinds[ci];
            if (ty == .text or ty == .date or ty == .timestamp) {
                vals[ci] = .{ .text = cell };
            } else {
                vals[ci] = .{ .int = parseIntFast(cell) };
            }
        }
        if (!ct.appendRow(ct.arena.allocator(), vals[0..defs.len])) return error.OutOfMemory;
        n += 1;
    }
    const elapsed_ns = std.Io.Clock.now(.awake, io).nanoseconds - start;
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    std.debug.print("loaded {d} rows into columnar hits in {d:.3} s ({d:.0} rows/s) ct.nrows={d} cap={d}\n", .{ n, secs, if (secs > 0) @as(f64, @floatFromInt(n)) / secs else 0, ct.nrows, cap });
    const t0 = std.Io.Clock.now(.awake, io).nanoseconds;
    const rss0 = rssNow();
    if (comptime builtin.os.tag == .macos) _ = malloc_zone_pressure_relief(null, 0);
    try ct.finalizeLoad();
    if (comptime builtin.os.tag == .macos) _ = malloc_zone_pressure_relief(null, 0);
    try ct.narrowIntColumns();
    if (comptime builtin.os.tag == .macos) _ = malloc_zone_pressure_relief(null, 0);
    const rss1 = rssNow();
    if (std.c.getenv("ZHDB_MEM") != null) std.debug.print("[rss] after load {d:.1} MiB, after finalize {d:.1} MiB\n", .{ @as(f64, @floatFromInt(rss0)) / 1048576.0, @as(f64, @floatFromInt(rss1)) / 1048576.0 });
    const t1 = std.Io.Clock.now(.awake, io).nanoseconds;
    std.debug.print("columnar encodings {d:.3} s\n", .{@as(f64, @floatFromInt(t1 - t0)) / 1e9});
    if (std.c.getenv("ZHDB_MEM") != null) {
        var data_b: usize = 0;
        var enc_b: usize = 0;
        for (ct.data) |d| {
            data_b += switch (d) {
                .ints => |ar| ar.len * 8,
                .ints8 => |ar| ar.len,
                .ints16 => |ar| ar.len * 2,
                .ints32 => |ar| ar.len * 4,
                .floats => |ar| ar.len * 8,
                .strs => |sd| sd.bytes.len + sd.offsets.len * 4,
            };
        }
        for (ct.enc) |e| {
            if (e) |x| enc_b += x.ids.len * 4 + x.first.len * 4 + x.counts.len * 4 +
                x.rank.len * 4 + x.byrank.len * 4;
        }
        for (ct.enc, 0..) |eo, ci| {
            if (eo) |x| {
                const eb = x.ids.len * 4 + x.first.len * 4 + x.counts.len * 4 + x.rank.len * 4 + x.byrank.len * 4;
                std.debug.print("[enc] {s}: ids={d} first={d} counts={d} rank={d} byrank={d} = {d:.1} MiB\n", .{ ct.cols[ci].name, x.ids.len, x.first.len, x.counts.len, x.rank.len, x.byrank.len, @as(f64, @floatFromInt(eb)) / 1048576.0 });
            }
        }
        std.debug.print(
            "[mem] rows={d} data={d:.2} MiB enc={d:.2} MiB scratch={d:.2} MiB total={d:.2} MiB\n",
            .{ ct.nrows, @as(f64, @floatFromInt(data_b)) / 1048576.0, @as(f64, @floatFromInt(enc_b)) / 1048576.0, @as(f64, @floatFromInt(ct.scratch.len)) / 1048576.0, @as(f64, @floatFromInt(data_b + enc_b + ct.scratch.len)) / 1048576.0 },
        );
    }
    try engine.installColumnarForLoad("hits", ct);
    if (std.c.getenv("ZHDB_DUMMY_ROWS") != null) engine.fillDummyRowsForBench("hits", n);
}
fn loadFile(engine: *engine_mod.Engine, io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{}); defer file.close(io);
    var rbuf: [1 << 20]u8 = undefined;
    var r = file.reader(io, &rbuf);
    const rd = &r.interface;
    var arena = std.heap.ArenaAllocator.init(gpa); defer arena.deinit();
    const a = arena.allocator();
    const header = (rd.takeDelimiterInclusive('\n') catch return error.BadHeader);
    const schema_line = if (std.mem.startsWith(u8, header, "#schema:")) header["#schema:".len..] else return error.BadHeader;
    const defs = try parseSchemaDefs(a, schema_line);
    try engine.createIfMissing("hits", defs);
    const start = std.Io.Clock.now(.awake, io).nanoseconds;
    var n: usize = 0;
    var vals = std.ArrayList(Value).empty; defer vals.deinit(gpa);
    while (true) {
        const line = rd.takeDelimiterInclusive('\n') catch break;
        if (line.len == 0) break;
        const trimmed = std.mem.trimEnd(u8, line, "\r\n"); if (trimmed.len == 0) continue;
        vals.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, trimmed, '\t');
        while (it.next()) |cell| {
            if (std.mem.eql(u8, cell, "\\N") or std.ascii.eqlIgnoreCase(cell, "NULL")) {
                try vals.append(gpa, .null); continue;
            }
            const ty = if (vals.items.len < defs.len)
                engine_mod.mapType(defs[vals.items.len].type_name)
            else
                .int;
            if (ty == .text or ty == .date or ty == .timestamp) {
                try vals.append(gpa, .{ .text = cell });
            } else {
                const iv = std.fmt.parseInt(i64, cell, 10) catch 0;
                try vals.append(gpa, .{ .int = iv });
            }
        }
        try engine.insertRow("hits", vals.items); n += 1;
    }
    const elapsed_ns = std.Io.Clock.now(.awake, io).nanoseconds - start;
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    std.debug.print("loaded {d} rows into hits in {d:.3} s ({d:.0} rows/s)\n", .{ n, secs, @as(f64, @floatFromInt(n)) / secs });
    const t0 = std.Io.Clock.now(.awake, io).nanoseconds; try engine.buildColumnar("hits");
    const t1 = std.Io.Clock.now(.awake, io).nanoseconds;
    std.debug.print("columnar conversion {d:.3} s\n", .{@as(f64, @floatFromInt(t1 - t0)) / 1e9});
}
fn benchFileLazy(db: *storage.Db, io: std.Io, gpa: std.mem.Allocator, path: []const u8, repeat: usize) !void {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024));
    defer gpa.free(src);
    const stmts = try sql.splitStatements(gpa, src); defer gpa.free(stmts);
    var idx: usize = 0;
    for (stmts) |text| {
        idx += 1;
        const q = std.mem.trim(u8, text, " \t\r\n"); if (q.len == 0) continue;
        var arena = std.heap.ArenaAllocator.init(gpa); defer arena.deinit();
        const a = arena.allocator();
        var parser = sql.Parser.init(a, q) catch continue;
        const stmt = parser.parseStatement() catch continue;
        if (stmt != .select) {
            std.debug.print("q{d}\tERROR\tNotLazyEligible\n", .{idx}); continue;
        }
        const plan = storage.Db.planLazy(db, stmt.select) catch |e| {
            std.debug.print("q{d}\tERROR\t{s}\n", .{ idx, @errorName(e) }); continue;
        };
        var best: f64 = std.math.inf(f64);
        var out: i128 = 0;
        var avg_val: f64 = 0;
        var attempt: usize = 0;
        while (attempt < repeat) : (attempt += 1) {
            const start = std.Io.Clock.now(.awake, io).nanoseconds;
            const r = db.streamAgg(plan.ci, plan.agg, plan.filter, null) catch |e| {
                std.debug.print("q{d}\tERROR\t{s}\n", .{ idx, @errorName(e) }); break;
            };
            const raw_ns = std.Io.Clock.now(.awake, io).nanoseconds - start;
            const ns: i64 = if (raw_ns > 0 and raw_ns < std.math.maxInt(i64)) @intCast(raw_ns) else 0;
            const ms = @as(f64, @floatFromInt(ns)) / 1e6; if (ms < best) best = ms;
            out = switch (plan.agg) {
                .count => @intCast(r.count),
                .sum => r.sum,
                .min => r.min,
                .max => r.max,
            };
            avg_val = if (r.count > 0)
                @as(f64, @floatFromInt(r.sum)) / @as(f64, @floatFromInt(r.count))
            else
                0;
        }
        if (plan.avg) {
            var ab = std.ArrayList(u8).empty; defer ab.deinit(gpa);
            try ab.appendSlice(gpa, try engine_mod.formatValue(gpa, .{ .float = avg_val }));
            std.debug.print("   -> {s}\n", .{ab.items});
        } else {
            std.debug.print("   -> {d}\n", .{out});
        }
        std.debug.print("q{d}\t{d:.3} ms\t1 rows\n", .{ idx, best });
    }
}
fn benchFile(engine: *engine_mod.Engine, io: std.Io, gpa: std.mem.Allocator, path: []const u8, repeat: usize) !void {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 * 1024 * 1024));
    defer gpa.free(src);
    const stmts = try sql.splitStatements(gpa, src); defer gpa.free(stmts);
    var idx: usize = 0;
    for (stmts) |text| {
        idx += 1;
        const q = std.mem.trim(u8, text, " \t\r\n"); if (q.len == 0) continue;
        var best: f64 = std.math.inf(f64);
        var rows: usize = 0;
        var attempt: usize = 0;
        var qarena = std.heap.ArenaAllocator.init(if (std.c.getenv("ZHDB_QARENA_GPA") != null) gpa else std.heap.page_allocator);
        while (attempt < repeat) : (attempt += 1) {
            _ = qarena.reset(.retain_capacity);
            const a = qarena.allocator();
            const start = std.Io.Clock.now(.awake, io).nanoseconds;
            var parser = sql.Parser.init(a, q) catch continue;
            const stmt = parser.parseStatement() catch continue;
            const res = engine.exec(a, stmt) catch |e| {
                std.debug.print("q{d}\tERROR\t{s}\n", .{ idx, @errorName(e) }); best = -1;
                break;
            };
            const raw_ns = std.Io.Clock.now(.awake, io).nanoseconds - start;
            const ns: i64 = if (raw_ns > 0 and raw_ns < std.math.maxInt(i64)) @intCast(raw_ns) else 0;
            const ms = @as(f64, @floatFromInt(ns)) / 1e6; if (ms < best) best = ms;
            rows = res.rows.len;
            if (res.rows.len > 0) {
                const dump_all = std.c.getenv("ZHDB_DUMP_ALL") != null;
                const nprint: usize = if (dump_all) res.rows.len else 1;
                for (res.rows[0..nprint]) |row| {
                    var line = std.ArrayList(u8).empty; defer line.deinit(a);
                    for (row, 0..) |v, ci| {
                        if (ci > 0) try line.append(a, '\t');
                        try line.appendSlice(a, try engine_mod.formatValue(a, v));
                    }
                    std.debug.print("   -> {s}\n", .{line.items});
                }
            }
        }
        qarena.deinit();
        if (comptime builtin.os.tag == .macos) _ = malloc_zone_pressure_relief(null, 0);
        if (std.c.getenv("ZHDB_MEM") != null) {
            std.debug.print("q{d}\t{d:.3} ms\t{d} rows\trss={d:.1}MiB\n", .{ idx, best, rows, @as(f64, @floatFromInt(rssNow())) / 1048576.0 });
        } else {
            std.debug.print("q{d}\t{d:.3} ms\t{d} rows\n", .{ idx, best, rows });
        }
    }
}
var clock_calls: u64 = 0;
fn now(io: std.Io) i128 {
    clock_calls +%= 1; return std.Io.Clock.now(.awake, io).nanoseconds;
}
var bench_sink: i64 = 0;
fn bestOf(io: std.Io, repeat: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx)) i64) f64 {
    var best: f64 = 1e30;
    var i: usize = 0;
    while (i < repeat) : (i += 1) {
        const t0 = now(io); bench_sink +%= f(ctx);
        const delta: i64 = @intCast(now(io) - t0);
        const dt = @as(f64, @floatFromInt(delta)) / 1e6; if (dt < best) best = dt;
    }
    return best;
}
const SumCtx = struct { v: []const i64 };
const FilterCtx = struct { v: []const i64, f: []const i64 };
const JitSumCtx = struct { f: *const fn ([*]const i64, usize) callconv(.c) i64, v: []const i64 };
const JitSumVecCtx = struct { f: *const fn ([*]const i64, usize) callconv(.c) i64, v: []const i64, groups: usize };
const JitFilterCtx = struct { f: *const fn ([*]const i64, [*]const i64, usize) callconv(.c) i64, v: []const i64, g: []const i64 };
fn zigSum(ctx: SumCtx) i64 {
    var s: i64 = 0; for (ctx.v) |x| s += x;
    return s;
}
fn zigSumFiltered(ctx: FilterCtx) i64 {
    var s: i64 = 0;
    var i: usize = 0;
    while (i < ctx.v.len) : (i += 1) {
        if (ctx.f[i] != 0) s += ctx.v[i];
    }
    return s;
}
fn jitSumRun(c: JitSumCtx) i64 {
    return c.f(@ptrCast(c.v.ptr), c.v.len);
}
fn jitSumVecRun(c: JitSumVecCtx) i64 {
    return c.f(@ptrCast(c.v.ptr), c.groups);
}
fn jitFilterRun(c: JitFilterCtx) i64 {
    return c.f(@ptrCast(c.v.ptr), @ptrCast(c.g.ptr), c.v.len);
}
fn jitBench(engine: *engine_mod.Engine, io: std.Io, gpa: std.mem.Allocator) !void {
    const ct = engine.columnarTable("hits") orelse {
        std.debug.print("no columnar table\n", .{}); return;
    };
    const width_idx = ct.find("ResolutionWidth") orelse return;
    const adv_idx = ct.find("AdvEngineID") orelse return;
    const vals: []const i64 = switch (ct.data[width_idx]) {
        .ints => |a| a,
        else => return,
    };
    const filt: []const i64 = switch (ct.data[adv_idx]) {
        .ints => |a| a,
        else => return,
    };
    const ct0 = now(io);
    var exe_tmp = try jit.compileSumI64(gpa);
    const compile_ns = now(io) - ct0; exe_tmp.deinit();
    std.debug.print("jit compile (sum kernel): {d} ns\n", .{compile_ns});
    const zig_ms = bestOf(io, 5, SumCtx{ .v = vals }, zigSum);
    var exe = try jit.compileSumI64(gpa); defer exe.deinit();
    const jsum = exe.as(*const fn ([*]const i64, usize) callconv(.c) i64);
    const jit_ms = bestOf(io, 5, JitSumCtx{ .f = jsum, .v = vals }, jitSumRun);
    const zf_ms = bestOf(io, 5, FilterCtx{ .v = vals, .f = filt }, zigSumFiltered);
    var exe2 = try jit.compileSumFilteredI64(gpa, false); defer exe2.deinit();
    const jf = exe2.as(*const fn ([*]const i64, [*]const i64, usize) callconv(.c) i64);
    const jf_ms = bestOf(io, 5, JitFilterCtx{ .f = jf, .v = vals, .g = filt }, jitFilterRun);
    var exe3 = try jit.compileSumI64Vec(gpa); defer exe3.deinit();
    const jv = exe3.as(*const fn ([*]const i64, usize) callconv(.c) i64);
    const groups = vals.len / 8;
    const jv_ms = bestOf(io, 5, JitSumVecCtx{ .f = jv, .v = vals[0 .. groups * 8], .groups = groups }, jitSumVecRun);
    var exe4 = try jit.compileSumI64Vec16(gpa); defer exe4.deinit();
    const jv16 = exe4.as(*const fn ([*]const i64, usize) callconv(.c) i64);
    const groups16 = vals.len / 16;
    const jv16_ms = bestOf(io, 5, JitSumVecCtx{ .f = jv16, .v = vals[0 .. groups16 * 16], .groups = groups16 }, jitSumVecRun);
    std.debug.print("check neon8={d} neon16={d}\n", .{ jv(@ptrCast(vals.ptr), groups), jv16(@ptrCast(vals.ptr), groups16) });
    std.debug.print("rows={d}\n", .{vals.len});
    std.debug.print("sum          zig {d:.3} ms  jit-scalar {d:.3} ms  jit-neon8 {d:.3} ms  jit-neon16 {d:.3} ms\n", .{ zig_ms, jit_ms, jv_ms, jv16_ms });
    std.debug.print("sum filtered zig {d:.3} ms  jit {d:.3} ms\n", .{ zf_ms, jf_ms });
    std.debug.print("sink={d} clocks={d}\n", .{ bench_sink, clock_calls });
}
fn jitLoop(engine: *engine_mod.Engine, gpa: std.mem.Allocator, kernel: []const u8, iters: usize) !void {
    const ct = engine.columnarTable("hits") orelse return;
    const wi = ct.find("ResolutionWidth") orelse return;
    const vals: []const i64 = switch (ct.data[wi]) {
        .ints => |a| a,
        else => return,
    };
    var acc: i64 = 0;
    if (std.mem.eql(u8, kernel, "zig")) {
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            var s: i64 = 0; for (vals) |v| s += v;
            acc +%= s;
        }
    } else if (std.mem.eql(u8, kernel, "scalar")) {
        var exe = try jit.compileSumI64(gpa); defer exe.deinit();
        const f = exe.as(*const fn ([*]const i64, usize) callconv(.c) i64);
        var i: usize = 0;
        while (i < iters) : (i += 1) acc +%= f(@ptrCast(vals.ptr), vals.len);
    } else if (std.mem.eql(u8, kernel, "neon8")) {
        var exe = try jit.compileSumI64Vec(gpa); defer exe.deinit();
        const f = exe.as(*const fn ([*]const i64, usize) callconv(.c) i64);
        const groups = vals.len / 8;
        var i: usize = 0;
        while (i < iters) : (i += 1) acc +%= f(@ptrCast(vals.ptr), groups);
    } else {
        var exe = try jit.compileSumI64Vec16(gpa); defer exe.deinit();
        const f = exe.as(*const fn ([*]const i64, usize) callconv(.c) i64);
        const groups = vals.len / 16;
        var i: usize = 0;
        while (i < iters) : (i += 1) acc +%= f(@ptrCast(vals.ptr), groups);
    }
    std.debug.print("kernel={s} iters={d} acc={d}\n", .{ kernel, iters, acc });
}
fn jitGroup(engine: *engine_mod.Engine, gpa: std.mem.Allocator, iters: usize) !void {
    const ct = engine.columnarTable("hits") orelse return;
    const wi = ct.find("UserID") orelse return;
    const keys: []const i64 = switch (ct.data[wi]) {
        .ints => |a| a,
        else => return,
    };
    const n = keys.len;
    var cap: usize = 16; while (cap < n * 2) cap <<= 1;
    const slots = try gpa.alloc(u32, cap);
    const firsts = try gpa.alloc(u32, n);
    const counts = try gpa.alloc(i64, n); defer gpa.free(slots);
    defer gpa.free(firsts); defer gpa.free(counts);
    var exe = try jit.compileGroupCountI64(gpa); defer exe.deinit();
    const f = exe.as(*const fn ([*]const i64, usize, [*]u32, u64, [*]u32, [*]i64, *u64) callconv(.c) u64);
    var ng: u64 = 0;
    var acc: u64 = 0;
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        @memset(slots, 0);
        ng = f(keys.ptr, n, slots.ptr, cap - 1, firsts.ptr, counts.ptr, &ng); acc +%= ng;
    }
    var total: i64 = 0; for (counts[0..@intCast(ng)]) |x| total += x;
    std.debug.print("groups={d} rows={d} sum_counts={d} iters={d} acc={d}\n", .{ ng, n, total, iters, acc });
}