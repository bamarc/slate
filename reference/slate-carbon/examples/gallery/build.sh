#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SLATE_RUST_DIR="${WORKSPACE_ROOT}/slate-rust"
TARGET_DIR="${SLATE_RUST_DIR}/target/debug"

# 1. Ensure carbon toolchain is accessible
if ! command -v carbon >/dev/null 2>&1; then
    if [[ -x "${HOME}/opt/carbon/bin/carbon" ]]; then
        export PATH="${HOME}/opt/carbon/bin:${PATH}"
    else
        echo "Error: Carbon compiler not found on PATH or in ~/opt/carbon/bin" >&2
        exit 1
    fi
fi

# 2. Build the Slate native gallery library if needed
if [[ ! -f "${TARGET_DIR}/libslate_gallery.so" ]]; then
    echo "==> Building Slate Rust native gallery library (libslate_gallery.so)..."
    (cd "${SLATE_RUST_DIR}" && cargo build -p slate-showcase)
fi

mkdir -p "${SCRIPT_DIR}/bin"

echo "==> Compiling Slate Component Gallery with Google Carbon toolchain..."
carbon build \
    --output="${SCRIPT_DIR}/bin/carbon_gallery_app" \
    "${SCRIPT_DIR}/main.carbon" \
    -- \
    -fPIC \
    -- \
    -L"${TARGET_DIR}" \
    -lslate_gallery \
    -Wl,-rpath,"${TARGET_DIR}" \
    -lc++

echo "==> Build successful! Binary created at: ${SCRIPT_DIR}/bin/carbon_gallery_app"
