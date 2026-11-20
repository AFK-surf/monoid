// Engine-level hit-testing and hover skip completely unseen nodes (composed alpha <= 0.001) unless opted in via
// View::takes_unseen(Is(true)). Also verifies View::transitions_only() idempotency on repeated calls.

///|
test "unseen_hit: alpha=0 button over another button passes target_at and click through" {
  let under_clicks = Ref(0)
  let over_clicks = Ref(0)
  let under_id : Ref[@view.NodeId?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(under) {
      under_id.val = Some(under.id())
      under
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .ground(Is(0x3366CCFFL))
      .on_press(fn() { under_clicks.val += 1 })
      |> ignore
    })
    |> ignore
    root.box(fn(over) {
      over
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .ground(Is(0xCC3333FFL))
      .alpha(Is(0.0))
      .on_press(fn() { over_clicks.val += 1 })
      |> ignore
    })
    |> ignore
  })
  tree.frame(200.0, 200.0, now=0.0) |> ignore
  assert_eq(tree.target_at(50.0, 24.0), Pressed(under_id.val.unwrap()))
  assert_true(tree.press(50.0, 24.0))
  assert_eq((under_clicks.val, over_clicks.val), (1, 0))
  tree.dispose()
}

///|
test "unseen_hit: parent alpha=0 passes child button clicks through" {
  let under_clicks = Ref(0)
  let child_clicks = Ref(0)
  let under_id : Ref[@view.NodeId?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(under) {
      under_id.val = Some(under.id())
      under
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .ground(Is(0x3366CCFFL))
      .on_press(fn() { under_clicks.val += 1 })
      |> ignore
    })
    |> ignore
    root.box(fn(parent) {
      parent
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .alpha(Is(0.0))
      |> ignore
      parent.box(fn(child) {
        child
        .width(Is(Some(100.0)))
        .height(Is(Some(48.0)))
        .ground(Is(0xCC3333FFL))
        .on_press(fn() { child_clicks.val += 1 })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(200.0, 200.0, now=0.0) |> ignore
  assert_eq(tree.target_at(50.0, 24.0), Pressed(under_id.val.unwrap()))
  assert_true(tree.press(50.0, 24.0))
  assert_eq((under_clicks.val, child_clicks.val), (1, 0))
  tree.dispose()
}

///|
test "unseen_hit: alpha=0 small button does not intercept via 44x44 near expansion" {
  let under_clicks = Ref(0)
  let small_clicks = Ref(0)
  let under_id : Ref[@view.NodeId?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(under) {
      under_id.val = Some(under.id())
      under
      .over(Is(true))
      .width(Is(Some(120.0)))
      .height(Is(Some(60.0)))
      .ground(Is(0x3366CCFFL))
      .on_press(fn() { under_clicks.val += 1 })
      |> ignore
    })
    |> ignore
    root.box(fn(small) {
      small
      .over(Is(true))
      .offset(Is((40.0, 20.0)))
      .width(Is(Some(12.0)))
      .height(Is(Some(12.0)))
      .ground(Is(0xCC3333FFL))
      .alpha(Is(0.0))
      .on_press(fn() { small_clicks.val += 1 })
      |> ignore
    })
    |> ignore
  })
  tree.press_least(fn() { 44.0 })
  tree.frame(200.0, 200.0, now=0.0) |> ignore
  // Point is outside the 12x12 box (40..52, 20..32) but inside its 44x44 expanded hit area.
  assert_eq(tree.target_at(34.0, 26.0), Pressed(under_id.val.unwrap()))
  assert_true(tree.press(34.0, 26.0))
  assert_eq((under_clicks.val, small_clicks.val), (1, 0))
  tree.dispose()
}

///|
test "unseen_hit: explicit takes_unseen(Is(true)) captures clicks while alpha=0" {
  let under_clicks = Ref(0)
  let over_clicks = Ref(0)
  let over_id : Ref[@view.NodeId?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(under) {
      under
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .ground(Is(0x3366CCFFL))
      .on_press(fn() { under_clicks.val += 1 })
      |> ignore
    })
    |> ignore
    root.box(fn(over) {
      over_id.val = Some(over.id())
      over
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .ground(Is(0xCC3333FFL))
      .alpha(Is(0.0))
      .takes_unseen(Is(true))
      .on_press(fn() { over_clicks.val += 1 })
      |> ignore
    })
    |> ignore
  })
  tree.frame(200.0, 200.0, now=0.0) |> ignore
  assert_eq(tree.target_at(50.0, 24.0), Pressed(over_id.val.unwrap()))
  assert_true(tree.press(50.0, 24.0))
  assert_eq((under_clicks.val, over_clicks.val), (0, 1))
  tree.dispose()
}

///|
test "unseen_hit: reactive alpha 0 -> 1 -> 0 restores and drops hit testing" {
  let a = @signals.signal(0.0)
  let under_id : Ref[@view.NodeId?] = Ref(None)
  let over_id : Ref[@view.NodeId?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(under) {
      under_id.val = Some(under.id())
      under
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    root.box(fn(over) {
      over_id.val = Some(over.id())
      over
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .alpha(By(fn() { a.get() }))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
  })
  tree.frame(200.0, 200.0, now=0.0) |> ignore
  assert_eq(tree.target_at(50.0, 24.0), Pressed(under_id.val.unwrap()))
  a.set(1.0)
  tree.frame(200.0, 200.0, now=16.0) |> ignore
  assert_eq(tree.target_at(50.0, 24.0), Pressed(over_id.val.unwrap()))
  a.set(0.0)
  tree.frame(200.0, 200.0, now=32.0) |> ignore
  assert_eq(tree.target_at(50.0, 24.0), Pressed(under_id.val.unwrap()))
  tree.dispose()
}

///|
test "unseen_hit: alpha=0 hover node does not trigger pointed" {
  let hovered = Ref(false)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(b) {
      b
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .alpha(Is(0.0))
      .points(Is(true))
      |> ignore
      b.reacts(fn() { b.pointed() }, fn(p) { hovered.val = p })
    })
    |> ignore
  })
  tree.frame(200.0, 200.0, now=0.0) |> ignore
  tree.point_at(50.0, 24.0)
  tree.frame(200.0, 200.0, now=16.0) |> ignore
  assert_false(hovered.val)
  tree.dispose()
}

///|
test "unseen_hit: repeated View::transitions_only calls are idempotent" {
  let shown = @signals.signal(true)
  let other_view : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.show(fn() { shown.get() }, at_once=true, fn(s) {
      s.transitions_only().transitions_only() |> ignore
    })
    root.box(fn(o) {
      other_view.val = Some(o)
      o.height(Is(Some(20.0))) |> ignore
    })
    |> ignore
  })
  tree.frame(200.0, 200.0, now=0.0) |> ignore
  // Unmounting the node that called transitions_only() twice must decrement transitions_only_set back to 0 cleanly.
  shown.set(false)
  tree.frame(200.0, 200.0, now=16.0) |> ignore
  assert_true(other_view.val.unwrap().allows_transition())
  tree.dispose()
}

///|
test "unseen_hit: active drawn_while fade-in ancestor at t=0 allows child hits, while static alpha=0 child still passes through" {
  let clock = Ref(0.0)
  let under_id : Ref[@view.NodeId?] = Ref(None)
  let live_child_id : Ref[@view.NodeId?] = Ref(None)
  let tree = @view.Tree::new(time=fn() { clock.val }, fn(root) {
    root.box(fn(under) {
      under_id.val = Some(under.id())
      under
      .over(Is(true))
      .width(Is(Some(200.0)))
      .height(Is(Some(100.0)))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    root.box(fn(panel) {
      panel
      .over(Is(true))
      .width(Is(Some(200.0)))
      .height(Is(Some(100.0)))
      .alpha(By(fn() {
        let t = panel.drawn_while(fn(now) { now < 100.0 })
        if t == @double.infinity {
          1.0
        } else {
          t / 100.0
        }
      }))
      |> ignore
      panel.box(fn(live_child) {
        live_child_id.val = Some(live_child.id())
        live_child
        .over(Is(true))
        .offset(Is((0.0, 0.0)))
        .width(Is(Some(80.0)))
        .height(Is(Some(48.0)))
        .on_press(fn() {  })
        |> ignore
      })
      |> ignore
      panel.box(fn(static_unseen) {
        static_unseen
        .over(Is(true))
        .offset(Is((100.0, 0.0)))
        .width(Is(Some(80.0)))
        .height(Is(Some(48.0)))
        .alpha(Is(0.0))
        .on_press(fn() {  })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  // Frame 0 (t=0): panel is mid-fade-in (alpha=0.0, alpha_animating=true).
  tree.frame(200.0, 200.0, now=0.0) |> ignore
  // Normal child inside fading-in panel is immediately hittable at t=0.
  assert_eq(tree.target_at(40.0, 24.0), Pressed(live_child_id.val.unwrap()))
  // Static alpha=0 child inside the same panel is unseen at rest and passes through to under.
  assert_eq(tree.target_at(140.0, 24.0), Pressed(under_id.val.unwrap()))
  tree.dispose()
}

///|
test "unseen_hit: drawn_while fade-out to 0.0 passes through once animation ends" {
  let clock = Ref(0.0)
  let done = @signals.signal(false)
  let under_id : Ref[@view.NodeId?] = Ref(None)
  let fading_id : Ref[@view.NodeId?] = Ref(None)
  let tree = @view.Tree::new(time=fn() { clock.val }, fn(root) {
    root.box(fn(under) {
      under_id.val = Some(under.id())
      under
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    root.box(fn(fading) {
      fading_id.val = Some(fading.id())
      fading
      .over(Is(true))
      .width(Is(Some(100.0)))
      .height(Is(Some(48.0)))
      .alpha(By(fn() {
        let ended = done.get()
        let t = fading.drawn_while(fn(now) { !ended && now <= 100.0 })
        if t == @double.infinity {
          0.0
        } else {
          let p = 1.0 - t / 100.0
          if p < 0.0 { 0.0 } else { p }
        }
      }))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
  })
  // At t=100 while goes_now is still true, alpha hits 0.0 but is still animating -> still hittable.
  clock.val = 100.0
  tree.frame(200.0, 200.0, now=100.0) |> ignore
  assert_eq(tree.target_at(50.0, 24.0), Pressed(fading_id.val.unwrap()))
  // Once the animation ends (goes_now becomes false), alpha stays 0.0 at rest -> passes through to under.
  done.set(true)
  clock.val = 116.0
  tree.frame(200.0, 200.0, now=116.0) |> ignore
  assert_eq(tree.target_at(50.0, 24.0), Pressed(under_id.val.unwrap()))
  tree.dispose()
}

///|
test "unseen_hit: alpha=0 container with takes_unseen(Is(true)) allows alpha=1 child hits while alpha=0 child still passes through" {
  let under_id : Ref[@view.NodeId?] = Ref(None)
  let visible_child_id : Ref[@view.NodeId?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(under) {
      under_id.val = Some(under.id())
      under
      .over(Is(true))
      .width(Is(Some(200.0)))
      .height(Is(Some(100.0)))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    root.box(fn(container) {
      container
      .over(Is(true))
      .width(Is(Some(200.0)))
      .height(Is(Some(100.0)))
      .alpha(Is(0.0))
      .takes_unseen(Is(true))
      |> ignore
      container.box(fn(vis_child) {
        visible_child_id.val = Some(vis_child.id())
        vis_child
        .over(Is(true))
        .offset(Is((0.0, 0.0)))
        .width(Is(Some(80.0)))
        .height(Is(Some(48.0)))
        .on_press(fn() {  })
        |> ignore
      })
      |> ignore
      container.box(fn(unseen_child) {
        unseen_child
        .over(Is(true))
        .offset(Is((100.0, 0.0)))
        .width(Is(Some(80.0)))
        .height(Is(Some(48.0)))
        .alpha(Is(0.0))
        .on_press(fn() {  })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(200.0, 200.0, now=0.0) |> ignore
  // alpha=1 child inside opted-in alpha=0 container is hittable.
  assert_eq(tree.target_at(40.0, 24.0), Pressed(visible_child_id.val.unwrap()))
  // Unopted alpha=0 child inside the same container still passes through to under.
  assert_eq(tree.target_at(140.0, 24.0), Pressed(under_id.val.unwrap()))
  tree.dispose()
}
