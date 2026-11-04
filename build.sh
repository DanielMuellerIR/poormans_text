#!/usr/bin/env bash
# Bequemer Root-Wrapper; die eigentliche Build-Logik bleibt unter scripts/.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(uname -s)" == Linux ]]; then
    exec "$root/scripts/build_linux.sh" "$@"
fi
exec "$root/scripts/build_app.sh" "$@"
