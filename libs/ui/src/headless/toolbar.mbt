// The toolbar: a container of interactive controls (buttons, toggles, disclosures) sharing a single roving Tab stop
// and arrow-key navigation along `axis` (WAI-ARIA toolbar pattern). Read out a `Toolbar` called by its label; each
// registered item (`Toolbar::item`) joins the toolbar's `RovingFocus` with focus recovery on removal. Nothing here is
// drawn or laid out.

///|
/// A toolbar handed to its look to register its interactive items (`Toolbar::item`).
pub struct Toolbar {
  priv node : @view.View
  priv off : () -> Bool
  priv items : RovingFocus
}

///|
/// The toolbar's own node.
pub fn Toolbar::node(self : Toolbar) -> @view.View {
  self.node
}

///|
/// Whether the whole toolbar is disabled (as its caller says).
pub fn Toolbar::disabled(self : Toolbar) -> Bool {
  (self.off)()
}

///|
/// Ask keyboard focus onto the toolbar's current Tab stop (last focused live item, else preferred, else first enabled),
/// shown where `visible`. Returns whether an item took focus.
pub fn Toolbar::focus_stop(self : Toolbar, visible? : Bool = true) -> Bool {
  self.items.focus_stop(visible~)
}

///|
/// A toolbar in `parent` (`parent` itself where `in_node`), called `label`. `look` receives its node and `Toolbar` once
/// as it is made. Arrow keys along `axis` (flipped horizontally when `rtl=true`), Home and End navigate among live
/// enabled items (wrapping around the ends when `wraps=true`). Its node.
#callsite(autofill(loc))
pub fn toolbar(
  parent : @view.View,
  label : () -> String,
  look : (@view.View, Toolbar) -> Unit,
  axis? : GroupAxis = Horizontal,
  wraps? : Bool = true,
  rtl? : Bool = false,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let items = RovingFocus::new(axis~, roving=true, wraps~, rtl~)
  let setup = fn(v : @view.View) {
    let tb : Toolbar = { node: v, off: disabled, items }
    look(v, tb)
    v
    .says(By(fn() { Some(@view.said(Toolbar, label=label())) }))
    .on_key(fn(k) {
      if k.mods != 0 || disabled() {
        return false
      }
      items.step(k.code) is Some(_)
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
/// Register an item in `parent` (`parent` itself where `in_node`, e.g. an already-created `@headless.button` or
/// `@headless.toggle` node) into this toolbar's roving Tab stop and arrow-key navigation. `look` runs before the roving
/// Tab stop is bound so any `focusable` set by `look` (or a headless control inside it) yields its Tab stop to the
/// toolbar. Its node.
#callsite(autofill(loc))
pub fn Toolbar::item(
  self : Toolbar,
  parent : @view.View,
  look : (@view.View) -> Unit,
  disabled? : () -> Bool = fn() { false },
  preferred? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let off = fn() { (self.off)() || disabled() }
  let setup = fn(v : @view.View) {
    look(v)
    self.items.add(v, disabled=off, preferred~)
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}
