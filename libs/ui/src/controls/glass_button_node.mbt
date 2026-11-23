// Production iOS 26/27 Liquid Glass capsule button (`glass_button_node`):
// - `prominent=false` (`.glass`): Floating neutral liquid glass with `theme().p.text` ink and hairline `MBUI_GLASS=solid` fallback.
// - `prominent=true` (`.glassProminent`): Vivid 85% accent tinted liquid glass with bevel refraction, specular rim,
//   micro chromatic dispersion (`chroma=0.06`), high-contrast pure white ink (`0xFFFFFFFFL`), and solid accent fallback.
// - Interactive press drives `InteractiveHighlight` touch-tracked GPU `spot` + elastic spring scale with luminous white
//   highlight on real glass (zero grey veil), `refused_shake` when disabled, and `focus_ring_theme()` for keyboard focus.

///|
let glass_button_height : Double = 36.0

///|
let glass_button_padx : Double = 16.0

///|
let glass_button_gap : Double = 6.0

///|
/// Ensures a `.glassProminent` accent fill achieves WCAG AA (`>= 4.6:1`) contrast against pure white
/// `0xFFFFFFFFL` ink both in solid fallback and when composited at 85% alpha over `theme().p.card`.
fn prominent_accent_fill(accent : Int64) -> Int64 {
  let card = theme().p.card
  let ok = fn(c : Int64) -> Bool {
    @ui.contrast_ratio(0xFFFFFFFFL, c) >= 4.6 &&
    @ui.contrast_ratio(0xFFFFFFFFL, over(card, alpha(c, 0.85))) >= 4.6
  }
  if ok(accent) {
    return accent
  }
  let mut lo = 0.0
  let mut hi = 0.65
  for _ in 0..<10 {
    let mid = (lo + hi) * 0.5
    if ok(mix(0x000000FFL, mid, accent)) {
      hi = mid
    } else {
      lo = mid
    }
  }
  mix(0x000000FFL, hi, accent)
}

///|
/// A single-layer iOS 26/27 Liquid Glass capsule button in `parent`.
/// - `prominent=false`: neutral `.glass` (`Floating` tone, `theme().p.text` ink).
/// - `prominent=true`: vivid `.glassProminent` (`Prominent` tone tinted with `theme().p.accent`, pure white `0xFFFFFFFFL` ink).
/// - `icon`: optional 16pt leading icon name.
/// - `disabled`: fades to `0.45` alpha and triggers `refused_shake` when pressed.
/// - `tips`: optional `TipLayer` for a top hover tooltip.
#callsite(autofill(loc))
pub fn glass_button_node(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  prominent? : Bool = false,
  icon? : String = "",
  disabled? : () -> Bool = fn() { false },
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, disabled~, fn(b, btn) {
    let seen = @motion.NodeWay::new(if @signals.untracked(disabled) { 0.45 } else { 1.0 })
    b.reacts(disabled, fn(off) { seen.go_ms(b, if off { 0.45 } else { 1.0 }, dur_ms) })
    refused_shake(b, disabled)
    let ink = fn() {
      if prominent {
        0xFFFFFFFFL
      } else {
        theme().p.text
      }
    }
    b
    .focus_ring_theme()
    .row(Is(true))
    .height(Is(Some(glass_button_height)))
    .padding(Is((glass_button_padx, 0.0, glass_button_padx, 0.0)))
    .gap(Is(glass_button_gap))
    .radius(Is(glass_button_height / 2.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .alpha(By(fn() { seen.shown(b) }))
    |> ignore
    hover_ground_node(
      b,
      on=fn() { !disabled() },
      color=fn() {
        if b.pressed() {
          if b.glass_solid() {
            if prominent {
              0x00000018L
            } else {
              bar_pill_press_ink(solid=true)
            }
          } else {
            0xFFFFFF2EL
          }
        } else if prominent {
          0xFFFFFF1EL
        } else {
          @ui.tree_theme().color(Hover)
        }
      },
    )
    let ih = if prominent {
      @glass.liquid_press_glass_decorate(
        b,
        tone=Prominent,
        sharing=false,
        tint=fn() { Some(prominent_accent_fill(theme().p.accent)) },
        solid=fn() { prominent_accent_fill(theme().p.accent) },
        shadow=glass_control_shadow,
        solid_edge=fn() { (0.0, 0L) },
        with_scale=true,
      )
    } else {
      @glass.liquid_press_glass_decorate(
        b,
        tone=Floating,
        sharing=true,
        solid=panel_ground,
        shadow=glass_control_shadow,
        solid_edge=fn() { (control_edge_w, panel_edge()) },
        with_scale=true,
      )
    }
    b
    .gesture(
      @ui.touch_slop(),
      press=fn(d) {
        if !btn.disabled() {
          ih.down(d.x, d.y, d.w, d.h)
        }
      },
      tap=fn(d) {
        ih.up()
        if !btn.disabled() && b.finger_target(d.wx, d.wy) {
          btn.press()
        }
      },
      drag=fn(d) {
        match d.kind {
          Down | Moved =>
            if !btn.disabled() {
              ih.moved(d.x, d.y)
            }
          Up => {
            ih.up()
            if !btn.disabled() && @ui.pointing() is Mouse && b.finger_target(d.wx, d.wy) {
              btn.press()
            }
          }
          Off => ih.up()
        }
      },
    )
    |> ignore
    if icon != "" {
      icon_node(b, icon, button_icon, By(ink), loc~) |> ignore
    }
    b.box(fn(w) {
      let th = @signals.untracked(theme)
      w
      .words(
        By(label),
        look={
          size: th.t.ui,
          weight: if th.touch { 600 } else { 500 },
          line: th.t.ui_line,
          wrap: false,
          tracking: @view.letters_own,
          balance: false,
          max_lines: 0,
        },
      )
      .ink(By(ink))
      |> ignore
    })
    |> ignore
    match tips {
      Some(t) => tip_node(t, b, label, side=Top) |> ignore
      None => ()
    }
  })
}
