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
const StubEmbedder = @import("embedder.zig").StubEmbedder;
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
    embedder: StubEmbedder,

    pub fn init(
        alloc: Allocator,
        cfg: config,
        hnsw: *HNSW,
        hypergraph: *HyMem,
    ) HybridRetriever {
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .hnsw = hnsw,
            .hypergraph = hypergraph,
            .embedder = StubEmbedder.init(cfg.embedder_dim),
        };
    }

    /// Embed a query string and run dense retrieval.
    pub fn embedQuery(self: *HybridRetriever, alloc: Allocator, text: []const u8) ![]f32 {
        return self.embedder.embed(alloc, text);
    }

    /// Three-way recall for a query text. Returns top-k candidates ranked
    /// by the fused score.
    pub fn recall(
        self: *HybridRetriever,
        alloc: Allocator,
        query: []const u8,
        topk: usize,
    ) ![]Candidate {
        // 1. Dense: HNSW search.
        const qvec = try self.embedder.embed(alloc, query);
        defer alloc.free(qvec);
        const dense_results = try self.hnsw.search(alloc, qvec, topk * 3);
        defer alloc.free(dense_results);

        // 2. Sparse: in v0.1.0 we approximate via dense; v0.2.0 will use BM25.
        // For now, every dense candidate gets a sparse score of 1.0.
        const sparse_results = dense_results;
        _ = sparse_results;

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
            const score = self.hnsw.cosineSim(qvec, self.hnsw.nodes.get(r.id).?.vector);
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

        // 5. Rank by combined score, take top-k.
        var cands = std.ArrayList(Candidate).empty;
        defer cands.deinit(alloc);
        var it = cand_map.iterator();
        while (it.next()) |entry| {
            try cands.append(alloc, entry.value_ptr.*);
        }
        std.mem.sort(Candidate, cands.items, {}, struct {
            fn lt(_: void, a: Candidate, b: Candidate) bool {
                return a.combined(@import("../core/config.zig").Config{}) >
                    b.combined(@import("../core/config.zig").Config{});
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
