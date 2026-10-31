import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml

Item {
    id: root
    property var treeModel: null
    property alias settings: vs

    signal renderFinished(int ms, int tips, int nodes)
    signal notify(string text)
    signal graphicsRequested()

    function exportImage(path) { return canvasView.exportImage(path) }

    // ------------------------------------------------------------------ fonts
    // UI font (also the default tree font)
    FontLoader { id: fontLight; source: "qrc:/ui/assets/fonts/RobotoCondensed-Light.ttf" }
    FontLoader { id: fontBold; source: "qrc:/ui/assets/fonts/RobotoCondensed-Bold.ttf" }

    // Optional tree fonts. Drop the .ttf files into ui/assets/fonts, add them to
    // your .qrc / CMake resource list, and edit this catalog. Fonts whose file is
    // missing are simply left out of the picker.
    readonly property var fontCatalog: [
        { label: "Inter",              file: "qrc:/ui/assets/fonts/Inter-Regular.ttf" },
        { label: "IBM Plex Sans",      file: "qrc:/ui/assets/fonts/IBMPlexSans-Regular.ttf" },
        { label: "IBM Plex Mono",      file: "qrc:/ui/assets/fonts/IBMPlexMono-Regular.ttf" },
        { label: "Source Sans 3",      file: "qrc:/ui/assets/fonts/SourceSans3-Regular.ttf" },
        { label: "Fira Sans Condensed",file: "qrc:/ui/assets/fonts/FiraSansCondensed-Regular.ttf" },
        { label: "JetBrains Mono",     file: "qrc:/ui/assets/fonts/JetBrainsMono-Regular.ttf" },
        { label: "Lato",               file: "qrc:/ui/assets/fonts/Lato-Regular.ttf" },
        { label: "Noto Sans",          file: "qrc:/ui/assets/fonts/NotoSans-Regular.ttf" },
        { label: "Merriweather",       file: "qrc:/ui/assets/fonts/Merriweather-Regular.ttf" }
    ]

    function rebuildFonts() {
        var o = [{ label: "Default (Roboto Condensed)", family: "" },
                 { label: "System Sans", family: "sans-serif" }]
        for (var i = 0; i < fontInst.count; i++) {
            var f = fontInst.objectAt(i)
            if (f && f.status === FontLoader.Ready) o.push({ label: fontCatalog[i].label, family: f.name })
        }
        vs.fontOptions = o
    }

    Instantiator {
        id: fontInst
        model: root.fontCatalog
        delegate: FontLoader {
            required property var modelData
            source: modelData.file
            onStatusChanged: root.rebuildFonts()
        }
        onObjectAdded: root.rebuildFonts()
    }

    // ------------------------------------------------------------ shared state
    QtObject {
        id: vs
        property string layoutType: "rectangular"
        property bool useBranchLengths: true
        property string ladderize: "none"
        property real fontSize: 12
        property real lineWidth: 1.5
        property color branchColor: "#333a44"
        property bool showTips: true
        property bool alignTips: false
        property bool showNodeDots: false
        property bool showScale: true
        property bool showSupport: false
        property bool showLengths: false
        property bool performanceMode: false
        property string renderMode: "auto"          // auto | gpu | cpu

        property string searchQuery: ""
        property bool searchRegex: false
        property bool searchCase: false
        property int matchCount: 0

        property string colorPattern: ""
        property bool colorEnabled: false
        property bool colorBranches: true
        property int categoryCount: 0
        property string regexError: ""

        property string appFont: fontLight.status === FontLoader.Ready ? fontLight.name : "sans-serif"
        property string appFontBold: fontBold.status === FontLoader.Ready ? fontBold.name : "sans-serif"
        property string treeFont: ""                // "" = use appFont
        property var fontOptions: [{ label: "Default (Roboto Condensed)", family: "" },
                                   { label: "System Sans", family: "sans-serif" }]

        signal findNext()
        signal findPrev()
        signal fitView()
        signal pickMatches()
        signal copyMatches()

        function reset() {
            layoutType = "rectangular"; useBranchLengths = true; ladderize = "none"
            fontSize = 12; lineWidth = 1.5; branchColor = "#333a44"; treeFont = ""
            showTips = true; alignTips = false; showNodeDots = false; showScale = true
            showSupport = false; showLengths = false; performanceMode = false
            colorBranches = true
            fitView()
        }
    }

    Connections {
        target: vs
        function onFindNext() { canvasView.findNext() }
        function onFindPrev() { canvasView.findPrev() }
        function onFitView() { canvasView.fitView() }
        function onPickMatches() { canvasView.pickMatches() }
        function onCopyMatches() { canvasView.copyMatches() }
    }

    Shortcut {
        sequences: [StandardKey.Find]
        onActivated: sidebar.focusSearch()
    }

    // GPU canvas: only possible on a hardware OpenGL scene graph.
    readonly property bool gpuAvailable: typeof appBridge !== "undefined" && appBridge.canGpuCanvas
    readonly property bool useGpu: gpuAvailable && (vs.renderMode === "gpu"
                                    || (vs.renderMode === "auto" && canvasView.totalTips > 3000))
    readonly property string gpuText: {
        if (typeof appBridge === "undefined" || appBridge.api === "") return "Graphics: detecting…"
        var name = appBridge.gpuName !== "" ? appBridge.gpuName : appBridge.api
        if (useGpu) return "GPU · " + name
        if (gpuAvailable) return "GPU ready · " + name + " (idle)"
        return "CPU raster · " + appBridge.api
    }
    readonly property color gpuColor: useGpu ? "#28a745" : (gpuAvailable ? "#17a2b8" : "#f59f00")

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        SplitView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: Qt.Horizontal

            Sidebar {
                id: sidebar
                settings: vs
                SplitView.preferredWidth: 290
                SplitView.minimumWidth: 220
                SplitView.maximumWidth: 420
            }

            TreeCanvas {
                id: canvasView
                SplitView.fillWidth: true

                treeData: root.treeModel ? root.treeModel.treeData : null

                layoutType: vs.layoutType
                useBranchLengths: vs.useBranchLengths
                ladderize: vs.ladderize
                fontSize: vs.fontSize
                lineWidth: vs.lineWidth
                branchColor: vs.branchColor
                showTips: vs.showTips
                alignTips: vs.alignTips
                showNodeDots: vs.showNodeDots
                showScale: vs.showScale
                showSupport: vs.showSupport
                showLengths: vs.showLengths
                performanceMode: vs.performanceMode
                gpuCanvas: root.useGpu
                searchQuery: vs.searchQuery
                searchRegex: vs.searchRegex
                searchCaseSensitive: vs.searchCase
                colorPattern: vs.colorPattern
                colorEnabled: vs.colorEnabled
                colorBranches: vs.colorBranches
                appFont: vs.treeFont !== "" ? vs.treeFont : vs.appFont

                onMatchCountChanged: vs.matchCount = matchCount
                onCategoryCountChanged: vs.categoryCount = categoryCount
                onRegexErrorChanged: vs.regexError = regexError
                onRenderFinished: (ms, tips, nodes) => root.renderFinished(ms, tips, nodes)
                onNotify: (text) => root.notify(text)
                onCopyRequested: (text) => appBridge.copyText(text)
            }
        }

        // --- BOTTOM STATUS BAR ---
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            color: "#ffffff"
            border.color: "#d9dde3"
            border.width: 1

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 15
                anchors.rightMargin: 15
                spacing: 18

                Text {
                    text: canvasView.pT ? canvasView.totalTips + " tips" : "No tree loaded"
                    font.pixelSize: 12; font.family: vs.appFont; color: "#6b7480"
                }
                Text {
                    text: canvasView.pT ? canvasView.nodeCount + " visible nodes" : ""
                    font.pixelSize: 12; font.family: vs.appFont; color: "#6b7480"
                }
                Text {
                    visible: canvasView.pT !== null
                    text: canvasView.pT ? canvasView.layoutName() : ""
                    font.pixelSize: 12; font.family: vs.appFont; color: "#6b7480"
                }
                Text {
                    visible: canvasView.lodCount > 0
                    text: "◧ " + canvasView.lodCount + " clades summarized — zoom in for detail"
                    font.pixelSize: 12; font.family: vs.appFont; color: "#8a6d00"
                }
                Text {
                    visible: canvasView.pickedCount === 0 && canvasView.selectionText !== ""
                    text: "Selected: " + canvasView.selectionText
                    font.pixelSize: 12; font.family: vs.appFont; color: "#2f6fed"
                }
                Text {
                    visible: canvasView.pickedCount > 0
                    text: canvasView.pickedCount + " labels picked · Ctrl/Cmd+C to copy"
                    font.pixelSize: 12; font.family: vs.appFont; color: "#2f6fed"
                }

                Item { Layout.fillWidth: true }

                Text {
                    visible: vs.performanceMode
                    text: "⚡ Performance mode"
                    font.pixelSize: 12; font.family: vs.appFont; color: "#f59f00"
                }
                Text {
                    text: "Zoom: " + Math.round(canvasView.zoomFactor * 100) + "%"
                    font.pixelSize: 12; font.family: vs.appFont; color: "#6b7480"
                }

                // GPU / renderer indicator (click for details)
                Item {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: 20
                    Layout.preferredWidth: gpuRow.width
                    Row {
                        id: gpuRow
                        spacing: 6
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            width: 8; height: 8; radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.gpuColor
                        }
                        Text {
                            text: root.gpuText
                            font.pixelSize: 12; font.family: vs.appFont; color: "#4a5560"
                            elide: Text.ElideRight
                            width: Math.min(implicitWidth, 300)
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.graphicsRequested()
                    }
                }
            }
        }
    }
}
