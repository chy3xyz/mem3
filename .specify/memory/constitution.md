# TriSource-EverOS Constitution
<!-- Project: mem3 = TriSource-EverOS, the memory OS based on 三源合恰论 + GHW 范式 -->

## Core Principles

### I. 三源完整性 (Tri-Source Integrity, NON-NEGOTIABLE)

Every memory unit MUST carry the three ontological sources — **物 (Matter, M)**, **象 (Form, F)**, **性 (Spirit, S)** — in some form. The atomic memory primitive `TS-MemCell` is a 7-tuple ⟨id, source_tag, episode, atomic_facts, foresight, goal_associations, metadata⟩ where:

- `episode` carries the **物 (matter)** substrate — the raw, causally efficacious trace.
- `atomic_facts` carries the **象 (form)** structure — extractable, computable information.
- `foresight` and `goal_associations` carry the **性 (spirit)** direction — meaning, purpose, value-bearance.
- `source_tag ∈ {M, F, S}` is a hard guarantee that no memory can be tagged as "untyped": a memory is always traceable to its primary ontological source. Mixed-source memories are explicitly typed with a dominant tag + a coherence vector.
- `metadata.importance_score = α·source_coherence + β·goal_relevance + γ·existential_contribution` (default α=0.30, β=0.40, γ=0.30). A memory whose three sources cannot be reconstructed MUST be rejected at encoding time.

**Rationale**: 三源合恰论 (Tri-Source Con-appropriation Theory) defines 物/象/性 as irreducible — collapsing any source into another creates an *existential collapse* (存在坍缩). The system is not a "memory store"; it is an existential event in time.

### II. GHW 三层耦合 (Goal-Harness-World, NON-NEGOTIABLE)

All memory operations MUST be addressable within the three-layer GHW architecture:

- **Goal 层 (性源)**: target memory, value-direction, meta-goal evaluation. Time-scale: weeks to years. Slowest, most stable.
- **Harness 层 (象源)**: regulatory memory, procedural learning, meta-cognition. Time-scale: ms to days. Fastest, most adaptive.
- **World 层 (物源)**: world model, situated memory, physical causality. Time-scale: minutes to months. Mid-range.

The three layers communicate via **双向通演 (Bi-Directional Transduction)**:
- **外拓之路 (encoding)**: Goal → Harness → World — what is worth remembering is decided at the Goal layer, formatted at the Harness layer, written into physical substrate at the World layer.
- **内求之路 (retrieval)**: World → Harness → Goal — physical traces activate, information is reconstructed, meaning is bestowed in the present.

A module MUST declare which GHW layer it belongs to in its file-level doc-comment. Cross-layer access bypasses the natural transduction and is a constitutional violation requiring a written justification.

### III. 存在增益驱动 (Existence-Gain-Driven Lifecycle, NON-NEGOTIABLE)

The four memory operations — **编码 (Encoding)**, **巩固 (Consolidation)**, **回忆 (Recollection)**, **遗忘 (Forgetting)** — MUST be driven by the **存在增益 (Ontological Enhancement)** metric, not by capacity or TTL:

- **PMOE (Principle of Maximal Ontological Enhancement)**: prioritize consolidation of memories that maximize three-source coherence, create new con-appropriation possibilities, or promote others' con-appropriation.
- **PCR (Principle of Con-appropriation Respect)**: conflicts are resolved by adding temporal-validity markers, NEVER by deletion. Old facts stay, marked as superseded.
- **Decay asymmetry**: λ_matter > λ_form > λ_spirit > 0. Matter fades fastest (episodic detail blur), form decays mid-rate (organizational loosening), spirit lasts longest (meaning persistence). This mirrors the cognitive asymmetry "情节细节遗忘快、意义框架遗忘慢".
- **Forgetting threshold**: a memory is forgotten when its net_existence = importance − redundancy − conflict_score < 0, or when importance < θ_e and age > AGE_THRESHOLD. Memories with spirit_coherence > 0.7 are archived to the "fuzzy store" (模糊记忆区) rather than deleted.

**Rationale**: Forgetting is not failure, it is 合恰 maintenance. A system that retains everything is a system that has lost its grip on what matters.

### IV. 零依赖 + Zig 0.17 原生 (Zero-Dependency Zig 0.17 Native)

The system MUST be a **single binary, zero external runtime dependency** implementation:

- Language: **Zig 0.17 (dev branch, ≥ 0.17.0-dev.3000)**, no C/C++/Rust interop at runtime.
- **NO** external vector libraries (FAISS, HNSWlib), graph databases (Neo4j, Memgraph), KV stores (Redis, RocksDB), or RPC frameworks. HNSW, hypergraph, LSM-tree, and KV indexes are all implemented from scratch in Zig.
- Build target: `zig build` produces ONE binary, < 10MB, runnable on **macOS and Linux** with no `LD_LIBRARY_PATH` or service dependencies.
- Cross-compile: `zig build -Dtarget=x86_64-linux-gnu` and `-Dtarget=aarch64-linux-gnu` must work without an external cross-toolchain. Both are verified.
- **Windows is not supported**, and `src/platform/fs.zig` refuses the target at compile time with a stated reason. The HTTP daemon binds raw POSIX sockets and uses a `pthread_mutex_t`; Windows needs a Winsock port. The library, CLI and benchmarks were ported and cross-compiled, then withdrawn — see `docs/constitution-amendments/2026-10-14-platform-scope.md`.
- **WASM32 is not supported** (deferred to v0.3.0; see Scope Boundaries). It is refused at compile time with a stated reason rather than failing incidentally.
- Async I/O: the daemon uses a single background maintenance thread with libc `pthread` primitives and `clock_gettime`. This is a deliberate departure from an earlier draft of this principle that named `std.Io`; the amendment above is the rationale for the current shape. No thread-pool wrappers, no callback colour.
- All serialization MUST be implemented via `comptime` metaprogramming — no runtime reflection.

**Rationale**: The existential structure of memory is unified; splitting it across multiple services breaks the three-source coherence. Single-binary deployment also makes the system embedded-friendly and edge-deployable.

### V. 零拷贝 + 编译时零开销 (Zero-Copy + Comptime Zero-Overhead)

Performance is a constitutional requirement, not an optimization:

- Serialization: **`comptime` generated** per-type, no `anytype` reflection at runtime. Size pre-computed via `comptime serialized_size: usize`.
- Memory allocation: **explicit allocator injection**. No hidden allocations in hot paths. Arenas for batch work, page-level for indexes, bump allocators for transient serialization.
- Hypergraph adjacency: `std.ArrayList(u64)` in continuous memory regions for cache-friendliness. No per-edge heap allocation.
- HNSW index: ~400 LOC core, in-memory with optional mmap for persistence.
- Async I/O: every `pwrite`/`pread` uses `std.Io` futures, no thread spawn per request.

Benchmarks: P95 retrieval latency < 10ms for 100K memories; 5–10× faster than equivalent Go/Python implementations. These are release-blocking.

### VI. 测试优先 + 形式化保证 (Test-First + Formal Guarantees)

Every non-trivial module MUST have tests written BEFORE implementation:

- **Unit tests** for each public type and function, using Zig's built-in `test` blocks.
- **Property tests** for hypergraph invariants (no duplicate edges, all node references valid, source_tag consistency).
- **Integration tests** for the four lifecycle stages end-to-end.
- **Category-theoretic sanity checks** for adjoint pairs: `Encode` ∘ `Decode` ≈ `id` (left adjoint), `Decode` ∘ `Encode` ≤ `id` (right adjoint approximation).
- **Constitution tests** in `tests/constitution/` that assert the three invariants: (a) every MemCell has a non-null source_tag, (b) every MemCell has ≥ 1 foresight OR ≥ 1 goal_association (spirit dimension is present), (c) every goal in the Goal Poset has ≥ 1 associated MemCell OR is marked `unrealized`.

Code coverage target ≥ 80% for core modules, ≥ 60% for utilities. **Critical-path modules** (HyperMem, TriSourceManager, HybridRetriever) MUST have 100% line coverage.

### VII. 可观测性 + 单二进制调试 (Observability + Single-Binary Debugging)

The system is embedded-friendly, so observability is constitutional, not optional:

- **Structured logging** via `std.log.scoped`, JSONL output mode for production (`--log-format=jsonl`), human-readable for dev.
- **No stdout pollution in long-running mode** (per dev.md lessons-learned: silent by default, `--log-every N` for periodic summaries, `--verbose` for full tracing).
- **Prometheus-style metrics endpoint** at `/metrics` (HTTP mode) for the daemon — request count, retrieval P50/P95/P99, memstore size, vector index depth, hyperedge count, forgetting rate.
- **Snapshot/dump commands**: `mem3 dump --out state.json` writes the full memory store for debugging. `mem3 inspect --id <n>` shows the MemCell + its hypergraph neighborhood.

## Performance Standards

These are **release-blocking** quantitative criteria:

| Metric | Target | Measurement |
|---|---|---|
| MemCell write throughput | ≥ 10K MemCells/sec (sustained) | `bench/throughput.zig` |
| Three-way recall TopK=10 P95 | < 10ms at 100K corpus | `bench/retrieval_p95.zig` |
| HNSW index build | 100K vectors in < 30s on M1 | `bench/hnsw_build.zig` |
| Multi-hop traversal (3 hops) | < 5ms for 1K seeds | `bench/multihop.zig` |
| Cold-start (binary launch → ready) | < 200ms | `bench/cold_start.zig` |
| Memory footprint (100K MemCells) | < 500MB RSS | `bench/footprint.zig` |
| Single-binary size | < 10MB stripped | `wc -c build/mem3` |
| End-to-end on LongMemEval | ≥ 80% accuracy (vs EverOS baseline 83%) | `bench/longmemeval.zig` |

Targets are aspirational for v0.1.0-alpha; the v0.2.0-mvp gate is P95 < 50ms, write 1K/s, 100K corpus < 1GB.

## API Surface Standards

All public APIs MUST follow these contracts:

- **Error handling**: tagged unions (`!T`), never `null` for fallible operations. Use `std.posix.ENOENT`-style error names, not magic integers.
- **Memory ownership**: explicit `Allocator` parameter on every allocation. No hidden global allocator.
- **Naming**: Zig idiomatic — `snake_case` for functions, `PascalCase` for types, `SCREAMING_SNAKE_CASE` for constants. Domain terms (MemCell, GHW, HyMem) keep their natural casing.
- **No panics in libraries**. `unreachable` only for provably-impossible branches with a `// SAFETY: ...` comment.
- **No allocator state in globals**. Pass `Io` runtime explicitly to all async functions (Zig 0.17 idiom).

## Development Workflow

1. **Spec-first**: every feature MUST have a spec.md update before code. Spec changes require constitution review.
2. **Constitution check on every PR**: a CI step verifies:
   - All new MemCells pass the constitution tests (source_tag + foresight/goal).
   - No `std.ArrayList(T).init(allocator)` with a hidden allocator.
   - No new external dependency added.
   - Benchmark gates (P95, throughput) are not regressed.
3. **Commit message format**: `type(scope): subject`, e.g. `feat(hypermem): implement hyperedge multi-hop traversal`, `fix(serializer): correct string slice handling for nested structs`.
4. **Branch strategy**: main = stable, `###-feature-name` = feature branches per spec-kit convention. Version tags `vX.Y.Z` use semver with the following mapping:
   - MAJOR: constitution-amendment-level changes (breaking three-source or GHW semantics).
   - MINOR: new lifecycle stage, new retrieval mode, new top-level module.
   - PATCH: bug fixes, performance improvements, internal refactors.

## Scope Boundaries (v0.1.0-alpha)

**In scope**:
- TS-MemCell + HyMem + three-way recall + four-stage lifecycle
- Zig 0.17 native, single-binary, zero-dep
- CLI: `mem3 add`, `mem3 query`, `mem3 dump`, `mem3 inspect`, `mem3 bench`
- HTTP daemon: `mem3 serve --port 7777` with REST endpoints
- Local file persistence: `data/{memcells.idx, hyperedges.idx, kv.idx, hnsw.idx, wal.log}`

**Out of scope for v0.1.0-alpha** (tracked in `docs/roadmap.md`):
- Distributed consensus (Raft) — v0.4.0
- Distributed vector index sharding — v0.4.0
- LLM embedding model integration (use a stub or bring-your-own) — v0.2.0
- WASM32 target with full async — v0.3.0
- Windows daemon (Winsock port) — v0.4.0; the library and CLI already cross-compile, see `docs/constitution-amendments/2026-10-14-platform-scope.md`
- Embedding model fine-tuning — out of scope, defer to follow-up
- GUI / Web UI — v0.5.0

## Governance

- **Constitution supersedes** all other practices, READMEs, and architectural documents. In case of conflict, constitution wins.
- **Amendments** require: (1) a written rationale in `docs/constitution-amendments/YYYY-MM-NN.md`, (2) a sync-impact report identifying all dependent docs to update, (3) a version bump per semver rules.
- **Compliance review** runs on every PR via the `constitution-check` CI step and on every release via a manual sign-off.
- **Complexity justification**: any module that violates Principles IV (zero-dep) or V (zero-overhead) MUST include a `## Complexity Justification` section in its spec explaining the simpler alternative that was rejected and why.
- **Reference docs**:
  - `dev.md` — full engineering blueprint (Zig 0.17 idioms, type sketches, 12-week roadmap).
  - `ghw_memory_system.agent.final.md` — formal theoretical paper (TS-MemCell proof, GHW mapping theorem, category-theoretic semantics, existence-gain dynamics).
  - `三源合恰论.docx` — foundational ontology (物/象/性 definition, 互根律, 双向通演法, 合恰 dynamics).
  - `.specify/memory/constitution.md` — this file.
  - `AGENTS.md` (root) — agent onboarding.

**Version**: 1.1.0 | **Ratified**: 2026-06-07 | **Last Amended**: 2026-10-14
<!-- v1.1.0: Principle IV platform scope corrected to macOS + Linux. Windows and
     WASM32 are now explicitly unsupported and refused at compile time with a
     stated reason. The previous claim of Windows/WASM support was never true and
     a document that declares itself supreme must not carry unmet claims.
     Rationale and sync-impact: docs/constitution-amendments/2026-10-14-platform-scope.md -->
<!-- v1.0.0: initial ratification. No prior version. -->
