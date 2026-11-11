import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    clip: true
    focus: true

    // ------------------------------------------------------------------ inputs
    property var treeData: null
    property string layoutType: "rectangular"   // rectangular | slanted | circular | radial
    property bool useBranchLengths: true
    property string ladderize: "none"           // none | asc | desc
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
    property bool gpuCanvas: false              // use OpenGL framebuffer canvas
    property string searchQuery: ""
    property bool searchRegex: false
    property bool searchCaseSensitive: false
    property string colorPattern: ""
    property bool colorEnabled: false
    property bool colorBranches: true
    property string appFont: "sans-serif"
    property var metadata: null                 // TreeModel.metadata (columns aligned to node index)
    property string colorColumn: ""             // "" = tip names, else the name of a metadata column
    property bool canUndo: false
    property bool breakLongBranches: true       // compress branches that dominate the axis
    property int breakCount: 0                  // output: branches currently compressed
    property int breakCandidates: 0             // output: branches that would be compressed

    // ----------------------------------------------------------------- outputs
    property int matchCount: 0
    property int categoryCount: 0
    property string regexError: ""
    property int leafCount: 0
    property int nodeCount: 0
    property int collapsedCount: 0
    property int lodCount: 0
    property int pickedCount: 0
    property string selectionText: ""
    property bool selIsInternal: false
    property bool selIsCollapsed: false
    property int totalTips: 0
    property int highlightCount: 0

    // view transform. x/polar scale = zoomFactor, y scale = zoomFactor * yStretch
    property real zoomFactor: 1.0
    property real panX: 0
    property real panY: 0
    property real yStretch: 1.0
    property bool zoomTool: false
    property bool selectTool: false             // drag a box to pick the tips inside it
    property bool boxIsSelect: false            // the rubber band currently drawn selects (green) instead of zooming (blue)
    property bool fillLabels: false             // color by filling the label background (band) instead of the text
    property bool colOpen: false                // color palette open in the selection card
    property var manualGroups: []               // [{ color, label, names: [tip names] }]  (keyed by name: survives rerooting)
    property int manualCount: 0                 // tips currently colored by hand

    signal renderFinished(int ms, int tips, int nodes)
    signal notify(string text)
    signal copyRequested(string text)
    signal rerootRequested(int node)
    signal extractRequested(int node)
    signal newWindowRequested(int node)
    signal undoRequested()
    signal breakToggled(bool enabled)

    // ---------------------------------------------------------- internal state
    property var pT: null             // prepared tree (typed arrays)
    property var pL: null             // cached layout
    property var vp: ({ cx: 0, cy: 0, bw: 1, bh: 1, R: 1 })
    property var collapsed: ({})
    property var cat: null
    property var matchFlags: null
    property var matchList: []
    property int matchCursor: -1
    property var pickedFlags: null
    property var highlights: ({})               // node index -> fill color
    property bool hlOpen: false
    property string _colorSig: ""
    property int selIndex: -1
    property bool layoutDirty: true
    property bool firstRenderPending: false
    property bool announceLayout: false
    property bool interacting: false
    property int lastRenderMs: 0
    property real tgtZoom: 1.0
    property real tgtPanX: 0
    property real tgtPanY: 0
    property real tgtYs: 1.0
    property var viewHistory: []
    property bool boxActive: false
    property real bx0: 0
    property real by0: 0
    property real bx1: 0
    property real by1: 0

    readonly property var manualPalette: [
        { name: "Red", color: "#dc3545" },    { name: "Blue", color: "#2f6fed" },
        { name: "Green", color: "#28a745" },  { name: "Orange", color: "#f59f00" },
        { name: "Purple", color: "#6f42c1" }, { name: "Pink", color: "#e83e8c" },
        { name: "Teal", color: "#17a2b8" },   { name: "Brown", color: "#8d6e63" },
        { name: "Black", color: "#1c2128" },  { name: "Grey", color: "#8b96a3" }
    ]
    readonly property var palette: [
        "#2f6fed", "#e83e8c", "#28a745", "#f59f00", "#17a2b8",
        "#6f42c1", "#fd7e14", "#20c997", "#dc3545", "#8d6e63"
    ]

    // --------------------------------------------------------- change handling
    onTreeDataChanged: prepareTree()
    onSelIndexChanged: root.hlOpen = false

    property var _paintDeps: [fontSize, lineWidth, branchColor, showTips, alignTips, showNodeDots,
                              showScale, showSupport, showLengths, colorBranches, performanceMode,
                              appFont, zoomFactor, panX, panY, yStretch]
    on_PaintDepsChanged: canvas.requestPaint()

    property var _layoutDeps: [layoutType, useBranchLengths, ladderize, breakLongBranches]
    on_LayoutDepsChanged: {
        layoutDirty = true
        if (pT && !firstRenderPending) announceLayout = true
        canvas.requestPaint()
    }

    property var _searchDeps: [searchQuery, searchRegex, searchCaseSensitive]
    on_SearchDepsChanged: { recomputeSearch(); canvas.requestPaint() }

    property var _colorDeps: [colorPattern, colorEnabled, colorColumn, metadata]
    on_ColorDepsChanged: {
        // only announce when the user's coloring choice changed, not when metadata is re-aligned after an edit
        var sig = colorPattern + "|" + colorEnabled + "|" + colorColumn
        var announce = sig !== root._colorSig
        root._colorSig = sig
        recomputeCategories(announce)
        canvas.requestPaint()
    }

    function isPolar() { return pL !== null && (pL.kind === "circular" || pL.kind === "radial") }

    // ------------------------------------------------------------- tree prep
    function prepareTree() {
        var d = root.treeData
        root.collapsed = ({})
        root.collapsedCount = 0
        root.selIndex = -1
        root.pickedFlags = null
        root.pickedCount = 0
        root.highlights = ({})
        root.highlightCount = 0
        root.hlOpen = false
        root.viewHistory = []
        root.pL = null
        root.cat = null
        refreshSelection()
        if (!d || !d.count || d.count < 2) {
            root.pT = null; root.leafCount = 0; root.nodeCount = 0; root.totalTips = 0
            canvas.requestPaint()
            return
        }
        var n = d.count
        var parents = d.parents, names = d.names, lens = d.lengths
        var par = new Int32Array(n), len = new Float64Array(n)
        var label = new Array(n), children = new Array(n)
        var support = new Float64Array(n)
        var supText = new Array(n).fill("")
        var hasLen = false
        for (var i = 0; i < n; i++) children[i] = []
        for (var j = 0; j < n; j++) {
            par[j] = parents[j]
            len[j] = lens[j]
            label[j] = names[j]
            support[j] = NaN
            if (len[j] > 0) hasLen = true
            if (par[j] >= 0) children[par[j]].push(j)
        }
        var size = new Int32Array(n), tips = new Int32Array(n)
        var longest = ""
        var tipList = []
        for (var a = n - 1; a >= 0; a--) {
            size[a] += 1
            if (children[a].length === 0) {
                tips[a] = 1
                tipList.push(a)
                if (label[a].length > longest.length) longest = label[a]
            } else if (a > 0) {
                var sp = supportOf(label[a])
                if (sp) { support[a] = sp.value; supText[a] = sp.text; label[a] = "" }
            }
            if (par[a] >= 0) { size[par[a]] += size[a]; tips[par[a]] += tips[a] }
        }
        tipList.reverse()
        root.pT = { n: n, par: par, len: len, names: label, children: children, size: size,
                    tips: tips, support: support, supText: supText, hasLengths: hasLen, longest: longest, tipList: tipList }
        root.totalTips = tips[0]
        root.firstRenderPending = true
        root.layoutDirty = true
        recomputeSearch()
        recomputeCategories(false)
        setView(1, 0, 0, 1)
        canvas.requestPaint()
    }

    // ----------------------------------------------------------------- search
    function recomputeSearch() {
        root.matchFlags = null
        root.matchList = []
        root.matchCursor = -1
        if (!root.pT || !root.searchQuery) { root.matchCount = 0; return }
        var re
        try {
            var src = root.searchRegex ? root.searchQuery
                                       : root.searchQuery.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
            re = new RegExp(src, root.searchCaseSensitive ? "" : "i")
        } catch (e) { root.matchCount = 0; return }
        var flags = new Uint8Array(root.pT.n), list = []
        var tl = root.pT.tipList
        for (var k = 0; k < tl.length; k++) {
            var idx = tl[k]
            if (re.test(root.pT.names[idx])) { flags[idx] = 1; list.push(idx) }
        }
        root.matchFlags = flags
        root.matchList = list
        root.matchCount = list.length
    }

    function findNext() { stepMatch(1) }
    function findPrev() { stepMatch(-1) }
    function stepMatch(dir) {
        var m = root.matchList
        if (!m || m.length === 0) return
        root.matchCursor = (root.matchCursor + dir + m.length) % m.length
        focusNode(m[root.matchCursor])
    }

    // --------------------------------------------------------- color by regex
    function columnIndex(name) {
        if (!name || !root.metadata || !root.metadata.columns) return -1
        return root.metadata.columns.indexOf(name)
    }

    // Categories come from the tip name or a metadata column; an optional regex
    // (first capture group, else whole match) is applied to that text.
    function recomputeCategories(announce) {
        baseCategories(announce)
        applyManualColors()
    }
    function baseCategories(announce) {
        root.cat = null
        root.categoryCount = 0
        root.regexError = ""
        if (!root.pT) return
        var colIdx = columnIndex(root.colorColumn)
        var usePattern = root.colorEnabled && root.colorPattern !== ""
        if (colIdx < 0 && !usePattern) return
        var re = null
        if (usePattern) {
            try { re = new RegExp(root.colorPattern) }
            catch (e) { root.regexError = "Invalid pattern: " + e.message; return }
        }
        var colVals = colIdx >= 0 ? root.metadata.values[colIdx] : null

        var t = root.pT, n = t.n
        var keyOf = new Array(n), counts = {}
        for (var k = 0; k < t.tipList.length; k++) {
            var idx = t.tipList[k]
            var text = colVals ? colVals[idx] : t.names[idx]
            if (text === undefined || text === null || text === "") continue
            var key = text
            if (re) {
                var m = re.exec(text)
                if (!m) continue
                key = m[0]
                for (var g = 1; g < m.length; g++) if (m[g] !== undefined && m[g] !== "") { key = m[g]; break }
            }
            if (key === "") continue
            keyOf[idx] = key
            counts[key] = (counts[key] || 0) + 1
        }
        var labels = Object.keys(counts)
        labels.sort(function (a, b) {
            var na = parseFloat(a), nb = parseFloat(b)
            if (!isNaN(na) && !isNaN(nb) && na !== nb) return na - nb
            return a < b ? -1 : (a > b ? 1 : 0)
        })
        var colors = [], cnt = [], index = {}
        for (var c = 0; c < labels.length; c++) {
            colors.push(labels.length <= root.palette.length
                        ? root.palette[c]
                        : Qt.hsla((c / labels.length) * 0.85, 0.68, 0.46, 1).toString())
            cnt.push(counts[labels[c]])
            index[labels[c]] = c
        }
        var nodeCat = new Int32Array(n).fill(-1)
        for (var q = n - 1; q >= 0; q--) {
            var ch = t.children[q]
            if (ch.length === 0) {
                if (keyOf[q] !== undefined) nodeCat[q] = index[keyOf[q]]
            } else {
                var c0 = nodeCat[ch[0]], ok = c0 >= 0
                for (var z = 1; ok && z < ch.length; z++) if (nodeCat[ch[z]] !== c0) ok = false
                nodeCat[q] = ok ? c0 : -1
            }
        }
        root.cat = { labels: labels, colors: colors, counts: cnt, nodeCat: nodeCat }
        root.categoryCount = labels.length
        if (announce && labels.length > 0)
            root.notify("Colored by " + (colIdx >= 0 ? root.colorColumn : "pattern") + " · " + labels.length + " categories")
    }

    // ------------------------------------------------- selection / label picking
    function refreshSelection() {
        if (!root.pT || root.selIndex < 0) {
            root.selectionText = ""; root.selIsInternal = false; root.selIsCollapsed = false
            return
        }
        var i = root.selIndex, t = root.pT
        var internal = t.children[i].length > 0
        root.selIsInternal = internal && i > 0
        root.selIsCollapsed = root.collapsed[i] === true
        var nm = t.names[i]
        root.selectionText = internal ? ((nm ? nm + " · " : "Clade · ") + t.tips[i] + " tips")
                                      : (nm || "tip")
    }
    function clearSelection() { root.selIndex = -1; refreshSelection(); canvas.requestPaint() }
    function clearPicked() {
        if (root.pickedCount === 0) return
        root.pickedFlags = null
        root.pickedCount = 0
        canvas.requestPaint()
    }
    function clearAll() {
        root.selIndex = -1
        refreshSelection()
        clearPicked()
        canvas.requestPaint()
    }
    function selectParent() {
        if (root.selIndex > 0) { root.selIndex = root.pT.par[root.selIndex]; refreshSelection(); canvas.requestPaint() }
    }
    function toggleSelected() {
        if (root.selIndex <= 0 || !root.selIsInternal) return
        if (root.collapsed[root.selIndex] === true) delete root.collapsed[root.selIndex]
        else root.collapsed[root.selIndex] = true
        root.collapsedCount = Object.keys(root.collapsed).length
        root.layoutDirty = true
        refreshSelection()
        canvas.requestPaint()
    }
    function expandAll() {
        root.collapsed = ({})
        root.collapsedCount = 0
        root.layoutDirty = true
        refreshSelection()
        canvas.requestPaint()
    }

    function ensurePicked() {
        if (!root.pickedFlags || root.pickedFlags.length !== root.pT.n)
            root.pickedFlags = new Uint8Array(root.pT.n)
    }
    function togglePick(i) {
        ensurePicked()
        if (root.pickedFlags[i]) { root.pickedFlags[i] = 0; root.pickedCount-- }
        else { root.pickedFlags[i] = 1; root.pickedCount++ }
        canvas.requestPaint()
    }
    function pickClade(i) {
        ensurePicked()
        var t = root.pT, end = i + t.size[i], tl = t.tipList, added = 0
        for (var k = 0; k < tl.length; k++) {
            var idx = tl[k]
            if (idx >= i && idx < end && !root.pickedFlags[idx]) { root.pickedFlags[idx] = 1; added++ }
        }
        root.pickedCount += added
        canvas.requestPaint()
    }
    function pickOnly(i) {
        root.pickedFlags = null
        root.pickedCount = 0
        togglePick(i)
    }
    function pickMatches() {
        if (!root.pT || root.matchList.length === 0) return
        root.pickedFlags = null
        root.pickedCount = 0
        ensurePicked()
        for (var k = 0; k < root.matchList.length; k++) root.pickedFlags[root.matchList[k]] = 1
        root.pickedCount = root.matchList.length
        canvas.requestPaint()
    }

    // ---- manual color groups (box-select or search, then color).  They are layered on top of the
    // regex / metadata categories by appending extra categories, so the legend, branch coloring and
    // every export format pick them up with no extra drawing code.
    // Support value carried by an internal-node label: a plain number ("95", "0.98") or a compound one as
    // written by IQ-TREE ("87.5/99", "0.95/87").  Returns { value, text } or null for any other label.
    function supportOf(label) {
        var s = String(label).replace(/\s+/g, "")
        if (s === "") return null
        var num = "-?\\d+(\\.\\d+)?([eE][-+]?\\d+)?"
        if (new RegExp("^" + num + "$").test(s)) {
            var v = parseFloat(s)
            return { value: v, text: String(Math.round(v * 100) / 100) }
        }
        if (new RegExp("^" + num + "([/|,]" + num + ")+$").test(s))
            return { value: parseFloat(s.split(/[\/|,]/)[0]), text: s }
        return null
    }
    // Text to draw for node i's support value ("" if it has none)
    function supportLabel(t, i) {
        if (t.supText) return t.supText[i] || ""
        return t.support[i] === t.support[i] ? String(Math.round(t.support[i] * 100) / 100) : ""
    }

    function textOn(hex) {                       // readable text color (white or near-black) on a filled band
        var m = /^#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$/.exec(String(hex))
        if (!m) return "#1c2128"
        function lin(h) { var c = parseInt(h, 16) / 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4) }
        var lum = 0.2126 * lin(m[1]) + 0.7152 * lin(m[2]) + 0.0722 * lin(m[3])
        // WCAG contrast of the fill against white vs against the dark text color (#1c2128, luminance ~0.015): take the better
        return ((lum + 0.05) / 0.065 > 1.05 / (lum + 0.05)) ? "#1c2128" : "#ffffff"
    }

    function applyManualColors() {
        var groups = root.manualGroups
        if (!root.pT || !groups || groups.length === 0) { root.manualCount = 0; return }
        var t = root.pT, n = t.n, tl = t.tipList
        var g2 = {}
        for (var gi = 0; gi < groups.length; gi++)
            for (var q0 = 0; q0 < groups[gi].names.length; q0++) g2["n:" + groups[gi].names[q0]] = gi
        var base = root.cat
        var labels = base ? base.labels.slice() : [], colors = base ? base.colors.slice() : []
        var tipCat = new Int32Array(n).fill(-1)      // text/branch color category per tip
        var fillTip = new Int32Array(n).fill(-1)     // label-band category per tip (fill groups only)
        if (base) for (var k0 = 0; k0 < tl.length; k0++) tipCat[tl[k0]] = base.nodeCat[tl[k0]]
        var slot = [], used = 0
        for (var k = 0; k < tl.length; k++) {
            var gx = g2["n:" + t.names[tl[k]]]
            if (gx === undefined) continue
            if (slot[gx] === undefined) { slot[gx] = labels.length; labels.push(groups[gx].label); colors.push(groups[gx].color) }
            if (groups[gx].fill) fillTip[tl[k]] = slot[gx]
            else tipCat[tl[k]] = slot[gx]
            used++
        }
        if (used === 0) { root.manualGroups = []; root.manualCount = 0; return }   // e.g. a different tree was opened
        // recount, drop categories that lost all their tips, then propagate to internal nodes
        var cnt = new Array(labels.length).fill(0)
        for (var k1 = 0; k1 < tl.length; k1++) {
            var tc = tipCat[tl[k1]], fc = fillTip[tl[k1]]
            if (tc >= 0) cnt[tc]++
            if (fc >= 0) cnt[fc]++
        }
        var remap = new Array(labels.length), L2 = [], C2 = [], N2 = []
        for (var c = 0; c < labels.length; c++) {
            if (cnt[c] === 0) { remap[c] = -1; continue }
            remap[c] = L2.length; L2.push(labels[c]); C2.push(colors[c]); N2.push(cnt[c])
        }
        var nodeCat = new Int32Array(n).fill(-1), fillCat = new Int32Array(n).fill(-1), ch = t.children
        for (var i = n - 1; i >= 0; i--) {
            if (ch[i].length === 0) {
                nodeCat[i] = tipCat[i] >= 0 ? remap[tipCat[i]] : -1
                fillCat[i] = fillTip[i] >= 0 ? remap[fillTip[i]] : -1
                continue
            }
            var c0 = nodeCat[ch[i][0]], ok = c0 >= 0
            for (var z = 1; ok && z < ch[i].length; z++) if (nodeCat[ch[i][z]] !== c0) ok = false
            nodeCat[i] = ok ? c0 : -1
        }
        root.cat = { labels: L2, colors: C2, counts: N2, nodeCat: nodeCat, fillCat: fillCat }
        root.manualCount = used
    }

    // Color the picked tips: text/branch color, or (fill = true) a filled band behind the label.
    // color "" removes manual color from them.
    function colorPicked(color, name, fill) {
        if (!root.pT || root.pickedCount === 0) return
        var isFill = fill === true
        var t = root.pT, tl = t.tipList, moved = {}, nMoved = 0
        for (var k = 0; k < tl.length; k++)
            if (root.pickedFlags[tl[k]]) { moved["n:" + t.names[tl[k]]] = true; nMoved++ }
        var groups = []
        for (var gi = 0; gi < root.manualGroups.length; gi++) {
            var g = root.manualGroups[gi], keep = []
            for (var q = 0; q < g.names.length; q++) if (!moved["n:" + g.names[q]]) keep.push(g.names[q])
            if (keep.length > 0) groups.push({ color: g.color, label: g.label, fill: g.fill === true, names: keep })
        }
        if (color !== "") {
            var add = []
            for (var k2 = 0; k2 < tl.length; k2++) if (root.pickedFlags[tl[k2]]) add.push(t.names[tl[k2]])
            var found = -1
            for (var j = 0; j < groups.length; j++) if (groups[j].color === color && groups[j].fill === isFill) { found = j; break }
            if (found >= 0) groups[found].names = groups[found].names.concat(add)
            else groups.push({ color: color, fill: isFill, label: (name || color) + (isFill ? " (fill)" : ""), names: add })
        }
        root.manualGroups = groups
        recomputeCategories(false)
        root.notify(color === "" ? "Removed color from " + nMoved + " tips"
                                 : (isFill ? "Filled " : "Colored ") + nMoved + (nMoved === 1 ? " tip " : " tips ") + (name || color))
        canvas.requestPaint()
    }
    function clearManualColors() {
        root.manualGroups = []
        root.manualCount = 0
        recomputeCategories(false)
        canvas.requestPaint()
    }

    // ---- box selection: tip nodes (and collapsed clades) whose point or label anchor lies inside the rectangle
    function tipsInRect(x0, y0, x1, y1) {
        var Lr = root.pL, t = root.pT, out = []
        if (!Lr || !t) return out
        var xa = Math.min(x0, x1), xb = Math.max(x0, x1), ya = Math.min(y0, y1), yb = Math.max(y0, y1)
        var vis = Lr.vis, ch = t.children, col = root.collapsed
        var anc = { a: 0, x: 0, y: 0 }, useAnchor = root.alignTips && root.showTips
        for (var k = 0; k < vis.length; k++) {
            var i = vis[k]
            var leaf = ch[i].length === 0
            if (!leaf && col[i] !== true) continue
            var inside = Lr.PX[i] >= xa && Lr.PX[i] <= xb && Lr.PY[i] >= ya && Lr.PY[i] <= yb
            if (!inside && useAnchor && leaf) {
                labelAnchor(i, anc)
                inside = anc.x >= xa && anc.x <= xb && anc.y >= ya && anc.y <= yb
            }
            if (inside) out.push(i)
        }
        return out
    }
    function boxSelect(x0, y0, x1, y1, additive) {
        if (!root.pT || !root.pL) return 0
        var hits = tipsInRect(x0, y0, x1, y1)
        if (hits.length === 0) { root.notify("No tips inside that box"); return 0 }
        if (!additive) clearPicked()
        root.selIndex = -1
        refreshSelection()
        for (var h = 0; h < hits.length; h++) {
            if (root.pT.children[hits[h]].length === 0) {
                ensurePicked()
                if (!root.pickedFlags[hits[h]]) { root.pickedFlags[hits[h]] = 1; root.pickedCount++ }
            } else pickClade(hits[h])
        }
        canvas.requestPaint()
        return root.pickedCount
    }
    function beginBox(select, x, y) {
        viewAnim.stop()
        root.boxIsSelect = select
        root.bx0 = x; root.by0 = y; root.bx1 = x; root.by1 = y
        root.boxActive = true
        root.forceActiveFocus()
    }

    function copyLabels() {
        if (!root.pT) return
        var t = root.pT, out = [], tl = t.tipList
        if (root.pickedCount > 0) {
            for (var k = 0; k < tl.length; k++) if (root.pickedFlags[tl[k]]) out.push(t.names[tl[k]])
        } else if (root.selIndex >= 0) {
            var i = root.selIndex
            if (t.children[i].length === 0) out.push(t.names[i])
            else {
                var end = i + t.size[i]
                for (var k2 = 0; k2 < tl.length; k2++) if (tl[k2] >= i && tl[k2] < end) out.push(t.names[tl[k2]])
            }
        }
        if (out.length === 0) return
        root.copyRequested(out.join("\n"))
        root.notify("Copied " + out.length + (out.length === 1 ? " label" : " labels"))
    }
    function copyMatches() {
        if (!root.pT || root.matchList.length === 0) return
        var out = []
        for (var k = 0; k < root.matchList.length; k++) out.push(root.pT.names[root.matchList[k]])
        root.copyRequested(out.join("\n"))
        root.notify("Copied " + out.length + " matching labels")
    }

    // ---- clade highlights (shaded backgrounds behind a clade)
    function highlightSelected(color) {
        if (!root.pT || root.selIndex < 0) return
        var h = {}
        for (var k in root.highlights) h[k] = root.highlights[k]
        h[root.selIndex] = color
        root.highlights = h
        root.highlightCount = Object.keys(h).length
        canvas.requestPaint()
    }
    function unhighlightSelected() {
        if (root.selIndex < 0 || root.highlights[root.selIndex] === undefined) return
        var h = {}
        for (var k in root.highlights) if (parseInt(k) !== root.selIndex) h[k] = root.highlights[k]
        root.highlights = h
        root.highlightCount = Object.keys(h).length
        canvas.requestPaint()
    }
    function clearHighlights() {
        root.highlights = ({})
        root.highlightCount = 0
        canvas.requestPaint()
    }

    // ---- hit testing (tip labels first, then nodes)
    function labelAnchor(i, out) {
        var Lr = root.pL, v = root.vp, z = root.zoomFactor, kind = Lr.kind
        var a = (kind === "circular" || kind === "radial") ? Lr.ANG[i] : 0
        var ax = Lr.PX[i], ay = Lr.PY[i]
        if (root.alignTips && kind !== "radial") {
            if (kind === "circular") {
                var zr = v.R * z
                ax = v.cx + root.panX + zr * Math.cos(a)
                ay = v.cy + root.panY + zr * Math.sin(a)
            } else ax = v.cx + root.panX + 0.5 * v.bw * z
        }
        out.a = a
        out.x = ax + Math.cos(a) * 6
        out.y = ay + Math.sin(a) * 6
    }

    function hitTest(x, y) {
        var Lr = root.pL, t = root.pT
        var res = { idx: -1, label: false }
        if (!Lr || !t) return res
        var vis = Lr.vis, ch = t.children, fs = root.fontSize
        var polar = isPolar()
        var rowPx = polar ? (2 * Math.PI * root.vp.R * root.zoomFactor) / Math.max(Lr.leafCount, 1)
                          : (root.vp.bh * root.zoomFactor * root.yStretch) / Math.max(Lr.leafCount - 1, 1)
        var thin = Math.max(1, Math.ceil(fs * 1.1 / Math.max(rowPx, 0.01)))
        var anc = { a: 0, x: 0, y: 0 }

        if (root.showTips || root.matchFlags) {
            for (var k = 0; k < vis.length; k++) {
                var i = vis[k]
                if (ch[i].length !== 0) continue
                var special = (root.matchFlags && root.matchFlags[i] === 1) || (root.pickedFlags && root.pickedFlags[i] === 1)
                if (!root.showTips && !special) continue
                if (!special && ((thin > 1 && (Lr.Y[i] % thin) !== 0) || Lr.lod[i] === 1)) continue
                var nm = t.names[i]
                if (!nm) continue
                labelAnchor(i, anc)
                var dx = x - anc.x, dy = y - anc.y
                if (Math.abs(dx) > 700 || Math.abs(dy) > 700) continue
                var ca = Math.cos(anc.a), sa = Math.sin(anc.a)
                var along = dx * ca + dy * sa, perp = -dx * sa + dy * ca
                if (Math.abs(perp) > fs * 0.65 + 2 || along < -4) continue
                tm.text = nm
                if (along <= tm.width + 4) { res.idx = i; res.label = true; return res }
            }
        }
        var best = -1, bd = 14 * 14
        for (var k2 = 0; k2 < vis.length; k2++) {
            var j = vis[k2]
            if (Lr.lod[j] === 1) continue
            var ddx = Lr.PX[j] - x, ddy = Lr.PY[j] - y
            var d = ddx * ddx + ddy * ddy
            if (d < bd) { bd = d; best = j }
        }
        res.idx = best
        return res
    }

    // kind: "plain" | "double" | "additive"
    function handleTap(x, y, kind) {
        if (!root.pL || !root.pT) return
        var h = hitTest(x, y), i = h.idx, t = root.pT
        var isTip = i >= 0 && t.children[i].length === 0
        if (kind === "plain") {
            clearPicked()
            root.selIndex = i
            refreshSelection()
            canvas.requestPaint()
        } else if (kind === "double") {
            if (i < 0) return
            if (isTip) { root.selIndex = i; refreshSelection(); pickOnly(i) }
            else if (i > 0) { root.selIndex = i; refreshSelection(); toggleSelected() }
        } else {
            if (i < 0) return
            if (isTip) togglePick(i)
            else pickClade(i)
        }
    }

    // --------------------------------------------------------------- view ops
    function pushHistory() {
        var h = root.viewHistory.slice(-19)
        h.push({ z: root.zoomFactor, px: root.panX, py: root.panY, ys: root.yStretch })
        root.viewHistory = h
    }
    function zoomBack() {
        var h = root.viewHistory.slice()
        if (h.length === 0) return
        var s = h.pop()
        root.viewHistory = h
        animateView(s.z, s.px, s.py, s.ys)
    }
    function setView(z, px, py, ys) {
        viewAnim.stop()
        root.zoomFactor = z; root.panX = px; root.panY = py; root.yStretch = ys
        root.tgtZoom = z; root.tgtPanX = px; root.tgtPanY = py; root.tgtYs = ys
    }
    function animateView(z, px, py, ys) {
        viewAnim.stop()
        var y2 = (ys === undefined) ? root.yStretch : ys
        root.tgtZoom = z; root.tgtPanX = px; root.tgtPanY = py; root.tgtYs = y2
        aZoom.to = z; aPx.to = px; aPy.to = py; aYs.to = y2
        viewAnim.start()
    }
    function fitView() { pushHistory(); animateView(1.0, 0, 0, 1.0) }

    // fx/fy: multiplicative zoom on x and y (polar layouts always use fx)
    function zoomAboutXY(mx, my, fx, fy) {
        var polar = isPolar()
        var nz = Math.max(0.05, Math.min(400, root.tgtZoom * fx))
        var kx = nz / root.tgtZoom
        var nys = root.tgtYs, ky = kx
        if (!polar) {
            nys = Math.max(0.02, Math.min(20000, root.tgtYs * fy / kx))
            ky = (nz * nys) / (root.tgtZoom * root.tgtYs)
        }
        var ox = mx - root.vp.cx, oy = my - root.vp.cy
        animateView(nz, ox - (ox - root.tgtPanX) * kx, oy - (oy - root.tgtPanY) * ky, nys)
    }
    function zoomAbout(mx, my, f) { zoomAboutXY(mx, my, f, f) }

    // Zoom so that the screen rectangle fills the view
    function zoomToRect(x0, y0, x1, y1) {
        var w = Math.abs(x1 - x0), h = Math.abs(y1 - y0)
        if (w < 10 || h < 10 || !root.pL) return
        var rx = (x0 + x1) / 2, ry = (y0 + y1) / 2
        var z = root.zoomFactor, ys = root.yStretch
        var kx = root.width / w, ky = root.height / h
        var polar = isPolar()
        if (polar) { kx = Math.min(kx, ky) }
        var nz = Math.min(400, z * kx)
        kx = nz / z
        var nys = ys, kyEff = kx
        if (!polar) {
            nys = Math.max(0.02, Math.min(20000, ys * ky / kx))
            kyEff = (nz * nys) / (z * ys)
        }
        pushHistory()
        animateView(nz,
                    root.width / 2 - root.vp.cx - (rx - root.vp.cx - root.panX) * kx,
                    root.height / 2 - root.vp.cy - (ry - root.vp.cy - root.panY) * kyEff,
                    nys)
    }

    // One row of tips per ~1.3x font height (the "readable" view for huge trees)
    function readableRows() {
        if (!root.pL) return
        pushHistory()
        var target = root.fontSize * 1.3
        if (isPolar()) {
            var zNeeded = target * Math.max(root.pL.leafCount, 1) / (2 * Math.PI * root.vp.R)
            animateView(Math.min(400, Math.max(1, zNeeded)), 0, 0, 1)
            return
        }
        var rows = Math.max(root.pL.leafCount - 1, 1)
        var ys = target * rows / (root.vp.bh * root.zoomFactor)
        if (ys <= 1.0) { animateView(root.zoomFactor, 0, 0, 1); return }
        ys = Math.min(20000, ys)
        var tot = root.vp.bh * root.zoomFactor * ys
        animateView(root.zoomFactor, root.panX, 28 - root.vp.cy + 0.5 * tot, ys)
    }

    function focusNode(idx) {
        if (!root.pT) return
        var changed = false, p = root.pT.par[idx]
        while (p >= 0) {
            if (root.collapsed[p] === true) { delete root.collapsed[p]; changed = true }
            p = root.pT.par[p]
        }
        if (changed) { root.collapsedCount = Object.keys(root.collapsed).length; root.layoutDirty = true }
        if (root.layoutDirty || !root.pL) computeLayout()
        project()
        var Lr = root.pL, z = root.zoomFactor, nz = z
        var polar = isPolar()
        if (!polar) {
            var rowPx = root.vp.bh * z * root.yStretch / Math.max(Lr.leafCount - 1, 1)
            if (rowPx < 16) nz = Math.min(400, z * Math.pow(16 / Math.max(rowPx, 0.001), 0.5))
        } else if (z < 4 && Lr.leafCount > 60) nz = 4
        var kx = nz / z
        var nys = root.yStretch
        var ky = kx
        if (!polar) {
            // bring rows up to ~16px, splitting the effort between x and y
            var rp = root.vp.bh * z * root.yStretch / Math.max(Lr.leafCount - 1, 1)
            var wantTotal = Math.max(1, 16 / Math.max(rp, 0.001))
            nys = Math.min(20000, root.yStretch * wantTotal / kx)
            ky = (nz * nys) / (z * root.yStretch)
        }
        var offX = Lr.PX[idx] - root.vp.cx - root.panX
        var offY = Lr.PY[idx] - root.vp.cy - root.panY
        root.selIndex = idx
        refreshSelection()
        animateView(nz, root.width / 2 - root.vp.cx - offX * kx,
                    root.height / 2 - root.vp.cy - offY * ky, nys)
        canvas.requestPaint()
    }
    function exportImage(path) { return canvas.save(path) }

    // ------------------------------------------------------------------ layout
    function computeLayout() {
        var t = root.pT, n = t.n, par = t.par, ch = t.children, col = root.collapsed
        var vis = [], mask = new Uint8Array(n)
        var i = 0
        while (i < n) {
            vis.push(i); mask[i] = 1
            if (col[i] === true && ch[i].length > 0) i += t.size[i]; else i++
        }
        var m = vis.length
        function isTipV(idx) { return ch[idx].length === 0 || col[idx] === true }
        function ordered(idx) {
            var c = ch[idx]
            if (root.ladderize === "none" || c.length < 2) return c
            var s = c.slice(), dir = root.ladderize === "asc" ? 1 : -1
            s.sort(function (a, b) { return dir * (t.tips[a] - t.tips[b]) })
            return s
        }

        // rows
        var Y = new Float64Array(n), leaves = 0, stack = [0]
        while (stack.length) {
            var s0 = stack.pop()
            if (isTipV(s0)) Y[s0] = leaves++
            else { var oc = ordered(s0); for (var k = oc.length - 1; k >= 0; k--) stack.push(oc[k]) }
        }
        var Ymin = new Float64Array(n), Ymax = new Float64Array(n)
        for (var a = m - 1; a >= 0; a--) {
            var idx = vis[a]
            if (!isTipV(idx)) {
                var c = ch[idx], mn = Infinity, mx = -Infinity
                for (var b = 0; b < c.length; b++) {
                    var yy = Y[c[b]]
                    if (yy < mn) mn = yy
                    if (yy > mx) mx = yy
                    if (Ymin[c[b]] < Ymin[idx] || b === 0) Ymin[idx] = Ymin[c[b]]
                    if (Ymax[c[b]] > Ymax[idx] || b === 0) Ymax[idx] = Ymax[c[b]]
                }
                Y[idx] = (mn + mx) / 2
            } else { Ymin[idx] = Y[idx]; Ymax[idx] = Y[idx] }
        }

        // depth (phylogram) or aligned height (cladogram)
        var useLen = root.useBranchLengths && t.hasLengths
        var depth = new Float64Array(n), maxDepth = 0
        var brkFlag = null, brkList = [], brkCand = 0
        if (useLen) {
            for (var a2 = 1; a2 < m; a2++) {
                var q = vis[a2]
                depth[q] = depth[par[q]] + t.len[q]
                if (depth[q] > maxDepth) maxDepth = depth[q]
            }
            // A branch longer than half the whole plot (e.g. one tip with a bad date)
            // leaves the real tree squeezed into a sliver. Shorten such branches to a
            // stub and mark them with a break symbol.
            var thr = maxDepth * 0.5
            for (var b1 = 1; b1 < m; b1++) if (t.len[vis[b1]] > thr) brkCand++
            if (brkCand > 0 && root.breakLongBranches) {
                var d0 = new Float64Array(n), rest = 0
                brkFlag = new Uint8Array(n)
                for (var b2 = 1; b2 < m; b2++) {
                    var q0 = vis[b2], l0 = t.len[q0]
                    if (l0 > thr) { brkFlag[q0] = 1; brkList.push(q0); l0 = 0 }
                    d0[q0] = d0[par[q0]] + l0
                    if (d0[q0] > rest) rest = d0[q0]
                }
                if (rest > 0) {
                    var cap = rest * 0.2
                    maxDepth = 0
                    for (var b3 = 1; b3 < m; b3++) {
                        var q1 = vis[b3]
                        depth[q1] = depth[par[q1]] + (brkFlag[q1] ? cap : t.len[q1])
                        if (depth[q1] > maxDepth) maxDepth = depth[q1]
                    }
                } else { brkFlag = null; brkList = [] }
            }
        } else {
            var hgt = new Float64Array(n)
            for (var a3 = m - 1; a3 >= 0; a3--) {
                var q2 = vis[a3]
                if (!isTipV(q2)) {
                    var cc = ch[q2], h = 0
                    for (var b2 = 0; b2 < cc.length; b2++) h = Math.max(h, hgt[cc[b2]] + 1)
                    hgt[q2] = h
                }
            }
            maxDepth = hgt[0]
            for (var a4 = 0; a4 < m; a4++) depth[vis[a4]] = maxDepth - hgt[vis[a4]]
        }
        if (!(maxDepth > 0)) maxDepth = 1

        // deepest descendant (normalised) -- used for LOD wedges
        var Dmax = new Float64Array(n)
        for (var a11 = m - 1; a11 >= 0; a11--) {
            var q9 = vis[a11], dm = depth[q9] / maxDepth
            if (!isTipV(q9)) {
                var c9 = ch[q9]
                for (var b9 = 0; b9 < c9.length; b9++) if (Dmax[c9[b9]] > dm) dm = Dmax[c9[b9]]
            }
            Dmax[q9] = dm
        }

        var kind = root.layoutType
        if (kind !== "slanted" && kind !== "circular" && kind !== "radial") kind = "rectangular"
        var U = new Float64Array(n), V = new Float64Array(n)
        var ANG = new Float64Array(n), RAD = new Float64Array(n)
        var half = 1

        if (kind === "circular") {
            for (var a5 = 0; a5 < m; a5++) {
                var q3 = vis[a5]
                RAD[q3] = depth[q3] / maxDepth
                ANG[q3] = (Y[q3] / Math.max(leaves, 1)) * 2 * Math.PI - Math.PI / 2
                U[q3] = RAD[q3] * Math.cos(ANG[q3])
                V[q3] = RAD[q3] * Math.sin(ANG[q3])
            }
        } else if (kind === "radial") {
            var lw = new Float64Array(n)
            for (var a6 = m - 1; a6 >= 0; a6--) {
                var q4 = vis[a6]
                if (isTipV(q4)) lw[q4] = 1
                else { var sum = 0, c4 = ch[q4]; for (var b4 = 0; b4 < c4.length; b4++) sum += lw[c4[b4]]; lw[q4] = sum }
            }
            var a0 = new Float64Array(n), a1 = new Float64Array(n)
            var X = new Float64Array(n), Yp = new Float64Array(n)
            a1[0] = 2 * Math.PI
            for (var a7 = 0; a7 < m; a7++) {
                var q5 = vis[a7]
                if (isTipV(q5)) continue
                var oc5 = ordered(q5), span = a1[q5] - a0[q5], curA = a0[q5]
                for (var b5 = 0; b5 < oc5.length; b5++) {
                    var cn = oc5[b5]
                    a0[cn] = curA
                    curA += span * lw[cn] / lw[q5]
                    a1[cn] = curA
                    ANG[cn] = (a0[cn] + a1[cn]) / 2
                    var el = useLen ? t.len[cn] : 1
                    X[cn] = X[q5] + el * Math.cos(ANG[cn])
                    Yp[cn] = Yp[q5] + el * Math.sin(ANG[cn])
                }
            }
            var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
            for (var a8 = 0; a8 < m; a8++) {
                var q6 = vis[a8]
                if (X[q6] < minX) minX = X[q6]
                if (X[q6] > maxX) maxX = X[q6]
                if (Yp[q6] < minY) minY = Yp[q6]
                if (Yp[q6] > maxY) maxY = Yp[q6]
            }
            half = Math.max(maxX - minX, maxY - minY) / 2
            if (!(half > 0)) half = 1
            var mx0 = (minX + maxX) / 2, my0 = (minY + maxY) / 2
            for (var a9 = 0; a9 < m; a9++) {
                var q7 = vis[a9]
                U[q7] = (X[q7] - mx0) / half
                V[q7] = (Yp[q7] - my0) / half
            }
        } else {
            var rows = Math.max(leaves - 1, 1)
            for (var a10 = 0; a10 < m; a10++) {
                var q8 = vis[a10]
                U[q8] = depth[q8] / maxDepth
                V[q8] = Y[q8] / rows
            }
        }

        root.pL = { kind: kind, vis: vis, visMask: mask, U: U, V: V, Y: Y, ANG: ANG, RAD: RAD,
                    Ymin: Ymin, Ymax: Ymax, Dmax: Dmax, lod: new Uint8Array(n),
                    A0: (typeof a0 !== "undefined") ? a0 : null, A1: (typeof a1 !== "undefined") ? a1 : null,
                    PX: new Float64Array(n), PY: new Float64Array(n), broken: brkFlag, brkList: brkList,
                    leafCount: leaves, maxDepth: maxDepth, useLen: useLen, half: half }
        root.breakCount = brkList.length
        root.breakCandidates = brkCand
        root.leafCount = leaves
        root.nodeCount = m
        root.layoutDirty = false
    }

    function fontStr(px) {
        var f = root.appFont
        return Math.max(1, Math.round(px)) + "px " + ((f === "sans-serif" || f === "") ? "sans-serif" : "'" + f + "'")
    }

    function updateViewport(ctx, w, h) {
        ctx.font = fontStr(root.fontSize)
        var lw = 0
        if (root.showTips && root.pT.longest) lw = Math.min(ctx.measureText(root.pT.longest).width + 14, w * 0.3)
        var pad = 28, v = root.vp
        v.lw = lw
        if (root.pL.kind === "circular" || root.pL.kind === "radial") {
            v.cx = w / 2; v.cy = h / 2
            v.R = Math.max(30, Math.min(w, h) / 2 - pad - lw)
        } else {
            v.bw = Math.max(60, w - 2 * pad - lw)
            v.bh = Math.max(60, h - 2 * pad)
            v.cx = pad + v.bw / 2
            v.cy = pad + v.bh / 2
        }
    }

    function project() {
        var Lr = root.pL, v = root.vp, z = root.zoomFactor
        var vis = Lr.vis, U = Lr.U, V = Lr.V, PX = Lr.PX, PY = Lr.PY
        var px = root.panX, py = root.panY
        if (Lr.kind === "circular" || Lr.kind === "radial") {
            var s = v.R * z
            for (var k = 0; k < vis.length; k++) {
                var i = vis[k]
                PX[i] = v.cx + px + U[i] * s
                PY[i] = v.cy + py + V[i] * s
            }
        } else {
            var sx = v.bw * z, sy = v.bh * z * root.yStretch
            for (var k2 = 0; k2 < vis.length; k2++) {
                var i2 = vis[k2]
                PX[i2] = v.cx + px + (U[i2] - 0.5) * sx
                PY[i2] = v.cy + py + (V[i2] - 0.5) * sy
            }
        }
    }

    function layoutName() {
        var n = { rectangular: "Rectangular", slanted: "Slanted", circular: "Circular", radial: "Radial" }[root.layoutType]
        return (n || "Rectangular") + (root.useBranchLengths && root.pT && root.pT.hasLengths ? " phylogram" : " cladogram")
    }

    // ---------------------------------------------------- highlight geometry
    // g = { PX, PY, R, cx, cy, lw, rowH, xr, rowY(fn) } in whichever coordinate
    // space (screen or export) the caller is working in.
    function hlShape(hn, g) {
        var Lr = root.pL, t = root.pT, par = t.par, L = Math.max(Lr.leafCount, 1)
        if (Lr.kind === "radial") {
            var ax = g.PX[hn], ay = g.PY[hn], mr = 0, end = hn + t.size[hn], vis = Lr.vis
            for (var k = 0; k < vis.length; k++) {
                var q = vis[k]
                if (q < hn) continue
                if (q >= end) break
                var dx = g.PX[q] - ax, dy = g.PY[q] - ay, d = Math.sqrt(dx * dx + dy * dy)
                if (d > mr) mr = d
            }
            return { type: "wedge", ax: ax, ay: ay, r: mr + g.lw + 12, a0: Lr.A0[hn], a1: Lr.A1[hn] }
        }
        if (Lr.kind === "circular") {
            return { type: "sector", cx: g.cx, cy: g.cy,
                     ri: hn > 0 ? Lr.RAD[par[hn]] * g.R : 0, ro: g.R + g.lw + 10,
                     a0: (Lr.Ymin[hn] / L) * 2 * Math.PI - Math.PI / 2 - Math.PI / L,
                     a1: (Lr.Ymax[hn] / L) * 2 * Math.PI - Math.PI / 2 + Math.PI / L }
        }
        return { type: "rect", x0: hn > 0 ? g.PX[par[hn]] - 2 : g.PX[0] - 6, x1: g.xr,
                 y0: g.rowY(Lr.Ymin[hn]) - g.rowH / 2, y1: g.rowY(Lr.Ymax[hn]) + g.rowH / 2 }
    }

    function fillShape(ctx, s) {
        ctx.beginPath()
        if (s.type === "rect") {
            ctx.rect(s.x0, s.y0, s.x1 - s.x0, s.y1 - s.y0)
        } else if (s.type === "wedge") {
            if (s.a1 - s.a0 > 2 * Math.PI - 0.02) ctx.arc(s.ax, s.ay, s.r, 0, 2 * Math.PI)
            else { ctx.moveTo(s.ax, s.ay); ctx.arc(s.ax, s.ay, s.r, s.a0, s.a1, false); ctx.closePath() }
        } else {
            if (s.a1 - s.a0 > 2 * Math.PI - 0.02) ctx.arc(s.cx, s.cy, s.ro, 0, 2 * Math.PI)
            else {
                ctx.arc(s.cx, s.cy, s.ro, s.a0, s.a1, false)
                if (s.ri > 0.5) ctx.arc(s.cx, s.cy, s.ri, s.a1, s.a0, true)
                else ctx.lineTo(s.cx, s.cy)
                ctx.closePath()
            }
        }
        ctx.fill()
    }

    function nf(x) { return String(Math.round(x * 100) / 100) }

    // Centre and direction of a compressed branch, and the strokes of its "//" mark.
    // g = { PX, PY, cx, cy, R }
    function breakGeom(i, g) {
        var Lr = root.pL, a = root.pT.par[i], x, y, th
        if (Lr.kind === "circular") {
            var rm = (Lr.RAD[a] + Lr.RAD[i]) / 2 * g.R
            th = Lr.ANG[i]
            x = g.cx + rm * Math.cos(th); y = g.cy + rm * Math.sin(th)
        } else if (Lr.kind === "rectangular") {
            x = (g.PX[a] + g.PX[i]) / 2; y = g.PY[i]; th = 0
        } else {
            x = (g.PX[a] + g.PX[i]) / 2; y = (g.PY[a] + g.PY[i]) / 2
            th = Math.atan2(g.PY[i] - g.PY[a], g.PX[i] - g.PX[a])
        }
        var dx = Math.cos(th), dy = Math.sin(th), ux = Math.cos(th - 1.05), uy = Math.sin(th - 1.05)
        var segs = []
        for (var k = -1; k <= 1; k += 2) {
            var sx = x + dx * 3.5 * k, sy = y + dy * 3.5 * k
            segs.push([sx - ux * 7, sy - uy * 7, sx + ux * 7, sy + uy * 7])
        }
        return { gap: [x - dx * 7, y - dy * 7, x + dx * 7, y + dy * 7], segs: segs }
    }

    function shapePath(s) {
        var T = Math.PI * 2
        if (s.type === "rect")
            return "M" + nf(s.x0) + " " + nf(s.y0) + "H" + nf(s.x1) + "V" + nf(s.y1) + "H" + nf(s.x0) + "Z"
        if (s.type === "wedge") {
            if (s.a1 - s.a0 > T - 0.02)
                return "M" + nf(s.ax - s.r) + " " + nf(s.ay) + "A" + nf(s.r) + " " + nf(s.r) + " 0 1 0 " + nf(s.ax + s.r) + " " + nf(s.ay)
                       + "A" + nf(s.r) + " " + nf(s.r) + " 0 1 0 " + nf(s.ax - s.r) + " " + nf(s.ay) + "Z"
            var bigW = (s.a1 - s.a0) > Math.PI ? 1 : 0
            return "M" + nf(s.ax) + " " + nf(s.ay)
                   + "L" + nf(s.ax + s.r * Math.cos(s.a0)) + " " + nf(s.ay + s.r * Math.sin(s.a0))
                   + "A" + nf(s.r) + " " + nf(s.r) + " 0 " + bigW + " 1 "
                   + nf(s.ax + s.r * Math.cos(s.a1)) + " " + nf(s.ay + s.r * Math.sin(s.a1)) + "Z"
        }
        if (s.a1 - s.a0 > T - 0.02)
            return "M" + nf(s.cx - s.ro) + " " + nf(s.cy) + "A" + nf(s.ro) + " " + nf(s.ro) + " 0 1 0 " + nf(s.cx + s.ro) + " " + nf(s.cy)
                   + "A" + nf(s.ro) + " " + nf(s.ro) + " 0 1 0 " + nf(s.cx - s.ro) + " " + nf(s.cy) + "Z"
        var big = (s.a1 - s.a0) > Math.PI ? 1 : 0
        var d = "M" + nf(s.cx + s.ro * Math.cos(s.a0)) + " " + nf(s.cy + s.ro * Math.sin(s.a0))
              + "A" + nf(s.ro) + " " + nf(s.ro) + " 0 " + big + " 1 "
              + nf(s.cx + s.ro * Math.cos(s.a1)) + " " + nf(s.cy + s.ro * Math.sin(s.a1))
        if (s.ri > 0.5)
            d += "L" + nf(s.cx + s.ri * Math.cos(s.a1)) + " " + nf(s.cy + s.ri * Math.sin(s.a1))
               + "A" + nf(s.ri) + " " + nf(s.ri) + " 0 " + big + " 0 "
               + nf(s.cx + s.ri * Math.cos(s.a0)) + " " + nf(s.cy + s.ri * Math.sin(s.a0))
        else d += "L" + nf(s.cx) + " " + nf(s.cy)
        return d + "Z"
    }

    // ----------------------------------------------------------------- drawing
    function drawTree(ctx, w, h) {
        var Lr = root.pL, t = root.pT, v = root.vp, cat = root.cat
        var vis = Lr.vis, PX = Lr.PX, PY = Lr.PY, par = t.par, ch = t.children, col = root.collapsed
        var kind = Lr.kind
        var polar = (kind === "circular" || kind === "radial")
        var fs = root.fontSize, z = root.zoomFactor
        var lite = root.interacting && (root.performanceMode || Lr.leafCount > 4000)
        var branchStr = root.branchColor.toString()
        var zr = polar ? v.R * z : 0
        var ccx = v.cx + root.panX, ccy = v.cy + root.panY
        var rowPx = polar ? (2 * Math.PI * zr) / Math.max(Lr.leafCount, 1)
                          : (v.bh * z * root.yStretch) / Math.max(Lr.leafCount - 1, 1)
        var alignX = v.cx + root.panX + 0.5 * v.bw * z
        var align = root.alignTips && kind !== "radial"
        var pxUnit = 0
        if (Lr.useLen) pxUnit = kind === "circular" ? zr / Lr.maxDepth
                              : (kind === "radial" ? zr / Lr.half : v.bw * z / Lr.maxDepth)
        var sel = root.selIndex, selEnd = sel >= 0 ? sel + t.size[sel] : -1
        var match = root.matchFlags, pk = root.pickedFlags
        var lineW = root.lineWidth
        var lod = Lr.lod

        function trace(i) {
            var a = par[i], x0 = PX[a], y0 = PY[a], x1 = PX[i], y1 = PY[i]
            if (kind === "circular") {
                var an = Lr.ANG[i], ap = Lr.ANG[a], rp = Lr.RAD[a] * zr, ri = Lr.RAD[i] * zr
                ctx.moveTo(ccx + rp * Math.cos(ap), ccy + rp * Math.sin(ap))
                if (rp > 0.5 && an !== ap) ctx.arc(ccx, ccy, rp, ap, an, an < ap)
                ctx.lineTo(ccx + ri * Math.cos(an), ccy + ri * Math.sin(an))
                return
            }
            if (Math.max(x0, x1) < -8 || Math.min(x0, x1) > w + 8
                    || Math.max(y0, y1) < -8 || Math.min(y0, y1) > h + 8) return
            ctx.moveTo(x0, y0)
            if (kind === "rectangular") { ctx.lineTo(x0, y1); ctx.lineTo(x1, y1) }
            else ctx.lineTo(x1, y1)
        }
        function inView(x, y, m) { return x > -m && x < w + m && y > -m && y < h + m }

        // ---- level of detail: clades thinner than ~2px become one solid wedge
        lod.fill(0)
        var lodList = []
        if (kind !== "radial") {
            var lk = 0, lodPx = 2.2
            while (lk < vis.length) {
                var li0 = vis[lk]
                if (li0 !== 0 && ch[li0].length > 0 && col[li0] !== true) {
                    var span = Lr.Ymax[li0] - Lr.Ymin[li0]
                    var ext = polar ? (span / Math.max(Lr.leafCount, 1)) * 2 * Math.PI * Math.max(Lr.Dmax[li0], 0.02) * zr
                                    : span * rowPx
                    if (ext < lodPx) {
                        lodList.push(li0)
                        var endIdx = li0 + t.size[li0]
                        lk++
                        while (lk < vis.length && vis[lk] < endIdx) { lod[vis[lk]] = 1; lk++ }
                        continue
                    }
                }
                lk++
            }
        }
        root.lodCount = lodList.length

        ctx.lineCap = "round"
        ctx.lineJoin = "round"

        // ---- clade highlights (shaded backgrounds)
        var hlKeys = Object.keys(root.highlights)
        if (hlKeys.length > 0) {
            var hsy = v.bh * z * root.yStretch, hrows = Math.max(Lr.leafCount - 1, 1)
            var hg = { PX: PX, PY: PY, R: zr, cx: ccx, cy: ccy, lw: v.lw || 0, rowH: rowPx,
                       xr: alignX + (v.lw || 0) + 4,
                       rowY: function (yy) { return v.cy + root.panY + (yy / hrows - 0.5) * hsy } }
            ctx.globalAlpha = 0.6
            for (var hi = 0; hi < hlKeys.length; hi++) {
                var hn = parseInt(hlKeys[hi])
                if (!Lr.visMask[hn] || lod[hn]) continue
                ctx.fillStyle = root.highlights[hlKeys[hi]]
                fillShape(ctx, hlShape(hn, hg))
            }
            ctx.globalAlpha = 1
        }

        // ---- alignment guides
        if (align && !lite) {
            ctx.beginPath()
            ctx.strokeStyle = "#d7dce2"
            ctx.lineWidth = 1
            for (var g = 0; g < vis.length; g++) {
                var gi = vis[g]
                if (ch[gi].length !== 0 || lod[gi]) continue
                var tx = PX[gi], ty = PY[gi], ex, ey
                if (kind === "circular") { ex = ccx + zr * Math.cos(Lr.ANG[gi]); ey = ccy + zr * Math.sin(Lr.ANG[gi]) }
                else { ex = alignX; ey = ty }
                if (Math.abs(ex - tx) + Math.abs(ey - ty) < 3) continue
                if (!inView(tx, ty, 40) && !inView(ex, ey, 40)) continue
                ctx.moveTo(tx, ty); ctx.lineTo(ex, ey)
            }
            ctx.stroke()
        }

        // ---- edges, batched per color
        var buckets = {}, keys = []
        for (var k = 1; k < vis.length; k++) {
            var i = vis[k]
            if (lod[i]) continue
            var colr = branchStr
            if (cat) {
                var cc = cat.nodeCat[i]
                if (cc >= 0 && (root.colorBranches || ch[i].length === 0 || col[i] === true)) colr = cat.colors[cc]
            }
            if (!buckets[colr]) { buckets[colr] = []; keys.push(colr) }
            buckets[colr].push(i)
        }
        ctx.lineWidth = lineW
        for (var b = 0; b < keys.length; b++) {
            var list = buckets[keys[b]]
            ctx.beginPath()
            ctx.strokeStyle = keys[b]
            for (var e = 0; e < list.length; e++) trace(list[e])
            ctx.stroke()
        }

        // ---- LOD wedges (batched per color)
        if (lodList.length > 0) {
            var gb = {}, gk = []
            for (var gq = 0; gq < lodList.length; gq++) {
                var gn = lodList[gq]
                var gcol = "#7a8591"
                if (cat && cat.nodeCat[gn] >= 0) gcol = cat.colors[cat.nodeCat[gn]]
                if (!gb[gcol]) { gb[gcol] = []; gk.push(gcol) }
                gb[gcol].push(gn)
            }
            ctx.globalAlpha = 0.85
            for (var gc = 0; gc < gk.length; gc++) {
                var gl = gb[gk[gc]]
                ctx.beginPath()
                ctx.fillStyle = gk[gc]
                for (var gj = 0; gj < gl.length; gj++) {
                    var gx = gl[gj]
                    if (kind === "circular") {
                        var ga = Lr.ANG[gx]
                        var r0 = Lr.RAD[gx] * zr, r1 = Math.max(Lr.Dmax[gx] * zr, r0 + 1)
                        var gspan = ((Lr.Ymax[gx] - Lr.Ymin[gx]) / Math.max(Lr.leafCount, 1)) * Math.PI + 0.3 / Math.max(r1, 1)
                        var c1 = Math.cos(ga - gspan), s1 = Math.sin(ga - gspan)
                        var c2 = Math.cos(ga + gspan), s2 = Math.sin(ga + gspan)
                        ctx.moveTo(ccx + r0 * c1, ccy + r0 * s1)
                        ctx.lineTo(ccx + r1 * c1, ccy + r1 * s1)
                        ctx.lineTo(ccx + r1 * c2, ccy + r1 * s2)
                        ctx.lineTo(ccx + r0 * c2, ccy + r0 * s2)
                        ctx.closePath()
                    } else {
                        var gx0 = PX[gx], gy = PY[gx]
                        var gx1 = v.cx + root.panX + (Lr.Dmax[gx] - 0.5) * v.bw * z
                        var gh = Math.max((Lr.Ymax[gx] - Lr.Ymin[gx]) * rowPx / 2, 0.6)
                        if (gy < -10 || gy > h + 10 || gx1 < -10 || gx0 > w + 10) continue
                        ctx.rect(gx0, gy - gh, Math.max(gx1 - gx0, 1), gh * 2)
                    }
                }
                ctx.fill()
            }
            ctx.globalAlpha = 1
        }

        // ---- selected clade
        if (sel >= 0 && Lr.visMask[sel] && !lod[sel]) {
            ctx.beginPath()
            ctx.strokeStyle = "#2f6fed"
            ctx.lineWidth = lineW + 1.5
            for (var s = 0; s < vis.length; s++) {
                var si = vis[s]
                if (si >= sel && si < selEnd && si > 0 && !lod[si]) trace(si)
            }
            ctx.stroke()
        }

        // ---- axis-break marks on compressed branches
        if (Lr.brkList && Lr.brkList.length > 0) {
            var brkG = { PX: PX, PY: PY, cx: ccx, cy: ccy, R: zr }
            for (var bkk = 0; bkk < Lr.brkList.length; bkk++) {
                var bki = Lr.brkList[bkk]
                if (lod[bki]) continue
                var bkm = breakGeom(bki, brkG)
                ctx.lineCap = "butt"
                ctx.strokeStyle = "#ffffff"
                ctx.lineWidth = lineW + 4
                ctx.beginPath(); ctx.moveTo(bkm.gap[0], bkm.gap[1]); ctx.lineTo(bkm.gap[2], bkm.gap[3]); ctx.stroke()
                ctx.strokeStyle = branchStr
                ctx.lineWidth = Math.max(1.2, lineW)
                ctx.beginPath()
                for (var bks = 0; bks < bkm.segs.length; bks++) {
                    ctx.moveTo(bkm.segs[bks][0], bkm.segs[bks][1]); ctx.lineTo(bkm.segs[bks][2], bkm.segs[bks][3])
                }
                ctx.stroke()
                ctx.lineCap = "round"
            }
        }

        // ---- collapsed clades as triangles
        for (var c = 0; c < vis.length; c++) {
            var ci = vis[c]
            if (col[ci] !== true || ch[ci].length === 0 || lod[ci]) continue
            var cx0 = PX[ci], cy0 = PY[ci]
            if (!inView(cx0, cy0, 80)) continue
            var ang = polar ? Lr.ANG[ci] : 0
            var halfH = polar ? 9 : Math.max(5, Math.min(rowPx * 0.42, 60))
            var dx = Math.cos(ang), dy = Math.sin(ang), nx = -dy, ny = dx, tl = 26
            ctx.beginPath()
            ctx.moveTo(cx0, cy0)
            ctx.lineTo(cx0 + dx * tl + nx * halfH, cy0 + dy * tl + ny * halfH)
            ctx.lineTo(cx0 + dx * tl - nx * halfH, cy0 + dy * tl - ny * halfH)
            ctx.closePath()
            var tcol = "#8b96a3"
            if (cat && cat.nodeCat[ci] >= 0) tcol = cat.colors[cat.nodeCat[ci]]
            ctx.globalAlpha = 0.85
            ctx.fillStyle = tcol
            ctx.fill()
            ctx.globalAlpha = 1
        }

        // ---- internal node dots
        if (root.showNodeDots && !lite) {
            ctx.beginPath()
            ctx.fillStyle = branchStr
            for (var d = 1; d < vis.length; d++) {
                var di = vis[d]
                if (ch[di].length === 0 || col[di] === true || lod[di]) continue
                if (!inView(PX[di], PY[di], 4)) continue
                ctx.moveTo(PX[di] + 2.6, PY[di])
                ctx.arc(PX[di], PY[di], 2.6, 0, Math.PI * 2)
            }
            ctx.fill()
        }

        // ---- support values and branch lengths
        if ((root.showSupport || root.showLengths) && !lite && !root.performanceMode) {
            ctx.font = fontStr(Math.max(8, fs - 2))
            ctx.fillStyle = "#6b7480"
            for (var u = 1; u < vis.length; u++) {
                var ui = vis[u]
                if (lod[ui]) continue
                var x1 = PX[ui], y1 = PY[ui]
                if (!inView(x1, y1, 30)) continue
                if (root.showSupport && ch[ui].length > 0 && col[ui] !== true) {
                    var st = supportLabel(t, ui)
                    if (st !== "") {
                        ctx.textAlign = "right"; ctx.textBaseline = "bottom"
                        ctx.fillText(st, x1 - 3, y1 - 2)
                    }
                }
                if (root.showLengths && t.len[ui] > 0) {
                    var lt = String(parseFloat(t.len[ui].toPrecision(3)))
                    var p = par[ui], mxx, myy, segPx
                    if (kind === "circular") {
                        var rm = (Lr.RAD[p] + Lr.RAD[ui]) / 2 * zr
                        mxx = ccx + rm * Math.cos(Lr.ANG[ui]); myy = ccy + rm * Math.sin(Lr.ANG[ui])
                        segPx = (Lr.RAD[ui] - Lr.RAD[p]) * zr
                    } else if (kind === "rectangular") {
                        mxx = (PX[p] + x1) / 2; myy = y1 - 2; segPx = x1 - PX[p]
                    } else {
                        mxx = (PX[p] + x1) / 2; myy = (PY[p] + y1) / 2 - 2
                        segPx = Math.sqrt((x1 - PX[p]) * (x1 - PX[p]) + (y1 - PY[p]) * (y1 - PY[p]))
                    }
                    if (segPx > lt.length * fs * 0.55 + 6) {
                        ctx.textAlign = "center"; ctx.textBaseline = "bottom"
                        ctx.fillText(lt, mxx, myy)
                    }
                }
            }
        }

        // ---- search match rings (always visible, even when labels are thinned out)
        if (match && root.matchList.length > 0) {
            ctx.beginPath()
            ctx.fillStyle = "#ffd54a"
            ctx.strokeStyle = "#b58900"
            ctx.lineWidth = 1
            for (var mi = 0; mi < root.matchList.length; mi++) {
                var mIdx = root.matchList[mi]
                if (!Lr.visMask[mIdx]) continue
                var mx = PX[mIdx], my = PY[mIdx]
                if (!inView(mx, my, 10)) continue
                ctx.moveTo(mx + 4.5, my)
                ctx.arc(mx, my, 4.5, 0, Math.PI * 2)
            }
            ctx.fill()
            ctx.stroke()
        }

        // ---- picked tip rings
        if (pk && root.pickedCount > 0) {
            ctx.beginPath()
            ctx.strokeStyle = "#2f6fed"
            ctx.fillStyle = "rgba(47,111,237,0.25)"
            ctx.lineWidth = 1.5
            var tlist = t.tipList
            for (var pi = 0; pi < tlist.length; pi++) {
                var pIdx = tlist[pi]
                if (!pk[pIdx] || !Lr.visMask[pIdx]) continue
                var pxx = PX[pIdx], pyy = PY[pIdx]
                if (!inView(pxx, pyy, 10)) continue
                ctx.moveTo(pxx + 5, pyy)
                ctx.arc(pxx, pyy, 5, 0, Math.PI * 2)
            }
            ctx.fill()
            ctx.stroke()
        }

        // ---- selection ring
        if (sel >= 0 && Lr.visMask[sel] && !lod[sel]) {
            ctx.beginPath()
            ctx.strokeStyle = "#2f6fed"
            ctx.lineWidth = 2
            ctx.arc(PX[sel], PY[sel], 6.5, 0, Math.PI * 2)
            ctx.stroke()
        }

        // ---- labels
        ctx.font = fontStr(fs)
        ctx.textBaseline = "middle"
        var thin = Math.max(1, Math.ceil(fs * 1.1 / Math.max(rowPx, 0.01)))

        function putLabel(txt, lx, ly, a, flip, color, bg) {
            if (polar) {
                ctx.save()
                ctx.translate(lx, ly)
                ctx.rotate(flip ? a + Math.PI : a)
                ctx.textAlign = flip ? "right" : "left"
                if (bg) {
                    var tw = ctx.measureText(txt).width
                    ctx.fillStyle = bg
                    ctx.fillRect(flip ? -tw - 2 : -2, -fs / 2 - 2, tw + 4, fs + 4)
                }
                ctx.fillStyle = color
                ctx.fillText(txt, 0, 0)
                ctx.restore()
            } else {
                ctx.textAlign = "left"
                if (bg) {
                    var tw2 = ctx.measureText(txt).width
                    ctx.fillStyle = bg
                    ctx.fillRect(lx - 2, ly - fs / 2 - 2, tw2 + 4, fs + 4)
                }
                ctx.fillStyle = color
                ctx.fillText(txt, lx, ly)
            }
        }

        // filled label bands (manual "fill" coloring): drawn even where text is thinned out, so color regions stay visible
        var fcat = cat && cat.fillCat ? cat.fillCat : null
        if (fcat && root.showTips) {
            var longestW = align ? ctx.measureText(t.longest || "").width : 0
            var bandH = Math.max(fs + 4, rowPx)
            for (var fb = 0; fb < vis.length; fb++) {
                var fi = vis[fb]
                if (fcat[fi] < 0) continue
                var fa = polar ? Lr.ANG[fi] : 0
                var fx = PX[fi], fy = PY[fi]
                if (align) {
                    if (kind === "circular") { fx = ccx + zr * Math.cos(fa); fy = ccy + zr * Math.sin(fa) }
                    else if (kind !== "radial") fx = alignX
                }
                if (fx < -300 || fx > w + 300 || fy < -30 || fy > h + 30) continue
                var flx = fx + Math.cos(fa) * 6, fly = fy + Math.sin(fa) * 6
                var ftw = align ? longestW : ctx.measureText(t.names[fi]).width
                ctx.fillStyle = cat.colors[fcat[fi]]
                if (polar) {
                    var fflip = Math.cos(fa) < 0
                    ctx.save()
                    ctx.translate(flx, fly)
                    ctx.rotate(fflip ? fa + Math.PI : fa)
                    ctx.fillRect(fflip ? -ftw - 3 : -3, -bandH / 2, ftw + 6, bandH + 0.75)
                    ctx.restore()
                } else ctx.fillRect(flx - 3, fly - bandH / 2, ftw + 6, bandH + 0.75)
            }
        }

        for (var l = 0; l < vis.length; l++) {
            var li = vis[l]
            var coll = col[li] === true && ch[li].length > 0
            var isTip = ch[li].length === 0
            if (!isTip && !coll) continue
            var isM = match && match[li] === 1
            var isP = pk && pk[li] === 1
            var special = isM || isP
            if (lod[li] && !special) continue
            if (!coll && !root.showTips && !special) continue
            if (lite && !special && !coll) continue
            if (!coll && !special && thin > 1 && (Lr.Y[li] % thin) !== 0) continue

            var txt = coll ? ((t.names[li] ? t.names[li] + " " : "") + "(" + t.tips[li] + " tips)") : t.names[li]
            if (!txt) continue
            var ax = PX[li], ay = PY[li], a = polar ? Lr.ANG[li] : 0
            if (!coll && align) {
                if (kind === "circular") { ax = ccx + zr * Math.cos(a); ay = ccy + zr * Math.sin(a) }
                else if (kind !== "radial") ax = alignX
            }
            if (ax < -300 || ax > w + 300 || ay < -30 || ay > h + 30) continue

            var off = 6 + (coll ? 26 : 0)
            var lx = ax + Math.cos(a) * off, ly = ay + Math.sin(a) * off
            var flip = polar && Math.cos(a) < 0
            var tcolor = coll ? "#4a5560" : "#1c2128"
            if (cat && cat.nodeCat[li] >= 0) tcolor = cat.colors[cat.nodeCat[li]]
            if (fcat && fcat[li] >= 0) tcolor = textOn(cat.colors[fcat[li]])
            var bg = null
            if (isM) { bg = "#ffd54a"; tcolor = "#000000" }
            if (isP) { bg = "#bcd3ff"; tcolor = "#0b2a6b" }
            putLabel(txt, lx, ly, a, flip, tcolor, bg)
        }

        // ---- scale bar
        if (root.showScale && pxUnit > 0) {
            var raw = 110 / pxUnit
            var p10 = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10)), mm = raw / p10
            var nice = (mm < 1.5 ? 1 : (mm < 3.5 ? 2 : (mm < 7.5 ? 5 : 10))) * p10
            var barW = nice * pxUnit, bx = 20, by = h - 28
            ctx.strokeStyle = "#4a5560"
            ctx.lineWidth = 1.5
            ctx.beginPath()
            ctx.moveTo(bx, by); ctx.lineTo(bx + barW, by)
            ctx.moveTo(bx, by - 4); ctx.lineTo(bx, by + 4)
            ctx.moveTo(bx + barW, by - 4); ctx.lineTo(bx + barW, by + 4)
            ctx.stroke()
            ctx.font = fontStr(Math.max(9, fs - 1))
            ctx.fillStyle = "#4a5560"
            ctx.textAlign = "left"
            ctx.textBaseline = "top"
            ctx.fillText(String(parseFloat(nice.toPrecision(3))), bx, by + 7)
        }

        // ---- legend (drawn on the canvas so it is included in exported images)
        if (cat && cat.labels.length > 0) {
            ctx.font = fontStr(fs)
            var nShow = Math.min(cat.labels.length, 16), maxW = 60
            for (var q = 0; q < nShow; q++)
                maxW = Math.max(maxW, ctx.measureText(cat.labels[q] + "  (" + cat.counts[q] + ")").width)
            var rowH = fs + 7
            var lgW = maxW + 44, lgH = 34 + nShow * rowH + (cat.labels.length > nShow ? rowH : 0)
            ctx.fillStyle = "rgba(255,255,255,0.94)"
            ctx.strokeStyle = "#d9dde3"
            ctx.lineWidth = 1
            ctx.beginPath()
            ctx.roundedRect(14, 14, lgW, lgH, 8, 8)
            ctx.fill()
            ctx.stroke()
            ctx.textAlign = "left"
            ctx.textBaseline = "middle"
            ctx.fillStyle = "#1c2128"
            ctx.font = "bold " + fontStr(fs)
            ctx.fillText("Legend", 28, 14 + 16)
            ctx.font = fontStr(fs)
            for (var r = 0; r < nShow; r++) {
                var yy = 14 + 34 + r * rowH + rowH / 2 - 2
                ctx.fillStyle = cat.colors[r]
                ctx.fillRect(28, yy - 5, 11, 11)
                ctx.fillStyle = "#4a5560"
                ctx.fillText(cat.labels[r] + "  (" + cat.counts[r] + ")", 46, yy)
            }
            if (cat.labels.length > nShow) {
                ctx.fillStyle = "#8a94a0"
                ctx.fillText("+ " + (cat.labels.length - nShow) + " more", 28, 14 + 34 + nShow * rowH + rowH / 2 - 2)
            }
        }
    }

    // ------------------------------------------------------------ figure export
    function xmlEsc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    }

    // Builds a standalone SVG of the WHOLE tree (not the current viewport) at a
    // readable row spacing, using the current layout / colors / display options.
    // opts: { selection: bool (include search matches, picks, selected clade),
    //         rasterFonts: bool (single font family, for the SVG->PDF/PNG renderer) }
    function buildSvg(opts) {
        if (!root.pT) return ""
        opts = opts || {}
        if (root.layoutDirty || !root.pL) computeLayout()
        var Lr = root.pL, t = root.pT, cat = root.cat, col = root.collapsed
        var vis = Lr.vis, par = t.par, ch = t.children, n = t.n
        var kind = Lr.kind, polar = (kind === "circular" || kind === "radial")
        var fs = root.fontSize, L = Math.max(Lr.leafCount, 1)
        var withSel = opts.selection === true
        var branchStr = root.branchColor.toString()
        var align = root.alignTips && kind !== "radial"
        var rowH = root.showTips ? Math.max(fs * 1.4, 4) : Math.max(2, Math.min(10, 900 / L))
        var pad = 30, treeW = 900

        tm.text = t.longest || ""
        var lw = root.showTips ? tm.width + 14 : 0
        var hasScale = root.showScale && Lr.useLen

        // legend size
        var legend = null, legendW = 0
        if (cat && cat.labels.length > 0) {
            var nShow = Math.min(cat.labels.length, 40), mw = 70
            for (var q = 0; q < nShow; q++) {
                tm.text = cat.labels[q] + "  (" + cat.counts[q] + ")"
                if (tm.width > mw) mw = tm.width
            }
            legend = { n: nShow, w: mw + 46, rh: fs + 7 }
            legendW = legend.w + 24
        }

        // canvas size and projection
        var R = 0, W, H, cx = 0, cy = 0
        var barSpace = hasScale ? 44 : 0
        if (!polar) {
            W = pad * 2 + treeW + lw + legendW
            H = pad * 2 + L * rowH + barSpace
        } else {
            R = Math.max(220, Math.min(6000, L * rowH / (2 * Math.PI)))
            cx = pad + R + lw
            cy = cx
            W = 2 * cx + legendW
            H = 2 * cy + barSpace
        }
        W = Math.round(W); H = Math.round(H)

        var PX = new Float64Array(n), PY = new Float64Array(n)
        for (var k = 0; k < vis.length; k++) {
            var i = vis[k]
            if (polar) { PX[i] = cx + Lr.U[i] * R; PY[i] = cy + Lr.V[i] * R }
            else { PX[i] = pad + Lr.U[i] * treeW; PY[i] = pad + (Lr.Y[i] + 0.5) * rowH }
        }

        function colOf(idx) {
            var c = branchStr
            if (cat) {
                var cc = cat.nodeCat[idx]
                if (cc >= 0 && (root.colorBranches || ch[idx].length === 0 || col[idx] === true)) c = cat.colors[cc]
            }
            return c
        }
        function edgeD(idx) {
            var a = par[idx], x0 = PX[a], y0 = PY[a], x1 = PX[idx], y1 = PY[idx]
            if (kind === "circular") {
                var an = Lr.ANG[idx], ap = Lr.ANG[a], rp = Lr.RAD[a] * R, ri = Lr.RAD[idx] * R
                var d = "M" + nf(cx + rp * Math.cos(ap)) + " " + nf(cy + rp * Math.sin(ap))
                if (rp > 0.5 && an !== ap)
                    d += "A" + nf(rp) + " " + nf(rp) + " 0 0 " + (an > ap ? 1 : 0) + " "
                         + nf(cx + rp * Math.cos(an)) + " " + nf(cy + rp * Math.sin(an))
                return d + "L" + nf(cx + ri * Math.cos(an)) + " " + nf(cy + ri * Math.sin(an))
            }
            if (kind === "rectangular")
                return "M" + nf(x0) + " " + nf(y0) + "L" + nf(x0) + " " + nf(y1) + "L" + nf(x1) + " " + nf(y1)
            return "M" + nf(x0) + " " + nf(y0) + "L" + nf(x1) + " " + nf(y1)
        }

        var fam = root.appFont
        var base = (!fam || fam === "sans-serif") ? "sans-serif" : fam
        var famAttr = opts.rasterFonts ? base
                    : (base === "sans-serif" ? "Arial, Helvetica, sans-serif" : base + ", Arial, Helvetica, sans-serif")

        var out = []
        out.push('<?xml version="1.0" encoding="UTF-8"?>')
        out.push('<svg xmlns="http://www.w3.org/2000/svg" width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '">')
        out.push('<rect x="0" y="0" width="' + W + '" height="' + H + '" fill="#ffffff"/>')

        // ---- clade highlights
        var hlKeys = Object.keys(root.highlights)
        if (hlKeys.length > 0) {
            var hg = { PX: PX, PY: PY, R: R, cx: cx, cy: cy, lw: lw, rowH: rowH,
                       xr: pad + treeW + lw + 6, rowY: function (yy) { return pad + (yy + 0.5) * rowH } }
            out.push('<g fill-opacity="0.6">')
            for (var hi = 0; hi < hlKeys.length; hi++) {
                var hn = parseInt(hlKeys[hi])
                if (!Lr.visMask[hn]) continue
                out.push('<path d="' + shapePath(hlShape(hn, hg)) + '" fill="' + root.highlights[hlKeys[hi]] + '"/>')
            }
            out.push('</g>')
        }

        // ---- alignment guides
        if (align) {
            var gd = []
            for (var g = 0; g < vis.length; g++) {
                var gi = vis[g]
                if (ch[gi].length !== 0) continue
                var ex = kind === "circular" ? cx + R * Math.cos(Lr.ANG[gi]) : pad + treeW
                var ey = kind === "circular" ? cy + R * Math.sin(Lr.ANG[gi]) : PY[gi]
                if (Math.abs(ex - PX[gi]) + Math.abs(ey - PY[gi]) < 3) continue
                gd.push("M" + nf(PX[gi]) + " " + nf(PY[gi]) + "L" + nf(ex) + " " + nf(ey))
            }
            if (gd.length) out.push('<path d="' + gd.join("") + '" fill="none" stroke="#d7dce2" stroke-width="0.8"/>')
        }

        // ---- edges, one path per color
        var buckets = {}, keys = []
        for (var e = 1; e < vis.length; e++) {
            var ei = vis[e], c = colOf(ei)
            if (!buckets[c]) { buckets[c] = []; keys.push(c) }
            buckets[c].push(edgeD(ei))
        }
        out.push('<g fill="none" stroke-linecap="round" stroke-linejoin="round" stroke-width="' + nf(root.lineWidth) + '">')
        for (var b = 0; b < keys.length; b++)
            out.push('<path d="' + buckets[keys[b]].join("") + '" stroke="' + keys[b] + '"/>')
        out.push('</g>')

        // ---- selected clade (optional)
        var sel = root.selIndex
        if (withSel && sel > 0 && Lr.visMask[sel]) {
            var sd = [], selEnd = sel + t.size[sel]
            for (var sv = 0; sv < vis.length; sv++) {
                var si = vis[sv]
                if (si >= sel && si < selEnd && si > 0) sd.push(edgeD(si))
            }
            out.push('<path d="' + sd.join("") + '" fill="none" stroke="#2f6fed" stroke-width="' + nf(root.lineWidth + 1.5)
                     + '" stroke-linecap="round" stroke-linejoin="round"/>')
        }

        // ---- axis-break marks
        if (Lr.brkList && Lr.brkList.length > 0) {
            var sbg = { PX: PX, PY: PY, cx: cx, cy: cy, R: R }, sgap = [], sstr = []
            for (var sbk = 0; sbk < Lr.brkList.length; sbk++) {
                var sgm = breakGeom(Lr.brkList[sbk], sbg)
                sgap.push("M" + nf(sgm.gap[0]) + " " + nf(sgm.gap[1]) + "L" + nf(sgm.gap[2]) + " " + nf(sgm.gap[3]))
                for (var ssg = 0; ssg < sgm.segs.length; ssg++)
                    sstr.push("M" + nf(sgm.segs[ssg][0]) + " " + nf(sgm.segs[ssg][1]) + "L" + nf(sgm.segs[ssg][2]) + " " + nf(sgm.segs[ssg][3]))
            }
            out.push('<path d="' + sgap.join("") + '" fill="none" stroke="#ffffff" stroke-width="' + nf(root.lineWidth + 4) + '"/>')
            out.push('<path d="' + sstr.join("") + '" fill="none" stroke="' + branchStr + '" stroke-width="' + nf(Math.max(1.2, root.lineWidth)) + '"/>')
        }

        // ---- collapsed clades as triangles
        for (var cI = 0; cI < vis.length; cI++) {
            var ci = vis[cI]
            if (col[ci] !== true || ch[ci].length === 0) continue
            var ang = polar ? Lr.ANG[ci] : 0
            var half = polar ? 9 : rowH * 0.42
            var tdx = Math.cos(ang), tdy = Math.sin(ang), tnx = -tdy, tny = tdx, tl = 26
            var tcol = (cat && cat.nodeCat[ci] >= 0) ? cat.colors[cat.nodeCat[ci]] : "#8b96a3"
            out.push('<path d="M' + nf(PX[ci]) + " " + nf(PY[ci])
                     + "L" + nf(PX[ci] + tdx * tl + tnx * half) + " " + nf(PY[ci] + tdy * tl + tny * half)
                     + "L" + nf(PX[ci] + tdx * tl - tnx * half) + " " + nf(PY[ci] + tdy * tl - tny * half)
                     + 'Z" fill="' + tcol + '" fill-opacity="0.85"/>')
        }

        // ---- internal node dots
        if (root.showNodeDots) {
            var dd = []
            for (var dI = 1; dI < vis.length; dI++) {
                var di = vis[dI]
                if (ch[di].length === 0 || col[di] === true) continue
                dd.push("M" + nf(PX[di] - 2.6) + " " + nf(PY[di]) + "a2.6 2.6 0 1 0 5.2 0a2.6 2.6 0 1 0 -5.2 0")
            }
            if (dd.length) out.push('<path d="' + dd.join("") + '" fill="' + branchStr + '"/>')
        }

        // ---- support values and branch lengths
        var sfs = Math.max(8, fs - 2)
        if (root.showSupport || root.showLengths) {
            out.push('<g font-family="' + xmlEsc(famAttr) + '" font-size="' + nf(sfs) + '" fill="#6b7480">')
            for (var u = 1; u < vis.length; u++) {
                var ui = vis[u], px1 = PX[ui], py1 = PY[ui], pp = par[ui]
                if (root.showSupport && ch[ui].length > 0 && col[ui] !== true && supportLabel(t, ui) !== "")
                    out.push('<text x="' + nf(px1 - 3) + '" y="' + nf(py1 - 2 - sfs * 0.2) + '" text-anchor="end">'
                             + xmlEsc(supportLabel(t, ui)) + '</text>')
                if (root.showLengths && t.len[ui] > 0) {
                    var lt = String(parseFloat(t.len[ui].toPrecision(3))), mxx, myy, segPx
                    if (kind === "circular") {
                        var rm = (Lr.RAD[pp] + Lr.RAD[ui]) / 2 * R
                        mxx = cx + rm * Math.cos(Lr.ANG[ui]); myy = cy + rm * Math.sin(Lr.ANG[ui])
                        segPx = (Lr.RAD[ui] - Lr.RAD[pp]) * R
                    } else if (kind === "rectangular") {
                        mxx = (PX[pp] + px1) / 2; myy = py1 - 2; segPx = px1 - PX[pp]
                    } else {
                        mxx = (PX[pp] + px1) / 2; myy = (PY[pp] + py1) / 2 - 2
                        segPx = Math.sqrt((px1 - PX[pp]) * (px1 - PX[pp]) + (py1 - PY[pp]) * (py1 - PY[pp]))
                    }
                    if (segPx > lt.length * fs * 0.55 + 6)
                        out.push('<text x="' + nf(mxx) + '" y="' + nf(myy - sfs * 0.2) + '" text-anchor="middle">' + lt + '</text>')
                }
            }
            out.push('</g>')
        }

        // ---- search match markers and picked tips (optional)
        if (withSel) {
            var mk = []
            if (root.matchFlags)
                for (var mi = 0; mi < root.matchList.length; mi++) {
                    var mIdx = root.matchList[mi]
                    if (Lr.visMask[mIdx]) mk.push("M" + nf(PX[mIdx] - 4.5) + " " + nf(PY[mIdx]) + "a4.5 4.5 0 1 0 9 0a4.5 4.5 0 1 0 -9 0")
                }
            if (mk.length) out.push('<path d="' + mk.join("") + '" fill="#ffd54a" stroke="#b58900" stroke-width="1"/>')
            var pk = []
            if (root.pickedFlags && root.pickedCount > 0)
                for (var pi = 0; pi < t.tipList.length; pi++) {
                    var pIdx = t.tipList[pi]
                    if (root.pickedFlags[pIdx] && Lr.visMask[pIdx])
                        pk.push("M" + nf(PX[pIdx] - 5) + " " + nf(PY[pIdx]) + "a5 5 0 1 0 10 0a5 5 0 1 0 -10 0")
                }
            if (pk.length) out.push('<path d="' + pk.join("") + '" fill="#2f6fed" fill-opacity="0.25" stroke="#2f6fed" stroke-width="1.5"/>')
        }

        // ---- labels
        out.push('<g font-family="' + xmlEsc(famAttr) + '" font-size="' + nf(fs) + '">')
        var baseY = nf(fs * 0.35)
        var fcat = cat && cat.fillCat ? cat.fillCat : null
        if (fcat && root.showTips) {
            tm.text = t.longest || ""
            var longestW = tm.width
            for (var fb = 0; fb < vis.length; fb++) {
                var fi = vis[fb]
                if (fcat[fi] < 0) continue
                var fa = polar ? Lr.ANG[fi] : 0
                var fx = PX[fi], fy = PY[fi]
                if (align) {
                    if (kind === "circular") { fx = cx + R * Math.cos(fa); fy = cy + R * Math.sin(fa) }
                    else fx = pad + treeW
                }
                var flx = fx + Math.cos(fa) * 6, fly = fy + Math.sin(fa) * 6
                var ftw = longestW
                if (!align) { tm.text = t.names[fi]; ftw = tm.width }
                var bh = Math.max(fs + 4, rowH) + 0.5
                if (polar) {
                    var fflip = Math.cos(fa) < 0
                    var ftr = 'translate(' + nf(flx) + ' ' + nf(fly) + ') rotate(' + nf((fflip ? fa + Math.PI : fa) * 180 / Math.PI) + ')'
                    out.push('<rect transform="' + ftr + '" x="' + nf(fflip ? -ftw - 3 : -3) + '" y="' + nf(-bh / 2)
                             + '" width="' + nf(ftw + 6) + '" height="' + nf(bh) + '" fill="' + cat.colors[fcat[fi]] + '"/>')
                } else
                    out.push('<rect x="' + nf(flx - 3) + '" y="' + nf(fly - bh / 2) + '" width="' + nf(ftw + 6)
                             + '" height="' + nf(bh) + '" fill="' + cat.colors[fcat[fi]] + '"/>')
            }
        }
        for (var l = 0; l < vis.length; l++) {
            var li = vis[l]
            var coll = col[li] === true && ch[li].length > 0
            if (ch[li].length !== 0 && !coll) continue
            if (!coll && !root.showTips) continue
            var txt = coll ? ((t.names[li] ? t.names[li] + " " : "") + "(" + t.tips[li] + " tips)") : t.names[li]
            if (!txt) continue
            var isM = withSel && root.matchFlags && root.matchFlags[li] === 1
            var isP = withSel && root.pickedFlags && root.pickedFlags[li] === 1
            var ax = PX[li], ay = PY[li], a = polar ? Lr.ANG[li] : 0
            if (!coll && align) {
                if (kind === "circular") { ax = cx + R * Math.cos(a); ay = cy + R * Math.sin(a) }
                else ax = pad + treeW
            }
            var off = 6 + (coll ? 26 : 0)
            var lx = ax + Math.cos(a) * off, ly = ay + Math.sin(a) * off
            var flip = polar && Math.cos(a) < 0
            var tcolor = coll ? "#4a5560" : "#1c2128"
            if (cat && cat.nodeCat[li] >= 0) tcolor = cat.colors[cat.nodeCat[li]]
            if (fcat && fcat[li] >= 0) tcolor = textOn(cat.colors[fcat[li]])
            var bg = null
            if (isM) { bg = "#ffd54a"; tcolor = "#000000" }
            if (isP) { bg = "#bcd3ff"; tcolor = "#0b2a6b" }
            var tw = 0
            if (bg) { tm.text = txt; tw = tm.width }
            if (polar) {
                var tr = 'translate(' + nf(lx) + ' ' + nf(ly) + ') rotate(' + nf((flip ? a + Math.PI : a) * 180 / Math.PI) + ')'
                if (bg)
                    out.push('<rect transform="' + tr + '" x="' + nf(flip ? -tw - 2 : -2) + '" y="' + nf(-fs / 2 - 2)
                             + '" width="' + nf(tw + 4) + '" height="' + nf(fs + 4) + '" fill="' + bg + '"/>')
                out.push('<text transform="' + tr + '" x="0" y="' + baseY + '" fill="' + tcolor + '"'
                         + (flip ? ' text-anchor="end"' : '') + '>' + xmlEsc(txt) + '</text>')
            } else {
                if (bg)
                    out.push('<rect x="' + nf(lx - 2) + '" y="' + nf(ly - fs / 2 - 2) + '" width="' + nf(tw + 4)
                             + '" height="' + nf(fs + 4) + '" fill="' + bg + '"/>')
                out.push('<text x="' + nf(lx) + '" y="' + nf(ly + fs * 0.35) + '" fill="' + tcolor + '">' + xmlEsc(txt) + '</text>')
            }
        }
        out.push('</g>')

        // ---- scale bar
        if (hasScale) {
            var pxUnit = kind === "circular" ? R / Lr.maxDepth : (kind === "radial" ? R / Lr.half : treeW / Lr.maxDepth)
            var raw = 110 / pxUnit
            var p10 = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10)), mm = raw / p10
            var nice = (mm < 1.5 ? 1 : (mm < 3.5 ? 2 : (mm < 7.5 ? 5 : 10))) * p10
            var barW = nice * pxUnit, bx = pad, by = H - 26
            out.push('<path d="M' + nf(bx) + " " + nf(by) + "H" + nf(bx + barW) + "M" + nf(bx) + " " + nf(by - 4) + "V" + nf(by + 4)
                     + "M" + nf(bx + barW) + " " + nf(by - 4) + "V" + nf(by + 4) + '" fill="none" stroke="#4a5560" stroke-width="1.5"/>')
            out.push('<text x="' + nf(bx) + '" y="' + nf(by + 8 + fs * 0.8) + '" font-family="' + xmlEsc(famAttr) + '" font-size="'
                     + nf(Math.max(9, fs - 1)) + '" fill="#4a5560">' + String(parseFloat(nice.toPrecision(3))) + '</text>')
        }

        // ---- legend (to the right of the figure, never over the tree)
        if (legend) {
            var lx0 = W - legendW, ly0 = pad
            var lh = 34 + legend.n * legend.rh + (cat.labels.length > legend.n ? legend.rh : 0)
            out.push('<g font-family="' + xmlEsc(famAttr) + '" font-size="' + nf(fs) + '">')
            out.push('<rect x="' + nf(lx0) + '" y="' + nf(ly0) + '" width="' + nf(legend.w) + '" height="' + nf(lh)
                     + '" rx="8" fill="#ffffff" stroke="#d9dde3"/>')
            out.push('<text x="' + nf(lx0 + 14) + '" y="' + nf(ly0 + 16 + fs * 0.35) + '" font-weight="bold" fill="#1c2128">'
                     + xmlEsc(root.colorColumn !== "" ? root.colorColumn : "Legend") + '</text>')
            for (var r = 0; r < legend.n; r++) {
                var ry = ly0 + 34 + r * legend.rh + legend.rh / 2 - 2
                out.push('<rect x="' + nf(lx0 + 14) + '" y="' + nf(ry - 5) + '" width="11" height="11" fill="' + cat.colors[r] + '"/>')
                out.push('<text x="' + nf(lx0 + 32) + '" y="' + nf(ry + fs * 0.35) + '" fill="#4a5560">'
                         + xmlEsc(cat.labels[r] + "  (" + cat.counts[r] + ")") + '</text>')
            }
            if (cat.labels.length > legend.n)
                out.push('<text x="' + nf(lx0 + 14) + '" y="' + nf(ly0 + 34 + legend.n * legend.rh + legend.rh / 2 + fs * 0.35 - 2)
                         + '" fill="#8a94a0">+ ' + (cat.labels.length - legend.n) + ' more</text>')
            out.push('</g>')
        }

        out.push('</svg>')
        return out.join("\n")
    }

    // ------------------------------------------------------------------ canvas
    TextMetrics { id: tm; font.pixelSize: root.fontSize; font.family: root.appFont }

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        renderTarget: root.gpuCanvas ? Canvas.FramebufferObject : Canvas.Image

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var t0 = Date.now()
            var ctx = getContext("2d")
            ctx.reset()
            ctx.fillStyle = "#ffffff"
            ctx.fillRect(0, 0, width, height)
            if (!root.pT || width < 10 || height < 10) return

            if (root.layoutDirty || !root.pL) root.computeLayout()
            root.updateViewport(ctx, width, height)
            root.project()
            root.drawTree(ctx, width, height)
            root.lastRenderMs = Date.now() - t0

            if (root.announceLayout) {
                root.announceLayout = false
                root.notify(root.layoutName() + " layout · " + root.lastRenderMs + " ms")
            }
        }
        onPainted: {
            if (root.firstRenderPending && root.pT) {
                root.firstRenderPending = false
                root.renderFinished(root.lastRenderMs, root.totalTips, root.pT.n)
            }
        }
    }

    // ------------------------------------------------------------ interaction
    ParallelAnimation {
        id: viewAnim
        NumberAnimation { id: aZoom; target: root; property: "zoomFactor"; duration: 170; easing.type: Easing.OutCubic }
        NumberAnimation { id: aPx; target: root; property: "panX"; duration: 170; easing.type: Easing.OutCubic }
        NumberAnimation { id: aPy; target: root; property: "panY"; duration: 170; easing.type: Easing.OutCubic }
        NumberAnimation { id: aYs; target: root; property: "yStretch"; duration: 170; easing.type: Easing.OutCubic }
    }

    Timer {
        id: interactTimer
        interval: 160
        onTriggered: { root.interacting = false; canvas.requestPaint() }
    }

    // Wheel: zoom at cursor. On big rectangular trees the wheel favours vertical
    // zoom (x grows slowly) so rows become readable without the tree exploding
    // sideways. Shift = vertical only, Ctrl = horizontal only.
    HoverHandler { id: wheelHover }
    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (event) => {
            var d = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
            if (d === 0 || !root.pT) return
            var f = Math.exp(d * 0.0011)
            root.interacting = true
            interactTimer.restart()
            // var m = event.point.position
            var m = wheelHover.point.position
            if (root.isPolar()) { root.zoomAbout(m.x, m.y, f); return }
            if (event.modifiers & Qt.ShiftModifier) root.zoomAboutXY(m.x, m.y, 1, f)
            else if (event.modifiers & Qt.ControlModifier) root.zoomAboutXY(m.x, m.y, f, 1)
            else if (root.pL && root.pL.leafCount > 250) root.zoomAboutXY(m.x, m.y, Math.pow(f, 0.35), f)
            else root.zoomAbout(m.x, m.y, f)
        }
    }

    // Pan
    DragHandler {
        id: dragH
        target: null
        enabled: !root.zoomTool && !root.selectTool
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        acceptedModifiers: Qt.NoModifier
        property real lx: 0
        property real ly: 0
        onActiveChanged: {
            if (active) {
                lx = centroid.position.x; ly = centroid.position.y
                viewAnim.stop()
                root.tgtZoom = root.zoomFactor; root.tgtPanX = root.panX
                root.tgtPanY = root.panY; root.tgtYs = root.yStretch
                root.interacting = true
                interactTimer.stop()
                root.forceActiveFocus()
            } else {
                interactTimer.restart()
            }
        }
        onCentroidChanged: {
            if (!active) return
            root.panX += centroid.position.x - lx
            root.panY += centroid.position.y - ly
            root.tgtPanX = root.panX; root.tgtPanY = root.panY
            lx = centroid.position.x; ly = centroid.position.y
        }
    }

    // Rubber-band zoom: Shift+drag anywhere, or drag while the zoom-box tool is on
    DragHandler {
        id: boxH
        target: null
        acceptedButtons: Qt.LeftButton
        acceptedModifiers: root.zoomTool ? Qt.KeyboardModifierMask : Qt.ShiftModifier
        onActiveChanged: {
            if (active) {
                root.boxIsSelect = false
                viewAnim.stop()
                root.bx0 = centroid.pressPosition.x; root.by0 = centroid.pressPosition.y
                root.bx1 = centroid.position.x; root.by1 = centroid.position.y
                root.boxActive = true
                root.forceActiveFocus()
            } else {
                root.boxActive = false
                root.zoomToRect(root.bx0, root.by0, root.bx1, root.by1)
                root.zoomTool = false
            }
        }
        onCentroidChanged: {
            if (!active) return
            root.bx1 = centroid.position.x
            root.by1 = centroid.position.y
        }
    }

    // Box select: drag with the select tool on (replaces the picks), or Ctrl/Cmd+drag any time (adds to them)
    DragHandler {
        id: selH
        target: null
        enabled: root.selectTool
        acceptedButtons: Qt.LeftButton
        acceptedModifiers: Qt.NoModifier
        onActiveChanged: {
            if (active) root.beginBox(true, centroid.pressPosition.x, centroid.pressPosition.y)
            else { root.boxActive = false; root.boxSelect(root.bx0, root.by0, root.bx1, root.by1, false) }
        }
        onCentroidChanged: { if (active) { root.bx1 = centroid.position.x; root.by1 = centroid.position.y } }
    }
    DragHandler {
        id: selAddH
        target: null
        enabled: !root.zoomTool
        acceptedButtons: Qt.LeftButton
        acceptedModifiers: Qt.ControlModifier
        onActiveChanged: {
            if (active) root.beginBox(true, centroid.pressPosition.x, centroid.pressPosition.y)
            else { root.boxActive = false; root.boxSelect(root.bx0, root.by0, root.bx1, root.by1, true) }
        }
        onCentroidChanged: { if (active) { root.bx1 = centroid.position.x; root.by1 = centroid.position.y } }
    }

    // Taps: plain = select, double = pick label / collapse clade, Ctrl|Shift = add to picks
    TapHandler {
        acceptedModifiers: Qt.NoModifier
        onTapped: (point) => { root.forceActiveFocus(); root.handleTap(point.position.x, point.position.y, "plain") }
        onDoubleTapped: (point) => root.handleTap(point.position.x, point.position.y, "double")
    }
    TapHandler {
        acceptedModifiers: Qt.ControlModifier      // Command on macOS
        onTapped: (point) => { root.forceActiveFocus(); root.handleTap(point.position.x, point.position.y, "additive") }
    }
    TapHandler {
        acceptedModifiers: Qt.ShiftModifier
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: (point) => { root.forceActiveFocus(); root.handleTap(point.position.x, point.position.y, "additive") }
    }

    Keys.onPressed: (event) => {
        if (event.matches(StandardKey.Copy)) { root.copyLabels(); event.accepted = true }
    }
    Keys.onEscapePressed: { root.zoomTool = false; root.selectTool = false; root.colOpen = false; root.clearAll() }
    onPickedCountChanged: if (pickedCount === 0) root.colOpen = false

    // -------------------------------------------------------------- overlay UI
    Rectangle {
        visible: root.boxActive
        x: Math.min(root.bx0, root.bx1)
        y: Math.min(root.by0, root.by1)
        width: Math.abs(root.bx1 - root.bx0)
        height: Math.abs(root.by1 - root.by0)
        color: root.boxIsSelect ? "#2628a745" : "#262f6fed"
        border.color: root.boxIsSelect ? "#28a745" : "#2f6fed"
        border.width: 1.5
    }

    component Chip: Rectangle {
        id: chip
        property string label: ""
        property string tip: ""
        property bool on: false
        property int fontPx: 13
        signal clicked()
        implicitHeight: 30
        implicitWidth: chipText.implicitWidth + 22
        radius: 7
        color: chip.on ? "#dbe5fd" : (chipMa.containsMouse ? "#eef1f5" : "#ffffff")
        border.color: chip.on ? "#2f6fed" : "#d9dde3"
        Text { id: chipText; anchors.centerIn: parent; text: chip.label; font.pixelSize: chip.fontPx; color: "#1c2128" }
        MouseArea {
            id: chipMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
        ToolTip.visible: chip.tip !== "" && chipMa.containsMouse
        ToolTip.text: chip.tip
        ToolTip.delay: 450
    }

    Column {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 16
        spacing: 8
        visible: root.pT !== null
        Chip { width: 32; implicitWidth: 32; label: "+"; fontPx: 18; tip: "Zoom in"
               onClicked: root.zoomAbout(root.width / 2, root.height / 2, 1.35) }
        Chip { width: 32; implicitWidth: 32; label: "−"; fontPx: 18; tip: "Zoom out"
               onClicked: root.zoomAbout(root.width / 2, root.height / 2, 1 / 1.35) }
        Chip { width: 32; implicitWidth: 32; label: "⛶"; fontPx: 15; tip: "Fit whole tree  (Ctrl+0)"
               onClicked: root.fitView() }
        Chip { width: 32; implicitWidth: 32; label: "⬚"; fontPx: 16; on: root.zoomTool
               tip: "Zoom to box — drag a rectangle (or hold Shift and drag)"
               onClicked: { root.zoomTool = !root.zoomTool; if (root.zoomTool) root.selectTool = false } }
        Chip { width: 32; implicitWidth: 32; label: "▣"; fontPx: 15; on: root.selectTool
               tip: "Select tips by box — drag a rectangle, then color or copy them (or hold Ctrl/Cmd and drag)"
               onClicked: { root.selectTool = !root.selectTool; if (root.selectTool) root.zoomTool = false } }
        Chip { width: 32; implicitWidth: 32; label: "≡"; fontPx: 17
               tip: "Readable rows — spread tips so every label is legible"
               onClicked: root.readableRows() }
        Chip { width: 32; implicitWidth: 32; label: "↶"; fontPx: 16; tip: "Previous view"
               visible: root.viewHistory.length > 0
               onClicked: root.zoomBack() }
    }

    Row {
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 14
        spacing: 8
        visible: root.pT !== null
        Chip { visible: root.canUndo; label: "↶ Undo edit"; fontPx: 12
               tip: "Undo the last reroot / extract  (Ctrl+Z)"; onClicked: root.undoRequested() }
        Chip { visible: root.collapsedCount > 0; label: "Expand all  (" + root.collapsedCount + " collapsed)"; fontPx: 12
               onClicked: root.expandAll() }
        Chip { visible: root.breakCount > 0; label: "// Long branch compressed  ·  show true scale"; fontPx: 12
               tip: "A branch longer than half the tree was shortened so the rest is readable"
               onClicked: root.breakToggled(false) }
        Chip { visible: root.breakCount === 0 && root.breakCandidates > 0 && !root.breakLongBranches
               label: "Compress long branch"; fontPx: 12
               tip: "Shorten the very long branch so the rest of the tree gets the full width"
               onClicked: root.breakToggled(true) }
        Chip { visible: root.manualCount > 0; label: "Clear colors  (" + root.manualCount + " tips)"; fontPx: 12
               tip: "Remove the colors you applied by hand"; onClicked: root.clearManualColors() }
        Chip { visible: root.highlightCount > 0; label: "Clear highlights  (" + root.highlightCount + ")"; fontPx: 12
               onClicked: root.clearHighlights() }
    }

    Rectangle {
        id: selCard
        visible: (root.selIndex >= 0 || root.pickedCount > 0) && root.pT !== null
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
        width: Math.min(root.width - 32, 620)
        height: selCol.implicitHeight + 22
        radius: 10
        color: "#ffffff"
        border.color: "#d9dde3"

        ColumnLayout {
            id: selCol
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 11 }
            spacing: 8

            Text {
                text: root.pickedCount > 0
                      ? root.pickedCount + (root.pickedCount === 1 ? " label picked" : " labels picked")
                      : root.selectionText
                font.pixelSize: 13
                font.bold: true
                color: root.pickedCount > 0 ? "#2f6fed" : "#1c2128"
                Layout.fillWidth: true
                elide: Text.ElideMiddle
            }

            Flow {
                Layout.fillWidth: true
                spacing: 6
                visible: !root.hlOpen && !root.colOpen
                Chip { visible: root.pickedCount > 0; label: "Color…"; fontPx: 12; on: root.manualCount > 0
                       tip: "Color the picked tips"; onClicked: root.colOpen = true }
                Chip { visible: root.selIsInternal && root.pickedCount === 0
                       label: root.selIsCollapsed ? "Expand" : "Collapse"; fontPx: 12; onClicked: root.toggleSelected() }
                Chip { visible: root.selIndex >= 0 && root.pickedCount === 0
                       label: "Highlight"; fontPx: 12; on: root.highlights[root.selIndex] !== undefined
                       tip: "Shade the background behind this clade"; onClicked: root.hlOpen = true }
                Chip { visible: root.selIndex > 0 && root.pickedCount === 0
                       label: "Reroot"; fontPx: 12; tip: "Place the root on the branch above this node"
                       onClicked: root.rerootRequested(root.selIndex) }
                Chip { visible: root.selIsInternal && root.pickedCount === 0
                       label: "Extract clade"; fontPx: 12; tip: "Replace the tree with just this clade (undoable)"
                       onClicked: root.extractRequested(root.selIndex) }
                Chip { visible: root.selIsInternal && root.pickedCount === 0
                       label: "Open in new window"; fontPx: 12; tip: "Open this clade as its own tree in a new window"
                       onClicked: root.newWindowRequested(root.selIndex) }
                Chip { visible: root.selIndex > 0 && root.pickedCount === 0
                       label: "Parent"; fontPx: 12; onClicked: root.selectParent() }
                Chip { label: "Copy"; fontPx: 12; tip: "Copy label(s) — Ctrl/Cmd+C"; onClicked: root.copyLabels() }
                Chip { label: "✕"; fontPx: 12; onClicked: root.clearAll() }
            }

            Flow {
                Layout.fillWidth: true
                spacing: 8
                visible: root.colOpen
                Repeater {
                    model: root.manualPalette
                    delegate: Rectangle {
                        required property var modelData
                        width: 28; height: 28; radius: 14
                        color: modelData.color
                        border.color: cMa.containsMouse ? "#1c2128" : "#ffffff"
                        border.width: 2
                        MouseArea {
                            id: cMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.colorPicked(parent.modelData.color, parent.modelData.name, root.fillLabels); root.colOpen = false }
                            ToolTip.visible: containsMouse
                            ToolTip.text: parent.modelData.name
                        }
                    }
                }
                Chip { label: "Fill label background"; fontPx: 12; on: root.fillLabels
                       tip: "On: fill a band behind each picked label (like a poster figure). Off: color the text and branches."
                       onClicked: root.fillLabels = !root.fillLabels }
                Chip { label: "Uncolor"; fontPx: 12; tip: "Remove manual color from the picked tips"
                       onClicked: { root.colorPicked("", ""); root.colOpen = false } }
                Chip { label: "Cancel"; fontPx: 12; onClicked: root.colOpen = false }
            }

            Flow {
                Layout.fillWidth: true
                spacing: 8
                visible: root.hlOpen
                Repeater {
                    model: ["#fde68a", "#bfdbfe", "#bbf7d0", "#fecdd3", "#ddd6fe", "#fed7aa", "#a5f3fc", "#e5e7eb"]
                    delegate: Rectangle {
                        required property string modelData
                        width: 28; height: 28; radius: 7
                        color: modelData
                        border.color: swMa.containsMouse ? "#2f6fed" : "#b9c0c9"
                        border.width: swMa.containsMouse ? 2 : 1
                        MouseArea {
                            id: swMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.highlightSelected(parent.modelData); root.hlOpen = false }
                        }
                    }
                }
                Chip { label: "Remove"; fontPx: 12; visible: root.highlights[root.selIndex] !== undefined
                       onClicked: { root.unhighlightSelected(); root.hlOpen = false } }
                Chip { label: "Cancel"; fontPx: 12; onClicked: root.hlOpen = false }
            }
        }
    }
}
