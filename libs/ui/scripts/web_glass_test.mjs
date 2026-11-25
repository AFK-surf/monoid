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
    buf[3 * INST + 12] = 1; buf[3 * INST + 13] = 9; buf[3 * INST + 15] = 1; buf[3 * INST + 21] = 9;
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
        if (isLight ? (cy < refY - 70) : (cy > refY + 20)) cnt++;
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
    buf[41 * INST + 12] = 1; buf[41 * INST + 13] = 9; buf[41 * INST + 15] = 1; buf[41 * INST + 21] = 9;
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
  // V9c: Light Segmented Prism @ 3x (top/bot cyan, left/right amber, dark-stroke text ROI chroma-0 invariance)
  {
    const buf = new Float32Array(4 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 1, 1, 1, 1, 0);
    rect(buf, INST, 60.0, 34.0, 4.0, 12.0, 0, 20 / 255, 20 / 255, 20 / 255, 1, 0);
    rect(buf, 2 * INST, 78.0, 36.0, 22.0, 3.0, 0, 20 / 255, 20 / 255, 20 / 255, 1, 0);
    rect(buf, 3 * INST, 25, 17.5, 110, 45, 6, 1, 1, 1, 0, -56);
    buf[3 * INST + 4] = 22.5; buf[3 * INST + 6] = 1; buf[3 * INST + 7] = -48;
    buf[3 * INST + 12] = 1; buf[3 * INST + 13] = 9; buf[3 * INST + 15] = 1; buf[3 * INST + 21] = 9; buf[3 * INST + 22] = 0.04;
    H.present(buf, 4, 1, 1, 1);
    const shot = H.renderPixels();
    const top = pxAt(shot, 80 * 3, Math.floor(18.4 * 3));
    const bot = pxAt(shot, 80 * 3, Math.floor(61.6 * 3));
    const lft = pxAt(shot, Math.floor(25.9 * 3), 40 * 3);
    const rgt = pxAt(shot, Math.floor(134.1 * 3), 40 * 3);
    buf[3 * INST + 20] = -561; buf[3 * INST + 22] = 0;
    H.present(buf, 4, 1, 1, 1);
    const shot0 = H.renderPixels();
    let textDiff = 0;
    for (let py = 32 * 3; py <= 48 * 3; py++) {
      for (let pxI = 55 * 3; pxI <= 105 * 3; pxI++) {
        const a = pxAt(shot, pxI, py), b = pxAt(shot0, pxI, py);
        for (let ch = 0; ch < 3; ch++) textDiff = Math.max(textDiff, Math.abs(a[ch] - b[ch]));
      }
    }
    let strokeSpan = 0;
    for (let py = 30 * 3; py <= 50 * 3; py++) {
      if (lumaOf(pxAt(shot, 62 * 3, py)) < 160) strokeSpan++;
    }
    const tp = new Float32Array(3 * INST);
    rect(tp, 0, 0, 0, VW, VH, 0, 1, 1, 1, 1, 0);
    rect(tp, INST, 10, 24, 140, 32, 0, 190 / 255, 190 / 255, 190 / 255, 1, 0);
    rect(tp, 2 * INST, 25, 17.5, 110, 45, 6, 1, 1, 1, 0, -5611);
    tp[2 * INST + 4] = 22.5; tp[2 * INST + 6] = 1; tp[2 * INST + 7] = -48;
    tp[2 * INST + 12] = 1; tp[2 * INST + 13] = 9; tp[2 * INST + 15] = 1; tp[2 * INST + 21] = 9; tp[2 * INST + 22] = 0.04;
    H.present(tp, 3, 1, 1, 1);
    const shotT = H.renderPixels();
    const pinchOutL = lumaOf(pxAt(shotT, 80 * 3, Math.floor(25.5 * 3)));
    const pinchInL = lumaOf(pxAt(shotT, 80 * 3, Math.floor(29.0 * 3)));
    roi.v9_seg = { topBR: top[2] - top[0], botBR: bot[2] - bot[0], lftRB: lft[0] - lft[2], rgtRB: rgt[0] - rgt[2], textDiff, strokeSpan, pinchOutL, pinchInL };
  }
  // V9e: Switch uniform green center + blue track swap + OFF r9->r4.5 + 5-level press monotonic area
  {
    const buf = new Float32Array(2 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 48 / 255, 209 / 255, 88 / 255, 1, 0);
    rect(buf, INST, 52.9, 21.0, 59.2, 38.4, 6, 1, 1, 1, 0, -562);
    buf[INST + 4] = 19.2; buf[INST + 6] = 1; buf[INST + 7] = -32;
    buf[INST + 12] = 1; buf[INST + 13] = 9; buf[INST + 15] = 1; buf[INST + 21] = 9;
    H.present(buf, 2, 48 / 255, 209 / 255, 88 / 255);
    const shot = H.renderPixels();
    const c = pxAt(shot, Math.round(82.5 * 3), Math.round(40.2 * 3));
    roi.v9_sw_green_ctr = [c[0], c[1], c[2]];

    // Blue track swap
    const sb = new Float32Array(3 * INST);
    rect(sb, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
    rect(sb, INST, 40.0, 26.0, 63.0, 28.0, 0, 0, 122 / 255, 1, 1, 0);
    sb[INST + 4] = 14; sb[INST + 36] = 14; sb[INST + 37] = 14; sb[INST + 38] = 14; sb[INST + 39] = 14;
    rect(sb, 2 * INST, 52.9, 21.0, 59.2, 38.4, 6, 1, 1, 1, 0, -5621);
    sb[2 * INST + 4] = 19.2; sb[2 * INST + 6] = 1; sb[2 * INST + 7] = -32;
    sb[2 * INST + 12] = 1; sb[2 * INST + 13] = 9; sb[2 * INST + 15] = 1; sb[2 * INST + 21] = 9;
    H.present(sb, 3, 28 / 255, 28 / 255, 30 / 255);
    const cb = pxAt(H.renderPixels(), 80 * 3, 21 * 3 + 1);
    roi.v9_sw_blue_caustic = [cb[0], cb[1], cb[2]];

    // OFF fixed press r=9.0 vs r=4.5
    const offMoat = [];
    for (const [ri, rv] of [[0, 9.0], [1, 4.5]]) {
      const so = new Float32Array(3 * INST);
      rect(so, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
      rect(so, INST, 40.0, 26.0, 63.0, 28.0, 0, 120 / 255, 120 / 255, 128 / 255, 1, 0);
      so[INST + 4] = 14; so[INST + 36] = 14; so[INST + 37] = 14; so[INST + 38] = 14; so[INST + 39] = 14;
      rect(so, 2 * INST, 52.9, 21.0, 59.2, 38.4, 6, 1, 1, 1, 0, -5622 - ri);
      so[2 * INST + 4] = 19.2; so[2 * INST + 6] = 1; so[2 * INST + 7] = -32;
      so[2 * INST + 12] = 1; so[2 * INST + 13] = 9; so[2 * INST + 15] = 1; so[2 * INST + 21] = rv;
      H.present(so, 3, 28 / 255, 28 / 255, 30 / 255);
      const pxo = H.renderPixels();
      let best = 0, cur = 0;
      for (let py = 21 * 3 + 2; py < 40 * 3; py++) {
        if (pxAt(pxo, 80 * 3, py)[0] < 95) { cur++; if (cur > best) best = cur; } else cur = 0;
      }
      offMoat.push(best);
    }
    roi.v9_sw_off_moat = offMoat;

    // 5-level white-cap + glass press monotonic visible delta area vs p=0 rest (synced with liquid_toggle.mbt)
    const areas = [];
    let pxRest = null;
    for (const [pi, p] of [[0, 0], [1, 0.25], [2, 0.5], [3, 0.75], [4, 1.0]]) {
      const sc5 = new Float32Array(4 * INST);
      rect(sc5, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
      rect(sc5, INST, 40.0, 26.0, 63.0, 28.0, 0, 48 / 255, 209 / 255, 88 / 255, 1, 0);
      sc5[INST + 4] = 14; sc5[INST + 36] = 14; sc5[INST + 37] = 14; sc5[INST + 38] = 14; sc5[INST + 39] = 14;
      const cw = 37.0 * (1.0 + 0.60 * p), ch = 24.0 * (1.0 + 0.60 * p);
      const cx0 = 82.5 - cw * 0.5, cy0 = 40.0 - ch * 0.5;
      const capA = Math.min(1.0, Math.max(0.0, 1.0 - 1.8 * p));
      rect(sc5, 2 * INST, cx0, cy0, cw, ch, 0, 1, 1, 1, capA, 0);
      sc5[2 * INST + 4] = ch * 0.5;
      sc5[2 * INST + 36] = ch * 0.5; sc5[2 * INST + 37] = ch * 0.5; sc5[2 * INST + 38] = ch * 0.5; sc5[2 * INST + 39] = ch * 0.5;
      let ninst = 3;
      if (p > 0.001) {
        rect(sc5, 3 * INST, cx0, cy0, cw, ch, 6, 1, 1, 1, 0, -5625 - pi);
        sc5[3 * INST + 4] = ch * 0.5; sc5[3 * INST + 6] = 1; sc5[3 * INST + 7] = -32;
        sc5[3 * INST + 12] = p; sc5[3 * INST + 13] = 9 * p; sc5[3 * INST + 15] = p; sc5[3 * INST + 21] = 9 * p;
        ninst = 4;
      }
      H.present(sc5, ninst, 28 / 255, 28 / 255, 30 / 255);
      const px5 = H.renderPixels();
      if (pi === 0) {
        pxRest = px5;
        areas.push(0);
      } else {
        let cnt = 0;
        for (let py = 21 * 3; py <= 59 * 3; py += 2) {
          for (let pxI = 53 * 3; pxI <= 112 * 3; pxI += 2) {
            const c0 = pxAt(px5, pxI, py), r0 = pxAt(pxRest, pxI, py);
            if (Math.abs(c0[0] - r0[0]) + Math.abs(c0[1] - r0[1]) + Math.abs(c0[2] - r0[2]) >= 30) cnt++;
          }
        }
        areas.push(cnt);
      }
    }
    roi.v9_sw_5press_delta_area = areas;
  }
  // V9f: Role 4 Tab icon bevel gate (FIXED refract=9.0, Role 4 -64; icon at x_right-6.7pt vs empty; |y-cy|=0.42*h diff==0)
  {
    const buf = new Float32Array(4 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
    rect(buf, INST, 25, 17.5, 110, 45, 6, 1, 1, 1, 0, -563);
    buf[INST + 4] = 22.5; buf[INST + 6] = 1; buf[INST + 7] = -64;
    buf[INST + 12] = 1; buf[INST + 13] = 9; buf[INST + 15] = 1; buf[INST + 21] = 9;
    H.present(buf, 2, 28 / 255, 28 / 255, 30 / 255);
    const shotEmpty = H.renderPixels();
    rect(buf, INST, 127.3, 35.0, 2.0, 10.0, 0, 1, 0.55, 0, 1, 0);
    rect(buf, 2 * INST, 117.0, 56.0, 2.0, 6.0, 0, 1, 0.55, 0, 1, 0);
    rect(buf, 3 * INST, 25, 17.5, 110, 45, 6, 1, 1, 1, 0, -564);
    buf[3 * INST + 4] = 22.5; buf[3 * INST + 6] = 1; buf[3 * INST + 7] = -64;
    buf[3 * INST + 12] = 1; buf[3 * INST + 13] = 9; buf[3 * INST + 15] = 1; buf[3 * INST + 21] = 9;
    H.present(buf, 4, 28 / 255, 28 / 255, 30 / 255);
    const shotIcon = H.renderPixels();
    const aMid = pxAt(shotEmpty, 400, 120);
    const bMid = pxAt(shotIcon, 400, 120);
    const midDelta = Math.abs(bMid[0] - aMid[0]) + Math.abs(bMid[1] - aMid[1]);
    const aOut = pxAt(shotEmpty, Math.round(123.2 * 3), Math.round(58.9 * 3));
    const bOut = pxAt(shotIcon, Math.round(123.2 * 3), Math.round(58.9 * 3));
    const outDiff = Math.max(Math.abs(bOut[0] - aOut[0]), Math.abs(bOut[1] - aOut[1]), Math.abs(bOut[2] - aOut[2]));
    roi.v9_tab_icon_delta = { midDelta, outDiff };
  }
  // V9g: Role 4 Tab bevelGate outer falloff regression (no un-refracted ghost at inward=10pt)
  {
    const buf = new Float32Array(3 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 246 / 255, 244 / 255, 240 / 255, 1, 0);
    rect(buf, INST, 41.5, 8.0, 2.0, 64.0, 0, 90 / 255, 90 / 255, 90 / 255, 1, 0);
    rect(buf, 2 * INST, 32.5, 8.25, 95.0, 63.5, 6, 1, 1, 1, 0, -565);
    buf[2 * INST + 4] = 31.75; buf[2 * INST + 6] = 1; buf[2 * INST + 7] = -64;
    buf[2 * INST + 12] = 1; buf[2 * INST + 13] = 9; buf[2 * INST + 15] = 1; buf[2 * INST + 21] = 9;
    H.present(buf, 3, 246 / 255, 244 / 255, 240 / 255);
    const shotG = H.renderPixels();
    const origL = lumaOf(pxAt(shotG, 127, 120));
    let refrMinL = 1e9;
    for (let pxI = 132; pxI <= 136; pxI++) {
      const lr = lumaOf(pxAt(shotG, pxI, 120));
      if (lr < refrMinL) refrMinL = lr;
    }
    roi.v9_tab_no_ghost = { origL, refrMinL };
  }
  // V9h: Switch ON held glassFrost C0 continuity (0 -> eps, 0.108->0.110 veil, 0.127->0.129 blur, 0.60 frosted)
  {
    const frosts = [0.0, 0.0001, 0.00011, 0.108, 0.110, 0.127, 0.129, 0.60];
    let px0 = null, pxPrev = null;
    let maxDEps = 0, maxDVeil = 0, maxDBlur = 0;
    let ctr0 = [0, 0], ctr60 = [0, 0];
    for (let fi = 0; fi < frosts.length; fi++) {
      const fr = frosts[fi];
      let alpha = 0.0, slot7 = -32.0, refr = 9.0;
      if (fr > 0.0001) {
        const aFrac = 0.94 * fr;
        alpha = Math.round(aFrac * 255.0) / 255.0;
        const bl = aFrac <= 0.12 ? 0.0 : 14.0 * ((aFrac - 0.12) / 0.88) * 0.5;
        slot7 = bl <= 0.0 ? -32.0 : bl;
        refr = 9.0 * (1.0 - 0.55 * fr);
      }
      const buf = new Float32Array(3 * INST);
      rect(buf, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
      rect(buf, INST, 40, 26, 63, 28, 0, 48 / 255, 209 / 255, 88 / 255, 1, 0);
      buf[INST + 4] = 14;
      rect(buf, 2 * INST, 52.9, 21.0, 59.2, 38.4, 6, 1, 1, 1, alpha, -90 - fi);
      buf[2 * INST + 4] = 19.2; buf[2 * INST + 6] = 1; buf[2 * INST + 7] = slot7;
      buf[2 * INST + 12] = 1; buf[2 * INST + 13] = 9; buf[2 * INST + 15] = 1; buf[2 * INST + 21] = refr;
      H.present(buf, 3, 28 / 255, 28 / 255, 30 / 255);
      const shot = H.renderPixels();
      if (fi === 0) {
        px0 = shot;
        const c = pxAt(shot, 82 * 3, 40 * 3);
        ctr0 = [c[0], c[1]];
      } else if (fi === 2) {
        for (let py = 21 * 3; py <= 59 * 3; py++) {
          for (let pxI = 53 * 3; pxI <= 112 * 3; pxI++) {
            const a = pxAt(px0, pxI, py), b = pxAt(shot, pxI, py);
            for (let ch = 0; ch < 3; ch++) {
              const d = Math.abs(a[ch] - b[ch]);
              if (d > maxDEps) maxDEps = d;
            }
          }
        }
      } else if (fi === 3 || fi === 5) {
        pxPrev = shot;
      } else if (fi === 4 || fi === 6) {
        let md = 0;
        for (let py = 21 * 3; py <= 59 * 3; py++) {
          for (let pxI = 53 * 3; pxI <= 112 * 3; pxI++) {
            const a = pxAt(pxPrev, pxI, py), b = pxAt(shot, pxI, py);
            for (let ch = 0; ch < 3; ch++) {
              const d = Math.abs(a[ch] - b[ch]);
              if (d > md) md = d;
            }
          }
        }
        if (fi === 4) maxDVeil = md; else maxDBlur = md;
      } else if (fi === 7) {
        const c = pxAt(shot, 82 * 3, 40 * 3);
        ctr60 = [c[0], c[1]];
      }
    }
    roi.v9_switch_frost_continuity = { maxDEps, maxDVeil, maxDBlur, ctr0, ctr60 };
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
  // V10: Regular Glass Light Parabolic AA (@2x, R=24pt)
  {
    H.renderInit(VW, VH, 2);
    const buf = new Float32Array(2 * INST);
    rect(buf, 0, 0, 0, VW, VH, 0, 242 / 255, 240 / 255, 236 / 255, 1, 0);
    rect(buf, INST, 20, 10, 120, 60, 6, 253 / 255, 252 / 255, 253 / 255, 0.40, -70);
    buf[INST + 4] = 24; buf[INST + 6] = 1; buf[INST + 7] = 0;
    buf[INST + 12] = 0.6; buf[INST + 13] = 14; buf[INST + 15] = 1; buf[INST + 21] = 20;
    H.present(buf, 2, 242 / 255, 240 / 255, 236 / 255);
    const shot = H.renderPixels();
    const masses = [];
    const bgL = 0.2126 * 242 + 0.7152 * 240 + 0.0722 * 236;
    for (let py = 24; py <= 64; py++) {
      let mass = 0;
      for (let xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
        const L = lumaOf(pxAt(shot, xpx, py));
        if (L < bgL) mass += (bgL - L);
      }
      masses.push(mass / 2);
    }
    let maxD2 = 0;
    for (let i = 1; i < masses.length - 1; i++) {
      const d2 = Math.abs(masses[i - 1] - 2 * masses[i] + masses[i + 1]);
      if (d2 > maxD2) maxD2 = d2;
    }
    let sideLmin = 1e9;
    for (let xpx = 140 * 2 - 8; xpx <= 140 * 2 + 2; xpx++) {
      const L = lumaOf(pxAt(shot, xpx, 80));
      if (L < sideLmin) sideLmin = L;
    }
    const lightOuterTopL = lumaOf(pxAt(shot, 80 * 2, 10 * 2 - 1));
    const lightTopL = lumaOf(pxAt(shot, 80 * 2, 10 * 2));
    const lightMidL = lumaOf(pxAt(shot, 80 * 2, 40 * 2));
    roi.v10_reg_light = { maxD2, sideLmin, lightOuterTopL, lightTopL, lightMidL };
    const bufd = new Float32Array(2 * INST);
    rect(bufd, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
    rect(bufd, INST, 20, 10, 120, 60, 6, 32 / 255, 32 / 255, 32 / 255, 0x67 / 255, -71);
    bufd[INST + 4] = 24; bufd[INST + 6] = 1; bufd[INST + 7] = 0;
    bufd[INST + 12] = 0.6; bufd[INST + 13] = 14; bufd[INST + 15] = 1; bufd[INST + 21] = 20;
    H.present(bufd, 2, 28 / 255, 28 / 255, 30 / 255);
    const shotd = H.renderPixels();
    let dh = 0xcbf29ce484222325n;
    const fnvStep = (x, y) => {
      const i = (y * shotd.w + x) * 4;
      for (let ch = 0; ch < 4; ch++) dh = ((dh ^ BigInt(shotd.px[i + ch])) * 0x100000001b3n) & 0xffffffffffffffffn;
    };
    for (let py = 10 * 2; py <= 10 * 2 + 8; py++) fnvStep(80 * 2, py);
    for (let xpx = 140 * 2 - 8; xpx <= 140 * 2 + 1; xpx++) fnvStep(xpx, 40 * 2);
    for (let py = 10 * 2; py <= 10 * 2 + 48; py++) {
      for (let xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) fnvStep(xpx, py);
    }
    roi.v10_reg_dark = {
      lMid: lumaOf(pxAt(shotd, 80 * 2, 40 * 2)),
      lTop: lumaOf(pxAt(shotd, 80 * 2, 10 * 2)),
      lSideIn: lumaOf(pxAt(shotd, 140 * 2 - 1, 40 * 2)),
      lSideOut: lumaOf(pxAt(shotd, 140 * 2, 40 * 2)),
      roiFnv1a: '0x' + dh.toString(16).padStart(16, '0'),
    };
    // V12-AntiSmear: Regular Light blur=1.2pt at 3x over 2pt alternating dark/light strokes
    {
      H.renderInit(VW, VH, 3);
      const sm = new Float32Array(7 * INST);
      rect(sm, 0, 0, 0, VW, VH, 0, 244 / 255, 241 / 255, 234 / 255, 1, 0);
      for (let si = 0; si < 5; si++) {
        rect(sm, (si + 1) * INST, 20, 30 + si * 4, 120, 2, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
      }
      rect(sm, 6 * INST, 20, 10, 120, 60, 6, 253 / 255, 252 / 255, 253 / 255, 0x67 / 255, -711);
      sm[6 * INST + 4] = 24; sm[6 * INST + 6] = 1; sm[6 * INST + 7] = 1.2;
      sm[6 * INST + 12] = 0.6; sm[6 * INST + 13] = 20; sm[6 * INST + 15] = 1;
      sm[6 * INST + 21] = 28; sm[6 * INST + 22] = 0.06;
      H.present(sm, 7, 244 / 255, 241 / 255, 234 / 255);
      const shots = H.renderPixels();
      let minL = 1e9, maxL = -1;
      for (let py = 34 * 3; py <= 42 * 3; py++) {
        const L = lumaOf(pxAt(shots, 80 * 3, py));
        if (L < minL) minL = L;
        if (L > maxL) maxL = L;
      }
      roi.v12_reg_antismear = { minL, maxL, delta: maxL - minL };
      H.renderInit(VW, VH, 2);
    }
    // V11-Unified-Panel-Glass: Light/Dark 0x80 overlay chroma, rim, white-backdrop WCAG >= 4.5:1, and 0xFF solid zero leak
    {
      const pb = new Float32Array(2 * INST);
      rect(pb, 0, 0, 0, VW, VH, 0, 211 / 255, 232 / 255, 253 / 255, 1, 0);
      rect(pb, INST, 20, 10, 120, 60, 6, 253 / 255, 252 / 255, 253 / 255, 0x80 / 255, -98);
      pb[INST + 4] = 22; pb[INST + 6] = 1; pb[INST + 7] = 14.0;
      pb[INST + 12] = 0.6; pb[INST + 13] = 20; pb[INST + 14] = 0; pb[INST + 15] = 1;
      pb[INST + 21] = 16; pb[INST + 22] = 0.0;
      H.present(pb, 2, 211 / 255, 232 / 255, 253 / 255);
      const s1 = H.renderPixels();
      const rim = pxAt(s1, 80 * 2, 20), mid = pxAt(s1, 80 * 2, 68);
      const midBR = mid[2] - mid[0], rimL = lumaOf(rim), midL = lumaOf(mid);
      pb[INST + 11] = 1.0; pb[INST + 20] = -99;
      H.present(pb, 2, 211 / 255, 232 / 255, 253 / 255);
      const s2 = H.renderPixels();
      const solidDL = Math.abs(lumaOf(pxAt(s2, 80 * 2, 20)) - lumaOf(pxAt(s2, 80 * 2, 68)));
      rect(pb, 0, 0, 0, VW, VH, 0, 0.60, 0.60, 0.60, 1, 0);
      pb[INST + 11] = 0x80 / 255; pb[INST + 20] = -100; pb[INST + 22] = 0.0;
      H.present(pb, 2, 0.60, 0.60, 0.60);
      const l60 = lumaOf(pxAt(H.renderPixels(), 80 * 2, 68));
      rect(pb, 0, 0, 0, VW, VH, 0, 0.72, 0.72, 0.72, 1, 0);
      pb[INST + 20] = -101;
      H.present(pb, 2, 0.72, 0.72, 0.72);
      const l72 = lumaOf(pxAt(H.renderPixels(), 80 * 2, 68));
      rect(pb, 0, 0, 0, VW, VH, 0, 0.60, 0.60, 0.60, 1, 0);
      pb[INST + 11] = 0xB3 / 255; pb[INST + 20] = -105; pb[INST + 22] = 0.0;
      H.present(pb, 2, 0.60, 0.60, 0.60);
      const l60CD = lumaOf(pxAt(H.renderPixels(), 80 * 2, 68));
      rect(pb, 0, 0, 0, VW, VH, 0, 0.72, 0.72, 0.72, 1, 0);
      pb[INST + 20] = -106;
      H.present(pb, 2, 0.72, 0.72, 0.72);
      const l72CD = lumaOf(pxAt(H.renderPixels(), 80 * 2, 68));
      rect(pb, 0, 0, 0, VW, VH, 0, 60 / 255, 120 / 255, 210 / 255, 1, 0);
      pb[INST + 8] = 32 / 255; pb[INST + 9] = 32 / 255; pb[INST + 10] = 32 / 255;
      pb[INST + 11] = 0x80 / 255; pb[INST + 20] = -102; pb[INST + 22] = 0.0;
      H.present(pb, 2, 60 / 255, 120 / 255, 210 / 255);
      const da = pxAt(H.renderPixels(), 80 * 2, 68), d80BR = da[2] - da[0];
      pb[INST + 11] = 0xCC / 255; pb[INST + 20] = -104; pb[INST + 22] = 0.0;
      H.present(pb, 2, 60 / 255, 120 / 255, 210 / 255);
      const dc = pxAt(H.renderPixels(), 80 * 2, 68), ccBR = dc[2] - dc[0];
      rect(pb, 0, 0, 0, VW, VH, 0, 1, 1, 1, 1, 0);
      pb[INST + 11] = 0x80 / 255; pb[INST + 20] = -107; pb[INST + 22] = 0.0;
      H.present(pb, 2, 1, 1, 1);
      const darkWhiteL = lumaOf(pxAt(H.renderPixels(), 80 * 2, 68));
      // Regular controls (chroma=0.06 vs 0.0) bit-exact zero-diff gate under Light 0x85/0xAB & Dark 0xAB
      let ctrlMaxDiff = 0, ctrlHashEq = true;
      const ctrlCases = [
        [false, 0x85 / 255, 211 / 255, 232 / 255, 253 / 255],
        [false, 0xAB / 255, 211 / 255, 232 / 255, 253 / 255],
        [true,  0xAB / 255,  60 / 255, 120 / 255, 210 / 255],
      ];
      pb[INST + 7] = 2.0; pb[INST + 12] = 0.6; pb[INST + 13] = 14.0; pb[INST + 21] = 20.0;
      for (let ci = 0; ci < ctrlCases.length; ci++) {
        const [dk, al, br, bg, bb] = ctrlCases[ci];
        rect(pb, 0, 0, 0, VW, VH, 0, br, bg, bb, 1, 0);
        pb[INST + 8] = dk ? 32 / 255 : 253 / 255;
        pb[INST + 9] = dk ? 32 / 255 : 252 / 255;
        pb[INST + 10] = dk ? 32 / 255 : 253 / 255;
        pb[INST + 11] = al;
        pb[INST + 20] = -110 - ci * 2; pb[INST + 22] = 0.06;
        H.present(pb, 2, br, bg, bb);
        const p06 = H.renderPixels();
        pb[INST + 20] = -111 - ci * 2; pb[INST + 22] = 0.0;
        H.present(pb, 2, br, bg, bb);
        const p00 = H.renderPixels();
        let h06 = 0xcbf29ce484222325n, h00 = 0xcbf29ce484222325n;
        const m64 = 0xffffffffffffffffn, pr = 0x100000001b3n;
        for (let ry = 20; ry < 140; ry++) {
          for (let rx = 40; rx < 280; rx++) {
            const q06 = pxAt(p06, rx, ry), q00 = pxAt(p00, rx, ry);
            for (let c = 0; c < 3; c++) {
              const d = Math.abs(q06[c] - q00[c]);
              if (d > ctrlMaxDiff) ctrlMaxDiff = d;
              h06 = ((h06 ^ BigInt(q06[c])) * pr) & m64;
              h00 = ((h00 ^ BigInt(q00[c])) * pr) & m64;
            }
          }
        }
        if (h06 !== h00) ctrlHashEq = false;
      }
      roi.v11_unified_panel_glass = { midBR, rimL, midL, solidDL, l60, l72, l60CD, l72CD, d80BR, ccBR, darkWhiteL, ctrlMaxDiff, ctrlHashEq };
    }
    // V13-Menu-Morph-DualW + V13b: sweep liquid_menu_morph_glass alpha codes & height-adaptive dual_w / zero-frost k=1
    {
      const mf = new Float32Array(INST);
      let maxStepL = 0, maxStepD = 0, maxStepT = 0, prevW = -1, wStart = 0, wEnd = 0;
      for (let ai = 103; ai <= 147; ai++) {
        mf.fill(0);
        mf[0] = 20; mf[1] = 10; mf[2] = 120; mf[3] = 60; mf[4] = 24;
        mf[5] = 6; mf[6] = 1; mf[7] = 1.2 + 2.8 * (ai - 103) / 44.0;
        mf[8] = 253 / 255; mf[9] = 252 / 255; mf[10] = 253 / 255; mf[11] = ai / 255;
        mf[12] = 0.6; mf[13] = 14; mf[15] = 1; mf[18] = VW; mf[19] = VH; mf[20] = -120; mf[21] = 20;
        const g = H.renderGrabOf(mf, 0, 1, 1);
        if (ai === 103) wStart = g.dualW;
        if (ai === 147) wEnd = g.dualW;
        if (prevW >= 0) maxStepL = Math.max(maxStepL, Math.abs(g.dualW - prevW));
        prevW = g.dualW;
      }
      prevW = -1;
      for (let ai = 103; ai <= 136; ai++) {
        mf.fill(0);
        mf[0] = 20; mf[1] = 10; mf[2] = 120; mf[3] = 60; mf[4] = 24;
        mf[5] = 6; mf[6] = 1; mf[7] = 1.2 + 2.8 * (ai - 103) / 33.0;
        mf[8] = 32 / 255; mf[9] = 32 / 255; mf[10] = 32 / 255; mf[11] = ai / 255;
        mf[12] = 0.6; mf[13] = 14; mf[15] = 1; mf[18] = VW; mf[19] = VH; mf[20] = -121; mf[21] = 20;
        const g = H.renderGrabOf(mf, 0, 1, 1);
        if (prevW >= 0) maxStepD = Math.max(maxStepD, Math.abs(g.dualW - prevW));
        prevW = g.dualW;
      }
      prevW = -1;
      for (let ai = 180; ai <= 210; ai++) {
        mf.fill(0);
        mf[0] = 20; mf[1] = 10; mf[2] = 120; mf[3] = 60; mf[4] = 24;
        mf[5] = 6; mf[6] = 1; mf[7] = 1.2;
        mf[8] = 0; mf[9] = 136 / 255; mf[10] = 1; mf[11] = ai / 255;
        mf[12] = 0.6; mf[13] = 14; mf[15] = 1; mf[18] = VW; mf[19] = VH; mf[20] = -122; mf[21] = 20;
        const g = H.renderGrabOf(mf, 0, 1, 1);
        if (prevW >= 0) maxStepT = Math.max(maxStepT, Math.abs(g.dualW - prevW));
        prevW = g.dualW;
      }
      roi.v13_menu_morph_dual_w = { wStart, wEnd, maxStepL, maxStepD, maxStepT };
      mf.fill(0);
      mf[0] = 20; mf[1] = 10; mf[2] = 132; mf[3] = 44; mf[4] = 22;
      mf[5] = 6; mf[6] = 1; mf[7] = 1.2;
      mf[8] = 32 / 255; mf[9] = 32 / 255; mf[10] = 32 / 255; mf[11] = 0x67 / 255;
      mf[12] = 0.6; mf[13] = 14; mf[15] = 1; mf[18] = VW; mf[19] = VH; mf[20] = -123; mf[21] = 20;
      const g44 = H.renderGrabOf(mf, 0, 1, 1);
      mf[2] = 292; mf[3] = 62; mf[4] = 31;
      const g62 = H.renderGrabOf(mf, 0, 1, 1);
      mf[2] = 100; mf[3] = 44; mf[4] = 22; mf[7] = 0.0;
      mf[8] = 1; mf[9] = 1; mf[10] = 1; mf[11] = 0x1A / 255;
      const gclr = H.renderGrabOf(mf, 0, 1, 1);
      roi.v13_dual_k1 = { g44, g62, gclr };
      // V13c: effective-sigma continuity across menu morph (legacy + v9 3-anchor) & size sweep (14..20pt) at 2x & 3x.
      let maxMorphDsig = 0, minMorphDsig = 0, maxSzDsig = 0;
      let maxV9Dsig = 0, minV9Dsig = 0;
      for (const scI of [2, 3]) {
        H.renderInit(VW, VH, scI);
        let prevSe = -1;
        for (let si = 0; si <= 240; si++) {
          const t = si / 240;
          mf.fill(0);
          mf[0] = 20; mf[1] = 10; mf[2] = 120; mf[3] = 60; mf[4] = 24;
          mf[5] = 6; mf[6] = 1; mf[7] = 1.2 + 2.8 * t;
          mf[8] = 253 / 255; mf[9] = 252 / 255; mf[10] = 253 / 255; mf[11] = (103 + 44 * t) / 255;
          mf[12] = 0.6; mf[13] = 14; mf[15] = 1; mf[18] = VW; mf[19] = VH; mf[20] = -124; mf[21] = 20;
          const gm = H.renderGrabOf(mf, 0, 1, 1);
          const pre = gm.k > 0 ? 0.75 * (1 - Math.pow(0.25, gm.k)) / 3 + 1 / 6 : 0;
          const sgu = (gm.dualScale && gm.k > 0) ? (gm.sg > 0.55 ? gm.sg : 0.526) : (gm.sg > 0.3 ? gm.sg : 0);
          const se = (1 << gm.k) * Math.sqrt(sgu * sgu + pre);
          if (prevSe >= 0) {
            const d = se - prevSe;
            if (Math.abs(d) > maxMorphDsig) maxMorphDsig = Math.abs(d);
            if (d < minMorphDsig) minMorphDsig = d;
          }
          prevSe = se;
        }
        prevSe = -1;
        for (let si = 0; si <= 240; si++) {
          const t = si / 240;
          const u = t <= 0.5 ? t * 2 : (t - 0.5) * 2;
          const mb = t <= 0.5 ? (1.2 + 4.8 * u) : (6.0 + 8.0 * u);
          const ma = t <= 0.5 ? (103 + 13 * u) / 255 : (116 + 12 * u) / 255;
          mf.fill(0);
          mf[0] = 20; mf[1] = 10; mf[2] = 44 + 207 * t; mf[3] = 44 + 214 * t; mf[4] = 22 + 10 * t;
          mf[5] = 6; mf[6] = 1; mf[7] = mb;
          mf[8] = 253 / 255; mf[9] = 252 / 255; mf[10] = 253 / 255; mf[11] = ma;
          mf[12] = 0.6; mf[13] = 14 + 6 * t; mf[15] = 1; mf[18] = VW; mf[19] = VH; mf[20] = -126; mf[21] = 20 - 4 * t;
          const gm = H.renderGrabOf(mf, 0, 1, 1);
          const pre = gm.k > 0 ? 0.75 * (1 - Math.pow(0.25, gm.k)) / 3 + 1 / 6 : 0;
          const sgu = (gm.dualScale && gm.k > 0) ? (gm.sg > 0.55 ? gm.sg : 0.526) : (gm.sg > 0.3 ? gm.sg : 0);
          const se = (1 << gm.k) * Math.sqrt(sgu * sgu + pre);
          if (prevSe >= 0) {
            const d = se - prevSe;
            if (Math.abs(d) > maxV9Dsig) maxV9Dsig = Math.abs(d);
            if (d < minV9Dsig) minV9Dsig = d;
          }
          prevSe = se;
        }
        prevSe = -1;
        for (let si = 0; si <= 60; si++) {
          const dim = 14 + 6 * si / 60;
          mf.fill(0);
          mf[0] = 20; mf[1] = 10; mf[2] = 120; mf[3] = dim; mf[4] = dim * 0.5;
          mf[5] = 6; mf[6] = 1; mf[7] = 1.2;
          mf[8] = 253 / 255; mf[9] = 252 / 255; mf[10] = 253 / 255; mf[11] = 103 / 255;
          mf[12] = 0.6; mf[13] = 14; mf[15] = 1; mf[18] = VW; mf[19] = VH; mf[20] = -125; mf[21] = 20;
          const gs = H.renderGrabOf(mf, 0, 1, 1);
          const pre = gs.k > 0 ? 0.75 * (1 - Math.pow(0.25, gs.k)) / 3 + 1 / 6 : 0;
          const sgu = (gs.dualScale && gs.k > 0) ? (gs.sg > 0.55 ? gs.sg : 0.526) : (gs.sg > 0.3 ? gs.sg : 0);
          const se = (1 << gs.k) * Math.sqrt(sgu * sgu + pre);
          if (prevSe >= 0) {
            const d = Math.abs(se - prevSe);
            if (d > maxSzDsig) maxSzDsig = d;
          }
          prevSe = se;
        }
      }
      H.renderInit(VW, VH, 2);
      roi.v13c_sigma_cont = { maxMorphDsig, minMorphDsig, maxV9Dsig, minV9Dsig, maxSzDsig };
    }
    // V14-Opus-Gates: (1) Tinted capsule dark outer contour <= 14; (2) Light Regular rim on black/mid-grey/cream;
    // (3) Clear pill on pure white has zero inner grey band (min_L >= 254).
    {
      H.renderInit(VW, VH, 3);
      const tb = new Float32Array(2 * INST);
      rect(tb, 0, 0, 0, VW, VH, 0, 28 / 255, 28 / 255, 30 / 255, 1, 0);
      rect(tb, INST, 20, 18, 78, 44, 6, 0, 122 / 255, 1, 0x99 / 255, -130);
      tb[INST + 4] = 22; tb[INST + 6] = 1; tb[INST + 7] = 1.2;
      tb[INST + 12] = 0.6; tb[INST + 13] = 14; tb[INST + 15] = 1; tb[INST + 21] = 20; tb[INST + 22] = 0.06;
      H.present(tb, 2, 28 / 255, 28 / 255, 30 / 255);
      const tintSideL = lumaOf(pxAt(H.renderPixels(), 98 * 3, 40 * 3));
      const bgVals = [[0, 0, 0], [0.5, 0.5, 0.5], [244 / 255, 241 / 255, 234 / 255]];
      const topD = [], top2D = [], topAbs = [];
      for (let bi = 0; bi < 3; bi++) {
        const lr = new Float32Array(2 * INST);
        rect(lr, 0, 0, 0, VW, VH, 0, bgVals[bi][0], bgVals[bi][1], bgVals[bi][2], 1, 0);
        rect(lr, INST, 14, 18, 132, 44, 6, 253 / 255, 252 / 255, 253 / 255, 0x67 / 255, -131 - bi);
        lr[INST + 4] = 22; lr[INST + 6] = 1; lr[INST + 7] = 1.2;
        lr[INST + 12] = 0.6; lr[INST + 13] = 14; lr[INST + 15] = 1; lr[INST + 21] = 20; lr[INST + 22] = 0.06;
        H.present(lr, 2, bgVals[bi][0], bgVals[bi][1], bgVals[bi][2]);
        const s = H.renderPixels();
        const lm = lumaOf(pxAt(s, 80 * 3, 40 * 3));
        const l0 = lumaOf(pxAt(s, 80 * 3, 18 * 3));
        const l2 = lumaOf(pxAt(s, 80 * 3, 18 * 3 + 2));
        topD.push(l0 - lm); top2D.push(l2 - lm); topAbs.push(l0);
      }
      const cw = new Float32Array(2 * INST);
      rect(cw, 0, 0, 0, VW, VH, 0, 1, 1, 1, 1, 0);
      rect(cw, INST, 20, 18, 100, 44, 6, 1, 1, 1, 0x1A / 255, -135);
      cw[INST + 4] = 22; cw[INST + 6] = 1; cw[INST + 7] = 0.0;
      cw[INST + 12] = 0.6; cw[INST + 13] = 14; cw[INST + 15] = 1; cw[INST + 21] = 16;
      H.present(cw, 2, 1, 1, 1);
      const sc = H.renderPixels();
      let clrMinL = 999;
      for (let py = 18 * 3 + 2; py <= 62 * 3 - 2; py++) {
        const L = lumaOf(pxAt(sc, 70 * 3, py));
        if (L < clrMinL) clrMinL = L;
      }
      roi.v14_opus_gates = { tintSideL, topD, top2D, topAbs, clrMinL };
      // V14b-Scroll-Shimmer: 1px vertical scroll shift-invariance at 2x & 3x.
      roi.v14b_scroll_shimmer = [];
      for (const scI of [2, 3]) {
        H.renderInit(VW, VH, scI);
        const fpx = [];
        for (let fi = 0; fi < 2; fi++) {
          const dy = fi / scI;
          const sb = new Float32Array(7 * INST);
          rect(sb, 0, 0, 0, VW, VH, 0, 1, 1, 1, 1, 0);
          rect(sb, INST, 0, 24 + dy, VW, 1.0, 0, 0.08, 0.08, 0.08, 1, 0);
          rect(sb, 2 * INST, 0, 31 + dy, VW, 1.5, 0, 0.08, 0.08, 0.08, 1, 0);
          rect(sb, 3 * INST, 0, 39 + dy, VW, 2.0, 0, 0.08, 0.08, 0.08, 1, 0);
          rect(sb, 4 * INST, 0, 47 + dy, VW, 1.0, 0, 0.08, 0.08, 0.08, 1, 0);
          rect(sb, 5 * INST, 0, 54 + dy, VW, 2.0, 0, 0.08, 0.08, 0.08, 1, 0);
          rect(sb, 6 * INST, 14, 18, 132, 44, 6, 253 / 255, 252 / 255, 253 / 255, 0x67 / 255, -140 - scI * 2 - fi);
          sb[6 * INST + 4] = 22; sb[6 * INST + 6] = 1; sb[6 * INST + 7] = 1.2;
          sb[6 * INST + 12] = 0.6; sb[6 * INST + 13] = 14; sb[6 * INST + 15] = 1;
          sb[6 * INST + 21] = 20; sb[6 * INST + 22] = 0.06;
          H.present(sb, 7, 1, 1, 1);
          fpx.push(H.renderPixels());
        }
        let maxD = 0, sum2 = 0, cnt = 0;
        for (let py = 28 * scI; py < 52 * scI - 1; py++) {
          for (let px = 44 * scI; px < 116 * scI; px++) {
            const l0 = lumaOf(pxAt(fpx[0], px, py));
            const l1 = lumaOf(pxAt(fpx[1], px, py + 1));
            const d = Math.abs(l1 - l0);
            if (d > maxD) maxD = d;
            sum2 += d * d;
            cnt++;
          }
        }
        roi.v14b_scroll_shimmer.push({ sc: scI, maxD, rms: Math.sqrt(sum2 / Math.max(cnt, 1)) });
      }
      // V14c-DualSlot-MidSg: 2x blur=2.1pt tint=0x67 falls in 0.3 < sg <= 0.55 (sg~0.438).
      {
        H.renderInit(VW, VH, 2);
        const mf21 = new Float32Array(INST);
        mf21[0] = 14; mf21[1] = 18; mf21[2] = 132; mf21[3] = 44; mf21[4] = 22;
        mf21[5] = 6; mf21[6] = 1; mf21[7] = 2.1;
        mf21[8] = 253 / 255; mf21[9] = 252 / 255; mf21[10] = 253 / 255; mf21[11] = 0x67 / 255;
        mf21[12] = 0.6; mf21[13] = 14; mf21[15] = 1; mf21[18] = VW; mf21[19] = VH; mf21[20] = -149; mf21[21] = 20;
        const g21 = H.renderGrabOf(mf21, 0, 1, 1);
        const s21 = new Float32Array(3 * INST);
        rect(s21, 0, 0, 0, VW, VH, 0, 1, 1, 1, 1, 0);
        rect(s21, INST, 74, 0, 12, VH, 0, 0.05, 0.05, 0.05, 1, 0);
        rect(s21, 2 * INST, 14, 18, 132, 44, 6, 253 / 255, 252 / 255, 253 / 255, 0x67 / 255, -149);
        s21[2 * INST + 4] = 22; s21[2 * INST + 6] = 1; s21[2 * INST + 7] = 2.1;
        s21[2 * INST + 12] = 0.6; s21[2 * INST + 13] = 14; s21[2 * INST + 15] = 1;
        s21[2 * INST + 21] = 20; s21[2 * INST + 22] = 0.06;
        H.present(s21, 3, 1, 1, 1);
        const p1 = H.renderPixels();
        H.present(s21, 3, 1, 1, 1);
        const p2 = H.renderPixels();
        const barL = lumaOf(pxAt(p1, 80 * 2, 40 * 2));
        const whL = lumaOf(pxAt(p1, 50 * 2, 40 * 2));
        let cacheDiff = 0;
        for (let py = 24 * 2; py < 56 * 2; py++) {
          for (let px = 30 * 2; px < 130 * 2; px++) {
            const a1 = pxAt(p1, px, py), a2 = pxAt(p2, px, py);
            for (let c = 0; c < 3; c++) cacheDiff = Math.max(cacheDiff, Math.abs(a1[c] - a2[c]));
          }
        }
        roi.v14c_dual_slot_midsg = { dualScale: g21.dualScale, k: g21.k, sg: g21.sg, barL, whL, cacheDiff };
      }
      // V15-Unified-V9-Gates
      {
        H.renderInit(160, 80, 2);
        const fg = new Float32Array(2 * INST);
        rect(fg, 0, 0, 0, 160, 80, 0, 0.5, 0.5, 0.5, 1, 0);
        rect(fg, INST, 14, 9, 132, 62, 6, 253 / 255, 252 / 255, 253 / 255, 0x67 / 255, -151);
        fg[INST + 4] = 31; fg[INST + 6] = 1; fg[INST + 7] = 4.0;
        fg[INST + 12] = 0.6; fg[INST + 13] = 14; fg[INST + 15] = 1; fg[INST + 21] = 20;
        H.present(fg, 2, 0.5, 0.5, 0.5);
        const k2G = pxAt(H.renderPixels(), 80 * 2, 40 * 2)[1];

        H.renderInit(160, 80, 3);
        const wb = new Float32Array(6 * INST);
        rect(wb, 0, 0, 0, 160, 80, 0, 0, 0, 0, 1, 0);
        for (let bi = 0; bi < 4; bi++) rect(wb, (1 + bi) * INST, 0, 10 + bi * 20, 160, 2.0, 0, 1, 1, 1, 1, 0);
        rect(wb, 5 * INST, 14, 9, 132, 62, 6, 253 / 255, 252 / 255, 253 / 255, 0x67 / 255, -152);
        wb[5 * INST + 4] = 31; wb[5 * INST + 6] = 1; wb[5 * INST + 7] = 1.2;
        wb[5 * INST + 12] = 0.6; wb[5 * INST + 13] = 14; wb[5 * INST + 15] = 1; wb[5 * INST + 21] = 20;
        H.present(wb, 6, 0, 0, 0);
        const darkBarG = pxAt(H.renderPixels(), 80 * 3, 40 * 3)[1];

        H.renderInit(160, 80, 2);
        const adC = [];
        for (let bi = 0; bi < 2; bi++) {
          const bgv = bi ? 1 : 0;
          rect(fg, 0, 0, 0, 160, 80, 0, bgv, bgv, bgv, 1, 0);
          rect(fg, INST, 14, 9, 132, 62, 6, 253 / 255, 252 / 255, 253 / 255, 1.0, -153 - bi);
          fg[INST + 4] = 24; fg[INST + 6] = 1; fg[INST + 7] = 1.2;
          fg[INST + 12] = 0.6; fg[INST + 13] = 14; fg[INST + 14] = -1; fg[INST + 15] = 1; fg[INST + 21] = 20;
          H.present(fg, 2, bgv, bgv, bgv);
          const cad = pxAt(H.renderPixels(), 80 * 2, 40 * 2);
          adC.push([cad[0], cad[1], cad[2]]);
        }
        let adDiff = 0;
        for (let c = 0; c < 3; c++) adDiff = Math.max(adDiff, Math.abs(adC[0][c] - adC[1][c]));

        const sord = [];
        for (let oi = 0; oi < 2; oi++) {
          const so = new Float32Array(4 * INST);
          rect(so, 0, 0, 0, 160, 80, 0, 0.95, 0.94, 0.91, 1, 0);
          rect(so, INST, 0, 36, 160, 8, 0, 0.05, 0.05, 0.05, 1, 0);
          const li = oi === 0 ? 2 : 3, di = oi === 0 ? 3 : 2;
          rect(so, li * INST, 8, 9, 64, 62, 6, 253 / 255, 252 / 255, 253 / 255, 0x67 / 255, -156 - oi);
          so[li * INST + 4] = 31; so[li * INST + 6] = 1; so[li * INST + 7] = 1.2;
          so[li * INST + 12] = 0.6; so[li * INST + 13] = 14; so[li * INST + 15] = 1; so[li * INST + 21] = 20;
          rect(so, di * INST, 88, 9, 64, 62, 6, 32 / 255, 32 / 255, 32 / 255, 0x67 / 255, -156 - oi);
          so[di * INST + 4] = 31; so[di * INST + 6] = 1; so[di * INST + 7] = 1.2;
          so[di * INST + 12] = 0.6; so[di * INST + 13] = 14; so[di * INST + 15] = 1; so[di * INST + 21] = 20;
          H.present(so, 4, 0.95, 0.94, 0.91);
          sord.push(H.renderPixels());
        }
        let ordDiff = 0;
        for (let i = 0; i < sord[0].length; i++) ordDiff = Math.max(ordDiff, Math.abs(sord[0][i] - sord[1][i]));

        let darkMonoOk = true, prevDl = -1, darkY20L = 0, darkY40L = 0, darkMidL = 0, darkWtL2 = 0;
        for (let gi = 0; gi <= 20; gi++) {
          const gv = gi / 20;
          rect(fg, 0, 0, 0, 160, 80, 0, gv, gv, gv, 1, 0);
          rect(fg, INST, 14, 9, 132, 62, 6, 32 / 255, 32 / 255, 32 / 255, 0x80 / 255, -160 - gi);
          fg[INST + 4] = 24; fg[INST + 6] = 1; fg[INST + 7] = 14;
          fg[INST + 12] = 0.6; fg[INST + 13] = 20; fg[INST + 14] = 0; fg[INST + 15] = 1; fg[INST + 21] = 16;
          H.present(fg, 2, gv, gv, gv);
          const dl = lumaOf(pxAt(H.renderPixels(), 80 * 2, 40 * 2));
          if (prevDl >= 0 && dl < prevDl - 0.1) darkMonoOk = false;
          prevDl = dl;
          if (gi === 4) darkY20L = dl;
          if (gi === 8) darkY40L = dl;
          if (gi === 11) darkMidL = dl;
          if (gi === 20) darkWtL2 = dl;
        }

        let lightMonoOk = true, prevLl = -1, lightBlkL = 0, lightY60L = 0, lightY80L = 0;
        for (let gi = 0; gi <= 20; gi++) {
          const gv = gi / 20;
          rect(fg, 0, 0, 0, 160, 80, 0, gv, gv, gv, 1, 0);
          rect(fg, INST, 14, 9, 132, 62, 6, 253 / 255, 252 / 255, 253 / 255, 0x80 / 255, -200 - gi);
          fg[INST + 4] = 24; fg[INST + 6] = 1; fg[INST + 7] = 14;
          fg[INST + 12] = 0.6; fg[INST + 13] = 20; fg[INST + 14] = 0; fg[INST + 15] = 1; fg[INST + 21] = 16;
          H.present(fg, 2, gv, gv, gv);
          const ll = lumaOf(pxAt(H.renderPixels(), 80 * 2, 40 * 2));
          if (prevLl >= 0 && ll < prevLl - 0.1) lightMonoOk = false;
          prevLl = ll;
          if (gi === 0) lightBlkL = ll;
          if (gi === 12) lightY60L = ll;
          if (gi === 16) lightY80L = ll;
        }

        const linSrgb = (v) => (v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
        const accL = 0.2126 * linSrgb(0x98 / 255) + 0.7152 * linSrgb(0x2E / 255) + 0.0722 * linSrgb(0x01 / 255);
        let chkCrBlk = 0, chkCrBlu = 0;
        const rowB = new Float32Array(3 * INST);
        for (let bi = 0; bi < 2; bi++) {
          const br = 0, bg = bi ? 0x7A / 255 : 0, bb = bi ? 1 : 0;
          rect(rowB, 0, 0, 0, 160, 80, 0, br, bg, bb, 1, 0);
          rect(rowB, INST, 14, 9, 132, 62, 6, 253 / 255, 252 / 255, 253 / 255, 0x80 / 255, -230 - bi);
          rowB[INST + 4] = 24; rowB[INST + 6] = 1; rowB[INST + 7] = 14;
          rowB[INST + 12] = 0.6; rowB[INST + 13] = 20; rowB[INST + 14] = 0; rowB[INST + 15] = 1; rowB[INST + 21] = 16;
          rect(rowB, 2 * INST, 24, 22, 112, 36, 0, 0x24 / 255, 0x27 / 255, 0x2B / 255, 0x0F / 255, 0);
          rowB[2 * INST + 4] = 14;
          H.present(rowB, 3, br, bg, bb);
          const crp = pxAt(H.renderPixels(), 80 * 2, 40 * 2);
          const rowL = 0.2126 * linSrgb(crp[0] / 255) + 0.7152 * linSrgb(crp[1] / 255) + 0.0722 * linSrgb(crp[2] / 255);
          const crv = (Math.max(rowL, accL) + 0.05) / (Math.min(rowL, accL) + 0.05);
          if (bi === 0) chkCrBlk = crv; else chkCrBlu = crv;
        }

        H.renderInit(200, 160, 3);
        const sh = new Float32Array(3 * INST);
        rect(sh, 0, 0, 0, 200, 160, 0, 244 / 255, 241 / 255, 234 / 255, 1, 0);
        sh[18] = 200; sh[19] = 160;
        rect(sh, INST, 20, 46, 160, 100, 2, 0, 0, 0, 0x18 / 255, 0);
        sh[INST + 4] = 24; sh[INST + 7] = 14; sh[INST + 12] = 1; sh[INST + 13] = 6;
        sh[INST + 18] = 200; sh[INST + 19] = 160;
        sh[INST + 36] = 24; sh[INST + 37] = 24; sh[INST + 38] = 24; sh[INST + 39] = 24;
        rect(sh, 2 * INST, 20, 40, 160, 100, 6, 253 / 255, 252 / 255, 253 / 255, 0x80 / 255, -190);
        sh[2 * INST + 4] = 24; sh[2 * INST + 6] = 1; sh[2 * INST + 7] = 14;
        sh[2 * INST + 12] = 0.6; sh[2 * INST + 13] = 20; sh[2 * INST + 15] = 1;
        sh[2 * INST + 18] = 200; sh[2 * INST + 19] = 160; sh[2 * INST + 21] = 16;
        sh[2 * INST + 36] = 24; sh[2 * INST + 37] = 24; sh[2 * INST + 38] = 24; sh[2 * INST + 39] = 24;
        H.present(sh, 3, 244 / 255, 241 / 255, 234 / 255);
        const psh = H.renderPixels();
        let shMaxJump = 0, shPrev = -1;
        for (let py = 60; py <= 114; py++) {
          const sl = lumaOf(pxAt(psh, 100 * 3, py));
          if (shPrev >= 0 && (sl - shPrev) > shMaxJump) shMaxJump = sl - shPrev;
          shPrev = sl;
        }
        roi.v15_unified_v9 = { k2G, darkBarG, adDiff, ordDiff, darkMonoOk, darkY20L, darkY40L, darkMidL, darkWtL2, lightMonoOk, lightBlkL, lightY60L, lightY80L, chkCrBlk, chkCrBlu, shMaxJump };
      }
      H.renderInit(VW, VH, 2);
    }
  }
  // V11-AA & V11-Wall: Switch ON (Dark & Light, 3x & 2x, shadow-free)
  roi.v11_aa = [];
  roi.v11_wall = [];
  roi.v9_left_horn = [];
  for (const isLight of [false, true]) {
    const bg = isLight ? 1.0 : 28 / 255, bgB = isLight ? 1.0 : 30 / 255;
    const trR = isLight ? 52 / 255 : 48 / 255, trG = isLight ? 199 / 255 : 209 / 255, trB = isLight ? 89 / 255 : 88 / 255;
    for (const sc of [3, 2]) {
      H.renderInit(120, 65, sc);
      const buf = new Float32Array(3 * INST);
      rect(buf, 0, 0, 0, 120, 65, 0, bg, bg, bgB, 1, 0);
      rect(buf, INST, 18.5, 18.0, 63.0, 28.0, 0, trR, trG, trB, 1, 0);
      buf[INST + 4] = 14;
      buf[INST + 36] = 14; buf[INST + 37] = 14; buf[INST + 38] = 14; buf[INST + 39] = 14;
      rect(buf, 2 * INST, 31.58, 12.8, 59.2, 38.4, 6, 1, 1, 1, 0, -72 - (isLight ? 2 : 0) - (sc === 2 ? 1 : 0));
      buf[2 * INST + 4] = 19.2; buf[2 * INST + 6] = 1; buf[2 * INST + 7] = -32;
      buf[2 * INST + 12] = 1; buf[2 * INST + 13] = 9; buf[2 * INST + 15] = 1; buf[2 * INST + 21] = 9;
      H.present(buf, 3, bg, bg, bgB);
      const shot = H.renderPixels();
      const yLo = Math.ceil((32.0 - 0.52 * 19.2) * sc - 0.5);
      const yHi = Math.floor((32.0 + 0.52 * 19.2) * sc - 0.5);
      const xl0 = sc === 3 ? 89 : 58, xl1 = sc === 3 ? 109 : 74;
      const xr0 = sc === 3 ? 259 : 170, xr1 = sc === 3 ? 281 : 188;
      const minL = [], minR = [];
      for (let py = yLo; py <= yHi; py++) {
        let ml = 1e9, mr = 1e9;
        for (let xpx = xl0; xpx <= xl1; xpx++) { const L = lumaOf(pxAt(shot, xpx, py)); if (L < ml) ml = L; }
        for (let xpx = xr0; xpx <= xr1; xpx++) { const L = lumaOf(pxAt(shot, xpx, py)); if (L < mr) mr = L; }
        minL.push(ml); minR.push(mr);
      }
      let d2L = 0, d2R = 0;
      for (let i = 1; i < minL.length - 1; i++) {
        d2L = Math.max(d2L, Math.abs(minL[i - 1] - 2 * minL[i] + minL[i + 1]));
        d2R = Math.max(d2R, Math.abs(minR[i - 1] - 2 * minR[i] + minR[i + 1]));
      }
      roi.v11_aa.push({ isLight, sc, yLo, yHi, d2L, d2R });
      if (sc === 3) {
        const cyPx = 32 * 3;
        let rxMin = 271, rMinL = 1e9;
        for (let xpx = 268; xpx <= 272; xpx++) {
          const L = lumaOf(pxAt(shot, xpx, cyPx));
          if (L < rMinL) { rMinL = L; rxMin = xpx; }
        }
        const rc0 = pxAt(shot, rxMin, cyPx);
        const rGr = rc0[1] - rc0[0];
        const l1 = lumaOf(pxAt(shot, rxMin - 1, cyPx));
        const l2 = lumaOf(pxAt(shot, rxMin - 2, cyPx));
        const l3 = lumaOf(pxAt(shot, rxMin - 3, cyPx));
        const l4 = lumaOf(pxAt(shot, rxMin - 4, cyPx));
        const rMono = (l1 >= rMinL && l2 >= l1 && l3 >= l2 && l4 >= l3);
        let bestGr = -999, bestG = 0;
        for (let xpx = 94; xpx <= 98; xpx++) {
          const c = pxAt(shot, xpx, cyPx);
          const gr = c[1] - c[0];
          if (gr > bestGr && c[1] >= 125 && c[1] <= 165) { bestGr = gr; bestG = c[1]; }
        }
        roi.v11_wall.push({ isLight, rMinL, rxMin, rGr, rMono, l1, l2, l3, l4, bestG, bestGr });
        const horn = [];
        for (let dx = 6; dx <= 20; dx += 2) {
          const pc = Math.round((31.58 + dx) * 3);
          const dyc = Math.sqrt(Math.max(19.2 * 19.2 - Math.max(19.2 - dx, 0) ** 2, 0));
          const y0 = Math.round((32.0 - dyc + 1.0) * 3);
          const y1 = Math.round(32.0 * 3);
          let best = 0, cur = 0;
          for (let py = y0; py < y1; py++) {
            const c = pxAt(shot, pc, py);
            if (c[1] - c[0] < 26) { cur++; if (cur > best) best = cur; } else cur = 0;
          }
          horn.push({ dx, mpt: best / 3.0 });
        }
        roi.v9_left_horn.push({ isLight, horn });
      }
    }
  }
  // V11-Top: Registered 3x & 2x top-wall at 5.00pt & 5.20pt (Dark & Light)
  roi.v11_top = [];
  for (const isLight of [false, true]) {
    const bg = isLight ? 1.0 : 28 / 255, bgB = isLight ? 1.0 : 30 / 255;
    const trR = isLight ? 52 / 255 : 48 / 255, trG = isLight ? 199 / 255 : 209 / 255, trB = isLight ? 89 / 255 : 88 / 255;
    for (const off of [5.00, 5.20]) {
      const th = 38.4 - 2.0 * off;
      for (const sc of [3, 2]) {
        H.renderInit(VW, VH, sc);
        const buf = new Float32Array(3 * INST);
        rect(buf, 0, 0, 0, VW, VH, 0, bg, bg, bgB, 1, 0);
        rect(buf, INST, 40.0, 21.0 + off, 63.0, th, 0, trR, trG, trB, 1, 0);
        buf[INST + 4] = th * 0.5;
        buf[INST + 36] = th * 0.5; buf[INST + 37] = th * 0.5; buf[INST + 38] = th * 0.5; buf[INST + 39] = th * 0.5;
        rect(buf, 2 * INST, 52.9, 21.0, 59.2, 38.4, 6, 1, 1, 1, 0, -80 - (isLight ? 4 : 0) - (off > 5.1 ? 2 : 0) - (sc === 2 ? 1 : 0));
        buf[2 * INST + 4] = 19.2; buf[2 * INST + 6] = 1; buf[2 * INST + 7] = -32;
        buf[2 * INST + 12] = 1; buf[2 * INST + 13] = 9; buf[2 * INST + 15] = 1; buf[2 * INST + 21] = 9;
        H.present(buf, 3, bg, bg, bgB);
        const shot = H.renderPixels();
        const r0 = pxAt(shot, 80 * sc, 21 * sc + 0);
        const r1 = pxAt(shot, 80 * sc, 21 * sc + 1);
        const r2 = pxAt(shot, 80 * sc, 21 * sc + 2);
        roi.v11_top.push({
          isLight, off, sc,
          gr0: r0[1] - r0[0], l0: lumaOf(r0),
          gr1: r1[1] - r1[0],
          gr2: r2[1] - r2[0], l2: lumaOf(r2),
        });
      }
    }
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
    check(v.r >= 30 && v.r <= 38 && v.g >= 30 && v.g <= 38 && v.b >= 30 && v.b <= 38, `${v.name} out of (34,34,34)+/-4`);
  } else if (v.name === 'dark_1b1c1f') {
    check(v.r >= 53 && v.r <= 63 && v.g >= 54 && v.g <= 64 && v.b >= 57 && v.b <= 67, `${v.name} out of (58,59,62)+/-5`);
  } else if (v.name === 'dark_ad_white') {
    check(v.r >= 166 && v.r <= 182 && v.g >= 166 && v.g <= 182 && v.b >= 166 && v.b <= 182, `${v.name} out of (174,174,174)+/-8`);
  } else if (v.name === 'light_blue') {
    const mx = Math.max(v.r, v.g, v.b), mn = Math.min(v.r, v.g, v.b);
    const sat = mx > 0 ? (mx - mn) / mx : 0;
    check(Math.abs(v.r - 88) <= 12 && Math.abs(v.g - 205) <= 12 && v.b >= 243 && sat >= 0.62,
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
  check(s.maxBh >= 9.5 && s.maxBh <= 12.5, `${k} maxBh=${s.maxBh}`);
  check(s.peakDx >= 0.33 && s.peakDx <= 1.50, `${k} peakDx=${s.peakDx}`);
  check(s.h55 >= 5.6 && s.h55 <= 6.4, `${k} h55=${s.h55}`);
  check(s.maxGh >= 9.5 && s.maxGh <= 12.5, `${k} maxGh=${s.maxGh}`);
  check(s.greyPeakDx >= 0.33 && s.greyPeakDx <= 1.50, `${k} greyPeakDx=${s.greyPeakDx}`);
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
check(roi.v9_seg.topBR >= 10 && roi.v9_seg.botBR >= 10 && roi.v9_seg.lftRB >= 20 && roi.v9_seg.rgtRB >= 20 && roi.v9_seg.textDiff === 0 &&
  roi.v9_seg.strokeSpan >= 35 && roi.v9_seg.strokeSpan <= 37 &&
  roi.v9_seg.pinchOutL > 240 && roi.v9_seg.pinchInL < 215,
  `v9_seg=${JSON.stringify(roi.v9_seg)}`);
check(Math.abs(roi.v9_sw_green_ctr[0] - 57) <= 2 && Math.abs(roi.v9_sw_green_ctr[1] - 218) <= 2 && Math.abs(roi.v9_sw_green_ctr[2] - 97) <= 2,
  `v9_sw_green_ctr=${JSON.stringify(roi.v9_sw_green_ctr)}`);
check(roi.v9_sw_blue_caustic[2] - roi.v9_sw_blue_caustic[0] >= 100 && roi.v9_sw_blue_caustic[2] > roi.v9_sw_blue_caustic[1],
  `v9_sw_blue_caustic=${JSON.stringify(roi.v9_sw_blue_caustic)}`);
check(roi.v9_sw_off_moat[0] > roi.v9_sw_off_moat[1] && roi.v9_sw_off_moat[1] >= 1,
  `v9_sw_off_moat=${JSON.stringify(roi.v9_sw_off_moat)}`);
check(roi.v9_sw_5press_delta_area[0] < roi.v9_sw_5press_delta_area[1] && roi.v9_sw_5press_delta_area[1] < roi.v9_sw_5press_delta_area[2] && roi.v9_sw_5press_delta_area[2] < roi.v9_sw_5press_delta_area[3] && roi.v9_sw_5press_delta_area[3] < roi.v9_sw_5press_delta_area[4],
  `v9_sw_5press_delta_area=${JSON.stringify(roi.v9_sw_5press_delta_area)}`);
check(roi.v9_tab_icon_delta.midDelta >= 40 && roi.v9_tab_icon_delta.outDiff === 0, `v9_tab_icon_delta=${JSON.stringify(roi.v9_tab_icon_delta)}`);
check(roi.v9_tab_no_ghost.origL > 220.0 && roi.v9_tab_no_ghost.refrMinL < 170.0, `v9_tab_no_ghost=${JSON.stringify(roi.v9_tab_no_ghost)}`);
check(roi.v9_switch_frost_continuity.maxDEps <= 2 && roi.v9_switch_frost_continuity.maxDVeil <= 10 && roi.v9_switch_frost_continuity.maxDBlur <= 10 && roi.v9_switch_frost_continuity.ctr60[0] > roi.v9_switch_frost_continuity.ctr0[0] + 25 && (roi.v9_switch_frost_continuity.ctr60[1] - roi.v9_switch_frost_continuity.ctr60[0]) < (roi.v9_switch_frost_continuity.ctr0[1] - roi.v9_switch_frost_continuity.ctr0[0]) - 20, `v9_switch_frost_continuity=${JSON.stringify(roi.v9_switch_frost_continuity)}`);
check(roi.v9_sw_2x[0] > 40 && roi.v9_sw_2x[1] > 40, `v9_sw_2x=${JSON.stringify(roi.v9_sw_2x)}`);
check(roi.v10_reg_light.maxD2 <= 14.0 && roi.v10_reg_light.sideLmin >= 150.0 && roi.v10_reg_light.sideLmin <= 176.0 && roi.v10_reg_light.lightOuterTopL <= roi.v10_reg_light.lightMidL - 15.0 && roi.v10_reg_light.lightTopL >= roi.v10_reg_light.lightMidL,
  `v10_reg_light=${JSON.stringify(roi.v10_reg_light)}`);
check(roi.v10_reg_dark.lTop > roi.v10_reg_dark.lMid + 20.0 && roi.v10_reg_dark.lSideOut <= 14.0 && roi.v10_reg_dark.lSideOut < roi.v10_reg_dark.lMid - 40.0 && roi.v10_reg_dark.lSideIn >= roi.v10_reg_dark.lMid - 6.0 && roi.v10_reg_dark.roiFnv1a === '0x5d82a685fcc7ca94',
  `v10_reg_dark=${JSON.stringify(roi.v10_reg_dark)}`);
check(roi.v12_reg_antismear.delta >= 4.0 && roi.v12_reg_antismear.minL >= 170.0,
  `v12_reg_antismear=${JSON.stringify(roi.v12_reg_antismear)}`);
check(roi.v11_unified_panel_glass.midBR >= 24 && roi.v11_unified_panel_glass.rimL >= roi.v11_unified_panel_glass.midL + 4.0 && roi.v11_unified_panel_glass.solidDL <= 1.0 &&
  roi.v11_unified_panel_glass.l72 >= roi.v11_unified_panel_glass.l60 + 2.0 &&
  roi.v11_unified_panel_glass.l72CD >= roi.v11_unified_panel_glass.l60CD + 1.0 &&
  roi.v11_unified_panel_glass.d80BR >= 90 && roi.v11_unified_panel_glass.ccBR < roi.v11_unified_panel_glass.d80BR - 25 &&
  roi.v11_unified_panel_glass.darkWhiteL <= 102.0 &&
  roi.v11_unified_panel_glass.ctrlMaxDiff === 0 && roi.v11_unified_panel_glass.ctrlHashEq,
  `v11_unified_panel_glass=${JSON.stringify(roi.v11_unified_panel_glass)}`);
check(roi.v13_menu_morph_dual_w.wStart >= 0.80 && roi.v13_menu_morph_dual_w.wStart <= 0.88 && roi.v13_menu_morph_dual_w.wEnd === 0 &&
  roi.v13_menu_morph_dual_w.maxStepL <= 0.06 && roi.v13_menu_morph_dual_w.maxStepD <= 0.06 && roi.v13_menu_morph_dual_w.maxStepT <= 0.07,
  `v13_menu_morph_dual_w=${JSON.stringify(roi.v13_menu_morph_dual_w)}`);
check(roi.v13_dual_k1.g44.dualScale && Math.abs(roi.v13_dual_k1.g44.dualW - 0.68) < 0.01 && roi.v13_dual_k1.g44.k === 1 && roi.v13_dual_k1.g44.sg === 0 &&
  roi.v13_dual_k1.g62.dualScale && Math.abs(roi.v13_dual_k1.g62.dualW - 0.86) < 0.01 && roi.v13_dual_k1.g62.k === 1 && roi.v13_dual_k1.g62.sg === 0 &&
  !roi.v13_dual_k1.gclr.dualScale && roi.v13_dual_k1.gclr.k === 1 && roi.v13_dual_k1.gclr.sg > 0.3,
  `v13_dual_k1=${JSON.stringify(roi.v13_dual_k1)}`);
check(roi.v14_opus_gates.tintSideL <= 14.0 &&
  roi.v14_opus_gates.topD[0] <= 50.0 && roi.v14_opus_gates.top2D[0] <= 28.0 &&
  roi.v14_opus_gates.topD[1] <= 38.0 && roi.v14_opus_gates.top2D[1] <= 18.0 &&
  roi.v14_opus_gates.topAbs[2] >= 252.0 && roi.v14_opus_gates.clrMinL >= 254.0,
  `v14_opus_gates=${JSON.stringify(roi.v14_opus_gates)}`);
check(roi.v13c_sigma_cont.minMorphDsig >= -1e-4 && roi.v13c_sigma_cont.maxMorphDsig <= 0.30 &&
  roi.v13c_sigma_cont.minV9Dsig >= -1e-4 && roi.v13c_sigma_cont.maxV9Dsig <= 0.45 &&
  roi.v13c_sigma_cont.maxSzDsig <= 0.30,
  `v13c_sigma_cont=${JSON.stringify(roi.v13c_sigma_cont)}`);
for (const sh of roi.v14b_scroll_shimmer) {
  check(sh.maxD <= 3.0, `v14b_scroll_shimmer=${JSON.stringify(sh)}`);
}
check(roi.v14c_dual_slot_midsg.dualScale && roi.v14c_dual_slot_midsg.k === 1 &&
  roi.v14c_dual_slot_midsg.sg > 0.30 && roi.v14c_dual_slot_midsg.sg <= 0.55 &&
  roi.v14c_dual_slot_midsg.barL >= 185.0 && (roi.v14c_dual_slot_midsg.whL - roi.v14c_dual_slot_midsg.barL) <= 65.0 &&
  roi.v14c_dual_slot_midsg.cacheDiff === 0,
  `v14c_dual_slot_midsg=${JSON.stringify(roi.v14c_dual_slot_midsg)}`);
check(Math.abs(roi.v15_unified_v9.k2G - 195) <= 2 &&
  roi.v15_unified_v9.darkBarG <= 150 &&
  roi.v15_unified_v9.adDiff <= 1 &&
  roi.v15_unified_v9.ordDiff === 0 &&
  roi.v15_unified_v9.darkMonoOk && roi.v15_unified_v9.darkWtL2 <= 102.0 &&
  (roi.v15_unified_v9.darkWtL2 - roi.v15_unified_v9.darkY40L) >= 6.0 &&
  (roi.v15_unified_v9.darkWtL2 - roi.v15_unified_v9.darkY20L) >= 24.0 &&
  roi.v15_unified_v9.lightMonoOk && roi.v15_unified_v9.lightBlkL >= 198.0 &&
  (roi.v15_unified_v9.lightY60L - roi.v15_unified_v9.lightBlkL) >= 10.0 &&
  (roi.v15_unified_v9.lightY80L - roi.v15_unified_v9.lightBlkL) >= 26.0 &&
  roi.v15_unified_v9.chkCrBlk >= 3.0 && roi.v15_unified_v9.chkCrBlu >= 3.0 &&
  roi.v15_unified_v9.shMaxJump < 2.5,
  `v15_unified_v9=${JSON.stringify(roi.v15_unified_v9)}`);
for (const a of roi.v11_aa) {
  const lim = a.sc === 3 ? (a.isLight ? 12.0 : 10.0) : (a.isLight ? 14.0 : 12.0);
  check(a.d2L <= lim && a.d2R <= lim, `v11_aa=${JSON.stringify(a)} lim=${lim}`);
}
for (const w of roi.v11_wall) {
  if (!w.isLight) check(w.rMinL <= 14.0 && w.rGr <= 12 && w.rMono, `v11_wall_dark=${JSON.stringify(w)}`);
  else check(w.rMinL >= 170.0 && w.rMinL <= 205.0 && w.rMono && w.l4 >= 230.0, `v11_wall_light=${JSON.stringify(w)}`);
  check(w.bestGr >= 90 && w.bestG >= 125 && w.bestG <= 165, `v11_wall_emerald=${JSON.stringify(w)}`);
}
for (const g of roi.v9_left_horn) {
  let prevMoat = -1;
  for (const h of g.horn) {
    if (h.dx === 6 || h.dx === 8) check(h.mpt === 0, `v9_left_horn(${g.isLight})=${JSON.stringify(h)}`);
    if (h.dx === 10) check(h.mpt >= 1.5 && h.mpt <= 4.5, `v9_left_horn(${g.isLight})=${JSON.stringify(h)}`);
    if (h.dx >= 12 && prevMoat >= 0) check(h.mpt >= prevMoat - 0.35 && h.mpt - prevMoat <= 3.5, `v9_left_horn(${g.isLight})=${JSON.stringify(h)} prev=${prevMoat}`);
    if (h.dx === 20) check(h.mpt >= 7.0, `v9_left_horn_end(${g.isLight})=${JSON.stringify(h)}`);
    prevMoat = h.mpt;
  }
}
for (const t of roi.v11_top) {
  if (t.sc === 3) {
    if (!t.isLight) check(t.gr0 < 15 && t.l0 <= 35 && t.gr1 >= 100 && t.gr2 < 15 && t.l2 >= 75, `v11_top=${JSON.stringify(t)}`);
    else check(t.gr0 < 15 && t.l0 >= 180 && t.l0 <= 215 && t.gr1 >= 95 && t.gr2 < 15 && t.l2 >= 245, `v11_top=${JSON.stringify(t)}`);
  } else {
    check(t.gr1 >= 70 && t.gr2 < 15, `v11_top=${JSON.stringify(t)}`);
  }
}
if (failed) process.exit(1);
console.log('web_glass_test: ok');
