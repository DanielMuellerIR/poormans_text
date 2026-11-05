#!/usr/bin/env bash
# Linux-Gegenstück zum App-Build: CLI und GTK, ohne Installation.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
gui=(--with-gui)
args=()
for argument in "$@"; do
    case "$argument" in
        --cli-only) gui=() ;;
        --with-gui) gui=(--with-gui) ;;
        --help|-h) echo 'Usage: ./build-linux.sh [--cli-only] [debug|release]'; exit 0 ;;
        *) args+=("$argument") ;;
    esac
done
[[ $(uname -s) == Linux ]] || { echo 'Run this script on a Linux build host.' >&2; exit 69; }
exec "$root/build.sh" "${gui[@]}" "${args[@]}"
