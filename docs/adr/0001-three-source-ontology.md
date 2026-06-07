# ADR-0001: Three-Source Ontology as Canonical `source_tag`

**Status**: Accepted | **Date**: 2026-06-07 | **Authors**: Mavis (drafted from `dev.md` + `ghw_memory_system.agent.final.md`)

## Context

Two reference documents use different taxonomies for memory sources:

- **`ghw_memory_system.agent.final.md` §4.1.2** uses `{M, F, S}` = {物 (Matter), 象 (Form), 性 (Spirit)} as the *canonical* source taxonomy. This is rooted in 三源合恰论.
- **`dev.md` §2.2.1** uses `{sensory, cognitive, action}` as the source taxonomy. This is rooted in cognitive activity types (input, reasoning, behavior).

The two are not contradictory, but they are not identical either:

| Paper's `source_tag` | `dev.md`'s source | Cognitive activity | Example |
|---|---|---|---|
| Matter (M) | sensory | 感知: 感官输入、环境观测 | "user said: 'how do I use Zig?'" |
| Form (F) | cognitive | 认知: 推理、反思、抽象 | "I derived that Zig 0.17 replaces std.fs" |
| Spirit (S) | action | 行动: 工具调用、执行结果 | "I ran `zig build` and it compiled in 4s" |

The misalignment: `dev.md` puts *action/execution* under the third source, but the paper puts *meaning/value-direction* under the third source (性). The paper's `goal_associations` and `foresight` are explicitly the 性 (spirit) dimension, NOT the action dimension.

## Decision

We adopt the **paper's `M/F/S` taxonomy** as the canonical `source_tag` on `TS-MemCell`. The `dev.md` `sensory/cognitive/action` naming is preserved as a **secondary classification** stored in `metadata.activity_subtype ∈ {perception, cognition, action, reflection}`.

The default mapping is:

| `source_tag` | Default `activity_subtype` | Notes |
|---|---|---|
| Matter (M) | perception | 感官 / 工具返回的原始数据 |
| Form (F) | cognition | 推理 / 反思 / 抽象知识 |
| Spirit (S) | action (for *behavioral* spirit) or reflection (for *meta-cognitive* spirit) | 行动 vs 反思: 行为轨迹 vs 元认知 |

The Source Classifier (when implemented in v0.2.0 with an LLM) MUST set both fields. For the v0.1.0-alpha stub, the user explicitly sets `source_tag` via `--source=matter|form|spirit` and `activity_subtype` is inferred or default.

## Consequences

- **Positive**: Aligns the implementation with the formal paper's theoretical scaffolding. The category-theoretic semantics (paper §5) cleanly map to M/F/S.
- **Positive**: Constitution Principle I (三源完整性) is unambiguous: a memory is 物/象/性-tagged, period.
- **Negative**: Adds a `metadata.activity_subtype` field that is not in the paper. This is a small extension; the paper's `source_tag` is the primary classification, the subtype is auxiliary.
- **Negative**: The default mapping for `Spirit` is ambiguous (action vs reflection). Resolved by the weight ordering `w_reflection > w_cognition > w_action > w_perception` from the paper: reflection dominates when present.

## Alternatives Considered

1. **Use `dev.md`'s `sensory/cognitive/action` taxonomy as canonical**. Rejected: this is an activity classification, not an ontological classification. It conflicts with the paper's category-theoretic semantics.
2. **Use both as parallel enums (`source_tag`, `activity_subtype`)**. Rejected as the primary design (both are always set). But this is what we ended up doing as a refinement: the user explicitly sets one, the other is inferred.
3. **Drop the `dev.md` taxonomy entirely**. Rejected: the cognitive activity distinction (perception/cognition/action/reflection) is useful for the Source Classifier.

## References

- `ghw_memory_system.agent.final.md` §4.1.2 (M/F/S mapping)
- `ghw_memory_system.agent.final.md` §5.1 (category-theoretic semantics)
- `dev.md` §2.2.1 (sensory/cognitive/action)
- `specs/001-trisource-everos-mvp/data-model.md` (concrete type definitions)
- `specs/001-trisource-everos-mvp/spec.md` FR-002 (source_tag enforcement)
- `.specify/memory/constitution.md` Principle I (三源完整性)
