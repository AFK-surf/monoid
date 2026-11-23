// A ring to choose a thing by among several (圆环多选序号勾选框) as a node of the window's tree, made once: over a
// picture of a strip or a grid (a photo of the recent ones, a file of a folder), white over a shade of black so that
// it shows on a white picture too; chosen, filled with the primary as a checkbox ticked, the place it was chosen in
// (1 the first) on it. What it is to the hand, the keyboard and a screen reader is mbui's headless checkbox's
// (@headless.toggle, Checkbox: read out checked while chosen); here its look.

///|
/// The ring in `parent`, `side` across, named `label`: chosen while `order()` is more than none, that number on it;
/// pressed, `press` (choosing it or letting it go, its caller's). The node.
#callsite(autofill(loc))
pub fn select_ring_node(
  parent : @view.View,
  label : () -> String,
  order : () -> Int,
  press : () -> Unit,
  side? : Double = select_ring_side,
  loc~ : SourceLoc,
) -> @view.View {
  let chosen = fn() { order() > 0 }
  // (its two looks worked out once, for its side)
  let off = select_ring_look(side)
  let on = off.then(select_ring_on)
  @headless.toggle(made_for=loc, parent, Checkbox, label, chosen, fn(_) { press() }, fn(r, _) {
    style_node(r, fn() { if chosen() { on } else { off } }, in_row=true)
    r.show(
      fn() { chosen() },
      fn(w) { words_node(w, fn() { order().to_string() }, fn() { select_ring_words }) |> ignore },
      at_once=true,
    )
  })
}

///|
/// How wide a ring is where its caller says no other (22: a strip's tiles').
pub let select_ring_side : Double = 22.0

///|
/// A ring not chosen, `side` across: white, over a shade of black.
fn select_ring_look(side : Double) -> @ui.Style {
  @ui.style(w=Fixed(side), h=Fixed(side), radius=Full, bg=A(Theater, O20), border=B1_5, border_color=OnVeil)
}

///|
/// Chosen: filled with the primary (as a checkbox ticked), its number in its middle.
// kept across runs: a value (no field of it changes)
let select_ring_on : @ui.Style = @ui.css("bg=Primary align=ACenter justify=JCenter")

///|
/// The number on a ring chosen.
// kept across runs: a value (no field of it changes)
let select_ring_words : @ui.TextStyle = @ui.text_style(size=Caption, weight=Semibold, color=OnPrimary, wrap=false)
