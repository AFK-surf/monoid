// The composer made as nodes (sfpages' composer_node: 实验性功能's 试用新输入框) on a chat's page made as nodes, over
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
