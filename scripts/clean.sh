#!/usr/bin/env bash
# clean.sh — wipe caches and generated artifacts. Idempotent.
# Usage:
#   scripts/clean.sh            # caches only
#   scripts/clean.sh --all      # also remove generated code + lockfiles? (asks)
#   scripts/clean.sh --hard     # nuke node_modules and .venv too
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-soft}"

echo " 🧹 Cleaning caches..."
find . -type d \( \
    -name "__pycache__" -o \
    -name ".pytest_cache" -o \
    -name ".ruff_cache" -o \
    -name ".mypy_cache" -o \
    -name ".vite" -o \
    -name "coverage" -o \
    -name "htmlcov" \
  \) -not -path "*/node_modules/*" -not -path "*/.venv/*" -prune -exec rm -rf {} +
rm -rf backend/.coverage frontend/.eslintcache

echo " 🧹 Cleaning build outputs..."
rm -rf frontend/dist backend/dist

echo " 🧹 Cleaning generated code..."
rm -rf backend/app/models/_generated frontend/src/api/generated

if [ "$MODE" = "--hard" ]; then
  echo " 💣 Removing node_modules and .venv..."
  rm -rf frontend/node_modules backend/.venv
fi

echo " ✅ Clean complete."
