//! Unit tests for `Consolidator` (Hierarchical Agglomerative
//! Clustering). Exercises:
//! - HAC clustering on a small corpus of similar cells
//! - Abstract generation (1 per cluster of size ≥ 2)
//! - No abstract when cells are too dissimilar
//! - PCR rule: originals are preserved (consolidation never deletes)

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");
const Config = mem3.core.Config;
const TriSourceManager = mem3.memory.TriSourceManager;
const FuzzyStore = mem3.memory.FuzzyStore;
const Consolidator = mem3.consolidator_mod.Consolidator;

fn buildStore(alloc: std.mem.Allocator) !struct {
    mgr: *TriSourceManager,
    cons: Consolidator,
    alloc: std.mem.Allocator,
    /// Heap-allocated because `TriSourceManager` keeps a pointer to it.
    ids: *std.atomic.Value(u64),

    fn deinit(self: *@This()) void {
        // CoherenceCalculator has no heap state, so no deinit.
        self.cons.fuzzy.deinit();
        self.cons.mgr.deinit();
        self.alloc.destroy(self.cons.fuzzy);
        self.alloc.destroy(self.cons.mgr);
        self.alloc.destroy(self.ids);
    }
} {
    // HEAP, not stack.
    //
    // This was `var ids: std.atomic.Value(u64) = .init(1);` — a local whose
    // address escaped into `TriSourceManager.next_id` and then went out of
    // scope when `buildStore` returned. `next_id` was left pointing at a
    // reused stack slot, so `fetchAdd` read and wrote whatever landed
    // there. It usually worked by accident: the slot kept a plausible
    // value from an earlier call.
    //
    // It stopped working the moment the code size of `consolidate` changed
    // enough to move the stack layout — an unrelated consolidation
    // refactor made abstracts come out as `id=1` against three existing
    // cells, and the tests failed with `error.DuplicateId`. A test whose
    // id counter is a dangling pointer is a landmine: the next innocent
    // edit anywhere sets it off again.
    const ids = try alloc.create(std.atomic.Value(u64));
    ids.* = .init(1);

    const mgr_ptr = try alloc.create(TriSourceManager);
    mgr_ptr.* = TriSourceManager.init(alloc, ids);

    const fuzzy_ptr = try alloc.create(FuzzyStore);
    fuzzy_ptr.* = FuzzyStore.init(alloc);

    const cons = Consolidator.init(
        alloc,
        Config{ .consolidation_threshold = 0.3 },
        fuzzy_ptr,
        mgr_ptr,
    );
    return .{ .mgr = mgr_ptr, .cons = cons, .alloc = alloc, .ids = ids };
}

fn addCell(mgr: *TriSourceManager, episode: []const u8, source: mem3.MemorySource, goal_id: u64) !void {
    const cell: mem3.MemCell = .{
        .id = 0,
        .source = source,
        .episode = episode,
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = goal_id, .relevance = 0.5, .priority = 5 },
        },
        .metadata = .{ .source_confidence = 1.0, .importance_score = 0.5, .decay_rate = 0.01 },
    };
    _ = try mgr.add(cell);
}

test "Consolidator: two similar cells produce one abstract" {
    const alloc = testing.allocator;
    var s = try buildStore(alloc);
    defer s.deinit();

    try addCell(s.mgr, "machine learning optimizes models", .form, 1);
    try addCell(s.mgr, "machine learning trains models", .form, 1);
    try addCell(s.mgr, "machine learning improves accuracy", .form, 1);

    try testing.expectEqual(@as(usize, 3), s.mgr.count());

    var result = try s.cons.consolidate();
    defer result.deinitAbstractIds(alloc);
    try testing.expectEqual(@as(usize, 1), result.abstracts_created);
    // 3 originals + 1 abstract.
    try testing.expectEqual(@as(usize, 4), s.mgr.count());
}

test "Consolidator: dissimilar cells produce no abstract" {
    const alloc = testing.allocator;
    var s = try buildStore(alloc);
    defer s.deinit();

    try addCell(s.mgr, "machine learning optimizes models", .form, 1);
    try addCell(s.mgr, "potato recipe for dinner", .form, 1);
    try addCell(s.mgr, "quantum gravity theory revisited", .form, 1);

    var result = try s.cons.consolidate();
    defer result.deinitAbstractIds(alloc);
    try testing.expectEqual(@as(usize, 0), result.abstracts_created);
    // Originals preserved.
    try testing.expectEqual(@as(usize, 3), s.mgr.count());
}

test "Consolidator: PCR — originals are never deleted" {
    // Even after consolidation, the original cells must remain in the
    // manager. This is the Projective Cognitive Reduction invariant.
    const alloc = testing.allocator;
    var s = try buildStore(alloc);
    defer s.deinit();

    try addCell(s.mgr, "deep learning vision models", .form, 1);
    try addCell(s.mgr, "deep learning speech models", .form, 1);

    const before = s.mgr.count();
    var res = try s.cons.consolidate();
    defer res.deinitAbstractIds(alloc);
    const after = s.mgr.count();

    // After consolidation: at least `before` cells (originals) plus 1
    // abstract. No deletions.
    try testing.expect(after >= before + 1);
}

test "Consolidator: empty corpus produces zero abstracts" {
    const alloc = testing.allocator;
    var s = try buildStore(alloc);
    defer s.deinit();

    var result = try s.cons.consolidate();
    defer result.deinitAbstractIds(alloc);
    try testing.expectEqual(@as(usize, 0), result.abstracts_created);
}