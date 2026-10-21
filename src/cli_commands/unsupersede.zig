//! CLI implementation for `mem3 unsupersede <id>`.
//!
//! The way back from a wrong supersession: `mem3 add` (and the HTTP / MCP
//! adds) report which older cells a new fact superseded and by which
//! predicate; if that call was wrong — a predicate that is really
//! multi-valued, say — this restores the cell. It becomes current again,
//! returns in default `query` results, and is *pinned*: neither a later write
//! nor a forgetting sweep supersedes it a second time. Journaled to the WAL
//! before the state changes, like every other mutation.
//!
//! Exits non-zero for an unknown id or a cell that is not superseded, so a
//! typo cannot look like a restore.

const std = @import("std");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");

pub fn run(alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    var target: ?u64 = null;
    for (parsed.args.items) |arg| {
        if (!std.mem.eql(u8, arg.key, "positional")) continue;
        if (target != null) cli_common.fatal("error: more than one id (usage: mem3 unsupersede <id>)\n", .{});
        target = std.fmt.parseInt(u64, arg.value orelse "", 10) catch
            cli_common.fatal("error: invalid id '{s}'\n", .{arg.value orelse ""});
    }
    const id = target orelse cli_common.fatal("error: missing id (usage: mem3 unsupersede <id>)\n", .{});

    var store = try cli_common.openStore(alloc, parsed);
    defer store.deinit();

    store.unsupersede(id) catch |err| switch (err) {
        error.CellNotFound => cli_common.fatal("error: id {d} not found\n", .{id}),
        error.NotSuperseded => cli_common.fatal("error: cell {d} is not superseded; nothing to undo\n", .{id}),
        else => cli_common.fatal("error: unsupersede failed: {s}; nothing was changed.\n", .{@errorName(err)}),
    };

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    if (parsed.json) {
        try cli_common.appendFmt(&buf, alloc, "{{\"id\":{d},\"unsuperseded\":true,\"pinned\":true}}", .{id});
    } else {
        try cli_common.appendFmt(&buf, alloc, "restored cell {d}: current again, and pinned against re-supersession", .{id});
    }
    cli_common.println(buf.items);
}
