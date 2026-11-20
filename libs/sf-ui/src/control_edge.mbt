// One edge for every outlined control (a field, a select, a filter pill, a choice card, an accordion's card, a framed
// bar field, a swatch or an avatar's tile): a hairline (`B0_5`), the theme's Line at rest and its Border pointed at or
// written in, so the frames read alike and quiet beside one another. A chosen ring (`B2` in Fg) is not this edge.

///|
/// How thick an outlined control's edge is: a hairline (`@ui.Stroke::B0_5`, as seg_node's and tabs_node's lines).
let control_edge_w : Double = 0.5

///|
/// An outlined control's edge now: `hot` (pointed at, open or written in) the theme's Border; `solid` (on the page's
/// own ground, no line of its own) the ground's; else the theme's Line.
fn control_edge(hot? : Bool = false, solid? : Bool = false) -> (Double, Int64) {
  let t = @ui.tree_theme()
  (control_edge_w, t.color(if hot { Border } else if solid { Bg } else { Line }))
}
