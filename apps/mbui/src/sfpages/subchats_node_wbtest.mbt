// subchats_list_node: which sub-chats the 已完成 group folds away, and what the list leads with: those at work (已完成
// and 已归档 folded under them), else the latest done or archived ones with the rest behind a press.

///|
fn subchat_of(session : String, mark? : String = "", lead? : String = "", archived? : Bool = false) -> @sfbase.OpenedChat {
  {
    chat: { station: "ws1/st1", session, title: "子会话 " + session, station_name: "" },
    mark,
    state_lead: lead,
    state_text: "",
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
