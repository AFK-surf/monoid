// Aspect-preserving hero rectangle flight with outer clip box, rounded-corner interpolation, and cover/letterbox
// content geometry. Pure closed-form geometry usable by any full-stage media or card transition.

///|
/// Source thumbnail geometry for a hero flight:
/// - `(x, y, w, h)`: source box in stage coordinates
/// - `seen`: optional visible clip rectangle of the source (e.g. clipped by a scroll viewport)
/// - `corners`: `(tl, tr, br, bl)` corner radii at `p = 0`
/// - `letterbox`: when `true`, content fits inside the source box; when `false`, content covers it
/// - `start_crop`: when `true`, anchors content at `(x, y)` instead of centering inside the source box
#derive(Eq, Debug)
pub(all) struct HeroThumb {
  x : Double
  y : Double
  w : Double
  h : Double
  seen : (Double, Double, Double, Double)?
  corners : (Double, Double, Double, Double)
  letterbox : Bool
  start_crop : Bool
}

///|
/// Interpolated hero flight rectangles at progress `p` (`0..1`):
/// - `cut`: outer clip rect on stage (from source `seen` to `(0, 0, stage_w, stage_h)`)
/// - `box`: rounded clip box (from source box to visible portion of `to` on stage)
/// - `corners`: interpolated `(tl, tr, br, bl)` radii shrinking to `(0, 0, 0, 0)` at `p = 1`
/// - `picture`: aspect-preserving inner content rect (from fitted/covered source rect to `to`)
#derive(Eq, Debug)
pub(all) struct HeroFlightBox {
  cut : (Double, Double, Double, Double)
  box : (Double, Double, Double, Double)
  corners : (Double, Double, Double, Double)
  picture : (Double, Double, Double, Double)
}

///|
/// Visible intersection of `rect` `(x, y, w, h)` with stage `(0, 0, stage_w, stage_h)`, or `rect` itself when disjoint.
pub fn hero_seen_of(
  rect : (Double, Double, Double, Double),
  stage_w : Double,
  stage_h : Double,
) -> (Double, Double, Double, Double) {
  let (x0, y0) = (dmax(rect.0, 0.0), dmax(rect.1, 0.0))
  let (x1, y1) = (dmin(rect.0 + rect.2, stage_w), dmin(rect.1 + rect.3, stage_h))
  if x1 > x0 && y1 > y0 {
    (x0, y0, x1 - x0, y1 - y0)
  } else {
    rect
  }
}

///|
/// Compute the interpolated `HeroFlightBox` from `from` (shifted vertically by `dy`, e.g. lifted clear of an overlapping
/// bar while preserving clipped edges) to destination `to` on a stage of size `stage_w` x `stage_h` at progress `p`.
/// Returns `None` when `to` has non-positive width or height.
pub fn hero_flight_box(
  from : HeroThumb,
  dy : Double,
  to : (Double, Double, Double, Double),
  p : Double,
  stage_w : Double,
  stage_h : Double,
) -> HeroFlightBox? {
  let (sx, sy, sw, sh) = from.seen.unwrap_or((from.x, from.y, from.w, from.h))
  // A side clipped by its container stays anchored on stage; an unclipped side moves with `dy`.
  let (sx, sy, sw, sh) = if dy == 0.0 {
    (sx, sy, sw, sh)
  } else {
    let cut = 0.5
    let y0 = if sy > from.y + cut { sy } else { from.y + dy }
    let y1 = if sy + sh < from.y + from.h - cut { sy + sh } else { from.y + dy + from.h }
    (sx, y0, sw, y1 - y0)
  }
  let fx = from.x
  let fy = from.y + dy
  let fw = from.w
  let fh = from.h
  let (tx, ty, tw, th) = to
  if tw <= 0.0 || th <= 0.0 {
    return None
  }
  let k = if from.letterbox { dmin(fw / tw, fh / th) } else { dmax(fw / tw, fh / th) }
  let (pw0, ph0) = (tw * k, th * k)
  let (px0, py0) = if from.start_crop {
    (fx, fy)
  } else {
    (fx + (fw - pw0) / 2.0, fy + (fh - ph0) / 2.0)
  }
  let along = fn(a : Double, b : Double) { a + (b - a) * p }
  let (bx, by, bw, bh) = hero_seen_of(to, stage_w, stage_h)
  let (cx, cy) = (along(sx, 0.0), along(sy, 0.0))
  let (tl, tr, br, bl) = from.corners
  let cr = 1.0 - p
  Some({
    cut: (cx, cy, along(sx + sw, stage_w) - cx, along(sy + sh, stage_h) - cy),
    box: (along(fx, bx), along(fy, by), along(fw, bw), along(fh, bh)),
    corners: (tl * cr, tr * cr, br * cr, bl * cr),
    picture: (along(px0, tx), along(py0, ty), along(pw0, tw), along(ph0, th)),
  })
}
