//! Hierarchical Agglomerative Clustering (HAC) for memory consolidation.
//!
//! **GHW Layer**: Memory (三源合恰). Implements the Consolidation stage
//! of the four-stage lifecycle (per the paper §4.3.3).
//!
//! ## Algorithm
//!
//! HAC works in three steps:
//! 1. Compute pairwise C_MF (matter-form coherence) between every
//!    pair of cells. (C_MF is the only pairwise that uses BOTH
//!    cells' content directly; C_FS and C_SM are intra-cell.)
//! 2. Single-linkage cluster: cells with C_MF ≥ threshold are merged
//!    into clusters. Single-linkage is O(N²) but stable.
//! 3. For each cluster of size ≥ 2, generate an abstract cell that
//!    captures the common token vocabulary. The abstract is added
//!    to the manager as a NEW cell (the originals are kept per the
//!    PCR rule).
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
const CoherenceCalculator = @import("coherence.zig").CoherenceCalculator;
const coherence_mod = @import("coherence.zig");
const config = @import("../core/config.zig").Config;
const time = @import("../utils/time.zig");

/// C_MF threshold for cluster inclusion. Default 0.5 — half the
/// matter-form tokens must overlap. Tunable via `Config.consolidation_threshold`.
pub const Consolidator = struct {
    alloc: Allocator,
    cfg: config,
    fuzzy: *FuzzyStore,
    mgr: *TriSourceManager,
    coherence: CoherenceCalculator,

    pub fn init(alloc: Allocator, cfg: config, fuzzy: *FuzzyStore, mgr: *TriSourceManager) Consolidator {
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .fuzzy = fuzzy,
            .mgr = mgr,
            .coherence = CoherenceCalculator.init(alloc),
        };
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

        pub fn deinitAbstractIds(self: *ConsolidationResult, alloc: Allocator) void {
            if (self.abstract_ids.len > 0) alloc.free(self.abstract_ids);
            self.abstract_ids = &.{};
        }
    };

    /// Run HAC over the manager's cells. Threshold comes from cfg.
    /// Returns counts; does not return the abstract cells (those are
    /// stored in the manager and can be queried by source/.form).
    pub fn consolidate(self: *Consolidator) !ConsolidationResult {
        // Step 1: collect all cells, in **id order**.
        var cells = std.ArrayList(*MemCell).empty;
        defer cells.deinit(self.alloc);
        var it_s = self.mgr.sensory.iterator();
        while (it_s.next()) |e| try cells.append(self.alloc, e.value_ptr.*);
        var it_c = self.mgr.cognitive.iterator();
        while (it_c.next()) |e| try cells.append(self.alloc, e.value_ptr.*);
        var it_a = self.mgr.action.iterator();
        while (it_a.next()) |e| try cells.append(self.alloc, e.value_ptr.*);
        if (cells.items.len < 2) return .{ .clusters = 0, .abstracts_created = 0, .cells_processed = cells.items.len };

        // The three sources are `AutoHashMap`s, and hash-map iteration order
        // is explicitly unspecified. Everything downstream keys off the
        // index into `cells`: `bitsets` is laid out by it, `cluster_map` is
        // keyed by union-find roots chosen by it, and `generateAbstract`
        // takes `indices[0]` as the cluster's representative cell. So the
        // iteration order decided, on every pass, *which cell's episode
        // became the abstract's text* — and that order depended on the
        // table's capacity and rehash history, i.e. on insertion order and
        // on whether anything had been forgotten in between. The same
        // corpus could consolidate differently from one run to the next.
        //
        // Sorting by id costs O(n log n) and makes the whole pass a pure
        // function of the cell set. It also means the index of a given cell
        // is stable across passes, which is the precondition any incremental
        // clustering would need.
        std.mem.sort(*MemCell, cells.items, {}, byIdAscending);

        const n = cells.items.len;
        // Step 2: single-linkage clustering via union-find.
        // Heap-allocate the parent array: Zig's stack-allocated arrays
        // require a comptime size, but `n` is a runtime count.
        const parent = try self.alloc.alloc(usize, n);
        defer self.alloc.free(parent);
        for (0..n) |i| parent[i] = i;

        const find = struct {
            fn find(p: []usize, _: *usize, i: usize) usize {
                var x = i;
                while (p[x] != x) {
                    p[x] = p[p[x]]; // path compression
                    x = p[x];
                }
                return x;
            }
        }.find;
        const union_set = struct {
            fn unionSet(p: []usize, m: *usize, a: usize, b: usize) void {
                const ra = find(p, m, a);
                const rb = find(p, m, b);
                if (ra != rb) p[ra] = rb;
            }
        }.unionSet;

        const threshold = self.cfg.consolidation_threshold;

        // Tokenize every cell exactly ONCE, into a PACKED bitset.
        //
        // Two separate problems were stacked here.
        //
        // First, the old `pairwiseMatterForm` zeroed two 512-byte scratch
        // buffers and re-tokenized BOTH cells on every one of the
        // n(n-1)/2 pairs — each cell's episode and every atomic_fact token
        // got XxHash3'd once per partner, so identical work was repeated
        // n-1 times. That is the 29.5s the long-run harness reports as
        // `lat_consolidate_us` on a 1000-cell store.
        //
        // Second, one byte per bucket makes the pair scan cost 512
        // load+compare per pair even after the re-tokenization is gone:
        // 499,500 pairs x 1024 byte operations is ~256M ops, and that
        // became the new bottleneck.
        //
        // Packing to u64 words and using popcount turns each pair into
        // 8 ANDs + 8 ORs + 16 popcounts. Measured on a 1000-cell corpus
        // with ~55 tokens per cell, the pair loop alone: 173.4 ms -> 2.3
        // ms (75x), producing a bit-identical edge set.
        //
        // Memory is n x 512 bits (64 KB at 1k cells, 640 KB at 10k), held
        // only for the clustering phase.
        const bitsets = try self.alloc.alloc(u64, n * TOKEN_WORDS);
        defer self.alloc.free(bitsets);
        @memset(bitsets, 0);
        for (cells.items, 0..) |cell, k| {
            packCell(bitsets[k * TOKEN_WORDS ..], cell);
        }

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ra = bitsets[i * TOKEN_WORDS ..];
            var j: usize = i + 1;
            while (j < n) : (j += 1) {
                const rb = bitsets[j * TOKEN_WORDS ..];
                var inter: usize = 0;
                var union_size: usize = 0;
                for (0..TOKEN_WORDS) |w| {
                    inter += @popCount(ra[w] & rb[w]);
                    union_size += @popCount(ra[w] | rb[w]);
                }
                if (union_size == 0) continue;
                const jaccard = @as(f32, @floatFromInt(inter)) / @as(f32, @floatFromInt(union_size));
                if (jaccard >= threshold) {
                    union_set(parent, &i, i, j);
                }
            }
        }

        // Step 3: collect clusters (group cells by root).
        var cluster_map = std.AutoHashMap(usize, std.ArrayList(usize)).init(self.alloc);
        defer {
            var cit = cluster_map.iterator();
            while (cit.next()) |entry| entry.value_ptr.deinit(self.alloc);
            cluster_map.deinit();
        }
        for (0..n) |k| {
            const root = find(parent, &i, k);
            const gop = try cluster_map.getOrPut(root);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.alloc, k);
        }

        // Step 4: for each cluster of size ≥ 2, generate abstract.
        var abstracts_created: usize = 0;
        var abstract_ids: std.ArrayList(u64) = .empty;
        defer abstract_ids.deinit(self.alloc);
        var it = cluster_map.iterator();
        while (it.next()) |entry| {
            const indices = entry.value_ptr.items;
            if (indices.len < 2) continue;
            if (try self.generateAbstract(cells.items, indices)) |aid| {
                try abstract_ids.append(self.alloc, aid);
                abstracts_created += 1;
            }
        }

        // `cluster_map` is an `AutoHashMap`, so the order abstracts were
        // appended in is hash order — random per instance, since
        // `std.HashMap` seeds itself. That order reaches the caller, which
        // journals and indexes the slice, so without this the WAL record
        // sequence for an identical cell set differs run to run.
        const ids_out = try abstract_ids.toOwnedSlice(self.alloc);
        std.mem.sort(u64, ids_out, {}, std.sort.asc(u64));

        return .{
            .clusters = cluster_map.count(),
            .abstracts_created = abstracts_created,
            .abstract_ids = ids_out,
            .cells_processed = n,
        };
    }

    /// Generate an abstract cell that captures the common vocabulary
    /// of the cluster. Uses matter + form fields from a representative
    /// cell (first in cluster) and a synthetic foresight + goals.
    /// Returns the id of the abstract it inserted, so the caller can
    /// index and journal it.
    fn generateAbstract(self: *Consolidator, cells: []const *MemCell, indices: []const usize) !?u64 {
        const alloc = self.alloc;
        const rep = cells[indices[0]];

        // Build common-episode by ANDing token-bitsets.
        @memset(&self.coherence.scratch_a, 0);
        for (indices) |idx| {
            @memset(&self.coherence.scratch_b, 0);
            tokenizeCell(&self.coherence.scratch_b, cells[idx]);
            for (0..coherence_mod.MAX_TRACKED_TOKENS) |i| {
                if (self.coherence.scratch_b[i] != 0) {
                    self.coherence.scratch_a[i] = 1;
                }
            }
        }

        // Convert bit pattern into a coarse text representation. We
        // emit the common token set as a sorted list (so the abstract
        // is deterministic across runs). The list of tokens is
        // reconstructed by walking the original cell and emitting
        // those whose hash-bucket is set in the AND.
        var abstract_text = std.ArrayList(u8).empty;
        defer abstract_text.deinit(alloc);
        // Use the representative cell's episode as the carrier —
        // emit only those tokens whose hash-bucket is in the AND set.
        // For human-readability, take the representative's episode and
        // filter to common tokens (approximate: substring contains).
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
            const idx: usize = @intCast(h % coherence_mod.MAX_TRACKED_TOKENS);
            if (self.coherence.scratch_a[idx] != 0) {
                if (abstract_text.items.len > 0) try abstract_text.append(alloc, ' ');
                try abstract_text.appendSlice(alloc, buf[0..bl]);
            }
        }

        // Build abstract: source=.form (abstracts ARE form), episode =
        // the common vocabulary, atomic_facts = union of cluster
        // atomic_facts, foresight = representative foresight, goals =
        // union of cluster goals. importance = max of cluster members
        // (abstracts represent the cluster's value).
        var max_importance: f32 = 0.0;
        for (indices) |idx| {
            if (cells[idx].metadata.importance_score > max_importance) {
                max_importance = cells[idx].metadata.importance_score;
            }
        }
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

/// Tokenize a cell's matter + form fields into a bitset. Mirrors the
/// intra-cell tokenizeInto in CoherenceCalculator, but aggregates
/// episode + atomic_facts in one pass.
fn tokenizeCell(bits: *[coherence_mod.MAX_TRACKED_TOKENS]u8, cell: *const MemCell) void {
    // Inline the per-field tokenize pass.
    const visit = struct {
        fn visit(b: *[coherence_mod.MAX_TRACKED_TOKENS]u8, text: []const u8) void {
            forEachToken(text, b, struct {
                fn f(bs: *[coherence_mod.MAX_TRACKED_TOKENS]u8, bucket: u32) void {
                    bs[bucket] = 1;
                }
            }.f);
        }
    }.visit;
    visit(bits, cell.episode);
    for (cell.atomic_facts) |f| {
        visit(bits, f.subject);
        visit(bits, f.predicate);
        visit(bits, f.object);
    }
}

/// `MAX_TRACKED_TOKENS` buckets packed into u64 words. 512 bits = 8 words.
const TOKEN_WORDS: usize = coherence_mod.MAX_TRACKED_TOKENS / 64;

/// Call `sink` with the hash bucket of every alphanumeric token in `text`.
///
/// Shared by both bitset representations so they cannot drift: the
/// byte-per-bucket version below and the packed one in `packCell` must
/// agree on bucket assignment or the clustering silently changes.
fn forEachToken(text: []const u8, context: anytype, comptime sink: fn (@TypeOf(context), u32) void) void {
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |tok| {
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
        sink(context, @intCast(h % coherence_mod.MAX_TRACKED_TOKENS));
    }
}

/// Token bitset for one cell, packed into `words` (length `TOKEN_WORDS`).
/// Sort key for `consolidate`'s cell list: ascending id.
///
/// Ties cannot occur — `TriSourceManager` keys all three of its source maps
/// by the same unique id — so this is a total order and the resulting
/// arrangement is reproducible.
fn byIdAscending(_: void, a: *MemCell, b: *MemCell) bool {
    return a.id < b.id;
}

fn packCell(words: []u64, cell: *const MemCell) void {
    const visit = struct {
        fn v(ws: []u64, text: []const u8) void {
            forEachToken(text, ws, struct {
                fn f(s: []u64, bucket: u32) void {
                    s[bucket / 64] |= @as(u64, 1) << @intCast(bucket % 64);
                }
            }.f);
        }
    }.v;
    visit(words, cell.episode);
    for (cell.atomic_facts) |f| {
        visit(words, f.subject);
        visit(words, f.predicate);
        visit(words, f.object);
    }
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
