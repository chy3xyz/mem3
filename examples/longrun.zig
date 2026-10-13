//! mem3-longrun — long-run baseline harness for the memory lifecycle.
//!
//! The question this answers is narrow and testable: **does the system
//! reach a steady state, and what do the per-cycle increments do as it
//! gets there?** Concretely it runs a closed loop of
//!
//!     ingest → (periodic) consolidate → (periodic) forget → sync
//!
//! and records one JSONL line per cycle, so the interesting quantity —
//! `d_cells`, the net change in live cells for that cycle — becomes a
//! curve you can plot.
//!
//! ## Why the output is a file and not stdout
//!
//! A long run is expected to produce tens of thousands of lines. Piping
//! that into a supervised process's stdout is how you fill a disk (this
//! was measured at 1.5 GB/day on another project in this codebase's
//! family). So: silent by default, results go to a JSONL file, and
//! progress goes to stderr on a **time** interval, never on a cycle
//! count. A cycle-count progress trigger never fires in exactly the
//! steady state you are trying to observe — if increments go to zero, a
//! cycle-triggered log goes silent forever and the run looks hung.
//!
//! ## Usage
//!
//!     zig build example-longrun
//!     ./zig-out/bin/mem3-longrun --duration-sec=3600 --data-dir=/tmp/mem3_lr
//!
//! Stopping early is safe: every line already written is durable, and the
//! file is reopened in append mode on the next run with `--append`.

const std = @import("std");
const builtin = @import("builtin");
const mem3 = @import("mem3");

const Allocator = std.mem.Allocator;

const WALL_RULE = "--------------------------------------------------------------";

// ============================================================================
// Corpus
// ============================================================================

/// Topic-clustered sentences. Consolidator runs HAC clustering, and HAC
/// needs something to cluster: feeding it uniformly random text would
/// measure nothing. Each topic shares vocabulary with itself, so clusters
/// exist by construction and the sweep has real work to do.
const TOPICS = [_]struct { name: []const u8, lines: []const []const u8 }{
    .{
        .name = "wal",
        .lines = &.{
            "wal replay reconstructs the cell store after an unclean shutdown",
            "wal append fsyncs every record before the write is acknowledged",
            "wal rotation keeps the log bounded under sustained writes",
            "wal checksum detects corruption in the replayed byte stream",
            "wal recovery semantics depend on append fsync ordering",
        },
    },
    .{
        .name = "hnsw",
        .lines = &.{
            "hnsw insert builds the layered graph incrementally per node",
            "hnsw search descends from the top layer to the candidate set",
            "hnsw beam search parameter tuning trades recall for latency",
            "hnsw neighbour lists grow with m and are bounded by mmax0",
            "hnsw cosine similarity assumes every vector is unit norm",
        },
    },
    .{
        .name = "serialize",
        .lines = &.{
            "serializer comptime size keeps the wire format deterministic",
            "serialize writes every struct field in declared order",
            "deserialize reads fields back in the same declared order",
            "serializer round trip property must hold for every value",
            "deserialize rejects an unknown enum tag rather than guessing",
        },
    },
    .{
        .name = "ontology",
        .lines = &.{
            "the matter source records a causally efficacious trace",
            "the form source extracts atomic facts from the episode",
            "the spirit source predicts with an explicit validity window",
            "three source coherence requires all three dimensions present",
            "tri source ontology forbids a cell missing its spirit dimension",
        },
    },
    .{
        .name = "forget",
        .lines = &.{
            "the forgetting sweep fuzzies low importance cells instead of deleting",
            "fuzzy storage preserves the original under a compressed marker",
            "existence gain drives which cells the sweep is willing to drop",
            "the promote path restores a fuzzied cell back to the active set",
            "forgetting threshold decides when a cell stops earning its keep",
        },
    },
    .{
        .name = "consolidate",
        .lines = &.{
            "consolidation clusters similar cells and emits one abstract",
            "hac clustering uses agglomerative passes over similarity",
            "the abstract inherits the union of its cluster's facts",
            "consolidation must never delete the originals it merged",
            "consolidation threshold decides which clusters actually merge",
        },
    },
};

const FACT_TRIPLES = [_][3][]const u8{
    .{ "wal", "replayed", "n records" },
    .{ "hnsw", "returned", "k candidates" },
    .{ "serializer", "roundtripped", "memcell" },
    .{ "sweep", "fuzzied", "low value cell" },
    .{ "abstract", "merged", "cluster" },
    .{ "coherence", "measured", "three sources" },
};

// ============================================================================
// Parameters
// ============================================================================

const Params = struct {
    cycles: usize = 5_000,
    /// When non-zero, stop after this much wall-clock time instead of
    /// after `cycles`. This is how you run a 24-hour experiment.
    duration_sec: u64 = 0,
    per_cycle: usize = 16,
    seed: u64 = 42,
    consolidate_every: usize = 25,
    forget_every: usize = 10,
    sync_every: usize = 100,
    /// How often to walk every cell for the importance/coherence
    /// distribution. That walk is O(n), so it is sampled rather than
    /// paid every cycle; non-sampling cycles record null.
    stats_every: usize = 5,
    /// Seconds between progress lines on stderr. Time-based on purpose.
    progress_sec: u64 = 300,
    data_dir: []const u8 = "/tmp/mem3_longrun",
    out_path: []const u8 = "longrun.jsonl",
    stdout_jsonl: bool = false,
    append: bool = false,
    /// Overwrite an existing output file. Without it, a non-append run
    /// refuses to clobber, because two harnesses sharing the default
    /// path silently interleave at their own file offsets and produce a
    /// file full of NUL holes.
    force: bool = false,
    dry_data: bool = false,
};

// ============================================================================
// Small POSIX helpers (Zig 0.17 removed most of the std.fs conveniences)
// ============================================================================

fn openZ(alloc: Allocator, path: []const u8, oflag: std.c.O, mode: std.c.mode_t) ?std.c.fd_t {
    const z = std.fmt.allocPrintSentinel(alloc, "{s}\x00", .{path}, 0) catch return null;
    defer alloc.free(z);
    // MUST test the return value explicitly. `std.c.open` yields a plain
    // c_int, and returning it as `?fd_t` under Zig 0.17 does NOT null-ify a
    // negative result — measured: opening a missing file returned the *value*
    // -1, not null. So an earlier `orelse { exit }` here was dead code: a
    // failed open fell through with fd = -1, every subsequent write to it
    // failed, and the old silent `break` in writeAll swallowed that, letting
    // the harness run to completion having written nothing at all.
    const rc = std.c.open(z.ptr, oflag, mode);
    if (rc < 0) return null;
    return rc;
}

fn closeFd(fd: std.c.fd_t) void {
    _ = std.c.close(fd);
}

/// Write every byte, or fail.
///
/// The previous version did `if (n <= 0) break;`, which silently dropped
/// the rest of a record. On a 24h run that produces a JSONL file that is
/// truncated but still well-formed up to the cut — the worst possible
/// failure for a baseline harness, because the missing data stays
/// invisible until someone finally plots the curve. ENOSPC, EDQUOT and
/// EPIPE must end the run loudly instead.
fn writeAll(fd: std.c.fd_t, bytes: []const u8) error{WriteFailed}!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            // A signal during the write is not a failure; retry it.
            if (std.c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        // A zero-length write with bytes remaining would spin forever.
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// True if `path` can be opened for reading. Used as an existence probe
/// without depending on a stat wrapper this codebase may not target.
fn fileExists(alloc: Allocator, path: []const u8) bool {
    const fd = openZ(alloc, path, .{ .ACCMODE = .RDONLY }, 0) orelse return false;
    closeFd(fd);
    return true;
}

/// Resident set size in KB. `ru_maxrss` is bytes on macOS and kilobytes
/// on Linux; normalise so the JSONL column means the same thing
/// everywhere.
fn rssKb() u64 {
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0) return 0;
    const raw: u64 = @intCast(@max(usage.maxrss, 0));
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => raw / 1024,
        else => raw,
    };
}

fn fileSizeKb(alloc: Allocator, path: []const u8) u64 {
    var st: std.c.Stat = undefined;
    const z = std.fmt.allocPrintSentinel(alloc, "{s}\x00", .{path}, 0) catch return 0;
    defer alloc.free(z);
    if (std.c.stat(z.ptr, &st) != 0) return 0;
    const bytes: u64 = @intCast(@max(0, st.size));
    return bytes / 1024;
}

const ClockFn = struct {
    fn nowNs() i128 {
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    }
};

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(std.c.STDOUT_FILENO, s.ptr, s.len);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(std.c.STDERR_FILENO, s.ptr, s.len);
}

// ============================================================================
// Per-cycle statistics
// ============================================================================

const DistStats = struct {
    sampled: bool = false,
    imp_mean: f64 = 0,
    imp_min: f64 = 0,
    imp_max: f64 = 0,
    coh_mean: f64 = 0,
    decay_mean: f64 = 0,
};

/// O(n) walk over the live cells. Sampled, not run every cycle — see
/// `stats_every` in Params.
fn sampleDist(alloc: Allocator, store: *mem3.Store, out_dist: *DistStats) !void {
    const cells = try store.allCells(alloc);
    defer alloc.free(cells);
    if (cells.len == 0) {
        return;
    }

    var imp_sum: f64 = 0;
    var imp_min: f64 = std.math.floatMax(f64);
    var imp_max: f64 = -std.math.floatMax(f64);
    var coh_sum: f64 = 0;
    var decay_sum: f64 = 0;
    for (cells) |cell| {
        const imp: f64 = cell.metadata.importance_score;
        imp_sum += imp;
        if (imp < imp_min) imp_min = imp;
        if (imp > imp_max) imp_max = imp;
        coh_sum += cell.metadata.coherence_score;
        decay_sum += cell.metadata.decay_rate;
    }
    const n: f64 = @floatFromInt(cells.len);
    out_dist.* = .{
        .sampled = true,
        .imp_mean = imp_sum / n,
        .imp_min = imp_min,
        .imp_max = imp_max,
        .coh_mean = coh_sum / n,
        .decay_mean = decay_sum / n,
    };
}

const CycleRecord = struct {
    cycle: u64,
    ingested: usize,
    cells: usize,
    d_cells: i64,
    matter: usize,
    form: usize,
    spirit: usize,
    fuzzy: usize,
    lat_ingest_ns: u64,
    lat_consolidate_ns: u64,
    lat_forget_ns: u64,
    abstracts: usize,
    fuzzied: usize,
    kept: usize,
    dist: DistStats,
};

fn writeRecord(fd: std.c.fd_t, rec: CycleRecord, wal_kb: u64, snap_kb: u64, t_ms: u64) error{ LineTooLong, WriteFailed }!void {
    const d = rec.dist;
    // The optional distribution fields must be rendered BEFORE the main
    // line, into a buffer that outlives the bufPrint call — a helper
    // returning a slice of its own stack buffer would dangle.
    //
    // The selector MUST be the loop index. It used to be `switch (l.*)`,
    // which reads `opt_len[i]` *before* this iteration writes it — i.e.
    // uninitialised stack memory. The four fields therefore came out
    // scrambled: an observed record had imp_mean=0.67944 with
    // imp_min=0.74657 (mean below the minimum) and imp_max=0.00000.
    // A wrong number here is worse than a missing one, because nothing
    // about the output looks broken.
    var opt_buf: [4][32]u8 = undefined;
    var opt_len: [4]usize = undefined;
    for (&opt_buf, &opt_len, 0..) |*b, *l, i| {
        if (d.sampled) {
            const v = switch (i) {
                0 => d.imp_mean,
                1 => d.imp_min,
                2 => d.imp_max,
                else => d.coh_mean,
            };
            // A formatting failure must not render as `null`: that is
            // indistinguishable from "this cycle was not a sample
            // cycle", so the failure would be invisible in the curve.
            // 32 bytes holds far more than any `{d:.5}` f64 can need.
            const s = std.fmt.bufPrint(b, "{d:.5}", .{v}) catch |e| {
                err("longrun: imp field {d} failed to format: {s}\n", .{ i, @errorName(e) });
                return error.LineTooLong;
            };
            l.* = s.len;
        } else {
            @memcpy(b[0..4], "null");
            l.* = 4;
        }
    }

    var line: [1600]u8 = undefined;
    // NOTE: this format string must stay on ONE physical line. A Zig
    // multiline `\\` literal preserves its embedded newlines, which
    // silently turns one record into four and destroys the whole point of
    // a JSONL file. Being long is fine; being pretty is not.
    const s = std.fmt.bufPrint(&line, "{{\"cycle\":{d},\"t_ms\":{d},\"ingested\":{d},\"cells\":{d},\"d_cells\":{d},\"matter\":{d},\"form\":{d},\"spirit\":{d},\"fuzzy\":{d},\"lat_ingest_us\":{d:.2},\"lat_consolidate_us\":{d:.2},\"lat_forget_us\":{d:.2},\"abstracts\":{d},\"fuzzied\":{d},\"kept\":{d},\"wal_kb\":{d},\"snap_kb\":{d},\"rss_kb\":{d},\"imp_mean\":{s},\"imp_min\":{s},\"imp_max\":{s},\"coh_mean\":{s}}}", .{
        rec.cycle,
        t_ms,
        rec.ingested,
        rec.cells,
        rec.d_cells,
        rec.matter,
        rec.form,
        rec.spirit,
        rec.fuzzy,
        @as(f64, @floatFromInt(rec.lat_ingest_ns)) / 1000.0,
        @as(f64, @floatFromInt(rec.lat_consolidate_ns)) / 1000.0,
        @as(f64, @floatFromInt(rec.lat_forget_ns)) / 1000.0,
        rec.abstracts,
        rec.fuzzied,
        rec.kept,
        wal_kb,
        snap_kb,
        rssKb(),
        opt_buf[0][0..opt_len[0]],
        opt_buf[1][0..opt_len[1]],
        opt_buf[2][0..opt_len[2]],
        opt_buf[3][0..opt_len[3]],
    }) catch return error.LineTooLong;
    try writeAll(fd, s);
    try writeAll(fd, "\n");
}

// ============================================================================
// Entry point
// ============================================================================

fn parseArgs(init: std.process.Init.Minimal) !Params {
    var p = Params{};
    var it = std.process.Args.iterate(init.args);
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--stdout-jsonl")) {
            p.stdout_jsonl = true;
        } else if (std.mem.eql(u8, a, "--append")) {
            p.append = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            p.force = true;
        } else if (std.mem.eql(u8, a, "--dry-data")) {
            p.dry_data = true;
        } else if (std.mem.startsWith(u8, a, "--cycles=")) {
            p.cycles = try std.fmt.parseInt(usize, a["--cycles=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--duration-sec=")) {
            p.duration_sec = try std.fmt.parseInt(u64, a["--duration-sec=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--per-cycle=")) {
            p.per_cycle = try std.fmt.parseInt(usize, a["--per-cycle=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--seed=")) {
            p.seed = try std.fmt.parseInt(u64, a["--seed=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--data-dir=")) {
            p.data_dir = a["--data-dir=".len..];
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            p.out_path = a["--out=".len..];
        } else if (std.mem.startsWith(u8, a, "--progress-sec=")) {
            p.progress_sec = try std.fmt.parseInt(u64, a["--progress-sec=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--stats-every=")) {
            p.stats_every = try std.fmt.parseInt(usize, a["--stats-every=".len..], 10);
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            out(
                \\mem3-longrun — closed-loop lifecycle baseline
                \\
                \\  --cycles=N            cycles to run (default 5000)
                \\  --duration-sec=S      stop after S seconds instead (use for 24h runs)
                \\  --per-cycle=N         cells ingested per cycle (default 16)
                \\  --seed=N              PRNG seed; same seed reproduces the run
                \\  --consolidate-every=N default 25
                \\  --forget-every=N      default 10
                \\  --sync-every=N        default 100
                \\  --stats-every=N       sample the importance distribution every N cycles
                \\  --progress-sec=S      stderr progress interval (default 300)
                \\  --data-dir=PATH       default /tmp/mem3_longrun
                \\  --out=PATH            JSONL output (default longrun.jsonl)
                \\  --stdout-jsonl        also stream JSONL to stdout
                \\  --append              append to an existing output file
                \\  --force               overwrite an existing output file (default: refuse)
                \\  --dry-data            in-memory, no WAL
                \\
            , .{});
            std.process.exit(0);
        } else {
            err("unknown argument: {s}\n", .{a});
            std.process.exit(2);
        }
    }
    return p;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const p = parseArgs(init) catch {
        err("longrun: bad arguments\n", .{});
        std.process.exit(2);
    };

    const store = try mem3.Store.init(alloc, .{
        .data_dir = if (p.dry_data) null else p.data_dir,
        .seed_default_goals = true,
    });
    defer store.deinit();

    if (!p.append and !p.force and fileExists(alloc, p.out_path)) {
        err("longrun: {s} already exists — pass --append to extend it, --force to overwrite, or --out=PATH\n", .{p.out_path});
        std.process.exit(2);
    }

    const out_fd = openZ(alloc, p.out_path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = p.append,
        .TRUNC = !p.append,
    }, 0o644) orelse {
        err("longrun: cannot open {s}\n", .{p.out_path});
        std.process.exit(2);
    };
    defer closeFd(out_fd);

    const stdout_fd: std.c.fd_t = if (p.stdout_jsonl) @intCast(std.c.STDOUT_FILENO) else -1;

    var prng = std.Random.DefaultPrng.init(p.seed);
    const rand = prng.random();

    const start_ms = mem3.utils.time.nowMs();
    const t0 = ClockFn.nowNs();
    var last_progress = t0;
    // End timestamp, so the summary can compare the run's wall clock
    // against the age at which forgetting would first trigger.
    var end_ns: i128 = t0;
    // Most recent successful sample, reused by the summary block.
    var last_dist: DistStats = .{};
    var prev_cells: usize = store.cellCount();
    var total_ingested: usize = 0;
    var total_fuzzied: usize = 0;
    var total_abstracts: usize = 0;

    // First-decile accumulators, for the convergence summary.
    const decile = @max(p.cycles / 10, 1);
    var first_decile_d: i64 = 0;
    var last_decile_d: i64 = 0;
    var last_decile_n: usize = 0;

    err("longrun: cycles={d} per_cycle={d} seed={d} stats_every={d} data_dir={s}{s}\n", .{
        p.cycles,
        p.per_cycle,
        p.seed,
        p.stats_every,
        p.data_dir,
        if (p.dry_data) " (in-memory)" else "",
    });
    err("longrun: writing {s}\n", .{p.out_path});

    var cycle: usize = 0;
    while (cycle < p.cycles) : (cycle += 1) {
        if (p.duration_sec > 0 and @divTrunc(ClockFn.nowNs() - t0, 1_000_000_000) >= @as(i128, @intCast(p.duration_sec))) {
            err("longrun: duration reached at cycle {d}\n", .{cycle});
            break;
        }

        // ---- ingest -------------------------------------------------------
        const ci0 = ClockFn.nowNs();
        var ingested: usize = 0;
        var k: usize = 0;
        while (k < p.per_cycle) : (k += 1) {
            const topic = TOPICS[rand.intRangeAtMost(usize, 0, TOPICS.len - 1)];
            const line = topic.lines[rand.intRangeAtMost(usize, 0, topic.lines.len - 1)];
            const triple = FACT_TRIPLES[rand.intRangeAtMost(usize, 0, FACT_TRIPLES.len - 1)];
            const src: mem3.MemorySource = @enumFromInt(@as(u8, @intCast(rand.intRangeAtMost(u8, 0, 2))));
            const facts = try std.fmt.allocPrint(
                alloc,
                "{s}|{s}|{s}",
                .{ triple[0], triple[1], triple[2] },
            );
            defer alloc.free(facts);
            _ = store.addRaw(src, line, facts, 1, 0.3 + rand.float(f32) * 0.7) catch {
                continue;
            };
            ingested += 1;
        }
        const ci1 = ClockFn.nowNs();

        // ---- consolidate / forget ----------------------------------------
        var lat_cons: u64 = 0;
        var abstracts: usize = 0;
        if (p.consolidate_every > 0 and (cycle + 1) % p.consolidate_every == 0) {
            const cc0 = ClockFn.nowNs();
            abstracts = store.consolidate() catch 0;
            const cc1 = ClockFn.nowNs();
            lat_cons = @intCast(cc1 - cc0);
        }

        var lat_forget: u64 = 0;
        var fuzzied: usize = 0;
        var kept: usize = 0;
        if (p.forget_every > 0 and (cycle + 1) % p.forget_every == 0) {
            const cf0 = ClockFn.nowNs();
            if (store.forget(false)) |r| {
                fuzzied = r.fuzzied;
                kept = r.kept;
            } else |_| {}
            const cf1 = ClockFn.nowNs();
            lat_forget = @intCast(cf1 - cf0);
        }

        if (p.sync_every > 0 and (cycle + 1) % p.sync_every == 0) {
            store.sync() catch {};
        }

        // ---- record -------------------------------------------------------
        const cells = store.cellCount();
        const d: i64 = @as(i64, @intCast(cells)) - @as(i64, @intCast(prev_cells));
        prev_cells = cells;
        total_ingested += ingested;
        total_fuzzied += fuzzied;
        total_abstracts += abstracts;

        if (cycle < decile) first_decile_d += d;
        if (cycle >= p.cycles - decile) {
            last_decile_d += d;
            last_decile_n += 1;
        }

        var dist = DistStats{};
        if (p.stats_every > 0 and (cycle % p.stats_every == 0)) {
            sampleDist(alloc, store, &dist) catch |e| {
                // Previously `catch {}`: a failure here silently pinned
                // imp_mean/imp_min/imp_max/coh_mean to `null` for the
                // entire run, which is exactly the diagnostic needed to
                // explain whether the lifecycle is converging.
                err("longrun: sampleDist failed at cycle {d}: {s}\n", .{ cycle, @errorName(e) });
                std.process.exit(1);
            };
            last_dist = dist;
        }
        end_ns = ClockFn.nowNs();

        const rec = CycleRecord{
            .cycle = cycle,
            .ingested = ingested,
            .cells = cells,
            .d_cells = d,
            .matter = store.cellCountBySource(.matter),
            .form = store.cellCountBySource(.form),
            .spirit = store.cellCountBySource(.spirit),
            .fuzzy = store.lc.fuzzy.count(),
            .lat_ingest_ns = @intCast(ci1 - ci0),
            .lat_consolidate_ns = lat_cons,
            .lat_forget_ns = lat_forget,
            .abstracts = abstracts,
            .fuzzied = fuzzied,
            .kept = kept,
            .dist = dist,
        };

        var wal_kb: u64 = 0;
        var snap_kb: u64 = 0;
        if (!p.dry_data) {
            const wal_path = try std.fmt.allocPrint(alloc, "{s}/mem3.wal", .{p.data_dir});
            defer alloc.free(wal_path);
            const snap_path = try std.fmt.allocPrint(alloc, "{s}/snapshot.bin", .{p.data_dir});
            defer alloc.free(snap_path);
            wal_kb = fileSizeKb(alloc, wal_path);
            snap_kb = fileSizeKb(alloc, snap_path);
        }
        const t_ms: u64 = @intCast(@max(0, mem3.utils.time.nowMs() - start_ms));

        writeRecord(out_fd, rec, wal_kb, snap_kb, t_ms) catch |e| {
            err("longrun: record write failed: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        if (stdout_fd >= 0) {
            var line: [256]u8 = undefined;
            // Was `catch return`: an over-long diagnostic line exited main
            // with status 0 and a truncated stream, so a broken --stdout-jsonl
            // was indistinguishable from a short run.
            const s = std.fmt.bufPrint(&line, "{{\"cycle\":{d},\"t_ms\":{d},\"cells\":{d},\"d_cells\":{d},\"fuzzy\":{d},\"rss_kb\":{d}}}", .{ rec.cycle, t_ms, rec.cells, rec.d_cells, rec.fuzzy, rssKb() }) catch |e| {
                err("longrun: stdout jsonl line too long at cycle {d}: {s}\n", .{ rec.cycle, @errorName(e) });
                std.process.exit(1);
            };
            writeAll(stdout_fd, s) catch |e| {
                err("longrun: stdout write failed at cycle {d}: {s}\n", .{ rec.cycle, @errorName(e) });
                std.process.exit(1);
            };
            writeAll(stdout_fd, "\n") catch |e| {
                err("longrun: stdout write failed at cycle {d}: {s}\n", .{ rec.cycle, @errorName(e) });
                std.process.exit(1);
            };
        }

        // ---- progress (time-based, never cycle-based) ---------------------
        const now_ns = ClockFn.nowNs();
        if (p.progress_sec > 0 and @divTrunc(now_ns - last_progress, 1_000_000_000) >= @as(i128, @intCast(p.progress_sec))) {
            last_progress = now_ns;
            err("longrun: t={d}s cycle={d} cells={d} d_cells={d} fuzzy={d} rss_kb={d}\n", .{
                @divTrunc(now_ns - t0, 1_000_000_000),
                rec.cycle,
                rec.cells,
                rec.d_cells,
                rec.fuzzy,
                rssKb(),
            });
        }
    }

    const total_ms: u64 = @intCast(@max(0, mem3.utils.time.nowMs() - start_ms));
    const final_cells = store.cellCount();

    out("{s}\n", .{WALL_RULE});
    out("longrun summary\n", .{});
    out("  seed                : {d}\n", .{p.seed});
    out("  cycles run          : {d}\n", .{cycle});
    out("  wall clock          : {d} s\n", .{total_ms / 1000});
    out("  cells ingested      : {d}\n", .{total_ingested});
    out("  live cells          : {d} (matter {d} / form {d} / spirit {d})\n", .{
        final_cells,
        store.cellCountBySource(.matter),
        store.cellCountBySource(.form),
        store.cellCountBySource(.spirit),
    });
    out("  fuzzy (never deleted): {d}\n", .{store.lc.fuzzy.count()});
    out("  abstracts created   : {d}\n", .{total_abstracts});
    out("  cells fuzzied       : {d}\n", .{total_fuzzied});
    out("  rss_kb              : {d}\n", .{rssKb()});
    out("{s}\n", .{WALL_RULE});
    out("steady-state signal (net cell change per cycle)\n", .{});
    out("  first decile mean   : {d:.3}\n", .{@as(f64, @floatFromInt(first_decile_d)) / @as(f64, @floatFromInt(@max(decile, 1)))});
    out("  last decile mean    : {d:.3}  (over {d} cycles)\n", .{
        @as(f64, @floatFromInt(last_decile_d)) / @as(f64, @floatFromInt(@max(last_decile_n, 1))),
        last_decile_n,
    });
    out("  => d_cells trending to 0 means the loop reached a steady state.\n", .{});
    out("  => if the last-decile mean equals the first, it did NOT plateau.\n", .{});

    // Why `fuzzied` stayed at 0 — this is almost never a bug in the run.
    //
    // Forgetter.existenceContribution is `importance * exp(-decay_rate *
    // age_days)` and a cell is only fuzzied once that drops below
    // `forgetting_threshold`. Solving for the crossover:
    //
    //     age_days > ln(importance / threshold) / decay_rate
    //
    // With the observed defaults that lands around 30 days, so no run
    // shorter than a month will ever forget anything — a 24h baseline
    // produces a perfectly flat `fuzzied: 0` and that is the CORRECT
    // answer, not a broken sweep. Printing the arithmetic turns a
    // mysterious flat line into a checkable prediction.
    if (last_dist.sampled and last_dist.decay_mean > 0 and last_dist.imp_mean > 0) {
        const T: f64 = 0.1; // Lifecycle default forgetting_threshold
        const ratio = last_dist.imp_mean / T;
        const age_days = if (ratio > 1.0) @log(ratio) / last_dist.decay_mean else 0.0;
        const run_days = @as(f64, @floatFromInt(@as(u64, @intCast(@max(0, end_ns - t0))))) / 86_400_000_000_000.0;
        out("forgetting crossover (why fuzzied may be 0)\n", .{});
        out("  mean importance     : {d:.4}\n", .{last_dist.imp_mean});
        out("  mean decay_rate     : {d:.5} /day\n", .{last_dist.decay_mean});
        out("  threshold           : {d:.2}\n", .{T});
        out("  first cell forgotten: ~{d:.1} days after creation\n", .{age_days});
        out("  run wall clock      : {d:.4} days\n", .{run_days});
        if (age_days > run_days) {
            out("  => this run is {d:.0}x too short to trigger forgetting; fuzzied=0 is expected.\n", .{age_days / @max(run_days, 1e-9)});
        }
    }

    out("{s}\n", .{WALL_RULE});
    out("curve written to {s} — plot the `d_cells` column.\n", .{p.out_path});
}