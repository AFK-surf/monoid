// A notification opens where the viewer is: beside a board with room, or in the chat page otherwise.

///|
fn notice_board_at(w : Double, h : Double, platform? : Int = 0) -> (@ui.Tester, Source) {
  new_run()
  let src = fixture("board")
  open_fixture_over("board", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  t.run_for(@ui.move_most_ms)
  (t, src)
}

///|
fn notice_board_tap(t : @ui.Tester, opens : String) -> Unit raise {
  @ui.notice_show(channel="消息", tag="board-notice", title="通知", body="打开通知", opens~)
  assert_true(t.tap_notice("打开通知"))
  t.draw()
  t.run_for(@ui.move_most_ms)
}

///|
test "大屏: a system notification on the board opens its chat beside it, at its message, and a card can close it" {
  for url in ["/o/ws1/st1/s-c1\n8", "/w/ws1/s/st1/chats/s-c1\n8"] {
    let (t, _) = notice_board_at(1440.0, 900.0)
    let before = @sfbase.go_tos_said.untracked()
    notice_board_tap(t, url)
    assert_true(app.nav.top() is Home, msg=url)
    guard @sfbase.board_pick.get() is Some(r) else { fail("no chat beside the board: \{url}") }
    assert_eq((r.station, r.session), ("ws1/st1", "s-c1"), msg=url)
    assert_true(@sfbase.go_tos_said.untracked() > before, msg="the notice's message is requested: \{url}")
    assert_true(t.query(Button, label="全屏打开") is Some(_), msg=url)
    // A second notification for the same chat does not toggle it closed.
    notice_board_tap(t, url)
    assert_true(@sfbase.board_pick.get() is Some(_), msg=url)
    // The URL has no row title, but the card still recognizes the selected chat.
    t.click(Button, label="整理发布清单")
    t.run_for(@ui.move_most_ms)
    assert_true(@sfbase.board_pick.get() is None, msg=url)
  }
}

///|
test "大屏: 待处理 opens the chosen chat beside the board, and replaces one already there" {
  let (t, _) = notice_board_at(1440.0, 900.0)
  t.click(Button, label="整理发布清单")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="待处理")
  t.run_for(@ui.move_most_ms)
  let rows = t.all(Button, label="夜里的构建又失败了")
  guard rows.length() > 0 else { fail("the notification row is not shown") }
  // The panel is beside the rail, before the board's own card of the same chat.
  let mut row = rows[0]
  for candidate in rows {
    if candidate.rect.0 < row.rect.0 { row = candidate }
  }
  let (x, y, w, h) = row.rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(app.nav.top() is Home)
  guard @sfbase.board_pick.get() is Some(r) else { fail("no chat beside the board") }
  assert_eq((r.station, r.session), ("ws1/st2", "s-c3"))
  assert_true(t.query(Button, label="全屏打开") is Some(_))
}

///|
test "a notification while a chat is in view opens a chat page, even with the board preference on" {
  let (t, src) = notice_board_at(1440.0, 900.0)
  @ui.view_tree().unwrap().event(t.time(), fn() {
    open_page(Chat({ station: "ws1/st1", session: "s-c11", title: "", station_name: "" }))
  })
  t.run_for(@ui.move_most_ms)
  // (a chat opened from the board on the wide frame shows the list again, open_where's: the preference turned on
  // again under the chat page, as the prefs can still say it)
  assert_true(!@sfbase.board_on_of(src, "ws1"))
  @sfbase.set_board_on(src, "ws1", true)
  t.run_for(@ui.move_most_ms)
  guard app.nav.top() is Chat(_) else { fail("the chat page is no longer in view") }
  notice_board_tap(t, "/o/ws1/st1/s-c1\n8")
  guard app.nav.top() is Chat(r) else { fail("the chat page was not opened") }
  assert_eq((r.station, r.session), ("ws1/st1", "s-c1"))
  assert_true(@sfbase.board_pick.get() is None)
}

///|
test "大屏: 待处理 from a chat opens another chat page while the board preference is on" {
  let (t, src) = notice_board_at(1440.0, 900.0)
  @ui.view_tree().unwrap().event(t.time(), fn() {
    open_page(Chat({ station: "ws1/st1", session: "s-c11", title: "", station_name: "" }))
  })
  t.run_for(@ui.move_most_ms)
  // (a chat opened from the board on the wide frame shows the list again, open_where's: the preference turned on
  // again under the chat page, as the prefs can still say it)
  assert_true(!@sfbase.board_on_of(src, "ws1"))
  @sfbase.set_board_on(src, "ws1", true)
  t.run_for(@ui.move_most_ms)
  guard app.nav.top() is Chat(_) else { fail("the chat page is no longer in view") }
  t.click(Button, label="待处理")
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="夜里的构建又失败了")
  t.run_for(@ui.move_most_ms)
  guard app.nav.top() is Chat(r) else { fail("the chat page was not opened") }
  assert_eq((r.station, r.session), ("ws1/st2", "s-c3"))
  assert_true(@sfbase.board_pick.get() is None)
}

///|
test "小屏 and 中屏: a notification from the board opens a page, with back to the board" {
  for (w, h) in [(390.0, 844.0), (760.0, 800.0)] {
    let (t, _) = notice_board_at(w, h, platform=2)
    notice_board_tap(t, "/o/ws1/st1/s-c1\n8")
    guard app.nav.top() is Chat(r) else { fail("\{w}: no chat page") }
    assert_eq((r.station, r.session), ("ws1/st1", "s-c1"))
    assert_true(@sfbase.board_pick.get() is None)
    assert_true(t.takes_back())
    t.back()
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.top() is Home)
  }
}

///|
test "a notification for another workspace or a service keeps the ordinary page-opening path" {
  for url in ["/o/ws2/st9/s-x\n1", "/o/ws1/st1/s-c1?service=j-web"] {
    let (t, _) = notice_board_at(1440.0, 900.0)
    notice_board_tap(t, url)
    assert_true(app.nav.top() is (Chat(_) | Service(_, _)), msg=url)
    assert_true(@sfbase.board_pick.get() is None, msg=url)
  }
}
