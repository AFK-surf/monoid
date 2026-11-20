// A person's input as an iOS Simulator takes it (src/screens/sim-input.ts; still.fail Helper's SimulatorView.swift
// posts it): the left button held is a finger on the screen, a wheel a finger dragging, a key its USB HID usage, typed
// text keys of a US keyboard (anything else pasted). Simulator.app's own shortcuts press the device's buttons: ⌘⇧H
// home, ⌃⌘⇧H the app switcher, ⌘L lock, ⌘K the software keyboard.

///|
/// A page's KeyboardEvent.code → the USB HID keyboard usage (page 7).
pub let sim_usages : Map[String, Int] = {
  let m : Map[String, Int] = Map::new()
  let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  for i, c in letters.to_array() {
    m["Key\{c}"] = 0x04 + i
  }
  for i, c in "123456789".to_array() {
    m["Digit\{c}"] = 0x1e + i
  }
  let rest : Array[(String, Int)] = [
    ("Digit0", 0x27), ("Enter", 0x28), ("NumpadEnter", 0x28), ("Escape", 0x29), ("Backspace", 0x2a), ("Tab", 0x2b),
    ("Space", 0x2c), ("Minus", 0x2d), ("Equal", 0x2e), ("BracketLeft", 0x2f), ("BracketRight", 0x30),
    ("Backslash", 0x31), ("Semicolon", 0x33), ("Quote", 0x34), ("Backquote", 0x35), ("Comma", 0x36),
    ("Period", 0x37), ("Slash", 0x38), ("CapsLock", 0x39),
  ]
  for p in rest {
    m[p.0] = p.1
  }
  for i in 0..<12 {
    m["F\{i + 1}"] = 0x3a + i
  }
  let more : Array[(String, Int)] = [
    ("Insert", 0x49), ("Home", 0x4a), ("PageUp", 0x4b), ("Delete", 0x4c), ("End", 0x4d), ("PageDown", 0x4e),
    ("ArrowRight", 0x4f), ("ArrowLeft", 0x50), ("ArrowDown", 0x51), ("ArrowUp", 0x52), ("ControlLeft", 0xe0),
    ("ShiftLeft", 0xe1), ("AltLeft", 0xe2), ("MetaLeft", 0xe3), ("ControlRight", 0xe4), ("ShiftRight", 0xe5),
    ("AltRight", 0xe6), ("MetaRight", 0xe7),
  ]
  for p in more {
    m[p.0] = p.1
  }
  m
}

///|
/// A ScreenInput's `mods` bits (0 alt, 1 ctrl, 2 meta, 3 shift) and the left modifier key each is.
let sim_mods : Array[(Int, Int)] = [(1, 0xe2), (2, 0xe0), (4, 0xe3), (8, 0xe1)]

///|
fn sim_mod_of_usage(u : Int) -> Int? {
  match u {
    0xe0 | 0xe4 => Some(2)
    0xe1 | 0xe5 => Some(8)
    0xe2 | 0xe6 => Some(1)
    0xe3 | 0xe7 => Some(4)
    _ => None
  }
}

///|
const SIM_SHIFT : Int = 0xe1

///|
/// What a US keyboard types each printable ASCII character with: its usage, and whether with shift.
pub let sim_typed : Map[Char, (Int, Bool)] = {
  let out : Map[Char, (Int, Bool)] = { ' ': (0x2c, false), '\n': (0x28, false), '\t': (0x2b, false) }
  for i in 0..<26 {
    out[Int::unsafe_to_char(97 + i)] = (0x04 + i, false)
    out[Int::unsafe_to_char(65 + i)] = (0x04 + i, true)
  }
  let rows : Array[(String, String, Int)] = [
    ("1234567890", "!@#$%^&*()", 0x1e),
    ("-=[]\\", "_+{}|", 0x2d),
    (";'`,./", ":\"~<>?", 0x33),
  ]
  for r in rows {
    for i, c in r.0.to_array() {
      out[c] = (r.2 + i, false)
    }
    for i, c in r.1.to_array() {
      out[c] = (r.2 + i, true)
    }
  }
  out
}

///|
/// Where a finger that goes down is a system gesture's (0..1 of the screen from the edge).
const BOTTOM_EDGE : Double = 0.97

///|
const TOP_EDGE : Double = 0.02

///|
fn clamp01(v : Double) -> Double {
  if v.is_finite() {
    js_min(1.0, js_max(0.0, v))
  } else {
    0.0
  }
}

///|
fn sim_key(kind : String, usage : Int) -> J {
  jo([("op", js("key")), ("type", js(kind)), ("usage", ji(usage))])
}

///|
fn sim_touch(kind : String, x : Double, y : Double, edge : Int) -> J {
  jsome([
    ("op", Some(js("touch"))),
    ("type", Some(js(kind))),
    ("x", Some(jn(x))),
    ("y", Some(jn(y))),
    ("edge", if edge != 0 { Some(ji(edge)) } else { None }),
  ])
}

///|
/// One view's input as it goes (sim-input.ts `SimInput`): whether a finger is down (and from which edge), the modifier
/// keys held.
pub struct SimInput {
  priv mut finger : Int?
  priv mut held : Int
}

///|
pub fn SimInput::new() -> SimInput {
  { finger: None, held: 0 }
}

///|
/// What `e` is posted as (a touchscreen counts no clicks).
pub fn SimInput::ops(self : SimInput, e : ScreenInput) -> Array[J] {
  match e {
    Pointer(kind~, x~, y~, buttons~, ..) => {
      let x = clamp01(x)
      let y = clamp01(y)
      let left = (buttons & 1) == 1
      match self.finger {
        None => {
          if kind != "down" || !left {
            return []
          }
          let edge = if y >= BOTTOM_EDGE { 3 } else if y <= TOP_EDGE { 2 } else { 0 }
          self.finger = Some(edge)
          [sim_touch("begin", x, y, edge)]
        }
        Some(edge) => {
          if left && kind != "up" {
            return [sim_touch("move", x, y, edge)]
          }
          self.finger = None
          [sim_touch("end", x, y, edge)]
        }
      }
    }
    Wheel(x~, y~, dx~, dy~) =>
      if dx == 0.0 && dy == 0.0 {
        []
      } else {
        [jo([("op", js("scroll")), ("x", jn(clamp01(x))), ("y", jn(clamp01(y))), ("dx", jn(dx)), ("dy", jn(dy))])]
      }
    Key(kind~, code~, mods~, ..) => self.key(kind == "down", code, mods)
    Text(t) => self.typed(t)
    Pose(name) => [jo([("op", js("pose")), ("name", js(name))])]
    Gamepad(_) => []
    Button(page~, usage~, down~) => [jo([("op", js("hid")), ("page", ji(page)), ("usage", ji(usage)), ("down", jb(down))])]
    Device(name) =>
      if name == "memory_warning" {
        [jo([("op", js("memory_warning"))])]
      } else if name == "rotate" {
        [jo([("op", js("rotate"))])]
      } else {
        [jo([("op", js("button")), ("name", js(name))])]
      }
  }
}

///|
fn SimInput::key(self : SimInput, down : Bool, code : String, mods : Int) -> Array[J] {
  guard sim_usages.get(code) is Some(usage) else { return [] }
  match sim_mod_of_usage(usage) {
    Some(m) => {
      self.held = if down { self.held | m } else { self.held & m.lnot() }
      return [sim_key(if down { "down" } else { "up" }, usage)]
    }
    None => ()
  }
  // Simulator.app's shortcuts for the device's buttons.
  let meta = (mods & 4) != 0
  let shift = (mods & 8) != 0
  let ctrl = (mods & 2) != 0
  let alt = (mods & 1) != 0
  if meta && !alt {
    let button = if ctrl {
      if shift && code == "KeyH" {
        Some("app_switcher")
      } else {
        None
      }
    } else if shift && code == "KeyH" {
      Some("home")
    } else if !shift && code == "KeyL" {
      Some("lock")
    } else if !shift && code == "KeyK" {
      Some("keyboard")
    } else {
      None
    }
    match button {
      Some(b) => return if down { [jo([("op", js("button")), ("name", js(b))])] } else { [] }
      None => ()
    }
  }
  // A key that comes with modifiers not held before it (a phone's keys row) has them pressed round it.
  let round = sim_mods.filter(m => (mods & m.0) != 0 && (self.held & m.0) == 0).map(m => m.1)
  let key = sim_key(if down { "down" } else { "up" }, usage)
  if round.length() == 0 {
    return [key]
  }
  if down {
    let out = round.map(u => sim_key("down", u))
    out.push(key)
    out
  } else {
    let out = [key]
    for u in round.rev() {
      out.push(sim_key("up", u))
    }
    out
  }
}

///|
/// Typed text: a US keyboard's keys where each character has one, else the whole of it pasted.
fn SimInput::typed(self : SimInput, t : String) -> Array[J] {
  if t == "" {
    return []
  }
  let keys = []
  for c in t {
    match sim_typed.get(c) {
      Some(k) => keys.push(k)
      None => return [jo([("op", js("paste")), ("text", js(t))])]
    }
  }
  let out = []
  for k in keys {
    let (usage, shift) = k
    let press = shift && (self.held & 8) == 0
    if press {
      out.push(sim_key("down", SIM_SHIFT))
    }
    out.push(sim_key("down", usage))
    out.push(sim_key("up", usage))
    if press {
      out.push(sim_key("up", SIM_SHIFT))
    }
  }
  out
}

///|
pub fn SimInput::input_ops(self : SimInput) -> InputOps {
  { ops: (e, _) => self.ops(e), release: None }
}
