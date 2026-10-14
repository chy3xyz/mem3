//! Portability layer: wall clock and monotonic clock.
//!
//! Why this file exists: Zig 0.17 deleted `std.time`, so every timing call in
//! the project reached for `std.c.clock_gettime` and `std.c.timespec`
//! directly. That compiles on macOS and Linux, but on Windows both
//! `std.c.clock_gettime` and `std.c.timespec` are `void` — the Windows libc
//! has no POSIX clock API. The error a developer sees is
//! `type 'void' does not support struct initialization syntax`, which points
//! nowhere near the actual cause.
//!
//! Everything above this file asks for a clock in milliseconds and gets one,
//! regardless of target.
//!
//! Scope: macOS and Linux. The Windows implementation below is retained but
//! not compiled, not tested and not maintained — see `src/platform/mod.zig`
//! for why Windows was withdrawn.
//!
//! Semantics, kept deliberately boring:
//!   - `realtimeMs` is wall-clock milliseconds. It can jump when the system
//!     clock is adjusted, so it is for timestamps humans read.
//!   - `monotonicNs` never goes backwards. It is for measuring durations.
//!     Mixing the two up is how a benchmark ends up reporting negative
//!     latencies, so they are not interchangeable.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

/// Windows kernel32 imports. Zig 0.17's `std.os.windows` does not re-export
/// these under discoverable names in every build, and the signatures are
/// stable CRT/Win32 ABI, so they are declared here rather than guessed at.
const win32 = struct {
    extern "kernel32" fn QueryPerformanceCounter(lp_counter: *i64) callconv(.winapi) c_int;
    extern "kernel32" fn QueryPerformanceFrequency(lp_freq: *i64) callconv(.winapi) c_int;
    extern "kernel32" fn GetSystemTimeAsFileTime(lp: *u64) callconv(.winapi) void;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
};

/// Windows FILETIME is 100ns intervals since 1601-01-01 UTC. To get Unix
/// epoch milliseconds, subtract the 1601→1970 offset (11644473600 s) and
/// divide by 10_000. Getting this constant wrong yields dates near 1601 or
/// near 58000, which is the usual symptom.
const windows_epoch_offset_ms: u64 = 11_644_473_600_000;

fn posixRealtimeNs() i128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

fn posixMonotonicNs() i128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

fn windowsRealtimeMs() i64 {
    var ft: u64 = 0;
    win32.GetSystemTimeAsFileTime(&ft);
    const ms = ft / 10_000;
    return @intCast(ms - windows_epoch_offset_ms);
}

fn windowsMonotonicNs() i128 {
    var freq: i64 = 0;
    if (win32.QueryPerformanceFrequency(&freq) != 0 or freq == 0) return 0;
    var counter: i64 = 0;
    if (win32.QueryPerformanceCounter(&counter) != 0) return 0;
    return @divTrunc(@as(i128, counter) * 1_000_000_000, freq);
}

/// Wall-clock milliseconds since the Unix epoch. May jump backwards if the
/// system clock is adjusted; never use it to measure a duration.
pub fn realtimeMs() i64 {
    if (is_windows) return windowsRealtimeMs();
    return @intCast(@divTrunc(posixRealtimeNs(), 1_000_000));
}

/// Monotonic nanoseconds from an unspecified origin. Only differences between
/// two readings are meaningful.
pub fn monotonicNs() i128 {
    if (is_windows) return windowsMonotonicNs();
    return posixMonotonicNs();
}

/// Convenience wrapper for measuring a duration.
pub const Timer = struct {
    /// Named `started_at` rather than `start` because Zig has no method
    /// overloading and a field named `start` collides with `start()`.
    started_at: i128,

    pub fn start() Timer {
        return .{ .started_at = monotonicNs() };
    }

    pub fn elapsedNs(self: Timer) i128 {
        return monotonicNs() - self.started_at;
    }

    pub fn elapsedUs(self: Timer) i64 {
        return @intCast(@divTrunc(self.elapsedNs(), 1_000));
    }

    pub fn elapsedMs(self: Timer) i64 {
        return @intCast(@divTrunc(self.elapsedNs(), 1_000_000));
    }
};

pub fn sleepMs(ms: u64) void {
    if (is_windows) {
        win32.Sleep(@intCast(ms));
        return;
    }
    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    // Retry on EINTR with the remaining time the kernel hands back. A bare
    // one-shot sleep here silently returns early under signal load, which is
    // exactly the sort of thing that makes a daemon's "every 60 seconds"
    // quietly become "every 43 seconds".
    while (true) {
        var rem: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        const rc = nanosleep(&req, &rem);
        if (rc == 0) return;
        req = rem;
    }
}

const nanosleep = struct {
    extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;
}.nanosleep;

test "monotonic clock never goes backwards" {
    var last = monotonicNs();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const now = monotonicNs();
        try std.testing.expect(now >= last);
        last = now;
    }
}

test "realtime clock is a sane Unix epoch" {
    // If the FILETIME epoch offset is wrong this lands in 1601 or ~58000.
    // 1_700_000_000_000 ms is 2023-11-14, comfortably inside any correct
    // implementation's range and comfortably outside a broken one's.
    const ms = realtimeMs();
    try std.testing.expect(ms > 1_700_000_000_000);
    try std.testing.expect(ms < 4_000_000_000_000);
}

test "Timer measures a non-zero, monotonic duration" {
    var t = Timer.start();
    var acc: u64 = 0;
    var i: usize = 0;
    while (i < 100_000) : (i += 1) acc +%= i;
    const first = t.elapsedNs();
    try std.testing.expect(first > 0);
    // Keep the optimizer honest about `acc`.
    try std.testing.expect(acc > 0);
    t = Timer.start();
    var j: usize = 0;
    while (j < 100_000) : (j += 1) acc +%= j;
    try std.testing.expect(t.elapsedNs() > 0);
}
