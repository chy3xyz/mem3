//! mem3 — `serve` subcommand.
//! Boots the HTTP daemon. Constitution FR-017: REST endpoints + /metrics.

const std = @import("std");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const server = @import("../server/http_server.zig");
const signal = @import("../platform/signal.zig");
const platform_stdio = @import("../platform/stdio.zig");
const Logger = @import("../utils/logger.zig").Logger;

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

/// Where daemon events go, from the flags the operator actually typed.
///
/// **Silent unless asked.** With neither `--log-format` nor `--log-every` on
/// the command line this is `.off` and the daemon behaves exactly as it did
/// before logging existed. An explicit `--log-format=silent` also means off,
/// and wins over `--log-every`. `--log-every` alone turns on the human format
/// (you asked for periodic output, so you get lines); `--log-format=jsonl`
/// gives one JSON object per line. Always stderr — stdout is never touched.
pub fn loggerFor(p: cli.Parsed) Logger {
    if (p.log_format_explicit) return switch (p.log_format) {
        .silent => .{},
        .human => .{ .mode = .human },
        .jsonl => .{ .mode = .jsonl },
    };
    if (p.log_every_explicit and p.log_every_seconds > 0) return .{ .mode = .human };
    return .{};
}

/// Seconds between summary lines, 0 for none. Only `--log-every` N>0 asks.
pub fn summaryEvery(p: cli.Parsed) u32 {
    if (!p.log_every_explicit or p.log_every_seconds == 0) return 0;
    if (p.log_format_explicit and p.log_format == .silent) return 0;
    return @intCast(@min(p.log_every_seconds, std.math.maxInt(u32)));
}

/// The startup banner, byte-for-byte what `mem3 serve` printed before the
/// logger existed. Rendered into a buffer rather than printed in pieces so a
/// test can hold it to that. A non-default WAL mode adds one line; the
/// default adds nothing.
pub fn bannerText(buf: []u8, p: cli.Parsed, in_memory: bool) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    renderBanner(&w, p, in_memory) catch {};
    return buf[0..w.end];
}

fn renderBanner(w: *std.Io.Writer, p: cli.Parsed, in_memory: bool) !void {
    try w.print("mem3 v0.1.0-alpha listening on http://{s}:{d}\n", .{ p.bind, p.port });
    try w.print("  data dir:  {s}\n", .{if (in_memory) "(none — in-memory, MEM3_NO_PERSIST=1)" else p.data_dir});
    switch (p.wal_sync) {
        .always => {},
        .group => try w.writeAll("  wal sync:  group (concurrent writers share one fsync; acknowledged only after it)\n"),
        .interval_ms => |ms| try w.print("  wal sync:  interval:{d} (WEAKER: a power cut can lose up to ~{d} ms of acknowledged writes)\n", .{ ms, ms }),
    }
    try w.print("  web UI:    http://{s}:{d}/\n", .{ p.bind, p.port });
    try w.print("  health:    http://{s}:{d}/healthz\n", .{ p.bind, p.port });
    try w.print("  metrics:   http://{s}:{d}/metrics\n", .{ p.bind, p.port });
    if (p.forget_interval_sec == 0) {
        try w.writeAll("  forgetting: off (--forget-interval=0); every memory is retained\n");
    } else {
        try w.print("  forgetting: every {d}s{s}\n", .{
            p.forget_interval_sec,
            if (p.dry_run) " (dry run — previews only)" else "",
        });
        try w.print("  forget:    POST http://{s}:{d}/api/forget (preview; add {{\"dry_run\":false}} to actually forget)\n", .{ p.bind, p.port });
    }
    if (p.maint_interval_sec == 0) {
        try w.writeAll("  maintenance: off (--maint-interval=0)\n");
    }
    if (!in_memory) {
        try w.print("  sync:      POST http://{s}:{d}/api/sync\n", .{ p.bind, p.port });
    } else {
        try w.writeAll("  sync:      unavailable (no persistence)\n");
    }
}

fn signalName(sig: ?c_int) []const u8 {
    const s = sig orelse return "shutdown request";
    if (s == @as(c_int, @intCast(@intFromEnum(std.c.SIG.TERM)))) return "SIGTERM";
    if (s == @as(c_int, @intCast(@intFromEnum(std.c.SIG.INT)))) return "SIGINT";
    return "signal";
}

pub fn run(alloc: std.mem.Allocator, p: cli.Parsed) !void {
    const in_memory = noPersistRequested();
    const data_dir: ?[]const u8 = if (in_memory) null else p.data_dir;
    const logger = loggerFor(p);

    const srv = server.Server.initWithOptions(alloc, p.bind, p.port, .{
        .data_dir = data_dir,
        .wal_sync = p.wal_sync,
        .logger = logger,
        .log_every_sec = summaryEvery(p),
    }) catch |err| {
        std.debug.print("fatal: failed to init server (data_dir={s}): {s}\n", .{ p.data_dir, @errorName(err) });
        std.debug.print("hint: check that the data directory is writable, or set MEM3_NO_PERSIST=1 to run without persistence.\n", .{});
        std.process.exit(1);
    };
    defer srv.deinit();
    try cli_common.applySupersedePolicy(srv.store, p);

    // SIGINT/SIGTERM become a graceful stop: `serve` returns, having
    // refused new connections, drained in-flight ones and flushed the WAL.
    try signal.installTermHandlers();
    srv.watch_signals = true;

    try srv.listen();

    // Periodic Constitution III maintenance: goals that have sat for 7 days
    // with no memories get marked `unrealized`, WAL-first, so the change
    // survives a restart. This is what makes the invariant real rather than
    // merely unit-tested — before this the rule existed only in
    // `GoalPoset.evaluateMetaGoals`, which nothing called.
    //
    // Scheduled forgetting rides the same thread on its own, much slower
    // deadline: a daemon that never calls `store.forget` retains every
    // memory it is ever given and reports `mem3_forgetting_rate 0` forever,
    // which is indistinguishable from a memory system in good health.
    // `--forget-interval=0` opts out; `--dry-run` keeps the sweep but makes
    // it a preview.
    srv.setForgetSchedule(p.forget_interval_sec, p.dry_run);
    try srv.startMaintenance(p.maint_interval_sec);

    if (p.log_format_explicit and p.log_format == .silent) {
        // Explicitly silent: no banner either.
    } else if (logger.mode == .jsonl) {
        // stderr must be pure JSONL here, so the banner becomes one event
        // instead of seven lines of prose.
        logger.event(.info, "startup", "listening on http://{s}:{d} data_dir={s} wal_sync={s} forget_interval_s={d} maint_interval_s={d}", .{
            p.bind,
            p.port,
            if (in_memory) "(memory)" else p.data_dir,
            @tagName(p.wal_sync),
            p.forget_interval_sec,
            p.maint_interval_sec,
        });
    } else {
        var buf: [2048]u8 = undefined;
        _ = platform_stdio.writeErr(bannerText(&buf, p, in_memory));
    }

    try srv.serve();
    logger.event(.info, "shutdown", "{s}: stopped accepting, drained in-flight requests, WAL flushed", .{signalName(signal.requestedSignal())});
}

// =============================================================================
// Tests
// =============================================================================

fn parseArgs(argv: []const []const u8) !cli.Parsed {
    return cli.parseSlice(std.testing.allocator, argv);
}

test "serve: the default banner is byte-for-byte the pre-logger banner" {
    // Captured from the unmodified daemon (`mem3 serve --port 17891
    // --data-dir /tmp/bd1`, stderr, md5 041cdcf0d09a90003a7a828ee2da6ca1).
    const expected =
        "mem3 v0.1.0-alpha listening on http://127.0.0.1:17891\n" ++
        "  data dir:  /tmp/bd1\n" ++
        "  web UI:    http://127.0.0.1:17891/\n" ++
        "  health:    http://127.0.0.1:17891/healthz\n" ++
        "  metrics:   http://127.0.0.1:17891/metrics\n" ++
        "  forgetting: every 3600s\n" ++
        "  forget:    POST http://127.0.0.1:17891/api/forget (preview; add {\"dry_run\":false} to actually forget)\n" ++
        "  sync:      POST http://127.0.0.1:17891/api/sync\n";
    var p = try parseArgs(&.{ "serve", "--port", "17891", "--data-dir", "/tmp/bd1" });
    defer p.deinit(std.testing.allocator);
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(expected, bannerText(&buf, p, false));
}

test "serve: a non-default WAL mode adds one line and changes nothing else" {
    var base = try parseArgs(&.{ "serve", "--port", "17891", "--data-dir", "/tmp/bd1" });
    defer base.deinit(std.testing.allocator);
    var grp = try parseArgs(&.{ "serve", "--port", "17891", "--data-dir", "/tmp/bd1", "--wal-sync=group" });
    defer grp.deinit(std.testing.allocator);
    var b1: [2048]u8 = undefined;
    var b2: [2048]u8 = undefined;
    const a = bannerText(&b1, base, false);
    const g = bannerText(&b2, grp, false);
    try std.testing.expect(g.len > a.len);
    try std.testing.expect(std.mem.indexOf(u8, g, "wal sync:  group") != null);
    // Removing that one line gives the default banner back.
    const at = std.mem.indexOf(u8, g, "  wal sync:").?;
    const eol = std.mem.indexOfScalarPos(u8, g, at, '\n').?;
    var joined: [2048]u8 = undefined;
    @memcpy(joined[0..at], g[0..at]);
    @memcpy(joined[at .. at + g.len - eol - 1], g[eol + 1 ..]);
    try std.testing.expectEqualStrings(a, joined[0 .. at + g.len - eol - 1]);
}

test "serve: logging is off unless the operator asked for it" {
    {
        var p = try parseArgs(&.{"serve"});
        defer p.deinit(std.testing.allocator);
        try std.testing.expect(!loggerFor(p).enabled());
        try std.testing.expectEqual(@as(u32, 0), summaryEvery(p));
    }
    {
        var p = try parseArgs(&.{ "serve", "--log-format=silent", "--log-every=5" });
        defer p.deinit(std.testing.allocator);
        try std.testing.expect(!loggerFor(p).enabled());
        try std.testing.expectEqual(@as(u32, 0), summaryEvery(p));
    }
    {
        var p = try parseArgs(&.{ "serve", "--log-format=jsonl" });
        defer p.deinit(std.testing.allocator);
        try std.testing.expectEqual(Logger.Mode.jsonl, loggerFor(p).mode);
        // jsonl alone is events, not a periodic summary.
        try std.testing.expectEqual(@as(u32, 0), summaryEvery(p));
    }
    {
        var p = try parseArgs(&.{ "serve", "--log-every", "30" });
        defer p.deinit(std.testing.allocator);
        try std.testing.expectEqual(Logger.Mode.human, loggerFor(p).mode);
        try std.testing.expectEqual(@as(u32, 30), summaryEvery(p));
    }
    {
        var p = try parseArgs(&.{ "serve", "--log-every=0" });
        defer p.deinit(std.testing.allocator);
        try std.testing.expect(!loggerFor(p).enabled());
        try std.testing.expectEqual(@as(u32, 0), summaryEvery(p));
    }
}
