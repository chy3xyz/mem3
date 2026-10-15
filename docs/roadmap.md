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

- **`platform.clock.Timer` returns zero for folded measurements in optimised
  builds.** Under `-O ReleaseFast`/`ReleaseSafe`, LLVM hoists two
  `clock_gettime` calls above the region being timed and subtracts identical
  readings. Measured: Debug 23,951,000 ns / ReleaseSafe **0 ns** / ReleaseFast
  **0 ns** for the same 20M-iteration loop. It reaches shipped output —
  `mem3-bench multihop` reports `"min_ns":0.000000` over 1,000 real
  traversals that each reach ~49 nodes. The in-tree test
  (`Timer measures a non-zero, monotonic duration`) passes because
  `zig build test` builds in Debug. Four fixes were tried and measured — memory
  clobber, `@call(.never_inline)`, function-pointer indirection, and
  `mach_absolute_time` — and all four still fold. The remaining approach is a
  per-architecture non-foldable cycle counter through inline asm (`rdtsc` /
  `cntvct_el0`), which is **not written** because it cannot be validated on
  Linux from this machine. Until then, treat min/tail-percentile latencies as
  unreliable and report p50.
- **Snapshot restore now rebuilds the vector index** (fixed 2026-10-15).
  `Store.loadSnapshot` restored `addCell` + `cell_index.put` but never
  `hnsw.insert`, and `sync` is snapshot-and-truncate: `takeSnapshot` unlinks
  the WAL on its way out, so a restart after any sync had nothing left to
  replay. The store then looked intact — `dump`, `cellCount` and
  `GET /api/memcells` all listed every cell — while `hnsw.count` stayed at
  zero and every vector query returned an empty slice rather than an error.
  Reproduced end to end: four cells, `POST /api/sync`, restart,
  `mem3 query "coffee"` returned `{"query":[],"count":0}` where the
  no-sync control returned `{"query":[4,6,5],"count":3}`. Fixed by embedding
  and indexing each restored row in the same loop; after the fix the
  post-sync query returns exactly the control's three hits.
- **Forget removes from `cell_index`/`mgr` but not from HNSW**, so stale nodes
  persist in the vector index after a sweep. Note this now interacts with the
  fix above: a fuzzied cell is in HNSW before a restart and is not restored
  into HNSW afterwards, so the index and the cell map disagree across a
  restart. Which of those two is correct is an open design question, not a
  settled one.
- **`addRaw`'s `errdefer _ = self.ids.fetchSub(1, .monotonic)`** returns an id to
  a *shared* monotonic counter. Under daemon concurrency that can hand a later
  insert an id a live cell already holds. Currently masked by
  `TriSourceManager.addWithId` rejecting the duplicate, but it is the same
  latent hazard and nothing tests the ordering that makes it safe.
- **`--foresight` is accepted and discarded.** The CLI warns at encode time, but
  the value never reaches the WAL record or the committed cell, so a
  foresight-only cell loses its spirit dimension across a restart.
- **Consolidation does not reach steady state, and no run length will show it.**
  Recorded run: 2,124 cycles / 397 s / 46,958 cells. `d_cells` first-decile mean
  21.632, last-decile mean 21.849 — flat. The cause is arithmetic, not a short
  run: a cell is only fuzzied once `importance × exp(-decay_rate × age_days)`
  drops below `forgetting_threshold`, which at the measured `imp_mean = 0.747`
  takes **40 days (matter) / 67 days (form) / 201 days (spirit)**. The run was
  0.0046 days. Closing this needs a compressed clock or a fixture of pre-aged
  cells, not a longer run. Note the closing verdict only prints this
  calculation when `--stats-every=N` is set.
- **Consolidation was not deterministic; now it is** (fixed 2026-10-15).
  `Consolidator.consolidate` collected its cell list straight out of three
  `AutoHashMap` iterators and then keyed everything off the index into that
  list: `bitsets` was laid out by it, `cluster_map` was keyed by union-find
  roots chosen by it, and `generateAbstract` took `indices[0]` as the
  cluster's representative cell. Hash-map iteration order is unspecified *and*
  shifts with insertion order — measured on ids 1000..1008, filling forwards
  iterates `1006 1007 1001 1000 1003 1004 1008 1002 1005` and filling
  backwards iterates `1006 1007 1001 1003 1008 1004 1000 1002 1005`. So
  **which episode became an abstract's text depended on insertion order and
  on whether anything had been forgotten in between.** Separately,
  `abstract_ids` was assembled by iterating `cluster_map`, another hash map,
  so the order the caller journals and indexes them in varied per run even
  when the clustering was identical. Fixed by sorting the cell list by id
  (O(n log n), and it also makes a cell's index stable across passes — the
  precondition any incremental clustering needs) and by sorting the returned
  `abstract_ids` ascending.
- **Consolidation is all-pairs and superlinear.** `Consolidator.consolidate`
  compares every cell pair. Over the run above, 89.9× more cells cost 154.6×
  more consolidation time (exponent 1.12; 126.9 ms/pass at 518 cells →
  **20,257.6 ms/pass at 44,909 cells**). At the constitutional 100k scale that
  is ~5.0 billion pair comparisons per pass. The pair loop itself was already
  made 75× faster and bit-identical; O(n²) is the remaining problem.
  **An inverted index is not the obvious win here and was rejected on
  arithmetic**: the signature is 512 bits with ~55 tokens per cell, so bucket
  collisions are dense and the candidate set comes out at ~2.95n² against
  n²/2 for the full scan — about six times *worse*. The promising direction
  is keeping the union-find across passes and comparing only newly arrived
  cells against everything already present: at the long run's 400 cells per
  pass that is ~1.8e7 pairs instead of 1.01e9, roughly 56×. A standalone
  probe confirms this yields an **identical partition** (pair-wise agreement
  640000/640000; only the chosen root differs, and the root is just a
  `cluster_map` key). It costs resident memory for a per-cell signature cache
  (~2.9 MB at 45k cells, 6.4 MB at 100k, growing linearly) and needs a
  defined invalidation rule when `consolidation_threshold` changes. Not
  implemented — both are open design decisions, and the id-ordered cell list
  from the fix above is the prerequisite for it.
- **`abstracts` per pass is flat at 155 from 5k cells on.** That is the
  harness's 5-topic synthetic corpus saturating, not convergence — do not read
  it as evidence.
- **HNSW recall has not saturated.** `mem3-hnsw-recall` measures recall@10
  against exhaustive scan on 400 nodes: 0.566 @ ef=10, 0.758 @ ef=100, 0.772 @
  ef=400. The default `hnsw_ef_search` is 100.
- **No group commit.** `wal.append` fsyncs on every record (~1.2 ms). Currently
  not the dominant write cost, but it will become one once insert is fixed.
- **The on-disk format is unstable.** `0.1.0-alpha`, no external users, no
  stability guarantee.
- **No licence.** No `LICENSE` file exists. The code is unlicensed and carries no
  granted rights until one is added.