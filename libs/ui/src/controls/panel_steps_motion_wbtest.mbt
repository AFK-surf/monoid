// 大屏居中多步弹窗（panel_steps_node.mbt）：底层 0.28× 视差退让、连续压暗与零残留、步进途中反向打断速度连续。

///|
/// A centred multi-step panel on 大屏, opened and at rest on step 1.
fn steps_dialog_tester() -> @ui.Tester {
  let t = presenting_tester(desk, fn(_) {
    panel_nodes(
      "第一步",
      from=Unanchored,
      steps=true,
      fn(v, _) {
        v.box(fn(col) {
          col.gap(Is(12.0)) |> ignore
          words_node(col, fn() { "第一步内容" }, fn() { paragraph }) |> ignore
          button_node(col, fn() { "进入第二步" }, fn() {
            panel_go_nodes("第二步", fn(v2, _) {
              words_node(v2, fn() { "第二步内容" }, fn() { paragraph }) |> ignore
            })
          })
          |> ignore
        })
        |> ignore
      },
    )
  })
  open_it(t)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Count drawn semi-transparent dark rects inside `box` (excluding the full-window scrim).
fn dark_overlays_in(t : @ui.Tester, box : (Double, Double, Double, Double)) -> Array[(Double, Double, Double, Double, Double)] {
  let (bx, by, bw, bh) = box
  let out : Array[(Double, Double, Double, Double, Double)] = []
  for r in t.drawn_rects() {
    let rgb = (r.4 >> 8) & 0xFFFFFFL
    let a = (r.4 & 0xFFL).to_double() / 255.0
    if rgb == 0L && a > 0.0 && a < 0.25 && r.0 >= bx - 2.0 && r.1 >= by - 2.0 && r.0 + r.2 <= bx + bw + 2.0 && r.1 + r.3 <= by + bh + 2.0 && r.2 <= bw + 2.0 {
      out.push((r.0, r.1, r.2, r.3, a))
    }
  }
  out
}

///|
test "大屏居中多步弹窗步进时底层按 0.28× 视差退让并连续压暗，静止后零残留" {
  let t = steps_dialog_tester()
  let dlg = t.get(Dialog, label="第一步").rect
  let x1_rest = t.find("第一步内容").unwrap().0
  assert_eq(dark_overlays_in(t, dlg).length(), 0, msg="no dark dim/edge overlay at rest on step 1")
  assert_eq(t.audit(), [])

  t.tap_text("进入第二步")
  if !@ui.test_at_a_rate() {
    for _ in [0, 1, 2, 3, 4, 5] {
      t.frame()
    }
    let x1_mid = t.find("第一步内容").unwrap().0
    let shift = x1_rest - x1_mid
    // (0.28× parallax: step 1 shifts left smoothly, well below 0.35 * dialog width)
    assert_true(shift > 4.0 && shift < dlg.2 * 0.35, msg="step 1 parallax shift=\{shift}, dlg_w=\{dlg.2}")
    // (mid-slide has dimming/edge overlays inside dialog)
    let overlays = dark_overlays_in(t, dlg)
    assert_true(overlays.length() > 0, msg="expected dimming/edge overlay mid-slide")
  }
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("第二步内容") is Some(_))
  assert_true(t.find("第一步内容") is None)
  let dlg2 = t.get(Dialog, label="第一步").rect
  assert_eq(dark_overlays_in(t, dlg2).length(), 0, msg="no residual dim/edge overlay at rest on step 2")
  assert_eq(t.audit(), [])

  // pop back to step 1
  t.key(@ui.key_escape)
  t.run_for(@ui.move_most_ms)
  let x1_back = t.find("第一步内容").unwrap().0
  assert_true((x1_back - x1_rest).abs() < 0.5, msg="step 1 returns to exact rest x: rest=\{x1_rest}, back=\{x1_back}")
  assert_true(t.find("第二步内容") is None)
  assert_eq(dark_overlays_in(t, dlg).length(), 0, msg="no residual overlay after pop back")
  assert_eq(t.audit(), [])
}

///|
test "大屏居中多步弹窗步进途中反向打断，位置与速度连续且平滑折返" {
  let t = steps_dialog_tester()
  let dlg = t.get(Dialog, label="第一步").rect
  t.tap_text("进入第二步")
  if !@ui.test_at_a_rate() {
    // (mid-slide: ~100ms in, step 2 is actively sliding left toward rest)
    for _ in [0, 1, 2, 3, 4, 5] {
      t.frame()
    }
    let x_before = t.find("第二步内容").map(fn(p) { p.0 }).unwrap_or(-999.0)
    assert_true(x_before > dlg.0 + 20.0 && x_before < dlg.0 + dlg.2, msg="step 2 mid-slide: \{x_before}, dlg=\{Repr(dlg)}")
    t.key(@ui.key_escape)
    t.frame()
    let x_f1 = t.find("第二步内容").map(fn(p) { p.0 }).unwrap_or(-999.0)
    // (velocity continuity: carries leftward momentum on frame 1 without teleporting)
    assert_true(x_f1 < x_before && (x_f1 - x_before).abs() < 80.0, msg="continuous after interrupt: before=\{x_before}, f1=\{x_f1}")
    t.frame()
    let x_f2 = t.find("第二步内容").map(fn(p) { p.0 }).unwrap_or(-999.0)
    // (decelerating smoothly toward turning right: step 2 delta is more positive than step 1 delta)
    assert_true(x_f2 - x_f1 > x_f1 - x_before, msg="decelerating smoothly: before=\{x_before}, f1=\{x_f1}, f2=\{x_f2}")
  } else {
    t.run_for(@ui.move_ms(dlg.2) / 3.0)
    t.key(@ui.key_escape)
  }
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("第一步内容") is Some(_))
  assert_true(t.find("第二步内容") is None)
  assert_eq(t.audit(), [])
}
