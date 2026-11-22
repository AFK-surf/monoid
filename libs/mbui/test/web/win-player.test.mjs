// The Windows player's page (src/host/win_views.cpp kPlayerPage, in WebView2) run on a fake browser: its frames' times
// read from an MP4's sample table by ranges of /media answered in pieces (as the app answers them), in the <video>'s
// time (an edit list's, B-frames' shown out of their order), and a finger's seeks one at a time.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const cpp = readFileSync(new URL('../../src/host/win_views.cpp', import.meta.url), 'utf8');
const lit = cpp.slice(cpp.indexOf('kPlayerPage[] ='), cpp.indexOf(';', cpp.indexOf(')JS";')));
const pageHtml = [...lit.matchAll(/R"JS\(([\s\S]*?)\)JS"/g)].map((m) => m[1]).join('');
const scripts = [...pageHtml.matchAll(/<script>([\s\S]*?)(?=<\/script>|$)/g)].map((m) => m[1]);

function page(file) {
  const bytes = file ? readFileSync(new URL(`../host/${file}`, import.meta.url)) : new Uint8Array(0);
  const said = [];
  const element = () => ({
    style: {}, listeners: new Map(),
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    emit(name) { for (const f of this.listeners.get(name) || []) f(); },
    removeAttribute() {}, load() {}, getContext: () => ({ setTransform() {}, drawImage() {} }),
  });
  const v = element();
  let time = 0;
  Object.assign(v, { paused: true, ended: false, readyState: 4, seeking: false, buffered: { length: 0 }, duration: 2,
    playbackRate: 1, videoWidth: 64, videoHeight: 36, error: null, seeks: 0, play: () => Promise.resolve(), pause() {} });
  Object.defineProperty(v, 'currentTime', { get: () => time, set(t) { time = t; v.seeking = true; v.seeks++; } });
  v.finishSeek = () => { v.seeking = false; v.emit('seeked'); };
  const k = element();
  // /media by ranges, at most 1 KB an answer (fewer than asked, as the app may give)
  const fetch = async (url, o) => {
    const m = /bytes=(\d+)-(\d*)/.exec(o.headers.Range);
    const a = +m[1], e = Math.min(m[2] ? +m[2] + 1 : bytes.length, bytes.length, a + 1024);
    if (a >= bytes.length) return { status: 416, headers: { get: () => `bytes */${bytes.length}` }, arrayBuffer: async () => new ArrayBuffer(0) };
    const body = bytes.subarray(a, e);
    return { status: 206, headers: { get: (h) => (h === 'Content-Range' ? `bytes ${a}-${e - 1}/${bytes.length}` : null) },
      arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.length) };
  };
  const win = { document: { getElementById: (id) => (id === 'v' ? v : k), createElement: element }, fetch,
    chrome: { webview: { postMessage: (m) => said.push(JSON.parse(m)) } }, innerWidth: 64, innerHeight: 36,
    devicePixelRatio: 1, requestAnimationFrame() {}, isFinite, Math, JSON, Promise, Map, Uint8Array, DataView,
    String, Number, Array, Infinity };
  win.window = win;
  const ctx = vm.createContext(win);
  for (const s of scripts) vm.runInContext(s, ctx);
  return { P: win.mbuiPlayer, v, said };
}

const framesOf = async (file) => {
  const { P, said } = page(file);
  P.frames();
  for (let i = 0; i < 1000 && !said.some((m) => m.t === 'f'); i++) await new Promise((ok) => setImmediate(ok));
  const f = said.find((m) => m.t === 'f');
  assert.ok(f, 'its frames said');
  return f.f ? f.f.split(',').map(Number) : [];
};
const tenths = (n) => Array.from({ length: n }, (_, i) => i * 100);
const near = (got, want) => {
  assert.equal(got.length, want.length);
  got.forEach((x, i) => assert.ok(Math.abs(x - want[i]) < 0.01, `frame ${i}: ${x}, not ${want[i]}`));
};

test('an MP4\'s frames\' times, its index first', async () => near(await framesOf('playcheck.mp4'), tenths(10)));

test('an AV1 MP4\'s frames\' times', async () => near(await framesOf('playcheck-av1.mp4'), tenths(50)));

test('B-frames shown out of their order, its edit list taking its first shown frame to 0, its index at its end', async () =>
  near(await framesOf('playcheck-bframes.mp4'), tenths(20)));

test('a file of another kind: no frames, said so', async () => assert.deepEqual(await framesOf('playcheck.webm'), []));

test('a finger\'s seeks, exact or near, wait for the one going: the last asked taken up once it is there', () => {
  const { P, v } = page('');
  P.scrub(true);
  P.seek(1000, false);
  assert.equal(v.currentTime, 1);
  P.seek(1500, false);
  P.seek(2000, true);
  P.seek(1200, false);
  assert.equal(v.seeks, 1, 'none while the first goes');
  v.finishSeek();
  assert.equal(v.seeks, 2);
  assert.equal(v.currentTime, 1.2);
  // let go while one goes: the last asked once it is there, and nothing after
  P.seek(900, false);
  P.scrub(false);
  assert.equal(v.seeks, 2);
  v.finishSeek();
  assert.equal(v.currentTime, 0.9);
  v.finishSeek();
  assert.equal(v.seeks, 3);
  // no finger on it: at once
  P.seek(500, false);
  assert.equal(v.seeks, 4);
  assert.equal(v.currentTime, 0.5);
});
