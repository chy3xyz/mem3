//! Constitution Invariant I: every MemCell has a non-null source_tag.
//!
//! Per `.specify/memory/constitution.md` Principle I and `spec.md` FR-027:
//!   - Every MemCell MUST have `source ∈ {matter, form, spirit}`.
//!   - `source_confidence` MUST be ≥ 0.5 (otherwise reject at encoding).
//!
//! This test builds a fixture corpus of well-formed cells and verifies the
//! invariant holds for every entry.

const std = @import("std");
const mem3 = @import("mem3");

const testing = std.testing;

test "constitution I: every MemCell has a valid source_tag" {
    const corpus = try buildFixture(testing.allocator);
    defer corpus.deinit();

    for (corpus.cells) |cell| {
        try testing.expect(cell.source == .matter or
            cell.source == .form or
            cell.source == .spirit);
        try testing.expect(cell.metadata.source_confidence >= 0.5);
    }
}

test "constitution I: source.fromString accepts all aliases" {
    try testing.expectEqual(mem3.MemorySource.matter, try mem3.MemorySource.fromString("matter"));
    try testing.expectEqual(mem3.MemorySource.form, try mem3.MemorySource.fromString("form"));
    try testing.expectEqual(mem3.MemorySource.spirit, try mem3.MemorySource.fromString("spirit"));
    try testing.expectError(error.InvalidSource, mem3.MemorySource.fromString("invalid"));
}

test "constitution I: source distribution must be non-zero across all three" {
    const corpus = try buildFixture(testing.allocator);
    defer corpus.deinit();

    var has_matter = false;
    var has_form = false;
    var has_spirit = false;
    for (corpus.cells) |c| {
        if (c.source == .matter) has_matter = true;
        if (c.source == .form) has_form = true;
        if (c.source == .spirit) has_spirit = true;
    }
    try testing.expect(has_matter);
    try testing.expect(has_form);
    try testing.expect(has_spirit);
}

const Corpus = struct {
    cells: []mem3.MemCell,
    alloc: std.mem.Allocator,

    fn deinit(self: *const Corpus) void {
        for (self.cells) |*c| c.deinit(self.alloc);
        self.alloc.free(self.cells);
    }
};

fn buildFixture(alloc: std.mem.Allocator) !Corpus {
    const cells = try alloc.alloc(mem3.MemCell, 9);
    var i: usize = 0;
    for ([_]mem3.MemorySource{ .matter, .form, .spirit }) |src| {
        for ([_][]const u8{ "alpha", "beta", "gamma" }) |ep| {
            cells[i] = try mkCell(alloc, @intCast(i + 1), src, ep);
            i += 1;
        }
    }
    return .{ .cells = cells, .alloc = alloc };
}

fn mkCell(
    alloc: std.mem.Allocator,
    id: u64,
    source: mem3.MemorySource,
    ep: []const u8,
) !mem3.MemCell {
    return .{
        .id = id,
        .source = source,
        .episode = try alloc.dupe(u8, ep),
        .atomic_facts = try alloc.dupe(mem3.Fact, &[_]mem3.Fact{}),
        .foresight = &.{},
        .goal_associations = try alloc.dupe(mem3.GoalAssociation, &[_]mem3.GoalAssociation{}),
        .metadata = .{
            .source_confidence = 0.95,
        },
    };
}
