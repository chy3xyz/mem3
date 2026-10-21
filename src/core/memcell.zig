//! Core types: TS-MemCell 7-tuple and its component structs.
//!
//! **GHW Layer**: foundation layer. Touches all three layers because
//! MemCell is the unit of memory across the system.
//!
//! **Constitution compliance**:
//! - Principle I (Tri-Source Integrity): `MemorySource` enum enforces tagging.
//! - Principle V (zero-copy): comptime `serialized_size`.
//! - All structs use explicit allocators, no globals.

const std = @import("std");
const types = @import("types.zig");
const serializer = @import("../utils/serializer.zig");

pub const MemorySource = types.MemorySource;
pub const Fact = types.Fact;
pub const Foresight = types.Foresight;
pub const GoalAssociation = types.GoalAssociation;
pub const Metadata = types.Metadata;
pub const GoalStatus = types.GoalStatus;
pub const EdgeType = types.EdgeType;

/// TS-MemCell — Tri-Source Memory Cell (7-tuple).
///
/// Field order matches the paper (ghw_memory_system.agent.final.md §4.1.1).
/// Storage layout: fields are emitted in declaration order by the comptime
/// serializer.
pub const MemCell = struct {
    /// Globally unique, monotonically increasing id (1-based; 0 is reserved).
    id: u64,
    /// The ontological source (matter/form/spirit). CONSTITUTIONAL: must be set.
    source: MemorySource,
    /// Matter: raw episode, causally efficacious trace.
    episode: []const u8,
    /// Form: extracted atomic facts.
    atomic_facts: []const Fact,
    /// Spirit: predictive memories with time validity.
    foresight: []const Foresight,
    /// Spirit: goal bindings with relevance + priority.
    goal_associations: []const GoalAssociation,
    /// Metadata: timestamps, scores, decay rate, fuzzy flag.
    metadata: Metadata,

    /// Comptime-computed serialized size. Used by the WAL and SSTable
    /// for record-offset arithmetic.
    pub const serialized_size: usize = serializer.calculateSize(MemCell);

    /// Free all heap-allocated slices owned by this MemCell.
    /// This is a "full deinit" — releases episode, atomic_facts[i].*,
    /// foresight[i].description, the container slices, and the
    /// `metadata.location` string. Used by tests and by managers that
    /// dup the cell on insertion.
    pub fn deinit(self: *const MemCell, alloc: std.mem.Allocator) void {
        alloc.free(@constCast(self.episode));
        for (self.atomic_facts) |f| {
            alloc.free(@constCast(f.subject));
            alloc.free(@constCast(f.predicate));
            alloc.free(@constCast(f.object));
            alloc.free(@constCast(f.source));
        }
        alloc.free(@constCast(self.atomic_facts));
        for (self.foresight) |f| {
            alloc.free(@constCast(f.description));
        }
        alloc.free(@constCast(self.foresight));
        alloc.free(@constCast(self.goal_associations));
        if (self.metadata.location) |loc| alloc.free(@constCast(loc));
    }

    /// Touch the cell (bump updated_at, recency, frequency). Used on read access.
    pub fn touch(self: *MemCell, now_ms: i64) void {
        self.metadata.updated_at = now_ms;
        self.metadata.last_accessed_at = now_ms;
        self.metadata.access_count += 1;
    }

    /// Combined weight used for memory lifecycle decisions.
    /// Per the paper: `importance` × 0.5 + `coherence` × 0.3 + `freshness` × 0.2.
    /// We use the constitutional weights from `metadata.importance_score`,
    /// `metadata.coherence_score`, and a recency decay based on age.
    pub fn getWeight(self: *const MemCell, now_ms: i64) f32 {
        const age_ms: i64 = if (now_ms > self.metadata.created_at)
            now_ms - self.metadata.created_at
        else
            0;
        const age_days: f32 = @as(f32, @floatFromInt(age_ms)) / (1000.0 * 86400.0);
        const decay: f32 = @exp(-self.metadata.decay_rate * age_days);
        return self.metadata.importance_score * 0.5 +
            self.metadata.coherence_score * 0.3 +
            decay * 0.2;
    }

    /// Three-source coherence: C_tri = C_MF · C_FS · C_SM.
    /// Caller provides the per-pair cosine similarities.
    /// Returns 0.0 if any source is empty (degenerate case).
    pub fn triSourceCoherence(c_mf: f32, c_fs: f32, c_sm: f32) f32 {
        if (c_mf <= 0.0 or c_fs <= 0.0 or c_sm <= 0.0) return 0.0;
        return c_mf * c_fs * c_sm;
    }
};

test "MemCell: trivial construction" {
    const cell: MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "test episode",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{},
        .metadata = .{},
    };
    try std.testing.expectEqual(@as(u64, 1), cell.id);
    try std.testing.expectEqual(MemorySource.matter, cell.source);
}

test "MemCell: triSourceCoherence degenerate (zero) returns 0" {
    try std.testing.expectEqual(@as(f32, 0.0), MemCell.triSourceCoherence(0.0, 0.5, 0.5));
    try std.testing.expectEqual(@as(f32, 0.0), MemCell.triSourceCoherence(0.5, -0.1, 0.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), MemCell.triSourceCoherence(0.5, 0.5, 0.5), 1e-6);
}

test "MemCell: getWeight monotonically decays with age" {
    var cell: MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "x",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{},
        .metadata = .{
            .created_at = 0,
            .importance_score = 0.8,
            .coherence_score = 0.6,
            .decay_rate = 0.1,
        },
    };
    const w0 = cell.getWeight(0);
    const w1 = cell.getWeight(86_400_000); // 1 day later
    try std.testing.expect(w0 > w1);
}
