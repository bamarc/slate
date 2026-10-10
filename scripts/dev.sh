#!/usr/bin/env bash
# dev.sh — start the full stack (db + backend + frontend) via docker compose.
# Usage:
#   scripts/dev.sh                 # foreground, all services
#   scripts/dev.sh --detach        # background
#   scripts/dev.sh --no-frontend   # only db + backend
#   scripts/dev.sh --local         # run backend (uv) and frontend (pnpm dev) on host, db in compose
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MODE="compose"
DETACH=""
SERVICES="db backend frontend"

for arg in "$@"; do
  case "$arg" in
    --detach|-d) DETACH="-d" ;;
    --no-frontend) SERVICES="db backend" ;;
    --local) MODE="local" ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done

if [ "$MODE" = "local" ]; then
  echo " 🐘 Starting database in compose..."
  docker compose up -d db
  echo " 🐍 Starting backend (uv run uvicorn --reload)..."
  (cd backend && uv run uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload) &
  BACKEND_PID=$!
  echo " ⚛️  Starting frontend (pnpm dev)..."
  (cd frontend && pnpm dev) &
  FRONTEND_PID=$!
  trap "kill $BACKEND_PID $FRONTEND_PID 2>/dev/null; docker compose stop db" EXIT INT TERM
  wait
else
  echo " 🐳 docker compose up ${DETACH:-} $SERVICES"
  # shellcheck disable=SC2086
  exec docker compose up $DETACH $SERVICES
fi
