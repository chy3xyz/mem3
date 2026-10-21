//! JSON writing helpers for the MCP server's response side.
//!
//! **GHW layer**: Harness layer (form source).
//!
//! `src/utils/jsonl.zig` owns the escaping rules (`writeJsonString`).
//! This module owns the *shape* of a response: how to open an object,
//! how to write a key, how to write a number that came out of an
//! embedding index without producing a `nan`.
//!
//! ## The float rule
//!
//! Scores come out of a cosine similarity and an exponential decay. If
//! either ever produces a non-finite value, Zig's `{d}` formatter emits
//! the literal text `nan` or `inf` — not JSON — and the client fails to
//! parse the *entire response*, losing every other field in it. So a
//! non-finite float is written as `null` here, once, at the only place
//! floats are written.

const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonl = @import("../utils/jsonl.zig");

/// Adapter so the shared `jsonl.writeJsonString` helper — written
/// against a stream writer — can target an `std.ArrayList(u8)`. Zig
/// 0.17's unmanaged ArrayList has no `.writer()`.
///
/// Same shape as the adapter in `src/server/http_server.zig`; the two
/// modules do not share one because the alternative is a dependency
/// from the MCP surface onto the HTTP daemon.
pub const ListWriter = struct {
    list: *std.ArrayList(u8),
    gpa: Allocator,

    pub fn writeByte(self: ListWriter, b: u8) !void {
        try self.list.append(self.gpa, b);
    }

    pub fn writeAll(self: ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.gpa, bytes);
    }

    pub fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.gpa, fmt, args);
    }
};

/// Open `{"k":` for the named key.
pub fn openKey(out: *std.ArrayList(u8), gpa: Allocator, k: []const u8) !void {
    try out.append(gpa, '{');
    try jsonl.writeJsonString(ListWriter{ .list = out, .gpa = gpa }, k);
    try out.appendSlice(gpa, ":");
}

/// Write `"k":` — a member separator, with or without the comma the
/// caller already emitted. Caller emits the comma.
pub fn key(out: *std.ArrayList(u8), gpa: Allocator, k: []const u8) !void {
    try jsonl.writeJsonString(ListWriter{ .list = out, .gpa = gpa }, k);
    try out.append(gpa, ':');
}

pub fn string(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    try jsonl.writeJsonString(ListWriter{ .list = out, .gpa = gpa }, s);
}

pub fn uint(out: *std.ArrayList(u8), gpa: Allocator, v: u64) !void {
    try out.print(gpa, "{d}", .{v});
}

pub fn int(out: *std.ArrayList(u8), gpa: Allocator, v: i64) !void {
    try out.print(gpa, "{d}", .{v});
}

pub fn boolean(out: *std.ArrayList(u8), gpa: Allocator, v: bool) !void {
    try out.appendSlice(gpa, if (v) "true" else "false");
}

/// A float that is always valid JSON. Non-finite becomes `null` rather
/// than the text `nan`/`inf`, which would break the whole response.
pub fn float(out: *std.ArrayList(u8), gpa: Allocator, v: f64) !void {
    if (!std.math.isFinite(v)) {
        try out.appendSlice(gpa, "null");
        return;
    }
    try out.print(gpa, "{d}", .{v});
}

/// Write the `null` literal. Named `jsonNull` because `null` is a
/// primitive and cannot be a declaration.
pub fn jsonNull(out: *std.ArrayList(u8), gpa: Allocator) !void {
    try out.appendSlice(gpa, "null");
}

/// An integer that may be absent.
pub fn optionalUint(out: *std.ArrayList(u8), gpa: Allocator, v: ?u64) !void {
    if (v) |x| try uint(out, gpa, x) else try jsonNull(out, gpa);
}

/// Append raw, already-valid JSON. The caller's contract.
pub fn raw(out: *std.ArrayList(u8), gpa: Allocator, json_text: []const u8) !void {
    try out.appendSlice(gpa, json_text);
}

// =============================================================================
// Tests
//
// Named directly in `src/main.zig`'s comptime block; a re-export from
// `src/mcp/mod.zig` does not register these with the runner.
//
// Nothing here prints — see the note at the top of `json.zig`.
// =============================================================================

test "json_out: non-finite floats become null, not nan" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try out.append(alloc, '[');
    try float(&out, alloc, 0.5);
    try out.append(alloc, ',');
    try float(&out, alloc, std.math.nan(f64));
    try out.append(alloc, ',');
    try float(&out, alloc, std.math.inf(f64));
    try out.append(alloc, ',');
    try float(&out, alloc, -std.math.inf(f64));
    try out.append(alloc, ']');

    // The round-trip through our own parser is the point: a client
    // parsing this must not see a bare `nan` token.
    try std.testing.expectEqualStrings("[0.5,null,null,null]", out.items);

    var d = try @import("json.zig").parse(alloc, out.items);
    defer d.deinit();
    const arr = d.root.asArray().?;
    try std.testing.expectEqual(@as(f64, 0.5), arr[0].asNumber().?);
    try std.testing.expect(arr[1] == .null);
    try std.testing.expect(arr[2] == .null);
    try std.testing.expect(arr[3] == .null);
}

test "json_out: keys and strings are escaped" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try openKey(&out, alloc, "a\"b");
    try string(&out, alloc, "line\none");
    try out.append(alloc, '}');

    try std.testing.expectEqualStrings("{\"a\\\"b\":\"line\\none\"}", out.items);
}

test "json_out: absent integers are null, present ones are numbers" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try out.append(alloc, '[');
    try optionalUint(&out, alloc, null);
    try out.append(alloc, ',');
    try optionalUint(&out, alloc, 7);
    try out.append(alloc, ']');

    var d = try @import("json.zig").parse(alloc, out.items);
    defer d.deinit();
    const arr = d.root.asArray().?;
    try std.testing.expect(arr[0] == .null);
    try std.testing.expectEqual(@as(f64, 7), arr[1].asNumber().?);
}
