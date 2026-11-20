// The new chat page by the channel (the device's `beta` feature `chatPage`, the prefs' `features`; sfbase's
// chat_page_from_prefs): on the test channel a chat's page, a new chat's and their composer are made as nodes with no
// switch, on stable their old views; a test or a scene holding one way (sfbase's hold_chat_page_nodes) has a chat or a
// new chat open become that way at once, both ways.

///|
/// The fixture's chat s-c1, as tests open it.
let setting_chat : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
/// The fixture's chat s-c1's last message, the words a page of either kind shows at rest.
let setting_chat_last : String = "做完了：列表、跳到最新的按钮"

///|
/// The app on 小屏 over `src`, its window's tree and all.
fn setting_tester(src : Source) -> @ui.Tester {
  @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
}

///|
/// Whether the chat's page shown is the one made as nodes: its last message drawn by a node made in its messages'
/// nodes (sfpages' chat_page_node, chat_body_node) and no old view's list under it; the old page the other way round.
fn setting_page_nodes(t : @ui.Tester, at : String) -> Bool raise {
  let said = t.sources_of(setting_chat_last)
  let by_nodes = said.contains("sfpages/chat_page_node.mbt") || said.contains("sfpages/chat_body_node.mbt")
  let old_rows = t.old_list_row_boxes().iter().any(fn(rows) { !rows.is_empty() })
  assert_true(by_nodes != old_rows, msg="\{at}: the page's last message drawn by nodes \{by_nodes}, an old list's rows \{old_rows}")
  by_nodes
}

///|
/// The chat opened, shown at rest: whether its page is the one made as nodes; then back to where it was opened from.
fn setting_chat_opened(t : @ui.Tester, at : String) -> Bool raise {
  open_chat(setting_chat)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is Chat(_), msg="\{at}: the chat not opened")
  let nodes = setting_page_nodes(t, at)
  app.nav.pop() |> ignore
  t.run_for(@ui.move_most_ms)
  nodes
}

///|
/// Whether the new chat shown is the one made as nodes (sfpages' new_chat_node): its heading drawn by a node made
/// there; the old view's (new_chat.mbt, none of the window's tree's) the other way round.
fn setting_new_nodes(t : @ui.Tester, at : String) -> Bool raise {
  let heading = @sf.t("android-chat.new.heading")
  assert_true(t.find(heading) is Some(_), msg="\{at}: its heading not drawn")
  t.sources_of(heading).contains("sfpages/new_chat_node.mbt")
}

///|
/// The app on 小屏 over `src`, a new chat opened, shown at rest: whether it is the one made as nodes; then back.
fn setting_new_opened(t : @ui.Tester, at : String) -> Bool raise {
  app.nav.rise(NewChat)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat, msg="\{at}: the new chat not opened")
  let nodes = setting_new_nodes(t, at)
  app.nav.pop() |> ignore
  t.run_for(@ui.move_most_ms)
  nodes
}

///|
test "the test channel's app: a chat opened is the page made as nodes, a new chat too, with no 实验性功能 switch of it" {
  new_run()
  assert_false(@sfbase.chat_page_nodes.get(), msg="a run begins on the old page, till the prefs say")
  let src = fixture("home")
  let t = setting_tester(src)
  t.run_for(@ui.move_most_ms)
  assert_true(field(field(src.topic("prefs", {}).get().value, "features"), "chatPage") is Some(True))
  assert_true(setting_chat_opened(t, "test channel"), msg="test channel: the page made as nodes")
  assert_true(setting_new_opened(t, "test channel"), msg="test channel: the new chat made as nodes")
}

///|
test "the stable app: a chat opened is the old page, a new chat the old one too" {
  new_run()
  let src = fixture("home-stable")
  let t = setting_tester(src)
  t.run_for(@ui.move_most_ms)
  assert_true(field(field(src.topic("prefs", {}).get().value, "features"), "chatPage") is Some(False))
  assert_false(setting_chat_opened(t, "stable"), msg="stable: the old page")
  assert_false(setting_new_opened(t, "stable"), msg="stable: the old new chat")
}

///|
test "the test channel's app started on a chat opens it on the page made as nodes; stable's on the old" {
  new_run()
  let src = fixture("chat")
  open_chat(setting_chat)
  let t = setting_tester(src)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is Chat(_), msg="started on the chat")
  assert_true(setting_page_nodes(t, "started"), msg="started: the page made as nodes")
  new_run()
  let src = fixture("chat-stable")
  open_chat(setting_chat)
  let t = setting_tester(src)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is Chat(_), msg="stable: started on the chat")
  assert_false(setting_page_nodes(t, "stable started"), msg="stable started: the old page")
}

///|
test "held one way while a chat is open: the page shown becomes it at once, both ways, the prefs told meanwhile not over it" {
  new_run()
  let src = fixture("chat")
  open_chat(setting_chat)
  let t = setting_tester(src)
  t.run_for(@ui.move_most_ms)
  assert_true(setting_page_nodes(t, "open"), msg="open: the page made as nodes")
  @sfbase.hold_chat_page_nodes(Some(false))
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is Chat(_), msg="still on the chat")
  assert_false(setting_page_nodes(t, "held old"), msg="held old: the old page at once")
  // (the prefs told again, as on any change of them: the hold stands)
  (src.call)("prefs.set", { "motion": "reduce" }, fn(_) {  })
  t.run_for(@ui.move_most_ms)
  assert_false(setting_page_nodes(t, "held old, prefs told"), msg="held old, prefs told: the old page still")
  @sfbase.hold_chat_page_nodes(Some(true))
  t.run_for(@ui.move_most_ms)
  assert_true(setting_page_nodes(t, "held nodes"), msg="held nodes: the page made as nodes again")
}

///|
test "held one way while a new chat is open: the new chat shown becomes it (its composer with it), at once, both ways" {
  new_run()
  let src = fixture("home")
  let t = setting_tester(src)
  t.run_for(@ui.move_most_ms)
  app.nav.rise(NewChat)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat, msg="the new chat not opened")
  assert_true(setting_new_nodes(t, "open"), msg="open: the new chat made as nodes")
  @sfbase.hold_chat_page_nodes(Some(false))
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is NewChat, msg="still on the new chat")
  assert_false(setting_new_nodes(t, "held old"), msg="held old: the old new chat")
  @sfbase.hold_chat_page_nodes(Some(true))
  t.run_for(@ui.move_most_ms)
  assert_true(setting_new_nodes(t, "held nodes"), msg="held nodes: the new chat made as nodes again")
}
