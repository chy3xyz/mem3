//! mem3-forgetting-eval, `--mode=netex` and `--mode=scale`.
//!
//! The age sweep in `forgetting_eval.zig` answers "does the *decay* rule
//! forget the right things". It cannot say anything about the other two
//! terms of `net_existence = importance - redundancy - conflict_score`,
//! because its corpus has neither duplicates nor contradictions. This file
//! is that missing half, and it is deliberately adversarial about itself:
//! the corpus includes cases the definitions are *expected to get wrong*
//! (multi-valued predicates, templated text) so that the false-positive
//! rate is a measured number, not an omission.
//!
//! ## netex: before / after on a corpus with known ground truth
//!
//! The same seeded corpus is built twice:
//!
//!   before — the forgetter as it was: decay only. Reproduced in the same
//!            binary by switching the new terms off (`supersede_on_conflict
//!            = false`, `redundancy_threshold > 1`), so the comparison is
//!            like-for-like and not against a remembered number.
//!   after  — the shipped forgetter.
//!
//! Cell kinds, by construction:
//!
//!   unique       distinct text, distinct fact          must never be forgotten
//!   dup_*        groups of an original + exact copy +  keep exactly one (the
//!                1-token and 2-token edits, same fact  most important)
//!   conflict_old a fact later contradicted             should be superseded
//!   conflict_new its contradiction                     must stay current
//!   multi        one subject, one predicate, 3 values  nothing is contradicted
//!                ("likes"): a heuristic key's weak spot (ground truth: none)
//!   templ        "ticket N closed by ..." pairs        distinct info with
//!                differing only in N, no facts         near-identical text
//!   stale        back-dated far past the decay edge    decays under both
//!
//! The same encoder, the same ids, the same sweep entry point (`Store.forget`)
//! as production; only the corpus is synthetic. Retrieval is measured too:
//! for contradiction pairs, is the top-1 hit the *current* value; for
//! duplicate groups, how many of the top-5 are copies of each other.
//!
//! ## scale: does the sweep stay sub-quadratic
//!
//! Wall time of a dry-run `Store.forget` at 1k / 5k / 20k cells (corpus
//! vocabulary grows with n, ~10% duplicates), plus a *templated* corpus —
//! every cell near-identical but carrying a different fact — which is the
//! worst case for the prefix filter: every pair is a candidate and nothing
//! is redundant. Reported next to the all-pairs count.

const std = @import("std");
const mem3 = @import("mem3");

const Allocator = std.mem.Allocator;
const Store = mem3.Store;

fn pr(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = mem3.platform.stdio.writeOut(s);
}

fn nowNs() i128 {
    return mem3.platform.clock.monotonicNs();
}

const Kind = enum {
    unique,
    dup_orig,
    dup_exact,
    dup_near1,
    dup_near2,
    conflict_old,
    conflict_new,
    multi,
    templ,
    stale,
};
const N_KINDS = 10; // == number of `Kind` tags; `@intFromEnum` indexes the arrays below

const Rec = struct { id: u64, kind: Kind, group: u32 };

pub const Shape = struct {
    unique: usize = 400,
    dup_groups: usize = 60,
    conflicts: usize = 60,
    multi_subjects: usize = 60,
    templ_pairs: usize = 60,
    stale: usize = 40,
};

const VOCAB: u32 = 200_000;

/// Append `n` random tokens ("t12345") separated by spaces.
fn words(alloc: Allocator, out: *std.ArrayList(u8), rand: std.Random, n: usize) !void {
    var tmp: [16]u8 = undefined;
    for (0..n) |i| {
        if (i > 0) try out.append(alloc, ' ');
        const w = try std.fmt.bufPrint(&tmp, "t{d}", .{rand.uintLessThan(u32, VOCAB)});
        try out.appendSlice(alloc, w);
    }
}

fn relevance(rand: std.Random) f32 {
    return 0.5 + 0.5 * rand.float(f32);
}

fn addCell(store: *Store, recs: *std.ArrayList(Rec), alloc: Allocator, kind: Kind, group: u32, ep: []const u8, facts: []const u8, rel: f32) !u64 {
    const id = try store.addRaw(.matter, ep, facts, 1, rel);
    try recs.append(alloc, .{ .id = id, .kind = kind, .group = group });
    return id;
}

fn buildCorpus(store: *Store, alloc: Allocator, seed: u64, shape: Shape, recs: *std.ArrayList(Rec)) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var ep: std.ArrayList(u8) = .empty;
    defer ep.deinit(alloc);
    var fc: std.ArrayList(u8) = .empty;
    defer fc.deinit(alloc);
    var tmp: [64]u8 = undefined;

    // unique
    for (0..shape.unique) |i| {
        ep.clearRetainingCapacity();
        fc.clearRetainingCapacity();
        try words(alloc, &ep, rand, 10);
        try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "uq{d}|rel|val{d}", .{ i, rand.uintLessThan(u32, VOCAB) }));
        _ = try addCell(store, recs, alloc, .unique, @intCast(i), ep.items, fc.items, relevance(rand));
    }

    // duplicate groups: original, exact copy, 1-token edit, 2-token edit.
    for (0..shape.dup_groups) |g| {
        var toks: [10]u32 = undefined;
        for (&toks) |*t| t.* = rand.uintLessThan(u32, VOCAB);
        fc.clearRetainingCapacity();
        try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "dg{d}|state|ok", .{g}));
        for (0..4) |m| {
            var t = toks;
            // m = 0 original, 1 exact, 2 one token changed, 3 two changed.
            if (m >= 2) t[3] = rand.uintLessThan(u32, VOCAB);
            if (m >= 3) t[7] = rand.uintLessThan(u32, VOCAB);
            ep.clearRetainingCapacity();
            for (t, 0..) |tok, i| {
                if (i > 0) try ep.append(alloc, ' ');
                try ep.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "t{d}", .{tok}));
            }
            const kind: Kind = switch (m) {
                0 => .dup_orig,
                1 => .dup_exact,
                2 => .dup_near1,
                else => .dup_near2,
            };
            _ = try addCell(store, recs, alloc, kind, @intCast(g), ep.items, fc.items, relevance(rand));
        }
    }

    // contradictions: old first, then the new value.
    for (0..shape.conflicts) |c| {
        ep.clearRetainingCapacity();
        fc.clearRetainingCapacity();
        try words(alloc, &ep, rand, 8);
        try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "cs{d}|status|alpha", .{c}));
        _ = try addCell(store, recs, alloc, .conflict_old, @intCast(c), ep.items, fc.items, relevance(rand));
        ep.clearRetainingCapacity();
        fc.clearRetainingCapacity();
        try words(alloc, &ep, rand, 8);
        try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "cs{d}|status|beta", .{c}));
        _ = try addCell(store, recs, alloc, .conflict_new, @intCast(c), ep.items, fc.items, relevance(rand));
    }

    // multi-valued: three "likes" per subject, none of which contradicts another.
    for (0..shape.multi_subjects) |s| {
        for (0..3) |v| {
            ep.clearRetainingCapacity();
            fc.clearRetainingCapacity();
            try words(alloc, &ep, rand, 8);
            try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "ms{d}|likes|item{d}", .{ s, v }));
            _ = try addCell(store, recs, alloc, .multi, @intCast(s), ep.items, fc.items, relevance(rand));
        }
    }

    // templated pairs with no facts, differing in one token.
    for (0..shape.templ_pairs) |k| {
        for (0..2) |v| {
            ep.clearRetainingCapacity();
            const n = rand.uintLessThan(u32, VOCAB);
            _ = v;
            try ep.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "ticket n{d} ", .{n}));
            try ep.appendSlice(alloc, "closed by the platform team after review in the sprint on friday");
            _ = try addCell(store, recs, alloc, .templ, @intCast(k), ep.items, "", relevance(rand));
        }
    }

    // stale: genuinely old; the decay rule must still catch them.
    const now_ms = mem3.utils.time.nowMs();
    for (0..shape.stale) |i| {
        ep.clearRetainingCapacity();
        fc.clearRetainingCapacity();
        try words(alloc, &ep, rand, 10);
        try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "st{d}|age|old", .{i}));
        const id = try addCell(store, recs, alloc, .stale, @intCast(i), ep.items, fc.items, 0.3);
        if (store.getCell(id)) |cell| cell.metadata.created_at = now_ms - 600 * 86_400_000;
    }
}

const Side = struct {
    forgotten: [N_KINDS]usize = @splat(0),
    total: [N_KINDS]usize = @splat(0),
    superseded: [N_KINDS]usize = @splat(0),
    // sweep counters
    res_decayed: usize = 0,
    res_redundant: usize = 0,
    res_conflicted: usize = 0,
    res_superseded: usize = 0,
    // retrieval
    conflict_top1_current: usize = 0,
    conflict_queries: usize = 0,
    dup_members_in_top5: usize = 0,
    dup_queries: usize = 0,
    dup_group_found: usize = 0,
    // dup-group survivors that are the most important member
    dup_rep_kept: usize = 0,
    dup_groups: usize = 0,
    sweep_ms: f64 = 0,
};

fn evaluate(alloc: Allocator, seed: u64, shape: Shape, legacy: bool) !Side {
    const store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = true });
    defer store.deinit();
    if (legacy) {
        // The forgetter before this change: decay only.
        store.lc.cfg.supersede_on_conflict = false;
        store.lc.forgetter.cfg.supersede_on_conflict = false;
        store.lc.forgetter.cfg.redundancy_threshold = 2.0;
    }

    var recs: std.ArrayList(Rec) = .empty;
    defer recs.deinit(alloc);
    try buildCorpus(store, alloc, seed, shape, &recs);

    var side = Side{};
    for (recs.items) |r| side.total[@intFromEnum(r.kind)] += 1;

    // Which member of each duplicate group is the most important (the one
    // a correct sweep keeps)?
    var best_of_group = std.AutoHashMap(u32, struct { id: u64, imp: f32 }).init(alloc);
    defer best_of_group.deinit();
    for (recs.items) |r| {
        switch (r.kind) {
            .dup_orig, .dup_exact, .dup_near1, .dup_near2 => {},
            else => continue,
        }
        const imp = store.getCell(r.id).?.metadata.importance_score;
        const e = try best_of_group.getOrPut(r.group);
        if (!e.found_existing or imp > e.value_ptr.imp) e.value_ptr.* = .{ .id = r.id, .imp = imp };
    }

    // ---- retrieval BEFORE the sweep is not what we compare; both sides are
    // measured AFTER their own sweep, which is what a user would see.
    const t0 = nowNs();
    const sw = try store.forget(false);
    side.sweep_ms = @as(f64, @floatFromInt(nowNs() - t0)) / 1e6;
    side.res_decayed = sw.decayed;
    side.res_redundant = sw.redundant;
    side.res_conflicted = sw.conflicted;
    side.res_superseded = sw.superseded;

    for (recs.items) |r| {
        const k = @intFromEnum(r.kind);
        if (store.getCell(r.id) == null) side.forgotten[k] += 1;
        const cell = store.getCell(r.id) orelse store.lc.fuzzy.cells.get(r.id) orelse continue;
        if (cell.metadata.superseded_at != null) side.superseded[k] += 1;
    }

    var it = best_of_group.iterator();
    while (it.next()) |e| {
        side.dup_groups += 1;
        if (store.getCell(e.value_ptr.id) != null) side.dup_rep_kept += 1;
    }

    // ---- retrieval: contradiction pairs. Query = the pair's shared key.
    // Default recall (legacy store never marks anything, so it is the
    // pre-change behaviour: old and new compete on score).
    var qbuf: [64]u8 = undefined;
    var c_old = std.AutoHashMap(u32, u64).init(alloc);
    defer c_old.deinit();
    var c_new = std.AutoHashMap(u32, u64).init(alloc);
    defer c_new.deinit();
    for (recs.items) |r| switch (r.kind) {
        .conflict_old => try c_old.put(r.group, r.id),
        .conflict_new => try c_new.put(r.group, r.id),
        else => {},
    };
    for (0..shape.conflicts) |c| {
        const new_id = c_new.get(@intCast(c)).?;
        const old_id = c_old.get(@intCast(c)).?;
        // The episode of the new cell is the query: "which memory states the
        // current value of this key". Query by the shared fact key words.
        const text = try std.fmt.bufPrint(&qbuf, "cs{d} status", .{c});
        const hits = try store.query(alloc, text, .{ .topk = 5 });
        defer alloc.free(hits);
        // Only count queries where at least one of the pair is reachable.
        var found_any = false;
        for (hits) |h| if (h.cell.id == new_id or h.cell.id == old_id) {
            found_any = true;
        };
        if (!found_any) continue;
        side.conflict_queries += 1;
        for (hits) |h| {
            if (h.cell.id == new_id or h.cell.id == old_id) {
                if (h.cell.id == new_id) side.conflict_top1_current += 1;
                break;
            }
        }
    }

    // ---- retrieval: duplicate groups. Query = the original's own text.
    var group_text = std.AutoHashMap(u32, []const u8).init(alloc);
    defer {
        var gt = group_text.valueIterator();
        while (gt.next()) |v| alloc.free(v.*);
        group_text.deinit();
    }
    var group_members = std.AutoHashMap(u32, std.ArrayList(u64)).init(alloc);
    defer {
        var gm = group_members.valueIterator();
        while (gm.next()) |v| v.deinit(alloc);
        group_members.deinit();
    }
    for (recs.items) |r| {
        switch (r.kind) {
            .dup_orig, .dup_exact, .dup_near1, .dup_near2 => {},
            else => continue,
        }
        const e = try group_members.getOrPut(r.group);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(alloc, r.id);
        if (r.kind == .dup_orig) {
            const c = store.getCell(r.id) orelse store.lc.fuzzy.cells.get(r.id).?;
            try group_text.put(r.group, try alloc.dupe(u8, c.episode));
        }
    }
    var gi = group_members.iterator();
    while (gi.next()) |e| {
        const text = group_text.get(e.key_ptr.*).?;
        const hits = try store.query(alloc, text, .{ .topk = 5 });
        defer alloc.free(hits);
        side.dup_queries += 1;
        var members: usize = 0;
        for (hits) |h| {
            for (e.value_ptr.items) |m| if (m == h.cell.id) {
                members += 1;
                break;
            };
        }
        side.dup_members_in_top5 += members;
        if (members > 0) side.dup_group_found += 1;
    }
    return side;
}

fn pct(n: usize, d: usize) f64 {
    if (d == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d));
}

fn row(name: []const u8, b: Side, a: Side, k: Kind) void {
    const i = @intFromEnum(k);
    pr("  {s:<14} n={d:<4} forgotten before={d:<4} after={d:<4}  superseded before={d:<3} after={d:<3}\n", .{
        name, a.total[i], b.forgotten[i], a.forgotten[i], b.superseded[i], a.superseded[i],
    });
}

pub fn runNetex(alloc: Allocator, seed: u64, shape: Shape) !void {
    const before = try evaluate(alloc, seed, shape, true);
    const after = try evaluate(alloc, seed, shape, false);

    var n_cells: usize = 0;
    for (after.total) |t| n_cells += t;
    pr("\n=== net_existence evaluation: seed={d}, {d} cells ===\n\n", .{ seed, n_cells });
    pr("Per kind (forgotten = moved to the fuzzy store; superseded = marked superseded_at):\n", .{});
    row("unique", before, after, .unique);
    row("dup_orig", before, after, .dup_orig);
    row("dup_exact", before, after, .dup_exact);
    row("dup_near1", before, after, .dup_near1);
    row("dup_near2", before, after, .dup_near2);
    row("conflict_old", before, after, .conflict_old);
    row("conflict_new", before, after, .conflict_new);
    row("multi", before, after, .multi);
    row("templ", before, after, .templ);
    row("stale", before, after, .stale);

    pr("\nSweep reasons (before | after):\n", .{});
    pr("  decayed    {d:>5} | {d:<5}\n", .{ before.res_decayed, after.res_decayed });
    pr("  redundant  {d:>5} | {d:<5}\n", .{ before.res_redundant, after.res_redundant });
    pr("  conflicted {d:>5} | {d:<5}\n", .{ before.res_conflicted, after.res_conflicted });
    pr("  superseded {d:>5} | {d:<5}   (newly marked by the sweep; write-time marks are counted per kind above)\n", .{ before.res_superseded, after.res_superseded });

    // ---- derived: duplicates
    const d_orig = @intFromEnum(Kind.dup_orig);
    const d_exact = @intFromEnum(Kind.dup_exact);
    const d_n1 = @intFromEnum(Kind.dup_near1);
    const d_n2 = @intFromEnum(Kind.dup_near2);
    const exact_removed_a = after.forgotten[d_orig] + after.forgotten[d_exact];
    const exact_removed_b = before.forgotten[d_orig] + before.forgotten[d_exact];
    var fp_after: usize = 0;
    var fp_before: usize = 0;
    for ([_]Kind{ .unique, .conflict_new, .multi, .templ }) |k| {
        fp_after += after.forgotten[@intFromEnum(k)];
        fp_before += before.forgotten[@intFromEnum(k)];
    }
    pr("\nDuplicates ({d} groups: original + exact copy + 1-token edit + 2-token edit, one fact each):\n", .{after.dup_groups});
    pr("  exact-copy pairs reduced to one cell   before {d}/{d}   after {d}/{d}\n", .{ exact_removed_b, after.dup_groups, exact_removed_a, after.dup_groups });
    pr("  most-important member of the group kept   before {d}/{d}   after {d}/{d}\n", .{ before.dup_rep_kept, before.dup_groups, after.dup_rep_kept, after.dup_groups });
    pr("  near-duplicates forgotten: 1-token edit (J~0.86) {d}/{d}, 2-token edit (J~0.67, below tau) {d}/{d}\n", .{
        after.forgotten[d_n1], after.total[d_n1], after.forgotten[d_n2], after.total[d_n2],
    });
    pr("  (a near-duplicate is forgotten only when s > importance/(importance+theta); at typical importance that needs J ~ 0.96+, so these stay, with a lowered net_existence.)\n", .{});

    // ---- derived: supersession
    const co = @intFromEnum(Kind.conflict_old);
    const cn = @intFromEnum(Kind.conflict_new);
    const mu = @intFromEnum(Kind.multi);
    const sup_tp = after.superseded[co];
    const sup_fp_new = after.superseded[cn];
    const sup_fp_multi = after.superseded[mu];
    const sup_fp = sup_fp_new + sup_fp_multi + after.superseded[@intFromEnum(Kind.unique)];
    const sup_total = sup_tp + sup_fp;
    // The last of three multi-values is never superseded by definition; the
    // first two are what the heuristic key wrongly marks.
    pr("\nSupersession (ground truth: conflict_old superseded; nothing else):\n", .{});
    pr("  recall    {d}/{d} ({d:.1}%)\n", .{ sup_tp, after.total[co], pct(sup_tp, after.total[co]) });
    pr("  precision {d}/{d} ({d:.1}%)   false marks: multi-valued={d} (of {d} cells), conflict_new={d}\n", .{
        sup_tp, sup_total, pct(sup_tp, sup_total), sup_fp_multi, after.total[mu], sup_fp_new,
    });

    // ---- derived: collateral
    pr("\nCollateral (must be 0 for unique / conflict_new; templ and multi are known weak spots):\n", .{});
    pr("  forgotten non-duplicate cells   before {d}   after {d}\n", .{ fp_before, fp_after });
    pr("  unique forgotten                before {d}   after {d}   (of {d})\n", .{ before.forgotten[@intFromEnum(Kind.unique)], after.forgotten[@intFromEnum(Kind.unique)], after.total[@intFromEnum(Kind.unique)] });
    pr("  templ forgotten                 before {d}   after {d}   (of {d}; distinct tickets whose text differs by one token)\n", .{ before.forgotten[@intFromEnum(Kind.templ)], after.forgotten[@intFromEnum(Kind.templ)], after.total[@intFromEnum(Kind.templ)] });

    // ---- derived: retrieval
    pr("\nRetrieval after the sweep:\n", .{});
    pr("  contradiction pairs, top-1 hit is the CURRENT value   before {d}/{d} ({d:.1}%)   after {d}/{d} ({d:.1}%)\n", .{
        before.conflict_top1_current, before.conflict_queries, pct(before.conflict_top1_current, before.conflict_queries),
        after.conflict_top1_current,  after.conflict_queries,  pct(after.conflict_top1_current, after.conflict_queries),
    });
    const bd = if (before.dup_queries == 0) 0.0 else @as(f64, @floatFromInt(before.dup_members_in_top5)) / @as(f64, @floatFromInt(before.dup_queries));
    const ad = if (after.dup_queries == 0) 0.0 else @as(f64, @floatFromInt(after.dup_members_in_top5)) / @as(f64, @floatFromInt(after.dup_queries));
    pr("  duplicate groups, copies of one memory in top-5 (mean)  before {d:.2}   after {d:.2}\n", .{ bd, ad });
    pr("  duplicate groups still reachable (>=1 member in top-5)   before {d}/{d}   after {d}/{d}\n", .{ before.dup_group_found, before.dup_queries, after.dup_group_found, after.dup_queries });
    pr("\nSweep wall time (whole corpus, includes the move to the fuzzy store): before {d:.1} ms, after {d:.1} ms\n\n", .{ before.sweep_ms, after.sweep_ms });
}

// ============================================================================
// scale
// ============================================================================

const ScaleKind = enum { realistic, templated };

fn buildScale(store: *Store, alloc: Allocator, n: usize, kind: ScaleKind) !void {
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var ep: std.ArrayList(u8) = .empty;
    defer ep.deinit(alloc);
    var fc: std.ArrayList(u8) = .empty;
    defer fc.deinit(alloc);
    var tmp: [64]u8 = undefined;
    const vocab: u32 = @intCast(n * 3); // vocabulary grows with the corpus
    var prev_ep: std.ArrayList(u8) = .empty;
    defer prev_ep.deinit(alloc);
    for (0..n) |i| {
        ep.clearRetainingCapacity();
        fc.clearRetainingCapacity();
        switch (kind) {
            .realistic => {
                if (i > 0 and rand.uintLessThan(u8, 10) == 0) {
                    // ~10% exact duplicates of the previous cell
                    try ep.appendSlice(alloc, prev_ep.items);
                    try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "f{d}|is|x", .{i -| 1}));
                } else {
                    for (0..10) |j| {
                        if (j > 0) try ep.append(alloc, ' ');
                        try ep.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "w{d}", .{rand.uintLessThan(u32, vocab)}));
                    }
                    try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "f{d}|is|x", .{i}));
                }
                prev_ep.clearRetainingCapacity();
                try prev_ep.appendSlice(alloc, ep.items);
            },
            .templated => {
                // 12 shared tokens + 1 varying: every pair has Jaccard 12/14,
                // every cell carries its own fact, so none is redundant.
                try ep.appendSlice(alloc, "ticket closed by the platform team after review in the sprint on friday ");
                try ep.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "n{d}", .{i}));
                try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "tk{d}|closed|yes", .{i}));
            },
        }
        _ = try store.addRaw(.matter, ep.items, fc.items, 1, 0.7);
    }
}

pub fn runScale(alloc: Allocator, max_n: usize) !void {
    const sizes = [_]usize{ 1000, 5000, 20000 };
    pr("\n=== sweep scaling (dry-run Store.forget, ReleaseFast) ===\n", .{});
    for ([_]ScaleKind{ .realistic, .templated }) |kind| {
        pr("\ncorpus: {s}\n", .{switch (kind) {
            .realistic => "realistic (growing vocabulary, ~10% exact duplicates, unique facts)",
            .templated => "templated worst case (every pair Jaccard 0.86, every cell a distinct fact)",
        }});
        pr("  {s:>7} {s:>10} {s:>14} {s:>14} {s:>10} {s:>10}\n", .{ "cells", "sweep ms", "jaccard evals", "all pairs", "evals/n", "ms ratio" });
        var prev_ms: f64 = 0;
        var prev_n: usize = 0;
        for (sizes) |n| {
            if (n > max_n) break;
            const store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = true });
            defer store.deinit();
            try buildScale(store, alloc, n, kind);
            // best of 3: a dry-run mutates nothing, so repeats are comparable
            var best: f64 = std.math.inf(f64);
            var evals: u64 = 0;
            for (0..3) |_| {
                const t0 = nowNs();
                const r = try store.forget(true);
                const ms = @as(f64, @floatFromInt(nowNs() - t0)) / 1e6;
                if (ms < best) best = ms;
                evals = r.jaccard_evals;
            }
            const all_pairs: u64 = @as(u64, n) * (n - 1) / 2;
            var ratio_buf: [24]u8 = undefined;
            const ratio = if (prev_n == 0) "-" else std.fmt.bufPrint(&ratio_buf, "{d:.1}x", .{best / prev_ms}) catch "?";
            pr("  {d:>7} {d:>10.1} {d:>14} {d:>14} {d:>10.2} {s:>10}\n", .{
                n, best, evals, all_pairs, @as(f64, @floatFromInt(evals)) / @as(f64, @floatFromInt(n)), ratio,
            });
            if (prev_n != 0) {
                const exp = @log(best / prev_ms) / @log(@as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(prev_n)));
                pr("          local scaling exponent vs previous row: {d:.2} (1.00 = linear, 2.00 = quadratic)\n", .{exp});
            }
            prev_ms = best;
            prev_n = n;
        }
    }
    pr("\n", .{});
}
