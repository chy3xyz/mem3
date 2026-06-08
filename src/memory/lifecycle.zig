//! Memory lifecycle orchestrator — runs the four stages (encode /
//! consolidate / recollect / forget) on a TriSourceManager.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const TriSourceManager = @import("tri_source_manager.zig").TriSourceManager;
const enc = @import("encoder.zig");
const RawInput = enc.RawInput;
const Encoder = enc.Encoder;
const Forgetter = @import("forgetter.zig").Forgetter;
const FuzzyStore = @import("forgetter.zig").FuzzyStore;
const Consolidator = @import("consolidator.zig").Consolidator;
const CoherenceCalculator = @import("coherence.zig").CoherenceCalculator;
const config = @import("../core/config.zig").Config;
const errors = core.Error;

pub const Lifecycle = struct {
    alloc: Allocator,
    cfg: config,
    mgr: *TriSourceManager,
    encoder: Encoder,
    forgetter: Forgetter,
    fuzzy: FuzzyStore,
    consolidator: Consolidator,
    coherence: CoherenceCalculator,

    pub fn init(alloc: Allocator, cfg: config, mgr: *TriSourceManager) Lifecycle {
        const fuzzy = FuzzyStore.init(alloc);
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .mgr = mgr,
            .encoder = Encoder.init(alloc, cfg),
            .forgetter = Forgetter.init(alloc, cfg, undefined), // patched below
            .fuzzy = fuzzy,
            .consolidator = Consolidator.init(alloc, cfg, undefined, undefined), // patched below
            .coherence = CoherenceCalculator.init(alloc),
        };
    }

    /// Wire the forgetter to the fuzzy store and the consolidator to
    /// both. Required after init() because struct fields are
    /// initialized in order and the dependencies (fuzzy, mgr) aren't
    /// available at init() time.
    pub fn wire(self: *Lifecycle) void {
        self.forgetter.fuzzy = &self.fuzzy;
        self.consolidator.fuzzy = &self.fuzzy;
        self.consolidator.mgr = self.mgr;
    }

    /// Encoding: turn a raw input into a MemCell and add to the manager.
    pub fn encode(self: *Lifecycle, input: RawInput) errors!u64 {
        const cell = try self.encoder.encode(input);
        return self.mgr.add(cell);
    }

    /// Encode with a caller-supplied id. Used by the WAL-first commit path
    /// in `Store.addRawInternal`: the id is pre-fetchAdd'd so the WAL record
    /// can name the cell before the manager has it.
    pub fn encodeWithId(self: *Lifecycle, id: u64, input: RawInput) errors!u64 {
        const cell = try self.encoder.encode(input);
        return self.mgr.addWithId(id, cell);
    }

    /// Replay-side insert: take a fully-formed cell (already parsed from
    /// WAL with restored metadata) and add it under the given id. Bypasses
    /// the encoder so created_at / importance_score / decay_rate survive
    /// the round-trip — Principle III ranking requires these to be stable
    /// across boots, not reset to "now".
    pub fn addCell(self: *Lifecycle, id: u64, cell: MemCell) errors!u64 {
        return self.mgr.addWithId(id, cell);
    }

    /// Forgetting: run the existence-gain-driven sweep.
    pub fn forget(self: *Lifecycle, dry_run: bool) !Forgetter.SweepResult {
        return self.forgetter.sweep(self.mgr, dry_run);
    }

    /// Consolidation: run HAC clustering + abstract generation. Returns
    /// the number of abstract cells created (1 per cluster ≥ 2 cells).
    pub fn consolidate(self: *Lifecycle) !usize {
        const result = try self.consolidator.consolidate();
        return result.abstracts_created;
    }
};

// Tests
const testing = std.testing;

test "Lifecycle: encode + forget cycle" {
    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(testing.allocator, &ids);
    var lc = Lifecycle.init(testing.allocator, .{ .forgetting_threshold = 0.1 }, &mgr);
    lc.wire();
    defer mgr.deinit();
    defer lc.fuzzy.deinit();

    // Encode a low-importance cell.
    const id = try lc.encode(.{
        .source = .matter,
        .episode = "fading",
        .goal_associations = &.{ .{ .goal_id = 1, .relevance = 0.05, .priority = 1 } },
    });
    try testing.expect(id > 0);
    try testing.expectEqual(@as(usize, 1), mgr.count());

    // Force importance low and sweep.
    const cell = mgr.get(id).?;
    cell.metadata.importance_score = 0.01;
    const result = try lc.forget(false);
    try testing.expectEqual(@as(usize, 1), result.fuzzied);
    try testing.expectEqual(@as(usize, 0), mgr.count());
    try testing.expectEqual(@as(usize, 1), lc.fuzzy.count());
}
