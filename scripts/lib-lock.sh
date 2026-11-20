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
        echo "BLOCKED: the SFOS pipeline lock is not held." >&2
        echo "  The shared emulator is only driven under a session lock —" >&2
        echo "  otherwise concurrent sessions corrupt each other's UI verification." >&2
        echo "" >&2
        echo "  Start of a test workflow:  bash scripts/lock.sh hold 30" >&2
        echo "  End of the workflow:      bash scripts/lock.sh release" >&2
        echo "  Status:                   bash scripts/lock.sh status" >&2
        exit 75   # EX_TEMPFAIL — "try again later"
    fi
    # Lock is held (by us or another session): this op is covered.
    return 0
}
