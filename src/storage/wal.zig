//! Write-Ahead Log (WAL) for crash recovery.
//!
//! **Constitution FR-022**: every committed MemCell write is preceded by
//! a `WAL_RECORD_TYPE_MEMCELL_INSERT` log entry. Replay reconstructs state
//! on startup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const HyperEdge = @import("../hypermem/hyperedge.zig").HyperEdge;
const GoalNode = @import("../ghw/goal_node.zig").GoalNode;
const GoalStatus = core.GoalStatus;
const errors = core.Error;
const hashing = @import("../utils/hashing.zig");

pub const WALRecordType = enum(u8) {
    memcell_insert = 0x01,
    memcell_update = 0x02,
    hyperedge_add = 0x03,
    hyperedge_remove = 0x04,
    goal_create = 0x10,
    goal_update = 0x11,
    forget = 0x20,
    snapshot_marker = 0xF0,
    checksum_marker = 0xFF,
};

pub const WALRecord = struct {
    record_type: WALRecordType,
    /// Type-specific payload. The serializer handles encoding.
    payload: []const u8,
    timestamp: i64,

    pub fn checksum(self: *const WALRecord) u32 {
        var h = std.hash.XxHash3.init();
        h.update(&[_]u8{@intFromEnum(self.record_type)});
        h.update(self.payload);
        h.update(&std.mem.toBytes(self.timestamp));
        return @truncate(h.final());
    }
};

pub const WAL = struct {
    alloc: Allocator,
    path: []const u8,
    file: ?std.fs.File,
    /// Records appended in this session (not yet flushed to disk).
    buffer: std.ArrayList(u8),
    /// Number of records written.
    record_count: u64 = 0,
    /// Sync after every N records.
    sync_every_n: u64 = 64,

    pub fn init(alloc: Allocator, path: []const u8) !WAL {
        return .{
            .alloc = alloc,
            .path = try alloc.dupe(u8, path),
            .file = null,
            .buffer = .empty,
        };
    }

    pub fn deinit(self: *WAL) void {
        if (self.file) |f| f.close();
        self.alloc.free(self.path);
        self.buffer.deinit(self.alloc);
    }

    /// Open (or create) the WAL file.
    pub fn open(self: *WAL) !void {
        const f = try std.fs.cwd().createFile(self.path, .{ .read = true, .truncate = false });
        errdefer f.close();
        self.file = f;
    }

    /// Append a record. The record is buffered; call `flush()` to write
    /// to disk.
    pub fn append(self: *WAL, rec: WALRecord) !void {
        const cs = rec.checksum();
        // Layout: [len:u32 LE][type:u8][payload:N][ts:i64 LE][checksum:u32 LE]
        try self.buffer.ensureUnusedCapacity(self.alloc, @sizeOf(u32) + 1 + rec.payload.len + @sizeOf(i64) + @sizeOf(u32));
        const len: u32 = @intCast(1 + rec.payload.len + @sizeOf(i64) + @sizeOf(u32));
        var len_bytes: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &len_bytes, len, .little);
        try self.buffer.appendSlice(self.alloc, &len_bytes);
        try self.buffer.append(self.alloc, @intFromEnum(rec.record_type));
        try self.buffer.appendSlice(self.alloc, rec.payload);
        var ts_bytes: [@sizeOf(i64)]u8 = undefined;
        std.mem.writeInt(i64, &ts_bytes, rec.timestamp, .little);
        try self.buffer.appendSlice(self.alloc, &ts_bytes);
        var cs_bytes: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &cs_bytes, cs, .little);
        try self.buffer.appendSlice(self.alloc, &cs_bytes);
        self.record_count += 1;
        if (self.record_count % self.sync_every_n == 0) {
            try self.flush();
        }
    }

    /// Flush the buffer to disk.
    pub fn flush(self: *WAL) !void {
        const f = self.file orelse return error.WALCorrupt;
        if (self.buffer.items.len == 0) return;
        try f.writeAll(self.buffer.items);
        self.buffer.clearRetainingCapacity();
    }

    /// Replay the WAL. Calls `cb` for each valid record. Stops at the
    /// first corrupt record and returns `error.WALCorrupt` (but the cb
    /// has been called for all prior records).
    pub fn replay(
        self: *WAL,
        data: []const u8,
        cb: *const fn (ctx: anytype, rec: WALRecord) anyerror!void,
        ctx: anytype,
    ) !void {
        _ = self;
        var pos: usize = 0;
        while (pos < data.len) {
            if (pos + @sizeOf(u32) > data.len) break;
            const len = std.mem.readInt(u32, data[pos..][0..@sizeOf(u32)], .little);
            pos += @sizeOf(u32);
            if (pos + len > data.len) return error.WALCorrupt;
            const rec_data = data[pos..][0..len];
            pos += len;
            // Parse record.
            if (rec_data.len < 1 + @sizeOf(i64) + @sizeOf(u32)) return error.WALCorrupt;
            const rec_type = rec_data[0];
            const payload_end = rec_data.len - @sizeOf(i64) - @sizeOf(u32);
            const payload = rec_data[1..payload_end];
            const ts = std.mem.readInt(i64, rec_data[payload_end..][0..@sizeOf(i64)], .little);
            const cs_stored = std.mem.readInt(u32, rec_data[payload_end + @sizeOf(i64)..][0..@sizeOf(u32)], .little);

            const rec = WALRecord{
                .record_type = @enumFromInt(rec_type),
                .payload = payload,
                .timestamp = ts,
            };
            const cs_computed = rec.checksum();
            if (cs_stored != cs_computed) return error.WALCorrupt;
            try cb(ctx, rec);
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "WAL: append + replay" {
    var wal = try WAL.init(std.testing.allocator, "data/test.wal");
    defer wal.deinit();
    try wal.open();
    defer {
        std.fs.cwd().deleteFile("data/test.wal") catch {};
    }

    try wal.append(.{ .record_type = .memcell_insert, .payload = "hello", .timestamp = 1000 });
    try wal.append(.{ .record_type = .memcell_insert, .payload = "world", .timestamp = 2000 });
    try wal.flush();

    // Replay from disk.
    const f = try std.fs.cwd().openFile("data/test.wal", .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try std.testing.allocator.alloc(u8, stat.size);
    defer std.testing.allocator.free(buf);
    _ = try f.readAll(buf);

    var records: usize = 0;
    try wal.replay(buf, struct {
        fn cb(ctx: *usize, rec: WALRecord) !void {
            _ = rec;
            ctx.* += 1;
        }
    }.cb, &records);
    try std.testing.expectEqual(@as(usize, 2), records);
}

test "WAL: checksum corruption is detected" {
    var wal = try WAL.init(std.testing.allocator, "data/test_corrupt.wal");
    defer wal.deinit();
    try wal.open();
    defer {
        std.fs.cwd().deleteFile("data/test_corrupt.wal") catch {};
    }
    try wal.append(.{ .record_type = .memcell_insert, .payload = "x", .timestamp = 100 });
    try wal.flush();

    // Corrupt the file: flip a byte in the middle.
    const f = try std.fs.cwd().openFile("data/test_corrupt.wal", .{ .mode = .read_write });
    defer f.close();
    var buf: [64]u8 = undefined;
    _ = try f.readAll(&buf);
    buf[10] ^= 0xFF;
    _ = try f.seekTo(0);
    try f.writeAll(&buf);

    // Replay: should error.
    try std.testing.expectError(error.WALCorrupt, wal.replay(&buf, struct {
        fn cb(_: *u8, _: WALRecord) !void {}
    }.cb, @as(*u8, undefined)));
}
