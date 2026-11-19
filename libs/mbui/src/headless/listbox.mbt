// The list box: a list of options to choose one (or, `multiple`, several) of, with no field to type in (a combobox's is
// combobox.mbt's). Read out a `Listbox` called by its label; each option (`Listbox::option`) an `Option` called by its
// own label, selected as its caller says.
//
// Which are selected is its caller's (`is_selected`), told the key of an option pressed (`pick`: the pointer, Enter or
// Space with the focus on it, a screen reader's Activate; never a disabled one): one of one at a time, chosen where it is
// not chosen already (nothing told where it is); of `multiple`, every press, the caller turning it.
//
// Keys (WAI-ARIA's listbox): Tab stops on one of its options (the last that had the focus while it is still enabled,
// else the first selected, else the first enabled), and while one has the focus ↓ and ↑ go to the enabled option after
// and before (around the ends where `wraps`), Home and End to the first and the last, each showing the focus there and
// choosing nothing. Letters typed (typeahead) go to the next enabled option whose words (`text`, by default its label)
// begin with what was typed: what was typed within `typeahead_ms` of the letter before it together (at each key's own
// moment: the same at any rate of frames), the same letter again going on to the next that begins with it; a disabled
// option passed by.

///|
/// One option of a list box as typeahead finds it: its node, and its words.
priv struct ListboxEntry {
  node : @view.View
  text : () -> String
}

///|
/// A list box handed to its look to make its options by (`Listbox::option`).
pub struct Listbox[K] {
  priv is_selected : (K) -> Bool
  priv pick : (K) -> Unit
  priv multiple : Bool
  priv off : () -> Bool
  priv options : Rove
  priv entries : Array[ListboxEntry]
  /// (what was typed together, and the moment of its last letter)
  priv typed : Ref[(String, Double)]
}

///|
/// Whether the whole list box is disabled (as its caller says).
pub fn[K] Listbox::disabled(self : Listbox[K]) -> Bool {
  (self.off)()
}

///|
/// Whether several of its options may be selected.
pub fn[K] Listbox::multiple(self : Listbox[K]) -> Bool {
  self.multiple
}

///|
/// The focus asked onto the option Tab stops on (the last that had it, else the first selected, else the first
/// enabled), shown where `visible`. Whether one took it.
pub fn[K] Listbox::focus_stop(self : Listbox[K], visible? : Bool = true) -> Bool {
  match @signals.untracked(fn() { self.options.stop_at() }) {
    Some(id) =>
      match self.options.items.iter().find_first(fn(e) { e.node.id() == id }) {
        Some(e) => e.node.ask_focus(visible~)
        None => false
      }
    None => false
  }
}

///|
/// An option of a list box as its look reads it: each a reading, followed where a binding reads it.
pub struct ListOption {
  priv node : @view.View
  priv on : () -> Bool
  priv off : () -> Bool
}

///|
/// Whether it is selected now (as its caller says).
pub fn ListOption::selected(self : ListOption) -> Bool {
  (self.on)()
}

///|
/// Whether it is disabled (the list box or the option itself): it takes no press and no focus.
pub fn ListOption::disabled(self : ListOption) -> Bool {
  (self.off)()
}

///|
/// Whether it has the keyboard's focus (View::focused), whether that shows or not.
pub fn ListOption::focused(self : ListOption) -> Bool {
  self.node.focused()
}

///|
/// Whether it has the keyboard's focus and that shows (View::focus_shown).
pub fn ListOption::focus_shown(self : ListOption) -> Bool {
  self.node.focus_shown()
}

///|
/// Whether a pointer rests over it now (View::pointed): a mouse's, never a finger's.
pub fn ListOption::hovered(self : ListOption) -> Bool {
  self.node.pointed()
}

///|
/// Whether a finger or the pointer is held on it now (View::pressed).
pub fn ListOption::pressed(self : ListOption) -> Bool {
  self.node.pressed()
}

///|
/// The key code of a typed character's key (`ui`'s `key_of_char`: its code past this), and Space's.
let listbox_key_char : Int = 1000

///|
let listbox_key_space : Int = 1032

///|
/// `s` with its letters A to Z made small, as typeahead matches them.
fn listbox_small(s : String) -> String {
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
fn listbox_all(s : String, c : Char) -> Bool {
  s.iter().all(fn(x) { x == c })
}

///|
/// A typed character `c` at `at` among parts the keys go to (`live`, in order; `words` the words of the `i`th): what
/// was typed together (`typed`, with the moment of its last letter) grown by it (or begun anew, past `window_ms` since
/// the letter before), and the focus asked onto the next whose words begin with it, from the one with the focus (from
/// after it, where a letter is typed alone or again), around the end. Whether one was found. A list box's and a
/// menu's typeahead.
fn type_ahead(
  typed : Ref[(String, Double)],
  c : Char,
  at : Double,
  window_ms : Double,
  live : Array[@view.View],
  words : (Int) -> String,
) -> Bool {
  let small = listbox_small(c.to_string())
  let (was, last) = typed.val
  let now = if was != "" && at - last <= window_ms { was + small } else { small }
  typed.val = (now, at)
  let n = live.length()
  if n == 0 {
    return false
  }
  // (the same letter again: the next that begins with it; else what was typed whole, from the one it is on)
  let first = small.get_char(0).unwrap_or(' ')
  let (find, from_next) = if listbox_all(now, first) { (small, true) } else { (now, false) }
  let start = match live.search_by(fn(v) { v.focused() }) {
    Some(i) => if from_next { i + 1 } else { i }
    None => 0
  }
  for d in 0..<n {
    let i = (start + d) % n
    if listbox_small(words(i)).has_prefix(find) {
      live[i].ask_focus(visible=true) |> ignore
      return true
    }
  }
  false
}

///|
/// A typed character `c` at `at`: the focus on the next enabled option whose words begin with what was typed together
/// (type_ahead). Whether one was found.
fn[K] Listbox::typeahead(self : Listbox[K], c : Char, at : Double, window_ms : Double) -> Bool {
  let live = self.options.live()
  type_ahead(self.typed, c, at, window_ms, live.map(fn(e) { e.node }), fn(i) {
    let id = live[i].node.id()
    match self.entries.iter().find_first(fn(x) { x.node.id() == id }) {
      Some(x) => (x.text)()
      None => ""
    }
  })
}

///|
/// A list box in `parent`, called `label`, its options selected as `is_selected` says, `pick` told the key of one
/// pressed; `multiple`: several may be selected (each press told); `wraps`: ↓ past the last comes to the first, ↑
/// before the first to the last; `typeahead_ms`: how long after a letter the next is typed with it; `disabled` while
/// none of it takes a press or the focus. `look` is given its node and the `Listbox[K]` its options are made by
/// (directly or inside `View::each`), once as it is made: all that is drawn of it and how it is laid out. Its node.
#callsite(autofill(loc))
pub fn[K] listbox(
  parent : @view.View,
  label : () -> String,
  is_selected : (K) -> Bool,
  pick : (K) -> Unit,
  look : (@view.View, Listbox[K]) -> Unit,
  multiple? : Bool = false,
  wraps? : Bool = false,
  typeahead_ms? : Double = 500.0,
  disabled? : () -> Bool = fn() { false },
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let lb : Listbox[K] = {
    is_selected,
    pick,
    multiple,
    off: disabled,
    options: Rove::new(true),
    entries: [],
    typed: Ref(("", 0.0)),
  }
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    look(v, lb)
    v
    .says(By(fn() { Some(@view.said(Listbox, label=label())) }))
    .on_key(fn(k) {
      if disabled() || !focus_in(v, false) {
        return false
      }
      if k.mods == 0 && lb.options.step(k.code, [group_key_up], [group_key_down], wraps) is Some(_) {
        return true
      }
      // (a character typed, Space aside (it presses what has the focus); with Shift as without)
      if k.code > listbox_key_char && k.code != listbox_key_space && (k.mods == 0 || k.mods == shift_mod) {
        let c = (k.code - listbox_key_char).unsafe_to_char()
        return lb.typeahead(c, k.at, typeahead_ms)
      }
      false
    })
    |> ignore
  })
}

///|
/// The mods a key carries with Shift held (`ui`'s `mod_shift_key`).
let shift_mod : Int = 1

///|
/// An option of `key` in `parent` (the list box's node, a part of it, or `parent` itself where `in_node`: the row a
/// structure made), called `label`, found by typeahead by `text` (by default its label); `disabled` while it alone
/// takes no press and no focus. `look` is given its node and its `ListOption` once as it is made. Its node.
#callsite(autofill(loc))
pub fn[K] Listbox::option(
  self : Listbox[K],
  parent : @view.View,
  key : K,
  label : () -> String,
  look : (@view.View, ListOption) -> Unit,
  text? : () -> String,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    let off = fn() { (self.off)() || disabled() }
    let able = fn() { !off() }
    let on = fn() { (self.is_selected)(key) }
    self.entries.push({ node: v, text: text.unwrap_or(label) })
    v.owns(fn() { self.entries.retain(fn(e) { e.node.id() != v.id() }) }) |> ignore
    look(v, { node: v, on, off })
    v
    .presses(By(able))
    .focusable(By(able), tab=false)
    .says(By(fn() { Some(@view.said(@view.Role::Option, label=label(), selected=on())) }))
    .on_press(fn() {
      if !off() && (self.multiple || !on()) {
        (self.pick)(key)
      }
    })
    |> ignore
    self.options.add(v, off, on)
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}
