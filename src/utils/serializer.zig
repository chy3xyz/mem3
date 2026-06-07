//! Comptime zero-overhead binary serializer.
//!
//! **Constitution Principle V**: serialization MUST be `comptime`-generated.
//! No runtime reflection. Each serializable type has a `serialized_size`
//! computed at compile time, used by the WAL and SSTable for offset
//! arithmetic.
//!
//! ## Wire format
//!
//! - Integers: little-endian, fixed-width matching the type.
//! - Floats: little-endian bit-cast to integer, fixed-width.
//! - Enums: stored as their `u8` tag (must be `enum(u8)`).
//! - Bools: 1 byte (0 or 1).
//! - `[]const u8`: 4-byte little-endian length prefix, then UTF-8 bytes.
//! - `[]const T` (any other T): 4-byte count prefix, then each element serialized.
//! - Struct: fields emitted in declaration order.
//! - Optional: 1-byte present flag (0/1), then value if present.
//!
//! ## Comptime size calculation
//!
//! `calculateSize(T)` walks the type's fields at compile time and sums the
//! fixed-width contributions. Variable-length types (slices) are reported
//! as their *prefix* size; the actual length depends on runtime data.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const log = std.log.scoped(.mem3_serializer);

/// Comptime-computed serialized size of `T` (prefix only, not data).
pub fn calculateSize(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .Int => |i| divCeilInt(i.bits, 8),
        .Float => |f| f.bits / 8,
        .Bool => 1,
        .Enum => @sizeOf(std.meta.Tag(T)),
        .Pointer => |p| p_size(p),
        .Array => |a| a.len * calculateSize(a.child),
        .Struct => |s| s_size: {
            var total: usize = 0;
            for (s.fields) |f| {
                total += calculateSize(f.type);
            }
            break :s_size total;
        },
        .Optional => |o| 1 + calculateSize(o.child),
        .Void => 0,
        else => @compileError("calculateSize: unsupported type " ++ @typeName(T)),
    };
}

fn divCeilInt(comptime numerator: comptime_int, comptime denominator: comptime_int) usize {
    return @divFloor(numerator + denominator - 1, denominator);
}

fn p_size(comptime p: std.builtin.Type.Pointer) usize {
    return switch (p.size) {
        .Slice => blk: {
            if (p.child == u8) {
                break :blk @sizeOf(u32); // length prefix only
            }
            break :blk @sizeOf(u32) + calculateSize(p.child);
        },
        else => @compileError("calculateSize: only slices supported, got " ++ @typeName(p)),
    };
}

/// Compute the *runtime* size of a value (prefix + data).
pub fn sizeOf(value: anytype) usize {
    const T = @TypeOf(value);
    const fixed = calculateSize(T);
    return switch (@typeInfo(T)) {
        .Pointer => |p| blk: {
            if (p.size == .Slice) {
                if (p.child == u8) {
                    break :blk @sizeOf(u32) + value.len;
                }
                var total: usize = @sizeOf(u32);
                for (value) |item| {
                    total += sizeOf(item);
                }
                break :blk total;
            }
            break :blk fixed;
        },
        .Struct => blk: {
            var total: usize = fixed;
            inline for (@typeInfo(T).Struct.fields) |f| {
                const fv = @field(value, f.name);
                total += switch (@typeInfo(f.type)) {
                    .Pointer => |p| if (p.size == .Slice and p.child != u8) sliceSize(fv) else 0,
                    else => 0,
                };
            }
            break :blk total;
        },
        .Array => blk: {
            var total: usize = fixed;
            for (value) |item| {
                total += sizeOf(item);
            }
            break :blk total;
        },
        else => fixed,
    };
}

fn sliceSize(slice: anytype) usize {
    var total: usize = 0;
    for (slice) |item| {
        total += sizeOf(item);
    }
    return total;
}

// =============================================================================
// Serialize: returns an owned slice allocated with `gpa`.
// =============================================================================

pub const SerializeError = Allocator.Error || std.posix.RealAnyError || std.io.GenericWriterError;

pub fn serialize(gpa: Allocator, value: anytype) SerializeError![]u8 {
    const total = sizeOf(value);
    const buf = try gpa.alloc(u8, total);
    errdefer gpa.free(buf);
    var stream = std.io.fixedBufferStream(buf);
    try writeValue(&stream, value);
    return buf;
}

fn writeValue(stream: *std.io.FixedBufferStream([]u8), value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Int => try writeInt(stream, value),
        .Float => try writeFloat(stream, value),
        .Bool => try stream.writer().writeByte(if (value) 1 else 0),
        .Enum => try writeInt(stream, @intFromEnum(value)),
        .Pointer => |p| switch (p.size) {
            .Slice => try writeSlice(stream, value),
            else => @compileError("serialize: unsupported pointer type " ++ @typeName(T)),
        },
        .Array => try writeArray(stream, value),
        .Struct => try writeStruct(stream, value),
        .Optional => try writeOptional(stream, value),
        .Void => {},
        else => @compileError("serialize: unsupported type " ++ @typeName(T)),
    }
}

fn writeInt(stream: *std.io.FixedBufferStream([]u8), value: anytype) !void {
    const T = @TypeOf(value);
    const size = divCeilInt(@typeInfo(T).Int.bits, 8);
    var bytes: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(value, &bytes, .little);
    try stream.writer().writeAll(bytes[0..size]);
}

fn writeFloat(stream: *std.io.FixedBufferStream([]u8), value: anytype) !void {
    const T = @TypeOf(value);
    const IntT = std.meta.Int(.unsigned, @typeInfo(T).Float.bits);
    try writeInt(stream, @as(IntT, @bitCast(value)));
}

fn writeSlice(stream: *std.io.FixedBufferStream([]u8), slice: anytype) !void {
    const T = @TypeOf(slice);
    const ptr_info = @typeInfo(T).Pointer;
    if (ptr_info.child == u8) {
        try writeInt(stream, @as(u32, @intCast(slice.len)));
        try stream.writer().writeAll(slice);
    } else {
        try writeInt(stream, @as(u32, @intCast(slice.len)));
        for (slice) |item| {
            try writeValue(stream, item);
        }
    }
}

fn writeArray(stream: *std.io.FixedBufferStream([]u8), array: anytype) !void {
    for (array) |item| {
        try writeValue(stream, item);
    }
}

fn writeStruct(stream: *std.io.FixedBufferStream([]u8), value: anytype) !void {
    const T = @TypeOf(value);
    inline for (@typeInfo(T).Struct.fields) |f| {
        try writeValue(stream, @field(value, f.name));
    }
}

fn writeOptional(stream: *std.io.FixedBufferStream([]u8), opt: anytype) !void {
    if (opt) |v| {
        try stream.writer().writeByte(1);
        try writeValue(stream, v);
    } else {
        try stream.writer().writeByte(0);
    }
}

// =============================================================================
// Deserialize: parses bytes into a value. Allocates strings / slices with gpa.
// =============================================================================

pub const DeserializeError = error{
    OutOfMemory,
    BufferUnderflow,
    InvalidUtf8,
    InvalidTag,
    InvalidBool,
} || std.posix.RealAnyError;

pub fn deserialize(gpa: Allocator, comptime T: type, data: []const u8) DeserializeError!T {
    var stream = std.io.fixedBufferStream(data);
    return readValue(gpa, T, &stream);
}

fn readValue(gpa: Allocator, comptime T: type, stream: *std.io.FixedBufferStream([]const u8)) DeserializeError!T {
    switch (@typeInfo(T)) {
        .Int => return try readInt(T, stream),
        .Float => {
            const IntT = std.meta.Int(.unsigned, @typeInfo(T).Float.bits);
            return @bitCast(try readInt(IntT, stream));
        },
        .Bool => {
            const b = try stream.reader().readByte();
            return switch (b) {
                0 => false,
                1 => true,
                else => return error.InvalidBool,
            };
        },
        .Enum => {
            const tag_int = try readInt(std.meta.Tag(T), stream);
            return std.meta.intToEnum(T, tag_int) catch return error.InvalidTag;
        },
        .Pointer => |p| switch (p.size) {
            .Slice => return @as(T, try readSlice(gpa, p.child, stream)),
            else => @compileError("deserialize: unsupported pointer type " ++ @typeName(T)),
        },
        .Array => |a| {
            var arr: [a.len]a.child = undefined;
            for (&arr) |*item| {
                item.* = try readValue(gpa, a.child, stream);
            }
            return arr;
        },
        .Struct => |s| {
            var value: T = undefined;
            inline for (s.fields) |f| {
                @field(value, f.name) = try readValue(gpa, f.type, stream);
            }
            return value;
        },
        .Optional => |o| {
            const present = try stream.reader().readByte();
            if (present == 0) return null;
            return try readValue(gpa, o.child, stream);
        },
        .Void => return {},
        else => @compileError("deserialize: unsupported type " ++ @typeName(T)),
    }
}

fn readInt(comptime T: type, stream: *std.io.FixedBufferStream([]const u8)) DeserializeError!T {
    const size = divCeilInt(@typeInfo(T).Int.bits, 8);
    const raw = try stream.reader().readBytesNoEof(size);
    return std.mem.readInt(T, raw, .little);
}

fn readSlice(gpa: Allocator, comptime Child: type, stream: *std.io.FixedBufferStream([]const u8)) DeserializeError![]Child {
    const len = try readInt(u32, stream);
    if (Child == u8) {
        const buf = try gpa.alloc(u8, len);
        errdefer gpa.free(buf);
        const raw = try stream.reader().readBytesNoEof(len);
        @memcpy(buf, raw);
        return buf;
    }
    const buf = try gpa.alloc(Child, len);
    errdefer gpa.free(buf);
    for (buf) |*item| {
        item.* = try readValue(gpa, Child, stream);
    }
    return buf;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "calculateSize: primitives" {
    try testing.expectEqual(@as(usize, 1), calculateSize(u8));
    try testing.expectEqual(@as(usize, 4), calculateSize(u32));
    try testing.expectEqual(@as(usize, 8), calculateSize(u64));
    try testing.expectEqual(@as(usize, 4), calculateSize(f32));
    try testing.expectEqual(@as(usize, 8), calculateSize(f64));
    try testing.expectEqual(@as(usize, 1), calculateSize(bool));
}

test "serialize + deserialize: roundtrip u32" {
    const v: u32 = 0x12345678;
    const buf = try serialize(testing.allocator, v);
    defer testing.allocator.free(buf);
    try testing.expectEqual(@as(usize, 4), buf.len);
    const out = try deserialize(testing.allocator, u32, buf);
    try testing.expectEqual(v, out);
}

test "serialize + deserialize: roundtrip struct with strings and slices" {
    const types = @import("../core/types.zig");
    const Fact = types.Fact;
    const cell: Fact = .{
        .subject = "user",
        .predicate = "asked",
        .object = "how to use Zig 0.17",
        .confidence = 0.95,
        .source = "user_input",
    };
    const buf = try serialize(testing.allocator, cell);
    defer testing.allocator.free(buf);

    try testing.expect(buf.len >= 50);

    const out = try deserialize(testing.allocator, Fact, buf);
    defer testing.allocator.free(out.subject);
    defer testing.allocator.free(out.predicate);
    defer testing.allocator.free(out.object);
    defer testing.allocator.free(out.source);
    try testing.expectEqualStrings(cell.subject, out.subject);
    try testing.expectEqualStrings(cell.object, out.object);
    try testing.expectEqual(cell.confidence, out.confidence);
}

test "serialize + deserialize: roundtrip array of structs" {
    const arr = [_]u32{ 1, 2, 3, 4, 5 };
    const buf = try serialize(testing.allocator, &arr);
    defer testing.allocator.free(buf);
    try testing.expectEqual(@as(usize, 20), buf.len);
    const out = try deserialize(testing.allocator, [5]u32, buf);
    try testing.expectEqualSlices(u32, &arr, &out);
}

test "serialize + deserialize: roundtrip optional" {
    const v: ?[]const u8 = "hello";
    const buf = try serialize(testing.allocator, v);
    defer testing.allocator.free(buf);
    const out = try deserialize(testing.allocator, ?[]const u8, buf);
    defer if (out) |s| testing.allocator.free(s);
    try testing.expectEqualStrings("hello", out.?);
}

test "serialize + deserialize: roundtrip null optional" {
    const v: ?[]const u8 = null;
    const buf = try serialize(testing.allocator, v);
    defer testing.allocator.free(buf);
    try testing.expectEqual(@as(usize, 1), buf.len);
    const out = try deserialize(testing.allocator, ?[]const u8, buf);
    try testing.expectEqual(@as(?[]const u8, null), out);
}
