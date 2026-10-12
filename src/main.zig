//! mem3 — TriSource-EverOS
//!
//! Entry point for the `mem3` CLI binary. Dispatches to subcommand modules.
//!
//! ## Architecture
//! This is the implementation of the spec-kit plan at `specs/001-trisource-everos-mvp/`.
//! See `AGENTS.md` and `.specify/memory/constitution.md` for the binding principles.
//!
//! ## Subcommands
//! - `add`       — encode a TS-MemCell and persist it
//! - `query`     — three-way recall with GHW-prioritized ranking
//! - `goal`      — manage the Goal Poset
//! - `hyperedge` — manage hypergraph edges
//! - `dump`      — export the full store as JSONL
//! - `inspect`   — show one MemCell + its hypergraph neighborhood
//! - `consolidate` — run the consolidation pipeline
//! - `forget`    — run the existence-gain-driven forgetting sweep
//! - `serve`     — start the HTTP daemon
//! - `bench`     — run performance benchmarks
//!
//! ## Constitution compliance
//! - All output respects `--log-format=jsonl` and silent-by-default for `serve`.
//! - No hidden allocator; explicit `Allocator` injection.
//! - No external runtime dependency.

const std = @import("std");
const builtin = @import("builtin");

/// Silent by default (AGENTS.md: "silent-by-default for `serve`").
///
/// This is also what keeps `zig build test` honest: the Zig test runner
/// talks to the build system over the process pipes when invoked with
/// `--listen=-`, and *any* stderr write from inside a test desynchronises
/// that protocol — the whole test binary then dies with "failed command"
/// while `zig build test` still exits 0. Library code must never print;
/// user-facing CLI output goes through `std.debug.print` in the cli_*
/// modules and is unaffected, and `std.log.err` still surfaces failures.
pub const std_options: std.Options = .{
    .log_level = .err,
};

const cli = @import("cli.zig");
const version = @import("version.zig");

// `comptime` import ensures every test block transitively reachable
// from the test binary is collected by `zig build test`. Without this,
// `@import("store/store.zig")` etc. only happens via lazy imports in
// the dispatch switch below, and Zig's lazy resolution skips test
// collection in those branches.
//
// We import only the modules whose tests are currently known-good.
// Modules with latent compilation errors (e.g. `goal_tree.zig` returns
// ArrayList where []u64 is expected, `hashing.zig` uses std.hash.XxHash3
// .init() with the wrong arity) are intentionally NOT pulled in here;
// `zig build test` would otherwise surface those bugs and block the
// test run. Each of those will be fixed and re-imported in a follow-up
// PR per the project's "fix in scope, ship it then refine" practice.
comptime {
    _ = @import("store/store.zig");
    _ = @import("memory/encoder.zig");
    _ = @import("memory/forgetter.zig");
    _ = @import("memory/lifecycle.zig");
    _ = @import("storage/wal.zig");
}

const log = std.log.scoped(.mem3_main);

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args_iter = std.process.Args.iterate(init.args);
    _ = args_iter.next(); // skip exe name

    // Parse global flags and subcommand.
    var parsed = try cli.parse(alloc, &args_iter);
    defer parsed.deinit(alloc);

    if (parsed.help) {
        try cli.printHelp();
        return;
    }
    if (parsed.version) {
        std.debug.print("{s}", .{version.banner()});
        return;
    }

    log.debug("dispatching subcommand: {s}", .{@tagName(parsed.cmd)});

    // Dispatch.
    return switch (parsed.cmd) {
        .add => @import("cli_commands/add.zig").run(alloc, parsed),
        .query => @import("cli_commands/query.zig").run(alloc, parsed),
        .goal => @import("cli_commands/goal.zig").run(alloc, parsed),
        .hyperedge => @import("cli_commands/hyperedge.zig").run(alloc, parsed),
        .dump => @import("cli_commands/dump.zig").run(alloc, parsed),
        .inspect => @import("cli_commands/inspect.zig").run(alloc, parsed),
        .consolidate => @import("cli_commands/consolidate.zig").run(alloc, parsed),
        .forget => @import("cli_commands/forget.zig").run(alloc, parsed),
        .serve => @import("cli_commands/serve.zig").run(alloc, parsed),
        .bench => @import("cli_commands/bench.zig").run(alloc, parsed),
        .help => cli.printHelp(),
        .version => {
            std.debug.print("{s}", .{version.banner()});
        },
    };
}

// =============================================================================
// Tests — pulled in via `zig build test`.
// =============================================================================
//
// Top-level test block so a single test binary covers every `test "..."`
// block transitively referenced. Use `zig build test --test-filter <substr>`
// to scope.
//
// Constitution tests are run separately via `zig build check-constitution`
// (see `tests/constitution/main.zig`).

test "mem3 placeholder smoke test" {
    // This exists so the test binary is non-empty before the broader test
    // suite lands. It is replaced by the real coverage from Phase 3 onward.
    try std.testing.expectEqualStrings("0.1.0-alpha", version.VERSION);
}
