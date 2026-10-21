//! Public re-exports for the memory layer.

pub const tri_source_manager = @import("tri_source_manager.zig");
pub const encoder = @import("encoder.zig");
pub const forgetter = @import("forgetter.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const conflict = @import("conflict.zig");
pub const redundancy = @import("redundancy.zig");

pub const TriSourceManager = tri_source_manager.TriSourceManager;
pub const Encoder = encoder.Encoder;
pub const RawInput = encoder.RawInput;
pub const Forgetter = forgetter.Forgetter;
pub const FuzzyStore = forgetter.FuzzyStore;
pub const Lifecycle = lifecycle.Lifecycle;
pub const ConflictIndex = conflict.ConflictIndex;
