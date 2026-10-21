//! Core type definitions shared across layers.
//!
//! These are POD-ish structs (only `[]const u8` and primitive types) that
//! can be embedded in any other struct without allocation cycles.

const std = @import("std");
const serializer = @import("../utils/serializer.zig");

/// Three-source ontology tag. The constitutional source of truth.
pub const MemorySource = enum(u8) {
    /// Matter — sensory input, environmental observation, raw tool return.
    matter = 0,
    /// Form — reasoning, reflection, abstract knowledge.
    form = 1,
    /// Spirit — meaning, value-direction, goal binding. In dev.md's
    /// vocabulary this also covers "action / behavior" — see ADR-0001.
    spirit = 2,

    /// Parse from a string. Used by the CLI `--source=` flag.
    pub fn fromString(s: []const u8) !MemorySource {
        if (std.mem.eql(u8, s, "matter") or std.mem.eql(u8, s, "m") or std.mem.eql(u8, s, "物")) return .matter;
        if (std.mem.eql(u8, s, "form") or std.mem.eql(u8, s, "f") or std.mem.eql(u8, s, "象")) return .form;
        if (std.mem.eql(u8, s, "spirit") or std.mem.eql(u8, s, "s") or std.mem.eql(u8, s, "性")) return .spirit;
        return error.InvalidSource;
    }

    /// Human-readable name for logs and JSON output.
    pub fn label(self: MemorySource) []const u8 {
        return switch (self) {
            .matter => "matter",
            .form => "form",
            .spirit => "spirit",
        };
    }
};

/// Atomic fact (subject, predicate, object) with confidence + source.
pub const Fact = struct {
    subject: []const u8,
    predicate: []const u8,
    object: []const u8,
    /// [0, 1]
    confidence: f32,
    /// e.g., "user_input", "tool_output", "reflection"
    source: []const u8,

    pub const serialized_size: usize = serializer.calculateSize(Fact);
};

/// Predictive memory: a claim that holds over a time interval.
pub const Foresight = struct {
    description: []const u8,
    /// Unix ms
    valid_from: i64,
    /// Unix ms; `i64.max` means "always (until contradicted)".
    valid_until: i64,
    /// [0, 1]
    confidence: f32,

    pub const serialized_size: usize = serializer.calculateSize(Foresight);
};

/// Binding between a MemCell and a Goal, with relevance + priority.
pub const GoalAssociation = struct {
    goal_id: u64,
    /// [0, 1]
    relevance: f32,
    /// [0, 255]
    priority: u8,

    pub const serialized_size: usize = serializer.calculateSize(GoalAssociation);
};

/// MemCell metadata. All fields are stored together (comptime layout).
pub const Metadata = struct {
    /// Unix ms
    created_at: i64 = 0,
    /// Unix ms
    updated_at: i64 = 0,
    /// Confidence of the source classification [0, 1]. Below 0.5 = reject.
    source_confidence: f32 = 1.0,
    /// [-1, 1]
    emotional_valence: f32 = 0.0,
    location: ?[]const u8 = null,
    access_count: u64 = 0,
    /// Unix ms
    last_accessed_at: i64 = 0,
    /// C_tri (constitution test 1 — every cell has a non-null source; spirit
    /// is tested separately).
    coherence_score: f32 = 0.0,
    /// α·C + β·G + γ·E. Defaults from data-model.md.
    importance_score: f32 = 0.5,
    /// Per-day exponential decay. λ_m > λ_f > λ_s per constitution.
    decay_rate: f32 = 0.01,
    /// Moved to the fuzzy store (read-only with respect to forgetting).
    is_fuzzy: bool = false,
    /// Superseded by another cell (PCR — never deleted, just marked).
    /// Unix ms. Set by conflict resolution (`memory/conflict.zig`); a
    /// superseded cell is excluded from default recall but stays in the
    /// store, and stays readable by `inspect` / `dump`.
    superseded_at: ?i64 = null,
    /// Id of the cell whose arrival superseded this one. Only ever set
    /// together with `superseded_at`; `null` for a `superseded_at` that was
    /// written by a build that did not record the superseder (snapshot v1/v2).
    superseded_by: ?u64 = null,
    /// Set by `mem3 unsupersede`: an operator said this cell is still true
    /// although a newer cell contradicts it. Conflict detection (write-time
    /// and sweep) never supersedes a pinned cell again. Persisted: snapshot
    /// v3 flag bit, and a WAL `memcell_update` record.
    supersede_pinned: bool = false,
    /// When this cell was moved to the fuzzy store.
    fuzzed_at: ?i64 = null,

    pub const serialized_size: usize = serializer.calculateSize(Metadata);
};

/// Status of a node in the Goal Poset.
pub const GoalStatus = enum(u8) {
    pending = 0,
    in_progress = 1,
    completed = 2,
    failed = 3,
    /// Constitution: a goal with no associated memories is "unrealized",
    /// not deleted. After 7 days, a candidate for tombstoning.
    unrealized = 4,
    /// Soft delete. Existing `goal_associations` keep their reference but
    /// the goal contributes 0 to the `goal_bonus` rerank factor.
    tombstoned = 5,
};

/// Type of a hyperedge in HyMem.
pub const EdgeType = enum(u8) {
    /// A caused B
    causal = 0,
    /// A happened before B
    temporal = 1,
    /// A semantically related to B
    associative = 2,
    /// A serves goal G
    goal = 3,

    pub fn label(self: EdgeType) []const u8 {
        return switch (self) {
            .causal => "causal",
            .temporal => "temporal",
            .associative => "associative",
            .goal => "goal",
        };
    }
};

test "MemorySource: fromString accepts multiple aliases" {
    try std.testing.expectEqual(MemorySource.matter, try MemorySource.fromString("matter"));
    try std.testing.expectEqual(MemorySource.matter, try MemorySource.fromString("m"));
    try std.testing.expectEqual(MemorySource.matter, try MemorySource.fromString("物"));
    try std.testing.expectEqual(MemorySource.form, try MemorySource.fromString("form"));
    try std.testing.expectEqual(MemorySource.spirit, try MemorySource.fromString("s"));
    try std.testing.expectError(error.InvalidSource, MemorySource.fromString("x"));
}

test "Fact / Foresight / GoalAssociation / Metadata: default-constructible" {
    const f: Fact = .{ .subject = "a", .predicate = "p", .object = "o", .confidence = 1.0, .source = "x" };
    try std.testing.expectEqualStrings("a", f.subject);
    const m: Metadata = .{};
    try std.testing.expectEqual(@as(f32, 0.5), m.importance_score);
    try std.testing.expect(!m.is_fuzzy);
}
