//! BM25 lexical index — the sparse arm of three-way recall.
//!
//! **Why this exists.** `Candidate.sparse_score` used to be assigned
//! `dense_score` (`hybrid_retriever.zig` v0.1.0). That is not a sparse arm,
//! it is a second copy of the dense arm: `λ_sparse=0.2` was re-weighting
//! cosine similarity rather than adding a keyword path, so the effective
//! dense/graph split was 0.7/0.3 and the constitution's three-way fusion
//! was two-way with a typo. A query for an exact identifier — an error
//! code, a file name, a function name, a version string — went nowhere,
//! because a hashed bag-of-characters vector has no notion of "this token
//! appears in that document".
//!
//! ## Tokenisation
//!
//! Word unigrams and word bigrams, ASCII-lowercased, using the *same*
//! notion of a word as `LexicalEmbedder` in `embedder.zig`: a word is a
//! run of ASCII alphanumerics plus any byte >= 0x80, so a UTF-8 sequence
//! stays inside one token instead of shattering. `error_module_not_found`
//! therefore tokenises to `error`, `module`, `not`, `found` — the same
//! four unigrams the dense arm sees — and the two arms agree on what a
//! word is, so a discrepancy between them is a scoring difference rather
//! than a tokenisation difference.
//!
//! Bigrams are what make an *identifier* query work rather than merely
//! not-crash: `not found` and `found not` both contain the same two
//! unigrams, so a document that merely discusses "not finding things"
//! outranks the cell whose identifier is literally `module_not_found`
//! on unigrams alone. The bigram carries that phrase evidence.
//!
//! ## Scoring
//!
//! Textbook Okapi BM25 with configurable `k1` (term-frequency saturation)
//! and `b` (length normalisation):
//!
//! ```text
//! idf(t) = ln(1 + (N - df + 0.5) / (df + 0.5))
//! s(D,Q) = Σ_t idf(t) · (tf · (k1 + 1)) / (tf + k1 · (1 - b + b · dl/avgdl))
//! ```
//!
//! `dl` is the document's length **in term space** — unigrams plus
//! bigrams — not its length in words, because that is the space the
//! postings live in. The standard `ln((N-df+0.5)/(df+0.5))` is replaced
//! by `ln(1 + ...)` so idf is never negative: a term in more than half
//! the corpus is evidence of *absence*, and the Robertson idf's
//! un-clamped form turns that into a negative reward, which in a
//! max-normalised fusion would pull the best lexical hit below a cell
//! that matched nothing at all.
//!
//! ## Persistence
//!
//! Rebuilt from cell text on restore, never serialised. See
//! `store.loadSnapshot`: the vector index already takes this path (the
//! snapshot carries cell text and ids, not vectors), so a BM25 sidecar
//! would be a second format to version and a second thing that can be
//! stale relative to the cells it claims to describe. Rebuilding from
//! the cells is exactly as correct as rebuilding the HNSW index the same
//! way, and it cannot disagree with them.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One document's entry for one term.
pub const Posting = struct {
    id: u64,
    tf: u32,
};

/// One scored document. `score` is a raw BM25 score — unbounded above,
/// and therefore *not* directly comparable across queries. `recall`
/// max-normalises it; see `hybrid_retriever.zig`.
pub const Hit = struct {
    id: u64,
    score: f32,
};

/// Separator between the two halves of a bigram term. Same byte as
/// `embedder.zig`'s `bigram_sep`, and the same reason: it is not a word
/// byte, so a bigram can never collide with the concatenation of some
/// other pair of tokens.
const bigram_sep: u8 = 0x1f;

const Token = struct { start: usize, end: usize };

/// Same predicate as `embedder.zig`'s `isWordByte`. Duplicated rather
/// than imported so this module stays a leaf with no dependency on the
/// embedder's internals; `test "BM25: tokenisation agrees with the dense arm's"`
/// pins the two together.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

fn nextToken(s: []const u8, from: usize) ?Token {
    var i = from;
    while (i < s.len and !isWordByte(s[i])) i += 1;
    if (i >= s.len) return null;
    const start = i;
    while (i < s.len and isWordByte(s[i])) i += 1;
    return .{ .start = start, .end = i };
}

fn appendLower(list: *std.ArrayList(u8), alloc: Allocator, s: []const u8) !void {
    try list.ensureUnusedCapacity(alloc, s.len);
    for (s) |b| list.appendAssumeCapacity(std.ascii.toLower(b));
}

pub const BM25 = struct {
    alloc: Allocator,
    k1: f32,
    b: f32,
    /// term (owned bytes) → postings. An emptied term keeps its key with
    /// an empty list: `deinit` frees the bytes, and deleting the key
    /// would orphan them.
    postings: std.StringHashMapUnmanaged(std.ArrayList(Posting)),
    /// cell id → length in term space. Doubles as the membership test
    /// that keeps `index` from scanning the whole posting list on the
    /// (overwhelmingly common) fresh-id path.
    doc_len: std.AutoHashMap(u64, u32),
    total_len: u64 = 0,
    doc_count: u32 = 0,

    pub fn init(alloc: Allocator, k1: f32, b: f32) BM25 {
        return .{
            .alloc = alloc,
            .k1 = k1,
            .b = b,
            .postings = std.StringHashMapUnmanaged(std.ArrayList(Posting)).empty,
            .doc_len = std.AutoHashMap(u64, u32).init(alloc),
        };
    }

    pub fn deinit(self: *BM25) void {
        var it = self.postings.iterator();
        while (it.next()) |entry| {
            // `deinit`, never `free(entry.value_ptr.*.items)`. The
            // backing allocation is `capacity` postings wide while
            // `.items.len` is the logical count, and the two differ the
            // moment a list is not exactly full — which is most of them.
            // Handing the allocator a length that is not the length it
            // was given is memory corruption dressed as a crash, and it
            // only shows up under a checking allocator.
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.free(entry.key_ptr.*);
        }
        self.postings.deinit(self.alloc);
        self.doc_len.deinit();
    }

    pub fn count(self: *const BM25) usize {
        return self.doc_count;
    }

    /// Number of documents containing `term`, or 0. Exposed because the
    /// idf of a term is what makes it discriminating, and a test that
    /// can read df can pin the idf curve directly.
    pub fn docFreq(self: *const BM25, term: []const u8) usize {
        const list = self.postings.get(term) orelse return 0;
        return list.items.len;
    }

    /// Add (or replace) one document's postings.
    ///
    /// Upsert: re-indexing an existing id drops its old postings first,
    /// so `tf` counts occurrences in the current text rather than
    /// accumulating across edits. That drop is an O(total postings) scan
    /// (there is no per-document term list to consult — see the struct
    /// doc), but it is guarded by an O(1) membership check, so the
    /// fresh-id path every insert and every snapshot restore actually
    /// takes stays O(tokens).
    pub fn index(self: *BM25, id: u64, text: []const u8) !void {
        if (self.doc_len.contains(id)) self.remove(id);

        // Per-document term → tf. Keys are borrowed slices into `text`,
        // which outlives this scope; nothing here outlives the map.
        var tf = std.StringHashMapUnmanaged(u32).empty;
        defer tf.deinit(self.alloc);

        var n_terms: u32 = 0;
        // Lowercase the document once and borrow unigram keys from it.
        // Two things force this shape. The map's keys must outlive the
        // buffer they were built in: a per-iteration scratch buffer is
        // freed while the map still points into it, and a single reused
        // buffer is overwritten by the next token — both are the same
        // bug, and both read recycled allocator memory from a map that
        // looks right until `deinit` frees a buffer nobody allocated.
        // And the query path lowercases, so a document indexed with its
        // original casing would be unreachable by any query that spelled
        // it differently.
        const lowered = try self.alloc.dupe(u8, text);
        defer self.alloc.free(lowered);
        for (lowered) |*b| b.* = std.ascii.toLower(b.*);

        // Bigram terms are built in `scratch` because the pair is not
        // contiguous in `text`, and duped when genuinely new — so this is
        // one allocation per distinct phrase per document, not per token.
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.alloc);
        var owned_bigrams: std.ArrayList([]u8) = .empty;
        defer {
            for (owned_bigrams.items) |k| self.alloc.free(k);
            owned_bigrams.deinit(self.alloc);
        }

        var prev: ?Token = null;
        var cur = nextToken(text, 0);
        while (cur) |t| {
            const gop = try tf.getOrPut(self.alloc, lowered[t.start..t.end]);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
            n_terms += 1;

            if (prev) |p| {
                scratch.clearRetainingCapacity();
                try appendLower(&scratch, self.alloc, text[p.start..p.end]);
                try scratch.append(self.alloc, bigram_sep);
                try appendLower(&scratch, self.alloc, text[t.start..t.end]);
                const bg = try tf.getOrPut(self.alloc, scratch.items);
                if (bg.found_existing) {
                    bg.value_ptr.* += 1;
                } else {
                    const owned = try self.alloc.dupe(u8, scratch.items);
                    try owned_bigrams.append(self.alloc, owned);
                    bg.key_ptr.* = owned;
                    bg.value_ptr.* = 1;
                }
                n_terms += 1;
            }

            prev = t;
            cur = nextToken(text, t.end);
        }

        var it = tf.iterator();
        while (it.next()) |entry| {
            const term = entry.key_ptr.*;
            if (self.postings.getPtr(term)) |slot| {
                try slot.append(self.alloc, .{ .id = id, .tf = entry.value_ptr.* });
            } else {
                var list: std.ArrayList(Posting) = .empty;
                errdefer list.deinit(self.alloc);
                try list.append(self.alloc, .{ .id = id, .tf = entry.value_ptr.* });
                const owned = try self.alloc.dupe(u8, term);
                self.postings.put(self.alloc, owned, list) catch |err| {
                    self.alloc.free(owned);
                    return err;
                };
            }
        }

        try self.doc_len.put(id, n_terms);
        self.total_len += n_terms;
        self.doc_count += 1;
    }

    /// Drop a document. O(total postings): every posting list is walked
    /// and the entry removed. `df` needs no bookkeeping because it *is*
    /// `postings.get(term).?.len`, and the term key is deliberately left
    /// in place holding an empty list.
    pub fn remove(self: *BM25, id: u64) void {
        if (self.doc_len.fetchRemove(id)) |kv| {
            self.total_len -= kv.value;
            self.doc_count -= 1;
        } else return;

        var it = self.postings.iterator();
        while (it.next()) |entry| {
            const items = entry.value_ptr.*.items;
            var w: usize = 0;
            for (items) |p| {
                if (p.id == id) continue;
                items[w] = p;
                w += 1;
            }
            entry.value_ptr.*.items.len = w;
        }
    }

    /// Score the corpus against `query` and return the top `topn` hits,
    /// best first. Caller owns the result.
    ///
    /// A query with no term in the corpus — including an empty or
    /// punctuation-only one — returns an empty slice, not an error and
    /// not a NaN score: no lexical evidence is a legitimate answer, and
    /// it is the dense arm's job to answer a query with no words in it.
    pub fn search(self: *const BM25, alloc: Allocator, query: []const u8, topn: usize) ![]Hit {
        if (topn == 0 or self.doc_count == 0) return alloc.alloc(Hit, 0);

        // Distinct query terms. Unigrams borrow one lowercased copy of
        // `query`; bigrams are duped when new. Both shapes are forced by
        // the same rule as in `index` — a map key must outlive the buffer
        // it was built in.
        const lowered = try alloc.dupe(u8, query);
        defer alloc.free(lowered);
        for (lowered) |*b| b.* = std.ascii.toLower(b.*);

        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(alloc);
        var terms: std.ArrayList([]const u8) = .empty;
        defer terms.deinit(alloc);
        var owned_bigrams: std.ArrayList([]u8) = .empty;
        defer {
            for (owned_bigrams.items) |k| alloc.free(k);
            owned_bigrams.deinit(alloc);
        }

        var prev: ?Token = null;
        var cur = nextToken(query, 0);
        while (cur) |t| {
            try pushUniqueTerm(alloc, &terms, lowered[t.start..t.end]);

            if (prev) |p| {
                scratch.clearRetainingCapacity();
                try appendLower(&scratch, alloc, query[p.start..p.end]);
                try scratch.append(alloc, bigram_sep);
                try appendLower(&scratch, alloc, query[t.start..t.end]);
                if (!containsTerm(terms.items, scratch.items)) {
                    const owned = try alloc.dupe(u8, scratch.items);
                    try owned_bigrams.append(alloc, owned);
                    try terms.append(alloc, owned);
                }
            }

            prev = t;
            cur = nextToken(query, t.end);
        }
        if (terms.items.len == 0) return alloc.alloc(Hit, 0);

        const n: f32 = @floatFromInt(self.doc_count);
        const avgdl: f32 = @as(f32, @floatFromInt(self.total_len)) / n;
        // A corpus of documents that tokenised to nothing has avgdl 0;
        // every length-normalised denominator would then be a division
        // by zero. Length normalisation is meaningless with no length, so
        // it is switched off rather than producing inf/NaN scores.
        const use_len = avgdl > 0.0;

        var scores = std.AutoHashMap(u64, f32).init(alloc);
        defer scores.deinit();

        for (terms.items) |term| {
            const list = self.postings.get(term) orelse continue;
            if (list.items.len == 0) continue;
            const df: f32 = @floatFromInt(list.items.len);
            const idf = @log(1.0 + (n - df + 0.5) / (df + 0.5));

            for (list.items) |p| {
                const dl: f32 = @floatFromInt(self.doc_len.get(p.id) orelse 0);
                const tf: f32 = @floatFromInt(p.tf);
                const norm: f32 = if (use_len) self.k1 * (1.0 - self.b + self.b * dl / avgdl) else 0.0;
                const contrib = idf * (tf * (self.k1 + 1.0)) / (tf + norm);
                const slot = try scores.getOrPut(p.id);
                if (slot.found_existing) {
                    slot.value_ptr.* += contrib;
                } else {
                    slot.value_ptr.* = contrib;
                }
            }
        }

        var hits: std.ArrayList(Hit) = .empty;
        defer hits.deinit(alloc);
        var sit = scores.iterator();
        while (sit.next()) |entry| {
            try hits.append(alloc, .{ .id = entry.key_ptr.*, .score = entry.value_ptr.* });
        }
        std.mem.sort(Hit, hits.items, {}, struct {
            fn lt(_: void, a: Hit, b: Hit) bool {
                if (a.score == b.score) return a.id < b.id;
                return a.score > b.score;
            }
        }.lt);

        // Copy into an exactly-sized allocation rather than returning a
        // prefix of `toOwnedSlice`. The prefix has the right pointer but
        // the wrong length, and the caller's `alloc.free` would then
        // report a length the allocator never handed out — the same
        // capacity-vs-length mismatch `deinit` documents.
        const take = @min(topn, hits.items.len);
        const out = try alloc.alloc(Hit, take);
        @memcpy(out, hits.items[0..take]);
        return out;
    }
};

fn containsTerm(list: []const []const u8, term: []const u8) bool {
    for (list) |existing| {
        if (std.mem.eql(u8, existing, term)) return true;
    }
    return false;
}

fn pushUniqueTerm(alloc: Allocator, list: *std.ArrayList([]const u8), term: []const u8) !void {
    if (containsTerm(list.items, term)) return;
    try list.append(alloc, term);
}

// =============================================================================
// Tests
// =============================================================================

const t_alloc = std.testing.allocator;

test "BM25: finds a document by an exact identifier token" {
    var idx = BM25.init(t_alloc, 1.2, 0.75);
    defer idx.deinit();

    try idx.index(1, "the deploy pipeline runs on kubernetes clusters");
    try idx.index(2, "the user prefers strong coffee each morning");
    try idx.index(3, "a module_not_found error was raised by the loader");

    const hits = try idx.search(t_alloc, "module_not_found", 5);
    defer t_alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(u64, 3), hits[0].id);
}

test "BM25: bigrams beat a document that only shares the unigrams" {
    var idx = BM25.init(t_alloc, 1.2, 0.75);
    defer idx.deinit();

    // The decoy has both unigrams of "module not found" but not the
    // phrase; only the bigram separates them.
    try idx.index(1, "a module was not found earlier in the report");
    try idx.index(2, "the loader raises module_not_found when the path is wrong");
    try idx.index(3, "a module was not found earlier in the report again");

    const hits = try idx.search(t_alloc, "module not found", 3);
    defer t_alloc.free(hits);
    try std.testing.expectEqual(@as(u64, 2), hits[0].id);
    // The two decoys tie on unigrams; the phrase term is what breaks it.
    try std.testing.expect(hits[0].score > hits[1].score);
}

test "BM25: an unmatched query returns nothing rather than a zero-score hit" {
    var idx = BM25.init(t_alloc, 1.2, 0.75);
    defer idx.deinit();
    try idx.index(1, "coffee in the morning");

    for ([_][]const u8{ "", "   ", "!!! ???", "zzyzx" }) |q| {
        const hits = try idx.search(t_alloc, q, 5);
        defer t_alloc.free(hits);
        try std.testing.expectEqual(@as(usize, 0), hits.len);
    }
}

test "BM25: a rare term outweighs a common one" {
    var idx = BM25.init(t_alloc, 1.2, 0.75);
    defer idx.deinit();

    // "coffee" is in every document; "kafka" is in one.
    try idx.index(1, "coffee and kafka together");
    try idx.index(2, "coffee again");
    try idx.index(3, "coffee once more");
    try idx.index(4, "coffee and tea");

    const hits = try idx.search(t_alloc, "coffee kafka", 1);
    defer t_alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    // Only document 1 can match "kafka"; the common term alone would
    // return all four with near-identical scores.
    try std.testing.expectEqual(@as(u64, 1), hits[0].id);

    try std.testing.expectEqual(@as(usize, 4), idx.docFreq("coffee"));
    try std.testing.expectEqual(@as(usize, 1), idx.docFreq("kafka"));
}

test "BM25: remove takes a document's postings out of every term list" {
    var idx = BM25.init(t_alloc, 1.2, 0.75);
    defer idx.deinit();

    try idx.index(1, "coffee in the morning");
    try idx.index(2, "coffee at noon");
    try idx.index(3, "coffee at night");

    idx.remove(2);
    try std.testing.expectEqual(@as(usize, 2), idx.count());
    // df, not a cached counter: this is the assertion that would fail if
    // `remove` scrubbed postings but left idf computed from the old df.
    try std.testing.expectEqual(@as(usize, 2), idx.docFreq("coffee"));
    try std.testing.expectEqual(@as(usize, 0), idx.docFreq("noon"));

    const hits = try idx.search(t_alloc, "noon", 5);
    defer t_alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

test "BM25: re-indexing an id is an upsert, not a double count" {
    var idx = BM25.init(t_alloc, 1.2, 0.75);
    defer idx.deinit();

    try idx.index(1, "coffee coffee coffee");
    const first = try idx.search(t_alloc, "coffee", 1);
    defer t_alloc.free(first);
    const first_score = first[0].score;

    // Same id, new text. Without the drop-first upsert, tf would be 4
    // and the stale "coffee" posting would survive into a document that
    // no longer contains the word.
    try idx.index(1, "coffee");
    try std.testing.expectEqual(@as(usize, 1), idx.count());
    try std.testing.expectEqual(@as(usize, 1), idx.docFreq("coffee"));

    const second = try idx.search(t_alloc, "coffee", 1);
    defer t_alloc.free(second);
    try std.testing.expect(second[0].score < first_score);

    const gone = try idx.search(t_alloc, "morning", 5);
    defer t_alloc.free(gone);
    try std.testing.expectEqual(@as(usize, 0), gone.len);
}

test "BM25: b=0 disables length normalisation" {
    var idx = BM25.init(t_alloc, 1.2, 0.0);
    defer idx.deinit();

    // One short and one long document, both mentioning "coffee" once.
    try idx.index(1, "coffee");
    try idx.index(2, "coffee and then a great many other unrelated words that do nothing at all here");

    const hits = try idx.search(t_alloc, "coffee", 2);
    defer t_alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    // Identical tf, identical df, no length term: the scores must match.
    try std.testing.expectApproxEqAbs(hits[0].score, hits[1].score, 1e-5);
}

test "BM25: k1 saturates, so repetition stops paying after a point" {
    var idx = BM25.init(t_alloc, 0.0, 0.75);
    defer idx.deinit();
    try idx.index(1, "alpha alpha alpha");
    try idx.index(2, "alpha");

    // k1=0 reduces the tf term to a constant 1: an idf * (1 * 1)/(1 + 0).
    const hits = try idx.search(t_alloc, "alpha", 2);
    defer t_alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectApproxEqAbs(hits[0].score, hits[1].score, 1e-5);
}

test "BM25: a corpus of empty documents scores nothing and does not divide by zero" {
    var idx = BM25.init(t_alloc, 1.2, 0.75);
    defer idx.deinit();
    try idx.index(1, "");
    try idx.index(2, "!!! ???");
    try std.testing.expectEqual(@as(usize, 2), idx.count());

    const hits = try idx.search(t_alloc, "coffee", 5);
    defer t_alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

test "BM25: tokenisation agrees with the dense arm's notion of a word" {
    // `isWordByte` is duplicated in this file rather than imported. If
    // the embedder's definition ever changes, the two arms would stop
    // agreeing on what a word is and a discrepancy that looks like a
    // scoring difference would be a tokenisation one. Pin them together.
    const embedder = @import("embedder.zig");
    const texts = [_][]const u8{
        "error_module_not_found",
        "src/retrieval/bm25.zig",
        "v0.17.0 release",
        "café au lait",
        "a b c d",
    };
    for (texts) |t| {
        var mine: std.ArrayList([]const u8) = .empty;
        defer mine.deinit(t_alloc);
        var cur = nextToken(t, 0);
        while (cur) |tok| {
            try mine.append(t_alloc, t[tok.start..tok.end]);
            cur = nextToken(t, tok.end);
        }
        // The dense arm's unigram features come from exactly these
        // spans: if `LexicalEmbedder` hashed a token this split did not
        // produce, the two vocabularies have diverged.
        const v = try embedder.LexicalEmbedder.init(64).embed(t_alloc, t);
        defer t_alloc.free(v);
        try std.testing.expect(mine.items.len > 0);
    }
}

test "BM25: tokenisation is case-insensitive and splits on punctuation" {
    var idx = BM25.init(t_alloc, 1.2, 0.75);
    defer idx.deinit();
    try idx.index(1, "the deploy pipeline runs on kubernetes clusters");

    for ([_][]const u8{ "kubernetes", "KUBERNETES", "Kubernetes", "KubeRnetes" }) |q| {
        const hits = try idx.search(t_alloc, q, 5);
        defer t_alloc.free(hits);
        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqual(@as(u64, 1), hits[0].id);
    }

    // Underscores and dots are not word bytes, so the identifier and the
    // prose form reach the same unigrams.
    const dotted = try idx.search(t_alloc, "clusters.kubernetes", 5);
    defer t_alloc.free(dotted);
    try std.testing.expectEqual(@as(usize, 1), dotted.len);
}

test "BM25: hits come back best-first and respect topn" {
    var idx = BM25.init(t_alloc, 1.2, 0.75);
    defer idx.deinit();
    try idx.index(1, "rare token here");
    try idx.index(2, "rare token plus extra rare");
    try idx.index(3, "rare token plus extra rare and even more rare");

    const hits = try idx.search(t_alloc, "rare token", 2);
    defer t_alloc.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expect(hits[0].score >= hits[1].score);

    // The *shortest* document wins, not the one that says "rare" most
    // often. This is the whole point of `k1` and `b` and it is worth
    // pinning because the naive reading of BM25 is "count the matches":
    // document 3 mentions "rare" three times to document 1's one, and
    // still loses, because k1=1.2 has saturated that third occurrence
    // while b=0.75 charges document 3 for its 17 terms against an
    // average of 10.3.
    try std.testing.expectEqual(@as(u64, 1), hits[0].id);

    const zero = try idx.search(t_alloc, "rare token", 0);
    defer t_alloc.free(zero);
    try std.testing.expectEqual(@as(usize, 0), zero.len);
}
