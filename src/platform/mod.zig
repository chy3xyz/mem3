//! mem3 platform portability layer.
//!
//! Everything in this directory exists for one reason: Zig 0.17's `std.c`
//! has a different shape on every target, so code that reaches for
//! `std.c.O`, `std.c.Stat`, `std.c.timespec` or `std.c.STDOUT_FILENO`
//! compiles on macOS and fails everywhere else — usually with an error that
//! names a `void` field rather than the missing abstraction.
//!
//! This layer gives the rest of the codebase three promises:
//!
//!  1. **No platform identifiers leak upward.** Callers express intent
//!     (`.{ .access = .read_write, .create = .truncate }`), never flags.
//!  2. **The semantics are the same everywhere.** A descriptor means the same
//!     thing, a short write means the same thing, and `sizeOf` never disturbs
//!     the read position on any target.
//!  3. **The boundaries are written down.** `windows`, `wasm32-wasi` and
//!     `wasm32-freestanding` are refused at compile time with a message that
//!     names this module and says why, instead of surfacing as a `void`
//!     field-access error somewhere unrelated.
//!
//! ## Targets
//!
//! | Target | Status |
//! |---|---|
//! | macOS (x86_64 / aarch64) | supported, primary, fully tested |
//! | Linux (x86_64 / aarch64, gnu) | supported, cross-compiles clean |
//! | Windows | **not supported** — refused at compile time |
//! | wasm32-wasi / wasm32-freestanding | **not supported** — deferred to v0.3.0 |
//!
//! ## Why Windows is out
//!
//! It was not out of laziness. The library, CLI, benchmarks and examples
//! were all ported and did cross-compile clean for `x86_64-windows`. What
//! stopped it is `src/server/http_server.zig`: raw POSIX sockets and a
//! pthread mutex. Windows needs Winsock (`ws2_32`) plus a different mutex
//! and clock story — a real port, not a flag flip. Since the daemon is the
//! product's most distinctive surface, deleting it to claim Windows support
//! would have been the wrong trade.
//!
//! The Windows branches inside `fs.zig` / `clock.zig` / `stdio.zig` / `env.zig`
//! are retained but **not compiled, not tested, not maintained**. Read them
//! as a record of the work, not a guarantee.
//!
//! ## Migration status
//!
//! The call sites have NOT all been converted yet. `fs`, `clock`, `stdio`
//! and `env` are implemented and tested; wiring them through `store.zig`,
//! `snapshot.zig`, `wal.zig` and the CLI is tracked separately. Until that
//! lands, the repository still contains direct `std.c` calls — do not read
//! this directory as evidence that they are gone.

const std = @import("std");

// Referencing these through a `comptime` block is what makes `zig test`
// collect their test blocks. A `pub const` re-export alone does NOT — a file
// reachable only as a module dependency is analysed, but its `test`
// declarations are never registered with the runner. That is how an entire
// daemon test suite once sat uncollected while CI stayed green.
comptime {
    _ = @import("clock.zig");
    _ = @import("fs.zig");
    _ = @import("stdio.zig");
    _ = @import("env.zig");
}

pub const clock = @import("clock.zig");
pub const fs = @import("fs.zig");
pub const stdio = @import("stdio.zig");
pub const env = @import("env.zig");

// Direct re-exports for the common cases.
pub const nowRealtimeMs = clock.realtimeMs;
pub const nowMonotonicNs = clock.monotonicNs;
pub const Timer = clock.Timer;
pub const Fd = fs.Fd;
pub const OpenMode = fs.OpenMode;
pub const Access = fs.Access;
pub const Create = fs.Create;
pub const Error = fs.Error;

test "platform layer reports the targets it was built for" {
    // A one-line smoke test so `zig test src/platform/mod.zig` is meaningful
    // on its own, rather than only through the main suite.
    try std.testing.expect(clock.realtimeMs() > 0);
    try std.testing.expect(clock.monotonicNs() > 0);
}
