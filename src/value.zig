const std = @import("std");
/// Runtime value used by the engine. Text values are owned by the table/arena
/// that produced them.
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    text: []const u8,
    boolean: bool,
    pub fn asFloat(self: Value) f64 {
        return switch (self) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
            .boolean => |v| if (v) 1 else 0,
            else => 0,
        };
    }
    pub fn isNull(self: Value) bool {
        return self == .null;
    }
    pub fn eql(a: Value, b: Value) bool {
        if (a.isNull() or b.isNull()) return false;
        switch (a) {
            .int => |x| return switch (b) {
                .int => |y| x == y,
                .float => |y| @as(f64, @floatFromInt(x)) == y,
                else => false,
            },
            .float => |x| return switch (b) {
                .float => |y| x == y,
                .int => |y| x == @as(f64, @floatFromInt(y)),
                else => false,
            },
            .text => |x| return switch (b) {
                .text => |y| std.mem.eql(u8, x, y),
                else => false,
            },
            .boolean => |x| return switch (b) {
                .boolean => |y| x == y,
                .int => |y| (if (x) @as(i64, 1) else 0) == y,
                else => false,
            },
            .null => return false,
        }
    }
    pub fn order(a: Value, b: Value) std.math.Order {
        if (a.isNull() and b.isNull()) return .eq;
        if (a.isNull()) return .gt;
        if (b.isNull()) return .lt;
        if (a == .text and b == .text) return std.mem.order(u8, a.text, b.text);
        if (a == .text) return .gt;
        if (b == .text) return .lt;
        if (a == .int and b == .int) return std.math.order(a.int, b.int);
        const af = a.asFloat();
        const bf = b.asFloat();
        const an = std.math.isNan(af);
        const bn = std.math.isNan(bf);
        if (an and bn) return .eq;
        if (an) return .gt; // PostgreSQL sorts NaN after all numbers
        if (bn) return .lt;
        return std.math.order(af, bf);
    }
};
