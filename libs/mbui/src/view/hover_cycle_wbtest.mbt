///|
test "a hover that moves itself cannot keep a layout running forever" {
  let reactions = Ref(0)
  let escaped = Ref(false)
  let other_width = @signals.signal(10.0, same=fn(a, b) { a == b })
  let other_y = @signals.signal(100.0, same=fn(a, b) { a == b })
  let other_hover = Ref(false)
  let opacity = @signals.signal(1.0, same=fn(a, b) { a == b })
  let cycling = @signals.signal(true, same=fn(a, b) { a == b })
  let box : Ref[View?] = Ref(None)
  let t = Tree::new(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(n) {
      box.val = Some(n)
      n.reacts(fn() { n.pointer_within() }, fn(_) {
        reactions.val += 1
        if reactions.val >= 200 {
          escaped.val = true
        }
      })
      n
      .width(
        By(fn() {
          Some(
            if cycling.get() && n.pointer_within() && !escaped.val {
              20.0
            } else {
              40.0
            },
          )
        }),
      )
      .alpha(By(fn() { opacity.get() }))
      .height(Is(Some(20.0)))
      |> ignore
    })
    |> ignore
    root.box(fn(n) {
      n.reacts(fn() { n.pointer_within() }, fn(v) { other_hover.val = v })
      n
      .over(Is(true))
      .offset(By(fn() { (0.0, other_y.get()) }))
      .width(By(fn() { Some(50.0 + other_width.get()) }))
      .height(Is(Some(20.0)))
      |> ignore
    })
    |> ignore
  })
  t.frame(300.0, 300.0) |> ignore
  t.point_at(30.0, 10.0)
  t.frame(300.0, 300.0) |> ignore
  assert_false(
    escaped.val,
    msg="hover layout must stop before its state oscillates 200 times",
  )
  assert_true(reactions.val > 1, msg="the hover did change more than once")
  let stopped = reactions.val
  t.frame(300.0, 300.0) |> ignore
  assert_eq(reactions.val, stopped, msg="idle frames do not restart the loop")
  for y in [0.0, 100.0, 0.0, 100.0] {
    other_width.set(if y == 0.0 { 10.0 } else { 11.0 })
    other_y.set(y)
    opacity.set(if y == 0.0 { 0.9 } else { 1.0 })
    t.frame(300.0, 300.0) |> ignore
    assert_eq(
      other_hover.val,
      y == 0.0,
      msg="other hover observers continue to update",
    )
    assert_true(
      t.pending.length() < 1000,
      msg="each frame leaves a bounded set of changes for the host",
    )
    t.take_changed() |> ignore
  }
  assert_false(
    escaped.val,
    msg="unrelated layout does not endlessly restart the hover loop",
  )
  assert_eq(
    reactions.val,
    stopped,
    msg="unrelated changes on the hovering node do not restart the loop",
  )
  cycling.set(false)
  t.frame(300.0, 300.0) |> ignore
  assert_true(
    @signals.untracked(fn() { box.val.unwrap().pointer_within() }),
    msg="the observer catches up when its feedback goes away",
  )
  t.point_at(100.0, 10.0)
  t.frame(300.0, 300.0) |> ignore
  assert_false(t.due, msg="the tree settles after the pointer moves away")
  t.dispose()
}

///|
test "moving an ancestor lets a stopped hover catch up" {
  let reactions = Ref(0)
  let escaped = Ref(false)
  let offset = @signals.signal(0.0, same=fn(a, b) { a == b })
  let trigger_y = @signals.signal(100.0, same=fn(a, b) { a == b })
  let box : Ref[View?] = Ref(None)
  let t = Tree::new(fn(root) {
    root.box(fn(parent) {
      parent.shift(By(fn() { (offset.get(), 0.0) })) |> ignore
      parent.box(fn(n) {
        box.val = Some(n)
        n.reacts(fn() { n.pointer_within() }, fn(_) {
          reactions.val += 1
          if reactions.val >= 200 {
            escaped.val = true
          }
        })
        n
        .width(
          By(fn() {
            Some(if n.pointer_within() && !escaped.val { 20.0 } else { 40.0 })
          }),
        )
        .height(Is(Some(20.0)))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    root.box(fn(other) {
      other
      .over(Is(true))
      .offset(By(fn() { (0.0, trigger_y.get()) }))
      .width(Is(Some(60.0)))
      .height(Is(Some(20.0)))
      |> ignore
      other.reacts(fn() { other.pointer_within() }, fn(on) {
        if on {
          offset.set(100.0)
        }
      })
    })
    |> ignore
  })
  t.frame(300.0, 300.0) |> ignore
  t.point_at(30.0, 10.0)
  t.frame(300.0, 300.0) |> ignore
  assert_false(escaped.val)
  assert_true(t.pointer_still is Some(_))
  trigger_y.set(0.0)
  t.frame(300.0, 300.0) |> ignore
  assert_false(@signals.untracked(fn() { box.val.unwrap().pointer_within() }))
  assert_true(t.pointer_still is None)
  assert_false(t.due)
  t.dispose()
}

///|
test "a bar that moves itself cannot keep a layout running forever" {
  let reactions = Ref(0)
  let escaped = Ref(false)
  let other_width = @signals.signal(10.0, same=fn(a, b) { a == b })
  let bar : Ref[View?] = Ref(None)
  let t = Tree::new(fn(root) {
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(n) {
      bar.val = Some(n)
      n.reacts(fn() { n.bar_near(15.0) }, fn(_) {
        reactions.val += 1
        if reactions.val >= 200 {
          escaped.val = true
        }
      })
      n
      .width(
        By(fn() {
          Some(if n.bar_near(15.0) && !escaped.val { 20.0 } else { 40.0 })
        }),
      )
      .height(Is(Some(20.0)))
      .ground(Is(0xff000000L))
      |> ignore
    })
    |> ignore
    root.box(fn(n) {
      n.width(By(fn() { Some(other_width.get()) })).height(Is(Some(1.0)))
      |> ignore
    })
    |> ignore
  })
  t.frame(300.0, 300.0) |> ignore
  t.point_at(35.0, 10.0)
  t.frame(300.0, 300.0) |> ignore
  assert_false(escaped.val)
  assert_true(reactions.val > 1)
  assert_true(t.pointer_still is Some(_))
  let stopped = reactions.val
  for width in [10.0, 11.0, 10.0, 11.0] {
    other_width.set(width)
    t.frame(300.0, 300.0) |> ignore
  }
  assert_eq(reactions.val, stopped)
  t.point_at(100.0, 10.0)
  t.frame(300.0, 300.0) |> ignore
  assert_false(@signals.untracked(fn() { bar.val.unwrap().bar_near(15.0) }))
  assert_false(t.due)
  t.dispose()
}

///|
test "a long chain of distinct hover states settles in one frame" {
  let views : Array[View] = []
  let t = Tree::new(fn(root) {
    for k in 0..<50 {
      root.box(fn(n) {
        let before = if k > 0 { Some(views[k - 1]) } else { None }
        views.push(n)
        n
        .over(Is(true))
        .width(Is(Some(100.0)))
        .height(Is(Some(20.0)))
        .offset(
          By(fn() {
            match before {
              None => (0.0, 80.0)
              Some(b) =>
                if b.pointer_within() {
                  (0.0, 80.0)
                } else {
                  (0.0, 250.0)
                }
            }
          }),
        )
        |> ignore
      })
      |> ignore
    }
  })
  t.point_at(10.0, 90.0)
  t.frame(400.0, 300.0) |> ignore
  for v in views {
    assert_true(@signals.untracked(fn() { v.pointer_within() }))
  }
  assert_true(t.pointer_still is None)
  assert_false(t.due)
  t.dispose()
}

///|
test "a hover with no repeating geometry cannot hold a frame forever" {
  let reactions = Ref(0)
  let t = Tree::new(fn(root) {
    root.box(fn(n) {
      n.reacts(fn() { n.pointer_within() }, fn(_) { reactions.val += 1 })
      n
      .width(
        By(fn() {
          let within = n.pointer_within()
          let step = reactions.val.to_double() / 1000.0
          Some(
            if within && reactions.val < 500 {
              20.0 + step
            } else {
              40.0 + step
            },
          )
        }),
      )
      .height(Is(Some(20.0)))
      |> ignore
    })
    |> ignore
  })
  t.frame(300.0, 300.0) |> ignore
  t.point_at(30.0, 10.0)
  t.frame(300.0, 300.0) |> ignore
  assert_true(reactions.val > 32 && reactions.val < 300)
  assert_true(t.pointer_still is Some(_))
  let stopped = reactions.val
  t.frame(300.0, 300.0) |> ignore
  assert_eq(reactions.val, stopped)
  t.point_at(100.0, 10.0)
  t.frame(300.0, 300.0) |> ignore
  assert_false(t.due)
  t.dispose()
}
