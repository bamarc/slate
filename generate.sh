#!/usr/bin/env bash
# Backwards-compat shim. The real script lives at scripts/generate.sh.
exec "$(dirname "$0")/scripts/generate.sh" "$@"
