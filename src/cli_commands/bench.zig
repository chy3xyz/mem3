//! `mem3 bench` — the in-process smoke benchmark suite.
//!
//! ## Scope, and why it exists separately from `zig build bench`
//!
//! The constitutional performance table (`.specify/memory/constitution.md`)
//! is **release-blocking** and is measured by the seven-benchmark suite
//! under `bench/`, which sweeps 100K-cell corpora and takes minutes.
//! That is the wrong thing to run when you want to know whether the
//! thing still works after a small change.
//!
//! This command is the developer-loop suite: a few thousand cells,
//! seconds, in-process, no dataset download. It exists because the
//! dispatch table advertises `mem3 bench` — a command that printed
//! "not yet implemented" while looking, in `--help`, like a working
//! one.
//!
//! ## Honesty rules this file follows
//!
//! * Metric keys match the constitutional table so the two outputs are
//!   diffable at a glance, and every row carries the same
//!   `target` / `target_op` reference values.
//! * **These numbers do not gate anything.** Every metric is emitted
//!   with `"gate": false` and the payload carries `scope: "smoke"` plus
//!   the workload it actually ran, because a P95 measured at 2K cells
//!   says nothing about the P95 the constitution gates on at 100K.
//!   Emitting a `pass` against the release targets at 1/50th the scale
//!   would be a lie with a JSON syntax highlighting it.
//! * Rows this suite cannot honestly measure (LongMemEval accuracy
//!   needs the dataset; binary size needs the release artifact) are
//!   emitted as `null` with a `reason`, not omitted and not guessed.

const std = @import("std");
const platform_clock = @import("../platform/clock.zig");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const store_mod = @import("../store/mod.zig");
const Store = store_mod.Store;
const MemorySource = @import("../core/mod.zig").MemorySource;
const EdgeType = @import("../core/mod.zig").EdgeType;

/// Workload size. Kept small on purpose: the whole suite must finish in
/// single-digit seconds in a Debug build, which is how `zig build`
/// builds by default. The full-scale numbers live in `bench/` behind
/// `zig build bench`.
const WORKLOAD_CELLS: usize = 600;
const WORKLOAD_QUERIES: usize = 50;
const WORKLOAD_EDGES: usize = 200;
const WORKLOAD_TOPK: usize = 10;
/// Vector corpus for the index-build row. Smaller than the cell corpus
/// on purpose: HNSW insert is the most expensive step in a Debug build
/// (milliseconds per vector), and this row measures the index, not the
/// encoder.
const WORKLOAD_INDEX_VECTORS: usize = 400;
const MULTIHOP_SEEDS: usize = 1000;
const MULTIHOP_HOPS: u8 = 3;

/// Constitutional targets, copied from the performance table. They are
/// *reference values* here, not pass/fail thresholds — see the module
/// doc comment.
const CONSTITUTION = struct {
    const write_throughput = 10_000.0; // cells/sec
    const recall_p95_ms = 10.0;
    const hnsw_build_sec = 30.0;
    const multihop_ms = 5.0;
    const cold_start_ms = 200.0;
    const footprint_bytes: f64 = 500 * 1024 * 1024;
};

const Metric = struct {
    key: []const u8,
    value: ?f64,
    unit: []const u8,
    target: ?f64,
    target_op: []const u8,
    /// Always false in this suite. Present so the shape matches the
    /// release-gate output and a reader never has to guess.
    gate: bool = false,
    reason: ?[]const u8 = null,

    /// `null` when there is no reference target — never `false`, which
    /// would read as "missed the target" for a row that has none.
    fn meetsTarget(self: Metric) ?bool {
        const v = self.value orelse return null;
        const t = self.target orelse return null;
        return if (std.mem.eql(u8, self.target_op, ">=")) v >= t else v < t;
    }

    fn writeJson(self: Metric, buf: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
        try buf.appendSlice(alloc, "{\"metric\":");
        try cli_common.appendJsonString(buf, alloc, self.key);
        if (self.value) |v| {
            try cli_common.appendFmt(buf, alloc, ",\"value\":{d:.6}", .{v});
        } else {
            try buf.appendSlice(alloc, ",\"value\":null");
        }
        try buf.appendSlice(alloc, ",\"unit\":");
        try cli_common.appendJsonString(buf, alloc, self.unit);
        if (self.target) |t| {
            try cli_common.appendFmt(buf, alloc, ",\"target\":{d:.6}", .{t});
        } else {
            try buf.appendSlice(alloc, ",\"target\":null");
        }
        try buf.appendSlice(alloc, ",\"target_op\":");
        try cli_common.appendJsonString(buf, alloc, self.target_op);
        try cli_common.appendFmt(buf, alloc, ",\"gate\":{}", .{self.gate});
        // `meets_reference_target` is a comparison against the reference
        // target, not a pass/fail signal at this scale; it is null when
        // the row has no target.
        if (self.meetsTarget()) |meets| {
            try cli_common.appendFmt(buf, alloc, ",\"meets_reference_target\":{}", .{meets});
        } else {
            try buf.appendSlice(alloc, ",\"meets_reference_target\":null");
        }
        if (self.reason) |r| {
            try buf.appendSlice(alloc, ",\"reason\":");
            try cli_common.appendJsonString(buf, alloc, r);
        }
        try buf.append(alloc, '}');
    }
};

pub fn run(alloc: std.mem.Allocator, p: cli.Parsed) !void {
    const total_start = nowNs();
    var metrics: std.ArrayList(Metric) = .empty;
    defer metrics.deinit(alloc);

    // A caller-supplied --data-dir makes the run durable (and writes
    // only there). Without one the run is pure in-memory, so `mem3
    // bench` never creates a `data/` directory in the working tree.
    const data_dir: ?[]const u8 = if (p.data_dir.len == 0 or std.mem.eql(u8, p.data_dir, "data")) null else p.data_dir;

    const cold_start = try measureColdStart(alloc, data_dir);
    try metrics.append(alloc, .{
        .key = "cold_start",
        .value = @as(f64, @floatFromInt(cold_start)) / 1_000_000.0,
        .unit = "ms",
        .target = CONSTITUTION.cold_start_ms,
        .target_op = "<",
    });

    const store = try Store.init(alloc, .{ .data_dir = data_dir, .seed_default_goals = true });
    defer store.deinit();

    // --- Write throughput -------------------------------------------------
    const write_ns = try writeCorpus(alloc, store);
    const throughput = @as(f64, @floatFromInt(WORKLOAD_CELLS)) /
        (@as(f64, @floatFromInt(write_ns)) / 1e9);
    try metrics.append(alloc, .{
        .key = "memcell_write_throughput",
        .value = throughput,
        .unit = "cells/sec",
        .target = CONSTITUTION.write_throughput,
        .target_op = ">=",
    });

    // Edges are built after the corpus: multi-hop traversal over an
    // edgeless graph would measure nothing but the seed loop.
    try buildEdges(alloc, store);

    // --- HNSW index build -------------------------------------------------
    // The store embeds and indexes on every commit, so the index build
    // is re-measured here on its own vector corpus rather than being
    // inferred from the write phase.
    const build_ns = try measureHnswBuild(alloc, store);
    try metrics.append(alloc, .{
        .key = "hnsw_index_build",
        .value = @as(f64, @floatFromInt(build_ns)) / 1e9,
        .unit = "sec",
        .target = CONSTITUTION.hnsw_build_sec,
        .target_op = "<",
    });

    // --- Multi-hop traversal ---------------------------------------------
    const multihop_ns = try measureMultiHop(alloc, store);
    try metrics.append(alloc, .{
        .key = "multi_hop_traversal",
        .value = @as(f64, @floatFromInt(multihop_ns)) / @as(f64, @floatFromInt(MULTIHOP_SEEDS)) / 1_000_000.0,
        .unit = "ms/seed",
        .target = CONSTITUTION.multihop_ms,
        .target_op = "<",
    });

    // --- Recall latency ---------------------------------------------------
    const recall = try measureRecall(alloc, store);
    try metrics.append(alloc, .{
        .key = "recall_topk_p50_latency",
        .value = recall.p50_ms,
        .unit = "ms",
        .target = null,
        .target_op = "<",
    });
    try metrics.append(alloc, .{
        .key = "recall_topk_p95_latency",
        .value = recall.p95_ms,
        .unit = "ms",
        .target = CONSTITUTION.recall_p95_ms,
        .target_op = "<",
    });
    try metrics.append(alloc, .{
        .key = "recall_topk_p99_latency",
        .value = recall.p99_ms,
        .unit = "ms",
        .target = null,
        .target_op = "<",
    });

    // --- Footprint -------------------------------------------------------
    try metrics.append(alloc, .{
        .key = "memory_footprint",
        .value = maxRssBytes(),
        .unit = "bytes",
        .target = CONSTITUTION.footprint_bytes,
        .target_op = "<",
        .reason = "process peak RSS at end of run, not an isolated 100K-cell corpus",
    });

    // --- Rows this suite cannot measure ----------------------------------
    try metrics.append(alloc, .{
        .key = "longmemeval_accuracy",
        .value = null,
        .unit = "ratio",
        .target = 0.80,
        .target_op = ">=",
        .reason = "requires the LongMemEval dataset; not part of the smoke suite",
    });
    try metrics.append(alloc, .{
        .key = "single_binary_size",
        .value = null,
        .unit = "bytes",
        .target = 10 * 1024 * 1024,
        .target_op = "<",
        .reason = "measured on the release artifact by `wc -c zig-out/bin/mem3`, not in-process",
    });

    const total_ns = nowNs() - total_start;

    try emit(alloc, p, metrics.items, data_dir, total_ns, store);
}

// =============================================================================
// Measurements
// =============================================================================

const Recall = struct { p50_ms: f64, p95_ms: f64, p99_ms: f64 };

/// `Store.init` alone: the daemon's readiness path. A separate store is
/// built so the measurement is not polluted by an already-warm store.
fn measureColdStart(alloc: std.mem.Allocator, data_dir: ?[]const u8) !u64 {
    const start = nowNs();
    const s = try Store.init(alloc, .{ .data_dir = data_dir });
    const ns = nowNs() - start;
    s.deinit();
    return ns;
}

fn writeCorpus(alloc: std.mem.Allocator, store: *Store) !u64 {
    var facts_buf: [128]u8 = undefined;
    var episode_buf: [128]u8 = undefined;

    const start = nowNs();
    var i: usize = 0;
    while (i < WORKLOAD_CELLS) : (i += 1) {
        // Deterministic corpus so a regression is comparable run to
        // run. Three sources rotate so every encode path is exercised.
        const episode = try std.fmt.bufPrint(&episode_buf, "episode {d}: the subject observed event {d}", .{ i, i * 7 % 23 });
        const facts = try std.fmt.bufPrint(&facts_buf, "subject{d}|predicate{d}|object{d}", .{ i, i % 11, i % 5 });
        _ = try store.addRaw(sourceFor(i), episode, facts, 1, 0.5);
    }
    const ns = nowNs() - start;
    _ = alloc;
    return ns;
}

/// Chain cells into a small hypergraph. `addHyperedge` copies the node
/// list, so the caller still owns `nodes`.
fn buildEdges(alloc: std.mem.Allocator, store: *Store) !void {
    const total = store.cellCount();
    if (total < 3) return;

    const edge_types = [_]EdgeType{ .causal, .temporal, .associative, .goal };
    const count = @min(WORKLOAD_EDGES, total - 1);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const a: u64 = @intCast(i + 1);
        const b: u64 = @intCast(i + 2);
        const c: u64 = @intCast(i + 3);
        const nodes = try alloc.alloc(u64, 3);
        defer alloc.free(nodes);
        nodes[0] = a;
        nodes[1] = b;
        nodes[2] = c;

        // Weights rotate so the three-source split is not a constant.
        const source_weights: [3]f32 = switch (i % 3) {
            0 => .{ 1.0, 0.0, 0.0 },
            1 => .{ 0.5, 0.5, 0.0 },
            else => .{ 0.34, 0.33, 0.33 },
        };
        _ = try store.addHyperedge(.{
            .id = 0,
            .edge_type = edge_types[i % edge_types.len],
            .nodes = nodes,
            .weight = 0.5,
            .source_weights = source_weights,
            .confidence = 0.75,
            .created_at = @intCast(i),
            .metadata = null,
        });
    }
}

fn measureHnswBuild(alloc: std.mem.Allocator, store: *Store) !u64 {
    var episode_buf: [96]u8 = undefined;

    // Embeddings first, outside the timed region: this row is the index
    // build, not the embedder.
    var vectors: std.ArrayList([]f32) = .empty;
    defer {
        for (vectors.items) |v| alloc.free(v);
        vectors.deinit(alloc);
    }
    var i: usize = 0;
    while (i < WORKLOAD_INDEX_VECTORS) : (i += 1) {
        const episode = try std.fmt.bufPrint(&episode_buf, "vector corpus entry {d}", .{i});
        const v = try store.emb.embed(alloc, episode);
        try vectors.append(alloc, v);
    }

    const start = nowNs();
    for (vectors.items, 0..) |v, vi| {
        try store.hnsw.insert(@as(u64, vi) + 1_000_000, v);
    }
    return nowNs() - start;
}

fn measureMultiHop(alloc: std.mem.Allocator, store: *Store) !u64 {
    const total = store.cellCount();
    if (total < 2) return 0;

    var seeds: std.ArrayList(u64) = .empty;
    defer seeds.deinit(alloc);
    const n = @min(MULTIHOP_SEEDS, total);
    var i: usize = 0;
    while (i < n) : (i += 1) seeds.append(alloc, @intCast(i + 1)) catch |err| return err;

    const start = nowNs();
    const reached = try store.multiHop(alloc, seeds.items, MULTIHOP_HOPS, 0.0, null);
    const ns = nowNs() - start;
    alloc.free(reached);
    return ns;
}

fn measureRecall(alloc: std.mem.Allocator, store: *Store) !Recall {
    var queries: std.ArrayList([]u8) = .empty;
    defer {
        for (queries.items) |q| alloc.free(q);
        queries.deinit(alloc);
    }
    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(alloc);

    var buf: [96]u8 = undefined;
    var i: usize = 0;
    while (i < WORKLOAD_QUERIES) : (i += 1) {
        const q = try alloc.dupe(u8, try std.fmt.bufPrint(&buf, "event {d} observed", .{i * 3 % 23}));
        try queries.append(alloc, q);

        const start = nowNs();
        const hits = try store.query(alloc, q, .{ .topk = WORKLOAD_TOPK });
        const ns = nowNs() - start;
        alloc.free(hits);
        try samples.append(alloc, ns);
    }

    std.mem.sort(u64, samples.items, {}, std.sort.asc(u64));
    return .{
        .p50_ms = percentileMs(samples.items, 0.50),
        .p95_ms = percentileMs(samples.items, 0.95),
        .p99_ms = percentileMs(samples.items, 0.99),
    };
}

/// Nearest-rank percentile over nanosecond samples, in ms. Nearest-rank
/// (rather than interpolating) is what a latency SLO means: "one query
/// in twenty was at least this slow".
fn percentileMs(sorted_ns: []const u64, q: f64) f64 {
    if (sorted_ns.len == 0) return 0;
    const rank_f = q * @as(f64, @floatFromInt(sorted_ns.len));
    const rank: usize = @max(1, @as(usize, @intFromFloat(@ceil(rank_f))));
    const idx = @min(rank, sorted_ns.len) - 1;
    return @as(f64, @floatFromInt(sorted_ns[idx])) / 1_000_000.0;
}

fn sourceFor(i: usize) MemorySource {
    return switch (i % 3) {
        0 => .matter,
        1 => .form,
        else => .spirit,
    };
}

// =============================================================================
// Output
// =============================================================================

fn emit(
    alloc: std.mem.Allocator,
    p: cli.Parsed,
    metrics: []const Metric,
    data_dir: ?[]const u8,
    total_ns: u64,
    store: *Store,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"suite\":\"mem3 bench (in-process smoke)\",\"scope\":\"smoke\",\"gate\":false,");
    try buf.appendSlice(alloc, "\"note\":\"Fast smoke suite. Release-blocking constitutional benchmarks run via `zig build bench`; these numbers are at smoke scale and gate nothing. Targets below assume an optimised build.\",");
    try buf.appendSlice(alloc, "\"optimize\":\"");
    try buf.appendSlice(alloc, @tagName(@import("builtin").mode));
    try buf.appendSlice(alloc, "\",");
    try buf.appendSlice(alloc, "\"workload\":{\"cells\":");
    try cli_common.appendFmt(&buf, alloc, "{d},\"queries\":{d},\"topk\":{d},\"hyperedges\":{d},\"index_vectors\":{d}", .{
        WORKLOAD_CELLS,
        WORKLOAD_QUERIES,
        WORKLOAD_TOPK,
        WORKLOAD_EDGES,
        WORKLOAD_INDEX_VECTORS,
    });
    try buf.appendSlice(alloc, "},\"corpus\":{\"cells\":");
    try cli_common.appendFmt(&buf, alloc, "{d},\"hyperedges\":{d},\"data_dir\":", .{ store.cellCount(), store.hyperedgeCount() });
    if (data_dir) |d| {
        try cli_common.appendJsonString(&buf, alloc, d);
    } else {
        try buf.appendSlice(alloc, "null");
    }
    try buf.appendSlice(alloc, "},\"metrics\":[");
    for (metrics, 0..) |m, mi| {
        if (mi > 0) try buf.append(alloc, ',');
        try m.writeJson(&buf, alloc);
    }
    try buf.appendSlice(alloc, "],\"duration_ms\":");
    try cli_common.appendFmt(&buf, alloc, "{d:.3}", .{@as(f64, @floatFromInt(total_ns)) / 1_000_000.0});
    try buf.appendSlice(alloc, "}");

    if (p.json) {
        cli_common.println(buf.items);
        return;
    }
    printHuman(alloc, metrics, data_dir, total_ns, store);
}

/// Human-readable default. Same numbers, no JSON — the rest of the CLI
/// is human-readable unless `--json` is passed.
fn printHuman(alloc: std.mem.Allocator, metrics: []const Metric, data_dir: ?[]const u8, total_ns: u64, store: *Store) void {
    cli_common.println("mem3 bench — in-process smoke suite (NOT the release gate)");
    cli_common.println("release-blocking constitutional benchmarks: `zig build bench`");
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        line.print(alloc, "build: {s} (targets below assume an optimised build)", .{@tagName(@import("builtin").mode)}) catch return;
        cli_common.println(line.items);
    }
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        line.appendSlice(alloc, "corpus: ") catch return;
        line.print(alloc, "{d} cells, {d} hyperedges, {s}", .{
            store.cellCount(),
            store.hyperedgeCount(),
            if (data_dir) |d| d else "in-memory",
        }) catch return;
        cli_common.println(line.items);
    }
    cli_common.println("");
    for (metrics) |m| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        const rendered = if (m.value) |v|
            std.fmt.allocPrint(alloc, "{d:.3}", .{v}) catch return
        else
            alloc.dupe(u8, "n/a") catch return;
        defer alloc.free(rendered);
        line.print(alloc, "  {s:<28} {s:>14} {s}", .{ m.key, rendered, m.unit }) catch return;
        cli_common.println(line.items);
    }
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        line.print(alloc, "\ndone in {d:.0} ms", .{@as(f64, @floatFromInt(total_ns)) / 1_000_000.0}) catch return;
        cli_common.println(line.items);
    }
}

// =============================================================================
// Platform helpers
// =============================================================================

fn nowNs() u64 {
    // Routed through the platform layer: `std.c.timespec` and
    // `std.c.clock_gettime` are both `void` on Windows in Zig 0.17, so
    // naming them here breaks cross-compilation for a measurement helper.
    return @bitCast(@as(u64, @truncate(@as(u128, @intCast(
        platform_clock.monotonicNs(),
    )))));
}

/// `RUSAGE_SELF` is 0 on both Linux and the BSDs/macOS. Spelled as a
/// literal because this std build exposes `std.c.rusage` but not a
/// `std.c.RUSAGE` enum.
const RUSAGE_SELF: c_int = 0;

/// Peak RSS of this process, or null where the platform cannot report it.
///
/// `getrusage` is POSIX. Windows has no equivalent in this form, so rather
/// than failing to compile there, the metric degrades to `null` and the
/// benchmark prints a reason. A missing number with an explanation is
/// usable; a build that does not cross-compile is not.
fn maxRssBytes() ?f64 {
    if (@import("builtin").os.tag == .windows) return null;
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(RUSAGE_SELF, &usage) != 0) return null;
    const raw: f64 = @floatFromInt(usage.maxrss);
    return switch (@import("builtin").os.tag) {
        .linux => raw * 1024.0,
        else => raw,
    };
}
