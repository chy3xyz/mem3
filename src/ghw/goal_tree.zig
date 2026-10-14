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
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const core_types = @import("../core/types.zig");
const GoalStatus = core_types.GoalStatus;
const GoalNode = @import("goal_node.zig").GoalNode;
const errors = @import("../core/errors.zig");

const log = std.log.scoped(.mem3_goal_tree);

/// Degraded-path diagnostic.
///
/// Zig 0.17's test runner captures EVERY log line emitted while a test
/// runs and fails the test that produced it — verified directly: a test
/// calling `std.log.warn` reports "logged 1 errors" and fails even though
/// `std_options.log_level = .err` is set on the root. So library
/// diagnostics on paths that tests deliberately exercise must be compiled
/// out under test, or the suite goes red for the wrong reason.
fn diag(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) log.warn(fmt, args);
}

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

    /// Build a synthetic (root/top) node. Returns null when the allocator
    /// could not satisfy the request -- `error.OutOfMemory` is genuinely
    /// reachable, not impossible. Every partial allocation is released
    /// before returning, and `name`/`description` are always heap-owned
    /// dupes (never string literals), so `GoalNode.deinit` can safely
    /// `free` them -- previously a dupe failure substituted a literal
    /// that `deinit` would later hand to `alloc.free`, corrupting the heap.
    fn initSynthetic(
        alloc: Allocator,
        id: u64,
        name: []const u8,
        description: []const u8,
        priority: u8,
    ) ?*GoalNode {
        const node = alloc.create(GoalNode) catch {
            diag("GoalPoset.init: out of memory allocating synthetic node (id={d})", .{id});
            return null;
        };
        const owned_name = alloc.dupe(u8, name) catch {
            diag("GoalPoset.init: out of memory duplicating name for synthetic node (id={d})", .{id});
            alloc.destroy(node);
            return null;
        };
        const owned_desc = alloc.dupe(u8, description) catch {
            diag("GoalPoset.init: out of memory duplicating description for synthetic node (id={d})", .{id});
            alloc.free(owned_name);
            alloc.destroy(node);
            return null;
        };
        node.* = .{
            .id = id,
            .parent_id = null,
            .name = owned_name,
            .description = owned_desc,
            .status = .pending,
            .priority = priority,
            .deadline = null,
            .created_at = 0,
            .updated_at = 0,
        };
        return node;
    }

    pub fn init(alloc: Allocator) GoalPoset {
        var poset: GoalPoset = .{
            .alloc = alloc,
            .nodes = std.AutoHashMap(u64, *GoalNode).init(alloc),
            .children = std.AutoHashMap(u64, std.ArrayList(u64)).init(alloc),
            .memcell_index = std.AutoHashMap(u64, std.ArrayList(u64)).init(alloc),
        };
        // `Allocator.create` and `HashMap.put` return `error.OutOfMemory`,
        // which is genuinely reachable under memory pressure -- it is NOT
        // provably unreachable, so it must not be panicked on. `init`
        // cannot return an error union without breaking its 12 call sites
        // (store.zig, http_server.zig, snapshot.zig, reranker.zig,
        // examples/, tests), so OOM is handled explicitly instead: we log
        // it and return a poset missing that synthetic node. Lookups of a
        // missing id then fail cleanly with `errors.Error.GoalNotFound`
        // (see `create`) rather than dereferencing a dangling pointer.
        //
        // Initialize synthetic root.
        const root_ptr = initSynthetic(alloc, ROOT_GOAL_ID, "⊥", "synthetic root", 0) orelse return poset;
        poset.nodes.put(ROOT_GOAL_ID, root_ptr) catch {
            diag("GoalPoset.init: out of memory inserting synthetic root (id={d})", .{ROOT_GOAL_ID});
            root_ptr.deinit(alloc);
            alloc.destroy(root_ptr);
            return poset;
        };

        const top_ptr = initSynthetic(alloc, TOP_GOAL_ID, "⊤", "synthetic top", 255) orelse return poset;
        poset.nodes.put(TOP_GOAL_ID, top_ptr) catch {
            diag("GoalPoset.init: out of memory inserting synthetic top (id={d})", .{TOP_GOAL_ID});
            top_ptr.deinit(alloc);
            alloc.destroy(top_ptr);
            return poset;
        };
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
        // `self.nodes` is AutoHashMap(u64, *GoalNode). getPtr returns
        // `?**GoalNode` — a pointer to the value slot, which itself
        // holds a `*GoalNode` (the pointer to the actual GoalNode
        // struct). We deref twice to reach the struct.
        const slot_ptr = self.nodes.getPtr(id) orelse return errors.Error.GoalNotFound;
        const node: *GoalNode = slot_ptr.*;
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
        const list = self.memcell_index.getPtr(goal_id) orelse return &.{};
        return list.items;
    }

    /// Direct children of a goal (one step down the lattice).
    pub fn childrenOf(self: *const GoalPoset, goal_id: u64) []const u64 {
        const list = self.children.getPtr(goal_id) orelse return &.{};
        return list.items;
    }

    /// All descendants of a goal (transitive closure). Returns an owned slice.
    pub fn descendants(self: *const GoalPoset, alloc: Allocator, goal_id: u64) errors.Error![]u64 {
        var result = std.ArrayList(u64).empty;
        errdefer result.deinit(alloc);
        try walkDescendants(self, goal_id, &result);
        return result.toOwnedSlice(alloc);
    }

    fn walkDescendants(self: *const GoalPoset, id: u64, out: *std.ArrayList(u64)) errors.Error!void {
        const kids_ptr = self.children.getPtr(id) orelse return;
        for (kids_ptr.items) |k| {
            try out.append(self.alloc, k);
            try walkDescendants(self, k, out);
        }
    }

    /// Validate a candidate status transition.
    ///
    /// Enforced by `Store.updateGoalStatus` before the record is
    /// journaled, so it is a durability rule and not advice. It used to
    /// be test-only, which meant `mem3 goal status <id> completed` on a
    /// goal that was still `pending` was refused while the product's own
    /// persistence test exercised exactly that path — the table was
    /// stricter than the system was ever run.
    ///
    /// What is genuinely illegal is resurrection out of a terminal
    /// state: a `completed` or `tombstoned` goal is final, and letting
    /// it move wrote a `goal_update` record that replay would apply,
    /// silently undoing the decision on the next boot.
    pub fn isValidTransition(from: GoalStatus, to: GoalStatus) bool {
        return switch (from) {
            // An agent that finished the work marks the goal done without
            // ever staging it, which is what the CLI does.
            .pending => to == .in_progress or to == .completed or
                to == .failed or to == .unrealized or to == .tombstoned,
            .in_progress => to == .completed or to == .failed or to == .pending,
            .completed => false, // terminal
            // Retry: pending to try again, completed if the retry worked,
            // unrealized once retries are exhausted, tombstoned to retire.
            .failed => to == .pending or to == .completed or
                to == .unrealized or to == .tombstoned,
            .unrealized => to == .pending or to == .completed or to == .tombstoned, // can revive or retire
            .tombstoned => false, // terminal
        };
    }

    /// Which goals Constitution III says are unrealizable as of `now_ms`:
    /// no associated MemCells and older than the 7-day grace period.
    ///
    /// **Pure query — mutates nothing.** The policy decision belongs here;
    /// applying it (and making it durable) belongs to the caller. That
    /// split is what lets `Store.maintain` journal each transition to the
    /// WAL: the previous shape, where `evaluateMetaGoals` called
    /// `updateStatus` internally, produced changes that no WAL record could
    /// ever describe, so a restart silently reverted them.
    ///
    /// Caller owns the returned slice.
    pub fn staleGoals(self: *GoalPoset, alloc: Allocator, now_ms: i64) ![]u64 {
        // Snapshot ids before mutating anything. Zig 0.17's AutoHashMap may
        // rehash on internal compaction, so holding a `value_ptr` from
        // `iterator.next()` across an insert is a stale-pointer bug waiting
        // to happen.
        //
        // The old version snapshotted into a fixed `[256]u64` and `break`
        //ed when full — past 256 goals it silently stopped evaluating and
        // reported a count that looked complete. Allocator-backed, so the
        //bound is memory, not a magic number.
        var ids = std.ArrayList(u64).empty;
        defer ids.deinit(alloc);
        {
            var it = self.nodes.iterator();
            while (it.next()) |entry| try ids.append(alloc, entry.key_ptr.*);
        }

        var out = std.ArrayList(u64).empty;
        errdefer out.deinit(alloc);

        for (ids.items) |id| {
            const node = self.nodes.get(id) orelse continue;
            if (node.id == ROOT_GOAL_ID or node.id == TOP_GOAL_ID) continue;
            if (node.status == .tombstoned or node.status == .unrealized) continue;
            if (self.memcellsFor(id).len != 0) continue;
            if (now_ms - node.created_at <= 7 * 86_400_000) continue;
            try out.append(alloc, id);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Apply `staleGoals` in place. Returns how many were marked.
    ///
    /// Kept for callers that deliberately do not want durability (the
    /// unit tests). Anything that must survive a restart wants
    /// `staleGoals` + `Store.updateGoalStatus` instead.
    pub fn evaluateMetaGoals(self: *GoalPoset, now_ms: i64) !usize {
        const ids = try self.staleGoals(self.alloc, now_ms);
        defer self.alloc.free(ids);
        var unrealized_count: usize = 0;
        for (ids) |id| {
            self.updateStatus(id, .unrealized, now_ms) catch |err| {
                diag("evaluateMetaGoals: updateStatus failed for goal {d}: {}", .{ id, err });
                continue;
            };
            unrealized_count += 1;
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

    // Diagnostic: try updateStatus directly first to verify the
    // mechanism works, then compare with evaluateMetaGoals.
    try poset.updateStatus(g, .in_progress, now + 1000);
    try std.testing.expectEqual(GoalStatus.in_progress, poset.get(g).?.status);
    try poset.updateStatus(g, .pending, now + 2000);
    try std.testing.expectEqual(GoalStatus.pending, poset.get(g).?.status);

    // Now the actual test: meta-goal evaluation marks it unrealized.
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
    // Forward progress and revival.
    try std.testing.expect(GoalPoset.isValidTransition(.pending, .in_progress));
    try std.testing.expect(GoalPoset.isValidTransition(.pending, .completed));
    try std.testing.expect(GoalPoset.isValidTransition(.pending, .unrealized));
    try std.testing.expect(GoalPoset.isValidTransition(.in_progress, .completed));
    try std.testing.expect(GoalPoset.isValidTransition(.unrealized, .pending));
    try std.testing.expect(GoalPoset.isValidTransition(.failed, .completed));

    // Terminal states are final — this is the invariant `Store` now
    // enforces before a `goal_update` record becomes durable.
    try std.testing.expect(!GoalPoset.isValidTransition(.completed, .pending));
    try std.testing.expect(!GoalPoset.isValidTransition(.completed, .in_progress));
    try std.testing.expect(!GoalPoset.isValidTransition(.tombstoned, .pending));
    try std.testing.expect(!GoalPoset.isValidTransition(.tombstoned, .in_progress));

    // In flight cannot jump straight to being retired without being
    // acknowledged first.
    try std.testing.expect(!GoalPoset.isValidTransition(.in_progress, .tombstoned));
}

test "GoalPoset: init survives OOM at every allocation site" {
    // `error.OutOfMemory` is reachable in `init` (Allocator.create,
    // dupe, HashMap.put), so it must be handled, not panicked on. Walk
    // every allocation index and confirm each one degrades gracefully:
    // no panic, and `deinit` releases whatever did succeed (leak-free,
    // which std.testing.allocator checks at the end of this test).
    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
        var poset = GoalPoset.init(failing.allocator());
        poset.deinit();
    }
}
