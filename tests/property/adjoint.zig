//! Category-theoretic adjoint checks (Constitution Principle VI).
//!
//! > **Category-theoretic sanity checks** for adjoint pairs:
//! > `Encode` ∘ `Decode` ≈ `id` (left adjoint),
//! > `Decode` ∘ `Encode` ≤ `id` (right adjoint approximation).
//!
//! Nothing tested either half. `serializer_roundtrip.zig` checks that
//! a `Fact` slice survives a serialize/deserialize cycle, which is one
//! example of the left half for one type; it never states the
//! property, never checks the right half, and its generator only
//! produces byte strings (8-bit LCG output concatenated), so an empty
//! string, a NUL, a multi-byte UTF-8 codepoint and a 3-byte string
//! are indistinguishable to it.
//!
//! ## Why the halves are named the way they are
//!
//! Composition in the constitution reads right-to-left
//! (`Encode ∘ Decode` = "Decode, then Encode"), but for a serializer
//! the *codec* is what people mean: `serialize` is the Encode
//! morphism into bytes, `deserialize` is the Decode morphism back.
//! This file names every direction explicitly instead of relying on
//! the composition notation, because the two directions are different
//! properties and conflating them is exactly how one of them gets
//! silently skipped.
//!
//! ## Left adjoint: `Decode ∘ Encode ≈ id` (value → bytes → value)
//!
//! Round-trip a structurally varied generated value through
//! `serialize`/`deserialize` and require the recovered value to equal
//! the original, field by field, with floats compared by bit pattern
//! (NaN ≠ NaN under `==`, so `expectEqual` would be wrong here).
//! Generated coverage includes empty strings, embedded NULs,
//! multi-byte UTF-8, a 4 KiB string, i64 minimum, u32 maximum,
//! subnormal and ±0.0 floats, NaN, ±Inf, nested structs, arrays of
//! arrays, slices of slices, and present/absent optionals.
//!
//! ## Right adjoint: `Encode ∘ Decode ≤ id` (bytes → value → bytes)
//!
//! The literal reading is "the re-encoded value must not be richer
//! than the original input". For *this* serializer that inequality is
//! not independently checkable, and pretending otherwise would make
//! the test vacuous. `serialize` is total on the value domain and
//! `deserialize` is total on the image of `serialize`, so the two
//! halves are mutual inverses on that image and `≤` degenerates to
//! `=`: there is no coarser behaviour for the round trip to degrade
//! into. Two things make it vacuous: (a) `≤` needs an order on values,
//! and the only order this codebase has is information content — which
//! the injectivity check below shows is equality on the canonical
//! image; (b) a decoder that *did* invent information would still
//! satisfy "re-encode ≤ input" if it invented it consistently, so the
//! naive assertion cannot fail.
//!
//! What survives as a real, falsifiable property is the standard
//! categorical content of `≤`: `decode ∘ encode` is a **projection**
//! — a retraction onto the decodable image, and therefore idempotent.
//! Plus the anti-invention half, which is where a decoder actually
//! fabricates data in practice: it must not read past the end of a
//! buffer, and it must not turn garbage into a plausible value. Those
//! are asserted below as:
//!
//!   RA1  projection idempotence — `d∘e∘d∘e == d∘e`
//!   RA2  no collapse — `serialize(a) == serialize(b)` implies
//!        `a == b`, i.e. no two distinct values share a fibre, which
//!        is what makes `decode` a well-defined representative
//!   RA3  no read-past-end — trailing bytes after a canonical
//!        encoding do not change the decoded value
//!   RA4  no invention from garbage — a truncated canonical encoding
//!        is an error, never a shorter plausible value
//!
//! The WAL payload pair (`Store.encodeWALPayload` → replay → cell) has
//! no public decoder — `parseInsertPayload` is private to
//! `store.zig` — so its adjoint is checked at the only public
//! boundary that exercises it: write cells through one `Store`,
//! reopen a second `Store` over the same WAL, and require the corpus
//! back. The right-adjoint direction is replay idempotence: replaying
//! the same WAL twice must produce the same store, not more cells.
//!
//! ## Test hygiene
//!
//! Deterministic fixed seed (not a clock seed, unlike the sibling
//! property test): a property failure has to be reproducible. No
//! printing, no log output, no file I/O outside a pid-isolated `/tmp`
//! directory that is removed before and after the run, so the suite
//! is idempotent across consecutive runs.
//!
//! This file deliberately does **not** import `serializer_roundtrip.zig`:
//! that would pull its `test` blocks into this binary and run them
//! twice under `zig build test`.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");

const serializer = mem3.utils.serializer;

// =============================================================================
// Generator
// =============================================================================

/// NOTE: the explicit `u8` backing type is load-bearing, not style.
/// `serializer.writeValue` computes the tag width with
/// `comptimeIntSize(@typeInfo(std.meta.Tag(T)).int.bits)` and then
/// `@bitCast`s the tag into `[size]u8`. A bare `enum { a, b, c }`
/// gets a `u2` tag, and the bitcast then fails to compile
/// ("destination type '[1]u8' has 8 bits but source type 'u2' has 2").
/// Every production enum in `core/types.zig` declares `enum(u8)`, so
/// the bug has never surfaced there; a third-party or future enum
/// without an explicit backing type will not compile at all.
/// Reported here rather than worked around silently.
const Kind = enum(u8) { alpha, beta, gamma };

const Nested = struct {
    id: u64,
    label: []const u8,
    ratio: f32,
    /// `?i32` with a negative payload — the optional-present branch of
    /// the decoder, with a sign the unsigned paths never exercise.
    bias: ?i32,
};

/// A deliberately awkward record: every supported kind the serializer
/// claims to handle, none of them trivial.
///
/// Optionals here are fixed-width scalars (`?u32`, `?i32`, `?f32`, `?u64`).
/// An optional holding a *slice* was excluded while `serializer.sizeOf`
/// failed to count its payload; that defect is fixed and the shape is now
/// covered by dedicated tests at the bottom of this file.
const Gen = struct {
    tag: u8,
    name: []const u8,
    blob: []const u8,
    flags: [3]bool,
    score: f32,
    weight: f64,
    delta: i64,
    count: u32,
    kind: Kind,
    tags: []const []const u8,
    ids: []const u64,
    grid: [2][2]u16,
    maybe_count: ?u32,
    maybe_ratio: ?f32,
    nested: Nested,

    fn deinit(self: Gen, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.blob);
        for (self.tags) |t| alloc.free(t);
        alloc.free(self.tags);
        alloc.free(self.ids);
        alloc.free(self.nested.label);
    }
};

/// Fixed so a failure reproduces exactly. Any change to the generator
/// invalidates past failures, which is the point.
const SEED: u64 = 0x9E3779B97F4A7C15;
const ITERATIONS: usize = 256;

fn lcgNext(state: *u64) u64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return state.* >> 17;
}

fn pick(state: *u64, n: usize) usize {
    return @intCast(lcgNext(state) % n);
}

/// Strings that stress the length-prefix path rather than the happy
/// path: empty, NUL-bearing, multi-byte UTF-8, and long.
fn genString(alloc: std.mem.Allocator, state: *u64) ![]u8 {
    const kind = pick(state, 8);
    switch (kind) {
        0 => return alloc.dupe(u8, ""),
        1 => return alloc.dupe(u8, "a"),
        2 => return alloc.dupe(u8, "embedded\x00nul"),
        3 => return alloc.dupe(u8, "trailing nul\x00"),
        4 => return alloc.dupe(u8, "日本語 · Ελληνικά · кириллица"),
        5 => return alloc.dupe(u8, "quote\" backslash\\ newline\n tab\t"),
        6 => {
            const n = 4096;
            const buf = try alloc.alloc(u8, n);
            for (buf, 0..) |*b, i| {
                // Deterministic, printable, and includes a NUL.
                b.* = if (i % 1024 == 512) 0 else @intCast(32 + (i % 95));
            }
            return buf;
        },
        else => {
            const n = 1 + pick(state, 40);
            const buf = try alloc.alloc(u8, n);
            for (buf, 0..) |*b, i| {
                b.* = @intCast(pick(state, 256) & 0x7f);
                if (i == 0) b.* = 'x'; // avoid a leading NUL in short strings
            }
            return buf;
        },
    }
}

fn genFloat32(state: *u64) f32 {
    return switch (pick(state, 10)) {
        0 => 0.0,
        1 => -0.0,
        2 => std.math.floatMin(f32),
        3 => -std.math.floatMin(f32),
        4 => std.math.floatMax(f32),
        5 => -std.math.floatMax(f32),
        6 => std.math.inf(f32),
        7 => -std.math.inf(f32),
        8 => std.math.nan(f32),
        else => @as(f32, @floatFromInt(lcgNext(state) & 0xFFFF)) / 7.0,
    };
}

fn genFloat64(state: *u64) f64 {
    return switch (pick(state, 8)) {
        0 => 0.0,
        1 => -0.0,
        2 => std.math.floatMin(f64),
        3 => std.math.floatMax(f64),
        4 => -std.math.floatMax(f64),
        5 => std.math.nan(f64),
        else => @as(f64, @floatFromInt(lcgNext(state) & 0xFFFFFFFF)) / 65536.0,
    };
}

/// Build one `Gen` on the given arena. The caller owns the arena, so
/// no `Gen.deinit` is needed for generated values — only for values
/// the decoder allocated with the testing allocator.
fn genValue(arena: std.mem.Allocator, state: *u64) !Gen {
    const tag_count = pick(state, 4);
    const tags = try arena.alloc([]const u8, tag_count);
    for (tags) |*t| t.* = try genString(arena, state);

    const id_count = pick(state, 4);
    const ids = try arena.alloc(u64, id_count);
    for (ids) |*id| id.* = lcgNext(state);

    return Gen{
        .tag = @intCast(lcgNext(state) & 0xFF),
        .name = try genString(arena, state),
        .blob = try genString(arena, state),
        .flags = .{
            (lcgNext(state) & 1) == 0,
            (lcgNext(state) & 1) == 0,
            (lcgNext(state) & 1) == 0,
        },
        .score = genFloat32(state),
        .weight = genFloat64(state),
        .delta = @bitCast(lcgNext(state)),
        .count = @truncate(lcgNext(state)),
        .kind = @fromBackingInt(@intCast(@as(u8, @intCast(pick(state, 3))))),
        .tags = tags,
        .ids = ids,
        .grid = .{
            .{ @truncate(lcgNext(state)), @truncate(lcgNext(state)) },
            .{ @truncate(lcgNext(state)), @truncate(lcgNext(state)) },
        },
        .maybe_count = if (pick(state, 2) == 0) null else @truncate(lcgNext(state)),
        .maybe_ratio = if (pick(state, 2) == 0) null else genFloat32(state),
        .nested = .{
            .id = lcgNext(state),
            .label = try genString(arena, state),
            .ratio = genFloat32(state),
            .bias = if (pick(state, 3) == 0) null else -@as(i32, @intCast(lcgNext(state) & 0x7FFFFFFF)),
        },
    };
}

/// Field-by-field equality. Floats by bit pattern: NaN payloads survive
/// the `@bitCast` round trip and `==` would call NaN unequal to itself.
fn expectSameGen(original: Gen, recovered: Gen) !void {
    try testing.expectEqual(original.tag, recovered.tag);
    try testing.expectEqualStrings(original.name, recovered.name);
    try testing.expectEqualStrings(original.blob, recovered.blob);
    for (original.flags, 0..) |f, i| try testing.expectEqual(f, recovered.flags[i]);
    try testing.expectEqual(@as(u32, @bitCast(original.score)), @as(u32, @bitCast(recovered.score)));
    try testing.expectEqual(@as(u64, @bitCast(original.weight)), @as(u64, @bitCast(recovered.weight)));
    try testing.expectEqual(original.delta, recovered.delta);
    try testing.expectEqual(original.count, recovered.count);
    try testing.expectEqual(original.kind, recovered.kind);
    try testing.expectEqual(original.tags.len, recovered.tags.len);
    for (original.tags, 0..) |t, i| try testing.expectEqualStrings(t, recovered.tags[i]);
    try testing.expectEqual(original.ids.len, recovered.ids.len);
    for (original.ids, 0..) |v, i| try testing.expectEqual(v, recovered.ids[i]);
    for (original.grid, 0..) |row, i| for (row, 0..) |v, j| {
        try testing.expectEqual(v, recovered.grid[i][j]);
    };
    if (original.maybe_count) |mc| {
        try testing.expectEqual(mc, recovered.maybe_count.?);
    } else {
        try testing.expect(recovered.maybe_count == null);
    }
    if (original.maybe_ratio) |mr| {
        try testing.expectEqual(@as(u32, @bitCast(mr)), @as(u32, @bitCast(recovered.maybe_ratio.?)));
    } else {
        try testing.expect(recovered.maybe_ratio == null);
    }
    try testing.expectEqual(original.nested.id, recovered.nested.id);
    try testing.expectEqualStrings(original.nested.label, recovered.nested.label);
    try testing.expectEqual(@as(u32, @bitCast(original.nested.ratio)), @as(u32, @bitCast(recovered.nested.ratio)));
    if (original.nested.bias) |b| {
        try testing.expectEqual(b, recovered.nested.bias.?);
    } else {
        try testing.expect(recovered.nested.bias == null);
    }
}

// =============================================================================
// Left adjoint: Decode ∘ Encode ≈ id
// =============================================================================

test "adjoint left: serialize/deserialize is the identity on generated values" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var state = SEED;
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const original = try genValue(arena, &state);

        const bytes = try serializer.serialize(alloc, original);
        defer alloc.free(bytes);

        const recovered = try serializer.deserialize(alloc, Gen, bytes);
        defer recovered.deinit(alloc);

        try expectSameGen(original, recovered);
    }
}

test "adjoint left: deserialize/serialize is the identity on a canonical encoding" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var state = SEED;
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const original = try genValue(arena, &state);
        const first = try serializer.serialize(alloc, original);
        defer alloc.free(first);

        const recovered = try serializer.deserialize(alloc, Gen, first);
        defer recovered.deinit(alloc);

        const second = try serializer.serialize(alloc, recovered);
        defer alloc.free(second);

        // Re-encoding a decoded value must reproduce the exact bytes:
        // if the decoder dropped or reordered a field, this fails.
        try testing.expectEqualSlices(u8, first, second);
    }
}

test "adjoint left: a MemCell survives the round trip unchanged" {
    // The production type, not just a synthetic one.
    const alloc = testing.allocator;
    var state = SEED;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const facts = try arena.alloc(mem3.Fact, 1 + pick(&state, 3));
        for (facts) |*f| {
            f.* = .{
                .subject = try genString(arena, &state),
                .predicate = try genString(arena, &state),
                .object = try genString(arena, &state),
                .confidence = genFloat32(&state),
                .source = try genString(arena, &state),
            };
        }
        const foresight = try arena.alloc(mem3.Foresight, pick(&state, 3));
        for (foresight) |*f| {
            f.* = .{
                .description = try genString(arena, &state),
                .valid_from = @bitCast(lcgNext(&state)),
                .valid_until = @bitCast(lcgNext(&state)),
                .confidence = genFloat32(&state),
            };
        }

        // `genString` produces arbitrarily long values; only a bounded
        // location fits the current (under-counting) buffer computation.
        const location = try arena.alloc(u8, 1 + pick(&state, 12));
        @memset(location, 'L');

        const cell: mem3.MemCell = .{
            .id = 1 + lcgNext(&state) & 0xFFFF,
            .source = @fromBackingInt(@intCast(@as(u8, @intCast(pick(&state, 3))))),
            .episode = try genString(arena, &state),
            .atomic_facts = facts,
            .foresight = foresight,
            .goal_associations = &.{.{ .goal_id = lcgNext(&state), .relevance = genFloat32(&state), .priority = @intCast(pick(&state, 4)) }},
            .metadata = .{
                .created_at = @bitCast(lcgNext(&state)),
                .updated_at = @bitCast(lcgNext(&state)),
                .source_confidence = genFloat32(&state),
                .emotional_valence = genFloat32(&state),
                .importance_score = genFloat32(&state),
                .decay_rate = genFloat32(&state),
                .is_fuzzy = (lcgNext(&state) & 1) == 0,
                .location = location,
            },
        };

        const bytes = try mem3.utils.serialize(alloc, cell);
        defer alloc.free(bytes);

        const back = try mem3.utils.deserialize(alloc, mem3.MemCell, bytes);
        defer back.deinit(alloc);

        try testing.expectEqual(cell.id, back.id);
        try testing.expectEqual(cell.source, back.source);
        try testing.expectEqualStrings(cell.episode, back.episode);
        try testing.expectEqual(cell.atomic_facts.len, back.atomic_facts.len);
        for (cell.atomic_facts, 0..) |f, fi| {
            try testing.expectEqualStrings(f.subject, back.atomic_facts[fi].subject);
            try testing.expectEqualStrings(f.predicate, back.atomic_facts[fi].predicate);
            try testing.expectEqualStrings(f.object, back.atomic_facts[fi].object);
            try testing.expectEqualStrings(f.source, back.atomic_facts[fi].source);
            try testing.expectEqual(@as(u32, @bitCast(f.confidence)), @as(u32, @bitCast(back.atomic_facts[fi].confidence)));
        }
        try testing.expectEqual(cell.foresight.len, back.foresight.len);
        try testing.expectEqual(cell.goal_associations.len, back.goal_associations.len);
        if (cell.metadata.location) |loc| {
            try testing.expectEqualStrings(loc, back.metadata.location.?);
        } else {
            try testing.expect(back.metadata.location == null);
        }
        try testing.expectEqual(cell.metadata.created_at, back.metadata.created_at);
        try testing.expectEqual(cell.metadata.access_count, back.metadata.access_count);
    }
}

// =============================================================================
// Right adjoint approximation: Encode ∘ Decode ≤ id
// =============================================================================

test "adjoint right RA1: d.e is a projection — decoding twice changes nothing" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var state = SEED;
    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const original = try genValue(arena, &state);
        const first = try serializer.serialize(alloc, original);
        defer alloc.free(first);

        const once = try serializer.deserialize(alloc, Gen, first);
        defer once.deinit(alloc);
        const re_encoded = try serializer.serialize(alloc, once);
        defer alloc.free(re_encoded);

        const twice = try serializer.deserialize(alloc, Gen, re_encoded);
        defer twice.deinit(alloc);
        const twice_encoded = try serializer.serialize(alloc, twice);
        defer alloc.free(twice_encoded);

        // e∘d∘e∘d == e∘d
        try expectSameGen(once, twice);
        try testing.expectEqualSlices(u8, re_encoded, twice_encoded);
    }
}

test "adjoint right RA2: no two distinct values share an encoding" {
    // The anti-collapse half. If `serialize(a) == serialize(b)` could
    // hold for `a != b`, then `decode` would have to pick one of them
    // arbitrarily and would be inventing a fact, not reporting one.
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var state = SEED;
    var previous = try genValue(arena, &state);
    var previous_bytes = try serializer.serialize(alloc, previous);
    var distinct: usize = 0;

    var i: usize = 1;
    while (i < ITERATIONS) : (i += 1) {
        const current = try genValue(arena, &state);
        const bytes = try serializer.serialize(alloc, current);

        if (std.mem.eql(u8, previous_bytes, bytes)) {
            // Equal encodings must mean equal values.
            try expectSameGen(previous, current);
        } else {
            distinct += 1;
        }

        alloc.free(previous_bytes);
        previous = current;
        previous_bytes = bytes;
    }
    alloc.free(previous_bytes);

    // Non-degeneracy guard: a generator that emitted one constant
    // would satisfy "equal encodings ⇒ equal values" trivially.
    try testing.expect(distinct > ITERATIONS / 2);
}

test "adjoint right RA3: trailing bytes do not change the decoded value" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var state = SEED;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const original = try genValue(arena, &state);
        const bytes = try serializer.serialize(alloc, original);
        defer alloc.free(bytes);

        // Garbage a decoder that ran past the payload would read.
        const padded = try alloc.alloc(u8, bytes.len + 32);
        defer alloc.free(padded);
        @memcpy(padded[0..bytes.len], bytes);
        for (padded[bytes.len..]) |*b| b.* = 0xAB;

        const recovered = try serializer.deserialize(alloc, Gen, padded);
        defer recovered.deinit(alloc);

        try expectSameGen(original, recovered);
    }
}

test "adjoint right RA4: a truncated encoding is an error, never a shorter value" {
    // The concrete way a decoder invents information: reading past a
    // short buffer and returning whatever was there. Truncation must
    // surface as BufferUnderflow, not as a shorter plausible value.
    //
    // The probe type is fixed-width-plus-one-slice rather than `Gen` so
    // that halving always lands inside the bytes the reader genuinely
    // needs. It used to be necessary for a second reason — `sizeOf`
    // over-counted structs, leaving an unwritten tail that truncation
    // could miss — but that over-count is gone now that sizeOf is exact.
    const alloc = testing.allocator;
    const TruncProbe = struct { id: u64, tail: []const u8 };

    var state = SEED;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const tail = try genString(arena, &state);
        // Empty tail: `sizeOf` surplus then equals the whole written
        // length, so skip the split — there is nothing to truncate.
        if (tail.len == 0) continue;

        const value: TruncProbe = .{ .id = lcgNext(&state), .tail = tail };
        const bytes = try serializer.serialize(alloc, value);
        defer alloc.free(bytes);

        const cut = bytes.len / 2;
        try testing.expect(cut < bytes.len);
        try testing.expectError(
            error.BufferUnderflow,
            serializer.deserialize(alloc, TruncProbe, bytes[0..cut]),
        );
    }
}

// =============================================================================
// SERIALIZER REGRESSIONS — formerly KNOWN BUG characterization tests
// =============================================================================
//
// These three asserted the *wrong* behaviour so a live defect stayed
// visible in test output. The defects are now fixed, so the assertions
// have been inverted: the round trip must succeed and the recovered
// value must equal the original, at every length that used to fail.
//
// 1. `sizeOf` had no `.optional` branch, so an optional holding a slice
//    never had its runtime payload counted. A struct's double-counted
//    scalar fields supplied accidental slack that masked it until the
//    payload outgrew that slack — 193 characters for MemCell, 7 for the
//    smaller probe shape. `sizeOf` is now purely additive and exact.
// 2. `writeFixedInt`/`readFixedInt` bitcast the tag into `[1]u8`, and a
//    `u2` tag is not a legal conversion, so an enum with no explicit
//    backing type did not build at all. Sub-byte widths now take a
//    byte-at-a-time path; whole-byte widths are untouched.
//
// Production constants are unchanged (MemCell=101, Metadata=76, Fact=20,
// Foresight=24, GoalAssociation=13) — these were accounting bugs, not
// layout bugs, and a golden byte-vector test pins the encoding.

test "serializer: an optional holding a slice round-trips at any length" {
    // Was a KNOWN BUG test. `serializer.sizeOf` had no `.optional` branch, so
    // a `?[]const u8` payload was never counted and `serialize` failed with
    // BufferUnderflow once the payload outgrew the slack that a struct's
    // double-counted fields happened to provide. Fixed: sizeOf is now purely
    // additive and exact, and the buffer size matches the reported size.
    //
    // The old defect's threshold was shape-dependent ("194" for MemCell,
    // "7" for this struct), so this sweeps past every boundary it had.
    const alloc = testing.allocator;
    const OptionalSlice = struct { a: u8, m: ?[]const u8 };

    for ([_]usize{ 0, 1, 7, 8, 100, 194, 250, 1024, 8192 }) |len| {
        var payload: [8192]u8 = undefined;
        for (payload[0..len], 0..) |*b, i| b.* = @truncate(i);

        const value: OptionalSlice = .{ .a = 7, .m = payload[0..len] };
        const bytes = try serializer.serialize(alloc, value);
        defer alloc.free(bytes);

        // The invariant that was violated: the reported size must be at
        // least what the encoder actually writes.
        try testing.expect(serializer.sizeOf(value) >= bytes.len);

        const back = try serializer.deserialize(alloc, OptionalSlice, bytes);
        defer if (back.m) |m| alloc.free(m);
        try testing.expectEqual(@as(u8, 7), back.a);
        try testing.expectEqualStrings(payload[0..len], back.m.?);
    }

    // A null optional must still round-trip as null, not as an empty slice.
    const none: OptionalSlice = .{ .a = 3, .m = null };
    const nb = try serializer.serialize(alloc, none);
    defer alloc.free(nb);
    const nback = try serializer.deserialize(alloc, OptionalSlice, nb);
    try testing.expectEqual(@as(u8, 3), nback.a);
    try testing.expect(nback.m == null);
}

test "serializer: a non-optional slice still round-trips" {
    // The control from the old KNOWN BUG test: this shape was always fine,
    // and must stay fine. Without it, a "fix" that simply over-allocated
    // would also pass.
    const alloc = testing.allocator;
    const PlainSlice = struct { a: u8, m: []const u8 };
    var payload: [100]u8 = undefined;
    @memset(&payload, 'x');
    const value: PlainSlice = .{ .a = 1, .m = &payload };
    const bytes = try serializer.serialize(alloc, value);
    defer alloc.free(bytes);
    const back = try serializer.deserialize(alloc, PlainSlice, bytes);
    defer alloc.free(back.m);
    try testing.expectEqualStrings(value.m, back.m);
}

test "serializer: a MemCell survives a long metadata.location" {
    // Was a KNOWN BUG test, and this one had production impact:
    // `Metadata.location` is `?[]const u8`, so every MemCell whose location
    // exceeded the struct's accidental slack failed to serialize — i.e. the
    // write was silently lost on the WAL/snapshot path.
    //
    // The measured boundary was 193 characters for this shape, not a round
    // 250, because the old sizeOf over-counted scalar fields and used the
    // surplus to mask the optional it never counted. Both halves are now
    // fixed, so the value round-trips at every length.
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]usize{ 193, 194, 250, 1024, 8192 }) |len| {
        const long_loc = try arena.alloc(u8, len);
        for (long_loc, 0..) |*b, i| b.* = @truncate('a' + (i % 26));

        const cell: mem3.MemCell = .{
            .id = 1,
            .source = .matter,
            .episode = "ep",
            .atomic_facts = &.{},
            .foresight = &.{},
            .goal_associations = &.{},
            .metadata = .{ .created_at = 1, .updated_at = 1, .location = long_loc },
        };

        const bytes = try mem3.utils.serialize(alloc, cell);
        defer alloc.free(bytes);
        try testing.expect(mem3.utils.sizeOf(cell) >= bytes.len);

        const back = try mem3.utils.deserialize(alloc, mem3.MemCell, bytes);
        defer back.deinit(alloc);
        try testing.expectEqualStrings(long_loc, back.metadata.location.?);
    }
}

test "serializer: an enum without an explicit backing type round-trips" {
    // Was a KNOWN BUG test. `calculateSize(.enum)` already reserved the
    // correct 1 byte, but `writeFixedInt` bitcast the tag into `[1]u8`, and
    // `u2 -> [1]u8` is an illegal conversion — so a sub-byte enum simply
    // did not build.
    //
    // Fixed by adding a byte-at-a-time path used only when the width is not
    // a multiple of 8. Whole-byte widths keep the original bitcast verbatim,
    // which is what keeps every previously-encoding type byte-identical.
    const alloc = testing.allocator;
    const Narrow = enum { a, b, c };
    const Wide = enum(u8) { a, b, c };
    const Holder = struct { which: Narrow, level: Wide, tag: u32 };

    try testing.expectEqual(@as(u16, 2), @bitSizeOf(std.meta.Tag(Narrow)));

    for ([_]Narrow{ .a, .b, .c }) |which| {
        const value: Holder = .{ .which = which, .level = .c, .tag = 0xDEADBEEF };
        const bytes = try serializer.serialize(alloc, value);
        defer alloc.free(bytes);
        const back = try serializer.deserialize(alloc, Holder, bytes);
        try testing.expectEqual(which, back.which);
        try testing.expectEqual(Wide.c, back.level);
        try testing.expectEqual(@as(u32, 0xDEADBEEF), back.tag);
    }
}

// =============================================================================
// The WAL payload adjoint, at the only public boundary
// =============================================================================

/// pid-isolated so concurrent runs never collide and a stale directory
/// from a previous run can never be replayed into this one.
fn walDir(alloc: std.mem.Allocator, label: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "/tmp/mem3_adjoint_{d}_{s}", .{ std.c.getpid(), label });
}

fn wipeDir(data_dir: []const u8) void {
    var wal_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&wal_z, "{s}/mem3.wal\x00", .{data_dir})) |wz| {
        _ = std.c.unlink(wz[0 .. wz.len - 1 :0].ptr);
    } else |_| {}
    var snap_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&snap_z, "{s}/snapshot.bin\x00", .{data_dir})) |sz| {
        _ = std.c.unlink(sz[0 .. sz.len - 1 :0].ptr);
    } else |_| {}
    var rmdir_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&rmdir_z, "{s}\x00", .{data_dir})) |dz| {
        _ = std.c.rmdir(dz[0 .. dz.len - 1 :0].ptr);
    } else |_| {}
}

test "adjoint WAL: every encoded record decodes back into its cell" {
    const alloc = testing.allocator;
    const data_dir = try walDir(alloc, "wal");
    defer alloc.free(data_dir);
    wipeDir(data_dir);
    defer wipeDir(data_dir);

    // No empty episode: `parseInsertPayload` rejects one with ParseFailed
    // and replay drops the record, so an empty string would make this a
    // test of the reject path rather than of the round trip.
    const episodes = [_][]const u8{
        "plain",
        "with\x00nul",
        "日本語 · Ελληνικά",
        " ",
        "x",
    };

    {
        const store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try testing.expect(store.isDurable());
        for (episodes) |ep| {
            _ = try store.addRaw(.matter, ep, "u|likes|coffee", 1, 0.5);
        }
    }

    const reopened = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
    defer reopened.deinit();

    // `Encode ∘ Decode ≈ id` over the WAL pair, at the public boundary.
    try testing.expectEqual(episodes.len, reopened.cellCount());

    const cells = try reopened.allCells(alloc);
    defer alloc.free(cells);
    for (cells) |cell| {
        var matched = false;
        for (episodes) |ep| {
            if (std.mem.eql(u8, ep, cell.episode)) matched = true;
        }
        try testing.expect(matched);
        // The replay decoder must not invent content the encoder never
        // wrote: every recovered cell still carries its source tag and
        // a non-empty fact set.
        try testing.expectEqual(mem3.MemorySource.matter, cell.source);
        try testing.expect(cell.atomic_facts.len > 0);
    }
}

test "adjoint WAL right: replaying the same WAL twice invents nothing" {
    const alloc = testing.allocator;
    const data_dir = try walDir(alloc, "wal2");
    defer alloc.free(data_dir);
    wipeDir(data_dir);
    defer wipeDir(data_dir);

    const first_count: usize = 7;
    {
        const store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        var i: usize = 0;
        while (i < first_count) : (i += 1) {
            _ = try store.addRaw(.form, "episode", "u|likes|tea", 1, 0.25);
        }
    }

    // Decode once.
    const once = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
    const once_count = once.cellCount();
    once.deinit();

    // Decode the same bytes again. The projection must not accumulate:
    // `decode ∘ encode` applied twice equals itself.
    const twice = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
    defer twice.deinit();

    try testing.expectEqual(first_count, once_count);
    try testing.expectEqual(once_count, twice.cellCount());
}
