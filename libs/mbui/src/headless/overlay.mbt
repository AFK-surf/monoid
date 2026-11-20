// The overlay: one layer of a window's stack of what floats over the rest (a dialog, a sheet, a popover, a menu, a
// toast), and what that stack decides between its layers (Radix's DismissableLayer and FocusScope as one stack): which
// one Escape and the system's back close, and which one a press outside closes. Each overlay is a node its caller makes
// while it shows (View::show); it joins its tree's stack as it is made, above all that are there, and leaves it as it is
// let go (View::owns), so a stack holds only what lives.
//
// What the stack decides, once an event, whichever of its layers is asked first:
//   - Escape and back: the topmost layer that takes them (`dismiss_on_escape`) and is not inert is told (`on_dismiss`,
//     Escape or Back); none under it, and a layer above it that takes neither (a toast) lets them through to it.
//   - a press that goes down anywhere in the window: the topmost layer that a press outside closes (`dismiss_on_outside`)
//     and is not inert is told Outside, where the press is on neither it, nor any layer above it, nor its `anchor` (what
//     opened it: a press there is that one's, which toggles it; under a modal layer it is covered, and a press there
//     outside as any). One press closes one layer: a menu opened on a dialog
//     closes by a press on the dialog, the dialog stays.
//   - inert (`inert`, or leaving: its way out drawn): it takes nothing and is read out as nothing, and the stack decides
//     as though it were not there.
//
// What the overlay says of its node, besides: a modal layer while not inert (`modal`: View::modal), the focus given to
// the first of what it holds that takes it as it opens (`auto_focus`: View::focus_opens_first) or left where it is
// (View::focus_returns), and back to `anchor` (or to what had it) as it goes (`return_focus`: View::opened_by), read out
// a Dialog called `label` where it has one. Where it goes and what is drawn of it (a layer over all, its scrim, its
// card) is its look's (headless.mbt): nothing of it is said here.
//
// A keyboard trap without a modal layer (focus kept in, the pointer free) is not here: the tree has no such word, and
// a component never goes around the tree (headless.mbt). Modal, the keys are kept in as the pointer is.

///|
/// What would close an overlay, as its `on_dismiss` is told: Escape, a press outside it, or the system's back.
#derive(Eq, Debug)
pub(all) enum OverlayDismiss {
  Escape
  Outside
  Back
}

///|
/// A layer of a stack, as the stack keeps it.
priv struct OverlayEntry {
  id : @view.NodeId
  node : @view.View
  dismiss : (OverlayDismiss) -> Unit
  inert : () -> Bool
  escape : Bool
  outside : Bool
  anchor : @view.View?
}

///|
/// A tree's stack of overlays, the lowest first; `changed` told as one joins or leaves; `down`: the last window press
/// it decided (View::window_downs), so each is decided once whichever layer is told of it first.
priv struct OverlayStack {
  tree : @view.Tree
  entries : Array[OverlayEntry]
  changed : @signals.Signal[Int]
  mut down : Int
}

///|
/// The stacks of the trees that have overlays now, each kept while it holds one.
let overlay_stacks : Array[OverlayStack] = []

///|
/// The stack of `tree` (made where it has none).
fn overlay_stack(tree : @view.Tree) -> OverlayStack {
  for s in overlay_stacks {
    if physical_equal(s.tree, tree) {
      return s
    }
  }
  let s = { tree, entries: [], changed: @signals.signal(0), down: -1 }
  overlay_stacks.push(s)
  s
}

///|
/// Layer `id` taken out of the stack, and the stack let go of once it holds none.
fn OverlayStack::drop(self : OverlayStack, id : @view.NodeId) -> Unit {
  for i, e in self.entries {
    if e.id == id {
      self.entries.remove(i) |> ignore
      break
    }
  }
  self.changed.set(self.changed.untracked() + 1)
  if self.entries.is_empty() {
    for i, s in overlay_stacks {
      if physical_equal(s, self) {
        overlay_stacks.remove(i) |> ignore
        break
      }
    }
  }
}

///|
/// Where the topmost layer that `takes` says of and is not inert is in the stack (-1: none).
fn OverlayStack::top_where(self : OverlayStack, takes : (OverlayEntry) -> Bool) -> Int {
  let mut i = self.entries.length() - 1
  while i >= 0 {
    let e = self.entries[i]
    if takes(e) && !(e.inert)() {
      return i
    }
    i = i - 1
  }
  -1
}

///|
/// Escape or back (`how`) decided: the topmost layer that takes them told. Whether one was.
fn OverlayStack::escape(self : OverlayStack, how : OverlayDismiss) -> Bool {
  let i = self.top_where(fn(e) { e.escape })
  guard i >= 0 else { return false }
  (self.entries[i].dismiss)(how)
  true
}

///|
/// Window press `count`, gone down at (`x`, `y`), decided once: the topmost layer a press outside closes told, where
/// the press is on neither it, nor what is above it, nor its anchor.
fn OverlayStack::press(self : OverlayStack, count : Int, x : Double, y : Double) -> Unit {
  guard self.down != count else { return }
  self.down = count
  let i = self.top_where(fn(e) { e.outside })
  guard i >= 0 else { return }
  let top = self.entries[i]
  for j in i..<self.entries.length() {
    if press_on(self.entries[j].node, x, y) {
      return
    }
  }
  if top.anchor is Some(a) && press_on(a, x, y) {
    return
  }
  (top.dismiss)(Outside)
}

///|
/// An overlay as its look reads it: each a reading, followed where a binding reads it.
pub struct Overlay {
  priv stack : OverlayStack
  priv entry : OverlayEntry
}

///|
/// Where it is in its stack (0 the lowest; -1 once it is let go). Followed: as layers join and leave.
pub fn Overlay::depth(self : Overlay) -> Int {
  self.stack.changed.get() |> ignore
  for i, e in self.stack.entries {
    if e.id == self.entry.id {
      return i
    }
  }
  -1
}

///|
/// Whether it is the topmost of its stack that is not inert (itself not inert): what takes the keys and presses over
/// all the others (a look dims what is under it by this). Followed.
pub fn Overlay::is_top(self : Overlay) -> Bool {
  let at = self.depth()
  guard at >= 0 && !(self.entry.inert)() else { return false }
  for j in (at + 1)..<self.stack.entries.length() {
    if !(self.stack.entries[j].inert)() {
      return false
    }
  }
  true
}

///|
/// Closed as `how` would close it, for what a look adds that closes it (its ✕): `on_dismiss` told, while it is not
/// inert. Called from a handler, never as something is drawn.
pub fn Overlay::dismiss(self : Overlay, how : OverlayDismiss) -> Unit {
  if !@signals.untracked(self.entry.inert) {
    (self.entry.dismiss)(how)
  }
}

///|
/// Its node.
pub fn Overlay::node(self : Overlay) -> @view.View {
  self.entry.node
}

///|
/// How many overlays `tree`'s stack holds now (inert ones too): none once each is let go.
pub fn overlays_open(tree : @view.Tree) -> Int {
  for s in overlay_stacks {
    if physical_equal(s.tree, tree) {
      return s.entries.length()
    }
  }
  0
}

///|
/// An overlay in `parent`, joining its tree's stack above all there (the file's head says what the stack decides);
/// `on_dismiss` told what would close it: Escape or back (`dismiss_on_escape`), a press outside it, what is above it and
/// `anchor` (`dismiss_on_outside`). `inert` while it takes nothing (its caller's way out; leaving is inert too).
/// `modal`: what it does not hold takes no input while it is not inert. `auto_focus`: the focus to the first of what it
/// holds that takes it as it opens (its own ground where none does), else left where it is; `return_focus`: given back
/// to `anchor` as it goes, where it is given (else to what had it as it opened, as auto_focus always does). `label`:
/// read out a Dialog so called (none: nothing read out of it, a toast's layer). `look` is run once as it is made, given
/// its node and what it reads of it: all that is drawn of it and where it goes (a layer of its own over all, its scrim
/// beside it). Its node is made at `loc` (`made_for` where a library's part over it was asked for), as the button's is.
/// Its caller makes it while it shows (View::show). The node.
#callsite(autofill(loc))
pub fn overlay(
  parent : @view.View,
  on_dismiss : (OverlayDismiss) -> Unit,
  look : (@view.View, Overlay) -> Unit,
  modal? : Bool = false,
  dismiss_on_escape? : Bool = true,
  dismiss_on_outside? : Bool = true,
  inert? : () -> Bool = fn() { false },
  anchor? : @view.View,
  auto_focus? : Bool = modal,
  return_focus? : Bool = true,
  label? : () -> String,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    let stack = overlay_stack(v.tree)
    let off = fn() { inert() || v.leaving() }
    let live = fn() { !off() }
    let entry = {
      id: v.id(),
      node: v,
      dismiss: fn(how) { if !@signals.untracked(off) { on_dismiss(how) } },
      inert: off,
      escape: dismiss_on_escape,
      outside: dismiss_on_outside,
      anchor,
    }
    stack.entries.push(entry)
    stack.changed.set(stack.changed.untracked() + 1)
    v.owns(fn() { stack.drop(entry.id) }) |> ignore
    look(v, { stack, entry })
    // (the framework's layer focus: to what it holds as it opens, or left where it is; back as it goes)
    if auto_focus {
      v.focus_opens_first().focusable(By(live), keys=0, tab=false) |> ignore
    } else {
      v.focus_returns() |> ignore
    }
    if return_focus && anchor is Some(a) {
      v.opened_by(ByNode(a.id())) |> ignore
    }
    if modal {
      v.modal(By(live)) |> ignore
    }
    // (its own words, said after its look: what it is while it is not inert, nothing of it once it is)
    if label is Some(name) {
      v.says(By(fn() { Some(@view.said(Dialog, label=name())) })) |> ignore
    }
    v
    .hides(By(off))
    .presses(By(live))
    // (a press on the ground its look draws its own, no press outside it, nothing done by it)
    .on_drag(fn(_) {  })
    |> ignore
    if dismiss_on_escape {
      v
      .on_key(fn(k) { k.code == menu_key_escape && k.mods == 0 && stack.escape(Escape) })
      .takes_back(fn() { stack.escape(Back) |> ignore })
      |> ignore
    }
    if dismiss_on_outside {
      window_downs_while(v, live, fn(x, y) {
        stack.press(@signals.untracked(fn() { v.window_downs() }), x, y)
      })
    }
  })
}
