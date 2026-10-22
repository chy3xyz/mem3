---
order: 2
---

# Interface

The CLI, the HTTP daemon, and MCP all use one store. Pass the same `--data-dir` to each.

## CLI

| Command | |
|---|---|
| `add` | Append a cell. Needs `--episode`, and a foresight or a goal. |
| `query` | Search. `--topk` defaults to 10. |
| `goal` | `add`, `list`, `status` |
| `hyperedge` | `add`, `list`, `multi-hop` |
| `dump` | Print the store as JSONL |
| `inspect` | One cell and its links |
| `consolidate` | Cluster cells |
| `forget` | Run the sweep. `--dry-run` makes no change. |
| `unsupersede` | Clear a superseded mark |
| `serve` | HTTP daemon |
| `mcp` | MCP on stdin and stdout |
| `bench` | Short in-process bench |

`mem3 add --help` lists the flags. A bad foresight is refused and nothing is written.

`query` hides superseded cells unless you pass `--include-superseded`.

## HTTP

`mem3 serve` speaks HTTP/1.1.

| Method | Path | |
|---|---|---|
| `GET` | `/` | Small web UI |
| `GET` | `/healthz` | `{"status":"ok","version":"0.1.0-alpha"}` |
| `GET` | `/metrics` | Text metrics |
| `POST` | `/api/memcells` | Create a cell. `201`, body `{"id":N}` |
| `GET` | `/api/memcells` | List cells |
| `GET` | `/api/memcells/:id` | One cell, or 404 |
| `GET` | `/api/goals` | Goals |
| `POST` | `/api/query` | JSON body field `text` |
| `POST` | `/api/sync` | Flush the log and write a snapshot |
| `POST` | `/api/forget` | Preview. Send `{"dry_run":false}` to apply. |

A create body needs `episode`. If you omit `goalId` and `relevance`, the server uses goal 1 at relevance 0.5. Foresight is an array of `{description, valid_from, valid_until, confidence}`. A bad foresight returns 400.

```bash
curl -s http://127.0.0.1:7777/healthz
curl -X POST http://127.0.0.1:7777/api/memcells \
  -d '{"source":"matter","episode":"curl added this cell"}'
curl -X POST http://127.0.0.1:7777/api/query \
  -d '{"text":"curl","topk":3}'
```

## MCP

`mem3 mcp` reads JSON-RPC on stdin and writes responses on stdout.

Tools: `memory_add`, `memory_query`, `goal_list`, `memory_forget`, `memory_stats`, `memory_unsupersede`.

```bash
python3 scripts/mcp_conformance.py --mem3 ./zig-out/bin/mem3
```

That script checks the wire protocol. It is not a session with a real MCP client. Clients that have been run are listed in `docs/mcp-hosts.md` in the repository.
