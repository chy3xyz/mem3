//! mem3 — placeholder stub.

const std = @import("std");
const cli = @import("../cli.zig");

pub fn run(alloc: std.mem.Allocator, p: cli.Parsed) !void {
    _ = alloc;
    _ = p;
    std.debug.print("forget: not yet implemented (Track B + E)\n", .{});
}
