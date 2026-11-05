#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
[[ -x "$root/poormans-text-app" ]] || { echo 'Build the Linux interface with ./linux/build.sh first.' >&2; exit 69; }
exec "$root/poormans-text-app" "$@"
