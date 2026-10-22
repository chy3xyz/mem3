---
order: 3
---

# Design notes

These pages are the repository's `docs/` tree, minus two things. The Chinese manuscript `docs/属性数学_出版版.md` is not published here. The v0.1.0-alpha release notes are not published here either: their performance table is not what `zig build bench` prints. Both files remain in the git repository.

| Page | What it is |
|---|---|
| [Glossary](glossary.md) | English names for the theory terms, next to the Chinese originals |
| [Roadmap](roadmap.md) | What is deferred, why, and the measured cost |
| [Constitution](constitution.md) | The seven principles |
| [ADR 0001](adr/0001-three-source-ontology.md) | Why the tags are matter, form, and spirit |
| [ADR 0002](adr/0002-ghw-mapping.md) | Goal, Harness, World |
| [ADR 0003](adr/0003-hnsw-from-scratch.md) | Why HNSW is in-tree |
| [ADR 0004](adr/0004-wal-first-persistence.md) | Why the log is the database |
| [ADR 0005](adr/0005-existence-gain-forgetting.md) | Net existence, supersede, no delete |
| [Platform amendment](constitution-amendments/2026-10-14-platform-scope.md) | macOS and Linux only |
| [Throughput amendment](constitution-amendments/2026-10-15-write-throughput-target.md) | The write-throughput bar |
| [MCP hosts](mcp-hosts.md) | Which MCP clients have actually been run |
| [Ablation](benchmarks/ablation-tri-source.md) | Tri-source, goal, importance, and graph on LongMemEval-S |
| [LongMemEval](benchmarks/longmemeval-official.md) | Official-haystack retrieval harness |
| [Consolidation](benchmarks/consolidation-incremental.md) | Incremental clustering |

The specification set and the two long design documents are separate sections. `dev.md` and the GHW paper describe the design. Where they disagree with the source, the source and the roadmap win.
