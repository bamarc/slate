# Contributing to Slate

Thanks for your interest in contributing to **Slate** (`slate-dlang`, `slint-d`, `ui`, and `slate:solid`). We value **small, test-driven, reviewable changes** with zero linter warnings.

## 1. Environment Setup

Install the portable Dlang (`dmd`, `dub`, `serve-d`, `dcd`, `dscanner`, `dfmt`) and Slint (`slint-lsp`, `slint-viewer`) toolchain and build the Rust C-ABI bridge:

```bash
just d-setup
just d-check
just d-bridge
```

## 2. Before You Commit or Push

Run the workspace lint, formatting, test, and security gates from the repository root:

```bash
just d-fmt                # Format all .d files with dfmt
just lint                 # dscanner syntax/style + Rust bridge clippy/fmt + dub build
just d-test               # slint-d pure-D unit tests
just slate-test           # slate-dlang (:core, :net, :mcp, :ui, :solid) unit tests
just slate-test-solid     # slint2solid compiler + Node/esbuild runtime verification
./scripts/security-scan.sh
```

When touching native Slint bindings or UI rendering, also run the headless software-rendered suites:

```bash
just d-test-native
just slate-test-native
```

## 3. Development Workflow

1. **Test-Driven Development (`Red → Green → Iterate`)**:
   - Every behavioral change starts with a focused `unittest` annotated with a `// Spec:` requirement header and `/// Example:` Ddoc block (see [`docs/guides/style-dlang.md`](docs/guides/style-dlang.md)).
2. **Architecture & Planning**:
   - Non-trivial features or architectural changes begin with an EARS/Gherkin specification plan in `.agents/plans/YYYYMMDD-HHMMSS-<topic>.md`.
3. **Branch Naming & Commits**:
   - Branch names: `type/short-description` (e.g., `feat/rework-mcp`, `fix/quic-flow-control`).
   - Commits: Conventional Commits + DCO sign-off (`git commit -s`), validated via `python3 scripts/validate-commit-msg.py`.

## 4. Style Guides & Scoped Rules

- **Dlang**: [`docs/guides/style-dlang.md`](docs/guides/style-dlang.md), [`slate-dlang/AGENTS.md`](slate-dlang/AGENTS.md), [`slint-d/AGENTS.md`](slint-d/AGENTS.md)
- **Slint UI**: [`docs/guides/style-slint.md`](docs/guides/style-slint.md), [`ui/AGENTS.md`](ui/AGENTS.md)
- **SolidJS Cross-Compiler**: [`slate-dlang/packages/solid/AGENTS.md`](slate-dlang/packages/solid/AGENTS.md)
- **General & Git**: [`docs/guides/style-general.md`](docs/guides/style-general.md)

## 5. Adding Dependencies

Slate keeps its dependency footprint minimal (`slate:core` and `slate:mcp` have zero external dependencies). Before adding any DUB, Cargo, or npm dependency:
1. Review [`docs/guides/tool-selection.md`](docs/guides/tool-selection.md).
2. Obtain explicit maintainer approval and run `./scripts/security-scan.sh`.

## 6. Reporting Security Issues

Do **not** open a public issue for security vulnerabilities. See [`SECURITY.md`](SECURITY.md).
