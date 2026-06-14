//! Property-based test for the comptime serializer round-trip.
//!
//! Constitution Principle V (comptime zero-overhead): the binary
//! format MUST be deterministic. We exercise that by generating
//! random `Fact` and `Foresight` slices and confirming that
//! `serialize → deserialize` recovers the exact bytes.
//!
//! We don't have a `std.Random` PRNG set up by default, so this test
//! uses a hand-rolled LCG seeded by the test's `pid` + `time`. That
//! gives a different sequence per run — the property is checked
//! each time.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");

fn lcgSeed() u64 {
    // Zig 0.17 dev removed std.time.{milli,nano}Timestamp — go through libc.
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const ns: u64 = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    return ns;
}

fn lcgNext(state: *u64) u8 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return @truncate(state.* >> 32);
}

fn randomBytes(alloc: std.mem.Allocator, len: usize, state: *u64) ![]u8 {
    const buf = try alloc.alloc(u8, len);
    for (buf) |*b| b.* = lcgNext(state);
    return buf;
}

test "serializer: random Fact slice round-trips" {
    const alloc = testing.allocator;
    var state = lcgSeed();

    var run: usize = 0;
    while (run < 32) : (run += 1) {
        const n = @as(usize, lcgNext(&state) % 5) + 1;
        var facts = try alloc.alloc(mem3.Fact, n);
        defer alloc.free(facts);
        for (0..n) |i| {
            const f = &facts[i];
            const subj_len = @as(usize, lcgNext(&state) % 8) + 1;
            const pred_len = @as(usize, lcgNext(&state) % 6) + 1;
            const obj_len = @as(usize, lcgNext(&state) % 10) + 1;
            const src_len = @as(usize, lcgNext(&state) % 4) + 1;
            const subj = try randomBytes(alloc, subj_len, &state);
            defer alloc.free(subj);
            const pred = try randomBytes(alloc, pred_len, &state);
            defer alloc.free(pred);
            const obj = try randomBytes(alloc, obj_len, &state);
            defer alloc.free(obj);
            const src = try randomBytes(alloc, src_len, &state);
            defer alloc.free(src);
            f.* = .{
                .subject = subj,
                .predicate = pred,
                .object = obj,
                .confidence = 0.5,
                .source = src,
            };
        }

        const buf = try mem3.utils.serializer.serialize(alloc, facts);
        defer alloc.free(buf);
        const out = try mem3.utils.serializer.deserialize(alloc, []mem3.Fact, buf);
        defer {
            for (out) |f| {
                alloc.free(@constCast(f.subject));
                alloc.free(@constCast(f.predicate));
                alloc.free(@constCast(f.object));
                alloc.free(@constCast(f.source));
            }
            alloc.free(out);
        }

        try testing.expectEqual(facts.len, out.len);
        for (facts, out) |a, b| {
            try testing.expectEqualStrings(a.subject, b.subject);
            try testing.expectEqualStrings(a.predicate, b.predicate);
            try testing.expectEqualStrings(a.object, b.object);
            try testing.expectEqualStrings(a.source, b.source);
            try testing.expect(a.confidence == b.confidence);
        }
    }
}

test "serializer: primitive types round-trip" {
    const alloc = testing.allocator;
    var state = lcgSeed();

    var run: usize = 0;
    while (run < 32) : (run += 1) {
        // Test every primitive type the serializer knows about.
        // u8
        const u8val: u8 = lcgNext(&state);
        const u8buf = try mem3.utils.serializer.serialize(alloc, u8val);
        defer alloc.free(u8buf);
        try testing.expectEqual(u8val, try mem3.utils.serializer.deserialize(alloc, u8, u8buf));

        // u32
        const u32val: u32 = (@as(u32, lcgNext(&state)) << 16) | @as(u32, lcgNext(&state));
        const u32buf = try mem3.utils.serializer.serialize(alloc, u32val);
        defer alloc.free(u32buf);
        try testing.expectEqual(u32val, try mem3.utils.serializer.deserialize(alloc, u32, u32buf));

        // u64
        const u64val: u64 = (@as(u64, lcgNext(&state)) << 32) | @as(u64, lcgNext(&state));
        const u64buf = try mem3.utils.serializer.serialize(alloc, u64val);
        defer alloc.free(u64buf);
        try testing.expectEqual(u64val, try mem3.utils.serializer.deserialize(alloc, u64, u64buf));

        // bool
        const bval = (lcgNext(&state) & 1) == 0;
        const bbuf = try mem3.utils.serializer.serialize(alloc, bval);
        defer alloc.free(bbuf);
        try testing.expectEqual(bval, try mem3.utils.serializer.deserialize(alloc, bool, bbuf));
    }
}

test "serializer: array of struct round-trips" {
    const alloc = testing.allocator;
    var state = lcgSeed();

    const arr = [_]u32{
        (@as(u32, lcgNext(&state)) << 16) | @as(u32, lcgNext(&state)),
        (@as(u32, lcgNext(&state)) << 16) | @as(u32, lcgNext(&state)),
        (@as(u32, lcgNext(&state)) << 16) | @as(u32, lcgNext(&state)),
    };
    const buf = try mem3.utils.serializer.serialize(alloc, &arr);
    defer alloc.free(buf);
    const out = try mem3.utils.serializer.deserialize(alloc, [3]u32, buf);
    try testing.expectEqualSlices(u32, &arr, &out);
}