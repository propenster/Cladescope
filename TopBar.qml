import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import QtQuick.Controls.Basic

Rectangle {
    id: topBar
    width: parent.width
    height: 50
    color: "#ffffff"
    border.color: "#e1e4e8"
    border.width: 1
    property int currentViewIndex: 0
    signal viewChanged(int index)

    RowLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 20

        // Left items
        RowLayout {
            spacing: 6
            Image {
                source: "qrc:/ui/assets/icons/file_open_24dp.svg"
                sourceSize.width: 22; sourceSize.height: 22
                width: 22; height: 22
                layer.enabled: true
                layer.effect: MultiEffect { colorization: 1.0; colorizationColor: "#212121" }
            }
            Text { text: "File"; font.pixelSize: 15; color: "#212121" }

        }


        RowLayout {
            spacing: 6
            Image {
                source: "qrc:/ui/assets/icons/view_quilt_24dp.svg"
                sourceSize.width: 22; sourceSize.height: 22
                width: 22; height: 22
                layer.enabled: true
                layer.effect: MultiEffect { colorization: 1.0; colorizationColor: "#212121" }
            }
            Text { text: "Quick Layouts"; font.pixelSize: 15; color: "#212121" }
        }

        RowLayout {
            spacing: 6
            Image {
                source: "qrc:/ui/assets/icons/speed_24dp.svg"
                sourceSize.width: 22; sourceSize.height: 22
                width: 22; height: 22
                layer.enabled: true
                layer.effect: MultiEffect { colorization: 1.0; colorizationColor: "#212121" }
            }
            Text { text: "Performance Mode"; font.pixelSize: 15; color: "#212121" }
        }

        RowLayout {
            spacing: 6
            Image {
                source: "qrc:/ui/assets/icons/stacked_bar_chart_24dp.svg"
                sourceSize.width: 22; sourceSize.height: 22
                width: 22; height: 22
                layer.enabled: true
                layer.effect: MultiEffect { colorization: 1.0; colorizationColor: "#212121" }
            }
            Text { text: "Data Overlay"; font.pixelSize: 15; color: "#212121" }
        }

        Item { Layout.fillWidth: true } // Spacer

        // Right items
        RowLayout {
            spacing: 6
            Image {
                source: "qrc:/ui/assets/icons/settings_24dp.svg"
                sourceSize.width: 20; sourceSize.height: 20
                width: 20; height: 20
                layer.enabled: true
                layer.effect: MultiEffect { colorization: 1.0; colorizationColor: "#212121" }
            }
            Text { text: "Settings"; font.pixelSize: 15; color: "#212121" }
        }


    }
}