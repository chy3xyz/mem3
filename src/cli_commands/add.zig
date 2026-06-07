//! CLI implementation for `mem3 add`.
//!
//! Per the spec: `mem3 add --source=matter --episode "..." --facts "..." \
//!                --foresight "..." --goal-ids 1,2 --relevances 0.8,0.5`
//!
//! On success: prints the assigned MemCell id as JSON (or human-readable).
//!
//! **Constitution compliance**:
//! - Source tag is mandatory (rejected if missing).
//! - Spirit dim is mandatory (rejected if both --foresight and --goal-ids
//!   are empty).
//! - Importance score is computed at encoding time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const core = @import("../core/mod.zig");
const MemorySource = core.MemorySource;
const encoder = @import("../memory/encoder.zig");
const RawInput = encoder.RawInput;
const lifecycle = @import("../memory/lifecycle.zig");
const Lifecycle = lifecycle.Lifecycle;
const tri_source = @import("../memory/tri_source_manager.zig");
const TriSourceManager = tri_source.TriSourceManager;
const config = @import("../core/config.zig").Config;
const time = @import("../utils/time.zig");
const jsonl = @import("../utils/jsonl.zig");

pub fn run(alloc: Allocator, p: cli.Parsed) !void {
    var source: ?MemorySource = null;
    var episode: ?[]const u8 = null;
    var facts: std.ArrayList(core.Fact) = .empty;
    defer facts.deinit(alloc);
    var foresights: std.ArrayList(core.Foresight) = .empty;
    defer foresights.deinit(alloc);
    var goal_ids: std.ArrayList(u64) = .empty;
    defer goal_ids.deinit(alloc);
    var relevances: std.ArrayList(f32) = .empty;
    defer relevances.deinit(alloc);

    // Parse args.
    for (p.args.items) |arg| {
        if (std.mem.eql(u8, arg.key, "--source")) {
            const v = arg.value orelse return error.MissingFlag;
            source = try MemorySource.fromString(v);
        } else if (std.mem.eql(u8, arg.key, "--episode") or std.mem.eql(u8, arg.key, "--ep")) {
            episode = arg.value;
        } else if (std.mem.eql(u8, arg.key, "--facts")) {
            const v = arg.value orelse return error.MissingFlag;
            // v0.1.0: zero-copy. We parse v's substrings into Fact slices that
            // reference v directly. v must outlive the MemCell.
            try parseFactsConst(alloc, v, &facts);
        } else if (std.mem.eql(u8, arg.key, "--foresight")) {
            const v = arg.value orelse return error.MissingFlag;
            try parseForesightConst(alloc, v, &foresights);
        } else if (std.mem.eql(u8, arg.key, "--goal-ids")) {
            const v = arg.value orelse return error.MissingFlag;
            try parseU64List(alloc, v, &goal_ids);
        } else if (std.mem.eql(u8, arg.key, "--relevances")) {
            const v = arg.value orelse return error.MissingFlag;
            try parseF32List(alloc, v, &relevances);
        }
    }

    if (source == null) {
        std.debug.print("error: --source is required (matter|form|spirit)\n", .{});
        return error.MissingFlag;
    }
    if (episode == null) {
        std.debug.print("error: --episode is required\n", .{});
        return error.MissingFlag;
    }

    // Build goal associations.
    var goal_associations = std.ArrayList(core.GoalAssociation).empty;
    defer goal_associations.deinit(alloc);
    const n = @min(goal_ids.items.len, relevances.items.len);
    for (0..n) |i| {
        try goal_associations.append(alloc, .{
            .goal_id = goal_ids.items[i],
            .relevance = relevances.items[i],
            .priority = 5,
        });
    }

    // Build RawInput.
    const input: RawInput = .{
        .source = source.?,
        .episode = episode.?,
        .atomic_facts = facts.items,
        .foresight = foresights.items,
        .goal_associations = goal_associations.items,
    };

    // In-memory store: allocate a small in-process store.
    var ids: std.atomic.Value(u64) = .init(1);
    var mgr = TriSourceManager.init(alloc, &ids);
    defer mgr.deinit();
    var lc = Lifecycle.init(alloc, .{}, &mgr);
    lc.wire();
    defer lc.fuzzy.deinit();

    const id = lc.encode(input) catch |err| {
        std.debug.print("error: encode failed: {s}\n", .{@errorName(err)});
        return err;
    };

    if (p.json) {
        var buf: [256]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{id});
        std.debug.print("{s}\n", .{s});
    } else {
        std.debug.print("added memory id={d}\n", .{id});
    }
}

// =============================================================================
// Zero-copy parsers: produce slices that reference `s` directly. `s` must
// outlive the resulting structs.
// =============================================================================

fn parseFactsConst(alloc: Allocator, s: []const u8, out: *std.ArrayList(core.Fact)) !void {
    // Format: "subject|predicate|object;subject|predicate|object;..."
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

fn parseForesightConst(alloc: Allocator, s: []const u8, out: *std.ArrayList(core.Foresight)) !void {
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

fn parseU64List(alloc: Allocator, s: []const u8, out: *std.ArrayList(u64)) !void {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const v = try std.fmt.parseInt(u64, part, 10);
        try out.append(alloc, v);
    }
}

fn parseF32List(alloc: Allocator, s: []const u8, out: *std.ArrayList(f32)) !void {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const v = try std.fmt.parseFloat(f32, part);
        try out.append(alloc, v);
    }
}
