// What only a look of the library's parts moves (a button's ground under the pointer, words' ink, a dialog dimmed over
// itself as another comes over it) is read as each frame is painted: told as the part is built, nothing built again
// for it while it goes.

///|
/// The frames after the one now, to `until` (each the next one a motion asks for), what each was built for (none where
/// it was painted alone), and `seen` read off each. The frame after one that laid out otherwise is built once more for
/// that, as the frame after any such build is (frame_watch.mbt): that one is not said.
fn[T : Eq] painted_until(t : @ui.Tester, until : Double, seen : () -> T) -> (Array[String], Array[T]) {
  let built : Array[String] = []
  let got : Array[T] = []
  let mut first = true
  while t.time() < until {
    let w = t.wanted_after()
    if w == @double.infinity {
      break
    }
    t.frame_at(if w <= t.time() { t.next_frame_time() } else { t.display_frame(w) })
    let why = t.built_why()
    if why != "" && !(first && why == "the one before it laid out otherwise") {
      built.push("\{t.time()}: \{why}")
    }
    first = false
    let s = seen()
    if !got.contains(s) {
      got.push(s)
    }
  }
  (built, got)
}

///|
test "a button the pointer comes onto: its ground eases to the hover's as each frame is painted, nothing built for it" {
  let t = @ui.Tester::new(
    fn(c) {
      c.box(w=Px(300.0), h=Px(200.0), align=AStart, fn() { button(c, "Join", key="b") |> ignore }) |> ignore
    },
    w=400.0,
    h=300.0,
  )
  t.check_looks(false)
  t.draw()
  let ground = fn() { t.drawn_rects()[0].4 }
  let (x, y) = {
    let r = t.drawn_rects()[0]
    (r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
  }
  let rest = ground()
  // (the pointer come onto it: built for that, its ground told to go to the hover's)
  t.move_to(x, y)
  let (built, grounds) = painted_until(t, t.time() + dur_ms, ground)
  // (it eases, through colours between, to the one under the hand)
  assert_true(grounds.length() > 3 && !grounds.contains(rest), msg="\{Repr(grounds)}")
  assert_eq(built, [], msg="\{built.length()} frames built: \{Repr(built)}")
}
