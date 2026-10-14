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
const Embedder = retrieval.Embedder;
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
    /// Which embedder implementation the store embeds with. Default:
    /// `.lexical_hash` — the real lexical embedder. `.stub_xxhash`
    /// stays available because it is the historical default and
    /// changing it silently would move every persisted HNSW index's
    /// vector space under the user. Note the vectors themselves are
    /// NOT persisted, only ids and graph topology, so switching
    /// embedder requires a re-index to be meaningful.
    embedder_kind: Config.EmbedderKind = .lexical_hash,
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
    emb: Embedder,
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
        self.emb = Embedder.init(opts.embedder_kind, opts.embed_dim);

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
    ///
    /// The consolidator itself only holds the TriSourceManager, so it
    /// used to insert abstracts that reached nothing else: not
    /// `cell_index`, not HNSW, not the WAL. Measured before this was
    /// wired: `consolidate` reported `abstracts_created=1, cells:
    /// 6 -> 7` while `dump` still listed 6 records and `query` could
    /// not retrieve any of them — consolidation produced data no
    /// user-facing path could observe. Each abstract is now indexed,
    /// embedded and journaled like any other cell.
    pub fn consolidate(self: *Store) !usize {
        var result = try self.lc.consolidateDetailed();
        defer result.deinitAbstractIds(self.alloc);

        for (result.abstract_ids) |id| {
            self.indexAbstract(id);
        }
        return result.abstracts_created;
    }

    /// Put one consolidation abstract into the paths that make a cell
    /// usable: `cell_index`, the vector index, and the WAL.
    fn indexAbstract(self: *Store, id: u64) void {
        const cell = self.mgr.get(id) orelse return;

        self.cell_index.put(id, cell) catch |err| {
            log.warn("consolidate: cell_index.put failed for abstract {d}: {}", .{ id, err });
            return;
        };

        // Embed and index. A failure here leaves the abstract
        // unsearchable, which is exactly the state this function
        // exists to prevent, so it is reported rather than swallowed.
        const v = self.emb.embed(self.alloc, cell.episode) catch |err| {
            log.warn("consolidate: embed failed for abstract {d}: {}", .{ id, err });
            return;
        };
        defer self.alloc.free(v);
        self.hnsw.insert(id, v) catch |err| {
            log.warn("consolidate: hnsw insert failed for abstract {d}: {}", .{ id, err });
        };

        // Journal last. The abstract is already observable in memory,
        // so a WAL failure here means it will not survive a restart
        // that does not also take a snapshot.
        if (self.wal) |wal| {
            const payload = self.encodeWALPayload(
                id,
                cell.source,
                cell.episode,
                cell.episode,
                0,
                0.0,
                cell.metadata,
            ) catch |err| {
                log.warn("consolidate: WAL encode failed for abstract {d}: {}", .{ id, err });
                return;
            };
            defer self.alloc.free(payload);
            wal.append(.{
                .record_type = .memcell_insert,
                .payload = payload,
                .timestamp = wallClockSec(),
            }) catch |err| {
                log.warn("consolidate: WAL append failed for abstract {d}: {}", .{ id, err });
            };
        }
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
    ///
    /// WAL-first, like `addRaw`: the parent is validated and the id is
    /// reserved, the `goal_create` record is appended + fsynced, and
    /// only then is the in-memory poset mutated. Doing it the other
    /// way round would leave a goal in memory that a crash between
    /// the two steps turns into a phantom record on disk.
    pub fn createGoal(
        self: *Store,
        name: []const u8,
        description: []const u8,
        parent_id: ?u64,
        priority: u8,
        deadline: ?i64,
        now_ms: i64,
    ) !u64 {
        // Same precondition GoalPoset.create enforces, hoisted above
        // the journal step: a missing parent must fail *before* the
        // record is durable, or replay would resurrect a goal whose
        // parent never existed.
        const parent = parent_id orelse ghw_goal_tree.ROOT_GOAL_ID;
        if (!self.goals.nodes.contains(parent)) return core.Error.GoalNotFound;

        const id = self.ids.fetchAdd(1, .monotonic);

        if (self.wal) |wal| {
            const payload = try self.encodeGoalWALPayload(
                id,
                name,
                description,
                parent_id,
                priority,
                deadline,
                now_ms,
            );
            defer self.alloc.free(payload);
            wal.append(.{
                .record_type = .goal_create,
                .payload = payload,
                .timestamp = wallClockSec(),
            }) catch |err| {
                // Nothing reached the disk, so the id is still ours.
                _ = self.ids.fetchSub(1, .monotonic);
                return err;
            };
        }

        // `slot` is a private counter seeded to `id` so
        // `GoalPoset.create` — which allocates its own id from the
        // counter it is handed — mints exactly the id we just
        // journaled. The shared `self.ids` was already advanced past
        // it by the fetchAdd above, so the two stay in lockstep.
        var slot: std.atomic.Value(u64) = .init(id);
        const created = self.goals.create(name, description, parent_id, priority, deadline, now_ms, &slot) catch |err| {
            // Past this point the record is durable; replay will
            // materialise the goal on the next boot. Do NOT roll the
            // id back — a later insert reusing it would collide with
            // the id this WAL record already claims.
            log.warn("createGoal: goal id={d} is journaled but poset insert failed: {}", .{ id, err });
            return err;
        };
        if (created != id) {
            log.err("createGoal: id drift — journaled {d}, poset returned {d}", .{ id, created });
        }
        return created;
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
    /// Update a goal's status. WAL-first, like `createGoal`.
    ///
    /// This used to mutate only the in-memory poset, so a status change
    /// was silently lost on restart: `mem3 goal status 4 in_progress`
    /// looked like it worked and then reverted to `pending` on the next
    /// process. The record type `goal_update = 0x11` was already
    /// declared in `wal.zig` and simply unused; using the reserved value
    /// is safe because no such record exists on any disk yet, and
    /// renumbering an existing type would corrupt older WALs.
    pub fn updateGoalStatus(self: *Store, id: u64, status: core.GoalStatus, now_ms: i64) !void {
        // Precondition first: a status update for a goal that does not
        // exist must fail BEFORE anything is journaled, or replay would
        // try to apply an update to an absent goal.
        if (!self.goals.nodes.contains(id)) return core.Error.GoalNotFound;

        if (self.wal) |wal| {
            const payload = try self.encodeGoalUpdatePayload(id, status, now_ms);
            defer self.alloc.free(payload);
            try wal.append(.{
                .record_type = .goal_update,
                .payload = payload,
                .timestamp = wallClockSec(),
            });
        }
        try self.goals.updateStatus(id, status, now_ms);
    }

    /// Free-standing form of `encodeGoalUpdatePayload`, same reason as
    /// `encodeGoalWALPayloadRaw`: the daemon has its own Store type and
    /// must not grow a second copy of the goal_status wire format.
    pub fn encodeGoalUpdatePayloadRaw(
        alloc: Allocator,
        id: u64,
        status: core.GoalStatus,
        updated_at: i64,
    ) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        try out.append(alloc, '{');
        try jsonFieldUintRaw(alloc, &out, "id", id);
        try out.append(alloc, ',');
        try jsonFieldStringRaw(alloc, &out, "status", @tagName(status));
        try out.append(alloc, ',');
        var num_buf: [24]u8 = undefined;
        try out.appendSlice(alloc, "\"updated_at\":");
        try out.appendSlice(alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{updated_at}));
        try out.append(alloc, '}');
        return out.toOwnedSlice(alloc);
    }

    /// `{"id":N,"status":"<tag>","updated_at":MS}`
    fn encodeGoalUpdatePayload(
        self: *Store,
        id: u64,
        status: core.GoalStatus,
        updated_at: i64,
    ) ![]u8 {
        return encodeGoalUpdatePayloadRaw(self.alloc, id, status, updated_at);
    }

    // =================================================================
    // HyMem ops (CLI `hyperedge` subcommand)
    // =================================================================

    /// Add a hyperedge connecting 2+ existing MemCells.
    /// WAL-first, like `addRaw` and `createGoal`.
    ///
    /// This used to insert straight into the in-memory hypergraph with no
    /// journal, while `mem3 hyperedge add`'s own doc comment promised
    /// "durable (snapshot+wal) when --data-dir is set". The whole
    /// hypergraph therefore vanished on restart, taking every
    /// `multiHop` answer with it.
    pub fn addHyperedge(self: *Store, edge: HyperEdge) !u64 {
        // Validate before journaling: an invalid edge must not become
        // durable, or replay would fail on a record that could never
        // have been created.
        try edge.validate();

        // Reserve the id BEFORE journaling. `HyMem.addEdge` mints its
        // own id internally, so journal-then-insert would have recorded
        // the caller's placeholder (usually 0) and the replayed edge
        // would land under a different id than the live one. The id
        // counter is shared with cells and goals, so a failure here
        // simply leaves a gap — harmless, because ids are only required
        // to be unique, not dense.
        const id = self.ids.fetchAdd(1, .monotonic);
        var journaled = edge;
        journaled.id = id;

        if (self.wal) |wal| {
            const payload = try self.encodeHyperedgePayload(journaled);
            defer self.alloc.free(payload);
            try wal.append(.{
                .record_type = .hyperedge_add,
                .payload = payload,
                .timestamp = wallClockSec(),
            });
        }
        return self.hymem.addEdgeWithId(id, journaled);
    }

    /// `{"id":N,"edge_type":"..","nodes":[..],"weight":F,
    ///  "source_weights":[F,F,F],"confidence":F,"created_at":MS,
    ///  "metadata":".."|null}`
    fn encodeHyperedgePayload(self: *Store, edge: HyperEdge) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.alloc);
        var num_buf: [32]u8 = undefined;
        try out.append(self.alloc, '{');
        try jsonFieldUintRaw(self.alloc, &out, "id", edge.id);
        try out.append(self.alloc, ',');
        try jsonFieldStringRaw(self.alloc, &out, "edge_type", @tagName(edge.edge_type));
        try out.append(self.alloc, ',');
        try out.appendSlice(self.alloc, "\"nodes\":[");
        for (edge.nodes, 0..) |nid, i| {
            if (i > 0) try out.append(self.alloc, ',');
            try out.appendSlice(self.alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{nid}));
        }
        try out.append(self.alloc, ']');
        try out.append(self.alloc, ',');
        try out.appendSlice(self.alloc, "\"weight\":");
        try out.appendSlice(self.alloc, try std.fmt.bufPrint(&num_buf, "{d:.4}", .{edge.weight}));
        try out.appendSlice(self.alloc, ",\"source_weights\":[");
        for (edge.source_weights, 0..) |w, i| {
            if (i > 0) try out.append(self.alloc, ',');
            try out.appendSlice(self.alloc, try std.fmt.bufPrint(&num_buf, "{d:.4}", .{w}));
        }
        try out.append(self.alloc, ']');
        try out.appendSlice(self.alloc, ",\"confidence\":");
        try out.appendSlice(self.alloc, try std.fmt.bufPrint(&num_buf, "{d:.4}", .{edge.confidence}));
        try out.appendSlice(self.alloc, ",\"created_at\":");
        try out.appendSlice(self.alloc, try std.fmt.bufPrint(&num_buf, "{d}", .{edge.created_at}));
        try out.appendSlice(self.alloc, ",\"metadata\":");
        if (edge.metadata) |m| {
            try jsonStringRawBody(self.alloc, &out, m);
        } else {
            try out.appendSlice(self.alloc, "null");
        }
        try out.append(self.alloc, '}');
        return out.toOwnedSlice(self.alloc);
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

    /// Encode a `memcell_insert` payload. Public because `mem3 add` must
    /// produce byte-identical records to `addRaw`: when `add` hand-rolled a
    /// second copy of this format it interpolated `episode` and the facts
    /// payload raw into a JSON string context, so any quote or backslash in
    /// user text produced a record that replay mis-parsed or dropped outright
    /// while `add` still reported success. One encoder, one escaping rule.
    pub fn encodeWALPayload(
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

    /// Encode a `goal_create` payload. Same hand-rolled JSON shape as
    /// `encodeWALPayload`, one field per `GoalPoset.create` argument:
    ///
    ///   {"id":N,"name":"..","description":"..","parent_id":-1|P,
    ///    "priority":N,"deadline":-1|D,"created_at":MS}
    ///
    /// `parent_id` and `deadline` use -1 as the "absent" sentinel —
    /// both are optional in the API, and Ids/deadlines are unsigned
    /// epoch-ms in practice, so -1 can never collide with a real
    /// value. `created_at` doubles as `updated_at` because
    /// `GoalPoset.create` sets both to the same `now_ms`.
    fn encodeGoalWALPayload(
        self: *Store,
        id: u64,
        name: []const u8,
        description: []const u8,
        parent_id: ?u64,
        priority: u8,
        deadline: ?i64,
        now_ms: i64,
    ) ![]u8 {
        return encodeGoalWALPayloadRaw(self.alloc, id, name, description, parent_id, priority, deadline, now_ms);
    }

/// Free-standing form of `Store.encodeGoalWALPayload`.
///
/// Public so the daemon's duplicate `Store` can re-journal goals with the
/// exact same encoder instead of growing a third hand-written copy of the
/// wire format. Only an allocator is needed.
pub fn encodeGoalWALPayloadRaw(
    alloc: Allocator,
    id: u64,
    name: []const u8,
    description: []const u8,
    parent_id: ?u64,
    priority: u8,
    deadline: ?i64,
    now_ms: i64,
) ![]u8 {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(alloc);
        try out.append(alloc, '{');
        try jsonFieldUintRaw(alloc, &out, "id", id);
        try out.append(alloc, ',');
        try jsonFieldStringRaw(alloc, &out, "name", name);
        try out.append(alloc, ',');
        try jsonFieldStringRaw(alloc, &out, "description", description);
        try out.append(alloc, ',');
        try jsonFieldIntRaw(alloc, &out, "parent_id", if (parent_id) |p| @as(i64, @intCast(p)) else -1);
        try out.append(alloc, ',');
        try jsonFieldUintRaw(alloc, &out, "priority", priority);
        try out.append(alloc, ',');
        try jsonFieldIntRaw(alloc, &out, "deadline", deadline orelse -1);
        try out.append(alloc, ',');
        try jsonFieldIntRaw(alloc, &out, "created_at", now_ms);
        try out.append(alloc, '}');
        return out.toOwnedSlice(alloc);
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
            // The WAL was just truncated and the snapshot does not
            // carry goals, so re-journal the whole poset into the
            // fresh file — otherwise every user goal dies here.
            self.rejournalGoals(wal_ptr);
            self.rejournalHyperedges(wal_ptr);
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
        var replayed_goals: u64 = 0;
        var replayed_edges: u64 = 0;
        var synthetic_id_seq: u64 = 0;
        const SYNTHETIC_ID_BASE: u64 = 1_000_000_000;
        const Ctx = struct {
            store: *Store,
            count: *u64,
            max_id: *u64,
            synthetic_seq: *u64,
            goals: *u64,
            edges: *u64,
        };
        var ctx = Ctx{
            .store = self,
            .count = &replay_count,
            .max_id = &max_replayed_id,
            .synthetic_seq = &synthetic_id_seq,
            .goals = &replayed_goals,
            .edges = &replayed_edges,
        };
        wal_ptr.replay(existing.items, &ctx, struct {
            fn cb(ctx_ptr: *Ctx, rec: WALRecord) anyerror!void {
                // Goal records predate nothing and postdate nothing:
                // a WAL written before goals were journaled contains
                // none of them and falls through untouched.
                if (rec.record_type == .goal_create) {
                    ctx_ptr.store.applyGoalRecord(rec.payload, ctx_ptr.max_id, ctx_ptr.goals);
                    return;
                }
                if (rec.record_type == .goal_update) {
                    ctx_ptr.store.applyGoalStatusRecord(rec.payload, ctx_ptr.goals);
                    return;
                }
                if (rec.record_type == .hyperedge_add) {
                    ctx_ptr.store.applyHyperedgeRecord(rec.payload, ctx_ptr.edges, ctx_ptr.max_id);
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
        std.log.info("WAL: replayed {d} memcell_insert + {d} goal_create records from {s}", .{ replay_count, replayed_goals, self.wal_path });
    }

    /// Replay one `goal_update` record. Idempotent and order-independent:
/// an update for a goal whose `goal_create` has not been replayed yet
/// is dropped, because `rejournalGoals` always emits the create first.
fn applyGoalStatusRecord(self: *Store, payload: []const u8, count: *u64) void {
        const id = extractJsonInt(payload, "id") orelse return;
        const status_str = extractJsonStringOrOwned(self.alloc, payload, "status", "") catch return;
        defer self.alloc.free(status_str);
        const status = std.meta.stringToEnum(core.GoalStatus, status_str) orelse {
            log.warn("WAL: goal_update id={d} carries unknown status '{s}', skipped", .{ id, status_str });
            return;
        };
        if (!self.goals.nodes.contains(@intCast(id))) {
            log.warn("WAL: goal_update id={d} skipped — goal not in poset", .{id});
            return;
        }
        // Replay in file order; only count records that actually changed
        // something, so the log line reflects real work rather than the
        // number of records read.
        const now = extractJsonInt(payload, "updated_at") orelse 0;
        const before = self.goals.get(@intCast(id)).?.status;
        self.goals.updateStatus(@intCast(id), status, now) catch |err| {
            log.warn("WAL: goal_update id={d} failed: {}", .{ id, err });
            return;
        };
        if (self.goals.get(@intCast(id)).?.status != before) count.* += 1;
    }

    /// Replay one `hyperedge_add` record. Idempotent: a re-journalled
    /// or already-present id is skipped rather than duplicated.
    fn applyHyperedgeRecord(self: *Store, payload: []const u8, count: *u64, max_id: *u64) void {
        const e = parseHyperedgePayload(self.alloc, payload) catch |err| {
            log.warn("WAL: skipping hyperedge_add (parse failed: {})", .{err});
            return;
        };
        defer e.deinit(self.alloc);

        if (e.id > max_id.*) max_id.* = e.id;
        if (self.hymem.edges.contains(e.id)) return;

        // The edge must reference cells that actually exist, otherwise
        // multiHop would hand back ids that resolve to nothing.
        for (e.nodes) |nid| {
            if (!self.cell_index.contains(nid)) {
                log.warn("WAL: hyperedge_add id={d} dropped — node {d} not in cell_index", .{ e.id, nid });
                return;
            }
        }
        // `addEdgeWithId`, not `addEdge`: the id in the record is the
        // one the edge was created under, and re-minting it here would
        // land the replayed edge under a different key than the live
        // one it replaced.
        _ = self.hymem.addEdgeWithId(e.id, e.asEdge() catch |err| {
            log.warn("WAL: hyperedge_add id={d} invalid: {}", .{ e.id, err });
            return;
        }) catch |err| {
            log.warn("WAL: hyperedge_add id={d} failed: {}", .{ e.id, err });
            return;
        };
        count.* += 1;
    }

    /// Replay one `goal_create` record back into the poset, with the
    /// same id it was created under. Idempotent by construction: a
    /// record whose id is already present (re-seeded goal, or a WAL
    /// replayed on top of a snapshot) is skipped rather than
    /// duplicated, so replaying twice is a no-op.
    fn applyGoalRecord(self: *Store, payload: []const u8, max_id: *u64, count: *u64) void {
        const g = parseGoalPayload(self.alloc, payload) catch |err| {
            log.warn("WAL: skipping goal_create record (parse failed: {})", .{err});
            return;
        };
        defer g.deinit(self.alloc);

        if (g.id == ghw_goal_tree.ROOT_GOAL_ID or g.id == ghw_goal_tree.TOP_GOAL_ID) {
            log.warn("WAL: goal_create record carries reserved id {d}, skipped", .{g.id});
            return;
        }
        // The counter must clear every id the WAL claims, even the
        // ones we skip, so a fresh create can never mint an id that
        // an existing record already uses.
        if (g.id > max_id.*) max_id.* = g.id;

        if (self.goals.nodes.contains(g.id)) return;
        if (g.parent_id) |p| {
            if (!self.goals.nodes.contains(p)) {
                log.warn("WAL: goal_create id={d} dropped — parent {d} is not in the poset", .{ g.id, p });
                return;
            }
        }
        // Same trick as createGoal: a private counter seeded to the
        // journaled id, so the poset mints exactly this id.
        var slot: std.atomic.Value(u64) = .init(g.id);
        const created = self.goals.create(g.name, g.description, g.parent_id, g.priority, g.deadline, g.created_at, &slot) catch |err| {
            log.warn("replay: goal_create id={d} failed: {}", .{ g.id, err });
            return;
        };
        if (created != g.id) {
            log.err("replay: goal_create id drift — record {d}, poset {d}", .{ g.id, created });
            return;
        }
        count.* += 1;
    }

    /// Re-emit every non-synthetic goal as a `goal_create` record into
    /// a freshly truncated WAL. The snapshot carries only
    /// (counter, cells, fuzzy) — see the `collectGoals` TODO in
    /// snapshot.zig — so truncating the WAL without this would delete
    /// every user goal on the next boot.
    ///
    /// Walks breadth-first from ⊥ so a parent is always journaled
    /// before its children; replay would otherwise drop a child whose
    /// parent has not been materialised yet.
    /// Re-emit every hyperedge into a freshly truncated WAL.
    ///
    /// Same failure class as goals, found by the regression test: the
    /// snapshot carries (counter, cells, fuzzy) and goals-via-rejournal
    /// but **no** hyperedges at all — `snapshot.zig` does not even
    /// mention the type. So truncating the WAL deleted the entire
    /// hypergraph, and every `multiHop` answer with it.
    fn rejournalHyperedges(self: *Store, wal: *WAL) void {
        var written: usize = 0;
        var it = self.hymem.edges.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr.*;
            // A hyperedge whose endpoint cells are gone would be
            // dropped on the next replay anyway; do not resurrect it.
            var endpoints_present = true;
            for (e.nodes) |nid| {
                if (!self.cell_index.contains(nid)) {
                    endpoints_present = false;
                    break;
                }
            }
            if (!endpoints_present) {
                log.warn("rejournalHyperedges: edge {d} dropped — an endpoint cell is missing", .{e.id});
                continue;
            }
            const payload = self.encodeHyperedgePayload(e.*) catch |err| {
                log.warn("rejournalHyperedges: encode failed for edge {d}: {}", .{ e.id, err });
                continue;
            };
            defer self.alloc.free(payload);
            wal.append(.{
                .record_type = .hyperedge_add,
                .payload = payload,
                .timestamp = wallClockSec(),
            }) catch |err| {
                log.warn("rejournalHyperedges: append failed for edge {d}: {}", .{ e.id, err });
                return;
            };
            written += 1;
        }
        if (written > 0) {
            log.info("rejournalHyperedges: re-emitted {d} hyperedge records into the fresh WAL", .{written});
        }
    }

    fn rejournalGoals(self: *Store, wal: *WAL) void {
        var queue: std.ArrayList(u64) = .empty;
        defer queue.deinit(self.alloc);
        queue.append(self.alloc, ghw_goal_tree.ROOT_GOAL_ID) catch {
            log.warn("rejournalGoals: out of memory — goals not carried into the new WAL", .{});
            return;
        };
        var head: usize = 0;
        var written: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            for (self.goals.childrenOf(queue.items[head])) |child_id| {
                if (child_id == ghw_goal_tree.ROOT_GOAL_ID or child_id == ghw_goal_tree.TOP_GOAL_ID) continue;
                const node = self.goals.get(child_id) orelse continue;
                // `GoalPoset.create` stores ROOT as a concrete parent;
                // store it back as the API's "absent" form.
                const parent_id: ?u64 = if (node.parent_id) |p|
                    (if (p == ghw_goal_tree.ROOT_GOAL_ID) null else p)
                else
                    null;
                {
                    const payload = self.encodeGoalWALPayload(child_id, node.name, node.description, parent_id, node.priority, node.deadline, node.created_at) catch |err| {
                        log.warn("rejournalGoals: encode failed for goal {d}: {}", .{ child_id, err });
                        continue;
                    };
                    defer self.alloc.free(payload);
                    wal.append(.{
                        .record_type = .goal_create,
                        .payload = payload,
                        .timestamp = wallClockSec(),
                    }) catch |err| {
                        log.warn("rejournalGoals: append failed for goal {d}: {}", .{ child_id, err });
                        return;
                    };
                }
                written += 1;
                // `goal_create` carries no status field, and
                // `GoalPoset.create` always starts at `.pending`. Without
                // this the snapshot truncation that `rejournalGoals`
                // exists to survive would silently reset every completed
                // or failed goal back to pending.
                if (node.status != .pending) {
                    const st_payload = self.encodeGoalUpdatePayload(child_id, node.status, node.updated_at) catch |err| {
                        log.warn("rejournalGoals: status encode failed for goal {d}: {}", .{ child_id, err });
                        continue;
                    };
                    defer self.alloc.free(st_payload);
                    wal.append(.{
                        .record_type = .goal_update,
                        .payload = st_payload,
                        .timestamp = wallClockSec(),
                    }) catch |err| {
                        log.warn("rejournalGoals: status append failed for goal {d}: {}", .{ child_id, err });
                        return;
                    };
                }
                queue.append(self.alloc, child_id) catch {
                    log.warn("rejournalGoals: out of memory at depth {d} — subtree dropped", .{head});
                    return;
                };
            }
        }
        std.log.info("rejournalGoals: re-emitted {d} goal records into the fresh WAL", .{written});
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

/// Write a bare JSON string (no key) — used where the key was already
/// emitted by the caller.
pub fn jsonStringRawBody(alloc: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(alloc);
    try jsonFieldStringRaw(alloc, &scratch, "", value);
    // strip the leading `"":` the key form leaves behind
    const full = scratch.items;
    const colon = std.mem.indexOfScalar(u8, full, ':') orelse full.len;
    try out.appendSlice(alloc, full[colon + 1 ..]);
}

pub fn jsonFieldStringRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
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
                const s = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{vc});
                try out.appendSlice(alloc, s);
            },
            else => try out.append(alloc, vc),
        }
    }
    try out.append(alloc, '"');
}

pub fn jsonFieldUintRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: u64) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value });
    try out.appendSlice(alloc, s);
}

pub fn jsonFieldIntRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: i64) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value });
    try out.appendSlice(alloc, s);
}

pub fn jsonFieldFloatRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: f32) !void {
    var buf: [48]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "\"{s}\":{d:.6}", .{ key, value });
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

/// Replay-side parse of a `goal_create` payload. Mirrors
/// `encodeGoalWALPayload` field for field; every optional field falls
/// back to the same default the API applies when it is absent.
pub const ParsedGoal = struct {
    id: u64,
    name: []u8,
    description: []u8,
    parent_id: ?u64,
    priority: u8,
    deadline: ?i64,
    created_at: i64,

    pub fn deinit(self: *const ParsedGoal, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
    }
};

pub fn parseGoalPayload(alloc: Allocator, payload: []const u8) ParseError!ParsedGoal {
    const id_i = extractJsonInt(payload, "id") orelse return error.ParseFailed;
    // Id 0 is the synthetic root; a record that claims it is corrupt.
    if (id_i <= 0) return error.ParseFailed;
    const name = try extractJsonStringOrOwned(alloc, payload, "name", "");
    errdefer alloc.free(name);
    if (name.len == 0) return error.ParseFailed;
    const description = try extractJsonStringOrOwned(alloc, payload, "description", "");
    errdefer alloc.free(description);

    const parent_i = extractJsonInt(payload, "parent_id") orelse -1;
    if (parent_i == ghw_goal_tree.ROOT_GOAL_ID) return error.ParseFailed;
    const parent_id: ?u64 = if (parent_i < 0) null else @intCast(parent_i);

    const priority_i = extractJsonInt(payload, "priority") orelse 5;
    const priority: u8 = if (priority_i < 0 or priority_i > 255) 5 else @intCast(priority_i);

    const deadline_i = extractJsonInt(payload, "deadline") orelse -1;
    const deadline: ?i64 = if (deadline_i < 0) null else deadline_i;

    return .{
        .id = @intCast(id_i),
        .name = name,
        .description = description,
        .parent_id = parent_id,
        .priority = priority,
        .deadline = deadline,
        .created_at = extractJsonInt(payload, "created_at") orelse 0,
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
/// Scratch-dir cleanup shared by the persistence tests below. All
/// scratch paths live under /tmp so a test run never writes into the
/// working tree. Best-effort: a leftover file from a crashed run is
/// simply overwritten.
fn wipeStoreDir(data_dir: []const u8) void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}/mem3.wal\x00", .{data_dir})) |wz| {
        _ = std.c.unlink(wz[0 .. wz.len - 1 :0].ptr);
    } else |_| {}
    if (std.fmt.bufPrint(&buf, "{s}/snapshot.bin\x00", .{data_dir})) |sz| {
        _ = std.c.unlink(sz[0 .. sz.len - 1 :0].ptr);
    } else |_| {}
    if (std.fmt.bufPrint(&buf, "{s}\x00", .{data_dir})) |dz| {
        _ = std.c.rmdir(dz[0 .. dz.len - 1 :0].ptr);
    } else |_| {}
}

test "Store: createGoal is WAL-journaled and survives restart" {
    const alloc = std.testing.allocator;
    const data_dir = "/tmp/mem3_test_store_goal";
    const legacy_dir = "/tmp/mem3_test_store_goal_legacy";
    wipeStoreDir(data_dir);
    wipeStoreDir(legacy_dir);
    defer {
        wipeStoreDir(data_dir);
        wipeStoreDir(legacy_dir);
    }

    // Run 1: one cell + one user goal. The goal id must be assigned by
    // the Store (not re-minted on replay), so remember it.
    const gid = blk: {
        var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
        defer store.deinit();
        _ = try store.addRaw(.matter, "cell-with-goal", "a|b|c", 1, 0.5);
        const id = try store.createGoal("persisted-goal", "must survive restart", null, 7, null, 1_700_000_000_000);
        try std.testing.expect(id > 0);
        break :blk id;
    };

    // Run 2: fresh Store over the same dir — WAL replay must rebuild
    // both the cell and the goal, with the original id.
    {
        var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
        defer store.deinit();

        try std.testing.expectEqual(@as(usize, 1), store.cellCount());
        const goals = try store.listGoals(alloc);
        defer alloc.free(goals);
        try std.testing.expectEqual(@as(usize, 1), goals.len);
        try std.testing.expectEqual(gid, goals[0].id);
        try std.testing.expectEqualStrings("persisted-goal", goals[0].name);
        try std.testing.expectEqualStrings("must survive restart", goals[0].description);
        try std.testing.expectEqual(@as(u8, 7), goals[0].priority);
    }

    // Run 3: `sync` truncates the WAL. The snapshot carries no goals,
    // so takeSnapshot re-journals them — the goal must still be here.
    {
        var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
        defer store.deinit();
        try store.sync();
    }
    {
        var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
        defer store.deinit();

        const goals = try store.listGoals(alloc);
        defer alloc.free(goals);
        try std.testing.expectEqual(@as(usize, 1), goals.len);
        try std.testing.expectEqual(gid, goals[0].id);
        try std.testing.expectEqualStrings("persisted-goal", goals[0].name);
    }

    // Run 4: a WAL written *before* goals were journaled holds nothing
    // but memcell_insert records. It must still replay cleanly and
    // leave the poset empty.
    {
        var store = try Store.init(alloc, .{ .data_dir = legacy_dir, .seed_default_goals = false });
        defer store.deinit();
        _ = try store.addRaw(.form, "legacy-cell", "x|y|z", 1, 0.5);
    }
    {
        var store = try Store.init(alloc, .{ .data_dir = legacy_dir, .seed_default_goals = false });
        defer store.deinit();

        try std.testing.expectEqual(@as(usize, 1), store.cellCount());
        const goals = try store.listGoals(alloc);
        defer alloc.free(goals);
        try std.testing.expectEqual(@as(usize, 0), goals.len);
    }
}

/// Replay-side parse of a `hyperedge_add` payload, mirroring
/// `encodeHyperedgePayload` field for field.
const ParsedEdge = struct {
    id: u64,
    edge_type: core.EdgeType,
    nodes: []u64,
    weight: f32,
    source_weights: [3]f32,
    confidence: f32,
    created_at: i64,
    metadata: ?[]u8,

    fn asEdge(self: ParsedEdge) !HyperEdge {
        return .{
            .id = self.id,
            .edge_type = self.edge_type,
            .nodes = self.nodes,
            .weight = self.weight,
            .source_weights = self.source_weights,
            .confidence = self.confidence,
            .created_at = self.created_at,
            .metadata = self.metadata,
        };
    }

    pub fn deinit(self: *const ParsedEdge, alloc: Allocator) void {
        alloc.free(self.nodes);
        if (self.metadata) |m| alloc.free(m);
    }
};

/// Parse the `[a,b,c]` id list without pulling in std.json reflection.
fn parseIdList(comptime key: []const u8, body: []const u8, alloc: Allocator) ![]u64 {
    const key_pos = std.mem.indexOf(u8, body, "\"" ++ key ++ "\"") orelse return error.ParseFailed;
    const open = std.mem.indexOfScalarPos(u8, body, key_pos, '[') orelse return error.ParseFailed;
    const close = std.mem.indexOfScalarPos(u8, body, open, ']') orelse return error.ParseFailed;
    var out = std.ArrayList(u64).empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, body[open + 1 .. close], ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t\r\n");
        if (t.len == 0) continue;
        try out.append(alloc, std.fmt.parseInt(u64, t, 10) catch return error.ParseFailed);
    }
    return out.toOwnedSlice(alloc);
}

fn parseFloatList3(comptime key: []const u8, body: []const u8) ![3]f32 {
    const key_pos = std.mem.indexOf(u8, body, "\"" ++ key ++ "\"") orelse return error.ParseFailed;
    const open = std.mem.indexOfScalarPos(u8, body, key_pos, '[') orelse return error.ParseFailed;
    const close = std.mem.indexOfScalarPos(u8, body, open, ']') orelse return error.ParseFailed;
    var out: [3]f32 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, body[open + 1 .. close], ',');
    while (it.next()) |part| {
        if (n >= 3) break;
        const t = std.mem.trim(u8, part, " \t\r\n");
        if (t.len == 0) continue;
        out[n] = std.fmt.parseFloat(f32, t) catch return error.ParseFailed;
        n += 1;
    }
    if (n != 3) return error.ParseFailed;
    return out;
}

fn parseHyperedgePayload(alloc: Allocator, payload: []const u8) !ParsedEdge {
    const id_i = extractJsonInt(payload, "id") orelse return error.ParseFailed;
    if (id_i < 0) return error.ParseFailed;
    const type_str = extractJsonStringOrOwned(alloc, payload, "edge_type", "") catch return error.ParseFailed;
    defer alloc.free(type_str);
    const edge_type = std.meta.stringToEnum(core.EdgeType, type_str) orelse return error.ParseFailed;

    const nodes = try parseIdList("nodes", payload, alloc);
    errdefer alloc.free(nodes);
    const source_weights = try parseFloatList3("source_weights", payload);
    const meta_owned: ?[]u8 = extractJsonStringOrOwned(alloc, payload, "metadata", "") catch null;

    return .{
        .id = @intCast(id_i),
        .edge_type = edge_type,
        .nodes = nodes,
        .weight = extractJsonFloat(payload, "weight") orelse 0.0,
        .source_weights = source_weights,
        .confidence = extractJsonFloat(payload, "confidence") orelse 0.0,
        .created_at = extractJsonInt(payload, "created_at") orelse 0,
        .metadata = meta_owned,
    };
}
