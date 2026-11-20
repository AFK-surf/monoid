// A small chevron that opens or closes what is under it (a folder's rows in a tree), as a node: mbui's headless
// disclosure (expanded while what it opens is open) with the library's look.

///|
/// A chevron key in `parent`, `side` across, round, its chevron `icon_size` muted in its middle, pointing down while
/// `open()`, right while not; read out a button named `label()`, expanded while open; pressed, `toggle`.
#callsite(autofill(loc))
pub fn disclosure_key_node(
  parent : @view.View,
  label : () -> String,
  open : () -> Bool,
  toggle : () -> Unit,
  side? : Double = 12.0,
  icon_size? : Double = 12.0,
  loc~ : SourceLoc,
) -> Unit {
  @headless.disclosure(made_for=loc, parent, label, open, fn(_) { @view.transition(toggle) }, fn(k, _) {
    k
    .focus_ring_theme()
    .width(Is(Some(side)))
    .height(Is(Some(side)))
    .radius(Is(side / 2.0))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    |> ignore
    icon_node(k, "", icon_size, By(fn() { theme().p.muted }), name_now=fn() {
      if open() {
        "chevron-down"
      } else {
        "chevron-right"
      }
    })
    |> ignore
  })
  |> ignore
}
