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
