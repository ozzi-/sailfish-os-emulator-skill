# ═════════════════════════════════════════════════════════════
# lib-staging.sh — staging path contract (shared by deploy.sh + smoke.sh)
#
# Apps that live OUTSIDE the SDK "shared source" workspace are built from
# a clean copy under:
#
#     <shared-src>/.sfdk-staging/<basename>-<12-hex>
#
# where <12-hex> is the first 12 hex chars of sha256(canonical absolute
# path of the app dir).
#
# Why the hash suffix (incident, 2026-11): two concurrent Bionic sessions
# built apps from DIFFERENT folders that both happened to be named
# `repo`. With a basename-only staging path they shared one staging dir —
# one session's `rm -rf` + re-stage wiped the other's in-flight build tree
# mid-build → binary with missing QML resources, app died with exit 255.
#
# Properties:
#   * unique per SOURCE LOCATION — same basename under different parents
#     never collides;
#   * deterministic — the same app dir always maps to the same staging
#     dir, so rebuilds stay stable and smoke.sh can compute the identical
#     path to locate the RPM;
#   * short + readable — `<basename>-<12hex>` still tells you the app.
#
# Usage:  BUILD_DIR="$(sfos_staging_dir "$SHARED_SRC" "$APP_DIR")"
# ═════════════════════════════════════════════════════════════

sfos_staging_dir() {
    local ssrc="$1" appdir="$2" abs hash
    abs="$(cd "$appdir" && pwd -P)"
    hash="$(printf '%s' "$abs" | sha256sum | cut -c1-12)"
    printf '%s/.sfdk-staging/%s-%s' "$ssrc" "$(basename "$abs")" "$hash"
}
