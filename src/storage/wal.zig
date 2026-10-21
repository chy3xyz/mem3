//! Write-Ahead Log (WAL) for crash recovery.
//!
//! **Constitution FR-022**: every committed MemCell write is preceded by
//! a `WAL_RECORD_TYPE_MEMCELL_INSERT` log entry. Replay reconstructs state
//! on startup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = std.c;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const HyperEdge = @import("../hypermem/hyperedge.zig").HyperEdge;
const GoalNode = @import("../ghw/goal_node.zig").GoalNode;
const GoalStatus = core.GoalStatus;
const errors = core.Error;
const hashing = @import("../utils/hashing.zig");
const builtin = @import("builtin");
const clock = @import("../platform/clock.zig");

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
        var h = std.hash.XxHash3.init(0);
        h.update(&[_]u8{@intFromEnum(self.record_type)});
        h.update(self.payload);
        h.update(&std.mem.toBytes(self.timestamp));
        return @truncate(h.final());
    }
};

/// Durability mode. See `core.Config.WalSync` for the contract of each
/// variant; the implementation notes are on `WAL` below.
pub const SyncMode = core.Config.WalSync;

/// Durability tickets issued to the *calling thread* and not yet awaited.
///
/// This is how the HTTP daemon releases its store lock before the fsync:
/// the handler opens a scope (`deferDurability`), `append` writes the record
/// and returns without waiting, the handler drops the store lock, and only
/// then `awaitDeferred` blocks until an fsync covers the record. The client
/// is answered after that, so the acknowledgement still follows durability;
/// what changes is that other threads can run (and append) while this one
/// waits, which is the whole point of group commit.
///
/// Thread-local rather than a parameter because the append call sites are
/// buried inside `Store` and several of them are not the hot path; a scope
/// that must not leak into them is easier to guarantee than an argument
/// threaded through every one.
const Pending = struct {
    wal: ?*WAL = null,
    seq: u64 = 0,
    count: usize = 0,
    active: bool = false,
};
threadlocal var tl_pending: Pending = .{};

/// Open a deferral scope on this thread. Every `.group` append until the
/// matching `awaitDeferred` is written but not waited for.
pub fn deferDurability() void {
    tl_pending.active = true;
}

/// Close the scope: block until one fsync covers every record this thread
/// appended since `deferDurability`, and report its failure if it did not.
/// A no-op when nothing was deferred (e.g. `.always` mode, or a request that
/// wrote nothing).
pub fn awaitDeferred() !void {
    const p = tl_pending;
    tl_pending = .{};
    const w = p.wal orelse return;
    defer w.releaseTickets(p.count);
    try w.waitDurable(p.seq);
}

fn monotonicMs() i64 {
    return @intCast(@divTrunc(clock.monotonicNs(), 1_000_000));
}

/// Degraded-path diagnostics, compiled out under test (see `store.zig`'s
/// `diag`: the test runner fails any test that logs, even at `warn`).
fn diag(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) std.log.warn(fmt, args);
}

pub const WAL = struct {
    alloc: Allocator,
    path: []const u8,
    /// POSIX file descriptor (c_int). -1 when closed. Using raw fd avoids
    /// Zig 0.17's Io-based std.fs API which is awkward in this context.
    fd: c_int = -1,
    /// Records appended in this session (not yet flushed to disk).
    buffer: std.ArrayList(u8),
    /// Number of records written. Doubles as the sequence number of the
    /// most recent record: record N is the Nth `append` of this session.
    record_count: u64 = 0,
    /// Sync after every N records.
    sync_every_n: u64 = 64,

    /// When the fsync happens. `.always` (the default) never touches any of
    /// the fields below except the two counters, and never takes `mu`.
    sync: SyncMode = .always,

    // ---- group-commit state. Everything below is guarded by `mu` in
    // `.group` / `.interval_ms` mode. ----
    mu: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    cv: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,
    /// Highest record sequence covered by a *successful* fsync.
    durable_seq: u64 = 0,
    /// A leader is inside fsync(2) right now.
    syncing: bool = false,
    /// Records `<= failed_through` were covered by an fsync that failed.
    /// Permanent: after a failed fsync Linux may drop the dirty pages, so a
    /// later fsync returning 0 proves nothing about those records.
    failed_through: u64 = 0,
    /// Deferred tickets issued and not yet released. `deinit` waits for it
    /// to reach zero so a late waiter never touches a freed WAL.
    pending: usize = 0,
    /// fsync(2) calls that succeeded.
    sync_count: u64 = 0,
    /// Monotonic ms of the last successful fsync (or of `open`).
    last_sync_ms: i64 = 0,

    pub const Stats = struct {
        /// Records written to the file descriptor.
        appended: u64,
        /// Records covered by a successful fsync.
        durable: u64,
        /// Successful fsync calls. `appended / syncs` is the batching factor.
        syncs: u64,
        /// Deferred tickets not yet awaited.
        pending: usize,
    };

    pub fn init(alloc: Allocator, path: []const u8) !WAL {
        return .{
            .alloc = alloc,
            .path = try alloc.dupe(u8, path),
            .fd = -1,
            .buffer = .empty,
            .last_sync_ms = monotonicMs(),
        };
    }

    pub fn deinit(self: *WAL) void {
        // A deferred ticket means some thread is (or is about to be) inside
        // `waitDurable` on this very object. Let it leave first.
        if (self.sync != .always) {
            self.lock();
            while (self.pending > 0) _ = c.pthread_cond_wait(&self.cv, &self.mu);
            self.unlock();
        }
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        self.alloc.free(self.path);
        self.buffer.deinit(self.alloc);
    }

    /// Choose the durability mode. Call before the first append.
    pub fn setSync(self: *WAL, mode: SyncMode) void {
        self.sync = mode;
    }

    /// Open (or create) the WAL file in append mode.
    pub fn open(self: *WAL) !void {
        // Build NUL-terminated path.
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path_z = try std.fmt.bufPrint(&path_buf, "{s}\x00", .{self.path});
        const flags: c.O = .{ .CREAT = true, .APPEND = true, .ACCMODE = .WRONLY };
        const fd = c.open(path_z[0 .. path_z.len - 1 :0].ptr, flags, @as(c.mode_t, 0o644));
        if (fd < 0) return error.WALOpenFailed;
        self.fd = fd;
        self.last_sync_ms = monotonicMs();
    }

    fn lock(self: *WAL) void {
        _ = c.pthread_mutex_lock(&self.mu);
    }
    fn unlock(self: *WAL) void {
        _ = c.pthread_mutex_unlock(&self.mu);
    }

    pub fn stats(self: *WAL) Stats {
        self.lock();
        defer self.unlock();
        return .{
            .appended = self.record_count,
            .durable = self.durable_seq,
            .syncs = self.sync_count,
            .pending = self.pending,
        };
    }

    /// Append a record. In `.always` mode the record is buffered, written
    /// and fsynced before this returns. In `.group` it is written and this
    /// returns once an fsync covering it has completed (or, inside a
    /// `deferDurability` scope, immediately — see `awaitDeferred`). In
    /// `.interval_ms` it is written and the fsync happens at most every N ms.
    pub fn append(self: *WAL, rec: WALRecord) !void {
        _ = try self.appendSeq(rec);
    }

    /// `append`, returning the record's sequence number.
    pub fn appendSeq(self: *WAL, rec: WALRecord) !u64 {
        switch (self.sync) {
            .always => {
                try self.encode(rec);
                self.record_count += 1;
                // Flush after every record to make this safe for crash recovery.
                try self.flushAlways();
                return self.record_count;
            },
            .group, .interval_ms => return self.appendBuffered(rec),
        }
    }

    /// Serialise one record into `self.buffer`.
    fn encode(self: *WAL, rec: WALRecord) !void {
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
    }

    /// `.group` / `.interval_ms` append: write under `mu`, sync outside it.
    fn appendBuffered(self: *WAL, rec: WALRecord) !u64 {
        // A scope opened against another WAL (the store swaps its WAL object
        // on snapshot) must settle before this one joins it.
        if (tl_pending.active) try self.settleForeignTickets();

        self.lock();
        const seq = self.stageLocked(rec) catch |err| {
            self.unlock();
            return err;
        };
        switch (self.sync) {
            .always => unreachable, // SAFETY: appendSeq routes `.always` elsewhere.
            .group => {
                if (tl_pending.active) {
                    tl_pending.wal = self;
                    tl_pending.seq = seq;
                    tl_pending.count += 1;
                    self.pending += 1;
                    self.unlock();
                    return seq;
                }
                self.unlock();
                try self.waitDurable(seq);
            },
            .interval_ms => |ms| {
                const due = monotonicMs() - self.last_sync_ms >= ms;
                self.unlock();
                if (due) try self.waitDurable(seq);
            },
        }
        return seq;
    }

    fn settleForeignTickets(self: *WAL) !void {
        const w = tl_pending.wal orelse return;
        if (w == self) return;
        const p = tl_pending;
        tl_pending.wal = null;
        tl_pending.seq = 0;
        tl_pending.count = 0;
        defer w.releaseTickets(p.count);
        try w.waitDurable(p.seq);
    }

    /// Encode + write(2) one record, with `mu` held. The record is in the
    /// kernel when this returns — durable against a process crash, not yet
    /// against power loss.
    fn stageLocked(self: *WAL, rec: WALRecord) !u64 {
        if (self.fd < 0) return error.WALCorrupt;
        self.encode(rec) catch |err| {
            self.buffer.clearRetainingCapacity();
            return err;
        };
        defer self.buffer.clearRetainingCapacity();
        var pos: usize = 0;
        while (pos < self.buffer.items.len) {
            const n = c.write(self.fd, self.buffer.items[pos..].ptr, self.buffer.items.len - pos);
            if (n <= 0) return error.WALWriteFailed;
            pos += @intCast(n);
        }
        self.record_count += 1;
        return self.record_count;
    }

    fn releaseTickets(self: *WAL, n: usize) void {
        self.lock();
        self.pending -= n;
        _ = c.pthread_cond_broadcast(&self.cv);
        self.unlock();
    }

    /// Block until an fsync covering record `seq` has succeeded.
    ///
    /// Leader/follower: the first waiter to find no fsync in flight becomes
    /// the leader, releases `mu`, and fsyncs everything written so far — which
    /// includes records appended by threads that arrived while it was
    /// running. Everyone else sleeps on `cv`. `mu` is never held across the
    /// fsync, and neither is the caller's store lock if it used
    /// `deferDurability`.
    pub fn waitDurable(self: *WAL, seq: u64) !void {
        if (self.sync == .always) return;
        self.lock();
        while (true) {
            if (seq <= self.failed_through) {
                self.unlock();
                return error.WALSyncFailed;
            }
            if (self.durable_seq >= seq) {
                self.unlock();
                return;
            }
            if (self.syncing) {
                _ = c.pthread_cond_wait(&self.cv, &self.mu);
                continue;
            }
            self.syncing = true;
            const target = self.record_count;
            self.unlock();
            const rc = c.fsync(self.fd);
            self.lock();
            self.syncing = false;
            if (rc == 0) {
                if (target > self.durable_seq) self.durable_seq = target;
                self.sync_count += 1;
                self.last_sync_ms = monotonicMs();
            } else {
                if (target > self.failed_through) self.failed_through = target;
                diag("WAL fsync returned {d}; {d} record(s) are NOT durable and their writers get an error", .{ rc, target - self.durable_seq });
            }
            _ = c.pthread_cond_broadcast(&self.cv);
        }
    }

    /// Interval mode's idle-stream flush: fsync if the interval has elapsed
    /// and there is anything unsynced. A no-op in the other modes. The
    /// daemon calls this from its maintenance tick so a quiet stream still
    /// reaches the disk within the interval.
    pub fn syncIfDue(self: *WAL) !void {
        try self.syncIfDueAt(monotonicMs());
    }

    /// `syncIfDue` with the clock supplied by the caller (monotonic ms).
    pub fn syncIfDueAt(self: *WAL, now_ms: i64) !void {
        const ms = switch (self.sync) {
            .interval_ms => |m| m,
            else => return,
        };
        self.lock();
        const target = self.record_count;
        const due = self.durable_seq < target and now_ms - self.last_sync_ms >= ms;
        self.unlock();
        if (due) try self.waitDurable(target);
    }

    /// Make everything appended so far durable. After a successful flush
    /// the data is `fsync`d so it survives a process crash.
    pub fn flush(self: *WAL) !void {
        if (self.sync == .always) return self.flushAlways();
        if (self.fd < 0) return error.WALCorrupt;
        self.lock();
        const target = self.record_count;
        self.unlock();
        try self.waitDurable(target);
    }

    fn flushAlways(self: *WAL) !void {
        if (self.fd < 0) return error.WALCorrupt;
        if (self.buffer.items.len == 0) return;
        var pos: usize = 0;
        while (pos < self.buffer.items.len) {
            const n = c.write(self.fd, self.buffer.items[pos..].ptr, self.buffer.items.len - pos);
            if (n < 0) return error.WALWriteFailed;
            if (n == 0) return error.WALWriteFailed;
            pos += @intCast(n);
        }
        // fsync — durability on process crash. Non-fatal if it fails
        // (network FS, etc.) since the data is already in the OS page cache.
        const fsync_rc = c.fsync(self.fd);
        if (fsync_rc != 0) {
            std.log.warn("WAL fsync returned {d} (data is in OS cache, may be lost on hard crash)", .{fsync_rc});
        } else {
            self.durable_seq = self.record_count;
            self.sync_count += 1;
            self.last_sync_ms = monotonicMs();
        }
        self.buffer.clearRetainingCapacity();
    }

    /// Replay the WAL. Calls `cb` for each valid record. Stops at the
    /// first corrupt record and returns `error.WALCorrupt` (but the cb
    /// has been called for all prior records).
    pub fn replay(
        self: *WAL,
        data: []const u8,
        ctx: anytype,
        comptime cb: fn (ctx: @TypeOf(ctx), rec: WALRecord) anyerror!void,
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

/// Scratch path under /tmp, pid-isolated. A fixed path means a run that
/// died before its cleanup could leave a WAL behind, and the next run
/// would replay someone else's records: the same command then gives a
/// different answer depending on what ran before it.
/// `std.c.unlink` needs a sentinel-terminated slice; a `bufPrint` result is
/// not one, and a string literal only coerces because it is.
fn unlinkIfPresent(path: []const u8) void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}\x00", .{path})) |z| {
        _ = std.c.unlink(z[0 .. z.len - 1 :0].ptr);
    } else |_| {}
}

fn walTestPath(buf: []u8, name: []const u8) []const u8 {
    const pid: u64 = @intCast(std.c.getpid());
    return std.fmt.bufPrint(buf, "/tmp/mem3_wal_{d}_{s}", .{ pid, name }) catch unreachable;
}

test "WAL: append + replay" {
    // Scratch path lives outside the repo: a fresh clone has no `data/`
    // dir, and the test must not depend on one existing.
    var path_buf: [96]u8 = undefined;
    const wal_path = walTestPath(&path_buf, "append");
    var wal = try WAL.init(std.testing.allocator, wal_path);
    defer wal.deinit();
    try wal.open();
    defer unlinkIfPresent(wal_path);

    try wal.append(.{ .record_type = .memcell_insert, .payload = "hello", .timestamp = 1000 });
    try wal.append(.{ .record_type = .memcell_insert, .payload = "world", .timestamp = 2000 });
    try wal.flush();

    // Replay from disk. Read through the platform layer, not `std.c.fstat`:
    // `std.c.Stat` is `void` on Linux in Zig 0.17, so the old direct call
    // compiled on macOS and made the whole `src/main.zig` test binary fail to
    // compile on Linux (found by running the suite in a Linux container;
    // cross-compiling `zig build` never builds the test root).
    const buf = try slurp(std.testing.allocator, wal_path);
    defer std.testing.allocator.free(buf);

    var records: usize = 0;
    const Cb = struct {
        fn cb(ctx: *usize, rec: WALRecord) !void {
            _ = rec;
            ctx.* += 1;
        }
    };
    try wal.replay(buf, &records, Cb.cb);
    try std.testing.expectEqual(@as(usize, 2), records);
}

test "WAL: checksum corruption is detected" {
    var cpath_buf: [96]u8 = undefined;
    const corrupt_path = walTestPath(&cpath_buf, "corrupt");
    var wal = try WAL.init(std.testing.allocator, corrupt_path);
    defer wal.deinit();
    try wal.open();
    defer unlinkIfPresent(corrupt_path);
    try wal.append(.{ .record_type = .memcell_insert, .payload = "x", .timestamp = 100 });
    try wal.flush();

    // Corrupt the file: flip a byte in the middle. Use POSIX open()
    // since std.fs.cwd() is gone in Zig 0.17.
    var zpath: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = try std.fmt.bufPrint(&zpath, "{s}\x00", .{corrupt_path});
    const zslice = z[0 .. z.len - 1 :0];
    const flags: std.c.O = .{ .ACCMODE = .RDWR };
    const fd = std.c.open(zslice.ptr, flags, @as(std.c.mode_t, 0));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var buf: [64]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.c.read(fd, buf[got..].ptr, buf.len - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    buf[10] ^= 0xFF;
    _ = std.c.lseek(fd, 0, std.c.SEEK.SET);
    var written: usize = 0;
    while (written < got) {
        const n = std.c.write(fd, buf[written..got].ptr, got - written);
        if (n <= 0) break;
        written += @intCast(n);
    }

    // Replay: should error.
    const CbNoop = struct {
        fn cb(_: *u8, _: WALRecord) !void {}
    };
    try std.testing.expectError(error.WALCorrupt, wal.replay(buf[0..got], @as(*u8, undefined), CbNoop.cb));
}

// =============================================================================
// Durability-mode tests (group commit / interval)
//
// The contract under test, in order of how much it matters:
//   1. `group` never acknowledges a record before an fsync that covers it.
//   2. The bytes on disk are identical in every mode, so replay and torn-tail
//      handling cannot differ between them.
//   3. Nothing leaks, nothing deadlocks, and a failed fsync is never reported
//      as success.
// =============================================================================

const platform_fs = @import("../platform/fs.zig");

fn slurp(alloc: Allocator, path: []const u8) ![]u8 {
    const z = platform_fs.z(path);
    const fd = try platform_fs.open(z.ptr(), .{ .access = .read_only });
    defer platform_fs.close(fd);
    const size: usize = @intCast(try platform_fs.sizeOf(fd));
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    const got = try platform_fs.readFull(fd, buf);
    return buf[0..got];
}

const CountCtx = struct {
    alloc: Allocator,
    payloads: std.ArrayList([]u8) = .empty,

    fn deinit(self: *CountCtx) void {
        for (self.payloads.items) |p| self.alloc.free(p);
        self.payloads.deinit(self.alloc);
    }
    fn cb(self: *CountCtx, rec: WALRecord) anyerror!void {
        try self.payloads.append(self.alloc, try self.alloc.dupe(u8, rec.payload));
    }
};

fn openModeWal(alloc: Allocator, name: []const u8, mode: core.Config.WalSync, path_buf: []u8) !WAL {
    const path = walTestPath(path_buf, name);
    unlinkIfPresent(path);
    var wal = try WAL.init(alloc, path);
    errdefer wal.deinit();
    wal.setSync(mode);
    try wal.open();
    return wal;
}

test "WAL group: a single writer is acknowledged only once its record is durable" {
    var pb: [96]u8 = undefined;
    var wal = try openModeWal(std.testing.allocator, "grp_single", .group, &pb);
    defer wal.deinit();
    defer unlinkIfPresent(wal.path); // runs first: deinit frees `wal.path`

    for (0..10) |i| {
        const seq = try wal.appendSeq(.{ .record_type = .memcell_insert, .payload = "x", .timestamp = @intCast(i) });
        // The ack has happened (appendSeq returned). The fsync covering it
        // must already have completed.
        try std.testing.expect(wal.stats().durable >= seq);
    }
    const st = wal.stats();
    try std.testing.expectEqual(@as(u64, 10), st.appended);
    try std.testing.expectEqual(@as(u64, 10), st.durable);
    // One writer means no batching: group degrades to always, it does not
    // skip syncs.
    try std.testing.expectEqual(@as(u64, 10), st.syncs);
}

test "WAL group: deferred tickets from one thread share a single fsync" {
    var pb: [96]u8 = undefined;
    var wal = try openModeWal(std.testing.allocator, "grp_defer", .group, &pb);
    defer wal.deinit();
    defer unlinkIfPresent(wal.path); // runs first: deinit frees `wal.path`

    deferDurability();
    for (0..5) |i| {
        try wal.append(.{ .record_type = .memcell_insert, .payload = "d", .timestamp = @intCast(i) });
    }
    // Written, not yet durable, not yet synced: the caller has NOT been
    // told "ok" in any sense that matters — it has not waited.
    var st = wal.stats();
    try std.testing.expectEqual(@as(u64, 5), st.appended);
    try std.testing.expectEqual(@as(u64, 0), st.durable);
    try std.testing.expectEqual(@as(u64, 0), st.syncs);

    try awaitDeferred();
    st = wal.stats();
    try std.testing.expectEqual(@as(u64, 5), st.durable);
    try std.testing.expectEqual(@as(u64, 1), st.syncs);
    try std.testing.expectEqual(@as(usize, 0), st.pending);
}

test "WAL group: deferral is per-scope, a plain append afterwards waits again" {
    var pb: [96]u8 = undefined;
    var wal = try openModeWal(std.testing.allocator, "grp_scope", .group, &pb);
    defer wal.deinit();
    defer unlinkIfPresent(wal.path); // runs first: deinit frees `wal.path`

    deferDurability();
    try wal.append(.{ .record_type = .memcell_insert, .payload = "a", .timestamp = 1 });
    try awaitDeferred();
    // The scope is closed: this one must wait for its own fsync.
    const seq = try wal.appendSeq(.{ .record_type = .memcell_insert, .payload = "b", .timestamp = 2 });
    try std.testing.expect(wal.stats().durable >= seq);
    // awaitDeferred with nothing deferred is a no-op, not an error.
    try awaitDeferred();
}

test "WAL group: concurrent writers lose nothing and never see an early ack" {
    const alloc = std.testing.allocator;
    var pb: [96]u8 = undefined;
    var wal = try openModeWal(alloc, "grp_conc", .group, &pb);
    defer wal.deinit();
    defer unlinkIfPresent(wal.path); // runs first: deinit frees `wal.path`

    const THREADS = 8;
    const PER = 40;
    const Worker = struct {
        fn run(w: *WAL, t: usize, bad: *std.atomic.Value(u32)) void {
            var buf: [32]u8 = undefined;
            for (0..PER) |i| {
                const payload = std.fmt.bufPrint(&buf, "t{d}:{d}", .{ t, i }) catch unreachable;
                const seq = w.appendSeq(.{ .record_type = .memcell_insert, .payload = payload, .timestamp = 0 }) catch {
                    _ = bad.fetchAdd(1, .monotonic);
                    return;
                };
                // The ack point. Durable must already cover this record.
                if (w.stats().durable < seq) _ = bad.fetchAdd(1, .monotonic);
            }
        }
    };
    var bad: std.atomic.Value(u32) = .init(0);
    var threads: [THREADS]std.Thread = undefined;
    for (&threads, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{ &wal, t, &bad });
    for (threads) |th| th.join();
    try std.testing.expectEqual(@as(u32, 0), bad.load(.monotonic));

    const st = wal.stats();
    try std.testing.expectEqual(@as(u64, THREADS * PER), st.appended);
    try std.testing.expectEqual(@as(u64, THREADS * PER), st.durable);
    // Batching can only ever reduce the number of fsyncs.
    try std.testing.expect(st.syncs <= THREADS * PER);
    try std.testing.expect(st.syncs >= 1);

    // Replay: every record present, intact, and each thread's records in
    // the order that thread wrote them.
    const data = try slurp(alloc, wal.path);
    defer alloc.free(data);
    var ctx = CountCtx{ .alloc = alloc };
    defer ctx.deinit();
    try wal.replay(data, &ctx, CountCtx.cb);
    try std.testing.expectEqual(@as(usize, THREADS * PER), ctx.payloads.items.len);
    var next_i: [THREADS]usize = @splat(0);
    for (ctx.payloads.items) |p| {
        const colon = std.mem.indexOfScalar(u8, p, ':').?;
        const t = try std.fmt.parseInt(usize, p[1..colon], 10);
        const i = try std.fmt.parseInt(usize, p[colon + 1 ..], 10);
        try std.testing.expectEqual(next_i[t], i);
        next_i[t] += 1;
    }
}

test "WAL: the bytes on disk are identical in every durability mode" {
    const alloc = std.testing.allocator;
    const modes = [_]core.Config.WalSync{ .always, .group, .{ .interval_ms = 5_000 } };
    var images: [modes.len][]u8 = undefined;
    var made: usize = 0;
    defer for (images[0..made]) |im| alloc.free(im);

    for (modes, 0..) |mode, k| {
        var pb: [96]u8 = undefined;
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "same_{d}", .{k});
        var wal = try openModeWal(alloc, name, mode, &pb);
        defer wal.deinit();
        defer unlinkIfPresent(wal.path); // runs first: deinit frees `wal.path`
        for (0..25) |i| {
            var buf: [24]u8 = undefined;
            const payload = try std.fmt.bufPrint(&buf, "record-{d}", .{i});
            try wal.append(.{
                .record_type = if (i % 5 == 0) .goal_create else .memcell_insert,
                .payload = payload,
                .timestamp = @as(i64, @intCast(i)) * 1000,
            });
        }
        try wal.flush();
        images[k] = try slurp(alloc, wal.path);
        made += 1;
    }
    try std.testing.expect(images[0].len > 0);
    try std.testing.expectEqualSlices(u8, images[0], images[1]);
    try std.testing.expectEqualSlices(u8, images[0], images[2]);
}

test "WAL: a torn tail replays the same prefix in every durability mode" {
    const alloc = std.testing.allocator;
    var pb: [96]u8 = undefined;
    var wal = try openModeWal(alloc, "torn", .group, &pb);
    defer wal.deinit();
    defer unlinkIfPresent(wal.path); // runs first: deinit frees `wal.path`
    for (0..6) |i| {
        var buf: [24]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, "torn-{d}", .{i});
        try wal.append(.{ .record_type = .memcell_insert, .payload = payload, .timestamp = @intCast(i) });
    }
    const data = try slurp(alloc, wal.path);
    defer alloc.free(data);

    // Cut the image at every byte. `cut` bytes of a log whose records are
    // all the same size contain exactly `cut / rec_len` complete records.
    const rec_len = data.len / 6;
    try std.testing.expectEqual(data.len, rec_len * 6);
    for (0..data.len + 1) |cut| {
        var ctx = CountCtx{ .alloc = alloc };
        defer ctx.deinit();
        const res = wal.replay(data[0..cut], &ctx, CountCtx.cb);
        try std.testing.expectEqual(cut / rec_len, ctx.payloads.items.len);
        if (res) |_| {} else |err| try std.testing.expectEqual(error.WALCorrupt, err);
    }
}

test "WAL interval: fsync runs at most once per interval, flush forces one" {
    var pb: [96]u8 = undefined;
    var wal = try openModeWal(std.testing.allocator, "interval", .{ .interval_ms = 10_000 }, &pb);
    defer wal.deinit();
    defer unlinkIfPresent(wal.path); // runs first: deinit frees `wal.path`

    for (0..50) |i| {
        try wal.append(.{ .record_type = .memcell_insert, .payload = "i", .timestamp = @intCast(i) });
    }
    // 10 s has not passed: 50 acknowledged records, none synced. This is
    // the documented loss window, made visible.
    try std.testing.expectEqual(@as(u64, 0), wal.stats().syncs);
    try std.testing.expectEqual(@as(u64, 50), wal.stats().appended);

    const t0 = wal.last_sync_ms;
    try wal.syncIfDueAt(t0 + 9_999);
    try std.testing.expectEqual(@as(u64, 0), wal.stats().syncs);
    try wal.syncIfDueAt(t0 + 10_000);
    try std.testing.expectEqual(@as(u64, 1), wal.stats().syncs);
    try std.testing.expectEqual(@as(u64, 50), wal.stats().durable);
    // Nothing new to sync: not due again, and not needed.
    try wal.syncIfDueAt(t0 + 25_000);
    try std.testing.expectEqual(@as(u64, 1), wal.stats().syncs);

    try wal.append(.{ .record_type = .memcell_insert, .payload = "tail", .timestamp = 0 });
    try wal.flush();
    try std.testing.expectEqual(@as(u64, 2), wal.stats().syncs);
    try std.testing.expectEqual(@as(u64, 51), wal.stats().durable);
}

test "WAL always: still fsyncs once per record" {
    var pb: [96]u8 = undefined;
    var wal = try openModeWal(std.testing.allocator, "always_cnt", .always, &pb);
    defer wal.deinit();
    defer unlinkIfPresent(wal.path); // runs first: deinit frees `wal.path`
    for (0..7) |i| try wal.append(.{ .record_type = .memcell_insert, .payload = "a", .timestamp = @intCast(i) });
    try std.testing.expectEqual(@as(u64, 7), wal.stats().syncs);
    try std.testing.expectEqual(@as(u64, 7), wal.stats().durable);
}

test "WAL group: flush covers a deferred ticket, and awaiting it afterwards returns" {
    var pb: [96]u8 = undefined;
    var wal = try openModeWal(std.testing.allocator, "grp_flush", .group, &pb);
    defer wal.deinit();
    defer unlinkIfPresent(wal.path); // runs first: deinit frees `wal.path`

    deferDurability();
    try wal.append(.{ .record_type = .memcell_insert, .payload = "f", .timestamp = 1 });
    try wal.flush();
    try std.testing.expectEqual(@as(u64, 1), wal.stats().durable);
    try awaitDeferred();
    try std.testing.expectEqual(@as(usize, 0), wal.stats().pending);
}

test "WAL group: an fsync that fails is never acknowledged" {
    // A pipe accepts write(2) but rejects fsync(2) (EINVAL on both macOS and
    // Linux), which is exactly the shape of "the data reached the kernel and
    // the disk did not confirm it".
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);

    var pb: [96]u8 = undefined;
    const path = walTestPath(&pb, "grp_fail");
    var wal = try WAL.init(std.testing.allocator, path);
    wal.setSync(.group);
    // `deinit` closes whatever fd is installed, so hand it the write end.
    wal.fd = fds[1];
    defer wal.deinit();

    try std.testing.expectError(error.WALSyncFailed, wal.append(.{ .record_type = .memcell_insert, .payload = "p", .timestamp = 1 }));
    try std.testing.expectEqual(@as(u64, 0), wal.stats().durable);
    // Poisoned: a later sync "succeeding" must not retroactively bless a
    // record whose earlier fsync failed (the Linux fsync-failure trap).
    try std.testing.expectError(error.WALSyncFailed, wal.waitDurable(1));
}
