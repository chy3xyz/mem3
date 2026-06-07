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

    pub const EmbedderKind = enum {
        /// Deterministic hash-based stub (v0.1.0 default; ~zero deps).
        stub_xxhash,
        /// Reserved for v0.2.0 (ONNX model load).
        onnx_external,
    };

    pub const LogFormat = enum {
        human,
        jsonl,
        silent,
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
