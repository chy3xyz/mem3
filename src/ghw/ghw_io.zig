//! GHW I/O — the cross-layer communication interface.
//!
//! **Constitution Principle II**: cross-layer shortcuts are forbidden. All
//! inter-layer access MUST go through this interface. Each call records
//! the direction (外拓 = encoding Goal→Harness→World, 内求 = retrieval
//! World→Harness→Goal) and validates it against the allowed directions.
//!
//! ## Why this file exists at all
//!
//! `HarnessRegistry` and `WorldModel` were fully implemented, fully tested
//! and constructed nowhere outside their own tests, while `Store` — the
//! only path production ever takes — used `GoalPoset` and nothing else.
//! A NON-NEGOTIABLE constitutional principle was therefore not enforced by
//! the shipping binary. The traversal lives here, on `GHW`, so that both
//! directions are written down once and `Store` has nothing to get wrong.

const std = @import("std");
const Allocator = std.mem.Allocator;
const GoalPoset = @import("goal_tree.zig").GoalPoset;
const HarnessRegistry = @import("harness_registry.zig").HarnessRegistry;
const WorldModel = @import("world_model.zig").WorldModel;

pub const Direction = enum {
    /// Encoding: Goal → Harness → World
    outward,
    /// Retrieval: World → Harness → Goal
    inward,
};

/// Attribute key the World layer uses to record which Harness realises it.
/// Retrieval reads it back to cross the world→harness hop, so the hop
/// moves a real value instead of being a labelled no-op.
pub const HARNESS_ATTR: []const u8 = "harness";
/// Attribute key carrying the id of the most recently encoded cell.
pub const LAST_CELL_ATTR: []const u8 = "last_cell";
/// Attribute key carrying the vocabulary this situation is observed
/// through. Without it the world entity is nothing but an id and a
/// pointer, and `bestMatchFor` has no basis on which to choose.
pub const TOPIC_ATTR: []const u8 = "topic";

/// A cross-layer hop was attempted in a direction Principle II forbids.
/// Never expected; when it fires it means a traversal was written wrong,
/// so it is an error rather than a warning.
pub const DirectionError = error{InvalidCrossLayerDirection};

/// Composite handle to all three GHW layers.
pub const GHW = struct {
    /// The store's allocator. Held explicitly rather than borrowed from
    /// `ids`, so the traversals never have to guess who owns the few
    /// strings they build.
    alloc: Allocator,
    goals: *GoalPoset,
    harness: *HarnessRegistry,
    world: *WorldModel,
    /// Shared monotonic id source, so harnesses and world entities draw
    /// from the same sequence `Store` already advances for cells and
    /// goals.
    ids: *std.atomic.Value(u64),

    pub fn init(
        alloc: Allocator,
        goals: *GoalPoset,
        harness: *HarnessRegistry,
        world: *WorldModel,
        ids: *std.atomic.Value(u64),
    ) GHW {
        return .{
            .alloc = alloc,
            .goals = goals,
            .harness = harness,
            .world = world,
            .ids = ids,
        };
    }

    /// 外拓 — encode one memory across all three layers.
    ///
    /// Hop 1 (Goal → Harness): the goal is bound to the memory and its
    /// goal-bound harness (象源, the regulatory/procedural record) is
    /// materialised or reused, then credited with the execution.
    ///
    /// Hop 2 (Harness → World): the harness's situation is registered in
    /// the world model (物源) as a situated entity, which records which
    /// harness realises it — that back-reference is what retrieval reads
    /// to make the world→harness hop real.
    ///
    /// Both hops are direction-checked before they run. Each layer is
    /// keyed by `goal_id`, so a store with N goals holds N harnesses and
    /// N world entities no matter how many cells are encoded: the hot
    /// path stays O(1) and memory stays bounded across a daemon's life.
    /// Per-memory evidence lands as counters (`execution_count`,
    /// `total_duration_ms`) and a last-observed attribute, never as an
    /// unbounded per-cell list.
    pub fn encode(self: *GHW, xlog: *CrossLayerLog, req: EncodeRequest) !void {
        const node = self.goals.get(req.goal_id) orelse return error.GoalNotFound;

        // --- hop 1: Goal → Harness -------------------------------------
        if (!isValidDirection(.outward, .goal, .harness)) return error.InvalidCrossLayerDirection;
        const caps = try capabilityTags(self.alloc, node.name, node.description);
        defer self.alloc.free(caps);
        const harness_id = self.harness.ensureForGoal(
            req.goal_id,
            node.name,
            node.description,
            caps,
            "mem3",
            req.now_ms,
            self.ids,
        ) catch |err| return err;
        try self.harness.recordExecution(harness_id, true, 0);
        try xlog.log(.{
            .ts_ms = req.now_ms,
            .from = .goal,
            .to = .harness,
            .direction = .outward,
            .cell_id = req.cell_id,
        });

        // --- hop 2: Harness → World ------------------------------------
        if (!isValidDirection(.outward, .harness, .world)) return error.InvalidCrossLayerDirection;
        var name_buf: [48]u8 = undefined;
        const entity_name = try std.fmt.bufPrint(&name_buf, "goal:{d}", .{req.goal_id});
        const entity_id = try self.world.upsert("goal-scope", entity_name, req.now_ms, self.ids);
        var hid_buf: [24]u8 = undefined;
        const hid_str = try std.fmt.bufPrint(&hid_buf, "{d}", .{harness_id});
        try self.world.updateWithSurprise(entity_id, HARNESS_ATTR, hid_str, req.now_ms, 0.0);
        var cid_buf: [24]u8 = undefined;
        const cid_str = try std.fmt.bufPrint(&cid_buf, "{d}", .{req.cell_id});
        try self.world.updateWithSurprise(entity_id, LAST_CELL_ATTR, cid_str, req.now_ms, 0.0);
        // What the situation is *about*, as the harness sees it. Bounded:
        // `capabilityTags` caps the token count and length, and the world
        // replaces the previous value in place rather than growing.
        try self.world.updateWithSurprise(entity_id, TOPIC_ATTR, caps, req.now_ms, 0.0);
        try xlog.log(.{
            .ts_ms = req.now_ms,
            .from = .harness,
            .to = .world,
            .direction = .outward,
            .cell_id = req.cell_id,
        });
    }

    /// 内求 — retrieval across all three layers.
    ///
    /// Hop 1 (World → Harness): the world model picks the situated
    /// entity that best matches the query text and hands control to the
    /// harness that entity names.
    ///
    /// Hop 2 (Harness → Goal): that harness names the goal it realises.
    ///
    /// The returned goal id is the Goal-layer signal retrieval ranks
    /// with; `null` means the world has no state for this query yet and
    /// the caller falls back to whatever goal scope it already had.
    pub fn retrieve(self: *GHW, xlog: *CrossLayerLog, task: []const u8, now_ms: i64) !?u64 {
        // --- hop 1: World → Harness -----------------------------------
        if (!isValidDirection(.inward, .world, .harness)) return error.InvalidCrossLayerDirection;
        const entity_id = self.world.bestMatchFor(task) orelse return null;
        const hid_str = self.world.entityAttribute(entity_id, HARNESS_ATTR) orelse return null;
        const harness_id = std.fmt.parseInt(u64, hid_str, 10) catch return null;
        const harness = self.harness.get(harness_id) orelse return null;
        try xlog.log(.{
            .ts_ms = now_ms,
            .from = .world,
            .to = .harness,
            .direction = .inward,
            .cell_id = harness_id,
        });

        // --- hop 2: Harness → Goal ------------------------------------
        if (!isValidDirection(.inward, .harness, .goal)) return error.InvalidCrossLayerDirection;
        const goal_id = self.harness.goalOf(harness.id) orelse return null;
        try xlog.log(.{
            .ts_ms = now_ms,
            .from = .harness,
            .to = .goal,
            .direction = .inward,
            .cell_id = goal_id,
        });
        return goal_id;
    }
};

pub const EncodeRequest = struct {
    goal_id: u64,
    cell_id: u64,
    now_ms: i64,
};

/// Capability tags for a goal-bound harness: the goal's own name plus a
/// bounded slice of its description, semicolon-joined to match
/// `HarnessRegistry.findBestForTask`'s token scan.
///
/// Bounded on purpose: the result is duped into the harness, so an
/// unbounded description would make one harness's fixed cost scale with
/// user text.
fn capabilityTags(alloc: Allocator, name: []const u8, description: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, truncateToken(name));

    var it = std.mem.tokenizeAny(u8, description, " \t\r\n");
    var taken: usize = 0;
    while (it.next()) |tok| {
        if (taken >= MAX_CAPABILITY_TOKENS) break;
        const t = truncateToken(tok);
        if (t.len == 0) continue;
        try buf.append(alloc, ';');
        try buf.appendSlice(alloc, t);
        taken += 1;
    }
    return buf.toOwnedSlice(alloc);
}

const MAX_CAPABILITY_TOKENS: usize = 16;
const MAX_CAPABILITY_TOKEN_LEN: usize = 32;

fn truncateToken(tok: []const u8) []const u8 {
    if (tok.len <= MAX_CAPABILITY_TOKEN_LEN) return tok;
    return tok[0..MAX_CAPABILITY_TOKEN_LEN];
}

/// Cross-layer log: records every inter-layer access for auditability.
///
/// **Bounded by construction.** A long-running daemon encodes and
/// retrieves forever; an append-only log would grow without limit and
/// turn observability into the store's largest leak. Past `cap` the
/// oldest entry is overwritten, so memory is `cap × @sizeOf(Entry)`
/// forever and `count()` never exceeds `cap`. Ordering is preserved
/// (`swapRemove` would scramble the traversal sequence the log exists to
/// record, so the ring is indexed explicitly).
pub const CrossLayerLog = struct {
    alloc: Allocator,
    entries: std.ArrayList(Entry),
    /// Maximum retained entries. Zero is clamped to `DEFAULT_CAP`.
    cap: usize,
    /// Index of the oldest live entry in `entries.items`.
    head: usize = 0,
    /// Number of live entries; `<= entries.items.len <= cap`.
    len: usize = 0,

    pub const Entry = struct {
        ts_ms: i64,
        from: Layer,
        to: Layer,
        direction: Direction,
        cell_id: ?u64 = null,
    };

    pub const Layer = enum { goal, harness, world };

    pub const DEFAULT_CAP: usize = 256;

    pub fn init(alloc: Allocator) CrossLayerLog {
        return initWithCap(alloc, DEFAULT_CAP);
    }

    pub fn initWithCap(alloc: Allocator, cap: usize) CrossLayerLog {
        return .{
            .alloc = alloc,
            .entries = .empty,
            .cap = if (cap == 0) DEFAULT_CAP else cap,
        };
    }

    pub fn deinit(self: *CrossLayerLog) void {
        self.entries.deinit(self.alloc);
    }

    /// Record a hop. Overwrites the oldest entry once full.
    pub fn log(self: *CrossLayerLog, e: Entry) !void {
        if (self.entries.items.len < self.cap) {
            try self.entries.append(self.alloc, e);
            self.len = self.entries.items.len;
            return;
        }
        const slot = (self.head + self.len) % self.cap;
        self.entries.items[slot] = e;
        self.head = (self.head + 1) % self.cap;
    }

    /// Live entries, oldest first.
    pub fn count(self: *const CrossLayerLog) usize {
        return self.len;
    }

    /// The `i`-th oldest live entry. Out of range yields null.
    pub fn nth(self: *const CrossLayerLog, i: usize) ?Entry {
        if (i >= self.len) return null;
        return self.entries.items[(self.head + i) % self.cap];
    }

    /// Chronological copy of the live entries. Caller owns the result.
    pub fn toOwnedSlice(self: *const CrossLayerLog, alloc: Allocator) ![]Entry {
        const out = try alloc.alloc(Entry, self.len);
        for (out, 0..) |*o, i| o.* = self.nth(i).?;
        return out;
    }
};

/// Validate a direction. Constitution Principle II: encoding MUST go
/// outward, retrieval MUST go inward, no shortcuts.
///
/// This used to be a `v0.2.0` stub that returned `true` for everything,
/// so the "shortcut" the constitution forbids was in fact permitted by
/// the only function written to detect it. Enforced now, and the
/// traversals in `GHW` check every hop against it before performing it.
pub fn isValidDirection(d: Direction, from: CrossLayerLog.Layer, to: CrossLayerLog.Layer) bool {
    return switch (d) {
        // 外拓: goal → harness → world
        .outward => (from == .goal and to == .harness) or
            (from == .harness and to == .world),
        // 内求: world → harness → goal
        .inward => (from == .world and to == .harness) or
            (from == .harness and to == .goal),
    };
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

test "isValidDirection: enforces the three-layer order both ways" {
    // Outward (encoding) admits exactly goal→harness and harness→world.
    try std.testing.expect(isValidDirection(.outward, .goal, .harness));
    try std.testing.expect(isValidDirection(.outward, .harness, .world));
    // No shortcut from Goal straight to World — Principle II's whole point.
    try std.testing.expect(!isValidDirection(.outward, .goal, .world));
    // No backwards or sideways hops.
    try std.testing.expect(!isValidDirection(.outward, .world, .harness));
    try std.testing.expect(!isValidDirection(.outward, .harness, .goal));
    try std.testing.expect(!isValidDirection(.outward, .world, .goal));
    try std.testing.expect(!isValidDirection(.outward, .goal, .goal));

    // Inward (retrieval) is the exact mirror.
    try std.testing.expect(isValidDirection(.inward, .world, .harness));
    try std.testing.expect(isValidDirection(.inward, .harness, .goal));
    try std.testing.expect(!isValidDirection(.inward, .world, .goal));
    try std.testing.expect(!isValidDirection(.inward, .harness, .world));
    try std.testing.expect(!isValidDirection(.inward, .goal, .harness));
}

test "CrossLayerLog: is bounded and keeps chronological order" {
    const alloc = std.testing.allocator;
    const cap = 8;
    var log_ = CrossLayerLog.initWithCap(alloc, cap);
    defer log_.deinit();

    // Drive 5x the cap. An unbounded log grows with the input; this one
    // must not, or a long-running daemon leaks by construction.
    var i: usize = 0;
    while (i < cap * 5) : (i += 1) {
        try log_.log(.{
            .ts_ms = @intCast(i),
            .from = .goal,
            .to = .harness,
            .direction = .outward,
            .cell_id = i,
        });
        try std.testing.expect(log_.count() <= cap);
    }
    try std.testing.expectEqual(cap, log_.count());

    // The survivors are the newest `cap` entries, oldest-first.
    const kept = try log_.toOwnedSlice(alloc);
    defer alloc.free(kept);
    try std.testing.expectEqual(cap, kept.len);
    for (kept, 0..) |e, j| {
        try std.testing.expectEqual(@as(u64, @intCast(cap * 4 + j)), e.cell_id.?);
    }
}

test "GHW: encode traverses Goal → Harness → World and records both hops" {
    const alloc = std.testing.allocator;
    var goals = GoalPoset.init(alloc);
    defer goals.deinit();
    var harness = HarnessRegistry.init(alloc);
    defer harness.deinit();
    var world = WorldModel.init(alloc);
    defer world.deinit();
    var ids: std.atomic.Value(u64) = .init(1);
    var ghw = GHW.init(alloc, &goals, &harness, &world, &ids);
    var xlog = CrossLayerLog.init(alloc);
    defer xlog.deinit();

    const gid = try goals.create("build mem3", "compile the memory operating system", null, 9, null, 0, &ids);
    try ghw.encode(&xlog, .{ .goal_id = gid, .cell_id = 77, .now_ms = 1000 });

    // Both layers are populated, not just the goal.
    try std.testing.expectEqual(@as(usize, 1), harness.count());
    try std.testing.expectEqual(@as(usize, 1), world.count());
    try std.testing.expectEqual(@as(u64, 1), harness.get(harness.harnessForGoal(gid).?).?.execution_count);

    // And the traversal order is exactly the constitutional one.
    try std.testing.expectEqual(@as(usize, 2), xlog.count());
    const e0 = xlog.nth(0).?;
    const e1 = xlog.nth(1).?;
    try std.testing.expect(e0.from == .goal and e0.to == .harness and e0.direction == .outward);
    try std.testing.expect(e1.from == .harness and e1.to == .world and e1.direction == .outward);
    try std.testing.expect(isValidDirection(e0.direction, e0.from, e0.to));
    try std.testing.expect(isValidDirection(e1.direction, e1.from, e1.to));
}

test "GHW: encode is idempotent per goal — layers stay bounded" {
    const alloc = std.testing.allocator;
    var goals = GoalPoset.init(alloc);
    defer goals.deinit();
    var harness = HarnessRegistry.init(alloc);
    defer harness.deinit();
    var world = WorldModel.init(alloc);
    defer world.deinit();
    var ids: std.atomic.Value(u64) = .init(1);
    var ghw = GHW.init(alloc, &goals, &harness, &world, &ids);
    var xlog = CrossLayerLog.init(alloc);
    defer xlog.deinit();

    const gid = try goals.create("write tests", "cover the ghw traversal", null, 5, null, 0, &ids);
    var n: u64 = 0;
    while (n < 100) : (n += 1) {
        try ghw.encode(&xlog, .{ .goal_id = gid, .cell_id = 1000 + n, .now_ms = @intCast(n) });
    }

    // 100 memories, one goal: still one harness, one world entity. The
    // per-memory evidence is a counter, not a list.
    try std.testing.expectEqual(@as(usize, 1), harness.count());
    try std.testing.expectEqual(@as(usize, 1), world.count());
    try std.testing.expectEqual(@as(u64, 100), harness.get(harness.harnessForGoal(gid).?).?.execution_count);
    var entity_id: u64 = 0;
    var eit = world.entities.iterator();
    while (eit.next()) |entry| entity_id = entry.value_ptr.*.id;
    try std.testing.expectEqualStrings("1099", world.entityAttribute(entity_id, LAST_CELL_ATTR).?);
}

test "GHW: retrieve traverses World → Harness → Goal" {
    const alloc = std.testing.allocator;
    var goals = GoalPoset.init(alloc);
    defer goals.deinit();
    var harness = HarnessRegistry.init(alloc);
    defer harness.deinit();
    var world = WorldModel.init(alloc);
    defer world.deinit();
    var ids: std.atomic.Value(u64) = .init(1);
    var ghw = GHW.init(alloc, &goals, &harness, &world, &ids);
    var xlog = CrossLayerLog.init(alloc);
    defer xlog.deinit();

    const gid = try goals.create("zig compilation", "build the zig test binary", null, 8, null, 0, &ids);
    try ghw.encode(&xlog, .{ .goal_id = gid, .cell_id = 5, .now_ms = 1000 });
    const before = xlog.count();

    // The query names the goal's own vocabulary, so the world entity is
    // the best match and the traversal resolves back to that goal.
    const resolved = try ghw.retrieve(&xlog, "zig compilation build", 2000);
    try std.testing.expectEqual(gid, resolved.?);

    try std.testing.expectEqual(before + 2, xlog.count());
    const e0 = xlog.nth(before).?;
    const e1 = xlog.nth(before + 1).?;
    try std.testing.expect(e0.from == .world and e0.to == .harness and e0.direction == .inward);
    try std.testing.expect(e1.from == .harness and e1.to == .goal and e1.direction == .inward);
    try std.testing.expect(isValidDirection(e0.direction, e0.from, e0.to));
    try std.testing.expect(isValidDirection(e1.direction, e1.from, e1.to));
}

test "GHW: retrieve on an empty world resolves nothing instead of guessing" {
    const alloc = std.testing.allocator;
    var goals = GoalPoset.init(alloc);
    defer goals.deinit();
    var harness = HarnessRegistry.init(alloc);
    defer harness.deinit();
    var world = WorldModel.init(alloc);
    defer world.deinit();
    var ids: std.atomic.Value(u64) = .init(1);
    var ghw = GHW.init(alloc, &goals, &harness, &world, &ids);
    var xlog = CrossLayerLog.init(alloc);
    defer xlog.deinit();

    try std.testing.expectEqual(@as(?u64, null), try ghw.retrieve(&xlog, "anything", 0));
    try std.testing.expectEqual(@as(usize, 0), xlog.count());
}

test "GHW: encode rejects a goal the poset does not hold" {
    const alloc = std.testing.allocator;
    var goals = GoalPoset.init(alloc);
    defer goals.deinit();
    var harness = HarnessRegistry.init(alloc);
    defer harness.deinit();
    var world = WorldModel.init(alloc);
    defer world.deinit();
    var ids: std.atomic.Value(u64) = .init(1);
    var ghw = GHW.init(alloc, &goals, &harness, &world, &ids);
    var xlog = CrossLayerLog.init(alloc);
    defer xlog.deinit();

    try std.testing.expectError(
        error.GoalNotFound,
        ghw.encode(&xlog, .{ .goal_id = 4242, .cell_id = 1, .now_ms = 0 }),
    );
    try std.testing.expectEqual(@as(usize, 0), harness.count());
    try std.testing.expectEqual(@as(usize, 0), world.count());
}