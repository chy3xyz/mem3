//! Portability layer: graceful-termination signals (SIGINT / SIGTERM).
//!
//! Scope: macOS and Linux, via POSIX `sigaction`. Windows and WASM are
//! refused at compile time by `fs.zig` / `lib.zig`; there is no console-ctrl
//! branch here because there is no Windows daemon to receive one.
//!
//! ## Model
//!
//! The handler does the only thing a signal handler may safely do: store one
//! integer into a lock-free atomic. The daemon and the MCP loop *poll* that
//! flag (`terminationRequested`) between units of work and shut down on
//! their own stack, where taking locks, joining threads and flushing the WAL
//! are legal.
//!
//! The handlers are installed **without `SA_RESTART`**, so a blocking
//! `accept` / `read` / `poll` returns `EINTR` instead of resuming. That is
//! what makes a signal wake a daemon that is parked on a socket. It is not
//! sufficient on its own — a signal landing between the flag check and the
//! blocking call would be missed until the next wakeup — so callers block in
//! `waitReadable` with a short timeout rather than indefinitely.
//!
//! ## State is process-global
//!
//! A signal handler has no closure; the flag *has* to be a global. That is
//! the one deliberate exception to "no hidden globals", and it holds a single
//! atomic integer, not allocator or store state.

const std = @import("std");

/// Signal number that asked us to stop, 0 if none. Written from the handler.
var term_signal: std.atomic.Value(c_int) = .init(0);

fn onSignal(sig: std.c.SIG) callconv(.c) void {
    term_signal.store(@intCast(@intFromEnum(sig)), .release);
}

pub const Error = error{SigactionFailed};

/// Route SIGINT and SIGTERM to the termination flag.
pub fn installTermHandlers() Error!void {
    var act = std.mem.zeroes(std.c.Sigaction);
    act.handler = .{ .handler = onSignal };
    // Zero flags: no SA_RESTART. See the module doc for why that matters.
    act.flags = 0;
    if (std.c.sigaction(.INT, &act, null) != 0) return error.SigactionFailed;
    if (std.c.sigaction(.TERM, &act, null) != 0) return error.SigactionFailed;
}

/// Put SIGINT and SIGTERM back to their default disposition.
pub fn restoreDefaultHandlers() void {
    var act = std.mem.zeroes(std.c.Sigaction);
    act.handler = .{ .handler = null };
    act.flags = 0;
    // SIG_DFL is the null handler on every supported target.
    _ = std.c.sigaction(.INT, &act, null);
    _ = std.c.sigaction(.TERM, &act, null);
}

/// True once SIGINT or SIGTERM has been delivered.
pub fn terminationRequested() bool {
    return term_signal.load(.acquire) != 0;
}

/// The signal number that requested termination, if any.
pub fn requestedSignal() ?c_int {
    const s = term_signal.load(.acquire);
    return if (s == 0) null else s;
}

/// Clear the flag. For tests, and for a host that wants to survive one
/// signal.
pub fn reset() void {
    term_signal.store(0, .release);
}

/// Wait up to `timeout_ms` for `fd` to become readable (or reach EOF / hang
/// up — a closed pipe must wake a reader so it can see the 0-byte read).
/// Returns false on timeout *and* on `EINTR`, so the caller re-checks
/// `terminationRequested` either way.
pub fn waitReadable(fd: c_int, timeout_ms: c_int) bool {
    var pfd = [1]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
    const rc = std.c.poll(&pfd, 1, timeout_ms);
    return rc > 0;
}

// =============================================================================
// Tests
// =============================================================================

test "signal: SIGTERM sets the flag and records which signal it was" {
    reset();
    try installTermHandlers();
    defer {
        restoreDefaultHandlers();
        reset();
    }
    try std.testing.expect(!terminationRequested());
    try std.testing.expectEqual(@as(?c_int, null), requestedSignal());

    try std.testing.expectEqual(@as(c_int, 0), std.c.raise(.TERM));
    // `raise` delivers to the calling thread before it returns, but poll
    // anyway: the contract under test is "eventually visible", not a
    // particular delivery order.
    var spins: usize = 0;
    while (!terminationRequested() and spins < 1000) : (spins += 1) {
        _ = waitReadable(-1, 1);
    }
    try std.testing.expect(terminationRequested());
    try std.testing.expectEqual(@as(?c_int, @intCast(@intFromEnum(std.c.SIG.TERM))), requestedSignal());

    reset();
    try std.testing.expect(!terminationRequested());
}

test "signal: SIGINT is handled the same way" {
    reset();
    try installTermHandlers();
    defer {
        restoreDefaultHandlers();
        reset();
    }
    try std.testing.expectEqual(@as(c_int, 0), std.c.raise(.INT));
    try std.testing.expect(terminationRequested());
    try std.testing.expectEqual(@as(?c_int, @intCast(@intFromEnum(std.c.SIG.INT))), requestedSignal());
}

test "signal: waitReadable times out on an idle pipe and wakes on data or hang-up" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    var write_open = true;
    defer if (write_open) {
        _ = std.c.close(fds[1]);
    };

    try std.testing.expect(!waitReadable(fds[0], 5));

    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    try std.testing.expect(waitReadable(fds[0], 1000));

    var b: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(fds[0], &b, 1));
    try std.testing.expect(!waitReadable(fds[0], 5));

    // EOF must wake the reader too, or `mem3 mcp` could never see its
    // client hang up.
    _ = std.c.close(fds[1]);
    write_open = false;
    try std.testing.expect(waitReadable(fds[0], 1000));
}
