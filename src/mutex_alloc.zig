//! Thread-safe allocator wrapper.
//!
//! The engine allocates tables/rows/arenas through a single allocator; the
//! default process GPA is not thread-safe. Serialising it with a mutex is the
//! first prerequisite for executing statements from several sessions at once.

const std = @import("std");

pub const MutexAlloc = struct {
    child: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(io: std.Io, child: std.mem.Allocator) *MutexAlloc {
        const self = std.heap.page_allocator.create(MutexAlloc) catch @panic("mutex allocator: oom");
        self.* = .{ .child = child, .io = io };
        return self;
    }

    pub fn allocator(self: *MutexAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn a(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *MutexAlloc = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn r(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *MutexAlloc = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawResize(memory, alignment, new_len, ra);
    }

    fn m(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *MutexAlloc = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }

    fn f(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *MutexAlloc = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.child.rawFree(memory, alignment, ra);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = a,
        .resize = r,
        .remap = m,
        .free = f,
    };
};

test "mutex allocator: concurrent alloc/free from two threads" {
    const base = std.heap.page_allocator;
    const safe = MutexAlloc.init(std.testing.io, base);
    const al = safe.allocator();

    const Worker = struct {
        al: std.mem.Allocator,
        fn run(self: @This()) void {
            var i: usize = 0;
            while (i < 2000) : (i += 1) {
                const buf = self.al.alloc(u8, 64 + i % 4096) catch return;
                @memset(buf, 0xAB);
                self.al.free(buf);
            }
        }
    };
    var t1 = try std.Thread.spawn(.{}, Worker.run, .{Worker{ .al = al }});
    var t2 = try std.Thread.spawn(.{}, Worker.run, .{Worker{ .al = al }});
    t1.join();
    t2.join();
}
