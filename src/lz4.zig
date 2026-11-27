const std = @import("std");
const min_match: usize = 4;
const last_literals: usize = 5;
const mf_limit: usize = 12;
const hash_bits: u6 = 16;
const max_offset: usize = 65535;
fn readU32(p: []const u8, pos: usize) u32 {
    return std.mem.readInt(u32, p[pos..][0..4], .little);
}
fn hashOf(v: u32) usize {
    return @intCast((v *% 2654435761) >> (32 - hash_bits));
}
pub fn compressBound(n: usize) usize {
    return n + n / 255 + 16;
}
pub fn compress(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, compressBound(src.len));
    errdefer alloc.free(out);
    var o: usize = 0;
    if (src.len < mf_limit + 4) {
        emitLiterals(out, &o, src);
        return alloc.realloc(out, o) catch out[0..o];
    }
    const table = try alloc.alloc(u32, 1 << hash_bits);
    defer alloc.free(table);
    @memset(table, 0xFFFF_FFFF);
    const max_end = src.len - last_literals;
    var anchor: usize = 0;
    var pos: usize = 0;
    while (pos + mf_limit <= src.len) {
        const h = hashOf(readU32(src, pos));
        const cand: usize = table[h];
        table[h] = @intCast(pos);
        if (cand != 0xFFFF_FFFF and cand < pos and pos - cand <= max_offset and readU32(src, cand) == readU32(src, pos)) {
            var len: usize = min_match;
            while (pos + len < max_end and src[cand + len] == src[pos + len]) len += 1;
            emitSequence(out, &o, src[anchor..pos], pos - cand, len);
            pos += len;
            anchor = pos;
            if (pos + mf_limit <= src.len) table[hashOf(readU32(src, pos))] = @intCast(pos);
            if (pos + 1 + mf_limit <= src.len) {
                pos += 1;
                table[hashOf(readU32(src, pos))] = @intCast(pos);
            }
            continue;
        }
        pos += 1;
    }
    emitLiterals(out, &o, src[anchor..]);
    return alloc.realloc(out, o) catch out[0..o];
}
fn putLen(out: []u8, o: *usize, mut_v: usize) void {
    var v = mut_v;
    while (v >= 255) : (v -= 255) {
        out[o.*] = 255;
        o.* += 1;
    }
    out[o.*] = @intCast(v);
    o.* += 1;
}
fn emitLiterals(out: []u8, o: *usize, lit: []const u8) void {
    var token: u8 = 0;
    if (lit.len >= 15) token = 15 << 4 else token = @as(u8, @intCast(lit.len)) << 4;
    out[o.*] = token;
    o.* += 1;
    if (lit.len >= 15) putLen(out, o, lit.len - 15);
    @memcpy(out[o.* .. o.* + lit.len], lit);
    o.* += lit.len;
}
fn emitSequence(out: []u8, o: *usize, lit: []const u8, offset: usize, match_len: usize) void {
    const ml = match_len - min_match;
    var token: u8 = 0;
    token |= if (lit.len >= 15) 15 << 4 else @as(u8, @intCast(lit.len)) << 4;
    token |= if (ml >= 15) 15 else @as(u8, @intCast(ml));
    out[o.*] = token;
    o.* += 1;
    if (lit.len >= 15) putLen(out, o, lit.len - 15);
    @memcpy(out[o.* .. o.* + lit.len], lit);
    o.* += lit.len;
    std.mem.writeInt(u16, out[o.*..][0..2], @intCast(offset), .little);
    o.* += 2;
    if (ml >= 15) putLen(out, o, ml - 15);
}
pub fn decompress(dst: []u8, src: []const u8) !void {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len) {
        const token = src[i];
        i += 1;
        var lit: usize = token >> 4;
        if (lit == 15) {
            while (true) {
                if (i >= src.len) return error.Corrupt;
                const b = src[i];
                i += 1;
                lit += b;
                if (b != 255) break;
            }
        }
        if (i + lit > src.len or o + lit > dst.len) return error.Corrupt;
        @memcpy(dst[o .. o + lit], src[i .. i + lit]);
        i += lit;
        o += lit;
        if (i >= src.len) break;
        if (i + 2 > src.len) return error.Corrupt;
        const off: usize = std.mem.readInt(u16, src[i..][0..2], .little);
        i += 2;
        if (off == 0 or off > o) return error.Corrupt;
        var mlen: usize = token & 15;
        if (mlen == 15) {
            while (true) {
                if (i >= src.len) return error.Corrupt;
                const b = src[i];
                i += 1;
                mlen += b;
                if (b != 255) break;
            }
        }
        mlen += min_match;
        if (o + mlen > dst.len) return error.Corrupt;
        var k: usize = 0;
        while (k < mlen) : (k += 1) {
            dst[o] = dst[o - off];
            o += 1;
        }
    }
    if (o != dst.len) return error.Corrupt;
}
test "lz4 roundtrip: short and empty inputs" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{ "", "a", "abc", "abcdefghijklmnop", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
    for (cases) |c| {
        const comp = try compress(a, c);
        defer a.free(comp);
        const dst = try a.alloc(u8, c.len);
        defer a.free(dst);
        try decompress(dst, comp);
        try std.testing.expectEqualSlices(u8, c, dst);
    }
}
test "lz4 roundtrip: repetitive text shrinks" {
    const a = std.testing.allocator;
    var src = std.ArrayList(u8).empty;
    defer src.deinit(a);
    var buf: [128]u8 = undefined;
    var i: usize = 0;
    while (i < 20000) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "http://example{d}.com/page/{d}?q=abcdef&x={d}\n", .{ i % 97, i % 13, i % 7 });
        try src.appendSlice(a, line);
    }
    const comp = try compress(a, src.items);
    defer a.free(comp);
    try std.testing.expect(comp.len * 2 < src.items.len);
    const dst = try a.alloc(u8, src.items.len);
    defer a.free(dst);
    try decompress(dst, comp);
    try std.testing.expectEqualSlices(u8, src.items, dst);
}
test "lz4 roundtrip: incompressible and mixed data" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const n: usize = 300_000;
    const src = try a.alloc(u8, n);
    defer a.free(src);
    r.bytes(src);
    @memset(src[n / 2 ..], 'z');
    const comp = try compress(a, src);
    defer a.free(comp);
    const dst = try a.alloc(u8, n);
    defer a.free(dst);
    try decompress(dst, comp);
    try std.testing.expectEqualSlices(u8, src, dst);
}
test "lz4 decompress rejects truncated input" {
    const a = std.testing.allocator;
    const src = "hello hello hello hello hello";
    const comp = try compress(a, src);
    defer a.free(comp);
    var dst: [src.len]u8 = undefined;
    try std.testing.expectError(error.Corrupt, decompress(&dst, comp[0 .. comp.len - 1]));
}
