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
//            its radius, its fillets'; scene.mbt); or slot 22 == -1.0 when
//            `progressive` (variable blur modulated by slots 52-59 fade ramp)
//   liquid:  12 the rim's light · 13 the bezel's width · 14 where the pointer
//            lights it (Glass::spot, from its rect's top left: glass_spot's
//            packing; 0 none) · 15 opacity · 21 how far the bezel bends what
//            is under it (px) · 22 the colours' split · 23 the smooth-min
//            radius two shapes of one group merge within
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
  // the last capture of unmerged liquid glass (merge <= 0, 0 none): what `shares_capture` takes (same blur)
  mut liquid_run : Int
  mut liquid_blur : Double
  mut liquid_first : Int
  mut liquid_y0 : Double
  mut liquid_y1 : Double
  mut run_start : Int
  mut run_len : Int
  mut solid : Bool
  mut material : GlassMaterial
  mut contrast : Bool
  mut forced : Int
  mut in_group : Int
  // text in adaptive liquid glass: its centre and half its size (0: none)
  mut ink_x : Double
  mut ink_y : Double
  mut ink_r : Double
  // true when the active adaptive ink scope is bare text (`View::adaptive_ink`, no glass capsule)
  mut ink_bare : Bool
  // true while painting a cached block inside an adaptive glass scope so emit_text records line centerline in slot 7 and emit_bands records icon center in slots 6-7
  mut ink_line : Bool
}

///|
/// Slot 23 of bare adaptive text (kind 7, `View::adaptive_ink`): the whole text's half width and half height in
/// points, packed as `-(hw * 4096 + hh)` (each whole, 1..4095: exact in a float), its centre in slots 21-22. Every
/// glyph of one text samples the same box behind it and takes one ink; sampling round each glyph flipped single
/// letters over a busy backdrop (a key of a keyboard behind one letter of a title).
fn bare_text_ink(hw : Double, hh : Double) -> Double {
  let whole = fn(v : Double) { dmin(dmax(v.floor(), 1.0), 4095.0) }
  -(whole(hw) * 4096.0 + whole(hh))
}

///|
/// How far the capsule under bare adaptive words reaches past them (across, down), in points, and its edge (a
/// shadow's sigma: as sharp as a box's, a capsule, not a haze spreading out).
let bare_veil_pad : (Double, Double) = (12.0, 5.0)

///|
let bare_veil_soft : Double = 0.5

///|
/// Under bare adaptive words (a block of node `id` drawn at x, y, w × h, as opaque as `a`), a capsule (kind 2, its
/// edge sharp: bare_veil_soft) of their own ink, with their box in 21-23 as theirs (bare_text_ink): the hosts give it
/// the blurred backdrop's own colour pulled to the side opposite the words' ink (the frost it is drawn on, thicker
/// there) and an opacity rising as the worst of what is behind them leaves the words less than 4.5:1 (none above it),
/// so over a busy backdrop a capsule fades in and out with it as it moves, and over a quiet one there is none, eased
/// over time where the host keeps their state (bare_text_who). None for a block with no words.
fn Ctx::bare_text_veil(
  self : Ctx,
  id : @view.NodeId,
  block : FixedArray[Double],
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  a : Double,
) -> Unit {
  let n = block.length() / inst_size
  let mut first = -1
  for i in 0..<n {
    if block[i * inst_size + 5] == 1.0 {
      first = i
      break
    }
  }
  guard first >= 0 && w > 0.0 && h > 0.0 else { return }
  let g = first * inst_size
  let byte = fn(v : Double) { (dmin(dmax(v, 0.0), 1.0) * 255.0).round().to_int64() }
  let ink = (byte(block[g + 8]) << 24) | (byte(block[g + 9]) << 16) | (byte(block[g + 10]) << 8) | 0xFFL
  let (px, py) = bare_veil_pad
  let (was, was_tree) = (inst_owners.painting, inst_owners.tree_painting)
  inst_owners.painting = -1
  inst_owners.tree_painting = Some(id)
  let vh = h + 2.0 * py
  self.push_inst(x - px, y - py, w + 2.0 * px, vh, vh / 2.0, 2.0, 0.0, bare_veil_soft, ink, a, 0.0, 0.0, 0.0, 0.0)
  inst_owners.painting = was
  inst_owners.tree_painting = was_tree
  let b = (self.ninst - 1) * inst_size
  self.inst[b + 21] = x + w / 2.0
  self.inst[b + 22] = y + h / 2.0
  self.inst[b + 23] = bare_text_ink(w / 2.0, h / 2.0)
  self.inst[b + 6] = bare_text_who(id)
}

///|
/// Slot 6 of bare adaptive words and their capsule: whose they are (their node's index and 1), the same frame after
/// frame, so the host keeps their state over time (how far their capsule shows, which side of grey they are) and eases
/// it as what is behind them changes rather than jumping; the host puts its slot there in its place (-(slot + 1)).
fn bare_text_who(id : @view.NodeId) -> Double {
  (id.at % 8388607 + 1).to_double()
}

///|
let glass_paint : GlassPaint = {
  run: 0,
  frost_run: 0,
  liquid_run: 0,
  liquid_blur: 0.0,
  liquid_first: -1,
  liquid_y0: 0.0,
  liquid_y1: 0.0,
  run_start: -1,
  run_len: 0,
  solid: false,
  material: Liquid,
  contrast: false,
  forced: -1,
  in_group: 0,
  ink_x: 0.0,
  ink_y: 0.0,
  ink_r: 0.0,
  ink_bare: false,
  ink_line: false,
}

///|
/// Glass made solid or glass by the app (set_glass_solid: 1 solid, 0 glass, -1 as the system says), followed: what read
/// it (a node's View::glass_solid, the paint) told as it changes, in the frame it changes, not as the next one paints.
/// The window's, as glass_paint's `forced` is (window_kept.mbt).
// kept across runs: put back by each Tester (reset_glass)
let glass_forced_said : Ref[@signals.Signal[Int]] = Ref(@signals.signal(-1, same=fn(a, b) { a == b }))

///|
/// Global ambient light axis angle (radians, default `0.0`: top-down light axis) for liquid glass specular glint,
/// inner bevel shadow, and external contour rotation. Per-window kept (`window_kept.mbt`), reset by `reset_glass`.
let glass_light_angle_said : Ref[@signals.Signal[Double]] = Ref(@signals.signal(0.0, same=fn(a, b) { a == b }))

///|
/// What every glass surface of a window is made of, one of three: each surface's own liquid glass (the default),
/// frosted glass (what is under it blurred deep behind a denser tint, its rim lit but bending nothing), or its solid
/// ground. The app says which (set_glass_material); the surfaces' recipes stay their own, the material is applied to
/// them all alike as they are painted (effective_glass), so no part chooses one of its own.
#derive(Eq, Debug)
pub(all) enum GlassMaterial {
  Liquid
  Frosted
  Solid
}

///|
/// The window's glass material (GlassMaterial). Per-window kept (`window_kept.mbt`), reset by `reset_glass`.
let glass_material_said : Ref[@signals.Signal[GlassMaterial]] = Ref(
  @signals.signal(Liquid, same=fn(a, b) { a == b }),
)

///|
fn reset_glass() -> Unit {
  glass_paint.run = 0
  glass_paint.frost_run = 0
  glass_paint.liquid_run = 0
  glass_paint.liquid_blur = 0.0
  glass_paint.liquid_first = -1
  glass_paint.liquid_y0 = 0.0
  glass_paint.liquid_y1 = 0.0
  glass_paint.run_start = -1
  glass_paint.run_len = 0
  glass_paint.solid = false
  glass_paint.material = Liquid
  glass_paint.contrast = false
  glass_paint.forced = -1
  @signals.untracked(fn() { glass_forced_said.val.set(-1) })
  @signals.untracked(fn() { glass_light_angle_said.val.set(0.0) })
  @signals.untracked(fn() { glass_material_said.val.set(Liquid) })
  glass_paint.in_group = 0
  glass_paint.ink_r = 0.0
  glass_paint.ink_bare = false
  glass_paint.ink_line = false
}

///|
/// Make every glass surface of the window liquid (the default), frosted or solid from the next frame on.
pub fn set_glass_material(material : GlassMaterial) -> Unit {
  glass_material_said.val.set(material)
}

///|
/// The window's glass material, followed (set_glass_material).
pub fn glass_material() -> GlassMaterial {
  glass_material_said.val.get()
}

///|
/// Set the global ambient light axis angle (in radians, `0.0` = default top-down) for liquid glass surfaces.
pub fn set_glass_light_angle(radians : Double) -> Unit {
  glass_light_angle_said.val.set(radians)
}

///|
/// Read the current global ambient light axis angle (in radians) for liquid glass surfaces.
pub fn glass_light_angle() -> Double {
  glass_light_angle_said.val.get()
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
/// Whether glass is drawn solid in this frame, followed: as the app set it (set_glass_solid), else solid when the
/// window's material is Solid, else as the system says.
pub fn Ctx::glass_solid(self : Ctx) -> Bool {
  ignore(self)
  let f = glass_forced_said.val.get()
  if f >= 0 {
    f == 1
  } else if glass_material_said.val.get() == Solid {
    true
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
  glass_paint.liquid_run = 0
  glass_paint.liquid_blur = 0.0
  glass_paint.liquid_first = -1
  glass_paint.liquid_y0 = 0.0
  glass_paint.liquid_y1 = 0.0
  glass_paint.run_start = -1
  glass_paint.run_len = 0
  glass_paint.in_group = 0
  glass_paint.ink_r = 0.0
  glass_paint.ink_bare = false
  glass_paint.ink_line = false
  glass_paint.material = glass_material_said.val.get()
  glass_paint.contrast = more_contrast()
  glass_paint.solid = self.glass_solid()
}

///|
/// How far frosted glass takes a liquid surface's tint toward its solid ground (its alpha toward 0.94, its colour half
/// as far).
let frosted_frost : Double = 0.5

///|
/// The least blur frosted glass gives what is under it (CSS blur()'s deviation, logical px).
let frosted_blur : Double = 24.0

///|
/// How wide the hairline round frosted glass made of liquid glass is (frosted_ring), in points: the controls' hairline.
let frosted_ring_w : Double = 0.5

///|
/// The hairline round frosted glass made of liquid glass (material_glass), drawn over its edge as it is painted: a light
/// one round dark glass, a dark one round light glass (its solid ground's lightness says which), as a solid overlay's
/// edge is.
fn frosted_ring(gl : Glass) -> Int64 {
  let r = ((gl.solid >> 24) & 0xFFL).to_int().to_double()
  let g = ((gl.solid >> 16) & 0xFFL).to_int().to_double()
  let b = ((gl.solid >> 8) & 0xFFL).to_int().to_double()
  if 0.2126 * r + 0.7152 * g + 0.0722 * b < 128.0 {
    0xFFFFFF2AL
  } else {
    0x00000020L
  }
}

///|
/// Whether glass `gl` was liquid glass the window's material made frosted (material_glass gave `made`): ringed by
/// frosted_ring.
fn frosted_made(gl : Glass, made : Glass) -> Bool {
  gl.liquid && !made.liquid && !glass_paint.solid && made.strength > 0.001
}

///|
/// A glass surface as the window's material makes it, before anything reads whether it is liquid. Liquid glass and
/// Solid glass are the surface's own (Solid is drawn as its solid ground: Ctx::glass_solid). Frosted glass is liquid
/// glass made flat frosted glass (kind 5): none of liquid glass's shading (no bezel, rim light, refraction, colours
/// split, pointer light, merging or adaptive ink), what is under it blurred at least `frosted_blur` behind its tint
/// taken `frosted_frost` of the way to its solid ground, a hairline round it (frosted_ring, drawn by its painter). Glass already frosted stays as
/// it is, and a clear magnifying lens (`tint alpha == 0 && zoom > 1`, a drag loupe) stays liquid to keep magnifying.
fn material_glass(gl : Glass, material : GlassMaterial) -> Glass {
  if material != Frosted || !gl.liquid || ((gl.tint & 0xFFL) == 0L && gl.zoom > 1.0001) {
    return gl
  }
  let f = frosted_frost
  let tr = ((gl.tint >> 24) & 0xFFL).to_int().to_double()
  let tg = ((gl.tint >> 16) & 0xFFL).to_int().to_double()
  let tb = ((gl.tint >> 8) & 0xFFL).to_int().to_double()
  let ta = (gl.tint & 0xFFL).to_int().to_double() / 255.0
  let sr = ((gl.solid >> 24) & 0xFFL).to_int().to_double()
  let sg = ((gl.solid >> 16) & 0xFFL).to_int().to_double()
  let sb = ((gl.solid >> 8) & 0xFFL).to_int().to_double()
  // (a clear droplet has no colour of its own: its solid ground's)
  let (tr, tg, tb) = if ta <= 0.0 { (sr, sg, sb) } else { (tr, tg, tb) }
  let mix = f * 0.5
  let r = dclamp((tr + (sr - tr) * mix).round(), 0.0, 255.0).to_int().to_int64()
  let g = dclamp((tg + (sg - tg) * mix).round(), 0.0, 255.0).to_int().to_int64()
  let b = dclamp((tb + (sb - tb) * mix).round(), 0.0, 255.0).to_int().to_int64()
  let a = dclamp(((ta + (0.94 - ta) * f) * 255.0).round(), 0.0, 255.0).to_int().to_int64()
  {
    ..gl,
    liquid: false,
    blur: dmax(gl.blur, frosted_blur),
    tint: (r << 24) | (g << 16) | (b << 8) | a,
    rim_edge: 0.0,
    rim_lit: 0.0,
    rim_back: 0.0,
    rim: 0.0,
    bezel: 0.0,
    refraction: 0.0,
    chroma: 0.0,
    merge: 0.0,
    adaptive: false,
    contained: false,
    progressive: false,
    spot: None,
    zoom: 1.0,
    layer: 0,
    break_gap: 0.0,
    droplet_role: 0,
  }
}

///|
/// What of a content lens (the defocus and bending over what a morphing surface holds, View::content_lens) the
/// window's glass keeps: liquid glass all of it, frosted glass its defocus alone (bending nothing, as its glass bends
/// nothing: material_glass), solid glass none (what it holds drawn as it is: its own alpha its own).
fn material_lens(l : @paint.ContentLens) -> @paint.ContentLens {
  if glass_paint.solid {
    @paint.ContentLens::none()
  } else if glass_paint.material == Frosted {
    { ..l, refraction: 0.0, bezel: 0.0 }
  } else {
    l
  }
}

///|
/// Apply system increase-contrast modulation to a glass surface (as the window's material made it: material_glass).
/// Pure clear optical magnifying lenses (`liquid && tint alpha == 0 && zoom > 1`) and progressive scroll edges
/// (`!liquid && progressive`) are exempted so drag loupes and scroll fades stay optically clean.
fn effective_glass(gl : Glass, contrast : Bool) -> Glass {
  if !contrast {
    return gl
  }
  if gl.liquid && (gl.tint & 0xFFL) == 0L && gl.zoom > 1.0001 {
    return gl
  }
  if !gl.liquid && gl.progressive {
    return gl
  }
  let f = 0.22
  let tr = ((gl.tint >> 24) & 0xFFL).to_int().to_double()
  let tg = ((gl.tint >> 16) & 0xFFL).to_int().to_double()
  let tb = ((gl.tint >> 8) & 0xFFL).to_int().to_double()
  let ta = (gl.tint & 0xFFL).to_int().to_double() / 255.0
  let sr = ((gl.solid >> 24) & 0xFFL).to_int().to_double()
  let sg = ((gl.solid >> 16) & 0xFFL).to_int().to_double()
  let sb = ((gl.solid >> 8) & 0xFFL).to_int().to_double()
  let mix = f * 0.5
  let r = dclamp((tr + (sr - tr) * mix).round(), 0.0, 255.0).to_int().to_int64()
  let g = dclamp((tg + (sg - tg) * mix).round(), 0.0, 255.0).to_int().to_int64()
  let b = dclamp((tb + (sb - tb) * mix).round(), 0.0, 255.0).to_int().to_int64()
  let a_frac = ta + (0.94 - ta) * f
  let a = dclamp((a_frac * 255.0).round(), 0.0, 255.0).to_int().to_int64()
  let tint = (r << 24) | (g << 16) | (b << 8) | a
  let blur = if gl.blur < 14.0 { gl.blur + (14.0 - gl.blur) * (f * 0.5) } else { gl.blur }
  let refraction = if gl.liquid { gl.refraction * (1.0 - 0.55 * f) } else { gl.refraction }
  let rim = if gl.liquid { dmin(1.0, gl.rim * 1.25 + 0.12) } else { gl.rim }
  let rim_edge = if !gl.liquid { dmin(1.0, gl.rim_edge + 0.15) } else { gl.rim_edge }
  let chroma = if gl.liquid && gl.droplet_role == 0 { 0.0 } else { gl.chroma }
  { ..gl, tint, blur, refraction, rim, rim_edge, chroma }
}

///|
fn rects_meet_by(a : Int, b : Int, inst : FixedArray[Double], pad : Double) -> Bool {
  let pa = a * inst_size
  let pb = b * inst_size
  inst[pa] - pad < inst[pb] + inst[pb + 2] + pad &&
  inst[pb] - pad < inst[pa] + inst[pa + 2] + pad &&
  inst[pa + 1] - pad < inst[pb + 1] + inst[pb + 3] + pad &&
  inst[pb + 1] - pad < inst[pa + 1] + inst[pa + 3] + pad
}

///|
/// The glass instance of node `n` (its frame), at `alpha`.
fn Ctx::emit_glass(self : Ctx, n : Node, gl : Glass, alpha : Double) -> Unit {
  if gl.strength <= 0.001 {
    return
  }
  self.glass_inst(n.x, n.y, n.fw, n.fh, n.radius, gl, alpha * gl.strength)
  // (frosted, unmerged liquid, and merged liquid all keep each shape's 4 independent corner radii in 36..39)
  self.corners_last(n)
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
  let gl = effective_glass(gl, glass_paint.contrast)
  let kind = if gl.liquid { 6.0 } else { 5.0 }
  let blur_slot = if !gl.liquid {
    if gl.contained { -gl.blur } else { gl.blur }
  } else if gl.blur <= 0.0 && gl.droplet_role > 0 {
    let zd = if gl.zoom > 1.0001 { dmin(gl.zoom, 3.0) - 1.0 } else { 0.0 }
    -(16.0 * gl.droplet_role.to_double()) - zd
  } else if gl.blur <= 0.0 && gl.zoom > 1.0001 {
    -(dmin(gl.zoom, 3.0) - 1.0)
  } else {
    dmax(gl.blur, 0.0)
  }
  self.push_inst(
    x,
    y,
    w,
    h,
    radius,
    kind,
    gl.saturation,
    blur_slot,
    gl.tint,
    1.0,
    if gl.liquid { gl.rim } else { gl.rim_edge },
    if gl.liquid { gl.bezel } else { gl.rim_lit },
    if gl.liquid {
      let spot_v = glass_spot(gl.spot)
      if gl.adaptive { -(spot_v + 1.0) } else { spot_v }
    } else {
      gl.rim_back
    },
    alpha,
  )
  let b = (self.ninst - 1) * inst_size
  let a = self.inst
  a[b + 21] = if gl.refraction > 0.0 { gl.refraction } else { 0.0 }
  a[b + 22] = if gl.liquid { gl.chroma } else if gl.progressive { -1.0 } else { 0.0 }
  a[b + 23] = gl.merge
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
/// Whether any non-shadow, non-data instance in kept ride `group`'s `[first, first + count)` (offset by `dx, dy`)
/// intersects `[kx0, ky0, kx1, ky1]`, handling nested `kind == 13.0` headers without reading unwritten slots.
fn glass_ride_blocks(
  group : Int,
  first : Int,
  count : Int,
  dx : Double,
  dy : Double,
  kx0 : Double,
  ky0 : Double,
  kx1 : Double,
  ky1 : Double,
) -> Bool {
  match ride_groups.get(group) {
    None => true
    Some(rk) => {
      let (rx0, ry0, rx1, ry1) = rk.reach
      if rx1 + dx <= kx0 || kx1 <= rx0 + dx || ry1 + dy <= ky0 || ky1 <= ry0 + dy {
        return false
      }
      let ra = rk.inst
      let mut i = first
      let end = first + count
      while i < end {
        let p = i * inst_size
        let ik = ra[p + 5]
        if ik == 13.0 {
          let sub_n = ra[p + 14].to_int()
          if glass_ride_blocks(
              ra[p + 12].to_int(),
              ra[p + 13].to_int(),
              sub_n,
              dx + ra[p],
              dy + ra[p + 1],
              kx0,
              ky0,
              kx1,
              ky1,
            ) {
            return true
          }
          i = i + (if sub_n > 0 { sub_n } else { 1 })
          continue
        }
        if ik != 2.0 && ik != 12.0 && ra[p + 2] > 0.0 && ra[p + 3] > 0.0 {
          let ix0 = ra[p] + dx
          let iy0 = ra[p + 1] + dy
          let ix1 = ix0 + ra[p + 2]
          let iy1 = iy0 + ra[p + 3]
          if ix0 < kx1 && kx0 < ix1 && iy0 < ky1 && ky0 < iy1 {
            return true
          }
        }
        i = i + 1
      }
      false
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
  // For liquid glass (kind 6), a negative slot 7 encodes clear-lens optical zoom (-(zoom - 1.0)) with effective blur 0.0.
  let eff_blur = if liquid && blur < 0.0 { 0.0 } else { blur }
  let is_single_liquid = liquid && a[b + 23] <= 0.0
  let is_progressive = !liquid && a[b + 22] < -0.5
  if shares && !liquid && !is_progressive && glass_paint.frost_run != 0 {
    // the last frosted capture's (liquid glass's is no frost, and only of what is under its shapes), the run as it was
    a[b + 20] = -glass_paint.frost_run.to_double()
    return
  }
  if shares &&
    is_single_liquid &&
    eff_blur >= 0.0 &&
    glass_paint.liquid_run != 0 &&
    glass_paint.liquid_blur == eff_blur &&
    glass_paint.liquid_first >= 0 {
    let kx0 = a[b]
    let ky0 = a[b + 1]
    let kx1 = kx0 + a[b + 2]
    let ky1 = ky0 + a[b + 3]
    let dy_gap = dmax(0.0, dmax(ky0 - glass_paint.liquid_y1, glass_paint.liquid_y0 - ky1))
    if dy_gap <= 64.0 {
      let run_tag = -glass_paint.liquid_run.to_double()
      let mut blocked = false
      let mut j = glass_paint.liquid_first
      while j < k {
        let pj = j * inst_size
        let jk = a[pj + 5]
        if jk == 13.0 {
          let sub_n = a[pj + 14].to_int()
          if glass_ride_blocks(
              a[pj + 12].to_int(),
              a[pj + 13].to_int(),
              sub_n,
              a[pj],
              a[pj + 1],
              kx0,
              ky0,
              kx1,
              ky1,
            ) {
            blocked = true
            break
          }
          j = j + (if sub_n > 0 { sub_n } else { 1 })
          continue
        }
        if jk != 2.0 &&
          jk != 12.0 &&
          a[pj + 20] != run_tag &&
          a[pj + 2] > 0.0 &&
          a[pj + 3] > 0.0 &&
          rects_meet_by(j, k, a, 0.0) {
          blocked = true
          break
        }
        j = j + 1
      }
      if !blocked {
        a[b + 20] = run_tag
        glass_paint.liquid_y0 = dmin(glass_paint.liquid_y0, ky0)
        glass_paint.liquid_y1 = dmax(glass_paint.liquid_y1, ky1)
        return
      }
    }
  }
  // one capture with the glass just before it: right after it, as it is,
  // the same blur, not over it, and (merged liquid) a group of fewer than 8; frosted glass
  // contained (blur below 0) or progressive (slot 22 < -0.5) takes a capture of its own
  let prev = glass_paint.run_start + glass_paint.run_len
  let prev_is_single = liquid && k > 0 && a[(k - 1) * inst_size + 23] <= 0.0
  let prev_is_progressive = !liquid && k > 0 && a[(k - 1) * inst_size + 22] < -0.5
  let prev_eff_blur = if k > 0 {
    let pb = a[(k - 1) * inst_size + 7]
    if liquid && pb < 0.0 { 0.0 } else { pb }
  } else {
    0.0
  }
  let mut same = glass_paint.run != 0 &&
    prev == k &&
    !is_progressive &&
    !prev_is_progressive &&
    eff_blur >= 0.0 &&
    a[(k - 1) * inst_size + 5] == kind &&
    prev_eff_blur == eff_blur &&
    (!liquid ||
      (is_single_liquid && prev_is_single) ||
      (!is_single_liquid && !prev_is_single && glass_paint.run_len < 8))
  if same && (!liquid || is_single_liquid) {
    let pad = if is_single_liquid { 2.0 } else { 0.0 }
    if is_single_liquid && glass_paint.liquid_run == glass_paint.run && glass_paint.liquid_first >= 0 {
      let ky0 = a[b + 1]
      let ky1 = ky0 + a[b + 3]
      let dy_gap = dmax(0.0, dmax(ky0 - glass_paint.liquid_y1, glass_paint.liquid_y0 - ky1))
      if dy_gap > 64.0 {
        same = false
      }
    }
    if same {
      for j in glass_paint.run_start..<k {
        if rects_meet_by(j, k, a, pad) {
          same = false
          break
        }
      }
    }
  }
  if same {
    glass_paint.run_len = glass_paint.run_len + 1
    if is_single_liquid && glass_paint.liquid_run == glass_paint.run {
      glass_paint.liquid_y0 = dmin(glass_paint.liquid_y0, a[b + 1])
      glass_paint.liquid_y1 = dmax(glass_paint.liquid_y1, a[b + 1] + a[b + 3])
    }
  } else {
    glass_paint.run = glass_paint.run + 1
    glass_paint.run_start = k
    glass_paint.run_len = 1
    if !liquid && !is_progressive {
      glass_paint.frost_run = glass_paint.run
      glass_paint.liquid_run = 0
      glass_paint.liquid_first = -1
    } else if is_single_liquid && eff_blur >= 0.0 {
      glass_paint.liquid_run = glass_paint.run
      glass_paint.liquid_blur = eff_blur
      glass_paint.liquid_first = k
      glass_paint.liquid_y0 = a[b + 1]
      glass_paint.liquid_y1 = a[b + 1] + a[b + 3]
    } else {
      glass_paint.liquid_run = 0
      glass_paint.liquid_first = -1
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
      match n.glass.map(fn(gl) { material_glass(gl, glass_paint.material) }) {
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
  if gl.strength <= 0.001 {
    if n.shadow > 0.0 {
      self.paint_shadow(n, alpha, n.shadow_out)
    }
    return
  }
  if glass_paint.solid {
    if n.shadow > 0.0 {
      self.paint_shadow(n, alpha, false)
    }
    self.emit_rect(n.x, n.y, n.fw, n.fh, n.radius, gl.solid, 0.0, 0L, alpha * gl.strength)
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
