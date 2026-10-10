#!/usr/bin/env bash
# setup-hooks.sh
# Configures git to use the project's .githooks directory.
# Run once after cloning the template:
#   ./scripts/setup-hooks.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$ROOT_DIR/.githooks"

echo "🔗 Setting up git hooks..."
git config core.hooksPath "$HOOKS_DIR"
echo "   hooksPath → $HOOKS_DIR"

# Make hooks executable
chmod +x "$HOOKS_DIR"/* 2>/dev/null || true

echo ""
echo "✅ Git hooks configured:"
echo "   • pre-commit  — Security scan for dependency changes"
echo "   • post-commit — Docs-Bot notification"
echo ""
echo "   To disable: git config --unset core.hooksPath"
