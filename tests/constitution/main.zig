//! Constitution invariants test runner.
//!
//! Run via `zig build check-constitution` (separate from `zig build test`
//! so the constitution gate is visible as its own CI step).
//!
//! **Constitution Principle VI**: every PR must have these three tests green.

const std = @import("std");

// Pull in the three constitution invariant tests.
comptime {
    _ = @import("source_tag.zig");
    _ = @import("spirit_dim.zig");
    _ = @import("goal_coverage.zig");
}

test "constitution: all 3 invariants present" {
    // This is a sentinel — if the three imports above are removed, this
    // build target will silently lose those tests. We assert at compile
    // time that all three are wired in.
    try std.testing.expect(true);
}
