const std = @import("std");
pub const fanout: usize = 32;
pub const Payload = struct { off: u32, count: u32 };
pub const Page = struct {
    leaf: bool = true,
    n: u16 = 0,
    next: u32 = none,
    keys: [fanout]i64 = @splat(0),
    vals: [fanout]Payload = @splat(.{ .off = 0, .count = 0 }),
    children: [fanout + 1]u32 = @splat(none),
};
pub const none: u32 = std.math.maxInt(u32);
pub const BTree = struct {
    alloc: std.mem.Allocator,
    pages: std.ArrayList(Page),
    rows: std.ArrayList(u32),
    root: u32 = none,
    height: usize = 0,
    pub fn init(alloc: std.mem.Allocator) BTree {
        return .{ .alloc = alloc, .pages = .empty, .rows = .empty };
    }
    pub fn copy(self: *BTree, a: std.mem.Allocator) !BTree {
        var t = BTree.init(a);
        errdefer t.deinit();
        try t.pages.appendSlice(a, self.pages.items);
        try t.rows.appendSlice(a, self.rows.items);
        t.root = self.root;
        t.height = self.height;
        return t;
    }
    pub fn deinit(self: *BTree) void {
        self.pages.deinit(self.alloc);
        self.rows.deinit(self.alloc);
    }
    pub fn build(
        alloc: std.mem.Allocator,
        keys: []const i64,
        offsets: []const u32,
        rows: []const u32,
    ) !BTree {
        var t = BTree.init(alloc);
        errdefer t.deinit();
        try t.rows.appendSlice(alloc, rows);
        if (keys.len == 0) return t;
        var level = std.ArrayList(u32).empty;
        defer level.deinit(alloc);
        var i: usize = 0;
        while (i < keys.len) {
            const take = @min(fanout, keys.len - i);
            const idx: u32 = @intCast(t.pages.items.len);
            var p = Page{ .leaf = true, .n = @intCast(take) };
            for (0..take) |k| {
                p.keys[k] = keys[i + k];
                p.vals[k] = .{
                    .off = offsets[i + k],
                    .count = offsets[i + k + 1] - offsets[i + k],
                };
            }
            try t.pages.append(alloc, p);
            try level.append(alloc, idx);
            i += take;
        }
        for (level.items, 0..) |idx, li| {
            if (li + 1 < level.items.len) t.pages.items[idx].next = level.items[li + 1];
        }
        while (level.items.len > 1) {
            var next = std.ArrayList(u32).empty;
            defer next.deinit(alloc);
            var j: usize = 0;
            while (j < level.items.len) {
                const take = @min(fanout + 1, level.items.len - j);
                const idx: u32 = @intCast(t.pages.items.len);
                var p = Page{ .leaf = false, .n = @intCast(take - 1) };
                for (0..take) |c| p.children[c] = level.items[j + c];
                for (0..take - 1) |c| {
                    p.keys[c] = t.firstKey(p.children[c + 1]);
                }
                try t.pages.append(alloc, p);
                try next.append(alloc, idx);
                j += take;
            }
            level.clearRetainingCapacity();
            try level.appendSlice(alloc, next.items);
        }
        t.root = level.items[0];
        t.height = 1;
        var p = t.root;
        while (!t.pages.items[p].leaf) : (t.height += 1) p = t.pages.items[p].children[0];
        return t;
    }
    fn firstKey(self: *BTree, idx: u32) i64 {
        var p = idx;
        while (!self.pages.items[p].leaf) p = self.pages.items[p].children[0];
        return self.pages.items[p].keys[0];
    }
    pub fn lookup(self: *BTree, key: i64) ?[]const u32 {
        if (self.root == none) return null;
        var p = self.root;
        while (true) {
            const page = &self.pages.items[p];
            if (page.leaf) {
                const i = lowerBound(page.keys[0..page.n], key);
                if (i < page.n and page.keys[i] == key) {
                    const v = page.vals[i];
                    return self.rows.items[v.off .. v.off + v.count];
                }
                return null;
            }
            p = page.children[childIndex(page.keys[0..page.n], key)];
        }
    }
    pub fn range(self: *BTree, a: std.mem.Allocator, lo: i64, hi: i64, out: *std.ArrayList(u32)) !void {
        if (self.root == none) return;
        var p = self.root;
        while (true) {
            const page = &self.pages.items[p];
            if (page.leaf) break;
            p = page.children[childIndex(page.keys[0..page.n], lo)];
        }
        var leaf = p;
        while (leaf != none) {
            const page = &self.pages.items[leaf];
            var i = lowerBound(page.keys[0..page.n], lo);
            while (i < page.n) : (i += 1) {
                const k = page.keys[i];
                if (k > hi) return;
                const v = page.vals[i];
                try out.appendSlice(a, self.rows.items[v.off .. v.off + v.count]);
            }
            leaf = page.next;
        }
    }
    pub fn insert(self: *BTree, key: i64, rowid: u32) !void {
        if (self.root == none) {
            try self.pages.append(self.alloc, .{ .leaf = true, .n = 0 });
            self.root = 0;
        }
        if (self.findPayload(key)) |v| {
            const old_off = v.off;
            const old_count = v.count;
            const dst_slice = try self.rows.addManyAsSlice(self.alloc, @as(usize, old_count) + 1);
            const dst: u32 = @intCast(self.rows.items.len - (old_count + 1));
            std.mem.copyForwards(u32, dst_slice[0..old_count], self.rows.items[old_off .. old_off + old_count]);
            dst_slice[old_count] = rowid;
            v.off = dst;
            v.count += 1;
            return;
        }
        const split = try self.insertInto(self.root, key, .{ .off = @intCast(self.rows.items.len), .count = 1 });
        if (split) |s| {
            const idx: u32 = @intCast(self.pages.items.len);
            var p = Page{ .leaf = false, .n = 1 };
            p.children[0] = self.root;
            p.children[1] = s.page;
            p.keys[0] = s.key;
            try self.pages.append(self.alloc, p);
            self.root = idx;
            self.height += 1;
        }
        try self.rows.append(self.alloc, rowid);
    }
    fn findPayload(self: *BTree, key: i64) ?*Payload {
        var p = self.root;
        while (true) {
            const page = &self.pages.items[p];
            if (page.leaf) {
                const i = lowerBound(page.keys[0..page.n], key);
                if (i < page.n and page.keys[i] == key) return &page.vals[i];
                return null;
            }
            p = page.children[childIndex(page.keys[0..page.n], key)];
        }
    }
    const Split = struct { key: i64, page: u32 };
    fn insertInto(self: *BTree, idx: u32, key: i64, pl: Payload) !?Split {
        var page = &self.pages.items[idx];
        if (page.leaf) {
            const i = lowerBound(page.keys[0..page.n], key);
            if (page.n < fanout) {
                var j: usize = page.n;
                while (j > i) : (j -= 1) {
                    page.keys[j] = page.keys[j - 1];
                    page.vals[j] = page.vals[j - 1];
                }
                page.keys[i] = key;
                page.vals[i] = pl;
                page.n += 1;
                return null;
            }
            var tmpk: [fanout + 1]i64 = undefined;
            var tmpv: [fanout + 1]Payload = undefined;
            for (0..fanout) |k| {
                tmpk[k] = page.keys[k];
                tmpv[k] = page.vals[k];
            }
            var j: usize = fanout;
            while (j > i) : (j -= 1) {
                tmpk[j] = tmpk[j - 1];
                tmpv[j] = tmpv[j - 1];
            }
            tmpk[i] = key;
            tmpv[i] = pl;
            const mid = (fanout + 1) / 2;
            const new_idx: u32 = @intCast(self.pages.items.len);
            var right = Page{ .leaf = true, .n = @intCast(fanout + 1 - mid), .next = page.next };
            for (0..mid) |k| {
                page.keys[k] = tmpk[k];
                page.vals[k] = tmpv[k];
            }
            for (mid..fanout + 1) |k| {
                right.keys[k - mid] = tmpk[k];
                right.vals[k - mid] = tmpv[k];
            }
            page.n = @intCast(mid);
            page.next = new_idx;
            try self.pages.append(self.alloc, right);
            return .{ .key = right.keys[0], .page = new_idx };
        }
        const ci = childIndex(page.keys[0..page.n], key);
        const child = page.children[ci];
        const split = try self.insertInto(child, key, pl);
        if (split == null) return null;
        page = &self.pages.items[idx];
        const s = split.?;
        if (page.n < fanout) {
            var j: usize = page.n;
            while (j > ci) : (j -= 1) {
                page.keys[j] = page.keys[j - 1];
                page.children[j + 1] = page.children[j];
            }
            page.keys[ci] = s.key;
            page.children[ci + 1] = s.page;
            page.n += 1;
            return null;
        }
        var tmpk: [fanout + 1]i64 = undefined;
        var tmpc: [fanout + 2]u32 = undefined;
        for (0..page.n) |k| tmpk[k] = page.keys[k];
        for (0..page.n + 1) |k| tmpc[k] = page.children[k];
        var j: usize = page.n;
        while (j > ci) : (j -= 1) {
            tmpk[j] = tmpk[j - 1];
            tmpc[j + 1] = tmpc[j];
        }
        tmpk[ci] = s.key;
        tmpc[ci + 1] = s.page;
        const total = page.n + 1;
        const mid = total / 2;
        const new_idx: u32 = @intCast(self.pages.items.len);
        var right = Page{ .leaf = false };
        for (0..mid) |k| page.keys[k] = tmpk[k];
        for (0..mid + 1) |k| page.children[k] = tmpc[k];
        page.n = @intCast(mid);
        const sep = tmpk[mid];
        for (mid + 1..total) |k| right.keys[k - mid - 1] = tmpk[k];
        for (mid + 1..total + 1) |k| right.children[k - mid - 1] = tmpc[k];
        right.n = @intCast(total - mid - 1);
        try self.pages.append(self.alloc, right);
        return .{ .key = sep, .page = new_idx };
    }
    pub fn remove(self: *BTree, key: i64, rowid: u32) !bool {
        const v = self.findPayload(key) orelse return false;
        const list = self.rows.items[v.off .. v.off + v.count];
        var found = false;
        for (list, 0..) |rid, i| {
            if (rid != rowid) continue;
            found = true;
            var k = i;
            while (k + 1 < list.len) : (k += 1) self.rows.items[v.off + k] = self.rows.items[v.off + k + 1];
            v.count -= 1;
            break;
        }
        if (!found) return false;
        if (v.count == 0) try self.deleteKey(key);
        return true;
    }
    fn deleteKey(self: *BTree, key: i64) !void {
        if (self.root == none) return;
        var path: [16]struct { page: u32, child: usize } = undefined;
        var depth: usize = 0;
        var p = self.root;
        while (true) {
            const page = &self.pages.items[p];
            if (page.leaf) break;
            if (depth >= path.len) return;
            const ci = childIndex(page.keys[0..page.n], key);
            path[depth] = .{ .page = p, .child = ci };
            depth += 1;
            p = page.children[ci];
        }
        var page = &self.pages.items[p];
        const i = lowerBound(page.keys[0..page.n], key);
        if (i >= page.n or page.keys[i] != key) return;
        var j = i;
        while (j + 1 < page.n) : (j += 1) {
            page.keys[j] = page.keys[j + 1];
            page.vals[j] = page.vals[j + 1];
        }
        page.n -= 1;
        if (page.n > 0) return;
        const dead = p;
        const next_of_dead = self.pages.items[dead].next;
        for (self.pages.items) |*pg| {
            if (pg.leaf and pg.next == dead) pg.next = next_of_dead;
        }
        if (depth == 0) {
            self.root = none;
            self.height = 0;
            return;
        }
        var d = depth;
        while (d > 0) {
            d -= 1;
            const parent_idx = path[d].page;
            var parent = &self.pages.items[parent_idx];
            const child_pos = path[d].child;
            const sep = if (child_pos > 0) child_pos - 1 else 0;
            var k = sep;
            while (k + 1 < parent.n) : (k += 1) parent.keys[k] = parent.keys[k + 1];
            var c2 = child_pos;
            while (c2 + 1 < parent.n + 1) : (c2 += 1) parent.children[c2] = parent.children[c2 + 1];
            if (parent.n > 0) parent.n -= 1;
            if (parent.n > 0) break;
            const only = parent.children[0];
            if (d == 0) {
                self.root = only;
                self.height -= 1;
                break;
            } else {
                const grand = &self.pages.items[path[d - 1].page];
                grand.children[path[d - 1].child] = only;
            }
        }
    }
    pub fn serialize(self: *BTree, a: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        var hdr: [24]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], @intCast(self.pages.items.len), .little);
        std.mem.writeInt(u32, hdr[4..8], self.root, .little);
        std.mem.writeInt(u32, hdr[8..12], @intCast(self.height), .little);
        std.mem.writeInt(u32, hdr[12..16], @intCast(self.rows.items.len), .little);
        std.mem.writeInt(u32, hdr[16..20], @intCast(self.count()), .little);
        std.mem.writeInt(u32, hdr[20..24], 0, .little);
        try out.appendSlice(a, &hdr);
        for (self.pages.items) |pg| {
            var b: [12]u8 = undefined;
            b[0] = if (pg.leaf) 1 else 0;
            std.mem.writeInt(u16, b[1..3], pg.n, .little);
            std.mem.writeInt(u32, b[3..7], pg.next, .little);
            std.mem.writeInt(u32, b[7..11], 0, .little);
            b[11] = 0;
            try out.appendSlice(a, &b);
            for (0..fanout) |i| {
                var k: [8]u8 = undefined;
                std.mem.writeInt(i64, &k, pg.keys[i], .little);
                try out.appendSlice(a, &k);
            }
            for (0..fanout) |i| {
                var v: [8]u8 = undefined;
                std.mem.writeInt(u32, v[0..4], pg.vals[i].off, .little);
                std.mem.writeInt(u32, v[4..8], pg.vals[i].count, .little);
                try out.appendSlice(a, &v);
            }
            for (0..fanout + 1) |i| {
                var c: [4]u8 = undefined;
                std.mem.writeInt(u32, &c, pg.children[i], .little);
                try out.appendSlice(a, &c);
            }
        }
        for (self.rows.items) |r| {
            var rb: [4]u8 = undefined;
            std.mem.writeInt(u32, &rb, r, .little);
            try out.appendSlice(a, &rb);
        }
    }
    pub fn deserialize(a: std.mem.Allocator, bytes: []const u8, pos: *usize) !BTree {
        if (pos.* + 24 > bytes.len) return error.BadIndex;
        const npages: usize = @intCast(std.mem.readInt(u32, bytes[pos.*..][0..4], .little));
        const root = std.mem.readInt(u32, bytes[pos.* + 4 ..][0..4], .little);
        const height: usize = @intCast(std.mem.readInt(u32, bytes[pos.* + 8 ..][0..4], .little));
        const npost: usize = @intCast(std.mem.readInt(u32, bytes[pos.* + 12 ..][0..4], .little));
        pos.* += 24;
        var t = BTree.init(a);
        errdefer t.deinit();
        try t.pages.resize(a, npages);
        for (t.pages.items) |*pg| {
            if (pos.* + 12 > bytes.len) return error.BadIndex;
            const hb = bytes[pos.*..][0..12];
            pg.* = .{};
            pg.leaf = hb[0] != 0;
            pg.n = std.mem.readInt(u16, hb[1..3], .little);
            pg.next = std.mem.readInt(u32, hb[3..7], .little);
            pos.* += 12;
            for (0..fanout) |i| {
                if (pos.* + 8 > bytes.len) return error.BadIndex;
                pg.keys[i] = std.mem.readInt(i64, bytes[pos.*..][0..8], .little);
                pos.* += 8;
            }
            for (0..fanout) |i| {
                if (pos.* + 8 > bytes.len) return error.BadIndex;
                pg.vals[i] = .{
                    .off = std.mem.readInt(u32, bytes[pos.*..][0..4], .little),
                    .count = std.mem.readInt(u32, bytes[pos.* + 4 ..][0..4], .little),
                };
                pos.* += 8;
            }
            for (0..fanout + 1) |i| {
                if (pos.* + 4 > bytes.len) return error.BadIndex;
                pg.children[i] = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
                pos.* += 4;
            }
        }
        try t.rows.resize(a, npost);
        if (pos.* + npost * 4 > bytes.len) return error.BadIndex;
        @memcpy(std.mem.sliceAsBytes(t.rows.items), bytes[pos.* .. pos.* + npost * 4]);
        pos.* += npost * 4;
        t.root = root;
        t.height = height;
        return t;
    }
    pub fn remapRows(self: *BTree, map: []const u32) usize {
        const dead_mark: u32 = 0xFFFF_FFFF;
        var moved: usize = 0;
        for (self.pages.items) |*p| {
            if (!p.leaf) continue;
            var i: usize = 0;
            var k: usize = 0;
            while (i < p.n) : (i += 1) {
                const v = p.vals[i];
                if (v.count == 0 or v.off > self.rows.items.len) continue;
                const end = @min(@as(usize, v.off) + v.count, self.rows.items.len);
                var w: usize = v.off;
                var r: usize = v.off;
                while (r < end) : (r += 1) {
                    const rid = self.rows.items[r];
                    if (rid >= map.len) continue;
                    const nn = map[rid];
                    if (nn == dead_mark) continue;
                    self.rows.items[w] = nn;
                    w += 1;
                    if (nn != rid) moved += 1;
                }
                const cnt = w - v.off;
                if (cnt == 0) continue;
                p.keys[k] = p.keys[i];
                p.vals[k] = .{ .off = v.off, .count = @intCast(cnt) };
                k += 1;
            }
            p.n = @intCast(k);
        }
        return moved;
    }
    pub fn flatten(self: *BTree, alloc: std.mem.Allocator) !struct {
        keys: []i64,
        offsets: []u32,
        rows: []u32,
    } {
        var keys = std.ArrayList(i64).empty;
        var offs = std.ArrayList(u32).empty;
        var rws = std.ArrayList(u32).empty;
        errdefer {
            keys.deinit(alloc);
            offs.deinit(alloc);
            rws.deinit(alloc);
        }
        if (self.root != none) {
            var p = self.root;
            while (!self.pages.items[p].leaf) p = self.pages.items[p].children[0];
            var leaf = p;
            while (leaf != none) {
                const page = &self.pages.items[leaf];
                for (0..page.n) |i| {
                    try keys.append(alloc, page.keys[i]);
                    try offs.append(alloc, @intCast(rws.items.len));
                    const v = page.vals[i];
                    try rws.appendSlice(alloc, self.rows.items[v.off .. v.off + v.count]);
                }
                leaf = page.next;
            }
        }
        try offs.append(alloc, @intCast(rws.items.len));
        return .{
            .keys = try keys.toOwnedSlice(alloc),
            .offsets = try offs.toOwnedSlice(alloc),
            .rows = try rws.toOwnedSlice(alloc),
        };
    }
    pub fn countKeysInRange(self: *BTree, lo: i64, hi: i64) usize {
        if (self.root == none) return 0;
        var p = self.root;
        while (true) {
            const page = &self.pages.items[p];
            if (page.leaf) break;
            p = page.children[childIndex(page.keys[0..page.n], lo)];
        }
        var total: usize = 0;
        var leaf = p;
        while (leaf != none) {
            const page = &self.pages.items[leaf];
            var i = lowerBound(page.keys[0..page.n], lo);
            while (i < page.n) : (i += 1) {
                if (page.keys[i] > hi) return total;
                total += 1;
            }
            leaf = page.next;
        }
        return total;
    }
    pub fn count(self: *BTree) usize {
        var n: usize = 0;
        for (self.pages.items) |p| {
            if (p.leaf) n += p.n;
        }
        return n;
    }
};
fn lowerBound(items: []const i64, key: i64) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}
fn childIndex(items: []const i64, key: i64) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] <= key) lo = mid + 1 else hi = mid;
    }
    return lo;
}
test "btree bulk load, lookup, range" {
    const alloc = std.testing.allocator;
    const n: usize = 1000;
    var keys = try alloc.alloc(i64, n);
    defer alloc.free(keys);
    var offsets = try alloc.alloc(u32, n + 1);
    defer alloc.free(offsets);
    var rows = try alloc.alloc(u32, n);
    defer alloc.free(rows);
    for (0..n) |i| {
        keys[i] = @intCast(i * 2);
        offsets[i] = @intCast(i);
        rows[i] = @intCast(i);
    }
    offsets[n] = @intCast(n);
    var t = try BTree.build(alloc, keys, offsets, rows);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, n), t.count());
    try std.testing.expect(t.lookup(500) != null);
    try std.testing.expect(t.lookup(501) == null);
    var out = std.ArrayList(u32).empty;
    defer out.deinit(alloc);
    try t.range(alloc, 100, 110, &out);
    try std.testing.expectEqual(@as(usize, 6), out.items.len);
}
test "btree delete then insert different key finds the new key" {
    const alloc = std.testing.allocator;
    var keys = [_]i64{ 1, 2, 3 };
    var offsets = [_]u32{ 0, 1, 2, 3 };
    var rows = [_]u32{ 0, 1, 2 };
    var t = try BTree.build(alloc, &keys, &offsets, &rows);
    defer t.deinit();
    try std.testing.expect(t.lookup(3) != null);
    try std.testing.expect(try t.remove(3, 2));
    try std.testing.expect(t.lookup(3) == null);
    try t.insert(20, 2);
    const got = t.lookup(20);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(u32, 2), got.?[0]);
    var out = std.ArrayList(u32).empty;
    defer out.deinit(alloc);
    try t.range(alloc, 20, 20, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}
test "btree incremental insert and delete keep splits/merges correct" {
    const alloc = std.testing.allocator;
    var t = try BTree.build(alloc, &.{}, &.{0}, &.{});
    defer t.deinit();
    for (0..500) |i| try t.insert(@intCast(i), @intCast(i));
    try std.testing.expectEqual(@as(usize, 500), t.count());
    try std.testing.expect(t.lookup(250) != null);
    try std.testing.expect(t.lookup(500) == null);
    for (0..10) |i| try t.insert(1000, @intCast(i));
    try std.testing.expectEqual(@as(usize, 10), t.lookup(1000).?.len);
    for (0..500) |i| _ = try t.remove(@intCast(i), @intCast(i));
    try std.testing.expect(t.lookup(250) == null);
    for (0..10) |i| _ = try t.remove(1000, @intCast(i));
    try std.testing.expect(t.lookup(1000) == null);
    try std.testing.expectEqual(@as(usize, 0), t.count());
    const flat = try t.flatten(alloc);
    defer {
        alloc.free(flat.keys);
        alloc.free(flat.offsets);
        alloc.free(flat.rows);
    }
    try std.testing.expectEqual(@as(usize, 0), flat.keys.len);
}
