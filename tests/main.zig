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

/// See `src/main.zig` for why this exists. Under `--listen=-` any stderr
/// write from inside a test desynchronises the runner↔build protocol, so
/// the test binary aborts and `zig build test` reports success anyway.
pub const std_options: std.Options = .{
    .log_level = .err,
};

comptime {
    // Unit tests — per-module focused coverage of core algorithms.
    _ = @import("unit/coherence.zig");
    _ = @import("unit/consolidator.zig");
    _ = @import("unit/consolidator_incremental.zig");
    _ = @import("unit/hnsw.zig");
    // The CLI argument parser. Zero tests previously, across 223 lines of
    // hand-rolled flag handling; three real parser bugs were found the day
    // this was added.
    _ = @import("unit/cli.zig");

    // Integration tests — end-to-end scenarios through Store /
    // HTTP server. Slow but high signal.
    _ = @import("integration/store_persistence_e2e.zig");
    _ = @import("integration/http_server_e2e.zig");

    // Property-based tests — randomized round-trip coverage of the
    // comptime serializer.
    _ = @import("property/serializer_roundtrip.zig");
    // Adjoint-pair sanity checks required by constitution Principle VI:
    // Encode ∘ Decode ≈ id, and the Decode ∘ Encode ≤ id approximation.
    _ = @import("property/adjoint.zig");
}

test "tests runner: all import paths resolved" {
    // This sentinel test exists so the test runner has at least one
    // named test even if every imported file's tests get skipped
    // (e.g. via a `--test-filter` regex that doesn't match anything).
    try std.testing.expect(true);
}
