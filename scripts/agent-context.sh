#!/usr/bin/env bash
# agent-context.sh — print a compact snapshot of the Slate Dlang + Slint workspace
# so AI agents can orient quickly.
#
# Usage: scripts/agent-context.sh [--json]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

JSON=false
[ "${1:-}" = "--json" ] && JSON=true

GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "n/a")
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "n/a")
GIT_DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
SLINT_FILES=$(find ui -name '*.slint' 2>/dev/null | wc -l | tr -d ' ')
SLINT_D_MODULES=$(find slint-d/source -name '*.d' 2>/dev/null | wc -l | tr -d ' ')
SLATE_D_MODULES=$(find slate-dlang/source slate-dlang/packages/*/source -name '*.d' 2>/dev/null | wc -l | tr -d ' ')
SUBPACKAGES=$(ls -1 slate-dlang/packages 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)
HAS_BRIDGE=$([ -f slint-d/bridge/target/debug/libslint_d_bridge.so ] && echo true || echo false)
HAS_SOLID_UI=$([ -d target/solid-ui ] && echo true || echo false)

if $JSON; then
  cat <<EOF
{
  "git": {"branch": "$GIT_BRANCH", "sha": "$GIT_SHA", "dirty_files": $GIT_DIRTY},
  "slate_dlang": {"subpackages": "$SUBPACKAGES", "d_modules": $SLATE_D_MODULES},
  "slint_d": {"d_modules": $SLINT_D_MODULES, "native_bridge_built": $HAS_BRIDGE},
  "ui": {"slint_files": $SLINT_FILES, "solid_codegen_built": $HAS_SOLID_UI}
}
EOF
else
  cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 📍 Slate Workspace Context Snapshot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 git             : $GIT_BRANCH @ $GIT_SHA  (dirty files: $GIT_DIRTY)
 slate-dlang
   subpackages   : ${SUBPACKAGES:-none}
   D modules     : $SLATE_D_MODULES
 slint-d
   D modules     : $SLINT_D_MODULES
   native bridge : $HAS_BRIDGE
 ui & solid
   .slint files  : $SLINT_FILES
   solid-ui      : $HAS_SOLID_UI
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 Key Agent Instructions:
   AGENTS.md (root), slate-dlang/AGENTS.md, slint-d/AGENTS.md, ui/AGENTS.md
   slate-dlang/packages/solid/AGENTS.md, slate-dev/rules/AGENTS.md
   docs/guides/style-dlang.md, docs/guides/style-slint.md
EOF
fi
