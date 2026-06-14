//! CLI implementation for `mem3 inspect`.
//!
//! Per spec: `mem3 inspect <id>` shows one MemCell + its hypergraph
//! neighborhood (the cells reachable via HyMem edges within `--hops`
//! hops, default 2).
//!
//! Reads through the same Store the HTTP server uses.

const std = @import("std");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const Store = @import("../store/mod.zig").Store;
const MemCell = @import("../core/mod.zig").MemCell;

pub fn run(alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    var store = try cli_common.openStore(alloc, parsed);
    defer store.deinit();

    // Pull id from positional args.
    var target_id: ?u64 = null;
    var max_hops: u8 = 2;
    for (parsed.args.items) |arg| {
        if (std.mem.eql(u8, arg.key, "positional")) {
            if (target_id == null) {
                target_id = std.fmt.parseInt(u64, arg.value orelse "", 10) catch {
                    cli_common.fatal("error: invalid id '{s}'\n", .{arg.value orelse ""});
                };
            }
        } else if (std.mem.eql(u8, arg.key, "--hops") or std.mem.eql(u8, arg.key, "-h")) {
            const v = arg.value orelse cli_common.fatal("error: --hops requires a value\n", .{});
            max_hops = std.fmt.parseInt(u8, v, 10) catch cli_common.fatal("error: invalid --hops '{s}'\n", .{v});
        }
    }
    const id = target_id orelse cli_common.fatal("error: missing id (usage: mem3 inspect <id>)\n", .{});

    const cell = store.getCell(id) orelse cli_common.fatal("error: id {d} not found\n", .{id});

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, '{');
    try cli_common.appendFmt(&buf, alloc, "\"id\":{d}", .{cell.id});
    try cli_common.appendFmt(&buf, alloc, ",\"source\":\"{s}\"", .{@tagName(cell.source)});
    try buf.appendSlice(alloc, ",\"episode\":");
    try cli_common.appendJsonString(&buf, alloc, cell.episode);
    try cli_common.appendFmt(&buf, alloc, ",\"importance\":{d:.4}", .{cell.metadata.importance_score});
    try cli_common.appendFmt(&buf, alloc, ",\"coherence\":{d:.4}", .{cell.metadata.coherence_score});
    try cli_common.appendFmt(&buf, alloc, ",\"decay_rate\":{d:.6}", .{cell.metadata.decay_rate});
    try cli_common.appendFmt(&buf, alloc, ",\"created_at\":{d}", .{cell.metadata.created_at});
    try cli_common.appendFmt(&buf, alloc, ",\"access_count\":{d}", .{cell.metadata.access_count});
    try buf.append(alloc, '}');

    // Find the hypergraph neighborhood if requested.
    if (max_hops > 0) {
        const seeds = [_]u64{id};
        const visited = try store.multiHop(alloc, &seeds, max_hops, 0.0, null);
        defer alloc.free(visited);

        try buf.appendSlice(alloc, ",\"neighborhood\":[");
        for (visited, 0..) |nid, i| {
            if (i > 0) try buf.append(alloc, ',');
            if (store.getCell(nid)) |neighbor| {
                try cli_common.appendFmt(&buf, alloc, "{{\"id\":{d},\"source\":\"{s}\",\"episode\":", .{ neighbor.id, @tagName(neighbor.source) });
                try cli_common.appendJsonString(&buf, alloc, neighbor.episode);
                try buf.append(alloc, '}');
            } else {
                try cli_common.appendFmt(&buf, alloc, "{{\"id\":{d}}}", .{nid});
            }
        }
        try buf.append(alloc, ']');
    }

    cli_common.println(buf.items);
}