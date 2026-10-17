# Slate-DLang (`slate-dlang`)

Declarative desktop UI, SolidJS cross-compiler, networking, and Model Context Protocol (MCP) framework in DLang, organized into 5 layered DUB sub-packages under the MIT License:

- **`slate:core`** ([`packages/core`](packages/core)): Foundational themes, tasks, worker thread dispatch, controllers, platform integration, plugins, Monte Carlo demo, SVG chart utilities (`slate.utils.chart`), and agent capability traits (`@safe`, total purity, zero external dependencies).
- **`slate:net`** ([`packages/net`](packages/net)): Full QUIC (RFC 9000/9001/9002) client stack, HTTP/1.1, HTTP/2, and HTTP/3 client engines, async task bridges, and `durl` CLI tool (depends only on `slate:core` and system `curl`, `ssl`, `crypto`).
- **`slate:mcp`** ([`packages/mcp`](packages/mcp)): Embedded Model Context Protocol (MCP) JSON-RPC 2.0 server, schema definitions, tool handlers, bounded log resources, stdio/fiber transports, and agent automation engine (`AutomationEngine`, `ComponentBridge`, `McpStateRegistry`) (depends only on `slate:core`, 100% Slint-free).
- **`slate:ui`** ([`packages/ui`](packages/ui)): Application builder (`AppBuilder`), Slint desktop component controllers (`DataGridController`, `MediaPlayerController`, `UploadQueueController`, `FileDialogController`, `WorkspaceDockController`, `MasterDetailController`, `WizardController`, `RingBufferLogModel`), `SlintUiInspector`, `SlintElementController`, `SlintVisualRenderer`, and end-to-end MCP UI integration tests (depends on `slate:core`, `slate:mcp`, and `slint-d`).
- **`slate:solid`** ([`packages/solid`](packages/solid/README.md)): Standalone `.slint` + Dlang to SolidJS (`.tsx`) and TypeScript (`.ts`) cross-compiler library and `slint2solid` CLI. Compiles all 64 `.slint` components in `ui/` and transpiles Dlang controllers into reactive SolidJS components and TypeScript classes with an in-browser MCP JSON-RPC 2.0 server (depends on `slate:core`, `slate:mcp`, and `slate:ui`; zero native `libslint_d_bridge` runtime link required).

## Sub-Package Layer Map

```
┌───────────────────────────────────┐    ┌───────────────────────────────────┐
│             slate:ui              │    │            slate:solid            │
│ (AppBuilder, Slint Controllers,   │◄───│ (.slint + Dlang -> SolidJS .tsx   │
│  Slint Native Backends)           │    │  & TypeScript Cross-Compiler CLI) │
└───────────┬───────────────┬───────┘    └─────────────────┬─────────────────┘
            │               │                              │
            ▼               │                              │
┌────────────────────────┐  │                              │
│       slate:mcp        │◄─┼──────────────────────────────┘
│ (MCP JSON-RPC, Engine) │  │
└───────────┬────────────┘  │
            │               │
            ▼               ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                                 slate:core                                 │
│            (Themes, Tasks, Dispatch, Controllers, Traits, Chart)           │
└────────────────────────────────────────────────────────────────────────────┘
            ▲
            │
┌───────────┴────────────┐
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
just slate-test-solid      # Test slate:solid (.slint + D -> SolidJS compiler + Node runtime)
just solid-codegen         # Run slint2solid CLI to compile ui/ + controllers -> target/solid-ui/
just slate-test            # Test full slate umbrella package (pure D)
just slate-test-native     # Test full slate umbrella package (SlintNative)
just d-lint                # Run dscanner syntax + style checks
just d-fmt                 # Format all .d files via dfmt
```

Or via direct `dub` commands:

```sh
cd slate-dlang

# Test individual sub-packages
dub test :core
dub test :net
dub test :mcp
dub test :ui
dub test :solid
LD_LIBRARY_PATH="$PWD/../slint-d/bridge/target/debug:$LD_LIBRARY_PATH" SLINT_BACKEND=software dub test :ui --config=native

# Run the slint2solid CLI cross-compiler
dub run :solid --config=slint2solid -- --ui-dir=../ui --out-dir=../target/solid-ui

# Test umbrella slate package
dub test
LD_LIBRARY_PATH="$PWD/../slint-d/bridge/target/debug:$LD_LIBRARY_PATH" SLINT_BACKEND=software dub test --config=native
```

## License

MIT License. See [LICENSE](LICENSE) for details.
