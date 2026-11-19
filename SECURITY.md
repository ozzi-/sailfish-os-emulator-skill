# SECURITY.md — Sailfish OS Emulator Skill

This document defines the threat model, security controls, and operational
checklist for the Sailfish OS emulator pipeline. Read this before deploying
untrusted apps or modifying the network/input setup.

---

## §1 Threat Model

**Assumption (S9):** The VM runs on the SAME host as Bionic (LM Studio),
your dev tools, APIs, and local services. The VM is NOT on a separate
physical machine.

| Actor | Capability | Risk |
|-------|-----------|------|
| Malicious app (deployed by you) | Runs as `defaultuser` (uid 100000) inside the guest, firejail sandbox | Could attempt: network exfil to host/LAN, input injection (PIN bypass), read host files via shared folders |
| Compromised guest kernel | Full guest root | Could: escape to host (VBox exploit), read host memory |
| Build engine VM (SDK) | SDK architecture REQUIRES its `src1` shared folder to be the host home dir **read-write** (engine writes `.sfdk` build state into your project tree); it also has NAT internet (build deps) | Building untrusted source can read the host home and exfiltrate over internet. **Accepted risk — see §2.5.** Build only source you trust. |
| Another VM / process on host | Same user or root on host | Could: access VM disk image, VNC, SSH |

**Trust boundary:** The guest OS and its apps are UNTRUSTED. The host is
TRUSTED. The VM hypervisor (VirtualBox) is the isolation boundary.

**What we do NOT protect against:**
- A compromised VirtualBox (hypervisor escape) — use a different hypervisor if this is a concern
- A user with host root who reads the VM disk image
- Malicious updates from the Sailfish SDK repository (supply chain, §7)

---

## §2 Network Lockdown (Internet-Only Egress)

**Goal (S1):** The guest can reach the public internet (via VBox NAT) but
CANNOT reach:
- The host's LAN IP (192.168.x.x, 10.x.x.x non-VBox, 172.16.x.x)
- Other VMs on the host
- Link-local addresses (169.254.x.x)
- The host via NAT loopback (10.0.2.2:PORT → host services)

**Mechanism: Blackhole routes** (NOT iptables).

Why not iptables? Connman (SFOS network manager) saves/restores iptables
tables on service activation, which WIPES mangle/filter rules within ~2
minutes (verified in journal: `connman_iptables_restore() cannot restore
table mangle`). Blackhole routes are in the kernel routing table, which
connman does NOT manage.

**Implementation:**
```
ip route add blackhole 10.0.0.0/8      # blocks all 10.x except more-specific routes
ip route add blackhole 172.16.0.0/12
ip route add blackhole 192.168.0.0/16
ip route add blackhole 169.254.0.0/16
```

**Exemptions (automatic via longest-prefix-match):**
- `10.0.2.0/24` (24-bit kernel route > 8-bit blackhole) → VBox NAT plumbing
- `10.220.220.0/24` (24-bit kernel route > 8-bit blackhole) → SDK host-only network

**Persistence:**
- `sf-netlock.service` (oneshot, runs at boot after network.target)
- `sf-netlock.timer` (re-applies every 60s as safety net)

**Verification (run after any reboot):**
```bash
# Internet works:
curl -s -o /dev/null -w '%{http_code}' https://www.google.com  # expect 200
# LAN blocked:
ping -c1 -W2 192.168.1.1  # expect "Invalid argument" (blackholed)
# SDK works:
ping -c1 -W2 10.220.220.254  # expect reply
```

**KNOWN LIMITATION:** The NAT gateway (10.0.2.2) is both the internet path
AND a route to the host. We cannot block 10.0.2.2 without breaking internet.
In practice, this means the guest CAN reach host services that listen on
accessible ports (via NAT port-forwarding or if the host binds to 0.0.0.0).
Mitigation: don't run sensitive services on the host without auth/firewall.

---

## §2.5 Build Engine — Accepted Risks (S-1, S-2, S-8)

The **build engine** VM (`Sailfish SDK Build Engine`) compiles your app from
the host filesystem via VirtualBox shared folders. Its share layout is
**fixed by the SDK** (no `sfdk` property exists to narrow it), which forces
three accepted risks. Understand them before building untrusted source.

### S-1 — `src1` shared folder is host home, READ-WRITE (accepted)

**Evidence:** with `src1` set read-only, `sfdk build` fails with
`mkdir: cannot create directory '<app>/.sfdk': Read-only file system`. The
engine-side `/proc/mounts` shows `src1` (vboxsf) mapped to the host home,
with `/home/<user>` on the engine as fuse.dynexecfs over it. The build
process writes `.sfdk/` state **into the project tree**, so the share MUST
be writable — there is no narrower share possible via `sfdk`.

**Consequence:** a malicious (or compromised) build script runs in the
engine with write access to the host home directory.
**Mitigation:** treat the engine as a trusted build environment; only build
source you trust; the engine has **no LAN access** (NIC2 = Internal only,
§2), so its egress is internet-only.
**Do NOT** re-apply read-only to `src1` — it breaks the build (verified).

### S-2 — Engine can READ the whole host home (accepted)

The engine's `home` share is read-only from the engine's view, which means
the engine can read the entire host home directory. Combined with S-1's
internet egress (needed for build dependencies), building untrusted source
creates a **read + exfiltration path** to host files.
**Mitigation:** same as S-1 — build only trusted source. The emulator VM
is NOT affected: all of its shared folders are read-only from the guest
(verified) and it has the §2 blackhole lockdown.

### S-8 — VM guardrail (operational rule)

The host user (in `vboxusers`) can `VBoxManage` **any** VM on the machine —
and the host may have unrelated VMs (e.g. a personal desktop VM). The agent
MUST operate only on the two Sailfish VMs:

- `SailfishOS-*` (the emulator)
- `Sailfish SDK Build Engine` (the build engine)

Never power off, modify, delete, or take snapshots of any other VM.
`uninstall.sh` enforces the same name-matching guardrail (§UNINSTALL.md).

---

## §3 Sandbox / Permissions

Apps run in a **firejail sandbox** (via `invoker -s --type=silica-session`
or `sailjail`). The sandbox:
- Whitelists only the app's binary, data dirs, and shared resources
- Drops capabilities
- Restricts filesystem access (no /etc, no /root, no other apps' data)
- Enforces sailjaild permission model (internet, camera, etc.)

**Permission grants (deploy.sh):**
- Default: ALL permissions (fast dev loop, no GUI dialogs)
- For untrusted apps: `PERMISSIONS="internet,audio"` (minimal)
- sailjaild only enforces what's granted — ungranted = blocked

**NOTE:** The `sailjail` binary is broken on SDK images (missing
`disable-common.local` firejail profile). Use `invoker` instead — it uses
the same sandbox + permissions but works reliably.

---

## §4 Input Pipeline Security (vts root-only)

The `vts` daemon runs as **root** (needs `/dev/uinput`) and injects UI
events (tap, swipe, click). Without protection, any guest process could:
- Inject taps to punch a PIN / bypass a security dialog
- Issue `quit` to kill the daemon (DoS)

**Mitigation (verified):** vts `fstat()`s `/tmp/vts.cmd` on every read.
If `st_uid != 0` (not root), the command is **rejected + file deleted**.
The daemon survives. Non-root processes CANNOT command vts.

**Verification:**
```bash
# As non-root: write "quit" to /tmp/vts.cmd
su defaultuser -c 'echo quit > /tmp/vts.cmd'
# vts log shows: "REJECTED /tmp/vts.cmd (uid=100000, must be root)"
# vts still running ✓
```

### §4.1 Position file (`/tmp/vboxfake.pos`) — root-only check (S-5, FIXED)

The shim reads tap positions from `/tmp/vboxfake.pos`. Any guest process
writing arbitrary coords there would let it steer taps without going through
vts. **Control:** `vboxfake.c` now `fstat()`s the position file and accepts
it only when `st_uid == 0` (root); anything else is **ignored and the center
default is used**.

**Verification (both paths proven):**
- *Accept:* root-owned `.pos` with explicit coords → taps land exactly at the
  requested positions (icon tap opened the app; two center taps advanced the
demo counter to 2, confirmed in screenshot).
- *Reject:* a non-root-owned `.pos` containing bogus coords ("12345 54321")
  → shim returned the center default (x=32767, y=32767) — verified for both
  uid 100000 and uid 65534 via a host-built harness linking the same shim
  source. Absent `.pos` → center default.

### §4.2 FIFO `/tmp/vboxfake` (S-4, accepted)

The kick FIFO is `0644` owned by `defaultuser` — any defaultuser process can
write a 1-byte kick. **Harmless:** a kick alone does nothing; the actual
event requires the BTN_LEFT press that only root (vts) can issue. It cannot
be tightened further, because `lipstick` (defaultuser) must be able to open
the read end.

---

## §5 LD_PRELOAD Trade-off

`libvboxfake.so` is LD_PRELOADed into `lipstick` (the compositor) to
intercept the `/dev/vboxguest` GET ioctl and serve fake touch positions.

**Trade-off:**
- ✅ Enables programmatic touch injection (the entire tap/swipe pipeline)
- ❌ Any bug in the shim could crash or corrupt the compositor
- ❌ If the shim is compromised, it has the same privileges as lipstick
  (defaultuser, not root — so blast radius is limited to the UI session)

**Mitigation:**
- The shim is ~200 lines of C, auditable
- It only intercepts ONE ioctl (GET on /dev/vboxguest)
- It serves data from a root-only FIFO (/tmp/vboxfake)
- A crash restarts lipstick (systemd `Restart=always`)

---

## §6 Guest-Local Binds (VNC, DNS)

| Service | Bind | Risk |
|---------|------|------|
| VNC (VirtualBox) | `127.0.0.1:5900` (host-side) | Only accessible from the host. No network exposure. |
| DNS (systemd-resolved) | `127.0.0.53` (guest-internal) | Loopback only. Not reachable from outside. |
| SSH (sshd) | `0.0.0.0:22` in guest → NAT port-forward to `127.0.0.1:2223` | Only reachable via the NAT port-forward on the host's localhost. |

**No guest service is exposed to the LAN.** The NAT + blackhole routes
ensure the guest is invisible to other network devices.

**S3 note:** VNC on :5900 is bound to localhost by VirtualBox default.
If you change this, ensure it's not exposed to the network.

---

## §7 Supply Chain

| Item | Control |
|------|---------|
| SDK / guest image | Downloaded from Jolla's official site. Verify SHA-256 if available (S7: fail-hard on mismatch). |
| RPMs built on engine | Built from YOUR source code. No external deps beyond Qt5 (from the SDK). |
| `rpm --nodeps` (S10) | Used for fast install. Risk: missing deps could cause unexpected behavior. Mitigation: the SDK image has all Qt5 libs pre-installed. |
| VirtualBox (S11) | Keep updated. Hypervisor exploits = host compromise. Check `VBoxManage --version` periodically. |
| vts / libvboxfake.so | Built from source in this skill's `tools/`. No external deps. |

---

## §8 Ops Checklist

Run after any host reboot, guest reboot, or snapshot restore:

```bash
# 1. VMs running?
VBoxManage list runningvms  # expect: Build Engine + Emulator

# 2. SSH works?
ssh -p 2223 -i ~/SailfishOS/vmshare/ssh/private_keys/sdk root@127.0.0.1 'echo OK'

# 3. Key permissions (S5)
stat -c '%a' ~/SailfishOS/vmshare/ssh/private_keys/sdk  # expect: 600

# 4. Netlock active?
ssh ... 'ip route show | grep blackhole'  # expect: 4 blackhole routes

# 5. Input pipeline?
ssh ... 'ps aux | grep vts && grep -c vboxfake /proc/$(pgrep lipstick)/maps'
# expect: vts running, shim refs >= 5

# 6. Display working?
VBoxManage controlvm <vm> screenshotpng /tmp/test.png  # expect: non-black image

# 7. After ANY guest reboot: re-run input setup
ssh ... '/usr/local/bin/sf-input-setup.sh'

# 8. Snapshot restore = clean reset (wipes all in-guest deployments)
#    Re-deploy from host-side sources in this skill's tools/
VBoxManage snapshot <vm> restore "5.1.0.11"

# 9. VM guardrail (S-8): only ever operate on
#    "SailfishOS-*" and "Sailfish SDK Build Engine" — the host may have
#    other, unrelated VMs. Never poweroff/modify/delete any other VM.

# 10. App logs: check the GUEST JOURNAL, not just the log file:
ssh ... 'journalctl | grep <app> | tail -50'
#    /tmp/<app>.log can be stale or empty when the session manager
#    (sessiond) adopted the launch (app fd1/2 → socket, not your file).
#    Verify UI behaviour via screenshot + journal — never the log file alone.
```

---

## File Map

| File | Purpose |
|------|---------|
| `tools/sf-netlock.sh` | Blackhole route lockdown (idempotent) |
| `tools/vts.c` | Input daemon (root-only, uinput) |
| `tools/vboxfake.c` | LD_PRELOAD shim for touch position |
| `tools/sf-input-setup.sh` | Deploy + start input pipeline |
| `scripts/tap.sh` | Inject a tap at screen coords |
| `scripts/swipe.sh` | Inject a swipe between coords |
| `scripts/deploy.sh` | Build → deploy → launch → screenshot |
| `SETUP.md` | First-time setup + re-run instructions |
| `UNINSTALL.md` | Safe removal of the whole stack (dry-run by default) |
| `NETWORKING.md` | Network topology + lockdown details |
| `TESTING.md` | Test procedure for apps |
| `scripts/uninstall.sh` | Destructive-cleanup script (dry-run default, `--yes` to execute) |
