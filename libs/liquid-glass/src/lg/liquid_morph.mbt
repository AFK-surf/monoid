// Apple iOS 26/27 Liquid Glass Menu Morph for anchored floating overlays (`liquid_menu_node`,
// `liquid_select_node`, `liquid_popover_node`).
//
// Closed-form `@motion.NodeWay` architecture (zero frame loops, 60/120/24/7 fps invariant):
// - Three spring ways (`backdrop_scale_x_spring`, `backdrop_scale_y_spring`, `liquid_auto_fuse_spring`
//   on enter; `snappy_damped` on exit) drive an organic liquid-droplet emergence directly from the
//   trigger's `(side, along)` anchor pivot (`At(ox, oy)`).
// - Single clean `shell` liquid glass surface (`merge == 0.0`, zero extra glass instances at any frame)
//   with anisotropic jelly squash, dynamic droplet-to-panel corner radius (`36pt -> panel_radius`), and
//   mid-flight optical refraction / bezel / chroma / rim burst that settles bit-exact to `ovl_panel_glass()`.
// - Content fades in after the glass shell forms (invisible at <= 0.5 scale) and fades out first on close.

///|
/// Leave duration (ms) passed to `pop.layer(..., leave=ovl_morph_leave_ms)` so the closing liquid
/// contraction completes cleanly before unmount.
let ovl_morph_leave_ms : Double = 240.0

///|
/// Travel distance (pt) along the placement axis from the trigger edge into the resting panel slot.
let ovl_morph_travel : Double = 22.0

///|
/// Initial scale ratio from the trigger-aligned pivot (`At(ox, oy)`) as the droplet blooms to `1.0`.
let ovl_morph_scale_from : Double = 0.30

///|
/// Initial rounded droplet corner radius (pt) that morphs smoothly into `panel_radius` (e.g. 22pt).
let ovl_morph_droplet_r : Double = 36.0

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
/// Exact scale pivot `(ox, oy)` aligned to the trigger's `(side, along)` anchor so the liquid droplet
/// emerges directly out of the trigger button rather than the midpoint of the menu.
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
/// Dynamic Liquid Glass recipe during menu morph: boosts refraction, bezel depth, rim highlight and subtle
/// chromatic edge dispersion proportional to morph `energy`, while matching `ovl_panel_glass()` bit-for-bit
/// once `energy <= 0.001`.
fn ovl_morph_panel_glass(energy : Double) -> @paint.Glass {
  if energy <= 0.001 {
    return ovl_panel_glass()
  }
  let d = is_dark()
  let e = clamp(energy, 0.0, 1.0)
  @paint.Glass::liquid(
    blur=8.0,
    tint=if d { 0x202020FFL } else { 0xFDFCFD67L },
    solid=if d { 0x1C1C1EFFL } else { 0xF7F7FAFFL },
    saturation=1.0,
    rim=0.6 + 0.5 * e,
    bezel=20.0 + 14.0 * e,
    refraction=36.0 + 32.0 * e,
    chroma=-0.06 * e,
    merge=0.0,
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
/// Attaches the full Liquid Glass Menu Morph to an anchored overlay `panel` mounted inside `layer`.
/// `panel` must not set `.glass(...)`, `.shadow(...)`, or `.clips(...)` itself; `content` receives the inner
/// `content_box` where padding, gap and rows/body are built. Returns `modal_live = fn() { !layer.leaving() }`.
fn ovl_attach_liquid_morph(
  layer : @view.View,
  panel : @view.View,
  side : @view.Side,
  along : @view.Along,
  panel_radius : Double,
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
      p_way.go(layer, 1.0, @motion.liquid_auto_fuse_spring)
    }
  })
  let modal_live = fn() { !layer.leaving() }
  let energy_of = fn(sx : Double, sy : Double, p : Double) -> Double {
    clamp((1.0 - clamp(p, 0.0, 1.0)) * 1.2 + (sx - sy).abs() * 2.2, 0.0, 1.0)
  }
  panel
  .scale(
    By(fn() {
      let s = 0.5 * (sx_way.shown(panel) + sy_way.shown(panel))
      lerp(ovl_morph_scale_from, 1.0, clamp(s, 0.0, 1.08))
    }),
    about=ovl_morph_pivot(side, along),
  )
  .offset(
    By(fn() {
      let p = clamp(p_way.shown(panel), 0.0, 1.0)
      let d = (1.0 - p) * ovl_morph_travel
      match side {
        Bottom => (0.0, -d)
        Top => (0.0, d)
        Right => (-d, 0.0)
        Left => (d, 0.0)
      }
    }),
  )
  |> ignore
  panel.by_room(fn(inner, room) {
    // 1. Underlying single-layer liquid glass shell (anisotropic jelly squash + dynamic droplet corner radius)
    inner.box(fn(backdrop) {
      backdrop.over(Is(true)).points(Is(false)) |> ignore
      backdrop.box(fn(shell) {
        shell
        .over(Is(true))
        .points(Is(false))
        .radius(Is(panel_radius))
        .alpha(By(fn() { ovl_smoothstep(0.0, 0.24, p_way.shown(shell)) }))
        .shadow(
          By(fn() {
            let ga = ovl_smoothstep(0.0, 0.24, p_way.shown(shell))
            let (s, dy, ink) = shadow_default
            (s, dy, alpha(ink, ga))
          }),
        )
        .glass(
          By(fn() {
            let p = p_way.shown(shell)
            let ga = ovl_smoothstep(0.0, 0.24, p)
            if ga > 0.01 {
              let sx = sx_way.shown(shell)
              let sy = sy_way.shown(shell)
              Some(ovl_morph_panel_glass(energy_of(sx, sy, p)))
            } else {
              None
            }
          }),
        )
        .ground_drawn(
          By(fn() {
            let sx = sx_way.shown(shell)
            let sy = sy_way.shown(shell)
            let p = p_way.shown(shell)
            if (sx - 1.0).abs() < 0.001 && (sy - 1.0).abs() < 0.001 && (p - 1.0).abs() < 0.001 {
              return @view.ground_as_laid
            }
            let w = room.width()
            let h = room.tall(shell)
            if w <= 0.0 || h <= 0.0 {
              return @view.ground_as_laid
            }
            let squash = clamp(sx - sy, -0.25, 0.25) * 0.22
            let dw = w * squash
            let dh = -h * squash * 0.65
            let nw = if w + dw > 4.0 { w + dw } else { 4.0 }
            let nh = if h + dh > 4.0 { h + dh } else { 4.0 }
            let half_min = (if nw < nh { nw } else { nh }) * 0.5
            let raw_r = lerp(ovl_morph_droplet_r, panel_radius, clamp(p, 0.0, 1.0))
            let r = if raw_r < half_min { raw_r } else { half_min }
            let dx = match (side, along) {
              (Right, _) => 0.0
              (Left, _) => -dw
              (_, Start) => 0.0
              (_, End) => -dw
              (_, Middle) => -dw * 0.5
            }
            let dy = match (side, along) {
              (Bottom, _) => 0.0
              (Top, _) => -dh
              (_, Start) => 0.0
              (_, End) => -dh
              (_, Middle) => -dh * 0.5
            }
            { dx, dy, dw, dh, corners: Some((r, r, r, r)) }
          }),
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 2. Foreground content box: appears after the glass shell forms (invisible at <= 0.5 scale)
    inner.box(fn(content_box) {
      content_box
      .alpha(
        By(fn() {
          let p = p_way.shown(content_box)
          if layer.leaving() {
            ovl_smoothstep(0.45, 0.86, p)
          } else {
            ovl_smoothstep(0.34, 0.80, p)
          }
        }),
      )
      .offset(
        By(fn() {
          let p = p_way.shown(content_box)
          let u = 1.0 - ovl_smoothstep(0.24, 0.82, p)
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
