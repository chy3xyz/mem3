//! Constitutional target: **3-hop multi-hop traversal < 5 ms for 1K seeds**.
//!
//! (`.specify/memory/constitution.md`, "Performance Standards", row 4.)
//!
//! ## What is actually measured
//!
//! `Store.multiHopScored(alloc, seeds, 3, decay, threshold, null)` —
//! the relevance-propagating traversal, which is the shipped path
//! (`POST /api/query` reaches it through `HybridRetriever.recall`).
//! Relevance propagation is the more expensive of the two multi-hop
//! entry points and the one that actually feeds the fused ranking, so
//! it is the one the target should be read against.
//!
//! "For 1K seeds" is ambiguous in the constitution, so both readings
//! are measured and labelled:
//!   * `per_seed`  — each of 1,000 distinct seed nodes traversed on its
//!                   own. Primary metric: P95 per-seed latency.
//!   * `batched`   — all 1,000 seeds passed to a single traversal call,
//!                   which is what a 1,000-seed query would cost.
//!
//! ## The graph is not a toy
//!
//! Traversal cost is a function of the degree and the branching factor,
//! so the hypergraph is built at scale (`--cells`, `--edges`) with
//! every edge validated, and its shape (nodes, edges, average degree) is
//! reported. A 5 ms number over a 10-edge graph says nothing about a
//! 5 ms number over a realistic one, so the shape travels with the
//! latency.
//!
//! ## Default scale and honest cost
//!
//! Default 5,000 cells / 8,000 edges, 1,000 seeds, built in memory
//! (`data_dir = null`) so the build cost does not drown the traversal.
//! Build time is reported separately as `graph_build_ms`. The full
//! 1,000-seed run at this graph size takes a few seconds on an M1;
//! `--cells=` / `--edges=` raise the graph, `--seeds=` the population.

const std = @import("std");
const mem3 = @import("mem3");
const harness = @import("harness.zig");

const Allocator = std.mem.Allocator;

const TARGET_MS: f64 = 5.0;
const CONSTITUTION_SEEDS: u64 = 1_000;
const HOPS: u8 = 3;
const DEFAULT_CELLS: usize = 5_000;
const DEFAULT_EDGES: usize = 8_000;
const DEFAULT_SEEDS: usize = 1_000;

/// Edges are built over the cell id space. `Store.addRaw` hands out ids
/// from a shared monotonic counter that also covers goals, so real cell
/// ids are collected as they are issued rather than assumed.
const GraphBuild = struct {
    ids: []u64,
    edges_added: usize,
    edge_errors: usize,
    build_ms: f64,
    degree_sum: usize,
    degree_max: usize,

    fn deinit(self: GraphBuild, alloc: Allocator) void {
        alloc.free(self.ids);
    }

    fn avgDegree(self: GraphBuild) f64 {
        if (self.edges_added == 0) return 0;
        return @as(f64, @floatFromInt(self.degree_sum)) /
            (@as(f64, @floatFromInt(self.edges_added)) * 2.0);
    }
};

const Built = struct {
    store: *mem3.Store,
    g: GraphBuild,
};

fn buildGraph(alloc: Allocator, cells: usize, edges_wanted: usize, seed: u64) !Built {
    var rng = harness.Rng.init(seed);
    const store = try mem3.Store.init(alloc, .{
        // In-memory: a traversal benchmark that also fsyncs 8,000 times
        // is measuring the wrong thing.
        .data_dir = null,
        .seed_default_goals = true,
    });
    errdefer store.deinit();

    const ids = try alloc.alloc(u64, cells);
    errdefer alloc.free(ids);

    const t0 = harness.clockNs();
    for (0..cells) |i| {
        const id = store.addRaw(
            @enumFromInt(@as(u8, @intCast(i % 3))),
            EPISODE_TEMPLATES[i % EPISODE_TEMPLATES.len],
            CONST_FACTS,
            1,
            0.6,
        ) catch continue;
        ids[i] = id;
    }

    var added: usize = 0;
    var failed: usize = 0;
    var degree_sum: usize = 0;
    var degree_max: usize = 0;
    var e: usize = 0;
    while (e < edges_wanted) : (e += 1) {
        const a = ids[rng.below(cells)];
        const b = ids[rng.below(cells)];
        if (a == b) continue;
        const nodes = [_]u64{ a, b };
        _ = store.addHyperedge(.{
            .id = 0,
            .edge_type = EDGE_KINDS[rng.below(EDGE_KINDS.len)],
            .nodes = &nodes,
            .weight = 0.4 + 0.5 * @as(f32, @floatCast(rng.unitF64())),
            .source_weights = .{ 0.34, 0.33, 0.33 },
            .confidence = 0.35 + 0.6 * @as(f32, @floatCast(rng.unitF64())),
            .created_at = @intCast(e),
            .metadata = null,
        }) catch {
            failed += 1;
            continue;
        };
        added += 1;
        degree_sum += 2;
    }
    const build_ms = harness.nsToMs(harness.sinceNs(t0));

    // Recompute the real degree distribution from the graph rather than
    // from the counter, so a rejected edge cannot inflate the claim.
    var eit = store.hymem.edges.iterator();
    while (eit.next()) |entry| {
        degree_max = @max(degree_max, entry.value_ptr.*.nodes.len);
    }

    return .{
        .store = store,
        .g = .{
            .ids = ids,
            .edges_added = added,
            .edge_errors = failed,
            .build_ms = build_ms,
            .degree_sum = degree_sum,
            .degree_max = degree_max,
        },
    };
}

const EPISODE_TEMPLATES = [_][]const u8{
    "user asked to refactor the persistence layer and keep the WAL contract",
    "agent observed a replay failure after an unclean shutdown mid-append",
    "tool output showed a snapshot written with a stale cell counter",
    "reflection: the forgetting sweep removed a high-importance cell",
    "goal ghw was blocked because the harness had no world model binding",
    "episode recorded a duplicate triad across matter and form sources",
    "conversation about consolidating two similar cells into one abstract",
    "system reported coherence below the constitutional threshold",
};

const CONST_FACTS = "user|prefers|zig";

const EDGE_KINDS = [_]mem3.EdgeType{ .causal, .temporal, .associative, .goal };

var sink: u64 = 0;

const MultiHopResult = struct {
    per_seed: harness.Latencies,
    batched_ns: u64,
    batched_reached: usize,
    reached_mean: f64,
    max_hop_reached: u8,
};

fn traverse(
    alloc: Allocator,
    store: *mem3.Store,
    ids: []const u64,
    seed_count: usize,
) !MultiHopResult {
    var rng = harness.Rng.init(0x5EED);

    const samples = try alloc.alloc(u64, seed_count);
    defer alloc.free(samples);
    const seed_buf = try alloc.alloc(mem3.HyMem.ScoredNode, seed_count);
    defer alloc.free(seed_buf);

    var reached_total: usize = 0;
    var max_hop: u8 = 0;

    for (0..seed_count) |i| {
        const id = ids[rng.below(ids.len)];
        seed_buf[0] = .{ .id = id, .score = 1.0, .hops = 0 };
        const one = harness.clockNs();
        const out = try store.multiHopScored(alloc, seed_buf[0..1], HOPS, 0.5, 0.3, null);
        samples[i] = harness.sinceNs(one);
        defer alloc.free(out);
        reached_total += out.len;
        for (out) |node| {
            sink +%= node.id;
            max_hop = @max(max_hop, node.hops);
        }
    }

    // Batched: every seed in one call.
    for (0..seed_count) |i| {
        seed_buf[i] = .{ .id = ids[rng.below(ids.len)], .score = 1.0, .hops = 0 };
    }
    const b0 = harness.clockNs();
    const batched = try store.multiHopScored(alloc, seed_buf, HOPS, 0.5, 0.3, null);
    const batched_ns = harness.sinceNs(b0);
    defer alloc.free(batched);
    for (batched) |node| sink +%= node.id;

    return .{
        .per_seed = try harness.Latencies.fromSlice(alloc, samples),
        .batched_ns = batched_ns,
        .batched_reached = batched.len,
        .reached_mean = if (seed_count == 0)
            0
        else
            @as(f64, @floatFromInt(reached_total)) / @as(f64, @floatFromInt(seed_count)),
        .max_hop_reached = max_hop,
    };
}

pub fn run(alloc: Allocator, init: std.process.Init.Minimal) !void {
    var common = harness.CommonArgs{};
    var cells: ?usize = null;
    var edges: ?usize = null;
    var seeds: ?usize = null;

    var it = harness.argIterator(init);
    while (it.next()) |arg| {
        if (try harness.parseCommon(arg, &common)) continue;
        if (std.mem.startsWith(u8, arg, "--cells=")) {
            cells = try std.fmt.parseInt(usize, arg["--cells=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--edges=")) {
            edges = try std.fmt.parseInt(usize, arg["--edges=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seeds=")) {
            seeds = try std.fmt.parseInt(usize, arg["--seeds=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            harness.out(
                \\multihop — 3-hop traversal latency over a real hypergraph
                \\
                \\  --cells=N    MemCells in the store (default {d})
                \\  --edges=N    hyperedges to build (default {d})
                \\  --seeds=N    seeds traversed (default {d})
                \\  --scale=F    multiply the defaults; --quick is 0.1
                \\  --seed=N     PRNG seed for the graph
                \\
            , .{ DEFAULT_CELLS, DEFAULT_EDGES, DEFAULT_SEEDS });
            return;
        } else {
            harness.out("multihop: unknown argument {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }

    const n_cells = harness.scaled(cells orelse DEFAULT_CELLS, common);
    const n_edges = harness.scaled(edges orelse DEFAULT_EDGES, common);
    const n_seeds = @max(harness.scaled(seeds orelse DEFAULT_SEEDS, common), 1);

    harness.progress("multihop: building {d} cells / {d} edges...\n", .{ n_cells, n_edges });
    const built = try buildGraph(alloc, @max(n_cells, 2), n_edges, common.seed);
    defer built.store.deinit();
    defer built.g.deinit(alloc);

    harness.progress("multihop: traversing {d} seeds x {d} hops...\n", .{ n_seeds, HOPS });
    var res = try traverse(alloc, built.store, built.g.ids, n_seeds);
    defer res.per_seed.deinit(alloc);

    const p95_ms = res.per_seed.p95Ns() / 1e6;

    var j = harness.Json.init(alloc);
    defer j.deinit();

    try harness.emitEnvelope(&j, .{
        .benchmark = "multihop",
        .metric = "three_hop_traversal_p95_latency",
        .target = "< 5ms for 1K seeds (3 hops)",
        .target_value = TARGET_MS,
        .target_comparison = "<",
        .unit = "ms",
        .measured = p95_ms,
        .measured_at_N = @intCast(n_seeds),
        .seed = common.seed,
        .notes = "P95 of per-seed Store.multiHopScored latency, each of the " ++
            "1,000 seeds traversed independently at 3 hops with decay 0.5 " ++
            "and confidence threshold 0.3 over an unfiltered edge set. " ++
            "measured_at_N is the seed count. The batched reading — all " ++
            "seeds in one call — is reported beside it because the " ++
            "constitution's 'for 1K seeds' admits both readings.",
    });

    try j.key("hops");
    try j.int(HOPS);
    try j.key("decay");
    try j.float(0.5);
    try j.key("confidence_threshold");
    try j.float(0.3);
    try j.key("seeds_timed");
    try j.int(@as(u64, @intCast(n_seeds)));

    try j.key("graph");
    try j.beginObject();
    try j.key("cells");
    try j.int(@as(u64, @intCast(built.store.cellCount())));
    try j.key("edges_added");
    try j.int(@as(u64, @intCast(built.g.edges_added)));
    try j.key("edge_errors");
    try j.int(@as(u64, @intCast(built.g.edge_errors)));
    try j.key("edges_in_graph");
    try j.int(@as(u64, @intCast(built.store.hyperedgeCount())));
    try j.key("avg_edge_degree");
    try j.float(built.g.avgDegree());
    try j.key("max_edge_nodes");
    try j.int(@as(u64, @intCast(built.g.degree_max)));
    try j.key("build_ms");
    try j.float(built.g.build_ms);
    try j.key("storage");
    try j.str("in-memory (data_dir=null): no WAL fsync on the build path");
    try j.endObject();

    try j.key("per_seed_latency_ms");
    try j.beginObject();
    try j.key("p50");
    try j.float(res.per_seed.p50Ns() / 1e6);
    try j.key("p95");
    try j.float(p95_ms);
    try j.key("p99");
    try j.float(res.per_seed.p99Ns() / 1e6);
    try j.key("max");
    try j.float(res.per_seed.maxNs() / 1e6);
    try j.key("mean");
    try j.float(res.per_seed.meanNs() / 1e6);
    try j.key("nodes_reached_mean");
    try j.float(res.reached_mean);
    try j.key("max_hop_depth_reached");
    try j.int(res.max_hop_reached);
    try j.endObject();

    try j.key("per_seed_latency_ns");
    try res.per_seed.writeJson(&j);

    try j.key("batched_all_seeds_one_call");
    try j.beginObject();
    try j.key("seeds");
    try j.int(@as(u64, @intCast(n_seeds)));
    try j.key("total_ms");
    try j.float(@as(f64, @floatFromInt(res.batched_ns)) / 1e6);
    try j.key("per_seed_amortised_ms");
    try j.float(@as(f64, @floatFromInt(res.batched_ns)) / 1e6 / @as(f64, @floatFromInt(n_seeds)));
    try j.key("nodes_reached");
    try j.int(@as(u64, @intCast(res.batched_reached)));
    try j.key("note");
    try j.str("The second reading of 'for 1K seeds': one traversal call " ++
        "seeded with all 1,000 nodes. Amortised per seed is much cheaper " ++
        "than a per-seed call because the visited set and the frontier " ++
        "are allocated once.");
    try j.endObject();

    try j.key("constitutional_seed_count");
    try j.int(CONSTITUTION_SEEDS);
    try j.key("measured_at_constitutional_seed_count");
    try j.boolean(n_seeds >= CONSTITUTION_SEEDS);
    try j.key("dce_checksum");
    try j.int(sink);
    try j.endObject();

    try harness.finish(alloc, &j);
}

test "multihop: a 3-hop traversal from a real edge reaches further than one hop" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = true });
    defer store.deinit();

    const ids = try alloc.alloc(u64, 4);
    defer alloc.free(ids);
    for (0..4) |i| {
        ids[i] = store.addRaw(@enumFromInt(@as(u8, @intCast(i % 3))), "episode", "a|b|c", 1, 0.5) catch return;
    }
    // A chain: 0-1, 1-2, 2-3. Three hops must reach node 3 from node 0.
    const pairs = [_][2]u64{ .{ ids[0], ids[1] }, .{ ids[1], ids[2] }, .{ ids[2], ids[3] } };
    for (pairs) |p| {
        const nodes = [_]u64{ p[0], p[1] };
        _ = try store.addHyperedge(.{
            .id = 0,
            .edge_type = .associative,
            .nodes = &nodes,
            .weight = 0.9,
            .source_weights = .{ 0.34, 0.33, 0.33 },
            .confidence = 0.9,
            .created_at = 0,
            .metadata = null,
        });
    }

    const seed = [_]mem3.HyMem.ScoredNode{.{ .id = ids[0], .score = 1.0, .hops = 0 }};
    const out = try store.multiHopScored(alloc, &seed, 3, 0.9, 0.3, null);
    defer alloc.free(out);

    var saw_ids3 = false;
    for (out) |node| {
        if (node.id == ids[3]) saw_ids3 = true;
    }
    try std.testing.expect(saw_ids3);

    // One hop must NOT reach it — otherwise the "3 hops" number would
    // be measuring a graph that is already flat.
    const one_hop = try store.multiHopScored(alloc, &seed, 1, 0.9, 0.3, null);
    defer alloc.free(one_hop);
    var reached_in_one = false;
    for (one_hop) |node| {
        if (node.id == ids[3]) reached_in_one = true;
    }
    try std.testing.expect(!reached_in_one);
}

test "multihop: a seed with no edges returns only itself, not an error" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();
    const id = try store.addRaw(.matter, "lonely", "a|b|c", 1, 0.5);

    const seed = [_]mem3.HyMem.ScoredNode{.{ .id = id, .score = 1.0, .hops = 0 }};
    const out = try store.multiHopScored(alloc, &seed, 3, 0.5, 0.3, null);
    defer alloc.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(id, out[0].id);
}