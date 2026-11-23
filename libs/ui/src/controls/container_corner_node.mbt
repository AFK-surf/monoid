// The container's corner lent down what it holds (mbui's view/container_corner.mbt) on the ladder's terms: a card says
// how round it is and how far in what it holds starts (corner_card_node), and what lies in it is round by it less how
// far in it stands (concentric_radius_node) where the theme's ranges let it be so (CornerFit: @paint.CornerOf's
// Follow), else as round as it is alone; a capsule stands as far in as makes it concentric with it
// (concentric_capsule_pad). Worked out from the card's corner as it is now, never a constant of where it stands.

///|
/// `v` a card `radius` round (the ladder's step it is), what it holds starting `inset` in from its edges (its padding):
/// lent to what it holds, made now or later (View::corner_scope), what follows it following it as it changes.
pub fn corner_card_node(v : @view.View, radius : () -> Double, inset? : () -> Double = fn() { 0.0 }) -> Unit {
  v.corner_scope(radius, inset~) |> ignore
}

///|
/// `v` round as the card lent to it (corner_card_node) less how far in it stands (`extra_inset` more than that card's
/// padding: its own margin), as the corner rule makes it (@paint.CornerOf's Follow: concentric where the theme's
/// CornerFit lets a corner be so round and stand so far in); `alone` where it does not, or none is lent.
#callsite(autofill(loc))
pub fn concentric_radius_node(
  v : @view.View,
  alone : () -> Double,
  extra_inset? : () -> Double = fn() { 0.0 },
  loc~ : SourceLoc,
) -> Unit {
  let at = v.container_corner()
  v.radius(loc~, By(fn() { concentric_fit(at, alone, extra_inset()) })) |> ignore
}

///|
/// The corner of what stands `extra` more in than card `c` lends (its padding), concentric with it where the window's
/// tree's ranges let it (tree_corner_roots_now's fit), `alone` else, or where none is lent.
fn concentric_fit(c : @view.ContainerCorner?, alone : () -> Double, extra : Double) -> Double {
  match c {
    Some(c) => {
      let inset = (c.inset)() + extra
      @paint.CornerOf::Follow(Own((c.radius)()), inset, alone()).radius(@ui.tree_corner_roots_now())
    }
    None => alone()
  }
}

///|
/// How far in from `v`'s edges a capsule or a circle `capsule_h` high stands to be concentric with the card lent to it
/// (@ui.capsule_in of the card's corner, less how far in `v` stands already: out past its padding where that is less),
/// as it is now; `base` where none is lent or the card is square.
pub fn concentric_capsule_pad(v : @view.View, capsule_h : Double, base : Double) -> Double {
  match v.container_corner() {
    Some(c) =>
      @signals.untracked(fn() {
        let r = (c.radius)()
        if r > 0.0 {
          @ui.capsule_in(r, capsule_h) - (c.inset)()
        } else {
          base
        }
      })
    None => base
  }
}
