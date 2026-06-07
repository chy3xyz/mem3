//! Reranker — GHW-prioritized final score.
//!
//! final = base × (1 + 0.4·goal_bonus) × (1 + 0.3·existence_bonus) × (1 + 0.2·recency_bonus)

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const HybridRetriever = @import("hybrid_retriever.zig").HybridRetriever;
const GoalPoset = @import("../ghw/goal_tree.zig").GoalPoset;
const config = @import("../core/config.zig").Config;
const time = @import("../utils/time.zig");

pub const RerankContext = struct {
    alloc: Allocator,
    cfg: config,
    goals: *GoalPoset,
    query_goal_ids: []const u64 = &.{},

    pub fn goalBonus(self: *const RerankContext, cell: *const MemCell) f32 {
        if (cell.goal_associations.len == 0 or self.query_goal_ids.len == 0) return 0.0;
        var max_rel: f32 = 0.0;
        for (cell.goal_associations) |ga| {
            for (self.query_goal_ids) |qg| {
                if (ga.goal_id == qg and ga.relevance > max_rel) {
                    max_rel = ga.relevance;
                }
            }
        }
        return max_rel;
    }

    pub fn existenceBonus(self: *const RerankContext, cell: *const MemCell) f32 {
        _ = self;
        return cell.metadata.importance_score;
    }

    pub fn recencyBonus(self: *const RerankContext, cell: *const MemCell) f32 {
        _ = self;
        const now = time.nowMs();
        if (now <= cell.metadata.created_at) return 1.0;
        const age_ms: f32 = @as(f32, @floatFromInt(now - cell.metadata.created_at));
        const age_days: f32 = age_ms / 86_400_000.0;
        return @exp(-cell.metadata.decay_rate * age_days);
    }

    /// Compose the final reranked score.
    pub fn finalScore(self: *const RerankContext, base: f32, cell: *const MemCell) f32 {
        const goal = self.goalBonus(cell);
        const existence = self.existenceBonus(cell);
        const recency = self.recencyBonus(cell);
        return base *
            (1.0 + self.cfg.goal_bonus_weight * goal) *
            (1.0 + self.cfg.existence_bonus_weight * existence) *
            (1.0 + self.cfg.recency_bonus_weight * recency);
    }

    /// Rerank a list of candidate (cell_id, base_score) pairs against
    /// actual MemCells, returning sorted results.
    pub fn rerank(
        self: *RerankContext,
        alloc: Allocator,
        candidates: []const HybridRetriever.Candidate,
        cells_lookup: *const fn (u64) ?*const MemCell,
    ) ![]ScoredCell {
        var scored = std.ArrayList(ScoredCell).empty;
        defer scored.deinit(alloc);
        for (candidates) |c| {
            const cell = cells_lookup(c.cell_id) orelse continue;
            const base = c.combined(self.cfg);
            const final = self.finalScore(base, cell);
            try scored.append(alloc, .{ .cell = cell, .base_score = base, .final_score = final });
        }
        std.mem.sort(ScoredCell, scored.items, {}, struct {
            fn lt(_: void, a: ScoredCell, b: ScoredCell) bool {
                return a.final_score > b.final_score;
            }
        }.lt);
        return scored.toOwnedSlice(alloc);
    }
};

pub const ScoredCell = struct {
    cell: *const MemCell,
    base_score: f32,
    final_score: f32,
};

// =============================================================================
// Tests
// =============================================================================

test "RerankContext: goal bonus matches max relevance" {
    var goals = GoalPoset.init(std.testing.allocator);
    defer goals.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const g1 = try goals.create("g1", "", null, 5, null, 0, &next);
    _ = try goals.create("g2", "", null, 5, null, 0, &next);

    const ctx: RerankContext = .{
        .alloc = std.testing.allocator,
        .cfg = .{},
        .goals = &goals,
        .query_goal_ids = &.{ g1 },
    };

    const cell: MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "x",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = g1, .relevance = 0.7, .priority = 5 },
            .{ .goal_id = 999, .relevance = 0.9, .priority = 5 },
        },
        .metadata = .{ .source_confidence = 0.9 },
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), ctx.goalBonus(&cell), 1e-6);
}

test "RerankContext: finalScore respects all factors" {
    var goals = GoalPoset.init(std.testing.allocator);
    defer goals.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const g = try goals.create("g", "", null, 5, null, 0, &next);

    const ctx: RerankContext = .{
        .alloc = std.testing.allocator,
        .cfg = .{},
        .goals = &goals,
        .query_goal_ids = &.{g},
    };

    const cell: MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "x",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{ .{ .goal_id = g, .relevance = 1.0, .priority = 9 } },
        .metadata = .{
            .source_confidence = 0.9,
            .importance_score = 1.0,
            .decay_rate = 0.0,
        },
    };

    // base=1.0, goal=1.0, existence=1.0, recency=1.0
    // final = 1.0 * (1 + 0.4*1) * (1 + 0.3*1) * (1 + 0.2*1) = 1.4 * 1.3 * 1.2 = 2.184
    const final = ctx.finalScore(1.0, &cell);
    try std.testing.expectApproxEqAbs(@as(f32, 2.184), final, 0.01);
}
