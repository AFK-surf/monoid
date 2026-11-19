// A game controller driving a desktop that has no virtual controller to give its apps (Linux without /dev/uinput):
// the pointer by the left stick, the wheel by the right, its buttons as a mouse's and keys. The same map as still.fail
// Helper's (native/helper Gamepad.swift) and stillfail-screen's fallback (native/screen gamepad.rs):
//   A  left button       B  right button     X  Escape      Y  Enter
//   LB Shift+Tab         RB Tab              LT Page Up     RT Page Down
//   Back Backspace       Start Space         the d-pad  the arrow keys
// A client sends a controller's whole state at its own rate while any of it is held (each animation frame, as
// navigator.getGamepads is read), so a stick held over moves the pointer on each of them: no timer here.
import type { Gamepad, ScreenInput } from "./source.ts";

/// The W3C Standard Gamepad's buttons, by their bit.
export const PAD = { a: 0, b: 1, x: 2, y: 3, lb: 4, rb: 5, lt: 6, rt: 7, back: 8, start: 9, ls: 10, rs: 11, up: 12, down: 13, left: 14, right: 15, home: 16 } as const;
/// A stick's travel within which it is at rest, and a trigger's past which it is pressed.
export const DEAD_ZONE = 0.15;
const TRIGGER_DOWN = 0.5;
/// How far the pointer moves at a stick's full travel, a state, in pixels (the travel squared: fine near the centre),
/// and the wheel.
const POINTER_STEP = 24;
const WHEEL_STEP = 40;

/// Keys the buttons press: `code` as a page's KeyboardEvent.code, `mods` as ScreenInput's.
const KEYS: { bit: number; key: string; code: string; mods: number }[] = [
  { bit: PAD.x, key: "Escape", code: "Escape", mods: 0 },
  { bit: PAD.y, key: "Enter", code: "Enter", mods: 0 },
  { bit: PAD.lb, key: "Tab", code: "Tab", mods: 8 },
  { bit: PAD.rb, key: "Tab", code: "Tab", mods: 0 },
  { bit: PAD.back, key: "Backspace", code: "Backspace", mods: 0 },
  { bit: PAD.start, key: " ", code: "Space", mods: 0 },
  { bit: PAD.up, key: "ArrowUp", code: "ArrowUp", mods: 0 },
  { bit: PAD.down, key: "ArrowDown", code: "ArrowDown", mods: 0 },
  { bit: PAD.left, key: "ArrowLeft", code: "ArrowLeft", mods: 0 },
  { bit: PAD.right, key: "ArrowRight", code: "ArrowRight", mods: 0 },
];
const MOUSE: { bit: number; button: number }[] = [
  { bit: PAD.a, button: 1 },
  { bit: PAD.b, button: 2 },
];

/// A stick's travel past its dead zone, 0..1 again, its sign kept.
export function past(v: number): number {
  const a = Math.abs(v);
  return a <= DEAD_ZONE ? 0 : (Math.sign(v) * (a - DEAD_ZONE)) / (1 - DEAD_ZONE);
}

/// The buttons a controller's state holds down, the triggers as two more.
function held(pad: Gamepad): number {
  if (!pad.connected) return 0;
  return (pad.buttons & ~((1 << PAD.lt) | (1 << PAD.rt))) | (pad.lt > TRIGGER_DOWN ? 1 << PAD.lt : 0) | (pad.rt > TRIGGER_DOWN ? 1 << PAD.rt : 0);
}

/// One view's controllers as their states come: what each state is posted as (relative pointer moves, buttons, keys,
/// the wheel), and what lets go of all they hold.
export class PadDesktop {
  /// The buttons held, by slot.
  readonly #held = new Map<number, number>();
  /// The mouse buttons all slots hold, as ScreenInput's `buttons`.
  #mouse = 0;
  /// The part of a pixel a stick moved the pointer, and of the wheel, not posted yet.
  #rest = { x: 0, y: 0, wx: 0, wy: 0 };

  ops(pad: Gamepad): ScreenInput[] {
    const was = this.#held.get(pad.index) ?? 0;
    const now = held(pad);
    if (pad.connected) this.#held.set(pad.index, now);
    else this.#held.delete(pad.index);
    const out: ScreenInput[] = [];
    const pointer = (kind: "down" | "up" | "move", dx: number, dy: number): ScreenInput => ({ t: "pointer", kind, x: 0, y: 0, buttons: this.#mouse, dx, dy, relative: true });
    if (pad.connected) {
      const sx = past(pad.lx), sy = past(pad.ly);
      this.#rest.x += Math.sign(sx) * sx * sx * POINTER_STEP;
      this.#rest.y += Math.sign(sy) * sy * sy * POINTER_STEP;
      const dx = Math.trunc(this.#rest.x), dy = Math.trunc(this.#rest.y);
      this.#rest.x -= dx;
      this.#rest.y -= dy;
      if (dx !== 0 || dy !== 0) out.push(pointer("move", dx, dy));
      // (a page's wheel: positive down; the stick down scrolls down)
      this.#rest.wx += past(pad.rx) * WHEEL_STEP;
      this.#rest.wy += past(pad.ry) * WHEEL_STEP;
      const wx = Math.trunc(this.#rest.wx), wy = Math.trunc(this.#rest.wy);
      this.#rest.wx -= wx;
      this.#rest.wy -= wy;
      if (wx !== 0 || wy !== 0) out.push({ t: "wheel", x: -1, y: -1, dx: wx, dy: wy });
    }
    for (const { bit, button } of MOUSE) {
      const down = (now & (1 << bit)) !== 0, before = (was & (1 << bit)) !== 0;
      if (down === before) continue;
      if (down) this.#mouse |= button;
      else this.#mouse &= ~button;
      out.push(pointer(down ? "down" : "up", 0, 0));
    }
    for (const k of [...KEYS, { bit: PAD.lt, key: "PageUp", code: "PageUp", mods: 0 }, { bit: PAD.rt, key: "PageDown", code: "PageDown", mods: 0 }]) {
      const down = (now & (1 << k.bit)) !== 0, before = (was & (1 << k.bit)) !== 0;
      if (down !== before) out.push({ t: "key", kind: down ? "down" : "up", key: k.key, code: k.code, mods: k.mods });
    }
    return out;
  }

  /// What lets go of every controller's buttons.
  release(): ScreenInput[] {
    const out: ScreenInput[] = [];
    for (const index of [...this.#held.keys()]) out.push(...this.ops({ t: "gamepad", index, connected: false, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0 }));
    return out;
  }
}
