///|
test "at work's ring as a node: turning step by step, each step woken for; held at the first while motion is reduced, nothing woken for it" {
  for reduced in [false, true] {
    let env = if reduced { [("MBUI_REDUCE_MOTION", "1")] } else { [] }
    let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=200.0, h=200.0, platform=2, env~)
    @ui.set_view_app(fn(root) { work_ring_node(root, 16.0, fn() { 0xF5B800FFL }) |> ignore })
    t.frame()
    let at = "reduced \{reduced}: \{t.wanted_why()}"
    assert_eq(t.wanted_after() == @double.infinity, reduced, msg=at)
    // (with motion reduced: as at its first step, three steps on)
    if reduced {
      let was = t.drawlist()
      t.run_for(3.0 * work_step_ms)
      assert_eq(t.drawlist(), was, msg=at)
    }
  }
}

///|
/// The turns of the shapes' bands drawn now (instances of kind 11: radians, 0 … 2π), each with the point it turns
/// about.
fn node_ring_turns(t : @ui.Tester) -> Array[(Double, Double, Double)] {
  let pi2 = 2.0 * 3.141592653589793
  t.drawn_instances().filter(fn(a) { a[5] == 11.0 }).map(fn(a) { (a[32] - (a[32] / pi2).floor() * pi2, a[33], a[34]) })
}

///|
test "at work's ring as a node: an eighth of a turn every 100 ms about its box's middle, the ring's; none between; back after eight" {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=200.0, h=200.0, platform=2)
  @ui.set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    work_ring_node(root, 10.0, mark_yellow, box=12.0) |> ignore
  })
  t.draw()
  let pi = 3.141592653589793
  // (its box at the window's top left: its middle 6, 6)
  // (from whichever step the resident clock is at as it starts)
  let start = node_ring_turns(t)[0].0
  for k in 0..=8 {
    let turns = node_ring_turns(t)
    assert_true(turns.length() > 0, msg="step \{k}")
    let want = start + (k % 8).to_double() * pi / 4.0
    let want = want - (want / (2.0 * pi)).floor() * 2.0 * pi
    for r in turns {
      assert_true((r.0 - want).abs() < 1.0e-9 || (r.0 - want).abs() > 2.0 * pi - 1.0e-9, msg="step \{k}: turned \{r.0}, not \{want}")
      if r.0 != 0.0 {
        assert_true((r.1 - 6.0).abs() < 1.0e-6 && (r.2 - 6.0).abs() < 1.0e-6, msg="step \{k}: about \{r.1},\{r.2}")
      }
    }
    let at = t.drawlist()
    t.run_for(work_step_ms / 2.0)
    assert_eq(t.drawlist(), at, msg="step \{k}, half a step on")
    t.run_for(work_step_ms / 2.0)
  }
}

///|
test "at work's ink as a node: the amber #e08a00 by day, #f2b01e at night, following the theme as it changes; its track the same at 22%" {
  set_dark(Some(false))
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=200.0, h=200.0, platform=2)
  @ui.set_view_app(fn(root) { work_ring_node(root, 10.0, mark_yellow) |> ignore })
  t.draw()
  let inks = fn() { t.drawn_shapes().map(fn(s) { s.5 }) }
  assert_true(inks().contains(0xE08A00FFL), msg="by day: \{Repr(inks())}")
  assert_true(inks().contains(alpha(0xE08A00FFL, 0.22)), msg="by day's track: \{Repr(inks())}")
  assert_true(!inks().contains(0xF2B01EFFL))
  set_dark(Some(true))
  t.draw()
  assert_true(inks().contains(0xF2B01EFFL), msg="at night: \{Repr(inks())}")
  assert_true(inks().contains(alpha(0xF2B01EFFL, 0.22)), msg="at night's track: \{Repr(inks())}")
  assert_true(!inks().contains(0xE08A00FFL))
}

///|
test "OpenCode's mark as a node: its frame, half as wide as its size and two thirds as high, edged 1.5 in the words' colour" {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=100.0, h=100.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.lines_up(Is(Some(Start))) |> ignore
    provider_logo_node(root, "claude", "opencode-go", 24.0, "") |> ignore
  })
  t.draw()
  assert_eq(edge_round(t, 12.0, 12.0), (1.5, @ui.tree_theme().color(Fg)))
}

///|
/// The edge drawn round (x, y) (its width, its colour RRGGBBAA), of the least rect drawn there with one: none, (0, 0).
fn edge_round(t : @ui.Tester, x : Double, y : Double) -> (Double, Int64) {
  let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
  let mut best : (Double, Double, Int64)? = None
  for a in t.drawn_instances() {
    if a[5] == 0.0 && a[6] > 0.0 && a[15] > 0.0 && x >= a[0] && x <= a[0] + a[2] && y >= a[1] && y <= a[1] + a[3] {
      let color = (ch(a[12]) << 24) | (ch(a[13]) << 16) | (ch(a[14]) << 8) | ch(a[15])
      match best {
        Some((area, _, _)) if area <= a[2] * a[3] => ()
        _ => best = Some((a[2] * a[3], a[6], color))
      }
    }
  }
  match best {
    Some((_, w, c)) => (w, c)
    None => (0.0, 0L)
  }
}
