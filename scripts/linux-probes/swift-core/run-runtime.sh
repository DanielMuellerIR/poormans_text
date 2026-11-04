#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LD_LIBRARY_PATH="$base/runtime/lib"
export PATH="$base/runtime/bin:$PATH"
out=$(mktemp -d "$base/runtime-output.XXXXXX")
printf 'OUTPUT=%s\n' "$out"
(cd "$base/fixtures" && sha256sum table.csv table.xlsx notebook.ipynb picture.docx encoding.rtf fixture.png) > "$out/source-hashes.before"
for name in table.csv table.xlsx notebook.ipynb picture.docx encoding.rtf; do
 "$base/runtime/pmt-probe" "$base/fixtures/$name" "$out/$name"
done
(cd "$base/fixtures" && sha256sum --check "$out/source-hashes.before")
