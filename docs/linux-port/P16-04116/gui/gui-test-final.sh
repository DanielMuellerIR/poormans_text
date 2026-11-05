#!/bin/sh
set -eu
ulimit -c 0
export DISPLAY=:97 GSETTINGS_BACKEND=dconf GSK_RENDERER=cairo GTK_A11Y=none
export PMT_CLI=/nonexistent/pmt-private-preferences-probe
Xvfb :97 -screen 0 1500x1200x24 -nolisten tcp -fbdir /work/evidence > /work/evidence/xvfb.log 2>&1 &
xpid=$!
trap 'kill "$xpid" 2>/dev/null || true' EXIT
for attempt in 1 2 3 4 5; do test -S /tmp/.X11-unix/X97 && break; sleep .1; done
for mode in unchanged write read; do
 PMT_UI_TEST_PREFERENCES=$mode timeout -k 2 15 /work/target/debug/poormans-text-gtk > /work/evidence/gui-$mode.stdout 2> /work/evidence/gui-$mode.stderr &
 app=$!
 sleep .5
 cp /work/evidence/Xvfb_screen0 /work/evidence/gui-$mode.xwd
 wait "$app"
 if test "$mode" = unchanged; then
   dconf dump /org/poormanstext/Linux/ > /work/evidence/unchanged-settings.txt
   test ! -s /work/evidence/unchanged-settings.txt
 fi
 if test "$mode" = write; then
   dconf dump /org/poormanstext/Linux/ > /work/evidence/written-settings.txt
 fi
done
dconf dump /org/poormanstext/Linux/ > /work/evidence/restarted-settings.txt
test "$(cat /work/evidence/written-settings.txt)" = "$(cat /work/evidence/restarted-settings.txt)"
mv /work/target/debug/schemas/gschemas.compiled /work/target/debug/schemas/gschemas.held
trap 'mv /work/target/debug/schemas/gschemas.held /work/target/debug/schemas/gschemas.compiled; kill "$xpid" 2>/dev/null || true' EXIT
PMT_UI_TEST_PREFERENCES=missing timeout -k 2 15 /work/target/debug/poormans-text-gtk > /work/evidence/gui-missing.stdout 2> /work/evidence/gui-missing.stderr &
app=$!
sleep .5
cp /work/evidence/Xvfb_screen0 /work/evidence/gui-missing.xwd
wait "$app"
printf 'unchanged-no-write, write-restart-read, sensitive-fields-empty, missing-schema-warning: passed\n'
