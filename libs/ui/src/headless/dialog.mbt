// The dialog: what opens over the window to be dealt with before what is under it (a modal dialog, an alert dialog that
// asks to confirm, a sheet that leaves the page usable: `modal` false). Read out a `Dialog` or an `AlertDialog` called
// by its label (and its words, `description`), while it is open.
//
// Controlled (headless.mbt, State): `open` is its caller's, who makes its node while it shows (View::show, its leave the
// look's way out); what would close it (Escape, the system's back, a press outside it) tells `on_close`, who writes
// `open`. Nothing of open or closed is kept here.
//
// While open: modal (`modal`: what it does not hold takes no press, no key, no focus and is not read out: View::modal),
// a press on it is its own (one on the ground its look draws is no press outside it, nothing done by it), and its own
// node takes the focus as it is given it (no key presses it, Tab passing it by). From the cause that makes `open` false, at once, whatever frames its way
// out takes: none of that (no modal layer, no press, nothing read out), so what is under it is the hand's again as it
// begins to go, never held under the tail of its leaving.
//
// The focus: as it opens, to the first of what it holds that takes it (`first_takes`: the first that says what that
// holds; its own ground where none does: View::focus_opens_first), and as it goes, back to what had it as it opened, or
// to `return_focus` where that is given and can take it then (View::opened_by): the framework's layer focus, done once
// the change that opened or closed it is committed whole.
//
// What closes it: Escape (`close_on_escape`, the focus in it or nowhere) and the system's back (the same), and a press
// that goes down anywhere in the window outside it and what it holds (`close_on_outside`; a modal one's scrim, drawn by
// its look outside it, is such a press), each telling `on_close` once, only while it is open.

///|
/// What a dialog is to a screen reader: a `Dialog`, or an `AlertDialog` (one that asks to confirm or warns).
#derive(Eq, Debug)
pub(all) enum DialogKind {
  Dialog
  AlertDialog
}

///|
/// A dialog as its look reads it: each a reading, followed where a binding reads it.
pub struct Dialog {
  priv node : @view.View
  priv now : () -> Bool
  priv close : () -> Unit
}

///|
/// Whether it is open now (as its caller says): false from the cause that closes it, as it goes.
pub fn Dialog::open(self : Dialog) -> Bool {
  (self.now)()
}

///|
/// Whether it has the keyboard's focus itself (its ground: none of what it holds) and that shows.
pub fn Dialog::focus_shown(self : Dialog) -> Bool {
  self.node.focus_shown()
}

///|
/// Closed, for what a look adds that closes it (its ✕): `on_close` told, while it is open. Called from a handler, never
/// as something is drawn.
pub fn Dialog::close(self : Dialog) -> Unit {
  (self.close)()
}

///|
/// Whether a press that went down at (`x`, `y`) of the window is on `v` or what it holds, as the tree is now (what
/// takes it there: Tree::target_at).
fn press_on(v : @view.View, x : Double, y : Double) -> Bool {
  v.alive() &&
  (match v.tree.target_at(x, y) {
    Pressed(id) | Dragged(id) | Hosted(id) => v.tree.holds(v.id(), id)
    _ => false
  })
}

///|
/// `v` told `f` as a press goes down anywhere in the window while `on` says so (View::window_downs), given where it went
/// down; a press already down as `on` came to hold is none of these.
fn window_downs_while(v : @view.View, on : () -> Bool, f : (Double, Double) -> Unit) -> Unit {
  let was : Ref[Int?] = Ref(None)
  v.reacts(fn() { if on() { Some(v.window_downs()) } else { None } }, fn(now) {
    let before = was.val
    was.val = now
    guard before is Some(_) && now is Some(_) else { return }
    let (x, y) = v.window_down_point()
    f(x, y)
  })
}

///|
/// A dialog of `kind` in `parent`, called `label` (with its words `description`, as they change), open while `open`
/// says so; `on_close` told as Escape or back (`close_on_escape`) or a press outside it (`close_on_outside`) would
/// close it. `modal`: what it does not hold takes no input while it is open. `first_takes`: what of what it holds the
/// focus goes to as it opens (the first that says what this holds; by default the first that takes the focus);
/// `return_focus`: what the focus goes back to as it goes (by default what had it as it opened). `look` is run once as
/// it is made, given its node and what it reads of it: all that is drawn of it and where it goes (a layer of its own,
/// over all; its scrim beside it). Its node is made at `loc` (`made_for` where a library's part over it was asked
/// for), as the button's is. Its caller makes it while it shows (View::show). The node.
#callsite(autofill(loc))
pub fn dialog(
  parent : @view.View,
  label : () -> String,
  open : () -> Bool,
  on_close : () -> Unit,
  look : (@view.View, Dialog) -> Unit,
  kind? : DialogKind = Dialog,
  description? : () -> String = fn() { "" },
  modal? : Bool = true,
  close_on_escape? : Bool = true,
  close_on_outside? : Bool = true,
  first_takes? : (@view.Said) -> Bool,
  return_focus? : @view.View,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    let close = fn() {
      if @signals.untracked(open) {
        on_close()
      }
    }
    let (stack, entry) = overlay_join(v, fn(_) { close() }, fn() { !open() }, close_on_escape, close_on_outside, None)
    look(v, { node: v, now: open, close })
    // (the framework's layer focus: to what it holds as it opens, back as it goes)
    v.focus_opens_first(takes?=first_takes) |> ignore
    if return_focus is Some(r) {
      v.opened_by(ByNode(r.id())) |> ignore
    }
    if modal {
      v.modal(By(open)) |> ignore
    }
    // (its own words, said after its look: what it is while open, nothing of it once it goes)
    v
    .says(By(fn() {
      let role : @view.Role = match kind {
        Dialog => Dialog
        AlertDialog => AlertDialog
      }
      Some(@view.said(role, label=label(), description=description()))
    }))
    .hides(By(fn() { !open() }))
    .presses(By(open))
    .focusable(By(open), keys=0, tab=false)
    // (a press on the ground its look draws its own, no press outside it: the pointer's there taken (Tree::target_at
    // finds what is drawn), and nothing done by it)
    .on_drag(fn(_) {  })
    |> ignore
    overlay_wire_dismiss(v, stack, entry)
  })
}
