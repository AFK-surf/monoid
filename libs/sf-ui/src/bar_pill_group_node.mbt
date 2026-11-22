// Single-layer iOS 26 / macOS 26 floating liquid glass pill container for top bar action button groups:
// uses `glass_bar_pill(spot~)` (40% translucent iOS 27 optical liquid glass matching `glass_tab_bar()`),
// tight outside-only `glass_control_shadow()` (`shadow_outside(Is(true))` so shadows stay crisp and never bleed inside glass or onto adjacent pills),
// native `.glassEffect(.interactive())` press response (`spot` specular highlight + `@motion.backdrop_press_spring` bounce),
// `MBUI_GLASS=solid` hairline `panel_edge()` fallback, and automatic concentric corner scope (`corner_card_node`).

///|
/// Translucent liquid glass for floating top bar action pills (`36–40pt` tall): matches `glass_tab_bar()`'s
/// iOS 27 40% tint (`0x20202067L` / `0xFDFCFD67L`) with bevel/refraction tuned for top bar capsules and
/// live `spot` specular highlight on press.
fn glass_bar_pill(spot? : (Double, Double)? = None) -> @ui.Glass {
  let t = theme()
  let tint = if t.dark { 0x20202067L } else { 0xFDFCFD67L }
  @ui.Glass::liquid(
    blur=2.5,
    tint~,
    solid=panel_ground(),
    saturation=1.0,
    rim=0.6,
    bezel=14.0,
    refraction=20.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
    spot~,
  ).sharing()
}

///|
/// Shared press-feedback scope lent by `bar_pill_group_node` to its interactive children (`round_key_node`,
/// `icon_button_node`, and custom pill actions via `bind_pill_press` / `bar_pill_key_press_node`).
priv struct PillPressScope {
  pill : @view.View
  spot : @signals.Signal[(Double, Double)?]
  press_way : @motion.NodeWay
  mut count : Int
}

///|
let pill_press_lent : @view.Lent[PillPressScope] = @view.Lent::new()

///|
/// Theme-adaptive press overlay ink for controls inside a liquid glass top bar pill: bright white glow in Dark
/// mode and soft dark veil in Light mode so touch and mouse presses stay clearly visible over translucent glass.
pub fn bar_pill_press_ink() -> Int64 {
  alpha(theme().p.text, if theme().dark { 0.22 } else { 0.12 })
}

///|
/// Connects an interactive child control inside `bar_pill_group_node` to its enclosing liquid glass pill's
/// `.glassEffect(.interactive())` response: moves the GPU `spot` specular highlight to the child's center and
/// springs the pill scale via `@motion.backdrop_press_spring`. No-op outside a `bar_pill_group_node`.
pub fn bind_pill_press(child : @view.View) -> Unit {
  guard child.lent(pill_press_lent) is Some(scope) else { return }
  let active = Ref(false)
  let release = fn() {
    if active.val {
      active.val = false
      scope.count = if scope.count > 0 { scope.count - 1 } else { 0 }
      if scope.count == 0 {
        scope.spot.set(None)
        scope.press_way.go(scope.pill, 0.0, @motion.backdrop_press_spring)
      }
    }
  }
  child.reacts(fn() { child.pressed() }, fn(down) {
    if down {
      if !active.val {
        active.val = true
        scope.count += 1
      }
      if !scope.pill.glass_solid() {
        let (gx, gy, _, _) = scope.pill.placed_window_now()
        let (cx, cy, cw, ch) = child.placed_window_now()
        scope.spot.set(Some((cx - gx + cw / 2.0, cy - gy + ch / 2.0)))
      }
      if !@ui.reduced_motion() {
        scope.press_way.go(scope.pill, 1.0, @motion.backdrop_press_spring)
      }
    } else {
      release()
    }
  })
  child.owns(release) |> ignore
}

///|
/// Attaches theme-adaptive hover + press highlight and outer liquid glass pill press feedback (`bind_pill_press`)
/// to a custom `action_box_node` inside `bar_pill_group_node` (such as the home workspace switcher capsule).
pub fn bar_pill_key_press_node(v : @view.View) -> Unit {
  hover_ground_node(
    v,
    color=fn() {
      if v.pressed() {
        bar_pill_press_ink()
      } else {
        @ui.tree_theme().color(Hover)
      }
    },
  )
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
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(g) {
    let r = height / 2.0
    let spot_sig : @signals.Signal[(Double, Double)?] = @signals.signal(None)
    let press_way = @motion.NodeWay::new(0.0)
    let scope : PillPressScope = { pill: g, spot: spot_sig, press_way, count: 0 }
    g
    .row(Is(true))
    .height(Is(Some(height)))
    .radius(Is(r))
    .padding(Is((pad, pad, pad, pad)))
    .gap(Is(gap))
    .lines_up(Is(Some(Middle)))
    .shrink(Is(0.0))
    .glass(By(fn() { Some(glass_bar_pill(spot=spot_sig.get())) }))
    .scale(By(fn() { 1.0 + 0.05 * press_way.shown(g) }), about=At(0.5, 0.5))
    .edge(By(fn() { if g.glass_solid() { (control_edge_w, panel_edge()) } else { (0.0, 0L) } }))
    .shadow(By(fn() { glass_control_shadow() }))
    .shadow_outside(Is(true))
    .clips(Is(true))
    .lends(pill_press_lent, scope)
    |> ignore
    corner_card_node(g, fn() { r }, inset=fn() { pad })
    body(g)
  })
}
