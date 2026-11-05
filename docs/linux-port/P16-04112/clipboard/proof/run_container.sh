#!/usr/bin/env bash
set -euo pipefail
probe=${PMT_PROBE_ROOT:?set proof directory root}
helper=${PMT_PROBE_HELPER:?set built bound_probe}
candidate=${PMT_PROBE_CANDIDATE:?set CLI-support directory}
runtime=${PMT_PROBE_RUNTIME:?set Swift runtime root}
image=${PMT_PROBE_IMAGE:?set an existing qualified local image}
case ${1:-devro} in devro) script=devro.py;; backend) script=backend_devro.py;; uno) script=uno_devro.py;; *) exit 64;; esac
docker image inspect "$image" >/dev/null
exec docker run --rm --pull never --network none --user "$(id -u):$(id -g)" \
 --cap-add SYS_ADMIN --cap-add NET_ADMIN --security-opt seccomp=unconfined \
 --security-opt apparmor=unconfined --security-opt systempaths=unconfined \
 --mount "type=bind,src=$probe,dst=/probe" \
 --mount "type=bind,src=$probe/samples,dst=/probe/fixtures,readonly" \
 --mount "type=bind,src=$helper,dst=/helper,readonly" \
 --mount "type=bind,src=$candidate,dst=/candidate,readonly" \
 --mount "type=bind,src=$runtime,dst=/base-runtime,readonly" \
 "$image" python3 "/probe/proof/$script"
