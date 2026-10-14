//! Snapshot — full memory state dump with atomic-rename recovery.
//!
//! **GHW Layer**: L4 Storage (snapshot). Pairs with the WAL (write-ahead
//! log) to provide two-tier durability:
//!
//!   - **WAL** records every mutation as it happens. On restart we
//!     replay the WAL to reconstruct state. Cheap to write (per-record
//!     append), expensive to read (N record reads + parse).
//!   - **Snapshot** captures the full state at a moment in time.
//!     Cheap to read (one read), expensive to write (full state
//!     dump). Used to truncate the WAL after a successful snapshot so
//!     the WAL never grows unbounded.
//!
//! **Constitution compliance**:
//! - Principle IV (零依赖): pure Zig, no external snapshot libs.
//! - Principle V (零拷贝 + comptime): no runtime reflection; we
//!   emit each known type field-by-field with a comptime-derived
//!   layout.
//! - Principle VII (可观测性): dump/inspect commands work the
//!   same way for snapshots and live state.
//!
//! ## Atomicity
//!
//! `write()` emits to a temp file, fsyncs, then `rename(2)`s over
//! the previous snapshot. POSIX guarantees that the rename is atomic
//! — readers either see the old or the new file, never a partial
//! write. On crash mid-write, the previous snapshot is still
//! available; the half-written temp file is unlinked at startup.

const std = @import("std");
const platform_fs = @import("../platform/fs.zig");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const MemorySource = core.MemorySource;
const TriSourceManager = @import("../memory/tri_source_manager.zig").TriSourceManager;
const FuzzyStore = @import("../memory/forgetter.zig").FuzzyStore;
const GoalPoset = @import("../ghw/goal_tree.zig").GoalPoset;
const ROOT_GOAL_ID = @import("../ghw/goal_tree.zig").ROOT_GOAL_ID;
const TOP_GOAL_ID = @import("../ghw/goal_tree.zig").TOP_GOAL_ID;
const GoalNode = @import("../ghw/goal_node.zig").GoalNode;
const GoalStatus = core.GoalStatus;
const hashing = @import("../utils/hashing.zig");

/// Magic bytes at the start of every snapshot. Bumping this on
/// incompatible format changes makes the loader refuse to read
/// older snapshots, surfacing the migration need loudly.
pub const SNAPSHOT_MAGIC: u32 = 0x4D45_4D53; // "MEMS" in little-endian
pub const SNAPSHOT_VERSION: u32 = 1;

/// Per-goal snapshot row.
pub const GoalSnapshot = struct {
    id: u64,
    name: []const u8,
    description: []const u8,
    parent_id: ?u64,
    status: GoalStatus,
    priority: u8,
};

/// Per-cell snapshot row. Owned (heap-allocated strings). Free via
/// `freeCellSnapshot(alloc, &cell)` after use.
pub const CellSnapshot = struct {
    id: u64,
    source: MemorySource,
    episode: []const u8,
    facts: []core.Fact,
    foresight: []core.Foresight,
    goal_associations: []core.GoalAssociation,
    metadata: core.Metadata,
};

/// Result of a `read()` — caller uses this to restore their state.
pub const SnapshotData = struct {
    alloc: Allocator,
    /// Owned: counter (next id to allocate). Caller should restore
    /// into their atomic id counter.
    counter: u64,
    /// Owned: list of (id, name, description, parent_id, status, priority)
    /// tuples representing the Goal Poset at snapshot time.
    goals: []GoalSnapshot,
    /// Owned: list of cells. Caller should re-insert into their
    /// TriSourceManager (which will dup the slices).
    cells: []CellSnapshot,
    /// Owned: list of cells in the fuzzy store at snapshot time.
    fuzzy_cells: []CellSnapshot,

    pub fn deinit(self: *SnapshotData) void {
        for (self.goals) |*g| {
            self.alloc.free(@constCast(g.name));
            self.alloc.free(@constCast(g.description));
        }
        self.alloc.free(self.goals);
        for (self.cells) |*cell| {
            freeCellSnapshot(self.alloc, cell);
        }
        self.alloc.free(self.cells);
        for (self.fuzzy_cells) |*cell| {
            freeCellSnapshot(self.alloc, cell);
        }
        self.alloc.free(self.fuzzy_cells);
    }
};

/// Writer side. Holds no state — every call is stateless except for
/// the allocator. Caller decides when to write a snapshot (e.g. after
/// every N cells, or on graceful shutdown, or on `/api/sync` if the
/// argument is supplied).
pub const SnapshotWriter = struct {
    alloc: Allocator,
    path: []const u8,

    pub fn init(alloc: Allocator, path: []const u8) SnapshotWriter {
        return .{ .alloc = alloc, .path = path };
    }

    /// Write a snapshot of (counter, goals, mgr, fuzzy) to a temp
    /// file, then atomically rename over `self.path`. Returns the
    /// number of bytes written on success.
    pub fn write(
        self: *SnapshotWriter,
        counter: u64,
        goals: *GoalPoset,
        mgr: *TriSourceManager,
        fuzzy: *FuzzyStore,
    ) !usize {
        // Emit to a temp file in the same directory so rename(2) is
        // atomic (no cross-filesystem rename).
        var tmp_path_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{self.path}) catch {
            return error.SnapshotPathTooLong;
        };
        var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const z = std.fmt.bufPrint(&zbuf, "{s}\x00", .{tmp_path}) catch return error.SnapshotPathTooLong;
        const zpath = z[0 .. z.len - 1 :0];

        // Truncate-and-write. `std.c.O` is a `switch (native_os)` whose
        // shape differs per platform — the Linux branch has an `ACCMODE`
        // field and the Windows branch does not — so naming it here broke
        // cross-compilation. The platform layer takes intent instead.
        const fd = platform_fs.open(zpath.ptr, .{
            .access = .write_only,
            .create = .truncate,
        }) catch return error.SnapshotOpenFailed;
        defer platform_fs.close(fd);

        var w: BufferedWriter = .{ .fd = fd };
        defer w.flush() catch {}; // best-effort; we already wrote to OS buffer

        // Header
        try w.writeU32(SNAPSHOT_MAGIC);
        try w.writeU32(SNAPSHOT_VERSION);

        // Counter
        try w.writeU64(counter);

        // Goals — serialize as a flat array. GoalPoset doesn't expose
        // its full internals; we walk the root and children.
        var goal_buf: std.ArrayList(GoalSnapshot) = .empty;
        defer {
            for (goal_buf.items) |*g| {
                self.alloc.free(@constCast(g.name));
                self.alloc.free(@constCast(g.description));
            }
            goal_buf.deinit(self.alloc);
        }
        try self.collectGoals(goals, &goal_buf);
        try w.writeU64(goal_buf.items.len);
        for (goal_buf.items) |g| {
            try w.writeU64(g.id);
            try w.writeString(g.name);
            try w.writeString(g.description);
            try w.writeBool(g.parent_id != null);
            if (g.parent_id) |pid| try w.writeU64(pid);
            try w.writeU8(@intFromEnum(g.status));
            try w.writeU8(g.priority);
        }

        // Cells (live, from mgr)
        var cell_buf: std.ArrayList(CellSnapshot) = .empty;
        defer cell_buf.deinit(self.alloc);
        try self.collectCellsFromMgr(mgr, &cell_buf);
        try w.writeU64(cell_buf.items.len);
        for (cell_buf.items) |cell| try writeCellSnapshot(&w, cell);

        // Fuzzy cells
        var fuzzy_buf: std.ArrayList(CellSnapshot) = .empty;
        defer fuzzy_buf.deinit(self.alloc);
        try self.collectFuzzyCells(fuzzy, &fuzzy_buf);
        try w.writeU64(fuzzy_buf.items.len);
        for (fuzzy_buf.items) |cell| try writeCellSnapshot(&w, cell);

        try w.flush();

        // Durability barrier, BEFORE the rename.
        //
        // `rename(2)` is atomic, but the bytes behind it are only in the
        // OS page cache until they are fsynced. `Store.takeSnapshot`
        // rotates the WAL immediately after this returns, and before
        // this call existed the WAL was the *only* place goals lived — so
        // a power cut right after "snapshot written" could leave a
        // renamed-but-empty snapshot next to a rotated WAL. Failing hard
        // is the safe answer: `takeSnapshot` then propagates and does not
        // touch the WAL at all.
        platform_fs.sync(fd) catch {
            platform_fs.unlink(zpath.ptr) catch {};
            return error.SnapshotSyncFailed;
        };

        // Atomic rename
        var dst_zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const dz = std.fmt.bufPrint(&dst_zbuf, "{s}\x00", .{self.path}) catch return error.SnapshotPathTooLong;
        const dzpath = dz[0 .. dz.len - 1 :0];
        platform_fs.rename(zpath.ptr, dzpath.ptr) catch {
            // Rename failed — clean up the temp file before returning.
            platform_fs.unlink(zpath.ptr) catch {};
            return error.SnapshotRenameFailed;
        };
        return w.bytes_written;
    }

    /// Emit one `GoalSnapshot` per non-synthetic goal, parents before
    /// children.
    ///
    /// This used to be a no-op stub that discarded all three arguments
    /// and left a `TODO: walk GoalPoset`, which meant `goals_count` was
    /// always written as 0 — the format had a slot reserved for the goal
    /// poset (`GoalSnapshot` existed, `read` already parsed it) and
    /// nothing ever filled it. Goals therefore survived *only* as WAL
    /// records, and `Store.takeSnapshot` truncated the WAL right after
    /// writing the snapshot: a crash in between deleted every user goal,
    /// permanently.
    ///
    /// The walk deliberately mirrors `Store.rejournalGoals` exactly:
    ///
    ///   - breadth-first from ⊥, so a parent is always emitted before its
    ///     children and a single forward pass on restore is enough;
    ///   - the synthetic ⊥/⊤ are skipped — `GoalPoset.init` rebuilds
    ///     them, and a record claiming a reserved id is rejected on
    ///     replay;
    ///   - `GoalPoset` stores ⊥ as a concrete `parent_id` while the API
    ///     spells "no parent" as `null`; ⊥ is folded back to `null` on
    ///     the way out, exactly as the WAL payload does, because
    ///     `GoalPoset.create` maps `null` back to ⊥. Both replay paths
    ///     must rebuild the identical poset, or a restart after a
    ///     snapshot would diverge from one after a WAL replay.
    ///
    /// The queue is explicit rather than recursive: a goal tree is
    /// arbitrary depth, and self-recursion would put the stack — not the
    /// heap — in the way.
    fn collectGoals(
        self: *SnapshotWriter,
        goals: *GoalPoset,
        out: *std.ArrayList(GoalSnapshot),
    ) !void {
        var queue: std.ArrayList(u64) = .empty;
        defer queue.deinit(self.alloc);
        try queue.append(self.alloc, ROOT_GOAL_ID);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            for (goals.childrenOf(queue.items[head])) |child_id| {
                if (child_id == ROOT_GOAL_ID or child_id == TOP_GOAL_ID) continue;
                const node = goals.get(child_id) orelse continue;
                const parent_id: ?u64 = if (node.parent_id) |p|
                    (if (p == ROOT_GOAL_ID) null else p)
                else
                    null;
                const name = try self.alloc.dupe(u8, node.name);
                errdefer self.alloc.free(name);
                const description = try self.alloc.dupe(u8, node.description);
                errdefer self.alloc.free(description);
                try out.append(self.alloc, .{
                    .id = node.id,
                    .name = name,
                    .description = description,
                    .parent_id = parent_id,
                    .status = node.status,
                    .priority = node.priority,
                });
                try queue.append(self.alloc, child_id);
            }
        }
    }

    fn collectCellsFromMgr(
        self: *SnapshotWriter,
        mgr: *TriSourceManager,
        out: *std.ArrayList(CellSnapshot),
    ) !void {
        var it_s = mgr.sensory.iterator();
        while (it_s.next()) |e| {
            const cell = e.value_ptr.*;
            try out.append(self.alloc, snapshotFromCell(self.alloc, cell));
        }
        var it_c = mgr.cognitive.iterator();
        while (it_c.next()) |e| {
            const cell = e.value_ptr.*;
            try out.append(self.alloc, snapshotFromCell(self.alloc, cell));
        }
        var it_a = mgr.action.iterator();
        while (it_a.next()) |e| {
            const cell = e.value_ptr.*;
            try out.append(self.alloc, snapshotFromCell(self.alloc, cell));
        }
    }

    fn collectFuzzyCells(
        self: *SnapshotWriter,
        fuzzy: *FuzzyStore,
        out: *std.ArrayList(CellSnapshot),
    ) !void {
        var it = fuzzy.cells.iterator();
        while (it.next()) |e| {
            const cell = e.value_ptr.*;
            try out.append(self.alloc, snapshotFromCell(self.alloc, cell));
        }
    }
};

fn snapshotFromCell(_: Allocator, cell: *const MemCell) CellSnapshot {
    return .{
        .id = cell.id,
        .source = cell.source,
        .episode = cell.episode, // borrowed snapshot — caller transfers ownership via writeCellSnapshot
        .facts = @constCast(cell.atomic_facts),
        .foresight = @constCast(cell.foresight),
        .goal_associations = @constCast(cell.goal_associations),
        .metadata = cell.metadata,
    };
}

fn writeCellSnapshot(w: *BufferedWriter, cell: CellSnapshot) !void {
    try w.writeU64(cell.id);
    try w.writeU8(@intFromEnum(cell.source));
    try w.writeString(cell.episode);
    try w.writeU64(cell.facts.len);
    for (cell.facts) |f| {
        try w.writeString(f.subject);
        try w.writeString(f.predicate);
        try w.writeString(f.object);
        try w.writeF32(f.confidence);
        try w.writeString(f.source);
    }
    try w.writeU64(cell.foresight.len);
    for (cell.foresight) |f| {
        try w.writeString(f.description);
        try w.writeI64(f.valid_from);
        try w.writeI64(f.valid_until);
        try w.writeF32(f.confidence);
    }
    try w.writeU64(cell.goal_associations.len);
    for (cell.goal_associations) |g| {
        try w.writeU64(g.goal_id);
        try w.writeF32(g.relevance);
        try w.writeU8(g.priority);
    }
    try w.writeI64(cell.metadata.created_at);
    try w.writeI64(cell.metadata.updated_at);
    try w.writeF32(cell.metadata.source_confidence);
    try w.writeF32(cell.metadata.emotional_valence);
    try w.writeBool(cell.metadata.location != null);
    if (cell.metadata.location) |loc| try w.writeString(loc);
    try w.writeU64(cell.metadata.access_count);
    try w.writeI64(cell.metadata.last_accessed_at);
    try w.writeF32(cell.metadata.coherence_score);
    try w.writeF32(cell.metadata.importance_score);
    try w.writeF32(cell.metadata.decay_rate);
    try w.writeBool(cell.metadata.is_fuzzy);
    try w.writeBool(cell.metadata.superseded_at != null);
    if (cell.metadata.superseded_at) |ts| try w.writeI64(ts);
    try w.writeBool(cell.metadata.fuzzed_at != null);
    if (cell.metadata.fuzzed_at) |ts| try w.writeI64(ts);
}

/// Reader. Returns SnapshotData which the caller restores into their
/// live state.
pub fn read(alloc: Allocator, path: []const u8) !SnapshotData {
    // Open + read all
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrint(&zbuf, "{s}\x00", .{path}) catch return error.SnapshotPathTooLong;
    const zpath = z[0 .. z.len - 1 :0];
    const fd = platform_fs.open(zpath.ptr, .{ .access = .read_only }) catch
        return error.SnapshotOpenFailed;
    defer platform_fs.close(fd);

    // `std.c.Stat` is `void` on Linux and Windows in Zig 0.17. sizeOf does
    // the same job with a seek, and preserves the read position so the read
    // below still starts at offset 0.
    const size: usize = @intCast(platform_fs.sizeOf(fd) catch
        return error.SnapshotStatFailed);
    if (size == 0) return error.SnapshotEmpty;

    const raw = try alloc.alloc(u8, size);
    defer alloc.free(raw);
    const got = platform_fs.readFull(fd, raw) catch return error.SnapshotTruncated;
    if (got < size) return error.SnapshotTruncated;

    var r: BufferedReader = .{ .data = raw };
    const magic = try r.readU32();
    if (magic != SNAPSHOT_MAGIC) return error.SnapshotBadMagic;
    const version = try r.readU32();
    if (version != SNAPSHOT_VERSION) return error.SnapshotBadVersion;

    const counter = try r.readU64();

    const goals_count = try r.readU64();
    const goals = try alloc.alloc(GoalSnapshot, goals_count);
    // Goal rows own their strings, and `read` has no way to hand a
    // half-built array back to `SnapshotData.deinit` (which frees every
    // row unconditionally). Without this errdefer a truncated snapshot
    // leaked the whole goal array — unreachable while `collectGoals`
    // was a stub that emitted nothing, live the moment it emits.
    var goals_filled: usize = 0;
    errdefer {
        for (goals[0..goals_filled]) |*g| {
            alloc.free(@constCast(g.name));
            alloc.free(@constCast(g.description));
        }
        alloc.free(goals);
    }
    for (goals) |*g| {
        g.id = try r.readU64();
        g.name = try r.readStringAlloc(alloc);
        g.description = try r.readStringAlloc(alloc);
        // Counted the moment the two owning strings exist, not at the
        // end of the row: a corrupt discriminant or a truncated tail
        // fails *after* this point, and those strings still have to be
        // freed. Counting at the end leaked exactly what the reader was
        // supposed to reject cleanly.
        goals_filled += 1;
        const has_parent = try r.readBool();
        g.parent_id = if (has_parent) try r.readU64() else null;
        g.status = try readEnumByte(GoalStatus, &r);
        g.priority = try r.readU8();
    }

    const cells_count = try r.readU64();
    const cells = try alloc.alloc(CellSnapshot, cells_count);
    var cells_filled: usize = 0;
    errdefer {
        for (cells[0..cells_filled]) |*cell| freeCellSnapshot(alloc, cell);
        alloc.free(cells);
    }
    for (cells) |*cell| {
        try readCellSnapshot(alloc, &r, cell);
        cells_filled += 1;
    }

    const fuzzy_count = try r.readU64();
    const fuzzy_cells = try alloc.alloc(CellSnapshot, fuzzy_count);
    // Its own counter, not a shared "rows read so far" one: a shared
    // counter is still carrying `cells.len` by the time the fuzzy
    // errdefer runs, so `fuzzy_cells[0..counter]` walks past the end of
    // the fuzzy array whenever the snapshot holds cells and then fails
    // mid-fuzzy — a bounds panic on the exact input that was supposed
    // to degrade into "no valid snapshot".
    var fuzzy_filled: usize = 0;
    errdefer {
        for (fuzzy_cells[0..fuzzy_filled]) |*cell| freeCellSnapshot(alloc, cell);
        alloc.free(fuzzy_cells);
    }
    for (fuzzy_cells) |*cell| {
        try readCellSnapshot(alloc, &r, cell);
        fuzzy_filled += 1;
    }

    return .{
        .alloc = alloc,
        .counter = counter,
        .goals = goals,
        .cells = cells,
        .fuzzy_cells = fuzzy_cells,
    };
}

fn readCellSnapshot(alloc: Allocator, r: *BufferedReader, cell: *CellSnapshot) !void {
    const cs = cell;
    cs.id = try r.readU64();
    cs.source = try readEnumByte(MemorySource, r);
    cs.episode = try r.readStringAlloc(alloc);
    errdefer alloc.free(@constCast(cs.episode));
    const facts_len = try r.readU64();
    cs.facts = try alloc.alloc(core.Fact, facts_len);
    errdefer alloc.free(@constCast(cs.facts));
    for (cs.facts) |*f| {
        f.subject = try r.readStringAlloc(alloc);
        f.predicate = try r.readStringAlloc(alloc);
        f.object = try r.readStringAlloc(alloc);
        f.confidence = try r.readF32();
        f.source = try r.readStringAlloc(alloc);
    }
    const foresight_len = try r.readU64();
    cs.foresight = try alloc.alloc(core.Foresight, foresight_len);
    errdefer alloc.free(@constCast(cs.foresight));
    for (cs.foresight) |*f| {
        f.description = try r.readStringAlloc(alloc);
        f.valid_from = try r.readI64();
        f.valid_until = try r.readI64();
        f.confidence = try r.readF32();
    }
    const goals_len = try r.readU64();
    cs.goal_associations = try alloc.alloc(core.GoalAssociation, goals_len);
    errdefer alloc.free(@constCast(cs.goal_associations));
    for (cs.goal_associations) |*g| {
        g.goal_id = try r.readU64();
        g.relevance = try r.readF32();
        g.priority = try r.readU8();
    }
    cs.metadata.created_at = try r.readI64();
    cs.metadata.updated_at = try r.readI64();
    cs.metadata.source_confidence = try r.readF32();
    cs.metadata.emotional_valence = try r.readF32();
    const has_loc = try r.readBool();
    cs.metadata.location = if (has_loc) try r.readStringAlloc(alloc) else null;
    cs.metadata.access_count = try r.readU64();
    cs.metadata.last_accessed_at = try r.readI64();
    cs.metadata.coherence_score = try r.readF32();
    cs.metadata.importance_score = try r.readF32();
    cs.metadata.decay_rate = try r.readF32();
    cs.metadata.is_fuzzy = try r.readBool();
    const has_sup = try r.readBool();
    cs.metadata.superseded_at = if (has_sup) try r.readI64() else null;
    const has_fuzz = try r.readBool();
    cs.metadata.fuzzed_at = if (has_fuzz) try r.readI64() else null;
}

/// Read one byte as an enum discriminant, rejecting out-of-range values.
///
/// `@enumFromInt` is a *checked* conversion in safe builds: a corrupt
/// byte in a snapshot would abort the process with "invalid enum value"
/// instead of surfacing as a load failure that `Store.loadSnapshot`
/// already knows how to handle. A snapshot file is untrusted input the
/// moment a write was interrupted, so the check belongs here.
fn readEnumByte(comptime T: type, r: *BufferedReader) !T {
    const raw = try r.readU8();
    const info = @typeInfo(T).@"enum";
    if (raw >= info.field_names.len) return error.SnapshotCorruptField;
    return @enumFromInt(raw);
}

fn freeCellSnapshot(alloc: Allocator, cell: *CellSnapshot) void {
    const cs = cell;
    alloc.free(@constCast(cs.episode));
    for (cs.facts) |f| {
        alloc.free(@constCast(f.subject));
        alloc.free(@constCast(f.predicate));
        alloc.free(@constCast(f.object));
        alloc.free(@constCast(f.source));
    }
    alloc.free(@constCast(cs.facts));
    for (cs.foresight) |f| alloc.free(@constCast(f.description));
    alloc.free(@constCast(cs.foresight));
    alloc.free(@constCast(cs.goal_associations));
    if (cs.metadata.location) |loc| alloc.free(@constCast(loc));
}

// =============================================================================
// Buffered I/O — minimal hand-rolled writer/reader to avoid std.Io's io: parameter
// =============================================================================

const BufferedWriter = struct {
    fd: c_int,
    bytes_written: usize = 0,
    // 64KB buffer; flushed on demand.
    buf: [65536]u8 = undefined,
    pos: usize = 0,

    fn flush(self: *BufferedWriter) !void {
        if (self.pos == 0) return;
        // A short write must not be treated as success: a snapshot that
        // silently stops early is a corrupt snapshot that still looks valid.
        platform_fs.writeAll(self.fd, self.buf[0..self.pos]) catch
            return error.SnapshotWriteFailed;
        self.bytes_written += self.pos;
        self.pos = 0;
    }

    fn writeAll(self: *BufferedWriter, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            const take = @min(bytes.len - i, self.buf.len - self.pos);
            @memcpy(self.buf[self.pos..][0..take], bytes[i..][0..take]);
            self.pos += take;
            i += take;
            if (self.pos == self.buf.len) try self.flush();
        }
    }

    fn writeU64(self: *BufferedWriter, v: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        try self.writeAll(&buf);
    }

    fn writeU32(self: *BufferedWriter, v: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        try self.writeAll(&buf);
    }

    fn writeU8(self: *BufferedWriter, v: u8) !void {
        try self.writeAll(&[1]u8{v});
    }

    fn writeI64(self: *BufferedWriter, v: i64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, v, .little);
        try self.writeAll(&buf);
    }

    fn writeF32(self: *BufferedWriter, v: f32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @bitCast(v), .little);
        try self.writeAll(&buf);
    }

    fn writeBool(self: *BufferedWriter, v: bool) !void {
        try self.writeU8(if (v) 1 else 0);
    }

    fn writeString(self: *BufferedWriter, s: []const u8) !void {
        try self.writeU64(s.len);
        try self.writeAll(s);
    }
};

const BufferedReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readExact(self: *BufferedReader, n: usize) ![]u8 {
        // Written as a subtraction rather than `self.pos + n > len`: `n`
        // comes straight off the wire (a string length), so a corrupt or
        // truncated file can make the addition overflow — which is a
        // panic in safe builds, i.e. a crash on exactly the input this
        // function exists to reject.
        if (self.pos > self.data.len or n > self.data.len - self.pos) return error.SnapshotTruncated;
        const out = self.data[self.pos..][0..n];
        self.pos += n;
        return @constCast(out);
    }

    fn readU64(self: *BufferedReader) !u64 {
        var bytes: [8]u8 = undefined;
        const slice = try self.readExact(8);
        @memcpy(&bytes, slice);
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn readU32(self: *BufferedReader) !u32 {
        var bytes: [4]u8 = undefined;
        const slice = try self.readExact(4);
        @memcpy(&bytes, slice);
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn readU8(self: *BufferedReader) !u8 {
        const bytes = try self.readExact(1);
        return bytes[0];
    }

    fn readI64(self: *BufferedReader) !i64 {
        var bytes: [8]u8 = undefined;
        const slice = try self.readExact(8);
        @memcpy(&bytes, slice);
        return std.mem.readInt(i64, &bytes, .little);
    }

    fn readF32(self: *BufferedReader) !f32 {
        var bytes: [4]u8 = undefined;
        const slice = try self.readExact(4);
        @memcpy(&bytes, slice);
        return @bitCast(std.mem.readInt(u32, &bytes, .little));
    }

    fn readBool(self: *BufferedReader) !bool {
        return (try self.readU8()) != 0;
    }

    fn readStringAlloc(self: *BufferedReader, alloc: Allocator) ![]u8 {
        const len = try self.readU64();
        // A length of u64 max from a corrupt file must not become a
        // wrapping `@intCast` on a 32-bit target.
        if (len > std.math.maxInt(usize)) return error.SnapshotTruncated;
        const bytes = try self.readExact(@intCast(len));
        return alloc.dupe(u8, bytes);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Snapshot: write + read roundtrip preserves state" {
    const alloc = std.testing.allocator;
    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();
    var goals = GoalPoset.init(alloc);
    defer goals.deinit();
    _ = goals.create("general", "catch-all", null, 5, null, 0, &ids) catch {};

    const cell: MemCell = .{
        .id = 0,
        .source = .matter,
        .episode = "alpha episode",
        .atomic_facts = &.{
            .{ .subject = "alpha", .predicate = "is", .object = "first", .confidence = 1.0, .source = "test" },
        },
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.5, .priority = 1 },
        },
        .metadata = .{ .source_confidence = 0.9, .importance_score = 0.7, .decay_rate = 0.01 },
    };
    _ = try mgr.add(cell);

    const path = "/tmp/mem3_test_snapshot.bin";
    defer {
        var zb: [std.fs.max_path_bytes + 1]u8 = undefined;
        // `bufPrint` can only fail by overflow; a path too long cannot be
        // unlinked anyway. Note this block cannot `return` — Zig forbids it.
        if (std.fmt.bufPrint(&zb, "{s}\x00", .{path})) |zz| {
            platform_fs.unlink(zz[0 .. zz.len - 1 :0].ptr) catch {};
        } else |_| {}
    }

    var w = SnapshotWriter.init(alloc, path);
    _ = try w.write(42, &goals, &mgr, &fuzzy);

    var data = try read(alloc, path);
    defer data.deinit();
    try std.testing.expectEqual(@as(u64, 42), data.counter);
    try std.testing.expectEqual(@as(usize, 1), data.cells.len);
    try std.testing.expectEqualStrings("alpha episode", data.cells[0].episode);
    try std.testing.expectEqual(@as(MemorySource, .matter), data.cells[0].source);
}

// =============================================================================
// Goal-poset tests
//
// `collectGoals` shipped as a stub that emitted nothing, so `goals_count`
// was written as 0 and `read`'s goal branch never executed. Everything
// below is that branch being exercised for the first time.
// =============================================================================

/// Scratch path under /tmp, pid-isolated so concurrent test binaries and
/// re-runs of a crashed test cannot read each other's snapshot.
fn goalTestPath(buf: []u8, name: []const u8) []const u8 {
    const pid: u64 = @intCast(std.c.getpid());
    return std.fmt.bufPrint(buf, "/tmp/mem3_snap_{d}_{s}.bin", .{ pid, name }) catch unreachable;
}

fn unlinkIfPresent(path: []const u8) void {
    var zb: [platform_fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&zb, "{s}\x00", .{path})) |zz| {
        platform_fs.unlink(zz[0 .. zz.len - 1 :0].ptr) catch {};
    } else |_| {}
}

/// The row for `id`, or null. Written as a lookup rather than an index so
/// the tests assert on *content* and do not depend on the walk's order —
/// only the parents-before-children guarantee matters to the reader, and
/// the store-level test is what pins that down.
fn rowFor(rows: []const GoalSnapshot, id: u64) ?GoalSnapshot {
    for (rows) |r| {
        if (r.id == id) return r;
    }
    return null;
}

test "Snapshot: a six-deep goal chain round-trips through write + read" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = goalTestPath(&path_buf, "deep");
    unlinkIfPresent(path);
    defer unlinkIfPresent(path);

    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();
    var goals = GoalPoset.init(alloc);
    defer goals.deinit();

    // Six levels: d0 ⊥→ d1 → d2 → d3 → d4 → d5. A walk that only
    // descends one level, or that recurses into a fixed-depth buffer,
    // truncates this chain.
    var chain: [6]u64 = undefined;
    var parent: ?u64 = null;
    for (0..6) |i| {
        const name = try std.fmt.allocPrint(alloc, "level-{d}", .{i});
        defer alloc.free(name);
        const desc = try std.fmt.allocPrint(alloc, "depth {d} goal", .{i});
        defer alloc.free(desc);
        chain[i] = try goals.create(name, desc, parent, @intCast(10 - i), null, 1_700_000_000_000 + @as(i64, @intCast(i)), &ids);
        parent = chain[i];
    }
    // A second, shallower branch off ⊥ so the writer has to interleave
    // two subtrees rather than following one happy path.
    const side = try goals.create("side", "hangs directly off root", null, 4, null, 1_700_000_999_999, &ids);
    try goals.updateStatus(chain[2], .completed, 1_700_000_500_000);
    try goals.updateStatus(chain[5], .in_progress, 1_700_000_600_000);

    var w = SnapshotWriter.init(alloc, path);
    _ = try w.write(99, &goals, &mgr, &fuzzy);

    var data = try read(alloc, path);
    defer data.deinit();

    try std.testing.expectEqual(@as(usize, 7), data.goals.len);

    const deep = rowFor(data.goals, chain[5]).?;
    try std.testing.expectEqualStrings("level-5", deep.name);
    try std.testing.expectEqualStrings("depth 5 goal", deep.description);
    try std.testing.expectEqual(chain[4], deep.parent_id.?);
    try std.testing.expectEqual(GoalStatus.in_progress, deep.status);
    try std.testing.expectEqual(@as(u8, 5), deep.priority);

    const done = rowFor(data.goals, chain[2]).?;
    try std.testing.expectEqual(GoalStatus.completed, done.status);
    try std.testing.expectEqual(chain[1], done.parent_id.?);

    // ⊥-parented goals are written in the API's "absent" form, exactly
    // as the WAL payload writes them.
    try std.testing.expectEqual(@as(?u64, null), rowFor(data.goals, chain[0]).?.parent_id);
    try std.testing.expectEqual(@as(?u64, null), rowFor(data.goals, side).?.parent_id);

    // The synthetic nodes are rebuilt by `GoalPoset.init`, never
    // serialized.
    try std.testing.expect(rowFor(data.goals, ROOT_GOAL_ID) == null);
    try std.testing.expect(rowFor(data.goals, TOP_GOAL_ID) == null);
}

test "Snapshot: an empty goal set round-trips as zero goals" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = goalTestPath(&path_buf, "empty");
    unlinkIfPresent(path);
    defer unlinkIfPresent(path);

    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();
    // No user goals — only the synthetic ⊥/⊤ that `GoalPoset.init`
    // always creates.
    var goals = GoalPoset.init(alloc);
    defer goals.deinit();
    try std.testing.expectEqual(@as(usize, 0), goals.count());

    var w = SnapshotWriter.init(alloc, path);
    _ = try w.write(7, &goals, &mgr, &fuzzy);

    var data = try read(alloc, path);
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 0), data.goals.len);
    // The rest of the record still reads back, so this is a genuine
    // empty goal set and not a truncated file.
    try std.testing.expectEqual(@as(u64, 7), data.counter);
    try std.testing.expectEqual(@as(usize, 0), data.cells.len);
    try std.testing.expectEqual(@as(usize, 0), data.fuzzy_cells.len);
}

test "Snapshot: a corrupt goal status byte is rejected, not panicked on" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = goalTestPath(&path_buf, "corrupt");
    unlinkIfPresent(path);
    defer unlinkIfPresent(path);

    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();
    var goals = GoalPoset.init(alloc);
    defer goals.deinit();
    _ = try goals.create("n", "d", null, 5, null, 1_700_000_000_000, &ids);

    var w = SnapshotWriter.init(alloc, path);
    _ = try w.write(1, &goals, &mgr, &fuzzy);

    // Read the file back, patch the one status byte, and put it. The
    // offset is derived from the layout the writer documents, not
    // hard-coded blindly:
    //   magic 4 | version 4 | counter 8 | goals_count 8 | id 8 |
    //   name_len 8 | name | desc_len 8 | desc | has_parent 1 | status
    var zbuf: [platform_fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrint(&zbuf, "{s}\x00", .{path}) catch return error.SkipZigTest;
    const zpath = z[0 .. z.len - 1 :0];
    const fd = try platform_fs.open(zpath, .{ .access = .read_only });
    defer platform_fs.close(fd);
    const size: usize = @intCast(try platform_fs.sizeOf(fd));
    var raw = try alloc.alloc(u8, size);
    defer alloc.free(raw);
    const got = try platform_fs.readFull(fd, raw);
    try std.testing.expectEqual(size, got);

    const name_len: usize = 1;
    const desc_len: usize = 1;
    const status_off = 4 + 4 + 8 + 8 + 8 + 8 + name_len + 8 + desc_len + 1;
    try std.testing.expect(status_off < raw.len);
    try std.testing.expectEqual(@as(u8, 0), raw[status_off]); // .pending
    raw[status_off] = 0xFF;

    const wfd = try platform_fs.open(zpath, .{ .access = .write_only, .create = .truncate });
    defer platform_fs.close(wfd);
    try platform_fs.writeAll(wfd, raw);

    // `@enumFromInt(0xFF)` is a checked panic in safe builds: the
    // reader has to reject it itself, or a single corrupt byte takes
    // the whole process down instead of failing this one load.
    try std.testing.expectError(error.SnapshotCorruptField, read(alloc, path));
}
