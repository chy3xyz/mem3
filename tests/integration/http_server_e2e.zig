//! E2E test: HTTP server route layer.
//!
//! Spawns `mem3 serve` as a subprocess, hits the documented
//! endpoints over a TCP socket, verifies round-trip behaviour.
//! Falls back to in-process `Server.route()` testing on platforms
//! where subprocess spawn is not feasible (e.g. hermetic CI).
//!
//! This test is the regression guard for the v0.2.0 server fix
//! (4dd681a fix(round2): heap-corruption + replay leaks +
//! WAL upgrade migration). Before that fix the server crashed
//! under replay; this test would have caught it.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");

const c = std.c;

// Zig 0.17 dev's std.c does not expose execvp, so we declare it
// locally. Signature per POSIX.
extern "c" fn execvp([*:0]const u8, [*c]?[*:0]const u8) c_int;

// Static scratch buffer (see comment in store_persistence_e2e.zig
// for the rationale: returning a slice into a function-local buffer
// is a use-after-return in Zig 0.17).
var data_dir_buf: [128]u8 = undefined;
var data_dir_len: usize = 0;

fn makeDataDir(label: []const u8) ![]u8 {
    data_dir_len = (std.fmt.bufPrint(
        &data_dir_buf,
        "/tmp/mem3_http_{d}_{s}",
        .{ c.getpid(), label },
    ) catch return error.NoSpaceLeft).len;
    return data_dir_buf[0..data_dir_len];
}

fn wipeDataDir(data_dir: []const u8) void {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&z, "{s}/mem3.wal\x00", .{data_dir})) |wz| {
        _ = c.unlink(wz[0 .. wz.len - 1 :0].ptr);
    } else |_| {}
    if (std.fmt.bufPrint(&z, "{s}/snapshot.bin\x00", .{data_dir})) |wz| {
        _ = c.unlink(wz[0 .. wz.len - 1 :0].ptr);
    } else |_| {}
    var rmdir_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&rmdir_z, "{s}\x00", .{data_dir})) |dz| {
        _ = c.rmdir(dz[0 .. dz.len - 1 :0].ptr);
    } else |_| {}
}

const HttpResponse = struct {
    status: u16,
    body: []u8,

    fn deinit(self: *const HttpResponse, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
    }
};

/// Issue a single HTTP/1.1 request against a server on `port` and
/// return the raw response. Caller frees `body`.
fn httpRequest(alloc: std.mem.Allocator, port: u16, request: []const u8) !HttpResponse {
    var addr: std.posix.sockaddr.in = undefined;
    addr.family = c.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = std.mem.nativeToBig(u32, 0x7F000001); // 127.0.0.1

    const fd = c.socket(c.AF.INET, @bitCast(@as(u32, c.SOCK.STREAM)), 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);

    if (c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.ConnectFailed;

    var written: usize = 0;
    while (written < request.len) {
        const n = c.write(fd, request[written..].ptr, request.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }

    var buf: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }

    var it = std.mem.splitScalar(u8, buf[0..total], '\n');
    const status_line = it.next() orelse return error.MalformedResponse;
    var parts_it = std.mem.splitScalar(u8, status_line, ' ');
    _ = parts_it.next() orelse return error.MalformedResponse;
    const status_str = parts_it.next() orelse return error.MalformedResponse;
    const status = std.fmt.parseInt(u16, status_str, 10) catch return error.MalformedResponse;

    var header_end: usize = 0;
    while (it.next()) |line| {
        // HTTP uses CRLF line endings. The splitScalar on '\n' leaves a
        // trailing '\r' on each line; the empty separator between
        // headers and body is "\r\n" which becomes "\r" after split.
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) {
            header_end = @intFromPtr(line.ptr) - @intFromPtr(&buf[0]) + line.len + 1;
            break;
        }
    }
    if (header_end == 0 or header_end >= total) {
        return .{ .status = status, .body = try alloc.dupe(u8, "") };
    }
    const body = try alloc.dupe(u8, buf[header_end..total]);
    return .{ .status = status, .body = body };
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

    var assigned: std.posix.sockaddr.in = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(assigned));
    if (c.getsockname(fd, @ptrCast(&assigned), &len) != 0) return error.GetsocknameFailed;
    return std.mem.bigToNative(u16, assigned.port);
}

/// Spawn `mem3 serve` as a subprocess and wait for it to bind the
/// port. Uses POSIX `fork`/`exec` directly because `std.process.Child`
/// in Zig 0.17 dev requires a full `Io` runtime setup that's awkward
/// from a unit-test context. Returns the child pid; caller must
/// `kill(pid, SIGTERM)` and `waitpid` it.
fn spawnServer(data_dir: []const u8, port: u16) !c.pid_t {
    // Locate the mem3 binary relative to cwd. Tests run from the
    // project root via `zig build test`, so the binary is at
    // `zig-out/bin/mem3`.
    const exe_path: [:0]const u8 = "zig-out/bin/mem3";
    const port_str = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "{d}", .{port}, 0);
    defer std.heap.page_allocator.free(port_str);
    const data_dir_z = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}", .{data_dir}, 0);
    defer std.heap.page_allocator.free(data_dir_z);

    const argv = [_]?[*:0]const u8{
        exe_path.ptr,
        "serve",
        "--port",
        port_str.ptr,
        "--bind",
        "127.0.0.1",
        "--data-dir",
        data_dir_z.ptr,
        null,
    };

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child: redirect stdio, exec mem3 serve.
        _ = c.close(0);
        _ = c.close(1);
        _ = c.close(2);
        const devnull_z = "/dev/null\x00";
        const fd_null = c.open(devnull_z.ptr, .{ .ACCMODE = .RDWR }, @as(c.mode_t, 0));
        if (fd_null >= 0) {
            _ = c.dup2(fd_null, 0);
            _ = c.dup2(fd_null, 1);
            _ = c.dup2(fd_null, 2);
            _ = c.close(fd_null);
        }
        _ = execvp(exe_path.ptr, @ptrCast(@constCast(&argv)));
        c.exit(127);
    }
    return pid;
}

fn waitForPort(port: u16) bool {
    var attempt: u8 = 0;
    while (attempt < 30) : (attempt += 1) {
        // Zig 0.17 dev has no portable sleep on std.Thread without
        // the Io runtime. Use POSIX nanosleep directly.
        var req: c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = c.nanosleep(&req, null);
        const resp = httpRequest(std.heap.page_allocator, port, "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n") catch continue;
        if (resp.status == 200) {
            resp.deinit(std.heap.page_allocator);
            return true;
        }
        resp.deinit(std.heap.page_allocator);
    }
    return false;
}

const TestServer = struct {
    pid: c.pid_t,
    port: u16,
    data_dir: []u8,
    stopped: bool = false,

    fn start(data_dir: []u8) !TestServer {
        const port = try pickFreePort();
        const pid = try spawnServer(data_dir, port);
        if (!waitForPort(port)) {
            _ = c.kill(pid, c.SIG.TERM);
            _ = c.waitpid(pid, null, 0);
            return error.ServerStartupTimeout;
        }
        return .{ .pid = pid, .port = port, .data_dir = data_dir };
    }

    /// Idempotent: the restart test stops the server explicitly *and*
    /// defers the stop, so guarding here keeps us from kill/waitpid-ing an
    /// already-reaped pid.
    fn stop(self: *TestServer) void {
        if (self.stopped) return;
        self.stopped = true;
        _ = c.kill(self.pid, c.SIG.TERM);
        _ = c.waitpid(self.pid, null, 0);
    }
};

/// Skip helper. Callers must `return skipUnavailable(err);`.
/// Returning `error.SkipZigTest` makes the runner report a real SKIP
/// instead of counting a silently-unrun test as a pass — which is how these
/// three e2e tests used to report OK while never executing.
fn skipUnavailable(err: anyerror) error{SkipZigTest} {
    std.log.warn("skipping: subprocess unavailable ({s})", .{@errorName(err)});
    return error.SkipZigTest;
}

test "E2E HTTP: /healthz responds 200 with status:ok" {
    const data_dir = try makeDataDir("healthz");
    wipeDataDir(data_dir);

    var srv = TestServer.start(data_dir) catch |err| {
        wipeDataDir(data_dir);
        return skipUnavailable(err);
    };
    defer srv.stop();
    defer wipeDataDir(srv.data_dir);

    const alloc = testing.allocator;
    const resp = try httpRequest(alloc, srv.port, "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer resp.deinit(alloc);
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(std.mem.indexOf(u8, resp.body, "ok") != null);
}

test "E2E HTTP: POST /api/memcells inserts, GET retrieves" {
    const data_dir = try makeDataDir("postget");
    wipeDataDir(data_dir);

    var srv = TestServer.start(data_dir) catch |err| {
        wipeDataDir(data_dir);
        return skipUnavailable(err);
    };
    defer srv.stop();
    defer wipeDataDir(srv.data_dir);

    const alloc = testing.allocator;

    const post_body =
        \\{"source":"spirit","episode":"first http cell","facts":"user|loves|zig","goalId":1,"relevance":0.7}
    ;
    var post_req_buf: [1024]u8 = undefined;
    const post_req = std.fmt.bufPrint(
        &post_req_buf,
        "POST /api/memcells HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ post_body.len, post_body },
    ) catch return error.NoSpaceLeft;
    const post_resp = try httpRequest(alloc, srv.port, post_req);
    defer post_resp.deinit(alloc);
    try testing.expectEqual(@as(u16, 201), post_resp.status);

    // Body is JSON like `{"id":N,...}`. Extract the inserted id
    // by scanning for `"id":` then reading the integer.
    const id_marker = std.mem.indexOf(u8, post_resp.body, "\"id\":") orelse return error.MalformedResponse;
    const id_start = id_marker + "\"id\":".len;
    var id_len: usize = 0;
    while (id_start + id_len < post_resp.body.len and
        post_resp.body[id_start + id_len] >= '0' and
        post_resp.body[id_start + id_len] <= '9')
    {
        id_len += 1;
    }
    if (id_len == 0) return error.MalformedResponse;
    const inserted_id = try std.fmt.parseInt(u64, post_resp.body[id_start..][0..id_len], 10);

    var get_req_buf: [256]u8 = undefined;
    const get_req = std.fmt.bufPrint(
        &get_req_buf,
        "GET /api/memcells/{d} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        .{inserted_id},
    ) catch return error.NoSpaceLeft;
    const get_resp = try httpRequest(alloc, srv.port, get_req);
    defer get_resp.deinit(alloc);
    try testing.expectEqual(@as(u16, 200), get_resp.status);
    try testing.expect(std.mem.indexOf(u8, get_resp.body, "first http cell") != null);
}

test "E2E HTTP: server restart preserves inserted cells" {
    const data_dir = try makeDataDir("restart");
    wipeDataDir(data_dir);

    // Server #1: insert 2 cells, then shutdown.
    {
        var srv1 = TestServer.start(data_dir) catch |err| {
            wipeDataDir(data_dir);
            return skipUnavailable(err);
        };
        defer srv1.stop();

        const alloc = testing.allocator;
        for ([_][]const u8{ "first server run cell A", "first server run cell B" }) |episode| {
            var post_req_buf: [1024]u8 = undefined;
            var body_buf: [512]u8 = undefined;
            const post_body = std.fmt.bufPrint(
                &body_buf,
                "{{\"source\":\"matter\",\"episode\":\"{s}\",\"facts\":\"\",\"goalId\":1,\"relevance\":0.5}}",
                .{episode},
            ) catch return error.NoSpaceLeft;
            const post_req = std.fmt.bufPrint(
                &post_req_buf,
                "POST /api/memcells HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
                .{ post_body.len, post_body },
            ) catch return error.NoSpaceLeft;
            const resp = try httpRequest(alloc, srv1.port, post_req);
            try testing.expectEqual(@as(u16, 201), resp.status);
            resp.deinit(alloc);
        }
        var sync_req_buf: [256]u8 = undefined;
        // SAFETY: this format string has zero arguments, so the rendered
        // request is a compile-time constant 82 bytes; sync_req_buf holds
        // 256. bufPrint cannot fail.
        const sync_req = std.fmt.bufPrint(
            &sync_req_buf,
            "POST /api/sync HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{},
        ) catch unreachable;
        const sync_resp = try httpRequest(alloc, srv1.port, sync_req);
        sync_resp.deinit(alloc);

        srv1.stop();
    }

    // Server #2: same data dir, expect to see both cells.
    {
        var srv2 = TestServer.start(data_dir) catch |err| {
            wipeDataDir(data_dir);
            return skipUnavailable(err);
        };
        defer srv2.stop();
        defer wipeDataDir(srv2.data_dir);

        const alloc = testing.allocator;
        const resp = try httpRequest(alloc, srv2.port, "GET /api/memcells HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
        defer resp.deinit(alloc);
        try testing.expectEqual(@as(u16, 200), resp.status);
        try testing.expect(std.mem.indexOf(u8, resp.body, "first server run cell A") != null);
        try testing.expect(std.mem.indexOf(u8, resp.body, "first server run cell B") != null);
    }
}
test "E2E HTTP: /metrics publishes the six constitutional families" {
    // Constitution Principle VII requires the daemon to publish
    // request count, retrieval P50/P95/P99, memstore size, vector
    // index depth, hyperedge count and forgetting rate. This drives a
    // real subprocess over a real socket — the unit tests in
    // `src/server/http_server.zig` exercise the same renderer through
    // `route`, but only this path proves the bytes actually leave the
    // process.
    const data_dir = try makeDataDir("metrics");
    wipeDataDir(data_dir);

    var srv = TestServer.start(data_dir) catch |err| {
        wipeDataDir(data_dir);
        return skipUnavailable(err);
    };
    defer srv.stop();
    defer wipeDataDir(srv.data_dir);

    const alloc = testing.allocator;

    // A query, so the latency histogram is non-empty when scraped —
    // an all-zero /metrics would pass a name-only assertion while
    // proving nothing about the recording path.
    var q_buf: [1024]u8 = undefined;
    const q_body = "{\"text\":\"e2e metrics probe\",\"maxHops\":0}";
    const query_req = std.fmt.bufPrint(
        &q_buf,
        "POST /api/query HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ q_body.len, q_body },
    ) catch return error.NoSpaceLeft;
    const query_resp = try httpRequest(alloc, srv.port, query_req);
    defer query_resp.deinit(alloc);
    try testing.expectEqual(@as(u16, 200), query_resp.status);

    const resp = try httpRequest(alloc, srv.port, "GET /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer resp.deinit(alloc);
    try testing.expectEqual(@as(u16, 200), resp.status);

    const required = [_][]const u8{
        // request count
        "mem3_requests_total",
        // retrieval P50/P95/P99
        "mem3_retrieval_latency_p50_us",
        "mem3_retrieval_latency_p95_us",
        "mem3_retrieval_latency_p99_us",
        "mem3_retrieval_latency_samples_total",
        // memstore size
        "mem3_memstore_cells",
        "mem3_memstore_cells_by_source",
        // hyperedge count
        "mem3_hyperedges",
        // vector index depth
        "mem3_vector_index_depth",
        // forgetting rate
        "mem3_forgetting_rate",
    };
    for (required) |name| {
        // No logging on the failure path, even here: under `--listen=-`
        // any stderr write from inside a test desynchronises the
        // runner protocol and kills the test binary, and `zig build
        // test` reports success anyway. Returning the error is the only
        // way to make this failure visible.
        try testing.expect(std.mem.indexOf(u8, resp.body, name) != null);
    }

    // Every source variant is reported, not just whichever one the
    // daemon happened to see traffic for.
    for ([_][]const u8{ "matter", "form", "spirit" }) |src| {
        var line: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&line, "mem3_memstore_cells_by_source{{source=\"{s}\"}}", .{src}) catch return error.NoSpaceLeft;
        try testing.expect(std.mem.indexOf(u8, resp.body, needle) != null);
    }

    // The histogram recorded the one query we sent.
    try testing.expect(std.mem.indexOf(u8, resp.body, "mem3_retrieval_latency_samples_total 1\n") != null);
}
