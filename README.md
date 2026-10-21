# mem3 / TriSource-EverOS

**Status: v0.1.0-alpha — early. Not production-ready. No public benchmark results.**

mem3 is a memory store for AI agents, compiled into a single binary with no
external dependencies. You give it short pieces of text; it tags each one with
where it came from, writes it to an append-only log on disk, and keeps a search
index in memory. It ships as one file that runs offline, on an edge box, or
inside an embedded device — on macOS or Linux; see
[Supported platforms](#supported-platforms).

```
git clone <this repo> && cd mem3
zig build
./zig-out/bin/mem3 --help
```

---

## Why it exists

Most agent-memory setups need a database, a vector index, and usually an
embedding service running alongside your agent. That is a reasonable choice on a
server. It is not available on a laptop with no network or on an air-gapped
machine.

It is also, as measured below, too heavy for a 64 MB device. mem3 costs about
**27 KB of resident memory per cell**, so a 64 MB budget covers roughly
**2,000–3,000 cells**. An earlier version of this README named 64 MB as a
supported target; the measurement does not support it, and the table that
replaces it is below.

mem3 takes the opposite constraint: the whole memory layer must compile into one
static-ish binary that links nothing but the OS. Everything usually delegated to
a dependency — the log-structured write path, the vector index, the persistence
format, the embedder — is implemented in-tree in Zig. `otool -L
zig-out/bin/mem3` lists exactly one library, `libSystem`.

### How much memory it actually takes

This is whole-process **peak RSS** (`getrusage` `ru_maxrss`) for a store filled
through `Store.addRaw` and still resident in memory. Each row is one process,
one scale, measured on an Apple M1 Pro (arm64, macOS 26.6.2), `-Doptimize=ReleaseFast`,
on an otherwise idle host.

| Cells | Peak RSS | of which HNSW vectors + edge IDs | marginal cost per cell |
|---|---|---|---|
| 1,000 | 26.1 MB | 1.7 MB | — |
| 2,000 | 53.2 MB | 3.4 MB | 27.7 KB |
| **3,000** | **79.4 MB** | 5.2 MB | 26.8 KB |
| 5,000 | 132.8 MB | 8.6 MB | 27.4 KB |
| 10,000 | 266.9 MB | 17.2 MB | 27.5 KB |
| 20,000 | 405.4 MB | 34.3 MB | 14.2 KB |
| 50,000 | 695.0 MB | 85.9 MB | 9.9 KB |
| 100,000 | 687.6 MB | 171.7 MB | −0.2 KB |

**The conditions these numbers carry.** An RSS figure without them is not a
measurement, so they are stated rather than implied — the benchmark also emits
them as a `conditions` object in its own JSON:

- **Embedder: the built-in hashed lexer** (`embedder_cmd = null`). No external
  embedder process is spawned and no model weights are resident. These figures
  do **not** bound a `--embedder-cmd` run, which pays for whatever model you point it at.
- **Dim: 384** (`f32`), so 1,536 bytes of vector per cell before any indexing overhead.
- **Index: built incrementally.** Every `addRaw` inserts into the live HNSW, so
  the graph is fully linked at the end. No separate build or rebuild pass.
- **Consolidation: never runs.** No abstracts, no consolidation working set, no
  decay sweep. A long-running daemon that also holds abstracts is larger.
- **WAL: none.** `data_dir = null`, so the WAL contributes 0 bytes to RSS and 0
  to disk. No snapshot is taken.
- **Allocator: `std.heap.DebugAllocator(.{ .thread_safe = true })`** — the same
  allocator the shipped `mem3` binary uses, so this is not a bench-harness
  artifact. It does carry per-allocation debug metadata and caches freed pages
  rather than returning them, which is what makes the marginal cost collapse
  above 20K cells. Do not read the flattening as a property of the data model.
- **Not measured here:** on-disk footprint, durable/WAL mode, `--embedder-cmd`,
  and steady-state RSS of a consolidating daemon. Those are different numbers.

Reproduce any row:

```bash
zig build -Doptimize=ReleaseFast
/usr/bin/time -l ./zig-out/bin/mem3-bench footprint --cells=10000
```

Use the external `/usr/bin/time -l` figure, not the benchmark's self-report.
On a memory-pressured host macOS purges and compresses pages, and in-process
`ru_maxrss` then reads **low** — this measurement was caught reporting 71.7 MB
for a store whose vectors alone are 73.2 MB, which is impossible. Under load
the in-process and external readings diverged by as much as 4×. On an idle host
the two agree exactly and repeated runs are bit-identical; every row above was
checked for that agreement. Treat any RSS number taken on a busy host as
unverified.

Two honest readings of the table:

1. **64 MB holds 2,000 cells and does not hold 3,000.** The crossover sits
   between those two points, and it stayed there across every replicate taken
   while this was measured — 3,000 cells was never observed below 67.6 MB.
2. **100K cells is 687.6 MB, which misses the project's own < 500 MB
   target** recorded in `AGENTS.md`. That row was previously marked UNVERIFIED;
   it is now measured, and the answer is a miss, not a pass. Repeated
   measurements of the 100K point ranged from 608.7 MB to 1,644.6 MB on a
   loaded host; every single one exceeded 500 MB, so the miss does not depend on
   which run you believe.

**Update after the HNSW rework (2026-10-21, loaded host).** The table above
is the older idle-host measurement and has not been re-taken. On a loaded host
RSS was unusable: at 100k cells `/usr/bin/time -l` read 426 / 991 / 2,768 MB for
`main` and 331 / 337 / 579 MB for the branch, so **nothing is claimed about the
< 500 MB target**. What can be stated is the deterministic live-allocation count
(`mem3-bench footprint` now reports it from a counting allocator; it excludes
allocator overhead, so it is a lower bound on RSS): at 100k cells **~3,013 B/cell
(301 MB) on `main`, ~2,940 B/cell (294 MB) on the branch, ~1,784 B/cell (178 MB)
with the optional int8 vector storage**. Of the ~2,926 B/cell on the branch at
10k cells, 1,573 are the vector arena, ~520 the BM25 posting lists, ~340 the
cells and their strings, 257 the layer-0 neighbour lists. The ~27 KB/cell
marginal figure above is therefore mostly allocator page caching and macOS RSS
behaviour, not live data. Full tables and method:
[`docs/roadmap.md`](docs/roadmap.md), "1a. HNSW rework".

This is early software. It has no external users, no published benchmarks, and
several known gaps listed under [Status and limitations](#status-and-limitations).
The reason it is published at all is that the constraints it was built under are
reproducible today, and the parts that do work are covered by tests.

## Build

Requires **Zig 0.17.0**, pinned in [`.zigversion`](.zigversion).

```bash
zig build            # binaries land in zig-out/bin/
```

`zig build` produces `mem3` (the CLI + daemon), `mem3-bench`, `mem3-longrun`,
`mem3-hnsw-recall`, `mem3-forgetting-eval`, `notebook`, and `loadtest`. The
default Debug build of `mem3` is **4,569,032 bytes** and `-Doptimize=ReleaseFast`
is **963,704 bytes**; both link only `libSystem` (both measured on this tree,
Apple M1 Pro / arm64).

Artifacts:

| Path | What |
|---|---|
| `zig-out/bin/mem3` | CLI and HTTP daemon |
| `zig-out/bin/mem3-bench` | benchmark harness (see [Performance](#performance)) |
| `zig-out/bin/mem3-longrun` | long-run lifecycle baseline (see [Long-run baseline](#long-run-baseline)) |
| `zig-out/bin/mem3-hnsw-recall` | HNSW recall@10 vs exhaustive scan, per `ef` |
| `zig-out/bin/mem3-forgetting-eval` | forgetting-sweep evaluation harness |
| `zig-out/bin/notebook` | `zig build example-notebook` |
| `zig-out/bin/loadtest` | `zig build example-loadtest` |

### Supported platforms

**macOS and Linux only.** Both `x86_64-linux-gnu` and `aarch64-linux-gnu`
cross-compile the whole project clean — binary, library, examples and benchmarks.

**Windows and WASM are refused at compile time**, with the reason named in the
error rather than surfacing later as an unrelated type error:

```
src/lib.zig:23:9: error: mem3 supports macOS and Linux only. Windows needs a
Winsock port of the HTTP daemon (src/server/http_server.zig binds raw POSIX
sockets); WASM is deferred to v0.3.0.
```

The reason is the daemon: `src/server/http_server.zig` binds raw POSIX sockets
(`socket`/`bind`/`listen`/`accept`) and locks a libc `pthread_mutex_t`.
`std.Thread.Mutex` and `std.Thread.sleep` no longer exist in Zig 0.17, and
`std.Io.Mutex` needs an `Io` instance the daemon does not carry, so there is no
zero-port route to Windows. The library, CLI and benchmarks *were* ported and
their Windows branches are still preserved in `src/platform/` — they are
unreachable, untested and unmaintained, and their presence is not a
compatibility guarantee. Full rationale and sync-impact report:
[`docs/constitution-amendments/2026-10-14-platform-scope.md`](docs/constitution-amendments/2026-10-14-platform-scope.md).

## Quick start

All examples write to `/tmp` so nothing lands in your checkout. The spirit
dimension is mandatory — a cell without a foresight or a goal association is
rejected at encode time with `SpiritDimMissing`.

```bash
D=/tmp/mem3-demo && mkdir -p $D

# Add one cell per source: matter (物), form (象), spirit (性)
./zig-out/bin/mem3 add --data-dir=$D --source matter \
  --episode "user asked to refactor the persistence layer" \
  --facts "user|prefers|zig" \
  --goal-ids 1 --relevances 0.8

./zig-out/bin/mem3 add --data-dir=$D --source form \
  --episode "tool output showed a snapshot with a stale counter" \
  --facts "snapshot|superseded|counter" \
  --foresight "the WAL will need a rotation policy|0|9999999999|0.7"

./zig-out/bin/mem3 add --data-dir=$D --source spirit \
  --episode "the forgetting sweep removed a high-importance cell" \
  --facts "forget|removed|cell" \
  --goal-ids 1 --relevances 0.6 --json
```

```
added memory id=4
added memory id=6
{"id":7}
```

`--source` accepts `matter`/`m`/`物`, `form`/`f`/`象`, `spirit`/`s`/`性`.
`--foresight` is `description|valid_from|valid_until|confidence` (entries
`;`-separated); it is durable — journaled in the WAL record and carried in the
snapshot, so a foresight-only cell keeps its spirit dimension across a restart.
Facts are `subject|predicate|object`, `;`-separated.

Read back what is on disk:

```bash
./zig-out/bin/mem3 dump --data-dir=$D
./zig-out/bin/mem3 inspect 4 --data-dir=$D
./zig-out/bin/mem3 goal --data-dir=$D list
```

`dump` emits one MemCell per line:

```json
{"id":4,"source":"matter","episode":"user asked to refactor the persistence layer","importance":0.7700,"coherence":0.0000,"created_at":1791852342356,"access_count":0,"is_fuzzy":false,"atomic_facts":[{"s":"user","p":"prefers","o":"zig"}],"foresight":[],"goals":[{"id":1,"relevance":0.8000}]}
```

```
goals (3):
  id=1 name=general status=pending priority=5 memcells=2
  id=2 name=research status=pending priority=7 memcells=0
  id=3 name=system status=pending priority=6 memcells=0
```

Recall against what you just wrote. `query` embeds the text with the same
embedder the store used, over-fetches 3× the requested top-k from the index,
then re-ranks by goal relevance and importance:

```bash
./zig-out/bin/mem3 query "persistence layer" --data-dir=$D --topk 3
```

```
query: "persistence layer" — 3 results
  id=4 score=0.7793
  id=6 score=0.0046
  id=7 score=-0.2247
```

Link two cells and run the lifecycle passes:

```bash
./zig-out/bin/mem3 hyperedge --data-dir=$D add --type causal --node-ids 4,5 --confidence 0.7
./zig-out/bin/mem3 consolidate --data-dir=$D
./zig-out/bin/mem3 forget --data-dir=$D
```

```
hyperedge added: id=8 type=causal nodes=2
consolidate: abstracts_created=0
  cells: 3 -> 3
forget: dry_run=false
  fuzzied: 0
  kept:    3
  active:  3
  fuzzy:   0
```

Run the HTTP daemon:

```bash
./zig-out/bin/mem3 serve --data-dir=$D --port 7791 --bind 127.0.0.1
curl -s http://127.0.0.1:7791/healthz
# {"status":"ok","version":"0.1.0-alpha"}
```

## Retrieval

The embedder is a real lexical model, not a hash stub. `LexicalEmbedder`
(`src/retrieval/embedder.zig`) hashes word unigrams, word bigrams and character
3-grams into a 384-dim vector with sublinear tf weighting (`1 + log tf`),
**signed** hashing, and L2 normalisation — so dot product equals cosine
similarity of lexical overlap, and HNSW ranks by actual relevance.

Two details matter if you are reading the numbers:

- **Signed hashing** is what keeps unrelated text centred on zero. Without the
  random ±1 sign, every shared bucket adds a positive bias and everything looks
  similar to everything else. There is a test that measures the mean pairwise
  cosine over a corpus and requires it to stay within ±0.15 of zero.
- **Char 3-grams** are what give partial credit for morphology and typos
  (`embed` ↔ `embedded`, `preference` ↔ `preferences`), normalised by
  `sqrt(token length)` so a long token cannot out-mass a short one.

`Embedder` is a union over the variants, selected by `Config.EmbedderKind`, and
`Store` holds that union rather than a concrete embedder — so a future real
model is one variant and one `switch` arm. `Store`'s `BuildOptions.embedder_kind`
defaults to `.lexical_hash`; the historical `StubEmbedder` (`.stub_xxhash`) is
still selectable, and `.onnx_external` is reserved and unimplemented (it
returns `error.UnsupportedEmbedder`).

> **Caveat worth knowing before you switch embedders on an existing `data/`.**
> Only ids and HNSW graph topology are persisted — the vectors themselves are
> not. A graph rebuilt against a different embedder is structurally intact but
> semantically meaningless until the cells are re-inserted. Treat changing
> `embedder_kind` as requiring a re-index.

## CLI reference

```
mem3 <subcommand> [flags]
```

| Subcommand | Purpose | State |
|---|---|---|
| `add` | Encode and persist a MemCell | works |
| `query` | Lexical recall over the live index | works |
| `goal` | Add / list / status goals (`add`, `list`, `status`) | works; created goals are WAL-journaled |
| `hyperedge` | Add / list hypergraph edges, `multi-hop` traversal (`add`, `list`, `multi-hop`) | works |
| `dump` | Export the whole store as JSONL | works |
| `inspect` | Show a cell and its neighborhood | works |
| `consolidate` | Run the consolidation pipeline | works |
| `forget` | Existence-gain-driven forgetting sweep | works |
| `serve` | Start the HTTP daemon | works |
| `mcp` | Serve the Model Context Protocol over stdio | works; driven end to end by MCP Inspector 2.11.0, Claude Code 2.1.289 and the Cursor CLI agent 2026.10.21 (legacy `2025-11-25` handshake only; no other host — see [`docs/mcp-hosts.md`](docs/mcp-hosts.md)) |
| `bench` | In-process smoke suite (see [Performance](#performance)) | works; the release gate is `zig build bench` |
| `help`, `version` | Help text / version string | works |

`add` flags: `--source`, `--episode` (`--ep`), `--facts`, `--foresight`,
`--goal-ids`, `--relevances`. Both `--foresight` and `--goal-ids` are needed
only in the sense that at least one must be present. `--foresight` entries are
`description|valid_from|valid_until|confidence` separated by `;`; a confidence
that is not a finite number in [0, 1], or an empty description, is refused
(`InvalidForesight`) and nothing is written. The same field is accepted by the
HTTP `POST /api/memcells` body (`"foresight":[{"description":..,"valid_from":..,
"valid_until":..,"confidence":..}]`) and by MCP `memory_add`
(`"foresight":["desc|from|until|conf"]`).

`query` flags: `--topk` (`-k`, default 10), `--source-filter` (comma-separated
sources), `--goal-ids` (comma-separated ids). With `--json` it prints
`{"query":[ids...],"count":N}`.

Global flags: `--json`, `--data-dir=<path>` (default `data`), `--log-format=human|jsonl|silent`,
`--log-every=<seconds>`, `--wal-sync=always|group|interval:<ms>`,
`--embedder-cmd=<path>`, `--embedder-arg=<arg>` (repeatable), `--dry-run`,
`--help`, `--version`.

`--wal-sync` (serve, mcp, add and every command that opens a store): `always`
(default) fsyncs every record before the write returns. `group` still
acknowledges a write only after an fsync that covers it, but concurrent
writers share one; the daemon then serves connections on threads. `interval:N`
fsyncs at most every N ms and is **weaker**: an OS crash or power cut can lose
up to ~N ms (+ a 100 ms tick) of acknowledged writes (a process crash loses
nothing). The on-disk WAL bytes are identical in all modes. On the measured
host `group` was not faster than `always` (see
[`docs/roadmap.md`](docs/roadmap.md)).

`serve` and `mcp` exit 0 on SIGINT/SIGTERM after draining in-flight requests
and flushing the WAL. Logging is off unless asked: `--log-format=jsonl` writes
one JSON object per line to **stderr** (startup, maintenance, summary,
shutdown events, nothing else); `--log-every=N` adds a summary every N
seconds; `--log-format=silent` also suppresses the startup banner.

`serve` flags: `--port=<n>` (default 7777), `--bind=<addr>` (default 127.0.0.1).

`mcp` speaks JSON-RPC 2.0 over stdin/stdout, one message per line, and exposes
five tools: `memory_add`, `memory_query`, `goal_list`, `memory_forget`,
`memory_stats`. `memory_forget` defaults to `dry_run: true`. It is hand-written
against the std library — the zero-dependency rule is not relaxed here. Point an
MCP client at it with:

```json
{ "mcpServers": { "mem3": { "command": "/path/to/mem3", "args": ["mcp", "--data-dir=/path/to/store"] } } }
```

It speaks revisions `2026-07-28`, `2025-11-25`, `2025-06-18`, `2025-03-26` and
`2024-11-05`, and it is **dual-era**: a modern client and a legacy one can be
served on the same stdio process, decided per request rather than per
connection.

- A request carrying `params._meta["io.modelcontextprotocol/protocolVersion"]`
  is served under the stateless core — results carry `resultType` and a
  `serverInfo` echo.
- A request without it, or an `initialize`, is served under handshake
  semantics, byte-for-byte as earlier versions answered.
- `server/discover` reports every supported version, the capabilities and the
  identity, and a client that sends it without `_meta` gets `-32602` — which
  is the signal a dual-era client reads as "legacy server, send `initialize`".
- A version we do not speak is answered `-32022` with the list of ones we do.

JSON-RPC **batches** are accepted as well as required: a line holding a
top-level array is answered with a single array, an all-notification batch is
answered with nothing at all, and an empty or malformed batch gets one error
object rather than an empty array. A batch may mix eras.

`--embedder-cmd` delegates embedding to a long-lived external program instead of
the built-in hashed lexer: mem3 writes one line of text, the program replies with
one line of whitespace-separated floats, and the process is reused for every
call. Width mismatches fail at startup, not mid-query. Omit the flag and nothing
changes — the built-in path is byte-identical to builds without this feature, and
neither path adds a link dependency.

> The example in `mem3 --help` (`mem3 add --source matter --episode "hello" --facts "u|likes|coffee"`)
> does not run — it omits the spirit dimension and fails with `SpiritDimMissing`.
> Use the invocation in [Quick start](#quick-start).

## Architecture

Four layers, each justified by a decision record in [`docs/adr/`](docs/adr/):

- **Tri-source tag** — every cell carries `matter` / `form` / `spirit`
  (`src/core/types.zig`). The mapping and the rejected alternative naming are in
  [ADR-0001](docs/adr/0001-three-source-ontology.md); the layer mapping
  (World↔物, Harness↔象, Goal↔性) is in [ADR-0002](docs/adr/0002-ghw-mapping.md).
- **WAL-first persistence** — writes are appended to `mem3.wal` and fsynced per
  record; a periodic snapshot compacts them. Why not RocksDB or SQLite:
  [ADR-0004](docs/adr/0004-wal-first-persistence.md).
- **In-tree HNSW** — the vector index is implemented in `src/retrieval/hnsw.zig`
  rather than linked against FAISS, to preserve the zero-dependency constraint:
  [ADR-0003](docs/adr/0003-hnsw-from-scratch.md).
- **`Store`** (`src/store/store.zig`) — the container holding cells, goals,
  hyperedges, WAL, snapshot and index, built through one factory from
  `BuildOptions` (data dir, seed goals, embed dim, embedder kind).- **Restoring is not only about cells.** `sync` is snapshot-and-truncate:
  `takeSnapshot` unlinks the WAL on its way out, so a restart after any sync
  has nothing left to replay and `loadSnapshot` is the only thing that runs.
  That loop therefore has to rebuild the vector index as well as the cell map
  — it did not, and the store looked intact while every vector query returned
  nothing. Fixed, with the reproduction and the negative control in
  [`docs/roadmap.md`](docs/roadmap.md#other-open-work) and the test
  `Store: a snapshot restore rebuilds the vector index, not just the cells`.

> The daemon **does** use that `Store`. `src/server/http_server.zig` used to
> carry its own ~890-line duplicate so the server could run without the CLI's
> dependency graph; that fork is deleted and the daemon now calls
> `mem3_store.Store` directly. One implementation, two surfaces. The
> `/api/goals` gap this duplication caused is closed — see
> [HTTP API](#http-api).

### Inside the MCP server

`src/mcp/` is five files, and the split is by *who decides what a byte means*
rather than by function:

| File | Decides |
|---|---|
| `framing.zig` | where one message ends and the next begins — including where one element of a batch ends |
| `json.zig` / `json_out.zig` | how bytes become values and back, with no escapes silently lost |
| `protocol.zig` | whether a message is a request, a notification, or garbage — and which protocol era it speaks |
| `server.zig` | dispatch, and the shape of every response |
| `tools.zig` | what a tool does; the only file that touches `Store` |

A line is only a message once its newline has arrived: a truncated trailing
line is *not yet a message*, and asking the framer for it returns nothing
rather than a guess. That is the difference between a transport a real client
interoperates with and one that intermittently hangs, because a client's
write and a pipe read share no boundary.

Two asymmetries carry more weight than the rest. **A notification is never
answered** — an unsolicited response desynchronises a client that matches
responses by id. And **a rejection is always answered**, because silence
leaves a client waiting on a request that was structurally impossible. The
one exception is a request whose `id` could not be read at all, which
JSON-RPC requires be answered as `null`; a request that has a readable id and
a broken method is not that case, and gets its own id back.

See [CLI reference](#cli-reference) for what a client sees, and run
[`scripts/mcp_conformance.py`](#testing) to check it.

## HTTP API

Served by `mem3 serve` over HTTP/1.1 on POSIX sockets. Verified against the
running daemon:

| Method | Path | Result |
|---|---|---|
| `GET` | `/` | Web UI (HTML, embedded) |
| `GET` | `/healthz` | `{"status":"ok","version":"0.1.0-alpha"}` |
| `GET` | `/metrics` | Prometheus-style text |
| `POST` | `/api/memcells` | Create a cell, WAL-durable → `201 {"id":7}` |
| `GET` | `/api/memcells` | List cells |
| `GET` | `/api/memcells/:id` | Single cell, `404` if absent |
| `GET` | `/api/goals` | Live goals → `{"goals":[…]}` |
| `POST` | `/api/query` | Three-way recall — body field is `text` |
| `POST` | `/api/sync` | Flush WAL + write snapshot → `{"status":"synced"}` |

`/api/goals` walks the daemon's in-memory goal poset and emits one object per
goal, skipping the ⊥/⊤ structural anchors:

```json
{"goals":[{"id":1,"name":"general","description":"catch-all","status":"pending","priority":5,"parent_id":0,"memcell_count":0}]}
```

```bash
curl -X POST http://127.0.0.1:7791/api/memcells \
  -d '{"source":"matter","episode":"curl added this cell"}'
curl http://127.0.0.1:7791/api/memcells
curl -X POST http://127.0.0.1:7791/api/query -d '{"text":"zig","topk":3}'
```

The daemon replays the WAL on startup, so both cells **and goals** added in a
prior process are visible over HTTP — a goal created by `mem3 goal add` in one
process appears in `/api/goals` in the next. (Verified: a goal added to a fresh
data dir shows up as `{"id":4,"name":"crossproc",...}` after the daemon starts.)

## Performance

Every figure below was printed by `zig build bench` on the current tree, on an
Apple M1 Pro (arm64, macOS 26.6.2), `seed=42 cells=1000 queries=400`, built
`ReleaseFast`. The harness reports min / median / p95 over many repetitions with
warmup discarded, and writes the raw run to `bench-results.json` (gitignored)
alongside the params and timestamp.

| Benchmark | median | p95 |
|---|---|---|
| `hashing.combine` | 1.0 ns/op | 1.0 ns |
| `hashing.xxh3_64bits` | 6.0 ns/op | 18.0 ns |
| `time.formatIso8601` | 33.0 ns/op | 69.0 ns |
| `serializer.roundtrip` | 27.7 µs | 64.2 µs |
| `encoder.encode` | 35.0 ns/op | 35.0 ns |
| `hnsw.insert` | 899 µs/op (244 µs/op after the HNSW rework) | 1,166 µs (277 µs) |
| `hnsw.search` | 748 µs/op (212 µs/op after the rework) | 1,161 µs (229 µs) |
| `wal.append_durable` | 1,232 µs/record | 2,861 µs |
| `store.addRaw_memory` | 239 µs/op (198 µs/op after the rework) | 323 µs (210 µs) |
| `store.addRaw_durable` | 322 µs/op (275 µs/op after the rework) | 437 µs (294 µs) |

**Read the median, distrust the p95.** On this machine p95 for the same binary
and the same input varies by more than an order of magnitude between runs; only
the median is reproducible to within a couple of percent. That is also why the
constitutional benchmarks below report a worst window alongside the mean — a
sustained writer has to keep up with the slow window, not the fast one.

These are single-run figures on one machine, not regression gates. Re-run them
before quoting.

Run it yourself:

```bash
zig build bench
./zig-out/bin/mem3-bench --cells=1000 --queries=400 --seed=42
```

- **LongMemEval on the official dataset (retrieval only, no LLM judge):**
  `./zig-out/bin/mem3-bench longmemeval-official --data=PATH` reports session-
  and turn-level Recall@k / NDCG@k by question type on the real
  `longmemeval_s_cleaned.json`. These are *not* QA accuracies and not comparable
  to published QA numbers; dataset hash, commands, results and limitations are
  in [`docs/benchmarks/longmemeval-official.md`](docs/benchmarks/longmemeval-official.md).
- **Does the tri-source / goal / importance / hypergraph machinery improve
  retrieval? (pre-registered ablation, same dataset):**
  [`docs/benchmarks/ablation-tri-source.md`](docs/benchmarks/ablation-tri-source.md)
  — paired per-question deltas with bootstrap 95 % CIs for 39–40 variants at
  session and turn granularity (`scripts/lme_ablation_run.sh`,
  `scripts/lme_ablation_report.py`, `mem3-bench lme-compare`). Headline: no
  measured retrieval gain; see [Status and limitations](#status-and-limitations).

The `ef` budget bug that used to make beam search sample instead of navigate is
fixed: the budget is now gated on candidate-set size, which is what `ef` means,
and cannot underflow. `hnsw.search` is bounded by the `ef` budget
(`hnsw_ef_search` = 100) rather than by corpus size. The harness labels it
"top-10 cosine search over the shipped HNSW beam search (greedy descent +
ef-bounded expansion)" — the older "brute-force TopK" label is gone.

`hashing.combine` was rewritten from an `init`/`update`/`final` streaming chain
to a one-shot hash over a 16-byte stack buffer. The old streaming path is
recorded at ~800 ns/op in the comment at `src/utils/hashing.zig:24`; the rewrite
is pinned by a test asserting the exact output bits
(`0x188e414c9e25e9af` for `(0x1234, 0x5678)`), so the speedup could not have
changed any chained key or WAL checksum.

Two caveats the benchmark states itself: `wal.append_durable` fsyncs on every
record, which is what sets the write floor; and `hnsw.search` grows with the
corpus, so do not quote it as graph-index performance.

`hnsw.insert` at ~899 µs/op was the dominant cost in the write path —
larger than the WAL fsync, and larger than the whole `store.addRaw_durable`
pipeline it sits inside. After the HNSW rework (2026-10-21) the rows marked
"after the rework" were A/B-measured against a build of `main` over 5
interleaved rounds (`hnsw.insert` 886 → 244 µs/op, `store.addRaw_durable`
538 → 275 µs/op, `wal.append_durable` unchanged as the control); the figures in
the left column are the older single-run table above, the parenthesised ones are
the median of five medians and the median of five p95s, taken on a quieter host.
The two columns are not from the same load, so compare the `main`-vs-branch pair in
[`docs/roadmap.md`](docs/roadmap.md) ("1a. HNSW rework"), not left against right.
See [Known misses](#known-misses).

## Long-run baseline

`mem3-longrun` (`examples/longrun.zig`) answers one narrow question: **does the
memory lifecycle reach a steady state, and what do the per-cycle increments do
as it gets there?** It runs a closed loop of ingest → periodic consolidate →
periodic forget → sync over a topic-clustered corpus (the consolidator runs HAC
clustering, which needs something to cluster), and writes one JSON object per
cycle so `d_cells`, the net change in live cells, becomes a plottable curve.

```bash
zig build
./zig-out/bin/mem3-longrun --duration-sec=86400 --data-dir=/tmp/mem3_lr
```

Output goes to a JSONL file, not stdout, and progress goes to stderr on a
**time** interval (`--progress-sec`, default 300s) — never on a cycle count. A
cycle-triggered progress log never fires in exactly the steady state you are
trying to observe: once the increments go to zero, it goes silent and the run
looks hung. A long run is expected to produce tens of thousands of lines, so it
is silent by default and refuses to clobber an existing output file.

One cycle's line:

```json
{"cycle":39,"t_ms":41,"ingested":4,"cells":182,"d_cells":4,"matter":49,"form":74,"spirit":59,"fuzzy":0,"lat_ingest_us":1698.00,"lat_consolidate_us":0.00,"lat_forget_us":16.00,"abstracts":0,"fuzzied":0,"kept":182,"wal_kb":66,"snap_kb":0,"rss_kb":5216,"imp_mean":null,"imp_min":null,"imp_max":null,"coh_mean":null}
```

and the closing verdict compares the first decile of `d_cells` against the last:

```
steady-state signal (net cell change per cycle)
  first decile mean   : 4.000
  last decile mean    : 4.000  (over 4 cycles)
  => d_cells trending to 0 means the loop reached a steady state.
  => if the last-decile mean equals the first, it did NOT plateau.
```

### The recorded run

This is a real run on this tree, not an illustration. It was stopped at 2,124
cycles once the trend was unambiguous; the harness writes every line durably
before the next cycle, so stopping early loses nothing.

```bash
zig build
./zig-out/bin/mem3-longrun --cycles=5000 --data-dir=/tmp/mem3_lr --progress-sec=120
```

| Measurement | Value |
|---|---|
| Cycles completed | 2,124 (of 5,000 requested; stopped early) |
| Wall clock | 397.4 s |
| Live cells at stop | 46,958 |
| `d_cells` first decile mean | 21.632 |
| `d_cells` last decile mean | **21.849 — no plateau** |
| Total cells fuzzied | **0** |
| `imp_mean` at last sample | 0.747 (min 0.570, max 0.850) |
| `coh_mean` at last sample | 0.277 |
| Consolidation passes | 84 |
| Total abstracts created | 12,974 (155 per pass, flat from 5k cells on) |
| Consolidate latency, first pass (all-pairs build) | 126.9 ms at 518 cells |
| Consolidate latency, last pass (all-pairs build) | **20,257.6 ms at 44,909 cells** |
| RSS at stop | 151 MB |

The `RSS at stop` row is **not reconciled with
[the measured store footprint](#how-much-memory-it-actually-takes)** and should
not be combined with it. 151 MB at 46,958 live cells is roughly 4× smaller than
the 695 MB measured for a 50,000-cell in-memory store, and the two runs are not
like-for-like: this one is durable, ingest-then-consolidate, and carries a
consolidation working set, while the sweep inserts only through `addRaw`. A
number that disagrees with another number by 4× is a reason to re-measure, not
a reason to pick the smaller one. The long-run RSS has not been re-taken with an
external observer and is reported here exactly as recorded.

Two things fall out of this, and both are recorded as misses in
[Known misses](#known-misses):

1. **`d_cells` does not trend to zero**, and the harness's own arithmetic says
   why. The closing verdict only prints the forgetting-crossover calculation when
   `--stats-every=N` is set — without it every `imp_*` field is `null` and the
   explanation is silently skipped. The crossover is **40–201 days** depending
   on source; this run was 0.0046 days.
2. **Consolidation was superlinear.** 89.9× more cells cost 154.6× more time.
   The pass was all-pairs, so this was O(n²) in the corpus, and the exponent was
   already 1.12 over the range this run covered. *This run predates incremental
   consolidation; the table's two consolidate-latency rows describe the old
   all-pairs build.* The A/B against the incremental build is in
   [`docs/roadmap.md`](docs/roadmap.md) under "Consolidation is incremental":
   at 45k cells a steady-state pass is ~35× less CPU (1.76 s vs 61.6 s on a
   loaded host) and ~40× fewer pair comparisons, while the first pass in a
   process is still O(n²).

If you reproduce this, `--stats-every=25` is worth adding: it turns the
`fuzzied: 0` line from a mystery into a checkable prediction, and it is the
difference between the harness explaining itself and the harness looking broken.

Flags, as implemented:

| Flag | Meaning |
|---|---|
| `--cycles=N` | cycles to run (default 5000) |
| `--duration-sec=S` | stop after S seconds instead — use for 24h runs |
| `--per-cycle=N` | cells ingested per cycle (default 16) |
| `--seed=N` | PRNG seed; same seed reproduces the run |
| `--consolidate-every=N` | default 25 |
| `--forget-every=N` | default 10 |
| `--sync-every=N` | default 100 |
| `--stats-every=N` | sample the importance distribution every N cycles |
| `--progress-sec=S` | stderr progress interval (default 300) |
| `--data-dir=PATH` | default `/tmp/mem3_longrun` |
| `--out=PATH` | JSONL output (default `longrun.jsonl`) |
| `--stdout-jsonl` | also stream JSONL to stdout |
| `--append` | append to an existing output file |
| `--force` | overwrite an existing output file (default: refuse) |
| `--dry-data` | in-memory, no WAL |

Stopping early is safe: every line already written is durable, and `--append`
extends the file on the next run.

## Testing

```bash
./scripts/verify.sh           # everything below, plus provenance and a not-verified list
zig build test                # 507 tests (407 + 100)
zig build check-constitution  # 12 constitution invariants
zig build bench
python3 scripts/mcp_conformance.py   # drives a live `mem3 mcp` over stdio
```

`scripts/mcp_conformance.py` is the one that answers "does the MCP server
actually work", and it is deliberately not a unit test: it starts the binary
and speaks JSON-RPC 2.0 at it, so it catches wiring faults — a truncated
response, a missing newline, an id that is not echoed, bytes on stderr —
that no in-process test can. It checks the things a specification makes
mandatory (`server/discover`, `resultType`, `-32022`, batching, the
notification asymmetry) rather than mem3's own opinions, and it exits
non-zero on the first thing that is wrong. Pass `--mem3 <path>` to point it
at a specific build.

What it is *not*: an interoperability test. Every message in it was written by
the same person who wrote the server, so a shared misreading of the spec would
pass here and fail against a real client. Three real clients have since
been driven against it on 2026-10-21 — MCP Inspector CLI 2.11.0, Claude Code
2.1.289 (headless) and the Cursor CLI agent 2026.10.21 — each doing
`tools/list`, `memory_add`, `memory_query` and `memory_stats` with no errors.
All three used the legacy `2025-11-25` handshake, so **the modern `2026-07-28`
path still has no real-client evidence**. Not verified: Claude Desktop, the
Cursor IDE app, Codex, Gemini CLI (needs auth), and opencode (handshake and
`tools/list` only; its LLM gateway was down). Transcripts, per-host config
snippets and a 5-minute self-check for the rest are in
[`docs/mcp-hosts.md`](docs/mcp-hosts.md).

`zig build test` runs two binaries — one rooted at `src/main.zig` and one at
`tests/main.zig` (unit, integration and property tests under `tests/`). The
counts above are what the two binaries actually report: `407/407` and `100/100`,
for `507/507 tests passed` overall.

**Zig collects `test` blocks only from files named directly in a root source
file's `comptime { _ = @import(...) }` block, exactly one level deep.** A file
reached through `lib.zig` is compiled into the build and looks tested while its
tests register with nobody. Nineteen files and 87 test blocks were sitting
outside the gate that way, including everything in `ghw/goal_tree.zig` — the
goal-poset invariants. Naming them surfaced three real defects on the spot (a
logger that emitted malformed JSON, and two files that did not compile at all).
If you add a `test` block, add the file to the root block too, and check it
actually runs: break a call inside it and confirm `zig build test` goes red.

Because `zig build test` re-runs are served from the build cache and report green
without re-executing, drive the roots directly when you need a real count:

```bash
zig test --dep mem3 -Mroot=src/main.zig  -Mmem3=src/lib.zig   # -> All 421 tests passed.
zig test --dep mem3 -Mroot=tests/main.zig -Mmem3=src/lib.zig   # -> All 120 tests passed.
zig test --dep mem3 -Mroot=tests/constitution/main.zig -Mmem3=src/lib.zig  # -> All 12 tests passed.
```

Every test scratch path under `/tmp` is pid-scoped. That is not tidiness: a
fixed path plus cleanup that only runs on completion means a run that dies
part-way leaves a WAL or snapshot behind and the *next* run inherits it, so the
same command gave different answers depending on what ran before it.

### Test-suite rules

These are enforced conventions, not style preferences. Do not regress them:

1. **A library must never write to stderr.** `zig build test` runs each binary
   with `--listen=-`; a stray stderr write desynchronises the runner↔build
   protocol and the binary dies with `failed command`.
2. **Never silently skip.** A test that cannot run must
   `return error.SkipZigTest`, not `return;`. Skips used to be counted as passes.
3. **The test step depends on the install artifact**, because the HTTP e2e tests
   exec `zig-out/bin/mem3`.
4. **Tests must not write inside the repo.** All scratch paths live under `/tmp`.
5. **Verify the gate actually fails.** Inject a deliberately failing test and
   confirm `zig build test` exits non-zero — a green gate that cannot go red is
   worse than no gate.

## Status and limitations

Known and measured, not discovered after the fact:

- **No measured retrieval gain from the tri-source tag, the goal bonus, the
  importance / existence-gain terms or source-dependent decay on LongMemEval-S
  (official data, retrieval only, 419 questions).** The tag is not an input to
  ranking on the shipped query path, so shuffling it changes nothing (Δ NDCG@10
  = 0.0000, CI [0, 0]). Routing a query by a heuristic tag *lost* to routing by
  shuffled tags (−0.22 / −0.13 NDCG@10, session / turn); switching the goal
  bonus on, with goals derived from the haystack text, cost −0.014 / −0.023;
  importance and source-dependent decay are within noise (|Δ| ≤ 0.006 at the
  pre-registered primary level, with one nominal +0.0046 that does not survive
  the multiplicity correction); one hyperedge per session adds +0.0020 (CI spans
  0) on the primary turn metric and +0.0076 on a secondary session-derived one.
  A null on LongMemEval is not evidence against the ideas — the benchmark has
  no goals or source labels to reward them; a synthetic task built to reward
  them does (goal bonus 1/8 → 8/8, source router 2/10 → 10/10 top-1). Full
  tables, threats to validity and a sketch of a benchmark that would test the
  claims: [`docs/benchmarks/ablation-tri-source.md`](docs/benchmarks/ablation-tri-source.md).
- **Lexical by default, and semantic is opt-in.** Retrieval works — `mem3 query`
  returns ranked, reproducible results and typos/morphology still match — but the
  built-in embedder is bag-of-features over surface forms. It has no world
  knowledge, so synonymy across unrelated vocabulary ("the persistence layer" ↔
  "how mem3 stores records on disk") will not match. `--embedder-cmd` delegates
  to a real model instead; see [CLI reference](#cli-reference). Two honest
  caveats: every recall figure in this document was measured with the built-in
  embedder or synthetic geometry, so the numbers do not describe the external
  path; and bridging to a local model costs one adapter, because Ollama and
  llama.cpp both speak HTTP and this protocol speaks lines.
- **Hybrid retrieval exists now, and it changed the benchmark by an order of
  magnitude.** `recall` fuses three signals (`src/retrieval/hybrid_retriever.zig`,
  weights `λ_dense=0.5, λ_sparse=0.2, λ_graph=0.3`) over word unigrams and
  bigrams with Okapi BM25 (`src/retrieval/bm25.zig`), multi-hop expansion, and
  vectors. Until this landed the sparse score was a copy of the dense one, so
  `λ_sparse` merely re-weighted the dense arm. On identifiers that appear only
  in an `atomic_facts` triple — which the dense arm embeds *from the episode
  text alone*, so it is structurally blind to them — recall went from **1/12 to
  12/12**. What BM25 did not fix is equally worth stating: for an identifier in
  the episode prose, the built-in embedder's char 3-grams already ranked it
  correctly, and the score stayed 12/12 before and after.
- **Switching embedders invalidates a persisted index.** Vectors are not
  persisted, only ids and graph topology — see [Retrieval](#retrieval).
- **Foresight is stored but not searchable.** `--foresight` is durable (WAL and
  snapshot), but it is not embedded and not in the BM25 text, so `query` cannot
  find a cell by what it predicts — only by its episode and facts. A cell that
  names no goal still carries the synthetic goal id `0` next to its foresight.
- **HNSW recall is high on small graphs and falls off with corpus size.** The
  layered structure is built and searched by greedy descent with `ef`-bounded
  expansion, not sampled. Measured recall@10 against an exhaustive scan on a
  400-node corpus (`mem3-hnsw-recall`, dim=32): **0.9920 @ ef=10, 0.9980 @
  ef=100**, against a level-0 reachability of 399/400 = 0.9975 — recall is
  capped by graph connectivity, not by search width. At dim=384 the same
  measurement degrades with `n`: **0.9980** (n=1k), **0.8930** (n=10k),
  **0.6760** (n=30k), **0.4300** (n=100k) at the default `ef=100`, reaching
  0.9890 only at ef=3200. Saturation needs roughly `ef ≈ 0.08·n`, so the
  default is a small-corpus setting: say nothing about a 100k index at `ef=100`.
  `hnsw_ef_search_divisor` (default 64, so the budget is
  `max(ef, live_count / 64)` and inert below 6,400 cells) now buys this back:
  recall@10 **0.893 → 0.944** (10k), **0.676 → 0.926** (30k), **0.430 → 0.928**
  (100k), at a mean of 0.81 → 9.88 ms/query at 100k (100 queries; no per-query
  p95 was measured). Optional int8 vector storage exists
  (`Config.hnsw_vector_storage`) and is off by default because it costs 0.7–1.0
  pt of recall at 10k and 30k.
- **The WAL fsyncs on every record by default**, costing ~1.2 ms per durable
  append in an earlier measurement. `--wal-sync=group|interval:N` exist but
  were not faster on the measured host (fsync was ~30 µs there); see
  [`docs/roadmap.md`](docs/roadmap.md).
- **The daemon's HTTP stack is POSIX-only.** Raw `socket`/`bind`/`listen`/
  `accept` and a libc `pthread_mutex_t`; this is the stated reason Windows is
  not a supported target. See [Supported platforms](#supported-platforms).
- **The daemon is silent by default.** `mem3 serve` prints an 8-line startup
  banner to stderr and then logs nothing per cycle unless a maintenance pass or
  forgetting sweep actually transitions something. This is deliberate: a
  launchd-managed daemon writing per-cycle lines costs ~1.5 GB/day of logs.
- **Consolidation does not reach steady state, and cannot in any practical
  run.** This was measured, not assumed — see [Long-run baseline](#long-run-baseline).
  Over 2,124 cycles / 397 s / 47k cells the mean net cell change per cycle went
  from **21.632** (first decile) to **21.849** (last decile): flat, not
  trending to zero. The reason is structural rather than a short run.
  `Forgetter.existenceContribution` is `importance × exp(-decay_rate × age_days)`
  and a cell is only fuzzied once that falls below `forgetting_threshold`, so
  the crossover is `ln(importance / threshold) / decay_rate`. At the measured
  `imp_mean = 0.747` with the shipped decay rates that is **40 days (matter),
  67 days (form), 201 days (spirit)**. The run lasted 0.0046 days. A flat
  `fuzzied: 0` is the arithmetically correct answer at every run length a human
  will actually sit through, including the 24 h baseline in the README.
  Demonstrating convergence needs either a compressed clock or a fixture of
  pre-aged cells; it does not need a longer run.
- **Consolidation is incremental now, but the first pass in a process is still
  O(n²).** The long run above recorded an all-pairs pass: **8.5 s per pass at
  40k cells, 20.3 s at 45k**, ~1.01 billion pair comparisons at 45k and ~5.0
  billion at 100k. `Consolidator` now keeps its union-find and per-cell token
  signatures across passes and compares only new cells, with an identical
  partition. Measured A/B on a loaded host (CPU time, 45k cells): steady-state
  pass **61.6 s → 1.76 s**, 1.05e9 → 2.59e7 pairs, growth exponent 2.00 →
  1.00 — but only while arrivals per pass are fixed (here 555), and the cache
  costs ~109 B/cell. The cold first pass (every `mem3 consolidate` CLI call) is
  unchanged at 1.01e9 pairs / ~59 s CPU. Details, the removal rule and what was
  not measured (100k, forgetting at volume): `docs/roadmap.md`, "Consolidation
  is incremental".
  Note also that `abstracts` per pass sits flat at 155 from 5k cells onward —
  that is a property of the harness's 5-topic synthetic corpus saturating, not
  evidence of convergence.
- **`mem3 bench` is a fast in-process smoke suite, not the gate.** It is
  implemented (600 cells, 200 hyperedges, in-memory, finishes in ~0.6 s
  optimised). The release-blocking constitutional gates are `zig build bench`.
- **No published benchmarks, no external users, no stability guarantee.**
  Version is `0.1.0-alpha`; treat the on-disk format as unstable.

### Known misses

**Some latency samples are zeros the optimiser manufactured, not measurements
that took no time.** This is the most serious item here, because it questions
the foundation every other number in this document stands on.

`platform.clock.Timer` brackets a region with two `clock_gettime` calls. Under
`-O ReleaseFast` and `-O ReleaseSafe`, LLVM can prove that `clock_gettime` has
no side effects the program can observe, hoist both calls above the region being
measured, and subtract two identical readings. The result is a duration of
**exactly zero** for work that demonstrably ran.

```zig
var t = clock.Timer.start();
var x: u64 = 0;
for (0..20_000_000) |i| x +%= i *% 2654435761;   // provably ~25 ms
std.debug.print("{d} ns\n", .{t.elapsedNs()});
```

| build mode | measured |
|---|---|
| Debug | 23,951,000 ns |
| ReleaseSafe | **0 ns** |
| ReleaseFast | **0 ns** |

This is not confined to a synthetic loop. `./zig-out/bin/mem3-bench multihop`
reports, over 1,000 real per-seed traversals that each reach ~49 nodes:

```
"per_seed_latency_ns":{"min_ns":0.000000,"p50_ns":31000.000000, ...}
```

`min_ns` is exactly `0.000000`. No traversal that reaches 49 nodes takes zero
nanoseconds, so at least one of those 1,000 samples is a folded measurement.

**What is and is not affected.** Benchmarks that time work with observable heap
side effects mostly escape this — the p50 above (31 µs) is in the right range,
and every headline number in this document is non-zero and reproducible across
runs. But `min`, `p99`, and any tight per-iteration loop are the shapes most
likely to be folded, and the fold is silent: there is no error, no warning, and
a zero is a perfectly plausible-looking number to put in a percentile table.
Until this is fixed, **treat minimum and tail-percentile latencies from this
build as unreliable, and prefer p50**, which is already the rule elsewhere in
this document for an unrelated reason.

**Why the existing test does not catch it.** `src/platform/clock.zig` carries
`Timer measures a non-zero, monotonic duration`, which asserts exactly this. It
passes — because `zig build test` builds in Debug by default, and the fold only
happens when optimisation is on. `zig build test -Doptimize=ReleaseFast` would
catch it, and the build does accept that flag.

**Fixes tried and rejected** (all still fold, all measured, none shipped):

| Approach | Result |
|---|---|
| `asm volatile ("" ::: .{ .memory = true })` around each read | 0 ns — a memory clobber does not stop a pure-register CSE |
| `@call(.never_inline, ...)` wrapper | 0 ns — LLVM infers `readnone` from the body at `-O` |
| Indirect through a function pointer | 0 ns — the global is never mutated, so it is constant-propagated |
| `mach_absolute_time` directly | still folds, and the timebase conversion is fragile |

What remains is an architecture-specific non-foldable counter — `rdtsc` on
x86_64, `cntvct_el0` on aarch64 — read through inline `asm volatile` with an
output operand, which LLVM cannot fold by construction. That is a real change to
the platform layer that every benchmark depends on, and **it has not been
written**: it cannot be validated on Linux from this machine (no qemu, no
container, no Linux host), and shipping an unverified timing primitive would be
worse than the bug, because it would fail silently in the same way.

**Write throughput meets its amended target; the old 10,000 figure did not.**
The release target is now 1,750 cells/sec sustained, judged on the
worst window, amended
2026-10-15 (see
[`docs/constitution-amendments/2026-10-15-write-throughput-target.md`](docs/constitution-amendments/2026-10-15-write-throughput-target.md)). Measured on the durable path (every write encoded,
WAL-journalled with an fsync per record, and indexed), across four runs of
`./scripts/verify.sh`: **2,779 / 3,028 / 3,800 / 3,898 cells/sec**. Report the
range, not the best one — the spread is nearly 40% run to run.

The cause is **HNSW insert, not fsync**, and that attribution has been measured
rather than assumed: a phase profile of the write pipeline puts `hnsw.insert` at
~55% of the cost and the embedder at ~42%, with the `Store`'s own code under 3%.
Group commit does not move this number (`--wal-sync=group` was measured against
it and sat inside run-to-run noise). A cheaper insert path would.

The embedder share is smaller than it looks, and **an earlier revision of this
document got the reason wrong by two orders of magnitude.** It claimed that at
realistic episode lengths (94–384 bytes) "about 97%" of the embedder is the
384-dimension f32 allocation and the memset. A length sweep from 1 to 384 bytes
does not support that. Fixed overhead — the 12 KB `TermTable` zero-init, the
512-slot scan, and the 1,536-byte allocation plus memset — measures **~2 µs**,
while everything above it is **linear at ~438 ns per input byte**:

| input | 1–4 B | 8 B | 32 B | 94 B | 384 B |
|---|---|---|---|---|---|
| `LexicalEmbedder.embed` p50 | ~2,000 ns | 4,000 ns | 15,000 ns | 41,000 ns | 170,000 ns |

So the allocation is ~5% at 94 B and ~1% at 384 B, not 97%. The actual cost is
`LowerHasher`, which constructs an `XxHash3` per character 3-gram. This was
confirmed the hard way: a caller-owned output buffer (the change the 97% claim
was motivating) was implemented, proven bit-identical by fingerprint, measured
across interleaved A/B rounds at all four lengths, and came out **1.8–3.6%
slower** at every one of them. It was reverted. `src/retrieval/embedder.zig` is
byte-identical to the pre-experiment state.

The earlier 13–40% regression in that paragraph is a separate, still-valid
result: hoisting the per-position hash seed is provably bit-identical and
strictly less work, and it was also slower, because it defeated inlining.
Neither experiment changed the bit pattern; both changed the wall clock.

**The local offline LongMemEval re-implementation reads 0.729 core / 0.708 padded (table below), and the embedder is not what limits it.** The earlier figure of 0.646 / 0.000 predates the BM25 arm. For retrieval measured on the *official* dataset, see [`docs/benchmarks/longmemeval-official.md`](docs/benchmarks/longmemeval-official.md).
Run `./zig-out/bin/mem3-bench longmemeval`. This is an **offline
re-implementation of the LongMemEval protocol, not the official benchmark** — a
locally generated case set, a deterministic surface reader, no LLM judge, no
network. The output says so in a `disclaimer` field every run. Against the
constitutional ≥80% target it reports `met_target: false`.

Both arms were re-measured on the same tree, same seed (`--seed=42`), with the
BM25 sparse arm active. The external arm is `sentence-transformers/all-MiniLM-L6-v2`
(ONNX, run locally via `onnxruntime`) behind
[`scripts/embedder_adapter_example.py`](scripts/embedder_adapter_example.py);
**it is not a boundary in the abstract** — that script is the whole of the
integration.

| Configuration | Cells | built-in comb. | built-in retr. | MiniLM comb. | MiniLM retr. |
|---|---|---|---|---|---|
| core, no distractor padding | 144 | **0.7292** | 0.9896 | 0.7188 | 1.0000 |
| quarter padding | 1,144 | **0.7188** | 0.9896 | 0.7083 | 0.9896 |
| full padding | 4,144 | **0.7083** | 1.0000 | 0.7083 | 0.9688 |
| full padding, hypergraph disabled | 4,144 | **0.6979** | 1.0000 | 0.6979 | 0.9688 |

Two things in that table are worth more than the numbers themselves.

**The padded configurations are no longer at zero, and BM25 is why.** Before the
lexical arm landed, the same benchmark reported 0.0417 for full padding and a
retrieval hit rate of 0.0729 — the query stopped finding its answer entirely as
the store grew. Both arms now sit at 0.7083 with a hit rate of 1.0000. The
previous README attributed that collapse to `lexical_hash` never placing a
question and its answer in the same neighbourhood. **That diagnosis was wrong**:
HNSW recall at 4k cells was never the problem, and a 0.0729 hit rate was the
signature of a missing lexical path, not a failing graph.

**A real semantic embedder bought nothing here.** `exhaustive_nn_hit_rate` — the
index-independent score of whether the gold cell is the exact cosine nearest
neighbour over every vector — moves from 0.6042 to **0.7812**, so the stronger
embedder demonstrably places better. End-to-end combined accuracy does not
follow: it is flat to within 0.01 on every configuration, and slightly *lower*
on core. With a lexical arm in the fusion, this benchmark's ceiling is not the
embedding. Anyone reaching for a semantic model to move this number should read
that first. (`.onnx_external` remains reserved and returns
`error.UnsupportedEmbedder`; `--embedder-cmd` is the path that works.)

## License

MIT — see [`LICENSE`](LICENSE).

## Further reading

| Document | Contents |
|---|---|
| [`AGENTS.md`](AGENTS.md) | Project status, conventions, file map, roadmap |
| [`docs/roadmap.md`](docs/roadmap.md) | What is deferred, why, and what it would cost |
| [`docs/adr/`](docs/adr/) | Four decision records: ontology, GHW mapping, HNSW, WAL |
| [`docs/constitution-amendments/2026-10-14-platform-scope.md`](docs/constitution-amendments/2026-10-14-platform-scope.md) | Why Windows and WASM are refused at compile time |
| [`docs/releases/v0.1.0-alpha.md`](docs/releases/v0.1.0-alpha.md) | Original release notes — **their performance claims are unmeasured and contradicted by `zig build bench`; ignore the numbers there** |
| [`bench/main.zig`](bench/main.zig) | The benchmark harness and its honesty rules |
| [`examples/longrun.zig`](examples/longrun.zig) | The long-run lifecycle baseline harness |
