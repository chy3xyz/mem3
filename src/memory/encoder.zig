//! Memory encoder — converts raw inputs into TS-MemCells.
//!
//! **GHW Layer**: Memory (三源合恰). Implements the Encoding stage of
//! the four-stage lifecycle (per the paper §4.3.1).
//!
//! ## Constitution compliance
//! - Principle I (三源完整性): source_tag is mandatory.
//! - Principle III (存在增益驱动): importance_score is computed here using
//!   the constitutional formula `α·source_coherence + β·goal_relevance +
//!   γ·existential_contribution`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const Fact = core.Fact;
const Foresight = core.Foresight;
const GoalAssociation = core.GoalAssociation;
const MemorySource = core.MemorySource;
const Metadata = core.Metadata;
const errors = core.Error;
const time = @import("../utils/time.zig");
const config = @import("../core/config.zig").Config;

/// Raw input to be encoded into a MemCell.
pub const RawInput = struct {
    source: MemorySource,
    episode: []const u8,
    atomic_facts: []const Fact = &.{},
    foresight: []const Foresight = &.{},
    goal_associations: []const GoalAssociation = &.{},
    /// Optional override; otherwise computed by the encoder.
    source_confidence: f32 = 1.0,
    /// Optional location tag.
    location: ?[]const u8 = null,
};

pub const Encoder = struct {
    alloc: Allocator,
    cfg: config,

    pub fn init(alloc: Allocator, cfg: config) Encoder {
        return .{ .alloc = alloc, .cfg = cfg };
    }

    /// Encode a raw input into a TS-MemCell with all constitutional
    /// invariants validated and the importance score computed.
    ///
    /// **v0.1.0 zero-copy**: the returned MemCell references slices from
    /// `input` directly. `input.episode`, `input.atomic_facts[i].*`,
    /// `input.foresight[i].description` must outlive the MemCell. The CLI
    /// ensures this by holding the parsed lists in the same scope.
    pub fn encode(self: *Encoder, input: RawInput) errors!MemCell {
        if (input.episode.len == 0) return errors.EmptyEpisode;
        if (input.foresight.len == 0 and input.goal_associations.len == 0) {
            return errors.SpiritDimMissing;
        }
        if (input.source_confidence < 0.5) return errors.SourceConfidenceTooLow;

        const now = time.nowMs();
        const importance = self.computeImportance(input, now);
        const meta = Metadata{
            .created_at = now,
            .updated_at = now,
            .source_confidence = input.source_confidence,
            .emotional_valence = 0.0,
            .location = input.location, // zero-copy: caller owns
            .access_count = 0,
            .last_accessed_at = now,
            .coherence_score = 0.0, // updated by the coherence calculator
            .importance_score = importance,
            .decay_rate = self.cfg.decayRateFor(input.source),
            .is_fuzzy = false,
        };

        return .{
            .id = 0, // assigned by TriSourceManager
            .source = input.source,
            .episode = input.episode,
            .atomic_facts = input.atomic_facts,
            .foresight = input.foresight,
            .goal_associations = input.goal_associations,
            .metadata = meta,
        };
    }

    /// Compute the importance score using the constitutional formula.
    /// - source_coherence: 1.0 for fresh single-source cells (will be
    ///   updated by the coherence calculator when the cell joins a cluster)
    /// - goal_relevance: max of relevance across goal_associations
    /// - existential_contribution: heuristic based on # of atomic facts
    pub fn computeImportance(self: *Encoder, input: RawInput, now_ms: i64) f32 {
        const source_coherence: f32 = 1.0; // default; updated by coherence.zig
        const goal_relevance: f32 = blk: {
            if (input.goal_associations.len == 0) break :blk 0.0;
            var max_rel: f32 = 0.0;
            for (input.goal_associations) |g| {
                if (g.relevance > max_rel) max_rel = g.relevance;
            }
            break :blk max_rel;
        };
        const existential: f32 = blk: {
            // Heuristic: 1.0 if foresight has any entry with valid_until
            // in the future, else 0.5 if facts present, else 0.2.
            for (input.foresight) |f| {
                if (f.valid_until > now_ms) break :blk 1.0;
            }
            if (input.atomic_facts.len > 0) break :blk 0.5;
            break :blk 0.2;
        };

        const score = self.cfg.importance_alpha * source_coherence +
            self.cfg.importance_beta * goal_relevance +
            self.cfg.importance_gamma * existential;
        return std.math.clamp(score, 0.0, 1.0);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Encoder: encode valid cell" {
    const alloc = std.testing.allocator;
    var enc = Encoder.init(alloc, .{});
    const input: RawInput = .{
        .source = .spirit,
        .episode = "test",
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.8, .priority = 9 },
        },
        .foresight = &.{
            .{ .description = "future", .valid_from = 0, .valid_until = std.math.maxInt(i64), .confidence = 0.9 },
        },
    };
    const cell = try enc.encode(input);
    // Encode is zero-copy: cell.episode aliases input.episode (a string
    // literal in this test). Don't free it.
    try std.testing.expect(cell.metadata.importance_score > 0.3);
    try std.testing.expect(cell.metadata.decay_rate > 0.0);
}

test "Encoder: rejects empty episode" {
    var enc = Encoder.init(std.testing.allocator, .{});
    const input: RawInput = .{
        .source = .matter,
        .episode = "",
        .goal_associations = &.{ .{ .goal_id = 1, .relevance = 0.5, .priority = 5 } },
    };
    try std.testing.expectError(errors.EmptyEpisode, enc.encode(input));
}

test "Encoder: rejects spirit-dim-missing" {
    var enc = Encoder.init(std.testing.allocator, .{});
    const input: RawInput = .{
        .source = .matter,
        .episode = "x",
    };
    try std.testing.expectError(errors.SpiritDimMissing, enc.encode(input));
}

test "Encoder: importance score respects formula" {
    const alloc = std.testing.allocator;
    var enc = Encoder.init(alloc, .{});
    const future_ts = time.nowMs() + 86_400_000;

    // High: high goal relevance + future foresight
    const high = enc.computeImportance(.{
        .source = .spirit,
        .episode = "x",
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.9, .priority = 9 },
        },
        .foresight = &.{
            .{ .description = "y", .valid_from = 0, .valid_until = future_ts, .confidence = 0.9 },
        },
    }, time.nowMs());

    // Low: no goals, no foresight, no facts
    const low = enc.computeImportance(.{
        .source = .matter,
        .episode = "x",
    }, time.nowMs());

    try std.testing.expect(high > low);
    try std.testing.expect(high <= 1.0);
    try std.testing.expect(low >= 0.0);
}
