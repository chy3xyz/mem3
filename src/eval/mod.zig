//! Public re-exports for the evaluation module.
//!
//! **GHW layer**: Harness 层 (象源). Evaluation protocols that consume a
//! `Store` from the outside; nothing here is on a product code path.

pub const longmemeval_official = @import("longmemeval_official.zig");
pub const paired_stats = @import("paired_stats.zig");
pub const lme_ablation = @import("lme_ablation.zig");
