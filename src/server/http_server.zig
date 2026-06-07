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
const fact = @import("../core/types.zig").Fact;
const foresight_t = @import("../core/types.zig").Foresight;
const goal_assoc_t = @import("../core/types.zig").GoalAssociation;
const ghw = @import("../ghw/mod.zig");
const memory = @import("../memory/mod.zig");
const retrieval = @import("../retrieval/mod.zig");
const HNSW = retrieval.HNSW;
const WAL = @import("../storage/wal.zig").WAL;
const WALRecord = @import("../storage/wal.zig").WALRecord;

const log = std.log.scoped(.mem3_server);

/// Embedded web UI (loaded at compile time via @embedFile).
const WEB_INDEX: []const u8 = @embedFile("web_index.html");

fn nowNs() u128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    // timespec fields are signed c_long; coerce through i64 to recover non-negative values from MONOTONIC clock.
    const sec_i: i64 = @intCast(ts.sec);
    const nsec_i: i64 = @intCast(ts.nsec);
    return @as(u128, @as(u64, @bitCast(sec_i))) * 1_000_000_000 +
        @as(u128, @as(u64, @bitCast(nsec_i)));
}

/// In-process memory store. Lives for the duration of the server.
const Store = struct {
    alloc: Allocator,
    ids: std.atomic.Value(u64),
    goals: *ghw.GoalPoset,
    mgr: *memory.TriSourceManager,
    lc: *memory.Lifecycle,
    hnsw: *HNSW,
    emb: retrieval.StubEmbedder,
    cell_index: std.AutoHashMap(u64, *MemCell),
    /// WAL for crash-safe persistence. Optional so tests / dry-runs can opt out.
    wal: ?*WAL,

    fn init(alloc: Allocator, data_dir: []const u8) !*Store {
        const self = try alloc.create(Store);
        self.* = .{
            .alloc = alloc,
            .ids = .init(1),
            .goals = undefined,
            .mgr = undefined,
            .lc = undefined,
            .hnsw = undefined,
            .emb = undefined,
            .cell_index = std.AutoHashMap(u64, *MemCell).init(alloc),
            .wal = null,
        };
        // Goals
        var goals = try alloc.create(ghw.GoalPoset);
        goals.* = ghw.GoalPoset.init(alloc);
        self.goals = goals;
        _ = try goals.create("general", "catch-all", null, 5, null, 0, &self.ids);
        _ = try goals.create("research", "research-related", null, 7, null, 0, &self.ids);
        _ = try goals.create("system", "system / meta", null, 6, null, 0, &self.ids);
        // TriSourceManager
        const mgr = try alloc.create(memory.TriSourceManager);
        mgr.* = memory.TriSourceManager.init(alloc, &self.ids);
        self.mgr = mgr;
        // Lifecycle
        const lc = try alloc.create(memory.Lifecycle);
        lc.* = memory.Lifecycle.init(alloc, .{}, mgr);
        lc.wire();
        self.lc = lc;
        // HNSW
        const hnsw = try alloc.create(HNSW);
        hnsw.* = HNSW.init(alloc, .{}, 384);
        self.hnsw = hnsw;
        self.emb = retrieval.StubEmbedder.init(384);
        // Open WAL (best-effort) and replay if data_dir exists.
        try self.openAndReplayWAL(data_dir);
        return self;
    }

    fn deinit(self: *Store) void {
        if (self.wal) |w| {
            w.flush() catch {};
            w.deinit();
            self.alloc.destroy(w);
            self.wal = null;
        }
        var it = self.cell_index.iterator();
        while (it.next()) |_| {}
        self.cell_index.deinit();
        self.hnsw.deinit();
        self.alloc.destroy(self.hnsw);
        // Lifecycle wraps mgr + fuzzy; clean fuzzy, then mgr deinit handles lc.
        self.lc.fuzzy.deinit();
        self.alloc.destroy(self.lc);
        self.mgr.deinit();
        self.alloc.destroy(self.mgr);
        self.goals.deinit();
        self.alloc.destroy(self.goals);
        self.alloc.destroy(self);
    }

    fn addRaw(
        self: *Store,
        source: MemorySource,
        episode: []const u8,
        facts: []const u8,
        goal_id: u64,
        relevance: f32,
    ) !u64 {
        return self.addRawInternal(source, episode, facts, goal_id, relevance, true);
    }

    /// Replay helper: same as addRaw but skips WAL writes (avoid re-recording replayed records).
    fn addRawNoWAL(
        self: *Store,
        source: MemorySource,
        episode: []const u8,
        facts: []const u8,
        goal_id: u64,
        relevance: f32,
    ) !u64 {
        return self.addRawInternal(source, episode, facts, goal_id, relevance, false);
    }

    fn addRawInternal(
        self: *Store,
        source: MemorySource,
        episode: []const u8,
        facts: []const u8,
        goal_id: u64,
        relevance: f32,
        write_wal: bool,
    ) !u64 {
        var fact_list = std.ArrayList(fact).empty;
        defer fact_list.deinit(self.alloc);
        var it = std.mem.splitScalar(u8, facts, ';');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            var pit = std.mem.splitScalar(u8, part, '|');
            const s = pit.next() orelse "";
            const p = pit.next() orelse "";
            const o = pit.next() orelse "";
            try fact_list.append(self.alloc, .{
                .subject = s,
                .predicate = p,
                .object = o,
                .confidence = 1.0,
                .source = "api",
            });
        }

        var goal_list = std.ArrayList(goal_assoc_t).empty;
        defer goal_list.deinit(self.alloc);
        try goal_list.append(self.alloc, .{
            .goal_id = goal_id,
            .relevance = relevance,
            .priority = 5,
        });

        const id = try self.lc.encode(.{
            .source = source,
            .episode = episode,
            .atomic_facts = fact_list.items,
            .foresight = &[_]foresight_t{},
            .goal_associations = goal_list.items,
        });

        if (self.mgr.get(id)) |cell| {
            try self.cell_index.put(id, cell);
            const v = try self.emb.embed(self.alloc, episode);
            defer self.alloc.free(v);
            self.hnsw.insert(id, v) catch |err| {
                log.warn("hnsw insert failed: {}", .{err});
            };
        }

        // Persist to WAL after the in-memory state is consistent.
        if (write_wal) {
            if (self.wal) |wal| {
                const payload = try self.encodeWALPayload(source, episode, facts, goal_id, relevance);
                defer self.alloc.free(payload);
                const ts_s: i64 = @intCast(@divTrunc(nowNs(), std.time.ns_per_s));
                try wal.append(.{
                    .record_type = .memcell_insert,
                    .payload = payload,
                    .timestamp = ts_s,
                });
            }
        }
        return id;
    }

    /// Encode a memcell_insert WAL payload as a length-prefixed JSON document.
    /// Fields: { source, episode, facts, goal_id, relevance }.
    fn encodeWALPayload(
        self: *Store,
        source: MemorySource,
        episode: []const u8,
        facts: []const u8,
        goal_id: u64,
        relevance: f32,
    ) ![]u8 {
        // Use std.fmt.allocPrint to produce a self-contained JSON object.
        // Strings are JSON-escaped inline. Episodes come from the API and
        // may contain quotes, backslashes, and control characters; we
        // escape them as we copy.
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        try out.append(self.alloc, '{');
        try jsonFieldStringRaw(self.alloc, &out, "source", source.label());
        try out.append(self.alloc, ',');
        try jsonFieldStringRaw(self.alloc, &out, "episode", episode);
        try out.append(self.alloc, ',');
        try jsonFieldStringRaw(self.alloc, &out, "facts", facts);
        try out.append(self.alloc, ',');
        try jsonFieldUintRaw(self.alloc, &out, "goal_id", goal_id);
        try out.append(self.alloc, ',');
        try jsonFieldFloatRaw(self.alloc, &out, "relevance", relevance);
        try out.append(self.alloc, '}');
        return out.toOwnedSlice(self.alloc);
    }

    /// Open the WAL at data_dir/mem3.wal and replay any prior records.
    /// Creates the directory if missing. Silently no-ops if no WAL exists.
    fn openAndReplayWAL(self: *Store, data_dir: []const u8) !void {
        const dir_path = try self.alloc.dupe(u8, data_dir);
        defer self.alloc.free(dir_path);

        // Recursive mkdir (mkdir -p). 0.17 std has no public makeDir API,
        // so we shell out to the C `mkdir` syscall per path component.
        var it = std.mem.splitScalar(u8, dir_path, '/');
        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(self.alloc);
        // Absolute path starting with / : add a leading slash.
        if (dir_path.len > 0 and dir_path[0] == '/') {
            try prefix.append(self.alloc, '/');
        }
        while (it.next()) |component| {
            if (component.len == 0) continue;
            if (prefix.items.len > 0 and prefix.items[prefix.items.len - 1] != '/') {
                try prefix.append(self.alloc, '/');
            }
            try prefix.appendSlice(self.alloc, component);
            var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const z = std.fmt.bufPrint(&zbuf, "{s}\x00", .{prefix.items}) catch continue;
            const rc = std.c.mkdir(z[0 .. z.len - 1 :0].ptr, 0o755);
            std.debug.print("WAL: mkdir({s}) rc={d}\n", .{ prefix.items, rc });
        }

        const wal_path = std.fs.path.join(self.alloc, &.{ data_dir, "mem3.wal" }) catch |err| {
            log.warn("path.join failed: {}; persistence disabled", .{err});
            return;
        };
        defer self.alloc.free(wal_path);

        // Build a NUL-terminated copy for C open() calls.
        var wal_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const wal_z = std.fmt.bufPrint(&wal_z_buf, "{s}\x00", .{wal_path}) catch {
            log.warn("path too long", .{});
            return;
        };
        const wal_z_slice = wal_z[0 .. wal_z.len - 1 :0];

        // Try to read existing WAL via POSIX open (0.17 has no fs.openFileAbsolute).
        var existing: std.ArrayList(u8) = .empty;
        defer existing.deinit(self.alloc);

        const fd = std.c.open(wal_z_slice.ptr, std.c.O{}, @as(c.mode_t, 0));
        if (fd >= 0) {
            defer _ = std.c.close(fd);
            var stat_buf: std.c.Stat = undefined;
            if (std.c.fstat(fd, &stat_buf) == 0) {
                const size: usize = @intCast(@max(0, stat_buf.size));
                if (size > 0) {
                    const buf = try self.alloc.alloc(u8, size);
                    defer self.alloc.free(buf);
                    var got: usize = 0;
                    while (got < size) {
                        const n = std.c.read(fd, buf[got..].ptr, size - got);
                        if (n <= 0) break;
                        got += @intCast(n);
                    }
                    try existing.appendSlice(self.alloc, buf[0..got]);
                }
            }
        }
        // Now allocate the WAL (it will createFile on open()).
        const wal_ptr = self.alloc.create(WAL) catch |err| {
            std.debug.print("WAL: alloc failed: {s}\n", .{@errorName(err)});
            return;
        };
        const init_wal = WAL.init(self.alloc, wal_path) catch |err| {
            std.debug.print("WAL: init failed: {s}\n", .{@errorName(err)});
            self.alloc.destroy(wal_ptr);
            return;
        };
        wal_ptr.* = init_wal;
        wal_ptr.open() catch |err| {
            std.debug.print("WAL: open({s}) failed: {s}\n", .{ wal_path, @errorName(err) });
            wal_ptr.deinit();
            self.alloc.destroy(wal_ptr);
            return;
        };
        std.debug.print("WAL: opened {s} (replay={d} bytes)\n", .{ wal_path, existing.items.len });
        self.wal = wal_ptr;
        if (existing.items.len == 0) return;

        // Replay records.
        var replay_count: u64 = 0;
        const Ctx = struct {
            store: *Store,
            count: *u64,
        };
        var ctx = Ctx{ .store = self, .count = &replay_count };
        wal_ptr.replay(existing.items, &ctx, struct {
            fn cb(ctx_ptr: *Ctx, rec: WALRecord) anyerror!void {
                if (rec.record_type != .memcell_insert) return;
                const parsed = parseInsertPayload(rec.payload) orelse return;
                var local_parsed = parsed;
                defer local_parsed.deinit(ctx_ptr.store.alloc);
                _ = ctx_ptr.store.addRawNoWAL(
                    parsed.source,
                    parsed.episode,
                    parsed.facts,
                    parsed.goal_id,
                    parsed.relevance,
                ) catch |err| {
                    std.log.warn("replay insert failed: {}", .{err});
                    return;
                };
                ctx_ptr.count.* += 1;
            }
        }.cb) catch |err| {
            log.warn("WAL replay stopped at record {d}: {}", .{ replay_count, err });
        };
        std.debug.print("WAL: replayed {d} memcell_insert records from {s}\n", .{ replay_count, wal_path });
    }

    fn allCells(self: *Store, alloc: Allocator) ![]*MemCell {
        var out = std.ArrayList(*MemCell).empty;
        errdefer out.deinit(alloc);
        var it = self.cell_index.iterator();
        while (it.next()) |entry| try out.append(alloc, entry.value_ptr.*);
        return out.toOwnedSlice(alloc);
    }
};

const Metrics = struct {
    requests_total: std.atomic.Value(u64) = .init(0),
    queries_total: std.atomic.Value(u64) = .init(0),
    inserts_total: std.atomic.Value(u64) = .init(0),
    last_query_us: std.atomic.Value(u64) = .init(0),

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
        , .{
            uptime_s,
            self.requests_total.load(.monotonic),
            self.queries_total.load(.monotonic),
            self.inserts_total.load(.monotonic),
            self.last_query_us.load(.monotonic),
        });
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

    pub fn init(alloc: Allocator, bind: []const u8, port: u16, data_dir: []const u8) !*Server {
        const self = try alloc.create(Server);
        const store = try Store.init(alloc, data_dir);
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
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.store.deinit();
        self.alloc.free(self.bind);
        self.alloc.destroy(self);
    }

    pub fn listen(self: *Server) !void {
        var addr: std.posix.sockaddr.in = undefined;
        addr.family = c.AF.INET;
        addr.port = std.mem.nativeToBig(u16, self.port);
        addr.addr = std.mem.nativeToBig(u32, 0x7F000001);
        if (!std.mem.eql(u8, self.bind, "127.0.0.1") and !std.mem.eql(u8, self.bind, "localhost")) {
            addr.addr = 0;
        }

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

        const response = try self.route(method, path, req);
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
        }
        return try self.jsonResponse(200, "OK",
            \\{"status":"synced"}
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

        const source_str = extractJsonString(body, "source") orelse "matter";
        const source = core.MemorySource.fromString(source_str) catch return try self.jsonResponse(400, "Bad Request", "{\"error\":\"invalid source\"}");
        const episode = extractJsonString(body, "episode") orelse return try self.jsonResponse(400, "Bad Request", "{\"error\":\"episode required\"}");
        const facts = extractJsonString(body, "facts") orelse "";
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

    fn handleListGoals(self: *Server) !Response {
        const body = try std.fmt.allocPrint(self.alloc,
            \\[{{"id":1,"name":"general","priority":5}},
            \\{{"id":2,"name":"research","priority":7}},
            \\{{"id":3,"name":"system","priority":6}}]
        , .{});
        return self.rawJson(200, body);
    }

    fn handleQuery(self: *Server, full_request: []const u8) !Response {
        const body_start = std.mem.findPos(u8, full_request, 0, "\r\n\r\n") orelse 0;
        const body = full_request[body_start + 4 ..];

        const text = extractJsonString(body, "text") orelse return try self.jsonResponse(400, "Bad Request", "{\"error\":\"text required\"}");
        const topk = @as(usize, @intCast(extractJsonInt(body, "topk") orelse 10));
        _ = extractJsonInt(body, "maxHops") orelse 3;

        _ = self.metrics.queries_total.fetchAdd(1, .monotonic);
        const t0 = nowNs();

        const qvec = try self.store.emb.embed(self.alloc, text);
        defer self.alloc.free(qvec);

        const dense = self.store.hnsw.search(self.alloc, qvec, topk * 3) catch &.{};
        defer self.alloc.free(dense);

        var ranked = std.ArrayList(struct { id: u64, score: f32 }).empty;
        defer ranked.deinit(self.alloc);
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
            var goal_bonus: f32 = 0.0;
            for (cell.goal_associations) |ga| {
                if (ga.relevance > goal_bonus) goal_bonus = ga.relevance;
            }
            const existence = cell.metadata.importance_score;
            score = score * (1.0 + 0.4 * goal_bonus) * (1.0 + 0.3 * existence);
            try ranked.append(self.alloc, .{ .id = cell.id, .score = score });
        }

        std.mem.sort(@TypeOf(ranked.items[0]), ranked.items, {}, struct {
            fn lt(_: void, a: @TypeOf(ranked.items[0]), b: @TypeOf(ranked.items[0])) bool {
                return a.score > b.score;
            }
        }.lt);

        const out_n = @min(topk, ranked.items.len);
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "{\"results\":[");
        for (ranked.items[0..out_n], 0..) |r, i| {
            if (i > 0) try out.append(self.alloc, ',');
            const cell = self.store.cell_index.get(r.id) orelse continue;
            try out.append(self.alloc, '{');
            try jsonFieldInt(self.alloc, &out, "id", r.id);
            try out.append(self.alloc, ',');
            try jsonFieldString(self.alloc, &out, "source", @tagName(cell.source));
            try out.append(self.alloc, ',');
            try jsonFieldString(self.alloc, &out, "episode", cell.episode);
            try out.append(self.alloc, ',');
            try jsonFieldFloat(self.alloc, &out, "score", r.score);
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

// =============================================================================
// Tiny JSON utilities (avoid pulling in std.json for the hot API path).
// =============================================================================

fn extractJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const idx = std.mem.findPos(u8, body, 0, needle) orelse return null;
    var pos = idx + needle.len;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) : (pos += 1) {}
    if (pos >= body.len or body[pos] != '"') return null;
    pos += 1;
    const start = pos;
    // Walk to terminating unescaped quote.
    while (pos < body.len) : (pos += 1) {
        if (body[pos] == '\\') {
            pos += 1; // skip escaped char (any byte)
            continue;
        }
        if (body[pos] == '"') break;
    }
    if (pos >= body.len) return null;
    return body[start..pos];
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

fn extractJsonFloat(body: []const u8, key: []const u8) ?f32 {
    return @as(f32, @floatFromInt(extractJsonInt(body, key) orelse return null));
}

fn jsonFieldString(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try out.append(alloc, '"');
    for (key) |kc| try out.append(alloc, kc);
    try out.appendSlice(alloc, "\":\"");
    for (value) |vc| {
        switch (vc) {
            '"' => try out.append(alloc, '\\'),
            '\\' => try out.append(alloc, '\\'),
            '\n' => try out.appendSlice(alloc, "\\n"),
            else => try out.append(alloc, vc),
        }
    }
    try out.append(alloc, '"');
}

fn jsonFieldInt(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: u64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value }) catch unreachable;
    try out.appendSlice(alloc, s);
}

fn jsonFieldFloat(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: f32) !void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d:.4}", .{ key, value }) catch unreachable;
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
    var srv = try Server.init(alloc, "127.0.0.1", 0, "data/test_server");
    defer srv.deinit();
    const resp = try srv.route("GET", "/healthz", "");
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "ok") != null);
}

test "Server: GET /api/goals" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, "data/test_server");
    defer srv.deinit();
    const resp = try srv.route("GET", "/api/goals", "");
    defer alloc.free(resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "general") != null);
}

// =============================================================================
// WAL payload helpers
// =============================================================================

/// JSON-escaped string field: "key":"escaped value".
fn jsonFieldStringRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try out.append(alloc, '"');
    for (key) |kc| try out.append(alloc, kc);
    try out.appendSlice(alloc, "\":\"");
    for (value) |vc| {
        switch (vc) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0...7, 11, 14...31 => {
                var buf: [8]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{vc}) catch continue;
                try out.appendSlice(alloc, s);
            },
            else => try out.append(alloc, vc),
        }
    }
    try out.append(alloc, '"');
}

fn jsonFieldUintRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: u64) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value }) catch unreachable;
    try out.appendSlice(alloc, s);
}

fn jsonFieldFloatRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: f32) !void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d:.6}", .{ key, value }) catch unreachable;
    try out.appendSlice(alloc, s);
}

const ParsedInsert = struct {
    source: MemorySource,
    /// Borrowed slices from the parent payload buffer; no need to free.
    episode: []const u8,
    facts: []const u8,
    goal_id: u64,
    relevance: f32,

    pub fn deinit(_: *ParsedInsert, _: Allocator) void {}
};

/// Parse a JSON payload of shape { source, episode, facts, goal_id, relevance }.
fn parseInsertPayload(payload: []const u8) ?ParsedInsert {
    const source_str = extractJsonString(payload, "source") orelse "matter";
    const source = core.MemorySource.fromString(source_str) catch return null;
    const episode = extractJsonString(payload, "episode") orelse return null;
    const facts = extractJsonString(payload, "facts") orelse "";
    const goal_id_i: i64 = extractJsonInt(payload, "goal_id") orelse extractJsonInt(payload, "goalId") orelse 1;
    if (goal_id_i < 0) return null;
    const goal_id: u64 = @intCast(goal_id_i);
    const relevance_f: f32 = extractJsonFloat(payload, "relevance") orelse 0.5;
    return .{
        .source = source,
        .episode = episode,
        .facts = facts,
        .goal_id = goal_id,
        .relevance = relevance_f,
    };
}
