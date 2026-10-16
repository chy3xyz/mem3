//! mem3 — `mcp` subcommand.
//!
//! Serves the Model Context Protocol over stdio: newline-delimited
//! JSON-RPC 2.0 on stdin/stdout, so any MCP client (Claude Code,
//! Claude Desktop, an IDE extension) can attach mem3 as a memory tool
//! server.
//!
//! ## Configuration
//!
//! `--data-dir` selects the store, exactly as it does for every other
//! subcommand. `MEM3_NO_PERSIST=1` runs entirely in memory, which is
//! the right choice for a client session that should not write to disk.
//!
//! ## Silence
//!
//! This subcommand prints **nothing**. stdout is the protocol channel
//! and a single stray byte there desynchronises the client's framing;
//! the daemon's silent-by-default rule (Constitution VII) applies here
//! for the same reason and with the same cost. Diagnostics go through
//! `std.log`, which the CLI's log-level handling keeps off stdout.

const std = @import("std");
const cli = @import("../cli.zig");
const cli_common = @import("cli_common.zig");
const mcp = @import("../mcp/mod.zig");

/// True when `--in-memory` was passed. It is a subcommand flag, not a
/// global one, so it arrives through `Parsed.args` like `--source` does
/// for `mem3 add`.
fn hasFlag(p: cli.Parsed, key: []const u8) bool {
    for (p.args.items) |a| {
        if (std.mem.eql(u8, a.key, key)) return true;
    }
    return false;
}

pub fn run(alloc: std.mem.Allocator, p: cli.Parsed) !void {
    // `cli_common.openStore` reads "no persistence" as an empty
    // `--data-dir`, which is how every other subcommand spells it.
    const ephemeral = hasFlag(p, "--in-memory");
    var local = p;
    if (ephemeral) local.data_dir = "";

    var store = try cli_common.openStore(alloc, local);
    defer store.deinit();

    var server = mcp.Server.init(alloc, store, 1);
    defer server.deinit();

    // fd 0 in, fd 1 out. Never stderr: stderr is for humans and the
    // client does not read it.
    try server.serveStdio(0);
}

// =============================================================================
// Tests
//
// Named directly in `src/main.zig`'s comptime block. Nothing here
// prints — see the note at the top of `src/mcp/json.zig`.
// =============================================================================

const testing = std.testing;

test "mem3 mcp: the subcommand resolves without touching the filesystem" {
    // `run` is a blocking stdio loop, so it is not called here. What is
    // pinned is the flag handling that decides whether it would write
    // to disk: `--in-memory` must be recognised as a bare flag, which
    // means checking for the key rather than for a value — an early
    // version read `a.value`, saw `null` for a valueless flag, and so
    // silently persisted every session it was told to keep ephemeral.
    var p: cli.Parsed = .{ .cmd = .mcp };
    try testing.expect(!hasFlag(p, "--in-memory"));

    var args = std.ArrayList(cli.Arg).empty;
    defer args.deinit(testing.allocator);
    try args.append(testing.allocator, .{ .key = "--in-memory", .value = null });
    try args.append(testing.allocator, .{ .key = "--port", .value = "0" });
    p.args = args;

    try testing.expect(hasFlag(p, "--in-memory"));
    // A flag that was never passed is not found.
    try testing.expect(!hasFlag(p, "--data-dir"));
    try testing.expect(!hasFlag(p, "--verbose"));
}

test "mem3 mcp: the subcommand is a known name" {
    try testing.expectEqual(cli.Subcommand.mcp, try cli.subcommandFromName("mcp"));
}
