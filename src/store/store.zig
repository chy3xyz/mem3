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
const builtin = @import("builtin");
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
const ghw_io = @import("../ghw/ghw_io.zig");
const ghw_goal_tree = @import("../ghw/goal_tree.zig");
const memory = @import("../memory/mod.zig");
const retrieval = @import("../retrieval/mod.zig");
const RerankContext = @import("../retrieval/reranker.zig").RerankContext;
const HNSW = retrieval.HNSW;
const Embedder = retrieval.Embedder;
const WAL = @import("../storage/wal.zig").WAL;
const WALRecord = @import("../storage/wal.zig").WALRecord;
const Snapshot = @import("../storage/snapshot.zig");
const SnapshotData = Snapshot.SnapshotData;
const SnapshotWriter = Snapshot.SnapshotWriter;
const GoalSnapshot = Snapshot.GoalSnapshot;
const platform_fs = @import("../platform/fs.zig");
const HyMem = @import("../hypermem/mod.zig").HyMem;
const HyperEdge = @import("../hypermem/mod.zig").HyperEdge;

const log = std.log.scoped(.mem3_store);

/// Degraded-path diagnostics, compiled out under test.
///
/// Zig 0.17's test runner captures every log line emitted while a test runs
/// and fails the test that produced it — including `warn`, which
/// `std_options.log_level = .err` does not suppress. A library branch that
/// tests deliberately walk would otherwise turn the suite red for a reason
/// that has nothing to do with the assertion.
fn diag(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) log.warn(fmt, args);
}

/// Build-time options for `Store.init`. See module doc for semantics.
    /// The WAL on disk is shorter than the size we computed for it. Replaying
    /// a truncated prefix would resurrect a store state that never existed, so
    /// this is an error rather than a short read.
    pub const Error = error{WalReplayShortRead};

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
    /// GHW layer 2 (Harness / 象源). Owned; released in `deinit`.
    harness: *ghw.HarnessRegistry,
    /// GHW layer 3 (World / 物源). Owned; released in `deinit`.
    world: *ghw.WorldModel,
    /// The three-layer handle every memory operation now travels
    /// through. Built once in `init`; holds no ownership of its own.
    ghw: ghw.GHW,
    /// Bounded audit trail of every cross-layer hop. Owned; released in
    /// `deinit`. Bounded by construction — see `CrossLayerLog`.
    xlog: ghw.CrossLayerLog,
    /// Three-way recall (dense + sparse + hypergraph). Owns no memory:
    /// it borrows `self.hnsw`, `self.hymem` and a copy of `self.emb`.
    hybrid: retrieval.HybridRetriever,
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
            .harness = undefined,
            .world = undefined,
            .ghw = undefined,
            .xlog = undefined,
            .hybrid = undefined,
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
            // Stamped with *now*, not 0.
            //
            // These three are synthetic anchors, re-created on every boot
            // because `init` does not journal them. An epoch timestamp
            // makes them 56 years old the instant the store is built, so
            // the first Constitution III maintenance pass — "no memories
            // for 7 days → unrealized" — marks every built-in goal
            // unrealized before a single query has been served. Measured:
            // a fresh daemon reported 4 goals unrealized on its first pass,
            // three of them built-ins that had existed for microseconds.
            const seeded_at = wallClockMs();
            _ = try goals_ptr.create("general", "catch-all", null, 5, null, seeded_at, &self.ids);
            _ = try goals_ptr.create("research", "research-related", null, 7, null, seeded_at, &self.ids);
            _ = try goals_ptr.create("system", "system / meta", null, 6, null, seeded_at, &self.ids);
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
        // The encoder computes goal_relevance, the beta=0.40 term of
        // importance_score = 0.30*coherence + 0.40*goal_relevance +
        // 0.30*existential. Without this it reads only the caller-supplied
        // values, so a tombstoned goal scores exactly like a live one and the
        // single largest weight in the formula is blind. `mem3 add` wires
        // this itself; the daemon and the benchmarks do not, which is why it
        // belongs here rather than at each call site.
        lc_ptr.encoder.goals = self.goals;
        self.lc = lc_ptr;

        // HyMem (uses the same id source — hyperedges are id-allocated
        // from the same monotonic counter, but live in their own space)
        self.hymem = HyMem.init(alloc, &self.ids);

        // GHW layers 2 and 3 + the cross-layer audit log. These used to
        // be constructed only by their own unit tests, so a NON-NEGOTIABLE
        // constitutional principle (Principle II) was not enforced by
        // anything that ships. Everything from here on crosses them.
        const harness_ptr = try alloc.create(ghw.HarnessRegistry);
        errdefer alloc.destroy(harness_ptr);
        harness_ptr.* = ghw.HarnessRegistry.init(alloc);
        self.harness = harness_ptr;

        const world_ptr = try alloc.create(ghw.WorldModel);
        errdefer alloc.destroy(world_ptr);
        world_ptr.* = ghw.WorldModel.init(alloc);
        self.world = world_ptr;

        self.xlog = ghw.CrossLayerLog.init(alloc);
        self.ghw = ghw.GHW.init(alloc, self.goals, self.harness, self.world, &self.ids);

        // HNSW + embedder
        const hnsw_ptr = try alloc.create(HNSW);
        errdefer alloc.destroy(hnsw_ptr);
        hnsw_ptr.* = HNSW.init(alloc, .{}, opts.embed_dim);
        self.hnsw = hnsw_ptr;
        self.emb = try Embedder.init(opts.embedder_kind, opts.embed_dim);

        // The retriever embeds queries with the *store's* embedder, not a
        // second one built from `Config` defaults. With the old
        // `HybridRetriever.init` it would have hashed queries with
        // `.stub_xxhash` against an index built with `.lexical_hash` and
        // silently returned noise.
        self.hybrid = retrieval.HybridRetriever.init(alloc, lc_ptr.cfg, self.emb, self.hnsw, &self.hymem);

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
        self.xlog.deinit();
        self.harness.deinit();
        self.alloc.destroy(self.harness);
        self.world.deinit();
        self.alloc.destroy(self.world);
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
    ///
    /// ## Why this is more than a delegate
    ///
    /// `Lifecycle.forget` removes cells from the `TriSourceManager` and hands
    /// them to the fuzzy store. It does **not** touch `cell_index` and does
    /// **not** write the WAL. Both omissions were live bugs:
    ///
    ///  - `cell_index` kept its entry, so `getCell(id)` returned memories
    ///    that had been forgotten. Anything reading through the index could
    ///    surface a cell the system had declared no longer worth keeping.
    ///  - Nothing was journalled, so on restart the `memcell_insert` records
    ///    replayed and every forgotten cell came back — while
    ///    `mem3_forgotten_cells_total` still reported the sweep that removed
    ///    them. Process counters and on-disk state diverged.
    ///
    /// The fix is to diff the id set around the sweep. `Forgetter.SweepResult`
    /// carries only counts, and adding an id list to it would ripple through
    /// every consumer for no benefit: the sweep is already O(cells), so one
    /// extra pass is free.
    ///
    /// WAL-first ordering still holds — the `.forget` records are appended
    /// after the in-memory transfer, which means a crash between the two can
    /// lose the journal entry and resurrect the cell. That is the correct
    /// direction to fail: a resurrected memory is recoverable, a journalled
    /// deletion whose transfer did not happen is a phantom tombstone.
    pub fn forget(self: *Store, dry_run: bool) !memory.Forgetter.SweepResult {
        if (dry_run) return self.lc.forget(true);

        var before = std.ArrayList(u64).empty;
        defer before.deinit(self.alloc);
        var it = self.cell_index.iterator();
        while (it.next()) |e| try before.append(self.alloc, e.key_ptr.*);

        const result = try self.lc.forget(false);

        // Anything the sweep took out of the manager but left in the index.
        for (before.items) |id| {
            if (self.mgr.get(id) != null) continue;
            _ = self.cell_index.remove(id);

            if (self.wal) |wal| {
                // `.forget` (0x20) has been in the record enum since the
                // format was written and has never been emitted. Using it
                // needs no format change at all.
                var buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &buf, id, .little);
                wal.append(.{
                    .record_type = .forget,
                    .payload = buf[0..8],
                    .timestamp = wallClockSec(),
                }) catch |err| {
                    // A cell is already out of the manager. Failing to
                    // journal that means it will come back on restart —
                    // recoverable, and strictly better than aborting a sweep
                    // that has already half-completed.
                    log.warn("forget: WAL append failed for cell {d}: {}", .{ id, err });
                };
            }
        }

        return result;
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

        // And the transition itself must be legal before anything is
        // journaled. `GoalPoset.isValidTransition` existed only for its
        // own unit tests, so `completed → pending` and every other
        // illegal move was written to the WAL, fsynced, and reported as
        // success; the poset then applied it, and replay applied it
        // again on the next boot. The synthetic root/top are exempt:
        // they are `pending` by construction and are never user-visible.
        if (id != ghw_goal_tree.ROOT_GOAL_ID and id != ghw_goal_tree.TOP_GOAL_ID) {
            const from = self.goals.get(id).?.status;
            if (from != status and !ghw.GoalPoset.isValidTransition(from, status)) {
                diag("updateGoalStatus: illegal transition {s} -> {s} for goal {d}, rejected", .{ @tagName(from), @tagName(status), id });
                // Same error `GoalPoset.updateStatus` already reuses for
                // an invalid transition.
                return core.Error.GoalCycle;
            }
        }

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

    /// What one maintenance pass did.
    pub const MaintenanceResult = struct {
        /// Goals moved to `.unrealized` and made durable.
        goals_unrealized: usize = 0,
        /// Candidates that could not be written and were left alone.
        goals_failed: usize = 0,
        /// Cells the forgetting sweep moved into the fuzzy store.
        cells_forgotten: usize = 0,
    };

    /// One Constitution III maintenance pass.
    ///
    /// This is the only place the "a goal with no memories becomes
    /// `unrealized`" rule has ever been enforced at runtime. It lived in
    /// `GoalPoset.evaluateMetaGoals`, which no production code path called —
    /// the daemon is a blocking accept loop with no tick — so the invariant
    /// was documented, unit-tested, and never applied to a running system.
    ///
    /// Every transition goes through `updateGoalStatus`, which is
    /// WAL-first: the record is durable before the in-memory status moves.
    /// That is not optional here. A goal marked `unrealized` only in memory
    /// reverts on the next restart, which reads to the user like the
    /// system forgetting its own decision.
    pub fn maintain(self: *Store, now_ms: i64) !MaintenanceResult {
        var result: MaintenanceResult = .{};

        const stale = try self.goals.staleGoals(self.alloc, now_ms);
        defer self.alloc.free(stale);

        for (stale) |id| {
            self.updateGoalStatus(id, .unrealized, now_ms) catch |err| {
                // One bad goal must not abort the pass — the rest still
                // need their transitions written.
                diag("maintain: updateGoalStatus(goal={d}) failed: {}", .{ id, err });
                result.goals_failed += 1;
                continue;
            };
            result.goals_unrealized += 1;
        }

        return result;
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

    /// Relevance-propagating multi-hop: see `HyMem.multiHopScored`.
    pub fn multiHopScored(
        self: *Store,
        alloc: Allocator,
        seeds: []const HyMem.ScoredNode,
        max_hops: u8,
        decay: f32,
        confidence_threshold: f32,
        edge_types_filter: ?[]const core.EdgeType,
    ) ![]HyMem.ScoredNode {
        return self.hymem.multiHopScored(alloc, seeds, max_hops, decay, confidence_threshold, edge_types_filter);
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
            // 外拓. Everything above this line is the World layer's
            // storage job; everything GHW does with the memory happens
            // here, and it happens in layer order.
            try self.encodeAcrossLayers(id, stored);
        }
    }

    /// 外拓 — carry one committed memory across all three GHW layers.
    ///
    /// Goal → Harness → World, in that order, each hop checked against
    /// `isValidDirection` inside `GHW.encode` before it runs. A
    /// direction Principle II forbids is returned as an error, so it can
    /// never be written to the WAL as a successful insert.
    ///
    /// A memory whose goal association names a goal the poset does not
    /// hold (or a synthetic id, which is how "no goal" is spelled)
    /// skips the traversal rather than inventing a binding. Everything
    /// else about the insert has already succeeded, so this reports and
    /// returns rather than rolling the cell back.
    ///
    /// Cost per insert is O(1): one `bindMemcell` append, one hash
    /// lookup, two `updateWithSurprise` calls against an entity that
    /// already exists. Nothing here scans the corpus.
    fn encodeAcrossLayers(self: *Store, id: u64, cell: *MemCell) !void {
        if (cell.goal_associations.len == 0) return;
        const goal_id = cell.goal_associations[0].goal_id;
        if (goal_id == ghw_goal_tree.ROOT_GOAL_ID or goal_id == ghw_goal_tree.TOP_GOAL_ID) return;
        if (self.goals.get(goal_id) == null) {
            diag("encodeAcrossLayers: cell {d} names goal {d}, which the poset does not hold; skipped the GHW traversal", .{ id, goal_id });
            return;
        }

        // The cell reaches the Goal layer first, then flows outward.
        // This also fixes the meta-goal rule being unenforceable: a goal
        // with memories was never registered as having any, so the
        // "no memories for 7 days → unrealized" sweep aged out goals
        // that had a full corpus behind them.
        self.goals.bindMemcell(goal_id, id) catch |err| {
            diag("encodeAcrossLayers: bindMemcell(goal={d}, cell={d}) failed: {}", .{ goal_id, id, err });
            return err;
        };
        try self.ghw.encode(&self.xlog, .{
            .goal_id = goal_id,
            .cell_id = id,
            .now_ms = cell.metadata.created_at,
        });
    }

    // =================================================================
    // Retrieval (内求 — World → Harness → Goal)
    // =================================================================

    pub const QueryOptions = struct {
        /// Hits to return. The dense stage over-fetches 3x.
        topk: usize = 10,
        /// Extra goal scope the caller already knows about. The GHW
        /// traversal adds to this; it never narrows it.
        goal_ids: []const u64 = &.{},
    };

    /// Retrieve by text, traversing World → Harness → Goal before
    /// ranking.
    ///
    /// The traversal is what makes `RerankContext.goalBonus` live
    /// without a caller-supplied `--goal-ids`: the goal scope that
    /// multiplies the score is produced by the World layer picking the
    /// situation the query describes, the Harness layer naming the
    /// procedure that realises it, and the Goal layer naming the intent.
    ///
    /// Results are `topk` hits sorted by `final_score`. Caller owns the
    /// returned slice.
    pub fn query(self: *Store, alloc: Allocator, text: []const u8, opts: QueryOptions) ![]retrieval.ScoredCell {
        // Goal scope: whatever the caller asked for, plus whatever the
        // GHW traversal resolves to.
        var scope = std.ArrayList(u64).empty;
        defer scope.deinit(alloc);
        for (opts.goal_ids) |gid| try appendUnique(alloc, &scope, gid);

        if (try self.ghw.retrieve(&self.xlog, text, wallClockMs())) |gid| {
            try appendUnique(alloc, &scope, gid);
        }

        const cands = try self.hybrid.recall(alloc, text, opts.topk * 3);
        defer alloc.free(cands);

        var pairs = std.ArrayList(RerankContext.Pair).empty;
        defer pairs.deinit(alloc);
        // `cand`, not `c`: `c` is the `std.c` binding this module uses
        // for clock and fs calls, and a capture that shadows it silently
        // changes what the next line means.
        for (cands) |cand| {
            const cell = self.getCell(cand.cell_id) orelse continue;
            try pairs.append(alloc, .{
                .id = cand.cell_id,
                .score = cand.combined(self.lc.cfg),
                .cell = cell,
            });
        }

        var rr = RerankContext{
            .alloc = alloc,
            .cfg = self.lc.cfg,
            .goals = self.goals,
            .query_goal_ids = scope.items,
        };
        const scored = try rr.rerankPairs(alloc, pairs.items);
        defer alloc.free(scored);

        const n = @min(opts.topk, scored.len);
        const out = try alloc.dupe(retrieval.ScoredCell, scored[0..n]);
        return out;
    }

    /// The Goal layer's own answer to "how relevant is this goal",
    /// as the β=0.40 term of `importance_score` should have used it.
    ///
    /// `Encoder.computeImportance` derives `goal_relevance` from the
    /// caller-supplied `relevance` field on the association and nothing
    /// else — the poset is never consulted, so the heaviest term in the
    /// constitutional formula is a number the caller typed and a
    /// tombstoned goal scores exactly like a live one. Fixing that
    /// belongs in `memory/encoder.zig`, which this module does not own;
    /// this is the Goal layer's answer, exposed so the call site can use
    /// it.
    pub fn goalRelevance(self: *const Store, goal_id: u64, stated: f32) f32 {
        const node = self.goals.get(goal_id) orelse return 0.0;
        return switch (node.status) {
            // A retired goal carries no priority (same rule the
            // reranker's `goalBonus` already applies).
            .tombstoned => 0.0,
            // Achieved: the goal still grounds its memories, but it is
            // no longer pulling the agent forward.
            .completed => stated * 0.5,
            // In flight outranks not-yet-started.
            .in_progress => @min(1.0, stated * 1.2),
            .pending, .failed, .unrealized => stated,
        };
    }

    // =================================================================
    // GHW observability
    // =================================================================

    /// The bounded cross-layer trail, oldest entry first.
    pub fn crossLayerLog(self: *const Store) *const ghw.CrossLayerLog {
        return &self.xlog;
    }

    /// Number of harnesses — i.e. GHW goals that have been encoded into.
    pub fn harnessCount(self: *const Store) usize {
        return self.harness.count();
    }

    /// Number of world entities — one per encoded goal.
    pub fn worldCount(self: *const Store) usize {
        return self.world.count();
    }

    /// The harness bound to a goal, or null when it has none yet.
    pub fn harnessForGoal(self: *const Store, goal_id: u64) ?u64 {
        return self.harness.harnessForGoal(goal_id);
    }

    /// The world entity holding a goal's situated state, or null.
    pub fn worldEntityForGoal(self: *const Store, goal_id: u64) ?u64 {
        var buf: [48]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "goal:{d}", .{goal_id}) catch return null;
        var it = self.world.entities.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.name, name)) return entry.value_ptr.*.id;
        }
        return null;
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

        // Goals.
        //
        // `SnapshotWriter.collectGoals` used to be a stub that emitted
        // nothing, so this loop had nothing to read and the poset was
        // rebuilt exclusively from WAL records. That made the WAL the
        // only copy of every user goal — and `takeSnapshot` deleted it
        // right after writing the snapshot, so a crash in that window
        // destroyed the poset permanently. The snapshot now carries the
        // goals, and this is the code that puts them back.
        //
        // `collectGoals` emits parents before children (breadth-first
        // from ⊥), so a single forward pass restores any tree the writer
        // saw. A row whose parent is missing is skipped rather than
        // re-parented, matching `applyGoalRecord`.
        var restored_goals: usize = 0;
        var failed_goals: usize = 0;
        var max_goal_id: u64 = 0;
        const goal_now = wallClockMs();
        for (data.goals) |gs| {
            if (gs.id == ghw_goal_tree.ROOT_GOAL_ID or gs.id == ghw_goal_tree.TOP_GOAL_ID) {
                diag("snapshot: goal row carries reserved id {d}, skipped", .{gs.id});
                continue;
            }
            if (gs.id > max_goal_id) max_goal_id = gs.id;
            if (self.goals.nodes.contains(gs.id)) continue;
            self.restoreGoalRow(gs, goal_now) catch |err| {
                diag("snapshot: goal id={d} not restored: {}", .{ gs.id, err });
                failed_goals += 1;
                continue;
            };
            restored_goals += 1;
        }
        if (restored_goals > 0 or failed_goals > 0) {
            std.log.info("WAL: snapshot restored {d} goals ({d} failed)", .{ restored_goals, failed_goals });
        }
        // The id counter must clear every id the snapshot claims, even
        // the ones that failed to restore, so a fresh create can never
        // mint an id an existing snapshot row already uses.
        if (max_goal_id > 0) _ = self.ids.fetchMax(max_goal_id + 1, .monotonic);

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

    /// Put one snapshot goal row back into the poset, under the id the
    /// row carries.
    ///
    /// Extracted from `loadSnapshot` so the parent/⊥ handling can be
    /// asserted directly: `GoalSnapshot.parent_id` is written as the
    /// API's "absent" form (`null`) when the live node hangs off ⊥, but
    /// a row may equally name ⊥ explicitly, and both must land in the
    /// same place — `GoalPoset.create` maps `null` to ⊥ itself, so
    /// passing the row's value through unchanged is correct for both.
    ///
    /// `deadline`, `created_at`, `updated_at` and `unrealized_at` are
    /// NOT in the snapshot record — see the note in `takeSnapshot`. A
    /// restored goal is therefore stamped with the restore time rather
    /// than `0`: `staleGoals` treats "no memcells for 7 days" as
    /// unrealizable, and a `0` stamp would make every goal restored from
    /// a snapshot immediately stale, i.e. the snapshot path would
    /// manufacture the very data loss it was added to prevent.
    fn restoreGoalRow(self: *Store, gs: GoalSnapshot, now_ms: i64) !void {
        // Same trick as `createGoal` / `applyGoalRecord`: a private
        // counter seeded to the id in the record, so the poset mints
        // exactly that id rather than a fresh one.
        var slot: std.atomic.Value(u64) = .init(gs.id);
        const created = self.goals.create(
            gs.name,
            gs.description,
            gs.parent_id,
            gs.priority,
            null,
            now_ms,
            &slot,
        ) catch |err| return err;
        if (created != gs.id) {
            diag("snapshot: goal id drift — row {d}, poset returned {d}", .{ gs.id, created });
            return error.GoalIdDrift;
        }
        if (gs.status != .pending) {
            self.goals.updateStatus(gs.id, gs.status, now_ms) catch |err| {
                // `.tombstoned` is refused by the poset's own transition
                // rule (it requires a ≥7-day `unrealized_at`, which the
                // snapshot does not carry), and WAL replay loses it the
                // same way. A snapshot is a point-in-time copy, so the
                // recorded status wins: silently resurrecting a retired
                // goal as `pending` is a worse answer than skipping a
                // state-machine check on data we just read off disk.
                diag("snapshot: goal id={d} status {s} refused by the poset ({}), restored verbatim", .{ gs.id, @tagName(gs.status), err });
                if (self.goals.get(gs.id)) |node_const| {
                    const node = @constCast(node_const);
                    node.status = gs.status;
                    node.updated_at = now_ms;
                }
            };
        }
    }

    /// Write a snapshot, then rotate the WAL.
    ///
    /// ## Order is the whole point
    ///
    /// 1. write the snapshot — goals included — to a temp file, `fsync`
    ///    it, and atomically `rename` it over `snapshot.bin`;
    /// 2. only then flush, close, `unlink` and re-create the WAL, and
    ///    re-journal the poset into it.
    ///
    /// Steps 2 used to be the ONLY place goals were persisted. The WAL
    /// was unlinked before the fresh one existed, so a crash anywhere in
    /// it destroyed the only copy of every user goal — permanently, since
    /// nothing else on disk had them. `SnapshotWriter.collectGoals` was
    /// the missing half of the fix: a stub that emitted zero rows, so
    /// `goals_count` was always 0. The durable copy is now in place
    /// before the WAL is touched, and the re-journal is belt-and-braces.
    ///
    /// ## Residual window (not closed, and it is not goal data)
    ///
    /// `rename(2)` is atomic, but making the renamed *directory entry*
    /// durable requires an `fsync` on the parent directory, and this
    /// codebase has no primitive for it: `platform_fs.open` rejects
    /// `.directory = true` on Windows, and there is no `syncDir`. So a
    /// power cut immediately after the rename can still surface the
    /// PREVIOUS snapshot on the next boot. That is a rollback, not a
    /// loss — the WAL still exists at that point (it is rotated
    /// afterwards) and the previous snapshot plus that WAL together
    /// describe every goal. What a cut during step 2 can lose is
    /// memcell inserts journaled since the previous snapshot, which was
    /// already true before this function was fixed.
    ///
    /// ## What the snapshot format cannot carry
    ///
    /// `GoalSnapshot` has room for (id, name, description, parent,
    /// status, priority) — no `deadline`, `created_at`, `updated_at` or
    /// `unrealized_at`. Changing that would alter the on-disk layout, so
    /// it is left alone: the re-journal below is what still preserves
    /// those four on a normal restart, and the snapshot path stamps the
    /// restore time. See `restoreGoalRow`.
    fn takeSnapshot(self: *Store) !void {
        var w = SnapshotWriter.init(self.alloc, self.snapshot_path);
        const bytes = w.write(
            self.ids.load(.monotonic),
            self.goals,
            self.mgr,
            &self.lc.fuzzy,
        ) catch |err| {
            std.log.warn("snapshot: write failed: {}", .{err});
            // Propagate. This used to `return` silently, which let
            // `POST /api/sync` answer 200 {"status":"synced"} even when no
            // snapshot reached disk — the caller had no way to tell
            // "synced" from "tried and failed". The daemon surfaces it as a
            // 500. It also leaves the WAL untouched, which is the safe
            // direction: a snapshot that failed to reach disk must not be
            // followed by a WAL truncation.
            return err;
        };
        std.log.info("snapshot: wrote {d} bytes to {s}", .{ bytes, self.snapshot_path });
        if (self.wal) |wal| {
            wal.flush() catch {};
            wal.deinit();
            self.alloc.destroy(wal);
            self.wal = null;
            var zbuf: [platform_fs.max_path_bytes + 1]u8 = undefined;
            const z = std.fmt.bufPrint(&zbuf, "{s}\x00", .{self.wal_path}) catch return;
            // `WAL.open` appends (O_APPEND) and never truncates, so the
            // old file must go before the fresh one is created — the
            // snapshot is already durable at this point, which is what
            // makes deleting the WAL safe.
            platform_fs.unlink(z[0 .. z.len - 1 :0].ptr) catch {};
            const wal_ptr = self.alloc.create(WAL) catch return;
            wal_ptr.* = WAL.init(self.alloc, self.wal_path) catch |err| {
                self.alloc.destroy(wal_ptr);
                diag("snapshot: fresh WAL init failed: {}", .{err});
                return;
            };
            wal_ptr.open() catch {
                wal_ptr.deinit();
                self.alloc.destroy(wal_ptr);
                diag("snapshot: fresh WAL open failed for {s}", .{self.wal_path});
                return;
            };
            self.wal = wal_ptr;
            // Redundant for durability now that the snapshot carries the
            // poset, but still worth emitting: it restores the four fields
            // the snapshot record has no room for, and it keeps the WAL
            // self-contained for any tool that replays it without a
            // snapshot. A partial failure here costs fidelity in the WAL
            // only; the snapshot copy is unaffected.
            const goal_stats = self.rejournalGoals(wal_ptr);
            self.rejournalHyperedges(wal_ptr);
            if (goal_stats.failed > 0) {
                diag("snapshot: {d}/{d} goal records failed to re-journal into the fresh WAL (the snapshot copy is unaffected)", .{ goal_stats.failed, goal_stats.attempted });
            }
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
            if (std.c.mkdir(zptr, platform_fs.default_dir_mode) == 0) continue;
            // `std.c.Stat` is `void` on Linux and Windows in Zig 0.17, and
            // its field is `mode` on Darwin but `st_mode` elsewhere.
            // Opening with O_DIRECTORY answers the same question with no
            // struct layout involved at all.
            const dir_flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true };
            const dir_fd = std.c.open(zptr, dir_flags, @as(std.c.mode_t, 0));
            if (dir_fd < 0) return error.DataDirNotADirectory;
            _ = std.c.close(dir_fd);
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

        const fd = platform_fs.open(wal_z_slice.ptr, .{ .access = .read_only }) catch -1;
        if (fd >= 0) {
            defer platform_fs.close(fd);
            // No `std.c.Stat`: it is `void` on Linux and Windows. `sizeOf`
            // does the same job with a seek and restores the read position,
            // so the read below still starts at offset 0.
            if (platform_fs.sizeOf(fd)) |sz| {
                const size: usize = @intCast(sz);
                if (size > 0) {
                    const buf = try self.alloc.alloc(u8, size);
                    defer self.alloc.free(buf);
                    const got = platform_fs.readFull(fd, buf) catch return error.WalReplayShortRead;
                    try existing.appendSlice(self.alloc, buf[0..got]);
                }
            } else |_| {}
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
                if (rec.record_type == .forget) {
                    // A forgetting sweep journals the id of every cell it
                    // transferred to the fuzzy store. Without this branch the
                    // `memcell_insert` record for that cell would replay and
                    // the memory would come back — while
                    // `mem3_forgotten_cells_total` still claimed it was gone.
                    if (rec.payload.len >= 8) {
                        const id = std.mem.readInt(u64, rec.payload[0..8], .little);
                        // `remove` hands back the pointer and frees nothing.
                        // Dropping it on the floor leaks the cell and every
                        // string it owns — and replay allocates these cells
                        // fresh, so they are ours to release.
                        if (ctx_ptr.store.mgr.remove(id)) |cell| {
                            cell.deinit(ctx_ptr.store.alloc);
                            ctx_ptr.store.alloc.destroy(cell);
                        }
                        _ = ctx_ptr.store.cell_index.remove(id);
                    }
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

    /// Outcome of one `rejournalGoals` pass. Returned rather than only
    /// logged so a caller can see — and a test can assert — exactly how
    /// much of the poset made it into the fresh WAL.
    pub const RejournalStats = struct {
        /// Non-synthetic goals visited. Equal to the poset size unless
        /// the queue itself could not be extended.
        attempted: usize = 0,
        /// Goals whose `goal_create` record reached the WAL.
        written: usize = 0,
        /// Individual operations that failed (encode or append, create or
        /// status). Counted, never silently swallowed.
        failed: usize = 0,
    };

    /// Re-emit every non-synthetic goal as a `goal_create` record into
    /// a freshly truncated WAL.
    ///
    /// Walks breadth-first from ⊥ so a parent is always journaled
    /// before its children; replay would otherwise drop a child whose
    /// parent has not been materialised yet.
    ///
    /// **Failure handling is per node.** This used to `return` out of
    /// the whole walk on an append failure, and to `continue` on a status
    /// encode failure — which skipped the `queue.append` below and so
    /// silently abandoned every descendant of that node. One unwritable
    /// record could therefore cost an entire subtree with no error
    /// anywhere but a log line. Now a failed node is counted and the
    /// walk continues: the worst case for one bad record is that one
    /// goal, not the branch below it.
    fn rejournalGoals(self: *Store, wal: *WAL) RejournalStats {
        var stats = RejournalStats{};
        var queue: std.ArrayList(u64) = .empty;
        defer queue.deinit(self.alloc);
        queue.append(self.alloc, ghw_goal_tree.ROOT_GOAL_ID) catch {
            diag("rejournalGoals: out of memory - goals not carried into the new WAL", .{});
            stats.failed += 1;
            return stats;
        };
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            for (self.goals.childrenOf(queue.items[head])) |child_id| {
                if (child_id == ghw_goal_tree.ROOT_GOAL_ID or child_id == ghw_goal_tree.TOP_GOAL_ID) continue;
                const node = self.goals.get(child_id) orelse continue;
                stats.attempted += 1;
                // `GoalPoset.create` stores ROOT as a concrete parent;
                // store it back as the API's "absent" form - the same
                // mapping `SnapshotWriter.collectGoals` makes, which is
                // what keeps the two replay paths in agreement.
                const parent_id: ?u64 = if (node.parent_id) |p|
                    (if (p == ghw_goal_tree.ROOT_GOAL_ID) null else p)
                else
                    null;

                // Note what is NOT here: there is no `continue` on the
                // failure branch. The descend at the bottom of the loop
                // has to run either way - a node we failed to journal
                // must not take its subtree with it. Replay drops a child
                // whose parent record is missing, so the cost is a little
                // wasted WAL space and nothing else.
                if (self.encodeGoalWALPayload(child_id, node.name, node.description, parent_id, node.priority, node.deadline, node.created_at)) |payload| {
                    defer self.alloc.free(payload);
                    const landed = blk: {
                        wal.append(.{
                            .record_type = .goal_create,
                            .payload = payload,
                            .timestamp = wallClockSec(),
                        }) catch |err| {
                            diag("rejournalGoals: append failed for goal {d}: {}", .{ child_id, err });
                            stats.failed += 1;
                            break :blk false;
                        };
                        break :blk true;
                    };
                    if (landed) stats.written += 1;
                } else |err| {
                    diag("rejournalGoals: encode failed for goal {d}: {}", .{ child_id, err });
                    stats.failed += 1;
                }

                // `goal_create` carries no status field, and
                // `GoalPoset.create` always starts at `.pending`. Without
                // this the snapshot truncation that `rejournalGoals`
                // exists to survive would silently reset every completed
                // or failed goal back to pending.
                if (node.status != .pending) {
                    if (self.encodeGoalUpdatePayload(child_id, node.status, node.updated_at)) |sp| {
                        defer self.alloc.free(sp);
                        wal.append(.{
                            .record_type = .goal_update,
                            .payload = sp,
                            .timestamp = wallClockSec(),
                        }) catch |err| {
                            diag("rejournalGoals: status append failed for goal {d}: {}", .{ child_id, err });
                            stats.failed += 1;
                        };
                    } else |err| {
                        diag("rejournalGoals: status encode failed for goal {d}: {}", .{ child_id, err });
                        stats.failed += 1;
                    }
                }

                queue.append(self.alloc, child_id) catch {
                    // Cannot descend without a slot in the queue. Counted
                    // like any other failure, and the walk continues with
                    // the siblings rather than abandoning them too.
                    diag("rejournalGoals: out of memory at depth {d} - subtree below goal {d} dropped", .{ head, child_id });
                    stats.failed += 1;
                    continue;
                };
            }
        }
        if (stats.written > 0) {
            std.log.info("rejournalGoals: re-emitted {d} goal records into the fresh WAL ({d} failed)", .{ stats.written, stats.failed });
        } else if (stats.attempted > 0) {
            diag("rejournalGoals: 0/{d} goal records reached the fresh WAL ({d} operations failed)", .{ stats.attempted, stats.failed });
        }
        return stats;
    }

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

};

// =============================================================================
// Helpers shared with the HTTP server
// =============================================================================

/// Append `v` unless already present. Keeps the GHW-resolved goal scope
/// from listing the same id twice when the caller already named it.
fn appendUnique(alloc: Allocator, list: *std.ArrayList(u64), v: u64) !void {
    for (list.items) |existing| {
        if (existing == v) return;
    }
    try list.append(alloc, v);
}

fn wallClockSec() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// Wall clock in milliseconds — the unit `created_at`, `updated_at` and
/// `unrealized_at` are expressed in throughout the data model.
fn wallClockMs() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
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

// =============================================================================
// GHW traversal tests (Principle II)
//
// These fail if the traversal is unwired. Each asserts an observable the
// unwired store cannot produce — a non-empty Harness layer, a non-empty
// World layer, a valid direction sequence, a bounded log, a goal-scoped
// rerank — rather than re-asserting an internal call was made.
// =============================================================================

test "Store: insert traverses Goal → Harness → World" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const gid = try store.createGoal("zig build", "compile the zig test binary", null, 9, null, 1_700_000_000_000);
    try std.testing.expectEqual(@as(usize, 0), store.harnessCount());
    try std.testing.expectEqual(@as(usize, 0), store.worldCount());

    const id = try store.addRaw(.matter, "the build finished cleanly", "a|b|c", gid, 0.8);

    // Both lower layers now hold state. Before this was wired, an insert
    // produced a cell and nothing else.
    try std.testing.expectEqual(@as(usize, 1), store.harnessCount());
    try std.testing.expectEqual(@as(usize, 1), store.worldCount());
    try std.testing.expect(store.harnessForGoal(gid) != null);
    try std.testing.expect(store.worldEntityForGoal(gid) != null);

    // The Goal layer holds the binding too, which is what the meta-goal
    // sweep reads. It used to never register any.
    try std.testing.expectEqual(@as(usize, 1), store.goals.memcellsFor(gid).len);
    try std.testing.expectEqual(id, store.goals.memcellsFor(gid)[0]);

    // Exactly two hops, in the constitutional order, each one legal.
    const xlog = store.crossLayerLog();
    try std.testing.expectEqual(@as(usize, 2), xlog.count());
    const e0 = xlog.nth(0).?;
    const e1 = xlog.nth(1).?;
    try std.testing.expect(e0.from == .goal and e0.to == .harness);
    try std.testing.expect(e0.direction == .outward);
    try std.testing.expect(e1.from == .harness and e1.to == .world);
    try std.testing.expect(e1.direction == .outward);
    try std.testing.expectEqual(id, e0.cell_id.?);
    try std.testing.expect(ghw.isValidDirection(e0.direction, e0.from, e0.to));
    try std.testing.expect(ghw.isValidDirection(e1.direction, e1.from, e1.to));

    // The world entity names the harness that realises it — the
    // back-reference retrieval reads to cross world→harness.
    const eid = store.worldEntityForGoal(gid).?;
    const hid = std.fmt.parseInt(u64, store.world.entityAttribute(eid, ghw.HARNESS_ATTR).?, 10) catch 0;
    try std.testing.expectEqual(store.harnessForGoal(gid).?, hid);
}

test "Store: many inserts against one goal keep the layers bounded" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const gid = try store.createGoal("throughput", "measure insert cost", null, 5, null, 1_700_000_000_000);
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        _ = try store.addRaw(.matter, "insert number with some content", "a|b|c", gid, 0.5);
    }

    // 64 memories, 1 goal: 1 harness, 1 world entity. Per-memory evidence
    // is a counter, so the daemon's memory does not track its corpus.
    try std.testing.expectEqual(@as(usize, 1), store.harnessCount());
    try std.testing.expectEqual(@as(usize, 1), store.worldCount());
    try std.testing.expectEqual(@as(u64, 64), store.harness.get(store.harnessForGoal(gid).?).?.execution_count);
    try std.testing.expectEqual(@as(usize, 64), store.goals.memcellsFor(gid).len);
}

test "Store: an insert naming no goal skips the traversal instead of faking one" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    // goal_id 0 is the synthetic root — the way "no goal" is spelled.
    _ = try store.addRaw(.matter, "unattached memory", "a|b|c", 0, 0.5);
    _ = try store.addRaw(.matter, "memory for a goal that does not exist", "a|b|c", 4242, 0.5);

    try std.testing.expectEqual(@as(usize, 2), store.cellCount());
    try std.testing.expectEqual(@as(usize, 0), store.harnessCount());
    try std.testing.expectEqual(@as(usize, 0), store.worldCount());
    try std.testing.expectEqual(@as(usize, 0), store.crossLayerLog().count());
}

test "Store: query traverses World → Harness → Goal and the goal scope ranks" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const wanted = try store.createGoal("astronomy", "observe the telescope and the stars", null, 9, null, 1_700_000_000_000);
    const other = try store.createGoal("gardening", "water the tomatoes and the basil", null, 3, null, 1_700_000_000_000);
    const wanted_cell = try store.addRaw(.matter, "the telescope tracked a distant galaxy", "s|p|g", wanted, 0.9);
    _ = try store.addRaw(.matter, "watered the tomatoes this evening", "w|t|e", other, 0.1);

    const before = store.crossLayerLog().count();
    const hits = try store.query(alloc, "telescope galaxy", .{ .topk = 5 });
    defer alloc.free(hits);
    try std.testing.expect(hits.len >= 1);

    // The reverse traversal ran, in the reverse order, and only after
    // the encode hops — 2 inward hops appended.
    const xlog = store.crossLayerLog();
    try std.testing.expectEqual(before + 2, xlog.count());
    const inward0 = xlog.nth(before).?;
    const inward1 = xlog.nth(before + 1).?;
    try std.testing.expect(inward0.from == .world and inward0.to == .harness and inward0.direction == .inward);
    try std.testing.expect(inward1.from == .harness and inward1.to == .goal and inward1.direction == .inward);
    try std.testing.expect(ghw.isValidDirection(inward0.direction, inward0.from, inward0.to));
    try std.testing.expect(ghw.isValidDirection(inward1.direction, inward1.from, inward1.to));

    // And the goal the traversal resolved is the one the query was about:
    // the reranker's goal bonus comes from the GHW layers, not from a
    // caller-supplied flag.
    try std.testing.expectEqual(wanted, inward1.cell_id.?);

    // It also actually reorders. "telescope galaxy" is dense-similar to
    // the astronomy episode and not to the gardening one, and the goal
    // bonus the traversal unlocked multiplies that further — the
    // astronomy cell has to come first.
    try std.testing.expectEqual(wanted_cell, hits[0].cell.id);
}

test "Store: the GHW goal scope changes the ranking, and nothing else does" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const a = try store.createGoal("alpha topic", "alpha", null, 5, null, 1_700_000_000_000);
    const b = try store.createGoal("beta topic", "beta", null, 5, null, 1_700_000_000_000);
    const id_a = try store.addRaw(.matter, "shared vocabulary about widgets", "w|is|g", a, 0.5);
    _ = try store.addRaw(.matter, "shared vocabulary about widgets", "w|is|g", b, 0.5);

    // The traversal resolves `alpha` from the query text alone.
    const hits = try store.query(alloc, "alpha topic", .{ .topk = 2 });
    defer alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    // `id_a` is the first insert and, with identical episode text, the
    // base scores tie; only the goal bonus separates them.
    try std.testing.expectEqual(id_a, hits[0].cell.id);
    try std.testing.expect(hits[0].final_score > hits[1].final_score);
}

test "Store: cross-layer log stays bounded under sustained traffic" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const gid = try store.createGoal("busy goal", "generate a lot of cross-layer traffic", null, 5, null, 1_700_000_000_000);
    const cap = store.crossLayerLog().cap;
    try std.testing.expect(cap > 0);

    // 2 hops per insert plus 2 per query. Drive well past the cap: an
    // append-only log would be a slow leak in every long-running daemon.
    var n: usize = 0;
    while (n < cap * 4) : (n += 1) {
        _ = try store.addRaw(.matter, "sustained traffic about the busy goal", "a|b|c", gid, 0.5);
    }
    const hits = try store.query(alloc, "busy goal", .{ .topk = 1 });
    defer alloc.free(hits);
    try std.testing.expect(hits.len >= 1);

    try std.testing.expectEqual(cap, store.crossLayerLog().count());
    try std.testing.expect(store.crossLayerLog().count() <= cap);
}

test "Store: GHW state is released across many encode/decode cycles" {
    const alloc = std.testing.allocator;
    const data_dir = "/tmp/mem3_test_store_ghw_cycles";
    wipeStoreDir(data_dir);
    defer wipeStoreDir(data_dir);

    // Run under `std.testing.allocator`, which fails the test on any
    // leak. Each cycle adds a goal, harnesses, world entities and a full
    // cross-layer log; a single un-released allocation shows up here.
    var cycle: usize = 0;
    while (cycle < 4) : (cycle += 1) {
        var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
        defer store.deinit();

        const gid = try store.createGoal("cycle goal", "prove the layers are released", null, 5, null, 1_700_000_000_000);
        var n: usize = 0;
        while (n < 8) : (n += 1) {
            _ = try store.addRaw(.matter, "cycle traffic", "a|b|c", gid, 0.5);
        }
        const hits = try store.query(alloc, "cycle goal", .{ .topk = 3 });
        defer alloc.free(hits);
        try store.sync();
    }
}

test "Store: goalRelevance consults the Goal layer, the bare relevance does not" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const gid = try store.createGoal("status probe", "check goal layer influence", null, 5, null, 1_700_000_000_000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), store.goalRelevance(gid, 0.7), 1e-6);

    // In flight outranks pending.
    try store.updateGoalStatus(gid, .in_progress, 1_700_000_000_000);
    try std.testing.expect(store.goalRelevance(gid, 0.7) > 0.7);

    // Achieved still grounds its memories, at half weight. (`completed`
    // is terminal, so it is the last state this goal can reach.)
    try store.updateGoalStatus(gid, .completed, 1_700_000_000_000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), store.goalRelevance(gid, 0.7), 1e-6);

    // Retired contributes nothing, whatever the caller claimed.
    const retired = try store.createGoal("retired probe", "tombstoned goals stop mattering", null, 5, null, 1_700_000_000_000);
    try store.updateGoalStatus(retired, .unrealized, 1_700_000_000_000);
    // Constitution III's 7-day grace: a goal cannot be retired the moment
    // it goes unrealized.
    try store.updateGoalStatus(retired, .tombstoned, 1_700_000_000_000 + 8 * 86_400_000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), store.goalRelevance(retired, 0.7), 1e-6);

    // A goal the poset never held contributes nothing, even when the
    // caller claims full relevance.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), store.goalRelevance(4242, 1.0), 1e-6);
}

test "Store: an illegal goal transition is rejected before it reaches the WAL" {
    const alloc = std.testing.allocator;
    const data_dir = "/tmp/mem3_test_store_transition";
    wipeStoreDir(data_dir);
    defer wipeStoreDir(data_dir);

    var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
    defer store.deinit();

    const gid = try store.createGoal("transition probe", "terminal states stay terminal", null, 5, null, 1_700_000_000_000);
    try store.updateGoalStatus(gid, .in_progress, 1_700_000_000_000);
    try store.updateGoalStatus(gid, .completed, 1_700_000_000_000);

    // `completed` is terminal. This used to be journaled, fsynced and
    // reported as a success.
    try std.testing.expectError(
        core.Error.GoalCycle,
        store.updateGoalStatus(gid, .pending, 1_700_000_000_001),
    );
    try std.testing.expectEqual(core.GoalStatus.completed, store.goals.get(gid).?.status);

    // A missing goal still fails, and fails before anything is written.
    try std.testing.expectError(
        core.Error.GoalNotFound,
        store.updateGoalStatus(9999, .pending, 1_700_000_000_000),
    );
}

test "Store: a replayed illegal transition is still applied" {
    // Replay must stay permissive: records written by older builds were
    // never validated, so rejecting them on the way back in would turn
    // a recoverable record into lost data.
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const gid = try store.createGoal("replay probe", "legacy record", null, 5, null, 1_700_000_000_000);
    try store.updateGoalStatus(gid, .in_progress, 1_700_000_000_000);
    try store.updateGoalStatus(gid, .completed, 1_700_000_000_000);

    const payload = Store.encodeGoalUpdatePayloadRaw(alloc, gid, .pending, 1_700_000_000_001) catch unreachable;
    defer alloc.free(payload);
    var counter: u64 = 0;
    store.applyGoalStatusRecord(payload, &counter);
    try std.testing.expectEqual(core.GoalStatus.pending, store.goals.get(gid).?.status);
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

// =============================================================================
// Snapshot-carried goal poset
//
// Before this set, `SnapshotWriter.collectGoals` was a stub: the snapshot
// held `goals_count = 0`, so `Store.takeSnapshot` unlinked the WAL and the
// poset existed nowhere except in records it was in the middle of
// rewriting. A crash in that window erased every user goal, permanently.
// These tests pin the closed window: the snapshot carries the poset, both
// replay paths rebuild the same tree, and a partial re-journal is counted
// rather than swallowed.
// =============================================================================

/// Pid-scoped scratch directory. The older persistence tests above use
/// fixed paths, which is fine for one binary but means a crashed run
/// leaves state that silently becomes the next run's input.
fn testDataDir(buf: []u8, name: []const u8) []const u8 {
    const pid: u64 = @intCast(std.c.getpid());
    return std.fmt.bufPrint(buf, "/tmp/mem3_test_{s}_{d}", .{ name, pid }) catch unreachable;
}

fn unlinkIfPresent(path: []const u8) void {
    var buf: [platform_fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}\x00", .{path})) |z| {
        platform_fs.unlink(z[0 .. z.len - 1 :0].ptr) catch {};
    } else |_| {}
}

/// Ids of a poset tree used by the round-trip tests. Six deep plus a
/// sibling off ⊥: deeper than any fixed-depth walk, and wide enough that
/// a queue which only follows one branch is caught.
const SeedTree = struct { chain: [6]u64, side: u64 };

fn seedGoalTree(store: *Store) !SeedTree {
    var ids: SeedTree = undefined;
    var parent: ?u64 = null;
    for (0..6) |i| {
        const name = try std.fmt.allocPrint(store.alloc, "level-{d}", .{i});
        defer store.alloc.free(name);
        const desc = try std.fmt.allocPrint(store.alloc, "depth {d} goal", .{i});
        defer store.alloc.free(desc);
        ids.chain[i] = try store.createGoal(name, desc, parent, @intCast(10 - i), null, 1_700_000_000_000 + @as(i64, @intCast(i)));
        parent = ids.chain[i];
    }
    ids.side = try store.createGoal("side", "hangs directly off root", null, 4, null, 1_700_000_999_999);
    // Non-pending statuses: `goal_create` has no status field, so this is
    // the part most likely to be silently reset to `pending`.
    try store.updateGoalStatus(ids.chain[2], .completed, 1_700_000_500_000);
    try store.updateGoalStatus(ids.chain[4], .in_progress, 1_700_000_600_000);
    return ids;
}

test "Store: goals survive a snapshot when the WAL is deleted" {
    const alloc = std.testing.allocator;
    var dir_buf: [128]u8 = undefined;
    const data_dir = testDataDir(&dir_buf, "goalsnap");
    wipeStoreDir(data_dir);
    defer wipeStoreDir(data_dir);

    const seeded = blk: {
        var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
        defer store.deinit();
        const ids = try seedGoalTree(store);
        try store.sync();
        break :blk ids;
    };

    // This is the defect, reproduced literally: the snapshot is on disk
    // and the WAL is not. `takeSnapshot` had already unlinked the WAL by
    // the time it finished, and the snapshot it had just written carried
    // no goals, so nothing on this disk described the poset.
    var wal_buf: [platform_fs.max_path_bytes + 1]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_buf, "{s}/mem3.wal", .{data_dir});
    unlinkIfPresent(wal_path);

    var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
    defer store.deinit();

    const goals = try store.listGoals(alloc);
    defer alloc.free(goals);
    try std.testing.expectEqual(@as(usize, 7), goals.len);

    var seen: usize = 0;
    for (goals) |g| {
        if (g.id == seeded.chain[0]) {
            // Created with `parent_id = null`, so ⊥-parented.
            try std.testing.expectEqual(ghw_goal_tree.ROOT_GOAL_ID, g.parent_id.?);
            try std.testing.expectEqualStrings("level-0", g.name);
            try std.testing.expectEqual(@as(u8, 10), g.priority);
            try std.testing.expectEqual(core.GoalStatus.pending, g.status);
            seen += 1;
        } else if (g.id == seeded.chain[2]) {
            try std.testing.expectEqual(seeded.chain[1], g.parent_id.?);
            try std.testing.expectEqualStrings("level-2", g.name);
            try std.testing.expectEqualStrings("depth 2 goal", g.description);
            try std.testing.expectEqual(core.GoalStatus.completed, g.status);
            seen += 1;
        } else if (g.id == seeded.chain[4]) {
            try std.testing.expectEqual(seeded.chain[3], g.parent_id.?);
            try std.testing.expectEqual(core.GoalStatus.in_progress, g.status);
            seen += 1;
        } else if (g.id == seeded.chain[5]) {
            // The deepest node: a walk that stops early loses exactly
            // this one, and nothing else would notice.
            try std.testing.expectEqual(seeded.chain[4], g.parent_id.?);
            try std.testing.expectEqualStrings("level-5", g.name);
            seen += 1;
        } else if (g.id == seeded.side) {
            try std.testing.expectEqual(ghw_goal_tree.ROOT_GOAL_ID, g.parent_id.?);
            try std.testing.expectEqualStrings("side", g.name);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), seen);

    // The parent links survived as structure, not just as fields: every
    // chain node is listed under its own parent.
    for (0..5) |i| {
        const parent = store.goals.childrenOf(seeded.chain[i]);
        try std.testing.expectEqual(@as(usize, 1), parent.len);
        try std.testing.expectEqual(seeded.chain[i + 1], parent[0]);
    }
}

test "Store: snapshot replay and WAL replay rebuild the same poset" {
    const alloc = std.testing.allocator;
    var wal_buf: [128]u8 = undefined;
    const wal_dir = testDataDir(&wal_buf, "eq_wal");
    var snap_buf: [128]u8 = undefined;
    const snap_dir = testDataDir(&snap_buf, "eq_snap");
    wipeStoreDir(wal_dir);
    wipeStoreDir(snap_dir);
    defer {
        wipeStoreDir(wal_dir);
        wipeStoreDir(snap_dir);
    }

    // Two stores, seeded identically. One is left to be rebuilt by WAL
    // replay; the other is snapshotted and has its WAL deleted, so it is
    // rebuilt by the snapshot alone. Both then report what is actually in
    // the poset.
    {
        var store = try Store.init(alloc, .{ .data_dir = wal_dir, .seed_default_goals = false });
        defer store.deinit();
        _ = try seedGoalTree(store);
    }
    {
        var store = try Store.init(alloc, .{ .data_dir = snap_dir, .seed_default_goals = false });
        defer store.deinit();
        _ = try seedGoalTree(store);
        try store.sync();
    }
    var wal_file: [platform_fs.max_path_bytes + 1]u8 = undefined;
    const snap_wal = try std.fmt.bufPrint(&wal_file, "{s}/mem3.wal", .{snap_dir});
    unlinkIfPresent(snap_wal);

    var wal_store = try Store.init(alloc, .{ .data_dir = wal_dir, .seed_default_goals = false });
    defer wal_store.deinit();
    var snap_store = try Store.init(alloc, .{ .data_dir = snap_dir, .seed_default_goals = false });
    defer snap_store.deinit();

    const a = try wal_store.listGoals(alloc);
    defer alloc.free(a);
    const b = try snap_store.listGoals(alloc);
    defer alloc.free(b);
    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expectEqual(@as(usize, 7), a.len);

    // `listGoals` walks a hash map, so match by id rather than by order.
    for (a) |wa| {
        var matched = false;
        for (b) |sb| {
            if (sb.id != wa.id) continue;
            matched = true;
            try std.testing.expectEqualStrings(wa.name, sb.name);
            try std.testing.expectEqualStrings(wa.description, sb.description);
            try std.testing.expectEqual(wa.parent_id, sb.parent_id);
            try std.testing.expectEqual(wa.status, sb.status);
            try std.testing.expectEqual(wa.priority, sb.priority);
            try std.testing.expectEqual(wa.memcell_count, sb.memcell_count);
            break;
        }
        try std.testing.expect(matched);
    }

    // The one field the two paths genuinely cannot agree on, stated
    // rather than papered over: `GoalSnapshot` has no `created_at` slot
    // (see `takeSnapshot`), so the snapshot path stamps the restore time
    // while the WAL path replays the recorded timestamp. Everything the
    // format does carry is asserted equal above.
    const wal_facts = try collectPosetFacts(wal_store, alloc);
    defer freePosetFacts(alloc, wal_facts);
    const snap_facts = try collectPosetFacts(snap_store, alloc);
    defer freePosetFacts(alloc, snap_facts);
    for (wal_facts) |wf| {
        try std.testing.expect(wf.created_at >= 1_700_000_000_000);
    }
    for (snap_facts) |sf| {
        try std.testing.expect(sf.created_at > 0);
    }
}

const PosetFact = struct {
    id: u64,
    parent_id: ?u64,
    status: core.GoalStatus,
    created_at: i64,
};

/// What the poset actually holds, for the one comparison that needs
/// `created_at` (which `GoalInfo` does not expose).
fn collectPosetFacts(store: *Store, alloc: Allocator) ![]PosetFact {
    var out: std.ArrayList(PosetFact) = .empty;
    errdefer out.deinit(alloc);
    var it = store.goals.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr.*;
        if (node.id == ghw_goal_tree.ROOT_GOAL_ID or node.id == ghw_goal_tree.TOP_GOAL_ID) continue;
        try out.append(alloc, .{
            .id = node.id,
            .parent_id = node.parent_id,
            .status = node.status,
            .created_at = node.created_at,
        });
    }
    return out.toOwnedSlice(alloc);
}

fn freePosetFacts(alloc: Allocator, facts: []PosetFact) void {
    alloc.free(facts);
}

test "Store: an empty poset survives a snapshot round trip" {
    const alloc = std.testing.allocator;
    var dir_buf: [128]u8 = undefined;
    const data_dir = testDataDir(&dir_buf, "emptysnap");
    wipeStoreDir(data_dir);
    defer wipeStoreDir(data_dir);

    {
        var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
        defer store.deinit();
        _ = try store.addRaw(.matter, "cell-with-no-goals", "a|b|c", 0, 0.5);
        try store.sync();
    }
    var wal_buf: [platform_fs.max_path_bytes + 1]u8 = undefined;
    const wal_path = try std.fmt.bufPrint(&wal_buf, "{s}/mem3.wal", .{data_dir});
    unlinkIfPresent(wal_path);

    var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
    defer store.deinit();
    const goals = try store.listGoals(alloc);
    defer alloc.free(goals);
    // Zero goals must read back as zero goals, not as "the writer never
    // got around to it".
    try std.testing.expectEqual(@as(usize, 0), goals.len);
    // The cell is still there, so the snapshot as a whole was read.
    try std.testing.expectEqual(@as(usize, 1), store.cellCount());
}

test "Store: a snapshot row parented at ⊥ and one parented at null land identically" {
    const alloc = std.testing.allocator;
    var store = try Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const now: i64 = 1_700_000_000_000;
    // `collectGoals` writes ⊥ as the API's "absent" form (null), but a
    // row may equally name ⊥ explicitly. Both must produce the same tree.
    try store.restoreGoalRow(.{
        .id = 11,
        .name = "parented-at-root",
        .description = "d",
        .parent_id = ghw_goal_tree.ROOT_GOAL_ID,
        .status = .pending,
        .priority = 3,
    }, now);
    try store.restoreGoalRow(.{
        .id = 12,
        .name = "parented-at-null",
        .description = "d",
        .parent_id = null,
        .status = .pending,
        .priority = 3,
    }, now);

    try std.testing.expectEqual(@as(usize, 2), store.goals.childrenOf(ghw_goal_tree.ROOT_GOAL_ID).len);
    try std.testing.expectEqual(ghw_goal_tree.ROOT_GOAL_ID, store.goals.get(11).?.parent_id.?);
    try std.testing.expectEqual(ghw_goal_tree.ROOT_GOAL_ID, store.goals.get(12).?.parent_id.?);

    // And a child of either is still a child, not flattened to ⊥.
    try store.restoreGoalRow(.{
        .id = 13,
        .name = "child-of-11",
        .description = "d",
        .parent_id = 11,
        .status = .pending,
        .priority = 1,
    }, now);
    const kids = store.goals.childrenOf(11);
    try std.testing.expectEqual(@as(usize, 1), kids.len);
    try std.testing.expectEqual(@as(u64, 13), kids[0]);

    // A recorded non-pending status survives the restore, and a
    // `.tombstoned` one — which `updateStatus` refuses outright — is
    // written back verbatim rather than reset to `pending`.
    try store.restoreGoalRow(.{
        .id = 14,
        .name = "retired",
        .description = "d",
        .parent_id = null,
        .status = .tombstoned,
        .priority = 2,
    }, now);
    try std.testing.expectEqual(core.GoalStatus.tombstoned, store.goals.get(14).?.status);
}

test "Store: a mid-tree re-journal failure does not abandon the rest of the poset" {
    const alloc = std.testing.allocator;
    var dir_buf: [128]u8 = undefined;
    const data_dir = testDataDir(&dir_buf, "rejfail");
    wipeStoreDir(data_dir);
    defer wipeStoreDir(data_dir);

    var store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = false });
    defer store.deinit();
    const ids = try seedGoalTree(store);
    const wal = store.wal.?;

    // Happy path first: the counters have to mean something, and a test
    // that only ever sees failures cannot tell "counted correctly" from
    // "always counting".
    const clean = store.rejournalGoals(wal);
    try std.testing.expectEqual(@as(usize, 7), clean.attempted);
    try std.testing.expectEqual(@as(usize, 7), clean.written);
    try std.testing.expectEqual(@as(usize, 0), clean.failed);

    // Now break allocation partway through. `FailingAllocator` keeps
    // failing once it trips (its index stops advancing), so every encode
    // from here on fails — which is the point: the old code `continue`d
    // past the failed node without queueing it, so it never descended
    // and every descendant of the first goal was silently abandoned.
    // The queue itself still grows (ArrayList growth is a `resize`,
    // which this allocator leaves alone), so the walk can and must
    // continue.
    const real_alloc = store.alloc;
    var failing = std.testing.FailingAllocator.init(real_alloc, .{ .fail_index = 1 });
    store.alloc = failing.allocator();
    const broken = store.rejournalGoals(wal);
    store.alloc = real_alloc;

    try std.testing.expectEqual(@as(usize, 7), broken.attempted);
    try std.testing.expectEqual(@as(usize, 0), broken.written);
    try std.testing.expect(broken.failed > 0);

    // `attempted == 7` is the assertion that distinguishes this from the
    // old walk: chain[1] is reachable only by descending through
    // chain[0], and the old failure path never queued chain[0], so it
    // could not have reported 7 however many siblings ⊥ had.
    //
    // The rest is the observable that matters beyond the counter — a
    // failed re-journal must not mutate the poset it is copying.
    try std.testing.expectEqual(@as(usize, 7), store.goals.count());
    for (ids.chain[0..5]) |parent_id| {
        const kids = store.goals.childrenOf(parent_id);
        try std.testing.expectEqual(@as(usize, 1), kids.len);
    }
}
