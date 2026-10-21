//! Shared CLI helpers — store construction, JSON output, error formatting.
//!
//! Pre-extraction, every CLI command had its own ad-hoc init logic.
//! Now they all go through `openStore` (which honors `--data-dir`)
//! and `println` for output. This keeps the surface tiny and lets
//! the CLI match the HTTP server's persistence semantics.

const std = @import("std");
const cli = @import("../cli.zig");
const store_mod = @import("../store/mod.zig");
const Store = store_mod.Store;
const core_mod = @import("../core/mod.zig");
const MemorySource = core_mod.MemorySource;
const platform_stdio = @import("../platform/stdio.zig");

/// Open a Store according to CLI global flags.
///
/// `--data-dir` (default `data`) is honored — the Store is WAL-backed
/// when set, in-memory when empty. Reads `parsed.dry_run` to choose
/// between durable and ephemeral mode.
///
/// `--embedder-cmd` / `--embedder-arg` are forwarded verbatim. With neither
/// set the store uses the built-in hashed lexer and stays dependency-free;
/// with a command set, the external backend is spawned here, at open time,
/// so a tool that is missing or answers with the wrong width fails before
/// anything is indexed rather than halfway through.
pub fn openStore(alloc: std.mem.Allocator, parsed: cli.Parsed) !*Store {
    const data_dir: ?[]const u8 = if (parsed.data_dir.len == 0) null else parsed.data_dir;
    const store = try Store.init(alloc, .{
        .data_dir = data_dir,
        .seed_default_goals = true,
        .embedder_cmd = parsed.embedder_cmd,
        .embedder_args = parsed.embedder_args.items,
        .wal_sync = parsed.wal_sync,
    });
    errdefer store.deinit();
    try applySupersedePolicy(store, parsed);
    return store;
}

/// Value of a `--key=value` / `--key value` flag; the last one wins. `null`
/// when absent or given without a value.
pub fn flagValue(parsed: cli.Parsed, name: []const u8) ?[]const u8 {
    var v: ?[]const u8 = null;
    for (parsed.args.items) |a| {
        if (std.mem.eql(u8, a.key, name)) v = a.value;
    }
    return v;
}

/// `--supersede=off|functional|all`, `--no-supersede` (= off) and
/// `--functional-predicates=a,b,c`, applied to an open store. An unknown mode
/// or a valueless flag is an error, not a silent fallback: a mistyped
/// `--supersede=al` must not quietly leave supersession on.
pub fn applySupersedePolicy(store: *Store, parsed: cli.Parsed) !void {
    var mode: ?core_mod.SupersedeMode = null;
    for (parsed.args.items) |a| {
        if (!std.mem.eql(u8, a.key, "--supersede")) continue;
        const v = a.value orelse {
            eprintln("error: --supersede requires a value (off|functional|all)");
            return error.InvalidFlag;
        };
        mode = std.meta.stringToEnum(core_mod.SupersedeMode, v) orelse {
            eprintln("error: invalid --supersede (expected off|functional|all)");
            return error.InvalidFlag;
        };
    }
    if (hasSwitch(parsed, "--no-supersede")) mode = .off;
    if (mode) |m| store.setSupersedeMode(m);

    for (parsed.args.items) |a| {
        if (!std.mem.eql(u8, a.key, "--functional-predicates")) continue;
        const v = a.value orelse {
            eprintln("error: --functional-predicates requires a value (a,b,c)");
            return error.InvalidFlag;
        };
        try store.setFunctionalPredicates(v);
    }
}

/// Print a complete line to stdout. Use this in place of
/// `std.io.getStdOut().writer()`, which doesn't exist in Zig 0.17.
/// The buffer is stack-allocated; format the line in full before calling.
///
/// Goes through the platform layer rather than `std.c.write(std.c.STDOUT_FILENO, …)`
/// because that handle is `*anyopaque` on Windows and does not type-check there.
pub fn println(s: []const u8) void {
    var buf: [8192]u8 = undefined;
    const out = if (s.len + 1 <= buf.len) blk: {
        @memcpy(buf[0..s.len], s);
        buf[s.len] = '\n';
        break :blk buf[0 .. s.len + 1];
    } else s;
    _ = platform_stdio.writeOut(out);
}

/// Print a complete line to stderr via POSIX write.
pub fn eprintln(s: []const u8) void {
    var buf: [8192]u8 = undefined;
    const out = if (s.len + 1 <= buf.len) blk: {
        @memcpy(buf[0..s.len], s);
        buf[s.len] = '\n';
        break :blk buf[0 .. s.len + 1];
    } else s;
    _ = platform_stdio.writeErr(out);
}

/// Pretty-print an error to stderr and exit with code 1.
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch "fatal: format error\n";
    _ = platform_stdio.writeErr(s);
    std.process.exit(1);
}

/// Append `bytes` to `buf`, growing it as needed. Returns an
/// `Allocator.Error` so callers can propagate OOM. This is a
/// convenience wrapper around `appendSlice` because we cannot
/// rely on the `writer()` method that previous Zig versions
/// exposed on `ArrayList`.
pub fn appendAll(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, bytes: []const u8) !void {
    try buf.appendSlice(alloc, bytes);
}

/// Append a formatted JSON value to `buf`. Used for assembling JSON
/// documents incrementally without depending on `writer()`.
/// A valueless switch such as `--include-superseded` or `--no-supersede`: present with no value,
/// `=true`, or `=1`. `--flag=false` turns it off.
pub fn hasSwitch(parsed: cli.Parsed, name: []const u8) bool {
    var on = false;
    for (parsed.args.items) |a| {
        if (!std.mem.eql(u8, a.key, name)) continue;
        const v = a.value orelse {
            on = true;
            continue;
        };
        on = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
    }
    return on;
}

pub fn appendFmt(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    var tmp: [4096]u8 = undefined;
    const formatted = std.fmt.bufPrint(&tmp, fmt, args) catch return;
    try buf.appendSlice(alloc, formatted);
}

/// Append a JSON-escaped string to `buf`. Surrounds with `"` quotes.
pub fn appendJsonString(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            0...7, 11, 14...31 => {
                var esc: [8]u8 = undefined;
                const formatted = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch continue;
                try buf.appendSlice(alloc, formatted);
            },
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            8 => try buf.appendSlice(alloc, "\\b"),
            12 => try buf.appendSlice(alloc, "\\f"),
            else => try buf.append(alloc, c),
        }
    }
    try buf.append(alloc, '"');
}

/// Parse `--source=...` value to MemorySource, with a friendly error.
pub fn parseSource(value: []const u8) !MemorySource {
    return MemorySource.fromString(value) catch {
        eprintln("error: invalid --source (expected matter|form|spirit)");
        return error.InvalidFlag;
    };
}
test "applySupersedePolicy: default is functional; flags choose the mode and the predicate list" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    try std.testing.expectEqual(core_mod.SupersedeMode.functional, store.lc.cfg.supersede_mode);

    {
        var p = try cli.parseSlice(alloc, &.{ "add", "--supersede=all", "--functional-predicates=likes, +x" });
        defer p.deinit(alloc);
        try applySupersedePolicy(store, p);
        try std.testing.expectEqual(core_mod.SupersedeMode.all, store.lc.cfg.supersede_mode);
        try std.testing.expectEqual(core_mod.SupersedeMode.all, store.lc.forgetter.cfg.supersede_mode);
        try std.testing.expectEqualStrings("likes, +x", store.lc.cfg.functional_predicates.?);
    }
    {
        // Space form, and the legacy alias.
        var p = try cli.parseSlice(alloc, &.{ "forget", "--supersede", "off" });
        defer p.deinit(alloc);
        try applySupersedePolicy(store, p);
        try std.testing.expectEqual(core_mod.SupersedeMode.off, store.lc.cfg.supersede_mode);
    }
    {
        var p = try cli.parseSlice(alloc, &.{ "serve", "--supersede=functional", "--no-supersede" });
        defer p.deinit(alloc);
        try applySupersedePolicy(store, p);
        try std.testing.expectEqual(core_mod.SupersedeMode.off, store.lc.cfg.supersede_mode);
    }
    // The list is copied: replacing it frees the old copy (leak-checked).
    try store.setFunctionalPredicates("a");
    try store.setFunctionalPredicates(null);
    try std.testing.expect(store.lc.cfg.functional_predicates == null);
}

test "the `unsupersede` subcommand parses with its id as a positional" {
    var p = try cli.parseSlice(std.testing.allocator, &.{ "unsupersede", "42" });
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(cli.Subcommand.unsupersede, p.cmd);
    try std.testing.expectEqualStrings("positional", p.args.items[0].key);
    try std.testing.expectEqualStrings("42", p.args.items[0].value.?);
}
