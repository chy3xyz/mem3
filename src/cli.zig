//! CLI parser. Zero-dependency flag parser. Outputs a `Parsed` struct that
//! the dispatcher in `main.zig` consumes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core_types = @import("core/types.zig");

const ArgIterator = std.process.Args.Iterator;

/// Subcommand tag.
pub const Subcommand = enum {
    add,
    query,
    goal,
    hyperedge,
    dump,
    inspect,
    consolidate,
    forget,
    serve,
    bench,
    help,
    version,
};

/// A free-form positional/flag/value pair, retained for subcommand handlers.
pub const Arg = struct {
    key: []const u8,
    value: ?[]const u8 = null,
};

pub const LogFormat = enum { human, jsonl, silent };

/// All global flags + the subcommand.
pub const Parsed = struct {
    cmd: Subcommand,
    json: bool = false,
    log_format: LogFormat = .human,
    log_every_seconds: u64 = 60,
    data_dir: []const u8 = "data",
    bind: []const u8 = "127.0.0.1",
    port: u16 = 7777,
    /// Seconds between daemon maintenance passes. 0 disables the thread
    /// entirely, which is what the test suite and `--maint-interval=0`
    /// want — a background thread racing assertions is a flaky test.
    maint_interval_sec: u32 = 60,
    dry_run: bool = false,
    help: bool = false,
    version: bool = false,
    /// Remaining args after subcommand + global flags, kept as key/value pairs.
    args: std.ArrayList(Arg) = .empty,

    pub fn deinit(self: *Parsed, alloc: Allocator) void {
        // args holds borrowed slices from the cmdline iterator (which
        // has program lifetime) — no per-element frees needed.
        self.args.deinit(alloc);
    }
};

pub fn parse(alloc: Allocator, iter: *ArgIterator) !Parsed {
    var p: Parsed = .{
        .cmd = .help,
    };

    var next_subcommand = true;
    while (iter.next()) |raw| {
        const arg = raw;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            p.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            p.version = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            p.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            p.dry_run = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--log-format=")) {
            const v = arg["--log-format=".len..];
            p.log_format = if (std.mem.eql(u8, v, "jsonl"))
                .jsonl
            else if (std.mem.eql(u8, v, "silent"))
                .silent
            else
                .human;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--log-every=")) {
            const v = arg["--log-every=".len..];
            p.log_every_seconds = std.fmt.parseInt(u64, v, 10) catch 60;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            p.data_dir = arg["--data-dir=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--bind=")) {
            p.bind = arg["--bind=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--port=")) {
            p.port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch 7777;
        } else if (std.mem.startsWith(u8, arg, "--maint-interval=")) {
            p.maint_interval_sec = std.fmt.parseInt(u32, arg["--maint-interval=".len..], 10) catch 60;
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            try p.args.append(alloc, .{ .key = "--port", .value = null });
            continue;
        }
        if (std.mem.eql(u8, arg, "--bind")) {
            try p.args.append(alloc, .{ .key = "--bind", .value = null });
            continue;
        }
        if (std.mem.eql(u8, arg, "--data-dir")) {
            try p.args.append(alloc, .{ .key = "--data-dir", .value = null });
            continue;
        }
        if (next_subcommand) {
            next_subcommand = false;
            p.cmd = try subcommandFromName(arg);
            continue;
        }
        // Track if the previous arg was a flag expecting a value.
        if (p.args.items.len > 0) {
            const last = &p.args.items[p.args.items.len - 1];
            if (last.value == null and !std.mem.startsWith(u8, last.key, "--no-")) {
                // Heuristic: this token is the value for the previous flag.
                last.value = arg;
                continue;
            }
        }
        try p.args.append(alloc, parseArg(alloc, arg));
    }
    // Post-process: lift space-form flag values into their fields.
    for (p.args.items) |a| {
        if (a.value) |v| {
            if (std.mem.eql(u8, a.key, "--port")) {
                p.port = std.fmt.parseInt(u16, v, 10) catch p.port;
            } else if (std.mem.eql(u8, a.key, "--bind")) {
                p.bind = v;
            } else if (std.mem.eql(u8, a.key, "--data-dir")) {
                p.data_dir = v;
            }
        }
    }
    return p;
}

fn parseArg(_: Allocator, raw: []const u8) Arg {
    if (std.mem.startsWith(u8, raw, "--")) {
        if (std.mem.findScalar(u8, raw, '=')) |eq| {
            // Borrowed slices: cmdline has program-lifetime strings.
            return .{ .key = raw[0..eq], .value = raw[eq + 1 ..] };
        }
        return .{ .key = raw, .value = null };
    }
    return .{ .key = "positional", .value = raw };
}

pub fn subcommandFromName(name: []const u8) !Subcommand {
    if (std.mem.eql(u8, name, "add")) return .add;
    if (std.mem.eql(u8, name, "query") or std.mem.eql(u8, name, "q")) return .query;
    if (std.mem.eql(u8, name, "goal")) return .goal;
    if (std.mem.eql(u8, name, "hyperedge") or std.mem.eql(u8, name, "edge")) return .hyperedge;
    if (std.mem.eql(u8, name, "dump")) return .dump;
    if (std.mem.eql(u8, name, "inspect")) return .inspect;
    if (std.mem.eql(u8, name, "consolidate")) return .consolidate;
    if (std.mem.eql(u8, name, "forget")) return .forget;
    if (std.mem.eql(u8, name, "serve")) return .serve;
    if (std.mem.eql(u8, name, "bench")) return .bench;
    if (std.mem.eql(u8, name, "help")) return .help;
    if (std.mem.eql(u8, name, "version")) return .version;
    return error.UnknownSubcommand;
}

pub fn printHelp() !void {
    const help_text =
        \\mem3 — TriSource-EverOS
        \\
        \\USAGE:
        \\  mem3 <subcommand> [flags]
        \\
        \\SUBCOMMANDS:
        \\  add           Encode and persist a TS-MemCell
        \\  query         Three-way recall with GHW-prioritized ranking
        \\  goal          Manage the Goal Poset (add/list/status)
        \\  hyperedge     Manage hypergraph edges
        \\  dump          Export the full store as JSONL
        \\  inspect       Show a MemCell + its hypergraph neighborhood
        \\  consolidate   Run the consolidation pipeline
        \\  forget        Run the existence-gain-driven forgetting sweep
        \\  serve         Start the HTTP daemon (default port 7777)
        \\  bench         Run performance benchmarks
        \\  help          Show this help
        \\  version       Show version
        \\
        \\GLOBAL FLAGS:
        \\  --json                 Emit JSON output
        \\  --data-dir=<path>      Storage directory (default: data)
        \\  --log-format=<fmt>     human | jsonl | silent
        \\  --log-every=<seconds>  Periodic summary interval (default: 60)
        \\  --dry-run              Show what would be done, don't write
        \\  --help, -h             Show this help
        \\  --version, -V          Show version
        \\
        \\EXAMPLES:
        \\  mem3 add --source matter --episode "hello" --facts "u|likes|coffee"
        \\  mem3 query "coffee" --topk 5
        \\  mem3 serve --port 7777 --bind 127.0.0.1
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

// Re-export core types to keep callers' import paths stable.
pub const MemorySource = core_types.MemorySource;
