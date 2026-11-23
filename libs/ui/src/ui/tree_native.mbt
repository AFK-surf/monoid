// A native view (a page, a player: native.mbt) as a node of the window's tree (ui's native), in place of an old view's
// Ctx::native. Its hole is drawn where the tree draws the node, each frame it is drawn, its corners as said then: in
// the tree's order, so what the tree draws after it (a sheet, a menu, a page over it) is over it, and where the scene's
// walk has it (moved, scrolled, grown, cut by what clips it). The host is told where it is and what clips it from
// there, after the frame is painted (Ctx::sync_views), as the frame's instances end up: a page's list's rows moved by
// the column's offset (list_put) take it with them (Ctx::follow_holes). Nothing outside the tree reads back where it
// was laid out.
//
// Shown while its hole is drawn; hidden, not closed, while it is not: its block of a page's list gone out of what
// shows or put by (View::park), its page under another that covers it whole, in its bones, none of it in its clip. Let
// go with its node (View::owns): closed then, unless the app keeps the view past its node (`kept`: a chat's
// visualizations, kept by the chat as it is left), when it is only hidden. Drawn anew each time it is drawn, as a field
// is: no row it is in kept and drawn again as kept, nor a list drawn whole as one (list_drawn_anew), so that each frame
// that moves it says where it went.

///|
/// A native view of the window's tree's: the view, its corners as they are now (top left, then round it), whether the
/// app keeps it past its node.
priv struct TreeNative {
  view : NativeView
  corners : () -> (Double, Double, Double, Double)
  kept : Bool
}

///|
/// The native views of the window's tree, by the node each is in.
// kept across runs: emptied as a run begins (view_forget); each let go with its node (tree_native_gone)
let tree_natives : Map[@view.NodeId, TreeNative] = Map([])

///|
/// How many times a native view was put in tree_natives or taken out: what view_draws reads besides a node's content
/// (@view.Tree::each_drawn_laid_or_past's `draws_rev`, with tree_fields_rev).
// kept across runs: only counts
let tree_natives_rev : Ref[Int] = Ref(0)

///|
/// Native view `view` in a box of `parent`'s, as big as the box is said to be (its height the app's: a page's said
/// height, a placeholder's till it has drawn), seen within it and what clips it, its content's corners round by
/// `corners` as it is drawn (each frame: a visualization's the placeholder's while it waits, square once shown; none:
/// square). Let go with the node: closed, unless `kept` (the app keeps the view past it, and closes it itself; it is
/// only hidden then). One view in one node: given to another while one holds it, a fault. The box made.
#callsite(autofill(loc))
pub fn native(
  parent : @view.View,
  view : NativeView,
  corners? : () -> (Double, Double, Double, Double) = fn() { (0.0, 0.0, 0.0, 0.0) },
  kept? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    let id = b.id()
    let tree = b.tree
    // (given to another node still shown, a fault; one no longer shown (put by till its change is committed whole as
    // what flies from it is, Tree::departs; leaving; laid out nowhere) hands it over: no longer its, not closed, so
    // that its letting go later closes nothing of this one's)
    // (said in the window its tree is drawn in, whichever window is in place as it is made: in_tree_window)
    in_tree_window(tree, fn() {
      let root = tree.root().id()
      let gone : Array[@view.NodeId] = []
      let mut live_dup = false
      for o, e in tree_natives {
        if o != id && physical_equal(e.view, view) {
          if tree.holds(root, o) && !tree.leaving(o) && !tree.laid_out_nowhere(o) {
            live_dup = true
          } else {
            gone.push(o)
          }
        }
      }
      for o in gone {
        tree_natives.remove(o)
        tree_natives_rev.val = tree_natives_rev.val + 1
      }
      if live_dup {
        b.fault("native: one native view given to two nodes of the tree's: a view is shown in one place")
      }
      tree_natives_rev.val = tree_natives_rev.val + 1
      tree_natives[id] = { view, corners, kept }
    })
    b.owns(fn() { in_tree_window(tree, fn() { tree_native_gone(id) }) }) |> ignore
  })
}

///|
/// Native node `id` let go: its view closed, or, kept by the app, only no longer drawn there (hidden as the next frame
/// is painted without it).
fn tree_native_gone(id : @view.NodeId) -> Unit {
  guard tree_natives.get(id) is Some(tn) else { return }
  tree_natives.remove(id)
  tree_natives_rev.val = tree_natives_rev.val + 1
  if !tn.kept {
    tn.view.close()
  }
}

///|
/// How many of the frame's targets are the old views' the walk of the window's tree has come to so far as it is
/// painted (each old view's found before it: Ctx::view_targets, next_old_hits): what of theirs is under a native view
/// of the tree's drawn now, the rest over it.
// kept across runs: set as each paint of the tree begins (Ctx::view_paint)
let tree_hits_passed : Ref[Int] = Ref(0)

///|
/// Native node `id` drawn this frame at (`x`, `y`), `w` × `h` where it is drawn: its hole there (NativeView::paint_in),
/// its corners (`ground_corners`, else its own) as `s` makes them, what is over it found from it (its covers: Tree::finger_areas, Tree::taken_over).
fn Ctx::paint_tree_native(
  self : Ctx,
  id : @view.NodeId,
  tn : TreeNative,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  s : Double,
  ground_corners? : (Double, Double, Double, Double)? = None,
) -> Unit {
  // (a shot shows no native view: it is the window's, where the page has it)
  if shooting.val {
    return
  }
  // (as round as its ground is drawn, where that says (View::ground_drawn); else its own)
  let (r0, r1, r2, r3) = match ground_corners {
    Some(gc) => gc
    None => (tn.corners)()
  }
  let radii = FixedArray::from_array([dmax(r0, 0.0) * s, dmax(r1, 0.0) * s, dmax(r2, 0.0) * s, dmax(r3, 0.0) * s])
  // (what is over it is what of the tree's is drawn after it and takes a finger (Tree::taken_over), and the old views'
  // targets after those of the old views the walk came to before it, found before the walk: tree_hits_passed)
  if tn.view.paint_in(self, x, y, w, h, None, radii) {
    tn.view.island = Some(id)
    tn.view.hits_before = tree_hits_passed.val
  }
}
