---
name: scripts-usage
description: 'Reference for every script in scripts/ and the matching `just <target>` recipe. Use this when the user asks "how do I X", wants to setup/test/lint/format/codegen/clean, or seems unsure which recipe applies.'
allowed-tools: [shell]
---

# Scripts & Justfile Reference

This project provides a top-level **`Justfile`** and helper scripts in **`slate-dev/`** and **`scripts/`**. Always prefer `just <recipe>` from the repository root.

## Decision Table — Pick the Right Recipe

| User Intent | `just` Recipe | Underlying Command / Script |
|---|---|---|
| Install or update Dlang + Slint toolchain & plugin | `just d-setup` | `./slate-dev/install.sh` |
| Verify installed toolchain & plugin | `just d-check` | `./slate-dev/install.sh --check` |
| Lint Dlang, Rust bridge & verify DUB builds | `just lint` | `just d-lint` + `cargo fmt/clippy` + `dub build` |
| Run `dscanner` syntax & style checks | `just d-lint` | `dscanner --syntaxCheck ... && dscanner --styleCheck ...` |
| Format all `.d` files in-place | `just d-fmt` | `dfmt -i ...` |
| Build Rust C-ABI bridge (`libslint_d_bridge`) | `just d-bridge` | `cd slint-d/bridge && cargo build` |
| Run `slint-d` pure-D unit tests | `just d-test` | `cd slint-d && dub test` |
| Run `slint-d` native software-rendered tests | `just d-test-native` | `cd slint-d && SLINT_BACKEND=software dub test --config=native` |
| Run all `slate-dlang` pure-D unit tests | `just slate-test` | `cd slate-dlang && dub test` |
| Run all `slate-dlang` native E2E tests | `just slate-test-native` | `cd slate-dlang && SLINT_BACKEND=software dub test --config=native` |
| Run individual `slate-dlang` subpackage tests | `just slate-test-{core,net,mcp,ui,solid}` | `cd slate-dlang && dub test :<subpkg>` |
| Compile `ui/*.slint` + D controllers to SolidJS | `just solid-codegen` | `cd slate-dlang && dub run :solid --config=slint2solid ...` |
| Generate Ddoc HTML documentation on demand | `just d-docs` | `cd slate-dlang && dub build --build=docs` |
| Run File Manager example tests | `just file-manager-test` | `cd examples/file-manager && dub test` |
| Clean DUB build artifacts & test binaries | `just clean` | `./scripts/clean.sh` |
| Print workspace context snapshot | `just ctx` | `./scripts/agent-context.sh` |
| Run pre-commit secret & dependency scan | — | `./scripts/security-scan.sh` |

## Rules

- Run from the **repository root** — `Justfile` resolves paths relative to it.
- Generated files (`target/solid-ui/`, `slate-dlang/docs/`, `slint-d/docs/`) are gitignored and rebuilt on demand.
- Confirm with the user before running `--hard` cleanup (`./scripts/clean.sh --hard` or `just down-hard`).
