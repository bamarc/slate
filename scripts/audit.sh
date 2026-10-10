#!/usr/bin/env bash
# audit.sh — dependency + secret + container security checks.
# Usage:
#   scripts/audit.sh            # everything available locally
#   scripts/audit.sh --strict   # fail on any finding
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

STRICT=""
[ "${1:-}" = "--strict" ] && STRICT="--strict"
EXIT=0

echo "━━━ 🔒 pip-audit (backend) ━━━"
if (cd backend && uv run pip-audit --version >/dev/null 2>&1); then
  (cd backend && uv run pip-audit $STRICT) || [ -z "$STRICT" ] || EXIT=1
else
  echo " ℹ️  pip-audit not in backend deps; skipping"
fi

echo ""
echo "━━━ 🔒 pnpm audit (frontend) ━━━"
if command -v pnpm >/dev/null 2>&1; then
  (cd frontend && pnpm audit --prod --audit-level=high) || [ -z "$STRICT" ] || EXIT=1
fi

echo ""
echo "━━━ 🔍 gitleaks (secrets) ━━━"
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --no-banner --redact -v || EXIT=1
else
  echo " ℹ️  gitleaks not installed; skipping"
fi

echo ""
echo "━━━ 📦 dependency-file pre-commit scan ━━━"
"$ROOT_DIR/scripts/check-package-security.sh" backend/pyproject.toml || true
"$ROOT_DIR/scripts/check-package-security.sh" frontend/package.json || true

echo ""
if command -v trivy >/dev/null 2>&1; then
  echo "━━━ 🐳 trivy fs ━━━"
  trivy fs --severity HIGH,CRITICAL --exit-code "${STRICT:+1}" . || EXIT=1
fi

exit $EXIT
