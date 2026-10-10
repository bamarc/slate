#!/usr/bin/env bash
# check-package-security.sh
# Scans dependency files for new packages and checks for known vulnerabilities.
# Usage: ./check-package-security.sh [pyproject.toml|package.json|Cargo.toml]

set -euo pipefail

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "Usage: $0 <dependency-file>"
  echo "Checks: pyproject.toml, package.json, Cargo.toml"
  exit 1
fi
# Resolve to an absolute path so subshell directory changes don't affect relative paths
FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

echo "🔍 Security check: $FILE"

case "$(basename "$FILE")" in
  pyproject.toml)
    echo "  → Checking PyPI packages via pip-audit..."
    if command -v uv &>/dev/null; then
      TEMP_REQS=$(mktemp)
      uv pip compile "$FILE" --quiet -o "$TEMP_REQS"
      uv run --project "$(dirname "$FILE")" pip-audit --no-deps --disable-pip --requirement "$TEMP_REQS"
      rm -f "$TEMP_REQS"
    elif command -v pip-audit &>/dev/null; then
      pip-audit --requirement <(grep -A999 'dependencies = \[' "$FILE" | grep -v 'dependencies = \[' | sed -n '/^[[:space:]]*\]/q;p' | sed 's/^[[:space:]]*"//;s/",[[:space:]]*$//')
    else
      echo "  ⚠️  uv or pip-audit not installed; skipping"
    fi
    ;;
  package.json)
    echo "  → Checking npm packages via audit..."
    if [ -f "$FILE" ]; then
      cd "$(dirname "$FILE")" 2>/dev/null
      if command -v pnpm &>/dev/null; then
        pnpm audit --prod --audit-level=high 2>/dev/null || echo "  ⚠️  pnpm audit failed or unavailable"
      else
        npm audit --production 2>/dev/null || echo "  ⚠️  npm audit failed or unavailable"
      fi
    fi
    echo "  → Checking for postinstall scripts..."
    grep -A5 '"postinstall"' "$FILE" && echo "  ⚠️  WARNING: postinstall script found!" || echo "  ✅ No postinstall scripts"
    ;;
  Cargo.toml)
    echo "  → Checking Rust packages via cargo audit..."
    if command -v cargo-audit &>/dev/null; then
      cargo audit --file "$FILE" 2>/dev/null || true
    else
      echo "  ⚠️  cargo-audit not installed. Run: cargo install cargo-audit"
    fi
    ;;
  *)
    echo "  ❌ Unknown dependency file type"
    exit 1
    ;;
esac

echo "✅ Scan complete: $FILE"
