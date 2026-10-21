//! E2E: the daemon's lifecycle against the real `zig-out/bin/mem3`.
//!
//! What the unit tests cannot show, this does with real processes:
//!
//!   * SIGTERM / SIGINT stop `mem3 serve` and `mem3 mcp` cleanly (exit
//!     status 0, not death-by-signal) and nothing acknowledged is lost.
//!   * `--wal-sync=group` loses no acknowledged write across `kill -9`.
//!   * `--log-format=jsonl` makes stderr pure JSONL; the default stays the
//!     legacy banner and nothing else.
//!
//! **What kill -9 does and does not prove.** SIGKILL ends the *process*; the
//! kernel still owns every byte that was `write(2)`n, so the page cache
//! survives it. These tests therefore prove the *logical* contract (a
//! response is never sent for a record the server has not made durable *as
//! it understands durability*, and replay restores everything acknowledged).
//! They cannot prove an fsync reached the platter: that needs a power cut,
//! and is covered in `src/storage/wal.zig` by tests that assert
//! `durable >= seq` at the instant of acknowledgement and that a failed
//! fsync is never acknowledged.
//!
//! Subprocesses are skipped (`error.SkipZigTest`), never silently passed,
//! when the binary is absent. Scratch lives under /tmp, pid-scoped.

const std = @import("std");
const testing = std.testing;

const c = std.c;
extern "c" fn execvp([*:0]const u8, [*c]?[*:0]const u8) c_int;

const EXE: [:0]const u8 = "zig-out/bin/mem3";

// ---------------------------------------------------------------- scratch --

fn scratchPath(buf: []u8, label: []const u8, suffix: []const u8) []u8 {
    const s = std.fmt.bufPrint(buf, "/tmp/mem3_life_{d}_{s}{s}", .{ c.getpid(), label, suffix }) catch unreachable; // SAFETY: caller buffers are >= 128 bytes and labels are short literals.
    return s;
}

fn unlinkPath(path: []const u8) void {
    var z: [256]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&z, "{s}", .{path}, 0) catch return;
    _ = c.unlink(s.ptr);
}

fn wipeDir(dir: []const u8) void {
    var b: [256]u8 = undefined;
    for ([_][]const u8{ "mem3.wal", "snapshot.bin" }) |f| {
        const p = std.fmt.bufPrint(&b, "{s}/{s}", .{ dir, f }) catch continue;
        unlinkPath(p);
    }
    var z: [256]u8 = undefined;
    const d = std.fmt.bufPrintSentinel(&z, "{s}", .{dir}, 0) catch return;
    _ = c.rmdir(d.ptr);
}

fn sleepMs(ms: u64) void {
    var req: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = c.nanosleep(&req, null);
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var z: [256]u8 = undefined;
    const pz = try std.fmt.bufPrintSentinel(&z, "{s}", .{path}, 0);
    const fd = c.open(pz.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        try out.appendSlice(alloc, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------- http --

const Resp = struct {
    status: u16,
    body: []u8,
    fn deinit(self: Resp, a: std.mem.Allocator) void {
        a.free(self.body);
    }
};

fn http(alloc: std.mem.Allocator, port: u16, request: []const u8) !Resp {
    var addr: std.posix.sockaddr.in = undefined;
    addr.family = c.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = std.mem.nativeToBig(u32, 0x7F000001);
    const fd = c.socket(c.AF.INET, @bitCast(@as(u32, c.SOCK.STREAM)), 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.ConnectFailed;
    var w: usize = 0;
    while (w < request.len) {
        const n = c.write(fd, request[w..].ptr, request.len - w);
        if (n <= 0) return error.WriteFailed;
        w += @intCast(n);
    }
    var all = std.ArrayList(u8).empty;
    defer all.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        try all.appendSlice(alloc, chunk[0..@intCast(n)]);
    }
    const head_end = std.mem.indexOf(u8, all.items, "\r\n\r\n") orelse return error.MalformedResponse;
    const sp = std.mem.indexOfScalar(u8, all.items, ' ') orelse return error.MalformedResponse;
    const status = std.fmt.parseInt(u16, all.items[sp + 1 ..][0..3], 10) catch return error.MalformedResponse;
    return .{ .status = status, .body = try alloc.dupe(u8, all.items[head_end + 4 ..]) };
}

fn postCell(alloc: std.mem.Allocator, port: u16, episode: []const u8) !u64 {
    var body: [256]u8 = undefined;
    const b = try std.fmt.bufPrint(&body, "{{\"source\":\"matter\",\"episode\":\"{s}\",\"facts\":\"\",\"goalId\":1,\"relevance\":0.5}}", .{episode});
    var req: [768]u8 = undefined;
    const r = try std.fmt.bufPrint(&req, "POST /api/memcells HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ b.len, b });
    const resp = try http(alloc, port, r);
    defer resp.deinit(alloc);
    if (resp.status != 201) return error.NotAcknowledged;
    const m = std.mem.indexOf(u8, resp.body, "\"id\":") orelse return error.MalformedResponse;
    var i = m + 5;
    const start = i;
    while (i < resp.body.len and resp.body[i] >= '0' and resp.body[i] <= '9') i += 1;
    return std.fmt.parseInt(u64, resp.body[start..i], 10);
}

fn cellPresent(alloc: std.mem.Allocator, port: u16, id: u64) !bool {
    var req: [160]u8 = undefined;
    const r = try std.fmt.bufPrint(&req, "GET /api/memcells/{d} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{id});
    const resp = try http(alloc, port, r);
    defer resp.deinit(alloc);
    return resp.status == 200;
}

fn pickFreePort() !u16 {
    const fd = c.socket(c.AF.INET, @bitCast(@as(u32, c.SOCK.STREAM)), 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);
    var addr: std.posix.sockaddr.in = undefined;
    addr.family = c.AF.INET;
    addr.port = 0;
    addr.addr = 0;
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
    var got: std.posix.sockaddr.in = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(got));
    if (c.getsockname(fd, @ptrCast(&got), &len) != 0) return error.GetsocknameFailed;
    return std.mem.bigToNative(u16, got.port);
}

// ---------------------------------------------------------------- process --

const Child = struct {
    pid: c.pid_t,
    reaped: bool = false,

    /// Wait up to `timeout_ms` for exit. Returns the raw wait status, or
    /// null if the child is still running (never blocks forever, so a hung
    /// daemon fails the test instead of hanging the suite).
    fn waitExit(self: *Child, timeout_ms: u64) ?c_int {
        if (self.reaped) return 0;
        var waited: u64 = 0;
        while (waited <= timeout_ms) : (waited += 20) {
            var status: c_int = 0;
            const r = c.waitpid(self.pid, &status, std.c.W.NOHANG);
            if (r == self.pid) {
                self.reaped = true;
                return status;
            }
            sleepMs(20);
        }
        return null;
    }

    /// Test cleanup: never leaves a daemon behind.
    fn reap(self: *Child) void {
        if (self.reaped) return;
        _ = c.kill(self.pid, c.SIG.KILL);
        _ = c.waitpid(self.pid, null, 0);
        self.reaped = true;
    }
};

fn exitedCleanly(status: c_int) bool {
    // WIFEXITED && WEXITSTATUS == 0, spelled out: low 7 bits clear means a
    // normal exit, and the exit code lives in bits 8..15.
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
}

fn killedBy(status: c_int, sig: c.SIG) bool {
    return (status & 0x7f) == @intFromEnum(sig);
}

const Stdio = struct {
    stdin_fd: c_int = -1, // -1: /dev/null
    stdout_fd: c_int = -1,
    stderr_fd: c_int = -1,
};

fn spawn(args: []const [:0]const u8, io: Stdio) !Child {
    var argv: [24]?[*:0]const u8 = @splat(null);
    argv[0] = EXE.ptr;
    for (args, 0..) |a, i| argv[i + 1] = a.ptr;
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const devnull = c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(c.mode_t, 0));
        _ = c.dup2(if (io.stdin_fd >= 0) io.stdin_fd else devnull, 0);
        _ = c.dup2(if (io.stdout_fd >= 0) io.stdout_fd else devnull, 1);
        _ = c.dup2(if (io.stderr_fd >= 0) io.stderr_fd else devnull, 2);
        var fd: c_int = 3;
        while (fd < 64) : (fd += 1) _ = c.close(fd);
        _ = execvp(EXE.ptr, @ptrCast(@constCast(&argv)));
        c.exit(127);
    }
    return .{ .pid = pid };
}

fn binaryPresent() bool {
    return c.access(EXE.ptr, 1) == 0; // X_OK
}

fn waitForPort(port: u16) bool {
    var attempt: u8 = 0;
    while (attempt < 50) : (attempt += 1) {
        sleepMs(100);
        const r = http(std.heap.page_allocator, port, "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n") catch continue;
        r.deinit(std.heap.page_allocator);
        if (r.status == 200) return true;
    }
    return false;
}

const Daemon = struct {
    child: Child,
    port: u16,

    fn start(dir: []const u8, extra: []const [:0]const u8, stderr_fd: c_int) !Daemon {
        if (!binaryPresent()) return error.SkipZigTest;
        const port = try pickFreePort();
        var port_s: [8:0]u8 = undefined;
        _ = try std.fmt.bufPrintSentinel(&port_s, "{d}", .{port}, 0);
        var dir_z: [200:0]u8 = undefined;
        _ = try std.fmt.bufPrintSentinel(&dir_z, "{s}", .{dir}, 0);

        var args: [20][:0]const u8 = undefined;
        var n: usize = 0;
        for ([_][:0]const u8{ "serve", "--bind", "127.0.0.1", "--port", std.mem.sliceTo(&port_s, 0), "--data-dir", std.mem.sliceTo(&dir_z, 0) }) |a| {
            args[n] = a;
            n += 1;
        }
        for (extra) |a| {
            args[n] = a;
            n += 1;
        }
        var child = try spawn(args[0..n], .{ .stderr_fd = stderr_fd });
        if (!waitForPort(port)) {
            child.reap();
            return error.ServerStartupTimeout;
        }
        return .{ .child = child, .port = port };
    }
};

// ------------------------------------------------------------------ tests --

fn lifecycleRoundTrip(label: []const u8, extra: []const [:0]const u8, sig: c.SIG) !void {
    const alloc = testing.allocator;
    var db: [128]u8 = undefined;
    const dir = scratchPath(&db, label, "");
    wipeDir(dir);
    defer wipeDir(dir);

    var ids: [6]u64 = undefined;
    {
        var d = Daemon.start(dir, extra, -1) catch |e| return e;
        defer d.child.reap();
        for (&ids, 0..) |*id, i| {
            var ep: [48]u8 = undefined;
            id.* = try postCell(alloc, d.port, try std.fmt.bufPrint(&ep, "lifecycle {s} cell {d}", .{ label, i }));
        }
        try testing.expectEqual(@as(c_int, 0), c.kill(d.child.pid, sig));
        const status = d.child.waitExit(10_000) orelse return error.DaemonDidNotExit;
        // Clean exit: not "killed by SIGTERM", not a crash, not nonzero.
        try testing.expect(exitedCleanly(status));
    }
    {
        // Restart *without* the flag: the WAL format is the same in every mode.
        var d = try Daemon.start(dir, &.{}, -1);
        defer d.child.reap();
        for (ids) |id| try testing.expect(try cellPresent(alloc, d.port, id));
    }
}

test "E2E lifecycle: SIGTERM stops `serve` cleanly and keeps every acknowledged cell" {
    try lifecycleRoundTrip("term_always", &.{}, c.SIG.TERM);
}

test "E2E lifecycle: SIGINT stops `serve` cleanly in group mode and keeps every acknowledged cell" {
    try lifecycleRoundTrip("int_group", &.{"--wal-sync=group"}, c.SIG.INT);
}

test "E2E lifecycle: SIGTERM in interval mode flushes the WAL on the way out" {
    try lifecycleRoundTrip("term_interval", &.{"--wal-sync=interval:5000"}, c.SIG.TERM);
}

const Writer = struct {
    port: u16,
    worker: usize,
    acked: [PER_WORKER]u64 = undefined,
    n_acked: usize = 0,

    const PER_WORKER = 12;

    fn run(self: *Writer) void {
        const alloc = std.heap.page_allocator;
        var i: usize = 0;
        while (i < PER_WORKER) : (i += 1) {
            var ep: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&ep, "crash w{d} cell {d}", .{ self.worker, i }) catch return;
            const id = postCell(alloc, self.port, text) catch return;
            self.acked[self.n_acked] = id;
            self.n_acked += 1;
        }
    }
};

test "E2E crash: with --wal-sync=group, kill -9 after N acknowledged writes loses none of them" {
    const alloc = testing.allocator;
    var db: [128]u8 = undefined;
    const dir = scratchPath(&db, "crash_group", "");
    wipeDir(dir);
    defer wipeDir(dir);

    var acked_ids = std.ArrayList(u64).empty;
    defer acked_ids.deinit(alloc);
    {
        var d = try Daemon.start(dir, &.{"--wal-sync=group"}, -1);
        defer d.child.reap();

        var writers: [4]Writer = undefined;
        var threads: [4]std.Thread = undefined;
        for (&writers, 0..) |*w, i| w.* = .{ .port = d.port, .worker = i };
        for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Writer.run, .{&writers[i]});
        for (threads) |t| t.join();

        // Every response is in. Only now — the daemon has had no chance to
        // "catch up" — is it killed, without a chance to flush or snapshot.
        for (writers) |w| try acked_ids.appendSlice(alloc, w.acked[0..w.n_acked]);
        try testing.expectEqual(@as(usize, 4 * Writer.PER_WORKER), acked_ids.items.len);
        _ = c.kill(d.child.pid, c.SIG.KILL);
        const status = d.child.waitExit(10_000) orelse return error.DaemonDidNotExit;
        try testing.expect(killedBy(status, c.SIG.KILL));
    }
    {
        var d = try Daemon.start(dir, &.{"--wal-sync=group"}, -1);
        defer d.child.reap();
        var missing: usize = 0;
        for (acked_ids.items) |id| {
            if (!try cellPresent(alloc, d.port, id)) missing += 1;
        }
        try testing.expectEqual(@as(usize, 0), missing);
    }
}

test "E2E lifecycle: SIGTERM ends `mcp` while the client keeps stdin open and idle" {
    if (!binaryPresent()) return error.SkipZigTest;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[1]); // we keep the write end open the whole time
    var child = blk: {
        defer _ = c.close(fds[0]);
        break :blk try spawn(&.{ "mcp", "--in-memory" }, .{ .stdin_fd = fds[0] });
    };
    defer child.reap();

    sleepMs(500);
    try testing.expect(child.waitExit(0) == null); // still serving
    try testing.expectEqual(@as(c_int, 0), c.kill(child.pid, c.SIG.TERM));
    const status = child.waitExit(10_000) orelse return error.DaemonDidNotExit;
    try testing.expect(exitedCleanly(status));
}

fn openLog(path: []const u8) !c_int {
    var z: [256]u8 = undefined;
    const pz = try std.fmt.bufPrintSentinel(&z, "{s}", .{path}, 0);
    const fd = c.open(pz.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    return fd;
}

test "E2E logging: --log-format=jsonl makes stderr pure JSONL with startup, summary and shutdown" {
    const alloc = testing.allocator;
    var db: [128]u8 = undefined;
    const dir = scratchPath(&db, "jsonl", "");
    var lb: [128]u8 = undefined;
    const log_path = scratchPath(&lb, "jsonl", ".log");
    wipeDir(dir);
    unlinkPath(log_path);
    defer wipeDir(dir);
    defer unlinkPath(log_path);

    {
        const fd = try openLog(log_path);
        defer _ = c.close(fd);
        var d = try Daemon.start(dir, &.{ "--log-format=jsonl", "--log-every=1", "--maint-interval=1" }, fd);
        defer d.child.reap();
        _ = try postCell(alloc, d.port, "jsonl probe cell");
        sleepMs(2500); // at least two summary ticks
        _ = c.kill(d.child.pid, c.SIG.TERM);
        const status = d.child.waitExit(10_000) orelse return error.DaemonDidNotExit;
        try testing.expect(exitedCleanly(status));
    }

    const text = try readFile(alloc, log_path);
    defer alloc.free(text);
    try testing.expect(text.len > 0);
    var saw_startup = false;
    var summaries: usize = 0;
    var saw_shutdown = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Every non-empty line must be one JSON object with the four keys.
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("ts") != null);
        try testing.expect(obj.get("level") != null);
        try testing.expect(obj.get("msg") != null);
        const scope = obj.get("scope").?.string;
        if (std.mem.eql(u8, scope, "startup")) saw_startup = true;
        if (std.mem.eql(u8, scope, "summary")) {
            summaries += 1;
            try testing.expect(std.mem.indexOf(u8, obj.get("msg").?.string, "requests=") != null);
        }
        if (std.mem.eql(u8, scope, "shutdown")) saw_shutdown = true;
    }
    try testing.expect(saw_startup);
    try testing.expect(summaries >= 2);
    try testing.expect(saw_shutdown);
}

test "E2E logging: the default is the legacy banner and nothing else, even across shutdown" {
    const alloc = testing.allocator;
    var db: [128]u8 = undefined;
    const dir = scratchPath(&db, "quiet", "");
    var lb: [128]u8 = undefined;
    const log_path = scratchPath(&lb, "quiet", ".log");
    wipeDir(dir);
    unlinkPath(log_path);
    defer wipeDir(dir);
    defer unlinkPath(log_path);

    var port: u16 = 0;
    {
        const fd = try openLog(log_path);
        defer _ = c.close(fd);
        var d = try Daemon.start(dir, &.{ "--maint-interval=1" }, fd);
        defer d.child.reap();
        port = d.port;
        _ = try postCell(alloc, d.port, "quiet probe cell");
        sleepMs(1500); // maintenance ticks happen; none may speak
        _ = c.kill(d.child.pid, c.SIG.TERM);
        const status = d.child.waitExit(10_000) orelse return error.DaemonDidNotExit;
        try testing.expect(exitedCleanly(status));
    }

    var exp_buf: [1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &exp_buf,
        "mem3 v0.1.0-alpha listening on http://127.0.0.1:{d}\n" ++
            "  data dir:  {s}\n" ++
            "  web UI:    http://127.0.0.1:{d}/\n" ++
            "  health:    http://127.0.0.1:{d}/healthz\n" ++
            "  metrics:   http://127.0.0.1:{d}/metrics\n" ++
            "  forgetting: every 3600s\n" ++
            "  forget:    POST http://127.0.0.1:{d}/api/forget (preview; add {{\"dry_run\":false}} to actually forget)\n" ++
            "  sync:      POST http://127.0.0.1:{d}/api/sync\n",
        .{ port, dir, port, port, port, port, port },
    );
    const text = try readFile(alloc, log_path);
    defer alloc.free(text);
    try testing.expectEqualStrings(expected, text);
}
