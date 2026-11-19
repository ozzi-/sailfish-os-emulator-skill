#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# build-deps.sh — One-time host dependencies for the Sailfish SDK
# Run: sudo bash build-deps.sh [--with-docker]
#
# Installs what the Sailfish SDK needs that isn't in the installer:
#   - virtualbox        (required for the Sailfish OS Emulator)
#   - libcrypt.so.1     (glibc distros: SDK links to libcrypt.so.1)
#   - 32-bit toolchain  (required to build the guest input tools — SETUP.md §2.5)
#   - docker            (OPTIONAL, opt-in: faster build engine than VirtualBox)
#
# Distro-aware: pacman (Arch), apt (Debian/Ubuntu), dnf/yum (Fedora).
# Idempotent — safe to re-run.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

WITH_DOCKER=0
for arg in "$@"; do
    case "$arg" in
        --with-docker) WITH_DOCKER=1 ;;
        -h|--help)
            echo "Usage: sudo bash build-deps.sh [--with-docker]"
            echo "  --with-docker  Also install Docker (optional, faster build engine)."
            echo "                 WARNING: this adds the user to the 'docker' group,"
            echo "                 which is functionally ROOT on the host."
            exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

PK=""
if   command -v pacman &>/dev/null; then PK="pacman"
elif command -v apt    &>/dev/null; then PK="apt"
elif command -v dnf    &>/dev/null; then PK="dnf"
elif command -v yum    &>/dev/null; then PK="yum"
else echo "WARNING: no known package manager (pacman/apt/dnf/yum) found."; fi

install_pkg() { # $1 = package name
    local p="$1"
    case "$PK" in
        pacman) pacman -S --noconfirm "$p" ;;
        apt)    apt-get update -qq && apt-get install -y "$p" ;;
        dnf)    dnf install -y "$p" ;;
        yum)    yum install -y "$p" ;;
        *)      echo "  ? cannot auto-install $p with package manager '$PK'" ;;
    esac
}

echo "=== Sailfish SDK host dependencies ==="
echo "  package manager: ${PK:-<none>}"
echo

# ── 1. VirtualBox (required for the emulator) ─────────────────
echo "[1/4] VirtualBox (required for the emulator)…"
if command -v virtualbox &>/dev/null; then
    echo "  ✓ virtualbox $(virtualbox --version)"
else
    install_pkg "virtualbox"
    echo "  ✓ virtualbox installed"
fi

# Add your user to the vboxusers group (needed to run VirtualBox VMs)
if ! groups | grep -qw vboxusers; then
    echo "  → Adding $USER to vboxusers group (re-login required)…"
    usermod -aG vboxusers "$USER" 2>/dev/null || echo "  (vboxusers group not present — ok)"
fi

# ── 2. libcrypt.so.1 (glibc distros need the compat shim) ─────
echo "[2/4] libcrypt.so.1 (SDK runtime dependency)…"
if ldconfig -p 2>/dev/null | grep -q libcrypt.so.1; then
    echo "  ✓ libcrypt.so.1 present"
else
    case "$PK" in
        pacman) install_pkg "libxcrypt-compat" ;;
        apt)    install_pkg "libxcrypt-compat" ;;
        dnf|yum) echo "  ? libcrypt.so.1 not found — install your distro's provider."
                 echo "    (Most Fedora/RHEL ≥ 8 systems ship it in glibc; if it is"
                 echo "     truly missing, search your repo for a 'libxcrypt-compat'"
                 echo "     or equivalent package.)" ;;
        *)      echo "  ? install a libcrypt.so.1 provider for your distro" ;;
    esac
fi

# ── 3. 32-bit toolchain (needed to build the guest input tools) ─
echo "[3/4] 32-bit (i686) toolchain for the guest input tools …"
proof32() { # compiles a 32-bit hello-world as a proof
    local c=/tmp/.sf32test.c b=/tmp/.sf32test
    printf 'int main(){return 0;}\n' > "$c" && gcc -m32 -o "$b" "$c" 2>/dev/null
    local rc=$?
    rm -f "$c" "$b"
    return $rc
}
if proof32; then
    echo "  ✓ 32-bit compilation works"
else
    case "$PK" in
        pacman) install_pkg "gcc-multilib" ;;
        apt)    apt-get update -qq && apt-get install -y gcc-multilib libc6-dev-i386 ;;
        dnf)    dnf install -y gcc32 glibc-devel.i686 ;;
        yum)    yum install -y gcc32 glibc-devel.i686 ;;
        *)      echo "  ? install the 32-bit gcc toolchain for your distro" ;;
    esac
    if proof32; then
        echo "  ✓ 32-bit compilation works"
    else
        echo "  ✗ 32-bit compilation STILL failing — SETUP.md §2.5 (input tools)"
        echo "    will not work until a 32-bit gcc + multilib headers are installed."
    fi
fi

# ── 4. Docker (OPTIONAL — only with --with-docker) ────────────
echo "[4/4] Docker (optional build engine)…"
DOCKER_PKG="docker"
[[ "$PK" == "apt" ]] && DOCKER_PKG="docker.io"
if command -v docker &>/dev/null; then
    echo "  ✓ docker $(docker --version 2>/dev/null | head -1)"
    if ! groups | grep -qw docker; then
        if [[ $WITH_DOCKER -eq 1 ]]; then
            echo "  → Adding $USER to docker group (re-login required)…"
            echo "    ⚠ docker group ≈ ROOT on the host (a container can mount"
            echo "      the host filesystem). Only do this if you intend to use it."
            usermod -aG docker "$USER" 2>/dev/null || true
        else
            echo "  (not in docker group; pass --with-docker to add it)"
        fi
    fi
elif [[ $WITH_DOCKER -eq 1 ]]; then
    install_pkg "$DOCKER_PKG"
    echo "  → Adding $USER to docker group (re-login required)…"
    echo "    ⚠ docker group ≈ ROOT on the host (a container can mount"
    echo "      the host filesystem). Only do this if you intend to use it."
    usermod -aG docker "$USER" 2>/dev/null || true
else
    echo "  — skipped (VirtualBox build engine works fine without Docker)"
    echo "    (opt-in: re-run with --with-docker; note docker group ≈ root)"
fi

# ── Verify ────────────────────────────────────────────────────
echo
echo "=== Verification ==="
echo "  virtualbox : $(virtualbox --version 2>/dev/null || echo 'NOT FOUND')"
echo "  libcrypt   : $(ldconfig -p 2>/dev/null | grep -m1 libcrypt.so.1 || echo 'not in ldconfig (may be fine on your distro)')"
if proof32; then echo "  32-bit gcc : OK"; else echo "  32-bit gcc : NOT WORKING (see above)"; fi
echo "  docker     : $(docker --version 2>/dev/null | head -1 || echo 'not installed (ok)')"
echo "  KVM        : $(ls /dev/kvm &>/dev/null && echo available || echo 'not available (ok — SDK uses VirtualBox)')"
echo
echo "=== Done ==="
echo "Next step: bash setup-sdk.sh"
