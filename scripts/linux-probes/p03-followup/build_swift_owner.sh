#!/usr/bin/env bash
set -euo pipefail
scripts=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[[ $# == 1 && "$1" = /* && ! -e "$1" && ! -L "$1" ]] || {
  echo 'Neuen absoluten Ausgabeordner angeben.' >&2
  exit 64
}
mkdir -m 700 -- "$1"
docker run --rm --network none --user "$(id -u):$(id -g)" \
  -v "$scripts:/source:ro" -v "$1:/out" swift:6.2.1-noble sh -c '
    set -eu
    clang -Wall -Wextra -Werror -O2 -c /source/pidfd_bridge.c -o /out/pidfd_bridge.o
    swiftc -swift-version 6 /source/swift_owner.swift /out/pidfd_bridge.o -o /out/swift-owner
    mkdir /out/lib
    ldd /out/swift-owner > /out/ldd.txt
    awk '\''/=> \/usr\/lib\/swift\// {print $3}'\'' /out/ldd.txt | while IFS= read -r lib; do cp -L "$lib" /out/lib/; done
    swiftc --version > /out/swift-version.txt
  '
