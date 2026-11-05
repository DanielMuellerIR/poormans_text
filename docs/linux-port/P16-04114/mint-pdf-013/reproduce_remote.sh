#!/usr/bin/env bash
set -euo pipefail
probe=$(cd -- "$(dirname -- "$0")" && pwd)
case "$probe" in /tmp/pmt-mint-pdf13.*) ;; *) echo 'Use a new owned /tmp/pmt-mint-pdf13.* directory.' >&2; exit 64;; esac
cd "$probe"
# Produktpaket und synthetische Fixtures vorher in diese eigene Wurzel übertragen.
apt-get download gir1.2-poppler-0.18=24.02.0-1ubuntu9.11
python3 -I setup_remote.py "$probe"
python3 -I run_remote.py
python3 -I finalize_remote.py
