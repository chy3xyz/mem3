//! `mem3-bench lme-compare` and `mem3-bench lme-synthetic` — the paired
//! analysis half of the ablation (docs/benchmarks/ablation-tri-source.md).
//!
//! `lme-compare` reads the per-question score files that
//! `longmemeval-official --dump-scores=PATH` writes, pairs the questions of a
//! baseline with those of a variant by `question_id`, and reports the mean
//! paired delta of R_any@1/@5/@10 and NDCG@10 with a percentile-bootstrap
//! confidence interval over questions. All arithmetic is in
//! `src/eval/paired_stats.zig`, where it is unit tested; this file is I/O.
//!
//! Either side may be several files (`--base` / `--variant` repeated). The
//! per-question metric is then the **mean over the files**, which is how a
//! seed family (five random-tag runs) is compared as one arm; the per-file
//! overall deltas are listed as well so the seed-to-seed spread is visible.
//!
//! `lme-synthetic` runs the two SYNTHETIC mechanism checks (goal-conditioned
//! and source-routed) and prints their hit counts.

const std = @import("std");
const mem3 = @import("mem3");
const harness = @import("harness.zig");
const official = @import("longmemeval_official.zig");

const pstats = mem3.eval.paired_stats;
const abl = mem3.eval.lme_ablation;
const Allocator = std.mem.Allocator;

const M = struct {
    ra: []const f64,
    rl: []const f64,
    nd: []const f64,
};

const Row = struct {
    question_id: []const u8,
    question_type: []const u8,
    rank_hash: []const u8,
    n_ranked: u64 = 0,
    primary: M,
    derived: ?M = null,
};

/// Reported metrics: name and (series, index into `lme.KS` = 1,3,5,10,30,50).
const Metric = struct { name: []const u8, series: enum { ra, nd }, ki: usize };
const METRICS = [_]Metric{
    .{ .name = "R_any@1", .series = .ra, .ki = 0 },
    .{ .name = "R_any@5", .series = .ra, .ki = 2 },
    .{ .name = "R_any@10", .series = .ra, .ki = 3 },
    .{ .name = "NDCG@10", .series = .nd, .ki = 3 },
};

const File = struct {
    rows: []Row,
    by_id: std.StringHashMap(usize),
};

fn loadFile(arena: Allocator, path: []const u8) !File {
    const bytes = try official.readWholeFile(arena, path);
    var rows = std.ArrayList(Row).empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        const row = try std.json.parseFromSliceLeaky(Row, arena, line, .{ .ignore_unknown_fields = true });
        try rows.append(arena, row);
    }
    var by_id = std.StringHashMap(usize).init(arena);
    for (rows.items, 0..) |r, i| try by_id.put(r.question_id, i);
    return .{ .rows = rows.items, .by_id = by_id };
}

/// Below this a per-question delta is quantisation/float noise (score files
/// are written with 9 decimals).
const SNAP: f64 = 5e-9;

const Level = enum { primary, derived };

fn pick(row: Row, level: Level, m: Metric) !f64 {
    const mm = switch (level) {
        .primary => row.primary,
        .derived => row.derived orelse return error.NoDerivedLevel,
    };
    return switch (m.series) {
        .ra => mm.ra[m.ki],
        .nd => mm.nd[m.ki],
    };
}

fn usage() void {
    harness.out(
        \\lme-compare — paired bootstrap of per-question deltas (variant − baseline)
        \\
        \\  --base=PATH        baseline score file (repeatable: per-question mean over files)
        \\  --variant=PATH     variant score file  (repeatable)
        \\  --label=TEXT       name echoed into the JSON
        \\  --level=L          primary (default) | derived (session-from-turn)
        \\  --resamples=N      bootstrap resamples (default 10000)
        \\  --boot-seed=N      bootstrap seed (default 20261021)
        \\  --adjust-m=N       Bonferroni family size for the adjusted CI (default 20)
        \\
        \\Score files come from `longmemeval-official --dump-scores=PATH`.
        \\
    , .{});
}

pub fn run(alloc: Allocator, init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var base_paths = std.ArrayList([]const u8).empty;
    var var_paths = std.ArrayList([]const u8).empty;
    var label: []const u8 = "";
    var level: Level = .primary;
    var resamples: usize = 10_000;
    var boot_seed: u64 = 20261021;
    var adjust_m: usize = 20;

    var it = harness.argIterator(init);
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--base=")) {
            try base_paths.append(arena, arg["--base=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--variant=")) {
            try var_paths.append(arena, arg["--variant=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--label=")) {
            label = arg["--label=".len..];
        } else if (std.mem.startsWith(u8, arg, "--level=")) {
            level = std.meta.stringToEnum(Level, arg["--level=".len..]) orelse return error.BadLevel;
        } else if (std.mem.startsWith(u8, arg, "--resamples=")) {
            resamples = try std.fmt.parseInt(usize, arg["--resamples=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--boot-seed=")) {
            boot_seed = try std.fmt.parseInt(u64, arg["--boot-seed=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--adjust-m=")) {
            adjust_m = try std.fmt.parseInt(usize, arg["--adjust-m=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        } else {
            harness.out("lme-compare: unknown argument {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    if (base_paths.items.len == 0 or var_paths.items.len == 0) {
        harness.out("lme-compare: need at least one --base and one --variant (see --help)\n", .{});
        return error.MissingInput;
    }
    if (adjust_m == 0) return error.BadAdjust;

    const nb = base_paths.items.len;
    const nv = var_paths.items.len;
    const bases = try arena.alloc(File, nb);
    for (base_paths.items, 0..) |p, i| bases[i] = try loadFile(arena, p);
    const vars = try arena.alloc(File, nv);
    for (var_paths.items, 0..) |p, i| vars[i] = try loadFile(arena, p);

    // The pairing key is the question id of the first baseline file; every
    // other file must hold exactly the same set.
    const n = bases[0].rows.len;
    for (bases[1..]) |f| if (f.rows.len != n) return error.QuestionSetMismatch;
    for (vars) |f| if (f.rows.len != n) return error.QuestionSetMismatch;
    const idx_b = try arena.alloc([]usize, nb);
    for (bases, 0..) |f, fi| {
        idx_b[fi] = try arena.alloc(usize, n);
        for (bases[0].rows, 0..) |r, qi| idx_b[fi][qi] = f.by_id.get(r.question_id) orelse return error.QuestionSetMismatch;
    }
    const idx_v = try arena.alloc([]usize, nv);
    for (vars, 0..) |f, fi| {
        idx_v[fi] = try arena.alloc(usize, n);
        for (bases[0].rows, 0..) |r, qi| idx_v[fi][qi] = f.by_id.get(r.question_id) orelse return error.QuestionSetMismatch;
    }

    // Per-question metric means over each side, per metric.
    const nm = METRICS.len;
    const base_m = try arena.alloc([]f64, nm);
    const var_m = try arena.alloc([]f64, nm);
    // Per-file overall means of the variant side, for the spread listing.
    const var_file_m = try arena.alloc([]f64, nm);
    for (METRICS, 0..) |m, mi| {
        base_m[mi] = try arena.alloc(f64, n);
        var_m[mi] = try arena.alloc(f64, n);
        var_file_m[mi] = try arena.alloc(f64, nv);
        for (0..n) |qi| {
            var sb: f64 = 0;
            for (bases, 0..) |f, fi| sb += try pick(f.rows[idx_b[fi][qi]], level, m);
            base_m[mi][qi] = sb / @as(f64, @floatFromInt(nb));
            var sv: f64 = 0;
            for (vars, 0..) |f, fi| sv += try pick(f.rows[idx_v[fi][qi]], level, m);
            var_m[mi][qi] = sv / @as(f64, @floatFromInt(nv));
        }
        for (vars, 0..) |f, fi| {
            var sum: f64 = 0;
            for (0..n) |qi| sum += try pick(f.rows[idx_v[fi][qi]], level, m);
            var_file_m[mi][fi] = sum / @as(f64, @floatFromInt(n));
        }
    }

    // Identical rankings: the question's ranking hash is the same in every
    // file of both sides.
    var identical: usize = 0;
    for (0..n) |qi| {
        const h0 = bases[0].rows[idx_b[0][qi]].rank_hash;
        var same = true;
        for (bases, 0..) |f, fi| {
            if (!std.mem.eql(u8, f.rows[idx_b[fi][qi]].rank_hash, h0)) same = false;
        }
        for (vars, 0..) |f, fi| {
            if (!std.mem.eql(u8, f.rows[idx_v[fi][qi]].rank_hash, h0)) same = false;
        }
        if (same) identical += 1;
    }

    // Groups: overall + question types (sorted).
    var type_names = std.ArrayList([]const u8).empty;
    for (bases[0].rows) |r| {
        var seen = false;
        for (type_names.items) |t| if (std.mem.eql(u8, t, r.question_type)) {
            seen = true;
        };
        if (!seen) try type_names.append(arena, r.question_type);
    }
    std.mem.sort([]const u8, type_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const adj_level = 1.0 - 0.05 / @as(f64, @floatFromInt(adjust_m));

    var j = harness.Json.init(alloc);
    defer j.deinit();
    try j.beginObject();
    try j.key("tool");
    try j.str("lme-compare");
    try j.key("label");
    try j.str(label);
    try j.key("level");
    try j.str(@tagName(level));
    try j.key("n_questions");
    try j.int(@as(u64, n));
    try j.key("base_files");
    try j.int(@as(u64, nb));
    try j.key("variant_files");
    try j.int(@as(u64, nv));
    try j.key("resamples");
    try j.int(@as(u64, resamples));
    try j.key("boot_seed");
    try j.int(boot_seed);
    try j.key("bonferroni_m");
    try j.int(@as(u64, adjust_m));
    try j.key("adjusted_ci_level");
    try j.float(adj_level);
    try j.key("questions_with_identical_ranking");
    try j.int(@as(u64, identical));

    try j.key("groups");
    try j.beginObject();
    const deltas = try arena.alloc(f64, n);
    const names_all = try arena.alloc([]const u8, type_names.items.len + 1);
    names_all[0] = "overall";
    for (type_names.items, 0..) |t, i| names_all[i + 1] = t;
    for (names_all) |gname| {
        const is_overall = std.mem.eql(u8, gname, "overall");
        try j.key(gname);
        try j.beginObject();
        var count: usize = 0;
        for (0..n) |qi| {
            if (is_overall or std.mem.eql(u8, bases[0].rows[qi].question_type, gname)) count += 1;
        }
        try j.key("n");
        try j.int(@as(u64, count));
        try j.key("metrics");
        try j.beginObject();
        for (METRICS, 0..) |m, mi| {
            var k: usize = 0;
            var sb: f64 = 0;
            var sv: f64 = 0;
            for (0..n) |qi| {
                if (!is_overall and !std.mem.eql(u8, bases[0].rows[qi].question_type, gname)) continue;
                // Score files hold 9 decimals; the mean of five equal 9-decimal
                // values can differ from the value by one float ulp. A difference
                // below half a unit in the last place is no difference.
                var d = var_m[mi][qi] - base_m[mi][qi];
                if (@abs(d) < SNAP) d = 0;
                deltas[k] = d;
                sb += base_m[mi][qi];
                sv += var_m[mi][qi];
                k += 1;
            }
            try j.key(m.name);
            try j.beginObject();
            const t = pstats.tally(deltas[0..k]);
            const seed = boot_seed +% pstats.hashStr(gname) *% 31 +% @as(u64, mi);
            const iv = pstats.bootstrapMean2(alloc, deltas[0..k], resamples, seed, adj_level) catch |e| switch (e) {
                error.NoData => null,
                else => return e,
            };
            const kf: f64 = @floatFromInt(@max(k, 1));
            try j.key("base");
            try j.float(sb / kf);
            try j.key("variant");
            try j.float(sv / kf);
            try j.key("delta");
            try j.optFloat(if (iv) |v| v.mean else null);
            try j.key("ci95");
            try j.beginArray();
            try j.optFloat(if (iv) |v| v.ci95[0] else null);
            try j.optFloat(if (iv) |v| v.ci95[1] else null);
            try j.endArray();
            try j.key("ci_adj");
            try j.beginArray();
            try j.optFloat(if (iv) |v| v.ci_adj[0] else null);
            try j.optFloat(if (iv) |v| v.ci_adj[1] else null);
            try j.endArray();
            try j.key("improved");
            try j.int(@as(u64, t.improved));
            try j.key("worsened");
            try j.int(@as(u64, t.worsened));
            try j.key("same");
            try j.int(@as(u64, t.same));
            try j.endObject();
        }
        try j.endObject();
        try j.endObject();
    }
    try j.endObject();

    // Seed-to-seed spread: overall mean of each variant file minus the
    // overall mean of the baseline side.
    try j.key("per_file_overall_delta");
    try j.beginObject();
    for (METRICS, 0..) |m, mi| {
        try j.key(m.name);
        try j.beginArray();
        const bmean = pstats.mean(base_m[mi]);
        for (var_file_m[mi]) |v| try j.float(v - bmean);
        try j.endArray();
    }
    try j.endObject();
    try j.endObject();
    try harness.finish(alloc, &j);
}

pub fn runSynthetic(alloc: Allocator, init: std.process.Init.Minimal) !void {
    _ = init;
    const g = try abl.synthGoalConditioned(alloc);
    const s = try abl.synthSourceRouted(alloc);
    var j = harness.Json.init(alloc);
    defer j.deinit();
    try j.beginObject();
    try j.key("tool");
    try j.str("lme-synthetic");
    try j.key("label");
    try j.str("SYNTHETIC: built so that the machinery should win; a wiring check, not evidence of usefulness on real data");
    try j.key("goal_conditioned");
    try j.beginObject();
    try j.key("queries");
    try j.int(@as(u64, g.queries));
    try j.key("top1_hits_goal_bonus_off");
    try j.int(@as(u64, g.hits_off));
    try j.key("top1_hits_goal_bonus_on");
    try j.int(@as(u64, g.hits_on));
    try j.key("chance_top1");
    try j.float(1.0 / 8.0);
    try j.endObject();
    try j.key("source_routed");
    try j.beginObject();
    try j.key("queries");
    try j.int(@as(u64, s.queries));
    try j.key("top1_hits_no_router");
    try j.int(@as(u64, s.hits_off));
    try j.key("top1_hits_source_router");
    try j.int(@as(u64, s.hits_on));
    try j.key("chance_top1");
    try j.float(1.0 / 3.0);
    try j.endObject();
    try j.endObject();
    try harness.finish(alloc, &j);
}
