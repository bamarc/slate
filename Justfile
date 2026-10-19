# Justfile — Polyglot task runner for Slate (Dlang + Slint + SolidJS + Rust Bridge)
# Run `just` with no args to list available recipes, or use `dub` directly from the root.

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

export PATH := env_var("HOME") + "/.local/bin:" + env_var("PATH")

# Default recipe: show available commands
default:
    @just --list --unsorted

# ── Toolchain, Linting & Workspace Hygiene ─────────────────────────────────

# Install or update the portable slate-dev toolchain (DMD, DUB, serve-d, DCD, dscanner, dfmt, slint-lsp, plugin)
d-setup *args:
    ./slate-dev/install.sh {{args}}

# Verify installed Dlang & Slint LSP/linter/formatter toolchain and Antigravity plugin
d-check:
    ./slate-dev/install.sh --check

# Full workspace lint & build gate (dscanner + Rust bridge fmt/clippy + dub build)
lint: d-lint
    cd slint-d/bridge && cargo fmt --check && cargo clippy -- -D warnings
    dub build --root=slint-d
    dub build --root=slate-dlang

# Run D-Scanner syntax and static analysis checks across slint-d, slate-dlang, slate-encoding, and examples
d-lint:
    dscanner --syntaxCheck slint-d/source slate-dlang/source slate-dlang/packages/*/source slate-encoding/source examples/file-manager/source
    dscanner --styleCheck --config dscanner.ini slint-d/source slate-dlang/source slate-dlang/packages/*/source slate-encoding/source examples/file-manager/source

# Format all D source files in-place with dfmt
d-fmt:
    find slint-d/source slint-d/examples slate-dlang/source slate-dlang/packages slate-encoding/source examples -name '*.d' -exec dfmt -i {} +

# Clean DUB/Dlang build artifacts, test runner binaries, and caches
clean *args:
    ./scripts/clean.sh {{args}}

# Print a compact workspace context snapshot for AI agents
ctx *args:
    ./scripts/agent-context.sh {{args}}

# Provision a new Slate project (Window + Button + Counter + MCP Switch + mcp_config.json)
new-project target_dir app_name="":
    ./scripts/new-project.sh "{{target_dir}}" {{app_name}}

# ── Building & Codegen ─────────────────────────────────────────────────────

# Build the Rust C-ABI bridge (libslint_d_bridge) for slint-d
d-bridge:
    cd slint-d/bridge && cargo build

# Build the slint-d library (pure-D configuration)
d-build:
    dub build --root=slint-d

# Build the slate-dlang umbrella library (pure-D configuration)
slate-build:
    dub build --root=slate-dlang

# Compile ui/*.slint and Dlang controllers into SolidJS TypeScript package (target/solid-ui)
solid-codegen out_dir="target/solid-ui":
    dub run --root=slate-dlang :solid --config=slint2solid -- ../ui ../{{out_dir}}

# Generate Ddoc HTML documentation on demand into slate-dlang/docs/
d-docs:
    dub build --root=slate-dlang --build=docs

# ── Testing (DUB Suites) ───────────────────────────────────────────────────

# Run all pure-D unit tests across slint-d, slate-dlang, slate-encoding, and examples
test: d-test slate-test d-encoding-test file-manager-test

# Run slate-encoding pure-D unit tests (QOI, QOIV, QOA, LOC)
d-encoding-test:
    dub test --root=slate-encoding

# Run slint-d pure-D unit tests (15 modules)
d-test:
    dub test --root=slint-d

# Run slint-d native unit tests with headless software renderer
d-test-native: d-bridge
    LD_LIBRARY_PATH="$PWD/slint-d/bridge/target/debug:${LD_LIBRARY_PATH:-}" SLINT_BACKEND=software dub test --root=slint-d --config=native

# Run slate-dlang umbrella pure-D unit tests
slate-test:
    dub test --root=slate-dlang

# Run slate-dlang umbrella native Slint + MCP E2E unit tests with headless software renderer
slate-test-native: d-bridge
    LD_LIBRARY_PATH="$PWD/slint-d/bridge/target/debug:${LD_LIBRARY_PATH:-}" SLINT_BACKEND=software dub test --root=slate-dlang --config=native

# Run slate:core subpackage pure-D unit tests
slate-test-core:
    dub test --root=slate-dlang :core

# Run slate:net subpackage unit tests (HTTP + QUIC)
slate-test-net:
    dub test --root=slate-dlang :net

# Run slate:mcp subpackage unit tests (automation engine + MCP protocol)
slate-test-mcp:
    dub test --root=slate-dlang :mcp

# Run slate:ui subpackage pure-D unit tests
slate-test-ui:
    dub test --root=slate-dlang :ui

# Run slate:ui subpackage native Slint unit tests with headless software renderer
slate-test-ui-native: d-bridge
    LD_LIBRARY_PATH="$PWD/slint-d/bridge/target/debug:${LD_LIBRARY_PATH:-}" SLINT_BACKEND=software dub test --root=slate-dlang :ui --config=native

# Run slate:solid subpackage unit tests (.slint compiler + D-to-TS transpiler + Node/esbuild E2E)
slate-test-solid:
    dub test --root=slate-dlang :solid

# Run examples/file-manager unit tests
file-manager-test:
    dub test --root=examples/file-manager

# ── Examples & Visual Snapshots ────────────────────────────────────────────

# Run the slint-d hello example (pure-D demo)
d-example:
    dub run --root=slint-d/examples/hello

# Render the Slate showcase gallery from D offscreen into renders/dlang-gallery
d-gallery out_dir="../../../renders/dlang-gallery": d-bridge
    cd slint-d/examples/gallery && LD_LIBRARY_PATH="$PWD/../../bridge/target/debug:${LD_LIBRARY_PATH:-}" SLINT_BACKEND=software dub run --config=native -- {{out_dir}}

# Launch the interactive Slate showcase gallery window from D
d-gallery-live: d-bridge
    cd slint-d/examples/gallery && LD_LIBRARY_PATH="$PWD/../../bridge/target/debug:${LD_LIBRARY_PATH:-}" dub run --config=native -- --live
