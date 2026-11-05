#!/usr/bin/env bash
set -euo pipefail
probe=$(cd -- "$(dirname -- "$0")" && pwd)
runtime=${PMT_FINAL_RUNTIME:?set final runtime root}
fixtures=${PMT_FINAL_FIXTURES:?set original synthetic fixture directory}
image=${PMT_FINAL_IMAGE:-pmt-heic-probe:local}
actual=$(sha256sum "$runtime/bin/poormans-text")
[[ ${actual%% *} == 2f49d54ecd6d9bae4962fcdb7f968ea4eef9c3844701d278a9a507e3e84db07c ]] || exit 65
docker image inspect "$image" >/dev/null
exec docker run --rm --pull never --network none --user "$(id -u):$(id -g)" \
 --cap-add SYS_ADMIN --cap-add NET_ADMIN --security-opt seccomp=unconfined \
 --security-opt apparmor=unconfined --security-opt systempaths=unconfined \
 --mount "type=bind,src=$probe,dst=/probe" \
 --mount "type=bind,src=$fixtures,dst=/probe/fixtures,readonly" \
 --mount "type=bind,src=$runtime,dst=/release,readonly" \
 --env PMT_PREVIEW_TEST_ROOT=/probe --env PMT_PREVIEW_TEST_CLI=/release/bin/poormans-text \
 --env PMT_PREVIEW_TEST_LIBS=/release/lib "$image" \
 sh -c 'python3 /probe/reproduction/verify_cli.py && python3 /probe/reproduction/verify_failures.py'
