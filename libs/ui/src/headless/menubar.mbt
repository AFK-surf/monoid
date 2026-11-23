// The desktop menubar: a horizontal bar of top-level menu triggers (`Menubar::trigger`) sharing a single roving Tab
// stop, with ←/→ (RTL-aware) and Home/End focus movement, automatic hot-switching of `active` on arrow navigation or
// pointer hover while a menu is open, ↓/Enter/Space to open, and Escape to close while keeping focus on the trigger.
// Read out a `MenuBar` of `MenuItem` triggers (`expanded` while active). Nothing here is drawn or laid out.

///|
/// One registered trigger of a `Menubar[K]`.
priv struct MenubarEntry[K] {
  node : @view.View
  key : K
  off : () -> Bool
}

///|
/// A desktop menubar handed to its look to register its top-level menu triggers (`Menubar::trigger`).
pub struct Menubar[K] {
  priv node : @view.View
  priv active_ : () -> K?
  priv set_active : (K?) -> Unit
  priv off : () -> Bool
  priv rove : RovingFocus
  priv entries : Array[MenubarEntry[K]]
}

///|
/// The menubar's own node.
pub fn[K] Menubar::node(self : Menubar[K]) -> @view.View {
  self.node
}

///|
/// Whether the whole menubar is disabled (as its caller says).
pub fn[K] Menubar::disabled(self : Menubar[K]) -> Bool {
  (self.off)()
}

///|
/// The currently active (open) menu key, if any (as its caller says).
pub fn[K] Menubar::active(self : Menubar[K]) -> K? {
  (self.active_)()
}

///|
/// Whether any menu in the menubar is currently open.
pub fn[K] Menubar::open(self : Menubar[K]) -> Bool {
  (self.active_)() is Some(_)
}

///|
/// Close any open menu (`set_active(None)`).
pub fn[K] Menubar::close(self : Menubar[K]) -> Unit {
  if @signals.untracked(self.active_) is Some(_) {
    (self.set_active)(None)
  }
}

///|
/// Ask keyboard focus onto the menubar's current Tab stop, shown where `visible`. Returns whether a trigger took focus.
pub fn[K] Menubar::focus_stop(self : Menubar[K], visible? : Bool = true) -> Bool {
  self.rove.focus_stop(visible~)
}

///|
/// One top-level trigger of a `Menubar[K]` as its look reads it: each a reading, followed where a binding reads it.
pub struct MenubarTrigger {
  priv node : @view.View
  priv is_open : () -> Bool
  priv off : () -> Bool
}

///|
/// Whether this trigger's menu is currently active (open).
pub fn MenubarTrigger::open(self : MenubarTrigger) -> Bool {
  (self.is_open)()
}

///|
/// Whether this trigger is disabled (either the menubar or the trigger itself).
pub fn MenubarTrigger::disabled(self : MenubarTrigger) -> Bool {
  (self.off)()
}

///|
/// Whether this trigger has the keyboard's focus (View::focused).
pub fn MenubarTrigger::focused(self : MenubarTrigger) -> Bool {
  self.node.focused()
}

///|
/// Whether this trigger has the keyboard's focus and that shows (View::focus_shown).
pub fn MenubarTrigger::focus_shown(self : MenubarTrigger) -> Bool {
  self.node.focus_shown()
}

///|
/// Whether a pointer rests over this trigger now (View::pointed).
pub fn MenubarTrigger::hovered(self : MenubarTrigger) -> Bool {
  self.node.pointed()
}

///|
/// Whether a finger or the pointer is held on this trigger now (View::pressed).
pub fn MenubarTrigger::pressed(self : MenubarTrigger) -> Bool {
  self.node.pressed()
}

///|
/// A desktop menubar in `parent` (`parent` itself where `in_node`), called `label`, whose open menu key is controlled
/// by `active` / `set_active`. `look` receives its node and `Menubar[K]` once as it is made.
#callsite(autofill(loc))
pub fn[K : Eq] menubar(
  parent : @view.View,
  label : () -> String,
  active : () -> K?,
  set_active : (K?) -> Unit,
  look : (@view.View, Menubar[K]) -> Unit,
  rtl? : Bool = false,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let rove = RovingFocus::new(axis=Horizontal, roving=true, wraps=true, rtl~)
  let entries : Array[MenubarEntry[K]] = []
  let setup = fn(v : @view.View) {
    let mb : Menubar[K] = { node: v, active_: active, set_active, off: disabled, rove, entries }
    look(v, mb)
    v
    .says(By(fn() { Some(@view.said(MenuBar, label=label())) }))
    .on_key(fn(k) {
      if k.mods != 0 || disabled() || !focus_in(v, false) {
        return false
      }
      if k.code == menu_key_escape {
        match @signals.untracked(active) {
          Some(cur) => {
            set_active(None)
            match entries.iter().find_first(fn(e) { e.key == cur && e.node.takes_input() && !(e.off)() }) {
              Some(e) => e.node.ask_focus(visible=true) |> ignore
              None => ()
            }
            return true
          }
          None => return false
        }
      }
      if k.code == group_key_down {
        if v.tree.focused_now().0 is Some(fid) {
          match entries.iter().find_first(fn(e) { e.node.id() == fid && !(e.off)() }) {
            Some(e) => {
              if @signals.untracked(active) != Some(e.key) {
                set_active(Some(e.key))
              }
              return true
            }
            None => ()
          }
        }
        return false
      }
      match rove.step(k.code) {
        Some(target) => {
          if @signals.untracked(active) is Some(_) {
            match entries.iter().find_first(fn(e) { e.node.id() == target.id() }) {
              Some(e) =>
                if @signals.untracked(active) != Some(e.key) {
                  set_active(Some(e.key))
                }
              None => ()
            }
          }
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
/// Register a top-level menu trigger of `key` in `parent` (`parent` itself where `in_node`), called `label`.
/// Joins the menubar's single roving Tab stop; opens on press (`Enter`/`Space`/click) or `↓`; hot-switches `active`
/// when hovered while another menu in the menubar is open. Its node.
#callsite(autofill(loc))
pub fn[K : Eq] Menubar::trigger(
  self : Menubar[K],
  parent : @view.View,
  key : K,
  label : () -> String,
  look : (@view.View, MenubarTrigger) -> Unit,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    let off = fn() { (self.off)() || disabled() }
    let able = fn() { !off() }
    let is_open = fn() { (self.active_)() == Some(key) }
    self.entries.push({ node: v, key, off })
    v.owns(fn() {
      self.entries.retain(fn(e) { e.node.id() != v.id() })
      if self.entries.is_empty() {
        self.entries.shrink_to_fit()
      }
    })
    |> ignore
    look(v, { node: v, is_open, off })
    v
    .presses(By(able))
    .focusable(By(able), tab=false)
    .says(By(fn() { Some(@view.said(MenuItem, label=label(), expanded=is_open())) }))
    .on_press(fn() {
      if off() {
        return
      }
      if @signals.untracked(self.active_) == Some(key) {
        (self.set_active)(None)
      } else {
        (self.set_active)(Some(key))
      }
    })
    |> ignore
    v.reacts(fn() { v.pointed() }, fn(pointed) {
      if pointed && !off() {
        match @signals.untracked(self.active_) {
          Some(cur) if cur != key => (self.set_active)(Some(key))
          _ => ()
        }
      }
    })
    self.rove.add(v, disabled=off, preferred=is_open)
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}
