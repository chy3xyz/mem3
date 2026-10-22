# Changelog

## Unreleased

`main` after the 2026-06-08 alpha notes. Foresight is stored in the log. MCP is on stdio. Consolidation is incremental. Forgetting uses net existence and can mark a cell superseded without deleting it. Release builds use `smp_allocator`. Parallel HNSW build and int8 distances exist as library options. The default insert path is still one thread. Prebuilt binaries are published for `brew install mem3` from `chy3xyz/tap`.

Numbers are in `docs/roadmap.md` and the README Performance section.

## v0.1.0-alpha (2026-06-08)

Notes: `docs/releases/v0.1.0-alpha.md`. The performance table in that file is not what `zig build bench` prints on this tree. Use the README.
