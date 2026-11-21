// Single-layer iOS 26 / macOS 26 floating liquid glass pill container for top bar action button groups:
// uses `glass_menu()` (high-density frosted liquid glass for >= 4.5:1 legibility over scrolled content),
// outside-only `float_shadow()` (`shadow_outside(Is(true))` so shadows never bleed inside glass),
// `MBUI_GLASS=solid` hairline `panel_edge()` fallback, and automatic concentric corner scope (`corner_card_node`).

///|
/// A single-layer liquid glass pill container in `parent` for a group of top bar controls made by `body`:
/// `height` tall (default `40.0`, full capsule radius `height / 2.0`), padded `pad` all around (default `3.0`,
/// concentric with 34pt `round_key_node` at `height=40.0` and 32pt `icon_button_node` at `height=38.0`),
/// children `gap` apart (default `2.0`). Never nest inside another glass surface.
#callsite(autofill(loc))
pub fn bar_pill_group_node(
  parent : @view.View,
  body : (@view.View) -> Unit,
  height? : Double = 40.0,
  pad? : Double = 3.0,
  gap? : Double = 2.0,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(g) {
    let r = height / 2.0
    g
    .row(Is(true))
    .height(Is(Some(height)))
    .radius(Is(r))
    .padding(Is((pad, pad, pad, pad)))
    .gap(Is(gap))
    .lines_up(Is(Some(Middle)))
    .shrink(Is(0.0))
    .glass(By(fn() { Some(glass_menu()) }))
    .edge(By(fn() { if g.glass_solid() { (control_edge_w, panel_edge()) } else { (0.0, 0L) } }))
    .shadow(By(fn() { float_shadow() }))
    .shadow_outside(Is(true))
    .clips(Is(true))
    |> ignore
    corner_card_node(g, fn() { r }, inset=fn() { pad })
    body(g)
  })
}
