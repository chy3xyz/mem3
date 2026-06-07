//! HTTP server — minimal HTTP/1.1 over POSIX sockets with in-process store.
//!
//! **v0.1.0-alpha limitation**: store is process-local; data does not
//! persist across restarts. WASM/LibSQL persistence lands in v0.2.0.
//!
//! **Constitution FR-017** endpoints:
//!   - GET  /                            — web UI (htmx + Alpine.js + Tailwind)
//!   - GET  /api/memcells                — list
//!   - GET  /api/memcells/{id}           — single
//!   - POST /api/memcells                — create
//!   - GET  /api/goals                   — list
//!   - POST /api/query                   — three-way recall
//!   - GET  /healthz, /metrics           — observability

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

    fn init(alloc: Allocator) !*Store {
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
        return self;
    }

    fn deinit(self: *Store) void {
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
        return id;
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

    pub fn init(alloc: Allocator, bind: []const u8, port: u16) !*Server {
        const self = try alloc.create(Server);
        const store = try Store.init(alloc);
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
        return try self.textResponse(404, "Not Found", "404 not found\n");
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
    while (pos < body.len and body[pos] != '"') : (pos += 1) {}
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
    var srv = try Server.init(alloc, "127.0.0.1", 0);
    defer srv.deinit();
    const resp = try srv.route("GET", "/healthz", "");
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "ok") != null);
}

test "Server: GET /api/goals" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0);
    defer srv.deinit();
    const resp = try srv.route("GET", "/api/goals", "");
    defer alloc.free(resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "general") != null);
}
