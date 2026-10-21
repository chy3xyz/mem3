//! CLI implementation for `mem3 dump`.
//!
//! Exports every MemCell in the active store as JSONL (one cell per
//! line). Connects to the same Store the HTTP server uses, so reads
//! survive a server restart when `--data-dir` matches.
//!
//! Per spec: `mem3 dump [--data-dir=...] [--json] [--include-fuzzy]` emits
//! the full corpus for offline analysis or backup. Superseded cells are
//! included (with `superseded_at` / `superseded_by`): they are history, not
//! deleted.

const std = @import("std");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const Store = @import("../store/mod.zig").Store;
const MemCell = @import("../core/mod.zig").MemCell;

pub fn run(alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    var store = try cli_common.openStore(alloc, parsed);
    defer store.deinit();

    const cells = try store.allCells(alloc);
    defer alloc.free(cells);

    // Forgotten cells live in the fuzzy store (PCR: never deleted). They are
    // not part of the default export; `--include-fuzzy` appends them, marked
    // `"is_fuzzy":true`, so a conflict-forgotten cell can still be audited.
    if (cli_common.hasSwitch(parsed, "--include-fuzzy")) {
        var fuzzy_cells: std.ArrayList(*MemCell) = .empty;
        defer fuzzy_cells.deinit(alloc);
        var fit = store.lc.fuzzy.cells.iterator();
        while (fit.next()) |e| try fuzzy_cells.append(alloc, e.value_ptr.*);
        std.mem.sort(*MemCell, fuzzy_cells.items, {}, struct {
            fn lt(_: void, a: *MemCell, b: *MemCell) bool {
                return a.id < b.id;
            }
        }.lt);
        for (cells) |cell| try dumpOne(alloc, cell);
        for (fuzzy_cells.items) |cell| try dumpOne(alloc, cell);
        return;
    }

    for (cells) |cell| {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        try writeCellJson(alloc, &buf, cell);
        cli_common.println(buf.items);
    }
}

fn dumpOne(alloc: std.mem.Allocator, cell: *const MemCell) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try writeCellJson(alloc, &buf, cell);
    cli_common.println(buf.items);
}

fn writeCellJson(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), cell: *const MemCell) !void {
    try buf.append(alloc, '{');
    try cli_common.appendFmt(buf, alloc, "\"id\":{d}", .{cell.id});
    try cli_common.appendFmt(buf, alloc, ",\"source\":\"{s}\"", .{@tagName(cell.source)});
    try buf.appendSlice(alloc, ",\"episode\":");
    try cli_common.appendJsonString(buf, alloc, cell.episode);
    try cli_common.appendFmt(buf, alloc, ",\"importance\":{d:.4}", .{cell.metadata.importance_score});
    try cli_common.appendFmt(buf, alloc, ",\"coherence\":{d:.4}", .{cell.metadata.coherence_score});
    try cli_common.appendFmt(buf, alloc, ",\"created_at\":{d}", .{cell.metadata.created_at});
    try cli_common.appendFmt(buf, alloc, ",\"access_count\":{d}", .{cell.metadata.access_count});
    try cli_common.appendFmt(buf, alloc, ",\"is_fuzzy\":{}", .{cell.metadata.is_fuzzy});
    // Supersession: null while current, else when and by which cell.
    try appendOptInt(buf, alloc, "superseded_at", cell.metadata.superseded_at);
    try appendOptInt(buf, alloc, "superseded_by", cell.metadata.superseded_by);
    // `true` after `mem3 unsupersede`: never superseded again.
    try cli_common.appendFmt(buf, alloc, ",\"supersede_pinned\":{}", .{cell.metadata.supersede_pinned});
    try buf.appendSlice(alloc, ",\"atomic_facts\":[");
    for (cell.atomic_facts, 0..) |f, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.append(alloc, '{');
        try buf.appendSlice(alloc, "\"s\":");
        try cli_common.appendJsonString(buf, alloc, f.subject);
        try buf.appendSlice(alloc, ",\"p\":");
        try cli_common.appendJsonString(buf, alloc, f.predicate);
        try buf.appendSlice(alloc, ",\"o\":");
        try cli_common.appendJsonString(buf, alloc, f.object);
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "],\"foresight\":[");
    for (cell.foresight, 0..) |f, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.append(alloc, '{');
        try buf.appendSlice(alloc, "\"desc\":");
        try cli_common.appendJsonString(buf, alloc, f.description);
        try cli_common.appendFmt(buf, alloc, ",\"from\":{d},\"until\":{d},\"conf\":{d:.4}", .{ f.valid_from, f.valid_until, f.confidence });
        try buf.append(alloc, '}');
    }
    try buf.appendSlice(alloc, "],\"goals\":[");
    for (cell.goal_associations, 0..) |g, i| {
        if (i > 0) try buf.append(alloc, ',');
        try cli_common.appendFmt(buf, alloc, "{{\"id\":{d},\"relevance\":{d:.4}}}", .{ g.goal_id, g.relevance });
    }
    try buf.appendSlice(alloc, "]}");
}
fn appendOptInt(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, key: []const u8, v: anytype) !void {
    if (v) |x| {
        try cli_common.appendFmt(buf, alloc, ",\"{s}\":{d}", .{ key, x });
    } else {
        try cli_common.appendFmt(buf, alloc, ",\"{s}\":null", .{key});
    }
}

test "dump: a foresight-only cell lists its foresight entries" {
    // `dump` printed `"foresight":[]` for every cell because the store
    // never kept any. The JSON must carry the entry and stay valid.
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    const id = try store.addRawWithForesight(.spirit, "dump me", "", 0, 0.5, &.{
        .{ .description = "quote \" inside", .valid_from = 100, .valid_until = 200, .confidence = 0.5 },
    });

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    try writeCellJson(alloc, &buf, store.getCell(id).?);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"foresight\":[]") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        buf.items,
        "\"foresight\":[{\"desc\":\"quote \\\" inside\",\"from\":100,\"until\":200,\"conf\":0.5000}]",
    ) != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("foresight").?.array.items.len);
}

test "dump: every line carries superseded_at / superseded_by / supersede_pinned by default" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var cell: MemCell = .{
        .id = 5,
        .source = .matter,
        .episode = "the user lives in Paris",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{},
        .metadata = .{},
    };
    try writeCellJson(alloc, &buf, &cell);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"superseded_at\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"superseded_by\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"supersede_pinned\":false") != null);

    buf.clearRetainingCapacity();
    cell.metadata.superseded_at = 1234;
    cell.metadata.superseded_by = 9;
    cell.metadata.supersede_pinned = true;
    try writeCellJson(alloc, &buf, &cell);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"superseded_at\":1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"superseded_by\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"supersede_pinned\":true") != null);
}
