// A resizable column's edge, with the library's edge look over mbui's split handle.

///|
/// The left edge of a right-hand column, `width` wide, between `least` and `most`. The bounds may change with the
/// room available. Dragging and arrow keys follow the hand; the screen reader's Increment widens the column. Its
/// spoken value is the column's width. Double-clicking restores the caller's default.
#callsite(autofill(loc))
pub fn split_edge_node(
  parent : @view.View,
  label : () -> String,
  width : () -> Double,
  least : () -> Double,
  most : () -> Double,
  change : (Double) -> Unit,
  reset : () -> Unit,
  tips~ : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  let span = fn() { dmax(0.0, most() - least()) }
  let position = fn() {
    let size = span()
    if size <= 0.0 { 0.0 } else { (width() - least()) / size }
  }
  @headless.split(
    parent,
    label,
    position,
    min=0.0,
    max=1.0,
    step=0.0,
    fn(at) { change((least() + at * span()).round()) },
    span~,
    reverse=true,
    reset~,
    said_value=fn(at) { (least() + at * span()).round().to_int().to_string() + " px" },
    made_for=loc,
    fn(v, state) {
      v.grow(Is(1.0)).cursor(Is(Some(ResizeX))) |> ignore
      tip_node(tips, v, label, side=Left, delay=edge_tip_ms, skip=false, gap=edge_tip_gap, at_pointer=true) |> ignore
      v.box(fn(look) {
        look.over(Is(true)) |> ignore
        edge_look_node(look, edge_over, fn() { state.hovered() || state.focus_shown() || state.dragging() }, fn() {
          state.dragging()
        }) |> ignore
      }) |> ignore
    },
  )
}
