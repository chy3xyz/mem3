//! HyMem — Hypergraph Memory Engine.
//!
//! **GHW Layer**: HyMem (the storage plane). Provides node+hyperedge
//! storage, multi-hop traversal, and message passing over typed edges.
//!
//! ## Constitution compliance
//! - Principle II (GHW 三层耦合): HyMem is the storage backbone.
//! - Principle III: edges carry three-source weight vectors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/mod.zig");
const MemCell = core.MemCell;
const HyperEdge = @import("hyperedge.zig").HyperEdge;
const EdgeType = core.EdgeType;
const errors = core.Error;

const log = std.log.scoped(.mem3_hypermem);

pub const HyMem = struct {
    alloc: Allocator,
    /// id -> HyperEdge
    edges: std.AutoHashMap(u64, *HyperEdge),
    /// id -> node index (for fast lookup)
    node_to_edges: std.AutoHashMap(u64, std.ArrayList(u64)),
    /// id -> edge ids
    edge_to_nodes: std.AutoHashMap(u64, std.ArrayList(u64)),
    next_id: *std.atomic.Value(u64),

    pub fn init(alloc: Allocator, next_id: *std.atomic.Value(u64)) HyMem {
        return .{
            .alloc = alloc,
            .edges = std.AutoHashMap(u64, *HyperEdge).init(alloc),
            .node_to_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(alloc),
            .edge_to_nodes = std.AutoHashMap(u64, std.ArrayList(u64)).init(alloc),
            .next_id = next_id,
        };
    }

    pub fn deinit(self: *HyMem) void {
        var it = self.edges.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.edges.deinit();

        var n_it = self.node_to_edges.iterator();
        while (n_it.next()) |entry| entry.value_ptr.*.deinit(self.alloc);
        self.node_to_edges.deinit();

        var e_it = self.edge_to_nodes.iterator();
        while (e_it.next()) |entry| entry.value_ptr.*.deinit(self.alloc);
        self.edge_to_nodes.deinit();
    }

    /// Register a node (MemCell). Idempotent.
    pub fn addNode(self: *HyMem, node_id: u64) !void {
        if (self.node_to_edges.getPtr(node_id) == null) {
            try self.node_to_edges.put(node_id, .empty);
        }
    }

    /// Add a hyperedge connecting 2+ MemCells.
    pub fn addEdge(self: *HyMem, edge: HyperEdge) !u64 {
        const id = self.next_id.fetchAdd(1, .monotonic);
        return self.addEdgeWithId(id, edge);
    }

    /// Insert with a caller-reserved id.
    ///
    /// `addEdge` mints the id internally, which makes WAL-first
    /// journaling impossible: the journal has to be written *before*
    /// the insert, but it needs the id, and the id does not exist until
    /// the insert has happened. Reserving it here closes that gap.
    pub fn addEdgeWithId(self: *HyMem, id: u64, edge: HyperEdge) !u64 {
        try edge.validate();

        const e_ptr = try self.alloc.create(HyperEdge);
        errdefer self.alloc.destroy(e_ptr);
        // Copy nodes slice.
        const nodes_copy = try self.alloc.alloc(u64, edge.nodes.len);
        @memcpy(nodes_copy, edge.nodes);
        e_ptr.* = .{
            .id = id,
            .edge_type = edge.edge_type,
            .nodes = nodes_copy,
            .weight = edge.weight,
            .source_weights = edge.source_weights,
            .confidence = edge.confidence,
            .created_at = edge.created_at,
            .metadata = if (edge.metadata) |m| try self.alloc.dupe(u8, m) else null,
        };
        try self.edges.put(id, e_ptr);

        // Update adjacency indices.
        for (edge.nodes) |nid| {
            const nlist = self.node_to_edges.getPtr(nid) orelse blk: {
                const l = std.ArrayList(u64).empty;
                try self.node_to_edges.put(nid, l);
                break :blk self.node_to_edges.getPtr(nid).?;
            };
            try nlist.append(self.alloc, id);
        }
        var e_list = std.ArrayList(u64).empty;
        try e_list.append(self.alloc, id);
        try self.edge_to_nodes.put(id, e_list);

        log.debug("addEdge: id={d} type={s} nodes={d}", .{ id, edge.edge_type.label(), edge.nodes.len });
        return id;
    }

    /// Get the edges incident to a node.
    pub fn edgesOf(self: *HyMem, node_id: u64) []const u64 {
        const list = self.node_to_edges.getPtr(node_id) orelse return &.{};
        return list.items;
    }

    /// Get the nodes in a given edge.
    pub fn nodesIn(self: *HyMem, edge_id: u64) []const u64 {
        const list = self.edge_to_nodes.getPtr(edge_id) orelse return &.{};
        return list.items;
    }

    /// Remove an edge (e.g., during a fuzzy-store transition).
    pub fn removeEdge(self: *HyMem, edge_id: u64) ?*HyperEdge {
        if (self.edges.fetchRemove(edge_id)) |kv| {
            // Remove from node_to_edges for each node.
            for (kv.value.nodes) |nid| {
                if (self.node_to_edges.getPtr(nid)) |list| {
                    for (list.items, 0..) |eid, i| {
                        if (eid == edge_id) {
                            _ = list.orderedRemove(i);
                            break;
                        }
                    }
                }
            }
            _ = self.edge_to_nodes.remove(edge_id);
            return kv.value;
        }
        return null;
    }

    /// Multi-hop traversal from seed nodes. BFS up to `max_hops`, with
    /// confidence threshold filtering.
    pub fn multiHop(
        self: *HyMem,
        alloc: Allocator,
        seed_ids: []const u64,
        max_hops: u8,
        confidence_threshold: f32,
        edge_types_filter: ?[]const EdgeType,
    ) errors![]u64 {
        var visited = std.AutoHashMap(u64, void).init(alloc);
        defer visited.deinit();
        var frontier = std.ArrayList(u64).empty;
        defer frontier.deinit(alloc);
        var next_frontier = std.ArrayList(u64).empty;
        defer next_frontier.deinit(alloc);
        var results = std.ArrayList(u64).empty;
        errdefer results.deinit(alloc);

        for (seed_ids) |sid| {
            try visited.put(sid, {});
            try frontier.append(alloc, sid);
            try results.append(alloc, sid);
        }

        var hops: u8 = 0;
        while (hops < max_hops and frontier.items.len > 0) {
            next_frontier.clearRetainingCapacity();
            for (frontier.items) |nid| {
                for (self.edgesOf(nid)) |eid| {
                    const edge = self.edges.get(eid) orelse continue;
                    if (edge.confidence < confidence_threshold) continue;
                    if (edge_types_filter) |types| {
                        var allowed = false;
                        for (types) |t| {
                            if (t == edge.edge_type) {
                                allowed = true;
                                break;
                            }
                        }
                        if (!allowed) continue;
                    }
                    for (edge.nodes) |target_nid| {
                        if (visited.contains(target_nid)) continue;
                        try visited.put(target_nid, {});
                        try next_frontier.append(alloc, target_nid);
                        try results.append(alloc, target_nid);
                    }
                }
            }
            // Swap frontiers. Zig doesn't allow pointer-arithmetic on local
            // ArrayLists, so we move-construct via assignment: each
            // ArrayList becomes the other's contents.
            const tmp = frontier;
            frontier = next_frontier;
            next_frontier = tmp;
            hops += 1;
        }
        return results.toOwnedSlice(alloc);
    }

    pub fn count(self: *const HyMem) usize {
        return self.edges.count();
    }
};

test "HyMem: addEdge + multiHop" {
    var ids: std.atomic.Value(u64) = .init(1);
    var hm = HyMem.init(std.testing.allocator, &ids);
    defer hm.deinit();

    try hm.addNode(1);
    try hm.addNode(2);
    try hm.addNode(3);

    const e1: HyperEdge = .{
        .id = 0,
        .edge_type = .associative,
        .nodes = &[_]u64{ 1, 2 },
        .weight = 0.8,
        .source_weights = .{ 0.5, 0.3, 0.2 },
        .confidence = 0.7,
        .created_at = 0,
    };
    const e2: HyperEdge = .{
        .id = 0,
        .edge_type = .temporal,
        .nodes = &[_]u64{ 2, 3 },
        .weight = 0.6,
        .source_weights = .{ 0.2, 0.7, 0.1 },
        .confidence = 0.5,
        .created_at = 0,
    };
    const e1id = try hm.addEdge(e1);
    const e2id = try hm.addEdge(e2);

    const visited = try hm.multiHop(std.testing.allocator, &[_]u64{1}, 3, 0.0, null);
    defer std.testing.allocator.free(visited);

    try std.testing.expect(visited.len >= 3);
    try std.testing.expect(e1id != e2id);
}

test "HyperEdge: validates nodes.len >= 2" {
    var ids: std.atomic.Value(u64) = .init(1);
    var hm = HyMem.init(std.testing.allocator, &ids);
    defer hm.deinit();

    const bad: HyperEdge = .{
        .id = 0,
        .edge_type = .causal,
        .nodes = &[_]u64{1},
        .weight = 0.5,
        .source_weights = .{ 1.0, 0.0, 0.0 },
        .confidence = 0.5,
        .created_at = 0,
    };
    try std.testing.expectError(errors.EdgeTooFewNodes, hm.addEdge(bad));
}

test "HyperEdge: validates source_weights sum to 1" {
    var ids: std.atomic.Value(u64) = .init(1);
    var hm = HyMem.init(std.testing.allocator, &ids);
    defer hm.deinit();

    const bad: HyperEdge = .{
        .id = 0,
        .edge_type = .causal,
        .nodes = &[_]u64{ 1, 2 },
        .weight = 0.5,
        .source_weights = .{ 0.5, 0.5, 0.5 }, // sums to 1.5
        .confidence = 0.5,
        .created_at = 0,
    };
    try std.testing.expectError(errors.InvalidSourceWeights, hm.addEdge(bad));
}
