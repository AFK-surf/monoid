// A key of a bar that says how far something has come (进度键) as a node of the window's tree, made once: a ring in
// a bar key's room (a page's resources loading beside its address), pressed to see what it is of. What it is to the
// hand and the keyboard is mbui's headless button's (@headless.button); how far it has come is read out as the
// button's own value and range, said as it changes; here its look.

///|
/// The key in `parent`, a bar key square (the theme's bars' `key`), named `label`, `press` done as it is pressed (given
/// its node: what it opens goes beside it). In its middle a ring `ring` across, `part()` of it come (0 to 100) in
/// `color()`'s ink; read out as one button, `value()` its words (none till there are some) and `part()` its range's
/// place. The node.
#callsite(autofill(loc))
pub fn bar_meter_button_node(
  parent : @view.View,
  label : () -> String,
  press : (@view.View) -> Unit,
  ring~ : Double,
  part~ : () -> Double,
  value~ : () -> String,
  color~ : () -> Int64,
  loc~ : SourceLoc,
) -> @view.View {
  // (one key to a screen reader, whatever has come: its name, how far it came as its value and range, said as that
  // changes)
  @headless.button(made_for=loc, parent, label, press, value~, range=fn() { Some((0.0, part(), 100.0)) }, fn(v, _) {
    v
    .width(By(fn() { Some(theme().bars.key) }))
    .height(By(fn() { Some(theme().bars.key) }))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    |> ignore
    progress_ring_node(v, ring, fn() { part() / 100.0 }, color) |> ignore
  })
}
