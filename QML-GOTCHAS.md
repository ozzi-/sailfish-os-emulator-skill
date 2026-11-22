# QML / Silica gotchas (Qt 5.6 / SFOS 5.x — all hit the hard way)

## White screen / "Could not load page" (component failed to instantiate)

- **`header: PageHeader { ... }` on a `Page`** — Silica `Page` has **no
  `header` property** (that's QtQuick.Controls). Declare `PageHeader` as a
  plain child item. (`header:` IS valid on `SilicaListView`/`SilicaGridView`.)
- **`SilicaButton`** — does not exist. Use plain `Button`.
- **`BackButton`** — does not exist. Use
  `IconButton { icon.source: "image://theme/icon-m-back"; onClicked: pageStack.pop() }`.
- **`if (cond) { SomeItem { ... } }`** — QML has no inline `if` for item
  declaration. Keep the item always instantiated; toggle `visible: cond`.
- **`Theme.paddingTiny`** — not in 5.1/5.2. Use `Theme.paddingSmall / 2`.
- **`import QtQuick.Controls` / `QtQuick.Controls 2`** — don't; Silica
  defines `Page`, `Button`, `Label`, `PageHeader`, etc. itself.
- **`pageStack.push("Page.qml")`** — use
  `pageStack.push(Qt.resolvedUrl("Page.qml"), { "prop": value })`.

## White screen — cause #2: sailjail sandbox, no manifest.json

A white screen is **not always** a QML instantiation failure. A *second*,
independent cause: a sailjail app that ships **no `manifest.json`** dies inside
the (default-**ON**) sailjail sandbox **before its first frame** → white screen,
with no QML error in the journal. The bundled test apps ship a `manifest.json`,
so this one is easy to miss.

- **Diagnose:** after a white screen with no QML error, check the installed
  package: `rpm -ql <app> | grep -E 'manifest.json|applications/'`. If there is
  no `manifest.json` and the `.desktop` has no `[X-Sailjail]` section → this is
  the cause. (`deploy.sh` prints this hint on a launch failure.)
- **Fix (pick one):**
  - ship a `manifest.json` (see `apps/sfsmoke/rpm/sources/manifest.json`), or
  - add to the `.desktop` file:  `[X-Sailjail]` on one line, `Sandboxing=Disabled` on the next.
    (per Jolla docs: `X-Sailjail` … `Sandboxing=Disabled`; note the key is
    `Sandboxing`, not `Sandbox`. Disabling the sandbox is not allowed in the
    Jolla Store, but is fine for your own apps.)
- A `manifest.json` also lets you declare permissions (e.g. `internet`) so the
  app gets network access without a runtime dialog.

## Silent rendering bugs (page loads, content just missing)

- **`Repeater` with a JS-array model is broken (Qt 5.6 / SFOS 5.2).**
  `Repeater { model: myArray }` (property var of objects, or inline
  `model: [{a:1},{a:2}]`) reports the correct `count` but **never
  instantiates delegates** — zero log output. Safe patterns:
  (a) fixed items bound to plain properties, toggled with `visible:`;
  (b) `ListModel {}` + `SilicaListView` with `model.<role>` in the delegate.
- **`Canvas` is risky** — unproven in minimal-QPA harnesses and easy to get
  "not visible" on device. For charts/bars, prefer pure QML items
  (a `Row` of `Rectangle`s with `height` bound to data values).
- **`visible:` bound to a flag set by a JS function** that can early-return
  → empty page. Log the flag during development.
- **Circular width binding → both resolve to 0, no error, text invisible.**
  `Label { width: parent.width - other.width }` where `parent` is the very `Row`
  you are sizing: `parent.width` depends on the label, the label depends on
  `parent.width` → QML breaks the cycle by zeroing, silently. Fix: give the
  inner `Row` an explicit `width: parent.width` (or size only one side). Rule:
  a `width` may only depend on an item that does **not** itself depend on it.

## Qt 5.6 API landmines

- `Timer` has **no `stopped` signal** and **no `elapsed` property**
  (both white-screen). Only `triggered`, `start()`, `stop()`.
- QML `Timer` uses **`repeat`** (singular), not `repeats`.
- Text overflow: **`elide: Text.ElideRight`**. `truncationMode:` is Qt 5.8+
  (silently ignored in 5.6).
- **C++ → QML signal parameters must be named in the C++ declaration**
  (`void pingSample(double latencyMs, bool relayed);`), otherwise the QML
  handler's references fail with `ReferenceError` and abort silently.
- No `QProcess::splitCommand`; `QSortFilterProxyModel::filterFixedString()`
  is private.
- **`QByteArray` has no `.toLocal8Bit()`** — that is a `QString` method; calling
  it on a `QByteArray` is a **compile error**. Convert with
  `QString::fromUtf8(bytes)` (or `QString(bytes.constData(), bytes.size())`).
- `QStringLiteral` strings are **UTF-16** in binaries — `strings`/`grep`
  for them is a false negative.
- Launching other apps: `LauncherItem { filePath: path }` from
  `import org.nemomobile.lipstick 0.1`. `QProcess`-based launch silently
  fails in the app sandbox.
- Focus requests before the window is visible silently fail — retry with a
  `Timer` and verify `activeFocus`.
- mb2's spec parser trips on a literal `%prep` anywhere in the spec (even
  comments) and on undefined `%qmake5` (replace with plain `qmake`/`make`).
- **Debug-log 0444 trap:** never `QFile::setPermissions` on a log file you
  keep appending to without `QFile::WriteOwner` — a setuid-root app can't
  reopen it, and every later append fails **silently**. The log then looks
  like the app died at start (one line), which masks whatever the real bug is.

## D-Bus (Qt 5.6) — silent failure patterns

- **Only `QDBusAbstractAdaptor` subclasses expose methods.** A plain
  `QObject` exposes **nothing** on D-Bus. The adaptor must carry
  `Q_CLASSINFO("D-Bus Interface", "<interface>")`.
- **An adaptor slot returning `QDBusArgument` silently drops the WHOLE
  interface** from introspection — the client gets `UnknownMethod` on every
  method, not just that one. Return a concrete registered metatype that
  serializes to the real signature (e.g. `QList<Entry>` with a struct
  `Entry { QDBusObjectPath; QVariantMap; }` → the real `a(oa{sv})`).
- **`qDBusRegisterMetaType<T>()`** (template call, `#include
  <QtDBus/qdbusmetatype.h>`) registers the D-Bus signature;
  `qRegisterMetaType<T>()` does **not**.
- **Reading complex replies:** `QDBusReply<QList<T>>` can be rejected
  ("Unexpected reply signature … expected \"\"") even with the metatype
  registered. Call into `QDBusReply<QDBusArgument>` and read via a `const
  operator>>` on a **copy** — calling `beginArray()`/`beginStructure()` on
  the reply argument directly is a write on a read-only object →
  `QDBusArgument: write from a read-only object`, then segfault.
- **Verify what actually got exposed** before debugging the client:
  introspect the live bus —
  `dbus-send --system --print-reply --dest=:1.<n> /
  org.freedesktop.DBus.Introspectable.Introspect` (with the app's bus
  address). A service showing up with no methods = one of the rules above
  was violated.

## Privileged D-Bus calls (setuid app pattern)

Mutating D-Bus calls on a system service (e.g. connman VPN
`Connect()`/`Disconnect()`) are refused for sandboxed apps — listing is
open to console users, mutating is not. The proven pattern:
- spec: install the binary **setuid** — `%attr(4755,root,root) ...`;
- C++: `QCoreApplication::setSetuidAllowed(true)` in `main()`;
- spec `%post`: add `root` **and** `defaultuser` to the service's required
  group (e.g. `privileged` for connman-vpn).

## Input-specific (affects tap testing)

- **Z-order:** QML delivers a touch to the **topmost** item at the touch
  point. A `Text` declared after a `MouseArea` covers it and eats the touch
  → the handler never fires. Declare the `MouseArea` **last** and use
  **`onPressed`** (not `onClicked`).
- Declare counter/state properties at the **top** of the component (Qt 5.6
  forward-reference issues with later-declared properties).

## Silica allowlist (5.2 qmldir, verified)

Present: `Page`, `Button`, `IconButton`, `Label`, `PageHeader`, `PageStack`,
`ViewPlaceholder`, `SilicaFlickable`, `SilicaListView`, `SilicaGridView`,
`ListItem`, `VerticalScrollDecorator`, `Switch`, `TextSwitch`,
`IconTextSwitch`, `BusyIndicator`, `ContextMenu`, `MenuItem`, `Drawer`,
`Dialog`, `DetailItem`, `GridItem`, `ProgressBar`. Also plain `QtQuick`:
`Repeater`, `Canvas`, `Row`, `Column`, `Rectangle`.
Absent: `SilicaButton`, `BackButton`, everything from `QtQuick.Controls*`.

## Theme members (5.2, verified present)

`primaryColor`, `secondaryColor`, `highlightColor`,
`highlightBackgroundColor`, `secondaryHighlightColor`, `errorColor`,
`fontSizeExtraSmall/Small/Medium/Large`, `paddingSmall/Medium/Large`,
`horizontalPageMargin`, `pageHeaderHeight`, `rgba(color, alpha)`.
Not present: `paddingTiny`.

## App config & permissions (silent failures — not QML, easy to misread)

- **Seeding app config over root SSH silently breaks the app.** Writing
  `~/.config/<org>/<app>.conf` as root leaves the directory `root:root 700`.
  The app runs as `defaultuser` and cannot traverse a root-only directory →
  `QSettings` reads **zero keys** → the app silently falls back to its
  hard-coded defaults (wrong URL, empty token) and looks "can't connect"
  with no error. After any root-seeded config, hand ownership back to the
  session user, then verify the app actually read it (log
  `QSettings::allKeys()` / the resolved URL at startup):
  ```sh
  chown -R defaultuser:defaultuser ~/.config/<org>
  chmod 700 ~/.config/<org>
  chmod 600 ~/.config/<org>/<app>.conf
  ```
