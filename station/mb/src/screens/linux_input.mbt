// A person's input (`ScreenInput`) translated into the JSON ops that `stillfail-screen-linux` expects
// (`src/screens/linux-input.ts`, `station/native/screen-linux/src/input_queue.rs`): mouse, wheel, evdev key, text.

///|
let linux_modifiers : Array[(Int, Array[String])] = [
  (2, ["ControlLeft", "ControlRight"]),
  (8, ["ShiftLeft", "ShiftRight"]),
  (1, ["AltLeft", "AltRight"]),
  (4, ["MetaLeft", "MetaRight", "OSLeft", "OSRight"]),
]

///|
fn linux_key_op(code : Int, down : Bool) -> J {
  jo([("op", js("key")), ("evdev", ji(code)), ("down", jb(down))])
}

///|
fn linux_mouse(kind : String, x : Double, y : Double, button : Int) -> J {
  jo([("op", js("mouse")), ("type", js(kind)), ("x", jn(x)), ("y", jn(y)), ("button", ji(button))])
}

///|
/// One view's Linux input state (linux-input.ts `LinuxInput`).
pub struct LinuxInput {
  priv mut buttons : Int
  priv held : Array[String]
  priv mut at_x : Double
  priv mut at_y : Double
  priv mut wheel_x : Double
  priv mut wheel_y : Double
}

///|
pub fn LinuxInput::new() -> LinuxInput {
  { buttons: 0, held: [], at_x: 0.0, at_y: 0.0, wheel_x: 0.0, wheel_y: 0.0 }
}

///|
/// Release all held mouse buttons and modifier keys.
pub fn LinuxInput::release(self : LinuxInput) -> Array[J] {
  let ops = []
  for bit in [1, 2, 4] {
    if (self.buttons & bit) != 0 {
      ops.push(linux_mouse("up", self.at_x, self.at_y, button_of_bit(bit).unwrap()))
    }
  }
  for code in self.held {
    match evdev.get(code) {
      Some(k) => ops.push(linux_key_op(k, false))
      None => ()
    }
  }
  self.buttons = 0
  self.held.clear()
  ops
}

///|
pub fn LinuxInput::ops(self : LinuxInput, e : ScreenInput) -> Array[J] {
  match e {
    Pointer(kind~, x~, y~, buttons~, delta~) => {
      let before = self.buttons
      self.buttons = buttons & 7
      self.at_x = x
      self.at_y = y
      if kind == "move" {
        return [with_delta(linux_mouse("move", x, y, 0), delta)]
      }
      if kind == "down" {
        let b = lowest_bit(self.buttons & before.lnot())
        let bit = if b == 0 { 1 } else { b }
        self.buttons = self.buttons | bit
        return [with_delta(linux_mouse("down", x, y, button_of_bit(bit).unwrap_or(0)), delta)]
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
      [with_delta(linux_mouse("up", x, y, button_of_bit(bit).unwrap_or(0)), delta)]
    }
    Wheel(x~, y~, dx~, dy~) => {
      self.wheel_x = self.wheel_x + dx / 100.0
      self.wheel_y = self.wheel_y + dy / 100.0
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
      guard evdev.get(code) is Some(k) else {
        return if kind == "down" && points_len(key) == 1 && (mods & 6) == 0 {
          [jo([("op", js("text")), ("text", js(key))])]
        } else {
          []
        }
      }
      let modifier = linux_modifiers.iter().any(m => m.1.contains(code))
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
        return [linux_key_op(k, kind == "down")]
      }
      if kind == "up" {
        return [linux_key_op(k, false)]
      }
      let round = linux_modifiers
        .filter(m => (mods & m.0) != 0 && !m.1.iter().any(c => self.held.contains(c)))
        .map(m => evdev.get(m.1[0]).unwrap())
      let out = round.map(r => linux_key_op(r, true))
      out.push(linux_key_op(k, true))
      for r in round.rev() {
        out.push(linux_key_op(r, false))
      }
      out
    }
    Text(t) => if t == "" { [] } else { [jo([("op", js("text")), ("text", js(t))])] }
    Gamepad(_) | Pose(_) | Device(_) | Button(..) => []
  }
}

///|
pub fn LinuxInput::input_ops(self : LinuxInput) -> InputOps {
  { ops: (e, _) => self.ops(e), release: Some(() => self.release()) }
}
