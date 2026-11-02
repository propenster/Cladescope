'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { parseNewick, toPT, run, checkWellFormed } = require('./harness');

const SMALL = '((A_x:0.1,B_x:0.2)95:0.3,((C_y:0.1,D_y:0.1)80:0.2,(E_z:0.4,F_z:0.2,G_z:0.1)99:0.1)88:0.2,H_w:0.9);';
const KINDS = ['rectangular', 'slanted', 'circular', 'radial'];
const tree = (nw) => toPT(parseNewick(nw));

function yule(n, seed) {          // deterministic random binary tree, built without recursion
  let s = seed >>> 0; const rnd = () => (s = (s * 1664525 + 1013904223) >>> 0) / 4294967296;
  const L = [-1], R = [-1], len = [0], tips = [0];
  for (let k = 1; k < n; k++) {
    const t = Math.floor(rnd() * tips.length), v = tips[t], a = L.length, b = a + 1;
    L.push(-1, -1); R.push(-1, -1); len.push(rnd() * 0.1 + 0.001, rnd() * 0.1 + 0.001);
    L[v] = a; R[v] = b; tips[t] = a; tips.push(b);
  }
  const out = [], st = [[0, 0]], id = { n: 0 };
  while (st.length) {
    const [v, ph] = st.pop();
    if (L[v] < 0) out.push('t' + (id.n++) + ':' + len[v].toFixed(5));
    else if (ph === 0) { out.push('('); st.push([v, 1]); st.push([L[v], 0]); }
    else if (ph === 1) { out.push(','); st.push([v, 2]); st.push([R[v], 0]); }
    else out.push(')' + (v ? ':' + len[v].toFixed(5) : ''));
  }
  return out.join('') + ';';
}

for (const kind of KINDS) {
  test(`layout and SVG are sane: ${kind}`, () => {
    const pT = tree(SMALL);
    const { svg, root } = run(pT, { layoutType: kind, showSupport: true, showLengths: true, showNodeDots: true });
    assert.equal(root.leafCount, 8);
    for (const a of ['U', 'V', 'ANG', 'RAD']) assert.ok(Array.from(root.pL[a]).every(Number.isFinite), `${a} finite`);
    assert.ok(checkWellFormed(svg));
    assert.doesNotMatch(svg, /NaN|undefined|Infinity|null/);
    assert.equal((svg.match(/<text /g) || []).length >= 8, true, 'one text per tip at least');
  });
}

test('SVG output is deterministic', () => {
  const pT = tree(SMALL);
  assert.equal(run(pT, {}).svg, run(pT, {}).svg);
});

test('tip names are XML-escaped', () => {
  const pT = tree("('A&B <x> \"q\"':1,C:1,D:1);");
  const { svg } = run(pT, {});
  assert.ok(checkWellFormed(svg));
  assert.match(svg, /A&amp;B &lt;x&gt; &quot;q&quot;/);
});

test('trees without branch lengths draw as cladograms', () => {
  const { svg, root } = run(tree('((a,b),(c,d),e);'), { layoutType: 'rectangular' });
  assert.equal(root.pL.useLen, false);
  assert.ok(checkWellFormed(svg));
});

test('star tree (single polytomy) works in every layout', () => {
  for (const kind of KINDS) {
    const { svg } = run(tree('(a:1,b:1,c:1,d:1,e:1,f:1);'), { layoutType: kind });
    assert.ok(checkWellFormed(svg));
  }
});

test('collapsed clade is drawn as one labelled triangle', () => {
  const pT = tree(SMALL);
  const idx = pT.names.indexOf('E_z'), clade = pT.par[idx];
  const { svg, root } = run(pT, { collapsed: { [clade]: true } });
  assert.ok(root.nodeCount < pT.n);
  assert.match(svg, /\(3 tips\)/);
});

test('highlights appear in the export, in every layout', () => {
  const pT = tree(SMALL);
  for (const kind of KINDS) {
    const { svg } = run(pT, { layoutType: kind, highlights: { 1: '#fde68a' } });
    assert.match(svg, /fill="#fde68a"/, kind);
    assert.ok(checkWellFormed(svg));
  }
});

test('search matches only appear when selection is requested', () => {
  const pT = tree(SMALL);
  const flags = Uint8Array.from(pT.names.map(n => (n === 'C_y' ? 1 : 0)));
  const over = { matchFlags: flags, matchList: [pT.names.indexOf('C_y')] };
  assert.doesNotMatch(run(pT, over, { selection: false }).svg, /#ffd54a/);
  assert.match(run(pT, over, { selection: true }).svg, /#ffd54a/);
});

// ---------------------------------------------------------------- axis break
const OUTLIER = '(outlier:5.9,(' + yule(200, 7).replace(/;$/, '') + '):1860);';

test('a branch longer than half the depth is compressed and marked', () => {
  const pT = tree(OUTLIER);
  const on = run(pT, { breakLongBranches: true });
  assert.equal(on.root.breakCount, 1);
  assert.ok(on.root.pL.maxDepth < 100, 'depth no longer dominated by the long branch: ' + on.root.pL.maxDepth);
  assert.match(on.svg, /stroke="#ffffff" stroke-width/, 'break mark drawn');
  const off = run(pT, { breakLongBranches: false });
  assert.equal(off.root.breakCount, 0);
  assert.equal(off.root.breakCandidates, 1);
  assert.ok(off.root.pL.maxDepth > 1800);
});

test('balanced trees are never compressed', () => {
  const r = run(tree(yule(300, 3)), {});
  assert.equal(r.root.breakCount, 0);
  assert.equal(r.root.breakCandidates, 0);
});

test('compression keeps every other branch proportional', () => {
  const pT = tree(OUTLIER);
  const on = run(pT, { breakLongBranches: true }).root.pL;
  // depth difference between two tips inside the main clade equals the raw difference
  const tips = pT.tipList.filter(t => pT.names[t] !== 'outlier');
  const [a, b] = [tips[0], tips[tips.length - 1]];
  let da = 0, db = 0; // raw depth below the long branch
  for (let v = a; v > 1; v = pT.par[v]) da += pT.len[v];
  for (let v = b; v > 1; v = pT.par[v]) db += pT.len[v];
  const comp = (v) => on.U[v] * on.maxDepth;
  assert.ok(Math.abs((comp(a) - comp(b)) - (da - db)) < 1e-6);
});

// ---------------------------------------------------------------- scale
test('deep ladder tree (20,000 levels) does not overflow the stack', () => {
  let s = 'l0:1'; const parts = [];
  for (let i = 1; i < 20000; i++) parts.push(i);
  let nw = 'x0:1'; // build iteratively: ((((x0,x1),x2),x3)...)
  const open = '('.repeat(19999), tail = [];
  for (let i = 1; i < 20000; i++) tail.push(',x' + i + ':1)');
  nw = open + 'x0:1' + tail.join('') + ';';
  const pT = tree(nw);
  const { svg, root } = run(pT, {});
  assert.equal(root.leafCount, 20000);
  assert.ok(svg.length > 1000);
});

test('30,000-tip tree exports quickly in every layout', () => {
  const pT = tree(yule(30000, 11));
  for (const kind of ['rectangular', 'circular', 'radial']) {
    const t0 = Date.now();
    const { svg } = run(pT, { layoutType: kind });
    const ms = Date.now() - t0;
    assert.ok(svg.length > 100000);
    assert.ok(ms < 8000, `${kind} took ${ms} ms`);
  }
});
