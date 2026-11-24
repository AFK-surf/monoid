// A browser's zoom keys belong to it, including while the hidden input or the shortcut recorder has focus.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

function browser(platform, clipboard) {
  const element = () => ({
    style: {}, listeners: new Map(),
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    dispatch(name, e) { for (const f of this.listeners.get(name) || []) f(e); },
  });
  const gl = new Proxy({}, { get: (_, name) => {
    if (name === 'getShaderParameter' || name === 'getProgramParameter') return () => true;
    return () => ({});
  } });
  const canvas = { ...element(), width: 0, height: 0, getContext: () => gl, setPointerCapture() {},
    getBoundingClientRect: () => ({ width: 800, height: 600, left: 0, top: 0 }) };
  const ime = element();
  const document = { createElement: () => ({ ...element(), getContext: () => ({}) }),
    getElementById: (id) => id === 'c' ? canvas : ime,
    addEventListener() {} };
  const win = { ...element(), document, navigator: { platform, clipboard }, location: { search: '' }, URLSearchParams, Intl, queueMicrotask,
    devicePixelRatio: 1, performance: { now: () => 0 }, requestAnimationFrame() {} };
  win.window = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  const keys = [];
  win.__mbhost.run('test', () => {}, () => {}, () => {}, (code, mods) => keys.push([code, mods]), () => {});
  return {
    host: win.__mbhost,
    mouseBack() {
      win.dispatch('mouseup', { button: 3, preventDefault() {} });
    },
    press(target, key, mods = {}) {
      const event = { target: target === 'ime' ? ime : canvas, key, code: mods.code || '',
        ctrlKey: false, metaKey: false, altKey: false, shiftKey: false,
        defaultPrevented: false, ...mods, preventDefault() { this.defaultPrevented = true; } };
      keys.length = 0;
      if (target === 'ime') ime.dispatch('keydown', event);
      win.dispatch('keydown', event);
      return { prevented: event.defaultPrevented, keys: [...keys] };
    },
    release(key, mods = {}) {
      keys.length = 0;
      win.dispatch('keyup', { target: canvas, key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...mods });
      return [...keys];
    },
    pointer(mods = {}) {
      keys.length = 0;
      canvas.dispatch('pointerdown', { pointerType: 'mouse', pointerId: 1, button: 0, clientX: 10, clientY: 10,
        ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, preventDefault() {}, ...mods });
      return [...keys];
    },
    blur() { keys.length = 0; win.dispatch('blur', {}); return [...keys]; },
  };
}

for (const platform of ['MacIntel', 'Win32']) {
  test(`${platform}: editing keys never also navigate back`, () => {
    const b = browser(platform);
    let backs = 0;
    b.host.setBack(() => backs++);
    b.host.backEnabled(true);
    for (const recording of [false, true]) {
      b.host.keyCatch(recording);
      for (const shiftKey of [false, true]) {
        for (const [key, code] of [['ArrowLeft', 3], ['ArrowRight', 4]]) {
          assert.deepEqual(b.press('ime', key, { altKey: true, shiftKey }),
            { prevented: true, keys: [[code, 4 | (shiftKey ? 1 : 0)]] });
          assert.equal(backs, 0);
        }
      }
      for (const composition of [{ isComposing: true }, { keyCode: 229 }]) {
        b.press('ime', 'ArrowLeft', { altKey: true, ...composition });
        b.press('page', 'ArrowLeft', { altKey: true, ...composition });
        assert.equal(backs, 0);
      }
    }
    b.host.keyCatch(false);
    for (const target of [{ tagName: 'INPUT' }, { tagName: 'TEXTAREA' }, { isContentEditable: true }]) {
      b.press('page', 'ArrowLeft', { altKey: true, target });
      assert.equal(backs, 0);
    }
    b.host.keyCatch(true);
    assert.deepEqual(b.press('page', 'ArrowLeft', { altKey: true }), { prevented: true, keys: [[3, 4]] });
    assert.equal(backs, 0);
    b.host.keyCatch(false);
    for (const extra of [{ shiftKey: true }, { ctrlKey: true }, { metaKey: true }]) {
      assert.equal(b.press('page', 'ArrowLeft', { altKey: true, ...extra }).keys.length, 1);
      assert.equal(backs, 0);
    }
    b.press('page', 'ArrowLeft', { altKey: true, defaultPrevented: true });
    assert.equal(backs, 0);
    b.press('page', 'ArrowLeft', { altKey: true });
    assert.equal(backs, 1);
    b.mouseBack();
    assert.equal(backs, 2);
    b.host.backEnabled(false);
    assert.deepEqual(b.press('page', 'ArrowLeft', { altKey: true }), { prevented: false, keys: [] });
    assert.equal(backs, 2);
  });
}

for (const [platform, key, flag, bit] of [['MacIntel', 'Meta', 'metaKey', 8], ['Win32', 'Control', 'ctrlKey', 2]]) {
  test(`${platform}: modifier-only keys and pointer focus tell the app what is held and released`, () => {
    const b = browser(platform);
    assert.deepEqual(b.press('page', key, { [flag]: true }), { prevented: false, keys: [[0, bit]] });
    assert.deepEqual(b.release(key), [[0, 0]]);
    // A modifier already held as the browser gets a pointer press is told too, but an unchanged one is not repeated.
    assert.deepEqual(b.pointer({ [flag]: true }), [[0, bit]]);
    assert.deepEqual(b.pointer({ [flag]: true }), []);
    assert.deepEqual(b.blur(), [[0, 0]]);
    assert.deepEqual(b.pointer(), []);
    // The browser can receive a normal key before it sees the held modifier's own keydown.
    assert.deepEqual(b.press('page', 'Enter', { [flag]: true }), { prevented: true, keys: [[7, bit]] });
    assert.deepEqual(b.pointer(), [[0, 0]]);
  });
}

test('a clipboard whose read() refuses gives its words by readText() (a paste in a WebView)', async () => {
  const b = browser('Win32', {
    read: async () => { throw new Error('NotAllowedError'); },
    readText: async () => '粘贴的字',
  });
  const answered = new Promise((resolve) => b.host.setOutside((kind, id, state) => resolve([kind, id, state])));
  const id = b.host.clipRead();
  assert.deepEqual(await answered, [9, id, 1]);
  assert.equal(b.host.clipText(id), '粘贴的字');
  assert.equal(b.host.clipPicture(id), 0);
  b.host.clipEnd(id);
});

test('a clipboard PNG over 8 MiB is read as an attachment; the file bound still applies', async () => {
  const bytes = new Uint8Array(9 << 20);
  bytes[0] = 137;
  bytes[bytes.length - 1] = 255;
  for (const [size, expected] of [[bytes.length, 1], [(1 << 30) + 1, 2]]) {
    let read = false;
    const b = browser('Win32', { read: async () => [{ types: ['image/png'], getType: async () => ({
      type: 'image/png', size,
      arrayBuffer: async () => { read = true; return bytes.buffer; },
    }) }] });
    const answered = new Promise((resolve) => b.host.setOutside((kind, id, state) => resolve([kind, id, state])));
    const id = b.host.clipRead();
    assert.deepEqual(await answered, [9, id, 1]);
    assert.equal(b.host.clipState(id), 1);
    assert.equal(b.host.clipPicture(id), expected);
    assert.equal(read, expected === 1);
    const got = b.host.clipPng(id);
    assert.equal(got.length, expected === 1 ? bytes.length : 0);
    if (expected === 1) {
      assert.equal(got[0], 137);
      assert.equal(got[got.length - 1], 255);
    }
    b.host.clipEnd(id);
    assert.equal(b.host.clipState(id), -1);
  }
});

for (const [platform, command, other] of [['Win32', 'ctrlKey', 'metaKey'], ['MacIntel', 'metaKey', 'ctrlKey']]) {
  test(`${platform}: browser zoom keys pass through the page, the input and the shortcut recorder`, () => {
    const b = browser(platform);
    for (const recording of [false, true]) {
      b.host.keyCatch(recording);
      for (const target of ['page', 'ime']) {
        for (const [key, code, shiftKey] of [
          ['=', 'Equal', false], ['+', 'Equal', true], ['-', 'Minus', false], ['0', 'Digit0', false],
          ['+', 'NumpadAdd', false], ['-', 'NumpadSubtract', false], ['0', 'Numpad0', false],
        ]) {
          assert.deepEqual(b.press(target, key, { [command]: true, code, shiftKey }), { prevented: false, keys: [] },
            `${target}, recording=${recording}: ${key} (${code})`);
        }
      }
    }
    b.host.keyCatch(false);
    // Zoom characters without the platform command, or with Alt as an app shortcut, are still the app's.
    assert.deepEqual(b.press('page', '-', {}), { prevented: true, keys: [[1045, 0]] });
    assert.deepEqual(b.press('page', '0', { [command]: true, altKey: true }),
      { prevented: true, keys: [[1048, platform === 'Win32' ? 6 : 12]] });
    assert.deepEqual(b.press('page', 'k', { [command]: true }),
      { prevented: true, keys: [[1107, platform === 'Win32' ? 2 : 8]] });
    assert.deepEqual(b.press('page', 'r', { [command]: true }), { prevented: false, keys: [] });
    assert.deepEqual(b.press('page', '-', { [other]: true }),
      { prevented: true, keys: [[1045, platform === 'Win32' ? 8 : 2]] });
  });
}
