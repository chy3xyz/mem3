//! mem3 — placeholder stub.
//! Implementation lands in Track E.

const std = @import("std");
const cli = @import("../cli.zig");

pub fn run(alloc: std.mem.Allocator, p: cli.Parsed) !void {
    _ = alloc;
    _ = p;
    std.debug.print("query: not yet implemented (Track E)\n", .{});
}
