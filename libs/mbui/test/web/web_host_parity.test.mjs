// What the browser's host answers as the other hosts do (web/host.js): the keys held (H.modsHeld, @hostapi.mods_held,
// as a key's own modifiers are told: shift 1, control 2, alt 4, command 8), the system's bars round the page said on
// the system's channel as they change (@hostapi.system_said's `bars`), Escape kept from the browser, the page's title,
// colour and history (@webpage.set_title, set_theme_color, location, history_*, history_channel: the app's calls
// `mbui.page.*`). It holds web/host.js alone, run in Node with as little of a page as it reads: not a real browser's
// order of its events, nor what the app does once told.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

function browser() {
  const element = () => ({
    style: {}, listeners: new Map(), attrs: {},
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    dispatch(name, e) { for (const f of this.listeners.get(name) || []) f(e); },
    setAttribute(name, v) { this.attrs[name] = v; },
    appendChild(child) { this.children = [...(this.children || []), child]; },
  });
  const gl = new Proxy({}, { get: (_, name) =>
    name === 'getShaderParameter' || name === 'getProgramParameter' ? () => true : () => ({}) });
  const canvas = { ...element(), width: 0, height: 0, getContext: () => gl,
    getBoundingClientRect: () => ({ width: 800, height: 600, left: 0, top: 0 }) };
  const ime = element();
  const theme = element();
  const body = element();
  const document = { ...element(), title: '', body, documentElement: element(),
    createElement: () => ({ ...element(), getContext: () => ({}) }),
    getElementById: (id) => id === 'c' ? canvas : ime,
    querySelector: (q) => q === 'meta[name="theme-color"]' ? theme : null };
  // the page's place in its site, and the browser's history over it
  const location = { search: '', pathname: '/', hash: '' };
  const stack = ['/'];
  let at = 0;
  const go = (to) => {
    const u = new URL(to, 'https://page.invalid' + location.pathname);
    location.pathname = u.pathname;
    location.search = u.search;
    location.hash = u.hash;
  };
  const history = {
    pushState(_, __, to) { stack.splice(at + 1); stack.push(to); at++; go(to); },
    replaceState(_, __, to) { stack[at] = to; go(to); },
    back() { if (at > 0) { at--; go(stack[at]); backs++; } },
  };
  let backs = 0;
  // CSS's env(safe-area-inset-*) as the probe's padding reads it
  const insets = { top: 0, right: 0, bottom: 0, left: 0 };
  const visualViewport = { ...element(), scale: 1, height: 600, offsetTop: 0 };
  const timers = [], frames = [];
  const clock = { now: 0 };
  const said = [];
  const win = { ...element(), document, location, history, visualViewport, navigator: { platform: 'MacIntel' },
    URLSearchParams, URL, Intl, queueMicrotask, devicePixelRatio: 1, performance: { now: () => clock.now },
    setTimeout(f, ms) { timers.push([f, ms]); return timers.length; },
    requestAnimationFrame(f) { frames.push(f); return frames.length; },
    getComputedStyle: () => ({ paddingTop: insets.top + 'px', paddingRight: insets.right + 'px',
      paddingBottom: insets.bottom + 'px', paddingLeft: insets.left + 'px' }) };
  win.window = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  const H = win.__mbhost;
  H.run('test', (w, h, scale, t) => said.push('frame ' + t), () => {}, () => {}, (code, mods) => said.push(`key ${code} ${mods}`),
    () => {});
  const event = (more) => ({ target: canvas, key: '', code: '', ctrlKey: false, metaKey: false, altKey: false,
    shiftKey: false, isComposing: false, keyCode: 0, defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true; }, ...more });
  const taken = () => {
    const out = [];
    const n = H.postTake();
    for (let i = 0; i < n; i++) out.push([H.postNext(), JSON.parse(H.postJson())]);
    return out;
  };
  return { H, win, document, theme, location, insets, visualViewport, timers, frames, clock, said, event, taken,
    backs: () => backs };
}

const task = () => new Promise((resolve) => setTimeout(resolve, 0));

test('the keys held are what the window\'s last input says, none once it is left', async () => {
  const b = browser();
  await task();
  assert.equal(b.H.modsHeld(), 0);
  b.win.dispatch('pointerdown', b.event({ shiftKey: true }));
  assert.equal(b.H.modsHeld(), 1, 'Shift with a press');
  b.win.dispatch('pointermove', b.event({ shiftKey: true, metaKey: true }));
  assert.equal(b.H.modsHeld(), 1 | 8, 'Command too as the pointer moves');
  b.win.dispatch('keydown', b.event({ key: 'Alt', altKey: true, ctrlKey: true }));
  assert.equal(b.H.modsHeld(), 2 | 4, 'a key down says its own');
  b.win.dispatch('keyup', b.event({ key: 'Alt', ctrlKey: true }));
  assert.equal(b.H.modsHeld(), 2, 'Alt let go');
  b.win.dispatch('wheel', b.event({ ctrlKey: true, shiftKey: true }));
  assert.equal(b.H.modsHeld(), 2 | 1, 'with the wheel');
  b.win.dispatch('pointerup', b.event({}));
  assert.equal(b.H.modsHeld(), 0);
  b.win.dispatch('keydown', b.event({ key: 'Shift', shiftKey: true }));
  b.win.dispatch('blur', {});
  assert.equal(b.H.modsHeld(), 0, 'none once the window is left, its keys going up unseen');
  b.win.dispatch('keydown', b.event({ key: 'Meta', metaKey: true }));
  b.document.dispatch('visibilitychange', {});
  assert.equal(b.H.modsHeld(), 0, 'none once the page is hidden');
});

test('the system\'s bars round the page are said on the system\'s channel as they change, none while none', async () => {
  const b = browser();
  await task();
  // (the page's size measured again for the frame a resize asks for)
  const resized = () => { b.win.dispatch('resize', {}); while (b.frames.length) b.frames.shift()(0); };
  resized();
  assert.deepEqual(b.taken(), [], 'none said while there are none');
  b.insets.top = 47;
  b.insets.bottom = 34;
  resized();
  assert.deepEqual(b.taken(), [['system', { bars: { top: 47, bottom: 34, left: 0, right: 0 } }]]);
  resized();
  assert.deepEqual(b.taken(), [], 'said once, as it changes');
  // turned: the notch at a side
  b.insets.top = 0;
  b.insets.left = 47;
  b.insets.right = 47;
  b.insets.bottom = 21;
  b.win.dispatch('orientationchange', {});
  assert.deepEqual(b.taken(), [['system', { bars: { top: 0, bottom: 21, left: 47, right: 47 } }]]);
  // the soft keyboard up: the app laid out above it, nothing under it the system's
  b.visualViewport.height = 300;
  b.visualViewport.dispatch('resize', {});
  assert.deepEqual(b.taken(), [['system', { bars: { top: 0, bottom: 0, left: 47, right: 47 } }]]);
  b.visualViewport.height = 600;
  b.visualViewport.dispatch('resize', {});
  assert.deepEqual(b.taken(), [['system', { bars: { top: 0, bottom: 21, left: 47, right: 47 } }]]);
});

test('Escape is kept from the browser and told to the app, but not from an input method composing', async () => {
  const b = browser();
  await task();
  b.said.length = 0;
  const e = b.event({ key: 'Escape' });
  b.win.dispatch('keydown', e);
  assert.ok(e.defaultPrevented);
  assert.deepEqual(b.said, ['key 17 0'], 'the app told it');
  b.said.length = 0;
  const composing = b.event({ key: 'Escape', isComposing: true, keyCode: 229 });
  b.win.dispatch('keydown', composing);
  assert.ok(!composing.defaultPrevented, 'the input method\'s, calling its words off');
  assert.deepEqual(b.said, []);
});

test('the page\'s title and colour', async () => {
  const b = browser();
  await task();
  assert.equal(b.document.title, 'test', 'the title it runs with');
  b.H.setPageTitle('收件箱 (3)');
  assert.equal(b.document.title, '收件箱 (3)');
  b.H.setThemeColor('#101012');
  assert.equal(b.theme.attrs.content, '#101012');
  assert.equal(b.document.documentElement.style.backgroundColor, '#101012');
  assert.equal(b.document.body.style.backgroundColor, '#101012');
  b.H.setThemeColor('');
  assert.equal(b.theme.attrs.content, '');
});

test('the page\'s history: put on, put in place, and where the browser went by itself said', async () => {
  const b = browser();
  await task();
  assert.equal(b.H.historyLocation(), '/');
  b.H.historyPush('/a?x=1#top');
  assert.equal(b.H.historyLocation(), '/a?x=1#top');
  b.H.historyPush('/b');
  b.H.historyReplace('/c?y=2');
  assert.equal(b.H.historyLocation(), '/c?y=2');
  assert.deepEqual(b.taken(), [], 'what the app put there is not said back');
  b.H.historyBack();
  assert.equal(b.backs(), 1);
  // (the browser tells the page where it came to as it gets there)
  b.win.dispatch('popstate', {});
  assert.deepEqual(b.taken(), [['history', { location: '/a?x=1#top' }]]);
});
