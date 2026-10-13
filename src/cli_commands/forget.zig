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
        // SAFETY: four usize counters (each <= 20 digits) plus a bool
        // ("true"/"false", <= 5 bytes) plus a 64-byte literal -> worst
        // case 149 bytes into a 256-byte buffer.
        const s = std.fmt.bufPrint(
            &buf,
            "{{\"dry_run\":{},\"fuzzied\":{d},\"kept\":{d},\"active\":{d},\"fuzzy\":{d}}}",
            .{ parsed.dry_run, result.fuzzied, result.kept, store.cellCount(), store.lc.fuzzy.count() },
        ) catch unreachable;
        cli_common.println(s);
    } else {
        var buf: [256]u8 = undefined;
        // SAFETY: each line below interpolates exactly one usize counter
        // (<= 20 digits) or a bool (<= 5 bytes) against a literal of at
        // most 16 bytes, so the longest line is 36 bytes into a 256-byte
        // buffer. The same `buf` is reused only after its previous
        // contents have already been printed.
        const w1 = std.fmt.bufPrint(&buf, "forget: dry_run={}", .{parsed.dry_run}) catch unreachable;
        cli_common.println(w1);
        // SAFETY: `  fuzzied: ` is 11 bytes + <= 20 digits = 31 bytes.
        const w2 = std.fmt.bufPrint(&buf, "  fuzzied: {d}", .{result.fuzzied}) catch unreachable;
        cli_common.println(w2);
        // SAFETY: `  kept:    ` is 11 bytes + <= 20 digits = 31 bytes.
        const w3 = std.fmt.bufPrint(&buf, "  kept:    {d}", .{result.kept}) catch unreachable;
        cli_common.println(w3);
        // SAFETY: `  active:  ` is 11 bytes + <= 20 digits = 31 bytes.
        const w4 = std.fmt.bufPrint(&buf, "  active:  {d}", .{store.cellCount()}) catch unreachable;
        cli_common.println(w4);
        // SAFETY: `  fuzzy:   ` is 11 bytes + <= 20 digits = 31 bytes.
        const w5 = std.fmt.bufPrint(&buf, "  fuzzy:   {d}", .{store.lc.fuzzy.count()}) catch unreachable;
        cli_common.println(w5);
    }
}