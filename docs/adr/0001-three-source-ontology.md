# ADR-0001: Three-Source Ontology as Canonical `source_tag`

Terminology: Chinese theory terms used in this repository are defined in [`docs/glossary.md`](../glossary.md).

**Status**: Accepted | **Date**: 2026-06-07 | **Authors**: Mavis (drafted from `dev.md` + `ghw_memory_system.agent.final.md`)

## Context

Two reference documents use different taxonomies for memory sources:

- **`ghw_memory_system.agent.final.md` §4.1.2** uses `{M, F, S}` = {Matter, Form, Spirit} as the *canonical* source taxonomy. This is rooted in Tri-Source Coherence Theory.
- **`dev.md` §2.2.1** uses `{sensory, cognitive, action}` as the source taxonomy. This is rooted in cognitive activity types (input, reasoning, behavior).

The two are not contradictory, but they are not identical either:

| Paper's `source_tag` | `dev.md`'s source | Cognitive activity | Example |
|---|---|---|---|
| Matter (M) | sensory | Perception: sensory input, environment observations | "user said: 'how do I use Zig?'" |
| Form (F) | cognitive | Cognition: reasoning, reflection, abstraction | "I derived that Zig 0.17 replaces std.fs" |
| Spirit (S) | action | Action: tool calls, execution results | "I ran `zig build` and it compiled in 4s" |

The misalignment: `dev.md` puts *action/execution* under the third source, but the paper puts *meaning/value-direction* under the third source (spirit). The paper's `goal_associations` and `foresight` are explicitly the spirit dimension, NOT the action dimension.

## Decision

We adopt the **paper's `M/F/S` taxonomy** as the canonical `source_tag` on `TS-MemCell`. The `dev.md` `sensory/cognitive/action` naming is preserved as a **secondary classification** stored in `metadata.activity_subtype ∈ {perception, cognition, action, reflection}`.

The default mapping is:

| `source_tag` | Default `activity_subtype` | Notes |
|---|---|---|
| Matter (M) | perception | Raw data from the senses and tool returns |
| Form (F) | cognition | Reasoning, reflection, abstract knowledge |
| Spirit (S) | action (for *behavioral* spirit) or reflection (for *meta-cognitive* spirit) | Action vs reflection: behaviour traces vs meta-cognition |

The Source Classifier (when implemented in v0.2.0 with an LLM) MUST set both fields. For the v0.1.0-alpha stub, the user explicitly sets `source_tag` via `--source=matter|form|spirit` and `activity_subtype` is inferred or default.

## Consequences

- **Positive**: Aligns the implementation with the formal paper's theoretical scaffolding. The category-theoretic semantics (paper §5) cleanly map to M/F/S.
- **Positive**: Constitution Principle I (Tri-Source Integrity) is unambiguous: a memory is tagged matter, form or spirit, period.
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
- `.specify/memory/constitution.md` Principle I (Tri-Source Integrity)
