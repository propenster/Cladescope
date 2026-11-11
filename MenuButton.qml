import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects

Button {
    id: root
    property string iconSource: ""
    property string labelText: ""
    property bool isActive: false

    flat: true
    padding: 8

    // Hover/Active background
    background: Rectangle {
        color: root.isActive ? "#e0e0e0" : (root.hovered ? "#f0f0f0" : "transparent")
        radius: 4
    }

    contentItem: RowLayout {
        spacing: 6
        Image {
            visible: root.iconSource !== ""
            source: root.iconSource
            sourceSize.width: 22; sourceSize.height: 22
            Layout.preferredWidth: root.iconSource !== "" ? 22 : 0
            Layout.preferredHeight: 22
            // layer.enabled: true
            // layer.effect: MultiEffect { colorization: 1.0; colorizationColor: "#212121" }
            opacity: root.enabled ? 1.0 : 0.4
        }
        Text {
            text: root.labelText
            font.pixelSize: 15
            color: root.enabled ? "#212121" : "#a0a7b0"
        }
    }
}
