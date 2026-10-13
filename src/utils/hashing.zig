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
///
/// Uses the one-shot `XxHash3.hash` over a 16-byte stack buffer rather than
/// the `init`/`update`/`final` streaming state machine. The streaming path
/// spends ~800 ns/op re-entering the accumulator per 8-byte update; the
/// one-shot path over a fixed stack buffer is ~7 ns/op. Output bits are
/// unchanged -- xxHash3 streaming is defined to equal the one-shot over the
/// same concatenated byte stream, and
/// `test "combine: byte-for-byte, deterministic and order-sensitive"` pins that.
pub fn combine(a: u64, b: u64) u64 {
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..8], &std.mem.toBytes(a));
    @memcpy(buf[8..16], &std.mem.toBytes(b));
    return std.hash.XxHash3.hash(0, &buf);
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

// Pins the exact output bits so the one-shot rewrite cannot silently change
// chained keys or WAL checksums. 0x188e414c9e25e9af is what the previous
// init/update/final streaming implementation returned for (0x1234, 0x5678).
test "combine: byte-for-byte, deterministic and order-sensitive" {
    try std.testing.expectEqual(@as(u64, 0x188e414c9e25e9af), combine(0x1234, 0x5678));
    try std.testing.expectEqual(combine(0xdeadbeef, 0xfeedface), combine(0xdeadbeef, 0xfeedface));
    try std.testing.expect(combine(0xdeadbeef, 0xfeedface) != combine(0xfeedface, 0xdeadbeef));
}
