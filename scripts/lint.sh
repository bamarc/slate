#!/usr/bin/env bash
# lint.sh — ruff + mypy + eslint + yamllint.
# Usage: scripts/lint.sh [--fix]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "━━━ generated artifact guard ━━━"
if [ -n "$(git ls-files -- \
  'frontend/src/api/generated/' \
  'backend/app/models/_generated/')" ]; then
  echo "Generated API artifacts must remain untracked; run generation at build/CI/dev time." >&2
  exit 1
fi

# Ensure generated OpenAPI models and frontend client exist before linting
if [ ! -d "$ROOT_DIR/backend/app/models/_generated" ] || [ ! -d "$ROOT_DIR/frontend/src/api/generated" ]; then
  echo "━━━ ⚙️  Generating OpenAPI client & models ━━━"
  "$ROOT_DIR/scripts/generate.sh"
fi

FIX=""
[ "${1:-}" = "--fix" ] && FIX="--fix"
EXIT=0

echo "━━━ 🐍 ruff ━━━"
(cd backend && uv run ruff check . $FIX) || EXIT=1
(cd backend && uv run ruff format --check .) || EXIT=1

if (cd backend && uv run mypy --version >/dev/null 2>&1); then
  echo "━━━ 🐍 mypy ━━━"
  (cd backend && uv run mypy app) || EXIT=1
fi

echo "━━━ ⚛️  eslint ━━━"
(cd frontend && pnpm lint) || EXIT=1

echo "━━━ ⚛️  prettier ━━━"
if (cd frontend && [ -f node_modules/.bin/prettier ]); then
  (cd frontend && pnpm exec prettier --check .) || EXIT=1
else
  echo " ℹ️  prettier not installed in frontend; skipping check"
fi

if command -v yamllint >/dev/null 2>&1; then
  echo "━━━ 📝 yamllint ━━━"
  yamllint -c .yamllint.yaml . || EXIT=1
else
  echo " ℹ️  yamllint not installed; skipping"
fi

exit $EXIT
