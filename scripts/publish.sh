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
#   4. tag + push v<version> from the SKILL.md front matter (skipped when
#      the version is unchanged — that tag already exists)
#
# Rationale: a broken skill shipped to other Bionic users is worse than
# no release at all. The suite is strict — no WARN tier — so "green"
# means the pipeline was verified end-to-end a few seconds ago.
# ═════════════════════════════════════════════════════════════
set -u
set -o pipefail   # `git push … | sed` must not mask a failed push as success

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

# ── 4. Tag the release ─────────────────────────────────────────
# version: lives in the SKILL.md front matter (Bionic ignores the field;
# it is the single machine-readable version for tag + install reporting).
VERSION="$(sed -n 's/^version:[[:space:]]*//p' SKILL.md 2>/dev/null | head -n1 | tr -d '"')"
TAG="v${VERSION}"

if [[ -z "$VERSION" ]]; then
    echo
    echo "  ⚠ no version: line in SKILL.md front matter — pushed without a tag."
    echo "    Add 'version: X.Y.Z' to SKILL.md to cut versioned releases."
    exit 0
fi

# Remote already has this tag → release unchanged, nothing to do.
if git ls-remote --tags origin "$TAG" 2>/dev/null | grep -q "refs/tags/$TAG"; then
    echo
    echo "  ✓ tag $TAG already on remote — release unchanged."
    echo "    To cut a new release, bump 'version:' in SKILL.md first."
    exit 0
fi

# Local tag exists but never made it to the remote → push it as-is.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    if git push origin "refs/tags/$TAG" 2>&1 | sed 's/^/  /'; then
        echo "  ✓ pushed existing local tag $TAG"
    else
        echo "  ✗ pushing existing tag failed (commit push succeeded) — fix manually:"
        echo "      git push origin $TAG"
        exit 1
    fi
    exit 0
fi

# New version → create annotated tag, then push it.
if git tag -a "$TAG" -m "Release $TAG" \
   && git push origin "refs/tags/$TAG" 2>&1 | sed 's/^/  /'; then
    echo "  ✓ tagged & pushed $TAG"
else
    echo "  ✗ tagging failed (commit push succeeded — fix the tag manually):"
    echo "      git tag -a $TAG -m \"Release $TAG\" && git push origin $TAG"
    exit 1
fi
