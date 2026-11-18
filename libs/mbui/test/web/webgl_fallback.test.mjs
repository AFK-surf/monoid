// web/index.html's gate before the app: where the browser gives a WebGL 2 context (let go of at once) host.js and
// demo.js are loaded in their order; where it gives none, or throws, neither is, and the page says how to turn it on in
// the browser it is (Chromium's by its scheme, Firefox, Safari, any other), in Chinese or English by the browser's
// language, without a browser.
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
  firefoxAndroid: 'Mozilla/5.0 (Android 16; Mobile; rv:145.0) Gecko/145.0 Firefox/145.0',
};

// A page of just what the gate touches: elements with children, text, attributes and listeners.
function page({ ua = UA.chrome, language = 'en-US', webgl = 'ok', brave = false, render = false, title = 'MoonBit UI',
  clipboard = 'ok', execCommand = true } = {}) {
  const lost = [], copied = [], reloaded = [], selected = [], execs = [];
  const node = (tag) => ({
    tag, children: [], attrs: {}, style: {}, listeners: {}, hidden: false, className: '', _text: '', lang: '',
    appendChild(c) { this.children.push(c); return c; },
    removeChild(c) { this.children = this.children.filter((x) => x !== c); return c; },
    setAttribute(k, v) { this.attrs[k] = v; },
    addEventListener(n, f) { (this.listeners[n] ||= []).push(f); },
    fire(n) { for (const f of this.listeners[n] || []) f({}); },
    select() {},
    get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); },
    set textContent(s) { this._text = s; this.children = []; },
  });
  const ids = Object.fromEntries(['c', 'ime', 'nogl', 'nogl-h', 'nogl-lead', 'nogl-steps', 'nogl-note', 'nogl-retry']
    .map((id) => [id, node(id)]));
  ids.nogl.hidden = true;
  const document = {
    title, body: node('body'),
    getElementById: (id) => ids[id],
    createTextNode: (s) => ({ textContent: s }),
    createRange: () => ({ selectNodeContents(n) { this.node = n; } }),
    execCommand(c) { execs.push(c); return execCommand; },
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
  const navigator = { userAgent: ua, language };
  if (clipboard !== 'none') {
    navigator.clipboard = { writeText: (s) => clipboard === 'ok'
      ? (copied.push(s), Promise.resolve()) : Promise.reject(new Error('not allowed')) };
  }
  if (brave) navigator.brave = {};
  const win = { document, navigator, location: { reload: () => reloaded.push(1) },
    getSelection: () => ({ removeAllRanges() {}, addRange: (r) => selected.push(r.node.textContent) }) };
  if (render) win.__mbrender = {};
  win.globalThis = win;
  vm.runInNewContext(gate, win, { filename: 'index.html' });
  const scripts = document.body.children.filter((c) => c.tag === 'script');
  const steps = ids['nogl-steps'].children.map((li) => li.children[1].textContent);
  const numbers = ids['nogl-steps'].children.map((li) => [li.children[0].className, li.children[0].textContent]);
  const copies = [];
  const walk = (e) => { if (e.tag === 'button') copies.push(e); (e.children || []).forEach(walk); };
  walk(ids['nogl-steps']);
  return { ids, scripts, steps, numbers, lost, copied, reloaded, copies, selected, execs };
}
const settle = () => new Promise((ok) => setImmediate(ok));

test('a WebGL 2 context: host.js then demo.js, run in their order, the context asked for let go', () => {
  const p = page();
  assert.deepEqual(p.scripts.map((s) => [s.src, s.async]), [['host.js', false], ['demo.js', false]]);
  assert.deepEqual(p.lost, ['WEBGL_lose_context']);
  assert.equal(p.ids.nogl.hidden, true);
  assert.equal(p.ids.c.style.display, undefined);
  assert.equal(p.ids['nogl-h'].textContent, '');
});

test('a page rendering a draw list (globalThis.__mbrender) loads at once, asking for no context', () => {
  const p = page({ render: true, webgl: 'throws' });
  assert.deepEqual(p.scripts.map((s) => s.src), ['host.js', 'demo.js']);
  assert.equal(p.ids.nogl.hidden, true);
});

for (const webgl of ['none', 'throws']) {
  test(`no WebGL 2 (${webgl}): nothing of the app loaded, the canvas hidden, the page shown, Retry reloads`, () => {
    const p = page({ webgl });
    assert.equal(p.scripts.length, 0);
    assert.equal(p.ids.nogl.hidden, false);
    assert.equal(p.ids.c.style.display, 'none');
    assert.equal(p.ids.ime.style.display, 'none');
    assert.deepEqual(p.numbers, [['n', '1'], ['n', '2'], ['n', '3']]);
    assert.equal(p.ids['nogl-retry'].textContent, 'Retry');
    p.ids['nogl-retry'].fire('click');
    assert.equal(p.reloaded.length, 1);
  });
}

for (const [name, scheme, en, zh] of [
  ['chrome', 'chrome', 'Use graphics acceleration when available', '使用图形加速功能（如果可用）'],
  ['edge', 'edge', 'Use graphics acceleration when available', '在可用时使用图形加速'],
  ['opera', 'opera', 'Use hardware acceleration when available', '可用时使用硬件加速'],
  ['brave', 'brave', 'Use graphics acceleration when available', '使用图形加速功能（如果可用）'],
]) {
  const ua = UA[name === 'brave' ? 'chrome' : name], brave = name === 'brave';
  const shown = name[0].toUpperCase() + name.slice(1);
  test(`${name}, English: its own settings page to copy, the setting by its name, its gpu page`, () => {
    const p = page({ ua, brave, webgl: 'none' });
    assert.equal(p.ids.nogl.lang, 'en');
    assert.equal(p.ids['nogl-h'].textContent, 'Turn on hardware acceleration');
    assert.match(p.ids['nogl-lead'].textContent, new RegExp(`^MoonBit UI draws with your graphics card and needs WebGL\u00a02\\. ${shown} has`));
    assert.deepEqual(p.steps, [
      `Open this address in a new tab:${scheme}://settings/systemCopy`,
      `Turn on ${en}.`,
      'Press Relaunch, then come back here and press Retry.',
    ]);
    assert.match(p.ids['nogl-note'].textContent, new RegExp(`Open ${scheme}://gpu and check`));
  });
  test(`${name}, Chinese: the setting by its Chinese name`, () => {
    const p = page({ ua, brave, webgl: 'none', language: 'zh-CN' });
    assert.equal(p.ids.nogl.lang, 'zh-CN');
    assert.equal(p.ids['nogl-h'].textContent, '打开浏览器的硬件加速');
    assert.match(p.ids['nogl-lead'].textContent, new RegExp(`^MoonBit UI 用显卡绘制界面，需要 WebGL\u00a02。${shown} 现在没有开启`));
    assert.deepEqual(p.steps, [
      `在新标签页的地址栏打开：${scheme}://settings/system复制`,
      `打开「${zh}」。`,
      '点设置旁出现的「重新启动」，再回到这里点「重试」。',
    ]);
    assert.match(p.ids['nogl-note'].textContent, new RegExp(`在地址栏打开 ${scheme}://gpu`));
    assert.equal(p.ids['nogl-retry'].textContent, '重试');
  });
}

test('firefox: its preferences to copy, the two settings of Performance, about:support, in either language', () => {
  const en = page({ ua: UA.firefox, webgl: 'none' });
  assert.match(en.steps[0], /about:preferences#general/);
  assert.match(en.steps[1], /Use recommended performance settings.*Use hardware acceleration when available/);
  assert.match(en.ids['nogl-note'].textContent, /about:support/);
  const zh = page({ ua: UA.firefox, webgl: 'none', language: 'zh-TW' });
  assert.equal(zh.steps[1], '在「性能」里取消勾选「使用推荐的性能设置」，再勾选「自动启用硬件加速」。');
  assert.match(zh.ids['nogl-note'].textContent, /about:support/);
});

test('safari: update, its feature flag, reopen; nothing to copy', () => {
  const p = page({ ua: UA.safari, webgl: 'none' });
  assert.equal(p.copies.length, 0);
  assert.match(p.steps[1], /Develop › Feature Flags.*WebGL\u00a02\.0/);
  const zh = page({ ua: UA.safari, webgl: 'none', language: 'zh-CN' });
  assert.equal(zh.steps[1], '若在「开发」›「功能标志」里改过设置，确认「WebGL\u00a02.0」是打开的。');
});

for (const name of ['android', 'firefoxAndroid']) {
  test(`a phone (${name}): what any browser does, no address of a computer's`, () => {
    const p = page({ ua: UA[name], webgl: 'none' });
    assert.match(p.ids['nogl-lead'].textContent, /This browser has graphics acceleration turned off/);
    assert.equal(p.copies.length, 0);
    assert.doesNotMatch(p.steps.join(' '), /:\/\/|about:/);
    const zh = page({ ua: UA[name], webgl: 'none', language: 'zh' });
    assert.match(zh.ids['nogl-lead'].textContent, /这个浏览器现在没有开启/);
  });
}

test('a page with no title is called this page, in either language', () => {
  assert.match(page({ webgl: 'none', title: '  ' }).ids['nogl-lead'].textContent, /^This page draws/);
  assert.match(page({ webgl: 'none', title: '', language: 'zh-CN' }).ids['nogl-lead'].textContent, /^当前页面 用显卡/);
});

test('copy: the address on the clipboard, Copied till the pointer or the focus leaves', async () => {
  for (const [language, copy, copied] of [['en-US', 'Copy', 'Copied'], ['zh-CN', '复制', '已复制']]) {
    const p = page({ webgl: 'none', language });
    const [b] = p.copies;
    b.fire('click');
    await settle();
    assert.deepEqual(p.copied, ['chrome://settings/system']);
    assert.equal(b.textContent, copied);
    b.fire('pointerleave');
    assert.equal(b.textContent, copy);
    b.fire('click');
    await settle();
    b.fire('blur');
    assert.equal(b.textContent, copy);
  }
});

test('copy without the clipboard, or refused it: the old way; where that fails too, the address selected', async () => {
  const none = page({ webgl: 'none', clipboard: 'none' });
  none.copies[0].fire('click');
  await settle();
  assert.deepEqual(none.execs, ['copy']);
  assert.equal(none.copies[0].textContent, 'Copied');
  const refused = page({ webgl: 'none', clipboard: 'refused', execCommand: false, language: 'zh-CN' });
  refused.copies[0].fire('click');
  await settle();
  assert.deepEqual(refused.execs, ['copy']);
  assert.deepEqual(refused.selected, ['chrome://settings/system']);
  assert.equal(refused.copies[0].textContent, '选中地址后手动复制');
});
