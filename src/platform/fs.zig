//! Portability layer: file and directory operations.
//!
//! Why this file exists: the project used to call `std.c.open` with a
//! `std.c.O` literal everywhere. That type is a `switch (native_os)` whose
//! *shape differs per platform* — the Linux branch has an `ACCMODE` field,
//! the Windows and WASI branches do not. The result was a scatter of
//! `no field named 'ACCMODE' in struct 'c.O__struct_XX'` errors whose hex
//! suffix even changes depending on which file was being compiled.
//!
//! It also used `std.c.Stat`, which Zig 0.17 defines only for
//! darwin/freebsd/illumos/wasi/emscripten and leaves as `void` on Linux and
//! Windows.
//!
//! This module replaces both with one API whose surface is identical
//! everywhere: callers describe intent with `OpenMode`/`Access`/`Create`
//! enums and never name a platform flag.
//!
//! Descriptor-based on purpose. The store, snapshot writer and WAL all hold a
//! raw descriptor across calls and do incremental reads and writes against
//! it, so this deliberately mirrors that shape instead of forcing the whole
//! persistence layer onto a different abstraction in one go.
//!
//! ## Target support
//!
//! ## Supported targets: macOS and Linux only
//!
//! `windows`, `wasm32-wasi` and `wasm32-freestanding` are **refused at
//! compile time** with a message naming this file. The WASM refusal has
//! always been here; Windows was ported and then deliberately withdrawn,
//! because the daemon's socket and pthread layer needs a real Winsock port
//! and that work is not scheduled.
//!
//! Consequence, stated plainly: the Windows branches further down this file
//! are **not compiled, not tested, and not maintained**. They are retained
//! only so that re-enabling Windows is a one-line change rather than a
//! re-port. Do not read them as a compatibility guarantee.
//!
//! The refusal is a `comptime` error rather than an accidental `void` field
//! access, because the whole point of this layer is that an unsupported
//! target says so in words instead of failing somewhere unrelated.

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

comptime {
    switch (builtin.os.tag) {
        .windows => @compileError(
            "mem3 does not support Windows. The library, CLI and benchmarks " ++
                "were ported and cross-compiled here, then withdrawn: the HTTP " ++
                "daemon in src/server/http_server.zig uses raw POSIX sockets and " ++
                "a pthread mutex, and Windows needs a Winsock port rather than a " ++
                "flag flip. Removing the daemon would be a smaller product. " ++
                "Supported targets are macOS and Linux. See src/platform/mod.zig.",
        ),
        .wasi, .freestanding => @compileError(
            "mem3 does not support wasm targets: WASI open flags do not match the " ++
                "POSIX ACCMODE layout used by this module, and WASM 64-bit atomics need " ++
                "the threads feature. See the v0.1.0-alpha scope boundary in " ++
                ".specify/memory/constitution.md, which defers WASM32 to v0.3.0. " ++
                "This is a deliberate, documented boundary — not an accident.",
        ),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

/// Portable across platforms. Note this deliberately does NOT mirror
/// `std.posix.errno` values, which have no meaning on Windows.
pub const Error = error{
    /// Failed to open the path.
    CannotOpen,
    /// Path exists but is not the kind of thing the caller needed.
    NotADirectory,
    /// The operation requires a directory and the path is not one.
    IsADirectory,
    /// Underlying read/write/close failed.
    IoFailed,
    /// The target of a rename already exists.
    AlreadyExists,
    /// No such file or directory.
    NotFound,
};

// ---------------------------------------------------------------------------
// Public vocabulary — never name a platform flag above this line
// ---------------------------------------------------------------------------

pub const Fd = c_int;

pub const Access = enum {
    read_only,
    write_only,
    read_write,
};

pub const Create = enum {
    /// Never create. Open fails if absent.
    never,
    /// Create if absent, keep contents otherwise.
    if_missing,
    /// Create if absent, truncate otherwise.
    truncate,
};

pub const OpenMode = struct {
    access: Access = .read_only,
    create: Create = .never,
    /// Require the path to be a directory rather than a regular file.
    directory: bool = false,
    /// Open for appending instead of seeking from the start.
    append: bool = false,
};

pub const DirMode = enum { file, directory };

/// Permissions for files we create. POSIX-only in effect; Windows uses the
/// CRT's default ACL instead, which is why this field exists at all.
pub const default_file_mode: std.c.mode_t = 0o644;
pub const default_dir_mode: std.c.mode_t = 0o755;

// ---------------------------------------------------------------------------
// Windows CRT / Win32 declarations
// ---------------------------------------------------------------------------

// UCRT `_O_*` values. Stable ABI, documented in the Microsoft CRT headers.
// Note these are NOT POSIX `O_*` values — mixing the two up opens files with
// the wrong access semantics and is a classic silent-corruption bug.
const win_crt = struct {
    pub const RDONLY: u32 = 0x0000;
    pub const WRONLY: u32 = 0x0001;
    pub const RDWR: u32 = 0x0002;
    pub const APPEND: u32 = 0x0008;
    pub const CREAT: u32 = 0x0100;
    pub const TRUNC: u32 = 0x0200;
    pub const EXCL: u32 = 0x0400;
    /// Required or text-mode translation will corrupt binary WAL records on
    /// a CRLF platform.
    pub const BINARY: u32 = 0x8000;

    extern "c" fn _open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn _close(fd: c_int) c_int;
    extern "c" fn _read(fd: c_int, buf: [*]u8, count: u32) c_int;
    extern "c" fn _write(fd: c_int, buf: [*]const u8, count: u32) c_int;
    extern "c" fn _unlink(path: [*:0]const u8) c_int;
    /// Note the arity: the Windows CRT's `_mkdir` takes NO mode argument,
    /// unlike POSIX `mkdir(path, mode)`. Passing two arguments here is a
    /// compile error, which is one of the reasons this module exists.
    extern "c" fn _mkdir(path: [*:0]const u8) c_int;
    extern "c" fn _rmdir(path: [*:0]const u8) c_int;
    extern "c" fn _lseeki64(fd: c_int, offset: i64, origin: c_int) i64;
};

const win32 = struct {
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

    extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn MoveFileExW(
        lpExistingFileName: [*:0]const u16,
        lpNewFileName: [*:0]const u16,
        dwFlags: u32,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn FlushFileBuffers(hFile: std.os.windows.HANDLE) callconv(.winapi) c_int;
};

// ---------------------------------------------------------------------------
// Sentinel helpers
// ---------------------------------------------------------------------------

/// Longest path we accept on the stack. `PATH_MAX` is not a portable constant
/// in Zig 0.17 — asking for it fails to compile on freestanding targets — so
/// the bound is stated here rather than inherited from libc.
pub const max_path_bytes = 4096;

pub const SentinelBuffer = struct {
    buf: [max_path_bytes + 1]u8 = undefined,
    len: usize = 0,

    pub fn init(path: []const u8) SentinelBuffer {
        std.debug.assert(path.len <= max_path_bytes);
        var s = SentinelBuffer{};
        @memcpy(s.buf[0..path.len], path);
        s.buf[path.len] = 0;
        s.len = path.len;
        return s;
    }

    pub fn ptr(self: *const SentinelBuffer) [*:0]const u8 {
        return self.buf[0..self.len :0].ptr;
    }
};

/// Build a NUL-terminated copy of `path` for the C ABI. Used by call sites
/// that still pass plain slices.
pub fn z(path: []const u8) SentinelBuffer {
    return SentinelBuffer.init(path);
}

// ---------------------------------------------------------------------------
// Path kind
// ---------------------------------------------------------------------------

fn posixPathKind(zp: [*:0]const u8) Error!DirMode {
    // `std.c.Stat` is `void` on Linux and Windows in Zig 0.17, so we cannot
    // ask the question the obvious way. Opening with O_DIRECTORY answers
    // "is it a directory" with no struct layout involved — but it cannot by
    // itself tell "this is a regular file" apart from "this does not exist",
    // so the errno decides.
    const rc = std.c.open(zp, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, @as(std.c.mode_t, 0));
    if (rc >= 0) {
        _ = std.c.close(rc);
        return .directory;
    }
    // `std.c.errno` needs the failing call's return value to know where to
    // read errno from; it must be called immediately, before anything else
    // can clobber it.
    return switch (std.c.errno(rc)) {
        .NOTDIR => .file,
        .NOENT => error.NotFound,
        else => error.CannotOpen,
    };
}

fn windowsPathKind(zp: [*:0]const u8) Error!DirMode {
    var wide: [max_path_bytes + 1]u16 = undefined;
    const w = std.unicode.utf8ToUtf16Le(&wide, zp) catch return error.CannotOpen;
    wide[w] = 0;
    const attrs = win32.GetFileAttributesW(wide[0..w :0].ptr);
    if (attrs == std.math.maxInt(u32)) return error.NotFound;
    if (attrs & win32.FILE_ATTRIBUTE_DIRECTORY != 0) return .directory;
    return .file;
}

/// What `path` actually is on disk.
pub fn pathKind(path: [*:0]const u8) Error!DirMode {
    if (is_windows) return windowsPathKind(path);
    return posixPathKind(path);
}

// ---------------------------------------------------------------------------
// Open / close
// ---------------------------------------------------------------------------

fn posixFlags(m: OpenMode) std.c.O {
    var o: std.c.O = .{};
    o.ACCMODE = switch (m.access) {
        .read_only => .RDONLY,
        .write_only => .WRONLY,
        .read_write => .RDWR,
    };
    switch (m.create) {
        .never => {},
        .if_missing => o.CREAT = true,
        .truncate => {
            o.CREAT = true;
            o.TRUNC = true;
        },
    }
    if (m.directory) o.DIRECTORY = true;
    if (m.append) o.APPEND = true;
    return o;
}

fn windowsFlags(m: OpenMode) u32 {
    var f: u32 = win_crt.BINARY;
    f = f | switch (m.access) {
        .read_only => win_crt.RDONLY,
        .write_only => win_crt.WRONLY,
        .read_write => win_crt.RDWR,
    };
    switch (m.create) {
        .never => {},
        .if_missing => f |= win_crt.CREAT,
        .truncate => f |= win_crt.CREAT | win_crt.TRUNC,
    }
    if (m.append) f |= win_crt.APPEND;
    return f;
}

pub fn open(path: [*:0]const u8, mode: OpenMode) Error!Fd {
    if (is_windows) {
        // Directories have no CRT descriptor; the caller asking for one is a
        // programming error, not something to paper over.
        if (mode.directory) return error.NotADirectory;
        const rc = win_crt._open(path, @bitCast(windowsFlags(mode)), @as(c_uint, @intCast(default_file_mode)));
        if (rc < 0) return error.CannotOpen;
        return rc;
    }
    const fd = std.c.open(path, posixFlags(mode), default_file_mode);
    if (fd < 0) return error.CannotOpen;
    return fd;
}

pub fn close(fd: Fd) void {
    if (is_windows) {
        _ = win_crt._close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

pub fn read(fd: Fd, buf: []u8) Error!usize {
    const n = if (is_windows)
        @as(isize, win_crt._read(fd, buf.ptr, @intCast(buf.len)))
    else
        std.c.read(fd, buf.ptr, buf.len);
    if (n < 0) return error.IoFailed;
    return @intCast(n);
}

pub fn write(fd: Fd, bytes: []const u8) Error!usize {
    const n = if (is_windows)
        @as(isize, win_crt._write(fd, bytes.ptr, @intCast(bytes.len)))
    else
        std.c.write(fd, bytes.ptr, bytes.len);
    if (n < 0) return error.IoFailed;
    return @intCast(n);
}

/// Write the whole buffer, looping until it is out. A short `write` on a
/// regular file is rare but legal; returning early would truncate the WAL.
pub fn writeAll(fd: Fd, bytes: []const u8) Error!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try write(fd, bytes[written..]);
        // Zero progress means the descriptor can never accept more. Treat it
        // as an error: looping would spin forever, and returning silently
        // would lose data.
        if (n == 0) return error.IoFailed;
        written += n;
    }
}

/// Read until `buf` is full or EOF. Returns bytes actually read.
///
/// A short read is reported as success-with-fewer-bytes, because for a
/// regular file EOF is legitimate. Callers that are replaying a log MUST
/// distinguish "hit EOF early" from "finished" themselves — a silently
/// truncated log replay resurrects a store state that never existed.
pub fn readFull(fd: Fd, buf: []u8) Error!usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try read(fd, buf[got..]);
        if (n == 0) break;
        got += n;
    }
    return got;
}

/// Current length of the file in bytes.
///
/// **This deliberately preserves the descriptor's read/write position.**
///
/// It is implemented with `lseek(SEEK_END)`, because `std.c.Stat` is `void`
/// on Linux and Windows in Zig 0.17. But `lseek` to END *moves* the
/// position — a naive implementation leaves the descriptor parked at EOF, so
/// the next `read` silently returns zero bytes. In a WAL replayer that is not
/// a wrong answer, it is a resurrected store state that never existed.
/// Save and restore around the seek.
pub fn sizeOf(fd: Fd) Error!u64 {
    const saved = if (is_windows)
        win_crt._lseeki64(fd, 0, 0) // SEEK_CUR
    else
        std.c.lseek(fd, 0, std.c.SEEK.CUR);
    const end = if (is_windows) win_crt._lseeki64(fd, 0, 2) else std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return error.IoFailed;
    // Restore, but only if the restore itself is meaningful; a descriptor
    // that cannot report its position still gets its length reported.
    if (saved >= 0) {
        if (is_windows) {
            _ = win_crt._lseeki64(fd, saved, 0); // SEEK_SET
        } else {
            _ = std.c.lseek(fd, saved, std.c.SEEK.SET);
        }
    }
    return @intCast(end);
}

/// Push buffered data to the storage device.
///
/// This is the single most expensive call in the write path — on most
/// filesystems it is an actual disk barrier. Code that appends one record per
/// call and syncs each time is capped at the device's sync rate, which is
/// usually the reason a "10K writes/sec" target is missed by an order of
/// magnitude. Group commit exists to amortise exactly this call.
pub fn sync(fd: Fd) Error!void {
    if (is_windows) {
        if (win32.FlushFileBuffers(@ptrCast(@as(usize, @bitCast(fd)))) == 0) return error.IoFailed;
        return;
    }
    if (std.c.fsync(fd) != 0) return error.IoFailed;
}

// ---------------------------------------------------------------------------
// Namespace operations
// ---------------------------------------------------------------------------

pub fn unlink(path: [*:0]const u8) Error!void {
    const rc = if (is_windows) win_crt._unlink(path) else std.c.unlink(path);
    if (rc != 0) return error.NotFound;
}

/// Create one directory. Fails with `AlreadyExists` if present.
pub fn makeDir(path: [*:0]const u8) Error!void {
    if (is_windows) {
        if (win_crt._mkdir(path) != 0) return error.AlreadyExists;
        return;
    }
    if (std.c.mkdir(path, default_dir_mode) != 0) return error.AlreadyExists;
}

pub fn removeDir(path: [*:0]const u8) Error!void {
    const rc = if (is_windows) win_crt._rmdir(path) else std.c.rmdir(path);
    if (rc != 0) return error.NotFound;
}

pub fn rename(from: [*:0]const u8, to: [*:0]const u8) Error!void {
    if (is_windows) {
        var w_from: [max_path_bytes + 1]u16 = undefined;
        var w_to: [max_path_bytes + 1]u16 = undefined;
        const a = std.unicode.utf8ToUtf16Le(&w_from, from) catch return error.CannotOpen;
        const b = std.unicode.utf8ToUtf16Le(&w_to, to) catch return error.CannotOpen;
        w_from[a] = 0;
        w_to[b] = 0;
        const rc = win32.MoveFileExW(
            w_from[0..a :0].ptr,
            w_to[0..b :0].ptr,
            win32.MOVEFILE_REPLACE_EXISTING,
        );
        if (rc == 0) return error.IoFailed;
        return;
    }
    if (std.c.rename(from, to) != 0) return error.IoFailed;
}

/// Create `path` and every missing parent. Returns the first component that
/// already existed, or the full path if it was created from scratch.
pub fn makeDirAll(path: [*:0]const u8) Error![]const u8 {
    var created_up_to: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/' and path[i] != '\\') continue;
        if (i == 0) {
            created_up_to = 1;
            continue;
        }
        const parent = path[0..i :0];
        const parent_kind = posixPathKind(parent) catch DirMode.file;
        if (parent_kind == .directory) {
            created_up_to = i + 1;
            continue;
        }
        makeDir(parent) catch |err| switch (err) {
            // Lost a race with another process creating the same directory.
            error.AlreadyExists => {},
            else => return err,
        };
        created_up_to = i + 1;
    }
    return path[0..created_up_to];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A per-test scratch path. The pid keeps concurrent test binaries (and
/// repeated runs of a failing test) from colliding in /tmp.
fn tmpPath(buf: []u8, name: []const u8) [*:0]const u8 {
    const pid = if (is_windows) @as(u64, 0) else @as(u64, @intCast(std.c.getpid()));
    const s = std.fmt.bufPrint(buf, "/tmp/mem3_platform_{d}_{s}", .{ pid, name }) catch unreachable;
    // `bufPrint` does not write a terminator; the C ABI calls below need one.
    buf[s.len] = 0;
    return buf[0..s.len :0].ptr;
}

test "open, write, read back, size" {
    var pb: [max_path_bytes + 1]u8 = undefined;
    const p = tmpPath(&pb, "rw");
    defer unlink(p) catch {};

    const payload = "the quick brown fox";
    const fd = try open(p, .{ .access = .write_only, .create = .truncate });
    try writeAll(fd, payload);
    try sync(fd);
    close(fd);

    const fd2 = try open(p, .{ .access = .read_only });
    defer close(fd2);
    try std.testing.expectEqual(@as(u64, payload.len), try sizeOf(fd2));

    var buf: [128]u8 = undefined;
    const got = try readFull(fd2, buf[0..payload.len]);
    try std.testing.expectEqualStrings(payload, buf[0..got]);
}

test "opening a missing file fails" {
    var pb: [max_path_bytes + 1]u8 = undefined;
    const p = tmpPath(&pb, "does_not_exist");
    unlink(p) catch {};
    try std.testing.expectError(error.CannotOpen, open(p, .{ .access = .read_only }));
}

test "truncate then write replaces previous contents" {
    var pb: [max_path_bytes + 1]u8 = undefined;
    const p = tmpPath(&pb, "trunc");
    defer unlink(p) catch {};

    {
        const fd = try open(p, .{ .access = .write_only, .create = .truncate });
        try writeAll(fd, "aaaaaaaaaaaaaaaaaaaaaaaa");
        close(fd);
    }
    {
        const fd = try open(p, .{ .access = .write_only, .create = .truncate });
        try writeAll(fd, "bb");
        close(fd);
    }
    const fd = try open(p, .{ .access = .read_only });
    defer close(fd);
    try std.testing.expectEqual(@as(u64, 2), try sizeOf(fd));
}

test "binary round-trip preserves every byte, including NUL" {
    // Text-mode translation on a CRLF platform would silently corrupt this.
    var pb: [max_path_bytes + 1]u8 = undefined;
    const p = tmpPath(&pb, "binary");
    defer unlink(p) catch {};

    var payload: [256]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    const fd = try open(p, .{ .access = .write_only, .create = .truncate });
    try writeAll(fd, &payload);
    close(fd);

    const fd2 = try open(p, .{ .access = .read_only });
    defer close(fd2);
    var back: [256]u8 = undefined;
    const got = try readFull(fd2, &back);
    try std.testing.expectEqualSlices(u8, &payload, back[0..got]);
}

test "readFull stops at EOF and reports the short count" {
    var pb: [max_path_bytes + 1]u8 = undefined;
    const p = tmpPath(&pb, "short");
    defer unlink(p) catch {};

    {
        const fd = try open(p, .{ .access = .write_only, .create = .truncate });
        try writeAll(fd, "12345");
        close(fd);
    }
    const fd = try open(p, .{ .access = .read_only });
    defer close(fd);
    var buf: [64]u8 = undefined;
    // Ask for more than exists: the caller must be able to tell that fewer
    // bytes than requested came back rather than getting a silent success.
    const got = try readFull(fd, &buf);
    try std.testing.expectEqual(@as(usize, 5), got);
    try std.testing.expectEqualStrings("12345", buf[0..got]);
}

test "directory lifecycle: make, kind, remove" {
    var pb: [max_path_bytes + 1]u8 = undefined;
    const p = tmpPath(&pb, "dir");
    removeDir(p) catch {};

    try makeDir(p);
    defer removeDir(p) catch {};
    try std.testing.expectEqual(DirMode.directory, try pathKind(p));

    // Creating it twice must report AlreadyExists rather than silently
    // succeeding — callers use this to decide whether to mkdir -p.
    try std.testing.expectError(error.AlreadyExists, makeDir(p));
}

test "pathKind distinguishes a regular file from a directory" {
    var pb: [max_path_bytes + 1]u8 = undefined;
    const p = tmpPath(&pb, "kind");
    defer unlink(p) catch {};

    {
        const fd = try open(p, .{ .access = .write_only, .create = .truncate });
        try writeAll(fd, "x");
        close(fd);
    }
    try std.testing.expectEqual(DirMode.file, try pathKind(p));
}

test "sizeOf does not move the read position" {
    // Regression guard. sizeOf is implemented with lseek(SEEK_END); if it
    // fails to restore the position, the read below returns zero bytes and a
    // WAL replayer silently truncates. This is the exact failure that
    // `stat`-then-`read` on the same descriptor does not have.
    var pb: [max_path_bytes + 1]u8 = undefined;
    const p = tmpPath(&pb, "sizepos");
    defer unlink(p) catch {};

    {
        const fd = try open(p, .{ .access = .write_only, .create = .truncate });
        try writeAll(fd, "0123456789");
        close(fd);
    }

    const fd = try open(p, .{ .access = .read_only });
    defer close(fd);

    var probe: [1]u8 = undefined;
    _ = try read(fd, &probe);
    try std.testing.expectEqualStrings("0", &probe);

    _ = try sizeOf(fd); // must not disturb the position

    var rest: [9]u8 = undefined;
    const got = try readFull(fd, &rest);
    try std.testing.expectEqual(@as(usize, 9), got);
    try std.testing.expectEqualStrings("123456789", &rest);
}

test "rename moves a file" {
    var pb: [max_path_bytes + 1]u8 = undefined;
    var pb2: [max_path_bytes + 1]u8 = undefined;
    const a = tmpPath(&pb, "ren_a");
    const b = tmpPath(&pb2, "ren_b");
    defer unlink(a) catch {};
    defer unlink(b) catch {};

    {
        const fd = try open(a, .{ .access = .write_only, .create = .truncate });
        try writeAll(fd, "payload");
        close(fd);
    }
    try rename(a, b);
    try std.testing.expectError(error.CannotOpen, open(a, .{ .access = .read_only }));
    const fd = try open(b, .{ .access = .read_only });
    defer close(fd);
    try std.testing.expectEqual(@as(u64, 7), try sizeOf(fd));
}
