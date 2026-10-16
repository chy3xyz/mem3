//! Minimal JSON parser for the MCP server's request side.
//!
//! **GHW layer**: Harness 层 (象源). Parsing a protocol envelope is
//! regulatory work: it turns an external byte stream into the shape the
//! memory system is allowed to act on. It touches no memory cell.
//!
//! ## Why this exists
//!
//! `src/utils/jsonl.zig` has writing helpers only — `writeJsonString`
//! and `writeJsonKey`. It is *not* a parser, and JSON-RPC needs to read
//! what a client sent. Constitution IV (零依赖) forbids pulling an MCP
//! or JSON library in, so the reader is hand-written here.
//!
//! ## Design
//!
//! - **Allocation is explicit and tracked at allocation time.** Every
//!   byte the parser owns is pushed onto `Document.blocks` in the same
//!   statement that allocates it, so one `Document.deinit()` releases the
//!   whole tree and the error path frees exactly what the success path
//!   frees. There is no partial tree to unwind.
//! - **Strings without escapes are borrowed, not copied.** A plain
//!   `Value.string` points into the source slice; only a string that
//!   actually contains an escape gets a heap block. The caller must keep
//!   the input alive while reading `Value`s out of the `Document` — that
//!   is the documented contract, and it is what keeps the common case at
//!   zero copies (Constitution V).
//! - **Two size caps.** `MAX_BYTES` bounds the input; `MAX_NODES` bounds
//!   the number of values, because `[,,,,,,,]` costs one byte of input
//!   and ~24 bytes of output. A byte cap alone is a trivially inflatable
//!   allocation.
//!
//! ## The unknown-escape rule
//!
//! `\q` is neither an error nor dropped: it is preserved as the two
//! literal characters `\` and `q`. `src/utils/logger.zig` was bitten by
//! the other half of this bug — an unrecognised escape was swallowed, so
//! log lines silently lost content. Dropping is strictly worse than
//! keeping: keeping is visible, dropping is not.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Largest single JSON document accepted, in bytes.
pub const MAX_BYTES: usize = 1 << 20; // 1 MiB

/// Largest number of values (array items, object members and scalars)
/// in one document.
pub const MAX_NODES: usize = 1 << 16;

/// Maximum container nesting. A recursive-descent parser without this
/// is a stack-overflow crash on hostile input, and the server's promise
/// is that bad input produces a JSON-RPC error, never a crash.
pub const MAX_DEPTH: usize = 64;

pub const ParseError = error{
    /// Input ended in the middle of a value.
    UnexpectedEof,
    /// A byte appeared that cannot start or continue a value.
    UnexpectedToken,
    /// Not a well-formed JSON number (`+1`, `01`, `.5`, `nan`, …).
    InvalidNumber,
    /// A `\uXXXX` escape that is not four hex digits, or a lone
    /// surrogate.
    InvalidEscape,
    /// A well-formed value followed by junk.
    TrailingGarbage,
    /// Deeper than `MAX_DEPTH`, wider than `MAX_NODES`, or longer than
    /// `MAX_BYTES`.
    LimitExceeded,
    OutOfMemory,
};

pub const Value = union(enum) {
    null,
    bool: bool,
    number: f64,
    /// Borrowed from the source when the literal contained no escapes.
    string: []const u8,
    array: []const Value,
    object: []const Member,

    /// Typed accessors. Every one returns `null` on a type mismatch
    /// rather than asserting: the caller decides whether a wrong type is
    /// an error (`tools/call` params) or simply absent.
    pub fn asObject(self: Value) ?[]const Member {
        return switch (self) {
            .object => |m| m,
            else => null,
        };
    }

    pub fn asArray(self: Value) ?[]const Value {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .bool => |b| b,
            else => null,
        };
    }

    pub fn asNumber(self: Value) ?f64 {
        return switch (self) {
            .number => |n| n,
            else => null,
        };
    }
};

pub const Member = struct {
    key: []const u8,
    value: Value,
};

/// One owned allocation, tagged by the type it must be freed as.
/// `Allocator.free` is type-checked, so a flat `[]u8` list of borrowed
/// blocks would either need `alignCast` laundering or would free the
/// wrong shape.
pub const Block = union(enum) {
    bytes: []u8,
    values: []Value,
    members: []Member,
};

/// A borrowed slice of the source text, captured for one top-level key.
pub const Span = struct {
    key: []const u8,
    /// Exactly the bytes the value occupied in the source, quotes
    /// included. Borrowed from the input like every other string here.
    text: []const u8,
};

/// A parsed document plus every allocation its values point at.
pub const Document = struct {
    alloc: Allocator,
    root: Value,
    /// One entry per owned allocation. Populated at allocation time,
    /// never at ownership-transfer time — that is what makes the error
    /// paths as leak-free as the success path.
    blocks: std.ArrayList(Block),
    /// Raw text of the requested top-level keys, borrowed from `src`.
    spans: std.ArrayList(Span),
    /// Which keys `parseWith` was asked to keep. Borrowed; not owned.
    capture_keys: []const []const u8 = &.{},

    pub fn deinit(self: *Document) void {
        for (self.blocks.items) |b| switch (b) {
            .bytes => |s| self.alloc.free(s),
            .values => |s| self.alloc.free(s),
            .members => |s| self.alloc.free(s),
        };
        self.blocks.deinit(self.alloc);
        self.spans.deinit(self.alloc);
        self.* = undefined;
    }

    /// The exact source text of a captured key, or `null`.
    pub fn span(self: *const Document, key: []const u8) ?[]const u8 {
        for (self.spans.items) |s| {
            if (std.mem.eql(u8, s.key, key)) return s.text;
        }
        return null;
    }
};

/// Look up `key` in an object value; `null` for anything else (including
/// a missing key or a non-object).
pub fn get(v: Value, key: []const u8) ?Value {
    const members = v.asObject() orelse return null;
    for (members) |m| {
        if (std.mem.eql(u8, m.key, key)) return m.value;
    }
    return null;
}

/// Parse one complete JSON document. `src` must outlive the returned
/// `Document` for the duration of any borrowed `Value.string`.
pub fn parse(alloc: Allocator, src: []const u8) ParseError!Document {
    return parseWith(alloc, src, &.{});
}

/// Parse, additionally keeping the exact source text of the named
/// top-level keys (`Document.span`).
///
/// `capture_keys` exists for JSON-RPC's `id`, which must be echoed back
/// byte-for-byte. Round-tripping it through `f64` would turn `1e2` into
/// `100` and quietly corrupt any id a client cared about, and there is
/// no way to reconstruct the original spelling from the parsed value.
/// Borrowed from the caller; must outlive the `Document`.
pub fn parseWith(
    alloc: Allocator,
    src: []const u8,
    capture_keys: []const []const u8,
) ParseError!Document {
    // Checked before the parser is even constructed: an over-cap
    // document must cost no allocation, not an allocation per reject.
    if (src.len > MAX_BYTES) return error.LimitExceeded;

    var doc: Document = .{
        .alloc = alloc,
        .root = .null,
        .blocks = .empty,
        .spans = .empty,
        .capture_keys = capture_keys,
    };
    errdefer doc.deinit();

    var p: Parser = .{ .src = src, .doc = &doc };

    p.skipWs();
    const root = try p.value(0);
    p.skipWs();
    if (p.i != p.src.len) return error.TrailingGarbage;

    doc.root = root;
    return doc;
}

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    nodes: usize = 0,
    doc: *Document,

    fn peek(self: *Parser) ?u8 {
        if (self.i >= self.src.len) return null;
        return self.src[self.i];
    }

    fn skipWs(self: *Parser) void {
        while (self.i < self.src.len) : (self.i += 1) {
            switch (self.src[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn expect(self: *Parser, c: u8) ParseError!void {
        const got = self.peek() orelse return error.UnexpectedEof;
        if (got != c) return error.UnexpectedToken;
        self.i += 1;
    }

    fn countNode(self: *Parser) ParseError!void {
        self.nodes += 1;
        if (self.nodes > MAX_NODES) return error.LimitExceeded;
    }

    /// Hand a container's freshly built slice to the Document.
    ///
    /// `list` is emptied by `toOwnedSlice`, so the caller's `defer
    /// list.deinit()` stays correct, and the `errdefer free` covers the
    /// one window where the buffer is owned but not yet tracked.
    fn ownSlice(self: *Parser, comptime T: type, list: *std.ArrayList(T)) ParseError![]T {
        const owned = try list.toOwnedSlice(self.doc.alloc);
        errdefer self.doc.alloc.free(owned);
        const block: Block = if (T == Value) .{ .values = owned } else .{ .members = owned };
        try self.doc.blocks.append(self.doc.alloc, block);
        return owned;
    }

    fn value(self: *Parser, depth: usize) ParseError!Value {
        try self.countNode();
        const c = self.peek() orelse return error.UnexpectedEof;
        return switch (c) {
            '{' => try self.object(depth),
            '[' => try self.array(depth),
            '"' => .{ .string = try self.string() },
            't' => try self.literal("true", .{ .bool = true }),
            'f' => try self.literal("false", .{ .bool = false }),
            'n' => try self.literal("null", .null),
            '-', '0'...'9' => .{ .number = try self.number() },
            else => error.UnexpectedToken,
        };
    }

    fn literal(self: *Parser, word: []const u8, v: Value) ParseError!Value {
        if (self.src.len - self.i < word.len) return error.UnexpectedEof;
        if (!std.mem.eql(u8, self.src[self.i .. self.i + word.len], word)) {
            return error.UnexpectedToken;
        }
        self.i += word.len;
        return v;
    }

    fn object(self: *Parser, depth: usize) ParseError!Value {
        if (depth >= MAX_DEPTH) return error.LimitExceeded;
        try self.expect('{');
        var members: std.ArrayList(Member) = .empty;
        defer members.deinit(self.doc.alloc);

        self.skipWs();
        if (self.peek() == @as(?u8, '}')) {
            self.i += 1;
            return .{ .object = try self.ownSlice(Member, &members) };
        }

        while (true) {
            self.skipWs();
            const key = try self.string();
            self.skipWs();
            try self.expect(':');
            self.skipWs();
            const v_start = self.i;
            const v = try self.value(depth + 1);
            // Top level only: an `id` nested inside `params` is not the
            // message id, and capturing it would be worse than useless.
            if (depth == 0) try self.captureIfRequested(key, v_start, self.i);
            try members.append(self.doc.alloc, .{ .key = key, .value = v });
            self.skipWs();
            const sep = self.peek() orelse return error.UnexpectedEof;
            if (sep == ',') {
                self.i += 1;
                continue;
            }
            if (sep == '}') {
                self.i += 1;
                return .{ .object = try self.ownSlice(Member, &members) };
            }
            return error.UnexpectedToken;
        }
    }

    fn array(self: *Parser, depth: usize) ParseError!Value {
        if (depth >= MAX_DEPTH) return error.LimitExceeded;
        try self.expect('[');
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(self.doc.alloc);

        self.skipWs();
        if (self.peek() == @as(?u8, ']')) {
            self.i += 1;
            return .{ .array = try self.ownSlice(Value, &items) };
        }

        while (true) {
            self.skipWs();
            try items.append(self.doc.alloc, try self.value(depth + 1));
            self.skipWs();
            const sep = self.peek() orelse return error.UnexpectedEof;
            if (sep == ',') {
                self.i += 1;
                continue;
            }
            if (sep == ']') {
                self.i += 1;
                return .{ .array = try self.ownSlice(Value, &items) };
            }
            return error.UnexpectedToken;
        }
    }

    /// Scan a JSON string and return it, borrowed when possible.
    ///
    /// First pass only looks for the closing quote, so it can decide
    /// whether the string needs a heap block at all; every escape check
    /// happens in `buildString`. The one rule that *must* be enforced
    /// here is that a raw control byte is illegal, because a literal
    /// newline inside a string is how a peer would try to smuggle a
    /// second message past the line framer.
    fn string(self: *Parser) ParseError![]const u8 {
        const open = self.i;
        try self.expect('"');
        const start = self.i;

        var has_escape = false;
        while (true) {
            if (self.i >= self.src.len) return error.UnexpectedEof;
            const c = self.src[self.i];
            if (c == '"') {
                const raw = self.src[start..self.i];
                self.i += 1;
                if (!has_escape) return raw;
                self.i = open;
                return self.buildString();
            }
            if (c < 0x20) return error.UnexpectedToken;
            if (c == '\\') has_escape = true;
            self.i += 1;
        }
    }

    /// Second pass: materialise the decoded string from the opening
    /// quote at `self.i`.
    fn buildString(self: *Parser) ParseError![]const u8 {
        std.debug.assert(self.i < self.src.len and self.src[self.i] == '"');
        self.i += 1;

        var out: std.ArrayList(u8) = .empty;
        // The only clean exit is the tail below, so one errdefer covers
        // every rejection inside the loop.
        errdefer out.deinit(self.doc.alloc);

        while (true) {
            if (self.i >= self.src.len) return error.UnexpectedEof;
            const c = self.src[self.i];
            if (c == '"') {
                self.i += 1;
                break;
            }
            if (c < 0x20) return error.UnexpectedToken;
            if (c != '\\') {
                try out.append(self.doc.alloc, c);
                self.i += 1;
                continue;
            }

            self.i += 1;
            if (self.i >= self.src.len) return error.UnexpectedEof;
            const e = self.src[self.i];
            self.i += 1;
            switch (e) {
                '"' => try out.append(self.doc.alloc, '"'),
                '\\' => try out.append(self.doc.alloc, '\\'),
                '/' => try out.append(self.doc.alloc, '/'),
                'n' => try out.append(self.doc.alloc, '\n'),
                't' => try out.append(self.doc.alloc, '\t'),
                'r' => try out.append(self.doc.alloc, '\r'),
                'b' => try out.append(self.doc.alloc, 0x08),
                'f' => try out.append(self.doc.alloc, 0x0c),
                'u' => {
                    const hi = try self.hex4();
                    var cp = hi;
                    if (hi >= 0xD800 and hi <= 0xDBFF) {
                        // High surrogate: a low one must follow.
                        if (self.i + 1 < self.src.len and
                            self.src[self.i] == '\\' and self.src[self.i + 1] == 'u')
                        {
                            self.i += 2;
                            const lo = try self.hex4();
                            if (lo < 0xDC00 or lo > 0xDFFF) return error.InvalidEscape;
                            cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                        } else return error.InvalidEscape;
                    } else if (hi >= 0xDC00 and hi <= 0xDFFF) {
                        // Unpaired low surrogate: no valid UTF-8 for it.
                        return error.InvalidEscape;
                    }
                    try appendUtf8(self.doc.alloc, &out, cp);
                },
                else => {
                    // Unknown escape: keep both literal characters.
                    // Dropping them is what `utils/logger.zig` did.
                    try out.append(self.doc.alloc, '\\');
                    try out.append(self.doc.alloc, e);
                },
            }
        }

        const owned = try out.toOwnedSlice(self.doc.alloc);
        errdefer self.doc.alloc.free(owned);
        try self.doc.blocks.append(self.doc.alloc, .{ .bytes = owned });
        return owned;
    }

    /// Record the source text of a top-level value if its key was asked
    /// for. The slice borrows `src`, like every other string the parser
    /// hands back.
    fn captureIfRequested(self: *Parser, key: []const u8, start: usize, end: usize) ParseError!void {
        for (self.doc.capture_keys) |want| {
            if (std.mem.eql(u8, key, want)) {
                try self.doc.spans.append(self.doc.alloc, .{ .key = key, .text = self.src[start..end] });
                return;
            }
        }
    }

    fn hex4(self: *Parser) ParseError!u32 {
        if (self.i + 4 > self.src.len) return error.InvalidEscape;
        var v: u32 = 0;
        for (self.src[self.i .. self.i + 4]) |h| {
            if (!isHex(h)) return error.InvalidEscape;
            v = v * 16 + hexVal(h);
        }
        self.i += 4;
        return v;
    }

    /// JSON number grammar, checked by hand before `parseFloat`.
    ///
    /// Hand-checking is not decoration: `parseFloat` accepts `inf`, `nan`
    /// and `1e999`, none of which are JSON, and an infinity written back
    /// out is the literal text `inf` — a response no client can parse.
    fn number(self: *Parser) ParseError!f64 {
        const start = self.i;
        if (self.peek() == @as(?u8, '-')) self.i += 1;

        // int part: a lone `0`, or `[1-9][0-9]*`
        const int_start = self.i;
        while (self.i < self.src.len and isDigit(self.src[self.i])) self.i += 1;
        if (self.i == int_start) return error.InvalidNumber;
        if (self.i - int_start > 1 and self.src[int_start] == '0') return error.InvalidNumber;

        if (self.peek() == @as(?u8, '.')) {
            self.i += 1;
            const frac_start = self.i;
            while (self.i < self.src.len and isDigit(self.src[self.i])) self.i += 1;
            if (self.i == frac_start) return error.InvalidNumber;
        }

        if (self.peek()) |c| {
            if (c == 'e' or c == 'E') {
                self.i += 1;
                if (self.peek()) |sign| {
                    if (sign == '+' or sign == '-') self.i += 1;
                }
                const exp_start = self.i;
                while (self.i < self.src.len and isDigit(self.src[self.i])) self.i += 1;
                if (self.i == exp_start) return error.InvalidNumber;
            }
        }

        const n = std.fmt.parseFloat(f64, self.src[start..self.i]) catch return error.InvalidNumber;
        // `parseFloat` happily returns `inf` for 1e999 rather than an
        // error, and an infinity written back out is the literal text
        // `inf` — not JSON. Anything non-finite is rejected here so the
        // value can never reach a response.
        if (!std.math.isFinite(n)) return error.InvalidNumber;
        return n;
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn hexVal(c: u8) u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => c - 'A' + 10,
    };
}

fn appendUtf8(alloc: Allocator, out: *std.ArrayList(u8), cp: u32) error{ OutOfMemory, InvalidEscape }!void {
    var buf: [4]u8 = undefined;
    // SAFETY of the cast, not an assumption: every caller has already
    // rejected surrogates, so `cp` is at most U+10FFFF, which fits u21.
    const n = std.unicode.utf8Encode(@as(u21, @intCast(cp)), &buf) catch return error.InvalidEscape;
    try out.appendSlice(alloc, buf[0..n]);
}

/// True when a line carries nothing but ASCII whitespace.
///
/// Blank lines are skipped rather than reported as parse errors: a
/// `\n`-terminated trailing line is normal in a stream that was closed
/// mid-write, and answering it with a JSON-RPC parse error would be
/// answering a message the client never sent. Anything with a
/// non-whitespace byte in it is a message and is parsed for real.
pub fn isBlank(line: []const u8) bool {
    for (line) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n' => {},
            else => return false,
        }
    }
    return true;
}

// =============================================================================
// Tests
//
// Collection caveat: `zig build test` registers `test` blocks only from
// files named **directly** in `src/main.zig`'s comptime block. Naming
// `src/mcp/mod.zig` is not enough — a re-export pulls a file into the
// build without registering its tests. Every new file here is named
// individually in `src/main.zig`.
//
// Test hygiene: nothing here prints. Zig's test runner speaks its
// protocol over the process pipes when invoked with `--listen=-`, and a
// single stderr write from inside a test desynchronises it, kills the
// test binary, and `zig build test` still exits 0.
// =============================================================================

test "json: parses the primitive types" {
    const alloc = std.testing.allocator;
    var d = try parse(alloc,
        \\{"s":"x","n":42,"f":-1.5e2,"t":true,"f2":false,"nil":null,"empty":""}
    );
    defer d.deinit();

    try std.testing.expectEqualStrings("x", get(d.root, "s").?.asString().?);
    try std.testing.expectEqual(@as(f64, 42), get(d.root, "n").?.asNumber().?);
    try std.testing.expectEqual(@as(f64, -150), get(d.root, "f").?.asNumber().?);
    try std.testing.expectEqual(true, get(d.root, "t").?.asBool().?);
    try std.testing.expectEqual(false, get(d.root, "f2").?.asBool().?);
    try std.testing.expect(get(d.root, "nil").? == .null);
    try std.testing.expectEqualStrings("", get(d.root, "empty").?.asString().?);
}

test "json: decodes escapes, including a surrogate pair" {
    const alloc = std.testing.allocator;
    var d = try parse(alloc,
        \\{"a":"q\"b","b":"c\\d","e":"l1\nl2","t":"x\ty","u":"物","p":"😀"}
    );
    defer d.deinit();

    try std.testing.expectEqualStrings("q\"b", get(d.root, "a").?.asString().?);
    try std.testing.expectEqualStrings("c\\d", get(d.root, "b").?.asString().?);
    try std.testing.expectEqualStrings("l1\nl2", get(d.root, "e").?.asString().?);
    try std.testing.expectEqualStrings("x\ty", get(d.root, "t").?.asString().?);
    // U+7269 is inside the BMP and must arrive as three UTF-8 bytes.
    try std.testing.expectEqualStrings("物", get(d.root, "u").?.asString().?);
    // U+1F600 is NOT in the BMP: it survives only as a surrogate pair.
    try std.testing.expectEqualStrings("😀", get(d.root, "p").?.asString().?);
}

test "json: an unknown escape keeps both literal characters" {
    // The `utils/logger.zig` bug, pinned here so it cannot come back:
    // `\q` used to vanish. It must come back as `\q`.
    const alloc = std.testing.allocator;
    var d = try parse(alloc,
        \\{"a":"c:\path","c":"\q"}
    );
    defer d.deinit();

    try std.testing.expectEqualStrings("c:\\path", get(d.root, "a").?.asString().?);
    try std.testing.expectEqualStrings("\\q", get(d.root, "c").?.asString().?);
}

test "json: a string with no escapes borrows the source" {
    // Zero-copy is the common case (Constitution V), and it is only
    // sound if the borrow really points into the input.
    const alloc = std.testing.allocator;
    const src =
        \\{"episode":"the tag was pushed"}
    ;
    var d = try parse(alloc, src);
    defer d.deinit();

    const got = get(d.root, "episode").?.asString().?;
    try std.testing.expectEqualStrings("the tag was pushed", got);
    const offset = @intFromPtr(got.ptr) - @intFromPtr(src.ptr);
    try std.testing.expect(offset > 0 and offset + got.len < src.len);
}

test "json: an escaped string does not borrow" {
    const alloc = std.testing.allocator;
    const src =
        \\{"episode":"a\nb"}
    ;
    var d = try parse(alloc, src);
    defer d.deinit();

    const got = get(d.root, "episode").?.asString().?;
    try std.testing.expectEqualStrings("a\nb", got);
    // Outside the source buffer, so it is a block the Document owns.
    const offset = @intFromPtr(got.ptr) - @intFromPtr(src.ptr);
    try std.testing.expect(offset >= src.len);
}

test "json: nested objects and arrays round-trip" {
    const alloc = std.testing.allocator;
    var d = try parse(alloc,
        \\{"params":{"name":"memory_add","arguments":{"facts":["a|b|c"],"topk":5,"nested":{"deep":[[1],[2,[3]]]}}}}
    );
    defer d.deinit();

    const params = get(d.root, "params").?;
    try std.testing.expectEqualStrings("memory_add", get(params, "name").?.asString().?);
    const arguments = get(params, "arguments").?;
    try std.testing.expectEqual(@as(usize, 1), get(arguments, "facts").?.asArray().?.len);
    try std.testing.expectEqual(@as(f64, 5), get(arguments, "topk").?.asNumber().?);
    const deep = get(arguments, "nested").?;
    const deep_arr = get(deep, "deep").?;
    const second = deep_arr.asArray().?[1].asArray().?;
    try std.testing.expectEqual(@as(f64, 3), second[1].asArray().?[0].asNumber().?);
}

test "json: empty containers are empty, not null" {
    const alloc = std.testing.allocator;
    var d = try parse(alloc,
        \\{"a":{},"b":[]}
    );
    defer d.deinit();

    try std.testing.expectEqual(@as(usize, 0), get(d.root, "a").?.asObject().?.len);
    try std.testing.expectEqual(@as(usize, 0), get(d.root, "b").?.asArray().?.len);
}

test "json: nesting at the depth limit parses, past it is rejected" {
    const alloc = std.testing.allocator;

    var at_limit: [MAX_DEPTH * 2]u8 = undefined;
    for (0..MAX_DEPTH) |k| at_limit[k] = '[';
    for (0..MAX_DEPTH) |k| at_limit[MAX_DEPTH + k] = ']';
    var d = try parse(alloc, &at_limit);
    defer d.deinit();
    try std.testing.expect(d.root == .array);

    const one_deeper = MAX_DEPTH + 1;
    var too_deep: [one_deeper * 2]u8 = undefined;
    for (0..one_deeper) |k| too_deep[k] = '[';
    for (0..one_deeper) |k| too_deep[one_deeper + k] = ']';
    try std.testing.expectError(error.LimitExceeded, parse(alloc, &too_deep));
}

test "json: rejects malformed input instead of accepting it" {
    const alloc = std.testing.allocator;

    const cases = [_][]const u8{
        "", // empty
        "   ", // whitespace only
        "{", // truncated object
        "{\"a\":", // truncated after the colon
        "{\"a\"", // truncated after the key
        "{\"a\":1", // truncated before the close
        "[1,2", // truncated array
        "\"unterminated", // unterminated string
        "{\"a\":1,}", // trailing comma
        "{,}", // missing key
        "{\"a\" 1}", // missing colon
        "tru", // truncated literal
        "nul1", // bad literal
        "{} {}", // two documents
        "{\"a\":1}trailing", // junk after a complete document
        "[1,2]]", // extra close
        "{'a':1}", // single quotes
        "{\"a\":01}", // leading zero
        "{\"a\":+1}", // leading plus
        "{\"a\":.5}", // no integer part
        "{\"a\":1.}", // no fraction digits
        "{\"a\":1e}", // no exponent digits
        "{\"a\":NaN}", // not JSON
        "{\"a\":Infinity}", // not JSON
        "{\"a\":1e999}", // overflows to infinity
        "{\"a\":\"\\u00zz\"}", // bad hex
        "{\"a\":\"\\u12\"}", // short escape
        "{\"a\":\"\\ud83d\"}", // lone high surrogate
        "{\"a\":\"\\ude00\"}", // lone low surrogate
        "{\"a\":\"\\ud83dA\"}", // high surrogate not followed by a low
        "{\"a\":\"raw\ncontrol\"}", // raw control byte inside a string
        "{\"a\":1}{\"b\":2}", // two documents, no separator
    };

    // No printing anywhere in a test (the runner's pipe is the reason),
    // so a failure is reported as "one of these was accepted" and the
    // loop stops at the first one.
    var accepted = false;
    for (cases) |c| {
        if (parse(alloc, c)) |*good| {
            var mut = good.*;
            mut.deinit();
            accepted = true;
            break;
        } else |_| {
            // rejected, which is the whole point
        }
    }
    try std.testing.expect(!accepted);
}

test "json: a payload over the byte cap is rejected before any allocation" {
    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, MAX_BYTES + 1);
    defer alloc.free(big);
    @memset(big, 'a');

    // The testing allocator proves nothing was allocated on the way out:
    // the cap is checked before the parser touches its allocator.
    try std.testing.expectError(error.LimitExceeded, parse(alloc, big));
}

test "json: a payload under the byte cap but over the node cap is rejected" {
    // The amplification case: one byte of input, ~24 bytes of output.
    const alloc = std.testing.allocator;
    const n = MAX_NODES + 16;
    const buf = try alloc.alloc(u8, 2 * n + 1);
    defer alloc.free(buf);
    buf[0] = '[';
    for (0..n) |k| {
        buf[1 + k * 2] = '0';
        buf[2 + k * 2] = if (k + 1 == n) ']' else ',';
    }
    try std.testing.expectError(error.LimitExceeded, parse(alloc, buf));
}

test "json: wrong-type accessors return null rather than asserting" {
    const alloc = std.testing.allocator;
    var d = try parse(alloc,
        \\{"n":1}
    );
    defer d.deinit();

    const n = get(d.root, "n").?;
    try std.testing.expect(n.asString() == null);
    try std.testing.expect(n.asBool() == null);
    try std.testing.expect(n.asArray() == null);
    try std.testing.expect(n.asObject() == null);
    try std.testing.expect(get(d.root, "missing") == null);
    // A non-object has no members.
    try std.testing.expect(get(n, "anything") == null);
}

test "json: whitespace is insignificant between tokens" {
    const alloc = std.testing.allocator;
    var d = try parse(alloc, "  {\n\t\"a\"  :\r\n [ 1 , 2 ]\t}  ");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), get(d.root, "a").?.asArray().?.len);
}

test "json: a truncated escape is an error, not a partial string" {
    const alloc = std.testing.allocator;
    // The closing quote is escaped, so the string runs off the end.
    try std.testing.expectError(error.UnexpectedEof, parse(alloc,
        \\{"a":"tail\"}
    ));
    // The escape itself is cut in half.
    try std.testing.expectError(error.UnexpectedEof, parse(alloc,
        \\{"a":"tail\u1}
    ));
}

test "json: isBlank classifies lines" {
    try std.testing.expect(isBlank(""));
    try std.testing.expect(isBlank("   "));
    try std.testing.expect(isBlank("\t\r "));
    try std.testing.expect(!isBlank("{"));
    try std.testing.expect(!isBlank(" x "));
}

test "json: a captured key keeps its exact source text" {
    // JSON-RPC echoes `id` verbatim. Round-tripping `1e2` through f64
    // would answer `100` to a client that asked about `1e2`.
    const alloc = std.testing.allocator;
    const src =
        \\{"jsonrpc":"2.0","id":1e2,"method":"ping"}
    ;
    var d = try parseWith(alloc, src, &.{"id"});
    defer d.deinit();

    try std.testing.expectEqualStrings("1e2", d.span("id").?);
    try std.testing.expectEqual(@as(f64, 100), get(d.root, "id").?.asNumber().?);
    try std.testing.expect(d.span("method") == null);
    // And the key the caller did not ask for is still fully parsed.
    try std.testing.expectEqualStrings("ping", get(d.root, "method").?.asString().?);
}

test "json: a captured string id keeps its quotes and escapes" {
    const alloc = std.testing.allocator;
    const src =
        \\{"id":"req-1","method":"ping"}
    ;
    var d = try parseWith(alloc, src, &.{"id"});
    defer d.deinit();
    try std.testing.expectEqualStrings("\"req-1\"", d.span("id").?);
}

test "json: capture only sees top-level keys" {
    const alloc = std.testing.allocator;
    var d = try parseWith(alloc,
        \\{"params":{"id":"inner"},"id":"outer"}
    , &.{"id"});
    defer d.deinit();
    try std.testing.expectEqualStrings("\"outer\"", d.span("id").?);
}

test "json: an absent captured key yields no span" {
    const alloc = std.testing.allocator;
    var d = try parseWith(alloc,
        \\{"method":"ping"}
    , &.{"id"});
    defer d.deinit();
    try std.testing.expect(d.span("id") == null);
}
