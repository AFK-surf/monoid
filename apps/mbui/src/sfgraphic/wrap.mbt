// A shareable comparison built from the same card, buttons, chooser and flex layout as the app. Only the normal-wrap
// example changes the direction of the card foot; the wide and reverse examples use the app's own ask_buttons.

///|
let paper : Int64 = 0xEDEDF0FFL
///|
let ink : Int64 = 0x1D1D1FFFL
///|
let muted : Int64 = 0x6E6E73FFL
///|
let faint : Int64 = 0x85858CFFL
///|
let white : Int64 = 0xFFFFFFFFL
///|
let red : Int64 = 0xF0502CFFL
///|
let blue : Int64 = 0x2863E9FFL

///|
/// The sign-in card's own controls.
fn sign_in_actions(v : @view.View) -> Unit {
  @sf.button_node(v, fn() { "Use password manager" }, fn() { }, tone=Primary, card_words=true) |> ignore
  @sf.button_node(v, fn() { "Sign in here" }, fn() { }, tone=Ghost, card_words=true) |> ignore
  @sf.chooser_button_node(v, fn() { "Save to vault" }, fn() { [] }, fn() { "" }, fn(_) { }, card_words=true) |> ignore
}

///|
/// A real sign-in card's components at one width. `reverse` is the only difference in its foot's layout.
pub fn sign_in_example(parent : @view.View, width : Double, reverse : Bool) -> Unit {
  parent.box(fn(box) {
    box.width(Is(Some(width))) |> ignore
    @sf.ask_card_node(box, fn(card) {
      @sf.ask_words_node(card, fn() { "Sign in to github.com" }, fn() { "View Actions logs for PR #512" }) |> ignore
      if reverse {
        @sf.ask_buttons_node(card, sign_in_actions) |> ignore
      } else {
        card.box(fn(f) {
          @sf.style_node(f, fn() { @sf.ask_foot.then(@sf.foot_reach(@sf.button_height())) })
          f.wraps(By(fn() { Some(@sf.ask_foot_lines()) })) |> ignore
          sign_in_actions(f)
        })
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
fn card_at(parent : @view.View, x : Double, y : Double, width : Double, reverse : Bool) -> Unit {
  parent.box(fn(v) {
    v.over(Is(true), edges=(Some(x), Some(y), None, None)).width(Is(Some(width))) |> ignore
    sign_in_example(v, width, reverse)
  })
  |> ignore
}

///|
fn comparison_panel(parent : @view.View, x : Double, reverse : Bool) -> Unit {
  let w = 418.0
  let dot = @ui.capsule_in(@sf.pane_corner, 10.0)
  @figure.panel_node(parent, x, 244.0, w, 280.0, white, @sf.pane_corner, fn(panel) {
    @figure.panel_node(panel, dot, dot, 10.0, 10.0, if reverse { blue } else { red }, 5.0, fn(_) { })
    @figure.words_node(panel, dot + 20.0, dot - 5.625, if reverse { "Narrow · reverse wrap" } else { "Narrow · normal wrap" }, 17.0, ink, weight=650)
    @figure.words_node(panel, if reverse { 296.0 } else { 348.0 }, dot - 2.625, if reverse { "wrap-reverse ↑" } else { "wrap ↓" }, 11.0, faint)
    card_at(panel, @sf.panel_card_in, 54.0, w - 2.0 * @sf.panel_card_in, reverse)
    @figure.words_node(panel, @sf.panel_card_in + @sf.card_pad, 216.0, if reverse { "The last action wraps up." } else { "The last action wraps down." }, 15.0, ink, weight=650)
    @figure.words_node(
      panel,
      @sf.panel_card_in + @sf.card_pad,
      240.0,
      if reverse { "The primary action stays in the bottom-left corner." } else { "The primary action is no longer at the bottom." },
      12.0,
      muted,
    )
  })
}

///|
/// The 960 × 540 wrapping figure, intended to be drawn at 2.5× for a 2400 × 1350 PNG.
pub fn wrap_figure(root : @view.View) -> Unit {
  @ui.set_tree_theme(@sf.ui_theme_now)
  let wide_panel_w = 860.0
  let wide_card_x = 164.0
  let wide_card_w = wide_panel_w - wide_card_x - @sf.panel_card_in
  @figure.canvas_node(root, 960.0, 540.0, paper, fn(canvas) {
    @figure.words_node(canvas, 50.0, 19.0, "Same buttons. Different wrap.", 34.0, ink, weight=680)
    @figure.words_node(canvas, 50.0, 65.0, "Three actions fit on a wide row. When space runs out, the wrap direction matters.", 14.0, muted)
    @figure.panel_node(canvas, 826.0, 31.0, 10.0, 10.0, ink, 3.0, fn(_) { })
    @figure.words_node(canvas, 844.0, 24.0, "still.fail", 18.0, ink, weight=650)
    @figure.auto_panel_node(canvas, 50.0, 96.0, wide_panel_w, white, @sf.pane_corner, fn(panel) {
      @figure.words_node(panel, @sf.card_pad, 25.0, "Wide layout", 18.0, ink, weight=650)
      @figure.words_node(panel, @sf.card_pad, 59.0, "All three actions\nfit on one line.", 14.0, muted, width=135.0, line=20.0)
      panel.box(fn(v) {
        v
        .width(Is(Some(wide_card_w)))
        .margin(Is((wide_card_x, @sf.panel_card_in, 0.0, @sf.panel_card_in)))
        |> ignore
        sign_in_example(v, wide_card_w, true)
      })
      |> ignore
    })
    comparison_panel(canvas, 50.0, false)
    comparison_panel(canvas, 492.0, true)
  })
}
