import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Dialogs

Rectangle {
    id: root
    color: "#ffffff"
    border.color: "#d9dde3"
    border.width: 1
    clip: true

    // Shared view settings object (owned by TreeViewer)
    property QtObject settings: null

    readonly property var layoutKeys: ["rectangular", "slanted", "circular", "radial"]
    readonly property var ladderKeys: ["none", "asc", "desc"]

    function focusSearch() {
        searchField.forceActiveFocus()
        searchField.selectAll()
    }

    function applyColors() {
        root.settings.colorPattern = regexField.text
        root.settings.colorEnabled = regexField.text !== ""
    }

    // Helper to build a field-extraction regex automatically for non-regex users
    function applyFieldExtraction(delimiter, index) {
        // Escaping special regex characters in delimiter if needed
        let escapedDelim = delimiter.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        // Formula: skip N delimiter-separated blocks, then capture the target block
        let pattern = index === 0
            ? "^([^" + escapedDelim + "]+)"
            : "^(?:[^" + escapedDelim + "]+" + escapedDelim + "){" + index + "}([^" + escapedDelim + "]+)";

        regexField.text = pattern;
        root.applyColors();
    }

    // ---------------------------------------------------------- small widgets
    component SectionHeader: Label {
        font.pixelSize: 17
        font.bold: true
        font.family: root.settings ? root.settings.appFontBold : "sans-serif"
        color: "#1c2128"
        Layout.topMargin: 12
    }

    component Caption: Label {
        font.pixelSize: 13
        font.family: root.settings ? root.settings.appFont : "sans-serif"
        color: "#6b7480"
    }

    component ModernCheckBox: CheckBox {
        id: cb
        implicitHeight: 24
        padding: 0
        contentItem: Text {
            text: cb.text
            font.pixelSize: 13
            font.family: root.settings ? root.settings.appFont : "sans-serif"
            color: "#1c2128"
            leftPadding: cb.indicator.width + cb.spacing
            verticalAlignment: Text.AlignVCenter
        }
        indicator: Rectangle {
            implicitWidth: 16; implicitHeight: 16
            x: cb.leftPadding
            y: parent.height / 2 - height / 2
            radius: 3
            color: cb.checked ? "#2f6fed" : "transparent"
            border.color: cb.checked ? "#2f6fed" : "#b9c0c9"
            border.width: 1
            Text {
                text: "✓"; color: "white"; font.pixelSize: 11; font.bold: true
                visible: cb.checked; anchors.centerIn: parent
            }
        }
    }

    component ModernSlider: Slider {
        id: slider
        implicitHeight: 24
        background: Rectangle {
            x: slider.leftPadding
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            implicitWidth: 200; implicitHeight: 4
            width: slider.availableWidth; height: implicitHeight
            radius: 2; color: "#e9ecef"
            Rectangle { width: slider.visualPosition * parent.width; height: parent.height; color: "#2f6fed"; radius: 2 }
        }
        handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + slider.availableHeight / 2 - height / 2
            implicitWidth: 16; implicitHeight: 16; radius: 8
            color: "#ffffff"; border.color: "#2f6fed"; border.width: 2
        }
    }

    component SoftButton: Button {
        id: sb
        property bool primary: false
        font.pixelSize: 12
        font.family: root.settings ? root.settings.appFont : "sans-serif"
        padding: 6
        leftPadding: 10
        rightPadding: 10
        background: Rectangle {
            radius: 5
            color: sb.primary ? (sb.down ? "#2559c4" : "#2f6fed") : (sb.hovered ? "#e3e7ec" : "#eef1f5")
            opacity: sb.enabled ? 1 : 0.5
        }
        contentItem: Text {
            text: sb.text
            font: sb.font
            color: sb.primary ? "white" : "#1c2128"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            opacity: sb.enabled ? 1 : 0.5
        }
    }

    component SegButton: Button {
        id: seg
        property bool active: false
        property bool leftEdge: true
        font.pixelSize: 12
        font.family: root.settings ? root.settings.appFont : "sans-serif"
        padding: 6; leftPadding: 10; rightPadding: 10
        background: Rectangle {
            color: seg.active ? "#2f6fed" : "#ffffff"
            border.color: seg.active ? "#2f6fed" : "#d9dde3"
            radius: 4
            Rectangle {
                width: 4; height: parent.height
                anchors.right: seg.leftEdge ? parent.right : undefined
                anchors.left: seg.leftEdge ? undefined : parent.left
                color: parent.color
                border.color: parent.border.color
                border.width: 0
            }
        }
        contentItem: Text {
            text: seg.text; font: seg.font
            color: seg.active ? "white" : "#1c2128"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // ---------------------------------------------------------------- content
    ScrollView {
        id: scroll
        anchors.fill: parent
        anchors.margins: 14
        clip: true
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            width: scroll.availableWidth
            spacing: 10

            // ------------------------------------------------------ LAYOUT
            SectionHeader { text: "Layout"; Layout.topMargin: 0 }
            ComboBox {
                Layout.fillWidth: true
                Layout.preferredHeight: 35
                font.family: root.settings ? root.settings.appFont : "sans-serif"
                font.pixelSize: 13
                model: ["Rectangular", "Slanted", "Circular", "Radial (unrooted)"]
                currentIndex: root.settings ? Math.max(0, root.layoutKeys.indexOf(root.settings.layoutType)) : 0
                onActivated: (i) => root.settings.layoutType = root.layoutKeys[i]
            }

            RowLayout {
                Layout.fillWidth: true
                Caption { text: "Branches"; Layout.fillWidth: true }
                Row {
                    spacing: 0
                    SegButton {
                        text: "Phylogram"; leftEdge: true
                        active: root.settings && root.settings.useBranchLengths
                        onClicked: root.settings.useBranchLengths = true
                    }
                    SegButton {
                        text: "Cladogram"; leftEdge: false
                        active: root.settings && !root.settings.useBranchLengths
                        onClicked: root.settings.useBranchLengths = false
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Caption { text: "Order"; Layout.fillWidth: true }
                ComboBox {
                    implicitWidth: 150
                    font.family: root.settings ? root.settings.appFont : "sans-serif"
                    font.pixelSize: 12
                    Layout.preferredHeight: 35
                    model: ["Original", "Ladderize ▲", "Ladderize ▼"]
                    currentIndex: root.settings ? Math.max(0, root.ladderKeys.indexOf(root.settings.ladderize)) : 0
                    onActivated: (i) => root.settings.ladderize = root.ladderKeys[i]
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: "#e9ecef"; Layout.topMargin: 4 }

            // ----------------------------------------------------- DISPLAY
            SectionHeader { text: "Display" }
            GridLayout {
                columns: 2; Layout.fillWidth: true; rowSpacing: 8; columnSpacing: 6
                ModernCheckBox { text: "Tip labels"; checked: root.settings ? root.settings.showTips : true
                               onToggled: root.settings.showTips = checked }
                ModernCheckBox { text: "Align tips"; checked: root.settings ? root.settings.alignTips : false
                               onToggled: root.settings.alignTips = checked }
                ModernCheckBox { text: "Node dots"; checked: root.settings ? root.settings.showNodeDots : false
                               onToggled: root.settings.showNodeDots = checked }
                ModernCheckBox { text: "Scale bar"; checked: root.settings ? root.settings.showScale : true
                               onToggled: root.settings.showScale = checked }
                ModernCheckBox { text: "Support values"; checked: root.settings ? root.settings.showSupport : false
                               onToggled: root.settings.showSupport = checked }
                ModernCheckBox { text: "Branch lengths"; checked: root.settings ? root.settings.showLengths : false
                               onToggled: root.settings.showLengths = checked }
                ModernCheckBox { text: "Compress long branches"; Layout.columnSpan: 2
                               checked: root.settings ? root.settings.breakLongBranches : true
                               onToggled: root.settings.breakLongBranches = checked }
            }

            RowLayout {
                Layout.fillWidth: true
                Caption { text: "Font size"; Layout.fillWidth: true }
                Label {
                    text: root.settings ? Math.round(root.settings.fontSize) : ""
                    font.pixelSize: 13; color: "#1c2128"
                    Layout.preferredWidth: 36; horizontalAlignment: Text.AlignRight
                }
            }
            ModernSlider {
                Layout.fillWidth: true
                from: 6; to: 28; stepSize: 1
                value: root.settings ? root.settings.fontSize : 12
                onMoved: root.settings.fontSize = value
            }

            RowLayout {
                Layout.fillWidth: true
                Caption { text: "Tree font"; Layout.fillWidth: true }
                ComboBox {
                    id: fontCombo
                    implicitWidth: 170
                    font.family: root.settings ? root.settings.appFont : "sans-serif"
                    font.pixelSize: 12
                    model: root.settings ? root.settings.fontOptions : []
                    textRole: "label"
                    currentIndex: {
                        if (!root.settings) return 0
                        var o = root.settings.fontOptions
                        for (var i = 0; i < o.length; i++) if (o[i].family === root.settings.treeFont) return i
                        return 0
                    }
                    onActivated: (i) => root.settings.treeFont = root.settings.fontOptions[i].family
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Caption { text: "Line width"; Layout.fillWidth: true }
                Label {
                    text: root.settings ? root.settings.lineWidth.toFixed(2) : ""
                    font.pixelSize: 13; color: "#1c2128"
                    Layout.preferredWidth: 36; horizontalAlignment: Text.AlignRight
                }
            }
            ModernSlider {
                Layout.fillWidth: true
                from: 0.5; to: 5.0; stepSize: 0.25
                value: root.settings ? root.settings.lineWidth : 1.5
                onMoved: root.settings.lineWidth = value
            }

            RowLayout {
                Layout.fillWidth: true
                Caption { text: "Branch color"; Layout.fillWidth: true }
                Rectangle {
                    width: 26; height: 26; radius: 5
                    color: root.settings ? root.settings.branchColor : "#333a44"
                    border.color: "#b9c0c9"
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { colorDialog.selectedColor = root.settings.branchColor; colorDialog.open() }
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: "#e9ecef"; Layout.topMargin: 4 }

            // ------------------------------------------------------ METADATA
            SectionHeader { text: "Metadata" }
            Caption {
                text: "Import a CSV or TSV table. The column whose values match your tip names becomes the key; every other column can be used for coloring."
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                SoftButton {
                    text: "Import table…"; primary: true
                    Layout.fillWidth: true
                    onClicked: root.settings.importMetadataRequested()
                }
                SoftButton {
                    visible: root.settings && root.settings.metaColumns.length > 0
                    text: "Remove"
                    onClicked: root.settings.clearMetadataRequested()
                }
            }
            Caption {
                visible: root.settings && root.settings.metaSummary !== ""
                text: root.settings ? root.settings.metaSummary : ""
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: "#e9ecef"; Layout.topMargin: 4 }

            // ----------------------------------------------------------- COLOR BY
            SectionHeader { text: "Color by" }

            RowLayout {
                Layout.fillWidth: true
                Caption { text: "Source"; Layout.fillWidth: true }
                ComboBox {
                    id: sourceCombo
                    implicitWidth: 170
                    Layout.preferredHeight: 35
                    font.family: root.settings ? root.settings.appFont : "sans-serif"
                    font.pixelSize: 12
                    model: root.settings ? ["Tip names"].concat(root.settings.metaColumns) : ["Tip names"]
                    currentIndex: root.settings ? Math.max(0, root.settings.metaColumns.indexOf(root.settings.colorColumn) + 1) : 0
                    onActivated: (i) => root.settings.colorColumn = (i === 0 ? "" : root.settings.metaColumns[i - 1])
                }
            }

            Caption {
                text: root.settings && root.settings.colorColumn !== ""
                      ? "Each distinct value in the column becomes a color. Add a pattern below to use only part of the value."
                      : "Match part of each tip name; every distinct match becomes a color category. A (group) is used if present."
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            TextField {
                id: regexField
                Layout.fillWidth: true
                font.pixelSize: 12
                font.family: root.settings ? root.settings.appFont : "sans-serif"
                placeholderText: "e.g. (\\d{4})  or  _([A-Za-z]+)_"
                padding: 6
                selectByMouse: true
                onAccepted: root.applyColors()
                background: Rectangle {
                    radius: 4
                    color: "#ffffff"
                    border.color: (root.settings && root.settings.regexError !== "") ? "#dc3545"
                                 : (regexField.activeFocus ? "#2f6fed" : "#d9dde3")
                }
            }

            Label {
                visible: root.settings && root.settings.regexError !== ""
                text: root.settings ? root.settings.regexError : ""
                color: "#dc3545"
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            // Quick Preset Buttons
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Repeater {
                    model: [
                        { t: "Year", p: "((?:19|20)\\d{2})" },
                        { t: "Date", p: "(\\d{4}-\\d{2}-\\d{2})" },
                        { t: "2nd field", p: "^[^_|]+[_|]([^_|]+)" },
                        { t: "Last field", p: "([^_|]+)$" }
                    ]
                    delegate: SoftButton {
                        required property var modelData
                        text: modelData.t
                        onClicked: { regexField.text = modelData.p; root.applyColors() }
                    }
                }
            }

            // Non-Regex Field Picker Helper Row
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                Layout.topMargin: 4

                ComboBox {
                    id: delimCombo
                    Layout.preferredHeight: 35
                    Layout.preferredWidth: 65
                    font.pixelSize: 12
                    model: ["/", "|", "_", "-"]
                }

                SpinBox {
                    id: indexSpinBox
                    Layout.preferredWidth: 80
                    Layout.preferredHeight: 35
                    from: 0; to: 20; value: 2
                }

                SoftButton {
                    text: "Pick Field"
                    Layout.fillWidth: true
                    onClicked: {
                        root.applyFieldExtraction(delimCombo.displayText, indexSpinBox.value)
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Layout.topMargin: 4
                SoftButton {
                    text: "Apply"; primary: true
                    Layout.fillWidth: true
                    onClicked: root.applyColors()
                }
                SoftButton {
                    text: "Clear"
                    Layout.fillWidth: true
                    onClicked: {
                        regexField.text = ""
                        root.settings.colorPattern = ""
                        root.settings.colorEnabled = false
                        root.settings.colorColumn = ""
                    }
                }
            }

            ModernCheckBox {
                text: "Color branches of uniform clades"
                checked: root.settings ? root.settings.colorBranches : true
                onToggled: root.settings.colorBranches = checked
            }

            Caption {
                visible: root.settings && (root.settings.colorEnabled || root.settings.colorColumn !== "")
                         && root.settings.regexError === ""
                text: root.settings && root.settings.categoryCount > 0
                    ? root.settings.categoryCount + " categories found"
                    : "Nothing matches — check the pattern or column"
                font.pixelSize: 12
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: "#e9ecef"; Layout.topMargin: 4 }

            // ----------------------------------------------------------- SEARCH
            SectionHeader { text: "Search" }

            RowLayout {
                Layout.fillWidth: true
                TextField {
                    id: searchField
                    Layout.fillWidth: true
                    font.pixelSize: 13
                    font.family: root.settings ? root.settings.appFont : "sans-serif"
                    placeholderText: "Search tip names…  (Ctrl+F)"
                    padding: 6
                    selectByMouse: true
                    onTextChanged: root.settings.searchQuery = text
                    onAccepted: root.settings.findNext()
                    background: Rectangle {
                        radius: 4; color: "#ffffff"
                        border.color: searchField.activeFocus ? "#2f6fed" : "#d9dde3"
                    }
                }
                SoftButton {
                    visible: searchField.text !== ""
                    text: "✕"
                    onClicked: searchField.text = ""
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                ModernCheckBox {
                    text: "Regex"
                    checked: root.settings ? root.settings.searchRegex : false
                    onToggled: root.settings.searchRegex = checked
                }
                ModernCheckBox {
                    text: "Case sensitive"
                    checked: root.settings ? root.settings.searchCase : false
                    onToggled: root.settings.searchCase = checked
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: searchField.text !== ""
                Caption {
                    text: root.settings ? (root.settings.matchCount + (root.settings.matchCount === 1 ? " match" : " matches")) : ""
                    Layout.fillWidth: true
                }
                SoftButton { text: "▲"; enabled: root.settings && root.settings.matchCount > 0; onClicked: root.settings.findPrev() }
                SoftButton { text: "▼"; enabled: root.settings && root.settings.matchCount > 0; onClicked: root.settings.findNext() }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: searchField.text !== "" && root.settings && root.settings.matchCount > 0
                SoftButton { text: "Select all"; Layout.fillWidth: true
                             onClicked: root.settings.pickMatches() }
                SoftButton { text: "Copy names"; Layout.fillWidth: true
                             onClicked: root.settings.copyMatches() }
            }

            Item { Layout.preferredHeight: 10 }
        }
    }

    ColorDialog {
        id: colorDialog
        title: "Branch color"
        onAccepted: root.settings.branchColor = selectedColor
    }
}
