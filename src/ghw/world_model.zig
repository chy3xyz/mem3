//! World Model — entities, attributes, predictions, and surprising-event updates.
//!
//! **GHW Layer**: World (物源). Sits at the bottom of the GHW three-layer
//! architecture; the fastest-adapting layer for current observations.
//!
//! ## Constitution compliance
//! - Principle II (GHW 三层耦合): this is the World layer.
//! - Principle III (惊讶驱动更新): WorldModel.updateEntity takes a surprise
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
        for (self.predictions) |*p| p.deinit(alloc);
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

    pub fn init(alloc: Allocator) WorldModel {
        return .{
            .alloc = alloc,
            .entities = std.AutoHashMap(u64, *WorldEntity).init(alloc),
        };
    }

    pub fn deinit(self: *WorldModel) void {
        var it = self.entities.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.entities.deinit();
    }

    /// Create or update an entity.
    pub fn upsert(
        self: *WorldModel,
        entity_type: []const u8,
        name: []const u8,
        now_ms: i64,
        next_id: *std.atomic.Value(u64),
    ) errors.Error!u64 {
        if (self.entities.getPtr(self.findByName(name))) |existing| {
            existing.last_observed = now_ms;
            return existing.id;
        }
        const id = next_id.fetchAdd(1, .monotonic);
        const e = try self.alloc.create(WorldEntity);
        errdefer self.alloc.destroy(e);
        e.* = .{
            .id = id,
            .entity_type = try self.alloc.dupe(u8, entity_type),
            .name = try self.alloc.dupe(u8, name),
            .attributes = std.StringHashMap([]const u8).init(self.alloc),
            .last_observed = now_ms,
            .confidence = 1.0,
            .predictions = &.{},
        };
        try self.entities.put(id, e);
        return id;
    }

    fn findByName(self: *WorldModel, name: []const u8) u64 {
        var it = self.entities.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.name, name)) return entry.key_ptr.*;
        }
        return 0;
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
        const e = self.entities.getPtr(id) orelse return errors.Error.NotFound;
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
