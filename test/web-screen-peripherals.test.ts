import assert from "node:assert/strict";
import test from "node:test";
import { DEAD_ZONE, MIC_SAMPLES, PAD_MS, PcmChunker, ScreenPeripherals, ScreenViews, padDue, padGone, padInput, resample } from "../web/src/mbui/screen-peripherals.ts";

const opened = (v: ScreenViews, id = 7, view = "mbui-1") => v.fromApp({ id, call: "screen.view", params: { station: "ws/st", screen: "desktop", view } });
const state = (v: ScreenViews, s: Record<string, unknown>, id = 7) => v.fromCore({ id, value: { state: { phase: "live", control: true, ...s } } });
const mic = (active: boolean, epoch = 3) => ({ available: true, active, epoch });

test("the microphone goes to a view only while it drives, is shared and something there records it", () => {
  const v = new ScreenViews();
  opened(v);
  assert.equal(v.micFor(), null);
  state(v, { mic: mic(true) });
  // not shared yet
  assert.equal(v.micFor(), null);
  assert.equal(v.fromApp({ id: 8, call: "screen.micOn", params: { view: "mbui-1", on: true } }), true);
  assert.deepEqual(v.micFor(), { view: "mbui-1", epoch: 3 });
  // its recording over
  state(v, { mic: mic(false) });
  assert.equal(v.micFor(), null);
  state(v, { mic: mic(true, 4) });
  assert.deepEqual(v.micFor(), { view: "mbui-1", epoch: 4 });
  // only looking (the core says no mic then)
  state(v, { control: false });
  assert.equal(v.micFor(), null);
  state(v, { mic: mic(true, 4) });
  assert.ok(v.micFor());
  // not live
  state(v, { phase: "reconnecting", mic: mic(true, 4) });
  assert.equal(v.micFor(), null);
  state(v, { mic: mic(true, 4) });
  // a virtual microphone not available is never active
  state(v, { mic: { available: false, active: true, epoch: 4 } });
  assert.equal(v.micFor(), null);
  state(v, { mic: mic(true, 4) });
  // unshared
  v.fromApp({ id: 9, call: "screen.micOn", params: { view: "mbui-1", on: false } });
  assert.equal(v.micFor(), null);
  v.fromApp({ id: 10, call: "screen.micOn", params: { view: "mbui-1", on: true } });
  assert.ok(v.micFor());
  // the view's call cancelled (out of sight) or answered (ended): gone
  v.fromApp({ id: 7, cancel: true });
  assert.equal(v.micFor(), null);
  opened(v, 11);
  v.fromApp({ id: 12, call: "screen.micOn", params: { view: "mbui-1", on: true } });
  state(v, { mic: mic(true) }, 11);
  assert.ok(v.micFor());
  assert.equal(v.fromCore({ id: 11, ok: null }), true);
  assert.equal(v.micFor(), null);
  // another call's values change nothing
  assert.equal(v.fromCore({ id: 99, value: { state: { phase: "live", control: true } } }), false);
});

test("the page opens the microphone as it is wanted and lets go of it in the same turn as it is not", async () => {
  const stopped: string[] = [];
  const asked: unknown[] = [];
  const track = { stop: () => stopped.push("track") };
  const nav = globalThis.navigator as unknown as { mediaDevices?: unknown };
  const had = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  let resolve: (s: unknown) => void = () => undefined;
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: { ...nav, mediaDevices: { getUserMedia: (c: unknown) => (asked.push(c), new Promise((r) => (resolve = r))) } },
  });
  try {
    const posted: unknown[] = [];
    const p = new ScreenPeripherals({ post: (m) => posted.push(m), canvas: () => null });
    p.fromApp({ id: 7, call: "screen.view", params: { view: "mbui-1" } });
    p.fromCore({ id: 7, value: { state: { phase: "live", control: true, mic: mic(true) } } });
    assert.equal(asked.length, 0);
    p.fromApp({ id: 8, call: "screen.micOn", params: { view: "mbui-1", on: true } });
    assert.equal(asked.length, 1);
    assert.equal(p.micView, "mbui-1");
    // the recording over before the browser answered: let go of; what comes after is stopped as it comes
    p.fromCore({ id: 7, value: { state: { phase: "live", control: true, mic: mic(false) } } });
    assert.equal(p.micView, null);
    resolve({ getTracks: () => [track] });
    for (let i = 0; i < 4; i++) await Promise.resolve();
    assert.deepEqual(stopped, ["track"]);
    assert.equal(posted.length, 0);
  } finally {
    if (had) Object.defineProperty(globalThis, "navigator", had);
  }
});

test("the microphone's samples go as 20 ms packets of 48 kHz mono s16le, clipped", () => {
  const out: Uint8Array[] = [];
  const c = new PcmChunker((b) => out.push(b));
  c.push(new Float32Array(MIC_SAMPLES - 1).fill(0.5));
  assert.equal(out.length, 0);
  c.push(new Float32Array([2, -2, Number.NaN]));
  assert.equal(out.length, 1);
  assert.equal(out[0]!.length, 1920);
  const d = new DataView(out[0]!.buffer);
  assert.equal(d.getInt16(0, true), Math.round(0.5 * 0x7fff));
  assert.equal(d.getInt16((MIC_SAMPLES - 1) * 2, true), 0x7fff);
  // the rest begins the next one
  c.push(new Float32Array(MIC_SAMPLES - 2));
  assert.equal(out.length, 2);
  assert.equal(new DataView(out[1]!.buffer).getInt16(0, true), -0x8000);
  assert.equal(resample(new Float32Array(441), 44_100).length, 480);
});

test("a controller's state: its buttons' bits, its sticks past the dead zone, its triggers; sent as it changes, or held off rest", () => {
  const buttons = Array.from({ length: 17 }, (_, i) => ({ pressed: i === 0 || i === 16, value: i === 7 ? 0.75 : i === 0 ? 1 : 0 }));
  const input = padInput({ index: 1, connected: true, mapping: "standard", buttons, axes: [DEAD_ZONE / 2, -0.5, 1.5, 0] });
  assert.deepEqual(input, { t: "gamepad", index: 1, connected: true, buttons: 1 | (1 << 16), lx: 0, ly: -0.5, rx: 1, ry: 0, lt: 0, rt: 0.75 });
  assert.equal(padDue(input, undefined, 0), true);
  const sent = { input: JSON.stringify(input), at: 100 };
  // held off rest: again once PAD_MS went by
  assert.equal(padDue(input, sent, 100 + PAD_MS / 2), false);
  assert.equal(padDue(input, sent, 100 + PAD_MS), true);
  // at rest: only as it changes
  const rest = padInput({ index: 0, connected: true, mapping: "standard", buttons: [], axes: [] });
  assert.equal(padDue(rest, { input: JSON.stringify(rest), at: 0 }, 10_000), false);
  assert.equal(padDue({ ...rest, buttons: 2 }, { input: JSON.stringify(rest), at: 0 }, 1), true);
  assert.deepEqual(padGone(2), { t: "gamepad", index: 2, connected: false, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0 });
});

test("the pointer is held for the view whose app holds it, its controllers go to the view last given input", () => {
  const v = new ScreenViews();
  opened(v, 1, "a");
  opened(v, 2, "b");
  state(v, {}, 1);
  state(v, { pointerLock: true }, 2);
  assert.equal(v.lockView()?.view, "b");
  assert.equal(v.padView(), "b");
  v.fromApp({ id: 3, call: "screen.input", params: { view: "a", input: { t: "pointer", kind: "move", x: 0.25, y: 0.75, buttons: 0 } } });
  assert.equal(v.padView(), "a");
  assert.deepEqual(v.of("a")?.at, { x: 0.25, y: 0.75 });
  state(v, { pointerLock: false }, 2);
  assert.equal(v.lockView(), null);
  state(v, { control: false }, 1);
  state(v, { control: false }, 2);
  assert.equal(v.padView(), null);
});

test("the core stopped or the page hidden: the views gone, the microphone let go of", () => {
  const had = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  const nav = globalThis.navigator as unknown as object;
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: { ...nav, mediaDevices: { getUserMedia: () => new Promise(() => undefined) } } });
  try {
    const p = new ScreenPeripherals({ post: () => undefined, canvas: () => null });
    p.fromApp({ id: 7, call: "screen.view", params: { view: "mbui-1" } });
    p.fromApp({ id: 8, call: "screen.micOn", params: { view: "mbui-1", on: true } });
    p.fromCore({ id: 7, value: { state: { phase: "live", control: true, mic: mic(true) } } });
    assert.equal(p.micView, "mbui-1");
    p.stop();
    assert.equal(p.micView, null);
    assert.equal(p.views.byCall.size, 0);
  } finally {
    if (had) Object.defineProperty(globalThis, "navigator", had);
  }
});
