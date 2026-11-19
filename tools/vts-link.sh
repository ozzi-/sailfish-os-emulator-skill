#!/bin/sh
# Point the i8042 mouse by-path symlink at the vts-mouse uinput device.
# (The vboxtouch plugin reads button state from this path.)
# Run after vts is up.
VM=$(grep -A4 'Name="vts-mouse"' /proc/bus/input/devices | grep Handlers= | sed 's/.*Handlers=//;s/ .*//')
[ -n "$VM" ] || { echo "vts-mouse not found (is vts running?)"; exit 1; }
ln -sfn ../$VM /dev/input/by-path/platform-i8042-serio-1-event-mouse
echo "linked i8042-serio-1-event-mouse -> $VM"
