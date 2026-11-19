import QtQuick 2.2
import QtQuick.Window 2.0

Window {
    id: root
    width: 360
    height: 740
    visible: true
    title: "harbour-cpp"

    // Declared FIRST so no QML forward-reference binding issue (Qt 5.6).
    property int taps: 0

    Column {
        anchors.centerIn: parent
        spacing: 16

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "C++ app — from Bionic!"
            font.pixelSize: 28
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Compiled on the engine (Qt 5.6 / C++)"
            font.pixelSize: 14
            opacity: 0.7
        }

        // "version" comes from C++ via engine.rootContext()->setContextProperty()
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "C++ context version: " + version
            font.pixelSize: 14
            opacity: 0.7
        }

        // Big, high-contrast counter -> trivial to verify with a screenshot diff.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "TAPS: " + root.taps
            font.pixelSize: 48
            font.bold: true
            color: "steelblue"
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "(tap anywhere)"
            font.pixelSize: 12
            opacity: 0.5
        }
    }

    // MouseArea declared LAST so it is the TOPMOST item. QML delivers a touch
    // to the topmost item at the touch point; if a Text (no handler) is on top,
    // the touch is lost. Putting the MouseArea on top catches every tap.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onPressed: {
            root.taps++
            Qt.outputDebug("TAP count=" + root.taps + " at " + Math.round(mouse.x) + "," + Math.round(mouse.y))
        }
    }
}