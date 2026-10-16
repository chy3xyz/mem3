//! JSON-RPC 2.0 envelope: validation of an incoming line, and the two
//! shapes of outgoing message.
//!
//! **GHW layer**: Harness 层 (象源). The envelope is pure protocol: it
//! carries no memory, crosses no GHW layer, and its only job is to
//! decide whether a line is a request, a notification, or garbage —
//! and to refuse to answer a notification.
//!
//! ## The notification rule
//!
//! A message without `id` is a notification and must never be
//! answered. Answering one does not merely waste a line: a client that
//! receives an unsolicited response for an id it is not awaiting will,
//! depending on the implementation, log it, drop it, or treat the
//! stream as desynchronised. Every test in `server.zig` that feeds a
//! notification asserts on the *absence* of bytes for it.
//!
//! ## The parse-error rule
//!
//! A line that does not parse still gets an answer, with `"id":null`.
//! Silence would leave a client waiting on a request that was
//! structurally impossible — the exact "hangs forever" failure the
//! notification rule exists to avoid on the other side.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("json.zig");
const out = @import("json_out.zig");

/// The MCP revision this server implements. `initialize` echoes the
/// client's version when it is one we support, and this one otherwise.
pub const PROTOCOL_VERSION = "2025-06-18";

/// Revisions we can speak. Clients negotiate by sending theirs; we
/// answer with theirs if listed here, else with `PROTOCOL_VERSION`.
pub const SUPPORTED_VERSIONS = [_][]const u8{
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};

/// Standard JSON-RPC error codes.
pub const Code = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
};

/// A validated request or notification. `deinit` releases the parsed
/// document; everything else in it borrows from the caller's `line`.
pub const Envelope = struct {
    doc: json.Document,
    /// Exact source text of `id`, or `null` for a notification.
    id_raw: ?[]const u8,
    method: []const u8,
    params: ?json.Value,

    pub fn deinit(self: *Envelope) void {
        self.doc.deinit();
        self.* = undefined;
    }

    pub fn isNotification(self: *const Envelope) bool {
        return self.id_raw == null;
    }

    /// `params` as an object, or `null`. An absent `params` reads as
    /// "no arguments", which every method here accepts.
    pub fn paramsObject(self: *const Envelope) ?[]const json.Member {
        const p = self.params orelse return null;
        return p.asObject();
    }
};

/// A rejected line, with the code to answer it under.
pub const Rejection = struct {
    code: i32,
    message: []const u8,
};

pub const Parsed = union(enum) {
    ok: Envelope,
    rejected: Rejection,
};

/// Validate one line as a JSON-RPC 2.0 message.
///
/// The only error this returns is `OutOfMemory`, which the caller turns
/// into an internal error rather than a parse error — a server that ran
/// out of memory did not fail to understand the request.
pub fn parseMessage(alloc: Allocator, line: []const u8) Allocator.Error!Parsed {
    var doc = json.parseWith(alloc, line, &.{"id"}) catch |err| {
        return .{ .rejected = .{
            .code = Code.parse_error,
            .message = switch (err) {
                error.LimitExceeded => "message exceeds the size limit",
                else => "malformed JSON",
            },
        } };
    };

    // Ownership handoff. Every path below returns either a rejection
    // (and frees the document) or an Envelope that takes it. The flag
    // exists because `errdefer` does not fire on a *successful*
    // `.rejected` return: writing this as `errdefer doc.deinit()` alone
    // leaks the whole document on every malformed request, which is
    // precisely the input an untrusted peer controls.
    var doc_owned = true;
    defer if (doc_owned) doc.deinit();

    if (validate(&doc)) |r| return .{ .rejected = r };

    doc_owned = false;
    return .{ .ok = .{
        .doc = doc,
        .id_raw = doc.span("id"),
        .method = json.get(doc.root, "method").?.asString().?,
        .params = paramsOf(doc.root),
    } };
}

/// Everything that makes a syntactically valid JSON object a *valid*
/// JSON-RPC message. `null` means valid.
fn validate(doc: *json.Document) ?Rejection {
    if (doc.root.asObject() == null) {
        return .{ .code = Code.invalid_request, .message = "message must be a JSON object" };
    }

    const version = json.get(doc.root, "jsonrpc");
    if (version == null or version.?.asString() == null or
        !std.mem.eql(u8, version.?.asString().?, "2.0"))
    {
        return .{
            .code = Code.invalid_request,
            .message = "missing or unsupported \"jsonrpc\": expected \"2.0\"",
        };
    }

    const method = json.get(doc.root, "method");
    if (method == null or method.?.asString() == null) {
        return .{ .code = Code.invalid_request, .message = "missing or non-string \"method\"" };
    }

    // `id` may be a string, a number, or absent. A bool, array or
    // object is not a valid JSON-RPC id. Absent ⇒ notification.
    if (json.get(doc.root, "id")) |id| {
        switch (id) {
            .string, .number => {},
            else => return .{
                .code = Code.invalid_request,
                .message = "\"id\" must be a string or a number",
            },
        }
    }

    // `params`, when present, is by-position or by-name: an object or
    // an array. A scalar is malformed *params* (-32602), not an absent
    // one — collapsing the two would make `tools/call` see "no
    // arguments" for a client that sent nonsense.
    if (json.get(doc.root, "params")) |p| {
        switch (p) {
            .object, .array => {},
            else => return .{
                .code = Code.invalid_params,
                .message = "\"params\" must be an object or an array",
            },
        }
    }
    return null;
}

/// `params` when present. `validate` has already rejected every shape
/// this returns null for.
fn paramsOf(root: json.Value) ?json.Value {
    return json.get(root, "params");
}

/// Append `{"jsonrpc":"2.0","id":<id>,"result":<result>}`.
///
/// `id` is the caller's exact source text. `result` is already-valid
/// JSON owned by the caller.
pub fn writeResult(
    out_list: *std.ArrayList(u8),
    gpa: Allocator,
    id_raw: []const u8,
    result_json: []const u8,
) !void {
    try out_list.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    try out_list.appendSlice(gpa, id_raw);
    try out_list.appendSlice(gpa, ",\"result\":");
    try out_list.appendSlice(gpa, result_json);
    try out_list.append(gpa, '}');
}

/// Append an error response. `id_raw` may be `null`, which is the
/// correct answer to a line that could not be parsed.
pub fn writeError(
    out_list: *std.ArrayList(u8),
    gpa: Allocator,
    id_raw: ?[]const u8,
    code: i32,
    message: []const u8,
) !void {
    try out_list.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",\"id\":");
    if (id_raw) |id| {
        try out_list.appendSlice(gpa, id);
    } else {
        try out_list.appendSlice(gpa, "null");
    }
    try out_list.appendSlice(gpa, ",\"error\":{\"code\":");
    try out_list.print(gpa, "{d}", .{code});
    try out_list.appendSlice(gpa, ",\"message\":");
    try out.string(out_list, gpa, message);
    try out_list.appendSlice(gpa, "}}");
}

/// Negotiate a protocol version: the client's if we speak it, else
/// ours.
pub fn negotiateVersion(requested: ?[]const u8) []const u8 {
    const want = requested orelse return PROTOCOL_VERSION;
    for (SUPPORTED_VERSIONS) |v| {
        if (std.mem.eql(u8, v, want)) return want;
    }
    return PROTOCOL_VERSION;
}

// =============================================================================
// Tests
//
// Named directly in `src/main.zig`'s comptime block.
//
// Nothing here prints: the runner speaks its protocol over the process
// pipes, and one stderr write kills the test binary while `zig build
// test` still exits 0.
// =============================================================================

const testing = std.testing;

fn parseOk(alloc: Allocator, line: []const u8) !Envelope {
    const p = try parseMessage(alloc, line);
    switch (p) {
        .ok => |e| return e,
        // No printing: a test that reaches this branch already failed
        // every assertion below it. `unreachable` here would be a lie,
        // so the failure is raised through `testing` instead.
        .rejected => |r| {
            if (r.code != Code.internal_error) {
                testing.expect(false) catch {};
            }
            return error.RejectedInTestHelper;
        },
    }
}

test "protocol: a request keeps its id, method and params" {
    const alloc = testing.allocator;
    var e = try parseOk(alloc,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"memory_stats"}}
    );
    defer e.deinit();

    try testing.expect(!e.isNotification());
    try testing.expectEqualStrings("7", e.id_raw.?);
    try testing.expectEqualStrings("tools/call", e.method);
    try testing.expectEqualStrings("memory_stats", json.get(e.params.?, "name").?.asString().?);
}

test "protocol: a notification has no id and is flagged as one" {
    const alloc = testing.allocator;
    var e = try parseOk(alloc,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer e.deinit();

    try testing.expect(e.isNotification());
    try testing.expect(e.id_raw == null);
    try testing.expect(e.params == null);
}

test "protocol: a string id keeps its quotes for the echo" {
    const alloc = testing.allocator;
    var e = try parseOk(alloc,
        \\{"jsonrpc":"2.0","id":"req-42","method":"ping"}
    );
    defer e.deinit();

    try testing.expectEqualStrings("\"req-42\"", e.id_raw.?);
    try testing.expect(!e.isNotification());
}

test "protocol: a rejected line carries a JSON-RPC code" {
    const alloc = testing.allocator;

    const cases = [_]struct { line: []const u8, code: i32 }{
        .{ .line = "", .code = Code.parse_error },
        .{ .line = "not json", .code = Code.parse_error },
        .{ .line = "{\"jsonrpc\":\"2.0\",", .code = Code.parse_error },
        .{ .line = "[]", .code = Code.invalid_request },
        .{ .line = "\"a string\"", .code = Code.invalid_request },
        .{ .line = "{\"id\":1,\"method\":\"ping\"}", .code = Code.invalid_request },
        .{ .line = "{\"jsonrpc\":\"1.0\",\"method\":\"ping\"}", .code = Code.invalid_request },
        .{ .line = "{\"jsonrpc\":2.0,\"method\":\"ping\"}", .code = Code.invalid_request },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":1}", .code = Code.invalid_request },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":7}", .code = Code.invalid_request },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":7}", .code = Code.invalid_params },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":\"x\"}", .code = Code.invalid_params },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}", .code = Code.invalid_request },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":[1],\"method\":\"ping\"}", .code = Code.invalid_request },
    };

    var wrong: ?i32 = null;
    for (cases) |c| {
        const p = try parseMessage(alloc, c.line);
        switch (p) {
            .ok => |*e| {
                var mut = e.*;
                mut.deinit();
                wrong = -1; // accepted something it should have rejected
            },
            .rejected => |r| {
                if (r.code != c.code) wrong = r.code;
            },
        }
        if (wrong != null) break;
    }
    try testing.expect(wrong == null);
}

test "protocol: an array of params is accepted, an object is, a scalar is not" {
    const alloc = testing.allocator;
    var e = try parseOk(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[]}
    );
    defer e.deinit();
    try testing.expectEqual(@as(usize, 0), e.params.?.asArray().?.len);

    var e2 = try parseOk(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}
    );
    defer e2.deinit();
    try testing.expectEqual(@as(usize, 0), e2.paramsObject().?.len);
}

test "protocol: a result response echoes the id byte for byte" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try writeResult(&buf, alloc, "1e2", "{\"ok\":true}");
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1e2,\"result\":{\"ok\":true}}",
        buf.items,
    );
    // And it parses back.
    var d = try json.parseWith(alloc, buf.items, &.{"id"});
    defer d.deinit();
    try testing.expectEqualStrings("1e2", d.span("id").?);
    try testing.expect(json.get(d.root, "result").?.asObject().?.len == 1);
}

test "protocol: an error response with no id is well-formed JSON" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try writeError(&buf, alloc, null, Code.parse_error, "malformed \"JSON\"");
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"malformed \\\"JSON\\\"\"}}",
        buf.items,
    );

    var d = try json.parse(alloc, buf.items);
    defer d.deinit();
    try testing.expect(json.get(d.root, "id").? == .null);
    const err = json.get(d.root, "error").?;
    try testing.expectEqual(@as(f64, @floatFromInt(Code.parse_error)), json.get(err, "code").?.asNumber().?);
}

test "protocol: version negotiation answers with a version we speak" {
    try testing.expectEqualStrings("2025-03-26", negotiateVersion("2025-03-26"));
    try testing.expectEqualStrings("2024-11-05", negotiateVersion("2024-11-05"));
    // Unknown or absent: our own, never the client's.
    try testing.expectEqualStrings(PROTOCOL_VERSION, negotiateVersion("2099-01-01"));
    try testing.expectEqualStrings(PROTOCOL_VERSION, negotiateVersion(null));
    for (SUPPORTED_VERSIONS) |v| {
        try testing.expectEqualStrings(v, negotiateVersion(v));
    }
}
