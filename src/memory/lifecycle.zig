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
const config = @import("../core/config.zig").Config;
const errors = core.Error;

pub const Lifecycle = struct {
    alloc: Allocator,
    cfg: config,
    mgr: *TriSourceManager,
    encoder: Encoder,
    forgetter: Forgetter,
    fuzzy: FuzzyStore,

    pub fn init(alloc: Allocator, cfg: config, mgr: *TriSourceManager) Lifecycle {
        const fuzzy = FuzzyStore.init(alloc);
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .mgr = mgr,
            .encoder = Encoder.init(alloc, cfg),
            .forgetter = Forgetter.init(alloc, cfg, undefined), // patched below
            .fuzzy = fuzzy,
        };
    }

    /// Wire the forgetter to the fuzzy store. Required after init().
    pub fn wire(self: *Lifecycle) void {
        self.forgetter.fuzzy = &self.fuzzy;
    }

    /// Encoding: turn a raw input into a MemCell and add to the manager.
    pub fn encode(self: *Lifecycle, input: RawInput) errors!u64 {
        const cell = try self.encoder.encode(input);
        return self.mgr.add(cell);
    }

    /// Forgetting: run the existence-gain-driven sweep.
    pub fn forget(self: *Lifecycle, dry_run: bool) !Forgetter.SweepResult {
        return self.forgetter.sweep(self.mgr, dry_run);
    }

    /// Consolidation: in v0.1.0 this is a no-op stub; v0.2.0 will run HAC.
    pub fn consolidate(self: *Lifecycle) !usize {
        _ = self;
        return 0;
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
