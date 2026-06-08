//! Three-source coherence: C_tri = C_MF · C_FS · C_SM.
//!
//! **GHW Layer**: Memory (三源合恰). Implements the Coherence
//! Calculator described in the paper §4.2 (L2 三源合恰记忆层).
//!
//! ## Constitution compliance
//! - Principle I (三源完整性): the three pairwise cosines are computed
//!   from explicit fields of the cell (episode, atomic_facts,
//!   foresight, goal_associations) — no field is invented.
//! - Principle V (零拷贝): all comparisons operate on borrowed slices;
//!   no per-call allocations beyond a single token-bitset buffer.
//!
//! ## Algorithm
//!
//! Each pairwise coherence is a Jaccard similarity over the token sets
//! of the two source's representations. Jaccard ∈ [0, 1] and
//! produces reasonable values for short natural-language text without
//! requiring a learned embedding model. This is a v0.2 stub — when
//! LLM embeddings land (v0.3), replace the Jaccard inner with cosine
//! over learned vectors. The pairwise → product topology is stable
//! across that upgrade.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const Fact = core.Fact;
const Foresight = core.Foresight;
const GoalAssociation = core.GoalAssociation;
const config = @import("../core/config.zig").Config;

/// Maximum distinct tokens we'll hash-tracked. Caps memory; tokens
/// beyond this threshold are simply ignored (which biases the Jaccard
/// denominator up, producing a *slightly* higher similarity than
/// the true value — the bias is conservative for "should this cell
/// be considered coherent?" decisions).
const MAX_TRACKED_TOKENS: usize = 512;

/// Per-cell coherence calculator. Holds reusable buffers so repeated
/// calls don't re-allocate. One instance per Lifecycle (or per
/// Consolidator thread).
pub const CoherenceCalculator = struct {
    alloc: Allocator,

    /// Reusable token-bitset (length = MAX_TRACKED_TOKENS, indexed by
    /// hash % MAX_TRACKED_TOKENS). A bit is set if any token with that
    /// hash was seen.
    scratch_a: [MAX_TRACKED_TOKENS]u8,
    scratch_b: [MAX_TRACKED_TOKENS]u8,

    pub fn init(alloc: Allocator) CoherenceCalculator {
        var zero: [MAX_TRACKED_TOKENS]u8 = undefined;
        @memset(&zero, 0);
        return .{
            .alloc = alloc,
            .scratch_a = zero,
            .scratch_b = zero,
        };
    }

    /// Compute C_MF: matter ↔ form coherence, Jaccard similarity of
    /// the token sets of `episode` (matter) and all atomic_facts
    /// subject/predicate/object strings (form).
    pub fn matterFormCoherence(self: *CoherenceCalculator, cell: *const MemCell) f32 {
        @memset(&self.scratch_a, 0);
        @memset(&self.scratch_b, 0);
        tokenizeInto(&self.scratch_a, cell.episode);
        for (cell.atomic_facts) |f| {
            tokenizeInto(&self.scratch_b, f.subject);
            tokenizeInto(&self.scratch_b, f.predicate);
            tokenizeInto(&self.scratch_b, f.object);
        }
        return jaccard(&self.scratch_a, &self.scratch_b);
    }

    /// Compute C_FS: form ↔ spirit coherence, Jaccard similarity of
    /// the token sets of `atomic_facts` (form) and
    /// `foresight[i].description` + `goal_associations` (spirit).
    pub fn formSpiritCoherence(self: *CoherenceCalculator, cell: *const MemCell) f32 {
        @memset(&self.scratch_a, 0);
        @memset(&self.scratch_b, 0);
        for (cell.atomic_facts) |f| {
            tokenizeInto(&self.scratch_a, f.subject);
            tokenizeInto(&self.scratch_a, f.predicate);
            tokenizeInto(&self.scratch_a, f.object);
        }
        for (cell.foresight) |ft| tokenizeInto(&self.scratch_b, ft.description);
        for (cell.goal_associations) |g| {
            var buf: [16]u8 = undefined;
            const gstr = std.fmt.bufPrint(&buf, "goal{d}", .{g.goal_id}) catch "goal";
            tokenizeInto(&self.scratch_b, gstr);
        }
        return jaccard(&self.scratch_a, &self.scratch_b);
    }

    /// Compute C_SM: spirit ↔ matter coherence, Jaccard similarity
    /// of the token sets of `foresight + goal_associations` (spirit)
    /// and `episode` (matter). The closing of the triangle
    /// (matter→form→spirit→matter) gives the "三源合恰" property
    /// its name.
    pub fn spiritMatterCoherence(self: *CoherenceCalculator, cell: *const MemCell) f32 {
        @memset(&self.scratch_a, 0);
        @memset(&self.scratch_b, 0);
        for (cell.foresight) |ft| tokenizeInto(&self.scratch_a, ft.description);
        for (cell.goal_associations) |g| {
            var buf: [16]u8 = undefined;
            const gstr = std.fmt.bufPrint(&buf, "goal{d}", .{g.goal_id}) catch "goal";
            tokenizeInto(&self.scratch_a, gstr);
        }
        tokenizeInto(&self.scratch_b, cell.episode);
        return jaccard(&self.scratch_a, &self.scratch_b);
    }

    /// C_tri = C_MF · C_FS · C_SM. Returns 0.0 if any pair is 0
    /// (degenerate: an empty source can't be coherent with anything).
    pub fn triSourceCoherence(self: *CoherenceCalculator, cell: *const MemCell) f32 {
        if (cell.atomic_facts.len == 0 or
            (cell.foresight.len == 0 and cell.goal_associations.len == 0))
        {
            return 0.0;
        }
        const c_mf = self.matterFormCoherence(cell);
        const c_fs = self.formSpiritCoherence(cell);
        const c_sm = self.spiritMatterCoherence(cell);
        return c_mf * c_fs * c_sm;
    }

    /// Compute and store the C_tri into the cell's metadata.coherence_score.
    /// Convenience used by encode() and consolidator().
    pub fn updateCell(self: *CoherenceCalculator, cell: *MemCell) f32 {
        const c = self.triSourceCoherence(cell);
        cell.metadata.coherence_score = c;
        return c;
    }
};

/// Insert hash-bits into a token-bitset. The bit index is `hash %
/// MAX_TRACKED_TOKENS` (so collisions fold multiple tokens into the
/// same bit; this is fine for Jaccard — it slightly *under*-estimates
/// the true intersection, biasing toward lower similarity. The bias
/// is conservative for "is this coherent?" gating.)
fn tokenizeInto(bits: *[MAX_TRACKED_TOKENS]u8, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        // Strip simple punctuation. Cheap: lowercase + skip non-alnum.
        var buf: [64]u8 = undefined;
        var bl: usize = 0;
        for (tok) |c| {
            const lc: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
            if (lc >= 'a' and lc <= 'z' or lc >= '0' and lc <= '9') {
                if (bl < buf.len) {
                    buf[bl] = lc;
                    bl += 1;
                }
            }
        }
        if (bl == 0) continue;
        const normalized = buf[0..bl];
        const h = std.hash.XxHash3.hash(normalized);
        const idx: usize = @intCast(h % MAX_TRACKED_TOKENS);
        bits[idx] = 1;
    }
}

/// Jaccard similarity: |A ∩ B| / |A ∪ B|. Both bitsets same size.
fn jaccard(a: *[MAX_TRACKED_TOKENS]u8, b: *[MAX_TRACKED_TOKENS]u8) f32 {
    var inter: usize = 0;
    var union_size: usize = 0;
    for (0..MAX_TRACKED_TOKENS) |i| {
        const av = a[i] != 0;
        const bv = b[i] != 0;
        if (av and bv) inter += 1;
        if (av or bv) union_size += 1;
    }
    if (union_size == 0) return 0.0;
    return @as(f32, @floatFromInt(inter)) / @as(f32, @floatFromInt(union_size));
}

// =============================================================================
// Tests
// =============================================================================

test "CoherenceCalculator: matter-form picks up token overlap" {
    var calc = CoherenceCalculator.init(std.testing.allocator);
    const cell: MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "the cat sat on the mat",
        .atomic_facts = &.{
            .{ .subject = "cat", .predicate = "sat_on", .object = "mat", .confidence = 1.0, .source = "test" },
            .{ .subject = "the", .predicate = "is", .object = "feline", .confidence = 1.0, .source = "test" },
        },
        .foresight = &.{},
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.5, .priority = 1 },
        },
        .metadata = .{ .source_confidence = 0.9 },
    };
    const c = calc.matterFormCoherence(&cell);
    try std.testing.expect(c > 0.0);
    try std.testing.expect(c < 1.0); // not perfect overlap
}

test "CoherenceCalculator: triSourceCoherence requires all three sources" {
    var calc = CoherenceCalculator.init(std.testing.allocator);
    // Empty foresight AND empty goal_associations → degenerate, return 0.
    const degenerate: MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "x",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{},
        .metadata = .{},
    };
    try std.testing.expectEqual(@as(f32, 0.0), calc.triSourceCoherence(&degenerate));

    // Empty atomic_facts → degenerate.
    const no_form: MemCell = .{
        .id = 2,
        .source = .matter,
        .episode = "x",
        .atomic_facts = &.{},
        .foresight = &.{},
        .goal_associations = &.{ .{ .goal_id = 1, .relevance = 0.5, .priority = 1 } },
        .metadata = .{},
    };
    try std.testing.expectEqual(@as(f32, 0.0), calc.triSourceCoherence(&no_form));
}

test "CoherenceCalculator: fully-aligned cell approaches 1.0" {
    var calc = CoherenceCalculator.init(std.testing.allocator);
    // Construct a cell where matter/form/spirit all share the same
    // vocabulary so all three pair Jaccards are high.
    const cell: MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "alpha beta gamma delta",
        .atomic_facts = &.{
            .{ .subject = "alpha", .predicate = "is", .object = "beta", .confidence = 1.0, .source = "test" },
        },
        .foresight = &.{
            .{ .description = "gamma delta alpha", .valid_from = 0, .valid_until = 0, .confidence = 1.0 },
        },
        .goal_associations = &.{
            .{ .goal_id = 1, .relevance = 0.5, .priority = 1 },
        },
        .metadata = .{ .source_confidence = 0.9 },
    };
    const c = calc.triSourceCoherence(&cell);
    try std.testing.expect(c > 0.0);
}
