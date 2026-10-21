//! Comptime zero-overhead binary serializer (Zig 0.17 dev-friendly).
//!
//! **Constitution Principle V**: serialization MUST be `comptime`-generated.
//! No runtime reflection. Each serializable type has a `serialized_size`
//! computed at compile time, used by the WAL and SSTable for offset
//! bookkeeping. Runtime serialize / deserialize are the simplest possible:
//! little-endian fixed-width for primitive scalars, length-prefixed for
//! slices, in-order fields for structs.
//!
//! Supported scalar kinds: `int`, `float`, `bool`, `enum` (tag), `?T`
//! (1-byte present flag + T), `[]const u8` (u32 len + bytes), `[N]T`
//! arrays of fixed size, and `struct` of the above.
//!
//! An `enum` is stored as its `std.meta.Tag` integer, little-endian, in
//! the smallest whole number of bytes that tag needs. A bare `enum { a,
//! b, c }` tags as `u2`, so it occupies **one** byte — the same width an
//! `enum(u8)` occupies. Enums without an explicit backing integer type
//! are supported; the tag width, not the source spelling, decides the
//! on-disk width.
//!
//! Anything else (pointers to non-`[]const u8` slices, optionals of
//! pointer types, unions, error sets) must be wrapped in a custom
//! serializer — this module does not pretend to handle Zig's full type
//! system.
//!
//! ## Two different size functions
//!
//! `calculateSize(T)` is a *per-type* constant: the fixed prefix width,
//! worst case, independent of any value. It is what `Fact.serialized_size`
//! and `MemCell.serialized_size` are, and it is what offset arithmetic
//! must use. It is deliberately not a bound on the encoded length of a
//! particular value — a `MemCell` has `serialized_size == 101` and still
//! encodes to `87 + location.len` bytes.
//!
//! `sizeOf(value)` is the per-value length. `serialize` allocates exactly
//! `sizeOf(value)` bytes, so it must equal what the encoder writes. Use
//! it, never `calculateSize`, to size a buffer.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;

const log = std.log.scoped(.mem3_serializer);

/// Comptime-computed serialized size of `T` (prefix only, not slice data).
pub fn calculateSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .int => |i| comptimeIntSize(i.bits),
        .float => |f| comptimeIntSize(f.bits),
        .bool => 1,
        .@"enum" => @sizeOf(std.meta.Tag(T)),
        .pointer => |p| switch (p.size) {
            .slice => @sizeOf(u32), // length prefix only; payload is runtime
            .one => calculateSize(p.child), // array literal decays to *const [N]T
            else => @compileError("calculateSize: unsupported pointer " ++ @typeName(T)),
        },
        .array => |a| a.len * calculateSize(a.child),
        .@"struct" => |s| s_size: {
            var total: usize = 0;
            inline for (s.field_types) |t| {
                total += calculateSize(t);
            }
            break :s_size total;
        },
        .optional => |o| 1 + calculateSize(o.child),
        .@"void" => 0,
        else => @compileError("calculateSize: unsupported type " ++ @typeName(T)),
    };
}

fn comptimeIntSize(comptime bits: u16) usize {
    return (bits + 7) / 8;
}

/// Runtime: total size of a *value*, including variable-length payload.
///
/// `serialize` allocates exactly this many bytes, so this function is the
/// encoder's own contract: for every value `writeValue` can reach it must
/// equal the number of bytes `writeValue` emits — not merely bound it. An
/// under-count here is silent data loss (the encode fails with
/// `BufferUnderflow` and the record is never written); an over-count is
/// less dangerous but still wrong, because `serialize` hands back the
/// whole allocation, so the tail of the "encoded" record is unwritten
/// heap garbage.
///
/// Two defects used to live here, and they cancelled out until they did
/// not:
///
///   * `.struct`/`.array` seeded the total with `calculateSize(T)` *and*
///     then added every field's own size, so each field's fixed prefix was
///     counted twice.
///   * `.optional` fell through to the type-only `calculateSize` branch,
///     which reports `1 + calculateSize(child)` and never adds the child's
///     runtime payload.
///
/// The first handed back surplus that masked the second. On a minimal
/// `MemCell` the surplus was 193 bytes, so `metadata.location` — free-form
/// user text — failed to serialize from its 194th character onward. See
/// the `sizeOf` tests at the bottom of this file.
pub fn sizeOf(value: anytype) usize {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => slice_size: {
                var total: usize = @sizeOf(u32); // length prefix
                for (value) |item| {
                    total += sizeOf(item);
                }
                break :slice_size total;
            },
            // `*const [N]T` (an array literal decays to this). Sum the
            // elements rather than multiplying: `[N][]const u8` is legal
            // and its payload is not a compile-time constant.
            .one => one_size: {
                var total: usize = 0;
                for (value) |item| {
                    total += sizeOf(item);
                }
                break :one_size total;
            },
            else => calculateSize(T),
        },
        .@"struct" => s_size: {
            var total: usize = 0;
            inline for (@typeInfo(T).@"struct".field_names) |fname| {
                total += sizeOf(@field(value, fname));
            }
            break :s_size total;
        },
        .array => a_size: {
            var total: usize = 0;
            for (value) |item| {
                total += sizeOf(item);
            }
            break :a_size total;
        },
        // The present branch carries the child payload; the absent branch
        // is the flag byte alone. Neither may be derived from the type.
        .optional => if (value) |inner| 1 + sizeOf(inner) else 1,
        else => calculateSize(T),
    };
}

/// Serialize `value` into an allocated buffer (little-endian).
pub fn serialize(gpa: Allocator, value: anytype) ![]u8 {
    const total = sizeOf(value);
    const buf = try gpa.alloc(u8, total);
    errdefer gpa.free(buf);
    var w = Writer{ .buf = buf };
    try writeValue(&w, value);
    return buf;
}

pub const DeserializeError = error{
    OutOfMemory,
    BufferUnderflow,
    InvalidUtf8,
    InvalidTag,
    InvalidBool,
} || error{ AnyError };

/// Deserialize `data` into a value of type `T` (allocates slices with `gpa`).
pub fn deserialize(gpa: Allocator, comptime T: type, data: []const u8) DeserializeError!T {
    var r = Reader{ .buf = data };
    return readValue(gpa, T, &r);
}

// =============================================================================
// Writer
// =============================================================================

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn remaining(self: *const Writer) usize {
        return self.buf.len - self.pos;
    }

    fn writeByte(self: *Writer, byte: u8) !void {
        if (self.remaining() < 1) return error.BufferUnderflow;
        self.buf[self.pos] = byte;
        self.pos += 1;
    }

    fn writeBytes(self: *Writer, bytes: []const u8) !void {
        if (self.remaining() < bytes.len) return error.BufferUnderflow;
        @memcpy(self.buf[self.pos .. self.pos + bytes.len], bytes);
        self.pos += bytes.len;
    }

    fn writeFixedInt(self: *Writer, comptime T: type, value: T) !void {
        const info = comptime @typeInfo(T).int;
        const size = comptime comptimeIntSize(info.bits);
        if (self.remaining() < size) return error.BufferUnderflow;
        // A tag narrower than a byte (a bare `enum { a, b, c }` tags as
        // `u2`) still occupies one whole byte on the wire, because
        // `calculateSize` rounds up — but `@bitCast` cannot bridge a
        // 2-bit integer and a `[1]u8`, so such an enum did not compile at
        // all. Emit it byte-at-a-time instead. Whole-byte widths keep the
        // original `@bitCast`, which is what guarantees the encoding of
        // every already-working type is bit-for-bit unchanged.
        var bytes: [size]u8 = undefined;
        if (comptime info.bits % 8 == 0) {
            bytes = @bitCast(value);
        } else {
            // Unreachable in practice: `std.meta.Tag` is always unsigned,
            // and no standard integer type is narrower than a byte. The
            // sign-extension case is reported rather than guessed at — it
            // never compiled before either, just with a less useful
            // message.
            if (comptime info.signedness == .signed) {
                @compileError("serializer: an integer narrower than a byte (" ++
                    @typeName(T) ++ ") cannot be encoded; declare it as an unsigned type");
            }
            inline for (0..size) |i| {
                bytes[i] = @truncate(value >> (i * 8));
            }
        }
        @memcpy(self.buf[self.pos .. self.pos + size], &bytes);
        self.pos += size;
    }
};

fn writeValue(w: *Writer, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => try w.writeFixedInt(T, value),
        .float => try w.writeFixedInt(unsignedIntForFloat(T), @bitCast(value)),
        .bool => try w.writeByte(if (value) 1 else 0),
        .@"enum" => try w.writeFixedInt(std.meta.Tag(T), @intFromEnum(value)),
        .pointer => |p| switch (p.size) {
            .slice => try writeSlice(w, value),
            .one => try writeArray(w, value),
            else => @compileError("serialize: unsupported pointer type " ++ @typeName(T)),
        },
        .array => try writeArray(w, value),
        .@"struct" => try writeStruct(w, value),
        .optional => try writeOptional(w, value),
        .@"void" => {},
        else => @compileError("serialize: unsupported type " ++ @typeName(T)),
    }
}

fn writeSlice(w: *Writer, slice: anytype) !void {
    const T = @TypeOf(slice);
    const info = @typeInfo(T).pointer;
    if (info.child == u8) {
        try w.writeFixedInt(u32, @intCast(slice.len));
        try w.writeBytes(slice);
    } else {
        try w.writeFixedInt(u32, @intCast(slice.len));
        for (slice) |item| {
            try writeValue(w, item);
        }
    }
}

fn writeArray(w: *Writer, array: anytype) !void {
    for (array) |item| {
        try writeValue(w, item);
    }
}

fn writeStruct(w: *Writer, value: anytype) !void {
    const T = @TypeOf(value);
    inline for (@typeInfo(T).@"struct".field_names) |fname| {
        try writeValue(w, @field(value, fname));
    }
}

fn writeOptional(w: *Writer, opt: anytype) !void {
    if (opt) |v| {
        try w.writeByte(1);
        try writeValue(w, v);
    } else {
        try w.writeByte(0);
    }
}

fn unsignedIntForFloat(comptime T: type) type {
    const bits = @typeInfo(T).float.bits;
    return switch (bits) {
        16 => u16,
        32 => u32,
        64 => u64,
        80 => u80,
        128 => u128,
        else => @compileError("unsignedIntForFloat: unsupported float width " ++ @typeName(T)),
    };
}

// =============================================================================
// Reader
// =============================================================================

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }

    fn readByte(self: *Reader) !u8 {
        if (self.remaining() < 1) return error.BufferUnderflow;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    fn readBytes(self: *Reader, len: usize) ![]const u8 {
        if (self.remaining() < len) return error.BufferUnderflow;
        const slice = self.buf[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }

    fn readFixedInt(self: *Reader, comptime T: type) !T {
        const info = comptime @typeInfo(T).int;
        const size = comptime comptimeIntSize(info.bits);
        const slice = try self.readBytes(size);
        // Mirrors `writeFixedInt`, and exists for the same reason: a
        // sub-byte tag (a `u2` enum tag) has `size == 1` but only two
        // significant bits, which no `@bitCast` to `[1]u8` can carry.
        if (size == 1) {
            // `topByteMask` discards the bits above `info.bits`. The
            // encoder never writes them, but this decoder is handed
            // untrusted bytes, and `std.enums.fromInt` must not be
            // reached with a tag that came from outside the enum.
            const byte: u8 = slice[0] & topByteMask(info.bits);
            // Only `i8` needs a bit-level reinterpret here (0xFF is -1,
            // not 255); every other single-byte integer is unsigned and
            // fits after masking. The condition is comptime-known, so
            // only the taken branch is analysed.
            return if (info.bits == 8 and info.signedness == .signed)
                @bitCast(byte)
            else
                @intCast(byte);
        }
        // Bytes are folded in least-significant first, so every byte
        // except the top one is shifted up inside the value's own width
        // and the `@as` cannot trap. `<<` is arithmetic for signed
        // operands, so the top byte sign-extends on the final shift.
        var acc: T = 0;
        var i: usize = size - 1;
        while (i > 0) {
            i -= 1;
            acc = (acc << 8) | @as(T, slice[i]);
        }
        const top: u8 = slice[size - 1] & topByteMask(info.bits);
        return acc | (@as(T, top) << ((size - 1) * 8));
    }
};

/// Bits of the most significant byte that are actually part of the value.
/// `0xFF` whenever the width is a whole number of bytes.
fn topByteMask(comptime bits: u16) u8 {
    const spare = comptime bits % 8;
    if (spare == 0) return 0xFF;
    return @as(u8, @truncate(@as(u16, 0xFF) >> @intCast(8 - spare)));
}

fn readValue(gpa: Allocator, comptime T: type, r: *Reader) DeserializeError!T {
    switch (@typeInfo(T)) {
        .int => return try r.readFixedInt(T),
        .float => {
            const IntT = unsignedIntForFloat(T);
            const int = try r.readFixedInt(IntT);
            return @bitCast(int);
        },
        .bool => {
            const b = try r.readByte();
            return switch (b) {
                0 => false,
                1 => true,
                else => error.InvalidBool,
            };
        },
        .@"enum" => {
            const tag_int = try r.readFixedInt(std.meta.Tag(T));
            // Zig 0.17 moved `intToEnum` to `std.enums.fromInt`.
            return std.enums.fromInt(T, tag_int) orelse return error.InvalidTag;
        },
        .pointer => |p| switch (p.size) {
            .slice => return @as(T, try readSlice(gpa, p.child, r)),
            else => @compileError("deserialize: unsupported pointer " ++ @typeName(T)),
        },
        .array => |a| {
            var arr: [a.len]a.child = undefined;
            for (&arr) |*item| {
                item.* = try readValue(gpa, a.child, r);
            }
            return arr;
        },
        .@"struct" => |s| {
            var value: T = undefined;
            inline for (s.field_names, 0..) |fname, i| {
                _ = fname;
                const ftype = s.field_types[i];
                @field(value, @typeInfo(T).@"struct".field_names[i]) =
                    try readValue(gpa, ftype, r);
            }
            return value;
        },
        .optional => |o| {
            const present = try r.readByte();
            if (present == 0) return null;
            return try readValue(gpa, o.child, r);
        },
        .@"void" => return {},
        else => @compileError("deserialize: unsupported type " ++ @typeName(T)),
    }
}

fn readSlice(gpa: Allocator, comptime Child: type, r: *Reader) DeserializeError![]Child {
    const len = try r.readFixedInt(u32);
    if (Child == u8) {
        const src = try r.readBytes(len);
        const out = try gpa.alloc(u8, len);
        @memcpy(out, src);
        return out;
    }
    const out = try gpa.alloc(Child, len);
    errdefer gpa.free(out);
    for (out) |*item| {
        item.* = try readValue(gpa, Child, r);
    }
    return out;
}

// =============================================================================
// Tests
// =============================================================================

test "calculateSize: scalars" {
    try std.testing.expectEqual(@as(usize, 1), calculateSize(u8));
    try std.testing.expectEqual(@as(usize, 2), calculateSize(u16));
    try std.testing.expectEqual(@as(usize, 4), calculateSize(u32));
    try std.testing.expectEqual(@as(usize, 8), calculateSize(u64));
    try std.testing.expectEqual(@as(usize, 4), calculateSize(f32));
    try std.testing.expectEqual(@as(usize, 8), calculateSize(f64));
    try std.testing.expectEqual(@as(usize, 1), calculateSize(bool));
}

test "calculateSize: simple struct" {
    const S = struct {
        a: u32,
        b: u8,
        c: f64,
    };
    try std.testing.expectEqual(@as(usize, 4 + 1 + 8), calculateSize(S));
}

test "serialize + deserialize: roundtrip struct with strings and slices" {
    const S = struct {
        id: u64,
        name: []const u8,
        count: u32,
    };
    const alloc = std.testing.allocator;
    const value = S{ .id = 42, .name = "hello", .count = 7 };
    const buf = try serialize(alloc, value);
    defer alloc.free(buf);
    const out = try deserialize(alloc, S, buf);
    try std.testing.expectEqual(@as(u64, 42), out.id);
    try std.testing.expectEqualStrings("hello", out.name);
    try std.testing.expectEqual(@as(u32, 7), out.count);
    // The deserialized name is a fresh allocation owned by gpa.
    alloc.free(out.name);
}

test "serialize + deserialize: roundtrip slice of u32" {
    const alloc = std.testing.allocator;
    // A slice, not an array: `[N]T` is written bare and `[]T` is written
    // with a u32 length prefix, so this test was round-tripping an array
    // through a slice decoder and could never agree. It was already red
    // before the `sizeOf` fix — the double-counted surplus used to hide
    // the mismatch by handing the reader uninitialised bytes.
    const value: []const u32 = &[_]u32{ 1, 2, 3, 4, 5 };
    const buf = try serialize(alloc, value);
    defer alloc.free(buf);
    const out = try deserialize(alloc, []u32, buf);
    defer alloc.free(out);
    try std.testing.expectEqualSlices(u32, value, out);
}

test "serialize + deserialize: optional present and absent" {
    const alloc = std.testing.allocator;
    const present = @as(?u32, 99);
    const absent = @as(?u32, null);
    const buf1 = try serialize(alloc, present);
    defer alloc.free(buf1);
    const buf2 = try serialize(alloc, absent);
    defer alloc.free(buf2);
    try std.testing.expectEqual(@as(u32, 99), (try deserialize(alloc, ?u32, buf1)).?);
    try std.testing.expect(try deserialize(alloc, ?u32, buf2) == null);
}

// =============================================================================
// Size accounting — the invariant `serialize` is built on
// =============================================================================

/// Writes `value` into a `sizeOf`-sized buffer and returns how many bytes
/// the encoder actually emitted. This is the measurement the whole module
/// rests on: `serialize` allocates `sizeOf(value)` and nothing else, so
/// any disagreement is either a failed encode or a buffer whose tail is
/// uninitialised heap.
fn encodedLen(alloc: Allocator, value: anytype) !struct { buf: []u8, written: usize } {
    const buf = try alloc.alloc(u8, sizeOf(value));
    errdefer alloc.free(buf);
    var w = Writer{ .buf = buf };
    try writeValue(&w, value);
    return .{ .buf = buf, .written = w.pos };
}

test "sizeOf equals the encoded length: an optional holding a slice, across field lengths" {
    const alloc = std.testing.allocator;
    const OptionalSlice = struct { a: u8, m: ?[]const u8 };

    // The old accounting reported a constant 12 bytes for this shape
    // regardless of `m`, while the encoder wrote 6 + len — so every value
    // from the 7th byte onward failed with `BufferUnderflow`, and the
    // bug-1 characterisation in tests/property/adjoint.zig failed at
    // 100 bytes only because 100 > 7.
    var payload: [8192]u8 = undefined;
    const lengths = [_]usize{ 0, 1, 6, 7, 8, 100, 193, 194, 250, 1024, 4096, 8192 };
    for (lengths) |len| {
        @memset(payload[0..len], 'L');
        const value: OptionalSlice = .{ .a = 7, .m = payload[0..len] };

        const r = try encodedLen(alloc, value);
        defer alloc.free(r.buf);
        try std.testing.expectEqual(sizeOf(value), r.written);
        try std.testing.expectEqual(len + 6, r.written);
    }
}

test "sizeOf equals the encoded length: a struct with every supported kind" {
    const alloc = std.testing.allocator;
    const Kind = enum(u8) { matter, form, spirit };
    const Kitchen = struct {
        id: u64,
        source: Kind,
        name: []const u8,
        ratio: f32,
        weight: f64,
        flags: [3]bool,
        bias: ?i32,
        maybe_text: ?[]const u8,
        tags: []const []const u8,
        ids: []const u64,
        grid: [2][2]u16,
    };

    var scratch: [2048]u8 = undefined;
    @memset(&scratch, 'k');
    const names = [_][]const u8{ "", "a", "longer name" };
    const lens = [_]usize{ 0, 1, 17, 128, 1024 };

    for (names) |name| {
        for (lens) |maybe_len| {
            const tags = try alloc.alloc([]const u8, 3);
            defer alloc.free(tags);
            for (tags, 0..) |*t, i| t.* = scratch[0 .. i * 5 % 64];

            const ids = try alloc.alloc(u64, 3);
            defer alloc.free(ids);
            for (ids, 0..) |*id, i| id.* = @as(u64, i) * 0x0102030405060708;

            const value: Kitchen = .{
                .id = 0x1122334455667788,
                .source = .form,
                .name = if (name.len == 0) scratch[0..0] else name,
                .ratio = 1.5,
                .weight = -2.25,
                .flags = .{ true, false, true },
                .bias = if (maybe_len % 2 == 0) null else -12345,
                .maybe_text = if (maybe_len % 3 == 0) null else scratch[0..maybe_len],
                .tags = tags,
                .ids = ids,
                .grid = .{ .{ 1, 2 }, .{ 3, 4 } },
            };

            const r = try encodedLen(alloc, value);
            defer alloc.free(r.buf);
            try std.testing.expectEqual(sizeOf(value), r.written);
            try std.testing.expect(r.written >= 1);
        }
    }
}

test "sizeOf equals the encoded length: a null optional is just its flag byte" {
    const alloc = std.testing.allocator;
    const S = struct { a: u8, m: ?[]const u8, n: ?i64 };

    const absent = S{ .a = 1, .m = null, .n = null };
    const r = try encodedLen(alloc, absent);
    defer alloc.free(r.buf);
    try std.testing.expectEqual(@as(usize, 3), r.written);
    try std.testing.expectEqual(@as(usize, 3), sizeOf(absent));

    const present = S{ .a = 1, .m = "abc", .n = -1 };
    const r2 = try encodedLen(alloc, present);
    defer alloc.free(r2.buf);
    try std.testing.expectEqual(@as(usize, 1 + 1 + 4 + 3 + 1 + 8), r2.written);
    try std.testing.expectEqual(r2.written, sizeOf(present));
}

test "sizeOf equals the encoded length: an array of slices, not len times the prefix" {
    const alloc = std.testing.allocator;
    const S = struct { many: [2][]const u8 };

    const value = S{ .many = .{ "ab", "cde" } };
    const r = try encodedLen(alloc, value);
    defer alloc.free(r.buf);
    // Each element is a full slice: its own u32 length prefix plus payload.
    try std.testing.expectEqual(@as(usize, 4 + 2 + 4 + 3), r.written);
    try std.testing.expectEqual(r.written, sizeOf(value));
}

// =============================================================================
// Regression: the MemCell `location` data-loss bug
// =============================================================================

/// Mirrors `core.MemCell` field-for-field, including all fourteen
/// `core.Metadata` fields, so the exact production encoding is exercised.
/// Declared here rather than imported so this module stays standalone
/// (`zig test src/utils/serializer.zig`) and free of a dependency cycle
/// with `core/types.zig`, which imports this file.
const MetaShape = struct {
    created_at: i64 = 0,
    updated_at: i64 = 0,
    source_confidence: f32 = 1.0,
    emotional_valence: f32 = 0.0,
    location: ?[]const u8 = null,
    access_count: u64 = 0,
    last_accessed_at: i64 = 0,
    coherence_score: f32 = 0.0,
    importance_score: f32 = 0.5,
    decay_rate: f32 = 0.01,
    is_fuzzy: bool = false,
    superseded_at: ?i64 = null,
    superseded_by: ?u64 = null,
    fuzzed_at: ?i64 = null,
};

const CellShape = struct {
    id: u64,
    source: enum(u8) { matter, form, spirit },
    episode: []const u8,
    atomic_facts: []const u32,
    foresight: []const u64,
    goal_associations: []const u16,
    metadata: MetaShape,

    fn deinit(self: CellShape, alloc: Allocator) void {
        // Every one of these is a fresh allocation made by `readSlice`,
        // including the zero-length case, so all of them are freeable.
        alloc.free(self.episode);
        alloc.free(self.atomic_facts);
        alloc.free(self.foresight);
        alloc.free(self.goal_associations);
        if (self.metadata.location) |loc| alloc.free(loc);
    }
};

test "regression: a MemCell-shaped cell with a long location round-trips byte for byte" {
    const alloc = std.testing.allocator;

    // 193 was the largest location the broken accounting could encode
    // (193 bytes of surplus from double-counted field prefixes, minus the
    // un-counted location payload); 194 was the first character that lost
    // the write. 1024 and 8192 are past any plausible accidental slack.
    const lengths = [_]usize{ 0, 1, 100, 193, 194, 250, 251, 1024, 8192 };
    var scratch: [8192]u8 = undefined;

    for (lengths) |loc_len| {
        @memset(scratch[0..loc_len], 'L');
        const location = try alloc.alloc(u8, loc_len);
        defer alloc.free(location);
        @memset(location, 'L');

        const facts = try alloc.alloc(u32, 2);
        defer alloc.free(facts);
        @memcpy(facts, &[_]u32{ 11, 22 });

        const foresight = try alloc.alloc(u64, 1);
        defer alloc.free(foresight);
        @memcpy(foresight, &[_]u64{33});

        const goals = try alloc.alloc(u16, 1);
        defer alloc.free(goals);
        @memcpy(goals, &[_]u16{44});

        const episode = try alloc.alloc(u8, 5);
        defer alloc.free(episode);
        @memcpy(episode, "episo");

        const cell: CellShape = .{
            .id = 1,
            .source = .matter,
            .episode = episode,
            .atomic_facts = facts,
            .foresight = foresight,
            .goal_associations = goals,
            .metadata = .{
                .created_at = 1,
                .updated_at = 2,
                .location = location,
                .superseded_at = 9,
            },
        };

        // Must not raise `BufferUnderflow`: that error *was* the write
        // being dropped on the floor.
        const bytes = try serialize(alloc, cell);
        defer alloc.free(bytes);

        const back = try deserialize(alloc, CellShape, bytes);
        defer back.deinit(alloc);

        try std.testing.expectEqual(cell.id, back.id);
        try std.testing.expectEqual(cell.source, back.source);
        try std.testing.expectEqualStrings(cell.episode, back.episode);
        try std.testing.expectEqualSlices(u32, cell.atomic_facts, back.atomic_facts);
        try std.testing.expectEqualSlices(u64, cell.foresight, back.foresight);
        try std.testing.expectEqualSlices(u16, cell.goal_associations, back.goal_associations);
        try std.testing.expectEqual(cell.metadata.created_at, back.metadata.created_at);
        try std.testing.expectEqual(cell.metadata.superseded_at, back.metadata.superseded_at);
        try std.testing.expect(back.metadata.location != null);
        try std.testing.expectEqualStrings(cell.metadata.location.?, back.metadata.location.?);

        // Byte for byte: re-encoding the recovered value must reproduce
        // the exact bytes, so nothing was padded, truncated or reordered.
        const again = try serialize(alloc, back);
        defer alloc.free(again);
        try std.testing.expectEqualSlices(u8, bytes, again);

        // And `sizeOf` agrees with what was encoded.
        try std.testing.expectEqual(sizeOf(cell), bytes.len);
    }
}

test "regression: the surplus that masked the bug is gone — no unwritten tail" {
    const alloc = std.testing.allocator;

    // A plain slice in a struct used to be counted twice (4 spare bytes),
    // which is why short cases "worked" and masked the optional-slice
    // under-count. `sizeOf` must now be exact, so the allocated buffer
    // and the encoded length are the same number.
    const S = struct { id: u64, tail: []const u8 };
    for ([_]usize{ 0, 1, 2, 4, 8, 16, 1024 }) |len| {
        const bytes = try alloc.alloc(u8, len);
        defer alloc.free(bytes);
        @memset(bytes, 't');

        const value = S{ .id = 0x0102030405060708, .tail = bytes };
        const r = try encodedLen(alloc, value);
        defer alloc.free(r.buf);
        try std.testing.expectEqual(@as(usize, 12 + len), r.written);
        try std.testing.expectEqual(r.written, sizeOf(value));

        const via_serialize = try serialize(alloc, value);
        defer alloc.free(via_serialize);
        try std.testing.expectEqual(r.written, via_serialize.len);
    }
}

// =============================================================================
// Regression: enums with no explicit backing integer type
// =============================================================================

test "regression: an enum with no explicit backing type round-trips" {
    const alloc = std.testing.allocator;

    // `std.meta.Tag` picks the smallest unsigned int that fits, so these
    // tag as u2/u3/u4/u8 — all narrower than the byte `@bitCast` used to
    // demand. `calculateSize` already rounded the tag up to one byte, so
    // the fix is the encoder/decoder, not the size computation.
    const Narrow = enum { a, b, c };
    const Three = enum { s0, s1, s2, s3, s4, s5, s6, s7 };
    const Nine = enum { n0, n1, n2, n3, n4, n5, n6, n7, n8 };
    const Wide = enum(u8) { a, b, c };

    try std.testing.expectEqual(@as(u16, 2), @bitSizeOf(std.meta.Tag(Narrow)));
    try std.testing.expectEqual(@as(u16, 3), @bitSizeOf(std.meta.Tag(Three)));
    try std.testing.expectEqual(@as(u16, 4), @bitSizeOf(std.meta.Tag(Nine)));
    try std.testing.expectEqual(@as(usize, 1), calculateSize(Narrow));
    try std.testing.expectEqual(@as(usize, 1), calculateSize(Three));
    try std.testing.expectEqual(@as(usize, 1), calculateSize(Nine));

    inline for (.{ Narrow, Three, Nine, Wide }) |E| {
        var i: usize = 0;
        while (i < @typeInfo(E).@"enum".field_names.len) : (i += 1) {
            const value: E = @enumFromInt(i);
            const bytes = try serialize(alloc, value);
            defer alloc.free(bytes);
            try std.testing.expectEqual(calculateSize(E), bytes.len);
            try std.testing.expectEqual(@as(u8, @intCast(i)), bytes[0]);
            try std.testing.expectEqual(value, try deserialize(alloc, E, bytes));
        }
    }
}

test "regression: a sub-byte enum tag inside a struct shares its one byte" {
    const alloc = std.testing.allocator;
    const Narrow = enum { a, b, c };
    const S = struct { before: u16, kind: Narrow, after: []const u8 };

    const value = S{ .before = 0xBEEF, .kind = .b, .after = "hi" };
    const bytes = try serialize(alloc, value);
    defer alloc.free(bytes);

    // 2 (u16) + 1 (one-byte u2 tag) + 4 (slice length) + 2 (payload).
    try std.testing.expectEqual(@as(usize, 9), bytes.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xEF, 0xBE, 0x01, 0x02, 0x00, 0x00, 0x00, 'h', 'i' }, bytes);

    const back = try deserialize(alloc, S, bytes);
    defer alloc.free(back.after);
    try std.testing.expectEqual(@as(u16, 0xBEEF), back.before);
    try std.testing.expectEqual(Narrow.b, back.kind);
    try std.testing.expectEqualStrings("hi", back.after);
}

test "regression: an out-of-range tag byte does not smuggle in a variant" {
    const alloc = std.testing.allocator;
    const Narrow = enum { a, b, c };

    // The decoder reads untrusted bytes. Bits above the u2 tag width are
    // masked off, so a corrupt byte cannot smuggle in a tag the enum
    // does not have: 0xFC's low two bits are 0b00, which is `.a`, and
    // unmasked it would have been 252 — a value no `u2` can hold.
    const back = try deserialize(alloc, Narrow, &[_]u8{0xFC});
    try std.testing.expectEqual(Narrow.a, back);

    // A byte whose low bits really are a valid tag still decodes to it.
    const back2 = try deserialize(alloc, Narrow, &[_]u8{0xFA});
    try std.testing.expectEqual(Narrow.c, back2);
}

// =============================================================================
// Wire format
// =============================================================================

test "wire format: the encoding of a known value is unchanged" {
    const alloc = std.testing.allocator;
    const Kind = enum(u8) { matter, form, spirit };
    const S = struct {
        a: u8,
        b: u32,
        c: f32,
        d: u64,
        e: Kind,
        f: ?u32,
        g: []const u8,
        h: [2]bool,
    };

    const value = S{
        .a = 0x11,
        .b = 0x22,
        .c = 1.5,
        .d = 0x0807060504030201,
        .e = .form,
        .f = 0x11223344,
        .g = "xyz",
        .h = .{ true, false },
    };

    // Declaration order, little-endian, u32 length prefixes. If this
    // golden vector ever changes, an existing WAL or snapshot written by
    // an earlier build can no longer be read — that is a format version
    // bump, not a refactor.
    const expected = [_]u8{
        0x11, // a
        0x22, 0x00, 0x00, 0x00, // b
        0x00, 0x00, 0xC0, 0x3F, // c = 1.5f32
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // d
        0x01, // e = form
        0x01, 0x44, 0x33, 0x22, 0x11, // f = present, 0x11223344
        0x03, 0x00, 0x00, 0x00, 'x', 'y', 'z', // g
        0x01, 0x00, // h
    };

    const bytes = try serialize(alloc, value);
    defer alloc.free(bytes);
    try std.testing.expectEqualSlices(u8, &expected, bytes);
    // `calculateSize` is the per-type *prefix* (29 here — slice payload
    // excluded); `sizeOf` is this value's length, which is what the
    // buffer must be. The two are not interchangeable, which is the
    // whole point of the distinction.
    try std.testing.expectEqual(@as(usize, 29), calculateSize(S));
    try std.testing.expectEqual(bytes.len, sizeOf(value));

    const back = try deserialize(alloc, S, bytes);
    defer alloc.free(back.g);
    try std.testing.expectEqual(value.a, back.a);
    try std.testing.expectEqual(value.b, back.b);
    try std.testing.expectEqual(@as(u32, @bitCast(value.c)), @as(u32, @bitCast(back.c)));
    try std.testing.expectEqual(value.d, back.d);
    try std.testing.expectEqual(value.e, back.e);
    try std.testing.expectEqual(value.f, back.f);
    try std.testing.expectEqualStrings(value.g, back.g);
    try std.testing.expectEqualSlices(bool, &value.h, &back.h);
}

test "wire format: signed and sub-byte integers keep their old encoding" {
    const alloc = std.testing.allocator;

    const v8: i8 = -1;
    const b8 = try serialize(alloc, v8);
    defer alloc.free(b8);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xFF}, b8);
    try std.testing.expectEqual(v8, try deserialize(alloc, i8, b8));

    const v16: i16 = -2;
    const b16 = try serialize(alloc, v16);
    defer alloc.free(b16);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFE, 0xFF }, b16);
    try std.testing.expectEqual(v16, try deserialize(alloc, i16, b16));

    const v64: u64 = 0xF1F2F3F4F5F6F7F8;
    const b64 = try serialize(alloc, v64);
    defer alloc.free(b64);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xF8, 0xF7, 0xF6, 0xF5, 0xF4, 0xF3, 0xF2, 0xF1 }, b64);
    try std.testing.expectEqual(v64, try deserialize(alloc, u64, b64));

    const v128: u128 = 0x0102030405060708090A0B0C0D0E0F10;
    const b128 = try serialize(alloc, v128);
    defer alloc.free(b128);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x10, 0x0F, 0x0E, 0x0D, 0x0C, 0x0B, 0x0A, 0x09,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
    }, b128);
    try std.testing.expectEqual(v128, try deserialize(alloc, u128, b128));
}
