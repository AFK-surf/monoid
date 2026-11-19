// A place of a bottom tab bar (or of its panel's rows) in its slot, as a node of the window's tree: its icon (24) in
// the idle ink, the lit one over it as far as it is lit as each frame is drawn (two pictures, one each colour, rather
// than one more of each colour on its way between them), its name under it as faint as it is dim, its dot at the
// icon's top right;
// read out as a tab of the bar by its name. Never pressed itself: a finger on the bar is what holds it's (its glass: a
// slide, a hold, its panel). Its name is drawn at the size it is said, as a phone's tab bar's is, so the bar keeps its
// height whatever the system's size of words.

///|
/// How far down its slot a place's icon's middle is (the lit place's indicator round it, the app's): its top 6 over
/// the indicator, 32 high.
pub let bar_place_icon_mid : Double = 22.0

///|
/// How high a place's icon's room is (the indicator and 6 over and under it); its name below.
let bar_place_icon_room : Double = 44.0

///|
// kept across runs: a value (no field of it changes)
let bar_place_words : @ui.TextStyle = @ui.text_style(size=Caption, weight=Medium, color=Fg, center=true, wrap=false)

///|
/// How faint a dim place's name is (the words' ink at this: as grey as the idle icon, still 4.5:1 on the bar).
let bar_place_dim_words : Double = 0.7

///|
/// Place `at` (a box its slot's size) of icon `icon` (the stations' glyph of `glance`, where it is given) over its name
/// `name`, lit as far as `lit` says as node `n` is drawn, its dot `dot` (0: none), read out as a tab called `said`.
#callsite(autofill(loc))
pub fn bar_place_node(
  at : @view.View,
  icon : String,
  glance : (() -> GlyphCounts)?,
  name : () -> String,
  lit : (@view.View) -> Double,
  dot : () -> Int64,
  said : () -> String,
  loc~ : SourceLoc,
) -> Unit {
  let idle_ink = fn() { if theme().dark { 0xD1D5DBFFL } else { 0x6B7280FFL } }
  let lit_ink = fn() { if theme().dark { 0xFFFFFFFFL } else { 0x111827FFL } }
  at
  .made_for(loc)
  .lines_up(Is(Some(Middle)))
  .says(By(fn() { Some(@view.said(Tab, label=said())) }))
  |> ignore
  let picture = fn(parent : @view.View, color : () -> Int64) {
    match glance {
      Some(g) => station_glyph_node(parent, g, 24.0, color, fn() { theme().p.red }) |> ignore
      None => icon_node(parent, icon, 24.0, By(color)) |> ignore
    }
  }
  // (the idle one gone once nearly lit, the lit one as opaque as it is lit, gone once nearly dim)
  let idle_alpha = fn(n : @view.View) { if lit(n) < 0.999 { 1.0 } else { 0.0 } }
  let lit_alpha = fn(n : @view.View) {
    let v = lit(n)
    if v > 0.001 {
      v
    } else {
      0.0
    }
  }
  // the icon, in the middle of its room
  at.box(fn(room) {
    room
    .width(Is(Some(bar_place_icon_room)))
    .height(Is(Some(bar_place_icon_room)))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    |> ignore
    room.box(fn(face) {
      face.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      face.alpha(By(fn() { idle_alpha(face) })) |> ignore
      picture(face, idle_ink)
    })
    |> ignore
    room.box(fn(over) {
      over.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      over.alpha(By(fn() { lit_alpha(over) })) |> ignore
      picture(over, lit_ink)
    })
    |> ignore
    room.box(fn(d) {
      d.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      d.show(at_once=true, fn() { dot() != 0L }, fn(mark) {
        mark
        .width(Is(Some(7.0)))
        .height(Is(Some(7.0)))
        .radius(Is(3.5))
        .ground(By(dot))
        .offset(Is((11.0, -10.0)))
        |> ignore
      })
    })
    |> ignore
  })
  |> ignore
  // its name under it, one line of words as faint as the place is dim (two, one each colour, would be words over
  // words as it lights up)
  at.box(fn(words) {
    words.lines_up(Is(Some(Middle))) |> ignore
    words.alpha(By(fn() { bar_place_dim_words + (1.0 - bar_place_dim_words) * dclamp(lit(words), 0.0, 1.0) })) |> ignore
    mark_words_node(words, name, fn() { bar_place_words }) |> ignore
  })
  |> ignore
}
