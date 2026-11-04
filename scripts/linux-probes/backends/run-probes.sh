#!/bin/bash
set -eu
scripts="$(cd -- "$(dirname -- "$0")" && pwd)"
if [ -n "${PMT_P04_ROOT:-}" ]; then
  [ ! -e "$PMT_P04_ROOT" ] && [ ! -L "$PMT_P04_ROOT" ] || {
    echo 'PMT_P04_ROOT muss ein neues Verzeichnis bezeichnen.' >&2
    exit 73
  }
  mkdir -m 700 -- "$PMT_P04_ROOT"
else
  PMT_P04_ROOT=$(mktemp -d /tmp/pmt-p04-run.XXXXXX)
fi
export PMT_P04_ROOT
mkdir -p "$PMT_P04_ROOT/fixtures" "$PMT_P04_ROOT/outputs"
python3 "$scripts/probe.py" > "$PMT_P04_ROOT/outputs/probe.log"
python3 "$scripts/extra-probe.py" > "$PMT_P04_ROOT/outputs/extra.log"
python3 "$scripts/lo-fixtures.py"
python3 - "$PMT_P04_ROOT" <<'PYHASH'
from pathlib import Path
import sys,hashlib,json
r=Path(sys.argv[1]);data={str(p.relative_to(r/'fixtures')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (r/'fixtures').rglob('*') if p.is_file()};(r/'outputs/source-hashes-before.json').write_text(json.dumps(data,indent=2))
PYHASH
cc "$scripts/pdf-links.c" -o "$PMT_P04_ROOT/pdf-links" $(pkg-config --cflags --libs poppler-glib)
"$PMT_P04_ROOT/pdf-links" "$PMT_P04_ROOT/fixtures/sample.pdf" > "$PMT_P04_ROOT/outputs/pdf-links.txt"
for d in doc doc-html rtf-html rtfd-html remote-html; do mkdir -p "$PMT_P04_ROOT/outputs/$d"; done
"$scripts/lo-run.sh" --convert-to 'doc:MS Word 97' --outdir "$PMT_P04_ROOT/outputs/doc" "$PMT_P04_ROOT/fixtures/encoded.rtf"
"$scripts/lo-run.sh" --convert-to html --outdir "$PMT_P04_ROOT/outputs/doc-html" "$PMT_P04_ROOT/outputs/doc/encoded.doc"
"$scripts/lo-run.sh" --convert-to html --outdir "$PMT_P04_ROOT/outputs/rtf-html" "$PMT_P04_ROOT/fixtures/encoded.rtf"
"$scripts/lo-run.sh" --convert-to html --outdir "$PMT_P04_ROOT/outputs/rtfd-html" "$PMT_P04_ROOT/fixtures/local.rtfd/TXT.rtf"
"$scripts/lo-run.sh" --convert-to html --outdir "$PMT_P04_ROOT/outputs/remote-html" "$PMT_P04_ROOT/fixtures/remote.fodt"
bwrap --unshare-net --ro-bind / / --proc /proc --dev /dev /usr/bin/python3 "$scripts/network-check.py" > "$PMT_P04_ROOT/outputs/network.json"
python3 - "$PMT_P04_ROOT" <<'PYHASH'
from pathlib import Path
import sys,hashlib,json
r=Path(sys.argv[1]);data={str(p.relative_to(r/'fixtures')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (r/'fixtures').rglob('*') if p.is_file()};assert data==json.loads((r/'outputs/source-hashes-before.json').read_text()), 'Quelldateien verändert'
PYHASH
printf 'Probe directory: %s\n' "$PMT_P04_ROOT"
