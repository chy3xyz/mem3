//! Existence-gain-driven forgetting.
//!
//! **GHW Layer**: Memory (三源合恰). Implements the Forgetting stage of
//! the four-stage lifecycle (per the paper §4.3.4).
//!
//! ## What a sweep decides
//!
//! Constitution Principle III / spec FR-010 define
//!
//!     net_existence = importance − redundancy − conflict_score
//!
//! with `net_existence < 0` making a cell a forgetting candidate. The terms,
//! precisely (ADR 0005, `docs/adr/0005-existence-gain-forgetting.md`, is the
//! authority; this is the summary):
//!
//!   * `importance`     — `metadata.importance_score`, **undecayed**. Age is
//!     handled by the separate "decayed" rule below, so a cell is not
//!     charged for being old twice.
//!   * `redundancy`     — how much of the cell a *more important, retained*
//!     near-duplicate already carries: `s · (importance + θ)`, where
//!     `s ∈ [0,1]` is the best covering neighbour's Jaccard similarity
//!     rescaled from `[redundancy_threshold, 1]`, and `θ` is
//!     `forgetting_threshold`. An exact duplicate has `s = 1` and so a
//!     strictly negative net existence whatever its importance. The
//!     neighbour must have the same source, serve every goal the cell serves,
//!     carry every one of its facts and foresight entries, and *outrank* it
//!     (importance, then arrival order) — so the top cell of a duplicate
//!     group has redundancy 0 and **a group can never be forgotten whole by redundancy**.
//!     Computed by `redundancy.zig` with a prefix-filter inverted index, not
//!     by comparing all pairs.
//!   * `conflict_score` — 0 for a current cell. For a *superseded* cell
//!     (every keyed fact contradicted by a newer cell; `conflict.zig`) it is
//!     the importance of the superseder: the old fact is only a forgetting
//!     candidate when what replaced it matters more than it does.
//!
//! A cell leaves the active store for one of three reasons, attributed in
//! this priority order when several hold: `decayed`
//! (`importance × exp(−decay_rate × age_days) < forgetting_threshold`, the
//! original rule, unchanged), `conflicted` (`net_existence < 0` because of a
//! supersession), `redundant` (`net_existence < 0` because of a duplicate).
//!
//! ## Constitution compliance
//! - Principle III (存在增益驱动): forgetting is driven by `net_existence`,
//!   not by capacity or TTL.
//! - PCR: **nothing is ever deleted.** Every forgotten cell goes to the fuzzy
//!   store (`is_fuzzy = true`, `fuzzed_at` stamped) and can be promoted back.
//!   Conflict resolution only *marks* the old cell `superseded_at` /
//!   `superseded_by`. FR-010's "spirit_coherence > 0.7 goes to the fuzzy
//!   store, not deleted" is therefore satisfied for every cell, not only the
//!   coherent ones: there is no delete path for the other half of that
//!   sentence to select (see the ADR's deviation list).
//!
//! ## Determinism
//! The sweep is a pure function of the set of cells. Cells are sorted by id
//! before anything else; the duplicate pass orders by (importance desc, id
//! asc); no decision reads hash-map iteration order.
//!
//! ## What is not done
//! Partial contradictions (some of a cell's facts contradicted, some not) do
//! not supersede it. `Fact.confidence` is not used (every ingest path writes
//! 1.0). Redundancy compares the exact token sets of episode + facts (not
//! embeddings, not the consolidator's 512-bit signature). `mem3 remember` (promote-back CLI) does not exist.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const TriSourceManager = @import("tri_source_manager.zig").TriSourceManager;
const conflict = @import("conflict.zig");
const redundancy_mod = @import("redundancy.zig");
const time = @import("../utils/time.zig");
const config = @import("../core/config.zig").Config;
const errors = core.Error;

pub const FuzzyStore = struct {
    alloc: Allocator,
    /// Cells demoted to fuzzy. Keyed by original id.
    cells: std.AutoHashMap(u64, *MemCell),

    pub fn init(alloc: Allocator) FuzzyStore {
        return .{
            .alloc = alloc,
            .cells = std.AutoHashMap(u64, *MemCell).init(alloc),
        };
    }

    pub fn deinit(self: *FuzzyStore) void {
        var it = self.cells.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.cells.deinit();
    }

    /// Take ownership of `cell`. Flags are stamped only after the insert
    /// succeeded, so a failed `put` leaves the cell exactly as it was and the
    /// caller still owns it.
    pub fn transfer(self: *FuzzyStore, cell: *MemCell) !void {
        try self.cells.put(cell.id, cell);
        cell.metadata.is_fuzzy = true;
        // Keep a stamp that already exists (a snapshot restore hands back the
        // original demotion time); stamp only a first demotion.
        if (cell.metadata.fuzzed_at == null) cell.metadata.fuzzed_at = time.nowMs();
    }

    pub fn promote(self: *FuzzyStore, id: u64) ?*MemCell {
        if (self.cells.fetchRemove(id)) |kv| {
            kv.value.metadata.is_fuzzy = false;
            kv.value.metadata.fuzzed_at = null;
            return kv.value;
        }
        return null;
    }

    pub fn count(self: *const FuzzyStore) usize {
        return self.cells.count();
    }
};

/// Why a cell leaves the active store. Attributed in this priority order
/// when more than one holds.
pub const ForgetReason = enum { decayed, conflicted, redundant };

/// One cell's verdict, with the three terms that produced it.
pub const ForgetDecision = struct {
    id: u64,
    importance: f32,
    /// `importance × exp(−decay_rate × age_days)`: the original rule's input.
    contribution: f32,
    redundancy: f32,
    conflict_score: f32,
    /// `importance − redundancy − conflict_score`.
    net_existence: f32,
    /// `null` = kept.
    reason: ?ForgetReason,
    /// The sweep itself found this cell superseded (a conflict that write-time
    /// detection had not recorded, e.g. data written by an older build).
    newly_superseded: bool,
    /// Superseder of a `newly_superseded` cell.
    superseded_by: ?u64,
};

/// A sweep's verdicts, computed without touching any cell.
pub const ForgetPlan = struct {
    alloc: Allocator,
    /// Ascending by id.
    decisions: []ForgetDecision,
    /// Parallel to `decisions`. Borrowed from the manager.
    cells: []*MemCell,
    /// Jaccard evaluations the duplicate pass performed. The quantity an
    /// all-pairs pass would have paid `n(n-1)/2` of.
    jaccard_evals: u64 = 0,

    pub fn deinit(self: *ForgetPlan) void {
        self.alloc.free(self.decisions);
        self.alloc.free(self.cells);
    }

    pub fn countReason(self: *const ForgetPlan, reason: ForgetReason) usize {
        var n: usize = 0;
        for (self.decisions) |d| {
            if (d.reason == reason) n += 1;
        }
        return n;
    }

    pub fn countSuperseded(self: *const ForgetPlan) usize {
        var n: usize = 0;
        for (self.decisions) |d| {
            if (d.newly_superseded) n += 1;
        }
        return n;
    }

    pub fn find(self: *const ForgetPlan, id: u64) ?*const ForgetDecision {
        var lo: usize = 0;
        var hi: usize = self.decisions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.decisions[mid].id < id) lo = mid + 1 else hi = mid;
        }
        if (lo < self.decisions.len and self.decisions[lo].id == id) return &self.decisions[lo];
        return null;
    }
};

fn sanitize(x: f32) f32 {
    return if (std.math.isNan(x)) 0.0 else x;
}

fn idLess(_: void, a: *MemCell, b: *MemCell) bool {
    return a.id < b.id;
}

/// Dominance order: more important first, then earlier arrival.
fn dominates(_: void, a: *const MemCell, b: *const MemCell) bool {
    const ia = sanitize(a.metadata.importance_score);
    const ib = sanitize(b.metadata.importance_score);
    if (ia != ib) return ia > ib;
    return a.id < b.id;
}

pub const Forgetter = struct {
    pub const Reason = ForgetReason;
    pub const Decision = ForgetDecision;
    pub const Plan = ForgetPlan;

    alloc: Allocator,
    cfg: config,
    fuzzy: *FuzzyStore,

    pub fn init(alloc: Allocator, cfg: config, fuzzy: *FuzzyStore) Forgetter {
        return .{ .alloc = alloc, .cfg = cfg, .fuzzy = fuzzy };
    }

    /// Compute the existence contribution for a single cell.
    /// High importance → high contribution. Recent access boosts. Old
    /// cells with low importance → low.
    pub fn existenceContribution(self: *const Forgetter, cell: *const MemCell, now_ms: i64) f32 {
        _ = self;
        const age_days: f32 = if (now_ms > cell.metadata.created_at)
            @as(f32, @floatFromInt(now_ms - cell.metadata.created_at)) / 86_400_000.0
        else
            0.0;
        const decay: f32 = @exp(-cell.metadata.decay_rate * age_days);
        return cell.metadata.importance_score * decay;
    }

    /// `importance − redundancy − conflict_score`. Pure; exposed so the
    /// arithmetic the tests and the ADR describe is one function.
    pub fn netExistence(importance: f32, redundancy: f32, conflict_score: f32) f32 {
        return importance - redundancy - conflict_score;
    }

    pub const SweepResult = struct {
        /// Cells moved to the fuzzy store (= decayed + conflicted + redundant).
        fuzzied: usize,
        kept: usize,
        archived: usize,
        decayed: usize = 0,
        conflicted: usize = 0,
        redundant: usize = 0,
        /// Cells the sweep newly marked `superseded_at` (they stay active
        /// unless `conflicted` also fuzzied them).
        superseded: usize = 0,
        /// See `ForgetPlan.jaccard_evals`.
        jaccard_evals: u64 = 0,
    };

    /// Decide, without mutating anything, what a sweep would do.
    ///
    /// Four passes, each O(n) or O(n log n) except the duplicate pass, which
    /// is sub-quadratic by construction (see `redundancy.zig`):
    ///   1. decay: the original `importance × decay < θ` rule;
    ///   2. conflict: replay the cells in arrival order through a
    ///      `ConflictIndex` to find supersessions nobody recorded yet;
    ///   3. conflict score of every superseded cell;
    ///   4. redundancy over the cells still standing.
    pub fn plan(self: *Forgetter, mgr: *TriSourceManager, now_ms: i64) !ForgetPlan {
        var cells = std.ArrayList(*MemCell).empty;
        errdefer cells.deinit(self.alloc);
        try cells.ensureTotalCapacity(self.alloc, mgr.count());
        var it_s = mgr.sensory.iterator();
        while (it_s.next()) |e| cells.appendAssumeCapacity(e.value_ptr.*);
        var it_c = mgr.cognitive.iterator();
        while (it_c.next()) |e| cells.appendAssumeCapacity(e.value_ptr.*);
        var it_a = mgr.action.iterator();
        while (it_a.next()) |e| cells.appendAssumeCapacity(e.value_ptr.*);
        std.mem.sort(*MemCell, cells.items, {}, idLess);

        const n = cells.items.len;
        const decisions = try self.alloc.alloc(ForgetDecision, n);
        errdefer self.alloc.free(decisions);

        const theta = self.cfg.forgetting_threshold;
        for (cells.items, decisions) |cell, *d| {
            const imp = sanitize(cell.metadata.importance_score);
            const contribution = self.existenceContribution(cell, now_ms);
            d.* = .{
                .id = cell.id,
                .importance = imp,
                .contribution = contribution,
                .redundancy = 0,
                .conflict_score = 0,
                .net_existence = imp,
                .reason = if (contribution < theta) .decayed else null,
                .newly_superseded = false,
                .superseded_by = null,
            };
        }

        // ---- 2. conflicts nobody recorded yet ------------------------------
        if (self.cfg.supersede_on_conflict) {
            var ci = conflict.ConflictIndex.init(self.alloc);
            defer ci.deinit();
            var olds = std.ArrayList(*MemCell).empty;
            defer olds.deinit(self.alloc);
            for (cells.items) |cell| {
                // Already resolved by write-time detection or a past sweep.
                if (cell.metadata.superseded_at != null) continue;
                olds.clearRetainingCapacity();
                try ci.detect(self.alloc, cell, &olds);
                for (olds.items) |old| {
                    const idx = indexOfId(decisions, old.id) orelse continue;
                    decisions[idx].newly_superseded = true;
                    decisions[idx].superseded_by = cell.id;
                    ci.remove(old);
                }
                try ci.index(cell);
            }
        }

        // ---- 3. conflict score of every superseded cell --------------------
        for (cells.items, decisions) |cell, *d| {
            const by: ?u64 = if (cell.metadata.superseded_at != null)
                cell.metadata.superseded_by
            else
                d.superseded_by;
            if (cell.metadata.superseded_at == null and !d.newly_superseded) continue;
            const winner_id = by orelse continue;
            const winner: ?*const MemCell = if (mgr.get(winner_id)) |w|
                w
            else if (self.fuzzy.cells.get(winner_id)) |w|
                w
            else
                null;
            if (winner) |w| d.conflict_score = sanitize(w.metadata.importance_score);
        }

        // ---- 4. redundancy over the cells still standing -------------------
        var standing = std.ArrayList(*const MemCell).empty;
        defer standing.deinit(self.alloc);
        for (cells.items, decisions) |cell, d| {
            if (d.reason == .decayed) continue;
            if (cell.metadata.superseded_at != null or d.newly_superseded) continue;
            try standing.append(self.alloc, cell);
        }
        std.mem.sort(*const MemCell, standing.items, {}, dominates);

        var red = try redundancy_mod.run(self.alloc, standing.items, .{
            .tau = self.cfg.redundancy_threshold,
            .theta = theta,
            .max_candidates = self.cfg.redundancy_max_candidates,
        });
        defer red.deinit();
        for (standing.items, 0..) |cell, k| {
            const idx = indexOfId(decisions, cell.id).?;
            decisions[idx].redundancy = red.redundancy[k];
        }

        // ---- verdicts --------------------------------------------------------
        for (decisions) |*d| {
            d.net_existence = netExistence(d.importance, d.redundancy, d.conflict_score);
            if (d.reason == null and d.net_existence < 0) {
                d.reason = if (d.conflict_score > 0) .conflicted else .redundant;
            }
        }

        return .{
            .alloc = self.alloc,
            .decisions = decisions,
            .cells = try cells.toOwnedSlice(self.alloc),
            .jaccard_evals = red.jaccard_evals,
        };
    }

    /// Run the forgetting sweep.
    ///
    /// With `dry_run` nothing is mutated, including `superseded_at`.
    /// Otherwise: newly found supersessions are stamped first, then every
    /// forgotten cell is handed to the fuzzy store (PCR: never delete) before
    /// it is removed from the manager, so a failed hand-over loses nothing.
    pub fn sweep(
        self: *Forgetter,
        mgr: *TriSourceManager,
        dry_run: bool,
    ) !SweepResult {
        const now = time.nowMs();
        var plan_ = try self.plan(mgr, now);
        defer plan_.deinit();

        var res: SweepResult = .{
            .fuzzied = 0,
            .kept = 0,
            .archived = 0,
            .superseded = plan_.countSuperseded(),
            .jaccard_evals = plan_.jaccard_evals,
        };
        for (plan_.decisions, plan_.cells) |d, cell| {
            if (d.newly_superseded and !dry_run) {
                cell.metadata.superseded_at = now;
                cell.metadata.superseded_by = d.superseded_by;
            }
            const reason = d.reason orelse {
                res.kept += 1;
                continue;
            };
            res.fuzzied += 1;
            switch (reason) {
                .decayed => res.decayed += 1,
                .conflicted => res.conflicted += 1,
                .redundant => res.redundant += 1,
            }
            if (!dry_run) {
                try self.fuzzy.transfer(cell);
                _ = mgr.remove(cell.id);
            }
        }
        return res;
    }
};

fn indexOfId(decisions: []const ForgetDecision, id: u64) ?usize {
    var lo: usize = 0;
    var hi: usize = decisions.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (decisions[mid].id < id) lo = mid + 1 else hi = mid;
    }
    if (lo < decisions.len and decisions[lo].id == id) return lo;
    return null;
}

// =============================================================================
// Tests
// =============================================================================

test "Forgetter: low importance gets fuzzied" {
    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(std.testing.allocator, &ids);
    defer mgr.deinit();
    var fuzzy = FuzzyStore.init(std.testing.allocator);
    defer fuzzy.deinit();
    var forgetter = Forgetter.init(std.testing.allocator, .{ .forgetting_threshold = 0.1 }, &fuzzy);

    // Add a cell with importance 0.05 — should be fuzzied.
    const cell: MemCell = .{
        .id = 0,
        .source = .matter,
        .episode = "x",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{ .{ .goal_id = 1, .relevance = 0.1, .priority = 1 } },
        .metadata = .{ .source_confidence = 0.9, .importance_score = 0.05, .decay_rate = 0.01 },
    };
    _ = try mgr.add(cell);

    const result = try forgetter.sweep(&mgr, false);
    try std.testing.expectEqual(@as(usize, 1), result.fuzzied);
    try std.testing.expectEqual(@as(usize, 1), fuzzy.count());
    try std.testing.expectEqual(@as(usize, 0), mgr.count());
}

test "FuzzyStore: promote restores" {
    var fuzzy = FuzzyStore.init(std.testing.allocator);
    defer fuzzy.deinit();

    var cell: MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "x",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{ .{ .goal_id = 1, .relevance = 0.5, .priority = 5 } },
        .metadata = .{ .source_confidence = 0.9 },
    };
    try fuzzy.transfer(&cell);
    try std.testing.expect(cell.metadata.is_fuzzy);
    try std.testing.expectEqual(@as(usize, 1), fuzzy.count());

    const promoted = fuzzy.promote(1).?;
    try std.testing.expect(!promoted.metadata.is_fuzzy);
    try std.testing.expectEqual(@as(usize, 0), fuzzy.count());
}
