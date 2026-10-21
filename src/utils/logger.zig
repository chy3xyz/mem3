//! Structured logging. Supports human, JSONL, and silent modes.
//!
//! **Constitution Principle VII**: silent by default for long-running modes.
//! Long-running modes (HTTP server, daemon) MUST NOT spam stdout/stderr.

const std = @import("std");
const builtin = @import("builtin");
const time = @import("time.zig");
const platform_stdio = @import("../platform/stdio.zig");

/// Per Constitution: use `std.log.scoped` for all log lines. The CLI / server
/// wraps these into a single global scope at init time.
pub const Scope = std.log.ScopedFn("mem3");

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
            // Everything else in the C0 range, minus 9/10/13 which the
            // named escapes above already claimed — naming them twice is a
            // duplicate switch value, and Zig rejects the whole file for it.
            0...8, 11...12, 14...31 => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    // Close the `msg` string, then the object, then the record. This used
    // to write `"}}\n` — two closing braces — so every JSONL line this
    // function produced was malformed and a strict reader would reject the
    // whole stream. The test that caught it had never run: `logger.zig`
    // was reachable from `lib.zig`, which re-exports it, and a re-export
    // does not register a file's `test` blocks with the runner.
    try writer.writeAll("\"}\n");
}

/// A log sink with an explicit destination and an explicit on/off switch.
///
/// **Silent unless constructed otherwise.** `Logger{}` is `.off`: `event`
/// formats nothing and writes nothing, which is what keeps the daemon's
/// default byte-identical to a build that had no logger at all
/// (Constitution VII), and what keeps library code from ever touching
/// stderr under the test runner. Only the CLI entry points (`serve`, `mcp`)
/// build an enabled one, from `--log-format` / `--log-every`.
///
/// It is a value passed to whoever logs — not a global — so a test can point
/// one at a scratch file and read the lines back.
pub const Logger = struct {
    pub const Mode = enum { off, human, jsonl };

    mode: Mode = .off,
    /// Destination descriptor. 2 (stderr) for the real CLI; never stdout, which
    /// is the MCP protocol channel and a data channel everywhere else.
    fd: c_int = 2,

    /// Longest message we will format. A line that does not fit is cut, at
    /// a UTF-8 boundary, rather than dropped or split: one event is one
    /// `write(2)`, so concurrent writers cannot interleave inside a line.
    pub const MAX_MSG: usize = 900;

    pub fn enabled(self: Logger) bool {
        return self.mode != .off;
    }

    pub fn event(
        self: Logger,
        level: std.log.Level,
        scope: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (self.mode == .off) return;
        var msg_buf: [MAX_MSG]u8 = undefined;
        const msg = formatTruncated(&msg_buf, fmt, args);

        var line_buf: [MAX_MSG * 2 + 160]u8 = undefined;
        var w = std.Io.Writer.fixed(&line_buf);
        switch (self.mode) {
            .off => unreachable, // SAFETY: returned above.
            .jsonl => writeJsonlLine(&w, scope, level, msg) catch return,
            .human => w.print("mem3 {s} {s}: {s}\n", .{ @tagName(level), scope, msg }) catch return,
        }
        _ = platform_stdio.writeFd(self.fd, line_buf[0..w.end]);
    }
};

/// `bufPrint`, but a message that does not fit is truncated instead of
/// failing, and the cut never lands inside a multi-byte code point: an
/// invalid-UTF-8 tail would make the JSONL line unparseable, which is worse
/// than a shortened message.
fn formatTruncated(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    var cut = false;
    w.print(fmt, args) catch {
        cut = true;
    };
    var n = w.end;
    if (cut) {
        // Look back at most 3 bytes for a lead byte whose sequence the cut
        // truncated, and drop it.
        var back: usize = 1;
        while (back <= 3 and back <= n) : (back += 1) {
            const b = buf[n - back];
            if (b < 0x80) break; // ASCII: boundary is clean.
            if (b >= 0xC0) {
                const need: usize = if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else 2;
                if (back < need) n -= back;
                break;
            }
            // continuation byte: keep looking for its lead.
        }
    }
    return buf[0..n];
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

// =============================================================================
// Logger tests. Every one writes to a scratch file, never to stderr: under
// `zig build test --listen=-` a stray stderr byte desynchronises the runner.
// =============================================================================

const platform_fs = @import("../platform/fs.zig");

const Scratch = struct {
    path: [96]u8 = undefined,
    path_len: usize = 0,
    fd: c_int = -1,

    fn open(label: []const u8) !Scratch {
        var s = Scratch{};
        const pid: u64 = @intCast(std.c.getpid());
        const p = try std.fmt.bufPrint(&s.path, "/tmp/mem3_logger_{d}_{s}\x00", .{ pid, label });
        s.path_len = p.len - 1;
        const z: [*:0]const u8 = @ptrCast(&s.path);
        platform_fs.unlink(z) catch {};
        s.fd = try platform_fs.open(z, .{ .access = .read_write, .create = .truncate });
        return s;
    }

    fn close(self: *Scratch) void {
        platform_fs.close(self.fd);
        const z: [*:0]const u8 = @ptrCast(&self.path);
        platform_fs.unlink(z) catch {};
    }

    /// Everything written so far. Caller frees.
    fn contents(self: *Scratch, alloc: std.mem.Allocator) ![]u8 {
        const size: usize = @intCast(try platform_fs.sizeOf(self.fd));
        const buf = try alloc.alloc(u8, size);
        errdefer alloc.free(buf);
        const z: [*:0]const u8 = @ptrCast(&self.path);
        const rfd = try platform_fs.open(z, .{ .access = .read_only });
        defer platform_fs.close(rfd);
        const got = try platform_fs.readFull(rfd, buf);
        return buf[0..got];
    }
};

test "Logger: the default is off and writes nothing" {
    var sc = try Scratch.open("off");
    defer sc.close();
    const lg = Logger{ .fd = sc.fd };
    try std.testing.expect(!lg.enabled());
    lg.event(.info, "server", "maintenance: {d} goal(s) unrealized", .{3});
    lg.event(.err, "server", "boom", .{});
    const got = try sc.contents(std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "Logger: jsonl mode emits one parseable JSON object per event" {
    const alloc = std.testing.allocator;
    var sc = try Scratch.open("jsonl");
    defer sc.close();
    const lg = Logger{ .mode = .jsonl, .fd = sc.fd };

    lg.event(.info, "maintenance", "{d} goal(s) unrealized, {d} failed", .{ 2, 0 });
    // The message is untrusted text: quotes, backslashes, newlines and
    // non-ASCII must all survive as valid JSON.
    lg.event(.warn, "store", "path \"C:\\x\" had a\nnewline and 存在增益", .{});
    lg.event(.err, "server", "plain", .{});

    const got = try sc.contents(alloc);
    defer alloc.free(got);

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expect(obj.get("ts") != null);
        try std.testing.expect(obj.get("scope") != null);
        try std.testing.expect(obj.get("level") != null);
        try std.testing.expect(obj.get("msg") != null);
        if (lines == 1) {
            try std.testing.expectEqualStrings("maintenance", obj.get("scope").?.string);
            try std.testing.expectEqualStrings("info", obj.get("level").?.string);
            try std.testing.expectEqualStrings("2 goal(s) unrealized, 0 failed", obj.get("msg").?.string);
        }
        if (lines == 2) {
            try std.testing.expectEqualStrings("path \"C:\\x\" had a\nnewline and 存在增益", obj.get("msg").?.string);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), lines);
}

test "Logger: human mode is one plain line per event" {
    const alloc = std.testing.allocator;
    var sc = try Scratch.open("human");
    defer sc.close();
    const lg = Logger{ .mode = .human, .fd = sc.fd };
    lg.event(.info, "server", "hello {s}", .{"world"});
    const got = try sc.contents(alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("mem3 info server: hello world\n", got);
}

test "Logger: an oversized message is cut on a code-point boundary and stays valid JSON" {
    const alloc = std.testing.allocator;
    var sc = try Scratch.open("long");
    defer sc.close();
    const lg = Logger{ .mode = .jsonl, .fd = sc.fd };

    // 3-byte characters, so the cut point lands mid-sequence for most
    // lengths. 1,000 of them is 3,000 bytes against a 900-byte limit.
    const big = try alloc.alloc(u8, 3000);
    defer alloc.free(big);
    for (0..1000) |i| @memcpy(big[i * 3 ..][0..3], "存");
    lg.event(.info, "server", "{s}", .{big});

    const got = try sc.contents(alloc);
    defer alloc.free(got);
    try std.testing.expect(got.len > 0);
    try std.testing.expect(got[got.len - 1] == '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, got[0 .. got.len - 1], .{});
    defer parsed.deinit();
    const msg = parsed.value.object.get("msg").?.string;
    try std.testing.expect(msg.len > 0 and msg.len <= Logger.MAX_MSG);
    try std.testing.expect(std.unicode.utf8ValidateSlice(msg));
}
