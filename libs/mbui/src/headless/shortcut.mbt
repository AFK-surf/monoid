// A shortcut as a person reads it, in their system's own words: ⇧⌘K on a Mac's keys, Ctrl+Shift+K on Windows' or
// Linux's (Apple's Human Interface Guidelines and Windows' keyboard guidelines: the modifiers in each system's order, its
// own key names), so an app writes its keys once, as the keymap binds them (view's Stroke), and never a keycap by hand.
// What the person types with is the caller's to say (`apple`: where the keys are a Mac's or an iPad's, as
// @hostapi.keys_platform says it), so each answer is a function of the keys and that alone.
//
// The keys are ui's key codes (view's keymap: Backspace 1, Delete 2, ← 3, → 4, ↑ 5, ↓ 6, Enter 7, Home 8, End 9,
// Page Up 15, Page Down 16, Escape 17, Tab 18; a character 1000 and its code, Space 1032) and the modifiers held its
// bits (Shift 1, Control 2, Alt or Option 4, Command or the Windows key 8). A key with no name here is said as its
// code ("#n"): it is never left out, so what is read is never shorter than what is bound.

///|
/// The Shift bit of a stroke's modifiers.
let mod_shift : Int = 1

///|
/// The Control bit.
let mod_ctrl : Int = 2

///|
/// The Alt (Option) bit.
let mod_alt : Int = 4

///|
/// The Command (Windows key, Super) bit.
let mod_cmd : Int = 8

///|
/// `stroke` with its Command held as the system's own command key: on a Mac's keys as it is; elsewhere Command
/// becomes Control (⌘K bound once, read and taken as Ctrl+K on Windows and Linux), unless Control is held with it
/// already, where it stays the Windows key.
pub fn platform_stroke(stroke : @view.Stroke, apple~ : Bool) -> @view.Stroke {
  if apple || (stroke.mods & mod_cmd) == 0 || (stroke.mods & mod_ctrl) != 0 {
    return stroke
  }
  { code: stroke.code, mods: (stroke.mods & mod_cmd.lnot()) | mod_ctrl }
}

///|
/// The name of the key `code` (no modifier) on a Mac's keys (`apple`) or elsewhere.
fn key_cap(code : Int, apple : Bool) -> String {
  match code {
    1 => if apple { "⌫" } else { "Backspace" }
    2 => if apple { "⌦" } else { "Delete" }
    3 => "←"
    4 => "→"
    5 => "↑"
    6 => "↓"
    7 => if apple { "↩" } else { "Enter" }
    8 => if apple { "↖" } else { "Home" }
    9 => if apple { "↘" } else { "End" }
    15 => if apple { "⇞" } else { "PgUp" }
    16 => if apple { "⇟" } else { "PgDn" }
    17 => if apple { "⎋" } else { "Esc" }
    18 => if apple { "⇥" } else { "Tab" }
    1032 => "Space"
    c =>
      match (c - 1000).to_char() {
        // (a letter said as its capital, as a keycap shows it)
        Some(ch) if ch >= 'a' && ch <= 'z' => (ch.to_int() - 32).unsafe_to_char().to_string()
        Some(ch) if c > 1032 && ch != '\u{7f}' => ch.to_string()
        _ => "#\{c}"
      }
  }
}

///|
/// The keycaps of `stroke` as a person reads them, one for each modifier held and then its key: on a Mac's keys
/// (`apple`) ⌃ ⌥ ⇧ ⌘ in Apple's order (Control, Option, Shift, Command); elsewhere Ctrl, Alt, Shift, Win in Windows'
/// order. The stroke is read as it is: `platform_stroke` first, for one written once with Command.
pub fn stroke_caps(stroke : @view.Stroke, apple~ : Bool) -> Array[String] {
  let caps = []
  let held = fn(bit : Int) { (stroke.mods & bit) != 0 }
  let order = if apple {
    [(mod_ctrl, "⌃"), (mod_alt, "⌥"), (mod_shift, "⇧"), (mod_cmd, "⌘")]
  } else {
    [(mod_ctrl, "Ctrl"), (mod_alt, "Alt"), (mod_shift, "Shift"), (mod_cmd, "Win")]
  }
  for m in order {
    if held(m.0) {
      caps.push(m.1)
    }
  }
  caps.push(key_cap(stroke.code, apple))
  caps
}

///|
/// `stroke` as one shortcut a person reads: its keycaps (`stroke_caps`) together on a Mac's keys (⇧⌘K; a named key
/// after a modifier set apart, ⌘ Space), joined by "+" elsewhere (Ctrl+Shift+K).
pub fn format_stroke(stroke : @view.Stroke, apple~ : Bool) -> String {
  let caps = stroke_caps(stroke, apple~)
  if !apple {
    return caps.join("+")
  }
  let key = caps[caps.length() - 1]
  let mods = caps[:caps.length() - 1].join("")
  // (a key of a word's name, Space, kept apart from the glyphs before it)
  if mods != "" && key.length() > 1 {
    mods + " " + key
  } else {
    mods + key
  }
}

///|
/// Keys one after another (a binding of several strokes: G then I, ⌘K then ←) as a person reads them: each stroke
/// (`format_stroke`) set apart by a space ("G I", "⌘K ←"; "Ctrl+K ←").
pub fn format_chord(strokes : Array[@view.Stroke], apple~ : Bool) -> String {
  strokes.map(fn(s) { format_stroke(s, apple~) }).join(" ")
}
