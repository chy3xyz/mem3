# Constitution Amendment — Platform Scope

**Date:** 2026-10-14
**From:** v1.0.0 → v1.1.0
**Affects:** Principle IV (零依赖 + Zig 0.17 原生), Scope Boundaries, Version history

---

## 1. Rationale

Principle IV has claimed since ratification that the binary is "runnable on
macOS/Linux/Windows/WASM32". That claim was never true, and the previous
scoring pass rated the project 2.0/10 on cross-platform because of it.

An audit this cycle established what was actually broken and what was not.

**Measured, not assumed.** A cross-compile of all four targets was run against
the working tree. Every failure traced to one of two causes, neither of which
was "this project cannot be portable":

1. `build.zig` declared no `link_libc` on any of its 18 modules. `std.c`
   requires it on every non-Darwin target.
2. Four `std.c` types change shape per target. `std.c.O` is a
   `switch (native_os)` whose Windows and WASI branches have no `ACCMODE`
   field; `std.c.Stat` is `void` on Linux and Windows; `std.c.timespec` and
   `std.c.STDOUT_FILENO` are unusable on Windows.

With a `src/platform/` layer over those four types:

| Target | Before | After |
|---|---|---|
| `x86_64-linux-gnu` | FAIL (`dependency on libc must be explicitly specified`) | **full project compiles, exit 0** |
| `aarch64-linux-gnu` | FAIL (same) | **full project compiles, exit 0** |
| `x86_64-windows` | FAIL (libc + `O.ACCMODE` + `timespec` + `Args.initAllocator` + stdio handles) | refused at compile time. The guard fires, but the daemon and two examples (`forgetting_eval.zig`, `longrun.zig`) also carry their own Windows-breaking call sites — `std.c.STDOUT_FILENO`, `Args.iterate` — so the refusal is not necessarily the *first* error reported. |
| `wasm32-wasi` / `wasm32-freestanding` | FAIL (`getrandom`, 64-bit atomics, no libc) | refused at compile time with a stated reason |

## 2. The change

**macOS and Linux are supported. Windows and WASM are not.**

The Windows library port was completed and worked. It was then withdrawn for
one reason: `src/server/http_server.zig` binds raw POSIX sockets
(`socket`/`bind`/`listen`/`accept`) and uses a `pthread_mutex_t`. Windows needs
Winsock (`ws2_32`), a different mutex, and a different clock story. That is a
real port, not a flag flip.

The HTTP daemon is the product's most distinctive surface — it is what
`/metrics`, `POST /api/memcells` and `POST /api/forget` live on. Removing the
daemon to make a cross-compile matrix look complete would have optimised the
score instead of the product.

WASM was already out of scope under the existing v0.1.0-alpha boundary
("WASM32 target with full async — v0.3.0"). This amendment does not change
that; it makes the enforcement explicit at compile time rather than incidental.

## 3. Sync-impact report

Documents and code checked against the new scope:

| Artefact | Status |
|---|---|
| `src/platform/{fs,clock,stdio,env,mod}.zig` | **updated** — target table, compile-time refusal for Windows + WASM, doc-comments state that the retained Windows branches are not compiled, tested or maintained |
| `src/cli_commands/bench.zig` | **updated** — `getrusage` degrades to `null` with a reason rather than failing to compile |
| `examples/*.zig` | **updated** — four files carried byte-identical private copies of POSIX helpers; removed in favour of the platform layer. Two still name `std.c.STDOUT_FILENO` and `Args.iterate`, so on Windows they fail before reaching the guard. |
| `src/utils/time.zig`, `src/cli_commands/cli_common.zig`, `src/storage/snapshot.zig` | **updated** — migrated onto the platform layer |
| `src/server/http_server.zig` | **unchanged** — POSIX-only, now the stated reason Windows is withdrawn |
| `.specify/memory/constitution.md` | **updated** — Principle IV and Scope Boundaries |
| `README.md` | **needs review before release** — platform claims not yet audited |
| `docs/roadmap.md` | **needs a Windows entry** — see §4 |

No on-disk or on-wire format changed. No WAL record type or snapshot field was
added, reordered or resized.

## 4. What is deferred, and the cost

Deferred to a future version, with the work that would be required:

- **Windows.** A Winsock port of the daemon (~16 call sites across
  `fs`/`clock`/`stdio`), plus `std.process.Args.initAllocator` at the entry
  point. The library, CLI and benchmarks are already ported and their Windows
  branches are preserved in-tree, so this is bounded — but it is real work and
  it has no user demanding it today.
- **WASM32.** Already deferred to v0.3.0 by the existing scope boundary.
  WASI's open flags do not match the POSIX `ACCMODE` layout the platform layer
  assumes, and wasm32's 64-bit atomics need the threads feature.

## 5. Compliance

`src/platform/fs.zig` refuses `windows`, `wasi` and `freestanding` at compile
time with a message naming the reason. This is deliberate: an unsupported
target must say so **in words**, not fail three files later with
`type 'void' does not support field access`.

The retained Windows branches inside the platform layer are explicitly
The refusal is a `comptime` error and it does fire, but "fires" is not "fires
first": the daemon and two examples have their own Windows-breaking call sites, so a
Windows build reports those alongside it. The boundary is enforced either way, which
is what matters — a reader who wants the *first* error to be the explanatory one still
has work to do.

The Windows branches inside the platform layer are explicitly unreachable, untested
and unmaintained. They are a record of completed work and
a one-line re-enable, **not** a compatibility guarantee. Anyone reading them as
one has misread them.

---

**Rationale**: an unmet claim in a document that declares itself supreme over
all other documents is worse than a scoped-out target that says so. Principle IV
now states what the project builds and for which targets, and the enforcement is
in the compiler rather than in a reviewer's memory.