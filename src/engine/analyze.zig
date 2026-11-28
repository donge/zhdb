const std = @import("std");
const engine_mod = @import("../engine.zig");
const Engine = engine_mod.Engine;
const sql = @import("../sql.zig");
const Table = engine_mod.Table;
const Column = engine_mod.Column;
const Value = engine_mod.Value;
const ColStat = engine_mod.ColStat;
const McvEntry = engine_mod.McvEntry;
const McvStr = engine_mod.McvStr;
const NgramStat = engine_mod.NgramStat;
const DictEntry = engine_mod.DictEntry;
const SuffixStat = engine_mod.SuffixStat;
const GramCount = engine_mod.GramCount;
const RES_CDF_BUDGET = engine_mod.RES_CDF_BUDGET;
const RANGE_MAX = engine_mod.RANGE_MAX;
const RANGE_KEY_BUDGET = engine_mod.RANGE_KEY_BUDGET;
const RANGE_STR_BUDGET = engine_mod.RANGE_STR_BUDGET;
const Result = engine_mod.Result;
const EngineError = engine_mod.EngineError;
const findCol = engine_mod.findCol;
const findColSlice = engine_mod.findColSlice;
const tableIsNull = engine_mod.tableIsNull;
const f64Key = engine_mod.f64Key;
const stripSchema = Engine.stripSchema;
const exprName = engine_mod.exprName;
const oneText = engine_mod.oneText;
const formatValue = engine_mod.formatValue;

pub fn execAnalyze(self: *Engine, name: []const u8) EngineError!Result {
    if (name.len == 0) return .{};
    const t = self.find(name) orelse return error.TableNotFound;
    self.execMaintenance(name, 1);
    self.ensureRowsMaterialized(name);
    const gpa = self.gpa;
    if (t.stats.len != t.cols.len) {
        t.stats = try gpa.alloc(ColStat, t.cols.len);
        @memset(t.stats, .{});
    }
    const ct = self.findColumnar(name);
    for (t.cols, 0..) |c, ci| {
        if (ci < t.stats.len) {
            const prev = t.stats[ci];
            if (prev.mcv.len > 0) gpa.free(prev.mcv);
            if (prev.hist.len > 0) gpa.free(prev.hist);
            if (prev.hist_ndv.len > 0) gpa.free(prev.hist_ndv);
            if (prev.hist_lo.len > 0) gpa.free(prev.hist_lo);
            if (prev.hist_hi.len > 0) gpa.free(prev.hist_hi);
            for (prev.mcv_str) |m| gpa.free(m.s);
            if (prev.mcv_str.len > 0) gpa.free(prev.mcv_str);
            for (prev.hist_str) |x| gpa.free(x);
            if (prev.hist_str.len > 0) gpa.free(prev.hist_str);
            if (prev.hist_str_ndv.len > 0) gpa.free(prev.hist_str_ndv);
            if (prev.min_str.len > 0) gpa.free(prev.min_str);
            if (prev.max_str.len > 0) gpa.free(prev.max_str);
            if (prev.ngram.len > 0) gpa.free(prev.ngram);
            if (prev.suf.len > 0) gpa.free(prev.suf);
            for (prev.dict) |e| gpa.free(e.s);
            if (prev.dict.len > 0) gpa.free(prev.dict);
            if (prev.res_min.len > 0) gpa.free(prev.res_min);
            if (prev.res_max.len > 0) gpa.free(prev.res_max);
            for (prev.res_hist) |x| gpa.free(x);
            if (prev.res_hist.len > 0) gpa.free(prev.res_hist);
            if (prev.res_hist_ndv.len > 0) gpa.free(prev.res_hist_ndv);
            if (prev.res_hist_mass.len > 0) gpa.free(prev.res_hist_mass);
            for (prev.res_sub) |x| gpa.free(x);
            if (prev.res_sub.len > 0) gpa.free(prev.res_sub);
            if (prev.res_sub_mass.len > 0) gpa.free(prev.res_sub_mass);
            if (prev.res_sub_ndv.len > 0) gpa.free(prev.res_sub_ndv);
            if (prev.res_sub_cum.len > 0) gpa.free(prev.res_sub_cum);
            for (prev.res_cdf_vals) |x| gpa.free(x);
            if (prev.res_cdf_vals.len > 0) gpa.free(prev.res_cdf_vals);
            if (prev.res_cdf_cum.len > 0) gpa.free(prev.res_cdf_cum);
        }
        var st = ColStat{};
        if (ct) |tab| {
            if (tab.enc.len > ci) {
                if (tab.enc[ci]) |e| st.ndv = e.first.len;
            }
        }
        st.nulls = 0;
        st.min = std.math.maxInt(i64);
        st.max = std.math.minInt(i64);
        var sampled: usize = 0;
        var seen = std.AutoHashMap(i64, usize).init(gpa);
        defer seen.deinit();
        var vals = std.ArrayList(i64).empty;
        defer vals.deinit(gpa);
        var sseen = std.StringHashMap(usize).init(gpa);
        defer sseen.deinit();
        var svals = std.ArrayList([]const u8).empty;
        defer svals.deinit(gpa);
        var ri: usize = 0;
        var step: usize = if (t.rows.items.len <= 262_144) 1 else @max(1, t.rows.items.len / 20000);
        if (step > 1 and step % 2 == 0) step += 1;
        while (ri < t.rows.items.len) : (ri += step) {
            const v = t.rows.items[ri][ci];
            if (tableIsNull(t, ci, ri)) {
                st.nulls += 1;
                continue;
            }
            sampled += 1;
            switch (v) {
                .int => |x| {
                    st.min = @min(st.min, x);
                    st.max = @max(st.max, x);
                    const gop = seen.getOrPut(x) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                    vals.append(gpa, x) catch {};
                },
                .float => |x| {
                    if (std.math.isNan(x)) continue;
                    const k = f64Key(x);
                    st.min = @min(st.min, k);
                    st.max = @max(st.max, k);
                    const gop = seen.getOrPut(k) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                    vals.append(gpa, k) catch {};
                },
                .text => |x| {
                    const gop = sseen.getOrPut(x) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                    svals.append(gpa, x) catch {};
                },
                else => {},
            }
        }
        if (st.ndv == 0 and seen.count() > 0) st.ndv = seen.count();
        if (st.min > st.max) st.min = 0;
        if (st.mcv.len > 0) gpa.free(st.mcv);
        if (st.hist.len > 0) gpa.free(st.hist);
        if (st.hist_ndv.len > 0) gpa.free(st.hist_ndv);
        if (st.hist_lo.len > 0) gpa.free(st.hist_lo);
        if (st.hist_hi.len > 0) gpa.free(st.hist_hi);
        st.mcv = &.{};
        st.hist = &.{};
        st.hist_ndv = &.{};
        st.hist_lo = &.{};
        st.hist_hi = &.{};
        st.mcv_mass = 0;
        const is_int = switch (c.ty) {
            .int, .boolean, .float => true,
            else => false,
        };
        if (is_int and sampled >= 64) {
            const total: f64 = @floatFromInt(sampled);
            var entries = std.ArrayList(McvEntry).empty;
            defer entries.deinit(gpa);
            var it2 = seen.iterator();
            while (it2.next()) |e| {
                const cnt = e.value_ptr.*;
                if (cnt < 2) continue;
                const freq = @as(f64, @floatFromInt(cnt)) / total;
                if (freq < 0.005) continue;
                entries.append(gpa, .{ .v = e.key_ptr.*, .freq = freq }) catch {};
            }
            std.mem.sort(McvEntry, entries.items, {}, struct {
                fn gt(_: void, a: McvEntry, b: McvEntry) bool {
                    return a.freq > b.freq;
                }
            }.gt);
            const take = @min(entries.items.len, 16);
            if (take > 0) {
                if (gpa.alloc(McvEntry, take)) |m| {
                    @memcpy(m, entries.items[0..take]);
                    st.mcv = m;
                    for (m) |e2| st.mcv_mass += e2.freq;
                    st.mcv_mass = @min(st.mcv_mass, 1.0);
                } else |_| {}
            }
            std.mem.sort(i64, vals.items, {}, std.sort.asc(i64));
            const B: usize = 32;
            var bounds = std.ArrayList(i64).empty;
            defer bounds.deinit(gpa);
            var bpos = std.ArrayList(usize).empty;
            defer bpos.deinit(gpa);
            var bi: usize = 0;
            while (bi <= B) : (bi += 1) {
                const idx = @min((bi * sampled) / B, sampled - 1);
                bounds.append(gpa, vals.items[idx]) catch {};
                bpos.append(gpa, idx) catch {};
            }
            if (bounds.items.len > 0) {
                if (st.max != std.math.maxInt(i64)) {
                    const last = bounds.items[bounds.items.len - 1];
                    if (last <= st.max) {
                        bounds.append(gpa, st.max + 1) catch {};
                        bpos.append(gpa, sampled - 1) catch {};
                    }
                }
                if (gpa.alloc(i64, bounds.items.len)) |h| {
                    @memcpy(h, bounds.items);
                    st.hist = h;
                } else |_| {}
                const nb = bounds.items.len - 1;
                if (nb > 0) {
                    if (gpa.alloc(u32, nb)) |hndv| {
                        const hlo = gpa.alloc(i64, nb) catch null;
                        const hhi = gpa.alloc(i64, nb) catch null;
                        var bj: usize = 0;
                        while (bj < nb) : (bj += 1) {
                            const lo2 = bpos.items[bj];
                            const hi2 = @min(bpos.items[bj + 1] + 1, sampled);
                            var distinct: u32 = 0;
                            if (hi2 > lo2) {
                                distinct = 1;
                                var z = lo2 + 1;
                                while (z < hi2) : (z += 1) {
                                    if (vals.items[z] != vals.items[z - 1]) distinct += 1;
                                }
                            }
                            hndv[bj] = distinct;
                            if (hlo != null and hhi != null) {
                                hlo.?[bj] = vals.items[lo2];
                                hhi.?[bj] = vals.items[@min(hi2 - 1, sampled - 1)];
                            }
                        }
                        st.hist_ndv = hndv;
                        if (hlo != null and hhi != null) {
                            st.hist_lo = hlo.?;
                            st.hist_hi = hhi.?;
                        } else {
                            if (hlo) |x| gpa.free(x);
                            if (hhi) |x| gpa.free(x);
                        }
                    } else |_| {}
                }
            }
        }
        for (st.mcv_str) |m| gpa.free(m.s);
        if (st.mcv_str.len > 0) gpa.free(st.mcv_str);
        for (st.hist_str) |h| gpa.free(h);
        if (st.hist_str.len > 0) gpa.free(st.hist_str);
        if (st.min_str.len > 0) gpa.free(st.min_str);
        if (st.max_str.len > 0) gpa.free(st.max_str);
        if (st.ngram.len > 0) gpa.free(st.ngram);
        if (st.suf.len > 0) gpa.free(st.suf);
        if (st.hist_str_ndv.len > 0) gpa.free(st.hist_str_ndv);
        for (st.hist_str_lo) |x| gpa.free(x);
        if (st.hist_str_lo.len > 0) gpa.free(st.hist_str_lo);
        for (st.hist_str_hi) |x| gpa.free(x);
        if (st.hist_str_hi.len > 0) gpa.free(st.hist_str_hi);
        for (st.dict) |e| gpa.free(e.s);
        if (st.dict.len > 0) gpa.free(st.dict);
        if (st.res_min.len > 0) gpa.free(st.res_min);
        if (st.res_max.len > 0) gpa.free(st.res_max);
        for (st.res_hist) |x| gpa.free(x);
        if (st.res_hist.len > 0) gpa.free(st.res_hist);
        if (st.res_hist_ndv.len > 0) gpa.free(st.res_hist_ndv);
        if (st.res_hist_mass.len > 0) gpa.free(st.res_hist_mass);
        for (st.res_sub) |x| gpa.free(x);
        if (st.res_sub.len > 0) gpa.free(st.res_sub);
        if (st.res_sub_mass.len > 0) gpa.free(st.res_sub_mass);
        if (st.res_sub_ndv.len > 0) gpa.free(st.res_sub_ndv);
        if (st.res_sub_cum.len > 0) gpa.free(st.res_sub_cum);
        for (st.res_cdf_vals) |x| gpa.free(x);
        if (st.res_cdf_vals.len > 0) gpa.free(st.res_cdf_vals);
        if (st.res_cdf_cum.len > 0) gpa.free(st.res_cdf_cum);
        st.ngram = &.{};
        st.suf = &.{};
        st.hist_str_ndv = &.{};
        st.hist_str_lo = &.{};
        st.hist_str_hi = &.{};
        st.mcv_str = &.{};
        st.hist_str = &.{};
        st.min_str = &.{};
        st.max_str = &.{};
        st.mcv_str_mass = 0;
        if ((c.ty == .text or c.ty == .date or c.ty == .timestamp) and sampled >= 64 and svals.items.len > 0) {
            const total: f64 = @floatFromInt(sampled);
            var sentries = std.ArrayList(McvStr).empty;
            defer sentries.deinit(gpa);
            var sit = sseen.iterator();
            while (sit.next()) |e| {
                const cnt = e.value_ptr.*;
                if (cnt < 2) continue;
                const freq = @as(f64, @floatFromInt(cnt)) / total;
                if (freq < 0.005) continue;
                const dup = gpa.dupe(u8, e.key_ptr.*) catch continue;
                sentries.append(gpa, .{ .s = dup, .freq = freq }) catch gpa.free(dup);
            }
            std.mem.sort(McvStr, sentries.items, {}, struct {
                fn gt(_: void, a: McvStr, b: McvStr) bool {
                    return a.freq > b.freq;
                }
            }.gt);
            const stake = @min(sentries.items.len, 16);
            if (stake > 0) {
                if (gpa.alloc(McvStr, stake)) |m| {
                    @memcpy(m, sentries.items[0..stake]);
                    for (m) |e2| st.mcv_str_mass += e2.freq;
                    st.mcv_str_mass = @min(st.mcv_str_mass, 1.0);
                    st.mcv_str = m;
                    for (sentries.items[stake..]) |e2| gpa.free(e2.s);
                    sentries.items.len = 0;
                } else |_| {
                    for (sentries.items) |e2| gpa.free(e2.s);
                    sentries.items.len = 0;
                }
            } else {
                for (sentries.items) |e2| gpa.free(e2.s);
                sentries.items.len = 0;
            }
            const Ctx = struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            };
            std.mem.sort([]const u8, svals.items, {}, Ctx.lt);
            const S = svals.items.len;
            st.min_str = gpa.dupe(u8, svals.items[0]) catch &.{};
            st.max_str = gpa.dupe(u8, svals.items[S - 1]) catch &.{};
            const B: usize = 32;
            var sb = std.ArrayList([]u8).empty;
            defer {
                for (sb.items) |x| gpa.free(x);
                sb.deinit(gpa);
            }
            var spos = std.ArrayList(usize).empty;
            defer spos.deinit(gpa);
            var bi: usize = 0;
            while (bi <= B) : (bi += 1) {
                const idx = @min((bi * S) / B, S - 1);
                const dup2 = gpa.dupe(u8, svals.items[idx]) catch continue;
                sb.append(gpa, dup2) catch gpa.free(dup2);
                spos.append(gpa, idx) catch {};
            }
            if (sb.items.len > 0) {
                const nbounds = sb.items.len;
                if (gpa.alloc([]u8, nbounds)) |h| {
                    @memcpy(h, sb.items);
                    st.hist_str = h;
                    sb.items.len = 0;
                } else |_| {}
                const nb = if (nbounds > 0) nbounds - 1 else 0;
                if (nb > 0 and spos.items.len >= nbounds) {
                    if (gpa.alloc(u32, nb)) |hsn| {
                        const hslo = gpa.alloc([]u8, nb) catch null;
                        const hshi = gpa.alloc([]u8, nb) catch null;
                        var bj: usize = 0;
                        while (bj < nb) : (bj += 1) {
                            const lo2 = spos.items[bj];
                            const hi2 = @min(spos.items[bj + 1] + 1, S);
                            var distinct: u32 = 0;
                            if (hi2 > lo2) {
                                distinct = 1;
                                var z = lo2 + 1;
                                while (z < hi2) : (z += 1) {
                                    if (!std.mem.eql(u8, svals.items[z], svals.items[z - 1])) distinct += 1;
                                }
                            }
                            hsn[bj] = distinct;
                            if (hslo != null and hshi != null) {
                                hslo.?[bj] = gpa.dupe(u8, svals.items[lo2]) catch &.{};
                                hshi.?[bj] = gpa.dupe(u8, svals.items[@min(hi2 - 1, S - 1)]) catch &.{};
                            }
                        }
                        st.hist_str_ndv = hsn;
                        if (hslo != null and hshi != null) {
                            st.hist_str_lo = hslo.?;
                            st.hist_str_hi = hshi.?;
                        } else {
                            if (hslo) |x| gpa.free(x);
                            if (hshi) |x| gpa.free(x);
                        }
                    } else |_| {}
                }
            }
            if (st.ndv > 65_536 and sampled >= 64) {
                var sents = std.ArrayList(DictEntry).empty;
                defer sents.deinit(gpa);
                var sit4 = sseen.iterator();
                while (sit4.next()) |e| {
                    const dup = gpa.dupe(u8, e.key_ptr.*) catch continue;
                    sents.append(gpa, .{ .s = dup, .count = @intCast(e.value_ptr.*) }) catch gpa.free(dup);
                }
                std.mem.sort(DictEntry, sents.items, {}, struct {
                    fn gt(_: void, a: DictEntry, b: DictEntry) bool {
                        return a.count > b.count;
                    }
                }.gt);
                const stk = @min(sents.items.len, 512);
                if (stk > 0) {
                    if (gpa.alloc(DictEntry, stk)) |dm| {
                        @memcpy(dm, sents.items[0..stk]);
                        for (sents.items[stk..]) |e| gpa.free(e.s);
                        sents.items.len = 0;
                        st.dict = dm;
                        st.dict_sampled = true;
                        st.dict_sample_rows = sampled;
                        var mapset = std.StringHashMap(void).init(gpa);
                        defer mapset.deinit();
                        for (dm) |e| mapset.put(e.s, {}) catch {};
                        var rmin: ?[]const u8 = null;
                        var rmax: ?[]const u8 = null;
                        var rvals = std.ArrayList([]const u8).empty;
                        defer rvals.deinit(gpa);
                        for (svals.items) |vv2| {
                            if (mapset.contains(vv2)) continue;
                            if (rmin == null or std.mem.order(u8, vv2, rmin.?) == .lt) rmin = vv2;
                            if (rmax == null or std.mem.order(u8, vv2, rmax.?) == .gt) rmax = vv2;
                            rvals.append(gpa, vv2) catch {};
                        }
                        if (rmin != null and rmax != null) {
                            st.res_min = gpa.dupe(u8, rmin.?) catch &.{};
                            st.res_max = gpa.dupe(u8, rmax.?) catch &.{};
                            const RB: usize = 16;
                            const RS = rvals.items.len;
                            if (RS > 0) {
                                std.mem.sort([]const u8, rvals.items, {}, struct {
                                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                                        return std.mem.order(u8, a, b) == .lt;
                                    }
                                }.lt);
                                const rpos = gpa.alloc(usize, RB + 1) catch null;
                                if (rpos) |rp| {
                                    var bi4: usize = 0;
                                    while (bi4 <= RB) : (bi4 += 1) rp[bi4] = @min((bi4 * RS) / RB, RS - 1);
                                    if (gpa.alloc(u32, RB)) |rndv| {
                                        const rmass = gpa.alloc(u32, RB) catch null;
                                        var bj5: usize = 0;
                                        while (bj5 < RB) : (bj5 += 1) {
                                            const lo4 = rp[bj5];
                                            const hi4 = @min(rp[bj5 + 1] + 1, RS);
                                            var dst: u32 = 0;
                                            if (hi4 > lo4) {
                                                dst = 1;
                                                var z6 = lo4 + 1;
                                                while (z6 < hi4) : (z6 += 1) {
                                                    if (!std.mem.eql(u8, rvals.items[z6], rvals.items[z6 - 1])) dst += 1;
                                                }
                                            }
                                            rndv[bj5] = dst;
                                            if (rmass) |rm| rm[bj5] = @intCast(hi4 - lo4);
                                        }
                                        st.res_hist_ndv = rndv;
                                        if (rmass) |rm| {
                                            st.res_hist_mass = rm;
                                        }
                                    } else |_| {}
                                    if (gpa.alloc([]u8, RB + 1)) |rh| {
                                        var bj6: usize = 0;
                                        while (bj6 <= RB) : (bj6 += 1) rh[bj6] = gpa.dupe(u8, rvals.items[rp[bj6]]) catch &.{};
                                        st.res_hist = rh;
                                    } else |_| {}
                                    {
                                        const SUB: usize = 128;
                                        const nsub = RB * SUB;
                                        const smass = gpa.alloc(u32, nsub) catch null;
                                        const sndv = gpa.alloc(u32, nsub) catch null;
                                        var sub = std.ArrayList([]u8).empty;
                                        var ok = smass != null and sndv != null;
                                        var bb: usize = 0;
                                        while (bb < RB and ok) : (bb += 1) {
                                            const lo5 = rp[bb];
                                            const hi5 = @min(rp[bb + 1] + 1, RS);
                                            const width = hi5 - lo5;
                                            var ss: usize = 0;
                                            while (ss <= SUB) : (ss += 1) {
                                                const idx = lo5 + (ss * width) / SUB;
                                                const cidx = @min(idx, hi5 - 1);
                                                const dup = gpa.dupe(u8, rvals.items[cidx]) catch {
                                                    ok = false;
                                                    break;
                                                };
                                                sub.append(gpa, dup) catch {
                                                    gpa.free(dup);
                                                    ok = false;
                                                    break;
                                                };
                                            }
                                            ss = 0;
                                            while (ss < SUB) : (ss += 1) {
                                                const a0 = lo5 + (ss * width) / SUB;
                                                const a1 = lo5 + ((ss + 1) * width) / SUB;
                                                smass.?[bb * SUB + ss] = @intCast(a1 - a0);
                                                var dst: u32 = 0;
                                                if (a1 > a0) {
                                                    dst = 1;
                                                    var z7 = a0 + 1;
                                                    while (z7 < a1) : (z7 += 1) {
                                                        if (!std.mem.eql(u8, rvals.items[z7], rvals.items[z7 - 1])) dst += 1;
                                                    }
                                                }
                                                sndv.?[bb * SUB + ss] = dst;
                                            }
                                        }
                                        if (ok and sub.items.len == RB * (SUB + 1)) {
                                            if (gpa.alloc(u32, nsub)) |scum| {
                                                var acc: u32 = 0;
                                                var zi: usize = 0;
                                                while (zi < nsub) : (zi += 1) {
                                                    acc += smass.?[zi];
                                                    scum[zi] = acc;
                                                }
                                                st.res_sub_cum = scum;
                                            } else |_| {}
                                            st.res_sub = sub.items;
                                            st.res_sub_mass = smass.?;
                                            st.res_sub_ndv = sndv.?;
                                            sub.items.len = 0;
                                        } else {
                                            for (sub.items) |x| gpa.free(x);
                                            sub.deinit(gpa);
                                            if (smass) |x| gpa.free(x);
                                            if (sndv) |x| gpa.free(x);
                                        }
                                    }
                                    {
                                        var uniq = std.ArrayList([]u8).empty;
                                        var cum = std.ArrayList(u32).empty;
                                        var bytes: usize = 0;
                                        var ui: usize = 0;
                                        var fits = true;
                                        while (ui < RS) {
                                            const v0 = rvals.items[ui];
                                            var uj = ui + 1;
                                            while (uj < RS and std.mem.eql(u8, rvals.items[uj], v0)) uj += 1;
                                            bytes += v0.len + 24;
                                            if (bytes > RES_CDF_BUDGET) {
                                                fits = false;
                                                break;
                                            }
                                            const dup = gpa.dupe(u8, v0) catch {
                                                fits = false;
                                                break;
                                            };
                                            uniq.append(gpa, dup) catch {
                                                gpa.free(dup);
                                                fits = false;
                                                break;
                                            };
                                            const prevc: u32 = if (cum.items.len > 0) cum.items[cum.items.len - 1] else 0;
                                            cum.append(gpa, prevc + @as(u32, @intCast(uj - ui))) catch {
                                                fits = false;
                                                break;
                                            };
                                            ui = uj;
                                        }
                                        if (fits and uniq.items.len > 0 and uniq.items.len == cum.items.len) {
                                            st.res_cdf_vals = uniq.items;
                                            st.res_cdf_cum = cum.items;
                                        } else {
                                            for (uniq.items) |x| gpa.free(x);
                                            uniq.deinit(gpa);
                                            cum.deinit(gpa);
                                        }
                                    }
                                    gpa.free(rp);
                                }
                            }
                        }
                    } else |_| {
                        for (sents.items) |e| gpa.free(e.s);
                        sents.items.len = 0;
                    }
                }
            }
            if (st.ndv > 0 and st.ndv <= 65_536) {
                var dmap = std.StringHashMap(u32).init(gpa);
                defer dmap.deinit();
                var ri2: usize = 0;
                while (ri2 < t.rows.items.len) : (ri2 += 1) {
                    const vv = t.rows.items[ri2][ci];
                    if (vv != .text) continue;
                    const gop = dmap.getOrPut(vv.text) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
                if (dmap.count() > 0 and dmap.count() <= 65_536) {
                    if (gpa.alloc(DictEntry, dmap.count())) |de| {
                        var it3 = dmap.iterator();
                        var idx3: usize = 0;
                        var okall = true;
                        while (it3.next()) |e| {
                            de[idx3] = .{ .s = gpa.dupe(u8, e.key_ptr.*) catch {
                                okall = false;
                                break;
                            }, .count = e.value_ptr.* };
                            idx3 += 1;
                        }
                        if (okall) {
                            st.dict = de;
                            var tot3: usize = 0;
                            for (de) |e| tot3 += e.count;
                            st.dict_sample_rows = tot3;
                            st.dict_sampled = false;
                        } else {
                            for (de[0..idx3]) |e| gpa.free(e.s);
                            gpa.free(de);
                        }
                    } else |_| {}
                }
            }
            {
                var grams = std.AutoHashMap(u32, u32).init(gpa);
                defer grams.deinit();
                var vseen: [64]u32 = undefined;
                for (svals.items) |v3| {
                    var nseen: usize = 0;
                    const lim = @min(v3.len, 64);
                    if (lim >= 3) {
                        var k3: usize = 0;
                        while (k3 + 3 <= lim) : (k3 += 1) {
                            const g = (@as(u32, v3[k3]) << 16) | (@as(u32, v3[k3 + 1]) << 8) | @as(u32, v3[k3 + 2]);
                            var dup = false;
                            for (vseen[0..nseen]) |x| {
                                if (x == g) {
                                    dup = true;
                                    break;
                                }
                            }
                            if (dup or nseen >= vseen.len) continue;
                            vseen[nseen] = g;
                            nseen += 1;
                            if (grams.count() >= 8192) {
                                if (grams.getPtr(g)) |p| p.* += 1;
                            } else {
                                const gop = grams.getOrPut(g) catch continue;
                                if (!gop.found_existing) gop.value_ptr.* = 0;
                                gop.value_ptr.* += 1;
                            }
                        }
                    }
                }
                var top = std.ArrayList(GramCount).empty;
                defer top.deinit(gpa);
                var git = grams.iterator();
                while (git.next()) |e| {
                    top.append(gpa, .{ .g = e.key_ptr.*, .c = e.value_ptr.* }) catch {};
                }
                std.mem.sort(GramCount, top.items, {}, struct {
                    fn gt(_: void, a: GramCount, b: GramCount) bool {
                        return a.c > b.c;
                    }
                }.gt);
                const ntake = @min(top.items.len, 256);
                if (ntake > 0) {
                    if (gpa.alloc(NgramStat, ntake)) |ns| {
                        for (top.items[0..ntake], 0..) |e, i| {
                            ns[i] = .{
                                .g = .{ @truncate(e.g >> 16), @truncate(e.g >> 8), @truncate(e.g) },
                                .freq = @as(f64, @floatFromInt(e.c)) / total,
                            };
                        }
                        st.ngram = ns;
                    } else |_| {}
                }
                var smap = std.AutoHashMap(u32, u32).init(gpa);
                defer smap.deinit();
                for (svals.items) |v3| {
                    var L: usize = 1;
                    while (L <= 3 and L <= v3.len) : (L += 1) {
                        const start3 = v3.len - L;
                        var key: u32 = @intCast(L);
                        var kk: usize = 0;
                        while (kk < 3) : (kk += 1) {
                            const b: u8 = if (kk < L) v3[start3 + kk] else 0;
                            key = (key << 8) | @as(u32, b);
                        }
                        const gop = smap.getOrPut(key) catch continue;
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                    }
                }
                var stop = std.ArrayList(GramCount).empty;
                defer stop.deinit(gpa);
                var sit2 = smap.iterator();
                while (sit2.next()) |e| stop.append(gpa, .{ .g = e.key_ptr.*, .c = e.value_ptr.* }) catch {};
                std.mem.sort(GramCount, stop.items, {}, struct {
                    fn gt(_: void, a: GramCount, b: GramCount) bool {
                        return a.c > b.c;
                    }
                }.gt);
                const stail = @min(stop.items.len, 128);
                if (stail > 0) {
                    if (gpa.alloc(SuffixStat, stail)) |ss| {
                        for (stop.items[0..stail], 0..) |e, i| {
                            ss[i] = .{
                                .len = @truncate(e.g >> 24),
                                .s = .{ @truncate(e.g >> 16), @truncate(e.g >> 8), @truncate(e.g) },
                                .freq = @as(f64, @floatFromInt(e.c)) / total,
                            };
                        }
                        st.suf = ss;
                    } else |_| {}
                }
            }
        }
        t.stats[ci] = st;
    }
    if (ct) |tab| {
        var pairs: usize = 0;
        for (tab.pair_req) |req| {
            _ = tab.pairNdvOf(gpa, req.a, req.b);
            pairs += 1;
            if (pairs >= 4096) break;
        }
        var triples: usize = 0;
        for (tab.triple_req) |req| {
            _ = tab.tripleNdvOf(gpa, req.a, req.b, req.c);
            triples += 1;
            if (triples >= 4096) break;
        }
        var sets: usize = 0;
        for (tab.multi_req) |req| {
            var cols: [8]usize = undefined;
            for (req.cols[0..req.n], 0..) |c, i| cols[i] = c;
            _ = tab.multiNdvOf(gpa, cols[0..req.n]);
            sets += 1;
            if (sets >= 4096) break;
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null and (tab.pair_req.len + tab.triple_req.len + tab.multi_req.len) > 0) {
            std.debug.print("[stats] {s}: ndv collected {d} pair(s) + {d} triple(s) + {d} set(s) (requested {d}/{d}/{d})\n", .{
                name, pairs, triples, sets, tab.pair_req.len, tab.triple_req.len, tab.multi_req.len,
            });
        }
    }
    {
        var pairs_done: usize = 0;
        for (t.or_req.items) |*r| {
            if (r.done) continue;
            self.measureOrReq(t, r);
            pairs_done += 1;
        }
        if (std.c.getenv("ZHDB_EXPLAIN") != null and pairs_done > 0) {
            std.debug.print("[stats] {s}: or pairs measured={d} resident={d} bytes={d}\n", .{
                name,
                pairs_done,
                t.or_req.items.len,
                t.or_bytes,
            });
        }
    }
    return .{ .affected = 0 };
}

pub fn ensureStats(self: *Engine, name: []const u8) void {
    if (std.mem.startsWith(u8, name, "pg_")) return;
    const t = self.find(name) orelse return;
    if (t.stats.len == t.cols.len and t.rows.items.len > 0) return;
    _ = self.execAnalyze(name) catch {};
}
