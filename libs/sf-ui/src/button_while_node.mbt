// A part that is pressed only while something says so (a head's name renamed by a press, a station's choice where there
// are others to choose): mbui's headless button then (a disclosure where it opens something), what it is to the hand,
// the keyboard and a screen reader that component's; else a plain box, nothing to press and read out as what it shows,
// no control. One look draws both.

///|
/// A part in `parent` that is a button named `label` while `on` says so, `press` done as it is pressed (given its
/// node); a disclosure, open while `open` says, where that is given; else a plain box. Made anew, at once, as `on`
/// changes (the one before let go). `look` draws it, given its node and whether it is the button then; the keyboard's
/// focus shown on the button by the theme's ring. `in_row`: it gives way in a row as what it holds does (cut short to
/// its least); `fills`: all of what holds it; `over`: laid over what else `parent` holds (what is pressed laid over a
/// part's words); `plain` false: nothing drawn while it is no button (the pick's own box alone, no look). No box of
/// its own round the pick's: what it holds is laid out in `parent` (a quote's source made one node more than before
/// for it, two with one, the chat's page counted).
#callsite(autofill(loc))
fn button_while_node(
  parent : @view.View,
  on : () -> Bool,
  label : () -> String,
  press : (@view.View) -> Unit,
  look : (@view.View, Bool) -> Unit,
  open? : () -> Bool,
  in_row? : Bool = false,
  fills? : Bool = false,
  over? : Bool = false,
  plain? : Bool = true,
  loc~ : SourceLoc,
) -> Unit {
  // (what holds it given way to as it gives way itself)
  let laid = fn(v : @view.View) {
    if fills {
      v.grow(Is(1.0)) |> ignore
    }
    if in_row {
      v.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    }
  }
  parent.pick(loc~, on, at_once=true, fn(p, pressed) {
    laid(p)
    if over {
      p.over(Is(true)) |> ignore
    }
    if !pressed {
      // (the pick's own box is the part while it is no button)
      if plain {
        look(p, false)
      }
      return
    }
    let drawn = fn(v : @view.View) {
      laid(v)
      focus_ring_node(v)
      look(v, true)
    }
    match open {
      Some(o) => @headless.disclosure(made_for=loc, p, label, o, press, fn(v, _) { drawn(v) }) |> ignore
      None => @headless.button(made_for=loc, p, label, press, fn(v, _) { drawn(v) }) |> ignore
    }
  })
}
