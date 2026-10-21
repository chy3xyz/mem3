//! The redundancy term of `net_existence`, computed without comparing all
//! pairs.
//!
//! **GHW Layer**: Memory (tri-source coherence). See `forgetter.zig` for how the term is
//! used and ADR 0005 (`docs/adr/0005-existence-gain-forgetting.md`) for why it
//! is defined this way.
//!
//! ## The definition
//!
//! Cells are visited from most to least dominant (`importance` descending,
//! then arrival order). For the cell `c` being visited, the **retained**
//! cells already visited are the only candidates to cover it. `d` *covers*
//! `c` when
//!
//!   * they have the same source (matter, form and spirit are not interchangeable),
//!   * every goal `c` is bound to, `d` is bound to,
//!   * every foresight description of `c` is also one of `d`'s,
//!   * every fact of `c` is also a fact of `d` (so `c` adds nothing a
//!     conflict could disagree with), and
//!   * `Jaccard(tokens(c), tokens(d)) >= tau`, over the *exact* sets of
//!     lowercased alphanumeric tokens of the episode and of every fact's
//!     subject, predicate and object (same tokenisation as
//!     `cluster_index.signatureOf`, before its hash-into-512-buckets step).
//!
//! `s = max over covering d of (J - tau) / (1 - tau)`, in `[0, 1]`, and
//!
//!     redundancy(c) = s * (importance(c) + theta)
//!
//! A cell is **redundant** when `importance - redundancy < 0`; a redundant
//! cell is not added to the retained set, so it never covers anyone. The
//! first cell of every duplicate group has no retained dominator and so has
//! redundancy 0: **a group is never forgotten whole**. Greedy-by-dominance
//! (rather than "redundant with respect to *any* more important neighbour")
//! is what makes that hold even when similarity is not transitive.
//!
//! ## Why this is not O(n^2)
//!
//! Candidates come from a *prefix-filter* inverted index (Chaudhuri et al.,
//! "A primitive operator for similarity joins", 2006), which is exact:
//!
//!   If `J(A, B) >= t` then `|A ∩ B| >= ceil(t*|A|)` and `>= ceil(t*|B|)`.
//!   Order every token by global rarity. Of the first
//!   `|A| - ceil(t*|A|) + 1` tokens of `A` and the first
//!   `|B| - ceil(t*|B|) + 1` tokens of `B`, at least one is shared:
//!   the rarest common token sits at position `<= |A| - |A∩B| + 1` in `A`
//!   and likewise in `B`.
//!
//! So a retained cell is indexed under its *prefix* tokens only, and `c` is
//! compared only against the retained cells that share a prefix token — which
//! are, by construction, the ones that hold a rare token of `c`. Results are
//! identical to comparing every retained pair (the tests hold the filter to
//! an independent all-pairs oracle); only the number of Jaccard evaluations
//! changes. `tau` is lowered by `PREFIX_SLACK` before the prefix length is
//! computed so that float rounding in the final `>=` can never admit a pair
//! the filter dropped.
//!
//! The cost is **output-sensitive**: O(n log n) to tokenise and rank, plus
//! one Jaccard per (cell, candidate) pair. It stays near-linear when cells
//! are mostly distinct or mostly exact duplicates (a duplicate group
//! contributes one retained cell). It degrades toward O(n^2) on a corpus
//! where *every* pair is moderately similar but nothing is redundant — a
//! templated log with a few varying tokens — because every cell is retained
//! and every pair is a genuine candidate. That is a property of the
//! definition, not of the index, and the ADR records it as a limit.
//!
//! A 512-bit-bucket index (the consolidator's signature) was *not* used for
//! candidate generation: with 512 posting lists a cell's prefix tokens each
//! hit ~`n*k/512` retained cells, so the index degenerates to a
//! constant-factor-512 version of all-pairs. That is an argument from the
//! arithmetic, not a measurement; the exact token set has no such floor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const conflict = @import("conflict.zig");

pub const Params = struct {
    /// Near-duplicate floor (`Config.redundancy_threshold`).
    tau: f32,
    /// The keep-threshold (`Config.forgetting_threshold`).
    theta: f32,
    /// Most Jaccard evaluations spent on any one cell. Bounds the sweep at
    /// O(n * max_candidates) even on a corpus where every pair is similar.
    /// Candidates are visited rarest-token first, in dominance order, so a
    /// genuine duplicate (which shares the cell's rarest tokens) is found
    /// long before the cap bites; what the cap gives up is a covering
    /// neighbour found only through *common* tokens in a dense cluster. That
    /// is the safe direction: fewer cells forgotten, never more. The default
    /// is unbounded so the oracle comparison stays exact.
    max_candidates: u32 = std.math.maxInt(u32),
};

/// Float slack applied to `tau` before sizing the prefix. See module doc.
pub const PREFIX_SLACK: f64 = 1e-4;

pub const Result = struct {
    alloc: Allocator,
    /// Per input cell, `s * (importance + theta)`; 0 for a cell nothing covers.
    redundancy: []f32,
    /// `importance - redundancy < 0`.
    redundant: []bool,
    /// Jaccard evaluations performed.
    jaccard_evals: u64 = 0,

    pub fn deinit(self: *Result) void {
        self.alloc.free(self.redundancy);
        self.alloc.free(self.redundant);
    }
};

/// Hash of every token of a string, using exactly the normalisation of
/// `cluster_index.forEachToken` (split on ' ', lowercase, keep [a-z0-9],
/// at most 64 characters) but keeping all 64 bits of the hash.
fn forEachTokenHash(text: []const u8, ctx: anytype, comptime sink: fn (@TypeOf(ctx), u64) void) void {
    var it = std.mem.splitScalar(u8, text, ' ');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
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
        sink(ctx, std.hash.XxHash3.hash(0, buf[0..bl]));
    }
}

/// The cell's unique token hashes, sorted ascending, appended to `out`.
pub fn tokenHashes(alloc: Allocator, cell: *const MemCell, out: *std.ArrayList(u64)) !void {
    const start = out.items.len;
    const Ctx = struct { list: *std.ArrayList(u64), alloc: Allocator, failed: bool = false };
    var ctx: Ctx = .{ .list = out, .alloc = alloc };
    const push = struct {
        fn f(c: *Ctx, h: u64) void {
            c.list.append(c.alloc, h) catch {
                c.failed = true;
            };
        }
    }.f;
    forEachTokenHash(cell.episode, &ctx, push);
    for (cell.atomic_facts) |f| {
        forEachTokenHash(f.subject, &ctx, push);
        forEachTokenHash(f.predicate, &ctx, push);
        forEachTokenHash(f.object, &ctx, push);
    }
    if (ctx.failed) return error.OutOfMemory;
    const slice = out.items[start..];
    std.mem.sort(u64, slice, {}, std.sort.asc(u64));
    // Unique in place.
    var w: usize = 0;
    for (slice, 0..) |h, i| {
        if (i > 0 and h == slice[i - 1]) continue;
        slice[w] = h;
        w += 1;
    }
    out.shrinkRetainingCapacity(start + w);
}

/// Per-cell token sets as ranks (0 = rarest in this batch), each cell's
/// ranks sorted ascending, in one flat array.
const TokenSets = struct {
    alloc: Allocator,
    offsets: []u32,
    ranks: []u32,
    unique_tokens: usize,

    fn deinit(self: *TokenSets) void {
        self.alloc.free(self.offsets);
        self.alloc.free(self.ranks);
    }

    fn of(self: *const TokenSets, i: usize) []const u32 {
        return self.ranks[self.offsets[i]..self.offsets[i + 1]];
    }

    fn build(alloc: Allocator, cells: []const *const MemCell) !TokenSets {
        // 1. Unique hashes per cell, flat.
        var hashes: std.ArrayList(u64) = .empty;
        defer hashes.deinit(alloc);
        const offsets = try alloc.alloc(u32, cells.len + 1);
        errdefer alloc.free(offsets);
        offsets[0] = 0;
        for (cells, 0..) |cell, i| {
            try tokenHashes(alloc, cell, &hashes);
            offsets[i + 1] = @intCast(hashes.items.len);
        }

        // 2. Document frequency per token, then rank by (frequency, hash):
        //    rare first, ties broken by the hash so the order is a function
        //    of the cell set alone.
        var freq: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer freq.deinit(alloc);
        for (hashes.items) |h| {
            const e = try freq.getOrPut(alloc, h);
            if (!e.found_existing) e.value_ptr.* = 0;
            e.value_ptr.* += 1;
        }
        const Entry = struct { hash: u64, freq: u32 };
        const entries = try alloc.alloc(Entry, freq.count());
        defer alloc.free(entries);
        var it = freq.iterator();
        var k: usize = 0;
        while (it.next()) |e| : (k += 1) entries[k] = .{ .hash = e.key_ptr.*, .freq = e.value_ptr.* };
        std.mem.sort(Entry, entries, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                if (a.freq != b.freq) return a.freq < b.freq;
                return a.hash < b.hash;
            }
        }.lt);
        // Reuse the map as hash -> rank.
        for (entries, 0..) |e, rank| freq.putAssumeCapacity(e.hash, @intCast(rank));

        // 3. Replace hashes by ranks and sort each cell's ranks ascending.
        const ranks = try alloc.alloc(u32, hashes.items.len);
        errdefer alloc.free(ranks);
        for (hashes.items, ranks) |h, *r| r.* = freq.get(h).?;
        for (0..cells.len) |i| {
            std.mem.sort(u32, ranks[offsets[i]..offsets[i + 1]], {}, std.sort.asc(u32));
        }
        return .{ .alloc = alloc, .offsets = offsets, .ranks = ranks, .unique_tokens = entries.len };
    }
};

/// |A ∩ B| and |A ∪ B| of two ascending rank lists.
fn overlap(a: []const u32, b: []const u32) struct { inter: usize, union_size: usize } {
    var i: usize = 0;
    var j: usize = 0;
    var inter: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] == b[j]) {
            inter += 1;
            i += 1;
            j += 1;
        } else if (a[i] < b[j]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    return .{ .inter = inter, .union_size = a.len + b.len - inter };
}

fn jaccard(a: []const u32, b: []const u32) f32 {
    const o = overlap(a, b);
    if (o.union_size == 0) return 0.0;
    return @as(f32, @floatFromInt(o.inter)) / @as(f32, @floatFromInt(o.union_size));
}

fn goalsSubset(c: *const MemCell, d: *const MemCell) bool {
    for (c.goal_associations) |cg| {
        var found = false;
        for (d.goal_associations) |dg| {
            if (dg.goal_id == cg.goal_id) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn foresightSubset(c: *const MemCell, d: *const MemCell) bool {
    for (c.foresight) |cf| {
        var found = false;
        for (d.foresight) |df| {
            if (std.mem.eql(u8, cf.description, df.description)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn factsSubset(c: *const MemCell, d: *const MemCell) bool {
    for (c.atomic_facts) |cf| {
        var found = false;
        for (d.atomic_facts) |df| {
            if (conflict.factsEqual(cf, df)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Everything about "d covers c" except the similarity: the part of the
/// definition that is about what c *carries*.
fn carries(c: *const MemCell, d: *const MemCell) bool {
    return c.source == d.source and goalsSubset(c, d) and foresightSubset(c, d) and factsSubset(c, d);
}

fn rescale(j: f32, tau: f32) f32 {
    const span = @max(1.0 - tau, 1e-6);
    return std.math.clamp((j - tau) / span, 0.0, 1.0);
}

fn importanceOf(c: *const MemCell) f32 {
    const x = c.metadata.importance_score;
    return if (std.math.isNan(x)) 0.0 else x;
}

fn finish(res: *Result, i: usize, c: *const MemCell, s: f32, theta: f32) bool {
    const imp = importanceOf(c);
    res.redundancy[i] = s * (imp + theta);
    res.redundant[i] = imp - res.redundancy[i] < 0;
    return !res.redundant[i];
}

fn newResult(alloc: Allocator, n: usize) !Result {
    const r = try alloc.alloc(f32, n);
    errdefer alloc.free(r);
    @memset(r, 0);
    const d = try alloc.alloc(bool, n);
    @memset(d, false);
    return .{ .alloc = alloc, .redundancy = r, .redundant = d };
}

/// Redundancy of every cell. `cells` MUST already be in dominance order
/// (most important first; ties by earlier arrival): that order is what lets
/// "retained cells visited so far" mean "cells that outrank this one".
pub fn run(alloc: Allocator, cells: []const *const MemCell, params: Params) !Result {
    // tau <= 0 makes every pair "similar", which no inverted index can
    // narrow. Not a configuration anyone should run; stay correct anyway.
    if (params.tau <= 0) return runBruteForce(alloc, cells, params);

    var res = try newResult(alloc, cells.len);
    errdefer res.deinit();
    if (cells.len == 0) return res;

    var sets = try TokenSets.build(alloc, cells);
    defer sets.deinit();

    const t_eff: f64 = @as(f64, params.tau) * (1.0 - PREFIX_SLACK);

    // Per source: rank -> retained cells (as indices into `cells`) that have
    // that rank in their prefix.
    const Lists = std.AutoHashMapUnmanaged(u32, std.ArrayList(u32));
    var lists: [3]Lists = .{ .empty, .empty, .empty };
    defer for (&lists) |*l| {
        var it = l.iterator();
        while (it.next()) |e| e.value_ptr.deinit(alloc);
        l.deinit(alloc);
    };

    // Candidate de-duplication: stamp[j] == i means j was already compared
    // against cell i.
    const stamp = try alloc.alloc(u32, cells.len);
    defer alloc.free(stamp);
    @memset(stamp, std.math.maxInt(u32));

    for (cells, 0..) |c, i| {
        const toks = sets.of(i);
        const k = toks.len;
        if (k == 0) continue; // nothing to match on: retained, not indexed
        const src = @intFromEnum(c.source);
        const need: usize = @intFromFloat(@ceil(t_eff * @as(f64, @floatFromInt(k))));
        const prefix_len = k - @min(need, k) + 1;

        var best: f32 = 0.0;
        var spent: u32 = 0;
        probe: for (toks[0..prefix_len]) |tok| {
            const list = lists[src].getPtr(tok) orelse continue;
            for (list.items) |j| {
                if (stamp[j] == i) continue;
                stamp[j] = @intCast(i);
                const other = sets.of(j);
                // Size filter: J >= t implies t*|A| <= |B| <= |A|/t.
                const m: f64 = @floatFromInt(other.len);
                if (m < t_eff * @as(f64, @floatFromInt(k)) or m * t_eff > @as(f64, @floatFromInt(k))) continue;
                res.jaccard_evals += 1;
                spent += 1;
                const j_val = jaccard(toks, other);
                if (j_val >= params.tau and carries(c, cells[j])) {
                    best = @max(best, rescale(j_val, params.tau));
                }
                if (spent >= params.max_candidates) break :probe;
            }
        }

        if (!finish(&res, i, c, best, params.theta)) continue;

        // Retained: index its prefix so later (less dominant) cells can find it.
        for (toks[0..prefix_len]) |tok| {
            const e = try lists[src].getOrPut(alloc, tok);
            if (!e.found_existing) e.value_ptr.* = .empty;
            try e.value_ptr.append(alloc, @intCast(i));
        }
    }
    return res;
}

/// The definition, applied literally: every retained, more-dominant cell of
/// the same source is compared. The oracle `run` is held to.
pub fn runBruteForce(alloc: Allocator, cells: []const *const MemCell, params: Params) !Result {
    var res = try newResult(alloc, cells.len);
    errdefer res.deinit();
    if (cells.len == 0) return res;

    var sets = try TokenSets.build(alloc, cells);
    defer sets.deinit();

    const retained = try alloc.alloc(bool, cells.len);
    defer alloc.free(retained);
    @memset(retained, false);

    for (cells, 0..) |c, i| {
        const toks = sets.of(i);
        var best: f32 = 0.0;
        if (toks.len != 0) {
            for (0..i) |j| {
                if (!retained[j] or cells[j].source != c.source) continue;
                res.jaccard_evals += 1;
                const j_val = jaccard(toks, sets.of(j));
                if (j_val < params.tau) continue;
                if (!carries(c, cells[j])) continue;
                best = @max(best, rescale(j_val, params.tau));
            }
        }
        retained[i] = finish(&res, i, c, best, params.theta);
    }
    return res;
}

test "redundancy: tokenHashes is sorted, unique, and drifts from forEachToken by nothing" {
    const alloc = std.testing.allocator;
    const cluster_index = @import("cluster_index.zig");
    const cell: MemCell = .{
        .id = 1,
        .source = .matter,
        .episode = "The  Quick brown FOX; jumps over the lazy dog's back 42 times",
        .atomic_facts = &.{.{ .subject = "Fox", .predicate = "jumps-over", .object = "dog", .confidence = 1, .source = "t" }},
        .foresight = &.{},
        .goal_associations = &.{},
        .metadata = .{},
    };
    var hashes: std.ArrayList(u64) = .empty;
    defer hashes.deinit(alloc);
    try tokenHashes(alloc, &cell, &hashes);
    try std.testing.expect(std.sort.isSorted(u64, hashes.items, {}, std.sort.asc(u64)));
    for (hashes.items[1..], hashes.items[0 .. hashes.items.len - 1]) |a, b| try std.testing.expect(a != b);

    // Every bucket the consolidator's signature sets is the bucket of one of
    // our hashes, and vice versa: same tokens, same normalisation.
    const sig = cluster_index.signatureOf(&cell);
    var ours: cluster_index.Signature = @splat(0);
    for (hashes.items) |h| {
        const b: usize = @intCast(h % 512);
        ours[b / 64] |= @as(u64, 1) << @intCast(b % 64);
    }
    try std.testing.expectEqualSlices(u64, &sig, &ours);
}
