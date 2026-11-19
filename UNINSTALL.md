# UNINSTALL — remove the whole stack, safely

Use `scripts/uninstall.sh` to remove everything this skill installed. It is
**dry-run by default**: it prints exactly what it *would* remove (with sizes)
and touches nothing. Nothing is deleted until you pass `--yes`.

```bash
cd <skill>/scripts

# 1. DRY-RUN — review the plan (no changes, no sudo needed):
bash uninstall.sh

# 2. EXECUTE the core removal (VMs + SDK + sfdk wrapper + installer):
sudo bash uninstall.sh --yes

# 3. (optional) also remove the distro packages and the skill directory:
sudo bash uninstall.sh --yes --with-packages --with-skill
```

Idempotent: every step skips cleanly when already absent, so it is safe to
re-run at any point (including after a partial previous run).

## What gets removed

| Step | Item | Notes |
|---|---|---|
| 1 | Stop the two SFOS VMs | `poweroff` only if running (timeout-wrapped) |
| 2 | Unregister + delete VMs **`SailfishOS-*`** and **`Sailfish SDK Build Engine`** | `unregistervm --delete` removes VM config AND disk images. **Strict name matching — no other VM on the host is ever touched** (SECURITY.md §2.5 / S-8). The script prints every non-matching VM it *skips* as proof. |
| 3 | `~/SailfishOS` (≈ 9 GB) | SDK install. Refused unless it looks like an SDK (has `bin/sfdk`, `vmshare/`, `mersdk/`, or `emulator/`). Override with `SDK_INSTALL_DIR=/correct/path`. |
| 4 | `~/.local/bin/sfdk` | **Only if** the wrapper file references the SDK dir — a foreign `sfdk` is left alone. |
| 5 | `~/Downloads/SailfishSDK-*.run` | the installer download |
| 6 | *(opt-in `--with-packages`)* | distro packages this skill installed: `virtualbox`, `libxcrypt-compat`, 32-bit toolchain (`gcc-multilib` on Arch; `gcc32`/`glibc-devel.i686` on Fedora; `libc6-dev-i386` on Debian/Ubuntu). Distro-aware (`pacman -Rns` / `apt-get remove --purge` / `dnf remove`). **Docker is never touched** — it is opt-in user infrastructure. |
| 7 | *(opt-in `--with-skill`)* | `~/.lmstudio/skills/sailfish-os` |

After executing, the script self-verifies (no SFOS VMs registered, SDK dir
gone, wrapper gone) and exits non-zero if anything remains.

## What is NOT touched

- Other VirtualBox VMs (e.g. a personal desktop VM) — see the skip lines.
- `~/.config/VirtualBox` (shared registry — `unregistervm` only removes the
  two VM entries, not your other machines' configs).
- Your files, project sources, RPMs you built elsewhere.
- Docker (even if `--with-packages` is given).

## Manual leftovers (optional cleanup)

```bash
# vboxusers group membership (you can leave this; it grants no privilege
# without VirtualBox installed):
sudo gpasswd -d "$USER" vboxusers

# DKMS leftovers, if any remain after package removal:
sudo dkms status | grep vbox
sudo dkms remove vboxhost --all

# VirtualBox runtime dirs (only if you removed the packages and want the
# last crumbs gone — contains no VM data after unregistervm --delete):
rm -rf ~/.vboxclient
```

## Reinstalling afterwards

Just follow `SETUP.md` from the top — it is idempotent and detects what is
already present. Everything (VMs, SDK, input pipeline, netlock) comes back
fresh; the guest is back at the SDK snapshot state, so re-apply SETUP.md
§2.4 (resolution) and §2.5 (input pipeline) as usual.
