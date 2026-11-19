// A person's input (source.mbt `ScreenInput`, as a page has it) as macOS posts it (src/screens/mac-input.ts): which
// mouse button went down or up and how many clicks it makes, a page's key `code` as the Mac's virtual key, its
// modifiers as CGEventFlags. What the desktop's helper is given (`{op: "mouse" | "scroll" | "key" | "text"}`).

///|
/// CGEventFlags.
pub const FLAG_ALT : Int = 0x80000

///|
pub const FLAG_CTRL : Int = 0x40000

///|
pub const FLAG_COMMAND : Int = 0x100000

///|
pub const FLAG_SHIFT : Int = 0x20000

///|
pub const FLAG_NUMERIC_PAD : Int = 0x200000

///|
pub const FLAG_FN : Int = 0x800000

///|
/// CGEventFlags of a ScreenInput's `mods` (bit 0 alt, 1 ctrl, 2 meta, 3 shift).
pub fn flags_of(mods : Int) -> Int {
  (if (mods & 1) != 0 { FLAG_ALT } else { 0 }) |
  (if (mods & 2) != 0 { FLAG_CTRL } else { 0 }) |
  (if (mods & 4) != 0 { FLAG_COMMAND } else { 0 }) |
  (if (mods & 8) != 0 { FLAG_SHIFT } else { 0 })
}

///|
/// A page's KeyboardEvent.code (the key's place, whatever the layout) → the Mac's virtual key.
pub let mac_keycodes : Map[String, Int] = {
  "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05, "KeyZ": 0x06, "KeyX": 0x07,
  "KeyC": 0x08, "KeyV": 0x09, "IntlBackslash": 0x0a, "KeyB": 0x0b, "KeyQ": 0x0c, "KeyW": 0x0d, "KeyE": 0x0e,
  "KeyR": 0x0f, "KeyY": 0x10, "KeyT": 0x11, "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15,
  "Digit6": 0x16, "Digit5": 0x17, "Equal": 0x18, "Digit9": 0x19, "Digit7": 0x1a, "Minus": 0x1b, "Digit8": 0x1c,
  "Digit0": 0x1d, "BracketRight": 0x1e, "KeyO": 0x1f, "KeyU": 0x20, "BracketLeft": 0x21, "KeyI": 0x22, "KeyP": 0x23,
  "Enter": 0x24, "KeyL": 0x25, "KeyJ": 0x26, "Quote": 0x27, "KeyK": 0x28, "Semicolon": 0x29, "Backslash": 0x2a,
  "Comma": 0x2b, "Slash": 0x2c, "KeyN": 0x2d, "KeyM": 0x2e, "Period": 0x2f, "Tab": 0x30, "Space": 0x31,
  "Backquote": 0x32, "Backspace": 0x33, "Escape": 0x35, "MetaRight": 0x36, "MetaLeft": 0x37, "ShiftLeft": 0x38,
  "CapsLock": 0x39, "AltLeft": 0x3a, "ControlLeft": 0x3b, "ShiftRight": 0x3c, "AltRight": 0x3d,
  "ControlRight": 0x3e, "Fn": 0x3f, "F17": 0x40, "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45,
  "NumLock": 0x47, "AudioVolumeUp": 0x48, "AudioVolumeDown": 0x49, "AudioVolumeMute": 0x4a, "NumpadDivide": 0x4b,
  "NumpadEnter": 0x4c, "NumpadSubtract": 0x4e, "F18": 0x4f, "F19": 0x50, "NumpadEqual": 0x51, "Numpad0": 0x52,
  "Numpad1": 0x53, "Numpad2": 0x54, "Numpad3": 0x55, "Numpad4": 0x56, "Numpad5": 0x57, "Numpad6": 0x58,
  "Numpad7": 0x59, "F20": 0x5a, "Numpad8": 0x5b, "Numpad9": 0x5c, "IntlYen": 0x5d, "IntlRo": 0x5e,
  "NumpadComma": 0x5f, "F5": 0x60, "F6": 0x61, "F7": 0x62, "F3": 0x63, "F8": 0x64, "F9": 0x65, "Lang2": 0x66,
  "F11": 0x67, "Lang1": 0x68, "F13": 0x69, "F16": 0x6a, "F14": 0x6b, "F10": 0x6d, "ContextMenu": 0x6e, "F12": 0x6f,
  "F15": 0x71, "Insert": 0x72, "Help": 0x72, "Home": 0x73, "PageUp": 0x74, "Delete": 0x75, "F4": 0x76, "End": 0x77,
  "F2": 0x78, "PageDown": 0x79, "F1": 0x7a, "ArrowLeft": 0x7b, "ArrowRight": 0x7c, "ArrowDown": 0x7d,
  "ArrowUp": 0x7e,
}

///|
/// Keys a Mac's keyboard says are on its function row or keypad: posted with the flags its own keyboard gives them.
let mac_arrows : Array[Int] = [0x7b, 0x7c, 0x7d, 0x7e]

///|
let mac_fn_keys : Array[Int] = [
  0x72, 0x73, 0x74, 0x75, 0x77, 0x79, 0x7a, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6d, 0x67, 0x6f,
]

///|
/// The modifier keys by their place, and the flag each holds.
fn mac_modifier_flag(code : String) -> Int? {
  match code {
    "MetaLeft" | "MetaRight" => Some(FLAG_COMMAND)
    "ShiftLeft" | "ShiftRight" => Some(FLAG_SHIFT)
    "AltLeft" | "AltRight" => Some(FLAG_ALT)
    "ControlLeft" | "ControlRight" => Some(FLAG_CTRL)
    _ => None
  }
}

///|
/// Two downs of a button this close (ms, and in 0..1 of the screen) are one double click (macOS's default interval).
pub const CLICK_MS : Double = 500

///|
const CLICK_NEAR : Double = 0.01

///|
/// DOM `buttons` bits (1 left, 2 right, 4 middle) → DOM `button` (0 left, 1 middle, 2 right).
fn button_of_bit(bit : Int) -> Int? {
  match bit {
    1 => Some(0)
    2 => Some(2)
    4 => Some(1)
    _ => None
  }
}

///|
fn lowest_bit(bits : Int) -> Int {
  bits & -bits
}

///|
fn abs_d(d : Double) -> Double {
  if d < 0.0 {
    -d
  } else {
    d
  }
}

///|
/// How a view's input is posted on the machine: the ops its helper takes for one person's event, at `now` (ms);
/// `release`, those that let go of what it holds down, as the view ends (desktop.ts `InputOps`).
pub(all) struct InputOps {
  ops : (ScreenInput, Double) -> Array[J]
  release : (() -> Array[J])?
}

///|
/// One view's input as it goes (mac-input.ts `MacInput`): which buttons and modifier keys are held, where the pointer
/// was last, and the last press (for click counts).
pub struct MacInput {
  priv mut buttons : Int
  priv held : Array[String]
  priv mut at_x : Double
  priv mut at_y : Double
  priv mut press : (Double, Double, Double, Int, Int)?
  /// The controllers it drove, let go of as it ends.
  priv pads : Array[Int]
}

///|
pub fn MacInput::new() -> MacInput {
  { buttons: 0, held: [], at_x: 0.0, at_y: 0.0, press: None, pads: [] }
}

///|
fn MacInput::held_flags(self : MacInput) -> Int {
  let mut flags = 0
  for code in self.held {
    flags = flags | mac_modifier_flag(code).unwrap_or(0)
  }
  flags
}

///|
fn mac_mouse(kind : String, x : Double, y : Double, button : Int, buttons : Int, clicks : Int, flags : Int) -> J {
  jo([
    ("op", js("mouse")),
    ("type", js(kind)),
    ("x", jn(x)),
    ("y", jn(y)),
    ("button", ji(button)),
    ("buttons", ji(buttons)),
    ("clicks", ji(clicks)),
    ("flags", ji(flags)),
  ])
}

///|
fn mac_key(keycode : Int, down : Bool, flags : Int) -> J {
  jo([("op", js("key")), ("keycode", ji(keycode)), ("down", jb(down)), ("flags", ji(flags))])
}

///|
/// What lets go of all this view holds down: its buttons at the pointer's last place, then its modifier keys.
pub fn MacInput::release(self : MacInput) -> Array[J] {
  let ops = []
  for bit in [1, 2, 4] {
    if (self.buttons & bit) == 0 {
      continue
    }
    self.buttons = self.buttons & bit.lnot()
    ops.push(mac_mouse("up", self.at_x, self.at_y, button_of_bit(bit).unwrap(), self.buttons, 1, self.held_flags()))
  }
  for code in self.held.copy() {
    match self.held.search(code) {
      Some(i) => ignore(self.held.remove(i))
      None => ()
    }
    ops.push(mac_key(mac_keycodes.get(code).unwrap_or(0), false, self.held_flags()))
  }
  for index in self.pads {
    ops.push(pad_released(index).to_j(op=Some("gamepad")))
  }
  self.pads.clear()
  ops
}

///|
/// What `e` is posted as, at `now` (ms).
pub fn MacInput::ops(self : MacInput, e : ScreenInput, now : Double) -> Array[J] {
  match e {
    Pointer(kind~, x~, y~, buttons~, delta~) => {
      let before = self.buttons
      self.buttons = buttons & 7
      self.at_x = x
      self.at_y = y
      let flags = self.held_flags()
      if kind == "move" {
        return [with_delta(mac_mouse("move", x, y, 0, self.buttons, 0, flags), delta)]
      }
      if kind == "down" {
        let bit = {
          let b = lowest_bit(self.buttons & before.lnot())
          if b == 0 {
            1
          } else {
            b
          }
        }
        let button = button_of_bit(bit).unwrap_or(0)
        let again = match self.press {
          Some((at, px, py, pbutton, _)) =>
            pbutton == button && now - at <= CLICK_MS && abs_d(px - x) <= CLICK_NEAR && abs_d(py - y) <= CLICK_NEAR
          None => false
        }
        let clicks = if again {
          match self.press {
            Some((_, _, _, _, c)) => c + 1
            None => 1
          }
        } else {
          1
        }
        self.press = Some((now, x, y, button, clicks))
        self.buttons = self.buttons | bit
        return [with_delta(mac_mouse("down", x, y, button, self.buttons, clicks, flags), delta)]
      }
      let bit = {
        let b = lowest_bit(before & self.buttons.lnot())
        if b != 0 {
          b
        } else {
          let c = lowest_bit(before)
          if c != 0 {
            c
          } else {
            1
          }
        }
      }
      let button = button_of_bit(bit).unwrap_or(0)
      self.buttons = self.buttons & bit.lnot()
      let clicks = match self.press {
        Some((_, _, _, pbutton, c)) if pbutton == button => c
        _ => 1
      }
      [with_delta(mac_mouse("up", x, y, button, self.buttons, clicks, flags), delta)]
    }
    Wheel(x~, y~, dx~, dy~) =>
      [jo([("op", js("scroll")), ("x", jn(x)), ("y", jn(y)), ("dx", jn(dx)), ("dy", jn(dy)), ("flags", ji(self.held_flags()))])]
    Key(kind~, key~, code~, mods~) => {
      guard mac_keycodes.get(code) is Some(keycode) else {
        // A key of no known place (another layout's, a phone's keyboard): what it types, when it types one thing.
        return if kind == "down" && points_len(key) == 1 && (mods & 6) == 0 {
          [jo([("op", js("text")), ("text", js(key))])]
        } else {
          []
        }
      }
      if mac_modifier_flag(code) is Some(_) {
        // Its own flags are those held after it, whatever `mods` says (an app's up still says the modifier).
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
        return [mac_key(keycode, kind == "down", self.held_flags())]
      }
      let flags = flags_of(mods) |
        self.held_flags() |
        (if mac_arrows.contains(keycode) { FLAG_NUMERIC_PAD | FLAG_FN } else { 0 }) |
        (if mac_fn_keys.contains(keycode) { FLAG_FN } else { 0 })
      [mac_key(keycode, kind == "down", flags)]
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
pub fn MacInput::input_ops(self : MacInput) -> InputOps {
  { ops: (e, now) => self.ops(e, now), release: Some(() => self.release()) }
}

///|
/// A move's `dx`, `dy` and `relative` beside an op's fields, as the TypeScript's spread puts them.
fn with_delta(op : J, delta : PointerDelta?) -> J {
  match (op, delta) {
    (Obj(fields), Some(d)) => {
      let more = fields.copy()
      if d.moved {
        more.push((@jsjson.units("dx"), jn(d.dx)))
        more.push((@jsjson.units("dy"), jn(d.dy)))
      }
      if d.relative {
        more.push((@jsjson.units("relative"), jb(true)))
      }
      Obj(more)
    }
    _ => op
  }
}

///|
/// A controller's slot kept as held (`pads`, in the order they came: a Set's), or let go of.
fn pad_held(pads : Array[Int], pad : Pad) -> Unit {
  match pads.search(pad.index) {
    Some(i) => if !pad.connected { ignore(pads.remove(i)) }
    None => if pad.connected { pads.push(pad.index) }
  }
}
