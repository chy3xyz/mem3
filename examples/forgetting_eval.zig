//! mem3-forgetting-eval — does forgetting actually work?
//!
//! ## The problem this answers
//!
//! `Forgetter.existenceContribution` scores a cell as
//!
//!     contribution = importance_score * exp(-decay_rate * age_days)
//!
//! and fuzzies it once `contribution < forgetting_threshold` (0.1).
//! Solving for the crossover age:
//!
//!     age_days = ln(importance / threshold) / decay_rate
//!
//! With this build's defaults (mean importance ~0.715, decay_rate 0.01/0.03/0.05
//! for spirit/form/matter) that crossover is **39 to 197 days**. So every
//! short wall-clock run — including the 24h `mem3-longrun` baseline —
//! correctly reports `fuzzied: 0` forever. That flat line is the *right*
//! answer, not a broken sweep, which makes the forgetting half of the
//! existence-gain thesis untestable in a demo.
//!
//! ## How simulated age works (zero production changes)
//!
//! `age_days` is derived as `(now_ms - cell.metadata.created_at) / 86_400_000`.
//! `Store.getCell` hands back a mutable `*MemCell` — it is the very same
//! heap cell that `TriSourceManager` owns and that `cell_index` aliases
//! (see `Store.commitBuiltCell`) — so writing `metadata.created_at` through
//! that pointer back-dates the cell exactly as if it had been sitting in the
//! store for N days. The decay term then becomes *real* for the sweep, with
//! no change to the forgetter, its signature, or anything under `src/`.
//!
//! ## The scenario
//!
//! Three groups of cells are seeded through the real ingest path
//! (`Store.addRaw` → `Encoder` → `TriSourceManager`), so importance and
//! decay_rate are the encoder's own values, not ones this harness fakes:
//!
//!   present — age x0.0  — must survive; the recall anchor
//!   fragile — age x0.7  — must survive, but sits near the edge
//!   stale   — age x1.8  — must be fuzzied; the stale tail
//!
//! One parameter is swept: the **base age offset**. Each config rebuilds the
//! same corpus with the same seed and only moves `created_at`, so the curve
//! isolates age as the cause. Within a group, cells differ by source
//! (decay 0.01/0.03/0.05) and goal relevance (which moves importance), so
//! a group crosses the threshold progressively rather than in one step.
//!
//! ## Scoring: FAMA
//!
//!     MPA  = facts that should be recalled that were recalled   / should be recalled
//!     FAA  = facts that should be forgotten that were forgotten / should be forgotten
//!     λ    = N_forget / (N_presence + N_forget)
//!     FAMA = max(0, MPA - λ·(1 - FAA))
//!
//! Ordinary recall metrics reward returning the relevant fact and say
//! nothing about the stale ones you dragged along with it. FAMA subtracts
//! that penalty, which is the only reason the `fragile` group exists: a
//! sweep that forgets *everything* scores FAA=1 and MPA=0, and a sweep
//! that forgets *nothing* scores the mirror image. Both components are
//! reported per group and combined, never blended into one number.
//!
//! ## Usage
//!
//!     zig build example-forgetting-eval
//!     ./zig-out/bin/mem3-forgetting-eval --data-dir=/tmp/mem3_fe
//!
//! Silent by default: JSONL goes to a file, progress to stderr on a **time**
//! interval, and a human-readable summary to stdout at the end.

const std = @import("std");
const mem3 = @import("mem3");

const Allocator = std.mem.Allocator;
const MemCell = mem3.MemCell;

const WALL_RULE = "==============================================================";
const DAY_MS: f64 = 86_400_000.0;

// ============================================================================
// Corpus definition
// ============================================================================

/// A group of cells sharing one age multiplier. `should_survive` is the
/// ground truth FAMA is scored against — the harness never changes it.
const Group = struct {
    name: []const u8,
    /// Cell age = base_age_days * age_mul * per-cell jitter.
    age_mul: f64,
    should_survive: bool,
    intent: []const u8,
};

const GROUPS = [_]Group{
    .{
        .name = "present",
        .age_mul = 0.0,
        .should_survive = true,
        .intent = "must survive; the recall anchor",
    },
    .{
        .name = "fragile",
        .age_mul = 0.7,
        .should_survive = true,
        .intent = "must survive, but sits near the edge",
    },
    .{
        .name = "stale",
        .age_mul = 1.8,
        .should_survive = false,
        .intent = "must be fuzzied; the stale tail",
    },
};

/// All three decay rates, so the sweep spans the full predicted crossover
/// range (spirit 197d, form 66d, matter 39d at the default threshold).
const SOURCES = [_]mem3.MemorySource{ .spirit, .form, .matter };

/// Goal relevance feeds the encoder's importance directly:
/// importance = 0.30*1.0 + 0.40*relevance + 0.30*0.5 = 0.45 + 0.40*relevance.
const RELEVANCE = [_]f32{ 0.30, 0.55, 0.80, 1.00 };

/// ±15% age jitter. Without it every cell in a group shares one crossover and
/// survival drops from 1 to 0 between two adjacent configs, leaving nothing
/// to interpolate — the measured crossover would be quantised to the sweep
/// step and could never be compared to the closed form.
const JITTER: f64 = 0.30;

const EPISODES = [_][]const u8{
    "the api key rotation schedule is documented in the ops runbook",
    "the staging cluster runs in region eu-west-1 with three zones",
    "the retention policy keeps ninety days of billing records",
    "the incident postmortem for the january outage is filed",
    "the quarterly revenue forecast was revised after the march close",
    "the contractor access review happens on the first of each month",
    "the deprecated endpoint sunsets at the end of the fiscal year",
    "the training set snapshot is pinned to the winter release",
    "the oncall rotation hands over at nine in the morning local time",
    "the legacy payroll export was replaced by the vendor feed",
    "the office lease renewal option was exercised in august",
    "the customer escalation matrix changed after the last review",
};

const FACT_STRINGS = [_][]const u8{
    "api_key|rotates|quarterly",
    "staging|region|eu-west-1",
    "retention|keeps|90 days",
    "postmortem|filed|january",
    "forecast|revised|march",
    "contractor|reviews|monthly",
    "endpoint|sunsets|fy-end",
    "snapshot|pinned|winter",
    "oncall|handover|09:00",
    "payroll|replaced|vendor",
    "lease|exercised|august",
    "escalation|changed|review",
};

// ============================================================================
// Parameters
// ============================================================================

const Params = struct {
    /// Number of sweep points. The base age runs 0 .. max_age_days.
    configs: usize = 13,
    max_age_days: f64 = 240.0,
    seed: u64 = 42,
    threshold: f32 = 0.1,
    /// Seconds between progress lines on stderr. Time-based on purpose:
    /// a cycle-count trigger goes silent in exactly the steady state you
    /// are trying to observe.
    progress_sec: u64 = 0,
    /// Empty (the default) means in-memory: no WAL, no snapshot. The
    /// harness never reloads a store, so persistence buys nothing here.
    /// If you do pass a directory, it is namespaced per run — see
    /// `runScopedDir`.
    data_dir: []const u8 = "",
    out_path: []const u8 = "forgetting_eval.jsonl",
    in_memory: bool = true,
    stdout_jsonl: bool = false,
    force: bool = false,
};

const MAX_CONFIGS = 512;

// ============================================================================
// Small POSIX helpers (mirrors examples/longrun.zig)
// ============================================================================


/// Write every byte, or fail. A silently truncated JSONL file is well-formed
/// up to the cut, which is the worst failure mode for a measurement
/// harness — the missing data stays invisible until someone plots the curve.
fn writeAll(fd: std.c.fd_t, bytes: []const u8) error{WriteFailed}!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (std.c.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Open for writing, truncating any existing file.
///
/// These two functions are all that remains of this example's private copy
/// of the POSIX file primitives. They are thin delegates onto
/// `src/platform/fs.zig`, which is what makes the example cross-compile:
/// the layer's `OpenMode` is identical on every target, whereas a
/// `std.c.O` literal has a different shape per platform.
fn openOut(path: []const u8) ?mem3.platform.fs.Fd {
    const z = mem3.platform.fs.SentinelBuffer.init(path);
    return mem3.platform.fs.open(z.ptr(), .{ .access = .write_only, .create = .truncate }) catch null;
}

fn closeFd(fd: mem3.platform.fs.Fd) void {
    mem3.platform.fs.close(fd);
}

fn fileExists(path: []const u8) bool {
    const z = mem3.platform.fs.SentinelBuffer.init(path);
    const probe = mem3.platform.fs.open(z.ptr(), .{ .access = .read_only }) catch return false;
    mem3.platform.fs.close(probe);
    return true;
}

/// Namespace `base` per run so two invocations never share WAL state.
///
/// This is not tidiness. `Store.init` replays any WAL it finds in
/// `data_dir`, so re-running into the same directory silently re-ingests
/// the previous run's cells: a 36-cell corpus reported `kept=108` on the
/// first config because three earlier runs had each left 36 cells behind.
/// A measurement harness that counts cells must start every config from an
/// empty store, so each run gets its own subtree and never replays.
fn runScopedDir(alloc: Allocator, base: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/run_{d}", .{ base, std.c.getpid() });
}

fn nowNs() i128 {
    return mem3.platform.clock.monotonicNs();
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = mem3.platform.stdio.writeOut(s);
}

fn err(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = mem3.platform.stdio.writeErr(s);
}

/// Render a float as JSON, or `null` when it is absent or non-finite.
/// `nan`/`inf` would make the whole line unparseable, and a single bad
/// record costs you the entire file in a strict-parser pipeline.
fn jnum(buf: *[64]u8, v: ?f64) []const u8 {
    const x = v orelse return "null";
    if (!std.math.isFinite(x)) return "null";
    return std.fmt.bufPrint(buf, "{d:.6}", .{x}) catch "null";
}

// ============================================================================
// Per-config results
// ============================================================================

const GroupResult = struct {
    n: usize = 0,
    survived: usize = 0,
    fuzzied: usize = 0,
    imp_sum: f64 = 0,
    decay_sum: f64 = 0,
    contrib_sum: f64 = 0,

    fn survival(self: GroupResult) f64 {
        if (self.n == 0) return 0;
        return @as(f64, @floatFromInt(self.survived)) / @as(f64, @floatFromInt(self.n));
    }

    fn meanImportance(self: GroupResult) f64 {
        if (self.n == 0) return 0;
        return self.imp_sum / @as(f64, @floatFromInt(self.n));
    }

    fn meanDecay(self: GroupResult) f64 {
        if (self.n == 0) return 0;
        return self.decay_sum / @as(f64, @floatFromInt(self.n));
    }

    fn meanContribution(self: GroupResult) f64 {
        if (self.n == 0) return 0;
        return self.contrib_sum / @as(f64, @floatFromInt(self.n));
    }

    /// Closed-form crossover in *cell* age, from this group's own measured
    /// importance and decay rate: ln(importance / threshold) / decay.
    fn predictedCellDays(self: GroupResult, threshold: f64) ?f64 {
        if (self.n == 0) return null;
        const imp = self.meanImportance();
        const decay = self.meanDecay();
        if (imp <= 0 or decay <= 0) return null;
        return @log(imp / threshold) / decay;
    }
};

fn defaultGroups() [GROUPS.len]GroupResult {
    var g: [GROUPS.len]GroupResult = undefined;
    for (&g) |*x| x.* = .{};
    return g;
}

const ConfigResult = struct {
    cfg: usize = 0,
    base_age_days: f64 = 0,
    fuzzied: usize = 0,
    kept: usize = 0,
    fuzzy_store: usize = 0,
    cells: usize = 0,
    groups: [GROUPS.len]GroupResult = defaultGroups(),
    /// Presence-accuracy: should-be-recalled cells that were.
    mpa: f64 = 0,
    /// Forgetting-absence-accuracy: should-be-forgotten cells that were.
    faa: f64 = 0,
    lambda: f64 = 0,
    fama: f64 = 0,
    n_presence: usize = 0,
    n_forget: usize = 0,
};

// ============================================================================
// One sweep configuration
// ============================================================================

fn runConfig(
    alloc: Allocator,
    p: Params,
    cfg: usize,
    base_age_days: f64,
    data_dir: ?[]const u8,
    res: *ConfigResult,
) !void {
    const cfg_dir = if (data_dir) |d|
        try std.fmt.allocPrint(alloc, "{s}/cfg_{d:0>3}", .{ d, cfg })
    else
        null;
    defer if (cfg_dir) |d| alloc.free(d);

    const store = try mem3.Store.init(alloc, .{
        .data_dir = cfg_dir,
        .seed_default_goals = true,
    });
    defer store.deinit();

    // One PRNG, re-seeded identically for every config, so the jitter and
    // relevance layout are constant across the sweep and the only variable
    // is created_at. Otherwise the curve mixes "age" with "which cell".
    var prng = std.Random.DefaultPrng.init(p.seed);
    const rand = prng.random();

    const per_group = SOURCES.len * RELEVANCE.len;
    const handles = try alloc.alloc(*MemCell, per_group * GROUPS.len);
    defer alloc.free(handles);

    var n: usize = 0;
    for (GROUPS) |_| {
        for (SOURCES) |src| {
            for (RELEVANCE) |rel| {
                const i = rand.intRangeAtMost(usize, 0, EPISODES.len - 1);
                const id = store.addRaw(src, EPISODES[i], FACT_STRINGS[i], 1, rel) catch |e| {
                    err("forgetting_eval: addRaw failed: {s}\n", .{@errorName(e)});
                    return e;
                };
                // getCell hands back the manager's own cell — the same
                // pointer the sweep will read and mutate. This is the
                // simulated-age lever.
                const cell = store.getCell(id) orelse {
                    err("forgetting_eval: cell {d} vanished right after insert\n", .{id});
                    return error.CellNotFound;
                };
                handles[n] = cell;
                n += 1;
            }
        }
    }

    const now_ms = mem3.utils.time.nowMs();

    // ---- back-date: the whole point -------------------------------------
    var gi: usize = 0;
    var gi_end: usize = 0;
    var k: usize = 0;
    while (gi < GROUPS.len) : (gi += 1) {
        gi_end = (gi + 1) * per_group;
        const g = GROUPS[gi];
        while (k < gi_end) : (k += 1) {
            const cell = handles[k];
            const jitter = 1.0 + (rand.float(f64) - 0.5) * JITTER;
            const age_days = base_age_days * g.age_mul * jitter;
            const age_ms: i64 = @intFromFloat(@max(0.0, age_days) * DAY_MS);
            cell.metadata.created_at = now_ms - age_ms;

            // Read back what the *encoder* chose, not what this file assumed.
            res.groups[gi].n += 1;
            res.groups[gi].imp_sum += cell.metadata.importance_score;
            res.groups[gi].decay_sum += cell.metadata.decay_rate;
        }
    }

    // ---- sweep -----------------------------------------------------------
    const sweep = store.forget(false) catch |e| {
        err("forgetting_eval: forget failed: {s}\n", .{@errorName(e)});
        return e;
    };
    res.fuzzied = sweep.fuzzied;
    res.kept = sweep.kept;
    res.fuzzy_store = store.lc.fuzzy.count();
    res.cells = store.cellCount();

    // ---- score -----------------------------------------------------------
    // Ground truth per cell is `is_fuzzy`, set by FuzzyStore.transfer on the
    // same object. Note that `getCell` is NOT a reliable presence probe
    // after a sweep: the forgetter removes from the manager but leaves the
    // id in `cell_index`, so the handle keeps resolving and the stale cell
    // still reports present. The flag is the honest signal.
    k = 0;
    gi = 0;
    while (gi < GROUPS.len) : (gi += 1) {
        gi_end = (gi + 1) * per_group;
        while (k < gi_end) : (k += 1) {
            const cell = handles[k];
            if (cell.metadata.is_fuzzy) {
                res.groups[gi].fuzzied += 1;
            } else {
                res.groups[gi].survived += 1;
            }
            // Ask the forgetter itself what it scored, rather than
            // recomputing the formula and hoping it matches.
            res.groups[gi].contrib_sum += store.lc.forgetter.existenceContribution(cell, now_ms);
        }
        if (GROUPS[gi].should_survive) {
            res.n_presence += res.groups[gi].n;
        } else {
            res.n_forget += res.groups[gi].n;
        }
    }

    var present_ok: usize = 0;
    var forget_ok: usize = 0;
    gi = 0;
    while (gi < GROUPS.len) : (gi += 1) {
        const g = GROUPS[gi];
        if (g.should_survive) {
            present_ok += res.groups[gi].survived;
        } else {
            forget_ok += res.groups[gi].fuzzied;
        }
    }

    res.mpa = if (res.n_presence == 0)
        0
    else
        @as(f64, @floatFromInt(present_ok)) / @as(f64, @floatFromInt(res.n_presence));
    res.faa = if (res.n_forget == 0)
        0
    else
        @as(f64, @floatFromInt(forget_ok)) / @as(f64, @floatFromInt(res.n_forget));
    const denom = res.n_presence + res.n_forget;
    res.lambda = if (denom == 0)
        0
    else
        @as(f64, @floatFromInt(res.n_forget)) / @as(f64, @floatFromInt(denom));
    res.fama = @max(0.0, res.mpa - res.lambda * (1.0 - res.faa));
}

// ============================================================================
// Output
// ============================================================================

fn writeHeader(fd: std.c.fd_t, p: Params) !void {
    var line: [1024]u8 = undefined;
    // NOTE: this format string must stay on ONE physical line. A Zig
    // multiline `\\` literal preserves its embedded newlines, which turns
    // one record into three and destroys a JSONL file.
    const s = try std.fmt.bufPrint(&line, "{{\"record\":\"header\",\"harness\":\"forgetting_eval\",\"schema\":1,\"threshold\":{d:.6},\"configs\":{d},\"max_age_days\":{d:.3},\"seed\":{d},\"cells_per_group\":{d},\"sources\":{d},\"groups\":[\"present\",\"fragile\",\"stale\"],\"score\":\"FAMA=max(0,MPA-lambda*(1-FAA)),lambda=N_forget/(N_presence+N_forget)\"}}", .{ p.threshold, p.configs, p.max_age_days, p.seed, SOURCES.len * RELEVANCE.len, SOURCES.len });
    try writeAll(fd, s);
    try writeAll(fd, "\n");
}

fn writeConfig(fd: std.c.fd_t, res: ConfigResult) !void {
    var gbuf: [GROUPS.len][256]u8 = undefined;
    var glen: [GROUPS.len]usize = undefined;
    for (&gbuf, &glen, GROUPS, 0..) |*b, *l, g, i| {
        const gr = res.groups[i];
        // Nullable floats are pre-rendered into buffers that outlive the
        // bufPrint below — a helper returning a slice of its own stack
        // buffer would dangle.
        const contrib = std.fmt.bufPrint(b, "{{\"name\":\"{s}\",\"should_survive\":{s},\"n\":{d},\"survived\":{d},\"fuzzied\":{d},\"survival\":{d:.6},\"mean_importance\":{d:.6},\"mean_decay_rate\":{d:.6},\"mean_contribution\":{d:.6}}}", .{
            g.name,
            if (g.should_survive) "true" else "false",
            gr.n,
            gr.survived,
            gr.fuzzied,
            gr.survival(),
            gr.meanImportance(),
            gr.meanDecay(),
            gr.meanContribution(),
        }) catch return error.LineTooLong;
        l.* = contrib.len;
    }

    var line: [3072]u8 = undefined;
    const s = try std.fmt.bufPrint(&line, "{{\"record\":\"config\",\"cfg\":{d},\"base_age_days\":{d:.3},\"cells\":{d},\"fuzzied\":{d},\"kept\":{d},\"fuzzy_store\":{d},\"groups\":[{s},{s},{s}],\"mpa\":{d:.6},\"faa\":{d:.6},\"lambda\":{d:.6},\"fama\":{d:.6},\"n_presence\":{d},\"n_forget\":{d}}}", .{
        res.cfg,
        res.base_age_days,
        res.cells,
        res.fuzzied,
        res.kept,
        res.fuzzy_store,
        gbuf[0][0..glen[0]],
        gbuf[1][0..glen[1]],
        gbuf[2][0..glen[2]],
        res.mpa,
        res.faa,
        res.lambda,
        res.fama,
        res.n_presence,
        res.n_forget,
    });
    try writeAll(fd, s);
    try writeAll(fd, "\n");
}

fn parseArgs(init: std.process.Init.Minimal) !Params {
    var p = Params{};
    var it = std.process.Args.iterate(init.args);
    _ = it.next();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--in-memory")) {
            p.in_memory = true;
        } else if (std.mem.eql(u8, a, "--stdout-jsonl")) {
            p.stdout_jsonl = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            p.force = true;
        } else if (std.mem.startsWith(u8, a, "--configs=")) {
            p.configs = try std.fmt.parseInt(usize, a["--configs=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--max-age-days=")) {
            p.max_age_days = try std.fmt.parseFloat(f64, a["--max-age-days=".len..]);
        } else if (std.mem.startsWith(u8, a, "--threshold=")) {
            p.threshold = try std.fmt.parseFloat(f32, a["--threshold=".len..]);
        } else if (std.mem.startsWith(u8, a, "--seed=")) {
            p.seed = try std.fmt.parseInt(u64, a["--seed=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--progress-sec=")) {
            p.progress_sec = try std.fmt.parseInt(u64, a["--progress-sec=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--data-dir=")) {
            p.data_dir = a["--data-dir=".len..];
            p.in_memory = false;
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            p.out_path = a["--out=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            out(
                \\mem3-forgetting-eval — measure whether forgetting actually works
                \\
                \\  --configs=N        sweep points (default 13)
                \\  --max-age-days=D   base age swept 0..D (default 240)
                \\  --threshold=T      forgetting threshold (default 0.1)
                \\  --seed=N           PRNG seed; same seed reproduces the run
                \\  --progress-sec=S   stderr progress interval (default 0 = per config)
                \\  --data-dir=PATH    persist under PATH/run_<pid>/cfg_NNN (default: in-memory)
                \\  --in-memory        no WAL, no disk (default)
                \\  --out=PATH         JSONL output (default forgetting_eval.jsonl)
                \\  --stdout-jsonl     also stream JSONL to stdout
                \\  --force            overwrite an existing output file
                \\
            , .{});
            std.process.exit(0);
        } else {
            err("unknown argument: {s}\n", .{a});
            std.process.exit(2);
        }
    }
    if (p.configs < 2) return error.TooFewConfigs;
    if (p.configs > MAX_CONFIGS) return error.TooManyConfigs;
    if (p.threshold <= 0) return error.BadThreshold;
    return p;
}

// ============================================================================
// Entry point
// ============================================================================

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const p = parseArgs(init) catch |e| {
        err("forgetting_eval: bad arguments ({s})\n", .{@errorName(e)});
        std.process.exit(2);
    };

    if (!p.force and fileExists(p.out_path)) {
        err("forgetting_eval: {s} already exists — pass --force or --out=PATH\n", .{p.out_path});
        std.process.exit(2);
    }

    const out_fd = openOut(p.out_path) orelse {
        err("forgetting_eval: cannot open {s}\n", .{p.out_path});
        std.process.exit(2);
    };
    defer closeFd(out_fd);

    const stdout_fd: std.c.fd_t = if (p.stdout_jsonl) @intCast(std.c.STDOUT_FILENO) else -1;
    const scoped_dir: ?[]const u8 = if (p.in_memory) null else try runScopedDir(alloc, p.data_dir);
    defer if (scoped_dir) |d| alloc.free(d);
    const data_dir: ?[]const u8 = scoped_dir;

    err("forgetting_eval: configs={d} max_age_days={d:.1} threshold={d:.4} seed={d} data_dir={s}\n", .{
        p.configs,
        p.max_age_days,
        p.threshold,
        p.seed,
        scoped_dir orelse "(in-memory)",
    });
    err("forgetting_eval: writing {s}\n", .{p.out_path});

    writeHeader(out_fd, p) catch |e| {
        err("forgetting_eval: header write failed: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    if (stdout_fd >= 0) {
        const hdr = "{\"record\":\"header\"}\n";
        writeAll(stdout_fd, hdr) catch std.process.exit(1);
    }

    const results = try alloc.alloc(ConfigResult, p.configs);
    defer alloc.free(results);
    @memset(results, ConfigResult{});

    const t0 = nowNs();
    var last_progress = t0;

    var cfg: usize = 0;
    while (cfg < p.configs) : (cfg += 1) {
        // base_age runs 0, D/(n-1), 2D/(n-1), ... D.
        const step = p.max_age_days / @as(f64, @floatFromInt(p.configs - 1));
        const base_age = step * @as(f64, @floatFromInt(cfg));

        results[cfg] = .{ .cfg = cfg, .base_age_days = base_age };
        try runConfig(alloc, p, cfg, base_age, data_dir, &results[cfg]);

        writeConfig(out_fd, results[cfg]) catch |e| {
            err("forgetting_eval: record write failed at cfg {d}: {s}\n", .{ cfg, @errorName(e) });
            std.process.exit(1);
        };
        if (stdout_fd >= 0) {
            var line: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&line, "{{\"cfg\":{d},\"base_age_days\":{d:.3},\"fuzzied\":{d},\"fama\":{d:.6}}}", .{
                results[cfg].cfg,
                results[cfg].base_age_days,
                results[cfg].fuzzied,
                results[cfg].fama,
            }) catch {
                err("forgetting_eval: stdout jsonl line too long at cfg {d}\n", .{cfg});
                std.process.exit(1);
            };
            writeAll(stdout_fd, s) catch std.process.exit(1);
            writeAll(stdout_fd, "\n") catch std.process.exit(1);
        }

        err("forgetting_eval: cfg={d}/{d} base_age={d:.1}d fuzzied={d} kept={d} mpa={d:.4} faa={d:.4} fama={d:.4}\n", .{
            cfg + 1,
            p.configs,
            base_age,
            results[cfg].fuzzied,
            results[cfg].kept,
            results[cfg].mpa,
            results[cfg].faa,
            results[cfg].fama,
        });

        if (p.progress_sec > 0) {
            const n = nowNs();
            if (@divTrunc(n - last_progress, 1_000_000_000) >= @as(i128, @intCast(p.progress_sec))) {
                last_progress = n;
                err("forgetting_eval: t={d}s cfg={d}\n", .{ @divTrunc(n - t0, 1_000_000_000), cfg });
            }
        }
    }

    // ---------------------------------------------------------------------
    // Summary: measured crossover vs the closed form.
    // ---------------------------------------------------------------------
    const threshold: f64 = p.threshold;
    var total_fuzzied: usize = 0;
    var best_fama: f64 = 0;
    var best_cfg: usize = 0;
    for (results) |r| {
        total_fuzzied += r.fuzzied;
        if (r.fama > best_fama) {
            best_fama = r.fama;
            best_cfg = r.cfg;
        }
    }

    out("\n{s}\n", .{WALL_RULE});
    out("mem3-forgetting-eval — FAMA summary\n", .{});
    out("  configs={d}  base age 0..{d:.1}d  threshold={d:.4}  seed={d}\n", .{ p.configs, p.max_age_days, threshold, p.seed });
    out("  cells/config={d} (3 groups x {d} sources x {d} relevance levels)\n", .{ GROUPS.len * SOURCES.len * RELEVANCE.len, SOURCES.len, RELEVANCE.len });
    out("  total fuzzied across sweep = {d}\n", .{total_fuzzied});
    out("  best FAMA = {d:.4} at base_age = {d:.1}d\n", .{ best_fama, results[best_cfg].base_age_days });
    out("{s}\n", .{WALL_RULE});

    out("\nCrossover: measured vs the closed form ln(importance/threshold)/decay_rate.\n", .{});
    out("  measured/predicted_base are in swept base-age units; pred_cell_d is the\n  closed form in the cell's own age (base_age * age_mul * jitter).\n", .{});
    out("  group      age_mul   measured_base   pred_cell_d   pred_base_d    delta     n    imp   decay\n", .{});
    for (GROUPS, results[0].groups) |g, gr0| {
        // Measured: first config whose survival drops below one half,
        // linearly interpolated between it and the previous point.
        const measured = interpolateCrossover(results, g.name);
        const predicted_cell = gr0.predictedCellDays(threshold);
        // Convert the cell-age crossover into this group's own base-age
        // units so it lines up with the swept x-axis.
        const predicted_base: ?f64 = if (g.age_mul <= 0)
            null
        else if (predicted_cell) |pc|
            pc / g.age_mul
        else
            null;

        const delta: ?f64 = if (measured) |m|
            if (predicted_base) |pb| m - pb else null
        else
            null;

        var mbuf: [64]u8 = undefined;
        var cbuf: [64]u8 = undefined;
        var pbuf: [64]u8 = undefined;
        var dbuf: [64]u8 = undefined;
        out("  {s:<10}  {d:.2}     {s:>12}  {s:>12}  {s:>12}  {s:>8}  {d:>3}  {d:.3}  {d:.4}\n", .{
            g.name,
            g.age_mul,
            jnum(&mbuf, measured),
            jnum(&cbuf, predicted_cell),
            jnum(&pbuf, predicted_base),
            jnum(&dbuf, delta),
            gr0.n,
            gr0.meanImportance(),
            gr0.meanDecay(),
        });
    }
    out("  (present has age_mul 0 so it never ages: no crossover is the correct answer,\n   and it anchors MPA at 1.0 across the whole sweep.)\n", .{});

    out("\nPer-group accuracy at the extremes of the sweep:\n", .{});
    const last = results[results.len - 1];
    for (GROUPS, last.groups) |g, gr| {
        out("  base_age={d:>6.1}d  {s:<9} should_survive={s:<5} survival={d:.4} ({d}/{d} kept)\n", .{
            last.base_age_days,
            g.name,
            if (g.should_survive) "true" else "false",
            gr.survival(),
            gr.survived,
            gr.n,
        });
    }

    out("\nFAMA components (MPA = recall of facts that should survive, FAA = removal of facts that should not):\n", .{});
    out("  base_age_days   mpa     faa     lambda   fama\n", .{});
    for (results) |r| {
        out("  {d:>13.1}   {d:.4}  {d:.4}  {d:.4}   {d:.4}\n", .{ r.base_age_days, r.mpa, r.faa, r.lambda, r.fama });
    }
    out("\n{s}\n", .{WALL_RULE});
}

/// First base_age at which a group's survival fraction crosses 0.5, linearly
/// interpolated between the two bracketing sweep points. Returns null if the
/// group never drops below one half (it never ages, or the sweep stops short).
fn interpolateCrossover(results: []const ConfigResult, group_name: []const u8) ?f64 {
    const idx = for (GROUPS, 0..) |g, i| {
        if (std.mem.eql(u8, g.name, group_name)) break i;
    } else return null;

    var i: usize = 1;
    while (i < results.len) : (i += 1) {
        const hi = results[i].groups[idx].survival();
        if (hi >= 0.5) continue;
        const lo_res = results[i - 1];
        const lo = lo_res.groups[idx].survival();
        if (lo <= hi) return lo_res.base_age_days;
        const t = (lo - 0.5) / (lo - hi);
        return lo_res.base_age_days + t * (results[i].base_age_days - lo_res.base_age_days);
    }
    return null;
}