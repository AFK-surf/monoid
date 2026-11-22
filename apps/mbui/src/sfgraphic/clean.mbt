// Individual editions of the share graphics: one actual app card on a neutral canvas.

///|
let clean_card_width : Double = 398.0

///|
let clean_canvas_width : Double = 480.0

///|
let clean_canvas_height : Double = 270.0

///|
fn clean_card(root : @view.View, body : (@view.View) -> Unit) -> Unit {
  @ui.set_tree_theme(@sf.ui_theme_now)
  @figure.canvas_node(root, clean_canvas_width, clean_canvas_height, paper, fn(canvas) {
    canvas.box(fn(v) {
      v
      .row(Is(true))
      .width_share(Is(1.0))
      .height_share(Is(1.0))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      |> ignore
      body(v)
    })
    |> ignore
  })
}

///|
/// The narrow sign-in card, with either normal or reverse wrapping.
pub fn wrap_card_figure(root : @view.View, reverse : Bool) -> Unit {
  clean_card(root, fn(v) {
    sign_in_example(v, clean_card_width, reverse)
  })
}

///|
/// The quota card, with either button-edge or text alignment.
pub fn alignment_card_figure(root : @view.View, text_aligned : Bool) -> Unit {
  clean_card(root, fn(v) {
    alignment_example(v, clean_card_width, text_aligned)
  })
}
