# Roadmap

What mem3 has deferred, why, and what closing it would cost. Every figure here
was measured on the tree it describes; nothing is projected.

Current version: **`0.1.0-alpha`**. Supported targets: **macOS and Linux**.

---

## Recently closed

- **MCP server** (`mem3 mcp`, JSON-RPC 2.0 over stdio, hand-written, zero
  dependencies). Five tools: `memory_add`, `memory_query`, `goal_list`,
  `memory_forget`, `memory_stats`. `memory_forget` defaults to `dry_run: true`,
  which is stricter than the CLI. This was the missing distribution channel:
  without it the daemon's storage was reachable only by a bespoke HTTP client.
  **Still unverified against a real MCP host** — no client has run against it
  yet, only against conformance probes written here, which is a weaker claim
  and worth stating as one.
- **Dual-era, not legacy-only.** The current revision `2026-07-28` removed the
  `initialize` handshake, moved the protocol version into every request's
  `_meta`, required a `resultType` on every result, and made `server/discover`
  mandatory. mem3 implements that era *and* the handshake era, decided per
  request rather than per connection — the protocol is stateless, so a client
  may interleave unrelated requests on one stdio process. The discriminator is
  the presence of `_meta["io.modelcontextprotocol/protocolVersion"]`, with
  `initialize` always legacy because that method does not exist in the modern
  core. Legacy responses are byte-identical to before, because an unmigrated
  client validates against the older schema.
- Two conformance defects were found by probing rather than by reading, and
  both are the kind a test suite built alongside the code cannot find. JSON-RPC
  batches: "implementations MUST support receiving batches", and a batch
  arriving on one line was answered with `-32700` per element — which a client
  reports as a parse failure, not as a missing feature. And the stdio fallback
  rule: `server/discover` without `_meta` must be `-32602`, not `-32022`,
  because `-32022` means "I am modern, retry" and a legacy client would treat
  it as one.
- A third suspicion turned out to be wrong, and is recorded because a false
  alarm costs more than a re-investigation. `initialize` appears to echo
  whatever version a client asks for, but `SUPPORTED_VERSIONS` is a real list
  and anything outside it falls back to `2025-06-18`, which is what the spec
  asks for.
- **Optional external embedding** (`--embedder-cmd`, `--embedder-arg`). A
  long-lived child process speaking a one-line-in / one-line-of-floats-out
  protocol, so a real embedding model becomes an *option* rather than a build
  dependency. The zero-dependency hashed lexer stays the default, and the
  default path is byte-identical to pre-MCP builds — pinned by a permanent
  fingerprint test. Cost of the external path is 1.50–1.96× the lexical path at
  p50, and neither adds a link dependency (`otool -L` still lists only
  `libSystem`).
- **HNSW recall** — see "The graph used to be disconnected" below. On a
  400-node corpus recall@10 went 0.6090 → **0.9920** at ef=10, and reachability
  went 0.7675 → 0.9975.

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

The only change that moves this number is a semantic embedder. That question
has since been answered a different way: `--embedder-cmd` delegates to an
externally-executed model over a line protocol, which is a different claim from
linking a runtime and was shipped without a new amendment. `.onnx_external` is
still reserved and unimplemented (it returns `error.UnsupportedEmbedder`).
This benchmark has not been re-run through the external path, so what a real
model would report here — including for the two configurations that score
0.0000 — remains unmeasured.

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
- **Forgetting a cell now takes its vector out of HNSW** (fixed 2026-10-16).
  `store.forget` took the cell out of `mgr` and `cell_index` but left the node
  in the vector index. Retrieval was never at risk — `getCell` reads
  `cell_index`, so the candidate is skipped and a forgotten memory cannot
  come back through a query — but two things were wrong. `count` kept
  counting it, and `count` is published as `mem3_vector_index_nodes`, so a
  Prometheus gauge only ever grew and never fell no matter how much the
  store forgot. And `insert` copies the caller's slice into the node, so each
  forgotten cell kept 384 floats resident for the life of the index; at the
  47k cells the long run reaches that is ~72 MB of vectors behind memories
  the store had already decided to forget. `HNSW.markDeleted` tombstones the
  node, zeroes its vector, drops it from `count`, and `search` filters
  tombstoned candidates out of its results.
  **This makes the index and the cell map agree across a restart too** — the
  snapshot restore indexes live cells only, which is now the same answer
  `forget` converges to, instead of the two disagreeing depending on whether
  the process had restarted.
  Two limits, both stated rather than hidden. The tombstone does not unlink
  the node: adjacency lists in this index hold ids, so rewriting every
  neighbour's list and re-running the pruning that produced them is graph
  surgery on a hot path. Over a long run of forget/add cycles the graph will
  degrade and would need a rebuild, which is separate work. And `search`
  over-fetches by 1.5× to refill after filtering, so a heavily-swept store
  can come back with fewer than `k` live hits; that is a smaller result set,
  not a wrong one.
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
- **A monotonic id counter is never rolled back** (fixed 2026-10-15).
  `Store.ids` is one `std.atomic.Value(u64)` shared by the goal poset, the
  hypergraph, the tri-source manager and `addRaw`. Both of the `errdefer
  fetchSub` sites in `store.zig` gave the id back on failure, which under the
  daemon's concurrency hands the same number to the next caller: A takes 5, B
  takes 6, A fails and decrements, C takes 6. Nothing is corrupted —
  `addWithId` rejects the duplicate — but a legitimate write fails, and it can
  ratchet, since every failure pushes the counter further back over ids that
  are already committed. `addHyperedge` was already correct here and said why:
  ids must be unique, not dense. Leaking an id costs nothing.
- **HNSW recall falls off with corpus size, and the default `ef` is a
  small-corpus setting.** `mem3-hnsw-recall` measures recall@10 against
  exhaustive scan. On 400 nodes (dim=32) it is **0.9920 @ ef=10** and **0.9980 @
  ef=100**, against a level-0 reachability of 0.9975 — recall is capped by graph
  connectivity, not by search width. At dim=384 it degrades with `n`: 0.9980
  (1k), 0.8930 (10k), 0.6760 (30k), 0.4300 (100k) at `ef=100`, and needs
  `ef ≈ 0.08·n` to saturate (0.9890 at ef=3200 for n=100k). The default
  `hnsw_ef_search` is 100.
- **The graph used to be disconnected, and that — not search width — was the
  recall ceiling.** Before this round, a directed walk from the entry point
  reached only 307/400 nodes; `1 − 307/400 = 0.7675` against a measured
  recall@10 of 0.7720 at ef=400. The cause was `shrinkConnections`
  implementing the paper's diversity rule with the operands swapped: it
  discarded the *candidate* instead of evicting the *kept neighbour`, which
  compounds (every kept neighbour is another chance to discard) and dropped
  average level-0 degree from 32 to 13.4 — while every max-degree assertion
  stayed green, because the assertion bounded the maximum, not the mean. With
  reachability at 1.0000 the same 400-node corpus went to 0.9920/0.9980.
- **`ef_construction = 200` is now the dominant insert cost.** At the corrected
  pruning, `efc=100` measures both *better* recall and *faster* insert
  (−26% on a 4000-cell interleaved build, p50 over 8 rounds) than `efc=200`
  did under the broken pruning. It is still 200 in `Config` because it is a
  product-level default that every benchmark inherits; changing it is a
  deliberate decision, not a side effect of a recall fix.
- **The 100k build-time target is missed by 14x.** `spec.md` and the
  constitution both state < 30s for 100k vectors; measured is **430.6 s**
  (dim=384, efc=200, whole-index build). Cost of the recall fix, which keeps
  more edges alive. `efc=100` roughly halves it and still misses.
- **No group commit.** `wal.append` fsyncs on every record (~1.2 ms). Currently
  not the dominant write cost, but it will become one once insert is fixed.
- **The on-disk format is unstable.** `0.1.0-alpha`, no external users, no
  stability guarantee.
- **No licence.** No `LICENSE` file exists. The code is unlicensed and carries no
  granted rights until one is added.