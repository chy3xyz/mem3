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
//! ## netex: three arms on a corpus with known ground truth
//!
//! The same seeded corpus is built three times, through the same encoder and
//! the same sweep entry point (`Store.forget`) as production:
//!
//!   decay_only  the forgetter before net_existence: decay only. Reproduced in
//!               the same binary by switching the new terms off
//!               (`supersede_mode = off`, `redundancy_threshold > 1`), so the
//!               comparison is like-for-like.
//!   all         the first net_existence cut: every (subject, predicate) is
//!               single-valued. Kept as `--supersede=all`; it is the arm whose
//!               multi-valued false positives motivated the default below.
//!   functional  the shipped default: only the single-valued predicate list
//!               (`memory/conflict.zig`) may supersede.
//!
//! Cell kinds, by construction:
//!
//!   unique       distinct text, distinct fact          must never be forgotten
//!   dup_*        groups of an original + exact copy +  keep exactly one (the
//!                1-token and 2-token edits, same fact  most important)
//!   conflict_*   `status` (functional) old/new pair    old superseded, new current
//!   unknown_*    `shoe_size` (not on the list) pair    ground truth: contradiction;
//!                                                      the default does NOT supersede
//!                                                      it, on purpose (abandoned recall)
//!   multi        one subject, a multi-valued predicate, ground truth: none superseded,
//!                three values (likes/knows/uses/...)    none forgotten
//!   templ        "ticket N closed by ..." pairs        distinct info with
//!                differing only in N, no facts         near-identical text
//!   stale        back-dated far past the decay edge    decays under all arms
//!
//! The functional arm's guarantees are asserted, not just reported: the
//! process exits non-zero if a multi-valued or unknown-predicate cell is
//! superseded or forgotten, if a conflict_old is not superseded, or if a
//! unique cell is forgotten. (The same properties are also unit/e2e tests.)
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
    unknown_old,
    unknown_new,
    multi,
    templ,
    stale,
};
const N_KINDS = 12; // == number of `Kind` tags; `@intFromEnum` indexes the arrays below

const Rec = struct { id: u64, kind: Kind, group: u32 };

pub const Shape = struct {
    unique: usize = 400,
    dup_groups: usize = 60,
    conflicts: usize = 60,
    unknown_conflicts: usize = 60,
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

    // unknown predicate: a real contradiction the default list cannot see.
    for (0..shape.unknown_conflicts) |c| {
        ep.clearRetainingCapacity();
        fc.clearRetainingCapacity();
        try words(alloc, &ep, rand, 8);
        try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "cu{d}|shoe_size|alpha", .{c}));
        _ = try addCell(store, recs, alloc, .unknown_old, @intCast(c), ep.items, fc.items, relevance(rand));
        ep.clearRetainingCapacity();
        fc.clearRetainingCapacity();
        try words(alloc, &ep, rand, 8);
        try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "cu{d}|shoe_size|beta", .{c}));
        _ = try addCell(store, recs, alloc, .unknown_new, @intCast(c), ep.items, fc.items, relevance(rand));
    }

    // multi-valued: three values per subject, none of which contradicts
    // another. The predicate rotates so the result is not about one word.
    const multi_preds = [_][]const u8{ "likes", "knows", "uses", "prefers", "speaks", "visited" };
    for (0..shape.multi_subjects) |s| {
        for (0..3) |v| {
            ep.clearRetainingCapacity();
            fc.clearRetainingCapacity();
            try words(alloc, &ep, rand, 8);
            try fc.appendSlice(alloc, try std.fmt.bufPrint(&tmp, "ms{d}|{s}|item{d}", .{ s, multi_preds[s % multi_preds.len], v }));
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

const Arm = enum { decay_only, all, functional };

const Side = struct {
    forgotten: [N_KINDS]usize = @splat(0),
    total: [N_KINDS]usize = @splat(0),
    superseded: [N_KINDS]usize = @splat(0),
    // sweep counters
    res_decayed: usize = 0,
    res_redundant: usize = 0,
    res_conflicted: usize = 0,
    res_superseded: usize = 0,
    // retrieval: is the top-1 hit of a contradiction pair the CURRENT value?
    conflict_top1_current: usize = 0,
    conflict_queries: usize = 0,
    unknown_top1_current: usize = 0,
    unknown_queries: usize = 0,
    dup_members_in_top5: usize = 0,
    dup_queries: usize = 0,
    dup_group_found: usize = 0,
    // dup-group survivors that are the most important member
    dup_rep_kept: usize = 0,
    dup_groups: usize = 0,
    sweep_ms: f64 = 0,
};

/// For each contradiction pair, query by the pair's shared key and ask whether
/// the first of the pair to appear is the new (current) cell. Only queries where
/// at least one of the two is reachable count.
fn pairRetrieval(
    store: *Store,
    alloc: Allocator,
    recs: []const Rec,
    old_kind: Kind,
    new_kind: Kind,
    comptime key_fmt: []const u8,
    n: usize,
    queries: *usize,
    top1_current: *usize,
) !void {
    var c_old = std.AutoHashMap(u32, u64).init(alloc);
    defer c_old.deinit();
    var c_new = std.AutoHashMap(u32, u64).init(alloc);
    defer c_new.deinit();
    for (recs) |r| {
        if (r.kind == old_kind) try c_old.put(r.group, r.id);
        if (r.kind == new_kind) try c_new.put(r.group, r.id);
    }
    var qbuf: [64]u8 = undefined;
    for (0..n) |c| {
        const new_id = c_new.get(@intCast(c)).?;
        const old_id = c_old.get(@intCast(c)).?;
        const text = try std.fmt.bufPrint(&qbuf, key_fmt, .{c});
        const hits = try store.query(alloc, text, .{ .topk = 5 });
        defer alloc.free(hits);
        var found_any = false;
        for (hits) |h| if (h.cell.id == new_id or h.cell.id == old_id) {
            found_any = true;
        };
        if (!found_any) continue;
        queries.* += 1;
        for (hits) |h| {
            if (h.cell.id == new_id or h.cell.id == old_id) {
                if (h.cell.id == new_id) top1_current.* += 1;
                break;
            }
        }
    }
}

fn evaluate(alloc: Allocator, seed: u64, shape: Shape, arm: Arm) !Side {
    const store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = true });
    defer store.deinit();
    switch (arm) {
        // The forgetter before net_existence: decay only.
        .decay_only => {
            store.setSupersedeMode(.off);
            store.lc.forgetter.cfg.redundancy_threshold = 2.0;
        },
        // The first cut: every subject+predicate is single-valued.
        .all => store.setSupersedeMode(.all),
        .functional => {},
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

    // Every arm is measured AFTER its own sweep, which is what a user sees.
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

    try pairRetrieval(store, alloc, recs.items, .conflict_old, .conflict_new, "cs{d} status", shape.conflicts, &side.conflict_queries, &side.conflict_top1_current);
    try pairRetrieval(store, alloc, recs.items, .unknown_old, .unknown_new, "cu{d} shoe_size", shape.unknown_conflicts, &side.unknown_queries, &side.unknown_top1_current);

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

fn row(name: []const u8, sides: [3]Side, k: Kind) void {
    const i = @intFromEnum(k);
    pr("  {s:<13} n={d:<4} forgotten {d:>3} | {d:>3} | {d:>3}     superseded {d:>3} | {d:>3} | {d:>3}\n", .{
        name,
        sides[2].total[i],
        sides[0].forgotten[i],
        sides[1].forgotten[i],
        sides[2].forgotten[i],
        sides[0].superseded[i],
        sides[1].superseded[i],
        sides[2].superseded[i],
    });
}

fn meanTop5(s: Side) f64 {
    return if (s.dup_queries == 0) 0.0 else @as(f64, @floatFromInt(s.dup_members_in_top5)) / @as(f64, @floatFromInt(s.dup_queries));
}

/// Prints the table, then fails with `error.GuaranteeBroken` if a guarantee of the
/// default (functional) arm does not hold.
pub fn runNetex(alloc: Allocator, seed: u64, shape: Shape) !void {
    const sides = [3]Side{
        try evaluate(alloc, seed, shape, .decay_only),
        try evaluate(alloc, seed, shape, .all),
        try evaluate(alloc, seed, shape, .functional),
    };
    const d = sides[0];
    const all = sides[1];
    const fun = sides[2];

    var n_cells: usize = 0;
    for (fun.total) |t| n_cells += t;
    pr("\n=== net_existence evaluation: seed={d}, {d} cells ===\n", .{ seed, n_cells });
    pr("Arms, left to right: decay_only (before net_existence) | all (first cut: every predicate single-valued) | functional (default)\n\n", .{});
    pr("Per kind (forgotten = moved to the fuzzy store; superseded = marked superseded_at):\n", .{});
    row("unique", sides, .unique);
    row("dup_orig", sides, .dup_orig);
    row("dup_exact", sides, .dup_exact);
    row("dup_near1", sides, .dup_near1);
    row("dup_near2", sides, .dup_near2);
    row("conflict_old", sides, .conflict_old);
    row("conflict_new", sides, .conflict_new);
    row("unknown_old", sides, .unknown_old);
    row("unknown_new", sides, .unknown_new);
    row("multi", sides, .multi);
    row("templ", sides, .templ);
    row("stale", sides, .stale);

    pr("\nSweep reasons (decay_only | all | functional):\n", .{});
    pr("  decayed    {d:>5} | {d:>5} | {d:<5}\n", .{ d.res_decayed, all.res_decayed, fun.res_decayed });
    pr("  redundant  {d:>5} | {d:>5} | {d:<5}\n", .{ d.res_redundant, all.res_redundant, fun.res_redundant });
    pr("  conflicted {d:>5} | {d:>5} | {d:<5}\n", .{ d.res_conflicted, all.res_conflicted, fun.res_conflicted });
    pr("  superseded {d:>5} | {d:>5} | {d:<5}   (newly marked by the sweep; write-time marks are counted per kind above)\n", .{ d.res_superseded, all.res_superseded, fun.res_superseded });

    const co = @intFromEnum(Kind.conflict_old);
    const uo = @intFromEnum(Kind.unknown_old);
    const mu = @intFromEnum(Kind.multi);
    const un = @intFromEnum(Kind.unique);
    const cn = @intFromEnum(Kind.conflict_new);
    const un_new = @intFromEnum(Kind.unknown_new);

    // ---- derived: duplicates (the same in every arm that has the term)
    const d_orig = @intFromEnum(Kind.dup_orig);
    const d_exact = @intFromEnum(Kind.dup_exact);
    pr("\nDuplicates ({d} groups: original + exact copy + 1-token edit + 2-token edit, one fact each):\n", .{fun.dup_groups});
    pr("  exact-copy pairs reduced to one cell   decay_only {d}/{d}   functional {d}/{d}\n", .{
        d.forgotten[d_orig] + d.forgotten[d_exact], fun.dup_groups, fun.forgotten[d_orig] + fun.forgotten[d_exact], fun.dup_groups,
    });
    pr("  most-important member of the group kept   decay_only {d}/{d}   functional {d}/{d}\n", .{ d.dup_rep_kept, d.dup_groups, fun.dup_rep_kept, fun.dup_groups });
    pr("  duplicate copies in top-5 (mean)   decay_only {d:.2}   functional {d:.2}\n", .{ meanTop5(d), meanTop5(fun) });

    // ---- the three supersession scenarios, per arm
    pr("\nSupersession, by scenario (recall = contradicted cells superseded; false = cells superseded that no fact contradicts):\n", .{});
    pr("  (a) single-valued `status`   n={d}:  recall  all {d}/{d}   functional {d}/{d}\n", .{ fun.total[co], all.superseded[co], all.total[co], fun.superseded[co], fun.total[co] });
    pr("  (b) multi-valued (rotating)  n={d}:  false marks  all {d}   functional {d}      forgotten  all {d}   functional {d}\n", .{
        fun.total[mu], all.superseded[mu], fun.superseded[mu], all.forgotten[mu], fun.forgotten[mu],
    });
    pr("  (c) unknown `shoe_size`      n={d}:  recall  all {d}/{d}   functional {d}/{d}   <- the abandoned recall: real contradictions the default leaves visible\n", .{
        fun.total[uo], all.superseded[uo], all.total[uo], fun.superseded[uo], fun.total[uo],
    });

    // ---- derived: collateral
    pr("\nCollateral (must be 0 for unique / conflict_new / unknown_new):\n", .{});
    pr("  unique forgotten        decay_only {d}   all {d}   functional {d}   (of {d})\n", .{ d.forgotten[un], all.forgotten[un], fun.forgotten[un], fun.total[un] });
    pr("  conflict_new forgotten  decay_only {d}   all {d}   functional {d}\n", .{ d.forgotten[cn], all.forgotten[cn], fun.forgotten[cn] });
    pr("  templ forgotten         decay_only {d}   all {d}   functional {d}   (of {d}; distinct tickets whose text differs by one token)\n", .{
        d.forgotten[@intFromEnum(Kind.templ)], all.forgotten[@intFromEnum(Kind.templ)], fun.forgotten[@intFromEnum(Kind.templ)], fun.total[@intFromEnum(Kind.templ)],
    });

    // ---- derived: retrieval
    pr("\nRetrieval after the sweep (top-1 hit of a contradiction pair is the CURRENT value):\n", .{});
    pr("  (a) status      decay_only {d}/{d} ({d:.1}%)   all {d}/{d} ({d:.1}%)   functional {d}/{d} ({d:.1}%)\n", .{
        d.conflict_top1_current,   d.conflict_queries,   pct(d.conflict_top1_current, d.conflict_queries),
        all.conflict_top1_current, all.conflict_queries, pct(all.conflict_top1_current, all.conflict_queries),
        fun.conflict_top1_current, fun.conflict_queries, pct(fun.conflict_top1_current, fun.conflict_queries),
    });
    pr("  (c) shoe_size   decay_only {d}/{d} ({d:.1}%)   all {d}/{d} ({d:.1}%)   functional {d}/{d} ({d:.1}%)   (functional shows both values, so the old one can rank first)\n", .{
        d.unknown_top1_current,   d.unknown_queries,   pct(d.unknown_top1_current, d.unknown_queries),
        all.unknown_top1_current, all.unknown_queries, pct(all.unknown_top1_current, all.unknown_queries),
        fun.unknown_top1_current, fun.unknown_queries, pct(fun.unknown_top1_current, fun.unknown_queries),
    });
    pr("\nSweep wall time (whole corpus, includes the move to the fuzzy store): decay_only {d:.1} ms, all {d:.1} ms, functional {d:.1} ms\n", .{ d.sweep_ms, all.sweep_ms, fun.sweep_ms });

    // ---- guarantees of the shipped default
    var broken: usize = 0;
    const checks = [_]struct { name: []const u8, ok: bool }{
        .{ .name = "(a) every contradicted `status` cell superseded", .ok = fun.superseded[co] == fun.total[co] },
        .{ .name = "(a) no `status` current cell superseded", .ok = fun.superseded[cn] == 0 },
        .{ .name = "(b) 0 multi-valued cells superseded", .ok = fun.superseded[mu] == 0 },
        .{ .name = "(b) 0 multi-valued cells forgotten", .ok = fun.forgotten[mu] == 0 },
        .{ .name = "(c) 0 unknown-predicate cells superseded", .ok = fun.superseded[uo] == 0 and fun.superseded[un_new] == 0 },
        .{ .name = "(c) 0 unknown-predicate cells forgotten", .ok = fun.forgotten[uo] == 0 and fun.forgotten[un_new] == 0 },
        .{ .name = "0 unique cells forgotten", .ok = fun.forgotten[un] == 0 },
    };
    pr("\nAssertions on the default (functional) arm:\n", .{});
    for (checks) |c| {
        pr("  {s}  {s}\n", .{ if (c.ok) "PASS" else "FAIL", c.name });
        if (!c.ok) broken += 1;
    }
    pr("\n", .{});
    if (broken != 0) return error.GuaranteeBroken;
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
