# ADR-0002: GHW Layer ↔ Three-Source Mapping

**Status**: Accepted | **Date**: 2026-06-07 | **Authors**: Mavis (drafted from `ghw_memory_system.agent.final.md` §3.2)

## Context

The paper's `ghw_memory_system.agent.final.md` §3.2.1 establishes a formal mapping from the three sources (M/F/S) to the GHW three layers (Goal/Harness/World). The paper is written in Chinese; the quotation below is translated:

> The directionality of the spirit source becomes goal generation in the Goal layer.
> The representational power of the form source becomes regulatory capacity in the Harness layer.
> The situatedness of the matter source becomes world construction in the World layer.

This gives:

| Source | GHW Layer | Function | Time scale |
|---|---|---|---|
| Spirit (S) | Goal | Goal memory, value orientation, meta-goal evaluation | Weeks to years (slowest) |
| Form (F) | Harness | Regulatory memory, procedural learning, meta-cognitive strategy | Milliseconds to days (fastest) |
| Matter (M) | World | World model, situated memory, physical causality | Minutes to months (mid) |

## Decision

We enforce the GHW three-layer architecture as three top-level source directories:

```
src/ghw/       → Goal + Harness + World (the "control plane" of GHW)
src/memory/    → Tri-source coherence (the "data plane" of the three sources)
src/hypermem/  → HyMem (the "storage plane" of hypergraph)
src/retrieval/ → Three-way recall (the "query plane")
src/storage/   → LSM + WAL (the "persistence plane")
```

Each file in `src/ghw/` MUST declare its layer in the file-level doc-comment:

```zig
//! GHW Layer: **Goal** (spirit source)
//! ...
```

Cross-layer calls MUST go through the GHW I/O interface in `src/ghw/ghw_io.zig`. Direct cross-layer access is a Constitution II violation requiring a written justification in the PR.

## Consequences

- **Positive**: The three-source ontology and the GHW three-layer architecture are aligned. A memory tagged Matter (M) lives primarily in the World layer; a memory tagged Spirit (S) lives primarily in the Goal layer; Form (F) is the Harness.
- **Positive**: Time-scale separation is enforced. Goal layer operations are slow and atomic (no high-frequency writes); Harness layer is fast and adaptive; World layer is mid-range and observation-driven.
- **Negative**: Adds ceremony. Every file needs a `//! GHW Layer: ...` comment. We accept this for clarity.
- **Negative**: Cross-layer communication requires the I/O interface, which adds a thin abstraction. We accept this for constitutional compliance.

## Alternatives Considered

1. **Single flat `src/` with no layer separation**. Rejected: violates Constitution II.
2. **Map 1:1 with the paper's `GHW Three-Layer Architecture` figure**. This is what we do, but with a refinement: the `src/memory/` directory (tri-source) is parallel to the GHW three layers, not a fourth layer. The data plane is orthogonal to the control plane.

## References

- `ghw_memory_system.agent.final.md` §3.2 (GHW three-layer mapping, time scales)
- `ghw_memory_system.agent.final.md` Table 2 (three-source to three-layer mapping)
- `.specify/memory/constitution.md` Principle II (GHW Three-Layer Coupling)
- `specs/001-trisource-everos-mvp/plan.md` §Project Structure
- `specs/001-trisource-everos-mvp/data-model.md` §Constitutional Mapping Table
