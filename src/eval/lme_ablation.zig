//! Ablation switches for the LongMemEval retrieval harness.
//!
//! **GHW layer**: Harness layer (form source). Evaluation protocol only. Every switch
//! here acts on the *harness side* of the product's public surface — the
//! arguments of `addRaw` / `createGoal` / `addHyperedge`, the config copies
//! the `Store` exposes (`store.lc.cfg`, `store.hybrid.cfg`) and the ranking
//! the `Store` returns. Nothing in `src/` outside `eval/` is changed, and
//! `Variant{}` (all defaults) reproduces the pre-ablation harness byte for
//! byte.
//!
//! The variants themselves, and why each one exists, are pre-registered in
//! `docs/benchmarks/ablation-tri-source.md`. This file is the mechanism.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemorySource = core.MemorySource;
const stats = @import("paired_stats.zig");
const store_mod = @import("../store/store.zig");

pub const TagMode = enum {
    /// Every cell matter. This is what the harness has always done.
    matter,
    form,
    spirit,
    /// §3.1 lexical stand-in for a source tagger.
    heuristic,
    /// The heuristic's tags shuffled across the question's documents.
    random,

    pub fn parse(s: []const u8) ?TagMode {
        return std.meta.stringToEnum(TagMode, s);
    }
};

pub const GoalMode = enum {
    /// Every cell bound to goal 1 at relevance 0.5 (today's harness).
    uniform,
    /// One goal per haystack session, derived from haystack text only.
    per_session,

    pub fn parse(s: []const u8) ?GoalMode {
        return std.meta.stringToEnum(GoalMode, s);
    }
};

pub const RouterMode = enum {
    none,
    /// Stable partition: predicted-source cells first.
    filter,
    /// Multiply the final score of predicted-source cells.
    boost,

    pub fn parse(s: []const u8) ?RouterMode {
        return std.meta.stringToEnum(RouterMode, s);
    }
};

/// One ablation configuration. The all-default value is the current harness.
pub const Variant = struct {
    tags: TagMode = .matter,
    /// Seed for `.random`. Mixed with a hash of the question id so a stream
    /// does not depend on file order or on `--limit` sampling.
    tag_seed: u64 = 0,
    goals: GoalMode = .uniform,
    /// `null` leaves the product default (0.4 / 0.3 / 0.2) untouched.
    goal_bonus_weight: ?f32 = null,
    existence_bonus_weight: ?f32 = null,
    recency_bonus_weight: ?f32 = null,
    /// Zero the graph arm's fusion weight on both live copies.
    graph_off: bool = false,
    /// One `associative` hyperedge per session (turn granularity only).
    session_edges: bool = false,
    /// Set `created_at` from the dataset's dates so recency is real.
    simulate_age: bool = false,
    /// Cells the heuristic calls spirit carry an unexpired foresight entry.
    foresight_on_spirit: bool = false,
    router: RouterMode = .none,
    router_boost: f32 = 1.25,

    pub fn isDefault(self: Variant) bool {
        const d = Variant{};
        return self.tags == d.tags and self.tag_seed == d.tag_seed and self.goals == d.goals and
            self.goal_bonus_weight == null and self.existence_bonus_weight == null and
            self.recency_bonus_weight == null and !self.graph_off and !self.session_edges and
            !self.simulate_age and !self.foresight_on_spirit and self.router == .none;
    }
};

// ============================================================================
// Tag assigner
// ============================================================================

const SPIRIT_PHRASES = [_][]const u8{
    "i want",       "i'd like",       "i would like",    "i plan",
    "planning to",  "i hope",         "i wish",          "my goal",
    "i need to",    "going to",       "i prefer",        "my favorite",
    "my favourite", "i love",         "i like",          "i enjoy",
    "looking for",  "i'm interested", "i am interested", "i intend",
    "thinking of",  "thinking about", "next week",       "next month",
    "tomorrow",
};

const FORM_PHRASES = [_][]const u8{
    "how to",     "step by step", "steps",    "recipe",
    "always",     "usually",      "routine",  "every day",
    "every week", "instructions", "tutorial", "template",
    "algorithm",  "function",     "script",
};

/// Does `phrase` occur in `text` starting exactly at `start`? ASCII
/// case-insensitive; an apostrophe in the phrase matches either `'` or the
/// typographic U+2019 (`E2 80 99`), because LongMemEval transcripts contain
/// both and a tagger that only saw one would silently mis-tag half of them.
fn matchPhraseAt(text: []const u8, start: usize, phrase: []const u8) bool {
    var ti = start;
    for (phrase) |pc| {
        if (ti >= text.len) return false;
        if (pc == '\'') {
            if (text[ti] == '\'') {
                ti += 1;
            } else if (ti + 3 <= text.len and text[ti] == 0xE2 and text[ti + 1] == 0x80 and text[ti + 2] == 0x99) {
                ti += 3;
            } else return false;
        } else {
            if (std.ascii.toLower(text[ti]) != pc) return false;
            ti += 1;
        }
    }
    return true;
}

fn containsPhrase(text: []const u8, phrase: []const u8) bool {
    if (phrase.len == 0 or text.len < phrase.len) return false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (matchPhraseAt(text, i, phrase)) return true;
    }
    return false;
}

/// §3.1 of the pre-registration: a crude lexical stand-in for a source
/// tagger. Spirit (intent / preference / plan) first, then form (procedure /
/// rule), else matter. The product has no such classifier; this is a
/// harness-defined baseline, and the verdicts say so.
pub fn classifyHeuristic(text: []const u8) MemorySource {
    for (SPIRIT_PHRASES) |p| if (containsPhrase(text, p)) return .spirit;
    for (FORM_PHRASES) |p| if (containsPhrase(text, p)) return .form;
    return .matter;
}

pub fn shuffleInPlace(comptime T: type, items: []T, rng: *stats.SplitMix64) void {
    if (items.len < 2) return;
    var i: usize = items.len;
    while (i > 1) : (i -= 1) {
        const j: usize = @intCast(rng.below(i));
        std.mem.swap(T, &items[i - 1], &items[j]);
    }
}

/// Fill `out[i]` with the tag for `texts[i]`. `texts` and `out` must have the
/// same length. For `.random` the heuristic tags of the non-empty documents
/// are permuted among themselves, so the per-question tag distribution equals
/// the heuristic's and only the tag-to-document association is destroyed.
/// Empty documents are never ingested, so they stay out of the pool.
pub fn assignTags(
    alloc: Allocator,
    mode: TagMode,
    seed: u64,
    question_id: []const u8,
    texts: []const []const u8,
    out: []MemorySource,
) !void {
    std.debug.assert(texts.len == out.len);
    switch (mode) {
        .matter => @memset(out, .matter),
        .form => @memset(out, .form),
        .spirit => @memset(out, .spirit),
        .heuristic => for (texts, out) |t, *o| {
            o.* = classifyHeuristic(t);
        },
        .random => {
            var pool = std.ArrayList(MemorySource).empty;
            defer pool.deinit(alloc);
            for (texts, out) |t, *o| {
                o.* = .matter;
                if (t.len > 0) try pool.append(alloc, classifyHeuristic(t));
            }
            var rng = stats.SplitMix64.init(seed ^ stats.hashStr(question_id));
            shuffleInPlace(MemorySource, pool.items, &rng);
            var k: usize = 0;
            for (texts, out) |t, *o| {
                if (t.len == 0) continue;
                o.* = pool.items[k];
                k += 1;
            }
        },
    }
}

// ============================================================================
// Router
// ============================================================================

pub fn routeOrder(
    alloc: Allocator,
    scores: []const f32,
    sources: []const MemorySource,
    pred: MemorySource,
    mode: RouterMode,
    boost: f32,
) ![]u32 {
    std.debug.assert(scores.len == sources.len);
    const order = try alloc.alloc(u32, scores.len);
    errdefer alloc.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    switch (mode) {
        .none => {},
        .filter => {
            // Stable partition: predicted-source first, nothing dropped.
            var w: usize = 0;
            for (sources, 0..) |s, i| {
                if (s == pred) {
                    order[w] = @intCast(i);
                    w += 1;
                }
            }
            for (sources, 0..) |s, i| {
                if (s != pred) {
                    order[w] = @intCast(i);
                    w += 1;
                }
            }
        },
        .boost => {
            const Ctx = struct {
                scores: []const f32,
                sources: []const MemorySource,
                pred: MemorySource,
                boost: f32,
                fn adj(c: @This(), i: u32) f32 {
                    return if (c.sources[i] == c.pred) c.scores[i] * c.boost else c.scores[i];
                }
                fn lt(c: @This(), a: u32, b: u32) bool {
                    const x = c.adj(a);
                    const y = c.adj(b);
                    if (x != y) return x > y;
                    return a < b; // ties keep the store's order
                }
            };
            std.mem.sort(u32, order, Ctx{ .scores = scores, .sources = sources, .pred = pred, .boost = boost }, Ctx.lt);
        },
    }
    return order;
}

// ============================================================================
// Goal topic derivation
// ============================================================================

pub fn topicWords(alloc: Allocator, texts: []const []const u8, k: usize) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var counts = std.StringHashMap(u32).init(arena);
    var lower: [MAX_WORD]u8 = undefined;
    for (texts) |t| {
        var i: usize = 0;
        while (i < t.len) {
            while (i < t.len and !std.ascii.isAlphabetic(t[i])) i += 1;
            const start = i;
            while (i < t.len and std.ascii.isAlphabetic(t[i])) i += 1;
            const len = i - start;
            if (len < MIN_WORD or len > MAX_WORD) continue;
            for (t[start..i], 0..) |c, j| lower[j] = std.ascii.toLower(c);
            const w = lower[0..len];
            if (isStopWord(w)) continue;
            if (counts.getPtr(w)) |c| {
                c.* += 1;
            } else {
                try counts.put(try arena.dupe(u8, w), 1);
            }
        }
    }

    const Entry = struct { word: []const u8, n: u32 };
    var entries = std.ArrayList(Entry).empty;
    var it = counts.iterator();
    while (it.next()) |e| try entries.append(arena, .{ .word = e.key_ptr.*, .n = e.value_ptr.* });
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.n != b.n) return a.n > b.n;
            return std.mem.lessThan(u8, a.word, b.word);
        }
    }.lt);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (entries.items[0..@min(k, entries.items.len)], 0..) |e, i| {
        if (i > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, e.word);
    }
    return out.toOwnedSlice(alloc);
}

const MIN_WORD: usize = 4;
const MAX_WORD: usize = 24;

/// Fixed stop-word list (pre-registered as "a fixed stop-word list"). Words
/// shorter than `MIN_WORD` never reach it.
const STOP_WORDS = [_][]const u8{
    "that",   "this",      "with",     "have",       "from",   "they",    "will",
    "would",  "there",     "their",    "what",       "about",  "which",   "when",
    "your",   "been",      "were",     "them",       "then",   "than",    "some",
    "into",   "just",      "like",     "also",       "more",   "very",    "much",
    "really", "could",     "should",   "other",      "only",   "know",    "want",
    "need",   "help",      "please",   "thanks",     "thank",  "make",    "made",
    "does",   "doing",     "going",    "here",       "these",  "those",   "where",
    "while",  "because",   "being",    "each",       "after",  "before",  "over",
    "such",   "same",      "most",     "many",       "think",  "tell",    "hello",
    "sure",   "okay",      "good",     "great",      "well",   "back",    "even",
    "still",  "take",      "give",     "come",       "look",   "find",    "using",
    "used",   "something", "anything", "everything", "anyone", "someone",
};

fn isStopWord(w: []const u8) bool {
    for (STOP_WORDS) |s| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

// ============================================================================
// Dates
// ============================================================================

pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    // Howard Hinnant's days_from_civil, proleptic Gregorian.
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn parseDateMs(s: []const u8) ?i64 {
    // Digit groups: YYYY MM DD [HH MM]. The weekday in parentheses and every
    // separator are skipped, so "2023/05/30 (Tue) 10:00" and "2023-05-30 10:00"
    // both parse.
    var nums: [5]i64 = .{ 0, 0, 0, 0, 0 };
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < nums.len) {
        while (i < s.len and !std.ascii.isDigit(s[i])) i += 1;
        if (i >= s.len) break;
        var v: i64 = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            v = v * 10 + (s[i] - '0');
            if (v > 1_000_000) return null;
        }
        nums[n] = v;
        n += 1;
    }
    if (n < 3) return null;
    const y = nums[0];
    const mo = nums[1];
    const d = nums[2];
    const hh = nums[3];
    const mm = nums[4];
    if (mo < 1 or mo > 12 or d < 1 or d > 31 or hh > 23 or mm > 59) return null;
    return (daysFromCivil(y, mo, d) * 24 + hh) * 3_600_000 + mm * 60_000;
}

// ============================================================================
// Synthetic mechanism checks (SYNTHETIC: built so the machinery should win)
// ============================================================================

pub const SynthResult = struct {
    queries: usize,
    hits_off: usize,
    hits_on: usize,
};

const SYNTH_GOALS = [_]struct { name: []const u8, desc: []const u8 }{
    .{ .name = "astronomy", .desc = "observe the telescope and the stars" },
    .{ .name = "cooking", .desc = "simmer the sauce and season the stew" },
    .{ .name = "gardening", .desc = "water the tomatoes and prune the basil" },
    .{ .name = "finance", .desc = "reconcile the ledger and file the taxes" },
    .{ .name = "fitness", .desc = "lift the barbell and track the miles" },
    .{ .name = "travel", .desc = "book the flights and pack the luggage" },
    .{ .name = "music", .desc = "tune the guitar and rehearse the chorus" },
    .{ .name = "carpentry", .desc = "sand the oak and glue the joints" },
};

/// SYNTHETIC goal-conditioned task. Eight goals, each with one *target* cell
/// whose text is identical across goals ("quarterly review notes checklist")
/// plus eleven distinct decoys. A query repeats the target phrase and names
/// one goal. Lexically and densely the eight targets tie exactly, so only the
/// goal machinery (`ghw.retrieve` routing + `goalBonus`) can pick the right
/// one. `hits_off` runs the same store with `goal_bonus_weight = 0`; chance is
/// 1/8. Built so that the mechanism SHOULD win: it checks that it works at
/// all, and says nothing about real data.
pub fn synthGoalConditioned(alloc: Allocator) !SynthResult {
    const store = try store_mod.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = false });
    defer store.deinit();

    var gids: [SYNTH_GOALS.len]u64 = undefined;
    var targets: [SYNTH_GOALS.len]u64 = undefined;
    for (SYNTH_GOALS, 0..) |g, i| {
        gids[i] = try store.createGoal(g.name, g.desc, null, 5, null, 1_700_000_000_000);
    }
    var buf: [64]u8 = undefined;
    for (SYNTH_GOALS, 0..) |_, i| {
        targets[i] = try store.addRaw(.matter, "quarterly review notes checklist", "", gids[i], 1.0);
        var j: usize = 0;
        while (j < 11) : (j += 1) {
            const t = try std.fmt.bufPrint(&buf, "decoy entry zq{d}x{d} filler{d}", .{ i, j, i * 31 + j });
            _ = try store.addRaw(.matter, t, "", gids[i], 1.0);
        }
    }

    var res = SynthResult{ .queries = SYNTH_GOALS.len, .hits_off = 0, .hits_on = 0 };
    const on_weight = store.lc.cfg.goal_bonus_weight;
    for ([_]bool{ false, true }) |on| {
        store.lc.cfg.goal_bonus_weight = if (on) on_weight else 0;
        for (SYNTH_GOALS, 0..) |g, i| {
            var qbuf: [128]u8 = undefined;
            const q = try std.fmt.bufPrint(&qbuf, "quarterly review notes checklist {s}", .{g.name});
            // topk 10, not 1: the reranker only reorders the 3*topk fused
            // candidates, so at topk 1 only 3 of the 8 tied targets are even
            // considered (measured: 3/8 hits with the bonus on). That is a
            // property of the product's query path, not of this check.
            const hits = try store.query(alloc, q, .{ .topk = 10 });
            defer alloc.free(hits);
            if (hits.len >= 1 and hits[0].cell.id == targets[i]) {
                if (on) res.hits_on += 1 else res.hits_off += 1;
            }
        }
    }
    return res;
}

const SYNTH_TOPICS = [_][]const u8{
    "harbour", "lantern", "orchard", "glacier", "monsoon",
    "cobalt",  "saffron", "tundra",  "quartz",  "meadow",
};

/// SYNTHETIC source-routed task. Ten topics, each stored as three cells with
/// identical text and different tags (matter/form/spirit). The query repeats the topic
/// and ends with "how to", which the §3.1 router reads as form; the target is
/// the form cell. The store has no source argument, so routing is the
/// harness-side `routeOrder` over the ranking `Store.query` returned. Chance
/// is 1/3 (the product's own tie-break, which prefers slow-decay sources by
/// float rounding, is not chance, which is why the target is the *middle*
/// source).
pub fn synthSourceRouted(alloc: Allocator) !SynthResult {
    const store = try store_mod.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = true });
    defer store.deinit();

    var targets: [SYNTH_TOPICS.len]u64 = undefined;
    var buf: [96]u8 = undefined;
    for (SYNTH_TOPICS, 0..) |w, i| {
        const text = try std.fmt.bufPrint(&buf, "monthly {s} digest overview", .{w});
        _ = try store.addRaw(.matter, text, "", 1, 0.5);
        targets[i] = try store.addRaw(.form, text, "", 1, 0.5);
        _ = try store.addRaw(.spirit, text, "", 1, 0.5);
    }

    var res = SynthResult{ .queries = SYNTH_TOPICS.len, .hits_off = 0, .hits_on = 0 };
    for (SYNTH_TOPICS, 0..) |w, i| {
        var qbuf: [128]u8 = undefined;
        const q = try std.fmt.bufPrint(&qbuf, "monthly {s} digest overview how to", .{w});
        const scored = try store.query(alloc, q, .{ .topk = SYNTH_TOPICS.len * 3 });
        defer alloc.free(scored);
        if (scored.len > 0 and scored[0].cell.id == targets[i]) res.hits_off += 1;

        const scores = try alloc.alloc(f32, scored.len);
        defer alloc.free(scores);
        const sources = try alloc.alloc(MemorySource, scored.len);
        defer alloc.free(sources);
        for (scored, 0..) |sc, k| {
            scores[k] = sc.final_score;
            sources[k] = sc.cell.source;
        }
        const order = try routeOrder(alloc, scores, sources, classifyHeuristic(q), .filter, 1.25);
        defer alloc.free(order);
        if (order.len > 0 and scored[order[0]].cell.id == targets[i]) res.hits_on += 1;
    }
    return res;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "classifyHeuristic: spirit beats form beats matter, case-insensitive" {
    try testing.expectEqual(MemorySource.spirit, classifyHeuristic("I'd like to adopt a dog next spring."));
    try testing.expectEqual(MemorySource.spirit, classifyHeuristic("My Favorite colour is teal"));
    try testing.expectEqual(MemorySource.spirit, classifyHeuristic("We are PLANNING TO move"));
    // Both a spirit and a form phrase: spirit wins (rule order).
    try testing.expectEqual(MemorySource.spirit, classifyHeuristic("I want to learn how to bake"));
    try testing.expectEqual(MemorySource.form, classifyHeuristic("Here is a step by step recipe for naan"));
    try testing.expectEqual(MemorySource.form, classifyHeuristic("I usually wake at six"));
    try testing.expectEqual(MemorySource.matter, classifyHeuristic("I bought a refractor telescope on Tuesday"));
    try testing.expectEqual(MemorySource.matter, classifyHeuristic(""));
}

test "classifyHeuristic: a typographic apostrophe matches the ASCII phrase" {
    try testing.expectEqual(MemorySource.spirit, classifyHeuristic("I\xe2\x80\x99d like a window seat"));
    try testing.expectEqual(MemorySource.spirit, classifyHeuristic("I\xe2\x80\x99m interested in pottery"));
}

test "assignTags: constant modes" {
    const alloc = testing.allocator;
    const texts = [_][]const u8{ "a plain sentence", "I want tea", "how to brew" };
    var out: [3]MemorySource = undefined;
    try assignTags(alloc, .matter, 0, "q", &texts, &out);
    for (out) |s| try testing.expectEqual(MemorySource.matter, s);
    try assignTags(alloc, .form, 0, "q", &texts, &out);
    for (out) |s| try testing.expectEqual(MemorySource.form, s);
    try assignTags(alloc, .spirit, 0, "q", &texts, &out);
    for (out) |s| try testing.expectEqual(MemorySource.spirit, s);
}

test "assignTags: heuristic mode follows classifyHeuristic per document" {
    const alloc = testing.allocator;
    const texts = [_][]const u8{ "a plain sentence", "I want tea", "how to brew" };
    var out: [3]MemorySource = undefined;
    try assignTags(alloc, .heuristic, 0, "q", &texts, &out);
    try testing.expectEqual(MemorySource.matter, out[0]);
    try testing.expectEqual(MemorySource.spirit, out[1]);
    try testing.expectEqual(MemorySource.form, out[2]);
}

fn countTags(tags: []const MemorySource) [3]usize {
    var c = [_]usize{ 0, 0, 0 };
    for (tags) |t| c[@backingInt(t)] += 1;
    return c;
}

test "assignTags: random mode keeps the tag multiset, is seeded, and moves tags" {
    const alloc = testing.allocator;
    var texts: [60][]const u8 = undefined;
    for (&texts, 0..) |*t, i| {
        t.* = switch (i % 3) {
            0 => "I want a quiet weekend",
            1 => "how to fold a fitted sheet",
            else => "the cat sat on the mat",
        };
    }
    var base: [60]MemorySource = undefined;
    try assignTags(alloc, .heuristic, 0, "q1", &texts, &base);
    var r1: [60]MemorySource = undefined;
    var r1b: [60]MemorySource = undefined;
    var r2: [60]MemorySource = undefined;
    try assignTags(alloc, .random, 1, "q1", &texts, &r1);
    try assignTags(alloc, .random, 1, "q1", &texts, &r1b);
    try assignTags(alloc, .random, 2, "q1", &texts, &r2);

    try testing.expectEqualSlices(usize, &countTags(&base), &countTags(&r1));
    try testing.expectEqualSlices(usize, &countTags(&base), &countTags(&r2));
    try testing.expectEqualSlices(MemorySource, &r1, &r1b);
    try testing.expect(!std.mem.eql(MemorySource, &r1, &r2));
    try testing.expect(!std.mem.eql(MemorySource, &r1, &base));
}

test "assignTags: random mode does not depend on other questions' ids but does on its own" {
    const alloc = testing.allocator;
    var texts: [30][]const u8 = undefined;
    for (&texts, 0..) |*t, i| t.* = if (i % 2 == 0) "I want pie" else "plain text";
    var a: [30]MemorySource = undefined;
    var b: [30]MemorySource = undefined;
    try assignTags(alloc, .random, 5, "qa", &texts, &a);
    try assignTags(alloc, .random, 5, "qb", &texts, &b);
    try testing.expect(!std.mem.eql(MemorySource, &a, &b));
}

test "assignTags: empty documents stay out of the shuffle pool" {
    const alloc = testing.allocator;
    const texts = [_][]const u8{ "I want a", "", "plain", "I want b", "" };
    var out: [5]MemorySource = undefined;
    try assignTags(alloc, .random, 3, "q", &texts, &out);
    try testing.expectEqual(MemorySource.matter, out[1]);
    try testing.expectEqual(MemorySource.matter, out[4]);
}

test "shuffleInPlace: a permutation, deterministic per seed" {
    var a = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var b = a;
    var r1 = stats.SplitMix64.init(11);
    var r2 = stats.SplitMix64.init(11);
    shuffleInPlace(u32, &a, &r1);
    shuffleInPlace(u32, &b, &r2);
    try testing.expectEqualSlices(u32, &a, &b);
    var sorted = a;
    std.mem.sort(u32, &sorted, {}, std.sort.asc(u32));
    for (sorted, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);
    try testing.expect(!std.mem.eql(u32, &a, &[_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }));
}

test "routeOrder: none is the identity" {
    const alloc = testing.allocator;
    const scores = [_]f32{ 3, 2, 1 };
    const src = [_]MemorySource{ .matter, .form, .spirit };
    const o = try routeOrder(alloc, &scores, &src, .spirit, .none, 1.25);
    defer alloc.free(o);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1, 2 }, o);
}

test "routeOrder: filter is a stable partition and loses nothing" {
    const alloc = testing.allocator;
    const scores = [_]f32{ 5, 4, 3, 2, 1 };
    const src = [_]MemorySource{ .matter, .spirit, .matter, .spirit, .form };
    const o = try routeOrder(alloc, &scores, &src, .spirit, .filter, 1.25);
    defer alloc.free(o);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 3, 0, 2, 4 }, o);
}

test "routeOrder: boost reorders only when the multiplier overcomes the gap" {
    const alloc = testing.allocator;
    // 1.25x: 0.9 -> 1.125 beats 1.0; 0.7 -> 0.875 does not.
    const scores = [_]f32{ 1.0, 0.9, 0.7 };
    const src = [_]MemorySource{ .matter, .spirit, .spirit };
    const o = try routeOrder(alloc, &scores, &src, .spirit, .boost, 1.25);
    defer alloc.free(o);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 0, 2 }, o);
    // a boost of exactly 1 is the identity
    const o2 = try routeOrder(alloc, &scores, &src, .spirit, .boost, 1.0);
    defer alloc.free(o2);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1, 2 }, o2);
}

test "routeOrder: ties keep the original order" {
    const alloc = testing.allocator;
    const scores = [_]f32{ 1, 1, 1, 1 };
    const src = [_]MemorySource{ .matter, .matter, .matter, .matter };
    const o = try routeOrder(alloc, &scores, &src, .form, .boost, 1.25);
    defer alloc.free(o);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1, 2, 3 }, o);
}

test "topicWords: most frequent content words, stop words and short words dropped, deterministic" {
    const alloc = testing.allocator;
    const texts = [_][]const u8{
        "The telescope and the telescope mount are on the balcony",
        "My telescope needs a new mount; the balcony is windy",
        "pizza pizza pizza",
    };
    const w = try topicWords(alloc, &texts, 3);
    defer alloc.free(w);
    // pizza x3, telescope x3, balcony x2, mount x2 -> alphabetical among equals.
    try testing.expectEqualStrings("pizza telescope balcony", w);
    const w2 = try topicWords(alloc, &texts, 3);
    defer alloc.free(w2);
    try testing.expectEqualStrings(w, w2);
    // 'the', 'and', 'are' and 3-letter words never appear.
    try testing.expect(std.mem.indexOf(u8, w, "the") == null);
}

test "topicWords: nothing usable gives an empty description" {
    const alloc = testing.allocator;
    const texts = [_][]const u8{ "a an to of", "ok ok ok" };
    const w = try topicWords(alloc, &texts, 5);
    defer alloc.free(w);
    try testing.expectEqual(@as(usize, 0), w.len);
}

test "daysFromCivil: known epoch days" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 11017), daysFromCivil(2000, 3, 1));
    try testing.expectEqual(@as(i64, 19513), daysFromCivil(2023, 6, 5));
    try testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
}

test "parseDateMs: the LongMemEval date format" {
    const a = parseDateMs("2023/05/30 (Tue) 10:00").?;
    const b = parseDateMs("2023/05/30 (Tue) 09:30").?;
    try testing.expectEqual(@as(i64, 30 * 60_000), a - b);
    const day = parseDateMs("2023/05/29 (Mon) 10:00").?;
    try testing.expectEqual(@as(i64, 86_400_000), a - day);
    try testing.expectEqual(@as(i64, 19513) * 86_400_000 + 15 * 3_600_000 + 45 * 60_000, parseDateMs("2023/06/05 (Mon) 15:45").?);
    // date without a time of day is midnight
    try testing.expectEqual(@as(i64, 19513) * 86_400_000, parseDateMs("2023/06/05").?);
    try testing.expect(parseDateMs("") == null);
    try testing.expect(parseDateMs("not a date") == null);
    try testing.expect(parseDateMs("2023/13/45 (Tue) 10:00") == null);
}

test "SYNTHETIC goal-conditioned: the goal machinery works end to end when it can" {
    const r = try synthGoalConditioned(testing.allocator);
    // With the goal bonus the routed goal's target always wins ...
    try testing.expectEqual(r.queries, r.hits_on);
    // ... and without it the eight identical targets tie (chance is 1/8).
    try testing.expect(r.hits_off <= 2);
}

test "SYNTHETIC source-routed: a source router can pick the tagged cell when text cannot" {
    const r = try synthSourceRouted(testing.allocator);
    try testing.expectEqual(r.queries, r.hits_on);
    try testing.expect(r.hits_off < r.queries / 2);
}
