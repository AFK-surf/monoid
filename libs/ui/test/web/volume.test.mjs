// How loud a player is (NativeView::volume, view_control's 10) on the web is its <video>'s volume, held to 0..1
// (web/host.js H.viewControl). It holds web/host.js alone, run in Node with as little of a page as it reads: not
// what a real browser plays, nor the app's slider.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

function browser() {
  const element = (tag) => ({
    tag, style: {}, listeners: new Map(), children: [],
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    appendChild(e) { this.children.push(e); }, insertBefore(e) { this.children.unshift(e); }, remove() {},
    getContext: () => ({}),
  });
  const gl = new Proxy({}, { get: (_, name) =>
    name === 'getShaderParameter' || name === 'getProgramParameter' ? () => true : () => ({}) });
  const canvas = { ...element('canvas'), width: 0, height: 0, getContext: () => gl,
    getBoundingClientRect: () => ({ width: 800, height: 600, left: 0, top: 0 }) };
  const ime = element('textarea');
  const videos = [];
  const document = { body: element('body'), getElementById: (id) => id === 'c' ? canvas : ime, addEventListener() {},
    createElement(tag) {
      const e = element(tag);
      if (tag === 'video') { e.volume = 1; e.play = () => Promise.resolve(); e.pause = () => {}; videos.push(e); }
      return e;
    } };
  const win = { ...element('window'), document, navigator: { platform: 'MacIntel' }, location: { search: '' },
    URLSearchParams, Intl, queueMicrotask, devicePixelRatio: 1, performance: { now: () => 0 }, Blob, URL,
    requestAnimationFrame() {} };
  win.window = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  const H = win.__mbhost;
  H.run('test', () => {}, () => {}, () => {}, () => {}, () => {});
  return { H, videos };
}

test('a player is as loud as it is told, held to 0..1', () => {
  const b = browser();
  const id = b.H.viewOpen(1, 'video/mp4');
  assert.ok(id > 0, 'a player opened');
  assert.equal(b.videos.length, 1);
  const video = b.videos[0];
  b.H.viewControl(id, 10, 0.25);
  assert.equal(video.volume, 0.25);
  b.H.viewControl(id, 10, 0);
  assert.equal(video.volume, 0, 'muted');
  b.H.viewControl(id, 10, 7);
  assert.equal(video.volume, 1, 'never past its loudest');
  b.H.viewControl(id, 10, -1);
  assert.equal(video.volume, 0, 'never under silence');
});
