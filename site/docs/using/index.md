---
order: 2
---

# CLI, HTTP, and MCP

All three call the same store. `--data-dir` selects the directory that holds `mem3.wal` and `snapshot.bin`. The default data directory is the process working directory, so a bare `mem3 add` writes those files where you ran it. Point it at `/tmp` or a directory you meant to create.

## CLI

| Command | What it does |
|---|---|
| `add` | Encode a cell and append it to the WAL |
| `query` | Ranked recall. `--topk` defaults to 10. `--json` prints ids |
| `goal` | `add`, `list`, `status` |
| `hyperedge` | `add`, `list`, `multi-hop` |
| `dump` | JSONL of the store |
| `inspect` | One cell and its neighborhood |
| `consolidate` | Clustering pass |
| `forget` | Existence-gain sweep. `--dry-run` reports without writing |
| `unsupersede` | Clear a superseded mark |
| `serve` | HTTP daemon |
| `mcp` | MCP over stdio |
| `bench` | In-process smoke bench. The release harness is `zig build bench` |
| `help`, `version` | |

`add` needs `--episode` and a spirit dimension: `--foresight`, or `--goal-ids` with `--relevances`. `--source` defaults are documented by `mem3 add --help`. A foresight confidence outside `[0, 1]`, or an empty description, is `InvalidForesight` and nothing is written.

`query --source-filter` is a filter on the dense path. It is not the hybrid ranker. `--include-superseded` puts marked cells back into the candidate set. The default hides them.

`serve` defaults to `--bind 127.0.0.1 --port 7777`. `--wal-sync` is `always` (the default), `group`, or `interval:N`.

## HTTP

`mem3 serve` speaks HTTP/1.1. No authentication. Do not publish the port.

| Method | Path | Result |
|---|---|---|
| `GET` | `/` | Embedded web UI |
| `GET` | `/healthz` | `{"status":"ok","version":"0.1.0-alpha"}` |
| `GET` | `/metrics` | Prometheus-style text |
| `POST` | `/api/memcells` | Create a cell. `201` and `{"id":N}` |
| `GET` | `/api/memcells` | List cells |
| `GET` | `/api/memcells/:id` | One cell, or `404` |
| `GET` | `/api/goals` | Goals, without the structural bottom and top anchors |
| `POST` | `/api/query` | Body field is `text` |
| `POST` | `/api/sync` | Flush the WAL and write a snapshot |
| `POST` | `/api/forget` | Preview unless the body sets `dry_run` to false |

```bash
curl -s http://127.0.0.1:7777/healthz
curl -X POST http://127.0.0.1:7777/api/memcells \
  -d '{"source":"matter","episode":"curl added this cell"}'
curl -X POST http://127.0.0.1:7777/api/query -d '{"text":"curl","topk":3}'
```

If the body omits `goalId` and `relevance`, the handler uses goal `1` at relevance `0.5`, which is enough of a spirit dimension to accept the cell. Optional foresight is a JSON array of `{description, valid_from, valid_until, confidence}`. A malformed foresight is a 400 and nothing is written.

## MCP

`mem3 mcp` reads JSON-RPC 2.0 on stdin and writes responses on stdout. Logging stays off stdout.

Tools:

| Tool | What it does |
|---|---|
| `memory_add` | Encode a cell |
| `memory_query` | Recall |
| `goal_list` | List goals |
| `memory_forget` | Forgetting sweep |
| `memory_stats` | Counts |
| `memory_unsupersede` | Clear a superseded mark |

The server accepts the modern `2026-07-28` handshake and the legacy `2025-11-25` handshake, decided per request, and it accepts batches. Real clients that have completed a session — MCP Inspector 2.11.0, Claude Code 2.1.289, and the Cursor CLI agent — all used the legacy handshake. The modern path has no real-client session yet. The record is [MCP hosts](../library/mcp-hosts.md).

```bash
python3 scripts/mcp_conformance.py --mem3 ./zig-out/bin/mem3
```
