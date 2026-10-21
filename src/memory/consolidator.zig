//! Hierarchical Agglomerative Clustering (HAC) for memory consolidation.
//!
//! **GHW Layer**: Memory (三源合恰). Implements the Consolidation stage
//! of the four-stage lifecycle (per the paper §4.3.3).
//!
//! ## Algorithm
//!
//! HAC works in three steps:
//! 1. Compute pairwise C_MF (matter-form coherence) between cells. (C_MF
//!    is the only pairwise that uses BOTH cells' content directly; C_FS
//!    and C_SM are intra-cell.)
//! 2. Single-linkage cluster: cells with C_MF ≥ threshold are merged
//!    into clusters.
//! 3. For each cluster of size ≥ 2, generate an abstract cell that
//!    captures the common token vocabulary. The abstract is added
//!    to the manager as a NEW cell (the originals are kept per the
//!    PCR rule).
//!
//! ## Incremental, not all-pairs
//!
//! Step 2 used to compare every cell pair on every pass: O(n²), measured
//! at 20.3 s per pass at 44,909 cells. The clustering state now lives in
//! `ClusterIndex` (see `cluster_index.zig` for the invariant, the removal
//! rule and the invalidation rule) and survives between passes, so a pass
//! compares only the cells that arrived since the last one. The partition
//! is identical to the full recompute's; that equivalence is the contract
//! and `tests/unit/consolidator_incremental.zig` holds it against an
//! independent O(n²) oracle.
//!
//! **Ownership**: a `Consolidator` owns its `ClusterIndex`. Whoever owns
//! the `Consolidator` calls `deinit` (`Store.deinit` does). A process that
//! consolidates once, like the `mem3 consolidate` CLI, has an empty index
//! and therefore does one full pass — the same work as before.
//!
//! **Constitution compliance**:
//! - Principle III (存在增益驱动): consolidation is the
//!   "comprehension" phase — abstract knowledge has higher
//!   existence-gain than individual instances.
//! - PCR: never delete originals. New abstract cell coexists.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const TriSourceManager = @import("tri_source_manager.zig").TriSourceManager;
const FuzzyStore = @import("forgetter.zig").FuzzyStore;
const coherence_mod = @import("coherence.zig");
const CoherenceCalculator = coherence_mod.CoherenceCalculator;
const cluster_index = @import("cluster_index.zig");
const ClusterIndex = cluster_index.ClusterIndex;
const config = @import("../core/config.zig").Config;
const time = @import("../utils/time.zig");

/// The token signature and the hash that backs it, re-exported so tests
/// and tools can build an oracle without reaching into a second module.
pub const Signature = cluster_index.Signature;
pub const signatureOf = cluster_index.signatureOf;
pub const SyncStats = cluster_index.SyncStats;

/// C_MF threshold for cluster inclusion. Default 0.75 — three quarters of
/// the matter-form tokens must overlap. Tunable via `Config.consolidation_threshold`.
pub const Consolidator = struct {
    alloc: Allocator,
    cfg: config,
    fuzzy: *FuzzyStore,
    mgr: *TriSourceManager,
    coherence: CoherenceCalculator,
    /// Clustering state carried between passes. See `cluster_index.zig`.
    index: ClusterIndex,
    /// The manager `index` was built from. A different manager means the
    /// cached ids describe another cell set entirely, so the index is
    /// dropped. `Lifecycle` builds a `Consolidator` with `undefined`
    /// pointers and patches them in `wire`, so this is checked at use, not
    /// at `init`.
    indexed_mgr: ?*const TriSourceManager = null,

    pub const PartitionEntry = cluster_index.PartitionEntry;

    pub fn init(alloc: Allocator, cfg: config, fuzzy: *FuzzyStore, mgr: *TriSourceManager) Consolidator {
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .fuzzy = fuzzy,
            .mgr = mgr,
            .coherence = CoherenceCalculator.init(alloc),
            .index = ClusterIndex.init(alloc),
        };
    }

    /// Free the cluster index. Safe on a consolidator that never ran.
    pub fn deinit(self: *Consolidator) void {
        self.index.deinit();
    }

    /// Forget everything cached. The next pass compares every pair.
    pub fn invalidate(self: *Consolidator) void {
        self.index.clear();
        self.indexed_mgr = null;
    }

    /// Number of cells currently held in the cluster index.
    pub fn cachedCells(self: *const Consolidator) usize {
        return self.index.live_count;
    }

    /// Heap bytes the cluster index holds, by capacity. An estimate for
    /// the hash-map share; see `ClusterIndex.bytesHeld`.
    pub fn cacheBytes(self: *const Consolidator) usize {
        return self.index.bytesHeld();
    }

    /// `{id, label}` for every cell in the index, ascending by id, where
    /// `label` is the lowest id of the cell's cluster. Reflects the last
    /// `refresh` / `consolidate`; caller owns the slice.
    pub fn partition(self: *Consolidator, alloc: Allocator) ![]PartitionEntry {
        return self.index.partition(alloc);
    }

    pub const ConsolidationResult = struct {
        clusters: usize,
        abstracts_created: usize,
        cells_processed: usize,
        /// Ids of the abstract cells this run inserted, so the caller
        /// can index and journal them.
        ///
        /// The consolidator owns no index and no WAL — it inserts
        /// straight into the TriSourceManager. That meant every abstract
        /// it produced landed in a store the retrieval path cannot see:
        /// not in `cell_index`, not embedded into HNSW, not in the WAL.
        /// Measured before the fix: consolidate reported
        /// `abstracts_created=1, cells: 6 -> 7` while `dump` still
        /// listed 6 records and `query` could not retrieve any of them.
        /// Caller owns the slice; free with `deinitAbstractIds`.
        abstract_ids: []u64 = &.{},

        /// Jaccard evaluations this pass performed. The all-pairs pass
        /// paid `cells_processed × (cells_processed − 1) / 2` every time.
        pair_comparisons: u64 = 0,
        /// Cells that entered the cluster index this pass (all of them on
        /// a full recompute).
        cells_new: usize = 0,
        /// Cells that left it: forgotten, fuzzied, or replaced.
        cells_removed: usize = 0,
        /// Clusters whose pairs had to be re-evaluated because a member
        /// left. See the removal rule in `cluster_index.zig`.
        clusters_rebuilt: usize = 0,
        /// True when the index was empty or the threshold had changed.
        full_recompute: bool = false,

        pub fn deinitAbstractIds(self: *ConsolidationResult, alloc: Allocator) void {
            if (self.abstract_ids.len > 0) alloc.free(self.abstract_ids);
            self.abstract_ids = &.{};
        }
    };

    /// Bring the cluster index up to date with the manager and report what
    /// that took, without generating any abstract. `consolidate` does this
    /// first; it is public so the clustering can be observed (and tested)
    /// without the side effect of inserting cells.
    pub fn refresh(self: *Consolidator) !SyncStats {
        var cells = try self.collectCells();
        defer cells.deinit(self.alloc);
        return self.syncIndex(cells.items);
    }

    /// Every live cell, in unspecified order. The three sources are
    /// `AutoHashMap`s and hash-map iteration order is unspecified;
    /// everything downstream that cares about order sorts by id.
    fn collectCells(self: *Consolidator) !std.ArrayList(*MemCell) {
        var cells = std.ArrayList(*MemCell).empty;
        errdefer cells.deinit(self.alloc);
        try cells.ensureTotalCapacity(self.alloc, self.mgr.count());
        var it_s = self.mgr.sensory.iterator();
        while (it_s.next()) |e| cells.appendAssumeCapacity(e.value_ptr.*);
        var it_c = self.mgr.cognitive.iterator();
        while (it_c.next()) |e| cells.appendAssumeCapacity(e.value_ptr.*);
        var it_a = self.mgr.action.iterator();
        while (it_a.next()) |e| cells.appendAssumeCapacity(e.value_ptr.*);
        return cells;
    }

    fn syncIndex(self: *Consolidator, cells: []const *MemCell) !SyncStats {
        if (self.indexed_mgr != self.mgr) {
            self.index.clear();
            self.indexed_mgr = self.mgr;
        }
        return self.index.sync(cells, self.cfg.consolidation_threshold);
    }

    /// Run HAC over the manager's cells. Threshold comes from cfg.
    /// Returns counts; does not return the abstract cells (those are
    /// stored in the manager and can be queried by source/.form).
    ///
    /// Determinism: the result is a pure function of the cell set. The
    /// index orders cells by id, so a cluster's representative is its
    /// lowest-id member, clusters are visited in ascending order of that
    /// id, and abstract ids are minted in that order. Hash-map iteration
    /// order never reaches the output.
    pub fn consolidate(self: *Consolidator) !ConsolidationResult {
        var cells = try self.collectCells();
        defer cells.deinit(self.alloc);
        const n = cells.items.len;

        const stats = try self.syncIndex(cells.items);
        var result: ConsolidationResult = .{
            .clusters = 0,
            .abstracts_created = 0,
            .cells_processed = n,
            .pair_comparisons = stats.pair_comparisons,
            .cells_new = stats.cells_new,
            .cells_removed = stats.cells_removed,
            .clusters_rebuilt = stats.clusters_rebuilt,
            .full_recompute = stats.full_recompute,
        };
        if (n < 2) return result;

        var groups = try self.index.groups(self.alloc);
        defer groups.deinit(self.alloc);
        result.clusters = groups.clusterCount();

        var abstract_ids: std.ArrayList(u64) = .empty;
        defer abstract_ids.deinit(self.alloc);

        for (0..groups.clusterCount()) |k| {
            const members = groups.members(k);
            if (members.len < 2) continue;

            // The abstract's vocabulary is the union of the members'
            // token buckets, which is the OR of their cached signatures —
            // no member is re-tokenized.
            var common: Signature = @splat(0);
            var max_importance: f32 = 0.0;
            for (members) |slot| {
                const sig = self.index.signatureAt(slot);
                for (0..common.len) |w| common[w] |= sig[w];
                if (self.mgr.get(self.index.idOf(slot))) |c| {
                    if (c.metadata.importance_score > max_importance) max_importance = c.metadata.importance_score;
                }
            }
            const rep = self.mgr.get(self.index.idOf(members[0])) orelse continue;
            if (try self.generateAbstract(rep, &common, max_importance)) |aid| {
                try abstract_ids.append(self.alloc, aid);
                result.abstracts_created += 1;
            }
        }

        // Already ascending, because clusters are visited in ascending
        // order of lowest id and ids are minted as we go. The sort is cheap
        // and keeps the guarantee local to this function rather than
        // dependent on the visit order above.
        const ids_out = try abstract_ids.toOwnedSlice(self.alloc);
        std.mem.sort(u64, ids_out, {}, std.sort.asc(u64));
        result.abstract_ids = ids_out;
        return result;
    }

    /// Generate an abstract cell that captures the common vocabulary
    /// of the cluster. Uses matter + form fields from a representative
    /// cell (the lowest-id member) and its foresight + goals.
    /// Returns the id of the abstract it inserted, so the caller can
    /// index and journal it.
    ///
    /// `common` is the OR of every member's token signature.
    fn generateAbstract(self: *Consolidator, rep: *const MemCell, common: *const Signature, max_importance: f32) !?u64 {
        const alloc = self.alloc;

        // Build abstract text: the representative's episode, filtered to
        // the tokens whose hash-bucket is set in `common`. (Since `rep` is
        // itself a member, all of its own tokens pass; the filter is kept
        // because it is the documented contract, and it makes the abstract
        // independent of how the rep was chosen.)
        var abstract_text = std.ArrayList(u8).empty;
        defer abstract_text.deinit(alloc);
        var split_it = std.mem.splitScalar(u8, rep.episode, ' ');
        while (split_it.next()) |tok| {
            if (tok.len == 0) continue;
            var buf: [64]u8 = undefined;
            var bl: usize = 0;
            for (tok) |c| {
                const lc: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
                if (lc >= 'a' and lc <= 'z' or lc >= '0' and lc <= '9') {
                    if (bl < buf.len) {
                        buf[bl] = lc;
                        bl += 1;
                    }
                }
            }
            if (bl == 0) continue;
            const h = std.hash.XxHash3.hash(0, buf[0..bl]);
            const bucket: usize = @intCast(h % coherence_mod.MAX_TRACKED_TOKENS);
            if (common[bucket / 64] & (@as(u64, 1) << @intCast(bucket % 64)) != 0) {
                if (abstract_text.items.len > 0) try abstract_text.append(alloc, ' ');
                try abstract_text.appendSlice(alloc, buf[0..bl]);
            }
        }

        // Build abstract: source=.form (abstracts ARE form), episode =
        // the common vocabulary, atomic_facts = none, foresight =
        // representative foresight, goals = representative goals.
        // importance = max of cluster members (abstracts represent the
        // cluster's value).
        const now = time.nowMs();
        const cell_ptr = try alloc.create(MemCell);
        errdefer alloc.destroy(cell_ptr);
        cell_ptr.* = .{
            .id = self.mgr.next_id.fetchAdd(1, .monotonic),
            .source = .form,
            .episode = try alloc.dupe(u8, abstract_text.items),
            .atomic_facts = &.{},
            .foresight = try cloneForesights(alloc, rep.foresight),
            .goal_associations = try cloneGoals(alloc, rep.goal_associations),
            .metadata = .{
                .created_at = now,
                .updated_at = now,
                .source_confidence = 1.0,
                .emotional_valence = 0.0,
                .location = null,
                .access_count = 0,
                .last_accessed_at = now,
                .coherence_score = 1.0, // abstract IS coherent
                .importance_score = max_importance,
                .decay_rate = 0.005, // abstracts decay slower
                .is_fuzzy = false,
                .superseded_at = null,
            },
        };
        // Snapshot the slices we own so we can free them AFTER mgr has
        // duped them. mgr.addWithId takes the cell by value (it dups
        // every owned slice inside); the local cell_ptr's heap slices
        // are still ours and must be freed explicitly.
        const own_episode = cell_ptr.episode;
        const own_foresight = cell_ptr.foresight;
        const own_goals = cell_ptr.goal_associations;
        defer {
            alloc.free(own_episode);
            for (own_foresight) |f| alloc.free(@constCast(f.description));
            alloc.free(own_foresight);
            alloc.free(own_goals);
        }
        _ = self.mgr.addWithId(cell_ptr.id, cell_ptr.*) catch |err| {
            // On duplicate id (extremely unlikely), drop the abstract
            // silently. The errdefer above frees cell_ptr; the
            // defer above frees the slices.
            std.log.warn("consolidator: addWithId failed: {}", .{err});
            return null;
        };
        // mgr.addWithId dups all owned slices (episode, atomic_facts,
        // etc.); the local cell_ptr is no longer needed.
        const cell_id = cell_ptr.id;
        alloc.destroy(cell_ptr);
        return cell_id;
    }
};

/// Length-prefixed clone of foresight descriptions.
fn cloneForesights(alloc: Allocator, src: []const core.Foresight) ![]core.Foresight {
    var out = try alloc.alloc(core.Foresight, src.len);
    errdefer alloc.free(out);
    for (src, 0..) |f, i| {
        out[i] = .{
            .description = try alloc.dupe(u8, f.description),
            .valid_from = f.valid_from,
            .valid_until = f.valid_until,
            .confidence = f.confidence,
        };
    }
    return out;
}

fn cloneGoals(alloc: Allocator, src: []const core.GoalAssociation) ![]core.GoalAssociation {
    return alloc.dupe(core.GoalAssociation, src);
}

// =============================================================================
// Tests
// =============================================================================

test "Consolidator: two similar cells → 1 abstract" {
    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(std.testing.allocator, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(std.testing.allocator);
    defer fuzzy.deinit();
    var con = Consolidator.init(std.testing.allocator, .{ .consolidation_threshold = 0.3 }, &fuzzy, &mgr);
    defer con.deinit();

    const a: MemCell = .{
        .id = 0, .source = .matter,
        .episode = "the cat sat on the mat",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.5, .priority = 1 },
        },
        .metadata = .{ .source_confidence = 0.9, .importance_score = 0.5 },
    };
    const b: MemCell = .{
        .id = 0, .source = .matter,
        .episode = "the cat lay on the mat",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.5, .priority = 1 },
        },
        .metadata = .{ .source_confidence = 0.9, .importance_score = 0.5 },
    };
    _ = try mgr.add(a);
    _ = try mgr.add(b);

    var result = try con.consolidate();
    defer result.deinitAbstractIds(std.testing.allocator);
    try std.testing.expect(result.abstracts_created >= 1);
    try std.testing.expect(result.cells_processed == 2);
    // The abstract cell should be in the manager now.
    try std.testing.expect(mgr.count() >= 3);
}

test "Consolidator: no cluster when cells too dissimilar" {
    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(std.testing.allocator, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(std.testing.allocator);
    defer fuzzy.deinit();
    var con = Consolidator.init(std.testing.allocator, .{ .consolidation_threshold = 0.9 }, &fuzzy, &mgr);
    defer con.deinit();

    const a: MemCell = .{
        .id = 0, .source = .matter,
        .episode = "completely unrelated content xyz",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.5, .priority = 1 },
        },
        .metadata = .{ .source_confidence = 0.9, .importance_score = 0.5 },
    };
    const b: MemCell = .{
        .id = 0, .source = .matter,
        .episode = "another totally different abc def",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.5, .priority = 1 },
        },
        .metadata = .{ .source_confidence = 0.9, .importance_score = 0.5 },
    };
    _ = try mgr.add(a);
    _ = try mgr.add(b);
    var result = try con.consolidate();
    defer result.deinitAbstractIds(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.abstracts_created);
}

test "Consolidator: output depends on the cell set, not on insertion order" {
    // The same nine cells, added in two different orders into two
    // independent managers, must produce the same abstracts.
    //
    // Before the id sort in `consolidate`, `cells` came straight out of
    // three `AutoHashMap` iterators whose order is unspecified and shifts
    // with capacity and rehash history. `generateAbstract` takes
    // `indices[0]` as the cluster representative, so the iteration order
    // chose which episode became the abstract's text. This test is the
    // regression guard for that.
    const alloc = std.testing.allocator;
    // Laid out so that one cluster's members sit at indices 0, 3 and 8,
    // which is what makes this test discriminate. `AutoHashMap` with ids
    // 1000..1008 iterates as 1006 1007 1001 1000 ... when filled forwards
    // and 1006 1007 1001 1003 ... when filled backwards, so that cluster's
    // first-seen member is id 1000 one way and id 1003 the other. Any two
    // clusters would do as long as the members straddle those positions.
    //
    // Three groups with no vocabulary in common, each sharing five of six
    // tokens within the group, so at threshold 0.3 they cluster cleanly and
    // never merge with each other.
    const episodes = [_][]const u8{
        "cat mat sat on the rug",        // 0  cluster A
        "kube deploy cluster node pool", // 1  cluster B
        "kube deploy cluster node zone", // 2  cluster B
        "cat mat lay on the rug",        // 3  cluster A
        "standup team weekday morning",  // 4  cluster C
        "standup team weekday evening",  // 5  cluster C
        "standup team weekday noon",     // 6  cluster C
        "standup team weekday dawn",     // 7  cluster C
        "cat mat rest on a rug",         // 8  cluster A
    };

    var forward_buf: [512]u8 = undefined;
    var reverse_buf: [512]u8 = undefined;
    const forward = try consolidateEpisodes(alloc, &episodes, false, &forward_buf);
    const reverse = try consolidateEpisodes(alloc, &episodes, true, &reverse_buf);

    // Both runs must actually have produced something, or this asserts
    // nothing: two empty strings are equal for the wrong reason.
    try std.testing.expect(forward.len > 0);
    try std.testing.expect(reverse.len > 0);
    try std.testing.expectEqualStrings(forward, reverse);
}

/// Consolidate `episodes` (optionally reversed) and flatten the resulting
/// abstracts' episodes into `buf`, so two runs can be compared as bytes.
fn consolidateEpisodes(
    alloc: std.mem.Allocator,
    episodes: []const []const u8,
    reverse: bool,
    buf: []u8,
) ![]const u8 {
    var ids = std.atomic.Value(u64).init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(alloc);
    defer fuzzy.deinit();
    var con = Consolidator.init(alloc, .{ .consolidation_threshold = 0.3 }, &fuzzy, &mgr);
    defer con.deinit();

    for (episodes, 0..) |_, i| {
        const at = if (reverse) episodes.len - 1 - i else i;
        // Pin the id to the content, not to the insertion position. Ids are
        // assigned once and never move in a real store, so "the same cells"
        // has to mean the same id-to-content mapping in both managers —
        // otherwise this compares two different stores rather than two
        // orders of one store.
        //
        // Offset from 1 because `generateAbstract` mints ids from the same
        // `next_id` counter this bypasses, and a low id here would collide
        // with an abstract and silently drop it.
        _ = try mgr.addWithId(@intCast(1000 + at), .{
            .id = 0,
            .source = .matter,
            .episode = episodes[at],
            .atomic_facts = &.{},
            .foresight = &.{},
            .goal_associations = &.{.{ .goal_id = 1, .relevance = 0.5, .priority = 1 }},
            .metadata = .{ .source_confidence = 0.9, .importance_score = 0.5 },
        });
    }

    var result = try con.consolidate();
    defer result.deinitAbstractIds(alloc);
    var out: usize = 0;
    for (result.abstract_ids) |aid| {
        const cell = mgr.get(aid) orelse continue;
        for (cell.episode) |byte| {
            if (out == buf.len) return error.BufferTooSmall;
            buf[out] = byte;
            out += 1;
        }
        if (out == buf.len) return error.BufferTooSmall;
        buf[out] = '|';
        out += 1;
    }
    return buf[0..out];
}
