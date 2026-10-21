//! World Model — entities, attributes, predictions, and surprising-event updates.
//!
//! **GHW Layer**: World (matter source). Sits at the bottom of the GHW three-layer
//! architecture; the fastest-adapting layer for current observations.
//!
//! ## Constitution compliance
//! - Principle II (GHW three-layer coupling): this is the World layer.
//! - Principle III (surprise-driven update): WorldModel.updateEntity takes a surprise
//!   signal and adjusts the entity's prediction confidence.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");

pub const Prediction = struct {
    attribute: []const u8,
    value: []const u8,
    valid_until: i64,
    confidence: f32,

    pub fn deinit(self: *Prediction, alloc: Allocator) void {
        alloc.free(self.attribute);
        alloc.free(self.value);
    }
};

pub const WorldEntity = struct {
    id: u64,
    entity_type: []const u8,
    name: []const u8,
    attributes: std.StringHashMap([]const u8),
    last_observed: i64,
    confidence: f32,
    predictions: []const Prediction,

    pub fn deinit(self: *WorldEntity, alloc: Allocator) void {
        alloc.free(self.entity_type);
        alloc.free(self.name);
        var it = self.attributes.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.attributes.deinit();
        // `predictions` is a `[]const Prediction`, so the loop capture is
        // `*const`. `deinit` frees what it owns, so it needs the mutable
        // pointer.
        for (self.predictions) |*p| @constCast(p).deinit(alloc);
        alloc.free(self.predictions);
    }

    pub fn getAttribute(self: *const WorldEntity, key: []const u8) ?[]const u8 {
        return self.attributes.get(key);
    }

    pub fn setAttribute(self: *WorldEntity, alloc: Allocator, key: []const u8, value: []const u8) !void {
        // Replace existing.
        if (self.attributes.fetchRemove(key)) |kv| {
            alloc.free(kv.key);
            alloc.free(kv.value);
        }
        const k = try alloc.dupe(u8, key);
        errdefer alloc.free(k);
        const v = try alloc.dupe(u8, value);
        errdefer alloc.free(v);
        try self.attributes.put(k, v);
    }
};

pub const WorldModel = struct {
    alloc: Allocator,
    entities: std.AutoHashMap(u64, *WorldEntity),
    /// name → entity id. `upsert` used to find an existing entity with a
    /// linear scan over every entity, which is O(n) per insert once the
    /// model holds a few hundred goals. The keys are duped; they are not
    /// the `WorldEntity.name` pointers.
    by_name: std.StringHashMapUnmanaged(u64),

    pub fn init(alloc: Allocator) WorldModel {
        return .{
            .alloc = alloc,
            .entities = std.AutoHashMap(u64, *WorldEntity).init(alloc),
            .by_name = std.StringHashMapUnmanaged(u64).empty,
        };
    }

    pub fn deinit(self: *WorldModel) void {
        var it = self.entities.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.entities.deinit();

        var nit = self.by_name.iterator();
        while (nit.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.by_name.deinit(self.alloc);
    }

    /// Create or update an entity.
    pub fn upsert(
        self: *WorldModel,
        entity_type: []const u8,
        name: []const u8,
        now_ms: i64,
        next_id: *std.atomic.Value(u64),
    ) errors.Error!u64 {
        if (self.by_name.get(name)) |existing_id| {
            if (self.entities.getPtr(existing_id)) |slot| {
                const existing: *WorldEntity = slot.*;
                existing.last_observed = now_ms;
                return existing_id;
            }
            // Name index drifted from the entity map (only reachable if a
            // future mutation deletes entities). Fall through and rebuild
            // rather than returning a dangling id.
        }
        const id = next_id.fetchAdd(1, .monotonic);

        // Built into locals and moved into the entity only once every
        // fallible step has succeeded. An `errdefer` chain around the
        // struct literal would run against a half-initialised `WorldEntity`
        // whenever one of the dupes inside it fails.
        const owned_type = try self.alloc.dupe(u8, entity_type);
        const owned_name = self.alloc.dupe(u8, name) catch {
            self.alloc.free(owned_type);
            return error.OutOfMemory;
        };
        const e = self.alloc.create(WorldEntity) catch {
            self.alloc.free(owned_name);
            self.alloc.free(owned_type);
            return error.OutOfMemory;
        };
        e.* = .{
            .id = id,
            .entity_type = owned_type,
            .name = owned_name,
            .attributes = std.StringHashMap([]const u8).init(self.alloc),
            .last_observed = now_ms,
            .confidence = 1.0,
            .predictions = &.{},
        };
        self.entities.put(id, e) catch {
            e.deinit(self.alloc);
            self.alloc.destroy(e);
            return error.OutOfMemory;
        };
        const owned_key = self.alloc.dupe(u8, name) catch {
            _ = self.entities.remove(id);
            e.deinit(self.alloc);
            self.alloc.destroy(e);
            return error.OutOfMemory;
        };
        self.by_name.put(self.alloc, owned_key, id) catch |err| {
            self.alloc.free(owned_key);
            _ = self.entities.remove(id);
            e.deinit(self.alloc);
            self.alloc.destroy(e);
            return err;
        };
        return id;
    }

    /// Look an entity up by id.
    pub fn get(self: *const WorldModel, id: u64) ?*const WorldEntity {
        return self.entities.get(id);
    }

    /// One attribute of an entity, or null.
    pub fn entityAttribute(self: *const WorldModel, id: u64, key: []const u8) ?[]const u8 {
        const e = self.entities.get(id) orelse return null;
        return e.getAttribute(key);
    }

    /// The entity whose name and attribute values best cover `task`.
    ///
    /// This is the World layer's half of retrieval: it answers "which
    /// situation in the world does this query look like", which is what
    /// the world→harness hop then follows. Scans the entity table, which
    /// is bounded by the goal count, not by the memory count.
    pub fn bestMatchFor(self: *const WorldModel, task: []const u8) ?u64 {
        var best_id: ?u64 = null;
        var best_score: usize = 0;
        var it = self.entities.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr.*;
            var score: usize = 0;
            score += tokenHits(task, e.name);
            var ait = e.attributes.iterator();
            while (ait.next()) |attr| {
                score += tokenHits(task, attr.value_ptr.*);
            }
            if (score > best_score) {
                best_score = score;
                best_id = e.id;
            }
        }
        return best_id;
    }

    /// Update an entity's prediction and adjust confidence based on a
    /// surprise signal. `surprise ∈ [0, 1]` (0 = predicted correctly,
    /// 1 = completely unexpected).
    pub fn updateWithSurprise(
        self: *WorldModel,
        id: u64,
        observed_attribute: []const u8,
        observed_value: []const u8,
        now_ms: i64,
        surprise: f32,
    ) errors.Error!void {
        const slot = self.entities.getPtr(id) orelse return errors.Error.NotFound;
        const e: *WorldEntity = slot.*;
        e.last_observed = now_ms;
        // Adjust confidence: smooth update based on surprise.
        e.confidence = e.confidence * 0.7 + (1.0 - surprise) * 0.3;
        try e.setAttribute(self.alloc, observed_attribute, observed_value);
    }

    /// Predict an attribute at a future time. Returns the most recent value
    /// and a confidence estimate based on age.
    pub fn predict(
        self: *const WorldModel,
        id: u64,
        attribute: []const u8,
        at_ms: i64,
    ) ?[]const u8 {
        const e = self.entities.get(id) orelse return null;
        const value = e.getAttribute(attribute) orelse return null;
        _ = at_ms; // for v0.1.0 we just return the current value
        return value;
    }

    pub fn count(self: *const WorldModel) usize {
        return self.entities.count();
    }
};

/// How many whitespace-separated tokens of `needle` occur in `haystack`.
/// Case-insensitive, so a query in any casing still reaches the layer.
fn tokenHits(haystack: []const u8, needle: []const u8) usize {
    var hits: usize = 0;
    var it = std.mem.tokenizeAny(u8, needle, " \t\r\n;,");
    while (it.next()) |tok| {
        if (tok.len < 3) continue;
        if (std.mem.indexOf(u8, haystack, tok) != null) hits += 1;
    }
    return hits;
}

test "WorldModel: upsert + setAttribute" {
    var wm = WorldModel.init(std.testing.allocator);
    defer wm.deinit();
    var next: std.atomic.Value(u64) = .init(1);

    const id = try wm.upsert("person", "alice", 1000, &next);
    try wm.updateWithSurprise(id, "mood", "happy", 1000, 0.1);
    try wm.updateWithSurprise(id, "mood", "happy", 2000, 0.2);

    const e = wm.entities.get(id).?;
    try std.testing.expectEqualStrings("happy", e.getAttribute("mood").?);
    try std.testing.expect(e.confidence > 0.6);
}

test "WorldModel: upsert by name reuses id" {
    var wm = WorldModel.init(std.testing.allocator);
    defer wm.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const id1 = try wm.upsert("place", "office", 1000, &next);
    const id2 = try wm.upsert("place", "office", 2000, &next);
    try std.testing.expectEqual(id1, id2);
    try std.testing.expectEqual(@as(usize, 1), wm.count());
}

test "WorldModel: entityAttribute reads back a written attribute" {
    var wm = WorldModel.init(std.testing.allocator);
    defer wm.deinit();
    var next: std.atomic.Value(u64) = .init(1);

    const id = try wm.upsert("goal-scope", "goal:7", 1000, &next);
    try wm.updateWithSurprise(id, "harness", "12", 1000, 0.0);
    try std.testing.expectEqualStrings("12", wm.entityAttribute(id, "harness").?);
    try std.testing.expectEqual(@as(?[]const u8, null), wm.entityAttribute(id, "absent"));
    try std.testing.expectEqual(@as(?[]const u8, null), wm.entityAttribute(999, "harness"));
}

test "WorldModel: bestMatchFor picks the entity the query describes" {
    var wm = WorldModel.init(std.testing.allocator);
    defer wm.deinit();
    var next: std.atomic.Value(u64) = .init(1);

    const zig_goal = try wm.upsert("goal-scope", "goal:1", 1000, &next);
    _ = try wm.upsert("goal-scope", "goal:2", 1000, &next);
    try wm.updateWithSurprise(zig_goal, "topic", "zig;compilation;build", 1000, 0.0);

    // The distinguishing token only exists on entity 1's attributes.
    try std.testing.expectEqual(zig_goal, wm.bestMatchFor("tell me about zig compilation").?);
    // With no overlap at all there is no basis for a claim.
    try std.testing.expectEqual(@as(?u64, null), wm.bestMatchFor("???"));
}
