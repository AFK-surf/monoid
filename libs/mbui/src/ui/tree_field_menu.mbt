// A custom editing bar over a focused text field's selection or caret (symmetrical to tree_picked.mbt's picked_bar /
// picked_now / keeps_picked): when an ancestor opts in with `field_menu_bar`, the app draws its own floating editing
// bar following `field_menu_now()` instead of asking the host for the system floating text menu (`h_text_menu`).

///|
/// A focused text field's floating editing menu state (in window coordinates), followed as a signal by `field_menu_now`.
#derive(Eq, Debug)
pub struct FieldMenuNow {
  /// the focused editor's said id (passed to `field_edit_now`)
  field : Int
  /// the tree node hosting this field, if it is a tree field
  node : @view.NodeId?
  /// selection or caret bounding box in window coordinates
  x : Double
  y : Double
  w : Double
  h : Double
  /// available editing actions (`@hostapi.text_menu_*` bitmask)
  can : Int
  /// whether a non-empty range is currently selected (`a != b`)
  selected : Bool
}

///|
/// Whether what holds node `v` draws its own editing bar over a focused text field (`field_menu_bar`).
// kept across runs: what each node lends (View::lends), let go with it
let field_menu_bars : @view.Lent[Bool] = @view.Lent::new()

///|
/// A press on node `v` or what it holds keeps the focused text field's editing bar open (`keeps_field_menu`).
// kept across runs: what each node lends (View::lends), let go with it
let keeps_field_menus : @view.Lent[Bool] = @view.Lent::new()

///|
/// Where a finger is reading in a tree field (dragging a handle or a long-pressed word) for `finger_reads()` / loupe.
// kept across runs: reset in view_forget and per-window in window_kept.mbt
let tree_finger_read : Ref[@signals.Signal[(Double, Double)?]] = Ref(@signals.signal(None, same=fn(a, b) { a == b }))

///|
/// The focused text field's floating editing bar state as of the latest frame (`field_menu_now`).
// kept across runs: reset in view_forget and per-window in window_kept.mbt
let field_menu_now_said : Ref[@signals.Signal[FieldMenuNow?]] = Ref(@signals.signal(None, same=fn(a, b) { a == b }))

///|
/// Text fields inside node `v`'s subtree use an app-drawn floating editing bar (reading `field_menu_now`) instead of
/// the host's system floating text menu (`h_text_menu`). Returns `v`.
pub fn field_menu_bar(v : @view.View) -> @view.View {
  v.lends(field_menu_bars, true)
}

///|
/// Reads the focused text field's floating editing bar state reactively. Returns `None` when no field editing menu is
/// open or while IME composition is active.
pub fn field_menu_now() -> FieldMenuNow? {
  field_menu_now_said.val.get()
}

///|
/// A press on node `v` or what it holds keeps the focused text field's editing bar from being dismissed on pointer down.
/// Returns `v`.
pub fn keeps_field_menu(v : @view.View) -> @view.View {
  v.lends(keeps_field_menus, true)
}

///|
/// Dismisses the currently focused text field's floating editing bar.
pub fn field_menu_dismiss() -> Unit {
  let c = g()
  match c.editors.get(c.focus) {
    Some(st) if st.menu => {
      st.menu = false
      tree_field_redraw()
    }
    _ => ()
  }
}

///|
/// Whether editor `st` lies within a subtree (or tree root) that opted into an app-drawn editing bar (`field_menu_bar`).
fn field_menu_bar_own(st : EditorState) -> Bool {
  guard view_app.val is Some(tree) else { return false }
  match st.tree_node {
    Some(nid) =>
      match tree.view_of(nid) {
        Some(v) => v.lent(field_menu_bars) == Some(true)
        None => tree.root().lent(field_menu_bars) == Some(true)
      }
    None => tree.root().lent(field_menu_bars) == Some(true)
  }
}

///|
/// Whether a press at (`x`, `y`) lands on a node marked with `keeps_field_menu`.
fn tree_keeps_field_menu_at(tree : @view.Tree, x : Double, y : Double) -> Bool {
  let id = match tree.target_at(x, y) {
    Pressed(id) | Dragged(id) => id
    _ => return false
  }
  match tree.view_of(id) {
    Some(v) => v.lent(keeps_field_menus) == Some(true)
    None => false
  }
}

///|
/// Computes the current focused field's floating editing menu state and whether its subtree opted into an app-drawn
/// bar (`field_menu_bar`).
fn Ctx::field_menu_compute(self : Ctx) -> (FieldMenuNow?, Bool) {
  match self.editors.get(self.focus) {
    Some(st) if st.menu && st.marked.length() == 0 =>
      match st.tl {
        Some(tl) => {
          let (a, b) = st.sel()
          let (x0, l0) = st.place_of(tl, a)
          let (x1, l1) = st.place_of(tl, b)
          let top = st.oy + l0.to_double() * tl.line_h
          let bottom = st.oy + (l1 + 1).to_double() * tl.line_h
          let (x, w) = if l0 == l1 {
            (st.ox + dmin(x0, x1), dmax((x1 - x0).abs(), caret_w))
          } else {
            (st.ox, tl.w)
          }
          let (x, top, w, h) = st.drawn_box(x, top, w, bottom - top)
          let can = st.can()
          (
            Some({ field: self.focus, node: st.tree_node, x, y: top, w, h, can, selected: a != b }),
            field_menu_bar_own(st),
          )
        }
        None => (None, false)
      }
    _ => (None, false)
  }
}

///|
/// Publishes the focused field's floating editing menu state to `field_menu_now()` at frame start (before layout/paint,
/// so the bar renders on the same frame with zero lag and never mutates signals at frame end).
fn Ctx::sync_field_menu_now(self : Ctx) -> Unit {
  let (field_want, _) = self.field_menu_compute()
  field_menu_now_said.val.set(field_want)
}

///|
/// Dismisses the focused field's editing menu when a primary press lands outside both `keeps_field_menu` nodes and the
/// focused field itself.
fn tree_field_menu_dismiss_if_outside(tree : @view.Tree, x : Double, y : Double) -> Unit {
  let c = g()
  guard c.editors.get(c.focus) is Some(st) && st.menu else { return }
  if tree_keeps_field_menu_at(tree, x, y) {
    return
  }
  match (tree.target_at(x, y), st.tree_node) {
    (Pressed(id), Some(fid)) if id == fid => return
    _ => ()
  }
  st.menu = false
  tree_field_redraw()
}
