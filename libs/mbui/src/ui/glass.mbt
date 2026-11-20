// Glass: a box whose ground is what was drawn under it, blurred (frosted) or
// bent at its rim (liquid). The scene says where the glass is; the renderers
// copy what is drawn below it when they reach it, blur it, and draw on.
//
// A glass instance (scene.mbt's 28 numbers):
//   0-3 rect · 4 radius · 5 kind (5 frosted, 6 liquid) · 6 saturation
//   7 blur (the Gaussian's deviation, logical px: CSS blur()'s); said below 0
//     for glass `contained`: its capture only its own box, its edges carried
//     on past them
//   8-11 tint rgba (over the frost) · 16-19, 24-27 clip (rect, corners)
//   frosted: 12-14 the rim's hairline, its lit top-left, its back (white's
//  alpha, Bar.kt rim) · 15 opacity · 21-23 a notch in its top
//            edge (its box's notch_*: the circle's middle below the top,
//            its radius, its fillets'; scene.mbt)
//   liquid:  12 the rim's light · 13 the bezel's width · 14 where the pointer
//            lights it (Glass::spot, from its rect's top left: glass_spot's
//            packing; 0 none; below 0 a Backdrop lens, backdrop_mode's)
//            15 opacity · 21 how far the bezel bends what is under it
//            (px) · 22 the colours' split (0-1) · 23 the smooth-min radius
//            two shapes of one group merge within
//   a Backdrop lens (Glass::backdrop_lens, liquid with 14 below 0): 6 its
//            saturation, or below 0 its saturation and contrast packed
//            (backdrop_saturation) · 14 minus its mode (backdrop_mode: the
//            highlight's style, depth, hue, the shadow's offset, the
//            highlight's angle and falloff, brightness) · 23 its
//            InnerShadow's radius, or below 0 its spot packed with it
//            (backdrop_rim) · 36-39 its corners, each its own. Each packed
//            one a whole number under 2^23, exact in a float; -1 and -2 a
//            lens of Default and Ambient highlight and nothing else, as before
//   20 the capture it shares: -1, -2, … (negative, so a run of glass is a run
//      of its own for the renderers' image runs): glass one after another
//      with nothing drawn between, the same blur and kind, not over each
//      other, shares one copy of what is under it; up to 8 liquid shapes of
//      one capture are one merged shape. Frosted glass made `shares_capture`
//      takes the last capture whatever is drawn between and wherever it is
//      (over that glass too, at its blur): it frosts what that glass frosts,
//  not the glass (Bar.kt: the ball and the action frost the pages, not
//      the bar). A renderer copies what is under every instance of a
//      capture when it reaches the first.
// Text in liquid glass that is `adaptive` is drawn as kind 7: a glyph whose
// ink the renderer picks from how light what is under its glass is (21-23:
// the glass's centre and half its size, where to look).

///|
/// The glass of a frame being painted: the capture the last glass instance
/// took (its id, the first instance of its run, how many), whether glass
/// is solid this frame, liquid groups being painted, the adaptive glass
/// text is in.
priv struct GlassPaint {
  mut run : Int
  // the last capture of frosted glass (0 none): what glass `shares_capture` takes
  mut frost_run : Int
  // the last capture of a Backdrop lens (0 none): what a lens `shares_capture` takes (same blur)
  mut lens_run : Int
  mut lens_blur : Double
  mut run_start : Int
  mut run_len : Int
  mut solid : Bool
  mut forced : Int
  mut in_group : Int
  // text in adaptive liquid glass: its centre and half its size (0: none)
  mut ink_x : Double
  mut ink_y : Double
  mut ink_r : Double
}

///|
let glass_paint : GlassPaint = {
  run: 0,
  frost_run: 0,
  lens_run: 0,
  lens_blur: 0.0,
  run_start: -1,
  run_len: 0,
  solid: false,
  forced: -1,
  in_group: 0,
  ink_x: 0.0,
  ink_y: 0.0,
  ink_r: 0.0,
}

///|
/// Glass made solid or glass by the app (set_glass_solid: 1 solid, 0 glass, -1 as the system says), followed: what read
/// it (a node's View::glass_solid, the paint) told as it changes, in the frame it changes, not as the next one paints.
/// The window's, as glass_paint's `forced` is (window_kept.mbt).
// kept across runs: put back by each Tester (reset_glass)
let glass_forced_said : Ref[@signals.Signal[Int]] = Ref(@signals.signal(-1, same=fn(a, b) { a == b }))

///|
fn reset_glass() -> Unit {
  glass_paint.run = 0
  glass_paint.frost_run = 0
  glass_paint.lens_run = 0
  glass_paint.lens_blur = 0.0
  glass_paint.run_start = -1
  glass_paint.run_len = 0
  glass_paint.solid = false
  glass_paint.forced = -1
  @signals.untracked(fn() { glass_forced_said.val.set(-1) })
  glass_paint.in_group = 0
  glass_paint.ink_r = 0.0
}

///|
/// Glass as glass, or solid from now on (None: as the system says, which is
/// what MBUI_GLASS=solid or the system's reduce transparency make solid).
pub fn set_glass_solid(solid : Bool?) -> Unit {
  let f = match solid {
    None => -1
    Some(true) => 1
    Some(false) => 0
  }
  glass_paint.forced = f
  glass_forced_said.val.set(f)
}

///|
/// Whether glass is drawn solid in this frame, followed: as the app set it (set_glass_solid), else as the system says.
pub fn Ctx::glass_solid(self : Ctx) -> Bool {
  ignore(self)
  let f = glass_forced_said.val.get()
  if f >= 0 {
    f == 1
  } else {
    glass_solid_said.now()
  }
}

///|
/// At the start of painting a frame: a new set of captures; glass solid or not as the frame has it (Ctx::glass_solid),
/// followed by the paint.
fn Ctx::glass_frame(self : Ctx) -> Unit {
  glass_paint.run = 0
  glass_paint.frost_run = 0
  glass_paint.lens_run = 0
  glass_paint.lens_blur = 0.0
  glass_paint.run_start = -1
  glass_paint.run_len = 0
  glass_paint.in_group = 0
  glass_paint.ink_r = 0.0
  glass_paint.solid = self.glass_solid()
}

///|
fn rects_meet(a : Int, b : Int, inst : FixedArray[Double]) -> Bool {
  let pa = a * inst_size
  let pb = b * inst_size
  inst[pa] < inst[pb] + inst[pb + 2] &&
  inst[pb] < inst[pa] + inst[pa + 2] &&
  inst[pa + 1] < inst[pb + 1] + inst[pb + 3] &&
  inst[pb + 1] < inst[pa + 1] + inst[pa + 3]
}

///|
/// The glass instance of node `n` (its frame), at `alpha`.
fn Ctx::emit_glass(self : Ctx, n : Node, gl : Glass, alpha : Double) -> Unit {
  self.glass_inst(n.x, n.y, n.fw, n.fh, n.radius, gl, alpha)
  // (frosted: its corners each its own; liquid merges shapes of one corner each, the renderers' groups: its roundest;
  // a Backdrop lens, never merged, its corners each its own: Shaders.kt's radiusAt)
  if !gl.liquid || gl.backdrop_highlight > 0 {
    self.corners_last(n)
  }
  self.glass_capture(self.ninst - 1, gl.liquid, gl.shares_capture)
}

///|
/// A glass instance at (x, y), `w` by `h`, corners `radius` round, as `gl` says, at `alpha`: its capture not yet told
/// (Ctx::glass_capture, as it goes into the frame).
fn Ctx::glass_inst(
  self : Ctx,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  radius : Double,
  gl : Glass,
  alpha : Double,
) -> Unit {
  let kind = if gl.liquid { 6.0 } else { 5.0 }
  let lens = gl.backdrop_highlight > 0
  self.push_inst(
    x,
    y,
    w,
    h,
    radius,
    kind,
    if lens { backdrop_saturation(gl) } else { gl.saturation },
    if gl.contained && !gl.liquid { -gl.blur } else { gl.blur },
    gl.tint,
    1.0,
    if gl.liquid { gl.rim } else { gl.rim_edge },
    if gl.liquid { gl.bezel } else { gl.rim_lit },
    if lens { backdrop_mode(gl) } else if gl.liquid { glass_spot(gl.spot) } else { gl.rim_back },
    alpha,
  )
  let b = (self.ninst - 1) * inst_size
  let a = self.inst
  a[b + 21] = gl.refraction
  a[b + 22] = gl.chroma
  a[b + 23] = if lens { backdrop_rim(gl, w, h) } else { gl.merge }
}

///|
/// `v` rounded to a whole number from `lo` to `hi`.
fn whole_in(v : Double, lo : Int, hi : Int) -> Int {
  let r = v.round()
  if r < lo.to_double() {
    lo
  } else if r > hi.to_double() {
    hi
  } else {
    r.to_int()
  }
}

///|
/// A Backdrop lens's 14: minus its mode, the renderers' to take apart (kind 6, c2.z below 0). Bits 0-1 its
/// highlight's style (1 Default, 2 Ambient, 3 Plain); 2 depthEffect; 3 its tint laid on by hue first; 4 its
/// InnerShadow a whole radius lower, not a sixth; 5-11 its highlight's angle (0 45°, else 1 + a 126th of a turn
/// each); 12-15 its falloff (0 one, else halves); 16-22 its brightness (0 none, else 64 + 63rds, -1 to 1). A lens of
/// Default or Ambient highlight and nothing else is -1 or -2, as it ever was.
fn backdrop_mode(gl : Glass) -> Double {
  let bit = fn(b : Bool, at : Int) { if b { 1 << at } else { 0 } }
  let angle = if gl.highlight_angle == 45.0 {
    0
  } else {
    let t = gl.highlight_angle - (gl.highlight_angle / 360.0).floor() * 360.0
    whole_in(t * 126.0 / 360.0, 0, 126) % 126 + 1
  }
  let falloff = if gl.highlight_falloff == 1.0 { 0 } else { whole_in(gl.highlight_falloff * 2.0, 1, 15) }
  let bright = if gl.brightness == 0.0 { 0 } else { whole_in(gl.brightness * 63.0, -63, 63) + 64 }
  let mode = (gl.backdrop_highlight & 3) |
    bit(gl.depth_effect, 2) |
    bit(gl.tint_hue, 3) |
    bit(gl.inner_shadow_full, 4) |
    (angle << 5) |
    (falloff << 12) |
    (bright << 16)
  -mode.to_double()
}

///|
/// A Backdrop lens's 6: its saturation where its contrast is one (as ever), else minus its saturation (thousandths,
/// bits 0-11, to 4.095) and contrast (thousandths, bits 12-22, to 2.047), never 0.
fn backdrop_saturation(gl : Glass) -> Double {
  if gl.contrast == 1.0 {
    return if gl.saturation < 0.0 { 0.0 } else { gl.saturation }
  }
  let s = whole_in(gl.saturation * 1000.0, 0, 4095)
  let c = whole_in(gl.contrast * 1000.0, 0, 2047)
  let pk = s | (c << 12)
  // (none of either: a contrast of a thousandth, so it is still said below 0)
  -(if pk == 0 { 1 << 12 } else { pk }).to_double()
}

///|
/// A Backdrop lens `w` by `h`'s 23: its InnerShadow's radius (as ever), else, where its spot lights it, minus where
/// (127ths of its width, bits 0-6, and of its height, 7-13), how much (63rds, 14-19) and the shadow's radius (fours,
/// 20-22, to 28). What a capture keeps round it takes none of it (grab_of's margin, damage.mbt's glass_margin).
fn backdrop_rim(gl : Glass, w : Double, h : Double) -> Double {
  let lit = whole_in(gl.spot_alpha * 63.0, 0, 63)
  match gl.spot {
    Some((x, y)) if lit > 0 => {
      let across = fn(v : Double, size : Double) { if size > 0.0 { whole_in(v / size * 127.0, 0, 127) } else { 0 } }
      let shadow = whole_in(gl.merge / 4.0, 0, 7)
      -(across(x, w) | (across(y, h) << 7) | (lit << 14) | (shadow << 20)).to_double()
    }
    _ => gl.merge
  }
}

///|
/// Where the pointer lights liquid glass (points from its top left) as one number of an instance: 0 none, else each
/// of x and y at half a point from 256 before its edge (0-4095, so 256 before to 1791.5 past), x * 4096 + y + 1; the
/// renderers take it apart again (kind 6's spot_glow).
fn glass_spot(spot : (Double, Double)?) -> Double {
  match spot {
    None => 0.0
    Some((lx, ly)) => {
      let q = fn(v : Double) {
        let h = ((v + 256.0) * 2.0).round()
        if h < 0.0 {
          0.0
        } else if h > 4095.0 {
          4095.0
        } else {
          h
        }
      }
      q(lx) * 4096.0 + q(ly) + 1.0
    }
  }
}

///|
/// The capture glass instance `k` (just put into the frame, its kind and blur said) takes, as the frame is composed: the
/// last frosted capture's where it `shares` one; else that of the glass just before it, where it may share it; else one
/// of its own. Told of each glass as it goes into the frame, whoever made it (a node of the old view's as it is painted,
/// a node of the window's tree's as its instances are composed: never kept with them).
fn Ctx::glass_capture(self : Ctx, k : Int, liquid : Bool, shares : Bool) -> Unit {
  let b = k * inst_size
  let a = self.inst
  let kind = a[b + 5]
  let blur = a[b + 7]
  let is_lens = liquid && a[b + 14] < 0.0
  if shares && !liquid && glass_paint.frost_run != 0 {
    // the last frosted capture's (liquid glass's is no frost, and only of what is under its shapes), the run as it was
    a[b + 20] = -glass_paint.frost_run.to_double()
    return
  }
  if shares && is_lens && blur >= 0.0 && glass_paint.lens_run != 0 && glass_paint.lens_blur == blur {
    a[b + 20] = -glass_paint.lens_run.to_double()
    return
  }
  // one capture with the glass just before it: right after it, as it is,
  // the same blur, not over it, and (liquid) a group of fewer than 8; glass
  // contained (blur below 0) a capture of its own box alone
  let prev = glass_paint.run_start + glass_paint.run_len
  let prev_is_lens = liquid && k > 0 && a[(k - 1) * inst_size + 14] < 0.0
  let mut same = glass_paint.run != 0 &&
    prev == k &&
    blur >= 0.0 &&
    a[(k - 1) * inst_size + 5] == kind &&
    a[(k - 1) * inst_size + 7] == blur &&
    (!liquid ||
      (is_lens && prev_is_lens) ||
      (!is_lens && !prev_is_lens && glass_paint.run_len < 8))
  if same && (!liquid || is_lens) {
    for j in glass_paint.run_start..<k {
      if rects_meet(j, k, a) {
        same = false
        break
      }
    }
  }
  if same {
    glass_paint.run_len = glass_paint.run_len + 1
  } else {
    glass_paint.run = glass_paint.run + 1
    glass_paint.run_start = k
    glass_paint.run_len = 1
    if !liquid {
      glass_paint.frost_run = glass_paint.run
    } else if is_lens && blur >= 0.0 {
      glass_paint.lens_run = glass_paint.run
      glass_paint.lens_blur = blur
    }
  }
  a[b + 20] = -glass_paint.run.to_double()
}

///|
/// The glass next drawn starts a capture of its own, whatever was drawn just before it.
fn glass_run_break() -> Unit {
  glass_paint.run_start = -1
  glass_paint.run_len = 0
}

///|
/// The liquid glass in `i`'s subtree, one after another (a glass group: so
/// they are one capture and merge), before anything in it is drawn.
fn Ctx::emit_group_glass(self : Ctx, i : Int, alpha_in : Double) -> Unit {
  let mut c = self.nodes[i].first
  while c >= 0 {
    let n = self.nodes[c]
    let alpha = alpha_in * n.opacity
    if alpha > 0.002 {
      match n.glass {
        Some(gl) if gl.liquid => self.emit_glass(n, gl, alpha)
        _ => ()
      }
      self.emit_group_glass(c, alpha)
    }
    c = n.next
  }
}

///|
/// The box's ground: its glass (or the glass's solid ground), and its own
/// colour over that if it has one. The shadow of glass is drawn after it,
/// outside it only, so the glass does not frost or bend its own shadow: a
/// drop of a liquid group's (drawn as its group's one shape) casts none of
/// its own.
fn Ctx::paint_glass(self : Ctx, n : Node, gl : Glass, alpha : Double) -> Unit {
  if glass_paint.solid {
    if n.shadow > 0.0 {
      self.paint_shadow(n, alpha, false)
    }
    self.emit_rect(n.x, n.y, n.fw, n.fh, n.radius, gl.solid, 0.0, 0L, alpha)
    self.notch_last(n)
    self.corners_last(n)
    return
  }
  if !gl.liquid || glass_paint.in_group == 0 {
    self.emit_glass(n, gl, alpha)
    if !gl.liquid {
      self.notch_last(n)
    }
  }
  if n.shadow > 0.0 && (!gl.liquid || glass_paint.in_group == 0) {
    self.paint_shadow(n, alpha, true)
  }
}

///|
/// The box's shadow; `outside`: only where the box is not.
fn Ctx::paint_shadow(self : Ctx, n : Node, alpha : Double, outside : Bool) -> Unit {
  let dy = if n.shadow_y >= 0.0 { n.shadow_y } else { n.shadow * 0.35 }
  self.push_inst(
    n.x,
    n.y + dy,
    n.fw,
    n.fh,
    n.radius,
    2.0,
    0.0,
    n.shadow,
    n.shadow_c,
    alpha,
    if outside { 1.0 } else { 0.0 },
    dy,
    0.0,
    0.0,
  )
  self.corners_last(n)
}
