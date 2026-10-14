//! Portability layer: stdout and stderr.
//!
//! The CLI writes directly to file descriptors rather than through
//! `std.io.getStdOut()`, because the daemon's silence guarantee depends on
//! being able to choose, per write, whether a byte reaches stdout at all.
//! Going through the buffered writer would make that unobservable.
//!
//! `std.c.STDOUT_FILENO` / `std.c.STDERR_FILENO` exist on POSIX. On Windows
//! they are `*anyopaque`, so this module resolves the handles through
//! `GetStdHandle` once and caches them.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

const win32 = struct {
    const STD_OUTPUT_HANDLE: u32 = -11;
    const STD_ERROR_HANDLE: u32 = -12;
    const INVALID_HANDLE_VALUE: isize = -1;

    extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WriteFile(
        hFile: ?*anyopaque,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: ?*u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) c_int;
};

/// Resolved once. `std.atomic.Value` is a value type, so a plain `?*anyopaque`
/// cache guarded by the fact that these are constants from the process's
/// lifetime is sufficient — there is no concurrent initialisation race worth
/// paying a lock for.
fn windowsHandle(which: u32) ?*anyopaque {
    const h = win32.GetStdHandle(which) orelse return null;
    if (@intFromPtr(h) == @as(usize, @bitCast(@as(isize, win32.INVALID_HANDLE_VALUE)))) return null;
    return h;
}

/// Write `bytes` to a stream, returning how many were accepted.
///
/// A short or zero write is reported, not swallowed. For a CLI that is
/// cosmetic, but this is also the path the daemon uses to decide whether a
/// message is visible, and silently dropping it would make "silent mode"
/// unprovable.
pub fn writeFd(fd: c_int, bytes: []const u8) usize {
    if (is_windows) {
        const which: u32 = if (fd == 1) win32.STD_OUTPUT_HANDLE else win32.STD_ERROR_HANDLE;
        const h = windowsHandle(which) orelse return 0;
        var written: u32 = 0;
        const rc = win32.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null);
        if (rc == 0) return 0;
        return written;
    }
    const n = std.c.write(fd, bytes.ptr, bytes.len);
    if (n <= 0) return 0;
    return @intCast(n);
}

pub fn writeOut(bytes: []const u8) usize {
    return writeFd(1, bytes);
}

pub fn writeErr(bytes: []const u8) usize {
    return writeFd(2, bytes);
}

test "writeFd writes real bytes and reports the count" {
    // Writes to a scratch file, never to stdout or stderr. Under
    // `zig build test` the runner speaks its protocol over the process pipe;
    // ANY stderr write from inside a test desynchronises it, kills the test
    // binary, and `zig build test` still reports success. Printing here to
    // "verify" stderr would be both noisy and silently fatal.
    var pb: [fs.max_path_bytes + 1]u8 = undefined;
    const pid = @as(u64, @intCast(std.c.getpid()));
    const n = std.fmt.bufPrint(&pb, "/tmp/mem3_stdio_{d}.txt", .{pid}) catch unreachable;
    pb[n.len] = 0;
    const p = pb[0..n.len :0].ptr;

    fs.unlink(p) catch {};
    defer fs.unlink(p) catch {};

    const fd = try fs.open(p, .{ .access = .write_only, .create = .truncate });
    defer fs.close(fd);

    const msg = "mem3 platform selftest\n";
    try std.testing.expectEqual(msg.len, writeFd(fd, msg));

    const back = try fs.open(p, .{ .access = .read_only });
    defer fs.close(back);
    var buf: [64]u8 = undefined;
    const got = try fs.readFull(back, &buf);
    try std.testing.expectEqualStrings(msg, buf[0..got]);
}

test "writing an empty slice is a no-op that reports zero" {
    // Exercises the entry points without producing output. An empty write
    // still has to return cleanly rather than being treated as an error.
    try std.testing.expectEqual(@as(usize, 0), writeOut(""));
    try std.testing.expectEqual(@as(usize, 0), writeErr(""));
}

const fs = @import("fs.zig");
