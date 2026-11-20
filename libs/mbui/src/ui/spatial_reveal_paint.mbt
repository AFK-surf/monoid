// What a node holds revealed in the paint (@view.View::spatial_reveal), worked on what the paint puts out for it
// (Ctx::view_paint): each instance drawn in it, its own and what it holds, faded in as it rises into place at its turn
// in the order what shows of it is read in (emit.mbt's glyph_out, the app's, read off the words' glyphs; here off every
// instance alike, where it is drawn). What its words are made into is drawn as kept (no glyph read by a look of its
// own: view_blocks' plain glyphs), only the copies the frame draws moved and faded. What is out of what shows is there
// at once and asks for nothing; once its way is over, nothing of it is looked at.

///|
/// A node revealing what it holds as the tree is painted (Ctx::view_paint's `revealing`): which, how (its reveal as
/// said), where its first instance is among the frame's (each numbered from it, for what varies glyph by glyph), the
/// stretch down the window what shows of it is read across (`top`, `foot`), where its lines start and how wide they
/// are (`x0`, `w`), how big it is drawn.
priv struct RevealAt {
  id : @view.NodeId
  r : @view.SpatialReveal
  k0 : Int
  top : Double
  foot : Double
  x0 : Double
  w : Double
  s : Double
}

///|
/// Node `c` (drawn at (`x`, `y`) as big as `s`, its instances from `k0`) beginning to reveal what it holds by `r`, at
/// this paint: none where nothing of it shows (cut by what holds it, or out of the window), so nothing is asked of it
/// there and all of it is drawn as it rests. Else the frame drawn again till its way is over, what it is drawn in not
/// kept and moved whole meanwhile (a row of a page's list, its list drawn as one), and what shows of it drawn anew.
fn Ctx::reveal_begin(
  self : Ctx,
  c : @view.Content,
  r : @view.SpatialReveal,
  x : Double,
  y : Double,
  s : Double,
  k0 : Int,
) -> RevealAt? {
  let k = clip_top()
  let (top, foot) = match r.span {
    Some(f) =>
      match f() {
        Some(sp) => sp
        None => (y, y + c.h * s)
      }
    None => (y, y + c.h * s)
  }
  let top = dmax(top, clip_stack[k + 1])
  let foot = dmin(foot, clip_stack[k + 3])
  guard foot > top else { return None }
  ride_spoil()
  match list_riding.val {
    Some(l) => l.spoiled = true
    None => ()
  }
  if !shooting.val {
    damage_known.push((dmax(x, clip_stack[k]), top, dmin(x + c.w * s, clip_stack[k + 2]), foot))
  }
  self.now_before(r.end_at) |> ignore
  Some({ id: c.id, r, k0, top, foot, x0: x, w: c.w * s, s })
}

///|
/// The frame's instances `from` … `till` (what one node in what `at` reveals drew of its own) as `at` reveals them now:
/// each out of what shows of it as it rests; each in it at its turn (its line down what shows, and along it), a glyph a
/// little before or after it and rising a little more or less (by its number from `at`'s first and the reveal's salt),
/// what is not one at its top's turn: before it, not drawn (its edge neither); on its way, faded in as it rises into
/// place, what it turns about and fades towards going with it; after it, as it rests. Shapes' pieces and kept groups'
/// headers left as they are (none is in a reveal: what reveals is drawn whole each frame).
fn Ctx::reveal_insts(self : Ctx, at : RevealAt, from : Int, till : Int) -> Unit {
  let r = at.r
  let a = self.inst
  let ms = self.clock - r.start_at
  let s = at.s
  let line = r.line_points * s
  let lines = dmax((at.foot - at.top) / line, 1.0)
  let line_ms = dmin(r.line_ms, r.screen_most_ms / lines)
  for k in from..<till {
    let b = k * inst_size
    let kind = a[b + 5]
    if kind == 12.0 || kind == 13.0 {
      continue
    }
    let iy = a[b + 1]
    // (out of what shows: there as it rests)
    if iy + a[b + 3] <= at.top || iy >= at.foot {
      continue
    }
    let read = dmax(iy - at.top, 0.0) / line +
      (if at.w > 0.0 { dclamp((a[b] - at.x0) / at.w, 0.0, 1.0) } else { 0.0 })
    let glyph = kind == 1.0 || kind == 3.0 || kind == 7.0
    let i = k - at.k0
    let (j0, j1) = if glyph {
      (@view.reveal_noise(i, r.salt), @view.reveal_noise(i, r.salt + 7919))
    } else {
      (0.5, 0.5)
    }
    let start = dmax(read * line_ms + (j0 - 0.5) * r.jitter_ms, 0.0)
    let p = (ms - start) / r.glyph_ms
    if p >= 1.0 {
      continue
    }
    if p <= 0.0 {
      a[b + 11] = 0.0
      if kind == 0.0 && a[b + 6] > 0.0 {
        a[b + 15] = 0.0
      }
      continue
    }
    let k_in = Ease::Out.at(dmin(p / 0.7, 1.0))
    a[b + 11] = a[b + 11] * k_in
    if kind == 0.0 && a[b + 6] > 0.0 {
      a[b + 15] = a[b + 15] * k_in
    }
    let dy = r.rise_px * s * (0.7 + 0.6 * j1) * (1.0 - Ease::Out.at(p))
    a[b + 1] = iy + dy
    if a[b + 32] != 0.0 {
      a[b + 34] = a[b + 34] + dy
    }
    if a[b + 53] > 0.0 {
      a[b + 52] = a[b + 52] + dy
    }
    if a[b + 55] > 0.0 {
      a[b + 54] = a[b + 54] + dy
    }
  }
}
