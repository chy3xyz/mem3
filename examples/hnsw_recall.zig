//! Recall@10 of the HNSW index against an exhaustive scan, swept over the
//! candidate budget and over corpus size at the production embedding width.
//!
//! The corpus, the ground truth and the comparison all live in
//! `src/retrieval/hnsw.zig` next to the code they measure, so the numbers
//! printed here and the ones the unit tests assert cannot drift apart.
//!
//! Two reports, because they answer different questions:
//!
//!   1. The **ef sweep** at 400 nodes x dim 32. Small enough to print a
//!      graph shape next to the numbers, so the shape can be read as a
//!      cause of the number. This is the harness the README quotes.
//!   2. The **scale sweep** at dim 384 — what the embedder actually
//!      produces — at 1k, 10k and as far up as this machine tolerates.
//!      400 nodes cannot say anything about a 100k-cell index, and a 32-d
//!      corpus has different neighbour geometry from a 384-d one: with
//!      random unit vectors the pairwise cosine concentrates as
//!      N(0, 1/dim), so 32-d spreads distances ~3.5x wider than 384-d
//!      and both the "true" top-10 and the graph's navigability change.
//!
//! Run with `zig build example-hnsw-recall`. Flags (all optional):
//!
//!   --dim D          width for the scale sweep          (default 384)
//!   --scale A,B,C    corpus sizes for the scale sweep    (default 1000,10000,100000)
//!   --m M            hnsw_m                              (default: Config)
//!   --m-max0 MM      hnsw_m_max0                         (default: Config)
//!   --efc E          hnsw_ef_construction                (default: Config)
//!   --queries Q      queries per point in the scale sweep (default 100)
//!   --ef A,B,C       budgets in the scale sweep          (default 100,400,800)
//!   --scale-only     skip report 1
//!   --scale-off      skip report 2
//!   --build-only     build only: print build time, skip the recall scan
//!   --int8           store vectors as int8 (hnsw_vector_storage = .int8)
//!   --adaptive D     budget = max(ef, live_count / D) (hnsw_ef_search_divisor).
//!                    Default 0 = off here, so an --ef sweep is a fixed budget
//!                    (the library default is 64)
//!   --latency        also time the searches (mean / worst batch of 10, ms/query)

const std = @import("std");
const mem3 = @import("mem3");

const hnsw_mod = mem3.retrieval.hnsw;

const EFS = [_]u16{ 10, 32, 50, 100, 200, 400 };

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = mem3.platform.stdio.writeOut(s);
}

const Options = struct {
    dim: u16 = 384,
    scale_ns: []const u8 = "1000,10000,100000",
    m: ?u16 = null,
    m_max0: ?u16 = null,
    efc: ?u16 = null,
    queries: usize = 100,
    scale_efs: []const u8 = "100,400,800",
    scale_only: bool = false,
    scale_off: bool = false,
    build_only: bool = false,
    int8: bool = false,
    adaptive: u16 = 0,
    latency: bool = false,
};

fn parseU16(s: []const u8) u16 {
    return std.fmt.parseInt(u16, s, 10) catch 0;
}

fn parseUsize(s: []const u8) usize {
    return std.fmt.parseInt(usize, s, 10) catch 0;
}

fn applyOverrides(cfg: *mem3.Config, o: Options) void {
    if (o.m) |v| cfg.hnsw_m = v;
    if (o.m_max0) |v| cfg.hnsw_m_max0 = v;
    if (o.efc) |v| cfg.hnsw_ef_construction = v;
    if (o.int8) cfg.hnsw_vector_storage = .int8;
    cfg.hnsw_ef_search_divisor = o.adaptive;
}

/// One corpus at one width: build, sweep `efs`, report recall, the layer-0
/// reachable fraction (the hard ceiling on recall), build time and mean
/// insert cost.
fn report(
    alloc: std.mem.Allocator,
    base_cfg: mem3.Config,
    spec: hnsw_mod.OracleSpec,
    efs: []const u16,
    label: []const u8,
    measure_time: bool,
    build_only: bool,
    latency: bool,
) !void {
    var cfg = base_cfg;
    var it = efs;
    if (it.len == 0) it = &EFS;

    out("\n{s}  n={d}  dim={d}  queries={d}  k={d}  m={d} m_max0={d} efc={d}\n", .{
        label,
        spec.n,
        spec.dim,
        spec.queries,
        spec.k,
        cfg.hnsw_m,
        cfg.hnsw_m_max0,
        cfg.hnsw_ef_construction,
    });

    // One build, scored at every budget. The graph is deterministic in the
    // seed and the insertion order, so one build is the same graph every
    // budget would have built — and it is the only way to get the reachable
    // fraction and the build cost alongside the recall numbers.
    const t0 = mem3.platform.clock.monotonicNs();
    var hnsw = hnsw_mod.HNSW.init(alloc, cfg, spec.dim);
    defer hnsw.deinit();
    const corpus = try hnsw_mod.oracleCorpusN(alloc, spec.n, spec.dim);
    defer alloc.free(corpus);
    try hnsw_mod.oracleFillN(&hnsw, corpus, spec.n, spec.dim);
    const t1 = mem3.platform.clock.monotonicNs();
    const build_ns: i128 = t1 - t0;

    const reach = try hnsw.level0Reachable(alloc);
    out("  build {d:.1}s  level0 reachable {d}/{d} ({d:.4})  ceiling {d:.4}\n", .{
        @as(f64, @floatFromInt(build_ns)) / 1e9,
        reach,
        spec.n,
        @as(f64, @floatFromInt(reach)) / @as(f64, @floatFromInt(spec.n)),
        @as(f64, @floatFromInt(reach)) / @as(f64, @floatFromInt(spec.n)),
    });

    out("  ef    recall\n", .{});
    out("  ---  ------\n", .{});
    for (it) |ef| {
        if (build_only) break;
        cfg.hnsw_ef_search = ef;
        hnsw.cfg.hnsw_ef_search = ef;
        const r = try hnsw_mod.recallAgainst(&hnsw, alloc, corpus, spec);
        out("  {d:>3}   {d:.4}\n", .{ ef, r });
        if (latency) try timeSearches(&hnsw, alloc, corpus, spec);
    }
    if (measure_time and build_ns != 0) {
        out("  mean insert {d:.1} us/op over {d} nodes\n", .{
            @as(f64, @floatFromInt(build_ns)) / @as(f64, @floatFromInt(spec.n)) / 1000.0,
            spec.n,
        });
    }
}

/// Search latency at the current budget: 10 batches of 10 queries, each
/// batch timed as a whole (sub-region timings fold to 0 under ReleaseFast,
/// see `timeBuild`). Prints the mean and the slowest batch, ms/query. A
/// per-query p95 is not measured; the slowest batch bounds it from above
/// only loosely, so it is reported as what it is.
fn timeSearches(hnsw: *hnsw_mod.HNSW, alloc: std.mem.Allocator, corpus: []const f32, spec: hnsw_mod.OracleSpec) !void {
    const dim: usize = spec.dim;
    const qv = try alloc.alloc(f32, dim);
    defer alloc.free(qv);
    const noise = try alloc.alloc(f32, dim);
    defer alloc.free(noise);
    var total: i128 = 0;
    var worst: i128 = 0;
    var sink: u64 = 0;
    var b: usize = 0;
    while (b < 10) : (b += 1) {
        var batch_ns: i128 = 0;
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            hnsw_mod.oracleQueryN(qv, noise, corpus, b * 10 + i, spec.n, dim);
            const t0 = mem3.platform.clock.monotonicNs();
            const got = try hnsw.search(alloc, qv, spec.k);
            sink +%= if (got.len > 0) got[0].id else 0;
            alloc.free(got);
            batch_ns += mem3.platform.clock.monotonicNs() - t0;
        }
        total += batch_ns;
        if (batch_ns > worst) worst = batch_ns;
    }
    out("        latency mean {d:.2} ms/query  slowest batch {d:.2} ms/query  (sink {d})\n", .{
        @as(f64, @floatFromInt(total)) / 100.0 / 1e6,
        @as(f64, @floatFromInt(worst)) / 10.0 / 1e6,
        sink,
    });
}

/// Average per-insert nanoseconds, timed over a whole build whose result is
/// printed. A whole-run measurement cannot be elided by the optimiser, which
/// is the only reason it is trusted here at all: `src/platform/clock.zig`
/// folds to 0 under `-O ReleaseFast` for sub-region timings.
fn timeBuild(
    alloc: std.mem.Allocator,
    cfg: mem3.Config,
    spec: hnsw_mod.OracleSpec,
) !u64 {
    const t0 = mem3.platform.clock.monotonicNs();
    var hnsw = hnsw_mod.HNSW.init(alloc, cfg, spec.dim);
    defer hnsw.deinit();
    const corpus = try hnsw_mod.oracleCorpusN(alloc, spec.n, spec.dim);
    defer alloc.free(corpus);
    try hnsw_mod.oracleFillN(&hnsw, corpus, spec.n, spec.dim);
    const t1 = mem3.platform.clock.monotonicNs();
    out("    (build {d} nodes -> {d})\n", .{ hnsw.count, hnsw.maxOccupiedLevel() });
    return t1 - t0;
}

fn report1(alloc: std.mem.Allocator, cfg: mem3.Config, o: Options) !void {
    out("HNSW recall@{d} vs exhaustive scan\n", .{hnsw_mod.oracle_k});
    out("corpus={d} nodes  dim={d}  queries={d}  seed={x}\n", .{
        hnsw_mod.oracle_n,
        hnsw_mod.oracle_dim,
        hnsw_mod.oracle_queries,
        cfg.hnsw_seed,
    });

    const spec = hnsw_mod.OracleSpec{
        .n = hnsw_mod.oracle_n,
        .dim = hnsw_mod.oracle_dim,
        .queries = hnsw_mod.oracle_queries,
        .k = hnsw_mod.oracle_k,
    };
    try report(alloc, cfg, spec, &EFS, "ef sweep", true, o.build_only, o.latency);

    out("\nGraph shape:\n", .{});
    var g = cfg;
    g.hnsw_ef_search = 100;
    var idx = hnsw_mod.HNSW.init(alloc, g, hnsw_mod.oracle_dim);
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

fn report2(alloc: std.mem.Allocator, cfg: mem3.Config, o: Options) !void {
    out("\n=== scale sweep at dim={d} (production embedder width) ===\n", .{o.dim});

    var it = std.mem.splitScalar(u8, o.scale_ns, ',');
    while (it.next()) |ns| {
        const n = parseUsize(ns);
        if (n == 0) continue;
        const spec = hnsw_mod.OracleSpec{
            .n = n,
            .dim = o.dim,
            .queries = o.queries,
            .k = hnsw_mod.oracle_k,
        };

        var efs = std.ArrayList(u16).empty;
        defer efs.deinit(alloc);
        var eit = std.mem.splitScalar(u8, o.scale_efs, ',');
        while (eit.next()) |es| {
            const e = parseU16(es);
            if (e != 0) try efs.append(alloc, e);
        }

        try report(alloc, cfg, spec, efs.items, "scale", true, o.build_only, o.latency);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    // smp_allocator, not DebugAllocator: the scale sweep has to build a
    // 100k x 384-dim index, and DebugAllocator's per-allocation bookkeeping
    // dominates it. This harness prints its results, so nothing it measures
    // can be optimised away; leak detection would cost more than the
    // measurement is worth.
    const alloc = std.heap.smp_allocator;

    var o = Options{};
    var args = std.process.Args.iterate(init.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--dim")) {
            o.dim = parseU16(args.next() orelse "384");
        } else if (std.mem.eql(u8, a, "--scale")) {
            o.scale_ns = args.next() orelse o.scale_ns;
        } else if (std.mem.eql(u8, a, "--m")) {
            o.m = parseU16(args.next() orelse "0");
        } else if (std.mem.eql(u8, a, "--m-max0")) {
            o.m_max0 = parseU16(args.next() orelse "0");
        } else if (std.mem.eql(u8, a, "--efc")) {
            o.efc = parseU16(args.next() orelse "0");
        } else if (std.mem.eql(u8, a, "--queries")) {
            o.queries = parseUsize(args.next() orelse "100");
        } else if (std.mem.eql(u8, a, "--ef")) {
            o.scale_efs = args.next() orelse o.scale_efs;
        } else if (std.mem.eql(u8, a, "--scale-only")) {
            o.scale_only = true;
        } else if (std.mem.eql(u8, a, "--scale-off")) {
            o.scale_off = true;
        } else if (std.mem.eql(u8, a, "--adaptive")) {
            o.adaptive = parseU16(args.next() orelse "0");
        } else if (std.mem.eql(u8, a, "--latency")) {
            o.latency = true;
        } else if (std.mem.eql(u8, a, "--int8")) {
            o.int8 = true;
        } else if (std.mem.eql(u8, a, "--build-only")) {
            o.build_only = true;
        }
    }

    var cfg = mem3.Config{};
    applyOverrides(&cfg, o);

    if (!o.scale_only) try report1(alloc, cfg, o);
    if (!o.scale_off) try report2(alloc, cfg, o);
}
