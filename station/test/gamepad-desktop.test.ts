import assert from "node:assert/strict";
import { test } from "node:test";
import { PAD, PadDesktop, past } from "../src/screens/gamepad-desktop.ts";
import { LinuxGamepads } from "../src/screens/linux-gamepad.ts";
import { type Gamepad, type ScreenInput, gamepadReleased } from "../src/screens/source.ts";

const pad = (o: Partial<Gamepad> = {}): Gamepad => ({ t: "gamepad", index: 0, connected: true, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0, ...o });

test("a stick at rest moves nothing, pushed it moves the pointer by its travel squared, a part of a pixel carried", () => {
  assert.equal(past(0.1), 0);
  assert.equal(past(-1), -1);
  const d = new PadDesktop();
  assert.deepEqual(d.ops(pad({ lx: 0.1 })), []);
  assert.deepEqual(d.ops(pad({ lx: 1, ly: -1 })), [{ t: "pointer", kind: "move", x: 0, y: 0, buttons: 0, dx: 24, dy: -24, relative: true }]);
  // a quarter of the travel past the dead zone: 1/16 of the step, 1.5 pixels, carried to the next
  const quarter = 0.15 + 0.85 / 4;
  assert.deepEqual(d.ops(pad({ lx: quarter })), [{ t: "pointer", kind: "move", x: 0, y: 0, buttons: 0, dx: 1, dy: 0, relative: true }]);
  assert.deepEqual(d.ops(pad({ lx: quarter })), [{ t: "pointer", kind: "move", x: 0, y: 0, buttons: 0, dx: 2, dy: 0, relative: true }]);
  // the right stick scrolls where the pointer is
  assert.deepEqual(d.ops(pad({ ry: 1 })), [{ t: "wheel", x: -1, y: -1, dx: 0, dy: 40 }]);
});

test("its buttons press a mouse's and keys, the triggers past half way, and all let go of", () => {
  const d = new PadDesktop();
  assert.deepEqual(d.ops(pad({ buttons: 1 << PAD.a })), [{ t: "pointer", kind: "down", x: 0, y: 0, buttons: 1, dx: 0, dy: 0, relative: true }]);
  assert.deepEqual(d.ops(pad({ buttons: (1 << PAD.a) | (1 << PAD.lb), rt: 0.9 })), [
    { t: "key", kind: "down", key: "Tab", code: "Tab", mods: 8 },
    { t: "key", kind: "down", key: "PageDown", code: "PageDown", mods: 0 },
  ]);
  assert.deepEqual(d.ops(pad({ index: 1, buttons: 1 << PAD.up })), [{ t: "key", kind: "down", key: "ArrowUp", code: "ArrowUp", mods: 0 }]);
  assert.deepEqual(d.release(), [
    { t: "pointer", kind: "up", x: 0, y: 0, buttons: 0, dx: 0, dy: 0, relative: true },
    { t: "key", kind: "up", key: "Tab", code: "Tab", mods: 8 },
    { t: "key", kind: "up", key: "PageDown", code: "PageDown", mods: 0 },
    { t: "key", kind: "up", key: "ArrowUp", code: "ArrowUp", mods: 0 },
  ]);
  assert.deepEqual(d.ops(gamepadReleased(0)), [], "nothing more to let go of");
});

test("LinuxGamepads does not silently fall back to mouse emulation unless opted in via setMouse", async () => {
  const posted: ScreenInput[] = [];
  const pads = new LinuxGamepads(async (e) => void posted.push(e), {}, false, "/nonexistent-python", "/nonexistent-helper.py");
  // Default (allowMouse=false): controller input never hijacks the mouse even when uinput helper fails.
  await pads.input(pad({ lx: 1, buttons: 1 << PAD.a }));
  assert.equal(posted.length, 0);
  // Opt-in via setMouse(true): controller drives mouse/keyboard explicitly.
  await pads.setMouse(true);
  await pads.input(pad({ lx: 1, buttons: 1 << PAD.a }));
  assert.ok(posted.some((e) => e.t === "pointer" && e.kind === "move" && e.dx === 24));
  assert.ok(posted.some((e) => e.t === "pointer" && e.kind === "down" && e.buttons === 1));
  // Turning mouse emulation back off releases held buttons.
  posted.length = 0;
  await pads.setMouse(false);
  assert.ok(posted.some((e) => e.t === "pointer" && e.kind === "up" && e.buttons === 0));
  pads.close();
});
