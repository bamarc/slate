# `slate:ui` — Desktop UI Controllers & Native Slint MCP Backend

`slate:ui` is the desktop UI integration DUB subpackage of [`slate-dlang`](../../README.md). It connects `slate:core` and `slate:mcp` to [`slint-d`](../../../slint-d/README.md) and the shared [`.slint` component library](../../../ui/README.md), providing reactive Dlang component controllers and the live Slint accessibility/rendering backend for MCP automation.

---

## Key Modules (`source/slate/`)

| Module | File | Description |
|---|---|---|
| `slate.app` | [`source/slate/app.d`](source/slate/app.d) | `AppBuilder` fluent API for configuring and launching Slate desktop windows with embedded MCP support |
| `slate.components.datagrid` | [`source/slate/components/datagrid.d`](source/slate/components/datagrid.d) | `DataGridController!T`: generic reactive table controller with tri-state column sorting, live filtering, row selection, and pagination |
| `slate.components.media` | [`source/slate/components/media.d`](source/slate/components/media.d) | `MediaPlayerController`: video/audio/mini-bar transport, timeline scrubbing, loop/shuffle, playback speed, markers, and track queue |
| `slate.components.file_dialog` | [`source/slate/components/file_dialog.d`](source/slate/components/file_dialog.d) | `FileDialogController`, `InMemoryFileSystem`, and `LocalFileSystem` with strict sandbox root confinement and traversal guards |
| `slate.components.dropzone` | [`source/slate/components/dropzone.d`](source/slate/components/dropzone.d) | `UploadQueueController`: extension allow-list & max-byte validation, progress tracking, and headless MCP drop injection |
| `slate.components.log_viewer` | [`source/slate/components/log_viewer.d`](source/slate/components/log_viewer.d) | `RingBufferLogModel`: bounded streaming log buffer with severity and substring filtering |
| `slate.components.layouts` | [`source/slate/components/layouts.d`](source/slate/components/layouts.d) | `WorkspaceDockController`, `MasterDetailController`, and `WizardController` driving `ui/layouts/*.slint` |
| `slate.agent.slint_backend` | [`source/slate/agent/slint_backend.d`](source/slate/agent/slint_backend.d) | `SlintUiInspector`, `SlintElementController`, and `SlintVisualRenderer` bridging live `slint.instance.WindowHandle` instances to `AutomationEngine` |

---

## Build & Test

```bash
# Pure-D controller unit tests (no Slint native runtime needed):
just slate-test-ui

# Native Slint + MCP E2E unit tests (software renderer):
just slate-test-ui-native
```
