//! CLI implementation for `mem3 query`.
//!
//! Per the spec: `mem3 query "text" --topk 10 [--source-filter M,F,S]
//! [--include-superseded]`
//!
//! ## Why this reads the Store
//!
//! v0.1.0 built a throwaway `HNSW.init()` and searched *that*, so the
//! index was empty on every invocation and `mem3 query` always reported
//! zero results regardless of the corpus. The store already owns a
//! populated index: `Store.commitBuiltCell` embeds each cell's episode
//! and inserts it into `store.hnsw`, and the WAL replay path routes
//! through the same commit. So the fix is to search `store.hnsw` rather
//! than build a second, empty one.
//!
//! ## The recall path
//!
//! 1. Embed the text with the store's StubEmbedder.
//! 2. Search `store.hnsw` for dense candidates (over-fetched 3x so that
//!    filtering and re-ranking still have material to work with).
//! 3. Apply `--source-filter` / `--goal-ids`, re-rank by GHW goal
//!    relevance and importance, truncate to `--topk`.
//!
//! Ranking mirrors the server's `POST /api/query` so the CLI and the
//! HTTP surface agree on ordering and score.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const core = @import("../core/mod.zig");
const MemorySource = core.MemorySource;
const MemCell = core.MemCell;
const RerankContext = @import("../retrieval/reranker.zig").RerankContext;

/// A ranked hit. Score is cosine similarity after GHW-prioritised
/// re-ranking; see `rerank`.
const Hit = struct {
    id: u64,
    score: f32,
};

pub fn run(alloc: Allocator, p: cli.Parsed) !void {
    var query_text: ?[]const u8 = null;
    var topk: usize = 10;
    var source_filter: std.ArrayList(MemorySource) = .empty;
    defer source_filter.deinit(alloc);
    var goal_ids: std.ArrayList(u64) = .empty;
    defer goal_ids.deinit(alloc);

    // First positional = query text.
    for (p.args.items) |arg| {
        if (std.mem.eql(u8, arg.key, "positional")) {
            if (query_text == null) {
                query_text = arg.value;
            }
        } else if (std.mem.eql(u8, arg.key, "--topk") or std.mem.eql(u8, arg.key, "-k")) {
            const v = arg.value orelse return error.MissingFlag;
            topk = std.fmt.parseInt(usize, v, 10) catch 10;
        } else if (std.mem.eql(u8, arg.key, "--source-filter")) {
            const v = arg.value orelse return error.MissingFlag;
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |s| {
                if (s.len == 0) continue;
                try source_filter.append(alloc, try MemorySource.fromString(s));
            }
        } else if (std.mem.eql(u8, arg.key, "--goal-ids")) {
            const v = arg.value orelse return error.MissingFlag;
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |s| {
                if (s.len == 0) continue;
                try goal_ids.append(alloc, try std.fmt.parseInt(u64, s, 10));
            }
        }
    }

    if (query_text == null) {
        cli_common.eprintln("error: query text required (usage: mem3 query \"text\" [--topk N])");
        return error.MissingFlag;
    }
    const text = query_text.?;

    // Same durable store `add` / `dump` / `inspect` use, so results
    // survive across CLI invocations when --data-dir matches.
    var store = try cli_common.openStore(alloc, p);
    defer store.deinit();

    const qvec = try store.emb.embed(alloc, text);
    defer alloc.free(qvec);

    // Superseded cells (an old fact a newer one contradicts) are history,
    // not answers: dropped unless `--include-superseded`. Over-fetch by as
    // many as exist so `topk` current hits can still come back.
    const include_superseded = cli_common.hasSwitch(p, "--include-superseded");
    const extra = if (include_superseded) 0 else @min(store.superseded_live, topk * 3);

    // Over-fetch: the dense stage only needs to supply candidates.
    const dense = store.hnsw.search(alloc, qvec, topk * 3 + extra) catch &.{};
    defer {
        // `catch &.{}` hands back a static empty slice; freeing that is
        // not ours to do.
        if (dense.len > 0) alloc.free(dense);
    }

    // Candidates after filtering, before GHW re-ranking.
    var cands = std.ArrayList(RerankContext.Pair).empty;
    defer cands.deinit(alloc);
    for (dense) |r| {
        const cell = store.getCell(r.id) orelse continue;
        if (!include_superseded and cell.metadata.superseded_at != null) continue;
        if (source_filter.items.len > 0 and !matchesSource(source_filter.items, cell.source)) continue;
        if (goal_ids.items.len > 0 and !matchesGoal(cell, goal_ids.items)) continue;
        try cands.append(alloc, .{ .id = r.id, .score = r.score, .cell = cell });
    }

    // The real GHW re-ranker (goal bonus x existence x recency), not the
    // two-factor inline copy this used to carry. `--goal-ids` becomes
    // the query's goal scope, so the bonus is now query-specific.
    var rr = RerankContext{
        .alloc = alloc,
        .cfg = store.lc.cfg,
        .goals = store.goals,
        .query_goal_ids = goal_ids.items,
    };
    const reranked = try rr.rerankPairs(alloc, cands.items);
    defer alloc.free(reranked);

    var ranked = std.ArrayList(Hit).empty;
    defer ranked.deinit(alloc);
    for (reranked) |sc| {
        try ranked.append(alloc, .{ .id = sc.cell.id, .score = sc.final_score });
    }

    const shown = ranked.items[0..@min(topk, ranked.items.len)];

    if (p.json) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, "{\"query\":[");
        for (shown, 0..) |r, i| {
            if (i > 0) try buf.append(alloc, ',');
            try cli_common.appendFmt(&buf, alloc, "{d}", .{r.id});
        }
        try cli_common.appendFmt(&buf, alloc, "],\"count\":{d}}}", .{shown.len});
        cli_common.println(buf.items);
    } else {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        try cli_common.appendFmt(&buf, alloc, "query: \"{s}\" — {d} results", .{ text, shown.len });
        cli_common.println(buf.items);
        for (shown) |r| {
            buf.clearRetainingCapacity();
            try cli_common.appendFmt(&buf, alloc, "  id={d} score={d:.4}", .{ r.id, r.score });
            cli_common.println(buf.items);
        }
    }
}

fn matchesSource(filter: []const MemorySource, source: MemorySource) bool {
    for (filter) |f| {
        if (f == source) return true;
    }
    return false;
}

fn matchesGoal(cell: *const MemCell, wanted: []const u64) bool {
    for (cell.goal_associations) |ga| {
        for (wanted) |w| {
            if (ga.goal_id == w) return true;
        }
    }
    return false;
}