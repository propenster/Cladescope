import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects

// Bottom-right activity card: shows a live log of steps, a progress bar and a
// rotating "what is it doing now" line while working.
//   begin(title)  step(text, progress0to1)  finish(text)  fail(text)  flash(text)
Item {
    id: root
    width: 340
    height: card.height
    opacity: 0
    visible: opacity > 0.001
    scale: 0.96 + 0.04 * opacity
    transformOrigin: Item.BottomRight

    property string phase: "idle"      // idle | working | done | error
    property string headline: ""
    property real progress: 0
    property int verbIndex: 0
    property int dotCount: 1
    readonly property bool working: phase === "working"
    readonly property var verbs: [
        "Untangling branches", "Consulting the ancestors", "Teaching leaves to align",
        "Rooting around", "Ladderizing quietly", "Polishing clades",
        "Negotiating with polytomies", "Counting tips twice", "Pruning shadows"
    ]

    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    ListModel { id: steps }

    function _show() { hideTimer.stop(); root.opacity = 1 }

    function begin(title) {
        steps.clear()
        headline = title
        progress = 0.03
        phase = "working"
        verbIndex = Math.floor(Math.random() * verbs.length)
        _show()
    }
    function step(text, p) {
        if (phase !== "working") begin(text)
        progress = Math.max(progress, Math.min(p, 0.99))
        if (steps.count === 0 || steps.get(steps.count - 1).label !== text) {
            steps.append({ label: text })
            if (steps.count > 4) steps.remove(0)
        }
    }
    function finish(text) {
        if (phase !== "working") return
        headline = text
        progress = 1
        phase = "done"
        _show()
        hideTimer.interval = 3200
        hideTimer.restart()
    }
    function fail(text) {
        headline = text
        phase = "error"
        _show()
        hideTimer.interval = 6000
        hideTimer.restart()
    }
    function flash(text) {
        if (phase === "working") return
        begin(text)
        finish(text)
    }

    Timer { id: hideTimer; onTriggered: root.opacity = 0 }
    Timer { interval: 1500; repeat: true; running: root.working
            onTriggered: root.verbIndex = (root.verbIndex + 1) % root.verbs.length }
    Timer { interval: 380; repeat: true; running: root.working
            onTriggered: root.dotCount = root.dotCount % 3 + 1 }

    Rectangle {
        id: card
        width: parent.width
        height: content.implicitHeight + 28
        radius: 12
        color: "#ffffff"
        border.color: "#e1e4e8"

        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: "#40000000"
            shadowBlur: 0.7
            shadowVerticalOffset: 4
        }

        MouseArea {
            anchors.fill: parent
            onClicked: if (!root.working) root.opacity = 0
        }

        ColumnLayout {
            id: content
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
            spacing: 9

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Item {
                    Layout.preferredWidth: 20
                    Layout.preferredHeight: 20

                    Item {
                        anchors.fill: parent
                        visible: root.working
                        Rectangle {
                            anchors.fill: parent; radius: 10; color: "transparent"
                            border.width: 2; border.color: "#dbe5fd"
                        }
                        Rectangle { width: 6; height: 6; radius: 3; color: "#2f6fed"; x: 7; y: -1 }
                        RotationAnimator on rotation {
                            from: 0; to: 360; duration: 900
                            loops: Animation.Infinite; running: root.working
                        }
                    }
                    Rectangle {
                        anchors.fill: parent; radius: 10; color: "#28a745"; visible: root.phase === "done"
                        Text { anchors.centerIn: parent; text: "✓"; color: "white"; font.pixelSize: 12; font.bold: true }
                    }
                    Rectangle {
                        anchors.fill: parent; radius: 10; color: "#dc3545"; visible: root.phase === "error"
                        Text { anchors.centerIn: parent; text: "!"; color: "white"; font.pixelSize: 13; font.bold: true }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: root.headline
                    font.pixelSize: 14
                    font.bold: true
                    color: "#1c2128"
                    elide: Text.ElideMiddle
                }
                Text {
                    visible: root.working
                    text: Math.round(root.progress * 100) + "%"
                    font.pixelSize: 12
                    color: "#6b7480"
                }
            }

            Rectangle {
                id: track
                Layout.fillWidth: true
                height: 4
                radius: 2
                color: "#e9ecef"
                clip: true

                Rectangle {
                    width: track.width * root.progress
                    height: parent.height
                    radius: 2
                    color: root.phase === "error" ? "#dc3545" : (root.phase === "done" ? "#28a745" : "#2f6fed")
                    Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
                Rectangle {
                    id: shimmer
                    visible: root.working
                    width: 70; height: parent.height
                    opacity: 0.55
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.5; color: "#ffffff" }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    NumberAnimation on x {
                        from: -70; to: track.width
                        duration: 1100; loops: Animation.Infinite; running: root.working
                    }
                }
            }

            Repeater {
                model: steps
                delegate: RowLayout {
                    id: stepRow
                    required property int index
                    required property string label
                    readonly property bool current: index === steps.count - 1 && root.working
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: stepRow.current ? "›" : "✓"
                        font.pixelSize: 12
                        color: stepRow.current ? "#2f6fed" : "#28a745"
                        Layout.preferredWidth: 10
                    }
                    Text {
                        Layout.fillWidth: true
                        text: stepRow.label
                        font.pixelSize: 12
                        color: stepRow.current ? "#1c2128" : "#8a94a0"
                        elide: Text.ElideRight
                    }
                }
            }

            Text {
                visible: root.working
                text: root.verbs[root.verbIndex] + ".".repeat(root.dotCount)
                font.pixelSize: 11
                font.italic: true
                color: "#8a94a0"
            }
        }
    }
}
