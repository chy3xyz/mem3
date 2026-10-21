//! HTTP server — minimal HTTP/1.1 over POSIX sockets with in-process store.
//!
//! **Persistence (v0.1.0+)**: writes are journaled to a Write-Ahead Log at
//! `data_dir/mem3.wal`. On startup the WAL is replayed to reconstruct the
//! in-process store. Use `data_dir` to switch storage locations.
//!
//! **Constitution FR-017** endpoints:
//!   - GET  /                            — web UI (htmx + Alpine.js + Tailwind)
//!   - GET  /api/memcells                — list
//!   - GET  /api/memcells/{id}           — single
//!   - POST /api/memcells                — create (WAL-durable)
//!   - GET  /api/goals                   — list
//!   - POST /api/query                   — three-way recall
//!   - GET  /healthz, /metrics           — observability
//!   - POST /api/sync                    — flush WAL to disk

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = std.c;
const builtin = @import("builtin");
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const MemorySource = core.MemorySource;
const ghw = @import("../ghw/mod.zig");
const ghw_goal_tree = @import("../ghw/goal_tree.zig");
const jsonl = @import("../utils/jsonl.zig");
const mem3_store = @import("../store/store.zig");
const RerankContext = @import("../retrieval/reranker.zig").RerankContext;
const memory = @import("../memory/mod.zig");
const retrieval = @import("../retrieval/mod.zig");
/// The CLI parser, for the daemon-flag tests at the bottom of this file.
/// Referenced as a type/module only — its own `test` blocks are not
/// collected here (see the note on that test section).
const cli = @import("../cli.zig");

const wal_mod = @import("../storage/wal.zig");
const signal = @import("../platform/signal.zig");
const logger_mod = @import("../utils/logger.zig");
const Logger = logger_mod.Logger;

const log = std.log.scoped(.mem3_server);

/// Diagnostic logging that is compiled out of tests.
///
/// Zig 0.17 fails a test that writes a log line at ANY level — including
/// `warn` — and `std_options.log_level = .err` does not suppress it. Under
/// `--listen=-` the test runner speaks its protocol over the same pipe, so a
/// stray stderr write desynchronises it, kills the test binary, and
/// `zig build test` still exits 0. Silent failure is worse than no log.
fn diag(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) log.warn(fmt, args);
}

/// Embedded web UI (loaded at compile time via @embedFile).
const WEB_INDEX: []const u8 = @embedFile("web_index.html");

/// Adapter so the shared `jsonl.writeJsonString` helper — written against
/// a stream writer — can target an `std.ArrayList(u8)`. Zig 0.17's
/// unmanaged ArrayList exposes `print(gpa, ...)` but has no `.writer()`.
const ListWriter = struct {
    list: *std.ArrayList(u8),
    gpa: Allocator,

    pub fn writeByte(self: ListWriter, b: u8) !void {
        try self.list.append(self.gpa, b);
    }
    pub fn writeAll(self: ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.gpa, bytes);
    }
    pub fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.list.print(self.gpa, fmt, args);
    }
};

fn nowNs() u128 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    // timespec fields are signed c_long; coerce through i64 to recover non-negative values from MONOTONIC clock.
    const sec_i: i64 = @intCast(ts.sec);
    const nsec_i: i64 = @intCast(ts.nsec);
    return @as(u128, @as(u64, @bitCast(sec_i))) * 1_000_000_000 +
        @as(u128, @as(u64, @bitCast(nsec_i)));
}

/// Unix epoch in seconds (CLOCK_REALTIME). Use this for human-meaningful
/// timestamps (WAL record timestamps, audit logs). Do NOT use for
/// measuring elapsed time — use `nowNs` for that.
fn wallClockSec() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// In-process memory store. Lives for the duration of the server.
/// The daemon uses the single library `Store`, not a private fork.
///
/// This file used to carry its own ~890-line `Store` struct. It was a
/// strict subset of `src/store/store.zig`: no hypergraph, no `multiHop`,
/// no `forget`/`consolidate`, no idempotent `deinit`, and an `init` with
/// no `errdefer` chain at all, so every allocation leaked whenever WAL
/// replay failed. It had drifted far enough to cost a real bug — `POST
/// /api/sync` truncated the WAL without replaying `goal_update` records,
/// permanently destroying goal status, because the fork's replay loop only
/// knew about `goal_create`.
///
/// One implementation is what makes the next bug impossible: there is no
/// second copy to forget to update.
const Store = mem3_store.Store;

/// Number of buckets in the retrieval-latency histogram.
///
/// Sized so that the range an operator can act on — 1µs to 10s —
/// lands in the low quarter of the array. Bucket 23's upper bound is
/// 2^24-1 ≈ 16.8s, so 10s is comfortably inside, and everything above
/// it is headroom: a pathological outlier saturates the last bucket
/// instead of wrapping an index or panicking.
const LATENCY_BUCKET_COUNT: usize = 64;

/// Lower edge of bucket 0, in microseconds.
const LATENCY_BUCKET_MIN_US: u64 = 1;

/// Bucket-width growth factor. 2× per bucket: the index is a bit
/// operation rather than a search, and the reported percentile is
/// within one factor of two of the truth — see `LatencyHistogram`.
const LATENCY_BUCKET_GROWTH: u64 = 2;

comptime {
    // `LatencyHistogram.bucketIndexFor` is a bit trick, not a search,
    // so it is only equivalent to the general bucket formula while the
    // base is 1 and the factor is 2. Change either constant and the
    // index would silently stop matching the boundaries
    // `bucketUpperBound` reports — make that a compile error instead.
    if (LATENCY_BUCKET_MIN_US != 1 or LATENCY_BUCKET_GROWTH != 2) {
        @compileError("bucketIndexFor assumes LATENCY_BUCKET_MIN_US == 1 and LATENCY_BUCKET_GROWTH == 2");
    }
}

/// Fixed-bucket latency histogram. Zero allocation, zero locks: the
/// query handler records a sample with one atomic increment per bucket
/// and nothing else, which is what keeps the hot path allocation-free.
///
/// ## Bucket formula
///
/// Bucket `i` covers the half-open microsecond range
///
///     [LATENCY_BUCKET_MIN_US * LATENCY_BUCKET_GROWTH^i,
///      LATENCY_BUCKET_MIN_US * LATENCY_BUCKET_GROWTH^(i+1) - 1]
///
/// With the constants above that collapses to `[2^i, 2^(i+1) - 1]`,
/// so the bucket index of a sample is just its base-2 logarithm.
///
/// ## Resolution — stated honestly
///
/// Each bucket is twice as wide as the one below it, and every
/// percentile is reported as the **upper bound of the bucket that
/// contains the requested rank**. A reported value is therefore
/// conservative in the direction that matters for an alert: never
/// below the true percentile, and at most 2× above it. `p99 = 8192`
/// means "the true p99 is somewhere in (4096, 8192] µs" — not 8192µs
/// to three significant figures. The sample count is published
/// alongside (`mem3_retrieval_latency_samples_total`) because a
/// percentile over three samples is noise, not a measurement.
const LatencyHistogram = struct {
    /// `@splat` rather than `{ .init(0) } ** N`: the array-repeat
    /// spelling does not parse here (the `**` after a struct literal
    /// is read as a pointer type), and the length is already in the
    /// field's type.
    buckets: [LATENCY_BUCKET_COUNT]std.atomic.Value(u64) = @splat(.init(0)),
    /// Total samples recorded, i.e. the sum of `buckets`.
    samples: std.atomic.Value(u64) = .init(0),

    /// Which bucket a microsecond sample belongs to. Pure, no state.
    pub fn bucketIndexFor(us: u64) usize {
        if (us <= LATENCY_BUCKET_MIN_US) return 0;
        // floor(log2(us)) == highest set bit. Computed through u32
        // because @clz(u64) returns a u7 and mixing that with the
        // literal 63 needs a common type.
        const clz: u32 = @intCast(@clz(us));
        const idx: usize = @intCast(63 - clz);
        return @min(idx, LATENCY_BUCKET_COUNT - 1);
    }

    /// Inclusive upper edge of bucket `index`, in microseconds.
    /// Saturates rather than overflowing on the top buckets.
    pub fn bucketUpperBound(index: usize) u64 {
        var bound: u64 = LATENCY_BUCKET_MIN_US;
        var i: usize = 0;
        while (i <= index) : (i += 1) {
            if (bound > std.math.maxInt(u64) / LATENCY_BUCKET_GROWTH) return std.math.maxInt(u64);
            bound *= LATENCY_BUCKET_GROWTH;
        }
        return bound - 1;
    }

    /// Record one sample. No allocator, no error — this runs on the
    /// query hot path and must not be able to fail.
    pub fn record(self: *LatencyHistogram, us: u64) void {
        _ = self.buckets[bucketIndexFor(us)].fetchAdd(1, .monotonic);
        _ = self.samples.fetchAdd(1, .monotonic);
    }

    pub fn sampleCount(self: *const LatencyHistogram) u64 {
        return self.samples.load(.monotonic);
    }

    /// Conservative percentile over the recorded samples, as
    /// `num/den` (50/100, 95/100, 99/100).
    ///
    /// Walks buckets low to high and returns the upper bound of the
    /// first bucket whose cumulative count reaches
    /// `ceil(total * num / den)`. An empty histogram returns 0 — the
    /// division below is guarded, so "no traffic yet" reports a zero
    /// rather than a NaN.
    pub fn percentile(self: *const LatencyHistogram, num: u32, den: u32) u64 {
        const total = self.samples.load(.monotonic);
        if (total == 0 or den == 0) return 0;
        // ceil(total * num / den), integer arithmetic only: a float
        // rank would make this harder to hand-verify in a test.
        const rank: u64 = @max(1, (total * num + den - 1) / den);
        var cumulative: u64 = 0;
        for (&self.buckets, 0..) |*bucket, i| {
            cumulative += bucket.load(.monotonic);
            if (cumulative >= rank) return bucketUpperBound(i);
        }
        // Unreachable while `samples` is maintained alongside the
        // buckets; the fallback keeps the function total rather than
        // returning an under-counted rank.
        return bucketUpperBound(LATENCY_BUCKET_COUNT - 1);
    }
};

const Metrics = struct {
    requests_total: std.atomic.Value(u64) = .init(0),
    queries_total: std.atomic.Value(u64) = .init(0),
    inserts_total: std.atomic.Value(u64) = .init(0),
    last_query_us: std.atomic.Value(u64) = .init(0),
    /// Bumped by the maintenance thread on each completed pass.
    maintenance_passes: std.atomic.Value(u64) = .init(0),

    /// Distribution of `/api/query` latency. Lives inside `Metrics` by
    /// value and must never be copied out of it: `std.atomic.Value` is
    /// a plain struct wrapping its number, so a copy is a snapshot,
    /// not a shared cell (the same trap is documented on
    /// `maintenance_passes`).
    latency: LatencyHistogram = .{},

    /// Cells the forgetting sweep has moved to the fuzzy store, and
    /// cells it has examined, both cumulative since boot. The ratio
    /// backing `mem3_forgetting_rate` is only auditable with both
    /// absolute numbers next to it: a rate of 0.5 means "half of what
    /// we looked at", and "looked at" has to be visible.
    forgotten_cells_total: std.atomic.Value(u64) = .init(0),
    forgetting_swept_total: std.atomic.Value(u64) = .init(0),

    /// Render the Prometheus exposition format.
    ///
    /// Gauges are read from live store state at scrape time; counters
    /// accumulate. `store` is passed in rather than reached through
    /// `Metrics` so that `Metrics` stays a pure counter bag with no
    /// pointer back into the store — which is what makes it safe to
    /// declare `self` a `*const` here. Called from `route`, i.e.
    /// already under `store_mutex`; this adds no lock of its own.
    fn render(self: *const Metrics, alloc: Allocator, boot_time_ns: u128, store: *Store) ![]u8 {
        const uptime_s = @divTrunc(nowNs() - boot_time_ns, 1_000_000_000);

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        const w = ListWriter{ .list = &out, .gpa = alloc };

        try w.writeAll(
            \\# mem3 metrics
            \\# HELP mem3_uptime_s Uptime in seconds
            \\# TYPE mem3_uptime_s gauge
            \\
        );
        try w.print("mem3_uptime_s {d}\n", .{uptime_s});

        try w.writeAll(
            \\# HELP mem3_requests_total Total HTTP requests
            \\# TYPE mem3_requests_total counter
            \\
        );
        try w.print("mem3_requests_total {d}\n", .{self.requests_total.load(.monotonic)});

        try w.writeAll(
            \\# HELP mem3_queries_total Total query API calls
            \\# TYPE mem3_queries_total counter
            \\
        );
        try w.print("mem3_queries_total {d}\n", .{self.queries_total.load(.monotonic)});

        try w.writeAll(
            \\# HELP mem3_inserts_total Total insert API calls
            \\# TYPE mem3_inserts_total counter
            \\
        );
        try w.print("mem3_inserts_total {d}\n", .{self.inserts_total.load(.monotonic)});

        try w.writeAll(
            \\# HELP mem3_last_query_us Last query latency in microseconds (most recent request only)
            \\# TYPE mem3_last_query_us gauge
            \\
        );
        try w.print("mem3_last_query_us {d}\n", .{self.last_query_us.load(.monotonic)});

        try w.writeAll(
            \\# HELP mem3_maintenance_passes_total Completed maintenance passes
            \\# TYPE mem3_maintenance_passes_total counter
            \\
        );
        try w.print("mem3_maintenance_passes_total {d}\n", .{self.maintenance_passes.load(.monotonic)});

        // Retrieval latency percentiles. Conservative by construction:
        // each is the upper bound of its containing bucket, so it never
        // under-reports. See `LatencyHistogram` for the formula.
        try w.writeAll(
            \\# HELP mem3_retrieval_latency_p50_us Retrieval latency p50 in microseconds, upper bound of the containing bucket
            \\# TYPE mem3_retrieval_latency_p50_us gauge
            \\
        );
        try w.print("mem3_retrieval_latency_p50_us {d}\n", .{self.latency.percentile(50, 100)});

        try w.writeAll(
            \\# HELP mem3_retrieval_latency_p95_us Retrieval latency p95 in microseconds, upper bound of the containing bucket
            \\# TYPE mem3_retrieval_latency_p95_us gauge
            \\
        );
        try w.print("mem3_retrieval_latency_p95_us {d}\n", .{self.latency.percentile(95, 100)});

        try w.writeAll(
            \\# HELP mem3_retrieval_latency_p99_us Retrieval latency p99 in microseconds, upper bound of the containing bucket
            \\# TYPE mem3_retrieval_latency_p99_us gauge
            \\
        );
        try w.print("mem3_retrieval_latency_p99_us {d}\n", .{self.latency.percentile(99, 100)});

        // Sample count, because a percentile over three samples is
        // noise and an operator cannot tell that from the number alone.
        try w.writeAll(
            \\# HELP mem3_retrieval_latency_samples_total Query latency samples recorded since boot, the basis for the percentiles above
            \\# TYPE mem3_retrieval_latency_samples_total counter
            \\
        );
        try w.print("mem3_retrieval_latency_samples_total {d}\n", .{self.latency.sampleCount()});

        // Live store state — gauges, read at scrape time.
        try w.writeAll(
            \\# HELP mem3_memstore_cells Cells currently in the active memstore (excludes fuzzy)
            \\# TYPE mem3_memstore_cells gauge
            \\
        );
        try w.print("mem3_memstore_cells {d}\n", .{store.cellCount()});

        // One line per MemorySource variant, iterated over the enum
        // itself rather than a hand-written list: a fourth source
        // cannot be added without the metric following it.
        try w.writeAll(
            \\# HELP mem3_memstore_cells_by_source Cells in the active memstore per MemorySource
            \\# TYPE mem3_memstore_cells_by_source gauge
            \\
        );
        for (std.enums.values(MemorySource)) |src| {
            try w.print("mem3_memstore_cells_by_source{{source=\"{s}\"}} {d}\n", .{ @tagName(src), store.cellCountBySource(src) });
        }

        try w.writeAll(
            \\# HELP mem3_hyperedges Hyperedges currently in the hypergraph
            \\# TYPE mem3_hyperedges gauge
            \\
        );
        try w.print("mem3_hyperedges {d}\n", .{store.hyperedgeCount()});

        try w.writeAll(
            \\# HELP mem3_vector_index_depth Deepest occupied HNSW layer, -1 when the index is empty
            \\# TYPE mem3_vector_index_depth gauge
            \\
        );
        try w.print("mem3_vector_index_depth {d}\n", .{store.hnsw.maxOccupiedLevel()});

        try w.writeAll(
            \\# HELP mem3_vector_index_nodes Vectors in the HNSW index
            \\# TYPE mem3_vector_index_nodes gauge
            \\
        );
        try w.print("mem3_vector_index_nodes {d}\n", .{store.hnsw.nodeCount()});

        // Forgetting. The rate is a ratio, not a rate per second: a sweep
        // is a full pass over the corpus on a slow schedule
        // (hourly by default), so "how much of what we looked at did we
        // drop" is the honest question. The two counters are published
        // next to it so the ratio can be recomputed from the exposition
        // text by anyone auditing it.
        //
        // Preview sweeps (`dry_run`) are deliberately absent from these
        // counters: they moved nothing, so counting them would publish
        // cells as forgotten that the daemon is still serving.
        const forgotten = self.forgotten_cells_total.load(.monotonic);
        const swept = self.forgetting_swept_total.load(.monotonic);
        const forget_rate: f64 = if (swept == 0)
            0.0
        else
            @as(f64, @floatFromInt(forgotten)) / @as(f64, @floatFromInt(swept));

        try w.writeAll(
            \\# HELP mem3_forgetting_rate Cells forgotten per cell swept by forgetting sweeps since boot, 0 before any sweep has run
            \\# TYPE mem3_forgetting_rate gauge
            \\
        );
        try w.print("mem3_forgetting_rate {d:.6}\n", .{forget_rate});

        try w.writeAll(
            \\# HELP mem3_forgotten_cells_total Cells moved to the fuzzy store by forgetting sweeps since boot
            \\# TYPE mem3_forgotten_cells_total counter
            \\
        );
        try w.print("mem3_forgotten_cells_total {d}\n", .{forgotten});

        try w.writeAll(
            \\# HELP mem3_forgetting_swept_total Cells examined by forgetting sweeps since boot
            \\# TYPE mem3_forgetting_swept_total counter
            \\
        );
        try w.print("mem3_forgetting_swept_total {d}\n", .{swept});

        return out.toOwnedSlice(alloc);
    }
};

/// Sleep for `ms` milliseconds.
///
/// Zig 0.17 removed `std.Thread.sleep`, and `std.c` does not re-export
/// `nanosleep`, so libc is declared directly — same convention as the
/// `getenv` fwd-decl in `cli_commands/serve.zig`. `EINTR` retries rather
/// than returning early: a signal must not silently shorten the interval.
fn sleepMs(ms: u32) void {
    const nanosleep = struct {
        extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;
    }.nanosleep;

    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (true) {
        const rc = nanosleep(&req, null);
        if (rc == 0) break;
        if (std.c.errno(rc) != .INTR) break;
    }
}

/// Wall clock in milliseconds — the unit every `created_at` /
/// `updated_at` / `unrealized_at` field in the system is expressed in.
fn nowMs() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Plain pthread mutex.
///
/// `std.Thread.Mutex` no longer exists in Zig 0.17, and `std.Io.Mutex`
/// demands an `Io` instance — which would mean standing up a
/// `std.Io.Threaded` event loop for the sake of one lock, in a daemon that
/// reaches the network through raw `std.c` sockets and never constructs an
/// `Io`. libc's mutex is the honest fit.
const Mutex = struct {
    m: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.m);
    }
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.m);
    }
};

/// Default cadence for the daemon's scheduled forgetting sweep.
///
/// **Why hourly, and not the 60s maintenance cadence.** The existence-gain
/// rule scores a cell as `importance * exp(-decay_rate * age_days)` and
/// forgets it below `forgetting_threshold` (0.1). With the configured decay
/// rates (matter 0.05/day, form 0.03/day, spirit 0.01/day) even the
/// fastest source needs `ln(importance/0.1)/0.05` ≈ 46 days to cross the
/// threshold from a perfect importance of 1.0 — and any cell already close
/// to 0.1 crosses it in hours, which is still far longer than a minute.
/// So the *decision* barely changes inside a minute, while the sweep itself
/// is an O(cells) walk under `store_mutex`, i.e. time every HTTP request is
/// blocked. Once an hour is frequent enough that an operator watching
/// `mem3_forgotten_cells_total` sees movement within the hour, and rare
/// enough that the daemon is not walking its whole corpus 1440 times a day
/// to learn the same thing.
///
/// Deliberately NOT derived from `--maint-interval`: a test (or an operator)
/// tuning the goal-maintenance cadence to 1s must not silently inherit a
/// 1-second forgetting sweep, which would fuzz a freshly seeded corpus
/// mid-assertion. The two cadences are separate counters over separate
/// deadlines in the same thread.
pub const DEFAULT_FORGET_INTERVAL_SEC: u32 = 3600;

pub const Server = struct {
    alloc: Allocator,
    bind: []const u8,
    port: u16,
    fd: c.fd_t,
    bound: bool,
    store: *Store,
    boot_time_ns: u128,
    metrics: Metrics,

    /// Guards every `store` mutation and every read of `store` state.
    ///
    /// The accept loop was single-threaded for the daemon's whole life,
    /// which is why it never needed one. A maintenance thread breaks that
    /// assumption immediately: it would be rewriting goal statuses while
    /// `GET /api/goals` walks the same poset, and `GoalPoset.nodes` is an
    /// `AutoHashMap` whose iterators do not survive a rehash. This is not
    /// theoretical lock-hygiene — it is the difference between a daemon and
    /// a crash.
    store_mutex: Mutex = .{},

    /// Maintenance thread, if one was started.
    maint_thread: ?std.Thread = null,
    /// Cleared by `deinit` to ask the thread to stop. Release/acquire: the
    /// thread may be parked in a sleep and must observe the flip promptly.
    maint_running: std.atomic.Value(bool) = .init(false),
    /// Seconds between maintenance passes.
    maint_interval_sec: u32 = 60,
    /// Seconds between scheduled forgetting sweeps; 0 = off.
    ///
    /// Zero until `serve` opts in, so embedding `Server` directly (tests,
    /// a future SDK) never starts deleting memories because someone forgot
    /// to configure it. `serve` sets it to
    /// `DEFAULT_FORGET_INTERVAL_SEC` unless the operator says otherwise.
    forget_interval_sec: u32 = 0,
    /// Daemon-wide preview mode for the scheduled sweep (`--dry-run`).
    /// The sweep still runs and still reports what it would drop, but no
    /// cell moves to the fuzzy store and the counters stay put.
    forget_dry_run: bool = false,

    /// Where daemon events go. `.off` (the default) writes nothing, so a
    /// `Server` built without options is exactly as silent as it always was.
    logger: Logger = .{},
    /// Seconds between periodic summary lines; 0 = none. Only ever non-zero
    /// when the operator typed `--log-every`.
    log_every_sec: u32 = 0,
    /// The WAL durability mode this server's store was opened with.
    wal_sync: core.Config.WalSync = .always,
    /// True in `.group` mode: each connection gets its own thread, so that
    /// several writers can be waiting on one shared fsync at once. In every
    /// other mode the accept loop stays the single-threaded loop it always
    /// was, so the default path is unchanged.
    concurrent: bool = false,
    /// Connections currently being handled on their own thread.
    inflight: std.atomic.Value(usize) = .init(0),
    /// Set by `requestShutdown` (and by SIGINT/SIGTERM when `watch_signals`).
    shutdown_requested: std.atomic.Value(bool) = .init(false),
    /// Also stop on SIGINT/SIGTERM. Off by default: the signal flag is
    /// process-global, and an embedded `Server` (a test, an SDK host) must
    /// not be stopped by a signal aimed at its host. `mem3 serve` turns it on.
    watch_signals: bool = false,

    pub const Options = struct {
        data_dir: ?[]const u8,
        wal_sync: core.Config.WalSync = .always,
        logger: Logger = .{},
        log_every_sec: u32 = 0,
    };

    /// `data_dir` is `null` for an in-memory server: no WAL, no snapshot,
    /// nothing written to disk. Tests that are not about persistence must
    /// use it — a fixed `/tmp` path makes a test non-idempotent, because
    /// the WAL from the previous run is replayed into the next one and the
    /// corpus quietly doubles. (That is not hypothetical: the `maxHops`
    /// test passed on a clean `/tmp` and failed on the second run.)
    pub fn init(alloc: Allocator, bind: []const u8, port: u16, data_dir: ?[]const u8) !*Server {
        return initWithOptions(alloc, bind, port, .{ .data_dir = data_dir });
    }

    pub fn initWithOptions(alloc: Allocator, bind: []const u8, port: u16, opts: Options) !*Server {
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);
        const store = try Store.init(alloc, .{ .data_dir = opts.data_dir, .wal_sync = opts.wal_sync });
        errdefer store.deinit();
        self.* = .{
            .alloc = alloc,
            .bind = try alloc.dupe(u8, bind),
            .port = port,
            .fd = -1,
            .bound = false,
            .store = store,
            .boot_time_ns = 0,
            .metrics = .{},
            .logger = opts.logger,
            .log_every_sec = opts.log_every_sec,
            .wal_sync = opts.wal_sync,
            .concurrent = opts.wal_sync == .group and opts.data_dir != null,
        };
        return self;
    }

    pub fn deinit(self: *Server) void {
        // Stop and JOIN the maintenance thread before touching anything it
        // can reach. `store.deinit()` under a running thread is a
        // use-after-free that happens to work until it doesn't.
        self.stopMaintenance();
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.store.deinit();
        self.alloc.free(self.bind);
        self.alloc.destroy(self);
    }

    /// Start the periodic maintenance thread.
    ///
    /// `interval_sec == 0` disables it, which is what the tests use: a
    /// background thread racing a test's assertions is a flaky test waiting
    /// to be written. Note the consequence for the scheduled sweep: there
    /// is exactly one background thread, so `--maint-interval=0` stops
    /// scheduled forgetting too. That is stated in `--help` rather than
    /// papered over with a second thread.
    pub fn startMaintenance(self: *Server, interval_sec: u32) !void {
        // The thread also carries the two duties that have nothing to do
        // with goals: the periodic summary line and interval-mode fsyncs. If
        // neither is on, `--maint-interval=0` still means "no thread".
        const interval_mode = switch (self.wal_sync) {
            .interval_ms => self.store.wal != null,
            else => false,
        };
        const other_duties = (self.log_every_sec != 0 and self.logger.enabled()) or interval_mode;
        if (interval_sec == 0 and !other_duties) return;
        if (self.maint_thread != null) return; // already running
        self.maint_interval_sec = interval_sec;
        self.maint_running.store(true, .release);
        // If the spawn fails, do not leave the flag set: `stopMaintenance`
        // would then be clearing a "running" state with no thread behind it.
        errdefer self.maint_running.store(false, .release);
        self.maint_thread = try std.Thread.spawn(.{}, maintenanceLoop, .{self});
    }

    /// Configure the scheduled forgetting sweep. Call before
    /// `startMaintenance`; `interval_sec == 0` means "never sweep".
    ///
    /// `dry_run` is the daemon-wide preview switch (`mem3 serve
    /// --dry-run`): the periodic sweep reports what it would drop without
    /// dropping it. A system that deletes memories should be runnable in a
    /// mode where it only ever previews.
    pub fn setForgetSchedule(self: *Server, interval_sec: u32, dry_run: bool) void {
        self.forget_interval_sec = interval_sec;
        self.forget_dry_run = dry_run;
    }

    /// One periodic summary line (`--log-every`). Takes `store_mutex` only
    /// to read the store's counters; the rest are atomics.
    pub fn emitSummary(self: *Server) void {
        if (!self.logger.enabled()) return;
        self.store_mutex.lock();
        const cells = self.store.cellCount();
        const edges = self.store.hyperedgeCount();
        const ws: ?wal_mod.WAL.Stats = if (self.store.wal) |w| w.stats() else null;
        self.store_mutex.unlock();

        const uptime_s: u64 = @intCast(@divTrunc(nowNs() - self.boot_time_ns, 1_000_000_000));
        const m = &self.metrics;
        if (ws) |w| {
            self.logger.event(.info, "summary", "uptime_s={d} requests={d} inserts={d} queries={d} cells={d} hyperedges={d} maintenance_passes={d} forgotten={d} wal_sync={s} wal_appended={d} wal_durable={d} wal_fsyncs={d}", .{
                uptime_s,
                m.requests_total.load(.monotonic),
                m.inserts_total.load(.monotonic),
                m.queries_total.load(.monotonic),
                cells,
                edges,
                m.maintenance_passes.load(.monotonic),
                m.forgotten_cells_total.load(.monotonic),
                @tagName(self.wal_sync),
                w.appended,
                w.durable,
                w.syncs,
            });
        } else {
            self.logger.event(.info, "summary", "uptime_s={d} requests={d} inserts={d} queries={d} cells={d} hyperedges={d} maintenance_passes={d} forgotten={d} wal=none", .{
                uptime_s,
                m.requests_total.load(.monotonic),
                m.inserts_total.load(.monotonic),
                m.queries_total.load(.monotonic),
                cells,
                edges,
                m.maintenance_passes.load(.monotonic),
                m.forgotten_cells_total.load(.monotonic),
            });
        }
    }

    /// `interval:N` mode's idle-stream flush, from the maintenance thread.
    /// Holds `store_mutex` because `takeSnapshot` swaps the WAL object under
    /// it; the fsync it may trigger is bounded by one interval.
    fn walIntervalTick(self: *Server) void {
        self.store_mutex.lock();
        defer self.store_mutex.unlock();
        if (self.store.wal) |w| w.syncIfDue() catch |err| {
            diag("interval fsync failed: {}", .{err});
        };
    }

    /// Ask `serve` to stop accepting, drain, and return. Safe from any thread.
    pub fn requestShutdown(self: *Server) void {
        self.shutdown_requested.store(true, .release);
    }

    fn stopping(self: *const Server) bool {
        if (self.shutdown_requested.load(.acquire)) return true;
        return self.watch_signals and signal.terminationRequested();
    }

    /// Wait for connection threads to finish. Bounded: a handler wedged on a
    /// dead client must not turn a clean shutdown into a SIGKILL.
    fn drainInflight(self: *Server, timeout_ms: u32) bool {
        var waited: u32 = 0;
        while (self.inflight.load(.acquire) != 0) {
            if (waited >= timeout_ms) return false;
            sleepMs(2);
            waited += 2;
        }
        return true;
    }

    /// Make the WAL durable. `serve` calls this after draining, with the
    /// maintenance thread already joined.
    pub fn flushWal(self: *Server) !void {
        self.store_mutex.lock();
        defer self.store_mutex.unlock();
        if (self.store.wal) |w| try w.flush();
    }

    fn stopMaintenance(self: *Server) void {
        self.maint_running.store(false, .release);
        if (self.maint_thread) |t| {
            t.join();
            self.maint_thread = null;
        }
    }

    fn maintenanceLoop(srv: *Server) void {
        // Sleep in short slices rather than one long sleep, so `deinit` is
        // not held hostage to a 60-second interval. A daemon that takes a
        // minute to shut down is a daemon that gets SIGKILLed instead.
        const slice_ms: u32 = 100;
        // u64 arithmetic: `interval_sec * 1000` overflows u32 above ~4.29e6
        // seconds, which is a typo away from a nonsense slice count.
        // 0 = maintenance is off (the thread is only here for the summary or
        // interval fsyncs); forgetting rides the same switch, as documented.
        const maint_slices: u64 = if (srv.maint_interval_sec == 0)
            0
        else
            @max(@as(u64, srv.maint_interval_sec) * 1000 / slice_ms, 1);
        const summary_slices: u64 = if (srv.log_every_sec == 0 or !srv.logger.enabled())
            0
        else
            @max(@as(u64, srv.log_every_sec) * 1000 / slice_ms, 1);
        const interval_mode = switch (srv.wal_sync) {
            .interval_ms => true,
            else => false,
        };
        // Two independent deadlines over one thread. `forget_slices == 0`
        // is "forgetting is off", and in that case the counter must stop
        // advancing entirely — incrementing it forever would eventually
        // wrap a u64 into a panic in the middle of the night.
        const forget_slices: u64 = if (srv.forget_interval_sec == 0 or maint_slices == 0)
            0
        else
            @max(@as(u64, srv.forget_interval_sec) * 1000 / slice_ms, 1);

        var since_maintenance: u64 = 0;
        var since_forget: u64 = 0;
        var since_summary: u64 = 0;

        while (srv.maint_running.load(.acquire)) {
            sleepMs(slice_ms);
            if (maint_slices != 0) since_maintenance += 1;
            if (forget_slices != 0) since_forget += 1;
            if (summary_slices != 0) since_summary += 1;
            if (!srv.maint_running.load(.acquire)) break;

            if (interval_mode) srv.walIntervalTick();
            if (summary_slices != 0 and since_summary >= summary_slices) {
                since_summary = 0;
                srv.emitSummary();
            }
            if (maint_slices != 0 and since_maintenance >= maint_slices) {
                since_maintenance = 0;
                srv.runMaintenancePass();
            }
            if (forget_slices != 0 and since_forget >= forget_slices) {
                since_forget = 0;
                if (srv.runForgetSweep(srv.forget_dry_run)) |_| {} else |err| {
                    diag("forgetting sweep failed: {}", .{err});
                    srv.logger.event(.warn, "forgetting", "sweep failed: {s}", .{@errorName(err)});
                }
            }
        }
    }

    /// One maintenance pass from the background thread. Silent unless
    /// something actually changed: a per-pass log line is how a
    /// long-lived daemon fills a disk, because launchd/systemd capture
    /// stdout and one line a minute is ~500MB a year from a daemon that
    /// has nothing to say.
    fn runMaintenancePass(self: *Server) void {
        self.store_mutex.lock();
        const res = self.store.maintain(nowMs()) catch |err| {
            self.store_mutex.unlock();
            diag("maintenance pass failed: {}", .{err});
            self.logger.event(.warn, "maintenance", "pass failed: {s}", .{@errorName(err)});
            return;
        };
        self.store_mutex.unlock();

        // Bump the metric that /metrics actually publishes.
        // `std.atomic.Value` is a plain struct wrapping a u64, so
        // copying one into another copies the value, not a shared
        // cell — a second counter field would have read 0 forever.
        _ = self.metrics.maintenance_passes.fetchAdd(1, .monotonic);
        if (res.goals_unrealized > 0 or res.goals_failed > 0) {
            // Transitions are rare by construction (7-day rule), so
            // logging them unconditionally is safe and useful.
            if (!builtin.is_test) log.info("maintenance: {d} goal(s) unrealized, {d} failed", .{ res.goals_unrealized, res.goals_failed });
            self.logger.event(.info, "maintenance", "{d} goal(s) unrealized, {d} failed", .{ res.goals_unrealized, res.goals_failed });
        }
    }

    /// Run one maintenance pass synchronously. Used by the tests and by
    /// `POST /api/sync`, so the behaviour is reachable without waiting out
    /// an interval.
    pub fn runMaintenanceNow(self: *Server) !Store.MaintenanceResult {
        self.store_mutex.lock();
        defer self.store_mutex.unlock();
        return self.store.maintain(nowMs());
    }

    /// Run one forgetting sweep and fold it into the published counters.
    ///
    /// Takes `store_mutex`; for callers that already hold it (every route
    /// handler — `handleConn` locks around `route`) use `sweepLocked`.
    ///
    /// **The single choke point.** The scheduled path (`maintenanceLoop`),
    /// `POST /api/forget` and any future caller all funnel through one of
    /// these two, so a sweep is counted exactly once no matter which door it
    /// came in by. Call `store.forget` directly and you get an unmeasured
    /// sweep — which is precisely how `mem3_forgotten_cells_total` sat at a
    /// structural zero for the daemon's whole life while the metric looked
    /// perfectly healthy.
    pub fn runForgetSweep(self: *Server, dry_run: bool) !memory.Forgetter.SweepResult {
        self.store_mutex.lock();
        defer self.store_mutex.unlock();
        return self.sweepLocked(dry_run);
    }

    /// `runForgetSweep` for callers already holding `store_mutex`.
    ///
    /// DO NOT call `runForgetSweep` from a route handler. `store_mutex` is a
    /// plain pthread mutex, so re-entering it from a thread that already
    /// holds it self-deadlocks: the daemon stops answering every request,
    /// forever, with no error. That is not hypothetical — the first
    /// version of `handleForget` did exactly that and hung the whole
    /// process on the first `POST /api/forget`. The in-process tests could
    /// not see it, because they call `route` directly and therefore never
    /// hold the lock; the regression test for it takes the lock the way
    /// `handleConn` does.
    fn sweepLocked(self: *Server, dry_run: bool) !memory.Forgetter.SweepResult {
        const res = try self.store.forget(dry_run);
        if (!dry_run) self.recordForgetSweep(res);

        // Silent unless the sweep actually moved something. A sweep that
        // forgets nothing is the normal case on a healthy corpus and must
        // not produce a log line; per-cycle logging under launchd has
        // previously cost ~1.5GB/day. Transitions are rare by construction —
        // the existence-gain rule moves on a days timescale — so one line per
        // transition is the useful signal, and `diag` keeps it out of the
        // test runner, which fails any test that logs at any level.
        //
        // `diag` rather than `log.info`: `src/main.zig` pins
        // `log_level = .err`, so an `info` line here would never reach an
        // operator at all.
        if (!dry_run and res.fuzzied > 0) {
            diag("forgetting: {d} cell(s) fuzzied of {d} swept", .{ res.fuzzied, res.fuzzied + res.kept });
            self.logger.event(.info, "forgetting", "{d} cell(s) fuzzied of {d} swept", .{ res.fuzzied, res.fuzzied + res.kept });
        }
        return res;
    }

    /// Fold one forgetting sweep into the cumulative counters behind
    /// `mem3_forgetting_rate`.
    ///
    /// Called by `runForgetSweep` and therefore already counted by the time
    /// a caller reaches here — do not call it a second time for the same
    /// sweep. It stays public so a host embedding `Server` can fold in the
    /// result of a sweep it ran itself, which is the case the counters were
    /// originally added for.
    ///
    /// Counted here rather than inside `Metrics.render` so the numbers are
    /// monotonic and auditable instead of re-derived per scrape.
    pub fn recordForgetSweep(self: *Server, res: memory.Forgetter.SweepResult) void {
        const forgotten: u64 = @intCast(res.fuzzied);
        _ = self.metrics.forgotten_cells_total.fetchAdd(forgotten, .monotonic);
        // "Swept" = everything the sweep looked at, kept or not. The
        // rate is meaningless without it.
        _ = self.metrics.forgetting_swept_total.fetchAdd(forgotten + @as(u64, @intCast(res.kept)), .monotonic);
    }

    pub fn listen(self: *Server) !void {
        var addr: std.posix.sockaddr.in = undefined;
        addr.family = c.AF.INET;
        addr.port = std.mem.nativeToBig(u16, self.port);
        // Resolve bind: IPv4 dotted-quad → u32 BE. Special names:
        //   "127.0.0.1" / "localhost" → loopback
        //   "0.0.0.0" / "all"        → INADDR_ANY (all interfaces)
        //   anything else that's a valid IPv4 → use it
        //   invalid                  → warn + fall back to loopback
        addr.addr = parseBindAddr(self.bind) catch |err| blk: {
            std.log.warn("invalid bind '{s}': {s}; falling back to 127.0.0.1", .{ self.bind, @errorName(err) });
            break :blk std.mem.nativeToBig(u32, 0x7F000001);
        };

        const fd = std.c.socket(c.AF.INET, @bitCast(@as(u32, c.SOCK.STREAM)), 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);

        const optval: c_int = 1;
        _ = std.c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &std.mem.toBytes(optval), @sizeOf(c_int));

        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
        if (std.c.listen(fd, 128) != 0) return error.ListenFailed;

        self.fd = fd;
        self.boot_time_ns = nowNs();
        self.bound = true;
        log.info("listening on {s}:{d}", .{ self.bind, self.port });
    }

    /// Accept loop. Returns once `requestShutdown` is called (or SIGINT /
    /// SIGTERM arrives, with `watch_signals`): it stops accepting, waits for
    /// in-flight connections, joins the maintenance thread and flushes the
    /// WAL, so the caller only has to `deinit`.
    pub fn serve(self: *Server) !void {
        if (!self.bound) return error.NotListening;
        // Poll with a short timeout instead of a bare blocking `accept`:
        // a signal that lands between the `stopping()` check and the
        // blocking call would otherwise be missed until the next client.
        const POLL_MS = 200;
        while (!self.stopping()) {
            var pfd = [1]std.c.pollfd{.{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&pfd, 1, POLL_MS) <= 0) continue;
            var client_addr: std.posix.sockaddr.in = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(client_addr));
            const client_fd = std.c.accept(self.fd, @ptrCast(&client_addr), &addr_len);
            if (client_fd < 0) continue;
            if (self.concurrent) {
                self.spawnConn(client_fd);
            } else {
                self.handleConn(client_fd) catch |err| log.warn("conn: {}", .{err});
                _ = std.c.close(client_fd);
            }
        }

        // Stop accepting: new connections are refused from here on.
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
            self.bound = false;
        }
        const drained = self.drainInflight(10_000);
        if (!drained) diag("shutdown: {d} connection(s) still in flight after 10s, flushing anyway", .{self.inflight.load(.acquire)});
        self.stopMaintenance();
        self.flushWal() catch |err| {
            diag("shutdown: WAL flush failed: {}", .{err});
            self.logger.event(.err, "shutdown", "WAL flush failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    /// Most connection threads alive at once; beyond it the accept loop
    /// waits, which is back-pressure rather than unbounded thread growth.
    const MAX_INFLIGHT: usize = 256;

    fn spawnConn(self: *Server, client_fd: c.fd_t) void {
        while (self.inflight.load(.acquire) >= MAX_INFLIGHT) sleepMs(1);
        _ = self.inflight.fetchAdd(1, .acq_rel);
        const t = std.Thread.spawn(.{}, connThread, .{ self, client_fd }) catch |err| {
            // Out of threads: serve it here, on the accept thread, which is
            // slower but never drops the request.
            _ = self.inflight.fetchSub(1, .acq_rel);
            diag("conn thread spawn failed: {}; handling inline", .{err});
            self.handleConn(client_fd) catch |e| log.warn("conn: {}", .{e});
            _ = std.c.close(client_fd);
            return;
        };
        t.detach();
    }

    fn connThread(self: *Server, client_fd: c.fd_t) void {
        defer _ = self.inflight.fetchSub(1, .acq_rel);
        self.handleConn(client_fd) catch |err| log.warn("conn: {}", .{err});
        _ = std.c.close(client_fd);
    }

    fn handleConn(self: *Server, fd: c.fd_t) !void {
        var buf: [16384]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) return;
        _ = self.metrics.requests_total.fetchAdd(1, .monotonic);

        const req = buf[0..@intCast(n)];
        var line_it = std.mem.splitScalar(u8, req, '\n');
        const request_line = line_it.next() orelse return;
        var parts_it = std.mem.splitScalar(u8, request_line, ' ');
        const method = std.mem.trim(u8, parts_it.next() orelse "", " \r");
        const path_with_query = std.mem.trim(u8, parts_it.next() orelse "", " \r");
        _ = parts_it.next();

        const path = if (std.mem.findScalar(u8, path_with_query, '?')) |q| path_with_query[0..q] else path_with_query;

        // One lock for the whole request, taken here rather than inside
        // each handler.
        //
        // The alternative is a `lock()` in every handler that touches the
        // store, and that shape fails open: the next handler someone adds
        // simply forgets, and the bug only appears once maintenance is
        // actually running. One coarse lock around the dispatch point
        // cannot be forgotten, and request latency here is microseconds —
        // there is no throughput argument for finer granularity.
        //
        // `handleConn` is the right altitude, not `route`: `route` is
        // called directly by the tests, and locking there would deadlock
        // against `runMaintenanceNow`.
        //
        // Group commit: in `.group` mode every WAL append this request makes
        // is *written* under the lock but not *waited for*. The lock is
        // dropped, and only then does this thread block until one fsync
        // covers its records — so while it waits, other connections can run
        // and append, and they all share that fsync. The client still gets
        // no reply before its record is durable; it is the lock, not the
        // acknowledgement, that no longer spans the fsync.
        if (self.concurrent) wal_mod.deferDurability();
        self.store_mutex.lock();
        var response = self.route(method, path, req) catch |err| {
            self.store_mutex.unlock();
            if (self.concurrent) wal_mod.awaitDeferred() catch {};
            return err;
        };
        self.store_mutex.unlock();
        if (self.concurrent) {
            wal_mod.awaitDeferred() catch |err| {
                // The change is in memory but its journal record is not
                // known to be on disk: say so instead of acknowledging it.
                self.alloc.free(response.body);
                response = self.jsonResponse(500, "Internal Server Error", "{\"error\":\"WAL fsync failed; write not acknowledged\"}") catch return err;
            };
        }
        defer self.alloc.free(response.body);

        var header_buf: [512]u8 = undefined;
        const header = std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
            .{ response.status, response.status_text, response.content_type, response.body.len },
        ) catch return;
        _ = std.c.write(fd, header.ptr, header.len);
        _ = std.c.write(fd, response.body.ptr, response.body.len);
    }

    const Response = struct {
        status: u16,
        status_text: []const u8,
        content_type: []const u8,
        body: []u8,

        /// `body` is allocated per response, so every in-process caller has
        /// to hand it back. This test never did — the leak only surfaced
        /// once the file's tests were actually in the gate.
        pub fn deinit(self: Response, alloc: Allocator) void {
            alloc.free(self.body);
        }
    };

    fn route(self: *Server, method: []const u8, path: []const u8, full_request: []const u8) !Response {
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            return .{
                .status = 200,
                .status_text = "OK",
                .content_type = "text/html; charset=utf-8",
                .body = try self.alloc.dupe(u8, WEB_INDEX),
            };
        }
        if (std.mem.eql(u8, path, "/healthz")) {
            return try self.jsonResponse(200, "OK",
                \\{"status":"ok","version":"0.1.0-alpha"}
            );
        }
        if (std.mem.eql(u8, path, "/metrics")) {
            const body = try self.metrics.render(self.alloc, self.boot_time_ns, self.store);
            return .{ .status = 200, .status_text = "OK", .content_type = "text/plain; charset=utf-8", .body = body };
        }
        if (std.mem.eql(u8, path, "/api/memcells") and std.mem.eql(u8, method, "GET")) {
            return try self.handleListMemcells();
        }
        if (std.mem.eql(u8, path, "/api/memcells") and std.mem.eql(u8, method, "POST")) {
            return try self.handleAddMemcell(full_request);
        }
        if (std.mem.startsWith(u8, path, "/api/memcells/") and std.mem.eql(u8, method, "GET")) {
            const id_str = path["/api/memcells/".len..];
            const id = std.fmt.parseInt(u64, id_str, 10) catch 0;
            return try self.handleGetMemcell(id);
        }
        if (std.mem.eql(u8, path, "/api/goals") and std.mem.eql(u8, method, "GET")) {
            return try self.handleListGoals();
        }
        if (std.mem.eql(u8, path, "/api/query") and std.mem.eql(u8, method, "POST")) {
            return try self.handleQuery(full_request);
        }
        if (std.mem.eql(u8, path, "/api/sync") and std.mem.eql(u8, method, "POST")) {
            return try self.handleSync();
        }
        if (std.mem.eql(u8, path, "/api/forget") and std.mem.eql(u8, method, "POST")) {
            return try self.handleForget(full_request);
        }
        return try self.textResponse(404, "Not Found", "404 not found\n");
    }

    fn handleSync(self: *Server) !Response {
        if (self.store.wal) |wal| {
            wal.flush() catch |err| {
                return try self.jsonResponse(500, "Internal Server Error",
                    try std.fmt.allocPrint(self.alloc, "{{\"error\":\"flush failed: {s}\"}}", .{@errorName(err)}));
            };
            // After WAL is durable, take a snapshot + truncate WAL so
            // next boot replays from snapshot (fast) instead of replaying
            // every WAL record (slow for long-lived daemons).
            //
            // `sync()` owns the whole tail: snapshot, flush, truncate, and
            // — the step this handler was missing when it had its own
            // store — re-journal goals and hyperedges into the fresh WAL.
            // The snapshot does not carry goals, so skipping that
            // re-journal is exactly what used to delete every user goal.
            self.store.sync() catch |err| {
                return try self.jsonResponse(500, "Internal Server Error",
                    try std.fmt.allocPrint(self.alloc, "{{\"error\":\"snapshot failed: {s}\"}}", .{@errorName(err)}));
            };
            self.logger.event(.info, "sync", "snapshot taken and WAL rotated", .{});
            return try self.jsonResponse(200, "OK",
                \\{"status":"synced","wal":true,"snapshot":true}
            );
        }
        // No WAL → persistence was never enabled for this server. The
        // contract is honest: don't claim a sync that didn't happen.
        return try self.jsonResponse(503, "Service Unavailable",
            \\{"error":"persistence not enabled (no WAL)","wal":false}
        );
    }

    /// `POST /api/forget` — run one forgetting sweep on demand.
    ///
    /// **Preview by default.** With no body, or without an explicit
    /// `"dry_run":false`, nothing is deleted: the response reports how many
    /// cells *would* move to the fuzzy store. Deleting memories is the one
    /// thing this daemon cannot be asked to undo (the fuzzy store is
    /// in-process and not WAL-journaled), so the destructive call has to be
    /// written down in the request rather than inferred from its absence:
    ///
    ///     curl -X POST http://127.0.0.1:7777/api/forget                      # preview
    ///     curl -X POST -d '{"dry_run":false}' .../api/forget                # actually forget
    ///
    /// A preview is not counted in `mem3_forgotten_cells_total` — see
    /// `sweepLocked`. `sweepLocked`, not `runForgetSweep`: `handleConn`
    /// holds `store_mutex` around `route`, so locking again here would
    /// deadlock every future request on the first `POST /api/forget`.
    fn handleForget(self: *Server, full_request: []const u8) !Response {
        // No "\r\n\r\n" means no request block at all (an in-process caller
        // passing a bare body, or an empty POST) — the body is then empty,
        // not `full_request[4..]`, which would slice past the end.
        const body = if (std.mem.indexOf(u8, full_request, "\r\n\r\n")) |at|
            full_request[at + 4 ..]
        else
            "";

        const dry_run = extractJsonBool(body, "dry_run") orelse true;
        const res = self.sweepLocked(dry_run) catch |err| {
            const msg = @errorName(err);
            const err_body = try std.fmt.allocPrint(self.alloc, "{{\"error\":\"sweep failed: {s}\"}}", .{msg});
            defer self.alloc.free(err_body);
            return try self.jsonResponse(500, "Internal Server Error", err_body);
        };

        // `jsonResponse` copies, so the formatted body is ours to free.
        const out = try std.fmt.allocPrint(
            self.alloc,
            "{{\"dry_run\":{s},\"fuzzied\":{d},\"kept\":{d},\"archived\":{d}}}",
            .{ if (dry_run) "true" else "false", res.fuzzied, res.kept, res.archived },
        );
        defer self.alloc.free(out);
        return try self.jsonResponse(200, "OK", out);
    }

    fn handleListMemcells(self: *Server) !Response {
        const cells = try self.store.allCells(self.alloc);
        defer self.alloc.free(cells);

        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.alloc);
        try body.appendSlice(self.alloc, "[");
        for (cells, 0..) |cell, i| {
            if (i > 0) try body.append(self.alloc, ',');
            try jsonAppendCell(self.alloc, &body, cell);
        }
        try body.append(self.alloc, ']');
        return self.rawJson(200, try body.toOwnedSlice(self.alloc));
    }

    fn handleGetMemcell(self: *Server, id: u64) !Response {
        const cell = self.store.cell_index.get(id) orelse {
            return try self.jsonResponse(404, "Not Found", "{\"error\":\"not found\"}");
        };
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.alloc);
        try jsonAppendCell(self.alloc, &body, cell);
        return self.rawJson(200, try body.toOwnedSlice(self.alloc));
    }

    fn handleAddMemcell(self: *Server, full_request: []const u8) !Response {
        const body_start = std.mem.findPos(u8, full_request, 0, "\r\n\r\n") orelse 0;
        const body = full_request[body_start + 4 ..];

        const source_str = try extractJsonStringOrOwned(self.alloc, body, "source", "matter");
        defer self.alloc.free(source_str);
        const source = core.MemorySource.fromString(source_str) catch return try self.jsonResponse(400, "Bad Request", "{\"error\":\"invalid source\"}");
        const episode = try extractJsonStringOrOwned(self.alloc, body, "episode", "");
        defer self.alloc.free(episode);
        if (episode.len == 0) return try self.jsonResponse(400, "Bad Request", "{\"error\":\"episode required\"}");
        const facts = try extractJsonStringOrOwned(self.alloc, body, "facts", "");
        defer self.alloc.free(facts);
        const goal_id = @as(u64, @intCast(extractJsonInt(body, "goalId") orelse 1));
        const relevance = extractJsonFloat(body, "relevance") orelse 0.5;

        // Optional `"foresight":[{"description":..,"valid_from":..,
        // "valid_until":..,"confidence":..}]`, the same shape the WAL
        // record carries. A malformed field is a 400, not a cell that
        // quietly lost its foresight.
        const foresight = mem3_store.parseForesightField(self.alloc, body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseFailed => return try self.jsonResponse(400, "Bad Request", "{\"error\":\"invalid foresight\"}"),
        };
        defer mem3_store.freeForesight(self.alloc, foresight);

        var superseded: std.ArrayList(mem3_store.Supersession) = .empty;
        defer mem3_store.freeSupersessions(self.alloc, &superseded);
        const id = self.store.addRawReporting(source, episode, facts, goal_id, relevance, foresight, &superseded) catch |err| {
            // `jsonResponse` copies its body, so the formatted message is
            // ours to free. It was not, and every refused insert leaked it.
            const err_body = try std.fmt.allocPrint(self.alloc, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
            defer self.alloc.free(err_body);
            return try self.jsonResponse(400, "Bad Request", err_body);
        };
        _ = self.metrics.inserts_total.fetchAdd(1, .monotonic);

        var resp: std.ArrayList(u8) = .empty;
        errdefer resp.deinit(self.alloc);
        try resp.print(self.alloc, "{{\"id\":{d}", .{id});
        // Additive: only present when this insert replaced an older fact.
        if (superseded.items.len > 0) {
            try resp.appendSlice(self.alloc, ",\"superseded\":");
            try mem3_store.appendSupersededJson(self.alloc, &resp, superseded.items);
        }
        try resp.append(self.alloc, '}');
        return self.rawJson(201, try resp.toOwnedSlice(self.alloc));
    }

    /// `GET /api/goals` — the real goals from the in-memory poset.
    ///
    /// This used to be a hardcoded three-element literal (`general`,
    /// `research`, `system`) that never consulted the store, so any goal
    /// created outside that literal — via `mem3 goal create`, which is
    /// WAL-journaled and replayed on boot — was invisible here. Names and
    /// descriptions are user input, so every string goes through the JSON
    /// escaper: a goal named `a"b` could otherwise emit invalid JSON.
    fn handleListGoals(self: *Server) !Response {
        var body = std.ArrayList(u8).empty;
        errdefer body.deinit(self.alloc);
        const w = ListWriter{ .list = &body, .gpa = self.alloc };
        try w.writeAll("{\"goals\":[");
        var first = true;
        var it = self.store.goals.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            // The ⊥/⊤ anchors are poset structure, not user-facing goals.
            if (node.id == ghw_goal_tree.ROOT_GOAL_ID) continue;
            if (node.id == ghw_goal_tree.TOP_GOAL_ID) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"id\":");
            try w.print("{d}", .{node.id});
            try w.writeAll(",\"name\":");
            try jsonl.writeJsonString(w, node.name);
            try w.writeAll(",\"description\":");
            try jsonl.writeJsonString(w, node.description);
            try w.writeAll(",\"status\":");
            try w.print("\"{s}\"", .{@tagName(node.status)});
            try w.writeAll(",\"priority\":");
            try w.print("{d}", .{node.priority});
            try w.writeAll(",\"parent_id\":");
            if (node.parent_id) |pid| {
                try w.print("{d}", .{pid});
            } else {
                try w.writeAll("null");
            }
            try w.writeAll(",\"memcell_count\":");
            try w.print("{d}", .{self.store.goals.memcellsFor(node.id).len});
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        return self.rawJson(200, try body.toOwnedSlice(self.alloc));
    }

    fn handleQuery(self: *Server, full_request: []const u8) !Response {
        const body_start = std.mem.findPos(u8, full_request, 0, "\r\n\r\n") orelse 0;
        const body = full_request[body_start + 4 ..];

        const text = try extractJsonStringOrOwned(self.alloc, body, "text", "");
        defer self.alloc.free(text);
        if (text.len == 0) return try self.jsonResponse(400, "Bad Request", "{\"error\":\"text required\"}");
        const topk = @as(usize, @intCast(extractJsonInt(body, "topk") orelse 10));
        // `maxHops` used to be parsed and thrown away on the floor — the
        // daemon's private Store had no hypergraph, so there was nothing to
        // expand. It shares the library Store now, so the parameter means
        // something. Clamped: the traversal is breadth-first over every edge
        // of every reachable node, so an unbounded value is a cheap way to
        // ask the daemon to materialise the whole graph.
        const hops_raw = extractJsonInt(body, "maxHops") orelse 3;
        const max_hops: u8 = @intCast(std.math.clamp(hops_raw, 0, 8));
        // Per-hop relevance decay for graph expansion. Tuned so one hop
        // keeps a graph hit competitive with a mid-ranked dense hit and
        // three hops (the default) still surface something, while a cell
        // four hops out cannot displace a direct semantic match.
        const graph_decay: f32 = 0.6;

        _ = self.metrics.queries_total.fetchAdd(1, .monotonic);
        const t0 = nowNs();

        const qvec = try self.store.emb.embed(self.alloc, text);
        defer self.alloc.free(qvec);

        // Superseded cells are history, not answers: dropped unless the body
        // says `"includeSuperseded":true`, with the over-fetch to match.
        const include_superseded = extractJsonBool(body, "includeSuperseded") orelse false;
        const extra = if (include_superseded) 0 else @min(self.store.superseded_live, topk * 3);
        const dense = self.store.hnsw.search(self.alloc, qvec, topk * 3 + extra) catch &.{};
        defer self.alloc.free(dense);

        var cands = std.ArrayList(RerankContext.Pair).empty;
        defer cands.deinit(self.alloc);
        // GHW re-rank via the shared reranker so the daemon and
        // `mem3 query` cannot drift apart. This path previously carried
        // its own two-factor copy with no recency term.
        var rr = RerankContext{
            .alloc = self.alloc,
            .cfg = self.store.lc.cfg,
            .goals = self.store.goals,
            .query_goal_ids = &.{},
        };
        var it = self.store.cell_index.iterator();
        while (it.next()) |entry| {
            const cell = entry.value_ptr.*;
            if (!include_superseded and cell.metadata.superseded_at != null) continue;
            var score: f32 = 0.0;
            var found = false;
            for (dense) |r| {
                if (r.id == cell.id) {
                    score = r.score;
                    found = true;
                    break;
                }
            }
            if (!found) continue;
            try cands.append(self.alloc, .{
                .id = cell.id,
                .score = score,
                .cell = cell,
            });
        }

        // Graph expansion. Seeds are the dense hits; a cell reachable over
        // hyperedges inherits the strongest path's score times
        // `graph_decay` per hop, so it competes on relevance instead of
        // arriving at 0.0.
        //
        // That distinction is the whole point. An earlier wiring pushed
        // graph nodes into the pool at score 0, which made `maxHops`
        // unobservable no matter what: the reranker is a *multiplicative*
        // bonus on the dense score, and `out_n = min(topk, reranked.len)`
        // truncates to exactly `topk` whenever the corpus is at least that
        // big — so a zero-score cell could never reach the response.
        if (max_hops > 0 and dense.len > 0) {
            var seeds = std.ArrayList(@import("../hypermem/mod.zig").HyMem.ScoredNode).empty;
            defer seeds.deinit(self.alloc);
            try seeds.ensureTotalCapacity(self.alloc, dense.len);
            for (dense) |r| try seeds.append(self.alloc, .{ .id = r.id, .score = r.score, .hops = 0 });

            const reached = self.store.multiHopScored(self.alloc, seeds.items, max_hops, graph_decay, 0.0, null) catch &.{};
            // `&.{}` is a static empty slice — never hand that to `free`.
            defer if (reached.len > 0) self.alloc.free(reached);

            // Bounded so a dense hypergraph cannot turn one query into an
            // unbounded allocation.
            const graph_cap = @max(topk * 4, 64);
            var added: usize = 0;
            for (reached) |g| {
                if (g.hops == 0) continue; // already a dense hit
                if (added >= graph_cap) break;
                var dup = false;
                for (cands.items) |existing| {
                    if (existing.id == g.id) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                const cell = self.store.getCell(g.id) orelse continue;
                if (!include_superseded and cell.metadata.superseded_at != null) continue;
                try cands.append(self.alloc, .{ .id = g.id, .score = g.score, .cell = cell });
                added += 1;
            }
        }

        const reranked = rr.rerankPairs(self.alloc, cands.items) catch |err| {
            const msg = @errorName(err);
            return try self.jsonResponse(500, "Internal Server Error", try std.fmt.allocPrint(self.alloc, "{{\"error\":\"{s}\"}}", .{msg}));
        };
        defer self.alloc.free(reranked);

        const out_n = @min(topk, reranked.len);
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "{\"results\":[");
        for (reranked[0..out_n], 0..) |r, i| {
            if (i > 0) try out.append(self.alloc, ',');
            const cell = r.cell;
            try out.append(self.alloc, '{');
            try jsonFieldInt(self.alloc, &out, "id", cell.id);
            try out.append(self.alloc, ',');
            try jsonFieldString(self.alloc, &out, "source", @tagName(cell.source));
            try out.append(self.alloc, ',');
            try jsonFieldString(self.alloc, &out, "episode", cell.episode);
            try out.append(self.alloc, ',');
            try jsonFieldFloat(self.alloc, &out, "score", r.final_score);
            try out.append(self.alloc, ',');
            try out.appendSlice(self.alloc, "\"goals\":[");
            for (cell.goal_associations, 0..) |ga, j| {
                if (j > 0) try out.append(self.alloc, ',');
                try out.append(self.alloc, '{');
                try jsonFieldInt(self.alloc, &out, "id", ga.goal_id);
                try out.append(self.alloc, ',');
                try jsonFieldFloat(self.alloc, &out, "relevance", ga.relevance);
                try out.append(self.alloc, '}');
            }
            try out.appendSlice(self.alloc, "]");
            try out.append(self.alloc, '}');
        }
        try out.appendSlice(self.alloc, "]}");

        const t1 = nowNs();
        const us: u64 = @intCast(@divTrunc(t1 - t0, 1000));
        _ = self.metrics.last_query_us.store(us, .monotonic);
        // Alongside the single-value gauge: the gauge says what the
        // last request cost, the histogram says what the distribution
        // looks like. No allocator on this path — `record` is two
        // atomic increments.
        self.metrics.latency.record(us);

        return self.rawJson(200, try out.toOwnedSlice(self.alloc));
    }

    fn serveFile(_: *Server, path: []const u8, content_type: []const u8) !Response {
        // v0.1.0-alpha: web UI is embedded via @embedFile (single binary).
        // This stub is kept for forward-compatibility with dynamic content.
        _ = path;
        _ = content_type;
        return .{ .status = 404, .status_text = "Not Found", .content_type = "text/plain", .body = @constCast("404") };
    }

    fn jsonResponse(self: *Server, status: u16, status_text: []const u8, body: []const u8) !Response {
        return .{
            .status = status,
            .status_text = status_text,
            .content_type = "application/json",
            .body = try self.alloc.dupe(u8, body),
        };
    }

    fn textResponse(self: *Server, status: u16, status_text: []const u8, body: []const u8) !Response {
        return .{
            .status = status,
            .status_text = status_text,
            .content_type = "text/plain; charset=utf-8",
            .body = try self.alloc.dupe(u8, body),
        };
    }

    fn rawJson(_: *Server, status: u16, body: []u8) Response {
        return .{
            .status = status,
            .status_text = if (status < 300) "OK" else if (status < 400) "Created" else "Bad Request",
            .content_type = "application/json",
            .body = body,
        };
    }
};

/// Resolve a bind address: "127.0.0.1" / "localhost" → loopback,
/// "0.0.0.0" / "all" → INADDR_ANY, anything else parsed as IPv4 dotted-quad.
/// Returns a u32 in network byte order (big-endian).
fn parseBindAddr(text: []const u8) !u32 {
    if (std.mem.eql(u8, text, "localhost")) return std.mem.nativeToBig(u32, 0x7F000001);
    if (std.mem.eql(u8, text, "all") or std.mem.eql(u8, text, "0.0.0.0")) return 0;

    var octets: [4]u8 = undefined;
    var octet_idx: u8 = 0;
    var accum: u32 = 0;
    var saw_digit = false;
    for (text) |ch| {
        if (ch == '.') {
            if (!saw_digit) return error.InvalidIpv4;
            if (octet_idx >= 3) return error.InvalidIpv4; // too many dots
            octets[octet_idx] = @intCast(accum);
            octet_idx += 1;
            accum = 0;
            saw_digit = false;
            continue;
        }
        if (ch < '0' or ch > '9') return error.InvalidIpv4;
        accum = accum * 10 + (ch - '0');
        if (accum > 255) return error.InvalidIpv4;
        saw_digit = true;
    }
    if (!saw_digit or octet_idx != 3) return error.InvalidIpv4;
    octets[octet_idx] = @intCast(accum);
    return std.mem.nativeToBig(u32, (@as(u32, octets[0]) << 24) | (@as(u32, octets[1]) << 16) | (@as(u32, octets[2]) << 8) | octets[3]);
}

// =============================================================================
// Tiny JSON utilities (avoid pulling in std.json for the hot API path).
// =============================================================================

/// JSON-string unescape. Walks `input` (which is between two unescaped
/// `"` characters) and produces the raw string value. Handles:
/// `\"` `\\` `\/` `\n` `\r` `\t` `\b` `\f` and `\uXXXX` (UTF-8 encoded).
/// Returns an owned slice; caller frees.
fn unescapeJsonString(alloc: Allocator, input: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];
        if (ch != '\\') {
            try out.append(alloc, ch);
            i += 1;
            continue;
        }
        if (i + 1 >= input.len) break;
        const esc = input[i + 1];
        switch (esc) {
            '"' => try out.append(alloc, '"'),
            '\\' => try out.append(alloc, '\\'),
            '/' => try out.append(alloc, '/'),
            'n' => try out.append(alloc, '\n'),
            'r' => try out.append(alloc, '\r'),
            't' => try out.append(alloc, '\t'),
            'b' => try out.append(alloc, 0x08),
            'f' => try out.append(alloc, 0x0C),
            'u' => {
                if (i + 6 > input.len) {
                    // Truncated \u — emit the raw 2 chars and stop.
                    try out.appendSlice(alloc, input[i..]);
                    i = input.len;
                    break;
                }
                const hex = input[i + 2 .. i + 6];
                const cp = std.fmt.parseInt(u21, hex, 16) catch {
                    // Malformed escape: pass through raw.
                    try out.appendSlice(alloc, input[i..][0..2]);
                    i += 2;
                    continue;
                };
                var buf: [4]u8 = undefined;
                const n = utf8Encode(cp, &buf);
                try out.appendSlice(alloc, buf[0..n]);
                i += 6;
                continue;
            },
            else => try out.append(alloc, esc),
        }
        i += 2;
    }
    return out.toOwnedSlice(alloc);
}

/// UTF-8 encode a Unicode scalar value (up to 0x10FFFF) into `dest`.
/// Returns the number of bytes written (1..4).
/// UTF-8 encode a Unicode scalar value (up to 0x10FFFF) into `dest`.
/// Returns the number of bytes written (1..4). Rejects surrogate halves
/// (0xD800-0xDFFF) and out-of-range code points — they would produce
/// invalid UTF-8 that downstream JSON parsers reject.
fn utf8Encode(cp: u21, dest: *[4]u8) usize {
    if (cp < 0x80) {
        dest[0] = @intCast(cp);
        return 1;
    } else if (cp >= 0xD800 and cp <= 0xDFFF) {
        // Surrogate half. Emit a replacement char (U+FFFD) and bail.
        dest[0] = 0xEF;
        dest[1] = 0xBF;
        dest[2] = 0xBD;
        return 3;
    } else if (cp < 0x800) {
        dest[0] = @intCast(0xC0 | (cp >> 6));
        dest[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        dest[0] = @intCast(0xE0 | (cp >> 12));
        dest[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dest[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        dest[0] = @intCast(0xF0 | (cp >> 18));
        dest[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        dest[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dest[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

/// Like `extractJsonString` but always returns an owned, heap-allocated
/// slice. Missing field → `default` is duped. Caller frees.
fn extractJsonStringOrOwned(alloc: Allocator, body: []const u8, key: []const u8, default: []const u8) ![]u8 {
    if (try extractJsonString(alloc, body, key)) |s| return s;
    return try alloc.dupe(u8, default);
}

fn extractJsonString(alloc: Allocator, body: []const u8, key: []const u8) !?[]u8 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const idx = std.mem.findPos(u8, body, 0, needle) orelse return null;
    var pos = idx + needle.len;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) : (pos += 1) {}
    if (pos >= body.len or body[pos] != '"') return null;
    pos += 1;
    const start = pos;
    // Walk to terminating unescaped quote. Manual pos management: a
    // backslash escapes the *next* byte (any byte, even another `\`).
    while (pos < body.len) {
        if (body[pos] == '\\') {
            // Skip the backslash AND the next byte. If the next byte
            // would land past the end, bail.
            if (pos + 1 >= body.len) return null;
            pos += 2;
            continue;
        }
        if (body[pos] == '"') break;
        pos += 1;
    }
    if (pos >= body.len) return null;
    // Allocate + unescape. Caller owns the returned slice.
    return try unescapeJsonString(alloc, body[start..pos]);
}

fn extractJsonInt(body: []const u8, key: []const u8) ?i64 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const idx = std.mem.findPos(u8, body, 0, needle) orelse return null;
    var pos = idx + needle.len;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) : (pos += 1) {}
    const start = pos;
    while (pos < body.len and (body[pos] >= '0' and body[pos] <= '9' or body[pos] == '-' or body[pos] == '+')) : (pos += 1) {}
    if (start == pos) return null;
    return std.fmt.parseInt(i64, body[start..pos], 10) catch null;
}

/// Parse a JSON number (int or float) into f32. Walks the number body
/// from extractJsonInt's find, then parses with std.fmt.parseFloat which
/// handles decimals, signs, and exponents.
fn extractJsonFloat(body: []const u8, key: []const u8) ?f32 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const idx = std.mem.findPos(u8, body, 0, needle) orelse return null;
    var pos = idx + needle.len;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) : (pos += 1) {}
    const start = pos;
    while (pos < body.len and (body[pos] >= '0' and body[pos] <= '9' or
        body[pos] == '-' or body[pos] == '+' or body[pos] == '.' or
        body[pos] == 'e' or body[pos] == 'E')) : (pos += 1) {}
    if (start == pos) return null;
    return std.fmt.parseFloat(f32, body[start..pos]) catch null;
}

/// Parse a JSON boolean. Mirrors `extractJsonInt`: find the key, skip
/// whitespace, match the literal. Anything else (`"dry_run":1`, a string,
/// a missing key) returns null, and the caller decides the default.
fn extractJsonBool(body: []const u8, key: []const u8) ?bool {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":", .{key}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const idx = std.mem.findPos(u8, body, 0, needle) orelse return null;
    var pos = idx + needle.len;
    while (pos < body.len and (body[pos] == ' ' or body[pos] == '\t')) : (pos += 1) {}
    if (std.mem.startsWith(u8, body[pos..], "true")) return true;
    if (std.mem.startsWith(u8, body[pos..], "false")) return false;
    return null;
}

/// JSON-escaped string field (used by WAL payload encoding).
/// Full escape coverage: \", \\, \/, \n, \r, \t, \b, \f, and \uXXXX.
fn jsonFieldStringRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try out.append(alloc, '"');
    for (key) |kc| try out.append(alloc, kc);
    try out.appendSlice(alloc, "\":\"");
    for (value) |vc| {
        switch (vc) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            8 => try out.appendSlice(alloc, "\\b"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            12 => try out.appendSlice(alloc, "\\f"),
            0...7, 11, 14...31 => {
                var buf: [8]u8 = undefined;
                // SAFETY: this prong bounds vc to 0...31, so "{x:0>4}" always
                // emits exactly 4 hex digits. "\uXXXX" is 6 bytes; buf is 8.
                const s = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{vc}) catch unreachable;
                try out.appendSlice(alloc, s);
            },
            else => try out.append(alloc, vc),
        }
    }
    try out.append(alloc, '"');
}

fn jsonFieldInt(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: u64) !void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value }) catch return error.NoSpaceLeft;
    try out.appendSlice(alloc, s);
}

fn jsonFieldFloat(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: f32) !void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d:.4}", .{ key, value }) catch return error.NoSpaceLeft;
    try out.appendSlice(alloc, s);
}

fn jsonAppendCell(alloc: Allocator, out: *std.ArrayList(u8), cell: *const MemCell) !void {
    try out.append(alloc, '{');
    try jsonFieldInt(alloc, out, "id", cell.id);
    try out.append(alloc, ',');
    try jsonFieldString(alloc, out, "source", @tagName(cell.source));
    try out.append(alloc, ',');
    try jsonFieldString(alloc, out, "episode", cell.episode);
    try out.append(alloc, ',');
    try jsonFieldFloat(alloc, out, "importance", cell.metadata.importance_score);
    try out.append(alloc, ',');
    try jsonFieldInt(alloc, out, "created_at", @intCast(@divTrunc(cell.metadata.created_at, 1000)));
    try out.append(alloc, ',');
    try out.appendSlice(alloc, "\"facts\":[");
    for (cell.atomic_facts, 0..) |f, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.append(alloc, '{');
        try jsonFieldString(alloc, out, "s", f.subject);
        try out.append(alloc, ',');
        try jsonFieldString(alloc, out, "p", f.predicate);
        try out.append(alloc, ',');
        try jsonFieldString(alloc, out, "o", f.object);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "]");
    // Additive: a cell without foresight lists `[]`, as `dump` does.
    try out.appendSlice(alloc, ",\"foresight\":[");
    for (cell.foresight, 0..) |f, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.append(alloc, '{');
        try jsonFieldString(alloc, out, "description", f.description);
        try out.append(alloc, ',');
        var tmp: [160]u8 = undefined;
        const tail = try std.fmt.bufPrint(
            &tmp,
            "\"valid_from\":{d},\"valid_until\":{d},\"confidence\":{d:.4}}}",
            .{ f.valid_from, f.valid_until, f.confidence },
        );
        try out.appendSlice(alloc, tail);
    }
    try out.append(alloc, ']');
    try out.append(alloc, '}');
}

// =============================================================================
// Tests
// =============================================================================

test "Server: healthz route" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();
    // No directory cleanup: Zig 0.17 moved `std.fs.cwd`/`deleteTree`, and
    // `/tmp` is the OS's to reap. Matches the convention in store.zig.
    const resp = try srv.route("GET", "/healthz", "");
    defer resp.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "ok") != null);
}

test "Server: sync re-journals goals so it cannot delete them" {
    // Regression guard for a data-destroying bug, kept even though the
    // daemon now shares the library Store and the specific cause is gone.
    //
    // What happened: the daemon carried a private ~890-line `Store` fork
    // whose replay loop knew about `goal_create` but not `goal_update`.
    // `POST /api/sync` truncated the WAL after snapshotting, and the
    // snapshot carries only (counter, cells, fuzzy) — no goals — so every
    // user goal, and its non-default status, was destroyed by one sync.
    // Reproduced end to end before the fix.
    //
    // The fork is gone, so the bug cannot recur in that shape. The guard
    // stays because the property is real and cheap to hold: the snapshot
    // format still does not carry goals, so anything that truncates the
    // WAL still has to re-journal them. `Store.sync()` is the only writer,
    // and this asserts it end to end through the HTTP handler.
    const alloc = std.testing.allocator;
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/mem3_rejournal_{d}", .{std.c.getpid()});

    var srv = try Server.init(alloc, "127.0.0.1", 0, dir);
    defer {
        srv.deinit();
    }

    const gid = srv.store.goals.create(
        "rejournal-probe",
        "must survive a sync",
        null,
        6,
        null,
        1_700_000_000_000,
        &srv.store.ids,
    ) catch |err| {
        std.log.warn("goal create failed: {s}", .{@errorName(err)});
        return err;
    };
    try srv.store.goals.updateStatus(gid, .completed, 1_700_000_000_000);
    try srv.store.sync();

    // Reopen against the same directory: a fresh process would do
    // exactly this after a restart.
    var srv2 = try Server.init(alloc, "127.0.0.1", 0, dir);
    defer srv2.deinit();

    const resp = try srv2.route("GET", "/api/goals", "");
    defer alloc.free(resp.body);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "rejournal-probe") != null);
    // `goal_create` carries no status, so a goal left at .completed
    // only reads back correctly if the status record was re-emitted too.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "completed") != null);
}

test "Server: GET /api/goals reflects the live poset, not a fixed literal" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer {
        srv.deinit();
    }

    // Seeded goals must be present.
    const before = try srv.route("GET", "/api/goals", "");
    defer alloc.free(before.body);
    try std.testing.expectEqual(@as(u16, 200), before.status);
    try std.testing.expect(std.mem.indexOf(u8, before.body, "general") != null);

    // The regression guard: the old implementation returned a hardcoded
    // literal, so ANY goal outside that literal proves we are now
    // reading the store. The name contains a quote and non-ASCII on
    // purpose — it must survive JSON escaping intact.
    const tricky_name = "e2e-quote\"and-中文";
    var slot: std.atomic.Value(u64) = .init(4242);
    _ = srv.store.goals.create(tricky_name, "desc with \\ backslash", null, 8, null, 0, &slot) catch |err| {
        std.log.warn("goal create failed: {s}", .{@errorName(err)});
        return err;
    };

    const after = try srv.route("GET", "/api/goals", "");
    defer alloc.free(after.body);

    // Parses as JSON at all — the old builder would not have.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, after.body, .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("goals").?.array;
    var found = false;
    for (arr.items) |item| {
        const o = item.object;
        if (std.mem.eql(u8, o.get("name").?.string, tricky_name)) {
            found = true;
            try std.testing.expectEqual(@as(i64, 8), o.get("priority").?.integer);
            try std.testing.expect(o.get("description") != null);
            try std.testing.expect(o.get("status") != null);
            try std.testing.expect(o.get("parent_id") != null);
        }
    }
    try std.testing.expect(found);
}

test "Server: POST /api/query maxHops actually expands over the hypergraph" {
    // Regression guard for a parameter that was parsed and thrown away:
    // `extractJsonInt(body, "maxHops") orelse 3` with the result discarded,
    // because the daemon's private Store carried no hypergraph at all. The
    // daemon now shares the library Store, so the knob is wired — and this
    // test exists so "wired" cannot quietly become "parsed and discarded"
    // a second time.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const anchor = try srv.store.addRaw(.matter, "kubernetes ingress controller rollout", "", 0, 0.0);
    const island = try srv.store.addRaw(.matter, "pottery glaze chemistry firing curve", "", 0, 0.0);

    // The corpus has to be big enough that the dense search *cannot* return
    // everything: `handleQuery` asks for `topk * 3` = 30 candidates, so a
    // 2-cell store returns both and the test proves nothing. These fillers
    // are deliberately unrelated to the query text.
    var filler_i: usize = 0;
    while (filler_i < 80) : (filler_i += 1) {
        var buf: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "unrelated filler document number {d} about medieval shipbuilding records", .{filler_i});
        _ = try srv.store.addRaw(.matter, text, "", 0, 0.0);
    }

    // The whole point: `island` shares no vocabulary with the query, so the
    // dense search will not surface it. Only the hyperedge connects them.
    const nodes = try alloc.dupe(u64, &[_]u64{ anchor, island });
    _ = try srv.store.addHyperedge(.{
        .id = 0,
        .edge_type = .associative,
        .nodes = nodes,
        .weight = 0.5,
        .source_weights = .{ 1.0, 0.0, 0.0 },
        .confidence = 1.0,
        .created_at = 0,
        .metadata = null,
    });
    alloc.free(nodes);

    const callQuery = struct {
        fn f(s: *Server, a: Allocator, hops: i64) ![]i64 {
            var req: [160]u8 = undefined;
            // `handleQuery` splits the body off at "\r\n\r\n"; with no
            // header block it falls back to offset 0 and slices from +4,
            // so a bare JSON body would arrive missing its first 4 bytes.
            const body = try std.fmt.bufPrint(&req, "\r\n\r\n{{\"text\":\"kubernetes ingress\",\"maxHops\":{d}}}", .{hops});
            const resp = try s.route("POST", "/api/query", body);
            defer a.free(resp.body);
            if (resp.status != 200) return error.QueryFailed;
            const parsed = try std.json.parseFromSlice(std.json.Value, a, resp.body, .{});
            defer parsed.deinit();
            var ids = std.ArrayList(i64).empty;
            errdefer ids.deinit(a);
            for (parsed.value.object.get("results").?.array.items) |item| {
                try ids.append(a, item.object.get("id").?.integer);
            }
            return ids.toOwnedSlice(a);
        }
    }.f;

    const zero = try callQuery(srv, alloc, 0);
    defer alloc.free(zero);
    const one = try callQuery(srv, alloc, 1);
    defer alloc.free(one);

    const want: i64 = @intCast(island);
    var island_in_zero = false;
    for (zero) |id| {
        if (id == want) island_in_zero = true;
    }
    var island_in_one = false;
    for (one) |id| {
        if (id == want) island_in_one = true;
    }

    try std.testing.expect(!island_in_zero);
    try std.testing.expect(island_in_one);
}

// =============================================================================
// WAL payload helpers
// =============================================================================

/// JSON-escaped string field: "key":"escaped value".
fn jsonFieldString(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try out.append(alloc, '"');
    for (key) |kc| try out.append(alloc, kc);
    try out.appendSlice(alloc, "\":\"");
    for (value) |vc| {
        switch (vc) {
            '"' => try out.appendSlice(alloc, "\\\""), // \" (2 bytes)
            '\\' => try out.appendSlice(alloc, "\\\\"), // \\ (2 bytes)
            8 => try out.appendSlice(alloc, "\\b"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            12 => try out.appendSlice(alloc, "\\f"),
            0...7, 11, 14...31 => {
                var buf: [8]u8 = undefined;
                // SAFETY: this prong bounds vc to 0...31, so "{x:0>4}" always
                // emits exactly 4 hex digits. "\uXXXX" is 6 bytes; buf is 8.
                const s = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{vc}) catch unreachable;
                try out.appendSlice(alloc, s);
            },
            else => try out.append(alloc, vc),
        }
    }
    try out.append(alloc, '"');
}

fn jsonFieldUintRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: u64) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value }) catch return error.NoSpaceLeft;
    try out.appendSlice(alloc, s);
}

fn jsonFieldFloatRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: f32) !void {
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d:.6}", .{ key, value }) catch return error.NoSpaceLeft;
    try out.appendSlice(alloc, s);
}

fn jsonFieldIntRaw(alloc: Allocator, out: *std.ArrayList(u8), key: []const u8, value: i64) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\"{s}\":{d}", .{ key, value }) catch return error.NoSpaceLeft;
    try out.appendSlice(alloc, s);
}

const ParsedInsert = struct {
    id: u64,
    source: MemorySource,
    /// Owned (heap-allocated, unescaped) string fields. Free via deinit.
    episode: []u8,
    facts: []u8,
    goal_id: u64,
    relevance: f32,
    /// Persisted metadata. Restored verbatim on replay so Principle III
    /// ranking (decay × importance × coherence) is stable across boots.
    metadata: core.Metadata,

    pub fn deinit(self: *const ParsedInsert, alloc: Allocator) void {
        alloc.free(self.episode);
        alloc.free(self.facts);
    }
};

/// Parse a JSON payload of shape { id, source, episode, facts, goal_id, relevance, ...meta }.
/// Metadata fields are optional — older WAL records (pre-metadata) parse
/// to zero-valued defaults, which still yields a working cell with
/// created_at=0 (i.e., very old, low weight) so it's distinguishable
/// from a fresh insert.
///
/// On parse failure (corrupt payload, missing required field) returns
/// `error.ParseFailed`. All partial heap allocations are released via
/// errdefer chain — no leaks. Caller distinguishes "bad record, skip"
/// from "out of memory" via the error code.
///
/// WAL upgrade note (B3): records from before the "id" field was added
/// are not silently dropped. A synthetic id is generated from the
/// record's offset in the WAL file so the cell survives the upgrade.
fn parseInsertPayload(alloc: Allocator, payload: []const u8, synthetic_id_fallback: u64) ParseError!ParsedInsert {
    // Id: prefer the persisted field; fall back to a synthetic value if
    // the record predates the "id" field. Negative id is a real error.
    const id_opt = extractJsonInt(payload, "id");
    const id: u64 = if (id_opt) |id_i| blk: {
        if (id_i < 0) return error.ParseFailed;
        break :blk @intCast(id_i);
    } else blk: {
        // Pre-id record. Use the synthetic id from the caller (1B +
        // u64 counter, guaranteed nonneg).
        break :blk synthetic_id_fallback;
    };
    return try parseInsertPayloadFromId(alloc, payload, id);
}

fn parseInsertPayloadFromId(alloc: Allocator, payload: []const u8, id: u64) ParseError!ParsedInsert {

    const source_str = try extractJsonStringOrOwned(alloc, payload, "source", "matter");
    errdefer alloc.free(source_str);
    const source = core.MemorySource.fromString(source_str) catch return error.ParseFailed;
    const episode = try extractJsonStringOrOwned(alloc, payload, "episode", "");
    errdefer alloc.free(episode);
    if (episode.len == 0) return error.ParseFailed;
    const facts = try extractJsonStringOrOwned(alloc, payload, "facts", "");
    errdefer alloc.free(facts);
    const goal_id_i: i64 = extractJsonInt(payload, "goal_id") orelse extractJsonInt(payload, "goalId") orelse 1;
    if (goal_id_i < 0) return error.ParseFailed;
    const goal_id: u64 = @intCast(goal_id_i);
    const relevance_f: f32 = extractJsonFloat(payload, "relevance") orelse 0.5;

    // Metadata fields. Missing fields → 0 (for ints) / 0.0 (for floats) /
    // defaults for derived values. A future enhancement could persist
    // the encoder's source_confidence default (1.0) here, but 0.0 is
    // safe because the manager rejects cells with source_confidence
    // below 0.5 at *encode* time — at *replay* time the cell is already
    // proven valid, so we accept the lower bound.
    const created_at = extractJsonInt(payload, "created_at") orelse 0;
    const updated_at = extractJsonInt(payload, "updated_at") orelse created_at;
    const last_accessed_at = extractJsonInt(payload, "last_accessed_at") orelse created_at;
    const importance_score = extractJsonFloat(payload, "importance_score") orelse 0.5;
    const coherence_score = extractJsonFloat(payload, "coherence_score") orelse 0.0;
    const decay_rate = extractJsonFloat(payload, "decay_rate") orelse 0.01;
    const source_confidence = extractJsonFloat(payload, "source_confidence") orelse 1.0;
    const emotional_valence = extractJsonFloat(payload, "emotional_valence") orelse 0.0;
    const access_count_i = extractJsonInt(payload, "access_count") orelse 0;
    const access_count: u64 = if (access_count_i < 0) 0 else @intCast(access_count_i);

    const metadata = core.Metadata{
        .created_at = created_at,
        .updated_at = updated_at,
        .source_confidence = source_confidence,
        .emotional_valence = emotional_valence,
        .location = null,
        .access_count = access_count,
        .last_accessed_at = last_accessed_at,
        .coherence_score = coherence_score,
        .importance_score = importance_score,
        .decay_rate = decay_rate,
        .is_fuzzy = false,
        .superseded_at = null,
    };

    return .{
        .id = id,
        .source = source,
        .episode = episode,
        .facts = facts,
        .goal_id = goal_id,
        .relevance = relevance_f,
        .metadata = metadata,
    };
}

const ParseError = error{ ParseFailed, OutOfMemory };

// =============================================================================
// Maintenance thread
// =============================================================================

test "Server: maintain marks an aged childless goal unrealized" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const now = nowMs();
    const gid = srv.store.goals.create("orphan", "no memories", null, 5, null, now - 30 * 86_400_000, &srv.store.ids) catch |err| {
        std.log.warn("goal create failed: {s}", .{@errorName(err)});
        return err;
    };

    const res = try srv.runMaintenanceNow();
    try std.testing.expectEqual(@as(usize, 1), res.goals_unrealized);
    try std.testing.expectEqual(@as(usize, 0), res.goals_failed);
    try std.testing.expectEqual(core.GoalStatus.unrealized, srv.store.goals.get(gid).?.status);

    // Idempotent: a second pass has nothing left to do.
    const again = try srv.runMaintenanceNow();
    try std.testing.expectEqual(@as(usize, 0), again.goals_unrealized);
}

test "Server: maintain leaves a goal that has memories alone" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const now = nowMs();
    const gid = srv.store.goals.create("attached", "has a memory", null, 5, null, now - 30 * 86_400_000, &srv.store.ids) catch |err| {
        std.log.warn("goal create failed: {s}", .{@errorName(err)});
        return err;
    };
    try srv.store.goals.bindMemcell(gid, 4242);

    const res = try srv.runMaintenanceNow();
    try std.testing.expectEqual(@as(usize, 0), res.goals_unrealized);
    try std.testing.expectEqual(core.GoalStatus.pending, srv.store.goals.get(gid).?.status);
}

test "Server: a maintain pass is silent when nothing changed" {
    // A per-pass log line is how a long-lived daemon fills a disk:
    // launchd and systemd capture stdout, so "one line a minute" is
    // ~500MB/year from a daemon with nothing to say. The pass only logs
    // when a transition actually happened, so this asserts the quiet path
    // exists and leaves no output behind.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    _ = srv.store.goals.create("young", "not stale yet", null, 5, null, nowMs(), &srv.store.ids) catch |err| {
        std.log.warn("goal create failed: {s}", .{@errorName(err)});
        return err;
    };
    // If this emitted a log line, the Zig 0.17 test runner would fail the
    // test outright — which is the assertion.
    const res = try srv.runMaintenanceNow();
    try std.testing.expectEqual(@as(usize, 0), res.goals_unrealized);
}

test "Server: maintenance thread starts, ticks, and stops cleanly" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);

    // 1-second interval, and we wait long enough for at least one pass.
    try srv.startMaintenance(1);
    var waited: u32 = 0;
    while (waited < 2500 and srv.metrics.maintenance_passes.load(.monotonic) == 0) : (waited += 10) {
        sleepMs(10);
    }
    try std.testing.expect(srv.metrics.maintenance_passes.load(.monotonic) >= 1);

    // `deinit` must join the thread before freeing the store. If it did
    // not, this is where a use-after-free would land — and under the
    // testing allocator a leak or a double free fails the test.
    srv.deinit();
}

test "Server: concurrent inserts and maintenance passes keep the store coherent" {
    // Both threads take the same mutex the accept loop and the real
    // maintenance thread take. That mirrors production exactly.
    //
    // Note what this does and does not prove: it shows the store stays
    // coherent under contention and that `deinit` joins cleanly. It does
    // NOT prove the absence of a data race — races are not observable by a
    // passing test. The discipline that actually protects `GoalPoset.nodes`
    // (an AutoHashMap whose iterators do not survive a rehash) is that
    // there is exactly ONE lock acquisition point for requests,
    // `handleConn`, so no handler can be added that forgets.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const Writer = struct {
        fn run(s: *Server, n: usize) void {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "concurrent insert {d}", .{i}) catch "concurrent";
                s.store_mutex.lock();
                defer s.store_mutex.unlock();
                _ = s.store.addRaw(.matter, text, "", 0, 0.0) catch {};
            }
        }
    };

    const Maint = struct {
        fn run(s: *Server, rounds: usize) void {
            var r: usize = 0;
            while (r < rounds) : (r += 1) {
                s.store_mutex.lock();
                defer s.store_mutex.unlock();
                _ = s.store.maintain(nowMs()) catch {};
            }
        }
    };

    var t1 = try std.Thread.spawn(.{}, Writer.run, .{ srv, 200 });
    var t2 = try std.Thread.spawn(.{}, Writer.run, .{ srv, 200 });
    var t3 = try std.Thread.spawn(.{}, Maint.run, .{ srv, 200 });

    t1.join();
    t2.join();
    t3.join();

    // Both writers' work landed, and the store is still coherent.
    try std.testing.expectEqual(@as(usize, 400), srv.store.cellCount());
}

test "Server: a fresh daemon does not mark its own built-in goals unrealized" {
    // Regression guard. The three seeded goals were created with
    // `created_at = 0`, which under Constitution III's "no memories for 7
    // days" rule makes them 56 years old the moment the store is built.
    // The first maintenance pass therefore marked all three unrealized —
    // before a single query had been served. Measured: a fresh daemon
    // reported 4 goals unrealized, three of them built-ins that had
    // existed for microseconds.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const res = try srv.runMaintenanceNow();
    try std.testing.expectEqual(@as(usize, 0), res.goals_unrealized);
    const seeded = [_][]const u8{ "general", "research", "system" };
    for (seeded) |name| {
        var found = false;
        var it = srv.store.goals.nodes.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.*.name, name)) {
                found = true;
                try std.testing.expectEqual(core.GoalStatus.pending, e.value_ptr.*.status);
            }
        }
        try std.testing.expect(found);
    }
}

// =============================================================================
// Metrics — Constitution Principle VII observability
// =============================================================================

/// Pull the numeric value of `name` out of a Prometheus exposition
/// body; `null` when the metric is absent. Test helper only.
///
/// Matches the name as a whole token, so asking for
/// `mem3_memstore_cells` does not answer with the value of
/// `mem3_memstore_cells_by_source`, and skips `# HELP` / `# TYPE`
/// lines rather than parsing them as samples.
fn metricValue(body: []const u8, name: []const u8) ?f64 {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, name)) continue;
        var rest = line[name.len..];
        if (rest.len == 0) continue;
        if (rest[0] != ' ' and rest[0] != '{') continue;
        // Step over a label set if one is present.
        if (rest[0] == '{') {
            const close = std.mem.indexOfScalar(u8, rest, '}') orelse continue;
            rest = rest[close + 1 ..];
        }
        return std.fmt.parseFloat(f64, std.mem.trim(u8, rest, " \r")) catch null;
    }
    return null;
}

test "Metrics: histogram buckets are half-open and land on the right index" {
    // The classic off-by-one lives here: if the boundary lands in the
    // bucket below, every percentile silently halves.
    //
    // Bucket i covers [2^i, 2^(i+1) - 1]. Both edges are asserted for
    // several i, because the lower edge and the upper edge are the two
    // places an off-by-one can hide.
    try std.testing.expectEqual(@as(usize, 0), LatencyHistogram.bucketIndexFor(0));
    try std.testing.expectEqual(@as(usize, 0), LatencyHistogram.bucketIndexFor(1));
    try std.testing.expectEqual(@as(usize, 1), LatencyHistogram.bucketIndexFor(2)); // first µs of bucket 1
    try std.testing.expectEqual(@as(usize, 1), LatencyHistogram.bucketIndexFor(3)); // last µs of bucket 1
    try std.testing.expectEqual(@as(usize, 2), LatencyHistogram.bucketIndexFor(4)); // first µs of bucket 2
    try std.testing.expectEqual(@as(usize, 6), LatencyHistogram.bucketIndexFor(100));
    try std.testing.expectEqual(@as(usize, 6), LatencyHistogram.bucketIndexFor(127)); // last µs of bucket 6
    try std.testing.expectEqual(@as(usize, 7), LatencyHistogram.bucketIndexFor(128)); // first µs of bucket 7

    // Upper bounds, hand-computed: 2^(i+1) - 1.
    try std.testing.expectEqual(@as(u64, 1), LatencyHistogram.bucketUpperBound(0));
    try std.testing.expectEqual(@as(u64, 3), LatencyHistogram.bucketUpperBound(1));
    try std.testing.expectEqual(@as(u64, 127), LatencyHistogram.bucketUpperBound(6));
    try std.testing.expectEqual(@as(u64, 8388607), LatencyHistogram.bucketUpperBound(22)); // 16.8s-ish
    // 10s = 1e7µs must be representable inside the histogram: it is
    // bucket 23, which tops out at 33.5s.
    try std.testing.expect(LatencyHistogram.bucketIndexFor(10_000_000) <= LATENCY_BUCKET_COUNT - 1);
    try std.testing.expect(LatencyHistogram.bucketUpperBound(LatencyHistogram.bucketIndexFor(10_000_000)) >= 10_000_000);

    // The top bucket saturates instead of overflowing: an absurd sample
    // is clamped into it, and the bound is representable.
    try std.testing.expectEqual(LATENCY_BUCKET_COUNT - 1, LatencyHistogram.bucketIndexFor(std.math.maxInt(u64)));
    try std.testing.expectEqual(std.math.maxInt(u64), LatencyHistogram.bucketUpperBound(LATENCY_BUCKET_COUNT - 1));
}

test "Metrics: percentile returns the containing bucket's upper bound" {
    // Hand-computed against the bucket layout, not a golden string.
    //
    // Samples → bucket: 1→0 [1], 2→1 [2,3], 3→1, 100→6 [64,127],
    // 101→6, 5000→12 [4096,8191], 8000000→22 [4194304,8388607].
    // n = 7.
    //   p50: rank = ceil(7·0.50) = 4 → cumulative 1, 3, 5 at b6 → 127.
    //   p95: rank = ceil(7·0.95) = 7 → only the last sample → 8388607.
    //   p99: same, 8388607.
    var h: LatencyHistogram = .{};
    for ([_]u64{ 1, 2, 3, 100, 101, 5000, 8_000_000 }) |us| h.record(us);

    try std.testing.expectEqual(@as(u64, 7), h.sampleCount());
    try std.testing.expectEqual(@as(u64, 127), h.percentile(50, 100));
    try std.testing.expectEqual(@as(u64, 8388607), h.percentile(95, 100));
    try std.testing.expectEqual(@as(u64, 8388607), h.percentile(99, 100));

    // Conservative means never under-reported: p50 of these samples is
    // ~100µs, and what comes back is the containing bucket's ceiling.
    try std.testing.expect(h.percentile(50, 100) >= 100);

    // p0 (rank 1) is the first sample's bucket, i.e. the fast path is
    // reported as its own bucket rather than collapsing to 0.
    try std.testing.expectEqual(@as(u64, 1), h.percentile(0, 100));

    // One sample: every percentile collapses onto that sample's bucket.
    var one: LatencyHistogram = .{};
    one.record(64); // first µs of bucket 6
    try std.testing.expectEqual(@as(u64, 127), one.percentile(50, 100));
    try std.testing.expectEqual(@as(u64, 127), one.percentile(99, 100));
}

test "Metrics: an empty histogram reports zero instead of dividing by zero" {
    var h: LatencyHistogram = .{};
    try std.testing.expectEqual(@as(u64, 0), h.sampleCount());
    try std.testing.expectEqual(@as(u64, 0), h.percentile(50, 100));
    try std.testing.expectEqual(@as(u64, 0), h.percentile(95, 100));
    try std.testing.expectEqual(@as(u64, 0), h.percentile(99, 100));
    // A zero denominator is the same failure from the other side.
    try std.testing.expectEqual(@as(u64, 0), h.percentile(50, 0));
}

test "Metrics: /metrics publishes all six constitutional families" {
    // Constitution Principle VII names six things the daemon must
    // publish: request count, retrieval P50/P95/P99, memstore size,
    // vector index depth, hyperedge count, forgetting rate. This
    // asserts the names exist and each is documented — a metric
    // without HELP/TYPE is half-published.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const resp = try srv.route("GET", "/metrics", "");
    defer resp.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    const required = [_][]const u8{
        "mem3_requests_total",
        "mem3_retrieval_latency_p50_us",
        "mem3_retrieval_latency_p95_us",
        "mem3_retrieval_latency_p99_us",
        "mem3_retrieval_latency_samples_total",
        "mem3_memstore_cells",
        "mem3_memstore_cells_by_source",
        "mem3_hyperedges",
        "mem3_vector_index_depth",
        "mem3_forgetting_rate",
    };
    for (required) |name| {
        try std.testing.expect(std.mem.indexOf(u8, resp.body, name) != null);
        // HELP line present.
        var help_buf: [160]u8 = undefined;
        const help_line = std.fmt.bufPrint(&help_buf, "# HELP {s} ", .{name}) catch return error.NoSpaceLeft;
        try std.testing.expect(std.mem.indexOf(u8, resp.body, help_line) != null);
        // TYPE line present and correctly typed.
        var type_buf: [160]u8 = undefined;
        const type_line = std.fmt.bufPrint(&type_buf, "# TYPE {s} ", .{name}) catch return error.NoSpaceLeft;
        const at = std.mem.indexOf(u8, resp.body, type_line) orelse return error.MissingMetricType;
        const kind = std.mem.trim(u8, resp.body[at + type_line.len ..][0..7], "\r\n");
        const is_counter = std.mem.eql(u8, kind, "counter");
        // Convention: anything named `_total` is a counter, everything
        // else is a gauge. A regression here would make a scraper
        // alert on a rate() over a gauge that only moves while the
        // process lives.
        const should_be_counter = std.mem.endsWith(u8, name, "_total");
        try std.testing.expectEqual(should_be_counter, is_counter);
    }

    // One line per MemorySource variant, not a hand-maintained subset.
    for (std.enums.values(MemorySource)) |src| {
        var label_buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&label_buf, "mem3_memstore_cells_by_source{{source=\"{s}\"}} ", .{@tagName(src)}) catch return error.NoSpaceLeft;
        try std.testing.expect(std.mem.indexOf(u8, resp.body, line) != null);
    }

    // A fresh daemon has served no queries: the percentiles must read
    // zero, not garbage from an empty histogram.
    try std.testing.expectEqual(@as(f64, 0), metricValue(resp.body, "mem3_retrieval_latency_p50_us").?);
    try std.testing.expectEqual(@as(f64, 0), metricValue(resp.body, "mem3_retrieval_latency_samples_total").?);
    // No sweep has run, so the rate is a defined zero rather than a
    // division by zero.
    try std.testing.expectEqual(@as(f64, 0), metricValue(resp.body, "mem3_forgetting_rate").?);
    // Empty HNSW index: -1, distinct from "a node on the base layer".
    try std.testing.expectEqual(@as(f64, -1), metricValue(resp.body, "mem3_vector_index_depth").?);
    try std.testing.expectEqual(@as(f64, 0), metricValue(resp.body, "mem3_vector_index_nodes").?);
}

test "Metrics: live gauges track the store, not a constant" {
    // The failure mode this guards is a metric wired to a literal: it
    // renders, it parses, it is always the same number. So capture the
    // exposition, mutate the store through the documented HTTP route,
    // capture again, and assert the numbers moved.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const before = try srv.route("GET", "/metrics", "");
    defer before.deinit(alloc);
    const cells_before = metricValue(before.body, "mem3_memstore_cells").?;
    const form_before = metricValue(before.body, "mem3_memstore_cells_by_source{source=\"form\"}").?;
    const nodes_before = metricValue(before.body, "mem3_vector_index_nodes").?;

    // `handleAddMemcell` slices the body off at "\r\n\r\n"; with no
    // header block it falls back to offset 0 and drops the first 4
    // bytes, so a bare JSON body would arrive corrupted. Same trick as
    // the maxHops query test.
    var req: [256]u8 = undefined;
    const post = std.fmt.bufPrint(&req, "\r\n\r\n{{\"source\":\"form\",\"episode\":\"metrics wiring probe\",\"facts\":\"\",\"goalId\":1,\"relevance\":0.5}}", .{}) catch unreachable;
    const inserted = try srv.route("POST", "/api/memcells", post);
    defer inserted.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 201), inserted.status);

    const after = try srv.route("GET", "/metrics", "");
    defer after.deinit(alloc);

    try std.testing.expectEqual(cells_before + 1, metricValue(after.body, "mem3_memstore_cells").?);
    try std.testing.expectEqual(form_before + 1, metricValue(after.body, "mem3_memstore_cells_by_source{source=\"form\"}").?);
    // Other sources are untouched, so the total cannot be coming from a
    // single hardcoded line.
    try std.testing.expectEqual(@as(f64, 0), metricValue(after.body, "mem3_memstore_cells_by_source{source=\"spirit\"}").?);
    // The insert also goes into the vector index.
    try std.testing.expect(nodes_before + 1 <= metricValue(after.body, "mem3_vector_index_nodes").?);
    try std.testing.expect(metricValue(after.body, "mem3_vector_index_depth").? >= 0);

    // Hyperedge count is live too: an insert adds none, and adding one
    // through the store moves the gauge.
    try std.testing.expectEqual(@as(f64, 0), metricValue(after.body, "mem3_hyperedges").?);
    const pair = try alloc.dupe(u64, &[_]u64{ 1, 2 });
    defer alloc.free(pair);
    _ = try srv.store.addHyperedge(.{
        .id = 0,
        .edge_type = .associative,
        .nodes = pair,
        .weight = 0.5,
        .source_weights = .{ 1.0, 0.0, 0.0 },
        .confidence = 1.0,
        .created_at = 0,
        .metadata = null,
    });
    const after_edge = try srv.route("GET", "/metrics", "");
    defer after_edge.deinit(alloc);
    try std.testing.expectEqual(@as(f64, 1), metricValue(after_edge.body, "mem3_hyperedges").?);
}

test "Metrics: forgetting counters accumulate and the rate follows them" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    srv.recordForgetSweep(.{ .fuzzied = 3, .kept = 7, .archived = 0 });
    srv.recordForgetSweep(.{ .fuzzied = 5, .kept = 5, .archived = 0 });

    const resp = try srv.route("GET", "/metrics", "");
    defer resp.deinit(alloc);
    try std.testing.expectEqual(@as(f64, 8), metricValue(resp.body, "mem3_forgotten_cells_total").?);
    try std.testing.expectEqual(@as(f64, 20), metricValue(resp.body, "mem3_forgetting_swept_total").?);
    try std.testing.expectEqual(@as(f64, 0.4), metricValue(resp.body, "mem3_forgetting_rate").?);
}

test "Metrics: query latency is recorded into the histogram" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    _ = try srv.store.addRaw(.matter, "latency probe corpus entry about shipbuilding", "", 0, 0.0);

    var req: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&req, "\r\n\r\n{{\"text\":\"shipbuilding\",\"maxHops\":0}}", .{}) catch unreachable;
    const resp = try srv.route("POST", "/api/query", body);
    defer resp.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    // The histogram saw exactly the one query. Zero queries before
    // this is what makes the count meaningful rather than incidental.
    try std.testing.expectEqual(@as(u64, 1), srv.metrics.latency.sampleCount());
    try std.testing.expect(srv.metrics.latency.percentile(99, 100) > 0);
}

// =============================================================================
// Scheduled forgetting — Constitution Principle III, actually running
// =============================================================================

/// Seed `n` cells whose existence contribution is below
/// `forgetting_threshold` (0.1), so the very first sweep drops them.
///
/// The contribution is `importance * exp(-decay_rate * age_days)`; with a
/// brand-new cell the decay term is 1.0, so setting importance is enough
/// and the test does not have to backdate anything.
fn seedForgettable(srv: *Server, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var buf: [64]u8 = undefined;
        const episode = try std.fmt.bufPrint(&buf, "ephemeral observation {d}", .{i});
        const id = try srv.store.addRaw(.matter, episode, "", 1, 0.1);
        srv.store.getCell(id).?.metadata.importance_score = 0.001;
    }
}

/// Seed `n` cells at the encoder's default importance (above 0.3), which
/// the existence-gain rule keeps. These are the cells a sweep must NOT
/// touch.
fn seedDurable(srv: *Server, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var buf: [64]u8 = undefined;
        const episode = try std.fmt.bufPrint(&buf, "durable observation {d}", .{i});
        _ = try srv.store.addRaw(.form, episode, "", 1, 0.5);
    }
}

test "Server: the scheduled sweep forgets, and mem3_forgotten_cells_total moves" {
    // This is the test that was impossible before the daemon had a call
    // site for `store.forget`: the three forgetting metrics were
    // published, HELP-documented and structurally pinned at zero for the
    // whole life of the process. A metric that can never be non-zero is
    // worse than an absent one — it reads as a healthy memory system.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    try seedForgettable(srv, 3);
    try seedDurable(srv, 2);
    try std.testing.expectEqual(@as(usize, 5), srv.store.cellCount());

    // Forget interval is its own knob, independent of the maintenance
    // cadence — here both are 1s only because the test wants both to fire
    // quickly.
    srv.setForgetSchedule(1, false);
    try srv.startMaintenance(1);

    var waited_ms: u32 = 0;
    while (waited_ms < 6000 and srv.metrics.forgotten_cells_total.load(.monotonic) == 0) : (waited_ms += 10) {
        sleepMs(10);
    }

    const forgotten = srv.metrics.forgotten_cells_total.load(.monotonic);
    const swept = srv.metrics.forgetting_swept_total.load(.monotonic);
    // 3 exactly: the scheduled sweep dropped the three qualifying cells.
    // Later sweeps see only the two durable cells and can add nothing, so
    // this stays exact however long the test takes to notice.
    try std.testing.expectEqual(@as(u64, 3), forgotten);
    try std.testing.expect(swept >= 5);
    try std.testing.expectEqual(@as(usize, 2), srv.store.cellCount());

    // And the published rate agrees with the published counters.
    const resp = try srv.route("GET", "/metrics", "");
    defer resp.deinit(alloc);
    const rate = metricValue(resp.body, "mem3_forgetting_rate").?;
    const pub_forgotten = metricValue(resp.body, "mem3_forgotten_cells_total").?;
    const pub_swept = metricValue(resp.body, "mem3_forgetting_swept_total").?;
    try std.testing.expectEqual(@as(f64, @floatFromInt(forgotten)), pub_forgotten);
    try std.testing.expectApproxEqAbs(pub_forgotten / pub_swept, rate, 1e-6);
    try std.testing.expect(rate > 0);
}

test "Server: forgetting rate is cumulative forgotten over cumulative swept" {
    // The definition, pinned against the existing render(): the rate is a
    // ratio over everything since boot, not a per-sweep rate and not a
    // per-second rate.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    try seedForgettable(srv, 4);
    try seedDurable(srv, 1);

    // Sweep 1: 4 of 5 examined cells drop.
    const first = try srv.runForgetSweep(false);
    try std.testing.expectEqual(@as(usize, 4), first.fuzzied);
    try std.testing.expectEqual(@as(usize, 1), first.kept);

    // Sweep 2: only the durable cell is left, so it is examined and kept.
    const second = try srv.runForgetSweep(false);
    try std.testing.expectEqual(@as(usize, 0), second.fuzzied);
    try std.testing.expectEqual(@as(usize, 1), second.kept);

    const resp = try srv.route("GET", "/metrics", "");
    defer resp.deinit(alloc);
    // 4 forgotten, (4 + 5) examined across the two sweeps.
    try std.testing.expectEqual(@as(f64, 4), metricValue(resp.body, "mem3_forgotten_cells_total").?);
    try std.testing.expectEqual(@as(f64, 6), metricValue(resp.body, "mem3_forgetting_swept_total").?);
    // 4/6, not 4/5 (last sweep only) and not 0.8 — a ratio that silently
    // changed denominator would still look plausible in a dashboard.
    try std.testing.expectApproxEqAbs(@as(f64, 4) / @as(f64, 6), metricValue(resp.body, "mem3_forgetting_rate").?, 1e-6);
}

test "Server: a sweep over a fresh store forgets nothing" {
    // Off-by-one guard on the threshold. A sweep that fires one interval
    // too early, or compares with `<=` instead of `<`, wipes a brand-new
    // corpus — and the daemon now does this on a schedule with nobody
    // watching. A default-importance cell scores ~0.5 against a
    // threshold of 0.1 and must survive.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    // A brand-new daemon has an empty corpus: a zero sweep, and the
    // counters stay at zero rather than reporting a ratio of nothing.
    const empty = try srv.runForgetSweep(false);
    try std.testing.expectEqual(@as(usize, 0), empty.fuzzied);
    try std.testing.expectEqual(@as(usize, 0), empty.kept);
    try std.testing.expectEqual(@as(u64, 0), srv.metrics.forgotten_cells_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), srv.metrics.forgetting_swept_total.load(.monotonic));

    try seedDurable(srv, 1);
    const before = srv.store.cellCount();

    const res = try srv.runForgetSweep(false);
    try std.testing.expectEqual(@as(usize, 0), res.fuzzied);
    try std.testing.expectEqual(@as(usize, 1), res.kept);
    try std.testing.expectEqual(before, srv.store.cellCount());

    // Examined but not forgotten: swept moves, rate stays zero.
    const resp = try srv.route("GET", "/metrics", "");
    defer resp.deinit(alloc);
    try std.testing.expectEqual(@as(f64, 0), metricValue(resp.body, "mem3_forgotten_cells_total").?);
    try std.testing.expectEqual(@as(f64, 1), metricValue(resp.body, "mem3_forgetting_swept_total").?);
    try std.testing.expectEqual(@as(f64, 0), metricValue(resp.body, "mem3_forgetting_rate").?);

    // A second sweep over what is left is a no-op: nothing new qualifies, so
    // no cell is deleted and no cell is spuriously swept either.
    _ = try srv.runForgetSweep(false);
    const res2 = try srv.runForgetSweep(false);
    try std.testing.expectEqual(@as(usize, 0), res2.fuzzied);
    try std.testing.expectEqual(@as(usize, 1), res2.kept);
    try std.testing.expectEqual(@as(usize, 1), srv.store.cellCount());
}

test "Server: a dry run previews the sweep and changes nothing" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    try seedForgettable(srv, 2);
    try seedDurable(srv, 1);
    const before = srv.store.cellCount();

    // In-process preview.
    const preview = try srv.runForgetSweep(true);
    try std.testing.expectEqual(@as(usize, 2), preview.fuzzied);
    try std.testing.expectEqual(before, srv.store.cellCount());
    try std.testing.expectEqual(@as(u64, 0), srv.metrics.forgotten_cells_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), srv.metrics.forgetting_swept_total.load(.monotonic));

    // Same through HTTP, with no body at all: preview is the default,
    // because an unauthenticated POST that deletes is not something to
    // infer from silence.
    const http_preview = try srv.route("POST", "/api/forget", "");
    defer http_preview.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 200), http_preview.status);
    try std.testing.expect(std.mem.indexOf(u8, http_preview.body, "\"dry_run\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, http_preview.body, "\"fuzzied\":2") != null);
    try std.testing.expectEqual(before, srv.store.cellCount());
    try std.testing.expectEqual(@as(u64, 0), srv.metrics.forgotten_cells_total.load(.monotonic));

    // The destructive call has to be written down explicitly.
    const live = try srv.route("POST", "/api/forget", "\r\n\r\n{\"dry_run\":false}");
    defer live.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, live.body, "\"dry_run\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, live.body, "\"fuzzied\":2") != null);
    try std.testing.expectEqual(@as(usize, 1), srv.store.cellCount());

    // Counted exactly once, by the one real sweep: the two previews above
    // contributed nothing to either counter.
    try std.testing.expectEqual(@as(u64, 2), srv.metrics.forgotten_cells_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3), srv.metrics.forgetting_swept_total.load(.monotonic));
}

test "Server: deinit joins the thread with forgetting enabled" {
    // A thread that outlives its store is a use-after-free that happens to
    // work until it doesn't, and the sweep makes the window wide: it holds
    // `store_mutex` while walking every cell.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    // From here on the server is owned by this test and MUST be torn down on
    // every exit path. An early `return` between here and the explicit
    // `deinit` would leave the maintenance thread running against a store
    // nothing will ever free — which does not fail this test, it segfaults
    // whichever test runs next. (Observed, not theorised: this test
    // asserted before it cleaned up, and a failing assertion cascaded into
    // a segfault one test later.)
    var teardown_pending = true;
    errdefer if (teardown_pending) srv.deinit();

    try seedForgettable(srv, 2);
    srv.setForgetSchedule(1, false);
    try srv.startMaintenance(1);

    var waited_ms: u32 = 0;
    while (waited_ms < 6000 and srv.metrics.forgotten_cells_total.load(.monotonic) == 0) : (waited_ms += 10) {
        sleepMs(10);
    }
    const moved = srv.metrics.forgotten_cells_total.load(.monotonic);

    // Joins, then frees the store. Any leak or double free here is the
    // testing allocator's job to report.
    teardown_pending = false;
    srv.deinit();

    // Asserted after the teardown so a regression reports itself instead of
    // poisoning the rest of the binary.
    try std.testing.expect(moved > 0);
}

test "Server: a scheduled dry run forgets nothing" {
    // `mem3 serve --dry-run`: the daemon reports what it would drop and
    // drops nothing, on the schedule, unattended.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    try seedForgettable(srv, 2);
    try seedDurable(srv, 1);
    const before = srv.store.cellCount();

    srv.setForgetSchedule(1, true);
    try srv.startMaintenance(1);

    // Wait for at least two sweeps to have been due.
    var waited_ms: u32 = 0;
    while (waited_ms < 4000 and srv.metrics.maintenance_passes.load(.monotonic) < 3) : (waited_ms += 10) {
        sleepMs(10);
    }
    try std.testing.expectEqual(before, srv.store.cellCount());
    try std.testing.expectEqual(@as(u64, 0), srv.metrics.forgotten_cells_total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), srv.metrics.forgetting_swept_total.load(.monotonic));
}

// =============================================================================
// Daemon forgetting flags
// =============================================================================
//
// The CLI parser tests live in this file rather than next to the flag they
// test. `src/main.zig` names `server/http_server.zig` directly in its
// comptime import block, so tests here are collected by `zig build test`;
// `cli.zig` and `cli_commands/serve.zig` are not named there, and Zig
// registers `test` blocks only for files named directly in the root's
// import graph. A parser test in either of those files compiles, looks
// responsible, and never runs — the exact trap documented at
// `src/main.zig`'s import block. The proper long-term home is
// `tests/unit/cli.zig`, which needs a build.zig module and is not this
// file's to change.

test "cli: daemon forgetting is on by default, hourly" {
    // The default is the whole point. The daemon had no call site for
    // `store.forget`, so every forgetting metric was pinned at zero for the
    // life of the process; defaulting this to "off" would preserve that bug
    // permanently and make it look like a deliberate configuration.
    const alloc = std.testing.allocator;
    var p = try cli.parseSlice(alloc, &[_][]const u8{"serve"});
    defer p.deinit(alloc);
    try std.testing.expectEqual(cli.Subcommand.serve, p.cmd);
    try std.testing.expectEqual(@as(u32, 3600), p.forget_interval_sec);
    try std.testing.expectEqual(DEFAULT_FORGET_INTERVAL_SEC, p.forget_interval_sec);
    try std.testing.expect(!p.dry_run);
}

test "cli: --forget-interval=0 opts out without touching maintenance" {
    const alloc = std.testing.allocator;
    {
        var p = try cli.parseSlice(alloc, &[_][]const u8{ "serve", "--forget-interval=0" });
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 0), p.forget_interval_sec);
        try std.testing.expectEqual(@as(u32, 60), p.maint_interval_sec);
    }
    // Space form resolves to the same field.
    {
        var p = try cli.parseSlice(alloc, &[_][]const u8{ "serve", "--forget-interval", "900" });
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 900), p.forget_interval_sec);
    }
    // A bad value is an error, never a silent fallback to the default.
    {
        const bad = cli.parseSlice(alloc, &[_][]const u8{ "serve", "--forget-interval=abc" });
        if (bad) |parsed| {
            var leaked = parsed;
            defer leaked.deinit(alloc);
            return error.ExpectedInvalidFlagValue;
        } else |err| {
            try std.testing.expectEqual(@as(anyerror, error.InvalidFlagValue), err);
        }
    }
}

test "cli: the forget cadence does not follow --maint-interval" {
    // The failure this pins: turning maintenance down to 1s must not
    // silently produce a 1s forgetting sweep, which walks the whole corpus
    // under the store lock and deletes freshly seeded cells mid-assertion.
    const alloc = std.testing.allocator;
    {
        var p = try cli.parseSlice(alloc, &[_][]const u8{ "serve", "--maint-interval=1", "--forget-interval=3600" });
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 1), p.maint_interval_sec);
        try std.testing.expectEqual(@as(u32, 3600), p.forget_interval_sec);
    }
    // `--maint-interval=0` disables the one background thread, which stops
    // the sweep too. The forget field keeps its own value — it is not
    // dragged to 0 — and `--help` says the sweep stops with the thread.
    {
        var p = try cli.parseSlice(alloc, &[_][]const u8{"serve", "--maint-interval=0"});
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 0), p.maint_interval_sec);
        try std.testing.expectEqual(@as(u32, 3600), p.forget_interval_sec);
    }
    // Neither flag inverts the other.
    {
        var p = try cli.parseSlice(alloc, &[_][]const u8{"serve", "--forget-interval=0", "--maint-interval=5"});
        defer p.deinit(alloc);
        try std.testing.expectEqual(@as(u32, 0), p.forget_interval_sec);
        try std.testing.expectEqual(@as(u32, 5), p.maint_interval_sec);
    }
}

test "cli: --dry-run makes daemon forgetting a preview" {
    const alloc = std.testing.allocator;
    var p = try cli.parseSlice(alloc, &[_][]const u8{ "serve", "--dry-run" });
    defer p.deinit(alloc);
    try std.testing.expect(p.dry_run);
    // The flag is orthogonal: it does not change the cadence.
    try std.testing.expectEqual(@as(u32, 3600), p.forget_interval_sec);
}

test "cli: --forget-interval is documented in help" {
    // An undocumented default-on flag that deletes memories is a trap with
    // no off switch on paper.
    try std.testing.expect(std.mem.indexOf(u8, cli.HELP_TEXT, "--forget-interval") != null);
}

test "Server: /api/forget does not re-enter the store lock it is already holding" {
    // Regression guard for a real hang, found by running the daemon rather
    // than by a test. `handleConn` takes `store_mutex` around `route`, so a
    // handler that takes it again self-deadlocks on a plain pthread mutex:
    // the first `POST /api/forget` froze the process with every subsequent
    // request queued behind it. Every other in-process test here calls
    // `route` directly and therefore never holds the lock — which is
    // exactly why they all passed while the daemon hung.
    //
    // So this one holds the lock the way the accept loop does and calls the
    // handler from another thread. Bounded wait rather than a bare call: if
    // the bug ever comes back the test must FAIL, not hang the runner.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    try seedForgettable(srv, 2);
    try seedDurable(srv, 1);

    const Finished = struct {
        done: std.atomic.Value(bool) = .init(false),
        body: [256]u8 = undefined,
        body_len: usize = 0,

        fn call(s: *Server, target: *@This()) void {
            const resp = s.route("POST", "/api/forget", "\r\n\r\n{\"dry_run\":false}") catch {
                target.done.store(true, .release);
                return;
            };
            defer resp.deinit(s.alloc);
            @memcpy(target.body[0..resp.body.len], resp.body);
            target.body_len = resp.body.len;
            target.done.store(true, .release);
        }
    };
    var finished = Finished{};
    srv.store_mutex.lock();
    const t = try std.Thread.spawn(.{}, Finished.call, .{ srv, &finished });

    var waited_ms: u32 = 0;
    while (waited_ms < 3000 and !finished.done.load(.acquire)) : (waited_ms += 10) {
        sleepMs(10);
    }
    const completed = finished.done.load(.acquire);
    srv.store_mutex.unlock();
    t.join();

    if (!completed) return error.ForgetHandlerDeadlockedOnStoreLock;
    try std.testing.expect(std.mem.indexOf(u8, finished.body[0..finished.body_len], "\"fuzzied\":2") != null);
    // The sweep still happened, under the lock the accept loop already held.
    try std.testing.expectEqual(@as(u64, 2), srv.metrics.forgotten_cells_total.load(.monotonic));
}

test "HTTP: POST /api/memcells carries foresight through to the committed cell" {
    // Bodies get the same `\r\n\r\n` prefix trick as the metrics test.
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();

    const post =
        "\r\n\r\n{\"source\":\"spirit\",\"episode\":\"http foresight\",\"facts\":\"\",\"goalId\":1,\"relevance\":0.5," ++
        "\"foresight\":[{\"description\":\"rain \\\"soon\\\"\",\"valid_from\":10,\"valid_until\":20,\"confidence\":0.9}]}";
    const inserted = try srv.route("POST", "/api/memcells", post);
    defer inserted.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 201), inserted.status);

    const id: u64 = @intCast(extractJsonInt(inserted.body, "id").?);
    const cell = srv.store.getCell(id).?;
    try std.testing.expectEqual(@as(usize, 1), cell.foresight.len);
    try std.testing.expectEqualStrings("rain \"soon\"", cell.foresight[0].description);
    try std.testing.expectEqual(@as(i64, 10), cell.foresight[0].valid_from);
    try std.testing.expectEqual(@as(i64, 20), cell.foresight[0].valid_until);

    // And the read side shows it.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/api/memcells/{d}", .{id});
    const got = try srv.route("GET", path, "");
    defer got.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, got.body, "\"foresight\":[{\"description\":\"rain \\\"soon\\\"\",\"valid_from\":10,\"valid_until\":20,\"confidence\":0.9000}]") != null);

    // Malformed foresight is refused rather than dropped.
    const bad_conf =
        "\r\n\r\n{\"source\":\"spirit\",\"episode\":\"x\",\"goalId\":1," ++
        "\"foresight\":[{\"description\":\"d\",\"confidence\":7}]}";
    const r1 = try srv.route("POST", "/api/memcells", bad_conf);
    defer r1.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 400), r1.status);
    const bad_shape = "\r\n\r\n{\"source\":\"spirit\",\"episode\":\"x\",\"goalId\":1,\"foresight\":5}";
    const r2 = try srv.route("POST", "/api/memcells", bad_shape);
    defer r2.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 400), r2.status);
    try std.testing.expectEqual(@as(usize, 1), srv.store.cellCount());
}

// =============================================================================
// Graceful shutdown, group-commit concurrency and daemon logging.
// =============================================================================

fn testFreePort() !u16 {
    const fd = c.socket(c.AF.INET, @bitCast(@as(u32, c.SOCK.STREAM)), 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);
    var addr: std.posix.sockaddr.in = undefined;
    addr.family = c.AF.INET;
    addr.port = 0;
    addr.addr = 0;
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
    var got: std.posix.sockaddr.in = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(got));
    if (c.getsockname(fd, @ptrCast(&got), &len) != 0) return error.GetsocknameFailed;
    return std.mem.bigToNative(u16, got.port);
}

/// One request over a real socket; returns the HTTP status or 0 on a
/// transport failure. The body is discarded: these tests assert on status
/// and on the store.
fn testHttpStatus(port: u16, request: []const u8) u16 {
    var addr: std.posix.sockaddr.in = undefined;
    addr.family = c.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = std.mem.nativeToBig(u32, 0x7F000001);
    const fd = c.socket(c.AF.INET, @bitCast(@as(u32, c.SOCK.STREAM)), 0);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return 0;
    var sent: usize = 0;
    while (sent < request.len) {
        const n = c.write(fd, request[sent..].ptr, request.len - sent);
        if (n <= 0) return 0;
        sent += @intCast(n);
    }
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    // "HTTP/1.1 201 Created"
    if (total < 12) return 0;
    return std.fmt.parseInt(u16, buf[9..12], 10) catch 0;
}

fn testPost(port: u16, episode: []const u8) u16 {
    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"source\":\"matter\",\"episode\":\"{s}\",\"facts\":\"\",\"goalId\":1,\"relevance\":0.5}}", .{episode}) catch return 0;
    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "POST /api/memcells HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return 0;
    return testHttpStatus(port, req);
}

const ServeRunner = struct {
    srv: *Server,
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,
    fn run(self: *ServeRunner) void {
        self.srv.serve() catch |e| {
            self.err = e;
        };
        self.done.store(true, .release);
    }
};

fn testDataDir(buf: []u8, label: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "/tmp/mem3_srv_{d}_{s}", .{ c.getpid(), label }) catch unreachable;
}

fn testWipe(dir: []const u8) void {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    inline for (.{ "mem3.wal", "snapshot.bin" }) |f| {
        if (std.fmt.bufPrint(&z, "{s}/" ++ f ++ "\x00", .{dir})) |p| {
            _ = c.unlink(p[0 .. p.len - 1 :0].ptr);
        } else |_| {}
    }
    if (std.fmt.bufPrint(&z, "{s}\x00", .{dir})) |p| {
        _ = c.rmdir(p[0 .. p.len - 1 :0].ptr);
    } else |_| {}
}

test "Server: serve() answers requests, then returns once shutdown is requested" {
    const alloc = std.testing.allocator;
    const port = try testFreePort();
    var srv = try Server.init(alloc, "127.0.0.1", port, null);
    defer srv.deinit();
    try srv.listen();

    var runner = ServeRunner{ .srv = srv };
    const t = try std.Thread.spawn(.{}, ServeRunner.run, .{&runner});

    try std.testing.expectEqual(@as(u16, 200), testHttpStatus(port, "GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"));
    try std.testing.expect(!runner.done.load(.acquire));

    srv.requestShutdown();
    t.join();
    try std.testing.expect(runner.done.load(.acquire));
    try std.testing.expectEqual(@as(?anyerror, null), runner.err);
}

test "Server: group mode acknowledges concurrent POSTs only after they are durable, and loses none" {
    const alloc = std.testing.allocator;
    var db: [96]u8 = undefined;
    const dir = testDataDir(&db, "grp_http");
    testWipe(dir);
    defer testWipe(dir);

    const THREADS = 4;
    const PER = 12;
    {
        const port = try testFreePort();
        var srv = try Server.initWithOptions(alloc, "127.0.0.1", port, .{ .data_dir = dir, .wal_sync = .group });
        defer srv.deinit();
        try srv.listen();
        var runner = ServeRunner{ .srv = srv };
        const st = try std.Thread.spawn(.{}, ServeRunner.run, .{&runner});

        const Client = struct {
            fn run(p: u16, t: usize, ok: *std.atomic.Value(u32)) void {
                for (0..PER) |i| {
                    var ep: [48]u8 = undefined;
                    const text = std.fmt.bufPrint(&ep, "group http cell {d}-{d}", .{ t, i }) catch return;
                    if (testPost(p, text) == 201) _ = ok.fetchAdd(1, .monotonic);
                }
            }
        };
        var ok: std.atomic.Value(u32) = .init(0);
        var ths: [THREADS]std.Thread = undefined;
        for (&ths, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Client.run, .{ port, t, &ok });
        for (ths) |th| th.join();
        try std.testing.expectEqual(@as(u32, THREADS * PER), ok.load(.monotonic));

        // Every acknowledged write is covered by an fsync.
        const ws = srv.store.wal.?.stats();
        try std.testing.expect(ws.appended >= THREADS * PER);
        try std.testing.expectEqual(ws.appended, ws.durable);
        try std.testing.expect(ws.syncs <= ws.appended);
        try std.testing.expectEqual(@as(usize, 0), ws.pending);

        srv.requestShutdown();
        st.join();
        try std.testing.expectEqual(@as(?anyerror, null), runner.err);
    }
    // A restart WITHOUT the flag still reads every record.
    var store = try mem3_store.Store.init(alloc, .{ .data_dir = dir });
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, THREADS * PER), store.cellCount());
}

/// POST that connects first and sends its request only after `delay_ms`,
/// so the server holds an accepted, in-flight connection in the meantime.
fn testSlowPost(port: u16, episode: []const u8, delay_ms: u32) u16 {
    var addr: std.posix.sockaddr.in = undefined;
    addr.family = c.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = std.mem.nativeToBig(u32, 0x7F000001);
    const fd = c.socket(c.AF.INET, @bitCast(@as(u32, c.SOCK.STREAM)), 0);
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return 0;
    sleepMs(delay_ms);
    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"source\":\"matter\",\"episode\":\"{s}\",\"facts\":\"\",\"goalId\":1,\"relevance\":0.5}}", .{episode}) catch return 0;
    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "POST /api/memcells HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return 0;
    if (c.write(fd, req.ptr, req.len) <= 0) return 0;
    var buf: [256]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total < 12) return 0;
    return std.fmt.parseInt(u16, buf[9..12], 10) catch 0;
}

test "Server: shutdown drains an in-flight request instead of dropping it" {
    const alloc = std.testing.allocator;
    var db: [96]u8 = undefined;
    const dir = testDataDir(&db, "drain");
    testWipe(dir);
    defer testWipe(dir);

    const port = try testFreePort();
    var srv = try Server.initWithOptions(alloc, "127.0.0.1", port, .{ .data_dir = dir, .wal_sync = .group });
    defer srv.deinit();
    try srv.listen();
    var runner = ServeRunner{ .srv = srv };
    const st = try std.Thread.spawn(.{}, ServeRunner.run, .{&runner});

    // The client connects, then dawdles for 600 ms before sending: from the
    // server's side an accepted connection is in flight for that long.
    var status: std.atomic.Value(u32) = .init(0);
    const Client = struct {
        fn run(p: u16, out: *std.atomic.Value(u32)) void {
            out.store(testSlowPost(p, "drained insert", 600), .release);
        }
    };
    const ct = try std.Thread.spawn(.{}, Client.run, .{ port, &status });
    while (srv.inflight.load(.acquire) == 0) sleepMs(1);

    srv.requestShutdown();
    sleepMs(250);
    // Still waiting on that connection: a shutdown that does not drain
    // would have returned by now (nothing else is holding it up).
    try std.testing.expect(!runner.done.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), status.load(.acquire));

    ct.join();
    st.join();
    try std.testing.expectEqual(@as(u32, 201), status.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), srv.store.cellCount());
    try std.testing.expectEqual(@as(?anyerror, null), runner.err);
}

test "Server: the periodic summary is one parseable JSON line carrying live numbers" {
    const alloc = std.testing.allocator;
    var sc = try logger_mod.Scratch.open("srv_summary");
    defer sc.close();
    var srv = try Server.initWithOptions(alloc, "127.0.0.1", 0, .{
        .data_dir = null,
        .logger = .{ .mode = .jsonl, .fd = sc.fd },
    });
    defer srv.deinit();

    _ = try srv.store.addRaw(.matter, "summary probe", "", 0, 0.0);
    _ = srv.metrics.inserts_total.fetchAdd(1, .monotonic);
    srv.emitSummary();

    const got = try sc.contents(alloc);
    defer alloc.free(got);
    try std.testing.expect(got.len > 0 and got[got.len - 1] == '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, got[0 .. got.len - 1], .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("summary", obj.get("scope").?.string);
    const msg = obj.get("msg").?.string;
    try std.testing.expect(std.mem.indexOf(u8, msg, "cells=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "inserts=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "uptime_s=") != null);
}

test "Server: a maintenance transition is logged as a JSONL event, and a quiet pass is not" {
    const alloc = std.testing.allocator;
    var sc = try logger_mod.Scratch.open("srv_maint");
    defer sc.close();
    var srv = try Server.initWithOptions(alloc, "127.0.0.1", 0, .{
        .data_dir = null,
        .logger = .{ .mode = .jsonl, .fd = sc.fd },
    });
    defer srv.deinit();

    // Quiet pass: nothing to say, nothing written.
    srv.runMaintenancePass();
    {
        const got = try sc.contents(alloc);
        defer alloc.free(got);
        try std.testing.expectEqual(@as(usize, 0), got.len);
    }

    // An aged, childless goal: the 7-day rule fires.
    const eight_days_ms: i64 = 8 * 24 * 3600 * 1000;
    _ = try srv.store.goals.create("stale", "no memories", null, 5, null, nowMs() - eight_days_ms, &srv.store.ids);
    srv.runMaintenancePass();
    const got = try sc.contents(alloc);
    defer alloc.free(got);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trimEnd(u8, got, "\n"), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("maintenance", parsed.value.object.get("scope").?.string);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.object.get("msg").?.string, "1 goal(s) unrealized") != null);
}

test "Server: the default logger is silent" {
    const alloc = std.testing.allocator;
    var srv = try Server.init(alloc, "127.0.0.1", 0, null);
    defer srv.deinit();
    try std.testing.expect(!srv.logger.enabled());
    // Would write to stderr and kill the test runner if it were not off.
    srv.emitSummary();
    srv.runMaintenancePass();
}
