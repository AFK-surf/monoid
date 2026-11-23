// Unified single-layer iOS 27 Liquid Glass floating capsule decorator for 30pt/32pt floating pills and overlays:
// delegates glass material to `@glass.liquid_floating_glass` (or `@glass.liquid_viewer_dark_glass` when `dark=true`),
// pairs with `glass_control_shadow()` + `shadow_outside(Is(true))`, `MBUI_GLASS=solid` hairline border fallback,
// and optional press-point GPU `spot` specular highlight (`interactive=true`).

///|
/// Decorates `b` as a single-layer iOS 27 floating liquid glass capsule and returns `b`.
/// Never nest inside another `Glass::liquid` surface.
pub fn glass_capsule_node(
  b : @view.View,
  min_height? : Double? = None,
  radius? : Double? = None,
  sharing? : Bool = true,
  interactive? : Bool = false,
  dark? : Bool = false,
  panel? : Bool = false,
  solid? : () -> Int64,
  tint? : () -> Int64,
  active? : () -> Bool,
) -> @view.View {
  @glass.liquid_capsule_decorate(
    b,
    tone=if dark { ViewerDark } else if panel { Panel } else { Floating },
    min_height~,
    radius~,
    sharing~,
    interactive~,
    active?,
    solid=match solid {
      Some(f) => f
      None => fn() { if dark { 0x161618FFL } else { panel_ground() } }
    },
    tint=match tint {
      Some(f) => fn() { Some(f()) }
      None => fn() { None }
    },
    shadow=glass_control_shadow,
    solid_edge=fn() { (control_edge_w, if dark { 0xFFFFFF26L } else { theme().p.line }) },
  )
}
