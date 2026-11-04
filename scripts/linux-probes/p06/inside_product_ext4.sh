#!/usr/bin/env bash
set -euo pipefail
image=$(mktemp /results/ext4-probe.XXXXXX.img)
mountpoint=/run/ext4
loop=''
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if mountpoint -q "$mountpoint"; then umount "$mountpoint" || status=90; fi
  associated=$(losetup --associated "$image" --noheadings --output NAME)
  if [[ -n "$associated" ]]; then
    if [[ "$associated" == "$loop" ]]; then losetup -d "$loop" || status=91;
    else echo 'Unexpected loop identity; refusing to touch it.' >&2; status=92; fi
  fi
  if [[ -z "$(losetup --associated "$image" --noheadings --output NAME)" ]]; then
    rm -- "$image"
    printf '{"ownImageRemoved":true,"ownLoopReleased":true,"unmounted":true}\n' > /results/cleanup.json
  else status=93; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
truncate -s 64M "$image"
mkfs.ext4 -q -F -m 0 "$image"
mkdir -p "$mountpoint"
TMPDIR=/run clang -Wall -Wextra -Werror -O2 /probe/p03-followup/loop_mount.c -o /run/loop-mount
loop=$(/run/loop-mount "$image" "$mountpoint")
[[ "$loop" =~ ^/dev/loop[0-9]+$ ]]
[[ "$(findmnt -n -o FSTYPE --target "$mountpoint")" == ext4 ]]
chmod 0777 "$mountpoint"
chmod 0755 /results
mkdir /results/evidence
chmod 0777 /results/evidence
export LD_LIBRARY_PATH=/product/lib
setpriv --reuid=65534 --regid=65534 --clear-groups python3 /probe/p06/verify_product_ext4.py before "$mountpoint"
set +e
dd if=/dev/zero of="$mountpoint/fill.bin" bs=1M count=80 conv=fsync status=none 2>/results/enospc.stderr
filled=$?
set -e
[[ "$filled" -ne 0 ]]
grep -q 'No space left on device' /results/enospc.stderr
python3 - "$mountpoint/fill.bin" <<'PY'
import errno, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND | os.O_SYNC)
try:
    for _ in range(16384):
        try:
            os.write(fd, b'\0' * 4096)
        except OSError as error:
            if error.errno != errno.ENOSPC:
                raise
            break
    else:
        raise AssertionError('bounded 4-KiB fill did not reach ENOSPC')
finally:
    os.close(fd)
PY
setpriv --reuid=65534 --regid=65534 --clear-groups python3 /probe/p06/verify_product_ext4.py full "$mountpoint"
rm -- "$mountpoint/fill.bin"
setpriv --reuid=65534 --regid=65534 --clear-groups python3 /probe/p06/verify_product_ext4.py recovered "$mountpoint"
