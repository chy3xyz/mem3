//! CLI implementation for `mem3 goal`.
//!
//! Per spec:
//!   mem3 goal add  --name <name> [--description <desc>] [--parent <id>]
//!                   [--priority N] [--deadline <unix_ms>]
//!   mem3 goal list
//!   mem3 goal status <id> <status>
//!
//! `--data-dir` is honored: goals persist across restarts via the
//! WAL and the goal snapshot embedded in the snapshot file.

const std = @import("std");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const Store = @import("../store/mod.zig").Store;
const GoalStatus = @import("../core/mod.zig").GoalStatus;
const time_util = @import("../utils/time.zig");

const Subcommand = enum { add, list, status, unknown };

pub fn run(alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    var store = try cli_common.openStore(alloc, parsed);
    defer store.deinit();

    var sub: Subcommand = .unknown;
    for (parsed.args.items) |arg| {
        const key = if (std.mem.eql(u8, arg.key, "positional")) arg.value orelse "" else arg.key;
        if (std.mem.eql(u8, key, "add") or std.mem.eql(u8, key, "list") or std.mem.eql(u8, key, "status")) {
            sub = std.meta.stringToEnum(Subcommand, key) orelse .unknown;
        }
    }

    switch (sub) {
        .add => try goalAdd(store, parsed),
        .list => try goalList(store, parsed, alloc),
        .status => try goalStatus(store, parsed),
        .unknown => cli_common.fatal("error: expected: goal add|list|status <args>\n", .{}),
    }
}

fn goalAdd(store: *Store, parsed: cli.Parsed) !void {
    var name: ?[]const u8 = null;
    var description: []const u8 = "";
    var parent_id: ?u64 = null;
    var priority: u8 = 5;
    var deadline: ?i64 = null;

    for (parsed.args.items) |arg| {
        if (std.mem.eql(u8, arg.key, "--name") or std.mem.eql(u8, arg.key, "-n")) {
            name = arg.value orelse cli_common.fatal("error: --name requires a value\n", .{});
        } else if (std.mem.eql(u8, arg.key, "--description") or std.mem.eql(u8, arg.key, "-d")) {
            description = arg.value orelse "";
        } else if (std.mem.eql(u8, arg.key, "--parent") or std.mem.eql(u8, arg.key, "-p")) {
            const v = arg.value orelse cli_common.fatal("error: --parent requires a value\n", .{});
            parent_id = std.fmt.parseInt(u64, v, 10) catch cli_common.fatal("error: invalid --parent '{s}'\n", .{v});
        } else if (std.mem.eql(u8, arg.key, "--priority") or std.mem.eql(u8, arg.key, "--pri")) {
            const v = arg.value orelse cli_common.fatal("error: --priority requires a value\n", .{});
            priority = std.fmt.parseInt(u8, v, 10) catch cli_common.fatal("error: invalid --priority '{s}'\n", .{v});
        } else if (std.mem.eql(u8, arg.key, "--deadline")) {
            const v = arg.value orelse cli_common.fatal("error: --deadline requires a value\n", .{});
            deadline = std.fmt.parseInt(i64, v, 10) catch cli_common.fatal("error: invalid --deadline '{s}'\n", .{v});
        }
    }
    const n = name orelse cli_common.fatal("error: --name is required\n", .{});

    const now_ms = time_util.nowMs();
    const id = try store.createGoal(n, description, parent_id, priority, deadline, now_ms);

    if (parsed.json) {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch unreachable;
        cli_common.println(s);
    } else {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "goal added: id={d}", .{id}) catch unreachable;
        cli_common.println(s);
    }
}

fn goalList(store: *Store, parsed: cli.Parsed, alloc: std.mem.Allocator) !void {
    const goals = try store.listGoals(alloc);
    defer alloc.free(goals);

    if (parsed.json) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, "{\"goals\":[");
        for (goals, 0..) |g, i| {
            if (i > 0) try buf.append(alloc, ',');
            try cli_common.appendFmt(&buf, alloc, "{{\"id\":{d},\"name\":\"{s}\",\"description\":\"{s}\",\"status\":\"{s}\",\"priority\":{d},\"parent_id\":", .{ g.id, g.name, g.description, @tagName(g.status), g.priority });
            if (g.parent_id) |pid|
                try cli_common.appendFmt(&buf, alloc, "{d}", .{pid})
            else
                try buf.appendSlice(alloc, "null");
            try cli_common.appendFmt(&buf, alloc, ",\"memcell_count\":{d}}}", .{g.memcell_count});
        }
        try buf.appendSlice(alloc, "]}");
        cli_common.println(buf.items);
    } else {
        var buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&buf, "goals ({d}):", .{goals.len}) catch unreachable;
        cli_common.println(header);
        for (goals) |g| {
            const line = std.fmt.bufPrint(
                &buf,
                "  id={d} name={s} status={s} priority={d} memcells={d}",
                .{ g.id, g.name, @tagName(g.status), g.priority, g.memcell_count },
            ) catch continue;
            cli_common.println(line);
        }
    }
}

fn goalStatus(store: *Store, parsed: cli.Parsed) !void {
    var target_id: ?u64 = null;
    var new_status: ?GoalStatus = null;
    for (parsed.args.items) |arg| {
        if (std.mem.eql(u8, arg.key, "positional")) {
            if (target_id == null) {
                target_id = std.fmt.parseInt(u64, arg.value orelse "", 10) catch
                    cli_common.fatal("error: invalid goal id '{s}'\n", .{arg.value orelse ""});
            } else if (new_status == null) {
                new_status = std.meta.stringToEnum(GoalStatus, arg.value orelse "") orelse
                    cli_common.fatal("error: invalid goal status '{s}' (pending|in_progress|completed|failed|unrealized|tombstoned)\n", .{arg.value orelse ""});
            }
        }
    }
    const id = target_id orelse cli_common.fatal("error: usage: mem3 goal status <id> <status>\n", .{});
    const status = new_status orelse cli_common.fatal("error: missing <status>\n", .{});

    const now_ms = time_util.nowMs();
    store.updateGoalStatus(id, status, now_ms) catch |err|
        cli_common.fatal("error: status update failed: {s}\n", .{@errorName(err)});

    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "goal {d} -> {s}", .{ id, @tagName(status) }) catch unreachable;
    cli_common.println(s);
}