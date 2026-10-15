# Justfile — Central entry point for Slate UI Framework
# Run `just` with no args to list available recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

# Default recipe: show the menu
default:
    @just --list --unsorted

# ── Slate Rust UI Framework ────────────────────────────────

# Build all crates in the Slate Rust workspace
build:
    cd slate-rust && cargo build --workspace

# Fast check compilation of all workspace crates without emitting binaries
check:
    cd slate-rust && cargo check --workspace

# Run all unit and integration tests across the Slate Rust workspace.
# SLINT_EMIT_DEBUG_INFO=1 is required at BUILD time: Slint's ElementHandle
# query pipeline (targeting, debug-id identity) needs compiler debug info,
# and ANY value enables it (`=0` does NOT disable — only an unset var does).
# Changing the var needs a rebuild of Slint consumers (`cargo clean -p
# <crate>` first): Cargo fingerprints do not track env changes, so a stale
# build keeps the old expansion and the query-path tests fail.
test:
    cd slate-rust && SLINT_EMIT_DEBUG_INFO=1 cargo test --workspace

# Run the comprehensive 4-tier Agent / MCP end-to-end test suite
e2e:
    cd slate-rust && cargo run -p slate-tests --bin e2e_runner

# Launch the interactive Slate desktop showcase application (Desktop layout)
run:
    cd slate-rust && cargo run -p slate-showcase

# Alias for run
showcase: run

# Launch the interactive Slate WebApp mirror showcase (Web layout matching webapp 1:1)
web-mirror:
    cd slate-rust && cargo run -p slate-showcase --bin web_mirror

# Render offline pixel-perfect PNG snapshots of all views into the output directory
render out_dir="renders":
    cd slate-rust && SLINT_BACKEND=software cargo run -p slate-showcase --bin render -- snapshot {{out_dir}}

# Optically compare two snapshots and generate a visual diff heatmap: `just compare a.png b.png diff.png [threshold%]`; exits non-zero above threshold
compare img_a img_b diff_out="renders/optical-diff.png" threshold="0.0":
    cd slate-rust && SLINT_BACKEND=software cargo run -p slate-showcase --bin render -- compare {{img_a}} {{img_b}} {{diff_out}} --threshold {{threshold}}

# Optical regression gate: render to a temp dir and compare against slate-rust/examples/showcase/golden/
optical-check:
    #!/usr/bin/env bash
    set -euo pipefail
    golden=slate-rust/examples/showcase/golden
    if [ ! -d "$golden" ] || [ -z "$(ls -A "$golden" 2>/dev/null)" ]; then
        echo "✗ No golden images in $golden — nothing to compare against."
        echo "  Run 'just optical-bless' to generate them, review them, and commit."
        exit 1
    fi
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    (cd slate-rust && SLINT_BACKEND=software cargo run -q -p slate-showcase --bin render -- snapshot "$tmp")
    (cd slate-rust && SLINT_BACKEND=software cargo run -q -p slate-showcase --bin render -- check "$golden" "$tmp")

# Regenerate golden images from the current UI (review them before committing!)
optical-bless:
    cd slate-rust && SLINT_BACKEND=software cargo run -p slate-showcase --bin render -- snapshot examples/showcase/golden
    @echo "⚠ Golden images regenerated in slate-rust/examples/showcase/golden — review before committing."

# Format Rust code across all workspace crates
fmt:
    cd slate-rust && cargo fmt --all

# Clean Cargo build artifacts
clean-slate:
    cd slate-rust && cargo clean

# Build standalone Linux AppImage for the Slate desktop showcase application
appimage:
    bash slate-rust/packaging/appimage/build.sh

# ── Slate Carbon Bindings ──────────────────────────────────

# Build Slate Carbon application with Google Carbon toolchain
carbon-build:
    slate-carbon/examples/gallery/build.sh

# Compile shared Slint UI markup into C++ header code for Carbon
carbon-ui:
    cd slate-carbon && bazel build //:slint_ui_cpp

# Run the Slate Desktop Component Gallery via Google Carbon
carbon-gallery:
    slate-carbon/examples/gallery/run.sh

# ── Slint-D Bindings ─────────────────────────────────────

# Activate the user-local D toolchain (~/dlang) for the chained command
_dlang:
    @test -d ~/dlang/dmd-*/ 2>/dev/null || { echo "✗ No D toolchain in ~/dlang. Install: curl -fsS https://dlang.org/install.sh | bash -s install dmd"; exit 1; }

# Build the Rust C-ABI bridge (libslint_d_bridge) for slint-d
d-bridge:
    cd slint-d/bridge && cargo build

# Run slint-d pure-D unit tests (no Slint runtime needed)
d-test: _dlang
    bash -c 'source ~/dlang/dmd-*/activate && cd slint-d && dub test'

# Run slint-d native unit tests with headless software renderer
d-test-native: _dlang d-bridge
    bash -c 'source ~/dlang/dmd-*/activate && cd slint-d && LD_LIBRARY_PATH="$PWD/bridge/target/debug:$LD_LIBRARY_PATH" SLINT_BACKEND=software dub test --config=native'

# Build the slint-d library (pure-D configuration)
d-build: _dlang
    bash -c 'source ~/dlang/dmd-*/activate && cd slint-d && dub build'

# Run the slint-d hello example (pure-D demo unless native config is used)
d-example: _dlang
    bash -c 'source ~/dlang/dmd-*/activate && cd slint-d/examples/hello && dub run'

# Render the Slate showcase gallery from D offscreen into renders/dlang-gallery
d-gallery out_dir="../../../renders/dlang-gallery": _dlang
    bash -c 'source ~/dlang/dmd-*/activate && cd slint-d/examples/gallery && LD_LIBRARY_PATH="$PWD/../../bridge/target/debug:$LD_LIBRARY_PATH" SLINT_BACKEND=software dub run --config=native -- {{out_dir}}'

# ── Slate-DLang Framework ────────────────────────────────

# Run slate-dlang pure-D unit tests (no Slint runtime needed)
slate-test: _dlang
    bash -c 'source ~/dlang/dmd-*/activate && cd slate-dlang && dub test'

# Run slate-dlang native Slint + MCP E2E unit tests with headless software renderer
slate-test-native: _dlang d-bridge
    bash -c 'source ~/dlang/dmd-*/activate && cd slate-dlang && LD_LIBRARY_PATH="$PWD/../slint-d/bridge/target/debug:$LD_LIBRARY_PATH" SLINT_BACKEND=software dub test --config=native'

# Build the slate-dlang library (pure-D configuration)
slate-build: _dlang
    bash -c 'source ~/dlang/dmd-*/activate && cd slate-dlang && dub build'

# ── Reference Webapp Stack (reference/) ────────────────────

# Start the reference docker compose stack attached.
dev: _ensure-env
    cd reference && ../scripts/dev.sh

# Bring the reference compose stack up in the background.
up: _ensure-env
    cd reference && docker compose up -d --build

# Stop and remove the reference compose stack (keeps volumes).
down:
    cd reference && docker compose down

# Hard reset: stop + remove containers AND the postgres volume.
down-hard:
    cd reference && docker compose down -v

# Tail logs for all reference services (or one: `just logs backend`).
logs service="":
    cd reference && docker compose logs -f {{service}}

# Open a psql shell on the reference db container.
psql:
    cd reference && docker compose exec db psql -U "${POSTGRES_USER:-postgres}" "${POSTGRES_DB:-postgres}"

# Reference frontend tests.
test-frontend *args:
    cd reference/frontend && pnpm test {{args}}

# Reference frontend lint.
lint-frontend:
    cd reference/frontend && pnpm lint

# Reference frontend TypeScript typecheck.
typecheck-frontend:
    cd reference/frontend && pnpm exec tsc --noEmit

# Ensure reference/.env exists — copies from reference/.env.example on first run.
_ensure-env:
    @test -f reference/.env || { echo "⚠  No reference/.env found. Copying reference/.env.example → reference/.env"; cp reference/.env.example reference/.env; exit 1; }

