//! Example program: the researcher's notebook (US1 scenario).
//!
//! Run via: `zig run examples/notebook.zig`
//!
//! What it does:
//! 1. Creates a Goal Poset with 3 project goals (ghw / mem3 / learn3).
//! 2. Encodes 30 MemCells with varying goal bindings.
//! 3. Reports the top cells per source by importance score.

const std = @import("std");
const mem3 = @import("mem3");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.debug.print("=== mem3 example: researcher's notebook ===\n", .{});
    std.debug.print("(Tri-Source Coherence + GHW paradigm end-to-end demo)\n\n", .{});

    // 1. Goal Poset
    var next_id: std.atomic.Value(u64) = .init(1);
    var goals = mem3.GoalPoset.init(alloc);
    defer goals.deinit();
    const g_ghw = try goals.create("build-ghw-kernel", "self-evolving digital life", null, 9, null, 1000, &next_id);
    const g_mem3 = try goals.create("build-mem3", "memory OS", null, 9, null, 1000, &next_id);
    const g_learn3 = try goals.create("learn3-explore", "knowledge graph playground", null, 6, null, 1000, &next_id);
    std.debug.print("created 3 goals: ghw={d}, mem3={d}, learn3={d}\n\n", .{ g_ghw, g_mem3, g_learn3 });

    // 2. Tri-Source Manager
    var mgr = mem3.TriSourceManager.init(alloc, &next_id);
    defer mgr.deinit();
    var lc = mem3.Lifecycle.init(alloc, .{}, &mgr);
    lc.wire();
    defer lc.fuzzy.deinit();

    // 3. Encode 30 cells with varying goal bindings.
    const cells_data: []const struct {
        source: mem3.MemorySource,
        episode: []const u8,
        goal_id: u64,
        relevance: f32,
    } = &.{
        .{ .source = .matter, .episode = "zig 0.17 std.Io replaces std.fs", .goal_id = g_mem3, .relevance = 0.95 },
        .{ .source = .matter, .episode = "io_uring backend on linux", .goal_id = g_mem3, .relevance = 0.7 },
        .{ .source = .form, .episode = "constitution principles drafted", .goal_id = g_mem3, .relevance = 0.9 },
        .{ .source = .form, .episode = "TS-MemCell struct finalized", .goal_id = g_mem3, .relevance = 0.85 },
        .{ .source = .spirit, .episode = "ship v0.1.0-alpha", .goal_id = g_mem3, .relevance = 1.0 },
        .{ .source = .spirit, .episode = "release tag planned for next week", .goal_id = g_mem3, .relevance = 0.8 },
        .{ .source = .matter, .episode = "GHW paper §3.2 mapping table", .goal_id = g_ghw, .relevance = 0.85 },
        .{ .source = .form, .episode = "existence gain dynamics equation", .goal_id = g_ghw, .relevance = 0.95 },
        .{ .source = .form, .episode = "bidirectional communication mechanism", .goal_id = g_ghw, .relevance = 0.9 },
        .{ .source = .spirit, .episode = "compose self-evolution cycle", .goal_id = g_ghw, .relevance = 1.0 },
        .{ .source = .spirit, .episode = "agent kernel design philosophy", .goal_id = g_ghw, .relevance = 0.95 },
        .{ .source = .matter, .episode = "knowledge graph schema v2", .goal_id = g_learn3, .relevance = 0.7 },
        .{ .source = .form, .episode = "graph traversal algorithms survey", .goal_id = g_learn3, .relevance = 0.6 },
        .{ .source = .spirit, .episode = "playground UX vision", .goal_id = g_learn3, .relevance = 0.8 },
        .{ .source = .matter, .episode = "Zig 0.17 release notes", .goal_id = g_mem3, .relevance = 0.6 },
        .{ .source = .matter, .episode = "WAL recovery semantics", .goal_id = g_mem3, .relevance = 0.7 },
        .{ .source = .form, .episode = "HNSW algorithm analysis", .goal_id = g_ghw, .relevance = 0.5 },
        .{ .source = .form, .episode = "category theory semantics", .goal_id = g_ghw, .relevance = 0.6 },
        .{ .source = .spirit, .episode = "Tri-Source Coherence philosophy essay", .goal_id = g_ghw, .relevance = 0.9 },
        .{ .source = .spirit, .episode = "go to ghw weekly", .goal_id = g_ghw, .relevance = 0.5 },
        .{ .source = .matter, .episode = "read paper on Mem0", .goal_id = g_learn3, .relevance = 0.5 },
        .{ .source = .form, .episode = "compare mag vs everos vs mem3", .goal_id = g_learn3, .relevance = 0.6 },
        .{ .source = .spirit, .episode = "play with new lisp", .goal_id = g_learn3, .relevance = 0.5 },
        .{ .source = .matter, .episode = "Zig comptime tricks", .goal_id = g_mem3, .relevance = 0.7 },
        .{ .source = .form, .episode = "type-level programming", .goal_id = g_mem3, .relevance = 0.6 },
        .{ .source = .spirit, .episode = "ship daily", .goal_id = g_mem3, .relevance = 0.9 },
        .{ .source = .matter, .episode = "GHW L4 storage layer", .goal_id = g_ghw, .relevance = 0.8 },
        .{ .source = .form, .episode = "L5 async runtime", .goal_id = g_ghw, .relevance = 0.7 },
        .{ .source = .spirit, .episode = "self-evolution loop", .goal_id = g_ghw, .relevance = 0.9 },
        .{ .source = .matter, .episode = "knowledge graph benchmark", .goal_id = g_learn3, .relevance = 0.5 },
    };

    var encoded: usize = 0;
    for (cells_data) |c| {
        const id = lc.encode(.{
            .source = c.source,
            .episode = c.episode,
            .goal_associations = &.{
                .{ .goal_id = c.goal_id, .relevance = c.relevance, .priority = 5 },
            },
        }) catch |err| {
            std.debug.print("encode failed for '{s}': {s}\n", .{ c.episode, @errorName(err) });
            continue;
        };
        _ = id;
        encoded += 1;
    }
    std.debug.print("encoded {d} cells across all three sources\n", .{encoded});
    std.debug.print("  matter  : {d}\n", .{mgr.countBySource(.matter)});
    std.debug.print("  form    : {d}\n", .{mgr.countBySource(.form)});
    std.debug.print("  spirit  : {d}\n", .{mgr.countBySource(.spirit)});
    std.debug.print("  total   : {d}\n\n", .{mgr.count()});

    // 4. Demonstrate the GHW-prioritized ranking.
    std.debug.print("=== sample ranking (per source) ===\n", .{});
    for ([_]mem3.MemorySource{ .matter, .form, .spirit }) |src| {
        const list = try mgr.getBySource(alloc, src);
        defer alloc.free(list);
        std.debug.print("{s} (top 3 by importance):\n", .{src.label()});
        // Sort by importance descending.
        const sorted = try alloc.alloc(*mem3.MemCell, list.len);
        defer alloc.free(sorted);
        for (list, 0..) |p, i| sorted[i] = p;
        std.mem.sort(*mem3.MemCell, sorted, {}, struct {
            fn lt(_: void, a: *mem3.MemCell, b: *mem3.MemCell) bool {
                return a.metadata.importance_score > b.metadata.importance_score;
            }
        }.lt);
        for (sorted[0..@min(3, sorted.len)]) |p| {
            std.debug.print("  - [{d:.2}] {s}\n", .{ p.metadata.importance_score, p.episode });
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("=== example complete ===\n", .{});
}
