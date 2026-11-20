// Apple iOS 27 GlassEffectContainer-style liquid merge & split control driven by `@motion.LiquidBond`.
//
// Capillary hysteresis contract:
// - Dragging from merged (`gap <= 0`) rightward stretches a smooth liquid bridge across `0 < gap < break_gap`
//   with subtle surface-tension damping. Once `gap >= break_gap`, the bond snaps irreversibly (`Split`),
//   `merge` decays critically damped to `0.0` (zero bounce), and when `auto_separate=true` the satellite
//   automatically springs to `separated_gap`. Releasing before `break_gap` snaps back into merged.
// - Dragging from separated leftward keeps `merge == 0.0` across the entire air gap (`gap > 0`), even
//   when paused or released at `gap = 3pt` (zero magnetic attraction). Upon physical contact (`gap <= 0`),
//   the bond flips (`Fused`), `merge` blooms to `merge_max`, and the satellite absorbs into the capsule.

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
pub let merge_k_max : Double = 26.0

///|
pub let merge_break_gap : Double = 11.7

///|
fn merge_smoothstep(lo : Double, hi : Double, x : Double) -> Double {
  if hi <= lo {
    return if x >= hi { 1.0 } else { 0.0 }
  }
  let u = clamp((x - lo) / (hi - lo), 0.0, 1.0)
  u * u * (3.0 - 2.0 * u)
}

///|
fn merge_glass(merge : Double, spot? : (Double, Double)? = None) -> @paint.Glass {
  let d = is_dark()
  @paint.Glass::liquid(
    blur=2.1,
    tint=if d { 0x202020FFL } else { 0xFDFCFD67L },
    solid=if d { 0x1E1F24FFL } else { 0xFAFAFAFFL },
    saturation=1.0,
    rim=0.6,
    bezel=20.0,
    refraction=28.0,
    chroma=0.0,
    merge~,
    adaptive=false,
    spot~,
  )
}

///|
/// Controller for a two-body liquid glass merge/split interaction.
pub struct LiquidMerge {
  priv merged_gap : Double
  priv separated_gap : Double
  priv max_gap : Double
  priv auto_separate : Bool
  priv bond : @motion.LiquidBond
  priv gap_way : @motion.Way
  priv separated_sig : @signals.Signal[Bool]
  priv dragging : Ref[Bool]
  priv drag_start_x : Ref[Double]
  priv drag_start_gap : Ref[Double]
  priv auto_released : Ref[Bool]
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
  let start_gap = if separated { separated_gap } else { merged_gap }
  {
    merged_gap,
    separated_gap,
    max_gap,
    auto_separate,
    bond: @motion.LiquidBond::new(merged=!separated, merge_max~, break_gap~, contact_gap=0.0),
    gap_way: @motion.Way::new(start_gap),
    separated_sig: @signals.signal(separated, same=fn(a, b) { a == b }),
    dragging: Ref(false),
    drag_start_x: Ref(0.0),
    drag_start_gap: Ref(start_gap),
    auto_released: Ref(false),
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
/// Current surface gap (dp) as drawn on `n`.
pub fn LiquidMerge::gap_on(self : LiquidMerge, n : @view.View) -> Double {
  self.gap_way.shown_on(n)
}

///|
/// Current surface gap (dp) at moment `t` (ms).
pub fn LiquidMerge::gap_at(self : LiquidMerge, t : Double) -> Double {
  self.gap_way.value_at(t)
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
/// Moment (ms) when all gap, merge, and recoil motions are at rest.
pub fn LiquidMerge::end(self : LiquidMerge) -> Double {
  let ge = self.gap_way.end()
  let be = self.bond.end()
  if ge > be { ge } else { be }
}

///|
/// Programmatically animates to `separated` (`true`: stretch bridge -> snap at `break_gap` -> glide to `separated_gap`;
/// `false`: approach with strictly zero attraction -> fuse at exact physical contact `gap <= 0.0`).
#callsite(autofill(loc))
pub fn LiquidMerge::set_separated(
  self : LiquidMerge,
  separated : Bool,
  at~ : Double,
  loc~ : SourceLoc,
) -> Unit {
  self.cancel_scheduled()
  self.dragging.val = false
  self.auto_released.val = false
  self.separated_sig.set(separated)
  let target = if separated { self.separated_gap } else { self.merged_gap }
  self.gap_way.go(target, @motion.liquid_toggle_spring, at~, loc~)
  let threshold = if separated { self.bond.break_gap() } else { self.bond.contact_gap() }
  let t_end = self.gap_way.end()
  let cross = @motion.liquid_bond_cross_time(
    at,
    if t_end > at { t_end } else { at },
    fn(t) { self.gap_way.value_at(t) },
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
  self.dragging.val = true
  self.auto_released.val = false
  self.drag_start_x.val = d.wx
  self.drag_start_gap.val = self.gap_way.value_at(d.at)
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
      if !self.dragging.val || self.auto_released.val {
        return
      }
      let raw_gap = clamp(
        self.drag_start_gap.val + (d.wx - self.drag_start_x.val),
        self.merged_gap - 6.0,
        self.max_gap,
      )
      // Subtle capillary surface-tension resistance while stretching an active liquid bridge.
      let eff_gap = if self.bond.is_bonded() && raw_gap > 0.0 {
        raw_gap * 0.82
      } else {
        raw_gap
      }
      self.gap_way.put(eff_gap)
      match self.bond.update(eff_gap, at=d.at) {
        Split => {
          self.separated_sig.set(true)
          if self.auto_separate {
            self.auto_released.val = true
            self.gap_way.go(self.separated_gap, @motion.liquid_auto_split_spring, at=d.at)
          }
        }
        Fused => {
          self.separated_sig.set(false)
          self.auto_released.val = true
          self.gap_way.go(self.merged_gap, @motion.liquid_auto_fuse_spring, at=d.at)
        }
        Steady => ()
      }
    }
    Up | Off => {
      self.dragging.val = false
      if !self.auto_released.val && self.bond.is_bonded() {
        // Released before snapping past break_gap: spring back into merged state.
        self.gap_way.go(self.merged_gap, @motion.liquid_snap_back_spring, at=d.at)
      }
      // When separated (not bonded), stay where released with zero magnetic attraction.
    }
  }
}

///|
/// Interactive liquid merge/split stage in `parent`: a main capsule on the left and a draggable satellite glass sphere
/// on the right. Shadows sit in a preceding sibling layer (satellite shadow fading in with separation so dark shadow
/// never bleeds into the capsule), followed by two strictly adjacent glass boxes so `merge > 0` enters one `sd_group`
/// and `merge == 0` uses single-capture `.sharing()`.
#callsite(autofill(loc))
pub fn liquid_merge_node(
  parent : @view.View,
  controller? : LiquidMerge,
  main_w? : Double = merge_main_w,
  main_h? : Double = merge_main_h,
  sat_size? : Double = merge_sat_size,
  main_label? : () -> String = fn() { "Capsule" },
  sat_label? : () -> String = fn() { "+" },
  label? : () -> String = fn() { "Liquid Merge" },
  loc~ : SourceLoc,
) -> @view.View {
  let ctrl = match controller {
    Some(c) => c
    None => LiquidMerge::new()
  }
  let stage_w = main_w + ctrl.max_gap + sat_size + 16.0
  let stage_h = (if main_h > sat_size { main_h } else { sat_size }) + 24.0
  let main_y = (stage_h - main_h) * 0.5
  let sat_y = (stage_h - sat_size) * 0.5
  let brk = ctrl.bond.break_gap()
  parent.box(made_for=loc, fn(stage) {
    ctrl.attach(stage)
    stage.width(Is(Some(stage_w))).height(Is(Some(stage_h))).shrink(Is(0.0)) |> ignore
    // 1. Preceding shadow layer (outside-only shadows; satellite shadow fades in smoothly as gap opens)
    stage.box(fn(shadows) {
      shadows.over(Is(true)) |> ignore
      shadows.box(fn(ms) {
        ms
        .over(Is(true))
        .width(Is(Some(main_w)))
        .height(Is(Some(main_h)))
        .offset(Is((0.0, main_y)))
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
        .offset(Is((main_w, sat_y)))
        .radius(Is(sat_size / 2.0))
        .shadow(Is(shadow_default))
        .shadow_outside(Is(true))
        .alpha(By(fn() { merge_smoothstep(0.0, brk, ctrl.gap_on(ss)) }))
        |> ignore
        ss.moved_by(
          fn(_, _, t) {
            ctrl.gap_way.said()
            (ctrl.gap_way.value_at(t), 0.0)
          },
          fn(_, _) {
            ctrl.gap_way.said()
            ctrl.gap_way.end()
          },
        )
        |> ignore
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
      .offset(Is((0.0, main_y)))
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
      .offset(Is((main_w, sat_y)))
      .radius(Is(sat_size / 2.0))
      .glass(By(fn() {
        let m = ctrl.merge_on(sg)
        if m > 0.0 {
          Some(merge_glass(m))
        } else {
          Some(merge_glass(0.0).sharing())
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
      sg.moved_by(
        fn(_, _, t) {
          ctrl.gap_way.said()
          (ctrl.gap_way.value_at(t), 0.0)
        },
        fn(_, _) {
          ctrl.gap_way.said()
          ctrl.gap_way.end()
        },
      )
      |> ignore
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
        .offset(Is((0.0, main_y)))
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
        .offset(Is((main_w, sat_y)))
        .radius(Is(sat_size / 2.0))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .says(By(fn() { Some(@view.said(Group, label=label())) }))
        .gesture(@ui.touch_slop(), press=fn(d) { ctrl.on_press(d) }, drag=fn(d) { ctrl.on_drag(d) })
        |> ignore
        hit.moved_by(
          fn(_, _, t) {
            ctrl.gap_way.said()
            (ctrl.gap_way.value_at(t), 0.0)
          },
          fn(_, _) {
            ctrl.gap_way.said()
            ctrl.gap_way.end()
          },
        )
        |> ignore
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
