# AGENTS.md — `ui/` Shared Slint Component Library Instructions

This directory contains Slate's shared declarative **[Slint](https://slint.dev)** component library (`ui/components/`, `ui/layouts/`, and [`ui/index.slint`](index.slint)). Every component here targets **both** native desktop rendering via `slint-d` and web browser compilation via `slate:solid` (`slint2solid`).

---

## 1. Directory Layout

- [`ui/index.slint`](index.slint): Public barrel file re-exporting all components, structs, and layouts. Any new component or struct added to `ui/components/` or `ui/layouts/` **must** be exported in `ui/index.slint`.
- [`ui/components/theme.slint`](components/theme.slint): Defines the `export global SlateTheme` singleton containing all color palettes (dark & light mode), typography tokens, spacing, border radii, and animation durations.
- `ui/components/*.slint`: 47 reusable UI primitives, data representations, charts, media controls, and dialogs (`SlateButton`, `SlateDataGrid`, `SlateTreeView`, `SlateMediaPlayer`, `SlateFileDialog`, `SlateDropzone`, etc.).
- `ui/layouts/*.slint`: 16 structural application layouts (`SlateWindow`, `SlateDockLayout`, `SlateMasterDetailLayout`, `SlateWizardLayout`, `SlateBentoGrid`, `SlateFormLayout`, `SlateSplitView`, etc.).

---

## 2. Authoring Rules & Conventions

1. **Theme Tokens Only (`SlateTheme`)**:
   - Never hardcode hex colors, font sizes, or border radii inside components. Bind all visual properties to `SlateTheme.*` (e.g., `SlateTheme.bg-surface`, `SlateTheme.text-primary`, `SlateTheme.accent`, `SlateTheme.border-subtle`, `SlateTheme.radius-md`).
   - All components must react dynamically when `SlateTheme.dark-mode` toggles between `true` and `false`.
2. **Naming Conventions**:
   - Exported components and structs must be prefixed with `Slate` in `PascalCase` (e.g., `export component SlateMediaPlayer`, `export struct SlateMediaTrack`).
   - Properties and callbacks use `kebab-case` in `.slint` (normalized automatically to `camelCase` by `slint-d` and `slint2solid`).
3. **Accessibility & MCP Automation**:
   - Interactive components must declare `accessible-role` (`button`, `checkbox`, `slider`, `text-input`, `list`, `tab`, etc.) and `accessible-label` / `accessible-value` so `SlintUiInspector` and the MCP server (`inspect_tree`, `click_element`, `send_keys`) can discover and drive them headlessly.
4. **Dual-Compiler Compatibility (`slint-lsp` + `slint2solid`)**:
   - Every `.slint` file in `ui/` must pass `slint-lsp` validation (`slint_check` MCP tool) **and** compile cleanly to SolidJS TSX via `just solid-codegen`.

---

## 3. Verification Checklist

After creating or modifying any `.slint` file in `ui/`:

1. Validate with `slint_check` (or `slint-lsp`) to ensure zero Slint compiler errors.
2. Run `just solid-codegen` and `just slate-test-solid` to verify 1:1 SolidJS cross-compilation.
3. Run `just slate-test-ui-native` to verify headless native Slint rendering and MCP interaction.
