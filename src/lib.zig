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

/// Library version. Keep in sync with `build.zig.zon`.
pub const VERSION = "0.1.0-alpha";

test "libmem3 placeholder" {
    try std.testing.expectEqualStrings("0.1.0-alpha", VERSION);
}
