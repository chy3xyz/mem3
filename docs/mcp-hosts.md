# MCP hosts: what has actually run against `mem3 mcp`

This page records which real MCP clients have been driven against `mem3 mcp`,
which have not, and how to check the rest yourself. It exists because
`scripts/mcp_conformance.py` is written by the same hands as the server and
cannot catch a shared misreading of the spec (see its docstring). A row is
**VERIFIED** only if the client was actually executed and its wire traffic was
captured. Everything else is **NOT VERIFIED**, with the reason.

Last run: **2026-10-21**, macOS (darwin 27, arm64), Zig 0.17.0.
Binary under test: `zig build -Doptimize=ReleaseFast` (963,704 B). The session
was repeated against a clean `git archive HEAD` build (commit `b23b48e`) for
Inspector and the conformance script, with identical results, so the evidence
does not depend on other people's uncommitted edits.

## Status

| Host | Version | Status | What was exercised |
|---|---|---|---|
| MCP Inspector CLI (`@modelcontextprotocol/inspector --cli`) | 2.11.0 (official TypeScript SDK client) | **VERIFIED** | `initialize` → `tools/list` (5 tools) → `tools/call` `memory_add`, `memory_query`, `memory_stats`, `goal_list`, `memory_forget` (default dry-run). All `isError:false`. |
| Claude Code (CLI, headless `claude -p`) | 2.1.289 | **VERIFIED** | Server `connected`; 5 tools surfaced as `mcp__mem3__*`; the model called `memory_add` → `memory_query` → `memory_stats`; all results returned, `isError:false`. The query returned the cell just added. |
| Cursor (`cursor-agent` CLI, `.cursor/mcp.json`) | 2026.10.21-d4ecfdc (wire `clientInfo`: `Cursor` / `1.0.0`) | **VERIFIED** (CLI agent only) | `initialize` → `tools/list` → `memory_add` → `memory_query` → `memory_stats`, all `isError:false`. **This is the Cursor CLI agent, not the Cursor IDE app** (`/Applications/Cursor.app` is installed but was not driven; it shares the config file format but not necessarily the client code). |
| opencode | v2.0.32 | **PARTIAL — handshake + `tools/list` only** | `opencode mcp list` shows `mem3 connected`; wire log shows `initialize` and `tools/list` answered. **No `tools/call` was made**: `opencode run` died with `provider.transport: ConnectionRefused` talking to its configured LLM gateway (`9router/...`), before any tool call. Do not count this as a verified tool session. |
| Gemini CLI | 0.49.0 | NOT VERIFIED | Needs auth (`GEMINI_API_KEY` / Vertex / GCA); headless run exits 41 with "Please set an Auth method". `gemini mcp list` shows the server as `Disabled` (workspace untrusted) and never spawned it. No handshake occurred. |
| Codex CLI | — | NOT VERIFIED | `codex` is not installed on this machine (a `~/.codex` directory exists, the binary does not). Not run through `npx` to avoid using stored credentials. |
| Claude Desktop | — | NOT VERIFIED | Not installed (no `/Applications/Claude.app`, no `~/Library/Application Support/Claude`). |
| Cursor IDE (GUI) | — | NOT VERIFIED | Installed, but a GUI cannot be driven non-interactively here. The CLI agent row above is the closest evidence. |
| Any other host (Windsurf, Zed, VS Code, ChatGPT, ...) | — | NOT VERIFIED | Not available. |

### What the verified sessions do and do not show

- **Protocol era.** All three clients opened with the *legacy* handshake and
  `protocolVersion: "2025-11-25"` and mem3 answered `2025-11-25`. **No real
  client sent the modern `2026-07-28` per-request `_meta` form**, so the
  modern branch of the dual-era server (`server/discover`, `resultType`) still
  has *only* conformance-script evidence. The other three legacy revisions
  (`2025-06-18`, `2025-03-26`, `2024-11-05`) were not offered by any client.
- **Pipelined calls.** Claude Code and Cursor sent `tools/call` ids 2, 3, 4
  back-to-back without waiting for responses; mem3 answered each in order with
  its id echoed. Claude Code also attached `_meta.progressToken` and
  `claudecode/toolUseId`; ignoring them was fine.
- **Surface.** Only the `tools` capability was exercised. Resources, prompts,
  logging, cancellation, progress notifications, and elicitation were not.
- **The LLM is not the evidence.** For Claude Code the model backend was the
  machine's configured gateway (reported as `MiniMax-M2.7`); for Cursor it was
  `Claude Sonnet 5.5`. The evidence is the captured JSON-RPC wire log, not what
  the model said.
- **Persistence.** Inspector spawns a fresh `mem3 mcp` per invocation; a
  `memory_add` in one process was returned by `memory_query` in the next, so
  the WAL-backed store round-trips across real client sessions.
- **No bugs in `src/mcp/` were found** by any of these clients. Nothing was
  changed under `src/`.

### Wire transcript (Claude Code 2.1.289, abridged only by truncating long strings)

```text
C->S {"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"roots":{"listChanged":true},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"claude-code","title":"Claude Code","version":"2.1.289",...}},"jsonrpc":"2.0","id":0}
C->S {"jsonrpc":"2.0","method":"notifications/initialized"}
C->S {"method":"tools/list","jsonrpc":"2.0","id":1}
C->S {"method":"tools/call","params":{"name":"memory_add","arguments":{"episode":"Bob migrated the billing service to Postgres in March","source":"form","facts":["bob|migrated|billing service"],"goal_ids":[1],"relevances":[0.9]},"_meta":{"claudecode/toolUseId":"...","progressToken":2}},"jsonrpc":"2.0","id":2}
C->S {"method":"tools/call","params":{"name":"memory_query","arguments":{"query":"who migrated billing","topk":3},"_meta":{...,"progressToken":3}},"jsonrpc":"2.0","id":3}
C->S {"method":"tools/call","params":{"name":"memory_stats","arguments":{},"_meta":{...,"progressToken":4}},"jsonrpc":"2.0","id":4}
S->C {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"mem3","version":"0.1.0-alpha"}}}
S->C {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"memory_add",...},{"name":"memory_query",...},{"name":"goal_list",...},{"name":"memory_forget",...},{"name":"memory_stats",...}]}}
S->C {"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"id\":4,\"source\":\"form\",\"cells\":1}"}],"isError":false}}
S->C {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{\"query\":\"who migrated billing\",\"count\":1,\"results\":[{\"id\":4,\"source\":\"form\",\"episode\":\"Bob migrated the billing service to Postgres in March\",\"score\":0.8169230818748474,\"base_score\":0.5476824045181274,\"importance\":0.809999942779541,\"created_at\":1792572410163}]}"}],"isError":false}}
S->C {"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"{\"cells\":1,\"cells_by_source\":{\"matter\":0,\"form\":1,\"spirit\":0},\"vector_index\":{\"nodes\":1,\"max_level\":0,\"dim\":384},\"goals\":3,\"harnesses\":1,\"world_entities\":1,\"hyperedges\":0,\"fuzzy\":0,\"durable\":true,\"approx_cell_bytes\":101}"}],"isError":false}}
```

Inspector 2.11.0 and the Cursor CLI produced the same shape (`initialize` with
`protocolVersion: "2025-11-25"`, `clientInfo` `inspector-cli`/`2.11.0` and
`Cursor`/`1.0.0` respectively) and the same server replies.

### How these runs were done (reproduce)

Every run used a throw-away data directory under `/tmp`, a per-run config file
(never a global one), and a tee wrapper to capture the wire. The wrapper:

```bash
#!/bin/bash
# wrap.sh <label> <data-dir>  — logs both directions to /tmp/wire-<label>.log
L=/tmp/wire-$1.log
tee >(sed 's/^/C->S /' >> "$L") | /path/to/mem3 mcp --data-dir="$2" | tee >(sed 's/^/S->C /' >> "$L")
```

Point the host's `command` at `wrap.sh` (args: label, data dir) instead of at
`mem3` to record a transcript, then read the log.

```bash
# MCP Inspector (read-only config file, so ~/.mcp-inspector is not written)
echo '{"mcpServers":{"mem3":{"command":"/path/to/mem3","args":["mcp","--data-dir=/tmp/m3"]}}}' > /tmp/insp.json
npx -y @modelcontextprotocol/inspector --cli --config /tmp/insp.json --server mem3 --method tools/list
npx -y @modelcontextprotocol/inspector --cli --config /tmp/insp.json --server mem3 --method tools/call \
  --tool-name memory_add --tool-arg episode="Alice deployed the daemon" source=form \
  'facts=["alice|deployed|daemon"]' 'goal_ids=[1]' 'relevances=[0.9]'

# Claude Code, no global/project config touched
claude -p "Using ONLY the mem3 MCP tools: memory_add, then memory_query, then memory_stats" \
  --mcp-config /tmp/mcp.json --strict-mcp-config --allowedTools 'mcp__mem3__*' \
  --permission-mode dontAsk --output-format stream-json --verbose --no-session-persistence

# Cursor CLI agent: needs .cursor/mcp.json in the working directory
cursor-agent -p --trust --approve-mcps --output-format stream-json "<same prompt>"
```

## Config snippets

Replace `/ABS/PATH/mem3` and the data directory. Use **absolute paths**: hosts
do not launch the server from your shell's working directory, and a relative
`--data-dir` would silently create a fresh empty store somewhere else.
The server writes nothing to stderr and nothing but JSON-RPC to stdout.

Claude Desktop — `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS) or `~/.config/Claude/claude_desktop_config.json` (Linux). *Not verified
by us.* Restart the app after editing.

```json
{
  "mcpServers": {
    "mem3": {
      "command": "/ABS/PATH/mem3",
      "args": ["mcp", "--data-dir=/ABS/PATH/mem3-data"]
    }
  }
}
```

Claude Code — verified. Project scope writes `.mcp.json` in the repo root:

```bash
claude mcp add --scope project mem3 -- /ABS/PATH/mem3 mcp --data-dir=/ABS/PATH/mem3-data
claude mcp list        # mem3 should be reported as connected
```

or write `.mcp.json` by hand with the same `mcpServers` object as above.

Cursor — `.cursor/mcp.json` (project) or `~/.cursor/mcp.json` (global). Verified
with the CLI agent; the IDE reads the same file. The CLI shows
`mem3: not loaded (needs approval)` until you approve it (`cursor-agent mcp
enable mem3`, or the approval prompt in the IDE).

```json
{
  "mcpServers": {
    "mem3": {
      "command": "/ABS/PATH/mem3",
      "args": ["mcp", "--data-dir=/ABS/PATH/mem3-data"]
    }
  }
}
```

Codex — `~/.codex/config.toml`. *Not verified by us* (not installed). The
`codex mcp add` form below is the CLI equivalent.

```toml
[mcp_servers.mem3]
command = "/ABS/PATH/mem3"
args = ["mcp", "--data-dir=/ABS/PATH/mem3-data"]
```

```bash
codex mcp add mem3 -- /ABS/PATH/mem3 mcp --data-dir=/ABS/PATH/mem3-data
```

Gemini CLI — `.gemini/settings.json` (project) or `~/.gemini/settings.json`;
`gemini mcp add --scope project mem3 /ABS/PATH/mem3 mcp --data-dir=...` writes
exactly this shape. *Not verified* (auth). Gemini marks servers in untrusted
folders `Disabled`; trust the folder or pass `--skip-trust`.

```json
{ "mcpServers": { "mem3": { "command": "/ABS/PATH/mem3", "args": ["mcp", "--data-dir=/ABS/PATH/mem3-data"] } } }
```

opencode 2.x — project `opencode.json`. This is the shape `opencode mcp add`
wrote in v2.0.32 and it is the one that loaded. The older v1-style
`{"mcp":{"mem3":{"type":"local","command":[...]}}}` was **not** picked up by
v2.0.32 (`opencode mcp list` said "No MCP servers configured").

```json
{
  "mcp": {
    "servers": {
      "mem3": {
        "type": "local",
        "command": ["/ABS/PATH/mem3", "mcp", "--data-dir=/ABS/PATH/mem3-data"]
      }
    }
  }
}
```

## Verify it yourself in 5 minutes (hosts not run above)

1. Build: `zig build -Doptimize=ReleaseFast`, then note the absolute path of
   `zig-out/bin/mem3`. Sanity: `python3 scripts/mcp_conformance.py` must print
   `56/56 checks passed`.
2. Pick a scratch store: `mkdir -p /tmp/mem3-host-test`. Never point a first
   trial at a store you care about.
3. Add the config snippet for your host above, restart the host fully, and
   (for Claude Desktop / Cursor IDE) check its MCP/Connectors settings page
   shows `mem3` as connected with **5 tools**: `memory_add`, `memory_query`,
   `goal_list`, `memory_forget`, `memory_stats`. A red/errored state with no
   tools is the failure you are looking for. Host logs: Claude Desktop
   `~/Library/Logs/Claude/mcp-server-mem3.log`; Claude Code `claude --debug`.
4. Ask the host, in one message: *"Use the mem3 tools: call memory_add with
   episode='the build bot rotated the signing key', source='form',
   facts=['bot|rotated|signing key'], goal_ids=[1], relevances=[0.9]; then
   memory_query for 'who rotated the key'; then memory_stats."* Pass criteria:
   all three calls succeed, the query returns the cell you just added, and
   stats shows `cells: 1`.
5. Confirm persistence: quit the host, relaunch, ask for `memory_stats` —
   `cells` must still be 1. Then run `./zig-out/bin/mem3 dump --data-dir=/tmp/mem3-host-test`
   from a shell; the cell must be there (CLI and MCP share one store).
6. Optional: tee the wire with the wrapper above and look at the first line.
   If the host sends `protocolVersion` in `initialize`, that is the legacy
   era; if instead every request carries
   `_meta["io.modelcontextprotocol/protocolVersion"]` and the host calls
   `server/discover`, you have the first real-client evidence for the modern
   `2026-07-28` path — please record that here.
7. Record the host name, exact version, date, and what you ran in the Status
   table. Mark only what you actually ran as VERIFIED.

If something fails, capture the wire log and the first response mem3 sent; a
response that is not one line of valid JSON, or output on stderr, is a mem3
bug, not a host bug.
