//! mem3 MCP server (Model Context Protocol over stdio).
//!
//! ## Why this module exists
//!
//! mem3 had a CLI and an HTTP daemon and therefore no distribution
//! channel: the market for a memory tool is reached through MCP, and
//! nothing about `mem3 serve` speaks it. This is the surface that lets
//! Claude Code — or any other MCP client — attach mem3 as a tool
//! server and keep a real tri-source memory between sessions.
//!
//! ## Layering
//!
//! Each file declares its GHW layer (Constitution II):
//!
//! | File         | Layer | Role |
//! |--------------|-------|------|
//! | `json.zig`   | Harness (form) | parse an incoming envelope |
//! | `framing.zig`| Harness (form) | decide what a *message* is |
//! | `protocol.zig`| Harness (form) | JSON-RPC validation and response shapes |
//! | `tools.zig`  | all three      | the tools, which cross Goal → Harness → World inside `Store` |
//! | `json_out.zig`| Harness (form) | response writing and float safety |
//! | `server.zig` | Harness (form) | the stdio loop |
//!
//! No file here reaches into another layer's state: every memory
//! operation goes through `store.Store`, which owns the traversal.
//!
//! ## Transport
//!
//! stdio. One JSON-RPC message per line, `\n` terminated, on stdin and
//! stdout. stdout is protocol — nothing else is ever written there.
//!
//! ## Why the parser is hand-written
//!
//! Constitution IV (zero dependency) forbids adding an MCP or JSON library, and
//! `src/utils/jsonl.zig` is a *writer*. `json.zig` is the reader, with
//! two size caps, an explicit escape policy (unknown escapes are
//! preserved, never dropped — the `utils/logger.zig` bug) and a
//! documented zero-copy borrow for strings with no escapes.

pub const framing = @import("framing.zig");
pub const json = @import("json.zig");
pub const json_out = @import("json_out.zig");
pub const protocol = @import("protocol.zig");
pub const server = @import("server.zig");
pub const tools = @import("tools.zig");

pub const Server = server.Server;
pub const CATALOGUE = tools.CATALOGUE;
pub const PROTOCOL_VERSION = protocol.PROTOCOL_VERSION;
