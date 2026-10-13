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
    /// Entry point: the topmost node's id. Null if empty.
    entry_point: ?u64,
    /// Total node count.
    count: usize = 0,

    pub fn init(alloc: Allocator, cfg: Config, dim: u16) HNSW {
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .dim = dim,
            .nodes = std.AutoHashMap(u64, *Node).init(alloc),
            .entry_point = null,
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
            return;
        }

        // Insert at each layer 0..level, with ef_construction beam search.
        // v0.1.0 simplified: at level 0 only, do a TopK cosine search and
        // connect. The upper layers (if any) get a single greedy descent
        // pass.
        if (level == 0) {
            const candidates = try self.searchInternal(vector, self.cfg.hnsw_ef_construction, 0);
            defer self.alloc.free(candidates);
            for (candidates) |cid| {
                if (cid == id) continue;
                try self.connect(id, cid, 0);
            }
        } else {
            // Multi-layer insertion: greedy descent to nearest node at each
            // layer, then beam search at layer 0.
            var current: u64 = self.entry_point.?;
            var l: i32 = @intCast(level);
            while (l > 0) : (l -= 1) {
                const ul: u8 = @intCast(l);
                current = self.greedyDescend(vector, current, ul);
            }
            const candidates = try self.searchInternal(vector, self.cfg.hnsw_ef_construction, 0);
            defer self.alloc.free(candidates);
            for (candidates) |cid| {
                if (cid == id) continue;
                try self.connect(id, cid, 0);
            }
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

    fn searchInternal(self: *HNSW, query: []const f32, ef: usize, level: u8) errors![]u64 {
        if (self.entry_point == null) return &.{};
        var current: u64 = self.entry_point.?;

        // Greedy descent from current's level down to `level`.
        const start_level: i32 = @intCast(self.nodes.get(current).?.level);
        var l: i32 = start_level;
        while (l > @as(i32, @intCast(level))) : (l -= 1) {
            const ul: u8 = @intCast(l);
            current = self.greedyDescend(query, current, ul);
        }

        // Beam search at `level`.
        var visited = std.AutoHashMap(u64, void).init(self.alloc);
        defer visited.deinit();
        var frontier = std.ArrayList(u64).empty;
        defer frontier.deinit(self.alloc);
        var result_set = std.AutoHashMap(u64, f32).init(self.alloc);
        defer result_set.deinit();

        try visited.put(current, {});
        try frontier.append(self.alloc, current);
        try result_set.put(current, self.cosineSim(query, self.nodes.get(current).?.vector));

        const target_ef = ef;
        // The ef budget bounds how many candidates we keep expanding.
        // It must gate the WHOLE beam search, not just one neighbour
        // loop: previously the counter only ever decremented inside the
        // expansion loop and the `break` only left the inner loop, so the
        // outer loop kept running, re-entered the inner loop with
        // `target_ef == 0`, and underflowed. Tests never reached it
        // because they insert a handful of nodes — the budget is
        // `hnsw_ef_construction` (200) neighbour expansions.
        var exhausted = false;
        while (frontier.items.len > 0 and !exhausted) {
            // Pick the frontier node with highest score (lowest distance / highest sim).
            // For cosine, higher is better.
            var best_idx: usize = 0;
            var best_score: f32 = -2.0;
            for (frontier.items, 0..) |nid, i| {
                const s = result_set.get(nid) orelse -2.0;
                if (s > best_score) {
                    best_score = s;
                    best_idx = i;
                }
            }
            const current_nid = frontier.items[best_idx];
            _ = frontier.orderedRemove(best_idx);

            // Expand neighbors.
            const node = self.nodes.get(current_nid) orelse continue;
            const layer_idx: usize = if (level < node.neighbors.len) level else 0;
            if (layer_idx >= node.neighbors.len) continue;
            for (node.neighbors[layer_idx].items) |nid| {
                if (visited.contains(nid)) continue;
                try visited.put(nid, {});
                try frontier.append(self.alloc, nid);
                const s = self.cosineSim(query, self.nodes.get(nid).?.vector);
                try result_set.put(nid, s);
                // Stop on the size of the candidate set, which is what
                // `ef` actually means, and cannot underflow.
                if (result_set.count() >= target_ef) {
                    exhausted = true;
                    break;
                }
            }
        }

        // Collect top ef by score.
        var scores = std.ArrayList(struct { id: u64, s: f32 }).empty;
        defer scores.deinit(self.alloc);
        var it = result_set.iterator();
        while (it.next()) |entry| {
            try scores.append(self.alloc, .{ .id = entry.key_ptr.*, .s = entry.value_ptr.* });
        }
        std.mem.sort(@TypeOf(scores.items[0]), scores.items, {}, struct {
            fn lt(_: void, a: @TypeOf(scores.items[0]), b: @TypeOf(scores.items[0])) bool {
                return a.s > b.s; // descending
            }
        }.lt);

        const out = try self.alloc.alloc(u64, @min(scores.items.len, ef));
        for (out, 0..) |*o, i| o.* = scores.items[i].id;
        return out;
    }

    pub const SearchResult = struct {
        id: u64,
        score: f32,
    };

    fn greedyDescend(self: *HNSW, query: []const f32, start: u64, level: u8) u64 {
        var current = start;
        var current_score = self.cosineSim(query, self.nodes.get(current).?.vector);
        var changed = true;
        while (changed) {
            changed = false;
            const node = self.nodes.get(current) orelse break;
            if (level >= node.neighbors.len) break;
            for (node.neighbors[level].items) |nid| {
                const s = self.cosineSim(query, self.nodes.get(nid).?.vector);
                if (s > current_score) {
                    current = nid;
                    current_score = s;
                    changed = true;
                }
            }
        }
        return current;
    }

    fn connect(self: *HNSW, a: u64, b: u64, level: u8) !void {
        const a_node = self.nodes.getPtr(a) orelse return;
        const b_node = self.nodes.getPtr(b) orelse return;
        if (level < a_node.*.neighbors.len) try a_node.*.neighbors[level].append(self.alloc, b);
        if (level < b_node.*.neighbors.len) try b_node.*.neighbors[level].append(self.alloc, a);
    }

    fn randomLevel(self: *HNSW) u8 {
        // Exponential distribution with `1/M` probability.
        var prng = std.Random.DefaultPrng.init(@intCast(@intFromPtr(&self) ^ 0xDEADBEEF));
        const rand = prng.random();
        var lvl: u8 = 0;
        while (lvl < 16) : (lvl += 1) {
            const r = rand.float(f32);
            if (r > 1.0 / @as(f32, @floatFromInt(self.cfg.hnsw_m))) break;
        }
        return lvl;
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
