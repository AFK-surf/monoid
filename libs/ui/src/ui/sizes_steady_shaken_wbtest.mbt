// Sizes steady (sizes_steady.mbt) takes where what shakes across on purpose (View::shakes_while: a control refusing a
// press, motion's ShakeWay::shakes) has its left edge drawn, and what it holds, as its shake's while it goes: there and
// back again and again is no jolt along its row then. Its top, its width and its height are judged as ever while it
// shakes, and its left edge once it is over; one shaken so that does not say it is found turning back.

///|
/// A shake there and back across `shake_cycles` times over `shake_ms` from the moment `from` says, 4 points at most,
/// less each swing (as motion's ShakeWay): 0 where it does not go.
let shake_ms : Double = 280.0

///|
let shake_cycles : Double = 3.0

///|
/// How long each case is looked at round its shake (ms): at rest before it is set off, and after a step or its end.
let shake_round_ms : Double = 100.0

///|
fn shake_goes(from : @signals.Signal[Double?], t : Double) -> Bool {
  guard from.get() is Some(s) else { return false }
  t >= s && t < s + shake_ms
}

///|
fn shake_x(from : @signals.Signal[Double?], t : Double) -> Double {
  guard shake_goes(from, t) && from.get() is Some(s) else { return 0.0 }
  let p = (t - s) / shake_ms
  4.0 * (1.0 - p) * @dmath.sin(p * shake_cycles * 2.0 * @math.PI)
}

///|
/// A row in a window 400 by 200: a box as wide as `lead` says, then a box on a ground of its own, as wide as `wide` and
/// as tall as `high` say, holding words, drawn off across by a shake set off at what `from` says, saying it shakes
/// while it goes (View::shakes_while) where `says`. Sizes steady said but not held (its faults read here).
fn shaken_case(
  from : @signals.Signal[Double?],
  lead : @signals.Signal[Double],
  wide : @signals.Signal[Double],
  high : @signals.Signal[Double],
  says : Bool,
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, words_over_held=false)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)) |> ignore
      r.box(fn(b) { b.width(By(fn() { Some(lead.get()) })).height(Is(Some(40.0))) |> ignore }) |> ignore
      r.box(fn(b) {
        let goes = fn(at) { shake_goes(from, at) }
        if says {
          b.shakes_while(goes) |> ignore
        }
        b
        .width(By(fn() { Some(wide.get()) }))
        .height(By(fn() { Some(high.get()) }))
        .ground(Is(0x336699FFL))
        .offset(By(fn() { (shake_x(from, b.drawn_while(goes)), 0.0) }))
        |> ignore
        b.box(fn(w) { w.words(Is("Send")) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// What sizes steady finds in each frame from now on, the display's every `period` ms (each one drawn: a hook on each
/// frame asks for it), down a column and across.
fn shaken_found(t : Tester, period : Double) -> (Array[String], Array[String]) {
  let down = []
  let across = []
  t.set_frame_period(period)
  t.each_frame(
    Some(fn() {
      for f in g().sizes_faults(t.fake.time, t.period) {
        if f.0 {
          across.push(f.1)
        } else {
          down.push(f.1)
        }
      }
    }),
  )
  (down, across)
}

///|
test "sizes steady: what says it shakes across, judged at 60 and 120 a second, none along its row while it shakes nor after; one shaken alike that does not say so, found turning back at 60" {
  // (frames it walks itself, judged by the default run alone: test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  for period in [1000.0 / 60.0, 1000.0 / 120.0] {
    let from = @signals.signal(None)
    let t = shaken_case(from, @signals.signal(100.0), @signals.signal(80.0), @signals.signal(40.0), true)
    let found = shaken_found(t, period)
    t.run_for(shake_round_ms)
    from.set(Some(t.time()))
    t.run_for(shake_ms + shake_round_ms)
    t.each_frame(None)
    assert_eq(found, ([], []))
  }
  // (the same shake, said of nothing, at 60 a second: its turning back again soon found along its row, as main's run at
  // 60 found ShakeWay's before it said so; at 120 its swings are sampled finer and pass the rule)
  let from2 = @signals.signal(None)
  let t2 = shaken_case(from2, @signals.signal(100.0), @signals.signal(80.0), @signals.signal(40.0), false)
  let found2 = shaken_found(t2, 1000.0 / 60.0)
  t2.run_for(shake_round_ms)
  from2.set(Some(t2.time()))
  t2.run_for(shake_ms + shake_round_ms)
  t2.each_frame(None)
  assert_eq(found2.0, [])
  assert_true(
    found2.1.any(fn(f) { f.contains("left edge") && f.contains("sizes_steady_shaken_wbtest.mbt:48") }),
    msg="a shake said of nothing at 60 a second: \{Repr(found2.1)}",
  )
}

///|
test "sizes steady: what shakes across stepping in height or width while it shakes, found; its left edge stepping once the shake is over, found" {
  // (frames it walks itself, judged by the default run alone: test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  let period = 1000.0 / 60.0
  // (its height stepping 40 half way through the shake: found down)
  let from = @signals.signal(None)
  let high = @signals.signal(40.0, same=fn(a, b) { a == b })
  let t = shaken_case(from, @signals.signal(100.0), @signals.signal(80.0), high, true)
  let found = shaken_found(t, period)
  t.run_for(shake_round_ms)
  from.set(Some(t.time()))
  t.run_for(shake_ms / 2.0)
  high.set(80.0)
  t.run_for(shake_ms)
  t.each_frame(None)
  assert_true(found.0.any(fn(f) { f.contains("its height") }), msg="a height step while it shakes: \{Repr(found.0)}")
  // (its width stepping 40 half way through the shake: found across)
  let from2 = @signals.signal(None)
  let wide = @signals.signal(80.0, same=fn(a, b) { a == b })
  let t2 = shaken_case(from2, @signals.signal(100.0), wide, @signals.signal(40.0), true)
  let found2 = shaken_found(t2, period)
  t2.run_for(shake_round_ms)
  from2.set(Some(t2.time()))
  t2.run_for(shake_ms / 2.0)
  wide.set(120.0)
  t2.run_for(shake_ms)
  t2.each_frame(None)
  assert_true(found2.1.any(fn(f) { f.contains("its width") }), msg="a width step while it shakes: \{Repr(found2.1)}")
  // (what is before it in the row stepping 40 once the shake is over: its left edge found stepping)
  let from3 = @signals.signal(None)
  let lead = @signals.signal(100.0, same=fn(a, b) { a == b })
  let t3 = shaken_case(from3, lead, @signals.signal(80.0), @signals.signal(40.0), true)
  let found3 = shaken_found(t3, period)
  t3.run_for(shake_round_ms)
  from3.set(Some(t3.time()))
  t3.run_for(shake_ms + shake_round_ms)
  let during = found3.1.copy()
  lead.set(140.0)
  t3.run_for(shake_round_ms)
  t3.each_frame(None)
  assert_eq(during, [])
  assert_true(
    found3.1.any(fn(f) { f.contains("left edge") && f.contains("sizes_steady_shaken_wbtest.mbt:48") }),
    msg="its left edge stepping after the shake: \{Repr(found3.1)}",
  )
}
