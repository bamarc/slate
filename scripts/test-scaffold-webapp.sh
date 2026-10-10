#!/usr/bin/env bash
# ==============================================================================
# test-scaffold-webapp.sh — End-to-End Scaffolding, Deployment & Verification Test
# ==============================================================================
# Workflow:
#   1. Scaffolds a new web-app clone via `scaffold.py` CLI into a local directory.
#   2. Configures the environment and updates the frontend port to 10000+.
#   3. Runs `docker compose up -d` to build and launch the container stack.
#   4. Checks existence and responsiveness of the web application over HTTP (200 OK).
#   5. Tears down the stack with `docker compose down -v`.
#   6. Cleans up temporary artifacts.
#   7. Measures and outputs high-precision timing for each phase and total runtime.
# ==============================================================================

set -euo pipefail

# Color palette
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_GREEN="\033[32m"
C_CYAN="\033[36m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_BLUE="\033[34m"

# Target port (must be 10000+)
PORT="${1:-10080}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 10000 ]; then
  echo -e "${C_RED}[!] Error: Port must be an integer >= 10000. Received: ${PORT}${C_RESET}"
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ID="$(date +%s)"
TARGET_DIR="${PROJECT_ROOT}/tmp/scaffold-e2e-${TEST_ID}"
PROJECT_NAME="e2e-webapp-${TEST_ID}"

echo -e "${C_BOLD}${C_BLUE}==================================================================${C_RESET}"
echo -e "${C_BOLD}${C_BLUE}      SPARK Web-App Scaffolding & Compose Verification Test       ${C_RESET}"
echo -e "${C_BOLD}${C_BLUE}==================================================================${C_RESET}"
echo -e "${C_CYAN}Target Directory:${C_RESET} ${TARGET_DIR}"
echo -e "${C_CYAN}Target Web Port:${C_RESET}  ${PORT}"
echo -e "${C_CYAN}Project Name:${C_RESET}     ${PROJECT_NAME}"
echo ""

# High-precision timer function (in seconds with 3 decimal places)
get_time() {
  python3 -c "import time; print(f'{time.perf_counter():.3f}')"
}

calc_duration() {
  local start="$1"
  local end="$2"
  python3 -c "print(f'{float($end) - float($start):.3f}')"
}

# Cleanup trap to ensure stack is always torn down even on failure or interruption
cleanup() {
  local exit_code=$?
  if [ -d "$TARGET_DIR" ]; then
    echo -e "\n${C_YELLOW}[*] Safety trap triggered — ensuring compose stack is down...${C_RESET}"
    (cd "$TARGET_DIR" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
    rm -rf "$TARGET_DIR" || true
  fi
  if [ $exit_code -ne 0 ]; then
    echo -e "${C_RED}${C_BOLD}✗ Test failed with exit code ${exit_code}.${C_RESET}"
  fi
}
trap cleanup EXIT INT TERM

TOTAL_START=$(get_time)

# ------------------------------------------------------------------------------
# Phase 1: Scaffold web-app via CLI
# ------------------------------------------------------------------------------
echo -e "${C_BOLD}[1/5] Scaffolding web-app via CLI to local directory...${C_RESET}"
P1_START=$(get_time)

mkdir -p "$(dirname "$TARGET_DIR")"
python3 "${PROJECT_ROOT}/scaffold.py" \
  --name "$PROJECT_NAME" \
  --description "Automated E2E Scaffolding Verification Web App" \
  --author "Antigravity CI" \
  --email "ci@example.com" \
  --license "MIT" \
  --db "PostgreSQL" \
  "$TARGET_DIR" >/dev/null

P1_END=$(get_time)
T_SCAFFOLD=$(calc_duration "$P1_START" "$P1_END")
echo -e "      ${C_GREEN}✓ Scaffolded successfully in ${T_SCAFFOLD}s${C_RESET}"

# ------------------------------------------------------------------------------
# Phase 2: Edit port to 10000+
# ------------------------------------------------------------------------------
echo -e "${C_BOLD}[2/5] Configuring ports to ${PORT} (10000+)...${C_RESET}"
P2_START=$(get_time)

cd "$TARGET_DIR"
cp .env.example .env
# Configure non-colliding project name and ports in .env and export to environment
export COMPOSE_PROJECT_NAME="${PROJECT_NAME}"
export FRONTEND_PORT="${PORT}"
export BACKEND_PORT="18000"
export POSTGRES_PORT="15433"
export JAEGER_UI_PORT="26686"
export OTEL_GRPC_PORT="24317"
export OTEL_HTTP_PORT="24318"

sed -i '' "s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=${PROJECT_NAME}|" .env
sed -i '' "s|^FRONTEND_PORT=.*|FRONTEND_PORT=${PORT}|" .env
sed -i '' "s|^BACKEND_PORT=.*|BACKEND_PORT=18000|" .env
sed -i '' "s|^POSTGRES_PORT=.*|POSTGRES_PORT=15433|" .env
sed -i '' "s|^JAEGER_UI_PORT=.*|JAEGER_UI_PORT=26686|" .env
sed -i '' "s|^OTEL_GRPC_PORT=.*|OTEL_GRPC_PORT=24317|" .env
sed -i '' "s|^OTEL_HTTP_PORT=.*|OTEL_HTTP_PORT=24318|" .env

# Ensure compose.yaml explicitly exposes the configured port
if ! grep -q "FRONTEND_PORT" compose.yaml; then
  sed -i '' "s|8080:80|${PORT}:80|" compose.yaml
fi

P2_END=$(get_time)
T_PORT_EDIT=$(calc_duration "$P2_START" "$P2_END")
echo -e "      ${C_GREEN}✓ Ports updated in ${T_PORT_EDIT}s (Frontend: ${PORT})${C_RESET}"

# ------------------------------------------------------------------------------
# Phase 3: Run compose up
# ------------------------------------------------------------------------------
echo -e "${C_BOLD}[3/5] Starting application stack with 'docker compose up -d'...${C_RESET}"
P3_START=$(get_time)

# Start stack detached
docker compose up -d frontend

P3_END=$(get_time)
T_COMPOSE_UP=$(calc_duration "$P3_START" "$P3_END")
echo -e "      ${C_GREEN}✓ Stack started in ${T_COMPOSE_UP}s${C_RESET}"

# ------------------------------------------------------------------------------
# Phase 4: Check existence of the site
# ------------------------------------------------------------------------------
echo -e "${C_BOLD}[4/5] Checking existence of the site on http://127.0.0.1:${PORT}...${C_RESET}"
P4_START=$(get_time)

MAX_RETRIES=30
RETRY_COUNT=0
SITE_UP=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/" || echo "000")
  if [ "$HTTP_STATUS" = "200" ]; then
    SITE_UP=true
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  sleep 1
done

if [ "$SITE_UP" != "true" ]; then
  echo -e "${C_RED}[!] Error: Web application failed to respond on http://127.0.0.1:${PORT} within ${MAX_RETRIES}s (Last status: ${HTTP_STATUS})${C_RESET}"
  echo -e "${C_YELLOW}--- Container Logs ---${C_RESET}"
  docker compose logs --tail=20 frontend
  exit 1
fi

# Fetch and verify content markers
PAGE_CONTENT=$(curl -s "http://127.0.0.1:${PORT}/")
if ! echo "$PAGE_CONTENT" | grep -qi "root"; then
  echo -e "${C_RED}[!] Error: Response received from http://127.0.0.1:${PORT} did not contain HTML mount point <div id=\"root\">.${C_RESET}"
  exit 1
fi

P4_END=$(get_time)
T_CHECK_SITE=$(calc_duration "$P4_START" "$P4_END")
echo -e "      ${C_GREEN}✓ Site responded with HTTP 200 OK (verified HTML content) in ${T_CHECK_SITE}s${C_RESET}"

# ------------------------------------------------------------------------------
# Phase 5: Pull it down
# ------------------------------------------------------------------------------
echo -e "${C_BOLD}[5/5] Pulling down application stack with 'docker compose down -v'...${C_RESET}"
P5_START=$(get_time)

docker compose down -v --remove-orphans >/dev/null

P5_END=$(get_time)
T_COMPOSE_DOWN=$(calc_duration "$P5_START" "$P5_END")
echo -e "      ${C_GREEN}✓ Stack pulled down in ${T_COMPOSE_DOWN}s${C_RESET}"

# ------------------------------------------------------------------------------
# Teardown & Timing Summary
# ------------------------------------------------------------------------------
cd "$PROJECT_ROOT"
rm -rf "$TARGET_DIR"

TOTAL_END=$(get_time)
T_TOTAL=$(calc_duration "$TOTAL_START" "$TOTAL_END")

echo ""
echo -e "${C_BOLD}${C_GREEN}==================================================================${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}                  TEST PASSED — TIMING SUMMARY                    ${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}==================================================================${C_RESET}"
printf "  %-35s : %8s s\n" "1. Scaffold via CLI" "$T_SCAFFOLD"
printf "  %-35s : %8s s\n" "2. Port Configuration (Port ${PORT})" "$T_PORT_EDIT"
printf "  %-35s : %8s s\n" "3. Docker Compose Up" "$T_COMPOSE_UP"
printf "  %-35s : %8s s\n" "4. Site Existence Verification" "$T_CHECK_SITE"
printf "  %-35s : %8s s\n" "5. Docker Compose Down" "$T_COMPOSE_DOWN"
echo -e "  --------------------------------------------------"
printf "  ${C_BOLD}%-35s : %8s s${C_RESET}\n" "Total Execution Time" "$T_TOTAL"
echo -e "${C_BOLD}${C_GREEN}==================================================================${C_RESET}"
