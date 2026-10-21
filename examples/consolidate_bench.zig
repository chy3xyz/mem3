//! mem3-consolidate-bench — per-pass cost of `Consolidator.consolidate`.
//!
//! Why this exists alongside `mem3-longrun`: the long run measures the
//! whole lifecycle, and reaching 45k cells with consolidation every 400
//! cells takes minutes of ingest (HNSW, WAL) that has nothing to do with
//! clustering. This drives `Consolidator` directly over the long run's own
//! corpus shape, so the clustering pass is the only thing timed.
//!
//! ## Written to run against two builds
//!
//! The same file is compiled against the baseline tree and the current
//! tree for A/B comparison, so it uses only API both have and probes the
//! rest with `@hasDecl` / `@hasField`: `pair_comparisons` and `cacheBytes`
//! exist only after the incremental change. For a build without the
//! counter, the pair count printed is the analytic `n(n-1)/2` that the
//! all-pairs loop performs by construction, and is labelled `pairs_kind=analytic`.
//!
//! ## What is measured
//!
//!   wall_ms     monotonic wall clock around `consolidate()` (noisy on a
//!               loaded host)
//!   cpu_ms      user+system CPU of this process around the same call,
//!               which load on *other* processes does not inflate
//!   pairs       Jaccard evaluations in the pass
//!   cons_live   bytes the Consolidator's own allocator holds when the pass
//!               returns — for the baseline that is 0 (it frees everything),
//!               for the incremental build it is the resident cache
//!   cons_peak   peak bytes that allocator held during the pass
//!   digest      order-independent hash of every abstract's text and
//!               importance, so two builds can be shown to have produced the
//!               same abstracts (ids are excluded: they are minted in a
//!               different cluster order by design)
//!
//! Usage:
//!
//!     ./mem3-consolidate-bench --mode=jump --cells=45000 --passes=3
//!     ./mem3-consolidate-bench --mode=grow --cells=20000
//!     ./mem3-consolidate-bench --mode=jump --cells=45000 --forget=50
//!
//! `jump` ingests `--cells` cells without consolidating, then runs
//! `--passes` passes, ingesting `--add` cells between them (pass 1 is the
//! cold pass; later ones are steady-state). `grow` starts empty and runs a
//! pass after every `--add` cells until the store reaches `--cells`, which
//! is the long run's trajectory.

const std = @import("std");
const builtin = @import("builtin");
const mem3 = @import("mem3");

/// Silence `std.log` (the manager logs every insert at debug level).
pub const std_options: std.Options = .{ .log_level = .err };

const TOPICS = [_][]const []const u8{
    &.{
        "wal replay reconstructs the cell store after an unclean shutdown",
        "wal append fsyncs every record before the write is acknowledged",
        "wal rotation keeps the log bounded under sustained writes",
        "wal checksum detects corruption in the replayed byte stream",
        "wal recovery semantics depend on append fsync ordering",
    },
    &.{
        "hnsw insert builds the layered graph incrementally per node",
        "hnsw search descends from the top layer to the candidate set",
        "hnsw beam search parameter tuning trades recall for latency",
        "hnsw neighbour lists grow with m and are bounded by mmax0",
        "hnsw cosine similarity assumes every vector is unit norm",
    },
    &.{
        "serializer comptime size keeps the wire format deterministic",
        "serialize writes every struct field in declared order",
        "deserialize reads fields back in the same declared order",
        "serializer round trip property must hold for every value",
        "deserialize rejects an unknown enum tag rather than guessing",
    },
    &.{
        "the matter source records a causally efficacious trace",
        "the form source extracts atomic facts from the episode",
        "the spirit source predicts with an explicit validity window",
        "three source coherence requires all three dimensions present",
        "tri source ontology forbids a cell missing its spirit dimension",
    },
    &.{
        "the forgetting sweep fuzzies low importance cells instead of deleting",
        "fuzzy storage preserves the original under a compressed marker",
        "existence gain drives which cells the sweep is willing to drop",
        "the promote path restores a fuzzied cell back to the active set",
        "forgetting threshold decides when a cell stops earning its keep",
    },
    &.{
        "consolidation clusters similar cells and emits one abstract",
        "hac clustering uses agglomerative passes over similarity",
        "the abstract inherits the union of its cluster's facts",
        "consolidation must never delete the originals it merged",
        "consolidation threshold decides which clusters actually merge",
    },
};

const TRIPLES = [_][3][]const u8{
    .{ "wal", "replayed", "n records" },
    .{ "hnsw", "returned", "k candidates" },
    .{ "serializer", "roundtripped", "memcell" },
    .{ "sweep", "fuzzied", "low value cell" },
    .{ "abstract", "merged", "cluster" },
    .{ "coherence", "measured", "three sources" },
};

/// Counts live and peak bytes of everything allocated through it.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn bump(self: *CountingAllocator, add: usize, sub: usize) void {
        self.live = self.live + add - sub;
        if (self.live > self.peak) self.peak = self.live;
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.inner.rawAlloc(len, a, ra) orelse return null;
        self.bump(len, 0);
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.inner.rawResize(m, a, new_len, ra)) return false;
        self.bump(new_len, m.len);
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.inner.rawRemap(m, a, new_len, ra) orelse return null;
        self.bump(new_len, m.len);
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(m, a, ra);
        self.bump(0, m.len);
    }
};

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = mem3.platform.stdio.writeOut(s);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = mem3.platform.stdio.writeErr(s);
}

fn cpuMs() f64 {
    var u: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &u) != 0) return 0;
    const us = @as(f64, @floatFromInt(u.utime.sec + u.stime.sec)) * 1e6 +
        @as(f64, @floatFromInt(u.utime.usec + u.stime.usec));
    return us / 1000.0;
}

fn peakRssKb() u64 {
    var u: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &u) != 0) return 0;
    const raw: u64 = @intCast(@max(u.maxrss, 0));
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => raw / 1024,
        else => raw,
    };
}

const Params = struct {
    mode: enum { jump, grow } = .jump,
    cells: usize = 5_000,
    add: usize = 400,
    passes: usize = 3,
    seed: u64 = 42,
    threshold: f32 = 0.75,
    /// Cells removed (as a forgetting sweep would) before every pass after
    /// the first. 0 = none, which is what the long run saw: it fuzzied nothing.
    forget: usize = 0,
};

fn parseArgs(init: std.process.Init.Minimal) !Params {
    var p = Params{};
    var it = std.process.Args.iterate(init.args);
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.startsWith(u8, a, "--mode=")) {
            const v = a["--mode=".len..];
            if (std.mem.eql(u8, v, "jump")) p.mode = .jump else if (std.mem.eql(u8, v, "grow")) p.mode = .grow else return error.BadMode;
        } else if (std.mem.startsWith(u8, a, "--cells=")) {
            p.cells = try std.fmt.parseInt(usize, a["--cells=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--add=")) {
            p.add = try std.fmt.parseInt(usize, a["--add=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--passes=")) {
            p.passes = try std.fmt.parseInt(usize, a["--passes=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--seed=")) {
            p.seed = try std.fmt.parseInt(u64, a["--seed=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--forget=")) {
            p.forget = try std.fmt.parseInt(usize, a["--forget=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--threshold=")) {
            p.threshold = try std.fmt.parseFloat(f32, a["--threshold=".len..]);
        } else {
            return error.UnknownArgument;
        }
    }
    return p;
}

/// Remove up to `k` random live cells, the way `Store.forget` does: take the
/// pointer out of the manager and free it. Ids are drawn from the PRNG, so
/// both builds under test remove the same cells.
fn forgetRandom(mgr: *mem3.TriSourceManager, alloc: std.mem.Allocator, rand: std.Random, k: usize) usize {
    var removed: usize = 0;
    const hi = mgr.next_id.load(.monotonic);
    for (0..k) |_| {
        const id = rand.intRangeLessThan(u64, 1, hi);
        const cell = mgr.remove(id) orelse continue;
        cell.deinit(alloc);
        alloc.destroy(cell);
        removed += 1;
    }
    return removed;
}

/// Ingest `n` cells shaped like the long run's: a topic line, a fact triple,
/// a random source and a random importance.
fn ingest(mgr: *mem3.TriSourceManager, rand: std.Random, n: usize) !void {
    for (0..n) |_| {
        const topic = TOPICS[rand.intRangeAtMost(usize, 0, TOPICS.len - 1)];
        const line = topic[rand.intRangeAtMost(usize, 0, topic.len - 1)];
        const t = TRIPLES[rand.intRangeAtMost(usize, 0, TRIPLES.len - 1)];
        const src: mem3.MemorySource = @enumFromInt(@as(u8, @intCast(rand.intRangeAtMost(u8, 0, 2))));
        const facts = [_]mem3.Fact{.{
            .subject = t[0],
            .predicate = t[1],
            .object = t[2],
            .confidence = 0.9,
            .source = "bench",
        }};
        _ = try mgr.add(.{
            .id = 0,
            .source = src,
            .episode = line,
            .atomic_facts = &facts,
            .foresight = &.{},
            .goal_associations = &.{.{ .goal_id = 1, .relevance = 0.5, .priority = 1 }},
            .metadata = .{
                .source_confidence = 0.9,
                .importance_score = 0.3 + rand.float(f32) * 0.7,
                .decay_rate = 0.01,
            },
        });
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const p = parseArgs(init) catch |e| {
        err("consolidate-bench: bad arguments ({s})\n", .{@errorName(e)});
        std.process.exit(2);
    };
    const base_alloc = std.heap.c_allocator;
    var counting = CountingAllocator{ .inner = base_alloc };

    var ids = std.atomic.Value(u64).init(1);
    var mgr = mem3.TriSourceManager.init(base_alloc, &ids);
    var fuzzy = mem3.FuzzyStore.init(base_alloc);
    var cons = mem3.consolidator_mod.Consolidator.init(counting.allocator(), .{ .consolidation_threshold = p.threshold }, &fuzzy, &mgr);
    const has_cache_bytes = comptime @hasDecl(mem3.consolidator_mod.Consolidator, "cacheBytes");
    const has_deinit = comptime @hasDecl(mem3.consolidator_mod.Consolidator, "deinit");

    var prng = std.Random.DefaultPrng.init(p.seed);
    const rand = prng.random();

    const has_pairs = comptime @hasField(mem3.consolidator_mod.Consolidator.ConsolidationResult, "pair_comparisons");
    const pairs_kind: []const u8 = if (has_pairs) "counted" else "analytic";
    out("# mode={s} cells={d} add={d} passes={d} seed={d} threshold={d} forget={d} pairs_kind={s}\n", .{
        @tagName(p.mode), p.cells, p.add, p.passes, p.seed, p.threshold, p.forget, pairs_kind,
    });

    if (p.mode == .jump) try ingest(&mgr, rand, p.cells);

    var digest: u64 = 0;
    var total_abstracts: usize = 0;
    var pass: usize = 0;
    while (true) {
        if (p.mode == .jump) {
            if (pass >= p.passes) break;
            if (pass > 0) try ingest(&mgr, rand, p.add);
        } else {
            if (mgr.count() >= p.cells) break;
            try ingest(&mgr, rand, p.add);
        }
        pass += 1;
        const forgotten: usize = if (pass > 1 and p.forget > 0) forgetRandom(&mgr, base_alloc, rand, p.forget) else 0;

        counting.peak = counting.live;
        const cpu0 = cpuMs();
        const t0 = mem3.platform.clock.monotonicNs();
        var res = try cons.consolidate();
        const t1 = mem3.platform.clock.monotonicNs();
        const cpu1 = cpuMs();
        defer res.deinitAbstractIds(base_alloc);

        const n: u64 = res.cells_processed;
        const pairs: u64 = if (has_pairs) res.pair_comparisons else n * (n -| 1) / 2;
        for (res.abstract_ids) |aid| {
            const c = mgr.get(aid) orelse continue;
            const h = std.hash.XxHash3.hash(0, c.episode);
            digest +%= h ^ @as(u64, @as(u32, @bitCast(c.metadata.importance_score)));
        }
        total_abstracts += res.abstracts_created;

        const rebuilt: usize = if (has_pairs) res.clusters_rebuilt else 0;
        out("pass={d} forgotten={d} rebuilt={d} cells={d} clusters={d} abstracts={d} pairs={d} wall_ms={d:.2} cpu_ms={d:.2} cons_live={d} cons_peak={d} peak_rss_kb={d}\n", .{
            pass,
            forgotten,
            rebuilt,
            n,
            res.clusters,
            res.abstracts_created,
            pairs,
            @as(f64, @floatFromInt(t1 - t0)) / 1e6,
            cpu1 - cpu0,
            counting.live,
            counting.peak,
            peakRssKb(),
        });
    }
    out("# digest={x} total_abstracts={d}\n", .{ digest, total_abstracts });
    if (has_cache_bytes) {
        out("# cache_bytes={d} cached_cells={d}\n", .{ cons.cacheBytes(), cons.cachedCells() });
    }
    // Teardown is not timed. Skipped for the manager: the process is about
    // to exit, and freeing 50k cells one by one would only slow the run.
    if (has_deinit) cons.deinit();
    _ = &fuzzy;
}
