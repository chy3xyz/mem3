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

/// The current MCP revision, and the one this server prefers.
///
/// Revision `2026-07-28` removed the `initialize` handshake: the
/// protocol version travels per request in
/// `params._meta["io.modelcontextprotocol/protocolVersion"]`, and every
/// result carries a `resultType`. This server implements that era and
/// still answers the legacy handshake, because most deployed clients
/// have not migrated and a legacy client has no fall-forward path.
pub const MODERN_VERSION = "2026-07-28";

/// The legacy revision this server answers `initialize` with. Clients
/// that only speak `2025-11-25` or earlier negotiate to one of the
/// versions below and are then served under handshake semantics.
pub const LEGACY_VERSION = "2025-06-18";

/// Back-compat alias for the legacy revision. `initialize` negotiates
/// within this list, so it is the legacy newest we can name.
pub const PROTOCOL_VERSION = LEGACY_VERSION;

/// Every revision this server can speak, newest first.
pub const SUPPORTED_VERSIONS = [_][]const u8{
    MODERN_VERSION,
    "2025-11-25",
    LEGACY_VERSION,
    "2025-03-26",
    "2024-11-05",
};

/// Revisions that predate the stateless core, i.e. those for which
/// `initialize` is a legitimate request rather than an unknown method.
pub const LEGACY_VERSIONS = [_][]const u8{
    "2025-11-25",
    LEGACY_VERSION,
    "2025-03-26",
    "2024-11-05",
};

/// Which era an incoming message belongs to, decided per request.
///
/// The discriminator is the presence of
/// `io.modelcontextprotocol/protocolVersion` in `params._meta`, not any
/// connection state: the protocol is stateless and a client may
/// interleave unrelated requests on one stdio process.
pub const Era = enum {
    /// Carries per-request `_meta`. Results need `resultType` and a
    /// `serverInfo` echo.
    modern,
    /// No per-request `_meta`, or an `initialize` request, which selects
    /// handshake semantics for the process by the spec's own rule.
    legacy,

    pub fn isModern(self: Era) bool {
        return self == .modern;
    }
};

/// The reserved `_meta` prefix. Key names under it are MCP's alone.
pub const META_PREFIX = "io.modelcontextprotocol/";
pub const META_PROTOCOL_VERSION = META_PREFIX ++ "protocolVersion";
pub const META_CLIENT_INFO = META_PREFIX ++ "clientInfo";
pub const META_CLIENT_CAPABILITIES = META_PREFIX ++ "clientCapabilities";
pub const META_SERVER_INFO = META_PREFIX ++ "serverInfo";

/// Standard JSON-RPC error codes.
pub const Code = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;

    /// `UnsupportedProtocolVersion`. Reserved for MCP by the 2026-07-28
    /// revision and defined by no earlier one, so emitting it is what
    /// tells a dual-era client "retry modern, do not fall back to
    /// `initialize`" instead of "you are talking to a legacy server".
    pub const unsupported_protocol_version: i32 = -32022;
};

/// `params._meta` as an object, or `null`.
///
/// `params` itself must be an object for `_meta` to be reachable; a
/// scalar or absent `params` reads as "no metadata", which is what an
// old client sending `tools/list` with no `params` actually means.
pub fn metaOf(params: ?json.Value) ?[]const json.Member {
    const p = params orelse return null;
    if (p.asObject() == null) return null;
    const m = json.get(p, "_meta") orelse return null;
    return m.asObject();
}

/// One `_meta` value by full key, e.g. `META_PROTOCOL_VERSION`.
pub fn metaGet(params: ?json.Value, key: []const u8) ?json.Value {
    const members = metaOf(params) orelse return null;
    for (members) |m| {
        if (std.mem.eql(u8, m.key, key)) return m.value;
    }
    return null;
}

/// The protocol version this request declares, or `null` when it
/// declares none.
pub fn requestedVersion(params: ?json.Value) ?[]const u8 {
    const v = metaGet(params, META_PROTOCOL_VERSION) orelse return null;
    return v.asString();
}

/// Classify a request by the per-request metadata it carries.
pub fn eraOf(params: ?json.Value, method: []const u8) Era {
    // `initialize` is a legacy method by definition. On a dual-era
    // server it selects handshake semantics for the stdio process, so it
    // must not be mistaken for a modern request just because a modern
    // client also happens to send `_meta` alongside it.
    if (std.mem.eql(u8, method, "initialize")) return .legacy;
    if (requestedVersion(params) != null) return .modern;
    return .legacy;
}

/// Whether a version string is one this server implements.
pub fn supportsVersion(v: []const u8) bool {
    for (SUPPORTED_VERSIONS) |s| {
        if (std.mem.eql(u8, s, v)) return true;
    }
    return false;
}

/// Whether a version predates the stateless core.
pub fn isLegacyVersion(v: []const u8) bool {
    for (LEGACY_VERSIONS) |s| {
        if (std.mem.eql(u8, s, v)) return true;
    }
    return false;
}

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
    /// Source text of the request's `id`, when the document parsed far
    /// enough to read one and validation still rejected the message.
    ///
    /// JSON-RPC 2.0 requires a response to carry "the same ID as the
    /// request... if the id could not be detected, it MUST be Null". A
    /// message that has a perfectly good `id` and a broken `method` is
    /// not an undetectable id, so echoing `null` there tells the client
    /// nothing about which request failed — and a client batching
    /// requests gets one `id: null` per bad element and no way to tell
    /// them apart from the error that killed the whole batch.
    ///
    /// Borrowed from the caller's line, which outlives the parse.
    id_raw: ?[]const u8 = null,
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

    // Read the id before validation, while the document that holds its
    // source text is still alive. `validate` may reject a message that
    // carried a perfectly good id, and that id is what the error has to
    // echo back.
    const id_raw = doc.span("id");

    if (validate(&doc)) |r| {
        var rejection = r;
        rejection.id_raw = id_raw;
        return .{ .rejected = rejection };
    }

    doc_owned = false;
    return .{ .ok = .{
        .doc = doc,
        .id_raw = id_raw,
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

/// Negotiate a protocol version for `initialize`: the client's if we
/// speak it, else ours.
///
/// Iterates `LEGACY_VERSIONS`, not `SUPPORTED_VERSIONS`. A client that
/// asked for `2026-07-28` and then sent `initialize` is asking for the
/// era in which that method does not exist; answering it with the
/// modern revision would hand back a version whose own rules this
/// response violates — there is no handshake to negotiate in it.
pub fn negotiateVersion(requested: ?[]const u8) []const u8 {
    const want = requested orelse return LEGACY_VERSION;
    for (LEGACY_VERSIONS) |v| {
        if (std.mem.eql(u8, v, want)) return want;
    }
    return LEGACY_VERSION;
}

/// Wrap a built legacy-shaped result object into a 2026-07-28 result.
///
/// The revision requires `resultType` on every result and asks servers
/// to identify themselves in `result._meta`, neither of which a legacy
/// result has room for. Rather than duplicate every builder with a
/// second variant that can drift out of step, the fields between the
/// outermost braces are re-opened under the modern envelope.
///
/// This is why every result builder in this module must emit a compact
/// object — a leading `{`, a trailing `}`, no whitespace outside it.
/// That is a checked precondition rather than an assumption: a builder
/// that ever changes shape fails the test that walks every tool's
/// result through here, instead of quietly producing a result the spec
/// calls invalid.
pub fn wrapModernResult(out_list: *std.ArrayList(u8), gpa: Allocator, result_json: []const u8) !void {
    const inner = std.mem.trim(u8, result_json, " \t\r\n");
    if (inner.len < 2 or inner[0] != '{' or inner[inner.len - 1] != '}') {
        // Reaching here means a builder produced something that is not a
        // bare object. Emitting it wrapped would be worse than refusing:
        // the client would see a result with no usable fields and no
        // indication why.
        return error.NotAResultObject;
    }
    try out_list.appendSlice(gpa, "{\"resultType\":\"complete\",");
    if (inner.len > 2) {
        try out_list.appendSlice(gpa, inner[1 .. inner.len - 1]);
        try out_list.append(gpa, ',');
    }
    try out_list.appendSlice(gpa, "\"_meta\":{");
    try out.string(out_list, gpa, META_SERVER_INFO);
    try out_list.appendSlice(gpa, ":{\"name\":");
    try out.string(out_list, gpa, SERVER_NAME);
    try out_list.appendSlice(gpa, ",\"version\":");
    try out.string(out_list, gpa, SERVER_VERSION);
    try out_list.appendSlice(gpa, "}}}");
}

/// Identity reported in `serverInfo` and in every modern result's
/// `_meta`. Self-reported and unverified by design; the spec says so,
/// and says clients must not use it for anything but display.
pub const SERVER_NAME = "mem3";
pub const SERVER_VERSION = "0.1.0-alpha";

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
    for (LEGACY_VERSIONS) |v| {
        try testing.expectEqualStrings(v, negotiateVersion(v));
    }
    // The loop above deliberately runs over `LEGACY_VERSIONS`, not
    // `SUPPORTED_VERSIONS`. A client that asks to negotiate the modern
    // revision and then sends `initialize` is asking for the era in
    // which that method does not exist, so echoing its version back
    // would hand it a version whose own rules this answer breaks.
    try testing.expectEqualStrings(LEGACY_VERSION, negotiateVersion(MODERN_VERSION));
    try testing.expect(!isLegacyVersion(MODERN_VERSION));
}

// The one property `negotiateVersion` must never violate: it answers
// from the legacy set, and that set is disjoint from the modern era.
test "protocol: the legacy negotiation set cannot name the stateless era" {
    for (LEGACY_VERSIONS) |v| {
        try testing.expect(!std.mem.eql(u8, v, MODERN_VERSION));
        try testing.expect(isLegacyVersion(v));
    }
    try testing.expect(supportsVersion(MODERN_VERSION));
    for (SUPPORTED_VERSIONS) |v| try testing.expect(supportsVersion(v));
    try testing.expect(!supportsVersion("2099-01-01"));
    try testing.expect(!supportsVersion(""));
}
