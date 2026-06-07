# Implementation Plan: TriSource-EverOS MVP

**Branch**: `001-trisource-everos-mvp` | **Date**: 2026-06-07 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-trisource-everos-mvp/spec.md`

## Summary

Build the **MVP slice** of TriSource-EverOS: a zero-dependency Zig 0.17 memory operating system that stores every memory as a `TS-MemCell` 7-tuple tagged with one of three ontological sources (物/象/性), organized in a hypergraph (`HyMem`), indexed via a from-scratch HNSW + KV + graph three-way recall, scored with GHW-prioritized ranking, and driven by existence-gain-dynamics for consolidation and forgetting. Ships as a single ~10MB binary with a CLI and an HTTP daemon, all four lifecycle stages end-to-end, all three constitution invariants testable, and the full project skeleton (per `dev.md` §三) compilable on Zig 0.17-dev.

The technical approach is locked to:
- **Zig 0.17 (dev branch ≥ 0.17.0-dev.3000)** with `std.Io` async, `comptime` metaprogramming, explicit allocator injection.
- **No external dependencies** — HNSW, LSM-tree, hypergraph, KV, WAL all in-tree.
- **WAL-first persistence** with periodic snapshot for fast restart.
- **Single-process, single-binary** deployment model.

## Technical Context

**Language/Version**: Zig 0.17.0-dev.3000+ (pinned in `build.zig.zon`)

**Primary Dependencies**: **NONE at runtime.** Build-time: the Zig compiler itself. Optional: a Python 3 harness for the `bench/` scripts (purely dev tooling, not shipped).

**Storage**:
- In-memory primary store: `std.AutoHashMap` for KV, `std.ArrayList` for HNSW layers, hypergraph nodes/edges as parallel arrays.
- On-disk WAL: append-only `wal.log` with periodic snapshot `state.snap` for fast cold start.
- File layout under `data/` (configurable via `--data-dir`):
  - `memcells.bin` — MemCell records (post-snapshot)
  - `hyperedges.bin` — hypergraph edges
  - `kv.idx` — id → offset index
  - `hnsw.idx` — HNSW graph
  - `goal_poset.bin` — goal nodes
  - `wal.log` — append-only write-ahead log

**Testing**: Zig's built-in `test` blocks (`zig build test`). Property-based tests in `tests/property/` for hypergraph invariants. Constitution invariants in `tests/constitution/`. Performance benchmarks in `bench/`.

**Target Platform**: macOS (M1+), Linux x86_64/aarch64. WASM32 is a stretch goal (FR-024) but not release-blocking for v0.1.0-alpha.

**Project Type**: Single CLI binary with embedded HTTP daemon (multi-target: one `mem3` binary that can run as CLI tool or `serve` mode).

**Performance Goals** (from Constitution §Performance Standards):
- MemCell write: ≥ 10K/sec (release-blocking) / 1K/sec (MVP gate)
- Top-10 query P95: < 10ms (release) / < 50ms (MVP) at 100K corpus
- HNSW build: 100K vectors < 30s
- Multi-hop 3-hop: < 5ms for 1K seeds
- Cold-start: < 200ms
- Footprint: < 500MB RSS for 100K MemCells
- Binary size: < 10MB stripped

**Constraints**:
- Zero external runtime libraries (verified by `ldd`)
- No GC, no hidden allocations
- No `anytype` reflection at runtime
- Long-running daemon: silent stdout by default, log rotation external (`logrotate`/`newsyslog`)
- Single-process: no IPC, no shared state across processes

**Scale/Scope**:
- Solo developer scale for v0.1.0-alpha: 100K–1M MemCells, single user, single machine.
- Distributed scale deferred to v0.4.0+.

## Constitution Check

*Gate: must pass before implementation. Re-check after each Phase.*

| Principle | Compliance Plan |
|---|---|
| I. 三源完整性 | TS-MemCell struct has all 7 fields; source_tag enforced at type level; constitution test in `tests/constitution/source_tag.zig` |
| II. GHW 三层耦合 | Three top-level directories `src/ghw/`, `src/memory/`, `src/hypermem/` map to Goal/Harness/World; file-level doc-comments declare layer |
| III. 存在增益驱动 | `src/memory/lifecycle.zig` implements the four stages with existence-gain scoring; fuzzy store in `src/memory/fuzzy.zig` |
| IV. 零依赖 + Zig 0.17 | `build.zig` has zero `linkSystemLibrary` calls (except libc/compiler-rt which Zig pulls in by default and `ldd`-clean); CI step runs `ldd` and fails on new deps |
| V. 零拷贝 + 编译时零开销 | `src/utils/serializer.zig` uses `comptime` codegen; all public types have `pub comptime serialized_size: usize` |
| VI. 测试优先 | Tests in `tests/` for every module; `tests/constitution/` for the three invariants; CI runs `zig build test` + `zig build bench` |
| VII. 可观测性 | `src/utils/logger.zig` provides `std.log.scoped` wrappers with JSONL mode; `--log-every N` flag; `/metrics` endpoint in HTTP mode |

All 7 principles are addressable in code. **No violations require justification.**

## Project Structure

### Documentation (this feature)

```text
specs/001-trisource-everos-mvp/
├── plan.md              # This file
├── spec.md              # The feature specification
├── data-model.md        # TS-MemCell, HyMem, Goal Poset formal models
├── quickstart.md        # 10-minute onboarding for new contributors
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Generated by tasks phase
```

### Source Code (repository root)

The structure follows `dev.md` §三 with adaptations for spec-kit:

```text
mem3/
├── build.zig            # Zig 0.17 build script
├── build.zig.zon        # Dependency manifest (zero deps)
├── README.md
├── AGENTS.md            # Agent onboarding (consumed by OpenCode/Codex/Cursor)
├── .gitignore
├── .specify/            # spec-kit scaffolding (do not edit manually)
├── dev.md               # Engineering blueprint (reference)
├── ghw_memory_system.agent.final.md  # Formal paper (reference)
├── data/                # Runtime data dir (gitignored)
│   ├── memcells.bin
│   ├── hyperedges.bin
│   ├── kv.idx
│   ├── hnsw.idx
│   ├── goal_poset.bin
│   └── wal.log
├── src/
│   ├── main.zig                 # Entry point: CLI dispatch
│   ├── cli.zig                  # CLI parsing (--help, --json, --log-every, ...)
│   ├── cli_commands/
│   │   ├── add.zig              # mem3 add <cell>
│   │   ├── query.zig            # mem3 query <text>
│   │   ├── goal.zig             # mem3 goal add/list/delete
│   │   ├── dump.zig             # mem3 dump --out state.json
│   │   ├── inspect.zig          # mem3 inspect --id <n>
│   │   ├── bench.zig            # mem3 bench
│   │   ├── serve.zig            # mem3 serve --port N
│   │   ├── consolidate.zig      # mem3 consolidate
│   │   └── forget.zig           # mem3 forget --threshold
│   ├── core/                    # GHW L1 基础层
│   │   ├── memcell.zig          # TS-MemCell struct + source_tag
│   │   ├── fact.zig             # Fact struct (subject, predicate, object)
│   │   ├── foresight.zig        # Foresight struct (with valid_from/until)
│   │   ├── goal_association.zig # GoalAssociation struct
│   │   ├── metadata.zig         # Metadata struct
│   │   ├── types.zig            # Common enums (EdgeType, GoalStatus)
│   │   └── errors.zig           # Tagged error unions
│   ├── ghw/                     # GHW L2 - GHW 三层
│   │   ├── goal_tree.zig        # Goal Poset (G = (Obj, ≤_goal, ⊥, ⊤))
│   │   ├── harness_registry.zig # Harness registry
│   │   ├── world_model.zig      # World entity model
│   │   └── ghw_io.zig           # Layer I/O interface
│   ├── memory/                  # GHW L3 - 三源合恰
│   │   ├── tri_source_manager.zig  # Tri-Source Memory Manager
│   │   ├── lifecycle.zig           # 4 stages: Encode/Consolidate/Recall/Forget
│   │   ├── encoder.zig             # Encoding pipeline
│   │   ├── consolidator.zig        # MemScene clustering (HAC)
│   │   ├── forgetter.zig           # Existence-gain-driven forgetting
│   │   ├── fuzzy.zig               # Fuzzy memory store
│   │   └── coherence.zig           # Tri-source coherence calculator
│   ├── hypermem/                # GHW L4 - 超图引擎
│   │   ├── engine.zig              # HyMem core
│   │   ├── hyperedge.zig           # HyperEdge struct
│   │   ├── node.zig                # MemCell node wrapper
│   │   ├── multi_hop.zig           # Multi-hop traversal
│   │   ├── msg_passing.zig         # Embedding propagation
│   │   └── graph_index.zig         # Adjacency list + neighbor query
│   ├── retrieval/               # GHW L4 - 检索
│   │   ├── hnsw.zig                # HNSW index (from scratch, ~400 LOC)
│   │   ├── hnsw_node.zig           # HNSW node + layer
│   │   ├── hnsw_search.zig         # Search with ef parameter
│   │   ├── kv_index.zig            # Exact-match KV
│   │   ├── keyword.zig             # BM25 keyword retrieval
│   │   ├── hybrid_retriever.zig    # Three-way recall fusion
│   │   ├── reranker.zig            # GHW-prioritized rerank
│   │   └── embedder.zig            # Stub deterministic embedder (v0.1)
│   ├── storage/                 # GHW L4 - 存储
│   │   ├── lsm_store.zig           # Log-structured memtable
│   │   ├── sstable.zig             # Sorted-string-table on disk
│   │   ├── wal.zig                 # Write-ahead log
│   │   ├── snapshot.zig            # Periodic snapshot writer/reader
│   │   └── index_manager.zig       # Master index coordination
│   ├── server/                  # HTTP daemon
│   │   ├── http_server.zig         # std.Io-based HTTP/1.1 server
│   │   ├── routes.zig              # Route table
│   │   ├── handlers/
│   │   │   ├── memcells.zig        # POST/GET /memcells
│   │   │   ├── query.zig           # POST /query
│   │   │   ├── goals.zig           # GET/POST /goals
│   │   │   ├── metrics.zig         # GET /metrics (Prometheus)
│   │   │   └── healthz.zig         # GET /healthz
│   │   └── middleware.zig         # JSON body parsing, error handling
│   └── utils/                   # Cross-cutting utilities
│       ├── serializer.zig          # comptime-zero-overhead serialize/deserialize
│       ├── allocator.zig           # Arena + page-pool allocators
│       ├── time.zig                # Unix timestamps, decay
│       ├── logger.zig              # std.log.scoped + JSONL
│       ├── jsonl.zig               # JSON line parser (for CLI --json)
│       └── hashing.zig             # xxHash for embedder stub
├── tests/
│   ├── test_memcell.zig           # Unit: TS-MemCell struct invariants
│   ├── test_fact.zig              # Unit: Fact serialization
│   ├── test_ghw.zig               # Unit: Goal tree, Harness, World
│   ├── test_tri_source.zig        # Unit: TriSourceManager
│   ├── test_lifecycle.zig         # Unit: 4-stage lifecycle
│   ├── test_hypermem.zig          # Unit: hypergraph invariants
│   ├── test_hnsw.zig              # Unit: HNSW build/search/delete
│   ├── test_hybrid_retriever.zig  # Unit: three-way recall
│   ├── test_forgetter.zig         # Unit: existence-gain scoring
│   ├── test_wal.zig               # Unit: WAL replay
│   ├── test_snapshot.zig          # Unit: snapshot roundtrip
│   ├── test_http.zig              # Integration: HTTP routes
│   ├── test_cli.zig               # Integration: CLI subcommands
│   ├── property/
│   │   ├── hypergraph_props.zig   # Property: no duplicate edges
│   │   ├── coherence_props.zig    # Property: C_tri ∈ [0, 1]
│   │   └── encoding_props.zig     # Property: roundtrip preserves fields
│   ├── constitution/
│   │   ├── source_tag.zig         # Invariant 1: every cell has source_tag
│   │   ├── spirit_dim.zig         # Invariant 2: spirit present
│   │   └── goal_coverage.zig      # Invariant 3: goal coverage
│   ├── integration/
│   │   ├── end_to_end.zig         # Full lifecycle on 100 cells
│   │   ├── longmemeval_subset.zig # Subset of LongMemEval benchmark
│   │   └── cross_source_query.zig # US1 scenario 2 test
│   └── fixtures/
│       └── corpus.json            # Hand-crafted 100-cell fixture
├── bench/
│   ├── throughput.zig             # MemCell write throughput
│   ├── retrieval_p95.zig          # Three-way recall P95
│   ├── hnsw_build.zig             # 100K HNSW build time
│   ├── multihop.zig               # 3-hop traversal
│   ├── cold_start.zig             # Binary launch → ready
│   ├── footprint.zig              # RSS at 100K cells
│   └── report.zig                 # Aggregate JSON output
├── examples/
│   ├── notebook.zig               # US1 demo: researcher's notebook
│   ├── multi_project.zig          # US2 demo: goal-aware
│   └── multihop_query.zig         # US3 demo: 3-hop reasoning
└── docs/
    ├── roadmap.md                 # v0.2+ features
    ├── constitution-amendments/   # Amendment log
    └── adr/                       # Architecture Decision Records
        ├── 0001-three-source-ontology.md
        ├── 0002-ghw-mapping.md
        ├── 0003-hnsw-from-scratch.md
        └── 0004-wal-first-persistence.md
```

**Structure Decision**: Single-project layout (not the multi-project web/frontend/mobile options in the template). This is a CLI + embedded HTTP server, single binary, single team. The `src/` mirror mirrors the GHW five-layer architecture from `dev.md` §1.2.

## Complexity Tracking

> **No Constitution violations require justification.** All 7 principles are met by the design above.

| Decision | Simpler Alternative Rejected | Reason |
|---|---|---|
| Implement HNSW from scratch | Use FAISS / hnswlib | Zero-dep Principle IV; FAISS is C++ with many transitive deps |
| Implement hypergraph in-tree | Use Neo4j / Memgraph | Zero-dep; hypergraph is just adjacency arrays + a few graph algos |
| Implement WAL + snapshot | Use RocksDB / SQLite | Zero-dep; WAL is ~150 LOC and gives us explicit control over the format |
| Zig comptime serialization | Use `std.json` (runtime reflection) | Comptime is faster and avoids the 0.11 → 0.17 std.json API churn |
| Stub deterministic embedder | Integrate a real ONNX model | Out of v0.1.0-alpha scope (deferred to v0.2.0); the stub is a unit-testable deterministic function that lets the rest of the system be tested without an ML model |

## Phase 0: Research Outcomes

Research is folded into this plan since the foundation papers (三源合恰论.docx, dev.md, ghw_memory_system.agent.final.md) are already in-tree. No additional web research needed for the MVP.

Key research conclusions that shaped the plan:

1. **Zig 0.17 std.Io semantics**: confirmed via `.mcp-zero` prior work and `ghw/` parallel project. Pattern: `std.Io.Threaded.init(alloc, .{}).io()` for thread-safe shared Io, `std.Io.Mutex` for shared state, async file ops with `file.pwriteAll(io, ...)`.
2. **HNSW in Zig**: prior implementations in `ghw/` show ~400 LOC is feasible; we lift that pattern.
3. **Hypergraph storage**: adjacency-list-of-arrays beats CSR for incremental writes; CSR is used only at snapshot time.
4. **Existence-gain dynamics**: the formula `α·source_coherence + β·goal_relevance + γ·existential_contribution` with α=0.30, β=0.40, γ=0.30 is directly from `ghw_memory_system.agent.final.md` §4.1.4.
5. **Tri-source coherence**: `C_tri = C_MF · C_FS · C_SM` per the paper. Implemented as cosine-similarity product.

## Phase 1: Design Outputs

### Data Model

See `data-model.md` in this directory for the full type definitions, valid-state invariants, and storage mappings.

Highlights:
- `TS-MemCell` is a fixed-layout struct with `comptime serialized_size: usize` for zero-overhead I/O.
- `HyperEdge` carries a three-source weight vector `(w_M, w_F, w_S)` summing to 1.
- `GoalNode` is a node in a partial order (parent_id creates the lattice; priority breaks ties).
- `WALRecord` is a tagged union: `MemcellInsert`, `MemcellUpdate`, `HyperedgeAdd`, `GoalCreate`, `GoalUpdate`, `Forget`.

### Quickstart

See `quickstart.md` in this directory. A new contributor should be able to:
1. `git clone`, `zig build` (one binary appears in `zig-out/bin/mem3`).
2. `mem3 add --source=matter --episode "hello" --facts "test,works"` — see `id=1`.
3. `mem3 query "hello" --topk=5` — see `id=1` in the results.
4. `mem3 serve --port 7777` — start the daemon.
5. `curl http://127.0.0.1:7777/healthz` — see `200 OK`.

### Contracts (API Surface)

CLI contract (per FR-016):
- `mem3 add --source={matter|form|spirit} --episode <text> --facts 's|p|o,s|p|o' [--foresight 'desc|valid_from|valid_until|conf'] [--goal-ids 1,2 --relevances 0.8,0.5]`
- `mem3 query <text> [--topk 10] [--source-filter M,F,S] [--goal-ids 1,2] [--max-hops 3]`
- `mem3 goal add --name <text> [--priority 0-255] [--parent-id <n>]`
- `mem3 dump --out <path.jsonl>`
- `mem3 inspect --id <n>`
- `mem3 bench [--filter <pattern>] [--out bench.json]`
- `mem3 serve --port <N> [--bind <addr>] [--data-dir <path>]`
- `mem3 consolidate [--threshold <f32>]`
- `mem3 forget [--threshold <f32>] [--dry-run]`

HTTP contract (per FR-017):
- `POST /memcells` body: `{"source":"matter","episode":"...","atomic_facts":[{...}],"foresight":[{...}],"goal_associations":[{...}]}` → `201 {"id":<n>}`
- `GET /memcells/{id}` → `200 {TS-MemCell JSON}` / `404`
- `POST /query` body: `{"text":"...","topk":10,...}` → `200 [{...MemCell JSON, "score":0.87}, ...]`
- `GET /goals` → `200 [{GoalNode JSON}, ...]`
- `POST /goals` body: `{"name":"...","priority":9}` → `201 {"id":<n>}`
- `GET /metrics` → `200 Prometheus text format`
- `GET /healthz` → `200 {"status":"ok","uptime_s":<n>,"memcell_count":<n>}`

JSON serialization uses the same `comptime` codegen as binary (a different back-end). Schema version: `1.0.0` (in HTTP `Server: mem3/1.0.0` header).

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Zig 0.17 std.Io API churn between dev snapshots | High | High | Pin to a specific dev commit in `build.zig.zon`; document the pin in `README.md` |
| HNSW correctness bugs (recall regression) | Medium | High | Property tests vs a reference implementation; `tests/integration/longmemeval_subset.zig` catches regressions |
| Hypergraph memory blow-up at 1M+ MemCells | Medium | Medium | Plan CSR compaction at snapshot time; in-memory limits are 100K for v0.1.0-alpha |
| Long-running daemon log file growth | Medium | Medium | Silent by default + external logrotate; `tests/integration/long_run.zig` verifies 24h simulated run stays bounded |
| Forgotten memories "leak" via hyperedges | Low | High | Forgetter removes edges in the same WAL transaction as the fuzzy-store move |
| Single-process is a blocker for v0.4.0 distributed work | Low | Low | Defer; design WAL format with multi-writer in mind (record ids are monotonic) |

## Out-of-Scope Reminder (v0.1.0-alpha)

Distributed, embedding model, WASM32 async, GUI — all deferred per spec §Non-Goals.
