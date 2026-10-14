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
const Timer = @import("../platform/clock.zig").Timer;

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

/// The memories bound to one goal, in insertion order.
///
/// `ids` is the single source of truth and is handed out verbatim by
/// `memcellsFor`, which snapshot, serialization and
/// `memcellsFor(gid)[0]` all depend on — so it is never reordered and
/// never deduplicated behind the caller's back.
///
/// `high_water` exists only to answer "could this id possibly already be
/// here?" in O(1). It is an **upper bound hint**, never read for its
/// value: `bindMemcell` compares a candidate against it and skips the
/// duplicate scan when the candidate is strictly above it. Removal never
/// lowers it, because a stale-high value can only cost one extra scan —
/// it can never let a duplicate through. That asymmetry is what makes a
/// single hint safe here where a second index (and the invariant that it
/// cannot drift from `ids`) would not be.
pub const BindingList = struct {
    ids: std.ArrayList(u64) = .empty,
    high_water: u64 = 0,

    fn deinit(self: *BindingList, alloc: Allocator) void {
        self.ids.deinit(alloc);
    }
};

pub const GoalPoset = struct {
    alloc: Allocator,
    /// Backing store: id -> node.
    nodes: std.AutoHashMap(u64, *GoalNode),
    /// Adjacency: parent_id -> list of child ids. Used for descendants().
    children: std.AutoHashMap(u64, std.ArrayList(u64)),
    /// Reverse index: goal_id -> memories bound to it, insertion order.
    memcell_index: std.AutoHashMap(u64, BindingList),

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
            .memcell_index = std.AutoHashMap(u64, BindingList).init(alloc),
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
            entry.value_ptr.deinit(self.alloc);
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
    ///
    /// Binding the same cell twice is a no-op. That guarantee used to
    /// cost O(k) per insert (k = memories already on the goal), which
    /// made filling one goal's corpus quadratic. It is now O(1) on the
    /// production path: `Store.encodeAcrossLayers` passes a freshly
    /// minted, strictly increasing id, so the id is above the goal's
    /// high-water mark and provably absent. The scan below still runs in
    /// full for any id at or below the mark, so the no-op guarantee is
    /// unchanged — only the cost of proving it moved.
    pub fn bindMemcell(self: *GoalPoset, goal_id: u64, memcell_id: u64) errors.Error!void {
        if (!self.nodes.contains(goal_id)) return errors.Error.GoalNotFound;
        const slot = self.memcell_index.getPtr(goal_id) orelse blk: {
            try self.memcell_index.put(goal_id, .{});
            break :blk self.memcell_index.getPtr(goal_id).?;
        };

        if (memcell_id > slot.high_water) {
            // Strictly above everything ever bound here: cannot be a
            // duplicate, so the scan is provably unnecessary.
            try slot.ids.append(self.alloc, memcell_id);
            slot.high_water = memcell_id;
            return;
        }

        // At or below the mark: prove absence the hard way.
        for (slot.ids.items) |id| if (id == memcell_id) return;
        try slot.ids.append(self.alloc, memcell_id);
        // `high_water` is deliberately not updated here — the branch is
        // only reached when `memcell_id <= high_water`, so it is already
        // at least as large as the id just appended.
    }

    /// Unbind a MemCell from a goal. (Used by forgetting; PCR-mandated
    /// preservation is for facts, not for goal bindings.)
    ///
    /// `high_water` is left alone; see `BindingList`.
    pub fn unbindMemcell(self: *GoalPoset, goal_id: u64, memcell_id: u64) errors.Error!void {
        const slot = self.memcell_index.getPtr(goal_id) orelse return errors.Error.GoalNotFound;
        for (slot.ids.items, 0..) |id, i| {
            if (id == memcell_id) {
                _ = slot.ids.orderedRemove(i);
                return;
            }
        }
    }

    /// Drop `memcell_ids` from **every** goal's bindings, in one pass.
    ///
    /// The forget sweep knows which cells died but not which goals they
    /// were bound to, and there is deliberately no `cell_id -> goal_id`
    /// index to consult: `GoalSnapshot` carries no binding ids, so every
    /// binding in the process is reconstructed by WAL replay through
    /// `bindMemcell`. A second index would have to be reconstructed and
    /// kept in lockstep across replay, restore and snapshot rotation, and
    /// a drift between the two would silently resurrect exactly the bug
    /// this function removes.
    ///
    /// Cost is O(forgotten + total bindings) using a throwaway set of the
    /// forgotten ids, which is the same order as the O(cells) id diff
    /// `Store.forget` already performs around the sweep. Iteration is
    /// backwards so `orderedRemove` indices stay valid as the list
    /// shrinks, and surviving bindings keep their relative order.
    pub fn unbindCellsEverywhere(self: *GoalPoset, memcell_ids: []const u64) errors.Error!void {
        if (memcell_ids.len == 0) return;

        // `AutoHashMap(u64, void)` as a set: this toolchain's std has no
        // `std.AutoHashSet`.
        var doomed = std.AutoHashMap(u64, void).init(self.alloc);
        defer doomed.deinit();
        for (memcell_ids) |id| try doomed.put(id, {});

        var it = self.memcell_index.iterator();
        while (it.next()) |entry| {
            const bound = &entry.value_ptr.ids;
            var i = bound.items.len;
            while (i > 0) {
                i -= 1;
                if (doomed.contains(bound.items[i])) _ = bound.orderedRemove(i);
            }
        }
    }

    /// List MemCell ids associated with a goal, in the order they were
    /// bound.
    pub fn memcellsFor(self: *const GoalPoset, goal_id: u64) []const u64 {
        const slot = self.memcell_index.getPtr(goal_id) orelse return &.{};
        return slot.ids.items;
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

// =============================================================================
// Binding index: complexity, dedup, ordering, release
// =============================================================================

/// Best-of-`reps` nanoseconds per `bindMemcell` when filling one goal with
/// `count` strictly increasing ids — the shape `Store.encodeAcrossLayers`
/// produces, since it binds the id it just minted.
///
/// `std.heap.smp_allocator`, deliberately **not** `std.testing.allocator`:
/// DebugAllocator captures a multi-frame stack trace on *every* allocation,
/// which measures the allocator rather than the code under test (a no-op
/// `Store.init`+`deinit` measures 1,320us under it and 11.8us under a plain
/// allocator). Leak detection for these containers is the job of the
/// `std.testing.allocator` test at the bottom of this section instead.
fn bestBindNsPerOp(count: usize, reps: usize) !i128 {
    const alloc = std.heap.smp_allocator;
    var best: i128 = std.math.maxInt(i128);
    var rep: usize = 0;
    while (rep < reps) : (rep += 1) {
        var poset = GoalPoset.init(alloc);
        defer poset.deinit();
        var next: std.atomic.Value(u64) = .init(1);
        const goal_id = try poset.create("throughput", "d", null, 5, null, 0, &next);

        // One untimed bind first, so the measurement covers growth rather
        // than first-touch page faults on the list's initial pages.
        try poset.bindMemcell(goal_id, 1);

        var timer = Timer.start();
        var filled: usize = 1;
        while (filled < count) : (filled += 1) {
            try poset.bindMemcell(goal_id, @intCast(filled + 1));
        }
        const per_op = @divTrunc(timer.elapsedNs(), @as(i128, @intCast(count - 1)));
        if (per_op < best) best = per_op;
    }
    return best;
}

test "GoalPoset: bindMemcell is O(1) amortised, not O(k) per insert" {
    // Fill one goal with 2,000 cells, then 16,000 -- an 8x larger corpus.
    //
    // Constant per-insert cost predicts the per-op time barely moves; the
    // linear duplicate scan this replaced predicts it grows with the corpus,
    // measured in Debug (best-of-3, this machine):
    //
    //     linear scan      1,953 ns/op ->  13,943 ns/op   ratio 6.9x
    //     high_water fast     346 ns/op ->     359 ns/op   ratio 1.0x
    //
    // The bound is 3x, between those two predictions with room on both
    // sides, and it is a *ratio* rather than a wall-clock threshold so a
    // slow or contended machine cannot flip it -- only removing the fast
    // path can.
    _ = try bestBindNsPerOp(2_000, 3); // warm up: page in the code first
    const small = try bestBindNsPerOp(2_000, 3);
    const large = try bestBindNsPerOp(16_000, 3);
    try std.testing.expect(large < small * 3);
}

test "GoalPoset: binding the same cell twice is a no-op on both bind paths" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const goal_id = try poset.create("dedup", "d", null, 5, null, 0, &next);

    // Above the high-water mark: the O(1) fast path. Nothing can already
    // be above the mark, so a repeat here is a real duplicate.
    try poset.bindMemcell(goal_id, 10);
    try poset.bindMemcell(goal_id, 20);
    try poset.bindMemcell(goal_id, 30);
    try std.testing.expectEqual(@as(usize, 3), poset.memcellsFor(goal_id).len);

    // At or below the mark: the scan path, which is what actually has to
    // reject the duplicate. Dropping this scan is the tempting "optimisation"
    // that would silently reintroduce double bindings.
    try poset.bindMemcell(goal_id, 20);
    try poset.bindMemcell(goal_id, 10);
    try poset.bindMemcell(goal_id, 30);
    try std.testing.expectEqual(@as(usize, 3), poset.memcellsFor(goal_id).len);

    // An absent id below the mark is still accepted, exactly once.
    try poset.bindMemcell(goal_id, 25);
    try poset.bindMemcell(goal_id, 25);
    try std.testing.expectEqual(@as(usize, 4), poset.memcellsFor(goal_id).len);
    try std.testing.expect(std.mem.indexOfScalar(u64, poset.memcellsFor(goal_id), 25) != null);

    // Same guarantee per-goal, not per-poset: the same cell id on two
    // goals is two bindings, and each keeps its own mark.
    const other_id = try poset.create("other", "d", null, 5, null, 0, &next);
    try poset.bindMemcell(other_id, 10);
    try poset.bindMemcell(other_id, 10);
    try std.testing.expectEqual(@as(usize, 1), poset.memcellsFor(other_id).len);
    try std.testing.expectEqual(@as(usize, 4), poset.memcellsFor(goal_id).len);
}

test "GoalPoset: high_water stays an upper bound that removal never lowers" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const goal_id = try poset.create("mark", "d", null, 5, null, 0, &next);

    try poset.bindMemcell(goal_id, 7);
    try poset.bindMemcell(goal_id, 9);
    try poset.bindMemcell(goal_id, 5); // below the mark -> scan path

    // The invariant the fast path rests on: nothing in `ids` is above the
    // mark. If this ever fails, the O(1) branch would admit a duplicate.
    const slot = poset.memcell_index.getPtr(goal_id).?;
    for (slot.ids.items) |id| try std.testing.expect(id <= slot.high_water);
    try std.testing.expectEqual(@as(u64, 9), slot.high_water);

    // Removing the highest bound must NOT lower the mark: a stale-high
    // mark can only cost one extra scan, whereas a mark that tracked the
    // removals would be one more thing that can drift from `ids`.
    try poset.unbindMemcell(goal_id, 9);
    try std.testing.expectEqual(@as(u64, 9), slot.high_water);

    // Re-binding the now-absent 9 is a genuine new binding, not a
    // duplicate -- and it arrives through the scan path, because 9 sits at
    // the mark rather than above it.
    try poset.bindMemcell(goal_id, 9);
    try std.testing.expectEqual(@as(usize, 3), poset.memcellsFor(goal_id).len);

    // Binding it a second time must be rejected there and then. This is
    // the case the stale mark has to get right: the id is present, it is
    // not above the mark, so only the scan can catch it.
    try poset.bindMemcell(goal_id, 9);
    try std.testing.expectEqual(@as(usize, 3), poset.memcellsFor(goal_id).len);
    var occurrences: usize = 0;
    for (poset.memcellsFor(goal_id)) |id| {
        if (id == 9) occurrences += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), occurrences);

    // ...while a genuinely new id below the stale mark is still accepted.
    try poset.bindMemcell(goal_id, 8);
    try std.testing.expectEqual(@as(usize, 4), poset.memcellsFor(goal_id).len);
}

test "GoalPoset: memcellsFor preserves binding order, empty and single cases" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const goal_id = try poset.create("ordered", "d", null, 5, null, 0, &next);

    // A goal with no bindings at all: an empty slice, never null. Callers
    // -- `staleGoals` (invariant c), http_server's memcell_count, the
    // snapshot writer -- all read `.len` off this without a null check.
    try std.testing.expectEqual(@as(usize, 0), poset.memcellsFor(goal_id).len);
    try std.testing.expectEqual(@as(usize, 0), poset.memcellsFor(999_999).len);
    try std.testing.expectEqual(@as(usize, 0), poset.memcellsFor(ROOT_GOAL_ID).len);

    // Single element, bound out of ascending order on purpose: position 0
    // is what `memcellsFor(gid)[0]` callers anchor on.
    try poset.bindMemcell(goal_id, 4242);
    try std.testing.expectEqual(@as(usize, 1), poset.memcellsFor(goal_id).len);
    try std.testing.expectEqual(@as(u64, 4242), poset.memcellsFor(goal_id)[0]);

    // Insertion order is the contract, not sort order: a lower id bound
    // later still goes to the end.
    try poset.bindMemcell(goal_id, 3);
    try poset.bindMemcell(goal_id, 900);
    try poset.bindMemcell(goal_id, 17);
    const expected = [_]u64{ 4242, 3, 900, 17 };
    try std.testing.expectEqualSlices(u64, &expected, poset.memcellsFor(goal_id));
}

test "GoalPoset: unbindMemcell removes one binding and keeps the rest in order" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const goal_id = try poset.create("unbind", "d", null, 5, null, 0, &next);
    for ([_]u64{ 1, 2, 3, 4, 5 }) |id| try poset.bindMemcell(goal_id, id);

    // Removing from the middle: `orderedRemove` shifts the tail down, so
    // the survivors stay in binding order. (`swapRemove` would be O(1) but
    // would move the last element into the hole -- a silent reordering of
    // a slice callers read positionally, so the shift is the right trade.)
    try poset.unbindMemcell(goal_id, 3);
    const after_middle = [_]u64{ 1, 2, 4, 5 };
    try std.testing.expectEqualSlices(u64, &after_middle, poset.memcellsFor(goal_id));

    // Removing an id that is not bound changes nothing.
    try poset.unbindMemcell(goal_id, 999);
    try std.testing.expectEqualSlices(u64, &after_middle, poset.memcellsFor(goal_id));

    // Unbinding every binding leaves an empty (not stale) slice, which is
    // what lets the 7-day rule in `staleGoals` fire again.
    for ([_]u64{ 1, 2, 4, 5 }) |id| try poset.unbindMemcell(goal_id, id);
    try std.testing.expectEqual(@as(usize, 0), poset.memcellsFor(goal_id).len);
}

test "GoalPoset: unbindCellsEverywhere drops forgotten cells and keeps survivors ordered" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const busy_id = try poset.create("busy", "d", null, 5, null, 0, &next);
    const thin_id = try poset.create("thin", "d", null, 5, null, 0, &next);
    const empty_id = try poset.create("empty", "d", null, 5, null, 0, &next);

    for ([_]u64{ 10, 20, 30, 40, 50 }) |id| try poset.bindMemcell(busy_id, id);
    try poset.bindMemcell(thin_id, 20);
    try poset.bindMemcell(thin_id, 40);

    // With a corpus behind it, `busy_id` reads as covered by invariant (c)
    // and is therefore never a candidate for the 7-day rule.
    const horizon_ms: i64 = 1_000_000_000_000 + 8 * 86_400_000;
    {
        const stale_before = try poset.staleGoals(std.testing.allocator, horizon_ms);
        defer std.testing.allocator.free(stale_before);
        try std.testing.expect(std.mem.indexOfScalar(u64, stale_before, busy_id) == null);
    }

    // An empty sweep is a no-op, not an error: `Store.forget` calls this
    // on every run, including the ones that forget nothing.
    try poset.unbindCellsEverywhere(&.{});

    // Ids that were never bound anywhere are likewise harmless.
    try poset.unbindCellsEverywhere(&[_]u64{ 999, 1000 });

    try poset.unbindCellsEverywhere(&[_]u64{ 20, 40, 50 });
    const survivors = [_]u64{ 10, 30 };
    try std.testing.expectEqualSlices(u64, &survivors, poset.memcellsFor(busy_id));
    try std.testing.expectEqual(@as(usize, 0), poset.memcellsFor(thin_id).len);
    // A goal that never had a binding is left alone rather than created.
    try std.testing.expectEqual(@as(usize, 0), poset.memcellsFor(empty_id).len);

    // `busy_id` still has survivors, so it still reads as covered. Only
    // once the rest of the corpus is swept does invariant (c) stop
    // counting it -- a goal must not read as covered by memories that
    // were explicitly judged not worth keeping.
    {
        const stale_mid = try poset.staleGoals(std.testing.allocator, horizon_ms);
        defer std.testing.allocator.free(stale_mid);
        try std.testing.expect(std.mem.indexOfScalar(u64, stale_mid, busy_id) == null);
    }

    try poset.unbindCellsEverywhere(&survivors);
    try std.testing.expectEqual(@as(usize, 0), poset.memcellsFor(busy_id).len);

    {
        const stale_after = try poset.staleGoals(std.testing.allocator, horizon_ms);
        defer std.testing.allocator.free(stale_after);
        try std.testing.expect(std.mem.indexOfScalar(u64, stale_after, busy_id) != null);
    }
}

test "GoalPoset: deinit releases every binding container" {
    // `BindingList` holds a heap list per goal, so this is the guard against
    // an orphaned per-goal container in a daemon that never exits. Every
    // shape the index can reach is built here: many goals, a single goal
    // with a large list, one emptied by a forget sweep, and one emptied by
    // `unbindMemcell`.
    var poset = GoalPoset.init(std.testing.allocator);
    var next: std.atomic.Value(u64) = .init(1);

    var goal_ids: [8]u64 = undefined;
    for (&goal_ids, 0..) |*slot, gi| {
        slot.* = try poset.create("goal", "d", null, 5, null, 0, &next);
        var cell: u64 = 0;
        while (cell < @as(u64, gi) * 32 + 1) : (cell += 1) {
            try poset.bindMemcell(slot.*, cell + @as(u64, gi) * 1_000);
        }
    }
    try poset.unbindCellsEverywhere(&[_]u64{ 0, 1_000 });
    try poset.unbindMemcell(goal_ids[0], 2);

    // A goal with no bindings must not leave an empty container behind
    // either, and the `put` in `bindMemcell` must not leak its own value.
    const sparse_id = try poset.create("sparse", "d", null, 5, null, 0, &next);
    try poset.bindMemcell(sparse_id, 77);
    try poset.unbindMemcell(sparse_id, 77);

    poset.deinit();
}

test "GoalPoset: bindMemcell surfaces a goal the poset does not hold" {
    var poset = GoalPoset.init(std.testing.allocator);
    defer poset.deinit();

    // Binding must not silently create a reverse-index entry for a goal
    // that does not exist -- that entry would count towards invariant (c).
    try std.testing.expectError(errors.Error.GoalNotFound, poset.bindMemcell(4_242, 1));
    try std.testing.expect(poset.memcell_index.count() == 0);
}
