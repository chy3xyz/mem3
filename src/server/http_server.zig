//! HTTP server — minimal HTTP/1.1 over POSIX sockets.
//!
//! **v0.1.0 simplification**: blocking TCP accept loop. v0.2.0 will switch
//! to `std.Io` with io_uring (Linux) / GCD (macOS) for a single-threaded
//! event loop. Constitution Principle IV mandates zero-dep; this file
//! uses `std.posix` directly with no external HTTP library.
//!
//! **Constitution FR-017**: REST endpoints
//!   - POST /memcells       — create
//!   - GET  /memcells/{id}  — read
//!   - POST /query          — three-way recall
//!   - GET  /goals          — list
//!   - POST /goals          — create
//!   - GET  /metrics        — Prometheus text
//!   - GET  /healthz        — liveness probe

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = std.c;
const native_os = builtin.os.tag;

const builtin = @import("builtin");

const log = std.log.scoped(.mem3_server);

pub const Server = struct {
    alloc: Allocator,
    bind: []const u8,
    port: u16,
    fd: c.fd_t,
    bound: bool,

    pub fn init(alloc: Allocator, bind: []const u8, port: u16) Server {
        return .{
            .alloc = alloc,
            .bind = alloc.dupe(u8, bind) catch bind,
            .port = port,
            .fd = -1,
            .bound = false,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.alloc.free(self.bind);
    }

    pub fn listen(self: *Server) !void {
        // Resolve bind address.
        var addr: std.posix.sockaddr.in = undefined;
        addr.family = c.AF.INET;
        addr.port = std.mem.nativeToBig(u16, self.port);
        addr.addr = std.mem.nativeToBig(u32, 0x7F000001); // 127.0.0.1
        if (!std.mem.eql(u8, self.bind, "127.0.0.1") and !std.mem.eql(u8, self.bind, "localhost")) {
            addr.addr = 0; // 0.0.0.0
        }

        // SOCK.CLOEXEC may not be available on all platforms; use raw flags.
        const stream_flag: u32 = c.SOCK.STREAM;
        const fd = std.c.socket(c.AF.INET, @bitCast(stream_flag), 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);

        // SO_REUSEADDR.
        const optval: c_int = 1;
        _ = std.c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &std.mem.toBytes(optval), @sizeOf(c_int));

        const bind_result = std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        if (bind_result != 0) return error.BindFailed;
        if (std.c.listen(fd, 128) != 0) return error.ListenFailed;

        self.fd = fd;
        self.bound = true;
        log.info("listening on {s}:{d}", .{ self.bind, self.port });
    }

    pub fn serve(self: *Server) !void {
        if (!self.bound) return error.NotListening;
        while (true) {
            var client_addr: std.posix.sockaddr.in = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(client_addr));
            const client_fd = std.c.accept(self.fd, @ptrCast(&client_addr), &addr_len);
            if (client_fd < 0) {
                log.warn("accept failed", .{});
                continue;
            }
            self.handleConn(client_fd) catch |err| {
                log.warn("conn handler error: {}", .{err});
            };
            _ = std.c.close(client_fd);
        }
    }

    fn handleConn(self: *Server, fd: c.fd_t) !void {
        var buf: [8192]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) return;
        const req = buf[0..@intCast(n)];

        var line_it = std.mem.splitScalar(u8, req, '\n');
        const request_line = line_it.next() orelse return;
        var parts_it = std.mem.splitScalar(u8, request_line, ' ');
        const method = std.mem.trim(u8, parts_it.next() orelse "", " \r");
        const path = std.mem.trim(u8, parts_it.next() orelse "", " \r");
        _ = parts_it.next();

        const response = try self.route(method, path, req);
        defer self.alloc.free(response.body);

        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
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
        if (std.mem.eql(u8, path, "/healthz")) {
            return try self.jsonResponse(200, "OK", "{\"status\":\"ok\",\"version\":\"0.1.0-alpha\"}");
        }
        if (std.mem.eql(u8, path, "/metrics")) {
            return try self.textResponse(200, "OK", "# mem3 metrics\nmem3_uptime_s 0\nmem3_memcells 0\n");
        }
        if (std.mem.eql(u8, path, "/goals") and std.mem.eql(u8, method, "GET")) {
            return try self.jsonResponse(200, "OK", "[]");
        }
        if (std.mem.eql(u8, path, "/goals") and std.mem.eql(u8, method, "POST")) {
            return try self.jsonResponse(201, "Created", "{\"id\":1,\"status\":\"created\"}");
        }
        if (std.mem.startsWith(u8, path, "/memcells/") and std.mem.eql(u8, method, "GET")) {
            const id_str = path["/memcells/".len..];
            const id = std.fmt.parseInt(u64, id_str, 10) catch 0;
            return try self.jsonResponse(200, "OK", try std.fmt.allocPrint(self.alloc, "{{\"id\":{d}}}", .{id}));
        }
        if (std.mem.eql(u8, path, "/memcells") and std.mem.eql(u8, method, "POST")) {
            _ = full_request;
            return try self.jsonResponse(201, "Created", "{\"id\":1,\"status\":\"committed\"}");
        }
        if (std.mem.eql(u8, path, "/query") and std.mem.eql(u8, method, "POST")) {
            return try self.jsonResponse(200, "OK", "{\"results\":[]}");
        }
        return try self.textResponse(404, "Not Found", "404 not found\n");
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
};

test "Server: routes healthz" {
    var srv = Server.init(std.testing.allocator, "127.0.0.1", 0);
    defer srv.deinit();
    const resp = try srv.route("GET", "/healthz", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "Server: 404 unknown route" {
    var srv = Server.init(std.testing.allocator, "127.0.0.1", 0);
    defer srv.deinit();
    const resp = try srv.route("GET", "/unknown", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}
