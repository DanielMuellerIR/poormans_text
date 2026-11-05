#!/usr/bin/env bash
set -euo pipefail
probe=$(cd -- "$(dirname -- "$0")" && pwd)
runtime=${PMT_OCR_RUNTIME:?set read-only Swift runtime root containing lib/}
image=${PMT_OCR_IMAGE:-pmt-linux-backend-test}
expected=2f49d54ecd6d9bae4962fcdb7f968ea4eef9c3844701d278a9a507e3e84db07c
actual=$(sha256sum "$probe/runtime/poormans-text")
[[ ${actual%% *} == "$expected" ]] || { echo "Wrong CLI snapshot; see README." >&2; exit 65; }
docker image inspect "$image" >/dev/null
for mode in nonexec nolangs iofault timeout real; do
 masks=()
 if [[ "$mode" != real ]]; then masks=(--mount "type=bind,src=$probe/fakes/$mode,dst=/usr/bin/tesseract,readonly"); fi
 docker run --rm --pull never --network none --user "$(id -u):$(id -g)" \
  --cap-add SYS_ADMIN --cap-add NET_ADMIN --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined --security-opt systempaths=unconfined \
  --mount "type=bind,src=$probe,dst=/probe" \
  --mount "type=bind,src=$probe/fixtures,dst=/probe/fixtures,readonly" \
  --mount "type=bind,src=$probe/runtime,dst=/candidate,readonly" \
  --mount "type=bind,src=$runtime,dst=/base-runtime,readonly" \
  "${masks[@]}" "$image" python3 /probe/run.py "$mode"
done
