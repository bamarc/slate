# Documentation Index

## 1. Core Workspace & Package Documentation

| Document | Audience | Description |
|----------|----------|-------------|
| [`../README.md`](../README.md) | All | Top-level overview of the Slate Dlang + Slint desktop framework, `slate:solid` SolidJS cross-compiler, MCP automation, networking, and `just` commands |
| [`../AGENTS.md`](../AGENTS.md) | AI Agents & Developers | Master project instructions, scoped `AGENTS.md` index, `slate-dev` toolchain, `just` recipes, and workflow rules |
| [`../slate-dlang/README.md`](../slate-dlang/README.md) | Developers | Architecture and layer map for the 5 DUB subpackages (`:core`, `:net`, `:mcp`, `:ui`, `:solid`) |
| [`../slate-dlang/packages/core/README.md`](../slate-dlang/packages/core/README.md) | Developers | `slate:core`: themes, tasks, SVG chart paths, and MCP capability traits |
| [`../slate-dlang/packages/net/README.md`](../slate-dlang/packages/net/README.md) | Developers | `slate:net`: sans-I/O QUIC (`RFC 9000`), HTTP/1.1/2/3, QPACK, and `durl` CLI |
| [`../slate-dlang/packages/mcp/README.md`](../slate-dlang/packages/mcp/README.md) | Developers | `slate:mcp`: embedded JSON-RPC 2.0 MCP server and Slint-free `AutomationEngine` |
| [`../slate-dlang/packages/ui/README.md`](../slate-dlang/packages/ui/README.md) | Developers | `slate:ui`: `AppBuilder`, desktop component controllers, and native Slint MCP backend |
| [`../slate-dlang/packages/solid/README.md`](../slate-dlang/packages/solid/README.md) | Developers | `slate:solid` (`slint2solid`): `.slint` + Dlang controller to SolidJS (`.tsx`) & TypeScript (`.ts`) cross-compiler |
| [`../slint-d/README.md`](../slint-d/README.md) | Developers | `slint-d`: idiomatic Dlang bindings for Slint and modular Rust C-ABI bridge (`slint-d/bridge/`) |
| [`../ui/README.md`](../ui/README.md) | Developers | `ui/`: catalog of all 63 shared `.slint` components and layouts + `SlateTheme` tokens |
| [`../slate-dev/README.md`](../slate-dev/README.md) | All | Portable installer (`./slate-dev/install.sh`) for `dmd`, `dub`, `serve-d`, `dcd`, `dscanner`, `dfmt`, `slint-lsp`, and the Antigravity plugin |
| [`../examples/README.md`](../examples/README.md) | All | Standalone example applications (`examples/file-manager/`, `slint-d/examples/`) |

---

## 2. Scoped `AGENTS.md` Instructions

| File | Scope |
|------|-------|
| [`../AGENTS.md`](../AGENTS.md) | Repository root |
| [`../slate-dlang/AGENTS.md`](../slate-dlang/AGENTS.md) | `slate-dlang` framework & DUB subpackage rules |
| [`../slate-dlang/packages/solid/AGENTS.md`](../slate-dlang/packages/solid/AGENTS.md) | `slate:solid` (`slint2solid`) compiler & D-to-TS transpiler rules |
| [`../slint-d/AGENTS.md`](../slint-d/AGENTS.md) | `slint-d` D bindings & Rust C-ABI FFI safety rules |
| [`../ui/AGENTS.md`](../ui/AGENTS.md) | `ui/` declarative `.slint` component authoring & `SlateTheme` rules |
| [`../slate-dev/rules/AGENTS.md`](../slate-dev/rules/AGENTS.md) | `slate-dev` Antigravity plugin rules |

---

## 3. Style Guides (`docs/guides/`)

| Guide | Audience | Description |
|-------|----------|-------------|
| [`guides/style-dlang.md`](guides/style-dlang.md) | All | Dlang conventions (`dfmt`, `dscanner`, `@safe`, Design-by-Contract, MCP traits, `// Spec:` unittests) |
| [`guides/style-slint.md`](guides/style-slint.md) | All | Slint conventions (`SlateTheme` tokens, `Slate*` naming, accessibility roles, `slint2solid` compatibility) |
| [`guides/style-general.md`](guides/style-general.md) | All | Git commit conventions, file naming, documentation rules, and agent coordination |
| [`guides/tool-selection.md`](guides/tool-selection.md) | AI Agents | Process for proposing and vetting new dependencies or tools |
| [`guides/style-typescript.md`](guides/style-typescript.md) | Reference / Web | TypeScript conventions (`slate:solid` output & `reference/frontend`) |
| [`guides/style-python.md`](guides/style-python.md) | Reference | Python conventions (`slate-dev/mcp/` & `reference/backend`) |
| [`guides/style-yaml.md`](guides/style-yaml.md) | Reference | YAML conventions |

---

## 4. Assistant Skills (`/.agents/skills/`)

| Skill | File | Purpose |
|-------|------|---------|
| `dlang-lsp-tooling` | [`../.agents/skills/dlang-lsp-tooling/SKILL.md`](../.agents/skills/dlang-lsp-tooling/SKILL.md) | Inspect, lint, format, and query AST/LSP symbols for `.d` and `.slint` files |
| `slate-agent-control` | [`../.agents/skills/slate-agent-control/SKILL.md`](../.agents/skills/slate-agent-control/SKILL.md) | Inspect, interact with, automate, and capture visual snapshots of Slate apps via MCP |
| `adversarial-tdd-workflow` | [`../.agents/skills/adversarial-tdd-workflow/SKILL.md`](../.agents/skills/adversarial-tdd-workflow/SKILL.md) | Multi-agent TDD implementation + fresh-context adversarial spec & security review workflow |
| `test-driven-development` | [`../.agents/skills/test-driven-development/SKILL.md`](../.agents/skills/test-driven-development/SKILL.md) | Red-Green-Iterate TDD workflow and `// Spec:` / `/// Example:` test documentation conventions |
| `architect` | [`../.agents/skills/architect/SKILL.md`](../.agents/skills/architect/SKILL.md) | Evidence-driven architectural planning and EARS specification authoring (`.agents/plans/`) |
| `debug-failure-analysis` | [`../.agents/skills/debug-failure-analysis/SKILL.md`](../.agents/skills/debug-failure-analysis/SKILL.md) | Root-cause analysis, dataflow modeling, and regression isolation |
| `git-commit-workflow` | [`../.agents/skills/git-commit-workflow/SKILL.md`](../.agents/skills/git-commit-workflow/SKILL.md) | Structured commit conventions, pre-commit security scan, and user consent rules |
| `docs-usage` | [`../.agents/skills/docs-usage/SKILL.md`](../.agents/skills/docs-usage/SKILL.md) | Documentation structure and maintenance rules |
| `scripts-usage` | [`../.agents/skills/scripts-usage/SKILL.md`](../.agents/skills/scripts-usage/SKILL.md) | Reference for `Justfile` recipes and `scripts/` utilities |
