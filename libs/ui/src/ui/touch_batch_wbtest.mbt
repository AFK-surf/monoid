// A system's batch of a finger's samples (touches.mbt): each a move taken at its own moment, what they changed laid out
// once, as the batch's last is taken.

///|
/// A frame of a phone's display: between the finger's down and its batch of moves.
let batch_frame_ms : Double = 16.0

///|
/// A Tester with a node a finger drags over the window's top left: its width the drag's x, what it is told in `seen`
/// (what, where, when).
fn batch_tester(seen : Array[String]) -> Tester {
  let t = Tester::new(fn(_c) {  })
  t.check_looks(false)
  let w = @signals.signal(100.0)
  set_view_app(fn(root) {
    root.box(fn(b) {
      b.over(Is(true)) |> ignore
      b.box(fn(h) {
        h
        .width(By(fn() { Some(w.get()) }))
        .height(Is(Some(200.0)))
        .on_drag(fn(d) {
          seen.push("\{d.kind} \{d.x} \{d.at}")
          if d.kind is Moved {
            w.set(d.x)
          }
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  t
}

///|
/// A finger down at 10,10, then the moves to `xs` (one batch: the host's phase for each, 4 more after it, 1 the
/// last), 2 ms apart: what the node was told, the nodes laid out by the moves.
fn batch_moved(phases : Array[Int], xs : Array[Double]) -> (Array[String], Int) {
  let seen : Array[String] = []
  let t = batch_tester(seen)
  let t0 = t.time()
  t.touch_raw(0, 7, 10.0, 10.0, t0)
  t.advance(batch_frame_ms)
  t.drawn_now()
  let laid = fn() { view_app.val.unwrap().work().laid }
  let before = laid()
  for i, x in xs {
    t.touch_raw(phases[i], 7, x, 10.0, t0 + batch_frame_ms + 2.0 * i.to_double())
  }
  let moved = laid() - before
  t.drawn_now()
  t.touch_raw(2, 7, xs[xs.length() - 1], 10.0, t0 + 40.0)
  (seen, moved)
}

///|
test "a batch of a finger's moves: each told at its own moment, laid out once, at the last" {
  let xs = [120.0, 130.0, 140.0, 150.0]
  let (apart, apart_laid) = batch_moved([1, 1, 1, 1], xs)
  let (batch, batch_laid) = batch_moved([4, 4, 4, 1], xs)
  // (every sample the node's, at its own moment, as when each came alone)
  assert_eq(batch, apart)
  assert_eq(batch.length(), 6)
  // (one layout of the four's: as many nodes as one alone lays out)
  assert_true(apart_laid > 0)
  assert_eq(batch_laid * 4, apart_laid)
}
