#!/usr/bin/env bash
set -euo pipefail
scripts=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=$(mktemp -d /tmp/pmt-p03-ext4-followup.XXXXXX)
printf 'OUTPUT=%s\n' "$output"
docker run --rm --network none --read-only --cap-add SYS_ADMIN \
  --device /dev/loop-control:/dev/loop-control --device-cgroup-rule 'b 7:* rwm' \
  --tmpfs /run:rw,exec,nosuid,size=2m -e PMT_PROBE_OUTPUT=/results \
  -v "$scripts:/probe:ro" -v "$output:/results" \
  pmt-p03-fs-probe bash /probe/inside_ext4.sh
