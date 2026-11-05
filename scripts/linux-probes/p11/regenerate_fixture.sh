#!/bin/sh
set -eu
# Aufruf: regenerate_fixture.sh REPO NEUER_PROBENORDNER
repo=$1
root=$2
test ! -e "$root"
mkdir -m 0700 "$root"
mkdir "$root/fixtures" "$root/outputs"
PMT_P04_ROOT="$root" python3 - "$repo" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1])/'scripts/linux-probes/backends/extra-probe.py'
exec(compile(path.read_text().split('res={}')[0],str(path),'exec'))
PY
