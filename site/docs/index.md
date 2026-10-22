---
layout: home
title: mem3
hero:
  name: mem3
  text: A memory store in one binary.
  tagline: Tri-source tags, an append-only log, and a search index. No database server. macOS and Linux.
  actions:
    - theme: brand
      text: Build and run
      link: /start/
    - theme: alt
      text: CLI, HTTP, MCP
      link: /using/
    - theme: alt
      text: Source
      link: https://github.com/chy3xyz/mem3
features:
  - title: One file
    details: Zig 0.17.0. The ReleaseFast binary links only the system C library. Windows and WASM are refused at compile time, with the reason in the error.
  - title: Three ways in
    details: The same store backs the mem3 CLI, the HTTP daemon on 127.0.0.1:7777, and an MCP server on stdio.
  - title: Written before it is indexed
    details: A cell is appended to the WAL and fsynced, then indexed in memory. A snapshot is a checkpoint. Restart replays the log.
  - title: v0.1.0-alpha
    details: Usable for local experiments. Not a production memory service. Measured gaps are listed on the status page and in the roadmap.
---

# What it stores

Each memory is a cell with a source tag: **matter**, **form**, or **spirit**. A cell with no foresight and no goal association is rejected at encode time. Forgetting does not delete a cell. It moves a decayed cell to the fuzzy store, or marks a contradicted cell superseded.

The names come from Tri-Source Coherence Theory and the GHW paradigm (Goal, Harness, World). The short definitions are in the [glossary](library/glossary.md).

## Read this first

- [Build, add a cell, query it](start/index.md)
- [Commands, HTTP routes, MCP tools](using/index.md)
- [What is measured and what is still open](start/status.md)
- [Roadmap](library/roadmap.md), with the numbers and the cost of closing each gap

On LongMemEval-S, shuffling the tri-source tag, turning the goal bonus off, and turning importance off did not improve retrieval. The benchmark has no goals or source labels to reward those mechanisms. The write-up is the [ablation](library/benchmarks/ablation-tri-source.md).

## Repository

<https://github.com/chy3xyz/mem3>

The manuscript `docs/属性数学_出版版.md` stays in the repository. It is not part of this site.
