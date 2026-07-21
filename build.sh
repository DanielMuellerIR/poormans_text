#!/usr/bin/env bash
# Bequemer Root-Wrapper; die eigentliche Build-Logik bleibt unter scripts/.
set -euo pipefail

exec "$(cd "$(dirname "$0")" && pwd)/scripts/build_app.sh" "$@"
