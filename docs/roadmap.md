# Roadmap

What mem3 has deferred, why, and what closing it would cost. Every figure here
was measured on the tree it describes; nothing is projected.

Current version: **`0.1.0-alpha`**. Supported targets: **macOS and Linux**.

---

## Recently closed

- **Forgetting implements `net_existence` and supersession** (branch
  `p2/forget`; ADR [0005](adr/0005-existence-gain-forgetting.md)). The sweep was
  `importance × decay < θ` only; `redundancy`, `conflict_score` and
  `superseded_at` did not exist while the MCP text and the `forgetter.zig`
  header described them. Now: redundancy by an exact prefix-filter duplicate
  pass, conflict by a subject+predicate index, `superseded_at` / `superseded_by`
  journaled (`memcell_update`) and in snapshot v3, per-reason counts in
  `forget`, superseded cells hidden from default recall. Measured on the
  synthetic `--mode=netex` corpus: exact-copy pairs 0/60 → 60/60 collapsed,
  unique high-importance cells forgotten 0/400, contradiction-pair top-1 =
  current value 53% → 100%. **Not a free win**: the first cut (every predicate
  single-valued) marked 120 of 180 multi-valued cells superseded, so the default
  now supersedes only a short list of single-valued predicates
  (`--supersede=off|functional|all`, `--functional-predicates`): 0/180
  multi-valued superseded or forgotten (asserted), at the price of 0/60
  contradictions on an unlisted predicate being superseded. Every supersession
  is reported by the add (`superseded:[{id,subject,predicate}]`) and undone with
  `mem3 unsupersede <id>` / `memory_unsupersede`. Near-duplicates are lowered
  but not forgotten. Sweep time at 20k cells: 140 ms (realistic corpus,
  near-linear), 1.1 s (dense templated worst case, capped at 256 candidates per
  cell; 18.9 s uncapped). Also fixed: replaying a `.forget` WAL record freed the
  cell instead of moving it to the fuzzy store, so a restart after a CLI
  `mem3 forget` (which does not sync) lost forgotten cells outright.
  Still open: predicate schemas beyond a flat list, `mem3 remember` (promote-back,
  T084), profiling the superlinear tail on the dense corpus, a non-synthetic
  evaluation corpus, no downgrade path from snapshot v3.

- **Consolidation is incremental** (`Consolidator` + `src/memory/cluster_index.zig`).
  The pass used to compare every cell pair: 1.01e9 pairs at 45,000 cells. The
  union-find and a per-cell token signature (512 bits) now persist across passes
  and only cells that arrived since the last pass are compared — against every
  present cell and against each other, once each. The partition is **identical**
  to the full recompute's: held by `tests/unit/consolidator_incremental.zig`
  against an independent O(n²) oracle and a cold instance over randomized
  add/forget, and at scale by an order-independent digest of every abstract's
  text and importance, which matched between baseline and new builds in all
  6 A/B pairs (5k/20k/45k × 2 runs) and in the 20k run with 50 cells forgotten
  per pass. Measured with `mem3-consolidate-bench` (`zig build
  example-consolidate-bench`; raw runs in
  [`benchmarks/consolidation-incremental.md`](benchmarks/consolidation-incremental.md)), baseline = `main` at 03e588f, A/B interleaved,
  2 runs per cell, long-run corpus shape, 400 cells ingested between passes.
  **The host was heavily loaded (load average 55–80 on 10 cores)**, so absolute
  times are inflated ~3× over the 20.3 s the long run recorded for the baseline
  at 45k; use CPU time (not wall) and the ratios, not the absolutes.

  | cells | pass kind | pairs base → new | CPU ms/pass base → new | speed-up |
  |---:|---|---|---|---:|
  | 5,000 | first (cold) | 1.25e7 → 1.25e7 | 747 → 785 | 0.95× (noise-level; same work) |
  | ~5.9k | steady | 1.72e7 → 3.16e6 | 1,015 → 223 | 4.6× |
  | 20,000 | first (cold) | 2.00e8 → 2.00e8 | 11,625 → 11,954 | 0.97× |
  | ~20.9k | steady | 2.18e8 → 1.17e7 | 12,696 → 809 | 15.7× |
  | 45,000 | first (cold) | 1.01e9 → 1.01e9 | 58,950 → 59,762 | 0.99× |
  | ~45.9k | steady | 1.05e9 → 2.59e7 | 61,640 → 1,760 | 35.0× |

  **Growth exponent** (log-log, 5k→45k): baseline 1.99 (CPU) / 2.00 (pairs);
  incremental **first pass 1.97 / 2.00 — still O(n²), unavoidably**;
  incremental **steady pass 1.00 (CPU) / 1.02 (pairs)**. The steady figure holds
  only because arrivals per pass are fixed (555 = 400 ingested + ~155 abstracts
  the previous pass created); the earlier probe's "~56×" counted 400 and
  missed the abstracts, and the measured pair reduction at 45k is 40.7×.
  Whole trajectory, empty → 20k in 37 passes: 2.63e9 pairs and 150.7 / 154.6 s
  CPU for the baseline against 2.07e8 pairs and 14.0 / 14.3 s for the new build
  (10.7×). New build alone, empty → 45,309 cells in 82 passes: 1.03e9 pairs,
  71.3 s CPU, last pass 1.75 s; the baseline's 2.84e10 pairs for the same
  trajectory is arithmetic, not a measurement (it was not run). With cells
  forgotten before each pass at 45k: 50/pass → ~1.99 s CPU (+13%, ~42 clusters
  rebuilt), 400/pass → ~2.3 s (+33%, ~140 rebuilt); one run of the 400 case
  was cut short, so it is a single sample.
  **Memory**: the cache is 108.7 B/cell once warm (5.02 MB at 46,135 cells; 643
  KB at 5,000 cells, 128 B/cell with growth slack), measured exactly through a
  counting allocator handed only to the consolidator — more than the 64 B/cell
  the signature alone would cost, because of the id, hash, parent and flags
  columns and the id→slot map. Transient peak during a pass: 6.3 MB against the
  baseline's 4.2 MB. Process-level peak RSS was 29–32 MB for both and the
  difference is inside the run-to-run spread, so no RSS figure is claimed.
  **Removal rule** (a union-find cannot split, a single-linkage cluster can): a
  removed cell marks its component dirty; every survivor of a dirty component is
  reset to a singleton and all-pairs is re-run *within those survivors only*.
  Exact, because there are no edges between components; one rebuild per dirty
  component per pass; free for a singleton or a lone survivor. Invalidation: a
  changed `consolidation_threshold` (compared as bits), a different manager, an
  allocation failure, or `invalidate()` clears everything and the next pass is
  full. A cell whose id is reused with different content is detected by a
  64-bit content hash and treated as removed-then-added (a hash collision would
  miss it). Behaviour changes: abstract ids are now minted in ascending order
  of each cluster's lowest member id (previously hash-map order; the set of
  abstracts is unchanged), and abstract text/vocabulary is built from the cached
  signatures instead of re-tokenizing members. Not verified: Linux execution
  (both Linux targets cross-compile, nothing was run there); the 100k scale.
- **WAL group commit, opt-in** (`--wal-sync=always|group|interval:N`; default
  `always` is byte-identical to before). `group` acknowledges a write only
  after an fsync that covers it (leader/follower, the store lock is *not* held
  across the fsync); `interval:N` is explicitly weaker and can lose up to ~N ms
  (+ a 100 ms tick) of acknowledged writes to an OS crash or power cut. A
  failed fsync is never acknowledged, and a later successful one never blesses
  earlier records. **Measured on this host, it does not make writes faster**
  (see "Write throughput" below): fsync here costs ~30 µs, `hnsw.insert` under
  the store lock dominates, so 1,600 concurrent writes shared 16 fsyncs. The
  feature is closed as *correct and available*, not as *a speedup*; its payoff
  needs a slow fsync (a Linux disk), which has **not been measured**.
- **Daemon hygiene** (T092/T095/T101/T102): `serve` and `mcp` stop cleanly on
  SIGINT/SIGTERM (exit 0, in-flight requests drained, WAL flushed; `mcp`
  snapshots a dirty store as it always did on EOF); `--log-format` and
  `--log-every` are wired to a stderr logger (`--log-format=jsonl` is pure
  JSONL); the default stays silent. Rotation is external
  ([`deploy/logrotate.conf`](deploy/logrotate.conf), not run under a real
  logrotate).
- **MCP server** (`mem3 mcp`, JSON-RPC 2.0 over stdio, hand-written, zero
  dependencies). Five tools: `memory_add`, `memory_query`, `goal_list`,
  `memory_forget`, `memory_stats`. `memory_forget` defaults to `dry_run: true`,
  which is stricter than the CLI. This was the missing distribution channel:
  without it the daemon's storage was reachable only by a bespoke HTTP client.
  **Partly verified against real MCP hosts** (2026-10-21): MCP Inspector CLI
  2.11.0, Claude Code 2.1.289 and the Cursor CLI agent 2026.10.21 each ran
  `tools/list`, `memory_add`, `memory_query` and `memory_stats` without error,
  all via the legacy `2025-11-25` handshake. **Still unverified**: the modern
  `2026-07-28` path against any real client (conformance probes written here
  are the only evidence for it), and Claude Desktop, the Cursor IDE app, Codex
  and Gemini CLI; opencode got only as far as `tools/list`. Details and a
  self-check in [`mcp-hosts.md`](mcp-hosts.md).
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
- **`--foresight` was accepted and discarded; it is now durable.**
  Reproduction (before): `mem3 add --source=spirit --episode x --foresight
  "rain|1|2|0.8"` printed `warning: --foresight is not yet stored`, wrote a WAL
  record with no foresight field, and `mem3 dump` in the next process printed
  `"foresight":[]` with the placeholder goal id `0` — a foresight-only cell lost
  its spirit dimension across a restart. Cause: `Store.addRaw` took one goal
  and no foresight, and neither the `memcell_insert` record nor
  `buildCellFromParsed` had anywhere to put it. The snapshot row already
  carried foresight, so the defect was the WAL and the insert path only.
  Fix: `Store.addRawWithForesight`, and an optional trailing
  `"foresight":[{"description","valid_from","valid_until","confidence"}]` field
  on the `memcell_insert` record, emitted **only when non-empty** — a record
  without foresight is byte-identical to before (the pinned literal test is
  unchanged) and a WAL written before this field existed replays with empty
  foresight, so no old file is rejected. The snapshot format did not change.
  Entries are validated before anything is journaled (empty description, or a
  confidence that is not a finite number in [0, 1], is `InvalidForesight`),
  because a NaN has no JSON spelling and would make the live cell and its replay
  disagree. The same field is carried by HTTP `POST /api/memcells` (also shown
  by `GET /api/memcells/:id`), and MCP `memory_add`. Consolidation abstracts
  inherit their representative's foresight in memory, and their WAL record now
  carries it too (that last path is now covered by
  `tests/integration/consolidate_incremental_e2e.zig`). Regression tests were written
  first and observed failing with `expected 2, found 0` (WAL replay, snapshot
  restore, `dump`, `add`, HTTP, MCP) before the implementation. Found on the
  way: the HTTP 400 path of `POST /api/memcells` leaked its error body on every
  refused insert (surfaced by the new refusal test). **Not closed:** foresight
  is not embedded and not in the BM25 text, so `query` cannot retrieve a cell
  by what it predicts; and a cell with no goal still carries synthetic goal id
  `0`. A pre-change binary was not run against a post-change store, so
  forward-compatibility (old reader, new WAL with foresight) is untested — it
  should read the record unchanged because the old parser stops at the fields
  it knows, but that is reasoning, not a measurement.

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

**WAL durability modes (2026-10-21, A/B interleaved, 5 rounds, loaded host,
load average 30–100).** Concurrent HTTP writers against the real daemon
(`scripts/wal_loadtest.py`, 16 threads × 2,400 writes, 200-write windows,
ReleaseFast; "base" is the pre-change build):

| Variant | Median overall /s | Median worst window /s | Min worst window /s |
|---|---|---|---|
| base | 767.9 | 615.7 | 503.0 |
| `always` (new build) | 727.5 | 560.7 | 344.1 |
| `group` | 745.3 | 527.1 | 349.2 |
| `interval:50` | 870.0 | 661.8 | 355.2 |

The spread inside one variant (344–616) is larger than the gap between
variants: **no variant is distinguishable from another on this host.**
Single-threaded `mem3-bench throughput --scale=0.4`, 5 interleaved rounds,
base vs new build: median overall 1,240 vs 1,170 cells/sec, median worst
window 942 vs 942, min worst window 839 vs 759; `met_target` was `false` in
every run. These loaded-host numbers are *not* the 2,779–3,898 figures above
and are not comparable to them. Amortisation, from the daemon's own summary
line over 1,600 concurrent writes: `always` 1,600 fsyncs, `group` 1,584.

**The cause is HNSW insert, not fsync.** `hnsw.insert` costs ~899 µs/op
amortised — comparable to the ~1.2 ms per-record WAL fsync, and larger than the
entire `store.addRaw_durable` pipeline (~577 µs) that contains both. Group
commit would not move this number. What would:

- Profile and reduce the per-insert neighbour-selection cost (the graph is
  `max_level=2` at 400 nodes with `avg degree 28.47` at level 0, so the ef-bounded
  expansion is touching a lot of neighbours per insert).
- Tune `ef_construction` against the insert/search trade-off rather than leaving
  it at the search-oriented default.

**Update (2026-10-21, `p1/hnsw`): the insert cost was reduced 3.6×, and the
build-time target is still missed.** See "1a. HNSW rework" below for the
interleaved A/B; the ~899 µs/op above is the pre-rework figure.

### 1a. HNSW rework — what was measured (2026-10-21, branch `p1/hnsw`)

Every number below is an interleaved A/B against a build of `main` at
`cc6f427` (ReleaseFast, Apple M1 Pro), never against a figure in this
document. The host was loaded (load average 20–50 during the 100k runs, 5–10
during the micro-benchmarks), so medians and ranges are reported and user CPU is
preferred over wall time where both exist. Raw outputs were kept in `/tmp`
during the work and are not committed; the method is `scripts/hnsw_ab.py`.

**What changed, one commit each.** (Per-step ratios were measured at 10k
against the preceding commit, interleaved; their product, 0.29, is consistent
with the 0.26 cumulative user-CPU ratio at 100k below.)

1. *Profile.* `sample` on a 10k build: ~42% of samples in linear scans of the
   candidate set (`searchLayer` kept `candidates`/`results` as unsorted
   lists), ~41% in cosine. No allocator or hash-map hot spot.
2. *Binary heaps in `searchLayer`.* Graph bit-identical to `main` (fingerprint
   test, below). User CPU for a 10k build: 0.47× of `main`.
3. *Vector arena + norm cache + prefetch.* Vectors live in 64-byte-aligned
   chunks addressed by a dense index instead of one heap slice per node; the
   norm is cached; the next neighbour's vector is prefetched while the current
   one is scored. A further 0.68× user CPU. The dot product is memory-bound at
   scale: 548 ns per call at 100k random vectors against 35 ns when hot, which
   is why this step paid off more at 100k than at 10k.
4. *`shrinkConnections` without per-call allocations*, in-place write-back,
   prefetch pass. A further 0.90× user CPU, and in-process peak RSS for a 10k
   build 66.4 → 42.9 MB.

**Graph identity.** `HNSW.graphFingerprint` hashes ids, levels and the order of
every neighbour list. Three pinned corpora (400×32 default, 1500×24 with
`m=8`/`efc=64`, 1000×100 with `efc=100`) produce the same fingerprint on `main`
and on the branch for steps 2–4, so those steps change speed, not the graph. At
30k×384 recall@10 reproduces the documented 0.6760. The fingerprints are pinned
on `aarch64` only: the f32 reduction order may differ on x86, where the test
skips rather than guess. **Not run on x86_64/Linux.**

**Cumulative result vs `main`, 3 interleaved rounds** (`hnsw_ab.py`,
`mem3-bench hnsw-build --vectors=100000`, dim 384, efc 200):

| Metric (100k build) | `main` median (range) | branch median (range) | B/A |
|---|---|---|---|
| build seconds | 543.4 (437.3–580.0) | **115.3 (105.9–120.6)** | 0.212 (per round 0.222 / 0.242 / 0.199) |
| user CPU s | 432.3 (393.1–439.6) | 113.3 (105.4–117.4) | 0.262 |
| peak RSS, `time -l` MB | 455.9 (444.9–462.3) | 260.1 (253.2–325.9) | 0.571 |

`met_target` is **false**: 115 s against < 30 s, 3.8× over. The earlier 430.6 s
in this file sits just under the low end of what `main` measured now
(437–580 s): the same order, a different load. A fresh 100k f32 build under a lighter
load (not an A/B) took 110–126 s; int8 storage took 87 s (below).

`mem3-bench` micro-benchmarks, 5 interleaved rounds, load average 5–10
(median of the five medians, range in brackets):

| Benchmark | `main` | branch |
|---|---|---|
| `hnsw.insert` (µs/op) | 886 (859–898) | **244 (241–258)** |
| `hnsw.search` (µs/op, 2,000-cell corpus) | 1,070 (1,065–1,107) | 212 (209–214) |
| `store.addRaw_memory` (µs/op) | 444 (435–450) | 198 (196–202) |
| `store.addRaw_durable` (µs/op) | 538 (519–545) | 275 (268–300) |
| `wal.append_durable` (µs/record) — control | 945 (877–1,023) | 958 (862–1,081) |

`wal.append_durable` did not move, as it should not: the control agrees. The
`hnsw.insert` share of the durable write path drops accordingly.

**`ef_construction` sweep (decision: keep 200).** recall@10 at `ef=100`,
dim 384, 100 queries, same graph seed:

| efc | 10k | 30k |
|---|---|---|
| 50 | 0.777 | 0.519 |
| 100 | 0.819 | 0.599 |
| 150 | 0.868 | 0.643 |
| 200 (default) | **0.893** | **0.676** |

Lower `efc` is faster, but it is strictly worse on recall at both sizes, so the
default stays 200. The
"efc=100 is better" bullet below compares `efc=100` after the pruning fix with
`efc=200` before it, so it does not bear on this same-pruning comparison. Per-insert timings for the sweep
were taken on a host whose load swung by 5×; only the first round, where the
ordering is monotone (330 / 454 / 555 / 639 µs for efc 50 / 100 / 150 / 200 at
10k), is quoted, and it is a single round.

**Adaptive `ef_search` (new default).** `Config.hnsw_ef_search_divisor`
(default 64): the search budget is `max(hnsw_ef_search, live_count / 64)`. It is
inert below 6,400 cells, so the small-corpus numbers (including every
LongMemEval run) are unchanged. The graph is fully reachable at every size
(level-0 reachability 1.0000), so the loss was search budget, not connectivity.
recall@10 at `hnsw_ef_search=100`, dim 384, 100 queries, same graph, one process
per row; latency is the mean over 100 searches, timed in batches of 10 (the
per-query p95 is **not** measured; "slowest batch" is the worst batch mean):

| n | fixed ef=100 recall | adaptive recall | fixed ms/query | adaptive ms/query (slowest batch) |
|---|---|---|---|---|
| 10,000 | 0.893 | **0.944** | 0.89 | 0.80 (1.29) |
| 30,000 | 0.676 | **0.926** | 1.44 | 4.39 (5.60) |
| 100,000 | 0.430 | **0.928** | 0.81 | 9.88 (10.06) |

For scale: at 100k a fixed ef of 800 gave 0.803, 1562 gave 0.928, 3200 gave
0.989 (the 1562 row is the same budget the divisor selects, and agrees). Mean
latency at 100k is under the < 50 ms MVP target and **at, not under,** the
< 10 ms release target; the p95 target has not been measured on a 100k corpus.
The 10k latency rows are within noise of each other. Since the search budget is
also over-fetched ×1.5 for tombstones, the effective beam is wider than the
divisor alone suggests.

**Optional int8 storage (`Config.hnsw_vector_storage = .int8`, default OFF).**
Per-vector scale so max |x| = 127, exact i8 dot product with i32 accumulation,
cached integer norm (cosine is scale-invariant, so no scale is stored). Vectors
are not persisted, so snapshots and the WAL are unchanged and readable either
way. Vector payload 1,536 → 384 B/cell. recall@10 at `ef=100`: 1k 0.988 vs 0.998,
10k 0.886 vs 0.893, 30k 0.666 vs 0.676 (int8 vs f32; 0.7–1.0 pt loss at 10k and
30k). The gate for turning it on was < 0.5 pt at both sizes, so it stays off. At
100k (100 queries) int8 read 0.453 / 0.822 / 0.941 against f32's 0.430 / 0.803 /
0.928 at ef 100 / 800 / 1562: higher, but 100 queries cannot resolve a 1–2 pt
difference, so this is not evidence int8 is better. Build time at 100k was 86.9 s
against 244 s for f32 *in the same loaded host and not interleaved*; the
user CPU for `mem3-bench footprint --cells=100000`, two interleaved
rounds, was 13.3–14.2 s int8, 18.3–20.2 s f32, 33.0–35.6 s `main`.

**Memory (`mem3-bench footprint`).** RSS is not a usable measurement on this
host. `/usr/bin/time -l` at 100k cells, every run taken (two scripts, runs
interleaved): `main` 426 / 991 / 2,768 MB; branch f32 331 / 337 / 579 MB; branch
int8 333 / 463 / 463 MB. A 6× spread inside one build is, by the README's own
account, macOS page compression and swap under a loaded host, so **no claim is made about the < 500 MB RSS target**. What is
deterministic is the allocator's live request bytes, now read from a counting
allocator inside `footprint` (a lower bound on RSS: it excludes allocator
metadata, size-class rounding and fragmentation). Same corpus, one run per cell
count (a deterministic count, so repeats were not needed):

| Cells | `main` live B/cell | branch f32 | branch int8 |
|---|---|---|---|
| 10,000 | 2,975 | 2,926 | 1,747 |
| 50,000 | 2,952 | 2,877 | 1,729 |
| 100,000 | 3,013 (301.3 MB) | 2,940 (294.0 MB) | 1,784 (178.4 MB) |

So at 100k cells the floor is ~294 MB (f32) or ~178 MB (int8) before the
allocator's own overhead. The live bytes barely changed between `main` and the
branch: the memory *win* of this work is not live bytes (−2.4% at 100k f32), it
is that the arena layout stops `DebugAllocator` from holding thousands of small
vector allocations, which showed up as in-process peak RSS in an earlier
`hnsw-build` A/B at 10k (66.4 → 42.9 MB); the `time -l` RSS above is too noisy
to quote as a ratio.

**Where the live bytes go** (call-site profile of a 10,000-cell fill, scratch
tool not committed; total 2,926 B/cell, agrees with the counting allocator's
2,926):

| Component | B/cell |
|---|---|
| HNSW vector arena (1,536 payload + chunk slack) | 1,573 |
| BM25 posting lists (`Posting` arrays + term map) | ~520 |
| MemCell structs and their strings (`commitBuiltCell`) | ~340 |
| HNSW layer-0 neighbour lists (32 ids × 8 B) | 257 |
| id→cell and related hash maps | ~100 |
| HNSW node structs | 56 |

The BM25 lexical arm is the largest non-vector item (~18% of live bytes) and
was added after the original 27 KB/cell figure; it is not touched by this
branch. The "~27 KB/cell marginal" in the README is dominated by
`DebugAllocator` page caching and macOS RSS behaviour, not by live data: live
data is ~3 KB/cell.

**Not done / not verified.**

- x86_64/Linux fingerprint pin and the int8 numbers there: not run.
- RSS at 100k vs the < 500 MB target: **not verified** (noise above); the
  live-bytes floor (294 MB f32) leaves room under 500 MB but is not RSS.
- Recall figures use 100 queries; differences under ~2 pt are not resolved.
- A 4-accumulator dot kernel was tried and gave no measurable gain (user CPU
  0.98×, inside noise); it was reverted, not committed.
- In `connect`, the neighbour-side `link` shrinks the neighbour's list using the
  *new* node's query as the reference instead of the neighbour's own vector. A
  scratch fix gave no recall gain (0.869 vs 0.893 at 10k, 100 queries) and was
  left as is; this is a finding, not a fix.
- Remaining levers for the 30 s build target, not attempted: int8 storage by
  default (needs the recall gate to pass), lower `efc` (costs recall, above), or
  a multi-threaded build (a different design; graph determinism, which the
  fingerprint tests rely on, would need re-proving).

### 2. LongMemEval — 0.729 core / 0.708 padded (offline), against a ≥80% target

> The 0.646 / 0.000 figures in the first table below are historical (before the
> BM25 arm). Current numbers are in the later table. Official-dataset retrieval
> metrics: `docs/benchmarks/longmemeval-official.md`.

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

**The "it's the embedder, not the index" diagnosis was half right and has been
re-measured.** `exhaustive_nn_hit_rate = 0.6042` is indeed identical across all
four runs, and it is index-independent — so that particular metric is a
statement about the embedder. But the sentence that followed it, "the retrieval
layer is not the bottleneck here", was wrong, and the way it was wrong is the
useful part.

What actually happened when the BM25 sparse arm landed
(`src/retrieval/bm25.zig`):

| | before | after |
|---|---|---|
| combined accuracy, full padding | 0.0417 | **0.7083** |
| retrieval hit rate, full padding | 0.0729 | **1.0000** |
| `exhaustive_nn_hit_rate` | 0.6042 | 0.6042 (unchanged, as expected) |

The padded configurations were not failing because the embedder could not rank
them and not because HNSW could not navigate — they were failing because
**there was no lexical path at all**, and as the store grew with distractors the
dense arm's noise simply drowned the signal. A retrieval hit rate of 0.0729
looked like index collapse and was not; it was a missing arm.

The external-model question has also been answered. `--embedder-cmd` was run
against `all-MiniLM-L6-v2` (ONNX, local, via `onnxruntime`), and
`exhaustive_nn_hit_rate` moves 0.6042 → **0.7812** — the stronger embedder does
place better. End-to-end combined accuracy does **not** follow: flat to within
0.01 across every configuration. With a lexical arm in the fusion, this
benchmark is not embedding-bound any more, and the remaining gap to the
constitutional 80% is somewhere other than both the embedder and the index.

Note for whoever repeats this: `--embedder-cmd` sends **hex-encoded** text, not
raw text. See `scripts/embedder_adapter_example.py`.

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
  `cntvct_el0`), which is **not written**. Update 2026-10-21: a Linux
  container is available after all (OrbStack). The defect is not macOS-only:
  on Linux aarch64 the Timer test alone fails 186/300 runs in ReleaseFast and
  0/300 in Debug (so a full-suite ReleaseFast run there passes or fails at
  random — it passed twice and failed once), and on macOS arm64 it fails every
  time. Linux x86_64 was only measured under Rosetta (0/300), which is not a
  native result. CI runs the ReleaseFast test step as `continue-on-error` for
  this reason. Until then, treat min/tail-percentile latencies as unreliable and
  report p50.
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
- **Consolidation: what incremental clustering did not remove.** See
  "Consolidation is incremental" under Recently closed for the measurements.
  (1) The first pass in a process is still all-pairs, O(n²) — 1.01e9 pairs and
  ~58 s CPU at 45,000 cells on the loaded measurement host — and that is every
  `mem3 consolidate` CLI call, because a fresh process has no cache.
  (2) The steady-state pass is O(new × n): linear only while arrivals per pass
  stay fixed. If arrivals scale with the corpus it is quadratic again.
  (3) Every pass still emits an abstract for *every* multi-member cluster,
  including clusters that did not change (155 per pass in the harness), and
  those abstracts are the next pass's new cells (~28% of arrivals in the
  bench). That is the pre-existing behaviour and was kept on purpose; changing
  it would change what consolidation produces. (4) A large cluster that loses a
  member on every pass pays that cluster's quadratic rebuild each time.
  (5) Not measured: the 100k scale, and a workload where forgetting actually
  fires at volume (the long run fuzzied nothing).
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
  `hnsw_ef_search` is 100. *Update 2026-10-21:* `hnsw_ef_search_divisor = 64`
  now scales the budget with the corpus (0.893 → 0.944 at 10k, 0.676 → 0.926 at
  30k, 0.430 → 0.928 at 100k); see "1a. HNSW rework".
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
  constitution both state < 30s for 100k vectors; measured was **430.6 s**
  (dim=384, efc=200, whole-index build). Cost of the recall fix, which keeps
  more edges alive. `efc=100` roughly halves it and still misses. *Update
  2026-10-21:* interleaved against `main`, the build is now **115.3 s** median
  (105.9–120.6) against `main`'s 543.4 s (437.3–580.0) on the same loaded host,
  still 3.8× over; see "1a. HNSW rework".
- **Group commit is opt-in and unproven as a speedup.** Default `wal.append`
  still fsyncs every record. `--wal-sync=group` exists and loses no
  acknowledged write across `kill -9` in the e2e test, but on the measured
  host (macOS, plain `fsync`, not `F_FULLFSYNC`) it is within noise of
  `always`. Whether it pays on a Linux disk has not been measured.
- **The daemon parses a request from one `read(2)`.** A client that sends
  head and body as two writes (Python `http.client` does) can get a 400. Found
  while writing `scripts/wal_loadtest.py`, identical on the pre-change build,
  not fixed here.
- **The on-disk format is unstable.** `0.1.0-alpha`, no external users, no
  stability guarantee.
- **Licence: MIT** (`LICENSE`, added 2026-10-21; copyright holder is the
  placeholder "mem3 contributors" — replace with the real owner before any
  external release).