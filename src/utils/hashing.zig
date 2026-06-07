//! Hashing primitives. xxHash3 is the v0.1.0 default (fast, non-cryptographic).
//!
//! Constitution: avoid pulling in OpenSSL/SHA. xxHash3 is a single-file
//! algorithm with a small implementation footprint, perfect for the
//! HNSW deterministic embedder stub and WAL checksums.

const std = @import("std");

/// xxHash3 64-bit non-secret hash. Self-contained, no external dep.
pub fn xxh3_64bits(input: []const u8) u64 {
    return std.hash.XxHash3.hash(0, input);
}

/// Stable per-string hash (for HNSW stub embedder, where we want the same
/// string to always map to the same vector).
pub fn stableHash(s: []const u8) u64 {
    return xxh3_64bits(s);
}

/// Combine two hashes (for chaining keys).
pub fn combine(a: u64, b: u64) u64 {
    var h = std.hash.XxHash3.init();
    h.update(&std.mem.toBytes(a));
    h.update(&std.mem.toBytes(b));
    return h.final();
}

test "xxh3_64bits: deterministic and non-zero" {
    const a = xxh3_64bits("hello");
    const b = xxh3_64bits("hello");
    const c = xxh3_64bits("world");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
    try std.testing.expect(a != 0);
}

test "combine: not equal to either input" {
    const h = combine(0x1234, 0x5678);
    try std.testing.expect(h != 0x1234);
    try std.testing.expect(h != 0x5678);
}
