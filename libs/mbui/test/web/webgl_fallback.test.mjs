// web/index.html's gate before the app: where the browser gives a WebGL 2 context (let go of at once) host.js and
// demo.js are loaded in their order; where it gives none, or throws, neither is, and the page says how to turn it on in
// the browser it is (Chromium's by its scheme, Firefox, any other), without a browser.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const html = readFileSync(new URL('../../web/index.html', import.meta.url), 'utf8');
const gate = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];

const UA = {
  chrome: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36',
  edge: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36 Edg/142.0.0.0',
  opera: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36 OPR/126.0.0.0',
  firefox: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:145.0) Gecko/20100101 Firefox/145.0',
  safari: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15',
  android: 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36',
};

// A page of just what the gate touches: elements with children, text, attributes and listeners.
function page({ ua = UA.chrome, webgl = 'ok', brave = false, render = false, title = 'MoonBit UI' } = {}) {
  const lost = [], copied = [], reloaded = [];
  const node = (tag) => ({
    tag, children: [], attrs: {}, style: {}, listeners: {}, hidden: false, className: '', _text: '',
    appendChild(c) { this.children.push(c); return c; },
    setAttribute(k, v) { this.attrs[k] = v; },
    addEventListener(n, f) { (this.listeners[n] ||= []).push(f); },
    fire(n) { for (const f of this.listeners[n] || []) f({}); },
    get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); },
    set textContent(s) { this._text = s; this.children = []; },
  });
  const ids = Object.fromEntries(['c', 'ime', 'nogl', 'nogl-h', 'nogl-lead', 'nogl-steps', 'nogl-note', 'nogl-reload']
    .map((id) => [id, node(id)]));
  ids.nogl.hidden = true;
  const document = {
    title, body: node('body'),
    getElementById: (id) => ids[id],
    createTextNode: (s) => ({ textContent: s }),
    createElement(tag) {
      const e = node(tag);
      if (tag === 'canvas') e.getContext = (kind) => {
        assert.equal(kind, 'webgl2');
        if (webgl === 'throws') throw new Error('no GPU');
        if (webgl !== 'ok') return null;
        return { getExtension: (n) => n === 'WEBGL_lose_context' ? { loseContext: () => lost.push(n) } : null };
      };
      return e;
    },
  };
  const navigator = { userAgent: ua, clipboard: { writeText: (s) => { copied.push(s); return Promise.resolve(); } } };
  if (brave) navigator.brave = {};
  const win = { document, navigator, location: { reload: () => reloaded.push(1) } };
  if (render) win.__mbrender = {};
  win.globalThis = win;
  vm.runInNewContext(gate, win, { filename: 'index.html' });
  const scripts = document.body.children.filter((c) => c.tag === 'script');
  const steps = ids['nogl-steps'].children.map((li) => li.children[1].textContent);
  const copies = [];
  const walk = (e) => { if (e.tag === 'button') copies.push(e); (e.children || []).forEach(walk); };
  walk(ids['nogl-steps']);
  return { ids, scripts, steps, lost, copied, reloaded, copies };
}

test('a WebGL 2 context: host.js then demo.js, run in their order, the context asked for let go', () => {
  const p = page();
  assert.deepEqual(p.scripts.map((s) => [s.src, s.async]), [['host.js', false], ['demo.js', false]]);
  assert.deepEqual(p.lost, ['WEBGL_lose_context']);
  assert.equal(p.ids.nogl.hidden, true);
  assert.equal(p.ids.c.style.display, undefined);
});

test('a page rendering a draw list (globalThis.__mbrender) loads at once, asking for no context', () => {
  const p = page({ render: true, webgl: 'throws' });
  assert.deepEqual(p.scripts.map((s) => s.src), ['host.js', 'demo.js']);
  assert.equal(p.ids.nogl.hidden, true);
});

for (const webgl of ['none', 'throws']) {
  test(`no WebGL 2 (${webgl}): nothing of the app loaded, the canvas hidden, the page shown`, () => {
    const p = page({ webgl });
    assert.equal(p.scripts.length, 0);
    assert.equal(p.ids.nogl.hidden, false);
    assert.equal(p.ids.c.style.display, 'none');
    assert.equal(p.ids.ime.style.display, 'none');
    p.ids['nogl-reload'].fire('click');
    assert.equal(p.reloaded.length, 1);
  });
}

for (const [name, scheme, setting] of [
  ['chrome', 'chrome', 'Use graphics acceleration when available'],
  ['edge', 'edge', 'Use graphics acceleration when available'],
  ['opera', 'opera', 'Use hardware acceleration when available'],
  ['brave', 'brave', 'Use graphics acceleration when available'],
]) {
  test(`${name}: its own settings page to copy, the setting by its name, its gpu page`, () => {
    const p = page({ ua: UA[name === 'brave' ? 'chrome' : name], brave: name === 'brave', webgl: 'none' });
    assert.equal(p.ids['nogl-h'].textContent, 'Graphics acceleration is turned off');
    assert.match(p.ids['nogl-lead'].textContent, /^MoonBit UI draws with WebGL 2/);
    assert.deepEqual(p.steps, [
      `Open this address in a new tab:${scheme}://settings/systemCopy`,
      `Turn on ${setting}.`,
      'Relaunch the browser, then reload.',
    ]);
    assert.match(p.ids['nogl-note'].textContent, new RegExp(`${scheme}://gpu`));
  });
}

test('firefox: its preferences to copy, the two settings of Performance, about:support', () => {
  const p = page({ ua: UA.firefox, webgl: 'none' });
  assert.equal(p.ids['nogl-h'].textContent, 'Hardware acceleration is turned off');
  assert.match(p.steps[0], /about:preferences#general/);
  assert.match(p.steps[1], /Use recommended performance settings.*Use hardware acceleration when available/);
  assert.match(p.ids['nogl-note'].textContent, /about:support/);
});

for (const name of ['safari', 'android']) {
  test(`${name}: what any browser does, no address of another's`, () => {
    const p = page({ ua: UA[name], webgl: 'none' });
    assert.equal(p.ids['nogl-h'].textContent, 'WebGL 2 is not available');
    assert.equal(p.copies.length, 0);
    assert.doesNotMatch(p.steps.join(' '), /:\/\//);
    assert.equal(p.steps.length, 3);
  });
}

test('a page with no title is called this page', () => {
  const p = page({ webgl: 'none', title: '  ' });
  assert.match(p.ids['nogl-lead'].textContent, /^This page draws/);
});

test('copy: the address on the clipboard, Copied till the pointer or the focus leaves', async () => {
  const p = page({ webgl: 'none' });
  const [b] = p.copies;
  assert.equal(b.attrs['aria-label'], 'Copy chrome://settings/system');
  b.fire('click');
  await Promise.resolve();
  assert.deepEqual(p.copied, ['chrome://settings/system']);
  assert.equal(b.textContent, 'Copied');
  b.fire('pointerleave');
  assert.equal(b.textContent, 'Copy');
  b.fire('click');
  await Promise.resolve();
  b.fire('blur');
  assert.equal(b.textContent, 'Copy');
});
