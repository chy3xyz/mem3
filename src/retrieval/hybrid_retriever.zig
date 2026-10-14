//! Hybrid retriever — three-way recall fusion.
//!
//! **Constitution FR-007**: HNSW (dense) + KV (exact) + Hypergraph (relation).
//! Fusion weights: `λ_dense=0.5, λ_sparse=0.2, λ_graph=0.3`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const HNSW = @import("hnsw.zig").HNSW;
const HyMem = @import("../hypermem/engine.zig").HyMem;
const Embedder = @import("embedder.zig").Embedder;
const config = @import("../core/config.zig").Config;

pub const Candidate = struct {
    cell_id: u64,
    dense_score: f32 = 0.0,
    sparse_score: f32 = 0.0,
    graph_score: f32 = 0.0,

    pub fn combined(self: *const Candidate, cfg: config) f32 {
        return cfg.recall_lambda_dense * self.dense_score +
            cfg.recall_lambda_sparse * self.sparse_score +
            cfg.recall_lambda_graph * self.graph_score;
    }
};

pub const HybridRetriever = struct {
    alloc: Allocator,
    cfg: config,
    hnsw: *HNSW,
    hypergraph: *HyMem,
    embedder: Embedder,

    /// `embedder` is supplied by the caller rather than built from
    /// `cfg.embedder_kind`. A retriever that hashed queries with
    /// `Config`'s default `.stub_xxhash` while the index it searches was
    /// built with `.lexical_hash` would have compared vectors from two
    /// different spaces and returned confident nonsense. The store hands
    /// over the exact embedder its index was built with.
    pub fn init(
        alloc: Allocator,
        cfg: config,
        embedder: Embedder,
        hnsw: *HNSW,
        hypergraph: *HyMem,
    ) HybridRetriever {
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .hnsw = hnsw,
            .hypergraph = hypergraph,
            .embedder = embedder,
        };
    }

    /// Embed a query string and run dense retrieval.
    pub fn embedQuery(self: *HybridRetriever, alloc: Allocator, text: []const u8) ![]f32 {
        return self.embedder.embed(alloc, text);
    }

    /// Three-way recall for a query text. Returns top-k candidates ranked
    /// by the fused score. Caller owns the result.
    pub fn recall(
        self: *HybridRetriever,
        alloc: Allocator,
        query: []const u8,
        topk: usize,
    ) ![]Candidate {
        if (topk == 0) return alloc.alloc(Candidate, 0);

        // 1. Dense: HNSW search.
        const qvec = try self.embedder.embed(alloc, query);
        defer alloc.free(qvec);
        const dense_results = try self.hnsw.search(alloc, qvec, topk * 3);
        defer alloc.free(dense_results);

        // 3. Graph: take the top-10 dense seeds, do multi-hop expansion.
        const seed_n: usize = @min(10, dense_results.len);
        const seeds = try alloc.alloc(u64, seed_n);
        defer alloc.free(seeds);
        for (dense_results[0..seed_n], 0..) |r, i| seeds[i] = r.id;

        const graph_results = try self.hypergraph.multiHop(
            alloc,
            seeds,
            self.cfg.max_hops,
            self.cfg.multi_hop_confidence_threshold,
            null,
        );
        defer alloc.free(graph_results);

        // 4. Fuse into candidates.
        var cand_map = std.AutoHashMap(u64, Candidate).init(alloc);
        defer cand_map.deinit();

        for (dense_results) |r| {
            // A hit with no vector in the index cannot be scored by
            // cosine. Dereferencing it anyway was a panic on a path the
            // store now runs for every query.
            const node = self.hnsw.nodes.get(r.id) orelse continue;
            const score = self.hnsw.cosineSim(qvec, node.vector);
            const entry = cand_map.getPtr(r.id) orelse blk: {
                const c = Candidate{ .cell_id = r.id };
                try cand_map.put(r.id, c);
                break :blk cand_map.getPtr(r.id).?;
            };
            entry.dense_score = @max(entry.dense_score, score);
        }
        for (graph_results) |id| {
            const entry = cand_map.getPtr(id) orelse blk: {
                const c = Candidate{ .cell_id = id };
                try cand_map.put(id, c);
                break :blk cand_map.getPtr(id).?;
            };
            entry.graph_score = @max(entry.graph_score, 0.7);
        }
        for (dense_results) |r| {
            // v0.1.0: sparse = dense (placeholder).
            const entry = cand_map.getPtr(r.id) orelse continue;
            entry.sparse_score = @max(entry.sparse_score, entry.dense_score);
        }

        // 5. Rank by combined score, take top-k. The comparison context
        // carries `self.cfg`: sorting on `Config{}` defaults silently
        // ignored any non-default fusion weights.
        var cands = std.ArrayList(Candidate).empty;
        defer cands.deinit(alloc);
        var it = cand_map.iterator();
        while (it.next()) |entry| {
            try cands.append(alloc, entry.value_ptr.*);
        }
        std.mem.sort(Candidate, cands.items, self.cfg, struct {
            fn lt(cfg: config, a: Candidate, b: Candidate) bool {
                return a.combined(cfg) > b.combined(cfg);
            }
        }.lt);

        const out = try alloc.alloc(Candidate, @min(topk, cands.items.len));
        for (out, 0..) |*o, i| o.* = cands.items[i];
        return out;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Candidate: combined score respects fusion weights" {
    const cfg: config = .{};
    const c = Candidate{ .cell_id = 1, .dense_score = 0.8, .sparse_score = 0.5, .graph_score = 0.3 };
    const expected = 0.5 * 0.8 + 0.2 * 0.5 + 0.3 * 0.3;
    try std.testing.expectApproxEqAbs(expected, c.combined(cfg), 1e-6);
}

test "HybridRetriever: recall uses the caller's embedder space" {
    // `init` used to build its own embedder from `Config` defaults, so a
    // store indexing with `.lexical_hash` got a retriever hashing queries
    // with `.stub_xxhash` — two different vector spaces, and recall
    // returned whatever ranked highest in the wrong one. The retriever
    // now takes the embedder the index was built with.
    const alloc = std.testing.allocator;
    const cfg: config = .{};

    var hnsw = HNSW.init(alloc, .{}, 384);
    defer hnsw.deinit();
    var ids: std.atomic.Value(u64) = .init(1);
    var hymem = HyMem.init(alloc, &ids);
    defer hymem.deinit();

    var hybrid = HybridRetriever.init(alloc, cfg, Embedder.init(.lexical_hash, 384) catch unreachable, &hnsw, &hymem);

    const queries = [_][]const u8{
        "the telescope tracked a distant galaxy",
        "watered the tomatoes in the evening",
        "compiled the zig release build",
    };
    for (queries, 0..) |q, i| {
        const v = try hybrid.embedQuery(alloc, q);
        defer alloc.free(v);
        try hnsw.insert(100 + i, v);
    }

    const cands = try hybrid.recall(alloc, "telescope galaxy", 3);
    defer alloc.free(cands);
    // HNSW over-fetches, so all three nodes can come back; what matters
    // is that the right one ranks first.
    try std.testing.expect(cands.len >= 1);
    try std.testing.expectEqual(@as(u64, 100), cands[0].cell_id);
    // Non-zero means the query and the hit were embedded in one space.
    try std.testing.expect(cands[0].dense_score > 0.1);
    // Strictly ahead of the other two.
    for (cands[1..]) |other| {
        try std.testing.expect(cands[0].dense_score > other.dense_score);
    }
}

test "HybridRetriever: recall over an empty index is empty, not a panic" {
    const alloc = std.testing.allocator;
    const cfg: config = .{};
    var hnsw = HNSW.init(alloc, .{}, 384);
    defer hnsw.deinit();
    var ids: std.atomic.Value(u64) = .init(1);
    var hymem = HyMem.init(alloc, &ids);
    defer hymem.deinit();
    var hybrid = HybridRetriever.init(alloc, cfg, Embedder.init(.lexical_hash, 384) catch unreachable, &hnsw, &hymem);

    const none = try hybrid.recall(alloc, "anything", 5);
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    const zero_k = try hybrid.recall(alloc, "anything", 0);
    defer alloc.free(zero_k);
    try std.testing.expectEqual(@as(usize, 0), zero_k.len);
}
