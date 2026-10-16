#!/usr/bin/env bash
# ==============================================================================
# slate-dev/uninstall.sh — Uninstall slate-dev Antigravity plugin & symlinks
# ==============================================================================
set -euo pipefail

PLUGIN_TARGET="${HOME}/.gemini/config/plugins/slate-dev"

if [ -d "$PLUGIN_TARGET" ]; then
    rm -rf "$PLUGIN_TARGET"
    echo "[slate-dev] Removed Antigravity plugin directory: $PLUGIN_TARGET"
else
    echo "[slate-dev] Plugin directory not present: $PLUGIN_TARGET"
fi
