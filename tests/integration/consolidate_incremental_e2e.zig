//! E2E: `Store.consolidate` over a long-lived process and across a restart.
//!
//! The unit tests in `tests/unit/consolidator_incremental.zig` drive
//! `Consolidator` directly. What they cannot see is the wiring: that
//! `Store` owns the consolidator's cache for the process's lifetime (so a
//! second `consolidate` is incremental), frees it on `deinit` (the test
//! allocator fails the test otherwise), and that the abstracts it journals
//! still carry the representative's foresight through the WAL.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");

fn dataDir(alloc: std.mem.Allocator, label: []const u8) ![]u8 {
    // /tmp, pid-scoped, like the other e2e tests: never inside the repo.
    return std.fmt.allocPrint(alloc, "/tmp/mem3_e2e_{d}_{s}", .{ std.c.getpid(), label });
}

fn wipe(dir: []const u8) void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{s}/mem3.wal\x00", .{dir})) |z| {
        _ = std.c.unlink(z[0 .. z.len - 1 :0].ptr);
    } else |_| {}
    if (std.fmt.bufPrint(&buf, "{s}/snapshot.bin\x00", .{dir})) |z| {
        _ = std.c.unlink(z[0 .. z.len - 1 :0].ptr);
    } else |_| {}
    if (std.fmt.bufPrint(&buf, "{s}\x00", .{dir})) |z| {
        _ = std.c.rmdir(z[0 .. z.len - 1 :0].ptr);
    } else |_| {}
}

/// Abstracts are the only cells created with this decay rate.
fn findAbstract(alloc: std.mem.Allocator, store: *mem3.Store) !?u64 {
    const cells = try store.allCells(alloc);
    defer alloc.free(cells);
    for (cells) |c| {
        if (c.metadata.decay_rate == 0.005) return c.id;
    }
    return null;
}

test "E2E: repeated Store.consolidate is incremental, tracks forgetting, and its abstracts keep foresight across restart" {
    const alloc = testing.allocator;
    const dir = try dataDir(alloc, "consol_inc");
    defer alloc.free(dir);
    wipe(dir);
    defer wipe(dir);

    const fs = [_]mem3.Foresight{
        .{ .description = "the migration finishes", .valid_from = 1_700_000_000_000, .valid_until = 1_900_000_000_000, .confidence = 0.8 },
    };
    const same = "the migration plan is approved";

    var abstract_id: u64 = 0;
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = dir });
        defer store.deinit();

        // Lowest id carries the foresight, so it is the cluster's
        // representative and the abstract must inherit it.
        const rep = try store.addRawWithForesight(.matter, same, "", 1, 0.9, &fs);
        const dup1 = try store.addRaw(.matter, same, "", 1, 0.8);
        _ = try store.addRaw(.matter, same, "", 1, 0.7);
        _ = try store.addRaw(.form, "unrelated kubernetes node pool", "", 1, 0.9);
        try testing.expect(rep < dup1);

        const before = store.cellCount();
        try testing.expectEqual(@as(usize, 1), try store.consolidate());
        try testing.expectEqual(before + 1, store.cellCount());
        // The first pass clustered what existed; the abstract it made is
        // not in the cache until the next pass notices it.
        try testing.expectEqual(before, store.lc.consolidator.cachedCells());

        abstract_id = (try findAbstract(alloc, store)) orelse return error.TestExpectedCellMissing;
        const made = store.getCell(abstract_id) orelse return error.TestExpectedCellMissing;
        try testing.expectEqual(@as(usize, 1), made.foresight.len);
        try testing.expectEqualStrings("the migration finishes", made.foresight[0].description);

        // Second pass in the same process: the previous abstract is the
        // only new cell, and the cluster (now 4 members) makes another.
        try testing.expectEqual(@as(usize, 1), try store.consolidate());
        try testing.expectEqual(before + 1, store.lc.consolidator.cachedCells());

        // Forget one original, consolidate again: the cache must drop it.
        if (store.getCell(dup1)) |c| c.metadata.importance_score = 0.001;
        const swept = try store.forget(false);
        try testing.expect(swept.fuzzied >= 1);
        try testing.expect(store.getCell(dup1) == null);
        const cells_at_pass = store.cellCount();
        const made3 = try store.consolidate();
        try testing.expectEqual(cells_at_pass, store.lc.consolidator.cachedCells());
        try testing.expectEqual(cells_at_pass + made3, store.cellCount());
    }

    // A fresh process has no cache; recovery must still hand back the
    // abstract with its foresight, which only works if the WAL record for
    // it carried the foresight.
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = dir });
        defer store.deinit();
        const back = store.getCell(abstract_id) orelse return error.TestExpectedCellMissing;
        try testing.expectEqual(@as(usize, 1), back.foresight.len);
        try testing.expectEqualStrings("the migration finishes", back.foresight[0].description);
        // And the one-shot CLI shape: a cold consolidator over the
        // recovered store does a full pass without complaint.
        try testing.expect(store.lc.consolidator.cachedCells() == 0);
        _ = try store.consolidate();
        try testing.expect(store.lc.consolidator.cachedCells() > 0);
    }
}
