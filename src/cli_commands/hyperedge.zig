//! mem3 — placeholder stub.
//! Implementation lands in Track C (HyMem) + Track E.

const std = @import("std");
const cli = @import("../cli.zig");

pub fn run(alloc: std.mem.Allocator, p: cli.Parsed) !void {
    _ = alloc;
    _ = p;
    std.debug.print("hyperedge: not yet implemented (Track C + E)\n", .{});
}
