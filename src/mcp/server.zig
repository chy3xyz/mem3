//! The MCP stdio server: framing in, dispatch, responses out.
//!
//! **GHW layer**: all three. This module is the Harness that a client
//! drives; the tools it dispatches cross Goal → Harness → World inside
//! `Store` (Principle II). The server itself holds no memory state.
//!
//! ## stdout is protocol
//!
//! Everything written to the output fd is a JSON-RPC message and
//! nothing else. A banner, a warning, a debug line — any of those on
//! stdout corrupts the stream and a real client will either fail to
//! parse it or drop the connection. Human-facing text belongs on
//! stderr, and this module writes none at all.
//!
//! ## Why `feed` is the seam
//!
//! `feed` takes bytes; it never takes a reader. That makes every
//! framing case — several messages in one write, a message split
//! across reads, a trailing partial line — reachable from a test with
//! no pipes, no subprocess and no timing. The read loop in `serveStdio`
//! is the only part that knows what a file descriptor is, and it is
//! four lines long for exactly that reason.

const std = @import("std");
const Allocator = std.mem.Allocator;

const framing = @import("framing.zig");
const json = @import("json.zig");
const out = @import("json_out.zig");
const platform_stdio = @import("../platform/stdio.zig");
const protocol = @import("protocol.zig");
const tools = @import("tools.zig");
const version_mod = @import("../version.zig");
const Store = @import("../store/mod.zig").Store;

const log = std.log.scoped(.mem3_mcp);

pub const SERVER_NAME = "mem3";

/// Read buffer for the stdio loop. Large enough that a typical
/// `tools/list` response arrives in one read, small enough to live on
/// the stack.
const READ_BUF: usize = 64 * 1024;

pub const Server = struct {
    alloc: Allocator,
    store: *Store,
    framer: framing.Framer,
    /// Where responses go. A descriptor, not a `std.fs.File`, so a test
    /// can point the server at a scratch file and read the bytes back.
    out_fd: std.posix.fd_t,
    /// Set once a store write has happened, so `serveStdio` can take a
    /// snapshot on a clean exit instead of losing the session to the
    /// WAL-replay path next time. `Store.sync` is a no-op in memory.
    dirty: bool = false,

    pub fn init(alloc: Allocator, store: *Store, out_fd: std.posix.fd_t) Server {
        return .{
            .alloc = alloc,
            .store = store,
            .framer = framing.Framer.init(alloc),
            .out_fd = out_fd,
        };
    }

    pub fn deinit(self: *Server) void {
        self.framer.deinit();
        self.* = undefined;
    }

    /// Read until EOF, then flush the store.
    ///
    /// `n == 0` is EOF. A read error is returned rather than swallowed:
    /// a client that closes the pipe cleanly gets 0, and anything else
    /// is a real fault the operator should see on stderr.
    pub fn serveStdio(self: *Server, in_fd: std.posix.fd_t) !void {
        var buf: [READ_BUF]u8 = undefined;
        while (true) {
            // `platform_fs.read` translates the raw syscall into a
            // typed error, so this loop only has to distinguish "bytes"
            // from "end of stream". An interrupted read surfaces as a
            // generic I/O failure here rather than a retry, which is
            // acceptable: a client that closes the pipe cleanly gives
            // 0, and anything else is a fault worth surfacing.
            const n = try platform_fs.read(in_fd, &buf);
            if (n == 0) break;
            try self.feed(buf[0..n]);
        }
        if (self.dirty) self.store.sync() catch |err| {
            // Losing the snapshot is not fatal: the WAL already holds
            // every record, and replay on the next start restores it.
            log.err("mcp: snapshot on exit failed: {}", .{err});
        };
    }

    /// Handle one chunk of bytes. Zero or more responses may be
    /// written.
    pub fn feed(self: *Server, chunk: []const u8) !void {
        try self.framer.feed(chunk);
        while (self.framer.next()) |outcome| {
            switch (outcome) {
                .too_long => try self.writeError(null, protocol.Code.parse_error, "message exceeds the size limit"),
                .line => |line| try self.handleLine(line),
            }
        }
    }

    /// Dispatch one complete line.
    fn handleLine(self: *Server, line: []const u8) !void {
        // A blank line is not a message. Answering it would be
        // answering something the client never sent.
        if (json.isBlank(line)) return;

        var parsed = protocol.parseMessage(self.alloc, line) catch {
            return self.writeError(null, protocol.Code.internal_error, "out of memory while parsing the request");
        };

        switch (parsed) {
            .rejected => |r| {
                // Even a rejection is answered — with `id: null`, since
                // there is no id to echo. Silence here is what leaves a
                // client waiting forever.
                return self.writeError(null, r.code, r.message);
            },
            .ok => |*env| {
                defer env.deinit();
                if (env.isNotification()) {
                    return self.handleNotification(env);
                }
                return self.handleRequest(env);
            },
        }
    }

    /// Notifications are processed and never answered. This is the
    /// single most consequential asymmetry in MCP: answering one
    /// produces an unsolicited response, and clients that match
    /// responses by id treat that as stream corruption.
    fn handleNotification(self: *Server, env: *protocol.Envelope) !void {
        _ = self;
        if (std.mem.eql(u8, env.method, "notifications/initialized")) return;
        if (std.mem.eql(u8, env.method, "notifications/cancelled")) return;
        // An unknown notification is ignored, as JSON-RPC requires:
        // there is no id, so there is nothing to report an error on.
    }

    fn handleRequest(self: *Server, env: *protocol.Envelope) !void {
        const id = env.id_raw.?;

        if (std.mem.eql(u8, env.method, "initialize")) {
            return self.writeInitialize(id, env);
        }
        if (std.mem.eql(u8, env.method, "ping")) {
            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(self.alloc);
            try result.appendSlice(self.alloc, "{}");
            return self.writeResult(id, result.items);
        }
        if (std.mem.eql(u8, env.method, "tools/list")) {
            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(self.alloc);
            try tools.writeToolsList(self.alloc, &result);
            return self.writeResult(id, result.items);
        }
        if (std.mem.eql(u8, env.method, "tools/call")) {
            return self.handleToolsCall(id, env);
        }

        return self.writeError(id, protocol.Code.method_not_found, "unknown method");
    }

    fn writeInitialize(self: *Server, id: []const u8, env: *protocol.Envelope) !void {
        const requested: ?[]const u8 = if (env.params) |p|
            (if (json.get(p, "protocolVersion")) |v| v.asString() else null)
        else
            null;
        const version = protocol.negotiateVersion(requested);

        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.alloc);

        try result.appendSlice(self.alloc, "{\"protocolVersion\":");
        try out.string(&result, self.alloc, version);
        try result.appendSlice(self.alloc, ",\"capabilities\":{\"tools\":{\"listChanged\":false}}");
        try result.appendSlice(self.alloc, ",\"serverInfo\":{\"name\":");
        try out.string(&result, self.alloc, SERVER_NAME);
        try result.appendSlice(self.alloc, ",\"version\":");
        try out.string(&result, self.alloc, version_mod.VERSION);
        // Two closes: `serverInfo`, then the result object itself. An
        // earlier revision closed only `serverInfo`, so every single
        // `initialize` response was a truncated JSON document — the one
        // message a client cannot proceed without.
        try result.appendSlice(self.alloc, "}}");

        try self.writeResult(id, result.items);
    }

    fn handleToolsCall(self: *Server, id: []const u8, env: *protocol.Envelope) !void {
        const params = env.params orelse {
            return self.writeError(id, protocol.Code.invalid_params, "tools/call requires params");
        };
        const name_value = json.get(params, "name") orelse {
            return self.writeError(id, protocol.Code.invalid_params, "tools/call requires params.name");
        };
        const name = name_value.asString() orelse {
            return self.writeError(id, protocol.Code.invalid_params, "params.name must be a string");
        };
        // `arguments` is by-name, so it is an object or absent. A
        // scalar is not "no arguments" — silently treating it as empty
        // would answer a malformed call as if it had succeeded.
        var arguments: ?json.Value = null;
        if (json.get(params, "arguments")) |a| {
            switch (a) {
                .object => arguments = a,
                else => return self.writeError(
                    id,
                    protocol.Code.invalid_params,
                    "\"arguments\" must be an object",
                ),
            }
        }

        var result = tools.call(self.alloc, self.store, name, arguments) catch |err| switch (err) {
            error.OutOfMemory => {
                return self.writeError(id, protocol.Code.internal_error, "out of memory while running the tool");
            },
            error.UnknownTool => {
                return self.writeError(id, protocol.Code.invalid_params, "unknown tool");
            },
            error.InvalidParams => {
                return self.writeError(id, protocol.Code.invalid_params, "malformed tool arguments");
            },
            error.ToolFailed => {
                // The call was well-formed and the tool refused. That
                // is an `isError` result, not a protocol error: the
                // client sees a completed call it can show to a model,
                // which is what lets it retry with better arguments.
                var reason: std.ArrayList(u8) = .empty;
                defer reason.deinit(self.alloc);
                try reason.appendSlice(self.alloc, "{\"error\":");
                try out.string(&reason, self.alloc, "the tool refused the call; check its required arguments");
                try reason.append(self.alloc, '}');

                // A second buffer: the content block wraps `reason`, so
                // it cannot be appended into the same list it reads.
                var failed: std.ArrayList(u8) = .empty;
                defer failed.deinit(self.alloc);
                try writeToolContent(&failed, self.alloc, reason.items, true);
                return self.writeResult(id, failed.items);
            },
        };
        defer result.deinit();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);
        try writeToolContent(&body, self.alloc, result.text, result.is_error);
        try self.writeResult(id, body.items);
    }

    /// `tools/call` result: a single text block holding the tool's JSON
    /// document, so a model reads one self-describing object rather
    /// than prose wrapped in a content block.
    fn writeToolContent(body: *std.ArrayList(u8), alloc: Allocator, text: []const u8, is_error: bool) !void {
        try body.appendSlice(alloc, "{\"content\":[{\"type\":\"text\",\"text\":");
        try out.string(body, alloc, text);
        try body.appendSlice(alloc, "}],\"isError\":");
        try out.boolean(body, alloc, is_error);
        try body.append(alloc, '}');
    }

    fn writeResult(self: *Server, id: []const u8, result_json: []const u8) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        try protocol.writeResult(&line, self.alloc, id, result_json);
        try self.emit(line.items);
    }

    fn writeError(self: *Server, id: ?[]const u8, code: i32, message: []const u8) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        try protocol.writeError(&line, self.alloc, id, code, message);
        try self.emit(line.items);
    }

    /// One line, one write. Partial writes on a protocol stream would
    /// desynchronise the client's framing, so this loops until the whole
    /// line is out rather than assuming the fd took it all.
    fn emit(self: *Server, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = platform_stdio.writeFd(self.out_fd, bytes[sent..]);
            if (n == 0) {
                log.err("mcp: output descriptor accepted 0 bytes; dropping a {d}-byte response", .{bytes.len});
                return error.OutputWriteFailed;
            }
            sent += n;
        }
        // The trailing newline is part of the frame, and is written
        // separately so that a short write can never split a line's
        // content from its terminator.
        const n = platform_stdio.writeFd(self.out_fd, "\n");
        if (n == 0) return error.OutputWriteFailed;
    }
};

// =============================================================================
// Tests
//
// Named directly in `src/main.zig`'s comptime block — a re-export from
// `src/mcp/mod.zig` does NOT register these with the runner.
//
// Two rules hold for every test below:
//   1. Nothing prints. The runner speaks its protocol over the process
//      pipes; a stderr write kills the test binary and `zig build test`
//      still exits 0.
//   2. The output fd is a scratch file under /tmp, never stdout. A
//      server that printed a response into the test runner's pipe
//      would corrupt the very protocol it is being tested against.
// =============================================================================

const testing = std.testing;
const platform_fs = @import("../platform/fs.zig");

/// A server wired to a scratch file standing in for stdout, plus the
/// path so the bytes can be read back.
const Harness = struct {
    server: *Server,
    store: *Store,
    dir: []u8,
    path: []u8,
    /// Bytes already consumed by an earlier `send`. The harness never
    /// truncates the file (that would desynchronise the write offset),
    /// so each send returns only its own delta — otherwise a second
    /// request in the same session would be handed back together with
    /// the first, and parsing it would fail on trailing garbage.
    consumed: usize = 0,

    fn init(alloc: Allocator, seed_default_goals: bool) !Harness {
        const pid = @as(u64, @intCast(std.c.getpid()));
        const dir = try std.fmt.allocPrint(alloc, "/tmp/mem3_mcp_test_{d}", .{pid});
        errdefer alloc.free(dir);
        const path = try std.fmt.allocPrint(alloc, "/tmp/mem3_mcp_test_{d}/out.jsonl", .{pid});
        errdefer alloc.free(path);

        // `makeDir`, not `makeDirAll`: the scratch path is exactly one
        // level under /tmp, and `makeDirAll` in `src/platform/fs.zig`
        // does not currently compile (it reads `path.len` off a
        // `[*:0]const u8`). That file is not this change's to edit, so
        // the working single-level call is used and the defect is
        // reported to the owner.
        platform_fs.makeDir(platform_fs.z(dir).ptr()) catch {};

        const fd = try platform_fs.open(
            platform_fs.z(path).ptr(),
            .{ .access = .write_only, .create = .truncate },
        );
        errdefer platform_fs.close(fd);

        const store = try Store.init(alloc, .{
            .data_dir = null, // in-memory: no WAL, no files, no leftovers
            .seed_default_goals = seed_default_goals,
        });
        errdefer store.deinit();

        const server = try alloc.create(Server);
        server.* = Server.init(alloc, store, fd);
        // `fd` stays open for the harness's life; `deinit` closes it.
        return .{ .server = server, .store = store, .dir = dir, .path = path, .consumed = 0 };
    }

    fn deinit(self: *Harness, alloc: Allocator) void {
        self.server.framer.deinit();
        platform_fs.close(self.server.out_fd);
        self.store.deinit();
        alloc.destroy(self.server);
        platform_fs.unlink(platform_fs.z(self.path).ptr()) catch {};
        platform_fs.removeDir(platform_fs.z(self.dir).ptr()) catch {};
        alloc.free(self.dir);
        alloc.free(self.path);
    }

    /// Everything the server has written so far.
    fn output(self: *Harness, alloc: Allocator) ![]u8 {
        const read_fd = try platform_fs.open(
            platform_fs.z(self.path).ptr(),
            .{ .access = .read_only },
        );
        defer platform_fs.close(read_fd);

        const size = try platform_fs.sizeOf(read_fd);
        const buf = try alloc.alloc(u8, @intCast(size));
        errdefer alloc.free(buf);
        var filled: usize = 0;
        while (filled < buf.len) {
            const n = try platform_fs.read(read_fd, buf[filled..]);
            if (n == 0) break;
            filled += n;
        }
        return alloc.realloc(buf, filled) catch buf;
    }

    /// Feed bytes, then return only the responses they produced.
    fn send(self: *Harness, alloc: Allocator, bytes: []const u8) ![]u8 {
        const before = self.consumed;
        try self.server.feed(bytes);
        const all = try self.output(alloc);
        defer alloc.free(all);
        self.consumed = all.len;
        return alloc.dupe(u8, all[before..]);
    }

    /// Send and immediately discard the reply. The bytes are still
    /// counted in `consumed`, so a later delta is still correct.
    fn drain(self: *Harness, alloc: Allocator, line: []const u8) !void {
        const got = try self.sendMessage(alloc, line);
        alloc.free(got);
    }

    /// Feed a line with its terminating newline, as a client would.
    fn sendMessage(self: *Harness, alloc: Allocator, line: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, line);
        try buf.append(alloc, '\n');
        return self.send(alloc, buf.items);
    }
};

test "server: initialize → tools/list → tools/call completes a handshake" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    // 1. initialize
    const init_out = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}
    );
    defer alloc.free(init_out);
    var d1 = try json.parse(alloc, init_out);
    defer d1.deinit();
    try testing.expectEqualStrings("2025-06-18", json.get(json.get(d1.root, "result").?, "protocolVersion").?.asString().?);
    // `tools` is the capability this server actually implements, and
    // it is the only one advertised.
    const caps = json.get(json.get(d1.root, "result").?, "capabilities").?;
    try testing.expect(json.get(caps, "tools") != null);
    try testing.expect(json.get(caps, "resources") == null);
    try testing.expect(json.get(caps, "prompts") == null);
    const info = json.get(json.get(d1.root, "result").?, "serverInfo").?;
    try testing.expectEqualStrings("mem3", json.get(info, "name").?.asString().?);
    try testing.expect(json.get(info, "version").?.asString().?.len > 0);

    // 2. notifications/initialized — no id, and no bytes back.
    const notif = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer alloc.free(notif);
    try testing.expectEqualStrings("", notif);

    // 3. tools/list
    const list_out = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    defer alloc.free(list_out);
    var d2 = try json.parse(alloc, list_out);
    defer d2.deinit();
    try testing.expectEqual(@as(usize, tools.CATALOGUE.len), json.get(json.get(d2.root, "result").?, "tools").?.asArray().?.len);

    // 4. tools/call
    const call_out = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_add","arguments":{"episode":"the tag was pushed","source":"matter","goal_ids":[1]}}}
    );
    defer alloc.free(call_out);
    var d3 = try json.parse(alloc, call_out);
    defer d3.deinit();
    const content = json.get(json.get(d3.root, "result").?, "content").?.asArray().?;
    try testing.expectEqualStrings("text", json.get(content[0], "type").?.asString().?);
    try testing.expectEqual(false, json.get(json.get(d3.root, "result").?, "isError").?.asBool().?);

    // The tool's own JSON, inside the text block, parses too.
    var d4 = try json.parse(alloc, json.get(content[0], "text").?.asString().?);
    defer d4.deinit();
    try testing.expect(json.get(d4.root, "id").?.asNumber().? >= 1);

    // And the store really holds it.
    try testing.expectEqual(@as(usize, 1), h.store.cellCount());
}

test "server: a notification produces no response at all" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    try testing.expectEqualStrings("", try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ));
    try testing.expectEqualStrings("", try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}
    ));
    try testing.expectEqualStrings("", try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","method":"something/nobody/implemented"}
    ));

    // And the stream is still usable afterwards.
    const ping = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","id":9,"method":"ping"}
    );
    defer alloc.free(ping);
    try testing.expect(std.mem.indexOf(u8, ping, "\"id\":9") != null);
}

test "server: a blank line is not a message" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    try testing.expectEqualStrings("", try h.send(alloc, "\n"));
    try testing.expectEqualStrings("", try h.send(alloc, "   \n"));
    try testing.expectEqualStrings("", try h.send(alloc, "\r\n"));
}

test "server: a malformed line is answered with a parse error, not silence" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    const bad = try h.send(alloc, "{\"jsonrpc\":\"2.0\", oops}\n");
    defer alloc.free(bad);

    try testing.expect(bad.len > 0);
    var d = try json.parse(alloc, bad);
    defer d.deinit();
    try testing.expect(json.get(d.root, "id").? == .null);
    try testing.expectEqual(
        @as(f64, @floatFromInt(protocol.Code.parse_error)),
        json.get(json.get(d.root, "error").?, "code").?.asNumber().?,
    );
}

test "server: an over-long line is rejected and the next message still works" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    const big = try alloc.alloc(u8, framing.MAX_LINE_BYTES + 32);
    defer alloc.free(big);
    @memset(big, 'z');

    const rejected = try h.send(alloc, big);
    defer alloc.free(rejected);
    try testing.expect(std.mem.indexOf(u8, rejected, "-32700") != null);

    // The over-long line is still *open* at this point: everything up
    // to the next newline is part of it, so the framer is right to
    // swallow whatever comes next. Terminating the line is what lets
    // the stream resynchronise.
    const swallowed = try h.send(alloc,
        \\{"jsonrpc":"2.0","id":11,"method":"ping"}
    );
    defer alloc.free(swallowed);
    try testing.expectEqualStrings("", swallowed);

    try testing.expectEqualStrings("", try h.send(alloc, "\n"));

    const after = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","id":12,"method":"ping"}
    );
    defer alloc.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "\"id\":12") != null);
}

test "server: several requests in one write each get their own answer" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    const both = try h.send(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        \\
    );
    defer alloc.free(both);

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, both, '\n');
    while (it.next()) |l| {
        if (l.len > 0) lines += 1;
    }
    try testing.expectEqual(@as(usize, 2), lines);
    // Every line is independently parseable — a real client reads them
    // one at a time and must not need the others.
    var one = std.mem.splitScalar(u8, both, '\n');
    while (one.next()) |l| {
        if (l.len == 0) continue;
        var d = try json.parse(alloc, l);
        defer d.deinit();
    }
}

test "server: a message split across three feeds is answered once, at the end" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    try h.server.feed("{\"jsonrpc\":\"2.0\",");
    try testing.expectEqualStrings("", try h.output(alloc));

    try h.server.feed("\"id\":4,\"method\":\"ping\"}");
    try testing.expectEqualStrings("", try h.output(alloc));

    const final_out = try h.send(alloc, "\n");
    defer alloc.free(final_out);
    try testing.expect(std.mem.indexOf(u8, final_out, "\"id\":4") != null);
}

test "server: an unknown method is -32601" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    const bad = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","id":5,"method":"resources/list"}
    );
    defer alloc.free(bad);

    var d = try json.parse(alloc, bad);
    defer d.deinit();
    try testing.expectEqual(@as(f64, 5), json.get(d.root, "id").?.asNumber().?);
    try testing.expectEqual(
        @as(f64, @floatFromInt(protocol.Code.method_not_found)),
        json.get(json.get(d.root, "error").?, "code").?.asNumber().?,
    );
}

test "server: malformed params are -32602" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    const cases = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":7}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_stats\",\"arguments\":\"not an object\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":5}"
    };
    var wrong_code = false;
    for (cases) |line| {
        const got = try h.sendMessage(alloc, line);
        defer alloc.free(got);
        var d = try json.parse(alloc, got);
        defer d.deinit();
        const code = json.get(json.get(d.root, "error").?, "code") orelse {
            wrong_code = true;
            break;
        };
        if (code.asNumber().? != @as(f64, @floatFromInt(protocol.Code.invalid_params))) {
            wrong_code = true;
            break;
        }
    }
    try testing.expect(!wrong_code);
}

test "server: an unknown tool is refused without killing the session" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    const bad = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"memory_eject","arguments":{}}}
    );
    defer alloc.free(bad);
    try testing.expect(std.mem.indexOf(u8, bad, "unknown tool") != null);

    // Still alive.
    const ok = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    );
    defer alloc.free(ok);
    try testing.expect(std.mem.indexOf(u8, ok, "\"id\":2") != null);
}

test "server: a refused tool call is an isError result, not a protocol error" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    // Well-formed call to a real tool with missing required arguments.
    const got = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"memory_add","arguments":{}}}
    );
    defer alloc.free(got);

    var d = try json.parse(alloc, got);
    defer d.deinit();
    // No top-level `error`: the call completed.
    try testing.expect(json.get(d.root, "error") == null);
    const result = json.get(d.root, "result").?;
    try testing.expectEqual(true, json.get(result, "isError").?.asBool().?);
    try testing.expect(json.get(result, "content").?.asArray().?.len == 1);
}

test "server: every response line is a complete, independently parseable document" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    try h.drain(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
    );
    try h.drain(alloc,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    try h.drain(alloc,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_stats","arguments":{}}}
    );
    try h.drain(alloc,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"goal_list","arguments":{}}}
    );

    const all = try h.output(alloc);
    defer alloc.free(all);

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, all, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
        var d = try json.parse(alloc, line);
        defer d.deinit();
        try testing.expectEqualStrings("2.0", json.get(d.root, "jsonrpc").?.asString().?);
        try testing.expect(json.get(d.root, "id") != null);
        // Exactly one of result / error, never both and never neither.
        const has_result = json.get(d.root, "result") != null;
        const has_error = json.get(d.root, "error") != null;
        try testing.expect(has_result != has_error);
    }
    try testing.expectEqual(@as(usize, 4), count);
}

test "server: initialize falls back to our version for an unknown one" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    const got = try h.sendMessage(alloc,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}
    );
    defer alloc.free(got);

    var d = try json.parse(alloc, got);
    defer d.deinit();
    try testing.expectEqualStrings(
        protocol.PROTOCOL_VERSION,
        json.get(json.get(d.root, "result").?, "protocolVersion").?.asString().?,
    );
}

test "server: a full session over many messages leaks nothing" {
    const alloc = testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    const transcript = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_add\",\"arguments\":{\"episode\":\"héllo \\\"wörld\\\" \\t tab \\\\n line\",\"source\":\"matter\",\"facts\":[\"a|b|c\"],\"goal_ids\":[1]}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_query\",\"arguments\":{\"query\":\"héllo\",\"topk\":5}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_stats\",\"arguments\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"goal_list\",\"arguments\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"memory_forget\",\"arguments\":{\"dry_run\":true}}}",
        "garbage that is not json at all,",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"ping\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"nope/nope\"}"
    };

    var all_replies: std.ArrayList(u8) = .empty;
    defer all_replies.deinit(alloc);
    var notification_replies: usize = 0;

    for (transcript) |line| {
        const got = try h.sendMessage(alloc, line);
        defer alloc.free(got);
        try all_replies.appendSlice(alloc, got);
        const is_notification = std.mem.indexOf(u8, line, "notifications/") != null;
        if (is_notification) {
            notification_replies += 1;
            // The single most consequential silence in MCP.
            try testing.expectEqualStrings("", got);
        } else {
            // Every other line gets exactly one response line.
            var it = std.mem.splitScalar(u8, got, '\n');
            var n: usize = 0;
            while (it.next()) |l| {
                if (l.len > 0) n += 1;
            }
            try testing.expectEqual(@as(usize, 1), n);
        }
    }

    try testing.expectEqual(@as(usize, 1), notification_replies);
    // Eleven lines in, ten responses out.
    try testing.expectEqual(@as(usize, 10), countLines(all_replies.items));
    // The memory_add really landed in the store, and the dry-run sweep
    // really kept it.
    try testing.expectEqual(@as(usize, 1), h.store.cellCount());
}

/// Number of non-empty lines in a response stream.
fn countLines(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len > 0) n += 1;
    }
    return n;
}
