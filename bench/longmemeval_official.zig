//! `mem3-bench longmemeval-official` — retrieval metrics on the OFFICIAL
//! LongMemEval dataset (Wu et al., `xiaowu0162/longmemeval-cleaned`).
//!
//! # Read the disclaimer before the number
//!
//! This reports **retrieval** Recall@k / NDCG@k against the dataset's own
//! evidence labels and nothing else. There is no LLM reader and no LLM judge,
//! so none of it is a QA accuracy and none of it is comparable to a published
//! QA number. It is the same shape of measurement as the retrieval table in
//! the LongMemEval repository, produced by the product's own `Store.query`
//! path rather than by a stand-alone retriever.
//!
//! It is the counterpart of `longmemeval.zig`, which is an offline
//! re-implementation on a locally generated case set and says so. Neither
//! number substitutes for the other.
//!
//! The metric math, corpus construction and exclusion rules live in
//! `src/eval/longmemeval_official.zig` (library side, so they are unit
//! tested). This file is argument parsing, the per-question loop, and output.
//!
//! The dataset is never read from inside the repository and never committed:
//! `--data=PATH` points at a file the caller downloaded (see
//! `docs/benchmarks/longmemeval-official.md`).

const std = @import("std");
const mem3 = @import("mem3");
const harness = @import("harness.zig");

const lme = mem3.eval.longmemeval_official;
const fs = mem3.platform.fs;
const Allocator = std.mem.Allocator;

const DISCLAIMER =
    "RETRIEVAL METRICS ONLY. Recall@k and NDCG@k against the official " ++
    "LongMemEval evidence labels (answer sessions / has_answer turns), " ++
    "measured through mem3's Store.query on a fresh in-memory store per " ++
    "question. There is NO LLM reader and NO LLM judge, so this is NOT " ++
    "comparable to any published QA accuracy (e.g. the 94.4% / 83% vendor " ++
    "figures in other docs). Retrieval recall is the same kind of quantity " ++
    "as the retrieval table in the official LongMemEval repository, but this " ++
    "run uses mem3's built-in hashed lexical embedder by default, so it is a " ++
    "characterisation of mem3, not a leaderboard entry. Abstention (_abs) " ++
    "questions and questions with no labelled target turn are excluded from " ++
    "every average, as in the official script.";

const PROTOCOL_NOTES = [_][]const u8{
    "metric definitions transcribed from the official src/retrieval/eval_utils.py (recall_any, recall_all, ndcg; dcg leaves rank 2 undiscounted)",
    "corpus = USER turns only by default (official); --roles=all also indexes assistant turns and is NOT the official configuration",
    "an answer_ session with no user-side has_answer turn is relabelled noans_* and is not a correct document (official)",
    "turn-level run also reports session-level metrics derived with the official turn->session rule (k widened until k distinct sessions)",
    "abstention (_abs) questions and questions with no user-side evidence turn are excluded from averages (official)",
    "scripts/lme_official_crosscheck.py re-scores a --dump-rankings file with the official eval_utils.py to check this transcription",
};

const Args = struct {
    data: ?[]const u8 = null,
    limit: ?usize = null,
    opts: lme.Options = .{},
    dump_rankings: ?[]const u8 = null,
};

fn usage() void {
    harness.out(
        \\longmemeval-official — retrieval Recall@k / NDCG@k on the official dataset
        \\
        \\  --data=PATH           longmemeval_s_cleaned.json (or _oracle / _m); REQUIRED
        \\  --granularity=G       session (default) | turn
        \\  --roles=R             user (default, official) | all
        \\  --arm=A               hybrid (default, product weights) | dense | bm25
        \\  --limit=N             evaluate a seeded random sample of N questions
        \\                         (taken before exclusions); default: all
        \\  --seed=N              sample seed for --limit (default 42)
        \\  --depth=N             ranking depth from Store.query (default 0 = whole corpus)
        \\  --dump-rankings=PATH  JSONL of corpus ids + ranking per question, for
        \\                         scripts/lme_official_crosscheck.py
        \\  --embedder-cmd=PATH   external embedder (see bench longmemeval --help)
        \\  --embedder-arg=ARG    one argument for it; repeatable
        \\  --embed-dim=N         vector width for the external embedder (default 384)
        \\
        \\Progress and the human table go to stderr; stdout is one JSON document.
        \\
    , .{});
}

fn readWholeFile(alloc: Allocator, path: []const u8) ![]u8 {
    const zp = fs.z(path);
    const fd = try fs.open(zp.ptr(), .{ .access = .read_only });
    defer fs.close(fd);
    const size: usize = @intCast(try fs.sizeOf(fd));
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    const got = try fs.readFull(fd, buf);
    if (got != size) return error.ShortRead;
    return buf;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(bytes);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn writeMetrics(j: *harness.Json, row: ?lme.MetricRow) !void {
    try j.beginObject();
    const names = [_][]const u8{ "recall_any", "recall_all", "ndcg" };
    for (names, 0..) |name, mi| {
        try j.key(name);
        try j.beginObject();
        for (lme.KS, 0..) |k, ki| {
            var kb: [8]u8 = undefined;
            const ks = std.fmt.bufPrint(&kb, "@{d}", .{k}) catch unreachable;
            try j.key(ks);
            if (row) |r| {
                const v = switch (mi) {
                    0 => r.recall_any[ki],
                    1 => r.recall_all[ki],
                    else => r.ndcg[ki],
                };
                try j.float(v);
            } else try j.nullValue();
        }
        try j.endObject();
    }
    try j.endObject();
}

const Level = enum { primary, derived };

fn meanOf(g: lme.Group, level: Level) ?lme.MetricRow {
    return if (level == .primary) g.meanPrimary() else g.meanDerived();
}

fn writeGroup(j: *harness.Json, g: lme.Group, level: Level) !void {
    try j.beginObject();
    try j.key("n");
    try j.int(@as(u64, @intCast(g.n)));
    try j.key("metrics");
    try writeMetrics(j, meanOf(g, level));
    try j.endObject();
}

fn writeLevel(j: *harness.Json, agg: *const lme.Aggregate, level: Level) !void {
    try j.beginObject();
    try j.key("overall");
    try writeGroup(j, agg.overall, level);
    try j.key("by_question_type");
    try j.beginObject();
    for (agg.groups.items) |g| {
        try j.key(g.name);
        try writeGroup(j, g, level);
    }
    try j.endObject();
    try j.endObject();
}

fn tableRow(name: []const u8, g: lme.Group, level: Level) void {
    const m = meanOf(g, level) orelse {
        harness.progress("  {s:<28} {d:>4}   (no questions)\n", .{ name, g.n });
        return;
    };
    // k = 1, 3, 5, 10 are columns 0..3 of KS.
    harness.progress(
        "  {s:<28} {d:>4}  | {d:.3} {d:.3} {d:.3} {d:.3} | {d:.3} {d:.3} {d:.3} {d:.3} | {d:.3} {d:.3} {d:.3} {d:.3}\n",
        .{
            name,           g.n,
            m.recall_any[0], m.recall_any[1], m.recall_any[2], m.recall_any[3],
            m.recall_all[0], m.recall_all[1], m.recall_all[2], m.recall_all[3],
            m.ndcg[0],       m.ndcg[1],       m.ndcg[2],       m.ndcg[3],
        },
    );
}

fn printTable(title: []const u8, agg: *const lme.Aggregate, level: Level) void {
    harness.progress("\n{s}\n", .{title});
    harness.progress(
        "  {s:<28} {s:>4}  | {s:<23} | {s:<23} | {s:<23}\n",
        .{ "question_type", "n", "recall_any @1 @3 @5 @10", "recall_all @1 @3 @5 @10", "ndcg @1 @3 @5 @10" },
    );
    for (agg.groups.items) |g| tableRow(g.name, g, level);
    tableRow("OVERALL", agg.overall, level);
}

fn writeDumpLine(alloc: Allocator, fd: fs.Fd, q: lme.Question, gran: lme.Granularity, r: lme.Ranked) !void {
    var j = harness.Json.init(alloc);
    defer j.deinit();
    try j.beginObject();
    try j.key("question_id");
    try j.str(q.question_id);
    try j.key("question_type");
    try j.str(q.question_type);
    try j.key("granularity");
    try j.str(@tagName(gran));
    try j.key("corpus_ids");
    try j.beginArray();
    for (r.docs) |d| try j.str(d.id);
    try j.endArray();
    try j.key("ranking");
    try j.beginArray();
    for (r.ranking) |idx| try j.int(@as(u64, idx));
    try j.endArray();
    try j.endObject();
    try j.buf.append(alloc, '\n');
    try fs.writeAll(fd, j.buf.items);
}

pub fn run(alloc: Allocator, init: std.process.Init.Minimal) !void {
    var common = harness.CommonArgs{};
    var args = Args{};
    var emb_args = std.ArrayList([]const u8).empty;
    defer emb_args.deinit(alloc);

    var it = harness.argIterator(init);
    while (it.next()) |arg| {
        if (try harness.parseCommon(arg, &common)) continue;
        if (std.mem.startsWith(u8, arg, "--data=")) {
            args.data = arg["--data=".len..];
        } else if (std.mem.startsWith(u8, arg, "--granularity=")) {
            args.opts.granularity = lme.Granularity.parse(arg["--granularity=".len..]) orelse return error.BadGranularity;
        } else if (std.mem.startsWith(u8, arg, "--roles=")) {
            args.opts.roles = lme.Roles.parse(arg["--roles=".len..]) orelse return error.BadRoles;
        } else if (std.mem.startsWith(u8, arg, "--arm=")) {
            args.opts.arm = lme.Arm.parse(arg["--arm=".len..]) orelse return error.BadArm;
        } else if (std.mem.startsWith(u8, arg, "--limit=")) {
            args.limit = try std.fmt.parseInt(usize, arg["--limit=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--depth=")) {
            args.opts.depth = try std.fmt.parseInt(usize, arg["--depth=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--dump-rankings=")) {
            args.dump_rankings = arg["--dump-rankings=".len..];
        } else if (std.mem.startsWith(u8, arg, "--embedder-cmd=")) {
            args.opts.embedder_cmd = arg["--embedder-cmd=".len..];
        } else if (std.mem.startsWith(u8, arg, "--embedder-arg=")) {
            try emb_args.append(alloc, arg["--embedder-arg=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--embed-dim=")) {
            args.opts.embed_dim = try std.fmt.parseInt(u16, arg["--embed-dim=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        } else {
            harness.out("longmemeval-official: unknown argument {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    args.opts.embedder_args = emb_args.items;

    const data_path = args.data orelse {
        harness.out("longmemeval-official: --data=PATH is required (see --help)\n", .{});
        return error.MissingData;
    };

    const t_total = harness.clockNs();

    harness.progress("longmemeval-official: reading {s}...\n", .{data_path});
    const input = try readWholeFile(alloc, data_path);
    defer alloc.free(input);
    const sha = sha256Hex(input);

    const spans = try lme.indexQuestions(alloc, input);
    defer alloc.free(spans);

    // Seeded sample over ALL questions (before exclusions), file order kept.
    const selected = try alloc.alloc(usize, spans.len);
    defer alloc.free(selected);
    for (selected, 0..) |*s, i| s.* = i;
    var n_sel: usize = spans.len;
    if (args.limit) |lim| {
        if (lim < spans.len) {
            var rng = harness.Rng.init(common.seed);
            var i: usize = spans.len;
            while (i > 1) : (i -= 1) {
                const jx = rng.below(i);
                std.mem.swap(usize, &selected[i - 1], &selected[jx]);
            }
            n_sel = lim;
            std.mem.sort(usize, selected[0..n_sel], {}, std.sort.asc(usize));
        }
    }

    var dump_fd: ?fs.Fd = null;
    if (args.dump_rankings) |p| {
        const zp = fs.z(p);
        dump_fd = try fs.open(zp.ptr(), .{ .access = .write_only, .create = .truncate });
    }
    defer if (dump_fd) |fd| fs.close(fd);

    var agg = lme.Aggregate.init(alloc);
    defer agg.deinit();

    var disagree: usize = 0;
    var ingest_failures: usize = 0;
    var empty_text_docs: usize = 0;
    var first_add_error: ?[]const u8 = null;
    var docs_total: u64 = 0;
    var ranked_total: u64 = 0;
    var evaluated: usize = 0;

    harness.progress(
        "longmemeval-official: {d} questions in file, {d} selected, granularity={s} roles={s} arm={s}\n",
        .{ spans.len, n_sel, @tagName(args.opts.granularity), @tagName(args.opts.roles), @tagName(args.opts.arm) },
    );

    var done: usize = 0;
    for (selected[0..n_sel]) |qi| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const sp = spans[qi];
        const q = try lme.parseQuestion(arena, input[sp.start..sp.end]);
        if (lme.answerIdsDisagree(q)) disagree += 1;

        const elig = lme.classify(q, args.opts.roles);
        done += 1;
        if (elig != .eligible) {
            agg.noteSkipped(elig);
            continue;
        }

        const r = try lme.rank(alloc, q, args.opts);
        defer r.deinit(alloc);
        const sc = try lme.scoreRanked(alloc, r, args.opts.granularity);
        try agg.add(q.question_type, sc);

        evaluated += 1;
        ingest_failures += r.ingest_failures;
        empty_text_docs += r.empty_text;
        if (r.first_add_error) |name| {
            if (first_add_error == null) first_add_error = name;
        }
        docs_total += r.docs.len;
        ranked_total += r.ranking.len;
        if (dump_fd) |fd| try writeDumpLine(alloc, fd, q, args.opts.granularity, r);

        if (done % 25 == 0) {
            const el = harness.nsToMs(harness.sinceNs(t_total)) / 1000.0;
            harness.progress("longmemeval-official: {d}/{d} questions, {d:.0}s elapsed\n", .{ done, n_sel, el });
        }
    }
    agg.sortGroups();

    const wall_s = harness.nsToMs(harness.sinceNs(t_total)) / 1000.0;

    // -------------------------------------------------------------- human table
    harness.progress("\nlongmemeval-official | retrieval only, no LLM reader/judge | wall {d:.1}s\n", .{wall_s});
    harness.progress(
        "evaluated {d} of {d} selected (abstention excluded: {d}, no user-side target: {d})\n",
        .{ evaluated, n_sel, agg.skipped_abstention, agg.skipped_no_target },
    );
    printTable(
        if (args.opts.granularity == .session) "SESSION-level (corpus = one doc per session)" else "TURN-level (corpus = one doc per turn)",
        &agg,
        .primary,
    );
    if (agg.has_derived) {
        printTable("SESSION-level derived from the turn ranking (official turn->session rule)", &agg, .derived);
    }
    harness.progress("\nNOT comparable to published QA accuracy: no LLM reader or judge was run.\n", .{});

    // ---------------------------------------------------------------------- JSON
    var j = harness.Json.init(alloc);
    defer j.deinit();

    const headline = agg.overall.meanPrimary();
    try harness.emitEnvelope(&j, .{
        .benchmark = "longmemeval-official",
        .metric = "overall recall_any@10 at the requested granularity",
        .target = "none: retrieval-only, no constitutional target applies",
        .target_comparison = "none",
        .unit = "fraction",
        .measured = if (headline) |h| h.recall_any[3] else null,
        .measured_at_N = @intCast(agg.overall.n),
        .null_reason = if (headline == null) "no eligible question was evaluated" else null,
        .seed = common.seed,
        .notes = "Retrieval recall on the official LongMemEval dataset. No LLM " ++
            "reader or judge; not comparable to QA accuracy. See disclaimer.",
    });

    try j.key("benchmark_suite");
    try j.str("longmemeval-official-retrieval");
    try j.key("disclaimer");
    try j.str(DISCLAIMER);
    try j.key("judge_model");
    try j.str("none — retrieval metrics only");
    try j.key("protocol");
    try j.beginArray();
    for (PROTOCOL_NOTES) |n| try j.str(n);
    try j.endArray();

    try j.key("dataset");
    try j.beginObject();
    try j.key("file");
    const base = if (std.mem.lastIndexOfScalar(u8, data_path, '/')) |i| data_path[i + 1 ..] else data_path;
    try j.str(base);
    try j.key("bytes");
    try j.int(@as(u64, @intCast(input.len)));
    try j.key("sha256");
    try j.str(&sha);
    try j.key("questions_in_file");
    try j.int(@as(u64, @intCast(spans.len)));
    try j.endObject();

    try j.key("config");
    try j.beginObject();
    try j.key("granularity");
    try j.str(@tagName(args.opts.granularity));
    try j.key("roles");
    try j.str(@tagName(args.opts.roles));
    try j.key("arm");
    try j.str(@tagName(args.opts.arm));
    try j.key("embedder");
    try j.str(if (args.opts.embedder_cmd) |c| c else "lexical_hash (the Store default)");
    try j.key("ranking_depth");
    try j.optInt(if (args.opts.depth == 0) null else @as(?u64, @intCast(args.opts.depth)));
    try j.key("ranking_depth_note");
    try j.str("null = the whole corpus is requested from Store.query");
    try j.key("sample");
    try j.str(if (args.limit != null and n_sel < spans.len)
        "seeded random subset (--limit with --seed), drawn before exclusions"
    else
        "all questions in the file");
    try j.key("ks");
    try j.beginArray();
    for (lme.KS) |k| try j.int(@as(u64, @intCast(k)));
    try j.endArray();
    try j.key("store_path");
    try j.str("fresh in-memory Store per question; Store.query (GHW goal-aware rerank included); " ++
        "no hyperedges are added, so the graph arm contributes only seeds");
    try j.endObject();

    try j.key("counts");
    try j.beginObject();
    try j.key("selected");
    try j.int(@as(u64, @intCast(n_sel)));
    try j.key("evaluated");
    try j.int(@as(u64, @intCast(evaluated)));
    try j.key("excluded_abstention");
    try j.int(@as(u64, @intCast(agg.skipped_abstention)));
    try j.key("excluded_no_user_side_target");
    try j.int(@as(u64, @intCast(agg.skipped_no_target)));
    try j.key("answer_session_ids_disagree_with_haystack_answer_ids");
    try j.int(@as(u64, @intCast(disagree)));
    try j.key("ingest_failures");
    try j.int(@as(u64, @intCast(ingest_failures)));
    try j.key("ingest_failures_empty_text");
    try j.int(@as(u64, @intCast(empty_text_docs)));
    try j.key("first_add_error");
    try j.optStr(first_add_error);
    try j.key("mean_corpus_docs_per_question");
    try j.optFloat(if (evaluated == 0) null else @as(f64, @floatFromInt(docs_total)) / @as(f64, @floatFromInt(evaluated)));
    try j.key("mean_fraction_of_corpus_ranked");
    try j.optFloat(if (docs_total == 0) null else @as(f64, @floatFromInt(ranked_total)) / @as(f64, @floatFromInt(docs_total)));
    try j.endObject();

    try j.key("results");
    try j.beginObject();
    try j.key("level");
    try j.str(@tagName(args.opts.granularity));
    try j.key("primary");
    try writeLevel(&j, &agg, .primary);
    if (agg.has_derived) {
        try j.key("session_from_turn");
        try writeLevel(&j, &agg, .derived);
    }
    try j.endObject();

    try j.key("timing");
    try j.beginObject();
    try j.key("wall_seconds");
    try j.float(wall_s);
    try j.key("ms_per_evaluated_question");
    try j.optFloat(if (evaluated == 0) null else wall_s * 1000.0 / @as(f64, @floatFromInt(evaluated)));
    try j.endObject();

    try j.endObject();
    try harness.finish(alloc, &j);
}
