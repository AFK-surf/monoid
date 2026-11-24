///|
test "same-moment Once re-scheduling cycle in advance_loop stops within bound" {
  let runs = Ref(0)
  let escaped = Ref(false)
  let tick = @signals.signal(0, same=fn(a, b) { a == b })
  let now = Ref(100.0)
  let t = Tree::new(time=fn() { now.val }, fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(100.0))).height(Is(Some(100.0))).ground(By(fn() { tick.get().to_int64() })) |> ignore
    })
    |> ignore
    root.reacts(fn() { tick.get() }, at_start=false, fn(v) {
      if v > 0 && !escaped.val {
        root.at_moment(root.cause_at(), fn() {
          runs.val += 1
          if runs.val >= 400 {
            escaped.val = true
            return
          }
          tick.set(v + 1)
        })
        |> ignore
      }
    })
  })
  t.at(100.0)
  t.frame(300.0, 300.0, now=100.0) |> ignore
  tick.set(1)
  now.val = 120.0
  t.frame(300.0, 300.0, now=120.0) |> ignore
  assert_false(
    escaped.val,
    msg="advance_loop must stop a same-moment Once re-scheduling cycle before 400 runs (runs=\{runs.val})",
  )
  assert_true(
    runs.val <= advance_same_moment_most + 1,
    msg="same-moment Once runs stay within advance_same_moment_most (runs=\{runs.val})",
  )
  t.dispose()
}

///|
test "pre-existing Once items at the same moment are not capped by advance_loop" {
  let runs = Ref(0)
  let now = Ref(100.0)
  let t = Tree::new(time=fn() { now.val }, fn(root) {
    root.box(fn(b) { b.width(Is(Some(100.0))).height(Is(Some(100.0))) |> ignore }) |> ignore
  })
  t.at(100.0)
  t.frame(300.0, 300.0, now=100.0) |> ignore
  for _ in 0..<300 {
    t.root().at_moment(120.0, fn() { runs.val += 1 }) |> ignore
  }
  now.val = 120.0
  t.frame(300.0, 300.0, now=120.0) |> ignore
  assert_eq(runs.val, 300)
  t.dispose()
}
