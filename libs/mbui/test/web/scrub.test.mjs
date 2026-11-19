// Scrubbing (op 9), approximate seeks (op 11, fastSeek + coalescing while seeking) and exact seeks (op 3, preempting
// pending scrub seeks) on the web host (web/host.js H.viewControl).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

function browser(withFastSeek = true) {
  const element = (tag) => ({
    tag, style: {}, listeners: new Map(), children: [],
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    emit(name) { for (const f of this.listeners.get(name) || []) f(); },
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
      if (tag === 'video') {
        let time = 0;
        e.volume = 1;
        e.paused = true;
        e.ended = false;
        e.readyState = 4;
        e.seeking = false;
        e.buffered = { length: 0 };
        e.exactSeeks = 0;
        e.fastSeeks = 0;
        Object.defineProperty(e, 'currentTime', {
          get() { return time; },
          set(t) { time = t; e.seeking = true; e.exactSeeks++; },
        });
        if (withFastSeek) {
          e.fastSeek = (t) => { time = t; e.seeking = true; e.fastSeeks++; };
        }
        e.finishSeek = () => { e.seeking = false; e.emit('seeked'); };
        e.play = () => Promise.resolve();
        e.pause = () => {};
        videos.push(e);
      }
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

test('web host scrub uses fastSeek, coalesces in-flight near seeks, and preempts on exact seek', () => {
  const b = browser(true);
  const id = b.H.viewOpen(1, 'video/mp4');
  const v = b.videos[0];
  b.H.viewControl(id, 9, 1);
  // First near seek runs immediately with fastSeek.
  b.H.viewControl(id, 11, 1000);
  assert.equal(v.fastSeeks, 1);
  assert.equal(v.exactSeeks, 0);
  assert.equal(v.currentTime, 1);
  assert.equal(v.seeking, true);
  // Subsequent near seeks while seeking coalesce to the latest target.
  b.H.viewControl(id, 11, 2000);
  b.H.viewControl(id, 11, 3500);
  assert.equal(v.fastSeeks, 1);
  assert.equal(v.currentTime, 1);
  // When seeked fires, the coalesced target is sought via fastSeek.
  v.finishSeek();
  assert.equal(v.fastSeeks, 2);
  assert.equal(v.currentTime, 3.5);
  assert.equal(v.seeking, true);
  // Queue another near seek, then preempt immediately with exact seek (op 3) and end scrub (op 9 0).
  b.H.viewControl(id, 11, 4200);
  assert.equal(v.fastSeeks, 2);
  b.H.viewControl(id, 3, 4500);
  b.H.viewControl(id, 9, 0);
  assert.equal(v.exactSeeks, 1);
  assert.equal(v.fastSeeks, 2);
  assert.equal(v.currentTime, 4.5);
  // Finishing the exact seek does not replay the preempted near seek.
  v.finishSeek();
  assert.equal(v.currentTime, 4.5);
  assert.equal(v.fastSeeks, 2);
});

test('web host near seek falls back to currentTime when fastSeek is unavailable', () => {
  const b = browser(false);
  const id = b.H.viewOpen(1, 'video/mp4');
  const v = b.videos[0];
  b.H.viewControl(id, 9, 1);
  b.H.viewControl(id, 11, 1500);
  assert.equal(v.exactSeeks, 1);
  assert.equal(v.currentTime, 1.5);
  b.H.viewControl(id, 11, 2500);
  assert.equal(v.exactSeeks, 1, 'still coalesced while seeking');
  v.finishSeek();
  assert.equal(v.exactSeeks, 2);
  assert.equal(v.currentTime, 2.5);
});
