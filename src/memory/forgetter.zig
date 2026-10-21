//! Existence-gain-driven forgetting.
//!
//! **GHW Layer**: Memory (tri-source coherence). Implements the Forgetting stage of
//! the four-stage lifecycle (per the paper §4.3.4).
//!
//! ## Constitution compliance
//! - Principle III (existence-gain-driven lifecycle): a memory is forgotten when
//!   `net_existence = importance - redundancy - conflict_score < 0`.
//! - PCR: never delete; mark `is_fuzzy = true` and move to fuzzy store.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const TriSourceManager = @import("tri_source_manager.zig").TriSourceManager;
const time = @import("../utils/time.zig");
const config = @import("../core/config.zig").Config;
const errors = core.Error;

pub const FuzzyStore = struct {
    alloc: Allocator,
    /// Cells demoted to fuzzy. Keyed by original id.
    cells: std.AutoHashMap(u64, *MemCell),

    pub fn init(alloc: Allocator) FuzzyStore {
        return .{
            .alloc = alloc,
            .cells = std.AutoHashMap(u64, *MemCell).init(alloc),
        };
    }

    pub fn deinit(self: *FuzzyStore) void {
        var it = self.cells.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.cells.deinit();
    }

    pub fn transfer(self: *FuzzyStore, cell: *MemCell) !void {
        cell.metadata.is_fuzzy = true;
        cell.metadata.fuzzed_at = time.nowMs();
        try self.cells.put(cell.id, cell);
    }

    pub fn promote(self: *FuzzyStore, id: u64) ?*MemCell {
        if (self.cells.fetchRemove(id)) |kv| {
            kv.value.metadata.is_fuzzy = false;
            kv.value.metadata.fuzzed_at = null;
            return kv.value;
        }
        return null;
    }

    pub fn count(self: *const FuzzyStore) usize {
        return self.cells.count();
    }
};

pub const Forgetter = struct {
    alloc: Allocator,
    cfg: config,
    fuzzy: *FuzzyStore,

    pub fn init(alloc: Allocator, cfg: config, fuzzy: *FuzzyStore) Forgetter {
        return .{ .alloc = alloc, .cfg = cfg, .fuzzy = fuzzy };
    }

    /// Compute the existence contribution for a single cell.
    /// High importance → high contribution. Recent access boosts. Old
    /// cells with low importance → low.
    pub fn existenceContribution(self: *const Forgetter, cell: *const MemCell, now_ms: i64) f32 {
        _ = self;
        const age_days: f32 = if (now_ms > cell.metadata.created_at)
            @as(f32, @floatFromInt(now_ms - cell.metadata.created_at)) / 86_400_000.0
        else
            0.0;
        const decay: f32 = @exp(-cell.metadata.decay_rate * age_days);
        return cell.metadata.importance_score * decay;
    }

    pub const SweepResult = struct { fuzzied: usize, kept: usize, archived: usize };

    /// Run the forgetting sweep. Returns counts of (fuzzied, kept).
    pub fn sweep(
        self: *Forgetter,
        mgr: *TriSourceManager,
        dry_run: bool,
    ) !SweepResult {
        const now = time.nowMs();
        var fuzzied: usize = 0;
        var kept: usize = 0;
        const archived: usize = 0;

        // Collect cells to process (avoid mutating map during iteration).
        var to_process = std.ArrayList(*MemCell).empty;
        defer to_process.deinit(self.alloc);
        mgr.forEach({}, struct {
            fn f(_: void, cell: *MemCell) void {
                // noop — we collect below
                _ = cell;
            }
        }.f);

        var it_s = mgr.sensory.iterator();
        while (it_s.next()) |e| try to_process.append(self.alloc, e.value_ptr.*);
        var it_c = mgr.cognitive.iterator();
        while (it_c.next()) |e| try to_process.append(self.alloc, e.value_ptr.*);
        var it_a = mgr.action.iterator();
        while (it_a.next()) |e| try to_process.append(self.alloc, e.value_ptr.*);

        for (to_process.items) |cell| {
            const contribution = self.existenceContribution(cell, now);
            if (contribution < self.cfg.forgetting_threshold) {
                if (dry_run) {
                    fuzzied += 1;
                } else {
                    // PCR: never delete. Transfer to fuzzy store.
                    _ = mgr.remove(cell.id);
                    try self.fuzzy.transfer(cell);
                    fuzzied += 1;
                }
            } else {
                kept += 1;
            }
        }

        return .{ .fuzzied = fuzzied, .kept = kept, .archived = archived };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Forgetter: low importance gets fuzzied" {
    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(std.testing.allocator, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(std.testing.allocator);
    defer fuzzy.deinit();
    var forgetter = Forgetter.init(std.testing.allocator, .{ .forgetting_threshold = 0.1 }, &fuzzy);

    // Add a cell with importance 0.05 — should be fuzzied.
    const cell: MemCell = .{
        .id = 0,
        .source = .matter,
        .episode = "x",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{ .{ .goal_id = 1, .relevance = 0.1, .priority = 1 } },
        .metadata = .{ .source_confidence = 0.9, .importance_score = 0.05, .decay_rate = 0.01 },
    };
    _ = try mgr.add(cell);

    const result = try forgetter.sweep(&mgr, false);
    try std.testing.expectEqual(@as(usize, 1), result.fuzzied);
    try std.testing.expectEqual(@as(usize, 1), fuzzy.count());
    try std.testing.expectEqual(@as(usize, 0), mgr.count());
}

test "FuzzyStore: promote restores" {
    var fuzzy = FuzzyStore.init(std.testing.allocator);
    defer fuzzy.deinit();

    var cell: MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "x",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{ .{ .goal_id = 1, .relevance = 0.5, .priority = 5 } },
        .metadata = .{ .source_confidence = 0.9 },
    };
    try fuzzy.transfer(&cell);
    try std.testing.expect(cell.metadata.is_fuzzy);
    try std.testing.expectEqual(@as(usize, 1), fuzzy.count());

    const promoted = fuzzy.promote(1).?;
    try std.testing.expect(!promoted.metadata.is_fuzzy);
    try std.testing.expectEqual(@as(usize, 0), fuzzy.count());
}
