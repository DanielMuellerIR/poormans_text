#!/bin/sh
entry=$(readlink -f -- "$0") || exit
base=$(CDPATH= cd -- "$(dirname -- "$entry")/.." && pwd -P) || exit
runtime="$base/.build/linux-runtime"
LD_LIBRARY_PATH="$runtime/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$runtime/bin/poormans-text" "$@"
