///|
/// How many nodes a tree lays out as an answer tells `shows` structures that read it and come out as they were, where
/// what is under the pointer is read and a binding follows the drawn clock, the host's time going on as it is asked (a
/// Mac's window: NewChat's send, 2026-11-15).
fn answer_laid(shows : Int) -> (Int, Int) {
  let now = Ref(60.0)
  let answer = @signals.signal(0)
  let within = Ref(false)
  let t = Tree::new(
    fn(root) {
      root.lines_up(Is(Some(Start))) |> ignore
      root.box(fn(n) {
        // (wider for each moment the drawn clock has passed: as a way going on is, laid out again as the clock moves)
        n.width(By(fn() {
          let mut w = 30.0
          for k in 0..<40 {
            if n.drawn_past(62.5 + k.to_double()) {
              w += 1.0
            }
          }
          Some(w)
        }))
        .height(Is(Some(20.0)))
        |> ignore
        n.reacts(fn() { n.pointer_within() }, fn(v) { within.val = v })
      })
      |> ignore
      for _ in 0..<shows {
        root.show(fn() { answer.get() >= 0 }, fn(s) { s.height(Is(Some(4.0))) |> ignore })
      }
    },
    time=fn() {
      // (each asking a moment later: a layout's own time)
      now.val += 1.0
      now.val
    },
  )
  t.frame(300.0, 300.0, now=50.0) |> ignore
  t.point_at(10.0, 10.0)
  t.frame(300.0, 300.0, now=60.0) |> ignore
  let before = t.work().laid
  answering(fn() { answer.set(1) })
  // (and what it owes of what is under the pointer, settled as the next thing of its moment comes: an event)
  t.event(now.val, fn() {  })
  let laid = t.work().laid - before
  let nodes = t.nodes.length()
  t.dispose()
  (laid, nodes)
}

///|
test "an answer marking many structures that come out as they were lays the tree out as one marking one does" {
  let (one, one_nodes) = answer_laid(1)
  let (many, many_nodes) = answer_laid(28)
  println("ANSWER-LAID one \{one} of \{one_nodes} nodes, 28: \{many} of \{many_nodes}")
  // (the answer's change laid out as one, the clock gone on once: what moved with it laid out again as often as for one
  // structure, not once more for each)
  assert_true(one > 0, msg="the clock's binding laid out again as the answer was told")
  assert_true(many <= one * 2, msg="laid \{many} of \{many_nodes} nodes for 28 structures against \{one} of \{one_nodes} for one")
}
