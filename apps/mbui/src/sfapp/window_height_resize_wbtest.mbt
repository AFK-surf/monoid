// The window made shorter alone, its width as it was (a phone's keyboard coming up, the window laid out above it a
// step at a time): a chat's page open on 小屏 and 大屏 makes nothing new for it, and wakes only what reads the window's
// height (View::window_h), not what reads its width alone (View::window_w: a page's tier, its bars' tops, its widths).
// Before the app read a single axis as window().0 or window().1, these steps woke 6 bindings on 小屏 and 70 and 72 on
// 大屏.

///|
/// What the window's tree did in the frame that takes the window `w` by `h`: (nodes made, nodes laid out, bindings run).
fn height_step_work(t : @ui.Tester, w : Double, h : Double) -> (Int, Int, Int) {
  t.tree_frames_from_now()
  t.resize(w, h)
  t.tree_frames().fold(init=(0, 0, 0), fn(a, x) { (a.0 + x.made, a.1 + x.laid, a.2 + x.bindings) })
}

///|
test "the window made shorter alone: a chat's page wakes no binding of its width" {
  let faults : Array[String] = []
  // (screen, width, platform, and each height step's most nodes made and bindings run)
  let screens = [
    ("小屏", 390.0, 2, [(590.0, 0, 4), (530.0, 0, 4)]),
    // (at 530 the fixture's short chat overflows its list and 5 nodes come for it, as many as before 4c3ca1b673)
    ("大屏", 1280.0, 0, [(590.0, 0, 51), (530.0, 5, 55)]),
  ]
  for screen in screens {
    let (name, w, platform, steps) = screen
    let (t, _) = chat_nodes_tester(w, 844.0, platform)
    t.run_for(@ui.move_most_ms)
    let mut was = 844.0
    for step in steps {
      let (h, made_most, bindings_most) = step
      let (made, _, bindings) = height_step_work(t, w, h)
      let at = "\{name} \{w}x\{was} → \{w}x\{h}"
      if made > made_most {
        faults.push("\{at}: made \{made} nodes, at most \{made_most}")
      }
      if bindings > bindings_most {
        faults.push("\{at}: ran \{bindings} bindings, at most \{bindings_most}")
      }
      was = h
    }
  }
  assert_eq(faults.join("\n"), "")
}
