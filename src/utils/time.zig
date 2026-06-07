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
/// Per Zig 0.17-compat memory: `std.time.milliTimestamp` does not exist.
/// Use `std.time.timestamp` (seconds) and multiply.
pub fn nowMs() i64 {
    const s = std.time.timestamp();
    return s * 1000;
}

/// High-resolution monotonic time in nanoseconds. For benchmarking only.
pub fn monotonicNs() u128 {
    return std.time.nanoTimestamp();
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
    const hh = @divTrunc(secs_today, 3600);
    const mm = @divTrunc(@mod(secs_today, 3600), 60);
    const ss = @mod(secs_today, 60);
    const n = std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{ civil.year, civil.month, civil.day, hh, mm, ss },
    ) catch unreachable;
    return n;
}

/// Howard Hinnant's `civil_from_days` algorithm: convert days-since-1970-01-01
/// to a `CivilDate`. Returns month 1-12, day 1-31.
pub fn civilFromDays(z: i64) CivilDate {
    const z2 = z + 719_468;
    const era = @divTrunc(z2, 146_097);
    const doe = @mod(z2, 146_097);
    const yoe = @divTrunc(doe - @divTrunc(doe, 36524) + @divTrunc(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
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

test "formatIso8601: known epoch" {
    var buf: [20]u8 = undefined;
    const s = formatIso8601(0, &buf);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", s);
}

test "civilFromDays: 0 = 1970-01-01" {
    const civil = civilFromDays(0);
    try std.testing.expectEqual(@as(u16, 1970), civil.year);
    try std.testing.expectEqual(@as(u8, 1), civil.month);
    try std.testing.expectEqual(@as(u8, 1), civil.day);
}

test "civilFromDays: 2026-06-08" {
    // 2026-01-01 = day 20489 from 1970-01-01 (56 * 365 + 14 leap days = 20454... )
    // Easier: compute from the formatter test
    var buf: [20]u8 = undefined;
    // 2026-06-08T00:00:00Z = ?
    // Compute: year 2026 starts at days (2026-1970)*365 + leap days
    // leap years: 1972, 1976, ..., 2024 (14 of them) = 56 years
    // 56 * 365 + 14 = 20440 + 14 = 20454 days = 2026-01-01
    // June 8 = +31+28+31+30+31+7 = 158 days from Jan 1 = day 20454 + 157 = 20611
    const s = formatIso8601(20611 * 86_400 * 1000, &buf);
    try std.testing.expectEqualStrings("2026-06-08T00:00:00Z", s);
}
