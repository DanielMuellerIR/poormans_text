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
    if [[ "$associated" == "$loop" ]]; then
      losetup -d "$loop" || status=91
    else
      echo 'Unerwartete Loopzuordnung; kein fremdes Gerät wird verändert.' >&2
      status=92
    fi
  fi
  if [[ "$status" -eq 0 ]]; then
    [[ -z "$(losetup --associated "$image" --noheadings --output NAME)" ]] || status=93
    if [[ "$status" -eq 0 ]]; then
      rm -- "$image"
      [[ ! -e "$image" ]] || status=94
      printf '{"unmounted":true,"ownLoopDetached":true,"imageRemoved":true}\n' > /results/cleanup.json
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
truncate -s 64M "$image"
mkfs.ext4 -q -F -m 0 "$image"
mkdir -p "$mountpoint"
TMPDIR=/run clang -Wall -Wextra -Werror -O2 /probe/loop_mount.c -o /run/loop-mount
set +e
/run/loop-mount "$image" "$mountpoint" kill-after-attach
attach_status=$?
set -e
[[ "$attach_status" == 137 ]]
[[ -z "$(losetup --associated "$image" --noheadings --output NAME)" ]]
set +e
/run/loop-mount "$image" "$mountpoint" kill-after-mount
mount_status=$?
set -e
[[ "$mount_status" == 137 ]]
[[ "$(findmnt -n -o FSTYPE --target "$mountpoint")" == ext4 ]]
umount "$mountpoint"
[[ -z "$(losetup --associated "$image" --noheadings --output NAME)" ]]
loop=$(/run/loop-mount "$image" "$mountpoint")
[[ "$loop" =~ ^/dev/loop[0-9]+$ ]]
[[ "$(losetup --associated "$image" --noheadings --output NAME)" == "$loop" ]]
[[ "$(losetup --list --noheadings --output AUTOCLEAR "$loop" | tr -d ' ')" == 1 ]]
printf '{"atomicAutoClearAttach":true,"attachHelperSigkillStatus":%s,"mountHelperSigkillStatus":%s,"bothFaultLoopsReleased":true}\n' "$attach_status" "$mount_status" > /results/lifecycle.json
findmnt -n -o FSTYPE,SOURCE,TARGET --target "$mountpoint" > /results/mount.txt
stat -f -c 'family=%T magic=%t blocksize=%S totalblocks=%b freeblocks=%f' "$mountpoint" > /results/statfs-before.txt
python3 /probe/fd_publication.py before-full "$mountpoint"
set +e
dd if=/dev/zero of="$mountpoint/fill.bin" bs=1M count=80 conv=fsync status=none 2>/results/enospc.stderr
fill_status=$?
set -e
[[ "$fill_status" -ne 0 ]] && grep -q 'No space left on device' /results/enospc.stderr
stat -f -c 'family=%T magic=%t blocksize=%S totalblocks=%b freeblocks=%f' "$mountpoint" > /results/statfs-full.txt
python3 /probe/fd_publication.py after-full "$mountpoint"
findmnt -n -o FSTYPE --target "$mountpoint" | grep -Fxq ext4
printf '{"kernelFilesystem":"ext4","imageBytes":67108864,"fillExitStatus":%s,"enospcObserved":true}\n' "$fill_status" > /results/filesystem.json
dpkg-query -W python3-minimal e2fsprogs util-linux > /results/packages.txt
cat /results/filesystem.json
