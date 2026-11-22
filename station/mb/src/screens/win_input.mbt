// A person's input as Windows' SendInput posts it (src/screens/win-input.ts): which mouse button went down or up, a
// wheel in Windows' units (120 a notch), a page's key `code` as the key's scan code or, for a key without one, its
// virtual key. What stillfail-screen is given (`{op: "mouse" | "wheel" | "key" | "text"}`). Windows counts double
// clicks itself, and keeps which modifiers are down: a key that comes with modifiers not pressed before it has them
// pressed round it.

///|
/// A key's scan code (set 1; `ext`: an E0 key), or a virtual key where the scan code does not say it.
pub(all) struct WinKey {
  scan : Int
  ext : Bool
  vk : Int
}

///|
fn wk(scan : Int, ext? : Bool = false, vk? : Int = 0) -> WinKey {
  { scan, ext, vk }
}

///|
/// A page's KeyboardEvent.code → the key.
pub let win_keys : Map[String, WinKey] = {
  "Escape": wk(0x01), "Digit1": wk(0x02), "Digit2": wk(0x03), "Digit3": wk(0x04), "Digit4": wk(0x05),
  "Digit5": wk(0x06), "Digit6": wk(0x07), "Digit7": wk(0x08), "Digit8": wk(0x09), "Digit9": wk(0x0a),
  "Digit0": wk(0x0b), "Minus": wk(0x0c), "Equal": wk(0x0d), "Backspace": wk(0x0e), "Tab": wk(0x0f),
  "KeyQ": wk(0x10), "KeyW": wk(0x11), "KeyE": wk(0x12), "KeyR": wk(0x13), "KeyT": wk(0x14), "KeyY": wk(0x15),
  "KeyU": wk(0x16), "KeyI": wk(0x17), "KeyO": wk(0x18), "KeyP": wk(0x19), "BracketLeft": wk(0x1a),
  "BracketRight": wk(0x1b), "Enter": wk(0x1c), "ControlLeft": wk(0x1d), "KeyA": wk(0x1e), "KeyS": wk(0x1f),
  "KeyD": wk(0x20), "KeyF": wk(0x21), "KeyG": wk(0x22), "KeyH": wk(0x23), "KeyJ": wk(0x24), "KeyK": wk(0x25),
  "KeyL": wk(0x26), "Semicolon": wk(0x27), "Quote": wk(0x28), "Backquote": wk(0x29), "ShiftLeft": wk(0x2a),
  "Backslash": wk(0x2b), "KeyZ": wk(0x2c), "KeyX": wk(0x2d), "KeyC": wk(0x2e), "KeyV": wk(0x2f), "KeyB": wk(0x30),
  "KeyN": wk(0x31), "KeyM": wk(0x32), "Comma": wk(0x33), "Period": wk(0x34), "Slash": wk(0x35),
  "ShiftRight": wk(0x36), "NumpadMultiply": wk(0x37), "AltLeft": wk(0x38), "Space": wk(0x39), "CapsLock": wk(0x3a),
  "F1": wk(0x3b), "F2": wk(0x3c), "F3": wk(0x3d), "F4": wk(0x3e), "F5": wk(0x3f), "F6": wk(0x40), "F7": wk(0x41),
  "F8": wk(0x42), "F9": wk(0x43), "F10": wk(0x44), "NumLock": wk(0x45, ext=true), "ScrollLock": wk(0x46),
  "Numpad7": wk(0x47), "Numpad8": wk(0x48), "Numpad9": wk(0x49), "NumpadSubtract": wk(0x4a), "Numpad4": wk(0x4b),
  "Numpad5": wk(0x4c), "Numpad6": wk(0x4d), "NumpadAdd": wk(0x4e), "Numpad1": wk(0x4f), "Numpad2": wk(0x50),
  "Numpad3": wk(0x51), "Numpad0": wk(0x52), "NumpadDecimal": wk(0x53), "IntlBackslash": wk(0x56), "F11": wk(0x57),
  "F12": wk(0x58), "NumpadEqual": wk(0x59), "F13": wk(0x64), "F14": wk(0x65), "F15": wk(0x66), "F16": wk(0x67),
  "F17": wk(0x68), "F18": wk(0x69), "F19": wk(0x6a), "F20": wk(0x6b), "F21": wk(0x6c), "F22": wk(0x6d),
  "F23": wk(0x6e), "KanaMode": wk(0x70), "IntlRo": wk(0x73), "F24": wk(0x76), "Convert": wk(0x79),
  "NonConvert": wk(0x7b), "IntlYen": wk(0x7d), "NumpadComma": wk(0x7e), "NumpadEnter": wk(0x1c, ext=true),
  "ControlRight": wk(0x1d, ext=true), "NumpadDivide": wk(0x35, ext=true), "PrintScreen": wk(0x37, ext=true),
  "AltRight": wk(0x38, ext=true), "Home": wk(0x47, ext=true), "ArrowUp": wk(0x48, ext=true),
  "PageUp": wk(0x49, ext=true), "ArrowLeft": wk(0x4b, ext=true), "ArrowRight": wk(0x4d, ext=true),
  "End": wk(0x4f, ext=true), "ArrowDown": wk(0x50, ext=true), "PageDown": wk(0x51, ext=true),
  "Insert": wk(0x52, ext=true), "Delete": wk(0x53, ext=true), "MetaLeft": wk(0x5b, ext=true),
  "MetaRight": wk(0x5c, ext=true), "OSLeft": wk(0x5b, ext=true), "OSRight": wk(0x5c, ext=true),
  "ContextMenu": wk(0x5d, ext=true), "Pause": wk(0, vk=0x13), "AudioVolumeMute": wk(0, vk=0xad),
  "AudioVolumeDown": wk(0, vk=0xae), "AudioVolumeUp": wk(0, vk=0xaf), "MediaTrackNext": wk(0, vk=0xb0),
  "MediaTrackPrevious": wk(0, vk=0xb1), "MediaStop": wk(0, vk=0xb2), "MediaPlayPause": wk(0, vk=0xb3),
}

///|
/// A ScreenInput's `mods` bits (0 alt, 1 ctrl, 2 meta, 3 shift) and the keys that press them.
let win_modifiers : Array[(Int, Array[String])] = [
  (2, ["ControlLeft", "ControlRight"]),
  (8, ["ShiftLeft", "ShiftRight"]),
  (1, ["AltLeft", "AltRight"]),
  (4, ["MetaLeft", "MetaRight", "OSLeft", "OSRight"]),
]

///|
/// A page's wheel (pixels, positive down and right) in Windows' units (120 a notch, positive up and right).
pub const WHEEL_PER_PIXEL : Double = 1.2

///|
fn win_key_op(key : WinKey, down : Bool) -> J {
  jo([("op", js("key")), ("scan", ji(key.scan)), ("ext", jb(key.ext)), ("vk", ji(key.vk)), ("down", jb(down))])
}

///|
fn win_mouse(kind : String, x : Double, y : Double, button : Int) -> J {
  jo([("op", js("mouse")), ("type", js(kind)), ("x", jn(x)), ("y", jn(y)), ("button", ji(button))])
}

///|
/// One view's input as it goes (win-input.ts `WinInput`): which buttons and modifiers are held, where the pointer was
/// last, the wheel's part of a notch not sent yet.
pub struct WinInput {
  priv mut buttons : Int
  priv held : Array[String]
  priv mut at_x : Double
  priv mut at_y : Double
  priv mut wheel_x : Double
  priv mut wheel_y : Double
  priv pads : Array[Int]
}

///|
pub fn WinInput::new() -> WinInput {
  { buttons: 0, held: [], at_x: 0.0, at_y: 0.0, wheel_x: 0.0, wheel_y: 0.0, pads: [] }
}

///|
/// What lets go of all this view holds down: its buttons at the pointer's last place, then its modifier keys.
pub fn WinInput::release(self : WinInput) -> Array[J] {
  let ops = []
  for bit in [1, 2, 4] {
    if (self.buttons & bit) != 0 {
      ops.push(win_mouse("up", self.at_x, self.at_y, button_of_bit(bit).unwrap()))
    }
  }
  for code in self.held {
    ops.push(win_key_op(win_keys.get(code).unwrap(), false))
  }
  for index in self.pads {
    ops.push(pad_released(index).to_j(op=Some("gamepad")))
  }
  self.pads.clear()
  self.buttons = 0
  self.held.clear()
  ops
}

///|
pub fn WinInput::ops(self : WinInput, e : ScreenInput) -> Array[J] {
  match e {
    Pointer(kind~, x~, y~, buttons~, delta~) => {
      let before = self.buttons
      self.buttons = buttons & 7
      self.at_x = x
      self.at_y = y
      if kind == "move" {
        return [with_delta(win_mouse("move", x, y, 0), delta)]
      }
      if kind == "down" {
        let b = lowest_bit(self.buttons & before.lnot())
        let bit = if b == 0 { 1 } else { b }
        self.buttons = self.buttons | bit
        return [with_delta(win_mouse("down", x, y, button_of_bit(bit).unwrap_or(0)), delta)]
      }
      let b = lowest_bit(before & self.buttons.lnot())
      let bit = if b != 0 {
        b
      } else {
        let c = lowest_bit(before)
        if c != 0 {
          c
        } else {
          1
        }
      }
      self.buttons = self.buttons & bit.lnot()
      [with_delta(win_mouse("up", x, y, button_of_bit(bit).unwrap_or(0)), delta)]
    }
    Wheel(x~, y~, dx~, dy~) => {
      // Whole units only; what is left goes with the next turn the same way (a trackpad's many small ones).
      self.wheel_x = self.wheel_x + dx * WHEEL_PER_PIXEL
      self.wheel_y = self.wheel_y - dy * WHEEL_PER_PIXEL
      let tx = js_trunc(self.wheel_x)
      let ty = js_trunc(self.wheel_y)
      self.wheel_x = self.wheel_x - tx
      self.wheel_y = self.wheel_y - ty
      if tx == 0.0 && ty == 0.0 {
        []
      } else {
        [jo([("op", js("wheel")), ("x", jn(x)), ("y", jn(y)), ("dx", jn(tx)), ("dy", jn(ty))])]
      }
    }
    Key(kind~, key~, code~, mods~) => {
      guard win_keys.get(code) is Some(k) else {
        // A key of no known place (another layout's, a phone's keyboard): what it types, when it types one thing.
        return if kind == "down" && points_len(key) == 1 && (mods & 6) == 0 {
          [jo([("op", js("text")), ("text", js(key))])]
        } else {
          []
        }
      }
      let modifier = win_modifiers.iter().any(m => m.1.contains(code))
      if modifier {
        if kind == "down" {
          if !self.held.contains(code) {
            self.held.push(code)
          }
        } else {
          match self.held.search(code) {
            Some(i) => ignore(self.held.remove(i))
            None => ()
          }
        }
        return [win_key_op(k, kind == "down")]
      }
      if kind == "up" {
        return [win_key_op(k, false)]
      }
      // Modifiers it comes with that are not down: pressed round it.
      let round = win_modifiers
        .filter(m => (mods & m.0) != 0 && !m.1.iter().any(c => self.held.contains(c)))
        .map(m => win_keys.get(m.1[0]).unwrap())
      let out = round.map(r => win_key_op(r, true))
      out.push(win_key_op(k, true))
      for r in round.rev() {
        out.push(win_key_op(r, false))
      }
      out
    }
    Text(t) => if t == "" { [] } else { [jo([("op", js("text")), ("text", js(t))])] }
    Gamepad(pad) => {
      pad_held(self.pads, pad)
      [pad.to_j(op=Some("gamepad"))]
    }
    Pose(_) | Device(_) | Button(..) => []
  }
}

///|
pub fn WinInput::input_ops(self : WinInput) -> InputOps {
  { ops: (e, _) => self.ops(e), release: Some(() => self.release()) }
}
