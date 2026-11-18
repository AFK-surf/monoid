// What a phone's input method and soft keyboard do to the browser host's field and page, without a browser: voice
// input replaces its guess as it hears more, and the app is told the edit, not every guess one after another; the soft
// keyboard ends the visual viewport above it, and the app is laid out above it; Safari's Done lets the field go; a field
// tapped is focused while the tap is handled, where iOS brings its keyboard up.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/host.js', import.meta.url), 'utf8');

function browser(search = '') {
  const queued = [], frames = [], texts = [];
  // what the app does as a pointer comes (its kind, x, y) and as a frame is drawn (the frame's height)
  const app = { pointer() {}, frame() {} };
  const element = () => ({
    style: {}, listeners: new Map(),
    addEventListener(name, f) { this.listeners.set(name, [...(this.listeners.get(name) || []), f]); },
    dispatch(name, e = {}) { for (const f of this.listeners.get(name) || []) f(e); },
  });
  const gl = new Proxy({}, { get: (_, name) => {
    if (name === 'getShaderParameter' || name === 'getProgramParameter') return () => true;
    return () => ({});
  } });
  const canvas = { ...element(), width: 0, height: 0, getContext: () => gl, setPointerCapture() {},
    getBoundingClientRect: () => ({ width: 400, height: 300, left: 0, top: 0 }) };
  const document = { activeElement: null, createElement: () => ({ ...element(), getContext: () => ({}) }),
    getElementById: (id) => id === 'c' ? canvas : ta, addEventListener() {} };
  // (a textarea's words, selection and focus)
  const ta = { ...element(), value: '', selectionStart: 0, selectionEnd: 0, attrs: new Map(), focusings: 0,
    setAttribute(k, v) { this.attrs.set(k, String(v)); }, removeAttribute(k) { this.attrs.delete(k); },
    getAttribute(k) { return this.attrs.get(k) ?? null; },
    setSelectionRange(s, e) { this.selectionStart = s; this.selectionEnd = e; },
    focus() { if (document.activeElement !== this) this.focusings++; document.activeElement = this; },
    blur() { if (document.activeElement === this) { document.activeElement = null; this.dispatch('blur'); } } };
  const visualViewport = { ...element(), height: 300, offsetTop: 0, scale: 1 };
  const win = { ...element(), document, navigator: { platform: 'iPhone' }, location: { search }, URLSearchParams,
    Intl, devicePixelRatio: 1, performance: { now: () => 0 }, requestAnimationFrame: (f) => queued.push(f),
    cancelAnimationFrame: (id) => { queued[id - 1] = null; },
    visualViewport, matchMedia: () => ({ addEventListener() {}, removeEventListener() {} }) };
  win.window = win;
  vm.runInNewContext(source, win, { filename: 'host.js' });
  const host = win.__mbhost;
  host.run('test', (w, h) => { frames.push(h); app.frame(h); }, (kind, x, y) => app.pointer(kind, x, y), () => {}, () => {},
    (kind, s, a, b) => texts.push([kind, s, a, b]));
  // The field's words as the app has them from what it was told (text kinds 3, the range a to b taken out, the caret
  // left there; 0, s put in at the caret), as src/ui's editor and ios_app.m's replaceRange:withText: do.
  let words = '', caret = 0;
  const told = () => {
    for (const [kind, s, a, b] of texts.splice(0)) {
      if (kind === 3) { words = words.slice(0, a) + words.slice(b); caret = a; }
      if (kind === 0) { words = words.slice(0, caret) + s + words.slice(caret); caret += s.length; }
    }
    return words;
  };
  // What the input method does to the textarea, and the input event it then sends.
  const edit = (from, to, put, inputType) => {
    ta.value = ta.value.slice(0, from) + put + ta.value.slice(to);
    ta.setSelectionRange(from + put.length, from + put.length);
    ta.dispatch('input', { inputType, data: put || null, isComposing: false });
  };
  // the field's words and selection as the app says them (setIme), its own model of them starting there
  const ime = (text = '', s = 0, e = s) => { host.setIme(true, 0, 0, 100, 20, text, s, e); words = text; caret = s; };
  const asked = () => queued.filter((f) => f !== null).length;
  const draw = () => {
    assert.equal(asked(), 1, 'one frame requested');
    const f = queued.find((f) => f !== null);
    queued.fill(null);
    f(0);
    return frames.at(-1);
  };
  // a finger's tap, or a mouse's click, on the canvas
  const tap = (pointerType = 'touch') => {
    for (const name of ['pointerdown', 'pointerup']) {
      canvas.dispatch(name, { pointerType, pointerId: 1, button: 0, clientX: 10, clientY: 10, timeStamp: 0,
        preventDefault() {} });
    }
  };
  return { ta, document, visualViewport, texts, ime, told, edit, draw, asked, tap, app, host, frames, win };
}

test('voice input that replaces its last guess writes the sentence once', () => {
  const b = browser();
  b.ime();
  let prev = '';
  for (const next of ['今天', '今天天气', '今天天气真不错 👋']) {
    // iOS's dictation: its last guess selected, the next inserted over it (WebPage::replaceDictatedText)
    const end = b.ta.selectionStart;
    b.edit(end - prev.length, end, next, 'insertText');
    prev = next;
  }
  assert.equal(b.told(), '今天天气真不错 👋');
});

test('voice input that deletes its guess key by key writes the sentence once', () => {
  const b = browser();
  b.ime();
  let prev = '';
  for (const next of ['今天', '今天天气', '今天天气真不错']) {
    // a keyboard's own deletes (deleteContentBackward, no key event), then the next guess typed
    for (let i = 0; i < prev.length; i++) b.edit(b.ta.selectionStart - 1, b.ta.selectionStart, '', 'deleteContentBackward');
    b.edit(b.ta.selectionStart, b.ta.selectionStart, next, 'insertText');
    prev = next;
  }
  assert.equal(b.told(), '今天天气真不错');
});

test('a correction replaces its word', () => {
  const b = browser();
  b.ime('teh cat', 3);
  b.edit(0, 3, 'the', 'insertReplacementText');
  assert.equal(b.told(), 'the cat');
});

test('the soft keyboard over the page lays the app out above it, and Done lets the field go', async () => {
  const b = browser();
  await Promise.resolve(); // H.run requests its first frame once the decoder's answer is known.
  assert.equal(b.draw(), 300);
  // A phone's keyboard changes no size of the page's, only the visual viewport's; that asks for a frame itself.
  b.visualViewport.height = 300 - 120;
  b.visualViewport.dispatch('resize');
  assert.equal(b.draw(), 180, 'laid out above the keyboard');
  b.ime();
  assert.equal(b.document.activeElement, b.ta);
  b.texts.length = 0;
  // Safari's Done: the keyboard put away by the person, the field blurred
  b.ta.blur();
  assert.deepEqual(b.texts.map(([k]) => k), [7], 'the app told the field let go');
  b.visualViewport.height = 300;
  b.visualViewport.dispatch('resize');
  assert.equal(b.draw(), 300, 'the whole canvas once the keyboard is gone');
});

// What the app does as a field is tapped: the pointer asks for a frame (its focus moved, src/view's tree), and that
// frame says the field's input method is on (@hostapi.set_ime), as every tap does on a device.
function aField(b, isField) {
  b.app.pointer = () => b.host.requestFrame();
  b.app.frame = () => { if (isField) b.host.setIme(true, 0, 0, 100, 20, '', 0, 0); };
}

test('a field tapped is focused while the tap is handled, its frame drawn once', async () => {
  const b = browser();
  await Promise.resolve();
  b.draw();
  aField(b, true);
  const before = b.frames.length;
  b.tap();
  // (iOS brings its keyboard up only for a focus given in the handling of a person's gesture)
  assert.equal(b.document.activeElement, b.ta, 'focused in the tap, not a display frame later');
  assert.equal(b.asked(), 0, 'the display frame asked for is called off');
  assert.equal(b.frames.length - before, 2, 'a frame for its down and one for its up, none drawn again');
});

test('what is not a field tapped takes no focus', async () => {
  const b = browser();
  await Promise.resolve();
  b.draw();
  aField(b, false);
  b.tap();
  assert.equal(b.document.activeElement, null, 'no keyboard for a tap elsewhere');
});

test("a mouse's click is drawn at the display's frame, as before", async () => {
  const b = browser();
  await Promise.resolve();
  b.draw();
  aField(b, true);
  b.tap('mouse');
  assert.equal(b.document.activeElement, null, 'nothing drawn in the click');
  b.draw();
  assert.equal(b.document.activeElement, b.ta);
});

// A field's keyboard (@hostapi.ime_action, said before setIme): what the textarea asks the phone's keyboard for. Moving
// from one field to another of another kind with the keyboard up, the textarea is focused again, the keyboard coming
// up anew for its kind (no blur told to the app as the field let go).
test("a field's kind sets the keyboard it asks for, a keyboard already up asked again", async () => {
  const b = browser();
  await Promise.resolve();
  b.draw();
  b.host.imeAction(5);
  b.ime();
  assert.equal(b.ta.getAttribute('inputmode'), 'email');
  assert.equal(b.ta.getAttribute('autocorrect'), 'off');
  const focusings = b.ta.focusings;
  b.visualViewport.height = 180;
  b.texts.length = 0;
  // another field, words taken as typed (a server's id), with the keyboard still up
  b.host.imeAction(6);
  b.ime('abc', 3);
  assert.equal(b.ta.getAttribute('inputmode'), null);
  assert.equal(b.ta.getAttribute('autocorrect'), 'off');
  assert.equal(b.document.activeElement, b.ta);
  assert.equal(b.ta.focusings, focusings + 1, 'focused again, for the keyboard to come up for its kind');
  assert.deepEqual(b.texts, [], 'the app told nothing of the textarea let go between');
  // the same kind again: nothing touched
  b.host.imeAction(6);
  b.ime('abcd', 4);
  assert.equal(b.ta.focusings, focusings + 1);
  // back to a plain field: its attributes gone
  b.host.imeAction(0);
  assert.equal(b.ta.getAttribute('autocorrect'), null);
  // an address's: the keyboard for addresses, its Enter a go key
  b.host.imeAction(2);
  assert.equal(b.ta.getAttribute('inputmode'), 'url');
  assert.equal(b.ta.getAttribute('enterkeyhint'), 'go');
});

test('a run to a declared moment draws a tapped field at its own frame, not in the tap', async () => {
  // (shot_at: the run's own clock, every frame drawn at its moment; a tap draws nothing out of its turn)
  const b = browser('?shot_at=100000');
  await Promise.resolve();
  b.draw();
  aField(b, true);
  b.tap();
  assert.equal(b.document.activeElement, null, 'nothing drawn in the tap');
  assert.equal(b.asked(), 1, 'the frame asked for stays asked');
  b.draw();
  assert.equal(b.document.activeElement, b.ta);
});

test("every field kind's keyboard, and an unknown kind taken as none", async () => {
  const b = browser();
  await Promise.resolve();
  b.draw();
  const attrs = () => Object.fromEntries(['inputmode', 'enterkeyhint', 'autocorrect']
    .filter((k) => b.ta.getAttribute(k) !== null).map((k) => [k, b.ta.getAttribute(k)]));
  const want = [
    {},
    { inputmode: 'search', enterkeyhint: 'search' },
    { inputmode: 'url', enterkeyhint: 'go', autocorrect: 'off' },
    { inputmode: 'numeric', enterkeyhint: 'done', autocorrect: 'off' },
    { autocorrect: 'off' },
    { inputmode: 'email', autocorrect: 'off' },
    { autocorrect: 'off' },
  ];
  for (const k of [1, 2, 3, 4, 5, 6, 0]) {
    b.host.imeAction(k);
    assert.deepEqual(attrs(), want[k], `kind ${k}`);
  }
  b.host.imeAction(3);
  b.host.imeAction(42);
  assert.deepEqual(attrs(), {}, 'a kind no host knows is none');
});

test('a field kind changed with no keyboard up neither focuses nor lets go of the textarea', async () => {
  const b = browser();
  await Promise.resolve();
  b.draw();
  b.host.imeAction(5);
  assert.equal(b.document.activeElement, null);
  assert.equal(b.ta.focusings, 0);
});

// The page's query parameters as the program reads them (host_js.mbt's env): a page's start that cleans the address
// (history.replaceState) before the program's first frame reads its drive does not take the drive away.
test('what the address said as the host loaded is read after the page took it off', () => {
  const b = browser('?MBUI_DRIVE_B64=dGFw&MBUI_DRIVE_KEEP_OPEN=1');
  assert.equal(b.host.env('MBUI_DRIVE_B64'), 'dGFw');
  b.win.location.search = '';
  assert.equal(b.host.env('MBUI_DRIVE_B64'), 'dGFw', 'kept from the load');
  assert.equal(b.host.env('MBUI_DRIVE_KEEP_OPEN'), '1');
  assert.equal(b.host.env('MBUI_DRIVE'), '', 'none said: ""');
});

test('what the address says now is read before what it said at the load', () => {
  const b = browser('?MBUI_DRIVE_KEEP_OPEN=1');
  b.win.location.search = '?MBUI_DRIVE_KEEP_OPEN=0&lang=en';
  assert.equal(b.host.env('MBUI_DRIVE_KEEP_OPEN'), '0');
  assert.equal(b.host.env('lang'), 'en');
  b.win.location.search = '?lang=en';
  assert.equal(b.host.env('MBUI_DRIVE_KEEP_OPEN'), '1', 'not on the address now: as it loaded');
});
