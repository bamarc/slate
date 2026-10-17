#!/usr/bin/env bash
# security-scan.sh — Scans codebase for secrets (gitleaks) and vulnerable dependencies.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

BLOCK_COMMIT=0

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🔒 Security Scan"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Secret Scanning via Gitleaks
if command -v gitleaks >/dev/null 2>&1; then
  echo "🔍 Running Gitleaks secret scan..."
  if ! gitleaks protect --staged --verbose --redact; then
    echo "❌ Gitleaks: Secrets detected in staged changes!"
    BLOCK_COMMIT=1
  else
    echo "✅ Gitleaks: No secrets detected in staged changes."
  fi
else
  echo "⚠️  Gitleaks not installed on host. Skipping local secret detection."
fi

# 2. Dependency Manifest Checks (DUB, Cargo, Reference Python/Node)
echo ""
echo "🔍 Checking staged dependency manifest changes..."

CHANGED_DEPS=$(git diff --cached --name-only -- \
  'slint-d/bridge/Cargo.toml' \
  'slint-d/dub.json' \
  'slate-dlang/dub.json' \
  'slate-dlang/packages/*/dub.json' \
  'reference/backend/pyproject.toml' \
  'reference/frontend/package.json' 2>/dev/null || true)

if [ -n "$CHANGED_DEPS" ]; then
  for dep_file in $CHANGED_DEPS; do
    if [ ! -f "$dep_file" ]; then
      continue
    fi
    echo "📦 Staged dependency file modified: $dep_file"
    if [[ "$dep_file" == *"Cargo.toml"* ]] && [ -x "$ROOT_DIR/scripts/check-package-security.sh" ]; then
      "$ROOT_DIR/scripts/check-package-security.sh" "$dep_file" || BLOCK_COMMIT=1
    fi
    if [[ "$dep_file" == *"package.json"* ]]; then
      echo "📦 Scanning Frontend (pnpm audit)..."
      (cd "$(dirname "$dep_file")" && pnpm audit --prod --audit-level=high) || {
        echo "❌ Frontend has high/critical vulnerability dependencies."
        BLOCK_COMMIT=1
      }
    fi
    if [[ "$dep_file" == *"pyproject.toml"* ]]; then
      echo "📦 Scanning Backend (pip-audit)..."
      if command -v uv >/dev/null 2>&1; then
        (cd "$(dirname "$dep_file")" && uv pip compile pyproject.toml -o requirements.txt && uv run pip-audit --no-deps --disable-pip -r requirements.txt && rm requirements.txt) || {
          echo "❌ Backend has vulnerability dependencies."
          BLOCK_COMMIT=1
        }
      fi
    fi
  done
else
  echo "✅ No dependency manifests changed in staging."
fi

# 3. OSV Scanner (Open Source Vulnerability scanner)
if command -v osv-scanner >/dev/null 2>&1; then
  echo ""
  echo "🔍 Running OSV Scanner..."
  CHANGED_LOCKS=$(git diff --cached --name-only -- \
    'slint-d/bridge/Cargo.lock' \
    'reference/backend/uv.lock' \
    'reference/frontend/pnpm-lock.yaml' 2>/dev/null || true)

  if [ -n "$CHANGED_LOCKS" ]; then
    for lock_file in $CHANGED_LOCKS; do
      if [ -f "$ROOT_DIR/$lock_file" ]; then
        echo "🛡️  Scanning $lock_file with OSV Scanner..."
        osv-scanner scan source --lockfile="$ROOT_DIR/$lock_file" || {
          echo "❌ OSV Scanner found vulnerabilities in $lock_file."
          BLOCK_COMMIT=1
        }
      fi
    done
  else
    echo "✅ No lockfiles changed. Skipping OSV scan."
  fi
else
  echo "⚠️  OSV Scanner not installed on host. Skipping OSV scanning."
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$BLOCK_COMMIT" -eq 1 ]; then
  echo "❌ Security scan failed. Commit blocked."
  exit 1
else
  echo "✅ Security scan passed."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
