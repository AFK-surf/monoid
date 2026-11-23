// What a node holds revealed in the paint (@view.View::spatial_reveal, spatial_reveal_paint.mbt): a column of words and
// a rule under them, all of it nothing at its start, each thing in at its own turn down what shows and along it, all
// of it as it rests once its way is over; nothing of its words made again meanwhile (view_painted's `made`), asking for
// nothing once it is over, nor where it is out of what shows; the moment it is all in no later however much shows.

///|
/// How long the column's reveal takes at most (spatial_reveal's defaults: what shows in 500, a line's 120, half a
/// glyph's turn either way of 50, each thing's 220).
let sr_most_ms : Double = 500.0 + 120.0 + 25.0 + 220.0

///|
/// How far into its way the first line's first glyphs are in or coming and the last line's not yet: less than a line's turn
/// past a glyph's, far short of all of it.
let sr_early_ms : Double = 200.0

///|
/// A frame's time at 60 a second, and a line's turn (View::spatial_reveal's `line_ms`): steps along its way.
let sr_frame_ms : Double = 16.0

///|
let sr_line_ms : Double = 120.0

///|
/// The least step the clock takes: from the moment before its way is over to that moment.
let sr_last_ms : Double = 1.0

///|
/// The rule's ink: what tells it among what is drawn.
let sr_rule : Int64 = 0xFF336699L

///|
/// `lines` lines of words in a column 300 wide, `top` down the window, a rule 4 tall under them; revealed from the
/// moment `from` says (less than 0: as it rests), by salt 3.
fn sr_tester(from : @signals.Signal[Double], top? : Double = 0.0, lines? : Int = 3, h? : Double = 300.0) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h~)
  t.check_looks(false)
  let words = Array::makei(lines, fn(i) { "line \{i} of the words" }).join("\n")
  set_view_app(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(col) {
      col.width(Is(Some(300.0))).margin(Is((0.0, top, 0.0, 0.0))).spatial_reveal(By(fn() { from.get() }), salt=Is(3)) |> ignore
      col.box(fn(w) { w.words(Is(words)) |> ignore }) |> ignore
      col.box(fn(r) { r.width(Is(Some(200.0))).height(Is(Some(4.0))).ground(Is(sr_rule)) |> ignore }) |> ignore
    })
    |> ignore
  })
  t
}

///|
/// How opaque each glyph drawn in the last frame is, and the rule, to a hundredth; and how far down the first glyph is.
fn sr_seen(t : Tester) -> (Array[Double], Double, Double) {
  let all = t.drawn_instances_keyed()
  let glyphs = all.filter(fn(a) { a[5] == 1.0 })
  let rule = all.filter(fn(a) { a[5] == 0.0 && a[3] == 4.0 }).map(fn(a) { (a[11] * 100.0).round() / 100.0 })
  (
    glyphs.map(fn(a) { (a[11] * 100.0).round() / 100.0 }),
    rule.get(0).unwrap_or(-1.0),
    glyphs.get(0).map_or(-1.0, fn(a) { (a[1] * 100.0).round() / 100.0 }),
  )
}

///|
test "a column revealed in the paint: nothing of what shows at its start, each glyph and the rule at its own turn, all of it as it rests once over, asking for nothing then" {
  let from = @signals.signal(-1.0)
  let t = sr_tester(from)
  t.draw()
  let (rest, rule_rest, top_rest) = sr_seen(t)
  assert_true(rest.length() > 20 && rest.iter().all(fn(a) { a > 0.0 }), msg="\{Repr(rest)}")
  assert_eq(t.idle_said(), None)
  // (from now: nothing of it at its start, none of it drawn at all (its reveal not begun: @view.Tree::each_drawn_in_order
  // has it unseen) or drawn unseen)
  from.set(t.time())
  t.draw()
  let (start, rule_start, _) = sr_seen(t)
  assert_true(start.iter().all(fn(a) { a == 0.0 }) && (rule_start == 0.0 || rule_start == -1.0), msg="\{Repr(start)} \{rule_start}")
  // (on its way: the first line's first glyphs in or coming, the last line's not yet; the rule under them not yet)
  t.run_for(sr_early_ms)
  let (mid, rule_mid, top_mid) = sr_seen(t)
  assert_true(mid[0] > 0.0 && mid[mid.length() - 1] == 0.0, msg="\{Repr(mid)}")
  assert_eq(rule_mid, 0.0)
  // (a glyph on its way risen less than all the way: drawn lower than it rests while it comes)
  assert_true(mid[0] == rest[0] || top_mid > top_rest, msg="\{top_mid} \{top_rest}")
  // (its way over: all of it as it rests, and nothing asked for)
  t.run_for(sr_most_ms)
  let (end, rule_end, top_end) = sr_seen(t)
  assert_eq((end, rule_end, top_end), (rest, rule_rest, top_rest))
  assert_eq(t.idle_said(), None)
}

///|
test "a column revealed in the paint makes none of its words again on its way: each frame draws what it made as kept" {
  let from = @signals.signal(-1.0)
  let t = sr_tester(from)
  t.draw()
  from.set(t.time())
  t.run_for(sr_frame_ms)
  let made = view_painted().made
  t.run_for(sr_line_ms)
  t.run_for(sr_line_ms)
  assert_eq(view_painted().made, made)
}

///|
test "a column revealed out of what shows: as it rests, asking for nothing" {
  let from = @signals.signal(-1.0)
  let t = sr_tester(from, top=500.0)
  t.draw()
  from.set(t.time())
  t.draw()
  assert_eq(t.idle_said(), None)
}

///|
test "a column revealed with many lines showing all in by the same moment as a few: each line's turn shorter" {
  for lines in [3, 30] {
    let from = @signals.signal(-1.0)
    let t = sr_tester(from, lines~, h=844.0)
    t.draw()
    let (rest, _, _) = sr_seen(t)
    from.set(t.time())
    t.run_for(sr_most_ms - sr_last_ms)
    let (late, _, _) = sr_seen(t)
    // (all but the last few on their way's end by then; all of it at its end)
    assert_true(late.filter(fn(a) { a == 0.0 }).length() == 0, msg="\{lines} lines: \{Repr(late)}")
    t.run_for(sr_last_ms)
    let (end, _, _) = sr_seen(t)
    assert_eq(end, rest, msg="\{lines} lines")
  }
}
