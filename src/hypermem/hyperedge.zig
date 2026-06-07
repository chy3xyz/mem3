//! HyperEdge — a typed relation connecting 2+ MemCells.
//!
//! **GHW Layer**: HyMem (跨层). Carries a three-source weight vector
//! `(w_M, w_F, w_S)` summing to 1.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const EdgeType = core.EdgeType;
const errors = core.Error;

pub const HyperEdge = struct {
    id: u64,
    edge_type: EdgeType,
    nodes: []const u64,            // 2+ MemCell ids
    weight: f32,                   // [0, 1]
    /// Three-source weight vector, must sum to 1.0 (within tolerance).
    source_weights: [3]f32,        // [w_M, w_F, w_S]
    confidence: f32,               // [0, 1]
    created_at: i64,
    metadata: ?[]const u8 = null,

    pub const serialized_size: usize = blk: {
        // Skeleton — full impl in serializer.zig extension. v0.1.0 just stores
        // in-memory.
        break :blk 64;
    };

    pub fn deinit(self: *const HyperEdge, alloc: Allocator) void {
        alloc.free(self.nodes);
        if (self.metadata) |m| alloc.free(m);
    }

    /// Validate a candidate edge.
    pub fn validate(self: *const HyperEdge) errors!void {
        if (self.nodes.len < 2) return errors.EdgeTooFewNodes;
        const sum: f32 = self.source_weights[0] + self.source_weights[1] + self.source_weights[2];
        if (@abs(sum - 1.0) > 1e-3) return errors.InvalidSourceWeights;
    }
};
