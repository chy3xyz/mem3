//! mem3 — TriSource-EverOS
//!
//! Static library surface (`libmem3.a`).
//! Built via `zig build` (installs `zig-out/lib/libmem3.a`).
//!
//! For the v0.1.0-alpha the library surface is intentionally minimal; it
//! exposes the same internal Zig types that the CLI consumes, so downstream
//! C / Zig / Rust clients can embed mem3 directly without going through
//! the CLI. The HTTP daemon (`src/server/`) is the recommended public API
//! for non-Zig clients.

const std = @import("std");

comptime {
    // The platform layer carries its own target guard in `fs.zig`, but that
    // module is only semantically analysed when something actually calls it —
    // so `zig build-lib src/lib.zig -Dtarget=x86_64-windows` used to produce a
    // library that silently contained un-analysable platform code. The root of
    // a library is always analysed, so the supported-target list is enforced
    // here as well. See docs/constitution-amendments/2026-10-14-platform-scope.md
    const os = @import("builtin").os.tag;
    if (os == .windows or os == .wasi or os == .freestanding) {
        @compileError(
            "mem3 supports macOS and Linux only. Windows needs a Winsock port " ++
                "of the HTTP daemon (src/server/http_server.zig binds raw POSIX " ++
                "sockets); WASM is deferred to v0.3.0. Rationale and the full " ++
                "sync-impact report: docs/constitution-amendments/2026-10-14-platform-scope.md",
        );
    }
}

pub const core = @import("core/mod.zig");
pub const utils = @import("utils/mod.zig");
pub const ghw = @import("ghw/mod.zig");
pub const memory = @import("memory/mod.zig");
pub const hypermem = @import("hypermem/mod.zig");
pub const retrieval = @import("retrieval/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const server = @import("server/mod.zig");
pub const store = @import("store/mod.zig");
/// The CLI argument parser. Exposed so `tests/unit/cli.zig` can reach
/// it through this module: giving `src/cli.zig` its own module root would
/// put `src/core/types.zig` in two modules at once, which Zig refuses.
pub const cli = @import("cli.zig");
/// The portability layer (fs / clock / stdio / env). Public so the
/// examples and benchmarks stop hand-rolling their own POSIX helpers —
/// four of them carried byte-identical copies of ~30 lines each.
pub const platform = @import("platform/mod.zig");
pub const Store = store.Store;
pub const BuildOptions = store.BuildOptions;

// Submodule re-exports — exposed so tests and downstream packages
// can reach the deeply-nested types (`mem3.memory.Consolidator`,
// `mem3.coherence.CoherenceCalculator`, etc.) without importing
// every `.zig` file directly.
pub const coherence = @import("memory/coherence.zig");
pub const consolidator_mod = @import("memory/consolidator.zig");

// Re-export the most common types at the top level so consumers can
// `const mem3 = @import("mem3"); mem3.MemCell` etc.
pub const MemorySource = core.MemorySource;
pub const Fact = core.Fact;
pub const Foresight = core.Foresight;
pub const GoalAssociation = core.GoalAssociation;
pub const Metadata = core.Metadata;
pub const GoalStatus = core.GoalStatus;
pub const EdgeType = core.EdgeType;
pub const MemCell = core.MemCell;
pub const IdSources = core.IdSources;
pub const Config = core.Config;
pub const Error = core.Error;

// GHW re-exports
pub const GoalPoset = ghw.GoalPoset;
pub const GoalNode = ghw.GoalNode;
pub const Harness = ghw.Harness;
pub const HarnessRegistry = ghw.HarnessRegistry;
pub const WorldEntity = ghw.WorldEntity;
pub const WorldModel = ghw.WorldModel;
/// The three-layer handle `Store` runs every memory operation through.
pub const GHW = ghw.GHW;
/// Bounded audit trail of every cross-layer hop.
pub const CrossLayerLog = ghw.CrossLayerLog;
pub const Direction = ghw.Direction;
/// Constitution Principle II's direction check. Exposed so a consumer
/// that builds its own traversal can be held to the same rule the store
/// enforces.
pub const isValidDirection = ghw.isValidDirection;

// Memory re-exports
pub const TriSourceManager = memory.TriSourceManager;
pub const Encoder = memory.Encoder;
pub const RawInput = memory.RawInput;
pub const Forgetter = memory.Forgetter;
pub const FuzzyStore = memory.FuzzyStore;
pub const Lifecycle = memory.Lifecycle;

// HyMem re-exports
pub const HyperEdge = hypermem.HyperEdge;
pub const HyMem = hypermem.HyMem;

// Retrieval re-exports
pub const HNSW = retrieval.HNSW;
pub const StubEmbedder = retrieval.StubEmbedder;
pub const LexicalEmbedder = retrieval.LexicalEmbedder;
pub const Embedder = retrieval.Embedder;
pub const HybridRetriever = retrieval.HybridRetriever;
pub const Candidate = retrieval.Candidate;
pub const RerankContext = retrieval.RerankContext;
pub const ScoredCell = retrieval.ScoredCell;

// Storage re-exports
pub const WAL = storage.WAL;
pub const WALRecord = storage.WALRecord;
pub const WALRecordType = storage.WALRecordType;

// Server re-exports
pub const Server = server.Server;

/// Library version. Keep in sync with `build.zig.zon`.
pub const VERSION = "0.1.0-alpha";

test "libmem3 placeholder" {
    try std.testing.expectEqualStrings("0.1.0-alpha", VERSION);
}
