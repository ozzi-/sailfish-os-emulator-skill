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
- `QStringLiteral` strings are **UTF-16** in binaries — `strings`/`grep`
  for them is a false negative.
- Launching other apps: `LauncherItem { filePath: path }` from
  `import org.nemomobile.lipstick 0.1`. `QProcess`-based launch silently
  fails in the app sandbox.
- Focus requests before the window is visible silently fail — retry with a
  `Timer` and verify `activeFocus`.
- mb2's spec parser trips on a literal `%prep` anywhere in the spec (even
  comments) and on undefined `%qmake5` (replace with plain `qmake`/`make`).

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
