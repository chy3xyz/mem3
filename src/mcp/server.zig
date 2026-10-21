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
const signal = @import("../platform/signal.zig");
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
    /// Stop on SIGINT/SIGTERM and wake every 100 ms while idle. Off by
    /// default so a test or an embedding host is not driven by the
    /// process-global signal flag; `mem3 mcp` turns it on.
    watch_signals: bool = false,
    /// Non-null while a JSON-RPC batch is being dispatched. `emit`
    /// appends here instead of writing, and `handleBatch` turns the
    /// result into one array. See `emit`.
    batch_buf: ?std.ArrayList(u8) = null,

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
            if (self.watch_signals) {
                if (signal.terminationRequested()) break;
                // Bounded wait, not a blocking read: a signal that lands
                // between the check above and the read would otherwise sit
                // until the client next speaks. The same wake-up is the
                // idle tick for `--wal-sync=interval:N`.
                if (!signal.waitReadable(in_fd, 100)) {
                    if (self.store.wal) |w| w.syncIfDue() catch {};
                    continue;
                }
            }
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

        // MCP: "Implementations MUST support receiving batches". A batch
        // is one line holding a top-level array, and every response to it
        // has to come back as a single array — so it cannot reuse the
        // one-message path, which emits as it goes.
        if (framing.BatchIterator.isBatch(line)) return self.handleBatch(line);

        try self.handleMessage(line);
    }

    /// Dispatch every message in a JSON-RPC batch and answer with one
    /// array.
    ///
    /// Three rules from JSON-RPC 2.0 §5 govern the edges:
    ///
    ///   * A batch that is not an array, or an array with no elements, is
    ///     answered with a **single** response object carrying `id: null`
    ///     — never an array, and never an empty one.
    ///   * An array of only notifications produces **no output at all**.
    ///     An empty array response would be a response to nothing.
    ///   * An invalid element inside a valid batch is answered in place,
    ///     with `id: null`, and the rest of the batch still runs.
    fn handleBatch(self: *Server, line: []const u8) !void {
        var it = framing.BatchIterator.init(line) catch {
            return self.writeError(null, protocol.Code.invalid_request, "batch must be a JSON array of messages");
        };

        self.batch_buf = .empty;
        defer if (self.batch_buf) |*b| b.deinit(self.alloc);

        var dispatched: usize = 0;
        // `next`'s payload is itself optional: `[]` reaches the closing
        // bracket with no element open, and that is the empty-batch case
        // rather than a value, so the optional is resolved here instead of
        // being unwrapped by the `while` capture.
        var malformed = false;
        while (it.next()) |maybe_elem| {
            const elem = maybe_elem orelse break;
            dispatched += 1;
            // A failing element must not abandon the ones after it: the
            // client sent a whole batch and is owed an answer to each.
            self.handleMessage(elem) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => try self.writeError(null, protocol.Code.internal_error, "failed while handling one batch element"),
            };
        } else |err| {
            malformed = err == error.MalformedBatch;
        }

        // Detach before answering. A batch that turns out to be malformed
        // is answered with a *single* response object, and leaving the
        // capture buffer installed would swallow that object into the
        // array being abandoned.
        var collected = self.takeBatch();
        defer collected.deinit(self.alloc);

        if (malformed) {
            return self.writeError(null, protocol.Code.invalid_request, "batch is not a well-formed array of messages");
        }
        if (dispatched == 0) {
            // `[]` — an array with no value in it. A single response
            // object, because there is nothing to put in an array.
            return self.writeError(null, protocol.Code.invalid_request, "batch must contain at least one message");
        }
        if (collected.items.len == 0) {
            // Every element was a notification. Silence is the only
            // correct answer; `[]` would be a response to nothing.
            return;
        }
        try self.emitBatchArray(collected.items);
    }

    /// Detach the capture buffer and hand it to the caller. Setting the
    /// field to `null` is what stops `emit` from writing back into a
    /// buffer the caller now owns.
    fn takeBatch(self: *Server) std.ArrayList(u8) {
        const b = self.batch_buf.?;
        self.batch_buf = null;
        return b;
    }

    /// Write `[` + collected responses + `]`, bypassing the capture
    /// buffer the responses were collected into.
    fn emitBatchArray(self: *Server, items: []const u8) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        try line.appendSlice(self.alloc, "[");
        try line.appendSlice(self.alloc, items);
        try line.append(self.alloc, ']');
        try self.emitRaw(line.items);
    }

    /// Parse and dispatch exactly one message, writing whatever response
    /// it produces straight to the output fd (or into the batch buffer).
    fn handleMessage(self: *Server, line: []const u8) !void {
        var parsed = protocol.parseMessage(self.alloc, line) catch {
            return self.writeError(null, protocol.Code.internal_error, "out of memory while parsing the request");
        };

        switch (parsed) {
            .rejected => |r| {
                // Even a rejection is answered. The id is the one the
                // request carried when it had one — `null` is only for an
                // id we could not read, which is what makes a batch of
                // several bad elements distinguishable from each other.
                return self.writeError(r.id_raw, r.code, r.message);
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
        const era = protocol.eraOf(env.params, env.method);

        // Modern-era admission. Both `_meta` fields the spec marks
        // required are checked here rather than at each method, because
        // "every request carries them" is a property of the era and not
        // of any one method.
        if (era.isModern()) {
            const requested = protocol.requestedVersion(env.params).?;
            if (!protocol.supportsVersion(requested)) {
                return self.writeUnsupportedVersion(id, requested);
            }
            if (protocol.metaGet(env.params, protocol.META_CLIENT_CAPABILITIES) == null) {
                return self.writeError(
                    id,
                    protocol.Code.invalid_params,
                    "a 2026-07-28 request requires params._meta.io.modelcontextprotocol/clientCapabilities",
                );
            }
        }

        if (std.mem.eql(u8, env.method, "server/discover")) {
            // `server/discover` with no per-request `_meta` is answered
            // `-32602` on purpose. It is the stdio fallback probe: a
            // dual-era client sends this first, and treats any error
            // that is not a recognised modern error as "legacy server,
            // use `initialize`". `-32602` is exactly that, so a legacy
            // client degrades instead of failing.
            if (!era.isModern()) {
                return self.writeError(
                    id,
                    protocol.Code.invalid_params,
                    "server/discover requires params._meta.io.modelcontextprotocol/protocolVersion",
                );
            }
            return self.writeDiscover(id, era);
        }

        if (std.mem.eql(u8, env.method, "initialize")) {
            return self.writeInitialize(id, env);
        }
        if (std.mem.eql(u8, env.method, "ping")) {
            // Removed in 2026-07-28, but a legacy client's liveness
            // probe still sends it, and answering costs one empty
            // object.
            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(self.alloc);
            try result.appendSlice(self.alloc, "{}");
            return self.writeResultForEra(id, result.items, era);
        }
        if (std.mem.eql(u8, env.method, "tools/list")) {
            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(self.alloc);
            try tools.writeToolsList(self.alloc, &result);
            return self.writeResultForEra(id, result.items, era);
        }
        if (std.mem.eql(u8, env.method, "tools/call")) {
            return self.handleToolsCall(id, env, era);
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

    fn handleToolsCall(self: *Server, id: []const u8, env: *protocol.Envelope, era: protocol.Era) !void {
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
                return self.writeResultForEra(id, failed.items, era);
            },
        };
        defer result.deinit();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);
        try writeToolContent(&body, self.alloc, result.text, result.is_error);
        try self.writeResultForEra(id, body.items, era);
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

    /// The same result, wrapped for whichever era asked.
    ///
    /// The legacy shape is passed through untouched. The modern shape
    /// gains `resultType` and a `serverInfo` echo, both of which the
    /// 2026-07-28 revision requires and no earlier one knows about —
    /// adding them unconditionally would change the bytes a legacy
    /// client validates against, for no benefit.
    fn writeResultForEra(self: *Server, id: []const u8, result_json: []const u8, era: protocol.Era) !void {
        if (!era.isModern()) return self.writeResult(id, result_json);

        // Two buffers, not one: `writeResult` *appends* the envelope
        // around the result it is handed, so passing it the list that is
        // mid-construction would splice the document into itself.
        var modern: std.ArrayList(u8) = .empty;
        defer modern.deinit(self.alloc);
        protocol.wrapModernResult(&modern, self.alloc, result_json) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotAResultObject => {
                // A builder emitted something that is not a bare object.
                // Refusing is better than shipping a result whose fields
                // the client cannot read and whose emptiness it cannot
                // explain.
                return self.writeError(id, protocol.Code.internal_error, "tool produced a result that is not a JSON object");
            },
        };

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        try protocol.writeResult(&line, self.alloc, id, modern.items);
        try self.emit(line.items);
    }

    /// `server/discover` — the one method the spec says a server MUST
    /// implement. It is how a modern client learns what this server
    /// speaks without guessing, and how a dual-era client decides
    /// whether to stay modern or fall back to `initialize`.
    ///
    /// No tools are listed here: that is `tools/list`'s job, and the
    /// discover probe is meant to be cheap enough to send before any
    /// real work.
    fn writeDiscover(self: *Server, id: []const u8, era: protocol.Era) !void {
        var result: std.ArrayList(u8) = .empty;
        defer result.deinit(self.alloc);
        try result.appendSlice(self.alloc, "{\"supportedVersions\":[");
        for (protocol.SUPPORTED_VERSIONS, 0..) |v, i| {
            if (i != 0) try result.append(self.alloc, ',');
            try out.string(&result, self.alloc, v);
        }
        // Only `tools` is declared. Advertising `resources` or `prompts`
        // would make a client probe methods this server answers with
        // -32601, and the spec prefers an absent capability to a
        // declared-and-unimplemented one.
        try result.appendSlice(self.alloc, "],\"capabilities\":{\"tools\":{}},\"instructions\":");
        try out.string(
            &result,
            self.alloc,
            "TriSource-EverOS memory. memory_add needs a spirit dimension: pass source and at least one of facts or goal_ids.",
        );
        // Cacheable: this answer cannot change while the process lives,
        // which is exactly what a shared cache is safe for.
        try result.appendSlice(self.alloc, ",\"ttlMs\":60000,\"cacheScope\":\"public\"}");

        return self.writeResultForEra(id, result.items, era);
    }

    /// `-32022 UnsupportedProtocolVersion`, with the versions this
    /// server does speak.
    ///
    /// The `supported` list is the whole point of the error: the client
    /// is expected to pick one and retry, and a client that has not
    /// migrated has no other way to learn what would work.
    fn writeUnsupportedVersion(self: *Server, id: []const u8, requested: []const u8) !void {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.alloc);
        try line.appendSlice(self.alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
        try line.appendSlice(self.alloc, id);
        try line.appendSlice(self.alloc, ",\"error\":{\"code\":");
        try out.int(&line, self.alloc, protocol.Code.unsupported_protocol_version);
        try line.appendSlice(self.alloc, ",\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[");
        for (protocol.SUPPORTED_VERSIONS, 0..) |v, i| {
            if (i != 0) try line.append(self.alloc, ',');
            try out.string(&line, self.alloc, v);
        }
        try line.appendSlice(self.alloc, "],\"requested\":");
        try out.string(&line, self.alloc, requested);
        try line.appendSlice(self.alloc, "}}}");
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
    ///
    /// Inside a batch, responses are *collected* rather than written:
    /// JSON-RPC requires every response to one batch to arrive as a
    /// single array, so an element answered straight to the fd would
    /// already be out of order by the time the second one is produced.
    fn emit(self: *Server, bytes: []const u8) !void {
        if (self.batch_buf) |*b| {
            if (b.items.len != 0) try b.appendSlice(self.alloc, ",");
            try b.appendSlice(self.alloc, bytes);
            return;
        }
        try self.emitRaw(bytes);
    }

    /// Write bytes to the output fd with no batch capture, so the array
    /// that closes a batch is not swallowed by the buffer it came from.
    fn emitRaw(self: *Server, bytes: []const u8) !void {
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

// -----------------------------------------------------------------------------
// JSON-RPC batching.
//
// MCP says "Implementations MUST support receiving batches; MAY support sending
// them". Each test below pins one of the three edges of JSON-RPC 2.0 §5, which
// are the parts a batch implementation gets wrong.
// -----------------------------------------------------------------------------

test "framing: a batch is one line, and its elements are found without parsing them" {
    var it = try framing.BatchIterator.init(
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"ping"}]
    );
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    , (try it.next()).?);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    , (try it.next()).?);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    , (try it.next()).?);
    try testing.expectEqual(@as(?[]const u8, null), try it.next());
}

test "framing: a comma or bracket inside a string does not end an element" {
    // The whole reason this is hand-written rather than a split on ',':
    // a naive splitter cuts this batch into two malformed halves.
    var it = try framing.BatchIterator.init(
        \\[{"jsonrpc":"2.0","id":1,"params":{"episode":"a, b] c {d} e"}},{"jsonrpc":"2.0","id":2,"method":"ping"}]
    );
    try testing.expect(std.mem.indexOf(u8, (try it.next()).?, "a, b] c {d} e") != null);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    , (try it.next()).?);
}

test "framing: an escaped quote does not end the string it is in" {
    // Without the escape flag the `\"` closes the string on the escaped
    // quote, and every `,` and `]` after it is read as structure.
    var it = try framing.BatchIterator.init(
        \\[{"jsonrpc":"2.0","id":1,"params":{"episode":"he said \"],{[\" loudly"}},{"jsonrpc":"2.0","id":2,"method":"ping"}]
    );
    try testing.expect(std.mem.indexOf(u8, (try it.next()).?, "he said") != null);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    , (try it.next()).?);
}

test "framing: nested arrays and objects are not element boundaries" {
    var it = try framing.BatchIterator.init(
        \\[{"jsonrpc":"2.0","id":1,"params":{"goal_ids":[1,2,3],"nested":{"a":[4,5]}}},{"jsonrpc":"2.0","id":2,"method":"ping"}]
    );
    try testing.expect(std.mem.indexOf(u8, (try it.next()).?, "goal_ids") != null);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    , (try it.next()).?);
}

test "framing: a truncated batch is malformed, not a silently short answer" {
    try testing.expectError(error.MalformedBatch, framing.BatchIterator.init("{\"jsonrpc\":\"2.0\"}"));
    try testing.expectError(error.MalformedBatch, framing.BatchIterator.init(""));
    // Missing the closing bracket: reporting the partial tail as a whole
    // message would answer a request the client never finished sending.
    var it = try framing.BatchIterator.init(
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    try testing.expectError(error.MalformedBatch, it.next());
}

test "framing: isBatch reports shape, not validity" {
    try testing.expect(framing.BatchIterator.isBatch("  [1]  "));
    try testing.expect(!framing.BatchIterator.isBatch("{\"jsonrpc\":\"2.0\"}"));
    try testing.expect(!framing.BatchIterator.isBatch(""));
    try testing.expect(!framing.BatchIterator.isBatch("   "));
}

test "server: a batch answers with ONE array holding every response" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const got = try h.sendMessage(testing.allocator,
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"},{"jsonrpc":"2.0","id":3,"method":"tools/list"}]
    );
    defer testing.allocator.free(got);

    // One line, not three. A client reading responses by id still copes,
    // but one that reads a single response per write does not.
    try testing.expectEqual(@as(usize, 1), countLines(got));

    var doc = try json.parse(testing.allocator, std.mem.trim(u8, got, "\r\n"));
    defer doc.deinit();
    const arr = doc.root.asArray().?;
    try testing.expectEqual(@as(usize, 3), arr.len);
    for (arr) |v| {
        const o = v.asObject().?;
        try testing.expect(json.get(.{ .object = o }, "result") != null);
    }
}

test "server: a batch of only notifications produces no output at all" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const got = try h.sendMessage(testing.allocator,
        \\[{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","method":"notifications/cancelled"}]
    );
    defer testing.allocator.free(got);

    // `[]` would be a response to nothing, and a client matching
    // responses by id would wait on ids that were never sent.
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "server: an empty batch is one error object, not an empty array" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const got = try h.sendMessage(testing.allocator, "[]");
    defer testing.allocator.free(got);

    try testing.expectEqual(@as(usize, 1), countLines(got));
    const trimmed = std.mem.trim(u8, got, "\r\n");
    try testing.expectEqualStrings("{", trimmed[0..1]);
    try testing.expect(std.mem.indexOf(u8, trimmed, "-32600") != null);
}

test "server: a bad element is answered in place and the rest of the batch still runs" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const got = try h.sendMessage(testing.allocator,
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2},{"jsonrpc":"2.0","id":3,"method":"ping"}]
    );
    defer testing.allocator.free(got);

    var doc = try json.parse(testing.allocator, std.mem.trim(u8, got, "\r\n"));
    defer doc.deinit();
    const arr = doc.root.asArray().?;
    // Three in, three out. Aborting at the bad element would leave the
    // client waiting on ids 1 and 3 forever.
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expect(json.get(.{ .object = arr[0].asObject().? }, "result") != null);
    try testing.expect(json.get(.{ .object = arr[1].asObject().? }, "error") != null);
    try testing.expect(json.get(.{ .object = arr[2].asObject().? }, "result") != null);
}

test "server: a tool call inside a batch really runs" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const got = try h.sendMessage(testing.allocator,
        \\[{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"memory_stats","arguments":{}}},{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"memory_stats","arguments":{}}}]
    );
    defer testing.allocator.free(got);

    var doc = try json.parse(testing.allocator, std.mem.trim(u8, got, "\r\n"));
    defer doc.deinit();
    const arr = doc.root.asArray().?;
    try testing.expectEqual(@as(usize, 2), arr.len);
    for (arr) |v| try testing.expect(json.get(.{ .object = v.asObject().? }, "result") != null);
}

test "server: a single message is still not treated as a batch" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const got = try h.sendMessage(testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
    );
    defer testing.allocator.free(got);

    // The regression this guards: routing every line through the batch
    // path would wrap a lone response in an array, and a client expecting
    // one response object would reject it.
    try testing.expectEqual(@as(usize, 1), countLines(got));
    const trimmed = std.mem.trim(u8, got, "\r\n");
    try testing.expectEqualStrings("{", trimmed[0..1]);
}

// -----------------------------------------------------------------------------
// MCP revision 2026-07-28 — the stateless core.
//
// The revision removes the `initialize` handshake, moves the protocol
// version into every request's `_meta`, requires a `resultType` on every
// result, and makes `server/discover` mandatory. mem3 is dual-era: these
// tests pin the modern path *and* that it did not disturb the legacy one.
//
// Requests are assembled with `appendSlice` rather than written as format
// strings. Zig treats `{` and `}` inside a format string as interpolation
// delimiters, so a JSON body full of them has to be doubled — and getting
// that wrong once sent a request with its braces eaten, which the server
// correctly answered with -32700 while the test blamed the server.
// -----------------------------------------------------------------------------

/// A modern-era request line. `params_tail` goes inside `params`, before
/// the `_meta` block; pass `""` for a request with no other parameters.
fn modernRequest(
    alloc: std.mem.Allocator,
    id: []const u8,
    method: []const u8,
    params_tail: []const u8,
    version: []const u8,
) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    try line.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try out.string(&line, alloc, id);
    try line.appendSlice(alloc, ",\"method\":");
    try out.string(&line, alloc, method);
    try line.appendSlice(alloc, ",\"params\":{");
    try line.appendSlice(alloc, params_tail);
    try line.appendSlice(alloc, "\"_meta\":{");
    try line.appendSlice(alloc, "\"io.modelcontextprotocol/protocolVersion\":");
    try out.string(&line, alloc, version);
    try line.appendSlice(alloc, ",\"io.modelcontextprotocol/clientCapabilities\":{}");
    // Four objects are open here — the JSON-RPC envelope, `params`,
    // `_meta` and `clientInfo` — and all four are closed.
    try line.appendSlice(alloc, ",\"io.modelcontextprotocol/clientInfo\":{\"name\":\"probe\",\"version\":\"1\"}}}}");
    return line.toOwnedSlice(alloc);
}

test "server: a modern request is built with braces that survive" {
    // The regression this guards is a construction bug, not a protocol
    // one: a request whose braces were eaten looks exactly like a client
    // sending garbage, and the -32700 it draws is correct behaviour
    // being blamed for the mistake.
    const alloc = testing.allocator;
    const line = try modernRequest(alloc, "1", "server/discover", "", protocol.MODERN_VERSION);
    defer alloc.free(line);

    var doc = try json.parse(alloc, line);
    defer doc.deinit();
    const root = doc.root.asObject().?;
    try testing.expectEqualStrings("2.0", (json.get(.{ .object = root }, "jsonrpc") orelse unreachable).asString().?);
    try testing.expectEqualStrings("server/discover", (json.get(.{ .object = root }, "method") orelse unreachable).asString().?);
    const params = json.get(.{ .object = root }, "params").?;
    try testing.expectEqualStrings(
        protocol.MODERN_VERSION,
        (protocol.metaGet(params, protocol.META_PROTOCOL_VERSION) orelse unreachable).asString().?,
    );
}

test "server: server/discover reports versions, capabilities and identity" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const line = try modernRequest(testing.allocator, "d1", "server/discover", "", protocol.MODERN_VERSION);
    defer testing.allocator.free(line);
    const got = try h.sendMessage(testing.allocator, line);
    defer testing.allocator.free(got);

    var doc = try json.parse(testing.allocator, std.mem.trim(u8, got, "\r\n"));
    defer doc.deinit();
    const root = doc.root.asObject().?;
    const result = json.get(.{ .object = root }, "result") orelse {
        std.debug.print("no result: {s}\n", .{got});
        return error.MissingResult;
    };

    try testing.expectEqualStrings("complete", (json.get(result, "resultType") orelse unreachable).asString().?);

    // The id must come back exactly as sent. A *string* id here, not a
    // number, is why ids are echoed as source text rather than parsed and
    // reprinted.
    try testing.expectEqualStrings("d1", (json.get(.{ .object = root }, "id") orelse unreachable).asString().?);

    const versions = (json.get(result, "supportedVersions") orelse unreachable).asArray().?;
    try testing.expect(versions.len >= 2);
    try testing.expectEqualStrings(protocol.MODERN_VERSION, versions[0].asString().?);
    for (versions) |v| try testing.expect(protocol.supportsVersion(v.asString().?));
    // It must also list what the handshake can still negotiate. A modern
    // client reading this and picking a legacy version must not then be
    // told to downgrade to something it cannot use.
    for (protocol.LEGACY_VERSIONS) |lv| {
        var found = false;
        for (versions) |v| found = found or std.mem.eql(u8, v.asString().?, lv);
        try testing.expect(found);
    }

    // Only `tools` is implemented, so only `tools` may be advertised. The
    // spec prefers an absent capability to a declared-and-unimplemented one.
    const caps = (json.get(result, "capabilities") orelse unreachable).asObject().?;
    try testing.expect(json.get(.{ .object = caps }, "tools") != null);
    try testing.expect(json.get(.{ .object = caps }, "resources") == null);
    try testing.expect(json.get(.{ .object = caps }, "prompts") == null);

    const meta = (json.get(result, "_meta") orelse unreachable).asObject().?;
    const info = json.get(.{ .object = meta }, protocol.META_SERVER_INFO) orelse unreachable;
    try testing.expectEqualStrings(protocol.SERVER_NAME, (json.get(info, "name") orelse unreachable).asString().?);
}

test "server: server/discover without per-request _meta is -32602, the fallback signal" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    // A legacy client probes with `server/discover` first and treats any
    // error that is not a recognised modern error as "legacy server, send
    // `initialize` instead". So this MUST be -32602 and MUST NOT be
    // -32022 — -32022 means "I am modern, retry with a version I speak".
    const got = try h.sendMessage(testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}
    );
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "-32602") != null);
    try testing.expect(std.mem.indexOf(u8, got, "-32022") == null);
}

test "server: an unsupported version is -32022 listing what we do speak" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const line = try modernRequest(testing.allocator, "1", "tools/list", "", "1999-01-01");
    defer testing.allocator.free(line);
    const got = try h.sendMessage(testing.allocator, line);
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "-32022") != null);
    // The client is expected to pick one of these and retry. An error that
    // does not say what would work leaves it with nothing but disconnect.
    try testing.expect(std.mem.indexOf(u8, got, "1999-01-01") != null);
    try testing.expect(std.mem.indexOf(u8, got, protocol.MODERN_VERSION) != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"supported\"") != null);
}

test "server: a modern request missing a required _meta field is -32602" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    // protocolVersion present, clientCapabilities absent.
    const got = try h.sendMessage(testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}
    );
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "-32602") != null);
    try testing.expect(std.mem.indexOf(u8, got, "clientCapabilities") != null);
}

test "server: a modern result carries resultType and a serverInfo echo" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const line = try modernRequest(testing.allocator, "1", "tools/list", "", protocol.MODERN_VERSION);
    defer testing.allocator.free(line);
    const got = try h.sendMessage(testing.allocator, line);
    defer testing.allocator.free(got);

    var doc = try json.parse(testing.allocator, std.mem.trim(u8, got, "\r\n"));
    defer doc.deinit();
    const root = doc.root.asObject().?;
    const result = json.get(.{ .object = root }, "result").?;
    try testing.expectEqualStrings("complete", (json.get(result, "resultType") orelse unreachable).asString().?);
    try testing.expect((json.get(result, "tools") orelse unreachable).asArray().?.len > 0);
    const meta = (json.get(result, "_meta") orelse unreachable).asObject().?;
    try testing.expect(json.get(.{ .object = meta }, protocol.META_SERVER_INFO) != null);
}

test "server: a modern tool call result is wrapped, and its content block survives" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const line = try modernRequest(
        testing.allocator,
        "1",
        "tools/call",
        "\"name\":\"memory_stats\",\"arguments\":{},",
        protocol.MODERN_VERSION,
    );
    defer testing.allocator.free(line);
    const got = try h.sendMessage(testing.allocator, line);
    defer testing.allocator.free(got);

    var doc = try json.parse(testing.allocator, std.mem.trim(u8, got, "\r\n"));
    defer doc.deinit();
    const root = doc.root.asObject().?;
    const result = json.get(.{ .object = root }, "result").?;
    try testing.expectEqualStrings("complete", (json.get(result, "resultType") orelse unreachable).asString().?);
    // The content block must come through the envelope re-open intact.
    // This is the splice in `wrapModernResult`, and it is exactly where a
    // mistake would silently eat the tool's actual payload.
    try testing.expect((json.get(result, "content") orelse unreachable).asArray().?.len == 1);
}

test "server: a legacy result carries neither resultType nor a serverInfo echo" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const got = try h.sendMessage(testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
    );
    defer testing.allocator.free(got);

    // An unmigrated client validates against the older schema. Adding
    // fields purely for the modern era's benefit would change bytes it
    // never asked for.
    try testing.expect(std.mem.indexOf(u8, got, "resultType") == null);
    try testing.expect(std.mem.indexOf(u8, got, protocol.META_SERVER_INFO) == null);
}

test "server: initialize still works and still answers with a legacy version" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const got = try h.sendMessage(testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}
    );
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "2025-06-18") != null);
    try testing.expect(std.mem.indexOf(u8, got, "resultType") == null);
}

test "server: initialize carrying modern _meta is still served as legacy" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    // `initialize` does not exist in the stateless core, so a request for
    // it is a legacy request even when it also carries modern metadata.
    // Otherwise the handshake answer would be wrapped in a resultType that
    // no handshake-era client expects.
    const got = try h.sendMessage(testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"probe","version":"1"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
    );
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "2025-11-25") != null);
    try testing.expect(std.mem.indexOf(u8, got, "resultType") == null);
}

test "server: one batch may mix eras, and each response is shaped for its own" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    const modern = try modernRequest(testing.allocator, "2", "tools/list", "", protocol.MODERN_VERSION);
    defer testing.allocator.free(modern);
    const probe = try modernRequest(testing.allocator, "3", "server/discover", "", protocol.MODERN_VERSION);
    defer testing.allocator.free(probe);

    // A legacy request with no `_meta` at all, spliced in verbatim.
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(testing.allocator);
    try batch.append(testing.allocator, '[');
    // Appended, not written as a literal: an empty `"params":{}` inside a
    // format string is read as an interpolation delimiter pair, and the
    // element boundary after it silently moves.
    try batch.appendSlice(testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}",
    );
    try batch.append(testing.allocator, ',');
    try batch.appendSlice(testing.allocator, modern);
    try batch.append(testing.allocator, ',');
    try batch.appendSlice(testing.allocator, probe);
    try batch.append(testing.allocator, ']');

    const got = try h.sendMessage(testing.allocator, batch.items);
    defer testing.allocator.free(got);

    var doc = try json.parse(testing.allocator, std.mem.trim(u8, got, "\r\n"));
    defer doc.deinit();
    const arr = doc.root.asArray().?;
    try testing.expectEqual(@as(usize, 3), arr.len);

    // Statelessness made observable: one process, one batch, three
    // requests spanning two protocol eras, each answered on its own terms.
    const r0 = json.get(.{ .object = arr[0].asObject().? }, "result") orelse unreachable;
    try testing.expect(json.get(r0, "resultType") == null);

    const r1 = json.get(.{ .object = arr[1].asObject().? }, "result") orelse unreachable;
    try testing.expectEqualStrings("complete", (json.get(r1, "resultType") orelse unreachable).asString().?);

    const r2 = json.get(.{ .object = arr[2].asObject().? }, "result") orelse unreachable;
    try testing.expect((json.get(r2, "supportedVersions") orelse unreachable).asArray().?.len > 0);
}

test "server: every tool's result survives the modern envelope" {
    // `wrapModernResult` re-opens the outermost braces of whatever a
    // builder produced. A builder emitting anything but a bare object
    // makes that splice produce a result the spec calls invalid, and only
    // running every tool through it finds that.
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    inline for (.{ "memory_stats", "goal_list", "memory_forget" }) |name| {
        const line = try modernRequest(
            testing.allocator,
            "1",
            "tools/call",
            "\"name\":\"" ++ name ++ "\",\"arguments\":{},",
            protocol.MODERN_VERSION,
        );
        defer testing.allocator.free(line);

        const got = try h.sendMessage(testing.allocator, line);
        defer testing.allocator.free(got);

        var doc = try json.parse(testing.allocator, std.mem.trim(u8, got, "\r\n"));
        defer doc.deinit();
        const root = doc.root.asObject().?;
        const result = json.get(.{ .object = root }, "result") orelse {
            // A tool refusing a call is `isError: true` *inside* a result,
            // not a protocol error, so having neither here is the defect.
            std.debug.print("tool {s}: neither result nor error: {s}\n", .{ name, got });
            return error.MissingToolResult;
        };
        try testing.expectEqualStrings("complete", (json.get(result, "resultType") orelse unreachable).asString().?);
        try testing.expect((json.get(result, "content") orelse unreachable).asArray().?.len == 1);
    }
}

test "server: a rejected request is answered under its own id, not null" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    // JSON-RPC: a response carries the same id as its request, and `null`
    // only when the id could not be detected. A message with a readable id
    // and a broken method is not that — and inside a batch, nulling every
    // bad element makes them indistinguishable from each other and from an
    // error that killed the whole batch.
    const got = try h.sendMessage(testing.allocator,
        \\[{"jsonrpc":"2.0","id":60,"method":"ping","params":{}},{"jsonrpc":"2.0","id":61},{"jsonrpc":"2.0","id":62,"method":"ping","params":{}}]
    );
    defer testing.allocator.free(got);

    var doc = try json.parse(testing.allocator, std.mem.trim(u8, got, "\r\n"));
    defer doc.deinit();
    const arr = doc.root.asArray().?;
    try testing.expectEqual(@as(usize, 3), arr.len);

    // The only element carrying an error must be the one sent as id 61,
    // and it must answer to that id. Ids are echoed as *source text*, so
    // a numeric id comes back as a number, not a string — reading it with
    // `asString` is how this test first failed on correct output.
    for (arr) |v| {
        const o = v.asObject().?;
        const id_value = json.get(.{ .object = o }, "id") orelse unreachable;
        const id_num: f64 = switch (id_value) {
            .number => |n| n,
            else => -1,
        };
        if (json.get(.{ .object = o }, "error") != null) {
            try testing.expectEqual(@as(f64, 61), id_num);
            const code = json.get(json.get(.{ .object = o }, "error") orelse unreachable, "code") orelse unreachable;
            try testing.expectEqual(@as(f64, -32600), switch (code) {
                .number => |n| n,
                else => 0,
            });
        } else {
            // Its neighbours are untouched: both are still answered, and
            // neither is the error. (Two neighbours, not one — 60 and 62.)
            try testing.expect(id_num == 60 or id_num == 62);
            try testing.expect(json.get(.{ .object = o }, "result") != null);
        }
    }
}

test "server: a message too broken to have an id is answered with id null" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit(testing.allocator);

    // The other half of the rule: when the id genuinely cannot be read,
    // null is required, not merely permitted.
    const got = try h.sendMessage(testing.allocator, "{ this is not json");
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, "\"id\":null") != null);
    try testing.expect(std.mem.indexOf(u8, got, "-32700") != null);
}

// =============================================================================
// Termination signals. `mem3 mcp` is a blocking stdio loop; SIGINT/SIGTERM
// must end it cleanly even while the client keeps the pipe open and idle.
// =============================================================================

test "server: serveStdio returns on SIGTERM while the client holds the pipe open" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, true);
    defer h.deinit(alloc);

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    signal.reset();
    try signal.installTermHandlers();
    defer {
        signal.restoreDefaultHandlers();
        signal.reset();
    }
    h.server.watch_signals = true;

    var done: std.atomic.Value(bool) = .init(false);
    const Runner = struct {
        fn run(s: *Server, fd: c_int, d: *std.atomic.Value(bool)) void {
            s.serveStdio(fd) catch {};
            d.store(true, .release);
        }
    };
    const t = try std.Thread.spawn(.{}, Runner.run, .{ h.server, fds[0], &done });

    // A request goes through, then the line goes quiet. The loop is now
    // parked waiting for input that is never coming.
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n";
    try std.testing.expectEqual(@as(isize, @intCast(req.len)), std.c.write(fds[1], req.ptr, req.len));
    const clock = @import("../platform/clock.zig");
    var spins: usize = 0;
    while (spins < 500) : (spins += 1) {
        const got = try h.output(alloc);
        defer alloc.free(got);
        if (got.len > 0) break;
        clock.sleepMs(10);
    }
    clock.sleepMs(150);
    try std.testing.expect(!done.load(.acquire));

    try std.testing.expectEqual(@as(c_int, 0), std.c.raise(.TERM));
    t.join();
    try std.testing.expect(done.load(.acquire));
}
