#!/usr/bin/env bash
# test.sh — run backend + frontend tests.
# Usage:
#   scripts/test.sh            # both
#   scripts/test.sh backend
#   scripts/test.sh frontend
#   scripts/test.sh --watch    # frontend watch mode
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="${1:-all}"
EXIT=0

# Ensure .env exists if .env.example is present (needed for docker compose variable interpolation)
if [ ! -f "$ROOT_DIR/.env" ] && [ -f "$ROOT_DIR/.env.example" ]; then
  echo "ℹ️  Creating .env from .env.example for local test stack..."
  cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
fi

# Ensure generated OpenAPI models and frontend client exist before testing
if [ ! -d "$ROOT_DIR/backend/app/models/_generated" ] || [ ! -d "$ROOT_DIR/frontend/src/api/generated" ]; then
  echo "━━━ ⚙️  Generating OpenAPI client & models ━━━"
  "$ROOT_DIR/scripts/generate.sh"
fi

run_backend() {
  echo "━━━ 🐍 backend pytest ━━━"
  # DB-backed tests use a DEDICATED test database (compose `test-db` service,
  # separate container + volume) — never the dev database. If Docker is
  # available, start it and point pytest at it. PostgreSQL is mandatory because
  # the models use PostgreSQL-specific types such as JSONB.
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose --profile test up -d --wait test-db >/dev/null 2>&1 || true
    export TEST_DATABASE_URL="${TEST_DATABASE_URL:-postgresql+asyncpg://postgres:postgres@localhost:${TEST_POSTGRES_PORT:-5434}/${{ values.projectName | replace('-', '_') }}_test}"
  fi
  (cd backend && uv run pytest "${@:2}") || EXIT=1
}

run_frontend() {
  echo "━━━ ⚛️  frontend vitest ━━━"
  if [ "${1:-}" = "--watch" ]; then
    (cd frontend && pnpm test:watch)
  else
    (cd frontend && pnpm test "$@") || EXIT=1
  fi
}

case "$TARGET" in
  backend) run_backend "$@" ;;
  frontend) shift; run_frontend "$@" ;;
  --watch) run_frontend "$TARGET" --watch ;;
  all|*) run_backend; run_frontend ;;
esac

exit $EXIT
