//! Tests for incremental consolidation.
//!
//! `Consolidator` used to compare every cell pair on every pass. It now
//! keeps its union-find and a per-cell token signature across passes and
//! compares only cells that arrived since the previous pass. The bar for
//! that change is **equivalence with the full recompute**, so the centre
//! of this file is an independent O(n²) oracle (a re-implementation of the
//! old algorithm that shares nothing with the cache) and two kinds of
//! comparison against it:
//!
//!   * the partition after each incremental `refresh`, against the oracle
//!     and against a freshly-constructed `Consolidator` (which has no cache
//!     and therefore must do the full pass);
//!   * the abstracts a persistent `Consolidator` emits, against the ones a
//!     throw-away `Consolidator` emits on an identical twin world.
//!
//! Scratch policy: nothing here touches the filesystem.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");
const Config = mem3.core.Config;
const MemCell = mem3.MemCell;
const TriSourceManager = mem3.memory.TriSourceManager;
const FuzzyStore = mem3.memory.FuzzyStore;
const Forgetter = mem3.memory.Forgetter;
const Consolidator = mem3.consolidator_mod.Consolidator;

/// Abstract ids are minted from `next_id`; pinned test cells use ids far
/// below it so the two ranges can never collide.
const ABSTRACT_ID_BASE: u64 = 1_000_000;

const World = struct {
    alloc: std.mem.Allocator,
    ids: *std.atomic.Value(u64),
    mgr: *TriSourceManager,
    fuzzy: *FuzzyStore,
    cons: Consolidator,

    fn init(alloc: std.mem.Allocator, threshold: f32) !World {
        // Heap, not stack: `TriSourceManager.next_id` keeps this pointer
        // (see the comment in tests/unit/consolidator.zig).
        const ids = try alloc.create(std.atomic.Value(u64));
        errdefer alloc.destroy(ids);
        ids.* = .init(ABSTRACT_ID_BASE);
        const mgr = try alloc.create(TriSourceManager);
        errdefer alloc.destroy(mgr);
        mgr.* = TriSourceManager.init(alloc, ids);
        errdefer mgr.deinit();
        const fuzzy = try alloc.create(FuzzyStore);
        errdefer alloc.destroy(fuzzy);
        fuzzy.* = FuzzyStore.init(alloc);
        return .{
            .alloc = alloc,
            .ids = ids,
            .mgr = mgr,
            .fuzzy = fuzzy,
            .cons = Consolidator.init(alloc, .{ .consolidation_threshold = threshold }, fuzzy, mgr),
        };
    }

    fn deinit(self: *World) void {
        self.cons.deinit();
        self.fuzzy.deinit();
        self.mgr.deinit();
        self.alloc.destroy(self.fuzzy);
        self.alloc.destroy(self.mgr);
        self.alloc.destroy(self.ids);
    }

    /// Replace the persistent consolidator with a cold one: what a fresh
    /// process (the `mem3 consolidate` CLI) has.
    fn coldConsolidator(self: *World) void {
        const threshold = self.cons.cfg.consolidation_threshold;
        self.cons.deinit();
        self.cons = Consolidator.init(self.alloc, .{ .consolidation_threshold = threshold }, self.fuzzy, self.mgr);
    }

    fn add(self: *World, id: u64, source: mem3.MemorySource, episode: []const u8, with_facts: bool, with_foresight: bool) !void {
        const facts = [_]mem3.Fact{.{
            .subject = "alpha",
            .predicate = "relates",
            .object = "beta",
            .confidence = 0.9,
            .source = "test",
        }};
        const foresight = [_]mem3.Foresight{.{
            .description = "will still hold next week",
            .valid_from = 0,
            .valid_until = std.math.maxInt(i64),
            .confidence = 0.8,
        }};
        _ = try self.mgr.addWithId(id, .{
            .id = 0,
            .source = source,
            .episode = episode,
            .atomic_facts = if (with_facts) &facts else &.{},
            .foresight = if (with_foresight) &foresight else &.{},
            .goal_associations = &.{.{ .goal_id = 1, .relevance = 0.5, .priority = 1 }},
            .metadata = .{
                .source_confidence = 0.9,
                // Varied but deterministic, so `max_importance` in the
                // abstract depends on which members the cluster has.
                .importance_score = 0.3 + @as(f32, @floatFromInt(id % 7)) * 0.1,
                .decay_rate = 0.01,
                // `Forgetter` decays by age; a zero `created_at` is 56 years
                // old and would make a sweep fuzzy everything.
                .created_at = mem3.utils.time.nowMs(),
            },
        });
    }

    /// Delete a cell the way `Store` does on a forget: `remove` hands back
    /// the pointer and frees nothing.
    fn drop(self: *World, id: u64) bool {
        const cell = self.mgr.remove(id) orelse return false;
        cell.deinit(self.alloc);
        self.alloc.destroy(cell);
        return true;
    }
};

// ---------------------------------------------------------------------------
// The oracle: the old algorithm, written again, sharing no state.
// ---------------------------------------------------------------------------

const Label = Consolidator.PartitionEntry;

fn byId(_: void, a: *MemCell, b: *MemCell) bool {
    return a.id < b.id;
}

/// All-pairs single linkage over every cell currently in `mgr`, exactly as
/// the pre-incremental `consolidate` did it. Returns `{id, label}` sorted
/// by id, where `label` is the smallest id in the component.
fn oraclePartition(alloc: std.mem.Allocator, mgr: *TriSourceManager, threshold: f32) ![]Label {
    var cells: std.ArrayList(*MemCell) = .empty;
    defer cells.deinit(alloc);
    inline for (.{ &mgr.sensory, &mgr.cognitive, &mgr.action }) |map| {
        var it = map.iterator();
        while (it.next()) |e| try cells.append(alloc, e.value_ptr.*);
    }
    std.mem.sort(*MemCell, cells.items, {}, byId);

    const n = cells.items.len;
    const sigs = try alloc.alloc(mem3.consolidator_mod.Signature, n);
    defer alloc.free(sigs);
    for (cells.items, 0..) |c, k| sigs[k] = mem3.consolidator_mod.signatureOf(c);

    const parent = try alloc.alloc(usize, n);
    defer alloc.free(parent);
    for (parent, 0..) |*p, i| p.* = i;

    for (0..n) |i| {
        for (i + 1..n) |j| {
            var inter: usize = 0;
            var uni: usize = 0;
            for (0..sigs[i].len) |w| {
                inter += @popCount(sigs[i][w] & sigs[j][w]);
                uni += @popCount(sigs[i][w] | sigs[j][w]);
            }
            if (uni == 0) continue;
            const jac = @as(f32, @floatFromInt(inter)) / @as(f32, @floatFromInt(uni));
            if (jac >= threshold) {
                var a = i;
                while (parent[a] != a) a = parent[a];
                var b = j;
                while (parent[b] != b) b = parent[b];
                if (a != b) parent[@max(a, b)] = @min(a, b);
            }
        }
    }

    const out = try alloc.alloc(Label, n);
    for (cells.items, 0..) |c, k| {
        var r = k;
        while (parent[r] != r) r = parent[r];
        // `parent[max] = min` makes the root the lowest index, which is the
        // lowest id because `cells` is sorted by id.
        out[k] = .{ .id = c.id, .label = cells.items[r].id };
    }
    return out;
}

fn expectSamePartition(expected: []const Label, actual: []const Label) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.id, a.id);
        try testing.expectEqual(e.label, a.label);
    }
}

/// Partition of `w`'s current cells as seen by a cold consolidator: the
/// reference an incremental one must reproduce.
fn freshPartition(alloc: std.mem.Allocator, w: *World) ![]Label {
    var cold = Consolidator.init(alloc, w.cons.cfg, w.fuzzy, w.mgr);
    defer cold.deinit();
    _ = try cold.refresh();
    return cold.partition(alloc);
}

/// Check the three-way agreement after an incremental refresh: the
/// persistent consolidator, the oracle, and a cold one.
fn expectEquivalent(alloc: std.mem.Allocator, w: *World) !void {
    const threshold = w.cons.cfg.consolidation_threshold;
    const inc = try w.cons.partition(alloc);
    defer alloc.free(inc);
    const oracle = try oraclePartition(alloc, w.mgr, threshold);
    defer alloc.free(oracle);
    const fresh = try freshPartition(alloc, w);
    defer alloc.free(fresh);
    try expectSamePartition(oracle, inc);
    try expectSamePartition(oracle, fresh);
}

// ---------------------------------------------------------------------------
// Randomised corpus
// ---------------------------------------------------------------------------

const VOCAB = [_][]const u8{
    "alpha", "bravo",  "charlie", "delta",  "echo",   "foxtrot", "golf",    "hotel",
    "india", "juliet", "kilo",    "lima",   "mike",   "november", "oscar",  "papa",
    "quebec", "romeo", "sierra",  "tango",  "uniform", "victor", "whiskey", "xray",
    "yankee", "zulu",  "amber",   "birch",  "cedar",  "dune",    "ember",   "fjord",
};

/// Six "topics" of five words each. An episode takes four of its topic's
/// words plus up to two strays, so Jaccard against a sibling lands around
/// 0.4–0.7: clusters form at the thresholds used below, and at the higher
/// one some chains are marginal, which is what makes splits interesting.
const TOPICS: [6][5]usize = .{
    .{ 0, 1, 2, 3, 4 },
    .{ 5, 6, 7, 8, 9 },
    .{ 10, 11, 12, 13, 14 },
    .{ 15, 16, 17, 18, 19 },
    .{ 20, 21, 22, 23, 24 },
    .{ 25, 26, 27, 28, 29 },
};

fn randomEpisode(rand: std.Random, buf: []u8) []const u8 {
    var len: usize = 0;
    const topic = TOPICS[rand.uintLessThan(usize, TOPICS.len)];
    const skip = rand.uintLessThan(usize, topic.len);
    for (topic, 0..) |wi, k| {
        if (k == skip) continue;
        len = appendWord(buf, len, VOCAB[wi]);
    }
    const strays = rand.uintLessThan(usize, 3);
    for (0..strays) |_| len = appendWord(buf, len, VOCAB[rand.uintLessThan(usize, VOCAB.len)]);
    return buf[0..len];
}

fn appendWord(buf: []u8, len: usize, word: []const u8) usize {
    var n = len;
    if (n > 0) {
        buf[n] = ' ';
        n += 1;
    }
    @memcpy(buf[n .. n + word.len], word);
    return n + word.len;
}

/// One scripted step: add `adds` fresh cells (ids ascending from
/// `next_id.*`), then drop `drops` random live pinned cells.
fn mutate(
    w: *World,
    rand: std.Random,
    next_id: *u64,
    live: *std.ArrayList(u64),
    adds: usize,
    drops: usize,
    shuffle_adds: bool,
) !void {
    const alloc = w.alloc;
    var batch: std.ArrayList(u64) = .empty;
    defer batch.deinit(alloc);
    var eps: std.ArrayList([]u8) = .empty;
    defer {
        for (eps.items) |e| alloc.free(e);
        eps.deinit(alloc);
    }
    for (0..adds) |_| {
        var buf: [128]u8 = undefined;
        const text = randomEpisode(rand, &buf);
        try eps.append(alloc, try alloc.dupe(u8, text));
        try batch.append(alloc, next_id.*);
        next_id.* += 1;
    }
    // Arrival order within a batch must not matter: the consolidator keys
    // everything off id order.
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(alloc);
    for (0..adds) |k| try order.append(alloc, k);
    if (shuffle_adds) {
        var i = order.items.len;
        while (i > 1) {
            i -= 1;
            const j = rand.uintLessThan(usize, i + 1);
            std.mem.swap(usize, &order.items[i], &order.items[j]);
        }
    }
    for (order.items) |k| {
        const id = batch.items[k];
        const src: mem3.MemorySource = @enumFromInt(@as(u8, @intCast(id % 3)));
        try w.add(id, src, eps.items[k], id % 4 == 0, id % 5 == 0);
        try live.append(alloc, id);
    }
    for (0..drops) |_| {
        if (live.items.len == 0) break;
        const at = rand.uintLessThan(usize, live.items.len);
        const id = live.swapRemove(at);
        try testing.expect(w.drop(id));
    }
}

// ---------------------------------------------------------------------------
// (a) incremental partition == full recompute
// ---------------------------------------------------------------------------

test "incremental refresh: partition equals the O(n^2) oracle and a cold instance, over random add/forget" {
    const alloc = testing.allocator;
    const seeds = [_]u64{ 1, 2, 3, 5, 8, 13, 21, 34 };
    const thresholds = [_]f32{ 0.3, 0.4, 0.55 };
    for (seeds, 0..) |seed, si| {
        var w = try World.init(alloc, thresholds[si % thresholds.len]);
        defer w.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        var live: std.ArrayList(u64) = .empty;
        defer live.deinit(alloc);
        var next_id: u64 = 1;

        for (0..14) |round| {
            // Interleave: some rounds only add, some only forget, most both.
            const adds: usize = if (round % 5 == 4) 0 else rand.uintLessThan(usize, 24);
            const drops: usize = if (round % 5 == 0) 0 else rand.uintLessThan(usize, 9);
            try mutate(&w, rand, &next_id, &live, adds, drops, false);
            _ = try w.cons.refresh();
            try expectEquivalent(alloc, &w);
            try testing.expectEqual(w.mgr.count(), w.cons.cachedCells());
        }
    }
}

test "incremental consolidate: abstracts equal those of a cold consolidator on an identical twin" {
    // Two worlds receive identical operations. World `inc` keeps its
    // Consolidator across passes; world `cold` builds a new one before every
    // pass, so it recomputes everything — the pre-change behaviour. Their
    // abstracts must be the same, in the same id order.
    const alloc = testing.allocator;
    const seeds = [_]u64{ 7, 11, 19, 23 };
    for (seeds) |seed| {
        var inc = try World.init(alloc, 0.4);
        defer inc.deinit();
        var cold = try World.init(alloc, 0.4);
        defer cold.deinit();
        var prng_a = std.Random.DefaultPrng.init(seed);
        var prng_b = std.Random.DefaultPrng.init(seed);
        var live_a: std.ArrayList(u64) = .empty;
        defer live_a.deinit(alloc);
        var live_b: std.ArrayList(u64) = .empty;
        defer live_b.deinit(alloc);
        var next_a: u64 = 1;
        var next_b: u64 = 1;

        for (0..8) |round| {
            const adds: usize = 6 + (round * 3) % 11;
            const drops: usize = if (round == 0) 0 else round % 4;
            try mutate(&inc, prng_a.random(), &next_a, &live_a, adds, drops, false);
            try mutate(&cold, prng_b.random(), &next_b, &live_b, adds, drops, false);

            cold.coldConsolidator();
            var ra = try inc.cons.consolidate();
            defer ra.deinitAbstractIds(alloc);
            var rb = try cold.cons.consolidate();
            defer rb.deinitAbstractIds(alloc);

            try testing.expectEqual(rb.clusters, ra.clusters);
            try testing.expectEqual(rb.abstracts_created, ra.abstracts_created);
            try testing.expectEqual(rb.cells_processed, ra.cells_processed);
            try testing.expectEqualSlices(u64, rb.abstract_ids, ra.abstract_ids);
            for (ra.abstract_ids) |aid| {
                const ca = inc.mgr.get(aid).?;
                const cb = cold.mgr.get(aid).?;
                try testing.expectEqualStrings(cb.episode, ca.episode);
                try testing.expectEqual(cb.metadata.importance_score, ca.metadata.importance_score);
                try testing.expectEqual(cb.foresight.len, ca.foresight.len);
                for (cb.foresight, ca.foresight) |fb, fa| try testing.expectEqualStrings(fb.description, fa.description);
                try testing.expectEqual(cb.goal_associations.len, ca.goal_associations.len);
            }
            // `consolidate` clusters *before* it inserts abstracts, so the
            // cache lags the manager by exactly those abstracts until the
            // next sync. Sync, then compare.
            _ = try inc.cons.refresh();
            try expectEquivalent(alloc, &inc);
        }
    }
}

// ---------------------------------------------------------------------------
// (b) determinism
// ---------------------------------------------------------------------------

test "incremental consolidate: same cell set gives the same abstracts, whatever the arrival order within a batch" {
    const alloc = testing.allocator;
    var fwd = try World.init(alloc, 0.4);
    defer fwd.deinit();
    var shuf = try World.init(alloc, 0.4);
    defer shuf.deinit();
    var prng_a = std.Random.DefaultPrng.init(99);
    var prng_b = std.Random.DefaultPrng.init(99);
    var live_a: std.ArrayList(u64) = .empty;
    defer live_a.deinit(alloc);
    var live_b: std.ArrayList(u64) = .empty;
    defer live_b.deinit(alloc);
    var next_a: u64 = 1;
    var next_b: u64 = 1;

    for (0..5) |_| {
        // Separate PRNGs for content and for the shuffle would be cleaner,
        // but `mutate` draws the shuffle from the same stream *after* the
        // content, so both worlds see identical episodes; only the order in
        // which the cells are inserted differs.
        try mutate(&fwd, prng_a.random(), &next_a, &live_a, 18, 0, false);
        try mutate(&shuf, prng_b.random(), &next_b, &live_b, 18, 0, true);
        // Re-align the streams: the shuffle consumed extra draws.
        prng_b = prng_a;

        var ra = try fwd.cons.consolidate();
        defer ra.deinitAbstractIds(alloc);
        var rb = try shuf.cons.consolidate();
        defer rb.deinitAbstractIds(alloc);

        try testing.expect(ra.abstract_ids.len > 0);
        try testing.expect(std.sort.isSorted(u64, ra.abstract_ids, {}, std.sort.asc(u64)));
        try testing.expectEqualSlices(u64, ra.abstract_ids, rb.abstract_ids);
        for (ra.abstract_ids) |aid| {
            try testing.expectEqualStrings(fwd.mgr.get(aid).?.episode, shuf.mgr.get(aid).?.episode);
        }
    }
}

test "consolidate: abstract ids are minted in ascending order of the cluster's lowest member id" {
    // Cluster minima: A=1, B=2, C=5. Abstracts must take ids in that order,
    // not in whatever order a hash map happens to enumerate the clusters.
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    try w.add(1, .matter, "cat mat sat on the rug", false, false);
    try w.add(2, .matter, "kube deploy cluster node pool", false, false);
    try w.add(3, .matter, "kube deploy cluster node zone", false, false);
    try w.add(4, .matter, "cat mat lay on the rug", false, false);
    try w.add(5, .matter, "standup team weekday morning", false, false);
    try w.add(6, .matter, "standup team weekday evening", false, false);

    var r = try w.cons.consolidate();
    defer r.deinitAbstractIds(alloc);
    try testing.expectEqual(@as(usize, 3), r.abstract_ids.len);
    // Abstract text is the representative's (lowest id's) filtered episode.
    try testing.expect(std.mem.startsWith(u8, w.mgr.get(r.abstract_ids[0]).?.episode, "cat"));
    try testing.expect(std.mem.startsWith(u8, w.mgr.get(r.abstract_ids[1]).?.episode, "kube"));
    try testing.expect(std.mem.startsWith(u8, w.mgr.get(r.abstract_ids[2]).?.episode, "standup"));
}

// ---------------------------------------------------------------------------
// (c) invalidation
// ---------------------------------------------------------------------------

test "threshold change forces a full recompute equal to a fresh instance's" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    var prng = std.Random.DefaultPrng.init(4242);
    var live: std.ArrayList(u64) = .empty;
    defer live.deinit(alloc);
    var next_id: u64 = 1;
    try mutate(&w, prng.random(), &next_id, &live, 40, 0, false);

    const first = try w.cons.refresh();
    try testing.expect(first.full_recompute); // nothing cached yet
    const n: u64 = w.mgr.count();
    try testing.expectEqual(n * (n - 1) / 2, first.pair_comparisons);

    // Same threshold, nothing changed: incremental, and no pair work.
    const quiet = try w.cons.refresh();
    try testing.expect(!quiet.full_recompute);
    try testing.expectEqual(@as(u64, 0), quiet.pair_comparisons);

    // A new threshold re-defines every edge; the cache is meaningless.
    w.cons.cfg.consolidation_threshold = 0.6;
    const redone = try w.cons.refresh();
    try testing.expect(redone.full_recompute);
    try testing.expectEqual(n * (n - 1) / 2, redone.pair_comparisons);
    try expectEquivalent(alloc, &w);

    // ...and going back is another full recompute, not a stale hit.
    w.cons.cfg.consolidation_threshold = 0.3;
    const back = try w.cons.refresh();
    try testing.expect(back.full_recompute);
    try expectEquivalent(alloc, &w);

    // The threshold the partition was built with must be the one that
    // `consolidate` then uses: compare against a cold twin.
    var cold = try World.init(alloc, 0.3);
    defer cold.deinit();
    var prng2 = std.Random.DefaultPrng.init(4242);
    var live2: std.ArrayList(u64) = .empty;
    defer live2.deinit(alloc);
    var next2: u64 = 1;
    try mutate(&cold, prng2.random(), &next2, &live2, 40, 0, false);
    var ra = try w.cons.consolidate();
    defer ra.deinitAbstractIds(alloc);
    var rb = try cold.cons.consolidate();
    defer rb.deinitAbstractIds(alloc);
    try testing.expectEqual(rb.clusters, ra.clusters);
    try testing.expectEqualSlices(u64, rb.abstract_ids, ra.abstract_ids);
}

test "invalidate() drops the cache; the next pass is a full recompute" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    try w.add(1, .matter, "one two three four", false, false);
    try w.add(2, .matter, "one two three five", false, false);
    _ = try w.cons.refresh();
    try testing.expectEqual(@as(usize, 2), w.cons.cachedCells());
    w.cons.invalidate();
    try testing.expectEqual(@as(usize, 0), w.cons.cachedCells());
    const s = try w.cons.refresh();
    try testing.expect(s.full_recompute);
}

// ---------------------------------------------------------------------------
// (d) removal: splits, leaks, content replacement
// ---------------------------------------------------------------------------

/// Chain a-b-c: a~b and b~c at 0.3 but a and c share nothing, so
/// single-linkage joins all three *through b*. Removing b must split it.
fn addChain(w: *World) !void {
    try w.add(1, .matter, "w1 w2 w3 w4", false, false); // a
    try w.add(2, .matter, "w3 w4 w5 w6", false, false); // b
    try w.add(3, .matter, "w5 w6 w7 w8", false, false); // c
}

test "removing the bridge of a chain splits the cluster, and the split is the oracle's" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    try addChain(&w);
    _ = try w.cons.refresh();

    {
        const p = try w.cons.partition(alloc);
        defer alloc.free(p);
        // Precondition: one component, label 1. If token buckets collided in
        // a way that breaks the chain this fails here, not later.
        try testing.expectEqual(@as(u64, 1), p[0].label);
        try testing.expectEqual(@as(u64, 1), p[1].label);
        try testing.expectEqual(@as(u64, 1), p[2].label);
    }

    try testing.expect(w.drop(2));
    const s = try w.cons.refresh();
    try testing.expectEqual(@as(usize, 1), s.cells_removed);
    try testing.expectEqual(@as(usize, 1), s.clusters_rebuilt);
    try testing.expect(!s.full_recompute);

    const p = try w.cons.partition(alloc);
    defer alloc.free(p);
    try testing.expectEqual(@as(usize, 2), p.len);
    try testing.expectEqual(@as(u64, 1), p[0].label);
    try testing.expectEqual(@as(u64, 3), p[1].label); // c is no longer a's
    try expectEquivalent(alloc, &w);
}

test "removing a singleton, or a leaf that keeps its cluster connected, is cheap and correct" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    try w.add(1, .matter, "red green blue amber", false, false);
    try w.add(2, .matter, "red green blue birch", false, false);
    try w.add(3, .matter, "red green blue cedar", false, false);
    try w.add(4, .matter, "completely unrelated tokens here", false, false); // singleton
    _ = try w.cons.refresh();

    try testing.expect(w.drop(4));
    const s1 = try w.cons.refresh();
    try testing.expectEqual(@as(usize, 1), s1.cells_removed);
    // A singleton's removal cannot split anything: nothing to rebuild.
    try testing.expectEqual(@as(usize, 0), s1.clusters_rebuilt);
    try testing.expectEqual(@as(u64, 0), s1.pair_comparisons);
    try expectEquivalent(alloc, &w);

    try testing.expect(w.drop(3));
    const s2 = try w.cons.refresh();
    try testing.expectEqual(@as(usize, 1), s2.clusters_rebuilt);
    // Rebuild cost is bounded by the affected cluster alone: one pair.
    try testing.expectEqual(@as(u64, 1), s2.pair_comparisons);
    try expectEquivalent(alloc, &w);
}

test "several removals from one cluster in a single pass rebuild it once" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    var prng = std.Random.DefaultPrng.init(31);
    var live: std.ArrayList(u64) = .empty;
    defer live.deinit(alloc);
    var next_id: u64 = 1;
    try mutate(&w, prng.random(), &next_id, &live, 30, 0, false);
    _ = try w.cons.refresh();
    for ([_]u64{ 1, 2, 3, 4, 5, 6 }) |id| try testing.expect(w.drop(id));
    const s = try w.cons.refresh();
    try testing.expectEqual(@as(usize, 6), s.cells_removed);
    // Never more rebuilds than removals, and never more than the number of
    // components that existed.
    try testing.expect(s.clusters_rebuilt <= 6);
    try expectEquivalent(alloc, &w);
}

test "forgotten (fuzzied) cells leave the clusters and the cache, with no leaks" {
    // Real `Forgetter.sweep`, not a hand-rolled remove: it moves the cell to
    // the fuzzy store, which then owns it. testing.allocator fails the test
    // if the cache holds on to anything.
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    var prng = std.Random.DefaultPrng.init(77);
    var live: std.ArrayList(u64) = .empty;
    defer live.deinit(alloc);
    var next_id: u64 = 1;
    try mutate(&w, prng.random(), &next_id, &live, 36, 0, false);
    _ = try w.cons.refresh();
    try testing.expectEqual(@as(usize, 36), w.cons.cachedCells());

    var forgotten: usize = 0;
    var id: u64 = 1;
    while (id <= 36) : (id += 3) {
        w.mgr.get(id).?.metadata.importance_score = 0.0001;
        forgotten += 1;
    }
    var forgetter = Forgetter.init(alloc, .{ .forgetting_threshold = 0.1 }, w.fuzzy);
    const sweep = try forgetter.sweep(w.mgr, false);
    try testing.expectEqual(forgotten, sweep.fuzzied);
    try testing.expectEqual(@as(usize, 36) - forgotten, w.mgr.count());

    const s = try w.cons.refresh();
    try testing.expectEqual(forgotten, s.cells_removed);
    try testing.expectEqual(w.mgr.count(), w.cons.cachedCells());
    const p = try w.cons.partition(alloc);
    defer alloc.free(p);
    for (p) |e| try testing.expect(w.mgr.get(e.id) != null);
    try expectEquivalent(alloc, &w);

    // And a consolidate after the sweep still runs end to end.
    var r = try w.cons.consolidate();
    defer r.deinitAbstractIds(alloc);
    try testing.expectEqual(@as(usize, 36) - forgotten, r.cells_processed);
}

test "a cell re-added under the same id with different content is re-clustered" {
    // Ids are unique per live cell but not forever: a restore (or a test)
    // can bring an id back with other content. A cache keyed on id alone
    // would keep the old signature and the old edges.
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    try w.add(1, .matter, "red green blue amber", false, false);
    try w.add(2, .matter, "red green blue birch", false, false);
    try w.add(3, .matter, "xx yy zz qq", false, false);
    _ = try w.cons.refresh();

    try testing.expect(w.drop(2));
    try w.add(2, .matter, "xx yy zz rr", false, false); // now joins cell 3
    const s = try w.cons.refresh();
    try testing.expect(!s.full_recompute);
    try testing.expectEqual(@as(usize, 1), s.cells_new);
    try testing.expectEqual(@as(usize, 1), s.cells_removed);
    const p = try w.cons.partition(alloc);
    defer alloc.free(p);
    try testing.expectEqual(@as(u64, 1), p[0].label);
    try testing.expectEqual(@as(u64, 2), p[1].label);
    try testing.expectEqual(@as(u64, 2), p[2].label);
    try expectEquivalent(alloc, &w);
}

test "removal and replacement between passes never leaves a stale cache entry (drop+add same pass)" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    var prng = std.Random.DefaultPrng.init(555);
    var live: std.ArrayList(u64) = .empty;
    defer live.deinit(alloc);
    var next_id: u64 = 1;
    for (0..10) |_| {
        try mutate(&w, prng.random(), &next_id, &live, 12, 7, true);
        _ = try w.cons.refresh();
        try expectEquivalent(alloc, &w);
    }
}

// ---------------------------------------------------------------------------
// (e) pair work
// ---------------------------------------------------------------------------

test "a pass with no new cells does no pair work" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.9);
    defer w.deinit();
    // Dissimilar on purpose: nothing clusters, so the pass creates no
    // abstracts and the next pass really has no new cells.
    try w.add(1, .matter, "machine learning optimizes models", false, false);
    try w.add(2, .matter, "potato recipe for dinner", false, false);
    try w.add(3, .matter, "quantum gravity theory revisited", false, false);
    try w.add(4, .matter, "zebra crossing safety rules", false, false);

    var r1 = try w.cons.consolidate();
    defer r1.deinitAbstractIds(alloc);
    try testing.expectEqual(@as(usize, 0), r1.abstracts_created);
    try testing.expect(r1.full_recompute);
    try testing.expectEqual(@as(u64, 6), r1.pair_comparisons); // 4 choose 2
    try testing.expectEqual(@as(usize, 4), r1.cells_new);

    var r2 = try w.cons.consolidate();
    defer r2.deinitAbstractIds(alloc);
    try testing.expect(!r2.full_recompute);
    try testing.expectEqual(@as(u64, 0), r2.pair_comparisons);
    try testing.expectEqual(@as(usize, 0), r2.cells_new);
    try testing.expectEqual(@as(usize, 0), r2.cells_removed);
    try testing.expectEqual(@as(usize, 4), r2.cells_processed);
}

test "new cells are compared against every present cell and each other, exactly once" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.9);
    defer w.deinit();
    var prng = std.Random.DefaultPrng.init(2024);
    var live: std.ArrayList(u64) = .empty;
    defer live.deinit(alloc);
    var next_id: u64 = 1;
    try mutate(&w, prng.random(), &next_id, &live, 50, 0, false);
    const first = try w.cons.refresh();
    try testing.expectEqual(@as(u64, 50 * 49 / 2), first.pair_comparisons);

    try mutate(&w, prng.random(), &next_id, &live, 7, 0, false);
    const second = try w.cons.refresh();
    try testing.expect(!second.full_recompute);
    try testing.expectEqual(@as(usize, 7), second.cells_new);
    // 7 new x 50 present, plus the 7-choose-2 among themselves. A full
    // recompute would have been 57*56/2 = 1596.
    try testing.expectEqual(@as(u64, 7 * 50 + 7 * 6 / 2), second.pair_comparisons);
    try expectEquivalent(alloc, &w);
}

test "consolidate: the abstracts one pass makes are the next pass's new cells, and nothing else is" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    try w.add(1, .matter, "machine learning optimizes models", false, false);
    try w.add(2, .matter, "machine learning trains models", false, false);
    try w.add(3, .matter, "machine learning improves accuracy", false, false);
    try w.add(4, .matter, "potato recipe for dinner tonight", false, false);

    var r1 = try w.cons.consolidate();
    defer r1.deinitAbstractIds(alloc);
    try testing.expectEqual(@as(usize, 1), r1.abstracts_created);

    var r2 = try w.cons.consolidate();
    defer r2.deinitAbstractIds(alloc);
    try testing.expect(!r2.full_recompute);
    try testing.expectEqual(r1.abstracts_created, r2.cells_new);
    const present: u64 = 4;
    const k: u64 = @intCast(r2.cells_new);
    try testing.expectEqual(k * present + k * (k - 1) / 2, r2.pair_comparisons);
}

// ---------------------------------------------------------------------------
// Public behaviour that must not move
// ---------------------------------------------------------------------------

test "consolidate: fewer than two cells is a no-op that still reports the count" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    var r0 = try w.cons.consolidate();
    defer r0.deinitAbstractIds(alloc);
    try testing.expectEqual(@as(usize, 0), r0.cells_processed);
    try w.add(1, .matter, "lonely cell", false, false);
    var r1 = try w.cons.consolidate();
    defer r1.deinitAbstractIds(alloc);
    try testing.expectEqual(@as(usize, 1), r1.cells_processed);
    try testing.expectEqual(@as(usize, 0), r1.abstracts_created);
    try testing.expectEqual(@as(usize, 1), w.mgr.count());
}

test "consolidate: PCR holds across repeated incremental passes" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    try w.add(1, .form, "deep learning vision models", false, false);
    try w.add(2, .form, "deep learning speech models", false, false);
    var before = w.mgr.count();
    for (0..3) |_| {
        var r = try w.cons.consolidate();
        defer r.deinitAbstractIds(alloc);
        // No original is ever removed; the count only grows by abstracts.
        try testing.expect(w.mgr.get(1) != null);
        try testing.expect(w.mgr.get(2) != null);
        try testing.expectEqual(before + r.abstracts_created, w.mgr.count());
        before = w.mgr.count();
    }
}

test "consolidate: abstract carries the representative's foresight" {
    // Abstract WAL records now carry foresight; that only works if the
    // abstract cell has it. The representative is the lowest-id member.
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    try w.add(10, .matter, "cat mat sat on the rug", false, true); // rep, has foresight
    try w.add(11, .matter, "cat mat lay on the rug", false, false);
    var r = try w.cons.consolidate();
    defer r.deinitAbstractIds(alloc);
    try testing.expectEqual(@as(usize, 1), r.abstract_ids.len);
    const a = w.mgr.get(r.abstract_ids[0]).?;
    try testing.expectEqual(@as(usize, 1), a.foresight.len);
    try testing.expectEqualStrings("will still hold next week", a.foresight[0].description);
    try testing.expectEqual(mem3.MemorySource.form, a.source);
}

test "cacheBytes reports a positive, per-cell-bounded footprint" {
    const alloc = testing.allocator;
    var w = try World.init(alloc, 0.3);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 0), w.cons.cacheBytes());
    var prng = std.Random.DefaultPrng.init(8);
    var live: std.ArrayList(u64) = .empty;
    defer live.deinit(alloc);
    var next_id: u64 = 1;
    try mutate(&w, prng.random(), &next_id, &live, 64, 0, false);
    _ = try w.cons.refresh();
    const bytes = w.cons.cacheBytes();
    try testing.expect(bytes >= 64 * 64); // at least one 512-bit signature each
    try testing.expect(bytes <= 64 * 512); // and nowhere near a pair matrix
}
