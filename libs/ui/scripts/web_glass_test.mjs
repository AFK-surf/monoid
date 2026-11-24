// Production WebGL2 shader (web/host.js) P0 Regular Liquid Glass 5+2 numerical vector readback test
// in headless Chromium on SwiftShader (same rasterizer as scripts/render_web.mjs):
//   node scripts/web_glass_test.mjs
import { createRequire } from 'node:module';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);
function loadPlaywright() {
  const candidates = [
    process.env.PLAYWRIGHT_MODULE,
    path.resolve('out/node/node_modules/playwright'),
    'playwright',
    'playwright-core',
  ].filter(Boolean);
  for (const c of candidates) {
    try {
      return require(c);
    } catch {}
  }
  throw new Error('web_glass_test: playwright not found (set PLAYWRIGHT_MODULE or install in out/node)');
}

const { chromium } = loadPlaywright();
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

const launchOpts = { args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] };
if (process.env.CHROMIUM_EXECUTABLE_PATH) launchOpts.executablePath = process.env.CHROMIUM_EXECUTABLE_PATH;
const browser = await chromium.launch(launchOpts);
const page = await (await browser.newContext({ viewport: { width: 256, height: 256 }, deviceScaleFactor: 1 })).newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));

await page.goto(`http://127.0.0.1:${server.address().port}/glass-test.html`);

const results = await page.evaluate(() => {
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
  return { gl: H.renderInfo(), out };
});

await browser.close();
server.close();

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
if (failed) process.exit(1);
console.log('web_glass_test: ok');
