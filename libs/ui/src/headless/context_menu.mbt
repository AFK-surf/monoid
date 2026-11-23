// The context menu's trigger: a part of the window (a row, a picture, a canvas) whose menu opens where it was asked for.
// It is asked for, at a point of it, by the pointer's secondary button (a right click) and by a finger held still on it
// as long as a long press: both the framework's own (View::on_menu, Tree::menu_at; ui's tree_finger_menu: its long
// press's time, the slop within which it stays still, a finger that scrolls or moves first asking none, the press it
// calls off and the haptic), used here and never counted again. `on_open` is told where (`@view.Menu`: in the area's
// terms, in the window's, and the moment), and its caller opens its menu there (a `menu` beside the point, menu.mbt).
// Disabled, it opens nothing (a finger's long press on it is taken all the same, felt and its press called off: the
// framework has no word yet for a node that asks for no menu now).
//
// The keyboard: no key asks for it yet. The hosts send no Shift+F10 nor the ContextMenu key (view's key codes, ui's
// desktop.mbt), so a caller gives the keys another way to the same menu (a button in the row, an action of its keymap)
// until they do.

///|
/// `parent` (or a node made in it) made what asks for a context menu: `on_open` told where it was asked for (a right
/// click's point, a long press's) while it is not `disabled`. `look` is given its node once as it is made: all that is
/// drawn of it and how it is laid out, and what it holds. Its node: `parent` itself where `in_node` (a row a structure
/// made, the area its look already is).
#callsite(autofill(loc))
pub fn context_menu(
  parent : @view.View,
  on_open : (@view.Menu) -> Unit,
  look : (@view.View) -> Unit,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    look(v)
    v.on_menu(fn(m) { if !disabled() { on_open(m) } }) |> ignore
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}
