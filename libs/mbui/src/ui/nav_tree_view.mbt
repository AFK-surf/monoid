// A stack of pages for a window that is the tree alone (run_tree): every page made once as nodes (nav_view's `made`),
// none an old view, the root pages another takes the place of kept at rest, slides layered, on the theme's ground.

///|
/// Stack `nav` as a node of `v`'s for a window that is the tree alone (nav_view's, every page made as nodes, no old
/// view built): each page of kind `kind` made by `make` (as nav_view's `made`: in the node given, given what it is as
/// that changes, the page under it, its time on top and its entry's number), on a ground of `bg` (the theme's
/// background as it changes); back taken within `edge` of its left side; a page pushed sliding in once `ready` says it
/// has what it shows, `most` ms after it was pushed at the latest. `keeps_made`: a root page another takes the place
/// of (Nav::replace_kept, Nav::replace_tab) put by at rest and taken back the same nodes. `keeps_left`: a page over the
/// root that leaves the stack kept at rest by the key it says (with its kind; none: let go as ever), taken back the same
/// nodes as a page of that key and kind is put on (nav_kept_left_most at most). `transition`: layered (parallax, veil,
/// leading edge, both ends of a tab's swap moving).
pub fn[P] nav_tree_view(
  v : @view.View,
  nav : Nav[P],
  kind : (P) -> String,
  make : (@view.View, () -> P, P?, () -> Int, Int) -> Unit,
  bg? : () -> Int64 = fn() { tree_theme().bg },
  edge? : Double = 20.0,
  ready? : (P) -> Bool,
  most? : Double = 0.0,
  keeps_made? : Bool = true,
  keeps_left? : (P) -> String?,
  transition? : NavTransition = NavTransition::layered(),
  tab_moves_slot? : Bool = true,
) -> @view.View {
  nav_view(
    v,
    nav,
    fn(_, _) {  },
    bg~,
    edge~,
    ready?,
    most~,
    made=fn(p) { Some((kind(p), make)) },
    keeps_made~,
    keeps_left?=keeps_left.map(fn(key) { fn(p) { key(p).map(fn(id) { (id, kind(p)) }) } }),
    transition~,
    tab_moves_slot~,
  )
}
