#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════
# deploy.sh — Build, deploy, launch & verify a Harbour app
#             on the Sailfish OS emulator (proven pipeline)
# ═════════════════════════════════════════════════════════════
# Full cycle in one command:
#   ./deploy.sh /path/to/harbour-foo --launch --screenshot
#
# Steps:
#   1. sfdk build            (build engine VM, port 2222)
#   2. scp RPM + rpm -Uvh    (emulator VM, port 2223)
#   3. sailjaild D-Bus       (grant launch + permissions → no GUI dialog)
#   4. sailjail launch       (proper sandboxed Sailfish app, full screen)
#   5. VBoxManage screenshot (visual verification)
#
# Usage:
#   ./deploy.sh APP_DIR [--launch] [--screenshot [PATH]] [--skip-build]
#   ./deploy.sh APP_DIR --stop                     # kill app
#   ./deploy.sh APP_DIR --uninstall                # remove from emulator
#
# Environment overrides:
#   SFDK, VM_NAME, SSH_PORT, SSH_KEY, SHOTS_DIR
# ═════════════════════════════════════════════════════════════
set -euo pipefail

SFDK="${SFDK:-$HOME/.local/bin/sfdk}"
VM_NAME="${VM_NAME:-SailfishOS-5.1.0.11}"
# Auto-detect the SailfishOS VM (name encodes the SDK version).
if [[ "${VM_NAME_AUTODETECT:-1}" == "1" ]]; then
    AD=$(VBoxManage list vms 2>/dev/null | sed -n 's/^"\([^"]*SailfishOS[^"]*\)".*/\1/p' | head -1)
    [[ -n "$AD" ]] && VM_NAME="$AD"
fi
SSH_PORT="${SSH_PORT:-2223}"
SSH_KEY="${SSH_KEY:-$HOME/SailfishOS/vmshare/ssh/private_keys/sdk}"
SSH_USER="${SSH_USER:-root}"
SSH_HOST="${SSH_HOST:-localhost}"
SHOTS_DIR="${SHOTS_DIR:-$(dirname "$0")/shots}"

# Non-interactive SSH: a first-ever connection on a fresh host must not hang
# on a host-key prompt. (SSH_HOST stays 127.0.0.1/localhost — see SECURITY.md.)
SSH_OPTS=(-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8)

# Session context of the GUI user inside the emulator
SESSION_USER="${SESSION_USER:-defaultuser}"
SESSION_UID="${SESSION_UID:-100000}"
SESSION_ENV="HOME=/home/defaultuser USER=defaultuser \
WAYLAND_DISPLAY=/run/display/wayland-0 \
XDG_RUNTIME_DIR=/run/user/100000 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket"

# Capability names understood by sailjaild (see /etc/sailfish/permissions/).
# Default: grant EVERYTHING (fast dev loop — no GUI permission dialogs).
# For UNTRUSTED apps pass a minimal list instead, e.g.:
#   PERMISSIONS="internet,audio" ./deploy.sh /path/to/app --launch
# The sailjail sandbox only enforces what is granted — see SECURITY.md.
PERMISSIONS="${PERMISSIONS:-internet,media_index,removable_media,user_directories,bluetooth,camera,microphone,audio,positioning,nfc,web_content}"
ALL_PERMISSIONS="array:string:${PERMISSIONS}"

# Concurrency guard: build engine + emulator are shared by ALL Bionic
# sessions on this host (single input channel; deploy kills running apps).
# Only run under a held pipeline lock (scripts/lock.sh hold).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-lock.sh"
sfos_require_lock "deploy.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }
ok()   { echo "  ✓ $*"; }

remote() {  # run a command as root inside the emulator
    ssh -p "$SSH_PORT" -i "$SSH_KEY" "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "$@"
}

session_run() {  # run a command as the GUI session user
    remote "su -s /bin/sh $SESSION_USER -c \"export $SESSION_ENV; $*\""
}

# ── Parse args ────────────────────────────────────────────────
APP_DIR=""
DO_LAUNCH=0
DO_SHOT=""
SKIP_BUILD=0
DO_STOP=0
DO_UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --launch)      DO_LAUNCH=1 ;;
        --screenshot)
            if [[ -n "${2:-}" && "${2:-}" != --* ]]; then DO_SHOT="$2"; shift; else DO_SHOT="auto"; fi
            ;;
        --skip-build)  SKIP_BUILD=1 ;;
        --stop)        DO_STOP=1 ;;
        --uninstall)   DO_UNINSTALL=1 ;;
        -h|--help)     grep "^# " "$0" | sed 's/^# //'; exit 0 ;;
        -*)            err "Unknown option: $1" ;;
        *)             APP_DIR="$1" ;;
    esac
    shift
done

[[ -n "$APP_DIR" && -d "$APP_DIR" ]] || err "Usage: $0 APP_DIR [--launch] [--screenshot [PATH]] [--stop] [--uninstall]"
cd "$APP_DIR"

# ── App name from the spec ────────────────────────────────────
SPEC_FILE=$(find . -maxdepth 3 -name "harbour-*.spec" | head -1)
[[ -n "$SPEC_FILE" ]] || err "No harbour-*.spec found under $APP_DIR"
APP_NAME=$(grep -m1 '^%define name' "$SPEC_FILE" | awk '{print $3}')
[[ -n "$APP_NAME" ]] || APP_NAME=$(basename "$SPEC_FILE" .spec)
BINARY="/usr/bin/$APP_NAME"
info "App: $APP_NAME"

# ── Emulator up? ──────────────────────────────────────────────
ensure_emulator() {
    if remote "true" 2>/dev/null; then
        ok "Emulator is up"
        return
    fi
    info "Emulator not reachable — starting $VM_NAME …"
    VBoxManage startvm "$VM_NAME" --type headless >/dev/null 2>&1 || true
    for i in $(seq 1 60); do
        remote "ps -eo comm | grep -q lipstick" 2>/dev/null && { ok "Emulator is up"; return; }
        sleep 2
    done
    err "Emulator did not come up. Check: VBoxManage list vms"
}

# ── 1. Build ──────────────────────────────────────────────────
build() {
    [[ "$SKIP_BUILD" == 1 ]] && { info "Skipping build"; return; }
    [[ -x "$SFDK" ]] || command -v sfdk >/dev/null || err "sfdk not found at $SFDK"
    info "Building on the engine …"
    "$SFDK" build
    local rpm
    rpm=$(ls -t RPMS/*.rpm 2>/dev/null | head -1)
    [[ -n "$rpm" ]] || err "Build did not produce an RPM (check sfdk output)"
    ok "Built $rpm"
    BUILD_RPM="$rpm"
}

# ── 2. Deploy ─────────────────────────────────────────────────
deploy() {
    local rpm="${BUILD_RPM:-$(ls -t RPMS/*.rpm | head -1)}"
    info "Deploying to emulator …"
    scp -P "$SSH_PORT" -i "$SSH_KEY" "${SSH_OPTS[@]}" "$rpm" "$SSH_USER@$SSH_HOST:/root/"
    # erase-then-install: works for same-version redeploy AND upgrades
    remote "rpm -e --nodeps $APP_NAME 2>/dev/null; rpm -i --nodeps /root/$(basename "$rpm")"
    ok "Installed (rpm -q: $(remote "rpm -q $APP_NAME" 2>/dev/null))"
}

# ── 3. Grant permissions (avoids the GUI permission dialog) ───
grant() {
    info "Granting launch permission + capabilities (${PERMISSIONS}) …"
    if [[ "$PERMISSIONS" == *"camera"* && "$PERMISSIONS" == *"microphone"* && "$PERMISSIONS" == *"positioning"* ]]; then
        info "  (default = ALL capabilities. For untrusted apps use PERMISSIONS=\"internet,audio\" — see SECURITY.md)"
    fi
    remote "dbus-send --system --print-reply --dest=org.sailfishos.sailjaild1 \
        /org/sailfishos/sailjaild1 org.sailfishos.sailjaild1.SetLaunchAllowed \
        uint32:$SESSION_UID string:$APP_NAME int32:1" >/dev/null
    remote "dbus-send --system --print-reply --dest=org.sailfishos.sailjaild1 \
        /org/sailfishos/sailjaild1 org.sailfishos.sailjaild1.SetGrantedPermissions \
        uint32:$SESSION_UID string:$APP_NAME $ALL_PERMISSIONS" >/dev/null
    ok "Permissions granted"
}

# ── 4. Launch via invoker (proper Sailfish sandbox) ───────────
# NOTE: `sailjail` binary is broken on SDK images (missing disable-common.local
# profile → "Permission denied"). `invoker -s --type=silica-session` uses the
# same firejail sandbox + sailjaild permissions but works reliably.
# Apps launched from CLI start in the BACKGROUND (behind home screen).
# Use tap.sh/swipe.sh to interact, or tap the app icon to raise it.
launch() {
    stop_app  # kill any previous instance
    info "Launching via invoker (sailjaild sandbox) …"
    session_run "setsid nohup /usr/bin/invoker -s --type=silica-session $BINARY >/tmp/$APP_NAME.log 2>&1 < /dev/null &"
    sleep 8
    if remote "pgrep $APP_NAME" >/dev/null 2>&1; then
        ok "Running (pid $(remote "pgrep $APP_NAME" | head -1))"
        info "  (app is in background — tap its icon or use tap.sh to interact)"
    else
        echo "  ✗ not running — last log lines:"
        remote "tail -5 /tmp/$APP_NAME.log 2>/dev/null" || true
        remote "journalctl -n 10 2>/dev/null | grep -iE 'invoker|sailjail|$APP_NAME' | tail -5" || true
        return 1
    fi
}

stop_app() {
    # SIGKILL: avoids firejail's noisy (harmless) clear_atexit seteuid error on SIGTERM
    remote "pkill -9 $APP_NAME 2>/dev/null" || true
    # sailjail wrapper process may linger:
    remote "pkill -9 -f 'sailjail -- $BINARY' 2>/dev/null" || true
    sleep 1
}

uninstall() {
    stop_app
    info "Uninstalling $APP_NAME …"
    remote "rpm -e --nodeps $APP_NAME" || info "(package was not installed)"
    ok "Uninstalled"
}

screenshot() {
    mkdir -p "$SHOTS_DIR"
    local path="${1:-$SHOTS_DIR/$(date +%Y%m%d-%H%M%S).png}"
    VBoxManage controlvm "$VM_NAME" screenshotpng "$path" >/dev/null
    ok "Screenshot: $path"
    SHOT_PATH="$path"
}

# ── Execute ───────────────────────────────────────────────────
if [[ "$DO_UNINSTALL" == 1 ]]; then
    ensure_emulator; uninstall; exit 0
fi
if [[ "$DO_STOP" == 1 ]]; then
    ensure_emulator; stop_app; ok "Stopped"; exit 0
fi

ensure_emulator
build
deploy
if [[ "$DO_LAUNCH" == 1 ]]; then
    grant
    launch
    if [[ -n "$DO_SHOT" ]]; then
        sleep 2
        [[ "$DO_SHOT" == "auto" ]] && screenshot || screenshot "$DO_SHOT"
        echo "  Screenshot: $SHOT_PATH"
    fi
fi
echo
echo "  App log:    ssh -p $SSH_PORT -i \$SSH_KEY root@$SSH_HOST 'cat /tmp/$APP_NAME.log'"
echo "  Stop:       $0 $APP_DIR --stop"
echo "  Uninstall:  $0 $APP_DIR --uninstall"
