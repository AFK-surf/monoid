///|
test "clock-dependent layout with at_moment(cause_at) does not loop forever in advance_loop" {
  let runs = Ref(0)
  let escaped = Ref(false)
  let box_w = @signals.signal(0.0, same=fn(a, b) { a == b })
  let paint_tick = @signals.signal(0, same=fn(a, b) { a == b })
  let hover = Ref(false)
  let pending : Ref[() -> Unit] = Ref(fn() {  })
  let now = Ref(100.0)
  let t = Tree::new(time=fn() { now.val }, fn(root) {
    root.row(Is(true)) |> ignore
    // A sidebar whose width animates with the drawn clock (like sfdesk's fold_along).
    root.box(fn(side) {
      side
      .width(
        By(fn() {
          let ms = side.drawn_at()
          let frac = if ms < 100.0 {
            0.0
          } else if ms > 300.0 {
            1.0
          } else {
            (ms - 100.0) / 200.0
          }
          Some(200.0 * (1.0 - frac))
        }),
      )
      .height(Is(Some(400.0)))
      |> ignore
    })
    |> ignore
    // A stage beside it that observes its laid_size and pointer_within (like screen_stage + screen_life_node).
    root.box(fn(stage) {
      stage.grow(Is(1.0)).height(Is(Some(400.0))).ground(By(fn() { paint_tick.get().to_int64() })) |> ignore
      stage.reacts(fn() { stage.pointer_within() }, fn(v) { hover.val = v })
      stage.reacts(fn() { stage.laid_size_told().map_or(0.0, fn(s) { s.0 }) }, fn(w) {
        if w > 0.0 {
          box_w.set(w)
        }
      })
    })
    |> ignore
    // A structure reading drawn_past so Tree::at(150.0) -> clock_to(150.0) triggers Tree::at_cause -> advance_loop
    // while clock-dependent layout bindings are still queued in bindings_due.
    root.show(fn() { root.drawn_past(140.0) }, fn(_) {  })
    root.reacts(fn() { box_w.get() }, fn(_) {
      if escaped.val {
        return
      }
      (pending.val)()
      pending.val = root.at_moment(root.cause_at(), fn() {
        runs.val += 1
        paint_tick.set(runs.val)
        if runs.val >= 50 {
          escaped.val = true
        }
      })
    })
  })
  t.at(100.0)
  t.frame(800.0, 400.0, now=100.0) |> ignore
  // Schedule a pending Once at 120.0 while the drawn clock moves ahead to 150.0.
  t.point_at(400.0, 200.0)
  t.root().at_moment(120.0, fn() {
    runs.val += 1
    paint_tick.set(runs.val)
    if runs.val >= 50 {
      escaped.val = true
    }
  })
  |> ignore
  now.val = 150.0
  t.at(150.0)
  t.frame(800.0, 400.0, now=150.0) |> ignore
  assert_false(
    escaped.val,
    msg="advance_loop must not oscillate between laid_now and withins_restored (runs=\{runs.val}, passes=\{t.work.passes})",
  )
  assert_eq(box_w.untracked(), 650.0)
  assert_true(hover.val, msg="pointer_within still settles after advance_loop")
  assert_true(t.pending.length() < 100, msg="pending changes remain bounded")
  t.dispose()
}

///|
test "eager settle_now inside advance_loop defers withins_restored until the loop ends" {
  let runs = Ref(0)
  let escaped = Ref(false)
  let box_w = @signals.signal(0.0, same=fn(a, b) { a == b })
  let paint_tick = @signals.signal(0, same=fn(a, b) { a == b })
  let pending : Ref[() -> Unit] = Ref(fn() {  })
  let now = Ref(100.0)
  let t = Tree::new(time=fn() { now.val }, fn(root) {
    root.laid_before_causes() |> ignore
    root.row(Is(true)) |> ignore
    root.box(fn(side) {
      side
      .width(
        By(fn() {
          let ms = side.drawn_at()
          let frac = if ms < 100.0 {
            0.0
          } else if ms > 300.0 {
            1.0
          } else {
            (ms - 100.0) / 200.0
          }
          Some(200.0 * (1.0 - frac))
        }),
      )
      .height(Is(Some(400.0)))
      |> ignore
    })
    |> ignore
    root.box(fn(stage) {
      stage.grow(Is(1.0)).height(Is(Some(400.0))).ground(By(fn() { paint_tick.get().to_int64() })) |> ignore
      stage.reacts(fn() { stage.pointer_within() }, fn(_) {  })
      stage.reacts(fn() { stage.laid_size_told().map_or(0.0, fn(s) { s.0 }) }, fn(w) {
        if w > 0.0 {
          box_w.set(w)
        }
      })
    })
    |> ignore
    root.reacts(fn() { box_w.get() }, fn(_) {
      if escaped.val {
        return
      }
      (pending.val)()
      pending.val = root.at_moment(root.cause_at(), fn() {
        runs.val += 1
        paint_tick.set(runs.val)
        if runs.val >= 50 {
          escaped.val = true
        }
      })
    })
  })
  t.at(100.0)
  t.frame(800.0, 400.0, now=100.0) |> ignore
  t.point_at(400.0, 200.0)
  t.root().at_moment(120.0, fn() {
    runs.val += 1
    paint_tick.set(runs.val)
    if runs.val >= 50 {
      escaped.val = true
    }
  })
  |> ignore
  now.val = 150.0
  t.frame(800.0, 400.0, now=150.0) |> ignore
  assert_false(
    escaped.val,
    msg="settle_layout_at in advance_loop must not oscillate with withins_restored (runs=\{runs.val}, passes=\{t.work.passes})",
  )
  assert_eq(box_w.untracked(), 650.0)
  assert_true(t.pending.length() < 100, msg="pending changes remain bounded")
  t.dispose()
}
