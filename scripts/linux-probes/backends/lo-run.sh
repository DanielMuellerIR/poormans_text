#!/bin/bash
set -eu
root="${PMT_P04_ROOT:-/tmp/pmt-p04}"
[[ "$root" = /* ]] || { echo 'PMT_P04_ROOT must be absolute' >&2; exit 64; }
profile_uri="$(python3 -c 'import pathlib,sys; print((pathlib.Path(sys.argv[1])/"lo-profile").as_uri())' "$root")"
bwrap --unshare-net --unshare-pid --die-with-parent --new-session --ro-bind / / --bind "$root" "$root" --tmpfs /tmp --bind "$root" "$root" --tmpfs /home --tmpfs /root --tmpfs /run --proc /proc --dev /dev --unsetenv DISPLAY --unsetenv WAYLAND_DISPLAY --setenv HOME "$root/lo-home" --setenv SAL_USE_VCLPLUGIN svp /usr/bin/timeout --kill-after=2 30 /usr/bin/libreoffice "-env:UserInstallation=$profile_uri" --headless --nologo --nodefault --norestore --nolockcheck "$@"
