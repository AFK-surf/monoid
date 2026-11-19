// The composer made as nodes (sfpages' composer_node: 实验性功能's 试用新对话页) on a chat's page made as nodes, over
// the fake core of composer_wbtest.mbt: what is typed told the core as it is typed, send taking it off the draft and
// sending it, the field one node all along, its box kept a moment after the focus goes, what is put into its draft
// from outside it taken at that moment.

///|
/// The composer's field made as nodes: drawn by a node made in sfpages' composer_node.mbt.
fn composed_field_made(t : @ui.Tester) -> Bool {
  t.sources_of("发消息").contains("sfpages/composer_node.mbt")
}

///|
test "made as nodes: words typed go with send, by the chat's thread, the field emptied; on a touch screen Enter is a new line" {
  let calls : Array[Made] = []
  let t = fake_core(calls, composed=true)
  assert_true(composed_field_made(t))
  t.tap_text("发消息")
  let (active, _, _, _) = t.ime()
  assert_true(active)
  t.type_text("第一行")
  t.enter()
  t.type_text("第二行")
  assert_eq(named(calls, "chat.send").length(), 0)
  let kept = named(calls, "composer.text")
  assert_eq(text(Some(kept[kept.length() - 1].params), "text"), "第一行\n第二行")
  tap_send(t)
  let sent = named(calls, "chat.send")
  assert_eq(sent.length(), 1)
  assert_eq(t.haptics(), [@ui.KeyboardTap])
  let p = Some(sent[0].params)
  assert_eq(text(p, "text"), "第一行\n第二行")
  assert_eq(text(p, "station"), "ws1/st1")
  assert_true(field(p, "thread") is Some(Number(7.0, ..)))
  let (_, after, _, _) = t.ime()
  assert_eq(after, "")
  let taken = named(calls, "composer.take")
  assert_eq(taken.length(), 1)
  assert_eq(text(Some(taken[0].params), "key"), "ws1/st1:s-c1")
  // (what was sent in its list at once, before the core has it)
  t.run_for(@ui.move_most_ms)
  assert_true(t.words().iter().any(fn(w) { w.0.contains("第二行") }))
  t.run_for(@sfpages.sending_shows_ms)
  t.assert_idle()
}

///|
test "made as nodes, keyboard and mouse: Enter sends what is written, ⇧Enter a new line" {
  let calls : Array[Made] = []
  let t = fake_core(calls, composed=true, platform=0)
  // (the cursor in it as the chat comes, with keyboard and mouse)
  let (active, _, _, _) = t.ime()
  assert_true(active)
  t.type_text("一")
  t.key(@ui.key_code_enter, mods=@ui.mod_shift_key)
  t.type_text("二")
  assert_eq(named(calls, "chat.send").length(), 0)
  t.enter()
  let sent = named(calls, "chat.send")
  assert_eq(sent.length(), 1)
  assert_eq(text(Some(sent[0].params), "text"), "一\n二")
}

///|
test "made as nodes: opened as its field takes the focus, the same field all along, let go a moment after it goes" {
  let calls : Array[Made] = []
  let t = fake_core(calls, composed=true, platform=0)
  // (the cursor in it as the chat comes: opened; let go of, a capsule a moment later)
  let open = t.query(Button, label=@sf.t("web-main.composer.send")).unwrap().rect
  t.ctx().blur()
  t.run_for(@sfpages.let_go_ms + @sfpages.composer_shape_ms)
  let (active, _, _, _) = t.ime()
  assert_false(active)
  let shut = t.query(Button, label=@sf.t("web-main.composer.send")).unwrap().rect
  // (send kept at the foot's right corner all the way: the box grows up from its foot)
  assert_true((open.1 - shut.1).abs() < 12.0, msg="send moved \{open.1} -> \{shut.1}")
  // pressed beside its field: the field's, opened again
  t.tap(shut.0 - 120.0, shut.1 + shut.3 / 2.0)
  t.run_for(@sfpages.composer_shape_ms)
  let (again, _, _, _) = t.ime()
  assert_true(again)
  t.type_text("还在")
  // (written in, it stays opened as the focus goes)
  t.ctx().blur()
  t.run_for(@sfpages.let_go_ms + @sfpages.composer_shape_ms)
  let still = t.query(Button, label=@sf.t("web-main.composer.send")).unwrap().rect
  assert_true((still.1 - open.1).abs() < 0.5, msg="send moved \{open.1} -> \{still.1}")
  assert_eq(t.audit(), [])
}

///|
test "made as nodes: words a visualization asks to send go into its draft at once, after what is written, the field focused" {
  let calls : Array[Made] = []
  let t = fake_core(calls, composed=true, platform=0)
  t.type_text("先写的")
  @sfbase.draft_give("ws1/st1:s-c1", Followed("追问"))
  t.draw()
  let (active, words, _, _) = t.ime()
  assert_true(active)
  assert_eq(words, "先写的\n追问")
  let kept = named(calls, "composer.text")
  assert_eq(text(Some(kept[kept.length() - 1].params), "text"), "先写的\n追问")
  assert_eq(@sfbase.draft_waiting("ws1/st1:s-c1").length(), 0)
}

///|
test "made as nodes, keyboard and mouse: 抄送, named with what it copies to, opens a menu of the chat's Slack and Feishu threads; each ticked or not asks the core (chat.cc), the menu kept open to tick the next" {
  new_run()
  @sfbase.chat_page_nodes.set(true)
  let asked : Array[Json] = []
  let base = fixture("chat-cc")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      if name == "chat.cc" {
        asked.push(params)
      }
      (base.call)(name, params, done)
    },
  }
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0, pointing=Mouse)
  t.run_for(@ui.move_most_ms)
  assert_true(composed_field_made(t))
  // (opened with the cursor in it as the chat comes, keyboard and mouse: 抄送 beside send, named with the one ticked)
  t.click(Button, label=@sf.t("web-main.composer.ccLabel") + " #still-fail")
  t.run_for(@ui.move_most_ms)
  t.click(MenuItemCheckbox, label="产品讨论")
  t.run_for(@ui.move_most_ms)
  // still open: the other one ticked off next
  t.click(MenuItemCheckbox, label="#still-fail")
  let said = asked.map(fn(p) { (field(Some(p), "to"), field(Some(p), "on"), text(Some(p), "station")) })
  assert_eq(said, [
    (Some(Json::number(22.0)), Some(Json::boolean(true)), "ws1/st1"),
    (Some(Json::number(21.0)), Some(Json::boolean(false)), "ws1/st1"),
  ])
}

///|
/// Where words holding `w` are drawn now, by their top (the window's tree's drawn list): none where not drawn.
fn cn_drawn_y(w : String) -> Double? {
  for d in @ui.view_tree().unwrap().drawn() {
    if d.bones == 0L && d.words.contains(w) {
      return Some(d.y)
    }
  }
  None
}

///|
/// Each frame's step of `ys` (where a message's words were drawn), and how far they went in all: a frame not drawing
/// them fails.
fn cn_steps(ys : Array[Double?]) -> (Double, Double) raise {
  let at : Array[Double] = []
  for y in ys {
    match y {
      Some(v) => at.push(v)
      None => fail("a message's words not drawn in a frame: \{Repr(ys)}")
    }
  }
  let mut most = 0.0
  for i in 1..<at.length() {
    most = @sf.dmax(most, (at[i] - at[i - 1]).abs())
  }
  (most, (at[at.length() - 1] - at[0]).abs())
}

///|
test "made as nodes, on a touch screen under what is said over it: opened and let go, the messages over it go up and back with it on its way, never at once" {
  // (judged frame to frame on the display's frames: the default run's alone)
  if @ui.test_at_a_rate() {
    return
  }
  new_run()
  @sfbase.chat_page_nodes.set(true)
  // (its prompt cache over and its station down: two lines said over it, the foot taller than its least)
  let src = fixture("chat-cold-offline")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  assert_true(composed_field_made(t))
  let words = "截图也换了"
  let ys : Array[Double?] = []
  t.each_frame(Some(fn() { ys.push(cn_drawn_y(words)) }))
  // opened from its capsule with nothing in it
  t.tap_text("发消息")
  t.run_shown(@sfpages.composer_shape_ms + @ui.move_most_ms)
  let (step, went) = cn_steps(ys)
  assert_true(went > 35.0, msg="went up \{went}")
  assert_true(step <= 8.0, msg="opened: a frame's step \{step}, of \{went}: \{Repr(ys)}")
  // let go of: back down to as it was, its way too
  ys.clear()
  t.ctx().blur()
  t.run_shown(@sfpages.let_go_ms + @sfpages.composer_shape_ms + @ui.move_most_ms)
  t.each_frame(None)
  let (back_step, back) = cn_steps(ys)
  assert_true(back > 35.0, msg="went down \{back}")
  assert_true(back_step <= 8.0, msg="let go: a frame's step \{back_step}, of \{back}: \{Repr(ys)}")
}

///|
test "made as nodes, keyboard and mouse: 抄送's menu has each thread's platform mark before its place, none of a check's column, a ticked one's check at its end alone, ticked at once" {
  new_run()
  @sfbase.chat_page_nodes.set(true)
  let src = fixture("chat-cc")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0, pointing=Mouse)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label=@sf.t("web-main.composer.ccLabel") + " #still-fail")
  t.run_for(@ui.move_most_ms)
  // what draws a picture in a menu's row (a mark, a check) before its words and after them
  let parts = fn(place : String) -> (Int, Int, Double) raise {
    let row = t.query(MenuItemCheckbox, label=place).unwrap().rect
    let drawn = @ui.view_tree().unwrap().drawn()
    let inside = fn(d : @view.Drawn) {
      d.x >= row.0 - 0.5 && d.x + d.w <= row.0 + row.2 + 0.5 && d.y >= row.1 - 0.5 && d.y + d.h <= row.1 + row.3 + 0.5
    }
    guard drawn.iter().find_first(fn(d) { d.words == place && inside(d) }) is Some(w) else {
      fail("\{place}'s words not drawn in its row")
    }
    let pictures = drawn.filter(fn(d) {
      inside(d) && d.words == "" && (d.shapes.length() > 0 || d.lines.length() > 0 || d.picture is Some(_) || d.image is Some(_))
    })
    let before = pictures.filter(fn(d) { d.x + d.w <= w.x + 0.5 })
    let after = pictures.filter(fn(d) { d.x >= w.x + w.w - 0.5 })
    (before.length(), after.length(), w.x)
  }
  let (ticked_before, ticked_after, ticked_x) = parts("#still-fail")
  let (other_before, other_after, other_x) = parts("产品讨论")
  // one picture before its words, its mark: no check there, nor a column kept for one
  assert_eq((ticked_before, other_before), (1, 1))
  assert_eq(ticked_x, other_x)
  // a ticked one's check at its end, only there
  assert_eq((ticked_after, other_after), (1, 0))
  // ticked: its check at its end at once, the menu still open, what it copies to said by 抄送
  t.click(MenuItemCheckbox, label="产品讨论")
  t.run_for(@ui.move_most_ms)
  let (_, now_after, _) = parts("产品讨论")
  assert_eq(now_after, 1)
  // (what it says before send, on 抄送's line: both now)
  let ws = t.words()
  guard ws.iter().find_first(fn(w) { w.0 == @sf.t("web-main.composer.ccLabel") }) is Some(cc) else {
    fail("抄送 not drawn")
  }
  assert_true(ws.iter().any(fn(w) { w.0 == "产品讨论" && (w.2 - cc.2).abs() < 1.0 && w.1 > cc.1 }), msg="said before send: \{Repr(ws)}")
}

///|
test "made as nodes, keyboard and mouse: right click on composer field and its I-beam area opens edit menu (Select All, Cut, Copy, Paste text & PNG); right click on +/Send does not; clicking beside Send keeps focus" {
  new_run()
  @sfbase.chat_page_nodes.set(true)
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0, pointing=Mouse)
  t.run_for(@ui.move_most_ms)
  assert_true(composed_field_made(t))
  t.type_text("第一行")
  t.frame()
  let field_at = fn() {
    let (x, y, _, h) = t.ime_rect()
    (x + 1.0, y + h / 2.0)
  }
  // 1. Right click on the text field opens edit menu with 全选 enabled
  let (fx, fy) = field_at()
  t.right_click(fx, fy)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("剪切") is Some(_) && t.find("复制") is Some(_) && t.find("粘贴") is Some(_) && t.find("全选") is Some(_))
  t.tap_text("全选")
  t.run_for(@ui.move_most_ms)
  // 2. Right click again: selection stays painted while menu is open; Cut copies and clears
  t.right_click(fx, fy)
  t.run_for(@ui.move_most_ms)
  let sel_color = (@sf.theme().p.accent & 0xFFFFFF00L) | 0x40L
  assert_true(t.drawn_rects().iter().any(fn(rc) { rc.4 == sel_color }), msg="selection highlight stays visible while context menu is open")
  t.tap_text("剪切")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.clipboard(), "第一行")
  assert_eq(@sfbase.writings.get(draft_key(r)).map(fn(d) { d.text.get() }), Some(""))
  // 3. Paste text from context menu on composer I-beam area (between + and Send, below text)
  let send = t.query(Button, label=@sf.t("web-main.composer.send")).unwrap().rect
  let pad_x = send.0 - 80.0
  let pad_y = send.1 + send.3 / 2.0
  t.clipboard_gives("ab")
  t.right_click(pad_x, pad_y)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("粘贴") is Some(_), msg="right click on composer area opened edit menu")
  t.tap_text("粘贴")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.writings.get(draft_key(r)).map(fn(d) { d.text.get() }), Some("ab"))
  // 4. Paste PNG image via context menu attaches image.png
  t.clipboard_gives_png(@pixels.png(2, 2, FixedArray::make(16, b'\xff')))
  t.right_click(pad_x, pad_y)
  t.run_for(@ui.move_most_ms)
  t.tap_text("粘贴")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.writings.get(draft_key(r)).map(fn(d) { d.files.get().map(fn(f) { text(Some(f), "name") }) }), Some(["image.png"]))
  // 5. Right click on Send button does NOT open composer's text edit menu
  t.right_click(send.0 + send.2 / 2.0, send.1 + send.3 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("全选") is None, msg="right click on Send button must not open composer edit menu")
  // 6. Left click on composer area beside Send keeps focus instead of blurring
  t.tap(pad_x, pad_y)
  t.run_for(@ui.move_most_ms)
  let (still_focused, _, _, _) = t.ime()
  assert_true(still_focused, msg="clicking composer area beside Send keeps focus")
}

///|
test "made as nodes, keyboard and mouse: right click on composer while a message menu is open switches cleanly to the composer's edit menu (menu_behind)" {
  new_run()
  @sfbase.chat_page_nodes.set(true)
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0, pointing=Mouse)
  t.run_for(@ui.move_most_ms)
  t.type_text("ab")
  t.frame()
  let (fx, fy, _, fh) = t.ime_rect()
  let (mx, my) = t.find("截图也换了").unwrap()
  t.right_click(mx, my)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("复制消息") is Some(_), msg="message menu opened first")
  t.right_click(fx + 1.0, fy + fh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("全选") is Some(_) && t.find("复制消息") is None, msg="switched to composer edit menu")
}

///|
test "made as nodes, offline chat: pasting a file or image into composer is refused with offline toast and adds no attachment" {
  new_run()
  @sfbase.chat_page_nodes.set(true)
  let src = fixture("chat-cold-offline")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0, pointing=Mouse)
  t.run_for(@ui.move_most_ms)
  t.clipboard_gives_png(@pixels.png(2, 2, FixedArray::make(16, b'\xff')))
  let (fx, fy, _, fh) = t.ime_rect()
  t.right_click(fx + 1.0, fy + fh / 2.0)
  t.run_for(@ui.move_most_ms)
  t.tap_text("粘贴")
  t.run_for(@ui.move_most_ms)
  assert_eq(@sfbase.writings.get(draft_key(r)).map(fn(d) { d.files.get().length() }), Some(0))
  assert_true(t.find(@sf.t("web-main.composer.filesOffline")) is Some(_), msg="offline paste toast shown")
}
