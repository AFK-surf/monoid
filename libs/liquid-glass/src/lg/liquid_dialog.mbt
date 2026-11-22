// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/destinations/DialogContent.kt. Over the page dimmed by
// the scrim's colour, a card of glass 40 in from the window's sides, its corners 48: what is under it brightened (by
// 0.2 in the light, none in the dark) and made vivid (a saturation of 1.5), blurred (16 in the light, 8 in the dark),
// bent by a lens 24 deep moving it by up to 48 with depth, its highlight Plain, the dialog's container colour over it.
// In it its title (24, medium) 28 in and 24 down, its words (15, at 68% of the words' colour, 5 lines at most) 24 in,
// and two capsule buttons 48 high side by side, 16 apart and 24 in: Cancel on the container's colour at 20%, the action
// on the accent in white. What it is to the keys and a screen reader is mbui's headless dialog's: modal, read out a
// dialog by its title, the focus taken in as it opens and given back as it goes, closed by Escape, the system's back
// and a press outside it (on the scrim).

///|
/// The card's glass: symmetric 80% dense iOS 27 liquid glass (`liquid_dialog_glass()`).
fn dialog_glass() -> @paint.Glass {
  liquid_dialog_glass()
}

///|
/// Composable single-layer dense Liquid Glass dialog shell (`r=24pt` by default) with symmetric 80%
/// `liquid_dialog_glass`, `shadow_outside(Is(true))`, `MBUI_GLASS=solid` 1pt hairline fallback, and `clips(Is(true))`.
/// Lets callers such as centered panels, confirm dialogs, and command switchers own their routing, scroll body,
/// and footer layout while reusing `@lg`'s calibrated dialog surface.
#callsite(autofill(loc))
pub fn liquid_dialog_shell_node(
  parent : @view.View,
  radius? : Double = 24.0,
  solid? : () -> Int64,
  body : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(shell) {
    shell
    .radius(Is(radius))
    .shadow(Is(shadow_default))
    .shadow_outside(Is(true))
    .glass(
      By(fn() {
        let s = match solid {
          Some(f) => f()
          None => clear
        }
        Some(liquid_dialog_glass(solid=s))
      }),
    )
    .edge(By(fn() { if shell.glass_solid() { liquid_overlay_solid_edge() } else { (0.0, clear) } }))
    .clips(Is(true))
    |> ignore
    body(shell)
  })
}

///|
/// iOS 26/27 Alert geometry: 34pt card radius, 40pt capsule buttons (r=20pt) inside 14pt padding -> 14 + 20 = 34pt exact concentric.
let dialog_card_radius : Double = 34.0

///|
let dialog_button_h : Double = 40.0

///|
/// One of a dialog's buttons in `parent`: a 40pt capsule taking its share of the row, its `label` (15pt medium) in
/// `ink` on `ground` with smooth closed-form `@motion.hover_fade` hover/press feedback; pressed, `press` is called.
#callsite(autofill(loc))
fn dialog_button(
  parent : @view.View,
  label : () -> String,
  press : () -> Unit,
  ground : () -> Int64,
  ink : () -> Int64,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, fn(b, btn) {
    let btn_r = dialog_button_h / 2.0
    let hover_t = @motion.hover_fade(b, fn() { btn.hovered() })
    let press_t = @motion.hover_fade(b, fn() { btn.pressed() }, duration_ms=@motion.pointer_tap_ms)
    b
    .grow(Is(1.0))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .height(Is(Some(dialog_button_h)))
    .padding(Is((button_px, 0.0, button_px, 0.0)))
    .radius(Is(btn_r))
    .ground(
      By(fn() {
        let base = ground()
        let h = hover_t()
        let p = press_t()
        let with_hover = if h > 0.001 { over(base, alpha(ovl_row_hover(), h)) } else { base }
        if p > 0.001 {
          over(with_hover, alpha(ovl_row_press(), p))
        } else {
          with_hover
        }
      }),
    )
    |> ignore
    b.box(fn(w) { w.words(By(label), look=words_at(15.0, weight=weight_medium)).ink(By(ink)) |> ignore }) |> ignore
    b.show(fn() { btn.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .margin(Is((-3.0, -3.0, -3.0, -3.0)))
      .radius(Is(btn_r + 3.0))
      .edge(By(fn() { (2.0, colors().accent) }))
      |> ignore
    })
  })
}

///|
/// A LiquidDialog in `parent` (the window's root, or a layer over all of it: what it is made in it covers), open while
/// `open` says: read out a dialog named `title`, its words `text`; `cancel` (its first button) and `close` (Escape,
/// back, a press on the scrim) tell `on_close`; its action, `action`, tells `on_action`. Compact iOS 26/27 Alert
/// proportions (`width=320pt`, `r=34pt`, concentric `40pt` buttons inside `14pt` padding). The node holding it.
#callsite(autofill(loc))
pub fn liquid_dialog_node(
  parent : @view.View,
  open : () -> Bool,
  on_close : () -> Unit,
  title : () -> String,
  text : () -> String,
  on_action? : () -> Unit = fn() {  },
  cancel? : () -> String = fn() { "Cancel" },
  action? : () -> String = fn() { "Okay" },
  width? : Double = 320.0,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(h) {
    h.over(Is(true)) |> ignore
    let shown_open = ovl_transitioned_bool(h, open)
    h.show(shown_open, leave=@motion.dialog_out_ms, fn(s) {
      let (look, live) = @motion.overlay_presence(s, enter=@motion.dialog_in, exit=@motion.dialog_out)
      s.over(Is(true)).points(By(live)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      // (the scrim: the page dimmed; a press on it is outside the dialog, which closes it)
      s.box(fn(scrim) {
        scrim
        .over(Is(true))
        .ground(By(fn() { colors().scrim }))
        .alpha(By(fn() { look().alpha }))
        |> ignore
      })
      |> ignore
      s.box(fn(room) {
        room
        .width(Is(Some(width + 2.0 * dialog_inset)))
        .max_width(Is(Some(width + 2.0 * dialog_inset)), within=true)
        .padding(Is((dialog_inset, dialog_inset, dialog_inset, dialog_inset)))
        |> ignore
        @headless.dialog(room, title, open, on_close, description=text, fn(card, _) {
          card
          .radius(Is(dialog_card_radius))
          .shadow(Is(shadow_default))
          .shadow_outside(Is(true))
          .glass(By(fn() { Some(dialog_glass()) }))
          .edge(By(fn() { if card.glass_solid() { liquid_overlay_solid_edge() } else { (0.0, clear) } }))
          .alpha(By(fn() { look().alpha }))
          .scale(By(fn() { look().sx }))
          .offset(By(fn() { (0.0, look().dy) }))
          |> ignore
          card.box(fn(t) {
            t.padding(Is((20.0, 20.0, 20.0, 6.0))) |> ignore
            t.box(fn(w) {
              w
              .words(By(title), look=words_at(17.0, weight=ovl_weight_semibold, wrap=true))
              .ink(By(fn() { colors().content }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
          card.box(fn(t) {
            t.padding(Is((20.0, 0.0, 20.0, 20.0))) |> ignore
            t.box(fn(w) {
              w
              .words(By(text), look=words_at(type_dialog_text, wrap=true, lines=5))
              .ink(By(fn() { alpha(colors().content, if is_dark() { 0.78 } else { 0.72 }) }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
          card.box(fn(r) {
            r.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))).padding(Is((14.0, 0.0, 14.0, 14.0))) |> ignore
            dialog_button(r, cancel, on_close, cancel_ground, fn() { colors().content })
            |> ignore
            dialog_button(r, action, on_action, dialog_action_ground, fn() { white }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
  })
}

///|
/// The Cancel button's ground: iOS 26/27 `UIColor.systemFill` neutral capsule fill (`rgba(120,120,128,0.16)` in
/// Light so it stays crisp over light liquid glass, `rgba(255,255,255,0.16)` in Dark).
fn cancel_ground() -> Int64 {
  if is_dark() { 0xFFFFFF29L } else { 0x78788029L }
}

///|
/// The primary Action button's ground: accessible iOS blue with >= 4.5:1 contrast against white label ink
/// (`#0066CC` 5.57:1 in Light, `#0071E3` 4.70:1 in Dark).
fn dialog_action_ground() -> Int64 {
  if is_dark() { 0x0071E3FFL } else { 0x0066CCFFL }
}
