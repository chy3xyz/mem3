# ADR-0002: GHW Layer ↔ Three-Source Mapping

**Status**: Accepted | **Date**: 2026-06-07 | **Authors**: Mavis (drafted from `ghw_memory_system.agent.final.md` §3.2)

## Context

The paper's `ghw_memory_system.agent.final.md` §3.2.1 establishes a formal mapping from 三源 (M/F/S) to GHW three layers (Goal/Harness/World):

> 性源的方向性转化为Goal层的目标生成
> 象源的表征力转化为Harness层的调控能力
> 物源的境域性转化为World层的世界建构

This gives:

| 三源 | GHW Layer | Function | Time scale |
|---|---|---|---|
| 性 (S) | Goal | 目标记忆、价值定向、元目标评估 | 周至年级 (slowest) |
| 象 (F) | Harness | 调控记忆、程序学习、元认知策略 | 毫秒至天级 (fastest) |
| 物 (M) | World | 世界模型、情境记忆、物理因果 | 分钟至月级 (mid) |

## Decision

We enforce the GHW three-layer architecture as three top-level source directories:

```
src/ghw/       → Goal + Harness + World (the "control plane" of GHW)
src/memory/    → 三源合恰 (the "data plane" of three sources)
src/hypermem/  → HyMem (the "storage plane" of hypergraph)
src/retrieval/ → Three-way recall (the "query plane")
src/storage/   → LSM + WAL (the "persistence plane")
```

Each file in `src/ghw/` MUST declare its layer in the file-level doc-comment:

```zig
//! GHW Layer: **Goal** (性源)
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
2. **Map 1:1 with the paper's `GHW Three-Layer Architecture` figure**. This is what we do, but with a refinement: the `src/memory/` directory (三源) is parallel to the GHW three layers, not a fourth layer. The data plane is orthogonal to the control plane.

## References

- `ghw_memory_system.agent.final.md` §3.2 (GHW three-layer mapping, time scales)
- `ghw_memory_system.agent.final.md` Table 2 (三源-三层 mapping)
- `.specify/memory/constitution.md` Principle II (GHW 三层耦合)
- `specs/001-trisource-everos-mvp/plan.md` §Project Structure
- `specs/001-trisource-everos-mvp/data-model.md` §Constitutional Mapping Table
