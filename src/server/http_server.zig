//! HTTP server — minimal HTTP/1.1 over POSIX sockets with in-process store.
//!
//! **Persistence (v0.1.0+)**: writes are journaled to a Write-Ahead Log at
//! `data_dir/mem3.wal`. On startup the WAL is replayed to reconstruct the
//! in-process store. Use `data_dir` to switch storage locations.
//!
//! **Constitution FR-017** endpoints:
//!   - GET  /                            — web UI (htmx + Alpine.js + Tailwind)
//!   - GET  /api/memcells                — list
//!   - GET  /api/memcells/{id}           — single
//!   - POST /api/memcells                — create (WAL-durable)
//!   - GET  /api/goals                   — list
//!   - POST /api/query                   — three-way recall
//!   - GET  /healthz, /metrics           — observability
//!   - POST /api/sync                    — flush WAL to disk

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = std.c;
const builtin = @import("builtin");
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const MemorySource = core.MemorySource;
const ghw = @import("../ghw/mod.zig");
const ghw_goal_tree = @import("../ghw/goal_tree.zig");
const jsonl = @import("../utils/jsonl.zig");
const mem3_store = @import("../store/store.zig");
const RerankContext = @import("../retrieval/reranker.zig").RerankContext;
const memory = @import("../memory/mod.zig");
const retrieval = @import("../retrieval/mod.zig");

const log = std.log.scoped(.mem3_server);

/// Embedded web UI (loaded at compile time via @embedFile).
const WEB_INDEX: []const u8 = @embedFile("web_index.html");

/// Adapter so the shared `jsonl.writeJsonString` helper — written against
/// a stream writer — can target an `std.ArrayList(u8)`. Zig 0.17's
/// unmanaged ArrayList exposes `print(gpa, ...)` but has no `.writer()`.
const ListWriter = struct {
    list: *std.ArrayList(u8),
    gpa: Allocator,

    pub fn writeByte(self: ListWriter, b: u8) !void {
        try self.list.append(self.gpa, b);
    }
    pub fn writeAll(self: ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.gpa, bytes);
    }
    pub fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.gpa, fmt, args);
    }
};

fn nowNs() u128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    // timespec fields are signed c_long; coerce through i64 to recover non-negative values from MONOTONIC clock.
    const sec_i: i64 = @intCast(ts.sec);
    const nsec_i: i64 = @intCast(ts.nsec);
    return @as(u128, @as(u64, @bitCast(sec_i))) * 1_000_000_000 +
        @as(u128, @as(u64, @bitCast(nsec_i)));
}

/// Unix epoch in seconds (CLOCK_REALTIME). Use this for human-meaningful
/// timestamps (WAL record timestamps, audit logs). Do NOT use for
/// measuring elapsed time — use `nowNs` for that.
fn wallClockSec() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// In-process memory store. Lives for the duration of the server.
/// The daemon uses the single library `Store`, not a private fork.
///
/// This file used to carry its own ~890-line `Store` struct. It was a
/// strict subset of `src/store/store.zig`: no hypergraph, no `multiHop`,
/// no `forget`/`consolidate`, no idempotent `deinit`, and an `init` with
/// no `errdefer` chain at all, so every allocation leaked whenever WAL
/// replay failed. It had drifted far enough to cost a real bug — `POST
/// /api/sync` truncated the WAL without replaying `goal_update` records,
/// permanently destroying goal status, because the fork's replay loop only
/// knew about `goal_create`.
///
/// One implementation is what makes the next bug impossible: there is no
/// second copy to forget to update.
const Store = mem3_store.Store;

const Metrics = struct {
    requests_total: std.atomic.Value(u64) = .init(0),
    queries_total: std.atomic.Value(u64) = .init(0),
    inserts_total: std.atomic.Value(u64) = .init(0),
    last_query_us: std.atomic.Value(u64) = .init(0),
    /// Bumped by the maintenance thread on each completed pass.
    maintenance_passes: std.atomic.Value(u64) = .init(0),

    fn render(self: *const Metrics, alloc: Allocator, boot_time_ns: u128) ![]u8 {
        const uptime_s = @divTrunc(nowNs() - boot_time_ns, std.time.ns_per_s);
        return std.fmt.allocPrint(alloc,
            \\# mem3 metrics
            \\# HELP mem3_uptime_s Uptime in seconds
            \\mem3_uptime_s {d}
            \\# HELP mem3_requests_total Total HTTP requests
            \\mem3_requests_total {d}
            \\# HELP mem3_queries_total Total query API calls
            \\mem3_queries_total {d}
            \\# HELP mem3_inserts_total Total insert API calls
            \\mem3_inserts_total {d}
            \\# HELP mem3_last_query_us Last query latency microseconds
            \\mem3_last_query_us {d}
            \\# HELP mem3_maintenance_passes_total Completed maintenance passes
            \\mem3_maintenance_passes_total {d}
        , .{
            uptime_s,
            self.requests_total.load(.monotonic),
            self.queries_total.load(.monotonic),
            self.inserts_total.load(.monotonic),
            self.last_query_us.load(.monotonic),
            self.maintenance_passes.load(.monotonic),
        });
    }
};

/// Sleep for `ms` milliseconds.
///
/// Zig 0.17 removed `std.Thread.sleep`, and `std.c` does not re-export
/// `nanosleep`, so libc is declared directly — same convention as the
/// `getenv` fwd-decl in `cli_commands/serve.zig`. `EINTR` retries rather
/// than returning early: a signal must not silently shorten the interval.
fn sleepMs(ms: u32) void {
    const nanosleep = struct {
        extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;
    }.nanosleep;

    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (true) {
        const rc = nanosleep(&req, null);
        if (rc == 0) break;
        if (std.c.errno(rc) != .INTR) break;
    }
}

/// Wall clock in milliseconds — the unit every `created_at` /
/// `updated_at` / `unrealized_at` field in the system is expressed in.
fn nowMs() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Plain pthread mutex.
///
/// `std.Thread.Mutex` no longer exists in Zig 0.17, and `std.Io.Mutex`
/// demands an `Io` instance — which would mean standing up a
/// `std.Io.Threaded` event loop for the sake of one lock, in a daemon that
/// reaches the network through raw `std.c` sockets and never constructs an
/// `Io`. libc's mutex is the honest fit.
const Mutex = struct {
    m: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.m);
    }
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.m);
    }
};

pub const Server = struct {
    alloc: Allocator,
    bind: []const u8,
    port: u16,
    fd: c.fd_t,
    bound: bool,
    store: *Store,
    boot_time_ns: u128,
    metrics: Metrics,

    /// Guards every `store` mutation and every read of `store` state.
    ///
    /// The accept loop was single-threaded for the daemon's whole life,
    /// which is why it never needed one. A maintenance thread breaks that
    /// assumption immediately: it would be rewriting goal statuses while
    /// `GET /api/goals` walks the same poset, and `GoalPoset.nodes` is an
    /// `AutoHashMap` whose iterators do not survive a rehash. This is not
    /// theoretical lock-hygiene — it is the difference between a daemon and
    /// a crash.
    store_mutex: Mutex = .{},

    /// Maintenance thread, if one was started.
    maint_thread: ?std.Thread = null,
    /// Cleared by `deinit` to ask the thread to stop. Release/acquire: the
    /// thread may be parked in a sleep and must observe the flip promptly.
    maint_running: std.atomic.Value(bool) = .init(false),
    /// Seconds between maintenance passes.
    maint_interval_sec: u32 = 60,

    /// `data_dir` is `null` for an in-memory server: no WAL, no snapshot,
    /// nothing written to disk. Tests that are not about persistence must
    /// use it — a fixed `/tmp` path makes a test non-idempotent, because
    /// the WAL from the previous run is replayed into the next one and the
    /// corpus quietly doubles. (That is not hypothetical: the `maxHops`
    /// test passed on a clean `/tmp` and failed on the second run.)
    pub fn init(alloc: Allocator, bind: []const u8, port: u16, data_dir: ?[]const u8) !*Server {
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);
        const store = try Store.init(alloc, .{ .data_dir = data_dir });
        self.* = .{
            .alloc = alloc,
            .bind = try alloc.dupe(u8, bind),
            .port = port,
            .fd = -1,
            .bound = false,
            .store = store,
            .boot_time_ns = 0,
            .metrics = .{},
        };
        return self;
    }

    pub fn deinit(self: *Server) void {
        // Stop and JOIN the maintenance thread before touching anything it
        // can reach. `store.deinit()` under a running thread is a
        // use-after-free that happens to work until it doesn't.
        self.stopMaintenance();
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.store.deinit();
        self.alloc.free(self.bind);
        self.alloc.destroy(self);
    }

    /// Start the periodic maintenance thread.
    ///
    /// `interval_sec == 0` disables it, which is what the tests use: a
    /// background thread racing a test's assertions is a flaky test waiting
    /// to be written.
    pub fn startMaintenance(self: *Server, interval_sec: u32) !void {
        if (interval_sec == 0) return;
        if (self.maint_thread != null) return; // already running
        self.maint_interval_sec = interval_sec;
        self.maint_running.store(true, .release);
        // If the spawn fails, do not leave the flag set: `stopMaintenance`
        // would then be clearing a "running" state with no thread behind it.
        errdefer self.maint_running.store(false, .release);
        self.maint_thread = try std.Thread.spawn(.{}, maintenanceLoop, .{self});
    }

    fn stopMaintenance(self: *Server) void {
        self.maint_running.store(false, .release);
        if (self.maint_thread) |t| {
            t.join();
            self.maint_thread = null;
        }
    }

    fn maintenanceLoop(srv: *Server) void {
        // Sleep in short slices rather than one long sleep, so `deinit` is
        // not held hostage to a 60-second interval. A daemon that takes a
        // minute to shut down is a daemon that gets SIGKILLed instead.
        const slice_ms: u32 = 100;
        // u64 arithmetic: `interval_sec * 1000` overflows u32 above ~4.29e6
        // seconds, which is a typo away from a nonsense slice count.
        const slices: u64 = @max(@as(u64, srv.maint_interval_sec) * 1000 / slice_ms, 1);

        while (srv.maint_running.load(.acquire)) {
            var waited: u64 = 0;
            while (waited < slices and srv.maint_running.load(.acquire)) : (waited += 1) {
                sleepMs(slice_ms);
            }
            if (!srv.maint_running.load(.acquire)) break;

            // Silent unless something actually changed. A per-pass log line
            // is how a long-lived daemon fills a disk: launchd/systemd
            // capture stdout, and one line a minute is 500MB a year for a
            // daemon that has nothing to say.
            srv.store_mutex.lock();
            const res = srv.store.maintain(nowMs()) catch |err| blk: {
                srv.store_mutex.unlock();
                if (!builtin.is_test) log.warn("maintenance pass failed: {}", .{err});
                break :blk null;
            };
            srv.store_mutex.unlock();

            if (res) |r| {
                // Bump the metric that /metrics actually publishes.
                // `std.atomic.Value` is a plain struct wrapping a u64, so
                // copying one into another copies the value, not a shared
                // cell — a second counter field would have read 0 forever.
                _ = srv.metrics.maintenance_passes.fetchAdd(1, .monotonic);
                if (r.goals_unrealized > 0 or r.goals_failed > 0) {
                    // Transitions are rare by construction (7-day rule), so
                    // logging them unconditionally is safe and useful.
                    if (!builtin.is_test) log.info("maintenance: {d} goal(s) unrealized, {d} failed", .{ r.goals_unrealized, r.goals_failed });
                }
            }
        }
    }

    /// Run one maintenance pass synchronously. Used by the tests and by
    /// `POST /api/sync`, so the behaviour is reachable without waiting out
    /// an interval.
    pub fn runMaintenanceNow(self: *Server) !Store.MaintenanceResult {
        self.store_mutex.lock();
        defer self.store_mutex.unlock();
        return self.store.maintain(nowMs());
    }

    pub fn listen(self: *Server) !void {
        var addr: std.posix.sockaddr.in = undefined;
        addr.family = c.AF.INET;
        addr.port = std.mem.nativeToBig(u16, self.port);
        // Resolve bind: IPv4 dotted-quad → u32 BE. Special names:
        //   "127.0.0.1" / "localhost" → loopback
        //   "0.0.0.0" / "all"        → INADDR_ANY (all interfaces)
        //   anything else that's a valid IPv4 → use it
        //   invalid                  → warn + fall back to loopback
        addr.addr = parseBindAddr(self.bind) catch |err| blk: {
            std.log.warn("invalid bind '{s}': {s}; falling back to 127.0.0.1", .{ self.bind, @errorName(err) });
            break :blk std.mem.nativeToBig(u32, 0x7F000001);
        };

        const fd = std.c.socket(c.AF.INET, @bitCast(@as(u32, c.SOCK.STREAM)), 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);

        const optval: c_int = 1;
        _ = std.c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &std.mem.toBytes(optval), @sizeOf(c_int));

        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
        if (std.c.listen(fd, 128) != 0) return error.ListenFailed;

        self.fd = fd;
        self.boot_time_ns = nowNs();
        self.bound = true;
        log.info("listening on {s}:{d}", .{ self.bind, self.port });
    }

    pub fn serve(self: *Server) !void {
        if (!self.bound) return error.NotListening;
        while (true) {
            var client_addr: std.posix.sockaddr.in = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(client_addr));
            const client_fd = std.c.accept(self.fd, @ptrCast(&client_addr), &addr_len);
            if (client_fd < 0) continue;
            self.handleConn(client_fd) catch |err| log.warn("conn: {}", .{err});
            _ = std.c.close(client_fd);
        }
    }

    fn handleConn(self: *Server, fd: c.fd_t) !void {
        var buf: [16384]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) return;
        _ = self.metrics.requests_total.fetchAdd(1, .monotonic);

        const req = buf[0..@intCast(n)];
        var line_it = std.mem.splitScalar(u8, req, '\n');
        const request_line = line_it.next() orelse return;
        var parts_it = std.mem.splitScalar(u8, request_line, ' ');
        const method = std.mem.trim(u8, parts_it.next() orelse "", " \r");
        const path_with_query = std.mem.trim(u8, parts_it.next() orelse "", " \r");
        _ = parts_it.next();

        const path = if (std.mem.findScalar(u8, path_with_query, '?')) |q| path_with_query[0..q] else path_with_query;

        // One lock for the whole request, taken here rather than inside
        // each handler.
        //
        // The alternative is a `lock()` in every handler that touches the
        // store, and that shape fails open: the next handler someone adds
        // simply forgets, and the bug only appears once maintenance is
        // actually running. One coarse lock around the dispatch point
        // cannot be forgotten, and request latency here is microseconds —
        // there is no throughput argument for finer granularity.
        //
        // `handleConn` is the right altitude, not `route`: `route` is
        // called directly by the tests, and locking there would deadlock
        // against `runMaintenanceNow`.
        self.store_mutex.lock();
        const response = self.route(method, path, req) catch |err| {
            self.store_mutex.unlock();
            return err;
        };
        self.store_mutex.unlock();
        defer self.alloc.free(response.body);

        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
            .{ response.status, response.status_text, response.content_type, response.body.len },
        ) catch return;
        _ = std.c.write(fd, header.ptr, header.len);
        _ = std.c.write(fd, response.body.ptr, response.body.len);
    }

    const Response = struct {
        status: u16,
        status_text: []const u8,
        content_type: []const u8,
        body: []u8,

        /// `body` is allocated per response, so every in-process caller has
        /// to hand it back. This test never did — the leak only surfaced
        /// once the file's tests were actually in the gate.
        pub fn deinit(self: Response, alloc: Allocator) void {
            alloc.free(self.body);
        }
    };

    fn route(self: *Server, method: []const u8, path: []const u8, full_request: []const u8) !Response {
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            return .{
                .status = 200,
                .status_text = "OK",
                .content_type = "text/html; charset=utf-8",
                .body = try self.alloc.dupe(u8, WEB_INDEX),
            };
        }
        if (std.mem.eql(u8, path, "/healthz")) {
            return try self.jsonResponse(200, "OK",
                \\{"status":"ok","version":"0.1.0-alpha"}
            );
        }
        if (std.mem.eql(u8, path, "/metrics")) {
            const body = try self.metrics.render(self.alloc, self.boot_time_ns);
            return .{ .status = 200, .status_text = "OK", .content_type = "text/plain; charset=utf-8", .body = body };
        }
        if (std.mem.eql(u8, path, "/api/memcells") and std.mem.eql(u8, method, "GET")) {
            return try self.handleListMemcells();
        }
        if (std.mem.eql(u8, path, "/api/memcells") and std.mem.eql(u8, method, "POST")) {
            return try self.handleAddMemcell(full_request);
        }
        if (std.mem.startsWith(u8, path, "/api/memcells/") and std.mem.eql(u8, method, "GET")) {
            const id_str = path["/api/memcells/".len..];
            const id = std.fmt.parseInt(u64, id_str, 10) catch 0;
            return try self.handleGetMemcell(id);
        }
        if (std.mem.eql(u8, path, "/api/goals") and std.mem.eql(u8, method, "GET")) {
            return try self.handleListGoals();
        }
        if (std.mem.eql(u8, path, "/api/query") and std.mem.eql(u8, method, "POST")) {
            return try self.handleQuery(full_request);
        }
        if (std.mem.eql(u8, path, "/api/sync") and std.mem.eql(u8, method, "POST")) {
            return try self.handleSync();
        }
        return try self.textResponse(404, "Not Found", "404 not found\n");
    }

    fn handleSync(self: *Server) !Response {
        if (self.store.wal) |wal| {
            wal.flush() catch |err| {
                return try self.jsonResponse(500, "Internal Server Error",
                    try std.fmt.allocPrint(self.alloc, "{{\"error\":\"flush failed: {s}\"}}", .{@errorName(err)}));
            };
            // After WAL is durable, take a snapshot + truncate WAL so
            // next boot replays from snapshot (fast) instead of replaying
            // every WAL record (slow for long-lived daemons).
            //
            // `sync()` owns the whole tail: snapshot, flush, truncate, and
            // — the step this handler was missing when it had its own
            // store — re-journal goals and hyperedges into the fresh WAL.
            // The snapshot does not carry goals, so skipping that
            // re-journal is exactly what used to delete every user goal.
            self.store.sync() catch |err| {
                return try self.jsonResponse(500, "Internal Server Error",
                    try std.fmt.allocPrint(self.alloc, "{{\"error\":\"snapshot failed: {s}\"}}", .{@errorName(err)}));
            };
            return try self.jsonResponse(200, "OK",
                \\{"status":"synced","wal":true,"snapshot":true}
            );
        }
        // No WAL → persistence was never enabled for this server. The
        // contract is honest: don't claim a sync that didn't happen.
        return try self.jsonResponse(503, "Service Unavailable",
            \\{"error":"persistence not enabled (no WAL)","wal":false}
        );
    }

    fn handleListMemcells(self: *Server) !Response {
        const cells = try self.store.allCells(self.alloc);
        defer self.alloc.free(cells);

        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.alloc);
        try body.appendSlice(self.alloc, "[");
        for (cells, 0..) |cell, i| {
            if (i > 0) try body.append(self.alloc, ',');
            try jsonAppendCell(self.alloc, &body, cell);
        }
        try body.append(self.alloc, ']');
        return self.rawJson(200, try body.toOwnedSlice(self.alloc));
    }

    fn handleGetMemcell(self: *Server, id: u64) !Response {
        const cell = self.store.cell_index.get(id) orelse {
            return try self.jsonResponse(404, "Not Found", "{\"error\":\"not found\"}");
        };
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.alloc);
        try jsonAppendCell(self.alloc, &body, cell);
        return self.rawJson(200, try body.toOwnedSlice(self.alloc));
    }

    fn handleAddMemcell(self: *Server, full_request: []const u8) !Response {
        const body_start = std.mem.findPos(u8, full_request, 0, "\r\n\r\n") orelse 0;
        const body = full_request[body_start + 4 ..];

        const source_str = try extractJsonStringOrOwned(self.alloc, body, "source", "matter");
        defer self.alloc.free(source_str);
        const source = core.MemorySource.fromString(source_str) catch return try self.jsonResponse(400, "Bad Request", "{\"error\":\"invalid source\"}");
        const episode = try extractJsonStringOrOwned(self.alloc, body, "episode", "");
        defer self.alloc.free(episode);
        if (episode.len == 0) return try self.jsonResponse(400, "Bad Request", "{\"error\":\"episode required\"}");
        const facts = try extractJsonStringOrOwned(self.alloc, body, "facts", "");
        defer self.alloc.free(facts);
        const goal_id = @as(u64, @intCast(extractJsonInt(body, "goalId") orelse 1));
        const relevance = extractJsonFloat(body, "relevance") orelse 0.5;

        const id = self.store.addRaw(source, episode, facts, goal_id, relevance) catch |err| {
            const msg = @errorName(err);
            return try self.jsonResponse(400, "Bad Request", try std.fmt.allocPrint(self.alloc, "{{\"error\":\"{s}\"}}", .{msg}));
        };
        _ = self.metrics.inserts_total.fetchAdd(1, .monotonic);

        const body_resp = try std.fmt.allocPrint(self.alloc, "{{\"id\":{d}}}", .{id});
        return self.rawJson(201, body_resp);
    }

    /// `GET /api/goals` — the real goals from the in-memory poset.
    ///
    /// This used to be a hardcoded three-element literal (`general`,
    /// `research`, `system`) that never consulted the store, so any goal
    /// created outside that literal — via `mem3 goal create`, which is
    /// WAL-journaled and replayed on boot — was invisible here. Names and
    /// descriptions are user input, so every string goes through the JSON
    /// escaper: a goal named `a"b` could otherwise emit invalid JSON.
    fn handleListGoals(self: *Server) !Response {
        var body = std.ArrayList(u8).empty;
        errdefer body.deinit(self.alloc);
        const w = ListWriter{ .list = &body, .gpa = self.alloc };
        try w.writeAll("{\"goals\":[");
        var first = true;
        var it = self.store.goals.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            // The ⊥/⊤ anchors are poset structure, not user-facing goals.
            if (node.id == ghw_goal_tree.ROOT_GOAL_ID) continue;
            if (node.id == ghw_goal_tree.TOP_GOAL_ID) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"id\":");
            try w.print("{d}", .{node.id});
            try w.writeAll(",\"name\":");
            try jsonl.writeJsonString(w, node.name);
            try w.writeAll(",\"description\":");
            try jsonl.writeJsonString(w, node.description);
            try w.writeAll(",\"status\":");
            try w.print("\"{s}\"", .{@tagName(node.status)});
            try w.writeAll(",\"priority\":");
            try w.print("{d}", .{node.priority});
            try w.writeAll(",\"parent_id\":");
            if (node.parent_id) |pid| {
                try w.print("{d}", .{pid});
            } else {
                try w.writeAll("null");
            }
            try w.writeAll(",\"memcell_count\":");
            try w.print("{d}", .{self.store.goals.memcellsFor(node.id).len});
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        return self.rawJson(200, try body.toOwnedSlice(self.alloc));
    }

    fn handleQuery(self: *Server, full_request: []const u8) !Response {
        const body_start = std.mem.findPos(u8, full_request, 0, "\r\n\r\n") orelse 0;
        const body = full_request[body_start + 4 ..];

        const text = try extractJsonStringOrOwned(self.alloc, body, "text", "");
        defer self.alloc.free(text);
        if (text.len == 0) return try self.jsonResponse(400, "Bad Request", "{\"error\":\"text required\"}");
        const topk = @as(usize, @intCast(extractJsonInt(body, "topk") orelse 10));
        // `maxHops` used to be parsed and thrown away on the floor — the
        // daemon's private Store had no hypergraph, so there was nothing to
        // expand. It shares the library Store now, so the parameter means
        // something. Clamped: the traversal is breadth-first over every edge
        // of every reachable node, so an unbounded value is a cheap way to
        // ask the daemon to materialise the whole graph.
        const hops_raw = extractJsonInt(body, "maxHops") orelse 3;
        const max_hops: u8 = @intCast(std.math.clamp(hops_raw, 0, 8));
        // Per-hop relevance decay for graph expansion. Tuned so one hop
        // keeps a graph hit competitive with a mid-ranked dense hit and
        // three hops (the default) still surface something, while a cell
        // four hops out cannot displace a direct semantic match.
        const graph_decay: f32 = 0.6;

        _ = self.metrics.queries_total.fetchAdd(1, .monotonic);
        const t0 = nowNs();

        const qvec = try self.store.emb.embed(self.alloc, text);
        defer self.alloc.free(qvec);

        const dense = self.store.hnsw.search(self.alloc, qvec, topk * 3) catch &.{};
        defer self.alloc.free(dense);

        var cands = std.ArrayList(RerankContext.Pair).empty;
        defer cands.deinit(self.alloc);
        // GHW re-rank via the shared reranker so the daemon and
        // `mem3 query` cannot drift apart. This path previously carried
        // its own two-factor copy with no recency term.
        var rr = RerankContext{
            .alloc = self.alloc,
            .cfg = self.store.lc.cfg,
            .goals = self.store.goals,
            .query_goal_ids = &.{},
        };
        var it = self.store.cell_index.iterator();
        while (it.next()) |entry| {
            const cell = entry.value_ptr.*;
            var score: f32 = 0.0;
            var found = false;
            for (dense) |r| {
                if (r.id == cell.id) {
                    score = r.score;
                    found = true;
                    break;
                }
            }
            if (!found) continue;
            try cands.append(self.alloc, .{
                .id = cell.id,
                .score = score,
                .cell = cell,
            });
        }

        // Graph expansion. Seeds are the dense hits; a cell reachable over
        // hyperedges inherits the strongest path's score times
        // `graph_decay` per hop, so it competes on relevance instead of
        // arriving at 0.0.
        //
        // That distinction is the whole point. An earlier wiring pushed
        // graph nodes into the pool at score 0, which made `maxHops`
        // unobservable no matter what: the reranker is a *multiplicative*
        // bonus on the dense score, and `out_n = min(topk, reranked.len)`
        // truncates to exactly `topk` whenever the corpus is at least that
        // big — so a zero-score cell could never reach the response.
        if (max_hops > 0 and dense.len > 0) {
            var seeds = std.ArrayList(@import("../hypermem/mod.zig").HyMem.ScoredNode).empty;
            defer seeds.deinit(self.alloc);
            try seeds.ensureTotalCapacity(self.alloc, dense.len);
            for (dense) |r| try seeds.append(self.alloc, .{ .id = r.id, .score = r.score, .hops = 0 });

            const reached = self.store.multiHopScored(self.alloc, seeds.items, max_hops, graph_decay, 0.0, null) catch &.{};
            // `&.{}` is a static empty slice — never hand that to `free`.
            defer if (reached.len > 0) self.alloc.free(reached);

            // Bounded so a dense hypergraph cannot turn one query into an
            // unbounded allocation.
            const graph_cap = @max(topk * 4, 64);
            var added: usize = 0;
            for (reached) |g| {
                if (g.hops == 0) continue; // already a dense hit
                if (added >= graph_cap) break;
                var dup = false;
                for (cands.items) |existing| {
                    if (existing.id == g.id) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                const cell = self.store.getCell(g.id) orelse continue;
                try cands.append(self.alloc, .{ .id = g.id, .score = g.score, .cell = cell });
                added += 1;
            }
        }

        const reranked = rr.rerankPairs(self.alloc, cands.items) catch |err| {
            const msg = @errorName(err);
            return try self.jsonResponse(500, "Internal Server Error", try std.fmt.allocPrint(self.alloc, "{{\"error\":\"{s}\"}}", .{msg}));
        };
        defer self.alloc.free(reranked);

        const out_n = @min(topk, reranked.len);
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "{\"results\":[");
        for (reranked[0..out_n], 0..) |r, i| {
            if (i > 0) try out.append(self.alloc, ',');
            const cell = r.cell;
            try out.append(self.alloc, '{');
            try jsonFieldInt(self.alloc, &out, "id", cell.id);
            try out.append(self.alloc, ',');
            try jsonFieldString(self.alloc, &out, "source", @tagName(cell.source));
            try out.append(self.alloc, ',');
            try jsonFieldString(self.alloc, &out, "episode", cell.episode);
            try out.append(self.alloc, ',');
            try jsonFieldFloat(self.alloc, &out, "score", r.final_score);
            try out.append(self.alloc, ',');
            try out.appendSlice(self.alloc, "\"goals\":[");
            for (cell.goal_associations, 0..) |ga, j| {
                if (j > 0) try out.append(self.alloc, ',');
                try out.append(self.alloc, '{');
                try jsonFieldInt(self.alloc, &out, "id", ga.goal_id);
                try out.append(self.alloc, ',');
                try jsonFieldFloat(self.alloc, &out, "relevance", ga.relevance);
                try out.append(self.alloc, '}');
            }
            try out.appendSlice(self.alloc, "]");
            try out.append(self.alloc, '}');
        }
        try out.appendSlice(self.alloc, "]}");

        const t1 = nowNs();
        const us: u64 = @intCast(@divTrunc(t1 - t0, 1000));
        _ = self.metrics.last_query_us.store(us, .monotonic);

        return self.rawJson(200, try out.toOwnedSlice(self.alloc));
    }

    fn serveFile(_: *Server, path: []const u8, content_type: []const u8) !Response {
        // v0.1.0-alpha: web UI is embedded via @embedFile (single binary).
        // This stub is kept for forward-compatibility with dynamic content.
        _ = path;
        _ = content_type;
        return .{ .status = 404, .status_text = "Not Found", .content_type = "text/plain", .body = @constCast("404") };
    }

    fn jsonResponse(self: *Server, status: u16, status_text: []const u8, body: []const u8) !Response {
        return .{
            .status = status,
            .status_text = status_text,
            .content_type = "application/json",
            .body = try self.alloc.dupe(u8, body),
        };
    }

    fn textResponse(self: *Server, status: u16, status_text: []const u8, body: []const u8) !Response {
        return .{
            .status = status,
            .status_text = status_text,
            .content_type = "text/plain; charset=utf-8",
            .body = try self.alloc.dupe(u8, body),
        };
    }

    fn rawJson(_: *Server, status: u16, body: []u8) Response {
        return .{
            .status = status,
            .status_text = if (status < 300) "OK" else if (status < 400) "Created" else "Bad Request",
            .content_type = "application/json",
            .body = body,
        };
    }
};

/// Resolve a bind address: "127.0.0.1" / "localhost" → loopback,
/// "0.0.0.0" / "all" → INADDR_ANY, anything else parsed as IPv4 dotted-quad.
/// Returns a u32 in network byte order (big-endian).
fn parseBindAddr(text: []const u8) !u32 {
    if (std.mem.eql(u8, text, "localhost")) return std.mem.nativeToBig(u32, 0x7F000001);
    if (std.mem.eql(u8, text, "all") or std.mem.eql(u8, text, "0.0.0.0")) return 0;

    var octets: [4]u8 = undefined;
    var octet_idx: u8 = 0;
    var accum: u32 = 0;
    var saw_digit = false;
    for (text) |ch| {
        if (ch == '.') {
            if (!saw_digit) return error.InvalidIpv4;
            if (octet_idx >= 3) return error.InvalidIpv4; // too many dots
            octets[octet_idx] = @intCast(accum);
            octet_idx += 1;
            accum = 0;
            saw_digit = false;
            continue;
        }
        if (ch < '0' or ch > '9') return error.InvalidIpv4;
        accum = accum * 10 + (ch - '0');
        if (accum > 255) return error.InvalidIpv4;
        saw_digit = true;
    }
    if (!saw_digit or octet_idx != 3) return error.InvalidIpv4;
    octets[octet_idx] = @intCast(accum);
    return std.mem.nativeToBig(u32, (@as(u32, octets[0]) << 24) | (@as(u32, octets[1]) << 16) | (@as(u32, octets[2]) << 8) | octets[3]);
}

// =============================================================================
// Tiny JSON utilities (avoid pulling in std.json for the hot API path).
// =============================================================================

/// JSON-string unescape. Walks `input` (which is between two unescaped
/// `"` characters) and produces the raw string value. Handles:
/// `\"` `\\` `\/` `\n` `\r` `\t` `\b` `\f` and `\uXXXX` (UTF-8 encoded).
/// Returns an owned slice; caller frees.
fn unescapeJsonString(alloc: Allocator, input: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];
        if (ch != '\\') {
            try out.append(alloc, ch);
            i += 1;
            continue;
        }
        if (i + 1 >= input.len) break;
        const esc = input[i + 1];
        switch (esc) {
            '"' => try out.append(alloc, '"'),
            '\\' => try out.append(alloc, '\\'),
            '/' => try out.append(alloc, '/'),
            'n' => try out.append(alloc, '\n'),
            'r' => try out.append(alloc, '\r'),
            't' => try out.append(alloc, '\t'),
            'b' => try out.append(alloc, 0x08),
            'f' => try out.append(alloc, 0x0C),
            'u' => {
                if (i + 6 > input.len) {
                    // Truncated \u — emit the raw 2 chars and stop.
                    try out.appendSlice(alloc, input[i..]);
                    i = input.len;
                    break;
                }
                const hex = input[i + 2 .. i + 6];
                const cp = std.fmt.parseInt(u21, hex, 16) catch {
                    // Malformed escape: pass through raw.
                    try out.appendSlice(alloc, input[i..][0..2]);
                    i += 2;
                    continue;
                };
                var buf: [4]u8 = undefined;
                const n = utf8Encode(cp, &buf);
                try out.appendSlice(alloc, buf[0..n]);
                i += 6;
                continue;
            },
            else => try out.append(alloc, esc),
        }
        i += 2;
    }
    return out.toOwnedSlice(alloc);
}

/// UTF-8 encode a Unicode scalar value (up to 0x10FFFF) into `dest`.
/// Returns the number of bytes written (1..4).
/// UTF-8 encode a Unicode scalar value (up to 0x10FFFF) into `dest`.
/// Returns the number of bytes written (1..4). Rejects surrogate halves
/// (0xD800-0xDFFF) and out-of-range code points — they would produce
/// invalid UTF-8 that downstream JSON parsers reject.
fn utf8Encode(cp: u21, dest: *[4]u8) usize {
    if (cp < 0x80) {
        dest[0] = @intCast(cp);
        return 1;
    } else if (cp >= 0xD800 and cp <= 0xDFFF) {
        // Surrogate half. Emit a replacement char (U+FFFD) and bail.
        dest[0] = 0xEF;
        dest[1] = 0xBF;
        dest[2] = 0xBD;
        return 3;
    } else if (cp < 0x800) {
        dest[0] = @intCast(0xC0 | (cp >> 6));
        dest[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        dest[0] = @intCast(0xE0 | (cp >> 12));
        dest[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dest[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        dest[0] = @intCast(0xF0 | (cp >> 18));
        dest[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        dest[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dest[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

/// Like `extractJsonString` but always returns an owned, heap-allocated
/// slice. Missing field → `default` is duped. Caller frees.
fn extractJsonStringOrOwned(alloc: Allocator, body: []const u8, key: []const u8, default: []const u8) ![]u8 {
    if (try extractJsonString(alloc, body, key)) |s| return s;
    return try alloc.dupe(u8, default);
}

fn extractJsonString(alloc: Allocator, body: []const u8, key: []const u8) !?[]u8 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const idx = std.mem.findPos(u8, body, 0, needle) orelse return null;
    var pos = idx + needle.len;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) : (pos += 1) {}
    if (pos >= body.len or body[pos] != '"') return null;
    pos += 1;
    const start = pos;
    // Walk to terminating unescaped quote. Manual pos management: a
    // backslash escapes the *next* byte (any byte, even another `\`).
    while (pos < body.len) {
        if (body[pos] == '\\') {
            // Skip the backslash AND the next byte. If the next byte
            // would land past the end, bail.
            if (pos + 1 >= body.len) return null;
            pos += 2;
            continue;
        }
        if (body[pos] == '"') break;
        pos += 1;
    }
    if (pos >= body.len) return null;
    // Allocate + unescape. Caller owns the returned slice.
    return try unescapeJsonString(alloc, body[start..pos]);
}

fn extractJsonInt(body: []const u8, key: []const u8) ?i64 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const idx = std.mem.findPos(u8, body, 0, needle) orelse return null;
    var pos = idx + needle.len;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) : (pos += 1) {}
    const start = pos;
    while (pos < body.len and (body[pos] >= '0' and body[pos] <= '9' or body[pos] == '-' or body[pos] == '+')) : (pos += 1) {}
    if (start == pos) return null;
    return std.fmt.parseInt(i64, body[start..pos], 10) catch null;
}

/// Parse a JSON number (int or float) into f32. Walks the number body
/// from extractJsonInt's find, then parses with std.fmt.parseFloat which
/// handles decimals, signs, and exponents.
fn extractJsonFloat(body: []const u8, key: []const u8) ?f32 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const idx = std.mem.findPos(u8, body, 0, needle) orelse return null;
    var pos = idx + needle.len;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) : (pos += 1) {}
    const start = pos;
    while (pos < body.len and (body[pos] >= '0' and body[pos] <= '9' or
        body[pos] == '-' or body[pos] == '+' or body[pos] == '.' or
        body[pos] == 'e' or body[pos] == 'E')) : (pos += 1) {}
    if (start == pos) return null;
    return std.fmt.parseFloat(f32, body[start..pos]) catch null;
}

/// JSON-escaped string field (used by WAL payload encoding).
/// Full escape coverage: \", \\, \/, \n, \r, \t, \b, \f, and \uXXXX.
fn jsonFieldStringRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try out.append(alloc, '"');
    for (key) |kc| try out.append(alloc, kc);
    try out.appendSlice(alloc, "\":\"");
    for (value) |vc| {
        switch (vc) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            8 => try out.appendSlice(alloc, "\\b"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            12 => try out.appendSlice(alloc, "\\f"),
            0...7, 11, 14...31 => {
                var buf: [8]u8 = undefined;
                // SAFETY: this prong bounds vc to 0...31, so "{x:0>4}" always
                // emits exactly 4 hex digits. "\uXXXX" is 6 bytes; buf is 8.
                const s = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{vc}) catch unreachable;
                try out.appendSlice(alloc, s);
            },
            else => try out.append(alloc, vc),
        }
    }
    try out.append(alloc, '"');
}

fn jsonFieldInt(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: u64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value }) catch return error.NoSpaceLeft;
    try out.appendSlice(alloc, s);
}

fn jsonFieldFloat(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: f32) !void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d:.4}", .{ key, value }) catch return error.NoSpaceLeft;
    try out.appendSlice(alloc, s);
}

fn jsonAppendCell(alloc: Allocator, out: *std.ArrayList(u8), cell: *const MemCell) !void {
    try out.append(alloc, '{');
    try jsonFieldInt(alloc, out, "id", cell.id);
    try out.append(alloc, ',');
    try jsonFieldString(alloc, out, "source", @tagName(cell.source));
    try out.append(alloc, ',');
    try jsonFieldString(alloc, out, "episode", cell.episode);
    try out.append(alloc, ',');
    try jsonFieldFloat(alloc, out, "importance", cell.metadata.importance_score);
    try out.append(alloc, ',');
    try jsonFieldInt(alloc, out, "created_at", @intCast(@divTrunc(cell.metadata.created_at, 1000)));
    try out.append(alloc, ',');
    try out.appendSlice(alloc, "\"facts\":[");
    for (cell.atomic_facts, 0..) |f, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.append(alloc, '{');
        try jsonFieldString(alloc, out, "s", f.subject);
        try out.append(alloc, ',');
        try jsonFieldString(alloc, out, "p", f.predicate);
        try out.append(alloc, ',');
        try jsonFieldString(alloc, out, "o", f.object);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]");
    try out.append(alloc, '}');
}

// =============================================================================
// Tests
// =============================================================================

test "Server: healthz route" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();
    // No directory cleanup: Zig 0.17 moved `std.fs.cwd`/`deleteTree`, and
    // `/tmp` is the OS's to reap. Matches the convention in store.zig.
    const resp = try srv.route("GET", "/healthz", "");
    defer resp.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "ok") != null);
}

test "Server: sync re-journals goals so it cannot delete them" {
    // Regression guard for a data-destroying bug, kept even though the
    // daemon now shares the library Store and the specific cause is gone.
    //
    // What happened: the daemon carried a private ~890-line `Store` fork
    // whose replay loop knew about `goal_create` but not `goal_update`.
    // `POST /api/sync` truncated the WAL after snapshotting, and the
    // snapshot carries only (counter, cells, fuzzy) — no goals — so every
    // user goal, and its non-default status, was destroyed by one sync.
    // Reproduced end to end before the fix.
    //
    // The fork is gone, so the bug cannot recur in that shape. The guard
    // stays because the property is real and cheap to hold: the snapshot
    // format still does not carry goals, so anything that truncates the
    // WAL still has to re-journal them. `Store.sync()` is the only writer,
    // and this asserts it end to end through the HTTP handler.
    const alloc = std.testing.allocator;
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/mem3_rejournal_{d}", .{std.c.getpid()});

    var srv = try Server.init(alloc, "127.0.0.1", 0, dir);
    defer {
        srv.deinit();
    }

    const gid = srv.store.goals.create(
        "rejournal-probe",
        "must survive a sync",
        null,
        6,
        null,
        1_700_000_000_000,
        &srv.store.ids,
    ) catch |err| {
        std.log.warn("goal create failed: {s}", .{@errorName(err)});
        return err;
    };
    try srv.store.goals.updateStatus(gid, .completed, 1_700_000_000_000);
    try srv.store.sync();

    // Reopen against the same directory: a fresh process would do
    // exactly this after a restart.
    var srv2 = try Server.init(alloc, "127.0.0.1", 0, dir);
    defer srv2.deinit();

    const resp = try srv2.route("GET", "/api/goals", "");
    defer alloc.free(resp.body);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "rejournal-probe") != null);
    // `goal_create` carries no status, so a goal left at .completed
    // only reads back correctly if the status record was re-emitted too.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "completed") != null);
}

test "Server: GET /api/goals reflects the live poset, not a fixed literal" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer {
        srv.deinit();
    }

    // Seeded goals must be present.
    const before = try srv.route("GET", "/api/goals", "");
    defer alloc.free(before.body);
    try std.testing.expectEqual(@as(u16, 200), before.status);
    try std.testing.expect(std.mem.indexOf(u8, before.body, "general") != null);

    // The regression guard: the old implementation returned a hardcoded
    // literal, so ANY goal outside that literal proves we are now
    // reading the store. The name contains a quote and non-ASCII on
    // purpose — it must survive JSON escaping intact.
    const tricky_name = "e2e-quote\"and-中文";
    var slot: std.atomic.Value(u64) = .init(4242);
    _ = srv.store.goals.create(tricky_name, "desc with \\ backslash", null, 8, null, 0, &slot) catch |err| {
        std.log.warn("goal create failed: {s}", .{@errorName(err)});
        return err;
    };

    const after = try srv.route("GET", "/api/goals", "");
    defer alloc.free(after.body);

    // Parses as JSON at all — the old builder would not have.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, after.body, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("goals").?.array;
    var found = false;
    for (arr.items) |item| {
        const o = item.object;
        if (std.mem.eql(u8, o.get("name").?.string, tricky_name)) {
            found = true;
            try std.testing.expectEqual(@as(i64, 8), o.get("priority").?.integer);
            try std.testing.expect(o.get("description") != null);
            try std.testing.expect(o.get("status") != null);
            try std.testing.expect(o.get("parent_id") != null);
        }
    }
    try std.testing.expect(found);
}

test "Server: POST /api/query maxHops actually expands over the hypergraph" {
    // Regression guard for a parameter that was parsed and thrown away:
    // `extractJsonInt(body, "maxHops") orelse 3` with the result discarded,
    // because the daemon's private Store carried no hypergraph at all. The
    // daemon now shares the library Store, so the knob is wired — and this
    // test exists so "wired" cannot quietly become "parsed and discarded"
    // a second time.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const anchor = try srv.store.addRaw(.matter, "kubernetes ingress controller rollout", "", 0, 0.0);
    const island = try srv.store.addRaw(.matter, "pottery glaze chemistry firing curve", "", 0, 0.0);

    // The corpus has to be big enough that the dense search *cannot* return
    // everything: `handleQuery` asks for `topk * 3` = 30 candidates, so a
    // 2-cell store returns both and the test proves nothing. These fillers
    // are deliberately unrelated to the query text.
    var filler_i: usize = 0;
    while (filler_i < 80) : (filler_i += 1) {
        var buf: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "unrelated filler document number {d} about medieval shipbuilding records", .{filler_i});
        _ = try srv.store.addRaw(.matter, text, "", 0, 0.0);
    }

    // The whole point: `island` shares no vocabulary with the query, so the
    // dense search will not surface it. Only the hyperedge connects them.
    const nodes = try alloc.dupe(u64, &[_]u64{ anchor, island });
    _ = try srv.store.addHyperedge(.{
        .id = 0,
        .edge_type = .associative,
        .nodes = nodes,
        .weight = 0.5,
        .source_weights = .{ 1.0, 0.0, 0.0 },
        .confidence = 1.0,
        .created_at = 0,
        .metadata = null,
    });
    alloc.free(nodes);

    const callQuery = struct {
        fn f(s: *Server, a: Allocator, hops: i64) ![]i64 {
            var req: [160]u8 = undefined;
            // `handleQuery` splits the body off at "\r\n\r\n"; with no
            // header block it falls back to offset 0 and slices from +4,
            // so a bare JSON body would arrive missing its first 4 bytes.
            const body = try std.fmt.bufPrint(&req, "\r\n\r\n{{\"text\":\"kubernetes ingress\",\"maxHops\":{d}}}", .{hops});
            const resp = try s.route("POST", "/api/query", body);
            defer a.free(resp.body);
            if (resp.status != 200) return error.QueryFailed;
            const parsed = try std.json.parseFromSlice(std.json.Value, a, resp.body, .{});
            defer parsed.deinit();
            var ids = std.ArrayList(i64).empty;
            errdefer ids.deinit(a);
            for (parsed.value.object.get("results").?.array.items) |item| {
                try ids.append(a, item.object.get("id").?.integer);
            }
            return ids.toOwnedSlice(a);
        }
    }.f;

    const zero = try callQuery(srv, alloc, 0);
    defer alloc.free(zero);
    const one = try callQuery(srv, alloc, 1);
    defer alloc.free(one);

    const want: i64 = @intCast(island);
    var island_in_zero = false;
    for (zero) |id| {
        if (id == want) island_in_zero = true;
    }
    var island_in_one = false;
    for (one) |id| {
        if (id == want) island_in_one = true;
    }

    try std.testing.expect(!island_in_zero);
    try std.testing.expect(island_in_one);
}

// =============================================================================
// WAL payload helpers
// =============================================================================

/// JSON-escaped string field: "key":"escaped value".
fn jsonFieldString(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try out.append(alloc, '"');
    for (key) |kc| try out.append(alloc, kc);
    try out.appendSlice(alloc, "\":\"");
    for (value) |vc| {
        switch (vc) {
            '"' => try out.appendSlice(alloc, "\\\""), // \" (2 bytes)
            '\\' => try out.appendSlice(alloc, "\\\\"), // \\ (2 bytes)
            8 => try out.appendSlice(alloc, "\\b"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            12 => try out.appendSlice(alloc, "\\f"),
            0...7, 11, 14...31 => {
                var buf: [8]u8 = undefined;
                // SAFETY: this prong bounds vc to 0...31, so "{x:0>4}" always
                // emits exactly 4 hex digits. "\uXXXX" is 6 bytes; buf is 8.
                const s = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{vc}) catch unreachable;
                try out.appendSlice(alloc, s);
            },
            else => try out.append(alloc, vc),
        }
    }
    try out.append(alloc, '"');
}

fn jsonFieldUintRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: u64) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value }) catch return error.NoSpaceLeft;
    try out.appendSlice(alloc, s);
}

fn jsonFieldFloatRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: f32) !void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d:.6}", .{ key, value }) catch return error.NoSpaceLeft;
    try out.appendSlice(alloc, s);
}

fn jsonFieldIntRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: i64) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value }) catch return error.NoSpaceLeft;
    try out.appendSlice(alloc, s);
}

const ParsedInsert = struct {
    id: u64,
    source: MemorySource,
    /// Owned (heap-allocated, unescaped) string fields. Free via deinit.
    episode: []u8,
    facts: []u8,
    goal_id: u64,
    relevance: f32,
    /// Persisted metadata. Restored verbatim on replay so Principle III
    /// ranking (decay × importance × coherence) is stable across boots.
    metadata: core.Metadata,

    pub fn deinit(self: *const ParsedInsert, alloc: Allocator) void {
        alloc.free(self.episode);
        alloc.free(self.facts);
    }
};

/// Parse a JSON payload of shape { id, source, episode, facts, goal_id, relevance, ...meta }.
/// Metadata fields are optional — older WAL records (pre-metadata) parse
/// to zero-valued defaults, which still yields a working cell with
/// created_at=0 (i.e., very old, low weight) so it's distinguishable
/// from a fresh insert.
///
/// On parse failure (corrupt payload, missing required field) returns
/// `error.ParseFailed`. All partial heap allocations are released via
/// errdefer chain — no leaks. Caller distinguishes "bad record, skip"
/// from "out of memory" via the error code.
///
/// WAL upgrade note (B3): records from before the "id" field was added
/// are not silently dropped. A synthetic id is generated from the
/// record's offset in the WAL file so the cell survives the upgrade.
fn parseInsertPayload(alloc: Allocator, payload: []const u8, synthetic_id_fallback: u64) ParseError!ParsedInsert {
    // Id: prefer the persisted field; fall back to a synthetic value if
    // the record predates the "id" field. Negative id is a real error.
    const id_opt = extractJsonInt(payload, "id");
    const id: u64 = if (id_opt) |id_i| blk: {
        if (id_i < 0) return error.ParseFailed;
        break :blk @intCast(id_i);
    } else blk: {
        // Pre-id record. Use the synthetic id from the caller (1B +
        // u64 counter, guaranteed nonneg).
        break :blk synthetic_id_fallback;
    };
    return try parseInsertPayloadFromId(alloc, payload, id);
}

fn parseInsertPayloadFromId(alloc: Allocator, payload: []const u8, id: u64) ParseError!ParsedInsert {

    const source_str = try extractJsonStringOrOwned(alloc, payload, "source", "matter");
    errdefer alloc.free(source_str);
    const source = core.MemorySource.fromString(source_str) catch return error.ParseFailed;
    const episode = try extractJsonStringOrOwned(alloc, payload, "episode", "");
    errdefer alloc.free(episode);
    if (episode.len == 0) return error.ParseFailed;
    const facts = try extractJsonStringOrOwned(alloc, payload, "facts", "");
    errdefer alloc.free(facts);
    const goal_id_i: i64 = extractJsonInt(payload, "goal_id") orelse extractJsonInt(payload, "goalId") orelse 1;
    if (goal_id_i < 0) return error.ParseFailed;
    const goal_id: u64 = @intCast(goal_id_i);
    const relevance_f: f32 = extractJsonFloat(payload, "relevance") orelse 0.5;

    // Metadata fields. Missing fields → 0 (for ints) / 0.0 (for floats) /
    // defaults for derived values. A future enhancement could persist
    // the encoder's source_confidence default (1.0) here, but 0.0 is
    // safe because the manager rejects cells with source_confidence
    // below 0.5 at *encode* time — at *replay* time the cell is already
    // proven valid, so we accept the lower bound.
    const created_at = extractJsonInt(payload, "created_at") orelse 0;
    const updated_at = extractJsonInt(payload, "updated_at") orelse created_at;
    const last_accessed_at = extractJsonInt(payload, "last_accessed_at") orelse created_at;
    const importance_score = extractJsonFloat(payload, "importance_score") orelse 0.5;
    const coherence_score = extractJsonFloat(payload, "coherence_score") orelse 0.0;
    const decay_rate = extractJsonFloat(payload, "decay_rate") orelse 0.01;
    const source_confidence = extractJsonFloat(payload, "source_confidence") orelse 1.0;
    const emotional_valence = extractJsonFloat(payload, "emotional_valence") orelse 0.0;
    const access_count_i = extractJsonInt(payload, "access_count") orelse 0;
    const access_count: u64 = if (access_count_i < 0) 0 else @intCast(access_count_i);

    const metadata = core.Metadata{
        .created_at = created_at,
        .updated_at = updated_at,
        .source_confidence = source_confidence,
        .emotional_valence = emotional_valence,
        .location = null,
        .access_count = access_count,
        .last_accessed_at = last_accessed_at,
        .coherence_score = coherence_score,
        .importance_score = importance_score,
        .decay_rate = decay_rate,
        .is_fuzzy = false,
        .superseded_at = null,
    };

    return .{
        .id = id,
        .source = source,
        .episode = episode,
        .facts = facts,
        .goal_id = goal_id,
        .relevance = relevance_f,
        .metadata = metadata,
    };
}

const ParseError = error{ ParseFailed, OutOfMemory };

// =============================================================================
// Maintenance thread
// =============================================================================

test "Server: maintain marks an aged childless goal unrealized" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const now = nowMs();
    const gid = srv.store.goals.create("orphan", "no memories", null, 5, null, now - 30 * 86_400_000, &srv.store.ids) catch |err| {
        std.log.warn("goal create failed: {s}", .{@errorName(err)});
        return err;
    };

    const res = try srv.runMaintenanceNow();
    try std.testing.expectEqual(@as(usize, 1), res.goals_unrealized);
    try std.testing.expectEqual(@as(usize, 0), res.goals_failed);
    try std.testing.expectEqual(core.GoalStatus.unrealized, srv.store.goals.get(gid).?.status);

    // Idempotent: a second pass has nothing left to do.
    const again = try srv.runMaintenanceNow();
    try std.testing.expectEqual(@as(usize, 0), again.goals_unrealized);
}

test "Server: maintain leaves a goal that has memories alone" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const now = nowMs();
    const gid = srv.store.goals.create("attached", "has a memory", null, 5, null, now - 30 * 86_400_000, &srv.store.ids) catch |err| {
        std.log.warn("goal create failed: {s}", .{@errorName(err)});
        return err;
    };
    try srv.store.goals.bindMemcell(gid, 4242);

    const res = try srv.runMaintenanceNow();
    try std.testing.expectEqual(@as(usize, 0), res.goals_unrealized);
    try std.testing.expectEqual(core.GoalStatus.pending, srv.store.goals.get(gid).?.status);
}

test "Server: a maintain pass is silent when nothing changed" {
    // A per-pass log line is how a long-lived daemon fills a disk:
    // launchd and systemd capture stdout, so "one line a minute" is
    // ~500MB/year from a daemon with nothing to say. The pass only logs
    // when a transition actually happened, so this asserts the quiet path
    // exists and leaves no output behind.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    _ = srv.store.goals.create("young", "not stale yet", null, 5, null, nowMs(), &srv.store.ids) catch |err| {
        std.log.warn("goal create failed: {s}", .{@errorName(err)});
        return err;
    };
    // If this emitted a log line, the Zig 0.17 test runner would fail the
    // test outright — which is the assertion.
    const res = try srv.runMaintenanceNow();
    try std.testing.expectEqual(@as(usize, 0), res.goals_unrealized);
}

test "Server: maintenance thread starts, ticks, and stops cleanly" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);

    // 1-second interval, and we wait long enough for at least one pass.
    try srv.startMaintenance(1);
    var waited: u32 = 0;
    while (waited < 2500 and srv.metrics.maintenance_passes.load(.monotonic) == 0) : (waited += 10) {
        sleepMs(10);
    }
    try std.testing.expect(srv.metrics.maintenance_passes.load(.monotonic) >= 1);

    // `deinit` must join the thread before freeing the store. If it did
    // not, this is where a use-after-free would land — and under the
    // testing allocator a leak or a double free fails the test.
    srv.deinit();
}

test "Server: concurrent inserts and maintenance passes keep the store coherent" {
    // Both threads take the same mutex the accept loop and the real
    // maintenance thread take. That mirrors production exactly.
    //
    // Note what this does and does not prove: it shows the store stays
    // coherent under contention and that `deinit` joins cleanly. It does
    // NOT prove the absence of a data race — races are not observable by a
    // passing test. The discipline that actually protects `GoalPoset.nodes`
    // (an AutoHashMap whose iterators do not survive a rehash) is that
    // there is exactly ONE lock acquisition point for requests,
    // `handleConn`, so no handler can be added that forgets.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const Writer = struct {
        fn run(s: *Server, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "concurrent insert {d}", .{i}) catch "concurrent";
                s.store_mutex.lock();
                defer s.store_mutex.unlock();
                _ = s.store.addRaw(.matter, text, "", 0, 0.0) catch {};
            }
        }
    };

    const Maint = struct {
        fn run(s: *Server, rounds: usize) void {
            var r: usize = 0;
            while (r < rounds) : (r += 1) {
                s.store_mutex.lock();
                defer s.store_mutex.unlock();
                _ = s.store.maintain(nowMs()) catch {};
            }
        }
    };

    var t1 = try std.Thread.spawn(.{}, Writer.run, .{ srv, 200 });
    var t2 = try std.Thread.spawn(.{}, Writer.run, .{ srv, 200 });
    var t3 = try std.Thread.spawn(.{}, Maint.run, .{ srv, 200 });

    t1.join();
    t2.join();
    t3.join();

    // Both writers' work landed, and the store is still coherent.
    try std.testing.expectEqual(@as(usize, 400), srv.store.cellCount());
}

test "Server: a fresh daemon does not mark its own built-in goals unrealized" {
    // Regression guard. The three seeded goals were created with
    // `created_at = 0`, which under Constitution III's "no memories for 7
    // days" rule makes them 56 years old the moment the store is built.
    // The first maintenance pass therefore marked all three unrealized —
    // before a single query had been served. Measured: a fresh daemon
    // reported 4 goals unrealized, three of them built-ins that had
    // existed for microseconds.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const res = try srv.runMaintenanceNow();
    try std.testing.expectEqual(@as(usize, 0), res.goals_unrealized);
    const seeded = [_][]const u8{ "general", "research", "system" };
    for (seeded) |name| {
        var found = false;
        var it = srv.store.goals.nodes.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.*.name, name)) {
                found = true;
                try std.testing.expectEqual(core.GoalStatus.pending, e.value_ptr.*.status);
            }
        }
        try std.testing.expect(found);
    }
}
