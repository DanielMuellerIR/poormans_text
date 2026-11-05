#!/bin/bash
set -euo pipefail
export HOME=/work/gui-home TMPDIR=/work/tmp XDG_CONFIG_HOME=/work/gui-config XDG_CACHE_HOME=/work/gui-cache XDG_DATA_HOME=/work/gui-data XDG_RUNTIME_DIR=/work/gui-run
export PATH=/work/bin:/usr/bin:/bin GSETTINGS_BACKEND=memory GTK_A11Y=none GIO_USE_VFS=local GDK_BACKEND=x11 GSK_RENDERER=cairo LD_LIBRARY_PATH=/app/lib
ulimit -c 0
export FASTRA_ISOLATED_DISPLAY=1 FASTRA_TOOL_SELFTEST=import FASTRA_TOOL_FIXTURE=/work/gui-fixture LANGUAGE=en
unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS DISPLAY WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS
exec timeout --signal=TERM --kill-after=3 45 xvfb-run -a -s '-screen 0 1400x1000x24 -nolisten tcp' dbus-run-session --config-file=/work/test-dbus.conf -- /app/fastra-linux
