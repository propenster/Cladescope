import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import QtQuick.Dialogs
import com.qtree.backend 1.0

ApplicationWindow {
    id: window
    width: 1280
    height: 760
    minimumWidth: 900
    minimumHeight: 560
    visible: true
    title: "qTree" + (treeModel.fileName !== "" ? " — " + treeModel.fileName : "")
    color: "#f6f7f9"

    readonly property bool hasTree: treeModel.fileName !== ""
    readonly property var vs: viewer.settings

    function setLayout(type, lengths) {
        vs.layoutType = type
        vs.useBranchLengths = lengths
    }
    function radio(on, text) { return (on ? "●  " : "○  ") + text }

    // ------------------------------------------------------------ C++ BACKEND
    TreeModel { id: treeModel }

    Connections {
        target: treeModel
        function onLoadStarted(name) { toast.begin("Opening " + name) }
        function onProgress(stage, fraction) { toast.step(stage, fraction * 0.9) }
        function onTreeLoaded() {
            toast.step("Drawing tree", 0.93)
            viewStack.currentIndex = 1
        }
        function onErrorOccurred(message) {
            toast.fail("Couldn't load tree")
            errorDialog.text = message
            errorDialog.open()
        }
    }

    Connections {
        target: viewer
        function onRenderFinished(ms, tips, nodes) {
            toast.step("Rendering", 0.97)
            toast.finish("Tree ready · " + tips + " tips · " + ms + " ms")
        }
        function onNotify(text) { toast.flash(text) }
        function onGraphicsRequested() { graphicsDialog.open() }
    }

    // ---------------------------------------------------------------- DIALOGS
    MessageDialog {
        id: errorDialog
        title: "Error Loading File"
        text: "Unknown error"
        buttons: MessageDialog.Ok
    }

    FileDialog {
        id: openFileDialog
        title: "Open Phylogenetic Tree File"
        nameFilters: [
            "Phylogenetic Trees (*.tre *.tree *.trees *.nwk *.newick *.nexus *.nex)",
            "Newick Files (*.nwk *.newick)",
            "Tree Files (*.tre *.tree *.trees)",
            "Nexus Files (*.nexus *.nex)",
            "All files (*)"
        ]
        onAccepted: treeModel.loadFile(selectedFile)
    }

    FileDialog {
        id: saveNewickDialog
        title: "Save Tree as Newick"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "nwk"
        nameFilters: ["Newick Files (*.nwk *.newick)", "All files (*)"]
        onAccepted: {
            if (treeModel.saveNewick(selectedFile)) toast.flash("Saved Newick file")
        }
    }

    FileDialog {
        id: exportImageDialog
        title: "Export Tree Image"
        fileMode: FileDialog.SaveFile
        defaultSuffix: "png"
        nameFilters: ["PNG image (*.png)"]
        onAccepted: {
            var ok = viewer.exportImage(treeModel.localPath(selectedFile))
            toast.flash(ok ? "Image exported" : "Export failed")
        }
    }

    Dialog {
        id: helpDialog
        title: "Keyboard & mouse"
        modal: true
        anchors.centerIn: Overlay.overlay
        standardButtons: Dialog.Close
        width: 480
        contentItem: Label {
            textFormat: Text.RichText
            wrapMode: Text.WordWrap
            lineHeight: 1.25
            text: "<b>Wheel</b> — zoom at cursor (big trees zoom mostly vertically)<br>" +
                  "<b>Shift + wheel</b> — vertical zoom only &nbsp; <b>Ctrl + wheel</b> — horizontal only<br>" +
                  "<b>Drag</b> — pan<br>" +
                  "<b>Shift + drag</b> — draw a box and zoom into it (or use the ⬚ tool)<br>" +
                  "<b>Click</b> a node — select clade<br>" +
                  "<b>Double-click</b> a tip or label — highlight it &nbsp;·&nbsp; a clade — collapse / expand<br>" +
                  "<b>Ctrl/Cmd + click</b> — add tips (or a whole clade) to the highlighted set<br>" +
                  "<b>Ctrl/Cmd + C</b> — copy highlighted labels, one per line<br>" +
                  "<b>Esc</b> — clear selection &nbsp; <b>Ctrl+F</b> — search &nbsp; <b>Ctrl+0</b> — fit<br>" +
                  "<b>≡</b> button — spread tips so every label is legible &nbsp; <b>↶</b> — previous view<br>" +
                  "<b>Drop a file</b> on the window to open it"
        }
    }

    Dialog {
        id: graphicsDialog
        title: "Graphics & performance"
        modal: true
        anchors.centerIn: Overlay.overlay
        width: 480
        standardButtons: Dialog.Close

        readonly property var prefKeys: ["auto", "opengl", "software"]

        contentItem: ColumnLayout {
            spacing: 10
            GridLayout {
                columns: 2
                columnSpacing: 14
                rowSpacing: 6
                Label { text: "Graphics API"; color: "#6b7480" }
                Label { text: appBridge.api !== "" ? appBridge.api : "detecting…"; font.bold: true }
                Label { text: "GPU"; color: "#6b7480" }
                Label {
                    text: appBridge.gpuName !== "" ? appBridge.gpuName
                          : (appBridge.hardware ? "reported by the driver only for OpenGL" : "none (software rendering)")
                    font.bold: true
                    wrapMode: Text.WordWrap
                    Layout.maximumWidth: 300
                }
                Label { text: "Tree canvas"; color: "#6b7480" }
                Label {
                    text: appBridge.canGpuCanvas ? "GPU-accelerable (OpenGL framebuffer)"
                          : "CPU raster — needs the OpenGL backend for GPU drawing"
                    font.bold: true
                    wrapMode: Text.WordWrap
                    Layout.maximumWidth: 300
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: "#e9ecef" }

            Label { text: "Graphics backend (applied on next start)"; font.bold: true }
            ComboBox {
                id: backendCombo
                Layout.fillWidth: true
                model: ["Automatic (Qt default for this OS)",
                        "OpenGL — enables the GPU canvas for big trees",
                        "Software — no GPU, most compatible"]
                currentIndex: Math.max(0, graphicsDialog.prefKeys.indexOf(appBridge.backendPref))
            }
            RowLayout {
                spacing: 8
                Button {
                    text: "Save"
                    onClicked: {
                        appBridge.setBackendPref(graphicsDialog.prefKeys[backendCombo.currentIndex])
                        toast.flash("Backend saved — takes effect on restart")
                    }
                }
                Button {
                    text: "Save & restart"
                    onClicked: {
                        appBridge.setBackendPref(graphicsDialog.prefKeys[backendCombo.currentIndex])
                        appBridge.restart()
                    }
                }
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#8a94a0"
                font.pixelSize: 12
                text: "With Renderer set to Auto, the tree switches to the GPU canvas automatically above ~3,000 tips when a hardware OpenGL backend is active."
            }
        }
    }

    Shortcut { sequences: [StandardKey.Open]; onActivated: openFileDialog.open() }
    Shortcut { sequence: "Ctrl+0"; enabled: window.hasTree; onActivated: vs.fitView() }

    // ------------------------------------------------------------------ MENUS
    Menu {
        id: fileMenu
        MenuItem { text: "Open Tree File…"; onTriggered: openFileDialog.open() }
        MenuItem { text: "Load Example Tree"; onTriggered: treeModel.loadExample() }
        MenuSeparator {}
        MenuItem { text: "Save as Newick…"; enabled: window.hasTree; onTriggered: saveNewickDialog.open() }
        MenuItem { text: "Export Image…"; enabled: window.hasTree; onTriggered: exportImageDialog.open() }
        MenuSeparator {}
        MenuItem { text: "Exit"; onTriggered: Qt.quit() }
    }

    Menu {
        id: layoutMenu
        MenuItem { text: "Rectangular cladogram"; onTriggered: window.setLayout("rectangular", false) }
        MenuItem { text: "Rectangular phylogram"; onTriggered: window.setLayout("rectangular", true) }
        MenuItem { text: "Slanted cladogram"; onTriggered: window.setLayout("slanted", false) }
        MenuItem { text: "Circular phylogram"; onTriggered: window.setLayout("circular", true) }
        MenuItem { text: "Circular cladogram"; onTriggered: window.setLayout("circular", false) }
        MenuItem { text: "Radial (unrooted) phylogram"; onTriggered: window.setLayout("radial", true) }
    }

    Menu {
        id: perfMenu
        MenuItem {
            text: window.radio(vs.performanceMode, "Lighter drawing while panning / zooming")
            onTriggered: vs.performanceMode = !vs.performanceMode
        }
        MenuSeparator {}
        MenuItem {
            text: window.radio(vs.renderMode === "auto", "Renderer: Auto (GPU for large trees)")
            onTriggered: vs.renderMode = "auto"
        }
        MenuItem {
            text: window.radio(vs.renderMode === "gpu", "Renderer: Always GPU") + (appBridge.canGpuCanvas ? "" : "  (unavailable)")
            enabled: appBridge.canGpuCanvas
            onTriggered: vs.renderMode = "gpu"
        }
        MenuItem {
            text: window.radio(vs.renderMode === "cpu", "Renderer: Always CPU")
            onTriggered: vs.renderMode = "cpu"
        }
        MenuSeparator {}
        MenuItem { text: "Graphics info & backend…"; onTriggered: graphicsDialog.open() }
    }

    Menu {
        id: dataMenu
        MenuItem { text: "Support values"; checkable: true
                   checked: vs.showSupport; onToggled: vs.showSupport = checked }
        MenuItem { text: "Branch lengths"; checkable: true
                   checked: vs.showLengths; onToggled: vs.showLengths = checked }
        MenuItem { text: "Color uniform clades"; checkable: true
                   checked: vs.colorBranches; onToggled: vs.colorBranches = checked }
    }

    Menu {
        id: settingsMenu
        MenuItem { text: "Fit to window"; enabled: window.hasTree; onTriggered: vs.fitView() }
        MenuItem { text: "Reset display options"; onTriggered: vs.reset() }
        MenuSeparator {}
        MenuItem { text: "Keyboard & mouse…"; onTriggered: helpDialog.open() }
    }

    // ---------------------------------------------------------------- TOP BAR
    header: Rectangle {
        height: 52
        color: "#ffffff"

        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#e1e4e8" }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 4

            MenuButton {
                id: fileBtn
                iconSource: "qrc:/ui/assets/icons/file_open_24dp.svg"
                labelText: "File"
                isActive: fileMenu.visible
                onClicked: fileMenu.popup(fileBtn, 0, fileBtn.height)
            }
            MenuButton {
                id: layoutBtn
                iconSource: "qrc:/ui/assets/icons/view_quilt_24dp.svg"
                labelText: "Quick Layouts"
                enabled: window.hasTree
                isActive: layoutMenu.visible
                onClicked: layoutMenu.popup(layoutBtn, 0, layoutBtn.height)
            }
            MenuButton {
                id: perfBtn
                iconSource: "qrc:/ui/assets/icons/speed_24dp.svg"
                labelText: "Performance"
                isActive: vs.performanceMode || perfMenu.visible
                onClicked: perfMenu.popup(perfBtn, 0, perfBtn.height)
            }
            MenuButton {
                id: dataBtn
                iconSource: "qrc:/ui/assets/icons/stacked_bar_chart_24dp.svg"
                labelText: "Data Overlay"
                enabled: window.hasTree
                isActive: dataMenu.visible
                onClicked: dataMenu.popup(dataBtn, 0, dataBtn.height)
            }

            Item { Layout.fillWidth: true }

            MenuButton {
                id: settingsBtn
                iconSource: "qrc:/ui/assets/icons/settings_24dp.svg"
                labelText: "Settings"
                isActive: settingsMenu.visible
                onClicked: settingsMenu.popup(settingsBtn, settingsBtn.width - settingsMenu.implicitWidth, settingsBtn.height)
            }
        }
    }

    // ---------------------------------------------------- MAIN CONTENT STACK
    StackLayout {
        id: viewStack
        anchors.fill: parent
        currentIndex: 0

        // VIEW 0: START SCREEN
        RowLayout {
            spacing: 40
            Layout.margins: 40

            ColumnLayout {
                Layout.preferredWidth: 450
                Layout.fillHeight: true
                spacing: 25

                Item { Layout.fillHeight: true }

                RowLayout {
                    spacing: 10
                    Image {
                        source: "qrc:/ui/assets/icons/picsvg_modified.svg"
                        sourceSize.width: 120; sourceSize.height: 120
                        Layout.preferredWidth: 120; Layout.preferredHeight: 120
                        fillMode: Image.PreserveAspectFit
                        layer.enabled: true
                        layer.effect: MultiEffect { colorization: 1.0; colorizationColor: "#212121" }
                    }
                    Text {
                        text: "qTree"
                        font.pixelSize: 42
                        font.bold: true
                        color: "#212121"
                        Layout.alignment: Qt.AlignVCenter
                    }
                }

                Text {
                    text: "Welcome to qTree: Next-Gen Phylogenetics"
                    font.pixelSize: 28
                    color: "#6c757d"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }

                RowLayout {
                    spacing: 15
                    Layout.topMargin: 6
                    Button {
                        text: "Open File"
                        font.pixelSize: 20
                        padding: 12
                        Layout.preferredWidth: 150
                        onClicked: openFileDialog.open()
                    }
                    Button {
                        text: "Try an example"
                        flat: true
                        font.pixelSize: 20
                        padding: 12
                        onClicked: treeModel.loadExample()
                    }
                }

                Text {
                    text: "…or drop a .nwk / .tre / .nex file anywhere on this window."
                    font.pixelSize: 14
                    color: "#8a94a0"
                }

                Item { Layout.fillHeight: true }
            }

            Item {
                Layout.minimumWidth: 400
                Layout.fillWidth: true
                Layout.fillHeight: true

                Image {
                    width: Math.min(parent.width, parent.height) * 0.95
                    height: width
                    x: (parent.width - width) / 2
                    y: (parent.height - height) / 2
                    source: "qrc:/ui/assets/icons/picsvg_modified.svg"
                    fillMode: Image.PreserveAspectFit
                    opacity: 0.85
                    layer.enabled: true
                    layer.effect: MultiEffect { colorization: 1.0; colorizationColor: "#212121" }
                }
            }
        }

        // VIEW 1: TREE VIEWER
        TreeViewer {
            id: viewer
            treeModel: treeModel
        }
    }

    // ------------------------------------------------------- DROP TO OPEN
    DropArea {
        id: dropArea
        anchors.fill: parent
        onDropped: (drop) => { if (drop.hasUrls) treeModel.loadFile(drop.urls[0]) }
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: 12
        visible: dropArea.containsDrag
        color: "#1a2f6fed"
        border.color: "#2f6fed"
        border.width: 2
        radius: 12
        z: 50
        Text {
            anchors.centerIn: parent
            text: "Drop to open tree"
            font.pixelSize: 26
            font.bold: true
            color: "#2f6fed"
        }
    }

    // --------------------------------------------------------- ACTIVITY TOAST
    StatusToast {
        id: toast
        z: 100
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 18
        anchors.bottomMargin: 46
    }
}
