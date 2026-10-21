//! Runtime configuration. Defaults from data-model.md §Configuration.

const std = @import("std");

/// All thresholds / parameters. CLI flags override these.
pub const Config = struct {
    // Storage
    data_dir: []const u8 = "data",
    memtable_size: usize = 64 * 1024 * 1024,
    snapshot_every_n_writes: u64 = 10_000,
    wal_buffer_size: usize = 64 * 1024,

    // HNSW
    hnsw_m: u16 = 16,
    hnsw_m_max0: u16 = 32,
    hnsw_ef_construction: u16 = 200,
    hnsw_ef_search: u16 = 100,
    /// Seed for the index's level-assignment RNG. Explicit so graph
    /// construction is reproducible: the benchmark reports a stability
    /// figure and the tests assert measured numbers, both of which are
    /// meaningless if every run builds a different graph.
    hnsw_seed: u64 = 0x5EED_1234_ABCD_0001,
    embedder_dim: u16 = 384,
    embedder_kind: EmbedderKind = .stub_xxhash,

    // Scoring weights (per constitution)
    importance_alpha: f32 = 0.30, // source_coherence
    importance_beta: f32 = 0.40, // goal_relevance
    importance_gamma: f32 = 0.30, // existential_contribution

    // Three-way recall fusion
    recall_lambda_dense: f32 = 0.5,
    recall_lambda_sparse: f32 = 0.2,
    recall_lambda_graph: f32 = 0.3,

    // BM25 sparse arm (`retrieval/bm25.zig`).
    //
    // `1.2` / `0.75` are the Robertson–Sparck-Jones defaults and are not
    // tuned to this corpus: the sparse arm's job is to catch exact
    // identifiers, and the shape of the tf curve barely moves which of
    // two documents that mentions `module_not_found` wins. Exposed
    // because `b=0` and `k1=0` are the two degenerate settings the
    // scoring tests pin, not because anyone is expected to sweep them.
    bm25_k1: f32 = 1.2,
    bm25_b: f32 = 0.75,
    /// Candidates the sparse arm over-fetches, as a multiple of `topk`.
    ///
    /// The dense arm over-fetches 3x for the same reason and with the
    /// same rationale: HNSW's graph walk is approximate and BM25's
    /// postings are not sorted globally, so the top-k of the *candidate
    /// set* is only as good as the window it was drawn from. `recall`
    /// truncates to `topk` after fusion, where the graph arm can pull an
    /// id in from outside the lexical top-k entirely.
    sparse_overfetch: usize = 5,

    // GHW-prioritized rerank
    goal_bonus_weight: f32 = 0.4,
    existence_bonus_weight: f32 = 0.3,
    recency_bonus_weight: f32 = 0.2,

    // Consolidation / Forgetting
    consolidation_threshold: f32 = 0.75,
    forgetting_threshold: f32 = 0.1,
    consolidation_min_cluster: usize = 3,

    // Decay rates — constitution asymmetry: λ_m > λ_f > λ_s
    decay_rate_matter: f32 = 0.05,
    decay_rate_form: f32 = 0.03,
    decay_rate_spirit: f32 = 0.01,

    // Multi-hop
    max_hops: u8 = 3,
    multi_hop_confidence_threshold: f32 = 0.3,
    multi_hop_max_expansions: usize = 1000,

    // Retrieval topk
    default_topk: usize = 10,

    // Server
    http_default_port: u16 = 7777,
    http_default_bind: []const u8 = "127.0.0.1",

    // Logging
    log_every_seconds: u64 = 60,
    log_format: LogFormat = .human,

    // Durability
    /// When the WAL is `fsync`ed relative to acknowledging a write.
    /// `.always` is the historical behaviour and the default.
    wal_sync: WalSync = .always,

    pub const EmbedderKind = enum {
        /// Deterministic hash-based stub (v0.1.0 default; ~zero deps).
        /// Semantically blind — kept for reproducibility, not relevance.
        stub_xxhash,
        /// Real lexical embedder: hashed word unigram/bigram + character
        /// 3-gram features, sublinear tf, signed hashing, L2-normalised.
        /// Pure Zig, deterministic, no external deps.
        lexical_hash,
        /// Reserved for v0.2.0 (ONNX model load).
        onnx_external,
    };

    pub const LogFormat = enum {
        human,
        jsonl,
        silent,
    };

    /// WAL durability mode: *when* the `fsync` that makes a record survive
    /// power loss happens relative to the moment the write is acknowledged.
    ///
    ///  - `always` — every record is `write`n and `fsync`ed before `append`
    ///    returns. The pre-existing behaviour, byte-for-byte.
    ///  - `group`  — records still are not acknowledged until an `fsync`
    ///    that covers them has completed, but concurrent writers share that
    ///    `fsync` (leader/follower group commit). The durability promise is
    ///    the same as `always`; only the cost per record changes, and only
    ///    when more than one writer is in flight.
    ///  - `interval_ms = N` — **weaker, on purpose.** `append` returns once
    ///    the record is in the OS page cache and `fsync` runs at most every
    ///    N ms. A process crash (`kill -9`) loses nothing, because the bytes
    ///    are already in the kernel; an OS crash or power cut can lose every
    ///    record written since the last `fsync`, i.e. up to ~N ms of writes
    ///    (plus the daemon's 100 ms maintenance tick when the stream goes
    ///    idle).
    pub const WalSync = union(enum) {
        always,
        group,
        interval_ms: u32,

        pub const ParseError = error{InvalidWalSync};

        /// `always` | `group` | `interval:N` (N a positive number of ms).
        pub fn parse(s: []const u8) ParseError!WalSync {
            if (std.mem.eql(u8, s, "always")) return .always;
            if (std.mem.eql(u8, s, "group")) return .group;
            const prefix = "interval:";
            if (std.mem.startsWith(u8, s, prefix)) {
                const n = std.fmt.parseInt(u32, s[prefix.len..], 10) catch return error.InvalidWalSync;
                if (n == 0) return error.InvalidWalSync;
                return .{ .interval_ms = n };
            }
            return error.InvalidWalSync;
        }
    };

    /// Decay rate for a given source. Per Constitution Principle III:
    /// λ_matter > λ_form > λ_spirit.
    pub fn decayRateFor(self: *const Config, source: @import("types.zig").MemorySource) f32 {
        return switch (source) {
            .matter => self.decay_rate_matter,
            .form => self.decay_rate_form,
            .spirit => self.decay_rate_spirit,
        };
    }
};

test "Config: defaults satisfy λ_m > λ_f > λ_s" {
    const c: Config = .{};
    try std.testing.expect(c.decay_rate_matter > c.decay_rate_form);
    try std.testing.expect(c.decay_rate_form > c.decay_rate_spirit);
    try std.testing.expect(c.decay_rate_spirit > 0.0);
}

test "Config: scoring weights sum to 1" {
    const c: Config = .{};
    const sum = c.importance_alpha + c.importance_beta + c.importance_gamma;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-5);
    const rsum = c.recall_lambda_dense + c.recall_lambda_sparse + c.recall_lambda_graph;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rsum, 1e-5);
}

test "Config: bm25 knobs are in their usable ranges" {
    const c: Config = .{};
    // k1 >= 0: k1 = 0 is the "saturate immediately" degenerate case the
    // scoring test pins, and a negative k1 would make the tf term
    // negative for long documents.
    try std.testing.expect(c.bm25_k1 >= 0.0);
    // 0 <= b <= 1: b > 1 would reward longer documents for being long,
    // inverting the length normalisation.
    try std.testing.expect(c.bm25_b >= 0.0);
    try std.testing.expect(c.bm25_b <= 1.0);
    // The sparse arm has to over-fetch: a window of 1 would truncate the
    // lexical ranking to a single hit before fusion ever saw it, which
    // is the dense arm's mistake in a different place.
    try std.testing.expect(c.sparse_overfetch >= 1);
}

test "Config: the documented three-way fusion weights are unchanged" {
    // λ_dense = 0.5, λ_sparse = 0.2, λ_graph = 0.3 is the constitutional
    // split. The sparse arm became real; the weights did not move, so
    // this pins them against a well-meaning future "fix" to the 0.7/0.3
    // split the placeholder accidentally produced.
    const c: Config = .{};
    try std.testing.expectEqual(@as(f32, 0.5), c.recall_lambda_dense);
    try std.testing.expectEqual(@as(f32, 0.2), c.recall_lambda_sparse);
    try std.testing.expectEqual(@as(f32, 0.3), c.recall_lambda_graph);
}

test "WalSync.parse: the three durability modes and nothing else" {
    const W = Config.WalSync;
    try std.testing.expectEqual(W.always, try W.parse("always"));
    try std.testing.expectEqual(W.group, try W.parse("group"));
    try std.testing.expectEqual(W{ .interval_ms = 50 }, try W.parse("interval:50"));
    try std.testing.expectEqual(W{ .interval_ms = 1 }, try W.parse("interval:1"));
    // A zero interval is `always` in disguise; refusing it keeps the
    // flag's meaning legible instead of picking a silent winner.
    try std.testing.expectError(error.InvalidWalSync, W.parse("interval:0"));
    try std.testing.expectError(error.InvalidWalSync, W.parse("interval:"));
    try std.testing.expectError(error.InvalidWalSync, W.parse("interval"));
    try std.testing.expectError(error.InvalidWalSync, W.parse("interval:abc"));
    try std.testing.expectError(error.InvalidWalSync, W.parse("interval:-5"));
    try std.testing.expectError(error.InvalidWalSync, W.parse("interval:99999999999"));
    try std.testing.expectError(error.InvalidWalSync, W.parse(""));
    try std.testing.expectError(error.InvalidWalSync, W.parse("Group"));
    try std.testing.expectError(error.InvalidWalSync, W.parse("never"));
}

test "Config: the default durability mode is `always`" {
    const c: Config = .{};
    try std.testing.expectEqual(Config.WalSync.always, c.wal_sync);
}
