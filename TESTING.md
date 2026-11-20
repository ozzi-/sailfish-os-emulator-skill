# TESTING — verify the UI on the emulator (agent's job, before any human)

**Goal:** by the time a human looks at the app, the agent has already
confirmed the UI renders correctly, controls are where expected, and basic
interactions (tap, scroll) work. This catches most issues with zero phone
round-trips.

## Concurrency (read first — the emulator is SHARED)

The emulator + build engine are ONE pair of VMs shared by **every** Bionic
session on this host, and the input pipeline is a single global channel
(`/tmp/vboxfake.pos` + FIFO + `vts`, no per-caller isolation). Two sessions
interleaving taps/screenshots corrupt **both** verifications; `deploy.sh` and
input-setup also kill running apps. So:

```bash
bash scripts/lock.sh hold 30    # BEFORE the loop (30 min auto-expire)
# … deploy, tap, screenshot, verify, iterate …
bash scripts/lock.sh release   # AFTER the loop (or let it expire)
```

- `tap.sh` / `swipe.sh` / `deploy.sh` / `apply-input.sh` **refuse to run**
  without the lock (exit 75) — if you see that, another session is driving
  the pipeline: `bash scripts/lock.sh status`, then `lock.sh wait 60` (or
  poll), then retry.
- Read-only ops (`screenshotpng`, `journalctl`) work anytime, but do NOT
  **interpret** a screenshot taken while another session holds the lock.
- If the hold expires mid-loop, just re-`hold` before the next guarded op.

## Verification loop (per feature/iteration)

0. **Hold the pipeline lock** (see Concurrency above).
1. **Build + deploy + launch** (`deploy.sh --launch --screenshot`) → screenshot.
   NOTE: App starts in background (behind home screen). Swipe up to unlock if
   locked, then tap the app icon or use `tap.sh` to interact.
2. **Layout check** (screenshot, eyeball + PIL):
   - all expected elements present (headers, buttons, rows, labels);
   - nothing cut off / overlapping;
   - text readable (not empty, not `undefined`/`NaN`);
   - page not blank (blank = QML failed to instantiate → QML-GOTCHAS.md).
3. **Interaction check** — tap each control added/changed; screenshot after
   each tap; verify the expected state change (counter, page, dialog,
   switch state). Swipe lists to check scrolling.
4. **Log check** — `tail -50 /tmp/<app>.log`; look for QML warnings,
   JS errors, `ReferenceError`. Also grep the Wayland touch trace to prove
   the tap arrived at the right coordinates:
   `grep -E "wl_touch.*\.(down|motion|up)" /tmp/<app>.log | tail`
   ⚠ **If `/tmp/<app>.log` is empty or stale, check the journal instead:**
   `journalctl | grep <app> | tail -50`. When the session manager (sessiond)
   adopts the launch, the app's stdout/stderr go to a socket, not your file
   — the journal is then the only log. Also check for stray duplicates:
   `pgrep <app>` may show multiple instances (manual launch + deploy.sh +
   sessiond relaunch); the visible one and the input-receiving one can differ.
   `pkill -9 <app>` and relaunch via `deploy.sh` before judging.
5. **Report** to the human: what was verified, screenshots, issues found &
   fixed. **Release the lock** (`bash scripts/lock.sh release`). Only then
   hand off for device acceptance (if in scope).

## Commands

```bash
K="${SSH_KEY:-$HOME/SailfishOS/vmshare/ssh/private_keys/sdk}"
S() { ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 "$@"; }
VM="<emulator vm>"

# Screenshot (full framebuffer, 1088×2260 phone default):
VBoxManage controlvm "$VM" screenshotpng shots/<name>.png

# Tap / swipe (SCREEN_W/SCREEN_H env if your resolution differs):
bash <skill>/scripts/tap.sh X Y
bash <skill>/scripts/swipe.sh X0 Y0 X1 Y1 [STEPS]

> **Right after boot the screen is locked** (black, no wallpaper — that is
> the LOCK SCREEN, not a resolution failure). Unlock with a swipe up before
> interacting: `bash scripts/swipe.sh 544 2050 544 150 28` (1088×2260 standard).

# App log / running check / kill:
S 'tail -50 /tmp/<app>.log'
S 'journalctl | grep <app> | tail -50'   # authoritative when the log file is empty/stale
S 'pgrep <app>'
S 'pkill -9 <app>'

# Pixel-level checks (host, Python + Pillow):
python3 - <<'EOF'
from PIL import Image
img = Image.open("shots/after.png")          # (1088, 2260) standard
print(img.size)
print("pixel:", img.getpixel((544, 1130)))    # center of 1088x2260 standard
img.crop((100, 300, 700, 500)).save("shots/crop.png")   # zoom a region
EOF
```

## Aiming at controls

- The app renders **fullscreen**; screenshots are 1:1 with screen pixels.
- Find the control's pixel center in the screenshot (crop + zoom with PIL,
  or look for the label region), then `tap.sh X Y`. Accuracy is sub-pixel —
  no calibration needed.
- Landmarks (standard 1088×2260 phone-parity): status bar y≈0..60; center
  (544, 1130); bottom nav y≈2200..2260.
  (Fallback 1024×768: status bar y≈0..45; center (512, 384); bottom nav
  y≈720..768.)

## What the emulator CANNOT verify (needs a real device)

- Hardware features: camera, GPS, NFC, Bluetooth, sensors.
- Device-specific OS version behavior (emulator is the SDK's SFOS version,
  e.g. 5.1.x; a device may run a different minor).
- Performance under real hardware load.
- Notifications, background behavior, suspend/resume lifecycle.
- Physical display traits (notches, actual touch latency).

## What the emulator CAN verify (often assumed it can't)

- Layout, rendering, text, colors — pixel-exact via screenshot.
- Tap targets, button behavior, navigation, dialogs, lists, scrolling.
- Network calls (internet + host loopback — see NETWORKING.md).
- C++/QML runtime errors, crashes, JS exceptions (app log).
