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
const bm25_mod = @import("bm25.zig");
const BM25 = bm25_mod.BM25;
const config = @import("../core/config.zig").Config;

pub const Candidate = struct {
    cell_id: u64,
    dense_score: f32 = 0.0,
    /// BM25 lexical relevance, **max-normalised within this query**:
    /// the best lexical hit of a query scores `1.0` and the rest are
    /// scored against it.
    ///
    /// Max-normalisation, not raw BM25 and not Reciprocal Rank Fusion,
    /// and the reason is the contract. `combined` is a weighted *sum* of
    /// three scores and `store.zig` feeds its result straight into the
    /// reranker; RRF is a rank-only transform, so adopting it here would
    /// mean either changing `combined`'s contract (out of the question —
    /// it is the documented fusion formula) or hanging a second, parallel
    /// notion of relevance off the side that nothing downstream reads.
    /// Two ranking truths in one struct is exactly the failure mode this
    /// file's own history is a record of: the graph arm is *already* a
    /// rank-only signal carried as a flat `0.7`, and the codebase's
    /// established convention for rank-like evidence is a bounded score
    /// inside the same weighted sum.
    ///
    /// Normalising by the query's own best hit is what makes the raw,
    /// unbounded BM25 score commensurable with cosine similarity
    /// (`[-1, 1]`) and with that flat `0.7`, so `λ_sparse=0.2` is a real
    /// weight rather than an unbounded number times a constant. The cost
    /// is the usual one: it discards *how much* better the top hit was
    /// than the second. For an arm whose job is exact-identifier
    /// matching — "did this token appear in that document, at all" —
    /// that is the right thing to discard.
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
    /// BM25 lexical index. Borrowed, exactly as `hnsw` and `hypergraph`
    /// are: the Store owns it and updates it on insert, forget and
    /// snapshot restore. `null` means "no lexical arm", which is a
    /// *silent* degradation and only `init` (below) can produce it.
    bm25: ?*BM25,

    /// Retriever with **no lexical arm**.
    ///
    /// Kept so existing callers keep compiling, but it is not what the
    /// product runs: with `bm25 == null`, `recall` scores `sparse_score`
    /// at 0 for everything, which is honest (no lexical evidence) and
    /// not the same thing as the v0.1.0 placeholder, which scored it as
    /// a copy of `dense_score`. Anything that is not a benchmark
    /// harness should call `initWithSparse`.
    pub fn init(
        alloc: Allocator,
        cfg: config,
        embedder: Embedder,
        hnsw: *HNSW,
        hypergraph: *HyMem,
    ) HybridRetriever {
        return initWithSparse(alloc, cfg, embedder, hnsw, hypergraph, null);
    }

    /// `embedder` is supplied by the caller rather than built from
    /// `cfg.embedder_kind`. A retriever that hashed queries with
    /// `Config`'s default `.stub_xxhash` while the index it searches was
    /// built with `.lexical_hash` would have compared vectors from two
    /// different spaces and returned confident nonsense. The store hands
    /// over the exact embedder its index was built with.
    ///
    /// `bm25` is the store's live lexical index. It is borrowed rather
    /// than owned for the same reason `hnsw` is: the store is the thing
    /// that knows when a cell is born, edited or forgotten, and an index
    /// that had to be told about those separately from the vectors would
    /// drift.
    pub fn initWithSparse(
        alloc: Allocator,
        cfg: config,
        embedder: Embedder,
        hnsw: *HNSW,
        hypergraph: *HyMem,
        bm25: ?*BM25,
    ) HybridRetriever {
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .hnsw = hnsw,
            .hypergraph = hypergraph,
            .embedder = embedder,
            .bm25 = bm25,
        };
    }

    /// Embed a query string and run dense retrieval.
    pub fn embedQuery(self: *HybridRetriever, alloc: Allocator, text: []const u8) ![]f32 {
        return self.embedder.embed(alloc, text);
    }

    /// Three-way recall for a query text. Returns top-k candidates ranked
    /// by the fused score. Caller owns the result.
    ///
    /// The three arms contribute candidates, not just scores: a cell the
    /// lexical arm matches is a candidate even when HNSW never returned
    /// it, which is the entire reason the identifier case set works.
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

        // 2. Sparse: BM25 over the lexical index.
        //
        // The over-fetch window is a multiple of `topk` rather than a
        // constant, because the caller has said how many hits it wants
        // and this is the arm that finds hits nobody else asked for.
        // `max(., 1)` so a caller who configured `sparse_overfetch = 0`
        // gets no lexical arm rather than a zero-sized one that silently
        // looks like "no lexical hits".
        const sparse_n = topk * @max(self.cfg.sparse_overfetch, 1);
        const sparse_hits = if (self.bm25) |idx|
            try idx.search(alloc, query, sparse_n)
        else
            try alloc.alloc(bm25_mod.Hit, 0);
        defer alloc.free(sparse_hits);

        // 3. Graph: seed multi-hop expansion from the best cells *any*
        // arm found, not from the dense arm alone.
        //
        // This used to be dense-only, which meant a cell the lexical arm
        // rescued got no neighbourhood either — it entered the ranking
        // with dense 0, sparse 1.0 and graph 0, and lost to a cell that
        // matched nothing at all but happened to be a dense seed. Seeding
        // from both is the honest reading of "the graph arm expands the
        // best candidates": it costs at most `graph_seed_n` extra seeds
        // and is bounded by `cfg.multi_hop_max_expansions` downstream.
        const graph_seed_n: usize = 10;
        var seeds = std.ArrayList(u64).empty;
        defer seeds.deinit(alloc);
        for (dense_results[0..@min(graph_seed_n, dense_results.len)]) |r| {
            try seeds.append(alloc, r.id);
        }
        for (sparse_hits[0..@min(graph_seed_n, sparse_hits.len)]) |h| {
            var seen = false;
            for (seeds.items) |s| {
                if (s == h.id) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try seeds.append(alloc, h.id);
        }

        const graph_results = try self.hypergraph.multiHop(
            alloc,
            seeds.items,
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
        // Max-normalise the lexical arm against its own best hit. See
        // `Candidate.sparse_score` for why this is normalisation rather
        // than RRF.
        //
        // `search` returns best-first, so `sparse_hits[0]` is the max.
        // The `> 0` guard covers a corpus where every term is in every
        // document and idf is (correctly) ~0: dividing by that would
        // produce 0/0, and NaN propagates silently through `combined`
        // into the reranker's sort.
        if (sparse_hits.len > 0 and sparse_hits[0].score > 0.0) {
            const best = sparse_hits[0].score;
            for (sparse_hits) |h| {
                const entry = cand_map.getPtr(h.id) orelse blk: {
                    const c = Candidate{ .cell_id = h.id };
                    try cand_map.put(h.id, c);
                    break :blk cand_map.getPtr(h.id).?;
                };
                entry.sparse_score = @max(entry.sparse_score, h.score / best);
            }
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

// =============================================================================
// The sparse arm — corpus helpers for the identifier case set
// =============================================================================

// `core` is already imported at the top of this file (EdgeType lives there).

const POOL_N = [_][]const u8{ "deployment", "rollout", "cluster", "dashboard", "pipeline", "alert", "ticket", "backlog", "release", "migration", "schema", "cache" };
const POOL_V = [_][]const u8{ "completed", "stalled", "resumed", "timed out", "was retried", "flapped", "succeeded", "was cancelled", "recovered", "was throttled" };
const POOL_C = [_][]const u8{ "during the morning standup", "in the staging environment", "after the config reload", "while the cache was cold", "on the second replica", "during the weekly review" };

fn clusterText(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "the {s} {s} {s} and the team recorded the outcome in the weekly log so that it could be reviewed later during the retrospective and compared against the previous cycle numbers",
        .{ POOL_N[i % POOL_N.len], POOL_V[i % POOL_V.len], POOL_C[i % POOL_C.len] },
    ) catch unreachable;
}

/// Identifiers that appear only in an extracted fact triple, never in
/// the episode prose. `System|reported|ENOENT` is what `mem3 add`
/// actually produces for an incident note, and the dense arm embeds the
/// episode alone — so these are invisible to it by construction.
const fact_idents = [_][]const u8{
    "PathError",      "fsync",        "mmap",           "EINTR",
    "atomic_ptr",     "ArrayHashMap", "toOwnedSlice",   "waitpid",
    "sigtimedwait",   "futex",        "cpuid",          "tlb_flush",
};

const fact_prose = "an unrelated note about the quarterly audit recorded a discrepancy that the on call engineer logged before leaving for the evening";

/// Rank of `want` in `cands`, or 0 when it is absent.
fn rankOf(cands: []const Candidate, want: u64) usize {
    for (cands, 0..) |c, i| {
        if (c.cell_id == want) return i + 1;
    }
    return 0;
}

test "HybridRetriever: the sparse arm retrieves an identifier the dense arm cannot see" {
    // The case set that motivated the sparse arm.
    //
    // 40 long, mutually hyperlinked "project" cells give the graph arm a
    // dense neighbourhood to promote; 12 cells carry an identifier in an
    // atomic fact while their episode prose is deliberately identifier-
    // free. `Store.indexLexicalText` indexes episode + facts and
    // `Store.commitBuiltCell` embeds the episode alone, so the lexical
    // arm sees these identifiers and the dense arm provably does not.
    const alloc = std.testing.allocator;
    const n_cluster = 40;

    var hnsw = HNSW.init(alloc, .{}, 384);
    defer hnsw.deinit();
    var ids: std.atomic.Value(u64) = .init(1);
    var hymem = HyMem.init(alloc, &ids);
    defer hymem.deinit();
    const emb = try Embedder.init(.lexical_hash, 384);
    var index = BM25.init(alloc, 1.2, 0.75);
    defer index.deinit();

    var scratch: [320]u8 = undefined;
    for (0..n_cluster) |i| {
        const id: u64 = @intCast(i + 1);
        const text = clusterText(&scratch, i);
        const v = try emb.embed(alloc, text);
        defer alloc.free(v);
        try hnsw.insert(id, v);
        try index.index(id, text);
        try hymem.addNode(id);
    }
    var edge_id: u64 = 1;
    for (0..n_cluster - 2) |i| {
        const nodes = [_]u64{ @intCast(i + 1), @intCast(i + 2), @intCast(i + 3) };
        _ = try hymem.addEdge(.{
            .id = edge_id,
            .edge_type = core.EdgeType.causal,
            .nodes = &nodes,
            .weight = 0.9,
            .source_weights = .{ 0.4, 0.3, 0.3 },
            .confidence = 0.9,
            .created_at = 0,
        });
        edge_id += 1;
    }
    const fact_base: u64 = n_cluster + 1;
    for (fact_idents, 0..) |ident, i| {
        const id: u64 = fact_base + @as(u64, @intCast(i));
        // Dense arm: the episode, which does not mention the identifier.
        const v = try emb.embed(alloc, fact_prose);
        defer alloc.free(v);
        try hnsw.insert(id, v);
        // Lexical arm: episode + the fact triple, exactly as the store does.
        var buf: [512]u8 = undefined;
        const lex = std.fmt.bufPrint(&buf, "{s} system reported {s}", .{ fact_prose, ident }) catch unreachable;
        try index.index(id, lex);
    }

    // The v0.1.0 formula, reproduced exactly: with `sparse_score =
    // dense_score`, `0.5*d + 0.2*d + 0.3*g` is `0.7*d + 0.3*g`.
    const before_cfg: config = .{ .recall_lambda_dense = 0.7, .recall_lambda_sparse = 0.0, .recall_lambda_graph = 0.3 };
    var before = HybridRetriever.init(alloc, before_cfg, emb, &hnsw, &hymem);
    var after = HybridRetriever.initWithSparse(alloc, .{}, emb, &hnsw, &hymem, &index);

    var before_hits: usize = 0;
    for (fact_idents, 0..) |ident, i| {
        const want: u64 = fact_base + @as(u64, @intCast(i));
        const bc = try before.recall(alloc, ident, 10);
        defer alloc.free(bc);
        const ac = try after.recall(alloc, ident, 10);
        defer alloc.free(ac);

        if (rankOf(bc, want) != 0) before_hits += 1;

        // The fix, stated as a gate: every identifier in the case set is
        // now the top hit. Without the lexical arm none of them are
        // reachable at all.
        try std.testing.expectEqual(@as(usize, 1), rankOf(ac, want));
    }
    // The documented baseline. Measured on this corpus: the v0.1.0
    // formula retrieves 3 of the 12 (none of them at rank 1). The gate
    // is an upper bound rather than an equality so that a legitimate
    // change to the corpus shows up as a smaller delta to re-measure
    // rather than as a mystery failure.
    try std.testing.expect(before_hits <= 3);
    try std.testing.expect(before_hits < fact_idents.len);
}

test "HybridRetriever: sparse_score is independent of dense_score" {
    // The placeholder assigned `entry.sparse_score = entry.dense_score`,
    // which made `λ_sparse` a second copy of `λ_dense`. Any candidate
    // scoring both arms identically is the signature of that bug; a real
    // lexical arm produces candidates whose sparse score comes from
    // somewhere the vector arm cannot see.
    const alloc = std.testing.allocator;
    var hnsw = HNSW.init(alloc, .{}, 384);
    defer hnsw.deinit();
    var ids: std.atomic.Value(u64) = .init(1);
    var hymem = HyMem.init(alloc, &ids);
    defer hymem.deinit();
    const emb = try Embedder.init(.lexical_hash, 384);
    var index = BM25.init(alloc, 1.2, 0.75);
    defer index.deinit();

    const texts = [_][]const u8{
        "the deploy pipeline runs on kubernetes clusters in eu west 1",
        "the user prefers strong coffee each morning before standup",
        "a module_not_found error was raised while loading the manifest",
    };
    for (texts, 1..) |t, i| {
        const v = try emb.embed(alloc, t);
        defer alloc.free(v);
        try hnsw.insert(@intCast(i), v);
        try index.index(@intCast(i), t);
    }
    var hybrid = HybridRetriever.initWithSparse(alloc, .{}, emb, &hnsw, &hymem, &index);

    const cands = try hybrid.recall(alloc, "module_not_found", 3);
    defer alloc.free(cands);
    try std.testing.expect(cands.len > 0);

    var mismatched: usize = 0;
    for (cands) |c| {
        if (@abs(c.dense_score - c.sparse_score) > 1e-6) mismatched += 1;
        // A lexical hit normalises to at most 1.0 by construction.
        try std.testing.expect(c.sparse_score <= 1.0 + 1e-6);
    }
    // If the placeholder were back, every candidate would have
    // `sparse_score == dense_score` and this would be zero.
    try std.testing.expect(mismatched > 0);
}

test "HybridRetriever: recall with no lexical index still answers, with sparse at zero" {
    // `init` is the no-lexical-arm constructor the benchmark harnesses
    // still use. It must degrade to "no lexical evidence" (score 0),
    // not back to the v0.1.0 "sparse is a copy of dense".
    const alloc = std.testing.allocator;
    var hnsw = HNSW.init(alloc, .{}, 384);
    defer hnsw.deinit();
    var ids: std.atomic.Value(u64) = .init(1);
    var hymem = HyMem.init(alloc, &ids);
    defer hymem.deinit();
    const emb = try Embedder.init(.lexical_hash, 384);
    var hybrid = HybridRetriever.init(alloc, .{}, emb, &hnsw, &hymem);

    const texts = [_][]const u8{
        "the deploy pipeline runs on kubernetes clusters in eu west 1",
        "a module_not_found error was raised while loading the manifest",
    };
    for (texts, 1..) |t, i| {
        const v = try emb.embed(alloc, t);
        defer alloc.free(v);
        try hnsw.insert(@intCast(i), v);
    }

    const cands = try hybrid.recall(alloc, "module_not_found", 3);
    defer alloc.free(cands);
    try std.testing.expect(cands.len > 0);
    for (cands) |c| {
        try std.testing.expectEqual(@as(f32, 0.0), c.sparse_score);
    }
}
