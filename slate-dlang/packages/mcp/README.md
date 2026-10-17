# `slate:mcp` — Embedded Model Context Protocol (MCP) & Agent Automation

`slate:mcp` is the Slint-independent automation and protocol DUB subpackage of [`slate-dlang`](../../README.md). It provides an embedded JSON-RPC 2.0 **Model Context Protocol (MCP)** server (`slate.mcp`) and the core UI inspection/automation engine (`slate.agent`), depending only on `slate:core`.

---

## Key Modules (`source/slate/`)

| Module | File | Description |
|---|---|---|
| `slate.mcp.server` | [`source/slate/mcp/server.d`](source/slate/mcp/server.d) | Embedded JSON-RPC 2.0 MCP server dispatching `initialize`, `tools/list`, `tools/call`, `resources/list`, and `resources/read` |
| `slate.mcp.protocol` | [`source/slate/mcp/protocol.d`](source/slate/mcp/protocol.d) | JSON-RPC 2.0 request/response framing, error codes, and payload parsing |
| `slate.mcp.schema` | [`source/slate/mcp/schema.d`](source/slate/mcp/schema.d) | Tool schemas for `inspect_tree`, `click_element`, `send_keys`, `get_state`, `set_property`, `invoke_action`, and `get_screenshot` |
| `slate.mcp.resources` | [`source/slate/mcp/resources.d`](source/slate/mcp/resources.d) | Bounded ring-buffer application log and state resources (`slate://logs`, `slate://state`) |
| `slate.mcp.stdio` | [`source/slate/mcp/stdio.d`](source/slate/mcp/stdio.d) | Non-blocking line-delimited stdio and fiber transport loop |
| `slate.agent.engine` | [`source/slate/agent/engine.d`](source/slate/agent/engine.d) | `AutomationEngine` coordinating semantic tree inspection, element interaction, state queries, and screenshots |
| `slate.agent.declarative` | [`source/slate/agent/declarative.d`](source/slate/agent/declarative.d) | `McpStateRegistry` managing registered `McpControllable` controllers, snapshots, mutations, and action dispatch |
| `slate.agent.tree` / `model` | [`source/slate/agent/tree.d`](source/slate/agent/tree.d) | Semantic UI accessibility tree nodes, bounding boxes (`geometry.d`), and query filters |

---

## Build & Test

```bash
# From repository root:
just slate-test-mcp

# Or directly via DUB:
cd slate-dlang && dub test :mcp
```
