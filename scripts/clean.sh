#!/usr/bin/env bash
# clean.sh — wipe DUB/Dlang build artifacts, test runner binaries, and caches. Idempotent.
# Usage:
#   scripts/clean.sh            # clean Dlang/DUB build artifacts, test runners, and caches
#   scripts/clean.sh --hard     # also clean Rust bridge target/, target/solid-ui, and reference caches
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-soft}"

echo " 🧹 Cleaning Dlang / DUB build artifacts and test runners..."
rm -rf \
  .dub \
  libslate-workspace.a \
  slate-workspace-test-* \
  slint-d/.dub \
  slint-d/*.a \
  slint-d/*-test-* \
  slint-d/docs \
  slint-d/examples/hello/.dub \
  slint-d/examples/hello/hello \
  slint-d/examples/menushow/.dub \
  slint-d/examples/menushow/menushow \
  slint-d/examples/gallery/.dub \
  slint-d/examples/gallery/gallery \
  slate-dlang/.dub \
  slate-dlang/*.a \
  slate-dlang/*.o \
  slate-dlang/*-test-* \
  slate-dlang/bin \
  slate-dlang/docs \
  slate-dlang/packages/*/.dub \
  slate-dlang/packages/*/*.a \
  slate-dlang/packages/*/*-test-* \
  slate-dlang/packages/*/bin \
  slate-encoding/.dub \
  slate-encoding/*.a \
  slate-encoding/*-test-* \
  examples/file-manager/.dub \
  examples/file-manager/file-manager \
  examples/file-manager/file-manager-test-application

echo " 🧹 Cleaning Python/Node caches..."
find . -type d \( \
    -name "__pycache__" -o \
    -name ".pytest_cache" -o \
    -name ".ruff_cache" -o \
    -name ".mypy_cache" \
  \) -not -path "*/node_modules/*" -not -path "*/.venv/*" -prune -exec rm -rf {} +

if [ "$MODE" = "--hard" ]; then
  echo " 💣 Cleaning target/solid-ui, slint-d/bridge/target, and reference caches..."
  rm -rf target/solid-ui slint-d/bridge/target reference/frontend/node_modules reference/backend/.venv
fi

echo " ✅ Clean complete."
