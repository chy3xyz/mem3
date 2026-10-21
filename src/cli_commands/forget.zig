//! CLI implementation for `mem3 forget`.
//!
//! Per spec: `mem3 forget [--dry-run]` runs the existence-gain-driven
//! sweeping pass (`net_existence = importance - redundancy - conflict_score`)
//! and reports how many cells were fuzzied vs kept, and *why*:
//!
//!   * `decayed`    - `importance * exp(-decay * age) < threshold`
//!   * `redundant`  - a more important near-duplicate already says it
//!   * `conflicted` - a newer cell contradicts every fact it holds and
//!                    matters more (it is marked `superseded_at`, not deleted)
//!   * `superseded` - cells the sweep newly marked superseded (they stay
//!                    active unless they are also `conflicted`)
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

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    if (parsed.json) {
        // The first five keys are the original contract and keep their order
        // and meaning; `reasons` / `superseded` are additive.
        try cli_common.appendFmt(
            &buf,
            alloc,
            "{{\"dry_run\":{},\"fuzzied\":{d},\"kept\":{d},\"active\":{d},\"fuzzy\":{d}," ++
                "\"reasons\":{{\"decayed\":{d},\"redundant\":{d},\"conflicted\":{d}}},\"superseded\":{d}}}",
            .{
                parsed.dry_run,                result.fuzzied,   result.kept,       store.cellCount(), store.lc.fuzzy.count(),
                result.decayed,                result.redundant, result.conflicted, result.superseded,
            },
        );
        cli_common.println(buf.items);
        return;
    }

    try cli_common.appendFmt(&buf, alloc, "forget: dry_run={}\n", .{parsed.dry_run});
    try cli_common.appendFmt(&buf, alloc, "  fuzzied:    {d}\n", .{result.fuzzied});
    try cli_common.appendFmt(&buf, alloc, "    decayed:    {d}\n", .{result.decayed});
    try cli_common.appendFmt(&buf, alloc, "    redundant:  {d}\n", .{result.redundant});
    try cli_common.appendFmt(&buf, alloc, "    conflicted: {d}\n", .{result.conflicted});
    try cli_common.appendFmt(&buf, alloc, "  superseded: {d} (newly marked, not deleted)\n", .{result.superseded});
    try cli_common.appendFmt(&buf, alloc, "  kept:       {d}\n", .{result.kept});
    try cli_common.appendFmt(&buf, alloc, "  active:     {d}\n", .{store.cellCount()});
    try cli_common.appendFmt(&buf, alloc, "  fuzzy:      {d}", .{store.lc.fuzzy.count()});
    cli_common.println(buf.items);
}
