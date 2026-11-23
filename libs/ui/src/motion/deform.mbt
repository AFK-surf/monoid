// A ground bent by how fast it goes: a knob or a thumb flung along its track drawn a little longer along its way and a
// little thinner across it, a capsule as round as it is short, back to as it is laid out as it comes to rest. Worked out
// of the speed its way says at the moment it is drawn (Way::motion_on, in closed form), never of two frames' places,
// and drawn by the node's ground alone (View::ground_drawn: a place's, nothing laid out or made again).

///|
/// How node's ground `w` by `h` is drawn going at (`vx`, `vy`) points a second: along the way it goes the most, longer
/// by a share `s` of its length that grows smoothly with the speed and never reaches `most` (`s = most · u / (1 + u)`,
/// `u` its speed times `gain`: no corner in it as it starts, or as it nears its most), its middle where it was; across
/// it, thinner as its area kept nearly the same has it (`1 / (1 + 0.45 s)`); its corners a capsule's, half its new short
/// side. Still, nothing to bend or none of it: exactly as it is laid out (ground_as_laid), so a ground at rest is
/// drawn as it always was.
pub fn velocity_capsule(
  w : Double,
  h : Double,
  vx : Double,
  vy : Double,
  gain? : Double = 0.00035,
  most? : Double = 0.28,
) -> @view.GroundShape {
  if (vx == 0.0 && vy == 0.0) || w <= 0.0 || h <= 0.0 || most <= 0.0 || gain <= 0.0 {
    return @view.ground_as_laid
  }
  let across = vx.abs() >= vy.abs()
  let u = (if across { vx } else { vy }).abs() * gain
  let s = most * (u / (1.0 + u))
  let thin = 1.0 / (1.0 + s * 0.45) - 1.0
  let (dw, dh) = if across { (w * s, h * thin) } else { (w * thin, h * s) }
  let r = dmin(w + dw, h + dh) / 2.0
  { dx: -dw / 2.0, dy: -dh / 2.0, dw, dh, corners: Some((r, r, r, r)) }
}

///|
/// 2D spring-following pointer/capsule controller: tracks `(x, y)` on two `NodeWay` axes plus a `held` presence way.
/// Snaps silently on first engagement (when `held <= 0.001`) so the capsule never flies in from the origin, and computes
/// velocity-stretched capsule geometry via `speed_stretch`.
pub struct SpringFollow2D {
  priv ax : NodeWay
  priv ay : NodeWay
  priv held : NodeWay
}

///|
/// Create a `SpringFollow2D` at rest (`(0, 0)`, not held).
pub fn SpringFollow2D::new() -> SpringFollow2D {
  { ax: NodeWay::new(0.0), ay: NodeWay::new(0.0), held: NodeWay::new(0.0) }
}

///|
/// Follow target `(x, y)` on `spec` (default `tactile_bounce`) and engage `held -> 1.0`.
/// When appearing from rest (`held.target() == 0.0` and `held.value_at(v.cause_at()) <= 0.001`), snaps `(ax, ay)`
/// immediately to `(x, y)` instead of flying in from the origin or previous position.
pub fn SpringFollow2D::chase(
  self : SpringFollow2D,
  v : @view.View,
  x : Double,
  y : Double,
  spec? : Spec = tactile_bounce,
) -> Unit {
  if self.held.target() == 0.0 && self.held.value_at(v.cause_at()) <= 0.001 {
    self.ax.put(x)
    self.ay.put(y)
  } else {
    self.ax.go(v, x, spec)
    self.ay.go(v, y, spec)
  }
  self.held.go(v, 1.0, spec)
}

///|
/// Release engagement (`held -> 0.0`) on `spec` (default `tactile_bounce`).
pub fn SpringFollow2D::release(
  self : SpringFollow2D,
  v : @view.View,
  spec? : Spec = tactile_bounce,
) -> Unit {
  self.held.go(v, 0.0, spec)
}

///|
/// Whether the controller is engaged or still animating out (`held.target() > 0.0 || held.goes(v)`).
pub fn SpringFollow2D::active(self : SpringFollow2D, v : @view.View) -> Bool {
  self.held.target() > 0.0 || self.held.goes(v)
}

///|
/// Current rendered engagement progress (`0..1`) on node `v`.
pub fn SpringFollow2D::held_shown(self : SpringFollow2D, v : @view.View) -> Double {
  self.held.shown(v)
}

///|
/// Velocity-stretched capsule `GroundShape` for a `w` x `h` capsule laid out at center `(tx, ty)`.
/// Stretches horizontally in the direction of motion and compresses vertically via `speed_stretch`.
pub fn SpringFollow2D::capsule_shape(
  self : SpringFollow2D,
  v : @view.View,
  w : Double,
  h : Double,
  tx : Double,
  ty : Double,
) -> @view.GroundShape {
  let (x, xv) = self.ax.motion(v)
  let y = self.ay.shown(v)
  let vel = if (self.ax.target() - x).abs() < 0.5 { 0.0 } else { xv / 60.0 }
  let (longer, lower) = speed_stretch(vel)
  let mid = x + (if vel < 0.0 { -longer } else { longer }) / 2.0
  let r = (h - lower) / 2.0
  {
    dx: mid - (w + longer) / 2.0 - (tx - w / 2.0),
    dy: y - (h - lower) / 2.0 - (ty - h / 2.0),
    dw: longer,
    dh: -lower,
    corners: Some((r, r, r, r)),
  }
}
