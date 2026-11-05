#!/usr/bin/env bash
set -euo pipefail
probe=$(cd -- "$(dirname -- "$0")" && pwd)
tests=${PMT_OCR_TEST_DEBUG:?set directory containing xctest and sibling resource bundles}
libs=${PMT_OCR_TEST_LIBS:?set test runtime lib directory}
image=${PMT_OCR_IMAGE:-pmt-linux-backend-test}
docker image inspect "$image" >/dev/null
exec docker run --rm --pull never --network none --user "$(id -u):$(id -g)" \
 --cap-add SYS_ADMIN --cap-add NET_ADMIN --security-opt seccomp=unconfined \
 --security-opt apparmor=unconfined --security-opt systempaths=unconfined \
 --mount "type=bind,src=$probe,dst=/probe" \
 --mount "type=bind,src=$tests,dst=/tests,readonly" \
 --mount "type=bind,src=$libs,dst=/test-libs,readonly" \
 --mount "type=bind,src=$probe/fakes/nonexec,dst=/usr/bin/tesseract,readonly" \
 "$image" python3 /probe/run_missing_unit.py
