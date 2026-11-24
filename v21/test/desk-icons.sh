#!/bin/bash
# Desktop icon column check on Xvfb: start the WM, screenshot the
# column, single-click the bottom icon (電卓) to check the
# selection rendering, then double-click 書庫 to check that the
# launcher actually starts PCManFM.
# Usage: desk-icons.sh <wm-binary> <tag>
# Screenshots land in v21/ as astro-desk-<tag>-{main,selected,launch}.png
# Honours 34OS_ICON_DIR / LD_LIBRARY_PATH from the environment.
set -u
WM_BIN="${1:?wm binary}"
TAG="${2:?tag}"
V21=$(cd "$(dirname "$0")/.." && pwd)
export DISPLAY=:99
export HOME=/tmp/fakehome-desk
export XDG_RUNTIME_DIR=/tmp/xdg-desk
export PATH="$V21/test/fakebin:$PATH"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
echo "42 on" > /tmp/fakeamixer.state; rm -f /tmp/fakeamixer.log
printf 'MyHomeWiFi:802-11-wireless\n' > /tmp/fakenmcli.active

# XTest click helper (synthetic events through the real pointer
# path, so ButtonPress times are genuine server times).
gcc -O2 -o /tmp/xt-desk "$V21/test/xt.c" -lX11 /lib/x86_64-linux-gnu/libXtst.so.6
click() { /tmp/xt-desk press "$1" "$2"; /tmp/xt-desk release "$1" "$2"; }
# Deterministic double-click: two XSendEvent presses with event
# times exactly 200 ms apart. Four xt process invocations cannot
# stay inside the double-click window reliably, so the launch
# check uses this instead (the WM reads the event time fields).
gcc -O2 -o /tmp/dclick-desk "$V21/test/dclick.c" -lX11

pkill -f "Xvfb :99" 2>/dev/null; sleep 0.5
Xvfb :99 -screen 0 1280x800x24 & XVFB_PID=$!
sleep 1.5

"$WM_BIN" & WM_PID=$!
sleep 4
import -window root "$V21/astro-desk-$TAG-main.png"
echo "screenshot: $V21/astro-desk-$TAG-main.png"

# Icon centres: x=58 (column is 116 wide); cell i centre y = 14 + i*92 + 24.
echo "=== single click: 電卓 (i=4, y=406) -> selection ==="
click 58 406
sleep 1
import -window root "$V21/astro-desk-$TAG-selected.png"
echo "screenshot: $V21/astro-desk-$TAG-selected.png"

echo "=== double click: 書庫 (i=1, y=130) -> launch pcmanfm ==="
/tmp/dclick-desk 130
sleep 3
import -window root "$V21/astro-desk-$TAG-launch.png"
echo "screenshot: $V21/astro-desk-$TAG-launch.png"

kill $WM_PID 2>/dev/null
pkill pcmanfm 2>/dev/null
kill $XVFB_PID 2>/dev/null
echo "=== desk-icons ($TAG) done ==="
