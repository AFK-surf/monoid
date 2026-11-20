// Adaptive jitter-absorbing presentation clock and four-state catch-up pacer for Web H.264 streams (web/host.js).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

function pacedBrowser() {
  const element = () => ({
    style: {}, listeners: new Map(),
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    dispatch(name, e = {}) { for (const f of this.listeners.get(name) || []) f(e); },
  });
  const videos = [];
  let nowMs = 0;
  let nextRaf = 1;
  const rafs = new Map();
  let cancelled = 0;
  const gl = new Proxy({}, { get: (_, name) => {
    if (name === 'getShaderParameter' || name === 'getProgramParameter') return () => true;
    if (name === 'getExtension') return () => ({ loseContext() {}, restoreContext() {} });
    if (name === 'isContextLost') return () => false;
    return () => ({});
  } });
  const canvas = { ...element(), width: 0, height: 0, getContext: () => gl,
    getBoundingClientRect: () => ({ width: 200, height: 200, left: 0, top: 0 }) };
  const ime = element();
  const document = { createElement: () => ({ ...element(), getContext: () => ({}) }),
    getElementById: id => id === 'c' ? canvas : ime, addEventListener() {} };
  class VideoDecoder {
    static isConfigSupported() { return Promise.resolve({ supported: true }); }
    constructor({ output }) { this.output = output; }
    configure() {}
    decode(chunk) {
      const f = videos.shift();
      f.timestamp = chunk.timestamp;
      this.output(f);
    }
    close() {}
  }
  class EncodedVideoChunk { constructor(fields) { Object.assign(this, fields); } }
  const requestAnimationFrame = (fn) => {
    const id = nextRaf++;
    rafs.set(id, fn);
    return id;
  };
  const cancelAnimationFrame = (id) => {
    if (rafs.delete(id)) cancelled++;
  };
  const win = {
    ...element(), document, navigator: { platform: 'MacIntel' }, location: { search: '' }, URLSearchParams,
    Intl, Blob, VideoDecoder, EncodedVideoChunk, createImageBitmap: async () => null,
    devicePixelRatio: 1, performance: { now: () => nowMs },
    requestAnimationFrame, cancelAnimationFrame,
  };
  win.window = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  const host = win.__mbhost;
  host.run('test', () => {}, () => {}, () => {}, () => {}, () => {});
  const drainEvents = (id) => {
    const out = [];
    for (let e = host.streamNext(id); e; e = host.streamNext(id)) out.push(e);
    return out;
  };
  const runRaf = () => {
    const batch = [...rafs.entries()];
    rafs.clear();
    for (const [, fn] of batch) fn(nowMs);
  };
  return {
    host, videos, drainEvents, runRaf,
    setNow(ms) { nowMs = ms; },
    getNow() { return nowMs; },
    pendingRafs() { return rafs.size; },
    cancelledRafs() { return cancelled; },
  };
}

const mkFrame = (w = 16, h = 16) => ({
  width: w, height: h, displayWidth: w, displayHeight: h, closed: 0,
  close() { this.closed++; },
});
const tick = () => new Promise(resolve => setImmediate(resolve));
const AVCC = [1, 0x64, 0x00, 0x2a];

test('clean link (0ms jitter) emits immediate f TS W H with no waitUs suffix', async () => {
  const b = pacedBrowser();
  await tick();
  const id = b.host.streamOpen();
  b.host.streamH264(id, AVCC, 16, 16);

  for (let i = 0; i < 5; i++) {
    b.setNow(100 + i * 16);
    b.videos.push(mkFrame());
    b.host.streamFrame(id, [1], i === 0, i * 16_000);
    assert.deepEqual(b.drainEvents(id), [`f ${i * 16_000} 16 16`]);
    // Advance display refresh so drawnThisFrame resets for next frame.
    b.runRaf();
  }
  b.host.streamClose(id);
});

test('burst jitter adapts holdMs up to 100ms cap, paces frames with waitUs, and decays when link clears', async () => {
  const b = pacedBrowser();
  await tick();
  const id = b.host.streamOpen();
  b.host.streamH264(id, AVCC, 16, 16);

  // Frame 0 arrives on time at t=100 (ts=0): offset=100, holdMs=0 -> immediate.
  b.setNow(100);
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], true, 0);
  assert.deepEqual(b.drainEvents(id), ['f 0 16 16']);
  b.runRaf();

  // Burst of two 60ms-late frames (recent=[0, 60, 60], p95 index floor(0.95*2)=1 -> holdMs jumps to 60).
  b.setNow(176); // ts=16ms -> offset=160, late=60
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 16_000);
  assert.deepEqual(b.drainEvents(id), ['f 16000 16 16']);
  b.runRaf();

  b.setNow(192); // ts=32ms -> offset=160, late=60 -> holdMs=60
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 32_000);
  assert.deepEqual(b.drainEvents(id), ['f 32000 16 16']);
  b.runRaf();

  // Frame 3 (ts=100ms) arrives cleanly at t=200 (offset=100, late=0).
  // holdMs is still ~59.6ms (decayed by (200-192)*0.05 = 0.4), so Frame 3 is due at 200 + 59.6 = 259.6ms.
  b.setNow(200);
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 100_000);
  assert.deepEqual(b.drainEvents(id), [], 'held back by adaptive jitter buffer');

  // Before due time (t=240): still held.
  b.setNow(240);
  b.runRaf();
  assert.deepEqual(b.drainEvents(id), []);

  // At t=260 (>= 259.6): presented with waitUs = (260 - 200) * 1000 = 60000.
  b.setNow(260);
  b.runRaf();
  assert.deepEqual(b.drainEvents(id), ['f 100000 16 16 60000']);
  b.runRaf();

  // Extreme jitter burst (two 250ms-late frames) caps holdMs at MAX_HOLD_MS = 100ms.
  b.setNow(550); // ts=200ms -> offset=350, late=250
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 200_000);
  assert.deepEqual(b.drainEvents(id), ['f 200000 16 16']);
  b.runRaf();

  b.setNow(566); // ts=216ms -> offset=350, late=250 -> p95=250 -> capped at 100ms
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 216_000);
  assert.deepEqual(b.drainEvents(id), ['f 216000 16 16']);
  b.runRaf();

  // Clean frame arrives at t=600 (ts=500ms, offset=100, late=0); due at 600 + 100 = 700 (not 850).
  b.setNow(600);
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 500_000);
  assert.deepEqual(b.drainEvents(id), []);
  b.setNow(700);
  b.runRaf();
  assert.deepEqual(b.drainEvents(id), ['f 500000 16 16 100000']);
  b.runRaf();

  // After > 2000ms of clean frames (JITTER_WINDOW_MS + HOLD_DECAY=0.05 -> 2000ms decays 100ms to 0):
  // Feed clean frames every 200ms from t=1000 to t=5200.
  for (let t = 1000; t <= 5200; t += 200) {
    b.setNow(t);
    b.videos.push(mkFrame());
    b.host.streamFrame(id, [1], false, (t - 100) * 1000);
    b.setNow(t + 100);
    b.runRaf();
    b.drainEvents(id);
    b.runRaf();
  }
  // Now holdMs has decayed to 0: next clean frame emits immediately with no waitUs!
  b.setNow(5400);
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 5_300_000);
  assert.deepEqual(b.drainEvents(id), ['f 5300000 16 16']);
  b.host.streamClose(id);
});

test('clock jump > 500ms resets clock and holdMs', async () => {
  const b = pacedBrowser();
  await tick();
  const id = b.host.streamOpen();
  b.host.streamH264(id, AVCC, 16, 16);

  // Establish offset=100 and build holdMs=80.
  b.setNow(100);
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], true, 0);
  b.drainEvents(id);
  b.runRaf();

  b.setNow(196); // ts=16ms -> offset=180, late=80
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 16_000);
  b.drainEvents(id);
  b.runRaf();

  b.setNow(212); // ts=32ms -> offset=180, late=80 -> holdMs=80
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 32_000);
  b.drainEvents(id);
  b.runRaf();

  // Clock jump: offset jumps by > 500ms (e.g. idle desktop or outage: t=1200, ts=100ms -> offset=1100, diff=920 > 500).
  b.setNow(1200);
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 100_000);
  assert.deepEqual(b.drainEvents(id), ['f 100000 16 16']);
  b.runRaf();

  // Next frame on the new clock (offset=1100, late=0) emits immediately because holdMs was reset to 0.
  b.setNow(1216);
  b.videos.push(mkFrame());
  b.host.streamFrame(id, [1], false, 116_000);
  assert.deepEqual(b.drainEvents(id), ['f 116000 16 16']);
  b.host.streamClose(id);
});

test('four-state catch-up presenter: idle -> backlog -> catchUp (drop 1 / 250ms) -> overrun (drop to 2), closing dropped frames', async () => {
  const b = pacedBrowser();
  await tick();
  const id = b.host.streamOpen();
  b.host.streamH264(id, AVCC, 16, 16);

  // Frame 0 draws immediately, setting drawnThisFrame=true so subsequent burst frames queue in s.paced.
  b.setNow(100);
  const f0 = mkFrame();
  b.videos.push(f0);
  b.host.streamFrame(id, [1], true, 0);
  assert.deepEqual(b.drainEvents(id), ['f 0 16 16']);

  // Burst 4 due frames while drawnThisFrame=true -> due=4, enters 'backlog' (< 500ms), nothing dropped yet.
  const q1 = [];
  for (let i = 1; i <= 4; i++) {
    const f = mkFrame();
    q1.push(f);
    b.videos.push(f);
    b.host.streamFrame(id, [1], false, i * 16_000);
  }
  // At t=100, due=4, backlogSince=100, backlogMs=0 < 500 -> 'backlog' (no drops).
  assert.deepEqual(b.drainEvents(id), []);
  for (const f of q1) assert.equal(f.closed, 0);

  // Wait 210ms (> 200ms headOverstayMs): triggers 'overrun' on next rAF, dropping down to 2 due frames then drawing 1.
  b.setNow(310);
  b.runRaf();
  const ev = b.drainEvents(id);
  // 4 due -> overrun drops 2 (ts=16000, ts=32000), leaving 2 (ts=48000, ts=64000), then draws ts=48000.
  assert.deepEqual(ev, [
    'd 16000 210000',
    'd 32000 210000',
    'f 48000 16 16 210000',
  ]);
  assert.equal(q1[0].closed, 1, 'dropped frame 1 closed');
  assert.equal(q1[1].closed, 1, 'dropped frame 2 closed');
  assert.equal(q1[2].closed, 0, 'shown frame 3 kept until replaced/closed');
  assert.equal(q1[3].closed, 0, 'remaining queued frame 4 still open');

  // Drain frame 4 on next rAF.
  b.setNow(326);
  b.runRaf();
  assert.deepEqual(b.drainEvents(id), ['f 64000 16 16 226000']);
  b.runRaf();

  // Now test gradual catchUp (due=4, backlogMs >= 500, headOverstayMs <= 200):
  // Feed a stream at 60fps where backlog persists >= 500ms while head stays < 200ms old.
  // Start fresh stream to keep timestamps clean.
  b.host.streamClose(id);
  const id2 = b.host.streamOpen();
  b.host.streamH264(id2, AVCC, 16, 16);

  // Frame 0 at t=1000 (ts=0) -> immediate.
  b.setNow(1000);
  b.videos.push(mkFrame());
  b.host.streamFrame(id2, [1], true, 0);
  b.drainEvents(id2);

  // Queue 4 frames at t=1000 (due=4 -> backlogSince=1000).
  const droppedCatchUp = [];
  for (let i = 1; i <= 4; i++) {
    const f = mkFrame();
    droppedCatchUp.push(f);
    b.videos.push(f);
    b.host.streamFrame(id2, [1], false, i * 1000);
  }
  assert.deepEqual(b.drainEvents(id2), []);

  // Keep queue at due=4 across 35 refreshes (16ms each = 560ms > 500ms) so headOverstayMs stays ~64ms (< 200ms).
  let nextTs = 5;
  let sawCatchUpDrop = false;
  for (let step = 1; step <= 35; step++) {
    const t = 1000 + step * 16;
    b.setNow(t);
    // Add 1 new frame before present so due stays 4 (draw brings it to 3 -> backlog/catchUp).
    const nf = mkFrame();
    b.videos.push(nf);
    b.host.streamFrame(id2, [1], false, nextTs++ * 1000);
    b.runRaf();
    const events = b.drainEvents(id2);
    const drops = events.filter((e) => e.startsWith('d '));
    if (drops.length > 0) {
      assert.equal(drops.length, 1, 'catchUp drops exactly 1 frame at a time');
      sawCatchUpDrop = true;
      break;
    }
  }
  assert.equal(sawCatchUpDrop, true, 'sustained backlog >= 500ms triggers catchUp drop');
  b.host.streamClose(id2);
});

test('streamH264 rebuild and streamClose cancel pending rAF and release all queued VideoFrames', async () => {
  const b = pacedBrowser();
  await tick();
  const id = b.host.streamOpen();
  b.host.streamH264(id, AVCC, 16, 16);

  // Frame 0 draws immediately; frames 1 and 2 queue in s.paced with a pending rAF.
  b.setNow(100);
  const f0 = mkFrame(), f1 = mkFrame(), f2 = mkFrame();
  b.videos.push(f0, f1, f2);
  b.host.streamFrame(id, [1], true, 0);
  b.host.streamFrame(id, [1], false, 16_000);
  b.host.streamFrame(id, [1], false, 32_000);
  assert.ok(b.pendingRafs() > 0, 'rAF scheduled for queued frames');
  assert.equal(f1.closed, 0);
  assert.equal(f2.closed, 0);

  // Reconfiguring decoder via streamH264 closes all queued paced frames and cancels rAF.
  const cancelledBefore = b.cancelledRafs();
  b.host.streamH264(id, AVCC, 32, 32);
  assert.equal(f1.closed, 1, 'queued frame 1 released on decoder rebuild');
  assert.equal(f2.closed, 1, 'queued frame 2 released on decoder rebuild');
  assert.ok(b.cancelledRafs() > cancelledBefore, 'pending rAF cancelled on decoder rebuild');

  // Queue new frames and close stream: all queued frames released and rAF cancelled.
  const f3 = mkFrame(), f4 = mkFrame();
  b.videos.push(f3, f4);
  b.host.streamFrame(id, [1], true, 100_000);
  b.host.streamFrame(id, [1], false, 116_000);
  const cancelledBeforeClose = b.cancelledRafs();
  b.host.streamClose(id);
  assert.equal(f0.closed, 1);
  assert.equal(f3.closed, 1);
  assert.equal(f4.closed, 1, 'queued frame 4 released on streamClose');
  assert.ok(b.cancelledRafs() > cancelledBeforeClose, 'pending rAF cancelled on streamClose');
});
