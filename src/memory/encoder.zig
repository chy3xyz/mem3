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
//!
//! ## The β=0.40 term is now the Goal layer's answer, not the caller's
//!
//! `goal_relevance` used to be `max(relevance)` over caller-supplied
//! values. The Goal Poset was never consulted, so a goal that had been
//! tombstoned scored exactly like a live one and the single largest
//! weight in the constitutional formula was a number the caller typed.
//! Meanwhile `retrieval/reranker.zig`'s `goalBonus` *did* consult the
//! poset — so encoding and retrieval disagreed about whether a goal was
//! alive, which is exactly the split-half of Principle III (PCR) that the
//! constitution forbids.
//!
//! `Encoder.goals` is the fix point. Set it (once, at Store construction —
//! `store.lc.encoder.goals = store.goals`) and the β term reads the live
//! poset through `goalRelevance`, which mirrors `Store.goalRelevance`
//! status for status.
//!
//! ## Why this file holds the rule and not `retrieval/`
//!
//! There are now two code paths that decide "is this goal alive" —
//! `RerankContext.goalBonus` and `Encoder.goalRelevance` — and three
//! would be worse. `retrieval/` cannot be imported from `memory/`
//! without inverting the dependency order (it is already downstream of
//! `core/`), and `store/` cannot be imported here at all because
//! `store/` imports `memory/`. So the shared statement lives here and
//! `retrieval/` keeps its own; `test "…liveness matches goalBonus…"`
//! below is the guard that keeps the two from drifting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const GoalPoset = @import("../ghw/goal_tree.zig").GoalPoset;
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

    /// Layer 1 of GHW. Borrowed, not owned — the `Store` that owns the
    /// poset outlives the `Lifecycle` that owns this `Encoder`.
    ///
    /// `null` means no Goal layer was wired in, and the β term then falls
    /// back to the caller's stated relevance. That fallback is the
    /// pre-fix behaviour and it is why the bug survived: a caller with
    /// no poset attached cannot tell a live goal from a retired one.
    goals: ?*GoalPoset = null,

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

    /// The Goal layer's answer to "how relevant is this goal", as the
    /// β=0.40 term of `importance_score` must use it.
    ///
    /// Mirrors `Store.goalRelevance` status for status — that is the
    /// canonical statement, this is the copy `store/` cannot reach:
    /// `store/` imports `memory/`, so `memory/encoder.zig` may not import
    /// it back. If the two ever disagree, that copy is the one to fix
    /// here, and `test "Encoder: goal liveness matches goalBonus on every
    /// GoalStatus"` is what catches it.
    ///
    /// With no poset attached (`goals == null`) this returns `stated`,
    /// preserving the old behaviour for embedders that construct an
    /// `Encoder` standalone. That fallback is a documented hole, not a
    /// silent one: it is exactly the condition under which a tombstoned
    /// goal scores like a live one.
    pub fn goalRelevance(self: *const Encoder, goal_id: u64, stated: f32) f32 {
        const goals = self.goals orelse return stated;
        const node = goals.get(goal_id) orelse return 0.0;
        return switch (node.status) {
            // A retired goal carries no priority — the same rule
            // `RerankContext.goalBonus` applies.
            .tombstoned => 0.0,
            // Achieved: the goal still grounds its memories, but it is
            // no longer pulling the agent forward.
            .completed => stated * 0.5,
            // In flight outranks not-yet-started.
            .in_progress => @min(1.0, stated * 1.2),
            .pending, .failed, .unrealized => stated,
        };
    }

    /// Compute the importance score using the constitutional formula.
    /// - source_coherence: 1.0 for fresh single-source cells (will be
    ///   updated by the coherence calculator when the cell joins a cluster)
    /// - goal_relevance: max of relevance across goal_associations, each
    ///   run through `goalRelevance` so the Goal layer gets a veto on
    ///   goals it has retired
    /// - existential_contribution: heuristic based on # of atomic facts
    pub fn computeImportance(self: *Encoder, input: RawInput, now_ms: i64) f32 {
        const source_coherence: f32 = 1.0; // default; updated by coherence.zig
        const goal_relevance: f32 = blk: {
            if (input.goal_associations.len == 0) break :blk 0.0;
            var max_rel: f32 = 0.0;
            for (input.goal_associations) |g| {
                // Not `g.relevance`: a tombstoned goal contributes 0 and
                // must not be able to win this max() on a high stated
                // number.
                const rel = self.goalRelevance(g.goal_id, g.relevance);
                if (rel > max_rel) max_rel = rel;
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

// =============================================================================
// Goal-layer consultation of the β=0.40 term
//
// These fail if the poset is ignored. Each asserts the *liveness
// decision* for a goal in a known state, not that some call happened.
// =============================================================================

/// Build a one-goal poset in a known state. Returns the goal id.
///
/// Kept as a helper rather than inlined so each test owns its own
/// `GoalPoset` and therefore its own deinit — no shared fixture, no
/// `/tmp`, no cross-run state.
///
/// The status is reached through `updateStatus`, which enforces the real
/// transition rules, rather than by assigning `node.status` behind the
/// poset's back: a goal must be `.unrealized` for ≥7 days before it may
/// be tombstoned, and a test that pokes internals would prove nothing
/// about the rule it claims to cover.
fn goalInState(
    poset: *GoalPoset,
    ids: *std.atomic.Value(u64),
    status: core.GoalStatus,
) !u64 {
    const t0: i64 = 1_700_000_000_000;
    const gid = try poset.create("g", "", null, 5, null, t0, ids);
    switch (status) {
        .pending => {},
        .in_progress, .completed, .failed, .unrealized => {
            try poset.updateStatus(gid, status, t0);
        },
        .tombstoned => {
            try poset.updateStatus(gid, .unrealized, t0);
            try poset.updateStatus(gid, .tombstoned, t0 + 8 * 86_400_000);
        },
    }
    return gid;
}

test "Encoder: goal_relevance consults the Goal Poset — a live goal keeps its relevance" {
    const alloc = std.testing.allocator;
    var poset = GoalPoset.init(alloc);
    defer poset.deinit();
    var ids: std.atomic.Value(u64) = .init(1);

    const gid = try goalInState(&poset, &ids, .pending);
    var enc = Encoder.init(alloc, .{});
    enc.goals = &poset;

    try std.testing.expectApproxEqAbs(@as(f32, 0.7), enc.goalRelevance(gid, 0.7), 1e-6);

    // And the same value reaches importance_score through β=0.40, so
    // this is not a helper nothing calls.
    const score = enc.computeImportance(.{
        .source = .spirit,
        .episode = "x",
        .goal_associations = &.{.{ .goal_id = gid, .relevance = 0.7, .priority = 5 }},
    }, time.nowMs());
    // 0.30*1.0 + 0.40*0.7 + 0.30*0.2 (no facts, no future foresight)
    try std.testing.expectApproxEqAbs(@as(f32, 0.64), score, 1e-4);
}

test "Encoder: a tombstoned goal contributes 0 — the regression that matters" {
    const alloc = std.testing.allocator;
    var poset = GoalPoset.init(alloc);
    defer poset.deinit();
    var ids: std.atomic.Value(u64) = .init(1);

    const retired = try goalInState(&poset, &ids, .tombstoned);
    var enc = Encoder.init(alloc, .{});
    enc.goals = &poset;

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), enc.goalRelevance(retired, 0.9), 1e-6);

    // The property: a cell bound only to a retired goal scores the same
    // as a cell bound to no goal at all. Before the poset was consulted
    // it scored *higher* than no-goal, because β multiplied a number the
    // caller typed about a goal the system had already retired.
    const tombstoned_score = enc.computeImportance(.{
        .source = .spirit,
        .episode = "x",
        .goal_associations = &.{.{ .goal_id = retired, .relevance = 0.9, .priority = 5 }},
    }, time.nowMs());
    const no_goal_score = enc.computeImportance(.{
        .source = .spirit,
        .episode = "x",
        .foresight = &.{.{ .description = "f", .valid_from = 0, .valid_until = 1, .confidence = 0.1 }},
    }, time.nowMs());
    try std.testing.expectApproxEqAbs(no_goal_score, tombstoned_score, 1e-6);

    // A retired goal must not be able to win the max() either, even when
    // a live sibling carries a lower stated relevance.
    var both = GoalPoset.init(alloc);
    defer both.deinit();
    const live = try goalInState(&both, &ids, .pending);
    var enc2 = Encoder.init(alloc, .{});
    enc2.goals = &both;
    const other_retired = try goalInState(&both, &ids, .tombstoned);
    const mixed = enc2.computeImportance(.{
        .source = .spirit,
        .episode = "x",
        .goal_associations = &.{
            .{ .goal_id = live, .relevance = 0.2, .priority = 5 },
            .{ .goal_id = other_retired, .relevance = 0.99, .priority = 5 },
        },
    }, time.nowMs());
    const live_only = enc2.computeImportance(.{
        .source = .spirit,
        .episode = "x",
        .goal_associations = &.{.{ .goal_id = live, .relevance = 0.2, .priority = 5 }},
    }, time.nowMs());
    try std.testing.expectApproxEqAbs(live_only, mixed, 1e-6);
}

test "Encoder: an unrealized goal is still live — same call the reranker makes" {
    const alloc = std.testing.allocator;
    var poset = GoalPoset.init(alloc);
    defer poset.deinit();
    var ids: std.atomic.Value(u64) = .init(1);

    const stalled = try goalInState(&poset, &ids, .unrealized);
    var enc = Encoder.init(alloc, .{});
    enc.goals = &poset;

    // `.unrealized` means the goal is not pulling the agent forward, but
    // it has not been retired: the poset will revive it, and PCR keeps
    // its memories. Both `goalBonus` and `Store.goalRelevance` still
    // score it, and so does this — a third rule here (unrealized → 0)
    // would re-open exactly the encode/retrieve split this change closed.
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), enc.goalRelevance(stalled, 0.6), 1e-6);
}

test "Encoder: a goal the poset does not hold contributes 0" {
    const alloc = std.testing.allocator;
    var poset = GoalPoset.init(alloc);
    defer poset.deinit();
    var enc = Encoder.init(alloc, .{});
    enc.goals = &poset;
    // The reference points at a goal that no longer exists, so there is
    // no priority to apply — same as `goalBonus`'s `orelse continue`.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), enc.goalRelevance(4242, 1.0), 1e-6);
}

test "Encoder: goal liveness matches goalBonus on every GoalStatus" {
    // The tie between the two halves of Principle III. `retrieval/` is
    // downstream of `core/` and imports nothing from `memory/`, so this
    // import introduces no cycle; it is function-local so the
    // non-test build of `memory/encoder.zig` does not pull it in.
    const RerankContext = @import("../retrieval/reranker.zig").RerankContext;

    const alloc = std.testing.allocator;
    var poset = GoalPoset.init(alloc);
    defer poset.deinit();
    var ids: std.atomic.Value(u64) = .init(1);

    const statuses = [_]core.GoalStatus{
        .pending,      .in_progress,  .completed,
        .failed,       .unrealized,   .tombstoned,
    };

    var enc = Encoder.init(alloc, .{});
    enc.goals = &poset;

    for (statuses) |status| {
        const gid = try goalInState(&poset, &ids, status);
        const stated: f32 = 0.7;

        const cell: MemCell = .{
            .id = 1,
            .source = .matter,
            .episode = "x",
            .atomic_facts = &.{},
            .foresight = &.{},
            .goal_associations = &.{.{ .goal_id = gid, .relevance = stated, .priority = 5 }},
            .metadata = .{ .source_confidence = 0.9 },
        };
        const rr: RerankContext = .{
            .alloc = alloc,
            .cfg = .{},
            .goals = &poset,
            .query_goal_ids = &.{gid},
        };

        const enc_relevance = enc.goalRelevance(gid, stated);
        const bonus = rr.goalBonus(&cell);

        // Same liveness decision: dead is dead, live is live. This is
        // the assertion that matters — the two functions are allowed to
        // disagree on *weight* (`completed` is halved here and not in
        // `goalBonus`), because PCR only says a retired goal must stop
        // counting, not that the two paths must agree to the digit.
        try std.testing.expect(
            (enc_relevance == 0.0) == (bonus == 0.0),
        );
        // And a live goal still scores: neither path may silently zero
        // a goal both consider active.
        if (status != .tombstoned) {
            try std.testing.expect(enc_relevance > 0.0);
            try std.testing.expect(bonus > 0.0);
        }
    }
}

test "Encoder: with no Goal layer attached the stated relevance is used" {
    // Documents the fallback rather than hiding it. A caller that never
    // wires `goals` gets the pre-fix behaviour, which is why the wiring
    // has to happen at Store construction rather than per call site.
    const alloc = std.testing.allocator;
    var enc = Encoder.init(alloc, .{});
    try std.testing.expect(enc.goals == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), enc.goalRelevance(1, 0.9), 1e-6);
}
