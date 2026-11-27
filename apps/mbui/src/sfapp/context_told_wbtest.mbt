// A right click's menu in a chat on 大屏 (sfdesk's context_menu.mbt: a message's turn, a field's editing, the words picked)
// dismissed by the hand: Escape, a press on the page, at that input's moment; the frame after closing nothing more,
// a right click opening it again its own.

///|
/// 大屏, a mouse's, the chat open, scrolled till Ana's message shows: its words right clicked (its menu, 多选
/// and what else there is), dismissed by `how` (as the host hands it on, no frame after it): whether it is open then, once a
/// frame is drawn, as a right click opens it again and a frame after.
fn context_dismissed(how : (@ui.Tester, Double) -> Unit) -> Array[Bool] raise {
  let t = wide_tester([], mode="chat")
  for _ in 0..<12 {
    match t.run_rects("example.com/review/42") {
      [(_, y, _, _), ..] if y > 100.0 && y < 600.0 => break
      _ => t.wheel(900.0, 400.0, -200.0)
    }
  }
  let (x, y, w, h) = words_rect(t, "第二屏的插画")
  let open = fn() { @sfdesk.context.open }
  t.right_click(x + w / 2.0, y + h / 2.0)
  t.frame()
  let shown = t.find("多选") is Some(_)
  let seen = [open()]
  // (beside it: over the words it opened at, where nothing of it is, as the words lie)
  how(t, y - 40.0)
  seen.push(open())
  t.draw()
  seen.push(open())
  t.right_click(x + w / 2.0, y + h / 2.0)
  t.frame()
  seen.push(open())
  t.draw()
  seen.push(open())
  assert_true(shown, msg="its menu shown: \{Repr(seen)}")
  seen
}

///|
test "大屏: a right click's menu in a chat dismissed by Escape: closed as the key is taken; the frame after closes nothing more, opened again its own" {
  assert_eq(context_dismissed(fn(t, _) { t.key_told(@ui.key_escape, 0, t.time()) }), [true, false, false, true, true])
}

///|
test "大屏: a right click's menu in a chat dismissed by a press beside it: closed as it goes down; the frame after closes nothing more, opened again its own" {
  let down : Array[Bool] = []
  let seen = context_dismissed(fn(t, beside) {
    t.touch_at(0, 600.0, beside, t.time())
    down.push(@sfdesk.context.open)
    t.touch_at(2, 600.0, beside, t.time())
  })
  assert_eq((down, seen), ([false], [true, false, false, true, true]))
}

///|
test "大屏聊天页与右侧执行历史面板同开：从左栏消息拖入右栏不跨栏高亮也不在右栏飘出引用胶囊；左栏选中后右击右栏不提供复制左栏文字" {
  let t = wide_tester([], mode="chat-history-side")
  t.run_for(@ui.move_most_ms)
  for _ in 0..<12 {
    match t.run_rects("example.com/review/42") {
      [(_, y, _, _), ..] if y > 100.0 && y < 600.0 => break
      _ => t.wheel(500.0, 400.0, -200.0)
    }
  }
  t.run_for(@ui.move_most_ms)
  let (lx, ly, _lw, lh) = words_rect(t, "第二屏的插画")
  let words = t.words()
  let right_w = match words.iter().find_first(fn(w) {
    w.1 > 820.0 && w.2 > 120.0 && w.2 < 620.0 && w.0.length() >= 4 && !t.run_rects(w.0).is_empty()
  }) {
    Some(w) => Some(w)
    None => words.iter().find_first(fn(w) { w.1 > 820.0 && w.2 > 120.0 && w.2 < 620.0 && w.0.length() >= 4 })
  }
  guard right_w is Some((rtxt, rx, ry, rw, rh, _)) else { fail("no right history word found: \{Repr(words.map(fn(w) { (w.0, w.1, w.2) }))}") }
  // 1. Drag from left chat message into right execution history panel
  t.drag(lx + 2.0, ly + lh / 2.0, rx + rw / 2.0, ry + rh / 2.0)
  t.run_for(@ui.move_most_ms)
  let picked = t.ctx().selected_text()
  assert_true(picked != "", msg="expected selection in left chat starting from 第二屏的插画")
  assert_true(!picked.contains(rtxt), msg="selection leaked into right history panel (\{rtxt}): \{picked}")
  // No 引用 pill may appear over the right panel (x > 800)
  for w in t.words() {
    if w.0 == "引用" {
      assert_true(w.1 < 800.0, msg="引用 pill floated over right panel at x=\{w.1}")
    }
  }
  // 2. Right-click inside the right panel while left chat has selection: must NOT offer 复制 of left pane's words
  t.right_click(rx + rw / 2.0, ry + rh / 2.0)
  t.frame()
  assert_true(t.find("复制") is None, msg="right-clicking right panel offered 复制 for left chat selection: words=\{@sfdesk.context.words}")
  assert_eq(@sfdesk.context.words, "")
}

///|
test "大屏: 选中对话正文后右键出现「分享为图片」，点击打开分享图预览并支持复制与保存" {
  let t = wide_tester([], mode="chat")
  t.run_for(@ui.move_most_ms)
  for _ in 0..<12 {
    match t.run_rects("example.com/review/42") {
      [(_, y, _, _), ..] if y > 100.0 && y < 600.0 => break
      _ => t.wheel(900.0, 400.0, -200.0)
    }
  }
  t.run_for(@ui.move_most_ms)
  let (x, y, w, h) = words_rect(t, "第二屏的插画")
  // Drag across part of the message text, then right-click inside it.
  t.drag(x + 2.0, y + h / 2.0, x + w - 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  t.right_click(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("复制") is Some(_), msg="expected 复制 in selection context menu")
  assert_true(t.find("分享为图片") is Some(_), msg="expected 分享为图片 in selection context menu")
  t.tap_text("分享为图片")
  t.run_for(@ui.move_most_ms)
  // Share card stage opened with Copy image & Save image buttons and zero audit faults.
  assert_true(t.find("复制图片") is Some(_), msg="expected 复制图片 on excerpt share stage")
  assert_true(t.find("保存图片") is Some(_), msg="expected 保存图片 on excerpt share stage")
  assert_eq(t.audit(), [])
  // Copy image triggers a take_picture shot.
  let shots_before = t.shot_drawn().length()
  t.tap_text("复制图片")
  t.run_for(@ui.move_most_ms)
  assert_true(t.shot_drawn().length() > shots_before, msg="expected 复制图片 to render PNG shot")
  assert_true(t.find("已复制") is Some(_), msg="expected 已复制 state/toast after copying share image")
  // Close via Escape.
  t.key_told(@ui.key_escape, 0, t.time())
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("保存图片") is None, msg="expected Escape to dismiss excerpt share stage")
}

///|
test "超长选中文本分享图：支持单图节选与分页卡片切换、翻页且大屏与小屏 1.3x 均无审计缺陷" {
  let para = "陶哲轩指出，理想情况下科技公司应当在机器大规模产出自动证明之前就与数学界建立透明的协作规范。"
  let parts : Array[String] = []
  for _ in 0..<45 {
    parts.push(para)
  }
  let long_text = parts.join("\n\n")
  let t = wide_tester([], mode="chat")
  t.run_for(@ui.move_most_ms)
  @sfpages.open_excerpt_share_payload({
    before_context: "此前访谈提到实验室与学界的节奏差异。",
    before_join: Paragraph,
    selected_text: long_text,
    after_context: "随后进一步讨论了激励机制。",
    after_join: Paragraph,
    source_title: "整理陶哲轩访谈：AI 证明与数学界合作要点",
    date_label: "2026.11.27",
  })
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("单图节选") is Some(_), msg="expected 单图节选 tab for long selection")
  assert_true(t.find("分页卡片") is Some(_), msg="expected 分页卡片 tab for long selection")
  assert_eq(t.audit(), [])
  // Switch to paginated mode.
  t.tap_text("分页卡片")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("01 / ") is Some(_), msg="expected page indicator 01 / N")
  assert_true(t.find("保存全部") is Some(_), msg="expected 保存全部 primary button in paged mode")
  assert_eq(t.audit(), [])
  // Step to page 2 via keyboard Right Arrow.
  t.key_told(@ui.key_code_right, 0, t.time())
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("02 / ") is Some(_), msg="expected page indicator 02 / N after Right Arrow")
}

///|
test "小屏 390x844 与 1.3x 字号下分享图预览（常规与超长分页）中英文零审计缺陷" {
  let phone = ("phone", 390.0, 844.0, 1, "compact")
  for mode in ["chat-share-excerpt", "chat-share-excerpt-long"] {
    for lang in ["zh", "en"] {
      let t = screen_in(mode, phone, lang, font_scale=1.3)
      t.run_for(@ui.move_most_ms)
      let faults = t.audit()
      assert_eq(faults, [], msg="audit failed for \{mode} \{lang} at 390x844 1.3x: \{Repr(faults)}")
    }
  }
}
