#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════
# sync-local.sh — Sync the skill repo into the local Bionic skills folder.
#
#   bash scripts/sync-local.sh             # sync + verify
#   bash scripts/sync-local.sh --check     # diff only, change nothing
#   bash scripts/sync-local.sh --dry-run   # preview what would change
#   bash scripts/sync-local.sh --dest DIR  # non-default destination
#
# The repo is the single source of truth; the installed copy is a plain
# folder (no .git, no README.md — both are repo-only and never synced).
# Idempotent — safe to re-run any time. Extra files in the destination
# (e.g. stray shots/) are removed: it is a copy, nothing more.
#
# Safety rails:
#   * destination must be inside ~/.lmstudio/skills/ (the canonical
#     skill home) — refuses anything else, so a bad --dest can never
#     rsync --delete into an unrelated folder
#   * .git and README.md are excluded (and protected from deletion)
#   * a dirty working tree only WARNS — syncing uncommitted changes is
#     the normal "test locally before committing" workflow
# ═════════════════════════════════════════════════════════════
set -u
set -o pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPTS_DIR/.." && pwd)"
SKILLS_HOME="$HOME/.lmstudio/skills"
DEST="$SKILLS_HOME/sailfish-os"
CHECK=0
DRY=0

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)    DEST="${2:?--dest needs a path}"; shift 2 ;;
        --check)   CHECK=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1 (use --dest DIR | --check | --dry-run | --help)" >&2; exit 2 ;;
    esac
done

# ── Sanity ─────────────────────────────────────────────────────
[[ -f "$REPO/SKILL.md" ]] || { echo "✗ $REPO has no SKILL.md — not the skill repo root." >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "✗ rsync is required but not installed." >&2; exit 1; }

# DEST must be inside the canonical skills home.
case "$DEST/" in
    "$SKILLS_HOME"/*) : ;;
    *) echo "✗ destination '$DEST' must be inside $SKILLS_HOME (refusing)." >&2; exit 1 ;;
esac
DEST="${DEST%/}"

# ── Report version (from SKILL.md front matter) ────────────────
VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$REPO/SKILL.md" 2>/dev/null | head -n1 | tr -d '"')"
[[ -n "$VERSION" ]] || VERSION="(no version: line in SKILL.md)"

# ── --check: diff only ─────────────────────────────────────────
if [[ $CHECK -eq 1 ]]; then
    if [[ ! -d "$DEST" ]]; then
        echo "not installed: $DEST does not exist yet (run sync-local.sh to install)"
        exit 1
    fi
    if diff -rq --exclude=.git --exclude=README.md "$REPO" "$DEST"; then
        echo "✓ in sync: $DEST (version: $VERSION)"
        exit 0
    else
        echo "✗ out of sync (see diff above): $DEST (repo version: $VERSION)"
        exit 1
    fi
fi

# ── Warn (don't block) on uncommitted changes ──────────────────
if [[ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]]; then
    echo "⚠ repo working tree is dirty — syncing UNCOMMITTED changes:"
    git -C "$REPO" status --short | sed 's/^/    /'
fi

# ── Sync ───────────────────────────────────────────────────────
mkdir -p "$(dirname "$DEST")"

RSYNC_FLAGS=(-a --delete --exclude=.git --exclude=README.md)
if [[ $DRY -eq 1 ]]; then
    RSYNC_FLAGS+=(--dry-run --itemize-changes)
    echo "=== sync (dry-run, nothing will change): $REPO/ → $DEST/ ==="
    rsync "${RSYNC_FLAGS[@]}" "$REPO/" "$DEST/"
    echo "  (re-run without --dry-run to apply)"
    exit 0
fi

echo "=== sync: $REPO/ → $DEST/ ==="
if ! rsync "${RSYNC_FLAGS[@]}" "$REPO/" "$DEST/"; then
    echo "✗ rsync failed (see above)" >&2
    exit 1
fi

# ── Verify ─────────────────────────────────────────────────────
if diff -rq --exclude=.git --exclude=README.md "$REPO" "$DEST" >/dev/null; then
    echo "✓ verified in sync (diff clean)"
else
    echo "✗ sync finished but diff is NOT clean — investigate:"
    diff -rq --exclude=.git --exclude=README.md "$REPO" "$DEST" | sed 's/^/    /'
    exit 1
fi

echo "✓ installed: $DEST (version: $VERSION)"
if [[ -n "$(git -C "$REPO" tag -l 2>/dev/null)" ]]; then
    echo "  git tags in repo: $(git -C "$REPO" tag -l | tr '\n' ' ')"
fi
