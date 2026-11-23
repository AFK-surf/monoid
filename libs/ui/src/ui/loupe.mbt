// What a finger hides, for a loupe to show (iOS's text loupe, Android's Magnifier; an app's library draws it over a
// node of the window's tree that magnifies, View::magnifies): where a finger reads as it drags what needs seeing where it
// is (a field's caret or the ends of what is picked in it by their handles, a long press's word slid on: app.mbt's
// handle_drag, word_drag), and what the frame drew round a point painted larger in that node (Ctx::view_magnified).

///|
/// Where a finger reads now, if it drags what needs seeing there: a field's handle (the caret hanging loupe_reach over
/// the finger, its handle under it), or a long press's word slid on (under the finger itself). None else. Read as the
/// hand changes (hand.mbt): what a node of the window's tree binds a loupe by.
pub fn finger_reads() -> (Double, Double)? {
  match tree_finger_read.val.get() {
    Some(p) => return Some(p)
    None => ()
  }
  let c = g()
  // (read so: hand.mbt; where the finger is, only while it drags what needs seeing)
  hand.down.get() |> ignore
  if !c.down || !(pointing() is Finger) {
    return None
  }
  if c.handle_drag != 0 {
    hand.pointer.get() |> ignore
    Some((c.px, c.py - loupe_reach))
  } else if c.word_drag != 0 {
    hand.pointer.get() |> ignore
    Some((c.px, c.py))
  } else {
    None
  }
}

///|
/// How far over a finger dragging a field's handle what it moves is (its caret: editor.mbt's handle, hanging under it).
pub let loupe_reach : Double = 26.0

///|
/// A node of the window's tree magnifying what was drawn before it (View::magnifies: round (`sx`, `sy`) in the window,
/// `z` times as large), its content `c` drawn at (`x`, `y`) as big as `s` and as opaque as `a`, over its own ground (the
/// first instance of it at `own`; where it is drawn off and bigger, `ground`, so too what it shows): the frame's instances before that which lie there copied after the frame's and set
/// larger about there into it, cut to it (what is inked by glass and what punches through left out; glass as the
/// ground of its tint). Drawn only.
fn Ctx::view_magnified(
  self : Ctx,
  c : @view.Content,
  x : Double,
  y : Double,
  s : Double,
  a : Double,
  m : (Double, Double, Double),
  own : Int,
  ground : @view.GroundShape,
) -> Unit {
  let (sx, sy, z) = m
  // (where its ground is drawn, drawn off and bigger as it says: View::ground_drawn)
  let (lw, lh) = (c.w + ground.dw, c.h + ground.dh)
  let (x, y) = (x + ground.dx * s, y + ground.dy * s)
  let (w, h) = (lw * s, lh * s)
  match ground.corners {
    Some((tl, tr, br, bl)) => push_box_clip(x, y, w, h, tl * s, tr * s, br * s, bl * s)
    None => {
      let r = c.radius * s
      push_box_clip(x, y, w, h, r, r, r, r)
    }
  }
  let (cx, cy) = (x + w / 2.0, y + h / 2.0)
  // (what lies round the point as it is laid out, its zoom's; drawn as large as its look's scale has it too)
  let (qx0, qy0) = (sx - lw / 2.0 / z, sy - lh / 2.0 / z)
  let (qx1, qy1) = (sx + lw / 2.0 / z, sy + lh / 2.0 / z)
  let i0 = self.ninst
  for k in 0..<own {
    let b = k * inst_size
    let ia = self.inst
    let kind = ia[b + 5]
    // (what is inked by glass and what punches through: left out)
    if kind == 7.0 || kind == 9.0 {
      continue
    }
    if ia[b] > qx1 || ia[b + 1] > qy1 || ia[b] + ia[b + 2] < qx0 || ia[b + 1] + ia[b + 3] < qy0 {
      continue
    }
    if ia[b + 16] > qx1 || ia[b + 17] > qy1 || ia[b + 18] < qx0 || ia[b + 19] < qy0 {
      continue
    }
    while (self.ninst + 2) * inst_size > self.inst.length() {
      self.grow()
    }
    let ia = self.inst
    let d = self.ninst * inst_size
    ia.blit_to(ia, len=inst_size, src_offset=b, dst_offset=d)
    if kind == 5.0 || kind == 6.0 {
      // glass as the ground of its tint (a rect's alpha where glass has its opacity, 15): what it frosts is under it,
      // copied at its own size
      ia[d + 5] = 0.0
      ia[d + 11] = ia[d + 15]
      for j in [6, 7, 12, 13, 14, 15, 20, 21, 22, 23] {
        ia[d + j] = 0.0
      }
    }
    ia[d + 11] = ia[d + 11] * a
    self.ninst = self.ninst + 1
  }
  // larger about where it reads, in the box, cut to the clip it is painted in (its own)
  let (outer, outer_r, outer_s) = clip_at(clip_top())
  self.transform_insts(i0, self.ninst, sx, sy, z * s, z * s, cx - sx, cy - sy, outer, outer_r, outer_s)
  pop_clip()
}
