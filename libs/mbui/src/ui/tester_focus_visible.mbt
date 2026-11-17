// Every live Tab stop of the window's tree (Tree::focus_order) shows where the keyboard's focus has come: by a
// concentric outer ring (View::focus_ring, View::focus_ring_theme) or a look reading View::focus_shown (a roving
// picker's bar, a switch's track, an edge's handle). A button or row that lights only under the pointer leaves a
// keyboard user blind to where Tab stands.

///|
/// The live Tab stops of the frame just drawn that show nothing when focused by the keyboard: one `focus-visible:`
/// line each, naming what it says of itself, where it is drawn and where in the source it was made.
pub fn Tester::focus_visible_faults(self : Tester) -> Array[String] {
  self.reads_own()
  ignore(self)
  guard view_tree() is Some(tree) else { return [] }
  let out : Array[String] = []
  for id in tree.focus_blind() {
    let d = match tree.drawn_of(id) {
      Some(d) => d
      None => continue
    }
    let who = match tree.said_of(id) {
      Some(s) if s.label != "" => "\{s.role} 「\{words_short(s.label)}」"
      Some(s) => "\{s.role}"
      None => "node \{id.at}"
    }
    out.push(
      "focus-visible: \{who} at \{d.x.round()},\{d.y.round()} \{d.w.round()}×\{d.h.round()} takes Tab focus with no focus ring or focus_shown feedback" +
      tree_source_said(id),
    )
  }
  out
}
