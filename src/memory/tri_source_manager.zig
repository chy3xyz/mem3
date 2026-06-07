//! Tri-Source Memory Manager — owns the three source sub-stores.
//!
//! **GHW Layer**: Memory (三源合恰). Sits between the three GHW layers and
//! the storage layer. Maintains physical isolation of the three sources
//! while allowing the lifecycle to act on them uniformly.
//!
//! ## Constitution compliance
//! - Principle I (三源完整性): every cell is routed to its source sub-store.
//! - Principle III (存在增益驱动): the manager exposes scoring used by
//!   consolidation and forgetting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const MemorySource = core.MemorySource;
const errors = core.Error;

const log = std.log.scoped(.mem3_tri_source);

/// In-memory tri-source store. Persistence is handled by the storage layer.
pub const TriSourceManager = struct {
    alloc: Allocator,
    sensory: std.AutoHashMap(u64, *MemCell),
    cognitive: std.AutoHashMap(u64, *MemCell),
    action: std.AutoHashMap(u64, *MemCell),
    next_id: *std.atomic.Value(u64),

    pub fn init(alloc: Allocator, next_id: *std.atomic.Value(u64)) TriSourceManager {
        return .{
            .alloc = alloc,
            .sensory = std.AutoHashMap(u64, *MemCell).init(alloc),
            .cognitive = std.AutoHashMap(u64, *MemCell).init(alloc),
            .action = std.AutoHashMap(u64, *MemCell).init(alloc),
            .next_id = next_id,
        };
    }

    pub fn deinit(self: *TriSourceManager) void {
        // Free each cell pointer and its owned slices.
        var it_s = self.sensory.iterator();
        while (it_s.next()) |entry| {
            freeCell(self.alloc, entry.value_ptr.*);
        }
        self.sensory.deinit();

        var it_c = self.cognitive.iterator();
        while (it_c.next()) |entry| {
            freeCell(self.alloc, entry.value_ptr.*);
        }
        self.cognitive.deinit();

        var it_a = self.action.iterator();
        while (it_a.next()) |entry| {
            freeCell(self.alloc, entry.value_ptr.*);
        }
        self.action.deinit();
    }

    fn freeCell(alloc: Allocator, cell: *MemCell) void {
        // Use MemCell.deinit for string + container slice cleanup.
        cell.deinit(alloc);
        alloc.destroy(cell);
    }

    /// Add a memory. Assigns id, validates source + spirit dim, routes to
    /// the appropriate sub-store. The manager takes ownership of the
    /// cell's heap-allocated slices: it dups `episode`, `atomic_facts`,
    /// `foresight`, and `goal_associations` into its own allocator, so the
    /// caller may free its original slices immediately after this returns.
    pub fn add(self: *TriSourceManager, cell: MemCell) errors!u64 {
        // Spirit-dimension check.
        if (cell.foresight.len == 0 and cell.goal_associations.len == 0) {
            return errors.SpiritDimMissing;
        }
        if (cell.episode.len == 0) return errors.EmptyEpisode;
        if (cell.metadata.source_confidence < 0.5) return errors.SourceConfidenceTooLow;

        const cell_ptr = try self.alloc.create(MemCell);
        errdefer self.alloc.destroy(cell_ptr);

        // Dup the string and slice fields so the manager owns the copies.
        const episode = try self.alloc.dupe(u8, cell.episode);
        errdefer self.alloc.free(episode);

        const atomic_facts = blk: {
            if (cell.atomic_facts.len == 0) break :blk &[_]core.Fact{};
            const facts = try self.alloc.alloc(core.Fact, cell.atomic_facts.len);
            errdefer self.alloc.free(facts);
            for (cell.atomic_facts, 0..) |f, i| {
                facts[i] = .{
                    .subject = try self.alloc.dupe(u8, f.subject),
                    .predicate = try self.alloc.dupe(u8, f.predicate),
                    .object = try self.alloc.dupe(u8, f.object),
                    .confidence = f.confidence,
                    .source = try self.alloc.dupe(u8, f.source),
                };
            }
            break :blk facts;
        };
        errdefer {
            for (atomic_facts) |f| {
                self.alloc.free(f.subject);
                self.alloc.free(f.predicate);
                self.alloc.free(f.object);
                self.alloc.free(f.source);
            }
            self.alloc.free(atomic_facts);
        }

        const foresight = blk: {
            if (cell.foresight.len == 0) break :blk &[_]core.Foresight{};
            const fs = try self.alloc.alloc(core.Foresight, cell.foresight.len);
            for (cell.foresight, 0..) |f, i| {
                fs[i] = .{
                    .description = try self.alloc.dupe(u8, f.description),
                    .valid_from = f.valid_from,
                    .valid_until = f.valid_until,
                    .confidence = f.confidence,
                };
            }
            break :blk fs;
        };
        errdefer {
            for (foresight) |f| self.alloc.free(f.description);
            self.alloc.free(foresight);
        }

        const goal_associations = blk: {
            if (cell.goal_associations.len == 0) break :blk &[_]core.GoalAssociation{};
            const gs = try self.alloc.dupe(core.GoalAssociation, cell.goal_associations);
            break :blk gs;
        };
        errdefer self.alloc.free(goal_associations);

        cell_ptr.* = .{
            .id = self.next_id.fetchAdd(1, .monotonic),
            .source = cell.source,
            .episode = episode,
            .atomic_facts = atomic_facts,
            .foresight = foresight,
            .goal_associations = goal_associations,
            .metadata = cell.metadata,
        };

        const map = self.mapFor(cell.source);
        try map.put(cell_ptr.id, cell_ptr);

        log.debug("addMem: id={d} source={s}", .{ cell_ptr.id, cell.source.label() });
        return cell_ptr.id;
    }

    /// Get a memory by id, searching all three sources.
    pub fn get(self: *TriSourceManager, id: u64) ?*MemCell {
        if (self.sensory.get(id)) |p| return p;
        if (self.cognitive.get(id)) |p| return p;
        if (self.action.get(id)) |p| return p;
        return null;
    }

    /// All memories of a given source. Returns an owned slice.
    pub fn getBySource(self: *TriSourceManager, alloc: Allocator, source: MemorySource) errors![]const *MemCell {
        const map = self.mapFor(source);
        var list = std.ArrayList(*MemCell).empty;
        errdefer list.deinit(alloc);
        var it = map.iterator();
        while (it.next()) |entry| {
            try list.append(alloc, entry.value_ptr.*);
        }
        return list.toOwnedSlice(alloc);
    }

    /// Total number of memories across all three sources.
    pub fn count(self: *const TriSourceManager) usize {
        return self.sensory.count() + self.cognitive.count() + self.action.count();
    }

    /// Count by source.
    pub fn countBySource(self: *const TriSourceManager, source: MemorySource) usize {
        return self.mapForConst(source).count();
    }

    /// Remove a memory by id. The caller is responsible for calling
    /// `MemCell.deinit` if needed. Returns the cell pointer so the caller
    /// can free it.
    pub fn remove(self: *TriSourceManager, id: u64) ?*MemCell {
        if (self.sensory.fetchRemove(id)) |kv| return kv.value;
        if (self.cognitive.fetchRemove(id)) |kv| return kv.value;
        if (self.action.fetchRemove(id)) |kv| return kv.value;
        return null;
    }

    /// Iterate all memories across all sources. Caller is responsible for
    /// not mutating the maps during iteration.
    pub fn forEach(self: *TriSourceManager, ctx: anytype, comptime f: fn (ctx: @TypeOf(ctx), cell: *MemCell) void) void {
        var it_s = self.sensory.iterator();
        while (it_s.next()) |entry| f(ctx, entry.value_ptr.*);
        var it_c = self.cognitive.iterator();
        while (it_c.next()) |entry| f(ctx, entry.value_ptr.*);
        var it_a = self.action.iterator();
        while (it_a.next()) |entry| f(ctx, entry.value_ptr.*);
    }

    fn mapFor(self: *TriSourceManager, source: MemorySource) *std.AutoHashMap(u64, *MemCell) {
        return switch (source) {
            .matter => &self.sensory,
            .form => &self.cognitive,
            .spirit => &self.action,
        };
    }

    fn mapForConst(self: *const TriSourceManager, source: MemorySource) *const std.AutoHashMap(u64, *MemCell) {
        return switch (source) {
            .matter => &self.sensory,
            .form => &self.cognitive,
            .spirit => &self.action,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TriSourceManager: add and retrieve by source" {
    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(std.testing.allocator, &ids);
    defer mgr.deinit();

    const cell: MemCell = .{
        .id = 0,
        .source = .matter,
        .episode = "test",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.5, .priority = 5 },
        },
        .metadata = .{ .source_confidence = 0.9 },
    };
    const id = try mgr.add(cell);
    try std.testing.expect(id > 0);

    const got = mgr.get(id).?;
    try std.testing.expectEqual(MemorySource.matter, got.source);
    try std.testing.expectEqualStrings("test", got.episode);
}

test "TriSourceManager: rejects spirit-dim-missing" {
    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(std.testing.allocator, &ids);
    defer mgr.deinit();

    const cell: MemCell = .{
        .id = 0,
        .source = .matter,
        .episode = "test",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{},
        .metadata = .{ .source_confidence = 0.9 },
    };
    try std.testing.expectError(errors.SpiritDimMissing, mgr.add(cell));
}

test "TriSourceManager: counts by source" {
    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(std.testing.allocator, &ids);
    defer mgr.deinit();

    inline for ([_]MemorySource{ .matter, .form, .spirit, .matter, .form }) |src| {
        const cell: MemCell = .{
            .id = 0,
            .source = src,
            .episode = "x",
            .atomic_facts = &.{},
            .foresight = &.{},
            .goal_associations = &.{
                .{ .goal_id = 1, .relevance = 0.5, .priority = 5 },
            },
            .metadata = .{ .source_confidence = 0.9 },
        };
        _ = try mgr.add(cell);
    }
    try std.testing.expectEqual(@as(usize, 5), mgr.count());
    try std.testing.expectEqual(@as(usize, 2), mgr.countBySource(.matter));
    try std.testing.expectEqual(@as(usize, 2), mgr.countBySource(.form));
    try std.testing.expectEqual(@as(usize, 1), mgr.countBySource(.spirit));
}
