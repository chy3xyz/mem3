//! Embedders. Two implementations behind one shape:
//!
//!   * `StubEmbedder`    — legacy xxHash3 pseudo-random vectors (v0.1.0).
//!                        Deterministic but semantically blind: cosine
//!                        similarity between two related strings is noise.
//!   * `LexicalEmbedder` — a real lexical embedder. Hashed bag-of-features
//!                        over word unigrams, word bigrams and character
//!                        3-grams, with sublinear tf weighting, signed
//!                        hashing, and L2 normalisation. Dot product ==
//!                        cosine similarity of lexical feature overlap,
//!                        so HNSW retrieval ranks by actual relevance.
//!
//! `LexicalEmbedder` is pure Zig (Constitution IV: no external deps), uses no
//! heap allocation beyond the returned vector, and is deterministic.
//!
//! Both are reachable through the `Embedder` union, selected by
//! `Config.EmbedderKind`. That union is the seam for a future real embedding
//! model: add a variant, add an arm to `Embedder.init`, and no call site
//! changes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const hashing = @import("../utils/hashing.zig");
const config = @import("../core/config.zig");

// =============================================================================
// StubEmbedder (legacy — kept working; other modules and tests depend on it)
// =============================================================================

pub const StubEmbedder = struct {
    dim: u16,

    pub fn init(dim: u16) StubEmbedder {
        return .{ .dim = dim };
    }

    /// Embed a single string. Returns an owned slice.
    pub fn embed(self: *const StubEmbedder, alloc: Allocator, s: []const u8) ![]f32 {
        const out = try alloc.alloc(f32, self.dim);
        // Fill with pseudo-random values derived from a chained hash of the input.
        var seed = hashing.stableHash(s);
        for (out) |*v| {
            // xorshift64 → f32 in [-1, 1]
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            const normalized: f32 = @as(f32, @floatFromInt(seed % 10000)) / 10000.0;
            v.* = normalized * 2.0 - 1.0;
        }
        // L2 normalize so cosine sim = dot product.
        var norm: f32 = 0.0;
        for (out) |v| norm += v * v;
        const n = @sqrt(norm);
        if (n > 0.0) {
            for (out) |*v| v.* /= n;
        }
        return out;
    }

    /// Batch embedding for corpus construction.
    pub fn embedBatch(
        self: *const StubEmbedder,
        alloc: Allocator,
        inputs: []const []const u8,
    ) ![][]f32 {
        const out = try alloc.alloc([]f32, inputs.len);
        for (inputs, 0..) |s, i| {
            out[i] = try self.embed(alloc, s);
        }
        return out;
    }
};

// =============================================================================
// LexicalEmbedder
// =============================================================================

/// Byte separating the two halves of a bigram feature. Not a word byte, so a
/// bigram can never collide with the concatenation of a shorter token pair.
const bigram_sep: u8 = 0x1f;

/// Feature kinds. Mixed into the hash so "zig" as a unigram, as a bigram
/// half and as a char 3-gram land in independent buckets.
const kind_unigram: u64 = 1;
const kind_bigram: u64 = 2;
const kind_char3: u64 = 3;

/// Base weights per feature kind. Word-level evidence is weighted above
/// character-level evidence: char n-grams exist to soften typos and
/// morphology, not to dominate.
const w_unigram: f32 = 1.0;
const w_bigram: f32 = 0.7;
const w_char3: f32 = 1.0;

/// Open-addressed term table. Lives on the stack, so `embed` allocates
/// nothing but the output vector. 512 distinct features covers the memory
/// cells this system stores; past that, new terms are dropped deterministically
/// (same input → same drops → same vector).
const max_terms = 512;

const TermEntry = struct {
    key: u64 = 0,
    tf: u32 = 0,
    base_w: f32 = 0.0,
};

const TermTable = struct {
    slots: [max_terms]TermEntry = @splat(TermEntry{}),
    used: usize = 0,

    /// Record one occurrence of `key`. Hash collisions inside the table are
    /// resolved by linear probing; two different terms sharing a slot still
    /// get distinct hashes downstream, so this only affects tf bookkeeping.
    fn add(self: *TermTable, key: u64, base_w: f32) void {
        if (self.used >= max_terms) {
            std.log.debug("LexicalEmbedder: term table full, dropping terms", .{});
            return;
        }
        var idx: usize = @intCast(key % max_terms);
        var probes: usize = 0;
        while (probes < max_terms) : (probes += 1) {
            const e = &self.slots[idx];
            if (e.tf == 0) {
                e.* = .{ .key = key, .tf = 1, .base_w = base_w };
                self.used += 1;
                return;
            }
            if (e.key == key) {
                e.tf += 1;
                return;
            }
            idx = (idx + 1) % max_terms;
        }
    }
};

/// Streaming ASCII-lowercasing hasher. Lets us hash a feature without
/// materialising a normalised copy of it, so arbitrarily long tokens are
/// handled without a scratch buffer.
const LowerHasher = struct {
    h: std.hash.XxHash3,

    fn init(kind: u64) LowerHasher {
        return .{ .h = std.hash.XxHash3.init(hashing.stableHash(&std.mem.toBytes(kind))) };
    }

    fn feed(self: *LowerHasher, s: []const u8) void {
        var chunk: [64]u8 = undefined;
        var i: usize = 0;
        while (i < s.len) {
            const n = @min(chunk.len, s.len - i);
            for (0..n) |k| chunk[k] = std.ascii.toLower(s[i + k]);
            self.h.update(chunk[0..n]);
            i += n;
        }
    }

    fn final(self: *LowerHasher) u64 {
        return self.h.final();
    }
};

const Token = struct { start: usize, end: usize };

/// Word bytes are ASCII alphanumerics plus any byte >= 0x80, so UTF-8
/// sequences stay inside a token instead of shattering into noise.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Next whitespace/punctuation-delimited token at or after `from`.
fn nextToken(s: []const u8, from: usize) ?Token {
    var i = from;
    while (i < s.len and !isWordByte(s[i])) i += 1;
    if (i >= s.len) return null;
    const start = i;
    while (i < s.len and isWordByte(s[i])) i += 1;
    return .{ .start = start, .end = i };
}

pub const LexicalEmbedder = struct {
    dim: u16,

    pub fn init(dim: u16) LexicalEmbedder {
        std.debug.assert(dim > 0);
        return .{ .dim = dim };
    }

    /// Embed a single string. Returns an owned, L2-normalised slice of length
    /// `dim`. Empty or punctuation-only input yields the all-zero vector
    /// rather than a NaN or a crash.
    pub fn embed(self: *const LexicalEmbedder, alloc: Allocator, s: []const u8) ![]f32 {
        const out = try alloc.alloc(f32, self.dim);
        errdefer alloc.free(out);
        @memset(out, 0.0);

        var table = TermTable{};

        // Pass 1 — extract features and count their frequencies.
        var prev: ?Token = null;
        var cur = nextToken(s, 0);
        while (cur) |t| {
            const tok = s[t.start..t.end];

            var unigram = LowerHasher.init(kind_unigram);
            unigram.feed(tok);
            table.add(unigram.final(), w_unigram);

            if (prev) |p| {
                var bigram = LowerHasher.init(kind_bigram);
                bigram.feed(s[p.start..p.end]);
                bigram.feed(&[_]u8{bigram_sep});
                bigram.feed(tok);
                table.add(bigram.final(), w_bigram);
            }

            // Character 3-grams, normalised by sqrt(token length) so a long
            // token cannot contribute more total mass than a short one.
            const len = t.end - t.start;
            const gram_w = w_char3 / @sqrt(@as(f32, @floatFromInt(len)));
            if (len < 3) {
                var short = LowerHasher.init(kind_char3);
                short.feed(tok);
                table.add(short.final(), gram_w);
            } else {
                var k: usize = 0;
                while (k + 3 <= len) : (k += 1) {
                    var gram = LowerHasher.init(kind_char3);
                    gram.feed(tok[k .. k + 3]);
                    table.add(gram.final(), gram_w);
                }
            }

            prev = t;
            cur = nextToken(s, t.end);
        }

        // Pass 2 — signed-hashed, sublinearly weighted accumulation.
        // Signed hashing is what keeps inner products unbiased: every feature
        // lands in a random bucket with a random ±1 sign, so unrelated texts
        // cancel toward 0 instead of piling up positive bias from shared
        // buckets alone.
        for (table.slots) |e| {
            if (e.tf == 0) continue;
            const tf: f32 = @floatFromInt(e.tf);
            const weight = e.base_w * (1.0 + @log(tf));
            const sign: f32 = if ((e.key & 1) == 1) -1.0 else 1.0;
            const bucket: usize = @as(usize, @truncate(e.key >> 1)) % @as(usize, self.dim);
            out[bucket] += sign * weight;
        }

        // L2 normalise: dot product == cosine similarity, which is the
        // invariant HNSW.cosineSim and the existing tests rely on.
        var norm: f32 = 0.0;
        for (out) |v| norm += v * v;
        if (norm > 0.0) {
            const inv = 1.0 / @sqrt(norm);
            for (out) |*v| v.* *= inv;
        }
        return out;
    }

    pub fn embedBatch(
        self: *const LexicalEmbedder,
        alloc: Allocator,
        inputs: []const []const u8,
    ) ![][]f32 {
        const out = try alloc.alloc([]f32, inputs.len);
        for (inputs, 0..) |s, i| {
            out[i] = self.embed(alloc, s) catch |err| {
                var j = i;
                while (j > 0) : (j -= 1) alloc.free(out[j - 1]);
                alloc.free(out);
                return err;
            };
        }
        return out;
    }
};

// =============================================================================
// Embedder — the common seam
// =============================================================================

/// One embedder shape. Call sites hold an `Embedder` and do not care which
/// variant backs it, so a real embedding model can replace `lexical_hash`
/// later without touching them.
pub const Embedder = union(enum) {
    stub_xxhash: StubEmbedder,
    lexical_hash: LexicalEmbedder,

    /// `EmbedderKind.onnx_external` is reserved for a v0.2.0 model load
    /// and has no implementation. It used to `@panic` from `init`, which
    /// is a crash: the variant is reachable from a deserialised config
    /// (`Config.embedder_kind`), so any future config loader would take
    /// the whole daemon down on a value that is documented as legal.
    /// The constitution's API Surface Standards say no panics in
    /// libraries, so this is a typed error the caller decides what to
    /// do with.
    pub const InitError = error{UnsupportedEmbedder};

    pub fn init(kind: config.Config.EmbedderKind, dim: u16) InitError!Embedder {
        return switch (kind) {
            .stub_xxhash => .{ .stub_xxhash = StubEmbedder.init(dim) },
            .lexical_hash => .{ .lexical_hash = LexicalEmbedder.init(dim) },
            .onnx_external => error.UnsupportedEmbedder,
        };
    }

    pub fn fromConfig(cfg: config.Config) InitError!Embedder {
        return init(cfg.embedder_kind, cfg.embedder_dim);
    }

    pub fn embed(self: *const Embedder, alloc: Allocator, s: []const u8) ![]f32 {
        return switch (self.*) {
            inline else => |e| e.embed(alloc, s),
        };
    }

    pub fn embedBatch(
        self: *const Embedder,
        alloc: Allocator,
        inputs: []const []const u8,
    ) ![][]f32 {
        return switch (self.*) {
            inline else => |e| e.embedBatch(alloc, inputs),
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "StubEmbedder: deterministic" {
    const alloc = std.testing.allocator;
    const emb = StubEmbedder.init(8);

    const v1 = try emb.embed(alloc, "hello");
    defer alloc.free(v1);
    const v2 = try emb.embed(alloc, "hello");
    defer alloc.free(v2);
    try std.testing.expectEqualSlices(f32, v1, v2);

    const v3 = try emb.embed(alloc, "world");
    defer alloc.free(v3);
    try std.testing.expect(!std.mem.eql(f32, v1, v3));
}

test "StubEmbedder: unit norm" {
    const alloc = std.testing.allocator;
    const emb = StubEmbedder.init(64);
    const v = try emb.embed(alloc, "test");
    defer alloc.free(v);
    var norm: f32 = 0.0;
    for (v) |x| norm += x * x;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), @sqrt(norm), 1e-5);
}

fn cosOf(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0.0;
    for (a, 0..) |x, i| dot += x * b[i];
    return dot; // both sides are already unit norm
}

fn cosOfText(alloc: Allocator, e: *const LexicalEmbedder, a: []const u8, b: []const u8) !f32 {
    const va = try e.embed(alloc, a);
    defer alloc.free(va);
    const vb = try e.embed(alloc, b);
    defer alloc.free(vb);
    return cosOf(va, vb);
}

// The headline property: retrieval now means something. This is the test the
// old hash-based stub cannot pass — it fails on the `> 0.5` expectation.
test "LexicalEmbedder: overlapping vocabulary ranks far above unrelated" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const related = try cosOfText(alloc, &e, "the user prefers zig", "the user really prefers zig");
    const unrelated = try cosOfText(
        alloc,
        &e,
        "the user prefers zig",
        "quarterly revenue forecast for the logistics division",
    );

    std.log.info("lexical: related={d:.4} unrelated={d:.4}", .{ related, unrelated });

    try std.testing.expect(related > 0.7);
    try std.testing.expect(unrelated < 0.2);
    try std.testing.expect(related > unrelated * 4.0);
}

test "LexicalEmbedder: deterministic" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const v1 = try e.embed(alloc, "the user prefers zig over rust");
    defer alloc.free(v1);
    const v2 = try e.embed(alloc, "the user prefers zig over rust");
    defer alloc.free(v2);
    try std.testing.expectEqualSlices(f32, v1, v2);

    // Case and separator differences must not change the vector.
    const v3 = try e.embed(alloc, "The  User, PREFERS zig over rust!");
    defer alloc.free(v3);
    try std.testing.expectEqualSlices(f32, v1, v3);
}

test "LexicalEmbedder: char n-grams give partial credit for morphology and typos" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const morph = try cosOfText(alloc, &e, "preference", "preferences");
    const typo = try cosOfText(alloc, &e, "embed", "embedded");
    const unrelated = try cosOfText(alloc, &e, "embed", "kubernetes ingress controller rollout");

    std.log.info("lexical: preference/preferences={d:.4} embed/embedded={d:.4} unrelated={d:.4}", .{
        morph, typo, unrelated,
    });

    // Morphological variants stay strongly related.
    try std.testing.expect(morph > 0.35);
    // Single words differ entirely — only the char 3-grams overlap, so this
    // is genuine partial credit, not exact-token matching.
    try std.testing.expect(typo > 0.2);
    try std.testing.expect(unrelated < 0.05);
    try std.testing.expect(typo > unrelated);
}

test "LexicalEmbedder: a typo still retrieves its source" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const clean = try cosOfText(alloc, &e, "configure the vector index", "configure teh vektor index");
    std.log.info("lexical: typo-tolerant cosine={d:.4}", .{clean});
    try std.testing.expect(clean > 0.4);
}

test "LexicalEmbedder: unit norm" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    // A pathologically repetitive input must still normalise cleanly.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(alloc);
    for (0..40) |_| try long.appendSlice(alloc, "the user prefers zig ");

    const inputs = [_][]const u8{ "hello", "the user prefers zig", long.items };
    for (inputs) |s| {
        const v = try e.embed(alloc, s);
        defer alloc.free(v);
        var norm: f32 = 0.0;
        for (v) |x| norm += x * x;
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), @sqrt(norm), 1e-5);
    }
}

test "LexicalEmbedder: empty and punctuation-only input is defined" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    for ([_][]const u8{ "", "   ", "--- ... !!! ???", "\n\t" }) |s| {
        const v = try e.embed(alloc, s);
        defer alloc.free(v);
        try std.testing.expectEqual(@as(usize, 384), v.len);
        for (v) |x| try std.testing.expectEqual(@as(f32, 0.0), x);
    }

    // Two empty inputs must still compare equal (0.0, not NaN).
    const a = try e.embed(alloc, "");
    defer alloc.free(a);
    const b = try e.embed(alloc, "...");
    defer alloc.free(b);
    try std.testing.expectEqual(@as(f32, 0.0), cosOf(a, b));
}

// Guards the sign trick: without random ±1 signs, shared buckets would add
// positive bias to every pair and unrelated text would look similar.
test "LexicalEmbedder: signed hashing keeps unrelated pairs centred on zero" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const corpus = [_][]const u8{
        "the user prefers zig over rust",
        "quarterly revenue forecast for logistics",
        "kubernetes ingress controller rollout failed",
        "she prefers tea in the afternoon",
        "vector index recall benchmark results",
        "the deployment was rolled back",
        "postgres vacuum blocked a long query",
        "notes on the alignment problem",
    };

    var sum: f64 = 0.0;
    var n: usize = 0;
    for (corpus, 0..) |a, i| {
        const va = try e.embed(alloc, a);
        defer alloc.free(va);
        for (corpus, 0..) |b, j| {
            if (i >= j) continue;
            const vb = try e.embed(alloc, b);
            defer alloc.free(vb);
            sum += @floatCast(cosOf(va, vb));
            n += 1;
        }
    }

    const mean: f32 = @floatCast(sum / @as(f64, @floatFromInt(n)));
    std.log.info("lexical: mean pairwise cosine over {d} pairs = {d:.4}", .{ n, mean });

    // A couple of corpus members genuinely overlap ("prefers", "rolled back"),
    // so the mean is allowed a little slack — but it must not be positive-biased.
    try std.testing.expect(mean < 0.15);
    try std.testing.expect(mean > -0.15);
}

test "LexicalEmbedder: repeated words do not dominate" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    // Sublinear tf keeps a repeated stop word from swamping the content
    // words. With linear tf, four copies of "the" would drag this vector
    // away from its own base text and toward a generic "the" direction.
    const a = try e.embed(alloc, "the the the the retrieval index is fast");
    defer alloc.free(a);
    const b = try e.embed(alloc, "the retrieval index is fast");
    defer alloc.free(b);
    const vs_unrelated = try cosOfText(
        alloc,
        &e,
        "the the the the retrieval index is fast",
        "quartz calcite feldspar mica",
    );
    const vs_base = cosOf(a, b);
    std.log.info("lexical: tf-damped vs base={d:.4} vs unrelated={d:.4}", .{ vs_base, vs_unrelated });

    // Still recognisably the same statement...
    try std.testing.expect(vs_base > 0.7);
    // ...and not dragged toward some unrelated stop-word-heavy text.
    try std.testing.expect(vs_unrelated < 0.2);
}

// End-to-end through the real index: this is the property the whole system
// exists for.
test "LexicalEmbedder + HNSW: relevant cell is retrieved first" {
    const alloc = std.testing.allocator;
    const e = LexicalEmbedder.init(384);

    const docs = [_]struct { id: u64, text: []const u8 }{
        .{ .id = 1, .text = "the user prefers zig for systems programming" },
        .{ .id = 2, .text = "quarterly revenue forecast for the logistics division" },
        .{ .id = 3, .text = "kubernetes ingress controller rollout failed overnight" },
        .{ .id = 4, .text = "postgres vacuum blocked a long running query" },
        .{ .id = 5, .text = "notes on the vecchio alignment problem" },
    };

    var hnsw = @import("hnsw.zig").HNSW.init(alloc, .{}, 384);
    defer hnsw.deinit();

    for (docs) |d| {
        const v = try e.embed(alloc, d.text);
        defer alloc.free(v);
        try hnsw.insert(d.id, v);
    }

    const q = try e.embed(alloc, "the user really prefers zig");
    defer alloc.free(q);

    const results = try hnsw.search(alloc, q, 3);
    defer alloc.free(results);

    try std.testing.expect(results.len >= 3);
    try std.testing.expectEqual(@as(u64, 1), results[0].id);
    try std.testing.expect(results[0].score > results[2].score);
}

test "Embedder: union selects the configured kind" {
    const alloc = std.testing.allocator;

    var cfg = config.Config{};
    cfg.embedder_dim = 384;

    cfg.embedder_kind = .stub_xxhash;
    const stub = try Embedder.fromConfig(cfg);
    try std.testing.expect(stub == .stub_xxhash);

    cfg.embedder_kind = .lexical_hash;
    const lex = try Embedder.fromConfig(cfg);
    try std.testing.expect(lex == .lexical_hash);

    const via_stub = try stub.embed(alloc, "the user prefers zig");
    defer alloc.free(via_stub);
    const via_lex = try lex.embed(alloc, "the user prefers zig");
    defer alloc.free(via_lex);
    try std.testing.expectEqual(@as(usize, 384), via_stub.len);
    try std.testing.expectEqual(@as(usize, 384), via_lex.len);
    try std.testing.expect(!std.mem.eql(f32, via_stub, via_lex));

    const batch = try lex.embedBatch(alloc, &.{ "alpha beta", "beta gamma" });
    defer {
        for (batch) |v| alloc.free(v);
        alloc.free(batch);
    }
    try std.testing.expectEqual(@as(usize, 2), batch.len);
}

test "Embedder: the reserved variant is a typed error, never a panic" {
    // The constitution's API Surface Standards forbid panics in
    // libraries, and `.onnx_external` is reachable from a config file.
    // This test fails loudly if anyone reintroduces `@panic` here: the
    // process dies instead of returning, and the runner reports it.
    try std.testing.expectError(
        error.UnsupportedEmbedder,
        Embedder.init(.onnx_external, 384),
    );
    try std.testing.expectError(
        error.UnsupportedEmbedder,
        Embedder.fromConfig(.{ .embedder_kind = .onnx_external }),
    );
}

test "Config: lexical_hash is a selectable EmbedderKind" {
    const c: config.Config = .{};
    try std.testing.expectEqual(@as(u16, 384), c.embedder_dim);

    const lex: config.Config = .{ .embedder_kind = .lexical_hash };
    try std.testing.expect(lex.embedder_kind == .lexical_hash);
    // Default stays on the stub so no existing behaviour changes implicitly.
    try std.testing.expect(c.embedder_kind == .stub_xxhash);
}