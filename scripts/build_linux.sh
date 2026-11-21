#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null || { echo "Python 3 is required for the local Linux build scripts." >&2; exit 69; }
if (( $# > 1 )); then echo "Usage: ./build.sh [debug|release]" >&2; exit 64; fi
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 "$script_directory/build_linux.py" "$script_directory/.." "${1:-${CONFIGURATION:-release}}"
