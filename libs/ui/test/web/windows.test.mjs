// The windows of one run in a browser (web/host.js H.windows; host_js.mbt's windows, @hostapi.windows_in_process,
// window_open_id …): a popup of the page's origin opened beside it, drawn with a WebGL 2 context of its own (the glyph
// atlas the run's: one put before it opened and one put after both drawn in it, read back off its canvas), its frames
// and input handed to the app as that window's (H.windows(4)), its title its own, and the app told as the person
// closes it (outside 17), the page drawing on. Real Chromium (Playwright's, headless, SwiftShader's WebGL 2) runs the
// real host.js; each step waits for what the page says it did (its log), never for a time.
//   node --test test/web/windows.test.mjs   (Playwright from out/node, as scripts/web.sh sets it up, or the module's)
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import { createRequire } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const hostJs = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

function playwright() {
  for (const p of [new URL('../../out/node/node_modules/playwright', import.meta.url).pathname, 'playwright', 'playwright-core']) {
    try { return require(p); } catch (e) { /* the next */ }
  }
  return null;
}

// The page: web/index.html's canvas and textarea, host.js, and an app of a few lines: each window's frame draws two
// glyphs white on a ground of its own (the page's blue, a window beside it red), and reads back what it drew.
const PAGE = `<!doctype html><html><head><meta charset="utf-8"><title>main</title>
<style>html,body{margin:0;height:100%;overflow:hidden;background:#F5F5F7}
#c{position:fixed;inset:0;width:100%;height:100%;display:block;touch-action:none}
#ime{position:fixed;left:0;top:0;width:2px;height:20px;opacity:0;padding:0;border:0}</style></head>
<body><canvas id="c"></canvas><textarea id="ime"></textarea>
<script>
  // (the popups host.js opens, for the app's frames to read back what they drew)
  window.__popups = [];
  const open = window.open.bind(window);
  window.open = (...a) => { const w = open(...a); if (w) window.__popups.push(w); return w; };
</script>
<script src="/host.js"></script>
<script>
  const H = window.__mbhost;
  const log = window.__t = { frames: [], inputs: [], outside: [] };
  H.setOutside((kind, id, state) => { log.outside.push([kind, id, state]); });
  const INST = 60, out = new Float32Array(8);
  // glyph A put in the page's first frame, before any window opened; B in the first frame of a window beside it
  const glyphs = [];
  const put = (c, x) => {
    const key = H.textKey(c, 48, 700, 0);
    H.glyph(key, out);
    const g = { x, w: out[2], h: out[3], ox: out[4], oy: out[5] };
    H.glyphPut(key, x, 0);
    glyphs.push(g);
  };
  const box = (i) => ({ x: 20 + i * 100, y: 20, w: glyphs[i].w, h: glyphs[i].h });
  function frame(w, h, scale, t) {
    const wid = H.windows(4, 0, '');
    if (glyphs.length === 0) put('W', 0);
    if (glyphs.length === 1 && wid !== 0) put('M', 128);
    const buf = new Float32Array(INST * glyphs.length);
    glyphs.forEach((g, i) => {
      const a = i * INST, b = box(i);
      buf.set([b.x, b.y, b.w, b.h], a);
      buf[a + 5] = 1;
      buf.set([1, 1, 1, 1], a + 8);
      buf.set([g.x, 0, g.w * scale, g.h * scale], a + 12);
      buf.set([-1e9, -1e9, 1e9, 1e9], a + 16);
    });
    const ground = wid === 0 ? [0.1, 0.2, 0.6] : [0.6, 0.1, 0.1];
    H.present(buf, glyphs.length, ...ground);
    // read back now, before the browser shows it (its drawing buffer is not kept past this task)
    const canvas = wid === 0 ? document.getElementById('c') : window.__popups.at(-1).document.querySelector('canvas');
    const gl = canvas.getContext('webgl2');
    const W = canvas.width, Hh = canvas.height, px = new Uint8Array(W * Hh * 4);
    gl.readPixels(0, 0, W, Hh, gl.RGBA, gl.UNSIGNED_BYTE, px);
    const at = (x, y) => { const i = ((Hh - 1 - y) * W + x) * 4; return [px[i], px[i + 1], px[i + 2]]; };
    const lit = (i) => {
      if (!glyphs[i]) return -1;
      const b = box(i);
      let n = 0;
      for (let y = Math.floor(b.y * scale); y < Math.ceil((b.y + b.h) * scale); y++) {
        for (let x = Math.floor(b.x * scale); x < Math.ceil((b.x + b.w) * scale); x++) {
          const [r, g, bl] = at(x, y);
          if (r > 200 && g > 200 && bl > 200) n++;
        }
      }
      return n;
    };
    log.frames.push({ wid, w, h, canvas: [W, Hh], a: lit(0), b: lit(1), ground: at(W - 2, Hh - 2) });
  }
  const said = (what) => (...a) => log.inputs.push([what, H.windows(4, 0, ''), ...a]);
  H.run('main', frame, said('pointer'), said('wheel'), said('key'), said('text'));
</script></body></html>`;

test('a window beside the page: its own frames, drawing, input and title, and the app told as it is closed', async (t) => {
  const pw = playwright();
  if (!pw) { t.skip('no Playwright (scripts/web.sh sets it up in out/node)'); return; }
  const server = http.createServer((req, res) => {
    const js = req.url.startsWith('/host.js');
    res.writeHead(js || req.url === '/' ? 200 : 404, { 'content-type': js ? 'text/javascript' : 'text/html' });
    res.end(js ? hostJs : req.url === '/' ? PAGE : '');
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const browser = await pw.chromium.launch({
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
  });
  try {
    const ctx = await browser.newContext({ viewport: { width: 800, height: 600 }, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    const errors = [];
    const watch = (p) => p.on('pageerror', (e) => errors.push(String(e)));
    watch(page);
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    const log = () => page.evaluate(() => window.__t);
    const until = (f, arg) => page.waitForFunction(f, arg, { polling: 'raf', timeout: 30000 });

    // the page drawn, glyph A in it
    await until(() => window.__t.frames.some((f) => f.wid === 0 && f.a > 20));
    assert.equal(await page.evaluate(() => window.__mbhost.windows(0, 0, '')), 1, 'windows open in this run');

    // 1. one opened: its id, its title, its first frame drawn as its own at its own size, both glyphs in its atlas
    const [popup, wid] = await Promise.all([
      page.waitForEvent('popup'),
      page.evaluate(() => window.__mbhost.windows(1, 0, JSON.stringify({ role: 'term', title: '终端 #1', w: 520, h: 380 }))),
    ]);
    watch(popup);
    assert.equal(wid, 1);
    assert.equal(await popup.title(), '终端 #1');
    assert.equal(await page.title(), 'main');
    await until(() => window.__t.frames.some((f) => f.wid === 1 && f.a > 20 && f.b > 20));
    const inner = await popup.evaluate(() => [window.innerWidth, window.innerHeight]);
    const first = (await log()).frames.find((f) => f.wid === 1);
    assert.deepEqual([first.w, first.h], inner, 'drawn at its own window\'s size');
    assert.deepEqual(first.canvas, inner, 'its own canvas, at its size');
    const [r, g, b] = first.ground;
    assert.ok(r > 130 && g < 50 && b < 50, `its own ground drawn (${first.ground})`);
    // (and the page drawn on, glyph B put in its atlas too as the window's frame drew it)
    await page.evaluate(() => window.__mbhost.requestFrame());
    await until(() => window.__t.frames.some((f, i, all) => f.wid === 0 && f.b > 20 && i > all.findIndex((x) => x.wid === 1)));
    const main = (await log()).frames.findLast((f) => f.wid === 0);
    assert.deepEqual([main.w, main.h], [800, 600]);
    assert.ok(main.ground[2] > 130 && main.ground[0] < 50, `the page's own ground (${main.ground})`);

    // 2. input: each window's as its own
    await popup.mouse.click(50, 60);
    await popup.keyboard.press('Escape');
    await until(() => window.__t.inputs.some((i) => i[0] === 'key' && i[2] === 17 && i[1] === 1));
    await page.mouse.click(30, 40);
    await page.keyboard.press('Escape');
    await until(() => window.__t.inputs.some((i) => i[0] === 'key' && i[2] === 17 && i[1] === 0));
    const inputs = (await log()).inputs;
    const presses = inputs.filter((i) => i[0] === 'pointer' && i[2] === 0);
    assert.deepEqual(presses.map((i) => [i[1], i[3], i[4]]), [[1, 50, 60], [0, 30, 40]], 'each press as its window\'s');
    assert.deepEqual(inputs.filter((i) => i[0] === 'key' && i[2] === 17).map((i) => i[1]), [1, 0]);

    // 3. a title of its own
    assert.equal(await page.evaluate(() => window.__mbhost.windows(5, 1, '新标题')), 1);
    assert.equal(await popup.title(), '新标题');
    assert.equal(await page.title(), 'main');

    // 4. closed by the person: the app told, once; the page draws on
    await page.evaluate(() => window.__popups[0].close());
    await until(() => window.__t.outside.some((o) => o[0] === 17 && o[1] === 1 && o[2] === -1));
    assert.equal(await page.evaluate(() => window.__mbhost.windows(2, 1, '')), 0, 'gone');
    const before = (await log()).frames.length;
    await page.evaluate(() => window.__mbhost.requestFrame());
    await until((n) => window.__t.frames.length > n && window.__t.frames.at(-1).wid === 0, before);
    const after = (await log()).frames.at(-1);
    assert.ok(after.a > 20 && after.b > 20, 'the page drawn as before');

    // 5. closed by the app: its id given again, not told (the app knows), its role's place kept
    const had = (await log()).frames.filter((f) => f.wid === 1).length;
    const [again, wid2] = await Promise.all([
      page.waitForEvent('popup'),
      page.evaluate(() => window.__mbhost.windows(1, 0, JSON.stringify({ role: 'term' }))),
    ]);
    watch(again);
    assert.equal(wid2, 1, 'the id told closed is free again');
    await until((n) => window.__t.frames.filter((f) => f.wid === 1).length > n, had);
    assert.equal(await page.evaluate(() => window.__mbhost.windows(3, 1, '')), 1);
    await until(() => window.__popups[1].closed);
    await page.evaluate(() => window.__mbhost.requestFrame());
    await until((n) => window.__t.frames.length > n, (await log()).frames.length);
    assert.equal((await log()).outside.filter((o) => o[0] === 17).length, 1, 'closed by the app: not told again');
    assert.equal(await page.evaluate(() => window.__mbhost.windows(2, 1, '')), 0);
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
    server.close();
  }
});

// The same contract with no browser (CI's Node: no Playwright), host.js run with as little of a page and its popups
// as it reads: what each op answers, where a window of a role opens, whose input and frames are whose, when the app
// is told of a window closed, and a site's frame shown in a window beside the page and taken back to the page.
function fakeBrowser() {
  const made = [];
  const element = (tag, owner) => {
    const el = {
      tagName: tag.toUpperCase(), ownerDocument: owner, style: {}, listeners: new Map(), children: [], parent: null,
      attributes: [], src: '',
      addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
      dispatch(name, e) { for (const f of this.listeners.get(name) || []) f(e); },
      setAttribute(n, v) { this[n] = v; },
      appendChild(child) { child.remove(); this.children.push(child); child.parent = this; return child; },
      insertBefore(child, before) {
        child.remove();
        const i = this.children.indexOf(before);
        this.children.splice(i < 0 ? this.children.length : i, 0, child);
        child.parent = this;
        return child;
      },
      remove() {
        if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1);
        this.parent = null;
      },
      get firstChild() { return this.children[0]; },
      getContext() { return gl; },
      getBoundingClientRect() { return { left: 0, top: 0, width: 400, height: 300, right: 400, bottom: 300 }; },
      setPointerCapture() {},
    };
    made.push(el);
    return el;
  };
  const gl = new Proxy({}, { get: (_, name) => {
    if (name === 'getShaderParameter' || name === 'getProgramParameter') return () => true;
    if (name === 'isContextLost') return () => true;
    return () => ({});
  } });
  const page = (title) => {
    const document = { title, listeners: new Map(), addEventListener() {} };
    document.createElement = (tag) => element(tag, document);
    document.body = element('body', document);
    document.head = element('head', document);
    document.documentElement = element('html', document);
    document.querySelector = () => null;
    return document;
  };
  const style = () => ({ borderTopLeftRadius: '0', borderTopRightRadius: '0', borderBottomRightRadius: '0',
    borderBottomLeftRadius: '0' });
  const popups = [];
  const doc = page('main');
  const canvas = doc.createElement('canvas'), ime = doc.createElement('textarea');
  doc.body.appendChild(canvas);
  doc.body.appendChild(ime);
  doc.getElementById = (id) => (id === 'c' ? canvas : ime);
  const frames = [];
  const win = {
    document: doc, navigator: { platform: 'MacIntel' }, location: { search: '', href: 'http://localhost/' },
    URL, URLSearchParams, Intl, crypto: { randomUUID: () => 'site' }, queueMicrotask, Promise,
    devicePixelRatio: 1, performance: { now: () => 0 }, requestAnimationFrame: (f) => frames.push(f),
    getComputedStyle: style, addEventListener() {}, focus() {}, console: { log() {} },
    open(url, name, features) {
      const cdoc = page('');
      const child = {
        document: cdoc, devicePixelRatio: 1, innerWidth: 400, innerHeight: 300, screenX: 100, screenY: 50,
        closed: false, url, features, frames: [], listeners: new Map(), getComputedStyle: style,
        requestAnimationFrame(f) { this.frames.push(f); return this.frames.length; },
        cancelAnimationFrame() {},
        addEventListener(n, f) { this.listeners.set(n, [...(this.listeners.get(n) || []), f]); },
        dispatch(n, e = {}) { for (const f of this.listeners.get(n) || []) f(e); },
        focus() { this.focused = true; }, resizeBy() {},
        close() { this.closed = true; this.dispatch('pagehide'); },
      };
      popups.push(child);
      return child;
    },
  };
  win.window = win;
  vm.runInNewContext(hostJs, win, { filename: 'host.js' });
  const H = win.__mbhost;
  const log = { frames: [], inputs: [], outside: [] };
  // what a window's next frame does as that window's (the app's frame, as it is handed to it)
  const todo = new Map();
  H.setOutside((kind, id, state) => log.outside.push([kind, id, state]));
  H.run('main', (w, h) => {
    const wid = H.windows(4, 0, '');
    log.frames.push([wid, w, h]);
    const f = todo.get(wid);
    todo.delete(wid);
    if (f) f();
  }, (kind, x, y) => log.inputs.push(['pointer', H.windows(4, 0, ''), kind, x, y]), () => {},
  (code) => log.inputs.push(['key', H.windows(4, 0, ''), code]), () => {});
  // the frames asked of the page and of each popup, drawn
  const draw = () => {
    for (const f of frames.splice(0)) f(0);
    for (const p of popups) for (const f of p.frames.splice(0)) f(0);
  };
  return { H, win, doc, canvas, popups, log, todo, draw, made };
}
const settle = () => new Promise((ok) => setImmediate(ok));

test('windows without a browser: ops, roles, input, closing and a site\'s frame across windows', async () => {
  const b = fakeBrowser();
  const { H, popups, log } = b;
  await settle();
  assert.equal(H.windows(0, 0, ''), 1);
  assert.equal(H.windows(4, 0, ''), 0);

  // ops 1 and 5; a role's second window a step down and right of its first
  const w1 = H.windows(1, 0, JSON.stringify({ role: 'term', title: '终端 #1', w: 520, h: 380 }));
  assert.equal(w1, 1);
  assert.equal(popups[0].url, 'about:blank');
  assert.equal(popups[0].features, 'popup=yes,width=520,height=380');
  assert.equal(popups[0].document.title, '终端 #1');
  const w2 = H.windows(1, 0, JSON.stringify({ role: 'term', w: 500, h: 360 }));
  assert.equal(w2, 2);
  assert.equal(popups[1].features, 'popup=yes,width=500,height=360,left=128,top=78');
  assert.equal(H.windows(5, 1, '新标题'), 1);
  assert.equal(popups[0].document.title, '新标题');
  assert.equal(b.doc.title, 'main');
  assert.equal(H.windows(2, 2, ''), 1);
  assert.ok(popups[1].focused);

  // frames: each window's as its own, at its own size
  b.draw();
  assert.deepEqual(log.frames.filter((f) => f[0] !== 0), [[1, 400, 300], [2, 400, 300]]);
  assert.equal(H.windows(4, 0, ''), 0, 'the page in place between them');

  // input: each window's as its own
  const down = (el) => el.dispatch('pointerdown', { pointerType: 'mouse', pointerId: 1, button: 0, clientX: 12,
    clientY: 34, timeStamp: 0, preventDefault() {} });
  const pcanvas = popups[0].document.body.children.find((e) => e.tagName === 'CANVAS');
  down(pcanvas);
  down(b.canvas);
  popups[0].dispatch('keydown', { key: 'Escape', preventDefault() {} });
  assert.deepEqual(log.inputs.filter((i) => i[0] === 'pointer' && i[2] === 0).map((i) => i[1]), [1, 0]);
  assert.deepEqual(log.inputs.filter((i) => i[0] === 'key' && i[2] === 17).map((i) => i[1]), [1]);

  // a site's frame shown in window 1: its presses' layers in that window's document, not the page's
  H.siteFrame = '/site';
  let vid = 0;
  b.todo.set(1, () => {
    vid = H.viewOpen(3, '/app');
    H.viewPlace(vid, 0, 0, 200, 150, 0, 0, 200, 150, true);
    H.viewTell(vid, 4, '10 10 50 40');
  });
  H.requestFrame();
  b.draw();
  assert.ok(vid > 0);
  const layersOf = (d) => d.body.children.map((e) => e.style.cssText).filter(Boolean);
  const pdoc = popups[0].document;
  assert.ok(layersOf(pdoc).includes('position:fixed;inset:0;z-index:0;touch-action:none'), 'under, in the popup');
  assert.ok(layersOf(pdoc).includes('position:fixed;z-index:2;touch-action:none'), 'its cover, in the popup');
  assert.ok(!layersOf(b.doc).some((c) => c.includes('touch-action:none')), 'none in the page');
  assert.equal(pcanvas.style.pointerEvents, 'none');
  assert.notEqual(b.canvas.style.pointerEvents, 'none');
  // taken back to the page (a view the app keeps): the popup's canvas takes presses again, its cover gone
  b.todo.set(0, () => H.viewPlace(vid, 0, 0, 200, 150, 0, 0, 200, 150, true));
  H.requestFrame();
  b.draw();
  assert.equal(pcanvas.style.pointerEvents, '');
  assert.ok(!layersOf(pdoc).includes('position:fixed;z-index:2;touch-action:none'));
  assert.equal(b.canvas.style.pointerEvents, 'none');
  assert.ok(layersOf(b.doc).includes('position:fixed;inset:0;z-index:0;touch-action:none'));
  H.viewClose(vid);
  assert.equal(b.canvas.style.pointerEvents, '');

  // closed by the person (its pagehide): told once, between events; its id kept till then
  popups[0].innerWidth = 610; popups[0].innerHeight = 410;
  popups[0].close();
  assert.equal(H.windows(2, 1, ''), 0);
  assert.equal(log.outside.length, 0, 'not in the middle of its event');
  await settle();
  assert.deepEqual(log.outside, [[17, 1, -1]]);
  // closed by the app (op 3): not told again; where it was kept for its role
  popups[1].innerWidth = 700; popups[1].innerHeight = 450; popups[1].screenX = 128; popups[1].screenY = 78;
  assert.equal(H.windows(3, 2, ''), 1);
  await settle();
  assert.ok(popups[1].closed);
  assert.deepEqual(log.outside, [[17, 1, -1]], 'closed by the app: not told');
  assert.equal(H.windows(2, 2, ''), 0);
  const w3 = H.windows(1, 0, JSON.stringify({ role: 'term', w: 300, h: 200 }));
  assert.equal(w3, 1, 'the id told closed given again');
  assert.equal(popups[2].features, 'popup=yes,width=700,height=450,left=128,top=78', 'where its role last closed');
  // the page draws on
  const n = log.frames.length;
  H.requestFrame();
  b.draw();
  assert.ok(log.frames.slice(n).some((f) => f[0] === 0));
});
