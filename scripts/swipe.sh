#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════
# swipe.sh — Inject a swipe gesture between two SCREEN coordinates
#
# Usage:
#   ./swipe.sh X0 Y0 X1 Y1 [STEPS]
#
# Environment overrides (all optional):
#   SCREEN_W (default 1088), SCREEN_H (default 2260)   [standard phone resolution, SETUP.md §2.4]
#   SSH_PORT (default 2223), SSH_KEY, SSH_USER (root), SSH_HOST (127.0.0.1)
#
# HOW IT WORKS (verified — full down→motion*→up delivered):
#   Same two-source model as tap.sh (shim position + vts button):
#     1. write start pos to /tmp/vboxfake.pos + kick FIFO + vts 'press'
#        (BTN_LEFT held down)
#     2. for each step: update /tmp/vboxfake.pos + kick + vts 'mmove'
#        (plugin emits wl_touch.motion per polled position change)
#     3. write end pos + kick + vts 'release'
#
# COORDINATE MAPPING: DX = X*65536/SCREEN_W, DY = Y*65536/SCREEN_H
# (The vts mouse ABS_X/ABS_Y values are irrelevant — the plugin takes the
#  position from the vboxguest GET, i.e. the shim.)
# ═════════════════════════════════════════════════════════════
set -euo pipefail

# Concurrency guard: the emulator is shared by ALL Bionic sessions on this
# host — swipes are only allowed under a held pipeline lock (scripts/lock.sh).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lock.sh"
sfos_require_lock "swipe.sh"

SCREEN_W="${SCREEN_W:-1088}"
SCREEN_H="${SCREEN_H:-2260}"
SSH_PORT="${SSH_PORT:-2223}"
SSH_KEY="${SSH_KEY:-$HOME/SailfishOS/vmshare/ssh/private_keys/sdk}"
SSH_USER="${SSH_USER:-root}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"

if [[ $# -lt 4 || $# -gt 5 ]]; then
    echo "Usage: $0 X0 Y0 X1 Y1 [STEPS]" >&2
    exit 1
fi

X0="$1"; Y0="$2"; X1="$3"; Y1="$4"
STEPS="${5:-12}"

for v in "$X0" "$Y0" "$X1" "$Y1" "$STEPS"; do
    if ! [[ "$v" =~ ^[0-9]+$ ]]; then
        echo "Error: all values must be non-negative integers" >&2
        exit 1
    fi
done
for v in "$X0" "$X1"; do
    if (( v >= SCREEN_W )); then
        echo "Error: X out of range (max $((SCREEN_W-1)))" >&2
        exit 1
    fi
done
for v in "$Y0" "$Y1"; do
    if (( v >= SCREEN_H )); then
        echo "Error: Y out of range (max $((SCREEN_H-1)))" >&2
        exit 1
    fi
done

echo "  Swipe: ($X0,$Y0) → ($X1,$Y1) in $STEPS steps (screen ${SCREEN_W}x${SCREEN_H})"

# Build one guest-side script: setpos + kick per step.
set_pos() {
    local DX=$(( $1 * 65536 / SCREEN_W ))
    local DY=$(( $2 * 65536 / SCREEN_H ))
    printf "echo '%d %d' > /tmp/vboxfake.pos; printf x > /tmp/vboxfake; sleep 0.12; " "$DX" "$DY"
}

cmds=""
cmds+="$(set_pos "$X0" "$Y0") echo 'press 1 1' > /tmp/vts.cmd; sleep 0.25; "
for i in $(seq 1 "$STEPS"); do
    lx=$(( X0 + (X1 - X0) * i / STEPS ))
    ly=$(( Y0 + (Y1 - Y0) * i / STEPS ))
    cmds+="$(set_pos "$lx" "$ly") echo 'mmove 1 1' > /tmp/vts.cmd; "
done
cmds+="$(set_pos "$X1" "$Y1") echo 'release 1 1' > /tmp/vts.cmd; sleep 0.5; "

ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 \
    "$SSH_USER@$SSH_HOST" \
    "${cmds}echo ok"
