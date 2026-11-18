// A mark of a row where the row takes the press (check_mark_node) going between half ticked (its bar), ticked (its
// tick) and not ticked: the bar and the tick are one or the other in the box, never both, so the bar is in the box's
// middle every frame it is drawn and goes at once as the tick comes (2026-11-17: 全选 pressed with two of three accounts
// ticked had the bar pushed 11 down under the tick that came at once, mbui-check 44119674663).

///|
/// The box's ground as drawn (x, y, side) and the bar's rects (as drawn, 2 tall at most and narrower than the box).
fn check_mark_drawn(t : @ui.Tester) -> ((Double, Double, Double), Array[(Double, Double, Double, Double)]) {
  let side = theme().rows.check
  let rects = t.drawn_rects()
  let box = match rects.filter(fn(r) { r.2 == side && r.3 == side }).get(0) {
    Some(r) => (r.0, r.1, side)
    None => (0.0, 0.0, 0.0)
  }
  (box, rects.filter(fn(r) { r.3 > 0.0 && r.3 <= 2.0 && r.2 < side }).map(fn(r) { (r.0, r.1, r.2, r.3) }))
}

///|
/// A frame of 60 a second: how far apart the frames are that the walk below looks at.
let check_mark_frame_ms : Double = 1000.0 / 60.0

///|
/// `on` and `mixed` set to each of `steps` in turn, each walked a frame of 60 a second at a time to past its way; at
/// every frame the bar, if drawn, in the box's middle. What was drawn at rest after each step: (tick's pieces, bars).
fn check_mark_walk(
  on : @signals.Signal[Bool],
  mixed : @signals.Signal[Bool],
  steps : Array[(Bool, Bool)],
) -> Array[(Int, Int)] raise {
  let t = part_case(fn(b) { check_mark_node(b, fn() { on.get() }, mixed=fn() { mixed.get() }) })
  let rested = []
  for s in steps {
    on.set(s.0)
    mixed.set(s.1)
    let mut ms = 0.0
    while ms < @ui.move_most_ms + check_mark_frame_ms * 6.0 {
      t.run_for(check_mark_frame_ms)
      ms = ms + check_mark_frame_ms
      let (box, bars) = check_mark_drawn(t)
      for bar in bars {
        let off = bar.1 + bar.3 / 2.0 - (box.1 + box.2 / 2.0)
        assert_true(off.abs() <= 0.5, msg="\{Repr(s)} at \{ms}: the bar \{Repr(bar)} \{off} off the middle of \{Repr(box)}")
      }
    }
    rested.push((line_pieces(t), check_mark_drawn(t).1.length()))
  }
  rested
}

///|
test "a check mark from half ticked to ticked and back: the bar in the box's middle every frame, gone as the tick comes" {
  let on = @signals.signal(false)
  let mixed = @signals.signal(true)
  let rested = check_mark_walk(on, mixed, [(true, false), (false, true), (true, false), (false, true)])
  assert_eq(rested.map(fn(r) { (r.0 > 0, r.1) }), [(true, 0), (false, 1), (true, 0), (false, 1)])
}

///|
test "a check mark from half ticked to not ticked and back: the bar in the box's middle every frame" {
  let on = @signals.signal(false)
  let mixed = @signals.signal(true)
  let rested = check_mark_walk(on, mixed, [(false, false), (false, true), (false, false), (true, false), (false, true)])
  assert_eq(rested.map(fn(r) { (r.0 > 0, r.1) }), [(false, 0), (false, 1), (false, 0), (true, 0), (false, 1)])
}
