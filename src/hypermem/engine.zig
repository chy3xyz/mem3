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

    /// A node reached by graph traversal, with the relevance it inherited.
    pub const ScoredNode = struct {
        id: u64,
        score: f32,
        hops: u8,
    };

    /// Like `multiHop`, but propagates relevance instead of returning bare
    /// ids.
    ///
    /// A node reached `k` hops from a seed inherits that seed's score times
    /// `decay^k`. `multiHop` cannot support this: it hands back a flat id
    /// list with no provenance, so every caller had to either ignore the
    /// scores or re-derive the traversal. Ignoring them is what made
    /// `POST /api/query`'s `maxHops` unobservable — graph hits entered the
    /// candidate pool with score 0 and could never reach the top-k cut.
    ///
    /// Seeds are returned first (hops = 0, score unchanged), so a caller can
    /// use this as a drop-in for the dense result set plus its expansion.
    pub fn multiHopScored(
        self: *HyMem,
        alloc: Allocator,
        seeds: []const ScoredNode,
        max_hops: u8,
        decay: f32,
        confidence_threshold: f32,
        edge_types_filter: ?[]const EdgeType,
    ) errors![]ScoredNode {
        var best = std.AutoHashMap(u64, ScoredNode).init(alloc);
        defer best.deinit();

        var results = std.ArrayList(ScoredNode).empty;
        errdefer results.deinit(alloc);
        try results.ensureTotalCapacity(alloc, seeds.len);

        var frontier = std.ArrayList(ScoredNode).empty;
        defer frontier.deinit(alloc);
        try frontier.ensureTotalCapacity(alloc, seeds.len);

        for (seeds) |s| {
            if (best.contains(s.id)) continue;
            const seeded: ScoredNode = .{ .id = s.id, .score = s.score, .hops = 0 };
            try best.put(s.id, seeded);
            try results.append(alloc, seeded);
            try frontier.append(alloc, seeded);
        }

        var hops: u8 = 0;

        // Two long-lived frontier buffers, swapped by value each level.
        // Declaring the next level's list *inside* the loop and deferring
        // its deinit to the end of the iteration frees the buffer that
        // `frontier` was just assigned — the next iteration then reads
        // freed memory.
        var next_frontier = std.ArrayList(ScoredNode).empty;
        defer next_frontier.deinit(alloc);

        while (hops < max_hops and frontier.items.len > 0) {
            next_frontier.clearRetainingCapacity();

            for (frontier.items) |node| {
                for (self.edgesOf(node.id)) |eid| {
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
                    for (edge.nodes) |target| {
                        // Propagate along the strongest path, not the first
                        // one found: a node reachable from two seeds keeps
                        // whichever score is higher.
                        // Exactly one `decay` per hop, applied to the
                        // parent's score. Multiplying by a running
                        // `level_decay` instead decays a score that was
                        // already decayed: 1.0 * 0.5^2 became 0.125 at two
                        // hops, not the 0.25 the doc comment promises.
                        const propagated: f32 = node.score * decay;
                        if (best.get(target)) |prev| {
                            if (propagated <= prev.score) continue;
                            best.put(target, .{ .id = target, .score = propagated, .hops = hops + 1 }) catch unreachable;
                            for (results.items) |*r| {
                                if (r.id == target) r.* = .{ .id = target, .score = propagated, .hops = hops + 1 };
                            }
                            try next_frontier.append(alloc, .{ .id = target, .score = propagated, .hops = hops + 1 });
                            continue;
                        }
                        const fresh: ScoredNode = .{ .id = target, .score = propagated, .hops = hops + 1 };
                        try best.put(target, fresh);
                        try results.append(alloc, fresh);
                        try next_frontier.append(alloc, fresh);
                    }
                }
            }
            // Swap both ways. Assigning only `frontier = next_frontier`
            // leaves the two variables aliasing one buffer, and the two
            // `defer`s above then free it twice.
            const tmp = frontier;
            frontier = next_frontier;
            next_frontier = tmp;
            hops += 1;
        }

        return results.toOwnedSlice(alloc);
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

test "HyMem: multiHopScored propagates relevance with per-hop decay" {
    var ids: std.atomic.Value(u64) = .init(1);
    var hm = HyMem.init(std.testing.allocator, &ids);
    defer hm.deinit();

    try hm.addNode(1);
    try hm.addNode(2);
    try hm.addNode(3);
    try hm.addNode(4);

    const mk = struct {
        fn e(a: Allocator, nodes: []const u64) !HyperEdge {
            return .{
                .id = 0,
                .edge_type = .associative,
                .nodes = try a.dupe(u64, nodes),
                .weight = 0.5,
                .source_weights = .{ 1.0, 0.0, 0.0 },
                .confidence = 1.0,
                .created_at = 0,
                .metadata = null,
            };
        }
    };

    var e1 = try mk.e(std.testing.allocator, &[_]u64{ 1, 2 });
    _ = try hm.addEdge(e1);
    e1.deinit(std.testing.allocator);
    var e2 = try mk.e(std.testing.allocator, &[_]u64{ 2, 3 });
    _ = try hm.addEdge(e2);
    e2.deinit(std.testing.allocator);
    var e3 = try mk.e(std.testing.allocator, &[_]u64{ 3, 4 });
    _ = try hm.addEdge(e3);
    e3.deinit(std.testing.allocator);

    const seeds = [_]HyMem.ScoredNode{.{ .id = 1, .score = 1.0, .hops = 0 }};
    const got = try hm.multiHopScored(std.testing.allocator, &seeds, 2, 0.5, 0.0, null);
    defer std.testing.allocator.free(got);

    var by_id = std.AutoHashMap(u64, HyMem.ScoredNode).init(std.testing.allocator);
    defer by_id.deinit();
    for (got) |g| try by_id.put(g.id, g);

    // Seed keeps its score.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), by_id.get(1).?.score, 1e-6);
    try std.testing.expectEqual(@as(u8, 0), by_id.get(1).?.hops);
    // One hop out: score * decay.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), by_id.get(2).?.score, 1e-6);
    try std.testing.expectEqual(@as(u8, 1), by_id.get(2).?.hops);
    // Two hops: score * decay^2.
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), by_id.get(3).?.score, 1e-6);
    try std.testing.expectEqual(@as(u8, 2), by_id.get(3).?.hops);
    // Beyond the budget.
    try std.testing.expect(by_id.get(4) == null);

    // max_hops = 0 must return exactly the seeds, undecayed.
    const none = try hm.multiHopScored(std.testing.allocator, &seeds, 0, 0.5, 0.0, null);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 1), none.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), none[0].score, 1e-6);
}

test "HyMem: multiHopScored keeps the strongest path to a node reachable twice" {
    var ids: std.atomic.Value(u64) = .init(1);
    var hm = HyMem.init(std.testing.allocator, &ids);
    defer hm.deinit();

    try hm.addNode(1);
    try hm.addNode(9);
    try hm.addNode(3);

    const mk = struct {
        fn e(a: Allocator, nodes: []const u64) !HyperEdge {
            return .{
                .id = 0,
                .edge_type = .associative,
                .nodes = try a.dupe(u64, nodes),
                .weight = 0.5,
                .source_weights = .{ 1.0, 0.0, 0.0 },
                .confidence = 1.0,
                .created_at = 0,
                .metadata = null,
            };
        }
    };

    // 1 — 3 directly (weak seed path is still one hop), and 1 — 9 — 3.
    var direct = try mk.e(std.testing.allocator, &[_]u64{ 1, 3 });
    _ = try hm.addEdge(direct);
    direct.deinit(std.testing.allocator);
    var bridge = try mk.e(std.testing.allocator, &[_]u64{ 1, 9 });
    _ = try hm.addEdge(bridge);
    bridge.deinit(std.testing.allocator);
    var tail = try mk.e(std.testing.allocator, &[_]u64{ 9, 3 });
    _ = try hm.addEdge(tail);
    tail.deinit(std.testing.allocator);

    // Seed 9 is strong, seed 1 is weak. Node 3 must inherit from 9, not 1.
    const seeds = [_]HyMem.ScoredNode{
        .{ .id = 1, .score = 0.2, .hops = 0 },
        .{ .id = 9, .score = 1.0, .hops = 0 },
    };
    const got = try hm.multiHopScored(std.testing.allocator, &seeds, 2, 0.5, 0.0, null);
    defer std.testing.allocator.free(got);

    var node3: ?HyMem.ScoredNode = null;
    for (got) |g| {
        if (g.id == 3) node3 = g;
    }
    try std.testing.expect(node3 != null);
    // 9's path: 1.0 * 0.5 = 0.5. 1's direct path: 0.2 * 0.5 = 0.1.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), node3.?.score, 1e-6);
}
