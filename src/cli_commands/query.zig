//! CLI implementation for `mem3 query`.
//!
//! Per the spec: `mem3 query "text" --topk 10 [--source-filter M,F,S]`
//!
//! v0.1.0 query is in-memory only. v0.2.0 will load from WAL on startup.
//!
//! For US1 acceptance, the query:
//! 1. Embeds the text via StubEmbedder.
//! 2. Searches HNSW for top-k candidates by cosine.
//! 3. Returns id list sorted by score (descending).

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const core = @import("../core/mod.zig");
const MemorySource = core.MemorySource;
const HNSW = @import("../retrieval/hnsw.zig").HNSW;
const StubEmbedder = @import("../retrieval/embedder.zig").StubEmbedder;
const config = @import("../core/config.zig").Config;

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
        std.debug.print("error: query text required\n", .{});
        return error.MissingFlag;
    }

    // Build an empty in-memory HNSW for the demo.
    var hnsw = HNSW.init(alloc, .{}, 384);
    defer hnsw.deinit();
    var emb = StubEmbedder.init(384);
    const qvec = try emb.embed(alloc, query_text.?);
    defer alloc.free(qvec);

    // No corpus in this minimal demo: just embed and report.
    const results = try hnsw.search(alloc, qvec, topk);
    defer alloc.free(results);

    if (p.json) {
        std.debug.print("{{\"query\":\"", .{});
        // simpler: just print the id list as JSON
        std.debug.print("[", .{});
        for (results, 0..) |r, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("{d}", .{r.id});
        }
        std.debug.print("]}}\n", .{});
    } else {
        std.debug.print("query: \"{s}\" — {d} results\n", .{ query_text.?, results.len });
        for (results) |r| {
            std.debug.print("  id={d} score={d:.4}\n", .{ r.id, r.score });
        }
    }
}
