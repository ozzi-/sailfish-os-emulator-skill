#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════
# lock.sh — Session lock for the shared SFOS pipeline
#
# WHY THIS EXISTS:
#   The emulator + build engine are ONE shared pair of VMs for every
#   Bionic session on this host. The input pipeline is a single global
#   channel (/tmp/vboxfake.pos + FIFO + vts, no per-caller isolation),
#   and deploy/input-setup restarts lipstick, which KILLS running apps.
#   Two agents interleaving taps/screenshots corrupt BOTH verifications.
#   So: one session holds the pipeline lock per test workflow; everyone
#   else's mutating operations fail fast with a clear message.
#
# MECHANISM: kernel flock() on LOCK_FILE, held by a detached background
# process (auto-expires after MIN minutes). The kernel releases the lock
# the instant the holder dies — there are NO stale locks to clean up.
#
# Usage:
#   ./lock.sh hold [MIN]      # hold the lock for MIN minutes (default 30)
#   ./lock.sh release         # drop the lock immediately (if we hold it)
#   ./lock.sh status          # print holder info (exit 0 = free, 1 = held)
#   ./lock.sh wait [SECS]     # block until free (default 120s); exit 0/2
#
# Environment: SFOSSKILL_LOCK_FILE (default /tmp/sfos-pipeline.lock)
#
# RULE (see SKILL.md): hold the lock for the ENTIRE test workflow
# (deploy → tap → screenshot → verify → release). Read-only observation
# (screenshotpng, journalctl) is allowed anytime but must not be
# INTERPRETED while another session holds the lock.
# ═════════════════════════════════════════════════════════════
set -euo pipefail

LOCK_FILE="${SFOSSKILL_LOCK_FILE:-/tmp/sfos-pipeline.lock}"
HOLDER_PID_FILE="${LOCK_FILE}.holder"
MIN=30
WAIT_SECS=120

die() { echo "ERROR: $*" >&2; exit 1; }

status_out() {
    if flock -n "$LOCK_FILE" true 2>/dev/null; then
        echo "LOCK FREE."
        return 0
    fi
    local pid="?"
    [[ -f "$HOLDER_PID_FILE" ]] && pid=$(cat "$HOLDER_PID_FILE" 2>/dev/null || echo '?')
    local started="?"
    if [[ "$pid" != "?" ]] && [[ -d "/proc/$pid" ]]; then
        started=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    fi
    echo "LOCKED: holder pid $pid (running ${started:-?})."
    echo "  Another session is driving the shared pipeline. Do NOT inject"
    echo "  input, deploy, or restart the compositor now."
    return 1
}

case "${1:-}" in
    hold)
        MIN="${2:-30}"
        [[ "$MIN" =~ ^[0-9]+$ ]] || die "minutes must be a positive integer"
        (( MIN >= 1 && MIN <= 480 )) || die "minutes must be 1..480"
        if ! flock -n "$LOCK_FILE" true 2>/dev/null; then
            echo "LOCKED: another session holds the SFOS pipeline lock."
            status_out
            echo "  Wait for it to expire:  $0 status   (poll until FREE)"
            echo "  Or drop it (yours?):    $0 release"
            exit 1
        fi
        # Detached holder: keeps the flock fd open for $MIN minutes, then
        # the kernel releases the lock. Survives the caller's shell exiting.
        setsid nohup bash -c "
            exec 9>>'${LOCK_FILE}'
            flock -n 9 || exit 1
            echo \$\$ > '${HOLDER_PID_FILE}'
            sleep ${MIN} 9>&-   # fd 9 = the lock; must NOT leak to the sleep child
            rm -f '${HOLDER_PID_FILE}'
        " </dev/null >/dev/null 2>&1 &
        # Give the holder a moment to grab the lock (it had the free window).
        sleep 0.3
        if flock -n "$LOCK_FILE" true 2>/dev/null; then
            die "could not acquire the lock (race — try again)"
        fi
        echo "LOCK HELD for ${MIN} min (auto-expires; holder pid $(cat "$HOLDER_PID_FILE" 2>/dev/null || echo '?'))."
        echo "  Run your full workflow now, then: $0 release   (or let it expire)"
        ;;
    release)
        if [[ -f "$HOLDER_PID_FILE" ]]; then
            pid=$(cat "$HOLDER_PID_FILE" 2>/dev/null || true)
            if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
                # Kill the whole group (holder + any children that inherited the lock fd).
                kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
                rm -f "$HOLDER_PID_FILE"
                sleep 0.3
            else
                rm -f "$HOLDER_PID_FILE"
            fi
        fi
        if flock -n "$LOCK_FILE" true 2>/dev/null; then
            echo "LOCK FREE (released)."
        else
            echo "still LOCKED (another holder exists — release only kills OUR holder)."
            exit 1
        fi
        ;;
    status)
        status_out
        ;;
    wait)
        WAIT_SECS="${2:-120}"
        [[ "$WAIT_SECS" =~ ^[0-9]+$ ]] || die "seconds must be a positive integer"
        if timeout "$WAIT_SECS" flock -w "$WAIT_SECS" "$LOCK_FILE" true 2>/dev/null; then
            echo "LOCK FREE (waited ≤ ${WAIT_SECS}s)."
            exit 0
        fi
        echo "TIMEOUT: still locked after ${WAIT_SECS}s." >&2
        exit 2
        ;;
    -h|--help|"")
        sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
        [[ -n "${1:-}" ]] || exit 1
        ;;
    *) die "unknown command: $1 (hold|release|status|wait)" ;;
esac
