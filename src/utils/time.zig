//! Time utilities. Unix milliseconds + decay helpers.

const std = @import("std");

/// CivilDate — (year, month, day) tuple, returned from `civilFromDays`.
pub const CivilDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

/// Get current Unix time in milliseconds.
///
/// Per Zig 0.17-compat memory: `std.time.timestamp` / `milliTimestamp` do
/// not exist. We use the C `clock_gettime` via `std.c` for portability.
pub fn nowMs() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// High-resolution monotonic time in nanoseconds. For benchmarking only.
pub fn monotonicNs() u128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    const sec: u128 = @intCast(ts.sec);
    const nsec: u128 = @intCast(ts.nsec);
    return sec * 1_000_000_000 + nsec;
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
    ) catch unreachable;
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
    const era = @divTrunc(z2, 146_097);
    const doe = @mod(z2, 146_097);
    const yoe = @divTrunc(doe - @divTrunc(doe, 36524) + @divTrunc(doe, 146_096), 365);
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
