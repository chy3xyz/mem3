//! Recall@10 of the HNSW index against an exhaustive scan, swept over the
//! candidate budget.
//!
//! The corpus, the ground truth and the comparison all live in
//! `src/retrieval/hnsw.zig` next to the code they measure, so the numbers
//! printed here and the ones the unit tests assert cannot drift apart.
//!
//! Run with `zig build example-hnsw-recall`.

const std = @import("std");
const mem3 = @import("mem3");

const hnsw_mod = mem3.retrieval.hnsw;

const EFS = [_]u16{ 10, 32, 50, 100, 200, 400 };

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = mem3.platform.stdio.writeOut(s);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const defaults: mem3.Config = .{};
    out("HNSW recall@{d} vs exhaustive scan\n", .{hnsw_mod.oracle_k});
    out("corpus={d} nodes  dim={d}  queries={d}  ef_construction=200  seed={x}\n", .{
        hnsw_mod.oracle_n,
        hnsw_mod.oracle_dim,
        hnsw_mod.oracle_queries,
        defaults.hnsw_seed,
    });
    out("\n  ef   recall\n", .{});
    out("  ---  ------\n", .{});

    for (EFS) |ef| {
        const r = try hnsw_mod.oracleRecallWith(alloc, ef);
        out("  {d:>3}   {d:.4}\n", .{ ef, r });
    }

    out("\nGraph shape at ef=100:\n", .{});
    var cfg = mem3.Config{};
    cfg.hnsw_ef_search = 100;
    var idx = hnsw_mod.HNSW.init(alloc, cfg, hnsw_mod.oracle_dim);
    defer idx.deinit();
    const corpus = try hnsw_mod.oracleCorpus(alloc);
    defer alloc.free(corpus);
    try hnsw_mod.oracleFill(&idx, corpus);

    out("  nodes={d}  max_level={d}  entry_point={d}\n", .{ idx.count, idx.max_level, idx.entry_point.? });

    var lvl: u8 = 0;
    while (lvl <= idx.max_level) : (lvl += 1) {
        var occupied: usize = 0;
        var total: usize = 0;
        var maxdeg: usize = 0;
        var it = idx.nodes.iterator();
        while (it.next()) |e| {
            const node = e.value_ptr.*;
            if (@as(usize, lvl) < node.neighbors.len) {
                occupied += 1;
                total += node.neighbors[lvl].items.len;
                maxdeg = @max(maxdeg, node.neighbors[lvl].items.len);
            }
        }
        const avg: f64 = if (occupied == 0) 0 else @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(occupied));
        out("  level {d}: {d:>3} nodes present, avg degree {d:.2}, max degree {d}\n", .{ lvl, occupied, avg, maxdeg });
    }
}
