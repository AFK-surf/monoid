// Generic single-layer Liquid Glass panel / menu / candidate / find-bar surface decorator and shell.
// Enforces zero hidden glass instances when `active()` is false, `shadow_outside(Is(true))`,
// optional smooth-min capillary `merge`, and `MBUI_GLASS=solid` hairline fallback.

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
