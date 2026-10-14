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
    /// Remaining args after subcommand + global flags, kept as key/value pairs.
    args: std.ArrayList(Arg) = .empty,

    pub fn deinit(self: *Parsed, alloc: Allocator) void {
        // args holds borrowed slices from the cmdline iterator (which
        // has program lifetime) — no per-element frees needed.
        self.args.deinit(alloc);
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
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--log-every=")) {
            p.log_every_seconds = try parseIntStrict(u64, arg["--log-every=".len..]);
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
                try liftSpaceForm(&p, last.key, arg);
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
fn liftSpaceForm(p: *Parsed, key: []const u8, v: []const u8) ParseError!void {
    if (std.mem.eql(u8, key, "--port")) {
        p.port = try parseIntStrict(u16, v);
    } else if (std.mem.eql(u8, key, "--bind")) {
        p.bind = v;
    } else if (std.mem.eql(u8, key, "--data-dir")) {
        p.data_dir = v;
    } else if (std.mem.eql(u8, key, "--log-every")) {
        p.log_every_seconds = try parseIntStrict(u64, v);
    } else if (std.mem.eql(u8, key, "--log-format")) {
        p.log_format = try logFormatFromName(v);
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
    \\  --log-every=<seconds>  Periodic summary interval (default: 60)
    \\  --maint-interval=<sec> Daemon maintenance pass interval, 0 = off
    \\  --forget-interval=<sec> Daemon forgetting sweep interval, 0 = off
    \\                          (default: 3600, so the daemon forgets on its
    \\                          own; independent of --maint-interval, and
    \\                          --maint-interval=0 also stops the sweep)
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
;

pub fn printHelp() !void {
    std.debug.print("{s}", .{HELP_TEXT});
}

// Re-export core types to keep callers' import paths stable.
pub const MemorySource = core_types.MemorySource;
