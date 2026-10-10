#!/usr/bin/env bash
# agent-context.sh — print a compact snapshot of project state for AI agents
# so they can orient quickly without re-reading dozens of files.
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
DOMAINS=$(ls -1 backend/app/domains 2>/dev/null | grep -v __ | tr '\n' ',' | sed 's/,$//' || true)
ROUTES=$(ls -1 backend/app/api/v1 2>/dev/null | grep -v __ | tr '\n' ',' | sed 's/,$//' || true)
MIGRATIONS=$([ -d backend/alembic/versions ] && ls -1 backend/alembic/versions 2>/dev/null | wc -l | tr -d ' ' || echo 0)
ENDPOINTS=$(grep -cE '^\s+(get|post|put|delete|patch):' api/openapi.yaml 2>/dev/null || echo 0)
HAS_GEN_BACKEND=$([ -d backend/app/models/_generated ] && echo true || echo false)
HAS_GEN_FRONTEND=$([ -d frontend/src/api/generated ] && echo true || echo false)

if $JSON; then
  cat <<EOF
{
  "git": {"branch": "$GIT_BRANCH", "sha": "$GIT_SHA", "dirty_files": $GIT_DIRTY},
  "backend": {"domains": "$DOMAINS", "routes": "$ROUTES", "migrations": $MIGRATIONS, "generated_models": $HAS_GEN_BACKEND},
  "frontend": {"generated_client": $HAS_GEN_FRONTEND},
  "openapi": {"endpoints": $ENDPOINTS}
}
EOF
else
  cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 📍 Project context snapshot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 git           : $GIT_BRANCH @ $GIT_SHA  (dirty files: $GIT_DIRTY)
 backend
   domains     : ${DOMAINS:-none}
   routes      : ${ROUTES:-none}
   migrations  : $MIGRATIONS
   gen models  : $HAS_GEN_BACKEND
 frontend
   gen client  : $HAS_GEN_FRONTEND
 openapi
   endpoints   : $ENDPOINTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 Reference files for agents:
   CLAUDE.md, Agent.md, .github/copilot/instructions.md
   docs/TEMPLATE-REVIEW.md (known gaps)
   docs/guides/*.md (style)
EOF
fi
