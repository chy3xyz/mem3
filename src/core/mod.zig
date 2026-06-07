//! Public re-exports for the core module.

pub const errors = @import("errors.zig");
pub const types = @import("types.zig");
pub const memcell = @import("memcell.zig");
pub const ids = @import("ids.zig");
pub const config = @import("config.zig");

// Re-export the most-used symbols at the top level.
pub const Error = errors.Error;
pub const MemorySource = types.MemorySource;
pub const Fact = types.Fact;
pub const Foresight = types.Foresight;
pub const GoalAssociation = types.GoalAssociation;
pub const Metadata = types.Metadata;
pub const GoalStatus = types.GoalStatus;
pub const EdgeType = types.EdgeType;
pub const MemCell = memcell.MemCell;
pub const IdSources = ids.IdSources;
pub const Config = config.Config;
