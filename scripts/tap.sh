#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════
# tap.sh — Inject a tap at SCREEN coordinates on the SFOS emulator
#
# Usage:
#   ./tap.sh X Y                # tap at screen position (px)
#
# Environment overrides (all optional):
#   SCREEN_W (default 1088), SCREEN_H (default 2260)   [standard phone resolution, SETUP.md §2.4]
#   SSH_PORT (default 2223), SSH_KEY, SSH_USER (root), SSH_HOST (127.0.0.1)
#
# HOW IT WORKS (verified, sub-pixel accurate):
#   The vboxtouch plugin (lipstick) composes a touch event from TWO sources:
#     - POSITION: from the /dev/vboxguest GET ioctl → intercepted by the
#                 libvboxfake.so shim, which serves /tmp/vboxfake.pos
#                 (format "DX DY", values in 0..65535 = 16-bit device space)
#     - BUTTON:   BTN_LEFT from the evdev mouse (vts-mouse uinput device,
#                 served by the vts daemon reading /tmp/vts.cmd)
#   A kick byte written to the /tmp/vboxfake FIFO wakes the plugin's event
#   loop so it polls (GET) while BTN_LEFT is down → touch down; button up
#   → touch up.
#
# COORDINATE MAPPING (verified: tap (272,565) delivered (271.75,564.76)):
#   DX = X * 65536 / SCREEN_W
#   DY = Y * 65536 / SCREEN_H
#
# TRAP: evdev mouse coordinates are IGNORED for position. If every tap
# lands at screen center, the position file was not updated.
# ═════════════════════════════════════════════════════════════
set -euo pipefail

# Concurrency guard: the emulator is shared by ALL Bionic sessions on this
# host — taps are only allowed under a held pipeline lock (scripts/lock.sh).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lock.sh"
sfos_require_lock "tap.sh"

SCREEN_W="${SCREEN_W:-1088}"
SCREEN_H="${SCREEN_H:-2260}"
SSH_PORT="${SSH_PORT:-2223}"
SSH_KEY="${SSH_KEY:-$HOME/SailfishOS/vmshare/ssh/private_keys/sdk}"
SSH_USER="${SSH_USER:-root}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 X Y  (screen coords 0..$((SCREEN_W-1)) x 0..$((SCREEN_H-1)))" >&2
    exit 1
fi

SX="$1"
SY="$2"

if ! [[ "$SX" =~ ^[0-9]+$ && "$SY" =~ ^[0-9]+$ ]]; then
    echo "Error: X and Y must be non-negative integers" >&2
    exit 1
fi
if (( SX >= SCREEN_W || SY >= SCREEN_H )); then
    echo "Error: coords out of range (max $((SCREEN_W-1))x$((SCREEN_H-1)))" >&2
    exit 1
fi

DX=$(( SX * 65536 / SCREEN_W ))
DY=$(( SY * 65536 / SCREEN_H ))

echo "  Tap: screen ($SX,$SY) → device ($DX,$DY)"

ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
    "$SSH_USER@$SSH_HOST" \
    "echo '$DX $DY' > /tmp/vboxfake.pos; \
     printf x > /tmp/vboxfake; \
     sleep 0.3; \
     echo 'click 1 1' > /tmp/vts.cmd; \
     sleep 0.8; \
     echo ok"
