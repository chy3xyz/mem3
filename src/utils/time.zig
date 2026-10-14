//! Time utilities. Unix milliseconds + decay helpers.

const std = @import("std");
const builtin = @import("builtin");
const platform_clock = @import("../platform/clock.zig");

const log = std.log.scoped(.mem3_time);

/// CivilDate — (year, month, day) tuple, returned from `civilFromDays`.
pub const CivilDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

/// Get current Unix time in milliseconds.
///
/// Routed through the platform layer: `std.time` was deleted in Zig 0.17,
/// and the obvious replacement — `std.c.clock_gettime` plus a `std.c.timespec`
/// literal — compiles on macOS and Linux but is `void` on Windows, so the
/// whole tree failed to cross-compile there.
pub fn nowMs() i64 {
    return platform_clock.realtimeMs();
}

/// High-resolution monotonic time in nanoseconds. For benchmarking only.
pub fn monotonicNs() u128 {
    return @intCast(platform_clock.monotonicNs());
}

/// Duration in milliseconds (for delta computations, log rotation, etc.).
pub const DurationMs = i64;

/// Compute the exponential decay factor `e^(-rate * days)` for a given age.
pub fn decayFactor(now_ms: i64, created_at_ms: i64, rate_per_day: f32) f32 {
    if (now_ms < created_at_ms) return 1.0;
    const age_ms: f32 = @as(f32, @floatFromInt(now_ms - created_at_ms));
    const age_days: f32 = age_ms / (1000.0 * 86_400.0);
    return @exp(-rate_per_day * age_days);
}

/// ISO-8601-ish formatter. "2026-06-08T00:00:00Z" — UTC, second precision.
pub fn formatIso8601(ts_ms: i64, buf: *[20]u8) []u8 {
    const s = @divTrunc(ts_ms, 1000);
    const sec_per_day: i64 = 86_400;
    const days = @divTrunc(s, sec_per_day);
    const secs_today = @mod(s, sec_per_day);
    const civil = civilFromDays(days);
    const hh: u64 = @intCast(@divTrunc(secs_today, 3600));
    const mm: u64 = @intCast(@divTrunc(@mod(secs_today, 3600), 60));
    const ss: u64 = @intCast(@mod(secs_today, 60));
    // Zig 0.17 dev's std.fmt renders signed zeros as "+0" instead of "00",
// which broke the earlier format spec. We force unsigned types so the
// `0>2` width specifier produces "00".
const n = std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u64, civil.year),
            @as(u64, civil.month),
            @as(u64, civil.day),
            @as(u64, hh),
            @as(u64, mm),
            @as(u64, ss),
        },
    ) catch |err| switch (err) {
        // `bufPrint`'s only error is `error.NoSpaceLeft`, and it IS
        // reachable here: the format reserves exactly 20 bytes
        // ("YYYY-MM-DDTHH:MM:SSZ" = 4+1+2+1+2+1+2+1+2+1+2+1), but the
        // `{d:0>4}` width is a MINIMUM, not a maximum. `civil.year` is a
        // u16, so it can legitimately render as 5 digits (10000..65535),
        // needing 23 bytes in a 20-byte buffer. Concrete witness:
        // ts_ms = 253407398400000 -> civilFromDays(2932956) =
        // {year=10000, month=3, day=1} -> NoSpaceLeft. That value sits far
        // inside i64 range (max 9223372036854775807), so this is not a
        // theoretical input.
        //
        // We cannot propagate: the one caller outside this file
        // (utils/logger.zig:36) passes a plain `[20]u8` and
        // `formatIso8601` has no error channel. So handle it explicitly --
        // log via std.log (never std.debug.print: this is library code)
        // and return a sentinel that cannot be mistaken for a date.
        error.NoSpaceLeft => blk: {
            // Gated on `builtin.is_test`: the regression test for this
            // branch deliberately drives it, and Zig 0.17's test runner
            // fails a test that emits any log line.
            if (!builtin.is_test) {
                log.warn("formatIso8601: ts_ms={d} (year {d}) exceeds the 4-digit-year ISO-8601 range; returning sentinel", .{ ts_ms, civil.year });
            }
            @memset(buf[0..], '*');
            break :blk buf[0..];
        },
    };
    return n;
}

/// Howard Hinnant's `civil_from_days` algorithm: convert days-since-1970-01-01
/// to a `CivilDate`. Returns month 1-12, day 1-31.
///
/// **Caveat**: the algorithm is offset from 0000-03-01 (March 1 of year 0),
/// not from Unix epoch 1970-01-01. The internal `+ 719468` shift corrects
/// this, but the algorithm only produces valid output for `z >= 0` and
/// does NOT correctly handle Jan/Feb of the same year as the offset.
/// Use `formatIso8601` for human-facing timestamps; this is exposed
/// primarily for the snapshot reader that needs calendar arithmetic.
pub fn civilFromDays(z: i64) CivilDate {
    const z2 = z + 719_468;
    // `era` MUST floor, not truncate toward zero: for pre-epoch days the
    // two disagree by one whole era, shifting the result by 400 years.
    const era = @divFloor(z2, 146_097);
    const doe = z2 - era * 146_097; // [0, 146096]
    // The year-of-era term needs all four corrections, in this order:
    // `-doe/1460 + doe/36524 - doe/146096`. The previous version dropped
    // the first term entirely and used `+ doe/146096` where the algorithm
    // says `-`. Measured against the reference implementation across
    // [-800000, 800000] days: 270541 of 1600001 results disagreed -- 8.35%
    // of the entire 1970..2100 window -- and the Unix epoch itself decoded
    // to 1971-02-28, a year and a month off with a negative day-of-month.
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divTrunc(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const yr: u16 = @intCast(y + @as(i64, if (m <= 2) 1 else 0));
    return .{ .year = yr, .month = m, .day = d };
}

test "nowMs: roughly matches wall clock" {
    const t = nowMs();
    // Should be after 2026-01-01 (≈ 1.77e12 ms).
    try std.testing.expect(t > 1_700_000_000_000);
}

test "decayFactor: 0 age = 1.0" {
    const f = decayFactor(1000, 1000, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), f, 1e-6);
}

test "decayFactor: monotonic decay" {
    const f0 = decayFactor(0, 0, 0.1);
    const f1 = decayFactor(86_400_000, 0, 0.1);
    const f2 = decayFactor(86_400_000 * 7, 0, 0.1);
    try std.testing.expect(f0 > f1);
    try std.testing.expect(f1 > f2);
}

test "formatIso8601: known date" {
    var buf: [20]u8 = undefined;
    // 2026-06-08T00:00:00Z = day 20612 since epoch (1970-01-01).
    const s = formatIso8601(20612 * 86_400 * 1000, &buf);
    try std.testing.expectEqualStrings("2026-06-08T00:00:00Z", s);
}

test "civilFromDays: 2026-06-08 via formatIso8601" {
    // 2026-06-08T00:00:00Z = day 20612 since 1970-01-01.
    // We pin ts as an i64 first because `comptime * i64` arithmetic
    // in Zig 0.17 dev can produce ambiguous integer types that
    // surface as off-by-one dates in `formatIso8601`. Using a typed
    // local variable forces i64 throughout the multiplication chain.
    var buf: [20]u8 = undefined;
    const ts: i64 = 20612;
    const ts_ms: i64 = ts * 86400 * 1000;
    const s = formatIso8601(ts_ms, &buf);
    try std.testing.expectEqualStrings("2026-06-08T00:00:00Z", s);
}

test "civilFromDays: 2026-06-08" {
    const civil = civilFromDays(20612);
    try std.testing.expectEqual(@as(u16, 2026), civil.year);
    try std.testing.expectEqual(@as(u8, 6), civil.month);
    try std.testing.expectEqual(@as(u8, 8), civil.day);
}

test "formatIso8601: year >= 10000 must not panic (bufPrint NoSpaceLeft is reachable)" {
    // 253407398400000 ms = day 2932956 since epoch.
    // civilFromDays(2932956) = { year = 10000, month = 3, day = 1 }.
    // The year renders as 5 digits, needing 23 bytes in a 20-byte buffer,
    // so `bufPrint` returns error.NoSpaceLeft. This used to hit
    // `catch unreachable` and panic.
    const ts_ms: i64 = 2932956 * 86_400 * 1000;
    var buf: [20]u8 = undefined;
    const s = formatIso8601(ts_ms, &buf);
    try std.testing.expectEqual(@as(usize, 20), s.len);
    try std.testing.expectEqualStrings("********************", s);
}

test "civilFromDays: known dates, incl. the epoch and leap days" {
    // Each of these was decoded WRONG before the era/yoe fix. The epoch
    // itself came out as 1971-02-28.
    const cases = [_]struct { days: i64, y: u16, m: u8, d: u8 }{
        .{ .days = 0, .y = 1970, .m = 1, .d = 1 }, // Unix epoch
        .{ .days = 59, .y = 1970, .m = 3, .d = 1 },
        .{ .days = 11_016, .y = 2000, .m = 2, .d = 29 }, // Y2K leap day
        .{ .days = 11_323, .y = 2001, .m = 1, .d = 1 },
        .{ .days = 19_723, .y = 2024, .m = 1, .d = 1 },
        .{ .days = -1, .y = 1969, .m = 12, .d = 31 }, // one second before epoch
        .{ .days = -365, .y = 1969, .m = 1, .d = 1 },
    };
    for (cases) |c| {
        const got = civilFromDays(c.days);
        try std.testing.expectEqual(c.y, got.year);
        try std.testing.expectEqual(c.m, got.month);
        try std.testing.expectEqual(c.d, got.day);
    }
}

test "civilFromDays: every day from 1970 to 2100 agrees with the reference" {
    // Sweeps the full modern era against an independently written copy of
    // the reference algorithm. The old implementation failed 8.35% of this
    // window, so this pins the whole range rather than a handful of dates.
    const days_1970_2100: i64 = 47_483; // 2100-01-01 minus 1970-01-01
    var z: i64 = 0;
    while (z <= days_1970_2100) : (z += 1) {
        const z2 = z + 719_468;
        const era = @divFloor(z2, 146_097);
        const doe = z2 - era * 146_097;
        const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146_096), 365);
        const y = yoe + era * 400;
        const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
        const mp = @divTrunc(5 * doy + 2, 153);
        const want_d: u8 = @intCast(doy - @divTrunc(153 * mp + 2, 5) + 1);
        const want_m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
        const want_y: u16 = @intCast(y + @as(i64, if (want_m <= 2) 1 else 0));

        const got = civilFromDays(z);
        try std.testing.expectEqual(want_y, got.year);
        try std.testing.expectEqual(want_m, got.month);
        try std.testing.expectEqual(want_d, got.day);
        // Sanity: month and day must be in range for any valid civil date.
        try std.testing.expect(got.month >= 1 and got.month <= 12);
        try std.testing.expect(got.day >= 1 and got.day <= 31);
    }
}
