///|
test "Tree::at skips withins_owed_now laid_now when no pointer is in window, settles when active" {
  let open = @signals.signal(false, same=fn(a, b) { a == b })
  let within = Ref(false)
  let near = Ref(false)
  let t = Tree::new(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(n) {
      n.width(Is(Some(40.0))).height(Is(Some(20.0))) |> ignore
      n.reacts(fn() { n.pointer_within() }, fn(v) { within.val = v })
    })
    |> ignore
    root.show(fn() { open.get() }, at_once=true, fn(n) {
      n.width(Is(Some(60.0))).height(Is(Some(20.0))) |> ignore
    })
    root.box(fn(n) {
      n.width(Is(Some(120.0))).height(Is(Some(80.0))) |> ignore
      n.reacts(fn() { n.bar_near(12.0) }, fn(v) { near.val = v })
    })
    |> ignore
  })
  t.frame(300.0, 300.0, now=10.0) |> ignore
  assert_eq(t.pointer_xy, (-1.0, -1.0))

  // No pointer in window: between-frame structural change sets withins_owed,
  // but Tree::at clears it without running laid_now; frame lays out once.
  let passes0 = t.work().passes
  open.set(true)
  assert_true(t.withins_owed, msg="between-frame change records withins_owed")
  t.at(20.0)
  assert_eq(
    t.work().passes,
    passes0,
    msg="Tree::at with no pointer must skip withins_owed_now laid_now",
  )
  assert_false(t.withins_owed, msg="Tree::at with no pointer clears withins_owed")
  t.frame(300.0, 300.0, now=20.0) |> ignore
  assert_true(t.work().passes > passes0, msg="subsequent frame still lays out once")

  // Active pointer inside window: Tree::at settles withins_owed immediately via laid_now.
  t.point_at(10.0, 10.0)
  t.frame(300.0, 300.0, now=30.0) |> ignore
  let passes1 = t.work().passes
  open.set(false)
  assert_true(t.withins_owed, msg="between-frame change with active pointer sets withins_owed")
  t.at(40.0)
  assert_true(
    t.work().passes > passes1,
    msg="Tree::at with active pointer should settle withins_owed_now via laid_now",
  )
  t.frame(300.0, 300.0, now=40.0) |> ignore

  // Pointer leaves window: withins_owed is cleared and Tree::at skips laid_now again.
  open.set(true)
  assert_true(t.withins_owed, msg="active pointer sets withins_owed before leaving")
  t.point_at(-1.0, -1.0)
  assert_false(t.withins_owed, msg="leaving window clears pending withins_owed")
  t.frame(300.0, 300.0, now=50.0) |> ignore
  let passes2 = t.work().passes
  open.set(false)
  assert_true(t.withins_owed, msg="between-frame structural change records withins_owed")
  t.at(60.0)
  assert_eq(
    t.work().passes,
    passes2,
    msg="Tree::at after pointer leaves window should skip laid_now again",
  )
  assert_false(t.withins_owed, msg="Tree::at after pointer leaves clears withins_owed")
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
