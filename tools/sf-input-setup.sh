#!/bin/sh
# sf-input-setup.sh — idempotent setup of the agent tap/swipe input pipeline.
# Safe to re-run any time (fresh boot or mid-session).
#
# Pipeline: libvboxfake.so (mouse position) + vts-mouse uinput (button press),
# both consumed by lipstick -plugin VBoxTouch.
set -u

USER_NAME=defaultuser
UID_NUM=100000

echo "[1/4] persistent shim env -> /var/lib/environment/compositor/90-vboxfake.conf"
mkdir -p /var/lib/environment/compositor
cat > /var/lib/environment/compositor/90-vboxfake.conf <<"CONF"
LD_PRELOAD=/usr/local/lib/libvboxfake.so
VIRTUALBOX_TOUCH_GUEST_DEVICE=/tmp/vboxfake
CONF

echo "[2/4] (re)start single vts daemon"
for p in $(pgrep -f "/usr/local/bin/vts"); do kill -9 "$p" 2>/dev/null || true; done
sleep 1
nohup /usr/local/bin/vts >/tmp/vts.log 2>&1 &
sleep 1

echo "[3/4] link vts-mouse into the i8042 by-path slot"
sh /usr/local/bin/vts-link.sh

echo "[4/4] restart lipstick so it reopens shim + fresh evdev device"
su "$USER_NAME" -s /bin/sh -c "XDG_RUNTIME_DIR=/run/user/$UID_NUM systemctl --user restart lipstick"
sleep 4

echo "=== verify ==="
echo -n "vts procs: "; pgrep -f "/usr/local/bin/vts" | wc -l
echo -n "vts-mouse event: "; grep -A4 "vts-mouse" /proc/bus/input/devices | grep Handlers=
echo -n "link: "; readlink /dev/input/by-path/platform-i8042-serio-1-event-mouse
# `pgrep -x` silently fails here (busybox); `pgrep lipstick` also matches
# `lipstick-securi*` — match the exact comm:
LPID=$(ps -eo pid,comm | awk '$2=="lipstick"{print $1; exit}')
echo -n "lipstick pid: $LPID ; shim refs: "; grep -c vboxfake /proc/$LPID/maps 2>/dev/null
