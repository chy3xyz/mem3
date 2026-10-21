# Glossary

The theory behind mem3 was written in Chinese. The rest of this repository uses the English names below. This file is the one place, besides the separate manuscript `docs/属性数学_出版版.md`, where the Chinese originals appear.

## Theory terms

| Chinese | English name used in the repo | Definition |
|---|---|---|
| 三源合恰论 | Tri-Source Coherence Theory | The ontology mem3 is built on: what exists shows up in three sources that cannot be reduced to each other. Older text and the paper render it as "Tri-Source Con-appropriation Theory". |
| 三源 | the three sources | Matter, form and spirit. Every memory carries one as its `source_tag`. |
| 物 | matter (M) | The raw, causally efficacious substrate. In a MemCell this is the `episode`. |
| 象 | form (F) | Structure and information that can be extracted and computed on. In a MemCell this is `atomic_facts`. |
| 性 | spirit (S) | Direction and meaning. In a MemCell this is `foresight` and `goal_associations`. |
| 合恰 | coherence | The way the three sources hold together in one memory. The paper's English word is "con-appropriation", which survives in the names PMOE and PCR. |
| 互根律 | law of mutual rooting | No source stands alone. Matter needs form to show up, form needs spirit to act, spirit needs matter to be carried. |
| 存在坍缩 | existential collapse | What happens when one source is reduced to another. The constitution treats it as the reason all three are required. |
| GHW 范式 | GHW paradigm (Goal/Harness/World) | The three-layer architecture. Goal is the spirit layer, Harness the form layer, World the matter layer. |
| 双向通演 | Bi-Directional Transduction | The two-way flow of information between the GHW layers. |
| 外拓之路 | outward path | Encoding: Goal → Harness → World. |
| 内求之路 | inward path | Retrieval: World → Harness → Goal. |
| 存在增益 | existence gain | The metric that drives encoding, consolidation, recollection and forgetting, in place of capacity or TTL. The paper also calls it "ontological enhancement" (see PMOE in the constitution). |
| 编码 / 巩固 / 回忆 / 遗忘 | Encoding / Consolidation / Recollection / Forgetting | The four memory operations that make up the lifecycle. |
| 模糊记忆区 | fuzzy store | Where memories with `spirit_coherence > 0.7` are archived instead of deleted. |

## Constitution principles

The English titles match the headings in `.specify/memory/constitution.md`. Some documents shorten principle IV to "Zero-Dependency Native".

| No. | Chinese title | English title | One-line meaning |
|---|---|---|---|
| I | 三源完整性 | Tri-Source Integrity | Every memory carries a matter, form and spirit source tag. Untyped memories are rejected at encoding time. |
| II | GHW 三层耦合 | GHW Three-Layer Coupling | Every operation fits the Goal/Harness/World layers. Modules declare their layer, and cross-layer shortcuts are violations. |
| III | 存在增益驱动 | Existence-Gain-Driven Lifecycle | Encoding, consolidation, recollection and forgetting follow existence gain, not capacity or TTL. |
| IV | 零依赖 + Zig 0.17 原生 | Zero-Dependency Zig 0.17 Native | One binary with no external runtime dependencies, for macOS and Linux. |
| V | 零拷贝 + 编译时零开销 | Zero-Copy + Comptime Zero-Overhead | Comptime serialization, explicit allocators, and performance targets that block a release. |
| VI | 测试优先 + 形式化保证 | Test-First + Formal Guarantees | Tests come before implementation. The constitution invariants run as their own gate. |
| VII | 可观测性 + 单二进制调试 | Observability + Single-Binary Debugging | Structured logs, a `/metrics` endpoint and dump/inspect commands. Long-running modes stay silent by default. |

## Literal Chinese in the code

The CLI, the HTTP API and the MCP tools accept `物`, `象` and `性` as aliases for the source tags `matter`, `form` and `spirit` (see `MemorySource.fromString` in `src/core/types.zig`). These characters are input values, not documentation, so they stay in the code and its tests.

## Source documents

| File | Note |
|---|---|
| `三源合恰论.docx` | The foundational manuscript for Tri-Source Coherence Theory. It is not in this repo. |
| `docs/属性数学_出版版.md` | A separate Chinese manuscript. Not translated. |
| `ghw_memory_system.agent.final.md` | The formal paper. |
