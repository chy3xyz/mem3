//! mem3 — placeholder stub.

const std = @import("std");
const cli = @import("../cli.zig");

pub fn run(alloc: std.mem.Allocator, p: cli.Parsed) !void {
    _ = alloc;
    _ = p;
    std.debug.print("dump: not yet implemented (Track E)\n", .{});
}
