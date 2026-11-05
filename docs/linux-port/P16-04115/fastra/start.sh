#!/bin/bash
set -eu
export HOME=/work/home XDG_CONFIG_HOME=/work/config XDG_CACHE_HOME=/work/cache XDG_DATA_HOME=/work/data XDG_STATE_HOME=/work/state XDG_RUNTIME_DIR=/work/run
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export DISPLAY=:99 GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none GIO_USE_VFS=local GSETTINGS_BACKEND=memory LANGUAGE=en FASTRA_ISOLATED_DISPLAY=1
Xvfb :99 -screen 0 1450x1200x24 -nolisten tcp >/work/xvfb.log 2>&1 &
export DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address)
sleep 1
/app/bin/fastra >/work/app.log 2>&1 &
wait
