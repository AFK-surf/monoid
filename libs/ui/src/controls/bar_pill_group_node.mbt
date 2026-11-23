// Single-layer iOS 26 / macOS 26 floating liquid glass pill container for top bar action button groups:
// delegates pill rendering, press feedback, and trigger morph scope to `@glass.liquid_pill_group_node` &
// `@glass.bind_pill_press` / `@glass.bind_pill_press_by`, adding sf-ui's calibrated outside-only
// `glass_control_shadow()`, `MBUI_GLASS=solid` hairline `panel_edge()` fallback, and automatic
// concentric corner scope (`corner_card_node`).

///|
/// Theme-adaptive press overlay ink for controls inside a liquid glass top bar pill: delegates to `@glass.liquid_pill_press_ink(solid~)`.
pub fn bar_pill_press_ink(solid? : Bool = false) -> Int64 {
  @glass.liquid_pill_press_ink(solid~)
}

///|
/// Connects an interactive child control inside `bar_pill_group_node`, `bar_pill_group_with`, or
/// `float_pill_group_node` to its enclosing liquid glass pill's `.glassEffect(.interactive())` response: moves the
/// GPU `spot` specular highlight to the child's center and springs the pill scale via `@motion.backdrop_press_spring`.
/// No-op outside a pill group.
pub fn bind_pill_press(child : @view.View) -> Unit {
  @glass.bind_pill_press(child)
}

///|
/// bind_pill_press with what holds `child` down said by `down` (a press the host takes rather than the app: the
/// window's maximize button held down as the host says, @ui.window_snap_state), sharing the pill's press count with
/// any other press bound to it.
fn bind_pill_press_by(child : @view.View, down : () -> Bool) -> Unit {
  @glass.bind_pill_press_by(child, down)
}

///|
/// Attaches theme-adaptive hover + press highlight and outer liquid glass pill press feedback (`bind_pill_press`)
/// to a custom `action_box_node` inside `bar_pill_group_node` (such as the home workspace switcher capsule).
pub fn bar_pill_key_press_node(v : @view.View) -> Unit {
  hover_ground_node(
    v,
    color=fn() {
      if v.pressed() {
        bar_pill_press_ink(solid=v.glass_solid())
      } else {
        @glass.liquid_pill_hover_ink(solid=v.glass_solid())
      }
    },
  )
  v.focus_ring(Is(Some((-1.5, -1.5, 0L)))) |> ignore
  bind_pill_press(v)
}

///|
/// A single-layer liquid glass pill container in `parent` for a group of top bar controls made by `body`:
/// `height` tall (default `40.0`, full capsule radius `height / 2.0`), padded `pad` all around (default `3.0`,
/// concentric with 34pt `round_key_node` at `height=40.0, pad=3.0` and 32pt `icon_button_node` at `height=36.0, pad=2.0`),
/// children `gap` apart (default `2.0`). Never nest inside another glass surface.
#callsite(autofill(loc))
pub fn bar_pill_group_node(
  parent : @view.View,
  body : (@view.View) -> Unit,
  height? : Double = 40.0,
  pad? : Double = 3.0,
  gap? : Double = 2.0,
  adaptive? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  bar_pill_group_with(loc~, parent, body, height~, pad~, gap~, adaptive~)
}

///|
/// bar_pill_group_node's pill, its glass `tint()` where said (`window_keys_node`), else delegates to neutral `bar_pill_group_node`.
#callsite(autofill(loc))
fn bar_pill_group_with(
  parent : @view.View,
  body : (@view.View) -> Unit,
  height? : Double = 40.0,
  pad? : Double = 3.0,
  gap? : Double = 2.0,
  tint? : (() -> Int64)? = None,
  adaptive? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let r = height / 2.0
  @glass.liquid_pill_group_node(
    loc~,
    parent,
    fn(g) {
      corner_card_node(g, fn() { r }, inset=fn() { pad })
      body(g)
    },
    height~,
    pad~,
    gap~,
    direction=Horizontal,
    solid=panel_ground,
    tint?,
    shadow=glass_control_shadow,
    solid_edge=fn() { (control_edge_w, panel_edge()) },
    adaptive~,
  )
}
