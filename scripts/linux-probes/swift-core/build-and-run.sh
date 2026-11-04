#!/bin/bash
set -euo pipefail
# Auf dem Host: ./prepare.py REPO /tmp/NEUER-PROBEBAUM
# Dann diesen Pfad als erstes Argument übergeben.
probe=$(realpath "$1")
scripts=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cp "$scripts/package-runtime.sh" "$probe/"
docker build -t pmt-p02-probe "$probe"
docker run --rm -v "$probe:/probe" pmt-p02-probe swift package resolve
docker run --rm --network none -v "$probe:/probe" pmt-p02-probe bash -lc 'set -euo pipefail; swift build --jobs 4; cd fixtures; pandoc picture.md -o picture.docx; cd ..; bash package-runtime.sh; ./run-runtime.sh'
