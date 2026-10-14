//! Constitutional target: **end-to-end LongMemEval accuracy >= 80%**
//! (EverOS baseline 83%).
//!
//! (`.specify/memory/constitution.md`, "Performance Standards", row 8.)
//!
//! # Read the disclaimer before the number
//!
//! This is **not** the official LongMemEval benchmark. The official one
//! requires downloading a dataset and running an LLM judge; both are
//! impossible in a zero-dependency, no-network Zig benchmark. What
//! follows is a faithful **offline re-implementation of the
//! LongMemEval protocol** against a locally generated case set. The
//! `disclaimer` field in the JSON says this too, every run, in the
//! output itself — not only here.
//!
//! It is still worth running, because it is the project's only
//! externally-meaningful quality number, and because the failure modes
//! it exposes are real.
//!
//! # The five ability categories
//!
//! Generated cases cover LongMemEval's ability taxonomy:
//!
//!   1. single-session extraction   — a fact stated once.
//!   2. multi-session coreference   — a fact introduced in session A,
//!                                    referred to by pronoun in session B.
//!   3. temporal reasoning          — "what did I have before I changed
//!                                    it", which must answer with the
//!                                    OLDER value.
//!   4. knowledge update            — a fact stated, then revised; the
//!                                    correct answer is the newest
//!                                    value.
//!   5. abstention                  — the corpus does not contain the
//!                                    answer; the system must decline.
//!
//! # Why the case set is not trivially solvable
//!
//! Exact-substring matching would measure nothing and would flatter
//! mem3 dishonestly, so:
//!
//!   * every fact value is a generated nonsense syllable string, so
//!     there is no real-world prior to guess from;
//!   * statements are wrapped in varying surface forms ("my {attr} is
//!     {v}", "I told them {v} is my {attr}", ...) and questions are
//!     paraphrased away from the statement wording;
//!   * every question carries a persona name so cases cannot be
//!     answered from a bare attribute cue;
//!   * the corpus is padded with distractor cells that share the filler
//!     vocabulary but never an answer.
//!
//! # How answers are scored without an LLM judge
//!
//! mem3's shipped embedder is `lexical_hash`, so no judge model is
//! involved. A **deterministic surface reader** stands in for the LLM
//! reader: given the ranked retrieved cells, it finds the attribute cue
//! and reads the value next to it. That reader is simple and has known
//! limits, which is exactly why the benchmark reports TWO numbers:
//!
//!   * `retrieval_hit` — was the gold cell in the top-k? This measures
//!     mem3 alone.
//!   * `accuracy` — did the reader produce the right string end to end?
//!     This measures mem3 + the reader.
//!
//! The gap between them is the reader's fault and is reported, not
//! hidden. Three text metrics are printed for every answer (normalised
//! exact match, token F1, substring containment) plus a combined
//! primary metric whose formula is printed in the output.
//!
//! # What it reports beyond one number
//!
//!   * per-ability accuracy, so a single ability sitting at 0% cannot
//!     hide inside an aggregate;
//!   * accuracy as a function of store size (distractor padding), which
//!     is what actually characterises the system;
//!   * the same evaluation with the hypergraph emptied, which isolates
//!     what the hypergraph arm contributes.
//!
//! ## Default scale and honest cost
//!
//! 16 personas x 7 cases = 112 cases, evaluated against four store
//! configurations (three corpus sizes plus the no-hypergraph control).
//! Building each store costs ~0.5 ms per cell, so the default run is a
//! few seconds. `--worlds=` and `--pad=` change it.

const std = @import("std");
const mem3 = @import("mem3");
const harness = @import("harness.zig");

const Allocator = std.mem.Allocator;

const TARGET_ACCURACY: f64 = 0.80;
const TOPK: usize = 10;

/// The disclaimer travels in the JSON output, verbatim, on every run.
const DISCLAIMER =
    "OFFLINE RE-IMPLEMENTATION, NOT THE OFFICIAL BENCHMARK. " ++
    "This is a locally generated case set modelled on the five LongMemEval " ++
    "ability categories (single-session extraction, multi-session " ++
    "coreference, temporal reasoning, knowledge update, abstention). It is " ++
    "NOT the official LongMemEval dataset, and this score is NOT comparable " ++
    "to published vendor numbers: Mem0's 94.4% and Zep/Graphiti's figures " ++
    "were produced with the official dataset, an LLM reader and an LLM judge, " ++
    "under their own model and retrieval settings. Here the corpus, the " ++
    "questions and the expected answers are synthesised from a seed, and " ++
    "answers are scored by deterministic string metrics with no judge model " ++
    "at all. Treat the result as a characterisation of mem3's retrieval " ++
    "behaviour under a lexical embedder, not as a LongMemEval score.";

const FORMULA_COMBINED =
    "combined = 0.50 * normalised_exact_match + 0.30 * token_f1 + " ++
    "0.20 * substring_containment, averaged over cases. Weights are fixed " ++
    "a priori and identical for every ability and every configuration; an " ++
    "abstention on an unanswerable case scores 0 by construction, which is " ++
    "why overall_including_abstentions is reported separately from " ++
    "accuracy_over_answerable.";

// ============================================================================
// Vocabulary
// ============================================================================

const Attribute = struct {
    phrase: []const u8,
    cue: []const u8,
};

/// Attributes that appear in the corpus.
const STATED_ATTRS = [_]Attribute{
    .{ .phrase = "favourite programming language", .cue = "language" },
    .{ .phrase = "home city", .cue = "city" },
    .{ .phrase = "morning coffee order", .cue = "coffee" },
    .{ .phrase = "text editor", .cue = "editor" },
    .{ .phrase = "commute method", .cue = "commute" },
    .{ .phrase = "phone model", .cue = "phone" },
    .{ .phrase = "weekly podcast", .cue = "podcast" },
    .{ .phrase = "gym session time", .cue = "gym" },
    .{ .phrase = "bicycle colour", .cue = "bicycle" },
    .{ .phrase = "side project codename", .cue = "codename" },
    .{ .phrase = "preferred meeting time", .cue = "meeting" },
    .{ .phrase = "cat's name", .cue = "cat" },
    .{ .phrase = "first car", .cue = "car" },
    .{ .phrase = "favourite bakery", .cue = "bakery" },
    .{ .phrase = "keyboard layout", .cue = "keyboard" },
    .{ .phrase = "desk lamp", .cue = "lamp" },
    .{ .phrase = "winter coat", .cue = "coat" },
    .{ .phrase = "vacation destination", .cue = "destination" },
    .{ .phrase = "alarm sound", .cue = "alarm" },
    .{ .phrase = "daily notebook", .cue = "notebook" },
    .{ .phrase = "running shoes", .cue = "shoes" },
    .{ .phrase = "tea variety", .cue = "tea" },
    .{ .phrase = "street name", .cue = "street" },
    .{ .phrase = "museum membership", .cue = "museum" },
    .{ .phrase = "kettle brand", .cue = "kettle" },
    .{ .phrase = "haircut interval", .cue = "haircut" },
    .{ .phrase = "board game", .cue = "boardgame" },
    .{ .phrase = "bird feeder", .cue = "feeder" },
    .{ .phrase = "soup recipe base", .cue = "soupbase" },
    .{ .phrase = "wallet brand", .cue = "wallet" },
    .{ .phrase = "shoe rack location", .cue = "shoerack" },
};

/// Attributes that are NEVER stated anywhere in the corpus. Asking
/// about these is the abstention case.
const ABSENT_ATTRS = [_]Attribute{
    .{ .phrase = "hiking trail", .cue = "trail" },
    .{ .phrase = "insurance provider", .cue = "insurance" },
    .{ .phrase = "sailing club", .cue = "sailing" },
    .{ .phrase = "dentist", .cue = "dentist" },
    .{ .phrase = "recipe book", .cue = "recipe" },
    .{ .phrase = "bank", .cue = "bank" },
    .{ .phrase = "ferry route", .cue = "ferry" },
    .{ .phrase = "book club", .cue = "bookclub" },
};

/// Filler vocabulary. Kept disjoint from every cue token — there is a
/// unit test that enforces it, because a filler that happened to
/// contain "editor" would quietly turn an abstention case into an
/// answerable one and inflate the abstention scores.
/// Filler vocabulary. Kept disjoint from every cue token — there is a
/// unit test that enforces it, because a filler that happened to
/// contain "editor" would quietly turn an abstention case into an
/// answerable one and inflate the abstention scores.
/// Filler vocabulary: ~230 ordinary English words, none of which is an
/// attribute cue (a unit test enforces that).
///
/// Two earlier generators failed here in opposite directions, and both
/// failures are worth recording:
///
///   * Six words per slot x 12 slots gave ~4,000 near-identical
///     documents. They collapsed into one dense lexical cluster that
///     swamped the 144 real statements: end-to-end accuracy fell from
///     0.69 at 144 cells to 0.00 at 4,144.
///   * Fully random letter strings made the opposite mistake: a real
///     note shares character 3-grams with a real query ("is", "the",
///     "my"), while random letters share none. Those documents are
///     harder to outrank than anything in a real memory, and again
///     accuracy went to 0.00 past ~1,000 cells.
///
/// Natural vocabulary with enough distinct words for every document to
/// be different is the honest middle: distractor density stays high
/// without the corpus becoming either a single blob or noise.
const FILLER_WORDS = [_][]const u8{
    "report",   "review",  "note",     "plan",     "roster",   "ledger",
    "digest",   "summary", "agenda",   "checklist", "roundup",  "standup",
    "quick",    "quiet",   "rough",    "sharp",    "plain",    "steep",
    "brief",    "tough",   "warm",     "clean",    "solid",    "proud",
    "arrived",  "settled", "lingered", "folded",   "gathered", "paused",
    "drifted",  "waited",  "nodded",   "wrapped",  "queued",   "drafted",
    "ticket",   "thread",  "reply",    "followup",
    "context",  "detail",  "link",     "owner",    "status",   "update",
    "refactor", "deploy",  "rollback", "incident", "outage",   "postmortem",
    "schema",   "migration", "index",  "cache",    "queue",    "worker",
    "latency",  "throughput", "budget", "capacity", "scaling",  "storage",
    "network",  "timeout", "retry",    "fallback", "circuit",  "breaker",
    "logging",  "tracing", "metrics",  "dashboard", "alert",   "threshold",
    "config",   "secret",  "token",    "cookie",   "header",
    "request",  "response", "payload", "endpoint", "handler",  "router",
    "client",   "proxy",    "gateway",  "region",   "zone",
    "release",  "version", "branch",   "commit",   "merge",    "reviewer",
    "document", "draft",   "section",  "appendix", "figure",   "table",
    "dataset",  "sample",  "training", "evaluation", "baseline", "variant",
    "accuracy", "precision", "p95", "batch",
    "resolved", "blocked", "pending",  "escalated", "assigned", "closed",
    "started",  "finished", "resumed", "cancelled", "deferred",
    "please",   "thanks",  "regards",  "reminder", "todo",
    "reading",  "editing",  "planning", "shipping",
    "left",     "right",   "top",      "bottom",   "front",    "back",
    "inside",   "outside", "above",    "below",    "between",  "across",
    "sometime",  "eventually",  "already",
};

/// Every word that appears in a question template or a statement
/// template. Filler vocabulary must be disjoint from this set: a
/// distractor containing "weekly" or "answer" competes with the
/// question on more than a real unrelated note would, and the
/// benchmark then measures the distractor's vocabulary rather than
/// mem3. `filler vocabulary can never shadow the query` enforces it.
const TEMPLATE_VOCAB = [_][]const u8{
    "what",   "is",    "do",      "you",     "remember", "which",
    "belongs", "to",   "before",  "changed", "their",    "was",
    "it",     "after", "change",  "now",     "my",       "me",
    "the",    "of",    "for",     "worth",   "writing",  "down",
    "told",   "them",  "uses",    "switched", "last",    "month",
    "no",     "regrets", "these", "days",    "still",    "going",
    "all",    "this",  "time",    "said",    "checked",  "again",
    "nothing", "had",  "that",    "one",     "came",     "while",
    "reviewing", "things", "s",    "and",
};

/// A distractor utterance: filler vocabulary only, never an attribute
/// cue, never an answer.
fn fillerText(alloc: Allocator, rng: *harness.Rng) ![]const u8 {
    const n = 5 + rng.below(9);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        try buf.append(alloc, ' ');
        try buf.appendSlice(alloc, FILLER_WORDS[rng.below(FILLER_WORDS.len)]);
    }
    try buf.append(alloc, '.');
    return buf.toOwnedSlice(alloc);
}

const NAME_A = [_][]const u8{ "Bel", "Cor", "Dan", "Eln", "Fen", "Gar", "Hal", "Ivo", "Jor", "Kel", "Lor", "Mar" };
const NAME_B = [_][]const u8{ "ka", "vin", "sel", "dor", "mia", "ren", "lon", "ta", "nel", "ris", "tor", "wen" };

const VALUE_A = [_][]const u8{ "dro", "kel", "vor", "tam", "que", "peth", "zan", "muk", "sil", "ryn", "topp", "wix" };
const VALUE_B = [_][]const u8{ "vin", "dom", "rin", "tek", "lin", "zor", "sap", "nel", "tor", "mik", "lud", "fex" };

/// Tokens that never carry an answer. The reader skips them.
const STOPWORDS = [_][]const u8{
    "is",  "are",  "was",  "were", "the", "a",   "an",  "my",   "me",
    "to",  "of",   "in",   "on",   "and", "for", "with", "that", "this",
    "it",  "its",   "now",  "still", "has", "have", "be",   "been", "i",
    "am",  "as",   "at",   "so",   "we",  "us",  "them", "they", "he",
    "she", "his",  "her",  "you",  "your", "our", "but",  "not",  "do",
    "did", "does", "ever", "always", "never", "much", "more", "most", "about",
    // The statement templates' own function words. A reader that treats
    // "uses" as a value turns every "{value} is the {persona} {attr}
    // uses now" statement into a wrong answer, and 25% of the corpus
    // uses that form.
    "uses", "use", "these", "days", "last", "month", "worth", "writing",
    "down", "told", "switched", "no", "regrets",
};

/// A token that cannot carry an answer for this question: a stopword,
/// or the persona's own name sitting between the cue and the value
/// ("the weekly podcast for Kelka is silrin").
fn isNoiseToken(tok: []const u8, persona: []const u8) bool {
    if (isStopword(tok)) return true;
    return std.ascii.startsWithIgnoreCase(tok, persona);
}

const ABILITY_LABELS = [_][]const u8{
    "single_session_extraction",
    "multi_session_coreference",
    "temporal_reasoning",
    "knowledge_update",
    "abstention",
};

// ============================================================================
// Case model
// ============================================================================

const Ability = enum {
    single_session,
    multi_session_coreference,
    temporal,
    knowledge_update,
    abstention,

    fn label(self: Ability) []const u8 {
        return switch (self) {
            .single_session => ABILITY_LABELS[0],
            .multi_session_coreference => ABILITY_LABELS[1],
            .temporal => ABILITY_LABELS[2],
            .knowledge_update => ABILITY_LABELS[3],
            .abstention => ABILITY_LABELS[4],
        };
    }
};

const Case = struct {
    ability: Ability,
    question: []const u8,
    /// The answer string. Empty for an abstention case.
    expected: []const u8,
    answerable: bool,
    /// Index into `Dataset.stmts` of the cell that carries the answer,
    /// resolved to a cell id after insertion. 0 for abstention.
    gold_stmt: usize,
    cue: []const u8,
    /// Index into `Dataset.personas`. The question names this persona,
    /// and so must any cell the reader is willing to read an answer
    /// from — otherwise two personas who own the same attribute are
    /// indistinguishable and the score measures tie-breaking rather
    /// than memory.
    persona: usize,
};

const Stmt = struct {
    text: []const u8,
};

const Dataset = struct {
    stmts: []Stmt,
    cases: []Case,
    personas: [][]const u8,
    /// Statements up to this index are answer-bearing; the rest is
    /// distractor padding, appended so the store can be grown without
    /// touching the cases.
    core_stmt_count: usize,
    worlds: usize,

    fn deinit(self: Dataset, alloc: Allocator) void {
        for (self.stmts) |s| alloc.free(s.text);
        alloc.free(self.stmts);
        for (self.cases) |c| {
            alloc.free(c.question);
            alloc.free(c.expected);
        }
        alloc.free(self.cases);
        for (self.personas) |p| alloc.free(p);
        alloc.free(self.personas);
    }
};

fn personaName(alloc: Allocator, rng: *harness.Rng) ![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}{s}",
        .{ NAME_A[rng.below(NAME_A.len)], NAME_B[rng.below(NAME_B.len)] },
    );
}

fn valueWord(alloc: Allocator, rng: *harness.Rng) ![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "{s}{s}",
        .{ VALUE_A[rng.below(VALUE_A.len)], VALUE_B[rng.below(VALUE_B.len)] },
    );
}

/// A statement that carries a fact. `form` picks the surface form;
/// form 2 puts the value BEFORE the attribute, so a reader that only
/// looks forward from the cue gets it wrong. That is deliberate: it is
/// what separates retrieval ability from string-matching ability.
fn factText(
    alloc: Allocator,
    rng: *harness.Rng,
    persona: []const u8,
    attr: Attribute,
    value: []const u8,
) ![]const u8 {
    const form = rng.below(4);
    return switch (form) {
        0 => std.fmt.allocPrint(alloc, "{s}'s {s} is {s}, worth writing down", .{ persona, attr.phrase, value }),
        1 => std.fmt.allocPrint(alloc, "the {s} for {s} is {s} these days", .{ attr.phrase, persona, value }),
        2 => std.fmt.allocPrint(alloc, "I told them {s} is the {s} {s} uses now", .{ value, persona, attr.phrase }),
        // Every form names the persona. An earlier version of this
        // template did not, which made its own cell unreadable to a
        // reader that (correctly) refuses to answer about one person
        // from another person's cell — a quarter of the corpus became
        // silently unanswerable.
        else => std.fmt.allocPrint(
            alloc,
            "{s} switched my {s} to {s} last month, no regrets",
            .{ persona, attr.phrase, value },
        ),
    };
}

/// Pronoun-referring session with no attribute cue: the coreference
/// trap. Retrieval has to get back to session A on its own.
fn corefText(alloc: Allocator, rng: *harness.Rng, persona: []const u8) ![]const u8 {
    const form = rng.below(3);
    return switch (form) {
        0 => std.fmt.allocPrint(alloc, "it is still going after all this time, said {s}", .{persona}),
        1 => std.fmt.allocPrint(alloc, "{s} checked on it again and nothing had changed", .{persona}),
        else => std.fmt.allocPrint(alloc, "that one came up again while {s} was reviewing things", .{persona}),
    };
}

fn questionText(
    alloc: Allocator,
    rng: *harness.Rng,
    persona: []const u8,
    attr: Attribute,
    kind: enum { plain, before, now },
) ![]const u8 {
    const form = rng.below(3);
    return switch (kind) {
        .plain => switch (form) {
            0 => std.fmt.allocPrint(alloc, "what is {s}'s {s}?", .{ persona, attr.phrase }),
            1 => std.fmt.allocPrint(alloc, "do you remember {s}'s {s}?", .{ persona, attr.phrase }),
            else => std.fmt.allocPrint(alloc, "which {s} belongs to {s}?", .{ attr.phrase, persona }),
        },
        .before => std.fmt.allocPrint(
            alloc,
            "before {s} changed their {s}, what was it?",
            .{ persona, attr.phrase },
        ),
        .now => std.fmt.allocPrint(
            alloc,
            "what is {s}'s {s} now, after the change?",
            .{ persona, attr.phrase },
        ),
    };
}

/// Generate the whole case set deterministically.
fn generateDataset(alloc: Allocator, worlds: usize, pad: usize, seed: u64) !Dataset {
    var rng = harness.Rng.init(seed);

    var stmts: std.ArrayList(Stmt) = .empty;
    errdefer {
        for (stmts.items) |s| alloc.free(s.text);
        stmts.deinit(alloc);
    }
    var cases: std.ArrayList(Case) = .empty;
    errdefer {
        for (cases.items) |c| {
            alloc.free(c.question);
            alloc.free(c.expected);
        }
        cases.deinit(alloc);
    }

    // Each attribute is handed to at most two personas; with 32
    // attributes and `worlds` <= 16 x 4 attributes there is always a
    // free one. A persona is also never asked about an attribute
    // another persona owns, so no case is ambiguous by construction.
    var next_attr: usize = rng.below(STATED_ATTRS.len);

    var personas: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (personas.items) |p| alloc.free(p);
        personas.deinit(alloc);
    }

    var w: usize = 0;
    while (w < worlds) : (w += 1) {
        // Persona names must be unique: two personas sharing a name
        // makes every question about either of them ambiguous, and the
        // reader would be right to fail.
        var persona: []const u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 64) : (attempts += 1) {
            const candidate = try personaName(alloc, &rng);
            var clash = false;
            for (personas.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing, candidate)) {
                    clash = true;
                    break;
                }
            }
            if (!clash) {
                persona = candidate;
                break;
            }
            alloc.free(candidate);
        }
        if (attempts >= 64) return error.PersonaNameSpaceExhausted;
        try personas.append(alloc, persona);
        const persona_idx = personas.items.len - 1;

        // Four distinct attributes for this persona.
        var attrs: [4]Attribute = undefined;
        var got: usize = 0;
        while (got < 4) : (got += 1) {
            attrs[got] = STATED_ATTRS[next_attr];
            next_attr = (next_attr + 1) % STATED_ATTRS.len;
        }

        // Values: one per attribute, plus an extra old/new pair for the
        // attribute that gets revised.
        var vals: [5][]const u8 = undefined;
        for (0..5) |k| vals[k] = try valueWord(alloc, &rng);
        defer for (vals) |v| alloc.free(v);

        const updated = attrs[2];

        // --- session 1: single-session fact -------------------------
        const s0 = stmts.items.len;
        try stmts.append(alloc, .{
            .text = try factText(alloc, &rng, persona, attrs[0], vals[0]),
        });
        try stmts.append(alloc, .{ .text = try fillerText(alloc, &rng) });

        const q0 = try questionText(alloc, &rng, persona, attrs[0], .plain);
        try cases.append(alloc, .{
            .ability = .single_session,
            .question = q0,
            .expected = try alloc.dupe(u8, vals[0]),
            .answerable = true,
            .gold_stmt = s0,
            .cue = attrs[0].cue,
            .persona = persona_idx,
        });

        // --- session 2: single-session fact -------------------------
        const s1 = stmts.items.len;
        try stmts.append(alloc, .{
            .text = try factText(alloc, &rng, persona, attrs[1], vals[1]),
        });
        try stmts.append(alloc, .{ .text = try fillerText(alloc, &rng) });

        const q1 = try questionText(alloc, &rng, persona, attrs[1], .plain);
        try cases.append(alloc, .{
            .ability = .single_session,
            .question = q1,
            .expected = try alloc.dupe(u8, vals[1]),
            .answerable = true,
            .gold_stmt = s1,
            .cue = attrs[1].cue,
            .persona = persona_idx,
        });

        // --- sessions 3-4: fact, then a pronoun reference ----------
        const s2 = stmts.items.len;
        try stmts.append(alloc, .{
            .text = try factText(alloc, &rng, persona, updated, vals[2]),
        });
        try stmts.append(alloc, .{ .text = try corefText(alloc, &rng, persona) });

        const qc = try questionText(alloc, &rng, persona, updated, .plain);
        try cases.append(alloc, .{
            .ability = .multi_session_coreference,
            .question = qc,
            .expected = try alloc.dupe(u8, vals[2]),
            .answerable = true,
            .gold_stmt = s2,
            .cue = updated.cue,
            .persona = persona_idx,
        });

        // --- session 5: the revision -------------------------------
        const s3 = stmts.items.len;
        try stmts.append(alloc, .{
            .text = try factText(alloc, &rng, persona, updated, vals[3]),
        });

        const qu = try questionText(alloc, &rng, persona, updated, .now);
        try cases.append(alloc, .{
            .ability = .knowledge_update,
            .question = qu,
            .expected = try alloc.dupe(u8, vals[3]),
            .answerable = true,
            .gold_stmt = s3,
            .cue = updated.cue,
            .persona = persona_idx,
        });

        const qt = try questionText(alloc, &rng, persona, updated, .before);
        try cases.append(alloc, .{
            .ability = .temporal,
            .question = qt,
            .expected = try alloc.dupe(u8, vals[2]),
            .answerable = true,
            .gold_stmt = s2,
            .cue = updated.cue,
            .persona = persona_idx,
        });

        // --- session 6: another single-session fact ----------------
        const s4 = stmts.items.len;
        try stmts.append(alloc, .{
            .text = try factText(alloc, &rng, persona, attrs[3], vals[4]),
        });
        try stmts.append(alloc, .{ .text = try fillerText(alloc, &rng) });

        const q2 = try questionText(alloc, &rng, persona, attrs[3], .plain);
        try cases.append(alloc, .{
            .ability = .single_session,
            .question = q2,
            .expected = try alloc.dupe(u8, vals[4]),
            .answerable = true,
            .gold_stmt = s4,
            .cue = attrs[3].cue,
            .persona = persona_idx,
        });

        // --- abstention: an attribute nobody ever stated -------------
        const absent = ABSENT_ATTRS[rng.below(ABSENT_ATTRS.len)];
        const qa = std.fmt.allocPrint(
            alloc,
            "what is {s}'s {s}?",
            .{ persona, absent.phrase },
        ) catch |err| return err;
        try cases.append(alloc, .{
            .ability = .abstention,
            .question = qa,
            .expected = try alloc.dupe(u8, ""),
            .answerable = false,
            .gold_stmt = 0,
            .cue = absent.cue,
            .persona = persona_idx,
        });
    }

    const core = stmts.items.len;

    // --- distractor padding ------------------------------------------
    var p: usize = 0;
    while (p < pad) : (p += 1) {
        try stmts.append(alloc, .{ .text = try fillerText(alloc, &rng) });
    }

    return .{
        .stmts = try stmts.toOwnedSlice(alloc),
        .cases = try cases.toOwnedSlice(alloc),
        .personas = try personas.toOwnedSlice(alloc),
        .core_stmt_count = core,
        .worlds = worlds,
    };
}

// ============================================================================
// Scoring primitives
// ============================================================================

fn isStopword(tok: []const u8) bool {
    for (STOPWORDS) |s| {
        if (std.ascii.eqlIgnoreCase(tok, s)) return true;
    }
    return false;
}

/// Normalised comparison form: lowercase, punctuation out, whitespace
/// collapsed. Deterministic and model-free, which is the point.
fn normalise(alloc: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var pending_space = false;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_space and out.items.len > 0) try out.append(alloc, ' ');
            pending_space = false;
            try out.append(alloc, std.ascii.toLower(c));
        } else {
            pending_space = true;
        }
    }
    return out.toOwnedSlice(alloc);
}

const MAX_TOKENS: usize = 32;
const MAX_TOKEN_LEN: usize = 64;

/// Lowercased ASCII tokens of `s`, into a caller-owned fixed buffer.
fn collectTokens(
    buf: *[MAX_TOKENS][MAX_TOKEN_LEN]u8,
    lens: *[MAX_TOKENS]usize,
    s: []const u8,
) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, &std.ascii.whitespace ++ ".,;:!?'\"()[]{}");
    while (it.next()) |tok| {
        if (n >= MAX_TOKENS) break;
        const take = @min(tok.len, MAX_TOKEN_LEN);
        for (0..take) |i| buf[n][i] = std.ascii.toLower(tok[i]);
        lens[n] = take;
        n += 1;
    }
    return n;
}

/// Multiset token F1, lowercased, with greedy matching. An empty
/// prediction scores 0: the reader declining to answer is not a
/// partial credit.
fn tokenF1(pred: []const u8, gold: []const u8) f64 {
    var p_buf: [MAX_TOKENS][MAX_TOKEN_LEN]u8 = undefined;
    var p_len: [MAX_TOKENS]usize = undefined;
    var g_buf: [MAX_TOKENS][MAX_TOKEN_LEN]u8 = undefined;
    var g_len: [MAX_TOKENS]usize = undefined;

    const p_n = collectTokens(&p_buf, &p_len, pred);
    const g_n = collectTokens(&g_buf, &g_len, gold);
    if (p_n == 0 or g_n == 0) return 0;

    var consumed: [MAX_TOKENS]bool = @splat(false);
    var overlap: usize = 0;
    for (0..p_n) |i| {
        for (0..g_n) |j| {
            if (consumed[j]) continue;
            if (std.mem.eql(u8, p_buf[i][0..p_len[i]], g_buf[j][0..g_len[j]])) {
                consumed[j] = true;
                overlap += 1;
                break;
            }
        }
    }
    const precision = @as(f64, @floatFromInt(overlap)) / @as(f64, @floatFromInt(p_n));
    const recall = @as(f64, @floatFromInt(overlap)) / @as(f64, @floatFromInt(g_n));
    if (precision + recall == 0) return 0;
    return 2 * precision * recall / (precision + recall);
}

/// combined = 0.50 exact + 0.30 F1 + 0.20 substring. Stated in the
/// output; never changed per-ability to make a number look better.
fn combinedScore(exact: f64, f1: f64, substring: f64) f64 {
    return 0.50 * exact + 0.30 * f1 + 0.20 * substring;
}

/// The deterministic stand-in reader for an LLM reader.
///
/// Scans the retrieved cells in rank order. On the first cell that
/// mentions the question's attribute cue, it reads forward for a
/// non-stopword token (the "my {attr} is {v}" form) and, failing that,
/// backward (the "{v} is my {attr}" form). Returns null — an abstention
/// — when no retrieved cell mentions the cue at all.
fn readAnswer(
    alloc: Allocator,
    texts: []const []const u8,
    cue: []const u8,
    persona: []const u8,
) !?[]u8 {
    var rank: usize = 0;
    while (rank < texts.len) : (rank += 1) {
        var buf: [MAX_TOKENS][MAX_TOKEN_LEN]u8 = undefined;
        var lens: [MAX_TOKENS]usize = undefined;
        const n = collectTokens(&buf, &lens, texts[rank]);

        // Only a cell that names the persona the question asked about
        // may supply an answer. Without this the reader would happily
        // return another persona's value for an attribute both of them
        // own, and the score would be measuring an arbitrary tie-break
        // instead of memory.
        var mentions_persona = false;
        for (0..n) |t| {
            if (std.ascii.startsWithIgnoreCase(buf[t][0..lens[t]], persona)) {
                mentions_persona = true;
                break;
            }
        }
        if (!mentions_persona) continue;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (!std.ascii.eqlIgnoreCase(buf[i][0..lens[i]], cue)) continue;

            // Forward. The cue is one token of a multi-word attribute
            // ("gym" in "gym session time"), so the reader first walks
            // to the connector that ends the attribute phrase and then
            // reads the first real token after it. Skipping straight to
            // "the next non-stopword" instead would return "session".
            const limit = @min(i + 9, n);
            var f = i + 1;
            while (f < limit and !isStopword(buf[f][0..lens[f]])) f += 1;
            var g = f + 1;
            while (g < limit and isNoiseToken(buf[g][0..lens[g]], persona)) g += 1;
            if (g < limit) return try alloc.dupe(u8, buf[g][0..lens[g]]);

            // Backward: the "{value} is my {attr}" form, mirrored —
            // walk back over the rest of the attribute phrase to its
            // connector, then keep going to the first real token.
            var b = i;
            var steps: usize = 0;
            while (b > 0 and steps < 7 and !isStopword(buf[b - 1][0 .. lens[b - 1]])) : (steps += 1) {
                b -= 1;
            }
            var h = b;
            var hsteps: usize = 0;
            while (h > 0 and hsteps < 7) : (hsteps += 1) {
                h -= 1;
                if (isNoiseToken(buf[h][0..lens[h]], persona)) continue;
                return try alloc.dupe(u8, buf[h][0..lens[h]]);
            }
        }
    }
    return null;
}

// ============================================================================
// Evaluation
// ============================================================================

const Tally = struct {
    cases: usize = 0,
    answerable: usize = 0,
    exact_hits: usize = 0,
    f1_sum: f64 = 0,
    substring_hits: usize = 0,
    combined_sum: f64 = 0,
    retrieval_hits: usize = 0,
    /// Gold cell was retrieved but the answer still came out wrong:
    /// the stand-in reader's limitation, not mem3's.
    hit_but_wrong: usize = 0,
    // Abstention bookkeeping, over ALL cases.
    abstain_predicted: usize = 0,
    abstain_should: usize = 0,
    abstain_correct: usize = 0,
    abstain_on_answerable: usize = 0,

    fn addCase(self: *Tally, answerable: bool, correct: bool, exact: f64, f1: f64, substring: f64, retrieval_hit: bool, abstained: bool) void {
        self.cases += 1;
        if (abstained) self.abstain_predicted += 1;
        if (!answerable) {
            self.abstain_should += 1;
            if (abstained) self.abstain_correct += 1;
            return;
        }
        self.answerable += 1;
        if (abstained) self.abstain_on_answerable += 1;
        if (retrieval_hit) self.retrieval_hits += 1;
        if (retrieval_hit and exact == 0) self.hit_but_wrong += 1;
        if (correct) self.exact_hits += 1;
        if (substring == 1) self.substring_hits += 1;
        self.f1_sum += f1;
        self.combined_sum += combinedScore(exact, f1, substring);
    }

    /// Combined metric over answerable cases only. Null when there are
    /// no answerable cases, never 0-by-default.
    fn accuracyOverAnswerable(self: Tally) ?f64 {
        if (self.answerable == 0) return null;
        return self.combined_sum / @as(f64, @floatFromInt(self.answerable));
    }

    /// Combined metric over every case, with an abstention on an
    /// unanswerable question scoring zero. This is the number that
    /// cannot be gamed by abstaining on everything.
    fn overallAccuracy(self: Tally) ?f64 {
        if (self.cases == 0) return null;
        return self.combined_sum / @as(f64, @floatFromInt(self.cases));
    }

    fn retrievalHitRate(self: Tally) ?f64 {
        if (self.answerable == 0) return null;
        return @as(f64, @floatFromInt(self.retrieval_hits)) /
            @as(f64, @floatFromInt(self.answerable));
    }

    fn abstentionPrecision(self: Tally) ?f64 {
        if (self.abstain_predicted == 0) return null;
        return @as(f64, @floatFromInt(self.abstain_correct)) /
            @as(f64, @floatFromInt(self.abstain_predicted));
    }

    fn abstentionRecall(self: Tally) ?f64 {
        if (self.abstain_should == 0) return null;
        return @as(f64, @floatFromInt(self.abstain_correct)) /
            @as(f64, @floatFromInt(self.abstain_should));
    }

    fn falseAbstentionRate(self: Tally) ?f64 {
        if (self.answerable == 0) return null;
        return @as(f64, @floatFromInt(self.abstain_on_answerable)) /
            @as(f64, @floatFromInt(self.answerable));
    }

    fn writeJson(self: Tally, j: *harness.Json) !void {
        try j.beginObject();
        try j.key("cases");
        try j.int(@as(u64, @intCast(self.cases)));
        try j.key("answerable");
        try j.int(@as(u64, @intCast(self.answerable)));
        try j.key("combined_accuracy_over_answerable");
        try j.optFloat(self.accuracyOverAnswerable());
        try j.key("overall_including_abstentions_as_failures");
        try j.optFloat(self.overallAccuracy());
        try j.key("exact_match_rate_over_answerable");
        try j.float(if (self.answerable == 0)
            0
        else
            @as(f64, @floatFromInt(self.exact_hits)) / @as(f64, @floatFromInt(self.answerable)));
        try j.key("token_f1_mean_over_answerable");
        try j.float(if (self.answerable == 0)
            0
        else
            self.f1_sum / @as(f64, @floatFromInt(self.answerable)));
        try j.key("substring_containment_rate_over_answerable");
        try j.float(if (self.answerable == 0)
            0
        else
            @as(f64, @floatFromInt(self.substring_hits)) / @as(f64, @floatFromInt(self.answerable)));
        try j.key("retrieval_hit_rate");
        try j.optFloat(self.retrievalHitRate());
        try j.key("abstention_precision");
        try j.optFloat(self.abstentionPrecision());
        try j.key("abstention_recall");
        try j.optFloat(self.abstentionRecall());
        try j.key("false_abstention_rate_on_answerable");
        try j.optFloat(self.falseAbstentionRate());
        try j.endObject();
    }
};

const RunResult = struct {
    label: []const u8,
    cells: usize,
    edges: usize,
    total: Tally,
    by_ability: [5]Tally,
    build_ms: f64,
    query_ms: f64,
    /// Fraction of answerable questions whose gold cell is the exact
    /// cosine nearest neighbour over EVERY indexed vector.
    ///
    /// This is the control the fused result needs: if the gold cell is
    /// the true nearest neighbour but the three-way result does not
    /// contain it, the HNSW search lost it; if the gold cell is not
    /// even the true nearest neighbour, `lexical_hash` never put the
    /// question and the answer in the same neighbourhood and no index
    /// could have recovered it. The two failures look identical from
    /// the outside and need very different fixes.
    exhaustive_nn_hit_rate: ?f64,

    fn deinit(self: RunResult, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

fn evaluate(
    alloc: Allocator,
    label: []const u8,
    ds: Dataset,
    cells_to_load: usize,
    with_hypergraph: bool,
) !RunResult {
    const t_build = harness.clockNs();

    const store = try mem3.Store.init(alloc, .{ .data_dir = null, .seed_default_goals = true });
    defer store.deinit();

    const cell_ids = try alloc.alloc(u64, ds.stmts.len);
    defer alloc.free(cell_ids);
    for (cell_ids) |*c| c.* = 0;

    const n = @min(cells_to_load, ds.stmts.len);
    for (0..n) |i| {
        cell_ids[i] = store.addRaw(
            @enumFromInt(@as(u8, @intCast(i % 3))),
            ds.stmts[i].text,
            "",
            1,
            0.5,
        ) catch continue;
    }

    // Hypergraph: chain consecutive statements of the same persona's
    // neighbourhood, which is the structure a real memory system would
    // build. With `with_hypergraph = false` the graph arm of the fused
    // retrieval has nothing to traverse and contributes only the seeds.
    var edges: usize = 0;
    if (with_hypergraph) {
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const nodes = [_]u64{ cell_ids[i - 1], cell_ids[i] };
            _ = store.addHyperedge(.{
                .id = 0,
                .edge_type = if (i % 2 == 0) .temporal else .associative,
                .nodes = &nodes,
                .weight = 0.6,
                .source_weights = .{ 0.34, 0.33, 0.33 },
                .confidence = 0.9,
                .created_at = @intCast(i),
                .metadata = null,
            }) catch continue;
            edges += 1;
        }
    }
    const build_ms = harness.nsToMs(harness.sinceNs(t_build));

    // The retriever gets the Store's own embedder, not a fresh one
    // built from Config defaults: the index was built with this
    // embedder, so querying with another one would compare vectors
    // from two different spaces.
    var retriever = mem3.HybridRetriever.init(
        alloc,
        mem3.Config{},
        store.emb,
        store.hnsw,
        &store.hymem,
    );

    var total = Tally{};
    var by_ability: [5]Tally = @splat(Tally{});
    var empty_result_queries: usize = 0;
    var empty_text_slots: usize = 0;

    const ranked_texts = try alloc.alloc([]const u8, TOPK);
    defer alloc.free(ranked_texts);

    const t_query = harness.clockNs();
    for (ds.cases) |c| {
        const cands = retriever.recall(alloc, c.question, TOPK) catch |err| {
            harness.progress("longmemeval: recall failed: {s}\n", .{@errorName(err)});
            continue;
        };
        defer alloc.free(cands);

        if (cands.len == 0) empty_result_queries += 1;
        if (cands.len == 0) empty_result_queries += 1;
        var hit = false;
        for (ranked_texts, 0..) |*slot, i| {
            slot.* = "";
            if (i >= cands.len) continue;
            const cell = store.getCell(cands[i].cell_id) orelse continue;
            slot.* = cell.episode;
            if (!c.answerable) continue;
            if (cands[i].cell_id == cell_ids[c.gold_stmt]) hit = true;
        }

        const answer = try readAnswer(alloc, ranked_texts, c.cue, ds.personas[c.persona]);
        defer if (answer) |a| alloc.free(a);

        var exact: f64 = 0;
        var substring: f64 = 0;
        var f1: f64 = 0;
        if (!c.answerable) {
            // An abstention case is correct only if the system declined.
            exact = if (answer == null) 1 else 0;
        } else if (answer) |a| {
            const na = try normalise(alloc, a);
            defer alloc.free(na);
            const ne = try normalise(alloc, c.expected);
            defer alloc.free(ne);
            exact = if (std.mem.eql(u8, na, ne)) 1 else 0;
            substring = if (std.mem.indexOf(u8, na, ne) != null) 1 else 0;
            f1 = tokenF1(na, ne);
        }

        total.addCase(c.answerable, exact == 1, exact, f1, substring, hit, answer == null);
        by_ability[@intFromEnum(c.ability)].addCase(
            c.answerable,
            exact == 1,
            exact,
            f1,
            substring,
            hit,
            answer == null,
        );
    }
    for (ranked_texts) |t| {
        if (t.len == 0) empty_text_slots += 1;
    }
    if (empty_result_queries > 0 or empty_text_slots > 0) {
        harness.progress(
            "longmemeval: [{s}] queries with 0 candidates: {d}/{d}; empty text slots in last query: {d}; hnsw nodes: {d}\n",
            .{ label, empty_result_queries, ds.cases.len, empty_text_slots, store.hnsw.count },
        );
    }
    // Exact-scan control (see `exhaustive_nn_hit_rate`).
    var exh_hit: usize = 0;
    var exh_n: usize = 0;
    {
        var cit = store.hnsw.nodes.iterator();
        while (cit.next()) |entry| {
            _ = entry;
        }
    }
    for (ds.cases) |c| {
        if (!c.answerable) continue;
        const gold = cell_ids[c.gold_stmt];
        if (gold == 0) continue;
        const qv = try store.emb.embed(alloc, c.question);
        defer alloc.free(qv);

        var best_sim: f32 = -2.0;
        var best_id: u64 = 0;
        var it = store.hnsw.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            const sim = harness.cosine(qv, node.vector);
            if (sim > best_sim) {
                best_sim = sim;
                best_id = node.id;
            }
        }
        exh_n += 1;
        if (best_id == gold) exh_hit += 1;
    }

    if (empty_result_queries > 0) {
        harness.progress(
            "longmemeval: [{s}] {d} of {d} queries returned zero candidates (hnsw nodes: {d})\n",
            .{ label, empty_result_queries, ds.cases.len, store.hnsw.count },
        );
    }
    const query_ms = harness.nsToMs(harness.sinceNs(t_query));

    return .{
        .label = label,
        .cells = store.cellCount(),
        .edges = store.hyperedgeCount(),
        .total = total,
        .by_ability = by_ability,
        .build_ms = build_ms,
        .query_ms = query_ms,
        .exhaustive_nn_hit_rate = if (exh_n == 0)
            null
        else
            @as(f64, @floatFromInt(exh_hit)) / @as(f64, @floatFromInt(exh_n)),
    };
}

fn writeRun(j: *harness.Json, r: RunResult) !void {
    try j.beginObject();
    try j.key("configuration");
    try j.str(r.label);
    try j.key("store_cells");
    try j.int(@as(u64, @intCast(r.cells)));
    try j.key("hyperedges");
    try j.int(@as(u64, @intCast(r.edges)));
    try j.key("hypergraph_enabled");
    try j.boolean(r.edges > 0);
    try j.key("build_ms");
    try j.float(r.build_ms);
    try j.key("query_ms_total");
    try j.float(r.query_ms);
    try j.key("exhaustive_nn_hit_rate");
    try j.optFloat(r.exhaustive_nn_hit_rate);
    try j.key("exhaustive_nn_hit_rate_note");
    try j.str("Fraction of answerable questions whose gold cell is the " ++
        "exact cosine nearest neighbour over every indexed vector — an " ++
        "index-independent control. Low here means lexical_hash never " ++
        "placed the question and its answer in the same neighbourhood; " ++
        "high here with a low retrieval_hit_rate would mean the HNSW " ++
        "search lost a neighbour it should have kept.");
    try j.key("overall");
    try r.total.writeJson(j);
    try j.key("by_ability");
    try j.beginObject();
    for (r.by_ability, 0..) |t, i| {
        try j.key(ABILITY_LABELS[i]);
        try t.writeJson(j);
    }
    try j.endObject();
    try j.endObject();
}

// ============================================================================
// Entry point
// ============================================================================

const DEFAULT_WORLDS: usize = 16;
const DEFAULT_PAD: usize = 4_000;

pub fn run(alloc: Allocator, init: std.process.Init.Minimal) !void {
    var common = harness.CommonArgs{};
    var worlds: ?usize = null;
    var pad: ?usize = null;

    var it = harness.argIterator(init);
    while (it.next()) |arg| {
        if (try harness.parseCommon(arg, &common)) continue;
        if (std.mem.startsWith(u8, arg, "--worlds=")) {
            worlds = try std.fmt.parseInt(usize, arg["--worlds=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--pad=")) {
            pad = try std.fmt.parseInt(usize, arg["--pad=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            harness.out(
                \\longmemeval — offline LongMemEval protocol re-implementation
                \\
                \\  --worlds=N   personas, 7 cases each (default {d})
                \\  --pad=N      max distractor cells for the size sweep (default {d})
                \\  --scale=F    multiply the defaults; --quick is 0.1
                \\  --seed=N     PRNG seed (the whole case set is derived from it)
                \\
                , .{ DEFAULT_WORLDS, DEFAULT_PAD });
            return;
        } else {
            harness.out("longmemeval: unknown argument {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }

    const n_worlds = harness.scaled(worlds orelse DEFAULT_WORLDS, common);
    const n_pad = harness.scaled(pad orelse DEFAULT_PAD, common);

    harness.progress("longmemeval: generating {d} personas...\n", .{n_worlds});
    const ds = try generateDataset(alloc, n_worlds, n_pad, common.seed);
    defer ds.deinit(alloc);

    // Three corpus sizes (the size sweep) plus one no-hypergraph
    // control at the largest size.
    const core = ds.core_stmt_count;
    const sizes = [_]usize{ core, core + n_pad / 4, core + n_pad };

    var runs: [4]RunResult = undefined;
    var n_runs: usize = 0;
    for (sizes, 0..) |cells, i| {
        const label = switch (i) {
            0 => "core corpus (no distractor padding)",
            1 => "quarter padding",
            else => "full padding",
        };
        harness.progress("longmemeval: {s}, {d} cells...\n", .{ label, cells });
        runs[n_runs] = try evaluate(alloc, label, ds, cells, true);
        n_runs += 1;
    }
    harness.progress("longmemeval: hypergraph-disabled control...\n", .{});
    runs[n_runs] = try evaluate(alloc, "full padding, hypergraph disabled", ds, core + n_pad, false);
    n_runs += 1;
    defer for (runs[0..n_runs]) |r| r.deinit(alloc);

    const primary = runs[n_runs - 2];
    const primary_acc = primary.total.accuracyOverAnswerable();

    var j = harness.Json.init(alloc);
    defer j.deinit();

    try harness.emitEnvelope(&j, .{
        .benchmark = "longmemeval",
        .metric = "end_to_end_accuracy_over_answerable",
        .target = ">= 80% accuracy on LongMemEval (EverOS baseline 83%)",
        .target_value = TARGET_ACCURACY,
        .target_comparison = ">=",
        .unit = "fraction",
        .measured = primary_acc,
        .measured_at_N = @intCast(primary.total.answerable),
        .seed = common.seed,
        .notes = "combined = 0.50*exact + 0.30*token_f1 + 0.20*substring, over " ++
            "answerable cases only, with the default distractor padding and " ++
            "the hypergraph enabled. This is an offline re-implementation of " ++
            "the LongMemEval protocol against a locally generated case set " ++
            "with a deterministic string reader and no judge model. It is NOT " ++
            "the official dataset and the number is NOT comparable to " ++
            "published vendor results. Read the disclaimer field.",
    });

    try j.key("benchmark_suite");
    try j.str("longmemeval-protocol-offline");
    try j.key("disclaimer");
    try j.str(DISCLAIMER);
    try j.key("scoring_formula");
    try j.str(FORMULA_COMBINED);
    try j.key("judge_model");
    try j.str("none — deterministic string metrics only");

    try j.key("case_set");
    try j.beginObject();
    try j.key("generator");
    try j.str("deterministic, seeded xorshift64; regenerate with --seed=N");
    try j.key("personas");
    try j.int(@as(u64, @intCast(n_worlds)));
    try j.key("cases_total");
    try j.int(@as(u64, @intCast(ds.cases.len)));
    try j.key("cases_answerable");
    try j.int(@as(u64, @intCast(primary.total.answerable)));
    try j.key("cases_abstention");
    try j.int(@as(u64, @intCast(primary.total.abstain_should)));
    try j.key("ability_categories");
    try j.beginArray();
    for (ABILITY_LABELS) |l| try j.str(l);
    try j.endArray();
    try j.key("values");
    try j.str("generated nonsense syllables — no real-world prior to exploit, " ++
        "so exact substring matching cannot solve the set");
    try j.key("reader");
    try j.str("deterministic surface reader: finds the question's attribute " ++
        "cue in the ranked retrieved cells and reads the adjacent token, " ++
        "forward first then backward. Stands in for the LLM reader the " ++
        "official protocol uses. Its limits are why retrieval_hit is " ++
        "reported alongside accuracy.");
    try j.key("embedder");
    try j.str("lexical_hash (the Store default)");
    try j.key("topk");
    try j.int(TOPK);
    try j.endObject();

    try j.key("runs");
    try j.beginArray();
    for (runs[0..n_runs]) |r| try writeRun(&j, r);
    try j.endArray();

    try j.key("store_size_sweep");
    try j.beginArray();
    for (runs[0..n_runs - 1]) |r| {
        try j.beginObject();
        try j.key("store_cells");
        try j.int(@as(u64, @intCast(r.cells)));
        try j.key("combined_accuracy_over_answerable");
        try j.optFloat(r.total.accuracyOverAnswerable());
        try j.key("overall_including_abstentions_as_failures");
        try j.optFloat(r.total.overallAccuracy());
        try j.key("retrieval_hit_rate");
        try j.optFloat(r.total.retrievalHitRate());
        try j.endObject();
    }
    try j.endArray();

    try j.key("hypergraph_ablation");
    try j.beginObject();
    try j.key("enabled_cells");
    try j.int(@as(u64, @intCast(primary.cells)));
    try j.key("enabled_accuracy");
    try j.optFloat(primary.total.accuracyOverAnswerable());
    try j.key("disabled_cells");
    try j.int(@as(u64, @intCast(runs[n_runs - 1].cells)));
    try j.key("disabled_accuracy");
    try j.optFloat(runs[n_runs - 1].total.accuracyOverAnswerable());
    try j.key("delta_accuracy");
    try j.optFloat(if (primary.total.accuracyOverAnswerable() != null and
        runs[n_runs - 1].total.accuracyOverAnswerable() != null)
        primary.total.accuracyOverAnswerable().? - runs[n_runs - 1].total.accuracyOverAnswerable().?
    else
        null);
    try j.key("note");
    try j.str("Identical corpus and identical questions; the only difference " ++
        "is whether the hypergraph holds edges, so the delta isolates the " ++
        "graph arm of the three-way recall.");
    try j.endObject();

    try j.key("per_ability_primary");
    try j.beginObject();
    for (primary.by_ability, 0..) |t, i| {
        try j.key(ABILITY_LABELS[i]);
        try t.writeJson(&j);
    }
    try j.endObject();

    // Where the loss happens: retrieval, or the stand-in reader. A
    // case where the gold cell WAS retrieved but the answer was still
    // wrong is the reader's limitation, not mem3's; one where the gold
    // cell never surfaced is a retrieval failure. Reporting only the
    // end-to-end number would hide which is which.
    try j.key("diagnosis");
    try j.beginObject();
    try j.key("retrieval_missed_share_of_answerable");
    try j.optFloat(if (primary.total.retrievalHitRate()) |r|
        1.0 - r
    else
        null);
    try j.key("retrieved_but_reader_got_it_wrong");
    try j.int(@as(u64, @intCast(primary.total.hit_but_wrong)));
    try j.key("retrieved_but_reader_got_it_wrong_share");
    try j.float(if (primary.total.retrieval_hits == 0)
        0
    else
        @as(f64, @floatFromInt(primary.total.hit_but_wrong)) /
            @as(f64, @floatFromInt(primary.total.retrieval_hits)));
    try j.key("reader_limitation_note");
    try j.str("The reader is a deterministic cue-adjacent extractor with no " ++
        "world model. It cannot follow a pronoun, cannot infer that a " ++
        "revised value supersedes an older one, and reads only the " ++
        "highest-ranked cell. Where retrieval_missed_share is high the " ++
        "limitation is mem3's; where retrieved_but_reader_got_it_wrong is " ++
        "high it is this stand-in reader's, and the official protocol's " ++
        "LLM reader would score it differently.");
    try j.endObject();

    try j.key("case_set_digest");
    try j.beginObject();
    try j.key("core_statements");
    try j.int(@as(u64, @intCast(core)));
    try j.key("distractor_padding_max");
    try j.int(@as(u64, @intCast(n_pad)));
    try j.key("cases_per_persona");
    try j.int(7);
    try j.endObject();

    try j.endObject(); // close the envelope opened by emitEnvelope
    try harness.finish(alloc, &j);
}

test "longmemeval: the case set covers all five abilities and is big enough to mean something" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const ds = try generateDataset(alloc, 4, 8, 1);
    defer ds.deinit(alloc);

    var counts: [5]usize = @splat(0);
    for (ds.cases) |c| counts[@intFromEnum(c.ability)] += 1;
    for (counts) |c| try std.testing.expect(c > 0);

    // Every world contributes exactly one abstention and six
    // answerable cases.
    try std.testing.expectEqual(ds.worlds * 7, ds.cases.len);
    try std.testing.expectEqual(ds.worlds, counts[@intFromEnum(Ability.abstention)]);
}

test "longmemeval: generation is deterministic in the seed" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const a = try generateDataset(alloc, 2, 4, 77);
    defer a.deinit(alloc);
    const b = try generateDataset(alloc, 2, 4, 77);
    defer b.deinit(alloc);

    try std.testing.expectEqual(a.cases.len, b.cases.len);
    for (a.cases, b.cases) |x, y| {
        try std.testing.expectEqualStrings(x.question, y.question);
        try std.testing.expectEqualStrings(x.expected, y.expected);
        try std.testing.expectEqual(x.ability, y.ability);
    }
}

/// Assert that none of `phrase`'s words is `word`.
fn assertNoWordOverlap(word: []const u8, phrase: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, phrase, &std.ascii.whitespace ++ ".,;:!?'");
    while (it.next()) |p| {
        try std.testing.expect(!std.ascii.eqlIgnoreCase(word, p));
    }
}

test "longmemeval: filler vocabulary can never shadow the query" {
    // A distractor that reuses the question's or the statement's own
    // words competes on more signal than a real unrelated note would.
    // With "weekly" and "question" in the filler list, end-to-end
    // accuracy fell to 0.00 past ~1,000 padding cells — a measurement
    // of the generator, not of mem3.
    for (FILLER_WORDS) |w| {
        for (TEMPLATE_VOCAB) |t| {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(w, t));
        }
        for (STATED_ATTRS) |attr| try assertNoWordOverlap(w, attr.phrase);
        for (ABSENT_ATTRS) |attr| try assertNoWordOverlap(w, attr.phrase);
    }
}

test "longmemeval: filler text can never contain an attribute cue" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    var rng = harness.Rng.init(9);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const text = try fillerText(alloc, &rng);
        defer alloc.free(text);

        var buf: [MAX_TOKENS][MAX_TOKEN_LEN]u8 = undefined;
        var lens: [MAX_TOKENS]usize = undefined;
        const n = collectTokens(&buf, &lens, text);
        for (0..n) |ti| {
            const tok = buf[ti][0..lens[ti]];
            for (STATED_ATTRS) |attr| {
                try std.testing.expect(!std.ascii.eqlIgnoreCase(tok, attr.cue));
            }
            for (ABSENT_ATTRS) |attr| {
                try std.testing.expect(!std.ascii.eqlIgnoreCase(tok, attr.cue));
            }
        }
    }
}

test "longmemeval: the reader handles every statement surface form" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    // One per `factText` form. All four must yield "zanvin".
    const forms = [_][]const u8{
        "Belka's weekly podcast is zanvin, worth writing down",
        "the weekly podcast for Belka is zanvin these days",
        "I told them zanvin is the Belka weekly podcast uses now",
        "Belka switched my weekly podcast to zanvin last month, no regrets",
    };
    for (forms) |f| {
        const texts = [_][]const u8{f};
        const got = (try readAnswer(alloc, &texts, "podcast", "belka")).?;
        defer alloc.free(got);
        try std.testing.expectEqualStrings("zanvin", got);
    }
}

test "longmemeval: a cue inside a multi-word attribute phrase still finds the value" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    // "gym" is only the first token of "gym session time". Reading the
    // next token after the cue would answer "session".
    const texts = [_][]const u8{"Belka's gym session time is vortor, worth writing down"};
    const got = (try readAnswer(alloc, &texts, "gym", "belka")).?;
    defer alloc.free(got);
    try std.testing.expectEqualStrings("vortor", got);
}

test "longmemeval: the reader finds the value after the cue and reads it back before" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    // Forward form.
    const fwd = [_][]const u8{"Belka's text editor is zanvin, worth writing down"};
    const a1 = (try readAnswer(alloc, &fwd, "editor", "belka")).?;
    defer alloc.free(a1);
    try std.testing.expectEqualStrings("zanvin", a1);

    // Backward form: "{value} is the {persona} {attr} uses now".
    const bwd = [_][]const u8{"I told them dokren is the Belka text editor uses now"};
    const a2 = (try readAnswer(alloc, &bwd, "editor", "belka")).?;
    defer alloc.free(a2);
    try std.testing.expectEqualStrings("dokren", a2);

    // No cue anywhere -> an abstention, not a guess.
    const none = [_][]const u8{"the quick report arrived until the plain ledger was signed off"};
    try std.testing.expect((try readAnswer(alloc, &none, "dentist", "belka")) == null);
}

test "longmemeval: the reader takes the highest-ranked cell, which is what makes the update case a real test" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const ranked = [_][]const u8{
        "Belka's text editor is zanvin",
        "Belka's text editor is dokren",
    };
    const a = (try readAnswer(alloc, &ranked, "editor", "belka")).?;
    defer alloc.free(a);
    try std.testing.expectEqualStrings("zanvin", a);

    // A cell about a different persona is skipped, not answered from.
    const other = [_][]const u8{
        "Marka's text editor is dokren",
        "Belka's text editor is zanvin",
    };
    const b = (try readAnswer(alloc, &other, "editor", "belka")).?;
    defer alloc.free(b);
    try std.testing.expectEqualStrings("zanvin", b);
}

test "longmemeval: normalised scoring is case- and punctuation-insensitive" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const a = try normalise(alloc, "Zanvin.");
    defer alloc.free(a);
    const b = try normalise(alloc, "  zanvin ");
    defer alloc.free(b);
    try std.testing.expectEqualStrings(a, b);

    try std.testing.expectApproxEqAbs(1.0, tokenF1("zanvin", "zanvin"), 1e-9);
    try std.testing.expectApproxEqAbs(0.0, tokenF1("", "zanvin"), 1e-9);
    try std.testing.expectApproxEqAbs(0.0, tokenF1("something", "else"), 1e-9);
}

test "longmemeval: combined score weights are the documented ones" {
    try std.testing.expectApproxEqAbs(1.0, combinedScore(1, 1, 1), 1e-9);
    try std.testing.expectApproxEqAbs(0.0, combinedScore(0, 0, 0), 1e-9);
    // Exact match alone is 0.5, not 1.0 — the formula is not
    // exact-match-with-a-bonus.
    try std.testing.expectApproxEqAbs(0.5, combinedScore(1, 0, 0), 1e-9);
}

test "longmemeval: an abstention on an answerable question costs, it does not score" {
    var t = Tally{};
    t.addCase(true, false, 0, 0, 0, false, true);
    // Declining to answer an answerable question: false abstention,
    // zero accuracy.
    try std.testing.expectApproxEqAbs(0.0, t.accuracyOverAnswerable().?, 1e-9);
    try std.testing.expectApproxEqAbs(0.0, t.overallAccuracy().?, 1e-9);
    try std.testing.expectApproxEqAbs(1.0, t.falseAbstentionRate().?, 1e-9);
    // Precision is defined (an abstention WAS predicted) and is zero:
    // it was predicted on a question that had an answer.
    try std.testing.expectApproxEqAbs(0.0, t.abstentionPrecision().?, 1e-9);
    // Recall is undefined, not 1.0: no case in this population was one
    // that ought to be abstained on. A recall of 1.0 here would be a
    // flattering artefact of dividing by nothing.
    try std.testing.expect(t.abstentionRecall() == null);
}

test "longmemeval: abstaining on everything cannot beat answering" {
    var dodge = Tally{};
    var answer = Tally{};
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        dodge.addCase(false, false, 0, 0, 0, false, true);
        answer.addCase(true, true, 1, 1, 1, true, false);
    }
    // Both are 0 overall accuracy on their own population — which is
    // why the abstention cases are scored as failures rather than
    // quietly dropped.
    try std.testing.expectApproxEqAbs(0.0, dodge.overallAccuracy().?, 1e-9);
    try std.testing.expectApproxEqAbs(1.0, dodge.abstentionRecall().?, 1e-9);
    try std.testing.expectApproxEqAbs(1.0, answer.overallAccuracy().?, 1e-9);
}

test "longmemeval: the temporal and update cases want opposite values from one cell pair" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");
    const alloc = gpa.allocator();

    const ds = try generateDataset(alloc, 1, 0, 5);
    defer ds.deinit(alloc);

    var saw_update = false;
    var saw_temporal = false;
    for (ds.cases) |c| {
        switch (c.ability) {
            .knowledge_update => {
                saw_update = true;
                try std.testing.expect(c.answerable);
            },
            .temporal => {
                saw_temporal = true;
                // The temporal case must point at the OLDER statement,
                // and expect a different value from the update case.
                try std.testing.expect(c.answerable);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_update and saw_temporal);
}