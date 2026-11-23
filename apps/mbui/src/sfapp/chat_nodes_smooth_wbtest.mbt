// Smoothness and one-way gate for the chat's page made as nodes (chat_page_nodes = true) with all Tester frame-to-frame
// look checks enabled (words_over_held = true, check_looks = true: sizes_steady, rows_steady, words_over, gaps_steady),
// never listed in motion_counted:
// 1. Answering a decision card ("一起换" -> "选择了「一起换」") enters once and stays at alpha 1.0 with its right edge
//    steady as the agent's follow-up answer arrives after it (#27, #8).
// 2. Sending a message while an agent works, then receiving the agent's reply after the bubble lands, on 大屏 and 小屏.
// 3. Starting a new chat (NewChat -> Chat) on 大屏 and 小屏, its composer made as nodes (its box flying down from where
//    NewChat's centered composer stood).
// 4. Scrolling up from the foot, fading in 跳到最新, and pressing it to glide back while the button fades out.
// 5. Opening and closing the side panel on 大屏 with no horizontal step.

///|
test "chat_page_nodes smoothness: decision card pick enters once and never replays or shifts right edge when later messages arrive (#27, #8)" {
  if @ui.test_at_a_rate() {
    return
  }
  for screen in [dk_screens[0]] {
    let (name, w, h, platform) = screen
    new_run()
    let src = fixture_app("chat")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, words_over_held=true)
    t.set_rows_on_pixels(true)
    t.set_frame_period(1000.0 / 60.0)
    let seen : Array[(Double, Double, Double, Double)] = []
    let start = t.time()
    let script =
      #|timeout 20000
      #|until =一起换
      #|wait 600
      #|tap =一起换
      #|wait 2600
      #|exit
    let min_y = if w >= @sf.page_narrow_most { @sf.wide_bar_h + 8.0 } else { 120.0 }
    t.drive(script, each=fn(t) {
      for wd in t.words() {
        let (txt, x, y, ww, _, a) = wd
        // (y >= min_y: on 390x844, the list scrolls down as the new reply arrives at the foot, carrying this earlier row up
        // into the top bar's scroll-edge fade band)
        if txt.contains("选择了「一起换」") && a > 0.02 && y >= min_y {
          seen.push((t.time() - start, x, ww, a))
          break
        }
      }
    })
    |> ignore
    assert_true(seen.length() > 10, msg="\{name}: picked line not seen across frames (\{seen.length()})")
    let mut reached_full = false
    let mut right_at_full = 0.0
    for s in seen {
      let (at, x, ww, a) = s
      if !reached_full {
        if a >= 0.99 {
          reached_full = true
          right_at_full = x + ww
        }
      } else {
        assert_true(a >= 0.99, msg="\{name} @\{at.round()}ms: picked line replayed fade (alpha=\{a})")
        assert_true(
          (x + ww - right_at_full).abs() <= 0.6,
          msg="\{name} @\{at.round()}ms: picked line right edge shifted from \{right_at_full} to \{x + ww}",
        )
      }
    }
    assert_true(reached_full, msg="\{name}: picked line never reached full alpha: \{Repr(seen)}")
  }
}

///|
test "chat_page_nodes smoothness: NewChat -> Chat glides the composer down on 大屏 and keeps words steady on 小屏" {
  for screen in dk_screens {
    let (name, w, h, platform) = screen
    new_run()
    let fixture = if w >= @sf.page_narrow_most { "chat" } else { "newchat" }
    let src = fixture_app(fixture)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, words_over_held=true)
    t.set_rows_on_pixels(true)
    t.run_for(@ui.move_most_ms * 2.0)
    if w >= @sf.page_narrow_most {
      t.tap_text("新建对话")
      t.run_for(@ui.move_most_ms)
    }
    // (where the new chat's composer stands: its box, made as nodes)
    let new_rect = @sfpages.composer_node_box(@sfpages.new_chat_drafts + "ws1")
    t.tap_text("做任何事")
    t.run_for(@ui.move_most_ms)
    t.type_text("平滑度门禁首句测试")
    t.run_for(@ui.move_most_ms)
    if !@ui.test_at_a_rate() && w >= @sf.page_narrow_most {
      guard new_rect is Some((_, fy, _, fh)) else {
        fail("\{name}: NewChat composer rect not measured")
      }
      tap_send(t)
      t.draw()
      // first frame in Chat: composer_node's foot flies from NewChat's foot without placeholder overlapping the flying words
      // (what is drawn, not what is found: the field keeps its placeholder to be found by while it is drawn in no ink)
      let hints = t.text_runs().filter(fn(r) {
        r.text == @sf.t("web-main.composer.placeholder") || r.text.contains("输入")
      })
      assert_eq(hints, [], msg="\{name}: composer placeholder overlapped flying words: \{Repr(hints)}")
      match t.query(Button, label=@sf.t("web-main.composer.attach")) {
        Some(plus) =>
          assert_true(
            plus.rect.1 >= fy + fh - 52.0 && plus.rect.1 <= fy + fh + 4.0,
            msg="\{name}: attach button at \{plus.rect.1}, expected near NewChat foot \{fy + fh}",
          )
        None => ()
      }
      t.run_for(@sfbase.flight_most_ms + @sfbase.new_leave_ms + @ui.move_most_ms)
      // (the cursor in it as the chat comes with keyboard and mouse: its placeholder drawn once it is let go)
      t.ctx().blur()
      t.run_for(@sfpages.let_go_ms + @sfpages.composer_shape_ms + @sf.hint_back_ms)
      assert_true(
        t.text_runs().iter().any(fn(r) { r.text == @sf.t("web-main.composer.placeholder") || r.text.contains("输入") }),
        msg="\{name}: composer placeholder did not fade in after blur",
      )
    } else {
      tap_send(t)
      t.run_for(@sfbase.flight_carry_after_ms + @sfbase.flight_most_ms + @sfbase.new_leave_ms + @ui.move_most_ms)
    }
    assert_true(app.nav.top() is Chat(_), msg="\{name}: did not become Chat")
  }
}

///|
test "chat_page_nodes smoothness: send, scroll away + 跳到最新 glide, and 大屏 side panel toggle pass full look checks" {
  let screen = dk_screens[0]
  let (name, w, h, _) = screen
  let (tp, srcp) = dk_open(screen)
  @sfdesk.side_toggle(srcp, dk_chat, "s-c1")
  tp.run_for(@ui.move_most_ms)
  @sfdesk.side_toggle(srcp, dk_chat, "s-c1")
  tp.run_for(@ui.move_most_ms)
  let (ts, _) = dk_open(screen)
  ts.move_to(w / 2.0, h / 2.0)
  ts.wheel(w / 2.0, h / 2.0, -700.0)
  ts.run_for(@ui.move_most_ms)
  if ts.query(Button, label=@sf.t("web-main.chat.toLatest")) is Some(_) {
    ts.click(Button, label=@sf.t("web-main.chat.toLatest"))
    ts.run_for(@ui.move_most_ms * 2.0)
  }
  let (t, _) = dk_open(screen)
  guard composer_field(t) is Some((cx, cy, cw, ch)) else { fail("\{name}: no composer field") }
  t.tap(cx + cw / 2.0, cy + ch / 2.0)
  t.run_for(@ui.move_most_ms)
  t.type_text("检查发送与回复平滑度")
  t.run_for(@ui.move_most_ms)
  tap_send(t)
  t.run_for(@sfbase.flight_most_ms + @ui.move_most_ms)
}

///|
test "chat_page_nodes smoothness: composer Shift+Enter with image and file attachments animates smoothly without silent snap" {
  let screen = dk_screens[0]
  let (name, w, h, platform) = screen
  new_run()
  let src = fixture_app("chat")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, words_over_held=true)
  t.set_rows_on_pixels(true)
  if !@ui.test_at_a_rate() {
    t.set_frame_period(1000.0 / 60.0)
  }
  let msg_ys : Array[(Double, Double)] = []
  let file_ys : Array[(Double, Double)] = []
  let pill_ys : Array[(Double, Double)] = []
  let saw_first_line = Ref(false)
  let saw_second_line = Ref(false)
  let script =
    #|timeout 20000
    #|until 发消息
    #|wait 300
    #|tap 发消息
    #|wait 200
    #|picks 截图.png:24x18
    #|key cmd+u
    #|wait 450
    #|picks 构建日志.log:2000
    #|key cmd+u
    #|wait 450
    #|type 第一行带附件
    #|wait 100
    #|key shift+enter
    #|type 第二行测平滑换行
    #|wait 450
    #|exit
  t.drive(script, each=fn(t) {
    let mut has_first = false
    let mut has_second = false
    let mut msg_y : Double? = None
    let mut file_y : Double? = None
    let mut pill_y : Double? = None
    for r in t.text_runs() {
      if r.text.contains("第一行带附件") {
        has_first = true
      }
      if r.text.contains("第二行测平滑换行") {
        has_second = true
      }
      if file_y is None && r.text.contains("构建日志") {
        file_y = Some(r.top)
      }
    }
    for wd in t.words() {
      let (txt, _, y, _, _, a) = wd
      if a <= 0.02 {
        continue
      }
      if msg_y is None && txt.contains("一起换") {
        msg_y = Some(y)
      }
      if file_y is None && txt.contains("构建日志.log") {
        file_y = Some(y)
      }
      if pill_y is None && txt.contains("Willow") && y > 400.0 {
        pill_y = Some(y)
      }
    }
    if has_first {
      saw_first_line.val = true
    }
    if has_second {
      saw_second_line.val = true
    }
    if saw_first_line.val {
      match msg_y {
        Some(y) => msg_ys.push((t.time(), y))
        None => ()
      }
      match file_y {
        Some(y) => file_ys.push((t.time(), y))
        None => ()
      }
      match pill_y {
        Some(y) => pill_ys.push((t.time(), y))
        None => ()
      }
    }
  })
  |> ignore
  assert_true(saw_first_line.val && saw_second_line.val, msg="\{name}: failed to type both lines")
  assert_true(msg_ys.length() >= 4, msg="\{name}: too few message samples (\{msg_ys.length()})")
  assert_true(file_ys.length() >= 4, msg="\{name}: too few file chip samples (\{file_ys.length()})")
  assert_true(pill_ys.length() >= 4, msg="\{name}: too few pill samples (\{pill_ys.length()})")

  let msg_start = msg_ys[0].1
  let msg_end = msg_ys[msg_ys.length() - 1].1
  let total_shift = msg_start - msg_end
  assert_true(
    total_shift >= 15.0,
    msg="\{name}: expected message list to shift up >= 15pt on newline, got \{total_shift} (\{msg_start} -> \{msg_end})",
  )

  let file_start = file_ys[0].1
  let file_end = file_ys[file_ys.length() - 1].1
  assert_true(
    (file_start - file_end - total_shift).abs() < 2.0,
    msg="\{name}: file chip total shift \{file_start - file_end} diverged from message shift \{total_shift}",
  )

  let pill_start = pill_ys[0].1
  let pill_end = pill_ys[pill_ys.length() - 1].1
  assert_true(
    (pill_start - pill_end - total_shift).abs() < 2.0,
    msg="\{name}: pill total shift \{pill_start - pill_end} diverged from message shift \{total_shift}",
  )

  // Monotonic upward movement (no downward reversal) across all frame rates.
  for i in 1..<msg_ys.length() {
    let dy = msg_ys[i].1 - msg_ys[i - 1].1
    assert_true(dy <= 0.5, msg="\{name}: message reversed downward by \{dy} at t=\{msg_ys[i].0}")
  }
  for i in 1..<file_ys.length() {
    let dy = file_ys[i].1 - file_ys[i - 1].1
    assert_true(dy <= 0.5, msg="\{name}: file chip reversed downward by \{dy} at t=\{file_ys[i].0}")
  }
  for i in 1..<pill_ys.length() {
    let dy = pill_ys[i].1 - pill_ys[i - 1].1
    assert_true(dy <= 0.5, msg="\{name}: pill reversed downward by \{dy} at t=\{pill_ys[i].0}")
  }

  // Anti-Silent-Snap assertions at 60fps: must animate through >= 4 intermediate frames with max step < 10pt,
  // and file chip must stay in lockstep with pill (no trailing -2pt snap).
  if !@ui.test_at_a_rate() {
    let mut mid_frames = 0
    let mut max_step = 0.0
    for i in 1..<msg_ys.length() {
      let step = (msg_ys[i].1 - msg_ys[i - 1].1).abs()
      if step > max_step {
        max_step = step
      }
      if msg_ys[i].1 < msg_start - 1.0 && msg_ys[i].1 > msg_end + 1.0 {
        mid_frames = mid_frames + 1
      }
    }
    assert_true(
      mid_frames >= 4,
      msg="\{name}: silent snap detected on composer newline with attachments: only \{mid_frames} intermediate frames (max_step=\{max_step}, \{msg_start} -> \{msg_end})",
    )
    assert_true(
      max_step < 10.0,
      msg="\{name}: single-frame jump on composer newline with attachments: max_step=\{max_step} (\{msg_start} -> \{msg_end})",
    )
    let mut max_gap_drift = 0.0
    let base_gap = file_start - pill_start
    let n = if file_ys.length() < pill_ys.length() { file_ys.length() } else { pill_ys.length() }
    for i in 0..<n {
      let drift = (file_ys[i].1 - pill_ys[i].1 - base_gap).abs()
      if drift > max_gap_drift {
        max_gap_drift = drift
      }
    }
    assert_true(
      max_gap_drift < 1.5,
      msg="\{name}: attachment chip drifted from Willow pill by \{max_gap_drift}pt during newline animation",
    )
  }
}

///|
test "chat_page_nodes smoothness: 4-attachment 2->1 row reflow has zero Y dip and 2-quote + 2-row attach Shift+Enter animates in lockstep" {
  let screen = dk_screens[0]
  let (name, w, h, platform) = screen
  // Part 1: 2-row attachments -> delete row-1 items to trigger 2->1 row shrink + cross-row reflow with zero Y dip.
  new_run()
  let src1 = fixture_app("chat")
  let t1 = @ui.Tester::new(fn(c) { view(c, src1) }, tree=app_tree(src1), w~, h~, platform~, words_over_held=true)
  t1.set_rows_on_pixels(true)
  if !@ui.test_at_a_rate() {
    t1.set_frame_period(1000.0 / 60.0)
  }
  let reflow_log_ys : Array[(Double, Double)] = []
  let pre_log1_y = Ref(-1.0)
  let pre_row2_y = Ref(-1.0)
  let saw_reflow = Ref(false)
  let script1 =
    #|timeout 25000
    #|until 发消息
    #|wait 300
    #|tap 发消息
    #|wait 200
    #|picks 构建日志1.log:2000
    #|key cmd+u
    #|wait 250
    #|picks 截图1.png:8x8
    #|key cmd+u
    #|wait 250
    #|picks 截图2.png:8x8
    #|key cmd+u
    #|wait 250
    #|picks 截图3.png:8x8
    #|key cmd+u
    #|wait 250
    #|picks 截图4.png:8x8
    #|key cmd+u
    #|wait 250
    #|picks 截图5.png:8x8
    #|key cmd+u
    #|wait 250
    #|picks 截图6.png:8x8
    #|key cmd+u
    #|wait 250
    #|picks 截图7.png:8x8
    #|key cmd+u
    #|wait 250
    #|picks 截图8.png:8x8
    #|key cmd+u
    #|wait 250
    #|picks 截图9.png:8x8
    #|key cmd+u
    #|wait 250
    #|picks 构建日志4.log:2000
    #|key cmd+u
    #|wait 450
    #|tap 移除 构建日志1.log
    #|wait 500
    #|exit
  t1.drive(script1, each=fn(t) {
    let mut has_log1 = false
    let mut has_log4 = false
    let mut log1_y : Double? = None
    let mut log4_y : Double? = None
    for wd in t.words() {
      let (txt, _, y, _, _, a) = wd
      if a <= 0.02 {
        continue
      }
      if txt.contains("构建日志1") {
        has_log1 = true
        if log1_y is None {
          log1_y = Some(y)
        }
      }
      if txt.contains("构建日志4") {
        has_log4 = true
        if log4_y is None {
          log4_y = Some(y)
        }
      }
    }
    if has_log1 && has_log4 && !saw_reflow.val {
      match (log1_y, log4_y) {
        (Some(y1), Some(y4)) => {
          pre_log1_y.val = y1
          pre_row2_y.val = y4
        }
        _ => ()
      }
    }
    if pre_row2_y.val > pre_log1_y.val + 30.0 {
      if has_log4 && !has_log1 {
        saw_reflow.val = true
      }
      if saw_reflow.val {
        match log4_y {
          Some(y) => reflow_log_ys.push((t.time(), y))
          None => ()
        }
      }
    }
  })
  |> ignore
  assert_true(
    pre_row2_y.val > pre_log1_y.val + 30.0,
    msg="\{name}: expected 构建日志4 on row 2 before deleting 构建日志1 (log1=\{pre_log1_y.val}, log4=\{pre_row2_y.val})",
  )
  assert_true(reflow_log_ys.length() >= 4, msg="\{name}: too few reflow samples (\{reflow_log_ys.length()})")
  let reflow_y0 = pre_row2_y.val
  let mut max_dip = 0.0
  for s in reflow_log_ys {
    let dip = s.1 - reflow_y0
    if dip > max_dip {
      max_dip = dip
    }
  }
  assert_true(
    max_dip < 1.5,
    msg="\{name}: row-2 attachment dipped downward by \{max_dip}pt during 2->1 row reflow (start y=\{reflow_y0})",
  )

  // Part 2: 2-row attachments + 2 quotes -> Shift+Enter animates msg, pill, quotes, and attachments in lockstep.
  new_run()
  let src2 = fixture_app("chat")
  let t2 = @ui.Tester::new(fn(c) { view(c, src2) }, tree=app_tree(src2), w~, h~, platform~, words_over_held=true)
  t2.set_rows_on_pixels(true)
  if !@ui.test_at_a_rate() {
    t2.set_frame_period(1000.0 / 60.0)
  }
  let nl_msg_ys : Array[(Double, Double)] = []
  let nl_pill_ys : Array[(Double, Double)] = []
  let nl_q1_ys : Array[(Double, Double)] = []
  let nl_log1_ys : Array[(Double, Double)] = []
  let in_newline = Ref(false)
  let saw_second_line = Ref(false)
  let script2 =
    #|timeout 25000
    #|until 发消息
    #|wait 300
    #|dragon 120 0 120 做完了：列表
    #|wait 200
    #|tap 引用
    #|wait 450
    #|dragon 120 0 120 推送截图前要先登录
    #|wait 200
    #|tap 引用
    #|wait 450
    #|tap 发消息
    #|wait 200
    #|picks 截图1.png:24x18
    #|key cmd+u
    #|wait 350
    #|picks 构建日志1.log:2000
    #|key cmd+u
    #|wait 350
    #|picks 构建日志2.log:2000
    #|key cmd+u
    #|wait 350
    #|picks 构建日志3.log:2000
    #|key cmd+u
    #|wait 350
    #|picks 构建日志4.log:2000
    #|key cmd+u
    #|wait 450
    #|tap 发消息
    #|wait 150
    #|type 第一行双引用两行附件
    #|wait 100
    #|key shift+enter
    #|type 第二行锁步测试
    #|wait 450
    #|exit
  t2.drive(script2, each=fn(t) {
    let mut has_nl1 = false
    let mut has_nl2 = false
    for r in t.text_runs() {
      if r.text.contains("第一行双引用两行附件") {
        has_nl1 = true
      }
      if r.text.contains("第二行锁步测试") {
        has_nl2 = true
      }
    }
    if has_nl1 {
      in_newline.val = true
    }
    if has_nl2 {
      saw_second_line.val = true
    }
    if in_newline.val {
      let mut msg_y : Double? = None
      let mut pill_y : Double? = None
      let mut q1_y : Double? = None
      let mut log1_y : Double? = None
      for wd in t.words() {
        let (txt, _, y, ww, _, a) = wd
        if a <= 0.02 {
          continue
        }
        if msg_y is None && txt.contains("做完了：列表") && ww > 500.0 {
          msg_y = Some(y)
        }
        if pill_y is None && txt == "Willow" && y > 300.0 {
          pill_y = Some(y)
        }
        if q1_y is None && txt.contains("Claude：：列表") {
          q1_y = Some(y)
        }
        if log1_y is None && txt.contains("构建日志1") {
          log1_y = Some(y)
        }
      }
      match msg_y {
        Some(y) => nl_msg_ys.push((t.time(), y))
        None => ()
      }
      match pill_y {
        Some(y) => nl_pill_ys.push((t.time(), y))
        None => ()
      }
      match q1_y {
        Some(y) => nl_q1_ys.push((t.time(), y))
        None => ()
      }
      match log1_y {
        Some(y) => nl_log1_ys.push((t.time(), y))
        None => ()
      }
    }
  })
  |> ignore
  assert_true(saw_second_line.val, msg="\{name}: failed to type second line with 2 quotes + 2-row attach")
  assert_true(
    nl_msg_ys.length() >= 4 && nl_pill_ys.length() >= 4 && nl_q1_ys.length() >= 4 && nl_log1_ys.length() >= 4,
    msg="\{name}: insufficient newline lockstep samples (\{nl_msg_ys.length()}, \{nl_pill_ys.length()}, \{nl_q1_ys.length()}, \{nl_log1_ys.length()})",
  )
  if !@ui.test_at_a_rate() {
    let msg_start = nl_msg_ys[0].1
    let msg_end = nl_msg_ys[nl_msg_ys.length() - 1].1
    let mut mid_frames = 0
    let mut max_step = 0.0
    for i in 1..<nl_msg_ys.length() {
      let step = (nl_msg_ys[i].1 - nl_msg_ys[i - 1].1).abs()
      if step > max_step {
        max_step = step
      }
      if nl_msg_ys[i].1 < msg_start - 1.0 && nl_msg_ys[i].1 > msg_end + 1.0 {
        mid_frames = mid_frames + 1
      }
    }
    assert_true(mid_frames >= 4 && max_step < 10.0, msg="\{name}: 2-quote+2-row newline snapped (mid=\{mid_frames}, max_step=\{max_step})")
    let base_q = nl_q1_ys[0].1 - nl_pill_ys[0].1
    let base_l = nl_log1_ys[0].1 - nl_pill_ys[0].1
    let n = [nl_pill_ys.length(), nl_q1_ys.length(), nl_log1_ys.length()].fold(init=nl_pill_ys.length(), fn(a, b) { if a < b { a } else { b } })
    for i in 0..<n {
      assert_true((nl_q1_ys[i].1 - nl_pill_ys[i].1 - base_q).abs() < 1.5, msg="\{name}: quote drifted from pill at sample \{i}")
      assert_true((nl_log1_ys[i].1 - nl_pill_ys[i].1 - base_l).abs() < 1.5, msg="\{name}: attach drifted from pill at sample \{i}")
    }
  }
}

///|
test "chat_page_nodes smoothness: adding first quote with 4 attachments present animates Willow smoothly from frame 0 without -10pt snap" {
  let (name, w, h, platform) = dk_screens[0]
  new_run()
  let src = fixture_app("chat")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, words_over_held=true)
  t.set_rows_on_pixels(true)
  if !@ui.test_at_a_rate() {
    t.set_frame_period(1000.0 / 60.0)
  }
  let script =
    #|timeout 25000
    #|until 发消息
    #|wait 300
    #|tap 发消息
    #|wait 200
    #|picks 构建日志1.log:2000
    #|key cmd+u
    #|wait 350
    #|picks 构建日志2.log:2000
    #|key cmd+u
    #|wait 350
    #|picks 构建日志3.log:2000
    #|key cmd+u
    #|wait 350
    #|picks 构建日志4.log:2000
    #|key cmd+u
    #|wait 450
    #|dragon 120 0 120 做完了：列表
    #|wait 200
    #|tap 引用
    #|wait 450
    #|exit
  let saw_quote_pill = Ref(false)
  let quoting = Ref(false)
  let base_willow = Ref(-1.0)
  let base_log1 = Ref(-1.0)
  let samples : Array[(Double, Double, Double)] = []
  t.drive(script, each=fn(t) {
    let mut has_log4 = false
    let mut has_quote_pill = false
    let mut willow_y : Double? = None
    let mut log1_y : Double? = None
    for wd in t.words() {
      let (txt, _, y, _, _, a) = wd
      if a <= 0.02 {
        continue
      }
      if txt.contains("构建日志4") {
        has_log4 = true
      }
      if txt == "引用" {
        has_quote_pill = true
      }
      if willow_y is None && txt == "Willow" && y > 300.0 {
        willow_y = Some(y)
      }
      if log1_y is None && txt.contains("构建日志1") {
        log1_y = Some(y)
      }
    }
    if has_log4 && has_quote_pill && !quoting.val {
      saw_quote_pill.val = true
      match (willow_y, log1_y) {
        (Some(wy), Some(ly)) => {
          base_willow.val = wy
          base_log1.val = ly
        }
        _ => ()
      }
    } else if saw_quote_pill.val && !has_quote_pill {
      quoting.val = true
    }
    if quoting.val {
      match (willow_y, log1_y) {
        (Some(wy), Some(ly)) => samples.push((t.time(), wy, ly))
        _ => ()
      }
    }
  })
  |> ignore
  assert_true(base_willow.val > 0.0 && base_log1.val > 0.0, msg="\{name}: failed to capture pre-quote baseline")
  assert_true(samples.length() >= 4, msg="\{name}: insufficient post-quote samples (\{samples.length()})")
  let end_willow = samples[samples.length() - 1].1
  let total_up = base_willow.val - end_willow
  assert_true(
    total_up >= 65.0 && total_up <= 75.0,
    msg="\{name}: expected Willow total upward shift in [65, 75], got \{total_up} (base=\{base_willow.val}, end=\{end_willow})",
  )
  for i, s in samples {
    assert_true(
      (s.2 - base_log1.val).abs() < 1.5,
      msg="\{name}: 构建日志1.log shifted at sample \{i} (t=\{s.0}): \{s.2} vs base \{base_log1.val}",
    )
  }
  if !@ui.test_at_a_rate() {
    let f0_delta = (samples[0].1 - base_willow.val).abs()
    assert_true(
      f0_delta < 0.5,
      msg="\{name}: Willow snapped on tap 引用 frame 0 by \{samples[0].1 - base_willow.val}pt (base=\{base_willow.val}, f0=\{samples[0].1})",
    )
    let mut mid_frames = 0
    let mut max_up_step = 0.0
    for i in 1..<samples.length() {
      let dy = samples[i].1 - samples[i - 1].1
      assert_true(
        dy <= 0.5,
        msg="\{name}: Willow reversed downward by \{dy}pt at sample \{i} (t=\{samples[i].0})",
      )
      if -dy > max_up_step {
        max_up_step = -dy
      }
      if samples[i].1 < base_willow.val - 1.0 && samples[i].1 > end_willow + 1.0 {
        mid_frames = mid_frames + 1
      }
    }
    assert_true(
      mid_frames >= 4 && max_up_step < 14.0,
      msg="\{name}: first quote expansion snapped (mid=\{mid_frames}, max_up_step=\{max_up_step})",
    )
  }
}
