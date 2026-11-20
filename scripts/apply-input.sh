#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════
# apply-input.sh — Guarded wrapper: deploy/apply the guest input pipeline
#
# Why a wrapper: sf-input-setup.sh RESTARTS LIPSTICK, which KILLS every
# running app in the guest. Running it while another session is mid-
# verification would destroy their state. So it goes through the same
# pipeline lock as tap.sh / swipe.sh / deploy.sh.
#
# Usage:
#   bash scripts/apply-input.sh          # after lock.sh hold (or under one)
#
# Effect (guest, idempotent — see tools/sf-input-setup.sh):
#   re-applies the LD_PRELOAD shim env, restarts exactly ONE vts daemon,
#   relinks the vts-mouse evdev device, restarts lipstick, prints a
#   verification summary.
# ═════════════════════════════════════════════════════════════
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lock.sh"
sfos_require_lock "apply-input.sh"

SSH_PORT="${SSH_PORT:-2223}"
SSH_KEY="${SSH_KEY:-$HOME/SailfishOS/vmshare/ssh/private_keys/sdk}"
SSH_USER="${SSH_USER:-root}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"

echo "  Applying input pipeline (guarded)…"
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes \
    -o ConnectTimeout=8 "$SSH_USER@$SSH_HOST" '/usr/local/bin/sf-input-setup.sh'
echo "  ✓ input pipeline applied. NOTE: running apps were killed — relaunch via deploy.sh."
