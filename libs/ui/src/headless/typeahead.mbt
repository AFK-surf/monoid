// Typeahead: incremental prefix search across live focusable items (used by menu, listbox, and custom controls).
// Characters typed within `window_ms` of each other build a prefix; repeating the same character advances to the next
// matching item; past `window_ms` the buffer resets. ASCII case-folded, Space passed through to activate the focused
// item. Nothing here is drawn, laid out or read out.

///|
/// The key code base for typed characters (`ui`'s `key_of_char`: code past this) and Space's code.
let typeahead_key_char : Int = 1000

///|
let typeahead_key_space : Int = 1032

///|
/// ASCII A..Z folded to a..z for case-insensitive typeahead matching.
fn typeahead_small(s : String) -> String {
  let b = StringBuilder()
  for c in s {
    if c >= 'A' && c <= 'Z' {
      b.write_char((c.to_int() + 32).unsafe_to_char())
    } else {
      b.write_char(c)
    }
  }
  b.to_string()
}

///|
/// Whether every character of `s` is `c`.
fn typeahead_all(s : String, c : Char) -> Bool {
  s.iter().all(fn(x) { x == c })
}

///|
/// Incremental prefix matcher over a list of live focusable nodes.
pub struct Typeahead {
  priv window_ms : Double
  priv typed : Ref[(String, Double)]
}

///|
/// A new typeahead matcher whose buffer resets when consecutive keys are more than `window_ms` apart.
pub fn Typeahead::new(window_ms? : Double = 500.0) -> Typeahead {
  { window_ms, typed: Ref(("", 0.0)) }
}

///|
/// Clear the accumulated typeahead buffer.
pub fn Typeahead::reset(self : Typeahead) -> Unit {
  self.typed.val = ("", 0.0)
}

///|
/// Match typed character `c` at moment `at` among `live` nodes (whose searchable label is `text_of(i)`). Moves visible
/// focus to the matching node and returns true when one is found.
pub fn Typeahead::match_next(
  self : Typeahead,
  c : Char,
  at : Double,
  live : Array[@view.View],
  text_of : (Int) -> String,
) -> Bool {
  let small = typeahead_small(c.to_string())
  let (was, last) = self.typed.val
  let now = if was != "" && at - last <= self.window_ms { was + small } else { small }
  self.typed.val = (now, at)
  let n = live.length()
  if n == 0 {
    return false
  }
  let first = small.get_char(0).unwrap_or(' ')
  let (find, from_next) = if typeahead_all(now, first) { (small, true) } else { (now, false) }
  let start = match live.search_by(fn(v) { v.focused() }) {
    Some(i) => if from_next { i + 1 } else { i }
    None => 0
  }
  for d in 0..<n {
    let i = (start + d) % n
    if typeahead_small(text_of(i)).has_prefix(find) {
      live[i].ask_focus(visible=true) |> ignore
      return true
    }
  }
  false
}

///|
/// Handle a key event `k` against `live` nodes: printable characters (excluding Space, allowing Shift or no modifiers)
/// are forwarded to `match_next`; all other keys return false without disturbing the buffer.
pub fn Typeahead::handle_key(
  self : Typeahead,
  k : @view.Key,
  live : Array[@view.View],
  text_of : (Int) -> String,
) -> Bool {
  if k.code > typeahead_key_char && k.code != typeahead_key_space && (k.mods == 0 || k.mods == mod_shift) {
    let c = (k.code - typeahead_key_char).unsafe_to_char()
    self.match_next(c, k.at, live, text_of)
  } else {
    false
  }
}
