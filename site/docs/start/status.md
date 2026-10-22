---
order: 4
---

# Status

**v0.1.0-alpha.** The CLI, the HTTP daemon, and the MCP server share one store. Cells, goals, foresight, hyperedges, consolidation, and forgetting survive a restart through the WAL and a snapshot.

This page does not repeat benchmark tables. Those go stale. The tables that match a given tree are in the repository [README](https://github.com/chy3xyz/mem3/blob/main/README.md) and the [roadmap](../library/roadmap.md).

## In this tree

- Encode rejects a cell with no spirit dimension. `--foresight` is stored in the WAL and the snapshot.
- Recall mixes a lexical vector, BM25, and the hypergraph. The default embedder has no synonym knowledge. `--embedder-cmd` delegates to an external program. Requests on that protocol are hex-encoded.
- Forgetting uses net existence: importance, minus redundancy, minus conflict. The default supersede mode is `functional`. Cells are marked superseded or moved to the fuzzy store. They are not deleted. `mem3 unsupersede` clears a mark.
- Consolidation rebuilds a dirty component instead of comparing every pair.
- Release builds use `smp_allocator`. Debug and ReleaseSafe keep the debug allocator so leak checks still run. Parallel HNSW construction and int8 distances during construction are library options. The default `mem3` insert path is still one thread and full-precision.

## Not met, on the measurements we have

- LongMemEval question-answer accuracy is not at the 80% bar. The published numbers are retrieval scores on an offline reimplementation and on the official haystack, not an LLM judge. See [LongMemEval](../library/benchmarks/longmemeval-official.md) and the [ablation](../library/benchmarks/ablation-tri-source.md).
- A 100k-vector HNSW build on the default single-thread path is over the 30 second budget. Eight threads plus construction-time int8 met that budget on one loaded Apple Silicon machine. That configuration is not what `mem3 add` calls.
- The original release notes under `docs/releases/` print a performance table from the design period. Current `zig build bench` does not reproduce it. Those notes are not published on this site.

## Not claimed

A null result on LongMemEval-S is not a proof that tri-source tags, goals, or existence gain are useless. That set has no goals, no source labels, and no forgetting pressure. The ablation says this, and it records the synthetic checks where those switches do change the ranking.
