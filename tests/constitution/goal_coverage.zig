//! Constitution Invariant III: every active goal has ≥ 1 associated MemCell,
//! or is marked `unrealized`.
//!
//! Per `.specify/memory/constitution.md` and `spec.md` FR-027:
//!   - Goals are not "declaration only" — they MUST connect to memories.
//!   - A goal with no memories is "unrealized" (status flag).
//!   - After 7 days as `unrealized`, a goal is a candidate for tombstoning.
//!   - A tombstoned goal keeps its `goal_associations` but contributes 0
//!     to the `goal_bonus` rerank factor.
//!
//! An earlier version of this file defined its own `isValid` predicate three
//! lines above the assertion that tested it, and "verified" the tombstone
//! rule by reading back a struct literal it had just written. Both passed
//! unconditionally while the production code could do the opposite. Every
//! test below now drives the real `GoalPoset` / `RerankContext`.

const std = @import("std");
const mem3 = @import("mem3");

const testing = std.testing;

const DAY_MS: i64 = 86_400_000;

// ---------------------------------------------------------------------------
// The core invariant: an aged goal with no memories is marked `unrealized`,
// and one that *does* have memories is left alone.
// ---------------------------------------------------------------------------
test "constitution III: a goal with no memories ages into unrealized; one with memories does not" {
    var poset = mem3.GoalPoset.init(testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const now: i64 = 1_000_000_000_000;

    const orphan = try poset.create("orphan", "no memories", null, 5, null, now, &next);
    const attached = try poset.create("attached", "has a memory", null, 5, null, now, &next);
    try poset.bindMemcell(attached, 42);

    // Before the 7-day grace period, nothing happens to either goal.
    try testing.expectEqual(@as(usize, 0), try poset.evaluateMetaGoals(now + 6 * DAY_MS));
    try testing.expectEqual(mem3.GoalStatus.pending, poset.get(orphan).?.status);
    try testing.expectEqual(mem3.GoalStatus.pending, poset.get(attached).?.status);

    // Past it, only the goal with no memories is affected.
    const marked = try poset.evaluateMetaGoals(now + 8 * DAY_MS);
    try testing.expectEqual(@as(usize, 1), marked);
    try testing.expectEqual(mem3.GoalStatus.unrealized, poset.get(orphan).?.status);
    try testing.expectEqual(mem3.GoalStatus.pending, poset.get(attached).?.status);
}

// ---------------------------------------------------------------------------
// The 7-day rule gates tombstoning, in both directions.
// ---------------------------------------------------------------------------
test "constitution III: tombstoning requires 7 days as unrealized" {
    var poset = mem3.GoalPoset.init(testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const now: i64 = 1_000_000_000_000;

    const g = try poset.create("g", "d", null, 5, null, now, &next);
    try poset.updateStatus(g, .unrealized, now);

    // Too early.
    try testing.expectError(mem3.Error.GoalCycle, poset.updateStatus(g, .tombstoned, now + DAY_MS));
    try testing.expectEqual(mem3.GoalStatus.unrealized, poset.get(g).?.status);

    // Long enough. This must be the real transition, not a no-op.
    try poset.updateStatus(g, .tombstoned, now + 8 * DAY_MS);
    try testing.expectEqual(mem3.GoalStatus.tombstoned, poset.get(g).?.status);

    // A goal that was never unrealized cannot be tombstoned at all.
    const h = try poset.create("h", "d", null, 5, null, now, &next);
    try testing.expectError(mem3.Error.GoalCycle, poset.updateStatus(h, .tombstoned, now + 400 * DAY_MS));
}

// ---------------------------------------------------------------------------
// The rerank clause. `RerankContext.goalBonus` did not consult the poset at
// all, so a tombstoned goal boosted its cells at full relevance; the claim in
// `types.zig` was documented but unimplemented.
// ---------------------------------------------------------------------------
test "constitution III: a tombstoned goal keeps its associations but contributes 0 to goal_bonus" {
    var poset = mem3.GoalPoset.init(testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const now: i64 = 1_000_000_000_000;

    const g = try poset.create("g", "d", null, 5, null, now, &next);
    const other = try poset.create("other", "d", null, 5, null, now, &next);

    const cell: mem3.MemCell = .{
        .id = 1,
        .source = .spirit,
        .episode = "x",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = g, .relevance = 0.9, .priority = 9 },
            .{ .goal_id = other, .relevance = 0.4, .priority = 1 },
        },
        .metadata = .{},
    };

    const ctx: mem3.RerankContext = .{
        .alloc = testing.allocator,
        .cfg = .{},
        .goals = &poset,
        .query_goal_ids = &.{ g },
    };

    // Live goal: the association drives the bonus.
    try testing.expectApproxEqAbs(@as(f32, 0.9), ctx.goalBonus(&cell), 1e-6);

    try poset.updateStatus(g, .unrealized, now);
    try poset.updateStatus(g, .tombstoned, now + 8 * DAY_MS);

    // Tombstoned: zero, even though the association is still on the cell.
    try testing.expectApproxEqAbs(@as(f32, 0.0), ctx.goalBonus(&cell), 1e-6);
    try testing.expectEqual(g, cell.goal_associations[0].goal_id);

    // An id the poset never held is worth zero too — the reference points at
    // nothing, so there is no priority to apply.
    const dangling: mem3.RerankContext = .{
        .alloc = testing.allocator,
        .cfg = .{},
        .goals = &poset,
        .query_goal_ids = &.{ 4242 },
    };
    try testing.expectApproxEqAbs(@as(f32, 0.0), dangling.goalBonus(&cell), 1e-6);
}

// ---------------------------------------------------------------------------
// Coverage guard. The previous version asserted `statuses.len == 6` on an
// array hardcoded in the test file, so adding a variant to `GoalStatus` left
// it green. This reflects on the real enum instead.
// ---------------------------------------------------------------------------
test "constitution III: GoalStatus exposes exactly the expected variants" {
    const expected = [_][]const u8{
        "pending",
        "in_progress",
        "completed",
        "failed",
        "unrealized",
        "tombstoned",
    };

    var seen: usize = 0;
    switch (@typeInfo(mem3.GoalStatus)) {
        // Zig 0.17 exposes `field_names: []const [:0]const u8` here; the
        // `fields: []Field` shape from 0.13/0.14 no longer exists.
        .@"enum" => |e| {
            try testing.expectEqual(expected.len, e.field_names.len);
            for (e.field_names, expected) |actual, want| {
                try testing.expectEqualStrings(want, actual);
                seen += 1;
            }
        },
        else => return error.GoalStatusIsNotAnEnum,
    }
    try testing.expectEqual(expected.len, seen);

    // Every variant must be reachable by name, since the CLI parses statuses
    // with `stringToEnum` and prints this exact list on failure.
    for (expected) |name| {
        try testing.expect(std.meta.stringToEnum(mem3.GoalStatus, name) != null);
    }
}
