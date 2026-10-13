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

/// A handler's own view of the command line: which subcommand was
/// selected, plus the args that follow it.
const Dispatch = struct {
    sub: Subcommand,
    args: []const cli.Arg,
};

/// Split `items` into the subcommand token and everything after it.
///
/// The split happens exactly once, here, so that no handler has to know
/// it was dispatched at some offset into a shared list. Handlers receive
/// `args` — a slice that already starts at their own first argument.
///
/// The token is the *first* item naming a subcommand. First-match wins
/// so a stray positional can never re-route an already-dispatched
/// command (`goal add --name list` must stay `add`). Flag values cannot
/// be mistaken for the token because the parser stores a flag and its
/// value as a single `Arg` whose `key` is the flag, not the value.
fn split(items: []const cli.Arg) Dispatch {
    for (items, 0..) |arg, i| {
        const token = if (std.mem.eql(u8, arg.key, "positional")) arg.value orelse "" else arg.key;
        if (std.mem.eql(u8, token, "add") or std.mem.eql(u8, token, "list") or std.mem.eql(u8, token, "status")) {
            return .{
                .sub = std.meta.stringToEnum(Subcommand, token) orelse .unknown,
                .args = items[i + 1 ..],
            };
        }
    }
    return .{ .sub = .unknown, .args = items };
}

pub fn run(alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    const d = split(parsed.args.items);
    // Fatal on an unknown subcommand before touching the disk: a
    // mistyped command should not create a data dir as a side effect.
    if (d.sub == .unknown) cli_common.fatal("error: expected: goal add|list|status <args>\n", .{});

    var store = try cli_common.openStore(alloc, parsed);
    defer store.deinit();

    switch (d.sub) {
        .add => try goalAdd(store, parsed.json, d.args),
        .list => try goalList(store, parsed.json, alloc),
        .status => try goalStatus(store, d.args),
        .unknown => unreachable, // guarded above
    }
}

/// `args` holds only what followed the `add` token.
fn goalAdd(store: *Store, json: bool, args: []const cli.Arg) !void {
    var name: ?[]const u8 = null;
    var description: []const u8 = "";
    var parent_id: ?u64 = null;
    var priority: u8 = 5;
    var deadline: ?i64 = null;

    for (args) |arg| {
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

    if (json) {
        var buf: [256]u8 = undefined;
        // SAFETY: format is `{"id":<u64>}`; id is u64 (<= 20 digits) and
        // the literal is 7 bytes, so the longest output is 27 bytes into a
        // 256-byte buffer. No user-supplied text is interpolated.
        const s = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch unreachable;
        cli_common.println(s);
    } else {
        var buf: [256]u8 = undefined;
        // SAFETY: format is `goal added: id=<u64>`; literal is 16 bytes
        // and id is u64 (<= 20 digits) -> 36 bytes into a 256-byte buffer.
        const s = std.fmt.bufPrint(&buf, "goal added: id={d}", .{id}) catch unreachable;
        cli_common.println(s);
    }
}

fn goalList(store: *Store, json: bool, alloc: std.mem.Allocator) !void {
    const goals = try store.listGoals(alloc);
    defer alloc.free(goals);

    if (json) {
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
        // SAFETY: format is `goals (<usize>):`; the literal is 9 bytes and
        // goals.len is a usize (<= 20 digits) -> 29 bytes into a 256-byte
        // buffer. No user-supplied text is interpolated.
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

/// `args` holds only what followed the `status` token, so the first
/// two positionals here are genuinely `<id>` and `<status>` — the
/// subcommand word itself is no longer in the slice.
fn goalStatus(store: *Store, args: []const cli.Arg) !void {
    var target_id: ?u64 = null;
    var new_status: ?GoalStatus = null;
    for (args) |arg| {
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
    // SAFETY: format is `goal <u64> -> <status>`; literal is 9 bytes, id
    // is u64 (<= 20 digits) and @tagName(GoalStatus) is drawn from the
    // six fixed tags in core/types.zig (longest "in_progress" = 11) ->
    // 40 bytes into a 256-byte buffer. No user-supplied text.
    const s = std.fmt.bufPrint(&buf, "goal {d} -> {s}", .{ id, @tagName(status) }) catch unreachable;
    cli_common.println(s);
}