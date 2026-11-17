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
