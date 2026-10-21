//! Tests for the existence-gain forgetting sweep:
//! `net_existence = importance − redundancy − conflict_score`.
//!
//! The forgetter used to implement only `importance × decay < θ`. These
//! tests pin the other two terms, in the order the spec asks for them:
//!
//!   * redundancy lowers the net existence of a near-duplicate and never of
//!     the cell that outranks it, so a duplicate group keeps a representative;
//!   * a contradicted cell is superseded (never deleted), and the supersession
//!     feeds `conflict_score`;
//!   * FR-010's "coherence > 0.7 → fuzzy store, not deleted";
//!   * the decisions are a pure function of the cell set (no hash-map order);
//!   * the duplicate pass is exact (it agrees with an independent all-pairs
//!     oracle) and sub-quadratic (counted in Jaccard evaluations, which is
//!     deterministic, not in wall time).
//!
//! Scratch policy: nothing here touches the filesystem.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");
const Config = mem3.core.Config;
const MemCell = mem3.MemCell;
const Fact = mem3.Fact;
const MemorySource = mem3.MemorySource;
const TriSourceManager = mem3.memory.TriSourceManager;
const FuzzyStore = mem3.memory.FuzzyStore;
const Forgetter = mem3.memory.Forgetter;
const ConflictIndex = mem3.memory.ConflictIndex;
const redundancy = mem3.memory.redundancy;

const DAY_MS: i64 = 86_400_000;

fn fact(s: []const u8, p: []const u8, o: []const u8) Fact {
    return .{ .subject = s, .predicate = p, .object = o, .confidence = 1.0, .source = "test" };
}

const Spec = struct {
    id: u64,
    episode: []const u8,
    source: MemorySource = .matter,
    facts: []const Fact = &.{},
    goal: u64 = 1,
    importance: f32 = 0.7,
    coherence: f32 = 0.0,
    /// Age in days. The decay rate below is tiny, so age alone never trips
    /// the original rule unless a test wants it to.
    age_days: f32 = 0.0,
    decay_rate: f32 = 0.0001,
};

const World = struct {
    alloc: std.mem.Allocator,
    ids: *std.atomic.Value(u64),
    mgr: *TriSourceManager,
    fuzzy: *FuzzyStore,
    forgetter: Forgetter,
    now_ms: i64,

    fn init(alloc: std.mem.Allocator, cfg: Config) !World {
        // Heap: `TriSourceManager.next_id` and `Forgetter.fuzzy` keep these
        // pointers, so a stack local would dangle on return.
        const ids = try alloc.create(std.atomic.Value(u64));
        errdefer alloc.destroy(ids);
        ids.* = .init(1_000_000);
        const mgr = try alloc.create(TriSourceManager);
        errdefer alloc.destroy(mgr);
        mgr.* = TriSourceManager.init(alloc, ids);
        errdefer mgr.deinit();
        const fuzzy = try alloc.create(FuzzyStore);
        errdefer alloc.destroy(fuzzy);
        fuzzy.* = FuzzyStore.init(alloc);
        return .{
            .alloc = alloc,
            .ids = ids,
            .mgr = mgr,
            .fuzzy = fuzzy,
            .forgetter = Forgetter.init(alloc, cfg, fuzzy),
            .now_ms = mem3.utils.time.nowMs(),
        };
    }

    fn deinit(self: *World) void {
        self.fuzzy.deinit();
        self.alloc.destroy(self.fuzzy);
        self.mgr.deinit();
        self.alloc.destroy(self.mgr);
        self.alloc.destroy(self.ids);
    }

    fn add(self: *World, spec: Spec) !void {
        const created: i64 = self.now_ms - @as(i64, @intFromFloat(spec.age_days * @as(f32, @floatFromInt(DAY_MS))));
        const cell: MemCell = .{
            .id = spec.id,
            .source = spec.source,
            .episode = spec.episode,
            .atomic_facts = spec.facts,
            .foresight = &.{},
            .goal_associations = &.{.{ .goal_id = spec.goal, .relevance = 0.5, .priority = 5 }},
            .metadata = .{
                .created_at = created,
                .updated_at = created,
                .importance_score = spec.importance,
                .coherence_score = spec.coherence,
                .decay_rate = spec.decay_rate,
            },
        };
        _ = try self.mgr.addWithId(spec.id, cell);
    }

    fn plan(self: *World) !Forgetter.Plan {
        return self.forgetter.plan(self.mgr, self.now_ms);
    }
};

const THETA_CFG: Config = .{ .forgetting_threshold = 0.1 };

const EP = "the quarterly revenue forecast was revised after the march close of the books";

// =============================================================================
// Redundancy
// =============================================================================

test "netex: exact duplicates are forgotten but exactly one representative survives" {
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    for (1..6) |i| try w.add(.{ .id = i, .episode = EP });

    var plan = try w.plan();
    defer plan.deinit();

    // Earliest arrival wins an importance tie.
    try testing.expectEqual(@as(?Forgetter.Reason, null), plan.find(1).?.reason);
    for (2..6) |i| {
        const d = plan.find(i).?;
        try testing.expectEqual(@as(?Forgetter.Reason, .redundant), d.reason);
        // An exact duplicate has s = 1, so its net existence is -theta
        // whatever its importance.
        try testing.expect(d.net_existence < 0);
        try testing.expect(d.redundancy > d.importance);
    }
    try testing.expectEqual(@as(usize, 4), plan.countReason(.redundant));
    // The representative's terms are untouched.
    const rep = plan.find(1).?;
    try testing.expectEqual(@as(f32, 0.0), rep.redundancy);
    try testing.expectEqual(rep.importance, rep.net_existence);
}

test "netex: the most important cell of a duplicate group is the one kept, whatever the arrival order" {
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    try w.add(.{ .id = 1, .episode = EP, .importance = 0.30 });
    try w.add(.{ .id = 2, .episode = EP, .importance = 0.95 });
    try w.add(.{ .id = 3, .episode = EP, .importance = 0.60 });

    var plan = try w.plan();
    defer plan.deinit();
    try testing.expectEqual(@as(?Forgetter.Reason, .redundant), plan.find(1).?.reason);
    try testing.expectEqual(@as(?Forgetter.Reason, null), plan.find(2).?.reason);
    try testing.expectEqual(@as(?Forgetter.Reason, .redundant), plan.find(3).?.reason);
}

test "netex: redundancy lowers the net existence of a near-duplicate and not of the cell that outranks it" {
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    // One word differs: a paraphrase, not a duplicate.
    try w.add(.{ .id = 1, .episode = EP, .importance = 0.8 });
    try w.add(.{ .id = 2, .episode = "the quarterly revenue forecast was revised after the april close of the books", .importance = 0.5 });

    var plan = try w.plan();
    defer plan.deinit();
    const rep = plan.find(1).?;
    const near = plan.find(2).?;
    try testing.expectEqual(@as(f32, 0.0), rep.redundancy);
    try testing.expectEqual(rep.importance, rep.net_existence);
    try testing.expect(near.redundancy > 0.0);
    try testing.expect(near.net_existence < near.importance);
    // The conservative reading: a paraphrase is lowered, not evicted.
    try testing.expectEqual(@as(?Forgetter.Reason, null), near.reason);
}

test "netex: unrelated cells carry no redundancy" {
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    try w.add(.{ .id = 1, .episode = "kubernetes ingress controller rollout plan for the staging cluster" });
    try w.add(.{ .id = 2, .episode = "pottery glaze chemistry and the firing curve for stoneware" });
    try w.add(.{ .id = 3, .episode = "oncall rotation hands over at nine in the morning local time" });

    var plan = try w.plan();
    defer plan.deinit();
    for (plan.decisions) |d| {
        try testing.expectEqual(@as(f32, 0.0), d.redundancy);
        try testing.expectEqual(@as(?Forgetter.Reason, null), d.reason);
    }
}

test "netex: a duplicate is only redundant when the cell above it carries everything it does" {
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    // Same text, but: another source (象 vs 物), another goal, an extra fact.
    try w.add(.{ .id = 1, .episode = EP, .importance = 0.9 });
    try w.add(.{ .id = 2, .episode = EP, .importance = 0.5, .source = .form });
    try w.add(.{ .id = 3, .episode = EP, .importance = 0.5, .goal = 77 });
    try w.add(.{ .id = 4, .episode = EP, .importance = 0.5, .facts = &.{fact("forecast", "revised", "march")} });
    // And the control: no difference at all.
    try w.add(.{ .id = 5, .episode = EP, .importance = 0.5 });

    var plan = try w.plan();
    defer plan.deinit();
    try testing.expectEqual(@as(?Forgetter.Reason, null), plan.find(2).?.reason);
    try testing.expectEqual(@as(?Forgetter.Reason, null), plan.find(3).?.reason);
    try testing.expectEqual(@as(?Forgetter.Reason, null), plan.find(4).?.reason);
    try testing.expectEqual(@as(?Forgetter.Reason, .redundant), plan.find(5).?.reason);
}

test "netex: a decayed cell does not cover its duplicates" {
    // Forgetting the only well-kept copy and then the copy it was covering
    // would lose the content. The decayed one leaves; the survivor stays.
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    try w.add(.{ .id = 1, .episode = EP, .importance = 0.9, .age_days = 5000, .decay_rate = 0.05 });
    try w.add(.{ .id = 2, .episode = EP, .importance = 0.4 });

    var plan = try w.plan();
    defer plan.deinit();
    try testing.expectEqual(@as(?Forgetter.Reason, .decayed), plan.find(1).?.reason);
    try testing.expectEqual(@as(?Forgetter.Reason, null), plan.find(2).?.reason);
}

test "netex: high-importance unique cells are never forgotten by the new terms" {
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    for (1..40) |i| {
        var buf: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "unique memory number {d} about topic {d} with detail {d}", .{ i, i * 7, i * 13 });
        const owned = try testing.allocator.dupe(u8, text);
        defer testing.allocator.free(owned);
        try w.add(.{ .id = i, .episode = owned, .importance = 0.9 });
    }
    var plan = try w.plan();
    defer plan.deinit();
    try testing.expectEqual(@as(usize, 0), plan.countReason(.redundant));
    try testing.expectEqual(@as(usize, 0), plan.countReason(.conflicted));
}

// =============================================================================
// FR-010: the fuzzy store, never deletion
// =============================================================================

test "netex: coherence above 0.7 goes to the fuzzy store and is never deleted" {
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    // Low importance, old, and coherent: the exact cell FR-010 names.
    try w.add(.{ .id = 1, .episode = "a coherent memory that faded", .importance = 0.08, .coherence = 0.9 });
    // And a duplicate pair whose redundant half is coherent.
    try w.add(.{ .id = 2, .episode = EP, .importance = 0.9 });
    try w.add(.{ .id = 3, .episode = EP, .importance = 0.5, .coherence = 0.95 });

    const res = try w.forgetter.sweep(w.mgr, false);
    try testing.expectEqual(@as(usize, 2), res.fuzzied);
    try testing.expectEqual(@as(usize, 1), res.decayed);
    try testing.expectEqual(@as(usize, 1), res.redundant);

    for ([_]u64{ 1, 3 }) |id| {
        try testing.expect(w.mgr.get(id) == null);
        const cell = w.fuzzy.cells.get(id) orelse return error.CellWasDeleted;
        try testing.expect(cell.metadata.is_fuzzy);
        try testing.expect(cell.metadata.fuzzed_at != null);
        try testing.expectEqualStrings(if (id == 1) "a coherent memory that faded" else EP, cell.episode);
    }
}

test "netex: a low-coherence cell is not deleted either (no delete path exists)" {
    // FR-010's second half reads as "the others are deleted". Constitution
    // PCR forbids that and the sweep has no delete path: documented as a
    // deviation in ADR 0005.
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    try w.add(.{ .id = 1, .episode = "an incoherent memory that faded", .importance = 0.05, .coherence = 0.1 });
    _ = try w.forgetter.sweep(w.mgr, false);
    try testing.expect(w.mgr.get(1) == null);
    try testing.expect(w.fuzzy.cells.get(1) != null);
}

test "netex: a dry run mutates nothing, supersession stamps included" {
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    try w.add(.{ .id = 1, .episode = "the old plan", .importance = 0.4, .facts = &.{fact("plan", "owner", "alice")} });
    try w.add(.{ .id = 2, .episode = "the new plan", .importance = 0.9, .facts = &.{fact("plan", "owner", "bob")} });
    try w.add(.{ .id = 3, .episode = EP });
    try w.add(.{ .id = 4, .episode = EP });

    const res = try w.forgetter.sweep(w.mgr, true);
    try testing.expectEqual(@as(usize, 1), res.superseded);
    try testing.expect(res.fuzzied >= 2);
    try testing.expectEqual(@as(usize, 4), w.mgr.count());
    try testing.expectEqual(@as(usize, 0), w.fuzzy.count());
    try testing.expectEqual(@as(?i64, null), w.mgr.get(1).?.metadata.superseded_at);
}

// =============================================================================
// Conflict
// =============================================================================

fn cellWith(id: u64, facts: []const Fact) MemCell {
    return .{
        .id = id,
        .source = .matter,
        .episode = "x",
        .atomic_facts = facts,
        .foresight = &.{},
        .goal_associations = &.{},
        .metadata = .{},
    };
}

test "conflict: the same subject and predicate with a different object supersedes the older cell" {
    const alloc = testing.allocator;
    var idx = ConflictIndex.initWithPolicy(alloc, .{ .mode = .all });
    defer idx.deinit();
    var old = cellWith(1, &.{fact("user", "prefers", "zig")});
    var newer = cellWith(2, &.{fact("user", "prefers", "rust")});
    try idx.index(&old);
    try idx.index(&newer);

    var out: std.ArrayList(*MemCell) = .empty;
    defer out.deinit(alloc);
    try idx.detect(alloc, &newer, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, 1), out.items[0].id);
}

test "conflict: key and object comparison ignore case and surrounding whitespace" {
    const alloc = testing.allocator;
    var idx = ConflictIndex.initWithPolicy(alloc, .{ .mode = .all });
    defer idx.deinit();
    var old = cellWith(1, &.{fact("User", " Prefers", "Zig")});
    var restated = cellWith(2, &.{fact("user", "prefers ", "zig")});
    var changed = cellWith(3, &.{fact("USER", "PREFERS", "Rust")});
    try idx.index(&old);

    var out: std.ArrayList(*MemCell) = .empty;
    defer out.deinit(alloc);
    // Restating the same thing is not a conflict.
    try idx.detect(alloc, &restated, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try idx.detect(alloc, &changed, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "conflict: a different predicate, an empty object, or no facts is never a conflict" {
    const alloc = testing.allocator;
    var idx = ConflictIndex.initWithPolicy(alloc, .{ .mode = .all });
    defer idx.deinit();
    var old = cellWith(1, &.{fact("user", "prefers", "zig")});
    try idx.index(&old);
    var out: std.ArrayList(*MemCell) = .empty;
    defer out.deinit(alloc);

    var other_pred = cellWith(2, &.{fact("user", "dislikes", "rust")});
    try idx.detect(alloc, &other_pred, &out);
    var empty_obj = cellWith(3, &.{fact("user", "prefers", "")});
    try idx.detect(alloc, &empty_obj, &out);
    var no_facts = cellWith(4, &.{});
    try idx.detect(alloc, &no_facts, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "conflict: a cell is superseded only when every one of its facts is contradicted" {
    const alloc = testing.allocator;
    var idx = ConflictIndex.initWithPolicy(alloc, .{ .mode = .all });
    defer idx.deinit();
    var old = cellWith(1, &.{ fact("user", "prefers", "zig"), fact("user", "uses", "vim") });
    try idx.index(&old);
    var out: std.ArrayList(*MemCell) = .empty;
    defer out.deinit(alloc);

    // Contradicts one of two facts: the cell still says something true.
    var half = cellWith(2, &.{fact("user", "prefers", "rust")});
    try idx.index(&half);
    try idx.detect(alloc, &half, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // A later cell contradicts the other fact: now nothing in it survives.
    var rest = cellWith(3, &.{fact("user", "uses", "emacs")});
    try idx.index(&rest);
    try idx.detect(alloc, &rest, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, 1), out.items[0].id);
}

test "conflict: a removed cell no longer conflicts, and a superseded cell is not re-detected" {
    const alloc = testing.allocator;
    var idx = ConflictIndex.initWithPolicy(alloc, .{ .mode = .all });
    defer idx.deinit();
    var old = cellWith(1, &.{fact("a", "b", "1")});
    var mid = cellWith(2, &.{fact("a", "b", "2")});
    var last = cellWith(3, &.{fact("a", "b", "3")});
    try idx.index(&old);
    try idx.index(&mid);
    var out: std.ArrayList(*MemCell) = .empty;
    defer out.deinit(alloc);
    try idx.detect(alloc, &mid, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    idx.remove(out.items[0]);

    out.clearRetainingCapacity();
    try idx.index(&last);
    try idx.detect(alloc, &last, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, 2), out.items[0].id);
}

test "netex: the sweep finds conflicts nobody recorded and stamps them, never deleting" {
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    // The superseded cell is MORE important than its superseder, so it must
    // stay in the active store: conflict_score = importance(winner) = 0.4,
    // net = 0.9 - 0.4 > 0.
    try w.add(.{ .id = 1, .episode = "owner of the plan was alice", .importance = 0.9, .facts = &.{fact("plan", "owner", "alice")} });
    try w.add(.{ .id = 2, .episode = "owner of the plan became bob", .importance = 0.4, .facts = &.{fact("plan", "owner", "bob")} });

    const res = try w.forgetter.sweep(w.mgr, false);
    try testing.expectEqual(@as(usize, 1), res.superseded);
    try testing.expectEqual(@as(usize, 0), res.fuzzied);
    const old = w.mgr.get(1) orelse return error.CellWasDeleted;
    try testing.expect(old.metadata.superseded_at != null);
    try testing.expectEqual(@as(?u64, 2), old.metadata.superseded_by);
    try testing.expectEqual(@as(?i64, null), w.mgr.get(2).?.metadata.superseded_at);

    // The sweep is idempotent: a second one finds nothing new.
    const again = try w.forgetter.sweep(w.mgr, false);
    try testing.expectEqual(@as(usize, 0), again.superseded);
}

test "netex: conflict_score is the superseder's importance, so a weaker old fact becomes a forgetting candidate" {
    var w = try World.init(testing.allocator, THETA_CFG);
    defer w.deinit();
    try w.add(.{ .id = 1, .episode = "owner of the plan was alice", .importance = 0.4, .facts = &.{fact("plan", "owner", "alice")} });
    try w.add(.{ .id = 2, .episode = "owner of the plan became bob", .importance = 0.9, .facts = &.{fact("plan", "owner", "bob")} });

    var plan = try w.plan();
    defer plan.deinit();
    const d = plan.find(1).?;
    try testing.expectApproxEqAbs(@as(f32, 0.9), d.conflict_score, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), d.net_existence, 1e-6);
    try testing.expectEqual(@as(?Forgetter.Reason, .conflicted), d.reason);

    const res = try w.forgetter.sweep(w.mgr, false);
    try testing.expectEqual(@as(usize, 1), res.conflicted);
    // Superseded AND forgotten: still not deleted, and the history reads.
    const kept = w.fuzzy.cells.get(1) orelse return error.CellWasDeleted;
    try testing.expectEqual(@as(?u64, 2), kept.metadata.superseded_by);
    try testing.expect(kept.metadata.superseded_at != null);
}

test "netex: supersession is off when the config says so" {
    var w = try World.init(testing.allocator, .{ .forgetting_threshold = 0.1, .supersede_mode = .off });
    defer w.deinit();
    try w.add(.{ .id = 1, .episode = "owner alice", .facts = &.{fact("plan", "owner", "alice")} });
    try w.add(.{ .id = 2, .episode = "owner bob", .facts = &.{fact("plan", "owner", "bob")} });
    const res = try w.forgetter.sweep(w.mgr, false);
    try testing.expectEqual(@as(usize, 0), res.superseded);
}

// =============================================================================
// Determinism
// =============================================================================

const Verdict = struct { id: u64, reason: ?Forgetter.Reason, net: f32, red: f32, sup: bool };

fn corpus(alloc: std.mem.Allocator, texts: *std.ArrayList([]u8), n: usize, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    const vocab = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango" };
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // 30% copy an earlier text exactly, 20% copy and change one word.
        if (texts.items.len > 0 and rand.uintLessThan(u8, 10) < 3) {
            const src = texts.items[rand.uintLessThan(usize, texts.items.len)];
            try texts.append(alloc, try alloc.dupe(u8, src));
            continue;
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        const words = 8 + rand.uintLessThan(usize, 6);
        for (0..words) |k| {
            if (k > 0) try buf.append(alloc, ' ');
            var num: [8]u8 = undefined;
            try buf.appendSlice(alloc, vocab[rand.uintLessThan(usize, vocab.len)]);
            try buf.appendSlice(alloc, try std.fmt.bufPrint(&num, "{d}", .{rand.uintLessThan(u8, 40)}));
        }
        try texts.append(alloc, try buf.toOwnedSlice(alloc));
    }
}

fn verdicts(alloc: std.mem.Allocator, order: []const usize, texts: []const []u8, imps: []const f32) ![]Verdict {
    var w = try World.init(alloc, THETA_CFG);
    defer w.deinit();
    for (order) |i| try w.add(.{ .id = i + 1, .episode = texts[i], .importance = imps[i] });
    var plan = try w.plan();
    defer plan.deinit();
    const out = try alloc.alloc(Verdict, plan.decisions.len);
    for (plan.decisions, out) |d, *v| v.* = .{ .id = d.id, .reason = d.reason, .net = d.net_existence, .red = d.redundancy, .sup = d.newly_superseded };
    return out;
}

test "netex: the same cell set gives the same decisions in any insertion order" {
    const alloc = testing.allocator;
    var texts: std.ArrayList([]u8) = .empty;
    defer {
        for (texts.items) |t| alloc.free(t);
        texts.deinit(alloc);
    }
    const n = 300;
    try corpus(alloc, &texts, n, 7);
    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();
    var imps: [n]f32 = undefined;
    // Few distinct importances on purpose: ties are where order leaks in.
    for (&imps) |*x| x.* = 0.3 + 0.2 * @as(f32, @floatFromInt(rand.uintLessThan(u8, 4)));

    var order: [n]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    const base = try verdicts(alloc, &order, texts.items, &imps);
    defer alloc.free(base);

    for (0..4) |round| {
        _ = round;
        rand.shuffle(usize, &order);
        const got = try verdicts(alloc, &order, texts.items, &imps);
        defer alloc.free(got);
        try testing.expectEqual(base.len, got.len);
        for (base, got) |a, b| {
            try testing.expectEqual(a.id, b.id);
            try testing.expectEqual(a.reason, b.reason);
            try testing.expectEqual(a.net, b.net);
            try testing.expectEqual(a.red, b.red);
        }
    }
    // The corpus is not trivially all-kept: the comparison above means something.
    var forgotten: usize = 0;
    for (base) |v| {
        if (v.reason != null) forgotten += 1;
    }
    try testing.expect(forgotten > 20);
}

// =============================================================================
// Exactness and cost of the duplicate pass
// =============================================================================

fn byDominance(_: void, a: *const MemCell, b: *const MemCell) bool {
    if (a.metadata.importance_score != b.metadata.importance_score) {
        return a.metadata.importance_score > b.metadata.importance_score;
    }
    return a.id < b.id;
}

test "netex: the prefix-filter duplicate pass agrees with an all-pairs oracle" {
    const alloc = testing.allocator;
    for ([_]u64{ 1, 2, 3 }) |seed| {
        var texts: std.ArrayList([]u8) = .empty;
        defer {
            for (texts.items) |t| alloc.free(t);
            texts.deinit(alloc);
        }
        try corpus(alloc, &texts, 400, seed);
        var w = try World.init(alloc, THETA_CFG);
        defer w.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        for (texts.items, 0..) |t, i| {
            try w.add(.{ .id = i + 1, .episode = t, .importance = 0.2 + 0.1 * @as(f32, @floatFromInt(rand.uintLessThan(u8, 7))) });
        }
        var cells: std.ArrayList(*const MemCell) = .empty;
        defer cells.deinit(alloc);
        var it = w.mgr.sensory.iterator();
        while (it.next()) |e| try cells.append(alloc, e.value_ptr.*);
        std.mem.sort(*const MemCell, cells.items, {}, byDominance);

        // Several thresholds: the filter's prefix length depends on it.
        for ([_]f32{ 0.5, 0.7, 0.85, 0.95 }) |tau| {
            const params: redundancy.Params = .{ .tau = tau, .theta = 0.1 };
            var fast = try redundancy.run(alloc, cells.items, params);
            defer fast.deinit();
            var slow = try redundancy.runBruteForce(alloc, cells.items, params);
            defer slow.deinit();
            try testing.expectEqualSlices(bool, slow.redundant, fast.redundant);
            try testing.expectEqualSlices(f32, slow.redundancy, fast.redundancy);
            // The oracle is all-pairs-ish, the filter must not be worse.
            try testing.expect(fast.jaccard_evals <= slow.jaccard_evals);
        }
    }
}

test "netex: the duplicate pass is sub-quadratic in Jaccard evaluations" {
    const alloc = testing.allocator;
    const sizes = [_]usize{ 1000, 4000 };
    var evals: [sizes.len]u64 = undefined;
    for (sizes, 0..) |n, k| {
        var texts: std.ArrayList([]u8) = .empty;
        defer {
            for (texts.items) |t| alloc.free(t);
            texts.deinit(alloc);
        }
        // Vocabulary grows with the corpus (3 distinct words per cell), as a
        // real store's does; most cells are genuinely unique. A *fixed*
        // vocabulary makes the number of cells sharing a word grow with n,
        // and with it the number of true candidate pairs: that is the
        // documented output-sensitivity, not something an index can remove.
        var prng = std.Random.DefaultPrng.init(5);
        const rand = prng.random();
        for (0..n) |i| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(alloc);
            if (i > 0 and rand.uintLessThan(u8, 10) == 0) {
                try buf.appendSlice(alloc, texts.items[rand.uintLessThan(usize, texts.items.len)]);
            } else {
                for (0..10) |j| {
                    if (j > 0) try buf.append(alloc, ' ');
                    var num: [16]u8 = undefined;
                    try buf.appendSlice(alloc, try std.fmt.bufPrint(&num, "w{d}", .{rand.uintLessThan(u32, @as(u32, @intCast(n * 3)))}));
                }
            }
            try texts.append(alloc, try buf.toOwnedSlice(alloc));
        }
        var w = try World.init(alloc, THETA_CFG);
        defer w.deinit();
        for (texts.items, 0..) |t, i| try w.add(.{ .id = i + 1, .episode = t, .importance = 0.5 });
        var plan = try w.plan();
        defer plan.deinit();
        evals[k] = plan.jaccard_evals;
        // Far below n(n-1)/2.
        const all_pairs: u64 = @as(u64, n) * (n - 1) / 2;
        try testing.expect(plan.jaccard_evals * 20 < all_pairs);
    }
    // 4x the cells must cost well under 16x the evaluations (quadratic).
    try testing.expect(evals[1] < evals[0] * 10 + 10);
}

test "netex: the candidate cap bounds a dense templated corpus and still finds a true duplicate" {
    const alloc = testing.allocator;
    const n: usize = 600;
    const cap: u32 = 32;
    var cfg = THETA_CFG;
    cfg.redundancy_max_candidates = cap;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var w = try World.init(alloc, cfg);
    defer w.deinit();
    // Every pair shares 12 of 14 tokens (Jaccard 0.86 >= tau) and every cell
    // carries its own fact, so nothing is redundant and every pair is a
    // candidate: the worst case for a prefix filter.
    for (0..n) |i| {
        const ep = try std.fmt.allocPrint(a, "ticket closed by the platform team after review in the sprint on friday n{d}", .{i});
        const f = try a.alloc(Fact, 1);
        f[0] = fact(try std.fmt.allocPrint(a, "tk{d}", .{i}), "closed", "yes");
        try w.add(.{ .id = i + 1, .episode = ep, .facts = f, .importance = 0.7 });
    }
    // An exact copy of cell 6, arriving last and less important.
    {
        const ep = try std.fmt.allocPrint(a, "ticket closed by the platform team after review in the sprint on friday n{d}", .{5});
        const f = try a.alloc(Fact, 1);
        f[0] = fact("tk5", "closed", "yes");
        try w.add(.{ .id = n + 1, .episode = ep, .facts = f, .importance = 0.69 });
    }

    var plan = try w.plan();
    defer plan.deinit();
    try testing.expect(plan.jaccard_evals <= (n + 1) * cap);
    // The cap really bit: uncapped this would be ~n^2/2.
    try testing.expect(plan.jaccard_evals * 4 < @as(u64, n) * (n - 1) / 2);
    // The copy shares its rarest token (n5) with its original, so it is
    // probed first and found despite the cap. The cap only costs misses.
    const d = plan.find(n + 1).?;
    try testing.expect(d.reason != null);
    try testing.expect(d.net_existence < 0);
    // No false positives: a capped sweep forgets a subset of what an
    // uncapped one would.
    try testing.expectEqual(@as(usize, 1), plan.countReason(.redundant));
}
