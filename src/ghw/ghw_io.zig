//! GHW I/O — the cross-layer communication interface.
//!
//! **Constitution Principle II**: cross-layer shortcuts are forbidden. All
//! inter-layer access MUST go through this interface. Each call records
//! the direction (外拓 = encoding Goal→Harness→World, 内求 = retrieval
//! World→Harness→Goal) and validates it against the allowed directions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const GoalPoset = @import("goal_tree.zig").GoalPoset;
const HarnessRegistry = @import("harness_registry.zig").HarnessRegistry;
const WorldModel = @import("world_model.zig").WorldModel;
const MemCell = @import("../core/memcell.zig").MemCell;

pub const Direction = enum {
    /// Encoding: Goal → Harness → World
    outward,
    /// Retrieval: World → Harness → Goal
    inward,
};

/// Composite handle to all three GHW layers.
pub const GHW = struct {
    goals: *GoalPoset,
    harness: *HarnessRegistry,
    world: *WorldModel,

    pub fn init(
        goals: *GoalPoset,
        harness: *HarnessRegistry,
        world: *WorldModel,
    ) GHW {
        return .{ .goals = goals, .harness = harness, .world = world };
    }
};

/// Cross-layer log: records every inter-layer access for auditability.
pub const CrossLayerLog = struct {
    alloc: Allocator,
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        ts_ms: i64,
        from: Layer,
        to: Layer,
        direction: Direction,
        cell_id: ?u64 = null,
    };

    pub const Layer = enum { goal, harness, world };

    pub fn init(alloc: Allocator) CrossLayerLog {
        return .{
            .alloc = alloc,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *CrossLayerLog) void {
        self.entries.deinit(self.alloc);
    }

    pub fn log(self: *CrossLayerLog, e: Entry) !void {
        try self.entries.append(self.alloc, e);
    }

    pub fn count(self: *const CrossLayerLog) usize {
        return self.entries.items.len;
    }
};

/// Validate a direction. Constitution Principle II: encoding MUST go
/// outward, retrieval MUST go inward, no shortcuts.
pub fn isValidDirection(d: Direction, from: CrossLayerLog.Layer, to: CrossLayerLog.Layer) bool {
    _ = d;
    _ = from;
    _ = to;
    // v0.1.0 stub: always allow; v0.2.0 enforces strict ordering.
    // The full check would be:
    //   - outward: goal → harness → world
    //   - inward:  world → harness → goal
    return true;
}

// =============================================================================
// Tests
// =============================================================================

test "GHW I/O: cross-layer log" {
    var log_ = CrossLayerLog.init(std.testing.allocator);
    defer log_.deinit();
    try log_.log(.{ .ts_ms = 1000, .from = .goal, .to = .harness, .direction = .outward });
    try log_.log(.{ .ts_ms = 2000, .from = .world, .to = .harness, .direction = .inward, .cell_id = 42 });
    try std.testing.expectEqual(@as(usize, 2), log_.count());
}
