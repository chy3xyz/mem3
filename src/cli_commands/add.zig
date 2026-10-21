//! CLI implementation for `mem3 add`.
//!
//! Per the spec: `mem3 add --source=matter --episode "..." --facts "..."
//!                --foresight "..." --goal-ids 1,2 --relevances 0.8,0.5`
//!
//! On success: prints the assigned MemCell id as JSON (or human-readable).
//!
//! **Constitution compliance**:
//! - Source tag is mandatory (rejected if missing).
//! - Spirit dim is mandatory (rejected if both --foresight and --goal-ids
//!   are empty).
//! - Importance score is computed at encoding time, and its β=0.40
//!   `goal_relevance` term is answered by the Goal Poset, not by the
//!   number the user typed.
//! - The insert goes through `Store.addRaw`, so it is WAL-journaled
//!   before it becomes observable *and* traverses
//!   Goal → Harness → World. `mem3 add` used to hand-roll its own
//!   commit — `mgr.addWithId` + `cell_index.put` + `embed` + `hnsw.insert`
//!   — and therefore produced a cell with no Harness binding, no World
//!   entity and no `CrossLayerLog` entry. The daemon and `mem3 bench`
//!   were already correct, which made that worse than having neither
//!   path correct: the suite was green while the most-used command in
//!   the product violated Principle II.
//!
//! **What the durable record cannot carry**: it holds one goal, so a
//! multi-goal cell is committed as its highest-relevance goal. That is a
//! pre-existing limit of the format, not a new one — but the in-memory
//! cell used to differ from what the next process would replay, and now
//! it does not.
//!
//! **Foresight is durable.** `--foresight "desc|valid_from|valid_until|confidence"`
//! (entries separated by `;`) goes through `Store.addRawWithForesight`
//! into the `memcell_insert` record and the snapshot row. It used to be
//! parsed and discarded, with a warning, so a foresight-only cell came
//! back from a restart without its spirit dimension. A cell that names no
//! goal still carries the synthetic goal id 0 (see `addMemory`), so
//! `dump` shows `"goals":[{"id":0,...}]` next to the real foresight.
//!
//! **Failure behaviour**: none of the failure points (WAL encode, WAL
//! append, HNSW insert, GHW traversal) is swallowed. Each aborts the
//! command with a message on stderr, exit status 1, and an explicit
//! statement of what did and did not persist — and crucially, without
//! printing `added memory id=N`, which is reserved for a fully
//! committed cell.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const core = @import("../core/mod.zig");
const MemorySource = core.MemorySource;
const Fact = core.Fact;
const Foresight = core.Foresight;
const GoalAssociation = core.GoalAssociation;
const store_mod = @import("../store/mod.zig");
const Store = store_mod.Store;
const ghw = @import("../ghw/mod.zig");

/// One memory as the CLI parsed it, before it reaches the Store.
pub const Memory = struct {
    source: MemorySource,
    episode: []const u8,
    facts: []const Fact = &.{},
    foresight: []const Foresight = &.{},
    goal_associations: []const GoalAssociation = &.{},
};

/// Serialize facts to the `"s|p|o;s|p|o"` form `Store` parses on both
/// sides of the WAL. Caller owns the returned slice.
fn factsPayload(alloc: std.mem.Allocator, facts: []const Fact) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    for (facts, 0..) |f, i| {
        if (i > 0) try buf.append(alloc, ';');
        try buf.appendSlice(alloc, f.subject);
        try buf.append(alloc, '|');
        try buf.appendSlice(alloc, f.predicate);
        try buf.append(alloc, '|');
        try buf.appendSlice(alloc, f.object);
    }
    return buf.toOwnedSlice(alloc);
}

/// The association that will carry the cell: the highest stated
/// relevance, lowest id on a tie.
///
/// Highest relevance because β=0.40 is `max(relevance)` — picking
/// anything else would change `importance_score`, which is the one
/// number the WAL record and the constitutional formula both agree on.
/// Lowest id on a tie so the same command twice produces the same cell.
fn primaryAssociation(goals: []const GoalAssociation) GoalAssociation {
    var best = goals[0];
    for (goals[1..]) |g| {
        if (g.relevance > best.relevance) best = g;
    }
    return best;
}

/// Commit one memory through `Store` and return its id.
///
/// Everything below is a pure decision; the only mutation is
/// `Store.addRaw`, which owns the ordering:
///
///   1. reserve id       — `errdefer` returns it to the pool on failure
///   2. build cell       — encoder validation + importance scoring
///   3. WAL append       — Constitution VII: journal BEFORE observable
///   4. commit           — manager + cell_index + embed + HNSW
///   5. 外拓              — Goal → Harness → World + CrossLayerLog
///
/// Steps 1-3 mutate nothing `mem3 query` / `mem3 dump` can see, so a
/// failure at step 3 leaves nothing behind to roll back. The old
/// hand-rolled path got the same ordering right but stopped at step 4,
/// which is why every `mem3 add` cell was invisible to two of the three
/// GHW layers.
///
/// The spirit-dimension check is repeated here on purpose: `addRaw`
/// always appends a goal association, so the encoder's own
/// `SpiritDimMissing` check can never fire on this path, and dropping it
/// would silently make `--source=matter --episode x --facts "a|b|c"` a
/// legal add.
pub fn addMemory(store: *Store, alloc: std.mem.Allocator, mem: Memory) !u64 {
    return addMemoryReporting(store, alloc, mem, null);
}

/// `addMemory` that also reports, in `superseded_out`, the older cells the
/// new one contradicted and so marked `superseded_at` (FR-015).
pub fn addMemoryReporting(
    store: *Store,
    alloc: std.mem.Allocator,
    mem: Memory,
    superseded_out: ?*std.ArrayList(store_mod.Supersession),
) !u64 {
    if (mem.foresight.len == 0 and mem.goal_associations.len == 0) {
        return core.Error.SpiritDimMissing;
    }

    // The β=0.40 term reads the live Goal Poset from here on, so a
    // tombstoned goal stops scoring. Store.init does not do this yet
    // (it would have to reach into `lc.encoder`, which is store.zig's
    // to change), so the CLI wires it for the one Store it owns.
    store.lc.encoder.goals = store.goals;

    const facts_str = try factsPayload(alloc, mem.facts);
    defer alloc.free(facts_str);

    const primary = if (mem.goal_associations.len > 0)
        primaryAssociation(mem.goal_associations)
    else
        // No goal named: id 0 is the synthetic root, which is how
        // `Store.encodeAcrossLayers` spells "nothing to traverse".
        GoalAssociation{ .goal_id = 0, .relevance = 0.5, .priority = 5 };

    return store.addRawReporting(mem.source, mem.episode, facts_str, primary.goal_id, primary.relevance, mem.foresight, superseded_out);
}

pub fn run(alloc: std.mem.Allocator, parsed: cli.Parsed) !void {

    var store = try cli_common.openStore(alloc, parsed);
    defer store.deinit();

    var source: ?MemorySource = null;
    var episode: ?[]const u8 = null;
    var facts = std.ArrayList(Fact).empty;
    defer facts.deinit(alloc);
    var foresights = std.ArrayList(Foresight).empty;
    defer foresights.deinit(alloc);
    var goal_ids = std.ArrayList(u64).empty;
    defer goal_ids.deinit(alloc);
    var relevances = std.ArrayList(f32).empty;
    defer relevances.deinit(alloc);

    for (parsed.args.items) |arg| {
        if (std.mem.eql(u8, arg.key, "--source")) {
            const v = arg.value orelse cli_common.fatal("error: --source requires a value\n", .{});
            source = try cli_common.parseSource(v);
        } else if (std.mem.eql(u8, arg.key, "--episode") or std.mem.eql(u8, arg.key, "--ep")) {
            episode = arg.value;
        } else if (std.mem.eql(u8, arg.key, "--facts")) {
            const v = arg.value orelse cli_common.fatal("error: --facts requires a value\n", .{});
            try parseFactsConst(alloc, v, &facts);
        } else if (std.mem.eql(u8, arg.key, "--foresight")) {
            const v = arg.value orelse cli_common.fatal("error: --foresight requires a value\n", .{});
            try parseForesightConst(alloc, v, &foresights);
        } else if (std.mem.eql(u8, arg.key, "--goal-ids")) {
            const v = arg.value orelse cli_common.fatal("error: --goal-ids requires a value\n", .{});
            try parseU64List(alloc, v, &goal_ids);
        } else if (std.mem.eql(u8, arg.key, "--relevances")) {
            const v = arg.value orelse cli_common.fatal("error: --relevances requires a value\n", .{});
            try parseF32List(alloc, v, &relevances);
        }
    }

    if (source == null) cli_common.fatal("error: --source is required (matter|form|spirit)\n", .{});
    if (episode == null) cli_common.fatal("error: --episode is required\n", .{});

    var goal_associations = std.ArrayList(GoalAssociation).empty;
    defer goal_associations.deinit(alloc);
    const n = @min(goal_ids.items.len, relevances.items.len);
    for (0..n) |i| {
        try goal_associations.append(alloc, .{
            .goal_id = goal_ids.items[i],
            .relevance = relevances.items[i],
            .priority = 5,
        });
    }
    // If user gave goal_ids but no relevances (or vice versa), still
    // provide a sensible default association so the spirit dimension
    // is non-empty.
    if (goal_associations.items.len == 0 and goal_ids.items.len > 0) {
        for (goal_ids.items) |gid| {
            try goal_associations.append(alloc, .{
                .goal_id = gid,
                .relevance = 0.5,
                .priority = 5,
            });
        }
    }

    var superseded: std.ArrayList(store_mod.Supersession) = .empty;
    defer store_mod.freeSupersessions(alloc, &superseded);
    const id = addMemoryReporting(store, alloc, .{
        .source = source.?,
        .episode = episode.?,
        .facts = facts.items,
        .foresight = foresights.items,
        .goal_associations = goal_associations.items,
    }, &superseded) catch |err| {
        // Nothing has been committed to memory, so there is nothing to
        // roll back: `Store.addRaw` returns the reserved id to the pool
        // and leaves no cell behind. Report the failure and exit
        // non-zero rather than printing `added memory id=N`.
        cli_common.fatal("error: add failed: {s}; nothing was persisted.\n", .{@errorName(err)});
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    if (parsed.json) {
        try cli_common.appendFmt(&out, alloc, "{{\"id\":{d}", .{id});
        // Additive: only present when this add replaced an older fact.
        if (superseded.items.len > 0) {
            try out.appendSlice(alloc, ",\"superseded\":");
            try store_mod.appendSupersededJson(alloc, &out, superseded.items);
        }
        try out.append(alloc, '}');
    } else {
        try cli_common.appendFmt(&out, alloc, "added memory id={d}", .{id});
        if (superseded.items.len > 0) {
            try out.appendSlice(alloc, " (superseded:");
            for (superseded.items) |sp| try cli_common.appendFmt(&out, alloc, " {d} [{s}]", .{ sp.id, sp.predicate });
            try out.appendSlice(alloc, "; undo with `mem3 unsupersede <id>`)");
        }
    }
    cli_common.println(out.items);
}

// Zero-copy parsers: produce slices that reference `s` directly. `s` must
// outlive the resulting structs.

fn parseFactsConst(alloc: std.mem.Allocator, s: []const u8, out: *std.ArrayList(Fact)) !void {
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        var pit = std.mem.splitScalar(u8, part, '|');
        const subject = pit.next() orelse "";
        const predicate = pit.next() orelse "";
        const object = pit.next() orelse "";
        try out.append(alloc, .{
            .subject = subject,
            .predicate = predicate,
            .object = object,
            .confidence = 1.0,
            .source = "user_input",
        });
    }
}

/// One `desc|valid_from|valid_until|confidence` entry. Absent or
/// unparseable trailing fields fall back to 0 / 0 / 0.5. The result
/// borrows `part`. Shared by the CLI and the MCP `memory_add` tool so the
/// two surfaces cannot disagree about the spelling.
pub fn parseForesightEntry(part: []const u8) Foresight {
    var pit = std.mem.splitScalar(u8, part, '|');
    const desc = pit.next() orelse "";
    const from = std.fmt.parseInt(i64, pit.next() orelse "0", 10) catch 0;
    const until = std.fmt.parseInt(i64, pit.next() orelse "0", 10) catch 0;
    const conf = std.fmt.parseFloat(f32, pit.next() orelse "0.5") catch 0.5;
    return .{
        .description = desc,
        .valid_from = from,
        .valid_until = until,
        .confidence = conf,
    };
}

fn parseForesightConst(alloc: std.mem.Allocator, s: []const u8, out: *std.ArrayList(Foresight)) !void {
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try out.append(alloc, parseForesightEntry(part));
    }
}

fn parseU64List(alloc: std.mem.Allocator, s: []const u8, out: *std.ArrayList(u64)) !void {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const v = try std.fmt.parseInt(u64, part, 10);
        try out.append(alloc, v);
    }
}

fn parseF32List(alloc: std.mem.Allocator, s: []const u8, out: *std.ArrayList(f32)) !void {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const v = try std.fmt.parseFloat(f32, part);
        try out.append(alloc, v);
    }
}
// =============================================================================
// Tests
//
// `mem3 add` is the CLI's primary insert path, and until it went through
// `Store` it produced a cell that existed in the manager, the cell index
// and the vector index and in *no* GHW layer. These assert the three
// observables the hand-rolled commit could never produce — a Harness
// binding, a World entity, and a CrossLayerLog entry — rather than
// re-asserting that a call happened.
//
// ## Collection caveat, read this before believing a green run
//
// `zig build test` collects `test` blocks only from files named directly
// in the comptime block of a root source file. `src/main.zig` names
// `cli_commands/goal.zig` but NOT `cli_commands/add.zig`, and nothing
// else in the tree imports this file except the dispatch switch at
// `src/main.zig:138` — which is inside a function body, so Zig's lazy
// analysis never registers these blocks with the runner. Until
// `_ = @import("cli_commands/add.zig");` is added to that comptime
// block, the tests below do not run under `zig build test`.
//
// ## Test hygiene
//
// Every store here is `data_dir = null` (in-memory, no WAL, no files),
// so the suite touches no fixed path and leaves nothing behind for the
// next run. No printing of any kind: Zig's test runner speaks its
// protocol over the process pipes and a stderr write from inside a test
// desynchronises it, killing the binary while `zig build test` still
// exits 0.
// =============================================================================

/// A store with no seeded goals, so the goal under test is the only one
/// and a harness/world count of 1 means 1 unambiguously.
fn freshStore(alloc: std.mem.Allocator) !*Store {
    return Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
}

test "mem3 add traverses Goal → Harness → World" {
    const alloc = std.testing.allocator;
    var store = try freshStore(alloc);
    defer store.deinit();

    const gid = try store.createGoal("ship the release", "cut v0.2.0", null, 9, null, 1_700_000_000_000);
    try std.testing.expectEqual(@as(usize, 0), store.harnessCount());
    try std.testing.expectEqual(@as(usize, 0), store.worldCount());
    try std.testing.expectEqual(@as(usize, 0), store.crossLayerLog().count());

    const id = try addMemory(store, alloc, .{
        .source = .matter,
        .episode = "the tag was pushed",
        .facts = &.{.{ .subject = "a", .predicate = "b", .object = "c", .confidence = 1.0, .source = "user_input" }},
        .goal_associations = &.{.{ .goal_id = gid, .relevance = 0.8, .priority = 5 }},
    });

    // (1) A Harness binding for the goal.
    try std.testing.expectEqual(@as(usize, 1), store.harnessCount());
    try std.testing.expect(store.harnessForGoal(gid) != null);
    // (2) A World entity holding its situated state.
    try std.testing.expectEqual(@as(usize, 1), store.worldCount());
    try std.testing.expect(store.worldEntityForGoal(gid) != null);
    // (3) A CrossLayerLog entry for each hop, in layer order.
    const xlog = store.crossLayerLog();
    try std.testing.expectEqual(@as(usize, 2), xlog.count());
    const e0 = xlog.nth(0).?;
    const e1 = xlog.nth(1).?;
    try std.testing.expect(e0.from == .goal and e0.to == .harness);
    try std.testing.expect(e0.direction == .outward);
    try std.testing.expectEqual(id, e0.cell_id.?);
    try std.testing.expect(e1.from == .harness and e1.to == .world);
    try std.testing.expect(e1.direction == .outward);
    try std.testing.expect(ghw.isValidDirection(e0.direction, e0.from, e0.to));
    try std.testing.expect(ghw.isValidDirection(e1.direction, e1.from, e1.to));

    // And the Goal layer itself holds the binding, which is what the
    // meta-goal sweep reads.
    try std.testing.expectEqual(id, store.goals.memcellsFor(gid)[0]);

    // The cell is still a normal, queryable memory: routing through
    // `Store` must not have traded observability for GHW state.
    try std.testing.expect(store.getCell(id) != null);
    try std.testing.expectEqual(@as(usize, 1), store.cellCount());
    try std.testing.expectEqualStrings("the tag was pushed", store.getCell(id).?.episode);
}

test "mem3 add refuses a memory with no spirit dimension and commits nothing" {
    const alloc = std.testing.allocator;
    var store = try freshStore(alloc);
    defer store.deinit();

    const gid = try store.createGoal("g", "", null, 5, null, 1_700_000_000_000);

    // `Store.addRaw` always appends a goal association, so the encoder's
    // own SpiritDimMissing check can never fire on the path `add` now
    // takes. This is the check that has to survive that.
    try std.testing.expectError(core.Error.SpiritDimMissing, addMemory(store, alloc, .{
        .source = .matter,
        .episode = "an orphan",
        .facts = &.{.{ .subject = "a", .predicate = "b", .object = "c", .confidence = 1.0, .source = "user_input" }},
        .goal_associations = &.{},
    }));

    // Nothing observable anywhere — not in the manager, not in the GHW
    // layers, and no WAL record could exist because the journal is
    // downstream of this check.
    try std.testing.expectEqual(@as(usize, 0), store.cellCount());
    try std.testing.expectEqual(@as(usize, 0), store.harnessCount());
    try std.testing.expectEqual(@as(usize, 0), store.worldCount());
    try std.testing.expectEqual(@as(usize, 0), store.crossLayerLog().count());
    try std.testing.expect(store.getCell(1) == null);
    _ = gid;
}

test "mem3 add commits the highest-relevance goal of a multi-goal cell" {
    const alloc = std.testing.allocator;
    var store = try freshStore(alloc);
    defer store.deinit();

    const low = try store.createGoal("low", "", null, 5, null, 1_700_000_000_000);
    const high = try store.createGoal("high", "", null, 5, null, 1_700_000_000_000);

    const id = try addMemory(store, alloc, .{
        .source = .spirit,
        .episode = "two goals, one cell",
        .goal_associations = &.{
            .{ .goal_id = low, .relevance = 0.3, .priority = 5 },
            .{ .goal_id = high, .relevance = 0.9, .priority = 5 },
        },
    });

    // The durable record carries one goal, so the one it carries has to
    // be the one β=0.40 actually scored — otherwise in-memory and replay
    // disagree about why the cell is important.
    const cell = store.getCell(id).?;
    try std.testing.expectEqual(@as(usize, 1), cell.goal_associations.len);
    try std.testing.expectEqual(high, cell.goal_associations[0].goal_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), cell.goal_associations[0].relevance, 1e-6);
    try std.testing.expect(store.harnessForGoal(high) != null);
    try std.testing.expect(store.harnessForGoal(low) == null);
}

test "mem3 add scores a tombstoned goal at zero relevance" {
    // The CLI is a caller like any other, so before the encoder consulted
    // the Poset it happily scored `--relevances 0.9` against a goal the
    // system had already retired. Asserted end-to-end through `add`.
    const alloc = std.testing.allocator;

    var live_store = try freshStore(alloc);
    defer live_store.deinit();
    const live = try live_store.createGoal("live", "", null, 5, null, 1_700_000_000_000);
    const live_id = try addMemory(live_store, alloc, .{
        .source = .spirit,
        .episode = "x",
        .goal_associations = &.{.{ .goal_id = live, .relevance = 0.9, .priority = 5 }},
    });

    var dead_store = try freshStore(alloc);
    defer dead_store.deinit();
    const dead = try dead_store.createGoal("dead", "", null, 5, null, 1_700_000_000_000);
    // pending → unrealized → tombstoned is the only legal route; the
    // poset refuses a direct tombstone until the goal has been unrealized
    // for seven days.
    try dead_store.updateGoalStatus(dead, .unrealized, 1_700_000_000_000);
    try dead_store.updateGoalStatus(dead, .tombstoned, 1_700_000_000_000 + 8 * 86_400_000);
    const dead_id = try addMemory(dead_store, alloc, .{
        .source = .spirit,
        .episode = "x",
        .goal_associations = &.{.{ .goal_id = dead, .relevance = 0.9, .priority = 5 }},
    });

    const live_score = live_store.getCell(live_id).?.metadata.importance_score;
    const dead_score = dead_store.getCell(dead_id).?.metadata.importance_score;

    // 0.30 (α) + 0.36 (β·0.9) + 0.06 (γ·0.2) vs 0.30 + 0 + 0.06.
    try std.testing.expectApproxEqAbs(@as(f32, 0.72), live_score, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.36), dead_score, 1e-4);

    // The traversal still happened for the retired goal — a tombstone is
    // not a deletion, so the binding and the World entity stay. PCR is
    // about the score, not about erasing the record.
    try std.testing.expect(dead_store.harnessForGoal(dead) != null);
    try std.testing.expectEqual(@as(usize, 2), dead_store.crossLayerLog().count());
}

test "mem3 add commits a foresight-only cell with its foresight" {
    // `--foresight` was parsed and then dropped on the way to `Store`, so
    // the cell that `dump` listed had `foresight = []`.
    const alloc = std.testing.allocator;
    var store = try freshStore(alloc);
    defer store.deinit();

    const id = try addMemory(store, alloc, .{
        .source = .spirit,
        .episode = "it will rain on friday",
        .foresight = &.{.{ .description = "rain", .valid_from = 10, .valid_until = 20, .confidence = 0.9 }},
    });

    const cell = store.getCell(id).?;
    try std.testing.expectEqual(@as(usize, 1), cell.foresight.len);
    try std.testing.expectEqualStrings("rain", cell.foresight[0].description);
    try std.testing.expectEqual(@as(i64, 10), cell.foresight[0].valid_from);
    try std.testing.expectEqual(@as(i64, 20), cell.foresight[0].valid_until);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), cell.foresight[0].confidence, 1e-6);
}

test "mem3 add parses a --foresight entry as desc|valid_from|valid_until|confidence" {
    const f = parseForesightEntry("rain|10|20|0.9");
    try std.testing.expectEqualStrings("rain", f.description);
    try std.testing.expectEqual(@as(i64, 10), f.valid_from);
    try std.testing.expectEqual(@as(i64, 20), f.valid_until);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), f.confidence, 1e-6);
    // Absent trailing fields keep the documented defaults.
    const g = parseForesightEntry("just a description");
    try std.testing.expectEqual(@as(i64, 0), g.valid_from);
    try std.testing.expectEqual(@as(i64, 0), g.valid_until);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), g.confidence, 1e-6);
}
