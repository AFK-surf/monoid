// The menu: a list of things to do, one of them done by a press and the menu then the caller's to close. The menu says
// it is a `Menu` called by its label; each item made by `Menu::item` a `MenuItem` (an action), by `Menu::check_item`
// a `MenuItemCheckbox` (checked `On` or `Off` as its caller says) and by `Menu::radio_item` a `MenuItemRadio` (one of
// several, checked as its caller says), each called by its own label. An item may be the node a structure made for it
// (`in_node`: a row of `View::each`), said to be what it is and no node more, as a table's row is (table.mbt).
//
// Focus and keys (WAI-ARIA's menu). An item takes the keyboard's focus while it is enabled, as it is asked for it, Tab
// passing it by: the keys go among the items, Tab out of the menu. While the focus is in the menu, or nowhere (a menu a
// pointer opened, the keys its first), ↓ and ↑ go to the enabled item after and before (from nowhere ↓ the first and ↑
// the last), around its ends unless `wraps` is false, and Home and End to the first and the last, each moving the
// focus shown there; disabled items are passed by. Pressing an item (the pointer, Enter or Space while it has the
// focus, a screen reader's Activate) does what it does (`act`), never while it is disabled. Escape, and `close_key`
// (the arrow toward the side a submenu opened from: the caller's, its look given the same, headless.mbt) while the
// focus is in it, tell `on_close`: the caller closes what holds the menu and gives the focus back to what opened it.
// Where it opens, the caller asks the focus onto its first item by the keys (`Menu::focus_first`), or leaves it where
// it is for the pointer: on the menu itself where it `takes_focus` (nothing lit, the keys its, ↓ the first and ↑ the
// last as from nowhere; no key presses it), else where it was. `roving` (Radix's roving focus): Tab stops on one of its
// items, the last that had the focus while it is still enabled, else the first enabled, as a group of them takes one
// stop; else Tab passes them all by.
//
// Letters typed (typeahead, unless `typeahead` is false) while the keys are the menu's, as its arrows are, go to the next
// enabled item whose label begins with what was typed: what was typed within `typeahead_ms` of the letter before it
// together (at each key's own moment: the same at any rate of frames), the same letter again going on to the next
// that begins with it, as a list box's do (listbox.mbt).
//
// An item may open a submenu (`Menu::sub_trigger`, submenu.mbt), read out expanded while it is open.
//
// What its look reads of an item: disabled, hovered (the pointer over it), pressed, focused (the keys on it, however
// they came), focus shown (they came by the keys), checked (a check's or a radio's), open (a submenu's trigger's).

///|
/// One item of a `Menu` as the keys go among them.
priv struct MenuEntry {
  node : @view.View
  off : () -> Bool
  /// (its words, as typeahead finds it: its label)
  text : () -> String
}

///|
/// Where Tab stops among a roving menu's items: the last of them that had the focus (none yet), and a count of the
/// items made and let go, each a change of it (what a stop reads to follow them).
priv struct MenuStop {
  last : @signals.Signal[@view.NodeId?]
  made : @signals.Signal[Int]
}

///|
/// A menu as its look reads it and makes its items by (`Menu::item`, `Menu::check_item`, `Menu::radio_item`).
pub struct Menu {
  priv node : @view.View
  priv off : () -> Bool
  priv items : Array[MenuEntry]
  priv stop : MenuStop?
  /// (what was typed together, and the moment of its last letter)
  priv typed : Ref[(String, Double)]
}

///|
/// The menu's own node: what its items are made in, where they are not made in a part of it.
pub fn Menu::node(self : Menu) -> @view.View {
  self.node
}

///|
/// Whether the whole menu is disabled (as its caller says).
pub fn Menu::disabled(self : Menu) -> Bool {
  (self.off)()
}

///|
/// Its enabled items that take input now (living, not leaving: an item a structure lets go of goes its way out still
/// living), in the order they were made.
fn Menu::live(self : Menu) -> Array[MenuEntry] {
  if (self.off)() {
    return []
  }
  self.items.filter(fn(e) { e.node.takes_input() && !(e.off)() })
}

///|
/// The item Tab stops on in a roving menu: the last that had the focus while it is still enabled, else the first
/// enabled; none in a menu not roving, or with none enabled. Followed where a binding reads it.
fn Menu::stop_at(self : Menu) -> @view.NodeId? {
  guard self.stop is Some(st) else { return None }
  st.made.get() |> ignore
  // (an item still leaving, made another kind or let go as the menu stays open, is none to stop on)
  let live = self.items.filter(fn(e) { e.node.takes_input() && !(e.off)() })
  match st.last.get() {
    Some(id) if live.iter().any(fn(e) { e.node.id() == id }) => Some(id)
    _ =>
      match live {
        [first, ..] => Some(first.node.id())
        [] => None
      }
  }
}

///|
/// The focus asked onto its first enabled item, shown where `visible` (it came by the keys). Whether one took it.
/// Called from a handler (what opens it, a key, a moment), never as something is drawn.
pub fn Menu::focus_first(self : Menu, visible? : Bool = true) -> Bool {
  match self.live() {
    [first, ..] => first.node.ask_focus(visible~)
    [] => false
  }
}

///|
/// The focus asked onto its last enabled item (Menu::focus_first's).
pub fn Menu::focus_last(self : Menu, visible? : Bool = true) -> Bool {
  match self.live() {
    [.., last] => last.node.ask_focus(visible~)
    [] => false
  }
}

///|
/// An item of a `Menu` as its look reads it: each a reading, followed where a binding reads it.
pub struct MenuItem {
  priv node : @view.View
  priv on : () -> Bool
  priv off : () -> Bool
  priv open : () -> Bool
}

///|
/// Whether the submenu it opens is open (a submenu's trigger's, as its caller says); any other item's never.
pub fn MenuItem::open(self : MenuItem) -> Bool {
  (self.open)()
}

///|
/// Whether it is disabled (the menu or the item itself): it takes no press and no focus.
pub fn MenuItem::disabled(self : MenuItem) -> Bool {
  (self.off)()
}

///|
/// Whether it is checked (a check's or a radio's, as its caller says); an action's never.
pub fn MenuItem::checked(self : MenuItem) -> Bool {
  (self.on)()
}

///|
/// Whether a pointer rests over it now (View::pointed): a mouse's, never a finger's.
pub fn MenuItem::hovered(self : MenuItem) -> Bool {
  self.node.pointed()
}

///|
/// Whether a finger or the pointer is held on it now (View::pressed).
pub fn MenuItem::pressed(self : MenuItem) -> Bool {
  self.node.pressed()
}

///|
/// Whether it has the keyboard's focus (View::focused), whether that shows or not: the item the keys are on.
pub fn MenuItem::focused(self : MenuItem) -> Bool {
  self.node.focused()
}

///|
/// Whether it has the keyboard's focus and that shows (it came by the keys: View::focus_shown).
pub fn MenuItem::focus_shown(self : MenuItem) -> Bool {
  self.node.focus_shown()
}

///|
/// Pressed now, for what a look adds that ends in a press: asked of the tree as a press delivered to the item's node
/// (View::press). Called from a handler, never as something is drawn.
pub fn MenuItem::press(self : MenuItem) -> Unit {
  self.node.press() |> ignore
}

///|
/// The key codes the menu takes (`ui`'s `key_code_*`, `key_escape`).
let menu_key_up : Int = 5

///|
let menu_key_down : Int = 6

///|
let menu_key_home : Int = 8

///|
let menu_key_end : Int = 9

///|
let menu_key_escape : Int = 17

///|
/// Whether the keyboard's focus is in `v` (itself or what it holds), or, where `or_none`, nowhere in its tree.
fn focus_in(v : @view.View, or_none : Bool) -> Bool {
  match v.tree.focused_now().0 {
    Some(f) => v.tree.holds(v.id(), f)
    None => or_none
  }
}

///|
/// A menu in `parent` (`parent` itself where `in_node`), called `label` where it is given one. `look` is given its node
/// and the `Menu` its items are made by (directly or inside `View::each`), once as it is made: all that is drawn of it
/// and how it is laid out. `on_close` told by Escape, and by `close_key` (a submenu's arrow toward its parent), while
/// the focus is in it; `wraps`: whether ↓ past the last item comes to the first, and ↑ before the first to the last;
/// `disabled` while none of it takes a press or the focus; `takes_focus`: the menu itself takes the focus as it is given
/// it (one opened by the pointer, its keys from nowhere), no key pressing it, one stop of Tab's; `roving`: Tab stops on
/// one of its items (the last that had the focus, else the first); `typeahead`: letters typed go to the next item whose
/// label begins with them, `typeahead_ms` how long after a letter the next is typed with it. Its node.
#callsite(autofill(loc))
pub fn menu(
  parent : @view.View,
  look : (@view.View, Menu) -> Unit,
  label? : () -> String,
  on_close? : () -> Unit,
  close_key? : Int,
  wraps? : Bool = true,
  disabled? : () -> Bool = fn() { false },
  takes_focus? : Bool = false,
  roving? : Bool = false,
  typeahead? : Bool = true,
  typeahead_ms? : Double = 500.0,
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    let stop : MenuStop? = if roving { Some({ last: @signals.signal(None), made: @signals.signal(0) }) } else { None }
    let m : Menu = { node: v, off: disabled, items: [], stop, typed: Ref(("", 0.0)) }
    look(v, m)
    if takes_focus {
      v.focusable(Is(true), keys=0) |> ignore
    }
    v
    .says(
      match label {
        Some(f) => By(fn() { Some(@view.said(Menu, label=f())) })
        None => Is(Some(@view.said(Menu)))
      },
    )
    .on_key(fn(k) {
      if disabled() {
        return false
      }
      // (a character typed, Space aside (it presses what has the focus); with Shift as without; the keys the menu's as
      // its arrows' are)
      if typeahead &&
        k.code > listbox_key_char &&
        k.code != listbox_key_space &&
        (k.mods == 0 || k.mods == shift_mod) {
        // (the keys on one of its items, on itself, or nowhere where it takes no focus itself: never on what else it
        // holds (a field in it, whose letters are its own))
        let ours = match v.tree.focused_now().0 {
          Some(f) => f == v.id() || m.items.iter().any(fn(e) { e.node.id() == f })
          None => !takes_focus
        }
        if !ours {
          return false
        }
        let live = m.live()
        let c = (k.code - listbox_key_char).unsafe_to_char()
        return type_ahead(m.typed, c, k.at, typeahead_ms, live.map(fn(e) { e.node }), fn(i) { (live[i].text)() })
      }
      if k.mods != 0 {
        return false
      }
      let closing = k.code == menu_key_escape || close_key == Some(k.code)
      if closing {
        match on_close {
          Some(f) if focus_in(v, k.code == menu_key_escape) => {
            f()
            return true
          }
          _ => return false
        }
      }
      // (from nowhere, the focus on no node of the tree's (one opened by the keys); never so for one that takes the
      // focus itself, which has it while its keys are its: the focus elsewhere, held outside the tree (an old view's
      // field kept as the menu opened beside it), the keys are that one's)
      if !focus_in(v, !takes_focus) {
        return false
      }
      let live = m.live()
      let n = live.length()
      if n == 0 {
        return false
      }
      let at = live.search_by(fn(e) { e.node.focused() })
      let to = if k.code == menu_key_down {
        match at {
          None => Some(0)
          Some(i) if i + 1 < n => Some(i + 1)
          Some(_) => if wraps { Some(0) } else { Some(n - 1) }
        }
      } else if k.code == menu_key_up {
        match at {
          None => Some(n - 1)
          Some(i) if i > 0 => Some(i - 1)
          Some(_) => if wraps { Some(n - 1) } else { Some(0) }
        }
      } else if k.code == menu_key_home {
        Some(0)
      } else if k.code == menu_key_end {
        Some(n - 1)
      } else {
        None
      }
      match to {
        Some(j) => {
          live[j].node.ask_focus(visible=true) |> ignore
          true
        }
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
/// The node of an item of `self` in `parent` (`parent` itself where `in_node`), said `role` (with its check where
/// `check` is one) and called `label`, handed to `look` and then said what it is.
fn Menu::part(
  self : Menu,
  parent : @view.View,
  role : @view.Role,
  label : () -> String,
  check : (() -> Bool)?,
  expanded : (() -> Bool)?,
  act : (@view.View) -> Unit,
  look : (@view.View, MenuItem) -> Unit,
  disabled : () -> Bool,
  in_node : Bool,
  made_for : SourceLoc?,
  loc : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    let off = fn() { (self.off)() || disabled() }
    let able = fn() { !off() }
    let on = match check {
      Some(f) => f
      None => fn() { false }
    }
    self.items.push({ node: v, off, text: label })
    let made = fn() {
      match self.stop {
        Some(st) => st.made.set(st.made.untracked() + 1)
        None => ()
      }
    }
    made()
    v.owns(fn() {
      self.items.retain(fn(e) { e.node.id() != v.id() })
      made()
    })
    |> ignore
    look(v, { node: v, on, off, open: expanded.unwrap_or(fn() { false }) })
    v
    .presses(By(able))
    .focusable(By(able), tab=false)
    .says(By(fn() {
      match (check, expanded) {
        (Some(f), _) => Some(@view.said(role, label=label(), check=if f() { On } else { Off }))
        (None, Some(e)) => Some(@view.said(role, label=label(), expanded=e()))
        (None, None) => Some(@view.said(role, label=label()))
      }
    }))
    .on_press(fn() {
      if !off() {
        act(v)
      }
    })
    |> ignore
    // (roving: Tab's one stop among the items, the last with the focus; said after `focusable`, which lets a stop go)
    match self.stop {
      Some(st) => {
        v.tab_stop(By(fn() { self.stop_at() == Some(v.id()) })) |> ignore
        v.reacts(fn() { v.focused() }, fn(f) { if f { st.last.set(Some(v.id())) } })
      }
      None => ()
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
/// An action of `self` in `parent` (the menu's node, a part of it, or `parent` itself where `in_node`: the row a
/// structure made), called `label`; `act` done as it is pressed, given its node; `disabled` while this item alone
/// takes no press and no focus. `look` is given its node and its `MenuItem` once as it is made. Its node.
#callsite(autofill(loc))
pub fn Menu::item(
  self : Menu,
  parent : @view.View,
  label : () -> String,
  act : (@view.View) -> Unit,
  look : (@view.View, MenuItem) -> Unit,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  self.part(parent, MenuItem, label, None, None, act, look, disabled, in_node, made_for, loc)
}

///|
/// A check of `self` (Menu::item's), checked while `checked` says so; `act` told as it is pressed (the caller turns
/// it). Its node.
#callsite(autofill(loc))
pub fn Menu::check_item(
  self : Menu,
  parent : @view.View,
  label : () -> String,
  checked : () -> Bool,
  act : (@view.View) -> Unit,
  look : (@view.View, MenuItem) -> Unit,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  self.part(parent, MenuItemCheckbox, label, Some(checked), None, act, look, disabled, in_node, made_for, loc)
}

///|
/// A radio of `self` (Menu::item's), one of several of which `checked` says this is the one now; `act` told as it is
/// pressed (the caller chooses it). Its node.
#callsite(autofill(loc))
pub fn Menu::radio_item(
  self : Menu,
  parent : @view.View,
  label : () -> String,
  checked : () -> Bool,
  act : (@view.View) -> Unit,
  look : (@view.View, MenuItem) -> Unit,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  self.part(parent, MenuItemRadio, label, Some(checked), None, act, look, disabled, in_node, made_for, loc)
}
