#!/usr/bin/env bash
# bootstrap.sh — install all toolchains and dependencies, set up git hooks.
# Run once after cloning. Idempotent.
#
# Usage: scripts/bootstrap.sh [--no-hooks]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

INSTALL_HOOKS=true
[ "${1:-}" = "--no-hooks" ] && INSTALL_HOOKS=false

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🥾 Bootstrap"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Tool prerequisites ─────────────────────────────────────
require() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing: $1 — please install it first."; exit 1; }
}
require git
require uv
require pnpm

# ── Backend ────────────────────────────────────────────────
echo ""
echo " 🐍 Backend — uv sync (all extras + dev)"
(cd backend && uv sync --all-extras)

# ── Frontend ───────────────────────────────────────────────
echo ""
echo " 📦 Frontend — pnpm install"
(cd frontend && pnpm install --frozen-lockfile || pnpm install)

# ── Git hooks ──────────────────────────────────────────────
if [ "$INSTALL_HOOKS" = true ]; then
  echo ""
  echo " 🔗 Git hooks"
  "$ROOT_DIR/scripts/setup-hooks.sh"

  if command -v pre-commit >/dev/null 2>&1; then
    echo ""
    echo " 🪝 pre-commit framework"
    pre-commit install --install-hooks
  else
    echo ""
    echo " ℹ️  pre-commit not installed (optional). Install with:"
    echo "     uv tool install pre-commit && pre-commit install"
  fi
fi

# ── .env scaffold ──────────────────────────────────────────
if [ ! -f "$ROOT_DIR/.env" ] && [ -f "$ROOT_DIR/.env.example" ]; then
  echo ""
  echo " 📝 Creating .env from .env.example (edit secrets before running compose!)"
  cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ Bootstrap complete."
echo ""
echo "    Next:"
echo "      scripts/generate.sh   # regenerate API client + models"
echo "      scripts/dev.sh        # start the full stack"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
