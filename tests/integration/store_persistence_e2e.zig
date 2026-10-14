//! E2E test: Store persistence — insert cells, "restart" by
//! closing + reopening the same data dir, verify the cells come back.
//!
//! This is the test that v0.1.0-alpha's "constitution tests" never
//! actually exercised. Before the refactor, every CLI command ran
//! in-memory only; the WAL was implemented but never round-tripped.
//! After the refactor, every CLI command goes through `Store` which
//! honors `--data-dir`. This test is the regression guard for that
//! invariant.

const std = @import("std");
const testing = std.testing;
const mem3 = @import("mem3");

// Test-local allocator for synthetic data_dir strings. We can't
// return a `[]u8` into a function-local buffer (it would dangle
// the moment the function returns), and a static scratch buffer
// is wrong because successive calls overwrite earlier values
// (the iso_a/iso_b test pattern proves this). Allocate on the
// test's general-purpose allocator instead; callers are expected
// to `defer alloc.free(...)` the returned slice.
fn makeDataDir(alloc: std.mem.Allocator, label: []const u8) ![]u8 {
    // /tmp with a PID suffix to avoid cross-test contamination
    // and to skip the project's data/ dir (which has a stale
    // mem3.wal file that confuses the splitter). PID ensures
    // concurrent test runs don't collide.
    return std.fmt.allocPrint(
        alloc,
        "/tmp/mem3_e2e_{d}_{s}",
        .{ std.c.getpid(), label },
    );
}

fn wipeDataDir(data_dir: []const u8) void {
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

test "E2E: insert 5 cells, restart, verify all survive" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "insert5");

    defer alloc.free(data_dir);
    // First run: insert 5 cells.
    {
        wipeDataDir(data_dir);
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        try testing.expect(store.isDurable());

        _ = try store.addRaw(.matter, "alpha memory", "user|likes|coffee", 1, 0.7);
        _ = try store.addRaw(.form, "beta insight", "user|knows|kubernetes", 1, 0.6);
        _ = try store.addRaw(.spirit, "gamma purpose", "user|wants|harmony", 2, 0.9);
        _ = try store.addRaw(.matter, "delta observation", "", 3, 0.5);
        _ = try store.addRaw(.form, "epsilon question", "world|has|meaning", 2, 0.4);

        try testing.expectEqual(@as(usize, 5), store.cellCount());

        // Manually trigger a snapshot so the second run starts from
        // the snapshot baseline (still has the WAL delta records).
        try store.sync();
    }

    // Second run: same data dir, expect everything to come back.
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        try testing.expectEqual(@as(usize, 5), store.cellCount());
        try testing.expectEqual(@as(usize, 2), store.cellCountBySource(.matter));
        try testing.expectEqual(@as(usize, 2), store.cellCountBySource(.form));
        try testing.expectEqual(@as(usize, 1), store.cellCountBySource(.spirit));

        // Verify each cell by episode text.
        var saw_alpha = false;
        var saw_gamma = false;
        var saw_epsilon = false;
        const cells = try store.allCells(alloc);
        defer alloc.free(cells);
        for (cells) |c| {
            if (std.mem.eql(u8, c.episode, "alpha memory")) saw_alpha = true;
            if (std.mem.eql(u8, c.episode, "gamma purpose")) saw_gamma = true;
            if (std.mem.eql(u8, c.episode, "epsilon question")) saw_epsilon = true;
        }
        try testing.expect(saw_alpha);
        try testing.expect(saw_gamma);
        try testing.expect(saw_epsilon);

        wipeDataDir(data_dir);
    }
}

test "E2E: goal list reflects defaults and survives restart with user goals" {
    // Rewritten: this used to carry a comment excusing itself because
    // "the current goal-create path doesn't WAL-append", so it could
    // only assert the re-seeded defaults. `createGoal` is now WAL-first
    // and `takeSnapshot` re-journals goals into the fresh WAL, so a
    // user-created goal must genuinely survive a restart — which is
    // the stronger property and the one actually worth testing.
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "goal1");

    defer alloc.free(data_dir);
    const user_goal_name = "user-created-goal";
    {
        wipeDataDir(data_dir);
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        const gid = try store.createGoal(
            user_goal_name,
            "created before restart",
            null,
            9,
            null,
            0,
        );
        try testing.expect(gid != 0);
        try store.sync();
    }

    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        const goals = try store.listGoals(alloc);
        defer alloc.free(goals);

        try testing.expect(goals.len >= 3);
        var saw_general = false;
        var saw_research = false;
        var saw_system = false;
        var saw_user = false;
        for (goals) |g| {
            if (std.mem.eql(u8, g.name, "general")) saw_general = true;
            if (std.mem.eql(u8, g.name, "research")) saw_research = true;
            if (std.mem.eql(u8, g.name, "system")) saw_system = true;
            if (std.mem.eql(u8, g.name, user_goal_name)) saw_user = true;
        }
        try testing.expect(saw_general);
        try testing.expect(saw_research);
        try testing.expect(saw_system);
        // The point of the rewrite: this used to be impossible to assert.
        try testing.expect(saw_user);

        wipeDataDir(data_dir);
    }
}

test "E2E: snapshot+replay vs no-snapshot — both recover" {
    // Both paths are valid recovery modes: snapshot-only (no new WAL
    // records) and snapshot+WAL (snapshot is base, WAL is delta).
    // The code must handle both correctly.
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "snap_replay");

    defer alloc.free(data_dir);
    // Run 1: 3 cells + sync. Run 2: open (snapshot-only recovery).
    {
        wipeDataDir(data_dir);
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        _ = try store.addRaw(.matter, "a", "", 1, 0.5);
        _ = try store.addRaw(.form, "b", "", 1, 0.5);
        _ = try store.addRaw(.spirit, "c", "", 1, 0.5);
        try store.sync();
    }
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try testing.expectEqual(@as(usize, 3), store.cellCount());

        // Add a new cell; with a snapshot on disk, the WAL gets a
        // single record for the new insert.
        _ = try store.addRaw(.matter, "d (after snapshot)", "", 1, 0.5);
        try testing.expectEqual(@as(usize, 4), store.cellCount());
    }
    // Run 3: fresh open, expect 4 cells (snapshot 3 + WAL delta 1).
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try testing.expectEqual(@as(usize, 4), store.cellCount());

        wipeDataDir(data_dir);
    }
}

test "E2E: forgetting sweep removes cells, restart reflects changes" {
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "forget");

    defer alloc.free(data_dir);
    // Run 1: insert 3 cells; mark one as low-importance to ensure
    // it gets fuzzied.
    {
        wipeDataDir(data_dir);
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        const keep_id = try store.addRaw(.matter, "important", "u|knows|things", 1, 0.9);
        _ = try store.addRaw(.matter, "ephemeral", "u|forgot|something", 1, 0.5);

        // Force low importance on the third cell.
        const fuzz_id = try store.addRaw(.matter, "low-quality", "u|whispers|maybe", 1, 0.1);
        if (store.getCell(fuzz_id)) |c| c.metadata.importance_score = 0.001;

        const result = try store.forget(false);
        try testing.expect(result.fuzzied >= 1);
        try testing.expect(store.cellCount() < 3);
        // keep_id must still be there.
        try testing.expect(store.getCell(keep_id) != null);

        try store.sync();
    }

    // Run 2: the fuzzied cells should still be absent on restart.
    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();
        try testing.expect(store.cellCount() < 3);

        var saw_ephemeral = false;
        const cells = try store.allCells(alloc);
        defer alloc.free(cells);
        for (cells) |c| {
            if (std.mem.eql(u8, c.episode, "important")) {
                try testing.expect(c.metadata.importance_score > 0.5);
            }
            if (std.mem.eql(u8, c.episode, "ephemeral")) saw_ephemeral = true;
        }
        // High-importance "important" cell must survive.
        var saw_important = false;
        for (cells) |c| {
            if (std.mem.eql(u8, c.episode, "important")) saw_important = true;
        }
        try testing.expect(saw_important);

        wipeDataDir(data_dir);
    }
}

test "E2E: in-memory mode is correctly isolated from durable mode" {
    // Two stores with different `data_dir` settings must not see each
    // other's data. This guards against a regression where the
    // `--data-dir` flag accidentally falls through to a global.
    const alloc = testing.allocator;
    const data_dir_a = try makeDataDir(alloc, "iso_a");
    const data_dir_b = try makeDataDir(alloc, "iso_b");

    defer alloc.free(data_dir_a);
    defer alloc.free(data_dir_b);
    wipeDataDir(data_dir_a);
    wipeDataDir(data_dir_b);

    {
        var a = try mem3.Store.init(alloc, .{ .data_dir = data_dir_a });
        defer a.deinit();
        _ = try a.addRaw(.matter, "alpha-in-a", "", 1, 0.5);
    }
    {
        var b = try mem3.Store.init(alloc, .{ .data_dir = data_dir_b });
        defer b.deinit();
        try testing.expectEqual(@as(usize, 0), b.cellCount());
        _ = try b.addRaw(.matter, "beta-in-b", "", 1, 0.5);
    }
    {
        var a = try mem3.Store.init(alloc, .{ .data_dir = data_dir_a });
        defer a.deinit();
        try testing.expectEqual(@as(usize, 1), a.cellCount());
        try testing.expect(a.isDurable());
        var inmem = try mem3.Store.init(alloc, .{ .data_dir = null });
        defer inmem.deinit();
        try testing.expect(!inmem.isDurable());
        try testing.expectEqual(@as(usize, 0), inmem.cellCount());
    }

    wipeDataDir(data_dir_a);
    wipeDataDir(data_dir_b);
}
test "E2E: goal status survives a restart (WAL goal_update)" {
    // `updateGoalStatus` used to mutate only the in-memory poset, so
    // `mem3 goal status <id> in_progress` reported success and then
    // silently reverted to `pending` on the next process. The record
    // type `goal_update = 0x11` was already reserved in wal.zig and
    // simply unused. This test fails against that behaviour.
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "goalstatus");
    defer alloc.free(data_dir);
    defer wipeDataDir(data_dir);

    const goal_name = "status-persistence-probe";
    {
        wipeDataDir(data_dir);
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        const gid = try store.createGoal(goal_name, "status probe", null, 5, null, 0);
        try store.updateGoalStatus(gid, .in_progress, 1_700_000_000_000);
        try store.sync();
    }

    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        const goals = try store.listGoals(alloc);
        defer alloc.free(goals);

        var found = false;
        for (goals) |g| {
            if (!std.mem.eql(u8, g.name, goal_name)) continue;
            found = true;
            try testing.expectEqual(mem3.core.GoalStatus.in_progress, g.status);
        }
        try testing.expect(found);
    }
}

test "E2E: non-default goal status survives snapshot truncation" {
    // `rejournalGoals` exists so that truncating the WAL when a
    // snapshot is taken does not delete user goals. But `goal_create`
    // carries no status and `GoalPoset.create` always starts at
    // `.pending`, so without an explicit `goal_update` every completed
    // goal silently reverted to pending at the next snapshot. This
    // exercises exactly that path: sync() truncates the WAL.
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "goaltrunc");
    defer alloc.free(data_dir);
    defer wipeDataDir(data_dir);

    const goal_name = "truncation-status-probe";
    {
        wipeDataDir(data_dir);
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        const gid = try store.createGoal(goal_name, "truncation probe", null, 5, null, 0);
        try store.updateGoalStatus(gid, .completed, 1_700_000_000_000);
        // sync() -> takeSnapshot() -> truncate WAL + rejournalGoals
        try store.sync();
    }

    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        const goals = try store.listGoals(alloc);
        defer alloc.free(goals);

        var found = false;
        for (goals) |g| {
            if (!std.mem.eql(u8, g.name, goal_name)) continue;
            found = true;
            try testing.expectEqual(mem3.core.GoalStatus.completed, g.status);
        }
        try testing.expect(found);
    }
}

test "E2E: hyperedges survive a restart (hyperedge_add is WAL-journaled)" {
    // `Store.addHyperedge` used to insert straight into the in-memory
    // hypergraph with no journal, even though `mem3 hyperedge add`'s own
    // doc comment promised "durable (snapshot+wal) when --data-dir is
    // set". The whole graph — and therefore every `multiHop` answer —
    // vanished on restart.
    const alloc = testing.allocator;
    const data_dir = try makeDataDir(alloc, "edge");
    defer alloc.free(data_dir);
    defer wipeDataDir(data_dir);

    var first_id: u64 = 0;
    var second_id: u64 = 0;
    var edge_id: u64 = 0;
    {
        wipeDataDir(data_dir);
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        first_id = try store.addRaw(.matter, "persistence layer uses a WAL", "a=b", 1, 0.5);
        second_id = try store.addRaw(.form, "the WAL is truncated at snapshot", "c=d", 1, 0.5);

        const nodes = try alloc.dupe(u64, &[_]u64{ first_id, second_id });
        defer alloc.free(nodes);
        edge_id = try store.addHyperedge(.{
            .id = 0,
            .edge_type = .causal,
            .nodes = nodes,
            .weight = 0.8,
            .source_weights = .{ 0.5, 0.3, 0.2 },
            .confidence = 0.7,
            .created_at = 1_700_000_000_000,
        });
        try store.sync();
    }

    {
        var store = try mem3.Store.init(alloc, .{ .data_dir = data_dir });
        defer store.deinit();

        const edges = try store.allHyperedges(alloc);
        defer alloc.free(edges);

        try testing.expect(edges.len >= 1);
        var found = false;
        for (edges) |e| {
            if (e.id != edge_id) continue;
            found = true;
            try testing.expectEqual(@as(usize, 2), e.nodes.len);
            try testing.expectEqual(mem3.EdgeType.causal, e.edge_type);
            try testing.expectEqual(@as(f32, 0.8), e.weight);
        }
        try testing.expect(found);
        try testing.expect(store.hyperedgeCount() >= 1);
    }
}
