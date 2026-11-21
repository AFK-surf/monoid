// Apple iOS 26/27 Liquid Glass Menu Morph with real GPU SDF capillary bridge (`merged_liquid`)
// for anchored floating overlays (`liquid_menu_node`, `liquid_select_node`, `liquid_popover_node`).
//
// Closed-form `@motion.NodeWay` architecture (zero frame loops, 60/120/24/7 fps invariant):
// - `panel` stays unscaled in `(0, 0, w, h)` so `trigger_ghost` locks pixel-for-pixel onto the real
//   trigger button's `(tx, ty, tw, th, tr)` while `shell` stretches smoothly out of `(tx, ty, tw, th, tr)`
//   into `(0, 0, w, h, panel_radius)` via `ground_drawn`.
// - Strict 4-layer draw order guarantees GPU `merged_liquid` SDF batching (`prev == k` with identical
//   `blur` and `merge > 0`, zero intervening shadows/grounds/children):
//   1. `shadow_box` (`shadow_outside(true)`, zero `.glass`)
//   2. `trigger_ghost` (only submits `.glass(Some(...))` while `m > 0.01`; `None` at rest)
//   3. `shell` (immediately adjacent glass sibling; settles bit-exact to `ovl_panel_glass()` & `ground_as_laid`)
//   4. `content_box` (shell-before-text reveal on open, text-first fade on close)

///|
/// Leave duration (ms) passed to `pop.layer(..., leave=ovl_morph_leave_ms)` so the closing capillary
/// re-absorption completes cleanly before unmount.
let ovl_morph_leave_ms : Double = 260.0

///|
/// Peak GPU smooth-min metaball merge radius (pt) between `trigger_ghost` and `shell` during capillary bridging.
let ovl_morph_merge_max : Double = 32.0

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
/// Capillary bridge merge radius (pt) as a function of morph progress `p`:
/// peaks at `ovl_morph_merge_max` across `p in [0.08, 0.70]` (covering emergence & gap bridging),
/// smoothly pinches off to `0.0` across `p in [0.70, 0.92]`, and stays strictly `0.0` at rest (`p >= 0.92`).
fn ovl_morph_bridge_merge(p : Double) -> Double {
  ovl_morph_merge_max * ovl_smoothstep(0.0, 0.08, p) * ovl_smoothstep(0.76, 0.56, p)
}

///|
/// Shared dynamic Liquid Glass recipe for both `trigger_ghost` and `shell`.
/// Both siblings call this with the exact same `p`, guaranteeing identical `blur` for GPU `merged_liquid`
/// batching (`blur=4.0` during bridging so the trigger icon remains crisp, settling to `8.0` at rest),
/// and matching `ovl_panel_glass()` bit-for-bit once `energy <= 0.001 && merge <= 0.001 && p >= 0.82`.
fn ovl_morph_panel_glass(p : Double, energy : Double, merge~ : Double) -> @paint.Glass {
  if energy <= 0.001 && merge <= 0.001 && p >= 0.82 {
    return ovl_panel_glass()
  }
  let d = is_dark()
  let e = clamp(energy, 0.0, 1.0)
  let m = if merge > 0.0 { merge } else { 0.0 }
  let blur = lerp(4.0, 8.0, ovl_smoothstep(0.56, 0.80, p))
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
/// Morphing panel `GroundShape` stretching from trigger rect `(tx, ty, tw, th, tr)` to resting `(0, 0, w, h, panel_radius)`.
fn ovl_morph_shell_shape(
  w : Double,
  h : Double,
  side : @view.Side,
  along : @view.Along,
  anchor_size : (Double, Double),
  panel_radius : Double,
  sx : Double,
  sy : Double,
  p : Double,
) -> @view.GroundShape {
  if (sx - 1.0).abs() < 0.001 && (sy - 1.0).abs() < 0.001 && (p - 1.0).abs() < 0.001 {
    return @view.ground_as_laid
  }
  if w <= 0.0 || h <= 0.0 {
    return @view.ground_as_laid
  }
  let (tx, ty, tw, th, tr) = ovl_morph_trigger_rect(w, h, side, along, anchor_size)
  let px = clamp(sx, 0.0, 1.06)
  let py = clamp(sy, 0.0, 1.06)
  let pt = clamp(p, 0.0, 1.0)
  let raw_mw = lerp(tw, w, px)
  let raw_mh = lerp(th, h, py)
  let mw = if raw_mw > 4.0 { raw_mw } else { 4.0 }
  let mh = if raw_mh > 4.0 { raw_mh } else { 4.0 }
  let mx = match side {
    Right => lerp(tx, 0.0, pt)
    Left => lerp(tx + tw - mw, 0.0, pt)
    _ =>
      match along {
        Start => 0.0
        End => w - mw
        Middle => (w - mw) * 0.5
      }
  }
  let my = match side {
    Bottom => lerp(ty, 0.0, pt)
    Top => lerp(ty + th - mh, 0.0, pt)
    _ =>
      match along {
        Start => 0.0
        End => h - mh
        Middle => (h - mh) * 0.5
      }
  }
  let half_min = (if mw < mh { mw } else { mh }) * 0.5
  let raw_r = lerp(tr, panel_radius, pt)
  let mr = if raw_r < half_min { raw_r } else { half_min }
  { dx: mx, dy: my, dw: mw - w, dh: mh - h, corners: Some((mr, mr, mr, mr)) }
}

///|
/// Attaches the GPU-merged capillary Liquid Glass Menu Morph to an anchored overlay `panel` inside `layer`.
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
    // 1. Preceding outside-only shadow layer (zero `.glass`, never breaks glass batching)
    inner.box(fn(shadow_box) {
      shadow_box
      .over(Is(true))
      .points(Is(false))
      .radius(Is(panel_radius))
      .shadow_outside(Is(true))
      .shadow(
        By(fn() {
          let ga = ovl_smoothstep(0.0, 0.24, p_way.shown(shadow_box))
          let (s, dy, ink) = shadow_default
          (s, dy, alpha(ink, ga))
        }),
      )
      .ground_drawn(
        By(fn() {
          ovl_morph_shell_shape(
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
        }),
      )
      |> ignore
    })
    |> ignore
    // 2 & 3. Strictly adjacent liquid glass siblings (`trigger_ghost` + `shell`): zero shadow, zero ground,
    //        zero children, identical `blur` & `merge` so Metal / WebGL 2 batches them into one SDF `sd_group`.
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
      .alpha(By(fn() { ovl_smoothstep(0.0, 0.20, p_way.shown(trigger_ghost)) }))
      .glass(
        By(fn() {
          let p = p_way.shown(trigger_ghost)
          let ga = ovl_smoothstep(0.0, 0.20, p)
          let m = ovl_morph_bridge_merge(p)
          if m > 4.0 && ga > 0.01 {
            let sx = sx_way.shown(trigger_ghost)
            let sy = sy_way.shown(trigger_ghost)
            Some(ovl_morph_panel_glass(p, energy_of(sx, sy, p), merge=m))
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
      .alpha(By(fn() { ovl_smoothstep(0.0, 0.20, p_way.shown(shell)) }))
      .glass(
        By(fn() {
          let p = p_way.shown(shell)
          let ga = ovl_smoothstep(0.0, 0.20, p)
          if ga > 0.01 {
            let sx = sx_way.shown(shell)
            let sy = sy_way.shown(shell)
            let m = ovl_morph_bridge_merge(p)
            let eff_m = if m > 4.0 { m } else { 0.0 }
            Some(ovl_morph_panel_glass(p, energy_of(sx, sy, p), merge=eff_m))
          } else {
            None
          }
        }),
      )
      .ground_drawn(
        By(fn() {
          ovl_morph_shell_shape(
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
        }),
      )
      |> ignore
    })
    |> ignore
    // 4. Foreground content box: appears only once the glass shell is >=95% open (0 text overflow on any frame)
    inner.box(fn(content_box) {
      content_ref.val = Some(content_box)
      content_box
      .scale(
        By(fn() { lerp(0.92, 1.0, ovl_smoothstep(0.70, 1.0, clamp(p_way.shown(content_box), 0.0, 1.0))) }),
        about=ovl_morph_pivot(side, along),
      )
      .alpha(
        By(fn() {
          let p = p_way.shown(content_box)
          if layer.leaving() {
            ovl_smoothstep(0.62, 0.90, p)
          } else {
            ovl_smoothstep(0.70, 0.94, p)
          }
        }),
      )
      .offset(
        By(fn() {
          let p = p_way.shown(content_box)
          let u = 1.0 - ovl_smoothstep(0.70, 0.96, p)
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
