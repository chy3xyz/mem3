//! mem3 — `serve` subcommand.
//! Boots the HTTP daemon. Constitution FR-017: REST endpoints + /metrics.

const std = @import("std");
const cli = @import("../cli.zig");
const server = @import("../server/http_server.zig");

/// `MEM3_NO_PERSIST=1` runs the daemon entirely in memory.
///
/// This used to be advertised in this file's error hint as "not yet
/// implemented" — a hint that sent users looking for a flag that had never
/// existed. `Server.init` now takes `?[]const u8`, so in-memory mode is a
/// real store mode (`BuildOptions.data_dir == null`) and this is a real
/// switch.
///
/// Zig 0.17 no longer exposes `getenv` anywhere in `std`, so libc is
/// declared directly. `MEM3_NO_PERSIST` is read once, here, rather than
/// threaded through `cli.Parsed`: it is a deployment escape hatch for the
/// daemon, not a CLI flag, and the help text should not grow a flag nobody
/// passes.
fn noPersistRequested() bool {
    const c_getenv = struct {
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    }.getenv;

    var buf: [32]u8 = undefined;
    const name = "MEM3_NO_PERSIST";
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const value = c_getenv(@ptrCast(&buf[0])) orelse return false;
    const slice = std.mem.span(value);
    return slice.len > 0 and !(std.mem.eql(u8, slice, "0") or std.mem.eql(u8, slice, "false"));
}

pub fn run(alloc: std.mem.Allocator, p: cli.Parsed) !void {
    const in_memory = noPersistRequested();
    const data_dir: ?[]const u8 = if (in_memory) null else p.data_dir;

    const srv = server.Server.init(alloc, p.bind, p.port, data_dir) catch |err| {
        std.debug.print("fatal: failed to init server (data_dir={s}): {s}\n", .{ p.data_dir, @errorName(err) });
        std.debug.print("hint: check that the data directory is writable, or set MEM3_NO_PERSIST=1 to run without persistence.\n", .{});
        std.process.exit(1);
    };
    defer srv.deinit();
    try srv.listen();

    // Periodic Constitution III maintenance: goals that have sat for 7 days
    // with no memories get marked `unrealized`, WAL-first, so the change
    // survives a restart. This is what makes the invariant real rather than
    // merely unit-tested — before this the rule existed only in
    // `GoalPoset.evaluateMetaGoals`, which nothing called.
    try srv.startMaintenance(p.maint_interval_sec);

    std.debug.print("mem3 v0.1.0-alpha listening on http://{s}:{d}\n", .{ p.bind, p.port });
    std.debug.print("  data dir:  {s}\n", .{if (in_memory) "(none — in-memory, MEM3_NO_PERSIST=1)" else p.data_dir});
    std.debug.print("  web UI:    http://{s}:{d}/\n", .{ p.bind, p.port });
    std.debug.print("  health:    http://{s}:{d}/healthz\n", .{ p.bind, p.port });
    std.debug.print("  metrics:   http://{s}:{d}/metrics\n", .{ p.bind, p.port });
    if (!in_memory) {
        std.debug.print("  sync:      POST http://{s}:{d}/api/sync\n", .{ p.bind, p.port });
    } else {
        std.debug.print("  sync:      unavailable (no persistence)\n", .{});
    }
    try srv.serve();
}
