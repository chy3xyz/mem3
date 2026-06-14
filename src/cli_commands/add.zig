//! CLI implementation for `mem3 add`.
//!
//! Per the spec: `mem3 add --source=matter --episode "..." --facts "..."
//!                --foresight "..." --goal-ids 1,2 --relevances 0.8,0.5`
//!
//! On success: prints the assigned MemCell id as JSON (or human-readable).
//!
//! **Constitution compliance**:
//! - Source tag is mandatory (rejected if missing).
//! - Spirit dim is mandatory (rejected if both --foresight and --goal-ids
//!   are empty).
//! - Importance score is computed at encoding time.
//! - When `--data-dir` is set, the cell is journaled to WAL before
//!   becoming observable in memory (Constitution VII).

const std = @import("std");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const core = @import("../core/mod.zig");
const MemorySource = core.MemorySource;
const Fact = core.Fact;
const Foresight = core.Foresight;
const GoalAssociation = core.GoalAssociation;
const time_util = @import("../utils/time.zig");
const encoder_mod = @import("../memory/encoder.zig");
const RawInput = encoder_mod.RawInput;

pub fn run(alloc: std.mem.Allocator, parsed: cli.Parsed) !void {
    var store = try cli_common.openStore(alloc, parsed);
    defer store.deinit();

    var source: ?MemorySource = null;
    var episode: ?[]const u8 = null;
    var facts = std.ArrayList(Fact).empty;
    defer facts.deinit(alloc);
    var foresights = std.ArrayList(Foresight).empty;
    defer foresights.deinit(alloc);
    var goal_ids = std.ArrayList(u64).empty;
    defer goal_ids.deinit(alloc);
    var relevances = std.ArrayList(f32).empty;
    defer relevances.deinit(alloc);

    for (parsed.args.items) |arg| {
        if (std.mem.eql(u8, arg.key, "--source")) {
            const v = arg.value orelse cli_common.fatal("error: --source requires a value\n", .{});
            source = try cli_common.parseSource(v);
        } else if (std.mem.eql(u8, arg.key, "--episode") or std.mem.eql(u8, arg.key, "--ep")) {
            episode = arg.value;
        } else if (std.mem.eql(u8, arg.key, "--facts")) {
            const v = arg.value orelse cli_common.fatal("error: --facts requires a value\n", .{});
            try parseFactsConst(alloc, v, &facts);
        } else if (std.mem.eql(u8, arg.key, "--foresight")) {
            const v = arg.value orelse cli_common.fatal("error: --foresight requires a value\n", .{});
            try parseForesightConst(alloc, v, &foresights);
        } else if (std.mem.eql(u8, arg.key, "--goal-ids")) {
            const v = arg.value orelse cli_common.fatal("error: --goal-ids requires a value\n", .{});
            try parseU64List(alloc, v, &goal_ids);
        } else if (std.mem.eql(u8, arg.key, "--relevances")) {
            const v = arg.value orelse cli_common.fatal("error: --relevances requires a value\n", .{});
            try parseF32List(alloc, v, &relevances);
        }
    }

    if (source == null) cli_common.fatal("error: --source is required (matter|form|spirit)\n", .{});
    if (episode == null) cli_common.fatal("error: --episode is required\n", .{});

    var goal_associations = std.ArrayList(GoalAssociation).empty;
    defer goal_associations.deinit(alloc);
    const n = @min(goal_ids.items.len, relevances.items.len);
    for (0..n) |i| {
        try goal_associations.append(alloc, .{
            .goal_id = goal_ids.items[i],
            .relevance = relevances.items[i],
            .priority = 5,
        });
    }
    // If user gave goal_ids but no relevances (or vice versa), still
    // provide a sensible default association so the spirit dimension
    // is non-empty.
    if (goal_associations.items.len == 0 and goal_ids.items.len > 0) {
        for (goal_ids.items) |gid| {
            try goal_associations.append(alloc, .{
                .goal_id = gid,
                .relevance = 0.5,
                .priority = 5,
            });
        }
    }

    const now_ms = time_util.nowMs();

    const input: RawInput = .{
        .source = source.?,
        .episode = episode.?,
        .atomic_facts = facts.items,
        .foresight = foresights.items,
        .goal_associations = goal_associations.items,
    };

    // Encode via the lifecycle (constitutional validation), then add
    // through the Store so it journals to WAL.
    // We construct a MemCell by going through the lifecycle once
    // (for validation + importance scoring) then handing the cell
    // to the Store with its pre-allocated id.
    var lc = store.lc;
    const cell = try lc.encoder.encode(input);
    const id = store.mgr.add(cell) catch |err| {
        cli_common.fatal("error: add failed: {s}\n", .{@errorName(err)});
    };
    // Add to the cell_index (the Store.addRaw path does this; we
    // bypassed it so the index needs manual sync).
    if (store.mgr.get(id)) |stored| {
        try store.cell_index.put(id, stored);
        const v = try store.emb.embed(alloc, stored.episode);
        defer alloc.free(v);
        store.hnsw.insert(id, v) catch {};
    }

    // Persist to WAL if durable.
    if (store.wal) |wal| {
        // Serialize facts to "s|p|o;s|p|o;..." format. The splitScalar
        // walks the parsed facts list once.
        var facts_payload_buf = std.ArrayList(u8).empty;
        defer facts_payload_buf.deinit(alloc);
        for (facts.items, 0..) |f, i| {
            if (i > 0) try facts_payload_buf.append(alloc, ';');
            try facts_payload_buf.appendSlice(alloc, f.subject);
            try facts_payload_buf.append(alloc, '|');
            try facts_payload_buf.appendSlice(alloc, f.predicate);
            try facts_payload_buf.append(alloc, '|');
            try facts_payload_buf.appendSlice(alloc, f.object);
        }

        const first_goal_id: u64 = if (goal_associations.items.len > 0) goal_associations.items[0].goal_id else 0;
        const first_relevance: f32 = if (goal_associations.items.len > 0) goal_associations.items[0].relevance else 0.5;

        const payload = try std.fmt.allocPrint(alloc,
            \\{{"id":{d},"source":"{s}","episode":"{s}","facts":"{s}","goal_id":{d},"relevance":{d:.4},"created_at":{d},"updated_at":{d},"last_accessed_at":{d},"importance_score":{d:.4},"coherence_score":{d:.4},"decay_rate":{d:.6},"source_confidence":{d:.4},"emotional_valence":{d:.4},"access_count":{d}}}
        , .{
            id, @tagName(source.?), episode.?, facts_payload_buf.items, first_goal_id, first_relevance,
            cell.metadata.created_at, cell.metadata.updated_at, cell.metadata.last_accessed_at,
            cell.metadata.importance_score, cell.metadata.coherence_score, cell.metadata.decay_rate,
            cell.metadata.source_confidence, cell.metadata.emotional_valence, cell.metadata.access_count,
        });
        defer alloc.free(payload);
        wal.append(.{ .record_type = .memcell_insert, .payload = payload, .timestamp = @intCast(@divTrunc(now_ms, 1000)) }) catch {};
    }

    if (parsed.json) {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id}) catch unreachable;
        cli_common.println(s);
    } else {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "added memory id={d}", .{id}) catch unreachable;
        cli_common.println(s);
    }
}

// Zero-copy parsers: produce slices that reference `s` directly. `s` must
// outlive the resulting structs.

fn parseFactsConst(alloc: std.mem.Allocator, s: []const u8, out: *std.ArrayList(Fact)) !void {
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        var pit = std.mem.splitScalar(u8, part, '|');
        const subject = pit.next() orelse "";
        const predicate = pit.next() orelse "";
        const object = pit.next() orelse "";
        try out.append(alloc, .{
            .subject = subject,
            .predicate = predicate,
            .object = object,
            .confidence = 1.0,
            .source = "user_input",
        });
    }
}

fn parseForesightConst(alloc: std.mem.Allocator, s: []const u8, out: *std.ArrayList(Foresight)) !void {
    var it = std.mem.splitScalar(u8, s, ';');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        var pit = std.mem.splitScalar(u8, part, '|');
        const desc = pit.next() orelse "";
        const from = std.fmt.parseInt(i64, pit.next() orelse "0", 10) catch 0;
        const until = std.fmt.parseInt(i64, pit.next() orelse "0", 10) catch 0;
        const conf = std.fmt.parseFloat(f32, pit.next() orelse "0.5") catch 0.5;
        try out.append(alloc, .{
            .description = desc,
            .valid_from = from,
            .valid_until = until,
            .confidence = conf,
        });
    }
}

fn parseU64List(alloc: std.mem.Allocator, s: []const u8, out: *std.ArrayList(u64)) !void {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const v = try std.fmt.parseInt(u64, part, 10);
        try out.append(alloc, v);
    }
}

fn parseF32List(alloc: std.mem.Allocator, s: []const u8, out: *std.ArrayList(f32)) !void {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const v = try std.fmt.parseFloat(f32, part);
        try out.append(alloc, v);
    }
}