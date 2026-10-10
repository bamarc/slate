#!/usr/bin/env bash
# migrate.sh — convenience wrapper around alembic.
# Usage:
#   scripts/migrate.sh                       # upgrade head
#   scripts/migrate.sh new "add foo column"  # autogenerate a revision
#   scripts/migrate.sh down                  # downgrade one step
#   scripts/migrate.sh history               # show history
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR/backend"

CMD="${1:-upgrade}"

case "$CMD" in
  upgrade|"") uv run alembic upgrade head ;;
  new) shift; MSG="${1:?usage: scripts/migrate.sh new \"message\"}"; uv run alembic revision --autogenerate -m "$MSG" ;;
  down) uv run alembic downgrade -1 ;;
  history) uv run alembic history --verbose ;;
  current) uv run alembic current ;;
  *) echo "Unknown command: $CMD"; exit 1 ;;
esac
