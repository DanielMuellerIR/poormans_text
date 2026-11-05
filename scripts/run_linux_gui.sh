#!/bin/sh
entry=$(readlink -f -- "$0") || exit
base=$(CDPATH= cd -- "$(dirname -- "$entry")/.." && pwd -P) || exit
exec "$base/.build/linux-runtime/ui/poormans-text-app" "$@"
