// A key catcher as a node of the window's tree (device.mbt's head says what one is): the same catcher an old view's is
// (Ctx::key_catcher), held by a node in place of an old view's. What it is known by in the window is the id the node is
// read out by (tree_said_id), as a field of the tree's is (tree_field.mbt): the focus on it, the keys and words typed
// while it has it (key_in's catcher_key, on_text_now's catcher_text), the host told to take the keyboard for it
// (Ctx::sync_ime) go there as to an old view's. What is typed is told as it comes, at the input's moment (`keys`), never
// read as a frame builds.

///|
/// A key catcher in `parent`, read out as `label` (what a screen reader says it is), told each key and word typed into
/// it while it has the keyboard's focus (`keys`, at the input's moment); a press on it gives it the focus. `on`: whether
/// it takes the focus at all (not on, the focus on it let go of). What it shows is made in it by `make`.
#callsite(autofill(loc))
pub fn key_catcher_node(
  parent : @view.View,
  label : String,
  keys : (KeyIn) -> Unit,
  make : (@view.View) -> Unit,
  on? : @view.Live[Bool] = Is(true),
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(k) {
    let id = k.id()
    let said = tree_said_id(id)
    let st = g().catcher_of(said)
    st.node = Some(id)
    st.told = Some(keys)
    k
    .focusable(on, keys=0)
    .says(Is(Some(@view.said(TextField, label~))))
    .on_press(fn() { key_catcher_focus(id) })
    .owns(fn() {
      match g().dev.catchers.get(said) {
        Some(c) if physical_equal(c, st) => g().dev.catchers.remove(said)
        _ => ()
      }
    })
    |> ignore
    make(k)
  })
}

///|
/// Key catcher `v` (key_catcher_node) given the keyboard's focus where it can take it now (`on`: the soft keyboard
/// raised, the keyboard the app's), or, where it has it, let go of it (`on` false: the soft keyboard put away).
pub fn key_catcher_focus_set(v : @view.View, on : Bool) -> Unit {
  if on {
    key_catcher_focus(v.id())
  } else {
    let c = g()
    if tree_said_ids.get(c.focus) == Some(v.id()) {
      c.focus_moved(0)
    }
  }
}

///|
/// Whether key catcher `v` (key_catcher_node) has the keyboard's focus: what reads it told as the focus comes or goes.
pub fn key_catcher_focused(v : @view.View) -> Bool {
  v.focused()
}

///|
fn key_catcher_focus(id : @view.NodeId) -> Unit {
  guard view_app.val is Some(tree) && tree.can_focus(id) else { return }
  // (in the event that gives it: its frame the event's, the host told at its end to take the keyboard, Ctx::sync_ime)
  g().focus_moved(tree_said_id(id))
}
