// What shakes across, said by what shakes it (View::shakes_while, motion's ShakeWay::shakes): a node drawn off where it
// is laid out there and back along its row while a way goes, turning back again and again on purpose (a control
// refusing a press). A Tester's steadiness judges (ui's sizes_steady.mbt) take where its left edge is drawn, and that
// of what it holds, as that way's while it goes, for that alone: its top, its width and its height are judged as ever,
// and once the way is over its left edge is too, from its first frame at rest. Said by the node it moves; nothing else
// of it is taken so.

///|
/// Shakes across while `goes` says the moment it is drawn at (ms, the one clock) is one its way goes at (see the file's
/// head): what moves it across says so beside how it moves it (`ShakeWay::shakes`).
pub fn View::shakes_while(self : View, goes : (Double) -> Bool) -> View {
  guard self.live() is Some(_) else { return self }
  let tree = self.tree
  let at = self.at
  if !tree.shakes_said.contains(at) {
    self.owns(fn() { tree.shakes_said.remove(at) }) |> ignore
  }
  tree.shakes_said[at] = goes
  self
}

///|
/// Whether node `at` says it shakes across at `now` (View::shakes_while), if it says so and lives.
pub fn Tree::shakes_at(self : Tree, at : Int, now : Double) -> Bool {
  guard at >= 0 && at < self.nodes.length() && self.nodes[at].live else { return false }
  match self.shakes_said.get(at) {
    Some(goes) => goes(now)
    None => false
  }
}
