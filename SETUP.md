# SETUP — Fresh-machine install (idempotent, safe to re-run)

One-time, global to the machine, shared by all projects. Every step below is
safe to re-run when already done.

## 1. Check if already set up (run first)

```bash
K="${SSH_KEY:-$HOME/SailfishOS/vmshare/ssh/private_keys/sdk}"
VM=$(VBoxManage list vms 2>/dev/null | sed -n 's/^"\([^"]*SailfishOS[^"]*\)".*/\1/p' | head -1)

ok=1
VBoxManage list vms 2>/dev/null | grep -q "SailfishOS"          || ok=0   # emulator VM exists
VBoxManage list vms 2>/dev/null | grep -q "SDK Build Engine"    || ok=0   # build engine VM exists
[[ -x "${SFDK:-$HOME/.local/bin/sfdk}" ]]                       || ok=0   # SDK installed
[[ -f "$K" ]]                                                   || ok=0   # SDK SSH key
ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=3 \
    root@127.0.0.1 "test -x /usr/local/bin/vts" 2>/dev/null     || ok=0   # input tools deployed
[[ "$ok" == 1 ]] && echo "SETUP COMPLETE" || echo "SETUP INCOMPLETE — continue below"
```

If `SETUP COMPLETE`: skip to **§3** (bring up + input pipeline).

## 2. Install (only the missing pieces)

### 2.1 Host dependencies (needs sudo)

```bash
# From this skill's scripts/ directory:
sudo bash build-deps.sh
# Distro-aware (pacman/apt/dnf). Installs VirtualBox + libcrypt compat,
# optionally Docker. Add user to vboxusers/docker groups (re-login required).
# Verify:  lsmod | grep vbox   →  vboxnetflt, vboxnetadp, vboxdrv
# (DKMS autoinstall of ZFS may fail on bleeding-edge kernels — harmless, ignore.)
```

### 2.2 Sailfish SDK (downloads ~1 GB, creates both VMs)

```bash
bash setup-sdk.sh --headless     # unattended; Docker build engine
# or: bash setup-sdk.sh --vbox   # VirtualBox build engine
# Env: SDK_INSTALL_DIR (default ~/SailfishOS), DOWNLOAD_DIR
# The installer creates:
#   - "Sailfish SDK Build Engine" VM  (builds RPMs)
#   - "SailfishOS-<version>" VM       (the emulator)
# Verify:  ~/.local/bin/sfdk --version
```

### 2.3 Start both VMs

```bash
VBoxManage startvm "Sailfish SDK Build Engine" --type headless 2>/dev/null || true
VBoxManage startvm "$VM" --type headless 2>/dev/null || true
# Wait for emulator SSH (up to ~2 min):
for i in $(seq 1 60); do
    ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=3 \
        root@127.0.0.1 "true" 2>/dev/null && break
    sleep 2
done
```

### 2.4 Set the emulator resolution (VBox display AND guest compositor must match)

The screen only renders if the **VBox framebuffer** and the **guest compositor**
agree on the same size — a mismatch shows a **black screen** (this is why a
device-profile copy of the UI-scale conf, or a `sfdk emulator start` that
rewrites it, can leave the screen black). Pick a width that is a **multiple of
16** (720 / 1024 / 1088 / 1920 render clean): a non-aligned width (e.g. 1080 →
4320 B/row) makes vboxvideo's 64-byte-aligned pitch (4352) differ from the
compositor's (4320) → **diagonal-line corruption** across the whole screen.

- **Standard (recommended, VERIFIED working): phone-parity `1088×2260`.** Every
  script defaults to `SCREEN_W=1088 SCREEN_H=2260`. This is the phone resolution
  the UI is designed for and it renders cleanly (verified end-to-end). Use it.
- **Fallback `1024×768`:** the SDK image's out-of-box size. Use it only if you
  want a smaller screen or hit a rendering problem — then also set
  `SCREEN_W=1024 SCREEN_H=768` for all interactions.

> **A black screen right after boot is the LOCK SCREEN (no wallpaper), NOT a
> resolution failure.** Swipe up to unlock (TESTING.md) and the home screen
> renders. Only call it a failure if the home screen is *also* black.

```bash
# Standard phone resolution: W=1088; H=2260     (fallback: W=1024; H=768)
W=1088; H=2260
# 1. host video mode hint (persists in the VM config):
VBoxManage controlvm "$VM" setvideomodehint $W $H 32
# 2. guest UI scale conf:
ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 \
    "printf 'QT_QPA_EGLFS_WIDTH=$W\nQT_QPA_EGLFS_HEIGHT=$H\n' > /var/lib/environment/compositor/65-emul-wayland-ui-scale.conf"
# 3. REBOOT THE GUEST OS — a lipstick restart is NOT enough. The guest only
#    adopts the new mode on OS reboot:
ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 'reboot'
# (wait for SSH to come back)
# 4. verify:
ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 \
    'cat /sys/class/graphics/fb0/virtual_size'
# Expected: $W,$H   (standard: 1088,2260)
# NOTE: `sfdk emulator start` may rewrite the UI-scale conf from a device
# profile — re-check the conf after any SDK-managed start (see snapshot note below).
```

### 2.5 Deploy the input pipeline to the guest (one-time)

```bash
# From this skill's tools/ directory (host needs 32-bit gcc: e.g. `sudo pacman -S gcc-multilib` /
# `sudo apt install gcc-multilib`):
cd <skill>/tools
gcc -m32 -march=i686 -shared -fPIC -O2 -o libvboxfake.so vboxfake.c -ldl
gcc -m32 -march=i686 -O2 -o vts vts.c
python3 patch_isa_note.py libvboxfake.so   # zeroes the x86 ISA .note the 32-bit kernel rejects
python3 patch_isa_note.py vts

K="${SSH_KEY:-$HOME/SailfishOS/vmshare/ssh/private_keys/sdk}"
scp -P 2223 -i "$K" -o StrictHostKeyChecking=no libvboxfake.so root@127.0.0.1:/usr/local/lib/libvboxfake.so
scp -P 2223 -i "$K" -o StrictHostKeyChecking=no vts root@127.0.0.1:/usr/local/bin/vts
scp -P 2223 -i "$K" -o StrictHostKeyChecking=no sf-input-setup.sh vts-link.sh root@127.0.0.1:/usr/local/bin/
ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 \
    'chmod 755 /usr/local/bin/vts /usr/local/bin/sf-input-setup.sh /usr/local/bin/vts-link.sh'

# One-time: allow LD_PRELOAD on lipstick (setgid binaries ignore LD_PRELOAD).
# NOTE: this deliberately strips a privilege bit from a system binary — see
# SECURITY.md §5 for the trade-off.
ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 \
    'chmod g-s /usr/bin/lipstick 2>/dev/null || true'
```

Security notes for this section (details in **SECURITY.md**):
- `vts` only accepts `/tmp/vts.cmd` files that are **root-owned** (any other
  file is rejected and deleted) — input injection from unprivileged guest
  processes is impossible.
- The LD_PRELOAD shim runs inside `lipstick` (the compositor). It is small
  and only touches its two `/tmp` paths, but it IS custom code in a system
  process — review it before trusting the pipeline.

## 3. Bring up (every boot — idempotent, one command)

After any guest reboot (and safe mid-session):

```bash
ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes \
    root@127.0.0.1 '/usr/local/bin/sf-input-setup.sh'
```

It (re)applies the shim env, restarts exactly ONE vts daemon, relinks the
vts-mouse evdev device into the i8042 slot, restarts lipstick, and prints a
verification summary (vts procs = 1, link target, shim refs in lipstick ≥ 5).

## 4. Verify the full pipeline (optional but recommended)

```bash
cd <skill>
# Build + deploy + launch the test app (tap counter):
bash scripts/deploy.sh apps/harbour-cpp --launch --screenshot /tmp/verify-before.png
# Right after boot the screen is LOCKED (black, no wallpaper — normal):
bash scripts/swipe.sh 544 2050 544 150 28   # swipe up to unlock (1088x2260)
# Tap screen center (standard 1088x2260 -> 544,1130; recompute if you changed resolution):
CW=$(( ${SCREEN_W:-1088} / 2 )); CH=$(( ${SCREEN_H:-2260} / 2 ))
bash scripts/tap.sh "$CW" "$CH"
sleep 1
VBoxManage controlvm "$VM" screenshotpng /tmp/verify-after.png
# PASS = the "TAPS" counter incremented. (Screenshot size == SCREEN_W x SCREEN_H.)
```

> **Launch uses `invoker`, not `sailjail`.** On SDK images the `sailjail`
> binary is broken (missing the `disable-common.local` firejail profile), so
> `deploy.sh` launches apps via `invoker -s --type=silica-session` instead —
> same sailjaild sandbox + permissions, but the app starts **in the background**
> (behind the home screen). That is normal SFOS behaviour. Bring it forward with
> the app switcher (swipe up from the bottom edge) or relaunch; see TESTING.md.

> **Snapshot restore = clean reset.** `sfdk snapshot restore` (or a freshly
> created VM) wipes everything done in-guest: the resolution conf, the compiled
> `vts`/`libvboxfake.so`, the netlock service, and the input pipeline. After a
> restore, re-run **§2.4** (if you use a non-default resolution), **§2.5**,
> **§3**, and redeploy netlock (NETWORKING.md). The host-side VM config
> (videomodehint) survives the restore, so re-check `fb0` against the conf.

## Troubleshooting setup

| Symptom | Fix |
|---|---|
| `sfdk` missing | SDK not installed — §2.2. Or it's at a non-standard path: `export SFDK=...` |
| SSH 2223 refused | Emulator VM not running — §2.3. Check `VBoxManage list runningvms` |
| VM name differs | `VM_NAME_AUTODETECT` (deploy.sh) or set `VM_NAME` — name encodes SDK version |
| Diagonal-line corruption in screenshots | Width not 16-aligned — §2.4 |
| `CPU ISA level is lower than required` when guest execs a 32-bit binary | Re-run `patch_isa_note.py` on that binary |
| Taps don't register at all | `sf-input-setup.sh` again; check its verification output |
| `LD_PRELOAD` not in lipstick maps | `chmod g-s /usr/bin/lipstick`, then restart lipstick |
