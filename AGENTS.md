# AGENTS.md

> Root-level agent onboarding for `mem3` (TriSource-EverOS).
> Consumed by OpenCode / Codex / Cursor / Aider / Devin / Gemini CLI / Claude Code.
> This is the **first** file an agent should read after `README.md`.

## Project Snapshot

| Field | Value |
|---|---|
| Project | `mem3` = **TriSource-EverOS** |
| Type | Memory operating system, single-binary CLI + HTTP daemon |
| Language | Zig 0.17.0 (released). The 0.17 point releases disagree on `@typeInfo` payload shapes and `OptimizeMode` literal names, so this is pinned rather than "dev ≥ ...". `./scripts/verify.sh` prints the toolchain it actually used. |
| Build | `zig build` → one binary, < 10MB, zero external runtime deps |
| Theory | Tri-Source Coherence Theory (matter / form / spirit) + the GHW paradigm (Goal / Harness / World) |
| Spec-kit | Initialized; spec at `specs/001-trisource-everos-mvp/` |
| Platforms | **macOS and Linux only** — Windows and WASM refused at compile time (see [Platforms](#platforms)) |
| Status | **v0.1.0-alpha** (CLI + MCP + persistence + 675 tests + 12 constitution invariants, all measured). All 7 constitutional principles active. |

## Read Order for New Agents

1. **This file** (you are here)
2. `README.md` — what the project is in 1 minute
3. `docs/roadmap.md` — what is deferred, why, and what it would cost
4. `dev.md` — engineering blueprint and the 12-week plan. **It is a design
   document, not a status report**: its forward-looking sections describe
   intended architecture and have not been re-audited against the current
   source. Verify anything you rely on against `src/`.
5. `ghw_memory_system.agent.final.md` — formal theory paper
6. `.specify/memory/constitution.md` — **the 7 principles (law), v1.2.0**
7. `specs/001-trisource-everos-mvp/spec.md` — what we're building
8. `specs/001-trisource-everos-mvp/plan.md` — how we're building it
9. `specs/001-trisource-everos-mvp/data-model.md` — type definitions
10. `specs/001-trisource-everos-mvp/tasks.md` — what to do next

## Core Principles (read this twice)

**The Constitution is law**. Violating a principle is not "creative license", it is a constitutional violation. If you think you need to violate one, **stop and ask first**.

The 7 principles (in order of importance):

1. **Tri-Source Integrity** — every memory MUST have a matter / form / spirit source tag. No untyped memories. Reject at encoding time.
2. **GHW Three-Layer Coupling (Goal-Harness-World)** — three layers, no cross-layer shortcuts. Each module declares its layer in file-level doc-comment.
3. **Existence-Gain-Driven Lifecycle** — encoding/consolidation/retrieval/forgetting all driven by the existence-gain metric, not by capacity/TTL.
4. **Zero-Dependency Zig 0.17 Native** — no FAISS, no Neo4j, no Redis, no SQLite, no libc wrappers, no external async runtime. Single binary, cross-compiled to macOS and Linux. Windows and WASM are refused at compile time with a stated reason.
5. **Zero-Copy + Comptime Zero-Overhead** — comptime-generated serialization, explicit allocator injection, no runtime reflection.
6. **Test-First + Formal Guarantees** — tests written BEFORE implementation. The constitution invariants (now 12) are tested on every PR as a separate gate.
7. **Observability + Single-Binary Debugging** — structured logs, /metrics endpoint, dump/inspect commands, silent-by-default for long-running modes.

**Read `.specify/memory/constitution.md` for the full text.**

## Code Style

- **Zig idiomatic**: snake_case functions, PascalCase types, SCREAMING_SNAKE_CASE constants. Domain terms (MemCell, GHW, HyMem) keep natural casing.
- **Memory ownership**: explicit `Allocator` parameter on every allocation. No hidden globals.
- **Error handling**: tagged unions (`!T`). Never `null` for fallible operations. Use `std.posix.ENOENT`-style names.
- **No panics in libraries**. `unreachable` only with a `// SAFETY: ...` comment.
- **No allocator state in globals**. Pass `Io` runtime explicitly to async functions.
- **Comments**: explain WHY, not WHAT. Code is read more than written.

## File Map (v0.1.0-alpha actual)

```
src/
├── main.zig                  # Entry: CLI dispatch (add/query/goal/hyperedge/dump/inspect/
│                             #   consolidate/forget/serve/bench/help/version)
├── core/                     # GHW L1 foundation: types, errors, ids, config
├── ghw/                      # GHW L2: goal_tree, goal_node, harness_registry, world_model
├── memory/                   # GHW L3: tri_source_manager, lifecycle, encoder, consolidator,
│                             #   cluster_index (incremental single-linkage state),
│                             #   forgetter (net_existence sweep), conflict (subject+predicate
│                             #   supersession index), redundancy (prefix-filter duplicate
│                             #   pass), fuzzy, coherence
├── hypermem/                 # GHW L4: engine, hyperedge, multi_hop, msg_passing, graph_index
├── retrieval/                # GHW L4: hnsw, kv_index, keyword, hybrid_retriever, reranker,
│                             #   embedder
├── storage/                  # GHW L4: lsm_store, wal, snapshot
├── server/                   # HTTP daemon: http_server, routes, handlers/, middleware,
│                             #   web_index.html
├── eval/                     # Evaluation protocols over a Store (official LongMemEval
│                             # retrieval metrics); not on any product code path.
├── utils/                    # Cross-cutting: serializer, allocator, time, logger, jsonl,
│                             #   hashing, mod
├── platform/                 # The compile-time portability layer: fs, clock, stdio, env.
│                             #   Refuses windows/wasi/freestanding at compile time.
├── store/                    # SHARED Store abstraction: CLI + HTTP server both call this.
│                             #   Owns WAL + snapshot + HNSW + HyMem + GoalPoset + lifecycle.
│                             #   One implementation, two surfaces. (The daemon's ~890-line
│                             #   fork is deleted; it calls mem3_store.Store directly.)
└── cli_commands/             # CLI subcommand implementations (one .zig per subcommand)
    ├── cli_common.zig        # POSIX-write helpers (println/eprintln/fatal/appendFmt)
    ├── add.zig               # Encode + WAL-append a MemCell
    ├── query.zig             # Three-way recall with GHW-prioritized ranking
    ├── goal.zig              # Manage the Goal Poset (add/list)
    ├── hyperedge.zig         # Manage hypergraph edges (add/list/multi-hop)
    ├── dump.zig              # Export the full store as JSONL
    ├── inspect.zig           # Show a MemCell + its hypergraph neighborhood
    ├── consolidate.zig       # Run the consolidation pipeline
    ├── forget.zig            # Run the existence-gain-driven forgetting sweep
    ├── serve.zig             # Start the HTTP daemon
    └── bench.zig             # Fast in-process smoke suite (NOT the release gate)

tests/
├── main.zig                  # Master test runner (comptime-imports everything)
├── unit/                     # cli, coherence, consolidator, consolidator_incremental, hnsw,
│                             #   forgetting_netexistence (redundancy / conflict / determinism / oracle),
│                             #   supersede_policy (which predicates may supersede: functional / all / off / custom)
├── integration/
│   ├── store_persistence_e2e.zig   # insert, goal, snapshot+replay, forget+restart, isolation
│   ├── http_server_e2e.zig         # /healthz, POST+GET /api/memcells, restart preservation
│   ├── consolidate_incremental_e2e.zig  # Store-owned cache, forget tracking, abstract foresight via WAL
│   └── supersede_e2e.zig           # supersession: WAL-only + snapshot restart, query exclusion, sweep repair, forget replay → fuzzy;
│                                   #   single-/multi-valued/unknown-predicate scenarios; unsupersede via WAL, snapshot, fuzzy
├── property/                 # Randomized round-trip coverage
│   ├── serializer_roundtrip.zig    # Fact slice, primitives, array of struct
│   └── adjoint.zig                 # every encoded record decodes back; replay is idempotent
└── constitution/             # Separate gate, run via `zig build check-constitution`
    ├── main.zig, source_tag.zig, spirit_dim.zig, goal_coverage.zig
```

## v0.1.0-alpha — What Works

| Surface | Status | Notes |
|---|---|---|
| `mem3 add` | ✅ | Encode + WAL-append a MemCell (validated by constitution tests) |
| `mem3 query` | ✅ | Three-way recall with GHW-prioritized ranking |
| `mem3 goal` | ✅ | Add/list goals; default seeds (general/research/system); created goals are WAL-journaled |
| `mem3 hyperedge` | ✅ | `add` / `list` / `multi-hop` |
| `mem3 dump` | ✅ | JSONL export of the full store |
| `mem3 inspect` | ✅ | MemCell + hypergraph neighborhood; emits valid JSON. Also finds forgotten (fuzzy) cells and shows `superseded_at` / `superseded_by` / `supersede_pinned` / `supersedes` |
| `mem3 consolidate` | ✅ | HAC clustering, abstract generation, PCR preserved. Incremental across passes within one process (`Store` owns the cache); a fresh CLI process does one full O(n²) pass |
| `mem3 forget` | ✅ | `net_existence = importance − redundancy − conflict_score` sweep (ADR 0005). Reports counts per reason: decayed / redundant / conflicted, plus newly superseded. `mem3 add` marks a cell `superseded_at` only when a newer fact contradicts it on a **single-valued predicate** (default list: `lives_in`, `works_at`, `status`, `name`, `email`, `owner`, `current_*`, ...; everything else is multi-valued and never supersedes; `--supersede=off|functional|all`, `--functional-predicates=a,b`) and *all* of the older cell's facts are contradicted; the add reports `superseded:[{id,subject,predicate}]`, `query` hides superseded cells unless `--include-superseded`, and `mem3 unsupersede <id>` undoes a wrong one (pinned against re-supersession; WAL-journaled). Unlisted single-valued predicates (`shoe_size`) are deliberately not superseded. Nothing is ever deleted; forgotten cells go to the fuzzy store |
| `mem3 bench` | ✅ | Fast in-process smoke suite; the release gate is `zig build bench` |
| `mem3 serve` | ✅ | HTTP daemon with /healthz /metrics /api/sync /api/memcells /api/memcells/:id |
| `mem3 mcp` | ✅ | MCP server over stdio (JSON-RPC 2.0, hand-written, zero deps). 6 tools: `memory_add` / `memory_query` / `goal_list` / `memory_forget` / `memory_stats` / `memory_unsupersede`. **Dual-era**: modern `2026-07-28` (per-request `_meta`, `resultType`, `server/discover`) and the legacy handshake, decided per request. Accepts JSON-RPC batches. Checked by `scripts/mcp_conformance.py` against the live binary. **Real-client evidence (2026-10-21, legacy `2025-11-25` handshake only)**: MCP Inspector CLI 2.11.0, Claude Code 2.1.289 and the Cursor CLI agent 2026.10.21 each ran `tools/list` + `memory_add` + `memory_query` + `memory_stats` cleanly; opencode 2.0.32 only handshake + `tools/list`. **Not verified**: the modern `2026-07-28` path against any real client, Claude Desktop, Cursor IDE, Codex, Gemini CLI. See `docs/mcp-hosts.md` |
| Embedding | ✅ | Built-in hashed lexer is the default and is byte-identical to pre-MCP builds. `--embedder-cmd` delegates to a long-lived external program over a line protocol (the "optional tier"); no new link dependency either way. Requests are **hex-encoded**, not raw text — see `scripts/embedder_adapter_example.py` |
| Lexical arm | ✅ | `src/retrieval/bm25.zig`, Okapi BM25 over unigrams + bigrams, max-normalised inside the existing `λ_dense=0.5 / λ_sparse=0.2 / λ_graph=0.3` sum. Rebuilt from cells on snapshot restore, never serialised. Identifiers that live only in an `atomic_facts` triple went from 1/12 recall to 12/12 |
| Persistence | ✅ | WAL-first + snapshot. WAL truncated on sync. `--wal-sync=always\|group\|interval:N` (default `always`, byte-identical); `interval` is weaker and documented as such. |
| Daemon hygiene | ✅ | `serve`/`mcp` exit 0 on SIGINT/SIGTERM (`src/platform/signal.zig`: handler only stores an atomic; loops poll with a timeout). `--log-format`/`--log-every` feed `src/utils/logger.zig`; default is silent and byte-identical. JSONL goes to stderr only. |
| Tests | ✅ | 675: 491 (`src/main.zig`-rooted) + 184 (`tests/main.zig`-rooted), plus 12 constitution invariants as a separate gate, 0 leaks |
| Binary | ✅ | 1,259,784 bytes `ReleaseFast` / 5,349,720 bytes Debug (measured 2026-10-22 after the P1/P2 merges), only links libSystem. It was 963,704 bytes ReleaseFast before those merges; the lexical arm alone had added 49 KB (+5.4%) over 914,456 B |
| Toolchain | ✅ | Pinned via `.zigversion` (Zig 0.17.0) |
| Platforms | ✅ | macOS + Linux (x86_64 and aarch64). Windows/WASM refused at compile time — see [Platforms](#platforms) |

**Test-suite rules (learned the hard way — do not regress these):**
1. **A library must never write to stderr.** `zig build test` runs each test binary with `--listen=-`; any stderr write from inside a test desynchronises the runner↔build protocol and the binary dies with `failed command`. `src/main.zig` and `tests/main.zig` therefore set `std_options.log_level = .err`, and all persistence logging goes through `std.log`, never `std.debug.print`.
2. **Never silently skip.** A test that cannot run must `return error.SkipZigTest`, not `return;`. The HTTP e2e tests used to print "skipped" and be counted as passes.
3. **The test step depends on the install artifact**, because the e2e tests exec `zig-out/bin/mem3`.
4. **Tests must not write inside the repo.** All scratch paths live under `/tmp`.
5. **Verify the gate actually fails.** Inject a deliberately failing test and confirm `zig build test` exits non-zero — a green gate that cannot go red is worse than no gate.
6. **A new test root must be reachable from `src/main.zig` or `tests/main.zig`.** `src/utils/serializer.zig` sat outside the gate for a long time: its tests had never run, and a `sizeOf` defect that silently dropped every `?[]const u8` payload survived because of it. A test that is not imported by a root is not a test.
7. **`zig build` never compiles the test roots, so a cross-compile can be green while the tests do not build on that target.** `std.c.Stat` is `void` on Linux (a test calling `std.c.fstat` broke the whole `src/main.zig` test binary there), and `testing.expectEqual` on two string slices compares *pointers* (fails on x86_64 Debug, whose self-hosted backend does not fold equal literals — use `expectEqualStrings`). Check any target with `zig test -target <t> --test-no-exec -femit-bin=/tmp/x --dep mem3 -Mroot=<root> -lc -Mmem3=src/lib.zig -lc`; CI's `cross-compile` job does this for all three roots.

**Known limitations tracked for v0.2.1:**
- Forgetting's conflict term only knows single-valued predicates from a short
  list (or `--functional-predicates`). Default `functional` mode: on the
  synthetic corpus in `mem3-forgetting-eval --mode=netex`, 0 of 180
  multi-valued cells superseded or forgotten (asserted), 60/60 listed
  contradictions superseded; the price is that 60/60 contradictions on an
  *unlisted* single-valued predicate (`shoe_size`) are no longer superseded and
  the old value ranks first in 39 of 60 queries. A *listed* predicate that is
  multi-valued in real data (two jobs) still hides an earlier value;
  `unsupersede` is the way back. `--supersede=all` is the old every-predicate
  heuristic (120/180 multi-valued cells wrongly superseded). Near-duplicates are lowered, not
  forgotten (only ~0.96+ similarity evicts). A snapshot written by this build
  (format v3) is refused by older builds. See ADR 0005. The sweep's wall time on
  a dense templated corpus is still superlinear at 20k cells (not profiled).
- Foresight is durable (WAL + snapshot, CLI/HTTP/MCP) but not searchable: it is
  not embedded and not in the BM25 text, and a cell that names no goal still
  carries the synthetic goal id 0 beside it.
- Write throughput is ~5× short of the 10,000 cells/sec release target: 192
  cells/sec ReleaseFast on the durable path (fsync per record), across four
  `./scripts/verify.sh` runs: 2,779 / 3,028 / 3,800 / 3,898 cells/sec. Report
  the range, not the best run. The cause is `hnsw.insert` (~899 µs/op), not the
  WAL fsync (~1.2 ms/record), and it was measured by phase profile: ~55% of the
  write pipeline is `hnsw.insert`, ~42% the embedder, under 3% the `Store`.
  Those are pre-rework figures: after the 2026-10-21 HNSW rework `hnsw.insert`
  is 886 → 244 µs/op and `store.addRaw_durable` 538 → 275 µs/op (A/B, 5
  interleaved rounds, `docs/roadmap.md` "1a"). The end-to-end cells/sec above
  has not been re-run.
- LongMemEval offline reimplementation: 0.729 core / 0.708 padded (BM25 arm
  active), against a ≥80% target. The old 0.646 / 0.000 figures predate the
  lexical arm. `exhaustive_nn_hit_rate` is 0.604 and invariant across
  configurations, but an external MiniLM embedder moved it to 0.781 without
  moving end-to-end accuracy, so the embedder is not the binding limit either.
  Retrieval on the official dataset (no LLM judge) is in
  `docs/benchmarks/longmemeval-official.md`.
- **No measured retrieval gain from the tri-source tag, goal bonus,
  importance/existence-gain terms or source-dependent decay on LongMemEval-S**
  (pre-registered paired ablation, 419 questions, 79 runs:
  `docs/benchmarks/ablation-tri-source.md`). The tag is not a ranking input on
  `Store.query` (shuffling it: Δ NDCG@10 = 0); heuristic-tag routing lost to
  shuffled-tag routing; the goal bonus cost −0.014/−0.023. The benchmark has no
  goals or source labels, so this is not evidence against the theory — do not
  quote it as such, and do not quote the theory as measured. Also: turn-level
  rankings are not bit-reproducible deep in the tail (the recency factor reads
  the wall clock); compare the first 50 ranks, not whole dumps.

## Development Workflow

1. **Read the task** in `specs/001-trisource-everos-mvp/tasks.md`. Each task has an ID (T001, T002, ...) and a [Story] label.
2. **Write the test first** (TDD, Constitution VI). Run it, verify it fails.
3. **Write the minimum implementation** to make the test pass.
4. **Run `zig build test` and `zig build check-constitution`** to verify no regressions. All 12 constitution invariants MUST stay green.
5. **Commit** with `type(scope): subject` format. Examples:
   - `feat(hypermem): implement multi-hop traversal with confidence threshold`
   - `fix(serializer): correct nested slice handling for HyperEdge.source_weights`
   - `test(constitution): add spirit-dim invariant test`
6. **Run `zig build bench`** if your change touches the hot path (HNSW, HybridRetriever, LSMStore, HTTP server). Compare against the Constitution §Performance Standards.
7. **Open a PR**. CI (`.github/workflows/ci.yml`) is *written to* do the
   following. **It has never run on a GitHub runner**: it was linted with
   `actionlint`/`shellcheck` and its shell steps were executed locally (macOS
   directly; Linux aarch64 in a container). Do not describe CI as green.
   - `build-and-test`, matrix `ubuntu-latest` (x86_64) / `ubuntu-24.04-arm` (aarch64) / `macos-latest` (arm64), `fail-fast: false`:
     - `zig build`, `zig build test`, `zig build check-constitution` (must be green)
     - `scripts/check_linked_libs.sh` — Linux `ldd` allow-list / macOS `otool -L` allow-list (Constitution IV), self-test first, every installed executable, plus a `linkSystemLibrary` grep on `build.zig`
     - `zig build test -Doptimize=ReleaseFast` as a `continue-on-error` step: the known `platform.clock.Timer` fold (README "Known misses", `docs/roadmap.md`) fails it on macOS arm64 (always) and Linux aarch64 (intermittently); failures are surfaced as annotations and in the job summary, not hidden
     - `zig build bench` as a **smoke step only** — machine-dependent, `continue-on-error`, never a gate
     - Assert the working tree is clean after tests (catches tests writing into the repo)
     - Inject a failing test and assert `zig build test` goes non-zero — the permanent guard against a gate that cannot fail
   - `cross-compile`: whole project (Debug + ReleaseFast) and the three test roots (`zig test --test-no-exec`) for `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-macos`, `aarch64-macos`. Compile-only.
   - `unsupported-targets`: `x86_64-windows`, `wasm32-wasi`, `wasm32-freestanding` must fail with the documented refusal message.
   - Known: the `ExternalEmbedder ... BackendExited` race (Linux aarch64: 101/200 failures) is fixed (bounded wait for the child after `EPIPE`; 0/200 after in the same container). A Linux `zig build test` can still be red because of the ReleaseFast Timer folding and load-sensitive tests. Details: README "Continuous integration".

## Common Pitfalls (from project history)

1. **Don't pull in FAISS / HNSWlib / Neo4j / Redis / SQLite** — zero-dep Constitution IV violation. Implement HNSW, hypergraph, KV, WAL in-tree.
2. **Don't use `std.Thread.Mutex` in Zig 0.17 — it doesn't exist.** Neither
   does `std.Thread.sleep`. `std.Io.Mutex` is the replacement, but it requires
   an `Io` instance; the daemon doesn't carry one, so `src/server/http_server.zig`
   locks a libc `std.c.pthread_mutex_t` instead. Pick per call site, and don't
   assume the std path is available.
3. **Don't log to stdout in long-running modes** — per dev.md lessons-learned: silent by default, `--log-every N` for periodic summaries, log rotation external.
4. **Don't introduce a new external dependency without a Constitution amendment** — raise it in the PR, do not silently add.
5. **Don't return `null` for fallible operations** — use tagged error unions. `null` is for absence-of-value, not for errors.
6. **Don't use `std.fs.File.stdout()` directly** — use `std.log.scoped` for log lines. Reserve stdout for CLI output.
7. **Don't forget to write a MemCell's spirit dimension** — `foresight` and `goal_associations` are constitutional requirements. The constitution test in `tests/constitution/spirit_dim.zig` will fail.

## Performance Gates (release-blocking)

Measured figures are from `mem3 bench` (ReleaseFast, 600-cell in-memory corpus)
and `mem3-bench longmemeval` on an Apple M1 Pro. Anything marked **MISS** is a
real gap, not a rounding error.

| Metric | Target | Measured | |
|---|---|---|---|
| MemCell write throughput | ≥ 1K/sec MVP / 1.75K/sec release (amended 2026-10-15, worst window) | worst window 1,863–2,438/sec; mean 3,116–3,898/sec | **pass** |
| Top-10 query P95 | < 50ms MVP / < 10ms release (100K corpus) | 0.624 ms p95 (600-cell corpus) | not comparable — wrong corpus size |
| HNSW build 100K vectors | < 30s | **13.3 s median, 10.4–19.9** with `insertBatch` on 8 threads + construction-time int8 distances (`mem3-bench hnsw-build --threads=8 --build-quant` reports `met_target: true`; 3 interleaved rounds, 10-core M1 Pro, load 16–64; direct runs at load ~12–17: 13.3, 14.3 s). **Not** the live-store path: single thread is 62.2 s with `--build-quant` (57.2–71.9) and 142.6 s without (`main`, 123.7–189.7, same rounds; user CPU 125 s). 8 threads without `--build-quant`: 39.4 s median (23.4–49.3). Parallel graph is not reproducible; recall@10 within 0.5 pt of single-thread at 10k/30k. x86_64/Linux not run | **pass only in that configuration; default single-thread path MISS: 2.1x over with `--build-quant`, 4.8x over without** |
| 3-hop traversal | < 5ms (1K seeds) | 0.000 ms/seed | pass |
| Cold-start | < 200ms | 0.077 ms | pass |
| RSS at 100K cells | < 500MB | Peak memory footprint (`time -l`, MiB, built-in embedder, no WAL, no consolidation, `mem3-bench footprint --cells=100000`, re-measured 2026-10-22): **551.7** with the `DebugAllocator` the binary used to ship (6 runs, all 551.7), **378.9** with `smp_allocator` (4 runs, all 378.9), 227.3 with `smp_allocator` + int8 vectors (off by default). `ru_maxrss` on this swapped host read 123–318 MB for the same runs and is not used; no quiet host was available. Daemon RSS not measured. Live-allocation floor 280 MiB f32 / 170 MiB int8 | **pass with `smp_allocator` (now used by ReleaseFast/ReleaseSmall `mem3`); was a MISS (551.7) with `DebugAllocator`** |
| Binary size | < 10MB stripped | 1,259,784 bytes ReleaseFast (not stripped) | pass |
| External deps (ldd) | 0 | `otool -L` lists only `libSystem` | pass |
| LongMemEval accuracy | ≥ 80% | 0.7292 core / 0.7083 padded (offline reimplementation, BM25 sparse arm active) | **MISS** |

After the HNSW rework (2026-10-21, `docs/roadmap.md` "1a. HNSW rework"),
interleaved against `main` over 5 rounds, `hnsw.insert` measures 886 µs/op on
`main` and **244 µs/op** on the branch, `store.addRaw_durable` 538 → 275 µs/op,
with `wal.append_durable` (the control) unchanged at ~950 µs. The
write-throughput miss was **HNSW insert**, not fsync: `hnsw.insert` was
~899 µs/op, comparable to the ~1.2 ms WAL fsync and above the whole
`store.addRaw_durable` pipeline. Group commit did not move it: `--wal-sync=group`
(opt-in) was A/B-measured over 5 interleaved rounds and is within noise of
`always` on this host (see `docs/roadmap.md`).

The LongMemEval miss is **`lexical_hash`**, not retrieval:
`exhaustive_nn_hit_rate` is 0.604 and identical across the core, quarter-padded,
full-padded and hypergraph-disabled runs, and that control is index-independent.

## Platforms

**macOS and Linux only.** `x86_64-linux-gnu` and `aarch64-linux-gnu` both
cross-compile the whole project clean. Windows and WASM are refused at compile
time by `src/lib.zig` and `src/platform/fs.zig`, each naming the reason:

- **Windows** — `src/server/http_server.zig` binds raw POSIX sockets
  (`socket`/`bind`/`listen`/`accept`) and locks a libc `pthread_mutex_t`.
  Windows needs Winsock (`ws2_32`), a different mutex and a different clock
  story. The library, CLI and benchmarks *were* ported; their Windows branches
  remain in `src/platform/` as unreachable, untested, unmaintained code — a
  record of completed work and a one-line re-enable, **not** a compatibility
  guarantee.
- **WASM** — deferred to v0.3.0 by the existing scope boundary. WASI's open
  flags do not match the POSIX `ACCMODE` layout the platform layer assumes, and
  wasm32's 64-bit atomics need the threads feature.

Rationale and the full sync-impact report:
[`docs/constitution-amendments/2026-10-14-platform-scope.md`](docs/constitution-amendments/2026-10-14-platform-scope.md).

## Reference Architecture Decision Records

Located in `docs/adr/`. Read in order:
- `0001-three-source-ontology.md` — resolves the `matter/form/spirit` vs `sensory/cognitive/action` naming conflict
- `0002-ghw-mapping.md` — formal mapping Goal↔spirit, Harness↔form, World↔matter
- `0003-hnsw-from-scratch.md` — why we don't use FAISS
- `0004-wal-first-persistence.md` — why we don't use RocksDB
- `0005-existence-gain-forgetting.md` — what redundancy and conflict_score *are*, supersession, snapshot v3, measured cost and false-positive rate

## Spec-Kit Quick Reference

This project uses GitHub's spec-kit workflow. Key commands (via `specify` CLI or slash commands in Claude Code):
- `specify init` — project scaffolding (done)
- `/speckit-constitution` — update the 7 principles (only if amendment needed)
- `/speckit-specify` — update spec.md (only for new features)
- `/speckit-plan` — update plan.md
- `/speckit-tasks` — generate tasks.md for a new feature
- `/speckit-implement` — execute the tasks

The current spec-kit artifacts:
- `.specify/memory/constitution.md` (**v1.2.0** — v1.1.0 platform scope, v1.2.0 write-throughput amendment; see
  [`docs/constitution-amendments/2026-10-14-platform-scope.md`](docs/constitution-amendments/2026-10-14-platform-scope.md))
- `specs/001-trisource-everos-mvp/spec.md` (DRAFT)
- `specs/001-trisource-everos-mvp/plan.md` (ready for implementation)
- `specs/001-trisource-everos-mvp/data-model.md` (ready for implementation)
- `specs/001-trisource-everos-mvp/quickstart.md` (ready for new contributors)
- `specs/001-trisource-everos-mvp/tasks.md` (110 tasks, 8 phases)
- `specs/001-trisource-everos-mvp/checklists/requirements.md` (30 checks, all passed)

## Testing

```bash
# All tests: 675 (491 src/main.zig-rooted + 184 tests/main.zig-rooted)
zig build test

# Just the constitution invariants (12, separate root)
zig build check-constitution

# Just one layer
zig build test --test-filter unit
zig build test --test-filter integration
zig build test --test-filter property

# Benchmarks (the release gate)
zig build bench
```

`zig build test` re-runs are served from the build cache and **report green
without re-executing**. When you need a count you can trust, drive the roots
directly:

```bash
zig test --dep mem3 -Mroot=src/main.zig  -Mmem3=src/lib.zig   # All 491 tests passed.
zig test --dep mem3 -Mroot=tests/main.zig -Mmem3=src/lib.zig   # All 184 tests passed.
zig test --dep mem3 -Mroot=tests/constitution/main.zig -Mmem3=src/lib.zig  # All 12 tests passed.
```

Test files live under `tests/{unit,integration,property}/` (one test file
per module/concern). The master runner `tests/main.zig` does
`comptime { _ = @import(...) }` on every file so `zig build test`
collects them all. The pre-existing `tests/constitution/` is run
separately via `zig build check-constitution` to keep it as a distinct
gate per Constitution VI.

## What NOT to do

- Don't write code before reading the relevant spec section.
- Don't skip the constitution tests "for now" — they are the gate.
- Don't add features not in `spec.md` or `tasks.md` without a spec amendment.
- Don't commit secrets, large binaries, or `zig-cache/` to git (see `.gitignore`).
- Don't push to `main` directly. Use a feature branch per the spec-kit convention.

## Questions?

Open an issue or ask the user. When in doubt, read the constitution — it has the answer.
