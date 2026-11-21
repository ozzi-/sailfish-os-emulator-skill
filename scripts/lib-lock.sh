# ═════════════════════════════════════════════════════════════
# lib-lock.sh — shared concurrency guard for the SFOS pipeline
# Source this from mutating scripts (tap/swipe/deploy/apply-input).
#
# The emulator + build engine are ONE shared pair of VMs for every
# Bionic session on this host, and the input pipeline is a single
# global channel (no per-caller isolation). So mutating operations
# are only allowed while a session holds the pipeline lock
# (scripts/lock.sh hold). Kernel flock() — no stale locks possible.
#
#   SFOSSKILL_NO_LOCK=1   bypass the guard (breaks glass; documented)
# ═════════════════════════════════════════════════════════════
: "${SFOSSKILL_LOCK_FILE:=/tmp/sfos-pipeline.lock}"

sfos_require_lock() {  # $1 = calling script name
    if [[ "${SFOSSKILL_NO_LOCK:-0}" == "1" ]]; then
        echo "  ⚠ LOCK GUARD BYPASSED (SFOSSKILL_NO_LOCK=1) — $1"
        return 0
    fi
    local caller="${1:-script}"
    if ! command -v flock >/dev/null 2>&1; then
        echo "ERROR: flock not found (util-linux required by the lock guard)." >&2
        exit 1
    fi
    if flock -n "$SFOSSKILL_LOCK_FILE" true 2>/dev/null; then
        echo "BLOCKED: the SFOS pipeline lock is held by another session (exit 75)." >&2
        echo "  One session drives the shared emulator at a time; interleaving" >&2
        echo "  corrupts both sessions' UI verification." >&2
        echo "" >&2
        echo "  Recovery:" >&2
        echo "    bash scripts/lock.sh status   # holder pid + how long held (poll until FREE)" >&2
        echo "    bash scripts/lock.sh release  # end YOUR session's hold early (kills current holder)" >&2
        echo "  A crashed/dead holder frees itself: the lock auto-expires (holder" >&2
        echo "  sleeps N minutes) and the kernel drops a dead holder's lock instantly —" >&2
        echo "  there are no stuck locks to clean up by hand." >&2
        exit 75   # EX_TEMPFAIL — "try again later"
    fi
    # Lock is held (by us or another session): this op is covered.
    return 0
}
