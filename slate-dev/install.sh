#!/usr/bin/env bash
# ==============================================================================
# slate-dev/install.sh — Portable Installer for Slate Dlang + Slint Dev Kit
#
# Installs & configures:
#   1. Dlang Compiler & Package Manager (dmd v2.113.0, dub v1.42.0)
#   2. D Language Server (serve-d v0.8.0-beta.18) + DCD (v0.19.4)
#   3. D Static Analyzer / Linter (dscanner v0.15.2) & Formatter (dfmt v0.15.2)
#   4. Slint Language Server (slint-lsp v1.18.1) & Live Viewer (slint-viewer v1.18.1)
#   5. Project Linter & Formatter Configs (dscanner.ini, .editorconfig)
#   6. Antigravity Plugin (~/.gemini/config/plugins/slate-dev) & PATH Sync
#
# Usage:
#   ./slate-dev/install.sh [--check | --skip-binaries | --plugin-only]
# ==============================================================================
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$PACKAGE_DIR/.." && pwd)"
LOCAL_BIN="${HOME}/.local/bin"
AGY_BIN="${HOME}/.gemini/antigravity/bin"
AGY_PLUGINS_DIR="${HOME}/.gemini/config/plugins"
PLUGIN_TARGET="${AGY_PLUGINS_DIR}/slate-dev"

DMD_VERSION="${DMD_VERSION:-2.113.0}"
SERVED_VERSION="${SERVED_VERSION:-0.8.0-beta.18}"
DCD_VERSION="${DCD_VERSION:-0.19.4}"
DFMT_VERSION="${DFMT_VERSION:-0.15.2}"
DSCANNER_VERSION="${DSCANNER_VERSION:-0.15.2}"
SLINT_VERSION="${SLINT_VERSION:-1.18.1}"

MODE="full"
for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        --skip-binaries) MODE="skip-binaries" ;;
        --plugin-only) MODE="plugin-only" ;;
        -h|--help)
            sed -n '2,16p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

log()  { printf "\033[1;34m[slate-dev]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m  ✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m  !\033[0m %s\n" "$*"; }

verify_setup() {
    log "Verifying installed Dlang & Slint toolchain..."
    export PATH="${LOCAL_BIN}:${PATH}"
    local missing=0
    for tool in dmd dub rdmd serve-d dcd-server dcd-client dfmt dscanner slint-lsp slint-viewer; do
        if command -v "$tool" >/dev/null 2>&1; then
            local ver
            ver="$("$tool" --version 2>&1 | head -n 1 || true)"
            ok "$(printf "%-14s -> %s (%s)" "$tool" "$(command -v "$tool")" "$ver")"
        else
            warn "Missing tool: $tool"
            missing=1
        fi
    done

    if [ -f "${PLUGIN_TARGET}/plugin.json" ]; then
        ok "Antigravity plugin installed at ${PLUGIN_TARGET}"
    else
        warn "Antigravity plugin not yet installed at ${PLUGIN_TARGET}"
        missing=1
    fi
    return "$missing"
}

if [ "$MODE" = "check" ]; then
    verify_setup
    exit $?
fi

mkdir -p "$LOCAL_BIN"
export PATH="${LOCAL_BIN}:${PATH}"

install_binaries() {
    local arch
    arch="$(uname -m)"

    # 1. Install or symlink DMD + DUB
    if ! command -v dmd >/dev/null 2>&1; then
        if [ ! -d "${HOME}/dlang/dmd-${DMD_VERSION}" ]; then
            log "Installing DMD ${DMD_VERSION}..."
            curl -fsS https://dlang.org/install.sh | bash -s "install" "dmd-${DMD_VERSION}"
        fi
    fi
    local dmd_bin_dir
    dmd_bin_dir="$(find "${HOME}/dlang" -maxdepth 4 -type d -name "bin64" 2>/dev/null | sort -V | tail -n 1 || true)"
    if [ -n "$dmd_bin_dir" ]; then
        for bin in dmd dub rdmd ddemangle dustmite; do
            if [ -x "${dmd_bin_dir}/${bin}" ]; then
                ln -sfn "${dmd_bin_dir}/${bin}" "${LOCAL_BIN}/${bin}"
            fi
        done
        ok "Linked DMD & DUB binaries from ${dmd_bin_dir} -> ${LOCAL_BIN}"
    fi

    # 2. Install serve-d
    if ! command -v serve-d >/dev/null 2>&1; then
        log "Downloading serve-d v${SERVED_VERSION}..."
        curl -fsSL "https://github.com/Pure-D/serve-d/releases/download/v${SERVED_VERSION}/serve-d_${SERVED_VERSION}-linux-${arch}.tar.gz" \
            | tar -xz -C "$LOCAL_BIN"
    fi
    ok "serve-d ready ($(serve-d --version 2>&1 | head -n 1))"

    # 3. Install DCD (dcd-server & dcd-client)
    if ! command -v dcd-server >/dev/null 2>&1 || ! command -v dcd-client >/dev/null 2>&1; then
        log "Downloading DCD v${DCD_VERSION}..."
        curl -fsSL "https://github.com/dlang-community/DCD/releases/download/v${DCD_VERSION}/dcd-v${DCD_VERSION}-linux-${arch}.tar.gz" \
            | tar -xz -C "$LOCAL_BIN"
    fi
    ok "DCD ready (dcd-server $(dcd-server --version 2>&1 | head -n 1))"

    # 4. Install Slint LSP & Slint Viewer
    if ! command -v slint-lsp >/dev/null 2>&1; then
        log "Downloading slint-lsp v${SLINT_VERSION}..."
        curl -fsSL "https://github.com/slint-ui/slint/releases/download/v${SLINT_VERSION}/slint-lsp-${arch}-unknown-linux-gnu.tar.gz" \
            | tar -xz --strip-components=1 -C "$LOCAL_BIN"
    fi
    if ! command -v slint-viewer >/dev/null 2>&1; then
        log "Downloading slint-viewer v${SLINT_VERSION}..."
        curl -fsSL "https://github.com/slint-ui/slint/releases/download/v${SLINT_VERSION}/slint-viewer-${arch}-unknown-linux-gnu.tar.gz" \
            | tar -xz --strip-components=1 -C "$LOCAL_BIN"
    fi
    ok "Slint LSP & Viewer ready ($(slint-lsp --version 2>&1 | head -n 1))"

    # 5. Build or install dfmt & dscanner via DUB
    if ! command -v dfmt >/dev/null 2>&1; then
        log "Building dfmt v${DFMT_VERSION} via DUB..."
        dub fetch "dfmt@${DFMT_VERSION}" || true
        dub build "dfmt@${DFMT_VERSION}" --build=release
        find "${HOME}/.dub/packages" -maxdepth 5 -type f -executable -name "dfmt" -exec cp -f {} "${LOCAL_BIN}/dfmt" \;
    fi
    ok "dfmt ready ($(dfmt --version 2>&1 | head -n 1))"

    if ! command -v dscanner >/dev/null 2>&1; then
        log "Building dscanner v${DSCANNER_VERSION} via DUB..."
        dub fetch "dscanner@${DSCANNER_VERSION}" || true
        dub build "dscanner@${DSCANNER_VERSION}" --build=release
        find "${HOME}/.dub/packages" -maxdepth 5 -type f -executable -name "dscanner" -exec cp -f {} "${LOCAL_BIN}/dscanner" \;
    fi
    ok "dscanner ready ($(dscanner --version 2>&1 | head -n 1))"
}

install_configs_and_plugin() {
    log "Installing D-Scanner & EditorConfig defaults..."
    mkdir -p "${HOME}/.config/dscanner"
    cp -f "${PACKAGE_DIR}/config/dscanner.ini" "${HOME}/.config/dscanner/dscanner.ini"
    if [ -d "$WORKSPACE_ROOT" ] && [ ! -f "${WORKSPACE_ROOT}/dscanner.ini" ]; then
        cp -f "${PACKAGE_DIR}/config/dscanner.ini" "${WORKSPACE_ROOT}/dscanner.ini"
    fi
    if [ -d "$WORKSPACE_ROOT" ] && [ ! -f "${WORKSPACE_ROOT}/.editorconfig" ]; then
        cp -f "${PACKAGE_DIR}/config/.editorconfig" "${WORKSPACE_ROOT}/.editorconfig"
    fi
    ok "Synced dscanner.ini -> ~/.config/dscanner/dscanner.ini"

    log "Installing slate-dev Antigravity plugin -> ${PLUGIN_TARGET}..."
    mkdir -p "$PLUGIN_TARGET"
    cp -rf "${PACKAGE_DIR}/plugin.json" \
           "${PACKAGE_DIR}/mcp_config.json" \
           "${PACKAGE_DIR}/assets" \
           "${PACKAGE_DIR}/mcp" \
           "${PACKAGE_DIR}/rules" \
           "${PACKAGE_DIR}/skills" \
           "${PACKAGE_DIR}/config" \
           "$PLUGIN_TARGET/"
    chmod +x "${PLUGIN_TARGET}/mcp/dlang-lsp-mcp.py"

    # Rewrite mcp_config.json command path inside the installed plugin to match $HOME
    python3 -c '
import json, pathlib
p = pathlib.Path.home() / ".gemini/config/plugins/slate-dev/mcp_config.json"
data = json.loads(p.read_text())
data["mcpServers"]["slate-dev-dlang-lsp"]["command"] = str(
    pathlib.Path.home() / ".gemini/config/plugins/slate-dev/mcp/dlang-lsp-mcp.py"
)
p.write_text(json.dumps(data, indent=2) + "\n")
'
    ok "Installed Antigravity plugin bundle at ${PLUGIN_TARGET}"

    # Sync binaries into ~/.gemini/antigravity/bin if Antigravity is present
    if command -v sync-dev-tools >/dev/null 2>&1; then
        sync-dev-tools
        ok "Synced binaries to ${AGY_BIN} via sync-dev-tools"
    elif [ -d "${HOME}/.gemini/antigravity" ]; then
        mkdir -p "$AGY_BIN"
        for bin in "$LOCAL_BIN"/*; do
            if [ -x "$bin" ] && [ ! -d "$bin" ]; then
                ln -sfn "$bin" "${AGY_BIN}/$(basename "$bin")"
            fi
        done
        ok "Linked binaries to ${AGY_BIN}"
    fi
}

if [ "$MODE" = "full" ]; then
    install_binaries
    install_configs_and_plugin
elif [ "$MODE" = "skip-binaries" ] || [ "$MODE" = "plugin-only" ]; then
    install_configs_and_plugin
fi

verify_setup
