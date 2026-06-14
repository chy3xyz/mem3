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

pub const core = @import("core/mod.zig");
pub const utils = @import("utils/mod.zig");
pub const ghw = @import("ghw/mod.zig");
pub const memory = @import("memory/mod.zig");
pub const hypermem = @import("hypermem/mod.zig");
pub const retrieval = @import("retrieval/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const server = @import("server/mod.zig");
pub const store = @import("store/mod.zig");
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
