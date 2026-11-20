import QtQuick 2.2
import QtQuick.Window 2.0

// ═════════════════════════════════════════════════════════════
// SMOKE-TEST CANARY — layout contract (smoke.sh T2 depends on this):
//   * ONE label "TAPS: <n>", centered on the screen, large + bold
//   * the WHOLE screen is a MouseArea; every press increments the counter
// Do not add chrome, animations, or extra elements — the pixel-diff check
// compares a box around screen center before/after three taps.
// ═════════════════════════════════════════════════════════════
Window {
    id: root
    width: 360
    height: 740
    visible: true
    title: "harbour-sfsmoke"

    property int taps: 0

    Text {
        anchors.centerIn: parent
        text: "TAPS: " + root.taps
        font.pixelSize: 64
        font.bold: true
        color: "steelblue"
    }

    // MouseArea LAST = topmost, so it catches every touch (QML-GOTCHAS.md).
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onPressed: root.taps++
    }
}
