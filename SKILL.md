---
name: sailfish-os
display-name: Sailfish OS
description: "Sailfish OS emulator pipeline: install the SDK, build & deploy
  Harbour apps, and tap/swipe/screenshot to verify UI. Use for any Sailfish OS
  app work."
---

# Sailfish OS — Build, Deploy, Test on the SDK Emulator

This skill turns the machine into a full **Sailfish OS app lab**: an LLM agent
can install the SDK once, then for any app — build it, deploy it to the
emulator, **tap/swipe it with pixel-accurate input**, take screenshots, read
logs, and verify the UI — without any physical phone or human in the loop.

## What this enables

- **Build**: `sfdk build` compiles the app on the SDK build-engine VM (Qt 5.6, i486).
- **Deploy**: RPM → emulator VM (SSH), sailjaild permissions granted, app launched
  in a proper sailjail sandbox (fullscreen).
- **Test**: `tap.sh X Y` / `swipe.sh X0 Y0 X1 Y1` inject real touch events
  (verified sub-pixel accurate); `screenshotpng` captures the exact framebuffer;
  app logs + Wayland touch traces confirm what the app received.
- **Network**: emulator has internet access (LAN blocked by blackhole routes — see SECURITY.md §2).

## Files in this skill

| Path | Purpose |
|---|---|
| `SETUP.md` | Fresh-machine install, idempotent & re-runnable (read this first) |
| `PIPELINE.md` | Build → deploy → launch → stop/uninstall (one command or manual) |
| `INPUT.md` | Verified tap/swipe recipes, coordinate math, traps, debugging |
| `NETWORKING.md` | Emulator networking: topology, lockdown, port forwards |
| `SECURITY.md` | Threat model, netlock, sandbox, input security, ops checklist |
| `UNINSTALL.md` | Safe removal of the whole stack (dry-run by default) |
| `TESTING.md` | UI verification workflow: screenshots, PIL, logs, phone-only items |
| `QML-GOTCHAS.md` | Qt 5.6 / Silica pitfalls that cause white screens & dead taps |
| `scripts/` | `build-deps.sh`, `setup-sdk.sh`, `deploy.sh`, `tap.sh`, `swipe.sh`, `uninstall.sh` |
| `tools/` | Guest input-pipeline sources: `vboxfake.c`, `vts.c`, `patch_isa_note.py`, `sf-input-setup.sh`, `vts-link.sh` |
| `apps/harbour-cpp/` | Minimal C++/QML test app (tap counter) to validate the pipeline |

## Quick start (agent)

1. **Is the pipeline already set up?** Run the check in `SETUP.md` §1.
   - Yes → skip to 3.
   - No → run `SETUP.md` steps (needs sudo for `build-deps.sh`; hand that to the
     user if there's no TTY).
2. **Bring the emulator up** (SETUP.md §2) and apply the input pipeline:
   `ssh -p 2223 -i $KEY root@127.0.0.1 '/usr/local/bin/sf-input-setup.sh'`
   (idempotent — always safe to run, esp. after a guest reboot).
3. **Build + deploy + launch** an app:
   `scripts/deploy.sh /path/to/harbour-<app> --launch --screenshot`
4. **Interact + verify**: `scripts/tap.sh X Y`, `scripts/swipe.sh …`,
   screenshot, inspect with PIL, read the app log (TESTING.md).
5. **Fix & repeat** until the UI looks right; only then hand to the human
   for device acceptance (if a device is in scope).
6. **Uninstall** (if the user asks to remove the whole stack):
   `bash scripts/uninstall.sh` (dry-run) → `--yes` to execute. UNINSTALL.md.

## Environment knobs (all optional, env vars)

| Var | Default | Meaning |
|---|---|---|
| `SCREEN_W` / `SCREEN_H` | `1088` / `2260` | Emulator resolution for tap math (match VBox framebuffer; phone-parity standard) |
| `VM_NAME` | auto-detected `SailfishOS*` VM | Emulator VM name |
| `SSH_PORT` | `2223` | Emulator SSH (SDK NAT forward "guestssh") |
| `SSH_KEY` | `~/SailfishOS/vmshare/ssh/private_keys/sdk` | SDK SSH key |
| `SFDK` | `~/.local/bin/sfdk` | SDK CLI |
| `SDK_INSTALL_DIR` | `~/SailfishOS` | Where the SDK lives |

## Key rules (learned the hard way — do not skip)

- **Tap position comes ONLY from the shim** (`/tmp/vboxfake.pos`); the evdev
  mouse only supplies the button. If taps all land at center, the position
  file wasn't updated. (INPUT.md)
- **Framebuffer must match VBox display** (1088x2260 phone default, verified).
  Mismatch = black screen. Set `65-emul-wayland-ui-scale.conf` to match.
  (SETUP.md)
- **`sailjail` is broken on SDK images** (missing profile). Use `invoker` for
  app launch. (deploy.sh handles this automatically.)
- **Network: internet-only.** LAN is blackholed. See SECURITY.md §2.
- **QML z-order**: a `Text` declared after a `MouseArea` eats its touches.
  Put the MouseArea last; use `onPressed`. (QML-GOTCHAS.md)
- **Restarting lipstick kills running apps** — relaunch after.
- **Keep exactly ONE vts daemon** — two race and input dies.
- After **any guest reboot**: re-run `sf-input-setup.sh` (one command).
