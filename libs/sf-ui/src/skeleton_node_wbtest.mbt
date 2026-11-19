// The library's skeletons (skeleton_node.mbt): lines, circles, blocks and a card of them; none read out or taking a
// press; pulsing all in step as a wait read by the clock's cycle (no motion set off, nothing asked of a frame by hand),
// still with motion reduced (nothing of the clock read); nothing the audit finds.

///|
/// A window `w` wide holding a skeleton line (half across), a circle, a block and a card of them, and a button "之后"
/// after them.
fn skel2(w? : Double = 600.0) -> @ui.Tester {
  w2_case(w~, fn(root) {
    skeleton_line_node(root, share=0.5) |> ignore
    skeleton_circle_node(root) |> ignore
    skeleton_rect_node(root, 80.0) |> ignore
    skeleton_card_node(root) |> ignore
    button_node(root, fn() { "之后" }, fn() {  }) |> ignore
  })
}

///|
/// The opacities of what the skeletons draw (their ground's alpha), in the order drawn.
fn skel2_alphas(t : @ui.Tester) -> Array[Int] {
  t.drawn_rects().map(fn(r) { (r.4 & 0xFFL).to_int() })
}

///|
test "skeletons: a line half across, a circle, a block and a card, none of them read out nor taking a press (Tab goes from 别处 to the button after them); nothing the audit finds, in a phone's width and a wide one" {
  for w in [390.0, 1280.0] {
    let t = skel2(w~)
    // (read out: 别处 and the button after them alone)
    assert_eq(t.all(Button).map(fn(s) { s.label }), ["别处", "之后"])
    t.act(Button, Focus, label="别处")
    t.tab()
    assert_eq(t.focused().map(fn(s) { s.label }), Some("之后"))
    assert_eq(t.audit(), [], msg="\{w}")
  }
}

///|
test "skeletons pulse as a wait read by the clock's cycle (no motion set off), all in step: what they draw differs half a pulse on, and is the same a whole pulse on" {
  let t = skel2()
  let tree = @ui.view_tree().unwrap()
  assert_true(tree.cycle_read(), msg="a wait read by the clock")
  assert_true(!tree.clock_read(), msg="no motion")
  let at0 = skel2_alphas(t)
  t.run_for(skeleton_ms / 2.0)
  let half = skel2_alphas(t)
  t.run_for(skeleton_ms / 2.0)
  let whole = skel2_alphas(t)
  assert_true(half != at0, msg="half a pulse on: as drawn at first")
  assert_eq(whole, at0)
}

///|
test "skeletons with motion reduced: still, a soft ground, nothing of the clock read" {
  @ui.set_motion_chosen(Some(true))
  let t = skel2()
  let tree = @ui.view_tree().unwrap()
  let read = tree.cycle_read() || tree.clock_read()
  let at0 = skel2_alphas(t)
  t.run_for(skeleton_ms / 2.0)
  let half = skel2_alphas(t)
  @ui.set_motion_chosen(None)
  assert_true(!read, msg="nothing of the clock read")
  assert_eq(half, at0)
}
