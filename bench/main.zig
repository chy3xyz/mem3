//! mem3-bench — real performance measurements.
//!
//! Run via `zig build bench`. To pass parameters run the binary directly:
//!   zig build bench
//!   ./zig-out/bin/mem3-bench --cells=20000 --queries=2000 --seed=7
//! (`zig build` in 0.17 no longer forwards `--` args to a run step.)
//!
//! ## Two suites, one binary
//!
//! With **no arguments** this runs the original micro-benchmark suite
//! below — the nanosecond-level primitives (`hashing`, `serializer`,
//! `encoder`, `hnsw`, `wal`, `store`) — and writes `bench-results.json`.
//! That suite is unchanged; it is the fast one and it is what
//! `zig build bench` runs.
//!
//! With **a benchmark name** it runs one of the seven constitutional
//! benchmarks named in `.specify/memory/constitution.md`, each of which
//! emits exactly one JSON object on stdout:
//!
//!   ./zig-out/bin/mem3-bench throughput      >= 1.75K MemCells/sec sustained (worst window)
//!   ./zig-out/bin/mem3-bench retrieval-p95   recall TopK=10 P95 < 10ms @100K
//!   ./zig-out/bin/mem3-bench hnsw-build      100K vectors indexed in < 30s
//!   ./zig-out/bin/mem3-bench multihop        3-hop traversal < 5ms for 1K seeds
//!   ./zig-out/bin/mem3-bench cold-start      launch -> ready < 200ms
//!   ./zig-out/bin/mem3-bench footprint       100K MemCells < 500MB RSS
//!   ./zig-out/bin/mem3-bench longmemeval     end-to-end >= 80% accuracy
//!
//!   --list          print the benchmark names and their targets
//!   <name> --help   flags and default scale for that one benchmark
//!
//! Shared flags every constitutional benchmark accepts:
//!   --scale=F       multiply the benchmark's default scale (`--quick`
//!                   is `--scale=0.1`)
//!   --seed=N        PRNG seed; the same seed reproduces the run
//!   --data-dir=P    scratch directory (default: a fresh dir under /tmp,
//!                   never inside the checkout)
//!
//! Scratch data goes to /tmp by design: a benchmark that writes
//! `data/` into the repository pollutes `git status` and makes two
//! concurrent runs fight over one WAL.
//!
//! ## Honesty rules this file follows
//!
//! 1. **No hardcoded numbers.** Every figure printed here was measured in
//!    this process, microseconds ago. If a benchmark cannot run it is
//!    reported as an error, never as a plausible-looking constant.
//! 2. **Distributions, not averages.** Each benchmark reports
//!    min / median / p95 over many repetitions, because a single mean over
//!    an unrepresentative run is how "7.2M cells/sec" style marketing
//!    numbers get invented.
//! 3. **Warmup is discarded** and every benchmark states its own
//!    `ops_per_rep` and `reps` so the sampling is auditable.
//! 4. **Results cannot be optimised away** — every benchmark folds its
//!    output into `sink`, which is printed as a checksum.
//! 5. **The JSON records its own provenance**: params, seed and a
//!    timestamp, so a number can be traced back to the run that produced it.
//! 6. **No projection is ever printed as a measurement.** The
//!    constitutional benchmarks put every extrapolation in a separate
//!    `projection` object carrying the fit it assumed, and print `null`
//!    plus a reason where a number could not be produced at all.
//!
//! Scope limits worth stating plainly: the HNSW corpus is `--cells`
//! (default 2 000) and `hnsw.search` is the shipped beam search
//! implementation. These numbers say nothing about a 10M-vector corpus and
//! must not be quoted as if they did.

const std = @import("std");
const mem3 = @import("mem3");

const harness = @import("harness.zig");
const throughput_bench = @import("throughput.zig");
const retrieval_p95_bench = @import("retrieval_p95.zig");
const hnsw_build_bench = @import("hnsw_build.zig");
const multihop_bench = @import("multihop.zig");
const cold_start_bench = @import("cold_start.zig");
const footprint_bench = @import("footprint.zig");
const longmemeval_bench = @import("longmemeval.zig");
const longmemeval_official_bench = @import("longmemeval_official.zig");
const lme_compare_bench = @import("lme_compare.zig");

/// Library logging stays quiet so it cannot interleave with bench output.
pub const std_options: std.Options = .{
    .log_level = .err,
};

const Allocator = std.mem.Allocator;

/// Monotonic clock. `std.time.nanoTimestamp` does not exist in Zig 0.17;
/// mem3's own clock_gettime wrapper does.
const clockNs = mem3.utils.time.monotonicNs;

/// Dead-code-elimination guard. Every benchmark folds its result in here and
/// the final value is printed, so no measured call can be optimised away.
var sink: u64 = 0;

const DEFAULT_JSON_PATH = "bench-results.json";
const RULE = "------------------------------------------------------------------------------";

// ============================================================================
// Harness
// ============================================================================

/// One benchmark's raw measurements: `reps` samples, each the per-operation
/// cost in nanoseconds averaged over `ops_per_rep` operations.
const Stats = struct {
    name: []const u8,
    unit: []const u8,
    ops_per_rep: usize,
    reps: usize,
    samples: []u64,
    /// What the number means, and what it does not.
    note: []const u8,

    fn minNs(self: Stats) f64 {
        return @floatFromInt(self.samples[0]);
    }

    fn medianNs(self: Stats) f64 {
        return @floatFromInt(self.samples[self.samples.len / 2]);
    }

    fn p95Ns(self: Stats) f64 {
        return @floatFromInt(self.samples[(self.samples.len - 1) * 95 / 100]);
    }

    fn meanNs(self: Stats) f64 {
        var total: u128 = 0;
        for (self.samples) |s| total += s;
        return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.samples.len));
    }

    /// Operations per second implied by the median — the number that reads
    /// like a rate. min/p95 stay alongside it for spread.
    fn perSec(self: Stats) f64 {
        const m = self.medianNs();
        if (m <= 0) return 0;
        return 1e9 / m;
    }
};

/// Time `reps` batches of up to `ops_per_rep` calls to `body`.
///
/// `body` receives an opaque context and a repetition index, and must
/// perform at most `ops_per_rep` units of work, adding one to
/// `ops_counter` per unit actually performed. The harness normalises by
/// the work actually done rather than by the work budget, so a benchmark
/// that runs out of inputs reports the truth instead of a fake zero.
fn runBench(
    alloc: Allocator,
    name: []const u8,
    unit: []const u8,
    note: []const u8,
    warmup: usize,
    ops_per_rep: usize,
    reps: usize,
    ctx: *anyopaque,
    ops_counter: *usize,
    body: *const fn (*anyopaque, usize) void,
) !Stats {
    var i: usize = 0;
    while (i < warmup) : (i += 1) {
        ops_counter.* = 0;
        body(ctx, i);
    }

    const samples = try alloc.alloc(u64, reps);
    var r: usize = 0;
    while (r < reps) : (r += 1) {
        ops_counter.* = 0;
        const t0 = clockNs();
        body(ctx, r);
        const t1 = clockNs();
        const elapsed: u64 = @intCast(t1 - t0);
        const ops = @max(ops_counter.*, 1);
        // One sample == ns per operation, not ns per batch. Batches are
        // sized so the elapsed time is far above clock granularity.
        samples[r] = elapsed / ops;
    }
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    return .{
        .name = name,
        .unit = unit,
        .note = note,
        .ops_per_rep = ops_per_rep,
        .reps = reps,
        .samples = samples,
    };
}

// ============================================================================
// Deterministic input generation
// ============================================================================

/// xorshift64. Benchmarks must be reproducible from a seed, otherwise a
/// result cannot be re-checked.
const Rng = struct {
    state: u64,

    fn init(seed: u64) Rng {
        return .{ .state = (seed ^ 0x9E3779B97F4A7C15) | 1 };
    }

    fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        return x;
    }

    /// Uniform in [-1, 1).
    fn unit(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() % 20_001)) / 10_000.0 - 1.0;
    }
};

const EPISODES = [_][]const u8{
    "user asked to refactor the persistence layer and keep the WAL contract",
    "agent observed a replay failure after an unclean shutdown mid-append",
    "tool output showed a snapshot written with a stale cell counter",
    "reflection: the forgetting sweep removed a high-importance cell",
    "goal ghw was blocked because the harness had no world model binding",
    "episode recorded a duplicate triad across matter and form sources",
    "conversation about consolidating two similar cells into one abstract",
    "system reported coherence below the constitutional threshold",
};

const FACT_TRIPLES = [_][3][]const u8{
    .{ "user", "prefers", "zig" },
    .{ "agent", "skipped", "forget" },
    .{ "wal", "replayed", "3 records" },
    .{ "snapshot", "superseded", "counter" },
    .{ "goal", "blocked", "binding" },
    .{ "cell", "decayed", "matter" },
};

// ============================================================================
// Foundation primitives
// ============================================================================

const HashCtx = struct {
    buf: [64]u8 = undefined,
    acc: u64 = 0,
    ops: usize = 0,
};

fn hashBody(c: *anyopaque, _: usize) void {
    const s: *HashCtx = @ptrCast(@alignCast(c));
    var n: usize = 0;
    while (n < 10000) : (n += 1) {
        s.ops += 1;
        // Mutate the input every iteration. Hashing a constant buffer is
        // foldable and the optimiser will hoist the whole batch into a
        // single call, reporting a confident 0 ns/op.
        s.buf[s.ops & 63] = @truncate(s.ops);
        s.acc +%= mem3.utils.hashing.xxh3_64bits(&s.buf);
    }
    sink +%= s.acc;
}

fn benchHashing(alloc: Allocator, reps: usize) !Stats {
    var rng = Rng.init(0xA5A5);
    var ctx = HashCtx{};
    for (&ctx.buf) |*b| b.* = @truncate(rng.next());

    return runBench(
        alloc,
        "hashing.xxh3_64bits",
        "ns/op",
        "xxHash3 over 64 bytes (one cache line)",
        1,
        10000,
        reps,
        @ptrCast(&ctx),
        &ctx.ops,
        hashBody,
    );
}

const CombineCtx = struct {
    a: u64 = 0x1234_5678_9ABC_DEF0,
    b: u64 = 0x0FED_CBA9_8765_4321,
    acc: u64 = 0,
    ops: usize = 0,
};

fn combineBody(c: *anyopaque, _: usize) void {
    const s: *CombineCtx = @ptrCast(@alignCast(c));
    var n: usize = 0;
    while (n < 20000) : (n += 1) {
        s.ops += 1;
        s.acc +%= mem3.utils.hashing.combine(s.a +% s.ops, s.b ^ s.ops);
    }
    sink +%= s.acc;
}

fn benchHashCombine(alloc: Allocator, reps: usize) !Stats {
    var ctx = CombineCtx{};
    return runBench(
        alloc,
        "hashing.combine",
        "ns/op",
        "two u64 -> one u64 avalanche mix; one-shot, not the streaming state machine",
        1,
        20000,
        reps,
        @ptrCast(&ctx),
        &ctx.ops,
        combineBody,
    );
}

const IsoCtx = struct {
    buf: [20]u8 align(1) = undefined,
    acc: usize = 0,
    ops: usize = 0,
};

fn isoBody(c: *anyopaque, rep: usize) void {
    const s: *IsoCtx = @ptrCast(@alignCast(c));
    var n: usize = 0;
    while (n < 2000) : (n += 1) {
        s.ops += 1;
        // Vary the timestamp per operation so the formatter cannot be
        // hoisted out of the loop.
        const ts: i64 = 1_700_000_000_000 +
            @as(i64, @intCast(rep)) * 86_400_000 +
            @as(i64, @intCast(s.ops));
        const out = mem3.utils.time.formatIso8601(ts, &s.buf);
        s.acc +%= out.len;
    }
    sink +%= s.acc;
}

fn benchFormatIso8601(alloc: Allocator, reps: usize) !Stats {
    var ctx = IsoCtx{};
    return runBench(
        alloc,
        "time.formatIso8601",
        "ns/op",
        "civil-date conversion + formatting, no allocation",
        1,
        2000,
        reps,
        @ptrCast(&ctx),
        &ctx.ops,
        isoBody,
    );
}

// ============================================================================
// Serialisation
// ============================================================================

/// A representative cell: all three tri-source dimensions populated, two
/// facts, one foresight, one goal association. Serialising a trivial cell
/// would flatter the serializer.
fn sampleCell() mem3.MemCell {
    return .{
        .id = 42,
        .source = .spirit,
        .episode = EPISODES[0],
        .atomic_facts = &.{
            .{ .subject = FACT_TRIPLES[0][0], .predicate = FACT_TRIPLES[0][1], .object = FACT_TRIPLES[0][2], .confidence = 0.9, .source = "user_input" },
            .{ .subject = FACT_TRIPLES[1][0], .predicate = FACT_TRIPLES[1][1], .object = FACT_TRIPLES[1][2], .confidence = 0.8, .source = "reflection" },
        },
        .foresight = &.{
            .{ .description = "the WAL will need a rotation policy", .valid_from = 1_700_000_000_000, .valid_until = std.math.maxInt(i64), .confidence = 0.7 },
        },
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.85, .priority = 200 },
        },
        .metadata = .{
            .created_at = 1_700_000_000_000,
            .updated_at = 1_700_000_000_000,
            .source_confidence = 0.95,
            .emotional_valence = 0.1,
            .importance_score = 0.62,
            .decay_rate = 0.05,
            .location = "bench",
        },
    };
}

const SerCtx = struct {
    alloc: Allocator,
    cell: mem3.MemCell,
    ok: u64 = 0,
    ops: usize = 0,
};

fn serBody(c: *anyopaque, _: usize) void {
    const s: *SerCtx = @ptrCast(@alignCast(c));
    var n: usize = 0;
    while (n < 50) : (n += 1) serOnce(s);
    sink +%= s.ops;
}

fn serOnce(s: *SerCtx) void {
    s.ops += 1;
    const bytes = mem3.utils.serialize(s.alloc, s.cell) catch {
        sink +%= 1;
        return;
    };
    defer s.alloc.free(bytes);
    const back = mem3.utils.deserialize(s.alloc, mem3.MemCell, bytes) catch {
        sink +%= 1;
        return;
    };
    defer back.deinit(s.alloc);
    s.ok +%= back.id;
    sink +%= back.id + back.atomic_facts.len;
}

fn benchSerializerRoundtrip(alloc: Allocator, reps: usize) !Stats {
    var ctx = SerCtx{ .alloc = alloc, .cell = sampleCell() };
    return runBench(
        alloc,
        "serializer.roundtrip",
        "ns/op",
        "MemCell serialize + deserialize, includes both allocations",
        1,
        50,
        reps,
        @ptrCast(&ctx),
        &ctx.ops,
        serBody,
    );
}

const EncCtx = struct {
    encoder: *mem3.Encoder,
    alloc: Allocator,
    acc: u64 = 0,
    ops: usize = 0,
};

fn encBody(c: *anyopaque, rep: usize) void {
    const s: *EncCtx = @ptrCast(@alignCast(c));
    var n: usize = 0;
    while (n < 200) : (n += 1) encOnce(s, rep * 200 + n);
    sink +%= s.ops;
}

fn encOnce(s: *EncCtx, idx_raw: usize) void {
    s.ops += 1;
    const idx = idx_raw % EPISODES.len;
    const out = s.encoder.encode(.{
        .source = @enumFromInt(@as(u8, @intCast(idx % 3))),
        .episode = EPISODES[idx],
        .goal_associations = &.{.{ .goal_id = 1, .relevance = 0.7, .priority = 128 }},
    }) catch {
        sink +%= 1;
        return;
    };
    // NOTE: `Encoder.encode` is zero-copy — it aliases the caller's slices
    // (see the "caller owns" comment in encoder.zig). Do NOT call
    // `out.deinit()` here: that would free memory this allocator never
    // handed out. Nothing to release on this path.
    s.acc +%= @as(u64, @intFromFloat(out.metadata.importance_score * 1000));
    sink +%= s.acc + out.atomic_facts.len;
}

fn benchEncoder(alloc: Allocator, reps: usize) !Stats {
    var encoder = mem3.Encoder.init(alloc, mem3.Config{});
    var ctx = EncCtx{ .encoder = &encoder, .alloc = alloc };
    return runBench(
        alloc,
        "encoder.encode",
        "ns/op",
        "RawInput -> MemCell; dominated by the clock_gettime inside the encoder",
        1,
        200,
        reps,
        @ptrCast(&ctx),
        &ctx.ops,
        encBody,
    );
}

// ============================================================================
// Retrieval
// ============================================================================

const HNSW_DIM: u16 = 384;

const Corpus = struct {
    vectors: [][]f32,
    ids: []u64,
};

fn fillCorpus(alloc: Allocator, count: usize, dim: u16, seed: u64) !Corpus {
    var rng = Rng.init(seed);
    const vectors = try alloc.alloc([]f32, count);
    const ids = try alloc.alloc(u64, count);
    for (vectors, 0..) |*v, i| {
        const vec = try alloc.alloc(f32, dim);
        for (vec) |*x| x.* = rng.unit();
        // L2-normalise so cosine search is well-conditioned.
        var norm: f32 = 0;
        for (vec) |x| norm += x * x;
        norm = @sqrt(norm);
        if (norm > 0) {
            for (vec) |*x| x.* /= norm;
        }
        v.* = vec;
        ids[i] = i + 1;
    }
    return .{ .vectors = vectors, .ids = ids };
}

fn freeCorpus(alloc: Allocator, c: Corpus) void {
    for (c.vectors) |v| alloc.free(v);
    alloc.free(c.vectors);
    alloc.free(c.ids);
}

const HnswInsertCtx = struct {
    hnsw: mem3.HNSW,
    corpus: Corpus,
    next: usize = 0,
    ops: usize = 0,
};

fn hnswInsertBody(c: *anyopaque, _: usize) void {
    const s: *HnswInsertCtx = @ptrCast(@alignCast(c));
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        if (s.next >= s.corpus.vectors.len) break;
        s.hnsw.insert(s.corpus.ids[s.next], s.corpus.vectors[s.next]) catch {
            sink +%= 1;
            continue;
        };
        s.next += 1;
        s.ops += 1;
    }
    sink +%= s.hnsw.count;
}

fn benchHnswInsert(alloc: Allocator, reps: usize, budget: usize, seed: u64) !Stats {
    const corpus = try fillCorpus(alloc, budget, HNSW_DIM, seed);
    defer freeCorpus(alloc, corpus);

    var ctx = HnswInsertCtx{
        .hnsw = mem3.HNSW.init(alloc, mem3.Config{}, HNSW_DIM),
        .corpus = corpus,
    };
    defer ctx.hnsw.deinit();

    return runBench(
        alloc,
        "hnsw.insert",
        "ns/op",
        "amortised incremental graph-build cost, 384-dim",
        1,
        64,
        reps,
        @ptrCast(&ctx),
        &ctx.ops,
        hnswInsertBody,
    );
}

const HnswSearchCtx = struct {
    alloc: Allocator,
    hnsw: *mem3.HNSW,
    queries: Corpus,
    k: usize,
    next: usize = 0,
    acc: u64 = 0,
    ops: usize = 0,
    // Repeat-vs-repeat accumulator. NOTE: the "ground truth" below is the
    // SAME function under test, so this measures run-to-run stability, not
    // recall. True recall needs an exhaustive scan; see hnsw.zig.
    truth_hits: u64 = 0,
    truth_total: u64 = 0,
};

fn hnswSearchBody(c: *anyopaque, _: usize) void {
    const s: *HnswSearchCtx = @ptrCast(@alignCast(c));
    var n: usize = 0;
    while (n < 20) : (n += 1) {
        if (s.next >= s.queries.vectors.len) break;
        const q = s.queries.vectors[s.next];
        s.next += 1;
        s.ops += 1;

        const got = s.hnsw.search(s.alloc, q, s.k) catch {
            sink +%= 1;
            continue;
        };
        defer s.alloc.free(got);
        for (got) |r| s.acc +%= r.id;

        // Deliberately the same code path. Do NOT read the resulting
        // ratio as correctness: it is 1.0 by construction. It only shows
        // the result set is stable across identical calls.
        const truth = s.hnsw.search(s.alloc, q, s.k) catch continue;
        defer s.alloc.free(truth);
        for (got) |g| {
            for (truth) |t| {
                if (g.id == t.id) {
                    s.truth_hits += 1;
                    break;
                }
            }
        }
        s.truth_total += got.len;
    }
    sink +%= s.acc;
}

const SearchResult = struct { stats: Stats, stability: f64 };

fn benchHnswSearch(alloc: Allocator, reps: usize, corpus_size: usize, query_count: usize, seed: u64) !SearchResult {
    const corpus = try fillCorpus(alloc, corpus_size, HNSW_DIM, seed);
    defer freeCorpus(alloc, corpus);

    var hnsw = mem3.HNSW.init(alloc, mem3.Config{}, HNSW_DIM);
    defer hnsw.deinit();
    for (corpus.vectors, 0..) |v, i| {
        try hnsw.insert(corpus.ids[i], v);
    }

    // Query vectors come from the same deterministic stream but are not in
    // the index, so we measure search over unseen directions.
    const queries = try fillCorpus(alloc, query_count, HNSW_DIM, seed ^ 0xFFFF);
    defer freeCorpus(alloc, queries);

    var ctx = HnswSearchCtx{
        .alloc = alloc,
        .hnsw = &hnsw,
        .queries = queries,
        .k = 10,
    };

    const stats = try runBench(
        alloc,
        "hnsw.search",
        "ns/op",
        "top-10 cosine search over the shipped HNSW beam search (greedy descent + ef-bounded expansion)",
        1,
        20,
        reps,
        @ptrCast(&ctx),
        &ctx.ops,
        hnswSearchBody,
    );

    const stability: f64 = if (ctx.truth_total == 0)
        0
    else
        @as(f64, @floatFromInt(ctx.truth_hits)) / @as(f64, @floatFromInt(ctx.truth_total));

    return .{ .stats = stats, .stability = stability };
}

// ============================================================================
// Persistence
// ============================================================================

const WAL_BENCH_PATH = "/tmp/mem3_bench.wal";

const WalCtx = struct {
    wal: mem3.WAL,
    acc: u64 = 0,
    counter: u64 = 0,
    ops: usize = 0,
};

fn walBody(c: *anyopaque, _: usize) void {
    const s: *WalCtx = @ptrCast(@alignCast(c));
    var n: usize = 0;
    while (n < 32) : (n += 1) {
        s.counter +%= 1;
        s.wal.append(.{
            .record_type = .memcell_insert,
            .payload = EPISODES[n % EPISODES.len],
            .timestamp = @as(i64, @intCast(s.counter)),
        }) catch {
            sink +%= 1;
            continue;
        };
        s.acc +%= 1;
    }
    s.wal.flush() catch {
        sink +%= 1;
    };
    sink +%= s.acc;
}

fn benchWalAppendFsync(alloc: Allocator, reps: usize) !Stats {
    var zbuf: [64]u8 = undefined;
    const zpath = std.fmt.bufPrint(&zbuf, WAL_BENCH_PATH ++ "\x00", .{}) catch unreachable;
    _ = std.c.unlink(zpath[0..zpath.len :0].ptr);

    var ctx = WalCtx{ .wal = mem3.WAL.init(alloc, WAL_BENCH_PATH) catch unreachable };
    ctx.wal.open() catch unreachable;
    defer {
        ctx.wal.deinit();
        _ = std.c.unlink(zpath[0..zpath.len :0].ptr);
    }

    return runBench(
        alloc,
        "wal.append_durable",
        "ns/record",
        "WAL.append writes AND fsyncs on every record, so this is the true per-record durability cost, not an amortised one",
        1,
        32,
        reps,
        @ptrCast(&ctx),
        &ctx.ops,
        walBody,
    );
}

const StoreCtx = struct {
    store: *mem3.Store,
    acc: u64 = 0,
    counter: u64 = 0,
    ops: usize = 0,
};

fn storeBody(c: *anyopaque, _: usize) void {
    const s: *StoreCtx = @ptrCast(@alignCast(c));
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        s.counter +%= 1;
        const i: usize = @intCast(s.counter);
        const id = s.store.addRaw(
            @enumFromInt(@as(u8, @intCast(i % 3))),
            EPISODES[i % EPISODES.len],
            "user|prefers|zig",
            1,
            0.6,
        ) catch {
            sink +%= 1;
            continue;
        };
        s.acc +%= id;
        s.ops += 1;
    }
    sink +%= s.acc;
}

fn benchStoreAddRaw(alloc: Allocator, reps: usize, durable: bool, scratch_dir: []const u8) !Stats {
    const store = try mem3.Store.init(alloc, .{
        .data_dir = if (durable) scratch_dir else null,
        .seed_default_goals = true,
    });
    defer {
        store.deinit();
        if (durable) removeScratch(scratch_dir);
    }

    var ctx = StoreCtx{ .store = store };
    return runBench(
        alloc,
        if (durable) "store.addRaw_durable" else "store.addRaw_memory",
        "ns/op",
        if (durable)
            "full pipeline (encode -> WAL append with a per-record fsync -> index); the fsync dominates this number"
        else
            "full pipeline (encode -> index) with persistence disabled",
        1,
        64,
        reps,
        @ptrCast(&ctx),
        &ctx.ops,
        storeBody,
    );
}

/// Best-effort removal of the bench scratch dir.
fn removeScratch(path: []const u8) void {
    var z: [256]u8 = undefined;
    if (std.fmt.bufPrint(&z, "{s}/mem3.wal\x00", .{path})) |p| {
        _ = std.c.unlink(p[0 .. p.len - 1 :0].ptr);
    } else |_| {}
    if (std.fmt.bufPrint(&z, "{s}/snapshot.bin\x00", .{path})) |p| {
        _ = std.c.unlink(p[0 .. p.len - 1 :0].ptr);
    } else |_| {}
    if (std.fmt.bufPrint(&z, "{s}\x00", .{path})) |p| {
        _ = std.c.rmdir(p[0 .. p.len - 1 :0].ptr);
    } else |_| {}
}

// ============================================================================
// Output
// ============================================================================

fn writeOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(std.c.STDOUT_FILENO, s.ptr, s.len);
}

fn printStat(s: Stats) void {
    writeOut(
        "  {s:.<30} {d:>12.1} {s:>11}   min {d:>10.1}  p95 {d:>13.1}\n",
        .{ s.name, s.medianNs(), s.unit, s.minNs(), s.p95Ns() },
    );
}

fn appendJsonLine(alloc: Allocator, json: *std.ArrayList(u8), s: Stats, comma: bool) !void {
    var tmp: [1400]u8 = undefined;
    const body = std.fmt.bufPrint(&tmp,
        \\    {{
        \\      "name": "{s}",
        \\      "unit": "{s}",
        \\      "note": "{s}",
        \\      "ops_per_rep": {d},
        \\      "reps": {d},
        \\      "median_ns": {d:.2},
        \\      "min_ns": {d:.2},
        \\      "p95_ns": {d:.2},
        \\      "mean_ns": {d:.2},
        \\      "per_sec": {d:.1}
        \\    }}{s}
    , .{
        s.name,
        s.unit,
        s.note,
        s.ops_per_rep,
        s.reps,
        s.medianNs(),
        s.minNs(),
        s.p95Ns(),
        s.meanNs(),
        s.perSec(),
        if (comma) "," else "",
    }) catch return error.FormatOverflow;
    try json.appendSlice(alloc, body);
}

fn renderJson(
    alloc: Allocator,
    results: []const Stats,
    params: Params,
    stability: f64,
    started_ms: i64,
) ![]u8 {
    var json: std.ArrayList(u8) = .empty;
    errdefer json.deinit(alloc);

    var stab_buf: [32]u8 = undefined;
    const stab_str = std.fmt.bufPrint(&stab_buf, "{d:.6}", .{stability}) catch "null";

    var head: [1024]u8 = undefined;
    const head_str = std.fmt.bufPrint(&head,
        \\{{
        \\  "tool": "mem3-bench",
        \\  "version": "{s}",
        \\  "generated_at_ms": {d},
        \\  "params": {{ "cells": {d}, "queries": {d}, "seed": {d}, "quick": {s} }},
        \\  "search_result_stability": {s},
        \\  "dce_checksum": {d},
        \\  "results": [
    , .{
        mem3.VERSION,
        started_ms,
        params.cells,
        params.queries,
        params.seed,
        if (params.quick) "true" else "false",
        stab_str,
        sink,
    }) catch return error.FormatOverflow;
    try json.appendSlice(alloc, head_str);

    for (results, 0..) |s, i| {
        try appendJsonLine(alloc, &json, s, i + 1 < results.len);
    }

    try json.appendSlice(alloc, "\n  ]\n}\n");
    return json.toOwnedSlice(alloc);
}

// ============================================================================
// Main
// ============================================================================

const Params = struct {
    cells: usize = 1000,
    queries: usize = 400,
    seed: u64 = 42,
    json_path: []const u8 = DEFAULT_JSON_PATH,
    quick: bool = false,
};

fn parseArgs(init: std.process.Init.Minimal) !Params {
    var p = Params{};
    var it = std.process.Args.iterate(init.args);
    _ = it.next(); // skip exe name

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quick")) {
            p.quick = true;
        } else if (std.mem.startsWith(u8, arg, "--cells=")) {
            p.cells = try std.fmt.parseInt(usize, arg["--cells=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--queries=")) {
            p.queries = try std.fmt.parseInt(usize, arg["--queries=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            p.seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--json=")) {
            p.json_path = arg["--json=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeOut(
                \\mem3-bench — measured in-process, no hardcoded numbers
                \\
                \\  (for the seven constitutional benchmarks, run
                \\   `mem3-bench --list` and `mem3-bench <name> --help`)
                \\
                \\  --cells=N     HNSW corpus size (default 2000)
                \\  --queries=N   search queries (default 600)
                \\  --seed=N      PRNG seed; the same seed reproduces the run
                \\  --json=PATH   results file (default bench-results.json)
                \\  --quick       10x fewer repetitions
                \\
            , .{});
            std.process.exit(0);
        } else {
            writeOut("unknown argument: {s}\n", .{arg});
            std.process.exit(2);
        }
    }
    return p;
}

fn scaled(base: usize, quick: bool) usize {
    return if (quick) @max(base / 10, 1) else base;
}

fn appendStat(alloc: Allocator, all: *std.ArrayList(Stats), s: Stats) !void {
    try all.append(alloc, s);
}

// ============================================================================
// Constitutional benchmark dispatch
// ============================================================================

/// The seven benchmark files named in the constitution's Performance
/// Standards table. The table is the reason this list exists and the
/// reason each entry carries its target: a benchmark nobody can find
/// cannot be run before a release gate.
const ConstitutionalBench = struct {
    /// CLI name, with dashes (this is what the user types).
    name: []const u8,
    /// The same benchmark spelled with underscores, accepted so a name
    /// copied straight out of the constitution (`hnsw_build.zig`) runs
    /// without editing.
    alt_name: []const u8,
    /// The file's base name, as written in the constitution.
    file: []const u8,
    target: []const u8,
    run: *const fn (Allocator, std.process.Init.Minimal) anyerror!void,
};

const CONSTITUTIONAL_BENCHES = [_]ConstitutionalBench{
    .{
        .name = "throughput",
        .alt_name = "throughput",
        .file = "bench/throughput.zig",
        .target = ">= 1.75K MemCells/sec (sustained, durable path; worst window)",
        .run = throughput_bench.run,
    },
    .{
        .name = "retrieval-p95",
        .alt_name = "retrieval_p95",
        .file = "bench/retrieval_p95.zig",
        .target = "< 10ms P95 at 100K corpus (TopK=10)",
        .run = retrieval_p95_bench.run,
    },
    .{
        .name = "hnsw-build",
        .alt_name = "hnsw_build",
        .file = "bench/hnsw_build.zig",
        .target = "100K vectors indexed in < 30s",
        .run = hnsw_build_bench.run,
    },
    .{
        .name = "multihop",
        .alt_name = "multihop",
        .file = "bench/multihop.zig",
        .target = "< 5ms for 1K seeds (3 hops)",
        .run = multihop_bench.run,
    },
    .{
        .name = "cold-start",
        .alt_name = "cold_start",
        .file = "bench/cold_start.zig",
        .target = "< 200ms (binary launch -> ready)",
        .run = cold_start_bench.run,
    },
    .{
        .name = "footprint",
        .alt_name = "footprint",
        .file = "bench/footprint.zig",
        .target = "< 500MB RSS for 100K MemCells",
        .run = footprint_bench.run,
    },
    .{
        .name = "longmemeval",
        .alt_name = "longmemeval",
        .file = "bench/longmemeval.zig",
        .target = ">= 80% end-to-end accuracy",
        .run = longmemeval_bench.run,
    },
    .{
        .name = "longmemeval-official",
        .alt_name = "longmemeval_official",
        .file = "bench/longmemeval_official.zig",
        .target = "none (retrieval-only; official dataset via --data)",
        .run = longmemeval_official_bench.run,
    },
    .{
        .name = "lme-compare",
        .alt_name = "lme_compare",
        .file = "bench/lme_compare.zig",
        .target = "none (paired bootstrap over --dump-scores files; see ablation-tri-source.md)",
        .run = lme_compare_bench.run,
    },
    .{
        .name = "lme-synthetic",
        .alt_name = "lme_synthetic",
        .file = "bench/lme_compare.zig",
        .target = "none (SYNTHETIC goal/source mechanism check)",
        .run = lme_compare_bench.runSynthetic,
    },
};

fn printBenchmarkList() void {
    writeOut(
        \\mem3-bench — constitutional benchmarks
        \\
        \\Each emits ONE JSON object on stdout. Progress goes to stderr,
        \\so stdout stays parseable: `... | python3 -m json.tool` works.
        \\
        \\  benchmark         file                     constitutional target
        \\  ---------------  -----------------------  ----------------------------------
    , .{});
    for (CONSTITUTIONAL_BENCHES) |b| {
        writeOut("  {s:.<17} {s:<23} {s}\n", .{ b.name, b.file, b.target });
    }
    writeOut(
        \\
        \\  --list                 this table
        \\  <name> --help          flags and default scale for one benchmark
        \\  --scale=F              raise the scale (--quick is 0.1)
        \\  --seed=N               PRNG seed; the same seed reproduces the run
        \\  --data-dir=P           scratch dir (default: a fresh /tmp dir)
        \\
        \\With no arguments this runs the original micro-benchmark suite
        \\instead (hashing, serializer, encoder, hnsw, wal, store), which
        \\writes bench-results.json rather than stdout JSON.
        \\
    , .{});
}

/// Accept both `throughput` and `throughput.zig` / `bench/throughput.zig`,
/// so a name copied straight out of the constitution works.
fn findBenchmark(name: []const u8) ?ConstitutionalBench {
    var want = name;
    if (std.mem.lastIndexOfScalar(u8, want, '/')) |i| want = want[i + 1 ..];
    if (std.mem.endsWith(u8, want, ".zig")) want = want[0 .. want.len - 4];

    for (CONSTITUTIONAL_BENCHES) |b| {
        if (std.mem.eql(u8, want, b.name) or std.mem.eql(u8, want, b.alt_name)) return b;
    }
    return null;
}

/// Route argv to a constitutional benchmark, or hand back to the
/// original suite. Returns true when a named benchmark handled it.
fn dispatch(alloc: Allocator, init: std.process.Init.Minimal) !bool {
    var it = std.process.Args.iterate(init.args);
    _ = it.next();
    const first = it.next() orelse return false;

    if (std.mem.eql(u8, first, "--list")) {
        printBenchmarkList();
        return true;
    }
    if (first.len > 0 and first[0] == '-') return false;

    const bench = findBenchmark(first) orelse {
        writeOut("mem3-bench: no benchmark named '{s}'\n\n", .{first});
        printBenchmarkList();
        std.process.exit(2);
    };

    // The named benchmark re-parses argv itself: it needs argv[0] to
    // still be argv[0] so `--help` and the scale flags land where they
    // were typed.
    try bench.run(alloc, init);
    return true;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    if (try dispatch(alloc, init)) return;

    const params = parseArgs(init) catch {
        writeOut("bench: bad arguments\n", .{});
        std.process.exit(2);
    };

    const started_ms = mem3.utils.time.nowMs();

    writeOut("mem3-bench — measured in-process | seed={d} cells={d} queries={d}{s}\n", .{
        params.seed,
        params.cells,
        params.queries,
        if (params.quick) " quick" else "",
    });
    writeOut("{s}\n", .{RULE});

    var all: std.ArrayList(Stats) = .empty;
    defer {
        for (all.items) |s| alloc.free(s.samples);
        all.deinit(alloc);
    }

    // --- foundation primitives ------------------------------------------------
    try appendStat(alloc, &all, try benchHashing(alloc, scaled(50, params.quick)));
    try appendStat(alloc, &all, try benchHashCombine(alloc, scaled(50, params.quick)));
    try appendStat(alloc, &all, try benchFormatIso8601(alloc, scaled(50, params.quick)));

    // --- serialisation --------------------------------------------------------
    try appendStat(alloc, &all, try benchSerializerRoundtrip(alloc, scaled(30, params.quick)));
    try appendStat(alloc, &all, try benchEncoder(alloc, scaled(30, params.quick)));

    // --- retrieval ------------------------------------------------------------
    // Size repetition counts to the work budget so no repetition runs dry.
    // 64 vectors per insert repetition; 20 queries per search repetition;
    // one warmup repetition is always spent first.
    const insert_reps = @max(params.cells / 64, 1);
    try appendStat(alloc, &all, try benchHnswInsert(alloc, insert_reps, params.cells, params.seed));

    const search_ops = 20;
    const search_reps = @max(@min(scaled(25, params.quick), params.queries / search_ops - 1), 1);
    const search_q = search_ops * (search_reps + 1);
    const sr = try benchHnswSearch(alloc, search_reps, params.cells, search_q, params.seed);
    try appendStat(alloc, &all, sr.stats);

    // --- persistence ----------------------------------------------------------
    try appendStat(alloc, &all, try benchWalAppendFsync(alloc, scaled(15, params.quick)));
    // Both store runs must insert the same number of cells: per-op cost
    // grows with index depth, so a durable run with fewer repetitions
    // would look artificially faster than the in-memory one.
    const store_reps = scaled(15, params.quick);
    try appendStat(alloc, &all, try benchStoreAddRaw(alloc, store_reps, false, ""));
    try appendStat(alloc, &all, try benchStoreAddRaw(alloc, store_reps, true, "/tmp/mem3_bench_store"));

    // --- report ---------------------------------------------------------------
    writeOut("\n  {s:.<30} {s:>12} {s:>11}   {s:>10}  {s:>13}\n", .{ "benchmark", "median", "unit", "min", "p95" });
    writeOut("{s}\n", .{RULE});
    for (all.items) |s| printStat(s);
    writeOut("{s}\n", .{RULE});
    writeOut("\n  search result stability (repeat-vs-repeat) : {d:.4}\n", .{sr.stability});
    writeOut("  DCE guard checksum                            : {d}\n", .{sink});
    writeOut("  wall clock                                   : {d} ms\n", .{mem3.utils.time.nowMs() - started_ms});

    writeOut(
        \\
        \\Scope: these are the shipped code paths, measured on this machine.
        \\hnsw.search is an HNSW beam search with ef-bounded expansion;
        \\grows with the corpus; do not quote it as graph-index performance.
        \\WAL.append fsyncs on every record — see wal.append_durable.
        \\
    , .{});

    // --- JSON -----------------------------------------------------------------
    const json = try renderJson(alloc, all.items, params, sr.stability, started_ms);
    defer alloc.free(json);

    var zbuf: [512]u8 = undefined;
    const zpath = std.fmt.bufPrint(&zbuf, "{s}\x00", .{params.json_path}) catch {
        writeOut("bench: json path too long\n", .{});
        return;
    };
    const fd = std.c.open(zpath[0..zpath.len :0].ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) {
        writeOut("bench: cannot write {s}\n", .{params.json_path});
        return;
    }
    defer _ = std.c.close(fd);
    var written: usize = 0;
    while (written < json.len) {
        const n = std.c.write(fd, json.ptr + written, json.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    writeOut("\n  results written to {s}\n", .{params.json_path});
}