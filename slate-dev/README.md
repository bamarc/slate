# `slate-dev` — Portable Dlang + Slint Developer Kit & Antigravity Plugin

`slate-dev/` packages the entire **Dlang + Slint** compiler, Language Server Protocol (LSP), static analysis, code formatting, and **Google Antigravity** plugin/MCP integration into a single shareable directory.

---

## What's Included

```text
slate-dev/
├── install.sh                         # One-command installer (binaries + configs + Antigravity plugin)
├── uninstall.sh                       # Removes the installed Antigravity plugin bundle
├── plugin.json                        # Antigravity plugin manifest ("slate-dev")
├── mcp_config.json                    # Antigravity MCP server config ("slate-dev-dlang-lsp")
├── assets/
│   └── logo.svg                       # Plugin icon
├── config/
│   ├── dscanner.ini                   # Canonical D-Scanner static analysis rules
│   └── .editorconfig                  # Canonical dfmt / Slint / Rust formatting rules
├── mcp/
│   └── dlang-lsp-mcp.py               # MCP stdio server wrapping serve-d, dscanner, dfmt, slint-lsp
├── rules/
│   └── AGENTS.md                      # Always-on Antigravity rule when plugin is active
└── skills/
    └── dlang-lsp-tooling/
        └── SKILL.md                   # On-demand skill teaching agents how to use the toolchain
```

---

## Quick Start (Install & Share)

Run from the repository root (or from a standalone copy of `slate-dev/`):

```bash
# Full install: DMD/DUB + serve-d + DCD + dfmt + dscanner + slint-lsp + Antigravity plugin
./slate-dev/install.sh

# Or via Justfile from the Slate repository root:
just d-setup
```

### Installer Flags

| Command | Description |
|---------|-------------|
| `./slate-dev/install.sh` | Full install of all Dlang/Slint binaries (`~/.local/bin`), configs (`~/.config/dscanner/dscanner.ini`), and Antigravity plugin (`~/.gemini/config/plugins/slate-dev`) |
| `./slate-dev/install.sh --check` | Verify installed tool versions and Antigravity plugin status without modifying anything |
| `./slate-dev/install.sh --plugin-only` | Install/update only the configs and Antigravity plugin (skips binary downloads) |
| `./slate-dev/uninstall.sh` | Remove the `~/.gemini/config/plugins/slate-dev` Antigravity plugin bundle |

---

## Exposed Antigravity MCP Tools (`slate-dev-dlang-lsp`)

Once installed, the `slate-dev` plugin provides 6 native MCP tools to Antigravity agents:

1. **`d_lint`**: Run `dscanner --syntaxCheck` and `dscanner --styleCheck --config dscanner.ini`.
2. **`d_find_declaration`**: AST-resolve the exact file, line, and column where any D symbol (`class`, `struct`, `interface`, `function`, `template`) is declared.
3. **`d_lsp_document_symbols`**: Extract structured document symbols (`name`, `kind`, `line`, `access`, `scope`, `signature`) from any `.d` file via `dscanner --ctags` and `serve-d`.
4. **`d_module_imports`**: Resolve imported modules for any `.d` file.
5. **`d_format`**: Preview unified diff or format `.d` files in-place using `dfmt` and `.editorconfig`.
6. **`slint_check`**: Validate `.slint` files via `slint-lsp` over JSON-RPC and return diagnostics + component symbols.
