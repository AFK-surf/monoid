// Production WebGL2 shader (web/host.js) P0 Regular Liquid Glass V1..V9 numerical vector readback test
// in headless Chrome/Chromium on SwiftShader (zero npm dependencies via Node built-in WebSocket + CDP;
// falls back to Playwright if installed and WebSocket is unavailable):
//   node scripts/web_glass_test.mjs
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);

function findChromeBinary() {
  const envBins = [process.env.CHROME_BIN, process.env.CHROMIUM_EXECUTABLE_PATH].filter(Boolean);
  const stdBins = [
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ];
  for (const p of [...envBins, ...stdBins]) {
    if (fs.existsSync(p)) return p;
  }
  const pwCache = path.join(os.homedir(), '.cache', 'ms-playwright');
  if (fs.existsSync(pwCache)) {
    const dirs = fs.readdirSync(pwCache).filter((d) => d.startsWith('chromium-')).sort().reverse();
    for (const d of dirs) {
      const cands = [
        path.join(pwCache, d, 'chrome-linux', 'chrome'),
        path.join(pwCache, d, 'chrome-linux64', 'chrome'),
        path.join(pwCache, d, 'chrome-mac', 'Chromium.app', 'Contents', 'MacOS', 'Chromium'),
        path.join(pwCache, d, 'chrome-mac-arm64', 'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing'),
      ];
      for (const c of cands) {
        if (fs.existsSync(c)) return c;
      }
    }
  }
  return null;
}

function tryLoadPlaywright() {
  const candidates = [
    process.env.PLAYWRIGHT_MODULE,
    path.resolve('out/node/node_modules/playwright'),
    path.resolve('out/node/node_modules/playwright-core'),
    'playwright',
    'playwright-core',
  ].filter(Boolean);
  for (const c of candidates) {
    try {
      return require(c);
    } catch {}
  }
  return null;
}

function runGlassVectorsInPage() {
  const H = globalThis.__mbhost;
  const INST = 60;
  const W = 100, Hh = 80, S = 2;
  H.renderInit(W, Hh, S);

  const cases = [
    { name: 'dark_black', bg: [0, 0, 0], tint: [32 / 255, 32 / 255, 32 / 255, 0x67 / 255], isClear: false, adaptive: false },
    { name: 'dark_1b1c1f', bg: [27 / 255, 28 / 255, 31 / 255], tint: [32 / 255, 32 / 255, 32 / 255, 0x67 / 255], isClear: false, adaptive: false },
    { name: 'dark_ad_white', bg: [1, 1, 1], tint: [32 / 255, 32 / 255, 32 / 255, 0x67 / 255], isClear: false, adaptive: true },
    { name: 'light_blue', bg: [0, 136 / 255, 1], tint: [253 / 255, 252 / 255, 253 / 255, 0x67 / 255], isClear: false, adaptive: false },
    { name: 'pure_clear', bg: [0, 1, 64 / 255], tint: [1, 1, 1, 0], isClear: true, adaptive: false },
    { name: 'light_d9_blue', bg: [0, 0.4, 1], tint: [253 / 255, 252 / 255, 253 / 255, 0xD9 / 255], isClear: false, adaptive: false },
    { name: 'light_ff_blue', bg: [0, 0.4, 1], tint: [253 / 255, 252 / 255, 253 / 255, 1.0], isClear: false, adaptive: false },
  ];

  function rect(buf, off, x, y, w, h, kind, r, g, b, a, grp) {
    buf.fill(0, off, off + INST);
    buf[off + 0] = x; buf[off + 1] = y; buf[off + 2] = w; buf[off + 3] = h;
    buf[off + 5] = kind;
    buf[off + 8] = r; buf[off + 9] = g; buf[off + 10] = b; buf[off + 11] = a;
    buf[off + 16] = -1e9; buf[off + 17] = -1e9; buf[off + 18] = 1e9; buf[off + 19] = 1e9;
    buf[off + 20] = grp;
  }

  const out = [];
  for (let i = 0; i < cases.length; i++) {
    const c = cases[i];
    const buf = new Float32Array(2 * INST);
    rect(buf, 0, 0, 0, W, Hh, 0, c.bg[0], c.bg[1], c.bg[2], 1, 0);
    rect(buf, INST, 10, 10, 80, 60, 6, c.tint[0], c.tint[1], c.tint[2], c.tint[3], -40 - i);
    buf[INST + 4] = 12;
    buf[INST + 6] = 1;
    buf[INST + 7] = c.isClear ? 0 : 1;
    buf[INST + 12] = 0;
    buf[INST + 13] = 4;
    buf[INST + 14] = c.adaptive ? -1 : 0;
    buf[INST + 15] = 1;
    H.present(buf, 2, c.bg[0], c.bg[1], c.bg[2]);
    const shot = H.renderPixels();
    // sample centre (50, 40) -> (100, 80) at 2x
    const idx = (80 * shot.w + 100) * 4;
    out.push({ name: c.name, r: shot.px[idx], g: shot.px[idx + 1], b: shot.px[idx + 2] });
  }

  // --- Commit 2 V8/V9 2D Multi-Pixel ROI Gates @ 3x & 2x ---
  const VW = 160, VH = 80;
  H.renderInit(VW, VH, 3);
  const pxAt = (shot, x, y) => {
    const i = (y * shot.w + x) * 4;
    return [shot.px[i], shot.px[i + 1], shot.px[i + 2]];
  };
  const lumaOf = (c) => 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];

  const roi = {};
  for (const isLight of [false, true]) {
    const bg = isLight ? 1.0 : 28 / 255, bgB = isLight ? 1.0 : 30 / 255;
    const buf = new Float32Array(4 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, bg, bg, bgB, 1, 0);
    rect(buf, INST, 10, 37, 70, 6, 0, 0, 136 / 255, 1, 1, 0);
    rect(buf, 2 * INST, 80, 37, 70, 6, 0, 120 / 255, 120 / 255, 128 / 255, 1, 0);
    rect(buf, 3 * INST, 51, 21, 58, 38, 6, 1, 1, 1, 0, isLight ? -51 : -50);
    buf[3 * INST + 4] = 19; buf[3 * INST + 6] = 1; buf[3 * INST + 7] = -16;
    buf[3 * INST + 12] = 1; buf[3 * INST + 13] = 8; buf[3 * INST + 15] = 1; buf[3 * INST + 21] = 3;
    H.present(buf, 4, bg, bg, bgB);
    const shot = H.renderPixels();
    let maxBh = 0, peakDx = 0, h55 = 0;
    let maxGh = 0, greyPeakDx = 0, greyH55 = 0;
    for (let i = 0; i <= 18; i++) {
      const xL = 51 * 3 + i;
      let cnt = 0;
      for (let ypx = 21 * 3; ypx < 59 * 3; ypx++) {
        const c = pxAt(shot, xL, ypx);
        if (c[2] - c[0] > 100) cnt++;
      }
      const hpt = cnt / 3, dxL = (i + 0.5) / 3;
      if (hpt > maxBh) { maxBh = hpt; peakDx = dxL; }
      if (i === 16) h55 = hpt;
    }
    const refY = lumaOf(pxAt(shot, 80 * 3, 25 * 3));
    for (let i = 0; i <= 18; i++) {
      const xR = 109 * 3 - 1 - i;
      let cnt = 0;
      for (let ypx = 33 * 3; ypx < 47 * 3; ypx++) {
        const cy = lumaOf(pxAt(shot, xR, ypx));
        if (isLight ? (cy < refY - 80) : (cy > refY + 25)) cnt++;
      }
      const hpt = cnt / 3, dxR = (i + 0.5) / 3;
      if (hpt > maxGh) { maxGh = hpt; greyPeakDx = dxR; }
      if (i === 16) greyH55 = hpt;
    }
    const cL = pxAt(shot, Math.floor(79.3 * 3), 40 * 3);
    const cR = pxAt(shot, Math.floor(80.7 * 3), 40 * 3);
    const cTop = pxAt(shot, 60 * 3, 25 * 3);
    const cBot = pxAt(shot, 60 * 3, 55 * 3);
    const y0 = lumaOf(pxAt(shot, 80 * 3, 21 * 3));
    const y1 = lumaOf(pxAt(shot, 80 * 3, 21 * 3 + 2));
    const y2 = lumaOf(pxAt(shot, 80 * 3, 23 * 3));
    const y9 = lumaOf(pxAt(shot, 80 * 3, 30 * 3));
    const y24 = lumaOf(pxAt(shot, 80 * 3, 45 * 3));
    roi[isLight ? 'v8_light' : 'v8_dark'] = {
      maxBh, peakDx, h55, maxGh, greyPeakDx, greyH55,
      cL_br: cL[2] - cL[0], cR_br: cR[2] - cR[0],
      cTop_br: cTop[2] - cTop[0], cBot_br: cBot[2] - cBot[0],
      y0, y1, y2, y9, y24,
    };
  }
  // V8a2: Horizontal-stripe vertical monotonicity (zero folding)
  {
    const buf = new Float32Array(42 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 0, 0, 0, 1, 0);
    for (let i = 0; i < 40; i++) {
      const v = Math.min(1, Math.max(0, (i - 12) / 16));
      rect(buf, (i + 1) * INST, 0, 20 + i, VW, 1, 0, 1 - v, 0, v, 1, 0);
    }
    rect(buf, 41 * INST, 51, 21, 58, 38, 6, 1, 1, 1, 0, -52);
    buf[41 * INST + 4] = 19; buf[41 * INST + 6] = 1; buf[41 * INST + 7] = -16;
    buf[41 * INST + 12] = 1; buf[41 * INST + 13] = 8; buf[41 * INST + 15] = 1; buf[41 * INST + 21] = 3;
    H.present(buf, 42, 0, 0, 0);
    const shot = H.renderPixels();
    const xpx = Math.floor(51.85 * 3);
    let prev = -1000, monoOk = true;
    for (let ypx = 36 * 3; ypx <= 44 * 3; ypx++) {
      const c = pxAt(shot, xpx, ypx);
      const cur = c[2] - c[0];
      if (prev > -999 && cur < prev - 6) monoOk = false;
      prev = cur;
    }
    roi.v8_mono_ok = monoOk;
  }
  // V8b: 124x48pt dropRole=0 magnifier + Role 0 real zoom (1.18) contact-edge push
  {
    const buf = new Float32Array(3 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
    rect(buf, INST, 0, 37, VW, 6, 0, 0, 136 / 255, 1, 1, 0);
    rect(buf, 2 * INST, 18, 16, 124, 48, 6, 1, 1, 1, 0, -53);
    buf[2 * INST + 4] = 24; buf[2 * INST + 6] = 1; buf[2 * INST + 7] = 0;
    buf[2 * INST + 12] = 1; buf[2 * INST + 13] = 8; buf[2 * INST + 15] = 1; buf[2 * INST + 21] = 3;
    H.present(buf, 3, 28 / 255, 28 / 255, 30 / 255);
    const shot = H.renderPixels();
    let cnt = 0;
    for (let ypx = 16 * 3; ypx < 64 * 3; ypx++) {
      const c = pxAt(shot, 19 * 3, ypx);
      if (c[2] - c[0] > 100) cnt++;
    }
    roi.v8_mag_h = cnt / 3;
  }
  {
    const buf = new Float32Array(3 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 1, 0, 0, 1, 0);
    rect(buf, INST, 0, 0, 55.2, VH, 0, 0, 1, 0, 1, 0);
    rect(buf, 2 * INST, 51, 21, 58, 38, 6, 1, 1, 1, 0, -59);
    buf[2 * INST + 4] = 19; buf[2 * INST + 6] = 1; buf[2 * INST + 7] = -0.18;
    buf[2 * INST + 12] = 1; buf[2 * INST + 13] = 8; buf[2 * INST + 15] = 1; buf[2 * INST + 21] = 8;
    H.present(buf, 3, 1, 0, 0);
    const shot = H.renderPixels();
    const e = pxAt(shot, 51 * 3, 40 * 3);
    roi.v8_zoom118_gr = e[1] - e[0];
  }
  // V9a: Switch ON @ 3x
  {
    const buf = new Float32Array(3 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
    rect(buf, INST, 40, 26, 63, 28, 0, 48 / 255, 209 / 255, 88 / 255, 1, 0);
    buf[INST + 4] = 14;
    rect(buf, 2 * INST, 52.9, 21.0, 59.2, 38.4, 6, 1, 1, 1, 0, -54);
    buf[2 * INST + 4] = 19.2; buf[2 * INST + 6] = 1; buf[2 * INST + 7] = -32;
    buf[2 * INST + 12] = 1; buf[2 * INST + 13] = 9; buf[2 * INST + 15] = 1; buf[2 * INST + 21] = 9;
    H.present(buf, 3, 28 / 255, 28 / 255, 30 / 255);
    const shot = H.renderPixels();
    const r0 = pxAt(shot, 80 * 3, 21 * 3 + 0);
    const r1 = pxAt(shot, 80 * 3, 21 * 3 + 1);
    const r2 = pxAt(shot, 80 * 3, 21 * 3 + 2);
    let core = 0, firstCoreY = -1;
    for (let ypx = 21 * 3 + 2; ypx < 59 * 3; ypx++) {
      const c = pxAt(shot, 80 * 3, ypx);
      if (c[1] - c[0] > 60) {
        if (firstCoreY < 0) firstCoreY = ypx;
        core++;
      }
    }
    const moatTop = firstCoreY >= 0 ? (firstCoreY - (21 * 3 + 2)) / 3 : 0;
    const tip = pxAt(shot, Math.floor(111.5 * 3), 40 * 3);
    roi.v9_sw = { gr0: r0[1] - r0[0], gr1: r1[1] - r1[0], gr2: r2[1] - r2[0], core: core / 3, moatTop, tipGr: tip[1] - tip[0] };
  }
  // V9b: Switch OFF @ 3x + right-cap inward horizontal profile
  {
    const buf = new Float32Array(4 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
    rect(buf, INST, 40, 26, 63, 28, 0, 120 / 255, 120 / 255, 128 / 255, 1, 0);
    buf[INST + 4] = 14;
    rect(buf, 2 * INST, 85, 26, 2, 28, 0, 0, 136 / 255, 1, 1, 0);
    rect(buf, 3 * INST, 30.9, 21.0, 59.2, 38.4, 6, 1, 1, 1, 0, -55);
    buf[3 * INST + 4] = 19.2; buf[3 * INST + 6] = 1; buf[3 * INST + 7] = -32;
    buf[3 * INST + 12] = 1; buf[3 * INST + 13] = 9; buf[3 * INST + 15] = 1; buf[3 * INST + 21] = 9;
    H.present(buf, 4, 28 / 255, 28 / 255, 30 / 255);
    const shot = H.renderPixels();
    const coreC = pxAt(shot, 60 * 3, 40 * 3);
    const moatC = pxAt(shot, 60 * 3, 25 * 3);
    const h0 = pxAt(shot, 60 * 3, 21 * 3);
    const rm = pxAt(shot, 60 * 3, 21 * 3 + 2);
    const rcap = pxAt(shot, Math.floor(88.6 * 3), 40 * 3);
    const rtir = pxAt(shot, Math.floor(89.3 * 3), 40 * 3);
    roi.v9_sw_off = { coreR: coreC[0], moatR: moatC[0], h0R: h0[0], rmR: rm[0], rcapBR: rcap[2] - rcap[0], rtirBR: rtir[2] - rtir[0] };
  }
  // V9b2: Switch half-press p = 0.5 / 0.6 / 1.0
  {
    const redRows = [];
    for (let pi = 0; pi < 3; pi++) {
      const p = [0.5, 0.6, 1.0][pi];
      const buf = new Float32Array(3 * INST);
      rect(buf, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
      rect(buf, INST, 40, 20, 80, 7, 0, 1, 0, 0, 1, 0);
      rect(buf, 2 * INST, 52.9, 21.0, 59.2, 38.4, 6, 1, 1, 1, 0, -60 - pi);
      buf[2 * INST + 4] = 19.2; buf[2 * INST + 6] = 1; buf[2 * INST + 7] = -32;
      buf[2 * INST + 12] = p; buf[2 * INST + 13] = 9 * p; buf[2 * INST + 15] = 1; buf[2 * INST + 21] = 9 * p;
      H.present(buf, 3, 28 / 255, 28 / 255, 30 / 255);
      const shot = H.renderPixels();
      let cnt = 0;
      for (let ypx = 27 * 3; ypx < 38 * 3; ypx++) {
        const c = pxAt(shot, 80 * 3, ypx);
        if (c[0] - c[2] > 80) cnt++;
      }
      redRows.push(cnt);
    }
    roi.v9_half_press = redRows;
  }
  // V9c: Light Segmented Prism @ 3x
  {
    const buf = new Float32Array(2 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 1, 1, 1, 1, 0);
    rect(buf, INST, 25, 17.5, 110, 45, 6, 1, 1, 1, 0, -56);
    buf[INST + 4] = 22.5; buf[INST + 6] = 1; buf[INST + 7] = -48;
    buf[INST + 12] = 1; buf[INST + 13] = 9; buf[INST + 15] = 1; buf[INST + 21] = 9; buf[INST + 22] = 0.04;
    H.present(buf, 2, 1, 1, 1);
    const shot = H.renderPixels();
    const bot = pxAt(shot, 80 * 3, Math.floor(61.6 * 3));
    const lft = pxAt(shot, Math.floor(25.9 * 3), 40 * 3);
    roi.v9_seg = { botBR: bot[2] - bot[0], lftRB: lft[0] - lft[2] };
  }
  // V9a2: Switch ON @ 2x phase-shifted integrated green mass
  H.renderInit(VW, VH, 2);
  {
    const masses = [];
    for (let ph = 0; ph < 2; ph++) {
      const yoff = ph * 0.25;
      const buf = new Float32Array(3 * INST);
      rect(buf, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
      rect(buf, INST, 40, 26 + yoff, 63, 28, 0, 48 / 255, 209 / 255, 88 / 255, 1, 0);
      buf[INST + 4] = 14;
      rect(buf, 2 * INST, 52.9, 21.0 + yoff, 59.2, 38.4, 6, 1, 1, 1, 0, -57 - ph);
      buf[2 * INST + 4] = 19.2; buf[2 * INST + 6] = 1; buf[2 * INST + 7] = -32;
      buf[2 * INST + 12] = 1; buf[2 * INST + 13] = 9; buf[2 * INST + 15] = 1; buf[2 * INST + 21] = 9;
      H.present(buf, 3, 28 / 255, 28 / 255, 30 / 255);
      const shot = H.renderPixels();
      let gsum = 0;
      for (let dy = 0; dy < 3; dy++) {
        const c = pxAt(shot, 80 * 2, 21 * 2 + dy);
        const d = c[1] - c[0];
        if (d > 0) gsum += d;
      }
      masses.push(gsum);
    }
    roi.v9_sw_2x = masses;
  }
  return { gl: H.renderInfo(), out, roi };
}

async function runWithCdp(chromeBin, url) {
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mbui-web-glass-'));
  const args = [
    '--headless=new',
    '--no-sandbox',
    '--disable-gpu-sandbox',
    '--use-gl=angle',
    '--use-angle=swiftshader',
    '--enable-unsafe-swiftshader',
    '--remote-debugging-port=0',
    `--user-data-dir=${userDataDir}`,
    'about:blank',
  ];
  const proc = spawn(chromeBin, args, { stdio: ['ignore', 'ignore', 'pipe'] });
  const errors = [];
  let stderrBuf = '';
  let ws;
  try {
    const wsUrl = await new Promise((resolve, reject) => {
      proc.on('error', reject);
      proc.on('exit', (code) => reject(new Error(`Chrome exited early (${code}); stderr:\n${stderrBuf}`)));
      proc.stderr.on('data', (chunk) => {
        stderrBuf += chunk.toString('utf8');
        const m = stderrBuf.match(/DevTools listening on (ws:\/\/[^\s]+)/);
        if (m) resolve(m[1]);
      });
    });

    ws = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      ws.addEventListener('open', resolve, { once: true });
      ws.addEventListener('error', (e) => reject(new Error(`CDP WebSocket error: ${e.message || e}`)), { once: true });
    });

    let nextId = 1;
    const pending = new Map();
    const eventWaiters = [];
    ws.addEventListener('close', () => {
      for (const { reject } of pending.values()) reject(new Error('CDP WebSocket closed unexpectedly'));
      pending.clear();
      while (eventWaiters.length) eventWaiters.pop().reject(new Error('CDP WebSocket closed unexpectedly'));
    });
    ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : Buffer.from(ev.data).toString('utf8'));
      if (msg.id && pending.has(msg.id)) {
        const { resolve, reject } = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) reject(new Error(`CDP ${msg.error.code}: ${msg.error.message}`));
        else resolve(msg.result);
        return;
      }
      if (msg.method === 'Runtime.exceptionThrown') {
        const d = msg.params?.exceptionDetails;
        errors.push(d?.exception?.description || d?.text || JSON.stringify(d));
      }
      for (let i = eventWaiters.length - 1; i >= 0; i--) {
        if (eventWaiters[i].match(msg)) {
          const w = eventWaiters.splice(i, 1)[0];
          w.resolve(msg);
        }
      }
    });

    const cdp = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      const payload = sessionId ? { id, method, params, sessionId } : { id, method, params };
      ws.send(JSON.stringify(payload));
    });
    const waitEvent = (method, sessionId) => new Promise((resolve, reject) => {
      eventWaiters.push({
        match: (m) => m.method === method && (!sessionId || m.sessionId === sessionId),
        resolve,
        reject,
      });
    });

    const { targetId } = await cdp('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await cdp('Target.attachToTarget', { targetId, flatten: true });
    await cdp('Page.enable', {}, sessionId);
    await cdp('Runtime.enable', {}, sessionId);
    await cdp('Emulation.setDeviceMetricsOverride', { width: 256, height: 256, deviceScaleFactor: 1, mobile: false }, sessionId);

    const loaded = waitEvent('Page.loadEventFired', sessionId);
    await cdp('Page.navigate', { url }, sessionId);
    await loaded;

    const evalRes = await cdp('Runtime.evaluate', {
      expression: `(${runGlassVectorsInPage.toString()})()`,
      returnByValue: true,
      awaitPromise: true,
    }, sessionId);
    if (evalRes.exceptionDetails) {
      errors.push(evalRes.exceptionDetails.exception?.description || evalRes.exceptionDetails.text || 'evaluate exception');
    }
    return { results: evalRes.result?.value, errors };
  } finally {
    try { ws?.close(); } catch {}
    try { proc.kill('SIGKILL'); } catch {}
    try { fs.rmSync(userDataDir, { recursive: true, force: true }); } catch {}
  }
}

async function runWithPlaywright(pw, url) {
  const launchOpts = { args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] };
  const bin = process.env.CHROMIUM_EXECUTABLE_PATH || process.env.CHROME_BIN;
  if (bin) launchOpts.executablePath = bin;
  const browser = await pw.chromium.launch(launchOpts);
  const errors = [];
  try {
    const page = await (await browser.newContext({ viewport: { width: 256, height: 256 }, deviceScaleFactor: 1 })).newPage();
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto(url);
    const results = await page.evaluate(runGlassVectorsInPage);
    return { results, errors };
  } finally {
    await browser.close();
  }
}

const webDir = path.resolve('web');
const server = http.createServer((req, res) => {
  const p = new URL(req.url, 'http://127.0.0.1').pathname;
  if (p === '/glass-test.html') {
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end('<!doctype html><meta charset="utf-8"><canvas id="c"></canvas><script src="/host.js"></script>');
    return;
  }
  const fp = path.join(webDir, path.basename(p));
  if (!fs.existsSync(fp) || !fs.statSync(fp).isFile()) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { 'content-type': fp.endsWith('.js') ? 'text/javascript' : 'text/html' });
  fs.createReadStream(fp).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const testUrl = `http://127.0.0.1:${server.address().port}/glass-test.html`;

let results, errors;
try {
  const chromeBin = findChromeBinary();
  if (chromeBin && typeof globalThis.WebSocket === 'function' && !process.env.PLAYWRIGHT_MODULE) {
    ({ results, errors } = await runWithCdp(chromeBin, testUrl));
  } else {
    const pw = tryLoadPlaywright();
    if (pw) {
      ({ results, errors } = await runWithPlaywright(pw, testUrl));
    } else if (chromeBin && typeof globalThis.WebSocket === 'function') {
      ({ results, errors } = await runWithCdp(chromeBin, testUrl));
    } else {
      throw new Error('web_glass_test: neither Chrome/Chromium (with Node WebSocket) nor Playwright found');
    }
  }
} finally {
  server.close();
}

if (errors.length) {
  console.error('web_glass_test page errors:', errors.join('\n'));
  process.exit(1);
}

console.log('web_glass_test gl:', results.gl);
let failed = 0;
function check(cond, msg) {
  if (!cond) {
    console.error('FAIL:', msg);
    failed = 1;
  }
}

for (const v of results.out) {
  console.log(`web_glass_test: ${v.name} -> rgb(${v.r}, ${v.g}, ${v.b})`);
  if (v.name === 'dark_black') {
    check(v.r >= 26 && v.r <= 34 && v.g >= 26 && v.g <= 34 && v.b >= 26 && v.b <= 34, `${v.name} out of (30,30,30)+/-4`);
  } else if (v.name === 'dark_1b1c1f') {
    check(v.r >= 41 && v.r <= 51 && v.g >= 42 && v.g <= 52 && v.b >= 45 && v.b <= 55, `${v.name} out of (46,47,50)+/-5`);
  } else if (v.name === 'dark_ad_white') {
    check(v.r >= 85 && v.r <= 101 && v.g >= 85 && v.g <= 101 && v.b >= 85 && v.b <= 101, `${v.name} out of (93,93,93)+/-8`);
  } else if (v.name === 'light_blue') {
    const mx = Math.max(v.r, v.g, v.b), mn = Math.min(v.r, v.g, v.b);
    const sat = mx > 0 ? (mx - mn) / mx : 0;
    check(Math.abs(v.r - 39) <= 12 && Math.abs(v.g - 154) <= 12 && v.b >= 243 && sat >= 0.80,
      `${v.name} rgb(${v.r},${v.g},${v.b}) sat=${sat.toFixed(3)}`);
  } else if (v.name === 'pure_clear') {
    check(v.r <= 8 && v.g >= 247 && v.b >= 56 && v.b <= 72, `${v.name} out of (0,255,64)+/-8`);
  } else if (v.name === 'light_d9_blue') {
    check(v.r >= Math.round(0.72 * 255) && v.g >= 200 && v.b >= 240, `${v.name} rgb(${v.r},${v.g},${v.b}) < (184,200,240)`);
  } else if (v.name === 'light_ff_blue') {
    check(Math.abs(v.r - 253) <= 4 && Math.abs(v.g - 252) <= 4 && Math.abs(v.b - 253) <= 4,
      `${v.name} rgb(${v.r},${v.g},${v.b}) out of (253,252,253)+/-4`);
  }
}
const { roi } = results;
console.log('web_glass_test roi:', JSON.stringify(roi));
for (const k of ['v8_dark', 'v8_light']) {
  const s = roi[k];
  console.log(`web_glass_test: ${k} blue_peak=${s.maxBh.toFixed(2)}@dx=${s.peakDx.toFixed(2)} blue_h55=${s.h55.toFixed(2)} grey_peak=${s.maxGh.toFixed(2)}@dx=${s.greyPeakDx.toFixed(2)} grey_h55=${s.greyH55.toFixed(2)}`);
  check(s.maxBh >= 10.0 && s.maxBh <= 12.0, `${k} maxBh=${s.maxBh}`);
  check(s.peakDx >= 0.67 && s.peakDx <= 1.33, `${k} peakDx=${s.peakDx}`);
  check(s.h55 >= 5.6 && s.h55 <= 6.4, `${k} h55=${s.h55}`);
  check(s.maxGh >= 10.0 && s.maxGh <= 12.0, `${k} maxGh=${s.maxGh}`);
  check(s.greyPeakDx >= 0.67 && s.greyPeakDx <= 1.33, `${k} greyPeakDx=${s.greyPeakDx}`);
  check(s.greyH55 >= 5.6 && s.greyH55 <= 6.4, `${k} greyH55=${s.greyH55}`);
  check(s.cL_br > 100 && s.cR_br < 20, `${k} center shift cL=${s.cL_br} cR=${s.cR_br}`);
  check(s.cTop_br < 20 && s.cBot_br < 20, `${k} top/bot ghosting`);
  check(s.y1 > s.y0 && s.y2 > s.y9 && s.y9 < s.y24, `${k} 5-point thickness profile`);
}
check(roi.v8_mono_ok, `v8_mono_ok=${roi.v8_mono_ok}`);
check(roi.v8_mag_h < 7.0, `v8_mag_h=${roi.v8_mag_h}`);
check(roi.v8_zoom118_gr > 40, `v8_zoom118_gr=${roi.v8_zoom118_gr}`);
check(roi.v9_sw.gr0 < 15 && roi.v9_sw.gr1 > 60 && roi.v9_sw.gr2 < 15, `v9_sw tir=${JSON.stringify(roi.v9_sw)}`);
check(roi.v9_sw.core >= 20.0 && roi.v9_sw.core <= 22.5, `v9_sw core=${roi.v9_sw.core}`);
check(roi.v9_sw.moatTop >= 6.5, `v9_sw moatTop=${roi.v9_sw.moatTop}`);
check(roi.v9_sw.tipGr < 15, `v9_sw tipGr=${roi.v9_sw.tipGr}`);
check(roi.v9_sw_off.coreR > roi.v9_sw_off.moatR + 15 && roi.v9_sw_off.rmR > roi.v9_sw_off.h0R, `v9_sw_off=${JSON.stringify(roi.v9_sw_off)}`);
check(roi.v9_sw_off.rcapBR < 20 && roi.v9_sw_off.rtirBR > 80, `v9_sw_off right cap=${JSON.stringify(roi.v9_sw_off)}`);
check(roi.v9_half_press[0] >= 4 && roi.v9_half_press[1] >= roi.v9_half_press[0] && roi.v9_half_press[2] > roi.v9_half_press[1], `v9_half_press=${JSON.stringify(roi.v9_half_press)}`);
check(roi.v9_seg.botBR >= 10 && roi.v9_seg.lftRB >= 20, `v9_seg=${JSON.stringify(roi.v9_seg)}`);
check(roi.v9_sw_2x[0] > 40 && roi.v9_sw_2x[1] > 40, `v9_sw_2x=${JSON.stringify(roi.v9_sw_2x)}`);
if (failed) process.exit(1);
console.log('web_glass_test: ok');
