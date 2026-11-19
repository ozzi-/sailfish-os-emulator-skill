# sailfish-os — Bionic Skill

A [Bionic](https://lmstudio.ai) (LM Studio desktop app) skill that lets an
LLM agent run a complete **Sailfish OS app lab** on a Linux desktop:

- **Build** Harbour apps on the Sailfish SDK build-engine VM (Qt 5.6 / i486)
- **Deploy** the RPM to the Sailfish OS emulator VM over SSH
- **Drive the UI programmatically** — pixel-accurate tap/swipe injection,
  screenshots, log inspection — no phone, no human in the loop
- **Internet-only networking** (LAN blackholed) and a hardened input pipeline

Verified end-to-end at **1088×2260** (phone-parity) resolution: unlock the
lock screen, launch a tap-counter app, inject 3 taps (counter 0 → 3), and
the whole setup survives a full guest reboot.

## Requirements (host)

| Requirement | Detail |
|---|---|
| OS | Linux x86_64 (Arch-family verified; install scripts also cover apt/dnf) |
| Privileges | `sudo` (host packages only) |
| 32-bit userland | `gcc-multilib` (installed by `build-deps.sh`) |
| Disk | ~20 GB free (SDK image + build engine + apps) |
| RAM | 8 GB free for the VMs, 16 GB comfortable (build engine + emulator) |
| Internet | SDK download (~1 GB) + app runtime |

## Import into Bionic

```bash
git clone <url of this repo> ~/.lmstudio/skills/sailfish-os
```

Then, in any Bionic session: *"Set up the Sailfish OS emulator skill and
verify the pipeline."*

The agent reads `SKILL.md` → `SETUP.md`. Every step is **idempotent** —
safe to re-run on an already-configured machine (`SETUP.md §1` detects what
is already done and skips it).

## What the agent does with this skill

1. `SETUP.md §1` — check what's already installed (VMs, SDK, keys, input tools)
2. Install only what's missing (host deps → SDK → both VMs)
3. Bring up the input pipeline (one idempotent command, `SETUP.md §3`)
4. `scripts/deploy.sh <app> --launch --screenshot` — build, deploy, launch
5. `tap.sh` / `swipe.sh` / screenshots / logs — verify the UI (`TESTING.md`)
6. Iterate until the UI matches expectations → hand to a human for
   device acceptance (a real phone is still the final acceptance step)

## Contents

| Path | Purpose |
|---|---|
| `SKILL.md` | Entry point — the agent reads this first |
| `SETUP.md` | Fresh-machine install; idempotent & re-runnable |
| `PIPELINE.md` | Build → deploy → launch (one command or manual) |
| `INPUT.md` | Verified tap/swipe recipes, coordinate math, traps, debugging |
| `TESTING.md` | UI verification workflow (screenshots, PIL, logs) |
| `NETWORKING.md` | Emulator network topology + internet-only lockdown |
| `SECURITY.md` | Threat model, netlock, sandbox, input security, ops checklist |
| `QML-GOTCHAS.md` | Qt 5.6 / Silica pitfalls that cause white screens & dead taps |
| `scripts/` | `build-deps.sh`, `setup-sdk.sh`, `deploy.sh`, `tap.sh`, `swipe.sh` |
| `tools/` | Guest input-pipeline + netlock sources (C, shell, python) |
| `apps/harbour-cpp/` | Minimal C++/QML tap-counter app to validate the pipeline |

## Security

Read `SECURITY.md` before deploying untrusted apps. In short: the guest can
reach the public internet but **not** the host LAN (blackhole routes), the
input daemon accepts commands from root only, and the only custom code in a
system process is a ~200-line `LD_PRELOAD` shim (auditable, limited scope —
trade-off documented in `SECURITY.md §5`).

## Assumptions

- The VM runs on the **same host as Bionic** (host trusted, guest untrusted,
  hypervisor is the isolation boundary — `SECURITY.md §1`).
- The emulator is the agent's verification loop. A real phone is still
  required for hardware features (camera, GPS, NFC, sensors) and final
  acceptance.
