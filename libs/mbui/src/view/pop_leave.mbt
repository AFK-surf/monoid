// What a show or an each said to `pop_leave` lets go over a time leaves out of the flow (as Framer's popLayout, a
// pick's fader: pick_leave.mbt): it is taken out of its column or its row in the change that lets it go, drawn where
// and as big as it stood then, fading there till its time is over; what stays is laid out
// where it rests from that change on (a row's tiles after it gliding along their way, said by what moves them: @motion's
// moves_for), and the box round them comes to its size at once on its own way (View::resizes), so nothing jumps as it
// is let go at its end. Told outside a transition where only one moves it (transition.mbt), or never drawn yet: gone at
// once.

///|
/// Node `v`, one this slot's show or each lets go said to pop out of the flow: leaving over `ms` from where it stood,
/// out of the flow (the file's head). Whether it is still there, leaving.
fn View::pop_leaves(self : View, v : View, ms : Double) -> Bool {
  guard v.live() is Some(n) else { return false }
  let tree = self.tree
  let quiet = !tree.transition_gate(v.at) || answered.val || tree.answer_holds(v.at)
  if quiet || ms <= 0.0 || !v.was_placed() || @signals.untracked(tree.motion_reduced) {
    if quiet {
      tree.answer_mark(v.at)
    }
    self.leave(v, 0.0)
    return false
  }
  // (in a block of a page's list said `flips`: what holds it closes on the list's way, told from this change as a
  // show's or a pick's coming or going tells it: View::comes)
  if tree.flip_lists.length() > 0 {
    let mut p = v.at
    while p >= 0 {
      match tree.flip_lists.get(p) {
        Some(tell) => {
          tell(v.at)
          break
        }
        None => p = tree.nodes[p].parent
      }
    }
  }
  // (where it stood in the window as the change came, and as big: kept there out of the flow, below; across and down
  // from what lays its box out, as that stood then: what holds it on a way of its own is no place of its)
  let (was_x, was_y, was_w, was_h) = v.placed_window_now()
  let h0 = tree.box_holder(v.at)
  let (px0, py0) = if h0 >= 0 {
    let (x, y, _, _) = tree.handle(h0).placed_window_now()
    (x, y)
  } else {
    (0.0, 0.0)
  }
  let rel_x = was_x - px0
  let rel_y = was_y - py0
  let st = n.flex.style
  st.position = @flex.PositionType::Absolute
  st.set_width(Pt(was_w))
  st.set_height(Pt(was_h))
  st.set_inset_left(Pt(0.0))
  st.set_inset_top(Pt(0.0))
  tree.layout_marked_at(v.at)
  // (pressed and read out no more: what leaves takes nothing)
  v.presses(Is(false)).says(Is(None)) |> ignore
  // (fading out where it stands, as big as it was: never drawn smaller, what it holds kept concentric with what holds it)
  v.alpha(By(fn() { 1.0 - leave_eased(v.going()) })) |> ignore
  self.leave(v, ms)
  // (once the change's layout has it where what holds it is laid out now: put back across and down where it stood)
  // (where it is laid out at no inset is what holds it says, its padding with it: taken off where it stood)
  @signals.after_flush(fn() {
    guard v.live() is Some(m) else { return }
    let (now_x, now_y, _, _) = v.laid_window_now()
    let h1 = tree.box_holder(v.at)
    let (px1, py1) = if h1 >= 0 {
      let (x, y, _, _) = tree.handle(h1).laid_window_now()
      (x, y)
    } else {
      (0.0, 0.0)
    }
    m.flex.style.set_inset_left(Pt(rel_x - (now_x - px1)))
    m.flex.style.set_inset_top(Pt(rel_y - (now_y - py1)))
    tree.layout_marked_at(v.at)
  })
  true
}
