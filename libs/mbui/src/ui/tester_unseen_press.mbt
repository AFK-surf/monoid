// What takes a press where nothing of it is seen: a control faded all the way out (its own opacity, or a narrow box
// round it, at 0: a row's 删除-like key shown only under the hand by `.alpha(...)` alone) that a press on the empty place
// it stands in, a finger's or the pointer's, still lands on. The contrast check passes over what is not seen and the
// rooms' check over what is not drawn (Tree::press_boxes), so nothing else said it. What is checked is what a press
// does on a device: the tree's own hit test at the middle of where it is drawn (Tree::target_at) landing on it or on
// what it holds; one said to take none while it is not shown (View::presses, View::takes giving no area then), or
// covered there by what takes the press over it, is no fault. What is faded out with a pane holding half the window or
// more (a first page held unseen while what it shows is read) is that pane's wait, not a control's, and is passed
// over; so is one on a way not at its end (Tree::on_way_at), judged where it comes to rest.

///|
/// The opacity at or under which a node is not seen.
let unseen_alpha : Double = 0.001

///|
/// Where the window's tree takes a press on what is not seen (see the file's head): one `unseen press:` line each,
/// naming the node by the words drawn in it, where it is drawn and where it was made (tester_sources.mbt).
pub fn Tester::unseen_press_faults(self : Tester) -> Array[String] {
  self.reads_own()
  let c = g()
  guard view_tree() is Some(tree) else { return [] }
  let now = self.fake.time
  let window = c.width * c.height
  let drawn = tree.drawn()
  // (each faded all the way out that does something pressed and takes it now, with its box in the window)
  let unseen : Array[(@view.NodeId, Double, Double, Double, Double)] = []
  for d in drawn {
    if d.alpha <= unseen_alpha &&
      d.w >= 1.0 &&
      d.h >= 1.0 &&
      tree.presses_do(d.id) &&
      tree.takes_presses(d.id) &&
      !tree.on_way_at(d.id.at, now) {
      unseen.push((d.id, d.x, d.y, d.w, d.h))
    }
  }
  let out : Array[String] = []
  for u in unseen {
    let (id, x, y, w, h) = u
    let (cx, cy) = (x + w / 2.0, y + h / 2.0)
    if cx < 0.0 || cy < 0.0 || cx >= c.width || cy >= c.height {
      continue
    }
    // (what faded it out: the outermost drawn holding it as unseen as it, the opacity of what holds it multiplied in;
    // a pane holding half the window or more is that pane's wait)
    let mut faded = w * h
    let mut said = ""
    for d in drawn {
      if d.alpha <= unseen_alpha && d.w * d.h > faded && tree.holds(d.id, id) {
        faded = d.w * d.h
      }
      if d.words != "" && said == "" && tree.holds(id, d.id) {
        said = d.words
      }
    }
    if faded * 2.0 >= window {
      continue
    }
    let lands = match tree.target_at(cx, cy) {
      Pressed(t) | Dragged(t) => tree.holds(id, t)
      _ => false
    }
    if !lands {
      continue
    }
    let words = if said == "" { "a box " } else { "「\{words_short(said)}」 " }
    out.push(
      "unseen press: \{words}(a node of the window's tree's at \{x.round()},\{y.round()} \{w.round()}×\{h.round()}" +
      tree_source_said(id) +
      ") takes presses while it is not seen (opacity 0): a press on the empty place there lands on it; say it takes none while hidden (View::presses, View::takes)",
    )
  }
  out
}
