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

///|
/// Find the floating sheet glass rect (x, y, w, h) and the last quiet card rect/corners in the last drawn frame.
fn sheet_glass_and_card(t : @ui.Tester) -> ((Double, Double, Double, Double), (Double, Double, Double, Double, (Double, Double, Double, Double))) raise {
  let glasses = t.drawn_glass()
  assert_true(glasses.length() >= 1, msg="expected sheet glass")
  let g = glasses[glasses.length() - 1]
  let gx = g.0
  let gy = g.1
  let gw = g.2
  let gh = g.3
  let cards = t.drawn_rect_corners().filter(fn(r) {
    r.0 >= gx && r.1 >= gy && r.0 + r.2 <= gx + gw + 0.5 && r.1 + r.3 <= gy + gh + 0.5 && r.2 > 200.0 && r.3 > 40.0
  })
  assert_true(cards.length() >= 1, msg="expected card inside glass (\{gx},\{gy},\{gw},\{gh})")
  let c = cards[cards.length() - 1]
  ((gx, gy, gw, gh), (c.0, c.1, c.2, c.3, c.5))
}

///|
test "小屏悬浮抽屉内 quiet_card_node 与抽屉玻璃四角严格同心（左/右/底距 16pt，抽屉 42pt，卡片 26pt）" {
  let t = presenting_tester(phone, fn(_) {
    panel_nodes("智能体信息", from=Unanchored, fn(v, _) {
      quiet_card_node(v, last=fn() { true }, fn(k) {
        words_node(k, fn() { "模型：Gemini 4 Neon" }, fn() { paragraph }) |> ignore
        words_node(k, fn() { "上下文：12% 已用" }, fn() { paragraph }) |> ignore
      })
    })
  })
  open_it(t)
  t.run_for(@ui.move_most_ms)
  let ((gx, gy, gw, gh), (cx, cy, cw, ch, cr)) = sheet_glass_and_card(t)
  let left_gap = cx - gx
  let right_gap = gx + gw - (cx + cw)
  let bottom_gap = gy + gh - (cy + ch)
  assert_true((left_gap - panel_card_in).abs() < 0.5, msg="left gap \{left_gap} vs \{panel_card_in}")
  assert_true((right_gap - panel_card_in).abs() < 0.5, msg="right gap \{right_gap} vs \{panel_card_in}")
  assert_true((bottom_gap - panel_card_in).abs() < 0.5, msg="bottom gap \{bottom_gap} vs \{panel_card_in}")
  assert_true((cr.0 - card_corner).abs() < 0.5 && (cr.1 - card_corner).abs() < 0.5 && (cr.2 - card_corner).abs() < 0.5 && (cr.3 - card_corner).abs() < 0.5, msg="card corners \{Repr(cr)} vs \{card_corner}")
  let gcs = t.drawn_glass_corners()
  assert_true(gcs.length() >= 1 && (gcs[gcs.length() - 1].4 - pane_corner).abs() < 0.5, msg="glass corner \{Repr(gcs)}")
  assert_eq(t.audit(), [])
}

///|
test "小屏悬浮抽屉在 system_bars().bottom 为 0/24/48 时均正确避让导航栏且卡片底距保持 16pt" {
  for bar_b in [0.0, 24.0, 48.0] {
    let t = presenting_tester(phone, fn(_) {
      panel_nodes("抽屉避让", from=Unanchored, fn(v, _) {
        quiet_card_node(v, last=fn() { true }, fn(k) {
          words_node(k, fn() { "卡片第一行" }, fn() { paragraph }) |> ignore
          words_node(k, fn() { "卡片第二行" }, fn() { paragraph }) |> ignore
        })
      })
    })
    t.post(@hostapi.system_channel, "{\"bars\":{\"top\":0,\"bottom\":\{bar_b},\"left\":0,\"right\":0}}")
    open_it(t)
    t.run_for(@ui.move_most_ms)
    let ((gx, gy, gw, gh), (cx, cy, cw, ch, _)) = sheet_glass_and_card(t)
    let want_clear = dmax(sheet_float_inset, bar_b)
    let actual_clear = phone.2 - (gy + gh)
    assert_true((actual_clear - want_clear).abs() < 0.5, msg="bar=\{bar_b}: clear \{actual_clear} vs \{want_clear}")
    let left_gap = cx - gx
    let right_gap = gx + gw - (cx + cw)
    let bottom_gap = gy + gh - (cy + ch)
    assert_true((left_gap - panel_card_in).abs() < 0.5, msg="bar=\{bar_b}: left \{left_gap}")
    assert_true((right_gap - panel_card_in).abs() < 0.5, msg="bar=\{bar_b}: right \{right_gap}")
    assert_true((bottom_gap - panel_card_in).abs() < 0.5, msg="bar=\{bar_b}: bottom \{bottom_gap}")
    assert_eq(t.audit(), [], msg="bar=\{bar_b}")
  }
}

///|
test "小屏悬浮抽屉带 foot 按钮与 Confirm 按钮时通过全量 audit" {
  let t1 = presenting_tester(phone, fn(_) {
    panel_nodes(
      "带页脚抽屉",
      from=Unanchored,
      foot=fn(f, close) {
        button_node(f, fn() { "取消" }, close, tone=Ghost) |> ignore
        button_node(f, fn() { "确定" }, close, tone=Primary) |> ignore
      },
      fn(v, _) { words_node(v, fn() { "页脚测试正文" }, fn() { paragraph }) |> ignore },
    )
  })
  open_it(t1)
  t1.run_for(@ui.move_most_ms)
  assert_eq(t1.audit(), [])
  let t2 = presenting_tester(phone, fn(_) {
    confirm("删除这个对话？", "对话和它的记录会从这台工作站上删除。", "删除", fn() {  }, danger=true, warning="删除后不能恢复。")
  })
  open_it(t2)
  t2.run_for(@ui.move_most_ms)
  assert_eq(t2.audit(), [])
}

///|
test "小屏 capped=true tall=0.62 hugs=true 悬浮滚动抽屉含卡片列表时左右底均与浮岛同心" {
  let t = presenting_tester(phone, fn(_) {
    panel_nodes("滚动卡片", from=Unanchored, tall=0.62, hugs=true, fn(v, _) {
      quiet_card_node(v, last=fn() { true }, fn(k) {
        words_node(k, fn() { "第一项" }, fn() { paragraph }) |> ignore
        words_node(k, fn() { "第二项" }, fn() { paragraph }) |> ignore
      })
    })
  })
  open_it(t)
  t.run_for(@ui.move_most_ms)
  let ((gx, gy, gw, gh), (cx, cy, cw, ch, _)) = sheet_glass_and_card(t)
  assert_true((cx - gx - panel_card_in).abs() < 0.5, msg="left \{cx - gx}")
  assert_true((gx + gw - (cx + cw) - panel_card_in).abs() < 0.5, msg="right \{gx + gw - (cx + cw)}")
  assert_true((gy + gh - (cy + ch) - panel_card_in).abs() < 0.5, msg="bottom \{gy + gh - (cy + ch)}")
  assert_eq(t.audit(), [])
}

///|
/// Marker RGB for the simulated bottom floating chrome observer box.
let foot_obs_rgb : Int64 = 0x1A73E8L

///|
/// Observed drawn alpha (0.0..1.0) of the simulated bottom chrome box in the last frame.
fn foot_obs_alpha(t : @ui.Tester) -> Double {
  let mut best = 0.0
  for r in t.drawn_rects() {
    if (r.4 >> 8) == foot_obs_rgb {
      let a = (r.4 & 0xFFL).to_double() / 255.0
      if a > best {
        best = a
      }
    }
  }
  best
}

///|
/// A phone tester with a bottom chrome box driven by `sheet_foot_alpha(obs)` and a button to open a sheet.
fn foot_alpha_tester(open : (Anchor) -> Unit) -> @ui.Tester {
  presenters_reset()
  set_words(fn(key, _) { key })
  let (platform, w, h) = phone
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~, platform~)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(box) {
      box.grow(Is(1.0)).padding(Is((40.0, 40.0, 40.0, 40.0))).lines_up(Is(Some(Start))) |> ignore
      button_opens_node(box, fn() { "打开" }, fn(b) { open(Node(b)) }) |> ignore
      box.box(fn(obs) {
        obs
        .width(Is(Some(120.0)))
        .height(Is(Some(44.0)))
        .ground(Is((foot_obs_rgb << 8) | 0xFFL))
        .alpha(By(fn() { sheet_foot_alpha(obs) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  t
}

///|
test "小屏底抽屉打开过程 sheet_foot_alpha 从 1.0 平滑淡出至 0.0，静止时保持 0.0" {
  let t = foot_alpha_tester(fn(_) {
    panel_nodes("抽屉标题", from=Unanchored, fn(v, _) {
      v.box(fn(b) { b.height(Is(Some(240.0))) |> ignore }) |> ignore
      words_node(v, fn() { "抽屉正文" }, fn() { paragraph }) |> ignore
    })
  })
  assert_true((foot_obs_alpha(t) - 1.0).abs() < 0.01, msg="initial alpha \{foot_obs_alpha(t)}")
  t.tap_text("打开")
  let samples : Array[Double] = []
  let step = @motion.sheet_scrim_ms / 8.0
  for _ in [0, 1, 2, 3, 4, 5, 6, 7] {
    t.run_for(step)
    samples.push(foot_obs_alpha(t))
  }
  t.run_for(@ui.move_most_ms)
  let rest = foot_obs_alpha(t)
  assert_eq(rest, 0.0, msg="at rest alpha should be 0.0, got \{rest}, samples=\{Repr(samples)}")
  for i in 1..<samples.length() {
    assert_true(samples[i] <= samples[i - 1] + 0.01, msg="non-monotonic fade out: \{Repr(samples)}")
  }
  assert_true(samples.iter().any(fn(a) { a > 0.0 && a < 1.0 }), msg="expected smooth intermediate fade: \{Repr(samples)}")
}

///|
test "小屏底抽屉 1:1 向下拖拽时 sheet_foot_alpha 平滑回升，松手回弹回 0.0，拖过阈值关闭后平滑回到 1.0 并空闲" {
  let t = foot_alpha_tester(fn(_) {
    panel_nodes("抽屉标题", from=Unanchored, fn(v, _) {
      v.box(fn(b) { b.height(Is(Some(240.0))) |> ignore }) |> ignore
      words_node(v, fn() { "抽屉正文" }, fn() { paragraph }) |> ignore
    })
  })
  open_it(t)
  t.run_for(@ui.move_most_ms)
  assert_eq(foot_obs_alpha(t), 0.0)
  let (x, y0, w, h) = drag_sheet_rect(t)
  let cx = x + w / 2.0
  let cy = y0 + 20.0
  // (1:1 drag past 35% of sheet height so cover drops below 0.65 and alpha begins returning, but keep under close? No: first test spring-back with 50pt then full drag with 55% + 75%)
  t.press_at(cx, cy)
  for frac in [0.25, 0.5, 0.75, 1.0] {
    t.hold_move(cx, cy + 50.0 * frac)
  }
  t.advance(@ui.input_step_ms * 6.0)
  t.release(cx, cy + 50.0)
  t.run_for(@ui.move_most_ms)
  assert_true(presenting(), msg="sheet stays open after short drag")
  assert_eq(foot_obs_alpha(t), 0.0, msg="alpha back to 0.0 after spring back")
  // (drag down 50% then 75% of height: cover = 0.50 -> alpha ~ 0.23, cover = 0.25 -> alpha ~ 0.62)
  let d50 = h * 0.5
  let d75 = h * 0.75
  t.press_at(cx, cy)
  t.hold_move(cx, cy + d50)
  let a50 = foot_obs_alpha(t)
  t.hold_move(cx, cy + d75)
  let a75 = foot_obs_alpha(t)
  assert_true(a50 > 0.05 && a50 < 0.9, msg="50% drag mid alpha: \{a50}")
  assert_true(a75 > a50 + 0.1, msg="75% drag higher alpha: a50=\{a50}, a75=\{a75}")
  t.release(cx, cy + d75)
  t.run_for(@ui.move_most_ms)
  assert_false(presenting(), msg="sheet closed")
  assert_true((foot_obs_alpha(t) - 1.0).abs() < 0.01, msg="alpha restored to 1.0: \{foot_obs_alpha(t)}")
  t.assert_idle()
}

///|
test "小屏底抽屉多页切换（panel_page）与 in_place 替换全程 sheet_foot_alpha 保持 0.0 无闪烁" {
  // 1) panel_page (panel -> panel)
  let t1 = foot_alpha_tester(fn(_) {
    panel_nodes("第一页", from=Unanchored, fn(v, close) {
      words_node(v, fn() { "第一页内容" }, fn() { paragraph }) |> ignore
      button_node(v, fn() { "去第二页" }, fn() {
        close()
        panel_nodes("第二页", from=Unanchored, tall=0.6, fn(v2, _) {
          words_node(v2, fn() { "第二页内容" }, fn() { paragraph }) |> ignore
        })
      })
      |> ignore
    })
  })
  open_it(t1)
  t1.run_for(@ui.move_most_ms)
  assert_eq(foot_obs_alpha(t1), 0.0)
  let step = @motion.sheet_scrim_ms / 8.0
  t1.tap_text("去第二页")
  for _ in [0, 1, 2, 3, 4, 5, 6, 7] {
    assert_eq(foot_obs_alpha(t1), 0.0, msg="panel_page push must not flicker")
    t1.run_for(step)
  }
  t1.key(@ui.key_escape)
  for _ in [0, 1, 2, 3, 4, 5, 6, 7] {
    assert_eq(foot_obs_alpha(t1), 0.0, msg="panel_page pop must not flicker")
    t1.run_for(step)
  }
  // 2) in_place replacement (panel -> confirm)
  let t2 = foot_alpha_tester(fn(_) {
    panel_nodes("菜单面板", from=Unanchored, fn(v, close) {
      button_node(v, fn() { "删除" }, fn() {
        close()
        confirm("确认删除？", "删除后不可恢复", "删除", fn() {  }, danger=true)
      })
      |> ignore
    })
  })
  open_it(t2)
  t2.run_for(@ui.move_most_ms)
  assert_eq(foot_obs_alpha(t2), 0.0)
  t2.tap_text("删除")
  for _ in [0, 1, 2, 3, 4, 5, 6, 7] {
    assert_eq(foot_obs_alpha(t2), 0.0, msg="in_place replacement must not flicker")
    t2.run_for(step)
  }
  t2.key(@ui.key_escape)
  t2.run_for(@ui.move_most_ms)
  assert_true((foot_obs_alpha(t2) - 1.0).abs() < 0.01, msg="restored after close")
}
