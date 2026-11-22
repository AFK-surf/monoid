// A chat an agent made (chat_create) and the chat whose agent made it: the way from either to the other, its row's mark
// and menu, the chat's info (…: beside the chat on Medium and Large, its sheet on Small); nothing else of either goes
// by the other.

///|
/// The chat the way back leads to: the one the fixture's chat-opener names (和 Ana 一起看新版的引导页).
fn opener_open(t : @ui.Tester) -> Unit raise {
  ignore(t)
  match app.nav.top() {
    Chat(r) => {
      assert_eq(r.session, "s-c6")
      assert_eq(r.station, "ws1/st1")
      assert_eq(r.title, "和 Ana 一起看新版的引导页")
    }
    _ => fail("no chat open")
  }
}

///|
test "wide: a row another chat's agent made is marked so, that chat named on the mark; its menu's 打开「…」 opens that chat" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-opener")
  t.draw()
  assert_true(t.query(Image, label="由「和 Ana 一起看新版的引导页」创建") is Some(_))
  let (x, y) = t.find("首页的列表改成按天分组").unwrap()
  t.right_click(x, y)
  assert_true(t.query(MenuItem, label="打开「和 Ana 一起看新版的引导页」") is None)
  t.key(@ui.key_escape)
  let (x, y) = t.find("夜里的构建又失败了").unwrap()
  t.right_click(x, y)
  t.click(MenuItem, label="打开「和 Ana 一起看新版的引导页」")
  opener_open(t)
}

///|
test "wide: a chat another chat's agent made has that chat in its info (…); pressed, that chat opens" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-opener")
  t.click(Button, label="对话信息")
  t.run_for(@ui.move_most_ms)
  // (its 发起: that chat, not a person)
  t.click(Link, label="由「和 Ana 一起看新版的引导页」创建")
  opener_open(t)
}

///|
test "wide: a chat whose agent made others has how many in its info (…), each where it stands in the menu that opens left of it as it is pointed at; one chosen opens" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-opened")
  t.click(Button, label="对话信息")
  t.run_for(@ui.move_most_ms)
  // (not each of them in it: one row)
  assert_true(t.query(MenuItem, label="旧版引导页的截图 · 已归档") is None)
  let (x, y, _, _) = t.rect_of("创建了 3 个对话").unwrap()
  let (px, _, _, _) = t.rect_of("发起").unwrap()
  t.move_to(x + 4.0, y + 4.0)
  t.run_for(@ui.move_most_ms)
  // left of the info's panel, not over it
  let (mx, _, mw, _) = t.rect_of("旧版引导页的截图 · 已归档").unwrap()
  ignore(mx)
  assert_true(mx + mw < px)
  t.click(MenuItem, label="夜里的构建又失败了")
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c3")
    _ => fail("no chat open")
  }
}

///|
test "a chat another chat's agent made has that chat in its own sheet (…); pressed, that chat opens" {
  let calls : Array[Made] = []
  let t = decide_core(calls, "chat-opener")
  t.click(Button, label="对话信息")
  t.run_for(@ui.move_most_ms)
  t.click(Link, label="由「和 Ana 一起看新版的引导页」创建")
  t.run_for(@ui.move_most_ms)
  opener_open(t)
}

///|
test "a chat whose agent made others has how many in its own sheet (…), each in the menu it opens; one chosen opens" {
  let calls : Array[Made] = []
  let t = decide_core(calls, "chat-opened")
  t.click(Button, label="对话信息")
  t.run_for(@ui.move_most_ms)
  t.tap_text("创建了 3 个对话")
  t.run_for(@ui.move_most_ms)
  // (a menu opened from the upper-half chat-info popover on Small: a dropdown menu, a MenuItem each)
  t.click(MenuItem, label="给设置页加一个深色模式开关")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c4")
    _ => fail("no chat open")
  }
}

///|
test "a chat whose agent made others: in its sheet (…) the card of 创建了 N 个对话 stands as far from the card under it as its agents' from it" {
  let calls : Array[Made] = []
  let t = decide_core(calls, "chat-opened")
  t.click(Button, label="对话信息")
  t.run_for(@ui.move_most_ms)
  // (the user's phone, 2026-11-02: its card and the pull requests' under it touching, 0 between them)
  // (its rows, a pull request's a link: it opens in the browser)
  let rows = t.semantics().filter(fn(s) { (s.role == @ui.Role::Button || s.role == @ui.Role::Link) && s.rect.2 > 200.0 })
  let labels = rows.map(fn(s) { s.label }).join(" / ")
  let mut i = -1
  for k, s in rows {
    if s.label.contains("创建了 3 个对话") {
      i = k
    }
  }
  assert_true(i > 0 && i + 1 < rows.length(), msg="a row over it and under it: \{labels}")
  let gap = fn(a : @ui.SemNode, b : @ui.SemNode) { b.rect.1 - (a.rect.1 + a.rect.3) }
  let over = gap(rows[i - 1], rows[i])
  let under = gap(rows[i], rows[i + 1])
  assert_true(over >= 10.0, msg="\{over} over it")
  assert_eq(under, over)
}

///|
test "wide: non-led chat-opener shows no top-bar breadcrumb, while led chat-lineage shows multi-level breadcrumb and navigates" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-opener")
  t.draw()
  // chat-opener is opened for a person (led == false): no breadcrumb link in the chat top bar
  let bar_crumb = t.semantics().filter(fn(s) { s.role == Link && s.label == "和 Ana 一起看新版的引导页" && s.rect.0 > 260.0 && s.rect.1 < 56.0 })
  assert_eq(bar_crumb.length(), 0)

  let calls2 : Array[Made] = []
  let t2 = wide_tester(calls2, mode="chat-lineage")
  t2.draw()
  assert_eq(t2.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [])
  // 3-level chain: root and direct parent visible, middle collapsed under 更多上级对话
  assert_true(t2.query(Link, label="根规划") is Some(_))
  assert_true(t2.query(Link, label="任务拆分") is Some(_))
  assert_true(t2.query(Button, label="更多上级对话") is Some(_))
  assert_true(t2.query(Link, label="接口重构") is None)
  t2.click(Button, label="更多上级对话")
  t2.run_for(@ui.move_most_ms)
  t2.click(MenuItem, label="接口重构")
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c5")
    _ => fail("expected middle ancestor chat open")
  }
  // History back returns to the child chat
  assert_true(@sfbase.go_back())
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c1")
    _ => fail("expected back to s-c1")
  }
  // Clicking root navigates directly
  t2.draw()
  t2.click(Link, label="根规划")
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c6")
    _ => fail("expected root ancestor chat open")
  }
}

///|
test "wide: sub-chats bar entry excludes non-led chats, opens popover, navigates, and pins to side panel" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat")
  t.draw()
  // Ordinary chat has no sub-chats bar button
  assert_true(t.query(Button, label="子会话") is None)

  let calls2 : Array[Made] = []
  let t2 = wide_tester(calls2, mode="chat-subchats-pop")
  t2.draw()
  guard t2.query(Button, label="子会话") is Some(sub_btn) else { fail("expected subchats button") }
  assert_true(sub_btn.rect.1 > 400.0, msg="wide subchats pill must sit above composer: \{Repr(sub_btn.rect)}")
  t2.click(Button, label="子会话")
  t2.run_for(@ui.move_most_ms)
  let dialogs = t2.all(Dialog)
  assert_true(dialogs.length() > 0, msg="expected subchats popover dialog")
  let d = dialogs[dialogs.length() - 1].rect
  assert_true(d.1 + d.3 <= sub_btn.rect.1 + 1.0, msg="wide subchats popover must open above composer pill: \{Repr(d)} vs \{Repr(sub_btn.rect)}")
  assert_eq(t2.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [])
  // 2 active led sub-chats shown, done and archived collapsed by default, non-led chat excluded!
  assert_true(t2.query(Button, label="安卓构建与冒烟测试") is Some(_))
  assert_true(t2.query(Button, label="夜里的构建又失败了") is Some(_))
  assert_true(t2.query(Button, label="给设置页加一个深色模式开关") is None)
  assert_true(t2.query(Button, label="旧版引导页的截图") is None)
  assert_true(t2.query(Button, label="给产品评审建的独立讨论") is None)
  assert_true(t2.find("1 进行中") is Some(_))
  assert_true(t2.find("1 待处理") is Some(_))
  // Expand done disclosure, verify done item and its summary text show, then collapse again
  guard t2.query(Button, label="已完成") is Some(done_btn) else { fail("expected done disclosure button") }
  assert_eq(done_btn.expanded, Some(false))
  t2.click(Button, label="已完成")
  t2.run_for(@ui.move_most_ms)
  assert_eq(t2.query(Button, label="已完成").unwrap().expanded, Some(true))
  assert_true(t2.query(Button, label="给设置页加一个深色模式开关") is Some(_))
  assert_true(t2.find("做完了：开关和三处颜色都改好了") is Some(_))
  t2.click(Button, label="已完成")
  t2.run_for(@ui.move_most_ms)
  assert_eq(t2.query(Button, label="已完成").unwrap().expanded, Some(false))
  assert_true(t2.query(Button, label="给设置页加一个深色模式开关") is None)
  // Expand archived disclosure, verify archived item shows without stale stateText, then collapse again
  guard t2.query(Button, label="已归档") is Some(arch_btn) else { fail("expected archived disclosure button") }
  assert_eq(arch_btn.expanded, Some(false))
  t2.click(Button, label="已归档")
  t2.run_for(@ui.move_most_ms)
  assert_eq(t2.query(Button, label="已归档").unwrap().expanded, Some(true))
  assert_true(t2.query(Button, label="旧版引导页的截图") is Some(_))
  assert_true(t2.find("归档前的残留提示") is None)
  t2.click(Button, label="已归档")
  t2.run_for(@ui.move_most_ms)
  assert_eq(t2.query(Button, label="已归档").unwrap().expanded, Some(false))
  assert_true(t2.query(Button, label="旧版引导页的截图") is None)
  // Open in side panel sends chat.tabs.open with tab: "subchats"
  t2.click(Button, label="在侧栏查看")
  t2.run_for(@ui.move_most_ms)
  assert_true(
    calls2.iter().any(fn(c) { c.name == "chat.tabs.open" && text(Some(c.params), "tab") == "subchats" }),
    msg="expected chat.tabs.open subchats",
  )

  // Clicking a sub-chat opens it
  let calls3 : Array[Made] = []
  let t3 = wide_tester(calls3, mode="chat-subchats-pop")
  t3.draw()
  t3.click(Button, label="子会话")
  t3.run_for(@ui.move_most_ms)
  t3.click(Button, label="安卓构建与冒烟测试")
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c2")
    _ => fail("expected sub-chat s-c2 open")
  }
}

///|
test "wide: side panel subchats tab renders led sub-chats and excludes non-led" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-subchats-panel")
  t.draw()
  assert_eq(t.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [])
  assert_true(t.query(Button, label="安卓构建与冒烟测试") is Some(_))
  assert_true(t.query(Button, label="给产品评审建的独立讨论") is None)
}

///|
test "small: chat-lineage breadcrumb navigates and chat-subchats-pop sheet excludes non-led" {
  let calls : Array[Made] = []
  let t = decide_core(calls, "chat-lineage")
  t.draw()
  assert_eq(t.audit(), [])
  assert_true(t.query(Link, label="根规划") is Some(_))
  assert_true(t.query(Link, label="任务拆分") is Some(_))
  guard t.query(Button, label="子会话") is Some(sub_sm) else { fail("expected small subchats pill") }
  assert_true(sub_sm.rect.1 > 400.0, msg="small subchats pill must sit above composer: \{Repr(sub_sm.rect)}")
  t.click(Link, label="任务拆分")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c4")
    _ => fail("expected parent chat s-c4 open")
  }

  let calls2 : Array[Made] = []
  let t2 = decide_core(calls2, "chat-subchats-pop")
  t2.run_for(@ui.move_most_ms)
  assert_eq(t2.audit(), [])
  assert_true(t2.query(Button, label="安卓构建与冒烟测试") is Some(_))
  assert_true(t2.query(Button, label="给产品评审建的独立讨论") is None)
}

///|
test "small: composer-top capsules give way inside the window" {
  let calls : Array[Made] = []
  let t = decide_core(calls, "chat-subchats-jobs")
  for w in [390.0, 320.0, 280.0] {
    t.resize(w, 844.0)
    t.run_for(@ui.move_most_ms)
    guard t.query(Button, label="子会话") is Some(sub) else { fail("expected subchats capsule at \{w}") }
    guard t.query(Button, label="服务") is Some(jobs) else { fail("expected services capsule at \{w}") }
    let strip = t.all(Button).filter(fn(b) { b.rect.1 == sub.rect.1 })
    assert_true(strip.length() >= 3, msg="expected agent, jobs and subchats capsules at \{w}: \{strip.length()}")
    // (the strip as wide as the composer under it, 2 in from its sides)
    let inset = @sfpages.composer_side() + 2.0
    for b in strip {
      assert_true(
        b.rect.0 >= inset - 0.5 && b.rect.0 + b.rect.2 <= w - inset + 0.5,
        msg="\{b.label} past the strip at \{w}: \{Repr(b.rect)}",
      )
    }
    assert_true(jobs.rect.0 + jobs.rect.2 <= sub.rect.0, msg="jobs and subchats overlap at \{w}")
    assert_eq(t.audit(), [])
  }
}

///|
test "small: subchats sheet aligns heading, shows header counts, collapses/expands archived without stale stateText, and navigates" {
  let calls : Array[Made] = []
  let t = decide_core(calls, "chat-subchats-pop")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [])
  // What it leads with on a card; under it 已完成 and 已归档, both folded, share one card of their own: as wide as the
  // first and as far in from the sheet's sides (16, concentric), no card's gap between the two heads, the card's foot
  // as far from the sheet's (16); their words where the rows' titles start
  guard t.query(Button, label="安卓构建与冒烟测试") is Some(active_row) else { fail("expected an active row") }
  guard t.query(Button, label="已完成") is Some(done_head) else { fail("expected 已完成") }
  guard t.query(Button, label="已归档") is Some(arch_head) else { fail("expected 已归档") }
  for h in [done_head, arch_head] {
    assert_true(
      (h.rect.0 - active_row.rect.0).abs() <= 0.5 && (h.rect.2 - active_row.rect.2).abs() <= 0.5,
      msg="\{h.label} on a card as wide as the rows': \{Repr(h.rect)} vs \{Repr(active_row.rect)}",
    )
  }
  let between = arch_head.rect.1 - (done_head.rect.1 + done_head.rect.3)
  assert_true(between >= 0.0 && between < 4.0, msg="the two folded heads on one card: \{between} between")
  guard t.all(Dialog).last() is Some(sheet) else { fail("expected the sheet") }
  let card_left = arch_head.rect.0 - @sf.corner_inset
  let card_right = arch_head.rect.0 + arch_head.rect.2 + @sf.corner_inset
  assert_true((card_left - sheet.rect.0 - 16.0).abs() <= 0.5, msg="card 16 in from the sheet: \{card_left} vs \{Repr(sheet.rect)}")
  assert_true(
    (sheet.rect.0 + sheet.rect.2 - card_right - (card_left - sheet.rect.0)).abs() <= 0.5,
    msg="card as far in on both sides: \{card_left}..\{card_right} vs \{Repr(sheet.rect)}",
  )
  let card_foot = arch_head.rect.1 + arch_head.rect.3 + @sf.corner_inset
  let sheet_foot = sheet.rect.1 + sheet.rect.3
  let screen_foot = if sheet_foot < 844.0 { sheet_foot } else { 844.0 }
  assert_true((screen_foot - card_foot - 16.0).abs() <= 0.5, msg="card's foot 16 over the sheet's: \{card_foot} vs \{screen_foot}")
  let (x_archived, _, _, _) = t.rect_of("已归档").unwrap()
  let (x_row_title, _, _, _) = t.rect_of("安卓构建与冒烟测试").unwrap()
  assert_true((x_archived - x_row_title).abs() <= 1.0, msg="archived head x=\{x_archived} must align with row titles x=\{x_row_title}")
  assert_true(t.find("暂无进行中") is None)
  assert_true(t.find("1 进行中") is Some(_), msg="expected running count in sheet head_end")
  assert_true(t.find("1 待处理") is Some(_), msg="expected need count in sheet head_end")
  assert_true(t.find("正在运行端到端用例") is Some(_), msg="active subchat stateText must show")
  // Archived group starts collapsed when active subchats exist
  guard t.query(Button, label="已归档") is Some(arch_btn) else { fail("expected archived disclosure button") }
  assert_eq(arch_btn.expanded, Some(false))
  assert_true(t.query(Button, label="旧版引导页的截图") is None, msg="archived subchat must start collapsed")
  // Expand archived group
  t.click(Button, label="已归档")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [])
  assert_eq(t.query(Button, label="已归档").unwrap().expanded, Some(true))
  assert_true(t.query(Button, label="旧版引导页的截图") is Some(_), msg="archived subchat must show after expand")
  assert_true(t.find("归档前的残留提示") is None, msg="archived subchat must hide stale stateText")
  // Collapse archived group again
  t.click(Button, label="已归档")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.query(Button, label="已归档").unwrap().expanded, Some(false))
  assert_true(t.query(Button, label="旧版引导页的截图") is None, msg="archived subchat must hide after collapse")
  t.click(Button, label="安卓构建与冒烟测试")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c2")
    _ => fail("expected sub-chat s-c2 open")
  }
}

///|
test "small: long subchats sheet collapses archived by default, expands and scrolls to bottom archived item" {
  let calls : Array[Made] = []
  let t = decide_core(calls, "chat-subchats-many")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [])
  assert_true(t.query(Button, label="安卓构建与冒烟测试") is Some(_))
  assert_true(t.query(Button, label="夜里的构建又失败了") is Some(_))
  assert_true(t.find("10") is Some(_), msg="expected archived count 10")
  assert_true(t.query(Button, label="旧版引导页的截图") is None, msg="archived items start collapsed")
  // Expand archived group
  t.click(Button, label="已归档")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [])
  assert_true(t.query(Button, label="旧版引导页的截图") is Some(_))
  assert_true(t.find("归档前的残留提示") is None, msg="archived subchats must hide stale stateText")
  assert_true(t.find("出错：额度已用完") is None, msg="archived subchats must hide stale error stateText")
  // Last archived item starts off-screen after expanding
  let initially_visible = match t.query(Button, label="历史日志导出脚本清理") {
    Some(n) => n.rect.1 + n.rect.3 <= 844.0
    None => false
  }
  assert_true(!initially_visible, msg="last archived subchat should start outside viewport")
  // Scroll up inside the sheet list to reach the bottom archived item
  for _ in [0, 1, 2, 3, 4] {
    t.drag(195.0, 700.0, 195.0, 420.0, steps=16)
    t.run_for(@ui.move_most_ms)
  }
  guard t.query(Button, label="历史日志导出脚本清理") is Some(last_btn) else {
    fail("expected last archived subchat visible after scrolling")
  }
  assert_true(last_btn.rect.1 + last_btn.rect.3 <= 844.0, msg="last archived subchat should be inside viewport: \{Repr(last_btn.rect)}")
  t.click(Button, label="历史日志导出脚本清理")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c4")
    _ => fail("expected last archived subchat s-c4 open")
  }
}

///|
test "small: subchats sheet passes audit at 1.3x font scale" {
  let phone = ("phone", 390.0, 844.0, 2, "")
  let t = screen_in("chat-subchats-pop", phone, "zh", font_scale=1.3)
  assert_eq(t.audit(), [])
  t.click(Button, label="已归档")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [])

  let t2 = screen_in("chat-subchats-many", phone, "zh", font_scale=1.3)
  assert_eq(t2.audit(), [])
  t2.click(Button, label="已归档")
  t2.run_for(@ui.move_most_ms)
  assert_eq(t2.audit(), [])
}

///|
fn assert_single_subchat_sheet(t : @ui.Tester, title : String, min_card_h : Double) -> Unit raise {
  assert_eq(t.audit(), [])
  guard t.query(Button, label=title) is Some(btn) else { fail("expected single subchat button: \{title}") }
  let bx = btn.rect.0 + btn.rect.2 / 2.0
  let by = btn.rect.1 + btn.rect.3 / 2.0
  guard t.drawn_glass().filter(fn(g) { g.2 > 300.0 && g.3 > 100.0 && bx >= g.0 && bx <= g.0 + g.2 && by >= g.1 && by <= g.1 + g.3 }).last()
    is Some(g) else {
    fail("expected floating sheet glass enclosing \{title}: \{Repr(t.drawn_glass())}")
  }
  let mut bottom_fade = 0.0
  for f in t.drawn_fades() {
    if f.1 >= g.1 && f.1 < g.1 + g.3 && f.6 > bottom_fade {
      bottom_fade = f.6
    }
  }
  assert_true(bottom_fade <= 1.0e-6, msg="expected zero bottom fade, got \{bottom_fade}")
  let cards = t
    .drawn_rects()
    .filter(fn(r) {
      r.0 > g.0 + 1.0 &&
      r.0 + r.2 < g.0 + g.2 - 1.0 &&
      r.1 > g.1 + 1.0 &&
      r.1 + r.3 < g.1 + g.3 - 1.0 &&
      r.2 > 200.0 &&
      bx >= r.0 &&
      bx <= r.0 + r.2 &&
      by >= r.1 &&
      by <= r.1 + r.3
    })
  guard cards.fold(init=None, fn(best : (Double, Double, Double, Double)?, r) {
    let rect = (r.0, r.1, r.2, r.3)
    match best {
      Some(b) if b.2 * b.3 >= rect.2 * rect.3 => Some(b)
      _ => Some(rect)
    }
  })
    is Some(card) else {
    fail("expected card rect inside sheet glass: \{Repr(cards)}")
  }
  assert_true(card.3 >= min_card_h - 0.5, msg="card height=\{card.3} < \{min_card_h}")
  let left_gap = card.0 - g.0
  let right_gap = g.0 + g.2 - (card.0 + card.2)
  let bottom_gap = g.1 + g.3 - (card.1 + card.3)
  assert_true((left_gap - 16.0).abs() <= 0.5, msg="left gap=\{left_gap} != 16")
  assert_true((right_gap - 16.0).abs() <= 0.5, msg="right gap=\{right_gap} != 16")
  assert_true((bottom_gap - 16.0).abs() <= 0.5, msg="bottom gap=\{bottom_gap} != 16")
}

///|
test "small: single subchat sheet fits card without bottom fade or truncation at 1.0x and 1.3x" {
  let title = "执行：模型面板搜索同行布局与分段控件交互"
  let phone = ("phone", 390.0, 844.0, 2, "")

  let calls1 : Array[Made] = []
  let t1 = decide_core(calls1, "chat-subchats-one")
  t1.run_for(@ui.move_most_ms)
  assert_single_subchat_sheet(t1, title, 60.0)

  let t2 = screen_in("chat-subchats-one", phone, "zh", font_scale=1.3)
  assert_single_subchat_sheet(t2, title, 60.0)

  let calls3 : Array[Made] = []
  let t3 = decide_core(calls3, "chat-subchats-one-note")
  t3.run_for(@ui.move_most_ms)
  assert_true(t3.find("正在运行端到端用例") is Some(_))
  assert_single_subchat_sheet(t3, title, 70.0)

  let t4 = screen_in("chat-subchats-one-note", phone, "zh", font_scale=1.3)
  assert_true(t4.find("正在运行端到端用例") is Some(_))
  assert_single_subchat_sheet(t4, title, 70.0)
}

///|
test "wide: tall subchats popover stands in the room above its pill, collapses done/archived by default, scrolls only once expanded past that room" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-subchats-tall")
  t.draw()
  guard t.query(Button, label="子会话") is Some(pill) else { fail("expected subchats pill") }
  t.click(Button, label="子会话")
  t.run_for(@ui.move_most_ms)
  let dialogs = t.all(Dialog)
  assert_true(dialogs.length() > 0, msg="expected subchats popover dialog")
  let d = dialogs[dialogs.length() - 1].rect
  assert_true(d.1 >= 0.0 && d.1 + d.3 <= pill.rect.1, msg="tall subchats popover must stand above its pill: \{Repr(d)}")
  // Folded, what it holds fits the room above the pill: nothing scrolls (the pinned head's line only shows scrolling).
  guard t.query(Button, label="已归档") is Some(arch_seen) else { fail("expected 已归档") }
  assert_true(arch_seen.rect.1 + arch_seen.rect.3 <= d.1 + d.3, msg="folded list must show whole: \{Repr(arch_seen.rect)} vs \{Repr(d)}")
  assert_eq(t.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [])
  // 7 active items visible; done (14) and archived (2) collapsed by default
  assert_true(t.query(Button, label="夜里的构建又失败了") is Some(_))
  assert_true(t.query(Button, label="离屏金属渲染对比视频生成") is Some(_))
  assert_true(t.query(Button, label="给设置页加一个深色模式开关") is None)
  assert_true(t.query(Button, label="旧版引导页的截图") is None)
  guard t.query(Button, label="已完成") is Some(done_btn) else { fail("expected done disclosure button") }
  assert_eq(done_btn.expanded, Some(false))
  guard t.query(Button, label="已归档") is Some(arch_btn) else { fail("expected archived disclosure button") }
  assert_eq(arch_btn.expanded, Some(false))
  // Scroll inside the capped popover so the collapsed 已完成 header is inside the viewport, then expand it
  let cx = d.0 + d.2 / 2.0
  let cy = d.1 + d.3 / 2.0
  for _ in [0, 1] {
    t.wheel(cx, cy, 160.0)
    t.run_for(@ui.move_most_ms)
  }
  t.click(Button, label="已完成")
  t.run_for(@ui.move_most_ms)
  let dialogs2 = t.all(Dialog)
  let d2 = dialogs2[dialogs2.length() - 1].rect
  assert_true(d2.1 >= 0.0 && d2.1 + d2.3 <= pill.rect.1, msg="expanded tall subchats popover must stay above its pill: \{Repr(d2)}")
  assert_eq(t.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [])
  assert_eq(t.query(Button, label="已完成").unwrap().expanded, Some(true))
  assert_true(t.query(Button, label="给设置页加一个深色模式开关") is Some(_))
  assert_true(t.find("已完成：开关和三处颜色都改好了") is Some(_))
  // Bare "已完成" appears only once (the section heading), never duplicated as a row secondary line
  let bare_done_words = t.words().filter(fn(w) { w.0 == "已完成" && w.5 > 0.5 })
  assert_eq(bare_done_words.length(), 1, msg="bare 已完成 must only appear as section heading: \{Repr(bare_done_words)}")
  // Scroll further inside the popover to reach the last done item; header and footer must stay pinned inside popover
  let cx2 = d2.0 + d2.2 / 2.0
  let cy2 = d2.1 + d2.3 / 2.0
  for _ in [0, 1, 2, 3, 4, 5, 6, 7] {
    t.wheel(cx2, cy2, 160.0)
    t.run_for(@ui.move_most_ms)
  }
  let head_words = t.words().filter(fn(w) {
    w.0 == "子会话" && w.5 > 0.5 && w.1 >= d2.0 && w.1 <= d2.0 + d2.2 && w.2 >= d2.1 && w.2 <= d2.1 + d2.3
  })
  assert_true(head_words.length() > 0, msg="header 子会话 must stay pinned inside popover after scrolling")
  guard t.query(Button, label="在侧栏查看") is Some(foot_btn) else {
    fail("footer 在侧栏查看 must stay pinned inside popover after scrolling")
  }
  assert_true(
    foot_btn.rect.1 >= d2.1 && foot_btn.rect.1 + foot_btn.rect.3 <= d2.1 + d2.3 + 1.0,
    msg="footer 在侧栏查看 must remain visible inside popover: \{Repr(foot_btn.rect)} vs \{Repr(d2)}",
  )
  guard t.query(Button, label="收尾回归与变更日志核对") is Some(last_btn) else {
    fail("expected last done subchat visible after scrolling")
  }
  assert_true(last_btn.rect.1 + last_btn.rect.3 <= foot_btn.rect.1 + 1.0, msg="last done subchat above pinned footer: \{Repr(last_btn.rect)} vs \{Repr(foot_btn.rect)}")
  t.click(Button, label="收尾回归与变更日志核对")
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c4")
    _ => fail("expected last done subchat s-c4 open")
  }
}

///|
test "small: tall sheet folds done and archived under those at work, done-only leads with its done ones, audit at 1.0x/1.3x, scroll to navigate" {
  // 1) tall sheet: active visible, done & archived collapsed by default; scroll to 已完成, expand, scroll to bottom, navigate
  let calls : Array[Made] = []
  let t = decide_core(calls, "chat-subchats-tall")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [])
  assert_true(t.query(Button, label="夜里的构建又失败了") is Some(_))
  assert_true(t.query(Button, label="给设置页加一个深色模式开关") is None)
  t.drag(195.0, 720.0, 195.0, 480.0, steps=16)
  t.run_for(@ui.move_most_ms)
  guard t.query(Button, label="已完成") is Some(done_btn) else { fail("expected done disclosure button") }
  assert_eq(done_btn.expanded, Some(false))
  t.click(Button, label="已完成")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit(), [])
  assert_eq(t.query(Button, label="已完成").unwrap().expanded, Some(true))
  for _ in [0, 1, 2, 3, 4, 5, 6, 7] {
    t.drag(195.0, 720.0, 195.0, 380.0, steps=16)
    t.run_for(@ui.move_most_ms)
  }
  guard t.query(Button, label="收尾回归与变更日志核对") is Some(last_btn) else {
    fail("expected last done subchat visible after scrolling small sheet")
  }
  assert_true(last_btn.rect.1 + last_btn.rect.3 <= 844.0, msg="last done subchat inside viewport: \{Repr(last_btn.rect)}")
  t.click(Button, label="收尾回归与变更日志核对")
  t.run_for(@ui.move_most_ms)
  match app.nav.top() {
    Chat(r) => assert_eq(r.session, "s-c4")
    _ => fail("expected last done subchat s-c4 open")
  }

  // 2) done-only sheet: none at work, so its 3 done ones lead, whole, with no 已完成 head and no more to show; 暂无进行中
  // said; 已归档 folded under them
  let calls2 : Array[Made] = []
  let t2 = decide_core(calls2, "chat-subchats-done-only")
  t2.run_for(@ui.move_most_ms)
  assert_eq(t2.audit(), [])
  assert_true(t2.query(Button, label="已完成") is None)
  assert_true(t2.find("暂无进行中") is Some(_))
  assert_true(t2.find("展开其余") is None)
  for title in ["给设置页加一个深色模式开关", "排查首页列表滚动掉帧", "补齐弹窗无障碍语义标签"] {
    assert_true(t2.query(Button, label=title) is Some(_), msg=title)
  }
  assert_eq(t2.query(Button, label="已归档").unwrap().expanded, Some(false))
  assert_true(t2.query(Button, label="旧版引导页的截图") is None)
  let bare_done = t2.words().filter(fn(w) { w.0 == "已完成" && w.5 > 0.5 })
  assert_eq(bare_done.length(), 0, msg="bare 已完成 must not show on done rows: \{Repr(bare_done)}")
  t2.click(Button, label="已归档")
  t2.run_for(@ui.move_most_ms)
  assert_eq(t2.audit(), [])
  assert_true(t2.query(Button, label="旧版引导页的截图") is Some(_))

  // 3) 1.3x font scale audit on both tall and done-only
  let phone = ("phone", 390.0, 844.0, 2, "")
  let t3 = screen_in("chat-subchats-tall", phone, "zh", font_scale=1.3)
  assert_eq(t3.audit(), [])
  for _ in [0, 1] {
    t3.drag(195.0, 720.0, 195.0, 440.0, steps=16)
    t3.run_for(@ui.move_most_ms)
  }
  t3.click(Button, label="已完成")
  t3.run_for(@ui.move_most_ms)
  assert_eq(t3.audit(), [])

  let t4 = screen_in("chat-subchats-done-only", phone, "zh", font_scale=1.3)
  assert_eq(t4.audit(), [])
}

///|
test "wide and small: sub-chats that stopped without a state fold into 已完成 with the done ones; one waiting on its work stays" {
  fn check(tt : @ui.Tester) -> Unit raise {
    assert_true(tt.query(Button, label="安卓构建与冒烟测试") is Some(_))
    assert_true(tt.query(Button, label="等 CI 跑完再合并分支") is Some(_), msg="waiting on its own work stays")
    assert_true(tt.query(Button, label="排查侧栏偶发白屏") is None, msg="idle folds")
    assert_true(tt.query(Button, label="给设置页加一个深色模式开关") is None, msg="done folds")
    guard tt.query(Button, label="已完成") is Some(head) else { fail("expected 已完成") }
    assert_eq(head.expanded, Some(false))
    tt.click(Button, label="已完成")
    tt.run_for(@ui.move_most_ms)
    // (the first of the group: the small sheet builds only the rows near its view)
    assert_true(tt.query(Button, label="排查侧栏偶发白屏") is Some(_), msg="idle shows once 已完成 opens")
  }
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-subchats-idle")
  t.draw()
  t.click(Button, label="子会话")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [])
  check(t)
  let calls2 : Array[Made] = []
  let t2 = decide_core(calls2, "chat-subchats-idle")
  t2.run_for(@ui.move_most_ms)
  assert_eq(t2.audit(), [])
  check(t2)
}

///|
test "wide: done-only subchats popover leads with its 3 done ones (no 已完成 head, 暂无进行中), 已归档 folded under them" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-subchats-done-only")
  t.draw()
  t.click(Button, label="子会话")
  t.run_for(@ui.move_most_ms)
  assert_true(t.all(Dialog).length() > 0, msg="expected subchats popover dialog")
  assert_eq(t.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [])
  assert_true(t.query(Button, label="已完成") is None)
  assert_true(t.find("暂无进行中") is Some(_))
  assert_true(t.find("展开其余") is None)
  for title in ["给设置页加一个深色模式开关", "排查首页列表滚动掉帧", "补齐弹窗无障碍语义标签"] {
    assert_true(t.query(Button, label=title) is Some(_), msg=title)
  }
  assert_true(t.find("已完成：开关和三处颜色都改好了") is Some(_))
  let bare_done = t.words().filter(fn(w) { w.0 == "已完成" && w.5 > 0.5 })
  assert_eq(bare_done.length(), 0, msg="bare 已完成 must not show on done rows: \{Repr(bare_done)}")
  assert_eq(t.query(Button, label="已归档").unwrap().expanded, Some(false))
  assert_true(t.query(Button, label="旧版引导页的截图") is None)
  t.click(Button, label="已归档")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="旧版引导页的截图") is Some(_))
  assert_eq(t.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [])
}

///|
/// chat-subchats-done-many's done ones, latest first (chat-subchats-tall's).
let done_many_first : Array[String] = ["给设置页加一个深色模式开关", "排查首页列表滚动掉帧", "补齐弹窗无障碍语义标签"]

///|
test "wide and small: 14 done and none at work lead with the latest 3, 展开其余 11 个 shows all in place and scrolls to the last, 收起其余 11 个 folds back" {
  let check = fn(t : @ui.Tester, at : String, scroll : (@ui.Tester) -> Unit) raise {
    let faults = fn() { t.audit().filter(fn(f) { !f.contains("edge_node.mbt") }) }
    assert_eq(faults(), [], msg=at)
    for title in done_many_first {
      assert_true(t.query(Button, label=title) is Some(_), msg="\{at}: \{title}")
    }
    assert_true(t.query(Button, label="收尾回归与变更日志核对") is None, msg="\{at}: the 14th folded")
    assert_true(t.query(Button, label="已完成") is None, msg=at)
    assert_true(t.find("暂无进行中") is Some(_), msg=at)
    guard t.query(Button, label="展开其余 11 个") is Some(more) else { fail("\{at}: expected 展开其余 11 个") }
    assert_eq(more.expanded, Some(false), msg=at)
    assert_eq(t.query(Button, label="已归档").unwrap().expanded, Some(false), msg=at)
    t.click(Button, label="展开其余 11 个")
    t.run_for(@ui.move_most_ms)
    assert_eq(faults(), [], msg="\{at} open")
    // (all 14 then, the press under the last: scrolled to)
    scroll(t)
    assert_true(t.query(Button, label="收尾回归与变更日志核对") is Some(_), msg="\{at}: the 14th shown once open")
    guard t.query(Button, label="收起其余 11 个") is Some(less) else { fail("\{at}: expected 收起其余 11 个 under the 14th") }
    assert_eq(less.expanded, Some(true), msg=at)
    assert_eq(faults(), [], msg="\{at} scrolled")
    t.click(Button, label="收起其余 11 个")
    t.run_for(@ui.move_most_ms)
    assert_true(t.query(Button, label="展开其余 11 个") is Some(_), msg="\{at}: folded back")
    assert_true(t.query(Button, label="收尾回归与变更日志核对") is None, msg="\{at}: the 14th folded back")
    // (folded back from under the last of them, the latest are seen again in what holds them, not scrolled away)
    t.run_for(@ui.move_most_ms)
    let d = t.all(Dialog).last().unwrap().rect
    let seen = t
      .words()
      .filter(fn(w) { w.5 > 0.5 && w.1 >= d.0 && w.1 <= d.0 + d.2 && w.2 >= d.1 && w.2 + w.4 <= d.1 + d.3 + 0.5 })
      .map(fn(w) { w.0 })
    for title in done_many_first {
      assert_true(seen.contains(title), msg="\{at}: \{title} seen once folded back: \{seen.join("|")}")
    }
    assert_true(seen.contains("展开其余 11 个"), msg="\{at}: the press seen once folded back")
  }
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-subchats-done-many")
  t.draw()
  t.click(Button, label="子会话")
  t.run_for(@ui.move_most_ms)
  check(t, "wide", fn(tt) {
    let d = tt.all(Dialog).last().unwrap().rect
    for _ in 0..<8 {
      tt.wheel(d.0 + d.2 / 2.0, d.1 + d.3 / 2.0, 160.0)
      tt.run_for(@ui.move_most_ms)
    }
  })
  let calls2 : Array[Made] = []
  let t2 = decide_core(calls2, "chat-subchats-done-many")
  t2.run_for(@ui.move_most_ms)
  check(t2, "small", fn(tt) {
    for _ in 0..<8 {
      tt.drag(195.0, 720.0, 195.0, 380.0, steps=16)
      tt.run_for(@ui.move_most_ms)
    }
  })
  let phone = ("phone", 390.0, 844.0, 2, "")
  let t3 = screen_in("chat-subchats-done-many", phone, "zh", font_scale=1.3)
  assert_eq(t3.audit(), [], msg="small 1.3x")
  assert_true(t3.find("展开其余 11 个") is Some(_), msg="small 1.3x")
}

///|
/// The composer-top buttons said `labels` (in order, left to right): segments of one liquid glass capsule, side by side
/// without overlapping, a hairline between each two of them and none else in it, and no 子会话 words drawn in it (the
/// sub-chats' mark and count only, said 子会话).
fn composer_right_capsule_check(t : @ui.Tester, at : String, labels : Array[String]) -> Unit raise {
  let rects = labels.map(fn(l) {
    match t.all(Button).filter(fn(b) { b.label == l && b.rect.1 > 400.0 && b.rect.3 < 90.0 }) {
      [b, ..] => b.rect
      _ => (-1.0, -1.0, 0.0, 0.0)
    }
  })
  for i, r in rects {
    assert_true(r.2 > 0.0, msg="\{at}: no \{labels[i]}")
  }
  let holding = fn(r : (Double, Double, Double, Double)) {
    t.drawn_glass().filter(fn(g) {
      g.4 == 6 && g.0 <= r.0 + 0.5 && g.1 <= r.1 + 0.5 && g.0 + g.2 >= r.0 + r.2 - 0.5 && g.1 + g.3 >= r.1 + r.3 - 0.5
    })
  }
  guard holding(rects[0]) is [cap, ..] else { fail("\{at}: \{labels[0]} in no glass") }
  for i, r in rects {
    guard holding(r) is [g, ..] else { fail("\{at}: \{labels[i]} in no glass") }
    assert_eq((g.0, g.1, g.2, g.3), (cap.0, cap.1, cap.2, cap.3), msg="\{at}: \{labels[i]} in a capsule of its own")
    if i > 0 {
      let p = rects[i - 1]
      assert_true(p.0 + p.2 <= r.0 + 0.01, msg="\{at}: \{labels[i - 1]} and \{labels[i]} overlap: \{Repr(p)} \{Repr(r)}")
    }
  }
  let lines = t
    .drawn_rects()
    .filter(fn(d) {
      d.2 <= 1.01 && d.3 >= 11.5 && d.3 <= 12.5 && d.0 >= cap.0 && d.0 + d.2 <= cap.0 + cap.2 && d.1 >= cap.1 && d.1 + d.3 <= cap.1 + cap.3
    })
  assert_eq(lines.length(), labels.length() - 1, msg="\{at}: hairlines in the capsule: \{Repr(lines)}")
  for i, l in lines {
    let (p, n) = (rects[i], rects[i + 1])
    assert_true(l.0 >= p.0 + p.2 - 0.01 && l.0 + l.2 <= n.0 + 0.01, msg="\{at}: hairline \{i} not between \{labels[i]} and \{labels[i + 1]}: \{Repr(l)}")
  }
  let said = t
    .words()
    .filter(fn(w) { w.0 == "子会话" && w.5 > 0.5 && w.1 >= cap.0 && w.1 <= cap.0 + cap.2 && w.2 >= cap.1 - 1.0 && w.2 <= cap.1 + cap.3 })
  assert_eq(said, [], msg="\{at}: 子会话 drawn in the capsule")
}

///|
test "wide and small: the composer-top services and sub-chats buttons are segments of one liquid glass capsule, the sub-chats' mark and count only" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat-subchats-jobs")
  t.draw()
  t.run_for(@ui.move_most_ms)
  composer_right_capsule_check(t, "wide", [@sf.t("web-main.jobs.services"), "子会话"])
  assert_eq(t.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [])
  assert_eq(t.room_faults(), [])
  let calls2 : Array[Made] = []
  let t2 = decide_core(calls2, "chat-subchats-jobs")
  for w in [390.0, 320.0] {
    t2.resize(w, 844.0)
    t2.run_for(@ui.move_most_ms)
    composer_right_capsule_check(t2, "small \{w}", ["服务", "子会话"])
    assert_eq(t2.audit(), [])
    assert_eq(t2.room_faults(), [])
  }
}

///|
/// The chat's screens: one an agent drives.
fn bar_screen_driven() -> (String, Topic) -> Topic {
  wide_bar_chat_field("screens", fn(_) {
    Json::array([
      Json::object({
        "id": Json::string("d1"),
        "kind": Json::string("display"),
        "title": Json::string("Display"),
        "agent": Json::boolean(true),
      }),
    ])
  })
}

///|
test "wide and small: services, a driven screen and sub-chats all shown: one capsule, exactly two hairlines between them" {
  let calls : Array[Made] = []
  let t = wide_bar_at(calls, over=wide_bar_both(wide_bar_both(wide_bar_jobs(""), bar_leads_one()), bar_screen_driven()))
  let screen = @sf.t("web-pages.chat.screen")
  composer_right_capsule_check(t, "wide", [@sf.t("web-main.jobs.services"), screen, "子会话"])
  assert_eq(t.audit().filter(fn(f) { f.contains("chat_bar_wide_node") }), [])
  let (t2, _) = chat_bar_node_tester("短标题", has_jobs=true, over=wide_bar_both(bar_leads_one(), bar_screen_driven()))
  composer_right_capsule_check(t2, "small", ["服务", screen, "子会话"])
  assert_eq(bar_node_audit(t2), [])
}

///|
test "small and wide: every sub-chats state passes audit at 1.0x and 1.3x, its folded groups folded and open" {
  let phone = ("phone", 390.0, 844.0, 2, "")
  for mode in ["chat-subchats-done-only", "chat-subchats-done-many", "chat-subchats-pop", "chat-subchats-many", "chat-subchats-tall", "chat-subchats-idle"] {
    let calls : Array[Made] = []
    let t = decide_core(calls, mode)
    t.run_for(@ui.move_most_ms)
    assert_eq(t.audit(), [], msg="\{mode} small 1.0x")
    let t2 = screen_in(mode, phone, "zh", font_scale=1.3)
    assert_eq(t2.audit(), [], msg="\{mode} small 1.3x")
    let calls3 : Array[Made] = []
    let t3 = wide_tester(calls3, mode~)
    t3.draw()
    t3.click(Button, label="子会话")
    t3.run_for(@ui.move_most_ms)
    assert_eq(t3.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [], msg="\{mode} wide")
    // (each group folded at first; 已完成, where there is one, opened then)
    for g in ["已完成", "已归档"] {
      if t3.query(Button, label=g) is Some(head) {
        assert_eq(head.expanded, Some(false), msg="\{mode} wide \{g}")
      }
    }
    if t3.query(Button, label="已完成") is Some(_) && mode != "chat-subchats-tall" {
      t3.click(Button, label="已完成")
      t3.run_for(@ui.move_most_ms)
      assert_eq(t3.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [], msg="\{mode} wide, 已完成 open")
    }
  }
}
