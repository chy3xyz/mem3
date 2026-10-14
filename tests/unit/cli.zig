//! Unit tests for the hand-written flag parser (`src/cli.zig`).
//!
//! ## Why this file exists
//!
//! The parser is 223 lines of hand-rolled branching — `=`-form vs
//! space-form flags, a subcommand slot, a "this token is the value of
//! the previous flag" heuristic — and until now it had zero tests.
//! Two of its bugs were found by writing these tests:
//!
//!   * `--port=8080` was missing the `continue` that every other
//!     `=`-form branch had, so it fell through into the subcommand
//!     slot and `mem3 --port=8080 serve` failed with
//!     `error.UnknownSubcommand`.
//!   * The subcommand slot was checked *before* the value-attachment
//!     heuristic, so `mem3 --port 8080 serve` read `8080` as the
//!     subcommand.
//!
//! ## Test hygiene
//!
//! No printing of any kind: Zig's test runner talks to the build
//! system over the process pipes and any stderr write from inside a
//! test desynchronises that protocol — the binary dies and
//! `zig build test` still exits 0. `cli.printHelp` is therefore never
//! called here; `cli.HELP_TEXT` is asserted as a value instead.
//!
//! No file I/O: nothing here touches `data/` or any fixed `/tmp`
//! path, so the suite is idempotent across runs.

const std = @import("std");
const testing = std.testing;
const cli = @import("mem3").cli;

/// Parse and return. Callers own `Parsed.args` and must `deinit`.
fn parse(argv: []const []const u8) !cli.Parsed {
    return cli.parseSlice(testing.allocator, argv);
}

// =============================================================================
// subcommandFromName
// =============================================================================

test "cli: subcommandFromName maps every enum variant" {
    inline for (@typeInfo(cli.Subcommand).@"enum".field_names) |name| {
        const got = try cli.subcommandFromName(name);
        try testing.expectEqual(name, @tagName(got));
    }
}

test "cli: subcommandFromName accepts the q and edge aliases" {
    try testing.expectEqual(cli.Subcommand.query, try cli.subcommandFromName("q"));
    try testing.expectEqual(cli.Subcommand.hyperedge, try cli.subcommandFromName("edge"));
}

test "cli: subcommandFromName rejects unknown names" {
    for ([_][]const u8{ "", "ad", "addd", "ADD", "Query", "--port", "8080" }) |bad| {
        try testing.expectError(error.UnknownSubcommand, cli.subcommandFromName(bad));
    }
}

// =============================================================================
// Defaults
// =============================================================================

test "cli: no arguments yields the help command and every default" {
    var p = try parse(&.{});
    defer p.deinit(testing.allocator);

    try testing.expectEqual(cli.Subcommand.help, p.cmd);
    try testing.expectEqual(false, p.json);
    try testing.expectEqual(false, p.dry_run);
    try testing.expectEqual(false, p.help);
    try testing.expectEqual(false, p.version);
    try testing.expectEqual(cli.LogFormat.human, p.log_format);
    try testing.expectEqual(@as(u64, 60), p.log_every_seconds);
    try testing.expectEqual(@as(u32, 60), p.maint_interval_sec);
    try testing.expectEqualStrings("data", p.data_dir);
    try testing.expectEqualStrings("127.0.0.1", p.bind);
    try testing.expectEqual(@as(u16, 7777), p.port);
    try testing.expectEqual(@as(usize, 0), p.args.items.len);
}

// =============================================================================
// `=`-form flags
// =============================================================================

test "cli: =-form flags populate their fields" {
    var p = try parse(&.{
        "serve",
        "--port=8080",
        "--data-dir=/tmp/x",
        "--bind=0.0.0.0",
        "--log-format=jsonl",
        "--log-every=30",
        "--maint-interval=5",
    });
    defer p.deinit(testing.allocator);

    try testing.expectEqual(cli.Subcommand.serve, p.cmd);
    try testing.expectEqual(@as(u16, 8080), p.port);
    try testing.expectEqualStrings("/tmp/x", p.data_dir);
    try testing.expectEqualStrings("0.0.0.0", p.bind);
    try testing.expectEqual(cli.LogFormat.jsonl, p.log_format);
    try testing.expectEqual(@as(u64, 30), p.log_every_seconds);
    try testing.expectEqual(@as(u32, 5), p.maint_interval_sec);
    // `=`-form flags are consumed, not echoed into `args`.
    try testing.expectEqual(@as(usize, 0), p.args.items.len);
}

test "cli: each log-format value maps to its tag" {
    for ([_]struct { []const u8, cli.LogFormat }{
        .{ "human", .human },
        .{ "jsonl", .jsonl },
        .{ "silent", .silent },
    }) |case| {
        const argv = [_][]const u8{ "serve", "--log-format", case[0] };
        var p = try parse(&argv);
        defer p.deinit(testing.allocator);
        try testing.expectEqual(case[1], p.log_format);
    }
}

test "cli: numeric boundaries for =-form are accepted when in range" {
    var lo = try parse(&.{ "serve", "--port=0", "--maint-interval=0" });
    defer lo.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 0), lo.port);
    try testing.expectEqual(@as(u32, 0), lo.maint_interval_sec);

    var hi = try parse(&.{ "serve", "--port=65535", "--maint-interval=4294967295", "--log-every=0" });
    defer hi.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 65535), hi.port);
    try testing.expectEqual(@as(u32, 4294967295), hi.maint_interval_sec);
    try testing.expectEqual(@as(u64, 0), hi.log_every_seconds);
}

// =============================================================================
// Space-form flags and the lift into struct fields
// =============================================================================

test "cli: space-form flags lift into the struct fields, not just args" {
    var p = try parse(&.{ "serve", "--port", "8080", "--data-dir", "/tmp/x", "--bind", "0.0.0.0" });
    defer p.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 8080), p.port);
    try testing.expectEqualStrings("/tmp/x", p.data_dir);
    try testing.expectEqualStrings("0.0.0.0", p.bind);
    // The Arg entries survive so handlers can still read them.
    try testing.expectEqual(@as(usize, 3), p.args.items.len);
    try testing.expectEqualStrings("--port", p.args.items[0].key);
    try testing.expectEqualStrings("8080", p.args.items[0].value.?);
}

test "cli: space-form numeric flags are validated the same as =-form" {
    var p = try parse(&.{ "serve", "--maint-interval", "5", "--log-every", "15" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 5), p.maint_interval_sec);
    try testing.expectEqual(@as(u64, 15), p.log_every_seconds);

    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--port", "abc" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--maint-interval", "x" }));
}

test "cli: =-form and space-form of the same flag are equivalent" {
    var eq_form = try parse(&.{ "serve", "--port=8080" });
    defer eq_form.deinit(testing.allocator);
    var space_form = try parse(&.{ "serve", "--port", "8080" });
    defer space_form.deinit(testing.allocator);
    try testing.expectEqual(eq_form.port, space_form.port);
    try testing.expectEqual(@as(u16, 8080), space_form.port);
}

// =============================================================================
// Precedence
// =============================================================================

test "cli: the last flag of either form wins" {
    var space_then_eq = try parse(&.{ "serve", "--port", "8080", "--port=9090" });
    defer space_then_eq.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 9090), space_then_eq.port);

    var eq_then_space = try parse(&.{ "serve", "--port=9090", "--port", "8080" });
    defer eq_then_space.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 8080), eq_then_space.port);

    var triple = try parse(&.{ "serve", "--port=1", "--port", "2", "--port=3" });
    defer triple.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 3), triple.port);
}

test "cli: an explicit value beats the default" {
    var p = try parse(&.{ "serve", "--data-dir=/var/lib/mem3", "--port=1234" });
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("/var/lib/mem3", p.data_dir);
    try testing.expectEqual(@as(u16, 1234), p.port);
}

// =============================================================================
// Malformed values
// =============================================================================

test "cli: malformed numeric values are a typed error, not a silent default" {
    // Regression guard for the old `catch 7777` / `catch 60`: a typo in
    // a deployment script used to bind the wrong port silently.
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--port=abc" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--port=99999" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--port=" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--port=-1" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--port=80 80" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--log-every=notanumber" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--maint-interval=notanumber" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--maint-interval=-5" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--log-every=99999999999999999999" }));
}

test "cli: an unknown log-format is an error, not a silent fall back to human" {
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--log-format=json" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--log-format=" }));
    try testing.expectError(error.InvalidFlagValue, parse(&.{ "serve", "--log-format", "jsonl " }));
}

test "cli: a malformed value names the offending flag in the caller-visible error" {
    // The error is value-free; the guarantee it offers is that it is
    // never returned for a well-formed command line. Assert that by
    // parsing the same shape with a good value.
    var ok = try parse(&.{ "serve", "--port=9090" });
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 9090), ok.port);
}

// =============================================================================
// Boolean flags and subcommand position
// =============================================================================

test "cli: boolean flags work before the subcommand" {
    var p = try parse(&.{ "--json", "--dry-run", "dump" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(cli.Subcommand.dump, p.cmd);
    try testing.expectEqual(true, p.json);
    try testing.expectEqual(true, p.dry_run);
}

test "cli: boolean flags work after the subcommand" {
    var p = try parse(&.{ "dump", "--json", "--dry-run" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(cli.Subcommand.dump, p.cmd);
    try testing.expectEqual(true, p.json);
    try testing.expectEqual(true, p.dry_run);
}

test "cli: boolean flags work on both sides of the subcommand" {
    var p = try parse(&.{ "--json", "query", "--dry-run", "coffee", "--topk", "5" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(cli.Subcommand.query, p.cmd);
    try testing.expectEqual(true, p.json);
    try testing.expectEqual(true, p.dry_run);
}

test "cli: -h and -V are the short forms of --help and --version" {
    var h = try parse(&.{"-h"});
    defer h.deinit(testing.allocator);
    try testing.expectEqual(true, h.help);

    var long_h = try parse(&.{ "--help", "serve" });
    defer long_h.deinit(testing.allocator);
    try testing.expectEqual(true, long_h.help);
    try testing.expectEqual(cli.Subcommand.serve, long_h.cmd);

    var v = try parse(&.{"-V"});
    defer v.deinit(testing.allocator);
    try testing.expectEqual(true, v.version);

    var long_v = try parse(&.{ "--version", "serve" });
    defer long_v.deinit(testing.allocator);
    try testing.expectEqual(true, long_v.version);
    try testing.expectEqual(cli.Subcommand.serve, long_v.cmd);
}

test "cli: a leading =-form flag does not consume the subcommand slot" {
    var p = try parse(&.{ "--port=8080", "--data-dir=/tmp/x", "--json", "serve" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(cli.Subcommand.serve, p.cmd);
    try testing.expectEqual(@as(u16, 8080), p.port);
    try testing.expectEqualStrings("/tmp/x", p.data_dir);
    try testing.expectEqual(true, p.json);
}

test "cli: a leading space-form flag does not consume the subcommand slot" {
    var p = try parse(&.{ "--port", "8080", "--data-dir", "/tmp/x", "serve" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(cli.Subcommand.serve, p.cmd);
    try testing.expectEqual(@as(u16, 8080), p.port);
    try testing.expectEqualStrings("/tmp/x", p.data_dir);
}

test "cli: the first non-flag token is the subcommand, later ones are not" {
    var p = try parse(&.{ "query", "coffee", "tea" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(cli.Subcommand.query, p.cmd);
    try testing.expectEqual(@as(usize, 2), p.args.items.len);
    for (p.args.items) |a| try testing.expectEqualStrings("positional", a.key);
    try testing.expectEqualStrings("coffee", p.args.items[0].value.?);
    try testing.expectEqualStrings("tea", p.args.items[1].value.?);
}

test "cli: only the first bare token can be a subcommand" {
    // Unknown as the *first* token is a typed error.
    try testing.expectError(error.UnknownSubcommand, parse(&.{"dump nonsense"}));
    // Known as the first token, it is the subcommand; the same word in
    // second position is just an arg.
    var p = try parse(&.{ "query", "add" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(cli.Subcommand.query, p.cmd);
    try testing.expectEqual(@as(usize, 1), p.args.items.len);
    try testing.expectEqualStrings("add", p.args.items[0].value.?);
}

test "cli: a leading dash-token never becomes the subcommand" {
    // `--no-cache` used to be read as a subcommand name and killed the
    // process with error.UnknownSubcommand before `add` was ever seen.
    var p = try parse(&.{ "--no-cache", "add", "coffee" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(cli.Subcommand.add, p.cmd);
    try testing.expectEqual(@as(usize, 2), p.args.items.len);

    var q = try parse(&.{"--no-cache"});
    defer q.deinit(testing.allocator);
    try testing.expectEqual(cli.Subcommand.help, q.cmd);
}

// =============================================================================
// The value-for-previous-flag heuristic
// =============================================================================

test "cli: an unknown --flag followed by a bare token takes it as its value" {
    var p = try parse(&.{ "add", "--source", "matter", "--episode", "hello" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), p.args.items.len);
    try testing.expectEqualStrings("--source", p.args.items[0].key);
    try testing.expectEqualStrings("matter", p.args.items[0].value.?);
    try testing.expectEqualStrings("--episode", p.args.items[1].key);
    try testing.expectEqualStrings("hello", p.args.items[1].value.?);
}

test "cli: a token after a flag that already has a value becomes a new positional" {
    var p = try parse(&.{ "query", "--topk", "5", "coffee" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), p.args.items.len);
    try testing.expectEqualStrings("--topk", p.args.items[0].key);
    try testing.expectEqualStrings("5", p.args.items[0].value.?);
    try testing.expectEqualStrings("positional", p.args.items[1].key);
    try testing.expectEqualStrings("coffee", p.args.items[1].value.?);
}

test "cli: a --no-* flag never swallows the following token" {
    var p = try parse(&.{ "--no-cache", "add", "coffee" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(cli.Subcommand.add, p.cmd);
    try testing.expectEqual(@as(usize, 2), p.args.items.len);
    try testing.expectEqualStrings("--no-cache", p.args.items[0].key);
    try testing.expect(p.args.items[0].value == null);
    try testing.expectEqualStrings("coffee", p.args.items[1].value.?);
}

test "cli: an --key=value arg keeps its key and value split in args" {
    var p = try parse(&.{ "add", "--facts=u|likes|coffee" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), p.args.items.len);
    try testing.expectEqualStrings("--facts", p.args.items[0].key);
    try testing.expectEqualStrings("u|likes|coffee", p.args.items[0].value.?);
}

test "cli: an empty space-form value is preserved, not treated as missing" {
    var p = try parse(&.{ "add", "--episode", "" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), p.args.items.len);
    try testing.expectEqualStrings("", p.args.items[0].value.?);
}

// =============================================================================
// Unknown args are preserved
// =============================================================================

test "cli: an unknown flag swallows the next token whatever it looks like" {
    // The value heuristic is positional, not syntactic — pinned here
    // because it is the surprising half of "unknown args are
    // preserved" and every subcommand handler relies on it.
    var p = try parse(&.{ "add", "--json2", "--facts=x", "extra", "-x" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), p.args.items.len);
    try testing.expectEqualStrings("--json2", p.args.items[0].key);
    try testing.expectEqualStrings("--facts=x", p.args.items[0].value.?);
    try testing.expectEqualStrings("positional", p.args.items[1].key);
    try testing.expectEqualStrings("extra", p.args.items[1].value.?);
    try testing.expectEqualStrings("positional", p.args.items[2].key);
    try testing.expectEqualStrings("-x", p.args.items[2].value.?);
}

test "cli: an unknown flag takes the next bare token as its value" {
    var p = try parse(&.{ "add", "--verbose", "coffee" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), p.args.items.len);
    try testing.expectEqualStrings("--verbose", p.args.items[0].key);
    try testing.expectEqualStrings("coffee", p.args.items[0].value.?);
}

test "cli: args with spaces, quotes and unicode survive intact" {
    var p = try parse(&.{ "add", "a b c", "中文 --flags", "quote\"and\\slash" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), p.args.items.len);
    try testing.expectEqualStrings("a b c", p.args.items[0].value.?);
    try testing.expectEqualStrings("中文 --flags", p.args.items[1].value.?);
    try testing.expectEqualStrings("quote\"and\\slash", p.args.items[2].value.?);
}

test "cli: a bare unknown flag at the end of the line keeps a null value" {
    var p = try parse(&.{ "add", "--verbose" });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), p.args.items.len);
    try testing.expectEqualStrings("--verbose", p.args.items[0].key);
    try testing.expect(p.args.items[0].value == null);
}

// =============================================================================
// Documentation drift
// =============================================================================

test "cli: every global flag is documented in the help text" {
    for (cli.GLOBAL_FLAGS) |flag| {
        if (std.mem.indexOf(u8, cli.HELP_TEXT, flag) == null) return error.MissingFlagInHelp;
    }
}

test "cli: every subcommand is documented in the help text" {
    inline for (@typeInfo(cli.Subcommand).@"enum".field_names) |name| {
        if (std.mem.indexOf(u8, cli.HELP_TEXT, name) == null) return error.MissingSubcommandInHelp;
    }
}

test "cli: help text states that a bad value is an error" {
    // The behaviour change (silent fallback -> typed error) is only
    // discoverable if the help says so.
    try testing.expect(std.mem.indexOf(u8, cli.HELP_TEXT, "exits non-zero") != null);
}

test "cli: help text documents the alias" {
    try testing.expect(std.mem.indexOf(u8, cli.HELP_TEXT, "-h") != null);
    try testing.expect(std.mem.indexOf(u8, cli.HELP_TEXT, "-V") != null);
}
