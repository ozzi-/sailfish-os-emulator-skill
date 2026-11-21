#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════
# build-phone.sh — Build the aarch64 RPM for the PHONE (final acceptance)
#
# deploy.sh builds the i486 RPM for the EMULATOR (the fast agent verify loop).
# This is the OTHER target: a real aarch64 RPM to install on the phone. It runs
# the proven docker + mb2 recipe — the SDK image supplies the cross-compiler,
# so no aarch64 toolchain is needed on the host. It does NOT push to the phone
# (that needs the user's phone on the network); it produces the RPM and copies
# it to a known location for the user to install.
#
#   ./build-phone.sh /path/to/harbour-<app>
#   ./build-phone.sh /path/to/harbour-<app> --dry-run   # print the plan, don't run
#
# Requirements: docker running + the aarch64 SDK image pulled (or set
#   SFOSSDK_AARCH64_IMAGE). See PIPELINE.md §"Phone build (aarch64)".
#
# This does NOT take the pipeline lock: it only runs a docker build and never
# touches the shared emulator VM, so it is safe to run alongside a session
# that is driving the emulator.
#
# Environment overrides:
#   SFOSSDK_AARCH64_IMAGE  SDK image (default: coderus/…-aarch64:5.2.0.15)
#   SFOSSDK_PROJ_DIR       container build dir (default: /home/mersdk/proj)
#   SFOSSKILL_PHONE_OUT    RPM output dir (default: <app>/dist)
# ═════════════════════════════════════════════════════════════
set -euo pipefail

SFOSSDK_AARCH64_IMAGE="${SFOSSDK_AARCH64_IMAGE:-coderus/sailfishos-platform-sdk-aarch64:5.2.0.15}"
SFOSSDK_PROJ_DIR="${SFOSSDK_PROJ_DIR:-/home/mersdk/proj}"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-spec.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }
ok()   { echo "  ✓ $*"; }

# ── args ──────────────────────────────────────────────────────
APP_DIR=""; DRY_RUN=0; OUT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=1 ;;
        --out)      OUT_DIR="${2:?--out needs a dir}"; shift ;;
        -h|--help)  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         err "Unknown option: $1" ;;
        *)          APP_DIR="$1" ;;
    esac
    shift
done
[[ -n "$APP_DIR" && -d "$APP_DIR" ]] || err "Usage: $0 APP_DIR [--dry-run] [--out DIR]"
APP_DIR="$(cd "$APP_DIR" && pwd)"
OUT_DIR="${OUT_DIR:-${SFOSSKILL_PHONE_OUT:-$APP_DIR/dist}}"

# ── locate spec, resolve name + version ───────────────────────
spec_rel=$(cd "$APP_DIR" && find . -maxdepth 3 -name "harbour-*.spec" | head -1)
[[ -n "$spec_rel" ]] || err "No harbour-*.spec found under $APP_DIR"
SPEC_FILE="$APP_DIR/${spec_rel#./}"
APP_NAME=$(spec_app_name "$SPEC_FILE")
VER=$(spec_app_version "$SPEC_FILE"); [[ -n "$VER" ]] || VER="0.1.0"

info "App:      $APP_NAME"
info "Version:  $VER"
info "Image:    $SFOSSDK_AARCH64_IMAGE"
info "Output:   $OUT_DIR"

# ── staging layout (mb2 builds IN-PLACE; no %prep/%setup) ─────
# Required shape:   <STAGE>/rpm/<spec>   +   <STAGE>/<name>-<version>/…
# (the app's `rpm/` dir — spec + sources — is hoisted to the top of <STAGE>).
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sfos-phone.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
SRC_SUB="$STAGE/$APP_NAME-$VER"

do_stage() {
    mkdir -p "$SRC_SUB"
    tar -C "$APP_DIR" \
        --exclude=RPMS --exclude=.sfdk --exclude=.git --exclude=dist \
        --exclude=Makefile --exclude='qrc_*.cpp' \
        -cf - . | tar -C "$SRC_SUB" -xf -
    # Hoist rpm/ (spec + sources) to the top of the staging tree.
    [[ -d "$SRC_SUB/rpm" ]] || err "app has no rpm/ dir (expected <app>/rpm/harbour-*.spec)"
    if [[ -e "$STAGE/rpm" ]]; then rm -rf "$STAGE/rpm"; fi
    mv "$SRC_SUB/rpm" "$STAGE/rpm"
    # The container build user may not write host-owned dirs — open them up.
    chmod -R a+rwX "$STAGE" 2>/dev/null || true
}

do_build() {
    docker run --rm \
        -v "$STAGE":"$SFOSSDK_PROJ_DIR" \
        "$SFOSSDK_AARCH64_IMAGE" \
        bash -lc "cd $SFOSSDK_PROJ_DIR && mb2 build" 2>&1 \
        | tee /dev/tty | grep -iE "Wrote:|error:|Bad exit|fatal" || true
}

do_collect() {
    local rpm
    rpm=$(find "$STAGE/RPMS" -maxdepth 2 -name '*.aarch64.rpm' 2>/dev/null | head -1)
    [[ -n "$rpm" ]] || { echo; err "no aarch64 RPM produced under $STAGE/RPMS (see build output above)"; }
    mkdir -p "$OUT_DIR"
    cp "$rpm" "$OUT_DIR/"
    local out="$OUT_DIR/$(basename "$rpm")"
    echo
    ok "Phone RPM: $out"
    cat <<EOF
  ── Hand this to the user for final acceptance ──────────────────────────
  It is aarch64 (phone) — it will NOT run on the i486 emulator.
  1. Get it onto the phone, e.g.:  scp "$out"  defaultuser@<PHONE_IP>:~/
  2. On the phone:                devel-su rpm -i ~/$(basename "$out")
  (or: devel-su rpm -Uvh ~/$(basename "$out") to upgrade a previous build)
EOF
}

# ── run ───────────────────────────────────────────────────────
if [[ "$DRY_RUN" == 1 ]]; then
    echo "  DRY RUN — would execute:"
    echo "    stage:  tar -C $APP_DIR … | tar -C $SRC_SUB -xf - ; mv $SRC_SUB/rpm $STAGE/rpm"
    echo "    build:  docker run --rm -v $STAGE:$SFOSSDK_PROJ_DIR $SFOSSDK_AARCH64_IMAGE"
    echo "            bash -lc 'cd $SFOSSDK_PROJ_DIR && mb2 build'"
    echo "    collect: cp \$STAGE/RPMS/*.aarch64.rpm $OUT_DIR/"
    echo "  (nothing was built, docker was not touched)"
    exit 0
fi

command -v docker >/dev/null 2>&1 || err "docker not found (required for the aarch64 cross-build)"
# Image present? (user may be offline — fail with a clear, actionable message)
if ! docker image inspect "$SFOSSDK_AARCH64_IMAGE" >/dev/null 2>&1; then
    echo "ERROR: aarch64 SDK image not found: $SFOSSDK_AARCH64_IMAGE" >&2
    echo "  Pull it once (needs internet), or point SFOSSDK_AARCH64_IMAGE at an image you have:" >&2
    echo "    docker pull $SFOSSDK_AARCH64_IMAGE" >&2
    echo "    SFOSSDK_AARCH64_IMAGE=<image> $0 $APP_DIR" >&2
    exit 1
fi

do_stage
info "Building aarch64 RPM (mb2) … (this compiles for the phone; ~1–3 min)"
do_build
do_collect
