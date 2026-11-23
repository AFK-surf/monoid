// The combobox: a list of options to choose one of, filtered by what is written in a field beside it (a select with
// a search, a command palette, an `@` that offers names). Its node says it is a `Combobox` called by its label,
// expanded while `open` says so; the list made by `Combobox::listbox` a `Listbox`; each option made by
// `Combobox::option` an `Option`, called by its own label and selected while it is the one `chosen`. The field is the
// caller's (ui's field, made by its look in the combobox's node or in a part of it): the component writes in it, reads
// it and focuses it never.
//
// Which option the keys are on (`active`): the caller's to keep, as the filter is (headless.mbt, State: what decides
// what is read out and what Enter does), told by `activate`. What is active now is the one `active` says while it is
// among the keys shown (`keys`, the same the look's list is made of) and enabled, else the first enabled one shown: a
// filter that takes the active option away, or disables it, moves it to the first that is left, with nothing told.
//
// Keys. The options never take the focus: the keyboard stays where it is (the field, its caret and its input method;
// or, with no field, the list itself, `field` false, which then takes the focus by Tab), and ↓ ↑ move what is active
// among the enabled options shown, around the ends unless `wraps` is false, Home and End to the first and the last
// (with no field: in a field they move its caret), Enter chooses the active one (`choose` told its key), Escape tells
// `on_close`. Taken while the combobox is open and enabled and the focus is in it, or nowhere in its tree (a palette
// opened by a pointer). A field's own keys (its arrows and its Enter) are never asked of a node's `on_key` (ui's
// view_host: the field's or the keymap's), so from a field they come as the keymap's actions, said by the
// combobox's node (`combobox_*`, in its key context `Combobox`) and bound by `combobox_keys`, which an app puts in its
// keymap (View::keymap). With the focus elsewhere in it, they come as keys (`on_key`), keymap or not; Escape so from
// the field too.
//
// The hand. Pressing an option (the pointer, a finger, a screen reader's Activate) makes it active and chooses it at
// once, never while it is disabled: on a phone a tap on an option is all it takes, and moves no focus, so no soft
// keyboard comes up for it. Opening it is the caller's (a button, a shortcut's action), and so is giving the field the
// focus (ui's Field::focus): from the keyboard as it opens, on a phone not till a finger taps the field, so the half of
// the screen the options are on is not put under a keyboard nobody asked for. A shortcut that opens it is the keymap's
// action, which takes its key whole: nothing of that key is written in the field (ui's on_key_now ends at a key the
// tree took).
//
// What its look reads of an option: active (the keys on it), chosen, disabled, hovered (the pointer over it), pressed.

///|
/// What the keys do in a combobox, by name (View::on_action's): the next enabled option shown made active, the one
/// before, the first, the last; the active one chosen; it closed.
pub let combobox_next : String = "combobox.next"

///|
pub let combobox_prev : String = "combobox.prev"

///|
pub let combobox_first : String = "combobox.first"

///|
pub let combobox_last : String = "combobox.last"

///|
pub let combobox_choose : String = "combobox.choose"

///|
pub let combobox_close : String = "combobox.close"

///|
/// The key context a combobox's node says (View::key_context): its bindings work in it.
pub let combobox_context : String = "Combobox"

///|
/// The keys of a combobox's actions (ui's key codes: ↓ 6, ↑ 5, Enter 7, Escape 17, Home 8, End 9), none held, where
/// a combobox is: ↓ ↑ Enter and Escape from its field too, Home and End only where no field has the focus (there they
/// are the caret's). An app with a combobox whose field has the focus puts these in its keymap (View::keymap).
pub let combobox_keys : Array[@view.Binding] = {
  let here : @view.KeyWhen = In(combobox_context)
  let not_field : @view.KeyWhen = All([In(combobox_context), Not(In("Field"))])
  [
    { keys: [{ code: 6, mods: 0 }], action: combobox_next, when: here },
    { keys: [{ code: 5, mods: 0 }], action: combobox_prev, when: here },
    { keys: [{ code: 7, mods: 0 }], action: combobox_choose, when: here },
    { keys: [{ code: 17, mods: 0 }], action: combobox_close, when: here },
    { keys: [{ code: 8, mods: 0 }], action: combobox_first, when: not_field },
    { keys: [{ code: 9, mods: 0 }], action: combobox_last, when: not_field },
  ]
}

///|
/// What a key or an action does in a combobox.
priv enum ComboStep {
  Next
  Prev
  First
  Last
  Choose
  Close
}

///|
/// A combobox as its look reads it and makes its list and options by (`Combobox::listbox`, `Combobox::option`).
pub struct Combobox[K] {
  priv node : @view.View
  priv label : () -> String
  priv keys : () -> Array[K]
  priv now : () -> K?
  priv chosen : () -> K?
  priv off : () -> Bool
  priv key_off : (K) -> Bool
  priv activate : (K?) -> Unit
  priv moved : (K) -> Unit
  priv choose : (K) -> Unit
  priv field : Bool
}

///|
/// The combobox's own node: what its field and its list are made in, where they are not made in a part of it.
pub fn[K] Combobox::node(self : Combobox[K]) -> @view.View {
  self.node
}

///|
/// Whether the whole combobox is disabled (as its caller says).
pub fn[K] Combobox::disabled(self : Combobox[K]) -> Bool {
  (self.off)()
}

///|
/// The option active now: the one its caller says while that is shown and enabled, else the first enabled one shown
/// (none: none is). Followed where a binding reads it (a look bringing it into view).
pub fn[K] Combobox::active(self : Combobox[K]) -> K? {
  (self.now)()
}

///|
/// The active option worked out of what its caller says and the keys shown (Combobox::active's).
fn[K : Eq] active_of(keys : Array[K], active : K?, off : (K) -> Bool) -> K? {
  match active {
    Some(a) if keys.contains(a) && !off(a) => Some(a)
    _ => keys.iter().find_first(fn(k) { !off(k) })
  }
}

///|
/// `step` done in combobox `self` while it takes keys (`open`): what is active moved, the active one chosen or it
/// closed. Whether it was done.
fn[K : Eq] Combobox::step(
  self : Combobox[K],
  step : ComboStep,
  wraps : Bool,
  on_close : (() -> Unit)?,
) -> Bool {
  if (self.off)() {
    return false
  }
  match step {
    Close =>
      match on_close {
        Some(f) => {
          f()
          true
        }
        None => false
      }
    Choose =>
      match (self.now)() {
        Some(k) => {
          (self.choose)(k)
          true
        }
        None => false
      }
    _ => {
      let live = (self.keys)().filter(fn(k) { !(self.key_off)(k) })
      let n = live.length()
      if n == 0 {
        return false
      }
      let at = match (self.now)() {
        Some(a) => live.search(a)
        None => None
      }
      let j = match step {
        Next =>
          match at {
            None => 0
            Some(i) if i + 1 < n => i + 1
            Some(_) => if wraps { 0 } else { n - 1 }
          }
        Prev =>
          match at {
            None => n - 1
            Some(i) if i > 0 => i - 1
            Some(_) => if wraps { n - 1 } else { 0 }
          }
        First => 0
        _ => n - 1
      }
      (self.activate)(Some(live[j]))
      (self.moved)(live[j])
      true
    }
  }
}

///|
/// A combobox in `parent`, called `label` (what a screen reader says), expanded while `open` says so; `keys` the
/// options shown now, in order (filtered as its caller filters them: what its look's list is made of); `active` which
/// of them its caller keeps the keys on and `activate` told one to move them to; `choose` told the key chosen (Enter on
/// the active one, a press on one); `chosen` which is the one chosen (read out selected); `key_disabled` an option that
/// takes no press and that the keys pass by; `disabled` while none of it does; `on_close` told by Escape; `wraps`
/// whether ↓ past the last comes to the first and ↑ before the first to the last; `field` whether a field in it keeps
/// the keyboard (false: its list takes the focus by Tab, a select with no search). `moved` told the key the keys made
/// active (↓ ↑ Home End), after `activate`: what a look brings into view, where a press (already in view) brings
/// nothing. `look` is given its node and the `Combobox[K]` its list and options are made by, once as it is made, in
/// `parent` itself where `in_node` (the box that holds its field). Its node.
#callsite(autofill(loc))
pub fn[K : Eq] combobox(
  parent : @view.View,
  label : () -> String,
  keys : () -> Array[K],
  active : () -> K?,
  activate : (K?) -> Unit,
  choose : (K) -> Unit,
  look : (@view.View, Combobox[K]) -> Unit,
  chosen? : () -> K? = fn() { None },
  open? : () -> Bool = fn() { true },
  key_disabled? : (K) -> Bool = fn(_) { false },
  disabled? : () -> Bool = fn() { false },
  on_close? : () -> Unit,
  wraps? : Bool = true,
  field? : Bool = true,
  moved? : (K) -> Unit = fn(_) {  },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    let now = fn() { active_of(keys(), active(), key_disabled) }
    let cb : Combobox[K] = {
      node: v,
      label,
      keys,
      now,
      chosen,
      off: disabled,
      key_off: key_disabled,
      activate,
      moved,
      choose,
      field,
    }
    look(v, cb)
    let takes = fn() { !disabled() && open() && focus_in(v, true) }
    let act = fn(step : ComboStep) { fn(_ : @view.ActionAt) { cb.step(step, wraps, on_close) } }
    v
    .says(By(fn() { Some(@view.said(Combobox, label=label(), expanded=open())) }))
    .key_context(combobox_context)
    .on_action(combobox_next, act(Next), can=takes)
    .on_action(combobox_prev, act(Prev), can=takes)
    .on_action(combobox_first, act(First), can=takes)
    .on_action(combobox_last, act(Last), can=takes)
    .on_action(combobox_choose, act(Choose), can=takes)
    .on_action(combobox_close, act(Close), can=fn() { takes() && on_close is Some(_) })
    .on_key(fn(k) {
      if k.mods != 0 || !takes() {
        return false
      }
      let step = if k.code == menu_key_down {
        Some(Next)
      } else if k.code == menu_key_up {
        Some(Prev)
      } else if k.code == menu_key_home && !field {
        Some(First)
      } else if k.code == menu_key_end && !field {
        Some(Last)
      } else if k.code == combo_key_enter || (k.code == combo_key_space && !field) {
        Some(Choose)
      } else if k.code == menu_key_escape {
        Some(Close)
      } else {
        None
      }
      match step {
        Some(s) => cb.step(s, wraps, on_close)
        None => false
      }
    })
    |> ignore
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}

///|
/// Enter's and Space's key codes (ui's `key_code_enter`; `key_space`, Space with no field focused).
let combo_key_enter : Int = 7

///|
let combo_key_space : Int = 1032

///|
/// The list of `self`'s options in `parent` (`parent` itself where `in_node`), called `label` where it is given one
/// (none: the combobox's). Where the combobox has no field (its `field` false) it takes the keyboard's focus by
/// Tab, the keys going among its options from there, Enter and Space choosing the active one. `look` is given its node
/// once as it is made. Its node.
#callsite(autofill(loc))
pub fn[K] Combobox::listbox(
  self : Combobox[K],
  parent : @view.View,
  look : (@view.View) -> Unit,
  label? : () -> String,
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    look(v)
    v
    .says(
      By(fn() { Some(@view.said(Listbox, label=label.unwrap_or(self.label)())) }),
    )
    |> ignore
    if !self.field {
      let able = fn() { !(self.off)() }
      v.presses(By(able)).focusable(By(able), keys=0) |> ignore
    }
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}

///|
/// An option of a `Combobox[K]` as its look reads it: each a reading, followed where a binding reads it.
pub struct ComboOption {
  priv node : @view.View
  priv is_active : () -> Bool
  priv is_chosen : () -> Bool
  priv off : () -> Bool
}

///|
/// Whether the keys are on it now (Combobox::active): what Enter chooses.
pub fn ComboOption::active(self : ComboOption) -> Bool {
  (self.is_active)()
}

///|
/// Whether it is the one chosen (as its caller says).
pub fn ComboOption::chosen(self : ComboOption) -> Bool {
  (self.is_chosen)()
}

///|
/// Whether it is disabled (the combobox or the option itself): it takes no press and the keys pass it by.
pub fn ComboOption::disabled(self : ComboOption) -> Bool {
  (self.off)()
}

///|
/// Whether a pointer rests over it now (View::pointed): a mouse's, never a finger's.
pub fn ComboOption::hovered(self : ComboOption) -> Bool {
  self.node.pointed()
}

///|
/// Whether a finger or the pointer is held on it now (View::pressed).
pub fn ComboOption::pressed(self : ComboOption) -> Bool {
  self.node.pressed()
}

///|
/// Pressed now, for what a look adds that ends in a press: asked of the tree as a press delivered to the option's node
/// (View::press). Called from a handler, never as something is drawn.
pub fn ComboOption::press(self : ComboOption) -> Unit {
  self.node.press() |> ignore
}

///|
/// An option of `self` in `parent` (the list's node, a part of it, or `parent` itself where `in_node`: the row
/// `View::each` made for its key), its key `key` and called `label`. It takes no focus; pressed (not while disabled)
/// it is made active and chosen. `look` is given its node and its `ComboOption` once as it is made. Its node.
#callsite(autofill(loc))
pub fn[K : Eq] Combobox::option(
  self : Combobox[K],
  parent : @view.View,
  key : () -> K,
  label : () -> String,
  look : (@view.View, ComboOption) -> Unit,
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    let off = fn() { (self.off)() || (self.key_off)(key()) }
    let able = fn() { !off() }
    let is_active = fn() { (self.now)() == Some(key()) }
    let is_chosen = fn() { (self.chosen)() == Some(key()) }
    look(v, { node: v, is_active, is_chosen, off })
    v
    .presses(By(able))
    .says(By(fn() { Some(@view.said(Option, label=label(), selected=is_chosen())) }))
    .on_press(fn() {
      if !off() {
        let k = key()
        (self.activate)(Some(k))
        (self.choose)(k)
      }
    })
    |> ignore
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}
