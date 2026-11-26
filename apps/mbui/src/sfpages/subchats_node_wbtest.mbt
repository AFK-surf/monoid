// subchats_list_node: which sub-chats the 已完成 group folds away, and what the list leads with: those at work (已完成
// and 已归档 folded under them), else the latest done or archived ones with the rest behind a press.

///|
fn subchat_of(
  session : String,
  mark? : String = "",
  lead? : String = "",
  state_text? : String = "",
  archived? : Bool = false,
) -> @sfbase.OpenedChat {
  {
    chat: { station: "ws1/st1", session, title: "子会话 " + session, station_name: "" },
    mark,
    state_lead: lead,
    state_text,
    archived,
    note: "",
    led: true,
  }
}

///|
fn done_label() -> String {
  @sf.t("web-pages.chat.subchatsDone")
}

///|
/// A window holding the list of `opened` in a column 360 wide; at rest.
fn subchats_tester(opened : @signals.Signal[Array[@sfbase.OpenedChat]]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=800.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(h) {
      h.width(Is(Some(360.0))) |> ignore
      subchats_list_node(h, fn() { opened.get() })
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "subchat_is_done: ended (done, idle, stopped) folds; at work, waiting on its work, asking or failed stays" {
  assert_true(subchat_is_done(subchat_of("a", lead="done")))
  assert_true(subchat_is_done(subchat_of("b")), msg="idle without a state")
  assert_false(subchat_is_done(subchat_of("c", mark="run")))
  assert_false(subchat_is_done(subchat_of("d", lead="wait")), msg="waiting on its own work")
  assert_false(subchat_is_done(subchat_of("e", lead="watch")))
  assert_false(subchat_is_done(subchat_of("f", lead="need")))
  assert_false(subchat_is_done(subchat_of("g", lead="decision")))
  assert_false(subchat_is_done(subchat_of("h", mark="block")))
  assert_false(subchat_is_done(subchat_of("i", mark="failed")))
  assert_false(subchat_is_done(subchat_of("j", lead="done", archived=true)), msg="archived has its own group")
}

///|
fn archived_label() -> String {
  @sf.t("web-pages.chat.subchatsArchived")
}

///|
/// What the audit finds of the list's layout (the words here are the catalog's keys, longer than any of its words: what
/// they cut is not the list's).
fn list_faults(t : @ui.Tester) -> Array[String] {
  t.audit().filter(fn(f) { !f.contains("cut short") })
}

///|
fn shown(t : @ui.Tester, session : String) -> Bool {
  t.query(Button, label="子会话 " + session) is Some(_)
}

///|
test "some at work: they lead, 已完成 and 已归档 folded under them till pressed, no 暂无进行中" {
  let opened : @signals.Signal[Array[@sfbase.OpenedChat]] = @signals.signal([])
  let t = subchats_tester(opened)
  assert_true(t.find(@sf.t("web-pages.chat.subchatsNone")) is Some(_))
  opened.set([subchat_of("r", mark="run"), subchat_of("d", lead="done"), subchat_of("i"), subchat_of("a", archived=true)])
  t.run_for(@ui.move_most_ms)
  assert_true(shown(t, "r"))
  assert_eq(t.query(Button, label=done_label()).unwrap().expanded, Some(false))
  assert_eq(t.query(Button, label=archived_label()).unwrap().expanded, Some(false))
  assert_true(!shown(t, "d") && !shown(t, "i") && !shown(t, "a"), msg="done, idle and archived folded")
  assert_true(t.find(@sf.t("web-pages.chat.subchatsIdle")) is None)
  t.click(Button, label=done_label())
  t.run_for(@ui.move_most_ms)
  assert_eq(t.query(Button, label=done_label()).unwrap().expanded, Some(true))
  assert_true(shown(t, "d") && shown(t, "i"))
  assert_true(!shown(t, "a"), msg="archived stays folded")
  t.click(Button, label=done_label())
  t.run_for(@ui.move_most_ms)
  assert_true(!shown(t, "d"))
  t.click(Button, label=archived_label())
  t.run_for(@ui.move_most_ms)
  assert_true(shown(t, "a"))
  assert_eq(list_faults(t), [])
}

///|
test "none at work, 3 done or fewer: all of them led with, no 已完成 head nor more to show, 暂无进行中 said, 已归档 folded" {
  let opened : @signals.Signal[Array[@sfbase.OpenedChat]] = @signals.signal([
    subchat_of("d", lead="done"),
    subchat_of("i"),
    subchat_of("e", lead="done"),
    subchat_of("a", archived=true),
  ])
  let t = subchats_tester(opened)
  assert_true(shown(t, "d") && shown(t, "i") && shown(t, "e"))
  assert_true(t.query(Button, label=done_label()) is None, msg="no 已完成 head over what it leads with")
  assert_true(t.query(Button, label=subchats_more_words(0, false)) is None)
  assert_true(t.find(@sf.t("web-pages.chat.subchatsIdle")) is Some(_))
  assert_eq(t.query(Button, label=archived_label()).unwrap().expanded, Some(false))
  assert_true(!shown(t, "a"))
  assert_eq(list_faults(t), [])
}

///|
test "none at work, more than 3 done: the latest 3, 展开其余 N 个 shows the rest in place, 收起其余 N 个 folds them back" {
  let opened : @signals.Signal[Array[@sfbase.OpenedChat]] = @signals.signal([
    subchat_of("d1", lead="done"),
    subchat_of("d2", lead="done"),
    subchat_of("d3", lead="done"),
    subchat_of("d4", lead="done"),
    subchat_of("d5", lead="done"),
  ])
  let t = subchats_tester(opened)
  assert_true(shown(t, "d1") && shown(t, "d2") && shown(t, "d3"))
  assert_true(!shown(t, "d4") && !shown(t, "d5"))
  guard t.query(Button, label=subchats_more_words(2, false)) is Some(more) else { fail("expected the press to show 2 more") }
  assert_eq(more.expanded, Some(false))
  t.click(Button, label=subchats_more_words(2, false))
  t.run_for(@ui.move_most_ms)
  assert_true(shown(t, "d4") && shown(t, "d5"))
  guard t.query(Button, label=subchats_more_words(2, true)) is Some(less) else { fail("expected the press to fold 2 back") }
  assert_eq(less.expanded, Some(true))
  assert_eq(list_faults(t), [])
  t.click(Button, label=subchats_more_words(2, true))
  t.run_for(@ui.move_most_ms)
  assert_true(!shown(t, "d4") && !shown(t, "d5"))
  assert_true(t.query(Button, label=subchats_more_words(2, false)) is Some(_))
}

///|
test "all archived, more than 3: the latest 3 led with, the rest shown and folded back in place" {
  let opened : @signals.Signal[Array[@sfbase.OpenedChat]] = @signals.signal([
    subchat_of("a1", archived=true),
    subchat_of("a2", archived=true),
    subchat_of("a3", archived=true),
    subchat_of("a4", archived=true),
  ])
  let t = subchats_tester(opened)
  assert_true(shown(t, "a1") && shown(t, "a3") && !shown(t, "a4"))
  assert_true(t.query(Button, label=archived_label()) is None, msg="no 已归档 head over what it leads with")
  t.click(Button, label=subchats_more_words(1, false))
  t.run_for(@ui.move_most_ms)
  assert_true(shown(t, "a4"))
  t.click(Button, label=subchats_more_words(1, true))
  t.run_for(@ui.move_most_ms)
  assert_true(!shown(t, "a4"))
}

///|
test "the last at work finishing: the list turns to the latest 3 done, not all of them" {
  let opened : @signals.Signal[Array[@sfbase.OpenedChat]] = @signals.signal([
    subchat_of("r", mark="run"),
    subchat_of("d1", lead="done"),
    subchat_of("d2", lead="done"),
    subchat_of("d3", lead="done"),
    subchat_of("d4", lead="done"),
  ])
  let t = subchats_tester(opened)
  assert_true(shown(t, "r") && !shown(t, "d1"))
  opened.set([
    subchat_of("r", lead="done"),
    subchat_of("d1", lead="done"),
    subchat_of("d2", lead="done"),
    subchat_of("d3", lead="done"),
    subchat_of("d4", lead="done"),
  ])
  t.run_for(@ui.move_most_ms)
  assert_true(shown(t, "r") && shown(t, "d1") && shown(t, "d2"))
  assert_true(!shown(t, "d3") && !shown(t, "d4"))
  assert_true(t.query(Button, label=subchats_more_words(2, false)) is Some(_))
  assert_true(t.query(Button, label=done_label()) is None)
  assert_true(t.find(@sf.t("web-pages.chat.subchatsIdle")) is Some(_))
}

///|
fn subchats_scroll_tester(opened : @signals.Signal[Array[@sfbase.OpenedChat]], cap? : Double = 320.0) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=800.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(h) {
      h.width(Is(Some(360.0))) |> ignore
      subchats_list_node(h, fn() { opened.get() }, scroll_most=fn() { cap })
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "pull-down search: tucked by default, revealed by pulling at top, filters done and archived, Escape clears" {
  let opened : @signals.Signal[Array[@sfbase.OpenedChat]] = @signals.signal([
    subchat_of("run-alpha", mark="run"),
    subchat_of("done-beta", lead="done"),
    subchat_of("arch-gamma", archived=true),
  ])
  let t = subchats_scroll_tester(opened)
  let ph = @sf.t("web-pages.chat.subchatsSearch")
  let row0 = t.query(Button, label="子会话 run-alpha").unwrap()
  let row0_y0 = row0.rect.1
  // Search bar is tucked above the scroll viewport top (`row0_y0`) on open and cannot be clicked through
  match t.find(ph) {
    Some((px0, py0)) => {
      assert_true(py0 < row0_y0, msg="search placeholder must be tucked above top on open: py0=\{py0} row0_y0=\{row0_y0}")
      t.tap(px0, py0)
      t.draw()
      assert_true(t.focused() is None, msg="tucked search input must not accept focus/clicks")
    }
    None => ()
  }
  assert_true(shown(t, "run-alpha"))
  assert_true(!shown(t, "done-beta") && !shown(t, "arch-gamma"))
  // Pull down at top reveals the search bar inside the scroll viewport
  let rx = row0.rect.0 + row0.rect.2 / 2.0
  let ry = row0.rect.1 + row0.rect.3 / 2.0
  t.wheel(rx, ry, -80.0)
  t.draw()
  guard t.find(ph) is Some((sx, sy)) else { fail("expected search box after pull down") }
  assert_true(sy >= row0_y0, msg="pulled search must appear inside viewport: sy=\{sy} row0_y0=\{row0_y0}")
  let row0_after = t.query(Button, label="子会话 run-alpha").unwrap()
  assert_true(row0_after.rect.1 > row0_y0 + 24.0, msg="first row must shift down when search is revealed")
  // Click search input and type to match archived item directly (unfolded)
  t.tap(sx, sy)
  t.draw()
  t.type_text("gamma")
  t.draw()
  assert_true(shown(t, "arch-gamma"), msg="archived sub-chat shown directly when filtering")
  assert_true(!shown(t, "run-alpha"))
  // Escape clears text and restores folded structure
  t.key(@ui.key_escape)
  t.draw()
  assert_true(shown(t, "run-alpha"))
  assert_true(!shown(t, "arch-gamma"))
  assert_eq(list_faults(t), [])
}

///|
fn subchats_tester_on(opened : @signals.Signal[Array[@sfbase.OpenedChat]], platform : Int) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=400.0, h=800.0, platform~)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    root.box(fn(h) {
      h.width(Is(Some(360.0))) |> ignore
      subchats_list_node(h, fn() { opened.get() })
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
fn word_rect(t : @ui.Tester, text : String) -> (Double, Double, Double, Double) raise {
  for w in t.words() {
    if w.0 == text {
      return (w.1, w.2, w.3, w.4)
    }
  }
  fail("expected drawn words: " + text)
}

///|
test "single-line subchat row follows desktop row_least (36) and centers vertically; two-line row stays symmetric and first-line aligned" {
  let opened : @signals.Signal[Array[@sfbase.OpenedChat]] = @signals.signal([
    subchat_of("single", mark="run"),
    subchat_of("two", mark="run", state_text="正在跑测试"),
  ])
  let t = subchats_tester_on(opened, 0)
  let r1 = t.query(Button, label="子会话 single").unwrap().rect
  let w1 = word_rect(t, "子会话 single")
  assert_true((r1.3 - 36.0).abs() < 0.5, msg="desktop single-line row height should be 36, got \{r1.3}")
  let top1 = w1.1 - r1.1
  let bot1 = r1.1 + r1.3 - (w1.1 + w1.3)
  assert_true((top1 - bot1).abs() <= 1.0, msg="desktop single-line row must center vertically: top=\{top1} bot=\{bot1}")
  let r2 = t.query(Button, label="子会话 two").unwrap().rect
  let w2_title = word_rect(t, "子会话 two")
  let w2_state = word_rect(t, "正在跑测试")
  let top2 = w2_title.1 - r2.1
  let bot2 = r2.1 + r2.3 - (w2_state.1 + w2_state.3)
  assert_true((top2 - bot2).abs() <= 1.0, msg="two-line row must have symmetric padding: top=\{top2} bot=\{bot2}")
  assert_eq(list_faults(t), [])
  // Dynamic state_text removal returns a two-line row to centered 36pt single-line geometry
  opened.set([subchat_of("two", mark="run")])
  t.run_for(@ui.move_most_ms)
  let r2_one = t.query(Button, label="子会话 two").unwrap().rect
  let w2_one = word_rect(t, "子会话 two")
  assert_true((r2_one.3 - 36.0).abs() < 0.5, msg="row after clearing state_text should shrink to 36, got \{r2_one.3}")
  let top_one = w2_one.1 - r2_one.1
  let bot_one = r2_one.1 + r2_one.3 - (w2_one.1 + w2_one.3)
  assert_true((top_one - bot_one).abs() <= 1.0, msg="row after clearing state_text must center vertically: top=\{top_one} bot=\{bot_one}")
  assert_eq(list_faults(t), [])
}

///|
test "single-line subchat row on touch keeps 44pt row_least and centers its single line vertically" {
  let opened : @signals.Signal[Array[@sfbase.OpenedChat]] = @signals.signal([
    subchat_of("single", mark="run"),
    subchat_of("two", mark="run", state_text="正在跑测试"),
  ])
  let t = subchats_tester_on(opened, 1)
  let r1 = t.query(Button, label="子会话 single").unwrap().rect
  let w1 = word_rect(t, "子会话 single")
  assert_true((r1.3 - 44.0).abs() < 0.5, msg="touch single-line row height should be 44, got \{r1.3}")
  let top1 = w1.1 - r1.1
  let bot1 = r1.1 + r1.3 - (w1.1 + w1.3)
  assert_true((top1 - bot1).abs() <= 1.0, msg="touch single-line row must center vertically: top=\{top1} bot=\{bot1}")
  let r2 = t.query(Button, label="子会话 two").unwrap().rect
  let w2_title = word_rect(t, "子会话 two")
  let w2_state = word_rect(t, "正在跑测试")
  let top2 = w2_title.1 - r2.1
  let bot2 = r2.1 + r2.3 - (w2_state.1 + w2_state.3)
  assert_true((top2 - bot2).abs() <= 1.0, msg="touch two-line row must have symmetric padding: top=\{top2} bot=\{bot2}")
  assert_eq(list_faults(t), [])
}
