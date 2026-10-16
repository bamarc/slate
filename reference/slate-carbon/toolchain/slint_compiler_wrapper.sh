#!/usr/bin/env bash
set -euo pipefail

if command -v slint-compiler >/dev/null 2>&1; then
    exec slint-compiler "$@"
else
    echo "ERROR: 'slint-compiler' not found on PATH." >&2
    echo "Install Slint C++ compiler via: cargo install slint-compiler --version 1.18.1" >&2
    exit 1
fi
