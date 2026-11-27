// Single-layer Liquid Glass surface decorators and shells for panels, popovers, tooltips,
// side drawers, bottom sheets, dialogs, and toasts.
// Enforces zero hidden glass instances when `active()` is false, `shadow_outside(Is(true))`,
// and `MBUI_GLASS=solid` 1pt hairline fallback.

///|
/// Decorates an existing panel container node `v` in place (zero wrapper nodes) with single-layer
/// `liquid_panel_glass`, optional capillary `merge`, `active` gating (submits `None` glass, zero edge,
/// and zero shadow when inactive), `shadow_outside(Is(true))`, `MBUI_GLASS=solid` hairline fallback,
/// and optional `radius` / `clips`. Returns `v` for chaining.
pub fn liquid_panel_surface_decorate(
  v : @view.View,
  radius? : Double,
  solid? : () -> Int64,
  merge? : () -> Double,
  active? : () -> Bool = fn() { true },
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
  clips? : Bool = true,
) -> @view.View {
  match radius {
    Some(r) => v.radius(Is(r)) |> ignore
    None => ()
  }
  if clips {
    v.clips(Is(true)) |> ignore
  }
  v
  .glass(
    By(fn() {
      if !active() {
        return None
      }
      let s = match solid {
        Some(f) => f()
        None => clear
      }
      let g = liquid_panel_glass(solid=s)
      match merge {
        Some(mf) => {
          let m = mf()
          if m > 0.0 {
            Some({ ..g, merge: m })
          } else {
            Some(g)
          }
        }
        None => Some(g)
      }
    }),
  )
  .edge(
    By(fn() {
      if active() && v.glass_solid() {
        solid_edge()
      } else {
        (0.0, clear)
      }
    }),
  )
  .shadow(
    By(fn() {
      if active() {
        shadow()
      } else {
        shadow_none
      }
    }),
  )
  .shadow_outside(Is(true))
}

///|
/// Composable single-layer Liquid Glass panel shell (`r=22pt` by default) wrapping `body` with
/// `liquid_panel_surface_decorate`. Suitable for floating panels, menus, candidate lists, and find bars.
#callsite(autofill(loc))
pub fn liquid_panel_shell_node(
  parent : @view.View,
  body : (@view.View) -> Unit,
  radius? : Double = ovl_popover_radius,
  solid? : () -> Int64,
  merge? : () -> Double,
  active? : () -> Bool = fn() { true },
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
  clips? : Bool = true,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(v) {
    liquid_panel_surface_decorate(v, radius~, solid?, merge?, active~, shadow~, solid_edge~, clips~) |> ignore
    body(v)
  })
}

///|
/// Helper forwarding `alpha` so `liquid_popover_surface_decorate` can accept an `alpha?` parameter without shadowing.
fn popover_fade_ink(c : Int64, share : Double) -> Int64 {
  alpha(c, share)
}

///|
/// Decorates an existing anchored popover container node `p` in place (zero wrapper nodes) in either:
/// 1. Standard anchored overlay mode (when `morph` is `None`):
///    binds `liquid_panel_glass(solid=...)`, `shadow`, `shadow_outside(Is(true))`, `MBUI_GLASS=solid` hairline
///    fallback, and optional `alpha` / `scale`.
/// 2. iOS 27.0 liquid-bridge morph mode (when `morph` is `Some(eval)`, whatever the window's glass material: solid glass
///    morphs as its solid ground):
///    encapsulates three-anchor `liquid_menu_morph_glass` optical interpolation, capillary `merge`/`layer`/`break_gap`,
///    `content_lens` blur/refraction, `ground_drawn` animated silhouette, `alpha` gating (zero hidden glass when
///    inactive), and smooth shadow ramp. Returns `p` for chaining.
pub fn liquid_popover_surface_decorate(
  p : @view.View,
  radius? : Double,
  solid? : () -> Int64,
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
  clips? : Bool = true,
  alpha? : () -> Double,
  scale? : () -> Double,
  scale_about? : @view.Pivot = FromBeside,
  max_shift? : Double = 0.0,
  morph? : () -> (Double, Bool, Double, Double, LiquidMorphFrame)?,
  layer? : Int = 0,
  break_gap? : Double = 32.0,
  close_break_gap? : Double = 48.0,
) -> @view.View {
  let resolve_solid = fn() -> Int64 {
    match solid {
      Some(f) => f()
      None => clear
    }
  }
  match radius {
    Some(r) => p.radius(Is(r)) |> ignore
    None => ()
  }
  if clips {
    p.clips(Is(true)) |> ignore
  }
  p
  .edge(By(fn() { if p.glass_solid() { solid_edge() } else { (0.0, clear) } }))
  .shadow_outside(Is(true))
  |> ignore
  match morph {
    Some(eval_morph) => {
      let unlaid_opening = fn(t : Double, closing : Bool, w : Double, h : Double) {
        !closing && t < lm_open_duration_ms / 1000.0 - 0.001 && (w <= 0.0 || h <= 0.0)
      }
      p
      .alpha(
        By(fn() {
          match eval_morph() {
            Some((t, closing, w, h, f)) =>
              if unlaid_opening(t, closing, w, h) {
                0.0
              } else if !closing {
                if f.raw_value <= 0.001 { 0.0 } else { 1.0 }
              } else if !f.platter_active {
                0.0
              } else {
                1.0
              }
            None =>
              match alpha {
                Some(af) => af()
                None => 1.0
              }
          }
        }),
      )
      .glass(
        By(fn() {
          let s = resolve_solid()
          match eval_morph() {
            Some((t, closing, w, h, f)) =>
              if unlaid_opening(t, closing, w, h) {
                None
              } else if !closing {
                if f.raw_value <= 0.001 {
                  None
                } else {
                  let stage = 0.5 + 0.5 * lm_smoothstep(0.08, 0.20, t)
                  if f.open_anchor_scale > 0.15 {
                    Some(
                      liquid_menu_morph_glass(
                        stage,
                        solid=s,
                        merge=14.0 * f.open_anchor_scale,
                        layer~,
                        break_gap~,
                      ),
                    )
                  } else {
                    Some(liquid_menu_morph_glass(stage, solid=s))
                  }
                }
              } else if !f.platter_active {
                None
              } else {
                let stage = 0.5 * lm_smoothstep(0.0, 0.12, f.raw_value) +
                  0.5 * lm_smoothstep(0.35, 0.95, f.raw_value)
                if f.blob_a_emerge > 0.001 {
                  Some(
                    liquid_menu_morph_glass(
                      stage,
                      solid=s,
                      merge=lm_close_blend(f.raw_value),
                      layer~,
                      break_gap=close_break_gap,
                    ),
                  )
                } else {
                  Some(liquid_menu_morph_glass(stage, solid=s))
                }
              }
            None => Some(liquid_panel_glass(solid=s))
          }
        }),
      )
      .content_lens(
        By(fn() {
          match eval_morph() {
            Some((t, closing, w, h, f)) =>
              if unlaid_opening(t, closing, w, h) {
                @paint.ContentLens::none()
              } else if f.content_opacity > 0.01 && f.content_blur > 0.05 {
                {
                  blur: f.content_blur,
                  refraction: 6.0 * clamp(f.content_blur / 8.0, 0.0, 1.0),
                  bezel: 24.0,
                  alpha: f.content_opacity,
                }
              } else {
                @paint.ContentLens::none()
              }
            None => @paint.ContentLens::none()
          }
        }),
      )
      .shadow(
        By(fn() {
          match eval_morph() {
            Some((t, closing, w, h, f)) =>
              if unlaid_opening(t, closing, w, h) {
                shadow_none
              } else if closing && !f.platter_active {
                shadow_none
              } else {
                let ga = lm_smoothstep(0.25, 0.78, clamp(f.raw_value, 0.0, 1.0))
                if ga <= 0.001 {
                  shadow_none
                } else {
                  let (s, dy, ink) = shadow()
                  (s, dy, popover_fade_ink(ink, ga))
                }
              }
            None => shadow()
          }
        }),
      )
      .ground_drawn(
        By(fn() {
          match eval_morph() {
            Some((t, closing, w, h, f)) =>
              if w <= 0.0 || h <= 0.0 || (!closing && t >= lm_open_duration_ms / 1000.0 - 0.001) {
                @view.ground_as_laid
              } else {
                let r = f.radius
                { dx: f.mx, dy: f.my, dw: f.cur_w - w, dh: f.cur_h - h, corners: Some((r, r, r, r)) }
              }
            None => @view.ground_as_laid
          }
        }),
      )
    }
    _ => {
      p.glass(By(fn() { Some(liquid_panel_glass(solid=resolve_solid())) })).shadow(By(shadow)) |> ignore
      match alpha {
        Some(af) => p.alpha(By(af)) |> ignore
        None => ()
      }
      match scale {
        Some(sf) => p.scale(By(sf), about=scale_about, max_shift~) |> ignore
        None => ()
      }
      p
    }
  }
}

///|
/// Decorates an existing tooltip node `v` in place (zero wrapper nodes) with `points(Is(false))` click-through,
/// `active` gating (submits `None` glass, zero edge, and zero shadow when inactive), `shadow_outside(Is(true))`,
/// `MBUI_GLASS=solid` hairline fallback, and single-layer liquid glass (`liquid_capsule_glass` by default, or
/// `liquid_panel_glass` when `panel=true`). Returns `v` for chaining.
pub fn liquid_tooltip_surface_decorate(
  v : @view.View,
  radius? : Double,
  active? : () -> Bool = fn() { true },
  solid? : () -> Int64,
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
  panel? : Bool = false,
) -> @view.View {
  match radius {
    Some(r) => v.radius(Is(r)) |> ignore
    None => ()
  }
  v
  .points(Is(false))
  .glass(
    By(fn() {
      if !active() {
        return None
      }
      let s = match solid {
        Some(f) => f()
        None => clear
      }
      if panel {
        Some(liquid_panel_glass(solid=s))
      } else {
        Some(liquid_capsule_glass(solid=s))
      }
    }),
  )
  .edge(
    By(fn() {
      if active() && v.glass_solid() {
        solid_edge()
      } else {
        (0.0, clear)
      }
    }),
  )
  .shadow(
    By(fn() {
      if active() {
        shadow()
      } else {
        shadow_none
      }
    }),
  )
  .shadow_outside(Is(true))
}

///|
/// Decorates an existing side-drawer container node `v` in place (zero wrapper nodes) with single-layer
/// `liquid_drawer_glass`, `active` gating (zero hidden glass when inactive), `shadow_outside(Is(true))`,
/// `MBUI_GLASS=solid` hairline fallback, and optional `radius` / `clips`. Returns `v` for chaining.
pub fn liquid_drawer_surface_decorate(
  v : @view.View,
  radius? : Double,
  active? : () -> Bool = fn() { true },
  strength? : () -> Double,
  solid? : () -> Int64,
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
  clips? : Bool = true,
) -> @view.View {
  match radius {
    Some(r) => v.radius(Is(r)) |> ignore
    None => ()
  }
  if clips {
    v.clips(Is(true)) |> ignore
  }
  let level = match strength {
    Some(f) => fn() { if active() { clamp(f(), 0.0, 1.0) } else { 0.0 } }
    None => fn() { if active() { 1.0 } else { 0.0 } }
  }
  v
  .glass(
    By(fn() {
      let k = level()
      if k <= 0.001 {
        return None
      }
      let s = match solid {
        Some(f) => f()
        None => clear
      }
      let base = liquid_drawer_glass(solid=s)
      Some(if k >= 0.999 { base } else { base.at_strength(k) })
    }),
  )
  .edge(
    By(fn() {
      let k = level()
      if k > 0.001 && v.glass_solid() {
        let (w, c) = solid_edge()
        (w, if k >= 0.999 { c } else { alpha(c, k) })
      } else {
        (0.0, clear)
      }
    }),
  )
  .shadow(
    By(fn() {
      let k = level()
      if k <= 0.001 {
        shadow_none
      } else if k >= 0.999 {
        shadow()
      } else {
        let (sigma, dy, color) = shadow()
        (sigma * k, dy * k, alpha(color, k))
      }
    }),
  )
  .shadow_outside(Is(true))
}

///|
/// Decorates an existing bottom-sheet glass layer node `g` in place (zero wrapper nodes) with single-layer
/// `liquid_sheet_glass`, `active` gating (returns `None` glass, zero edge, and zero shadow when vanished/inactive),
/// dynamic `solid` fallback (e.g. scrim-composited solid under `MBUI_GLASS=solid`), `shadow_outside(Is(true))`,
/// `MBUI_GLASS=solid` hairline fallback, and optional `radius`. Returns `g` for chaining.
pub fn liquid_sheet_surface_decorate(
  g : @view.View,
  radius? : Double,
  active? : () -> Bool = fn() { true },
  solid? : () -> Int64,
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
) -> @view.View {
  match radius {
    Some(r) => g.radius(Is(r)) |> ignore
    None => ()
  }
  g
  .glass(
    By(fn() {
      if !active() {
        return None
      }
      let s = match solid {
        Some(f) => f()
        None => clear
      }
      Some(liquid_sheet_glass(solid=s))
    }),
  )
  .edge(
    By(fn() {
      if active() && g.glass_solid() {
        solid_edge()
      } else {
        (0.0, clear)
      }
    }),
  )
  .shadow(
    By(fn() {
      if active() {
        shadow()
      } else {
        shadow_none
      }
    }),
  )
  .shadow_outside(Is(true))
}

///|
/// Decorates an existing dialog container node `shell` in place (zero wrapper nodes) with symmetric dense
/// `liquid_dialog_glass`, an optional light-mode tint override (`tint_light`: kept for callers outside; the library's
/// dialogs take the unified 50% recipe as it is), `shadow_outside(Is(true))`, `MBUI_GLASS=solid` 1pt hairline
/// fallback, and optional `radius` / `clips`. Returns `shell` for chaining.
pub fn liquid_dialog_surface_decorate(
  shell : @view.View,
  radius? : Double,
  solid? : () -> Int64,
  tint_light? : Int64,
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
  clips? : Bool = true,
) -> @view.View {
  match radius {
    Some(r) => shell.radius(Is(r)) |> ignore
    None => ()
  }
  if clips {
    shell.clips(Is(true)) |> ignore
  }
  shell
  .glass(
    By(fn() {
      let s = match solid {
        Some(f) => f()
        None => clear
      }
      let g = liquid_dialog_glass(solid=s)
      match tint_light {
        Some(tl) if !is_dark() => Some({ ..g, tint: tl })
        _ => Some(g)
      }
    }),
  )
  .edge(By(fn() { if shell.glass_solid() { solid_edge() } else { (0.0, clear) } }))
  .shadow(By(shadow))
  .shadow_outside(Is(true))
}

///|
/// Decorates an existing toast capsule node `v` in place (zero wrapper nodes) with single-layer
/// `liquid_toast_glass`, `active` gating (zero hidden glass when inactive), `shadow_outside(Is(true))`,
/// `MBUI_GLASS=solid` hairline fallback, and optional `radius`. Returns `v` for chaining.
pub fn liquid_toast_surface_decorate(
  v : @view.View,
  radius? : Double,
  active? : () -> Bool = fn() { true },
  solid? : () -> Int64,
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
) -> @view.View {
  match radius {
    Some(r) => v.radius(Is(r)) |> ignore
    None => ()
  }
  v
  .glass(
    By(fn() {
      if !active() {
        return None
      }
      let s = match solid {
        Some(f) => f()
        None => clear
      }
      Some(liquid_toast_glass(solid=s))
    }),
  )
  .edge(
    By(fn() {
      if active() && v.glass_solid() {
        solid_edge()
      } else {
        (0.0, clear)
      }
    }),
  )
  .shadow(
    By(fn() {
      if active() {
        shadow()
      } else {
        shadow_none
      }
    }),
  )
  .shadow_outside(Is(true))
}

///|
/// Decorates an existing bottom tab bar glass node `v` in place (zero wrapper nodes, one glass binding) with
/// `liquid_tab_bar_glass`. `glass_spec` is read once per evaluation, inside the binding, and answers the press
/// `spot` and capillary `merge` (it reads whatever clocks it needs, in its own order). With `share_when_unmerged`,
/// glass that does not merge is drawn `sharing()` (one backdrop with its neighbours). Returns `v` for chaining.
pub fn liquid_tab_bar_surface_decorate(
  v : @view.View,
  glass_spec : () -> ((Double, Double)?, Double),
  share_when_unmerged? : Bool = false,
) -> @view.View {
  v.glass(
    By(fn() {
      let (spot, merge) = glass_spec()
      let g = liquid_tab_bar_glass(spot~, merge~, adaptive=true)
      Some(if share_when_unmerged && !(merge > 0.0) { g.sharing() } else { g })
    }),
  )
}

///|
/// Decorates an existing tab bar / segmented control lens node `v` in place (zero wrapper nodes) with the clear
/// lifted `liquid_tab_lens_glass` as far as `press()` holds it, its `solid` ground where glass is drawn solid, and,
/// given `shadow` (sigma, dy, ink), that shadow drawn outside only. Returns `v` for chaining.
pub fn liquid_tab_lens_surface_decorate(
  v : @view.View,
  press : () -> Double,
  solid? : () -> Int64,
  shadow? : (Double, Double, Int64),
) -> @view.View {
  v.glass(
    By(fn() {
      let p = press()
      let s = match solid {
        Some(f) => f()
        None => clear
      }
      Some(liquid_tab_lens_glass(p, solid=s))
    }),
  )
  |> ignore
  match shadow {
    Some(s) => v.shadow(Is(s)).shadow_outside(Is(true))
    None => v
  }
}
