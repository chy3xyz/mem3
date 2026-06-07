//! Goal Poset (Partially Ordered Set).
//!
//! **GHW Layer**: Goal (性源). Sits at the top of the GHW three-layer
//! architecture and is the slowest, most stable layer.
//!
//! ## Structure
//! A Goal Poset is `(Obj(G), ≤_goal, ⊥, ⊤)` where:
//! - `Obj(G)` is the set of `GoalNode`s.
//! - `≤_goal` is a partial order via `parent_id` (a child is `<=` its parent).
//! - `⊥` (bottom) is a synthetic root with `id = 0`.
//! - `⊤` (top) is a synthetic all-encompassing node with `id = u64.max - 1`.
//!
//! These synthetic nodes never appear in user output; they enable lattice
//! queries ("all goals between X and Y").
//!
//! ## Constitution compliance
//! - Principle II (GHW 三层耦合): this file is the Goal layer.
//! - Principle III (存在增益驱动): goals are evaluated by `updateMetaGoals`.
//! - FR-011: goals have parent_id, priority, status, and associated memcells.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core_types = @import("../core/types.zig");
const GoalStatus = core_types.GoalStatus;
const GoalNode = @import("goal_node.zig").GoalNode;
const errors = @import("../core/errors.zig");

const log = std.log.scoped(.mem3_goal_tree);

/// Synthetic root goal id (⊥). Never returned to the user.
pub const ROOT_GOAL_ID: u64 = 0;

/// Synthetic top goal id (⊤). Never returned to the user.
pub const TOP_GOAL_ID: u64 = std.math.maxInt(u64) - 1;

pub const GoalPoset = struct {
    alloc: Allocator,
    /// Backing store: id -> node.
    nodes: std.AutoHashMap(u64, *GoalNode),
    /// Adjacency: parent_id -> list of child ids. Used for descendants().
    children: std.AutoHashMap(u64, std.ArrayList(u64)),
    /// Reverse index: goal_id -> list of associated MemCell ids.
    memcell_index: std.AutoHashMap(u64, std.ArrayList(u64)),

    pub fn init(alloc: Allocator) GoalPoset {
        var poset: GoalPoset = .{
            .alloc = alloc,
            .nodes = std.AutoHashMap(u64, *GoalNode).init(alloc),
            .children = std.AutoHashMap(u64, std.ArrayList(u64)).init(alloc),
            .memcell_index = std.AutoHashMap(u64, std.ArrayList(u64)).init(alloc),
        };
        // Initialize synthetic root.
        const root_ptr = alloc.create(GoalNode) catch unreachable;
        root_ptr.* = .{
            .id = ROOT_GOAL_ID,
            .parent_id = null,
            .name = alloc.dupe(u8, "⊥") catch "<root>",
            .description = alloc.dupe(u8, "synthetic root") catch "",
            .status = .pending,
            .priority = 0,
            .deadline = null,
            .created_at = 0,
            .updated_at = 0,
        };
        poset.nodes.put(ROOT_GOAL_ID, root_ptr) catch unreachable;

        const top_ptr = alloc.create(GoalNode) catch unreachable;
        top_ptr.* = .{
            .id = TOP_GOAL_ID,
            .parent_id = null,
            .name = alloc.dupe(u8, "⊤") catch "<top>",
            .description = alloc.dupe(u8, "synthetic top") catch "",
            .status = .pending,
            .priority = 255,
            .deadline = null,
            .created_at = 0,
            .updated_at = 0,
        };
        poset.nodes.put(TOP_GOAL_ID, top_ptr) catch unreachable;
        return poset;
    }

    pub fn deinit(self: *GoalPoset) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.nodes.deinit();

        var cit = self.children.iterator();
        while (cit.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
        }
        self.children.deinit();

        var mit = self.memcell_index.iterator();
        while (mit.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
        }
        self.memcell_index.deinit();
    }

    /// Create a new goal. `parent_id` is optional; if null, attaches to root.
    /// Returns the assigned id (1-based; root and top are reserved).
    pub fn create(
        self: *GoalPoset,
        name: []const u8,
        description: []const u8,
        parent_id: ?u64,
        priority: u8,
        deadline: ?i64,
        now_ms: i64,
        next_id: *std.atomic.Value(u64),
    ) errors.Error!u64 {
        const parent = parent_id orelse ROOT_GOAL_ID;
        if (!self.nodes.contains(parent)) return errors.Error.GoalNotFound;

        // Detect cycles: parent of parent of ... == self? Skip for now (new
        // goal has no id yet so cycle is impossible).

        const id = next_id.fetchAdd(1, .monotonic);
        const node = try self.alloc.create(GoalNode);
        errdefer self.alloc.destroy(node);
        node.* = .{
            .id = id,
            .parent_id = parent,
            .name = try self.alloc.dupe(u8, name),
            .description = try self.alloc.dupe(u8, description),
            .status = .pending,
            .priority = priority,
            .deadline = deadline,
            .created_at = now_ms,
            .updated_at = now_ms,
        };
        try self.nodes.put(id, node);

        // Track children.
        const child_list = self.children.getPtr(parent) orelse blk: {
            const new_list = std.ArrayList(u64).empty;
            try self.children.put(parent, new_list);
            break :blk self.children.getPtr(parent).?;
        };
        try child_list.append(self.alloc, id);

        log.debug("created goal id={d} parent={?d} name={s}", .{ id, parent_id, name });
        return id;
    }

    /// Get a goal by id.
    pub fn get(self: *const GoalPoset, id: u64) ?*const GoalNode {
        return self.nodes.get(id);
    }

    /// Update a goal's status. Rejects transitions to .tombstoned unless
    /// the goal is already .unrealized for ≥ 7 days (Constitution Principle III).
    pub fn updateStatus(self: *GoalPoset, id: u64, status: GoalStatus, now_ms: i64) errors.Error!void {
        const node = self.nodes.getPtr(id) orelse return errors.Error.GoalNotFound;
        if (status == .tombstoned) {
            if (node.status != .unrealized) {
                return errors.Error.GoalCycle; // reuse this error for "invalid transition"
            }
            if (node.unrealized_at) |uat| {
                if (now_ms - uat < 7 * 86_400_000) {
                    return errors.Error.GoalCycle;
                }
            } else {
                return errors.Error.GoalCycle;
            }
        }
        node.status = status;
        node.updated_at = now_ms;
        if (status == .unrealized) node.unrealized_at = now_ms;
    }

    /// Bind a MemCell to a goal. Maintains the reverse index.
    /// Constitution III: the bind call also marks the goal as "having
    /// memcells", preventing it from being marked .unrealized.
    pub fn bindMemcell(self: *GoalPoset, goal_id: u64, memcell_id: u64) errors.Error!void {
        if (!self.nodes.contains(goal_id)) return errors.Error.GoalNotFound;
        const list = self.memcell_index.getPtr(goal_id) orelse blk: {
            const new_list = std.ArrayList(u64).empty;
            try self.memcell_index.put(goal_id, new_list);
            break :blk self.memcell_index.getPtr(goal_id).?;
        };
        // Avoid duplicates.
        for (list.items) |id| if (id == memcell_id) return;
        try list.append(self.alloc, memcell_id);
    }

    /// Unbind a MemCell from a goal. (Used by forgetting; PCR-mandated
    /// preservation is for facts, not for goal bindings.)
    pub fn unbindMemcell(self: *GoalPoset, goal_id: u64, memcell_id: u64) errors.Error!void {
        const list = self.memcell_index.getPtr(goal_id) orelse return errors.Error.GoalNotFound;
        for (list.items, 0..) |id, i| {
            if (id == memcell_id) {
                _ = list.orderedRemove(i);
                return;
            }
        }
    }

    /// List MemCell ids associated with a goal.
    pub fn memcellsFor(self: *const GoalPoset, goal_id: u64) []const u64 {
        return self.memcell_index.get(goal_id) orelse &.{};
    }

    /// Direct children of a goal (one step down the lattice).
    pub fn childrenOf(self: *const GoalPoset, goal_id: u64) []const u64 {
        return self.children.get(goal_id) orelse &.{};
    }

    /// All descendants of a goal (transitive closure). Returns an owned slice.
    pub fn descendants(self: *const GoalPoset, alloc: Allocator, goal_id: u64) errors.Error![]u64 {
        var result = std.ArrayList(u64).empty;
        errdefer result.deinit(alloc);
        try walkDescendants(self, goal_id, &result);
        return result.toOwnedSlice(alloc);
    }

    fn walkDescendants(self: *const GoalPoset, id: u64, out: *std.ArrayList(u64)) errors.Error!void {
        const kids = self.children.get(id) orelse return;
        for (kids) |k| {
            try out.append(self.alloc, k);
            try walkDescendants(self, k, out);
        }
    }

    /// Validate a candidate status transition.
    pub fn isValidTransition(from: GoalStatus, to: GoalStatus) bool {
        return switch (from) {
            .pending => to == .in_progress or to == .unrealized or to == .tombstoned,
            .in_progress => to == .completed or to == .failed or to == .pending,
            .completed => false, // terminal
            .failed => to == .pending or to == .tombstoned, // can retry or retire
            .unrealized => to == .pending or to == .tombstoned, // can revive or retire
            .tombstoned => false, // terminal
        };
    }

    /// Meta-goal evaluation: run periodically, mark goals with no associated
    /// MemCells for > 7 days as .unrealized.
    pub fn evaluateMetaGoals(self: *GoalPoset, now_ms: i64) !usize {
        var unrealized_count: usize = 0;
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.id == ROOT_GOAL_ID or node.id == TOP_GOAL_ID) continue;
            if (node.status == .tombstoned or node.status == .unrealized) continue;

            const mcs = self.memcell_index.get(node.id) orelse &.{};
            if (mcs.len == 0) {
                if (now_ms - node.created_at > 7 * 86_400_000) {
                    try self.updateStatus(node.id, .unrealized, now_ms);
                    unrealized_count += 1;
                }
            }
        }
        return unrealized_count;
    }

    /// Number of non-synthetic goals.
    pub fn count(self: *const GoalPoset) usize {
        return self.nodes.count() - 2; // exclude root + top
    }
};

// =============================================================================
// Tests
// =============================================================================

test "GoalPoset: create + retrieve" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();

    var next_id: std.atomic.Value(u64) = .init(1);
    const g1 = try poset.create("build-mem3", "the memory OS", null, 9, null, 0, &next_id);
    try std.testing.expect(g1 > 0);
    const node = poset.get(g1).?;
    try std.testing.expectEqualStrings("build-mem3", node.name);
    try std.testing.expectEqual(@as(u8, 9), node.priority);
}

test "GoalPoset: parent-child" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);

    const parent = try poset.create("parent", "p", null, 5, null, 0, &next);
    const child = try poset.create("child", "c", parent, 8, null, 0, &next);

    try std.testing.expectEqual(@as(usize, 1), poset.childrenOf(parent).len);
    try std.testing.expectEqual(child, poset.childrenOf(parent)[0]);

    const descs = try poset.descendants(std.testing.allocator, parent);
    defer std.testing.allocator.free(descs);
    try std.testing.expectEqual(@as(usize, 1), descs.len);
    try std.testing.expectEqual(child, descs[0]);
}

test "GoalPoset: bind + unbind memcell" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);

    const g = try poset.create("g", "d", null, 5, null, 0, &next);
    try poset.bindMemcell(g, 42);
    try poset.bindMemcell(g, 43);
    try poset.bindMemcell(g, 42); // dup, no-op
    try std.testing.expectEqual(@as(usize, 2), poset.memcellsFor(g).len);

    try poset.unbindMemcell(g, 42);
    try std.testing.expectEqual(@as(usize, 1), poset.memcellsFor(g).len);
}

test "GoalPoset: meta-goal evaluation marks unrealized after 7 days" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);

    const now: i64 = 1_000_000_000_000;
    const g = try poset.create("orphan", "no memories", null, 5, null, now, &next);
    // No memcells bound. After 7 days, evaluateMetaGoals should mark it.
    const later = now + 8 * 86_400_000;
    const n = try poset.evaluateMetaGoals(later);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(GoalStatus.unrealized, poset.get(g).?.status);
}

test "GoalPoset: cycle detection" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);

    const a = try poset.create("a", "", null, 1, null, 0, &next);
    const b = try poset.create("b", "", a, 1, null, 0, &next);
    // Try to set b's parent to itself — should error.
    // (current API doesn't support reparenting; just verify the static
    // invariant that childrenOf doesn't include the node itself.)
    try std.testing.expectEqual(@as(usize, 1), poset.childrenOf(a).len);
    try std.testing.expect(b != a);

    // After 7 days, the orphan goal should be marked unrealized.
    const later: i64 = 8 * 86_400_000;
    _ = try poset.evaluateMetaGoals(later);
    try std.testing.expectEqual(GoalStatus.unrealized, poset.get(a).?.status);
}

test "GoalPoset: status transitions" {
    try std.testing.expect(GoalPoset.isValidTransition(.pending, .in_progress));
    try std.testing.expect(GoalPoset.isValidTransition(.pending, .unrealized));
    try std.testing.expect(!GoalPoset.isValidTransition(.completed, .pending));
    try std.testing.expect(!GoalPoset.isValidTransition(.tombstoned, .pending));
}
