//! Constitutional target: **memory footprint of 100K MemCells < 500 MB RSS**.
//!
//! (`.specify/memory/constitution.md`, "Performance Standards", row 6.)
//!
//! ## What is actually measured
//!
//! Peak RSS (`getrusage` `ru_maxrss`) sampled across the whole run:
//! before the Store exists, right after `Store.init`, and every
//! `--sample-every` inserts thereafter. Peak rather than current is the
//! right number for a footprint budget — a transient spike inside one
//! insert is memory the process did need at some point.
//!
//! ## The breakdown is accounting, not estimation
//!
//! The components reported next to the total are exact counts measured
//! from the live objects, not heuristics:
//!
//!   * vector bytes  — `hnsw.count * dim * sizeof(f32)`, exact.
//!   * edge id bytes — the number of neighbour entries actually stored,
//!     times `sizeof(u64)`, exact. The per-list allocator overhead on
//!     top of that is *not* estimated; it is left inside the
//!     unattributed remainder, where an estimate would only flatter
//!     the breakdown.
//!   * WAL bytes     — `stat` on the WAL file.
//!   * remainder     — MemCells, the strings they own, the id->cell
//!     hashmap, goal associations, hypergraph, and allocator
//!     bookkeeping. Stated as a number so the reader can see how much
//!     of the total is *not* accounted for by the index.
//!
//! ## Default scale and honest cost
//!
//! Default 15,000 cells in memory (`data_dir = null`). At the ~0.5 ms
//! per `addRaw` this path costs, that is roughly 8 s. The full
//! constitutional 100,000 cells takes roughly a minute on an M1-class
//! machine. `--cells=` and `--durable` change the shape of the run;
//! `measured_at_N` always records the scale actually used, and a
//! projection to 100K lives in its own `projection` object.

const std = @import("std");
const mem3 = @import("mem3");
const harness = @import("harness.zig");

const Allocator = std.mem.Allocator;

const TARGET_MB: f64 = 500.0;
const CONSTITUTION_N: u64 = 100_000;
const DIM: u16 = 384;
const DEFAULT_CELLS: usize = 15_000;

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

const Sample = struct {
    cells: usize,
    rss_kb: u64,
};

/// Counts the bytes the store has asked for and not yet given back.
///
/// RSS (`ru_maxrss`) is the number the target is written in, but on a loaded,
/// memory-pressured host macOS compresses and purges pages, so the same build
/// reads anywhere from 0.4 GB to 2.7 GB at 100k cells run to run. This count
/// is deterministic: it is the sum of live allocation request sizes, so it
/// excludes allocator metadata, size-class rounding and fragmentation (all of
/// which RSS includes) and is a lower bound on what the process holds.
const CountingAllocator = struct {
    backing: Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn grow(self: *CountingAllocator, by: usize) void {
        self.live += by;
        if (self.live > self.peak) self.peak = self.live;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.grow(len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ra)) return false;
        self.live -= memory.len;
        self.grow(new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.live -= memory.len;
        self.grow(new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
        self.live -= memory.len;
    }
};

const Footprint = struct {
    samples: []Sample,
    baseline_kb: u64,
    after_init_kb: u64,
    final_kb: u64,
    cells: usize,
    write_errors: usize,
    hnsw_nodes: usize,
    hnsw_edges: usize,
    hnsw_neighbor_lists: usize,
    hyperedges: usize,
    wal_bytes: u64,
    cells_by_source: [3]usize,
    vector_stride_bytes: usize,
    live_bytes: usize,
    live_peak_bytes: usize,

    fn deinit(self: Footprint, alloc: Allocator) void {
        alloc.free(self.samples);
    }

    fn deltaKb(self: Footprint) i64 {
        return @as(i64, @intCast(self.final_kb)) - @as(i64, @intCast(self.baseline_kb));
    }

    /// Exact vector payload held by the index.
    fn vectorBytes(self: Footprint) f64 {
        return @as(f64, @floatFromInt(self.hnsw_nodes)) * @as(f64, @floatFromInt(self.vector_stride_bytes));
    }

    /// Exact neighbour-id payload held by the index.
    fn edgeIdBytes(self: Footprint) f64 {
        return @as(f64, @floatFromInt(self.hnsw_edges)) * 8.0;
    }
};

fn measure(
    alloc: Allocator,
    cells: usize,
    sample_every: usize,
    scratch: harness.Scratch,
    durable: bool,
    int8: bool,
) !Footprint {
    var samples: std.ArrayList(Sample) = .empty;
    errdefer samples.deinit(alloc);

    const baseline = harness.peakRssKb() orelse 0;
    try samples.append(alloc, .{ .cells = 0, .rss_kb = baseline });

    var counted = CountingAllocator{ .backing = alloc };
    const store = try mem3.Store.init(counted.allocator(), .{
        .data_dir = if (durable) scratch.path else null,
        .seed_default_goals = true,
        .vector_storage = if (int8) .int8 else .f32,
    });
    defer store.deinit();

    const after_init = harness.peakRssKb() orelse 0;
    try samples.append(alloc, .{ .cells = 0, .rss_kb = after_init });

    var written: usize = 0;
    var failed: usize = 0;
    for (0..cells) |i| {
        _ = store.addRaw(
            @enumFromInt(@as(u8, @intCast(i % 3))),
            EPISODE_TEMPLATES[i % EPISODE_TEMPLATES.len],
            CONST_FACTS,
            1,
            0.6,
        ) catch {
            failed += 1;
            continue;
        };
        written += 1;
        if (sample_every > 0 and written % sample_every == 0) {
            try samples.append(alloc, .{
                .cells = written,
                .rss_kb = harness.peakRssKb() orelse 0,
            });
        }
    }

    const final_kb = harness.peakRssKb() orelse 0;
    try samples.append(alloc, .{ .cells = written, .rss_kb = final_kb });

    // Exact structural counts, read back from the live objects.
    var edges: usize = 0;
    var lists: usize = 0;
    var it = store.hnsw.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr.*;
        for (node.neighbors) |n| {
            if (n.items.len > 0) lists += 1;
            edges += n.items.len;
        }
    }

    var wal_bytes: u64 = 0;
    if (durable) {
        const wal = try scratch.pathZ(alloc, "mem3.wal");
        defer alloc.free(wal);
        wal_bytes = harness.fileSizeBytes(wal) orelse 0;
    }

    return .{
        .samples = try samples.toOwnedSlice(alloc),
        .baseline_kb = baseline,
        .after_init_kb = after_init,
        .final_kb = final_kb,
        .cells = written,
        .write_errors = failed,
        .hnsw_nodes = store.hnsw.count,
        .hnsw_edges = edges,
        .hnsw_neighbor_lists = lists,
        .hyperedges = store.hyperedgeCount(),
        .wal_bytes = wal_bytes,
        .cells_by_source = .{
            store.cellCountBySource(.matter),
            store.cellCountBySource(.form),
            store.cellCountBySource(.spirit),
        },
        .vector_stride_bytes = store.hnsw.vec_stride,
        .live_bytes = counted.live,
        .live_peak_bytes = counted.peak,
    };
}

pub fn run(alloc: Allocator, init: std.process.Init.Minimal) !void {
    var common = harness.CommonArgs{};
    var cells: ?usize = null;
    var sample_every: ?usize = null;
    var durable = false;
    var int8 = false;

    var it = harness.argIterator(init);
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--durable")) {
            durable = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--int8")) {
            int8 = true;
            continue;
        }
        if (try harness.parseCommon(arg, &common)) continue;
        if (std.mem.startsWith(u8, arg, "--cells=")) {
            cells = try std.fmt.parseInt(usize, arg["--cells=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--sample-every=")) {
            sample_every = try std.fmt.parseInt(usize, arg["--sample-every=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            harness.out(
                \\footprint — peak RSS for a loaded MemCell store
                \\
                \\  --cells=N         cells to insert (default {d})
                \\  --sample-every=N  RSS sample interval in cells (default cells/10)
                \\  --int8            store HNSW vectors as int8 (1 B/dim instead of 4)
                \\  --durable         keep the WAL, and account for its bytes
                \\  --data-dir=P      scratch dir (default: a fresh /tmp dir)
                \\  --scale=F         multiply the defaults; --quick is 0.1
                \\
                , .{DEFAULT_CELLS});
            return;
        } else {
            harness.out("footprint: unknown argument {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }

    const n_cells = harness.scaled(cells orelse DEFAULT_CELLS, common);
    const n_sample = @max(harness.scaled(sample_every orelse @max(n_cells / 10, 1), common), 1);

    const scratch = try harness.Scratch.init(alloc, common.data_dir, "footprint");
    defer scratch.deinit(alloc);

    harness.progress("footprint: inserting {d} cells (durable={})...\n", .{ n_cells, durable });
    var fp = try measure(alloc, n_cells, n_sample, scratch, durable, int8);
    defer fp.deinit(alloc);

    const mb = @as(f64, @floatFromInt(fp.final_kb)) / 1024.0;
    const per_cell = if (fp.cells == 0)
        0.0
    else
        (@as(f64, @floatFromInt(fp.deltaKb())) * 1024.0) / @as(f64, @floatFromInt(fp.cells));

    var j = harness.Json.init(alloc);
    defer j.deinit();

    try harness.emitEnvelope(&j, .{
        .benchmark = "footprint",
        .metric = "peak_rss_mb",
        .target = "< 500MB RSS for 100K MemCells",
        .target_value = TARGET_MB,
        .target_comparison = "<",
        .unit = "MB",
        .measured = mb,
        .measured_at_N = @intCast(fp.cells),
        .seed = common.seed,
        .notes = "Peak RSS (getrusage ru_maxrss, high-water mark for the " ++
            "whole process) after inserting N MemCells through Store.addRaw. " ++
            "The baseline sample is taken before the Store is created, so " ++
            "per_cell_bytes below is the marginal cost of a cell, not the " ++
            "process's fixed overhead. measured_at_N is the cell count this " ++
            "run actually filled; the constitutional scale is 100K.",
    });

    try j.key("storage");
    try j.str(if (durable) "durable (WAL retained)" else "in-memory (data_dir=null)");
    try j.key("cells");
    try j.int(@as(u64, @intCast(fp.cells)));
    try j.key("write_errors");
    try j.int(@as(u64, @intCast(fp.write_errors)));
    try j.key("embed_dim");
    try j.int(DIM);
    try j.key("vector_storage");
    try j.str(if (int8) "int8 (1 byte/dim)" else "f32 (4 bytes/dim)");

    // An RSS number without its conditions is not a measurement, it is a
    // rumour. Everything a reader needs in order to decide whether this
    // figure transfers to their own run is stated here, next to the number
    // it qualifies.
    try j.key("conditions");
    try j.beginObject();
    try j.key("embedder");
    try j.str("built-in hashed lexer (BuildOptions.embedder_cmd = null). No " ++
        "external embedder process is spawned, so no model weights are " ++
        "resident. These figures do NOT bound --embedder-cmd runs.");
    try j.key("embed_dim");
    try j.int(DIM);
    try j.key("index");
    try j.str("built incrementally: every addRaw inserts into the live HNSW, " ++
        "so the graph is fully linked at the end of the run. No separate " ++
        "build phase and no rebuild pass.");
    try j.key("consolidation");
    try j.str("never runs. This benchmark only calls Store.addRaw, so there " ++
        "are no abstracts, no consolidation working set, and no decay " ++
        "sweep. A long run with consolidation resident will be larger.");
    try j.key("wal");
    try j.str(if (durable)
        "WAL opened and retained uncompacted; no snapshot is taken, so the " ++
            "WAL grows monotonically and nothing is reclaimed."
    else
        "no WAL at all (data_dir=null), so the WAL contributes 0 bytes to " ++
            "both RSS and disk.");
    try j.key("allocator");
    try j.str("std.heap.DebugAllocator(.{ .thread_safe = true }) — byte-for-byte " ++
        "the allocator the shipped mem3 binary uses (src/main.zig), so this " ++
        "is not a bench-harness artifact, but it does carry per-allocation " ++
        "debug metadata and caches freed pages rather than returning them.");
    try j.key("what_this_number_is");
    try j.str("Whole-process peak RSS (getrusage ru_maxrss) for a store " ++
        "filled through addRaw and still in memory. It is NOT the on-disk " ++
        "footprint, and NOT the steady-state RSS of a long-running daemon " ++
        "that also holds abstracts and a consolidation working set.");
    try j.key("measurement_method");
    try j.str("In-process ru_maxrss, cross-checked against an external " ++
        "observer: /usr/bin/time -l ./mem3-bench footprint --cells=N. The " ++
        "external figure is the one to trust under memory pressure — see " ++
        "the caveat on rss_measurement_caveat below.");
    try j.key("rss_measurement_caveat");
    try j.str("ru_maxrss is a high-water mark, and on a memory-pressured host " ++
        "macOS purges and compresses pages, which makes in-process RSS read " ++
        "LOW (observed: 71.7 MB reported for a store whose vectors alone are " ++
        "73.2 MB, which is impossible). Under load the in-process and " ++
        "external readings diverged by up to 4x. On an idle host the two " ++
        "agree exactly and repeated runs are bit-identical. Report the " ++
        "external figure, and treat any single RSS number from a busy host " ++
        "as unverified.");
    try j.endObject();

    try j.key("rss");
    try j.beginObject();
    try j.key("baseline_kb");
    try j.int(fp.baseline_kb);
    try j.key("after_store_init_kb");
    try j.int(fp.after_init_kb);
    try j.key("peak_kb");
    try j.int(fp.final_kb);
    try j.key("peak_mb");
    try j.float(mb);
    try j.key("delta_kb");
    try j.int(fp.deltaKb());
    try j.key("delta_mb");
    try j.float(@as(f64, @floatFromInt(fp.deltaKb())) / 1024.0);
    try j.key("fixed_overhead_mb");
    try j.float(@as(f64, @floatFromInt(fp.baseline_kb)) / 1024.0);
    try j.key("per_cell_bytes");
    try j.float(per_cell);
    try j.endObject();

    try j.key("rss_growth");
    try j.beginArray();
    for (fp.samples) |s| {
        try j.beginObject();
        try j.key("cells");
        try j.int(@as(u64, @intCast(s.cells)));
        try j.key("peak_rss_kb");
        try j.int(s.rss_kb);
        try j.endObject();
    }
    try j.endArray();

    // --- per-cell accounting -------------------------------------------
    const accounted = fp.vectorBytes() + fp.edgeIdBytes() + @as(f64, @floatFromInt(fp.wal_bytes));
    const total_delta = @as(f64, @floatFromInt(fp.deltaKb())) * 1024.0;
    const remainder = total_delta - accounted;

    try j.key("per_cell_bytes_breakdown");
    try j.beginObject();
    try j.key("method");
    try j.str("Exact counts read back from the live objects, not estimates. " ++
        "Per-list allocator overhead is deliberately left in the remainder " ++
        "rather than guessed at.");
    try j.key("total_delta_bytes");
    try j.float(total_delta);
    try j.key("index_vector_bytes");
    try j.float(fp.vectorBytes());
    try j.key("index_vector_bytes_per_cell");
    try j.float(if (fp.cells == 0) 0 else fp.vectorBytes() / @as(f64, @floatFromInt(fp.cells)));
    try j.key("index_edge_id_bytes");
    try j.float(fp.edgeIdBytes());
    try j.key("index_edge_id_bytes_per_cell");
    try j.float(if (fp.cells == 0) 0 else fp.edgeIdBytes() / @as(f64, @floatFromInt(fp.cells)));
    try j.key("wal_bytes");
    try j.int(fp.wal_bytes);
    try j.key("wal_bytes_per_cell");
    try j.float(if (fp.cells == 0) 0 else @as(f64, @floatFromInt(fp.wal_bytes)) / @as(f64, @floatFromInt(fp.cells)));
    // Deterministic counterpart to the RSS remainder below: live allocation
    // request bytes, read from the counting allocator. See CountingAllocator.
    const nc: f64 = if (fp.cells == 0) 1 else @floatFromInt(fp.cells);
    try j.key("live_requested_bytes_per_cell");
    try j.float(@as(f64, @floatFromInt(fp.live_bytes)) / nc);
    try j.key("live_peak_requested_bytes_per_cell");
    try j.float(@as(f64, @floatFromInt(fp.live_peak_bytes)) / nc);
    try j.key("live_requested_other_bytes_per_cell");
    try j.float((@as(f64, @floatFromInt(fp.live_bytes)) - fp.vectorBytes() - fp.edgeIdBytes()) / nc);
    try j.key("unattributed_bytes");
    try j.float(remainder);
    try j.key("unattributed_bytes_per_cell");
    try j.float(if (fp.cells == 0) 0 else remainder / @as(f64, @floatFromInt(fp.cells)));
    try j.key("unattributed_share_of_delta");
    try j.float(if (total_delta <= 0) 0 else remainder / total_delta);
    try j.key("unattributed_contains");
    try j.str("MemCell structs, the episode/fact strings they own, the " ++
        "id->cell hashmap, goal associations, hypergraph, and allocator " ++
        "bookkeeping (per-list headers, growth slack).");
    try j.key("hnsw_nodes");
    try j.int(@as(u64, @intCast(fp.hnsw_nodes)));
    try j.key("hnsw_neighbor_entries");
    try j.int(@as(u64, @intCast(fp.hnsw_edges)));
    try j.key("hnsw_neighbor_lists");
    try j.int(@as(u64, @intCast(fp.hnsw_neighbor_lists)));
    try j.key("hyperedges");
    try j.int(@as(u64, @intCast(fp.hyperedges)));
    try j.key("cells_by_source");
    try j.beginObject();
    try j.key("matter");
    try j.int(@as(u64, @intCast(fp.cells_by_source[0])));
    try j.key("form");
    try j.int(@as(u64, @intCast(fp.cells_by_source[1])));
    try j.key("spirit");
    try j.int(@as(u64, @intCast(fp.cells_by_source[2])));
    try j.endObject();
    try j.endObject();

    // --- projection -----------------------------------------------------
    if (fp.cells < CONSTITUTION_N) {
        const projected_kb = @as(f64, @floatFromInt(fp.baseline_kb)) +
            per_cell * @as(f64, @floatFromInt(CONSTITUTION_N)) / 1024.0;
        try harness.emitProjection(
            &j,
            "projected_peak_rss_mb_at_100k",
            CONSTITUTION_N,
            projected_kb / 1024.0,
            "fixed process baseline (measured) plus the measured marginal " ++
                "bytes-per-cell times 100,000",
            @intCast(fp.cells),
            "Not a measurement. The per-cell cost itself grows with corpus " ++
                "size in this implementation (HNSW neighbour lists grow with " ++
                "N), so linear extrapolation is optimistic. The rss_growth " ++
                "table above is the measured evidence either way. Run with " ++
                "--cells=100000 to measure it.",
        );
    }

    try j.key("constitutional_N");
    try j.int(CONSTITUTION_N);
    try j.key("measured_at_constitutional_scale");
    try j.boolean(fp.cells >= CONSTITUTION_N);
    try j.endObject();

    try harness.finish(alloc, &j);
}

// ## KNOWN GAP: the two tests at the bottom of this file are not collected
//
// `zig build test` runs 451 tests and none of them are these two.
// `zig test` collects test blocks from files reachable by `@import` from
// the root source file, exactly one layer deep, and only what a root
// *names directly*. `bench/main.zig` is a dispatcher with no comptime
// block, and `tests/main.zig` cannot reach `../bench/` — importing it
// fails with "import of file outside module path".
//
// Exposing this file to the tests-rooted binary as a named module does
// not work either: a *module* import is not a *file* import, and a
// module's test blocks are not collected. That was tried and reverted;
// a green build with the module wired in is worse than an honest gap,
// because it reads as coverage that does not exist.
//
// To actually run them: `/usr/bin/time -l ./zig-out/bin/mem3-bench
// footprint --cells=300`. Closing this properly means restructuring
// `bench/` into the library module, which is a larger change than the
// two assertions are worth.

test "footprint: RSS grows monotonically and the growth table records it" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const scratch = try harness.Scratch.init(alloc, null, "footprint-test");
    defer scratch.deinit(alloc);

    const fp = try measure(alloc, 300, 100, scratch, false, false);
    defer fp.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 300), fp.cells);
    try std.testing.expect(fp.final_kb > fp.baseline_kb);
    // getrusage reports a high-water mark, so the samples never fall.
    for (fp.samples) |s| try std.testing.expect(s.rss_kb >= fp.baseline_kb);
}

test "footprint: vector bytes are exactly count * dim * 4" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const scratch = try harness.Scratch.init(alloc, null, "footprint-accounting");
    defer scratch.deinit(alloc);

    const fp = try measure(alloc, 64, 0, scratch, false, false);
    defer fp.deinit(alloc);

    try std.testing.expectEqual(@as(f64, 64.0 * @as(f64, DIM) * 4.0), fp.vectorBytes());
    try std.testing.expect(fp.hnsw_nodes >= 64);
}
test "footprint: int8 vectors are exactly count * dim bytes, and the live count covers them" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const scratch = try harness.Scratch.init(alloc, null, "footprint-accounting-i8");
    defer scratch.deinit(alloc);

    const fp = try measure(alloc, 64, 0, scratch, false, true);
    defer fp.deinit(alloc);

    try std.testing.expectEqual(@as(f64, 64.0 * @as(f64, DIM)), fp.vectorBytes());
    // The allocator count is a lower bound on the store's footprint: it
    // must at least hold the vectors and the neighbour ids it was asked for.
    try std.testing.expect(@as(f64, @floatFromInt(fp.live_bytes)) >= fp.vectorBytes() + fp.edgeIdBytes());
    try std.testing.expect(fp.live_peak_bytes >= fp.live_bytes);
}
