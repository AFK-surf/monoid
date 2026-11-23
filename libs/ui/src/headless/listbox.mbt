// The list box: a list of options to choose one (or, `multiple`, several) of, with no field to type in (a combobox's is
// combobox.mbt's). Read out a `Listbox` called by its label; each option (`Listbox::option`) an `Option` called by its
// own label, selected as its caller says.
//
// Which are selected is its caller's (`is_selected`), told the key of an option pressed (`pick`: the pointer, Enter or
// Space with the focus on it, a screen reader's Activate; never a disabled one): one of one at a time, chosen where it is
// not chosen already (nothing told where it is); of `multiple`, every press, the caller turning it. When `multiple` is
// true and `on_select_many` is provided, Shift+ArrowDown/Up/Home/End and Shift+Click extend a contiguous range from the
// anchor (skipping disabled options) via `SelectionModel`, and Ctrl+A / Cmd+A selects all enabled options.
//
// Keys (WAI-ARIA's listbox): Tab stops on one of its options (the last that had the focus while it is still enabled,
// else the first selected, else the first enabled), and while one has the focus ↓ and ↑ go to the enabled option after
// and before (around the ends where `wraps`), Home and End to the first and the last, each showing the focus there and
// choosing nothing. Letters typed (typeahead) go to the next enabled option whose words (`text`, by default its label)
// begin with what was typed: what was typed within `typeahead_ms` of the letter before it together (at each key's own
// moment: the same at any rate of frames), the same letter again going on to the next that begins with it; a disabled
// option passed by.

///|
/// One option of a list box: its node, key, disabled predicate, and searchable text.
priv struct ListboxEntry[K] {
  node : @view.View
  key : K
  off : () -> Bool
  text : () -> String
}

///|
/// A list box handed to its look to make its options by (`Listbox::option`).
pub struct Listbox[K] {
  priv is_selected : (K) -> Bool
  priv pick : (K) -> Unit
  priv on_select_many : ((Array[K]) -> Unit)?
  priv shift_held : () -> Bool
  priv multiple : Bool
  priv off : () -> Bool
  priv options : RovingFocus
  priv entries : Array[ListboxEntry[K]]
  priv typeahead : Typeahead
  priv selection : SelectionModel[@view.NodeId]
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
  self.options.focus_stop(visible~)
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
/// Key code for Select All (`ui`'s `key_code_select_all`).
let listbox_key_select_all : Int = 12

///|
/// Map a list of option NodeIds back to their caller keys in order.
fn[K] Listbox::keys_of(self : Listbox[K], ids : Array[@view.NodeId]) -> Array[K] {
  let out : Array[K] = []
  for id in ids {
    match self.entries.iter().find_first(fn(e) { e.node.id() == id }) {
      Some(e) => out.push(e.key)
      None => ()
    }
  }
  out
}

///|
/// All living option NodeIds in registration order, currently selected IDs, and a disabled predicate on NodeId.
fn[K] Listbox::selection_inputs(
  self : Listbox[K],
) -> (Array[@view.NodeId], Array[@view.NodeId], (@view.NodeId) -> Bool) {
  let all_ids : Array[@view.NodeId] = []
  let cur_ids : Array[@view.NodeId] = []
  for e in self.entries {
    if e.node.alive() {
      let id = e.node.id()
      all_ids.push(id)
      if @signals.untracked(fn() { (self.is_selected)(e.key) }) {
        cur_ids.push(id)
      }
    }
  }
  let is_off = fn(id : @view.NodeId) -> Bool {
    match self.entries.iter().find_first(fn(e) { e.node.id() == id }) {
      Some(e) => !e.node.takes_input() || @signals.untracked(e.off)
      None => true
    }
  }
  (all_ids, cur_ids, is_off)
}

///|
/// A list box in `parent`, called `label`, its options selected as `is_selected` says, `pick` told the key of one
/// pressed; `multiple`: several may be selected (each press told); `on_select_many`: when provided with `multiple=true`,
/// receives the new selection array on Shift+Arrow range selection, Shift+Click range selection (using `shift_held`), and
/// Ctrl+A / Cmd+A select-all; `wraps`: ↓ past the last comes to the first, ↑ before the first to the last;
/// `typeahead_ms`: how long after a letter the next is typed with it; `disabled` while none of it takes a press or the
/// focus. `look` is given its node and the `Listbox[K]` its options are made by (directly or inside `View::each`), once
/// as it is made: all that is drawn of it and how it is laid out. Its node.
#callsite(autofill(loc))
pub fn[K] listbox(
  parent : @view.View,
  label : () -> String,
  is_selected : (K) -> Bool,
  pick : (K) -> Unit,
  look : (@view.View, Listbox[K]) -> Unit,
  multiple? : Bool = false,
  on_select_many? : (Array[K]) -> Unit,
  shift_held? : () -> Bool = fn() { false },
  wraps? : Bool = false,
  typeahead_ms? : Double = 500.0,
  disabled? : () -> Bool = fn() { false },
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let lb : Listbox[K] = {
    is_selected,
    pick,
    on_select_many,
    shift_held,
    multiple,
    off: disabled,
    options: RovingFocus::new(axis=Vertical, roving=true, wraps~),
    entries: [],
    typeahead: Typeahead::new(window_ms=typeahead_ms),
    selection: SelectionModel::new(multiple~),
  }
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    look(v, lb)
    v
    .says(By(fn() { Some(@view.said(Listbox, label=label())) }))
    .on_key(fn(k) {
      if disabled() || !focus_in(v, false) {
        return false
      }
      if multiple && on_select_many is Some(many) {
        // Ctrl+A / Cmd+A / SelectAll
        let is_select_all = (k.code == listbox_key_select_all && (k.mods == 0 || k.mods == mod_ctrl || k.mods == mod_cmd)) ||
          ((k.mods == mod_ctrl || k.mods == mod_cmd) &&
            (k.code == typeahead_key_char + 'a'.to_int() || k.code == typeahead_key_char + 'A'.to_int()))
        if is_select_all {
          let (all_ids, _, is_off) = lb.selection_inputs()
          let next_ids = lb.selection.select_all(all_ids, disabled=is_off)
          many(lb.keys_of(next_ids))
          return true
        }
        // Shift+ArrowDown/Up/Home/End range extension
        if k.mods == mod_shift &&
          (k.code == group_key_down || k.code == group_key_up || k.code == group_key_home || k.code == group_key_end) {
          if lb.selection.anchor() is None {
            if v.tree.focused_now().0 is Some(f) {
              lb.selection.set_anchor(Some(f))
            }
          }
          if lb.options.step(k.code) is Some(target) {
            let (all_ids, cur_ids, is_off) = lb.selection_inputs()
            let next_ids = lb.selection.select_range(all_ids, cur_ids, target.id(), disabled=is_off)
            many(lb.keys_of(next_ids))
            return true
          }
        }
      }
      if k.mods == 0 && lb.options.step(k.code) is Some(_) {
        return true
      }
      let live = lb.options.live()
      lb.typeahead.handle_key(k, live, fn(i) {
        let id = live[i].id()
        match lb.entries.iter().find_first(fn(x) { x.node.id() == id }) {
          Some(x) => (x.text)()
          None => ""
        }
      })
    })
    |> ignore
  })
}

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
    self.entries.push({ node: v, key, off, text: text.unwrap_or(label) })
    v.owns(fn() {
      self.entries.retain(fn(e) { e.node.id() != v.id() })
      if self.entries.is_empty() {
        self.entries.shrink_to_fit()
      }
    })
    |> ignore
    look(v, { node: v, on, off })
    v
    .presses(By(able))
    .focusable(By(able), tab=false)
    .says(By(fn() { Some(@view.said(@view.Role::Option, label=label(), selected=on())) }))
    .on_press(fn() {
      if off() {
        return
      }
      if self.multiple && self.on_select_many is Some(many) && (self.shift_held)() {
        let (all_ids, cur_ids, is_off) = self.selection_inputs()
        let next_ids = self.selection.select_range(all_ids, cur_ids, v.id(), disabled=is_off)
        many(self.keys_of(next_ids))
        return
      }
      self.selection.set_anchor(Some(v.id()))
      if self.multiple || !on() {
        (self.pick)(key)
      }
    })
    |> ignore
    self.options.add(v, disabled=off, preferred=on)
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}
