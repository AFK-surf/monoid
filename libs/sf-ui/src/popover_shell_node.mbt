// Unified anchored popover shell and placement-side helper for overlays anchored beside a trigger
// (`menu_node`, `panel_node`, `pick_node`, `hover_panel_node`): single-layer iOS 27 liquid glass (`glass_menu()`),
// automatic solid fallback (`panel_ground()` + 1 pt `panel_edge()`) when `MBUI_GLASS=solid`, outside-only
// `glass_overlay_shadow()` (`shadow_outside(Is(true))` so outer shadows never bleed inside glass), `r_menu` corner
// radius, clipping, `FromBeside` pop motion, and `ground_node` input boundary.

///|
/// Configures `p` as the shared visual shell for an anchored popover beside `anchor_id`:
/// single-layer liquid glass (`glass_menu()`), solid hairline fallback when `p.glass_solid()` is true,
/// outside-only `glass_overlay_shadow()`, `r_menu` corner radius, clipping, `FromBeside` alpha/scale motion from `look`,
/// and `ground_node` press boundary.
/// - `holds_side`: keeps the chosen side while it still fits (default `true`; pass `false` for `menu_node`).
/// - `concentric_inset`: when `>= 0.0`, registers `corner_card_node(p, fn() { r_menu }, inset=fn() { concentric_inset })`.
pub fn anchored_popover_shell(
  p : @view.View,
  anchor_id : @view.NodeId,
  look : () -> @ui.Look,
  side? : @ui.Side = Bottom,
  along? : @ui.Along = Start,
  offset? : Double = panel_offset,
  holds_side? : Bool = true,
  concentric_inset? : Double = -1.0,
) -> @view.View {
  p
  .beside(anchor_id, side~, along=view_along(along), offset~, padding=8.0, holds_side~)
  .radius(Is(r_menu))
  .glass(By(fn() { Some(glass_menu()) }))
  .edge(By(fn() { if p.glass_solid() { (1.0, panel_edge()) } else { (0.0, 0L) } }))
  .shadow(By(fn() { glass_overlay_shadow() }))
  .shadow_outside(Is(true))
  .clips(Is(true))
  .alpha(By(fn() { look().alpha }))
  .scale(By(fn() { look().sx }), about=FromBeside, max_shift=pop_max_shift)
  |> ignore
  if concentric_inset >= 0.0 {
    corner_card_node(p, fn() { r_menu }, inset=fn() { concentric_inset })
  }
  ground_node(p)
}

///|
/// Preferred side (`Top` or `Bottom`) for an anchored popover beside `anchor`: opens upward when space below `anchor`
/// is smaller than `need` and there is more room above than below.
pub fn beside_side_for(anchor : @view.View, need? : Double = 360.0) -> @ui.Side {
  let (_, y, _, h) = anchor.placed_window_now()
  let under = anchor.window_h() - (y + h)
  if under < need && y > under {
    Top
  } else {
    Bottom
  }
}
