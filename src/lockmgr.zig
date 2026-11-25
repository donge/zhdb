const std = @import("std");
pub const Error = error{ DeadlockDetected, Timeout, OutOfMemory };
pub const LockMgr = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    cond: std.Io.Condition = std.Io.Condition.init,
    owners: std.StringHashMap(u64),
    waits: std.AutoHashMap(u64, u64),
    waits_total: usize = 0,
    deadlocks: usize = 0,
    pub fn init(alloc: std.mem.Allocator, io: std.Io) LockMgr {
        return .{
            .alloc = alloc,
            .io = io,
            .owners = std.StringHashMap(u64).init(alloc),
            .waits = std.AutoHashMap(u64, u64).init(alloc),
        };
    }
    pub fn deinit(self: *LockMgr) void {
        var it = self.owners.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.owners.deinit();
        self.waits.deinit();
    }
    fn wouldDeadlock(self: *LockMgr, txid: u64, owner: u64) bool {
        var cur = owner;
        var hops: usize = 0;
        while (hops < 64) : (hops += 1) {
            if (cur == txid) return true;
            const nxt = self.waits.get(cur) orelse return false;
            cur = nxt;
        }
        return true;
    }
    pub fn acquire(self: *LockMgr, txid: u64, table: []const u8, timeout_ns: u64) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var waited: u64 = 0;
        while (true) {
            if (self.owners.get(table)) |owner| {
                if (owner == txid) return;
                const gop = self.waits.getOrPut(txid) catch return error.OutOfMemory;
                _ = gop;
                self.waits.put(txid, owner) catch return error.OutOfMemory;
                if (self.wouldDeadlock(txid, owner)) {
                    _ = self.waits.remove(txid);
                    self.deadlocks += 1;
                    return error.DeadlockDetected;
                }
                if (timeout_ns == 0 or waited >= timeout_ns) {
                    _ = self.waits.remove(txid);
                    return error.Timeout;
                }
                const step: u64 = 1_000_000;
                self.cond.waitTimeout(self.io, &self.mutex, .{ .duration = .{ .raw = .{ .nanoseconds = @intCast(step) }, .clock = .awake } }) catch {};
                waited += step;
                self.waits_total += 1;
                continue;
            }
            const key = self.alloc.dupe(u8, table) catch return error.OutOfMemory;
            self.owners.put(key, txid) catch {
                self.alloc.free(key);
                return error.OutOfMemory;
            };
            _ = self.waits.remove(txid);
            self.cond.broadcast(self.io);
            return;
        }
    }
    pub fn release(self: *LockMgr, txid: u64, table: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.owners.get(table)) |owner| {
            if (owner == txid) {
                if (self.owners.fetchRemove(table)) |kv| self.alloc.free(kv.key);
                self.cond.broadcast(self.io);
            }
        }
    }
    pub fn releaseAll(self: *LockMgr, txid: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var victims = std.ArrayList([]const u8).empty;
        defer victims.deinit(self.alloc);
        var it = self.owners.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == txid) victims.append(self.alloc, e.key_ptr.*) catch {};
        }
        for (victims.items) |name| {
            if (self.owners.fetchRemove(name)) |kv| self.alloc.free(kv.key);
        }
        _ = self.waits.remove(txid);
        self.cond.broadcast(self.io);
    }
    pub fn holder(self: *LockMgr, table: []const u8) ?u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.owners.get(table);
    }
};
test "two writers on different tables do not block each other" {
    const alloc = std.testing.allocator;
    var m = LockMgr.init(alloc, std.testing.io);
    defer m.deinit();
    try m.acquire(1, "a", 10_000_000);
    try m.acquire(2, "b", 10_000_000);
    try std.testing.expectEqual(@as(u64, 1), m.holder("a").?);
    try std.testing.expectEqual(@as(u64, 2), m.holder("b").?);
    m.releaseAll(1);
    m.releaseAll(2);
}
test "same-table contention: second tx waits, first release wakes it" {
    const alloc = std.testing.allocator;
    var m = LockMgr.init(alloc, std.testing.io);
    defer m.deinit();
    try m.acquire(1, "t", 10_000_000);
    const Ctx = struct {
        m: *LockMgr,
        fn run(self: @This()) void {
            self.m.acquire(2, "t", 2_000_000_000) catch {};
            self.m.releaseAll(2);
        }
    };
    var th = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .m = &m }});
    std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    try std.testing.expectEqual(@as(u64, 1), m.holder("t").?);
    m.releaseAll(1);
    th.join();
    try std.testing.expect(m.holder("t") == null);
}
test "deadlock between two transactions is detected" {
    const alloc = std.testing.allocator;
    var m = LockMgr.init(alloc, std.testing.io);
    defer m.deinit();
    try m.acquire(1, "A", 1000);
    try m.acquire(2, "B", 1000);
    const R = struct {
        m: *LockMgr,
        err: ?Error = null,
        fn run(self: *@This(), txid: u64, table: []const u8) void {
            self.m.acquire(txid, table, 500_000_000) catch |e| {
                self.err = e;
            };
        }
    };
    var r1 = R{ .m = &m };
    var r2 = R{ .m = &m };
    var t1 = try std.Thread.spawn(.{}, R.run, .{ &r1, @as(u64, 1), "B" });
    std.Io.sleep(std.testing.io, std.Io.Duration.fromNanoseconds(30 * std.time.ns_per_ms), .awake) catch {};
    var t2 = try std.Thread.spawn(.{}, R.run, .{ &r2, @as(u64, 2), "A" });
    t1.join();
    t2.join();
    const detected = (r1.err != null and r1.err.? == Error.DeadlockDetected) or (r2.err != null and r2.err.? == Error.DeadlockDetected);
    try std.testing.expect(detected);
    try std.testing.expect(m.deadlocks >= 1);
    m.releaseAll(1);
    m.releaseAll(2);
}