//! Write-ahead log: a statement-level logical log.
//!
//! Records are length-prefixed statement texts; a zero-length record marks a
//! COMMIT. Statements after the last COMMIT were never durable and are dropped
//! on recovery.
//!
//! Trade-off (documented): logical logging re-executes statements instead of
//! replaying row images. That is compact and simple, and correct as long as
//! statements are deterministic against the same base snapshot — which holds for
//! INSERT/UPDATE/DELETE in this engine.
const std = @import("std");
pub const Wal = struct {
    path: []const u8,
    /// Committed records (as they will be written back).
    buf: std.ArrayList(u8) = .empty,
    pub fn init(path: []const u8) Wal {
        return .{ .path = path };
    }
    pub fn deinit(self: *Wal, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }
    /// Load the log contents (empty when the file does not exist).
    pub fn load(self: *Wal, io: std.Io, gpa: std.mem.Allocator) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, self.path, gpa, .limited(256 * 1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => try gpa.alloc(u8, 0),
            else => return e,
        };
    }
    /// Rewrite the log with the in-memory committed buffer.
    pub fn flush(self: *Wal, io: std.Io) !void {
        const f = try std.Io.Dir.cwd().createFile(io, self.path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, self.buf.items);
        f.sync(io) catch {};
    }
    pub fn appendStmt(self: *Wal, gpa: std.mem.Allocator, text: []const u8) !void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(text.len), .little);
        try self.buf.appendSlice(gpa, &len);
        try self.buf.appendSlice(gpa, text);
    }
    pub fn appendCommit(self: *Wal, gpa: std.mem.Allocator) !void {
        try self.buf.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
    }
    /// Statements that were followed by a COMMIT, in order.
    pub fn committed(self: *Wal, gpa: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
        _ = self;
        var out = std.ArrayList([]const u8).empty;
        errdefer out.deinit(gpa);
        var pending = std.ArrayList([]const u8).empty;
        defer pending.deinit(gpa);
        var pos: usize = 0;
        while (pos + 4 <= bytes.len) {
            const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            pos += 4;
            if (len == 0) {
                // COMMIT: everything pending becomes durable.
                for (pending.items) |t| try out.append(gpa, t);
                pending.clearRetainingCapacity();
                continue;
            }
            if (pos + len > bytes.len) break;
            try pending.append(gpa, bytes[pos .. pos + len]);
            pos += len;
        }
        return out.toOwnedSlice(gpa);
    }
};
