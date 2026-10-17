# AGENTS.md — Slate Project Instructions

**Slate** is a declarative desktop and web UI framework written in **Dlang** on top of **[Slint](https://slint.dev)**, featuring an idiomatic Rust C-ABI bridge ([`slint-d/`](slint-d/README.md)), a 5-subpackage Dlang framework ([`slate-dlang/`](slate-dlang/README.md)), a standalone `.slint` + Dlang to SolidJS cross-compiler ([`slate:solid`](slate-dlang/packages/solid/README.md)), and trait-driven **Model Context Protocol (MCP)** automation.

---

## Workspace Structure & Scoped `AGENTS.md` Index

Read the scoped `AGENTS.md` file in the directory you are modifying before making changes:

| Path | Scoped Instructions | Purpose |
|------|---------------------|---------|
| [`slate-dlang/`](slate-dlang/README.md) | [`slate-dlang/AGENTS.md`](slate-dlang/AGENTS.md) | Core Dlang framework subdivided into 5 layered DUB subpackages (`:core`, `:net`, `:mcp`, `:ui`, `:solid`) |
| [`slate-encoding/`](slate-encoding/README.md) | — | Pure-D media codecs and container primitives for QUIC / MoQ (`QOI`, `QOIV`, `QOA`, `LOC`) |
| [`slate-dlang/packages/solid/`](slate-dlang/packages/solid/README.md) | [`slate-dlang/packages/solid/AGENTS.md`](slate-dlang/packages/solid/AGENTS.md) | `slint2solid` `.slint` + Dlang controller to SolidJS (`.tsx`) & TypeScript (`.ts`) cross-compiler |
| [`slint-d/`](slint-d/README.md) | [`slint-d/AGENTS.md`](slint-d/AGENTS.md) | Dlang bindings for the Slint runtime (`source/slint/`) and modular Rust C-ABI bridge (`slint-d/bridge/`) |
| [`ui/`](ui/README.md) | [`ui/AGENTS.md`](ui/AGENTS.md) | Shared declarative Slint UI library: 47 components (`ui/components/`), 16 layouts (`ui/layouts/`), and [`ui/index.slint`](ui/index.slint) |
| [`slate-dev/`](slate-dev/README.md) | [`slate-dev/rules/AGENTS.md`](slate-dev/rules/AGENTS.md) | Portable Dlang & Slint toolchain installer (`./slate-dev/install.sh`), LSP/linter configs, and Antigravity plugin |
| [`examples/`](examples/README.md) | — | Standalone Slate & `slint-d` example applications (`examples/file-manager/`, `slint-d/examples/`) |
| [`docs/`](docs/README.md) | — | Project documentation, style guides (`docs/guides/style-dlang.md`, `style-slint.md`, `style-general.md`), and ADRs |
| [`scripts/`](scripts/README.md) | — | Workspace utility, linting, test, cleanup, and commit/security validation scripts |
| [`.agents/skills/`](.agents/skills/) | — | Project-standard assistant skills (TDD, Adversarial TDD, Architect, Dlang LSP, Slate MCP control, Git commit) |
| [`reference/`](reference/) | — | Archived prototype implementations (`slate-rust/`, `slate-carbon/`, `agent/`, and legacy webapp stack) |

---

## Slate Dlang & Slint Toolchain, LSP & Linting (`slate-dev/`)

The entire Dlang + Slint compiler, LSP, linting, formatting, and Antigravity plugin setup is packaged in [`slate-dev/`](slate-dev/README.md) and installed via `./slate-dev/install.sh` (or `just d-setup`). All binaries live in `~/.local/bin` and are synced to `~/.gemini/antigravity/bin`:

| Tool | Command / Binary | Purpose |
|---|---|---|
| **Portable Dev Kit & Plugin** | `./slate-dev/install.sh` (`just d-setup`) | One-command installer for all binaries, configs, and the `~/.gemini/config/plugins/slate-dev` Antigravity plugin |
| **D Compiler & DUB** | `dmd` (`v2.113.0`), `dub` (`v1.42.0`) | Dlang reference compiler and package/build manager (`slint-d` and `slate-dlang`) |
| **D Language Server (LSP)** | `serve-d` (`v0.8.0-beta.18`) + `dcd-server` / `dcd-client` (`v0.19.4`) | IDE & LSP intelligence (autocomplete, hover docs, go-to-definition, workspace symbol lookup) |
| **D Static Analyzer / Linter** | `dscanner` (`v0.15.2`, configured via [`dscanner.ini`](dscanner.ini)) | Fast AST syntax checking (`--syntaxCheck`), static analysis (`--styleCheck`), declaration lookup (`-d <symbol>`), and outline extraction (`--ctags`) |
| **D Formatter** | `dfmt` (`v0.15.2`, configured via [`.editorconfig`](.editorconfig)) | Canonical D code formatting (`just d-fmt` or `dfmt -i <file.d>`) |
| **Slint LSP & Viewer** | `slint-lsp`, `slint-viewer` (`v1.18.1`) | Language server and live previewer for declarative `.slint` UI files in `ui/` |
| **SolidJS Cross-Compiler** | `slint2solid` ([`slate:solid`](slate-dlang/packages/solid/README.md)) | Cross-compiles `.slint` UI files and Dlang controllers into reactive SolidJS (`.tsx`) + TypeScript (`.ts`) |
| **Antigravity MCP Bridge** | `slate-dev/mcp/dlang-lsp-mcp.py` (`slate-dev` plugin & `dlang-lsp`) | Exposes `d_lint`, `d_find_declaration`, `d_lsp_document_symbols`, `d_module_imports`, `d_format`, and `slint_check` as native MCP tools |

---

## Canonical `just` Recipes

Run commands from the repository root. Prefer `just <recipe>` for all standard operations:

### Toolchain, Linting & Formatting
| Recipe | Purpose | Underlying Command |
|---|---|---|
| `just` / `just default` | List all available recipes | `just --list --unsorted` |
| `just d-setup` / `just d-check` | Install or verify the portable `slate-dev` toolchain & plugin | `./slate-dev/install.sh [--check]` |
| `just d-lint` | Run `dscanner` syntax & style checks across `slint-d`, `slate-dlang`, and `examples` | `dscanner --syntaxCheck ... && dscanner --styleCheck --config dscanner.ini ...` |
| `just d-fmt` | Format all `.d` files in-place using `dfmt` and `.editorconfig` | `find ... -name '*.d' -exec dfmt -i {} +` |
| `just lint` | Run `just d-lint`, Rust bridge `cargo fmt --check` & `cargo clippy`, and `dub build` across `slint-d` and `slate-dlang` | Full workspace lint & build gate |
| `just clean` | Clean DUB/Dlang build artifacts, test binaries, and temporary outputs | `scripts/clean.sh` |
| `just ctx` | Print a compact workspace context snapshot for AI agents | `scripts/agent-context.sh` |

### Building, Codegen & Documentation
| Recipe | Purpose | Underlying Command |
|---|---|---|
| `just new-project <dir> [name]` | Provision a new Slate app (Window + Counter + Button + MCP Switch + `mcp_config.json`) | `./scripts/new-project.sh <dir> [name]` |
| `just d-bridge` | Build the Rust C-ABI bridge (`libslint_d_bridge`) | `cd slint-d/bridge && cargo build` |
| `just d-build` | Build `slint-d` library (pure-D configuration) | `cd slint-d && dub build` |
| `just slate-build` | Build `slate-dlang` umbrella library (pure-D configuration) | `cd slate-dlang && dub build` |
| `just solid-codegen [out_dir]` | Cross-compile all 64 `.slint` files in `ui/` + Dlang controllers into SolidJS (`target/solid-ui`) | `cd slate-dlang && dub run :solid --config=slint2solid -- ../ui ../target/solid-ui` |
| `just d-docs` | Generate Ddoc HTML documentation on demand into `slate-dlang/docs/` | `cd slate-dlang && dmd -D -Dd=docs -c ...` |
| `just d-gallery [out_dir]` | Render offscreen PNG snapshots of the Slate showcase gallery from D | `cd slint-d/examples/gallery && SLINT_BACKEND=software dub run --config=native` |

### Testing (All Suites)
| Recipe | Purpose | Underlying Command |
|---|---|---|
| `just d-test` | Run `slint-d` pure-D unit tests (15 modules) | `cd slint-d && dub test` |
| `just d-test-native` | Run `slint-d` native unit tests with headless software renderer | `cd slint-d && SLINT_BACKEND=software dub test --config=native` |
| `just slate-test` | Run `slate-dlang` umbrella pure-D unit tests | `cd slate-dlang && dub test` |
| `just slate-test-native` | Run `slate-dlang` umbrella native Slint + MCP E2E tests (`SLINT_BACKEND=software`) | `cd slate-dlang && SLINT_BACKEND=software dub test --config=native` |
| `just slate-test-core` | Run `slate:core` pure-D unit tests | `cd slate-dlang && dub test :core` |
| `just slate-test-net` | Run `slate:net` HTTP + QUIC unit tests | `cd slate-dlang && dub test :net` |
| `just slate-test-mcp` | Run `slate:mcp` automation engine + MCP JSON-RPC unit tests | `cd slate-dlang && dub test :mcp` |
| `just slate-test-ui` | Run `slate:ui` pure-D component controller unit tests | `cd slate-dlang && dub test :ui` |
| `just slate-test-ui-native` | Run `slate:ui` native Slint + MCP unit tests (`SLINT_BACKEND=software`) | `cd slate-dlang && SLINT_BACKEND=software dub test :ui --config=native` |
| `just slate-test-solid` | Run `slate:solid` `.slint` + Dlang to SolidJS compiler & Node/esbuild runtime verification tests | `cd slate-dlang && dub test :solid` |
| `just file-manager-test` | Run `examples/file-manager` controller unit tests | `cd examples/file-manager && dub test` |

---

## Assistant Skills (`.agents/skills/`)

Use the project-standard skills under `.agents/skills/` for specialized workflows:

| Skill | Purpose | Location |
|---|---|---|
| `dlang-lsp-tooling` | Inspect, lint, format, and query AST/LSP symbols for Dlang (`.d`) and Slint (`.slint`) files using `serve-d`, `dcd`, `dscanner`, `dfmt`, `slint-lsp`, and the `dlang-lsp` MCP server. | [`.agents/skills/dlang-lsp-tooling/SKILL.md`](.agents/skills/dlang-lsp-tooling/SKILL.md) |
| `slate-agent-control` | Inspect, interact with, automate, and capture visual snapshots of Slate desktop applications using the native MCP toolset (`inspect_tree`, `click_element`, `send_keys`, `get_state`, `get_screenshot`). | [`.agents/skills/slate-agent-control/SKILL.md`](.agents/skills/slate-agent-control/SKILL.md) |
| `test-driven-development` | Work test-driven using the Red → Green → Iterate loop: write a focused failing `unittest` first with `// Spec:` and `/// Example:` headers, implement the smallest passing change, and keep code clean. | [`.agents/skills/test-driven-development/SKILL.md`](.agents/skills/test-driven-development/SKILL.md) |
| `adversarial-tdd-workflow` | Orchestrate high-assurance implementation using a TDD Implementor subagent and fresh-context, strictly read-only Spec/TDD Reviewer and Security Auditor subagents. | [`.agents/skills/adversarial-tdd-workflow/SKILL.md`](.agents/skills/adversarial-tdd-workflow/SKILL.md) |
| `architect` | Evidence-driven architectural planning, trade-off analysis, dataflow modeling, and EARS/Gherkin specification authoring in `.agents/plans/`. | [`.agents/skills/architect/SKILL.md`](.agents/skills/architect/SKILL.md) |
| `debug-failure-analysis` | Systematically debug failures by reproducing them, modeling dataflow, tracing git history, and isolating root causes before fixing. | [`.agents/skills/debug-failure-analysis/SKILL.md`](.agents/skills/debug-failure-analysis/SKILL.md) |
| `git-commit-workflow` | Structured Conventional Commits conventions, pre-commit security checks (`scripts/security-scan.sh`), commit message validation (`scripts/validate-commit-msg.py`), and explicit user consent rules. | [`.agents/skills/git-commit-workflow/SKILL.md`](.agents/skills/git-commit-workflow/SKILL.md) |
| `docs-usage` | Guidelines for reading, using, and maintaining project documentation and language style guides (`docs/guides/`). | [`.agents/skills/docs-usage/SKILL.md`](.agents/skills/docs-usage/SKILL.md) |
| `scripts-usage` | Reference guide for repository scripts in `scripts/` and their canonical `just` recipes. | [`.agents/skills/scripts-usage/SKILL.md`](.agents/skills/scripts-usage/SKILL.md) |

*(Note: Preserved skills for the archived `reference/` webapp stack — `alembic-usage`, `auth-integration`, `code-generation`, `local-stack-management`, `terraform-usage` — remain in `.agents/skills/` for working inside `reference/`.)*

---

## Development Workflow & Engineering Rules

1. **Test-Driven Development (`Red → Green → Iterate`)**:
   - Follow [`test-driven-development`](.agents/skills/test-driven-development/SKILL.md) and [`docs/guides/style-dlang.md`](docs/guides/style-dlang.md).
   - Annotate every `unittest` block with a `// Spec:` comment describing the requirement under test and a `/// Example:` Ddoc header where appropriate.
2. **AST Queries, Linting & Formatting**:
   - Prefer `dscanner -d <symbol>` (`d_find_declaration`), `dscanner --ctags <file.d>` (`d_lsp_document_symbols`), and `dscanner --imports <file.d>` (`d_module_imports`) over blind regex searches when navigating D code.
   - Format modified `.d` files with `just d-fmt` and verify zero warnings with `just d-lint` (`dscanner`) and `slint_check` (`slint-lsp`) before completing any task.
3. **Plan Mode**:
   - Follow the [`architect`](.agents/skills/architect/SKILL.md) skill for architectural changes: save plans in `.agents/plans/YYYYMMDD-HHMMSS-<topic>.md` with EARS requirements and Gherkin acceptance scenarios.
4. **AI Agent Git Commit Rules**:
   - **Commit Dry-Run & Warning Report**: Before executing any `git commit`, dry-run commit validations (`python3 scripts/validate-commit-msg.py` and `./scripts/security-scan.sh`) and report any warnings to the user.
   - **Explicit Consent**: Never create a git commit without explicit user approval.
5. **AI Agent Subagent / Worktree Rules**:
   - **In-session subagents only**: When using subagents, invoke them via the in-session subagent tool (`invoke_subagent`). Do NOT create external git worktrees unless explicitly requested.
