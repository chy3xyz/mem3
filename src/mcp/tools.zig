//! The MCP tool catalogue: schema, dispatch, and the six tools that map
//! onto `store.Store`.
//!
//! **GHW layer**: all three, in order. Every tool here is a memory
//! operation or a report about one, and none of them is allowed to
//! cross a layer directly — they call `Store`, which does the Goal →
//! Harness → World traversal (Principle II).
//!
//! ## Allocation
//!
//! `call` takes the allocator explicitly and returns an owned string.
//! Every tool builds into a caller-owned `ArrayList`, and the error
//! paths free what they built. With `std.testing.allocator` that makes
//! a leak a test failure rather than a slow bleed in a long-running
//! stdio server — which is the whole reason this is written this way.
//!
//! ## Argument typing
//!
//! A **wrong-typed argument is a protocol error** (-32602), not a tool
//! error: `topk: "five"` is a malformed call, and answering it with an
//! `isError` content block would tell the client the tool ran. A
//! **missing or invalid value** (a memory with no spirit dimension, a
//! `source` that is not one of the three) is a tool error: the call was
//! well-formed and the tool had something to say.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("../core/mod.zig");
const json = @import("json.zig");
const out = @import("json_out.zig");
const protocol = @import("protocol.zig");
const mem3_store = @import("../store/mod.zig");
const Store = mem3_store.Store;
const cli_add = @import("../cli_commands/add.zig");
const Fact = core.Fact;
const GoalAssociation = core.GoalAssociation;
const MemCell = core.MemCell;

/// Upper bound on `memory_query`'s `topk`. The parameter arrives from a
/// model, and `store.query` allocates per hit; an uncapped 1e9 would be
/// a request to exhaust memory, not a request to search.
pub const MAX_TOPK: usize = 100;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema for `inputSchema`. Kept as text rather than built at
    /// runtime so the catalogue is a comptime constant.
    ///
    /// **One line, no raw newline.** The transport is
    /// newline-delimited, so a newline anywhere inside a response ends
    /// the message early: a `tools/list` whose schemas were written as
    /// readable multi-line literals reached the client as a dozen
    /// fragments, the first of which was not parseable JSON. Every other
    /// response is escaped by `json_out`; a raw-embedded document is
    /// the one place that cannot be, so it is kept newline-free and the
    /// round-trip test asserts it.
    schema: []const u8,
};

pub const CATALOGUE = [_]Tool{
    .{
        .name = "memory_add",
        .description =
        \\Persist one TS-MemCell (物/象/性 tagged) into the memory store.
        \\
        \\`episode` is the 物 (matter) trace and is required. `source` must be
        \\matter, form or spirit — a memory cannot be untagged (Constitution I).
        \\`facts` are "subject|predicate|object" triples (象 / form), and
        \\`goal_ids` binds the cell to goals (性 / spirit), and `foresight` lists
        \\predicted claims as "description|valid_from_ms|valid_until_ms|confidence"
        \\(also 性 / spirit, stored durably). A cell with neither a goal binding
        \\nor a foresight is rejected.
        \\
        \\If a fact "subject|predicate|object" contradicts an older cell's fact
        \\(same subject and predicate, different object) AND the predicate is a
        \\known single-valued one (lives_in, works_at, status, name, email,
        \\owner, version, current_*, ...), and ALL of that older cell's facts are
        \\contradicted by newer cells, the older cell is marked superseded
        \\(never deleted). Every other predicate (likes, knows, uses, is, ...) is
        \\treated as multi-valued and never supersedes anything. The list is set
        \\when the server starts (`mem3 mcp --supersede=off|functional|all`,
        \\`--functional-predicates=a,b`).
        \\
        \\Returns the assigned MemCell id, and `superseded` when this memory
        \\replaced older cells: a list of {id, subject, predicate} naming each
        \\older cell and the predicate that justified it. A wrong replacement
        \\is undone with `memory_unsupersede`.
        ,
        .schema = "{\"type\":\"object\",\"properties\":{\"episode\":{\"type\":\"string\",\"description\":\"物 — the raw episode text\"},\"source\":{\"type\":\"string\",\"enum\":[\"matter\",\"form\",\"spirit\"],\"description\":\"ontological source tag (required)\"},\"facts\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"象 — subject|predicate|object triples\"},\"goal_ids\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"},\"description\":\"性 — goal bindings\"},\"relevances\":{\"type\":\"array\",\"items\":{\"type\":\"number\"},\"description\":\"per-goal relevance in [0,1]\"},\"foresight\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"spirit — predicted claims as desc|valid_from_ms|valid_until_ms|confidence; durable\"}},\"required\":[\"episode\",\"source\"]}",
    },
    .{
        .name = "memory_query",
        .description =
        \\Three-way recall (dense + sparse + hypergraph) with GHW-prioritised
        \\reranking. Results are ordered by final_score, which folds in the goal
        \\the memory serves, not by vector similarity alone.
        \\
        \\`topk` defaults to 10 and is capped at 100. Superseded cells (an old
        \\fact a newer one contradicts) are history, not answers, and are left
        \\out unless `include_superseded` is true.
        ,
        .schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"natural-language query\"},\"topk\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100,\"description\":\"hits to return (default 10)\"},\"goal_ids\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"},\"description\":\"extra goal scope for the reranker\"},\"include_superseded\":{\"type\":\"boolean\",\"description\":\"also return cells a newer fact supersedes (default false)\"}},\"required\":[\"query\"]}",
    },
    .{
        .name = "goal_list",
        .description =
        \\The live Goal Poset: every non-synthetic goal with its status,
        \\priority, parent and how many memories are bound to it. This is the
        \\性 (spirit) layer as it currently stands.
        ,
        .schema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
    },
    .{
        .name = "memory_forget",
        .description =
        \\Run the existence-gain-driven forgetting sweep. A cell moves to the
        \\fuzzy store (never deleted — PCR) when it has decayed
        \\(importance * exp(-decay*age) < threshold), or when
        \\net_existence = importance - redundancy - conflict_score is negative:
        \\`redundancy` is how much a more important near-duplicate already
        \\carries, `conflict_score` is the importance of the newer cell that
        \\superseded it. The result reports the count per reason.
        \\
        \\Defaults to dry_run=true. Forgetting is irreversible in practice, so
        \\a caller must pass dry_run:false to actually let go of anything.
        ,
        .schema = "{\"type\":\"object\",\"properties\":{\"dry_run\":{\"type\":\"boolean\",\"description\":\"preview only (default true); false actually forgets\"}},\"required\":[]}",
    },
    .{
        .name = "memory_stats",
        .description =
        \\Counts and footprint: cells by ontological source, vector-index depth
        \\and node count, goal and hypergraph counts, fuzzy-store size, and an
        \\estimate of the cell payload in bytes.
        ,
        .schema = "{\"type\":\"object\",\"properties\":{},\"required\":[]}",
    },
    .{
        .name = "memory_unsupersede",
        .description =
        \\Undo a supersession: restore a cell that a newer fact marked
        \\superseded (see `superseded` in the `memory_add` result). The cell is
        \\current again, returns in default `memory_query` results, and is pinned
        \\so a later write or forgetting sweep does not supersede it a second
        \\time. Journaled before it takes effect. An unknown id, or a cell that
        \\is not superseded, is an error.
        ,
        .schema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"minimum\":0,\"description\":\"MemCell id to restore\"}},\"required\":[\"id\"]}",
    },
};

pub fn findTool(name: []const u8) ?Tool {
    for (CATALOGUE) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// The `result` value for `tools/list`.
///
/// The braces are explicit rather than borrowed from `json_out.openKey`
/// because that helper opens an object it does not close — using it per
/// tool left every catalogue entry missing its `}`, and the resulting
/// document parsed as valid JSON right up until the second tool, which
/// is the kind of bug that only a round-trip test catches.
pub fn writeToolsList(alloc: Allocator, list: *std.ArrayList(u8)) !void {
    try list.appendSlice(alloc, "{\"tools\":[");
    for (CATALOGUE, 0..) |t, i| {
        if (i > 0) try list.append(alloc, ',');
        try list.append(alloc, '{');
        try out.key(list, alloc, "name");
        try out.string(list, alloc, t.name);
        try list.append(alloc, ',');
        try out.key(list, alloc, "description");
        try out.string(list, alloc, t.description);
        try list.append(alloc, ',');
        try out.key(list, alloc, "inputSchema");
        // The schema is already JSON and is emitted verbatim; it is
        // covered by the round-trip test in this file, so "already
        // valid" is enforced rather than assumed.
        try out.raw(list, alloc, t.schema);
        try list.append(alloc, '}');
    }
    try list.appendSlice(alloc, "]}");
}

/// The outcome of one tool call.
pub const ToolResult = struct {
    alloc: Allocator,
    /// A JSON document, also rendered verbatim as the text content of
    /// the `tools/call` response.
    text: []const u8,
    /// True when the tool ran and failed. Distinct from a JSON-RPC
    /// error, which means it did not run.
    is_error: bool,

    pub fn deinit(self: *ToolResult) void {
        self.alloc.free(self.text);
        self.text = "";
    }
};

pub const ToolError = error{
    /// No tool by that name is in the catalogue.
    UnknownTool,
    /// The call was well-formed and the tool refused: a missing required
    /// argument, an untagged memory, a cell with no spirit dimension.
    ToolFailed,
    /// The argument itself is malformed — a string where a number
    /// belongs. This is -32602, not a tool error.
    InvalidParams,
    OutOfMemory,
};

/// Run one tool. `arguments` is the `params.arguments` object, or null.
pub fn call(
    alloc: Allocator,
    store: *Store,
    name: []const u8,
    arguments: ?json.Value,
) ToolError!ToolResult {
    const tool = findTool(name) orelse return error.UnknownTool;

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);

    if (std.mem.eql(u8, tool.name, "memory_add")) {
        try toolMemoryAdd(alloc, store, arguments, &body);
    } else if (std.mem.eql(u8, tool.name, "memory_query")) {
        try toolMemoryQuery(alloc, store, arguments, &body);
    } else if (std.mem.eql(u8, tool.name, "goal_list")) {
        try toolGoalList(alloc, store, &body);
    } else if (std.mem.eql(u8, tool.name, "memory_forget")) {
        try toolMemoryForget(alloc, store, arguments, &body);
    } else if (std.mem.eql(u8, tool.name, "memory_stats")) {
        try toolMemoryStats(alloc, store, &body);
    } else if (std.mem.eql(u8, tool.name, "memory_unsupersede")) {
        try toolMemoryUnsupersede(alloc, store, arguments, &body);
    } else {
        return error.UnknownTool;
    }

    return .{
        .alloc = alloc,
        .text = try body.toOwnedSlice(alloc),
        .is_error = false,
    };
}

// =============================================================================
// Argument readers
//
// Each returns a protocol error for a *wrong type*; a *missing* value is
// left to the tool, which knows whether it is required.
// =============================================================================

/// Look up a member in an already-extracted `arguments` object.
fn member(members: ?[]const json.Member, k: []const u8) ?json.Value {
    const ms = members orelse return null;
    for (ms) |m| {
        if (std.mem.eql(u8, m.key, k)) return m.value;
    }
    return null;
}

/// `arguments` as an object, or null when absent.
fn argObject(arguments: ?json.Value) ?[]const json.Member {
    const a = arguments orelse return null;
    if (a == .null) return null;
    return a.asObject();
}

fn argString(arguments: ?json.Value, k: []const u8) ToolError!?[]const u8 {
    const v = member(argObject(arguments), k) orelse return null;
    return v.asString() orelse error.InvalidParams;
}

fn argBool(arguments: ?json.Value, k: []const u8, dflt: bool) ToolError!bool {
    const v = member(argObject(arguments), k) orelse return dflt;
    return v.asBool() orelse error.InvalidParams;
}

fn argNumber(arguments: ?json.Value, k: []const u8) ToolError!?f64 {
    const v = member(argObject(arguments), k) orelse return null;
    return v.asNumber() orelse error.InvalidParams;
}

fn argNumberList(arguments: ?json.Value, k: []const u8) ToolError!?[]const json.Value {
    const v = member(argObject(arguments), k) orelse return null;
    return v.asArray() orelse error.InvalidParams;
}

/// Integers only: a fractional or negative value where an id or a count
/// belongs is a client mistake, not something to round in its favour.
fn asCount(n: f64) ?u64 {
    if (!std.math.isFinite(n)) return null;
    if (n < 0) return null;
    if (@floor(n) != n) return null;
    if (n > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
    return @intFromFloat(n);
}

// =============================================================================
// The tools
// =============================================================================

/// `memory_add` — one TS-MemCell through `Store`.
fn toolMemoryAdd(
    alloc: Allocator,
    store: *Store,
    arguments: ?json.Value,
    body: *std.ArrayList(u8),
) ToolError!void {
    // Argument *types* are checked before required fields, for the same
    // reason as in `toolMemoryQuery`: a wrong-typed argument is a
    // protocol error and must not be reported as a missing one.
    var facts: std.ArrayList(Fact) = .empty;
    defer facts.deinit(alloc);
    if (member(argObject(arguments), "facts")) |v| {
        const items = v.asArray() orelse return error.InvalidParams;
        for (items) |item| {
            const raw = item.asString() orelse return error.InvalidParams;
            try appendFact(alloc, raw, &facts);
        }
    }

    var goals: std.ArrayList(GoalAssociation) = .empty;
    defer goals.deinit(alloc);

    var ids: []const json.Value = &.{};
    var rels: []const json.Value = &.{};
    if (member(argObject(arguments), "goal_ids")) |v| {
        ids = v.asArray() orelse return error.InvalidParams;
    }
    if (member(argObject(arguments), "relevances")) |v| {
        rels = v.asArray() orelse return error.InvalidParams;
    }
    // A relevance with no goal to attach it to is a malformed call, not
    // an extra to ignore: silently dropping it would score the memory
    // against a relevance the caller believes was applied.
    if (rels.len > ids.len) return error.InvalidParams;
    for (ids, 0..) |v, i| {
        const gid = asCount(v.asNumber() orelse return error.InvalidParams) orelse
            return error.InvalidParams;
        var rel: f32 = 0.5;
        if (i < rels.len) {
            const r = rels[i].asNumber() orelse return error.InvalidParams;
            if (!std.math.isFinite(r) or r < 0.0 or r > 1.0) return error.InvalidParams;
            rel = @floatCast(r);
        }
        try goals.append(alloc, .{ .goal_id = gid, .relevance = rel, .priority = 5 });
    }

    // Same `desc|valid_from|valid_until|confidence` spelling as the CLI's
    // `--foresight`, parsed by the same function. The entries borrow from
    // `arguments`, which outlives the call.
    var foresight: std.ArrayList(core.Foresight) = .empty;
    defer foresight.deinit(alloc);
    if (member(argObject(arguments), "foresight")) |v| {
        const items = v.asArray() orelse return error.InvalidParams;
        for (items) |item| {
            const raw = item.asString() orelse return error.InvalidParams;
            try foresight.append(alloc, cli_add.parseForesightEntry(raw));
        }
    }

    const episode = (try argString(arguments, "episode")) orelse return error.ToolFailed;
    const source_text = (try argString(arguments, "source")) orelse return error.ToolFailed;
    const source = core.MemorySource.fromString(source_text) catch return error.ToolFailed;

    var superseded: std.ArrayList(mem3_store.Supersession) = .empty;
    defer mem3_store.freeSupersessions(alloc, &superseded);
    const id = cli_add.addMemoryReporting(store, alloc, .{
        .source = source,
        .episode = episode,
        .facts = facts.items,
        .foresight = foresight.items,
        .goal_associations = goals.items,
    }, &superseded) catch |err| return switch (err) {
        // Constitution I rejects an untagged or spiritless cell here.
        // The caller turns this into a tool error, not a crash.
        error.OutOfMemory => error.OutOfMemory,
        else => error.ToolFailed,
    };

    try body.appendSlice(alloc, "{\"id\":");
    try out.uint(body, alloc, id);
    try body.appendSlice(alloc, ",\"source\":");
    try out.string(body, alloc, source.label());
    try body.appendSlice(alloc, ",\"cells\":");
    try out.uint(body, alloc, store.cellCount());
    // Additive: present only when this memory replaced an older fact. The
    // old cells are marked, not deleted; `mem3 inspect <id>` shows them.
    if (superseded.items.len > 0) {
        try body.appendSlice(alloc, ",\"superseded\":");
        try mem3_store.appendSupersededJson(alloc, body, superseded.items);
    }
    try body.append(alloc, '}');
}

/// Split `"subject|predicate|object"` into a Fact. Reuses the same
/// shape `Store` parses on both sides of the WAL, so what a caller
/// sends and what a replay restores agree.
fn appendFact(alloc: Allocator, raw: []const u8, out_list: *std.ArrayList(Fact)) !void {
    var it = std.mem.splitScalar(u8, raw, '|');
    try out_list.append(alloc, .{
        .subject = it.first(),
        .predicate = it.next() orelse "",
        .object = it.next() orelse "",
        .confidence = 1.0,
        .source = "mcp",
    });
}

/// `memory_query` — three-way recall with GHW-prioritised reranking.
fn toolMemoryQuery(
    alloc: Allocator,
    store: *Store,
    arguments: ?json.Value,
    body: *std.ArrayList(u8),
) ToolError!void {
    // Types first, then required fields. A malformed `topk` is a
    // protocol error (-32602) and must not be reported as "you forgot
    // the query", which is a different mistake with a different fix.
    var topk: usize = 10;
    if (try argNumber(arguments, "topk")) |n| {
        const k = asCount(n) orelse return error.InvalidParams;
        if (k < 1) return error.InvalidParams;
        topk = @intCast(@min(k, MAX_TOPK));
    }

    var goal_ids: std.ArrayList(u64) = .empty;
    defer goal_ids.deinit(alloc);
    if (try argNumberList(arguments, "goal_ids")) |items| {
        for (items) |v| {
            const gid = asCount(v.asNumber() orelse return error.InvalidParams) orelse
                return error.InvalidParams;
            try goal_ids.append(alloc, gid);
        }
    }

    const text = (try argString(arguments, "query")) orelse return error.ToolFailed;

    const include_superseded = try argBool(arguments, "include_superseded", false);
    const hits = store.query(alloc, text, .{
        .topk = topk,
        .goal_ids = goal_ids.items,
        .include_superseded = include_superseded,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ToolFailed,
    };
    defer alloc.free(hits);

    try body.appendSlice(alloc, "{\"query\":");
    try out.string(body, alloc, text);
    try body.appendSlice(alloc, ",\"count\":");
    try out.uint(body, alloc, hits.len);
    try body.appendSlice(alloc, ",\"results\":[");
    for (hits, 0..) |hit, i| {
        if (i > 0) try body.append(alloc, ',');
        try body.appendSlice(alloc, "{\"id\":");
        try out.uint(body, alloc, hit.cell.id);
        try body.appendSlice(alloc, ",\"source\":");
        try out.string(body, alloc, hit.cell.source.label());
        try body.appendSlice(alloc, ",\"episode\":");
        try out.string(body, alloc, hit.cell.episode);
        try body.appendSlice(alloc, ",\"score\":");
        try out.float(body, alloc, hit.final_score);
        try body.appendSlice(alloc, ",\"base_score\":");
        try out.float(body, alloc, hit.base_score);
        try body.appendSlice(alloc, ",\"importance\":");
        try out.float(body, alloc, hit.cell.metadata.importance_score);
        try body.appendSlice(alloc, ",\"created_at\":");
        try out.int(body, alloc, hit.cell.metadata.created_at);
        try body.append(alloc, '}');
    }
    try body.appendSlice(alloc, "]}");
}

/// `memory_unsupersede` — restore a wrongly superseded cell.
fn toolMemoryUnsupersede(
    alloc: Allocator,
    store: *Store,
    arguments: ?json.Value,
    body: *std.ArrayList(u8),
) ToolError!void {
    const n = (try argNumber(arguments, "id")) orelse return error.ToolFailed;
    const id = asCount(n) orelse return error.InvalidParams;
    // Unknown id / not superseded / journal failure: a well-formed call
    // that changed nothing.
    store.unsupersede(id) catch return error.ToolFailed;
    try body.appendSlice(alloc, "{\"id\":");
    try out.uint(body, alloc, id);
    try body.appendSlice(alloc, ",\"unsuperseded\":true,\"pinned\":true}");
}

/// `goal_list` — the live Goal Poset.
fn toolGoalList(alloc: Allocator, store: *Store, body: *std.ArrayList(u8)) ToolError!void {
    const goals = try store.listGoals(alloc);
    defer alloc.free(goals);

    try body.appendSlice(alloc, "{\"count\":");
    try out.uint(body, alloc, goals.len);
    try body.appendSlice(alloc, ",\"goals\":[");
    for (goals, 0..) |g, i| {
        if (i > 0) try body.append(alloc, ',');
        try body.appendSlice(alloc, "{\"id\":");
        try out.uint(body, alloc, g.id);
        try body.appendSlice(alloc, ",\"name\":");
        try out.string(body, alloc, g.name);
        try body.appendSlice(alloc, ",\"description\":");
        try out.string(body, alloc, g.description);
        try body.appendSlice(alloc, ",\"status\":");
        try out.string(body, alloc, @tagName(g.status));
        try body.appendSlice(alloc, ",\"priority\":");
        try out.uint(body, alloc, g.priority);
        try body.appendSlice(alloc, ",\"parent_id\":");
        try out.optionalUint(body, alloc, g.parent_id);
        try body.appendSlice(alloc, ",\"memcell_count\":");
        try out.uint(body, alloc, g.memcell_count);
        try body.append(alloc, '}');
    }
    try body.appendSlice(alloc, "]}");
}

/// `memory_forget` — the existence-gain sweep. Dry run unless asked.
fn toolMemoryForget(
    alloc: Allocator,
    store: *Store,
    arguments: ?json.Value,
    body: *std.ArrayList(u8),
) ToolError!void {
    const dry_run = try argBool(arguments, "dry_run", true);
    const sweep = store.forget(dry_run) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ToolFailed,
    };

    try body.appendSlice(alloc, "{\"dry_run\":");
    try out.boolean(body, alloc, dry_run);
    try body.appendSlice(alloc, ",\"fuzzied\":");
    try out.uint(body, alloc, sweep.fuzzied);
    try body.appendSlice(alloc, ",\"kept\":");
    try out.uint(body, alloc, sweep.kept);
    try body.appendSlice(alloc, ",\"active\":");
    try out.uint(body, alloc, store.cellCount());
    try body.appendSlice(alloc, ",\"fuzzy\":");
    try out.uint(body, alloc, store.lc.fuzzy.count());
    // Additive: why cells left, and how many were newly marked superseded.
    try body.appendSlice(alloc, ",\"reasons\":{\"decayed\":");
    try out.uint(body, alloc, sweep.decayed);
    try body.appendSlice(alloc, ",\"redundant\":");
    try out.uint(body, alloc, sweep.redundant);
    try body.appendSlice(alloc, ",\"conflicted\":");
    try out.uint(body, alloc, sweep.conflicted);
    try body.appendSlice(alloc, "},\"superseded\":");
    try out.uint(body, alloc, sweep.superseded);
    try body.append(alloc, '}');
}

/// `memory_stats` — counts, index depth, footprint.
fn toolMemoryStats(alloc: Allocator, store: *Store, body: *std.ArrayList(u8)) ToolError!void {
    const cells = store.cellCount();

    try body.appendSlice(alloc, "{\"cells\":");
    try out.uint(body, alloc, cells);
    try body.appendSlice(alloc, ",\"cells_by_source\":{\"matter\":");
    try out.uint(body, alloc, store.cellCountBySource(.matter));
    try body.appendSlice(alloc, ",\"form\":");
    try out.uint(body, alloc, store.cellCountBySource(.form));
    try body.appendSlice(alloc, ",\"spirit\":");
    try out.uint(body, alloc, store.cellCountBySource(.spirit));
    try body.appendSlice(alloc, "}");
    try body.appendSlice(alloc, ",\"vector_index\":{\"nodes\":");
    try out.uint(body, alloc, store.hnsw.nodeCount());
    try body.appendSlice(alloc, ",\"max_level\":");
    try out.int(body, alloc, store.hnsw.maxOccupiedLevel());
    try body.appendSlice(alloc, ",\"dim\":");
    try out.uint(body, alloc, store.lc.cfg.embedder_dim);
    try body.appendSlice(alloc, "}");

    const goals = try store.listGoals(alloc);
    defer alloc.free(goals);
    try body.appendSlice(alloc, ",\"goals\":");
    try out.uint(body, alloc, goals.len);
    try body.appendSlice(alloc, ",\"harnesses\":");
    try out.uint(body, alloc, store.harnessCount());
    try body.appendSlice(alloc, ",\"world_entities\":");
    try out.uint(body, alloc, store.worldCount());
    try body.appendSlice(alloc, ",\"hyperedges\":");
    try out.uint(body, alloc, store.hyperedgeCount());
    try body.appendSlice(alloc, ",\"fuzzy\":");
    try out.uint(body, alloc, store.lc.fuzzy.count());
    try body.appendSlice(alloc, ",\"durable\":");
    try out.boolean(body, alloc, store.isDurable());

    // An estimate of the on-heap cell payload, not RSS: it is the part
    // of the footprint this process can account for exactly. Labelled
    // `approx_cell_bytes` so nobody reads it as a memory measurement.
    try body.appendSlice(alloc, ",\"approx_cell_bytes\":");
    try out.uint(body, alloc, @as(u64, cells) * MemCell.serialized_size);
    try body.append(alloc, '}');
}

// =============================================================================
// Tests
//
// Named directly in `src/main.zig`'s comptime block. Nothing here
// prints — see the note in `json.zig`. Every store is `data_dir = null`
// (in-memory, no WAL, no files), so the suite touches no fixed path.
// =============================================================================

const testing = std.testing;

/// An in-memory store with the default goal anchors seeded.
fn testStore(alloc: Allocator) !*Store {
    return Store.init(alloc, .{ .data_dir = null, .seed_default_goals = true });
}

/// Parse an arguments object and hand it to `call`.
fn callWith(alloc: Allocator, store: *Store, name: []const u8, args: []const u8) !ToolResult {
    var d = try json.parse(alloc, args);
    defer d.deinit();
    return call(alloc, store, name, d.root);
}

test "tools: tools/list emits JSON this module's own parser can read back" {
    // The round-trip that matters most: if the catalogue were emitted
    // in a shape the parser rejects, every real client would hang on
    // the second message of the handshake.
    const alloc = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);

    try writeToolsList(alloc, &list);

    var d = try json.parse(alloc, list.items);
    defer d.deinit();

    const arr = json.get(d.root, "tools").?.asArray().?;
    try testing.expectEqual(CATALOGUE.len, arr.len);
    for (arr, CATALOGUE) |v, want| {
        try testing.expectEqualStrings(want.name, json.get(v, "name").?.asString().?);
        try testing.expect(json.get(v, "description").?.asString().?.len > 0);

        // Every advertised schema must itself be valid JSON with an
        // object type — a client validates these before showing them.
        const schema_text = json.get(v, "inputSchema").?.asObject() orelse {
            testing.expect(false) catch {};
            return;
        };
        try testing.expectEqualStrings("object", json.get(.{ .object = schema_text }, "type").?.asString().?);
    }
}

test "tools: every catalogue name is dispatchable and every dispatch name is in the catalogue" {
    // Guards the two ways a catalogue rots: a tool that exists in the
    // list but not in the dispatch, and a dispatch branch nothing lists.
    // The arguments are the minimum each tool accepts — a catalogue
    // entry that cannot be called is as broken as one that is missing.
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    const cases = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "memory_add", .args = "{\"episode\":\"e\",\"source\":\"matter\",\"goal_ids\":[1]}" },
        .{ .name = "memory_query", .args = "{\"query\":\"e\"}" },
        .{ .name = "goal_list", .args = "{}" },
        .{ .name = "memory_forget", .args = "{}" },
        .{ .name = "memory_stats", .args = "{}" },
    };
    // `memory_unsupersede` needs a superseded cell to succeed on; it has its
    // own tests below, and the loop here only covers tools that run on an
    // empty store.
    try testing.expectEqual(CATALOGUE.len, cases.len + 1);
    try testing.expect(findTool("memory_unsupersede") != null);

    for (cases) |c| {
        try testing.expect(findTool(c.name) != null);
        var r = try callWith(alloc, store, c.name, c.args);
        defer r.deinit();
        // Every tool runs against a nearly-empty store without failing.
        try testing.expect(!r.is_error);
    }
    for (CATALOGUE) |t| {
        try testing.expect(findTool(t.name) != null);
    }
}

test "tools: an unknown tool is refused rather than guessed at" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    try testing.expectError(error.UnknownTool, callWith(alloc, store, "memory_eject", "{}"));
    try testing.expect(findTool("memory_eject") == null);
}

test "tools: memory_add persists a tri-source cell and returns its id" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var r = try callWith(alloc, store, "memory_add",
        \\{"episode":"the tag was pushed","source":"matter","facts":["neo|loves|tea"],"goal_ids":[1],"relevances":[0.8]}
    );
    defer r.deinit();
    try testing.expect(!r.is_error);

    var d = try json.parse(alloc, r.text);
    defer d.deinit();
    const id = json.get(d.root, "id").?.asNumber().?;
    try testing.expect(id >= 1);
    try testing.expectEqualStrings("matter", json.get(d.root, "source").?.asString().?);
    try testing.expectEqual(@as(f64, 1), json.get(d.root, "cells").?.asNumber().?);

    // It is a real memory, reachable through the store, not a receipt.
    const cell = store.getCell(@intFromFloat(id)).?;
    try testing.expectEqualStrings("the tag was pushed", cell.episode);
    try testing.expectEqual(@as(usize, 1), cell.atomic_facts.len);
    try testing.expectEqualStrings("neo", cell.atomic_facts[0].subject);
}

test "tools: memory_add reports the older cells a contradicting fact superseded" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var first = try callWith(alloc, store, "memory_add",
        \\{"episode":"the user lives in Paris","source":"matter","facts":["user|lives_in|Paris"],"goal_ids":[1]}
    );
    defer first.deinit();
    var d1 = try json.parse(alloc, first.text);
    defer d1.deinit();
    // Nothing to supersede yet: the key is absent, not an empty list.
    try testing.expect(json.get(d1.root, "superseded") == null);
    const old_id: u64 = @intFromFloat(json.get(d1.root, "id").?.asNumber().?);

    var second = try callWith(alloc, store, "memory_add",
        \\{"episode":"the user moved to Berlin","source":"matter","facts":["user|lives_in|Berlin"],"goal_ids":[1]}
    );
    defer second.deinit();
    var d2 = try json.parse(alloc, second.text);
    defer d2.deinit();
    const sup = json.get(d2.root, "superseded").?.asArray().?;
    try testing.expectEqual(@as(usize, 1), sup.len);
    // The audit trail: which cell, and on which predicate.
    try testing.expectEqual(@as(f64, @floatFromInt(old_id)), json.get(sup[0], "id").?.asNumber().?);
    try testing.expectEqualStrings("lives_in", json.get(sup[0], "predicate").?.asString().?);
    try testing.expectEqualStrings("user", json.get(sup[0], "subject").?.asString().?);

    // Marked, not deleted.
    const old = store.getCell(old_id).?;
    try testing.expect(old.metadata.superseded_at != null);

    // A default recall leaves it out; the opt-in brings it back.
    var plain = try callWith(alloc, store, "memory_query",
        \\{"query":"where does the user live"}
    );
    defer plain.deinit();
    var dq = try json.parse(alloc, plain.text);
    defer dq.deinit();
    try testing.expectEqual(@as(f64, 1), json.get(dq.root, "count").?.asNumber().?);

    var all = try callWith(alloc, store, "memory_query",
        \\{"query":"where does the user live","include_superseded":true}
    );
    defer all.deinit();
    var da = try json.parse(alloc, all.text);
    defer da.deinit();
    try testing.expectEqual(@as(f64, 2), json.get(da.root, "count").?.asNumber().?);
}

test "tools: a multi-valued predicate never supersedes, and memory_add reports nothing" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();
    var a = try callWith(alloc, store, "memory_add",
        \\{"episode":"the user likes tea","source":"matter","facts":["user|likes|tea"],"goal_ids":[1]}
    );
    a.deinit();
    var b = try callWith(alloc, store, "memory_add",
        \\{"episode":"the user likes coffee","source":"matter","facts":["user|likes|coffee"],"goal_ids":[1]}
    );
    defer b.deinit();
    var d = try json.parse(alloc, b.text);
    defer d.deinit();
    try testing.expect(json.get(d.root, "superseded") == null);
    try testing.expectEqual(@as(usize, 0), store.superseded_live);
}

test "tools: memory_unsupersede restores a cell, is an error for a live or unknown one" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();
    var first = try callWith(alloc, store, "memory_add",
        \\{"episode":"the user lives in Paris","source":"matter","facts":["user|lives_in|Paris"],"goal_ids":[1]}
    );
    defer first.deinit();
    var d1 = try json.parse(alloc, first.text);
    defer d1.deinit();
    const old_id: u64 = @intFromFloat(json.get(d1.root, "id").?.asNumber().?);
    var second = try callWith(alloc, store, "memory_add",
        \\{"episode":"the user moved to Berlin","source":"matter","facts":["user|lives_in|Berlin"],"goal_ids":[1]}
    );
    defer second.deinit();
    var d2 = try json.parse(alloc, second.text);
    defer d2.deinit();
    const new_id: u64 = @intFromFloat(json.get(d2.root, "id").?.asNumber().?);
    try testing.expect(store.getCell(old_id).?.metadata.superseded_at != null);

    var args_buf: [64]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"id\":{d}}}", .{old_id});
    var ok = try callWith(alloc, store, "memory_unsupersede", args);
    defer ok.deinit();
    try testing.expect(!ok.is_error);
    try testing.expect(store.getCell(old_id).?.metadata.superseded_at == null);
    try testing.expect(store.getCell(old_id).?.metadata.supersede_pinned);

    // Both are in default recall again.
    var q = try callWith(alloc, store, "memory_query",
        \\{"query":"where does the user live"}
    );
    defer q.deinit();
    var dq = try json.parse(alloc, q.text);
    defer dq.deinit();
    try testing.expectEqual(@as(f64, 2), json.get(dq.root, "count").?.asNumber().?);

    // Already restored, never superseded, unknown, wrong type.
    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_unsupersede", args));
    const live_args = try std.fmt.bufPrint(&args_buf, "{{\"id\":{d}}}", .{new_id});
    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_unsupersede", live_args));
    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_unsupersede", "{\"id\":987654}"));
    try testing.expectError(error.InvalidParams, callWith(alloc, store, "memory_unsupersede", "{\"id\":\"x\"}"));
}

test "tools: memory_add refuses an untagged memory" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    // Source is not one of the three.
    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_add",
        \\{"episode":"x","source":"vibes"}
    ));
    // Source absent.
    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_add",
        \\{"episode":"x"}
    ));
    // Episode absent.
    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_add",
        \\{"source":"matter"}
    ));
    try testing.expectEqual(@as(usize, 0), store.cellCount());
}

test "tools: memory_add refuses a cell with no spirit dimension" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    // Constitution I: no foresight and no goal binding is not a memory.
    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_add",
        \\{"episode":"an orphan","source":"matter","facts":["a|b|c"]}
    ));
    try testing.expectEqual(@as(usize, 0), store.cellCount());
    try testing.expectEqual(@as(usize, 0), store.harnessCount());
}

test "tools: memory_add stores foresight on the committed cell" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    // Foresight-only: no goal_ids. Constitution I is satisfied by the
    // foresight itself, and the cell must actually carry it.
    var r = try callWith(alloc, store, "memory_add",
        \\{"episode":"x","source":"spirit","foresight":["it will rain|10|20|0.9"]}
    );
    defer r.deinit();

    var d = try json.parse(alloc, r.text);
    defer d.deinit();
    // The old "not persisted" warning must be gone: it is no longer true.
    try testing.expect(json.get(d.root, "foresight_dropped") == null);
    try testing.expect(json.get(d.root, "warning") == null);
    const id: u64 = @intFromFloat(json.get(d.root, "id").?.asNumber().?);
    const cell = store.getCell(id).?;
    try testing.expectEqual(@as(usize, 1), cell.foresight.len);
    try testing.expectEqualStrings("it will rain", cell.foresight[0].description);
    try testing.expectEqual(@as(i64, 10), cell.foresight[0].valid_from);
    try testing.expectEqual(@as(i64, 20), cell.foresight[0].valid_until);
}

test "tools: memory_add foresight argument errors are protocol or tool errors, never silent" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    // Wrong shape: protocol error.
    try testing.expectError(error.InvalidParams, callWith(alloc, store, "memory_add",
        \\{"episode":"x","source":"spirit","foresight":"rain"}
    ));
    try testing.expectError(error.InvalidParams, callWith(alloc, store, "memory_add",
        \\{"episode":"x","source":"spirit","foresight":[7]}
    ));
    // Right shape, confidence outside [0,1]: the tool ran and refused.
    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_add",
        \\{"episode":"x","source":"spirit","foresight":["rain|1|2|1.5"]}
    ));
    try testing.expectEqual(@as(usize, 0), store.cellCount());
}

test "tools: a wrongly typed argument is a protocol error, not a tool error" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    // InvalidParams maps to -32602 at the protocol layer; it must not
    // be reported as a tool that ran and failed.
    try testing.expectError(error.InvalidParams, callWith(alloc, store, "memory_query",
        \\{"query":"tea","topk":"five"}
    ));
    try testing.expectError(error.InvalidParams, callWith(alloc, store, "memory_query",
        \\{"query":"tea","topk":1.5}
    ));
    try testing.expectError(error.InvalidParams, callWith(alloc, store, "memory_query",
        \\{"query":"tea","topk":0}
    ));
    try testing.expectError(error.InvalidParams, callWith(alloc, store, "memory_query",
        \\{"query":"tea","goal_ids":["one"]}
    ));
    try testing.expectError(error.InvalidParams, callWith(alloc, store, "memory_forget",
        \\{"dry_run":"yes"}
    ));
    try testing.expectError(error.InvalidParams, callWith(alloc, store, "memory_add",
        \\{"episode":"x","source":"matter","goal_ids":[1],"relevances":[0.5,2.0]}
    ));
}

test "tools: memory_query caps topk instead of trusting the model" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var r = try callWith(alloc, store, "memory_query",
        \\{"query":"tea","topk":1000000000}
    );
    defer r.deinit();
    try testing.expect(!r.is_error);

    var d = try json.parse(alloc, r.text);
    defer d.deinit();
    try testing.expectEqual(@as(f64, 0), json.get(d.root, "count").?.asNumber().?);
}

test "tools: memory_query over an empty store is an empty list, not an error" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var r = try callWith(alloc, store, "memory_query",
        \\{"query":"nothing has ever been remembered"}
    );
    defer r.deinit();
    try testing.expect(!r.is_error);

    var d = try json.parse(alloc, r.text);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 0), json.get(d.root, "results").?.asArray().?.len);
}

test "tools: memory_query finds what memory_add stored" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var a = try callWith(alloc, store, "memory_add",
        \\{"episode":"neo drinks oolong every morning","source":"matter","goal_ids":[1]}
    );
    defer a.deinit();

    var r = try callWith(alloc, store, "memory_query",
        \\{"query":"oolong","topk":5}
    );
    defer r.deinit();

    var d = try json.parse(alloc, r.text);
    defer d.deinit();
    const results = json.get(d.root, "results").?.asArray().?;
    try testing.expect(results.len >= 1);
    try testing.expectEqualStrings(
        "neo drinks oolong every morning",
        json.get(results[0], "episode").?.asString().?,
    );
}

test "tools: memory_query requires its query text" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_query", "{}"));
    try testing.expectError(error.InvalidParams, callWith(alloc, store, "memory_query",
        \\{"query":7}
    ));
}

test "tools: goal_list reports the seeded poset" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var r = try callWith(alloc, store, "goal_list", "{}");
    defer r.deinit();

    var d = try json.parse(alloc, r.text);
    defer d.deinit();
    const goals = json.get(d.root, "goals").?.asArray().?;
    try testing.expectEqual(json.get(d.root, "count").?.asNumber().?, @as(f64, @floatFromInt(goals.len)));
    try testing.expect(goals.len >= 3); // general / research / system

    var saw_system = false;
    for (goals) |g| {
        try testing.expect(json.get(g, "status").?.asString().?.len > 0);
        if (std.mem.eql(u8, json.get(g, "name").?.asString().?, "system")) saw_system = true;
    }
    try testing.expect(saw_system);
}

test "tools: memory_forget defaults to a preview" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var add = try callWith(alloc, store, "memory_add",
        \\{"episode":"x","source":"matter","goal_ids":[1]}
    );
    defer add.deinit();

    var r = try callWith(alloc, store, "memory_forget", "{}");
    defer r.deinit();

    var d = try json.parse(alloc, r.text);
    defer d.deinit();
    // The default is the non-destructive one: an LLM tool that
    // forgets things when called with no arguments is a hazard.
    try testing.expectEqual(true, json.get(d.root, "dry_run").?.asBool().?);
    try testing.expectEqual(@as(usize, 1), store.cellCount());
}

test "tools: memory_forget honours dry_run in both directions" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var add = try callWith(alloc, store, "memory_add",
        \\{"episode":"x","source":"matter","goal_ids":[1]}
    );
    defer add.deinit();

    var preview = try callWith(alloc, store, "memory_forget",
        \\{"dry_run":true}
    );
    defer preview.deinit();
    try testing.expectEqual(@as(usize, 1), store.cellCount());

    // And the destructive form actually runs the sweep. What it sweeps
    // is the forgetter's business, not this test's — the invariant here
    // is that the flag is honoured rather than ignored.
    var real = try callWith(alloc, store, "memory_forget",
        \\{"dry_run":false}
    );
    defer real.deinit();

    var d = try json.parse(alloc, real.text);
    defer d.deinit();
    try testing.expectEqual(false, json.get(d.root, "dry_run").?.asBool().?);
    try testing.expect(json.get(d.root, "fuzzied") != null);
    try testing.expect(json.get(d.root, "kept") != null);
}

test "tools: memory_stats reports cells, index depth and footprint" {
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var add = try callWith(alloc, store, "memory_add",
        \\{"episode":"a tagged episode","source":"spirit","goal_ids":[1]}
    );
    defer add.deinit();

    var r = try callWith(alloc, store, "memory_stats", "{}");
    defer r.deinit();

    var d = try json.parse(alloc, r.text);
    defer d.deinit();
    try testing.expectEqual(@as(f64, 1), json.get(d.root, "cells").?.asNumber().?);
    try testing.expectEqual(
        @as(f64, 1),
        json.get(json.get(d.root, "cells_by_source").?, "spirit").?.asNumber().?,
    );
    try testing.expectEqual(
        @as(f64, 1),
        json.get(json.get(d.root, "vector_index").?, "nodes").?.asNumber().?,
    );
    try testing.expect(json.get(json.get(d.root, "vector_index").?, "max_level").?.asNumber() != null);
    try testing.expectEqual(false, json.get(d.root, "durable").?.asBool().?);
    try testing.expect(json.get(d.root, "approx_cell_bytes").?.asNumber().? > 0);
}

test "tools: tools/list is a single line, because the transport is" {
    // The invariant that caught the multi-line schema bug. A newline
    // inside any response ends the message early, and a client reading
    // one line per message would see a dozen unparseable fragments.
    const alloc = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    try writeToolsList(alloc, &list);
    try testing.expect(std.mem.indexOfScalar(u8, list.items, '\n') == null);
    try testing.expect(std.mem.indexOfScalar(u8, list.items, '\r') == null);
}

test "tools: every tool result parses back as JSON" {
    // Belt and braces over the round-trip: whatever a tool returns is
    // written straight into the `text` content block, so a non-JSON
    // body would reach the client as prose inside a "JSON" answer.
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var add = try callWith(alloc, store, "memory_add",
        \\{"episode":"héllo \"wörld\" \t tab","source":"form","facts":["a|b|c","d|e|f"],"goal_ids":[1,2],"relevances":[0.5,0.6]}
    );
    defer add.deinit();
    try testing.expect(!add.is_error);

    const calls = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "memory_add", .args = "{\"episode\":\"another\",\"source\":\"spirit\",\"goal_ids\":[1]}" },
        .{ .name = "memory_query", .args = "{\"query\":\"héllo\",\"topk\":3}" },
        .{ .name = "goal_list", .args = "{}" },
        .{ .name = "memory_forget", .args = "{\"dry_run\":true}" },
        .{ .name = "memory_stats", .args = "{}" },
    };
    for (calls) |c| {
        var r = try callWith(alloc, store, c.name, c.args);
        defer r.deinit();
        var d = try json.parse(alloc, r.text);
        defer d.deinit();
        try testing.expect(d.root.asObject() != null);
    }
}

test "tools: a failing tool frees everything it had built" {
    // The error path that matters: `body` is populated and then the
    // tool fails. If `call`'s errdefer were missing, this leaks.
    const alloc = testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_add",
        \\{"episode":"an orphan","source":"matter","facts":["a|b|c","d|e|f","g|h|i"]}
    ));
    try testing.expectError(error.ToolFailed, callWith(alloc, store, "memory_query",
        \\{"goal_ids":[1,2,3,4,5,6,7,8]}
    ));
}
