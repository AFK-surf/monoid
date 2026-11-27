// Batched parallel WebGL2 shader setup, deferred auxiliary link validation, background KHR_parallel_shader_compile
// prewarm, context-loss / popup-window cleanup, and MB_PROG_LIQUID_MERGED dead-droplet stripping in web/host.js.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

function makeBrowser({ parallel = true, webdriver = false, search = '', failNextLink = null, onFrame = null } = {}) {
  const element = () => ({
    style: {},
    listeners: new Map(),
    attrs: {},
    children: [],
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    dispatch(name, e = {}) { for (const f of this.listeners.get(name) || []) f(e); },
    setAttribute(name, v) { this.attrs[name] = v; },
    appendChild(child) { this.children.push(child); },
    remove() {},
  });

  function makeGl() {
    let nextId = 1;
    let lost = false;
    const ops = [];
    const shaderSrc = new Map();
    const progShaders = new Map();
    const createdProgs = new Set();
    const createdShaders = new Set();
    const createdVs = new Set();
    const deletedProgs = new Set();
    const deletedShaders = new Set();
    const gl = new Proxy({
      VERTEX_SHADER: 0x8b31,
      FRAGMENT_SHADER: 0x8b30,
      COMPILE_STATUS: 0x8b81,
      LINK_STATUS: 0x8b82,
      RGBA8: 0x8058,
      RGBA: 0x1908,
      RGBA32F: 0x8814,
      UNSIGNED_BYTE: 0x1401,
      FLOAT: 0x1406,
      TEXTURE_2D: 0x0de1,
      FRAMEBUFFER: 0x8d40,
      READ_FRAMEBUFFER: 0x8ca8,
      DRAW_FRAMEBUFFER: 0x8ca9,
      COLOR_ATTACHMENT0: 0x8ce0,
      COLOR_BUFFER_BIT: 0x4000,
      NEAREST: 0x2600,
      LINEAR: 0x2601,
      CLAMP_TO_EDGE: 0x812f,
      TEXTURE_MIN_FILTER: 0x2801,
      TEXTURE_MAG_FILTER: 0x2800,
      TEXTURE_WRAP_S: 0x2802,
      TEXTURE_WRAP_T: 0x2803,
      BLEND: 0x0be2,
      SCISSOR_TEST: 0x0c11,
      ONE: 1,
      ONE_MINUS_SRC_ALPHA: 0x0303,
      ARRAY_BUFFER: 0x8892,
      STREAM_DRAW: 0x88e0,
      TRIANGLES: 4,
      TRIANGLE_STRIP: 5,
      TEXTURE0: 0x84c0,
      TEXTURE1: 0x84c1,
      TEXTURE2: 0x84c2,
      TEXTURE3: 0x84c3,
      TEXTURE4: 0x84c4,
      TEXTURE5: 0x84c5,
      NO_ERROR: 0,
      MAX_TEXTURE_SIZE: 0x0d33,
      FRAMEBUFFER_COMPLETE: 0x8cd5,
      FRAMEBUFFER_BINDING: 0x8ca6,
    }, {
      get(target, name) {
        if (name in target) return target[name];
        if (name === 'getExtension') {
          return (extName) => {
            if (extName === 'KHR_parallel_shader_compile') return parallel ? { COMPLETION_STATUS_KHR: 0x91b1 } : null;
            if (extName === 'WEBGL_lose_context') return { loseContext() {}, restoreContext() {} };
            return null;
          };
        }
        if (name === 'isContextLost') return () => lost;
        if (name === 'getError') return () => 0;
        if (name === 'getParameter') return (p) => (p === 0x0d33 ? 4096 : null);
        if (name === 'checkFramebufferStatus') return () => 0x8cd5;
        if (name === 'createShader') {
          return (type) => {
            const s = { id: nextId++, type };
            createdShaders.add(s.id);
            if (type === 0x8b31) createdVs.add(s.id);
            ops.push(['createShader', s.id, type]);
            return s;
          };
        }
        if (name === 'shaderSource') {
          return (s, src) => {
            shaderSrc.set(s.id, src);
            ops.push(['shaderSource', s.id, src]);
          };
        }
        if (name === 'compileShader') {
          return (s) => { ops.push(['compileShader', s.id]); };
        }
        if (name === 'getShaderParameter') {
          return (s, pname) => {
            ops.push(['getShaderParameter', s.id, pname]);
            if (failNextLink && failNextLink.failFs && s.type === 0x8b30) return false;
            return true;
          };
        }
        if (name === 'getShaderInfoLog') {
          return (s) => `shader-log-${s.id}`;
        }
        if (name === 'deleteShader') {
          return (s) => {
            if (s) deletedShaders.add(s.id);
            ops.push(['deleteShader', s?.id]);
          };
        }
        if (name === 'createProgram') {
          return () => {
            const p = { id: nextId++ };
            createdProgs.add(p.id);
            progShaders.set(p.id, []);
            ops.push(['createProgram', p.id]);
            return p;
          };
        }
        if (name === 'attachShader') {
          return (p, s) => {
            progShaders.get(p.id)?.push(s);
            ops.push(['attachShader', p.id, s.id]);
          };
        }
        if (name === 'linkProgram') {
          return (p) => { ops.push(['linkProgram', p.id]); };
        }
        if (name === 'getProgramParameter') {
          return (p, pname) => {
            ops.push(['getProgramParameter', p.id, pname]);
            if (lost) return false;
            if (failNextLink && failNextLink.shouldFail(p, progShaders.get(p.id) || [], shaderSrc)) return false;
            return true;
          };
        }
        if (name === 'getProgramInfoLog') return (p) => `prog-log-${p.id}`;
        if (name === 'deleteProgram') {
          return (p) => {
            if (p) deletedProgs.add(p.id);
            ops.push(['deleteProgram', p?.id]);
          };
        }
        if (name === 'getUniformLocation') return (p, u) => ({ p: p.id, u });
        if (name === 'useProgram') return (p) => { ops.push(['useProgram', p?.id ?? null]); };
        return () => ({});
      },
    });
    return {
      gl, ops, shaderSrc, progShaders, createdProgs, createdShaders, createdVs, deletedProgs, deletedShaders,
      setLost(v) { lost = v; },
    };
  }

  const mainGl = makeGl();
  const canvas = {
    ...element(),
    width: 400,
    height: 300,
    getContext: () => mainGl.gl,
    getBoundingClientRect: () => ({ width: 200, height: 150, left: 0, top: 0 }),
  };
  const ime = element();
  const document = {
    ...element(),
    title: '',
    body: element(),
    documentElement: element(),
    createElement: () => ({ ...element(), getContext: () => ({ measureText: () => ({ width: 8 }) }) }),
    getElementById: (id) => (id === 'c' ? canvas : ime),
    querySelector: () => null,
  };

  const popups = [];
  const mainRafs = [];
  const win = {
    ...element(),
    document,
    navigator: { platform: 'MacIntel', webdriver },
    location: { search, pathname: '/', hash: '', href: 'https://example.test/' },
    history: { pushState() {}, replaceState() {}, back() {} },
    URLSearchParams,
    URL,
    Intl,
    Float32Array,
    Uint32Array,
    Uint8Array,
    queueMicrotask,
    devicePixelRatio: 2,
    performance: { now: () => 0 },
    requestAnimationFrame(cb) { mainRafs.push(cb); return mainRafs.length; },
    cancelAnimationFrame() {},
    setTimeout() { return 1; },
    getComputedStyle: () => ({ paddingTop: '0px', paddingRight: '0px', paddingBottom: '0px', paddingLeft: '0px' }),
    open() {
      const pgl = makeGl();
      const pcanvas = {
        ...element(),
        width: 200,
        height: 200,
        getContext: () => pgl.gl,
        getBoundingClientRect: () => ({ width: 200, height: 200, left: 0, top: 0 }),
      };
      const pdoc = {
        ...element(),
        title: '',
        body: element(),
        head: element(),
        documentElement: element(),
        createElement: (tag) => (tag === 'canvas' ? pcanvas : element()),
        open() {},
        write() {},
        close() {},
      };
      const rafs = [];
      const pwin = {
        ...element(),
        document: pdoc,
        devicePixelRatio: 1,
        innerWidth: 200,
        innerHeight: 200,
        screenX: 0,
        screenY: 0,
        closed: false,
        getComputedStyle: () => ({ paddingTop: '0px', paddingRight: '0px', paddingBottom: '0px', paddingLeft: '0px' }),
        requestAnimationFrame(cb) { rafs.push(cb); return rafs.length; },
        cancelAnimationFrame() {},
        close() { this.closed = true; },
        focus() {},
      };
      popups.push({ win: pwin, canvas: pcanvas, gl: pgl, rafs });
      return pwin;
    },
  };
  win.window = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  const H = win.__mbhost;
  H.run('test', () => { if (onFrame) onFrame(H); }, () => {}, () => {}, () => {}, () => {});
  return { H, win, canvas, gl: mainGl, popups, mainRafs };
}

const INST = 60;
function makeInst(kind, padW = 0, tex = 0) {
  const buf = new Float32Array(INST);
  buf[0] = 10; buf[1] = 10; buf[2] = 60; buf[3] = 40;
  buf[4] = 8;
  buf[5] = kind;
  buf[8] = 0.5; buf[9] = 0.5; buf[10] = 0.5; buf[11] = 0.8;
  buf[16] = -1e9; buf[17] = -1e9; buf[18] = 1e9; buf[19] = 1e9;
  buf[20] = tex;
  buf[23] = padW;
  return buf;
}

const flushMicrotasks = () => new Promise((r) => setImmediate(r));

test('setupGL batches compiles and links with zero getShaderParameter stalls and defers auxiliary LINK_STATUS', () => {
  const b = makeBrowser({ parallel: true });
  const ops = b.gl.ops;
  assert.equal(
    ops.filter((op) => op[0] === 'getShaderParameter').length,
    0,
    'happy-path setupGL must never stall on getShaderParameter(COMPILE_STATUS)',
  );
  const links = ops.map((op, i) => [op[0], i]).filter(([k]) => k === 'linkProgram').map(([, i]) => i);
  const checks = ops.map((op, i) => [op[0], i]).filter(([k]) => k === 'getProgramParameter').map(([, i]) => i);
  assert.equal(links.length, 4, 'setupGL submits 4 links in one batch (ui, flat, post, adaptive)');
  assert.equal(checks.length, 1, 'setupGL only queries LINK_STATUS for MB_PROG_UI, deferring flat/post/adaptive');
  assert.ok(checks[0] > links.at(-1), 'all 4 linkProgram calls are submitted before the first getProgramParameter');
  assert.equal(b.gl.createdVs.size, 3, 'setupGL creates 3 shared vertex shaders (vs, vsAd, pvs)');
  for (const id of b.gl.createdVs) {
    assert.ok(!b.gl.deletedShaders.has(id), 'shared vertex shaders must not be deleted by finishLink');
  }
});

test('first present prewarms all 7 lazy programs + veil in heavy-first order and draws adopt them without relinking', async () => {
  const b = makeBrowser({ parallel: true });
  const beforePrewarmLinks = b.gl.ops.filter((op) => op[0] === 'linkProgram').length;
  // Frame 0: plain UI rect only -> schedules microtask prewarm after present finishes.
  b.H.present(makeInst(0, 0, 0), 1, 1, 1, 1);
  assert.equal(
    b.gl.ops.filter((op) => op[0] === 'linkProgram').length,
    beforePrewarmLinks,
    'prewarm does not run inside frame 0 present/host',
  );
  await flushMicrotasks();

  const prewarmOps = b.gl.ops.slice(b.gl.ops.findIndex((op) => op[0] === 'useProgram'));
  assert.equal(
    b.gl.ops.filter((op) => op[0] === 'getShaderParameter').length,
    0,
    'prewarm never calls getShaderParameter',
  );
  const prewarmChecks = prewarmOps.filter((op) => op[0] === 'getProgramParameter');
  assert.equal(prewarmChecks.length, 0, 'prewarm never blocks on getProgramParameter');

  const fsSources = [];
  for (const [k, id, src] of b.gl.ops) {
    if (k === 'shaderSource' && typeof src === 'string' && src.includes('#define ONE_KIND')) {
      fsSources.push(src);
    }
  }
  // Expected order after startup MB_PROG_UI (ONE_KIND -1):
  // LIQUID_MERGED (6), LIQUID_SINGLE (13), UI_AD (-2), FROSTED (5), PATH_AD (11), PATH (11), LENS (8)
  const oneKinds = fsSources.map((s) => Number(s.match(/#define ONE_KIND (-?\d+)/)[1]));
  assert.deepEqual(oneKinds, [-1, 6, 13, -2, 5, 11, 11, 8], 'heavy glass programs prewarm first');

  const mergedFs = fsSources[1];
  const singleFs = fsSources[2];
  assert.match(mergedFs, /#define MB_HAS_DROPLET 0\b/, 'MB_PROG_LIQUID_MERGED disables droplet code');
  assert.match(singleFs, /#define MB_HAS_DROPLET 1\b/, 'MB_PROG_LIQUID_SINGLE keeps droplet code');
  assert.match(mergedFs, /#if MB_HAS_LIQUID && MB_HAS_DROPLET\s+float mb_snell_intersect/, 'droplet Snell helpers are guarded');

  // Now draw a merged liquid glass frame: must adopt prewarmed MB_PROG_LIQUID_MERGED + post + adaptive with 0 new links.
  const linksAfterPrewarm = b.gl.ops.filter((op) => op[0] === 'linkProgram').length;
  assert.equal(linksAfterPrewarm, 4 + 7 + 1, '4 startup + 7 lazy MB_PROG_* + 1 veil = 12 total programs');

  const merged = new Float32Array(2 * INST);
  merged.set(makeInst(0, 0, 0), 0);
  merged.set(makeInst(6, 12, -1), INST);
  merged[INST + 14] = -1; // adaptive
  b.H.present(merged, 2, 1, 1, 1);

  assert.equal(
    b.gl.ops.filter((op) => op[0] === 'linkProgram').length,
    linksAfterPrewarm,
    'drawing merged liquid glass adopts pending programs without creating or relinking any program',
  );
  assert.equal(
    b.gl.ops.filter((op) => op[0] === 'useProgram' && op[1] === null).length,
    0,
    'drawing merged liquid + blur + adaptive must finalize post/adProg before useProgram (never useProgram(null))',
  );
  for (const id of b.gl.createdVs) {
    assert.ok(!b.gl.deletedShaders.has(id), 'shared vertex shaders remain alive after finalizing programs');
  }
});

test('prewarm is disabled without KHR_parallel_shader_compile, under webdriver, or with shot_at', async () => {
  for (const opts of [
    { parallel: false, webdriver: false, search: '' },
    { parallel: true, webdriver: true, search: '' },
    { parallel: true, webdriver: false, search: '?shot_at=100' },
  ]) {
    const b = makeBrowser(opts);
    const links0 = b.gl.ops.filter((op) => op[0] === 'linkProgram').length;
    b.H.present(makeInst(0, 0, 0), 1, 1, 1, 1);
    await flushMicrotasks();
    assert.equal(
      b.gl.ops.filter((op) => op[0] === 'linkProgram').length,
      links0,
      `no background prewarm for ${JSON.stringify(opts)}`,
    );
  }
});

test('webglcontextlost cancels queued prewarm and context restoration re-enables fresh prewarm', async () => {
  const b = makeBrowser({ parallel: true });
  const links0 = b.gl.ops.filter((op) => op[0] === 'linkProgram').length;
  b.H.present(makeInst(0, 0, 0), 1, 1, 1, 1);
  // Context is lost BEFORE microtask executes.
  b.gl.setLost(true);
  b.canvas.dispatch('webglcontextlost', { preventDefault() {} });
  await flushMicrotasks();
  assert.equal(
    b.gl.ops.filter((op) => op[0] === 'linkProgram').length,
    links0,
    'cancelled microtask must not link on a lost context',
  );
  // Restore context and render again: prewarm should run for the new generation.
  b.gl.setLost(false);
  b.canvas.dispatch('webglcontextrestored', {});
  const linksAfterRestore = b.gl.ops.filter((op) => op[0] === 'linkProgram').length;
  b.H.present(makeInst(0, 0, 0), 1, 1, 1, 1);
  // Queue prewarm on gen N, then restore immediately (isContextLost stays false) before microtask flushes:
  // glGen mismatch alone must cancel the stale microtask from the old generation.
  b.canvas.dispatch('webglcontextlost', { preventDefault() {} });
  b.canvas.dispatch('webglcontextrestored', {});
  const linksAfterFastRestore = b.gl.ops.filter((op) => op[0] === 'linkProgram').length;
  await flushMicrotasks();
  assert.equal(
    b.gl.ops.filter((op) => op[0] === 'linkProgram').length,
    linksAfterFastRestore,
    'stale prewarm microtask is blocked by glGen mismatch even when isContextLost() is false',
  );
  assert.ok(linksAfterFastRestore > linksAfterRestore, 'fast restore ran fresh setupGL');

  b.H.present(makeInst(0, 0, 0), 1, 1, 1, 1);
  await flushMicrotasks();
  assert.equal(
    b.gl.ops.filter((op) => op[0] === 'linkProgram').length,
    linksAfterFastRestore + 8,
    'restored context prewarms 7 lazy programs + veil',
  );
});

test('link failure surfaces program and shader logs and deletes shader handles; lost context does not throw', () => {
  const b = makeBrowser({
    parallel: false,
    failNextLink: {
      failFs: true,
      shouldFail(_p, shaders, srcs) {
        return shaders.some((s) => (srcs.get(s.id) || '').includes('ONE_KIND 5'));
      },
    },
  });
  const frosted = new Float32Array(2 * INST);
  frosted.set(makeInst(0, 0, 0), 0);
  frosted.set(makeInst(5, 0, -1), INST);
  assert.throws(
    () => b.H.present(frosted, 2, 1, 1, 1),
    /prog:4:.*prog-log-.*shader-log-/s,
    'link failure includes program and fragment shader info logs',
  );
  // Every fragment shader attached to a finalized program was deleted, while shared VS stay intact.
  const deleted = b.gl.deletedShaders.size;
  assert.ok(deleted >= 2, 'fragment shader handles are deleted even on link failure');
  for (const id of b.gl.createdVs) {
    assert.ok(!b.gl.deletedShaders.has(id), 'link failure must not delete shared vertex shaders');
  }

  // If context is lost mid-draw, getProgramParameter returning false must not throw.
  const b2 = makeBrowser({ parallel: false });
  b2.gl.setLost(true);
  assert.doesNotThrow(() => b2.H.present(frosted, 2, 1, 1, 1));
});

test('closing a secondary window deletes all pending prewarmed programs and shaders', async () => {
  const b = makeBrowser({
    parallel: true,
    onFrame(H) {
      if (H.windows(4, 0, '') === 1) H.present(makeInst(0, 0, 0), 1, 1, 1, 1);
    },
  });
  await flushMicrotasks();
  const wid = b.H.windows(1, 0, JSON.stringify({ title: 'aux', w: 200, h: 200 }));
  assert.equal(wid, 1);
  assert.equal(b.popups.length, 1);
  const popup = b.popups[0];
  const pgl = popup.gl;
  assert.equal(pgl.createdProgs.size, 4, 'popup setupGL creates 4 startup programs');

  // Drive one frame in the popup window (via main/popup rAF) and flush microtasks so all 7 lazy MB_PROG_* + veil are pending.
  while (b.mainRafs.length || popup.rafs.length) {
    while (b.mainRafs.length) b.mainRafs.shift()(16);
    while (popup.rafs.length) popup.rafs.shift()(16);
  }
  await flushMicrotasks();
  assert.equal(pgl.createdProgs.size, 12, 'popup prewarmed all 7 lazy MB_PROG_* + veil (12 total programs)');

  // Closing the popup must delete EVERY created program (including pendingProgs + veil.pending + pending aux)
  // and EVERY created shader (including shared vs/vsAd/pvs + all pending fragment shaders).
  b.H.windows(3, wid, '');
  await flushMicrotasks();
  for (const pid of pgl.createdProgs) {
    assert.ok(pgl.deletedProgs.has(pid), `popup program ${pid} was not deleted on close`);
  }
  for (const sid of pgl.createdShaders) {
    assert.ok(pgl.deletedShaders.has(sid), `popup shader ${sid} was not deleted on close`);
  }
});
