//! Lightweight JSON utilities. Minimal — we don't pull in std.json's runtime
//! reflection per Constitution Principle V.
//!
//! For the v0.1.0 CLI/JSON output we implement only what we need: emit
//! `key: "value"` strings, handle simple escape rules. For full JSON
//! parsing of CLI inputs we use `std.json` (one-time parse, not hot path).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// JSON-escape a string into a writer. Used by `dump.zig` and `/metrics`.
pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            // NOTE: the sub-ranges must skip 9, 10 and 13, which the arms
            // above already claim. A plain `0...31` here overlaps them —
            // Zig used to accept the dead branch, 0.17 rejects it outright.
            0...8, 11...12, 14...31 => try writer.print("\\u{x:0>4}", .{c}),
            // DEL gets escaped; everything above it is passed through
            // raw. JSON strings are UTF-8, so escaping each byte of a
            // multi-byte sequence independently (`127...255`, the old
            // behaviour) turned any non-ASCII text — a Chinese goal
            // name, for instance — into mojibake.
            127 => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// Write a JSON object member like `"key":`. Caller follows with the value.
pub fn writeJsonKey(writer: anytype, key: []const u8) !void {
    try writeJsonString(writer, key);
    try writer.writeAll(":");
}

test "writeJsonString: simple ASCII" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeJsonString(&stream.writer(), "hello");
    try std.testing.expectEqualStrings("\"hello\"", stream.getWritten());
}

test "writeJsonString: escapes" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try writeJsonString(&stream.writer(), "a\"b\\c\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", stream.getWritten());
}
