// Verifies WebGL2 host performance paths in web/host.js:
// 1. Whole-screen frames draw straight to the default framebuffer (null) with zero blitFramebuffer;
//    partial renderDirty frames build a cv baseline once then scissor-update dirty rects.
// 2. Glass ensureLevels allocates tight capture-box textures (not full screen) and hits glassSlots LRU cache
//    with zero blur passes on unchanged content under the glass.
// 3. ONE_KIND lazy shader compilation, progFlat interior cross for large solid rects, and banded scissor strips
//    for hollow borders and occluded shadows.
// 4. Cached canvas getBoundingClientRect on pointermove + getCoalescedEvents expansion on touch.
// 5. High-refresh H.framesPaced throttling via wakeAfter.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');
const INST = 60;
// slot 23 of bare adaptive text: the whole text's half width and height (ui's bare_text_ink), its centre in 21-22
const bareInk = (hw, hh) => -(Math.floor(hw) * 4096 + Math.floor(hh));

function makeHost({ w = 400, h = 800, dpr = 3, search = '', nav = { platform: 'Linux armv8l', userAgent: 'Android' } } = {}) {
  const calls = [];
  const shaders = new Map();
  const programs = new Map();
  let nextId = 1;
  let boundProg = null;
  let boundFb = null;
  let scissorOn = false;
  let scissorBox = null;
  const timers = [];
  const rafs = [];
  const pointers = [];
  let now = 0;
  let rectCalls = 0;
  let rectLeft = 10, rectTop = 20;

  const GL_CONST = {
    VERTEX_SHADER: 0x8b31,
    FRAGMENT_SHADER: 0x8b30,
    COMPILE_STATUS: 0x8b81,
    LINK_STATUS: 0x8b82,
    TEXTURE_2D: 0x0de1,
    FRAMEBUFFER: 0x8d40,
    READ_FRAMEBUFFER: 0x8ca8,
    DRAW_FRAMEBUFFER: 0x8ca9,
    COLOR_ATTACHMENT0: 0x8ce0,
    COLOR_BUFFER_BIT: 0x4000,
    SCISSOR_TEST: 0x0c11,
    BLEND: 0x0be2,
    RGBA8: 0x8058,
    RGB10_A2: 0x8059,
    RGBA32F: 0x8814,
    NEAREST: 0x2600,
    LINEAR: 0x2601,
    CLAMP_TO_EDGE: 0x812f,
    TRIANGLES: 0x0004,
    ARRAY_BUFFER: 0x8892,
    STREAM_DRAW: 0x88e0,
    FLOAT: 0x1406,
    ONE: 1,
    ONE_MINUS_SRC_ALPHA: 0x0303,
    TEXTURE0: 0x84c0,
    TEXTURE1: 0x84c1,
    TEXTURE2: 0x84c2,
    TEXTURE3: 0x84c3,
    TEXTURE4: 0x84c4,
  };

  const gl = new Proxy(GL_CONST, {
    get(target, name) {
      if (name in target) return target[name];
      if (name === 'createShader') return (type) => {
        const s = { id: nextId++, type, src: '' };
        shaders.set(s, s);
        return s;
      };
      if (name === 'shaderSource') return (s, src) => { s.src = src; };
      if (name === 'compileShader') return () => {};
      if (name === 'getShaderParameter') return () => true;
      if (name === 'createProgram') return () => {
        const p = { id: nextId++, shaders: [] };
        programs.set(p, p);
        return p;
      };
      if (name === 'attachShader') return (p, s) => { p.shaders.push(s); };
      if (name === 'linkProgram') return (p) => {
        const vs = p.shaders.find((s) => s.type === GL_CONST.VERTEX_SHADER);
        const fs = p.shaders.find((s) => s.type === GL_CONST.FRAGMENT_SHADER);
        p.vsSrc = vs ? vs.src : '';
        p.fsSrc = fs ? fs.src : '';
        p.isFlat = p.fsSrc.includes('void main() { o = vec4(v_color.rgb, 1.0) * v_color.a; }');
        const m = p.fsSrc.match(/#define ONE_KIND (-?\d+)/);
        p.oneKind = m ? Number(m[1]) : null;
        p.vsAdaptive = p.vsSrc.includes('#define MB_VS_ADAPTIVE 1');
        calls.push({ fn: 'linkProgram', prog: p });
      };
      if (name === 'getProgramParameter') return () => true;
      if (name === 'useProgram') return (p) => { boundProg = p; calls.push({ fn: 'useProgram', prog: p }); };
      if (name === 'createTexture') return () => ({ id: nextId++, kind: 'tex' });
      if (name === 'createFramebuffer') return () => {
        const fb = { id: nextId++, kind: 'fb' };
        calls.push({ fn: 'createFramebuffer', fb });
        return fb;
      };
      if (name === 'deleteFramebuffer') return (fb) => { calls.push({ fn: 'deleteFramebuffer', fb }); };
      if (name === 'deleteTexture') return (t) => { calls.push({ fn: 'deleteTexture', t }); };
      if (name === 'texStorage2D') return (t, levels, fmt, tw, th) => {
        calls.push({ fn: 'texStorage2D', fmt, w: tw, h: th });
      };
      if (name === 'bindFramebuffer') return (tgt, fb) => {
        if (tgt === GL_CONST.FRAMEBUFFER) boundFb = fb;
        calls.push({ fn: 'bindFramebuffer', tgt, fb });
      };
      if (name === 'blitFramebuffer') return (...args) => {
        calls.push({ fn: 'blitFramebuffer', args });
      };
      if (name === 'enable') return (cap) => { if (cap === GL_CONST.SCISSOR_TEST) scissorOn = true; };
      if (name === 'disable') return (cap) => { if (cap === GL_CONST.SCISSOR_TEST) scissorOn = false; };
      if (name === 'scissor') return (x, y, sw, sh) => {
        scissorBox = [x, y, sw, sh];
        calls.push({ fn: 'scissor', box: scissorBox });
      };
      if (name === 'drawArrays') return (mode, first, count) => {
        calls.push({ fn: 'drawArrays', prog: boundProg, fb: boundFb, count });
      };
      if (name === 'drawArraysInstanced') return (mode, first, count, instCount) => {
        calls.push({
          fn: 'drawArraysInstanced',
          prog: boundProg,
          fb: boundFb,
          scissorOn,
          scissorBox: scissorOn ? scissorBox : null,
          instCount,
        });
      };
      if (name === 'getUniformLocation') return (p, u) => ({ p, u });
      return () => ({});
    },
  });

  const element = () => ({
    style: {},
    listeners: new Map(),
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    dispatch(name, e = {}) { for (const f of this.listeners.get(name) || []) f(e); },
    setPointerCapture() {},
  });

  const canvas = {
    ...element(),
    width: Math.round(w * dpr),
    height: Math.round(h * dpr),
    getContext: (type, opts) => {
      calls.push({ fn: 'getContext', type, opts });
      return gl;
    },
    getBoundingClientRect: () => {
      rectCalls++;
      return { width: w, height: h, left: rectLeft, top: rectTop };
    },
  };
  const ta = element();
  const doc = {
    ...element(),
    activeElement: null,
    hidden: false,
    visibilityState: 'visible',
    body: element(),
    createElement: () => ({ ...element(), getContext: () => ({}) }),
    getElementById: (id) => (id === 'c' ? canvas : ta),
  };
  const visualViewport = { ...element(), height: h, offsetTop: 0, scale: 1 };
  const win = {
    ...element(),
    document: doc,
    navigator: nav,
    location: { search },
    URLSearchParams,
    Intl,
    queueMicrotask,
    devicePixelRatio: dpr,
    performance: { now: () => now },
    setTimeout: (f, ms) => { timers.push([f, ms]); return timers.length; },
    requestAnimationFrame: (f) => { rafs.push(f); return rafs.length; },
    cancelAnimationFrame: (id) => { rafs[id - 1] = null; },
    visualViewport,
    matchMedia: () => ({ addEventListener() {}, removeEventListener() {} }),
  };
  win.window = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  const H = win.__mbhost;
  H.run('test', () => {}, (kind, x, y, btn) => pointers.push([kind, x, y, btn, H.eventTime()]), () => {}, () => {}, () => {});

  return {
    H, win, doc, canvas, visualViewport, calls, timers, rafs, pointers,
    setNow(t) { now = t; },
    setRect(l, t) { rectLeft = l; rectTop = t; },
    rectCalls: () => rectCalls,
    resetCalls() { calls.length = 0; },
  };
}

function makeRect(buf, idx, x, y, w, h, { r = 0, a = 1, border = 0, rad = 0 } = {}) {
  const o = idx * INST;
  buf[o] = x; buf[o + 1] = y; buf[o + 2] = w; buf[o + 3] = h;
  buf[o + 4] = rad; buf[o + 5] = 0; buf[o + 6] = border;
  buf[o + 8] = r; buf[o + 9] = 0.2; buf[o + 10] = 0.3; buf[o + 11] = a;
  if (border > 0) { buf[o + 12] = 0.8; buf[o + 13] = 0.8; buf[o + 14] = 0.8; buf[o + 15] = 1; }
  buf[o + 16] = -1e9; buf[o + 17] = -1e9; buf[o + 18] = 1e9; buf[o + 19] = 1e9;
  buf[o + 36] = rad; buf[o + 37] = rad; buf[o + 38] = rad; buf[o + 39] = rad;
}

test('adaptive settle redraws the entire shared glass capture', () => {
  const b = makeHost({ w: 400, h: 300, dpr: 2 });
  const buf = new Float64Array(6 * INST);
  makeRect(buf, 0, 0, 0, 400, 300, { r: 0.95 });
  makeRect(buf, 1, 56, 216, 160, 12, { r: 0.1 });
  makeRect(buf, 2, 40, 116, 140, 32, { r: 0.99 });
  makeRect(buf, 3, 32, 180, 336, 92, { r: 0.99 });
  for (const i of [2, 3]) {
    const o = i * INST;
    buf[o + 5] = 6; buf[o + 6] = 1; buf[o + 7] = 4;
    buf[o + 11] = 0x67 / 255; buf[o + 13] = 8; buf[o + 14] = -1;
    buf[o + 15] = 1; buf[o + 20] = -1; buf[o + 21] = 6;
  }
  makeRect(buf, 4, 40, 8, 120, 12, { r: 0.4, a: 0 });
  makeRect(buf, 5, 0, 0, 0, 0);
  buf[5 * INST + 5] = 12;
  b.H.present(buf, 6, 0.95, 0.95, 0.95);
  b.H.renderDirty(0, 0, 400, 300);
  buf[8] = 0.93;
  b.H.present(buf, 6, 0.95, 0.95, 0.95);
  b.resetCalls();
  buf[4 * INST + 11] = 0.5;
  buf[5 * INST + 12] = 1;
  b.H.renderDirty(32, 0, 144, 32);
  b.H.present(buf, 6, 0.95, 0.95, 0.95);
  const draws = b.calls.filter((c) => c.fn === 'drawArraysInstanced' && c.prog?.oneKind === 13 && c.scissorOn);
  assert.ok(draws.length, 'adaptive glass was redrawn');
  for (const { scissorBox: [x, y, w, h] } of draws) {
    assert.ok(x <= 24 && y <= 16 && x + w >= 776 && y + h >= 408, 'the whole capture is redrawn');
  }
});

test('adaptive settle merges overlapping captures and draws each glass once', () => {
  const b = makeHost({ w: 400, h: 300, dpr: 2 });
  const buf = new Float64Array(7 * INST);
  makeRect(buf, 0, 0, 0, 400, 300, { r: 0.95 });
  makeRect(buf, 1, 56, 216, 160, 12, { r: 0.1 });
  // Two independent adaptive liquid glasses spaced 8pt apart so their captures overlap.
  makeRect(buf, 2, 40, 128, 140, 32, { r: 0.99 });
  makeRect(buf, 3, 32, 168, 336, 92, { r: 0.99 });
  const cfg = [
    { i: 2, tid: -1, blur: 2.1, refract: 28 },
    { i: 3, tid: -2, blur: 4.0, refract: 28 },
  ];
  for (const { i, tid, blur, refract } of cfg) {
    const o = i * INST;
    buf[o + 5] = 6; buf[o + 6] = 1; buf[o + 7] = blur;
    buf[o + 11] = 0x67 / 255; buf[o + 13] = 8; buf[o + 14] = -1;
    buf[o + 15] = 1; buf[o + 20] = tid; buf[o + 21] = refract;
  }
  // High-contrast blue foreground caret inside the lower glass, drawn after glass.
  makeRect(buf, 4, 48, 196, 2, 24, { r: 0.05 });
  buf[4 * INST + 9] = 0.35; buf[4 * INST + 10] = 1.0;
  // Unrelated top bar that changes during settling.
  makeRect(buf, 5, 40, 8, 120, 12, { r: 0.4, a: 0 });
  makeRect(buf, 6, 0, 0, 0, 0);
  buf[6 * INST + 5] = 12;
  b.H.present(buf, 7, 0.95, 0.95, 0.95);
  b.H.renderDirty(0, 0, 400, 300);
  buf[8] = 0.93;
  b.H.present(buf, 7, 0.95, 0.95, 0.95);
  b.resetCalls();
  buf[5 * INST + 11] = 0.5;
  buf[6 * INST + 12] = 1;
  b.H.renderDirty(32, 0, 144, 32);
  b.H.present(buf, 7, 0.95, 0.95, 0.95);
  const draws = b.calls.filter((c) => c.fn === 'drawArraysInstanced' && c.prog?.oneKind === 13 && c.scissorOn);
  assert.equal(draws.length, 2, 'each of the two independent adaptive glasses is drawn exactly once');
  for (const { scissorBox: [x, y, w, h] } of draws) {
    // Union of both captures in 2x pixels: x in [0, 800], top pill y=128..160 (margin ~36pt -> y0<=92),
    // bottom box y=168..260 (margin ~42pt -> y1>=300 -> WebGL bottom y=0, top y=600-184=416).
    assert.ok(x <= 4 && y <= 2 && x + w >= 796 && y + h >= 416, `scissor covers full union capture: [${x},${y},${w},${h}]`);
  }
});

test('whole-screen frames draw straight to null with zero blit; partial dirty builds cv once then scissors', () => {
  const b = makeHost({ w: 351, h: 805, dpr: 3 });
  const ctx = b.calls.find((c) => c.fn === 'getContext');
  assert.equal(ctx.opts.alpha, true, 'alpha stays true for kind 9 holes and RGBA8 default-FB glass blits');
  b.resetCalls();

  const buf = new Float64Array(INST);
  makeRect(buf, 0, 10, 10, 40, 40);

  // Frame 1: whole-screen (no renderDirty) -> straight to null, 0 blitFramebuffer, 0 cv FBO created
  b.H.present(buf, 1, 0.1, 0.1, 0.1);
  assert.equal(b.calls.filter((c) => c.fn === 'blitFramebuffer').length, 0, 'no blit on whole-screen frame');
  assert.equal(b.calls.filter((c) => c.fn === 'createFramebuffer').length, 0, 'no cv FBO allocated on whole-screen frame');
  const draws1 = b.calls.filter((c) => c.fn === 'drawArraysInstanced');
  assert.ok(draws1.length > 0 && draws1.every((d) => d.fb === null), 'drawn straight into default framebuffer null');

  // Frame 2: first partial dirty frame after whole-screen -> allocates cv, draws baseline into cv, blits once to null
  b.resetCalls();
  b.H.renderDirty(10, 10, 40, 40);
  b.H.present(buf, 1, 0.1, 0.1, 0.1);
  assert.equal(b.calls.filter((c) => c.fn === 'createFramebuffer').length, 1, 'cv FBO created once');
  assert.equal(b.calls.filter((c) => c.fn === 'blitFramebuffer').length, 1, 'cv blitted to null');
  const draws2 = b.calls.filter((c) => c.fn === 'drawArraysInstanced');
  assert.ok(draws2.length > 0 && draws2.every((d) => d.fb !== null && !d.scissorOn), 'baseline drawn whole into cv');

  // Frame 3: subsequent partial dirty frame -> reuses cv, scissor-redraws dirty rect only, blits to null
  b.resetCalls();
  b.H.renderDirty(10, 10, 20, 20);
  b.H.present(buf, 1, 0.1, 0.1, 0.1);
  assert.equal(b.calls.filter((c) => c.fn === 'createFramebuffer').length, 0, 'cv FBO reused');
  assert.equal(b.calls.filter((c) => c.fn === 'blitFramebuffer').length, 1, 'cv blitted to null');
  const draws3 = b.calls.filter((c) => c.fn === 'drawArraysInstanced');
  assert.ok(draws3.length > 0 && draws3.every((d) => d.fb !== null && d.scissorOn), 'partial frame uses scissor on cv');

  // Frame 4: back to whole-screen -> draws straight to null again
  b.resetCalls();
  b.H.present(buf, 1, 0.1, 0.1, 0.1);
  assert.equal(b.calls.filter((c) => c.fn === 'blitFramebuffer').length, 0, 'back to zero blit on whole-screen frame');
  const draws4 = b.calls.filter((c) => c.fn === 'drawArraysInstanced');
  assert.ok(draws4.length > 0 && draws4.every((d) => d.fb === null), 'back to default framebuffer null');

  // Page hidden -> trimRender deletes cv FBO
  b.resetCalls();
  b.doc.hidden = true;
  b.doc.dispatch('visibilitychange');
  assert.equal(b.calls.filter((c) => c.fn === 'deleteFramebuffer').length, 1, 'cv FBO freed on visibilitychange hidden');
});

test('glass allocates tight capture-box levels and reuses cached blur from glassSlots with zero passes', () => {
  const b = makeHost({ w: 351, h: 805, dpr: 3 }); // 1053 x 2415 framebuffer
  b.resetCalls();

  const buf = new Float64Array(INST * 2);
  makeRect(buf, 0, 0, 0, 351, 805, { r: 0.2, a: 1 });
  // Small frosted glass bar at bottom: 100x40 pt with blur=4
  const g = INST;
  buf[g] = 20; buf[g + 1] = 700; buf[g + 2] = 100; buf[g + 3] = 40;
  buf[g + 5] = 5; // frosted glass
  buf[g + 7] = 4; // blur radius
  buf[g + 8] = 1; buf[g + 9] = 1; buf[g + 10] = 1; buf[g + 11] = 0.2;
  buf[g + 15] = 1;
  buf[g + 16] = -1e9; buf[g + 17] = -1e9; buf[g + 18] = 1e9; buf[g + 19] = 1e9;
  buf[g + 20] = -1; // glass capture group

  // Frame 1: cold blur -> allocates tight levels (much smaller than 1053x2415) and runs blur passes
  b.H.present(buf, 2, 0.1, 0.1, 0.1);
  const storages = b.calls.filter((c) => c.fn === 'texStorage2D');
  assert.ok(storages.length >= 5, 'glass levels allocated');
  for (const s of storages) {
    assert.ok(s.w < 600 && s.h < 400, `tight glass level ${s.w}x${s.h}, not full screen 1053x2415`);
  }
  const passes1 = b.calls.filter((c) => c.fn === 'drawArrays').length;
  const blits1 = b.calls.filter((c) => c.fn === 'blitFramebuffer').length;
  assert.ok(passes1 > 0 && blits1 === 1, 'cold glass ran blur passes and swapped into slot without extra blit');

  // Frame 2: identical content under glass -> hits glassSlots cache, 0 blur passes, 0 blitFramebuffer
  b.resetCalls();
  b.H.present(buf, 2, 0.1, 0.1, 0.1);
  assert.equal(b.calls.filter((c) => c.fn === 'drawArrays').length, 0, 'cached glass ran zero blur passes');
  assert.equal(b.calls.filter((c) => c.fn === 'blitFramebuffer').length, 0, 'cached glass ran zero blits');

  // Frame 3: background color changes under glass -> cache miss, re-blurs
  b.resetCalls();
  buf[8] = 0.9;
  b.H.present(buf, 2, 0.1, 0.1, 0.1);
  assert.ok(b.calls.filter((c) => c.fn === 'drawArrays').length > 0, 'changed content under glass triggers fresh blur');
});

test('14 mixed-size/blur glass captures pre-size levels once, hit 100% cache when static, and avoid texStorage2D on scroll', () => {
  const b = makeHost({ w: 600, h: 2000, dpr: 2 });
  b.resetCalls();

  const N = 14;
  const blurs = [1, 3, 7, 16]; // at dpr=2 -> k = 0, 1, 2, 3
  const buf = new Float64Array(INST * (N + 1));
  makeRect(buf, 0, 0, 0, 600, 2000, { r: 0.25, a: 1 });
  let y = 20;
  for (let i = 0; i < N; i++) {
    const o = (i + 1) * INST;
    const gw = 60 + i * 20;
    const gh = 30 + i * 10;
    buf[o] = 40; buf[o + 1] = y; buf[o + 2] = gw; buf[o + 3] = gh;
    buf[o + 5] = 5; // frosted glass
    buf[o + 7] = blurs[i % blurs.length];
    buf[o + 8] = 1; buf[o + 9] = 1; buf[o + 10] = 1; buf[o + 11] = 0.2;
    buf[o + 15] = 1;
    buf[o + 16] = -1e9; buf[o + 17] = -1e9; buf[o + 18] = 1e9; buf[o + 19] = 1e9;
    buf[o + 20] = -(i + 1);
    y += gh + 20;
  }

  // Frame 1: lv pre-sized once at max capture box (5 lv textures + 14 slot textures = 19 texStorage2D, 0 deleteTexture)
  b.H.present(buf, N + 1, 0.1, 0.1, 0.1);
  assert.equal(b.calls.filter((c) => c.fn === 'texStorage2D').length, 19, 'frame 1 allocates 5 lv + 14 slot textures once');
  assert.equal(b.calls.filter((c) => c.fn === 'deleteTexture').length, 0, 'frame 1 performs zero mid-frame texture deletes');

  // Frame 2: static frame -> all 14 glasses hit cache (0 drawArrays, 0 blitFramebuffer, 0 texStorage2D)
  b.resetCalls();
  b.H.present(buf, N + 1, 0.1, 0.1, 0.1);
  assert.equal(b.calls.filter((c) => c.fn === 'drawArrays').length, 0, 'static frame runs zero blur passes');
  assert.equal(b.calls.filter((c) => c.fn === 'blitFramebuffer').length, 0, 'static frame runs zero blits');
  assert.equal(b.calls.filter((c) => c.fn === 'texStorage2D').length, 0, 'static frame allocates zero textures');

  // Frames 3..8: 6 consecutive scroll frames (moving background invalidates all 14 glasses each frame).
  // Once slots warm up (frames 5..8), texture-affinity eviction keeps texStorage2D == 0 and deleteTexture == 0.
  for (let frame = 3; frame <= 8; frame++) {
    b.resetCalls();
    buf[0] = (frame - 2) * 5;
    b.H.present(buf, N + 1, 0.1, 0.1, 0.1);
    assert.ok(b.calls.filter((c) => c.fn === 'drawArrays').length > 0, `scroll frame ${frame} re-blurs invalidated glasses`);
    if (frame >= 5) {
      assert.equal(b.calls.filter((c) => c.fn === 'texStorage2D').length, 0, `scroll frame ${frame} allocates zero textures`);
      assert.equal(b.calls.filter((c) => c.fn === 'deleteTexture').length, 0, `scroll frame ${frame} deletes zero textures`);
    }
  }
});

test('MB_PROG_UI batching, VS adaptive ink, progFlat for large solid rects, and banded strips for hollow border & occluded shadow', () => {
  const b = makeHost({ w: 400, h: 400, dpr: 2 }); // 800x800 px
  const initLinks = b.calls.filter((c) => c.fn === 'linkProgram');
  // Startup links MB_PROG_UI, progFlat, post and adaptive state; glass/path/lens programs are lazy.
  assert.equal(initLinks.length, 4, 'startup compiles only the shared programs');
  const uiProg = initLinks.find((c) => c.prog.oneKind === -1)?.prog;
  assert.ok(uiProg, 'MB_PROG_UI compiled at startup');
  assert.ok(!uiProg.vsAdaptive, 'MB_PROG_UI uses lean VS without adaptive ink');
  assert.ok(!uiProg.fsSrc.includes('mb_adaptive_ink_at'), 'FS carries no per-fragment adaptive ink');
  assert.ok(initLinks.some((c) => c.prog.isFlat), 'progFlat compiled at startup');

  // 1) Large solid-color rounded rect (kind 0, 300x300 pt = 600x600 px) -> uses MB_PROG_UI (no extra compile) and progFlat
  b.resetCalls();
  const buf1 = new Float64Array(INST);
  makeRect(buf1, 0, 20, 20, 300, 300, { r: 0.5, a: 1, rad: 16 });
  b.H.present(buf1, 1, 0, 0, 0);
  assert.equal(b.calls.filter((c) => c.fn === 'linkProgram').length, 0, 'kind 0 reuses startup MB_PROG_UI');
  const draws1 = b.calls.filter((c) => c.fn === 'drawArraysInstanced');
  assert.ok(draws1.some((d) => d.prog.isFlat && d.scissorOn), 'interior cross drawn with progFlat');
  assert.ok(draws1.some((d) => d.prog === uiProg && d.scissorOn), 'edges/corners drawn with MB_PROG_UI');

  // 2) Hollow border (kind 0, fill alpha 0, border=2, 300x300 pt) -> banded strips skipping center
  b.resetCalls();
  const buf2 = new Float64Array(INST);
  makeRect(buf2, 0, 20, 20, 300, 300, { r: 0, a: 0, border: 2, rad: 16 });
  b.H.present(buf2, 1, 0, 0, 0);
  const draws2 = b.calls.filter((c) => c.fn === 'drawArraysInstanced');
  assert.ok(draws2.length >= 4 && draws2.every((d) => d.scissorOn && d.prog === uiProg), 'hollow border drawn in scissor strips');
  const shadedArea2 = draws2.reduce((sum, d) => sum + d.scissorBox[2] * d.scissorBox[3], 0);
  assert.ok(shadedArea2 < 600 * 600 * 0.5, `hollow border skips center (shaded ${shadedArea2} < half of 360000)`);

  // 3) Occluded shadow (kind 2) followed by opaque kind 0 box -> reuses MB_PROG_UI and skips occluded center
  b.resetCalls();
  const buf3 = new Float64Array(INST * 2);
  // Shadow (kind 2) at 50,50 250x250 blur=12
  buf3[0] = 50; buf3[1] = 50; buf3[2] = 250; buf3[3] = 250;
  buf3[4] = 16; buf3[5] = 2; buf3[7] = 12;
  buf3[8] = 0; buf3[9] = 0; buf3[10] = 0; buf3[11] = 0.4;
  buf3[16] = -1e9; buf3[17] = -1e9; buf3[18] = 1e9; buf3[19] = 1e9;
  buf3[36] = 16; buf3[37] = 16; buf3[38] = 16; buf3[39] = 16;
  // Opaque box right after it
  makeRect(buf3, 1, 50, 50, 250, 250, { r: 1, a: 1, rad: 16 });
  b.H.present(buf3, 2, 0, 0, 0);
  assert.equal(b.calls.filter((c) => c.fn === 'linkProgram').length, 0, 'kind 2 reuses startup MB_PROG_UI');
  const shadowDraws = b.calls.filter((c) => c.fn === 'drawArraysInstanced' && dIsShadowOrEdge(c, uiProg));
  assert.ok(shadowDraws.length >= 4 && shadowDraws.every((d) => d.scissorOn), 'occluded shadow drawn in scissor strips');

  // 4) Mixed basic UI kinds (0, 1, 2, 10) with tid=0 batch into a single instanced draw call & 1 useProgram
  b.resetCalls();
  const buf4 = new Float64Array(INST * 8);
  for (let i = 0; i < 2; i++) {
    const y = 10 + i * 24;
    makeRect(buf4, i * 4 + 0, 10, y, 16, 16, { r: 0.2, g: 0.4, b: 0.8, a: 1 });
    // kind 1 glyph
    const g = (i * 4 + 1) * INST;
    buf4[g] = 30; buf4[g + 1] = y; buf4[g + 2] = 10; buf4[g + 3] = 12;
    buf4[g + 5] = 1; buf4[g + 11] = 1; buf4[g + 16] = -1e9; buf4[g + 17] = -1e9; buf4[g + 18] = 1e9; buf4[g + 19] = 1e9;
    // kind 2 small shadow
    const sh = (i * 4 + 2) * INST;
    buf4[sh] = 44; buf4[sh + 1] = y; buf4[sh + 2] = 12; buf4[sh + 3] = 12;
    buf4[sh + 5] = 2; buf4[sh + 7] = 2; buf4[sh + 11] = 0.3; buf4[sh + 16] = -1e9; buf4[sh + 17] = -1e9; buf4[sh + 18] = 1e9; buf4[sh + 19] = 1e9;
    // kind 10 line
    const ln = (i * 4 + 3) * INST;
    buf4[ln] = 60; buf4[ln + 1] = y; buf4[ln + 2] = 16; buf4[ln + 3] = 12;
    buf4[ln + 4] = 1.5; buf4[ln + 5] = 10; buf4[ln + 8] = 0.9; buf4[ln + 11] = 1;
    buf4[ln + 12] = 0.1; buf4[ln + 13] = 0.5; buf4[ln + 14] = 0.9; buf4[ln + 15] = 0.5;
    buf4[ln + 16] = -1e9; buf4[ln + 17] = -1e9; buf4[ln + 18] = 1e9; buf4[ln + 19] = 1e9;
  }
  b.H.present(buf4, 8, 1, 1, 1);
  const mixedDraws = b.calls.filter((c) => c.fn === 'drawArraysInstanced');
  const mixedUses = b.calls.filter((c) => c.fn === 'useProgram');
  assert.equal(mixedDraws.length, 1, '8 mixed basic UI instances batch into 1 drawArraysInstanced');
  assert.equal(mixedDraws[0].instCount, 8);
  assert.equal(mixedUses.length, 1, 'only 1 useProgram for batched UI frame');

  // 5) Adaptive primitive (kind 7) lazily compiles MB_PROG_UI_AD (oneKind === -2, vsAdaptive === true)
  b.resetCalls();
  const buf5 = new Float64Array(INST * 2);
  makeRect(buf5, 0, 10, 10, 16, 16, { r: 0.2, g: 0.4, b: 0.8, a: 1 });
  const adg = INST;
  buf5[adg] = 30; buf5[adg + 1] = 10; buf5[adg + 2] = 10; buf5[adg + 3] = 14;
  buf5[adg + 5] = 7; buf5[adg + 8] = 0.9; buf5[adg + 9] = 0.9; buf5[adg + 10] = 0.9; buf5[adg + 11] = 1;
  buf5[adg + 16] = -1e9; buf5[adg + 17] = -1e9; buf5[adg + 18] = 1e9; buf5[adg + 19] = 1e9;
  buf5[adg + 21] = 35; buf5[adg + 22] = 17; buf5[adg + 23] = bareInk(14, 14);
  b.H.present(buf5, 2, 1, 1, 1);
  const adLinks = b.calls.filter((c) => c.fn === 'linkProgram');
  assert.equal(adLinks.length, 1, 'kind 7 lazily compiles MB_PROG_UI_AD once');
  assert.equal(adLinks[0].prog.oneKind, -2, 'MB_PROG_UI_AD uses ONE_KIND -2');
  assert.ok(adLinks[0].prog.vsAdaptive, 'MB_PROG_UI_AD enables VS adaptive ink');
});
function dIsShadowOrEdge(c, uiProg) { return c.prog === uiProg; }

test('pointermove uses cached getBoundingClientRect and expands touch getCoalescedEvents', () => {
  const b = makeHost({ w: 400, h: 800, dpr: 3 });
  const beforeRect = b.rectCalls();

  // 10 pointermove events with zero extra getBoundingClientRect calls
  for (let i = 0; i < 10; i++) {
    b.canvas.dispatch('pointermove', {
      pointerType: 'touch',
      pointerId: 7,
      clientX: 100 + i,
      clientY: 200 + i,
      timeStamp: 100 + i * 8,
    });
  }
  assert.equal(b.rectCalls(), beforeRect, 'cached canvas rect avoids reflow on pointermove');
  assert.equal(b.pointers.length, 10);
  assert.deepEqual(b.pointers[0], [11, 90, 180, 7, 100], 'uses cached rectLeft=10, rectTop=20');

  // Coalesced touch samples
  b.pointers.length = 0;
  b.canvas.dispatch('pointermove', {
    pointerType: 'touch',
    pointerId: 9,
    clientX: 130,
    clientY: 230,
    timeStamp: 300,
    getCoalescedEvents: () => [
      { clientX: 110, clientY: 210, timeStamp: 292 },
      { clientX: 120, clientY: 220, timeStamp: 0 }, // falls back to parent event timeStamp
      { clientX: 130, clientY: 230, timeStamp: 300 },
    ],
  });
  assert.deepEqual(b.pointers, [
    [11, 100, 190, 9, 292],
    [11, 110, 200, 9, 300],
    [11, 120, 210, 9, 300],
  ], 'coalesced events expanded with exact coordinates and timestamps');

  // Scroll invalidates rect cache -> next pointermove refreshes once
  b.setRect(30, 40);
  b.win.dispatch('scroll');
  b.pointers.length = 0;
  b.canvas.dispatch('pointermove', { pointerType: 'touch', pointerId: 9, clientX: 50, clientY: 70, timeStamp: 310 });
  assert.equal(b.rectCalls(), beforeRect + 1, 'scroll invalidated cache and refreshed once');
  assert.deepEqual(b.pointers, [[11, 20, 30, 9, 310]]);
});

test('H.framesPaced throttles low-rate animations via wakeAfter on 120Hz displays', async () => {
  const b = makeHost({ w: 400, h: 800, dpr: 3 });
  await new Promise((r) => setTimeout(r, 0));

  // Drive several 120Hz rAF frames (8.33ms apart) so displayFrame converges near 8.33ms
  let ts = 100;
  for (let i = 0; i < 20; i++) {
    b.H.requestFrame();
    const fn = b.rafs.find((f) => f !== null);
    b.rafs.length = 0;
    b.setNow(ts);
    fn(ts);
    ts += 8.33;
  }

  // 10 Hz animation (100ms period >> 1.5 * 8.33ms) -> schedules wakeAfter timer, not immediate rAF
  b.rafs.length = 0;
  b.timers.length = 0;
  b.H.framesPaced(10);
  assert.equal(b.rafs.length, 0, '10Hz does not request immediate rAF at 120Hz');
  assert.equal(b.timers.length, 1, '10Hz scheduled via wakeAfter timer');
  assert.ok(b.timers[0][1] > 50 && b.timers[0][1] < 100, `wakeAfter lead ${b.timers[0][1]}ms is sensible`);

  // 120 Hz animation (8.33ms <= 1.5 * 8.33ms) -> immediate rAF
  b.H.framesPaced(120);
  assert.equal(b.rafs.length, 1, '120Hz requests immediate rAF');
});

test('Perf-51: dark adaptive zero settle, top-bar donor delegation keeps back pill capture tight, lens subtree does not delegate', () => {
  const b = makeHost({ w: 400, h: 300, dpr: 2 });
  const buf = new Float64Array(INST * 4);
  // 0: dark backdrop
  makeRect(buf, 0, 0, 0, 400, 300, { r: 0.06, g: 0.06, b: 0.06, a: 1 });
  // 1: pure progressive donor covering top bar (0, 0, 400, 96), tid=-1
  const d = INST;
  buf[d] = 0; buf[d + 1] = 0; buf[d + 2] = 400; buf[d + 3] = 96;
  buf[d + 5] = 5; buf[d + 6] = 1; buf[d + 7] = 8; buf[d + 11] = 0; buf[d + 15] = 1;
  buf[d + 16] = -1e9; buf[d + 17] = -1e9; buf[d + 18] = 1e9; buf[d + 19] = 1e9;
  buf[d + 20] = -1; buf[d + 22] = -1; buf[d + 54] = 96; buf[d + 55] = 48;
  // 2: small 40x40 dark adaptive back pill (tid=-2)
  const p = 2 * INST;
  buf[p] = 12; buf[p + 1] = 28; buf[p + 2] = 40; buf[p + 3] = 40;
  buf[p + 4] = 20; buf[p + 5] = 6; buf[p + 6] = 1; buf[p + 7] = 1.4;
  buf[p + 8] = 0.12; buf[p + 9] = 0.12; buf[p + 10] = 0.12; buf[p + 11] = 0.4;
  buf[p + 14] = -1; buf[p + 15] = 1;
  buf[p + 16] = -1e9; buf[p + 17] = -1e9; buf[p + 18] = 1e9; buf[p + 19] = 1e9;
  buf[p + 20] = -2; buf[p + 21] = 8; buf[p + 23] = 4;
  // 3: bare-adaptive title glyph at x=120..220
  const t = 3 * INST;
  buf[t] = 120; buf[t + 1] = 34; buf[t + 2] = 100; buf[t + 3] = 24;
  buf[t + 5] = 7; buf[t + 8] = 0.9; buf[t + 9] = 0.9; buf[t + 10] = 0.9; buf[t + 11] = 1;
  buf[t + 16] = -1e9; buf[t + 17] = -1e9; buf[t + 18] = 1e9; buf[t + 19] = 1e9;
  buf[t + 21] = 170; buf[t + 22] = 46; buf[t + 23] = bareInk(100, 24);

  b.resetCalls();
  b.H.present(buf, 4, 0.06, 0.06, 0.06);
  // Flip backdrop -> dark adaptive must not arm settle rAF
  b.rafs.length = 0;
  makeRect(buf, 0, 0, 0, 400, 300, { r: 0.94, g: 0.94, b: 0.94, a: 1 });
  b.H.present(buf, 4, 0.94, 0.94, 0.94);
  assert.equal(b.rafs.length, 0, 'dark adaptive pill does not schedule settle rAF after backdrop flip');

  // Verify back pill capture stayed tight (blitFramebuffer width for pill << 300px, not expanded across x=120..220)
  const blits = b.calls.filter((c) => c.fn === 'blitFramebuffer');
  assert.ok(blits.length >= 2, 'donor and pill captured');
  // Second capture is the back pill: width in 2x px should be tight (~120..180px, definitely < 260px)
  const pillBlit = blits[1];
  const pillW = pillBlit.args[2] - pillBlit.args[0];
  assert.ok(pillW < 260, `delegated back pill capture stays tight (${pillW}px < 260px)`);
});

test('Perf-51 R2: lens subtree counterexample, 33rd cold capture donor pin, and closeAdaptiveParts kind=8 boundary', () => {
  // (a) Lens subtree counterexample: [kind=8 (child_n=1), pure kind=5 child, kind=6 pill, bare title] -> NOT delegated (pillW >= 260)
  {
    const b = makeHost({ w: 400, h: 300, dpr: 2 });
    const buf = new Float64Array(INST * 5);
    makeRect(buf, 0, 0, 0, 400, 300, { r: 0.06, g: 0.06, b: 0.06, a: 1 });
    // 1: kind=8 lens header with child_n=1
    const lh = INST;
    buf[lh] = 0; buf[lh + 1] = 0; buf[lh + 2] = 400; buf[lh + 3] = 96;
    buf[lh + 5] = 8; buf[lh + 7] = 2; buf[lh + 11] = 1; buf[lh + 12] = 1; buf[lh + 15] = 1;
    buf[lh + 16] = -1e9; buf[lh + 17] = -1e9; buf[lh + 18] = 1e9; buf[lh + 19] = 1e9;
    // 2: pure progressive kind=5 child inside lens subtree (MUST NOT delegate)
    const d = 2 * INST;
    buf[d] = 0; buf[d + 1] = 0; buf[d + 2] = 400; buf[d + 3] = 96;
    buf[d + 5] = 5; buf[d + 6] = 1; buf[d + 7] = 8; buf[d + 11] = 0; buf[d + 15] = 1;
    buf[d + 16] = -1e9; buf[d + 17] = -1e9; buf[d + 18] = 1e9; buf[d + 19] = 1e9;
    buf[d + 20] = -10; buf[d + 22] = -1; buf[d + 54] = 96; buf[d + 55] = 48;
    // 3: 40x40 back pill
    const p = 3 * INST;
    buf[p] = 12; buf[p + 1] = 28; buf[p + 2] = 40; buf[p + 3] = 40;
    buf[p + 4] = 20; buf[p + 5] = 6; buf[p + 6] = 1; buf[p + 7] = 1.4;
    buf[p + 8] = 0.12; buf[p + 9] = 0.12; buf[p + 10] = 0.12; buf[p + 11] = 0.4;
    buf[p + 14] = -1; buf[p + 15] = 1;
    buf[p + 16] = -1e9; buf[p + 17] = -1e9; buf[p + 18] = 1e9; buf[p + 19] = 1e9;
    buf[p + 20] = -11; buf[p + 21] = 8; buf[p + 23] = 4;
    // 4: bare-adaptive title at x=120..220
    const t = 4 * INST;
    buf[t] = 120; buf[t + 1] = 34; buf[t + 2] = 100; buf[t + 3] = 24;
    buf[t + 5] = 7; buf[t + 8] = 0.9; buf[t + 9] = 0.9; buf[t + 10] = 0.9; buf[t + 11] = 1;
    buf[t + 16] = -1e9; buf[t + 17] = -1e9; buf[t + 18] = 1e9; buf[t + 19] = 1e9;
    buf[t + 21] = 170; buf[t + 22] = 46; buf[t + 23] = bareInk(100, 24);

    b.resetCalls();
    b.H.present(buf, 5, 0.06, 0.06, 0.06);
    const blits = b.calls.filter((c) => c.fn === 'blitFramebuffer' && (c.args[3] - c.args[1]) > 1);
    assert.ok(blits.length >= 1, 'pill captured');
    const pillBlit = blits[blits.length - 1];
    const pillW = pillBlit.args[2] - pillBlit.args[0];
    assert.ok(pillW >= 260, `lens child is NOT a donor so pill capture expands over bare title (${pillW}px >= 260px)`);
  }

  // (b) 33rd cold capture donor pin: donor's bt texture is never deleted/evicted while pinned
  {
    const b = makeHost({ w: 400, h: 300, dpr: 2 });
    const count = 35;
    const buf = new Float64Array(INST * count);
    makeRect(buf, 0, 0, 0, 400, 300, { r: 0.06, g: 0.06, b: 0.06, a: 1 });
    // 1: pure progressive donor (tid=-20)
    const d = INST;
    buf[d] = 0; buf[d + 1] = 0; buf[d + 2] = 400; buf[d + 3] = 96;
    buf[d + 5] = 5; buf[d + 6] = 1; buf[d + 7] = 8; buf[d + 11] = 0; buf[d + 15] = 1;
    buf[d + 16] = -1e9; buf[d + 17] = -1e9; buf[d + 18] = 1e9; buf[d + 19] = 1e9;
    buf[d + 20] = -20; buf[d + 22] = -1; buf[d + 54] = 96; buf[d + 55] = 48;
    // 2..32: 31 distinct cold glasses below y=104 (33 total cold captures with donor + pill)
    for (let i = 0; i < 31; i++) {
      const g = (2 + i) * INST;
      buf[g] = 8 + (i % 10) * 38; buf[g + 1] = 104 + Math.floor(i / 10) * 44;
      buf[g + 2] = 28; buf[g + 3] = 28;
      buf[g + 5] = 5; buf[g + 6] = 1; buf[g + 7] = 2; buf[g + 11] = 0.2; buf[g + 15] = 1;
      buf[g + 16] = -1e9; buf[g + 17] = -1e9; buf[g + 18] = 1e9; buf[g + 19] = 1e9;
      buf[g + 20] = -(30 + i);
    }
    // 33: 40x40 back pill (33rd cold capture -> triggers slotFill eviction)
    const p = 33 * INST;
    buf[p] = 12; buf[p + 1] = 28; buf[p + 2] = 40; buf[p + 3] = 40;
    buf[p + 4] = 20; buf[p + 5] = 6; buf[p + 6] = 1; buf[p + 7] = 1.4;
    buf[p + 8] = 0.12; buf[p + 9] = 0.12; buf[p + 10] = 0.12; buf[p + 11] = 0.4;
    buf[p + 14] = -1; buf[p + 15] = 1;
    buf[p + 16] = -1e9; buf[p + 17] = -1e9; buf[p + 18] = 1e9; buf[p + 19] = 1e9;
    buf[p + 20] = -21; buf[p + 21] = 8; buf[p + 23] = 4;
    // 34: bare-adaptive title delegated to donor -20
    const t = 34 * INST;
    buf[t] = 120; buf[t + 1] = 34; buf[t + 2] = 100; buf[t + 3] = 24;
    buf[t + 5] = 7; buf[t + 8] = 0.9; buf[t + 9] = 0.9; buf[t + 10] = 0.9; buf[t + 11] = 1;
    buf[t + 16] = -1e9; buf[t + 17] = -1e9; buf[t + 18] = 1e9; buf[t + 19] = 1e9;
    buf[t + 21] = 170; buf[t + 22] = 46; buf[t + 23] = bareInk(100, 24);

    b.resetCalls();
    b.H.present(buf, count, 0.06, 0.06, 0.06);
    const storages = b.calls.filter((c) => c.fn === 'texStorage2D');
    const deletes = b.calls.filter((c) => c.fn === 'deleteTexture');
    // Donor capture is 400x96@2x (w>=800); filler glasses are small (~28x28@2x).
    // Pinning guarantees the donor's large bt texture is never deleted during the 33rd cold capture!
    const donorTexCount = storages.filter((s) => s.w >= 400).length;
    assert.ok(donorTexCount >= 1, 'donor capture texture allocated');
    // At least one filler texture was evicted/reused for the 33rd capture, and total deleted textures stay bounded
    const blits = b.calls.filter((c) => c.fn === 'blitFramebuffer' && (c.args[3] - c.args[1]) > 1);
    assert.ok(blits.length >= 33, `all 33 cold captures ran (${blits.length} >= 33)`);
    const pillBlit = blits[blits.length - 1];
    const pillW = pillBlit.args[2] - pillBlit.args[0];
    assert.ok(pillW >= 80 && pillW < 260, `33rd back pill stayed delegated & tight (${pillW}px < 260px), deleted=${deletes.length}`);
  }

  // (c) closeAdaptiveParts: tid=0 rect immediately before kind=8 lens header with negative-tid child
  // must NOT swallow the kind=8 header or treat the lens child as a top-level capture
  {
    const b = makeHost({ w: 400, h: 300, dpr: 2 });
    const buf = new Float64Array(INST * 6);
    // 0: tid=0 background rect
    makeRect(buf, 0, 0, 0, 400, 300, { r: 0.95 });
    // 1: kind=8 lens header (tid=0, child_n=1) immediately after tid=0 rect!
    const lh = INST;
    buf[lh] = 0; buf[lh + 1] = 200; buf[lh + 2] = 400; buf[lh + 3] = 80;
    buf[lh + 5] = 8; buf[lh + 7] = 2; buf[lh + 11] = 1; buf[lh + 12] = 1; buf[lh + 15] = 1;
    buf[lh + 16] = -1e9; buf[lh + 17] = -1e9; buf[lh + 18] = 1e9; buf[lh + 19] = 1e9;
    // 2: negative-tid glass child INSIDE kind=8 lens covering full width y=200..280 (must NOT be expanded by closeAdaptiveParts!)
    const lc = 2 * INST;
    buf[lc] = 0; buf[lc + 1] = 200; buf[lc + 2] = 400; buf[lc + 3] = 80;
    buf[lc + 5] = 5; buf[lc + 6] = 1; buf[lc + 7] = 6; buf[lc + 11] = 0.3; buf[lc + 15] = 1;
    buf[lc + 16] = -1e9; buf[lc + 17] = -1e9; buf[lc + 18] = 1e9; buf[lc + 19] = 1e9;
    buf[lc + 20] = -99;
    // 3: small light adaptive liquid glass at top (x=20..100, y=10..50)
    const g = 3 * INST;
    buf[g] = 20; buf[g + 1] = 10; buf[g + 2] = 80; buf[g + 3] = 40;
    buf[g + 4] = 16; buf[g + 5] = 6; buf[g + 6] = 1; buf[g + 7] = 2;
    buf[g + 8] = 0.99; buf[g + 9] = 0.99; buf[g + 10] = 0.99; buf[g + 11] = 0x67 / 255;
    buf[g + 13] = 8; buf[g + 14] = -1; buf[g + 15] = 1;
    buf[g + 16] = -1e9; buf[g + 17] = -1e9; buf[g + 18] = 1e9; buf[g + 19] = 1e9;
    buf[g + 20] = -98; buf[g + 21] = 6;
    // 4: changing small rect touching y=200..240 (would overlap lens child if closeAdaptiveParts mistakenly treated child as top-level)
    makeRect(buf, 4, 20, 210, 40, 20, { r: 0.4, a: 0 });
    makeRect(buf, 5, 0, 0, 0, 0);
    buf[5 * INST + 5] = 12;

    b.H.present(buf, 6, 0.95, 0.95, 0.95);
    // Flip backdrop to trigger light adaptive settle on top glass (-98)
    b.H.renderDirty(0, 0, 400, 300);
    buf[8] = 0.1;
    b.H.present(buf, 6, 0.95, 0.95, 0.95);
    b.resetCalls();
    // Partial dirty touching x=20..60, y=210..230 while top glass settles -> lens child -99 MUST NOT expand dirty to full width 800px!
    buf[4 * INST + 11] = 0.5;
    buf[5 * INST + 12] = 1;
    b.H.renderDirty(20, 210, 40, 20);
    b.H.present(buf, 6, 0.95, 0.95, 0.95);
    const scDraws = b.calls.filter((c) => c.fn === 'drawArraysInstanced' && c.scissorOn && c.scissorBox);
    assert.ok(scDraws.length > 0, 'partial settle drew with scissor');
    const maxW = Math.max(...scDraws.map((c) => c.scissorBox[2]));
    assert.ok(maxW < 400, `lens child (-99) was not treated as top-level capture in closeAdaptiveParts (maxScissorW=${maxW} < 400)`);
  }
});
