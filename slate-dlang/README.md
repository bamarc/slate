# Slate-DLang (`slate-dlang`)

Declarative desktop UI, networking, and Model Context Protocol (MCP) framework in DLang, organized into 4 layered DUB sub-packages under the MIT License:

- **`slate:core`** (`packages/core`): Foundational themes, tasks, worker thread dispatch, controllers, platform integration, plugins, Monte Carlo demo, and utilities (`@safe`, total purity, zero external dependencies).
- **`slate:net`** (`packages/net`): Full QUIC (RFC 9000/9001/9002) client stack, HTTP/1.1, HTTP/2, and HTTP/3 client engines, async task bridges, and `durl` CLI tool (depends only on `slate:core` and system `curl`, `ssl`, `crypto`).
- **`slate:mcp`** (`packages/mcp`): Embedded Model Context Protocol (MCP) JSON-RPC 2.0 server, schema definitions, tool handlers, bounded log resources, stdio/fiber transports, and agent automation engine (`AutomationEngine`, `ComponentBridge`, `McpStateRegistry`) (depends only on `slate:core`, 100% Slint-free).
- **`slate:ui`** (`packages/ui`): Application builder (`AppBuilder`), Slint desktop component controllers (`DataGridController`, `MediaPlayerController`, `UploadQueueController`, `FileDialogController`, `WorkspaceDockController`, `MasterDetailController`, `WizardController`, `RingBufferLogModel`), `SlintUiInspector`, `SlintElementController`, `SlintVisualRenderer`, and end-to-end MCP UI integration tests (depends on `slate:core`, `slate:mcp`, and `slint-d`).

## Sub-Package Layer Map

```
┌────────────────────────────────────────────────────────┐
│                        slate:ui                        │
│  (AppBuilder, Slint Component Controllers, Backends)   │
└───────────────┬────────────────────────┬───────────────┘
                │                        │
                ▼                        │
┌────────────────────────┐               │
│       slate:mcp        │               │
│ (MCP JSON-RPC, Engine) │               │
└───────────────┬────────┘               │
                │                        │
                ▼                        ▼
┌────────────────────────────────────────────────────────┐
│                       slate:core                       │
│     (Themes, Tasks, Dispatch, Controllers, Utils)      │
└────────────────────────────────────────────────────────┘
                ▲
                │
┌───────────────┴────────┐
│       slate:net        │
│  (HTTP, QUIC, durl)    │
└────────────────────────┘
```

## Build & Test Commands

Use `just` recipes from repository root:

```sh
just slate-test-core       # Test slate:core (pure D)
just slate-test-net        # Test slate:net (HTTP + QUIC)
just slate-test-mcp        # Test slate:mcp (MCP JSON-RPC + agent automation)
just slate-test-ui         # Test slate:ui (pure-D UI component tests)
just slate-test-ui-native  # Test slate:ui native with Slint software renderer
just slate-test            # Test full slate umbrella package (pure D)
just slate-test-native     # Test full slate umbrella package (SlintNative)
```

Or via direct `dub` commands:

```sh
source ~/dlang/dmd-*/activate
cd slate-dlang

# Test individual sub-packages
dub test :core
dub test :net
dub test :mcp
dub test :ui
LD_LIBRARY_PATH="$PWD/../slint-d/bridge/target/debug:$LD_LIBRARY_PATH" SLINT_BACKEND=software dub test :ui --config=native

# Test umbrella slate package
dub test
LD_LIBRARY_PATH="$PWD/../slint-d/bridge/target/debug:$LD_LIBRARY_PATH" SLINT_BACKEND=software dub test --config=native
```

## License

MIT License. See [LICENSE](LICENSE) for details.
