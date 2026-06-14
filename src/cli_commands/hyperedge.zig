//! CLI implementation for `mem3 hyperedge`.
//!
//! Per spec:
//!   mem3 hyperedge add --type <causal|temporal|associative|goal>
//!                       --node-ids <id1,id2,...> [--weight w]
//!                       [--confidence c]
//!   mem3 hyperedge list
//!   mem3 hyperedge multi-hop --seed <id> [--hops N]
//!
//! Reads through the same Store the HTTP server uses; hyperedges are
//! durable (snapshot+wal) when `--data-dir` is set.

const std = @import("std");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const Store = @import("../store/mod.zig").Store;
const EdgeType = @import("../core/mod.zig").EdgeType;
const HyperEdge = @import("../hypermem/mod.zig").HyperEdge;
const time_util = @import("../utils/time.zig");

const Subcommand = enum { add, list, @"multi-hop", unknown };

pub fn run(alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    var store = try cli_common.openStore(alloc, parsed);
    defer store.deinit();

    var sub: Subcommand = .unknown;
    for (parsed.args.items) |arg| {
        const key = if (std.mem.eql(u8, arg.key, "positional")) arg.value orelse "" else arg.key;
        if (std.mem.eql(u8, key, "add") or std.mem.eql(u8, key, "list")) {
            sub = std.meta.stringToEnum(Subcommand, key) orelse .unknown;
        } else if (std.mem.eql(u8, key, "multi-hop")) {
            sub = .@"multi-hop";
        }
    }

    switch (sub) {
        .add => try edgeAdd(store, alloc, parsed),
        .list => try edgeList(store, alloc, parsed),
        .@"multi-hop" => try edgeMultiHop(store, alloc, parsed),
        .unknown => cli_common.fatal("error: expected: hyperedge add|list|multi-hop <args>\n", .{}),
    }
}

fn parseEdgeType(value: []const u8) !EdgeType {
    if (std.mem.eql(u8, value, "causal")) return .causal;
    if (std.mem.eql(u8, value, "temporal")) return .temporal;
    if (std.mem.eql(u8, value, "associative")) return .associative;
    if (std.mem.eql(u8, value, "goal")) return .goal;
    cli_common.fatal("error: invalid edge type '{s}' (causal|temporal|associative|goal)\n", .{value});
}

fn parseU64List(alloc: std.mem.Allocator, value: []const u8) ![]u64 {
    var out = std.ArrayList(u64).empty;
    defer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const v = try std.fmt.parseInt(u64, part, 10);
        try out.append(alloc, v);
    }
    return out.toOwnedSlice(alloc);
}

fn edgeAdd(store: *Store, alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    var edge_type: ?EdgeType = null;
    var node_ids_str: ?[]const u8 = null;
    var weight: f32 = 0.5;
    var confidence: f32 = 0.5;

    for (parsed.args.items) |arg| {
        if (std.mem.eql(u8, arg.key, "--type") or std.mem.eql(u8, arg.key, "-t")) {
            edge_type = try parseEdgeType(arg.value orelse "");
        } else if (std.mem.eql(u8, arg.key, "--node-ids")) {
            node_ids_str = arg.value orelse cli_common.fatal("error: --node-ids requires a value\n", .{});
        } else if (std.mem.eql(u8, arg.key, "--weight") or std.mem.eql(u8, arg.key, "-w")) {
            const v = arg.value orelse "";
            weight = std.fmt.parseFloat(f32, v) catch cli_common.fatal("error: invalid --weight '{s}'\n", .{v});
        } else if (std.mem.eql(u8, arg.key, "--confidence") or std.mem.eql(u8, arg.key, "-c")) {
            const v = arg.value orelse "";
            confidence = std.fmt.parseFloat(f32, v) catch cli_common.fatal("error: invalid --confidence '{s}'\n", .{v});
        }
    }
    const et = edge_type orelse cli_common.fatal("error: --type is required\n", .{});
    const ids_str = node_ids_str orelse cli_common.fatal("error: --node-ids is required\n", .{});

    const nodes = parseU64List(alloc, ids_str) catch |err|
        cli_common.fatal("error: parseU64List: {s}\n", .{@errorName(err)});
    defer alloc.free(nodes);

    const edge = HyperEdge{
        .id = 0, // assigned by store
        .edge_type = et,
        .nodes = nodes,
        .weight = weight,
        // Equal weights summing to 1 across the three sources. A more
        // sophisticated policy would distribute by source type, but
        // uniform is correct enough for v0.1.0.
        .source_weights = .{ 0.34, 0.33, 0.33 },
        .confidence = confidence,
        .created_at = time_util.nowMs(),
    };

    const id = store.addHyperedge(edge) catch |err|
        cli_common.fatal("error: addHyperedge: {s}\n", .{@errorName(err)});

    if (parsed.json) {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch unreachable;
        cli_common.println(s);
    } else {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(
            &buf,
            "hyperedge added: id={d} type={s} nodes={d}",
            .{ id, et.label(), nodes.len },
        ) catch unreachable;
        cli_common.println(s);
    }
}

fn edgeList(store: *Store, alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    const edges = try store.allHyperedges(alloc);
    defer alloc.free(edges);

    if (parsed.json) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        try buf.appendSlice(alloc, "{\"edges\":[");
        for (edges, 0..) |e, i| {
            if (i > 0) try buf.append(alloc, ',');
            try cli_common.appendFmt(&buf, alloc, "{{\"id\":{d},\"type\":\"{s}\",\"weight\":{d:.4},\"confidence\":{d:.4},\"nodes\":[", .{ e.id, e.edge_type.label(), e.weight, e.confidence });
            for (e.nodes, 0..) |n, j| {
                if (j > 0) try buf.append(alloc, ',');
                try cli_common.appendFmt(&buf, alloc, "{d}", .{n});
            }
            try buf.appendSlice(alloc, "]}");
        }
        try buf.appendSlice(alloc, "]}");
        cli_common.println(buf.items);
    } else {
        var buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&buf, "hyperedges ({d}):", .{edges.len}) catch unreachable;
        cli_common.println(header);
        for (edges) |e| {
            var line_buf: [4096]u8 = undefined;
            const prefix = std.fmt.bufPrint(
                &line_buf,
                "  id={d} type={s} conf={d:.2} nodes=",
                .{ e.id, e.edge_type.label(), e.confidence },
            ) catch continue;
            var rest_buf = std.ArrayList(u8).empty;
            defer rest_buf.deinit(alloc);
            for (e.nodes, 0..) |n, j| {
                if (j > 0) try rest_buf.append(alloc, ',');
                try cli_common.appendFmt(&rest_buf, alloc, "{d}", .{n});
            }
            const line = std.fmt.bufPrint(&line_buf, "{s}{s}", .{ prefix, rest_buf.items }) catch continue;
            cli_common.println(line);
        }
    }
}

fn edgeMultiHop(store: *Store, alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    var seed_id: ?u64 = null;
    var max_hops: u8 = 3;
    var confidence_threshold: f32 = 0.0;

    for (parsed.args.items) |arg| {
        if (std.mem.eql(u8, arg.key, "--seed") or std.mem.eql(u8, arg.key, "-s")) {
            const v = arg.value orelse cli_common.fatal("error: --seed requires a value\n", .{});
            seed_id = std.fmt.parseInt(u64, v, 10) catch cli_common.fatal("error: invalid --seed '{s}'\n", .{v});
        } else if (std.mem.eql(u8, arg.key, "--hops")) {
            const v = arg.value orelse cli_common.fatal("error: --hops requires a value\n", .{});
            max_hops = std.fmt.parseInt(u8, v, 10) catch cli_common.fatal("error: invalid --hops '{s}'\n", .{v});
        } else if (std.mem.eql(u8, arg.key, "--confidence-threshold") or std.mem.eql(u8, arg.key, "-c")) {
            const v = arg.value orelse "";
            confidence_threshold = std.fmt.parseFloat(f32, v) catch cli_common.fatal("error: invalid --confidence-threshold '{s}'\n", .{v});
        }
    }
    const seed = seed_id orelse cli_common.fatal("error: --seed is required\n", .{});
    const seeds = [_]u64{seed};

    const visited = try store.multiHop(alloc, &seeds, max_hops, confidence_threshold, null);
    defer alloc.free(visited);

    if (parsed.json) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        try cli_common.appendFmt(&buf, alloc, "{{\"seed\":{d},\"hops\":{d},\"visited\":[", .{ seed, max_hops });
        for (visited, 0..) |n, i| {
            if (i > 0) try buf.append(alloc, ',');
            try cli_common.appendFmt(&buf, alloc, "{d}", .{n});
        }
        try buf.appendSlice(alloc, "]}");
        cli_common.println(buf.items);
    } else {
        var buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &buf,
            "multi-hop from {d} (<={d} hops, conf>={d:.2}): {d} reachable",
            .{ seed, max_hops, confidence_threshold, visited.len },
        ) catch unreachable;
        cli_common.println(header);
        for (visited) |n| {
            const line = std.fmt.bufPrint(&buf, "  {d}", .{n}) catch continue;
            cli_common.println(line);
        }
    }
}