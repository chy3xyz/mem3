//! Constitutional target: **MemCell write throughput >= 1,750/sec (sustained, worst window)**.
//!
//! Amended 2026-10-15 from 10,000; see
//! `docs/constitution-amendments/2026-10-15-write-throughput-target.md`. The
//! target tracks `worst_window_rate`, not the overall mean — see below.
//!
//! (`.specify/memory/constitution.md`, "Performance Standards", row 1.)
//!
//! ## What is actually measured
//!
//! `Store.addRaw` — the same call `mem3 add` makes — is timed one write
//! at a time, in two configurations:
//!
//!   * `durable`  : `data_dir` set, so every cell is encoded, journalled
//!                  to the WAL and indexed. `WAL.append` fsyncs on every
//!                  record (`src/storage/wal.zig`), so one `fsync(2)`
//!                  per cell is included. This is the shipped path.
//!   * `memory`   : `data_dir = null`, i.e. no WAL and no snapshot.
//!                  The difference between the two is where the time
//!                  goes, and hiding it would make the durable number
//!                  unreadable.
//!
//! Both modes run the *same* number of writes, because per-write cost
//! grows with index depth; comparing a 20k-cell run against a 5k-cell
//! run would manufacture a speedup.
//!
//! "Sustained" is reported three ways, all measured:
//!   * `overall_rate`   — total writes / total wall time.
//!   * `worst_window`   — the slowest fixed-size window. This is the
//!                       number that cannot be inflated by a fast start.
//!   * per-write latency percentiles (P50/P95/P99/max) for the shape.
//!
//! ## Default scale and honest cost
//!
//! Default 5,000 writes per mode, windows of 500. At the ~0.5 ms/write
//! this code path currently costs, that is roughly 3 s per mode. The
//! full constitutional scale (100,000 writes) takes roughly one minute
//! per mode on an M1-class machine. `--cells=`, `--window=` and
//! `--scale=` raise or lower this; the JSON always reports the N it ran.
//!
//! The headline `measured` value is the **durable** rate. The in-memory
//! rate is reported beside it as a diagnostic, never as the result.

const std = @import("std");
const mem3 = @import("mem3");
const harness = @import("harness.zig");

const Allocator = std.mem.Allocator;

/// Constitution v1.2.0: ">= 1.75K MemCells/sec (sustained, durable path; worst window)".
///
/// The verdict is computed against the **worst window**, not the mean: the
/// mean across runs sits ~20% above the slowest run, and a mean-only rule
/// would clear a target that a sustained writer does not actually sustain.
const TARGET_RATE: f64 = 1_750.0;

const DEFAULT_CELLS: usize = 5_000;
const DEFAULT_WINDOW: usize = 500;

const Mode = enum {
    durable,
    memory,

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .durable => "durable",
            .memory => "memory",
        };
    }
};

/// One configuration's measurements.
const ModeResult = struct {
    mode: Mode,
    cells: usize,
    /// Writes that returned an error. Counted, never silently dropped:
    /// a throughput number over a partial run is not a throughput
    /// number.
    errors: usize,
    wall_ns: u64,
    window_rates: []f64,
    lat: harness.Latencies,
    /// Bytes the WAL holds after the run (0 in memory mode).
    wal_bytes: u64,

    fn deinit(self: ModeResult, alloc: Allocator) void {
        alloc.free(self.window_rates);
        self.lat.deinit(alloc);
    }

    fn overallRate(self: ModeResult) f64 {
        if (self.wall_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.cells)) /
            (@as(f64, @floatFromInt(self.wall_ns)) / 1e9);
    }

    /// The slowest window: the rate a sustained writer would actually
    /// have to keep up with once the index has grown.
    fn worstWindowRate(self: ModeResult) ?f64 {
        if (self.window_rates.len == 0) return null;
        var worst: f64 = self.window_rates[0];
        for (self.window_rates) |r| worst = @min(worst, r);
        return worst;
    }
};

/// Synthetic episode text. Varying the text keeps the embedder and the
/// serializer doing real work — a fixed 12-byte string would make the
/// measurement a benchmark of memcpy.
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

/// Dead-code-elimination guard, reported as a checksum so a reader can
/// tell a run that actually wrote cells from one that optimised them
/// away.
var sink: u64 = 0;

fn makeEpisodes(alloc: Allocator, n: usize, seed: u64) ![][]const u8 {
    var rng = harness.Rng.init(seed);
    const out = try alloc.alloc([]const u8, n);
    errdefer alloc.free(out);
    for (out, 0..) |*slot, i| {
        const tpl = EPISODE_TEMPLATES[i % EPISODE_TEMPLATES.len];
        slot.* = try std.fmt.allocPrint(alloc, "{s} [cycle {d}]", .{ tpl, rng.below(100_000) });
    }
    return out;
}

fn freeEpisodes(alloc: Allocator, eps: [][]const u8) void {
    for (eps) |e| alloc.free(e);
    alloc.free(eps);
}

fn measure(
    alloc: Allocator,
    mode: Mode,
    episodes: [][]const u8,
    cells: usize,
    window: usize,
    scratch: harness.Scratch,
) !ModeResult {
    const store = try mem3.Store.init(alloc, .{
        .data_dir = if (mode == .durable) scratch.path else null,
        .seed_default_goals = true,
    });
    defer store.deinit();

    const samples = try alloc.alloc(u64, cells);
    defer alloc.free(samples);

    var rates: std.ArrayList(f64) = .empty;
    defer rates.deinit(alloc);

    var written: usize = 0;
    var failed: usize = 0;
    var in_window: usize = 0;
    var window_start: u64 = harness.clockNs();
    const t0 = window_start;

    while (written < cells) : (written += 1) {
        const i = written;
        const one = harness.clockNs();
        const id = store.addRaw(
            @enumFromInt(@as(u8, @intCast(i % 3))),
            episodes[i % episodes.len],
            CONST_FACTS,
            1,
            0.6,
        ) catch {
            failed += 1;
            continue;
        };
        samples[i] = harness.sinceNs(one);
        sink +%= id;
        in_window += 1;

        if (in_window >= window and written + 1 < cells) {
            const elapsed = harness.sinceNs(window_start);
            if (elapsed > 0) {
                try rates.append(alloc, @as(f64, @floatFromInt(in_window)) /
                    (@as(f64, @floatFromInt(elapsed)) / 1e9));
            }
            in_window = 0;
            window_start = harness.clockNs();
        }
    }
    // Trailing partial window — measured on the same basis as the rest,
    // never dropped.
    {
        const elapsed = harness.sinceNs(window_start);
        if (elapsed > 0 and in_window > 0) {
            try rates.append(alloc, @as(f64, @floatFromInt(in_window)) /
                (@as(f64, @floatFromInt(elapsed)) / 1e9));
        }
    }

    const wall_ns = harness.sinceNs(t0);
    var wal_bytes: u64 = 0;
    if (mode == .durable) {
        const wal_path = try scratch.pathZ(alloc, "mem3.wal");
        defer alloc.free(wal_path);
        wal_bytes = harness.fileSizeBytes(wal_path) orelse 0;
    }

    const ok = cells - failed;
    return .{
        .mode = mode,
        .cells = ok,
        .errors = failed,
        .wall_ns = wall_ns,
        .window_rates = try rates.toOwnedSlice(alloc),
        .lat = try harness.Latencies.fromSlice(alloc, samples[0..ok]),
        .wal_bytes = wal_bytes,
    };
}

/// Isolated `WAL.append` cost, so the durable number above can be read
/// as "encode + index + write + fsync" rather than as an unexplained
/// slow number.
fn measureWalComponent(alloc: Allocator, records: usize, scratch: harness.Scratch) !harness.Latencies {
    const wal_path = try scratch.pathZ(alloc, "mem3-component.wal");
    defer alloc.free(wal_path);
    _ = std.c.unlink(wal_path.ptr);

    var wal = try mem3.WAL.init(alloc, wal_path);
    defer {
        wal.deinit();
        _ = std.c.unlink(wal_path.ptr);
    }
    try wal.open();

    const samples = try alloc.alloc(u64, records);
    defer alloc.free(samples);
    for (0..records) |i| {
        const one = harness.clockNs();
        wal.append(.{
            .record_type = .memcell_insert,
            .payload = CONST_FACTS,
            .timestamp = @as(i64, @intCast(i)),
        }) catch {
            return error.WalAppendFailed;
        };
        samples[i] = harness.sinceNs(one);
        sink +%= i;
    }
    return harness.Latencies.fromSlice(alloc, samples);
}

pub fn run(alloc: Allocator, init: std.process.Init.Minimal) !void {
    var common = harness.CommonArgs{};
    var cells: ?usize = null;
    var window: ?usize = null;

    var it = harness.argIterator(init);
    while (it.next()) |arg| {
        if (try harness.parseCommon(arg, &common)) continue;
        if (std.mem.startsWith(u8, arg, "--cells=")) {
            cells = try std.fmt.parseInt(usize, arg["--cells=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--window=")) {
            window = try std.fmt.parseInt(usize, arg["--window=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            harness.out(
                \\throughput — MemCell write rate, durable and in-memory
                \\
                \\  --cells=N     writes per mode (default {d})
                \\  --window=N    writes per sustained window (default {d})
                \\  --scale=F     multiply the defaults; --quick is 0.1
                \\  --data-dir=P  scratch data dir (default: a fresh /tmp dir)
                \\  --seed=N      PRNG seed for the episode text
                \\
            , .{ DEFAULT_CELLS, DEFAULT_WINDOW });
            return;
        } else {
            harness.out("throughput: unknown argument {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }

    const n_cells = harness.scaled(cells orelse DEFAULT_CELLS, common);
    const n_window = @max(harness.scaled(window orelse DEFAULT_WINDOW, common), 1);

    const scratch = try harness.Scratch.init(alloc, common.data_dir, "throughput");
    defer scratch.deinit(alloc);

    const episodes = try makeEpisodes(alloc, @max(n_cells, 1), common.seed);
    defer freeEpisodes(alloc, episodes);

    harness.progress("throughput: {d} cells/mode, window {d}\n", .{ n_cells, n_window });

    const durable = try measure(alloc, .durable, episodes, n_cells, n_window, scratch);
    defer durable.deinit(alloc);
    harness.progress("throughput: durable {d:.1} cells/sec\n", .{durable.overallRate()});

    const memory = try measure(alloc, .memory, episodes, n_cells, n_window, scratch);
    defer memory.deinit(alloc);
    harness.progress("throughput: memory {d:.1} cells/sec\n", .{memory.overallRate()});

    // The WAL component runs at roughly 1 ms/record, so cap it rather
    // than let it double the benchmark's wall time.
    const wal_records = @max(@min(n_cells, 2_000), 1);
    const wal_lat = try measureWalComponent(alloc, wal_records, scratch);
    defer wal_lat.deinit(alloc);

    const durable_mean = durable.lat.meanNs();
    const memory_mean = memory.lat.meanNs();
    const persistence_cost = durable_mean - memory_mean;
    const share = if (durable_mean > 0) persistence_cost / durable_mean else null;

    var j = harness.Json.init(alloc);
    defer j.deinit();

    try harness.emitEnvelope(&j, .{
        .benchmark = "throughput",
        .metric = "memcell_write_throughput_sustained",
        .target = ">= 1.75K MemCells/sec (sustained, durable path; worst window)",
        .target_value = TARGET_RATE,
        .target_comparison = ">=",
        .unit = "cells/sec",
        // The verdict is the SLOWEST window, not the mean. The mean across
        // runs sits ~20% above the slowest run, so a mean-only rule would
        // clear a target that a sustained writer does not actually sustain —
        // exactly the gap the 2026-10-15 amendment closed. The mean is still
        // emitted, under `modes.durable.overall_rate`.
        .measured = durable.worstWindowRate(),
        .measured_at_N = @intCast(durable.cells),
        .seed = common.seed,
        .notes = "durable path: Store.addRaw with a data_dir, so every write " ++
            "is encoded, WAL-journalled (write+fsync per record) and indexed. " ++
            "Latency percentiles are per single write, in nanoseconds. " ++
            "worst_window_rate is the slowest window of --window writes and is " ++
            "the number a sustained writer must keep up with. `measured` is that " ++
            "same worst window and is what `met_target` judges; the overall " ++
            "mean is under modes.durable.overall_rate.",
    });

    try j.key("modes");
    try j.beginObject();

    try j.key("durable");
    try j.beginObject();
    try j.key("cells");
    try j.int(@as(u64, @intCast(durable.cells)));
    try j.key("errors");
    try j.int(@as(u64, @intCast(durable.errors)));
    try j.key("wall_ms");
    try j.float(harness.nsToMs(durable.wall_ns));
    try j.key("overall_rate");
    try j.float(durable.overallRate());
    try j.key("worst_window_rate");
    try j.optFloat(durable.worstWindowRate());
    try j.key("window_size");
    try j.int(@as(u64, @intCast(n_window)));
    try j.key("windows");
    try j.int(@as(u64, @intCast(durable.window_rates.len)));
    try j.key("window_rates");
    try j.beginArray();
    for (durable.window_rates) |r| try j.float(r);
    try j.endArray();
    try j.key("latency");
    try durable.lat.writeJson(&j);
    try j.key("wal_bytes");
    try j.int(durable.wal_bytes);
    try j.key("wal_bytes_per_cell");
    try j.float(if (durable.cells == 0)
        0
    else
        @as(f64, @floatFromInt(durable.wal_bytes)) / @as(f64, @floatFromInt(durable.cells)));
    try j.endObject();

    try j.key("memory");
    try j.beginObject();
    try j.key("cells");
    try j.int(@as(u64, @intCast(memory.cells)));
    try j.key("errors");
    try j.int(@as(u64, @intCast(memory.errors)));
    try j.key("wall_ms");
    try j.float(harness.nsToMs(memory.wall_ns));
    try j.key("overall_rate");
    try j.float(memory.overallRate());
    try j.key("worst_window_rate");
    try j.optFloat(memory.worstWindowRate());
    try j.key("window_size");
    try j.int(@as(u64, @intCast(n_window)));
    try j.key("windows");
    try j.int(@as(u64, @intCast(memory.window_rates.len)));
    try j.key("window_rates");
    try j.beginArray();
    for (memory.window_rates) |r| try j.float(r);
    try j.endArray();
    try j.key("latency");
    try memory.lat.writeJson(&j);
    try j.key("wal_bytes");
    try j.int(memory.wal_bytes);
    try j.endObject();

    try j.endObject();

    // --- where the time goes ------------------------------------------
    try j.key("cost_attribution");
    try j.beginObject();
    try j.key("method");
    try j.str("mean durable write minus mean in-memory write, on identical " ++
        "input and identical cell count; isolates the persistence cost");
    try j.key("durable_mean_ns_per_write");
    try j.float(durable_mean);
    try j.key("memory_mean_ns_per_write");
    try j.float(memory_mean);
    try j.key("persistence_ns_per_write");
    try j.float(persistence_cost);
    try j.key("persistence_share_of_write");
    try j.optFloat(share);
    try j.key("wal_append_only");
    try j.beginObject();
    try j.key("records");
    try j.int(@as(u64, @intCast(wal_records)));
    try j.key("note");
    try j.str("WAL.append on an empty store: encode + write(2) + fsync(2) per " ++
        "record, with no HNSW work. fsync is per record by design " ++
        "(src/storage/wal.zig).");
    try j.key("latency");
    try wal_lat.writeJson(&j);
    try j.endObject();
    try j.endObject();

    try j.key("dce_checksum");
    try j.int(sink);
    try j.endObject();

    try harness.finish(alloc, &j);
}

test "throughput: sustained rate is total writes over total wall time" {
    // The rate must come from the whole run, not from a fast window.
    var rates = [_]f64{ 1000.0, 2000.0, 3000.0 };
    const r = ModeResult{
        .mode = .memory,
        .cells = 1000,
        .errors = 0,
        .wall_ns = 2 * 1_000_000_000,
        .window_rates = rates[0..],
        .lat = .{ .samples = &.{} },
        .wal_bytes = 0,
    };
    try std.testing.expectApproxEqAbs(500.0, r.overallRate(), 1e-9);
    try std.testing.expectApproxEqAbs(1000.0, r.worstWindowRate().?, 1e-9);
}

test "throughput: a run that wrote nothing reports a zero rate, not a division by zero" {
    var none = [_]f64{};
    const r = ModeResult{
        .mode = .memory,
        .cells = 0,
        .errors = 5,
        .wall_ns = 0,
        .window_rates = none[0..],
        .lat = .{ .samples = &.{} },
        .wal_bytes = 0,
    };
    try std.testing.expectEqual(@as(f64, 0), r.overallRate());
    try std.testing.expect(r.worstWindowRate() == null);
}