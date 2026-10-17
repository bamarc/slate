# Style Guide — Slint (`ui/*.slint`)

## Tooling & Validation
- **Language Server**: `slint-lsp` (`v1.18.1`), invoked via the `slint_check` MCP tool.
- **Cross-Compiler**: `slint2solid` (`just solid-codegen` / `just slate-test-solid`), which compiles all `.slint` files in `ui/` into SolidJS (`.tsx`) components.
- Every `.slint` file in `ui/` must compile cleanly under **both** `slint-lsp` (native Slint) and `slint2solid` (SolidJS web target).

## Component & Struct Naming
- Exported components and structs must use `PascalCase` prefixed with `Slate`:
  - Components: `export component SlateButton`, `export component SlateDataGrid`, `export component SlateDockLayout`
  - Structs: `export struct SlateMediaTrack`, `export struct SlateKanbanCard`
- Properties and callbacks use `kebab-case`:
  - `in-out property <string> search-query;`
  - `callback row-selected(int);`
- Re-export all public components and structs from [`ui/index.slint`](../../ui/index.slint).

## Design Tokens (`SlateTheme`)
- Import `SlateTheme` from `theme.slint` (`import { SlateTheme } from "../components/theme.slint";`).
- **Never hardcode colors, radii, or font sizes** inside component definitions. Bind visual styles to `SlateTheme` tokens:
  - Backgrounds: `SlateTheme.bg-canvas`, `SlateTheme.bg-surface`, `SlateTheme.bg-elevated`, `SlateTheme.bg-subtle`
  - Text: `SlateTheme.text-primary`, `SlateTheme.text-secondary`, `SlateTheme.text-muted`
  - Borders & Accents: `SlateTheme.border-subtle`, `SlateTheme.border-strong`, `SlateTheme.accent`, `SlateTheme.danger`, `SlateTheme.success`, `SlateTheme.warning`
  - Radii & Spacing: `SlateTheme.radius-sm`, `SlateTheme.radius-md`, `SlateTheme.radius-lg`, `SlateTheme.spacing-sm`, `SlateTheme.spacing-md`
- Ensure every component adapts automatically when `SlateTheme.dark-mode` changes.

## Accessibility & MCP Automation
- Interactive elements (`TouchArea`, buttons, inputs, tabs, sliders, checkboxes, list rows) must declare semantic accessibility attributes so `SlintUiInspector` and the in-browser MCP server can inspect and trigger them:
  ```slint
  accessible-role: button;
  accessible-label: root.label;
  ```
- Expose stateful values (`checked`, `value`, `text`, `current-tab`, `open`) as `in-out property` bindings so Dlang controllers (`McpBindable`) and SolidJS signals can synchronize two-way state.
