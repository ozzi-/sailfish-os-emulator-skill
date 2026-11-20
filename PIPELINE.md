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

App name is derived from the `harbour-*.spec` in the app tree.

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
