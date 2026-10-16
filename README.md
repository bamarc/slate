# Slate — Declarative Desktop UI & Agent Framework in DLang + Slint

**Slate** is a declarative desktop UI and application framework written in **DLang** on top of **[Slint](https://slint.dev)**. It pairs Slint's GPU- and software-accelerated `.slint` markup with idiomatic D2 (`@safe`, RAII, compile-time reflection, fibers, and Design-by-Contract) and first-class, trait-driven **Model Context Protocol (MCP)** automation.

---

## Workspace Structure

| Path | Package / Layer | Description |
|------|-----------------|-------------|
| [`slate-dlang/`](slate-dlang/) | `slate` (DUB) | **Core DLang Framework**: `AppBuilder`, component controllers, declarative MCP traits & JSON-RPC 2.0 server, fiber task scheduling, and native QUIC / HTTP/3 networking |
| [`slint-d/`](slint-d/) | `slint-d` (DUB) | **DLang Slint Bindings**: Idiomatic D bindings over the Slint runtime (`Value`, `StructModel!T`, `TreeModel!T`, `WindowHandle`, callbacks, timers, and C-ABI bridge in [`slint-d/bridge/`](slint-d/bridge/)) |
| [`ui/`](ui/) | Slint UI Library | **Shared Slint Component Library**: 45+ declarative components and layouts exported via [`ui/index.slint`](ui/index.slint) |
| [`reference/`](reference/) | Reference Archive | Archived web application stack (`frontend/`, `backend/`, `api/`, `infrastructure/`) kept as design and layout reference |

---

## Key Capabilities

### 1. Layouts & Data Representations ([`ui/`](ui/) + [`slate.components`](slate-dlang/source/slate/components/))

Slate ships a comprehensive suite of dark-theme-first desktop layouts and data visualization components:

#### Application & Workspace Layouts ([`ui/layouts/`](ui/layouts/))
- **[`SlateDockLayout`](ui/layouts/dock_layout.slint) & [`WorkspaceDockController`](slate-dlang/source/slate/components/layouts.d)**: IDE/Studio dockable workspace with collapsible Left, Right, and Bottom tool panels and dimension validation.
- **[`SlateMasterDetailLayout`](ui/layouts/master_detail_layout.slint) & [`MasterDetailController`](slate-dlang/source/slate/components/layouts.d)**: Searchable master list pane, resizable split handle, and automatic empty-selection fallback (`SlateStatusPage`).
- **[`SlateWizardLayout`](ui/layouts/wizard_layout.slint) & [`WizardController`](slate-dlang/source/slate/components/layouts.d)**: Multi-step progression bar with completed/active step states and `Back` / `Next` / `Finish` navigation.
- **[`SlatePageHeader`](ui/layouts/page_header.slint) & [`SlateBreadcrumbs`](ui/layouts/page_header.slint)**: Hierarchical breadcrumb trail, status badge, and primary/secondary action buttons.
- **[`SlateToolbar`](ui/layouts/toolbar_status_bar.slint) & [`SlateStatusBar`](ui/layouts/toolbar_status_bar.slint)**: Command action bar and bottom status bar with live task progress indicator.
- **[`SlateBentoGrid`](ui/layouts/bento_grid.slint), [`SlateFormLayout`](ui/layouts/form_layout.slint), [`SlateWrapLayout`](ui/layouts/wrap_layout.slint), [`SlateSplitView`](ui/layouts/resizable_panel_group.slint)**: Responsive dashboard tiles, structured field groups with validation errors, tag flows, and draggable splitters.

#### Data Representations & Vector Charts ([`ui/components/`](ui/components/))
- **[`SlateDataGrid`](ui/components/data_grid.slint) & [`DataGridController!T`](slate-dlang/source/slate/components/datagrid.d)**: Generic reactive data grid supporting custom D row structs, tri-state column sorting (`none` -> `asc` -> `desc`), live substring filtering, single/multi-row selection, status badges, and pagination.
- **[`SlateTreeView`](ui/components/tree_view.slint) & [`TreeModel!T`](slint-d/source/slint/model.d)**: Depth-indented hierarchical tree view with expand/collapse chevrons and bounded recursion (`maxTreeDepth = 128`).
- **[`SlateStatGroup`](ui/components/stat_group.slint) & [`SlateSparkline`](ui/components/sparkline.slint)**: KPI metric strips with delta badges and inline SVG polyline/area sparklines.
- **[`SlateBarChart`](ui/components/charts.slint), [`SlateLineChart`](ui/components/charts.slint), [`SlateDonutChart`](ui/components/charts.slint)**: Pure vector charts powered by [`slate.utils.chart`](slate-dlang/source/slate/utils/chart.d) (`buildSparklinePath`, `buildAreaPath`, `buildDonutArcPath`).
- **[`SlateKanbanBoard`](ui/components/kanban_board.slint)**: 4-lane workflow board (`To Do`, `In Progress`, `Review`, `Done`) with card tags and MCP lane-move actions.
- **[`SlateTimeline`](ui/components/timeline.slint), [`SlateDescriptionList`](ui/components/description_list.slint), [`SlateTagList`](ui/components/tag_list.slint)**: Chronological activity feed, key-value metadata inspector with copy actions, and interactive filter chips.
- **[`SlateLogViewer`](ui/components/log_viewer.slint) & [`RingBufferLogModel`](slate-dlang/source/slate/components/log_viewer.d)**: Bounded ring-buffer streaming log console with severity pills (`all`, `info`, `warn`, `error`) and search filtering.

---

### 2. Media Player, Dropzone, Drag-and-Drop & Sandboxed File Dialog

- **[`SlateMediaPlayer`](ui/components/media_player.slint) & [`MediaPlayerController`](slate-dlang/source/slate/components/media.d)**:
  - Supports `"video"`, `"audio-deck"`, and `"mini-bar"` presentation modes.
  - Transport controls (play/pause, stop, previous/next track, loop mode, shuffle, playback speed `0.5x`–`2.0x`, mute/volume, fullscreen).
  - Timeline scrubber with buffered range, chapter/event marker ticks (`SlateMediaMarker`), SVG waveform overlay, and selectable playlist queue (`SlateMediaTrack`).
- **[`SlateDropzone`](ui/components/dropzone.slint) & [`UploadQueueController`](slate-dlang/source/slate/components/dropzone.d)**:
  - Interactive drag-over drop target, extension allow-list & max-byte validation, per-file upload progress bars, and MCP file-drop injection.
- **[`SlateDraggable`](ui/components/drag_drop.slint) & [`SlateDropTarget`](ui/components/drag_drop.slint)**:
  - Reusable drag-and-drop primitives with pointer tracking and headless MCP drop-target activation.
- **[`SlateFileDialog`](ui/components/file_dialog.slint) & [`FileDialogController`](slate-dlang/source/slate/components/file_dialog.d)**:
  - Supports `"open-file"`, `"open-multiple"`, `"select-directory"`, and `"save-file"` modes.
  - Pluggable `IFileSystemProvider` (`InMemoryFileSystem` for deterministic unit tests and `LocalFileSystem` for host I/O) with strict sandbox root confinement, sibling-prefix collision protection, and symlink/filename traversal guards.

---

### 3. Trait-Driven Declarative MCP Automation ([`slate.agent`](slate-dlang/source/slate/agent/) & [`slate.mcp`](slate-dlang/source/slate/mcp/))

Every Slate component and Dlang controller integrates with the embedded **Model Context Protocol (MCP)** server (`JSON-RPC 2.0`) through compile-time introspected capability interfaces in [`slate.agent.traits`](slate-dlang/source/slate/agent/traits.d):

| Interface | Capability Tag | Purpose |
|-----------|----------------|---------|
| `McpControllable` | `"controllable"` | Base state snapshot (`mcpSnapshot`), property mutation (`mcpSetProperty`), and transactional rollback (`mcpRestoreSnapshot`) |
| `McpBindable` | `"bindable"` | Two-way binding between Dlang controller state and a live `slint.instance.WindowHandle` |
| `McpSeekable` | `"seekable"` | Timeline scrubbing and playback transport (`seekTo`, `play`, `pause`, `stop`) |
| `McpSortable` | `"sortable"` | Column sorting (`sortByColumn`, `sortColumn`, `sortDirection`) |
| `McpFilterable` | `"filterable"` | Live query filtering (`setFilterQuery`, `clearFilter`) |
| `McpExpandable` | `"expandable"` | Tree/collapsible node expansion (`expandNode`, `collapseNode`, `toggleNode`) |
| `McpDropReceiver` | `"drop-receiver"` | Headless file/payload drop injection (`dropFiles`, `dropPayload`) |
| `McpSelectable` | `"selectable"` | Single and multi-item selection (`selectIndex`, `selectById`) |

#### Example: Wiring a Controller into the MCP Server

```d
import slate.agent.builder : AgentBuilder;
import slate.agent.declarative : McpStateRegistry;
import slate.components;
import slate.mcp.server : McpServer;

auto registry = new McpStateRegistry();

auto media = new MediaPlayerController([
    MediaTrackData("t1", "Telemetry Stream", "Flight Ops", 180.0f),
]);
auto dropzone = new UploadQueueController([".mp4", ".json", ".png"]);

registry.registerController(media);
registry.registerController(dropzone);

auto handle = AgentBuilder.forWindow(win, registry).build();
auto server = new McpServer(handle.engine());

// Execute MCP JSON-RPC 2.0 tool calls (stdio or in-memory):
// - tools/call: inspect_tree, click_element, send_keys, get_state, get_screenshot
string responseJson = server.handleLine(
    `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_state","arguments":{"query":"media"}}}`
);
```

---

### 4. High-Performance Networking ([`slate.quic`](slate-dlang/source/slate/quic/) & [`slate.http`](slate-dlang/source/slate/http/))

- **`slate.quic`**: Pure-D, sans-I/O implementation of QUIC (`RFC 9000`, `RFC 9001`, `RFC 9002`), including variable-length integer & packet wire codecs, OpenSSL TLS 1.3 key derivation & header protection, stream flow control, and NewReno/Cubic congestion control with loss detection.
- **`slate.http`**: Memory-safe HTTP/1.1, HTTP/2, and HTTP/3 client (`HttpClient`, `HttpTask`) plus native HTTP/3 framing (`RFC 9114`) and QPACK header compression (`RFC 9204`).
- **`durl` CLI ([`slate.bin.durl`](slate-dlang/source/slate/bin/durl.d))**: Command-line HTTP/QUIC diagnostic client.

---

## Quick Start & Commands

### Prerequisites

1. **DMD `2.111+` / DUB**:
   ```bash
   curl -fsS https://dlang.org/install.sh | bash -s install dmd
   source ~/dlang/dmd-*/activate
   ```
2. **Rust Toolchain** (builds the `slint-d` C-ABI bridge crate `libslint_d_bridge.so`):
   ```bash
   cd slint-d/bridge && cargo build
   ```

### Running Tests & Builds

Use `just` recipes from the repository root (or run `dub` directly):

| Command | Description |
|---------|-------------|
| `just d-bridge` | Build the Rust C-ABI bridge (`slint-d/bridge`) |
| `just d-test` | Run `slint-d` pure-D unit tests (`14/14` modules) |
| `just d-test-native` | Run `slint-d` native unit tests with `SLINT_BACKEND=software` |
| `just slate-test-core` | Run `slate:core` pure-D unit tests (`12/12` modules) |
| `just slate-test-net` | Run `slate:net` unit tests (`41/41` modules) |
| `just slate-test-mcp` | Run `slate:mcp` automation & MCP unit tests (`19/19` modules) |
| `just slate-test-ui` | Run `slate:ui` pure-D UI component tests (`9/9` modules) |
| `just slate-test-ui-native` | Run `slate:ui` native Slint + MCP tests (`SLINT_BACKEND=software`) |
| `just slate-test` | Run full `slate` umbrella pure-D unit tests |
| `just slate-test-native` | Run full `slate` umbrella native Slint + MCP E2E tests (`SLINT_BACKEND=software`) |
| `just d-build` | Build `slint-d` library |
| `just slate-build` | Build `slate` library |
| `just d-gallery` | Render offscreen PNG component snapshots from D into `renders/dlang-gallery` |

#### Direct DUB Commands

```bash
# Activate D toolchain
source ~/dlang/dmd-*/activate

# Run slint-d pure-D and SlintNative software-rendered tests
cd slint-d
dub test
LD_LIBRARY_PATH="$PWD/bridge/target/debug:$LD_LIBRARY_PATH" SLINT_BACKEND=software dub test --config=native

# Run slate-dlang pure-D and SlintNative software-rendered tests (including E2E MCP + PNG screenshots)
cd ../slate-dlang
dub test
LD_LIBRARY_PATH="$PWD/../slint-d/bridge/target/debug:$LD_LIBRARY_PATH" SLINT_BACKEND=software dub test --config=native
```

---

## Development Workflow

1. **Test-Driven Development (`Red -> Green -> Iterate`)**:
   - Every behavior change starts with a failing unit test (`unittest`) annotated with a `// Spec:` header and `/// Example:` doc block.
2. **Adversarial TDD Verification (`/adversarial-tdd-workflow`)**:
   - Production changes are audited by fresh-context read-only Spec/TDD Reviewer and Security Auditor subagents (`slate-dlang`, `slint-d`, `ui`).
3. **Structured Commits**:
   - Validate commit messages with `python3 scripts/validate-commit-msg.py` and run `./scripts/security-scan.sh` before committing.
