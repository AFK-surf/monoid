// Rounded rectangles (paint's Rect): emitted directly as kind 0 instances (scene.mbt's kind 0) with optional per-corner
// radii (36..39), avoiding path banding for axis-aligned bars and highlight spans.

///|
/// `rects` drawn from (`ox`, `oy`) (a node of the window's tree's), each a native kind 0 rounded rectangle.
fn Ctx::emit_rects(self : Ctx, ox : Double, oy : Double, rects : Array[@paint.Rect], alpha : Double) -> Unit {
  for r in rects {
    if r.w <= 0.0 || r.h <= 0.0 || r.color == 0L {
      continue
    }
    let (c0, c1, c2, c3) = r.corners
    let max_r = dmax(dmax(c0, c1), dmax(c2, c3))
    self.push_inst(
      ox + r.x,
      oy + r.y,
      r.w,
      r.h,
      max_r,
      0.0,
      0.0,
      0.0,
      r.color,
      alpha,
      0.0,
      0.0,
      0.0,
      0.0,
    )
    if c0 != max_r || c1 != max_r || c2 != max_r || c3 != max_r {
      self.corners_last_each(c0, c1, c2, c3)
    }
  }
}
