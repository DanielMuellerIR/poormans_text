#!/usr/bin/env bash
set -euo pipefail
probe=$(cd -- "$(dirname -- "$0")" && pwd)
image=pmt-p11-tatr-probe:20261105-fixed
expected=sha256:5c5301d7ef2297de21640bfe3dd29c2c1b21fbb36aeaf1af2d21e2f226f637d2
[[ $(docker image inspect "$image" --format '{{.Id}}') == "$expected" ]] || { echo 'Unexpected probe image' >&2; exit 1; }
if (($# == 0)); then set -- 01030000000132.pdf 01030000000134.pdf 01030000000135.pdf structured.png; fi
exec docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
 --cpus 2 --memory 3g --memory-swap 3g --pids-limit 128 --user "$(id -u):$(id -g)" \
 --tmpfs /tmp:rw,noexec,nosuid,size=256m --env HOME=/tmp \
 --mount "type=bind,src=$probe/input,dst=/input,readonly" \
 --mount "type=bind,src=$probe/probe.py,dst=/probe.py,readonly" \
 --mount "type=bind,src=$probe/output,dst=/output" \
 "$image" timeout 600s python /probe.py "$@"
