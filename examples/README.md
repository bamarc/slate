# Slate Example Applications

This directory contains standalone example applications built with **Slate** (`slate-dlang` + `slint-d`).

---

## Available Examples

| Example | Location | Description |
|---|---|---|
| **Dual-Pane File Manager** | [`examples/file-manager/`](file-manager/README.md) | Tabbed dual-pane desktop file manager with directory tree navigation, cross-pane drag-and-drop file moves, pure-D `FileManagerController` unit tests, and headless MCP snapshot automation (`--shot`). |
| **Component Gallery Showcase** | [`../slint-d/examples/gallery/`](../slint-d/examples/gallery/) | Full Slate component gallery rendered from Dlang (`just d-gallery`), outputting offscreen PNG snapshots across all showcase tabs. |
| **Menubar Showcase** | [`../slint-d/examples/menushow/`](../slint-d/examples/menushow/) | Slate desktop menubar and command palette demonstration with offscreen PNG capture (`--shot`). |
| **Hello Counter** | [`../slint-d/examples/hello/`](../slint-d/examples/hello/) | Minimal `slint-d` counter window demonstrating `SlintProps` and `SlintCallbacks` compile-time mixins (`just d-example`). |

---

## Running Examples

```bash
# Run File Manager unit tests from repository root:
just file-manager-test

# Run Hello example:
just d-example

# Render the full Dlang component gallery offscreen:
just d-gallery
```
