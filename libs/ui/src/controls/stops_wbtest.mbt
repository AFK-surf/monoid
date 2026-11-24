// The stops as nodes (stops_node): single-row standard pill slider (6pt track, 38x24 pure white capsule thumb) paired
// with a fixed-width right-side label showing only the current/preview stop name.

///|
/// A phone's window with the stops of `labels` in it as nodes (stops_node), at `chosen` as its caller says; what was
/// picked in it, in order.
fn stops_run(labels : Array[String], chosen : @signals.Signal[Int], state : Stops, picks : Array[Int]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=360.0, h=200.0, platform=2)
  @ui.set_view_app(fn(root) {
    root.padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
    // (in a row, as a page's row has it: across the rest of it)
    root.box(fn(r) {
      r.row(Is(true)) |> ignore
      stops_node(r, fn() { labels }, fn() { chosen.get() }, state, said="思考深度", on_pick=fn(i) { picks.push(i) })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// What its caller does at the window's moment, as an event: says another level, or that a pick did not take.
fn stops_told(t : @ui.Tester, f : () -> Unit) -> Unit {
  @ui.view_tree().unwrap().event(t.time(), f)
}

///|
/// Which of `labels` are drawn.
fn stops_named(t : @ui.Tester, labels : Array[String]) -> Array[String] {
  labels.filter(fn(l) { t.words().iter().any(fn(w) { w.0 == l }) })
}

///|
test "stops: every level a stop on one line, the one it is at alone named; a stop tapped is picked, said once, and stays shown while its caller still says the level before" {
  let labels = ["低", "中", "高", "最高"]
  let (chosen, state, picks) = (@signals.signal(2), Stops::new(), [])
  let t = stops_run(labels, chosen, state, picks)
  let s = t.get(@ui.Role::Slider, label="思考深度")
  assert_eq(s.value, "高")
  assert_eq(stops_named(t, labels), ["高"])
  // (its name on the same single row to the right of the slider track)
  let (x, y, w, h) = s.rect
  let (nx, ny, nw, nh) = t.rect_of("高").unwrap()
  assert_true(
    nx >= x + w && ny >= y - 2.0 && ny + nh <= y + h + 2.0,
    msg="\{Repr((nx, ny, nw, nh))} beside \{Repr(s.rect)}",
  )
  // its last stop tapped
  t.tap(x + w - w / 8.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(picks, [3])
  assert_eq(stops_named(t, labels), ["最高"])
  assert_eq(t.get(@ui.Role::Slider, label="思考深度").value, "最高")
  // (its caller's save answered before its value is told: it says the level before for a while yet)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq(stops_named(t, labels), ["最高"], msg="taken back to what its caller still says")
  // said back, then another level from elsewhere: news, shown
  stops_told(t, fn() { chosen.set(3) })
  t.draw()
  stops_told(t, fn() { chosen.set(1) })
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq(stops_named(t, labels), ["中"])
  assert_eq(picks, [3], msg="what its caller says is not a pick")
  assert_eq(t.squeeze_faults(), [])
}

///|
test "stops: a finger takes its thumb along the track, nothing picked on the way; let go, the level under the finger is picked" {
  let labels = ["低", "中", "高", "最高"]
  let (chosen, state, picks) = (@signals.signal(2), Stops::new(), [])
  let t = stops_run(labels, chosen, state, picks)
  let (x, y, w, h) = t.get(@ui.Role::Slider, label="思考深度").rect
  let at = fn(i : Int) { dclamp(x + w * i.to_double() / 3.0, x + 2.0, x + w - 2.0) }
  let mid = y + h / 2.0
  // down on the stop it is at, along to its first: the stop under the finger named as it goes, none picked
  t.touch(0, at(2), mid)
  t.frame()
  t.touch(1, at(1), mid)
  t.frame()
  assert_eq(picks, [])
  t.touch(1, at(0), mid)
  t.run_for(@ui.move_most_ms)
  assert_eq(picks, [])
  assert_eq(stops_named(t, labels), ["低"])
  // let go there
  t.touch(2, at(0), mid)
  t.run_for(@ui.move_most_ms)
  assert_eq(picks, [0])
  assert_eq(stops_named(t, labels), ["低"])
}

///|
test "stops: blank track Down -> Moved -> Up commits once, Down -> Off commits zero times and reverts" {
  let labels = ["低", "中", "高", "最高"]
  let (chosen, state, picks) = (@signals.signal(2), Stops::new(), [])
  let t = stops_run(labels, chosen, state, picks)
  let (x, y, w, h) = t.get(@ui.Role::Slider, label="思考深度").rect
  let mid = y + h / 2.0
  // Down on blank track at stop 0: preview updates, zero commit
  t.touch(0, x + 8.0, mid)
  t.run_for(part_whole_ms)
  assert_eq(picks, [], msg="blank track Down must not commit")
  assert_eq(stops_named(t, labels), ["低"])
  assert_eq(t.get(@ui.Role::Slider, label="思考深度").value, "高")
  // Moved across to last stop: preview updates, still zero commit
  t.touch(1, x + w * 0.5, mid)
  t.run_for(part_whole_ms)
  assert_eq(picks, [], msg="Moved mid must not commit")
  t.touch(1, x + w - 8.0, mid)
  t.run_for(@ui.move_most_ms)
  assert_eq(picks, [], msg="Moved must not commit")
  assert_eq(stops_named(t, labels), ["最高"])
  // Up commits exactly once
  t.touch(2, x + w - 8.0, mid)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(picks, [3], msg="Up must commit exactly once")
  assert_eq(stops_named(t, labels), ["最高"])
  assert_eq(t.get(@ui.Role::Slider, label="思考深度").value, "最高")
  let thumb_x = fn() {
    t.drawn_rects().filter(fn(r) { r.4 == 0xFFFFFFFFL && (r.3 - 24.0).abs() < 0.5 }).map(fn(r) { r.0 })
  }
  let committed_x = thumb_x()[0]
  // Down on blank track at stop 0, then Off (cancel): zero commit, reverts to stop 3
  t.touch(0, x + 8.0, mid)
  t.run_for(part_whole_ms)
  assert_eq(picks, [3], msg="second Down must not commit")
  assert_eq(stops_named(t, labels), ["低"])
  t.touch(3, x + 8.0, mid)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(picks, [3], msg="Off cancel must not commit")
  assert_eq(stops_named(t, labels), ["最高"], msg="Off must revert preview label to committed stop")
  assert_eq(t.drawn_glass().length(), 0, msg="Off must release lens")
  assert_true((thumb_x()[0] - committed_x).abs() < 0.5, msg="Off must revert thumb to committed stop")
}

///|
test "stops: at none of its levels, a stop tapped stays shown while its caller still says none; its caller's reset takes it back to none" {
  let labels = ["低", "中", "高", "最高"]
  let (chosen, state, picks) = (@signals.signal(-1), Stops::new(), [])
  let t = stops_run(labels, chosen, state, picks)
  assert_eq(stops_named(t, labels), [])
  let (x, y, w, h) = t.get(@ui.Role::Slider, label="思考深度").rect
  t.tap(x + w * 2.5 / 4.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(picks, [2])
  // (its caller's save answered before its value is told: it says none for a while yet)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq(stops_named(t, labels), ["高"], msg="taken back to none while its save is on its way")
  // kept none of it
  stops_told(t, fn() { state.reset() })
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq(stops_named(t, labels), [])
}

///|
test "stops: a pick that did not take (its caller's reset) shows what its caller says again" {
  let labels = ["低", "中", "高", "最高"]
  let (chosen, state, picks) = (@signals.signal(1), Stops::new(), [])
  let t = stops_run(labels, chosen, state, picks)
  let (x, y, w, h) = t.get(@ui.Role::Slider, label="思考深度").rect
  t.tap(x + w - w / 8.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(stops_named(t, labels), ["最高"])
  stops_told(t, fn() { state.reset() })
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq(stops_named(t, labels), ["中"])
}

///|
test "stops: seven levels with long names on a narrow phone: still one line, current label whole beside slider" {
  let labels = ["Minimal", "Low", "Medium", "High", "Very high", "Maximum", "Ultra"]
  let (chosen, state, picks) = (@signals.signal(4), Stops::new(), [])
  let t = stops_run(labels, chosen, state, picks)
  t.resize(320.0, 200.0)
  t.draw()
  t.run_for(@ui.move_most_ms)
  let (x, y, w, h) = t.get(@ui.Role::Slider, label="思考深度").rect
  assert_eq(t.lines_of("Very high"), ["Very high"])
  let (nx, ny, nw, nh) = t.rect_of("Very high").unwrap()
  assert_true(
    nx >= x + w && ny >= y - 2.0 && ny + nh <= y + h + 2.0,
    msg="\{Repr((nx, ny, nw, nh))} beside \{Repr((x, y, w, h))}",
  )
  assert_true(h <= 44.5, msg="\{h} high: more than a line")
  assert_true(w > @glass.slider_thumb_w, msg="slider track width \{w} must exceed thumb width")
  assert_eq(stops_named(t, labels), ["Very high"])
  assert_eq(t.squeeze_faults(), [])
}

///|
test "stops: 320pt + 1.3x + ultra-long custom stop name keeps track > 38pt and drags to first and last stops" {
  let long_name = "Supercalifragilisticexpialidocious Extreme Thinking Level"
  let labels = ["低", "中", long_name, "最高"]
  let chosen = @signals.signal(1)
  let state = Stops::new()
  let picks : Array[Int] = []
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=200.0, platform=2, scale=1.3)
  @ui.set_view_app(fn(root) {
    root.padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
    root.box(fn(r) {
      r.row(Is(true)) |> ignore
      stops_node(r, fn() { labels }, fn() { chosen.get() }, state, said="思考深度", on_pick=fn(i) { picks.push(i) })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  let (x, y, w, h) = t.get(@ui.Role::Slider, label="思考深度").rect
  assert_true(w > 38.0, msg="320pt + 1.3x + long name must keep track width > 38pt, got \{w}")
  assert_eq(t.squeeze_faults(), [])
  let mid = y + h / 2.0
  let stop_x = fn(i : Int) { x + @glass.slider_thumb_w / 2.0 + (w - @glass.slider_thumb_w) * i.to_double() / 3.0 }
  // Drag smoothly to first stop (0)
  t.touch(0, stop_x(1), mid)
  t.frame()
  t.touch(1, stop_x(0), mid)
  t.frame()
  t.touch(2, stop_x(0), mid)
  t.run_for(@ui.move_most_ms)
  assert_eq(picks, [0])
  assert_eq(t.get(@ui.Role::Slider, label="思考深度").value, "低")
  // Drag to the ultra-long stop (2): screen-reader value keeps full untruncated name
  t.touch(0, stop_x(0), mid)
  t.frame()
  t.touch(1, stop_x(2), mid)
  t.frame()
  t.touch(2, stop_x(2), mid)
  t.run_for(@ui.move_most_ms)
  assert_eq(picks, [0, 2])
  assert_eq(t.get(@ui.Role::Slider, label="思考深度").value, long_name)
  // Drag to last stop (3)
  t.touch(0, stop_x(2), mid)
  t.frame()
  t.touch(1, stop_x(3), mid)
  t.frame()
  t.touch(2, stop_x(3), mid)
  t.run_for(@ui.move_most_ms)
  assert_eq(picks, [0, 2, 3])
  assert_eq(t.get(@ui.Role::Slider, label="思考深度").value, "最高")
}

///|
test "stops_node: discrete keyboard switch uses critically damped spring without overshoot" {
  let labels = ["低", "中", "高", "极高"]
  let chosen = @signals.signal(0)
  let state = Stops::new()
  let t = @ui.Tester::new(fn(_c) {  }, w=360.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
    stops_node(root, fn() { labels }, fn() { chosen.get() }, state, said="思考深度", on_pick=fn(i) { chosen.set(i) })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  let thumb_x = fn() {
    let raised = theme().p.raised
    t.drawn_rects().iter().find_first(fn(r) { r.4 == raised }).map(fn(r) { r.0 }).unwrap_or(-1.0)
  }
  let x0 = thumb_x()
  // Switch from 0 -> 2 via keyboard focus + Right twice
  t.act(@ui.Role::Slider, Focus, label="思考深度")
  t.key(@ui.key_code_right)
  t.key(@ui.key_code_right)
  // Find target settled x2 first by sampling trajectory and checking monotonicity / no overshoot past settled x2
  let xs : Array[Double] = []
  let step = @ui.move_most_ms / 30.0
  for _ in 0..<30 {
    t.run_for(step)
    xs.push(thumb_x())
  }
  t.run_for(@ui.move_most_ms)
  let x2 = thumb_x()
  assert_true(x2 > x0 + 20.0, msg="moved right: x0=\{x0}, x2=\{x2}")
  for x in xs {
    assert_true(x >= x0 - 0.05 && x <= x2 + 0.05, msg="stops_node discrete switch overshot [\{x0}, \{x2}]: x=\{x}")
  }
}

///|
test "stops_node: lens scale animation has laid == 0; cross-stop drag updates label with zero slider/sibling shift" {
  let labels = ["低", "中", "高", "极高"]
  let chosen = @signals.signal(1)
  let state = Stops::new()
  let t = @ui.Tester::new(fn(_c) {  }, w=360.0, h=200.0, platform=2)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
    root.box(fn(r) {
      r.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
      words_node(r, fn() { "思考深度" }, fn() { stops_label_words }) |> ignore
      stops_node(r, fn() { labels }, fn() { chosen.get() }, state, said="思考深度", on_pick=fn(i) { chosen.set(i) })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  let sl_before = t.get(@ui.Role::Slider, label="思考深度").rect
  let sib_before = t.rect_of("思考深度").unwrap()
  let (x, y, w, h) = sl_before
  let mid = y + h / 2.0
  let lens_step_ms = @ui.move_most_ms / 2.0
  t.touch(0, x + w * 1.0 / 3.0, mid)
  t.draw()
  t.tree_frames_from_now()
  t.run_for(lens_step_ms)
  let frames = t.tree_frames()
  assert_true(frames.length() > 0, msg="expected animation frames while lens scales")
  assert_true(
    frames.iter().all(fn(f) { f.laid == 0 }),
    msg="stops_node lens animation must not trigger relayout: \{Repr(frames.map(fn(f) { f.laid }))}",
  )
  // Cross stop to "极高": right label updates while slider and sibling rects stay pixel-identical
  t.touch(1, x + w - 4.0, mid)
  t.frame()
  assert_eq(stops_named(t, labels), ["极高"])
  let sl_after = t.get(@ui.Role::Slider, label="思考深度").rect
  let sib_after = t.rect_of("思考深度").unwrap()
  assert_eq(sl_after, sl_before, msg="slider rect must not shift on cross-stop label update")
  assert_eq(sib_after, sib_before, msg="sibling rect must not shift on cross-stop label update")
  t.touch(2, x + w - 4.0, mid)
  t.run_for(@ui.move_most_ms * 2.0)
}

///|
test "stops_node: light/dark 38x24 white pill, 0 hidden glass at rest, kind==6 held, glass_solid degrades cleanly" {
  for dark in [false, true] {
    set_dark(Some(dark))
    @ui.set_glass_solid(None)
    let labels = ["低", "中", "高", "极高"]
    let chosen = @signals.signal(1)
    let state = Stops::new()
    let t = @ui.Tester::new(fn(_c) {  }, w=360.0, h=200.0, dark~, platform=2)
    t.check_looks(false)
    @ui.set_view_app(
      fn(root) {
        root.padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
        stops_node(root, fn() { labels }, fn() { chosen.get() }, state, said="思考深度", on_pick=fn(i) { chosen.set(i) })
        |> ignore
      },
      theme=ui_theme_now,
    )
    t.draw()
    t.run_for(@ui.move_most_ms)
    // Rest: zero hidden glass instances and pure white 38x24 capsule thumb in both light and dark modes.
    assert_eq(t.drawn_glass().length(), 0, msg="stops_node rest must draw 0 glass (dark=\{dark})")
    let white_pills = t.drawn_rects().filter(fn(r) {
      r.4 == 0xFFFFFFFFL && (r.2 - @glass.slider_thumb_w).abs() < 0.5 && (r.3 - @glass.slider_thumb_h).abs() < 0.5
    })
    assert_eq(white_pills.length(), 1, msg="stops_node rest must draw 1 pure white 38x24 pill thumb (dark=\{dark})")
    let (x, y, w, h) = t.get(@ui.Role::Slider, label="思考深度").rect
    let mid = y + h / 2.0
    t.touch(0, x + w * 1.0 / 3.0, mid)
    t.run_for(part_whole_ms)
    let pressed_glass = t.drawn_glass()
    assert_eq(pressed_glass.length(), 1, msg="stops_node held must draw 1 glass lens (dark=\{dark})")
    assert_eq(pressed_glass[0].4, 6, msg="stops_node lens must be kind == 6")
    t.touch(2, x + w * 1.0 / 3.0, mid)
    t.run_for(@ui.move_most_ms * 2.0)
    assert_eq(t.drawn_glass().length(), 0, msg="stops_node settled must return to 0 glass (dark=\{dark})")
    // glass_solid degradation: 0 glass even while held, solid white 38x24 pill stays.
    @ui.set_glass_solid(Some(true))
    t.touch(0, x + w * 1.0 / 3.0, mid)
    t.run_for(part_whole_ms)
    assert_eq(t.drawn_glass().length(), 0, msg="stops_node glass_solid held must draw 0 glass (dark=\{dark})")
    let solid_pills = t.drawn_rects().filter(fn(r) {
      r.4 == 0xFFFFFFFFL && (r.2 - @glass.slider_thumb_w).abs() < 0.5 && (r.3 - @glass.slider_thumb_h).abs() < 0.5
    })
    assert_eq(solid_pills.length(), 1, msg="stops_node glass_solid held must keep 38x24 white pill (dark=\{dark})")
    t.touch(2, x + w * 1.0 / 3.0, mid)
    t.run_for(@ui.move_most_ms * 2.0)
    @ui.set_glass_solid(None)
  }
  set_dark(None)
}

///|
test "stops: 6pt track, solid accent fill, 38x24 white capsule flush at ends, even stop spacing and interior dots" {
  let labels = ["低", "中", "高", "超高", "最高"]
  let (chosen, state, picks) = (@signals.signal(0), Stops::new(), [])
  let t = stops_run(labels, chosen, state, picks)
  let (x, _, w, h) = t.get(@ui.Role::Slider, label="思考深度").rect
  assert_true((h - @glass.slider_thumb_h).abs() < 0.5, msg="slider height must be 24pt, got \{h}")
  let middles = []
  let widths = []
  let thumb = fn() {
    t.drawn_rects().filter(fn(r) { r.4 == 0xFFFFFFFFL && (r.3 - @glass.slider_thumb_h).abs() < 0.5 }).map(fn(r) {
      (r.0, r.2)
    })
  }
  for i in 0..<labels.length() {
    stops_told(t, fn() { chosen.set(i) })
    t.draw()
    t.run_for(@ui.move_most_ms)
    let th = thumb()
    assert_eq(th.length(), 1, msg="\{Repr(t.drawn_rects())}")
    let (tx, tw) = th[0]
    assert_true((tw - @glass.slider_thumb_w).abs() < 0.5, msg="thumb width must be 38pt, got \{tw}")
    middles.push(tx + tw / 2.0)
    widths.push(tw)
    assert_eq(stops_named(t, labels), [labels[i]])
    // (meeting the track's start at the first stop and its end at the last, a stop's middle its own)
    if i == 0 {
      assert_true((tx - x).abs() < 0.5, msg="first stop's thumb at \{tx}, the track at \{x}")
      // (no fill at the first stop: 6pt track alone, its round end under the thumb's)
      let bars = t.drawn_rects().filter(fn(r) { (r.3 - @glass.slider_track_h).abs() < 0.5 && r.2 > 0.0 && (r.4 & 0xFFL) > 0L })
      assert_eq(bars.length(), 1, msg="\{Repr(bars)}")
      assert_true(bars[0].0 >= tx + 3.0, msg="track from \{bars[0].0}, the thumb from \{tx}")
    }
    if i == labels.length() - 1 {
      assert_true((tx + tw - x - w).abs() < 0.5, msg="last stop's thumb to \{tx + tw}, the track to \{x + w}")
      let track = t.drawn_rects().filter(fn(r) { (r.3 - @glass.slider_track_h).abs() < 0.5 && r.2 > w / 2.0 })
      assert_true(track.iter().all(fn(r) { r.0 + r.2 <= tx + tw - 3.0 }), msg="\{Repr(track)} past the thumb to \{tx + tw}")
      // (solid accent fill under the thumb, full opacity, not 0.45 translucent)
      let accent = theme().p.accent
      assert_true(
        track.iter().any(fn(r) { r.4 == accent && r.0 + r.2 >= tx + 3.0 && r.0 + r.2 < x + w - 5.0 }),
        msg="expected solid accent fill \{accent} in \{Repr(track)}",
      )
    }
  }
  assert_true(widths.iter().all(fn(tw) { (tw - widths[0]).abs() < 0.01 }), msg="\{Repr(widths)}")
  let step = (middles[labels.length() - 1] - middles[0]) / (labels.length() - 1).to_double()
  for i in 0..<labels.length() {
    let want = middles[0] + step * i.to_double()
    assert_true((middles[i] - want).abs() < 0.5, msg="stop \{i} at \{middles[i]}, not \{want}: \{Repr(middles)}")
  }
  // (a dot of each stop between the ends under where the thumb's middle is on it)
  let dots = t.drawn_rects().filter(fn(r) { r.2 == 4.0 && r.3 == 4.0 }).map(fn(r) { r.0 + 2.0 })
  assert_eq(dots.length(), labels.length() - 2)
  for i in 1..<(labels.length() - 1) {
    assert_true(dots.iter().any(fn(d) { (d - middles[i]).abs() < 0.5 }), msg="stop \{i} \{middles[i]}: dots \{Repr(dots)}")
  }
}

///|
test "stops: held and dragged fast, its thumb drawn whole down a box that cuts what is past it, as a sheet that scrolls does" {
  let labels = ["低", "中", "高", "超高", "最高"]
  let chosen = @signals.signal(4)
  let state = Stops::new()
  let t = @ui.Tester::new(fn(_c) {  }, w=360.0, h=200.0, platform=2)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
    root.box(fn(cut) {
      cut.clip() |> ignore
      cut.box(fn(r) {
        r.row(Is(true)) |> ignore
        stops_node(r, fn() { labels }, fn() { chosen.get() }, state, said="思考深度", on_pick=fn(i) { chosen.set(i) })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  let (x, y, w, h) = t.get(@ui.Role::Slider, label="思考深度").rect
  let mid = y + h / 2.0
  let whole = fn(at : String) raise {
    let drawn = t.drawn_glass()
    let cut = t.drawn_glass_cut()
    assert_eq(drawn.length(), cut.length(), msg="\{at}: \{Repr(drawn)} cut to \{Repr(cut)}")
    for i, g in drawn {
      let (_, cy, _, ch) = cut[i]
      assert_true(
        (cy - g.1).abs() < 0.01 && (ch - g.3).abs() < 0.01,
        msg="\{at}: \{Repr(g)} cut to \{Repr(cut[i])}",
      )
    }
  }
  t.touch(0, x + w - 20.0, mid)
  t.run_for(@ui.move_most_ms)
  whole("held")
  // (along to its first stop fast: the thumb squeezed tallest by how fast it goes)
  let xs = [x + w * 0.6, x + w * 0.3, x + 10.0]
  for to in xs {
    t.touch(1, to, mid)
    t.frame()
    whole("dragged to \{to}")
  }
  t.touch(2, x + 10.0, mid)
  t.run_for(@ui.move_most_ms * 2.0)
  assert_eq(chosen.get(), 0)
}
