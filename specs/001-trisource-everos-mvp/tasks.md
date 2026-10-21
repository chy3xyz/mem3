---
description: "Task list for TriSource-EverOS MVP implementation"
---

# Tasks: TriSource-EverOS MVP

> **Legend** (added by the 2026-10-21 audit)
>
> - `- [x]` — done: the artifact exists in the tree and does what the task says. A trailing `_(implemented as ...)_` means it lives under a different path/name than the task states.
> - `- [ ]` — not done. A trailing `_(partial: ...)_` says what exists and what is missing; no note means nothing was found.
> - `- [~]` — superseded / deliberately dropped or deferred; the one-line reason follows. Not counted as open work.
>
> Task descriptions and IDs are unchanged from the original plan; only checkboxes and italic notes were added. The "Checkpoint" lines under each phase are the original plan's aspirations and were **not** re-audited — trust the per-task boxes, not the checkpoints. The "Total: 67 tasks" line below is stale (the file has 110).

## Audit 2026-10-21

Audited against the working tree on branch `feat/p0-foundations` (`src/`, `tests/`, `bench/`, `examples/`, `docs/`, `scripts/`, `.github/`). `zig build check-constitution` was re-run during the audit: 12/12 pass (11 invariant tests + 1 sentinel). `zig build test` was re-run too: 462/462 pass (see T097), and a ReleaseFast build is 963,704 bytes linking only `libSystem` (T099/T100).

**Counts (110 tasks): 65 done `[x]` · 24 partial `[ ]` · 17 open `[ ]` · 4 dropped/deferred `[~]`** (T041, T046, T047, T074). Several `[x]` items carry a caveat in their note (e.g. T051, T076, T098, T099) — read the note before treating the underlying goal as met.

**Top 5 open items**

1. **Durable `--foresight`** (T049, T027) — `mem3 add --foresight` was accepted and discarded in the committed tree, so a foresight-only cell loses its spirit dimension across a restart. A fix is in flight (uncommitted edits in `add.zig` / `store.zig` at audit time) and is **not** counted as done.
2. **Release gates still missed** (T052, T076, T098) — LongMemEval ≥ 80% (measured 0.73 core / 0.71 padded), HNSW build 100K < 30 s (115.3 s median after the 2026-10-21 HNSW rework, was 543 s on the same host; still ~3.8× over), RSS at 100K < 500 MB (687.6 MB before the rework; not re-measured reliably on a loaded host, live bytes ≈ 294 MB f32 / 178 MB int8). The retrieval P95 gate has never been measured at the 100K corpus it names (default bench corpus is 20K). The write-throughput target was amended (2026-10-15), not met as originally written.
3. **Forgetting does not implement `net_existence = importance − redundancy − conflict`** (T083, T080, T084) — the sweep is `importance × decay < threshold`; there is no redundancy or conflict term, no conflict/supersede detection (`superseded_at` is never set), and no `mem3 remember` promote-back command. The MCP tool text and `forgetter.zig` header still describe the full formula.
4. ~~**Daemon/CLI operability gaps** (T092, T095, T101, T102)~~ — closed on `p1/wal`: SIGINT/SIGTERM graceful shutdown for `serve` and `mcp`, `--log-format` / `--log-every` wired to a stderr logger, logrotate config added (not run under a real logrotate).
5. **CI and edge-deploy verification gaps** (T011, T072, T077; T073 and T075 written) — `ci.yml` is now a matrix (ubuntu-latest x86_64, ubuntu-24.04-arm aarch64, macos-latest arm64) plus a four-target cross-compile job and an unsupported-target refusal job, with a portable linked-library check (`scripts/check_linked_libs.sh`). **It has never run on a GitHub runner** — it was linted (`actionlint` + `shellcheck`) and its shell steps were run locally; see the README "Continuous integration" section for exactly what was and was not run. The first real Linux run found two defects (both fixed, see T011) and one more that is **not** fixed: `ExternalEmbedder: a backend that dies mid-request is BackendExited` is a race in `src/retrieval/embedder.zig` that fails ~40–55% of runs on Linux and ~2% on macOS, so a Linux `zig build test` will be red until it is fixed. No qemu: `tests/integration/cross_compile.zig` (T072) does not exist. Also missing: `examples/multi_project.zig`, `examples/multihop_query.zig`, `examples/edge_deploy.zig`, `examples/quick_demo.sh`, `docs/performance.md`.

Not a task in this file, but relevant to "done": real MCP hosts have run against `mem3 mcp` since 2026-10-21 (MCP Inspector 2.11.0, Claude Code 2.1.289, Cursor CLI agent: full add/query/stats sessions; opencode: handshake + tools/list only; see `docs/mcp-hosts.md`). All of them spoke the legacy handshake — the `2026-07-28` stateless branch is still covered only by the in-repo conformance script.

**Input**: Design documents from `/specs/001-trisource-everos-mvp/`
- `spec.md` — feature spec with 4 user stories (US1-P1, US2-P1, US3-P2, US4-P3)
- `plan.md` — technical plan with source layout
- `data-model.md` — TS-MemCell, HyMem, Goal Poset types
- `quickstart.md` — 8-step onboarding

**Prerequisites**: plan.md ✓, spec.md ✓, data-model.md ✓, quickstart.md ✓, constitution.md ✓

**Organization**: Tasks are grouped by user story to enable independent implementation and testing. Each story maps to a runnable MVP increment.

**Constitution tests** (in Phase 2) gate all user story work — they MUST be green before any US task starts.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 / US2 / US3 / US4
- Include exact file paths
- Total: 67 tasks across 8 phases

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project scaffolding, build configuration, and CI infrastructure. All other phases depend on this.

- [x] T001 Create directory layout per `plan.md` §Project Structure (src/core, src/ghw, src/memory, src/hypermem, src/retrieval, src/storage, src/server, src/utils, tests/, bench/, examples/, docs/adr/)
- [x] T002 [P] Write `build.zig` with `addExecutable`, io_uring/GCD detection, test step, bench step (per `dev.md` §3) _(done except io_uring/GCD detection, which does not exist; the HTTP daemon uses raw POSIX sockets, not `std.Io`)_
- [x] T003 [P] Write `build.zig.zon` pinning `zig 0.17.0-dev.XXXX+` with zero dependencies _(zon sets `minimum_zig_version = 0.17.0-dev.3000`; the exact pin is `.zigversion` = 0.17.0; no dependencies)_
- [x] T004 [P] Write `.gitignore` excluding `zig-out/`, `data/`, `*.log`, `zig-cache/`
- [x] T005 [P] Write `README.md` with project intro, build command, link to `AGENTS.md`
- [x] T006 [P] Write `AGENTS.md` (root) — agent onboarding: principles, file map, dev workflow, constitution test gate
- [x] T007 [P] Write `docs/adr/0001-three-source-ontology.md` resolving the `matter/form/spirit` vs `sensory/cognitive/action` nomenclature conflict (per data-model.md note)
- [x] T008 [P] Write `docs/adr/0002-ghw-mapping.md` documenting the Goal/Harness/World → tri-source (matter/form/spirit) mapping
- [x] T009 [P] Write `docs/adr/0003-hnsw-from-scratch.md` justifying zero-dep HNSW
- [x] T010 [P] Write `docs/adr/0004-wal-first-persistence.md` justifying WAL + snapshot over RocksDB _(ADR exists but still describes `lsm_store.zig` / `sstable.zig` / `hnsw.idx` / `kv.idx`, which were never built — see T041, T046, T047)_
- [ ] T011 [P] Set up CI workflow (`.github/workflows/ci.yml`) running `zig build test` + `zig build bench` on Linux + macOS _(written, never run on a runner, so left unchecked: matrix over ubuntu-latest / ubuntu-24.04-arm / macos-latest running build, linked-libs check, test, check-constitution, a `-Doptimize=ReleaseFast` test step (continue-on-error: known `platform.clock.Timer` fold, fails every time on macOS arm64 and intermittently, ~60% of runs of that test, on Linux aarch64 in a container), bench smoke, clean-tree check and the gate-can-go-red guard. Running the suite in Linux containers (aarch64 native, x86_64 cross-compiled + Rosetta) found: `src/storage/wal.zig` test used `std.c.fstat` and did not compile on Linux (fixed); `tests/unit/cli.zig` compared string pointers and failed on x86_64 Debug (fixed); `ExternalEmbedder … BackendExited` race, ~40–55% failure on Linux (NOT fixed, src/ change). Expect a red Linux `zig build test` until the race is fixed)_

**Checkpoint**: `zig build` produces a stub binary that prints "mem3 v0.1.0-alpha" and exits 0.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core types, serializer, and the three constitution invariants. **CRITICAL**: No user story work can begin until this phase is complete.

- [x] T012 [P] Implement `MemorySource` enum + `Fact` + `Foresight` + `GoalAssociation` + `Metadata` + `MemCell` structs in `src/core/memcell.zig` with all 7 fields and `comptime serialized_size: usize` _(implemented as src/core/types.zig (enums/structs) re-exported by src/core/memcell.zig (`MemCell`, `serialized_size`))_
- [x] T013 [P] Implement comptime serializer/deserializer in `src/utils/serializer.zig` supporting Int/Float/Enum/Bool/Pointer(Slice[]u8 and Slice[T])/Struct/Optional — no `anytype` reflection at runtime
- [x] T014 [P] Implement `EdgeType` enum + `HyperEdge` struct in `src/hypermem/hyperedge.zig` with three-source weight vector _(`EdgeType` lives in src/core/types.zig; `HyperEdge.serialized_size` is a hard-coded stub of 64)_
- [x] T015 [P] Implement `GoalNode` struct + `GoalStatus` enum in `src/ghw/goal_tree.zig` _(implemented as src/ghw/goal_node.zig (`GoalNode`) + src/core/types.zig (`GoalStatus`); the poset is in goal_tree.zig)_
- [x] T016 [P] Implement common error types in `src/core/errors.zig` (`MissingSourceTag`, `SpiritDimMissing`, `InvalidWeight`, `DanglingEdge`, `GoalCycle`, `OutOfMemory`, `WALCorrupt`) _(`InvalidWeight` is named `InvalidSourceWeights`; the other six exist verbatim)_
- [ ] T017 [P] Implement `std.log.scoped` wrappers in `src/utils/logger.zig` with JSONL mode _(done on `p1/wal`: `Logger` value type with off/human/jsonl modes; the no-op `initGlobal` was removed; `writeJsonlLine` is now what `--log-format=jsonl` emits; tests parse the lines)_
- [ ] T018 Implement comptime zero-overhead JSON serialization for HTTP API in `src/utils/jsonl.zig` (separate back-end from binary, but same `comptime` codegen approach) _(partial: jsonl.zig has only `writeJsonString` / `writeJsonKey` escaping helpers; HTTP/MCP JSON is hand-written, no comptime codegen)_
- [x] T019 [P] Implement deterministic stub embedder in `src/retrieval/embedder.zig` (xxHash-based, 384-dim) — clearly marked as v0.1.0 stub _(`StubEmbedder`; the default is now the hashed-lexical `LexicalEmbedder` in the same file)_
- [x] T020 [P] Implement `Config` struct in `src/core/config.zig` with all defaults from data-model.md §Configuration
- [x] T021 [P] Implement monotonic ID allocators in `src/core/ids.zig` (`next_memcell_id`, `next_hyperedge_id`, `next_goal_id` with thread-safe increments via `std.Io.Mutex`) _(implemented with `std.atomic.Value(u64)` rather than `std.Io.Mutex`; same thread-safety guarantee)_
- [x] T022 Implement WAL in `src/storage/wal.zig` with append + replay (CRCs, snapshot marker, checksum marker, partial recovery on corruption) _(per-record checksum; replay stops at the first corrupt record and the prefix is recovered; the `snapshot_marker` / `checksum_marker` record types are declared but never emitted — the WAL is truncated on sync instead)_
- [x] T023 Implement snapshot in `src/storage/snapshot.zig` (full state dump + atomic rename + recovery bootstrap)
- [x] T024 [P] Implement time utilities in `src/utils/time.zig` (Unix ms, decay calculation, ISO-8601 formatter)
- [ ] T025 [P] Implement allocators in `src/utils/allocator.zig` (arena, page-pool wrappers, fixed-size pool for HyperEdge nodes)
- [x] T026 Implement **constitution test 1: source_tag invariant** in `tests/constitution/source_tag.zig` — every cell in the test corpus has `source != null` AND `source_confidence >= 0.5`
- [x] T027 Implement **constitution test 2: spirit dimension** in `tests/constitution/spirit_dim.zig` — every cell has `foresight.len > 0 || goal_associations.len > 0` _(test passes; durable `--foresight` persistence is a separate open item, see T049)_
- [x] T028 Implement **constitution test 3: goal coverage** in `tests/constitution/goal_coverage.zig` — every active goal has `associated_memcell_ids.len > 0 || status == .unrealized`
- [x] T029 Implement unit test for `serializer.zig` in `tests/unit/test_serializer.zig` — roundtrip every type, verify `serialized_size` matches actual serialized length _(implemented as inline tests in src/utils/serializer.zig (incl. `sizeOf` == encoded length) + tests/property/serializer_roundtrip.zig + tests/property/adjoint.zig)_
- [ ] T030 Implement unit test for `memcell.zig` in `tests/unit/test_memcell.zig` — all 5 valid-state invariants from data-model.md _(partial: 3 inline tests in src/core/memcell.zig (construction, coherence, weight decay); the 5 data-model invariants are not tested as such; no tests/unit/test_memcell.zig)_
- [ ] T031 Implement unit test for `WAL` in `tests/unit/test_wal.zig` — append, replay, partial-corruption recovery _(partial: inline tests in src/storage/wal.zig cover append+replay and corruption detection; prefix recovery after a corrupt record is exercised only indirectly via Store)_
- [x] T032 Implement unit test for `snapshot.zig` in `tests/unit/test_snapshot.zig` — full state roundtrip _(implemented as ~10 inline tests in src/storage/snapshot.zig: roundtrip, v1 compat, truncation, corrupt rows, goal chains)_

**Checkpoint**: `zig build test` is GREEN. The three constitution tests pass on the fixture corpus. All 8 ADRs are written. CI runs `zig build test` + `zig build bench` and is green on the foundation.

---

## Phase 3: User Story 1 — Researcher's Notebook (Priority: P1) 🎯 MVP

**Goal**: A solo researcher can `mem3 add` cells and `mem3 query` to retrieve GHW-prioritized results across all three sources, with P95 < 50ms at 100K corpus.

**Independent Test**: Run `examples/notebook.zig` which adds 1000 cells across M/F/S, then queries with a time + source + goal filter, verifying P95 < 50ms and ≥ 4 results from each source when no filter is applied.

### Tests for User Story 1

- [ ] T033 [P] [US1] Write integration test `tests/integration/end_to_end.zig` — full lifecycle on 100 hand-crafted cells (cover encode → store → query → forget) _(partial: tests/integration/store_persistence_e2e.zig + http_server_e2e.zig cover insert/restart/forget/snapshot; no single 100-cell encode→query→forget lifecycle test)_
- [ ] T034 [P] [US1] Write integration test `tests/integration/cross_source_query.zig` — US1 acceptance scenario 2 (≥ 4 results per source on unfiltered query)
- [ ] T035 [P] [US1] Write fixture `tests/fixtures/corpus.json` with 100 balanced cells (33 matter, 33 form, 34 spirit)

### Implementation for User Story 1

- [x] T036 [P] [US1] Implement `TriSourceManager` in `src/memory/tri_source_manager.zig` with three `AutoHashMap`s (sensory/cognitive/action) and `addMemory` / `getMemory` / `getMemoriesBySource` / `consolidateMemories` (per `dev.md` §2.2.2) _(methods are `add` / `get` / `getBySource`; consolidation lives in src/memory/consolidator.zig)_
- [x] T037 [P] [US1] Implement `coherence.zig` in `src/memory/coherence.zig` with `C_tri = C_MF · C_FS · C_SM` cosine-similarity product
- [x] T038 [P] [US1] Implement `encoder.zig` in `src/memory/encoder.zig` with the 4-step pipeline (EventSegmentation → GenerateMemCell → HyperMem.Insert → Index updates)
- [x] T039 [P] [US1] Implement `src/utils/hashing.zig` (xxHash3) for the embedder stub
- [x] T040 [P] [US1] Implement HNSW core in `src/retrieval/hnsw.zig` (~400 LOC: insert, search, delete, ef, M parameters) per `dev.md` §3.1 + `ghw_memory_system.agent.final.md` §4.2.2 _(now ~1,950 LOC; delete is `markDeleted` tombstoning)_
- [~] T041 [P] [US1] Implement HNSW persistence in `src/retrieval/hnsw_persist.zig` (read/write `.idx` file) _(deliberately not built: the index is rebuilt from the cells on snapshot restore — cells are the source of truth; pinned by a Store test)_
- [x] T042 [P] [US1] Implement BM25 keyword index in `src/retrieval/keyword.zig` (~200 LOC, in-memory inverted index) _(implemented as src/retrieval/bm25.zig, Okapi BM25 over unigrams + bigrams, ~600 LOC)_
- [x] T043 [P] [US1] Implement `HybridRetriever` in `src/retrieval/hybrid_retriever.zig` with three-way recall fusion (λ_dense=0.5, λ_sparse=0.2, λ_graph=0.3)
- [x] T044 [P] [US1] Implement `reranker.zig` in `src/retrieval/reranker.zig` with GHW-prioritized formula: `final = base × (1 + 0.4·goal) × (1 + 0.3·existence) × (1 + 0.2·recency)`
- [x] T045 [US1] Implement `lifecycle.zig` in `src/memory/lifecycle.zig` orchestrating the 4 stages (depends on T036-T044)
- [~] T046 [US1] Implement `kv_index.zig` in `src/retrieval/kv_index.zig` with O(1) id → offset lookup _(superseded: id → cell lookup is `Store.cell_index`, an in-memory hash map in src/store/store.zig; there are no on-disk offsets because there is no LSM store, see T047)_
- [~] T047 [US1] Implement `lsm_store.zig` in `src/storage/lsm_store.zig` with memtable + sstable (per `dev.md` §2.4) using `std.Io` for async writes _(deferred: v0.1.0-alpha persists via WAL + snapshot over in-memory maps; `docs/releases/v0.1.0-alpha.md` says "LSM/SSTable planned for v0.2.0"; no lsm_store.zig / sstable.zig exist)_
- [x] T048 [US1] Wire `TriSourceManager` → `LSMStore` → `HNSW` → `KV` → `HybridRetriever` → `Reranker` in `src/main.zig`'s `add` + `query` CLI commands _(implemented as the shared `Store` in src/store/store.zig, which owns WAL + snapshot + manager + HNSW + BM25 + HyMem + reranker; both CLI and daemon call it; no LSM/KV stage)_
- [ ] T049 [US1] Implement `cli_commands/add.zig` and `cli_commands/query.zig` per the contract in plan.md §Contracts _(partial: both work end to end incl. `--source/--episode/--facts/--goal-ids/--relevances/--topk/--source-filter`; `--foresight` is not durable in the committed tree — the fix is in flight, uncommitted; `query` has no `--max-hops`, see T067)_
- [x] T050 [US1] Implement `examples/notebook.zig` (US1 scenario demo) _(demo adds 3 goals + 30 balanced cells and ranks by importance; it does not run the 1000-cell / P95 query scenario from the story's Independent Test — that is covered by `example-loadtest` and `bench/`)_
- [x] T051 [US1] Implement `bench/throughput.zig` (≥ 1K writes/sec MVP gate) _(gate met; constitutional target was later amended to 1.75K/s worst window, see docs/constitution-amendments/2026-10-15-write-throughput-target.md)_
- [ ] T052 [US1] Implement `bench/retrieval_p95.zig` (P95 < 50ms MVP gate at 100K corpus) _(partial: bench exists and runs the real three-way recall, but its default corpus is 20K and the gate has not been measured at 100K — HNSW build at 100K takes ~430 s; recorded figures are at 600–2,000 cells)_

**Checkpoint**: User Story 1 is fully functional. `mem3 add` and `mem3 query` work end-to-end. `examples/notebook.zig` runs. US1 acceptance scenarios 1, 2, 3 pass. Bench gates met.

---

## Phase 4: User Story 2 — Goal-Aware Multi-Project Memory (Priority: P1)

**Goal**: A user can manage a Goal Poset, bind memories to goals at creation time, and `mem3 query --goal-ids=X` reorders results by the goal bonus.

**Independent Test**: Run `examples/multi_project.zig` which creates 3 goals (`ghw`/`mem3`/`learn3`), adds 30 cells with varying goal bindings, then queries with each goal and verifies the top-5 sets differ by ≥ 60%.

### Tests for User Story 2

- [ ] T053 [P] [US2] Write integration test `tests/integration/goal_aware.zig` — US2 acceptance scenarios 1, 2, 3 _(partial: Store tests in src/store/store.zig ("the GHW goal scope changes the ranking", insert/query traversal) cover the behavior; no tests/integration/goal_aware.zig and no top-5-differs-by-60% check)_

### Implementation for User Story 2

- [x] T054 [P] [US2] Implement `Goal Poset` in `src/ghw/goal_tree.zig` with parent/child links, priority, DFS traversal, cycle detection
- [x] T055 [P] [US2] Implement synthetic `⊥` (root) and `⊤` (top) goals
- [x] T056 [P] [US2] Implement `goal associations` index in `src/ghw/goal_index.zig` (reverse map: goal_id → memcell_ids) _(implemented as `memcellsFor` / `bindMemcell` / `unbindMemcell` inside src/ghw/goal_tree.zig)_
- [x] T057 [P] [US2] Implement `meta_goal_evaluator.zig` in `src/ghw/meta_goal.zig` for periodic re-evaluation of goal bindings (per paper §4.1.3) _(implemented as `GoalPoset.evaluateMetaGoals` / `staleGoals` in src/ghw/goal_tree.zig, driven by the daemon's maintenance thread)_
- [ ] T058 [US2] Implement `cli_commands/goal.zig` with `add`, `list`, `delete`, `bind`, `unbind` subcommands _(partial: `add`, `list` and `status` exist; `delete`, `bind`, `unbind` do not)_
- [x] T059 [US2] Wire `--goal-ids` + `--relevances` flags into `cli_commands/add.zig`
- [x] T060 [US2] Wire `--goal-ids` flag into `cli_commands/query.zig` to inject `goal_bonus` into the reranker
- [ ] T061 [US2] Implement `examples/multi_project.zig` (US2 scenario demo)

**Checkpoint**: US2 acceptance scenarios all pass. `mem3 goal` CLI works. Goal bindings affect ranking. Constitution test 3 (goal coverage) passes on the fixture.

---

## Phase 5: User Story 3 — Hypergraph Multi-Hop Reasoning (Priority: P2)

**Goal**: A user can `mem3 query --max-hops=3` and get results that traverse typed hyperedges, including 2+ hop connections that pure vector search would miss.

**Independent Test**: Hand-craft a 50-cell fixture with 30 typed edges, run `mem3 query` with `--max-hops=3`, assert ≥ 1 cell at 2+ hops from the dense seed and 0 cells at 4+ hops.

### Tests for User Story 3

- [ ] T062 [P] [US3] Write integration test `tests/integration/multihop.zig` — US3 acceptance scenarios 1, 2 _(partial: multi-hop is covered by unit tests in src/hypermem/engine.zig, Store tests, and HTTP `maxHops` tests in http_server.zig; no tests/integration/multihop.zig)_

### Implementation for User Story 3

- [x] T063 [P] [US3] Implement `HyperMem` engine in `src/hypermem/engine.zig` with `addNode`, `addEdge`, `getNeighbors`, `multiHopRetrieval` _(`getNeighbors` is `edgesOf` / `nodesIn`; `multiHopRetrieval` is `multiHop` / `multiHopScored`)_
- [x] T064 [P] [US3] Implement `multi_hop.zig` in `src/hypermem/multi_hop.zig` with BFS + confidence threshold + visited-set + frontier queue _(implemented as `HyMem.multiHop` / `multiHopScored` in src/hypermem/engine.zig)_
- [ ] T065 [P] [US3] Implement `msg_passing.zig` in `src/hypermem/msg_passing.zig` with attention-weighted aggregation over hyperedges _(partial: `multiHopScored` propagates relevance with per-hop decay, but there is no attention-weighted aggregation and no msg_passing.zig)_
- [x] T066 [P] [US3] Implement `graph_index.zig` in `src/hypermem/graph_index.zig` with `node_to_edges` and `edge_to_nodes` adjacency maps _(implemented as the `node_to_edges` / `edge_to_nodes` maps inside src/hypermem/engine.zig)_
- [ ] T067 [US3] Wire hypergraph into `HybridRetriever` (third recall channel) and into `cli_commands/query.zig` `--max-hops` flag _(partial: the graph arm is wired into `HybridRetriever` and exposed as `maxHops` on `POST /api/query`; `mem3 query` has no `--max-hops` flag — only `mem3 inspect` and `hyperedge multi-hop` take hop counts)_
- [ ] T068 [US3] Implement `cli_commands/hyperedge.zig` with `add`, `list`, `remove` _(partial: `add`, `list` and `multi-hop` exist; `remove` does not, although `HyMem.removeEdge` does)_
- [ ] T069 [US3] Implement property test `tests/property/hypergraph_props.zig` — no duplicate edges, all node references valid, source_weights sum to 1 _(only example-based `HyperEdge.validate` tests exist in src/hypermem/engine.zig)_
- [ ] T070 [US3] Implement `examples/multihop_query.zig` (US3 scenario demo)
- [x] T071 [US3] Implement `bench/multihop.zig` (3-hop traversal < 5ms MVP gate for 1K seeds) _(gate met: ~0.03 ms p95 per seed in the recorded run)_

**Checkpoint**: US3 acceptance scenarios pass. Multi-hop queries find transitive connections. `bench/multihop` meets its gate.

---

## Phase 6: User Story 4 — Edge Deployment (Priority: P3)

**Goal**: The binary cross-compiles to aarch64-linux-gnu and runs in `qemu-aarch64` with zero shared library deps and < 200ms cold start.

**Independent Test**: `zig build -Dtarget=aarch64-linux-gnu && qemu-aarch64 -L /usr/aarch64-linux-gnu ./zig-out/bin/mem3 serve --port 7777` then `curl http://127.0.0.1:7777/healthz` returns 200 in < 200ms.

### Tests for User Story 4

- [ ] T072 [P] [US4] Write integration test `tests/integration/cross_compile.zig` — invoke `zig build` with aarch64 target, verify binary runs under qemu _(no such test, no qemu. Substitutes, none of them this task: the CI `cross-compile` job builds the whole project and all three test roots for four targets; the CI matrix runs natively on an aarch64 Linux runner (not yet observed); and the aarch64-linux and x86_64-linux binaries were executed once in OrbStack Linux containers — x86_64 via Rosetta — 2026-10-21)_

### Implementation for User Story 4

- [x] T073 [P] [US4] Audit `build.zig` for any accidental `linkSystemLibrary` calls (Constitution IV); add a CI step that greps for it _(build.zig has no `linkSystemLibrary`/`linkFramework`; ci.yml has a grep tripwire plus `scripts/check_linked_libs.sh` (ldd allow-list on Linux, `otool -L` allow-list on macOS) with a 23-case `--self-test`. Validated locally: self-test, a deliberately broken allow-list turns it red, real `otool -L` on macOS, real `ldd` output from Ubuntu 24.04 aarch64 and x86_64 containers (all 8 installed executables pass). The workflow step itself has not run on a runner)_
- [~] T074 [P] [US4] Verify Zig 0.17 std.Io works in aarch64-linux-gnu (io_uring backend); if not, fall back to blocking I/O on aarch64 _(moot: the daemon uses blocking raw POSIX sockets and a libc pthread mutex, not `std.Io`/io_uring; aarch64-linux-gnu was additionally built and its test suite run once in an OrbStack Linux container on 2026-10-21 — blocking I/O, nothing io_uring-related was exercised)_
- [x] T075 [P] [US4] Add `zig build -Dtarget=...` to CI matrix (linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64) _(ci.yml job `cross-compile`: Debug + ReleaseFast of the whole project plus `zig test --test-no-exec` of the three test roots per target, and an artifact-format check; job `unsupported-targets` asserts `x86_64-windows`, `wasm32-wasi`, `wasm32-freestanding` fail with the documented refusal. Every command was run locally and every one of the four targets compiled; the job has not run on a runner. Compile-only: nothing foreign is executed by it)_
- [x] T076 [US4] Implement `bench/cold_start.zig` (< 200ms gate) and `bench/footprint.zig` (< 500MB RSS at 100K cells) _(both benches exist and run; cold-start gate met, **footprint gate MISSED**: 687.6 MB peak RSS at 100K cells vs < 500 MB)_
- [ ] T077 [US4] Implement `examples/edge_deploy.zig` — minimal HTTP server on aarch64 with no libs

**Checkpoint**: Cross-compilation works for all 4 targets. `ldd` shows zero deps on aarch64. Cold-start meets gate.

---

## Phase 7: Lifecycle & Daemon (Supporting US1)

**Purpose**: Implement the remaining lifecycle stages (Consolidation, Forgetting) and the HTTP daemon — all needed to make US1 truly end-to-end.

### Lifecycle — Consolidation

- [x] T078 [P] Implement `consolidator.zig` in `src/memory/consolidator.zig` with hierarchical agglomerative clustering (HAC, sim_threshold=0.75)
- [ ] T079 [P] Implement `MemScene` struct in `src/memory/mem_scene.zig` (center_M, structure_F, meaning_S, coherence_C) _(no MemScene type exists; the consolidator emits abstract cells instead)_
- [ ] T080 [P] Implement conflict detection in `src/memory/conflict.zig` (PCR: mark old as `superseded_at`, never delete) _(partial: `Metadata.superseded_at` field exists and consolidation never deletes originals, but nothing detects conflicts or ever sets `superseded_at`; no conflict.zig)_
- [x] T081 [P] Implement `cli_commands/consolidate.zig`
- [ ] T082 [P] Implement property test `tests/property/consolidation_props.zig` — HAC scene count is O(sqrt(N)) _(only example tests in tests/unit/consolidator.zig (similar → 1 abstract, dissimilar → none, PCR, empty, order-independence); no scaling property test)_

### Lifecycle — Forgetting

- [ ] T083 [P] Implement `forgetter.zig` in `src/memory/forgetter.zig` with `net_existence = importance - redundancy - conflict_score` and `is_fuzzy` threshold _(partial: forgetter.zig exists and moves cells to the fuzzy store (never deletes) when `importance × decay < forgetting_threshold`; there is no redundancy or conflict term, so `net_existence` as specified is not implemented)_
- [ ] T084 [P] Implement `fuzzy.zig` in `src/memory/fuzzy.zig` (fuzzy store with read-only forgetting, promote-back via explicit `mem3 remember`) _(partial: `FuzzyStore` lives in src/memory/forgetter.zig, is persisted in the snapshot and has `promote()`; there is no `mem3 remember` command, no HTTP/MCP promote route, and no fuzzy.zig)_
- [x] T085 [P] Implement decay-rate asymmetry: λ_m > λ_f > λ_s > 0 (per Constitution III) _(`Config.decayRateFor`, applied in the encoder; asserted by a Config test)_
- [ ] T086 [P] Implement `cli_commands/forget.zig` with `--threshold` and `--dry-run` _(partial: `--dry-run` works; there is no `--threshold` flag)_
- [ ] T087 [P] Write unit test `tests/unit/test_forgetter.zig` — verify spirit-high cells go to fuzzy, not deleted _(partial: inline tests in src/memory/forgetter.zig cover "low importance gets fuzzied" and promote; nothing specifically about spirit-high cells; WAL/restart behavior is covered in store_persistence_e2e.zig)_

### HTTP Daemon

- [x] T088 [P] Implement HTTP/1.1 server in `src/server/http_server.zig` using `std.Io` (no external HTTP libs) _(implemented over raw POSIX sockets + a libc `pthread_mutex_t`, not `std.Io`; no external HTTP library)_
- [ ] T089 [P] Implement route table in `src/server/routes.zig` (POST /memcells, GET /memcells/{id}, POST /query, GET /goals, POST /goals, GET /metrics, GET /healthz) _(partial: routing is inline in http_server.zig under `/api/*` (`/api/memcells`, `/api/memcells/:id`, `/api/query`, `/api/goals` GET, plus `/api/sync`, `/api/forget`, `/healthz`, `/metrics`); `POST /api/goals` is missing and there is no routes.zig)_
- [x] T090 [P] Implement handlers in `src/server/handlers/*.zig` _(implemented as methods inside src/server/http_server.zig; there is no handlers/ directory)_
- [x] T091 [P] Implement JSON middleware in `src/server/middleware.zig` (parse body, set `Content-Type: application/json`) _(implemented inline in src/server/http_server.zig; there is no middleware.zig)_
- [ ] T092 [P] Implement SIGINT/SIGTERM handler in `serve.zig` for graceful shutdown (no torn WAL) _(done on `p1/wal` in `src/platform/signal.zig`, wired in `serve` and `mcp`; e2e tests send SIGTERM/SIGINT to the real binary and check exit 0 and data intact on restart)_
- [x] T093 [P] Implement `/metrics` Prometheus endpoint with: `memcell_count`, `hyperedge_count`, `hnsw_layer_count`, `query_p50_ms`, `query_p95_ms`, `query_p99_ms`, `forgotten_total`, `fuzzy_count` _(implemented under `mem3_*` names: `memstore_cells`, `hyperedges`, `vector_index_depth`, `retrieval_latency_p50/p95/p99_us` (microseconds), `forgotten_cells_total`; `fuzzy_count` exists only as that cumulative counter, not a current-size gauge)_
- [x] T094 [P] Write integration test `tests/integration/http_routes.zig` — POST/GET all endpoints, verify shape and status codes _(implemented as tests/integration/http_server_e2e.zig (healthz, POST/GET memcells, restart, metrics) + ~30 inline `route(...)` tests in src/server/http_server.zig (goals, query, forget, metrics))_
- [ ] T095 [P] Implement `cli_commands/serve.zig` with `--port`, `--bind`, `--data-dir`, `--log-every`, `--log-format=jsonl` _(done on `p1/wal`: `--log-every` and `--log-format` are now read by `serve`; also `--wal-sync`)_
- [x] T096 [P] Implement `cli_commands/inspect.zig` (show MemCell + its hypergraph neighborhood) and `cli_commands/dump.zig` (full state JSONL export)

**Checkpoint**: Full lifecycle works end-to-end via CLI. HTTP daemon serves all routes. `mem3 forget` correctly demotes spirit-high cells to fuzzy store. `tests/integration/end_to_end.zig` covers the full pipeline.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Make the system production-ready for v0.1.0-alpha release.

- [x] T097 [P] Run `zig build test` and verify all 67 tasks' tests pass; fix any flaky tests _(re-run 2026-10-21: 462/462 pass — 378 in the `src/main.zig` root + 84 in the `tests/main.zig` root — plus 12/12 in `check-constitution`, on a tree that includes other agents' uncommitted edits; this covers only the tasks that exist, and AGENTS.md's test counts are stale)_
- [x] T098 [P] Run `zig build bench` and verify all gates met (or document which are aspirational) _(gates are NOT all met; the misses (HNSW 100K build, RSS at 100K, LongMemEval, original write-throughput target) are documented in AGENTS.md §Performance Gates and docs/roadmap.md "Known misses")_
- [x] T099 [P] Verify `ldd zig-out/bin/mem3` shows only the dynamic linker + vDSO (no shared libs) _(verified on macOS with `otool -L`: only `libSystem.B.dylib`; `ldd` on Linux not run in this audit or in CI)_
- [x] T100 [P] Run `wc -c zig-out/bin/mem3` and verify ≤ 10MB stripped _(963,704 bytes ReleaseFast)_
- [ ] T101 [P] Add `--log-every N` flag to all subcommands (per dev.md lessons-learned: silent by default in long-running modes) _(done for `serve` only on `p1/wal`: periodic summary every N seconds; `mcp` has no periodic summary by design, only startup/shutdown events under an explicit `--log-format`; other subcommands are one-shot)_
- [ ] T102 [P] Add JSONL log rotation hook (external `logrotate` config in `docs/deploy/logrotate.conf`) _(`docs/deploy/logrotate.conf` added; written, not run under a real logrotate)_
- [x] T103 [P] Add `docs/roadmap.md` listing v0.2.0+ deferred features (distributed, embedding, WASM, GUI) _(exists and lists deferred work (Windows, WASM → v0.3.0, optional external embedder, known misses); distributed and GUI are not listed)_
- [ ] T104 [P] Add inline Zig doc-comments to all public APIs (Constitution: explicit Allocator, no hidden globals) _(partial: heavily commented, but a rough scan finds ~40% of `pub fn` / `pub const X = struct|enum|union` declarations without a `///` comment, e.g. in hnsw.zig, platform/fs.zig, embedder.zig, store.zig, http_server.zig)_
- [ ] T105 [P] Add `docs/performance.md` summarizing benchmark results vs Constitution targets _(file does not exist; the figures live in the AGENTS.md "Performance Gates" table and docs/roadmap.md)_
- [ ] T106 [P] Add a 5-minute demo script `examples/quick_demo.sh` that takes a contributor from zero to a populated store _(does not exist; `scripts/verify.sh` is a verification script, not a demo)_
- [x] T107 [P] Bump version to `0.1.0-alpha` in `build.zig.zon` and `README.md`
- [x] T108 [P] Tag the release: `git tag -a v0.1.0-alpha -m "TriSource-EverOS MVP: Tri-Source Coherence + GHW paradigm"` _(annotated tag exists locally, pointing at an early commit (ab4bd25), not the current HEAD; the repo has no `origin` remote, so nothing was pushed)_
- [ ] T109 [P] Write release notes `docs/releases/v0.1.0-alpha.md` with: features, known limitations, performance summary, what's next _(partial: file exists with all sections, but its figures are stale and overclaim — "7.2M cells/sec" (Debug), "2.4 MB binary", "11/11 invariants", dated 2026-06-08 — and it does not mention the measured misses or MCP)_
- [ ] T110 [P] Final constitution compliance review (manual sign-off; all 7 principles verified) _(no sign-off record found; the constitution is v1.2.0 while AGENTS.md still says v1.1.0)_

**Checkpoint**: v0.1.0-alpha is release-ready. `zig build` produces a single < 10MB binary. `zig build test` + `zig build bench` are green. Constitution principles verified. Release tag pushed.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: no dependencies. Can start immediately.
- **Phase 2 (Foundational)**: depends on Phase 1. **BLOCKS** all user story work.
- **Phase 3 (US1)**: depends on Phase 2. **MVP gate** — must complete for any release.
- **Phase 4 (US2)**: depends on Phase 2 + Phase 3 (US1) for goal-aware queries.
- **Phase 5 (US3)**: depends on Phase 2 + Phase 3 (US1) for retrieval pipeline integration.
- **Phase 6 (US4)**: depends on Phase 2 + Phase 3 (US1); can run in parallel with US2/US3.
- **Phase 7 (Lifecycle + Daemon)**: depends on Phase 2 + Phase 3. Can run in parallel with US2/US3.
- **Phase 8 (Polish)**: depends on all desired user stories.

### Parallel Opportunities

- **Within Phase 1**: T002, T003, T004, T005, T006, T007, T008, T009, T010, T011 all [P] — can run in parallel.
- **Within Phase 2**: T012-T016 (types), T017, T018, T019, T020, T021 (utils), T024, T025 (utils) all [P].
- **Within Phase 3 (US1)**: T036, T037, T038, T039, T040, T041, T042, T043, T044, T046, T047 are all [P] once the foundational types exist. T045, T048-T052 are serial (wire-up).
- **Within Phase 4 (US2)**: T054, T055, T056, T057, T058 are [P]. T059, T060, T061 depend on the wire-up.
- **Within Phase 5 (US3)**: T063, T064, T065, T066 are [P]. T067, T068, T069, T070, T071 depend on them.
- **Within Phase 6 (US4)**: T073, T074, T075 are [P]. T076, T077 depend on the cross-compile.
- **Within Phase 7**: T078, T079, T080, T081, T082 (consolidation) all [P]; T083-T087 (forgetting) all [P]; T088-T096 (daemon) all [P].
- **Phases 4, 5, 6, 7 can run in parallel after Phase 3** (different files, no cross-dependencies).

### Critical Path

The longest dependency chain is: T001 → T002 → T012 → T040 → T045 → T048 → T097 → T110.

Estimated duration: with 1 developer serial, ~10-12 weeks (matches dev.md §4 12-week roadmap). With 2-3 developers in parallel after Phase 2, ~5-6 weeks.

---

## Implementation Strategy

### MVP First (US1 + US2 only)

1. Complete Phase 1 (Setup)
2. Complete Phase 2 (Foundational) — **CRITICAL gate**
3. Complete Phase 3 (US1) → validate independently
4. Complete Phase 4 (US2) → validate independently
5. **STOP and VALIDATE**: run `examples/notebook.zig` + `examples/multi_project.zig`
6. Tag as v0.1.0-alpha

This is the minimum viable release: a single researcher can use mem3 with goal-aware retrieval.

### Incremental Delivery

1. Phases 1+2 → Foundation ready
2. Phase 3 (US1) → MVP! → tag v0.1.0-alpha-1
3. Phase 4 (US2) → Goal-aware → tag v0.1.0-alpha-2
4. Phase 5 (US3) → Multi-hop → tag v0.1.0-alpha-3
5. Phase 6 (US4) → Edge deploy → tag v0.1.0-alpha-4
6. Phase 7 (Daemon + Lifecycle) → Production-ready → tag v0.1.0-alpha-rc1
7. Phase 8 (Polish) → v0.1.0-alpha release

### Parallel Team Strategy

With 2-3 developers:
- Dev A: US1 (Phases 3+7) — main developer
- Dev B: US2 + US3 (Phases 4+5) — secondary
- Dev C: US4 + Polish (Phases 6+8) — infrastructure
- All share Phase 1+2 work, then diverge

Solo strategy (current constraint per user_profile): Dev A does all phases sequentially. Phases 1+2 take ~2 weeks, US1 takes ~2 weeks, US2 takes ~1 week, US3 takes ~1 week, US4 takes ~1 week, Phase 7 takes ~2 weeks, Phase 8 takes ~1 week. Total ~10-11 weeks. **Pace: ship the foundation first, then add capabilities incrementally.**

---

## Notes

- All [P] tasks = different files, no dependencies; safe to run in parallel.
- [USn] label maps each task to a user story for traceability.
- Each user story phase is independently completable and testable.
- The three constitution tests (T026, T027, T028) MUST be GREEN before any US task starts. They are the quality gate.
- Commit after each task or logical group. Use `type(scope): subject` format per Constitution.
- Stop at any phase checkpoint to validate the story independently.
- **Avoid**: vague tasks, same-file conflicts, cross-story dependencies that break independence.
- **Constitution is law**: if a task's implementation would violate a principle, raise it in the PR; do not silently violate.
