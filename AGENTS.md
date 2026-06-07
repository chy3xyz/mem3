# AGENTS.md

> Root-level agent onboarding for `mem3` (TriSource-EverOS).
> Consumed by OpenCode / Codex / Cursor / Aider / Devin / Gemini CLI / Claude Code.
> This is the **first** file an agent should read after `README.md`.

## Project Snapshot

| Field | Value |
|---|---|
| Project | `mem3` = **TriSource-EverOS** |
| Type | Memory operating system, single-binary CLI + HTTP daemon |
| Language | Zig 0.17 (dev branch, ≥ 0.17.0-dev.3000) |
| Build | `zig build` → one binary, < 10MB, zero external runtime deps |
| Theory | 三源合恰论 (物/象/性) + GHW 范式 (Goal/Harness/World) |
| Spec-kit | Initialized; spec at `specs/001-trisource-everos-mvp/` |
| Status | v0.1.0-alpha (planned); foundation not yet implemented |

## Read Order for New Agents

1. **This file** (you are here)
2. `README.md` — what the project is in 1 minute
3. `dev.md` — engineering blueprint, Zig 0.17 idioms, 12-week roadmap
4. `ghw_memory_system.agent.final.md` — formal theory paper
5. `三源合恰论.docx` (reference) — foundational ontology
6. `.specify/memory/constitution.md` — **the 7 principles (law)**
7. `specs/001-trisource-everos-mvp/spec.md` — what we're building
8. `specs/001-trisource-everos-mvp/plan.md` — how we're building it
9. `specs/001-trisource-everos-mvp/data-model.md` — type definitions
10. `specs/001-trisource-everos-mvp/tasks.md` — what to do next

## Core Principles (read this twice)

**The Constitution is law**. Violating a principle is not "creative license", it is a constitutional violation. If you think you need to violate one, **stop and ask first**.

The 7 principles (in order of importance):

1. **三源完整性 (Tri-Source Integrity)** — every memory MUST have a 物/象/性 source tag. No untyped memories. Reject at encoding time.
2. **GHW 三层耦合 (Goal-Harness-World)** — three layers, no cross-layer shortcuts. Each module declares its layer in file-level doc-comment.
3. **存在增益驱动 (Existence-Gain-Driven Lifecycle)** — encoding/consolidation/retrieval/forgetting all driven by the existence-gain metric, not by capacity/TTL.
4. **零依赖 + Zig 0.17 (Zero-Dependency Native)** — no FAISS, no Neo4j, no Redis, no SQLite, no libc wrappers, no external async runtime. Single binary, cross-compile.
5. **零拷贝 + 编译时零开销 (Zero-Copy + Comptime Zero-Overhead)** — comptime-generated serialization, explicit allocator injection, no runtime reflection.
6. **测试优先 + 形式化保证 (Test-First + Formal Guarantees)** — tests written BEFORE implementation. Three constitution invariants tested on every PR.
7. **可观测性 + 单二进制调试 (Observability + Single-Binary Debugging)** — structured logs, /metrics endpoint, dump/inspect commands, silent-by-default for long-running modes.

**Read `.specify/memory/constitution.md` for the full text.**

## Code Style

- **Zig idiomatic**: snake_case functions, PascalCase types, SCREAMING_SNAKE_CASE constants. Domain terms (MemCell, GHW, HyMem) keep natural casing.
- **Memory ownership**: explicit `Allocator` parameter on every allocation. No hidden globals.
- **Error handling**: tagged unions (`!T`). Never `null` for fallible operations. Use `std.posix.ENOENT`-style names.
- **No panics in libraries**. `unreachable` only with a `// SAFETY: ...` comment.
- **No allocator state in globals**. Pass `Io` runtime explicitly to async functions.
- **Comments**: explain WHY, not WHAT. Code is read more than written.

## File Map (Implementation Phase)

```
src/
├── main.zig                  # Entry: CLI dispatch
├── core/                     # GHW L1 基础层: types, errors, ids, config
├── ghw/                      # GHW L2: goal_tree, harness_registry, world_model
├── memory/                   # GHW L3: tri_source_manager, lifecycle, encoder, consolidator, forgetter, fuzzy, coherence
├── hypermem/                 # GHW L4: engine, hyperedge, multi_hop, msg_passing, graph_index
├── retrieval/                # GHW L4: hnsw, kv_index, keyword, hybrid_retriever, reranker, embedder
├── storage/                  # GHW L4: lsm_store, wal, snapshot
├── server/                   # HTTP daemon: http_server, routes, handlers/, middleware
├── utils/                    # Cross-cutting: serializer, allocator, time, logger, jsonl, hashing
└── cli_commands/             # CLI subcommand implementations
```

## Development Workflow

1. **Read the task** in `specs/001-trisource-everos-mvp/tasks.md`. Each task has an ID (T001, T002, ...) and a [Story] label.
2. **Write the test first** (TDD, Constitution VI). Run it, verify it fails.
3. **Write the minimum implementation** to make the test pass.
4. **Run `zig build test`** to verify no regressions. The three constitution tests MUST stay green.
5. **Commit** with `type(scope): subject` format. Examples:
   - `feat(hypermem): implement multi-hop traversal with confidence threshold`
   - `fix(serializer): correct nested slice handling for HyperEdge.source_weights`
   - `test(constitution): add spirit-dim invariant test`
6. **Run `zig build bench`** if your change touches the hot path (HNSW, HybridRetriever, LSMStore, HTTP server). Compare against the Constitution §Performance Standards.
7. **Open a PR**. The CI step will:
   - Run `zig build test` (must be green)
   - Run `zig build bench` (must meet gates; aspirational gates may be deferred)
   - Check `ldd zig-out/bin/mem3` for new shared library deps (Constitution IV violation = blocked)
   - Grep for forbidden patterns: `linkSystemLibrary`, `std.ArrayList(T).init(...)` with global allocator, `std.json.Parse` (use our `comptime` JSON instead)

## Common Pitfalls (from project history)

1. **Don't pull in FAISS / HNSWlib / Neo4j / Redis / SQLite** — zero-dep Constitution IV violation. Implement HNSW, hypergraph, KV, WAL in-tree.
2. **Don't use `std.Thread.Mutex` in Zig 0.17** — it doesn't exist. Use `std.Io.Mutex` and pass `io` explicitly.
3. **Don't log to stdout in long-running modes** — per dev.md lessons-learned: silent by default, `--log-every N` for periodic summaries, log rotation external.
4. **Don't introduce a new external dependency without a Constitution amendment** — raise it in the PR, do not silently add.
5. **Don't return `null` for fallible operations** — use tagged error unions. `null` is for absence-of-value, not for errors.
6. **Don't use `std.fs.File.stdout()` directly** — use `std.log.scoped` for log lines. Reserve stdout for CLI output.
7. **Don't forget to write a MemCell's spirit dimension** — `foresight` and `goal_associations` are constitutional requirements. The constitution test in `tests/constitution/spirit_dim.zig` will fail.

## Performance Gates (release-blocking)

| Metric | Target |
|---|---|
| MemCell write throughput | ≥ 1K/sec MVP / 10K/sec release |
| Top-10 query P95 | < 50ms MVP / < 10ms release (100K corpus) |
| HNSW build 100K vectors | < 30s |
| 3-hop traversal | < 5ms (1K seeds) |
| Cold-start | < 200ms |
| RSS at 100K cells | < 500MB |
| Binary size | < 10MB stripped |
| External deps (ldd) | 0 |

## Reference Architecture Decision Records

Located in `docs/adr/`. Read in order:
- `0001-three-source-ontology.md` — resolves the `matter/form/spirit` vs `sensory/cognitive/action` naming conflict
- `0002-ghw-mapping.md` — formal mapping Goal↔性, Harness↔象, World↔物
- `0003-hnsw-from-scratch.md` — why we don't use FAISS
- `0004-wal-first-persistence.md` — why we don't use RocksDB

## Spec-Kit Quick Reference

This project uses GitHub's spec-kit workflow. Key commands (via `specify` CLI or slash commands in Claude Code):
- `specify init` — project scaffolding (done)
- `/speckit-constitution` — update the 7 principles (only if amendment needed)
- `/speckit-specify` — update spec.md (only for new features)
- `/speckit-plan` — update plan.md
- `/speckit-tasks` — generate tasks.md for a new feature
- `/speckit-implement` — execute the tasks

The current spec-kit artifacts:
- `.specify/memory/constitution.md` (v1.0.0)
- `specs/001-trisource-everos-mvp/spec.md` (DRAFT)
- `specs/001-trisource-everos-mvp/plan.md` (ready for implementation)
- `specs/001-trisource-everos-mvp/data-model.md` (ready for implementation)
- `specs/001-trisource-everos-mvp/quickstart.md` (ready for new contributors)
- `specs/001-trisource-everos-mvp/tasks.md` (110 tasks, 8 phases)
- `specs/001-trisource-everos-mvp/checklists/requirements.md` (30 checks, all passed)

## Testing

```bash
# All tests
zig build test

# Just the constitution invariants
zig build test --test-filter constitution

# Benchmarks
zig build bench
```

## What NOT to do

- Don't write code before reading the relevant spec section.
- Don't skip the constitution tests "for now" — they are the gate.
- Don't add features not in `spec.md` or `tasks.md` without a spec amendment.
- Don't commit secrets, large binaries, or `zig-cache/` to git (see `.gitignore`).
- Don't push to `main` directly. Use a feature branch per the spec-kit convention.

## Questions?

Open an issue or ask the user. When in doubt, read the constitution — it has the answer.
