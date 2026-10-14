# Roadmap

What mem3 has deferred, why, and what closing it would cost. Every figure here
was measured on the tree it describes; nothing is projected.

Current version: **`0.1.0-alpha`**. Supported targets: **macOS and Linux**.

---

## Platform support

**macOS and Linux only.** `x86_64-linux-gnu` and `aarch64-linux-gnu` both
cross-compile the entire project clean — binary, library, examples and
benchmarks, exit 0.

**Windows and WASM are refused at compile time**, each naming its reason rather
than failing later as an unrelated type error.

### Windows — deferred

A Winsock port of the daemon. `src/server/http_server.zig` binds raw POSIX
sockets (`socket`/`bind`/`listen`/`accept`) and locks a libc `pthread_mutex_t`.
Windows needs Winsock (`ws2_32`), a different mutex type, and a different clock
story. That is a real port, not a flag flip.

The work:

- Winsock equivalents for the daemon's socket calls, plus `WSACleanup`/error-code
  translation (~16 call sites across `src/platform/{fs,clock,stdio}.zig`).
- `std.process.Args.initAllocator` at the entry point — `Args.iterate` is
  `@compileError` on Windows.
- Bring the currently-unreachable Windows branches in `src/platform/` back under
  test. They were written and then withdrawn, so they are a record of completed
  work and a one-line re-enable — **not** a compatibility guarantee.

The reason it is not being done: the HTTP daemon is the product's most
distinctive surface (`/metrics`, `POST /api/memcells`, `POST /api/forget`). Dropping
the daemon to complete a cross-compile matrix would have optimised the score
instead of the product, and nothing is asking for Windows.

Rationale: [`2026-10-14-platform-scope.md`](constitution-amendments/2026-10-14-platform-scope.md).

### WASM32 — deferred to v0.3.0

Already out of scope under the existing boundary. Two concrete blockers: WASI's
open flags do not match the POSIX `ACCMODE` layout the platform layer assumes, and
wasm32's 64-bit atomics need the threads feature (`goal_tree.zig` hits this
first).

---

## Known misses against the constitution

These are measured shortfalls, not aspirations. `zig build bench` and
`mem3-bench longmemeval` reproduce both.

### 1. Write throughput — ~5× short of target

Target: **10,000 cells/sec** at release.

| Build | Measured |
|---|---|
| Debug (default `zig build`) | **192.1 cells/sec** |
| ReleaseFast (durable path) | **2,779 – 3,898 cells/sec** |

600-cell in-memory corpus, via `mem3 bench`.

**The cause is HNSW insert, not fsync.** `hnsw.insert` costs ~899 µs/op
amortised — comparable to the ~1.2 ms per-record WAL fsync, and larger than the
entire `store.addRaw_durable` pipeline (~577 µs) that contains both. Group
commit would not move this number. What would:

- Profile and reduce the per-insert neighbour-selection cost (the graph is
  `max_level=2` at 400 nodes with `avg degree 28.47` at level 0, so the ef-bounded
  expansion is touching a lot of neighbours per insert).
- Tune `ef_construction` against the insert/search trade-off rather than leaving
  it at the search-oriented default.

### 2. LongMemEval — 0.646 core, 0.000 padded, against a ≥80% target

`./zig-out/bin/mem3-bench longmemeval` reports `met_target: false`.

| Configuration | Cells | combined accuracy (answerable) | retrieval hit rate |
|---|---|---|---|
| core, no distractor padding | 144 | **0.6458** | 0.8542 |
| quarter padding | 1,144 | **0.0000** | 0.0000 |
| full padding | 4,144 | **0.0000** | 0.0000 |

> This is an **offline re-implementation of the LongMemEval protocol, not the
> official benchmark.** Locally generated cases, deterministic surface reader, no
> LLM judge, no network. Not comparable to Mem0's or Zep's published figures.
> The output carries a `disclaimer` field saying exactly this on every run.

**`lexical_hash` is the ceiling, not the retrieval layer.** The evidence is
`exhaustive_nn_hit_rate = 0.6042`, which is *identical* across all four runs —
core, quarter-padded, full-padded, and the hypergraph-disabled control. That
control is index-independent: it asks whether the gold cell is the exact cosine
nearest neighbour over every indexed vector. It does not move when the index
changes, so the failure is upstream of HNSW. Had the hit rate been high with a
low `retrieval_hit_rate`, the index would be at fault; it is not.

The only change that moves this number is a semantic embedder. `.onnx_external`
is reserved and unimplemented (it panics), and shipping one is a dependency
question that needs its own constitutional amendment — Principle IV forbids
linking a runtime, but an externally-executed model is a different shape of
claim and has not been adjudicated.

---

## Other open work

- **`--foresight` is accepted and discarded.** The CLI warns at encode time, but
  the value never reaches the WAL record or the committed cell, so a
  foresight-only cell loses its spirit dimension across a restart.
- **Consolidation has no recorded long run.** `mem3-longrun` is built to answer
  whether the lifecycle reaches steady state and reports a
  first-decile-vs-last-decile verdict, but no run is recorded in this repository,
  so no convergence claim is made.
- **HNSW recall has not saturated.** `mem3-hnsw-recall` measures recall@10
  against exhaustive scan on 400 nodes: 0.566 @ ef=10, 0.758 @ ef=100, 0.772 @
  ef=400. The default `hnsw_ef_search` is 100.
- **No group commit.** `wal.append` fsyncs on every record (~1.2 ms). Currently
  not the dominant write cost, but it will become one once insert is fixed.
- **The on-disk format is unstable.** `0.1.0-alpha`, no external users, no
  stability guarantee.
- **No licence.** No `LICENSE` file exists. The code is unlicensed and carries no
  granted rights until one is added.