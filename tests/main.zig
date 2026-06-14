//! Master test runner for the tests/ tree.
//!
//! Imports every test in tests/unit/, tests/integration/, and
//! tests/property/ so that `zig build test --test-filter X` (and the
//! raw `zig build test`) collect them all.
//!
//! Tests in `tests/constitution/` are still run separately via
//! `zig build check-constitution` to keep them as a distinct gate
//! (Constitution Principle VI: separate, more visible CI step).

const std = @import("std");

comptime {
    // Unit tests — per-module focused coverage of core algorithms.
    _ = @import("unit/coherence.zig");
    _ = @import("unit/consolidator.zig");
    _ = @import("unit/hnsw.zig");

    // Integration tests — end-to-end scenarios through Store /
    // HTTP server. Slow but high signal.
    _ = @import("integration/store_persistence_e2e.zig");
    _ = @import("integration/http_server_e2e.zig");

    // Property-based tests — randomized round-trip coverage of the
    // comptime serializer.
    _ = @import("property/serializer_roundtrip.zig");
}

test "tests runner: all import paths resolved" {
    // This sentinel test exists so the test runner has at least one
    // named test even if every imported file's tests get skipped
    // (e.g. via a `--test-filter` regex that doesn't match anything).
    try std.testing.expect(true);
}