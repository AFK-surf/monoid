///|
/// A progress bar as nodes (progress_node), 200 wide, at how far `part` says.
fn progress_tester(part : @signals.Signal[Double?]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=300.0, h=100.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(200.0))) |> ignore
      progress_node(b, fn() { part.get() }, fn() { @ui.tree_theme().line }, fn() { theme().p.accent }).width_share(
        Is(1.0),
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The pieces of the bar drawn (x, width), the track's first: what is seen of each 3 high, within its track (200 wide).
fn progress_drawn(t : @ui.Tester) -> Array[(Int, Int)] {
  let out = []
  for r in t.drawn_rects() {
    let (x, _, w, h, _) = r
    let x0 = dmax(x, 0.0)
    let x1 = dmin(x + w, 200.0)
    if h != 3.0 || x1 - x0 < 0.5 {
      continue
    }
    out.push(((x0 * 10.0).round().to_int(), ((x1 - x0) * 10.0).round().to_int()))
  }
  out
}

///|
/// What the bar says, as read out (its value, its range) and as the host is told it (its range's least, where it is,
/// its most: a11y_lines' fields 12 to 14): checked to be `value` and `range` both.
fn progress_said(t : @ui.Tester, value : String, range : (Double, Double, Double)?) -> Unit raise {
  let bars = t.all(ProgressBar)
  assert_eq(bars.length(), 1, msg="bar read out")
  assert_eq((bars[0].value, bars[0].range), (value, range), msg="read out: \{bars[0].value} \{Repr(bars[0].range)}")
  let told = t.ctx().a11y_lines().split("\n").filter(fn(l) { l.contains("ProgressBar") }).to_array()
  assert_eq(told.length(), 1, msg="told the host")
  let want = match range {
    Some((lo, at, hi)) => [lo.to_string(), at.to_string(), hi.to_string()]
    None => ["", "", ""]
  }
  let f = told[0].split("\u{1F}").map(fn(v) { v.to_owned() }).to_array()
  assert_eq([f[12], f[13], f[14]], want, msg="told the host: \{f[12]} \{f[13]} \{f[14]}")
}

///|
/// What the nodes' bar says as read out now (its value, its range), no frame drawn for it.
fn node_said(t : @ui.Tester) -> (String, (Double, Double, Double)?) {
  let bars = t.all(ProgressBar)
  if bars.length() != 1 {
    return ("\{bars.length()} bars", None)
  }
  (bars[0].value, bars[0].range)
}

///|
test "a progress bar as nodes drawn and read out: at a part, gone on to another over progress_ms, then not known (a sweeping wait), then known again" {
  let part : @signals.Signal[Double?] = @signals.signal(Some(0.25), same=fn(a, b) { a == b })
  let t = progress_tester(part)
  assert_eq(progress_drawn(t), [(0, 2000), (0, 500)], msg="at a quarter")
  progress_said(t, "25%", Some((0.0, 25.0, 100.0)))
  part.set(Some(0.75))
  assert_eq(node_said(t), ("75%", Some((0.0, 75.0, 100.0))), msg="told: said at once, no frame drawn")
  t.draw()
  t.run_for(@motion.progress_ms / 2.0)
  let mid = progress_drawn(t)
  assert_true(mid.length() == 2 && mid[1].1 > 500 && mid[1].1 < 1500, msg="half way to three quarters: \{Repr(mid)}")
  progress_said(t, "75%", Some((0.0, 75.0, 100.0)))
  t.run_for(@motion.progress_ms)
  assert_eq(progress_drawn(t), [(0, 2000), (0, 1500)], msg="at three quarters")
  part.set(None)
  assert_eq(node_said(t), ("", None), msg="not known: said at once, no frame drawn")
  t.draw()
  t.run_for(@motion.progress_known_ms)
  progress_said(t, "", None)
  let tree = @ui.view_tree().unwrap()
  assert_true(tree.cycle_read(), msg="not known: a wait read by the clock")
  assert_true(!tree.clock_read(), msg="no motion")
  let swept0 = progress_drawn(t)
  t.run_for(@motion.progress_sweep_ms / 3.0)
  let swept1 = progress_drawn(t)
  assert_true(swept1 != swept0, msg="not known sweeps")
  part.set(Some(0.5))
  assert_eq(node_said(t), ("50%", Some((0.0, 50.0, 100.0))), msg="known again: said at once, no frame drawn")
  t.draw()
  t.run_for(@motion.progress_known_ms)
  assert_eq(progress_drawn(t), [(0, 2000), (0, 1000)], msg="known again, at half")
  progress_said(t, "50%", Some((0.0, 50.0, 100.0)))
  assert_true(!tree.cycle_read() && !tree.clock_read(), msg="known and there: nothing reads the clock")
}

///|
test "a progress bar as nodes, motion reduced: a part told anew there in the first frame, not known and known again there at once, nothing read of the clock after any of them" {
  @ui.set_motion_chosen(Some(true))
  let part : @signals.Signal[Double?] = @signals.signal(Some(0.25), same=fn(a, b) { a == b })
  let t = progress_tester(part)
  let tree = @ui.view_tree().unwrap()
  let seen : Array[(String, Array[(Int, Int)], Bool)] = []
  for step in [("three quarters", Some(0.75)), ("not known", None), ("known again", Some(0.5))] {
    part.set(step.1)
    t.draw()
    seen.push((step.0, progress_drawn(t), tree.clock_read() || tree.cycle_read()))
  }
  @ui.set_motion_chosen(None)
  assert_eq(seen[0].1, [(0, 2000), (0, 1500)])
  assert_true(seen[1].1.length() >= 2)
  assert_eq(seen[2].1, [(0, 2000), (0, 1000)])
  for s in seen {
    assert_true(!s.2, msg="\{s.0}: nothing read of the clock after")
  }
}

///|
test "a progress bar as nodes finishing: read out whole (its most, 100%) as it is drawn full, however far it was told before; done finishing, read out as told again" {
  let part : @signals.Signal[Double?] = @signals.signal(Some(0.4), same=fn(a, b) { a == b })
  let ending = @signals.signal(false)
  let t = @ui.Tester::new(fn(_c) {  }, w=300.0, h=60.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(200.0))) |> ignore
      progress_node(b, fn() { part.get() }, fn() { @ui.tree_theme().line }, fn() { theme().p.accent }, finishing=fn() {
        ending.get()
      }).width_share(Is(1.0))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let said = fn() raise {
    let b = t.get(ProgressBar)
    (b.value, b.range)
  }
  let told = said()
  ending.set(true)
  t.draw()
  let finishing = said()
  ending.set(false)
  part.set(None)
  t.draw()
  let not_known = said()
  assert_eq(told, ("40%", Some((0.0, 40.0, 100.0))))
  assert_eq(finishing, ("100%", Some((0.0, 100.0, 100.0))))
  assert_eq(not_known, ("", None))
}

///|
test "progress_node: determinate animation and indeterminate sweep cause zero relayout (laid == 0)" {
  let part : @signals.Signal[Double?] = @signals.signal(Some(0.2), same=fn(a, b) { a == b })
  let t = @ui.Tester::new(fn(_c) {  }, w=300.0, h=60.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(200.0))) |> ignore
      progress_node(b, fn() { part.get() }, fn() { @ui.tree_theme().line }, fn() { theme().p.accent }).width_share(
        Is(1.0),
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // Determinate progress transition: 0.2 -> 0.8
  part.set(Some(0.8))
  t.draw()
  t.tree_frames_from_now()
  t.run_for(@motion.progress_ms)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="determinate progress relaid out: \{Repr(f)}")
  }
  // Indeterminate sweep
  part.set(None)
  t.draw()
  t.run_for(@motion.progress_known_ms)
  t.tree_frames_from_now()
  t.run_for(@motion.progress_sweep_ms / 2.0)
  for f in t.tree_frames() {
    assert_eq(f.laid, 0, msg="indeterminate sweep relaid out: \{Repr(f)}")
  }
}
