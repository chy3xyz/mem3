# ADR-0003: HNSW from Scratch (No FAISS)

**Status**: Accepted | **Date**: 2026-06-07 | **Authors**: Mavis (drafted from `dev.md` §3 + Constitution IV)

## Context

The system needs a vector index for the dense recall path (Constitution IV: zero-dep + Zig 0.17). The dominant open-source options are:
- **FAISS** (Facebook AI Similarity Search): C++ with Python bindings, transitive deps on BLAS/LAPACK/OpenMP, requires C++ ABI compatibility, ~100MB+ binary footprint.
- **HNSWlib**: header-only C++ with Python bindings, simpler than FAISS but still C++.
- **Qdrant / Milvus / Weaviate**: external services, network-attached, full server.
- **From-scratch implementation in Zig**: ~400 LOC for the core algorithm (per dev.md §3 estimates).

## Decision

Implement HNSW from scratch in Zig in `src/retrieval/hnsw.zig` (~400 LOC) and `src/retrieval/hnsw_persist.zig` (read/write `.idx` file). No external vector library.

The implementation MUST support:
- Insert: search from top layer, descend, insert at level 0, promote with probability `1/M`.
- Search: greedy descent from top, then ef-beam at level 0, return TopK by distance.
- Delete: mark node as deleted in the graph; periodic compaction (deferred to v0.2.0).
- Configurable `M` (max neighbors per node, default 16) and `ef_construction` (default 200) at build time; `ef_search` (default 100) at query time.
- Distance metric: cosine similarity (sufficient for the stub embedder's normalized hash vectors).

## Consequences

- **Positive**: Zero external runtime dependency. `ldd zig-out/bin/mem3` shows no FAISS / BLAS / OpenMP.
- **Positive**: Single binary, < 10MB.
- **Positive**: Cross-compiles cleanly to aarch64, wasm32 (theoretically; wasm32 deferred to v0.3.0).
- **Positive**: We can customize the algorithm for the paper's tri-source weight vectors (e.g., per-layer weighting by source_tag).
- **Negative**: ~400 LOC of code we have to maintain. Bugs in HNSW are subtle (recall regression, neighbor graph imbalance).
- **Negative**: No SIMD acceleration initially. v0.2.0 may add Zig @Vector intrinsics for the distance calc.
- **Mitigation**: Property tests in `tests/property/hnsw_props.zig` compare recall against a brute-force baseline at small N. Integration test `tests/integration/longmemeval_subset.zig` catches regressions at the application level.

## Alternatives Considered

1. **Use FAISS via C FFI**. Rejected: transitive C++ deps; binary size blows past 10MB; cross-compile to aarch64 is fragile.
2. **Use HNSWlib via C FFI**. Rejected: same issues, plus the C++ template metaprogramming makes `linkSystemLibrary` a leaky abstraction.
3. **Use a pure Zig HNSW library** (e.g., `zig-hnsw` if it exists). None mature enough at the time of writing; we will revisit in v0.2.0.
4. **Skip HNSW and use a flat brute-force index**. Rejected: O(N) per query is unusable at 100K+ corpus.

## References

- `dev.md` §3 (Zig 0.17 std.Io and HNSW strategy)
- `ghw_memory_system.agent.final.md` §4.2.2 (HNSW usage)
- `.specify/memory/constitution.md` Principle IV (Zero-Dependency)
- `.specify/memory/constitution.md` §Performance Standards (HNSW build < 30s for 100K)
