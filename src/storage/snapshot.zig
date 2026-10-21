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
//!
//! ## Format versioning
//!
//! `SNAPSHOT_VERSION` is written in the header and read back before
//! any section is parsed, so a section can change shape without
//! making the rest of the file unreadable. v2 extended the goal row
//! with the four timestamp slots it had no room for in v1; see
//! `SNAPSHOT_VERSION` for the layout, what a v1 file does now, and
//! what it could not carry. The file is parsed from untrusted bytes,
//! so every read is bounds-checked and every enum discriminant is
//! range-checked — a corrupt snapshot is an error, never a panic.

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

/// Current on-disk format version.
///
/// ## v3 — cell rows carry `superseded_by`
///
/// Appended to the END of every cell row (active and fuzzy alike), after
/// `fuzzed_at`:
///
///     flags u8  [+ superseded_by u64 if bit 0]
///
/// `flags` bit 0 = has `superseded_by` (the only bit the first v3 writer
/// used, as a 0/1 bool, so those files read unchanged); bit 1 =
/// `supersede_pinned` (an operator ran `mem3 unsupersede`; the cell is never
/// superseded again). Unknown bits are ignored.
///
/// Everything before it is byte-for-byte what v2 wrote, so a v3 reader
/// loads a v1/v2 file by not reading the suffix: such a cell comes back with
/// `superseded_by = null` (and, if it was superseded at all, a
/// `superseded_at` that names no superseder). `superseded_at` itself has
/// been in the cell row since v1 and did not change. **Existing v1/v2 files
/// still load.** A v3 file does NOT load on a v2 build (`SnapshotBadVersion`,
/// which `Store.loadSnapshot` reports as "no valid snapshot"): upgrade, do
/// not downgrade — after a snapshot the WAL is empty of cells, so a build
/// that refuses the snapshot has nothing to rebuild them from.
pub const SNAPSHOT_VERSION: u32 = 3;

const SUPERSEDED_BY_BIT: u8 = 1;
const SUPERSEDE_PINNED_BIT: u8 = 2;

/// Format version 2: goal rows carry their timestamps (`SNAPSHOT_VERSION`
/// above is the current one).
///
/// ## v2 — goal rows carry their timestamps
///
/// Appended to the END of every goal row, after `priority`:
///
///     has_deadline      u8  [+ deadline        i64]
///     created_at        i64
///     updated_at        i64
///     has_unrealized_at u8  [+ unrealized_at   i64]
///
/// The v1 prefix of a row (id, name, description, has_parent,
/// parent_id, status, priority) is byte-for-byte what v1 wrote, and
/// the version word is read *before* the goal section, so a v2 reader
/// loads a v1 file by not reading the suffix. Nothing else in the file
/// changed — header, counter, cell rows and fuzzy rows are identical
/// across the two versions — so the version branch lives in exactly one
/// place, and an older file's tail needs no re-interpretation.
///
/// **Existing v1 files still load.** A v2 file does NOT load on a v1
/// build: the v1 reader rejects it as `SnapshotBadVersion`, which
/// `Store.loadSnapshot` already treats as "no valid snapshot" and falls
/// back to a WAL replay — and `takeSnapshot` re-journals the whole
/// poset into the fresh WAL immediately after every snapshot, so that
/// fallback costs nothing but the timestamps the v1 record had no room
/// for. Upgrading the binary is still the right answer; downgrading
/// loses goal ages, not goals.
///
/// ## Why the version had to move
///
/// `GoalSnapshot` (v1) had no slot for `created_at`, so
/// `Store.restoreGoalRow` stamped every restored goal with the *restore
/// time*. `GoalPoset.staleGoals` marks a goal unrealized on
/// `now - created_at > 7 days`, so a goal recovered from a snapshot
/// could never go stale: the maintenance thread's unrealization rule
/// silently did not apply to it, while a WAL-replayed store aged its
/// goals correctly. Same store, two restore paths, two behaviours,
/// decided by whether a snapshot happened to exist.
pub const SNAPSHOT_VERSION_V2: u32 = 2;

/// The original format: a goal row ended at `priority`.
pub const SNAPSHOT_VERSION_LEGACY: u32 = 1;

/// Oldest version `read` still accepts. v1 predates the goal
/// timestamps; anything older is refused rather than guessed at.
pub const SNAPSHOT_MIN_VERSION: u32 = SNAPSHOT_VERSION_LEGACY;

/// Per-goal snapshot row.
///
/// ## The four timestamp slots, and why they are `?i64` and not `i64`
///
/// v1 carried none of them. A reader therefore has to be able to say
/// "this file does not know when this goal was created" *distinctly*
/// from "this goal was created at 0", because the two produce opposite
/// behaviour downstream: `staleGoals` computes `now - created_at`, so a
/// real 0 would make every goal restored from a v1 file instantly
/// stale — the snapshot path manufacturing the very data loss the
/// snapshot exists to prevent. `null` means "not carried"; the
/// restore path stamps the restore time for `null`, exactly as v1
/// did. v2 rows always carry all four, so `null` here means the file
/// is a v1 file and nothing else.
///
/// `deadline` and `unrealized_at` are nullable in the model anyway;
/// `created_at` and `updated_at` are not, which is why their
/// nullability here is a *format* fact rather than a model fact.
pub const GoalSnapshot = struct {
    id: u64,
    name: []const u8,
    description: []const u8,
    parent_id: ?u64,
    status: GoalStatus,
    priority: u8,
    /// v2 only; `null` for a v1 row.
    deadline: ?i64 = null,
    /// v2 only; `null` for a v1 row. See the note above before
    /// substituting 0.
    created_at: ?i64 = null,
    /// v2 only; `null` for a v1 row.
    updated_at: ?i64 = null,
    /// v2 only; `null` for a v1 row *and* for a goal that has never
    /// been unrealized.
    unrealized_at: ?i64 = null,
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
            // v2 suffix. Appended after `priority` so the v1 prefix of a
            // row is unchanged and a v1 file is still readable by
            // skipping exactly this block. `collectGoals` fills all
            // four from the live node, so `orelse 0` is unreachable —
            // but an uninitialised 0 written as a *timestamp* would age
            // a goal by 56 years, so the fallback is written explicitly
            // rather than left to `undefined` reading as whatever was
            // in the buffer.
            try w.writeBool(g.deadline != null);
            if (g.deadline) |d| try w.writeI64(d);
            try w.writeI64(g.created_at orelse 0);
            try w.writeI64(g.updated_at orelse g.created_at orelse 0);
            try w.writeBool(g.unrealized_at != null);
            if (g.unrealized_at) |ua| try w.writeI64(ua);
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
                    // The whole point of the v2 row: without these the
                    // restore path has nothing but the clock to stamp,
                    // and a restored goal never ages out.
                    .deadline = node.deadline,
                    .created_at = node.created_at,
                    .updated_at = node.updated_at,
                    .unrealized_at = node.unrealized_at,
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
    // v3 suffix. See SNAPSHOT_VERSION.
    var flags: u8 = 0;
    if (cell.metadata.superseded_by != null) flags |= SUPERSEDED_BY_BIT;
    if (cell.metadata.supersede_pinned) flags |= SUPERSEDE_PINNED_BIT;
    try w.writeU8(flags);
    if (cell.metadata.superseded_by) |by| try w.writeU64(by);
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
    // Read *before* the goal section, which is what makes the versioned
    // goal row affordable: a v1 file is simply a v2 file with the
    // per-row timestamp suffix missing, and nothing after the goal
    // section differs between the two versions.
    if (version < SNAPSHOT_MIN_VERSION or version > SNAPSHOT_VERSION) {
        return error.SnapshotBadVersion;
    }
    const has_goal_timestamps = version >= 2;
    const has_superseded_by = version >= 3;

    const counter = try r.readU64();

    const goals_count = try r.readU64();
    const goals = try alloc.alloc(GoalSnapshot, goals_count);
    // Goal rows own their strings, and `read` has no way to hand a
    // half-built array back to `SnapshotData.deinit` (which frees every
    // row unconditionally). Without this errdefer a truncated snapshot
    // leaked the whole goal array — unreachable while `collectGoals`
    // was a stub that emitted nothing, live the moment it emits.
    //
    // Two counters, because a row owns its strings *progressively*:
    // `goals_named` counts rows whose `name` exists (the row is then
    // part-built — its `description` is not allocated yet, so
    // `freeCellSnapshot`-style unconditional freeing would free
    // `undefined` bytes), and `goals_filled` counts rows that are
    // complete. One counter cannot express both, and the row currently
    // being parsed is the one that differs.
    var goals_named: usize = 0;
    var goals_filled: usize = 0;
    errdefer {
        for (goals[0..goals_filled]) |*g| {
            alloc.free(@constCast(g.name));
            alloc.free(@constCast(g.description));
        }
        // At most one row is part-built: the one in flight.
        if (goals_named > goals_filled) {
            alloc.free(@constCast(goals[goals_filled].name));
        }
        alloc.free(goals);
    }
    for (goals) |*g| {
        g.id = try r.readU64();
        g.name = try r.readStringAlloc(alloc);
        // Counted here, not at the end of the row: a file truncated
        // between the name and the description fails *after* this point
        // and the name still has to be freed. Counting at the end of the
        // row leaked exactly what the reader was supposed to reject
        // cleanly — one allocation per corrupt snapshot, on a path a
        // hostile file can drive as often as it likes.
        goals_named += 1;
        g.description = try r.readStringAlloc(alloc);
        goals_filled += 1;
        const has_parent = try r.readBool();
        g.parent_id = if (has_parent) try r.readU64() else null;
        g.status = try readEnumByte(GoalStatus, &r);
        g.priority = try r.readU8();
        if (has_goal_timestamps) {
            // Every read below is width-checked by `readExact`, and the
            // two optional i64s are gated by a flag byte that is itself
            // a checked read — so a truncated tail lands on
            // `SnapshotTruncated` rather than on `undefined` bytes.
            // Note the ordering: the strings for this row were counted
            // into `goals_filled` above, so failing here still frees
            // them.
            const has_deadline = try r.readBool();
            g.deadline = if (has_deadline) try r.readI64() else null;
            g.created_at = try r.readI64();
            g.updated_at = try r.readI64();
            const has_unrealized = try r.readBool();
            g.unrealized_at = if (has_unrealized) try r.readI64() else null;
        } else {
            // v1: the file genuinely does not know. Leave every slot
            // null rather than inventing a value — `null` is the one
            // encoding the restore path can distinguish from a real
            // timestamp, and it is what keeps a v1 file loading with
            // exactly the behaviour it had before this field existed.
            g.deadline = null;
            g.created_at = null;
            g.updated_at = null;
            g.unrealized_at = null;
        }
    }

    const cells_count = try r.readU64();
    const cells = try alloc.alloc(CellSnapshot, cells_count);
    var cells_filled: usize = 0;
    errdefer {
        for (cells[0..cells_filled]) |*cell| freeCellSnapshot(alloc, cell);
        alloc.free(cells);
    }
    for (cells) |*cell| {
        try readCellSnapshot(alloc, &r, cell, has_superseded_by);
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
        try readCellSnapshot(alloc, &r, cell, has_superseded_by);
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

fn readCellSnapshot(alloc: Allocator, r: *BufferedReader, cell: *CellSnapshot, has_superseded_by: bool) !void {
    const cs = cell;
    cs.id = try r.readU64();
    cs.source = try readEnumByte(MemorySource, r);
    cs.episode = try r.readStringAlloc(alloc);
    errdefer alloc.free(@constCast(cs.episode));
    const facts_len = try r.readU64();
    cs.facts = try alloc.alloc(core.Fact, facts_len);
    // Each element is built by a helper that owns its own cleanup, and
    // the count of *completed* elements is what the errdefer may walk:
    // a file truncated inside a fact otherwise leaves an array whose
    // tail is `undefined`, and freeing that tail frees garbage. This
    // loop used to inline the four string reads and leak every string
    // before the cut.
    var facts_read: usize = 0;
    errdefer {
        freeFactStrings(alloc, cs.facts[0..facts_read]);
        // Not `freeFacts(cs.facts[0..facts_read])`: a zero-length slice
        // frees nothing at all, and the array is what was allocated.
        alloc.free(@constCast(cs.facts));
    }
    while (facts_read < cs.facts.len) : (facts_read += 1) {
        cs.facts[facts_read] = try readFact(alloc, r);
    }
    const foresight_len = try r.readU64();
    cs.foresight = try alloc.alloc(core.Foresight, foresight_len);
    var foresight_read: usize = 0;
    errdefer {
        for (cs.foresight[0..foresight_read]) |f| alloc.free(@constCast(f.description));
        alloc.free(@constCast(cs.foresight));
    }
    while (foresight_read < cs.foresight.len) : (foresight_read += 1) {
        cs.foresight[foresight_read] = try readForesight(alloc, r);
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
    // Held in a local until the row is complete: everything after it is
    // a fixed-width read that a truncated file can still fail on, and
    // the string would then be reachable only from a `CellSnapshot`
    // the caller never receives.
    const location = if (has_loc) try r.readStringAlloc(alloc) else null;
    errdefer {
        if (location) |loc| alloc.free(@constCast(loc));
    }
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
    cs.metadata.superseded_by = null;
    cs.metadata.supersede_pinned = false;
    if (has_superseded_by) {
        const flags = try r.readU8();
        cs.metadata.superseded_by = if (flags & SUPERSEDED_BY_BIT != 0) try r.readU64() else null;
        cs.metadata.supersede_pinned = flags & SUPERSEDE_PINNED_BIT != 0;
    }
    // Nothing below can fail, so ownership transfers cleanly.
    cs.metadata.location = location;
}

/// One fact, or nothing at all: the four strings are freed on any
/// failure, so a truncated file cannot strand them inside a
/// half-initialised array element.
fn readFact(alloc: Allocator, r: *BufferedReader) !core.Fact {
    var f: core.Fact = undefined;
    f.subject = try r.readStringAlloc(alloc);
    errdefer alloc.free(@constCast(f.subject));
    f.predicate = try r.readStringAlloc(alloc);
    errdefer alloc.free(@constCast(f.predicate));
    f.object = try r.readStringAlloc(alloc);
    errdefer alloc.free(@constCast(f.object));
    // Wire order is subject, predicate, object, confidence, source —
    // `confidence` is a fixed-width read that precedes `source`, and
    // reading them the other way round desynchronises the whole stream
    // behind it rather than failing here.
    f.confidence = try r.readF32();
    f.source = try r.readStringAlloc(alloc);
    errdefer alloc.free(@constCast(f.source));
    return f;
}

/// One foresight entry, or nothing. Same shape as `readFact`.
fn readForesight(alloc: Allocator, r: *BufferedReader) !core.Foresight {
    var f: core.Foresight = undefined;
    f.description = try r.readStringAlloc(alloc);
    errdefer alloc.free(@constCast(f.description));
    f.valid_from = try r.readI64();
    f.valid_until = try r.readI64();
    f.confidence = try r.readF32();
    return f;
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
    freeFacts(alloc, cs.facts);
    for (cs.foresight) |f| alloc.free(@constCast(f.description));
    alloc.free(@constCast(cs.foresight));
    alloc.free(@constCast(cs.goal_associations));
    if (cs.metadata.location) |loc| alloc.free(@constCast(loc));
}

/// Free `facts` and every string in it.
fn freeFacts(alloc: Allocator, facts: []core.Fact) void {
    freeFactStrings(alloc, facts);
    alloc.free(@constCast(facts));
}

/// Free every string in `facts`, but not the array. Takes a slice rather
/// than a pointer so a caller holding a part-read array can pass the
/// part that was actually built — its tail is `undefined`, and freeing
/// that tail frees garbage.
fn freeFactStrings(alloc: Allocator, facts: []const core.Fact) void {
    for (facts) |f| {
        alloc.free(@constCast(f.subject));
        alloc.free(@constCast(f.predicate));
        alloc.free(@constCast(f.object));
        alloc.free(@constCast(f.source));
    }
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

    var path_buf: [96]u8 = undefined;
    const path = goalTestPath(&path_buf, "roundtrip");
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

// =============================================================================
// Goal timestamps (format v2)
//
// v1 had no slot for a goal's timestamps, so `Store.restoreGoalRow` had
// nothing to restore and stamped every goal with the wall clock at
// restore time. `GoalPoset.staleGoals` marks a goal unrealized on
// `now - created_at > 7 days`, so a goal recovered from a snapshot
// could never go stale, while a WAL-replayed store aged its goals
// correctly — the same store behaving differently depending on whether
// a snapshot happened to exist. Everything below is the format end of
// that fix: the four values have to survive write -> read, and a poset
// rebuilt from the rows has to be indistinguishable from the one that
// was written.
// =============================================================================

/// Read a whole file. Caller frees. Test-only.
fn readRawFile(alloc: Allocator, path: []const u8) ![]u8 {
    var zb: [platform_fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrint(&zb, "{s}\x00", .{path}) catch return error.SnapshotPathTooLong;
    const zpath = z[0 .. z.len - 1 :0];
    const fd = try platform_fs.open(zpath, .{ .access = .read_only });
    defer platform_fs.close(fd);
    const size: usize = @intCast(try platform_fs.sizeOf(fd));
    const raw = try alloc.alloc(u8, size);
    errdefer alloc.free(raw);
    // `readFull` reports a short read as success-with-fewer-bytes, so
    // the count has to be checked here rather than assumed.
    const got = try platform_fs.readFull(fd, raw);
    if (got != size) {
        alloc.free(raw);
        return error.SnapshotTruncated;
    }
    return raw;
}

/// Overwrite `path` with `bytes`. Test-only.
fn writeRawFile(path: []const u8, bytes: []const u8) !void {
    var zb: [platform_fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrint(&zb, "{s}\x00", .{path}) catch return error.SnapshotPathTooLong;
    const zpath = z[0 .. z.len - 1 :0];
    const fd = try platform_fs.open(zpath, .{ .access = .write_only, .create = .truncate });
    defer platform_fs.close(fd);
    try platform_fs.writeAll(fd, bytes);
}

/// Offset one past the last byte of goal row `upto - 1` under the **v1**
/// layout — i.e. right after that row's `priority`, which is exactly
/// where v2 starts appending. Derived from the layout the writer
/// documents rather than hard-coded, so a layout change moves this and
/// the cross-check below with it.
fn v1GoalRowEndOffset(rows: []const GoalSnapshot, upto: usize) usize {
    // magic u32 | version u32 | counter u64 | goals_count u64
    var off: usize = 4 + 4 + 8 + 8;
    for (rows[0..upto]) |r| {
        off += 8; // id
        off += 8 + r.name.len; // name_len + name
        off += 8 + r.description.len; // description_len + description
        off += 1; // has_parent
        if (r.parent_id != null) off += 8; // parent_id
        off += 1; // status
        off += 1; // priority  <- v1 row ends here
    }
    return off;
}

/// The bytes v2 appends after row `r`'s `priority`, encoded independently
/// of the writer so the layout is pinned by a second implementation of
/// the spec rather than by the code under test agreeing with itself.
/// Caller frees.
fn expectedV2GoalSuffix(alloc: Allocator, r: GoalSnapshot) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var b8: [8]u8 = undefined;
    try out.append(alloc, if (r.deadline != null) 1 else 0);
    if (r.deadline) |d| {
        std.mem.writeInt(i64, &b8, d, .little);
        try out.appendSlice(alloc, &b8);
    }
    std.mem.writeInt(i64, &b8, r.created_at orelse 0, .little);
    try out.appendSlice(alloc, &b8);
    std.mem.writeInt(i64, &b8, r.updated_at orelse 0, .little);
    try out.appendSlice(alloc, &b8);
    try out.append(alloc, if (r.unrealized_at != null) 1 else 0);
    if (r.unrealized_at) |ua| {
        std.mem.writeInt(i64, &b8, ua, .little);
        try out.appendSlice(alloc, &b8);
    }
    return out.toOwnedSlice(alloc);
}

/// Rebuild a poset from rows, passing the carried timestamps through
/// instead of stamping the clock.
///
/// This is `Store.restoreGoalRow` with the one behaviour change the v2
/// record enables, written out here so the *format* can be held
/// responsible for what it is supposed to carry. `store.zig` owns the
/// production copy; if the two ever disagree, this test keeps failing
/// rather than quietly agreeing with a wrong one.
fn posetFromRows(alloc: Allocator, rows: []const GoalSnapshot) !GoalPoset {
    var poset = GoalPoset.init(alloc);
    errdefer poset.deinit();
    for (rows) |row| {
        if (row.id == ROOT_GOAL_ID or row.id == TOP_GOAL_ID) continue;
        // `created_at` is carried by every v2 row. `null` here means the
        // file predates the field, and the point of the test is that the
        // v2 path never lands in that branch.
        const created_at = row.created_at orelse return error.TestUnexpectedResult;
        var slot: std.atomic.Value(u64) = .init(row.id);
        const minted = try poset.create(
            row.name,
            row.description,
            row.parent_id,
            row.priority,
            row.deadline,
            created_at,
            &slot,
        );
        if (minted != row.id) return error.TestUnexpectedResult;
        if (row.status != .pending) {
            poset.updateStatus(row.id, row.status, row.updated_at orelse created_at) catch {
                // Same fallback as `Store.restoreGoalRow`: the recorded
                // status wins over a state-machine refusal.
                const node = @constCast(poset.get(row.id).?);
                node.status = row.status;
                node.updated_at = row.updated_at orelse created_at;
            };
        }
        // `updateStatus` sets `unrealized_at` to the status time, which
        // is only right when the goal is *currently* unrealized. A goal
        // that went unrealized and was revived carries the older mark,
        // and the row has to keep it — it is what the ≥7-day
        // tombstoning rule reads.
        if (row.unrealized_at) |ua| {
            @constCast(poset.get(row.id).?).unrealized_at = ua;
        }
    }
    return poset;
}

/// Every field the two posets have in common, in both directions.
fn expectPosetsIdentical(left: *const GoalPoset, right: *const GoalPoset) !void {
    try std.testing.expectEqual(left.count(), right.count());
    var it = left.nodes.iterator();
    while (it.next()) |entry| {
        const a = entry.value_ptr.*;
        if (a.id == ROOT_GOAL_ID or a.id == TOP_GOAL_ID) continue;
        const b = right.get(a.id) orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqualStrings(a.description, b.description);
        try std.testing.expectEqual(a.parent_id, b.parent_id);
        try std.testing.expectEqual(a.status, b.status);
        try std.testing.expectEqual(a.priority, b.priority);
        try std.testing.expectEqual(a.deadline, b.deadline);
        try std.testing.expectEqual(a.created_at, b.created_at);
        try std.testing.expectEqual(a.updated_at, b.updated_at);
        try std.testing.expectEqual(a.unrealized_at, b.unrealized_at);
    }
}

fn containsId(ids: []const u64, id: u64) bool {
    for (ids) |v| {
        if (v == id) return true;
    }
    return false;
}

/// The poset every test below snapshots: two top-level goals and one
/// child, one goal carrying a deadline and an `unrealized` mark that a
/// later status change has moved past, one carrying neither. Returns the
/// ids through `out` so a caller can name them.
fn buildTimestampFixture(alloc: Allocator, ids: *std.atomic.Value(u64), out: *[3]u64) !GoalPoset {
    const created: i64 = 1_700_000_000_000;
    const deadline: i64 = 1_700_003_000_000;
    const went_unrealized: i64 = 1_700_000_500_000;
    const revived: i64 = 1_700_000_600_000;

    var goals = GoalPoset.init(alloc);
    errdefer goals.deinit();
    const aged = try goals.create("aged", "has a deadline and a history", null, 5, deadline, created, ids);
    const plain = try goals.create("plain", "carries neither", null, 3, null, created + 1, ids);
    const child = try goals.create("child", "hangs off aged", aged, 2, created + 2, created + 2, ids);
    // Unrealized, then revived: `unrealized_at` (T1) and `updated_at`
    // (T2) now differ, so a reader that conflates the two is caught.
    try goals.updateStatus(aged, .unrealized, went_unrealized);
    try goals.updateStatus(aged, .in_progress, revived);
    out[0] = aged;
    out[1] = plain;
    out[2] = child;
    return goals;
}

test "Snapshot: goal timestamps come back as the exact values that were written" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = goalTestPath(&path_buf, "ts_exact");
    unlinkIfPresent(path);
    defer unlinkIfPresent(path);

    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();
    var fixture: [3]u64 = undefined;
    var goals = try buildTimestampFixture(alloc, &ids, &fixture);
    defer goals.deinit();

    var w = SnapshotWriter.init(alloc, path);
    _ = try w.write(11, &goals, &mgr, &fuzzy);

    var data = try read(alloc, path);
    defer data.deinit();

    // Exact equality, not "non-zero": the restore-time stamp this format
    // change exists to remove was a perfectly non-zero number.
    //
    // Compared as the optional it is, never unwrapped with `.?`: a
    // reader that stopped carrying the timestamps must fail this as an
    // assertion, not as a null-dereference panic that aborts the test
    // binary and takes every later test with it.
    const aged = rowFor(data.goals, fixture[0]).?;
    try std.testing.expectEqual(@as(?i64, 1_700_000_000_000), aged.created_at);
    try std.testing.expectEqual(@as(?i64, 1_700_000_600_000), aged.updated_at);
    try std.testing.expectEqual(@as(?i64, 1_700_003_000_000), aged.deadline);
    try std.testing.expectEqual(@as(?i64, 1_700_000_500_000), aged.unrealized_at);

    const plain = rowFor(data.goals, fixture[1]).?;
    try std.testing.expectEqual(@as(?i64, 1_700_000_000_001), plain.created_at);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000_001), plain.updated_at);
    try std.testing.expectEqual(@as(?i64, null), plain.deadline);
    try std.testing.expectEqual(@as(?i64, null), plain.unrealized_at);

    const child = rowFor(data.goals, fixture[2]).?;
    try std.testing.expectEqual(fixture[0], child.parent_id.?);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000_002), child.created_at);
}

test "Snapshot: a poset rebuilt from the rows equals the one written, field for field" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = goalTestPath(&path_buf, "ts_poset");
    unlinkIfPresent(path);
    defer unlinkIfPresent(path);

    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();
    var fixture: [3]u64 = undefined;
    var goals = try buildTimestampFixture(alloc, &ids, &fixture);
    defer goals.deinit();

    var w = SnapshotWriter.init(alloc, path);
    _ = try w.write(11, &goals, &mgr, &fuzzy);

    var data = try read(alloc, path);
    defer data.deinit();

    var rebuilt = try posetFromRows(alloc, data.goals);
    defer rebuilt.deinit();
    try expectPosetsIdentical(&goals, &rebuilt);

    // The synthetic nodes are rebuilt by `GoalPoset.init`, not restored.
    try std.testing.expect(rebuilt.get(ROOT_GOAL_ID) != null);
    try std.testing.expect(rebuilt.get(TOP_GOAL_ID) != null);
}

test "Snapshot: a goal that ages across a snapshot round trip still goes stale" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = goalTestPath(&path_buf, "ts_stale");
    unlinkIfPresent(path);
    defer unlinkIfPresent(path);

    const now: i64 = 1_700_100_000_000;
    const day: i64 = 86_400_000;

    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();

    var goals = GoalPoset.init(alloc);
    defer goals.deinit();
    const old_id = try goals.create("old", "eight days old, no memcells", null, 5, null, now - 8 * day, &ids);
    const young_id = try goals.create("young", "one day old, no memcells", null, 5, null, now - day, &ids);

    var w = SnapshotWriter.init(alloc, path);
    _ = try w.write(3, &goals, &mgr, &fuzzy);

    var data = try read(alloc, path);
    defer data.deinit();
    var rebuilt = try posetFromRows(alloc, data.goals);
    defer rebuilt.deinit();

    // The rule that silently stopped applying to snapshot-restored
    // goals. `staleGoals` reads `now - created_at`, so a restored goal
    // stamped with the restore time is always 0 ms old and never fires.
    const stale = try rebuilt.staleGoals(alloc, now);
    defer alloc.free(stale);
    try std.testing.expect(containsId(stale, old_id));
    try std.testing.expect(!containsId(stale, young_id));

    // Seven days is the threshold, not "any age at all": one
    // millisecond short of it the same goal is still not stale.
    const early = try rebuilt.staleGoals(alloc, now - 8 * day + 7 * day - 1);
    defer alloc.free(early);
    try std.testing.expect(!containsId(early, old_id));

    // And the pre-snapshot poset agrees, so the round trip did not
    // change the verdict in either direction.
    const stale_before = try goals.staleGoals(alloc, now);
    defer alloc.free(stale_before);
    try std.testing.expectEqual(stale_before.len, stale.len);
    try std.testing.expect(containsId(stale_before, old_id));
}

test "Snapshot: a v1 file from the previous version still loads, with the timestamps marked absent" {
    const alloc = std.testing.allocator;
    // Two buffers, not one: `goalTestPath` formats into the buffer it
    // is handed, so a shared one would have the second path overwrite
    // the first's bytes while both slices stay live.
    var v2_buf: [128]u8 = undefined;
    var v1_buf: [128]u8 = undefined;
    const v2_path = goalTestPath(&v2_buf, "v2src");
    const v1_path = goalTestPath(&v1_buf, "v1gold");
    unlinkIfPresent(v2_path);
    unlinkIfPresent(v1_path);

    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();
    var fixture: [3]u64 = undefined;
    var goals = try buildTimestampFixture(alloc, &ids, &fixture);
    defer goals.deinit();

    // The real writer, at the real version.
    var w = SnapshotWriter.init(alloc, v2_path);
    _ = try w.write(11, &goals, &mgr, &fuzzy);
    var v2_data = try read(alloc, v2_path);
    defer v2_data.deinit();
    const rows = v2_data.goals;

    // The same rows re-encoded in the v1 layout: header, counter, goal
    // count, rows that stop at `priority`, then the (empty) cell
    // sections. This is byte-for-byte what the previous version wrote —
    // the cross-check below proves the prefix is identical rather than
    // merely similar.
    var zb: [platform_fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrint(&zb, "{s}\x00", .{v1_path}) catch return error.SnapshotPathTooLong;
    const zpath = z[0 .. z.len - 1 :0];
    const fd = try platform_fs.open(zpath, .{ .access = .write_only, .create = .truncate });
    var v1w: BufferedWriter = .{ .fd = fd };
    try v1w.writeU32(SNAPSHOT_MAGIC);
    try v1w.writeU32(SNAPSHOT_VERSION_LEGACY);
    try v1w.writeU64(11);
    try v1w.writeU64(rows.len);
    for (rows) |r| {
        try v1w.writeU64(r.id);
        try v1w.writeString(r.name);
        try v1w.writeString(r.description);
        try v1w.writeBool(r.parent_id != null);
        if (r.parent_id) |pid| try v1w.writeU64(pid);
        try v1w.writeU8(@intFromEnum(r.status));
        try v1w.writeU8(r.priority);
    }
    try v1w.writeU64(0); // cells
    try v1w.writeU64(0); // fuzzy cells
    try v1w.flush();
    platform_fs.close(fd);

    // Cross-check, walking both files in lockstep: v2 has to be v1 with
    // a suffix inserted immediately after each row's `priority`, and the
    // suffix has to be exactly the encoding the reader expects. That is
    // the whole backwards-compatibility claim stated as bytes — "an old
    // file still loads" is not a hope about a layout nobody has bytes
    // for, and a writer that inserted the suffix anywhere else (or
    // reordered a field) fails here rather than at some operator's
    // first boot after an upgrade.
    const v2_raw = try readRawFile(alloc, v2_path);
    defer alloc.free(v2_raw);
    const v1_raw = try readRawFile(alloc, v1_path);
    defer alloc.free(v1_raw);

    // The version word is the one byte range that must differ: it is the
    // whole announcement.
    try std.testing.expectEqualSlices(u8, v1_raw[0..4], v2_raw[0..4]); // magic
    try std.testing.expectEqual(
        std.mem.readInt(u32, v1_raw[4..8], .little),
        @as(u32, SNAPSHOT_VERSION_LEGACY),
    );
    try std.testing.expectEqual(
        std.mem.readInt(u32, v2_raw[4..8], .little),
        @as(u32, SNAPSHOT_VERSION),
    );
    // counter and goal count are the same in both.
    try std.testing.expectEqualSlices(u8, v1_raw[8..24], v2_raw[8..24]);

    var v1_cursor: usize = 24;
    var v2_cursor: usize = 24;
    var suffix_total: usize = 0;
    for (rows, 0..) |r, k| {
        const v1_end = v1GoalRowEndOffset(rows, k + 1);
        const row_len = v1_end - v1_cursor;
        try std.testing.expectEqualSlices(
            u8,
            v1_raw[v1_cursor..v1_end],
            v2_raw[v2_cursor .. v2_cursor + row_len],
        );
        v2_cursor += row_len;
        v1_cursor = v1_end;

        const want = try expectedV2GoalSuffix(alloc, r);
        defer alloc.free(want);
        try std.testing.expect(v2_cursor + want.len <= v2_raw.len);
        try std.testing.expectEqualSlices(u8, want, v2_raw[v2_cursor .. v2_cursor + want.len]);
        v2_cursor += want.len;
        suffix_total += want.len;
    }
    // Both files end with the two empty section counts.
    try std.testing.expectEqual(v1_cursor + 16, v1_raw.len);
    try std.testing.expectEqual(v2_cursor + 16, v2_raw.len);
    try std.testing.expectEqual(v1_cursor + suffix_total + 16, v2_raw.len);

    // And the old file loads, with the version it was written at.
    var data = try read(alloc, v1_path);
    defer data.deinit();
    try std.testing.expectEqual(@as(u64, 11), data.counter);
    try std.testing.expectEqual(rows.len, data.goals.len);
    try std.testing.expectEqual(@as(usize, 0), data.cells.len);
    try std.testing.expectEqual(@as(usize, 0), data.fuzzy_cells.len);
    for (rows) |want| {
        const got = rowFor(data.goals, want.id) orelse return error.TestExpectedEqual;
        // Everything v1 carried is intact...
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqualStrings(want.description, got.description);
        try std.testing.expectEqual(want.parent_id, got.parent_id);
        try std.testing.expectEqual(want.status, got.status);
        try std.testing.expectEqual(want.priority, got.priority);
        // ...and everything it did not is marked absent, not zeroed. A
        // `0` here would make the restore path read it as "created in
        // 1970" and mark the goal unrealized on the next tick.
        try std.testing.expectEqual(@as(?i64, null), got.created_at);
        try std.testing.expectEqual(@as(?i64, null), got.updated_at);
        try std.testing.expectEqual(@as(?i64, null), got.deadline);
        try std.testing.expectEqual(@as(?i64, null), got.unrealized_at);
    }
}

test "Snapshot: superseded_by round-trips, and a v2 file (no such field) still loads" {
    const alloc = std.testing.allocator;
    var cur_buf: [128]u8 = undefined;
    var old_buf: [128]u8 = undefined;
    const cur_path = goalTestPath(&cur_buf, "v3cells");
    const old_path = goalTestPath(&old_buf, "v2cells");
    unlinkIfPresent(cur_path);
    unlinkIfPresent(old_path);
    defer unlinkIfPresent(cur_path);
    defer unlinkIfPresent(old_path);

    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();
    var goals = GoalPoset.init(alloc);
    defer goals.deinit();

    const base: MemCell = .{
        .id = 0,
        .source = .matter,
        .episode = "the user lives in Paris",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{.{ .goal_id = 1, .relevance = 0.5, .priority = 1 }},
        .metadata = .{},
    };
    // 1. One current cell: its v3 record ends in a single `false` byte, which
    //    is exactly what a v2 file lacks.
    _ = try mgr.add(base);
    var w = SnapshotWriter.init(alloc, cur_path);
    _ = try w.write(5, &goals, &mgr, &fuzzy);
    const raw = try readRawFile(alloc, cur_path);
    defer alloc.free(raw);
    try std.testing.expectEqual(@as(u32, SNAPSHOT_VERSION), std.mem.readInt(u32, raw[4..8], .little));
    // ... then the 8-byte fuzzy-cell count closes the file.
    const suffix_at = raw.len - 8 - 1;
    try std.testing.expectEqual(@as(u8, 0), raw[suffix_at]);

    var v2 = try alloc.alloc(u8, raw.len - 1);
    defer alloc.free(v2);
    @memcpy(v2[0..suffix_at], raw[0..suffix_at]);
    @memcpy(v2[suffix_at..], raw[suffix_at + 1 ..]);
    std.mem.writeInt(u32, v2[4..8], SNAPSHOT_VERSION_V2, .little);
    {
        var zb: [platform_fs.max_path_bytes + 1]u8 = undefined;
        const z = std.fmt.bufPrint(&zb, "{s}\x00", .{old_path}) catch return error.SnapshotPathTooLong;
        const fd = try platform_fs.open(z[0 .. z.len - 1 :0], .{ .access = .write_only, .create = .truncate });
        var bw: BufferedWriter = .{ .fd = fd };
        for (v2) |b| try bw.writeU8(b);
        try bw.flush();
        platform_fs.close(fd);
    }
    {
        var data = try read(alloc, old_path);
        defer data.deinit();
        try std.testing.expectEqual(@as(usize, 1), data.cells.len);
        try std.testing.expectEqualStrings("the user lives in Paris", data.cells[0].episode);
        try std.testing.expectEqual(@as(?u64, null), data.cells[0].metadata.superseded_by);
        try std.testing.expectEqual(@as(?i64, null), data.cells[0].metadata.superseded_at);
    }

    // 2. A superseded cell keeps both fields through write + read.
    var cell2 = base;
    cell2.episode = "the user moved to Berlin";
    cell2.metadata.superseded_at = 1234;
    cell2.metadata.superseded_by = 99;
    _ = try mgr.add(cell2);
    var w2 = SnapshotWriter.init(alloc, cur_path);
    _ = try w2.write(6, &goals, &mgr, &fuzzy);
    var data = try read(alloc, cur_path);
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 2), data.cells.len);
    var saw = false;
    for (data.cells) |c| {
        if (std.mem.eql(u8, c.episode, "the user moved to Berlin")) {
            saw = true;
            try std.testing.expectEqual(@as(?i64, 1234), c.metadata.superseded_at);
            try std.testing.expectEqual(@as(?u64, 99), c.metadata.superseded_by);
        } else {
            try std.testing.expectEqual(@as(?u64, null), c.metadata.superseded_by);
        }
    }
    try std.testing.expect(saw);
}

test "Snapshot: an unknown version is refused rather than guessed at" {
    const alloc = std.testing.allocator;
    var path_buf: [128]u8 = undefined;
    const path = goalTestPath(&path_buf, "version");
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
    const raw = try readRawFile(alloc, path);
    defer alloc.free(raw);

    // magic(4) | version(4) | ...
    try std.testing.expectEqual(@as(u32, SNAPSHOT_VERSION), std.mem.readInt(u32, raw[4..8], .little));

    // A future version must not be parsed as if it were this one: the
    // goal rows could be any shape at all, and reading them as v2 would
    // mean trusting a length field from a file whose encoding is
    // unknown.
    var patched = try alloc.dupe(u8, raw);
    defer alloc.free(patched);
    std.mem.writeInt(u32, patched[4..8], SNAPSHOT_VERSION + 1, .little);
    try writeRawFile(path, patched);
    try std.testing.expectError(error.SnapshotBadVersion, read(alloc, path));

    // And a version below the oldest supported one, rather than a
    // wraparound comparison that would accept it.
    std.mem.writeInt(u32, patched[4..8], SNAPSHOT_VERSION_LEGACY - 1, .little);
    try writeRawFile(path, patched);
    try std.testing.expectError(error.SnapshotBadVersion, read(alloc, path));
}

test "Snapshot: a v2 goal row truncated at any offset is rejected, never read past" {
    const alloc = std.testing.allocator;
    // Two buffers — see the v1 test for why one shared buffer is wrong.
    var path_buf: [128]u8 = undefined;
    var cut_buf: [128]u8 = undefined;
    const path = goalTestPath(&path_buf, "ts_trunc");
    const cut_path = goalTestPath(&cut_buf, "ts_cut");
    unlinkIfPresent(path);
    unlinkIfPresent(cut_path);
    defer unlinkIfPresent(path);
    defer unlinkIfPresent(cut_path);

    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();
    var fixture: [3]u64 = undefined;
    var goals = try buildTimestampFixture(alloc, &ids, &fixture);
    defer goals.deinit();
    const cell: MemCell = .{
        .id = 0,
        .source = .matter,
        .episode = "episode",
        .atomic_facts = &.{
            .{ .subject = "s", .predicate = "p", .object = "o", .confidence = 1.0, .source = "t" },
        },
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = fixture[1], .relevance = 0.5, .priority = 1 },
        },
        .metadata = .{ .source_confidence = 0.9, .importance_score = 0.7, .decay_rate = 0.01 },
    };
    _ = try mgr.add(cell);

    var w = SnapshotWriter.init(alloc, path);
    _ = try w.write(11, &goals, &mgr, &fuzzy);

    const raw = try readRawFile(alloc, path);
    defer alloc.free(raw);
    // The full file reads, so every failure below is caused by the cut
    // and not by the fixture.
    {
        var ok = try read(alloc, path);
        ok.deinit();
    }

    // Every proper prefix of a file the reader consumes exactly is short
    // of something it needs, so it must error. Sweeping every offset
    // rather than hand-picking boundaries covers the two optional i64s
    // as well: a `has_deadline`/`has_unrealized_at` flag that says
    // "value follows" with the value cut off is the shape that turns a
    // missing bounds check into a read past the buffer.
    const first_row_off: usize = 4 + 4 + 8 + 8;
    try std.testing.expect(first_row_off < raw.len);
    var cut = first_row_off;
    while (cut < raw.len) : (cut += 1) {
        try writeRawFile(cut_path, raw[0..cut]);
        try std.testing.expectError(error.SnapshotTruncated, read(alloc, cut_path));
    }
    // The last byte included is still a cut; the whole file is not.
    try writeRawFile(cut_path, raw);
    {
        var ok = try read(alloc, cut_path);
        ok.deinit();
    }
}
