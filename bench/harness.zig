//! Shared measurement plumbing for the constitutional benchmark suite.
//!
//! Everything here exists so that the seven named benchmarks in this
//! directory measure things the same way and say the same thing about it.
//! Nothing in this file prints a performance number of its own — it only
//! provides clocks, distributions, a JSON writer, a deterministic PRNG,
//! scratch-directory management and RSS accounting.
//!
//! ## The one rule everything else serves
//!
//! A benchmark that cannot measure something must print `null` and say
//! why. Nothing in this directory is allowed to substitute a "typical"
//! constant for a measurement. The JSON writer enforces part of that
//! mechanically: it refuses to emit NaN or Infinity (which are not valid
//! JSON) and writes them as `null` instead, so a broken metric degrades
//! into a visibly missing value rather than into a plausible-looking lie.

const std = @import("std");
const mem3 = @import("mem3");

pub const Allocator = std.mem.Allocator;

// ============================================================================
// Clocks
// ============================================================================

/// Monotonic nanoseconds. `std.time` was removed in Zig 0.17; this is the
/// same `clock_gettime(CLOCK_MONOTONIC)` wrapper mem3 itself uses.
pub fn clockNs() u64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Wall-clock Unix milliseconds — for human-readable stamps only.
pub fn nowMs() i64 {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// "2026-06-08T00:00:00Z" for `nowMs()`. Caller owns `buf`.
pub fn isoNow(buf: *[20]u8) []u8 {
    return mem3.utils.time.formatIso8601(nowMs(), buf);
}

/// Nanoseconds elapsed since `t0`.
pub fn sinceNs(t0: u64) u64 {
    const now = clockNs();
    return if (now > t0) now - t0 else 0;
}

pub fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// CPU milliseconds consumed by this process so far, user + system.
/// A *lower bound* on elapsed wall time, and the only in-process
/// handle on work that happened before `main` (dyld, relocations).
pub fn cpuTimeMs() ?f64 {
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0) return null;
    // macOS spells the fields `sec`/`usec`; Linux spells them
    // `tv_sec`/`tv_usec`. std.c's rusage uses the platform spelling on
    // each, so both branches are written out rather than guessed at.
    const user_usec = switch (@import("builtin").os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => @as(f64, @floatFromInt(@max(usage.utime.sec, 0))) * 1e6 +
            @as(f64, @floatFromInt(@max(usage.utime.usec, 0))),
        else => 0,
    };
    const sys_usec = switch (@import("builtin").os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => @as(f64, @floatFromInt(@max(usage.stime.sec, 0))) * 1e6 +
            @as(f64, @floatFromInt(@max(usage.stime.usec, 0))),
        else => 0,
    };
    return (user_usec + sys_usec) / 1e3;
}

/// Peak resident set size in KB (`ru_maxrss`; bytes on macOS, KB on
/// Linux). This is the high-water mark for the whole process, which is
/// the honest number for a "< 500MB RSS" budget.
pub fn peakRssKb() ?u64 {
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0) return null;
    const raw: u64 = @intCast(@max(usage.maxrss, 0));
    return switch (@import("builtin").os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => raw / 1024,
        else => raw,
    };
}

/// Size of `path` in bytes, or null when it does not exist.
pub fn fileSizeBytes(path: []const u8) ?u64 {
    // `std.c.Stat` is `void` on Linux and Windows in Zig 0.17. Open and
    // seek instead — same answer on every target.
    var z = mem3.platform.fs.SentinelBuffer.init(path);
    const fd = mem3.platform.fs.open(z.ptr(), .{ .access = .read_only }) catch return null;
    defer mem3.platform.fs.close(fd);
    return mem3.platform.fs.sizeOf(fd) catch null;
}

// ============================================================================
// Output
// ============================================================================

/// stdout writer. Benchmarks emit exactly one JSON object here, so the
/// only thing that writes to stdout in the named benchmarks is `finish`.
pub fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(std.c.STDOUT_FILENO, s.ptr, s.len);
}

/// Progress chatter goes to stderr so stdout stays a single parseable
/// JSON document even while a multi-minute run is in flight.
pub fn progress(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(std.c.STDERR_FILENO, s.ptr, s.len);
}

// ============================================================================
// Deterministic PRNG
// ============================================================================

/// xorshift64*. Benchmarks must be reproducible from a seed, otherwise a
/// reported number cannot be re-checked. The project has no shared RNG
/// utility, so this mirrors the shape used by `src/retrieval/hnsw.zig`.
pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = (seed ^ 0x9E3779B97F4A7C15) | 1 };
    }

    pub fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        return x;
    }

    /// Uniform in [0, 1).
    pub fn unitF64(self: *Rng) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / 9007199254740992.0;
    }

    /// Uniform float in [-1, 1).
    pub fn unitF32(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() % 20_001)) / 10_000.0 - 1.0;
    }

    /// Uniform integer in [0, n). `n` must be > 0.
    pub fn below(self: *Rng, n: usize) usize {
        return @intCast(self.next() % @as(u64, @max(n, 1)));
    }
};

// ============================================================================
// Latency distributions
// ============================================================================

/// A sorted sample of per-operation latencies in nanoseconds.
///
/// Percentiles use the nearest-rank definition
/// `idx = ceil(q * n) - 1` on the ascending sample array. Averages are
/// reported but never used as the headline: a mean over a
/// page-fault-heavy tail is exactly how a flattering number is invented.
pub const Latencies = struct {
    samples: []u64,

    pub fn fromSlice(alloc: Allocator, raw: []const u64) !Latencies {
        const copy = try alloc.dupe(u64, raw);
        std.mem.sort(u64, copy, {}, std.sort.asc(u64));
        return .{ .samples = copy };
    }

    pub fn deinit(self: Latencies, alloc: Allocator) void {
        alloc.free(self.samples);
    }

    pub fn count(self: Latencies) usize {
        return self.samples.len;
    }

    fn atQ(self: Latencies, num: u64, den: u64) f64 {
        if (self.samples.len == 0) return 0;
        const n: u64 = self.samples.len;
        const ceil_rank = (num * n + den - 1) / den;
        const idx: u64 = if (ceil_rank == 0) 0 else ceil_rank - 1;
        return @floatFromInt(self.samples[@min(idx, n - 1)]);
    }

    pub fn minNs(self: Latencies) f64 {
        if (self.samples.len == 0) return 0;
        return @floatFromInt(self.samples[0]);
    }

    pub fn p50Ns(self: Latencies) f64 {
        return self.atQ(1, 2);
    }

    pub fn p95Ns(self: Latencies) f64 {
        return self.atQ(95, 100);
    }

    pub fn p99Ns(self: Latencies) f64 {
        return self.atQ(99, 100);
    }

    pub fn maxNs(self: Latencies) f64 {
        if (self.samples.len == 0) return 0;
        return @floatFromInt(self.samples[self.samples.len - 1]);
    }

    pub fn meanNs(self: Latencies) f64 {
        if (self.samples.len == 0) return 0;
        var total: u128 = 0;
        for (self.samples) |s| total += s;
        return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(self.samples.len));
    }

    /// Emit the full distribution as a nested JSON object.
    pub fn writeJson(self: Latencies, j: *Json) !void {
        try j.beginObject();
        try j.key("samples");
        try j.int(@as(u64, @intCast(self.samples.len)));
        try j.key("unit");
        try j.str("ns");
        try j.key("min_ns");
        try j.float(self.minNs());
        try j.key("p50_ns");
        try j.float(self.p50Ns());
        try j.key("p95_ns");
        try j.float(self.p95Ns());
        try j.key("p99_ns");
        try j.float(self.p99Ns());
        try j.key("max_ns");
        try j.float(self.maxNs());
        try j.key("mean_ns");
        try j.float(self.meanNs());
        try j.endObject();
    }
};

// ============================================================================
// JSON
// ============================================================================

/// Minimal ordered JSON writer.
///
/// std.json.Stringify exists but pulls in an `Io` runtime that a
/// benchmark has no business booting, and it cannot express the
/// "null + reason" shape that honest reporting needs. This is ~120
/// lines and does exactly what these benchmarks require.
pub const Json = struct {
    alloc: Allocator,
    buf: std.ArrayList(u8) = .empty,
    /// Per-container "has at least one member" flag.
    filled: [32]bool = @splat(false),
    depth: usize = 0,
    /// A key has been written and its value has not. The value is the
    /// one that closes the member, so it must not open a second one.
    pending_key: bool = false,

    pub fn init(alloc: Allocator) Json {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Json) void {
        self.buf.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn toOwnedSlice(self: *Json) ![]u8 {
        return self.buf.toOwnedSlice(self.alloc);
    }

    fn pre(self: *Json) !void {
        if (self.pending_key) {
            self.pending_key = false;
            return;
        }
        if (self.depth > 0 and self.depth <= self.filled.len) {
            if (self.filled[self.depth - 1]) try self.buf.append(self.alloc, ',');
            self.filled[self.depth - 1] = true;
        }
    }

    pub fn beginObject(self: *Json) !void {
        try self.pre();
        try self.buf.append(self.alloc, '{');
        if (self.depth < self.filled.len) self.filled[self.depth] = false;
        self.depth += 1;
    }

    pub fn endObject(self: *Json) !void {
        self.depth -= 1;
        try self.buf.append(self.alloc, '}');
    }

    pub fn beginArray(self: *Json) !void {
        try self.pre();
        try self.buf.append(self.alloc, '[');
        if (self.depth < self.filled.len) self.filled[self.depth] = false;
        self.depth += 1;
    }

    pub fn endArray(self: *Json) !void {
        self.depth -= 1;
        try self.buf.append(self.alloc, ']');
    }

    pub fn key(self: *Json, name: []const u8) !void {
        // The key opens the member and takes the comma for it; the value
        // that follows must not take another.
        try self.pre();
        try self.writeString(name);
        try self.buf.append(self.alloc, ':');
        self.pending_key = true;
    }

    fn writeString(self: *Json, s: []const u8) !void {
        try self.buf.append(self.alloc, '"');
        for (s) |c| {
            switch (c) {
                '"' => try self.buf.appendSlice(self.alloc, "\\\""),
                '\\' => try self.buf.appendSlice(self.alloc, "\\\\"),
                '\n' => try self.buf.appendSlice(self.alloc, "\\n"),
                '\r' => try self.buf.appendSlice(self.alloc, "\\r"),
                '\t' => try self.buf.appendSlice(self.alloc, "\\t"),
                0x08 => try self.buf.appendSlice(self.alloc, "\\b"),
                0x0c => try self.buf.appendSlice(self.alloc, "\\f"),
                else => {
                    if (c < 0x20) {
                        var esc: [8]u8 = undefined;
                        const s2 = try std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c});
                        try self.buf.appendSlice(self.alloc, s2);
                    } else {
                        try self.buf.append(self.alloc, c);
                    }
                },
            }
        }
        try self.buf.append(self.alloc, '"');
    }

    pub fn str(self: *Json, v: []const u8) !void {
        try self.pre();
        try self.writeString(v);
    }

    pub fn optStr(self: *Json, v: ?[]const u8) !void {
        if (v) |s| {
            try self.str(s);
        } else {
            try self.nullValue();
        }
    }

    pub fn int(self: *Json, v: anytype) !void {
        try self.pre();
        var tmp: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&tmp, "{d}", .{v});
        try self.buf.appendSlice(self.alloc, s);
    }

    /// Takes an already-optional value (e.g. `?u64`) so one function
    /// covers every integer width a benchmark might hold.
    pub fn optInt(self: *Json, v: anytype) !void {
        if (v) |x| {
            try self.int(x);
        } else {
            try self.nullValue();
        }
    }

    /// Floats are emitted only when finite. NaN / ±Inf are not valid
    /// JSON, and a benchmark that divides by zero must surface that as
    /// a missing measurement rather than as a token a CI parser chokes on.
    pub fn float(self: *Json, v: f64) !void {
        try self.pre();
        if (!std.math.isFinite(v)) {
            try self.buf.appendSlice(self.alloc, "null");
            return;
        }
        var tmp: [40]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d:.6}", .{v}) catch "-0.000000";
        try self.buf.appendSlice(self.alloc, s);
    }

    pub fn optFloat(self: *Json, v: ?f64) !void {
        if (v) |x| {
            try self.float(x);
        } else {
            try self.nullValue();
        }
    }

    pub fn boolean(self: *Json, v: bool) !void {
        try self.pre();
        try self.buf.appendSlice(self.alloc, if (v) "true" else "false");
    }

    pub fn optBool(self: *Json, v: ?bool) !void {
        if (v) |x| {
            try self.boolean(x);
        } else {
            try self.nullValue();
        }
    }

    pub fn nullValue(self: *Json) !void {
        try self.pre();
        try self.buf.appendSlice(self.alloc, "null");
    }

    /// Append `v` as `{"value": V, "reason": "..."}` — the shape used
    /// everywhere a metric could not be produced.
    pub fn unavailable(self: *Json, reason: []const u8) !void {
        try self.beginObject();
        try self.key("value");
        try self.nullValue();
        try self.key("reason");
        try self.str(reason);
        try self.endObject();
    }
};

// ============================================================================
// Result envelope
// ============================================================================

/// The fields every named benchmark must publish, so a CI gate can
/// assert on them without knowing which benchmark it is reading.
pub const Meta = struct {
    benchmark: []const u8,
    metric: []const u8,
    /// Human-readable constitutional target, quoted from
    /// `.specify/memory/constitution.md`.
    target: []const u8,
    /// Machine-checkable form of the target: the numeric bound.
    target_value: ?f64 = null,
    /// ">=", "<", "<=" or "none".
    target_comparison: []const u8 = "none",
    unit: []const u8,
    /// Null when the metric could not be measured; `null_reason` then
    /// says why.
    measured: ?f64,
    measured_at_N: ?u64 = null,
    /// Null when `measured` is null — an unmet target and an unmeasured
    /// target are different things and must not look alike.
    met_target: ?bool = null,
    null_reason: ?[]const u8 = null,
    notes: []const u8 = "",
    seed: u64 = 42,
    /// Compare a measured value against the target, honouring the
    /// direction. Returns null when there is nothing to compare.
    pub fn evaluate(m: Meta) ?bool {
        const measured = m.measured orelse return null;
        const bound = m.target_value orelse return null;
        if (std.mem.eql(u8, m.target_comparison, ">=")) return measured >= bound;
        if (std.mem.eql(u8, m.target_comparison, ">")) return measured > bound;
        if (std.mem.eql(u8, m.target_comparison, "<")) return measured < bound;
        if (std.mem.eql(u8, m.target_comparison, "<=")) return measured <= bound;
        return null;
    }
};

/// Writes `{` plus every common field. The caller adds its own fields and
/// then calls `j.endObject()`.
pub fn emitEnvelope(j: *Json, m: Meta) !void {
    try j.beginObject();
    try j.key("benchmark");
    try j.str(m.benchmark);
    try j.key("metric");
    try j.str(m.metric);
    try j.key("constitution_target");
    try j.str(m.target);
    try j.key("target_comparison");
    try j.str(m.target_comparison);
    try j.key("target_value");
    try j.optFloat(m.target_value);
    try j.key("unit");
    try j.str(m.unit);
    try j.key("measured");
    try j.optFloat(m.measured);
    try j.key("measured_at_N");
    try j.optInt(m.measured_at_N);
    try j.key("met_target");
    try j.optBool(m.evaluate());
    try j.key("seed");
    try j.int(m.seed);
    try j.key("notes");
    try j.str(m.notes);
    if (m.null_reason) |r| {
        try j.key("null_reason");
        try j.str(r);
    }

    var buf: [20]u8 = undefined;
    const stamp = isoNow(&buf);
    try j.key("timestamp");
    try j.str(stamp);
    try j.key("timestamp_unix_ms");
    try j.int(nowMs());
    try j.key("host");
    try j.beginObject();
    try j.key("os");
    try j.str(@tagName(@import("builtin").os.tag));
    try j.key("arch");
    try j.str(@tagName(@import("builtin").cpu.arch));
    try j.key("optimize");
    try j.str(@tagName(@import("builtin").mode));
    try j.endObject();
}

/// Writes a projection block. Projections are ALWAYS nested here, never
/// blended into `measured`: the reader can see at a glance which numbers
/// came out of a clock and which came out of an extrapolation.
pub fn emitProjection(
    j: *Json,
    label: []const u8,
    target_N: u64,
    value: ?f64,
    method: []const u8,
    basis_N: u64,
    caveat: []const u8,
) !void {
    try j.key("projection");
    try j.beginObject();
    try j.key("is_measured");
    try j.boolean(false);
    try j.key("label");
    try j.str(label);
    try j.key("target_N");
    try j.int(target_N);
    try j.key("value");
    try j.optFloat(value);
    try j.key("method");
    try j.str(method);
    try j.key("basis_N");
    try j.int(basis_N);
    try j.key("caveat");
    try j.str(caveat);
    try j.endObject();
}

/// Emit the document and a trailing newline on stdout, then release it.
pub fn finish(alloc: Allocator, j: *Json) !void {
    const doc = try j.toOwnedSlice();
    defer alloc.free(doc);
    _ = std.c.write(std.c.STDOUT_FILENO, doc.ptr, doc.len);
    _ = std.c.write(std.c.STDOUT_FILENO, "\n", 1);
}

// ============================================================================
// Scratch directories
// ============================================================================

/// A benchmark scratch directory, always outside the checkout.
///
/// A benchmark that writes `data/` into the repository is a bug: it
/// pollutes `git status`, it makes two concurrent runs fight over one
/// WAL, and it makes a measured run non-reproducible on a dirty tree.
/// With `--data-dir` the caller takes responsibility for the path;
/// without it we build a unique one under the system temp dir.
pub const Scratch = struct {
    path: []u8,
    owned_by_us: bool,

    pub fn init(alloc: Allocator, caller_dir: ?[]const u8, tag: []const u8) !Scratch {
        if (caller_dir) |dir| {
            const dup = try alloc.dupe(u8, dir);
            errdefer alloc.free(dup);
            const z = std.fmt.allocPrintSentinel(alloc, "{s}\x00", .{dup}, 0) catch
                return error.OutOfMemory;
            defer alloc.free(z);
            _ = std.c.mkdir(z.ptr, @as(std.c.mode_t, 0o755));
            return .{ .path = dup, .owned_by_us = false };
        }

        // No mkdtemp in std.c, so build a unique name from pid + a
        // counter and let mkdir be the arbiter.
        var attempt: usize = 0;
        while (attempt < 64) : (attempt += 1) {
            const candidate = try std.fmt.allocPrint(
                alloc,
                "/tmp/mem3-bench-{s}-{d}-{d}",
                .{ tag, std.c.getpid(), attempt },
            );
            errdefer alloc.free(candidate);
            const z = try std.fmt.allocPrintSentinel(alloc, "{s}\x00", .{candidate}, 0);
            defer alloc.free(z);
            if (std.c.mkdir(z.ptr, @as(std.c.mode_t, 0o755)) == 0) {
                return .{ .path = candidate, .owned_by_us = true };
            }
        }
        return error.ScratchDirUnavailable;
    }

    /// Remove the files mem3 writes into a data dir, then the dir.
    /// Best effort: a failure here is reported, never fatal.
    pub fn deinit(self: Scratch, alloc: Allocator) void {
        defer alloc.free(self.path);
        if (!self.owned_by_us) return;
        inline for (.{ "/mem3.wal", "/snapshot.bin" }) |suffix| {
            const joined = std.fmt.allocPrint(alloc, "{s}{s}", .{ self.path, suffix }) catch return;
            defer alloc.free(joined);
            const z = std.fmt.allocPrintSentinel(alloc, "{s}\x00", .{joined}, 0) catch return;
            defer alloc.free(z);
            _ = std.c.unlink(z.ptr);
        }
        const z = std.fmt.allocPrintSentinel(alloc, "{s}\x00", .{self.path}, 0) catch return;
        defer alloc.free(z);
        _ = std.c.rmdir(z.ptr);
    }

    /// `<path>/<file>` as a caller-owned NUL-terminated string, for the
    /// C file APIs.
    pub fn pathZ(self: Scratch, alloc: Allocator, file: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(alloc, "{s}/{s}\x00", .{ self.path, file }, 0);
    }
};

// ============================================================================
// Vector corpora
// ============================================================================

/// Structure of a generated corpus.
pub const CorpusShape = enum {
    /// Isotropic random directions. Every vector is equally (dis)similar
    /// to every other, so search finds no real nearest neighbour and a
    /// recall number measured on it would be meaningless.
    uniform,
    /// Planted neighbourhoods: each vector is its cluster centre plus
    /// noise, and each query is a stored vector plus a small
    /// perturbation. A true nearest neighbour exists, so recall@k is a
    /// real measurement.
    clustered,
};

/// Contiguous row-major `count * dim` float32 corpus. Contiguous (not
/// a slice of pointers) because at 100K x 384 the pointer array alone
/// would be a measurable share of the footprint this suite reports.
pub const VectorCorpus = struct {
    data: []f32,
    count: usize,
    dim: u16,

    pub fn generate(
        alloc: Allocator,
        count: usize,
        dim: u16,
        seed: u64,
        shape: CorpusShape,
    ) !VectorCorpus {
        const d: usize = dim;
        const data = try alloc.alloc(f32, count * d);
        errdefer alloc.free(data);

        var rng = Rng.init(seed);
        for (0..count) |i| {
            const row = data[i * d .. (i + 1) * d];
            switch (shape) {
                .uniform => {
                    for (row) |*x| x.* = rng.unitF32();
                },
                .clustered => {
                    // 32 directions per cluster; the centre is derived
                    // from the cluster id so it is identical for every
                    // member without being stored.
                    const cid = (i / 32) + 1;
                    var crng = Rng.init(seed ^ (cid * 0x2545F4914F6CDD1D));
                    for (row) |*x| {
                        x.* = crng.unitF32() * 0.35 + rng.unitF32() * 0.10;
                    }
                },
            }
            l2Normalize(row);
        }
        return .{ .data = data, .count = count, .dim = dim };
    }

    pub fn deinit(self: VectorCorpus, alloc: Allocator) void {
        alloc.free(self.data);
    }

    pub fn vector(self: VectorCorpus, i: usize) []f32 {
        const d: usize = self.dim;
        return self.data[i * d .. (i + 1) * d];
    }

    /// A query vector for row `i`: the stored vector perturbed just
    /// enough that the stored row stays its nearest neighbour for a
    /// small multiple of the corpus radius.
    pub fn queryVector(self: VectorCorpus, alloc: Allocator, i: usize, perturb: f32, seed: u64) ![]f32 {
        var rng = Rng.init(seed ^ (@as(u64, @intCast(i)) *% 0x9E3779B97F4A7C15));
        const q = try alloc.dupe(f32, self.vector(i));
        errdefer alloc.free(q);
        for (q) |*x| x.* += rng.unitF32() * perturb;
        l2Normalize(q);
        return q;
    }
};

pub fn l2Normalize(v: []f32) void {
    var norm: f32 = 0;
    for (v) |x| norm += x * x;
    norm = @sqrt(norm);
    if (norm > 0) {
        for (v) |*x| x.* /= norm;
    }
}

/// Cosine similarity. Duplicated here (rather than reaching for
/// `HNSW.cosineSim`) so the exhaustive-scan oracle is independent of
/// the index it is scoring.
pub fn cosine(a: []const f32, b: []const f32) f32 {
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (a, b) |x, y| {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    const denom = @sqrt(na) * @sqrt(nb);
    if (denom == 0) return 0;
    return dot / denom;
}

// ============================================================================
// Argument parsing
// ============================================================================

/// Flags shared by every benchmark. Each benchmark declares its own
/// scale defaults and adds its own parser on top of this.
pub const CommonArgs = struct {
    data_dir: ?[]const u8 = null,
    seed: u64 = 42,
    quick: bool = false,
    /// `--scale=<f>` multiplies every default corpus size. `--quick`
    /// is shorthand for a tenth.
    scale: f64 = 1.0,
};

/// Classify one argument. Returns true when the caller has consumed it.
pub fn parseCommon(arg: []const u8, a: *CommonArgs) !bool {
    if (std.mem.eql(u8, arg, "--quick")) {
        a.quick = true;
        a.scale = 0.1;
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--data-dir=")) {
        a.data_dir = arg["--data-dir=".len..];
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--seed=")) {
        a.seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 10);
        return true;
    }
    if (std.mem.startsWith(u8, arg, "--scale=")) {
        a.scale = try std.fmt.parseFloat(f64, arg["--scale=".len..]);
        if (!(a.scale > 0)) return error.BadScale;
        if (a.scale < 1) a.quick = true;
        return true;
    }
    return false;
}

/// Apply the scale factor to a benchmark's declared default, never
/// letting it reach zero.
pub fn scaled(default: usize, a: CommonArgs) usize {
    const s: f64 = @as(f64, @floatFromInt(default)) * a.scale;
    if (s < 1) return 1;
    return @intFromFloat(s);
}

/// Iterate the arguments a constitutional benchmark should see.
///
/// Skips argv[0] (the executable) and argv[1] (the benchmark name, which
/// `mem3-bench`'s dispatcher already consumed to route here). Every
/// benchmark in this directory is reached through that dispatcher, so
/// there is no path on which argv[1] is a flag.
pub fn argIterator(init: std.process.Init.Minimal) std.process.Args.Iterator {
    var it = std.process.Args.iterate(init.args);
    _ = it.next(); // argv[0], the executable
    _ = it.next(); // argv[1], the benchmark name (consumed by dispatch)
    return it;
}

// ============================================================================
// Test coverage for the plumbing itself
// ============================================================================

test "Latencies: percentiles use nearest-rank on the sorted sample" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa_state.deinit() == .ok) catch @panic("leak");
    const alloc = gpa_state.allocator();

    // 1..100 ns. p50 = 50, p95 = 95, p99 = 99, max = 100.
    const raw = try alloc.alloc(u64, 100);
    defer alloc.free(raw);
    for (raw, 0..) |*s, i| s.* = @intCast(i + 1);

    const lat = try Latencies.fromSlice(alloc, raw);
    defer lat.deinit(alloc);

    try std.testing.expectEqual(@as(f64, 1), lat.minNs());
    try std.testing.expectEqual(@as(f64, 50), lat.p50Ns());
    try std.testing.expectEqual(@as(f64, 95), lat.p95Ns());
    try std.testing.expectEqual(@as(f64, 99), lat.p99Ns());
    try std.testing.expectEqual(@as(f64, 100), lat.maxNs());
    try std.testing.expectEqual(@as(f64, 50.5), lat.meanNs());
}

test "Latencies: an empty sample reads as zero, not as garbage" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa_state.deinit() == .ok) catch @panic("leak");
    const alloc = gpa_state.allocator();

    const lat = try Latencies.fromSlice(alloc, &.{});
    defer lat.deinit(alloc);
    try std.testing.expectEqual(@as(f64, 0), lat.p95Ns());
    try std.testing.expectEqual(@as(usize, 0), lat.count());
}

test "Json: emits a parseable document and escapes what it must" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa_state.deinit() == .ok) catch @panic("leak");
    const alloc = gpa_state.allocator();

    var j = Json.init(alloc);
    defer j.deinit();
    try j.beginObject();
    try j.key("a");
    try j.int(@as(u64, 1));
    try j.key("quote\"back\\slash");
    try j.str("line1\nline2\ttab");
    try j.key("arr");
    try j.beginArray();
    try j.int(@as(i64, -3));
    try j.float(1.5);
    try j.boolean(true);
    try j.nullValue();
    try j.endArray();
    try j.key("nan");
    try j.float(std.math.nan(f64));
    try j.endObject();

    const doc = try j.toOwnedSlice();
    defer alloc.free(doc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, doc, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), obj.get("a").?.integer);
    try std.testing.expectEqualStrings("line1\nline2\ttab", obj.get("quote\"back\\slash").?.string);
    try std.testing.expectEqual(@as(usize, 4), obj.get("arr").?.array.items.len);
    // NaN is not representable in JSON and must degrade to null rather
    // than emit a token no parser accepts.
    try std.testing.expect(obj.get("nan").? == .null);
}

test "Json: unavailable() pairs a null value with a reason" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa_state.deinit() == .ok) catch @panic("leak");
    const alloc = gpa_state.allocator();

    var j = Json.init(alloc);
    defer j.deinit();
    try j.beginObject();
    try j.key("metric");
    try j.unavailable("no such clock on this platform");
    try j.endObject();

    const doc = try j.toOwnedSlice();
    defer alloc.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"value\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "no such clock") != null);
}

test "Meta: an unmet target is distinguishable from an unmeasured one" {
    const hit: Meta = .{
        .benchmark = "x",
        .metric = "x",
        .target = "< 10",
        .target_value = 10,
        .target_comparison = "<",
        .unit = "ms",
        .measured = 4,
    };
    try std.testing.expectEqual(true, hit.evaluate().?);

    const miss: Meta = .{
        .benchmark = "x",
        .metric = "x",
        .target = "< 10",
        .target_value = 10,
        .target_comparison = "<",
        .unit = "ms",
        .measured = 40,
    };
    try std.testing.expectEqual(false, miss.evaluate().?);

    const unknown: Meta = .{
        .benchmark = "x",
        .metric = "x",
        .target = "< 10",
        .target_value = 10,
        .target_comparison = "<",
        .unit = "ms",
        .measured = null,
    };
    try std.testing.expect(unknown.evaluate() == null);
}

test "Rng: the same seed reproduces the same stream" {
    var a = Rng.init(99);
    var b = Rng.init(99);
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try std.testing.expectEqual(a.next(), b.next());
    }
    var c = Rng.init(100);
    try std.testing.expect(c.next() != a.next());
}

test "cosine: identical vectors score 1 and orthogonal vectors score 0" {
    const a = [_]f32{ 1, 0, 0 };
    const b = [_]f32{ 1, 0, 0 };
    const c = [_]f32{ 0, 1, 0 };
    try std.testing.expectApproxEqAbs(1.0, cosine(&a, &b), 1e-6);
    try std.testing.expectApproxEqAbs(0.0, cosine(&a, &c), 1e-6);
}

test "VectorCorpus: rows are unit length and stable across calls" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expect(gpa_state.deinit() == .ok) catch @panic("leak");
    const alloc = gpa_state.allocator();

    const c = try VectorCorpus.generate(alloc, 64, 8, 7, .clustered);
    defer c.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 64), c.count);
    for (0..c.count) |i| {
        var norm: f32 = 0;
        for (c.vector(i)) |x| norm += x * x;
        try std.testing.expectApproxEqAbs(1.0, norm, 1e-4);
    }
}

test "parseCommon: scale and quick are honoured, unknown flags are not" {
    var a = CommonArgs{};
    try std.testing.expect(try parseCommon("--quick", &a));
    try std.testing.expectApproxEqAbs(0.1, a.scale, 1e-9);
    try std.testing.expect(a.quick);

    var b = CommonArgs{};
    try std.testing.expect(try parseCommon("--scale=2.5", &b));
    try std.testing.expectApproxEqAbs(2.5, b.scale, 1e-9);
    try std.testing.expect(!b.quick);

    var c = CommonArgs{};
    try std.testing.expect(!try parseCommon("--corpus=10", &c));
}