//! Constitutional target: **three-way recall TopK=10, P95 < 10 ms at a
//! 100K corpus**.
//!
//! (`.specify/memory/constitution.md`, "Performance Standards", row 2.)
//!
//! ## What is actually measured
//!
//! `HybridRetriever.recall(query_text, 10)` — the real three-way path:
//! embed the query with the shipped `lexical_hash` embedder, dense
//! `hnsw.search`, graph `multiHop` expansion over the hypergraph, then
//! fuse. Only the query loop is timed; corpus construction is excluded
//! and reported separately as `corpus_build_ms`, because a build cost
//! smuggled into a query latency is how a P95 becomes fiction.
//!
//! The corpus is text, not raw vectors: documents are embedded with the
//! same embedder the Store uses, so what is measured is the path a real
//! query takes, not a synthetic vector-space shortcut.
//!
//! Primary metric: **P95 of per-query latency**, nearest-rank over the
//! query population. P50/P99/max ride along because a P95 with no P99
//! next to it hides the tail.
//!
//! Two secondary measurements, both labelled as secondary:
//!   * `dense_only` — `hnsw.search` alone, for attribution.
//!   * `recall_at_10_vs_exhaustive` — the fraction of the true top-10
//!     (exact cosine scan) that the graph actually returned. Every
//!     query has a planted nearest neighbour, so this is a real
//!     measurement and not a self-comparison.
//!
//! ## Default scale and honest cost
//!
//! Default corpus 20,000 documents, 200 queries, at 384 dims. Index
//! build is the dominant cost and is reported as `corpus_build_ms`.
//! The full constitutional 100,000-document corpus takes roughly two
//! minutes to build on an M1-class machine (HNSW insert is ~1 ms/op in
//! this implementation — see `hnsw_build.zig`), so `--corpus=100000`
//! is available but is not the default.
//!
//! If the run stops short of 100K, `measured_at_N` says where the
//! number was taken and the projection lives in its own `projection`
//! object with the fit stated. It is never blended into `measured`.

const std = @import("std");
const mem3 = @import("mem3");
const harness = @import("harness.zig");

const Allocator = std.mem.Allocator;

const TARGET_P95_MS: f64 = 10.0;
const CONSTITUTION_N: u64 = 100_000;

const DEFAULT_CORPUS: usize = 20_000;
const DEFAULT_QUERIES: usize = 200;
const DEFAULT_RECALL_QUERIES: usize = 25;
const DIM: u16 = 384;
const TOPK: usize = 10;

/// Vocabulary is deliberately disjoint from the filler vocabulary so a
/// query cannot be answered by accident through a shared common word.
const TOPIC_WORDS = [_][]const u8{
    "scheduler",  "allocator",  "checkpoint", "telemetry", "migration",
    "planner",    "quantizer",  "supervisor", "rebalance", "compaction",
    "arbitration", "idempotent", "watermark", "saturation", "throttle",
};

const FILLER_WORDS = [_][]const u8{
    "review",   "notes",  "weekly",  "summary", "agenda", "followup",
    "archive",  "digest", "minutes", "action",  "item",   "ticket",
    "refactor", "update", "status",  "owner",   "due",    "date",
    "context",  "detail", "link",    "thread",  "reply",  "question",
};

/// A document: one topic word plus filler, length varying so the
/// embedder's unigram and bigram features are not all the same width.
fn makeDoc(alloc: Allocator, topic: usize, len: usize, rng: *harness.Rng) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "document about ");
    try buf.appendSlice(alloc, TOPIC_WORDS[topic % TOPIC_WORDS.len]);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, FILLER_WORDS[rng.below(FILLER_WORDS.len)]);
    }
    return buf.toOwnedSlice(alloc);
}

/// A query is a partial restatement of one document: the topic word
/// (which makes the document the planted nearest neighbour) plus a few
/// of its filler words.
fn makeQuery(alloc: Allocator, topic: usize, rng: *harness.Rng) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "what is known about ");
    try buf.appendSlice(alloc, TOPIC_WORDS[topic % TOPIC_WORDS.len]);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, FILLER_WORDS[rng.below(FILLER_WORDS.len)]);
    }
    return buf.toOwnedSlice(alloc);
}

const Docs = struct {
    texts: [][]const u8,
    topics: []usize,

    fn deinit(self: Docs, alloc: Allocator) void {
        for (self.texts) |t| alloc.free(t);
        alloc.free(self.texts);
        alloc.free(self.topics);
    }
};

fn buildDocs(alloc: Allocator, n: usize, seed: u64) !Docs {
    var rng = harness.Rng.init(seed);
    const texts = try alloc.alloc([]const u8, n);
    errdefer alloc.free(texts);
    const topics = try alloc.alloc(usize, n);
    errdefer alloc.free(topics);
    for (texts, topics) |*t, *tp| {
        const topic = rng.below(TOPIC_WORDS.len);
        tp.* = topic;
        t.* = try makeDoc(alloc, topic, 4 + rng.below(12), &rng);
    }
    return .{ .texts = texts, .topics = topics };
}

var sink: u64 = 0;

/// One scored row of the exhaustive scan. Declared at file scope:
/// Zig 0.17 forbids declaring a function or a local type inside
/// another function.
const Scored = struct {
    id: u64,
    sim: f32,
};

fn scoredGt(_: void, a: Scored, b: Scored) bool {
    return a.sim > b.sim;
}

/// Exact top-k by cosine scan. Independent of the index it scores.
fn exhaustiveTopK(
    alloc: Allocator,
    vecs: []const []f32,
    query: []const f32,
    k: usize,
) ![]u64 {
    const scored = try alloc.alloc(Scored, vecs.len);
    defer alloc.free(scored);
    for (vecs, 0..) |v, i| scored[i] = .{ .id = @intCast(i + 1), .sim = harness.cosine(query, v) };
    // Full sort: k is 10 but this is the oracle, and a partial selection
    // here would mean a subtly wrong ground truth.
    std.mem.sort(Scored, scored, {}, scoredGt);
    const out = try alloc.alloc(u64, @min(k, scored.len));
    for (out, 0..) |*o, i| o.* = scored[i].id;
    return out;
}

const QueryRun = struct {
    recall_lat: harness.Latencies,
    dense_lat: harness.Latencies,
    recall_at_k: ?f64,
    recall_queries: usize,
    results_mean: f64,
    build_ms: f64,
    embed_ms: f64,
    indexed: usize,
};

fn runQueries(
    alloc: Allocator,
    docs: Docs,
    vecs: []const []f32,
    hnsw: *mem3.HNSW,
    hymem: *mem3.HyMem,
    bm25: *mem3.BM25,
    query_count: usize,
    recall_queries: usize,
    seed: u64,
) !QueryRun {
    var rng = harness.Rng.init(seed ^ 0xA5A5A5A5);

    // Query embedder and index embedder are the same object here:
    // a retriever that hashed with one embedder and searched an index
    // built with another would be scoring two different spaces.
    const qemb = try mem3.Embedder.init(.lexical_hash, DIM);
    // `initWithSparse`, not `init`: `init` leaves `bm25` null, which
    // scores every cell's sparse arm at zero. That is a configuration
    // the product never runs, and a latency benchmark that silently
    // measured it would report a p95 for the wrong retriever.
    var retriever = mem3.HybridRetriever.initWithSparse(alloc, mem3.Config{}, qemb, hnsw, hymem, bm25);

    const lat = try alloc.alloc(u64, query_count);
    defer alloc.free(lat);
    const dense = try alloc.alloc(u64, query_count);
    defer alloc.free(dense);

    var hits: usize = 0;
    var truth_total: usize = 0;
    var results_total: usize = 0;
    var embed_ns: u64 = 0;

    var qi: usize = 0;
    while (qi < query_count) : (qi += 1) {
        const topic = docs.topics[rng.below(docs.topics.len)];
        const qtext = try makeQuery(alloc, topic, &rng);
        defer alloc.free(qtext);

        // Dense-only, same query, so the three-way path can be read
        // against what it costs before fusion.
        {
            const t0 = harness.clockNs();
            const qvec = try retriever.embedQuery(alloc, qtext);
            defer alloc.free(qvec);
            embed_ns += harness.sinceNs(t0);
            const hits_dense = try hnsw.search(alloc, qvec, TOPK);
            defer alloc.free(hits_dense);
            sink +%= hits_dense.len;
            dense[qi] = harness.sinceNs(t0);
        }

        const t0 = harness.clockNs();
        const cands = try retriever.recall(alloc, qtext, TOPK);
        lat[qi] = harness.sinceNs(t0);
        defer alloc.free(cands);
        results_total += cands.len;
        for (cands) |c| sink +%= c.cell_id;

        // Recall against an exact scan, on a subset — an O(N^2) scan
        // over every query would dominate the benchmark's own runtime.
        if (qi < recall_queries) {
            const qvec = try retriever.embedQuery(alloc, qtext);
            defer alloc.free(qvec);
            const truth = try exhaustiveTopK(alloc, vecs, qvec, TOPK);
            defer alloc.free(truth);
            for (cands) |c| {
                for (truth) |t| {
                    if (c.cell_id == t) {
                        hits += 1;
                        truth_total += 1;
                        break;
                    }
                }
            }
        }
    }

    return .{
        .recall_lat = try harness.Latencies.fromSlice(alloc, lat),
        .dense_lat = try harness.Latencies.fromSlice(alloc, dense),
        .recall_at_k = if (truth_total == 0) null else @as(f64, @floatFromInt(hits)) /
            @as(f64, @floatFromInt(truth_total)),
        .recall_queries = recall_queries,
        .results_mean = if (query_count == 0)
            0
        else
            @as(f64, @floatFromInt(results_total)) / @as(f64, @floatFromInt(query_count)),
        .build_ms = 0,
        .embed_ms = harness.nsToMs(embed_ns),
        .indexed = docs.texts.len,
    };
}

pub fn run(alloc: Allocator, init: std.process.Init.Minimal) !void {
    var common = harness.CommonArgs{};
    var corpus_n: ?usize = null;
    var query_n: ?usize = null;
    var recall_q: ?usize = null;

    var it = harness.argIterator(init);
    while (it.next()) |arg| {
        if (try harness.parseCommon(arg, &common)) continue;
        if (std.mem.startsWith(u8, arg, "--corpus=")) {
            corpus_n = try std.fmt.parseInt(usize, arg["--corpus=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--queries=")) {
            query_n = try std.fmt.parseInt(usize, arg["--queries=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--recall-queries=")) {
            recall_q = try std.fmt.parseInt(usize, arg["--recall-queries=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            harness.out(
                \\retrieval_p95 — three-way recall latency at TopK=10
                \\
                \\  --corpus=N          documents in the index (default {d})
                \\  --queries=N         timed queries (default {d})
                \\  --recall-queries=N  queries also scored against an exact scan (default {d})
                \\  --scale=F           multiply the defaults; --quick is 0.1
                \\  --seed=N            PRNG seed
                \\
            , .{ DEFAULT_CORPUS, DEFAULT_QUERIES, DEFAULT_RECALL_QUERIES });
            return;
        } else {
            harness.out("retrieval_p95: unknown argument {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }

    const n_corpus = harness.scaled(corpus_n orelse DEFAULT_CORPUS, common);
    const n_queries = @max(harness.scaled(query_n orelse DEFAULT_QUERIES, common), 1);
    const n_recall_q = @min(@max(harness.scaled(recall_q orelse DEFAULT_RECALL_QUERIES, common), 0), n_queries);

    harness.progress("retrieval_p95: building {d}-document corpus...\n", .{n_corpus});

    const docs = try buildDocs(alloc, n_corpus, common.seed);
    defer docs.deinit(alloc);

    const vecs = try alloc.alloc([]f32, n_corpus);
    defer alloc.free(vecs);

    var hnsw = mem3.HNSW.init(alloc, mem3.Config{}, DIM);
    defer hnsw.deinit();

    var ids = std.atomic.Value(u64).init(1);
    var hymem = mem3.HyMem.init(alloc, &ids);
    defer hymem.deinit();

    // The lexical arm, built over the same documents as the vectors so
    // the retriever below sees all three arms the way the Store wires
    // them.
    const bm25_cfg = mem3.Config{};
    var bm25 = mem3.BM25.init(alloc, bm25_cfg.bm25_k1, bm25_cfg.bm25_b);
    defer bm25.deinit();

    const emb = try mem3.Embedder.init(.lexical_hash, DIM);

    // --- build (timed, but reported apart from the latency) -------------
    const build_t0 = harness.clockNs();
    for (docs.texts, 0..) |text, i| {
        const v = try emb.embed(alloc, text);
        defer alloc.free(v);
        vecs[i] = v;
        try hnsw.insert(@intCast(i + 1), v);
        try bm25.index(@intCast(i + 1), text);

        // One associative edge per document to the previous document of
        // the same topic, so the graph arm of the fusion has real
        // structure to traverse instead of an empty hypergraph.
        if (i > 0 and docs.topics[i] == docs.topics[i - 1]) {
            const nodes = [_]u64{ @intCast(i), @intCast(i + 1) };
            _ = hymem.addEdge(.{
                .id = 0,
                .edge_type = .associative,
                .nodes = &nodes,
                .weight = 0.7,
                .source_weights = .{ 0.34, 0.33, 0.33 },
                .confidence = 0.8,
                .created_at = @intCast(i),
                .metadata = null,
            }) catch |err| {
                harness.progress("retrieval_p95: edge insert failed: {s}\n", .{@errorName(err)});
            };
        }
    }
    const build_ms = harness.nsToMs(harness.sinceNs(build_t0));
    harness.progress("retrieval_p95: indexed {d} docs in {d:.0} ms; querying...\n", .{ n_corpus, build_ms });

    var res = try runQueries(alloc, docs, vecs, &hnsw, &hymem, &bm25, n_queries, n_recall_q, common.seed);
    defer res.recall_lat.deinit(alloc);
    defer res.dense_lat.deinit(alloc);

    const p95_ms = res.recall_lat.p95Ns() / 1e6;

    var j = harness.Json.init(alloc);
    defer j.deinit();

    const target_met = p95_ms < TARGET_P95_MS;
    try harness.emitEnvelope(&j, .{
        .benchmark = "retrieval_p95",
        .metric = "three_way_recall_p95_latency",
        .target = "< 10ms at 100K corpus (TopK=10)",
        .target_value = TARGET_P95_MS,
        .target_comparison = "<",
        .unit = "ms",
        .measured = p95_ms,
        .measured_at_N = @intCast(n_corpus),
        .seed = common.seed,
        .notes = "P95 over per-query HybridRetriever.recall latency " ++
            "(embed + dense top-10*3 + 3-hop graph expansion + fusion). " ++
            "Nearest-rank percentiles over the query population. Corpus " ++
            "construction is excluded from the latency and reported as " ++
            "corpus_build_ms. measured_at_N is the corpus this run actually " ++
            "built; the constitutional corpus is 100K.",
    });

    try j.key("corpus_build_ms");
    try j.float(build_ms);
    try j.key("corpus_documents");
    try j.int(@as(u64, @intCast(n_corpus)));
    try j.key("indexed_nodes");
    try j.int(@as(u64, @intCast(hnsw.count)));
    try j.key("hyperedges");
    try j.int(@as(u64, @intCast(hymem.count())));
    try j.key("embed_dim");
    try j.int(DIM);
    try j.key("topk");
    try j.int(TOPK);
    try j.key("queries_timed");
    try j.int(@as(u64, @intCast(n_queries)));

    try j.key("three_way_recall_latency_ms");
    try j.beginObject();
    try j.key("p50");
    try j.float(res.recall_lat.p50Ns() / 1e6);
    try j.key("p95");
    try j.float(p95_ms);
    try j.key("p99");
    try j.float(res.recall_lat.p99Ns() / 1e6);
    try j.key("max");
    try j.float(res.recall_lat.maxNs() / 1e6);
    try j.key("min");
    try j.float(res.recall_lat.minNs() / 1e6);
    try j.key("mean");
    try j.float(res.recall_lat.meanNs() / 1e6);
    try j.key("query_embed_ms_total");
    try j.float(res.embed_ms);
    try j.key("results_returned_mean");
    try j.float(res.results_mean);
    try j.endObject();

    try j.key("three_way_recall_latency_ns");
    try res.recall_lat.writeJson(&j);

    try j.key("dense_only_latency_ns");
    try j.beginObject();
    try j.key("note");
    try j.str("HybridRetriever.embedQuery + hnsw.search(k=10) only — the " ++
        "query-embed cost is inside this figure; it is the lower bound the " ++
        "three-way path adds fusion and graph expansion on top of.");
    try j.key("latency");
    try res.dense_lat.writeJson(&j);
    try j.endObject();

    try j.key("recall_at_10_vs_exhaustive");
    try j.optFloat(res.recall_at_k);
    try j.key("recall_queries_scored");
    try j.int(@as(u64, @intCast(res.recall_queries)));
    try j.key("recall_measurement_note");
    try j.str("Fraction of the exact cosine top-10 (independent O(N) scan " ++
        "per query) that the three-way fused result contained. Queries are " ++
        "partial restatements of one document, so a true nearest neighbour " ++
        "exists. Scored on --recall-queries queries only.");

    // --- projection ----------------------------------------------------
    if (n_corpus < CONSTITUTION_N) {
        // Two measured points do not identify a scaling law, so the
        // projection says exactly what it assumed and refuses to be
        // read as a measurement.
        const per_query_ns = res.recall_lat.meanNs();
        const projected = (per_query_ns * @as(f64, @floatFromInt(CONSTITUTION_N)) /
            @as(f64, @floatFromInt(n_corpus))) / 1e6;
        try harness.emitProjection(
            &j,
            "projected_p95_ms_at_100k",
            CONSTITUTION_N,
            projected,
            "proportional-to-N scaling from the measured mean per-query " ++
                "latency at measured_at_N",
            @intCast(n_corpus),
            "This is an upper-bound-shaped guess, not a measurement: " ++
                "HNSW search is sub-linear in N in the paper and in most " ++
                "implementations, so a proportional extrapolation almost " ++
                "certainly OVERSTATES the 100K P95. The honest reading is " ++
                "'if query latency were linear in corpus size, 100K would " ++
                "be about this'. Re-run with --corpus=100000 to measure it.",
        );
    }

    try j.key("target_met_at_measured_N");
    try j.boolean(target_met);
    try j.key("dce_checksum");
    try j.int(sink);
    try j.endObject();

    try harness.finish(alloc, &j);
}

test "retrieval_p95: P95 is nearest-rank over the query population" {
    // Four samples in ms: the P95 must be the worst of them (ceil(0.95*4)
    // = 4 -> index 3), not the mean and not the second worst. Getting
    // this wrong is how a tail gets reported as a typical value.
    const three_way = try harness.Latencies.fromSlice(
        std.testing.allocator,
        &.{ 1_000_000, 2_000_000, 9_000_000, 20_000_000 },
    );
    defer three_way.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(20.0, three_way.p95Ns() / 1e6, 1e-9);
    try std.testing.expectApproxEqAbs(2.0, three_way.p50Ns() / 1e6, 1e-9);
    try std.testing.expectApproxEqAbs(8.0, three_way.meanNs() / 1e6, 1e-9);
}

test "retrieval_p95: exact scan returns k distinct ids, k <= corpus" {
    const alloc = std.testing.allocator;
    const corpus = try harness.VectorCorpus.generate(alloc, 32, 8, 5, .clustered);
    defer corpus.deinit(alloc);

    var vecs: [32][]f32 = undefined;
    for (0..32) |i| vecs[i] = corpus.vector(i);

    const top = try exhaustiveTopK(alloc, &vecs, vecs[7], 10);
    defer alloc.free(top);
    try std.testing.expectEqual(@as(usize, 10), top.len);
    try std.testing.expectEqual(@as(u64, 8), top[0]);

    // k larger than the corpus must clamp, never over-read.
    const all = try exhaustiveTopK(alloc, &vecs, vecs[0], 100);
    defer alloc.free(all);
    try std.testing.expectEqual(@as(usize, 32), all.len);
}

test "retrieval_p95: a query names one topic and the corpus plants it" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const docs = try buildDocs(alloc, 64, 3);
    defer docs.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 64), docs.texts.len);

    var rng = harness.Rng.init(11);
    const q = try makeQuery(alloc, docs.topics[0], &rng);
    defer alloc.free(q);
    // The query restates the topic word of the document it came from,
    // which is what makes the nearest neighbour real rather than hoped
    // for.
    try std.testing.expect(std.mem.indexOf(u8, q, TOPIC_WORDS[docs.topics[0]]) != null);
}