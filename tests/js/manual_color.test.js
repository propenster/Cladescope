'use strict';
// Box selection and manual coloring (the logic behind "drag a box, then color the tips").
const test = require('node:test');
const assert = require('node:assert/strict');
const { parseNewick, toPT, run } = require('./harness');

const SMALL = '((A_x:0.1,B_x:0.2)95:0.3,((C_y:0.1,D_y:0.1)80:0.2,(E_z:0.4,F_z:0.2,G_z:0.1)99:0.1)88:0.2,H_w:0.9);';
const RED = '#dc3545', BLUE = '#2f6fed';

// Build a laid-out canvas and give every node deterministic "screen" coordinates
// (x = 100 * depth-order, y = 20 * row) the way the paint pass would.
function setup(newick, over) {
  const pT = toPT(parseNewick(newick || SMALL));
  const r = run(pT, over);
  const L = r.root.pL;
  L.PX = new Float64Array(pT.n); L.PY = new Float64Array(pT.n);
  for (let i = 0; i < pT.n; i++) { L.PX[i] = 50 + L.U[i] * 400; L.PY[i] = 20 + L.Y[i] * 20; }
  return { ...r, pT, L };
}
const nameOf = (c, i) => c.pT.names[i];
const tipRows = (c) => c.pT.tipList.map((i) => ({ i, name: c.pT.names[i], y: c.L.PY[i] }));
const pick = (c, names) => { // pick tips by name through the real selection state
  c.f.clearPicked(); c.f.ensurePicked();
  for (const i of c.pT.tipList) if (names.includes(c.pT.names[i])) { c.root.pickedFlags[i] = 1; c.root.pickedCount++; }
};
const colorOf = (c, name) => {
  const i = c.pT.names.indexOf(name), k = c.root.cat && c.root.cat.nodeCat[i];
  return k >= 0 ? c.root.cat.colors[k] : null;
};

test('tipsInRect returns exactly the tips whose point is inside the box', () => {
  const c = setup();
  const rows = tipRows(c).sort((a, b) => a.y - b.y);
  const wanted = rows.slice(2, 5);                                 // three consecutive rows
  const y0 = wanted[0].y - 5, y1 = wanted[2].y + 5;
  const got = c.f.tipsInRect(0, y0, 10000, y1).map((i) => nameOf(c, i)).sort();
  assert.deepEqual(got, wanted.map((w) => w.name).sort());
  assert.deepEqual(c.f.tipsInRect(y1 + 1000, 0, y1 + 1100, 50), []);   // empty region
});

test('the rectangle may be dragged in any direction', () => {
  const c = setup();
  const a = c.f.tipsInRect(0, 0, 10000, 10000).length;
  const b = c.f.tipsInRect(10000, 10000, 0, 0).length;
  assert.equal(a, 8); assert.equal(b, 8);
});

test('boxSelect replaces picks, additive mode extends them', () => {
  const c = setup();
  const rows = tipRows(c).sort((a, b) => a.y - b.y);
  const box = (k) => [0, rows[k].y - 5, 10000, rows[k].y + 5];
  assert.equal(c.f.boxSelect(...box(0), false), 1);
  assert.equal(c.f.boxSelect(...box(1), false), 1);                // replaced, not extended
  assert.equal(c.root.pickedFlags[rows[0].i], 0);
  assert.equal(c.f.boxSelect(...box(2), true), 2);                 // added: now two picked
  assert.equal(c.root.pickedFlags[rows[1].i], 1);
  assert.equal(c.root.pickedFlags[rows[2].i], 1);
  assert.equal(c.f.boxSelect(0, -500, 10, -400, true), 0);         // empty box: no hits ...
  assert.equal(c.root.pickedCount, 2);                             // ... and the picks are unchanged
  assert.match(c.root.notes.at(-1), /No tips/);
});

test('a collapsed clade inside the box picks every tip below it', () => {
  const pT = toPT(parseNewick(SMALL));
  const efg = pT.names.indexOf('E_z'); const clade = pT.par[efg];
  const c = setup(SMALL, { collapsed: { [clade]: true } });
  c.f.computeLayout && c.f.computeLayout();
  const L = c.root.pL;
  L.PX = new Float64Array(c.pT.n); L.PY = new Float64Array(c.pT.n);
  for (let i = 0; i < c.pT.n; i++) { L.PX[i] = 50 + L.U[i] * 400; L.PY[i] = 20 + L.Y[i] * 20; }
  const n = c.f.boxSelect(0, 0, 10000, 10000, false);
  assert.equal(n, 8);                                              // 5 visible tips + 3 under the collapsed clade
  for (const nm of ['E_z', 'F_z', 'G_z']) assert.equal(c.root.pickedFlags[c.pT.names.indexOf(nm)], 1);
});

test('colorPicked colors exactly the picked tips and builds a legend entry', () => {
  const c = setup();
  pick(c, ['A_x', 'B_x', 'H_w']);
  c.f.colorPicked(RED, 'Red');
  for (const nm of ['A_x', 'B_x', 'H_w']) assert.equal(colorOf(c, nm), RED);
  for (const nm of ['C_y', 'D_y', 'E_z', 'F_z', 'G_z']) assert.equal(colorOf(c, nm), null);
  assert.deepEqual(c.root.cat.labels, ['Red']);
  assert.deepEqual(c.root.cat.counts, [3]);
  assert.equal(c.root.manualCount, 3);
});

test('a clade whose tips share one color colors its branch; a mixed clade does not', () => {
  const c = setup();
  pick(c, ['A_x', 'B_x', 'C_y']);
  c.f.colorPicked(RED, 'Red');
  const ab = c.pT.par[c.pT.names.indexOf('A_x')], cd = c.pT.par[c.pT.names.indexOf('C_y')];
  assert.equal(c.root.cat.colors[c.root.cat.nodeCat[ab]], RED);    // (A,B) both red
  assert.equal(c.root.cat.nodeCat[cd], -1);                        // (C,D): only C is red
});

test('recoloring moves tips between groups and empty groups disappear', () => {
  const c = setup();
  pick(c, ['A_x', 'B_x', 'C_y']); c.f.colorPicked(RED, 'Red');
  pick(c, ['A_x', 'B_x']);        c.f.colorPicked(BLUE, 'Blue');   // A,B leave red
  assert.equal(colorOf(c, 'A_x'), BLUE);
  assert.equal(colorOf(c, 'C_y'), RED);
  assert.deepEqual(c.root.cat.labels.sort(), ['Blue', 'Red']);
  pick(c, ['C_y']);               c.f.colorPicked(BLUE, 'Blue');   // red group is now empty -> gone; same color merges
  assert.deepEqual(c.root.cat.labels, ['Blue']);
  assert.equal(c.root.cat.counts[0], 3);
  assert.equal(c.root.manualGroups.length, 1);
});

test('empty color removes manual color; clearManualColors removes all', () => {
  const c = setup();
  pick(c, ['A_x', 'B_x']); c.f.colorPicked(RED, 'Red');
  pick(c, ['A_x']);        c.f.colorPicked('', '');
  assert.equal(colorOf(c, 'A_x'), null);
  assert.equal(colorOf(c, 'B_x'), RED);
  c.f.clearManualColors();
  assert.equal(c.root.cat, null);
  assert.equal(c.root.manualCount, 0);
});

test('manual colors layer on top of regex categories without disturbing the others', () => {
  const c = setup(SMALL, { colorEnabled: true, colorPattern: '_([xyzw])$' });
  c.f.recomputeCategories(false);
  assert.deepEqual(c.root.cat.labels, ['w', 'x', 'y', 'z']);
  const basecolor = (nm) => colorOf(c, nm);
  const yBefore = basecolor('C_y'), zBefore = basecolor('E_z');
  pick(c, ['A_x', 'H_w']); c.f.colorPicked(RED, 'Red');
  assert.equal(colorOf(c, 'A_x'), RED);                           // overridden
  assert.equal(colorOf(c, 'H_w'), RED);
  assert.equal(colorOf(c, 'B_x'), basecolor('B_x'));             // untouched: still the "x" color
  assert.equal(colorOf(c, 'C_y'), yBefore);
  assert.equal(colorOf(c, 'E_z'), zBefore);
  const sum = c.root.cat.counts.reduce((a, b) => a + b, 0);
  assert.equal(sum, 8);                                            // every tip counted exactly once
  assert.ok(!c.root.cat.labels.includes('w'));                     // "w" lost its only tip -> dropped
  c.f.clearManualColors();
  assert.deepEqual(c.root.cat.labels, ['w', 'x', 'y', 'z']);       // regex coloring restored
});

test('manual colors are keyed by tip name, so they survive a change of tree layout', () => {
  const c = setup();
  pick(c, ['A_x', 'B_x']); c.f.colorPicked(RED, 'Red');
  const groups = c.root.manualGroups;
  // same tips, different order (as after a reroot): node indices change, names do not
  const re = setup('(H_w:0.9,(B_x:0.2,A_x:0.1)95:0.3,((E_z:0.4,F_z:0.2,G_z:0.1)99:0.1,(C_y:0.1,D_y:0.1)80:0.2)88:0.2);', { manualGroups: groups });
  re.f.recomputeCategories(false);
  assert.equal(colorOf(re, 'A_x'), RED);
  assert.equal(colorOf(re, 'B_x'), RED);
  assert.equal(colorOf(re, 'H_w'), null);
  assert.equal(re.root.manualCount, 2);
});

test('opening an unrelated tree drops stale manual groups', () => {
  const c = setup();
  pick(c, ['A_x']); c.f.colorPicked(RED, 'Red');
  const other = setup('((P:1,Q:1):1,(R:1,S:1):1);', { manualGroups: c.root.manualGroups });
  other.f.recomputeCategories(false);
  assert.equal(other.root.manualGroups.length, 0);
  assert.equal(other.root.cat, null);
});

test('manual colors and their legend appear in SVG export', () => {
  const c = setup();
  pick(c, ['A_x', 'B_x']); c.f.colorPicked(RED, 'Red');
  const svg = c.f.buildSvg();
  assert.ok(svg.includes(RED), 'color missing from SVG');
  assert.ok(svg.includes('Red'), 'legend label missing from SVG');
  const plain = setup().f.buildSvg();
  assert.ok(!plain.includes(RED));
});

test('coloring 5,000 picked tips of a 20,000-tip tree is fast', () => {
  const nw = '(' + Array.from({ length: 20000 }, (_, i) => 't' + i + ':1').join(',') + ');';
  const c = setup(nw);
  c.f.clearPicked(); c.f.ensurePicked();
  for (let k = 0; k < 5000; k++) { c.root.pickedFlags[c.pT.tipList[k]] = 1; c.root.pickedCount++; }
  const t0 = Date.now();
  c.f.colorPicked(RED, 'Red');
  assert.ok(Date.now() - t0 < 1500, 'took ' + (Date.now() - t0) + ' ms');
  assert.equal(c.root.manualCount, 5000);
});

// ---------------------------------------------------------------- label fill bands
const { checkWellFormed } = require('./harness');
const count = (s, re) => (s.match(re) || []).length;

test('textOn picks readable text for light and dark fills', () => {
  const c = setup();
  assert.equal(c.f.textOn('#f59f00'), '#1c2128');   // amber: dark text
  assert.equal(c.f.textOn('#8b96a3'), '#1c2128');   // light grey: dark text
  assert.equal(c.f.textOn('#2f6fed'), '#ffffff');   // blue: white text
  assert.equal(c.f.textOn('#1c2128'), '#ffffff');   // black: white text
  assert.equal(c.f.textOn('not a color'), '#1c2128');
});

test('fill coloring marks only the label bands: branches and dots stay uncolored', () => {
  const c = setup();
  pick(c, ['A_x', 'B_x', 'H_w']);
  c.f.colorPicked(RED, 'Red', true);
  const cat = c.root.cat;
  for (const nm of ['A_x', 'B_x', 'H_w']) {
    const i = c.pT.names.indexOf(nm);
    assert.ok(cat.fillCat[i] >= 0, nm + ' should have a band');
    assert.equal(cat.nodeCat[i], -1);                       // no text/branch color
    assert.equal(cat.colors[cat.fillCat[i]], RED);
  }
  assert.equal(cat.fillCat[c.pT.names.indexOf('C_y')], -1);
  assert.deepEqual(cat.labels, ['Red (fill)']);
  assert.deepEqual(cat.counts, [3]);
  assert.equal(c.root.manualCount, 3);
});

test('text color and fill can be used together, and recoloring switches a tip between them', () => {
  const c = setup();
  pick(c, ['A_x', 'B_x']);  c.f.colorPicked(RED, 'Red', true);
  pick(c, ['C_y', 'D_y']);  c.f.colorPicked(RED, 'Red', false);
  assert.deepEqual(c.root.cat.labels.sort(), ['Red', 'Red (fill)']);   // same color, two different modes
  pick(c, ['A_x']);         c.f.colorPicked(BLUE, 'Blue', false);       // fill -> text color
  const iA = c.pT.names.indexOf('A_x');
  assert.equal(c.root.cat.fillCat[iA], -1);
  assert.equal(colorOf(c, 'A_x'), BLUE);
  const sum = c.root.cat.counts.reduce((a, b) => a + b, 0);
  assert.equal(sum, 4);                                                 // A, B, C, D colored, each counted once
});

test('fill bands appear in the SVG, one per tip, with readable label text, in every layout', () => {
  for (const kind of ['rectangular', 'slanted', 'circular', 'radial']) {
    for (const align of [false, true]) {
      const c = setup(SMALL, { layoutType: kind, alignTips: align });
      pick(c, ['A_x', 'B_x', 'H_w']);
      c.f.colorPicked(BLUE, 'Blue', true);
      const svg = c.f.buildSvg();
      assert.ok(checkWellFormed(svg));
      const bands = [...svg.matchAll(new RegExp('<rect[^>]*width="([0-9.]+)"[^>]*fill="' + BLUE + '"', 'g'))].filter((m) => +m[1] > 20);
      assert.equal(bands.length, 3, `${kind} align=${align}: bands`);       // (the small legend swatch is excluded)
      assert.ok(count(svg, /<text[^>]*fill="#ffffff"[^>]*>[^<]*(A_x|B_x|H_w)</g) >= 3, `${kind}: white text on blue`);
      assert.ok(!new RegExp('<text[^>]*fill="' + BLUE + '"').test(svg), 'text must not be blue when filled');
    }
  }
});

test('bands are tall enough to touch their neighbours (no gaps between adjacent rows)', () => {
  const c = setup(SMALL, { fontSize: 12 });
  pick(c, ['A_x', 'B_x']); c.f.colorPicked(RED, 'Red', true);
  const svg = c.f.buildSvg();
  const hs = [...svg.matchAll(new RegExp('<rect[^>]*width="([0-9.]+)"[^>]*height="([0-9.]+)"[^>]*fill="' + RED + '"', 'g'))].filter((m) => +m[1] > 20).map((m) => +m[2]);
  assert.equal(hs.length, 2);
  for (const h of hs) assert.ok(h >= 12 * 1.4, 'band height ' + h);
});

test('a fill-colored tip does not color its parent branch even when its sibling is also filled', () => {
  const c = setup();
  pick(c, ['A_x', 'B_x']); c.f.colorPicked(RED, 'Red', true);
  const ab = c.pT.par[c.pT.names.indexOf('A_x')];
  assert.equal(c.root.cat.nodeCat[ab], -1);
});

test('fill groups are kept by name across a reroot-like reordering and cleared for an unrelated tree', () => {
  const c = setup();
  pick(c, ['A_x', 'B_x']); c.f.colorPicked(RED, 'Red', true);
  const re = setup('(H_w:0.9,(B_x:0.2,A_x:0.1)95:0.3,((E_z:0.4,F_z:0.2,G_z:0.1)99:0.1,(C_y:0.1,D_y:0.1)80:0.2)88:0.2);', { manualGroups: c.root.manualGroups });
  re.f.recomputeCategories(false);
  for (const nm of ['A_x', 'B_x']) assert.ok(re.root.cat.fillCat[re.pT.names.indexOf(nm)] >= 0);
  assert.equal(re.root.cat.fillCat[re.pT.names.indexOf('H_w')], -1);
});