# Local test harness — verify before shipping (no VM, no phone)

The emulator tap loop catches most problems, but some SFOS/Qt 5.6 bugs are
**silent** (page loads, content just missing) and only a runtime inspection
proves them. This ladder runs the **real SFOS 5.2 aarch64 QML engine**
headless under `qemu-aarch64` on the host — cheapest first:

| Tier | Catches | Cost |
|---|---|---|
| 1. QML compile check | instantiate-time errors (white screen) | ~1 s |
| 2. Geometry harness | silent rendering bugs (blank rows, 0-width items, dead Repeater) | ~10 s |
| 3. D-Bus E2E harness | client ↔ service signatures, metatypes, QML wiring | ~10 s |
| 4. Emulator (skill main loop, `PIPELINE.md`) | visual + interactive behavior | minutes |
| 5. Phone | final acceptance (hardware, real SFOS build) | user step |

**All tiers run on the host (docker + qemu) — they never touch the emulator
VMs, so they do NOT take the pipeline lock** and are safe to run alongside
a session driving the emulator.

**Gates (rules):**
- A touched QML file ships to the phone only after Tier 1 passes.
- A page change ships only after Tier 2 shows the expected texts/counts/heights.
- A change touching D-Bus client code (or the page driving it) ships only
  after Tier 3 ends with `E2E DONE`.

## Requirements (host)

- `docker` + the aarch64 SDK image (same as `build-phone.sh`, default
  `coderus/sailfishos-platform-sdk-aarch64:5.2.0.15`).
- `qemu-aarch64` (user-mode emulation).
- `dbus-daemon` (Tier 3 only).
- A **persistent** staging dir — do NOT use `/tmp` on hosts where it is
  flaky (e.g. FUSE-backed workspaces). Convention: `<project>/harness-work/`.

## Shared: extract the SFOS target runtime (once per machine, ~1 min)

Both the compile check and the geometry harness need the target's libs,
QML modules and QPA plugins. Extract them from the SDK image:

```bash
SDK=coderus/sailfishos-platform-sdk-aarch64:5.2.0.15
T=<project>/harness-work/sfos-target
rm -rf "$T" && mkdir -p "$T"
CID=$(docker create $SDK true)
for p in lib lib64 bin usr/bin usr/lib usr/lib64; do
    mkdir -p "$T/$(dirname $p)"
    docker cp $CID:/srv/mer/targets/SailfishOS-5.2.0.15-aarch64/$p "$T/$p"
done
# usr/share (≈240 MB) has permission-locked files — tar around them:
docker run --rm $SDK sh -c 'cd /srv/mer/targets/SailfishOS-5.2.0.15-aarch64 \
    && tar cf - --ignore-failed-read usr/share 2>/dev/null' > /tmp/sfos-share.tar
(cd "$T" && tar xf /tmp/sfos-share.tar 2>/dev/null)
docker rm $CID >/dev/null
```

`$T` is the `-L` root for qemu and the source of `LD_LIBRARY_PATH`.

## Tier 1 — QML compile check (~1 s)

Instantiate each QML file against the real engine; you get `COMPILE OK` or
the exact `QML ERROR` with file + line. Catches `header:` on `Page`,
`SilicaButton`/`BackButton`, inline `if { Item }`, `paddingTiny`, and every
other instantiate-time error — with no phone round-trip.

**The checker tool** (build once, keep in `<project>/harness-work/`):

`qmlcheck.cpp`:
```cpp
// Compile-only QML check, no QPA (works headless under qemu)
#include <QCoreApplication>
#include <QQmlEngine>
#include <QQmlComponent>
#include <cstdio>
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage\n"); return 2; }
    QQmlEngine engine;
    engine.addImportPath(QString("/usr/lib64/qt5/qml"));   // NOT setImportPath(QStringList)
    QQmlComponent comp(&engine, QUrl::fromLocalFile(argv[1]));
    if (comp.isError()) {
        fprintf(stderr, "errorString: %s\n", comp.errorString().toUtf8().constData());
        foreach (const QQmlError &e, comp.errors())
            fprintf(stderr, "  QML ERROR: %s\n", e.toString().toUtf8().constData());
        return 1;
    }
    fprintf(stderr, "COMPILE OK\n");
    return 0;
}
```

`qmlcheck.pro`:
```
QT += qml core
CONFIG += console c++17
TARGET = qmlcheck
SOURCES = qmlcheck.cpp
```

**Build** (inside the SDK — `make`/`g++` exist only inside `mb2 build-shell`;
`g++` there is the aarch64 cross-compiler):
```bash
B=<project>/harness-work; SDK=coderus/sailfishos-platform-sdk-aarch64:5.2.0.15
mkdir -p $B/mb2proj/qmlcheck-0.1.0/qmlcheck
cp qmlcheck.cpp qmlcheck.pro $B/mb2proj/qmlcheck-0.1.0/qmlcheck/
chmod -R a+rwX $B/mb2proj
docker run --rm -v "$B/mb2proj":/home/mersdk/proj $SDK bash -lc \
  'cd /home/mersdk/proj && mb2 build-shell sh -c "cd qmlcheck-0.1.0/qmlcheck && qmake qmlcheck.pro >/dev/null 2>&1 && make 2>&1 | tail -3"'
```

**Run** (per touched QML file):
```bash
T=$B/sfos-target
LD_LIBRARY_PATH=$T/usr/lib64:$T/lib64 \
  timeout 60 qemu-aarch64 -L $T $B/mb2proj/qmlcheck-0.1.0/qmlcheck/qmlcheck \
    <project>/repo/qml/pages/SomePage.qml
```

**Notes:**
- `QCoreApplication` only — a `QGuiApplication` build aborts under emulation
  (the target has no `offscreen` QPA plugin).
- This Qt's `QQmlEngine` has `addImportPath(QString)`, **not**
  `setImportPath(QStringList)` — trust the compiler over the Qt docs.

## Tier 2 — Runtime geometry harness (~10 s)

Compile checks only prove the page *instantiates*. The silent rendering bugs
(see `QML-GOTCHAS.md` §"Silent rendering bugs") need a **runtime** check:
instantiate the real page with real data and dump the item tree.

**Harness shape:**
- `QGuiApplication` + `QT_QPA_PLATFORM=minimal` (the SFOS target ships
  `libqminimal.so`) + `QQmlEngine` + `engine.addImportPath("/usr/lib64/qt5/qml")`.
- A **FakeClient** `QObject` (context property, same name the app's
  `main.cpp` uses) whose `Q_INVOKABLE`s return staged JSON and whose
  **signals have the same NAMED parameters** as the real C++ client.
- A harness QML root: `Loader` of the real page + inline test data.
- After settling (~200 ms of `processEvents` + `msleep`), dump the QObject
  tree recursively: `metaObject()->className()`, `x()/y()/width()/height()`,
  `property("text")`, Repeater `count`. That dump is your proof: rows must
  show their Label texts, bars their heights.

**Run recipe** (same build pattern as Tier 1, then):
```bash
B=<project>/harness-work; T=$B/sfos-target
docker run --rm -v "$B":/hw -v "$T":/sfos $SDK bash -lc \
  'cd /hw && QT_QPA_PLATFORM=minimal /usr/bin/qemu-aarch64-static -L /sfos ./geom <harness.qml> <staged-data.json>'
```

**Qt 5.6 harness pitfalls (all hit the hard way):**
- **`/tmp` inside the container is NOT the host `/tmp`** — a fake client
  that reads `/tmp/data.json` silently gets empty data and you misread "no
  data" as "bug in the page". Stage data inside the mounted build dir and
  pass the path as argv.
- **`QQmlConnections` never connects without a window/scene** — signal
  handlers don't fire in the harness. Drive the state from the harness QML
  directly (assign the page's properties with a real JS array — same shape
  the handler would produce).
- **No `QJSValue::fromVariant` in 5.6** (5.9+). Use
  `QVariant v = obj->property("x"); if (v.canConvert<QJSValue>()) QJSValue js = v.value<QJSValue>();`
- **No `QVariant(QJSValueList)` constructor in 5.6.** Build JS arrays in
  QML, not C++.
- `QString::arg()` only fills `%1`-style placeholders — `"w=%.0f"` leaves
  the `%.0f` literal. Use `"w=%1 h=%2".arg(...).arg(...)`.
- `moc` rejects signal declarations with bodies; `Q_OBJECT` in a `.cpp`
  needs `#include "<name>.moc"` at EOF.
- Under minimal QPA `isVisible()` is always false (no window) — rely on the
  `visible` property value, not `isVisible()`.
- Qt 5.6 has **no public `QQuickText`/`QQuickCanvas`/`QQuickRepeater`
  headers** — inspect via `QObject::property()` + `metaObject()->className()`.
- Run under qemu on the host, **not inside `mb2 build-shell`** (its PATH
  hides qemu).

**Shortcut:** if the emulator is already running, a screenshot + tap
(`PIPELINE.md`) is often faster than the harness. Use whichever is quicker;
the harness wins when the emulator is down or the bug is data-dependent.

## Tier 3 — D-Bus E2E harness (~10 s)

For apps that talk D-Bus to a system service (connman-vpn, NetworkManager,
…): run the **real app client code and the real QML page** headless under
`qemu-aarch64` against a **fake D-Bus service** implementing the same
interfaces/paths/signatures. The client still goes through a real D-Bus
daemon over a unix socket, so `UnknownMethod`, signature, metatype and
QML-wiring bugs all surface — no VM boot, no phone round-trip.

**Layout** (persistent dir, NOT `/tmp`):
```
<project>/harness-work/
├── sfos-target/               # extracted runtime (shared recipe above)
├── dbus.conf                  # permissive local bus config (below)
├── dbus.sock                  # (created at run time)
└── mb2proj/<harness>-<ver>/   # tiny build dir (just `make` in build-shell)
    ├── <harness>.pro          # QT += qml quick dbus; CONFIG += console c++11
    ├── main.cpp               # driver: fake setup, real page, JS calls, asserts
    ├── fake<svc>.h/.cpp       # the fake D-Bus service
    ├── <client>.h/.cpp        # the app's REAL client sources (copy them in,
    │                          # or reference repo/src/ paths — avoid drift)
    ├── qml/…                  # the app's REAL page (same rule)
    ├── harness.qml            # root Item: Loader of the real page +
    │                          # `property alias page: loader.item`
    └── <harness>              # built aarch64 binary
```

**`dbus.conf`** (permissive local bus; socket path must be absolute):
```xml
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=<abs>/<project>/harness-work/dbus.sock</listen>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
```

Host needs `dbus-daemon` + `qemu-aarch64`. The daemon is host x86_64 and
the client aarch64-under-qemu — that's fine, they talk over a plain unix
socket.

**Fake-service patterns:** see `QML-GOTCHAS.md` §"D-Bus (Qt 5.6)" — the
adaptor/metatype rules there are exactly what a fake service must obey
(a plain `QObject` exposes nothing; a `QDBusArgument`-returning slot drops
the whole interface). Verify what actually got exposed by introspecting the
live socket:
```
DBUS_SYSTEM_BUS_ADDRESS=unix:path=$B/dbus.sock dbus-send --system --print-reply \
  --dest=:1.1 / org.freedesktop.DBus.Introspectable.Introspect
```
A service that shows up with no methods = one of those rules was violated.

**Driver patterns (Qt 5.6):**
- Host the real page in a `QQuickView` with the **same context property name**
  the app's `main.cpp` uses (the page code stays unchanged).
- **QML ids are not visible outside the component.** Drive the page's public
  JS functions from C++ via `QJSEngine::evaluate("hroot.page.<fn>(…)")`
  after `hroot = eng->newQObject(view.rootObject())`. (Qt 5.6 has no
  `QQmlExpression::call(args)`; `QQmlScriptString`'s ctor is protected —
  `QJSEngine` is the way.)
- Step the test with `QTimer::singleShot`; after each step, read state back
  through the **real client** (not the fake's internals) and append an
  OK/FAIL line to a log file. A green run ends with an explicit `E2E DONE`.

**Build & run recipe:**
```bash
B=<project>/harness-work; P=$B/mb2proj/<harness>-<ver>
SDK=coderus/sailfishos-platform-sdk-aarch64:5.2.0.15

# rebuild after any source change (make is only on PATH inside build-shell):
docker run --rm -v "$B/mb2proj":/home/mersdk/proj $SDK \
  bash -lc 'cd /home/mersdk/proj && mb2 build-shell sh -c "cd <harness>-<ver> && make 2>&1 | tail -5"'

# run:
rm -f $B/dbus.sock /tmp/harness-debug.log
dbus-daemon --config-file=$B/dbus.conf --nofork & DPID=$!
sleep 1
cd $P
LD_LIBRARY_PATH=$B/sfos-target/usr/lib64:$B/sfos-target/lib64 \
QT_QPA_PLATFORM=minimal \
DBUS_SYSTEM_BUS_ADDRESS=unix:path=$B/dbus.sock \
timeout 35 qemu-aarch64 -L $B/sfos-target ./<harness>
kill $DPID
cat /tmp/harness-debug.log   # read immediately (transient log)
```

**What green looks like** (a VPN-profile app, one fake profile):
```
GetConnections OK: 1 connection(s): example.nordvpn.com
model count=1 quickIndex=0
FAKE: Connect on FakeConnection
connectProfile -> true
Connect OK: /net/connman/vpn/connection/example_nordvpn_com_tcp_2_6
state=online
FAKE: Disconnect on FakeConnection
Disconnect OK: /net/connman/vpn/connection/example_nordvpn_com_tcp_2_6
state=idle
E2E DONE
```
