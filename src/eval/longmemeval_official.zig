//! Retrieval evaluation against the OFFICIAL LongMemEval dataset
//! (Wu et al., `xiaowu0162/longmemeval-cleaned`).
//!
//! **GHW layer**: Harness 层 (象源). This is evaluation protocol: it turns an
//! external dataset into a store, a query and a score. It adds no memory
//! semantics of its own and never changes a product default.
//!
//! ## What this measures, and what it deliberately does not
//!
//! Retrieval only: for each question a fresh in-memory `Store` ingests that
//! question's haystack, the question text is the query, and the ranked cells
//! are mapped back to sessions (or turns). Recall@k and NDCG@k are computed
//! against the dataset's own evidence labels. There is **no LLM reader and no
//! LLM judge**, so nothing here is a QA accuracy and none of it is comparable
//! to a published QA number.
//!
//! ## Protocol fidelity
//!
//! The metric definitions, the corpus construction and the exclusion rules
//! below are a transcription of the official repository's
//! `src/retrieval/eval_utils.py`, `src/retrieval/run_retrieval.py` and
//! `src/evaluation/print_retrieval_metrics.py` as read on 2026-10-21, not a
//! re-derivation from the paper. The quirks that matter are kept on purpose,
//! and each is named where it lives:
//!
//!   * the corpus is **user turns only** by default (`Roles.user`);
//!   * an evidence session with no user-side `has_answer` turn is relabelled
//!     `noans_*` and is not a correct document;
//!   * `dcg` leaves rank 2 undiscounted (`log2(2) == 1`), which differs from
//!     textbook NDCG;
//!   * turn->session widens `k` until `k` distinct sessions were seen;
//!   * abstention (`_abs`) questions and questions with no user-side
//!     evidence turn are excluded from every average.
//!
//! `scripts/lme_official_crosscheck.py` re-scores a ranking dump with the
//! official `eval_utils.py` itself so the transcription can be checked rather
//! than trusted.

const std = @import("std");
const Allocator = std.mem.Allocator;

const store_mod = @import("../store/store.zig");
const core = @import("../core/mod.zig");
const abl = @import("lme_ablation.zig");
const time = @import("../utils/time.zig");

/// Cut-offs reported. 1/3/5/10 are the task; 30 and 50 are what the official
/// script also records.
pub const KS = [_]usize{ 1, 3, 5, 10, 30, 50 };
pub const NK = KS.len;

pub const Granularity = enum {
    session,
    turn,

    pub fn parse(s: []const u8) ?Granularity {
        return std.meta.stringToEnum(Granularity, s);
    }
};

/// Which turns become part of the corpus. `.user` is the official protocol;
/// `.all` is an extension (assistant turns indexed too) and is NOT the
/// official configuration.
pub const Roles = enum {
    user,
    all,

    pub fn parse(s: []const u8) ?Roles {
        return std.meta.stringToEnum(Roles, s);
    }
};

/// Which fusion arms are live. Switching sets the retriever's λ weights for
/// one run; the product defaults in `core/config.zig` are untouched.
pub const Arm = enum {
    /// Product default: λ_dense=0.5, λ_sparse=0.2, λ_graph=0.3.
    hybrid,
    /// Dense (HNSW over the embedder) only.
    dense,
    /// Lexical (BM25) only.
    bm25,

    pub fn parse(s: []const u8) ?Arm {
        return std.meta.stringToEnum(Arm, s);
    }
};

// ============================================================================
// Metrics (transcribed from the official eval_utils.py)
// ============================================================================

pub const MetricRow = struct {
    recall_any: [NK]f64 = @splat(0),
    recall_all: [NK]f64 = @splat(0),
    ndcg: [NK]f64 = @splat(0),
};

pub const Triple = struct { any: f64, all: f64, ndcg: f64 };

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

/// Official `dcg`: `rel[0] + sum(rel[1:] / log2(2..n))`. Rank 1 and rank 2
/// both carry weight 1 (log2(2) == 1). Kept verbatim so numbers line up with
/// the official script; textbook NDCG would discount rank 2 by 1/log2(3).
fn dcgOfficial(rels: []const f64, k: usize) f64 {
    const n = @min(k, rels.len);
    if (n == 0) return 0;
    var total: f64 = rels[0];
    var j: usize = 1;
    while (j < n) : (j += 1) {
        total += rels[j] / @log2(@as(f64, @floatFromInt(j + 1)));
    }
    return total;
}

/// Official `ndcg`: binary relevance per corpus entry, actual DCG over
/// `ranking[:k]`, ideal DCG over all relevances sorted descending.
fn ndcgOfficial(
    ranking: []const u32,
    corpus_ids: []const []const u8,
    correct: []const []const u8,
    k: usize,
) f64 {
    const n_rel = blk: {
        var c: usize = 0;
        for (corpus_ids) |id| {
            if (contains(correct, id)) c += 1;
        }
        break :blk c;
    };

    // Actual: relevance of ranking[:k], in rank order.
    var actual: f64 = 0;
    const take = @min(k, ranking.len);
    if (take > 0) {
        const rel0: f64 = if (contains(correct, corpus_ids[ranking[0]])) 1 else 0;
        actual = rel0;
        var j: usize = 1;
        while (j < take) : (j += 1) {
            const rel: f64 = if (contains(correct, corpus_ids[ranking[j]])) 1 else 0;
            actual += rel / @log2(@as(f64, @floatFromInt(j + 1)));
        }
    }

    // Ideal: n_rel ones followed by zeros, cut at k. Closed form of
    // `dcg(sorted(relevances, reverse=True), k)`.
    var ideal: f64 = 0;
    const ideal_take = @min(k, corpus_ids.len);
    const ones = @min(n_rel, ideal_take);
    if (ones > 0) {
        ideal = 1;
        var j: usize = 1;
        while (j < ones) : (j += 1) {
            ideal += 1.0 / @log2(@as(f64, @floatFromInt(j + 1)));
        }
    }
    if (ideal == 0) return 0;
    return actual / ideal;
}

/// Official `evaluate_retrieval`. `ranking` holds corpus indices, best first.
/// `correct` is a set of document ids (no duplicates expected).
pub fn evaluateRetrieval(
    ranking: []const u32,
    corpus_ids: []const []const u8,
    correct: []const []const u8,
    k: usize,
) Triple {
    const take = @min(k, ranking.len);
    var any = false;
    var all = true;
    for (correct) |doc| {
        var hit = false;
        for (ranking[0..take]) |idx| {
            if (std.mem.eql(u8, corpus_ids[idx], doc)) {
                hit = true;
                break;
            }
        }
        if (hit) any = true else all = false;
    }
    return .{
        .any = if (any) 1.0 else 0.0,
        // Python `all([])` is True; a question with no correct doc is
        // excluded upstream, this only keeps the transcription faithful.
        .all = if (all) 1.0 else 0.0,
        .ndcg = ndcgOfficial(ranking, corpus_ids, correct, k),
    };
}

/// Official `strip_turn_id`: `'_'.join(docid.split('_')[:-1])`, i.e. drop
/// the last `_`-separated component. No underscore -> empty string.
fn stripTurnId(id: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, id, '_') orelse return "";
    return id[0..i];
}

/// Official `evaluate_retrieval_turn2session`: labels and corpus are mapped
/// to session ids by stripping the turn suffix, and `k` is widened until `k`
/// distinct sessions appear in the ranking prefix.
pub fn evaluateTurnToSession(
    alloc: Allocator,
    ranking: []const u32,
    corpus_ids: []const []const u8,
    correct: []const []const u8,
    k: usize,
) !Triple {
    const sess_ids = try alloc.alloc([]const u8, corpus_ids.len);
    defer alloc.free(sess_ids);
    for (corpus_ids, 0..) |id, i| sess_ids[i] = stripTurnId(id);

    // `list(set(...))` in the official code: unique session labels.
    var correct_sess = std.ArrayList([]const u8).empty;
    defer correct_sess.deinit(alloc);
    for (correct) |id| {
        const s = stripTurnId(id);
        if (!contains(correct_sess.items, s)) try correct_sess.append(alloc, s);
    }

    // uniq[j] = distinct sessions in ranking[0..j].
    const uniq = try alloc.alloc(usize, ranking.len + 1);
    defer alloc.free(uniq);
    {
        var seen = std.ArrayList([]const u8).empty;
        defer seen.deinit(alloc);
        uniq[0] = 0;
        for (ranking, 0..) |idx, j| {
            if (!contains(seen.items, sess_ids[idx])) try seen.append(alloc, sess_ids[idx]);
            uniq[j + 1] = seen.items.len;
        }
    }

    var eff = k;
    while (eff <= corpus_ids.len and uniq[@min(eff, ranking.len)] < k) eff += 1;

    return evaluateRetrieval(ranking, sess_ids, correct_sess.items, eff);
}

// ============================================================================
// Dataset
// ============================================================================

pub const Turn = struct {
    role: []const u8,
    content: []const u8,
    has_answer: bool = false,
};

/// One question in the official schema. Fields the harness does not read
/// (`answer`, which is a string or an integer, `haystack_dates`,
/// `question_date`) are skipped by the parser.
pub const Question = struct {
    question_id: []const u8,
    question_type: []const u8,
    question: []const u8,
    haystack_session_ids: []const []const u8,
    haystack_sessions: []const []const Turn,
    answer_session_ids: []const []const u8 = &.{},
    /// Read only by the ablation variants that simulate age
    /// (`Variant.simulate_age`); the default harness never looks at them.
    haystack_dates: []const []const u8 = &.{},
    question_date: []const u8 = "",
};

pub const Span = struct { start: usize, end: usize };

pub const DatasetError = error{MalformedDataset};

/// Locate every top-level element of the dataset's outer JSON array without
/// building a tree. The S file is 277 MB; indexing it is one pass over the
/// bytes, and each question is then parsed on demand into its own arena.
pub fn indexQuestions(alloc: Allocator, input: []const u8) ![]Span {
    var spans = std.ArrayList(Span).empty;
    errdefer spans.deinit(alloc);

    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var start: usize = 0;
    for (input, 0..) |ch, i| {
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (ch == '\\') {
                esc = true;
            } else if (ch == '"') {
                in_str = false;
            }
            continue;
        }
        switch (ch) {
            '"' => in_str = true,
            '{', '[' => {
                depth += 1;
                if (depth == 2 and ch == '{') start = i;
            },
            '}', ']' => {
                if (depth == 0) return error.MalformedDataset;
                depth -= 1;
                if (depth == 1 and ch == '}') try spans.append(alloc, .{ .start = start, .end = i + 1 });
            },
            else => {},
        }
    }
    if (depth != 0 or in_str) return error.MalformedDataset;
    return spans.toOwnedSlice(alloc);
}

/// Parse one question. Everything allocated lives in `arena`.
pub fn parseQuestion(arena: Allocator, slice: []const u8) !Question {
    return std.json.parseFromSliceLeaky(Question, arena, slice, .{ .ignore_unknown_fields = true });
}

pub const Eligibility = enum {
    eligible,
    /// `_abs` in the question id: the correct behaviour is to decline, so
    /// there is nothing to retrieve. Excluded from recall like the paper.
    abstention,
    /// No selected-role turn anywhere in the haystack carries
    /// `has_answer == true`, so there is no label to score against.
    no_target,
};

fn roleSelected(roles: Roles, turn: Turn) bool {
    return roles == .all or std.mem.eql(u8, turn.role, "user");
}

pub fn classify(q: Question, roles: Roles) Eligibility {
    if (std.mem.indexOf(u8, q.question_id, "_abs") != null) return .abstention;
    for (q.haystack_sessions) |sess| {
        for (sess) |t| {
            if (t.has_answer and roleSelected(roles, t)) return .eligible;
        }
    }
    return .no_target;
}

/// True when `answer_session_ids` disagrees with "haystack ids containing
/// `answer`", which is what the official script actually uses for labels.
/// Reported as a count so a dataset revision that breaks the equivalence is
/// visible instead of silently changing the labels.
pub fn answerIdsDisagree(q: Question) bool {
    var n_hay: usize = 0;
    for (q.haystack_session_ids, 0..) |id, i| {
        if (std.mem.indexOf(u8, id, "answer") == null) continue;
        // count each distinct id once
        var dup = false;
        for (q.haystack_session_ids[0..i]) |p| {
            if (std.mem.eql(u8, p, id)) dup = true;
        }
        if (dup) continue;
        n_hay += 1;
        if (!contains(q.answer_session_ids, id)) return true;
    }
    var n_ans: usize = 0;
    for (q.answer_session_ids, 0..) |id, i| {
        var dup = false;
        for (q.answer_session_ids[0..i]) |p| {
            if (std.mem.eql(u8, p, id)) dup = true;
        }
        if (!dup) n_ans += 1;
    }
    return n_ans != n_hay;
}

// ============================================================================
// Corpus construction
// ============================================================================

/// One retrievable unit. `id` is the official corpus id: the session id for
/// session granularity, `<session>_<1-based turn position>` for turn
/// granularity, with `answer` renamed `noans` where the official script does.
pub const Doc = struct {
    id: []const u8,
    text: []const u8,
    /// Index of the haystack session this document came from. Documents are
    /// emitted in session order, so equal values are contiguous.
    session: u32 = 0,
};

pub fn freeDocs(alloc: Allocator, docs: []Doc) void {
    for (docs) |d| {
        alloc.free(d.id);
        alloc.free(d.text);
    }
    alloc.free(docs);
}

/// Python's `str.replace('answer', 'noans')`, all occurrences.
fn replaceAnswerWithNoans(alloc: Allocator, s: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, alloc, s, "answer", "noans");
}

pub fn buildDocs(alloc: Allocator, q: Question, gran: Granularity, roles: Roles) ![]Doc {
    var docs = std.ArrayList(Doc).empty;
    errdefer {
        for (docs.items) |d| {
            alloc.free(d.id);
            alloc.free(d.text);
        }
        docs.deinit(alloc);
    }

    const n = @min(q.haystack_session_ids.len, q.haystack_sessions.len);
    for (0..n) |si| {
        const sess_id = q.haystack_session_ids[si];
        const turns = q.haystack_sessions[si];
        const is_answer_sess = std.mem.indexOf(u8, sess_id, "answer") != null;

        switch (gran) {
            .session => {
                var text = std.ArrayList(u8).empty;
                errdefer text.deinit(alloc);
                var any_answer = false;
                var first = true;
                for (turns) |t| {
                    if (!roleSelected(roles, t)) continue;
                    if (t.has_answer) any_answer = true;
                    if (!first) try text.append(alloc, ' ');
                    first = false;
                    try text.appendSlice(alloc, t.content);
                }
                // Official: an `answer` session with no labelled selected-role
                // turn is not a correct document.
                const id = if (is_answer_sess and !any_answer)
                    try replaceAnswerWithNoans(alloc, sess_id)
                else
                    try alloc.dupe(u8, sess_id);
                errdefer alloc.free(id);
                try docs.append(alloc, .{ .id = id, .text = try text.toOwnedSlice(alloc), .session = @intCast(si) });
            },
            .turn => {
                for (turns, 0..) |t, ti| {
                    if (!roleSelected(roles, t)) continue;
                    const raw = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ sess_id, ti + 1 });
                    errdefer alloc.free(raw);
                    const id = if (is_answer_sess and !t.has_answer) blk: {
                        const r = try replaceAnswerWithNoans(alloc, raw);
                        alloc.free(raw);
                        break :blk r;
                    } else raw;
                    errdefer alloc.free(id);
                    const text = try alloc.dupe(u8, t.content);
                    errdefer alloc.free(text);
                    try docs.append(alloc, .{ .id = id, .text = text, .session = @intCast(si) });
                }
            },
        }
    }
    return docs.toOwnedSlice(alloc);
}

/// Official: `correct_docs = list(set(ids containing "answer"))`.
pub fn correctDocIds(alloc: Allocator, docs: []const Doc) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(alloc);
    for (docs) |d| {
        if (std.mem.indexOf(u8, d.id, "answer") == null) continue;
        if (!contains(out.items, d.id)) try out.append(alloc, d.id);
    }
    return out.toOwnedSlice(alloc);
}

// ============================================================================
// Driving the real Store
// ============================================================================

pub const Options = struct {
    granularity: Granularity = .session,
    roles: Roles = .user,
    arm: Arm = .hybrid,
    /// Ranking depth requested from `Store.query`. 0 = the whole corpus, so
    /// k = 30/50 and the turn->session widening see as much of the ranking as
    /// the store is willing to return. The fraction actually returned is
    /// reported (`Ranked.ranked`), not assumed.
    depth: usize = 0,
    embed_dim: u16 = 384,
    embedder_cmd: ?[]const u8 = null,
    embedder_args: []const []const u8 = &.{},
    /// Ablation switches. The default value reproduces the pre-ablation
    /// harness exactly; see `lme_ablation.zig`.
    variant: abl.Variant = .{},
};

/// What a run actually did, so a variant that silently did nothing shows up
/// as a zero here instead of as a plausible-looking result.
pub const Diag = struct {
    /// Ingested documents per source (matter, form, spirit).
    tag_counts: [3]u32 = .{ 0, 0, 0 },
    goals_created: u32 = 0,
    edges_created: u32 = 0,
    ages_set: u32 = 0,
    ages_unparsed: u32 = 0,
    router_pred: ?core.MemorySource = null,
};

pub const Ranked = struct {
    docs: []Doc,
    /// Corpus indices, best first. Only docs the store returned appear.
    ranking: []u32,
    /// Docs the store did not index: empty text, or `addRaw` returned an
    /// error. Such a doc stays in the corpus (it can still be a correct
    /// answer) but can never be retrieved, so it is counted, never hidden.
    ingest_failures: usize,
    /// Of `ingest_failures`, how many were empty text (no `addRaw` call).
    empty_text: usize = 0,
    /// Name of the first `addRaw` error seen, if any (static string).
    first_add_error: ?[]const u8 = null,
    diag: Diag = .{},

    pub fn deinit(self: Ranked, alloc: Allocator) void {
        freeDocs(alloc, self.docs);
        alloc.free(self.ranking);
    }
};

fn applyArm(store: *store_mod.Store, arm: Arm) void {
    const w: [3]f32 = switch (arm) {
        .hybrid => return, // product defaults, untouched
        .dense => .{ 1, 0, 0 },
        .bm25 => .{ 0, 1, 0 },
    };
    // Two copies of the weights are live: the retriever sorts candidates
    // with `hybrid.cfg`, and `Store.query` re-scores them with `lc.cfg`.
    // Setting only one would measure a configuration nobody runs.
    store.hybrid.cfg.recall_lambda_dense = w[0];
    store.hybrid.cfg.recall_lambda_sparse = w[1];
    store.hybrid.cfg.recall_lambda_graph = w[2];
    store.lc.cfg.recall_lambda_dense = w[0];
    store.lc.cfg.recall_lambda_sparse = w[1];
    store.lc.cfg.recall_lambda_graph = w[2];
}

/// Apply the config-level variant switches. These write only to the two live
/// copies of the config the `Store` already exposes; nothing is stored back
/// into a product default.
fn applyVariantConfig(store: *store_mod.Store, v: abl.Variant) void {
    if (v.goal_bonus_weight) |w| store.lc.cfg.goal_bonus_weight = w;
    if (v.existence_bonus_weight) |w| store.lc.cfg.existence_bonus_weight = w;
    if (v.recency_bonus_weight) |w| store.lc.cfg.recency_bonus_weight = w;
    if (v.graph_off) {
        // Same two-copies rule as `applyArm`.
        store.hybrid.cfg.recall_lambda_graph = 0;
        store.lc.cfg.recall_lambda_graph = 0;
    }
}

/// `Variant.goals == .per_session`: one goal per haystack session, named
/// `g<session>` and described by the session's most frequent content words.
/// Uses only haystack text; no label, no question type, no `has_answer`.
/// Fills `goal_ids[i]` for every document of a session that has at least one
/// non-empty document.
fn createSessionGoals(
    alloc: Allocator,
    store: *store_mod.Store,
    docs: []const Doc,
    goal_ids: []u64,
    diag: *Diag,
) !void {
    const now_ms = time.nowMs();
    var lo: usize = 0;
    while (lo < docs.len) {
        var hi = lo + 1;
        while (hi < docs.len and docs[hi].session == docs[lo].session) hi += 1;

        var any = false;
        for (docs[lo..hi]) |d| {
            if (d.text.len > 0) any = true;
        }
        if (any) {
            var texts = try alloc.alloc([]const u8, hi - lo);
            defer alloc.free(texts);
            for (docs[lo..hi], 0..) |d, i| texts[i] = d.text;
            const desc = try abl.topicWords(alloc, texts, 12);
            defer alloc.free(desc);
            var name_buf: [24]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "g{d}", .{docs[lo].session});
            const gid = try store.createGoal(name, desc, null, 5, null, now_ms);
            @memset(goal_ids[lo..hi], gid);
            diag.goals_created += 1;
        }
        lo = hi;
    }
}

/// Build a fresh in-memory store, ingest the question's haystack, run the
/// question through `Store.query` (the product's recall path, goal-aware
/// rerank included) and map the returned cells back to corpus documents.
///
/// `opts.variant` selects an ablation (pre-registered in
/// `docs/benchmarks/ablation-tri-source.md`). With the default variant every
/// call below is the call the harness always made: source 物, goal 1,
/// relevance 0.5, product weights.
pub fn rank(alloc: Allocator, q: Question, opts: Options) !Ranked {
    const v = opts.variant;
    if (v.session_edges and opts.granularity != .turn) return error.EdgesNeedTurnGranularity;

    const docs = try buildDocs(alloc, q, opts.granularity, opts.roles);
    errdefer freeDocs(alloc, docs);

    const store = try store_mod.Store.init(alloc, .{
        .data_dir = null,
        .seed_default_goals = true,
        .embed_dim = opts.embed_dim,
        .embedder_cmd = opts.embedder_cmd,
        .embedder_args = opts.embedder_args,
    });
    defer store.deinit();
    applyArm(store, opts.arm);
    applyVariantConfig(store, v);

    var diag = Diag{};

    // Per-document tag, goal and cell id. All three are trivial under the
    // default variant (every doc 物, goal 1, no extra bookkeeping).
    const tags = try alloc.alloc(core.MemorySource, docs.len);
    defer alloc.free(tags);
    {
        const texts = try alloc.alloc([]const u8, docs.len);
        defer alloc.free(texts);
        for (docs, 0..) |d, i| texts[i] = d.text;
        try abl.assignTags(alloc, v.tags, v.tag_seed, q.question_id, texts, tags);
    }
    const goal_ids = try alloc.alloc(u64, docs.len);
    defer alloc.free(goal_ids);
    @memset(goal_ids, 1);
    const relevance: f32 = if (v.goals == .per_session) 1.0 else 0.5;
    if (v.goals == .per_session) try createSessionGoals(alloc, store, docs, goal_ids, &diag);

    const doc_cell = try alloc.alloc(u64, docs.len);
    defer alloc.free(doc_cell);
    @memset(doc_cell, 0);

    var cell_to_doc = std.AutoHashMap(u64, u32).init(alloc);
    defer cell_to_doc.deinit();
    var failures: usize = 0;
    var empty_text: usize = 0;
    var first_err: ?[]const u8 = null;
    const intent_foresight = [_]core.Foresight{.{
        .description = "intent",
        .valid_from = 0,
        .valid_until = time.nowMs() + 365 * 86_400_000,
        .confidence = 0.8,
    }};
    for (docs, 0..) |d, i| {
        if (d.text.len == 0) {
            failures += 1;
            empty_text += 1;
            continue;
        }
        // Default: source 物 (a dialogue turn is a raw trace of what
        // happened), goal 1, relevance 0.5 -- the call this harness always made.
        const added = if (v.foresight_on_spirit and tags[i] == .spirit)
            store.addRawWithForesight(tags[i], d.text, "", goal_ids[i], relevance, &intent_foresight)
        else
            store.addRaw(tags[i], d.text, "", goal_ids[i], relevance);
        const cell_id = added catch |err| {
            failures += 1;
            if (first_err == null) first_err = @errorName(err);
            continue;
        };
        doc_cell[i] = cell_id;
        diag.tag_counts[@backingInt(tags[i])] += 1;
        try cell_to_doc.put(cell_id, @intCast(i));
    }

    if (v.session_edges) try addSessionEdges(alloc, store, docs, doc_cell, &diag);
    if (v.simulate_age) simulateAges(store, q, docs, doc_cell, &diag);

    var ranking = std.ArrayList(u32).empty;
    errdefer ranking.deinit(alloc);
    const depth = if (opts.depth == 0) docs.len else @min(opts.depth, docs.len);
    if (depth > 0 and cell_to_doc.count() > 0) {
        const scored = try store.query(alloc, q.question, .{ .topk = depth });
        defer alloc.free(scored);

        // Harness-side source router (variant E): the store has no source
        // argument, so the permutation is applied to the ranking it returned.
        var order: ?[]u32 = null;
        defer if (order) |o| alloc.free(o);
        if (v.router != .none) {
            const scores = try alloc.alloc(f32, scored.len);
            defer alloc.free(scores);
            const sources = try alloc.alloc(core.MemorySource, scored.len);
            defer alloc.free(sources);
            for (scored, 0..) |s, k| {
                scores[k] = s.final_score;
                sources[k] = s.cell.source;
            }
            const pred = abl.classifyHeuristic(q.question);
            diag.router_pred = pred;
            order = try abl.routeOrder(alloc, scores, sources, pred, v.router, v.router_boost);
        }
        var k: usize = 0;
        while (k < scored.len) : (k += 1) {
            const s = if (order) |o| scored[o[k]] else scored[k];
            const di = cell_to_doc.get(s.cell.id) orelse continue;
            try ranking.append(alloc, di);
        }
    }
    return .{
        .docs = docs,
        .ranking = try ranking.toOwnedSlice(alloc),
        .ingest_failures = failures,
        .empty_text = empty_text,
        .first_add_error = first_err,
        .diag = diag,
    };
}

/// Variant H_edges: one `associative` hyperedge per session over that
/// session's ingested documents. Natural structure only; no labels.
fn addSessionEdges(
    alloc: Allocator,
    store: *store_mod.Store,
    docs: []const Doc,
    doc_cell: []const u64,
    diag: *Diag,
) !void {
    var ids = std.ArrayList(u64).empty;
    defer ids.deinit(alloc);
    var lo: usize = 0;
    while (lo < docs.len) {
        var hi = lo + 1;
        while (hi < docs.len and docs[hi].session == docs[lo].session) hi += 1;
        ids.clearRetainingCapacity();
        for (doc_cell[lo..hi]) |c| {
            if (c != 0) try ids.append(alloc, c);
        }
        if (ids.items.len >= 2) {
            _ = try store.addHyperedge(.{
                .id = 0,
                .edge_type = .associative,
                .nodes = ids.items,
                .weight = 1.0,
                .source_weights = .{ 1.0, 0.0, 0.0 },
                .confidence = 1.0,
                .created_at = 0,
            });
            diag.edges_created += 1;
        }
        lo = hi;
    }
}

/// Variant J: give every cell the age its session really had relative to the
/// question date, so `exp(-decay_rate * age_days)` in the recency factor is
/// live. `created_at = t_ref - age`, with `t_ref` read once after ingestion;
/// the query then runs milliseconds later, which is below f32 resolution of
/// the factor. A doc whose session date or the question date does not parse
/// keeps its real (age ~ 0) timestamp and is counted.
fn simulateAges(
    store: *store_mod.Store,
    q: Question,
    docs: []const Doc,
    doc_cell: []const u64,
    diag: *Diag,
) void {
    const qd = abl.parseDateMs(q.question_date);
    const t_ref = time.nowMs();
    for (docs, doc_cell) |d, cell_id| {
        if (cell_id == 0) continue;
        const sd = if (d.session < q.haystack_dates.len) abl.parseDateMs(q.haystack_dates[d.session]) else null;
        if (qd == null or sd == null) {
            diag.ages_unparsed += 1;
            continue;
        }
        const age_ms: i64 = @max(0, qd.? - sd.?);
        store.getCell(cell_id).?.metadata.created_at = t_ref - age_ms;
        diag.ages_set += 1;
    }
}

pub const QuestionScore = struct {
    /// Metrics at the requested granularity.
    primary: MetricRow,
    /// Session-level metrics derived from a turn ranking (official
    /// turn->session). Null for session granularity.
    derived: ?MetricRow,
};

pub fn scoreRanked(alloc: Allocator, r: Ranked, gran: Granularity) !QuestionScore {
    const ids = try alloc.alloc([]const u8, r.docs.len);
    defer alloc.free(ids);
    for (r.docs, 0..) |d, i| ids[i] = d.id;
    const correct = try correctDocIds(alloc, r.docs);
    defer alloc.free(correct);

    var primary = MetricRow{};
    var derived = MetricRow{};
    for (KS, 0..) |k, ki| {
        const t = evaluateRetrieval(r.ranking, ids, correct, k);
        primary.recall_any[ki] = t.any;
        primary.recall_all[ki] = t.all;
        primary.ndcg[ki] = t.ndcg;
        if (gran == .turn) {
            const s = try evaluateTurnToSession(alloc, r.ranking, ids, correct, k);
            derived.recall_any[ki] = s.any;
            derived.recall_all[ki] = s.all;
            derived.ndcg[ki] = s.ndcg;
        }
    }
    return .{ .primary = primary, .derived = if (gran == .turn) derived else null };
}

// ============================================================================
// Aggregation
// ============================================================================

pub const Group = struct {
    name: []const u8,
    n: usize = 0,
    primary_sum: MetricRow = .{},
    derived_sum: MetricRow = .{},

    fn addRow(sum: *MetricRow, row: MetricRow) void {
        for (0..NK) |i| {
            sum.recall_any[i] += row.recall_any[i];
            sum.recall_all[i] += row.recall_all[i];
            sum.ndcg[i] += row.ndcg[i];
        }
    }

    fn meanOf(sum: MetricRow, n: usize) ?MetricRow {
        if (n == 0) return null;
        const d: f64 = @floatFromInt(n);
        var out = MetricRow{};
        for (0..NK) |i| {
            out.recall_any[i] = sum.recall_any[i] / d;
            out.recall_all[i] = sum.recall_all[i] / d;
            out.ndcg[i] = sum.ndcg[i] / d;
        }
        return out;
    }

    pub fn meanPrimary(self: Group) ?MetricRow {
        return meanOf(self.primary_sum, self.n);
    }

    pub fn meanDerived(self: Group) ?MetricRow {
        return meanOf(self.derived_sum, self.n);
    }
};

pub const Aggregate = struct {
    alloc: Allocator,
    /// Per `question_type`, first-seen order until `sortGroups`.
    groups: std.ArrayList(Group) = .empty,
    overall: Group = .{ .name = "overall" },
    has_derived: bool = false,
    skipped_abstention: usize = 0,
    skipped_no_target: usize = 0,

    pub fn init(alloc: Allocator) Aggregate {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Aggregate) void {
        for (self.groups.items) |g| self.alloc.free(g.name);
        self.groups.deinit(self.alloc);
    }

    pub fn noteSkipped(self: *Aggregate, e: Eligibility) void {
        switch (e) {
            .eligible => {},
            .abstention => self.skipped_abstention += 1,
            .no_target => self.skipped_no_target += 1,
        }
    }

    pub fn add(self: *Aggregate, qtype: []const u8, s: QuestionScore) !void {
        const g = blk: {
            for (self.groups.items) |*g| {
                if (std.mem.eql(u8, g.name, qtype)) break :blk g;
            }
            const name = try self.alloc.dupe(u8, qtype);
            errdefer self.alloc.free(name);
            try self.groups.append(self.alloc, .{ .name = name });
            break :blk &self.groups.items[self.groups.items.len - 1];
        };
        g.n += 1;
        Group.addRow(&g.primary_sum, s.primary);
        self.overall.n += 1;
        Group.addRow(&self.overall.primary_sum, s.primary);
        if (s.derived) |d| {
            self.has_derived = true;
            Group.addRow(&g.derived_sum, d);
            Group.addRow(&self.overall.derived_sum, d);
        }
    }

    pub fn sortGroups(self: *Aggregate) void {
        std.mem.sort(Group, self.groups.items, {}, struct {
            fn lt(_: void, a: Group, b: Group) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
    }
};

// ============================================================================
// Tests
// ============================================================================

const approx = std.testing.expectApproxEqAbs;

test "evaluateRetrieval: recall_any / recall_all / ndcg match hand-computed values" {
    // corpus a b c d; correct = {c, d}; ranking a→c→b→d is [0,2,1,3].
    const ids = [_][]const u8{ "a", "b", "c", "d" };
    const correct = [_][]const u8{ "c", "d" };
    const ranking = [_]u32{ 0, 2, 1, 3 };

    // k=1: top-1 is `a`, a miss.
    const k1 = evaluateRetrieval(&ranking, &ids, &correct, 1);
    try approx(0.0, k1.any, 1e-12);
    try approx(0.0, k1.all, 1e-12);
    try approx(0.0, k1.ndcg, 1e-12);

    // k=3: top-3 = a,c,b -> `c` found, `d` not.
    // Official dcg: rel[0] + sum(rel[1:] / log2(2..n)), so rank 2 is NOT
    // discounted (log2(2) == 1). actual = 0 + 1 + 0 = 1; ideal [1,1,0] = 2.
    const k3 = evaluateRetrieval(&ranking, &ids, &correct, 3);
    try approx(1.0, k3.any, 1e-12);
    try approx(0.0, k3.all, 1e-12);
    try approx(0.5, k3.ndcg, 1e-12);

    // k=10 (> corpus): whole ranking. rels [0,1,0,1]:
    // actual = 1/log2(2) + 1/log2(4) = 1.5; ideal [1,1,0,0] = 2 -> 0.75.
    const k10 = evaluateRetrieval(&ranking, &ids, &correct, 10);
    try approx(1.0, k10.any, 1e-12);
    try approx(1.0, k10.all, 1e-12);
    try approx(0.75, k10.ndcg, 1e-12);
}

test "evaluateRetrieval: rank-1 hit is a perfect ndcg" {
    const ids = [_][]const u8{ "x", "y" };
    const correct = [_][]const u8{"y"};
    const ranking = [_]u32{ 1, 0 };
    const r = evaluateRetrieval(&ranking, &ids, &correct, 5);
    try approx(1.0, r.ndcg, 1e-12);
    try approx(1.0, r.any, 1e-12);
}

test "evaluateRetrieval: a short ranking is not padded into a hit" {
    // The store returned only one doc; ranks beyond it are misses.
    const ids = [_][]const u8{ "x", "y", "z" };
    const correct = [_][]const u8{"z"};
    const ranking = [_]u32{0};
    const r = evaluateRetrieval(&ranking, &ids, &correct, 10);
    try approx(0.0, r.any, 1e-12);
    try approx(0.0, r.ndcg, 1e-12);
}

test "evaluateTurnToSession: k is widened until k distinct sessions are seen" {
    // turns: a_1 a_2 b_1 c_1 -> sessions a a b c. correct turn b_1 -> session b.
    const ids = [_][]const u8{ "a_1", "a_2", "b_1", "c_1" };
    const correct = [_][]const u8{"b_1"};
    const ranking = [_]u32{ 0, 1, 2, 3 };
    // k=2: top-2 turns are both session `a` (1 distinct) -> effective_k 3,
    // which reaches b. ndcg over 3 entries: rel [0,0,1] -> 1/log2(3).
    const r = try evaluateTurnToSession(std.testing.allocator, &ranking, &ids, &correct, 2);
    try approx(1.0, r.any, 1e-12);
    try approx(1.0, r.all, 1e-12);
    try approx(1.0 / @log2(3.0), r.ndcg, 1e-9);
}

test "evaluateTurnToSession: a noans turn of an answer session is NOT a hit (official relabel)" {
    // The official script renames non-evidence turns of an answer session to
    // `noans_*` BEFORE stripping the turn suffix, so retrieving one does not
    // count as retrieving the answer session. Preserved on purpose.
    const ids = [_][]const u8{ "s1_1", "answer_x_1", "noans_x_3", "s2_1" };
    const correct = [_][]const u8{"answer_x_1"};
    const ranking = [_]u32{ 2, 0, 1, 3 };
    const k1 = try evaluateTurnToSession(std.testing.allocator, &ranking, &ids, &correct, 1);
    try approx(0.0, k1.any, 1e-12);
    const k2 = try evaluateTurnToSession(std.testing.allocator, &ranking, &ids, &correct, 2);
    try approx(0.0, k2.any, 1e-12);
    const k3 = try evaluateTurnToSession(std.testing.allocator, &ranking, &ids, &correct, 3);
    try approx(1.0, k3.any, 1e-12);
    try approx(1.0 / @log2(3.0), k3.ndcg, 1e-9);
}

/// A miniature file in the OFFICIAL schema (field names, nesting, the
/// `answer` that is sometimes an integer, `has_answer` only on turns of
/// evidence sessions). Four questions:
///   q1  single-session-user    one evidence session, unique vocabulary
///   q2  q2_abs                 abstention -> excluded
///   q3  multi-session          two evidence sessions, ONE has no user-side
///                              has_answer -> relabelled noans, one correct doc
///   q4  single-session-assistant  has_answer only on an assistant turn
///                              -> no user-side target, excluded by default
const FIXTURE =
    \\[
    \\ {"question_id":"q1","question_type":"single-session-user",
    \\  "question":"What is the name of the quokka I adopted from the shelter?",
    \\  "answer":"Marmaduke","question_date":"2023/05/30 (Tue) 10:00",
    \\  "haystack_dates":["2023/05/01 (Mon) 09:00","2023/05/02 (Tue) 09:00","2023/05/03 (Wed) 09:00"],
    \\  "haystack_session_ids":["s_cook","answer_q1","s_garden"],
    \\  "answer_session_ids":["answer_q1"],
    \\  "haystack_sessions":[
    \\   [{"role":"user","content":"How long should I roast a chicken with rosemary and garlic?"},
    \\    {"role":"assistant","content":"About an hour and a half at moderate heat."}],
    \\   [{"role":"user","content":"I adopted a quokka called Marmaduke from the shelter last spring.","has_answer":true},
    \\    {"role":"assistant","content":"Congratulations on the new pet!","has_answer":false}],
    \\   [{"role":"user","content":"My tomato seedlings need repotting before the frost arrives."},
    \\    {"role":"assistant","content":"Use a larger pot with fresh compost.\nWater lightly."}]
    \\  ]},
    \\ {"question_id":"q2_abs","question_type":"single-session-user",
    \\  "question":"What colour is my parrot?","answer":"You never told me.",
    \\  "question_date":"2023/05/30 (Tue) 10:00","haystack_dates":["2023/05/01 (Mon) 09:00"],
    \\  "haystack_session_ids":["s_cook2"],"answer_session_ids":[],
    \\  "haystack_sessions":[[{"role":"user","content":"Roast chicken again tonight."}]]},
    \\ {"question_id":"q3","question_type":"multi-session",
    \\  "question":"How many telescopes do I own in total?","answer":3,
    \\  "question_date":"2023/06/01 (Thu) 10:00",
    \\  "haystack_dates":["2023/05/01 (Mon) 09:00","2023/05/02 (Tue) 09:00","2023/05/03 (Wed) 09:00"],
    \\  "haystack_session_ids":["answer_q3_a","s_misc","answer_q3_b"],
    \\  "answer_session_ids":["answer_q3_a","answer_q3_b"],
    \\  "haystack_sessions":[
    \\   [{"role":"user","content":"I bought a refractor telescope and a second telescope for my balcony.","has_answer":true}],
    \\   [{"role":"user","content":"Which sourdough starter hydration works best?"}],
    \\   [{"role":"user","content":"Planning a trip to the observatory this weekend.","has_answer":false},
    \\    {"role":"assistant","content":"Observatories are great for stargazing.","has_answer":false}]
    \\  ]},
    \\ {"question_id":"q4","question_type":"single-session-assistant",
    \\  "question":"What did you recommend for the squeaky hinge?","answer":"WD-40",
    \\  "question_date":"2023/06/01 (Thu) 10:00","haystack_dates":["2023/05/01 (Mon) 09:00"],
    \\  "haystack_session_ids":["answer_q4"],"answer_session_ids":["answer_q4"],
    \\  "haystack_sessions":[
    \\   [{"role":"user","content":"My door hinge squeaks every morning."},
    \\    {"role":"assistant","content":"I recommend a drop of silicone lubricant on the squeaky hinge.","has_answer":true}]
    \\  ]}
    \\]
;

test "dataset: indexQuestions finds each element and is not fooled by braces in strings" {
    const alloc = std.testing.allocator;
    const spans = try indexQuestions(alloc, FIXTURE);
    defer alloc.free(spans);
    try std.testing.expectEqual(@as(usize, 4), spans.len);

    const tricky =
        \\[{"question_id":"a","x":"} ] { [ \" \\"},{"question_id":"b"}]
    ;
    const s2 = try indexQuestions(alloc, tricky);
    defer alloc.free(s2);
    try std.testing.expectEqual(@as(usize, 2), s2.len);

    try std.testing.expectError(error.MalformedDataset, indexQuestions(alloc, "[{\"a\":1}"));
}

test "dataset: parseQuestion reads the official schema, including integer answers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spans = try indexQuestions(arena, FIXTURE);
    const q3 = try parseQuestion(arena, FIXTURE[spans[2].start..spans[2].end]);
    try std.testing.expectEqualStrings("q3", q3.question_id);
    try std.testing.expectEqualStrings("multi-session", q3.question_type);
    try std.testing.expectEqual(@as(usize, 3), q3.haystack_sessions.len);
    try std.testing.expect(q3.haystack_sessions[0][0].has_answer);
    // `has_answer` defaults to false when a turn omits it.
    try std.testing.expect(!q3.haystack_sessions[1][0].has_answer);
    try std.testing.expect(!answerIdsDisagree(q3));
}

test "classify: abstention and no-target questions are excluded; roles=all re-admits q4" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spans = try indexQuestions(arena, FIXTURE);
    var qs: [4]Question = undefined;
    for (spans, 0..) |sp, i| qs[i] = try parseQuestion(arena, FIXTURE[sp.start..sp.end]);

    try std.testing.expectEqual(Eligibility.eligible, classify(qs[0], .user));
    try std.testing.expectEqual(Eligibility.abstention, classify(qs[1], .user));
    try std.testing.expectEqual(Eligibility.eligible, classify(qs[2], .user));
    try std.testing.expectEqual(Eligibility.no_target, classify(qs[3], .user));
    try std.testing.expectEqual(Eligibility.eligible, classify(qs[3], .all));
    // Abstention stays excluded whatever the roles.
    try std.testing.expectEqual(Eligibility.abstention, classify(qs[1], .all));
}

test "buildDocs: official corpus ids, noans relabel, user-only text" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spans = try indexQuestions(arena, FIXTURE);
    const q3 = try parseQuestion(arena, FIXTURE[spans[2].start..spans[2].end]);

    // Session granularity: answer_q3_b has no user-side has_answer -> noans.
    const sdocs = try buildDocs(alloc, q3, .session, .user);
    defer freeDocs(alloc, sdocs);
    try std.testing.expectEqual(@as(usize, 3), sdocs.len);
    try std.testing.expectEqualStrings("answer_q3_a", sdocs[0].id);
    try std.testing.expectEqualStrings("s_misc", sdocs[1].id);
    try std.testing.expectEqualStrings("noans_q3_b", sdocs[2].id);
    // User-only text: the assistant sentence is not in the corpus.
    try std.testing.expect(std.mem.indexOf(u8, sdocs[2].text, "stargazing") == null);
    try std.testing.expect(std.mem.indexOf(u8, sdocs[2].text, "observatory") != null);

    const correct = try correctDocIds(alloc, sdocs);
    defer alloc.free(correct);
    try std.testing.expectEqual(@as(usize, 1), correct.len);
    try std.testing.expectEqualStrings("answer_q3_a", correct[0]);

    // Turn granularity: one doc per user turn, id = session_position.
    const tdocs = try buildDocs(alloc, q3, .turn, .user);
    defer freeDocs(alloc, tdocs);
    try std.testing.expectEqual(@as(usize, 3), tdocs.len);
    try std.testing.expectEqualStrings("answer_q3_a_1", tdocs[0].id);
    try std.testing.expectEqualStrings("noans_q3_b_1", tdocs[2].id);

    // roles=all keeps the assistant turn (position 2), a documented
    // departure from the official protocol.
    const adocs = try buildDocs(alloc, q3, .turn, .all);
    defer freeDocs(alloc, adocs);
    try std.testing.expectEqual(@as(usize, 4), adocs.len);
    try std.testing.expectEqualStrings("noans_q3_b_2", adocs[3].id);
}

test "aggregate: per-type breakdown, overall mean, skipped counters" {
    const alloc = std.testing.allocator;
    var agg = Aggregate.init(alloc);
    defer agg.deinit();

    var hit = QuestionScore{ .primary = .{}, .derived = null };
    for (0..NK) |i| {
        hit.primary.recall_any[i] = 1;
        hit.primary.recall_all[i] = 1;
        hit.primary.ndcg[i] = 1;
    }
    const miss = QuestionScore{ .primary = .{}, .derived = null };

    try agg.add("multi-session", hit);
    try agg.add("multi-session", miss);
    try agg.add("knowledge-update", hit);
    agg.noteSkipped(.abstention);
    agg.noteSkipped(.abstention);
    agg.noteSkipped(.no_target);
    agg.noteSkipped(.eligible);
    agg.sortGroups();

    try std.testing.expectEqual(@as(usize, 2), agg.groups.items.len);
    try std.testing.expectEqualStrings("knowledge-update", agg.groups.items[0].name);
    try approx(1.0, agg.groups.items[0].meanPrimary().?.recall_any[0], 1e-12);
    try std.testing.expectEqualStrings("multi-session", agg.groups.items[1].name);
    try approx(0.5, agg.groups.items[1].meanPrimary().?.recall_any[0], 1e-12);
    try approx(2.0 / 3.0, agg.overall.meanPrimary().?.ndcg[3], 1e-12);
    try std.testing.expectEqual(@as(usize, 3), agg.overall.n);
    try std.testing.expectEqual(@as(usize, 2), agg.skipped_abstention);
    try std.testing.expectEqual(@as(usize, 1), agg.skipped_no_target);
    try std.testing.expect(!agg.has_derived);
    try std.testing.expect(agg.groups.items[0].meanDerived().?.recall_any[0] == 0);
}

test "aggregate: an empty group has no mean rather than a made-up zero" {
    const g = Group{ .name = "empty" };
    try std.testing.expect(g.meanPrimary() == null);
}

test "end to end: the real Store ranks the evidence session first on the fixture" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spans = try indexQuestions(arena, FIXTURE);

    var agg = Aggregate.init(alloc);
    defer agg.deinit();

    for (spans) |sp| {
        const q = try parseQuestion(arena, FIXTURE[sp.start..sp.end]);
        const e = classify(q, .user);
        if (e != .eligible) {
            agg.noteSkipped(e);
            continue;
        }
        const r = try rank(alloc, q, .{ .granularity = .session });
        defer r.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), r.ingest_failures);
        const sc = try scoreRanked(alloc, r, .session);
        try agg.add(q.question_type, sc);

        // q1: the evidence session carries the only vocabulary the
        // question shares, so it must be rank 1.
        if (std.mem.eql(u8, q.question_id, "q1")) {
            try std.testing.expect(r.ranking.len >= 1);
            try std.testing.expectEqualStrings("answer_q1", r.docs[r.ranking[0]].id);
            try approx(1.0, sc.primary.recall_any[0], 1e-12);
            try approx(1.0, sc.primary.ndcg[0], 1e-12);
        }
    }
    // q2 is an abstention, q4 has no user-side target.
    try std.testing.expectEqual(@as(usize, 2), agg.overall.n);
    try std.testing.expectEqual(@as(usize, 1), agg.skipped_abstention);
    try std.testing.expectEqual(@as(usize, 1), agg.skipped_no_target);
    // 3-document haystacks: every k >= 3 sees the whole corpus, so a
    // retrievable evidence doc is always found by k=3.
    const m = agg.overall.meanPrimary().?;
    try approx(1.0, m.recall_any[1], 1e-12);
}

test "end to end: turn granularity yields a derived session-level row" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spans = try indexQuestions(arena, FIXTURE);
    const q1 = try parseQuestion(arena, FIXTURE[spans[0].start..spans[0].end]);

    const r = try rank(alloc, q1, .{ .granularity = .turn });
    defer r.deinit(alloc);
    const sc = try scoreRanked(alloc, r, .turn);
    try std.testing.expect(sc.derived != null);
    // The evidence turn is the best lexical and dense match for the query.
    try approx(1.0, sc.primary.recall_any[0], 1e-12);
    try approx(1.0, sc.derived.?.recall_any[0], 1e-12);
}

test "arms: dense-only and bm25-only both run through Store.query" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spans = try indexQuestions(arena, FIXTURE);
    const q1 = try parseQuestion(arena, FIXTURE[spans[0].start..spans[0].end]);

    for ([_]Arm{ .dense, .bm25 }) |arm| {
        const r = try rank(alloc, q1, .{ .granularity = .session, .arm = arm });
        defer r.deinit(alloc);
        try std.testing.expect(r.ranking.len >= 1);
        try std.testing.expectEqualStrings("answer_q1", r.docs[r.ranking[0]].id);
    }
}

// ============================================================================
// Ablation variants (see lme_ablation.zig and docs/benchmarks/ablation-tri-source.md)
// ============================================================================

fn rankingsEqual(a: Ranked, b: Ranked) bool {
    return std.mem.eql(u32, a.ranking, b.ranking);
}

fn fixtureQuestion(arena: Allocator, idx: usize) !Question {
    const spans = try indexQuestions(arena, FIXTURE);
    return parseQuestion(arena, FIXTURE[spans[idx].start..spans[idx].end]);
}

test "variant: the default Variant is the default behaviour (isDefault)" {
    try std.testing.expect((abl.Variant{}).isDefault());
    try std.testing.expect(!(abl.Variant{ .tags = .heuristic }).isDefault());
    try std.testing.expect(!(abl.Variant{ .graph_off = true }).isDefault());
    try std.testing.expect(!(abl.Variant{ .goal_bonus_weight = 0 }).isDefault());
}

test "variant: tag-only variants cannot move a fixture ranking (the tag is not a retrieval signal)" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const q = try fixtureQuestion(arena_state.allocator(), 2); // q3, multi-session

    const base = try rank(alloc, q, .{ .granularity = .session });
    defer base.deinit(alloc);
    for ([_]abl.Variant{
        .{ .tags = .form },
        .{ .tags = .spirit },
        .{ .tags = .heuristic },
        .{ .tags = .random, .tag_seed = 3 },
    }) |v| {
        const r = try rank(alloc, q, .{ .granularity = .session, .variant = v });
        defer r.deinit(alloc);
        try std.testing.expect(rankingsEqual(base, r));
    }
}

test "variant: diagnostics report what was actually done" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const q = try fixtureQuestion(arena_state.allocator(), 2); // q3: 3 sessions, 3 user docs

    const r = try rank(alloc, q, .{
        .granularity = .session,
        .variant = .{ .tags = .heuristic, .goals = .per_session },
    });
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 3), r.diag.goals_created);
    try std.testing.expectEqual(@as(u32, 0), r.diag.edges_created);
    // "I bought a refractor telescope..." / "Which sourdough..." / "Planning a trip..."
    // -> none of the pre-registered phrases ("planning to" needs "to") -> all 物.
    try std.testing.expectEqual(@as(u32, 3), r.diag.tag_counts[0] + r.diag.tag_counts[1] + r.diag.tag_counts[2]);
}

test "variant: session edges need turn granularity and are one per multi-turn session" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const q = try fixtureQuestion(arena_state.allocator(), 0); // q1: three sessions of 1 user turn each

    try std.testing.expectError(error.EdgesNeedTurnGranularity, rank(alloc, q, .{
        .granularity = .session,
        .variant = .{ .session_edges = true },
    }));
    // roles=all gives two turns per session -> one edge per session.
    const r = try rank(alloc, q, .{
        .granularity = .turn,
        .roles = .all,
        .variant = .{ .session_edges = true },
    });
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 3), r.diag.edges_created);
}

test "variant: goal-bonus off, existence off and recency off are bit-identical to the default" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const q = try fixtureQuestion(arena_state.allocator(), 2);

    const base = try rank(alloc, q, .{ .granularity = .session });
    defer base.deinit(alloc);
    // Uniform goal / importance / recency => switching the factor off cannot
    // change an ordering. This is the harness-side proof of the inventory.
    for ([_]abl.Variant{
        .{ .goal_bonus_weight = 0 },
        .{ .existence_bonus_weight = 0 },
        .{ .recency_bonus_weight = 0 },
    }) |v| {
        const r = try rank(alloc, q, .{ .granularity = .session, .variant = v });
        defer r.deinit(alloc);
        try std.testing.expect(rankingsEqual(base, r));
    }
}

test "variant: simulated age makes recency real, and only then" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Two sessions with IDENTICAL user text; only the dates differ.
    const json =
        \\{"question_id":"qa","question_type":"knowledge-update",
        \\ "question":"which marmalade recipe did I settle on",
        \\ "question_date":"2023/05/30 (Tue) 10:00",
        \\ "haystack_dates":["2021/01/01 (Fri) 10:00","2023/05/29 (Mon) 10:00"],
        \\ "haystack_session_ids":["answer_old","answer_new"],
        \\ "answer_session_ids":["answer_new"],
        \\ "haystack_sessions":[
        \\  [{"role":"user","content":"I settled on the bitter orange marmalade recipe","has_answer":true}],
        \\  [{"role":"user","content":"I settled on the bitter orange marmalade recipe","has_answer":true}]
        \\ ]}
    ;
    const q = try parseQuestion(arena, json);

    const aged = try rank(alloc, q, .{ .granularity = .session, .variant = .{ .simulate_age = true } });
    defer aged.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), aged.diag.ages_set);
    try std.testing.expectEqual(@as(u32, 0), aged.diag.ages_unparsed);
    try std.testing.expectEqual(@as(usize, 2), aged.ranking.len);
    // the 2023-05-29 session is ~1 day old, the 2021 one ~880 days old
    try std.testing.expectEqualStrings("answer_new", aged.docs[aged.ranking[0]].id);
}

test "variant: unparseable dates are counted, not guessed" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json =
        \\{"question_id":"qb","question_type":"knowledge-update","question":"marmalade",
        \\ "question_date":"garbage","haystack_dates":["also garbage"],
        \\ "haystack_session_ids":["answer_x"],"answer_session_ids":["answer_x"],
        \\ "haystack_sessions":[[{"role":"user","content":"marmalade","has_answer":true}]]}
    ;
    const q = try parseQuestion(arena, json);
    const r = try rank(alloc, q, .{ .granularity = .session, .variant = .{ .simulate_age = true } });
    defer r.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 0), r.diag.ages_set);
    try std.testing.expectEqual(@as(u32, 1), r.diag.ages_unparsed);
}

test "variant: router filter puts the predicted source first, boost keeps every doc" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json =
        \\{"question_id":"qc","question_type":"single-session-preference",
        \\ "question":"I want to know my favorite pastry",
        \\ "question_date":"2023/05/30 (Tue) 10:00",
        \\ "haystack_dates":["2023/05/01 (Mon) 10:00","2023/05/02 (Tue) 10:00","2023/05/03 (Wed) 10:00"],
        \\ "haystack_session_ids":["s1","answer_s2","s3"],"answer_session_ids":["answer_s2"],
        \\ "haystack_sessions":[
        \\  [{"role":"user","content":"my favorite pastry shop sells croissants"}],
        \\  [{"role":"user","content":"I love a good pastry, croissants are my favorite","has_answer":true}],
        \\  [{"role":"user","content":"pastry dough needs cold butter"}]
        \\ ]}
    ;
    const q = try parseQuestion(arena, json);
    try std.testing.expectEqual(core.MemorySource.spirit, abl.classifyHeuristic(q.question));

    const base = try rank(alloc, q, .{ .granularity = .session, .variant = .{ .tags = .heuristic } });
    defer base.deinit(alloc);
    const filt = try rank(alloc, q, .{ .granularity = .session, .variant = .{ .tags = .heuristic, .router = .filter } });
    defer filt.deinit(alloc);
    const boost = try rank(alloc, q, .{ .granularity = .session, .variant = .{ .tags = .heuristic, .router = .boost } });
    defer boost.deinit(alloc);

    try std.testing.expectEqual(base.ranking.len, filt.ranking.len);
    try std.testing.expectEqual(base.ranking.len, boost.ranking.len);
    try std.testing.expectEqual(core.MemorySource.spirit, filt.diag.router_pred.?);
    // the two spirit-tagged sessions come before the form/matter one
    try std.testing.expect(filt.ranking.len == 3);
    var seen_non_spirit = false;
    for (filt.ranking) |di| {
        const is_spirit = abl.classifyHeuristic(filt.docs[di].text) == .spirit;
        if (!is_spirit) seen_non_spirit = true else try std.testing.expect(!seen_non_spirit);
    }
}

test "variant: per-session goals are created from haystack text and the evidence session still ranks first" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Plumbing check only: one goal per session is created, none leaks a
    // label, and the ranking is well formed. That the goal bonus can change an
    // outcome at all is shown by the SYNTHETIC test in lme_ablation.zig; that
    // it does on LongMemEval is what the pre-registered run measures.
    const json =
        \\{"question_id":"qd","question_type":"multi-session",
        \\ "question":"telescope maintenance schedule",
        \\ "question_date":"2023/05/30 (Tue) 10:00",
        \\ "haystack_dates":["2023/05/01 (Mon) 10:00","2023/05/02 (Tue) 10:00"],
        \\ "haystack_session_ids":["s_a","answer_b"],"answer_session_ids":["answer_b"],
        \\ "haystack_sessions":[
        \\  [{"role":"user","content":"gardening schedule notes gardening gardening trowel"}],
        \\  [{"role":"user","content":"telescope schedule notes telescope telescope eyepiece","has_answer":true}]
        \\ ]}
    ;
    const q = try parseQuestion(arena, json);
    const on = try rank(alloc, q, .{ .granularity = .session, .variant = .{ .goals = .per_session } });
    defer on.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), on.diag.goals_created);
    try std.testing.expectEqualStrings("answer_b", on.docs[on.ranking[0]].id);
}
