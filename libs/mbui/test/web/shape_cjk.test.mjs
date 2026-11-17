// A paragraph of Han with no spaces is measured cluster by cluster (web/host.js H.shape): a Han character after a Han
// character starts a word of its own, where it had been measured as a prefix of the whole run growing to its end at
// each cluster (500 characters, 125,000 measured: a frame of 70-110 ms). What it gives is what the prefixes gave
// wherever no kerning pair joins two Han characters: Latin's pairs, and the pairs of punctuation beside Han, are kept
// in their words. It holds web/host.js alone, run in Node with a canvas whose widths are a model's (each character's
// own, and a few pairs'), not a browser's fonts.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

// The model's widths: a Han character or CJK punctuation 16, an ASCII one 8, a space 4, a zero width non-joiner none
// and joining no pair; and pairs that move what follows them in (Latin's kerning, the spacing a browser trims between
// CJK punctuation, a Han character beside punctuation or Latin).
const PAIRS = { AV: -1, To: -0.75, '，「': -8, '」。': -8, '字，': -0.25, '」字': -0.5, '国A': -0.5, 'A国': -0.25 };
const own = (ch) => (ch === '‌' ? 0 : ch === ' ' ? 4 : ch.codePointAt(0) < 0x80 ? 8 : 16);
function modelWidth(s) {
  const cs = [...s];
  let w = 0;
  for (let i = 0; i < cs.length; i++) {
    w += own(cs[i]);
    if (i > 0) w += PAIRS[cs[i - 1] + cs[i]] || 0;
  }
  return w;
}

function browser() {
  const element = () => ({
    style: {}, listeners: new Map(),
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    dispatch(name, e) { for (const f of this.listeners.get(name) || []) f(e); },
  });
  const measured = { calls: 0, chars: 0 };
  const ctx2d = { font: '', measureText(s) {
    measured.calls++;
    measured.chars += [...s].length;
    return { width: modelWidth(s), actualBoundingBoxAscent: 12, actualBoundingBoxDescent: 4 };
  } };
  const document = { createElement: () => ({ ...element(), getContext: () => ctx2d }),
    getElementById: () => element(), addEventListener() {} };
  const win = { ...element(), document, navigator: { platform: 'MacIntel' }, location: { search: '' }, URLSearchParams,
    Intl, queueMicrotask, devicePixelRatio: 1, performance: { now: () => 0 }, requestAnimationFrame() {} };
  win.window = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  return { H: win.__mbhost, measured };
}

// What the prefixes gave (H.shape before): a word ends only at a blank; a cluster starts where the word up to and with
// it ends, less its own width; it advances to where the next starts, the last of a word to where the word ends.
function prefixAdvances(text) {
  const segs = [...new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)].map((s) => s.segment);
  const blank = (c) => /^\s+$/.test(c);
  const xs = [];
  let word = 0;
  for (let i = 0; i < segs.length; i++) {
    if (blank(segs[i])) { word = i + 1; continue; }
    xs[i] = modelWidth(segs.slice(word, i + 1).join('')) - modelWidth(segs[i]);
  }
  const out = [];
  word = 0;
  for (let i = 0; i < segs.length; i++) {
    const c = segs[i];
    if (blank(c)) { out.push(modelWidth(c)); word = i + 1; continue; }
    const last = i + 1 >= segs.length || blank(segs[i + 1]);
    const end = last ? modelWidth(segs.slice(word, i + 1).join('')) : xs[i + 1];
    out.push(Math.max(0, end - xs[i]));
  }
  return out;
}

function shaped(H, text, style = 0) {
  const out = new Float64Array(4 * (text.length + 1));
  const n = H.shape(text, 16, 400, style, out);
  const advances = [];
  for (let k = 0; k < n; k++) advances.push(out[k * 4 + 2]);
  return advances;
}

const HAN = '天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳云腾致雨露结为霜金生丽水玉出昆冈剑号巨阙珠称夜光';

test('500 Han characters with no space are measured cluster by cluster, not as prefixes', () => {
  const text = Array.from({ length: 500 }, (_, i) => HAN[i % HAN.length]).join('');
  const b = browser();
  const advances = shaped(b.H, text);
  assert.equal(advances.length, 500);
  assert.deepEqual(advances, prefixAdvances(text), 'each advances as the prefixes had it');
  // before: 500 prefixes of up to 500 characters, 125,250 characters measured
  assert.ok(b.measured.calls < 1200, `measureText called ${b.measured.calls} times`);
  assert.ok(b.measured.chars < 3 * 500, `${b.measured.chars} characters measured`);
});

test('Han beside punctuation, Latin and spaces advances as the prefixes had it', () => {
  for (const text of [
    '天地，「玄黄」。宇宙洪荒',
    '我的字，「引号」字和标点',
    '中国AVTo国A国 To AVA 英文Tokyo混排',
    'AVATAR Total 国A V',
    '𠀀𠀁𪚥龘㐀豈 字字',
    '',
    '字',
  ]) {
    const b = browser();
    assert.deepEqual(shaped(b.H, text), prefixAdvances(text), JSON.stringify(text));
  }
});

test('words with no ligatures (letter spacing) are measured the same way', () => {
  const text = '天地玄黄AV宇宙，「洪荒」';
  const b = browser();
  // (a zero width non-joiner between clusters keeps the model's pairs apart, as it keeps the browser's ligatures)
  const advances = shaped(b.H, text, 8);
  const segs = [...text];
  assert.deepEqual(advances, segs.map((c) => own(c)));
});
