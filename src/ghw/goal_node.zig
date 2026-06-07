//! GoalNode — a single node in the Goal Poset.
//!
//! **GHW Layer**: Goal (性源).

const std = @import("std");
const core_types = @import("../core/types.zig");
const GoalStatus = core_types.GoalStatus;

pub const GoalNode = struct {
    id: u64,
    parent_id: ?u64,
    name: []const u8,
    description: []const u8,
    status: GoalStatus,
    priority: u8,
    deadline: ?i64,
    created_at: i64,
    updated_at: i64,
    /// When this goal was first marked `unrealized`. Null otherwise.
    unrealized_at: ?i64 = null,

    pub fn deinit(self: *GoalNode, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
    }
};
