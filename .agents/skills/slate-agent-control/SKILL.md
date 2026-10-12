---
name: slate-agent-control
description: "Inspect, interact with, automate, and capture visual snapshots of Slate desktop applications using the native Model Context Protocol (MCP) toolset and `slate-mcp` CLI helper."
allowed-tools: [shell, read_file]
---

# Slate Agent Remote Control & Automation

This skill guides AI agents and developers in inspecting, controlling, and visually verifying Slate desktop applications (built on Slint) using the native Model Context Protocol (MCP) layer.

## Architecture Overview

Slate applications can embed an autonomous agent interface via two workspace crates:
- **`slate-agent`**: Core traits (`UiInspector`, `ElementController`, `StateProvider`, `VisualRenderer`, `AutomationEngine`) and non-blocking `SlintUiBridge` that offloads image compression from the UI loop.
- **`slate-mcp`**: Asynchronous JSON-RPC 2.0 MCP server and client, supporting stdio pipes, in-memory duplex streams, and the `slate-mcp` CLI helper binary.

---

## MCP Tools Reference

Every Slate application with agent support exposes the standard 5 MCP tools:

| Tool | Parameters | Description |
|---|---|---|
| `inspect_tree` | `root_id?: string` | Returns the hierarchical UI element tree with accessible IDs, roles, bounding rects (`x, y, width, height`), and labels. Declare `accessible-id` on every interactive component (via its `automation-id` property): nodes without one get suffixed unstable IDs (`id_stable: false`, display-only, never store them), and duplicate `accessible-id`s fail the whole inspection (W2 deny-the-tree). |
| `click_element` | `id?: string`, `x?: number`, `y?: number`, `button?: "left"\|"right"\|"middle"`, `click_count?: 1\|2` | Simulates pointer click at target element center or exact coordinates. |
| `send_keys` | `text: string`, `element_id?: string`, `clear_first?: boolean` | Types text into active or targeted editable text field. |
| `get_screenshot` | `mime_type?: "image/png"` | Captures rendered window frame without freezing the UI event loop (~2ms raw capture, background PNG compression). Returns PNG base64. |
| `get_state` | `keys?: string[]` | Queries application diagnostic metrics (heap, fps, uptime) and custom domain state, filtered to `keys` (legacy single-`query` string still accepted server-side, deprecated). |

### MCP Live Resources

- **`slate://app/context`**: Metadata including app name, version, Slate framework version, active theme, window dimensions, and agent capabilities.
- **`slate://logs/live`**: Real-time event log recording all user and agent interactions.

---

## The `slate-mcp` CLI Helper

The repository includes a native Rust CLI binary `slate-mcp` (built at `slate-rust/target/debug/slate-mcp` via `cargo build -p slate-mcp` inside `slate-rust/`; source at `slate-rust/mcp/src/bin/slate_mcp.rs`). It acts as both a CLI controller and an stdio MCP proxy.

### Common CLI Invocations

```bash
# Inspect the entire component tree
slate-mcp inspect

# Inspect a specific sub-tree
slate-mcp inspect --root tab_navigation

# Click a button or tab by accessible ID
slate-mcp click btn_increment
slate-mcp click tab_compute

# Click at specific window coordinates
slate-mcp click --x 120.5 --y 45.0

# Type text into an input field (optionally clearing it first)
slate-mcp type "admin@example.com" --target input_email --clear

# Capture screenshot and save directly to disk as PNG
slate-mcp screenshot --out /tmp/current_app_frame.png

# Query runtime state or metrics (canonical `keys` filter)
slate-mcp state --key counter
slate-mcp state

# List available MCP tools and resources
slate-mcp tools
slate-mcp resources
slate-mcp read slate://app/context

# Run as an stdio MCP server proxy (for Claude Desktop, Gemini, Cursor;
# paths relative to the workspace root):
slate-mcp serve --app ./slate-rust/target/debug/slate-showcase
```

### Options & Environment Flags

- `--app <PATH>`: Target application binary path (defaults to `target/debug/slate-showcase` or `$SLATE_APP_BIN`).
- `--app-arg <ARG>`: Pass extra command-line arguments to the target process.
- `--headless`: Run offscreen using the Slint software backend (default in headless / non-DISPLAY environments).
- `--gui`: Display the visible desktop window.
- `--timeout <SECS>`: Request timeout duration (default: 15s).
- `--json`: Output raw JSON response payloads.

---

## Autonomous Agent Automation Loop (OODA)

When an agent is asked to perform a workflow in the desktop app (e.g., "Open the compute tab, start the calculation, and verify the result"):

1. **Observe**:
   - Run `slate-mcp inspect` to locate element IDs and current values.
   - Run `slate-mcp screenshot --out <path>` to observe visual layout and styling.
2. **Orient**:
   - Correlate element positions, accessible IDs (`id`), and roles (`button`, `input`, `text`).
3. **Decide & Act**:
   - Execute the action using `slate-mcp click <id>` or `slate-mcp type "<value>" --target <id>`.
4. **Verify**:
   - Re-inspect with `slate-mcp state` or `slate-mcp inspect --root <id>` to ensure the change was committed.
   - Capture a follow-up screenshot if visual confirmation is required.

---

## App Developer Guide: Adding Agent Support

To make any Slate/Slint application controllable by agents:

### 1. Minimal 1-Line Setup
In `main.rs`:
```rust
let main_window = MainWindow::new()?;
let _agent = slate::agent::init(&main_window)?;
main_window.run()?;
```

### 2. Custom Builder Setup
For custom state, custom action hooks, and custom renderers:
```rust
let _agent = slate::agent::builder(&main_window)
    .with_name("My Custom App")
    .with_state_provider(my_state_provider)
    .with_controller(my_controller)
    .with_inspector(my_inspector)
    .with_renderer(my_renderer)
    .with_mcp_stdio()
    .start()?;
```
