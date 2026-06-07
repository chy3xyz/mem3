//! mem3 — `serve` subcommand.
//! Boots the HTTP daemon. Constitution FR-017: REST endpoints + /metrics.

const std = @import("std");
const cli = @import("../cli.zig");
const server = @import("../server/http_server.zig");

pub fn run(alloc: std.mem.Allocator, p: cli.Parsed) !void {
    const srv = server.Server.init(alloc, p.bind, p.port, p.data_dir) catch |err| {
        std.debug.print("fatal: failed to init server (data_dir={s}): {s}\n", .{ p.data_dir, @errorName(err) });
        std.debug.print("hint: check that the data directory is writable. To run in-memory only, set MEM3_NO_PERSIST=1 (not yet implemented).\n", .{});
        std.process.exit(1);
    };
    defer srv.deinit();
    try srv.listen();
    std.debug.print("mem3 v0.1.0-alpha listening on http://{s}:{d}\n", .{ p.bind, p.port });
    std.debug.print("  data dir:  {s}\n", .{p.data_dir});
    std.debug.print("  web UI:    http://{s}:{d}/\n", .{ p.bind, p.port });
    std.debug.print("  health:    http://{s}:{d}/healthz\n", .{ p.bind, p.port });
    std.debug.print("  metrics:   http://{s}:{d}/metrics\n", .{ p.bind, p.port });
    std.debug.print("  sync:      POST http://{s}:{d}/api/sync\n", .{ p.bind, p.port });
    try srv.serve();
}
