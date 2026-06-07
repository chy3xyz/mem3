//! mem3 — placeholder stub.
//! Implementation lands in Track A (uses Goal Poset) + Track E.

const std = @import("std");
const cli = @import("../cli.zig");

pub fn run(alloc: std.mem.Allocator, p: cli.Parsed) !void {
    _ = alloc;
    _ = p;
    std.debug.print("goal: not yet implemented (Track A + E)\n", .{});
}
