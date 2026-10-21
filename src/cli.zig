//! CLI parser. Zero-dependency flag parser. Outputs a `Parsed` struct that
//! the dispatcher in `main.zig` consumes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core_types = @import("core/types.zig");
const core_config = @import("core/config.zig");

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
    mcp,
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
    /// True only when the user typed `--log-format`. The default (`human`)
    /// is the silent daemon of Constitution VII; naming a format on the
    /// command line is what opts the daemon into emitting log lines.
    log_format_explicit: bool = false,
    /// True only when the user typed `--log-every`. The 60 s default must
    /// not switch the periodic summary on by itself: a daemon that has
    /// not been asked to talk stays silent.
    log_every_explicit: bool = false,
    /// WAL durability mode (`--wal-sync`). `always` is the historical
    /// per-record fsync and the default.
    wal_sync: core_config.Config.WalSync = .always,
    data_dir: []const u8 = "data",
    bind: []const u8 = "127.0.0.1",
    port: u16 = 7777,
    /// Seconds between daemon maintenance passes. 0 disables the thread
    /// entirely, which is what the test suite and `--maint-interval=0`
    /// want — a background thread racing assertions is a flaky test.
    maint_interval_sec: u32 = 60,
    /// Seconds between the daemon's scheduled forgetting sweeps.
    /// 0 turns scheduled forgetting off.
    ///
    /// Default ON, because a daemon that never calls `store.forget` never
    /// forgets anything: it retains every memory it has ever been given
    /// and reports `mem3_forgetting_rate 0` forever, which reads as a
    /// healthy memory system rather than the absence of the mechanism.
    ///
    /// Independent of `maint_interval_sec` on purpose. The maintenance
    /// pass is about a 7-day goal-staleness rule and a 60s cadence is
    /// cheap; forgetting is an O(cells) walk under the store lock whose
    /// decision timescale is measured in days (see
    /// `server.DEFAULT_FORGET_INTERVAL_SEC`). Deriving one from the other
    /// would mean a 1s maintenance interval silently became a 1s
    /// forgetting interval.
    forget_interval_sec: u32 = 3600,
    dry_run: bool = false,
    help: bool = false,
    version: bool = false,
    /// Path to an external embedding program, or null for the built-in
    /// hashed lexer. Opting in is the only way to get a real semantic
    /// embedding without mem3 taking a dependency — the child process is
    /// spawned once and kept for the life of the store, so there is no
    /// per-write process spawn.
    ///
    /// Deliberately not a `Config.EmbedderKind` variant: an enum cannot
    /// carry a program path, and `init(kind, dim)` has nowhere to put one.
    /// That is why this is a `BuildOptions` field and not a config one.
    embedder_cmd: ?[]const u8 = null,
    /// Arguments for `embedder_cmd`, verbatim. No shell, so quoting and
    /// globbing are the caller's problem. Collected into a list because a
    /// repeat-single-flag parser cannot express `llama-server --port X`.
    embedder_args: std.ArrayList([]const u8) = .empty,
    /// Remaining args after subcommand + global flags, kept as key/value pairs.
    args: std.ArrayList(Arg) = .empty,

    pub fn deinit(self: *Parsed, alloc: Allocator) void {
        // Both hold borrowed slices from the cmdline iterator (which has
        // program lifetime) — no per-element frees needed.
        self.args.deinit(alloc);
        self.embedder_args.deinit(alloc);
    }
};

/// Every way `parse` can fail.
///
/// `UnknownSubcommand` — the first non-flag token is not a known
/// subcommand. `InvalidFlagValue` — a flag that must carry a
/// parseable value was given one that does not parse (or, for
/// `--log-format`, one that is not a known format).
///
/// `InvalidFlagValue` replaced a silent fallback that used to return
/// the default: `--port=abc` used to become `--port=7777` with no
/// diagnostic, so a typo in a deployment script bound the daemon to
/// the wrong port and said nothing. A hand-written parser is exactly
/// where silent misparses live; failing loudly is the cheaper bug.
pub const ParseError = error{
    UnknownSubcommand,
    InvalidFlagValue,
    OutOfMemory,
};

/// Parse the process command line. Thin wrapper over `parseSlice`
/// that exists only to keep `std.process.Args.Iterator` out of the
/// signature: on POSIX that type can only be built by reaching into
/// its `inner` field with platform-specific layout, which makes the
/// parser untestable off Linux/macOS.
pub fn parse(alloc: Allocator, iter: *ArgIterator) ParseError!Parsed {
    var raw_args: std.ArrayList([]const u8) = .empty;
    defer raw_args.deinit(alloc);
    while (iter.next()) |raw| {
        try raw_args.append(alloc, raw);
    }
    return parseSlice(alloc, raw_args.items);
}

/// Parse an argv slice (argv[0] excluded) into `Parsed`.
///
/// Slices returned in `Parsed.args` borrow from `raw_args` / its
/// backing storage, which for the real command line has program
/// lifetime.
pub fn parseSlice(alloc: Allocator, raw_args: []const []const u8) ParseError!Parsed {
    var p: Parsed = .{
        .cmd = .help,
    };
    // Without this, every `error.InvalidFlagValue` return leaked the
    // args list allocated for the tokens parsed before the bad one.
    errdefer p.args.deinit(alloc);

    var next_subcommand = true;
    for (raw_args) |arg| {
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
            p.log_format = try logFormatFromName(arg["--log-format=".len..]);
            p.log_format_explicit = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--log-every=")) {
            p.log_every_seconds = try parseIntStrict(u64, arg["--log-every=".len..]);
            p.log_every_explicit = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--wal-sync=")) {
            p.wal_sync = try walSyncFromName(arg["--wal-sync=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--data-dir=")) {
            p.data_dir = arg["--data-dir=".len..];
            continue;
        }
        // The `=` form is matched here, one flag at a time, and the
        // space form in `liftSpaceForm` below. A flag added to only one of
        // the two parses in one and silently does nothing in the other:
        // `--embedder-cmd=/path` landed in `p.args` and was never read, so
        // the store quietly fell back to the built-in lexer and indexed
        // with it. A flag that parses in one form and not the other is
        // the worst kind, because it looks like it worked.
        if (std.mem.startsWith(u8, arg, "--embedder-cmd=")) {
            p.embedder_cmd = arg["--embedder-cmd=".len..];
            continue;
        }
        // Repeatable, same as the space form.
        if (std.mem.startsWith(u8, arg, "--embedder-arg=")) {
            try p.embedder_args.append(alloc, arg["--embedder-arg=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--bind=")) {
            p.bind = arg["--bind=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--port=")) {
            p.port = try parseIntStrict(u16, arg["--port=".len..]);
            // The `continue` used to be missing here. Without it the
            // token fell through to the subcommand slot, so
            // `mem3 --port=8080 serve` died with
            // `error.UnknownSubcommand` on the literal string
            // "--port=8080" while `mem3 serve --port=8080` worked.
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--maint-interval=")) {
            p.maint_interval_sec = try parseIntStrict(u32, arg["--maint-interval=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--forget-interval=")) {
            p.forget_interval_sec = try parseIntStrict(u32, arg["--forget-interval=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--wal-sync")) {
            try p.args.append(alloc, .{ .key = "--wal-sync", .value = null });
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
        if (std.mem.eql(u8, arg, "--embedder-cmd")) {
            try p.args.append(alloc, .{ .key = "--embedder-cmd", .value = null });
            continue;
        }
        // Repeatable: `--embedder-arg=--model --embedder-arg=/path/to/m.bin`.
        if (std.mem.eql(u8, arg, "--embedder-arg")) {
            try p.args.append(alloc, .{ .key = "--embedder-arg", .value = null });
            continue;
        }
        // Track if the previous arg was a flag expecting a value.
        //
        // This runs *before* the subcommand slot on purpose: the first
        // non-flag token used to become the subcommand even when it
        // was plainly the value of a leading space-form flag, so
        // `mem3 --port 8080 serve` failed with UnknownSubcommand while
        // `mem3 --port=8080 serve` failed for the same reason.
        //
        // The heuristic is positional, not syntactic: an unknown flag
        // with a null value takes whatever token comes next, including
        // one that looks like `--key=value`. Subcommand handlers depend
        // on that (`mem3 add --source matter --facts "u|l|c"`), so it
        // is pinned by tests rather than tightened here.
        if (p.args.items.len > 0) {
            const last = &p.args.items[p.args.items.len - 1];
            if (last.value == null and !std.mem.startsWith(u8, last.key, "--no-")) {
                // Heuristic: this token is the value for the previous flag.
                last.value = arg;
                // Lift a known global flag's space-form value into its
                // field right here rather than in a second pass, so
                // `--port 8080 --port=9090` and `--port=9090 --port 8080`
                // both resolve last-wins. Unknown flags keep their Arg
                // entry untouched for the subcommand handler to read.
                try liftSpaceForm(alloc, &p, last.key, arg);
                continue;
            }
        }
        if (next_subcommand and !std.mem.startsWith(u8, arg, "-")) {
            next_subcommand = false;
            p.cmd = try subcommandFromName(arg);
            continue;
        }
        try p.args.append(alloc, parseArg(alloc, arg));
    }
    return p;
}

/// Apply a space-form global flag's value to its `Parsed` field.
/// Flags the parser does not own (`--source`, `--topk`, ...) are left
/// for the subcommand handler, which reads them out of `Parsed.args`.
fn liftSpaceForm(alloc: Allocator, p: *Parsed, key: []const u8, v: []const u8) ParseError!void {
    if (std.mem.eql(u8, key, "--port")) {
        p.port = try parseIntStrict(u16, v);
    } else if (std.mem.eql(u8, key, "--bind")) {
        p.bind = v;
    } else if (std.mem.eql(u8, key, "--data-dir")) {
        p.data_dir = v;
    } else if (std.mem.eql(u8, key, "--embedder-cmd")) {
        p.embedder_cmd = v;
    } else if (std.mem.eql(u8, key, "--embedder-arg")) {
        try p.embedder_args.append(alloc, v);
    } else if (std.mem.eql(u8, key, "--log-every")) {
        p.log_every_seconds = try parseIntStrict(u64, v);
        p.log_every_explicit = true;
    } else if (std.mem.eql(u8, key, "--log-format")) {
        p.log_format = try logFormatFromName(v);
        p.log_format_explicit = true;
    } else if (std.mem.eql(u8, key, "--wal-sync")) {
        p.wal_sync = try walSyncFromName(v);
    } else if (std.mem.eql(u8, key, "--maint-interval")) {
        p.maint_interval_sec = try parseIntStrict(u32, v);
    } else if (std.mem.eql(u8, key, "--forget-interval")) {
        p.forget_interval_sec = try parseIntStrict(u32, v);
    }
}

fn parseIntStrict(comptime T: type, s: []const u8) ParseError!T {
    // Overflow and InvalidCharacter both collapse to one error: from
    // the caller's point of view `--port=99999` and `--port=abc` are
    // the same mistake, and the flag name in the message identifies
    // which one it was.
    return std.fmt.parseInt(T, s, 10) catch error.InvalidFlagValue;
}

fn logFormatFromName(v: []const u8) ParseError!LogFormat {
    if (std.mem.eql(u8, v, "human")) return .human;
    if (std.mem.eql(u8, v, "jsonl")) return .jsonl;
    if (std.mem.eql(u8, v, "silent")) return .silent;
    return error.InvalidFlagValue;
}

fn walSyncFromName(v: []const u8) ParseError!core_config.Config.WalSync {
    return core_config.Config.WalSync.parse(v) catch error.InvalidFlagValue;
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

pub fn subcommandFromName(name: []const u8) ParseError!Subcommand {
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
    if (std.mem.eql(u8, name, "mcp")) return .mcp;
    if (std.mem.eql(u8, name, "help")) return .help;
    if (std.mem.eql(u8, name, "version")) return .version;
    return error.UnknownSubcommand;
}

/// Every global flag `parseSlice` understands, in help order.
/// `tests/unit/cli.zig` asserts each one appears in `HELP_TEXT`: the
/// `--maint-interval` flag shipped with no test *and* no help entry,
/// which is how nobody noticed either.
pub const GLOBAL_FLAGS = [_][]const u8{
    "--json",
    "--data-dir",
    "--bind",
    "--port",
    "--log-format",
    "--log-every",
    "--wal-sync",
    "--maint-interval",
    "--forget-interval",
    "--dry-run",
    "--help",
    "--version",
};

/// Help text as a value so tests can assert on it without printing.
/// `printHelp` must stay the only thing that writes it: a test that
/// called it would write to the test runner's protocol pipe.
pub const HELP_TEXT =
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
    \\  mcp           Serve the Model Context Protocol over stdio
    \\  bench         Run the in-process smoke benchmark suite
    \\  help          Show this help
    \\  version       Show version
    \\
    \\GLOBAL FLAGS:
    \\  --json                 Emit JSON output
    \\  --data-dir=<path>      Storage directory (default: data)
    \\  --bind=<addr>          Daemon bind address (default: 127.0.0.1)
    \\  --port=<port>          Daemon port (default: 7777)
    \\  --log-format=<fmt>     human | jsonl | silent
    \\  --log-every=<seconds>  Periodic summary interval; emitted only when this
    \\                          flag is given (`serve`, to stderr; default 60)
    \\  --wal-sync=<mode>      WAL durability: always | group | interval:<ms>
    \\                          always (default) fsyncs every record before it is
    \\                          acknowledged. group batches concurrent writers
    \\                          into one fsync and still acknowledges only after
    \\                          it. interval:N is WEAKER: acknowledged once in the
    \\                          OS cache, fsync at most every N ms, so a power cut
    \\                          can lose ~N ms of writes (a process crash cannot).
    \\  --maint-interval=<sec> Daemon maintenance pass interval, 0 = off
    \\  --forget-interval=<sec> Daemon forgetting sweep interval, 0 = off
    \\                          (default: 3600, so the daemon forgets on its
    \\                          own; independent of --maint-interval, and
    \\                          --maint-interval=0 also stops the sweep)
    \\  --embedder-cmd=<path>  Delegate embedding to a long-lived external
    \\                          program (line protocol, see
    \\                          retrieval/embedder.zig). Omit for the built-in
    \\                          zero-dependency hashed lexer.
    \\  --embedder-arg=<arg>   One argument for --embedder-cmd; repeatable.
    \\                          No shell is involved.
    \\  --dry-run              Show what would be done, don't write
    \\                          (`serve`: forgetting sweeps preview only)
    \\  --help, -h             Show this help
    \\  --version, -V          Show version
    \\
    \\A flag value may also be given as the next token: `--port 8080`.
    \\An unparseable value is an error, not a silent fallback to the
    \\default — `mem3 --port=abc` exits non-zero instead of binding 7777.
    \\
    \\EXAMPLES:
    \\  mem3 add --source matter --episode "hello" --facts "u|likes|coffee"
    \\  mem3 query "coffee" --topk 5
    \\  mem3 serve --port 7777 --bind 127.0.0.1
    \\  mem3 serve --forget-interval 0     # retain everything (opt out)
    \\  mem3 serve --dry-run # sweep without deleting
    \\  mem3 bench --json
    \\
    \\MCP (one JSON-RPC message per line on stdin/stdout):
    \\  mem3 mcp                    # attach mem3 to an MCP client
    \\  mem3 mcp --data-dir=./data  # same store the CLI uses
    \\  mem3 mcp --in-memory         # ephemeral session, no writes
    \\
;

pub fn printHelp() !void {
    std.debug.print("{s}", .{HELP_TEXT});
}

// Re-export core types to keep callers' import paths stable.
pub const MemorySource = core_types.MemorySource;
