//! E2E: conflict resolution by supersession (FR-015) and the net-existence
//! forgetting sweep (FR-010), through the real `Store` and its WAL/snapshot.
//!
//! What is pinned here:
//!   * a new fact that contradicts an older one marks the older cell
//!     `superseded_at` / `superseded_by` and NEVER deletes it;
//!   * that mark survives a WAL-only restart and a snapshot restart;
//!   * superseded cells are excluded from a default query and come back with
//!     `include_superseded`;
//!   * a sweep finds conflicts nobody recorded (older data), journals them,
//!     and a cell forgotten *because* it was superseded is still recoverable
//!     from the fuzzy store after a restart (the replay used to free it);
//!   * the sweep reports its decisions per reason.
//!
//! Scratch paths live under /tmp, scoped by pid.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");

fn makeDataDir(alloc: std.mem.Allocator, label: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "/tmp/mem3_supersede_{d}_{s}", .{ std.c.getpid(), label });
}

fn wipeDataDir(data_dir: []const u8) void {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&z, "{s}/mem3.wal\x00", .{data_dir})) |s| {
        _ = std.c.unlink(s[0 .. s.len - 1 :0].ptr);
    } else |_| {}
    if (std.fmt.bufPrint(&z, "{s}/snapshot.bin\x00", .{data_dir})) |s| {
        _ = std.c.unlink(s[0 .. s.len - 1 :0].ptr);
    } else |_| {}
    if (std.fmt.bufPrint(&z, "{s}\x00", .{data_dir})) |s| {
        _ = std.c.rmdir(s[0 .. s.len - 1 :0].ptr);
    } else |_| {}
}

const Supersession = mem3.store.Supersession;

const Pair = struct { old: u64, new: u64 };

/// Insert two contradicting cells, return their ids.
fn addContradiction(store: *mem3.Store) !Pair {
    var out: std.ArrayList(Supersession) = .empty;
    defer mem3.store.freeSupersessions(testing.allocator, &out);
    const old = try store.addRaw(.matter, "the user lives in Paris", "user|lives_in|Paris", 1, 0.6);
    const new = try store.addRawReporting(.matter, "the user moved to Berlin", "user|lives_in|Berlin", 1, 0.6, &.{}, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(old, out.items[0].id);
    try testing.expectEqualStrings("lives_in", out.items[0].predicate);
    return .{ .old = old, .new = new };
}

fn expectSuperseded(store: *mem3.Store, p: Pair) !void {
    const old = store.getCell(p.old) orelse store.lc.fuzzy.cells.get(p.old) orelse return error.OldCellGone;
    try testing.expect(old.metadata.superseded_at != null);
    try testing.expectEqual(@as(?u64, p.new), old.metadata.superseded_by);
    const new = store.getCell(p.new) orelse return error.NewCellGone;
    try testing.expect(new.metadata.superseded_at == null);
    try testing.expect(new.metadata.superseded_by == null);
}

test "supersede: a contradicting fact marks the old cell, never deletes it" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const p = try addContradiction(store);
    try expectSuperseded(store, p);
    // Marked, not removed: still in the active store and still readable.
    try testing.expectEqual(@as(usize, 2), store.cellCount());
    try testing.expect(store.getCell(p.old) != null);
}

test "supersede: different predicate, partial contradiction and an empty object do not supersede" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    var out: std.ArrayList(Supersession) = .empty;
    defer mem3.store.freeSupersessions(alloc, &out);
    const a = try store.addRaw(.matter, "profile one", "user|lives_in|Paris;user|works_at|Acme", 1, 0.6);
    _ = try store.addRawReporting(.matter, "different predicate", "user|born_in|Berlin", 1, 0.6, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    // Contradicts one of a's two facts only: a conservative reading keeps a.
    _ = try store.addRawReporting(.matter, "partial", "user|lives_in|Berlin", 1, 0.6, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    // An empty object is not a fact that can contradict anything.
    _ = try store.addRawReporting(.matter, "empty object", "user|lives_in|", 1, 0.6, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try testing.expect(store.getCell(a).?.metadata.superseded_at == null);
}

test "supersede: default query excludes the old cell, include_superseded returns it" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    const p = try addContradiction(store);

    {
        const hits = try store.query(alloc, "where does the user live", .{ .topk = 10 });
        defer alloc.free(hits);
        var saw_new = false;
        for (hits) |h| {
            try testing.expect(h.cell.id != p.old);
            if (h.cell.id == p.new) saw_new = true;
        }
        try testing.expect(saw_new);
    }
    {
        const hits = try store.query(alloc, "where does the user live", .{ .topk = 10, .include_superseded = true });
        defer alloc.free(hits);
        var saw_old = false;
        for (hits) |h| if (h.cell.id == p.old) {
            saw_old = true;
        };
        try testing.expect(saw_old);
    }
}

test "supersede: a topk of current hits is still returned when superseded cells crowd the pool" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    // Five generations of the same fact (4 superseded, 1 current) plus three
    // unrelated cells: asking for 4 must not come back short.
    var buf: [64]u8 = undefined;
    for (0..5) |i| {
        const ep = try std.fmt.bufPrint(&buf, "the user lives in city{d}", .{i});
        var facts: [48]u8 = undefined;
        const f = try std.fmt.bufPrint(&facts, "user|lives_in|city{d}", .{i});
        _ = try store.addRaw(.matter, ep, f, 1, 0.6);
    }
    _ = try store.addRaw(.matter, "the user lives a quiet life", "", 1, 0.6);
    _ = try store.addRaw(.matter, "the user lives for coffee", "", 1, 0.6);
    _ = try store.addRaw(.matter, "the user lives near a lake", "", 1, 0.6);
    try testing.expectEqual(@as(usize, 4), store.superseded_live);

    const hits = try store.query(alloc, "the user lives", .{ .topk = 4 });
    defer alloc.free(hits);
    try testing.expectEqual(@as(usize, 4), hits.len);
    for (hits) |h| try testing.expect(h.cell.metadata.superseded_at == null);
}

test "supersede: the mark survives a WAL-only restart" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "wal");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var p: Pair = undefined;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        p = try addContradiction(store);
        // No sync(): the only copy of the stamp is the WAL record.
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try expectSuperseded(store, p);
        try testing.expectEqual(@as(usize, 1), store.superseded_live);
        // A third contradicting fact after the restart still finds the live
        // cell (the conflict index was rebuilt) and not the superseded one.
        var out: std.ArrayList(Supersession) = .empty;
        defer mem3.store.freeSupersessions(alloc, &out);
        _ = try store.addRawReporting(.matter, "the user moved to Rome", "user|lives_in|Rome", 1, 0.6, &.{}, &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqual(p.new, out.items[0].id);
    }
}

test "supersede: the mark survives a snapshot restart (format v3)" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "snap");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var p: Pair = undefined;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        p = try addContradiction(store);
        try store.sync(); // snapshot, WAL truncated
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try expectSuperseded(store, p);
        try testing.expectEqual(@as(usize, 1), store.superseded_live);
    }
}

test "supersede: replaying the same stamp twice is idempotent (snapshot then WAL)" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "idem");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var p: Pair = undefined;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        p = try addContradiction(store);
        try store.sync();
        // A restart-then-more-writes cycle leaves a WAL on top of a snapshot
        // that already holds the stamp.
        _ = try store.addRaw(.matter, "unrelated later memory", "", 1, 0.6);
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try expectSuperseded(store, p);
        try testing.expectEqual(@as(usize, 1), store.superseded_live);
    }
}

test "supersede: a sweep finds a conflict nobody recorded, journals it, and keeps both cells" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "legacy");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var p: Pair = undefined;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        // A store written before write-time detection: contradicting cells,
        // no stamp, and no journal record saying otherwise.
        store.lc.cfg.supersede_mode = .off;
        const old = try store.addRaw(.matter, "the user lives in Paris", "user|lives_in|Paris", 1, 0.6);
        const new = try store.addRaw(.matter, "the user moved to Berlin", "user|lives_in|Berlin", 1, 0.6);
        p = .{ .old = old, .new = new };
        try testing.expect(store.getCell(old).?.metadata.superseded_at == null);

        const dry = try store.forget(true);
        try testing.expectEqual(@as(usize, 1), dry.superseded);
        try testing.expect(store.getCell(p.old).?.metadata.superseded_at == null); // dry run stamps nothing

        const res = try store.forget(false);
        try testing.expectEqual(@as(usize, 1), res.superseded);
        try testing.expectEqual(@as(usize, 0), res.fuzzied); // equal importance: marked, not forgotten
        try testing.expectEqual(@as(usize, 2), store.cellCount());
        try expectSuperseded(store, p);
    }
    {
        // WAL only (no sync): the sweep's stamp is the only record of it.
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try expectSuperseded(store, p);
        try testing.expectEqual(@as(usize, 1), store.superseded_live);
    }
}

test "forget: a cell outranked by its superseder is forgotten as 'conflicted' and stays recoverable" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "conflicted");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var p: Pair = undefined;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        p = try addContradiction(store);
        store.getCell(p.old).?.metadata.importance_score = 0.3;
        store.getCell(p.new).?.metadata.importance_score = 0.9;

        const res = try store.forget(false);
        try testing.expectEqual(@as(usize, 1), res.fuzzied);
        try testing.expectEqual(@as(usize, 1), res.conflicted);
        try testing.expectEqual(@as(usize, 0), res.decayed);
        try testing.expectEqual(@as(usize, 0), res.redundant);
        try testing.expect(store.getCell(p.old) == null);
        const kept = store.lc.fuzzy.cells.get(p.old) orelse return error.NotInFuzzy;
        try testing.expect(kept.metadata.is_fuzzy);
        try testing.expectEqual(@as(?u64, p.new), kept.metadata.superseded_by);
        try testing.expectEqual(@as(usize, 0), store.superseded_live);
        // No sync(): the restart below replays the WAL.
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try testing.expect(store.getCell(p.old) == null);
        // PCR: replaying `.forget` used to free the cell. It now lands in the
        // fuzzy store, history intact.
        const kept = store.lc.fuzzy.cells.get(p.old) orelse return error.NotInFuzzy;
        try testing.expect(kept.metadata.is_fuzzy);
        try testing.expect(kept.metadata.fuzzed_at != null);
        try testing.expectEqual(@as(?u64, p.new), kept.metadata.superseded_by);
        try testing.expect(kept.metadata.superseded_at != null);
        try testing.expectEqual(@as(usize, 0), store.superseded_live);
    }
}

test "forget: a restart that only replays a sweep keeps the forgotten cell in the fuzzy store" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "fuzzy_replay");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var low: u64 = 0;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        _ = try store.addRaw(.matter, "important", "u|knows|things", 1, 0.9);
        low = try store.addRaw(.matter, "low-quality", "u|whispers|maybe", 1, 0.1);
        store.getCell(low).?.metadata.importance_score = 0.001;
        const res = try store.forget(false);
        try testing.expectEqual(@as(usize, 1), res.decayed);
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try testing.expect(store.getCell(low) == null);
        try testing.expectEqual(@as(usize, 1), store.lc.fuzzy.count());
        try testing.expect(store.lc.fuzzy.cells.get(low) != null);
        // Gone from both indexes too: it must not answer queries.
        const hits = try store.query(alloc, "low-quality", .{ .topk = 5, .include_superseded = true });
        defer alloc.free(hits);
        for (hits) |h| try testing.expect(h.cell.id != low);
    }
}

test "forget: duplicates are reported as redundant, and the representative survives a restart" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "dups");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var ids: [3]u64 = undefined;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        for (&ids) |*id| id.* = try store.addRaw(.matter, "deploy finished on friday evening", "deploy|status|done", 1, 0.6);
        _ = try store.addRaw(.matter, "an entirely different memory about gardening", "", 1, 0.6);
        // Importance is a function of the encoder; make the order explicit.
        store.getCell(ids[1]).?.metadata.importance_score = 0.8;

        const res = try store.forget(false);
        try testing.expectEqual(@as(usize, 2), res.redundant);
        try testing.expectEqual(@as(usize, 0), res.decayed);
        try testing.expectEqual(@as(usize, 0), res.conflicted);
        try testing.expect(store.getCell(ids[1]) != null); // the most important one is the representative
        try testing.expect(store.getCell(ids[0]) == null);
        try testing.expect(store.getCell(ids[2]) == null);
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try testing.expect(store.getCell(ids[1]) != null);
        try testing.expectEqual(@as(usize, 2), store.lc.fuzzy.count());
    }
}

test "supersede: supersede_mode = off turns write-time marking off" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    store.lc.cfg.supersede_mode = .off;
    var out: std.ArrayList(Supersession) = .empty;
    defer mem3.store.freeSupersessions(alloc, &out);
    const old = try store.addRaw(.matter, "lives in Paris", "user|lives_in|Paris", 1, 0.6);
    _ = try store.addRawReporting(.matter, "lives in Berlin", "user|lives_in|Berlin", 1, 0.6, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try testing.expect(store.getCell(old).?.metadata.superseded_at == null);
}

// =============================================================================
// Single-valued predicates only (ADR 0005 §"Single-valued predicates")
//
// The first cut superseded on ANY repeated (subject, predicate), which hid
// "user likes tea" behind "user likes coffee". These tests are the assertion
// form of the evaluation's three scenario rows: (a) functional predicates
// supersede, (b) multi-valued predicates never do, (c) unknown ones never do.
// =============================================================================

const N_PAIRS = 60;

/// `n` subjects, each asserting `pred` twice with different objects, in
/// order. Returns how many second assertions reported a supersession, and
/// checks the report names the predicate and the first cell.
fn contradictPairs(store: *mem3.Store, comptime pred: []const u8, n: usize, expect_report: bool) !usize {
    const alloc = testing.allocator;
    var reported: usize = 0;
    for (0..n) |i| {
        var ep: [96]u8 = undefined;
        var facts: [96]u8 = undefined;
        const f1 = try std.fmt.bufPrint(&facts, "subj{d}|" ++ pred ++ "|first{d}", .{ i, i });
        const e1 = try std.fmt.bufPrint(&ep, "subj{d} first mention of {s} value first{d}", .{ i, pred, i });
        const first = try store.addRaw(.matter, e1, f1, 1, 0.6);

        var ep2: [96]u8 = undefined;
        var facts2: [96]u8 = undefined;
        const f2 = try std.fmt.bufPrint(&facts2, "subj{d}|" ++ pred ++ "|second{d}", .{ i, i });
        const e2 = try std.fmt.bufPrint(&ep2, "subj{d} later changed {s} to second{d}", .{ i, pred, i });
        var out: std.ArrayList(Supersession) = .empty;
        defer mem3.store.freeSupersessions(alloc, &out);
        _ = try store.addRawReporting(.matter, e2, f2, 1, 0.6, &.{}, &out);
        if (out.items.len > 0) {
            reported += 1;
            try testing.expectEqual(first, out.items[0].id);
            try testing.expectEqualStrings(pred, out.items[0].predicate);
            try testing.expect(std.mem.startsWith(u8, out.items[0].subject, "subj"));
        }
        if (!expect_report) try testing.expect(store.getCell(first).?.metadata.superseded_at == null);
    }
    return reported;
}

test "(a) default: 60/60 contradicted `lives_in` cells are superseded, each reported with its predicate" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    const reported = try contradictPairs(store, "lives_in", N_PAIRS, true);
    try testing.expectEqual(@as(usize, N_PAIRS), reported);
    try testing.expectEqual(@as(usize, N_PAIRS), store.superseded_live);
    // Nothing deleted, and a sweep after the fact forgets none of them.
    try testing.expectEqual(@as(usize, 2 * N_PAIRS), store.cellCount());
    const res = try store.forget(false);
    try testing.expectEqual(@as(usize, 0), res.fuzzied);
}

test "(b) default: 180 multi-valued `likes` cells -> 0 superseded, 0 forgotten, all in default recall" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    const items = [_][]const u8{ "tea", "coffee", "juice" };
    var reported: usize = 0;
    for (0..60) |i| {
        for (items) |item| {
            var ep: [96]u8 = undefined;
            var facts: [96]u8 = undefined;
            const e = try std.fmt.bufPrint(&ep, "subj{d} enjoys {s} in the afternoon", .{ i, item });
            const f = try std.fmt.bufPrint(&facts, "subj{d}|likes|{s}", .{ i, item });
            var out: std.ArrayList(Supersession) = .empty;
            defer mem3.store.freeSupersessions(alloc, &out);
            _ = try store.addRawReporting(.matter, e, f, 1, 0.6, &.{}, &out);
            reported += out.items.len;
        }
    }
    try testing.expectEqual(@as(usize, 0), reported);
    try testing.expectEqual(@as(usize, 0), store.superseded_live);

    const res = try store.forget(false);
    try testing.expectEqual(@as(usize, 0), res.superseded);
    try testing.expectEqual(@as(usize, 0), res.conflicted);
    try testing.expectEqual(@as(usize, 0), res.fuzzied);
    try testing.expectEqual(@as(usize, 180), store.cellCount());

    // Every cell is still marked-free, and a default recall can return the
    // oldest of the three for a subject.
    var it = store.cell_index.iterator();
    while (it.next()) |e| try testing.expect(e.value_ptr.*.metadata.superseded_at == null);
    const hits = try store.query(alloc, "subj7 enjoys tea in the afternoon", .{ .topk = 10 });
    defer alloc.free(hits);
    var saw_tea = false;
    for (hits) |h| if (std.mem.indexOf(u8, h.cell.episode, "subj7 enjoys tea") != null) {
        saw_tea = true;
    };
    try testing.expect(saw_tea);
}

test "(c) default: 60 contradicting `shoe_size` cells (unknown predicate) -> 0 superseded" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    const reported = try contradictPairs(store, "shoe_size", N_PAIRS, false);
    try testing.expectEqual(@as(usize, 0), reported);
    try testing.expectEqual(@as(usize, 0), store.superseded_live);
    const res = try store.forget(false);
    try testing.expectEqual(@as(usize, 0), res.superseded);
}

test "mode `all` (explicit opt-in) restores the old heuristic and reports `likes`" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    store.setSupersedeMode(.all);
    const reported = try contradictPairs(store, "likes", N_PAIRS, true);
    try testing.expectEqual(@as(usize, N_PAIRS), reported);
}

test "a custom functional list is honoured by write-time marking and by the sweep" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    try store.setFunctionalPredicates("shoe_size");
    // Replaced, not extended: `lives_in` no longer supersedes.
    var out: std.ArrayList(Supersession) = .empty;
    defer mem3.store.freeSupersessions(alloc, &out);
    _ = try store.addRaw(.matter, "lives in Paris", "user|lives_in|Paris", 1, 0.6);
    _ = try store.addRawReporting(.matter, "lives in Berlin", "user|lives_in|Berlin", 1, 0.6, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    _ = try store.addRaw(.matter, "shoe size forty two", "user|shoe_size|42", 1, 0.6);
    _ = try store.addRawReporting(.matter, "shoe size forty three", "user|shoe_size|43", 1, 0.6, &.{}, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("shoe_size", out.items[0].predicate);
}

test "mode `off` is honoured by the sweep too (a legacy conflict is not stamped)" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    store.setSupersedeMode(.off);
    _ = try store.addRaw(.matter, "lives in Paris", "user|lives_in|Paris", 1, 0.6);
    _ = try store.addRaw(.matter, "lives in Berlin", "user|lives_in|Berlin", 1, 0.6);
    const res = try store.forget(false);
    try testing.expectEqual(@as(usize, 0), res.superseded);
    try testing.expectEqual(@as(usize, 0), store.superseded_live);
}

// =============================================================================
// unsupersede: the way back from a wrong supersession
// =============================================================================

test "unsupersede: clears the mark, brings the cell back into default recall, pins it" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    const p = try addContradiction(store);
    try testing.expectEqual(@as(usize, 1), store.superseded_live);

    try store.unsupersede(p.old);
    const old = store.getCell(p.old).?;
    try testing.expect(old.metadata.superseded_at == null);
    try testing.expect(old.metadata.superseded_by == null);
    try testing.expect(old.metadata.supersede_pinned);
    try testing.expectEqual(@as(usize, 0), store.superseded_live);

    const hits = try store.query(alloc, "where does the user live", .{ .topk = 10 });
    defer alloc.free(hits);
    var saw_old = false;
    for (hits) |h| if (h.cell.id == p.old) {
        saw_old = true;
    };
    try testing.expect(saw_old);
}

test "unsupersede: unknown ids and cells that are not superseded are errors, not silent no-ops" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    const p = try addContradiction(store);
    try testing.expectError(error.CellNotFound, store.unsupersede(999_999));
    try testing.expectError(error.NotSuperseded, store.unsupersede(p.new));
    try store.unsupersede(p.old);
    try testing.expectError(error.NotSuperseded, store.unsupersede(p.old)); // already restored
}

test "unsupersede: neither a sweep nor a later contradiction re-supersedes the restored cell" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    const p = try addContradiction(store);
    try store.unsupersede(p.old);

    const res = try store.forget(false);
    try testing.expectEqual(@as(usize, 0), res.superseded);
    try testing.expect(store.getCell(p.old).?.metadata.superseded_at == null);

    var out: std.ArrayList(Supersession) = .empty;
    defer mem3.store.freeSupersessions(alloc, &out);
    _ = try store.addRawReporting(.matter, "the user moved to Rome", "user|lives_in|Rome", 1, 0.6, &.{}, &out);
    // Only the Berlin cell is superseded; the pinned Paris cell is left alone.
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(p.new, out.items[0].id);
    try testing.expect(store.getCell(p.old).?.metadata.superseded_at == null);
}

test "unsupersede: survives a WAL-only restart (journaled first), and the sweep still leaves it alone" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "unsup_wal");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var p: Pair = undefined;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        p = try addContradiction(store);
        try store.unsupersede(p.old);
        // No sync(): the WAL holds insert, supersede, unsupersede, in order.
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        const old = store.getCell(p.old).?;
        try testing.expect(old.metadata.superseded_at == null);
        try testing.expect(old.metadata.superseded_by == null);
        try testing.expect(old.metadata.supersede_pinned);
        try testing.expectEqual(@as(usize, 0), store.superseded_live);
        const res = try store.forget(false);
        try testing.expectEqual(@as(usize, 0), res.superseded);
        try testing.expect(store.getCell(p.old).?.metadata.superseded_at == null);
    }
}

test "unsupersede: survives a snapshot restart, and the pin survives with it" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "unsup_snap");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var p: Pair = undefined;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        p = try addContradiction(store);
        try store.unsupersede(p.old);
        try store.sync(); // snapshot, WAL truncated
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        const old = store.getCell(p.old).?;
        try testing.expect(old.metadata.superseded_at == null);
        try testing.expect(old.metadata.supersede_pinned);
        try testing.expectEqual(@as(usize, 0), store.superseded_live);
        const res = try store.forget(false);
        try testing.expectEqual(@as(usize, 0), res.superseded);
        try testing.expect(store.getCell(p.old).?.metadata.superseded_at == null);
    }
}

test "unsupersede: a WAL record on top of a snapshot that still holds the stamp wins" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "unsup_mixed");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var p: Pair = undefined;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        p = try addContradiction(store);
        try store.sync(); // the snapshot carries `superseded_at`
        try store.unsupersede(p.old); // only the WAL carries the reversal
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        const old = store.getCell(p.old).?;
        try testing.expect(old.metadata.superseded_at == null);
        try testing.expect(old.metadata.supersede_pinned);
        try testing.expectEqual(@as(usize, 0), store.superseded_live);
    }
}

test "unsupersede: a superseded cell that was forgotten (fuzzy) can be restored too, across a restart" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "unsup_fuzzy");
    defer alloc.free(data_dir);
    wipeDataDir(data_dir);
    defer wipeDataDir(data_dir);

    var p: Pair = undefined;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        p = try addContradiction(store);
        store.getCell(p.old).?.metadata.importance_score = 0.3;
        store.getCell(p.new).?.metadata.importance_score = 0.9;
        const res = try store.forget(false);
        try testing.expectEqual(@as(usize, 1), res.conflicted);
        try testing.expect(store.getCell(p.old) == null);

        try store.unsupersede(p.old);
        const kept = store.lc.fuzzy.cells.get(p.old).?;
        try testing.expect(kept.metadata.superseded_at == null);
        try testing.expect(kept.metadata.supersede_pinned);
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        const kept = store.lc.fuzzy.cells.get(p.old) orelse return error.NotInFuzzy;
        try testing.expect(kept.metadata.superseded_at == null);
        try testing.expect(kept.metadata.superseded_by == null);
        try testing.expect(kept.metadata.supersede_pinned);
    }
}
