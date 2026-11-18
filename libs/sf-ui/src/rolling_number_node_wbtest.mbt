// A number that rolls (rolling_number_node): the slots whose character stays where they are, still, as it changes; the
// one that changes rolls its new character in from under it as it grows (over it as it falls), the old one out the
// other way; at rest each slot its own character alone, nothing faded.

///|
/// Moments the tests here look at: early in a roll, past it.
let roll_early_ms : Double = 40.0

///|
let roll_past_ms : Double = 2000.0

///|
/// A rolling number alone at the top left of a window 390 by 300, `n` as it is, written with a % after it.
fn rolling_case(n : @signals.Signal[Int]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lines_up(Is(Some(Start))) |> ignore
      rolling_number_node(b, fn() { n.get() }, format=fn(k) { "\{k}%" }) |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// Each of the words drawn with where (x, y).
fn rolled(t : @ui.Tester) -> Array[(String, Double, Double)] {
  t.words().map(fn(w) { (w.0, w.1, w.2) })
}

///|
test "a rolling number: what stays stays where it is; the ones going up rolled in from under, the old out over; at rest its own characters alone" {
  let n = @signals.signal(98)
  let t = rolling_case(n)
  let rest = rolled(t)
  let at = fn(s : String, all : Array[(String, Double, Double)]) { all.filter(fn(w) { w.0 == s }) }
  n.set(99)
  t.frame()
  t.run_for(roll_early_ms)
  let going = rolled(t)
  t.run_for(roll_past_ms)
  let after = rolled(t)
  let nine_tens = at("9", rest)[0]
  // (the tens' 9 and the % where they were all along; the ones' 9 under where the 8 was, coming up, the 8 going up)
  let ones_8 = at("8", rest)[0]
  let new_9 = going.filter(fn(w) { w.0 == "9" && w.1 == ones_8.1 })
  let old_8 = at("8", going)
  assert_eq(
    (
      rest.map(fn(w) { w.0 }),
      going.contains(nine_tens),
      going.contains(at("%", rest)[0]),
      new_9.length() == 1 && new_9[0].2 > ones_8.2,
      old_8.length() == 1 && old_8[0].2 < ones_8.2,
      after.map(fn(w) { w.0 }),
      after.contains(nine_tens) && after.contains((("9", ones_8.1, ones_8.2))),
    ),
    (["9", "8", "%"], true, true, true, true, ["9", "9", "%"], true),
  )
}

///|
test "a rolling number going down: the new one rolled in from over it" {
  let n = @signals.signal(42)
  let t = rolling_case(n)
  let rest = rolled(t)
  let two = rest.filter(fn(w) { w.0 == "2" })[0]
  n.set(41)
  t.frame()
  t.run_for(roll_early_ms)
  let one = rolled(t).filter(fn(w) { w.0 == "1" && w.1 == two.1 })
  t.run_for(roll_past_ms)
  assert_eq((one.length() == 1 && one[0].2 < two.2, rolled(t).map(fn(w) { w.0 })), (true, ["4", "1", "%"]))
}

///|
test "a rolling number told not to roll now: the new character there at once, nothing of the old, nothing faded" {
  let n = @signals.signal(42)
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lines_up(Is(Some(Start))) |> ignore
      rolling_number_node(b, fn() { n.get() }, rolls=fn() { false }) |> ignore
    })
    |> ignore
  })
  t.draw()
  let two = t.words().filter(fn(w) { w.0 == "2" })[0]
  n.set(43)
  t.frame()
  t.run_for(roll_early_ms)
  let now = t.words().map(fn(w) { (w.0, w.1, w.2) })
  assert_eq((now.map(fn(w) { w.0 }), now.contains(("3", two.1, two.2)), @ui.view_tree().unwrap().cycle_read()), (["4", "3"], true, false))
}
