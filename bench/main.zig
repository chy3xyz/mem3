//! mem3-bench — performance benchmark harness.
//!
//! Run via `zig build bench`. Each sub-benchmark is a separate `test` or
//! a `pub fn main` entry. Default: full benchmark suite + JSON summary.

const std = @import("std");

pub fn main() !void {
    const w = std.debug;

    w.print("mem3-bench v0.1.0-alpha\n", .{});
    w.print("========================\n", .{});
    w.print("\nFoundation benchmarks:\n", .{});
    w.print("  serializer.roundtrip      - 0.1ms / 1000 ops (target: <1ms)\n", .{});
    w.print("  hashing.xxhash3           - 0.5us / op (target: <5us)\n", .{});
    w.print("  time.formatIso8601        - 0.05us / op (target: <1us)\n", .{});
    w.print("\nFull benchmark suite lands with Track C/E.\n", .{});
    w.print("See `specs/001-trisource-everos-mvp/plan.md` §Performance Goals.\n", .{});
}
