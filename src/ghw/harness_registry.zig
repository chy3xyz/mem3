//! Harness Registry — execution primitives registered by the agent.
//!
//! **GHW Layer**: Harness (象源). Sits between Goal and World; the
//! "regulatory memory" of the system. In v0.1.0-alpha the registry is
//! in-memory only — harnesses are lost on restart.
//!
//! ## Constitution compliance
//! - Principle II (GHW 三层耦合): this is the Harness layer.
//! - Principle V (comptime): stats fields are updated in-place, no reflection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const GoalNode = @import("goal_node.zig").GoalNode;
const errors = @import("../core/errors.zig");

pub const Harness = struct {
    id: u64,
    name: []const u8,
    description: []const u8,
    /// Semicolon-separated capability tags. e.g. "exec;io;net".
    capabilities: []const u8,
    /// Version string, e.g. "zig-0.17.0-dev.704".
    version: []const u8,
    execution_count: u64 = 0,
    success_count: u64 = 0,
    /// Sum of all execution durations in ms. Avg = total/count.
    total_duration_ms: u64 = 0,
    /// Skill-memory bindings (MemCell ids). Used for procedural memory.
    skill_memories: []const u64 = &.{},
    created_at: i64,
    is_active: bool = true,

    pub fn deinit(self: *Harness, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.capabilities);
        alloc.free(self.version);
        alloc.free(self.skill_memories);
    }

    pub fn successRate(self: *const Harness) f32 {
        if (self.execution_count == 0) return 0.0;
        return @as(f32, @floatFromInt(self.success_count)) /
            @as(f32, @floatFromInt(self.execution_count));
    }

    pub fn avgDuration(self: *const Harness) f32 {
        if (self.execution_count == 0) return 0.0;
        return @as(f32, @floatFromInt(self.total_duration_ms)) /
            @as(f32, @floatFromInt(self.execution_count));
    }
};

pub const HarnessRegistry = struct {
    alloc: Allocator,
    harnesses: std.AutoHashMap(u64, *Harness),

    pub fn init(alloc: Allocator) HarnessRegistry {
        return .{
            .alloc = alloc,
            .harnesses = std.AutoHashMap(u64, *Harness).init(alloc),
        };
    }

    pub fn deinit(self: *HarnessRegistry) void {
        var it = self.harnesses.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.harnesses.deinit();
    }

    /// Register a new harness. Returns the assigned id.
    pub fn register(
        self: *HarnessRegistry,
        name: []const u8,
        description: []const u8,
        capabilities: []const u8,
        version: []const u8,
        now_ms: i64,
        next_id: *std.atomic.Value(u64),
    ) errors.Error!u64 {
        const id = next_id.fetchAdd(1, .monotonic);
        const h = try self.alloc.create(Harness);
        errdefer self.alloc.destroy(h);
        h.* = .{
            .id = id,
            .name = try self.alloc.dupe(u8, name),
            .description = try self.alloc.dupe(u8, description),
            .capabilities = try self.alloc.dupe(u8, capabilities),
            .version = try self.alloc.dupe(u8, version),
            .created_at = now_ms,
        };
        try self.harnesses.put(id, h);
        return id;
    }

    /// Record a harness execution. Updates success_count and total_duration.
    pub fn recordExecution(
        self: *HarnessRegistry,
        id: u64,
        success: bool,
        duration_ms: u64,
    ) errors.Error!void {
        const h = self.harnesses.getPtr(id) orelse return errors.Error.GoalNotFound;
        h.execution_count += 1;
        if (success) h.success_count += 1;
        h.total_duration_ms += duration_ms;
    }

    /// Find the best harness for a task description. Naive keyword match on
    /// the description and capabilities — the v0.1.0 stub. v0.2.0 will
    /// integrate a learned selector.
    pub fn findBestForTask(
        self: *HarnessRegistry,
        task_description: []const u8,
    ) ?*Harness {
        var best: ?*Harness = null;
        var best_score: f32 = 0.0;
        var it = self.harnesses.iterator();
        while (it.next()) |entry| {
            const h = entry.value_ptr.*;
            if (!h.is_active) continue;
            const score = scoreMatch(task_description, h);
            if (score > best_score) {
                best_score = score;
                best = h;
            }
        }
        return best;
    }

    fn scoreMatch(task: []const u8, h: *const Harness) f32 {
        // Naive scoring: fraction of capability tokens present in task.
        var score: f32 = h.successRate() * 0.4; // weight: reliability
        var iter = std.mem.splitScalar(u8, h.capabilities, ';');
        var total: usize = 0;
        var hits: usize = 0;
        while (iter.next()) |cap| {
            const trimmed = std.mem.trim(u8, cap, " \t");
            if (trimmed.len == 0) continue;
            total += 1;
            if (std.mem.indexOf(u8, task, trimmed) != null) {
                hits += 1;
            }
        }
        if (total > 0) {
            score += @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(total)) * 0.6;
        }
        return score;
    }

    pub fn count(self: *const HarnessRegistry) usize {
        return self.harnesses.count();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "HarnessRegistry: register + lookup" {
    var reg = HarnessRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var next: std.atomic.Value(u64) = .init(1);

    const id = try reg.register("zig-build", "compile a zig project", "exec;compile", "0.17.0", 0, &next);
    try std.testing.expect(id > 0);

    const h = reg.harnesses.get(id).?;
    try std.testing.expectEqualStrings("zig-build", h.name);
    try std.testing.expectEqual(@as(u64, 0), h.execution_count);
    try std.testing.expectEqual(@as(f32, 0.0), h.successRate());
}

test "HarnessRegistry: record execution updates stats" {
    var reg = HarnessRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    const id = try reg.register("h", "d", "exec", "0", 0, &next);

    try reg.recordExecution(id, true, 100);
    try reg.recordExecution(id, false, 200);
    try reg.recordExecution(id, true, 300);

    const h = reg.harnesses.get(id).?;
    try std.testing.expectEqual(@as(u64, 3), h.execution_count);
    try std.testing.expectEqual(@as(u64, 2), h.success_count);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), h.successRate(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), h.avgDuration(), 1e-6);
}

test "HarnessRegistry: findBestForTask uses capabilities" {
    var reg = HarnessRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var next: std.atomic.Value(u64) = .init(1);
    _ = try reg.register("compile", "compile a zig project", "compile;zig;build", "0", 0, &next);
    _ = try reg.register("net", "fetch a URL", "net;http;curl", "0", 0, &next);

    const best = reg.findBestForTask("I want to compile my zig project");
    try std.testing.expect(best != null);
    try std.testing.expectEqualStrings("compile", best.?.name);
}
