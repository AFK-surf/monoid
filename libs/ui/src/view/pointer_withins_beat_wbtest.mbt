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

///|
test "look-only Paint/Alpha event bursts skip withins_laid and coalesce until frame" {
  let tick = @signals.signal(0, same=fn(a, b) { a == b })
  let within = Ref(false)
  let t = Tree::new(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(n) {
      n.width(Is(Some(40.0))).height(Is(Some(20.0))) |> ignore
      n.reacts(fn() { n.pointer_within() }, fn(v) { within.val = v })
    })
    |> ignore
    for i in 0..<8 {
      let idx = i
      root.box(fn(row) {
        row
        .width(Is(Some(80.0)))
        .height(Is(Some(20.0)))
        .ground(By(fn() { if (tick.get() + idx) % 2 == 0 { 0xFF112233L } else { 0xFF445566L } }))
        .alpha(By(fn() { if (tick.get() + idx) % 2 == 0 { 0.8 } else { 1.0 } }))
        |> ignore
      })
      |> ignore
    }
  })
  t.frame(300.0, 300.0, now=10.0) |> ignore
  t.point_at(10.0, 10.0)
  t.frame(300.0, 300.0, now=12.0) |> ignore
  assert_true(within.val)

  // 5 consecutive look-only events between frames: zero eager withins_laid passes.
  let passes0 = t.work().passes
  for i in 1..<=5 {
    t.event(12.0 + i.to_double() * 2.0, fn() { tick.set(i) })
  }
  assert_eq(
    t.work().passes,
    passes0,
    msg="look-only Ground/Alpha event burst must not trigger eager withins_laid passes",
  )
  assert_false(t.hits_place_due)
  t.frame(300.0, 300.0, now=26.0) |> ignore
  assert_eq(
    t.work().passes,
    passes0 + 1,
    msg="next frame should coalesce all 5 look-only events into 1 compositing pass",
  )
  t.dispose()
}

///|
test "Paint binding under Pivot::Drawn ancestor still triggers withins_laid" {
  let fill = @signals.signal(0L, same=fn(a, b) { a == b })
  let within = Ref(false)
  let t = Tree::new(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(scaled) {
      scaled
      .width(Is(Some(100.0)))
      .height(Is(Some(40.0)))
      .scale(Is(0.5), about=Drawn)
      |> ignore
      scaled.box(fn(child) {
        child
        .width(Is(Some(40.0)))
        .height(Is(Some(40.0)))
        .ground(By(fn() { fill.get() }))
        |> ignore
        child.reacts(fn() { child.pointer_within() }, fn(v) { within.val = v })
      })
      |> ignore
    })
    |> ignore
  })
  t.frame(300.0, 300.0, now=10.0) |> ignore
  t.point_at(20.0, 20.0)
  t.frame(300.0, 300.0, now=12.0) |> ignore

  // Changing Ground from transparent (draws_of=false) to opaque (draws_of=true) under Pivot::Drawn
  // shifts the ancestor's drawn pivot via drawn_stale_from, so has_withins_work must still settle eagerly.
  let passes0 = t.work().passes
  t.event(16.0, fn() { fill.set(0xFF112233L) })
  assert_true(
    t.work().passes > passes0,
    msg="Ground binding under Pivot::Drawn ancestor must still run withins_laid immediately",
  )
  t.dispose()
}

///|
test "active pointer skips withins_laid and withins_restored for look-only changes but settles geometry" {
  let now = Ref(10.0)
  let shade = @signals.signal(0xFF112233L, same=fn(a, b) { a == b })
  let fade = @signals.signal(1.0, same=fn(a, b) { a == b })
  let shift_y = @signals.signal(0.0, same=fn(a, b) { a == b })
  let within = Ref(false)
  let t = Tree::new(
    fn(root) {
      root.lines_up(Is(Some(Start))) |> ignore
      // Look-only animated spinner/fade reading beat/clock: must not trigger withins_restored pass.
      root.box(fn(b) {
        b
        .width(Is(Some(20.0)))
        .height(Is(Some(20.0)))
        .ground(By(fn() { shade.get() }))
        .alpha(By(fn() { fade.get() * (0.5 + 0.5 * b.cycle(1000.0)) }))
        |> ignore
      })
      |> ignore
      // Hit-moving target watched by pointer_within.
      root.box(fn(n) {
        n
        .width(Is(Some(60.0)))
        .height(Is(Some(40.0)))
        .offset(By(fn() { (0.0, shift_y.get()) }))
        |> ignore
        n.reacts(fn() { n.pointer_within() }, fn(v) { within.val = v })
      })
      |> ignore
    },
    time=fn() { now.val },
  )
  t.at(30.0)
  t.beat_set(30.0)
  t.frame(300.0, 300.0, now=10.0) |> ignore
  t.point_at(20.0, 35.0)
  t.frame(300.0, 300.0, now=10.0) |> ignore
  assert_true(within.val, msg="pointer starts inside target box")

  // 1. Paint-only (Ground) and look-only Place (Alpha) events with active pointer: zero withins passes.
  let passes0 = t.work().passes
  now.val = 15.0
  t.event(15.0, fn() {
    shade.set(0xFF445566L)
    fade.set(0.5)
  })
  assert_eq(
    t.work().passes,
    passes0,
    msg="Ground/Alpha-only events must not run withins_laid even with active pointer",
  )
  assert_false(t.hits_place_due)

  // 2. Hit-moving event (Offset) at at=20 while drawn clock is ahead at shown=30: runs exactly 1 pass
  // (laid_now at 20ms), then restores clock_to(30, beat=true) and skips withins_restored because the
  // only clock/beat binding in the tree is look-only (Alpha).
  now.val = 20.0
  t.event(20.0, fn() { shift_y.set(100.0) })
  assert_false(within.val, msg="moving box away from active pointer updates pointer_within immediately")
  assert_eq(
    t.work().passes,
    passes0 + 1,
    msg="look-only clock binding must not trigger an extra withins_restored pass when clock restores to 30ms",
  )
  t.dispose()
}

///|
test "Tree::pull and Tree::settle_bindings_at time tree bindings without double-counting" {
  let label = @signals.signal("a", same=fn(a, b) { a == b })
  let t = Tree::new(fn(root) {
    root.transitions_only() |> ignore
    root.laid_before_moves() |> ignore
    root.box(fn(b) {
      b.width(Is(Some(100.0))).height(Is(Some(30.0))).words(By(fn() { label.get() })) |> ignore
    })
    |> ignore
  })
  t.frame(300.0, 300.0, now=0.0) |> ignore

  let clock = Ref(0.0)
  let calls = Ref(0)
  let total_ms = Ref(0.0)
  t.timed_by(
    Some(
      (
        fn() {
          clock.val += 1.0
          clock.val
        },
        fn(what, ms) {
          if what == "tree bindings" {
            calls.val += 1
            total_ms.val += ms
          }
        },
      ),
    ),
  )

  // Event-end settle_bindings_at drains bindings and calls pull() internally: must report 1 outer timing.
  t.event(10.0, fn() { label.set("b") })
  assert_eq(calls.val, 1, msg="settle_bindings_at + inner pull must emit a single outer tree bindings span")
  assert_eq(total_ms.val, 1.0, msg="single outer span must not double-count nested pull()")

  // Standalone pull() when pulls_marked is non-empty reports tree bindings; empty pull() reports nothing.
  calls.val = 0
  total_ms.val = 0.0
  @signals.start_batch()
  label.set("c")
  t.pull()
  @signals.end_batch()
  assert_eq(calls.val, 1, msg="non-empty Tree::pull must report tree bindings")
  assert_eq(total_ms.val, 1.0)

  calls.val = 0
  t.pull()
  assert_eq(calls.val, 0, msg="empty Tree::pull must not emit a spurious tree bindings span")
  t.dispose()
}
