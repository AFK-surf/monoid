// Apple iOS 27 GlassEffectContainer-style liquid merge & split control driven by `@motion.LiquidBond`.
//
// 360° 2D Capillary hysteresis contract:
// - Dragging from merged (`gap <= 0`) outward in any direction stretches a smooth liquid bridge across
//   `0 < gap < break_gap` with gentle normal-aligned surface-tension resistance. Once `gap >= break_gap`, the bond
//   snaps (`Split`), `merge` decays critically damped to `0.0` (zero bounce), and a brief recoil impulse settles
//   while the pointer keeps 1:1 2D control (never locking out `Moved`).
// - Dragging while separated keeps `merge == 0.0` across the entire 360° air gap (`gap > 0`), even when hovering or
//   released at `gap = 3pt` (zero magnetic attraction). Upon physical contact with any edge (`gap <= 0`), the bond
//   flips (`Fused`), `merge` blooms to `merge_max`, and the pointer may keep sliding or pull apart again without
//   releasing.
// - On release: a bonded droplet settles gently onto the rim at `merged_gap`; a droplet that just snapped apart and
//   is still closer than `separated_gap` glides along the outward normal to `separated_gap`; otherwise it stays put.

///|
/// Default geometry and capillary thresholds for `liquid_merge_node` (dp).
pub let merge_main_w : Double = 180.0

///|
pub let merge_main_h : Double = 56.0

///|
pub let merge_sat_size : Double = 56.0

///|
pub let merge_merged_gap : Double = -8.0

///|
pub let merge_separated_gap : Double = 48.0

///|
pub let merge_max_gap : Double = 72.0

///|
pub let merge_k_max : Double = 34.0

///|
pub let merge_break_gap : Double = 9.5

///|
/// Visual outer-contour tangency offset (0.75pt external contour on each glass body = 1.5pt total).
pub let merge_contact_gap : Double = 1.5

///|
fn merge_smoothstep(lo : Double, hi : Double, x : Double) -> Double {
  if hi <= lo {
    return if x >= hi { 1.0 } else { 0.0 }
  }
  let u = clamp((x - lo) / (hi - lo), 0.0, 1.0)
  u * u * (3.0 - 2.0 * u)
}

///|
fn merge_glass(merge : Double, rim? : Double = 0.6, spot? : (Double, Double)? = None) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=2.1,
    tint=if d { 0x202020FFL } else { 0xFDFCFD67L },
    solid=if d { 0x1E1F24FFL } else { 0xFAFAFAFFL },
    saturation=1.0,
    rim~,
    bezel=20.0,
    refraction=28.0,
    chroma=0.0,
    merge~,
    adaptive=false,
    spot~,
  )
}

///|
/// Controller for a two-body 360° 2D liquid glass merge/split interaction.
pub struct LiquidMerge {
  priv merged_gap : Double
  priv separated_gap : Double
  priv max_gap : Double
  priv auto_separate : Bool
  priv bond : @motion.LiquidBond
  priv x_way : @motion.Way
  priv y_way : @motion.Way
  priv recoil_x : @motion.Way
  priv recoil_y : @motion.Way
  priv separated_sig : @signals.Signal[Bool]
  priv dragging_sig : @signals.Signal[Bool]
  priv dragging : Ref[Bool]
  priv drag_start_wx : Ref[Double]
  priv drag_start_wy : Ref[Double]
  priv drag_start_x : Ref[Double]
  priv drag_start_y : Ref[Double]
  priv split_this_drag : Ref[Bool]
  priv geom : Ref[(Double, Double, Double, Double, Double)]
  priv bounds : Ref[(Double, Double, Double, Double)]
  priv scheduled : Ref[(() -> Unit)?]
  priv node : Ref[@view.View?]
}

///|
/// Creates a `LiquidMerge` controller, starting either merged (`separated=false`) or separated.
pub fn LiquidMerge::new(
  separated? : Bool = false,
  merge_max? : Double = merge_k_max,
  break_gap? : Double = merge_break_gap,
  merged_gap? : Double = merge_merged_gap,
  separated_gap? : Double = merge_separated_gap,
  max_gap? : Double = merge_max_gap,
  auto_separate? : Bool = true,
) -> LiquidMerge {
  let start_x = (if separated { separated_gap } else { merged_gap }) + merge_contact_gap
  {
    merged_gap,
    separated_gap,
    max_gap,
    auto_separate,
    bond: @motion.LiquidBond::new(merged=!separated, merge_max~, break_gap~, contact_gap=0.0),
    x_way: @motion.Way::new(start_x),
    y_way: @motion.Way::new(0.0),
    recoil_x: @motion.Way::new(0.0),
    recoil_y: @motion.Way::new(0.0),
    separated_sig: @signals.signal(separated, same=fn(a, b) { a == b }),
    dragging_sig: @signals.signal(false, same=fn(a, b) { a == b }),
    dragging: Ref(false),
    drag_start_wx: Ref(0.0),
    drag_start_wy: Ref(0.0),
    drag_start_x: Ref(start_x),
    drag_start_y: Ref(0.0),
    split_this_drag: Ref(false),
    geom: Ref((0.0, 12.0, merge_main_w, merge_main_h, merge_sat_size)),
    bounds: Ref((merged_gap - 6.0, max_gap, 0.0, 0.0)),
    scheduled: Ref(None),
    node: Ref(None),
  }
}

///|
/// Binds this controller to `n`'s timeline for scheduled closed-form split/fuse transitions.
pub fn LiquidMerge::attach(self : LiquidMerge, n : @view.View) -> Unit {
  self.node.val = Some(n)
}

///|
fn LiquidMerge::cancel_scheduled(self : LiquidMerge) -> Unit {
  match self.scheduled.val {
    Some(stop) => {
      self.scheduled.val = None
      stop()
    }
    None => ()
  }
}

///|
/// Exact 360° 2D visual surface gap (dp) between the main capsule and satellite outer contours at offset `(dx, dy)`.
/// `0.0` corresponds to exact outer-contour tangency (`rounded_rect_gap == merge_contact_gap`).
fn LiquidMerge::surface_gap(self : LiquidMerge, dx : Double, dy : Double) -> Double {
  let (mx, my, mw, mh, sat) = self.geom.val
  let bx = mx + mw + dx
  let by = my + (mh - sat) * 0.5 + dy
  @motion.rounded_rect_gap(mx, my, mw, mh, mh * 0.5, bx, by, sat, sat, sat * 0.5) - merge_contact_gap
}

///|
/// Outward unit surface normal at `(dx, dy)` via central differences of `surface_gap`.
fn LiquidMerge::surface_normal(self : LiquidMerge, dx : Double, dy : Double) -> (Double, Double) {
  let eps = 0.5
  let gx = self.surface_gap(dx + eps, dy) - self.surface_gap(dx - eps, dy)
  let gy = self.surface_gap(dx, dy + eps) - self.surface_gap(dx, dy - eps)
  let len = (gx * gx + gy * gy).sqrt()
  if len < 1.0e-6 {
    (1.0, 0.0)
  } else {
    (gx / len, gy / len)
  }
}

///|
/// Reactive separated state (`true`: separated, `false`: merged).
pub fn LiquidMerge::is_separated(self : LiquidMerge) -> Bool {
  self.separated_sig.get()
}

///|
/// Whether the capillary liquid bridge is currently bonded.
pub fn LiquidMerge::is_bonded(self : LiquidMerge) -> Bool {
  self.bond.is_bonded()
}

///|
/// Current 2D satellite offset `(dx, dy)` (dp) at moment `t` (ms).
pub fn LiquidMerge::pos_at(self : LiquidMerge, t : Double) -> (Double, Double) {
  (self.x_way.value_at(t) + self.recoil_x.value_at(t), self.y_way.value_at(t) + self.recoil_y.value_at(t))
}

///|
/// Current 2D satellite offset `(dx, dy)` (dp) as drawn on `n`.
pub fn LiquidMerge::pos_on(self : LiquidMerge, n : @view.View) -> (Double, Double) {
  (self.x_way.shown_on(n) + self.recoil_x.shown_on(n), self.y_way.shown_on(n) + self.recoil_y.shown_on(n))
}

///|
/// Current 2D surface gap (dp) as drawn on `n`.
pub fn LiquidMerge::gap_on(self : LiquidMerge, n : @view.View) -> Double {
  let (dx, dy) = self.pos_on(n)
  self.surface_gap(dx, dy)
}

///|
/// Current 2D surface gap (dp) at moment `t` (ms).
pub fn LiquidMerge::gap_at(self : LiquidMerge, t : Double) -> Double {
  let (dx, dy) = self.pos_at(t)
  self.surface_gap(dx, dy)
}

///|
/// Current smooth-min merge radius (dp) as drawn on `n`.
pub fn LiquidMerge::merge_on(self : LiquidMerge, n : @view.View) -> Double {
  self.bond.merge_on(n)
}

///|
/// Current smooth-min merge radius (dp) at moment `t` (ms).
pub fn LiquidMerge::merge_at(self : LiquidMerge, t : Double) -> Double {
  self.bond.merge_at(t)
}

///|
/// Current elastic recoil impulse as drawn on `n`.
pub fn LiquidMerge::recoil_on(self : LiquidMerge, n : @view.View) -> Double {
  self.bond.recoil_on(n)
}

///|
/// Moment (ms) when all position, recoil, and bond motions are at rest.
pub fn LiquidMerge::end(self : LiquidMerge) -> Double {
  let mut m = self.x_way.end()
  let ye = self.y_way.end()
  if ye > m {
    m = ye
  }
  let rxe = self.recoil_x.end()
  if rxe > m {
    m = rxe
  }
  let rye = self.recoil_y.end()
  if rye > m {
    m = rye
  }
  let be = self.bond.end()
  if be > m {
    m = be
  }
  m
}

///|
/// Programmatically animates from any 2D position to `separated` (`true`: stretch bridge -> snap at `break_gap` ->
/// glide to `(separated_gap, 0.0)`; `false`: approach with strictly zero attraction -> fuse at exact physical
/// contact `gap <= 0.0` -> settle to `(merged_gap, 0.0)`).
#callsite(autofill(loc))
pub fn LiquidMerge::set_separated(
  self : LiquidMerge,
  separated : Bool,
  at~ : Double,
  loc~ : SourceLoc,
) -> Unit {
  self.cancel_scheduled()
  self.dragging.val = false
  self.dragging_sig.set(false)
  self.split_this_drag.val = false
  let (cur_x, cur_y) = self.pos_at(at)
  self.x_way.put(cur_x)
  self.y_way.put(cur_y)
  self.recoil_x.put(0.0)
  self.recoil_y.put(0.0)
  self.separated_sig.set(separated)
  let target_x = (if separated { self.separated_gap } else { self.merged_gap }) + merge_contact_gap
  self.x_way.go(target_x, @motion.liquid_toggle_spring, at~, loc~)
  self.y_way.go(0.0, @motion.liquid_toggle_spring, at~, loc~)
  let threshold = if separated { self.bond.break_gap() } else { self.bond.contact_gap() }
  let xe = self.x_way.end()
  let ye = self.y_way.end()
  let t_end = if xe > ye { xe } else { ye }
  let cross = @motion.liquid_bond_cross_time(
    at,
    if t_end > at { t_end } else { at },
    fn(t) { self.surface_gap(self.x_way.value_at(t), self.y_way.value_at(t)) },
    separated,
    threshold,
  )
  match cross {
    Some(tc) =>
      if tc <= at {
        self.bond.update(threshold, at=tc, loc~) |> ignore
      } else {
        match self.node.val {
          Some(n) => {
            let stop = n.at_moment(tc, fn() {
              self.scheduled.val = None
              self.bond.update(threshold, at=tc, loc~) |> ignore
            })
            self.scheduled.val = Some(stop)
          }
          None => self.bond.update(threshold, at=tc, loc~) |> ignore
        }
      }
    None => ()
  }
}

///|
fn LiquidMerge::on_press(self : LiquidMerge, d : @view.Drag) -> Unit {
  self.cancel_scheduled()
  let (cur_x, cur_y) = self.pos_at(d.at)
  self.x_way.put(cur_x)
  self.y_way.put(cur_y)
  self.recoil_x.put(0.0)
  self.recoil_y.put(0.0)
  self.dragging.val = true
  self.dragging_sig.set(true)
  self.split_this_drag.val = false
  self.drag_start_wx.val = d.wx
  self.drag_start_wy.val = d.wy
  self.drag_start_x.val = cur_x
  self.drag_start_y.val = cur_y
}

///|
fn LiquidMerge::on_drag(self : LiquidMerge, d : @view.Drag) -> Unit {
  match d.kind {
    Down => {
      if !self.dragging.val {
        self.on_press(d)
      }
    }
    Moved => {
      if !self.dragging.val {
        return
      }
      let (min_dx, max_dx, min_dy, max_dy) = self.bounds.val
      let raw_x = clamp(self.drag_start_x.val + (d.wx - self.drag_start_wx.val), min_dx, max_dx)
      let raw_y = clamp(self.drag_start_y.val + (d.wy - self.drag_start_wy.val), min_dy, max_dy)
      let raw_gap = self.surface_gap(raw_x, raw_y)
      if self.bond.is_bonded() {
        if raw_gap > 0.0 {
          // Gentle capillary surface-tension resistance along the outward normal while stretching an active bridge.
          let (nx, ny) = self.surface_normal(raw_x, raw_y)
          let pull = raw_gap * 0.12
          let eff_x = clamp(raw_x - nx * pull, min_dx, max_dx)
          let eff_y = clamp(raw_y - ny * pull, min_dy, max_dy)
          let eff_gap = self.surface_gap(eff_x, eff_y)
          match self.bond.update(eff_gap, at=d.at) {
            Split => {
              self.separated_sig.set(true)
              self.split_this_drag.val = true
              self.x_way.put(raw_x)
              self.y_way.put(raw_y)
              self.recoil_x.put(eff_x - raw_x)
              self.recoil_y.put(eff_y - raw_y)
              self.recoil_x.go(0.0, @motion.liquid_snap_back_spring, at=d.at)
              self.recoil_y.go(0.0, @motion.liquid_snap_back_spring, at=d.at)
            }
            Fused | Steady => {
              self.x_way.put(eff_x)
              self.y_way.put(eff_y)
            }
          }
        } else {
          self.x_way.put(raw_x)
          self.y_way.put(raw_y)
        }
      } else {
        // Separated: 1:1 2D free drag with strictly zero magnetic attraction across gap > 0.
        self.x_way.put(raw_x)
        self.y_way.put(raw_y)
        match self.bond.update(raw_gap, at=d.at) {
          Fused => {
            self.separated_sig.set(false)
            self.split_this_drag.val = false
          }
          Split | Steady => ()
        }
      }
    }
    Up | Off => {
      self.dragging.val = false
      self.dragging_sig.set(false)
      let (cur_x, cur_y) = self.pos_at(d.at)
      self.x_way.put(cur_x)
      self.y_way.put(cur_y)
      self.recoil_x.put(0.0)
      self.recoil_y.put(0.0)
      let cur_gap = self.surface_gap(cur_x, cur_y)
      let (min_dx, max_dx, min_dy, max_dy) = self.bounds.val
      if self.bond.is_bonded() {
        let (nx, ny) = self.surface_normal(cur_x, cur_y)
        let shift = self.merged_gap - cur_gap
        let tx = clamp(cur_x + nx * shift, min_dx, max_dx)
        let ty = clamp(cur_y + ny * shift, min_dy, max_dy)
        let spec = if cur_gap > 0.0 { @motion.liquid_snap_back_spring } else { @motion.liquid_auto_fuse_spring }
        self.x_way.go(tx, spec, at=d.at)
        self.y_way.go(ty, spec, at=d.at)
      } else if self.auto_separate && self.split_this_drag.val && cur_gap < self.separated_gap {
        let (nx, ny) = self.surface_normal(cur_x, cur_y)
        let shift = self.separated_gap - cur_gap
        let tx = clamp(cur_x + nx * shift, min_dx, max_dx)
        let ty = clamp(cur_y + ny * shift, min_dy, max_dy)
        self.x_way.go(tx, @motion.liquid_auto_split_spring, at=d.at)
        self.y_way.go(ty, @motion.liquid_auto_split_spring, at=d.at)
      }
      // Otherwise stay where released with strictly zero magnetic attraction.
    }
  }
}

///|
/// Interactive liquid merge/split stage in `parent`: a main capsule and a freely draggable satellite glass sphere.
/// When `arena` (reactive) or `arena_w > 0 && arena_h > 0` is given, the stage expands to a full 360° 2D arena;
/// otherwise it uses the compact horizontal track layout. Shadows sit in a preceding sibling layer, followed by two
/// strictly adjacent glass boxes so `merge > 0` enters one `sd_group` and `merge == 0` uses single-capture `.sharing()`.
#callsite(autofill(loc))
pub fn liquid_merge_node(
  parent : @view.View,
  controller? : LiquidMerge,
  main_w? : Double = merge_main_w,
  main_h? : Double = merge_main_h,
  sat_size? : Double = merge_sat_size,
  arena_w? : Double = 0.0,
  arena_h? : Double = 0.0,
  arena? : () -> (Double, Double),
  main_label? : () -> String = fn() { "Capsule" },
  sat_label? : () -> String = fn() { "+" },
  label? : () -> String = fn() { "Liquid Merge" },
  loc~ : SourceLoc,
) -> @view.View {
  let ctrl = match controller {
    Some(c) => c
    None => LiquidMerge::new()
  }
  let compact_w = main_w + ctrl.max_gap + sat_size + 16.0
  let compact_h = (if main_h > sat_size { main_h } else { sat_size }) + 24.0
  let resolve = fn() -> (Double, Double, Double, Double, Double, Double) {
    let (aw, ah) = match arena {
      Some(f) => f()
      None => (arena_w, arena_h)
    }
    let is_arena = aw > 0.0 && ah > 0.0
    let sw = if is_arena { aw } else { compact_w }
    let sh = if is_arena { ah } else { compact_h }
    let mx = if is_arena { (sw - main_w) * 0.5 - 24.0 } else { 0.0 }
    let my = (sh - main_h) * 0.5
    let sx = mx + main_w
    let sy = my + (main_h - sat_size) * 0.5
    ctrl.geom.val = (mx, my, main_w, main_h, sat_size)
    if is_arena {
      let margin = 8.0
      ctrl.bounds.val = (
        margin - sx,
        sw - margin - sat_size - sx,
        margin - sy,
        sh - margin - sat_size - sy,
      )
    } else {
      ctrl.bounds.val = (ctrl.merged_gap - 6.0, ctrl.max_gap, 0.0, 0.0)
    }
    (sw, sh, mx, my, sx, sy)
  }
  if arena is None {
    resolve() |> ignore
  }
  let brk = ctrl.bond.break_gap()
  let sat_move = fn(_ : Double, _ : Double, t : Double) {
    ctrl.x_way.said()
    ctrl.y_way.said()
    ctrl.recoil_x.said()
    ctrl.recoil_y.said()
    ctrl.pos_at(t)
  }
  let sat_end = fn(_ : Double, _ : Double) {
    ctrl.x_way.said()
    ctrl.y_way.said()
    ctrl.recoil_x.said()
    ctrl.recoil_y.said()
    ctrl.end()
  }
  let main_off = fn() -> (Double, Double) {
    let (_, _, mx, my, _, _) = resolve()
    (mx, my)
  }
  let sat_off = fn() -> (Double, Double) {
    let (_, _, _, _, sx, sy) = resolve()
    (sx, sy)
  }
  parent.box(made_for=loc, fn(stage) {
    ctrl.attach(stage)
    stage
    .width(By(fn() { Some(resolve().0) }))
    .height(By(fn() { Some(resolve().1) }))
    .shrink(Is(0.0))
    |> ignore
    // 1. Preceding shadow layer (outside-only shadows; satellite shadow fades in smoothly as gap opens)
    stage.box(fn(shadows) {
      shadows.over(Is(true)) |> ignore
      shadows.box(fn(ms) {
        ms
        .over(Is(true))
        .width(Is(Some(main_w)))
        .height(Is(Some(main_h)))
        .offset(By(main_off))
        .radius(Is(main_h / 2.0))
        .shadow(Is(shadow_default))
        .shadow_outside(Is(true))
        |> ignore
      })
      |> ignore
      shadows.box(fn(ss) {
        ss
        .over(Is(true))
        .width(Is(Some(sat_size)))
        .height(Is(Some(sat_size)))
        .offset(By(sat_off))
        .radius(Is(sat_size / 2.0))
        .shadow(Is(shadow_default))
        .shadow_outside(Is(true))
        .alpha(By(fn() { merge_smoothstep(0.0, brk, ctrl.gap_on(ss)) }))
        |> ignore
        ss.moved_by(sat_move, sat_end) |> ignore
      })
      |> ignore
    })
    |> ignore
    // 2. Strictly adjacent liquid glass boxes (no foreground children inside either box)
    stage.box(fn(mg) {
      mg
      .over(Is(true))
      .width(Is(Some(main_w)))
      .height(Is(Some(main_h)))
      .offset(By(main_off))
      .radius(Is(main_h / 2.0))
      .glass(By(fn() { Some(merge_glass(ctrl.merge_on(mg))) }))
      |> ignore
    })
    |> ignore
    stage.box(fn(sg) {
      sg
      .over(Is(true))
      .width(Is(Some(sat_size)))
      .height(Is(Some(sat_size)))
      .offset(By(sat_off))
      .radius(Is(sat_size / 2.0))
      .glass(By(fn() {
        let rim = if ctrl.dragging_sig.get() { 0.78 } else { 0.6 }
        let m = ctrl.merge_on(sg)
        if m > 0.0 {
          Some(merge_glass(m, rim~))
        } else {
          Some(merge_glass(0.0, rim~).sharing())
        }
      }))
      .ground_drawn(By(fn() {
        let r = clamp(ctrl.recoil_on(sg), -0.3, 0.3)
        if r.abs() < 0.001 {
          return @view.ground_as_laid
        }
        let sx = 1.0 - r * 0.25
        let sy = 1.0 + r * 0.22
        stretched(sat_size, sat_size, 0.0, 0.0, sx, sy)
      }))
      |> ignore
      sg.moved_by(sat_move, sat_end) |> ignore
    })
    |> ignore
    // 3. Foreground content & draggable satellite handle (drawn after both glass boxes)
    stage.box(fn(fg) {
      fg.over(Is(true)) |> ignore
      fg.box(fn(ml) {
        ml
        .over(Is(true))
        .width(Is(Some(main_w)))
        .height(Is(Some(main_h)))
        .offset(By(main_off))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        |> ignore
        ml.box(fn(w) {
          w.words(By(main_label), look=words_at(type_body, weight=weight_medium)).ink(By(fn() { colors().content }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      fg.box(fn(hit) {
        hit
        .over(Is(true))
        .width(Is(Some(sat_size)))
        .height(Is(Some(sat_size)))
        .offset(By(sat_off))
        .radius(Is(sat_size / 2.0))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .says(By(fn() { Some(@view.said(Group, label=label())) }))
        .gesture(2.0, press=fn(d) { ctrl.on_press(d) }, drag=fn(d) { ctrl.on_drag(d) })
        |> ignore
        hit.moved_by(sat_move, sat_end) |> ignore
        hit.box(fn(w) {
          w.words(By(sat_label), look=words_at(22.0, weight=weight_medium)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}
