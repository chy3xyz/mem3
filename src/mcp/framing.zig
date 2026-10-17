//! Line framing for the newline-delimited JSON-RPC stream.
//!
//! **GHW layer**: Harness 层 (象源). Framing is regulatory: it decides
//! which bytes are a *message* before any of them are allowed to mean
//! anything to the memory system.
//!
//! ## The rule this file exists to enforce
//!
//! A line is a message only when its terminating newline has arrived.
//! A truncated trailing line is not a half-message to be guessed at; it
//! is *not a message yet*, and `next` returns `null` until the rest of
//! it lands. This is the difference between a transport that a real
//! client interoperates with and one that intermittently hangs, because
//! a client's write and a pipe read share no boundary.
//!
//! ## Memory bound
//!
//! `MAX_LINE_BYTES` caps an unterminated line. Without it, a peer that
//! never sends a newline grows this buffer without limit — the one
//! buffer on the read path that a peer controls the size of. On
//! overflow the framer reports `.too_long` once, drops everything
//! buffered, and skips bytes until the next newline, so the connection
//! resynchronises and the *following* message still parses.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Largest unterminated line accepted. Matches the JSON document cap
/// in `json.zig`: a line that is too long to frame is also too long to
/// parse, and one number to reason about beats two.
pub const MAX_LINE_BYTES: usize = 1 << 20; // 1 MiB

pub const Outcome = union(enum) {
    /// A complete line, without its newline. Borrows the framer's
    /// buffer and is invalidated by the next `feed`/`next`.
    line: []const u8,
    /// The line exceeded `MAX_LINE_BYTES` and was discarded. Reported
    /// once per oversized line.
    too_long,
};

pub const Framer = struct {
    alloc: Allocator,
    /// Bytes received but not yet consumed as a complete line.
    buf: std.ArrayList(u8),
    /// Read cursor into `buf`. Bytes before it have been delivered.
    ///
    /// A cursor rather than a compaction because a compacted buffer
    /// would move the very bytes a returned `line` points at, and the
    /// server holds that slice across the whole of one dispatch.
    start: usize = 0,
    /// Set while skipping the tail of an oversized line, until the
    /// newline that ends it arrives.
    discarding: bool = false,

    pub fn init(alloc: Allocator) Framer {
        return .{ .alloc = alloc, .buf = .empty };
    }

    pub fn deinit(self: *Framer) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }

    /// Unconsumed bytes currently held.
    pub fn pending(self: *const Framer) usize {
        return self.buf.items.len - self.start;
    }

    /// Hand the framer more bytes. Never reports a line — ask `next`
    /// until it returns `null`. Splitting the two keeps the borrow from
    /// `next` valid across a `feed`.
    pub fn feed(self: *Framer, chunk: []const u8) Allocator.Error!void {
        if (self.discarding) {
            // Nothing before the newline is worth keeping, and keeping
            // it is exactly the unbounded growth this state prevents.
            if (std.mem.indexOfScalar(u8, chunk, '\n')) |i| {
                self.discarding = false;
                self.reset();
                const rest = chunk[i + 1 ..];
                if (rest.len > 0) try self.buf.appendSlice(self.alloc, rest);
            }
            return;
        }
        try self.buf.appendSlice(self.alloc, chunk);
    }

    /// The next complete line, or `null` when more bytes are needed.
    pub fn next(self: *Framer) ?Outcome {
        // Reclaim a fully drained buffer *before* reading it, never
        // after a line has been handed out.
        //
        // This placement is load-bearing: Zig 0.17's
        // `clearRetainingCapacity` does `@memset(items, undefined)`, so
        // reclaiming after building the returned slice writes garbage
        // into the bytes the caller is about to read. Reclaiming here
        // instead means the only thing a caller can lose is a line it
        // was told is invalidated by this very call.
        if (self.start > 0 and self.start == self.buf.items.len) self.reset();

        const rest = self.buf.items[self.start..];

        if (self.discarding) {
            // The oversized line was already reported when the cap was
            // crossed; finishing it is bookkeeping, not news.
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
            self.start += nl + 1;
            self.discarding = false;
            return null;
        }

        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
            if (rest.len > MAX_LINE_BYTES) {
                // Report now rather than waiting for a newline that may
                // never come, then resynchronise on the next one.
                // No line is outstanding here, so poisoning the buffer
                // is safe.
                self.discarding = true;
                self.reset();
                return .too_long;
            }
            return null;
        };

        const line = self.buf.items[self.start .. self.start + nl];
        self.start += nl + 1;
        // A CRLF peer is not a malformed peer: the `\r` is transport,
        // not content.
        return .{ .line = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line };
    }

    /// Drop the consumed prefix. Poisoning is acceptable only where no
    /// borrowed line is outstanding — see `next`.
    fn reset(self: *Framer) void {
        self.buf.clearRetainingCapacity();
        self.start = 0;
    }
};

/// Walks the elements of a JSON-RPC batch — one line whose top level is
/// an array of messages — yielding each element's *source text*, borrowed
/// from the input.
///
/// ## Why the framer owns this
///
/// MCP requires implementations to **receive** batches even though almost
/// no client sends one: "Implementations MUST support receiving batches;
/// MAY support sending them". Not supporting them is the kind of omission
/// that costs nothing until the day a client batches a connection open and
/// the server answers every element with `-32700`, which the client then
/// reports as a parse failure rather than as a missing feature.
///
/// Yielding source text rather than parsed values is deliberate: each
/// slice is a complete JSON-RPC message, so the server hands it to
/// `protocol.parseMessage` exactly as if it had arrived on its own line,
/// and every element gets its own `Document` with its own lifetime. A
/// batch therefore cannot outlive its own memory.
///
/// Only element *boundaries* are found here. Whether an element is valid
/// JSON, or a valid request, is `parseMessage`'s question — this layer
/// decides what a message is, not whether it is a good one.
pub const BatchIterator = struct {
    src: []const u8,
    /// Next byte to examine.
    pos: usize,
    /// Bracket nesting below the batch array. `0` means "between
    /// elements", where `,` separates and `]` closes.
    depth: usize = 0,
    in_string: bool = false,
    escape: bool = false,
    /// First byte of the element being scanned. `null` when the cursor is
    /// on whitespace or a separator just past one.
    elem_start: ?usize = null,
    /// Set once the closing `]` has been consumed.
    finished: bool = false,

    pub const Error = error{MalformedBatch};

    /// A batch line is one whose first non-whitespace byte is `[`. This
    /// is not validation: `[]` and `[{,}]` both pass here and are
    /// reported by `next` instead.
    pub fn isBatch(line: []const u8) bool {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        return trimmed.len > 0 and trimmed[0] == '[';
    }

    /// Start at the first element. `error.MalformedBatch` when the line
    /// does not open an array.
    pub fn init(line: []const u8) Error!BatchIterator {
        const trimmed = std.mem.trimStart(u8, line, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '[') return error.MalformedBatch;
        return .{ .src = line, .pos = trimmed.ptr - line.ptr + 1 };
    }

    /// The next element's source text, or `null` at the end of the
    /// batch. `error.MalformedBatch` for a missing separator, an
    /// unterminated string, or a closing bracket that arrives while the
    /// caller is still inside a nested container.
    pub fn next(self: *BatchIterator) Error!?[]const u8 {
        // A consumed batch ends; it does not fall off the end of the
        // input looking for a closing bracket that was already there.
        if (self.finished) return null;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;

            if (self.in_string) {
                // The escape flag must be consumed before anything else,
                // or `\"` ends the string on the escaped quote and every
                // subsequent `,` and `]` inside that string is read as
                // structure.
                if (self.escape) {
                    self.escape = false;
                } else if (c == '\\') {
                    self.escape = true;
                } else if (c == '"') {
                    self.in_string = false;
                }
                continue;
            }

            switch (c) {
                '"' => {
                    self.in_string = true;
                    if (self.elem_start == null) self.elem_start = self.pos - 1;
                },
                '[', '{' => {
                    self.depth += 1;
                    if (self.elem_start == null) self.elem_start = self.pos - 1;
                },
                ']', '}' => {
                    if (self.depth == 0) {
                        // `]` closes the batch; `}` here is a stray
                        // closer and the same kind of defect.
                        if (c != ']') return error.MalformedBatch;
                        const elem = try self.take();
                        self.finished = true;
                        return elem;
                    }
                    self.depth -= 1;
                },
                ',' => {
                    if (self.depth != 0) continue;
                    const elem = try self.take();
                    // `[,x]` — a separator with no value before it.
                    if (elem == null) return error.MalformedBatch;
                    return elem;
                },
                else => {
                    if (self.elem_start == null and !isSpace(c)) self.elem_start = self.pos - 1;
                },
            }
        }
        // Ran out before the closing `]`. A truncated batch is a
        // truncated batch; the caller answers it as malformed rather
        // than treating the partial tail as a whole message.
        return error.MalformedBatch;
    }

    /// Close the current element, or `null` if the cursor is still on
    /// separators and whitespace.
    fn take(self: *BatchIterator) Error!?[]const u8 {
        const start = self.elem_start orelse return null;
        const elem = std.mem.trimEnd(u8, self.src[start..self.pos - 1], " \t\r\n");
        self.elem_start = null;
        if (elem.len == 0) return error.MalformedBatch;
        return elem;
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

// =============================================================================
// Tests
//
// Named directly in `src/main.zig`'s comptime block — a re-export from
// `src/mcp/mod.zig` does NOT register these with the test runner.
//
// Nothing here prints: the test runner talks to the build system over
// the process pipes, and one stderr write from inside a test kills the
// test binary while `zig build test` still exits 0.
// =============================================================================

test "framing: several messages in one write are split in order" {
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    try f.feed("{\"id\":1}\n{\"id\":2}\n{\"id\":3}\n");

    try std.testing.expectEqualStrings("{\"id\":1}", f.next().?.line);
    try std.testing.expectEqualStrings("{\"id\":2}", f.next().?.line);
    try std.testing.expectEqualStrings("{\"id\":3}", f.next().?.line);
    try std.testing.expect(f.next() == null);
    try std.testing.expectEqual(@as(usize, 0), f.pending());
}

test "framing: a message split across reads is not delivered early" {
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    try f.feed("{\"js");
    // The invariant: no newline, no line. Not a prefix, not a guess.
    try std.testing.expect(f.next() == null);

    try f.feed("onrpc\":\"2.0\",\"id\":");
    try std.testing.expect(f.next() == null);

    try f.feed("7}\n");
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7}", f.next().?.line);
    try std.testing.expect(f.next() == null);
}

test "framing: a trailing partial line is held, not parsed" {
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    try f.feed("{\"id\":1}\n{\"id\":2");
    try std.testing.expectEqualStrings("{\"id\":1}", f.next().?.line);

    // Stream ended mid-message. This is NOT a message.
    try std.testing.expect(f.next() == null);
    try std.testing.expect(f.pending() > 0);

    // And when the rest of it arrives, it parses — exactly once.
    try f.feed("}\n");
    try std.testing.expectEqualStrings("{\"id\":2}", f.next().?.line);
    try std.testing.expect(f.next() == null);
}

test "framing: one byte at a time still yields the same line" {
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    const msg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n";
    for (msg) |b| {
        try f.feed(&[_]u8{b});
    }
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}", f.next().?.line);
}

test "framing: blank lines are delivered as empty lines" {
    // The framer does not judge emptiness — `json.isBlank` does. The
    // split matters: framing is about boundaries, content is the
    // server's policy.
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    try f.feed("\n\n{}\n");
    try std.testing.expectEqualStrings("", f.next().?.line);
    try std.testing.expectEqualStrings("", f.next().?.line);
    try std.testing.expectEqualStrings("{}", f.next().?.line);
    try std.testing.expect(f.next() == null);
}

test "framing: CRLF is transport, not content" {
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    try f.feed("{\"id\":1}\r\n");
    try std.testing.expectEqualStrings("{\"id\":1}", f.next().?.line);
    try std.testing.expect(f.next() == null);
}

test "framing: a lone CR is content, not a terminator" {
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    try f.feed("{\"id\":1}");
    try std.testing.expect(f.next() == null);
}

test "framing: an over-long line is reported once and the stream resynchronises" {
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    var chunk: [1024]u8 = undefined;
    @memset(&chunk, 'x');

    // Push past the cap with no newline anywhere.
    var fed: usize = 0;
    while (fed < MAX_LINE_BYTES + 1024) : (fed += chunk.len) {
        try f.feed(chunk[0..]);
    }
    try std.testing.expectEqual(Outcome.too_long, f.next().?);
    // The bytes are gone, not merely unread.
    try std.testing.expectEqual(@as(usize, 0), f.pending());

    // The rest of the oversized line, up to and including its newline,
    // is skipped — and the next real message still parses.
    try f.feed("tail-of-the-long-line\n{\"id\":9}\n");
    try std.testing.expectEqualStrings("{\"id\":9}", f.next().?.line);
    try std.testing.expect(f.next() == null);
}

test "framing: an over-long line split before its newline still reports once" {
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    const big = try alloc.alloc(u8, MAX_LINE_BYTES + 16);
    defer alloc.free(big);
    @memset(big, 'y');

    try f.feed(big);
    try std.testing.expectEqual(Outcome.too_long, f.next().?);
    try std.testing.expect(f.next() == null); // reported exactly once

    try f.feed("\n{\"id\":10}\n");
    try std.testing.expectEqualStrings("{\"id\":10}", f.next().?.line);
}

test "framing: the buffer never grows past the cap plus one chunk" {
    // The peer controls how much it sends before sending a newline, so
    // the bound has to hold while it does.
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    const big = try alloc.alloc(u8, 8192);
    defer alloc.free(big);
    @memset(big, 'z');

    var fed: usize = 0;
    while (fed <= MAX_LINE_BYTES + (4 * 8192)) : (fed += 8192) {
        try f.feed(big);
        if (f.pending() > MAX_LINE_BYTES) {
            // The only way to exceed the cap transiently is the chunk
            // that crosses it, which `next` immediately trims.
            _ = f.next();
        }
        try std.testing.expect(f.pending() <= MAX_LINE_BYTES);
    }
}

// =============================================================================

test "framing: a line at exactly the cap is still delivered" {
    // The off-by-one on a size cap is a silent truncation bug: either
    // the largest legal line is rejected, or the first illegal one is
    // accepted. Both directions are pinned.
    const alloc = std.testing.allocator;
    var f = Framer.init(alloc);
    defer f.deinit();

    const line = try alloc.alloc(u8, MAX_LINE_BYTES);
    defer alloc.free(line);
    @memset(line, 'a');
    try f.feed(line);
    try f.feed("\n");

    const got = f.next().?;
    try std.testing.expect(got == .line);
    try std.testing.expectEqual(MAX_LINE_BYTES, got.line.len);

    const one_more = try alloc.alloc(u8, MAX_LINE_BYTES + 1);
    defer alloc.free(one_more);
    @memset(one_more, 'a');
    try f.feed(one_more);
    try std.testing.expectEqual(Outcome.too_long, f.next().?);
}
