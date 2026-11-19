# INPUT — Programmatic tap & swipe (verified, sub-pixel accurate)

## The model (know this before debugging)

`lipstick` runs with `-plugin VBoxTouch`. That plugin composes a touch event
from **two independent sources**:

| Role | Source | We fake it with |
|---|---|---|
| **POSITION** | `/dev/vboxguest` GET ioctl (16-bit, 0..65535 per axis) | `libvboxfake.so` LD_PRELOAD shim serving `/tmp/vboxfake.pos` |
| **BUTTON** | evdev mouse (`/dev/input/by-path/platform-i8042-serio-1-event-mouse`) | `vts` daemon's `vts-mouse` uinput device, commands via `/tmp/vts.cmd` |

A 1-byte **kick** written to the `/tmp/vboxfake` FIFO wakes the plugin's
event loop; it then polls (GET) the position while it sees the button state.

**THE TRAP:** the evdev mouse ABS_X/ABS_Y are **ignored for position**.
`mmove X Y` + `click X Y` alone will register a tap — but at whatever
position the shim last served (stuck at center → every tap lands at
screen center). **The position file is the single source of truth.**

## Coordinate mapping

Device space is 16-bit per axis; the plugin scales to the UI size:

```
DX = X_screen * 65536 / SCREEN_W
DY = Y_screen * 65536 / SCREEN_H
```

Verified at the standard 1088×2260 (phone-parity): requested (272,565) →
delivered (271.75, 564.76); (952,1977) → (951.14, 1976.14). Error < 1 px.
(Same sub-pixel accuracy holds at the 1024×768 fallback.)

## Tap — verified recipe

```bash
# Easiest: the helper does the math + SSH for you (center of 1088x2260 standard):
bash <skill>/scripts/tap.sh 544 1130

# Or inline (X=544, Y=1130, screen 1088x2260 standard; 1024x768 fallback too):
K=~/SailfishOS/vmshare/ssh/private_keys/sdk
DX=$(( 544 * 65536 / 1088 ))     # 32768 (center)
DY=$(( 1130 * 65536 / 2260 ))    # 32768 (center)
ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 \
  "echo '$DX $DY' > /tmp/vboxfake.pos; \
   printf x > /tmp/vboxfake; sleep 0.3; \
   echo 'click 1 1' > /tmp/vts.cmd; sleep 0.8; echo ok"
#   1. position into the shim
#   2. kick the plugin event loop
#   3. BTN_LEFT press+release
```

## Swipe — verified recipe (full down→motion*→up delivered)

```bash
# host (or: bash <skill>/scripts/swipe.sh X0 Y0 X1 Y1 [STEPS])
setpos() { # $1=X $2=Y
  local D; D="$(( $1 * 65536 / ${W:-1088} )) $(( $2 * 65536 / ${H:-2260} ))"
  echo "echo '$D' > /tmp/vboxfake.pos; printf x > /tmp/vboxfake; sleep 0.12; "
}
SSH="ssh -p 2223 -i $K root@127.0.0.1"
# 1. press at start (BTN_LEFT held)
$SSH "$(setpos X0 Y0) echo 'press 1 1' > /tmp/vts.cmd; sleep 0.25;"
# 2. motion steps (one wl_touch.motion per polled position change)
for i in 1..N:  $SSH "$(setpos Xi Yi) echo 'mmove 1 1' > /tmp/vts.cmd;"
# 3. release at end
$SSH "$(setpos X1 Y1) echo 'release 1 1' > /tmp/vts.cmd; sleep 0.5;"
```

Verified: swipe (544,1800)→(544,460) delivered `down(543.5,1799.2)` +
8 `motion` events (1632→…→460) + `up`; diagonal (300,1500)→(800,700)
tracked a perfect line in both axes.

The vts `tap`/`swipe` (ABS_MT touch device) commands are **dead for the
plugin** — it never reads that device. Use the recipes above.

## vts command reference (`/tmp/vts.cmd`, one command per file write)

| Command | Effect |
|---|---|
| `click X Y` | mmove + BTN_LEFT press/release (X,Y ignored for position!) |
| `mmove X Y` | mouse move event only |
| `press X Y` | mmove + BTN_LEFT down, **held** until release |
| `release X Y` | BTN_LEFT up |
| `tap X Y` / `swipe …` | ABS_MT touch device (unused by the plugin) |
| `quit` | destroy devices, exit daemon |

## Verification & debugging

```bash
# What did the APP actually receive? (Wayland trace — launch the app with
# WAYLAND_DEBUG=1 in its session env to get this in /tmp/<app>.log):
grep -E "wl_touch.*\.(down|motion|up)" /tmp/<app>.log | tail

# Pipeline health (run in-guest):
pgrep vts                                  # expect exactly ONE line
readlink /dev/input/by-path/platform-i8042-serio-1-event-mouse
LP=$(ps -eo pid,comm | awk '$2=="lipstick"{print $1; exit}')
grep -c vboxfake /proc/$LP/maps            # shim refs — expect ≥5
tail -5 /tmp/vts.log
# NOTE: `pgrep -x <name>` silently fails on this guest (busybox pgrep matches
# full argv0). `pgrep lipstick` works but also matches `lipstick-securi*`,
# so use the `ps -eo pid,comm | awk` form for the exact process.

# Shim debug log (VBOXFAKE_DEBUG=1): tail /tmp/vboxfake.log
# Last position served: cat /tmp/vboxfake.pos
```

## QML gotcha that makes taps "not work" (they arrive, the app ignores them)

QML delivers a touch to the **topmost** item at the touch point. A `Text`
declared *after* a `MouseArea` covers it and eats the touch. Fix:
declare the `MouseArea` **last** (topmost) and use **`onPressed`**
(not `onClicked`). See QML-GOTCHAS.md.
