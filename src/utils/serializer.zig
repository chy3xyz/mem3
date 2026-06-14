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
//! Anything else (pointers to non-`[]const u8` slices, optionals of
//! pointer types, unions, error sets) must be wrapped in a custom
//! serializer — this module does not pretend to handle Zig's full type
//! system.

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
pub fn sizeOf(value: anytype) usize {
    const T = @TypeOf(value);
    const fixed = calculateSize(T);
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => slice_size: {
                var total: usize = @sizeOf(u32);
                for (value) |item| {
                    total += sizeOf(item);
                }
                break :slice_size total;
            },
            .one => @as(usize, value.len * calculateSize(p.child)),
            else => fixed,
        },
        .@"struct" => s_size: {
            var total: usize = fixed;
            inline for (@typeInfo(T).@"struct".field_names) |fname| {
                total += sizeOf(@field(value, fname));
            }
            break :s_size total;
        },
        .array => a_size: {
            var total: usize = fixed;
            for (value) |item| {
                total += sizeOf(item);
            }
            break :a_size total;
        },
        else => fixed,
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
        const size = comptime comptimeIntSize(@typeInfo(T).int.bits);
        if (self.remaining() < size) return error.BufferUnderflow;
        // @bitCast into a comptime-sized byte array (little-endian on dominant targets).
        const bytes: [size]u8 = @bitCast(value);
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
        const size = comptime comptimeIntSize(@typeInfo(T).int.bits);
        const slice = try self.readBytes(size);
        const bytes: [size]u8 = slice[0..size].*;
        return @bitCast(bytes);
    }
};

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
            return std.meta.intToEnum(T, tag_int) catch return error.InvalidTag;
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
    const value = [_]u32{ 1, 2, 3, 4, 5 };
    const buf = try serialize(alloc, value);
    defer alloc.free(buf);
    const out = try deserialize(alloc, []u32, buf);
    defer alloc.free(out);
    try std.testing.expectEqualSlices(u32, &value, out);
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
