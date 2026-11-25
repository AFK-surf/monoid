// Deterministic tests for `viewer_steps_node`: per-direction `awake_for(dir)` control, hidden/faded state
// (`takes == false`, unclickable and unreachable by screen readers), and fixed slot preservation.

///|
test "viewer_steps_node: awake_for controls left and right arrows independently and hides faded side from a11y" {
  let left_on = @signals.signal(false)
  let right_on = @signals.signal(false)
  let steps : Array[Int] = []
  let prev_label = t("web-main.preview.prevKey")
  let next_label = t("web-main.preview.nextKey")
  let tr = @ui.Tester::tree(
    fn(root) {
      let tips_at : Ref[@view.View?] = Ref(None)
      let tips = TipLayer::new(fn() { tips_at.val })
      root.box(fn(stage) {
        stage.grow(Is(1.0)).ground(By(fn() { theme().p.canvas })) |> ignore
        viewer_steps_node(
          stage,
          fn() { true },
          fn() { true },
          fn(dir) { if dir < 0 { left_on.get() } else { right_on.get() } },
          fn(_) { 1.0 },
          fn() { false },
          fn(dir) { steps.push(dir) },
          tips,
        )
        |> ignore
        tips_at.val = Some(stage.box(fn(l) { l.over(Is(true)) |> ignore }))
      })
      |> ignore
    },
    w=800.0,
    h=600.0,
    platform=0,
    theme=ui_theme_now,
  )
  tr.draw()
  // Both hidden at rest: neither button is reachable in semantics or clickable
  assert_eq(tr.all(Button, label=prev_label).length(), 0, msg="initial hidden: left unreachable")
  assert_eq(tr.all(Button, label=next_label).length(), 0, msg="initial hidden: right unreachable")
  // Wake only left arrow
  left_on.set(true)
  tr.run_for(wake_ms)
  let left_btns = tr.all(Button, label=prev_label)
  assert_eq(left_btns.length(), 1, msg="left awake: left reachable")
  assert_eq(tr.all(Button, label=next_label).length(), 0, msg="left awake: right still hidden and unreachable")
  let (lx, ly, lw, lh) = left_btns[0].rect
  tr.tap(lx + lw / 2.0, ly + lh / 2.0)
  tr.draw()
  assert_eq(steps, [-1], msg="left arrow click dispatches -1")
  // Move pointer away from left button, then switch to right arrow only; after sleep_ms + wake_ms left is completely
  // faded and unreachable in semantics
  tr.move_to(400.0, 300.0)
  left_on.set(false)
  right_on.set(true)
  tr.run_for(sleep_ms + wake_ms)
  assert_eq(tr.all(Button, label=prev_label).length(), 0, msg="left faded: unreachable in semantics")
  let right_btns = tr.all(Button, label=next_label)
  assert_eq(right_btns.length(), 1, msg="right awake: right reachable")
  // Clicking where left arrow used to be does nothing
  tr.tap(lx + lw / 2.0, ly + lh / 2.0)
  tr.draw()
  assert_eq(steps, [-1], msg="clicking hidden left slot does not step")
  let (rx, ry, rw, rh) = right_btns[0].rect
  tr.tap(rx + rw / 2.0, ry + rh / 2.0)
  tr.draw()
  assert_eq(steps, [-1, 1], msg="right arrow click dispatches +1")
}
