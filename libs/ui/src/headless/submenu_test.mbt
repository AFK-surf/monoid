// Tests for headless Submenu aiming corridor geometry, corridor_ms grace delay, and touch-open persistence.

///|
test "point_in_triangle and submenu_in_aim_corridor geometry" {
  // Right triangle (0,0)-(10,0)-(0,10)
  assert_true(@headless.point_in_triangle(2.0, 2.0, 0.0, 0.0, 10.0, 0.0, 0.0, 10.0))
  assert_true(@headless.point_in_triangle(0.0, 0.0, 0.0, 0.0, 10.0, 0.0, 0.0, 10.0))
  assert_true(!@headless.point_in_triangle(8.0, 8.0, 0.0, 0.0, 10.0, 0.0, 0.0, 10.0))
  // Aiming from trigger leave point (100, 50) toward submenu at (160, 20, 120, 160)
  assert_true(@headless.submenu_in_aim_corridor(130.0, 60.0, 100.0, 50.0, 160.0, 20.0, 120.0, 160.0))
  // Moving vertically downward away from corridor -> outside
  assert_true(!@headless.submenu_in_aim_corridor(100.0, 120.0, 100.0, 50.0, 160.0, 20.0, 120.0, 160.0))
  // Sub-1pt jitter at leave point -> false
  assert_true(!@headless.submenu_in_aim_corridor(100.5, 50.2, 100.0, 50.0, 160.0, 20.0, 120.0, 160.0))
  // Zero-size menu -> false
  assert_true(!@headless.submenu_in_aim_corridor(130.0, 60.0, 100.0, 50.0, 160.0, 20.0, 0.0, 160.0))
}

///|
test "Submenu: corridor_ms grace when leaving toward submenu panel vs close_delay_ms outside corridor" {
  let open = @signals.signal(false)
  let sub = @headless.Submenu::new(
    fn() { open.get() },
    fn(v) { open.set(v) },
    open_delay_ms=100.0,
    close_delay_ms=100.0,
    corridor_ms=300.0,
  )
  let t = window(fn(root) {
    root.row(Is(true)) |> ignore
    @headless.menu(root, label=fn() { "主菜单" }, fn(v, m) {
      v.width(Is(Some(120.0))).height(Is(Some(160.0))) |> ignore
      m.sub_trigger(v, sub, fn() { "更多" }, fn(tv, _) {
        tv.width(Is(Some(120.0))).height(Is(Some(40.0))).ground(Is(c_rest)) |> ignore
      })
      |> ignore
    })
    |> ignore
    root.box(fn(gap) { gap.width(Is(Some(40.0))).height(Is(Some(160.0))) |> ignore }) |> ignore
    root.show(at_once=true, fn() { open.get() }, fn(s) {
      sub.menu(s, label=fn() { "子菜单" }, fn(sv, sm) {
        sv
        .width(Is(Some(120.0)))
        .height(Is(Some(160.0)))
        .ground(Is(c_rest))
        |> ignore
        sm.item(sv, fn() { "子项" }, fn(_) { open.set(false) }, fn(iv, _) {
          iv.width(Is(Some(120.0))).height(Is(Some(32.0))) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  let sub_open_ms = 100.0
  let sub_half_corridor_ms = 150.0
  let (tx, ty, tw, th) = t.get(MenuItem, label="更多").rect
  // Hover trigger -> open after 100ms
  t.move_to(tx + tw - 10.0, ty + th / 2.0)
  t.run_for(sub_open_ms)
  assert_eq(open.get(), true)
  let (mx, my, _, mh) = t.get(Menu, label="子菜单").rect
  // Leave toward submenu panel (midpoint between trigger right edge and submenu near edge)
  t.move_to((tx + tw + mx) / 2.0, my + mh / 2.0)
  let in_corr = sub.in_corridor()
  // After 150ms (> close_delay_ms 100ms, < corridor_ms 300ms): still open!
  t.run_for(sub_half_corridor_ms)
  let still_open = open.get()
  // After another 150ms (total 300ms): closes
  t.run_for(sub_half_corridor_ms)
  let closed_after_corridor = open.get()
  assert_eq((in_corr, still_open, closed_after_corridor), (true, true, false))
}

///|
test "Submenu::open_touch keeps submenu open without hover and closes on outside press" {
  let open = @signals.signal(false)
  let sub = @headless.Submenu::new(
    fn() { open.get() },
    fn(v) { open.set(v) },
    open_delay_ms=100.0,
    close_delay_ms=100.0,
  )
  let t = window(fn(root) {
    @headless.menu(root, label=fn() { "主菜单" }, fn(v, m) {
      v.width(Is(Some(120.0))).height(Is(Some(160.0))) |> ignore
      m.sub_trigger(v, sub, fn() { "更多" }, fn(tv, _) {
        tv.width(Is(Some(120.0))).height(Is(Some(40.0))).ground(Is(c_rest)) |> ignore
      })
      |> ignore
    })
    |> ignore
    root.show(at_once=true, fn() { open.get() }, fn(s) {
      sub.menu(s, label=fn() { "子菜单" }, fn(sv, sm) {
        sv
        .over(Is(true))
        .offset(Is((160.0, 0.0)))
        .width(Is(Some(120.0)))
        .height(Is(Some(80.0)))
        .ground(Is(c_rest))
        |> ignore
        sm.item(sv, fn() { "子项" }, fn(_) { open.set(false) }, fn(iv, _) {
          iv.width(Is(Some(120.0))).height(Is(Some(32.0))) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  let sub_stay_ms = 500.0
  sub.open_touch()
  t.draw()
  // Pointer is nowhere near trigger or submenu; stays open well past close_delay_ms.
  t.run_for(sub_stay_ms)
  let stayed_open = open.get()
  // Outside press dismisses it.
  t.tap(350.0, 250.0)
  assert_eq((stayed_open, open.get()), (true, false))
}
