//! CLI implementation for `mem3 consolidate`.
//!
//! Per spec: `mem3 consolidate` runs the HAC clustering + abstract
//! generation over the corpus. Returns the number of abstract cells
//! created (1 per cluster of ≥ 2 cells with C_MF ≥ threshold).
//!
//! Prints a one-line summary in human mode, or JSON with the count
//! under `--json`.

const std = @import("std");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const Store = @import("../store/mod.zig").Store;

pub fn run(alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    var store = try cli_common.openStore(alloc, parsed);
    defer store.deinit();

    const before = store.cellCount();
    const abstracts = try store.consolidate();
    const after = store.cellCount();

    if (parsed.json) {
        var buf: [256]u8 = undefined;
        // SAFETY: three usize counters (each <= 20 digits on a 64-bit
        // target) plus a 62-byte literal -> worst case 122 bytes into a
        // 256-byte buffer.
        const s = std.fmt.bufPrint(
            &buf,
            "{{\"abstracts_created\":{d},\"cells_before\":{d},\"cells_after\":{d}}}",
            .{ abstracts, before, after },
        ) catch unreachable;
        cli_common.println(s);
    } else {
        var buf: [256]u8 = undefined;
        // SAFETY: three usize counters (each <= 20 digits) plus a 56-byte
        // literal -> worst case 116 bytes into a 256-byte buffer.
        const s = std.fmt.bufPrint(
            &buf,
            "consolidate: abstracts_created={d}\n  cells: {d} -> {d}",
            .{ abstracts, before, after },
        ) catch unreachable;
        cli_common.println(s);
    }
}