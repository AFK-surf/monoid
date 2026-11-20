// 小屏抽屉拖拽遮罩实时联动与步进页面打断速度连续（sheet_node.mbt）。

///|
/// Full-window sheet scrim alpha (0.0..1.0) in the last drawn frame.
fn sheet_scrim_alpha(t : @ui.Tester) -> Double {
  let (_, w, h) = phone
  let mut best = 0.0
  for r in t.drawn_rects() {
    if r.0 <= 0.0 && r.1 <= 0.0 && r.2 >= w && r.3 >= h && (r.4 & 0xFFL) > 0L && (r.4 & 0xFFL) < 0xFFL {
      let a = (r.4 & 0xFFL).to_double() / 255.0
      if a > best {
        best = a
      }
    }
  }
  best
}

///|
/// A non-`grows` sheet on 小屏 of known height (~340pt), opened and at rest.
fn drag_sheet_tester() -> @ui.Tester {
  let t = presenting_tester(phone, fn(_) {
    panel_nodes("抽屉标题", from=Unanchored, fn(v, _) {
      v.box(fn(b) { b.height(Is(Some(240.0))) |> ignore }) |> ignore
      words_node(v, fn() { "抽屉正文" }, fn() { paragraph }) |> ignore
    })
  })
  open_it(t)
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Dialog rect of the open sheet.
fn drag_sheet_rect(t : @ui.Tester) -> (Double, Double, Double, Double) {
  match t.query(@ui.Role::Dialog) {
    Some(s) => s.rect
    None => (-1.0, -1.0, -1.0, -1.0)
  }
}

///|
test "小屏抽屉下拖 40% 与 70% 时，遮罩透明度随拖拽实时单调下降" {
  let t = drag_sheet_tester()
  let a0 = sheet_scrim_alpha(t)
  assert_true(a0 > 0.2, msg="at rest scrim alpha \{a0}")
  let (x, y0, w, h) = drag_sheet_rect(t)
  assert_true(h > 150.0, msg="sheet height \{h}")
  let cx = x + w / 2.0
  let cy = y0 + 20.0
  let d40 = h * 0.4
  let d70 = h * 0.7
  t.press_at(cx, cy)
  t.hold_move(cx, cy + d40)
  let a40 = sheet_scrim_alpha(t)
  t.hold_move(cx, cy + d70)
  let a70 = sheet_scrim_alpha(t)
  assert_true(a40 < a0 - 0.05, msg="40% drag should dim less: a0=\{a0}, a40=\{a40}")
  assert_true(a70 < a40 - 0.04, msg="70% drag should dim even less: a40=\{a40}, a70=\{a70}")
  assert_true(a70 > 0.0, msg="70% drag scrim still visible: a70=\{a70}")
  t.release(cx, cy + d70)
  t.run_for(@ui.move_most_ms)
}

///|
test "小屏抽屉下拖未达关闭阈值松手弹回时，遮罩随抽屉平滑回升至稳态" {
  let t = drag_sheet_tester()
  let a0 = sheet_scrim_alpha(t)
  let (x, y0, w, _) = drag_sheet_rect(t)
  let cx = x + w / 2.0
  let cy = y0 + 20.0
  // (50pt < sheet_drag_close (80pt), paused before release so speed is 0 and it springs back)
  t.press_at(cx, cy)
  for frac in [0.25, 0.5, 0.75, 1.0] {
    t.hold_move(cx, cy + 50.0 * frac)
  }
  let a_drag = sheet_scrim_alpha(t)
  assert_true(a_drag < a0 - 0.02, msg="dragged scrim should be lighter: a0=\{a0}, a_drag=\{a_drag}")
  t.advance(@ui.input_step_ms * 6.0)
  t.release(cx, cy + 50.0)
  t.run_for(@ui.move_most_ms)
  let a_rest = sheet_scrim_alpha(t)
  assert_true((a_rest - a0).abs() < 0.02, msg="scrim should recover to rest: a0=\{a0}, a_rest=\{a_rest}")
}

///|
test "小屏抽屉拖过关闭阈值松手后，首帧遮罩不回弹并平滑淡出至 0" {
  let t = drag_sheet_tester()
  let a0 = sheet_scrim_alpha(t)
  let (x, y0, w, h) = drag_sheet_rect(t)
  let cx = x + w / 2.0
  let cy = y0 + 20.0
  let drag_y = dmax(h * 0.55, 140.0)
  t.press_at(cx, cy)
  for frac in [0.25, 0.5, 0.75, 1.0] {
    t.hold_move(cx, cy + drag_y * frac)
  }
  let a_release = sheet_scrim_alpha(t)
  assert_true(a_release < a0 - 0.06, msg="before release scrim should be lighter: a0=\{a0}, a_release=\{a_release}")
  t.release(cx, cy + drag_y)
  if !@ui.test_at_a_rate() {
    t.frame()
    let a_first = sheet_scrim_alpha(t)
    assert_true(a_first <= a_release + 0.01, msg="scrim must not jump back up on close: release=\{a_release}, first=\{a_first}")
  }
  t.run_for(@ui.move_most_ms)
  assert_eq(sheet_scrim_alpha(t), 0.0)
  assert_false(presenting())
}

///|
test "小屏抽屉二级页面推入中途立刻返回，位置与速度连续且平滑收尾" {
  let t = presenting_tester(phone, fn(_) {
    panel_nodes(
      "第一页",
      fn(v, close) {
        words_node(v, fn() { "第一页内容" }, fn() { paragraph }) |> ignore
        button_node(v, fn() { "去第二页" }, fn() {
          close()
          panel_nodes("第二页", fn(v2, _) { words_node(v2, fn() { "第二页内容" }, fn() { paragraph }) |> ignore }, from=Unanchored)
        })
        |> ignore
      },
      from=Unanchored,
    )
  })
  open_it(t)
  t.run_for(@ui.move_most_ms)
  t.tap_text("去第二页")
  if !@ui.test_at_a_rate() {
    // (mid-slide: ~100ms in, page 2 is actively sliding left toward x=0)
    for _ in [0, 1, 2, 3, 4, 5] {
      t.frame()
    }
    let x_before = t.find("第二页内容").map(fn(p) { p.0 }).unwrap_or(-999.0)
    assert_true(x_before > 20.0 && x_before < 420.0, msg="page 2 mid-slide: \{x_before}")
    t.key(@ui.key_escape)
    t.frame()
    let x_f1 = t.find("第二页内容").map(fn(p) { p.0 }).unwrap_or(-999.0)
    // (velocity continuity: carries leftward momentum on frame 1 without teleporting)
    assert_true(x_f1 < x_before && (x_f1 - x_before).abs() < 80.0, msg="continuous after interrupt: before=\{x_before}, f1=\{x_f1}")
    t.frame()
    let x_f2 = t.find("第二页内容").map(fn(p) { p.0 }).unwrap_or(-999.0)
    // (decelerating smoothly toward turning right: step 2 is more positive than step 1)
    assert_true(x_f2 - x_f1 > x_f1 - x_before, msg="decelerating smoothly: before=\{x_before}, f1=\{x_f1}, f2=\{x_f2}")
  } else {
    t.run_for(@ui.move_ms(390.0) / 3.0)
    t.key(@ui.key_escape)
  }
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("第一页内容") is Some(_))
  assert_true(t.find("第二页内容") is None)
}
