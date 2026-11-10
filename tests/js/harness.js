'use strict';
// Runs the real JavaScript functions of TreeCanvas.qml under Node, with a mocked `root` and
// text-measuring object, so layout and SVG export can be tested without Qt.
const fs = require('fs');
const path = require('path');

function findCanvas() {
  if (process.env.CANVAS_QML) return process.env.CANVAS_QML;
  const root = path.resolve(__dirname, '..', '..');
  const skip = new Set(['node_modules', '.git', 'build']);
  const stack = [root];
  while (stack.length) {
    const d = stack.pop();
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.isDirectory()) { if (!skip.has(e.name) && !e.name.startsWith('build')) stack.push(path.join(d, e.name)); }
      else if (e.name === 'TreeCanvas.qml') return path.join(d, e.name);
    }
  }
  throw new Error('TreeCanvas.qml not found; set CANVAS_QML=/path/to/TreeCanvas.qml');
}
const src = fs.readFileSync(findCanvas(), 'utf8');

function grab(name) {
  const i = src.indexOf('    function ' + name + '(');
  if (i < 0) throw new Error('function not found in TreeCanvas.qml: ' + name);
  let d = 0, k = src.indexOf('{', i);
  for (; k < src.length; k++) { if (src[k] === '{') d++; else if (src[k] === '}' && --d === 0) break; }
  return src.slice(i, k + 1).replace('    function ', 'function ');
}
const NAMES = ['computeLayout', 'breakGeom', 'hlShape', 'fillShape', 'nf', 'shapePath', 'xmlEsc', 'buildSvg',
  'columnIndex', 'isPolar', 'labelAnchor', 'refreshSelection', 'clearPicked', 'ensurePicked', 'pickClade',
  'baseCategories', 'recomputeCategories', 'applyManualColors', 'colorPicked', 'clearManualColors',
  'tipsInRect', 'boxSelect', 'textOn', 'supportOf', 'supportLabel'];
const code = NAMES.map(grab).join('\n\n');

// Iterative Newick parser -> flat pre-order node list (no recursion: safe for ladder trees).
function parseNewick(s) {
  const nodes = [], stack = [];
  let cur = -1, i = 0;
  const add = (parent) => { nodes.push({ par: parent, name: '', len: 0, support: NaN, kids: [] });
    if (parent >= 0) nodes[parent].kids.push(nodes.length - 1); return nodes.length - 1; };
  cur = add(-1);
  const isDelim = (c) => '(),:;['.includes(c);
  while (i < s.length) {
    const c = s[i];
    if (c === ' ' || c === '\n' || c === '\t') { i++; continue; }
    if (c === ';') break;
    if (c === '(') { const n = add(cur); stack.push(cur); cur = n; i++; continue; }
    if (c === ')') { cur = stack.pop(); i++; continue; }
    if (c === ',') { cur = add(nodes[cur].par); i++; continue; }
    if (c === ':') { i++; const m = /^[-+0-9.eE]+/.exec(s.slice(i, i + 40))[0]; nodes[cur].len = parseFloat(m); i += m.length; continue; }
    let label = '';
    if (c === "'") { i++; while (i < s.length && s[i] !== "'") label += s[i++]; i++; }
    else { const j0 = i; while (i < s.length && !isDelim(s[i])) i++; label = s.slice(j0, i).trim(); }
    nodes[cur].name = label;      // support labels are recognised later by the canvas's own supportOf()
  }
  return nodes;
}

function toPT(nodes) {
  const n = nodes.length, size = new Int32Array(n), tips = new Int32Array(n);
  for (let i = n - 1; i >= 0; i--) {
    size[i] += 1; if (!nodes[i].kids.length) tips[i] += 1;
    const p = nodes[i].par; if (p >= 0) { size[p] += size[i]; tips[p] += tips[i]; }
  }
  let longest = ''; const tipList = [];
  nodes.forEach((x, i) => { if (!x.kids.length) { tipList.push(i); if (x.name.length > longest.length) longest = x.name; } });
  return { n, par: nodes.map(x => (x.par < 0 ? 0 : x.par)), len: nodes.map(x => x.len), names: nodes.map(x => x.name),
           children: nodes.map(x => x.kids), size, tips, support: nodes.map(x => x.support),
           hasLengths: nodes.some(x => x.len > 0), longest, tipList };
}

function run(pT, over, opts) {
  const root = Object.assign({
    pT, pL: null, collapsed: {}, cat: null, matchFlags: null, matchList: [], pickedFlags: null, pickedCount: 0,
    selIndex: -1, layoutDirty: true, layoutType: 'rectangular', ladderize: 'none', useBranchLengths: true,
    fontSize: 12, lineWidth: 1.5, branchColor: { toString: () => '#333a44' }, showTips: true, alignTips: false,
    showNodeDots: false, showScale: true, showSupport: false, showLengths: false, colorBranches: true,
    appFont: 'sans-serif', highlights: {}, colorColumn: '', leafCount: 0, nodeCount: 0,
    breakLongBranches: true, breakCount: 0, breakCandidates: 0,
    colorEnabled: false, colorPattern: '', metadata: null, manualGroups: [], manualCount: 0, categoryCount: 0,
    regexError: '', selectionText: '', selIsInternal: false, selIsCollapsed: false, notes: [],
    palette: ['#2f6fed', '#e83e8c', '#28a745', '#f59f00', '#17a2b8', '#6f42c1', '#fd7e14', '#20c997', '#dc3545', '#8d6e63'],
    notify(msg) { this.notes.push(msg); }
  }, over || {});
  const tm = { text: '', get width() { return this.text.length * 6.5; } };
  const canvas = { requestPaint() {} };
  const Qt = { hsla: (h) => ({ toString: () => 'hsl(' + Math.round(h * 360) + ',68%,46%)' }) };
  const exportsList = NAMES.join(', ');
  const f = new Function('root', 'tm', 'canvas', 'Qt', code + '\nreturn { ' + exportsList + ' };')(root, tm, canvas, Qt);
  // mirror prepareTree: internal labels that are support values leave the name and become support/supText
  if (!pT.supText) {
    pT.supText = new Array(pT.n).fill('');
    for (let i = 1; i < pT.n; i++) {
      if (!pT.children[i].length) continue;
      const sp = f.supportOf(pT.names[i]);
      if (sp) { pT.support[i] = sp.value; pT.supText[i] = sp.text; pT.names[i] = ''; }
    }
  }
  const svg = f.buildSvg(opts);
  return { svg, root, f };
}

// Minimal well-formedness check for the simple SVG we emit (tags balanced, no raw '&' or '<' in text).
function checkWellFormed(xml) {
  const body = xml.replace(/^<\?xml[^>]*\?>\s*/, '');
  const re = /<(\/?)([A-Za-z][\w:-]*)((?:\s+[\w:-]+="[^"]*")*)\s*(\/?)>|([^<]+)/g;
  const stack = []; let m, pos = 0;
  while ((m = re.exec(body))) {
    if (m.index !== pos) throw new Error('unparsed content at ' + pos + ': ' + body.slice(pos, pos + 60));
    pos = re.lastIndex;
    if (m[5] !== undefined) { if (/&(?!(amp|lt|gt|quot|apos|#\d+);)/.test(m[5])) throw new Error('bad entity in text: ' + m[5].slice(0, 60)); continue; }
    if (m[1]) { const top = stack.pop(); if (top !== m[2]) throw new Error('mismatched </' + m[2] + '> expected </' + top + '>'); }
    else if (!m[4]) stack.push(m[2]);
  }
  if (pos !== body.length) throw new Error('trailing junk');
  if (stack.length) throw new Error('unclosed: ' + stack.join(','));
  return true;
}

module.exports = { parseNewick, toPT, run, checkWellFormed };
