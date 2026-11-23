// A container's corner lent down what it holds (SwiftUI's ContainerRelativeShape, as a Lent): a rounded box says how
// round it is and how far in from its edges what it holds starts (View::corner_scope), each box between that adds
// padding says how much more (View::corner_inset), and what lies inside asks its corner of them (View::
// concentric_radius: the container's less all those insets, concentric with it) or how far its end stands to be out of
// the container's corner (View::concentric_end_pad), never a constant worked out by hand for where it stands. The
// container's corner changing (a window maximized, 16 to 0), all that asked follows: each a signal read through it.
// Where none lends one, or the corner worked out would be none or under the least asked, what is asked stands as it
// would alone (its `fallback`).

///|
/// The corner of the nearest rounded container (View::corner_scope) and how far in from its edges the box asking stands:
/// each read as it is now, followed (a signal's read through it).
pub struct ContainerCorner {
  /// how round the container is now (0: square)
  radius : () -> Double
  /// how far in from the container's edges the box it is lent to stands now, all the insets between added up
  inset : () -> Double
}

///|
// kept across runs: a kind of value nodes lend, each lender's let go with it (View::lends)
let container_corner_lent : Lent[ContainerCorner] = Lent::new()

///|
/// The container's corner lent to it (View::corner_scope, through each View::corner_inset since): its own, else the
/// nearest of what holds it; None where none lends one.
pub fn View::container_corner(self : View) -> ContainerCorner? {
  self.lent(container_corner_lent)
}

///|
/// It a rounded container `radius` round, what it holds starting `inset` in from its edges (its own padding): lent to
/// what it holds, made now or later, each read as it is now.
pub fn View::corner_scope(self : View, radius : () -> Double, inset? : () -> Double = fn() { 0.0 }) -> View {
  self.lends(container_corner_lent, { radius, inset })
}

///|
/// What it holds `by` further in from the container it is in (its padding, a margin it adds): the container's corner
/// lent to it with that added, lent on to what it holds. Nothing where none is lent to it.
pub fn View::corner_inset(self : View, by : () -> Double) -> View {
  match self.container_corner() {
    Some(c) => self.lends(container_corner_lent, { radius: c.radius, inset: fn() { (c.inset)() + by() } })
    None => self
  }
}

///|
/// Its corner concentric with the container lent to it, `extra_inset` further in than what it is lent says (its own
/// margin): the container's less all those insets, as it changes. `fallback` where none is lent, the container is
/// square, or what is worked out is none or under `min_radius`.
pub fn View::concentric_radius(
  self : View,
  fallback : () -> Double,
  extra_inset? : () -> Double = fn() { 0.0 },
  min_radius? : Double = 0.0,
) -> Live[Double] {
  let at = self.container_corner()
  By(fn() { concentric_or(at, fallback, extra_inset(), min_radius) })
}

///|
/// The container's corner `c` less `extra` more than its inset, where that is a corner (over 0, `least` at least);
/// `fallback`'s else.
fn concentric_or(c : ContainerCorner?, fallback : () -> Double, extra : Double, least : Double) -> Double {
  match c {
    Some(c) => {
      let r = (c.radius)()
      let k = @paint.concentric(r, (c.inset)() + extra)
      if r > 0.0 && k > 0.0 && k >= least {
        k
      } else {
        fallback()
      }
    }
    None => fallback()
  }
}

///|
/// How far in from its end a control at its end (a switch, a capsule, an icon's button on its first or last row) stands
/// at least to be out of the container's corner: `base`, or more where the container's corner reaches further in than
/// it stands (its radius less its inset), as it changes; `base` where none is lent.
pub fn View::concentric_end_pad(self : View, base : Double) -> Live[Double] {
  let at = self.container_corner()
  By(fn() {
    match at {
      Some(c) => dmax(base, (c.radius)() - (c.inset)())
      None => base
    }
  })
}
