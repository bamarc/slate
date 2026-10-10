# Justfile — Central entry point for Slate UI Framework
# Run `just` with no args to list available recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

# Default recipe: show the menu
default:
    @just --list --unsorted

# ── Slate UI Framework ─────────────────────────────────────

# Build all crates in the Slate workspace
build:
    cargo build --workspace

# Fast check compilation of all workspace crates without emitting binaries
check:
    cargo check --workspace

# Run all unit and integration tests across the Slate workspace
test:
    cargo test --workspace

# Launch the interactive Slate desktop showcase application (Desktop layout)
run:
    cargo run -p slate-showcase

# Alias for run
showcase: run

# Launch the interactive Slate WebApp mirror showcase (Web layout matching webapp 1:1)
web-mirror:
    cargo run -p slate-showcase --bin web_mirror

# Render offline pixel-perfect PNG snapshots of all views into the output directory
render out_dir="renders":
    SLINT_BACKEND=software cargo run -p slate-showcase --bin render -- snapshot {{out_dir}}

# Optically compare two snapshots and generate a visual diff heatmap: `just compare a.png b.png diff.png [threshold%]`; exits non-zero above threshold
compare img_a img_b diff_out="renders/optical-diff.png" threshold="0.0":
    SLINT_BACKEND=software cargo run -p slate-showcase --bin render -- compare {{img_a}} {{img_b}} {{diff_out}} --threshold {{threshold}}

# Optical regression gate: render to a temp dir and compare against examples/showcase/golden/
optical-check:
    #!/usr/bin/env bash
    set -euo pipefail
    golden=examples/showcase/golden
    if [ ! -d "$golden" ] || [ -z "$(ls -A "$golden" 2>/dev/null)" ]; then
        echo "✗ No golden images in $golden — nothing to compare against."
        echo "  Run 'just optical-bless' to generate them, review them, and commit."
        exit 1
    fi
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    SLINT_BACKEND=software cargo run -q -p slate-showcase --bin render -- snapshot "$tmp"
    SLINT_BACKEND=software cargo run -q -p slate-showcase --bin render -- check "$golden" "$tmp"

# Regenerate golden images from the current UI (review them before committing!)
optical-bless:
    SLINT_BACKEND=software cargo run -p slate-showcase --bin render -- snapshot examples/showcase/golden
    @echo "⚠ Golden images regenerated in examples/showcase/golden — review before committing."

# Format Rust code across all workspace crates
fmt:
    cargo fmt --all

# Clean Cargo build artifacts
clean-slate:
    cargo clean

# ── Legacy Webapp Stack (Preserved) ─────────────────────────

# Start the full docker compose stack (db + backend + frontend) attached.
dev: _ensure-env
    scripts/dev.sh

# Bring the compose stack up in the background.
up: _ensure-env
    docker compose up -d --build

# Stop and remove the compose stack (keeps volumes).
down:
    docker compose down

# Hard reset: stop + remove containers AND the postgres volume.
down-hard:
    docker compose down -v

# Tail logs for all services (or one: `just logs backend`).
logs service="":
    docker compose logs -f {{service}}

# Open a psql shell on the db container.
psql:
    docker compose exec db psql -U "${POSTGRES_USER:-postgres}" "${POSTGRES_DB:-postgres}"

# Backend pytest + frontend vitest.
test-legacy:
    scripts/test.sh

# Backend tests only.
test-backend *args:
    scripts/test.sh backend {{args}}

# Frontend tests only.
test-frontend *args:
    cd frontend && pnpm test {{args}}

# Frontend lint only.
lint-frontend:
    cd frontend && pnpm lint

# Frontend TypeScript typecheck only.
typecheck-frontend:
    cd frontend && pnpm exec tsc --noEmit

# Regenerate backend models + frontend client from api/openapi.yaml.
generate:
    scripts/generate.sh

# Apply all pending alembic migrations.
migrate:
    scripts/migrate.sh upgrade

# Ensure .env exists — copies from .env.example on first run.
_ensure-env:
    @test -f .env || { echo "⚠  No .env found. Copying .env.example → .env"; echo "Edit .env to set secrets, then re-run."; cp .env.example .env; exit 1; }
