//! Unit tests for `CoherenceCalculator` (C_tri = C_MF · C_FS · C_SM).
//!
//! These exercise the full set of pairwise coherence functions
//! `matterFormCoherence`, `formSpiritCoherence`,
//! `spiritMatterCoherence`, and `triSourceCoherence` against
//! constructed cells. The goal is to catch regressions in the
//! Jaccard-token-overlap implementation that would silently corrupt
//! the importance ranking.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");

test "CoherenceCalculator: matter-form picks up token overlap" {
    var calc = mem3.coherence.CoherenceCalculator.init(testing.allocator);

    const cell: mem3.MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "the quick brown fox jumps over the lazy dog",
        .atomic_facts = &.{
            .{ .subject = "fox", .predicate = "jumps", .object = "dog", .confidence = 1.0, .source = "user" },
        },
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.5, .priority = 5 },
        },
        .metadata = .{},
    };

    const c_mf = calc.matterFormCoherence(&cell);
    // Episode has 9 unique tokens, atomic_facts have 3 unique tokens
    // ("fox", "jumps", "dog"). Overlap = 3. Union = 9. Jaccard ≈ 0.33.
    try testing.expect(c_mf > 0.2);
    try testing.expect(c_mf < 0.5);
}

test "CoherenceCalculator: form-spirit uses foresight + goals" {
    var calc = mem3.coherence.CoherenceCalculator.init(testing.allocator);

    const cell: mem3.MemCell = .{
        .id = 1,
        .source = .spirit,
        .episode = "x",
        .atomic_facts = &.{
            .{ .subject = "alpha", .predicate = "beta", .object = "gamma", .confidence = 1.0, .source = "user" },
        },
        .foresight = &.{
            .{ .description = "alpha gamma long-term plan", .valid_from = 0, .valid_until = 1, .confidence = 0.9 },
        },
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.7, .priority = 5 },
        },
        .metadata = .{},
    };

    const c_fs = calc.formSpiritCoherence(&cell);
    // atomic_facts tokens: alpha, beta, gamma. foresight tokens: alpha,
    // gamma, long-term, plan. Overlap = 2. Union = 5. Jaccard = 0.4.
    try testing.expect(c_fs > 0.2);
}

test "CoherenceCalculator: triSourceCoherence requires all three sources" {
    var calc = mem3.coherence.CoherenceCalculator.init(testing.allocator);

    const cell: mem3.MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "alpha beta gamma",
        .atomic_facts = &.{},
        .foresight = &.{
            .{ .description = "alpha beta gamma delta", .valid_from = 0, .valid_until = 1, .confidence = 0.9 },
        },
        .goal_associations = &.{},
        .metadata = .{},
    };

    const c_sm = calc.spiritMatterCoherence(&cell);
    const c_mf = calc.matterFormCoherence(&cell);
    const c_fs = calc.formSpiritCoherence(&cell);

    const c_tri = calc.triSourceCoherence(&cell);
    // c_mf = 0 (no atomic_facts), so c_tri = 0 per spec.
    try testing.expectEqual(@as(f32, 0.0), c_tri);

    _ = c_sm;
    _ = c_mf;
    _ = c_fs;
}

test "CoherenceCalculator: updateCell writes back coherence_score" {
    var calc = mem3.coherence.CoherenceCalculator.init(testing.allocator);

    var cell: mem3.MemCell = .{
        .id = 1,
        .source = .spirit,
        .episode = "machine learning algorithms for optimization",
        .atomic_facts = &.{
            .{ .subject = "machine", .predicate = "learns", .object = "patterns", .confidence = 1.0, .source = "user" },
            .{ .subject = "optimization", .predicate = "minimizes", .object = "loss", .confidence = 1.0, .source = "user" },
        },
        .foresight = &.{
            .{ .description = "machine learning will transform industries", .valid_from = 0, .valid_until = 1, .confidence = 0.9 },
        },
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.5, .priority = 5 },
        },
        .metadata = .{},
    };

    const before = cell.metadata.coherence_score;
    const new_score = calc.updateCell(&cell);
    try testing.expect(new_score >= 0.0);
    try testing.expect(new_score <= 1.0);
    // updateCell must write the score back into metadata.
    try testing.expectEqual(new_score, cell.metadata.coherence_score);
    _ = before;
}

test "CoherenceCalculator: completely disjoint text gives ~0" {
    var calc = mem3.coherence.CoherenceCalculator.init(testing.allocator);

    const cell: mem3.MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "apple banana cherry",
        .atomic_facts = &.{
            .{ .subject = "dog", .predicate = "elephant", .object = "frog", .confidence = 1.0, .source = "user" },
        },
        .foresight = &.{},
        .goal_associations = &.{},
        .metadata = .{},
    };

    const c_mf = calc.matterFormCoherence(&cell);
    // No token overlap.
    try testing.expectEqual(@as(f32, 0.0), c_mf);
}