// A person's input (`ScreenInput`) translated into the JSON ops that `stillfail-screen-linux` expects
// (`station/native/screen-linux/src/input_queue.rs`): mouse, wheel, evdev key, and UTF-8 text.
// Gamepads are handled separately by `LinuxGamepads` in `linux-native.ts`.
import type { InputOps } from "./desktop.ts";
import type { ScreenInput } from "./source.ts";
import { EVDEV } from "./x11-desktop.ts";

export type LinuxOp =
  | { op: "mouse"; type: "move" | "down" | "up"; x: number; y: number; button: number; dx?: number; dy?: number; relative?: boolean }
  | { op: "wheel"; x: number; y: number; dx: number; dy: number }
  | { op: "key"; evdev: number; down: boolean }
  | { op: "text"; text: string };

/// A ScreenInput's `mods` bits (0 alt, 1 ctrl, 2 meta, 3 shift) and the key codes that press them.
const MODIFIERS: { bit: number; codes: string[] }[] = [
  { bit: 2, codes: ["ControlLeft", "ControlRight"] },
  { bit: 8, codes: ["ShiftLeft", "ShiftRight"] },
  { bit: 1, codes: ["AltLeft", "AltRight"] },
  { bit: 4, codes: ["MetaLeft", "MetaRight", "OSLeft", "OSRight"] },
];

/// DOM `buttons` bits (1 left, 2 right, 4 middle) -> DOM `button` (0 left, 1 middle, 2 right).
const BUTTON_OF_BIT: Record<number, number> = { 1: 0, 2: 2, 4: 1 };
const lowestBit = (bits: number) => bits & -bits;

const keyOp = (evdev: number, down: boolean): LinuxOp => ({ op: "key", evdev, down });

/// Tracks held buttons, held modifier keys, pointer position, and fractional wheel ticks for one view.
export class LinuxInput implements InputOps {
  #buttons = 0;
  #held = new Set<string>();
  #at = { x: 0, y: 0 };
  #wheel = { x: 0, y: 0 };

  release(): LinuxOp[] {
    const ops: LinuxOp[] = [];
    for (const bit of [1, 2, 4]) {
      if ((this.#buttons & bit) !== 0) {
        ops.push({ op: "mouse", type: "up", x: this.#at.x, y: this.#at.y, button: BUTTON_OF_BIT[bit]! });
      }
    }
    for (const code of this.#held) {
      const evdev = EVDEV[code];
      if (evdev !== undefined) ops.push(keyOp(evdev, false));
    }
    this.#buttons = 0;
    this.#held.clear();
    return ops;
  }

  ops(e: ScreenInput): LinuxOp[] {
    switch (e.t) {
      case "pointer": {
        const before = this.#buttons;
        this.#buttons = e.buttons & 7;
        this.#at = { x: e.x, y: e.y };
        if (e.kind === "move") {
          return [{
            op: "mouse",
            type: "move",
            x: e.x,
            y: e.y,
            button: 0,
            ...(e.dx !== undefined && e.dy !== undefined ? { dx: e.dx, dy: e.dy, ...(e.relative ? { relative: true } : {}) } : {}),
          }];
        }
        if (e.kind === "down") {
          const bit = lowestBit(this.#buttons & ~before) || 1;
          this.#buttons |= bit;
          return [{ op: "mouse", type: "down", x: e.x, y: e.y, button: BUTTON_OF_BIT[bit] ?? 0, ...(e.relative ? { relative: true } : {}) }];
        }
        const bit = lowestBit(before & ~this.#buttons) || lowestBit(before) || 1;
        this.#buttons &= ~bit;
        return [{ op: "mouse", type: "up", x: e.x, y: e.y, button: BUTTON_OF_BIT[bit] ?? 0, ...(e.relative ? { relative: true } : {}) }];
      }
      case "wheel": {
        this.#wheel.x += e.dx / 100;
        this.#wheel.y += e.dy / 100;
        const dx = Math.trunc(this.#wheel.x);
        const dy = Math.trunc(this.#wheel.y);
        this.#wheel.x -= dx;
        this.#wheel.y -= dy;
        return dx === 0 && dy === 0 ? [] : [{ op: "wheel", x: e.x, y: e.y, dx, dy }];
      }
      case "key": {
        const evdev = EVDEV[e.code];
        if (evdev === undefined) {
          return e.kind === "down" && Array.from(e.key).length === 1 && (e.mods & 6) === 0 ? [{ op: "text", text: e.key }] : [];
        }
        const modifier = MODIFIERS.some((m) => m.codes.includes(e.code));
        if (modifier) {
          if (e.kind === "down") this.#held.add(e.code);
          else this.#held.delete(e.code);
          return [keyOp(evdev, e.kind === "down")];
        }
        if (e.kind === "up") return [keyOp(evdev, false)];
        const round = MODIFIERS
          .filter((m) => (e.mods & m.bit) !== 0 && !m.codes.some((c) => this.#held.has(c)))
          .map((m) => EVDEV[m.codes[0]!]!);
        return [...round.map((k) => keyOp(k, true)), keyOp(evdev, true), ...round.reverse().map((k) => keyOp(k, false))];
      }
      case "text":
        return e.text === "" ? [] : [{ op: "text", text: e.text }];
      case "gamepad":
      case "gamepadMode":
      case "pose":
      case "device":
      case "button":
        return [];
    }
  }
}
