// What scrolls across in the frame just drawn, each as much of it as shows: an old view's box scrolled sideways
// (Ctx::sideways: a code block's line, a wide table) and a node of the window's tree that scrolls across (View::scrolls
// with Scroll::across, put among the frame's as the squeeze reads them: Ctx::with_tree_nodes `facts`). What such a box
// holds past its edge is not where it shows: the hand scrolls it in, to the box's edge. A test that holds what is
// pressed clear of a part of the window (a system's column down its side) holds the box by where it shows, and what it
// holds by the box.

///|
/// The boxes that scroll across in the last frame (see the file's head), each where it shows, cut by what clips it
/// (x, y, w, h; w or h 0 where none of it shows).
pub fn Tester::across_shown(self : Tester) -> Array[(Double, Double, Double, Double)] {
  self.reads_own()
  let c = g()
  c.with_tree_nodes(facts=true, fn() {
    let out = []
    for b in self.boxes() {
      if c.nodes[b.index].sideways {
        out.push(b.cut)
      }
    }
    out
  })
}
