---
description: "Task list for TriSource-EverOS MVP implementation"
---

# Tasks: TriSource-EverOS MVP

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

- [ ] T001 Create directory layout per `plan.md` §Project Structure (src/core, src/ghw, src/memory, src/hypermem, src/retrieval, src/storage, src/server, src/utils, tests/, bench/, examples/, docs/adr/)
- [ ] T002 [P] Write `build.zig` with `addExecutable`, io_uring/GCD detection, test step, bench step (per `dev.md` §三)
- [ ] T003 [P] Write `build.zig.zon` pinning `zig 0.17.0-dev.XXXX+` with zero dependencies
- [ ] T004 [P] Write `.gitignore` excluding `zig-out/`, `data/`, `*.log`, `zig-cache/`
- [ ] T005 [P] Write `README.md` with project intro, build command, link to `AGENTS.md`
- [ ] T006 [P] Write `AGENTS.md` (root) — agent onboarding: principles, file map, dev workflow, constitution test gate
- [ ] T007 [P] Write `docs/adr/0001-three-source-ontology.md` resolving the `matter/form/spirit` vs `sensory/cognitive/action` nomenclature conflict (per data-model.md note)
- [ ] T008 [P] Write `docs/adr/0002-ghw-mapping.md` documenting the Goal/Harness/World → 三源 mapping
- [ ] T009 [P] Write `docs/adr/0003-hnsw-from-scratch.md` justifying zero-dep HNSW
- [ ] T010 [P] Write `docs/adr/0004-wal-first-persistence.md` justifying WAL + snapshot over RocksDB
- [ ] T011 [P] Set up CI workflow (`.github/workflows/ci.yml`) running `zig build test` + `zig build bench` on Linux + macOS

**Checkpoint**: `zig build` produces a stub binary that prints "mem3 v0.1.0-alpha" and exits 0.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core types, serializer, and the three constitution invariants. **CRITICAL**: No user story work can begin until this phase is complete.

- [ ] T012 [P] Implement `MemorySource` enum + `Fact` + `Foresight` + `GoalAssociation` + `Metadata` + `MemCell` structs in `src/core/memcell.zig` with all 7 fields and `comptime serialized_size: usize`
- [ ] T013 [P] Implement comptime serializer/deserializer in `src/utils/serializer.zig` supporting Int/Float/Enum/Bool/Pointer(Slice[]u8 and Slice[T])/Struct/Optional — no `anytype` reflection at runtime
- [ ] T014 [P] Implement `EdgeType` enum + `HyperEdge` struct in `src/hypermem/hyperedge.zig` with three-source weight vector
- [ ] T015 [P] Implement `GoalNode` struct + `GoalStatus` enum in `src/ghw/goal_tree.zig`
- [ ] T016 [P] Implement common error types in `src/core/errors.zig` (`MissingSourceTag`, `SpiritDimMissing`, `InvalidWeight`, `DanglingEdge`, `GoalCycle`, `OutOfMemory`, `WALCorrupt`)
- [ ] T017 [P] Implement `std.log.scoped` wrappers in `src/utils/logger.zig` with JSONL mode
- [ ] T018 Implement comptime zero-overhead JSON serialization for HTTP API in `src/utils/jsonl.zig` (separate back-end from binary, but same `comptime` codegen approach)
- [ ] T019 [P] Implement deterministic stub embedder in `src/retrieval/embedder.zig` (xxHash-based, 384-dim) — clearly marked as v0.1.0 stub
- [ ] T020 [P] Implement `Config` struct in `src/core/config.zig` with all defaults from data-model.md §Configuration
- [ ] T021 [P] Implement monotonic ID allocators in `src/core/ids.zig` (`next_memcell_id`, `next_hyperedge_id`, `next_goal_id` with thread-safe increments via `std.Io.Mutex`)
- [ ] T022 Implement WAL in `src/storage/wal.zig` with append + replay (CRCs, snapshot marker, checksum marker, partial recovery on corruption)
- [ ] T023 Implement snapshot in `src/storage/snapshot.zig` (full state dump + atomic rename + recovery bootstrap)
- [ ] T024 [P] Implement time utilities in `src/utils/time.zig` (Unix ms, decay calculation, ISO-8601 formatter)
- [ ] T025 [P] Implement allocators in `src/utils/allocator.zig` (arena, page-pool wrappers, fixed-size pool for HyperEdge nodes)
- [ ] T026 Implement **constitution test 1: source_tag invariant** in `tests/constitution/source_tag.zig` — every cell in the test corpus has `source != null` AND `source_confidence >= 0.5`
- [ ] T027 Implement **constitution test 2: spirit dimension** in `tests/constitution/spirit_dim.zig` — every cell has `foresight.len > 0 || goal_associations.len > 0`
- [ ] T028 Implement **constitution test 3: goal coverage** in `tests/constitution/goal_coverage.zig` — every active goal has `associated_memcell_ids.len > 0 || status == .unrealized`
- [ ] T029 Implement unit test for `serializer.zig` in `tests/unit/test_serializer.zig` — roundtrip every type, verify `serialized_size` matches actual serialized length
- [ ] T030 Implement unit test for `memcell.zig` in `tests/unit/test_memcell.zig` — all 5 valid-state invariants from data-model.md
- [ ] T031 Implement unit test for `WAL` in `tests/unit/test_wal.zig` — append, replay, partial-corruption recovery
- [ ] T032 Implement unit test for `snapshot.zig` in `tests/unit/test_snapshot.zig` — full state roundtrip

**Checkpoint**: `zig build test` is GREEN. The three constitution tests pass on the fixture corpus. All 8 ADRs are written. CI runs `zig build test` + `zig build bench` and is green on the foundation.

---

## Phase 3: User Story 1 — Researcher's Notebook (Priority: P1) 🎯 MVP

**Goal**: A solo researcher can `mem3 add` cells and `mem3 query` to retrieve GHW-prioritized results across all three sources, with P95 < 50ms at 100K corpus.

**Independent Test**: Run `examples/notebook.zig` which adds 1000 cells across M/F/S, then queries with a time + source + goal filter, verifying P95 < 50ms and ≥ 4 results from each source when no filter is applied.

### Tests for User Story 1

- [ ] T033 [P] [US1] Write integration test `tests/integration/end_to_end.zig` — full lifecycle on 100 hand-crafted cells (cover encode → store → query → forget)
- [ ] T034 [P] [US1] Write integration test `tests/integration/cross_source_query.zig` — US1 acceptance scenario 2 (≥ 4 results per source on unfiltered query)
- [ ] T035 [P] [US1] Write fixture `tests/fixtures/corpus.json` with 100 balanced cells (33 matter, 33 form, 34 spirit)

### Implementation for User Story 1

- [ ] T036 [P] [US1] Implement `TriSourceManager` in `src/memory/tri_source_manager.zig` with three `AutoHashMap`s (sensory/cognitive/action) and `addMemory` / `getMemory` / `getMemoriesBySource` / `consolidateMemories` (per `dev.md` §2.2.2)
- [ ] T037 [P] [US1] Implement `coherence.zig` in `src/memory/coherence.zig` with `C_tri = C_MF · C_FS · C_SM` cosine-similarity product
- [ ] T038 [P] [US1] Implement `encoder.zig` in `src/memory/encoder.zig` with the 4-step pipeline (EventSegmentation → GenerateMemCell → HyperMem.Insert → Index updates)
- [ ] T039 [P] [US1] Implement `src/utils/hashing.zig` (xxHash3) for the embedder stub
- [ ] T040 [P] [US1] Implement HNSW core in `src/retrieval/hnsw.zig` (~400 LOC: insert, search, delete, ef, M parameters) per `dev.md` §3.1 + `ghw_memory_system.agent.final.md` §4.2.2
- [ ] T041 [P] [US1] Implement HNSW persistence in `src/retrieval/hnsw_persist.zig` (read/write `.idx` file)
- [ ] T042 [P] [US1] Implement BM25 keyword index in `src/retrieval/keyword.zig` (~200 LOC, in-memory inverted index)
- [ ] T043 [P] [US1] Implement `HybridRetriever` in `src/retrieval/hybrid_retriever.zig` with three-way recall fusion (λ_dense=0.5, λ_sparse=0.2, λ_graph=0.3)
- [ ] T044 [P] [US1] Implement `reranker.zig` in `src/retrieval/reranker.zig` with GHW-prioritized formula: `final = base × (1 + 0.4·goal) × (1 + 0.3·existence) × (1 + 0.2·recency)`
- [ ] T045 [US1] Implement `lifecycle.zig` in `src/memory/lifecycle.zig` orchestrating the 4 stages (depends on T036-T044)
- [ ] T046 [US1] Implement `kv_index.zig` in `src/retrieval/kv_index.zig` with O(1) id → offset lookup
- [ ] T047 [US1] Implement `lsm_store.zig` in `src/storage/lsm_store.zig` with memtable + sstable (per `dev.md` §2.4) using `std.Io` for async writes
- [ ] T048 [US1] Wire `TriSourceManager` → `LSMStore` → `HNSW` → `KV` → `HybridRetriever` → `Reranker` in `src/main.zig`'s `add` + `query` CLI commands
- [ ] T049 [US1] Implement `cli_commands/add.zig` and `cli_commands/query.zig` per the contract in plan.md §Contracts
- [ ] T050 [US1] Implement `examples/notebook.zig` (US1 scenario demo)
- [ ] T051 [US1] Implement `bench/throughput.zig` (≥ 1K writes/sec MVP gate)
- [ ] T052 [US1] Implement `bench/retrieval_p95.zig` (P95 < 50ms MVP gate at 100K corpus)

**Checkpoint**: User Story 1 is fully functional. `mem3 add` and `mem3 query` work end-to-end. `examples/notebook.zig` runs. US1 acceptance scenarios 1, 2, 3 pass. Bench gates met.

---

## Phase 4: User Story 2 — Goal-Aware Multi-Project Memory (Priority: P1)

**Goal**: A user can manage a Goal Poset, bind memories to goals at creation time, and `mem3 query --goal-ids=X` reorders results by the goal bonus.

**Independent Test**: Run `examples/multi_project.zig` which creates 3 goals (`ghw`/`mem3`/`learn3`), adds 30 cells with varying goal bindings, then queries with each goal and verifies the top-5 sets differ by ≥ 60%.

### Tests for User Story 2

- [ ] T053 [P] [US2] Write integration test `tests/integration/goal_aware.zig` — US2 acceptance scenarios 1, 2, 3

### Implementation for User Story 2

- [ ] T054 [P] [US2] Implement `Goal Poset` in `src/ghw/goal_tree.zig` with parent/child links, priority, DFS traversal, cycle detection
- [ ] T055 [P] [US2] Implement synthetic `⊥` (root) and `⊤` (top) goals
- [ ] T056 [P] [US2] Implement `goal associations` index in `src/ghw/goal_index.zig` (reverse map: goal_id → memcell_ids)
- [ ] T057 [P] [US2] Implement `meta_goal_evaluator.zig` in `src/ghw/meta_goal.zig` for periodic re-evaluation of goal bindings (per paper §4.1.3)
- [ ] T058 [US2] Implement `cli_commands/goal.zig` with `add`, `list`, `delete`, `bind`, `unbind` subcommands
- [ ] T059 [US2] Wire `--goal-ids` + `--relevances` flags into `cli_commands/add.zig`
- [ ] T060 [US2] Wire `--goal-ids` flag into `cli_commands/query.zig` to inject `goal_bonus` into the reranker
- [ ] T061 [US2] Implement `examples/multi_project.zig` (US2 scenario demo)

**Checkpoint**: US2 acceptance scenarios all pass. `mem3 goal` CLI works. Goal bindings affect ranking. Constitution test 3 (goal coverage) passes on the fixture.

---

## Phase 5: User Story 3 — Hypergraph Multi-Hop Reasoning (Priority: P2)

**Goal**: A user can `mem3 query --max-hops=3` and get results that traverse typed hyperedges, including 2+ hop connections that pure vector search would miss.

**Independent Test**: Hand-craft a 50-cell fixture with 30 typed edges, run `mem3 query` with `--max-hops=3`, assert ≥ 1 cell at 2+ hops from the dense seed and 0 cells at 4+ hops.

### Tests for User Story 3

- [ ] T062 [P] [US3] Write integration test `tests/integration/multihop.zig` — US3 acceptance scenarios 1, 2

### Implementation for User Story 3

- [ ] T063 [P] [US3] Implement `HyperMem` engine in `src/hypermem/engine.zig` with `addNode`, `addEdge`, `getNeighbors`, `multiHopRetrieval`
- [ ] T064 [P] [US3] Implement `multi_hop.zig` in `src/hypermem/multi_hop.zig` with BFS + confidence threshold + visited-set + frontier queue
- [ ] T065 [P] [US3] Implement `msg_passing.zig` in `src/hypermem/msg_passing.zig` with attention-weighted aggregation over hyperedges
- [ ] T066 [P] [US3] Implement `graph_index.zig` in `src/hypermem/graph_index.zig` with `node_to_edges` and `edge_to_nodes` adjacency maps
- [ ] T067 [US3] Wire hypergraph into `HybridRetriever` (third recall channel) and into `cli_commands/query.zig` `--max-hops` flag
- [ ] T068 [US3] Implement `cli_commands/hyperedge.zig` with `add`, `list`, `remove`
- [ ] T069 [US3] Implement property test `tests/property/hypergraph_props.zig` — no duplicate edges, all node references valid, source_weights sum to 1
- [ ] T070 [US3] Implement `examples/multihop_query.zig` (US3 scenario demo)
- [ ] T071 [US3] Implement `bench/multihop.zig` (3-hop traversal < 5ms MVP gate for 1K seeds)

**Checkpoint**: US3 acceptance scenarios pass. Multi-hop queries find transitive connections. `bench/multihop` meets its gate.

---

## Phase 6: User Story 4 — Edge Deployment (Priority: P3)

**Goal**: The binary cross-compiles to aarch64-linux-gnu and runs in `qemu-aarch64` with zero shared library deps and < 200ms cold start.

**Independent Test**: `zig build -Dtarget=aarch64-linux-gnu && qemu-aarch64 -L /usr/aarch64-linux-gnu ./zig-out/bin/mem3 serve --port 7777` then `curl http://127.0.0.1:7777/healthz` returns 200 in < 200ms.

### Tests for User Story 4

- [ ] T072 [P] [US4] Write integration test `tests/integration/cross_compile.zig` — invoke `zig build` with aarch64 target, verify binary runs under qemu

### Implementation for User Story 4

- [ ] T073 [P] [US4] Audit `build.zig` for any accidental `linkSystemLibrary` calls (Constitution IV); add a CI step that greps for it
- [ ] T074 [P] [US4] Verify Zig 0.17 std.Io works in aarch64-linux-gnu (io_uring backend); if not, fall back to blocking I/O on aarch64
- [ ] T075 [P] [US4] Add `zig build -Dtarget=...` to CI matrix (linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64)
- [ ] T076 [US4] Implement `bench/cold_start.zig` (< 200ms gate) and `bench/footprint.zig` (< 500MB RSS at 100K cells)
- [ ] T077 [US4] Implement `examples/edge_deploy.zig` — minimal HTTP server on aarch64 with no libs

**Checkpoint**: Cross-compilation works for all 4 targets. `ldd` shows zero deps on aarch64. Cold-start meets gate.

---

## Phase 7: Lifecycle & Daemon (Supporting US1)

**Purpose**: Implement the remaining lifecycle stages (Consolidation, Forgetting) and the HTTP daemon — all needed to make US1 truly end-to-end.

### Lifecycle — Consolidation

- [ ] T078 [P] Implement `consolidator.zig` in `src/memory/consolidator.zig` with hierarchical agglomerative clustering (HAC, sim_threshold=0.75)
- [ ] T079 [P] Implement `MemScene` struct in `src/memory/mem_scene.zig` (center_M, structure_F, meaning_S, coherence_C)
- [ ] T080 [P] Implement conflict detection in `src/memory/conflict.zig` (PCR: mark old as `superseded_at`, never delete)
- [ ] T081 [P] Implement `cli_commands/consolidate.zig`
- [ ] T082 [P] Implement property test `tests/property/consolidation_props.zig` — HAC scene count is O(sqrt(N))

### Lifecycle — Forgetting

- [ ] T083 [P] Implement `forgetter.zig` in `src/memory/forgetter.zig` with `net_existence = importance - redundancy - conflict_score` and `is_fuzzy` threshold
- [ ] T084 [P] Implement `fuzzy.zig` in `src/memory/fuzzy.zig` (fuzzy store with read-only forgetting, promote-back via explicit `mem3 remember`)
- [ ] T085 [P] Implement decay-rate asymmetry: λ_m > λ_f > λ_s > 0 (per Constitution III)
- [ ] T086 [P] Implement `cli_commands/forget.zig` with `--threshold` and `--dry-run`
- [ ] T087 [P] Write unit test `tests/unit/test_forgetter.zig` — verify spirit-high cells go to fuzzy, not deleted

### HTTP Daemon

- [ ] T088 [P] Implement HTTP/1.1 server in `src/server/http_server.zig` using `std.Io` (no external HTTP libs)
- [ ] T089 [P] Implement route table in `src/server/routes.zig` (POST /memcells, GET /memcells/{id}, POST /query, GET /goals, POST /goals, GET /metrics, GET /healthz)
- [ ] T090 [P] Implement handlers in `src/server/handlers/*.zig`
- [ ] T091 [P] Implement JSON middleware in `src/server/middleware.zig` (parse body, set `Content-Type: application/json`)
- [ ] T092 [P] Implement SIGINT/SIGTERM handler in `serve.zig` for graceful shutdown (no torn WAL)
- [ ] T093 [P] Implement `/metrics` Prometheus endpoint with: `memcell_count`, `hyperedge_count`, `hnsw_layer_count`, `query_p50_ms`, `query_p95_ms`, `query_p99_ms`, `forgotten_total`, `fuzzy_count`
- [ ] T094 [P] Write integration test `tests/integration/http_routes.zig` — POST/GET all endpoints, verify shape and status codes
- [ ] T095 [P] Implement `cli_commands/serve.zig` with `--port`, `--bind`, `--data-dir`, `--log-every`, `--log-format=jsonl`
- [ ] T096 [P] Implement `cli_commands/inspect.zig` (show MemCell + its hypergraph neighborhood) and `cli_commands/dump.zig` (full state JSONL export)

**Checkpoint**: Full lifecycle works end-to-end via CLI. HTTP daemon serves all routes. `mem3 forget` correctly demotes spirit-high cells to fuzzy store. `tests/integration/end_to_end.zig` covers the full pipeline.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Make the system production-ready for v0.1.0-alpha release.

- [ ] T097 [P] Run `zig build test` and verify all 67 tasks' tests pass; fix any flaky tests
- [ ] T098 [P] Run `zig build bench` and verify all gates met (or document which are aspirational)
- [ ] T099 [P] Verify `ldd zig-out/bin/mem3` shows only the dynamic linker + vDSO (no shared libs)
- [ ] T100 [P] Run `wc -c zig-out/bin/mem3` and verify ≤ 10MB stripped
- [ ] T101 [P] Add `--log-every N` flag to all subcommands (per dev.md lessons-learned: silent by default in long-running modes)
- [ ] T102 [P] Add JSONL log rotation hook (external `logrotate` config in `docs/deploy/logrotate.conf`)
- [ ] T103 [P] Add `docs/roadmap.md` listing v0.2.0+ deferred features (distributed, embedding, WASM, GUI)
- [ ] T104 [P] Add inline Zig doc-comments to all public APIs (Constitution: explicit Allocator, no hidden globals)
- [ ] T105 [P] Add `docs/performance.md` summarizing benchmark results vs Constitution targets
- [ ] T106 [P] Add a 5-minute demo script `examples/quick_demo.sh` that takes a contributor from zero to a populated store
- [ ] T107 [P] Bump version to `0.1.0-alpha` in `build.zig.zon` and `README.md`
- [ ] T108 [P] Tag the release: `git tag -a v0.1.0-alpha -m "TriSource-EverOS MVP — 三源合恰 + GHW 范式"`
- [ ] T109 [P] Write release notes `docs/releases/v0.1.0-alpha.md` with: features, known limitations, performance summary, what's next
- [ ] T110 [P] Final constitution compliance review (manual sign-off; all 7 principles verified)

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

Estimated duration: with 1 developer serial, ~10-12 weeks (matches dev.md §四 12-week roadmap). With 2-3 developers in parallel after Phase 2, ~5-6 weeks.

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
