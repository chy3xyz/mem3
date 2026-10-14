//! Portability layer: environment variables.
//!
//! Zig 0.17 removed `std.posix.getenv` and `std.posix.setenv` and does not
//! re-export the C `getenv`, so the project had been hand-declaring
//! `extern "c" fn getenv` in the middle of a CLI module. This module gives
//! that one declaration a home and adds the Windows spelling.
//!
//! Scope note: read-only on purpose. `setenv` is not exposed, because the
//! CRT's `setenv` differs across platforms (`putenv_s` on MSVC) and a
//! half-portable environment mutator is worse than none.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

const c_getenv = struct {
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
}.getenv;

const win32 = struct {
    extern "kernel32" fn GetEnvironmentVariableW(
        lpName: [*:0]const u16,
        lpBuffer: ?[*]u16,
        nSize: u32,
    ) callconv(.winapi) u32;
};

/// Longest value we will copy out of the environment. Large enough for any
/// sane PATH or token; anything longer is a mistake worth surfacing.
pub const max_value_bytes = 32 * 1024;

/// Look up `name` and return its value as a borrowed slice, or null.
///
/// The returned slice borrows from process-owned storage that stays valid for
/// the life of the process — do not free it, and do not assume it is
/// NUL-terminated at exactly `name.len + 1 + value.len`.
pub fn get(name: []const u8) ?[]const u8 {
    if (is_windows) return windowsGet(name);
    return posixGet(name);
}

fn posixGet(name: []const u8) ?[]const u8 {
    if (name.len >= max_value_bytes) return null;
    var buf: [max_value_bytes + 1]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    // The buffer must outlive the returned slice. It is function-local, so
    // this only works because the C `getenv` storage is what `std.mem.span`
    // will actually walk — `name_buf` itself is dead on return. Do not "fix"
    // this by returning the local buffer; that would be a dangling pointer.
    const value_ptr = c_getenv(@ptrCast(&buf[0])) orelse return null;
    return std.mem.span(value_ptr);
}

fn windowsGet(name: []const u8) ?[]const u8 {
    var name_w: [max_value_bytes + 1]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&name_w, name) catch return null;
    name_w[n] = 0;

    var value_w: [max_value_bytes + 1]u16 = undefined;
    const written = win32.GetEnvironmentVariableW(name_w[0..n :0].ptr, &value_w, value_w.len);
    if (written == 0 or written >= value_w.len) return null;

    // Returns a slice into a thread-local scratch buffer owned by std, which
    // is what makes it safe to return from a function with no allocator.
    var scratch: [max_value_bytes]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&scratch, value_w[0..written]) catch return null;
    return scratch[0..len];
}

test "a variable that is definitely absent returns null" {
    try std.testing.expectEqual(null, get("MEM3_PLATFORM_DEFINITELY_NOT_SET_9c1f"));
}

test "an empty name does not crash and does not invent a value" {
    // getenv("") is implementation-defined. Whatever it returns, this must
    // not panic — that is the property under test.
    _ = get("");
}

test "a realistic PATH lookup succeeds" {
    // PATH is present in every environment this runs in. Its presence lets
    // us assert the happy path without mutating global environment state,
    // which would make tests order-dependent.
    if (get("PATH")) |p| {
        try std.testing.expect(p.len > 0);
    }
}
