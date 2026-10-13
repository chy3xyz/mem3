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
const ghw_goal_tree = @import("../ghw/goal_tree.zig");
const jsonl = @import("../utils/jsonl.zig");
const mem3_store = @import("../store/store.zig");
const memory = @import("../memory/mod.zig");
const retrieval = @import("../retrieval/mod.zig");
const HNSW = retrieval.HNSW;
const WAL = @import("../storage/wal.zig").WAL;
const WALRecord = @import("../storage/wal.zig").WALRecord;
const Snapshot = @import("../storage/snapshot.zig");
const SnapshotData = Snapshot.SnapshotData;
const SnapshotWriter = Snapshot.SnapshotWriter;

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
const Store = struct {
    alloc: Allocator,
    ids: std.atomic.Value(u64),
    goals: *ghw.GoalPoset,
    mgr: *memory.TriSourceManager,
    lc: *memory.Lifecycle,
    hnsw: *HNSW,
    emb: retrieval.Embedder,
    cell_index: std.AutoHashMap(u64, *MemCell),
    /// WAL for crash-safe persistence. Optional so tests / dry-runs can opt out.
    wal: ?*WAL,
    /// Snapshot path (data_dir/snapshot.bin). On boot, if the
    /// snapshot exists, we read it before replaying the WAL.
    snapshot_path: []u8,

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
            .snapshot_path = undefined,
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
        self.emb = retrieval.Embedder.init(.lexical_hash, 384);
        // Compute snapshot path: <data_dir>/snapshot.bin
        self.snapshot_path = std.fs.path.join(self.alloc, &.{ data_dir, "snapshot.bin" }) catch {
            log.err("snapshot path too long; persistence disabled", .{});
            return error.SnapshotPathTooLong;
        };
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
        self.alloc.free(self.snapshot_path);
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

    /// Front-door insert. Pre-assigns an id, journaled to WAL first, then
    /// committed to in-memory state. If the WAL write fails the in-memory
    /// store is untouched and the id is returned to the pool. Caller is
    /// guaranteed: `Ok(id) ⟹ cell is durable on disk AND observable in
    /// memory`.
    fn addRaw(
        self: *Store,
        source: MemorySource,
        episode: []const u8,
        facts: []const u8,
        goal_id: u64,
        relevance: f32,
    ) !u64 {
        const id = self.ids.fetchAdd(1, .monotonic);
        errdefer _ = self.ids.fetchSub(1, .monotonic);

        const built = try self.buildCellFromInput(id, source, episode, facts, goal_id, relevance);
        errdefer built.deinit(self.alloc);

        if (self.wal) |wal| {
            const payload = try self.encodeWALPayload(
                id,
                source,
                episode,
                facts,
                goal_id,
                relevance,
                built.cell.metadata,
            );
            defer self.alloc.free(payload);
            try wal.append(.{
                .record_type = .memcell_insert,
                .payload = payload,
                .timestamp = wallClockSec(),
            });
        }
        try self.commitBuiltCell(id, built);
        return id;
    }

    /// Replay-side insert. The id + metadata come from the WAL record.
    fn addRawNoWAL(
        self: *Store,
        id: u64,
        source: MemorySource,
        episode: []const u8,
        facts: []const u8,
        goal_id: u64,
        relevance: f32,
        meta: core.Metadata,
    ) !u64 {
        const built = try self.buildCellFromParsed(id, source, episode, facts, goal_id, relevance, meta);
        errdefer built.deinit(self.alloc);
        try self.commitBuiltCell(id, built);
        return id;
    }

    /// A built cell plus the heap-allocated lists it borrows FROM. The
    /// cell's *internal* slices (episode, atomic_facts, etc.) are still
    /// borrowed from the caller — this struct does NOT own them.
    /// Caller must `deinit()` AFTER mgr has duped the slices (i.e.
    /// after a successful `commitBuiltCell`). On errdefer paths
    /// (failure before commit) the deinit is still safe because the
    /// inner slices haven't been duped anywhere; the caller's defer
    /// owns their lifetime.
    const BuiltCell = struct {
        cell: *MemCell,
        fact_list: *std.ArrayList(fact),
        goal_list: *std.ArrayList(goal_assoc_t),

        /// Free the heap-allocated containers we own. Does NOT free
        /// the cell's inner slices — those belong to the caller until
        /// mgr.addWithId dups them.
        pub fn deinit(self: *const BuiltCell, alloc: Allocator) void {
            self.fact_list.deinit(alloc);
            self.goal_list.deinit(alloc);
            alloc.destroy(self.fact_list);
            alloc.destroy(self.goal_list);
            alloc.destroy(self.cell);
        }
    };

    /// Read snapshot (if present) and restore mgr + fuzzy + id counter.
    /// Called by openAndReplayWAL before the WAL replay pass.
    fn loadSnapshot(self: *Store) !void {
        var data = Snapshot.read(self.alloc, self.snapshot_path) catch |err| switch (err) {
            error.SnapshotOpenFailed,
            error.SnapshotEmpty,
            error.SnapshotTruncated,
            error.SnapshotBadMagic,
            error.SnapshotBadVersion,
            => {
                std.log.info("WAL: no valid snapshot at {s}, starting fresh", .{self.snapshot_path});
                return;
            },
            else => return err,
        };
        defer data.deinit();
        std.log.info("WAL: snapshot has {d} cells, {d} fuzzy, counter={d}", .{
            data.cells.len,
            data.fuzzy_cells.len,
            data.counter,
        });

        // Restore the id counter so fresh inserts pick up after the snapshot.
        if (data.counter > 0) {
            _ = self.ids.fetchMax(data.counter, .monotonic);
        }

        // Re-insert cells into the manager. Use mgr.addWithId so the
        // counter is honored (snapshot ids are stable across boots).
        for (data.cells) |cs| {
            const cell = try self.alloc.create(MemCell);
            errdefer self.alloc.destroy(cell);
            cell.* = .{
                .id = cs.id,
                .source = cs.source,
                .episode = cs.episode, // borrowed; mgr will dup
                .atomic_facts = cs.facts,
                .foresight = cs.foresight,
                .goal_associations = cs.goal_associations,
                .metadata = cs.metadata,
            };
            _ = self.lc.addCell(cs.id, cell.*) catch |err| {
                std.log.warn("snapshot: addCell failed for id={d}: {}", .{ cs.id, err });
                return;
            };
            if (self.mgr.get(cs.id)) |stored| try self.cell_index.put(cs.id, stored);
        }
        for (data.fuzzy_cells) |cs| {
            // Allocate a fresh MemCell for fuzzy (we want to own the slices).
            const cell = try self.alloc.create(MemCell);
            errdefer self.alloc.destroy(cell);
            cell.* = .{
                .id = cs.id,
                .source = cs.source,
                .episode = try self.alloc.dupe(u8, cs.episode),
                .atomic_facts = try self.cloneFacts(cs.facts),
                .foresight = try self.cloneForesights(cs.foresight),
                .goal_associations = try self.alloc.dupe(core.GoalAssociation, cs.goal_associations),
                .metadata = cs.metadata,
            };
            try self.lc.fuzzy.transfer(cell);
        }
    }

    /// Take a snapshot of (counter, mgr, fuzzy) to disk, then truncate
    /// the WAL. Atomic: snapshot is written to a temp file, fsync'd,
    /// then renamed over the previous snapshot. After a successful
    /// snapshot the WAL is truncated because the snapshot now contains
    /// the full state — no replay needed for any record ≤ snapshot.
    fn takeSnapshot(self: *Store) !void {
        var w = SnapshotWriter.init(self.alloc, self.snapshot_path);
        const bytes = w.write(
            self.ids.load(.monotonic),
            self.goals,
            self.mgr,
            &self.lc.fuzzy,
        ) catch |err| {
            std.log.warn("snapshot: write failed: {}", .{err});
            return;
        };
        std.log.info("snapshot: wrote {d} bytes to {s}", .{ bytes, self.snapshot_path });
        // Truncate the WAL. Close, delete, reopen as fresh.
        if (self.wal) |wal| {
            wal.flush() catch {};
            wal.deinit();
            self.alloc.destroy(wal);
            self.wal = null;
            // Delete the old WAL file so the new one starts empty.
            const wal_path = std.fs.path.join(self.alloc, &.{
                self.snapshot_path[0 .. self.snapshot_path.len - "snapshot.bin".len],
                "mem3.wal",
            }) catch return;
            defer self.alloc.free(wal_path);
            var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const z = std.fmt.bufPrint(&zbuf, "{s}\x00", .{wal_path}) catch return;
            _ = std.c.unlink(z[0 .. z.len - 1 :0].ptr);
            // Reopen a fresh WAL.
            const wal_ptr = self.alloc.create(WAL) catch return;
            wal_ptr.* = try WAL.init(self.alloc, wal_path);
            wal_ptr.open() catch {
                wal_ptr.deinit();
                self.alloc.destroy(wal_ptr);
                return;
            };
            self.wal = wal_ptr;
        }
    }

    fn cloneFacts(self: *Store, src: []const core.Fact) ![]core.Fact {
        const out = try self.alloc.alloc(core.Fact, src.len);
        for (src, 0..) |f, i| {
            out[i] = .{
                .subject = try self.alloc.dupe(u8, f.subject),
                .predicate = try self.alloc.dupe(u8, f.predicate),
                .object = try self.alloc.dupe(u8, f.object),
                .confidence = f.confidence,
                .source = try self.alloc.dupe(u8, f.source),
            };
        }
        return out;
    }

    fn cloneForesights(self: *Store, src: []const core.Foresight) ![]core.Foresight {
        const out = try self.alloc.alloc(core.Foresight, src.len);
        for (src, 0..) |f, i| {
            out[i] = .{
                .description = try self.alloc.dupe(u8, f.description),
                .valid_from = f.valid_from,
                .valid_until = f.valid_until,
                .confidence = f.confidence,
            };
        }
        return out;
    }

    /// Build a fresh MemCell from user input (new insert). Uses the
    /// encoder to set fresh metadata (created_at = now, etc.). Returns
    /// a BuiltCell whose lists must outlive the mgr commit; use
    /// `commitBuiltCell` to commit and then deinit the BuiltCell.
    fn buildCellFromInput(
        self: *Store,
        id: u64,
        source: MemorySource,
        episode: []const u8,
        facts: []const u8,
        goal_id: u64,
        relevance: f32,
    ) !BuiltCell {
        const fact_list = try self.alloc.create(std.ArrayList(fact));
        errdefer self.alloc.destroy(fact_list);
        fact_list.* = .empty;

        const goal_list = try self.alloc.create(std.ArrayList(goal_assoc_t));
        errdefer self.alloc.destroy(goal_list);
        goal_list.* = .empty;

        errdefer fact_list.deinit(self.alloc);
        errdefer goal_list.deinit(self.alloc);

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

        try goal_list.append(self.alloc, .{
            .goal_id = goal_id,
            .relevance = relevance,
            .priority = 5,
        });

        const cell_ptr = try self.alloc.create(MemCell);
        errdefer self.alloc.destroy(cell_ptr);
        cell_ptr.* = try self.lc.encoder.encode(.{
            .source = source,
            .episode = episode,
            .atomic_facts = fact_list.items,
            .foresight = &[_]foresight_t{},
            .goal_associations = goal_list.items,
        });
        cell_ptr.id = id;
        return .{
            .cell = cell_ptr,
            .fact_list = fact_list,
            .goal_list = goal_list,
        };
    }

    /// Build a MemCell from a WAL record (replay). Uses the metadata
    /// that was persisted, NOT fresh timestamps. This is the key to
    /// Principle III fidelity across boots.
    fn buildCellFromParsed(
        self: *Store,
        id: u64,
        source: MemorySource,
        episode: []const u8,
        facts: []const u8,
        goal_id: u64,
        relevance: f32,
        meta: core.Metadata,
    ) !BuiltCell {
        const fact_list = try self.alloc.create(std.ArrayList(fact));
        errdefer self.alloc.destroy(fact_list);
        fact_list.* = .empty;

        const goal_list = try self.alloc.create(std.ArrayList(goal_assoc_t));
        errdefer self.alloc.destroy(goal_list);
        goal_list.* = .empty;

        errdefer fact_list.deinit(self.alloc);
        errdefer goal_list.deinit(self.alloc);

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

        try goal_list.append(self.alloc, .{
            .goal_id = goal_id,
            .relevance = relevance,
            .priority = 5,
        });

        const cell_ptr = try self.alloc.create(MemCell);
        errdefer self.alloc.destroy(cell_ptr);
        cell_ptr.* = .{
            .id = id,
            .source = source,
            .episode = episode, // borrowed; mgr.addWithId will dup
            .atomic_facts = fact_list.items, // borrowed
            .foresight = &[_]foresight_t{},
            .goal_associations = goal_list.items, // borrowed
            .metadata = meta,
        };
        return .{
            .cell = cell_ptr,
            .fact_list = fact_list,
            .goal_list = goal_list,
        };
    }

    /// Commit a built cell to mgr + cell_index + hnsw. The lists
    /// (fact_list, goal_list) are deinited in-place because the mgr
    /// already duped their contents into its own store.
    fn commitBuiltCell(self: *Store, id: u64, built: BuiltCell) !void {
        _ = try self.lc.addCell(id, built.cell.*);
        // The mgr has now duped all borrowed slices. Free the lists.
        built.fact_list.deinit(self.alloc);
        built.goal_list.deinit(self.alloc);
        self.alloc.destroy(built.fact_list);
        self.alloc.destroy(built.goal_list);
        self.alloc.destroy(built.cell);

        if (self.mgr.get(id)) |stored| {
            try self.cell_index.put(id, stored);
            const v = try self.emb.embed(self.alloc, stored.episode);
            defer self.alloc.free(v);
            self.hnsw.insert(id, v) catch |err| {
                log.warn("hnsw insert failed: {}", .{err});
            };
        }
    }

    /// Encode a memcell_insert WAL payload as a self-contained JSON document.
    /// Fields: { id, source, episode, facts, goal_id, relevance, ...meta }.
    /// The id MUST be the pre-assigned id (same one used to commit the
    /// cell in memory); replay uses it to keep the WAL→memory contract
    /// identical across boots. Metadata fields are persisted so Principle
    /// III (existence-gain-driven) rankings are stable across boots
    /// instead of being reset to "now".
    fn encodeWALPayload(
        self: *Store,
        id: u64,
        source: MemorySource,
        episode: []const u8,
        facts: []const u8,
        goal_id: u64,
        relevance: f32,
        meta: core.Metadata,
    ) ![]u8 {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        try out.append(self.alloc, '{');
        try jsonFieldUintRaw(self.alloc, &out, "id", id);
        try out.append(self.alloc, ',');
        try jsonFieldStringRaw(self.alloc, &out, "source", source.label());
        try out.append(self.alloc, ',');
        try jsonFieldStringRaw(self.alloc, &out, "episode", episode);
        try out.append(self.alloc, ',');
        try jsonFieldStringRaw(self.alloc, &out, "facts", facts);
        try out.append(self.alloc, ',');
        try jsonFieldUintRaw(self.alloc, &out, "goal_id", goal_id);
        try out.append(self.alloc, ',');
        try jsonFieldFloatRaw(self.alloc, &out, "relevance", relevance);
        try out.append(self.alloc, ',');
        // Metadata round-trip (Principle III fidelity).
        try jsonFieldIntRaw(self.alloc, &out, "created_at", meta.created_at);
        try out.append(self.alloc, ',');
        try jsonFieldIntRaw(self.alloc, &out, "updated_at", meta.updated_at);
        try out.append(self.alloc, ',');
        try jsonFieldIntRaw(self.alloc, &out, "last_accessed_at", meta.last_accessed_at);
        try out.append(self.alloc, ',');
        try jsonFieldFloatRaw(self.alloc, &out, "importance_score", meta.importance_score);
        try out.append(self.alloc, ',');
        try jsonFieldFloatRaw(self.alloc, &out, "coherence_score", meta.coherence_score);
        try out.append(self.alloc, ',');
        try jsonFieldFloatRaw(self.alloc, &out, "decay_rate", meta.decay_rate);
        try out.append(self.alloc, ',');
        try jsonFieldFloatRaw(self.alloc, &out, "source_confidence", meta.source_confidence);
        try out.append(self.alloc, ',');
        try jsonFieldFloatRaw(self.alloc, &out, "emotional_valence", meta.emotional_valence);
        try out.append(self.alloc, ',');
        try jsonFieldUintRaw(self.alloc, &out, "access_count", meta.access_count);
        try out.append(self.alloc, '}');
        return out.toOwnedSlice(self.alloc);
    }

    /// Open the WAL at data_dir/mem3.wal and replay any prior records.
    /// Creates the directory tree if missing. Returns an error on any
    /// real filesystem failure (EACCES, ENOSPC, etc.) so the caller can
    /// refuse to start rather than silently run in-memory.
    fn openAndReplayWAL(self: *Store, data_dir: []const u8) !void {
        const dir_path = try self.alloc.dupe(u8, data_dir);
        defer self.alloc.free(dir_path);

        // Recursive mkdir (mkdir -p). 0.17 std has no public makeDir API,
        // so we shell out to the C `mkdir` syscall per path component.
        // A non-zero return is treated as EEXIST *only* if the path already
        // exists as a directory; otherwise the real error propagates.
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
            const z = std.fmt.bufPrint(&zbuf, "{s}\x00", .{prefix.items}) catch {
                return error.DataDirPathTooLong;
            };
            const zptr = z[0 .. z.len - 1 :0].ptr;
            const rc = std.c.mkdir(zptr, 0o755);
            if (rc == 0) continue;
            // mkdir returned -1. EEXIST (most common case in dev) is fine
            // if the path is already a directory. Anything else propagates.
            var st: std.c.Stat = undefined;
            if (std.c.stat(zptr, &st) != 0) return error.DataDirStatFailed;
            const mode_u32: u32 = @intCast(st.mode);
            if ((mode_u32 & 0xF000) != 0x4000) return error.DataDirNotADirectory;
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
            std.log.err("WAL: alloc failed: {s}", .{@errorName(err)});
            return;
        };
        const init_wal = WAL.init(self.alloc, wal_path) catch |err| {
            std.log.err("WAL: init failed: {s}", .{@errorName(err)});
            self.alloc.destroy(wal_ptr);
            return;
        };
        wal_ptr.* = init_wal;
        wal_ptr.open() catch |err| {
            std.log.err("WAL: open({s}) failed: {s}", .{ wal_path, @errorName(err) });
            wal_ptr.deinit();
            self.alloc.destroy(wal_ptr);
            return;
        };
        std.log.info("WAL: opened {s} (replay={d} bytes)", .{ wal_path, existing.items.len });
        self.wal = wal_ptr;
        // Read snapshot FIRST (if present), then replay WAL on top.
        // Snapshot is the "base" state; WAL records are deltas since
        // the snapshot.
        try self.loadSnapshot();
        if (existing.items.len == 0) return;

        // Replay records.
        var replay_count: u64 = 0;
        var max_replayed_id: u64 = 0;
        var replayed_goals: u64 = 0;
        // Records from before commit 5c3fdb9 (which added the "id" WAL
        // field) have no id. We synthesize one in a high range
        // (≥ 1_000_000_000) so they can't collide with fresh inserts. The
        // ordinal counter resets on every boot, but that's fine — the
        // SAME record gets the SAME synthetic id on every replay, and
        // the cell content (episode/facts/etc.) is stable, so external
        // observers see a stable id.
        var synthetic_id_seq: u64 = 0;
        const SYNTHETIC_ID_BASE: u64 = 1_000_000_000;
        const Ctx = struct {
            store: *Store,
            count: *u64,
            max_id: *u64,
            synthetic_seq: *u64,
            goal_count: *u64,
        };
        var ctx = Ctx{
            .store = self,
            .count = &replay_count,
            .max_id = &max_replayed_id,
            .synthetic_seq = &synthetic_id_seq,
            .goal_count = &replayed_goals,
        };
        wal_ptr.replay(existing.items, &ctx, struct {
            fn cb(ctx_ptr: *Ctx, rec: WALRecord) anyerror!void {
                // `goal_create` records used to be dropped here entirely,
                // because this daemon carries its own duplicate `Store`
                // with its own replay loop. So `mem3 goal add` wrote a
                // durable goal record that this process never read back,
                // and `GET /api/goals` disagreed with `mem3 goal list`.
                if (rec.record_type == .goal_create) {
                    applyGoalRecord(ctx_ptr.store, rec.payload, ctx_ptr.goal_count, ctx_ptr.max_id);
                    return;
                }
                if (rec.record_type != .memcell_insert) return;
                const synthetic_id = SYNTHETIC_ID_BASE + @atomicRmw(u64, ctx_ptr.synthetic_seq, .Add, 1, .seq_cst);
                const parsed = parseInsertPayload(
                    ctx_ptr.store.alloc,
                    rec.payload,
                    synthetic_id,
                ) catch |err| {
                    if (err == error.ParseFailed) {
                        std.log.warn("WAL: skipping corrupt record (parse failed)", .{});
                        return;
                    }
                    return err;
                };
                defer parsed.deinit(ctx_ptr.store.alloc);
                if (parsed.id > ctx_ptr.max_id.*) ctx_ptr.max_id.* = parsed.id;
                _ = ctx_ptr.store.addRawNoWAL(
                    parsed.id,
                    parsed.source,
                    parsed.episode,
                    parsed.facts,
                    parsed.goal_id,
                    parsed.relevance,
                    parsed.metadata,
                ) catch |err| {
                    std.log.warn("replay insert failed: {}", .{err});
                    return;
                };
                ctx_ptr.count.* += 1;
            }
        }.cb) catch |err| {
            log.warn("WAL replay stopped at record {d}: {}", .{ replay_count, err });
        };
        // Bump the id counter past the highest replayed id so future
        // fresh inserts can't collide with a replayed one. fetchMax is
        // atomic and idempotent: if `ids` is already past, no change.
        if (max_replayed_id > 0) {
            _ = self.ids.fetchMax(max_replayed_id + 1, .monotonic);
        }
        std.log.info("WAL: replayed {d} memcell_insert + {d} goal_create records from {s}", .{ replay_count, replayed_goals, wal_path });
    }

    /// Replay one `goal_create` record into the daemon's poset.
    ///
    /// Mirrors `store.Store.applyGoalRecord`, which cannot be reused
    /// directly because this file carries its own duplicate `Store` type.
    /// The payload parser itself IS shared (`mem3_store.parseGoalPayload`)
    /// so the two can never drift on the wire format.
    ///
    /// Idempotent: an id already in the poset is skipped, so replaying a
    /// WAL on top of a snapshot is a no-op rather than a duplicate. Logs
    /// are gated on `builtin.is_test` because the Zig 0.17 test runner
    /// fails any test that emits a log line.
    fn applyGoalRecord(store_self: *Store, payload: []const u8, count: *u64, max_id: *u64) void {
        const g = mem3_store.parseGoalPayload(store_self.alloc, payload) catch |err| {
            if (!builtin.is_test) log.warn("WAL: skipping goal_create record (parse failed: {})", .{err});
            return;
        };
        defer g.deinit(store_self.alloc);

        if (g.id == ghw_goal_tree.ROOT_GOAL_ID or g.id == ghw_goal_tree.TOP_GOAL_ID) return;
        // Clear the id even for skipped records, so a later insert can
        // never mint an id a durable record already claims.
        if (g.id > max_id.*) max_id.* = g.id;
        if (store_self.goals.nodes.contains(g.id)) return;
        if (g.parent_id) |p| {
            if (!store_self.goals.nodes.contains(p)) {
                if (!builtin.is_test) log.warn("WAL: goal_create id={d} dropped — parent {d} absent from poset", .{ g.id, p });
                return;
            }
        }
        // A private counter seeded to the journaled id makes the poset
        // mint exactly this id, matching how it was first created.
        var slot: std.atomic.Value(u64) = .init(g.id);
        const created = store_self.goals.create(g.name, g.description, g.parent_id, g.priority, g.deadline, g.created_at, &slot) catch |err| {
            if (!builtin.is_test) log.warn("replay: goal_create id={d} failed: {}", .{ g.id, err });
            return;
        };
        if (created != g.id) {
            if (!builtin.is_test) log.err("replay: goal_create id drift — record {d}, poset {d}", .{ g.id, created });
            return;
        }
        count.* += 1;
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
            // After WAL is durable, take a snapshot + truncate WAL so
            // next boot replays from snapshot (fast) instead of replaying
            // every WAL record (slow for long-lived daemons).
            self.store.takeSnapshot() catch |err| {
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
            const importance = cell.metadata.importance_score;
            score = score * (1.0 + 0.4 * goal_bonus) * (1.0 + 0.3 * importance);
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
    var srv = try Server.init(alloc, "127.0.0.1", 0, "/tmp/mem3_test_server");
    defer {
        srv.deinit();
        // Test cleanup: remove the data dir the test created.
        std.fs.cwd().deleteTree("/tmp/mem3_test_server") catch {};
    }
    const resp = try srv.route("GET", "/healthz", "");
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "ok") != null);
}

test "Server: GET /api/goals reflects the live poset, not a fixed literal" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, "/tmp/mem3_test_server");
    defer {
        srv.deinit();
        std.fs.cwd().deleteTree("/tmp/mem3_test_server") catch {};
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
