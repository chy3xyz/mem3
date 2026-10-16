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
const MemorySource = @import("../core/mod.zig").MemorySource;
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
    return Store.init(alloc, .{
        .data_dir = data_dir,
        .seed_default_goals = true,
        .embedder_cmd = parsed.embedder_cmd,
        .embedder_args = parsed.embedder_args.items,
    });
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