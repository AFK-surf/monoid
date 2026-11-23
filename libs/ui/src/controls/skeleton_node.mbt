// Skeletons (骨架屏) as nodes of the window's tree, made once: quiet blocks standing where what is coming will be (a
// line of words, a picture's circle, a block, a card of them), pulsing softly all together while they wait: their
// ground faded to skeleton_low and back once a skeleton_ms on CSS's ease-in-out, read as it is drawn by the clock's
// cycle (View::cycle, from moment 0 on: every skeleton of the window in step, nothing set off by a frame), still with
// motion reduced (@ui.reduced_motion). None of it is read out or takes a press: what is coming says itself when it
// comes.

///|
/// A skeleton line in `parent`: `share` of the room across (0 to 1), `h` high, its ends round. The node.
#callsite(autofill(loc))
pub fn skeleton_line_node(parent : @view.View, share? : Double = 1.0, h? : Double = 12.0, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    skeleton_bone(b)
    b.width_share(Is(share)).height(Is(Some(h))).radius(Is(h / 2.0)) |> ignore
  })
}

///|
/// A skeleton circle in `parent` (an avatar's, a picture's), `size` across. The node.
#callsite(autofill(loc))
pub fn skeleton_circle_node(parent : @view.View, size? : Double = 40.0, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    skeleton_bone(b)
    b.width(Is(Some(size))).height(Is(Some(size))).radius(Is(size / 2.0)).shrink(Is(0.0)) |> ignore
  })
}

///|
/// A skeleton block in `parent` (a picture's, a chart's), `h` high, `w` across (None: as wide as where it is), `corner`
/// round (a row's corner unless said). The node.
#callsite(autofill(loc))
pub fn skeleton_rect_node(
  parent : @view.View,
  h : Double,
  w? : Double? = None,
  corner? : Double = small_corner,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    skeleton_bone(b)
    b.height(Is(Some(h))).radius(Is(corner)) |> ignore
    match w {
      Some(w) => b.width(Is(Some(w))) |> ignore
      None => b.width_share(Is(1.0)) |> ignore
    }
  })
}

///|
/// A card of skeletons in `parent` as wide as where it is (what a row of a list will be while it comes): bordered, a
/// row's corner, 20 in (clear of its corner: none of it stands by its arc); a circle and two lines beside it over
/// `lines` lines (the last shorter). The node.
#callsite(autofill(loc))
pub fn skeleton_card_node(parent : @view.View, lines? : Int = 3, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(card) {
    style_node(card, fn() { skeleton_card })
    card.hides(Is(true)) |> ignore
    card.box(fn(head) {
      style_node(head, fn() { skeleton_card_head })
      skeleton_circle_node(head, size=skeleton_card_face) |> ignore
      head.box(fn(words) {
        style_node(words, fn() { skeleton_card_words })
        words.grow(Is(1.0)) |> ignore
        skeleton_line_node(words, share=0.5, h=12.0) |> ignore
        skeleton_line_node(words, share=0.3, h=10.0) |> ignore
      })
      |> ignore
    })
    |> ignore
    for i in 0..<lines {
      skeleton_line_node(card, share=if i == lines - 1 && lines > 1 { 0.6 } else { 1.0 }, h=10.0) |> ignore
    }
  })
}

///|
/// A skeleton's block, node `b`: its quiet ground pulsing (still with motion reduced), not read out, taking no press.
fn skeleton_bone(b : @view.View) -> Unit {
  b
  .ground(By(fn() { alpha(theme().p.text, skeleton_ground) }))
  .hides(Is(true))
  .alpha(
    By(fn() {
      if @ui.reduced_motion() {
        1.0
      } else {
        let f = b.cycle(skeleton_ms)
        let way = if f < 0.5 { f * 2.0 } else { 2.0 - f * 2.0 }
        1.0 - (1.0 - skeleton_low) * @ui.Ease::InOut.at(way)
      }
    }),
  )
  |> ignore
}

///|
/// A pulse's period, the least it fades to, and the ink's share its ground is.
pub let skeleton_ms : Double = 1600.0

///|
let skeleton_low : Double = 0.5

///|
let skeleton_ground : Double = 0.08

///|
/// The circle of a skeleton card.
let skeleton_card_face : Double = 40.0

///|
/// A card of skeletons: the surface, edged, a row's corner, 20 in (clear of the 18 corner), its rows 12 apart.
// kept across runs: a value (no field of it changes)
let skeleton_card : @ui.Style = @ui.css("w=Full p=S5 gap=S3 bg=Surface border=B1 border_color=Border").then(
  @ui.style(radius=row_radius),
)

///|
// kept across runs: a value (no field of it changes)
let skeleton_card_head : @ui.Style = @ui.css("row w=Full gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let skeleton_card_words : @ui.Style = @ui.css("gap=S2")
