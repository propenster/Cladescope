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
            source: root.iconSource
            sourceSize.width: 22; sourceSize.height: 22
            width: 22; height: 22
            layer.enabled: true
            layer.effect: MultiEffect { colorization: 1.0; colorizationColor: "#212121" }
        }
        Text {
            text: root.labelText
            font.pixelSize: 15
            color: "#212121"
        }
    }
}