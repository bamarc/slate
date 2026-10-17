# Utility Scripts (`scripts/`)

One-shot scripts for humans and AI agents. Prefer invoking the matching `just <recipe>` from the repository root.

## Core Workspace Scripts (Dlang + Slint + SolidJS)

| Script | `just` Recipe | What it does |
|--------|---------------|--------------|
| [`new-project.sh`](new-project.sh) | `just new-project <dir> [name]` | Provision a new Slate project with a Slint window, button, counter, live MCP toggle switch, and `mcp_config.json`. |
| [`../slate-dev/install.sh`](../slate-dev/install.sh) | `just d-setup` / `just d-check` | Install or verify the portable Dlang & Slint toolchain (`dmd`, `dub`, `serve-d`, `dcd`, `dscanner`, `dfmt`, `slint-lsp`) and Antigravity plugin. |
| [`dlang-lsp-mcp.py`](dlang-lsp-mcp.py) | *(MCP Server)* | JSON-RPC 2.0 MCP server bridging `dscanner`, `dfmt`, `serve-d`, and `slint-lsp` (`d_lint`, `d_format`, `d_find_declaration`, `d_lsp_document_symbols`, `d_module_imports`, `slint_check`). |
| [`clean.sh`](clean.sh) | `just clean` | Wipe DUB/Dlang build artifacts (`*.a`, `*-test-*`, `.dub`, `slate-dlang/docs`). Pass `--hard` to also remove `target/solid-ui` and `slint-d/bridge/target`. |
| [`agent-context.sh`](agent-context.sh) | `just ctx` | Print a compact workspace snapshot (`slate-dlang` subpackages, `slint-d` modules, `.slint` count, git status) in text or `--json` format. |
| [`security-scan.sh`](security-scan.sh) | *(Pre-commit)* | Run `gitleaks` secret detection and check staged dependency manifests (`dub.json`, `Cargo.toml`, `package.json`, `pyproject.toml`). |
| [`validate-commit-msg.py`](validate-commit-msg.py) | *(Commit-msg)* | Validate commit messages against Conventional Commits rules. |
| [`setup-hooks.sh`](setup-hooks.sh) | — | Configure Git to use `.githooks/`. |

## Preserved Reference Scripts (`reference/`)

The remaining scripts (`bootstrap.sh`, `dev.sh`, `test.sh`, `lint.sh`, `format.sh`, `audit.sh`, `generate.sh`, `migrate.sh`, `new-domain.sh`) support the archived fullstack reference template under `reference/`.
