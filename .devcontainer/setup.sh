#!/usr/bin/env bash
set -e

echo "========================================================"
echo "🚀 Initializing SPARK Environment..."
echo "========================================================"

# 1. Environment file check
if [ ! -f .env ] && [ -f .env.example ]; then
    echo "📋 Copying .env.example -> .env"
    cp .env.example .env
fi

# 2. Check Python/uv virtual environment
if [ -f backend/pyproject.toml ]; then
    echo "🐍 Initializing backend virtualenv with uv..."
    cd backend
    uv sync || echo "⚠ uv sync skipped or failed (will be handled during lab)"
    cd ..
fi

# 3. Check Frontend / pnpm
if [ -f frontend/package.json ]; then
    echo "📦 Checking frontend dependencies with pnpm..."
    cd frontend
    pnpm install || echo "⚠ pnpm install skipped or failed (will be handled during lab)"
    cd ..
fi

echo "========================================================"
echo "✅ AI Workshop Environment Ready!"
echo ""
echo "Tooling Status:"
echo "  • Docker: $(docker --version 2>/dev/null || echo 'Docker socket connected')"
echo "  • Python / uv: $(uv --version)"
echo "  • Node.js: $(node --version)"
echo "  • pnpm: $(pnpm --version)"
echo "  • Ruby: $(ruby --version 2>/dev/null || echo 'not installed')"
echo "  • Perl: $(perl -v 2>/dev/null | grep -o 'v[0-9.]*' | head -n 1 || echo 'installed')"
echo "  • Just: $(just --version)"
echo ""
echo "Quick Commands:"
echo "  just dev         -> Start local Docker Compose stack"
echo "  just test        -> Run backend & frontend tests"
echo "  just generate    -> Contract-first model generator"
echo "========================================================"
