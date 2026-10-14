//! Structured logging. Supports human, JSONL, and silent modes.
//!
//! **Constitution Principle VII**: silent by default for long-running modes.
//! Long-running modes (HTTP server, daemon) MUST NOT spam stdout/stderr.

const std = @import("std");
const builtin = @import("builtin");
const time = @import("time.zig");
const config = @import("../core/config.zig");

/// Per Constitution: use `std.log.scoped` for all log lines. The CLI / server
/// wraps these into a single global scope at init time.
pub const Scope = std.log.ScopedFn("mem3");

/// Initialize the global logger based on `Config.LogFormat`.
///
/// **IMPORTANT**: this is called once at startup. After this, use
/// `std.log.scoped(.mem3_<scope>)` for module-specific logs.
pub fn initGlobal(alloc: std.mem.Allocator, cfg: config.Config.LogFormat, level: std.log.Level) !void {
    _ = alloc;
    _ = cfg;
    _ = level;
    // In 0.17 we override the global logFn via the public API. For v0.1.0 we
    // rely on the default `std.log` behavior (stderr, line-buffered).
    // A future patch will swap in a JSONL sink.
}

/// Compose a JSONL log line. Caller passes the writer and the message.
pub fn writeJsonlLine(
    writer: anytype,
    scope: []const u8,
    level: std.log.Level,
    msg: []const u8,
) !void {
    var ts_buf: [20]u8 = undefined;
    const ts = time.formatIso8601(time.nowMs(), &ts_buf);
    const level_str = switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
    // JSON-escape `msg`: minimal — escape `"` and `\` and control chars.
    try writer.print("{{\"ts\":\"{s}\",\"scope\":\"{s}\",\"level\":\"{s}\",\"msg\":\"", .{ ts, scope, level_str });
    for (msg) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...31 => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("\"}}\n");
}

test "writeJsonlLine: roundtrip a known message" {
    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try writeJsonlLine(&stream, "test", .info, "hello world");
    const out = stream.buffer[0..stream.end];
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"ts\":\""));
    try std.testing.expect(std.mem.endsWith(u8, out, "\"msg\":\"hello world\"}\n"));
}

test "writeJsonlLine: escapes special characters" {
    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try writeJsonlLine(&stream, "test", .info, "with \"quotes\" and \\backslash and\nnewline");
    const out = stream.buffer[0..stream.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\n") != null);
}
