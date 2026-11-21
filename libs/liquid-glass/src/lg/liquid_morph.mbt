// Apple iOS 26/27 Liquid Glass Menu Morph with physically gap-driven GPU SDF capillary bridge
// (`merged_liquid`) for anchored floating overlays (`liquid_menu_node`, `liquid_select_node`,
// `liquid_popover_node`).
//
// Closed-form `@motion.NodeWay` architecture (zero frame loops, 60/120/24/7 fps invariant):
// - Two-stage drop-first emergence: the morphing droplet accelerates out of the trigger along `side`
//   (`drop_t = 1 - (1 - pt)^2`) while staying hugged to the trigger's cross-axis width until it clears
//   the trigger bar (`gap >= 0`), then blooms smoothly to full width `w` with zero overlap against
//   neighboring bar controls.
// - Capillary bridge merge radius `m` is driven strictly by real physical edge gap `gap`:
//   stays bonded across `gap < ovl_morph_break_gap (5.8pt)` (forming a visible curved hourglass neck
//   in the `1.5..5.8pt` air gap) and snaps cleanly to `0.0` only once `gap >= 5.8pt`, guaranteeing
//   zero overlap after separation.
// - Strict 4-layer draw order guarantees GPU `merged_liquid` SDF batching (`prev == k` with identical
//   `blur`, `alpha`, and `merge > 0`, zero intervening shadows/grounds/children):
//   1. `shadow_box` (`shadow_outside(true)`, zero `.glass`)
//   2. `trigger_ghost` (locks onto trigger rect while `m > 0.01`; `None` once separated / at rest)
//   3. `shell` (immediately adjacent glass sibling; settles bit-exact to `ovl_panel_glass()` & `ground_as_laid`)
//   4. `content_box` (fades in only once `gap >= 5.0pt`, zero text overflow on any frame)

///|
/// Leave duration (ms) passed to `pop.layer(..., leave=ovl_morph_leave_ms)` so the closing capillary
/// re-absorption completes cleanly before unmount.
let ovl_morph_leave_ms : Double = 260.0

///|
/// Peak GPU smooth-min metaball merge radius (pt) between `trigger_ghost` and `shell` while bonded.
let ovl_morph_merge_max : Double = 30.0

///|
/// Minimum physical air gap (pt) between trigger and shell before the capillary liquid bridge snaps off.
/// Guarantees that once separated (`trigger_ghost` unmounted), a clean `>= 5.8pt` air gap separates them.
let ovl_morph_break_gap : Double = 5.8

///|
/// GLSL-style cubic Hermite smoothstep supporting both rising (`edge0 < edge1`) and falling (`edge0 > edge1`) ramps.
fn ovl_smoothstep(edge0 : Double, edge1 : Double, x : Double) -> Double {
  if edge0 == edge1 {
    return if x >= edge1 { 1.0 } else { 0.0 }
  }
  let u = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
  u * u * (3.0 - 2.0 * u)
}

///|
/// Exact scale pivot `(ox, oy)` aligned to the trigger's `(side, along)` anchor for content reveal.
fn ovl_morph_pivot(side : @view.Side, along : @view.Along) -> @view.Pivot {
  let ax = match along {
    Start => 0.12
    End => 0.88
    Middle => 0.5
  }
  let ay = match along {
    Start => 0.15
    End => 0.85
    Middle => 0.5
  }
  match side {
    Bottom => At(ax, 0.0)
    Top => At(ax, 1.0)
    Right => At(0.0, ay)
    Left => At(1.0, ay)
  }
}

///|
/// Capillary bridge merge radius (pt) driven strictly by physical edge gap `gap`:
/// - `gap >= ovl_morph_break_gap` or `p <= 0.01`: strictly `0.0` (clean snap-off with zero post-separation overlap).
/// - `gap <= 1.5`: full `ovl_morph_merge_max` while emerging from the trigger.
/// - `1.5 < gap < ovl_morph_break_gap`: smoothly thins from `30.0` to `14.0` across the real air gap.
fn ovl_morph_bridge_merge_for_gap(p : Double, gap : Double) -> Double {
  if gap >= ovl_morph_break_gap || p <= 0.01 {
    return 0.0
  }
  let onset = ovl_smoothstep(0.0, 0.06, p)
  if gap <= 1.5 {
    ovl_morph_merge_max * onset
  } else {
    lerp(ovl_morph_merge_max, 14.0, ovl_smoothstep(1.5, ovl_morph_break_gap, gap)) * onset
  }
}

///|
/// Shared dynamic Liquid Glass recipe for both `trigger_ghost` and `shell`.
/// Both siblings call this with the exact same `gap`, guaranteeing identical `blur` for GPU `merged_liquid`
/// batching (`blur=4.0` during bridging, settling to `8.0` at rest), and matching `ovl_panel_glass()`
/// bit-for-bit once `energy <= 0.001 && merge <= 0.001 && gap >= 7.2`.
fn ovl_morph_panel_glass(gap : Double, energy : Double, merge~ : Double) -> @paint.Glass {
  if energy <= 0.001 && merge <= 0.001 && gap >= 7.2 {
    return ovl_panel_glass()
  }
  let d = is_dark()
  let e = clamp(energy, 0.0, 1.0)
  let m = if merge > 0.0 { merge } else { 0.0 }
  let blur = lerp(4.0, 8.0, ovl_smoothstep(4.0, 7.2, gap))
  @paint.Glass::liquid(
    blur~,
    tint=if d { 0x202020FFL } else { 0xFDFCFD67L },
    solid=if d { 0x1C1C1EFFL } else { 0xF7F7FAFFL },
    saturation=1.0,
    rim=0.6 + 0.45 * e,
    bezel=20.0 + 12.0 * e,
    refraction=36.0 + 28.0 * e,
    chroma=-0.055 * e,
    merge=m,
    adaptive=false,
  )
}

///|
/// Closed-form trigger recoil way: fires a crisp `0.94 -> 1.0` tactile bounce when `open` transitions to `true`.
fn ovl_trigger_recoil_way(trigger : @view.View, open : () -> Bool) -> @motion.NodeWay {
  let way = @motion.NodeWay::new(1.0)
  trigger.reacts(at_start=false, open, fn(is_open) {
    if is_open {
      way.go_from(trigger, 0.94, 1.0, @motion.tactile_bounce)
    }
  })
  way
}

///|
/// Attaches a subtle liquid elastic recoil (`0.94 -> 1.0` on `@motion.tactile_bounce`) to a menu/popover trigger
/// whenever its overlay opens.
fn ovl_attach_trigger_recoil(trigger : @view.View, open : () -> Bool) -> Unit {
  let way = ovl_trigger_recoil_way(trigger, open)
  trigger.scale(By(fn() { way.shown(trigger) })) |> ignore
}

///|
/// Exact trigger button rect `(tx, ty, tw, th, tr)` in the unscaled `panel` coordinate space `(0, 0, w, h)`.
fn ovl_morph_trigger_rect(
  w : Double,
  h : Double,
  side : @view.Side,
  along : @view.Along,
  anchor_size : (Double, Double),
) -> (Double, Double, Double, Double, Double) {
  let tw = anchor_size.0
  let th = anchor_size.1
  let tr = th * 0.5
  let ax = match along {
    Start => 0.0
    End => w - tw
    Middle => (w - tw) * 0.5
  }
  let ay = match along {
    Start => 0.0
    End => h - th
    Middle => (h - th) * 0.5
  }
  let (tx, ty) = match side {
    Bottom => (ax, -ovl_float_gap - th)
    Top => (ax, h + ovl_float_gap)
    Right => (-ovl_float_gap - tw, ay)
    Left => (w + ovl_float_gap, ay)
  }
  (tx, ty, tw, th, tr)
}

///|
/// Computes both the morphing panel `GroundShape` and the exact physical edge gap `gap` (pt) between the
/// trigger and the morphing shell (`gap < 0` overlapping, `gap == 0` touching, `gap > 0` clean air gap).
fn ovl_morph_shell_geom(
  w : Double,
  h : Double,
  side : @view.Side,
  along : @view.Along,
  anchor_size : (Double, Double),
  panel_radius : Double,
  sx : Double,
  sy : Double,
  p : Double,
) -> (@view.GroundShape, Double) {
  if (sx - 1.0).abs() < 0.001 && (sy - 1.0).abs() < 0.001 && (p - 1.0).abs() < 0.001 {
    return (@view.ground_as_laid, ovl_float_gap)
  }
  if w <= 0.0 || h <= 0.0 {
    return (@view.ground_as_laid, ovl_float_gap)
  }
  let (tx, ty, tw, th, tr) = ovl_morph_trigger_rect(w, h, side, along, anchor_size)
  let px = clamp(sx, 0.0, 1.06)
  let py = clamp(sy, 0.0, 1.06)
  let pt = clamp(p, 0.0, 1.0)
  // Quadratic ease-out drop clears the trigger bar early so bridging and expansion happen in clean air space.
  let drop_t = 1.0 - (1.0 - pt) * (1.0 - pt)
  let (mx, my, mw, mh, gap) = match side {
    Bottom => {
      let my_start = ty + th * 0.5
      let y = lerp(my_start, 0.0, drop_t)
      let g = y - (ty + th)
      let clear_t = ovl_smoothstep(-4.0, 4.5, g)
      let px_eff = clamp(lerp(px * 0.15, px, clear_t), 0.0, 1.06)
      let raw_mw = lerp(tw, w, px_eff)
      let raw_mh = lerp(th, h, py)
      let cur_w = if raw_mw > 4.0 { raw_mw } else { 4.0 }
      let cur_h = if raw_mh > 4.0 { raw_mh } else { 4.0 }
      let x = match along {
        Start => 0.0
        End => w - cur_w
        Middle => (w - cur_w) * 0.5
      }
      (x, y, cur_w, cur_h, g)
    }
    Top => {
      let bot_start = ty + th * 0.5
      let bot = lerp(bot_start, h, drop_t)
      let g = ty - bot
      let clear_t = ovl_smoothstep(-4.0, 4.5, g)
      let px_eff = clamp(lerp(px * 0.15, px, clear_t), 0.0, 1.06)
      let raw_mw = lerp(tw, w, px_eff)
      let raw_mh = lerp(th, h, py)
      let cur_w = if raw_mw > 4.0 { raw_mw } else { 4.0 }
      let cur_h = if raw_mh > 4.0 { raw_mh } else { 4.0 }
      let x = match along {
        Start => 0.0
        End => w - cur_w
        Middle => (w - cur_w) * 0.5
      }
      (x, bot - cur_h, cur_w, cur_h, g)
    }
    Right => {
      let mx_start = tx + tw * 0.5
      let x = lerp(mx_start, 0.0, drop_t)
      let g = x - (tx + tw)
      let clear_t = ovl_smoothstep(-4.0, 4.5, g)
      let py_eff = clamp(lerp(py * 0.15, py, clear_t), 0.0, 1.06)
      let raw_mw = lerp(tw, w, px)
      let raw_mh = lerp(th, h, py_eff)
      let cur_w = if raw_mw > 4.0 { raw_mw } else { 4.0 }
      let cur_h = if raw_mh > 4.0 { raw_mh } else { 4.0 }
      let y = match along {
        Start => 0.0
        End => h - cur_h
        Middle => (h - cur_h) * 0.5
      }
      (x, y, cur_w, cur_h, g)
    }
    Left => {
      let right_start = tx + tw * 0.5
      let r_edge = lerp(right_start, w, drop_t)
      let g = tx - r_edge
      let clear_t = ovl_smoothstep(-4.0, 4.5, g)
      let py_eff = clamp(lerp(py * 0.15, py, clear_t), 0.0, 1.06)
      let raw_mw = lerp(tw, w, px)
      let raw_mh = lerp(th, h, py_eff)
      let cur_w = if raw_mw > 4.0 { raw_mw } else { 4.0 }
      let cur_h = if raw_mh > 4.0 { raw_mh } else { 4.0 }
      let y = match along {
        Start => 0.0
        End => h - cur_h
        Middle => (h - cur_h) * 0.5
      }
      (r_edge - cur_w, y, cur_w, cur_h, g)
    }
  }
  let half_min = (if mw < mh { mw } else { mh }) * 0.5
  let raw_r = lerp(tr, panel_radius, pt)
  let mr = if raw_r < half_min { raw_r } else { half_min }
  ({ dx: mx, dy: my, dw: mw - w, dh: mh - h, corners: Some((mr, mr, mr, mr)) }, gap)
}

///|
/// Attaches the physically gap-driven GPU-merged capillary Liquid Glass Menu Morph to `panel` inside `layer`.
/// `panel` stays unscaled with no `.glass`, `.shadow`, or `.clips`; `content` receives `content_box`.
fn ovl_attach_liquid_morph(
  layer : @view.View,
  panel : @view.View,
  side : @view.Side,
  along : @view.Along,
  panel_radius : Double,
  anchor_size : (Double, Double),
  content : (@view.View) -> Unit,
) -> () -> Bool {
  let sx_way = @motion.NodeWay::new(0.0)
  let sy_way = @motion.NodeWay::new(0.0)
  let p_way = @motion.NodeWay::new(0.0)
  layer.reacts(fn() { layer.leaving() }, fn(leaving) {
    if leaving {
      sx_way.go(layer, 0.0, @motion.snappy_damped)
      sy_way.go(layer, 0.0, @motion.snappy_damped)
      p_way.go(layer, 0.0, @motion.snappy_damped)
    } else {
      sx_way.go(layer, 1.0, @motion.backdrop_scale_x_spring)
      sy_way.go(layer, 1.0, @motion.backdrop_scale_y_spring)
      p_way.go(layer, 1.0, @motion.liquid_toggle_spring)
    }
  })
  let modal_live = fn() { !layer.leaving() }
  let energy_of = fn(sx : Double, sy : Double, p : Double) -> Double {
    clamp((1.0 - clamp(p, 0.0, 1.0)) * 1.2 + (sx - sy).abs() * 2.2, 0.0, 1.0)
  }
  panel.by_room(fn(inner, room) {
    let content_ref : Ref[@view.View?] = Ref(None)
    let panel_h = fn() -> Double {
      match content_ref.val {
        Some(c) => room.tall(c)
        None => 0.0
      }
    }
    let gap_on = fn(node : @view.View) -> Double {
      let (_, g) = ovl_morph_shell_geom(
        room.width(),
        panel_h(),
        side,
        along,
        anchor_size,
        panel_radius,
        sx_way.shown(node),
        sy_way.shown(node),
        p_way.shown(node),
      )
      g
    }
    // 1. Preceding outside-only shadow layer (zero `.glass`, never breaks glass batching)
    inner.box(fn(shadow_box) {
      shadow_box
      .over(Is(true))
      .points(Is(false))
      .radius(Is(panel_radius))
      .shadow_outside(Is(true))
      .shadow(
        By(fn() {
          let ga = ovl_smoothstep(0.0, 0.22, p_way.shown(shadow_box))
          let (s, dy, ink) = shadow_default
          (s, dy, alpha(ink, ga))
        }),
      )
      .ground_drawn(
        By(fn() {
          let (shape, _) = ovl_morph_shell_geom(
            room.width(),
            panel_h(),
            side,
            along,
            anchor_size,
            panel_radius,
            sx_way.shown(shadow_box),
            sy_way.shown(shadow_box),
            p_way.shown(shadow_box),
          )
          shape
        }),
      )
      |> ignore
    })
    |> ignore
    // 2 & 3. Strictly adjacent liquid glass siblings (`trigger_ghost` + `shell`): zero shadow, zero ground,
    //        zero children, identical `alpha`, `blur` & `merge` so Metal / WebGL 2 batches them into one SDF `sd_group`.
    inner.box(fn(trigger_ghost) {
      let tw = anchor_size.0
      let th = anchor_size.1
      let tr = th * 0.5
      trigger_ghost
      .over(Is(true))
      .points(Is(false))
      .width(Is(Some(tw)))
      .height(Is(Some(th)))
      .radius(Is(tr))
      .offset(
        By(fn() {
          let (tx, ty, _, _, _) = ovl_morph_trigger_rect(
            room.width(),
            panel_h(),
            side,
            along,
            anchor_size,
          )
          (tx, ty)
        }),
      )
      .alpha(By(fn() { ovl_smoothstep(0.0, 0.18, p_way.shown(trigger_ghost)) }))
      .glass(
        By(fn() {
          let p = p_way.shown(trigger_ghost)
          let ga = ovl_smoothstep(0.0, 0.18, p)
          let gap = gap_on(trigger_ghost)
          let m = ovl_morph_bridge_merge_for_gap(p, gap)
          if m > 0.01 && ga > 0.01 {
            let sx = sx_way.shown(trigger_ghost)
            let sy = sy_way.shown(trigger_ghost)
            Some(ovl_morph_panel_glass(gap, energy_of(sx, sy, p), merge=m))
          } else {
            None
          }
        }),
      )
      |> ignore
    })
    |> ignore
    inner.box(fn(shell) {
      shell
      .over(Is(true))
      .points(Is(false))
      .radius(Is(panel_radius))
      .alpha(By(fn() { ovl_smoothstep(0.0, 0.18, p_way.shown(shell)) }))
      .glass(
        By(fn() {
          let p = p_way.shown(shell)
          let ga = ovl_smoothstep(0.0, 0.18, p)
          if ga > 0.01 {
            let sx = sx_way.shown(shell)
            let sy = sy_way.shown(shell)
            let gap = gap_on(shell)
            let m = ovl_morph_bridge_merge_for_gap(p, gap)
            Some(ovl_morph_panel_glass(gap, energy_of(sx, sy, p), merge=m))
          } else {
            None
          }
        }),
      )
      .ground_drawn(
        By(fn() {
          let (shape, _) = ovl_morph_shell_geom(
            room.width(),
            panel_h(),
            side,
            along,
            anchor_size,
            panel_radius,
            sx_way.shown(shell),
            sy_way.shown(shell),
            p_way.shown(shell),
          )
          shape
        }),
      )
      |> ignore
    })
    |> ignore
    // 4. Foreground content box: appears only once physical gap >= 5.0pt (zero text overflow on any frame)
    inner.box(fn(content_box) {
      content_ref.val = Some(content_box)
      content_box
      .scale(
        By(fn() { lerp(0.92, 1.0, ovl_smoothstep(5.0, 8.0, gap_on(content_box))) }),
        about=ovl_morph_pivot(side, along),
      )
      .alpha(
        By(fn() {
          let g = gap_on(content_box)
          if layer.leaving() {
            ovl_smoothstep(5.2, 7.6, g)
          } else {
            ovl_smoothstep(5.0, 7.6, g)
          }
        }),
      )
      .offset(
        By(fn() {
          let g = gap_on(content_box)
          let u = 1.0 - ovl_smoothstep(5.0, 7.8, g)
          let d = u * 6.0
          match side {
            Bottom => (0.0, -d)
            Top => (0.0, d)
            Right => (-d, 0.0)
            Left => (d, 0.0)
          }
        }),
      )
      |> ignore
      content(content_box)
    })
    |> ignore
  })
  |> ignore
  modal_live
}
