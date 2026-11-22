// A button of a few words in a bar (a page's zoom, 150%), round as a capsule as high as the bar's icon keys beside it,
// on the faint ground the bar's capsules have, deeper under the hand.

///|
/// A capsule button in `parent`: `words` in `look` (a number's digits all one width where it says so), as high as
/// icon_button_side and as round, `room` in at either end; named `label` (read out, its tip in `tips`); `press` done as
/// it is pressed. The node.
#callsite(autofill(loc))
pub fn capsule_words_button_node(
  parent : @view.View,
  words : () -> String,
  label : () -> String,
  press : () -> Unit,
  look : () -> @ui.TextStyle,
  room? : Double = @ui.Space::S3.px(),
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.button(made_for=loc, parent, label, fn(_) { press() }, fn(v, b) {
    let lit = fn() { b.hovered() || b.pressed() || b.focus_shown() }
    v
    .focus_ring_theme()
    .row(Is(true))
    .height(Is(Some(icon_button_side)))
    .padding(Is((room, 0.0, room, 0.0)))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .radius(Is(icon_button_side / 2.0))
    .ground(By(fn() {
      let p = theme().p
      if lit() {
        p.hover
      } else {
        p.neutral_bg
      }
    }))
    |> ignore
    words_node(v, words, look) |> ignore
    match tips {
      Some(t) => tip_node(t, v, label) |> ignore
      None => ()
    }
  })
}
