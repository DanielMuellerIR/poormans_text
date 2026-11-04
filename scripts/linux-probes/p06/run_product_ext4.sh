#!/usr/bin/env bash
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)
runtime="$repo/.build/linux-runtime"
[[ -x "$runtime/bin/poormans-text" ]] || { echo 'Build the Linux product first.' >&2; exit 69; }
output=$(mktemp -d /tmp/pmt-p06-product-ext4-XXXXXXXX)
printf 'OUTPUT=%s\n' "$output"
timeout 90 docker run --rm --pull never --network none --read-only --cap-add SYS_ADMIN \
  --device /dev/loop-control:/dev/loop-control --device-cgroup-rule 'b 7:* rwm' \
  --tmpfs /run:rw,exec,nosuid,size=2m \
  -v "$repo/scripts/linux-probes:/probe:ro" \
  -v "$runtime/bin:/product/bin:ro" -v "$runtime/lib:/product/lib:ro" \
  -v "$output:/results" pmt-p03-fs-probe bash /probe/p06/inside_product_ext4.sh
