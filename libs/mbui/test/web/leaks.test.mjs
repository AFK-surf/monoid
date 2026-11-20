// What web/host.js holds is bounded and let go of: its log the last lines of it where no test drives the page (all of
// it where one does, which reads it by its lines' places); the widths it measured at most so many, past it measured
// again; the glyphs' keys forgotten between frames as the faces change or past so many of them, never in a frame;
// glass's textures given back once frames in a row drew none, and as the page is hidden; a video read whole holding
// its bytes in its Blob alone; a clipboard picture's bitmap closed once drawn; and a window beside the page closed
// with every GL object of its context deleted and the context itself lost.
// It holds web/host.js alone, run in Node with as little of a page as it reads (a WebGL 2 context that makes and
// deletes objects and draws nothing): what is let go of, not what is drawn (the hosts' render tests, a real browser's).
//   node --test test/web/leaks.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

// Anything a page's object holds that a test does not look at: a function, its own fields, what it is called for or
// any field of it the same again; no items, the number 0.
function anything() {
  const f = function () {};
  const p = new Proxy(f, {
    get(t, name) {
      if (name === Symbol.iterator) return function* () {};
      if (name === Symbol.toPrimitive) return () => 0;
      if (name === 'then') return undefined;
      if (name in t) return t[name];
      return p;
    },
    set(t, name, v) { t[name] = v; return true; },
    apply: () => p,
    construct: () => p,
  });
  return p;
}

// A WebGL 2 context: every object it makes its own, each deletion of one said (`deleted`), the context lost as told.
function webgl(said) {
  const made = new Set();
  const lose = { loseContext() { said.push('lost'); } };
  let n = 0;
  return new Proxy({}, {
    get(_, name) {
      if (name === 'getShaderParameter' || name === 'getProgramParameter') return () => true;
      if (name === 'getExtension') return (x) => (x === 'WEBGL_lose_context' ? lose : null);
      if (name === 'isContextLost') return () => false;
      if (name === 'getParameter') return () => null;
      if (typeof name === 'string' && name.startsWith('create')) {
        return () => { const o = { kind: name.slice(6), n: ++n }; made.add(o); return o; };
      }
      if (typeof name === 'string' && name.startsWith('delete')) {
        return (o) => { if (o) said.push(['deleted', name.slice(6), made.has(o)]); };
      }
      if (typeof name === 'string' && /^[A-Z0-9_]+$/.test(name)) return 1;
      return () => {};
    },
  });
}

function element(extra = {}) {
  return {
    style: {}, listeners: new Map(), attributes: [],
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    removeEventListener() {},
    dispatch(name, e) { for (const f of this.listeners.get(name) || []) f(e); },
    appendChild() {}, insertBefore() {}, remove() {}, setAttribute() {}, currentTime: 0, paused: true,
    buffered: { length: 0 },
    ...extra,
  };
}

function browser({ webdriver = false } = {}) {
  const said = [];
  const measured = [];
  const blobs = [];
  const bitmaps = [];
  const frames = [];
  const gl = webgl(said);
  const canvasOf = (g) => element({
    width: 0, height: 0, getContext: () => g,
    getBoundingClientRect: () => ({ width: 800, height: 600, left: 0, top: 0 }),
  });
  const canvas = canvasOf(gl);
  const ime = element();
  // a 2d canvas's: what it measures counted, a picture drawn into it made a PNG of a few bytes
  const ctx2d = { measureText: (s) => { measured.push(s); return { width: s.length }; }, drawImage() {},
    getImageData: () => ({ data: new Uint8Array(4) }), clearRect() {}, fillText() {}, fillRect() {} };
  const made = (tag) => (tag === 'canvas'
    ? element({ width: 0, height: 0, getContext: () => ctx2d, toBlob: (f) => f(new Blob([new Uint8Array(8)], { type: 'image/png' })) })
    : element());
  const document = {
    createElement: made, getElementById: (id) => (id === 'c' ? canvas : ime), addEventListener(name, f) {
      if (name === 'visibilitychange') document.seen.push(f);
    },
    seen: [], hidden: false, visibilityState: 'visible', body: element(), title: '', fonts: { add() {}, delete() {} },
  };
  // the popups the page opens: a document of their own, a canvas whose context is another's
  const popups = [];
  const open = () => {
    const pgl = webgl(said);
    const pdoc = { body: element(), head: element(), documentElement: element(), title: '',
      createElement: (tag) => (tag === 'canvas' ? canvasOf(pgl) : element()) };
    const w = element({ document: pdoc, closed: false, devicePixelRatio: 1, innerWidth: 400, innerHeight: 300,
      screenX: 0, screenY: 0, close() { this.closed = true; }, focus() {}, requestAnimationFrame: () => 1,
      cancelAnimationFrame() {}, getComputedStyle: () => ({}) });
    popups.push(w);
    return w;
  };
  const win = {
    ...element(), document, navigator: { platform: 'MacIntel', webdriver,
      clipboard: { read: async () => win.clip } },
    location: { search: '', href: 'http://localhost/' }, URLSearchParams, URL: { createObjectURL: (b) => { blobs.push(b); return 'blob:1'; },
      revokeObjectURL() {} },
    Intl, queueMicrotask, setTimeout, clearTimeout, devicePixelRatio: 1, performance: { now: () => 0 },
    requestAnimationFrame: (f) => { frames.push(f); return frames.length; }, cancelAnimationFrame() {},
    // (the Blob the page makes kept with the parts it was made from)
    Blob: class { constructor(parts, o) { this.parts = parts; this.type = (o && o.type) || ''; this.size = 8; } },
    createImageBitmap: async (b) => {
      const bmp = { width: b.w || 4, height: b.h || 4, closed: false, close() { this.closed = true; } };
      bitmaps.push(bmp);
      return bmp;
    },
    FontFace: class { load() { return Promise.resolve(this); } },
    open, getComputedStyle: () => ({}), console: { log() {}, error() {}, warn() {} },
    Uint8Array, Float32Array, Map, Set, Promise, Math, JSON, Array, Object, Number, String,
  };
  win.window = win;
  win.globalThis = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  const H = win.__mbhost;
  H.run('test', () => {}, () => {}, () => {}, () => {}, () => {});
  H.setOutside(() => {});
  // the frames asked for, run (their RAF callbacks, as a browser runs them)
  const run = () => { while (frames.length) frames.shift()(0); };
  return { H, win, said, measured, blobs, bitmaps, run, popups, document };
}

const task = () => new Promise((resolve) => setTimeout(resolve, 0));

test('the log keeps its last 2000 lines where no test drives the page, all of them where one does', () => {
  const b = browser();
  for (let i = 0; i < 2500; i++) b.H.log('line ' + i);
  assert.equal(b.win.__logs.length, 2000);
  assert.equal(b.win.__logs[0], 'line 500');
  assert.equal(b.win.__logs.at(-1), 'line 2499');
  const d = browser({ webdriver: true });
  for (let i = 0; i < 2500; i++) d.H.log('line ' + i);
  assert.equal(d.win.__logs.length, 2500, 'a test reads every line by its place');
});

test('widths measured are kept, at most 16384 of them, past it measured again', () => {
  const b = browser();
  const out = new Float64Array(16);
  b.H.shape('a', 10, 400, 0, out);
  const once = b.measured.length;
  assert.ok(once > 0);
  b.H.shape('a', 10, 400, 0, out);
  assert.equal(b.measured.length, once, 'kept: not measured again');
  // a width of each of 16384 more fonts: past the most, all forgotten and measured again as they come
  for (let i = 1; i <= 16384; i++) b.H.shape('a', 10 + i / 1024, 400, 0, out);
  const after = b.measured.length;
  b.H.shape('a', 10, 400, 0, out);
  assert.ok(b.measured.length > after, 'forgotten past the most: measured again');
});

test('the glyphs\' keys are forgotten as the next frame starts once the faces change or past 65536', async () => {
  const b = browser();
  await task();
  b.run();
  b.H.textKey('x', 10, 400, 0);
  const k = b.H.textKey('a', 10, 400, 0);
  assert.equal(k, 1);
  const g = b.H.atlasGeneration();
  // a face loaded (outside a frame, or in one: a frame's text may still hold keys made before)
  assert.ok(b.H.faceAddBytes(1, new Uint8Array(0), 0));
  await task();
  assert.ok(b.H.atlasGeneration() > g, 'the generation moved on as the face came');
  assert.equal(b.H.textKey('a', 10, 400, 0), k, 'the keys kept till the next frame starts');
  b.H.requestFrame();
  b.run();
  assert.equal(b.H.textKey('a', 10, 400, 0), 0, 'forgotten as the frame started: made anew');
  // past the most: forgotten as the next frame starts, the generation moved on
  for (let i = 0; b.H.textKey('c', 10 + i / 1024, 400, 0) < 65536; i++);
  const g2 = b.H.atlasGeneration();
  assert.equal(b.H.textKey('a', 10, 400, 0), 0, 'kept in the frame');
  b.H.requestFrame();
  b.run();
  assert.ok(b.H.atlasGeneration() > g2, 'the generation moved on past the most');
  assert.equal(b.H.textKey('a', 10, 400, 0), 0, 'the keys made anew');
  b.H.requestFrame();
  b.run();
  assert.equal(b.H.atlasGeneration(), g2 + 1, 'nothing more forgotten with nothing changed');
});

test('glass\'s textures given back after 180 frames with none, and as the page is hidden', () => {
  const b = browser();
  b.run();
  const INST = 60;
  const frame = (glass) => {
    const buf = new Float64Array(INST * 2);
    buf.set([10, 10, 100, 50], 0);
    buf.set([-1e9, -1e9, 1e9, 1e9], 16);
    buf.set([20, 20, 200, 100], INST);
    buf[INST + 5] = 5;
    buf[INST + 7] = 8;
    buf.set([-1e9, -1e9, 1e9, 1e9], INST + 16);
    buf[INST + 20] = glass ? -1 : 0;
    b.H.present(buf, 2, 0.1, 0.2, 0.3);
  };
  const levels = () => b.said.filter((x) => Array.isArray(x) && x[1] === 'Framebuffer').length;
  frame(true);
  const before = levels();
  for (let i = 1; i < 180; i++) frame(false);
  assert.equal(levels(), before, 'kept through 179 frames with none');
  frame(false);
  assert.equal(levels(), before + 5, 'the five levels given back at the 180th');
  frame(true);
  frame(false);
  // hidden: given back at once
  b.document.hidden = true;
  for (const f of b.document.seen) f();
  assert.equal(levels(), before + 10, 'given back as the page is hidden');
  assert.ok(b.said.filter((x) => Array.isArray(x)).every((x) => x[2]), 'only what the context made deleted');
});

test('a video read whole keeps its bytes in its Blob alone', () => {
  const b = browser();
  const id = b.H.viewOpen(1, 'video/mp4');
  assert.ok(id > 0);
  b.H.viewReadAnswer(id, 1, new Uint8Array([1, 2, 3]).buffer, 3, false);
  assert.equal(b.blobs.length, 1, 'its Blob made');
  assert.equal(b.blobs[0].parts.length, 0, 'the parts let go of once the Blob holds them');
});

test('a clipboard picture\'s bitmap is closed once drawn, and when it is too big', async () => {
  const b = browser();
  const item = (w, h) => ({ types: ['image/jpeg'], getType: async () => ({ type: 'image/jpeg', size: 10, w, h }) });
  b.win.clip = [item(4, 4)];
  b.H.clipRead();
  for (let i = 0; i < 5; i++) await task();
  assert.equal(b.bitmaps.length, 1);
  assert.ok(b.bitmaps[0].closed, 'closed once drawn');
  b.win.clip = [item(8192, 8192)];
  b.H.clipRead();
  for (let i = 0; i < 5; i++) await task();
  assert.equal(b.bitmaps.length, 2);
  assert.ok(b.bitmaps[1].closed, 'closed when too big to draw');
});

test('a window beside the page closed: every GL object of its context deleted, the context lost', async () => {
  const b = browser();
  b.run();
  const wid = b.H.windows(1, 0, '{}');
  assert.ok(wid > 0, 'a window opened');
  b.said.length = 0;
  b.H.windows(3, wid, '');
  await task();
  const deleted = b.said.filter((x) => Array.isArray(x)).map((x) => x[1]);
  for (const k of ['Texture', 'Buffer', 'VertexArray', 'Program']) assert.ok(deleted.includes(k), k + ' deleted');
  assert.ok(b.said.includes('lost'), 'its context lost');
  assert.ok(b.popups[0].closed, 'the popup closed');
});
