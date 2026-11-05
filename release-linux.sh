#!/usr/bin/env bash
# Baut Linux-Pakete einschließlich GUI; Signatur nur mit explizitem Schlüssel.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
gui=(--with-gui)
args=()
for argument in "$@"; do
    case "$argument" in
        --cli-only) gui=() ;;
        --with-gui) gui=(--with-gui) ;;
        --help|-h) echo 'Linux release: GUI included by default; --cli-only omits it.'; args+=(--help) ;;
        *) args+=("$argument") ;;
    esac
done
[[ $(uname -s) == Linux ]] || { echo 'Run this script on a Linux build host.' >&2; exit 69; }
exec "$root/scripts/package_linux.sh" "${gui[@]}" "${args[@]}"
