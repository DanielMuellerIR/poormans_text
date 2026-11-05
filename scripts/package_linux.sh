#!/usr/bin/env bash
set -euo pipefail
directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 "$directory/package_linux.py" "$@"
