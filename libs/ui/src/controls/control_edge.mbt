// Outlined control edges share one hairline thickness (`B0_5`, `control_edge_w`):
// - `control_edge`: non-form outlined parts (filter pills, choice cards, avatar/swatch rings) use `Line` at rest and
//   `Border` (`line_strong`) while pointed at (`Bg` when `solid`).
// - `field_edge`: form controls (`input_node`, `textarea_node`, `select_node`) keep a light, crisp hairline over both
//   translucent liquid glass dialogs and solid surfaces: in light mode, 65% of `Border` toward `Surface` (`#D7D9DC`) at
//   rest and `Border` (`#C1C4C9`) when hot/focused; in dark mode, `Border` (`#44464B`) at rest and halfway toward
//   `FieldHover` (`#515359`) when hot/focused (stepping to `Border` / `FieldHover` under Increase Contrast; `Bg` when
//   `solid`).
// A chosen ring (`B2` in Fg) is neither edge.

///|
/// How thick an outlined control's edge is: a hairline (`@ui.Stroke::B0_5`, as seg_node's and tabs_node's lines).
pub let control_edge_w : Double = 0.5

///|
/// An outlined non-form control's edge now: `hot` (pointed at) the theme's `Border`; `solid` (on the page's own ground,
/// no line of its own) the ground's; else the theme's `Line`.
pub fn control_edge(hot? : Bool = false, solid? : Bool = false) -> (Double, Int64) {
  let t = @ui.tree_theme()
  (control_edge_w, t.color(if hot { Border } else if solid { Bg } else { Line }))
}

///|
/// An outlined form control's edge now (`input_node`, `textarea_node`, `select_node`): keeps a delicate 0.5pt hairline
/// that stays distinct on translucent liquid glass dialogs without looking heavy. Light: `#D7D9DC` rest -> `Border`
/// (`#C1C4C9`) hot; dark: `Border` (`#44464B`) rest -> `#515359` hot; `solid` at rest stays `Bg`; Increase Contrast
/// uses full `Border` / `FieldHover`.
pub fn field_edge(hot? : Bool = false, solid? : Bool = false) -> (Double, Int64) {
  let t = @ui.tree_theme()
  let c = if hot {
    if @ui.more_contrast() {
      t.color(FieldHover)
    } else if theme().dark {
      mix(t.color(FieldHover), 0.5, t.color(Border))
    } else {
      t.color(Border)
    }
  } else if solid {
    t.color(Bg)
  } else if theme().dark || @ui.more_contrast() {
    t.color(Border)
  } else {
    mix(t.color(Border), 0.65, t.color(Surface))
  }
  (control_edge_w, c)
}
