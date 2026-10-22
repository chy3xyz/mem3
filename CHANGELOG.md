# Changelog

The version people can build is whatever `main` is. There is no tag newer than the alpha notes. The same page is on the documentation site at <https://chy3xyz.github.io/mem3/project/changelog/>.

## Unreleased

On `main`, after the 2026-06-08 alpha notes:

- Foresight is stored in the WAL and the snapshot. A cell that only has a foresight keeps that spirit dimension across a restart.
- MCP over stdio, with `memory_add`, `memory_query`, `goal_list`, `memory_forget`, `memory_stats`, and `memory_unsupersede`. Conformance is `scripts/mcp_conformance.py`. Real-host sessions are in [`docs/mcp-hosts.md`](docs/mcp-hosts.md).
- An official LongMemEval retrieval harness, separate from the offline reimplementation. See [`docs/benchmarks/longmemeval-official.md`](docs/benchmarks/longmemeval-official.md).
- WAL sync modes `always`, `group`, and `interval:N`. The daemon can shut down on a signal and write a JSONL log when asked.
- Incremental consolidation. See [`docs/benchmarks/consolidation-incremental.md`](docs/benchmarks/consolidation-incremental.md).
- Forgetting uses net existence. Superseded cells stay on disk and drop out of default recall. `mem3 unsupersede` reverses a mark. See [ADR 0005](docs/adr/0005-existence-gain-forgetting.md).
- HNSW insert and build work since the alpha: adaptive `ef_search`, optional int8 storage (off by default), and a parallel build path that `mem3 add` does not call. Release builds allocate with `smp_allocator`.
- CI workflow for macOS and Linux, including a cross-compile job and a job that checks Windows and WASM are still refused.
- Documentation site, built with zdoc: <https://chy3xyz.github.io/mem3/>.

Numbers for those items are in [`docs/roadmap.md`](docs/roadmap.md), not in this list. A figure belongs next to the command that printed it.

## v0.1.0-alpha — 2026-06-08

The original notes are [`docs/releases/v0.1.0-alpha.md`](docs/releases/v0.1.0-alpha.md). They are not rendered on the documentation site. The performance table in that file (millions of cells per second, a 2.4 MB binary, microsecond query latency) is not what `zig build bench` prints on the current tree. Use the README Performance section and the roadmap.
