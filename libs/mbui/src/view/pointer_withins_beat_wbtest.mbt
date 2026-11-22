///|
test "no pointer skips withins laid_now on signal change, active pointer settles immediately" {
  let w = @signals.signal(40.0, same=fn(a, b) { a == b })
  let within = Ref(false)
  let near = Ref(false)
  let t = Tree::new(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(n) {
      n.width(By(fn() { Some(w.get()) })).height(Is(Some(20.0))) |> ignore
      n.reacts(fn() { n.pointer_within() }, fn(v) { within.val = v })
    })
    |> ignore
    root.box(fn(n) {
      n.width(Is(Some(120.0))).height(Is(Some(80.0))) |> ignore
      n.reacts(fn() { n.bar_near(12.0) }, fn(v) { near.val = v })
    })
    |> ignore
  })
  t.frame(300.0, 300.0, now=10.0) |> ignore
  assert_eq(t.pointer_xy, (-1.0, -1.0))

  // No pointer in window: signal change in an event does not trigger laid_now.
  let passes0 = t.work().passes
  t.event(20.0, fn() { w.set(60.0) })
  assert_eq(
    t.work().passes,
    passes0,
    msg="no pointer in window should skip synchronous withins laid_now in event",
  )
  assert_false(t.withins_owed, msg="no pointer in window should not owe withins")

  // Outside an event: signal change does not set withins_owed, and next event does not run laid_now.
  w.set(70.0)
  assert_false(t.withins_owed, msg="no pointer in window should not set withins_owed outside event")
  t.event(25.0, fn() {  })
  assert_eq(
    t.work().passes,
    passes0,
    msg="withins_owed_now should skip laid_now when pointer is outside window",
  )
  t.frame(300.0, 300.0, now=25.0) |> ignore

  // Active pointer inside window: signal change settles immediately via laid_now.
  t.point_at(10.0, 10.0)
  t.frame(300.0, 300.0, now=30.0) |> ignore
  let passes1 = t.work().passes
  t.event(40.0, fn() { w.set(90.0) })
  assert_true(
    t.work().passes > passes1,
    msg="active pointer should still settle withins via laid_now",
  )
  t.frame(300.0, 300.0, now=40.0) |> ignore

  // Pointer leaves window: signal changes skip laid_now again.
  t.point_at(-1.0, -1.0)
  let passes2 = t.work().passes
  t.event(50.0, fn() { w.set(110.0) })
  assert_eq(
    t.work().passes,
    passes2,
    msg="leaving window should resume skipping withins laid_now",
  )
  assert_false(t.withins_owed, msg="leaving window should not owe withins")
  t.dispose()
}

///|
test "clock_to with beat in transitions_only does not emit spurious answer_mark" {
  let now = Ref(100.0)
  let t = Tree::new(
    fn(root) {
      root.transitions_only() |> ignore
      root.lines_up(Is(Some(Start))) |> ignore
      root.box(fn(b) {
        b
        .width(By(fn() { Some(50.0 + b.cycle(1000.0) * 100.0) }))
        .height(Is(Some(20.0)))
        |> ignore
      })
      |> ignore
    },
    time=fn() { now.val },
  )
  t.frame(300.0, 300.0, now=100.0) |> ignore
  t.answered_between(0.0, 100.0) |> ignore

  // 1. bound_at
  now.val = 120.0
  @signals.untracked(fn() { t.bound_at(120.0) })
  t.frame(300.0, 300.0, now=120.0) |> ignore
  assert_true(
    t.answered_between(100.0, 120.0).is_empty(),
    msg="bound_at must not emit spurious answer_mark in transitions_only",
  )

  // 2. laid_now
  now.val = 140.0
  t.laid_now() |> ignore
  t.frame(300.0, 300.0, now=140.0) |> ignore
  assert_true(
    t.answered_between(120.0, 140.0).is_empty(),
    msg="laid_now must not emit spurious answer_mark in transitions_only",
  )

  // 3. measured_now
  now.val = 160.0
  t.measured_now()
  t.frame(300.0, 300.0, now=160.0) |> ignore
  assert_true(
    t.answered_between(140.0, 160.0).is_empty(),
    msg="measured_now must not emit spurious answer_mark in transitions_only",
  )

  // 4. settle_layout_at
  now.val = 180.0
  t.layout_due = true
  t.settle_layout_at(180.0)
  t.frame(300.0, 300.0, now=180.0) |> ignore
  assert_true(
    t.answered_between(160.0, 180.0).is_empty(),
    msg="settle_layout_at must not emit spurious answer_mark in transitions_only",
  )
  t.dispose()
}
