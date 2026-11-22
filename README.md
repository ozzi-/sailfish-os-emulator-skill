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

Pick one:

- **Ask Bionic** (recommended): invoke `@Install Skill` and give it this
  repo's URL — Bionic installs skills straight from a URL.
- **Clone it**: `git clone <url of this repo> ~/.lmstudio/skills/sailfish-os`
  (later updates = `git pull` inside that folder).

Then, in any Bionic session: *"Set up the Sailfish OS emulator skill and
verify the pipeline."*

The agent reads `SKILL.md` → `SETUP.md`. Every step is **idempotent** —
safe to re-run on an already-configured machine (`SETUP.md §1` detects what
is already done and skips it).

## What the agent does with this skill

1. `SETUP.md §1` — check what's already installed (VMs, SDK, keys, input tools)
2. Install only what's missing (host deps → SDK → both VMs)
3. Bring up the input pipeline (guarded, one idempotent command, `SETUP.md §3`)
4. `scripts/lock.sh hold 30` — take the **pipeline lock**: the emulator is
   one shared VM for every Bionic session on the host, so only one session
   drives it at a time (guarded scripts refuse to run without it)
5. `scripts/deploy.sh <app> --launch --screenshot` — build, deploy, launch
6. `tap.sh` / `swipe.sh` / screenshots / logs — verify the UI (`TESTING.md`)
7. `scripts/lock.sh release` → hand to a human for device acceptance
   (a real phone is still the final acceptance step)
8. To remove everything again: `bash scripts/uninstall.sh` (dry-run first,
   then `--yes`; see `UNINSTALL.md`)

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
| `UNINSTALL.md` | Safe removal of the whole stack (dry-run by default) |
| `QML-GOTCHAS.md` | Qt 5.6 / Silica pitfalls that cause white screens & dead taps |
| `scripts/` | `build-deps.sh`, `setup-sdk.sh`, `deploy.sh`, `tap.sh`, `swipe.sh`, `uninstall.sh`, `lock.sh`, `apply-input.sh`, `lib-lock.sh`, `lib-spec.sh`, `smoke.sh`, `publish.sh`, `sync-local.sh` (maintainer) |
| `tools/` | Guest input-pipeline + netlock sources (C, shell, python) |
| `apps/harbour-cpp/` | Minimal C++/QML tap-counter app to validate the pipeline |
| `apps/sfsmoke/` | Dedicated smoke-test canary app (tap counter) for tier T2 |

## Security

Read `SECURITY.md` before deploying untrusted apps. In short: the guest can
reach the public internet but **not** the host LAN (blackhole routes), the
input daemon accepts commands from root only, and the only custom code in a
system process is a ~200-line `LD_PRELOAD` shim (auditable, limited scope —
trade-off documented in `SECURITY.md §5`).

## Uninstall

`scripts/uninstall.sh` removes the whole stack — both VMs (strict name
matching, no other VM on the host is ever touched), the `~/SailfishOS` SDK
dir, the `sfdk` wrapper, the installer download, and optionally the distro
packages (`--with-packages`) and the skill directory (`--with-skill`).
**Dry-run by default** — it prints the plan with sizes and changes nothing
until you pass `--yes`. Details and manual leftovers: `UNINSTALL.md`.

## Testing & release workflow

The skill ships a strict, tiered smoke-test suite (`scripts/smoke.sh`):

| Tier | What it proves | Needs |
|---|---|---|
| T0 (static) | script syntax, repo hygiene, no personal data, installer hash gate, lock contract, uninstall dry-run safety | nothing (no VMs) |
| T1 (guest health) | both VMs up, SSH, single vts daemon, shim mapped, resolution, internet-only netlock, vts root-only | live pipeline |
| T2 (end-to-end) | builds + deploys + launches the canary app (`apps/sfsmoke`), proves taps change the UI (pixel diff), journal free of QML errors | live pipeline + pipeline lock (held automatically for the run) |

```bash
bash scripts/smoke.sh          # T0 + T1 (default)
bash scripts/smoke.sh --fast   # T0 only
bash scripts/smoke.sh --all    # T0 + T1 + T2 (full proof)
```

**Push gate:** `bash scripts/publish.sh` runs the full suite and pushes only
on green — a broken skill is never shipped to other users.

## Versioning & releases

The version lives in the `version:` line of the `SKILL.md` front matter
(Bionic ignores the field; it drives tagging and install reporting).
To cut a release:

1. Bump `version:` in `SKILL.md` — patch = doc fixes, minor = new capability,
   major = breaking workflow change
2. `git add -A && git commit -m "…"`
3. `bash scripts/publish.sh` — full smoke suite, push on green, then tag +
   push `v<version>` (skips tagging when the version is unchanged, so
   re-publishing a release is a no-op for tags)

**Distribution:** there is no Bionic/LM Studio skill store as of v0.1.0 —
this repository is the distribution channel. Bionic's supported install
paths are *from a URL* (`@Install Skill`, e.g. a GitHub repo) or a local
SKILL.md folder (Settings → Skills). The SKILL.md format is the portable
[Agent Skills](https://agentskills.io/specification) standard, so the same
folder also works in Claude Code and Codex.

## Update the local install (maintainer)

On the machine where this repo lives, the installed copy at
`~/.lmstudio/skills/sailfish-os/` is a **plain folder synced from the repo**
(not a clone):

```bash
bash scripts/sync-local.sh             # sync + verify (idempotent)
bash scripts/sync-local.sh --check     # diff only, change nothing
bash scripts/sync-local.sh --dry-run   # preview what would change
```

It keeps the folder clean (no `.git`, no `README.md`), removes stale files,
refuses destinations outside `~/.lmstudio/skills/`, and reports the installed
version. Safe to re-run any time.

## Concurrency (multiple Bionic projects/sessions)

All sessions share the **same two VMs** — nothing spawns a VM per project.
The input pipeline is a single global channel, so the skill serializes
access: `scripts/lock.sh hold` before a test workflow, `release` after
(kernel `flock`, auto-expiring, no stale locks; guarded scripts exit 75
when another session has the pipeline). Details: `TESTING.md §Concurrency`,
`SECURITY.md §9`.

## Assumptions

- The VM runs on the **same host as Bionic** (host trusted, guest untrusted,
  hypervisor is the isolation boundary — `SECURITY.md §1`).
- The emulator is the agent's verification loop. A real phone is still
  required for hardware features (camera, GPS, NFC, sensors) and final
  acceptance.
