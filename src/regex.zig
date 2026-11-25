const std = @import("std");
const Op = union(enum) {
    ch: u8,
    any,
    class: struct { neg: bool, bits: [32]u8 },
    save: u8,
    split: [2]u32,
    jmp: u32,
    bol,
    eol,
    match,
};
const Prog = struct {
    ops: std.ArrayList(Op),
    ncap: u8 = 0,
};
fn addBit(bits: *[32]u8, c: u8) void {
    bits[c / 8] |= @as(u8, 1) << @intCast(c % 8);
}
fn hasBit(bits: *const [32]u8, c: u8) bool {
    return (bits[c / 8] >> @intCast(c % 8)) & 1 != 0;
}
const Compiler = struct {
    p: Prog,
    pat: []const u8,
    i: usize = 0,
    alloc: std.mem.Allocator,
    err: bool = false,
    fn emit(self: *Compiler, op: Op) u32 {
        const pc: u32 = @intCast(self.p.ops.items.len);
        self.p.ops.append(self.alloc, op) catch {
            self.err = true;
        };
        return pc;
    }
    fn peek(self: *Compiler) ?u8 {
        if (self.i >= self.pat.len) return null;
        return self.pat[self.i];
    }
    fn parseClass(self: *Compiler) Op {
        self.i += 1;
        var bits: [32]u8 = @splat(0);
        var neg = false;
        if (self.peek() == @as(u8, '^')) {
            neg = true;
            self.i += 1;
        }
        var first = true;
        while (self.i < self.pat.len) {
            const c = self.pat[self.i];
            if (c == ']' and !first) {
                self.i += 1;
                break;
            }
            first = false;
            var lo = c;
            if (c == '\\' and self.i + 1 < self.pat.len) {
                self.i += 1;
                lo = self.classEscape(self.pat[self.i]);
            }
            self.i += 1;
            if (self.i + 1 < self.pat.len and self.pat[self.i] == '-' and self.pat[self.i + 1] != ']') {
                var hi = self.pat[self.i + 1];
                self.i += 2;
                if (hi == '\\' and self.i < self.pat.len) {
                    hi = self.classEscape(self.pat[self.i]);
                    self.i += 1;
                }
                var x: u16 = lo;
                while (x <= hi) : (x += 1) addBit(&bits, @intCast(x));
            } else {
                addBit(&bits, lo);
            }
        }
        return .{ .class = .{ .neg = neg, .bits = bits } };
    }
    fn classEscape(self: *Compiler, c: u8) u8 {
        _ = self;
        return switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => c,
        };
    }
    fn parseAtom(self: *Compiler) void {
        const c = self.peek() orelse return;
        switch (c) {
            '(' => {
                self.i += 1;
                var cap = true;
                if (self.i + 1 < self.pat.len and self.pat[self.i] == '?' and self.pat[self.i + 1] == ':') {
                    cap = false;
                    self.i += 2;
                }
                var slot: u8 = 0;
                if (cap) {
                    self.p.ncap += 1;
                    slot = self.p.ncap;
                    _ = self.emit(.{ .save = slot * 2 - 2 });
                }
                self.parseSeq();
                if (cap) _ = self.emit(.{ .save = slot * 2 - 1 });
            },
            '[' => _ = self.emit(self.parseClass()),
            '.' => {
                self.i += 1;
                _ = self.emit(.any);
            },
            '^' => {
                self.i += 1;
                _ = self.emit(.bol);
            },
            '$' => {
                self.i += 1;
                _ = self.emit(.eol);
            },
            '\\' => {
                self.i += 1;
                if (self.peek()) |e| {
                    self.i += 1;
                    switch (e) {
                        'd' => {
                            var bits: [32]u8 = @splat(0);
                            var x: u16 = '0';
                            while (x <= '9') : (x += 1) addBit(&bits, @intCast(x));
                            _ = self.emit(.{ .class = .{ .neg = false, .bits = bits } });
                        },
                        'w' => {
                            var bits: [32]u8 = @splat(0);
                            var x: u16 = 'a';
                            while (x <= 'z') : (x += 1) addBit(&bits, @intCast(x));
                            x = 'A';
                            while (x <= 'Z') : (x += 1) addBit(&bits, @intCast(x));
                            x = '0';
                            while (x <= '9') : (x += 1) addBit(&bits, @intCast(x));
                            addBit(&bits, '_');
                            _ = self.emit(.{ .class = .{ .neg = false, .bits = bits } });
                        },
                        's' => {
                            var bits: [32]u8 = @splat(0);
                            addBit(&bits, ' ');
                            addBit(&bits, '\t');
                            addBit(&bits, '\n');
                            addBit(&bits, '\r');
                            _ = self.emit(.{ .class = .{ .neg = false, .bits = bits } });
                        },
                        else => _ = self.emit(.{ .ch = self.classEscape(e) }),
                    }
                }
            },
            else => {
                self.i += 1;
                _ = self.emit(.{ .ch = c });
            },
        }
    }
    fn parseSeq(self: *Compiler) void {
        while (self.i < self.pat.len) {
            const c = self.pat[self.i];
            if (c == ')') {
                self.i += 1;
                return;
            }
            if (c == '?' or c == '*' or c == '+') {
                self.i += 1;
                continue;
            }
            const atom_pc: u32 = @intCast(self.p.ops.items.len);
            self.parseAtom();
            const q = self.peek() orelse return;
            switch (q) {
                '?' => {
                    self.i += 1;
                    const split_pc = self.emit(.{ .split = .{ 0, 0 } });
                    const body_len = split_pc - atom_pc;
                    const atom_ops = self.p.ops.items[atom_pc..split_pc];
                    const tmp = self.alloc.alloc(Op, body_len) catch {
                        self.err = true;
                        return;
                    };
                    defer self.alloc.free(tmp);
                    @memcpy(tmp, atom_ops);
                    self.p.ops.shrinkRetainingCapacity(atom_pc);
                    const sp = self.emit(.{ .split = .{ 0, 0 } });
                    const body_start: u32 = @intCast(self.p.ops.items.len);
                    for (tmp) |op| _ = self.emit(op);
                    const after: u32 = @intCast(self.p.ops.items.len);
                    self.p.ops.items[sp] = .{ .split = .{ body_start, after } };
                },
                '*' => {
                    self.i += 1;
                    const body_len = @as(u32, @intCast(self.p.ops.items.len)) - atom_pc;
                    const tmp = self.alloc.alloc(Op, body_len) catch {
                        self.err = true;
                        return;
                    };
                    defer self.alloc.free(tmp);
                    @memcpy(tmp, self.p.ops.items[atom_pc..]);
                    self.p.ops.shrinkRetainingCapacity(atom_pc);
                    const sp = self.emit(.{ .split = .{ 0, 0 } });
                    const body_start: u32 = @intCast(self.p.ops.items.len);
                    for (tmp) |op| _ = self.emit(op);
                    _ = self.emit(.{ .jmp = sp });
                    const after: u32 = @intCast(self.p.ops.items.len);
                    self.p.ops.items[sp] = .{ .split = .{ body_start, after } };
                },
                '+' => {
                    self.i += 1;
                    const sp = self.emit(.{ .split = .{ 0, 0 } });
                    const after: u32 = @intCast(self.p.ops.items.len);
                    self.p.ops.items[sp] = .{ .split = .{ atom_pc, after } };
                },
                else => {},
            }
        }
    }
};
const Caps = [20]?usize;
const Runner = struct {
    prog: []const Op,
    text: []const u8,
    caps: *Caps,
    steps: usize = 0,
    limit: usize,
    fn run(self: *Runner, pc: usize, pos: usize) ?usize {
        self.steps += 1;
        if (self.steps > self.limit) return null;
        var p = pc;
        var s = pos;
        while (true) {
            self.steps += 1;
            if (self.steps > self.limit) return null;
            switch (self.prog[p]) {
                .ch => |c| {
                    if (s >= self.text.len or self.text[s] != c) return null;
                    s += 1;
                    p += 1;
                },
                .any => {
                    if (s >= self.text.len or self.text[s] == '\n') return null;
                    s += 1;
                    p += 1;
                },
                .class => |cl| {
                    if (s >= self.text.len) return null;
                    const in = hasBit(&cl.bits, self.text[s]);
                    if (in == cl.neg) return null;
                    s += 1;
                    p += 1;
                },
                .save => |slot| {
                    const old = self.caps[slot];
                    self.caps[slot] = s;
                    if (self.run(p + 1, s)) |e| return e;
                    self.caps[slot] = old;
                    return null;
                },
                .split => |t| {
                    if (self.run(t[0], s)) |e| return e;
                    p = t[1];
                },
                .jmp => |t| p = t,
                .bol => {
                    if (s != 0) return null;
                    p += 1;
                },
                .eol => {
                    if (s != self.text.len) return null;
                    p += 1;
                },
                .match => return s,
            }
        }
    }
};
pub fn replace(
    alloc: std.mem.Allocator,
    text: []const u8,
    pattern: []const u8,
    replacement: []const u8,
) !?[]const u8 {
    var c = Compiler{ .p = .{ .ops = .empty }, .pat = pattern, .alloc = alloc };
    defer c.p.ops.deinit(alloc);
    c.parseSeq();
    if (c.err) return null;
    _ = c.emit(.match);
    var caps: Caps = @splat(null);
    var start: usize = 0;
    var end: usize = 0;
    var found = false;
    while (start <= text.len) {
        var caps_try: Caps = @splat(null);
        var runner = Runner{ .prog = c.p.ops.items, .text = text, .caps = &caps_try, .limit = 20_000 };
        if (runner.run(0, start)) |e| {
            caps = caps_try;
            end = e;
            found = true;
            break;
        }
        start += 1;
    }
    if (!found) return null;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, text[0..start]);
    var i: usize = 0;
    while (i < replacement.len) : (i += 1) {
        const ch = replacement[i];
        if (ch == '\\' and i + 1 < replacement.len and replacement[i + 1] >= '0' and replacement[i + 1] <= '9') {
            const g: usize = replacement[i + 1] - '0';
            i += 1;
            if (g > 0 and g <= 9) {
                const cs = caps[(g - 1) * 2];
                const ce = caps[(g - 1) * 2 + 1];
                if (cs != null and ce != null and ce.? >= cs.? and ce.? <= text.len) {
                    try out.appendSlice(alloc, text[cs.?..ce.?]);
                }
            }
            continue;
        }
        try out.append(alloc, ch);
    }
    try out.appendSlice(alloc, text[end..]);
    return try out.toOwnedSlice(alloc);
}
test "regexp_replace host extraction" {
    const a = std.testing.allocator;
    const got = try replace(
        a,
        "https://www.example.com/path?q=1",
        "^https?://(?:www\\.)?([^/]+)/.*$",
        "\\1",
    );
    defer a.free(got.?);
    try std.testing.expectEqualStrings("example.com", got.?);
}
test "regexp_replace no match returns null" {
    const a = std.testing.allocator;
    const got = try replace(a, "no url here", "^https?://([^/]+)/.*$", "\\1");
    try std.testing.expect(got == null);
}
