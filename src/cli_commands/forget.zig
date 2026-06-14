//! CLI implementation for `mem3 forget`.
//!
//! Per spec: `mem3 forget [--dry-run]` runs the existence-gain-driven
//! sweeping pass and reports how many cells were fuzzied vs kept.
//!
//! In `--dry-run` mode no state is mutated; otherwise cells move from
//! the active store to the FuzzyStore (PCR: never delete).

const std = @import("std");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const Store = @import("../store/mod.zig").Store;

pub fn run(alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    var store = try cli_common.openStore(alloc, parsed);
    defer store.deinit();

    const result = try store.forget(parsed.dry_run);

    if (parsed.json) {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(
            &buf,
            "{{\"dry_run\":{},\"fuzzied\":{d},\"kept\":{d},\"active\":{d},\"fuzzy\":{d}}}",
            .{ parsed.dry_run, result.fuzzied, result.kept, store.cellCount(), store.lc.fuzzy.count() },
        ) catch unreachable;
        cli_common.println(s);
    } else {
        var buf: [256]u8 = undefined;
        const w1 = std.fmt.bufPrint(&buf, "forget: dry_run={}", .{parsed.dry_run}) catch unreachable;
        cli_common.println(w1);
        const w2 = std.fmt.bufPrint(&buf, "  fuzzied: {d}", .{result.fuzzied}) catch unreachable;
        cli_common.println(w2);
        const w3 = std.fmt.bufPrint(&buf, "  kept:    {d}", .{result.kept}) catch unreachable;
        cli_common.println(w3);
        const w4 = std.fmt.bufPrint(&buf, "  active:  {d}", .{store.cellCount()}) catch unreachable;
        cli_common.println(w4);
        const w5 = std.fmt.bufPrint(&buf, "  fuzzy:   {d}", .{store.lc.fuzzy.count()}) catch unreachable;
        cli_common.println(w5);
    }
}