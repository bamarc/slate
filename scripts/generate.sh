#!/usr/bin/env bash
# generate.sh
# Synchronises backend Pydantic models and frontend API client from
# the OpenAPI spec (api/openapi.yaml). Run from the project root.
#
# Usage:
#   ./generate.sh            # full regeneration
#   ./generate.sh --dry-run  # show what would be generated
#
# Requires:
#   - backend: uv (managed Python + datamodel-code-generator)
#   - frontend: pnpm (managed Node + orval)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$ROOT_DIR/api/openapi.yaml"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

# ── Guardrails ──────────────────────────────────────────────
if [ ! -f "$SPEC" ]; then
  echo "❌ OpenAPI spec not found at $SPEC"
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🚀 OpenAPI Code Generation"
echo "    Spec: $SPEC"
[ "$DRY_RUN" = true ] && echo "    Mode: dry-run (no files written)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Step 1: Generate backend Pydantic models ────────────────
echo ""
echo " 📦 [1/2] Backend — Pydantic models"

BACKEND_DIR="$ROOT_DIR/backend"
BACKEND_OUTPUT="$BACKEND_DIR/app/models/_generated"

if [ "$DRY_RUN" = true ]; then
  echo "    → Would generate: $BACKEND_OUTPUT/__init__.py"
else
  cd "$BACKEND_DIR"

  # Ensure datamodel-code-generator is available
  if ! uv run datamodel-codegen --version &>/dev/null; then
    echo "    ⚠️  datamodel-code-generator not found, running uv sync..."
    uv sync
  fi

  rm -rf "$BACKEND_OUTPUT"
  mkdir -p "$BACKEND_OUTPUT"

  uv run datamodel-codegen \
    --input "$SPEC" \
    --input-file-type openapi \
    --output "$BACKEND_OUTPUT/__init__.py" \
    --output-model-type pydantic_v2.BaseModel \
    --target-python-version 3.12 \
    --use-schema-description \
    --collapse-root-models \
    --field-constraints \
    --snake-case-field \
    --allow-population-by-field-name

  echo "    ✅ Generated: $BACKEND_OUTPUT"
fi

# ── Step 2: Generate frontend API client ────────────────────
echo ""
echo " 🎨 [2/2] Frontend — TypeScript API client"

FRONTEND_DIR="$ROOT_DIR/frontend"
FRONTEND_OUTPUT="$FRONTEND_DIR/src/api/generated"

if [ "$DRY_RUN" = true ]; then
  echo "    → Would generate: $FRONTEND_OUTPUT/"
else
  cd "$FRONTEND_DIR"

  # Ensure orval is available
  if [ ! -f "node_modules/.bin/orval" ]; then
    echo "    ⚠️  orval not found, running pnpm install..."
    npx pnpm install
  fi

  rm -rf "$FRONTEND_OUTPUT"
  npx pnpm orval

  echo "    ✅ Generated: $FRONTEND_OUTPUT"

  # Count generated files
  GEN_COUNT=$(find "$FRONTEND_OUTPUT" -type f 2>/dev/null | wc -l)
  echo "       $GEN_COUNT files"
fi

# ── Report ──────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ Generation complete"
echo ""
echo "    Backend models:  backend/app/models/_generated/"
echo "    Frontend client: frontend/src/api/generated/"
echo ""
echo "    ⚠️  Generated files are gitignored; rebuild them in build/CI/dev."
echo "    ⚠️  NEVER edit generated files directly."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
