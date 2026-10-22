---
order: 2
---

# Platforms

**macOS and Linux.** `x86_64-linux-gnu` and `aarch64-linux-gnu` both cross-compile the CLI, the library, the examples, and the benchmarks.

**Windows and WASM do not compile.** `src/lib.zig` refuses them and names the reason. The HTTP daemon uses POSIX `socket` / `bind` / `listen` / `accept` and a libc `pthread_mutex_t`. Zig 0.17 has no `std.Thread.Mutex`. The Windows branches left in `src/platform/` are not a port.

The decision and the sync-impact note: [platform scope, 2026-10-14](../library/constitution-amendments/2026-10-14-platform-scope.md).
