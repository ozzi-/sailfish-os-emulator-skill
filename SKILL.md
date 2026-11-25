---
name: sailfish-os
display-name: Sailfish OS
version: 0.1.1
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

- **Build**: `sfdk build` compiles the app on the SDK build-engine VM (Qt 5.6, i486)
  for the emulator, or `build-phone.sh` (docker + mb2) for the **aarch64 phone RPM**.
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
| `HARNESS.md` | Local test ladder (QML compile check, geometry, D-Bus E2E) — no VM, no phone |
| `QML-GOTCHAS.md` | Qt 5.6 / Silica pitfalls that cause white screens & dead taps |
| `scripts/` | `build-deps.sh`, `setup-sdk.sh`, `deploy.sh` (emulator), `build-phone.sh` (aarch64 phone RPM), `tap.sh`, `swipe.sh`, `uninstall.sh`, `lock.sh`, `apply-input.sh`, `lib-lock.sh`, `lib-spec.sh`, `smoke.sh`, `publish.sh`, `sync-local.sh` (maintainer) |
| `tools/` | Guest input-pipeline sources: `vboxfake.c`, `vts.c`, `patch_isa_note.py`, `sf-input-setup.sh`, `vts-link.sh` |
| `apps/harbour-cpp/` | Minimal C++/QML test app (tap counter) to validate the pipeline |
| `apps/sfsmoke/` | Dedicated smoke-test canary (tap counter) — drives `smoke.sh` tier T2 |

## Quick start (agent)

1. **Is the pipeline already set up?** Run the check in `SETUP.md` §1.
   - Yes → skip to 3.
   - No → run `SETUP.md` steps (needs sudo for `build-deps.sh`; hand that to the
     user if there's no TTY).
2. **Bring the emulator up** (SETUP.md §2) and apply the input pipeline
   (guarded, idempotent — always safe, esp. after a guest reboot):
   `bash scripts/lock.sh hold 10 && bash scripts/apply-input.sh; bash scripts/lock.sh release`
3. **Acquire the pipeline lock** — the emulator is shared by ALL Bionic
   sessions on this host, one drives it at a time (TESTING.md, SECURITY.md §9):
   `bash scripts/lock.sh hold 30`   # 30 min auto-expire; `status` to inspect
4. **Build + deploy + launch** an app (guarded — refuses without the lock):
   `scripts/deploy.sh /path/to/harbour-<app> --launch --screenshot`
5. **Interact + verify**: `scripts/tap.sh X Y`, `scripts/swipe.sh …`,
   screenshot, inspect with PIL, read the app log (TESTING.md).
6. **Release the lock** when the workflow is done:
   `bash scripts/lock.sh release`
7. **Fix & repeat** (stay under the lock). Once the UI is verified on the
   emulator, build the **aarch64 phone RPM** for device acceptance:
   `bash scripts/build-phone.sh /path/to/harbour-<app>` → the human installs it on
   the phone (they own the phone; `build-phone.sh` prints the install commands).
   See PIPELINE.md §Phone build.
8. **Uninstall** (if the user asks to remove the whole stack):
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
| `SFOSSKILL_LOCK_FILE` | `/tmp/sfos-pipeline.lock` | Concurrency lock file (scripts/lock.sh) |
| `SFOSSKILL_NO_LOCK` | unset | `=1` bypasses the lock guard (breaks glass only) |

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
- **Pipeline lock is MANDATORY for mutating ops** (emulator + build engine
  are shared by every Bionic session on this host): `tap.sh`, `swipe.sh`,
  `deploy.sh`, `apply-input.sh` refuse to run without `scripts/lock.sh hold`
  (exit 75 = another session has it — wait & retry). Release after the
  workflow. Kernel flock → no stale locks. SECURITY.md §9.
- **QML z-order**: a `Text` declared after a `MouseArea` eats its touches.
  Put the MouseArea last; use `onPressed`. (QML-GOTCHAS.md)
- **Restarting lipstick kills running apps** — relaunch after.
- **Keep exactly ONE vts daemon** — two race and input dies.
- After **any guest reboot**: re-run `sf-input-setup.sh` (one command).
- **Before pushing skill changes: run `bash scripts/publish.sh`** — it runs the full
  smoke suite (`smoke.sh --all`: static + guest health + end-to-end canary)
  and refuses to push on any failure. Local iterations: `smoke.sh --fast`
  (no VMs needed).

## Maintainer workflow (skill repo)

- **Test**: `bash scripts/smoke.sh` (T0+T1), `--fast` (T0 only), `--all` (full).
- **Update the local Bionic install from the repo** (idempotent, safe to re-run):
  `bash scripts/sync-local.sh` — diff-only with `--check`, preview with `--dry-run`.
- **Release a version**: bump `version:` in this file's front matter → commit →
  `bash scripts/publish.sh` (full suite, push, then tag + push `v<version>`).
  Bump policy: patch = doc fixes, minor = new capability, major = breaking change.
- **Share/install on another machine**: hand over the repo URL — Bionic installs
  skills straight from a URL (`@Install Skill`); the format is the portable
  Agent Skills standard (also works in Claude Code / Codex).
