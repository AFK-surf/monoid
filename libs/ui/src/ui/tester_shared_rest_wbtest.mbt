// A shared element's flight (@view.View::shared) under the Tester: where it lands is when all that moves comes to
// rest (Tester::rest_of "", the tree's ways read beside the old view's movers), and what lands under a still pointer
// is pointed as it lands, no input needed (the flight's end a moment the hand is worked out again).

///|
/// How long rest_flight takes, whatever its length.
// kept across runs: a value
let rest_flight_ms : Double = 200.0

///|
/// A flight rest_flight_ms long whatever its length, straight along.
let rest_flight : @view.Flight = { way: fn(_) { (rest_flight_ms, fn(ms) { ms / rest_flight_ms }) } }

///|
let rest_red : Int64 = 0xFF0000FFL

///|
let rest_blue : Int64 = 0x0000FFFFL

///|
/// A window 400×400 of the tree alone: a thumbnail 40 square at (10, 10) while `open` is not, then (from y 60) a detail
/// holding one 100 tall at (10, 70), 380 wide, while `open` is, the two one thing (View::shared, rest_flight); what is
/// pointed of the detail's one, as its ground last read it, kept in `pointed`. The tester, `open`, the detail's one.
fn rest_tester(pointed : Ref[Bool]) -> (Tester, @signals.Signal[Bool], Ref[@view.View?]) {
  let open = @signals.signal(false, same=fn(a, b) { a == b })
  let big : Ref[@view.View?] = Ref(None)
  let t = Tester::tree(
    fn(root) {
      root.box(fn(list) {
        list.height(Is(Some(60.0))).padding(Is((10.0, 10.0, 10.0, 10.0))) |> ignore
        list.show(fn() { !open.get() }, fn(v) {
          v
          .width(Is(Some(40.0)))
          .height(Is(Some(40.0)))
          .ground(Is(rest_red))
          .shared(Is("a"), rest_flight)
          .says(Is(Some(@view.said(Button, label="小"))))
          .on_press(fn() {  })
          |> ignore
        })
      })
      |> ignore
      root.box(fn(d) {
        d.height(Is(Some(200.0))).padding(Is((10.0, 10.0, 10.0, 10.0))) |> ignore
        d.show(fn() { open.get() }, fn(b) {
          big.val = Some(b)
          b
          .height(Is(Some(100.0)))
          .ground(By(fn() {
            pointed.val = b.pointed()
            rest_blue
          }))
          .shared(Is("a"), rest_flight)
          .says(Is(Some(@view.said(Button, label="大"))))
          .on_press(fn() {  })
          |> ignore
        })
      })
      |> ignore
    },
    w=400.0,
    h=400.0,
  )
  t.check_looks(false)
  (t, open, big)
}

///|
test "a flight on the tree alone: all that moves at rest where it lands, said as it flies and kept once it has landed" {
  let (t, open, big) = rest_tester(Ref(false))
  assert_eq(t.rest_of(""), -1.0, msg="nothing ever moved")
  open.set(true)
  t.frame()
  let b = big.val.unwrap()
  assert_true(b.flies())
  let end = t.rest_of("")
  assert_true(end > t.time(), msg="its end said as it flies: \{end} at \{t.time()}")
  assert_eq(t.rest_of("other_mover"), -1.0, msg="no mover so named")
  // (still on its way a moment before it: the end said is the one it lands at)
  t.run_for(end - 1.0 - t.time())
  assert_true(b.flies(), msg="on its way a moment before the end said")
  assert_eq(t.rest_of(""), end)
  t.run_for(end - t.time())
  assert_false(b.flies(), msg="landed at the end said")
  assert_eq(t.rest_of(""), end, msg="kept once it has landed")
  assert_eq(t.rest_of("other_mover"), -1.0)
  assert_true(t.at_rest(), msg=t.rest_why())
}

///|
test "what flies in under a still pointer is pointed as it lands, the pointer not moved" {
  let pointed = Ref(false)
  let (t, open, big) = rest_tester(pointed)
  // (where the detail's one lands, nothing there that points before it)
  t.move_to(200.0, 150.0)
  open.set(true)
  t.frame()
  let b = big.val.unwrap()
  assert_true(b.flies())
  assert_false(pointed.val, msg="not under the pointer as it sets off")
  // (its length told by the flight alone, not by what the Tester reads of the tree's ways)
  t.run_for(rest_flight_ms / 2.0)
  assert_true(b.flies())
  assert_false(pointed.val, msg="not under the pointer half way")
  t.run_for(rest_flight_ms)
  assert_false(b.flies())
  assert_true(pointed.val, msg="pointed as it lands under the still pointer")
}
