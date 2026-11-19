#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# uninstall.sh — Remove the Sailfish OS emulator skill stack
#
#   DRY-RUN BY DEFAULT. It prints exactly what it WOULD remove
#   (with sizes) and touches nothing. Add --yes to execute.
#
#   sudo bash uninstall.sh                # dry-run (plan + sizes)
#   sudo bash uninstall.sh --yes          # execute
#   sudo bash uninstall.sh --with-packages      # also remove distro packages
#   sudo bash uninstall.sh --with-skill         # also remove the skill dir
#   bash uninstall.sh --with-packages --with-skill --yes
#
#   What is removed (core):
#     1. VMs: "SailfishOS-*" (emulator) and "Sailfish SDK Build Engine"
#        (unregistervm --delete, disks included) — ONLY these name patterns;
#        no other VM on the host is ever touched (SECURITY.md S-8).
#     2. ~/SailfishOS            (SDK install: bin, mersdk/, emulator/, …)
#     3. ~/.local/bin/sfdk       (only if it execs into the SDK dir)
#     4. ~/Downloads/SailfishSDK-*.run   (installer download)
#
#   Optional:
#     --with-packages  distro packages this skill installed:
#        virtualbox, libcrypt-compat (libxcrypt-compat), 32-bit toolchain
#        (gcc-multilib / gcc32 + glibc-devel.i686 / libc6-dev-i386).
#        Docker is NEVER touched (it is opt-in user infrastructure).
#     --with-skill     ~/.lmstudio/skills/sailfish-os
#
#   What is NOT touched: other VMs, ~/.config/VirtualBox (shared registry —
#   unregistervm removes only the two VM entries), user files, Docker.
#
#   Idempotent: every step skips cleanly when already absent.
#   Guardrails: refuses to delete the SDK dir unless it looks like an SDK
#   (bin/sfdk or vmshare/ present); refuses to delete the sfdk wrapper
#   unless it references the SDK dir.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

# ── Flags ─────────────────────────────────────────────────────
EXECUTE=0
WITH_PACKAGES=0
WITH_SKILL=0
SDK_INSTALL_DIR="${SDK_INSTALL_DIR:-$HOME/SailfishOS}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
SKILL_DIR="$HOME/.lmstudio/skills/sailfish-os"
SFDK_WRAPPER="$HOME/.local/bin/sfdk"

for arg in "$@"; do
    case "$arg" in
        --yes)             EXECUTE=1 ;;
        --with-packages)   WITH_PACKAGES=1 ;;
        --with-skill)      WITH_SKILL=1 ;;
        --help|-h)
            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
    esac
done

[[ $EUID -eq 0 || $EXECUTE -eq 0 ]] || true   # dry-run works without sudo

say()  { printf '\033[1m== %s\033[0m\n' "$*"; }
plan() { printf '  [PLAN] %s\n' "$*"; }
skip() { printf '  [skip] %s\n' "$*"; }
run()  {  # run <description> <cmd...>
    local desc="$1"; shift
    if [[ $EXECUTE -eq 1 ]]; then
        printf '  > %s\n' "$*"
        "$@"
    else
        plan "$desc"
    fi
}

size() { du -sh "$1" 2>/dev/null | awk '{print " (" $1 ")"}' || true; }

if [[ $EXECUTE -eq 1 ]]; then MODE="EXECUTE"; else MODE="DRY-RUN (nothing will be changed)"; fi
say "Sailfish OS skill stack — $MODE"
echo "  SDK dir : $SDK_INSTALL_DIR"
echo "  Host    : $(uname -sr)"
echo

# ── 0. Sanity: does this even look like an installed stack? ───
if ! command -v VBoxManage &>/dev/null; then
    echo "  ? VirtualBox not found — nothing SDK-related to remove (dry-run ok)."
fi
if [[ -d "$SDK_INSTALL_DIR" ]]; then
    if [[ ! -f "$SDK_INSTALL_DIR/bin/sfdk" && ! -d "$SDK_INSTALL_DIR/vmshare" \
          && ! -d "$SDK_INSTALL_DIR/mersdk" && ! -d "$SDK_INSTALL_DIR/emulator" ]]; then
        echo "✗ REFUSING: $SDK_INSTALL_DIR exists but does NOT look like a Sailfish SDK"
        echo "  (no bin/sfdk, vmshare/, mersdk/, or emulator/ inside)."
        echo "  If it really is the SDK, re-run with SDK_INSTALL_DIR=/correct/path."
        exit 1
    fi
fi

# ── 1. Stop the two VMs (never any other VM) ──────────────────
say "1. Stop Sailfish VMs"
if command -v VBoxManage &>/dev/null; then
    while IFS= read -r vm; do
        [[ -n "$vm" ]] || continue
        is_sfos=0
        if [[ "$vm" == "Sailfish SDK Build Engine" || "$vm" =~ ^SailfishOS- ]]; then
            is_sfos=1
        fi
        if [[ $is_sfos -eq 1 ]]; then
            if VBoxManage showvminfo "$vm" 2>/dev/null | grep -qi 'state: running'; then
                run "stop VM: $vm" \
                    bash -c "timeout 90 VBoxManage controlvm '$vm' poweroff || true"
            else
                skip "VM not running: $vm"
            fi
        else
            skip "NOT a Sailfish VM — never touched: $vm"
        fi
    done < <(VBoxManage list vms 2>/dev/null | sed -n 's/^"\([^"]*\)".*/\1/p')
else
    skip "VBoxManage not found — nothing to stop"
fi
echo

# ── 2. Unregister + delete the two VMs (disks included) ───────
say "2. Unregister + delete Sailfish VMs (unregistervm --delete)"
if command -v VBoxManage &>/dev/null; then
    found=0
    while IFS= read -r vm; do
        [[ -n "$vm" ]] || continue
        if [[ "$vm" == "Sailfish SDK Build Engine" || "$vm" =~ ^SailfishOS- ]]; then
            found=1
            run "unregistervm --delete: $vm" \
                bash -c "VBoxManage unregistervm '$vm' --delete"
        fi
    done < <(VBoxManage list vms 2>/dev/null | sed -n 's/^"\([^"]*\)".*/\1/p')
    [[ $found -eq 1 ]] || skip "no Sailfish VMs registered"
else
    skip "VBoxManage not found"
fi
echo

# ── 3. SDK install dir ─────────────────────────────────────────
say "3. Remove SDK install directory"
if [[ -d "$SDK_INSTALL_DIR" ]]; then
    run "rm -rf $SDK_INSTALL_DIR$(size "$SDK_INSTALL_DIR")" \
        rm -rf "$SDK_INSTALL_DIR"
else
    skip "absent: $SDK_INSTALL_DIR"
fi
echo

# ── 4. sfdk wrapper (only if it points at THIS SDK) ───────────
say "4. Remove ~/.local/bin/sfdk wrapper"
if [[ -f "$SFDK_WRAPPER" ]]; then
    if grep -Fq "$SDK_INSTALL_DIR" "$SFDK_WRAPPER"; then
        run "rm $SFDK_WRAPPER (references $SDK_INSTALL_DIR)" rm -f "$SFDK_WRAPPER"
    else
        skip "$SFDK_WRAPPER does NOT reference $SDK_INSTALL_DIR — left alone"
    fi
else
    skip "absent: $SFDK_WRAPPER"
fi
echo

# ── 5. Installer download ─────────────────────────────────────
say "5. Remove SDK installer download"
removed_installer=0
for f in "$DOWNLOAD_DIR"/SailfishSDK-*.run; do
    [[ -f "$f" ]] || continue
    removed_installer=1
    run "rm $f$(size "$f")" rm -f "$f"
done
[[ $removed_installer -eq 1 ]] || skip "no SailfishSDK-*.run in $DOWNLOAD_DIR"
echo

# ── 6. (optional) distro packages ──────────────────────────────
if [[ $WITH_PACKAGES -eq 1 ]]; then
    say "6. Remove distro packages (opt-in: --with-packages)"
    if [[ $EXECUTE -eq 1 && $EUID -ne 0 ]]; then
        echo "  (package removal needs root — re-run with sudo)"
        exit 1
    fi
    PK=""
    if   command -v pacman &>/dev/null; then PK="pacman"
    elif command -v apt    &>/dev/null; then PK="apt"
    elif command -v dnf    &>/dev/null; then PK="dnf"
    elif command -v yum    &>/dev/null; then PK="yum"
    fi
    case "$PK" in
        pacman)
            run "pacman -Rns virtualbox libxcrypt-compat gcc-multilib (orphaned deps included)" \
                bash -c "sudo pacman -Rns --noconfirm virtualbox libxcrypt-compat gcc-multilib || true"
            echo "  note: if DKMS leftovers remain: sudo dkms remove vboxhost --all"
            ;;
        apt)
            run "apt-get remove --purge virtualbox libxcrypt-compat gcc-multilib libc6-dev-i386 (+ autoremove)" \
                bash -c "sudo apt-get update -qq; sudo apt-get remove -y --purge virtualbox libxcrypt-compat gcc-multilib libc6-dev-i386; sudo apt-get autoremove -y"
            ;;
        dnf|yum)
            run "dnf remove virtualbox libxcrypt-compat gcc32 glibc-devel.i686" \
                bash -c "sudo dnf remove -y virtualbox libxcrypt-compat gcc32 glibc-devel.i686 || sudo yum remove -y virtualbox libxcrypt-compat gcc32 glibc-devel.i686"
            ;;
        *)
            echo "  ? no known package manager — remove manually:"
            echo "    virtualbox, libcrypt-compat (or equivalent), 32-bit toolchain"
            ;;
    esac
    echo "  Docker is NOT touched (opt-in user infrastructure)."
    echo "  Optional manual: remove your user from the 'vboxusers' group."
    echo
else
    say "6. Distro packages — SKIPPED (add --with-packages to include)"
    echo
fi

# ── 7. (optional) the skill directory ─────────────────────────
if [[ $WITH_SKILL -eq 1 ]]; then
    say "7. Remove skill directory (opt-in: --with-skill)"
    if [[ -d "$SKILL_DIR" ]]; then
        if [[ "$(cd "$(dirname "$0")" && pwd)" == *"$SKILL_DIR"* ]]; then
            echo "  ⚠ This script is running FROM $SKILL_DIR — deleting it now"
            echo "    is safe on Linux (open inodes persist), but the file disappears."
        fi
        run "rm -rf $SKILL_DIR$(size "$SKILL_DIR")" rm -rf "$SKILL_DIR"
    else
        skip "absent: $SKILL_DIR"
    fi
    echo
fi

# ── 8. Verification ───────────────────────────────────────────
if [[ $EXECUTE -eq 1 ]]; then
    say "Verification"
    fail=0
    if command -v VBoxManage &>/dev/null; then
        if VBoxManage list vms 2>/dev/null | grep -Eq 'SailfishOS-|Sailfish SDK Build Engine'; then
            echo "  ✗ Sailfish VMs still registered:"; VBoxManage list vms | grep -E 'Sailfish' ; fail=1
        else
            echo "  ✓ no Sailfish VMs registered"
        fi
    fi
    [[ -e "$SDK_INSTALL_DIR" ]] && { echo "  ✗ $SDK_INSTALL_DIR still exists"; fail=1; } \
                                || echo "  ✓ SDK dir gone"
    [[ -e "$SFDK_WRAPPER" ]]    && { echo "  ✗ $SFDK_WRAPPER still exists"; fail=1; } \
                                || echo "  ✓ sfdk wrapper gone"
    [[ $fail -eq 0 ]] && echo "=== Uninstall complete ===" || { echo "=== Uninstall INCOMPLETE — review above ==="; exit 1; }
else
    say "DRY-RUN complete — no changes were made."
    echo "  Re-run with --yes to execute. Add --with-packages / --with-skill"
    echo "  if you also want the distro packages / skill directory removed."
fi
