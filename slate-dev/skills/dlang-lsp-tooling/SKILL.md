---
name: dlang-lsp-tooling
description: Inspect, lint, format, and query AST/LSP symbols for Dlang (.d) and Slint (.slint) files using serve-d, dcd, dscanner, dfmt, slint-lsp, and the dlang-lsp MCP bridge. Use whenever working with D or Slint code, checking syntax/style, finding symbol declarations, formatting code, or configuring IDE/Antigravity LSP support.
---

# Dlang & Slint LSP, Linting, and Formatting Tooling (`dlang-lsp-tooling`)

This skill documents the Dlang (`slint-d`, `slate-dlang`) and Slint (`ui/`) language server, static analysis, and formatting toolchain installed in this environment and integrated into **Antigravity**.

---

## 1. Installed Toolchain Overview

All binaries are installed in `~/.local/bin` and synced into `~/.gemini/antigravity/bin` (via `sync-dev-tools`), making them immediately available to Antigravity agents, subagents, and IDEs without manual environment activation:

| Binary | Version | Purpose |
|--------|---------|---------|
| `dmd` / `dub` / `rdmd` | `v2.113.0` / `v1.42.0` | D reference compiler, package/build manager, and script runner |
| `serve-d` | `v0.8.0-beta.18` | Official D Language Server (LSP) with DUB workspace & sub-package support |
| `dcd-server` / `dcd-client` | `v0.19.4` | D Code Completion daemon & client backing `serve-d` |
| `dscanner` | `v0.15.2` | D AST syntax checker, static analyzer, symbol declaration locator, and ctags extractor |
| `dfmt` | `v0.15.2` | Canonical D code formatter driven by `.editorconfig` |
| `slint-lsp` | `v1.18.1` | Official Slint Language Server for `.slint` declarative UI markup |
| `slint-viewer` | `v1.18.1` | Live previewer and validator for `.slint` components |

---

## 2. Canonical `just` Recipes

Prefer running the `Justfile` recipes from the repository root:

```bash
# Run D-Scanner syntax check + static analysis across slint-d and slate-dlang
just d-lint

# Format all D source files in-place using dfmt (.editorconfig rules)
just d-fmt

# Full workspace lint (d-lint + Rust bridge cargo fmt/clippy + dub build)
just lint
```

---

## 3. Antigravity Integration (Two Layers)

### Layer A: Antigravity IDE (Editor Surface)
Because Antigravity IDE is built on VS Code, it natively runs Language Server Protocol (LSP) servers via extensions configured in [`.devcontainer/devcontainer.json`](../../.devcontainer/devcontainer.json):
- **Dlang (`webfreak.code-d`)**: Uses `~/.local/bin/serve-d`, `dcd-server`, `dcd-client`, `dmd`, and `dub` to provide inline diagnostics, autocomplete, hover docs, code actions, and format-on-save (`dfmt`).
- **Slint (`Slint.slint`)**: Uses `~/.local/bin/slint-lsp` for `.slint` syntax highlighting, component property completion, and live preview.
- **Rust Bridge (`rust-lang.rust-analyzer`)**: Provides LSP support for `slint-d/bridge/`.

### Layer B: Antigravity Agent Mode (`dlang-lsp` MCP Server & CLI)
In Agent Mode (Chat Canvas / Subagents), Antigravity connects to tool servers via the **Model Context Protocol (MCP)** (`~/.gemini/config/mcp_config.json`).

We provide the **[`scripts/dlang-lsp-mcp.py`](../../scripts/dlang-lsp-mcp.py)** MCP stdio bridge (registered as `dlang-lsp` in `~/.gemini/config/mcp_config.json`), which exposes 6 tools to the agent:

1. **`d_lint`**: Runs `dscanner --syntaxCheck` and `dscanner --styleCheck --config dscanner.ini` on specified files/directories (or all `slint-d` and `slate-dlang` packages by default).
2. **`d_find_declaration`**: Uses `dscanner -d <symbol>` to AST-resolve the exact file, line, and column where a class, struct, interface, function, or template is declared.
3. **`d_lsp_document_symbols`**: Extracts structured document symbols (name, kind, line, access, scope, signature) from any `.d` file via `dscanner --ctags` and `serve-d`.
4. **`d_module_imports`**: Uses `dscanner --imports` with workspace `-I` paths to list all resolved module imports for a `.d` file.
5. **`d_format`**: Previews a unified diff (`in_place: false`) or formats a `.d` file in-place (`in_place: true`) with `dfmt`.
6. **`slint_check`**: Spawns `slint-lsp` over JSON-RPC to validate `.slint` files and return diagnostics and component symbols.

---

## 4. Direct CLI Commands for Fast Agent Lookups

When working in the terminal, you can also invoke `dscanner` and `dfmt` directly:

### Fast AST Symbol Lookup (Better than grep)
```bash
# Find where a symbol is declared across slint-d and slate-dlang
dscanner -d DataGridController slint-d/source slate-dlang/source slate-dlang/packages/*/source
```

### Fast Syntax & Static Analysis Check on a Single File
```bash
dscanner --syntaxCheck slate-dlang/packages/core/source/slate/traits.d
dscanner --styleCheck --config dscanner.ini slate-dlang/packages/core/source/slate/traits.d
```

### Inspect Document Outline (Classes, Structs, Methods, Signatures)
```bash
dscanner --ctags slate-dlang/packages/ui/source/slate/components/datagrid.d
```

### Format a Single D File
```bash
# Preview diff without modifying file
dfmt slate-dlang/packages/core/source/slate/traits.d | diff -u slate-dlang/packages/core/source/slate/traits.d -

# Format in-place
dfmt -i slate-dlang/packages/core/source/slate/traits.d
```

---

## 5. Configuration Files Reference

- **[`dscanner.ini`](../../dscanner.ini)**: Project-root static analysis configuration. Excludes low-level `extern(C)` binding modules (`-slate.quic.crypto.c_openssl`, `-slate.http.c_bind`, `-slate.http.curl`, `-slint.capi`, `-slate.mcp.transport`) from Phobos camelCase naming checks.
- **[`.editorconfig`](../../.editorconfig)**: Defines 4-space indentation, `brace_style = otbs`, `max_line_length = 120`, `soft_max_line_length = 100`, and `keep_line_breaks = true` for `*.d` files.
- **`sync-dev-tools`**: Whenever a new binary is added to `~/.local/bin`, run `sync-dev-tools` so it is symlinked into `~/.gemini/antigravity/bin`.
