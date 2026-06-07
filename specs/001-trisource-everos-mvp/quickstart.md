# Quickstart: TriSource-EverOS MVP

**Branch**: `001-trisource-everos-mvp` | **Time-to-running**: < 10 minutes

**Purpose**: Get a new contributor from `git clone` to a running `mem3` daemon with a populated memory store. No prior knowledge of the codebase, dev.md, or the GHW paper required.

---

## Prerequisites

- **Zig 0.17 dev** (pinned in `build.zig.zon` to a specific commit; see `README.md` for installation). Verify: `zig version` should report `0.17.0-dev.XXXX+`.
- **No other dependencies**. No Node, no Python, no C compiler. (Optional: Python 3 if you want to run the `bench/report.zig` JSON post-processor.)
- A Unix-like system (macOS, Linux). Windows: works but unofficially; we test on macOS + Linux.

If you don't have Zig 0.17 dev yet, follow the official install instructions at <https://ziglang.org/download/>. We recommend installing a dev snapshot ≥ 0.17.0-dev.3000.

---

## Step 1: Build (1 minute)

```bash
cd mem3
zig build
```

This produces `zig-out/bin/mem3` — a single ~9MB stripped binary. No `cargo build`, no `npm install`, no `apt-get install`. Just one binary.

Verify:
```bash
ls -lh zig-out/bin/mem3
./zig-out/bin/mem3 --help
```

You should see the help text with subcommands: `add`, `query`, `goal`, `dump`, `inspect`, `bench`, `serve`, `consolidate`, `forget`.

---

## Step 2: Add your first memory (30 seconds)

The `add` subcommand takes a MemCell and stores it. Source tag is required.

```bash
./zig-out/bin/mem3 add \
  --source matter \
  --episode "Zig 0.17's std.Io replaces the old std.fs / std.posix async story" \
  --facts "Zig|introduces|std.Io|Zig|replaces|std.fs async" \
  --foresight "Zig 0.17 will be the dev branch for ~1 year|0|9999999999999|0.9" \
  --goal-ids 1 --relevances 0.7 \
  --json
```

Expected output (your `id` will differ):
```json
{"id": 1, "status": "committed", "wal_offset": 142}
```

This:
1. Created a `MemCell` with `source = matter`, `episode = "..."`, two `atomic_facts`, one `foresight`, and one `goal_association` to goal `id=1`.
2. Wrote a `WAL_RECORD_TYPE_MEMCELL_INSERT` to `data/wal.log`.
3. Inserted the cell into the in-memory HashMap, HNSW index (with the stub embedder), KV index, and hypergraph (single-node, no edges yet).
4. Computed `importance_score = 0.30 * 0.7 + 0.40 * 0.7 + 0.30 * 0.5 = 0.58`.
5. Returned the assigned `id`.

---

## Step 3: Add a goal (15 seconds)

Memories need goals to be useful. Let's create one.

```bash
./zig-out/bin/mem3 goal add --name "build-ghw-kernel" --priority 9 --json
```

Expected:
```json
{"id": 1, "status": "created"}
```

Now the MemCell from Step 2 is bound to this goal. Re-run the query in Step 4 to see the binding affect ranking.

---

## Step 4: Query (15 seconds)

```bash
./zig-out/bin/mem3 query "Zig 0.17 std.Io async" --topk 5 --json
```

Expected (abbreviated):
```json
{
  "results": [
    {
      "id": 1,
      "source": "matter",
      "episode": "Zig 0.17's std.Io replaces...",
      "score": 0.87,
      "score_breakdown": {
        "dense": 0.95,
        "sparse": 0.60,
        "graph": 0.0,
        "goal_bonus": 0.28,
        "existence_bonus": 0.17,
        "recency_bonus": 0.20
      }
    }
  ],
  "stats": {
    "query_ms": 4,
    "seeds": 1,
    "expanded_hops": 0
  }
}
```

The score breakdown shows the GHW-prioritized ranking in action. For a single cell with a 1-hop neighborhood, the dense path dominates. The goal_bonus is `0.4 * 0.7 = 0.28` (per the formula `(1 + 0.4 * goal_bonus)`).

---

## Step 5: Run the daemon (1 minute)

```bash
./zig-out/bin/mem3 serve --port 7777 --log-every 60
```

The daemon listens on `127.0.0.1:7777`. To test:
```bash
curl -s http://127.0.0.1:7777/healthz
```

Expected:
```json
{"status":"ok","uptime_s":3,"memcell_count":1}
```

To add a memory via HTTP:
```bash
curl -X POST http://127.0.0.1:7777/memcells \
  -H 'Content-Type: application/json' \
  -d '{
    "source": "form",
    "episode": "GHW mapping: Goal=spirit, Harness=form, World=matter",
    "atomic_facts": [{"subject":"GHW","predicate":"maps","object":"three sources","confidence":1.0,"source":"doc"}],
    "foresight": [],
    "goal_associations": [{"goal_id": 1, "relevance": 0.9, "priority": 9}]
  }'
```

Expected:
```json
{"id": 2, "status": "committed"}
```

---

## Step 6: Multi-hop query (30 seconds)

Add a third cell that links the first two via a typed hyperedge:

```bash
./zig-out/bin/mem3 hyperedge add \
  --type associative \
  --nodes 1,2 \
  --weight 0.8 \
  --source-weights 0.5,0.5,0.0 \
  --json
```

Expected:
```json
{"edge_id": 1, "status": "added"}
```

Now query with multi-hop enabled:
```bash
./zig-out/bin/mem3 query "Zig 0.17" --topk 5 --max-hops 2 --json
```

The result should now include `id=2` (the form cell) at 1 hop from the dense seed `id=1`, with a `graph_relevance > 0` in the score breakdown.

---

## Step 7: Run the tests (1 minute)

```bash
zig build test
```

This runs:
- Unit tests in `tests/unit/`
- Property tests in `tests/property/`
- Constitution tests in `tests/constitution/`
- Integration tests in `tests/integration/`

All tests should pass. The three constitution invariants are tested explicitly in `tests/constitution/`.

---

## Step 8: Run the benchmarks (5 minutes)

```bash
zig build bench
```

This runs:
- `bench/throughput.zig` — MemCell write rate
- `bench/retrieval_p95.zig` — Query latency
- `bench/hnsw_build.zig` — HNSW build time
- `bench/multihop.zig` — 3-hop traversal
- `bench/cold_start.zig` — Binary launch time
- `bench/footprint.zig` — Memory usage

Output is JSON to `zig-out/bench/bench.json`. Compare against the targets in `constitution.md` §Performance Standards.

---

## What's Next?

- **Understand the architecture**: read `dev.md` for the engineering blueprint, `ghw_memory_system.agent.final.md` for the formal paper, `三源合恰论.docx` for the foundational ontology.
- **Try the example programs**: `examples/notebook.zig` is the US1 scenario from the spec, `examples/multi_project.zig` is US2, `examples/multihop_query.zig` is US3.
- **Cross-compile to aarch64**: `zig build -Dtarget=aarch64-linux-gnu` produces an ARM binary for edge deployment.
- **Contribute**: see `AGENTS.md` (root) for the agent onboarding document, including the constitution test workflow.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `zig build` fails with "std.Io not found" | Zig version too old | Upgrade to ≥ 0.17.0-dev.3000 |
| `ldd build/mem3` shows unexpected libs | Native compilation pulled in extras | Verify `build.zig` has no `linkSystemLibrary` calls; if found, this is a Constitution IV violation, file an issue |
| `mem3 query` returns 0 results | The HNSW stub embedder is hash-based; semantically similar texts hash differently | v0.1.0-alpha limitation; bring-your-own embedder is v0.2.0 |
| `mem3 serve` crashes on Ctrl-C | The HTTP server doesn't trap SIGINT | The `serve` subcommand installs the signal handler; if you forked it, add one |
| `data/wal.log` grows huge | Forgetting not running | `mem3 forget --threshold 0.1` periodically, or wire it into a cron |
| Constitution test fails: "spirit dim missing" | A test fixture has a cell with no foresight AND no goal_associations | The fixture is wrong; add at least one foresight or goal_association |

---

## What This Quickstart Did NOT Cover

- **Embedding model integration** (v0.2.0): the stub embedder is deterministic but semantically weak. Bring your own ONNX model in v0.2.0.
- **Distributed mode** (v0.4.0): v0.1.0-alpha is single-process. Multi-node Raft is deferred.
- **GUI / Web UI** (v0.5.0): the HTTP daemon is API-only. A browser-based UI is a separate workstream.
- **Embedding fine-tuning** (out-of-scope): the project doesn't fine-tune the embedder; users plug in a pre-trained model.

For these and other roadmap items, see `docs/roadmap.md` (TBD in the implementation phase).
