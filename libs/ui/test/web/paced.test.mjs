// A frame asked for what moves on by the clock at a pace (@hostapi.frames_paced, ui's app.mbt: a motion seen to need
// fewer frames than the display's) is drawn by the browser's host on its next animation frame. It holds web/host.js
// alone, run in Node with as little of a page as it reads. (The host had no framesPaced till 2026-11-17: the app's
// call reached nothing, and what moved by the clock alone, a hold's fill, a spinner, stood still between inputs.)
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

test('a frame asked for at a pace is drawn on the next animation frame', async () => {
  const element = () => ({ style: {}, addEventListener() {} });
  const gl = new Proxy({}, { get: (_, name) =>
    name === 'getShaderParameter' || name === 'getProgramParameter' ? () => true : () => ({}) });
  const canvas = { ...element(), width: 0, height: 0, getContext: () => gl,
    getBoundingClientRect: () => ({ width: 800, height: 600, left: 0, top: 0 }) };
  const document = { createElement: () => ({ ...element(), getContext: () => ({}) }),
    getElementById: (id) => id === 'c' ? canvas : element(), addEventListener() {} };
  const frames = [], timers = [];
  let now = 0;
  const win = { ...element(), document, navigator: { platform: 'MacIntel' }, location: { search: '' }, URLSearchParams,
    Intl, queueMicrotask, devicePixelRatio: 1, performance: { now: () => now },
    setTimeout(f, ms) { timers.push([f, ms]); return timers.length; },
    requestAnimationFrame(f) { frames.push(f); return frames.length; } };
  win.window = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  const H = win.__mbhost;
  H.run('test', () => {}, () => {}, () => {}, () => {}, () => {});
  await new Promise((resolve) => setTimeout(resolve, 0));
  // the first frame, asked for as the host came to know what it decodes, drawn
  for (const f of frames.splice(0)) f(0);
  assert.equal(typeof H.framesPaced, 'function', 'the host answers frames_paced');
  H.framesPaced(60);
  assert.equal(frames.length, 1, 'high-rate pace draws on the next animation frame');
  for (const f of frames.splice(0)) f(16.67);
  H.framesPaced(20);
  assert.equal(frames.length, 0, 'low-rate pace waits via wakeAfter instead of immediate rAF');
  assert.equal(timers.length, 1, 'timer scheduled for low-rate pace');
});
