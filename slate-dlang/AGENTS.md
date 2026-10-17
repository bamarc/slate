# AGENTS.md — `slate-dlang` Framework Instructions

This directory contains **`slate-dlang`** (`dub` package `slate`), the core Dlang desktop UI, networking, MCP automation, and SolidJS cross-compiler framework.

---

## 1. Subpackage Architecture & Strict Dependency Rules

`slate-dlang` is divided into 5 DUB subpackages under `packages/`. **Never introduce circular or upward dependencies across layers:**

| Subpackage | Path | Allowed Dependencies | Purpose |
|---|---|---|---|
| **`slate:core`** | [`packages/core/`](packages/core/README.md) | **Zero external dependencies** (Phobos + druntime only) | Themes, tasks (`spawnCompute`), cancellation tokens, controllers, plugins, SVG chart paths (`slate.utils.chart`), and MCP capability traits (`slate.agent.traits`) |
| **`slate:net`** | [`packages/net/`](packages/net/README.md) | `slate:core` + system `libcurl`, `libssl`, `libcrypto` | Pure-D sans-I/O QUIC (`slate.quic`, RFC 9000/9001/9002), HTTP/1.1, HTTP/2, HTTP/3 (`slate.http`), QPACK, and `durl` CLI |
| **`slate:mcp`** | [`packages/mcp/`](packages/mcp/README.md) | `slate:core` (**100% Slint-free**) | Embedded MCP JSON-RPC 2.0 server (`slate.mcp`), tool/resource schemas, stdio/fiber transports, and `AutomationEngine` / `McpStateRegistry` (`slate.agent`) |
| **`slate:ui`** | [`packages/ui/`](packages/ui/README.md) | `slate:core`, `slate:mcp`, `slint-d` | `AppBuilder`, Slint UI controllers (`DataGridController`, `MediaPlayerController`, `UploadQueueController`, `FileDialogController`, `WorkspaceDockController`, `MasterDetailController`, `WizardController`, `RingBufferLogModel`), and native Slint MCP backends (`slate.agent.slint_backend`) |
| **`slate:solid`** | [`packages/solid/`](packages/solid/README.md) | `slate:core`, `slate:mcp`, `slate:ui` (pure-D `library` config; **no native `libslint_d_bridge` link**) | Standalone `.slint` + Dlang controller to SolidJS (`.tsx`) and TypeScript (`.ts`) cross-compiler (`slint2solid`). See [`packages/solid/AGENTS.md`](packages/solid/AGENTS.md) |

The root `source/slate/package.d` umbrella module re-exports the subpackages.

---

## 2. Dlang Coding Standards

- **Memory Safety & Attributes**: Mark functions `@safe` by default (`@trusted` only around audited FFI boundaries with a comment explaining why the call is memory-safe). Use `nothrow`, `pure`, and `@nogc` where applicable.
- **Design by Contract (DbC)**: Use `in (...)` and `out (...)` contracts on public controller and protocol APIs to enforce invariants.
- **Naming Conventions**:
  - Modules & packages: `snake_case` matching filesystem path (`module slate.components.file_dialog;`).
  - Types, classes, structs, interfaces, enums, UDAs: `PascalCase` (`FileDialogController`, `McpControllable`, `@McpProperty`).
  - Functions, methods, properties, variables: `camelCase` (`mcpSetProperty`, `selectById`).
  - Constants & enum members: `camelCase` or `PascalCase` per [`../../dscanner.ini`](../../dscanner.ini).
- **Formatting & Linting**:
  - Always run `just d-fmt` (`dfmt`) and `just d-lint` (`dscanner --syntaxCheck` + `--styleCheck`) after editing `.d` files.

---

## 3. Declarative MCP Controller Conventions

When creating or modifying UI controllers in `packages/ui/source/slate/components/`:
1. Implement `McpControllable` (from `slate.agent.traits`) and any applicable capability interfaces (`McpBindable`, `McpSeekable`, `McpSortable`, `McpFilterable`, `McpExpandable`, `McpDropReceiver`, `McpSelectable`), or register a plain class/struct directly via `registry.register("namespace", target)`.
2. Mix in `mixin McpControllableMixin!"namespace";` for automatic compile-time `__traits` introspection, state snapshotting (`mcpSnapshot`), and transactional property mutation with rollback on validation error (`mcpSetProperty` / `mcpRestoreSnapshot`).
3. Public fields and methods are introspected automatically (opt-out with `@McpIgnore`, or customize aliases with `@McpState`, `@McpWritable`, `@McpAction`).
4. Keep controller methods compatible with [`packages/solid/AGENTS.md`](packages/solid/AGENTS.md) if the controller is cross-compiled to TypeScript by `slate:solid`.

---

## 4. Testing Conventions

- **TDD & Spec Annotations**: Every behavior change requires a `unittest` annotated with `// Spec:` and `/// Example:`.
- **Pure-D vs Native Tests**:
  - Pure-D tests must run without linking `libslint_d_bridge` (`just slate-test`, `just slate-test-core`, `just slate-test-net`, `just slate-test-mcp`, `just slate-test-ui`, `just slate-test-solid`).
  - Gate tests that instantiate live Slint windows behind `version (SlintNative)` and run them via `just slate-test-ui-native` or `just slate-test-native` (`SLINT_BACKEND=software`).
