#!/usr/bin/env bash
# Bequemer Root-Wrapper; die eigentliche Build-Logik bleibt unter scripts/.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -s)" == Linux ]]; then
    if [[ "${1:-}" == --with-gui ]]; then
        shift
        "$root/scripts/build_linux.sh" "$@"
        exec "$root/scripts/build_linux_gui.sh" "$@"
    fi
    exec "$root/scripts/build_linux.sh" "$@"
fi
exec "$root/scripts/build_app.sh" "$@"
