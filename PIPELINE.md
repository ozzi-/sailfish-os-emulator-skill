# PIPELINE — Build, Deploy, Launch (and stop/uninstall)

## One command (recommended)

```bash
cd <skill>
# The whole workflow runs under the pipeline lock (the emulator is shared by
# every Bionic session on this host — TESTING.md §Concurrency, SECURITY.md §9):
bash scripts/lock.sh hold 30
bash scripts/deploy.sh /path/to/harbour-<app> --launch --screenshot [PATH]
# options:
#   --skip-build    deploy the last-built RPM (already in RPMS/)
#   --stop          kill the app
#   --uninstall     kill + remove the package
bash scripts/lock.sh release
```

> `deploy.sh` is **guarded**: it exits 75 ("another session has the pipeline")
> unless `scripts/lock.sh hold` was called first. `sfdk build` inside it and
> the manual `sfdk build` steps below share the same build-engine VM — run
> them under the lock too.

What it does:
1. `sfdk build` — compiles on the build-engine VM (Qt 5.6, i486) → `RPMS/*.rpm`
2. `scp` RPM → emulator, `rpm -e --nodeps` (old) + `rpm -i --nodeps` (new)
3. sailjaild D-Bus: `SetLaunchAllowed` + `SetGrantedPermissions`
   (internet, media_index, removable_media, user_directories, bluetooth,
   camera, microphone, audio, positioning, nfc, web_content) — so no GUI
   permission dialog ever appears
4. Launch via `invoker -s --type=silica-session` inside the GUI user session
   (same sailjaild sandbox + permissions; the `sailjail` binary is broken on
   SDK images) — **app starts in the BACKGROUND** (behind home screen),
   log at `/tmp/<app>.log`
5. Optional `screenshotpng` capture
   ⚠ App log: `/tmp/<app>.log` may be **empty or stale** when sessiond
   adopted the launch — check the guest journal: `journalctl | grep <app>`.

App name is derived from the `harbour-*.spec` in the app tree — `deploy.sh`
resolves `Name:` (a literal, or a `%{macro}` resolved through `%define …`) and
falls back to the spec filename. See `scripts/lib-spec.sh` (unit-tested in
`smoke.sh` T0.7).

> **Build-engine workspace:** the build engine is a VM and only sees host
> files under the SDK *shared source* path (installer default: `$HOME`; set
> at install time, visible in `~/.config/SailfishSDK/libsfdk/buildengines.xml`
> as `SharedSrc`). `sfdk build` refuses to run outside it. `deploy.sh`
> handles this for you: apps outside the workspace are **staged as a clean
> copy** under `$SHARED_SRC/.sfdk-staging/<app-name>` and built there (the
> RPM appears next to that staged copy). Manual `sfdk build` must be run
> from a directory inside the workspace.

## Phone build (aarch64 — the other target)

Two targets, two scripts:

| Target | Arch | Script | Where it builds | Used for |
|---|---|---|---|---|
| **Emulator** | i486 | `deploy.sh` (sfdk) | SDK build-engine VM | fast agent verify loop |
| **Phone** | aarch64 | `build-phone.sh` (docker + mb2) | a docker container | final-acceptance RPM |

`deploy.sh` produces the i486 RPM and drives the emulator. `build-phone.sh`
produces the **aarch64** RPM the phone actually installs, using the proven
docker + mb2 recipe — the SDK image supplies the aarch64 cross-compiler, so you
do not need one on the host:

```bash
# Dry-run first (prints the plan, touches nothing — safe on any host):
bash scripts/build-phone.sh /path/to/harbour-<app> --dry-run

# Real build (~1–3 min). Does NOT take the pipeline lock: it never touches the
# emulator VM, so it is safe to run alongside a session driving the emulator.
bash scripts/build-phone.sh /path/to/harbour-<app>
# → RPM copied to <app>/dist/<name>-<version>-<release>.aarch64.rpm
```

- **The aarch64 RPM will NOT run on the i486 emulator** — by design. Verify on
  the emulator first (`deploy.sh`), then build the phone RPM.
- **Delivery to the phone is a user step** (the phone must be on the network):
  `scp <rpm> defaultuser@<PHONE_IP>:~/`, then on the phone
  `devel-su rpm -i ~/<rpm>` (or `-Uvh` to upgrade). `build-phone.sh` prints
  these exact commands when it finishes.
- **Requires** docker + the aarch64 SDK image (default
  `coderus/sailfishos-platform-sdk-aarch64:5.2.0.15`; override with
  `SFOSSDK_AARCH64_IMAGE`). If the image is missing, `build-phone.sh` prints
  the exact `docker pull` command instead of failing silently.
- **Optional hardening (recommended before shipping):** run the local
  verification ladder — QML compile check, geometry harness, D-Bus E2E
  harness — all under `qemu-aarch64`, no VM, no phone: see `HARNESS.md`.
  The emulator verify loop above remains the skill's main path; the ladder
  catches silent rendering bugs the emulator tap loop may not reach.

## Environment knobs

`SFDK`, `VM_NAME` (auto-detected by default), `SSH_PORT` (2223), `SSH_KEY`,
`SSH_USER` (root), `SSH_HOST` (127.0.0.1), `SHOTS_DIR`,
`SESSION_USER` (defaultuser), `SESSION_UID` (100000).

## Manual steps (for debugging)

```bash
K="${SSH_KEY:-$HOME/SailfishOS/vmshare/ssh/private_keys/sdk}"
SSH() { ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 "$@"; }
APP=harbour-<name>          # package name
BINARY=/usr/bin/$APP

# 1. build
cd /path/to/app && ~/.local/bin/sfdk build
RPM=$(ls -t RPMS/*.rpm | head -1)

# 2. deploy
scp -P 2223 -i "$K" "$RPM" root@127.0.0.1:/root/
SSH "rpm -e --nodeps $APP 2>/dev/null; rpm -i --nodeps /root/$(basename "$RPM")"

# 3. grant (avoids GUI dialog)
SSH "dbus-send --system --dest=org.sailfishos.sailjaild1 /org/sailfishos/sailjaild1 \
     org.sailfishos.sailjaild1.SetLaunchAllowed uint32:100000 string:$APP int32:1"
SSH "dbus-send --system --dest=org.sailfishos.sailjaild1 /org/sailfishos/sailjaild1 \
     org.sailfishos.sailjaild1.SetGrantedPermissions uint32:100000 string:$APP \
     array:string:\"internet\",\"media_index\",\"removable_media\",\"user_directories\",\"bluetooth\",\"camera\",\"microphone\",\"audio\",\"positioning\",\"nfc\",\"web_content\""

# 4. launch (GUI session env is mandatory; invoker, NOT sailjail — see note)
#    NOTE: app starts in the BACKGROUND (behind home screen) — tap its icon
#    or interact with tap.sh/swipe.sh.
SSH "pkill -9 $APP 2>/dev/null; sleep 1
     su defaultuser -s /bin/sh -c 'export HOME=/home/defaultuser USER=defaultuser \
       WAYLAND_DISPLAY=/run/display/wayland-0 XDG_RUNTIME_DIR=/run/user/100000 \
       DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket; \
       setsid nohup /usr/bin/invoker -s --type=silica-session $BINARY >/tmp/$APP.log 2>&1 </dev/null &'
     sleep 6; pgrep $APP"

# 5. screenshot
VBoxManage controlvm "<VM>" screenshotpng out.png
```

## Notes & gotchas

- **`sfdk build` is IN-PLACE and takes NO path argument** — run it from the
  app root (`cd <app-repo> && sfdk build`); passing a path triggers a
  "shadow" flow that fails. The source must be a **real directory on a local
  filesystem**: a mirror/copy of the repo under a local path works, but a
  symlink pointing at a network/overlay (FUSE) mount has failed.
- **`mb2` / `sfdk` build in place and skip `%prep` / `%setup`** — the source
  tree is at the build root (`%{_builddir}`), **not** at
  `%{_builddir}/<name>-<version>`. A stock qmake spec that does
  `cd %{_builddir}/%{name}-%{version}` therefore fails. Resolve the source root
  defensively:
  ```sh
  if [ -d %{_builddir}/%{name}-%{version} ]; then
      cd %{_builddir}/%{name}-%{version}
  else
      cd %{_builddir}
  fi
  ```
  (The bundled specs avoid this by using a literal `cd rpm/sources`.)
- **App windows render fullscreen** — lipstick maximizes them; a 360×740 QML
  Window is scaled to the whole framebuffer.
- **`pgrep` on the guest is BusyBox** — `pgrep -x` matches full argv0 and
  silently fails; use plain `pgrep <name>` (regex). Caveat: `pgrep lipstick`
  also matches `lipstick-securi*` — use `ps -eo pid,comm | awk '$2=="lipstick"'`
  when the exact process matters (e.g. reading `/proc/<pid>/maps`).
- **`pkill -f <app>` can kill your own SSH shell** — use `pkill -9 <app>`
  (exact) or the bracket trick `pkill -9 -f '<app>-[-]x'`.
- **CLI-launched apps start in the BACKGROUND** (behind the home screen) —
  normal SFOS behaviour. Raise it by tapping its icon, or interact directly
  with `tap.sh`/`swipe.sh` (TESTING.md).
- **Restarting lipstick kills all running apps** — relaunch after.
- **White screen = QML failed to instantiate** — check QML-GOTCHAS.md and
  the app log; the shipped QML may differ from what you wrote
  (`rpm -ql <app>`, grep the installed QML).
- **`/tmp` is tmpfs** — logs persist until VM reboot.
- **App logs: verify with screenshot + journal, never the log file alone.**
  When the session manager (sessiond) adopts a launch, the app's fd1/fd2 go
  to a socket and `/tmp/<app>.log` goes stale/empty — the real log is the
  journal: `journalctl | grep <app>` (guest). Multiple instances of the same
  app can coexist (manual launch + deploy.sh + sessiond relaunch); the
  frontmost window and the input-receiving instance may differ — `pkill -9
  <app>` and relaunch via deploy.sh before judging behaviour.
  (Also: `Qt.outputDebug` does NOT exist in Qt 5.6 — it throws TypeError;
  use `console.log` or the journal.)
- The build engine and emulator talk over an SDK internal network
  (10.220.220.x) — that's the SDK's own plumbing; you don't touch it.
- **`deploy.sh` grants ALL sailjail capabilities by default** (no GUI dialogs).
  For untrusted apps grant only what they need:
  `PERMISSIONS="internet,audio" ./deploy.sh …` — see **SECURITY.md**.
- **`rpm -i --nodeps`**: dependency checks are skipped on purpose so a missing
  optional library never blocks a deploy. Trade-off: a genuinely missing
  library shows up as a **launch** crash (visible in the app log) instead of a
  clean install refusal. Fine for a dev VM you control.
