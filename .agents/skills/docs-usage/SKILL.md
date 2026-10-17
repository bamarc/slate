---
name: docs-usage
description: 'Guidelines for using and maintaining project documentation. Use this when asked about documentation structure, how to update docs, or where to find style guides.'
---

# Documentation Usage Skill

This project maintains structured documentation across the workspace and `docs/`. Follow these rules when reading or updating docs.

## Documentation Structure
- **Workspace & Package Docs**:
  - [`README.md`](../../../README.md) — Top-level Slate overview
  - [`AGENTS.md`](../../../AGENTS.md) — Master agent instructions and index of scoped `AGENTS.md` files
  - [`slate-dlang/README.md`](../../../slate-dlang/README.md) & [`slate-dlang/AGENTS.md`](../../../slate-dlang/AGENTS.md) — Core Dlang framework & 5 DUB subpackages (`:core`, `:net`, `:mcp`, `:ui`, `:solid`)
  - [`slint-d/README.md`](../../../slint-d/README.md) & [`slint-d/AGENTS.md`](../../../slint-d/AGENTS.md) — Slint Dlang bindings & Rust C-ABI bridge
  - [`ui/README.md`](../../../ui/README.md) & [`ui/AGENTS.md`](../../../ui/AGENTS.md) — Shared `.slint` component library
  - [`slate-dev/README.md`](../../../slate-dev/README.md) — Portable Dlang + Slint toolchain installer & MCP plugin
  - [`examples/README.md`](../../../examples/README.md) — Standalone example applications
- **Style Guides (`docs/guides/`)**:
  - [`docs/guides/style-dlang.md`](../../../docs/guides/style-dlang.md) — Dlang conventions (`dfmt`, `dscanner`, `@safe`, DbC, MCP traits, `// Spec:` unittests)
  - [`docs/guides/style-slint.md`](../../../docs/guides/style-slint.md) — Slint conventions (`SlateTheme` tokens, `Slate*` naming, accessibility roles, `slint2solid` compatibility)
  - [`docs/guides/style-general.md`](../../../docs/guides/style-general.md) — Git conventions, file naming, and agent rules
  - [`docs/guides/tool-selection.md`](../../../docs/guides/tool-selection.md) — Dependency and tool selection rules
- **Documentation Index**: [`docs/README.md`](../../../docs/README.md)

## Rules
- **Do NOT duplicate information** unnecessarily — link to the authoritative `README.md`, `AGENTS.md`, or `docs/guides/style-*.md` file.
- **Check language style guides first**:
  1. `docs/guides/style-dlang.md` and `slate-dlang/AGENTS.md` / `slint-d/AGENTS.md` before editing `.d` files.
  2. `docs/guides/style-slint.md` and `ui/AGENTS.md` before editing `.slint` files.
  3. `docs/guides/style-general.md` for git and file-naming conventions.
- **Keep `README.md` and `AGENTS.md` synchronized** whenever adding new subpackages, components, controllers, or `just` recipes.
