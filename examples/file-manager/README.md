# File Manager example

Tabbed single-window dual-pane file manager built on `slint-d`:

- **Top:** multiple tabs (`tabSelected` / `addTab` / `closeTab`), each tab keeps
  independent locations for pane 1 and pane 2.
- **Left:** directory tree (`treeSelectedChanged` drives the focused pane).
- **Middle / right:** location 1 + location 2 file lists. Pressing a row stages
  its path as `draggedPayload`; clicking the opposite pane fires
  `dropOnPane(pane, payload)` and moves the entry. `Send »` / `« Send` buttons
  (`moveRequested`) do the same move for keyboard / automation.

## Layout

| File | Purpose |
|------|---------|
| `app.slint` | `MainWindow`: tab bar, 3-column body (tree + 2 panes), status bar |
| `source/filemanager.d` | Pure-D `FileManagerController` + `MemFs`, with `unittest` spec |
| `source/main.d` | Pure-D demo fallback + native Slint wiring (`--check` verifies compile) |

The `.slint` intentionally mirrors the library primitives (`SlateTabs`,
`SlateTreeView`, `SlateDropTarget`, `SlateThreePanelLayout`) while staying
self-contained so it compiles against stock Slint.

## Run

```bash
cd examples/file-manager

dub test            # controller unit tests (1 module)
dub run             # pure-D demo (no Slint runtime needed)
dub build --config=native
LD_LIBRARY_PATH="../../slint-d/bridge/target/debug:$LD_LIBRARY_PATH" \
  SLINT_BACKEND=software ./file-manager --check   # compile-check app.slint
LD_LIBRARY_PATH="../../slint-d/bridge/target/debug:$LD_LIBRARY_PATH" \
  SLINT_BACKEND=software ./file-manager --shot [out.png]
    # headless MCP run: opens /docs + /media, drives the UI through
    # SlintUiInspector + SlintElementController (the click_element /
    # inspect_tree MCP path), drag-drops notes.txt across panes,
    # saves a PNG snapshot (default: ../../renders/file-manager-two-panes.png)
LD_LIBRARY_PATH="../../slint-d/bridge/target/debug:$LD_LIBRARY_PATH" \
  ./file-manager    # full window (needs display)
```
