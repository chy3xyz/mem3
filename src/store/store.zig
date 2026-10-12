//! Shared in-process store: the central MemCell + Goals + HyMem + WAL/Snapshot
//! container used by both the HTTP server and the CLI.
//!
//! ## Why a shared module
//!
//! Pre-extraction, the HTTP server (`src/server/http_server.zig`) and CLI
//! commands (`src/cli_commands/*.zig`) each constructed their own ad-hoc
//! store. This led to:
//!
//!   - 60% of CLI commands being unimplemented stubs (the data plumbing
//!     they needed was buried inside the HTTP server's `Store` struct).
//!   - WAL/snapshot lifecycle only exercised by the HTTP server — CLI
//!     `dump`, `inspect`, `forget`, `consolidate`, `goal`, `hyperedge`
//!     could not read or write to the on-disk store.
//!
//! The fix is to lift the store out of the server and make it a first-
//! class module. Both the server and every CLI command build a `*Store`
//! via the same factory, so persistence semantics are consistent
//! everywhere.
//!
//! ## Build options
//!
//! `BuildOptions` controls which optional subsystems get initialized:
//!
//!   - `data_dir`: persistence directory. `null` disables WAL/snapshot
//!     entirely (pure in-memory). This is the right choice for short-
//!     lived CLI commands that don't need durability (`add`, `query`,
//!     `inspect`).
//!   - `seed_default_goals`: when true, creates the standard
//!     (general / research / system) goals on init. Matches what
//!     `mem3 serve` historically did. CLI commands that manage goals
//!     themselves should pass `false`.
//!   - `embed_dim`: dimension of the StubEmbedder used by the HNSW
//!     index. 384 is the default (same as the server).
//!
//! ## Thread safety
//!
//! `Store` is single-writer / multi-reader safe, like the components it
//! composes. The HTTP server uses one Store per process; each CLI
//! invocation owns a single Store.
//!
//! ## Constitution compliance
//!
//! - Principle IV (零依赖): pure Zig, no new external deps.
//! - Principle V (零拷贝 + comptime): no reflection, explicit fields.
//! - Principle VII (observability): `deinit` is idempotent — safe to
//!   call multiple times if a caller forgets (logger emits a warning).

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = std.c;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const MemorySource = core.MemorySource;
const Fact = core.Fact;
const Foresight = core.Foresight;
const GoalAssociation = core.GoalAssociation;
const Config = core.Config;
const ghw = @import("../ghw/mod.zig");
const ghw_goal_tree = @import("../ghw/goal_tree.zig");
const memory = @import("../memory/mod.zig");
const retrieval = @import("../retrieval/mod.zig");
const HNSW = retrieval.HNSW;
const StubEmbedder = retrieval.StubEmbedder;
const WAL = @import("../storage/wal.zig").WAL;
const WALRecord = @import("../storage/wal.zig").WALRecord;
const Snapshot = @import("../storage/snapshot.zig");
const SnapshotData = Snapshot.SnapshotData;
const SnapshotWriter = Snapshot.SnapshotWriter;
const HyMem = @import("../hypermem/mod.zig").HyMem;
const HyperEdge = @import("../hypermem/mod.zig").HyperEdge;

const log = std.log.scoped(.mem3_store);

/// Build-time options for `Store.init`. See module doc for semantics.
pub const BuildOptions = struct {
    /// Persistence directory (e.g. "data"). `null` → in-memory only,
    /// no WAL, no snapshot. Default: `"data"`.
    data_dir: ?[]const u8 = "data",
    /// Seed the standard (general/research/system) goals at init. Set
    /// to `false` for CLI commands that manage goals themselves
    /// (e.g. `mem3 goal`). Default: `true`.
    seed_default_goals: bool = true,
    /// Embedder vector dimension. Default: 384.
    embed_dim: u16 = 384,
};

/// In-process memory store. Composes TriSourceManager + GoalPoset +
/// HyMem + HNSW + (optional) WAL + (optional) snapshot. The HTTP
/// server and every CLI command build one of these via `init` and
/// call `deinit` when done.
pub const Store = struct {
    alloc: Allocator,
    /// Single shared monotonic id source. Allocates ids for MemCells,
    /// goals, hyperedges, harnesses, and scenes.
    ids: std.atomic.Value(u64),
    /// Goal Poset — owned pointer so it can be passed by ref to APIs
    /// that take `*GoalPoset`.
    goals: *ghw.GoalPoset,
    /// Tri-Source Memory Manager.
    mgr: *memory.TriSourceManager,
    /// Lifecycle orchestrator. Wraps encoder + forgetter + consolidator.
    lc: *memory.Lifecycle,
    /// Hypergraph memory engine (HyMem).
    hymem: HyMem,
    /// HNSW vector index over episode embeddings.
    hnsw: *HNSW,
    /// Stub embedder (deterministic xxhash3-based).
    emb: StubEmbedder,
    /// id → cell pointer. The fast path for `getCell`.
    cell_index: std.AutoHashMap(u64, *MemCell),
    /// WAL for crash-safe persistence. `null` when built with
    /// `data_dir == null` (in-memory mode).
    wal: ?*WAL,
    /// `<data_dir>/snapshot.bin`. Borrowed. Empty string when in-memory.
    snapshot_path: []u8,
    /// `<data_dir>/mem3.wal`. Borrowed. Empty string when in-memory.
    wal_path: []u8,
    /// Set to true after `deinit` — guards double-free.
    deinit_called: bool = false,

    /// Build a Store. When `opts.data_dir` is non-null and the
    /// directory exists (or can be created), the Store is durable:
    /// snapshots on `sync()`, WAL on every insert. When `null`, the
    /// Store is pure in-memory.
    pub fn init(alloc: Allocator, opts: BuildOptions) !*Store {
        const self = try alloc.create(Store);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .ids = .init(1),
            .goals = undefined,
            .mgr = undefined,
            .lc = undefined,
            .hymem = undefined,
            .hnsw = undefined,
            .emb = undefined,
            .cell_index = std.AutoHashMap(u64, *MemCell).init(alloc),
            .wal = null,
            .snapshot_path = try alloc.dupe(u8, ""),
            .wal_path = try alloc.dupe(u8, ""),
        };
        errdefer alloc.free(self.snapshot_path);
        errdefer alloc.free(self.wal_path);

        // Goals
        const goals_ptr = try alloc.create(ghw.GoalPoset);
        errdefer alloc.destroy(goals_ptr);
        goals_ptr.* = ghw.GoalPoset.init(alloc);
        self.goals = goals_ptr;

        if (opts.seed_default_goals) {
            _ = try goals_ptr.create("general", "catch-all", null, 5, null, 0, &self.ids);
            _ = try goals_ptr.create("research", "research-related", null, 7, null, 0, &self.ids);
            _ = try goals_ptr.create("system", "system / meta", null, 6, null, 0, &self.ids);
        }

        // TriSourceManager
        const mgr_ptr = try alloc.create(memory.TriSourceManager);
        errdefer alloc.destroy(mgr_ptr);
        mgr_ptr.* = memory.TriSourceManager.init(alloc, &self.ids);
        self.mgr = mgr_ptr;

        // Lifecycle
        const lc_ptr = try alloc.create(memory.Lifecycle);
        errdefer alloc.destroy(lc_ptr);
        lc_ptr.* = memory.Lifecycle.init(alloc, .{}, mgr_ptr);
        lc_ptr.wire();
        self.lc = lc_ptr;

        // HyMem (uses the same id source — hyperedges are id-allocated
        // from the same monotonic counter, but live in their own space)
        self.hymem = HyMem.init(alloc, &self.ids);

        // HNSW + embedder
        const hnsw_ptr = try alloc.create(HNSW);
        errdefer alloc.destroy(hnsw_ptr);
        hnsw_ptr.* = HNSW.init(alloc, .{}, opts.embed_dim);
        self.hnsw = hnsw_ptr;
        self.emb = StubEmbedder.init(opts.embed_dim);

        // Persistence (optional)
        if (opts.data_dir) |dir| {
            try self.openAndReplayPersistence(dir);
        }
        return self;
    }

    /// Release all resources. Idempotent: safe to call more than once.
    pub fn deinit(self: *Store) void {
        if (self.deinit_called) return;
        self.deinit_called = true;

        if (self.wal) |w| {
            w.flush() catch {};
            w.deinit();
            self.alloc.destroy(w);
            self.wal = null;
        }
        if (self.snapshot_path.len > 0) self.alloc.free(self.snapshot_path);
        if (self.wal_path.len > 0) self.alloc.free(self.wal_path);
        self.snapshot_path = @constCast("");
        self.wal_path = @constCast("");

        self.cell_index.deinit();
        self.hnsw.deinit();
        self.alloc.destroy(self.hnsw);
        self.lc.fuzzy.deinit();
        self.alloc.destroy(self.lc);
        self.hymem.deinit();
        self.mgr.deinit();
        self.alloc.destroy(self.mgr);
        self.goals.deinit();
        self.alloc.destroy(self.goals);
        self.alloc.destroy(self);
    }

    // =================================================================
    // High-level operations
    // =================================================================

    /// Insert a fresh MemCell. Allocates a new id, journals to WAL (if
    /// enabled), commits to in-memory state. On any failure the id is
    /// returned to the pool and no side effect persists.
    pub fn addRaw(
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
        built.deinit(self.alloc);
        return id;
    }

    /// Look up a cell by id. Returns null if not found.
    pub fn getCell(self: *Store, id: u64) ?*MemCell {
        return self.cell_index.get(id);
    }

    /// Total cells currently in the active store (excludes fuzzy).
    pub fn cellCount(self: *Store) usize {
        return self.mgr.count();
    }

    /// Cells per source: matter / form / spirit.
    pub fn cellCountBySource(self: *Store, source: MemorySource) usize {
        return self.mgr.countBySource(source);
    }

    /// Snapshot of every cell in the active store. Caller owns the
    /// returned slice and must free it.
    pub fn allCells(self: *Store, alloc: Allocator) ![]*MemCell {
        var out = std.ArrayList(*MemCell).empty;
        errdefer out.deinit(alloc);
        var it = self.cell_index.iterator();
        while (it.next()) |entry| try out.append(alloc, entry.value_ptr.*);
        return out.toOwnedSlice(alloc);
    }

    /// Run the existence-gain-driven forgetting sweep. Pass
    /// `dry_run=true` to count without transferring cells to the
    /// fuzzy store.
    pub fn forget(self: *Store, dry_run: bool) !memory.Forgetter.SweepResult {
        return self.lc.forget(dry_run);
    }

    /// Run HAC consolidation. Returns the number of abstract cells
    /// created (0 if the corpus is too small to cluster).
    pub fn consolidate(self: *Store) !usize {
        return self.lc.consolidate();
    }

    /// Take a snapshot + truncate the WAL. No-op when WAL is disabled.
    pub fn sync(self: *Store) !void {
        if (self.wal == null) return;
        try self.takeSnapshot();
    }

    /// True if this store is WAL-backed (data_dir was non-null at init).
    pub fn isDurable(self: *const Store) bool {
        return self.wal != null;
    }

    // =================================================================
    // Goal Poset ops (CLI `goal` subcommand)
    // =================================================================

    pub const GoalInfo = struct {
        id: u64,
        name: []const u8,
        description: []const u8,
        status: core.GoalStatus,
        priority: u8,
        parent_id: ?u64,
        memcell_count: usize,
        is_synthetic: bool,
    };

    /// Create a new goal. Returns the assigned id.
    pub fn createGoal(
        self: *Store,
        name: []const u8,
        description: []const u8,
        parent_id: ?u64,
        priority: u8,
        deadline: ?i64,
        now_ms: i64,
    ) !u64 {
        return self.goals.create(name, description, parent_id, priority, deadline, now_ms, &self.ids);
    }

    /// All non-synthetic goals.
    pub fn listGoals(self: *Store, alloc: Allocator) ![]GoalInfo {
        var out = std.ArrayList(GoalInfo).empty;
        errdefer out.deinit(alloc);
        var it = self.goals.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.id == ghw_goal_tree.ROOT_GOAL_ID or node.id == ghw_goal_tree.TOP_GOAL_ID) continue;
            const mc_count = self.goals.memcellsFor(node.id).len;
            try out.append(alloc, .{
                .id = node.id,
                .name = node.name,
                .description = node.description,
                .status = node.status,
                .priority = node.priority,
                .parent_id = node.parent_id,
                .memcell_count = mc_count,
                .is_synthetic = false,
            });
        }
        return out.toOwnedSlice(alloc);
    }

    /// Update a goal's status.
    pub fn updateGoalStatus(self: *Store, id: u64, status: core.GoalStatus, now_ms: i64) !void {
        try self.goals.updateStatus(id, status, now_ms);
    }

    // =================================================================
    // HyMem ops (CLI `hyperedge` subcommand)
    // =================================================================

    /// Add a hyperedge connecting 2+ existing MemCells.
    pub fn addHyperedge(self: *Store, edge: HyperEdge) !u64 {
        return self.hymem.addEdge(edge);
    }

    /// Snapshot of every hyperedge (caller frees).
    pub fn allHyperedges(self: *Store, alloc: Allocator) ![]*HyperEdge {
        var out = std.ArrayList(*HyperEdge).empty;
        errdefer out.deinit(alloc);
        var it = self.hymem.edges.iterator();
        while (it.next()) |entry| try out.append(alloc, entry.value_ptr.*);
        return out.toOwnedSlice(alloc);
    }

    pub fn hyperedgeCount(self: *const Store) usize {
        return self.hymem.count();
    }

    /// Multi-hop traversal from seed nodes.
    pub fn multiHop(
        self: *Store,
        alloc: Allocator,
        seed_ids: []const u64,
        max_hops: u8,
        confidence_threshold: f32,
        edge_types_filter: ?[]const core.EdgeType,
    ) ![]u64 {
        return self.hymem.multiHop(alloc, seed_ids, max_hops, confidence_threshold, edge_types_filter);
    }

    // =================================================================
    // Internals
    // =================================================================

    /// A built cell plus the heap-allocated lists it borrows FROM. The
    /// cell's internal slices (episode, atomic_facts, etc.) are still
    /// borrowed from the caller — this struct does NOT own them.
    /// Caller must `deinit()` AFTER mgr has duped the slices (i.e.
    /// after a successful `commitBuiltCell`).
    const BuiltCell = struct {
        cell: *MemCell,
        fact_list: *std.ArrayList(Fact),
        goal_list: *std.ArrayList(GoalAssociation),

        pub fn deinit(self: *const BuiltCell, alloc: Allocator) void {
            // We treat `self.fact_list` etc. as owned heap allocations
            // (they were created via `alloc.create` in `buildCellFromX`)
            // and free them here. Both `alloc.destroy` and ArrayList
            // .deinit accept const inputs in Zig 0.17.
            const fl = @constCast(self.fact_list);
            fl.deinit(alloc);
            alloc.destroy(fl);
            const gl = @constCast(self.goal_list);
            gl.deinit(alloc);
            alloc.destroy(gl);
            alloc.destroy(@constCast(self.cell));
        }
    };

    fn buildCellFromInput(
        self: *Store,
        id: u64,
        source: MemorySource,
        episode: []const u8,
        facts: []const u8,
        goal_id: u64,
        relevance: f32,
    ) !BuiltCell {
        const fact_list = try self.alloc.create(std.ArrayList(Fact));
        errdefer self.alloc.destroy(fact_list);
        fact_list.* = .empty;

        const goal_list = try self.alloc.create(std.ArrayList(GoalAssociation));
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
                .source = "cli",
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
            .foresight = &[_]Foresight{},
            .goal_associations = goal_list.items,
        });
        cell_ptr.id = id;
        return .{
            .cell = cell_ptr,
            .fact_list = fact_list,
            .goal_list = goal_list,
        };
    }

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
        const fact_list = try self.alloc.create(std.ArrayList(Fact));
        errdefer self.alloc.destroy(fact_list);
        fact_list.* = .empty;

        const goal_list = try self.alloc.create(std.ArrayList(GoalAssociation));
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
                .source = "cli",
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
            .episode = episode,
            .atomic_facts = fact_list.items,
            .foresight = &[_]Foresight{},
            .goal_associations = goal_list.items,
            .metadata = meta,
        };
        return .{
            .cell = cell_ptr,
            .fact_list = fact_list,
            .goal_list = goal_list,
        };
    }

    fn commitBuiltCell(self: *Store, id: u64, built: BuiltCell) !void {
        _ = try self.lc.addCell(id, built.cell.*);
        // Note: built.fact_list / goal_list / cell are NOT freed here.
        // The caller owns them and is responsible for calling
        // `built.deinit(alloc)` on both success and failure paths.
        // This avoids the by-value-vs-by-pointer ownership confusion
        // that caused dbl-free segfaults in early v0.2.0 testing.

        if (self.mgr.get(id)) |stored| {
            try self.cell_index.put(id, stored);
            const v = try self.emb.embed(self.alloc, stored.episode);
            defer self.alloc.free(v);
            self.hnsw.insert(id, v) catch |err| {
                log.warn("hnsw insert failed: {}", .{err});
            };
        }
    }

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

    fn cloneFacts(self: *Store, src: []const Fact) ![]Fact {
        const out = try self.alloc.alloc(Fact, src.len);
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

    fn cloneForesights(self: *Store, src: []const Foresight) ![]Foresight {
        const out = try self.alloc.alloc(Foresight, src.len);
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

        if (data.counter > 0) {
            _ = self.ids.fetchMax(data.counter, .monotonic);
        }

        for (data.cells) |cs| {
            const snapshot_cell: MemCell = .{
                .id = cs.id,
                .source = cs.source,
                .episode = cs.episode,
                .atomic_facts = cs.facts,
                .foresight = cs.foresight,
                .goal_associations = cs.goal_associations,
                .metadata = cs.metadata,
            };
            _ = self.lc.addCell(cs.id, snapshot_cell) catch |err| {
                std.log.warn("snapshot: addCell failed for id={d}: {}", .{ cs.id, err });
                continue;
            };
            if (self.mgr.get(cs.id)) |stored| try self.cell_index.put(cs.id, stored);
        }
        for (data.fuzzy_cells) |cs| {
            const cell = try self.alloc.create(MemCell);
            errdefer self.alloc.destroy(cell);
            cell.* = .{
                .id = cs.id,
                .source = cs.source,
                .episode = try self.alloc.dupe(u8, cs.episode),
                .atomic_facts = try self.cloneFacts(cs.facts),
                .foresight = try self.cloneForesights(cs.foresight),
                .goal_associations = try self.alloc.dupe(GoalAssociation, cs.goal_associations),
                .metadata = cs.metadata,
            };
            try self.lc.fuzzy.transfer(cell);
        }
    }

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
        if (self.wal) |wal| {
            wal.flush() catch {};
            wal.deinit();
            self.alloc.destroy(wal);
            self.wal = null;
            var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const z = std.fmt.bufPrint(&zbuf, "{s}\x00", .{self.wal_path}) catch return;
            _ = std.c.unlink(z[0 .. z.len - 1 :0].ptr);
            const wal_ptr = self.alloc.create(WAL) catch return;
            wal_ptr.* = WAL.init(self.alloc, self.wal_path) catch return;
            wal_ptr.open() catch {
                wal_ptr.deinit();
                self.alloc.destroy(wal_ptr);
                return;
            };
            self.wal = wal_ptr;
        }
    }

    fn openAndReplayPersistence(self: *Store, data_dir: []const u8) !void {
        const dir_path = try self.alloc.dupe(u8, data_dir);
        defer self.alloc.free(dir_path);

        var it = std.mem.splitScalar(u8, dir_path, '/');
        var prefix: std.array_list.AlignedManaged(u8, null) = .init(self.alloc);
        defer prefix.deinit();
        if (dir_path.len > 0 and dir_path[0] == '/') {
            try prefix.append('/');
        }
        while (it.next()) |component| {
            if (component.len == 0) continue;
            if (prefix.items.len > 0 and prefix.items[prefix.items.len - 1] != '/') {
                try prefix.append('/');
            }
            try prefix.appendSlice(component);
            var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const written = std.fmt.bufPrint(&zbuf, "{s}", .{prefix.items}) catch {
                return error.DataDirPathTooLong;
            };
            zbuf[written.len] = 0;
            const zptr: [*:0]const u8 = zbuf[0 .. written.len :0].ptr;
            const rc = std.c.mkdir(zptr, 0o755);
            if (rc == 0) continue;
            var st: std.c.Stat = undefined;
            if (std.c.stat(zptr, &st) != 0) return error.DataDirStatFailed;
            const mode_u32: u32 = @intCast(st.mode);
            if ((mode_u32 & 0xF000) != 0x4000) return error.DataDirNotADirectory;
        }

        const wal_path = std.fs.path.join(self.alloc, &.{ data_dir, "mem3.wal" }) catch |err| {
            log.warn("path.join failed: {}; persistence disabled", .{err});
            return;
        };
        const snapshot_path = std.fs.path.join(self.alloc, &.{ data_dir, "snapshot.bin" }) catch |err| {
            self.alloc.free(wal_path);
            log.warn("path.join failed: {}; persistence disabled", .{err});
            return;
        };
        self.alloc.free(self.wal_path);
        self.alloc.free(self.snapshot_path);
        self.wal_path = wal_path;
        self.snapshot_path = snapshot_path;

        var wal_z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const wal_z = std.fmt.bufPrint(&wal_z_buf, "{s}\x00", .{self.wal_path}) catch {
            log.warn("path too long", .{});
            return;
        };
        const wal_z_slice = wal_z[0 .. wal_z.len - 1 :0];

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

        const wal_ptr = self.alloc.create(WAL) catch |err| {
            std.log.err("WAL: alloc failed: {s}", .{@errorName(err)});
            return;
        };
        const init_wal = WAL.init(self.alloc, self.wal_path) catch |err| {
            std.log.err("WAL: init failed: {s}", .{@errorName(err)});
            self.alloc.destroy(wal_ptr);
            return;
        };
        wal_ptr.* = init_wal;
        wal_ptr.open() catch |err| {
            std.log.err("WAL: open({s}) failed: {s}", .{ self.wal_path, @errorName(err) });
            wal_ptr.deinit();
            self.alloc.destroy(wal_ptr);
            return;
        };
        std.log.info("WAL: opened {s} (replay={d} bytes)", .{ self.wal_path, existing.items.len });
        self.wal = wal_ptr;

        try self.loadSnapshot();
        if (existing.items.len == 0) return;

        var replay_count: u64 = 0;
        var max_replayed_id: u64 = 0;
        var synthetic_id_seq: u64 = 0;
        const SYNTHETIC_ID_BASE: u64 = 1_000_000_000;
        const Ctx = struct {
            store: *Store,
            count: *u64,
            max_id: *u64,
            synthetic_seq: *u64,
        };
        var ctx = Ctx{
            .store = self,
            .count = &replay_count,
            .max_id = &max_replayed_id,
            .synthetic_seq = &synthetic_id_seq,
        };
        wal_ptr.replay(existing.items, &ctx, struct {
            fn cb(ctx_ptr: *Ctx, rec: WALRecord) anyerror!void {
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

                const built = ctx_ptr.store.buildCellFromParsed(
                    parsed.id,
                    parsed.source,
                    parsed.episode,
                    parsed.facts,
                    parsed.goal_id,
                    parsed.relevance,
                    parsed.metadata,
                ) catch |err| {
                    std.log.warn("replay: buildCell failed: {}", .{err});
                    return;
                };
                errdefer built.deinit(ctx_ptr.store.alloc);
                // commitBuiltCell no longer frees built's containers —
                // the caller owns them. errdefer covers failure; explicit
                // deinit covers success.
                ctx_ptr.store.commitBuiltCell(parsed.id, built) catch |err| {
                    std.log.warn("replay insert failed: {}", .{err});
                    // errdefer built.deinit at line above is registered
                    // *after* buildCellFromParsed succeeded, so on
                    // commitBuiltCell error we must deinit explicitly
                    // to avoid leaking the BuiltCell's containers.
                    built.deinit(ctx_ptr.store.alloc);
                    return;
                };
                built.deinit(ctx_ptr.store.alloc);
                ctx_ptr.count.* += 1;
            }
        }.cb) catch |err| {
            log.warn("WAL replay stopped at record {d}: {}", .{ replay_count, err });
        };
        if (max_replayed_id > 0) {
            _ = self.ids.fetchMax(max_replayed_id + 1, .monotonic);
        }
        std.log.info("WAL: replayed {d} memcell_insert records from {s}", .{ replay_count, self.wal_path });
    }
};

// =============================================================================
// Helpers shared with the HTTP server
// =============================================================================

fn wallClockSec() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

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
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value }) catch unreachable;
    try out.appendSlice(alloc, s);
}

fn jsonFieldIntRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: i64) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value }) catch unreachable;
    try out.appendSlice(alloc, s);
}

fn jsonFieldFloatRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: f32) !void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d:.6}", .{ key, value }) catch unreachable;
    try out.appendSlice(alloc, s);
}

/// Replay-side payload parser. Mirrors the one in HTTP server but lives
/// here so the Store can be tested without spinning up the server.
const ParsedInsert = struct {
    id: u64,
    source: MemorySource,
    episode: []u8,
    facts: []u8,
    goal_id: u64,
    relevance: f32,
    metadata: core.Metadata,

    pub fn deinit(self: *const ParsedInsert, alloc: Allocator) void {
        // `source` is a MemorySource enum (by value, no heap), so no
        // free needed — the 6-byte leak is from somewhere else.
        alloc.free(self.episode);
        alloc.free(self.facts);
    }
};

const ParseError = error{ ParseFailed, OutOfMemory };

fn parseInsertPayload(alloc: Allocator, payload: []const u8, synthetic_id_fallback: u64) ParseError!ParsedInsert {
    const id_opt = extractJsonInt(payload, "id");
    const id: u64 = if (id_opt) |id_i| blk: {
        if (id_i < 0) return error.ParseFailed;
        break :blk @intCast(id_i);
    } else blk: {
        break :blk synthetic_id_fallback;
    };

    const source_str = try extractJsonStringOrOwned(alloc, payload, "source", "matter");
    const source = MemorySource.fromString(source_str) catch {
        alloc.free(source_str);
        return error.ParseFailed;
    };
    // `source_str` is consumed by fromString (which only reads it
    // as a comptime-friendly view); free immediately so it doesn't
    // leak on the success path.
    alloc.free(source_str);
    const episode = try extractJsonStringOrOwned(alloc, payload, "episode", "");
    errdefer alloc.free(episode);
    if (episode.len == 0) return error.ParseFailed;
    const facts = try extractJsonStringOrOwned(alloc, payload, "facts", "");
    errdefer alloc.free(facts);
    const goal_id_i: i64 = extractJsonInt(payload, "goal_id") orelse extractJsonInt(payload, "goalId") orelse 1;
    if (goal_id_i < 0) return error.ParseFailed;
    const goal_id: u64 = @intCast(goal_id_i);
    const relevance_f: f32 = extractJsonFloat(payload, "relevance") orelse 0.5;

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
    while (pos < body.len) {
        if (body[pos] == '\\') {
            if (pos + 1 >= body.len) return null;
            pos += 2;
            continue;
        }
        if (body[pos] == '"') break;
        pos += 1;
    }
    if (pos >= body.len) return null;
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
                    try out.appendSlice(alloc, input[i..]);
                    i = input.len;
                    break;
                }
                const hex = input[i + 2 .. i + 6];
                const cp = std.fmt.parseInt(u21, hex, 16) catch {
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

fn utf8Encode(cp: u21, dest: *[4]u8) usize {
    if (cp < 0x80) {
        dest[0] = @intCast(cp);
        return 1;
    } else if (cp >= 0xD800 and cp <= 0xDFFF) {
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

// =============================================================================
// Tests
// =============================================================================

test "Store: in-memory add + getCell" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    // Add a cell with explicit goal association (skip default goals).
    const id = try store.addRaw(.matter, "hello world", "user|likes|coffee", 1, 0.7);
    try std.testing.expect(id > 0);

    const cell = store.getCell(id).?;
    try std.testing.expectEqual(MemorySource.matter, cell.source);
    try std.testing.expectEqualStrings("hello world", cell.episode);
    try std.testing.expectEqual(@as(usize, 1), store.cellCount());
    try std.testing.expectEqual(@as(usize, 1), store.cellCountBySource(.matter));
    try std.testing.expect(!store.isDurable());
}

test "Store: durable mode writes WAL, replay reconstructs state" {
    const alloc = std.testing.allocator;
    // Scratch dir lives outside the repo: running the test suite must not
    // leave `data/` behind in the working tree. The pre/post unlink
    // blocks below make this safe even after a crashed previous run.
    var data_dir_buf: [64]u8 = undefined;
    const data_dir = std.fmt.bufPrint(&data_dir_buf, "/tmp/mem3_test_store_e2e", .{}) catch "/tmp/mem3_test_store_e2e";
    defer {
        // Best-effort cleanup so re-runs start fresh.
        var wal_z: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (std.fmt.bufPrint(&wal_z, "{s}/mem3.wal\x00", .{data_dir})) |wz| {
            _ = std.c.unlink(wz[0 .. wz.len - 1 :0].ptr);
        } else |_| {}
        if (std.fmt.bufPrint(&wal_z, "{s}/snapshot.bin\x00", .{data_dir})) |wz| {
            _ = std.c.unlink(wz[0 .. wz.len - 1 :0].ptr);
        } else |_| {}
        var rmdir_z: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (std.fmt.bufPrint(&rmdir_z, "{s}\x00", .{data_dir})) |dz| {
            _ = std.c.rmdir(dz[0 .. dz.len - 1 :0].ptr);
        } else |_| {}
    }
    // Pre-clean: ensure we start with a fresh directory.
    {
        var wal_z: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (std.fmt.bufPrint(&wal_z, "{s}/mem3.wal\x00", .{data_dir})) |wz| {
            _ = std.c.unlink(wz[0 .. wz.len - 1 :0].ptr);
        } else |_| {}
        if (std.fmt.bufPrint(&wal_z, "{s}/snapshot.bin\x00", .{data_dir})) |wz| {
            _ = std.c.unlink(wz[0 .. wz.len - 1 :0].ptr);
        } else |_| {}
    }

    // First run: insert two cells, then deinit.
    {
        var store = try Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try std.testing.expect(store.isDurable());

        _ = try store.addRaw(.matter, "alpha", "a|b|c", 1, 0.5);
        _ = try store.addRaw(.form, "beta", "x|y|z", 1, 0.6);

        try std.testing.expectEqual(@as(usize, 2), store.cellCount());
        try std.testing.expectEqual(@as(usize, 1), store.cellCountBySource(.matter));
        try std.testing.expectEqual(@as(usize, 1), store.cellCountBySource(.form));

        // Sync explicitly to flush + snapshot.
        try store.sync();
    }

    // Second run: re-open same directory, replay restores state.
    {
        var store = try Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        try std.testing.expectEqual(@as(usize, 2), store.cellCount());

        // Verify the content survived.
        var it = store.cell_index.iterator();
        var saw_alpha = false;
        var saw_beta = false;
        while (it.next()) |entry| {
            const cell = entry.value_ptr.*;
            if (std.mem.eql(u8, cell.episode, "alpha")) saw_alpha = true;
            if (std.mem.eql(u8, cell.episode, "beta")) saw_beta = true;
        }
        try std.testing.expect(saw_alpha);
        try std.testing.expect(saw_beta);

        // Cleanup test directory. Skip in Zig 0.17 dev where std.fs.cwd
        // and deleteTree have moved; the OS will clean tmp-style paths
        // and the user can `rm -rf data/test_*` if needed.
    }
}

test "Store: forget moves low-importance cells to fuzzy" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const id = try store.addRaw(.matter, "ephemeral", "", 1, 0.1);
    const cell = store.getCell(id).?;
    cell.metadata.importance_score = 0.001;

    const dry = try store.forget(true);
    try std.testing.expectEqual(@as(usize, 1), dry.fuzzied);
    try std.testing.expectEqual(@as(usize, 1), store.cellCount());

    const live = try store.forget(false);
    try std.testing.expectEqual(@as(usize, 1), live.fuzzied);
    try std.testing.expectEqual(@as(usize, 0), store.cellCount());
    try std.testing.expectEqual(@as(usize, 1), store.lc.fuzzy.count());
}

test "Store: goal create + list" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const gid = try store.createGoal("ghw-kernel", "self-evolving", null, 9, null, 1_000_000);
    const goals = try store.listGoals(alloc);
    defer alloc.free(goals);

    try std.testing.expectEqual(@as(usize, 1), goals.len);
    try std.testing.expectEqual(gid, goals[0].id);
    try std.testing.expectEqualStrings("ghw-kernel", goals[0].name);
}

test "Store: hyperedge add + multiHop" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const c1 = try store.addRaw(.matter, "c1", "", 1, 0.5);
    const c2 = try store.addRaw(.matter, "c2", "", 1, 0.5);
    const c3 = try store.addRaw(.matter, "c3", "", 1, 0.5);

    try store.hymem.addNode(c1);
    try store.hymem.addNode(c2);
    try store.hymem.addNode(c3);

    const edge_id = try store.addHyperedge(.{
        .id = 0,
        .edge_type = .associative,
        .nodes = &[_]u64{ c1, c2 },
        .weight = 0.8,
        .source_weights = .{ 0.5, 0.5, 0.0 },
        .confidence = 0.9,
        .created_at = 0,
    });
    try std.testing.expect(edge_id > 0);

    const visited = try store.multiHop(alloc, &[_]u64{c1}, 3, 0.0, null);
    defer alloc.free(visited);
    try std.testing.expect(visited.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), store.hyperedgeCount());
}