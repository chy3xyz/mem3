//! Paired-difference statistics for the ablation harness.
//!
//! **GHW layer**: Harness layer (form source). Evaluation arithmetic only; nothing here
//! is on a product code path and nothing here touches a `Store`.
//!
//! One job: given per-question *paired* deltas (variant minus baseline on the
//! same question), report the mean delta with a percentile-bootstrap
//! confidence interval over questions. Questions are the resampling unit
//! because they are the independent draws; the cells inside one question's
//! haystack are not.
//!
//! The PRNG is SplitMix64, written out here rather than taken from `std` so
//! that a published interval can be reproduced from `(deltas, resamples,
//! seed)` on any toolchain: `std.Random` implementations have moved between
//! point releases, and an interval that silently changes with the compiler is
//! not a reproducible number.
//!
//! The percentile rule is the one numpy calls `linear` (position `p·(B−1)` in
//! the sorted resample means, interpolated), so `scripts/lme_ablation_report.py`
//! can re-derive the same interval independently as a cross-check.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// SplitMix64 (Steele, Lea, Flood). Deterministic, one `u64` of state,
/// passes the usual statistical batteries well enough for resampling.
pub const SplitMix64 = struct {
    state: u64,

    pub fn init(seed: u64) SplitMix64 {
        return .{ .state = seed };
    }

    pub fn next(self: *SplitMix64) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// Uniform in `[0, n)` by multiply-high. The bias is below `n / 2^64`,
    /// irrelevant for `n` in the hundreds. `n == 0` is a caller bug.
    pub fn below(self: *SplitMix64, n: u64) u64 {
        std.debug.assert(n > 0);
        return @intCast((@as(u128, self.next()) * @as(u128, n)) >> 64);
    }
};

pub const Ci = struct {
    mean: f64,
    lo: f64,
    hi: f64,
};

/// Counts of how the paired deltas fall. `same` is exact equality, which is
/// the right test for metrics that are identical when the rankings are.
pub const Tally = struct {
    n: usize = 0,
    improved: usize = 0,
    worsened: usize = 0,
    same: usize = 0,
};

pub fn tally(deltas: []const f64) Tally {
    var t = Tally{ .n = deltas.len };
    for (deltas) |d| {
        if (d > 0) t.improved += 1 else if (d < 0) t.worsened += 1 else t.same += 1;
    }
    return t;
}

pub fn mean(xs: []const f64) f64 {
    if (xs.len == 0) return 0;
    var s: f64 = 0;
    for (xs) |x| s += x;
    return s / @as(f64, @floatFromInt(xs.len));
}

/// Sorted-sample quantile, numpy's `linear` method: position `p·(n−1)`.
/// `sorted` must be ascending and non-empty; `p` is clamped to `[0, 1]`.
pub fn quantileSorted(sorted: []const f64, p: f64) f64 {
    std.debug.assert(sorted.len > 0);
    const pp = std.math.clamp(p, 0.0, 1.0);
    const pos = pp * @as(f64, @floatFromInt(sorted.len - 1));
    const lo_i: usize = @intFromFloat(@floor(pos));
    const hi_i: usize = @min(lo_i + 1, sorted.len - 1);
    const frac = pos - @as(f64, @floatFromInt(lo_i));
    return sorted[lo_i] + (sorted[hi_i] - sorted[lo_i]) * frac;
}

/// Two intervals from one bootstrap: the plain 95 % one and a wider one at a
/// caller-chosen confidence level (Bonferroni: `1 − 0.05/m`).
pub const Interval2 = struct {
    mean: f64,
    ci95: [2]f64,
    ci_adj: [2]f64,
};

/// Percentile bootstrap of the mean of `deltas` over questions.
///
/// `resamples` draws of `n` indices with replacement, `seed` fixes the
/// stream. An empty input has no interval and returns `error.NoData` instead
/// of a made-up zero. When every delta is identical the interval collapses to
/// that value without drawing anything: resampling a constant cannot move it,
/// and skipping the loop keeps float summation noise out of an exact `0`.
pub fn bootstrapMean2(
    alloc: Allocator,
    deltas: []const f64,
    resamples: usize,
    seed: u64,
    adj_level: f64,
) !Interval2 {
    if (deltas.len == 0) return error.NoData;
    const m = mean(deltas);

    var constant = true;
    for (deltas[1..]) |d| {
        if (d != deltas[0]) {
            constant = false;
            break;
        }
    }
    if (constant) {
        return .{ .mean = deltas[0], .ci95 = .{ deltas[0], deltas[0] }, .ci_adj = .{ deltas[0], deltas[0] } };
    }

    const means = try alloc.alloc(f64, resamples);
    defer alloc.free(means);
    var rng = SplitMix64.init(seed);
    const n: u64 = deltas.len;
    const nf: f64 = @floatFromInt(deltas.len);
    for (means) |*out| {
        var s: f64 = 0;
        var i: usize = 0;
        while (i < deltas.len) : (i += 1) s += deltas[@intCast(rng.below(n))];
        out.* = s / nf;
    }
    std.mem.sort(f64, means, {}, std.sort.asc(f64));

    const a95 = 0.05;
    const aadj = 1.0 - adj_level;
    return .{
        .mean = m,
        .ci95 = .{ quantileSorted(means, a95 / 2.0), quantileSorted(means, 1.0 - a95 / 2.0) },
        .ci_adj = .{ quantileSorted(means, aadj / 2.0), quantileSorted(means, 1.0 - aadj / 2.0) },
    };
}

/// FNV-1a over the little-endian bytes of a ranking. Used only to tell
/// "byte-identical ranking" from "different ranking" per question.
pub fn rankingHash(ranking: []const u32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (ranking) |v| {
        var x = v;
        var b: usize = 0;
        while (b < 4) : (b += 1) {
            h ^= @as(u64, x & 0xff);
            h *%= 0x100000001b3;
            x >>= 8;
        }
    }
    return h;
}

/// Stable 64-bit hash of a string (FNV-1a), for seeding per-question streams
/// independently of file order and of `--limit` sampling.
pub fn hashStr(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return h;
}

// ============================================================================
// Tests
// ============================================================================

const approx = std.testing.expectApproxEqAbs;

test "SplitMix64: matches the reference stream for seed 0" {
    // First outputs of the reference SplitMix64 implementation, seed 0.
    var r = SplitMix64.init(0);
    try std.testing.expectEqual(@as(u64, 0xE220A8397B1DCDAF), r.next());
    try std.testing.expectEqual(@as(u64, 0x6E789E6AA1B965F4), r.next());
    try std.testing.expectEqual(@as(u64, 0x06C45D188009454F), r.next());
}

test "SplitMix64: same seed same stream, different seed different stream" {
    var a = SplitMix64.init(42);
    var b = SplitMix64.init(42);
    var c = SplitMix64.init(43);
    var differs = false;
    for (0..64) |_| {
        const x = a.next();
        try std.testing.expectEqual(x, b.next());
        if (x != c.next()) differs = true;
    }
    try std.testing.expect(differs);
}

test "SplitMix64: below stays in range and covers the range" {
    var r = SplitMix64.init(7);
    var seen: [10]bool = @splat(false);
    for (0..2000) |_| {
        const v = r.below(10);
        try std.testing.expect(v < 10);
        seen[@intCast(v)] = true;
    }
    for (seen) |s| try std.testing.expect(s);
}

test "quantileSorted: numpy-linear on a hand-checked sample" {
    const xs = [_]f64{ 1, 2, 3, 4, 5 };
    try approx(1.0, quantileSorted(&xs, 0.0), 1e-12);
    try approx(5.0, quantileSorted(&xs, 1.0), 1e-12);
    try approx(3.0, quantileSorted(&xs, 0.5), 1e-12);
    // pos = 0.25 * 4 = 1.0 -> 2 ; pos = 0.125 * 4 = 0.5 -> 1.5
    try approx(2.0, quantileSorted(&xs, 0.25), 1e-12);
    try approx(1.5, quantileSorted(&xs, 0.125), 1e-12);
    // single element
    const one = [_]f64{7};
    try approx(7.0, quantileSorted(&one, 0.975), 1e-12);
}

test "tally: improved / worsened / same are exact" {
    const d = [_]f64{ 0.5, 0, -0.25, 0, 0, 1 };
    const t = tally(&d);
    try std.testing.expectEqual(@as(usize, 6), t.n);
    try std.testing.expectEqual(@as(usize, 2), t.improved);
    try std.testing.expectEqual(@as(usize, 1), t.worsened);
    try std.testing.expectEqual(@as(usize, 3), t.same);
}

test "bootstrap: all-zero deltas give exactly [0, 0] without resampling noise" {
    const alloc = std.testing.allocator;
    const d: [50]f64 = @splat(0);
    const r = try bootstrapMean2(alloc, &d, 1000, 1, 0.9975);
    try std.testing.expectEqual(@as(f64, 0), r.mean);
    try std.testing.expectEqual(@as(f64, 0), r.ci95[0]);
    try std.testing.expectEqual(@as(f64, 0), r.ci95[1]);
    try std.testing.expectEqual(@as(f64, 0), r.ci_adj[0]);
    try std.testing.expectEqual(@as(f64, 0), r.ci_adj[1]);
}

test "bootstrap: a constant non-zero delta collapses to that constant" {
    const alloc = std.testing.allocator;
    const d: [30]f64 = @splat(0.125);
    const r = try bootstrapMean2(alloc, &d, 500, 9, 0.99);
    try approx(0.125, r.mean, 1e-15);
    try approx(0.125, r.ci95[0], 1e-15);
    try approx(0.125, r.ci95[1], 1e-15);
}

test "bootstrap: empty input is an error, not a zero" {
    const none = [_]f64{};
    try std.testing.expectError(error.NoData, bootstrapMean2(std.testing.allocator, &none, 100, 1, 0.99));
}

test "bootstrap: deterministic for a fixed seed, sensitive to the seed" {
    const alloc = std.testing.allocator;
    var d: [40]f64 = undefined;
    for (&d, 0..) |*x, i| x.* = if (i % 3 == 0) 1.0 else if (i % 7 == 0) -1.0 else 0.0;
    const a = try bootstrapMean2(alloc, &d, 2000, 123, 0.99);
    const b = try bootstrapMean2(alloc, &d, 2000, 123, 0.99);
    const c = try bootstrapMean2(alloc, &d, 2000, 124, 0.99);
    try std.testing.expectEqual(a.ci95[0], b.ci95[0]);
    try std.testing.expectEqual(a.ci95[1], b.ci95[1]);
    try std.testing.expect(a.ci95[0] != c.ci95[0] or a.ci95[1] != c.ci95[1]);
}

test "bootstrap: interval brackets the mean, adjusted interval is wider" {
    const alloc = std.testing.allocator;
    var d: [100]f64 = undefined;
    for (&d, 0..) |*x, i| x.* = @as(f64, @floatFromInt(i % 10)) / 10.0 - 0.3;
    const r = try bootstrapMean2(alloc, &d, 4000, 5, 0.9975);
    try std.testing.expect(r.ci95[0] < r.mean and r.mean < r.ci95[1]);
    try std.testing.expect(r.ci_adj[0] <= r.ci95[0]);
    try std.testing.expect(r.ci_adj[1] >= r.ci95[1]);
}

test "bootstrap: coverage on a known mean is near nominal" {
    // 200 independent samples of 60 draws from {-1,+1} with a true mean of
    // 0: the 95% interval must contain 0 in roughly 95% of them. A broken
    // resampler (always the same index, or an off-by-one range) fails this
    // by a wide margin. The bound is generous on purpose.
    const alloc = std.testing.allocator;
    var gen = SplitMix64.init(2026);
    var covered: usize = 0;
    const trials: usize = 200;
    for (0..trials) |t| {
        var d: [60]f64 = undefined;
        for (&d) |*x| x.* = if (gen.next() & 1 == 0) 1.0 else -1.0;
        const r = try bootstrapMean2(alloc, &d, 600, 1000 + t, 0.99);
        if (r.ci95[0] <= 0 and 0 <= r.ci95[1]) covered += 1;
    }
    try std.testing.expect(covered >= 175);
    try std.testing.expect(covered <= 200);
}

test "bootstrap: interval of a one-sided sample excludes zero" {
    const alloc = std.testing.allocator;
    var d: [80]f64 = undefined;
    for (&d, 0..) |*x, i| x.* = if (i < 60) 1.0 else 0.0; // mean 0.75
    const r = try bootstrapMean2(alloc, &d, 4000, 3, 0.99);
    try std.testing.expect(r.ci95[0] > 0.5);
    try std.testing.expect(r.ci95[1] < 0.95);
}

test "bootstrap: a single question yields a degenerate interval at its value" {
    const alloc = std.testing.allocator;
    const d = [_]f64{0.4};
    const r = try bootstrapMean2(alloc, &d, 100, 1, 0.99);
    try approx(0.4, r.ci95[0], 1e-15);
    try approx(0.4, r.ci95[1], 1e-15);
}

test "rankingHash: order-sensitive, content-sensitive, stable" {
    const a = [_]u32{ 1, 2, 3 };
    const b = [_]u32{ 3, 2, 1 };
    const c = [_]u32{ 1, 2, 3 };
    try std.testing.expect(rankingHash(&a) != rankingHash(&b));
    try std.testing.expectEqual(rankingHash(&a), rankingHash(&c));
    try std.testing.expect(rankingHash(&[_]u32{}) == rankingHash(&[_]u32{}));
}

test "hashStr: stable and distinguishes ids" {
    try std.testing.expectEqual(hashStr("gpt4_001"), hashStr("gpt4_001"));
    try std.testing.expect(hashStr("gpt4_001") != hashStr("gpt4_002"));
}
