// Tests for headless Drawer: shared overlay_stack dismissal (Escape, outside press, modal), edge-aware drag-to-dismiss,
// multi-snap-point snapping, velocity flick, and can_drag scroll-handoff guard. All windows use `window`.

///|
test "Drawer: joins shared overlay_stack (Escape, outside press, modal) and drags to dismiss on Bottom edge" {
  let open = @signals.signal(false)
  let closes = Ref(0)
  let dr_ref : Ref[@headless.Drawer?] = Ref(None)
  let t = window(fn(root) {
    @headless.button(root, fn() { "打开抽屉" }, fn(_) { open.set(true) }, fn(v, _) {
      v.width(Is(Some(100.0))).height(Is(Some(32.0))) |> ignore
    })
    |> ignore
    root.show(at_once=true, fn() { open.get() }, fn(s) {
      @headless.drawer(
        s,
        fn() { "底部抽屉" },
        fn() { open.get() },
        fn() {
          closes.val += 1
          open.set(false)
        },
        edge=Bottom,
        dismiss_threshold=0.35,
        velocity_threshold=500.0,
        fn(v, d) {
          dr_ref.val = Some(d)
          v
          .over(Is(true))
          .offset(Is((0.0, 100.0)))
          .width(Is(Some(400.0)))
          .height(Is(Some(200.0)))
          .ground(Is(c_rest))
          |> ignore
          d.handle(v)
          @headless.button(v, fn() { "关闭" }, fn(_) { open.set(false) }, fn(bv, _) {
            bv.width(Is(Some(80.0))).height(Is(Some(30.0))) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
  })
  // Open via button -> joins overlay_stack
  t.click(Button, label="打开抽屉")
  let tree = @ui.view_tree().unwrap()
  let open_count = @headless.overlays_open(tree)
  // Escape closes it and returns focus to opener
  t.key(@ui.key_escape)
  let after_esc = (open.get(), closes.val, @headless.overlays_open(tree))
  // Open again: slow short drag down (40 < 200 * 0.35 = 70) snaps back
  t.click(Button, label="打开抽屉")
  t.drag(200.0, 150.0, 200.0, 190.0, steps=20)
  let after_short = (open.get(), dr_ref.val.unwrap().drag_offset())
  // Drag down 90px (>= 70) dismisses
  t.drag(200.0, 150.0, 200.0, 240.0, steps=20)
  let after_long = (open.get(), closes.val)
  assert_eq((open_count, after_esc, after_short, after_long), (1, (false, 1, 0), (true, 0.0), (false, 2)))
}

///|
test "Drawer: multi-snap points, velocity flick, and can_drag scroll-handoff guard" {
  let open = @signals.signal(true)
  let snap = @signals.signal(1)
  let can_drag = @signals.signal(false)
  let snaps_told : Array[Int] = []
  let closes = Ref(0)
  let dr_ref : Ref[@headless.Drawer?] = Ref(None)
  let t = window(fn(root) {
    root.show(at_once=true, fn() { open.get() }, fn(s) {
      @headless.drawer(
        s,
        fn() { "多档抽屉" },
        fn() { open.get() },
        fn() {
          closes.val += 1
          open.set(false)
        },
        edge=Bottom,
        snap_points=[0.5, 1.0],
        active_snap=fn() { snap.get() },
        on_snap=fn(i) {
          snaps_told.push(i)
          snap.set(i)
        },
        dismiss_threshold=0.35,
        velocity_threshold=500.0,
        can_drag=fn() { can_drag.get() },
        fn(v, d) {
          dr_ref.val = Some(d)
          v
          .over(Is(true))
          .offset(Is((0.0, 100.0)))
          .width(Is(Some(400.0)))
          .height(Is(Some(200.0)))
          .ground(Is(c_rest))
          |> ignore
          d.handle(v)
        },
      )
      |> ignore
    })
  })
  // can_drag=false blocks drag hijacking
  t.drag(200.0, 120.0, 200.0, 260.0, steps=20)
  let blocked = (open.get(), snap.get(), dr_ref.val.unwrap().dragging())
  // Enable dragging: drag down 90px from snap=1 (1.0) -> projected=0.55 -> snaps to 0.5 (index 0)
  can_drag.set(true)
  t.draw()
  t.drag(200.0, 120.0, 200.0, 210.0, steps=20)
  let snapped_down = (open.get(), snap.get())
  // Drag up 160px from snap=0 (0.5, height=200 -> full_ext=400, projected=0.9) -> snaps back to 1.0 (index 1)
  t.drag(200.0, 240.0, 200.0, 80.0, steps=20)
  let snapped_up = (open.get(), snap.get())
  // Fast flick down from snap=1 steps down to snap=0; second fast flick down from lowest snap dismisses
  t.drag(200.0, 120.0, 200.0, 150.0, steps=2)
  let after_flick1 = (open.get(), snap.get())
  t.drag(200.0, 120.0, 200.0, 150.0, steps=2)
  let after_flick2 = (open.get(), closes.val)
  assert_eq(blocked, (true, 1, false))
  assert_eq(snapped_down, (true, 0))
  assert_eq(snapped_up, (true, 1))
  assert_eq(after_flick1, (true, 0))
  assert_eq(after_flick2, (false, 1))
  assert_eq(snaps_told, [0, 1, 0])
}

///|
test "drawer_rubber_pull: asymptotic curve properties" {
  assert_eq(@headless.drawer_rubber_pull(0.0, 16.0), 0.0)
  assert_eq(@headless.drawer_rubber_pull(-10.0, 16.0), 0.0)
  assert_eq(@headless.drawer_rubber_pull(10.0, 0.0), 0.0)
  let p1 = @headless.drawer_rubber_pull(16.0, 16.0)
  let p2 = @headless.drawer_rubber_pull(64.0, 16.0)
  let p3 = @headless.drawer_rubber_pull(1000.0, 16.0)
  assert_true(p1 > 0.0 && p1 < p2 && p2 < p3 && p3 < 16.0)
}

///|
test "Drawer: overpull_max rubber band, on_release, last_velocity, reverse-fling guard, extent_by, and slop" {
  let open = @signals.signal(true)
  let closes = Ref(0)
  let inner_clicks = Ref(0)
  let dyn_extent = @signals.signal(200.0)
  let releases : Array[(Double, Double, Bool)] = []
  let offset_at_release : Ref[Double] = Ref(0.0)
  let dr_ref : Ref[@headless.Drawer?] = Ref(None)
  let t = window(fn(root) {
    root.show(at_once=true, fn() { open.get() }, fn(s) {
      @headless.drawer(
        s,
        fn() { "高级抽屉" },
        fn() { open.get() },
        fn() {
          closes.val += 1
          open.set(false)
        },
        edge=Bottom,
        overpull_max=16.0,
        dismiss_threshold=0.35,
        velocity_threshold=500.0,
        on_release=fn(off, vel, will_close) {
          offset_at_release.val = dr_ref.val.unwrap().drag_offset()
          releases.push((off, vel, will_close))
        },
        fn(v, d) {
          dr_ref.val = Some(d)
          v
          .over(Is(true))
          .offset(Is((0.0, 100.0)))
          .width(Is(Some(400.0)))
          .height(Is(Some(200.0)))
          .ground(Is(c_rest))
          |> ignore
          d.handle(v, extent_by=fn() { dyn_extent.get() }, slop=8.0)
          @headless.button(v, fn() { "内部按钮" }, fn(_) { inner_clicks.val += 1 }, fn(bv, _) {
            bv.width(Is(Some(100.0))).height(Is(Some(36.0))) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
  })
  // Tap inner button with slop=8.0 is not swallowed by drawer handle.
  t.click(Button, label="内部按钮")
  assert_eq(inner_clicks.val, 1)
  // Over-pull upward (negative delta) produces asymptotic rubber-band offset in (-16.0, 0.0).
  t.press_at(200.0, 180.0)
  t.move_to(200.0, 120.0)
  let over_off = dr_ref.val.unwrap().drag_offset()
  assert_true(over_off < 0.0 && over_off > -16.0)
  t.release(200.0, 120.0)
  assert_true(offset_at_release.val < 0.0)
  assert_eq(open.get(), true)
  assert_eq(releases.length(), 1)
  assert_eq(releases[0].2, false)
  // Reverse fling protection: drag down past dismiss_threshold (90 > 70), then flick rapidly upward.
  t.press_at(200.0, 120.0)
  t.hold_move(200.0, 140.0)
  t.hold_move(200.0, 260.0)
  t.hold_move(200.0, 230.0)
  t.hold_move(200.0, 200.0)
  t.release(200.0, 200.0)
  assert_eq(open.get(), true)
  assert_true(dr_ref.val.unwrap().last_velocity() <= -500.0)
  // Dynamic extent_by: shrink extent to 100.0 so a 50px drag (> 35px) dismisses and reports will_close=true.
  dyn_extent.set(100.0)
  t.drag(200.0, 120.0, 200.0, 170.0, steps=20)
  assert_eq((open.get(), closes.val), (false, 1))
  assert_eq(releases[releases.length() - 1].2, true)
}
