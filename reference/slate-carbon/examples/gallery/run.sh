#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/bin/carbon_gallery_app" ]]; then
    echo "Binary not found. Building Carbon Gallery first..."
    "${SCRIPT_DIR}/build.sh"
fi

echo "Launching Slate Gallery via Google Carbon..."
exec "${SCRIPT_DIR}/bin/carbon_gallery_app" "$@"
