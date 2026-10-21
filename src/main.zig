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
//! - `unsupersede` — restore a cell a newer fact wrongly superseded
//! - `serve`     — start the HTTP daemon
//! - `mcp`       — serve the Model Context Protocol over stdio
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
// Every module listed below now compiles and its tests pass. An earlier
// revision of this block withheld `goal_tree.zig` and `hashing.zig` on the
// claim that they had latent compilation errors; both were false — they
// were simply never imported, so the errors described in that comment
// could not have been observed. Naming them exposed the real defects and
// both are fixed. Do not re-add an exclusion comment here without a
// compile error to point at; "not yet tested" is not a reason to stay out
// of the gate.
comptime {
    _ = @import("store/store.zig");
    _ = @import("memory/encoder.zig");
    _ = @import("memory/forgetter.zig");
    _ = @import("memory/conflict.zig");
    _ = @import("memory/redundancy.zig");
    _ = @import("memory/lifecycle.zig");
    _ = @import("storage/wal.zig");
    // `snapshot.zig` carries the durability round-trip test but was not
    // named here, so — by the one-level collection rule — it never ran.
    _ = @import("storage/snapshot.zig");
    // `cli_commands/*.zig` are reached only through the lazy `@import`
    // in `main`'s dispatch switch, so a `test` block in one of them is
    // never compiled by `zig build test` and silently never runs. That
    // is how a whole CLI module could sit outside the gate without
    // anyone noticing. Import the ones that now carry tests.
    _ = @import("cli_commands/goal.zig");
    // `add.zig` is the single most-used command in the product and carried
    // zero tests; the only other reference is the dispatch switch inside
    // `main`, which never registers a test block. Same trap as `goal.zig`.
    _ = @import("cli_commands/add.zig");
    // `dump.zig` had no tests until the foresight one; same reachability
    // trap as `add.zig` (only the dispatch switch referenced it).
    _ = @import("cli_commands/dump.zig");
    // Same trap, different victim: `lib.zig` re-exports
    // `retrieval.RerankContext`, but a re-export does not pull a
    // module's `test` blocks into the test binary — verified: with
    // only this file listed, the reranker's tests ran in zero binaries.
    _ = @import("retrieval/reranker.zig");
    // And again, with the daemon as the victim. `tests/main.zig` reaches
    // the server through the `mem3` *module*, and Zig does not collect
    // `test` blocks out of module dependencies — only out of the root
    // source file's own import graph. `tests/integration/http_server_e2e.zig`
    // therefore exercised the HTTP surface over a subprocess without ever
    // compiling the three in-process tests sitting in this file, including
    // the regression guard for the sync-deletes-goals bug.
    //
    // Proven, not assumed: renaming `srv.store.takeSnapshot()` in the test
    // below to a method that does not exist still gave `zig build test`
    // exit 0. A green suite that cannot fail is worse than no suite.
    _ = @import("server/http_server.zig");

    // The portability layer, and the comptime serializer.
    //
    // These are named at the TOP level of this block on purpose: Zig
    // collects `test` blocks only from files named **directly** in the root
    // source file's comptime block. A file reached one level deeper is
    // analysed but its tests are never registered with the runner. That is
    // why `platform/mod.zig`'s own re-export of `fs.zig` is not enough —
    // the four sub-modules have to be named here.
    _ = @import("platform/clock.zig");
    _ = @import("platform/fs.zig");
    _ = @import("platform/stdio.zig");
    _ = @import("platform/env.zig");
    _ = @import("platform/signal.zig");
    _ = @import("platform/mod.zig");
    // `utils/serializer.zig` was likewise outside the gate entirely, which
    // is how a size-accounting defect that silently dropped every
    // `?[]const u8` payload survived — the tests that would have caught it
    // were never run.
    _ = @import("utils/serializer.zig");

    // Everything below was reachable from the library and therefore looked
    // tested. It was not: 87 `test` blocks across these 19 files were
    // compiled by nothing and run by nobody. `src/lib.zig` re-exports most
    // of them, which is the trap — a `pub const` re-export pulls a file
    // into the *build* but never registers its tests with the runner.
    //
    // This is not hypothetical. `ghw/goal_tree.zig` carried the tests for
    // the goal-poset invariants, including the 7-day unrealized rule and
    // the duplicate-bind guarantee, and none of them had ever run.
    //
    // Naming them is the only thing that works. The probe that proves it:
    // rename a method call inside one of these tests to something that does
    // not exist and confirm `zig build test` goes red. It stays green only
    // for files that are not listed here.
    _ = @import("core/types.zig");
    _ = @import("core/memcell.zig");
    _ = @import("core/ids.zig");
    _ = @import("core/config.zig");
    _ = @import("ghw/goal_tree.zig");
    _ = @import("ghw/world_model.zig");
    _ = @import("ghw/harness_registry.zig");
    _ = @import("ghw/ghw_io.zig");
    _ = @import("hypermem/engine.zig");
    _ = @import("memory/tri_source_manager.zig");
    _ = @import("memory/consolidator.zig");
    _ = @import("memory/coherence.zig");
    _ = @import("retrieval/hnsw.zig");
    _ = @import("retrieval/embedder.zig");
    _ = @import("retrieval/hybrid_retriever.zig");
    // The BM25 sparse arm. Named here for the reason every other entry
    // in this block is named: `retrieval/mod.zig` re-exports it, and a
    // re-export builds the module without ever registering its `test`
    // blocks with the runner. Without this line the sparse arm's twelve
    // tests would compile nowhere and run nowhere while `hybrid_retriever`
    // — which imports it — looked thoroughly tested.
    _ = @import("retrieval/bm25.zig");
    _ = @import("utils/hashing.zig");
    _ = @import("utils/time.zig");
    _ = @import("utils/jsonl.zig");
    _ = @import("utils/logger.zig");

    // The MCP server. Each file is named INDIVIDUALLY, not via
    // `mcp/mod.zig`: Zig collects `test` blocks only from files named
    // directly in the root's comptime block, so a re-export builds the
    // module without ever registering its tests. This is the same trap
    // documented above for `reranker.zig` and `goal_tree.zig`, and the
    // reason `mod.zig` alone is not enough.
    //
    // Hand-rolled protocol code is exactly where a silently green suite
    // hides: a parser that drops an escape, a framer that dispatches a
    // half-line, a server that answers a notification. Every one of
    // those is a field bug with no compiler support, so the tests are
    // the only thing standing between them and a client that hangs.
    _ = @import("mcp/json.zig");
    _ = @import("mcp/json_out.zig");
    _ = @import("mcp/framing.zig");
    _ = @import("mcp/protocol.zig");
    _ = @import("mcp/tools.zig");
    _ = @import("mcp/server.zig");
    _ = @import("cli_commands/mcp.zig");
    // Official LongMemEval retrieval harness: metric math, dataset parsing,
    // corpus construction and a Store-backed fixture run.
    _ = @import("eval/longmemeval_official.zig");
    // Ablation harness (variants, tag assigner, router) and its paired
    // bootstrap statistics. Evaluation-only; no product code path.
    _ = @import("eval/paired_stats.zig");
    _ = @import("eval/lme_ablation.zig");
    // The daemon entry point: banner, logger selection and signal wiring.
    _ = @import("cli_commands/serve.zig");
}

const log = std.log.scoped(.mem3_main);

pub fn main(init: std.process.Init.Minimal) !void {
    // Debug and ReleaseSafe keep the leak-checking DebugAllocator. In
    // ReleaseFast/ReleaseSmall its safety is compiled out, so it checks
    // nothing and only costs: a mutex, power-of-two size classes (a 264 B
    // neighbour list takes a 512 B slot) and page caching. Measured at 100K
    // cells: peak memory footprint 551.7 MB with it, 378.9 MB with
    // `smp_allocator` (docs/roadmap.md, "1b"). `smp_allocator` is pure Zig
    // and thread-safe, so the daemon's worker threads are covered.
    var debug_gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    const checked = switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    };
    defer if (checked) {
        _ = debug_gpa.deinit();
    };
    const alloc: std.mem.Allocator = if (checked) debug_gpa.allocator() else std.heap.smp_allocator;

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
        .unsupersede => @import("cli_commands/unsupersede.zig").run(alloc, parsed),
        .serve => @import("cli_commands/serve.zig").run(alloc, parsed),
        .bench => @import("cli_commands/bench.zig").run(alloc, parsed),
        .mcp => @import("cli_commands/mcp.zig").run(alloc, parsed),
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
