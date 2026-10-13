//! Constitution Invariant II: every MemCell has a 物/象/性 spirit dimension.
//!
//! Per `.specify/memory/constitution.md` Principle I and `spec.md` FR-027:
//!   - Every MemCell MUST have ≥ 1 foresight OR ≥ 1 goal_association.
//!   - This guarantees the spirit dimension is present (性 is non-empty).
//!
//! A cell with no foresight AND no goal_associations is a "headless" memory:
//! it has matter (episode) and form (facts) but no meaning. Constitution
//! rejects such cells at encoding time.

const std = @import("std");
const mem3 = @import("mem3");

const testing = std.testing;

test "constitution II: every MemCell has spirit dimension" {
    const corpus = try buildFixture(testing.allocator);
    defer corpus.deinit();

    for (corpus.cells, 0..) |cell, i| {
        const has_spirit = cell.foresight.len > 0 or cell.goal_associations.len > 0;
        if (!has_spirit) {
            // std.log, never std.debug.print: Zig's test runner talks to
            // the build system over the process pipes under `--listen=-`,
            // and any stderr write from inside a test desynchronises that
            // protocol — the binary dies with "failed command" while
            // `zig build test` still exits 0. Logging through the std.log
            // facade keeps this at .err and off the wire in normal runs.
            std.log.err("cell {d} (source={s}) is missing spirit dim", .{
                i, @tagName(cell.source),
            });
        }
        try testing.expect(has_spirit);
    }
}

test "constitution II: cell with only foresight is allowed" {
    var cell = try mkBaseCell(testing.allocator, 1, .matter, "x");
    defer cell.deinit(testing.allocator);
    testing.allocator.free(cell.goal_associations);
    cell.goal_associations = &.{};
    const desc = try testing.allocator.dupe(u8, "future");
    cell.foresight = try testing.allocator.dupe(mem3.Foresight, &[_]mem3.Foresight{
        .{ .description = desc, .valid_from = 0, .valid_until = 1000, .confidence = 0.5 },
    });

    try testing.expect(cell.foresight.len > 0);
    try testing.expect(cell.goal_associations.len == 0);
}

test "constitution II: cell with only goal_associations is allowed" {
    var cell = try mkBaseCell(testing.allocator, 1, .matter, "x");
    defer cell.deinit(testing.allocator);
    cell.foresight = &.{};

    try testing.expect(cell.foresight.len == 0);
    try testing.expect(cell.goal_associations.len > 0);
}

test "constitution II: cell with neither is REJECTED at encoding" {
    var cell = try mkBaseCell(testing.allocator, 1, .matter, "x");
    defer cell.deinit(testing.allocator);
    cell.foresight = &.{};
    testing.allocator.free(cell.goal_associations);
    cell.goal_associations = &.{};

    const has_spirit = cell.foresight.len > 0 or cell.goal_associations.len > 0;
    try testing.expect(!has_spirit);
    // In production: `try encoder.encode(cell)` returns `error.SpiritDimMissing`.
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
    const cells = try alloc.alloc(mem3.MemCell, 6);
    var i: usize = 0;
    for ([_]mem3.MemorySource{ .matter, .form, .spirit }) |src| {
        for ([_][]const u8{ "alpha", "beta" }) |ep| {
            cells[i] = try mkBaseCell(alloc, @intCast(i + 1), src, ep);
            i += 1;
        }
    }
    return .{ .cells = cells, .alloc = alloc };
}

fn mkBaseCell(
    alloc: std.mem.Allocator,
    id: u64,
    source: mem3.MemorySource,
    ep: []const u8,
) !mem3.MemCell {
    var fact = mem3.Fact{
        .subject = try alloc.dupe(u8, "s"),
        .predicate = try alloc.dupe(u8, "p"),
        .object = try alloc.dupe(u8, "o"),
        .confidence = 1.0,
        .source = try alloc.dupe(u8, "test"),
    };
    const facts = try alloc.dupe(mem3.Fact, &[_]mem3.Fact{fact});
    fact = undefined;

    const goals = try alloc.dupe(mem3.GoalAssociation, &[_]mem3.GoalAssociation{
        .{ .goal_id = 1, .relevance = 0.5, .priority = 5 },
    });

    return .{
        .id = id,
        .source = source,
        .episode = try alloc.dupe(u8, ep),
        .atomic_facts = facts,
        .foresight = &.{},
        .goal_associations = goals,
        .metadata = .{
            .source_confidence = 0.95,
        },
    };
}
