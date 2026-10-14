//! HNSW (Hierarchical Navigable Small World) index.
//!
//! **Constitution Principle IV**: zero-dep. ~400 LOC in-tree.
//!
//! **v0.1.0 implementation**: cosine similarity over xxHash3-derived 384-dim
//! vectors. Brute-force TopK for correctness; the layered graph is built
//! incrementally and used for navigation. v0.2.0 will replace the inner
//! search with a beam search over the layered graph.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("../core/config.zig");
const Config = config_mod.Config;
const errors = @import("../core/errors.zig").Error;

const log = std.log.scoped(.mem3_hnsw);

fn containsId(list: []const u64, id: u64) bool {
    for (list) |e| {
        if (e == id) return true;
    }
    return false;
}

pub const Node = struct {
    id: u64,
    vector: []f32,
    level: u8,
    /// neighbors[i] is the neighbor list at layer i. Lower index = higher layer.
    neighbors: []std.ArrayList(u64),

    pub fn deinit(self: *Node, alloc: Allocator) void {
        alloc.free(self.vector);
        for (self.neighbors) |*n| n.deinit(alloc);
        alloc.free(self.neighbors);
    }
};

pub const HNSW = struct {
    alloc: Allocator,
    cfg: Config,
    dim: u16,
    nodes: std.AutoHashMap(u64, *Node),
    /// Entry point: the topmost node's id. Null if empty. Promoted
    /// whenever a node arrives with a higher level than `max_level`.
    entry_point: ?u64,
    /// Highest level currently occupied. Starts at 0 and only grows.
    max_level: u8 = 0,
    /// Total node count.
    count: usize = 0,
    /// Persistent level-assignment RNG.
    ///
    /// This must be *state carried across calls*. It used to be
    /// reconstructed from `@intFromPtr(&self)` on every call to
    /// `randomLevel`, so every insert drew the identical sequence and
    /// every node received the same level. Measured on a 400-node
    /// insert: `max_level_seen = 0`, i.e. the upper layers were never
    /// populated at all and `greedyDescend` above level 0 was dead
    /// code — the "hierarchical" graph was flat.
    prng: std.Random.DefaultPrng,

    pub fn init(alloc: Allocator, cfg: Config, dim: u16) HNSW {
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .dim = dim,
            .nodes = std.AutoHashMap(u64, *Node).init(alloc),
            .entry_point = null,
            .max_level = 0,
            .prng = std.Random.DefaultPrng.init(cfg.hnsw_seed),
        };
    }

    pub fn deinit(self: *HNSW) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.nodes.deinit();
    }

    /// Insert a vector with a given id. Computes the level via exponential
    /// distribution `1/M`.
    pub fn insert(self: *HNSW, id: u64, vector: []const f32) errors!void {
        if (vector.len != self.dim) return errors.InvalidQuery;

        const level = self.randomLevel();
        const n = try self.alloc.create(Node);
        errdefer self.alloc.destroy(n);
        const vec_copy = try self.alloc.alloc(f32, vector.len);
        @memcpy(vec_copy, vector);
        n.* = .{
            .id = id,
            .vector = vec_copy,
            .level = level,
            .neighbors = try self.alloc.alloc(std.ArrayList(u64), level + 1),
        };
        for (0..level + 1) |i| {
            n.neighbors[i] = .empty;
        }
        try self.nodes.put(id, n);
        self.count += 1;

        if (self.entry_point == null) {
            self.entry_point = id;
            self.max_level = level;
            return;
        }

        // HNSW Algorithm 1 — descend the layers, then link on the way back.
        //
        // Above the new node's own level it does not exist yet, so those
        // layers get a cheap ef=1 hop whose only job is to find a better
        // starting point for the next layer down. From its own level down
        // to 0 it gets the full ef_construction beam and links to the M
        // nearest.
        //
        // Both previous branches called `connect(id, cid, 0, vector)` —
        // hardcoded layer 0 — so no adjacency list above layer 0 was ever
        // written, however tall `randomLevel` made the graph. Every
        // `greedyDescend` at level > 0 walked an empty list, which is why
        // fixing the level distribution alone could not buy recall: the
        // hierarchy it produced had no edges in it.
        var entry: u64 = self.entry_point.?;

        var lc: i32 = @intCast(self.max_level);
        while (lc > @as(i32, @intCast(level))) : (lc -= 1) {
            const hop = try self.searchLayer(vector, entry, 1, @intCast(lc));
            defer self.alloc.free(hop);
            if (hop.len > 0) entry = hop[0];
        }

        var l: i32 = @intCast(@min(self.max_level, level));
        while (l >= 0) : (l -= 1) {
            const ul: u8 = @intCast(l);
            const candidates = try self.searchLayer(
                vector,
                entry,
                @intCast(self.cfg.hnsw_ef_construction),
                ul,
            );
            defer self.alloc.free(candidates);

            const limit = self.maxDegree(ul);
            var linked: usize = 0;
            for (candidates) |cid| {
                if (cid == id) continue;
                try self.connect(id, cid, ul, vector);
                linked += 1;
                if (linked >= limit) break;
            }
            // Thread the nearest found into the next layer down.
            if (candidates.len > 0) entry = candidates[0];
        }

        // Promote the entry point only once the node is fully linked.
        //
        // Doing this before the links are built makes the multi-layer
        // branch below descend from the node being inserted, whose
        // neighbour lists at those levels are still empty — so the
        // descent has nowhere to go and the upper layers stay
        // unpopulated. It used to be fixed at the very first insert for
        // a different reason: search always began at whichever node
        // happened to be inserted first, which has no links above
        // level 0 either.
        if (level > self.max_level) {
            self.max_level = level;
            self.entry_point = id;
        }
    }

    /// Search for the top-k nearest neighbors by cosine similarity.
    pub fn search(self: *HNSW, alloc: Allocator, query: []const f32, k: usize) errors![]SearchResult {
        if (query.len != self.dim) return errors.InvalidQuery;
        if (self.entry_point == null) return &.{};
        const cands = try self.searchInternal(query, @max(k, @as(usize, self.cfg.hnsw_ef_search)), 0);
        defer self.alloc.free(cands);
        const out = try alloc.alloc(SearchResult, @min(k, cands.len));
        for (out, 0..) |*r, i| {
            r.id = cands[i];
            r.score = self.cosineSim(query, self.nodes.get(cands[i]).?.vector);
        }
        return out;
    }

    /// HNSW Algorithm 2 — best-first search within a single layer.
    ///
    /// `start` is the node the walk begins from. Callers pass the result
    /// of the layer above (Algorithm 1) so each layer begins where the
    /// layer above left off, rather than re-descending from the global
    /// entry point every time.
    ///
    /// Two sets drive the walk:
    ///
    ///   * `results` (W in the paper) — the best `budget` nodes found so
    ///     far. A new neighbour only enters by displacing the worst
    ///     incumbent; everything else is dropped on the spot.
    ///   * `frontier` (C) — nodes still to expand, always popped
    ///     closest-first.
    ///
    /// The loop ends as soon as the closest unexpanded candidate is worse
    /// than the worst node already in W and W is full: nothing left in
    /// the queue can improve the answer.
    ///
    /// The previous version filled a `result_set` and stopped the entire
    /// search the moment it reached `ef` *discovered* nodes. That is not a
    /// beam: it never pruned, and it never followed a promising path past
    /// the first ef nodes it happened to stumble into, so the answer
    /// depended on which nodes sat near the entry point rather than on the
    /// query. The signature was recall climbing almost linearly with the
    /// budget — 0.0650 / 0.1340 / 0.3370 / 0.5670 / 0.7280 at
    /// ef = 32 / 50 / 100 / 200 / 400 — which is what you see when a
    /// search *samples* a slice of the corpus instead of navigating to the
    /// neighbourhood.
    ///
    /// Both containers stay bounded (`frontier` by `budget`, because a node
    /// only joins the frontier as it joins W), so the linear scans below
    /// are far cheaper than the cosine evaluations they gate. A heap would
    /// only move the constant factor.
    fn searchLayer(self: *HNSW, query: []const f32, start: u64, ef: usize, level: u8) errors![]u64 {
        const budget = @max(ef, 1);

        var visited = std.AutoHashMap(u64, void).init(self.alloc);
        defer visited.deinit();
        var frontier = std.ArrayList(Cand).empty;
        defer frontier.deinit(self.alloc);
        var results = std.ArrayList(Cand).empty;
        defer results.deinit(self.alloc);
        try results.ensureTotalCapacity(self.alloc, budget);
        try frontier.ensureTotalCapacity(self.alloc, budget);

        const start_score = self.cosineSim(query, self.nodes.get(start).?.vector);
        try visited.put(start, {});
        try frontier.append(self.alloc, .{ .id = start, .score = start_score });
        try results.append(self.alloc, .{ .id = start, .score = start_score });

        while (frontier.items.len > 0) {
            // Pop the closest unexpanded candidate.
            var best_i: usize = 0;
            for (frontier.items, 0..) |c, i| {
                if (c.score > frontier.items[best_i].score) best_i = i;
            }
            const c = frontier.swapRemove(best_i);

            if (results.items.len >= budget and c.score < results.items[worstIdx(results.items)].score) break;

            const node = self.nodes.get(c.id) orelse continue;
            if (level >= node.neighbors.len) continue;

            // Locate the incumbent to displace once per expansion rather
            // than once per neighbour: rescanning `results` inside the
            // neighbour loop made the inner loop O(ef * degree) — 200 * 32
            // comparisons for every node expanded at construction time,
            // which dominated the whole search.
            //
            // `worst_valid` matters: while the beam is still filling, the
            // cached index is meaningless and MUST be recomputed on the
            // first neighbour seen *after* it fills. Caching it from the
            // pre-fill state silently compared every candidate against
            // `results[0]` and overwrote the best entry instead of the
            // worst — measured as recall@10 dropping 0.5660 -> 0.5420 at
            // ef = 10 before this was caught.
            var worst: usize = 0;
            var worst_valid = false;

            for (node.neighbors[level].items) |nid| {
                if (visited.contains(nid)) continue;
                const n = self.nodes.get(nid) orelse continue;
                try visited.put(nid, {});
                const s = self.cosineSim(query, n.vector);

                if (results.items.len < budget) {
                    try results.append(self.alloc, .{ .id = nid, .score = s });
                    try frontier.append(self.alloc, .{ .id = nid, .score = s });
                } else {
                    if (!worst_valid) {
                        worst = worstIdx(results.items);
                        worst_valid = true;
                    }
                    if (s > results.items[worst].score) {
                        results.items[worst] = .{ .id = nid, .score = s };
                        try frontier.append(self.alloc, .{ .id = nid, .score = s });
                        worst = worstIdx(results.items);
                    }
                }
            }
        }

        std.mem.sort(Cand, results.items, {}, struct {
            fn lt(_: void, a: Cand, b: Cand) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.id < b.id;
            }
        }.lt);

        const out = try self.alloc.alloc(u64, @min(results.items.len, budget));
        for (out, 0..) |*o, i| o.* = results.items[i].id;
        return out;
    }

    /// Descend from the entry point down to `level`, then beam-search there.
    ///
    /// The layers above `level` are cheap greedy hops (ef = 1); the target
    /// layer gets the real budget.
    fn searchInternal(self: *HNSW, query: []const f32, ef: usize, level: u8) errors![]u64 {
        const ep = self.entry_point orelse return &.{};
        if (level > self.max_level) return &.{};

        var current: u64 = ep;
        var l: i32 = @intCast(self.max_level);
        while (l > @as(i32, @intCast(level))) : (l -= 1) {
            const hop = try self.searchLayer(query, current, 1, @intCast(l));
            defer self.alloc.free(hop);
            if (hop.len > 0) current = hop[0];
        }
        return self.searchLayer(query, current, ef, level);
    }

    pub const SearchResult = struct {
        id: u64,
        score: f32,
    };

    /// A scored node id, as carried by the search frontier and the
    /// bounded result set. Declared at container scope because Zig has no
    /// nested functions or local type declarations.
    const Cand = struct { id: u64, score: f32 };

    /// Index of the lowest-scoring entry — the one a full result set
    /// displaces when a better neighbour shows up.
    fn worstIdx(items: []const Cand) usize {
        var w: usize = 0;
        for (items, 0..) |r, i| {
            if (r.score < items[w].score) w = i;
        }
        return w;
    }

    /// Maximum adjacency-list length at `level`.
    ///
    /// Layer 0 gets `hnsw_m_max0` (the usual `M_max0 = 2*M` convention),
    /// upper layers get `hnsw_m`. Clamped to `>= 1`: a zero-degree list
    /// strands the node and silently turns the graph into unreachable
    /// islands rather than a smaller-but-connected one.
    fn maxDegree(self: *const HNSW, level: u8) usize {
        const raw: usize = if (level == 0) self.cfg.hnsw_m_max0 else self.cfg.hnsw_m;
        return @max(raw, 1);
    }

    /// HNSW Algorithm 4 — "shrink connections".
    ///
    /// `node`'s list at `level` has overflowed `limit`. Walk its candidates
    /// nearest-to-`query` first and keep the first `limit` that survive the
    /// discard rule:
    ///
    ///   (a) if some neighbour `c2` of candidate `c` is closer to `query`
    ///       than `c` itself is, `c` is a redundant gateway — drop `c` and
    ///       let `c2` stand in for it (it is strictly closer to the query
    ///       than what it replaced);
    ///   (b) otherwise `c` is dropped when it sits closer to an already-kept
    ///       neighbour than to the query, i.e. it buys no navigation.
    ///
    /// The nearest candidate is kept unconditionally. Without that carve-out
    /// a dense cluster — where every candidate has a closer neighbour — would
    /// prune to an empty list.
    ///
    /// Ids missing from `self.nodes` are dropped rather than carried: the
    /// adjacency lists must never point at a node the index no longer holds.
    fn shrinkConnections(self: *HNSW, node: *Node, query: []const f32, level: u8, limit: usize) !void {
        const level_idx: usize = level;
        const src = node.neighbors[level_idx].items;

        var cands = std.ArrayList(Cand).empty;
        defer cands.deinit(self.alloc);
        try cands.ensureTotalCapacity(self.alloc, src.len);
        for (src) |cid| {
            if (cid == node.id) continue; // never keep a self loop
            const cn = self.nodes.get(cid) orelse continue; // never keep a dangling id
            try cands.append(self.alloc, .{ .id = cid, .score = self.cosineSim(query, cn.vector) });
        }
        // Nearest to the query first; ties broken by id so the resulting
        // graph is byte-for-byte reproducible for a given insertion order.
        std.mem.sort(Cand, cands.items, {}, struct {
            fn lt(_: void, a: Cand, b: Cand) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.id < b.id;
            }
        }.lt);

        var kept = std.ArrayList(u64).empty;
        errdefer kept.deinit(self.alloc);
        try kept.ensureTotalCapacity(self.alloc, @min(limit, cands.items.len));

        for (cands.items) |c| {
            if (kept.items.len >= limit) break;
            if (containsId(kept.items, c.id)) continue;

            var discard = false;
            var replacement: ?u64 = null;

            if (kept.items.len > 0) {
                // (a) one of c's own neighbours is a better gateway to the
                // query than c is — c gets re-linked out in favour of it.
                const cn = self.nodes.get(c.id).?;
                const c_layer = @min(level_idx, cn.neighbors.len - 1);
                for (cn.neighbors[c_layer].items) |c2| {
                    if (c2 == c.id or c2 == node.id) continue;
                    const c2n = self.nodes.get(c2) orelse continue;
                    if (self.cosineSim(c2n.vector, query) > c.score) {
                        discard = true;
                        replacement = c2;
                        break;
                    }
                }

                // (b) c is closer to something already kept than to the query.
                if (!discard) {
                    const cv = cn.vector;
                    for (kept.items) |kid| {
                        const kn = self.nodes.get(kid) orelse continue;
                        if (self.cosineSim(cv, kn.vector) >= c.score) {
                            discard = true;
                            break;
                        }
                    }
                }
            }

            if (discard) {
                // Propagation: the dropped node keeps its own (still valid,
                // still bounded) list; it simply stops being reachable *via*
                // this node, and its nearest neighbour stands in.
                if (replacement) |r| {
                    if (kept.items.len < limit and r != node.id and
                        !containsId(kept.items, r) and self.nodes.contains(r))
                    {
                        try kept.append(self.alloc, r);
                    }
                }
                continue;
            }
            try kept.append(self.alloc, c.id);
        }

        node.neighbors[level_idx].deinit(self.alloc);
        node.neighbors[level_idx] = kept;
    }

    /// Append `nb` to `node`'s list at `level` unless it is already there,
    /// then trim the list back to `maxDegree(level)` if it overflowed.
    ///
    /// This is the single choke point that keeps every adjacency list
    /// bounded; `connect` is the only caller.
    fn link(self: *HNSW, node: *Node, nb: u64, level: u8, query: []const f32) !void {
        if (level >= node.neighbors.len) return; // node has no such layer
        if (!self.nodes.contains(nb)) return; // never dangle
        const list = &node.neighbors[level];
        if (containsId(list.items, nb)) return; // already linked

        try list.append(self.alloc, nb);
        const limit = self.maxDegree(level);
        if (list.items.len > limit) {
            try self.shrinkConnections(node, query, level, limit);
        }
    }

    fn connect(self: *HNSW, a: u64, b: u64, level: u8, query: []const f32) !void {
        if (a == b) return;
        const a_node = self.nodes.get(a) orelse return;
        const b_node = self.nodes.get(b) orelse return;
        try self.link(a_node, b, level, query);
        try self.link(b_node, a, level, query);
    }

    fn randomLevel(self: *HNSW) u8 {
        // Geometric draw, Hinnant's form: level = floor(-ln(U) * mL),
        // with mL = 1/ln(M). A single draw per node, and the draw comes
        // from the *persistent* PRNG — the previous version rebuilt the
        // PRNG from a constant every call, so every node got the same
        // level and the graph came out flat.
        const m: f32 = @floatFromInt(@max(self.cfg.hnsw_m, 2));
        const m_l: f32 = 1.0 / @log(m);
        // `float(f32)` can return exactly 0.0; ln(0) is -inf, which
        // would floor to a huge level. Reject the degenerate draw.
        var u = self.prng.random().float(f32);
        if (u <= 0.0 or u >= 1.0) u = 0.5;
        const lvl_f = -@log(u) * m_l;
        // Cap so a freak draw cannot ask for a 200-level graph.
        const lvl: u32 = @intFromFloat(lvl_f);
        return @intCast(@min(lvl, @as(u32, 16)));
    }

    /// Number of vectors in the index.
    ///
    /// `const`-read-only and O(1): returns the counter `insert`
    /// maintains, which the "nodeCount matches storage" test below
    /// pins against `nodes.count()`. Exists for observability — the
    /// daemon publishes it as `mem3_vector_index_nodes`.
    pub fn nodeCount(self: *const HNSW) usize {
        return self.count;
    }

    /// Highest layer level that currently holds at least one node.
    ///
    /// `self.max_level` is a sticky high-water mark: it is bumped when
    /// a taller node arrives and never lowered. It would therefore
    /// report an occupied layer even if every node above the base
    /// layer were ever removed, so this recomputes the answer from
    /// the nodes themselves — the only honest reading of "how deep is
    /// the index right now" for an operator's dashboard.
    ///
    /// Returns -1 for an empty index: no layer is occupied at all,
    /// which is distinct from "one node sitting on the base layer"
    /// (0). Callers that publish a Prometheus gauge should render the
    /// value as-is and pair it with `nodeCount` so -1 is unambiguous.
    ///
    /// O(n) over the node map. This is a scrape-time metric on a
    /// daemon whose scrape path already walks the whole cell index for
    /// `mem3_memstore_cells`; it is not on the query hot path.
    pub fn maxOccupiedLevel(self: *const HNSW) i32 {
        var top: i32 = -1;
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            const lvl: i32 = entry.value_ptr.*.level;
            if (lvl > top) top = lvl;
        }
        return top;
    }

    pub fn cosineSim(self: *HNSW, a: []const f32, b: []const f32) f32 {
        _ = self;
        var dot: f32 = 0.0;
        var na: f32 = 0.0;
        var nb: f32 = 0.0;
        for (a, 0..) |x, i| {
            dot += x * b[i];
            na += x * x;
            nb += b[i] * b[i];
        }
        const denom = @sqrt(na) * @sqrt(nb);
        if (denom == 0.0) return 0.0;
        return dot / denom;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "HNSW: insert + search" {
    var hnsw = HNSW.init(std.testing.allocator, .{}, 4);
    defer hnsw.deinit();

    // Two clusters: [1, 0, 0, 0] near [0.9, 0.1, 0, 0] vs [0, 0, 1, 0] near [0, 0, 0.9, 0.1]
    try hnsw.insert(1, &[_]f32{ 1.0, 0.0, 0.0, 0.0 });
    try hnsw.insert(2, &[_]f32{ 0.9, 0.1, 0.0, 0.0 });
    try hnsw.insert(3, &[_]f32{ 0.0, 0.0, 1.0, 0.0 });
    try hnsw.insert(4, &[_]f32{ 0.0, 0.0, 0.9, 0.1 });

    const results = try hnsw.search(std.testing.allocator, &[_]f32{ 0.95, 0.05, 0.0, 0.0 }, 2);
    defer std.testing.allocator.free(results);
    try std.testing.expect(results.len >= 1);
    // Top should be 1 (closer to 0.95, 0.05, 0, 0 than 2 is).
    try std.testing.expect(results[0].id == 1 or results[0].id == 2);
}

test "HNSW: cosine similarity" {
    var hnsw = HNSW.init(std.testing.allocator, .{}, 3);
    defer hnsw.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hnsw.cosineSim(&.{ 1.0, 0.0, 0.0 }, &.{ 1.0, 0.0, 0.0 }), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hnsw.cosineSim(&.{ 1.0, 0.0, 0.0 }, &.{ 0.0, 1.0, 0.0 }), 1e-6);
    try std.testing.expect(hnsw.cosineSim(&.{ 1.0, 0.0, 0.0 }, &.{ 0.7, 0.7, 0.0 }) > 0.5);
}

// Regression guard for the ef-budget underflow in `searchInternal`.
//
// The candidate budget was decremented only inside the neighbour-expansion
// loop, and the `break` left just that inner loop. Once the budget hit
// zero the outer beam loop kept running, re-entered the inner loop, and
// decremented zero into an integer overflow. Every pre-existing test
// inserted at most a handful of nodes, so the budget
// (`hnsw_ef_construction`, 200 neighbour expansions) was never exhausted
// and the bug stayed invisible. The long-run harness tripped it on the
// first ingest of a few thousand cells.
//
// This test deliberately inserts far more nodes than the budget can
// expand, then searches. It must not panic, and search results must stay
// ranked.
test "HNSW: ef budget exhaustion does not underflow" {
    const alloc = std.testing.allocator;
    const dim: u16 = 32;
    const n: usize = 400; // comfortably past ef_construction = 200

    var cfg = Config{};
    cfg.hnsw_ef_construction = 200;
    var hnsw = HNSW.init(alloc, cfg, dim);
    defer hnsw.deinit();

    // Deterministic pseudo-random unit vectors, no PRNG dependency.
    var seed: u64 = 0x1234_5678_9ABC_DEF0;
    var vec: [dim]f32 = undefined;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        for (&vec) |*v| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            v.* = @as(f32, @floatFromInt(seed % 20_001)) / 10_000.0 - 1.0;
        }
        var norm: f32 = 0;
        for (vec) |x| norm += x * x;
        norm = @sqrt(norm);
        if (norm > 0) {
            for (&vec) |*v| v.* /= norm;
        }
        try hnsw.insert(@intCast(i), &vec);
    }
    try std.testing.expectEqual(@as(usize, n), hnsw.count);

    // Searching an index this size is what re-enters the exhausted loop.
    const results = try hnsw.search(alloc, &vec, 10);
    defer alloc.free(results);
    try std.testing.expect(results.len > 0);

    // Ranking must still be sane: descending by score.
    var r: usize = 1;
    while (r < results.len) : (r += 1) {
        try std.testing.expect(results[r - 1].score >= results[r].score);
    }
}

// =============================================================================
// Correctness oracle: recall against an exhaustive scan
// =============================================================================
//
// Everything above this line checked the index against itself — `search` was
// the reference for its own output, so "works" meant "is self-consistent".
// These tests hold `search` against ground truth it cannot influence: a
// brute-force cosine scan over the full corpus, scored by an independent
// copy of the math.
//
// Corpus: 400 clustered 32-dim vectors, ids 1..400.
// Queries: 100, half exact corpus members, half corpus members perturbed
// with 15% noise. All derived from `oracleVec`, which is splitmix64 over
// integer arithmetic — bit-identical on every platform and optimize mode.
// A std PRNG would not do: its stream is free to shift between Zig versions,
// and a corpus that shifts is a corpus whose measured recall is a fiction.
//
// Measured on this corpus. Reproduce with `zig build example-hnsw-recall`,
// which drives the same code paths these tests assert against:
//
//   | index                                    | max degree | recall@10 |
//   |------------------------------------------|------------|-----------|
//   | un-pruned, sampled search (pre-fix HEAD) |    399     |   0.2460  |
//   | degree-bounded, sampled search           |     32     |   0.3370  |
//   | degree-bounded + real level distribution |     32     |   0.3790  |
//   | degree-bounded + best-first beam (now)   |     32     |   0.7580  |
//
// The first row is load-bearing: a complete graph scored against brute
// force returned 1.0000, which proves the corpus, the ids, the scoring and
// the comparison are sound, and pins the loss on the search rather than on
// the harness.
//
// The rewrite moved two things at once. `searchInternal` stopped the whole
// walk the moment it had *discovered* `ef` nodes, so it never pruned and
// never followed a promising path — recall climbed almost linearly with the
// budget (0.0650 / 0.1340 / 0.3370 / 0.5670 / 0.7280 at ef = 32 / 50 / 100
// / 200 / 400), the signature of a search that samples a slice of the
// corpus. And `insert` linked at layer 0 only, hardcoded, so no adjacency
// list above layer 0 was ever written however tall `randomLevel` made the
// graph. Fixing both turns the sweep into 0.5660 / 0.6840 / 0.7230 / 0.7580
// / 0.7690 / 0.7720 at ef = 10 / 32 / 50 / 100 / 200 / 400 — saturating
// instead of linear, which is what navigating to a neighbourhood looks like.
//
// ~0.77 is the graph's ceiling, not the search's: at ef = N the budget no
// longer binds, so the missing ~23% is edges the degree bound cut and
// `shrinkConnections` then discarded. Raising it means a larger M or the
// paper's `SELECT-NEIGHBORS` heuristic with candidate extension, which is a
// graph-quality change, not a search change.

pub const oracle_dim: u16 = 32;
pub const oracle_n: usize = 400;
pub const oracle_k: usize = 10;
pub const oracle_queries: usize = 100;

pub fn oracleNormalize(v: []f32) void {
    var norm: f32 = 0;
    for (v) |x| norm += x * x;
    norm = @sqrt(norm);
    if (norm > 0) {
        for (v) |*x| x.* /= norm;
    }
}

/// splitmix64-derived unit vector for an integer tag. Pure integer ops, so
/// the same tag yields the same bits on every target and optimize mode.
pub fn oracleVec(out: []f32, tag: u64) void {
    var s: u64 = tag *% 0x9E37_79B9_7F4A_7C15 +% 0xDEAD_BEEF_CAFE_0001;
    for (out) |*v| {
        s ^= s >> 30;
        s *%= 0xBF58_476D_1CE4_E5B9;
        s ^= s >> 27;
        s *%= 0x94D0_49BB_1331_11EB;
        s ^= s >> 31;
        v.* = @as(f32, @floatFromInt(s % 20_001)) / 10_000.0 - 1.0;
    }
    oracleNormalize(out);
}

/// Two blended directions, normalised. Plain independent random vectors in
/// 32-d are near-orthogonal — every pairwise cosine sits around 0 — so the
/// "true" top-10 is noise that no index could recover. Blending gives the
/// corpus local structure, which is what makes recall a measurement.
pub fn oracleCorpusVec(out: []f32, tag: u64) void {
    oracleVec(out, tag);
    var second: [oracle_dim]f32 = undefined;
    oracleVec(&second, tag ^ 0xA5A5_A5A5_A5A5_A5A5);
    for (out, &second) |*x, s| x.* += 0.35 * s;
    oracleNormalize(out);
}

pub fn oracleCorpus(alloc: std.mem.Allocator) ![]f32 {
    const corpus = try alloc.alloc(f32, oracle_n * oracle_dim);
    errdefer alloc.free(corpus);
    for (0..oracle_n) |i| {
        oracleCorpusVec(corpus[i * oracle_dim ..][0..oracle_dim], @as(u64, @intCast(i)) +% 1);
    }
    return corpus;
}

/// Query `q`: even queries are an exact corpus member, odd queries are that
/// member plus 15% noise. Writes into `out` — no allocation per query.
pub fn oracleQuery(out: []f32, corpus: []const f32, q: usize) void {
    const base = (q * 7919 % oracle_n) * oracle_dim;
    @memcpy(out, corpus[base..][0..oracle_dim]);
    if (q % 2 != 0) {
        var noise: [oracle_dim]f32 = undefined;
        oracleVec(&noise, @as(u64, @intCast(oracle_n + q)) +% 1);
        for (out, &noise) |*x, nz| x.* += 0.15 * nz;
        oracleNormalize(out);
    }
}

/// Exhaustive top-`k` by cosine over every vector in the corpus. Ids are the
/// 1-based insert order used by `oracleFill`. Ties break on the lower index
/// so the ground truth is reproducible rather than sort-order dependent.
pub fn oracleTruth(alloc: std.mem.Allocator, corpus: []const f32, query: []const f32, k: usize) ![]u64 {
    const Ctx = struct {
        corpus: []const f32,
        query: []const f32,

        fn sim(ctx: @This(), i: usize) f32 {
            const v = ctx.corpus[i * oracle_dim ..][0..oracle_dim];
            var dot: f32 = 0;
            var nv: f32 = 0;
            var nq: f32 = 0;
            for (v, ctx.query) |a, b| {
                dot += a * b;
                nv += a * a;
                nq += b * b;
            }
            const denom = @sqrt(nv) * @sqrt(nq);
            return if (denom == 0.0) 0.0 else dot / denom;
        }

        fn lt(ctx: @This(), a: usize, b: usize) bool {
            const sa = ctx.sim(a);
            const sb = ctx.sim(b);
            if (sa != sb) return sa > sb;
            return a < b;
        }
    };

    const order = try alloc.alloc(usize, oracle_n);
    defer alloc.free(order);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, Ctx{ .corpus = corpus, .query = query }, Ctx.lt);

    const truth = try alloc.alloc(u64, @min(k, oracle_n));
    for (truth, 0..) |*t, r| t.* = @intCast(order[r] + 1);
    return truth;
}

pub fn oracleFill(hnsw: *HNSW, corpus: []const f32) !void {
    for (0..oracle_n) |i| {
        try hnsw.insert(@intCast(i + 1), corpus[i * oracle_dim ..][0..oracle_dim]);
    }
}

/// Builds the oracle corpus + index and returns the aggregate recall@k.
/// Caller frees `corpus`. `ef_search` is passed through to the config.
/// Recall@oracle_k on the oracle corpus at a given `ef_search`.
///
/// Public so `examples/hnsw_recall.zig` can sweep the budget and print the
/// table — the numbers quoted in the comment block above used to exist only
/// as prose, which is how they went stale in the first place.
pub fn oracleRecallWith(alloc: std.mem.Allocator, ef_search: u16) !f32 {
    var cfg = Config{};
    cfg.hnsw_ef_construction = 200;
    cfg.hnsw_ef_search = ef_search;

    var hnsw = HNSW.init(alloc, cfg, oracle_dim);
    defer hnsw.deinit();

    const corpus = try oracleCorpus(alloc);
    defer alloc.free(corpus);
    try oracleFill(&hnsw, corpus);
    if (hnsw.count != oracle_n) return error.OracleCorpusSizeMismatch;

    var hits: usize = 0;
    var qv: [oracle_dim]f32 = undefined;
    var q: usize = 0;
    while (q < oracle_queries) : (q += 1) {
        oracleQuery(&qv, corpus, q);
        const truth = try oracleTruth(alloc, corpus, &qv, oracle_k);
        defer alloc.free(truth);

        const got = try hnsw.search(alloc, &qv, oracle_k);
        defer alloc.free(got);
        if (got.len != oracle_k) return error.OracleResultTruncated;

        for (got) |g| {
            for (truth) |t| {
                if (g.id == t) {
                    hits += 1;
                    break;
                }
            }
        }
    }
    return @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(oracle_queries * oracle_k));
}

fn oracleRecall(alloc: std.mem.Allocator, ef_search: u16) !f32 {
    const r = try oracleRecallWith(alloc, ef_search);
    try std.testing.expect(r >= 0.0 and r <= 1.0);
    return r;
}

// Recall@k on the default configuration (`hnsw_ef_search` = 100).
//
// Threshold 0.70, measured 0.7580. It was 0.30 / measured 0.3370 before the
// best-first rewrite, which meant the guard cleared anything down to a third
// of what the search actually delivered — a test that passes at 0.30 when the
// code scores 0.758 is not a guard. The 0.70 floor now sits above every
// pre-rewrite measurement in the table above (0.2460 / 0.3370 / 0.3790), so
// a regression back to the sampled search turns this red instead of quietly
// re-baselining.
test "HNSW: recall against exhaustive scan at default ef" {
    const recall = try oracleRecall(std.testing.allocator, 100);
    try std.testing.expect(recall >= 0.70);
}

// Recall@k with the candidate budget raised to the corpus size, so the
// search can walk everything the graph still reaches.
//
// This isolates *graph quality* from the search heuristic: at `ef = N` the
// search is no longer the binding constraint, so whatever is missing is an
// edge the degree bound or `shrinkConnections` cut. Measured 0.7720, up from
// 0.7280 before the rewrite — inserting at every layer, not just layer 0,
// also made the graph itself better. Threshold 0.75 leaves little room
// above the measured value because this number is exactly determined: the
// corpus is splitmix64 and the level seed is fixed, so there is no sampling
// variance to absorb.
test "HNSW: degree-bounded graph still reaches the true neighbours at ef = N" {
    const recall = try oracleRecall(std.testing.allocator, @intCast(oracle_n));
    try std.testing.expect(recall >= 0.75);
}

// Structural guard for the pruning: no adjacency list may exceed its
// layer's configured limit, no entry may be a self loop, a duplicate, or
// an id the index does not hold, and no node may be stranded with an empty
// layer-0 list (which is how a naive "keep the nearest, drop the rest"
// shrink silently amputates a region of the graph).
//
// The lower bound on mean degree matters as much as the upper bound: a
// "fix" that capped every list at 1 would sail past a pure max-degree
// assertion while leaving the index unable to reach anything.
test "HNSW: adjacency degree stays bounded by m_max0" {
    const alloc = std.testing.allocator;
    var cfg = Config{};
    cfg.hnsw_ef_construction = 200;
    cfg.hnsw_ef_search = 100;

    var hnsw = HNSW.init(alloc, cfg, oracle_dim);
    defer hnsw.deinit();

    const corpus = try oracleCorpus(alloc);
    defer alloc.free(corpus);
    try oracleFill(&hnsw, corpus);

    const max0: usize = cfg.hnsw_m_max0;
    const max_upper: usize = cfg.hnsw_m;

    var sum: usize = 0;
    var lists: usize = 0;
    var observed_max: usize = 0;
    var it = hnsw.nodes.iterator();
    while (it.next()) |entry| {
        const nd = entry.value_ptr.*;
        for (nd.neighbors, 0..) |list, layer| {
            const limit = if (layer == 0) max0 else max_upper;
            try std.testing.expect(list.items.len <= limit);
            // Layer 0 must never strand a node — once there is more
            // than one node in the index, every one of them needs a
            // level-0 neighbour or it is unreachable.
            //
            // Upper layers may legitimately be empty: when exactly one
            // node reaches the top level it has no peer there. This
            // assertion used to demand non-empty at every layer, which
            // only held while every node sat at level 0.
            if (layer == 0) {
                try std.testing.expect(hnsw.count <= 1 or list.items.len > 0);
            }
            observed_max = @max(observed_max, list.items.len);
            sum += list.items.len;
            lists += 1;
            for (list.items, 0..) |nb, i| {
                try std.testing.expect(nb != nd.id); // no self loop
                try std.testing.expect(hnsw.nodes.contains(nb)); // no dangling id
                for (list.items[i + 1 ..]) |later| {
                    try std.testing.expect(later != nb); // no duplicates
                }
            }
        }
    }
    // Every node contributes at least its layer-0 list. This used to
    // assert `lists == oracle_n`, i.e. that every node sits at level 0
    // — which encoded the flat-graph bug as if it were the contract.
    // A hierarchical graph has strictly more lists than nodes.
    try std.testing.expect(lists >= oracle_n);
    try std.testing.expect(lists > oracle_n); // and now genuinely more than one
    // Upper layers must use the tighter limit.
    var upper_lists: usize = 0;
    var upper_max: usize = 0;
    var uit = hnsw.nodes.iterator();
    while (uit.next()) |entry| {
        const nd2 = entry.value_ptr.*;
        for (nd2.neighbors, 0..) |list2, layer2| {
            if (layer2 == 0) continue; // layer 0 uses m_max0, not m
            upper_lists += list2.items.len;
            upper_max = @max(upper_max, list2.items.len);
        }
    }
    if (upper_lists > 0) {
        try std.testing.expect(upper_max <= max_upper);
    }
    // Un-pruned this is 299.5 (near-complete); pruned it must collapse onto
    // the limit without over-shooting into isolation.
    try std.testing.expect(observed_max <= max0);
    try std.testing.expect(observed_max >= @as(usize, max0 / 2)); // the limit is actually reached
    const mean = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(lists));
    try std.testing.expect(mean > 4.0); // still navigable, not amputated
}

test "HNSW: node levels are actually distributed, not all identical" {
    // Regression guard for a bug that made the index nominally
    // hierarchical and actually flat. `randomLevel` rebuilt its PRNG
    // from `@intFromPtr(&self)` on every call, so the seed never
    // changed and every insert drew the same value. Measured on a
    // 400-node insert: max_level_seen = 0, i.e. not one node reached
    // level 1, the upper layers were empty, and `greedyDescend` above
    // level 0 was unreachable code.
    const alloc = std.testing.allocator;
    var idx = HNSW.init(alloc, .{ .hnsw_m = 16 }, 8);
    defer idx.deinit();

    const n = 400;
    var v: [8]f32 = undefined;
    var max_level: u8 = 0;
    var level_mask: u32 = 0;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Deterministic, well-spread vectors.
        for (&v, 0..) |*x, j| {
            x.* = @as(f32, @floatFromInt((i * 31 + j * 17) % 23)) - 11.0;
        }
        try idx.insert(@intCast(i + 1), &v);
    }

    var it = idx.nodes.iterator();
    while (it.next()) |e| {
        const lvl = e.value_ptr.*.level;
        level_mask |= (@as(u32, 1) << @intCast(lvl));
        if (lvl > max_level) max_level = lvl;
    }

    // The graph must be genuinely hierarchical: more than one distinct
    // level occupied, and at least one node above layer 0.
    try std.testing.expect(@popCount(level_mask) >= 2);
    try std.testing.expect(max_level >= 1);
    // The entry point must sit at the top, not at whatever was
    // inserted first.
    try std.testing.expectEqual(max_level, idx.max_level);
    try std.testing.expectEqual(max_level, idx.nodes.get(idx.entry_point.?).?.level);

    // Determinism: the same seed must rebuild the same level profile.
    var idx2 = HNSW.init(alloc, .{ .hnsw_m = 16 }, 8);
    defer idx2.deinit();
    i = 0;
    while (i < n) : (i += 1) {
        for (&v, 0..) |*x, j| {
            x.* = @as(f32, @floatFromInt((i * 31 + j * 17) % 23)) - 11.0;
        }
        try idx2.insert(@intCast(i + 1), &v);
    }
    var max2: u8 = 0;
    var it2 = idx2.nodes.iterator();
    while (it2.next()) |e| {
        if (e.value_ptr.*.level > max2) max2 = e.value_ptr.*.level;
    }
    try std.testing.expectEqual(max_level, max2);
}

test "HNSW: observability accessors report the live index shape" {
    // The daemon publishes these as `mem3_vector_index_depth` and
    // `mem3_vector_index_nodes`. Two properties are worth pinning:
    //
    //  1. `nodeCount` must agree with actual storage. It is a counter
    //     maintained by `insert`, so a drift between it and
    //     `nodes.count()` would be invisible everywhere else.
    //  2. `maxOccupiedLevel` must report the deepest *occupied*
    //     layer, and -1 (not 0) when there is nothing indexed — a
    //     flat "0" would be indistinguishable from "one node on the
    //     base layer" and would silently make an empty index look
    //     healthy.
    const alloc = std.testing.allocator;

    var empty = HNSW.init(alloc, .{ .hnsw_m = 16 }, 4);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.nodeCount());
    try std.testing.expectEqual(@as(i32, -1), empty.maxOccupiedLevel());

    var idx = HNSW.init(alloc, .{ .hnsw_m = 16 }, 8);
    defer idx.deinit();
    var v: [8]f32 = undefined;
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        for (&v, 0..) |*x, j| {
            x.* = @as(f32, @floatFromInt((n * 31 + j * 17) % 23)) - 11.0;
        }
        try idx.insert(n + 1, &v);
    }

    try std.testing.expectEqual(@as(usize, 200), idx.nodeCount());
    try std.testing.expectEqual(idx.nodes.count(), idx.nodeCount());

    // Recomputed from the nodes, so it equals the deep-est level
    // actually present rather than a sticky high-water mark.
    var deepest: i32 = 0;
    var it = idx.nodes.iterator();
    while (it.next()) |entry| {
        deepest = @max(deepest, @as(i32, entry.value_ptr.*.level));
    }
    try std.testing.expectEqual(deepest, idx.maxOccupiedLevel());
}
