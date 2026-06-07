//! Deterministic stub embedder — xxHash3-derived 384-dim vectors.
//!
//! v0.1.0 ships with this stub. v0.2.0 will replace it with a real
//! ONNX model loaded at startup. The stub is deterministic (same input
//! → same vector), enabling reproducible tests without ML.

const std = @import("std");
const Allocator = std.mem.Allocator;
const hashing = @import("../utils/hashing.zig");

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
