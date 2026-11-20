#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════
# publish.sh — Push gate: the full smoke suite must pass before
#              any version of the skill leaves this machine.
#
#   bash scripts/publish.sh
#
# Flow:
#   1. warn if the working tree is dirty (uncommitted changes are NOT
#      pushed — commit first)
#   2. run scripts/smoke.sh --all  (T0 static + T1 guest health + T2 e2e)
#   3. push only if every test passed
#
# Rationale: a broken skill shipped to other Bionic users is worse than
# no release at all. The suite is strict — no WARN tier — so "green"
# means the pipeline was verified end-to-end a few seconds ago.
# ═════════════════════════════════════════════════════════════
set -u

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPTS_DIR/.." && pwd)"
cd "$REPO"

echo
echo "=== publish: smoke gate ==="

# ── 1. Working tree state ──────────────────────────────────────
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "  ⚠ working tree is dirty — uncommitted changes will NOT be pushed:"
    git status --short | sed 's/^/      /'
    echo
fi

# ── 2. Full smoke suite ────────────────────────────────────────
if bash "$SCRIPTS_DIR/smoke.sh" --all; then
    :
else
    echo
    echo "✗ PUSH REFUSED: the smoke suite reported failures (see above)."
    echo "  Fix the failing tests, re-run, then publish again."
    exit 1
fi

# ── 3. Push ────────────────────────────────────────────────────
echo
if git push origin HEAD 2>&1 | sed 's/^/  /'; then
    echo "  ✓ pushed (smoke suite green)"
else
    echo "  ✗ git push failed (see above)"
    exit 1
fi
