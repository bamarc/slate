#!/usr/bin/env bash
# generate-from-openapi.sh
# Wipes the generated frontend API client files and regenerates from the
# OpenAPI spec using Orval. Run from the project root.
#
# Usage: .github/skills/code-generation/generate-from-openapi.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
GENERATED_DIR="$ROOT_DIR/frontend/src/api/generated"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🚀 Code Generation: OpenAPI → Frontend"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Step 1: Verify OpenAPI spec exists
if [ ! -f "$ROOT_DIR/api/openapi.yaml" ]; then
  echo " ❌ OpenAPI spec not found at api/openapi.yaml"
  exit 1
fi
echo " ✅ Found OpenAPI spec: api/openapi.yaml"

# Step 2: Wipe existing generated files
if [ -d "$GENERATED_DIR" ]; then
  echo " 🗑️  Wiping existing generated files..."
  rm -rf "$GENERATED_DIR"
  echo "    Removed: $GENERATED_DIR"
fi

# Step 3: Regenerate via Orval
echo " 🔄 Regenerating frontend API client..."
cd "$ROOT_DIR/frontend"

if [ ! -f "node_modules/.bin/orval" ]; then
  echo " ⚠️  Orval not found. Running pnpm install first..."
  pnpm install
fi

pnpm orval
echo " ✅ Generation complete"

# Step 4: Report
echo ""
echo " 📦 Generated files:"
find "$GENERATED_DIR" -type f 2>/dev/null | sed 's/^/    • /' | head -20

GENERATED_COUNT=$(find "$GENERATED_DIR" -type f 2>/dev/null | wc -l)
echo ""
echo "   $GENERATED_COUNT files regenerated"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " 💡 Review and commit the generated files alongside your API changes."
