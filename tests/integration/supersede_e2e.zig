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

const Pair = struct { old: u64, new: u64 };

/// Insert two contradicting cells, return their ids.
fn addContradiction(store: *mem3.Store) !Pair {
    var out: std.ArrayList(u64) = .empty;
    defer out.deinit(testing.allocator);
    const old = try store.addRaw(.matter, "the user lives in Paris", "user|lives_in|Paris", 1, 0.6);
    const new = try store.addRawReporting(.matter, "the user moved to Berlin", "user|lives_in|Berlin", 1, 0.6, &.{}, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(old, out.items[0]);
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

    var out: std.ArrayList(u64) = .empty;
    defer out.deinit(alloc);
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
        var out: std.ArrayList(u64) = .empty;
        defer out.deinit(alloc);
        _ = try store.addRawReporting(.matter, "the user moved to Rome", "user|lives_in|Rome", 1, 0.6, &.{}, &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqual(p.new, out.items[0]);
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
        store.lc.cfg.supersede_on_conflict = false;
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

test "supersede: supersede_on_conflict = false turns write-time marking off" {
    const alloc = testing.allocator;
    var store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    store.lc.cfg.supersede_on_conflict = false;
    var out: std.ArrayList(u64) = .empty;
    defer out.deinit(alloc);
    const old = try store.addRaw(.matter, "lives in Paris", "user|lives_in|Paris", 1, 0.6);
    _ = try store.addRawReporting(.matter, "lives in Berlin", "user|lives_in|Berlin", 1, 0.6, &.{}, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try testing.expect(store.getCell(old).?.metadata.superseded_at == null);
}
