#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# setup-sdk.sh — Download and install the Sailfish SDK
# Run:  bash setup-sdk.sh            (interactive, graphical)
# Run:  bash setup-sdk.sh --headless (no GUI, uses Docker build engine)
# Run:  bash setup-sdk.sh --vbox     (no GUI, uses VirtualBox build engine)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SDK_VERSION="3.13.5"
SDK_BASE_URL="https://releases.sailfishos.org/sdk/installers/${SDK_VERSION}"
INSTALLER_ONLINE="SailfishSDK-${SDK_VERSION}-linux64-online.run"
INSTALLER_OFFLINE="SailfishSDK-${SDK_VERSION}-linux64-offline.run"
INSTALL_DIR="${SDK_INSTALL_DIR:-$HOME/SailfishOS}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"

# ── Parse flags ────────────────────────────────────────────────
MODE="interactive"   # interactive | headless-docker | headless-vbox
OFFLINE=0

for arg in "$@"; do
    case "$arg" in
        --headless) MODE="headless-docker" ;;
        --vbox)     MODE="headless-vbox"   ;;
        --offline)  OFFLINE=1              ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--headless|--vbox] [--offline]

  --headless   Unattended install, Docker build engine
  --vbox       Unattended install, VirtualBox build engine
  --offline    Use the offline installer (2.3 GB, no internet needed during install)

Environment overrides:
  SDK_INSTALL_DIR   Where to install  (default: ~/SailfishOS)
  DOWNLOAD_DIR      Where to download (default: ~/Downloads)
  SKIP_HASH_CHECK   Set to 1 to skip the installer SHA-256 check (DANGEROUS)
EOF
            exit 0
            ;;
    esac
done

# ── Check prerequisites ───────────────────────────────────────
echo "=== Sailfish SDK ${SDK_VERSION} Setup ==="
echo

# virtualbox is required for the emulator
if ! command -v virtualbox &>/dev/null; then
    echo "ERROR: virtualbox not found."
    echo "  Run first:  sudo bash build-deps.sh"
    exit 1
fi
echo "  ✓ virtualbox $(virtualbox --version 2>/dev/null)"

# libxcrypt-compat (Arch-specific)
if ! ldconfig -p | grep -q libcrypt.so.1; then
    echo "WARNING: libcrypt.so.1 not found."
    echo "  The SDK may fail to start. Run:  sudo pacman -S libxcrypt-compat"
fi

# ── Download the installer ────────────────────────────────────
mkdir -p "$DOWNLOAD_DIR"
INSTALLER="$DOWNLOAD_DIR/$([[ $OFFLINE == 1 ]] && echo "$INSTALLER_OFFLINE" || echo "$INSTALLER_ONLINE")"

if [[ -f "$INSTALLER" ]]; then
    echo "  ✓ Installer already exists: $INSTALLER"
else
    URL="$SDK_BASE_URL/$([[ $OFFLINE == 1 ]] && echo "$INSTALLER_OFFLINE" || echo "$INSTALLER_ONLINE")"
    SIZE="$([[ $OFFLINE == 1 ]] && echo "2.3 GB" || echo "29 MB")"
    echo "  ↓ Downloading ($SIZE)…"
    echo "    $URL"

    if command -v wget &>/dev/null; then
        wget -O "$INSTALLER" "$URL"
    elif command -v curl &>/dev/null; then
        curl -L -o "$INSTALLER" "$URL"
    else
        echo "ERROR: Need wget or curl to download."
        exit 1
    fi

    chmod +x "$INSTALLER"
    echo "  ✓ Downloaded: $INSTALLER"
fi

# ── Verify checksum (online installer) ────────────────────────
if [[ $OFFLINE == 0 ]]; then
    if [[ "${SKIP_HASH_CHECK:-0}" == "1" ]]; then
        echo "  ⚠ SKIP_HASH_CHECK=1 — installer hash NOT verified (explicit opt-out)"
    else
        EXPECTED_SHA256="1b5703da664a05743ffa93e68cff874f17f21076358adeb85145bd62bf0ddb86"
        ACTUAL_SHA256=$(sha256sum "$INSTALLER" | awk '{print $1}')
        if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
            echo "✗ ERROR: installer SHA-256 MISMATCH — refusing to run."
            echo "  expected: $EXPECTED_SHA256"
            echo "  actual:   $ACTUAL_SHA256"
            echo "  The file may be corrupt, tampered with, or a different build."
            echo "  Delete it and re-download from releases.sailfishos.org."
            echo "  If you KNOW this exact file is correct (e.g. you re-signed it),"
            echo "  re-run with SKIP_HASH_CHECK=1."
            exit 1
        else
            echo "  ✓ SHA-256 verified"
        fi
    fi
fi

# ── Run the installer ─────────────────────────────────────────
echo
echo "=== Running installer ==="
echo "  install dir : $INSTALL_DIR"
echo "  mode        : $MODE"
echo

cd "$DOWNLOAD_DIR"

case "$MODE" in
    interactive)
        # Graphical installer — user clicks through the wizard
        echo "  Opening graphical installer…"
        echo "  Click through the setup wizard. Defaults are fine."
        echo "  The SDK will install to: $INSTALL_DIR"
        echo
        ./"$INSTALLER"
        ;;
    headless-docker)
        echo "  Unattended install (Docker build engine)…"
        QT_QPA_PLATFORM=minimal ./"$INSTALLER" \
            non-interactive=1 \
            accept-licenses=1 \
            build-engine-type=docker \
            --verbose
        ;;
    headless-vbox)
        echo "  Unattended install (VirtualBox build engine)…"
        QT_QPA_PLATFORM=minimal ./"$INSTALLER" \
            non-interactive=1 \
            accept-licenses=1 \
            build-engine-type=vbox \
            --verbose
        ;;
esac

# ── Post-install setup ────────────────────────────────────────
echo
echo "=== Post-install setup ==="

SFDK="$INSTALL_DIR/bin/sfdk"

if [[ -f "$SFDK" ]]; then
    echo "  ✓ sfdk found: $SFDK"

    # Create a wrapper in ~/.local/bin
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/sfdk" <<WRAPPER
#!/bin/sh
exec "$SFDK" "\$@"
WRAPPER
    chmod +x "$HOME/.local/bin/sfdk"
    echo "  ✓ Wrapper created: ~/.local/bin/sfdk"

    # Verify ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo "  ⚠ ~/.local/bin is not in your PATH."
        echo "    Add to ~/.bashrc or ~/.zshrc:"
        echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi

    # Show version
    if "$SFDK" --version &>/dev/null; then
        echo "  ✓ sfdk version: $("$SFDK" --version 2>&1 | head -1)"
    fi
else
    echo "  ⚠ sfdk not found at $SFDK — the SDK may not have installed correctly."
    echo "    Check:  ls -la $INSTALL_DIR/bin/"
fi

# ── Summary ───────────────────────────────────────────────────
echo
echo "=== Done ==="
echo
echo "Next steps:"
echo "  1. Re-login (or open a new terminal) to pick up PATH and group changes"
echo "  2. Verify:     sfdk --help"
echo "  3. Start the emulator (first time downloads components):"
echo "       sfdk emulator start"
echo "  4. List devices:"
echo "       sfdk device list"
echo "  5. Test a command in the emulator:"
echo "       sfdk emulator exec 'uname -a'"
echo
echo "  See SETUP.md (this skill) for the full pipeline:"
echo "  build → deploy → launch → tap/screenshot-test → hand to the user."
