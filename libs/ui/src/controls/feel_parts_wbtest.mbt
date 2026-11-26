// The library's controls answering the hand as data on their timelines: a checkbox's tick drawn by its stroke, a
// switch's capsule drawn longer as it flies, an edge's line drawn aside past its end and back, a full
// bar's running light while it finishes. Each at rest drawn as it is, nothing read of the clock.

///|
/// Moments the tests here look at: a control's answer whole, a flying knob's middle, past every way.
let part_whole_ms : Double = 300.0

///|
let part_mid_ms : Double = 50.0

///|
let part_past_ms : Double = 1500.0

///|
/// `make` alone in a column at the top left of a window 390 by 300, drawn.
fn part_case(make : (@view.View) -> Unit) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lines_up(Is(Some(Start))).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
      make(b)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// How many pieces of lines are drawn (scene's kind 10).
fn line_pieces(t : @ui.Tester) -> Int {
  t.drawn_instances().filter(fn(i) { i[5] == 10.0 }).length()
}

///|
test "a checkbox's tick: whole as it is made on, no words of it; gone as it is turned off; drawn again as it is turned on" {
  let on = @signals.signal(true)
  let t = part_case(fn(b) { check_node(b, fn() { on.get() }, fn(v) { on.set(v) }, fn() { "记住我" }) })
  let first = (line_pieces(t), t.words().length())
  let at = t.semantics().filter(fn(n) { n.role == Checkbox })[0].rect
  let (x, y) = (at.0 + at.2 / 2.0, at.1 + at.3 / 2.0)
  t.tap(x, y)
  t.run_for(part_whole_ms)
  let off = (on.get(), line_pieces(t))
  t.tap(x, y)
  t.run_for(part_whole_ms)
  assert_eq((first.0 > 0, first.1, off, on.get(), line_pieces(t) == first.0, @ui.view_tree().unwrap().cycle_read()), (true, 0, (false, 0), true, true, false))
}

///|
/// The white of a switch's knob as drawn: (w, h).
fn knob_drawn(t : @ui.Tester) -> (Double, Double) {
  match t.drawn_rects().filter(fn(r) { r.4 == 0xFFFFFFFFL }).get(0) {
    Some(r) => (r.2, r.3)
    None => (0.0, 0.0)
  }
}

///|
test "a switch's capsule thumb slides cleanly and keeps its resting dimensions" {
  let on = @signals.signal(false)
  let t = part_case(fn(b) { switch_node(b, fn() { on.get() }, fn(v) { on.set(v) }, fn() { "通知" }) })
  let rest = knob_drawn(t)
  on.set(true)
  t.frame()
  t.run_for(part_mid_ms)
  let flying = knob_drawn(t)
  t.run_for(part_past_ms)
  let there = knob_drawn(t)
  assert_eq((rest.0 > rest.1, (flying.0 - rest.0).abs() < 0.5, there, @ui.view_tree().unwrap().cycle_read()), (true, true, rest, false))
}

///|
test "an edge dragged past its most: its line drawn aside as a string, none at rest; let go, back to none" {
  let w = @signals.signal(160.0)
  let held = @signals.signal(false)
  let pull = EdgePull::new()
  let t = part_case(fn(b) {
    b.box(fn(row) {
      row.row(Is(true)).height(Is(Some(200.0))) |> ignore
      row.box(fn(side) { side.width(By(fn() { Some(w.get()) })) |> ignore }) |> ignore
      row.box(fn(holder) {
        holder.width(Is(Some(handle_w))) |> ignore
        let e = edge_node(holder, fn() { "调整宽度" }, fn() { w.get() }, fn() { 120.0 }, fn() { 220.0 }, Right, fn(said, _) {
          match said {
            Dragging(x) | Dropped(x) => w.set(x)
            _ => ()
          }
        }, fn(h) { held.set(h) }, pull~)
        e.box(fn(g) {
          g.over(Is(true)) |> ignore
          edge_look_node(g, fn() { true }, fn() { held.get() }, fn() { held.get() }, pull~) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  let rest = line_pieces(t)
  let x = 20.0 + 160.0 + handle_w / 2.0
  t.press_at(x, 120.0)
  t.move_to(x + 30.0, 120.0)
  t.move_to(x + 90.0, 120.0)
  t.run_for(part_whole_ms)
  let past = (w.get(), line_pieces(t))
  t.release(x + 90.0, 120.0)
  t.run_for(part_past_ms)
  assert_eq((rest, past.0, past.1 > 0, line_pieces(t)), (0, 220.0, true, 0))
}

///|
test "a bar finishing: full, a light running along it while it is; none of it, nothing read of the clock, once it is not; still and full with motion reduced" {
  let finishing = @signals.signal(true)
  let t = part_case(fn(b) {
    b.box(fn(w) {
      w.width(Is(Some(300.0))) |> ignore
      progress_node(w, fn() { Some(1.0) }, fn() { 0x000000FFL }, fn() { 0x3366CCFFL }, finishing=fn() { finishing.get() }) |> ignore
    })
    |> ignore
  })
  t.run_for(part_whole_ms)
  let tree = @ui.view_tree().unwrap()
  let full = t.drawn_rects().filter(fn(r) { r.4 == 0x3366CCFFL }).map(fn(r) { r.2 })
  let running = tree.cycle_read()
  finishing.set(false)
  t.frame()
  t.run_for(part_whole_ms)
  assert_eq((full, running, tree.cycle_read()), ([300.0], true, false))
}
