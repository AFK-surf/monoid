// The accordion: a stack of sections, each a header that opens or closes its panel. Each header (`Accordion::trigger`) is
// a disclosure (disclosure.mbt): a button called by its label, read out expanded while its section is open, pressed by
// the pointer, Enter or Space, a screen reader's Activate, taking a press and the focus only while enabled (the whole
// accordion's `disabled` or its own). Each panel (`Accordion::panel`) is read out a `Region` called by its label.
//
// Which are open is its caller's (`is_open`), told the key of a section to turn (`on_toggle`) by a press on its header:
// `Single` (one open at a time: the caller opens it and closes the one open before), a press on the open one's header
// telling it only where it is `collapsible` (else it stays open, nothing told); `Multiple` (each its own), every press.
//
// Keys (WAI-ARIA's accordion): each header is a stop of Tab's; while one of them has the focus, ↓ and ↑ (`vertical`; →
// and ← where it is not) go to the enabled header after and before, around the ends unless `wraps` is false, Home and
// End to the first and the last, each showing the focus there; a disabled header is passed by.

///|
/// Whether one section is open at a time (`Single`: the open one's header closes it where `collapsible`), or each its
/// own (`Multiple`).
#derive(Eq, Debug)
pub(all) enum AccordionKind {
  Single(collapsible~ : Bool)
  Multiple
}

///|
/// An accordion handed to its look to make its headers and panels by (`Accordion::trigger`, `Accordion::panel`).
pub struct Accordion[K] {
  priv kind : AccordionKind
  priv is_open : (K) -> Bool
  priv on_toggle : (K) -> Unit
  priv off : () -> Bool
  priv heads : RovingFocus
}

///|
/// Whether the whole accordion is disabled (as its caller says).
pub fn[K] Accordion::disabled(self : Accordion[K]) -> Bool {
  (self.off)()
}

///|
/// Whether the section of `key` is open now (as its caller says).
pub fn[K] Accordion::is_open(self : Accordion[K], key : K) -> Bool {
  (self.is_open)(key)
}

///|
/// The focus asked onto the first enabled header, shown where `visible`. Whether one took it.
pub fn[K] Accordion::focus_first(self : Accordion[K], visible? : Bool = true) -> Bool {
  self.heads.focus_first(visible~)
}

///|
/// An accordion in `parent` (`parent` itself where `in_node`), its sections open as `is_open` says, `on_toggle` told the
/// key of one a press on its header turns; `kind` one at a time or each its own; `vertical`: its headers go down (↓ ↑),
/// else across (→ ←); `wraps`: the keys go round its ends; `disabled` while none of it takes a press or the focus.
/// `look` is given its node and the `Accordion[K]` its headers and panels are made by (directly or inside `View::each`),
/// once as it is made: all that is drawn of it and how it is laid out. Its node.
#callsite(autofill(loc))
pub fn[K] accordion(
  parent : @view.View,
  is_open : (K) -> Bool,
  on_toggle : (K) -> Unit,
  look : (@view.View, Accordion[K]) -> Unit,
  kind? : AccordionKind = Single(collapsible=true),
  vertical? : Bool = true,
  wraps? : Bool = true,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let heads = RovingFocus::new(axis=if vertical { Vertical } else { Horizontal }, roving=false, wraps~)
  let a : Accordion[K] = { kind, is_open, on_toggle, off: disabled, heads }
  let setup = fn(v : @view.View) {
    look(v, a)
    v.on_key(fn(k) {
      if k.mods != 0 || disabled() {
        return false
      }
      heads.step(k.code) is Some(_)
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
/// The header of the section of `key` in `parent`, called `label`: a disclosure (disclosure.mbt), expanded while its
/// section is open; `disabled` while this header alone takes no press and no focus. `look` as the disclosure's. Its node.
#callsite(autofill(loc))
pub fn[K] Accordion::trigger(
  self : Accordion[K],
  parent : @view.View,
  key : K,
  label : () -> String,
  look : (@view.View, Disclosure) -> Unit,
  disabled? : () -> Bool = fn() { false },
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let off = fn() { (self.off)() || disabled() }
  let press = fn(_ : @view.View) {
    let open = (self.is_open)(key)
    match self.kind {
      Single(collapsible~) => if !open || collapsible { (self.on_toggle)(key) }
      Multiple => (self.on_toggle)(key)
    }
  }
  disclosure(
    parent,
    label,
    fn() { (self.is_open)(key) },
    press,
    fn(v, d) {
      self.heads.add(v, disabled=off)
      look(v, d)
    },
    disabled=off,
    made_for=made_for.unwrap_or(loc),
    loc~,
  )
}

///|
/// The panel of the section of `key` in `parent`, read out a `Region` called `label`. `look` is run once as it is made,
/// given its node: all that is drawn of it and how it is laid out. Its caller makes it while the section is open
/// (View::show), or keeps it, hidden from what reads the screen and taking no input while closed. Its node.
#callsite(autofill(loc))
pub fn[K] Accordion::panel(
  self : Accordion[K],
  parent : @view.View,
  key : K,
  label : () -> String,
  look : (@view.View) -> Unit,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    let open = fn() { (self.is_open)(key) }
    look(v)
    v
    .says(By(fn() { Some(@view.said(Region, label=label())) }))
    .hides(By(fn() { !open() }))
    .presses(By(open))
    |> ignore
  })
}
