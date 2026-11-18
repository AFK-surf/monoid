// A place of a bottom bar (or of its panel's rows) in its slot, as a node of the window's tree: its icon (28) in the
// idle ink, the lit one over it as far as it is lit as each frame is drawn (two pictures, one each colour, rather than
// one more of each colour on its way between them), its dot at the icon's top right; read out as a tab of the bar by
// its name. Never pressed itself: a finger on the bar is what holds it's (its glass: a slide, a hold, its panel).

///|
/// Place `at` (a box its slot's size) of icon `icon` (the stations' glyph of `glance`, where it is given), lit as far as
/// `lit` says as node `n` is drawn, its dot `dot` (0: none), read out as a tab called `said`.
#callsite(autofill(loc))
pub fn bar_place_node(
  at : @view.View,
  icon : String,
  glance : (() -> GlyphCounts)?,
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
  .lies_along(Is(Middle))
  .says(By(fn() { Some(@view.said(Tab, label=said())) }))
  |> ignore
  let picture = fn(parent : @view.View, color : () -> Int64) {
    match glance {
      Some(g) => station_glyph_node(parent, g, 28.0, color, fn() { theme().p.red }) |> ignore
      None => icon_node(parent, icon, 28.0, By(color)) |> ignore
    }
  }
  // (the idle one gone once nearly lit, the lit one as opaque as it is lit, gone once nearly dim)
  at.box(fn(face) {
    face.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    face.alpha(By(fn() { if lit(face) < 0.999 { 1.0 } else { 0.0 } })) |> ignore
    picture(face, idle_ink)
  })
  |> ignore
  at.box(fn(over) {
    over.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    over.alpha(
      By(fn() {
        let v = lit(over)
        if v > 0.001 {
          v
        } else {
          0.0
        }
      }),
    )
    |> ignore
    picture(over, lit_ink)
  })
  |> ignore
  at.box(fn(d) {
    d.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    d.show(at_once=true, fn() { dot() != 0L }, fn(mark) {
      mark
      .width(Is(Some(7.0)))
      .height(Is(Some(7.0)))
      .radius(Is(3.5))
      .ground(By(dot))
      .offset(Is((13.5, -12.5)))
      |> ignore
    })
  })
  |> ignore
}
