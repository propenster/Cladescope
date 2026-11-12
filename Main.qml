import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import QtQuick.Dialogs
import com.cladescope.backend 1.0

ApplicationWindow {
    id: window
    width: 1280
    height: 760
    minimumWidth: 900
    minimumHeight: 560
    visible: true
    title: "Cladescope" + (treeModel.fileName !== "" ? " — " + treeModel.fileName : "")
    color: "#f6f7f9"
    palette {
        window: "#ffffff"
        windowText: "#1c2128"
        base: "#ffffff"
        alternateBase: "#f6f7f9"
        text: "#1c2128"
        button: "#eef1f5"
        buttonText: "#1c2128"
        highlight: "#2f6fed"
        highlightedText: "#ffffff"
        mid: "#d9dde3"
        dark: "#b9c0c9"
        light: "#ffffff"
        placeholderText: "#6b7480"
        toolTipBase: "#1c2128"
        toolTipText: "#ffffff"
    }

    readonly property bool hasTree: treeModel.fileName !== ""
    readonly property var vs: viewer.settings
    property string editNote: ""      // set by backend edits, shown in the finish toast
    property string exportPath: ""
    property string exportFmt: "svg"

    Component.onCompleted: {
        if (appBridge.startupFile !== "") window.openTreePath(appBridge.startupFile)
    }

    function setLayout(type, lengths) {
        vs.layoutType = type
        vs.useBranchLengths = lengths
    }
    function radio(on, text) { return (on ? "●  " : "○  ") + text }

    property string pendingRecent: ""

    // Open a tree: in this window if it's empty, otherwise in a new window
    function openTreePath(path) {
        if (path === "") return
        if (!appBridge.fileExists(path)) {
            appBridge.removeRecent(path)
            toast.flash("File not found: " + path)
            return
        }
        if (window.hasTree) {
            if (appBridge.openFileInNewWindow(path)) toast.flash("Opening in a new window…")
            else toast.flash("Could not open a new window")
            return
        }
        window.pendingRecent = path
        treeModel.loadPath(path)
    }
    function openTreeUrl(url) { window.openTreePath(treeModel.localPath(url)) }

    // ------------------------------------------------------------ C++ BACKEND
    TreeModel { id: treeModel }

    Connections {
        target: treeModel
        function onLoadStarted(name) { toast.begin("Opening " + name) }
        function onProgress(stage, fraction) { toast.step(stage, fraction * 0.9) }
        function onTreeLoaded() {
            toast.step("Drawing tree", 0.93)
            viewStack.currentIndex = 1
            if (window.pendingRecent !== "") {
               appBridge.addRecent(window.pendingRecent)
               window.pendingRecent = ""
            }
        }
        function onErrorOccurred(message) {
            window.pendingRecent = ""
            toast.fail("Couldn't complete that")
            errorDialog.text = message
            errorDialog.open()
        }
        function onEdited(message) { window.editNote = message }
        function onMetadataLoaded(matched, total, key) {
            toast.flash(matched > 0 ? "Metadata: matched " + matched + " of " + total + " rows"
                                    : "Metadata imported, but no rows match the tip names")
        }
    }

    Connections {
        target: viewer
        function onRenderFinished(ms, tips, nodes) {
            toast.step("Rendering", 0.97)
            toast.finish((window.editNote !== "" ? window.editNote + " · " : "Tree ready · ")
                         + tips + " tips · " + ms + " ms")
            window.editNote = ""
        }
        function onNotify(text) { toast.flash(text) }
        function onGraphicsRequested() { graphicsDialog.open() }
    }

    // ---------------------------------------------------------------- DIALOGS
    MessageDialog {
        id: errorDialog
        title: "cladescope"
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
        onAccepted: window.openTreeUrl(selectedFile)
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
        id: metadataDialog
        title: "Import Metadata Table"
        nameFilters: ["Tables (*.csv *.tsv *.txt *.tab)", "All files (*)"]
        onAccepted: treeModel.loadMetadata(selectedFile)
    }

    // Figure export: SVG / PDF / PNG of the whole tree at a readable size.
    Dialog {
        id: exportDialog
        title: "Export figure"
        modal: true
        anchors.centerIn: Overlay.overlay
        width: 460
        readonly property var fmts: ["svg", "pdf", "png"]
        readonly property string fmt: fmts[fmtCombo.currentIndex]
        readonly property real pngScale: scaleCombo.currentIndex + 1

        contentItem: ColumnLayout {
            spacing: 12
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#6b7480"
                text: "Exports the whole tree at a readable row spacing — not just what is on screen — using your current layout, colors and display options."
            }
            RowLayout {
                Layout.fillWidth: true
                Label { text: "Format"; Layout.preferredWidth: 90 }
                ComboBox {
                    id: fmtCombo
                    Layout.fillWidth: true
                    model: ["SVG — editable vector (Illustrator, Inkscape)",
                            "PDF — vector, ready for papers",
                            "PNG — high-resolution image"]
                }
            }
            RowLayout {
                Layout.fillWidth: true
                visible: exportDialog.fmt === "png"
                Label { text: "Resolution"; Layout.preferredWidth: 90 }
                ComboBox {
                    id: scaleCombo
                    Layout.fillWidth: true
                    model: ["1×  (screen)", "2×  (sharp)", "3×  (print)", "4×  (large print)"]
                    currentIndex: 1
                }
            }
            CheckBox {
                id: includeSelBox
                text: "Include search matches and current selection"
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#8a94a0"
                font.pixelSize: 12
                visible: exportDialog.fmt === "svg"
                text: "Text stays editable. If your editor lacks the tree font it will substitute one; use PDF to embed the look."
            }
        }

        footer: DialogButtonBox {
            Button { text: "Cancel"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole }
            Button { text: "Choose file…"; highlighted: true; DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole }
        }
        onAccepted: exportFileDialog.open()
    }

    FileDialog {
        id: exportFileDialog
        title: "Export figure"
        fileMode: FileDialog.SaveFile
        defaultSuffix: exportDialog.fmt
        nameFilters: exportDialog.fmt === "svg" ? ["SVG vector (*.svg)"]
                   : (exportDialog.fmt === "pdf" ? ["PDF document (*.pdf)"] : ["PNG image (*.png)"])
        onAccepted: {
            window.exportPath = treeModel.localPath(selectedFile)
            window.exportFmt = exportDialog.fmt
            toast.begin("Exporting " + exportDialog.fmt.toUpperCase())
            toast.step("Laying out the whole tree", 0.35)
            exportTimer.start()          // let the toast paint before the heavy work
        }
    }

    Timer {
        id: exportTimer
        interval: 80
        onTriggered: {
            var ok = viewer.exportFigure(window.exportPath, window.exportFmt,
                                         exportDialog.pngScale, includeSelBox.checked)
            if (ok) toast.finish("Exported " + window.exportFmt.toUpperCase())
            else toast.fail("Export failed — check the file location")
        }
    }

    FileDialog {
        id: exportImageDialog
        title: "Export Current View as PNG"
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
                  "<b>Select a clade</b> — then Highlight, Reroot, Extract or Open in new window from the card at the bottom<br>" +
                  "<b>Ctrl/Cmd + Z</b> — undo a reroot or extract<br>" +
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
    Shortcut { sequences: [StandardKey.Undo]; enabled: window.hasTree && viewer.canUndo; onActivated: viewer.undo() }

    // ------------------------------------------------------------------ MENUS
    Menu {
       id: fileMenu
       onAboutToShow: appBridge.refreshRecent()
       delegate: MenuItem {
           id: mi
           arrow: Text {
               visible: mi.subMenu
               text: "›"
               font.pixelSize: 15
               color: mi.enabled ? "#1c2128" : "#a0a7b0"
               x: mi.mirrored ? mi.padding : mi.width - width - mi.padding
               y: mi.topPadding + (mi.availableHeight - height) / 2
           }
       }
       MenuItem { text: "Open Tree File…"; onTriggered: openFileDialog.open() }
       Menu {
           id: recentMenu
           title: "Open Recent"
           property real wanted: 280
           width: Math.min(wanted, window.width - 40)

           function recalc() {
               var w = 280
               for (var i = 0; i < count; i++) {
                   var it = itemAt(i)
                   if (it && it.visible) w = Math.max(w, it.implicitWidth)
               }
               wanted = w
           }

           Instantiator {
               model: appBridge.recentFiles
               delegate: MenuItem {
                   id: ri
                   required property string modelData
                   text: modelData
                   contentItem: Text {
                       text: ri.text
                       font: ri.font
                       color: ri.enabled ? "#1c2128" : "#a0a7b0"
                       elide: Text.ElideMiddle
                       verticalAlignment: Text.AlignVCenter
                   }
                   onTriggered: window.openTreePath(modelData)
               }
               onObjectAdded: (index, object) => { recentMenu.insertItem(index, object); recentMenu.recalc() }
               onObjectRemoved: (index, object) => { recentMenu.removeItem(object); recentMenu.recalc() }
           }
           MenuItem {
               text: "No recent files"
               enabled: false
               visible: appBridge.recentFiles.length === 0
               height: visible ? implicitHeight : 0
           }
           MenuSeparator { visible: appBridge.recentFiles.length > 0; height: visible ? implicitHeight : 0 }
           MenuItem {
               text: "Clear Recent Files"
               visible: appBridge.recentFiles.length > 0
               height: visible ? implicitHeight : 0
               onTriggered: appBridge.clearRecent()
           }
       }
       MenuItem { text: "Load Example Tree"; onTriggered: treeModel.loadExample() }
        MenuSeparator {}
        MenuItem { text: "Import Metadata…"; enabled: window.hasTree; onTriggered: metadataDialog.open() }
        MenuSeparator {}
        MenuItem { text: "Save as Newick…"; enabled: window.hasTree; onTriggered: saveNewickDialog.open() }
        MenuItem { text: "Export Figure (SVG / PDF / PNG)…"; enabled: window.hasTree; onTriggered: exportDialog.open() }
        MenuItem { text: "Export Current View as PNG…"; enabled: window.hasTree; onTriggered: exportImageDialog.open() }
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
        id: treeMenu
        MenuItem { text: "Midpoint root"; enabled: window.hasTree; onTriggered: viewer.midpointRoot() }
        MenuItem { text: "Reroot on selected branch"; enabled: viewer.canEditSelection; onTriggered: viewer.rerootSelected() }
        MenuSeparator {}
        MenuItem { text: "Highlight selected clade…"; enabled: viewer.canEditSelection; onTriggered: viewer.highlightSelected() }
        MenuItem { text: "Clear all highlights"; enabled: window.hasTree; onTriggered: viewer.clearHighlights() }
        MenuSeparator {}
        MenuItem { text: "Extract selected clade"; enabled: viewer.selectionIsClade; onTriggered: viewer.extractSelected() }
        MenuItem { text: "Open selected clade in new window"; enabled: viewer.selectionIsClade
                   onTriggered: viewer.openCladeInNewWindow(viewer.selectedNode) }
        MenuSeparator {}
        MenuItem { text: "Undo   (Ctrl+Z)"; enabled: viewer.canUndo; onTriggered: viewer.undo() }
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
        MenuSeparator {}
        MenuItem { text: "Import metadata table…"; onTriggered: metadataDialog.open() }
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
                id: treeBtn
                iconSource: "qrc:/ui/assets/icons/account_tree_24dp.svg"
                labelText: "Tree"
                enabled: window.hasTree
                isActive: treeMenu.visible
                onClicked: treeMenu.popup(treeBtn, 0, treeBtn.height)
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
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            RowLayout {
                anchors.fill: parent
                anchors.margins: 40 // Gives you the clean room on the left, right, top, and bottom
                spacing: 40

                ColumnLayout {
                    // Instead of a rigid 450px width, let it scale but cap it at 500
                    Layout.fillWidth: true
                    Layout.maximumWidth: 500
                    Layout.fillHeight: true
                    spacing: 25

                    Item { Layout.fillHeight: true } // Top spacer

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
                            text: "cladescope"
                            font.pixelSize: 42
                            font.bold: true
                            color: "#212121"
                            Layout.alignment: Qt.AlignVCenter
                        }
                    }

                    Text {
                        text: "Welcome to cladescope: Next-Gen Phylogenetics"
                        font.pixelSize: 28
                        color: "#6c757d"
                        Layout.fillWidth: true // Ensure it knows to wrap within the column
                        // wrapMode: Text.WordWrap
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
                        Layout.fillWidth: true // Ensure it knows to wrap
                        wrapMode: Text.WordWrap
                    }

                    Item { Layout.fillHeight: true } // Bottom spacer
                }

                Item {
                    Layout.minimumWidth: 300
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
        onDropped: (drop) => { if (drop.hasUrls) window.openTreeUrl(drop.urls[0]) }
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
