// A right click on a field of the window's tree (the composer made as nodes, 试用新输入框; a new chat's): the same
// editing menu an old view's field opens (sfdesk's context_menu.mbt: 剪切, 复制, 粘贴, 全选 as they can be done).

///|
test "wide: a right click on the composer made as nodes opens 剪切, 复制, 粘贴, 全选, each done to its words" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="chat", before=fn(_) {
    @sfbase.chat_page_nodes.set(true)
    @sfbase.composer_nodes.set(true)
  })
  t.run_for(@ui.move_most_ms)
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "", station_name: "" }
  let (fx, fy) = match t.find("发消息") {
    Some(at) => at
    None => fail("no composer")
  }
  t.tap(fx, fy)
  t.type_text("发布前再看一眼")
  t.frame()
  let field_at = fn() {
    let (x, y, _, h) = t.ime_rect()
    (x + 1.0, y + h / 2.0)
  }
  let (fx, fy) = field_at()
  t.right_click(fx, fy)
  t.frame()
  assert_true(t.find("剪切") is Some(_) && t.find("粘贴") is Some(_) && t.find("全选") is Some(_), msg="no editing menu")
  t.tap_text("全选")
  t.frame()
  t.right_click(fx, fy)
  t.frame()
  t.tap_text("剪切")
  t.frame()
  assert_eq(t.clipboard(), "发布前再看一眼")
  assert_eq(@sfbase.writings.get(draft_key(r)).map(fn(d) { d.text.get() }), Some(""))
  t.clipboard_gives("再看一眼签名")
  let (fx, fy) = field_at()
  t.right_click(fx, fy)
  t.frame()
  t.tap_text("粘贴")
  t.frame()
  t.frame()
  assert_eq(@sfbase.writings.get(draft_key(r)).map(fn(d) { d.text.get() }), Some("再看一眼签名"))
  @sfbase.chat_page_nodes.set(false)
  @sfbase.composer_nodes.set(false)
}

///|
test "wide: a right click on a new chat's field made as nodes opens its editing menu" {
  let calls : Array[Made] = []
  let t = wide_tester(calls, mode="newchat", before=fn(_) { @sfbase.composer_nodes.set(true) })
  t.run_for(@ui.move_most_ms)
  guard t.find("做任何事") is Some((fx, fy)) else { fail("no new chat's composer") }
  t.tap(fx, fy)
  t.frame()
  t.clipboard_gives("修好右键")
  t.right_click(fx, fy)
  t.frame()
  assert_true(t.find("粘贴") is Some(_), msg="no editing menu")
  t.tap_text("粘贴")
  t.frame()
  t.frame()
  assert_eq(t.ime().1, "修好右键")
  @sfbase.composer_nodes.set(false)
}
