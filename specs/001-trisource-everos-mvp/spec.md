# Feature Specification: TriSource-EverOS MVP

**Feature Branch**: `001-trisource-everos-mvp`

**Created**: 2026-06-07

**Status**: Draft (post-clarification ready for planning)

**Input**: User description: "TriSource-EverOS: a zero-dependency memory OS (Zig 0.17) driven by Tri-Source Coherence and the GHW paradigm, MVP stage"

**Theoretical Foundation**:
- Tri-Source Coherence Theory: matter (M) / form (F) / spirit (S) three-source ontology.
- GHW paradigm: Goal-Harness-World three-layer memory architecture.
- Engineering blueprint: `dev.md` (Zig 0.17 idioms, 12-week roadmap, type sketches).
- Formal paper: `ghw_memory_system.agent.final.md` (TS-MemCell proof, category-theoretic semantics).

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Researcher's Notebook (Priority: P1) 🎯 MVP

A solo AI researcher (n0x) is building the `mem3` (mem-cubed) project. They run the `mem3` daemon in the background and pipe their development thoughts, code discoveries, and paper notes through it. The daemon indexes everything as three-source memories, and when the researcher comes back the next morning, they ask "what did I learn about Zig 0.17's `std.Io` last week?" and get a hypergraph-walked, GHW-prioritized answer that links the original code, the paper note, and the goal context.

**Why this priority**: This is the user's actual day-to-day workflow. Without it, mem3 is just another theoretical artifact. It validates the entire three-source + GHW pipeline end-to-end with real human-scale data.

**Independent Test**: Can be fully tested by `mem3 add` × 100 simulated MemCells across M/F/S sources, then `mem3 query` with a time-range + source-filter + goal-filter combo, and verifying P95 < 50ms and that the top-10 results include items from all three sources when no filter is applied.

**Acceptance Scenarios**:

1. **Given** an empty `mem3` instance, **When** the user runs `mem3 add --source=matter --episode "..." --facts '...' --foresight '...' --goal-id 7`, **Then** the system stores the MemCell, writes it to WAL, indexes it in HNSW + KV + hypergraph, and prints the assigned `id`.
2. **Given** 1000 MemCells with realistic three-source distribution, **When** the user runs `mem3 query "Zig 0.17 std.Io async patterns" --topk=10`, **Then** the system returns 10 results ranked by `0.5·dense_sim + 0.2·sparse_sim + 0.3·graph_relevance` × `(1 + 0.4·goal_bonus)·(1 + 0.3·existence_bonus)·(1 + 0.2·recency_bonus)`, and ≥ 4 results come from each source (M/F/S) when no source filter is applied.
3. **Given** a MemCell whose importance has decayed below θ_e and age > AGE_THRESHOLD, **When** the consolidation daemon runs, **Then** the MemCell is moved to the fuzzy store and its hypergraph edges are downgraded to "fuzzy" type, but the MemCell is NEVER deleted.
4. **Given** two MemCells with conflicting `atomic_facts`, **When** the user adds a new one, **Then** the new one is stored with `valid_time` = [now, ∞), the old one is marked `superseded_at` = now (not deleted), and the Goal Poset reflects both facts with their temporal validity.

---

### User Story 2 — Goal-Aware Multi-Project Memory (Priority: P1)

The same researcher is running multiple parallel projects: `ghw` (digital life framework), `mem3` (this project), and `learn3` (knowledge graph playground). They want mem3 to remember that a memory about "Zig comptime metaprogramming" is HIGHLY relevant to the `ghw` project's goal "build self-evolving agent kernel" but LESS relevant to `learn3`. The system should let them manage the Goal Poset explicitly, bind memories to goals at creation time, and let the goal binding influence retrieval ranking via the `goal_bonus` factor.

**Why this priority**: Goal-aware memory is the killer differentiator of GHW over RAG/Mem0. Without explicit goal binding + ranking, mem3 is "just another vector DB". This scenario is what makes GHW engineering, not philosophy.

**Independent Test**: Create 3 goals with explicit priority ordering, add 30 MemCells with various `goal_associations`, then run `mem3 query --goal-ids=ghw` and verify that the top-5 results all have `goal_associations[goal_id=ghw].relevance > 0.5`. Cross-check by running the same query with `--goal-ids=learn3` and verifying the result sets differ by ≥ 60%.

**Acceptance Scenarios**:

1. **Given** no goals exist, **When** the user runs `mem3 goal add --name "build-ghw-kernel" --priority 9`, **Then** the system creates a goal node in the Goal Poset with `id` = 1 and priority 9.
2. **Given** a goal exists, **When** the user runs `mem3 add --goal "build-ghw-kernel" --relevance 0.8 ...`, **Then** the new MemCell's `goal_associations` includes `(goal_id=1, relevance=0.8)`.
3. **Given** multiple goals with different priorities, **When** the user runs `mem3 query ... --goal-boost`, **Then** the result ranking includes `goal_bonus = max(goal_associations[goal_id ∈ query_goals].relevance)`, multiplied into the final score.

---

### User Story 3 — Hypergraph Multi-Hop Reasoning (Priority: P2)

The user asks a question that requires connecting two memories through a third (3-hop). For example: "What was the relationship between that Zig 0.17 std.Io issue I noted last week, the WAL pattern I designed for mem3, and the GHW paper's existence-gain dynamics?" The system should walk the hypergraph to find transitive connections that pure vector similarity would miss.

**Why this priority**: Multi-hop reasoning is what hypergraph buys you over a pure vector store. It's the second-most-important differentiator (after goals) and is what justifies the zero-dep HNSW + hypergraph implementation complexity.

**Independent Test**: Hand-craft a test fixture with 50 MemCells and 30 typed hyperedges (Causal / Temporal / Associative / Goal), then run `mem3 query "..." --max-hops=3 --edge-types=Causal,Goal` and assert that the result includes at least one cell that is 2-hops away from the top dense-similarity seed, and that no result is 4+ hops away.

**Acceptance Scenarios**:

1. **Given** a query, **When** multi-hop is enabled, **Then** the system performs ≥ 1 expansion iteration over the seed nodes, each iteration only visiting edges with `confidence(e) > θ` (default θ=0.3).
2. **Given** `max_hops=3`, **When** the traversal runs, **Then** the iteration count is capped at 3 and the visited set prevents cycles.

---

### User Story 4 — Single-Binary Deployment to Edge Device (Priority: P3)

A future scenario: the user wants to deploy `mem3` to a Raspberry Pi 5 as a personal memory co-processor. They cross-compile with `zig build -Dtarget=aarch64-linux-gnu`, copy the 9MB binary over, and it runs without any library dependencies, with a cold-start < 200ms and < 50MB RSS at idle.

**Why this priority**: Edge deployment is a stated design goal of dev.md but a P3 for the MVP — the core architecture must be sound first. Tests for this scenario ensure we don't accidentally introduce libc / external-service dependencies.

**Independent Test**: `zig build -Dtarget=aarch64-linux-gnu` produces a binary that runs under `qemu-aarch64` without any shared library references (`ldd build/mem3-aarch64` shows only `linux-vdso` and the interpreter).

**Acceptance Scenarios**:

1. **Given** the build is run with `-Dtarget=aarch64-linux-gnu`, **When** the binary is inspected with `file build/mem3-aarch64`, **Then** it reports ARM aarch64 ELF.
2. **Given** the binary is run on a foreign-arch emulator with no libs, **When** the daemon starts, **Then** it serves `GET /healthz` with `200 OK` within 200ms.

---

### Edge Cases

- **Empty store query**: query against an empty store returns 0 results and a structured empty response, NOT an error.
- **Concurrent writes to same id**: Zig 0.17's `std.Io.Mutex` serializes writes; readers see the latest committed state. Tests verify no torn writes.
- **Disk full during WAL write**: the system returns `OutOfMemory` (Zig's idiomatic error), logs the failure with cell id, and refuses to acknowledge the cell as committed. The cell can be retried after disk is freed.
- **Corrupted WAL on startup**: replay stops at the first invalid record, logs a warning with offset, and the system starts in a "degraded mode" where uncommitted writes are lost but committed ones are preserved.
- **Goal deletion when memories still reference it**: the goal is moved to a `tombstone` state, existing `goal_associations` keep their `goal_id` reference but `goal_bonus` is computed as 0 for the tombstoned goal.
- **Source tag drift**: if a MemCell's content no longer matches its `source_tag` (e.g., the classifier re-evaluates and disagrees), the system records the disagreement as a `metadata.drift_score` and triggers a consolidation review, but does not auto-relabel.
- **HNSW rebuild after crash**: on startup, the HNSW index is rebuilt from the persisted MemCells (or read from a snapshot if present). The rebuild takes < 30s for 100K cells.
- **Long-running daemon (weeks)**: per dev.md lessons-learned, no per-cycle stdout. Progress logs are at `--log-every N` intervals. The log file size is bounded via log rotation (external `logrotate`/`newsyslog`).

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST implement `TS-MemCell` as a 7-tuple struct with the exact fields and types from `dev.md` §3 (id, source_tag, episode, atomic_facts, foresight, goal_associations, metadata).
- **FR-002**: System MUST classify every MemCell with a `source_tag ∈ {M, F, S}` at encoding time. Reject untyped memories with a `MissingSourceTag` error.
- **FR-003**: System MUST compute `importance_score` for every MemCell using the constitutional formula `α·source_coherence + β·goal_relevance + γ·existential_contribution` with `α=0.30, β=0.40, γ=0.30` defaults.
- **FR-004**: System MUST implement the GHW three-layer architecture as separate modules: `ghw/goal_tree.zig`, `ghw/harness_registry.zig`, `ghw/world_model.zig`. Each MUST declare its GHW layer in file-level doc-comment.
- **FR-005**: System MUST implement the four-stage memory lifecycle: Encoding → Consolidation → Recollection → Forgetting. Each stage MUST be a public function in `src/memory/lifecycle.zig`.
- **FR-006**: System MUST implement `HyMem` (Hypergraph Memory Engine) as a node+hyperedge store with the four edge types: Causal, Temporal, Associative, Goal. Each edge carries a three-source weight vector `(w_M, w_F, w_S)`.
- **FR-007**: System MUST implement three-way recall: HNSW dense vector index (in-memory, from-scratch), KV exact index, hypergraph relational index. Fusion weights default `λ_dense=0.5, λ_sparse=0.2, λ_graph=0.3`.
- **FR-008**: System MUST implement GHW-prioritized ranking: `final_score = base_score × (1 + 0.4·goal_bonus) × (1 + 0.3·existence_bonus) × (1 + 0.2·recency_bonus)`.
- **FR-009**: System MUST implement multi-hop hypergraph traversal with configurable `max_hops` (default 3) and `edge_types` filter.
- **FR-010**: System MUST implement existence-gain-driven forgetting: `net_existence = importance − redundancy − conflict_score`. Memories with `net_existence < 0` are candidates for forgetting; those with `spirit_coherence > 0.7` go to the fuzzy store, not deleted.
- **FR-011**: System MUST implement a Goal Poset as a partially ordered set with priority values and parent-child relationships, supporting goal creation, deletion, priority update, and hierarchy query.
- **FR-012**: System MUST implement bidirectional transduction: encoding path Goal→Harness→World (the outward path) and retrieval path World→Harness→Goal (the inward path). Cross-layer shortcuts are forbidden by Constitution §II.
- **FR-013**: System MUST implement a tri-source coherence check: `C_tri = C_MF · C_FS · C_SM` where each `C_XY` is the cosine similarity of the source embeddings.
- **FR-014**: System MUST implement `MemScene` as a consolidation-time cluster: `⟨center_M, structure_F, meaning_S, coherence_C⟩`. Created via hierarchical agglomerative clustering with `sim_threshold=0.75`.
- **FR-015**: System MUST implement conflict detection and resolution via PCR: new fact + temporal validity markers, old fact marked `superseded_at = now`, never deleted.
- **FR-016**: System MUST provide a CLI binary `mem3` with subcommands: `add`, `query`, `goal`, `dump`, `inspect`, `bench`, `serve`, `consolidate`, `forget`. Each subcommand MUST support `--json` output mode.
- **FR-017**: System MUST provide an HTTP daemon `mem3 serve --port N` with REST endpoints: `POST /memcells`, `GET /memcells/{id}`, `POST /query`, `GET /goals`, `POST /goals`, `GET /metrics`, `GET /healthz`.
- **FR-018**: System MUST persist all state to a local directory `data/` with files: `memcells.bin`, `hyperedges.bin`, `kv.idx`, `hnsw.idx`, `goal_poset.bin`, `wal.log`. Reload on startup must restore the full state.
- **FR-019**: System MUST implement async I/O via Zig 0.17's `std.Io` interface, using `io_uring` on Linux and GCD on macOS. No thread-per-request.
- **FR-020**: System MUST use `comptime` metaprogramming for all serialization. Runtime reflection is forbidden. Each serializable type MUST have `pub comptime serialized_size: usize`.
- **FR-021**: System MUST implement HNSW from scratch in Zig. The core algorithm (~400 LOC) MUST support incremental insert, delete, and search with `ef` and `M` parameters configurable at runtime.
- **FR-022**: System MUST implement a logged WAL for crash recovery. Every committed MemCell write is preceded by a `WAL_RECORD_TYPE_MEMCELL` log entry. Replay reconstructs state on startup.
- **FR-023**: System MUST NOT introduce any external runtime dependency. `ldd build/mem3` shows only the dynamic linker and vDSO. No `libc`, no `libm`, no `libpthread` (use Zig 0.17's `std.Io.Threaded`).
- **FR-024**: System MUST be cross-compilable to aarch64-linux-gnu, x86_64-linux-gnu, x86_64-macos, aarch64-macos, wasm32-freestanding. `zig build -Dtarget=...` works without an external toolchain.
- **FR-025**: System MUST emit structured logs via `std.log.scoped`, support JSONL format (`--log-format=jsonl`), and default to silent for long-running modes (with `--log-every N` for periodic summaries).
- **FR-026**: System MUST provide a `mem3 bench` command that runs the performance benchmarks from Constitution §Performance Standards and prints a JSON report.
- **FR-027**: System MUST satisfy the constitution invariants in `tests/constitution/`: (a) every MemCell has a non-null `source_tag`, (b) every MemCell has ≥ 1 `foresight` OR ≥ 1 `goal_association` (spirit dimension is present), (c) every active goal has ≥ 1 associated MemCell OR is marked `unrealized`.

### Key Entities

- **TS-MemCell**: The atomic memory unit. 7-tuple ⟨id, source_tag, episode, atomic_facts, foresight, goal_associations, metadata⟩. ~1KB typical serialized size.
- **HyperEdge**: A typed relation connecting 2+ MemCells. Carries a three-source weight vector and a confidence score.
- **GoalNode**: A node in the Goal Poset. Carries id, parent_id, priority (0-255), description, status (Pending/InProgress/Completed/Failed/Unrealized), and a set of associated MemCell ids.
- **Harness**: An execution primitive registered in the Harness Registry. Carries capabilities, success rate, avg duration, and a set of skill memories.
- **WorldEntity**: A real-world entity (person, place, thing, concept) tracked by the World Model. Carries attributes, predictions with validity windows, and confidence.
- **MemScene**: A consolidation-time cluster of related MemCells. Carries center_M, structure_F, meaning_S, coherence_C.
- **FuzzyMemStore**: The "dim memory" archive. Holds demoted but not deleted MemCells. Read-only with respect to forgetting — entries can be promoted back via explicit `mem3 remember` invocation.
- **WAL Record**: A log entry for crash recovery. Types: `MEMCELL_INSERT`, `MEMCELL_UPDATE`, `HYPEREDGE_ADD`, `GOAL_CREATE`, `GOAL_UPDATE`, `FORGET`.

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A single researcher can run `mem3 serve` and `mem3 add` ≥ 1000 MemCells across all three sources in a single session with no manual restarts and no crashes.
- **SC-002**: `mem3 query "..."` against a 100K-MemCell corpus returns Top-10 in P95 < 50ms (v0.1.0-alpha) / < 10ms (v0.2.0-mvp) on a single M1 core.
- **SC-003**: The cross-source retrieval (US1 scenario 2) returns ≥ 4 results from each source (M/F/S) for unfiltered queries on a balanced corpus.
- **SC-004**: Goal-aware ranking (US2 scenario 3) reorders results such that the top-5 under `--goal-ids=ghw` and `--goal-ids=learn3` differ by ≥ 60% on a hand-crafted fixture.
- **SC-005**: Multi-hop traversal (US3) finds ≥ 1 cell at 2+ hops from the top dense seed, and never returns cells at > `max_hops` distance.
- **SC-006**: The single binary `mem3` is < 10MB stripped and has zero shared library dependencies (verified via `ldd`).
- **SC-007**: Edge deployment (US4) on `qemu-aarch64` starts the daemon in < 200ms cold-start and serves `GET /healthz` in < 50ms.
- **SC-008**: Constitution tests pass 100% on every PR. `zig build test` is green. The three constitution invariants (FR-027) hold for the entire test corpus.
- **SC-009**: The codebase has ≥ 80% line coverage for `src/core/`, `src/memory/`, `src/ghw/`, `src/hypermem/`, `src/retrieval/`.
- **SC-010**: A new contributor can build, test, and run the full system on a fresh checkout in < 10 minutes, following only `AGENTS.md` + `quickstart.md` (no need to read the full 2000+ lines of dev.md).

---

## Assumptions

- **Target user**: solo developer-researcher running on a Unix-like system (macOS, Linux). No multi-user auth in v0.1.0-alpha.
- **Network**: the daemon is local-only by default (`127.0.0.1:7777`). LAN access via `--bind 0.0.0.0` is opt-in.
- **Embedding model**: v0.1.0-alpha ships with a deterministic stub embedder (hash-based, 384-dim) for self-test purposes. Bring-your-own embedding is supported via `--embedder=path/to/onnx` (out-of-scope for v0.1.0-alpha; v0.2.0).
- **Data integrity**: WAL is append-only. Crash recovery is best-effort within a single session; long-term durability relies on filesystem durability.
- **Single process**: no IPC, no shared memory, no cross-process locking. v0.1.0-alpha is single-process, single-daemon.
- **Language**: all code, comments, and commit messages in English. Documentation may have a parallel Chinese version (out of v0.1.0-alpha scope).
- **Dependency on upstream Zig**: the system targets `zig 0.17.0-dev.3000+` and is expected to track the dev branch. API stability is best-effort; the system pins to a specific commit in `build.zig.zon`.

## Non-Goals (v0.1.0-alpha)

- Distributed consensus / Raft
- Distributed vector sharding
- LLM integration for embedding / extraction
- WASM32 with full async I/O
- GUI / Web UI
- Multi-tenant / auth
- Replication / backup automation
- Embedding model fine-tuning

These are tracked in `docs/roadmap.md` for v0.2.0+.

## Out-of-Scope Dependencies

The following are deliberately NOT dependencies:
- FAISS, HNSWlib, or any external vector index
- Neo4j, Memgraph, or any external graph database
- Redis, RocksDB, LevelDB, or any external KV store
- libsqlite3, libpq, or any external RDBMS
- gRPC, Cap'n Proto, FlatBuffers, or any external RPC
- OpenCV, BLAS, LAPACK, or any external numerical library
- tokio, async-std, libuv, or any external async runtime
