#!/usr/bin/env bash
# format.sh — ruff format + prettier.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "━━━ 🐍 ruff format ━━━"
(cd backend && uv run ruff format .)
(cd backend && uv run ruff check . --fix)

echo "━━━ ⚛️  prettier ━━━"
if (cd frontend && [ -f node_modules/.bin/prettier ]); then
  (cd frontend && pnpm exec prettier --write .)
else
  echo " ℹ️  prettier not installed in frontend; run 'pnpm add -D prettier' first"
fi
