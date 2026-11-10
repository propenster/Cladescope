'use strict';
// Branch support values: plain numbers, IQ-TREE style "a/b" labels, and non-support labels.
const test = require('node:test');
const assert = require('node:assert/strict');
const { parseNewick, toPT, run } = require('./harness');

const texts = (svg) => [...svg.matchAll(/<text[^>]*text-anchor="end"[^>]*>([^<]*)<\/text>/g)].map((m) => m[1]);
function make(nw, show = true) {
  const pT = toPT(parseNewick(nw));
  return run(pT, { showSupport: show });
}

test('supportOf accepts numbers and compound labels and rejects names', () => {
  const { f } = make('((A:1,B:1)90:1,C:1);');
  assert.deepEqual(f.supportOf('95'), { value: 95, text: '95' });
  assert.deepEqual(f.supportOf('0.9876'), { value: 0.9876, text: '0.99' });
  assert.deepEqual(f.supportOf('1e-2'), { value: 0.01, text: '0.01' });
  assert.deepEqual(f.supportOf('87.5/99'), { value: 87.5, text: '87.5/99' });
  assert.deepEqual(f.supportOf(' 0.95 / 87 '), { value: 0.95, text: '0.95/87' });
  assert.deepEqual(f.supportOf('100|98|77'), { value: 100, text: '100|98|77' });
  for (const bad of ['', 'Eukaryota', '95abc', 'A/B', '12/', '/12', '1.2.3', 'clade 3']) assert.equal(f.supportOf(bad), null, JSON.stringify(bad));
});

test('plain numeric labels are drawn, rounded to two decimals', () => {
  const t = texts(make('((A:1,B:1)0.987:1,(C:1,D:1)95:1);').svg);
  assert.deepEqual(t.sort(), ['0.99', '95']);
});

test('IQ-TREE style compound labels are drawn exactly as written', () => {
  const t = texts(make('((A:1,B:1)87.5/99:1,(C:1,D:1)100/100:1);').svg);
  assert.deepEqual(t.sort(), ['100/100', '87.5/99']);
});

test('support values are hidden unless requested', () => {
  assert.deepEqual(texts(make('((A:1,B:1)95:1,C:1);', false).svg), []);
});

test('internal names that are not support values are kept and not drawn as support', () => {
  const c = make('((A:1,B:1)Primates:1,(C:1,D:1)88:1);');
  assert.deepEqual(texts(c.svg), ['88']);
  assert.ok(c.root.pT.names.includes('Primates'));
});

test('tip labels that look like numbers are never treated as support', () => {
  const c = make('((1:1,2:1)95:1,(3:1,4:1)90:1);');
  assert.deepEqual(texts(c.svg).sort(), ['90', '95']);
  assert.deepEqual(c.root.pT.tipList.map((i) => c.root.pT.names[i]), ['1', '2', '3', '4']);
});

test('support text is XML-escaped in the SVG', () => {
  const c = make('((A:1,B:1)95:1,C:1);');
  c.root.pT.supText[c.root.pT.supText.indexOf('95')] = '<1&2>';   // hostile label must not break the document
  const svg = c.f.buildSvg();
  assert.ok(svg.includes('&lt;1&amp;2&gt;'));
  assert.ok(!svg.includes('<1&2>'));
});
