// subchats_list_node: which sub-chats the 已完成 group folds away, and that it folds by what the list holds now, not by
// what it held when it was made.

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
test "a list made before its sub-chats came folds 已完成 once one at work comes; pressed, it stays as pressed" {
  let opened : @signals.Signal[Array[@sfbase.OpenedChat]] = @signals.signal([])
  let t = subchats_tester(opened)
  assert_true(t.find(@sf.t("web-pages.chat.subchatsNone")) is Some(_))
  opened.set([subchat_of("r", mark="run"), subchat_of("d", lead="done"), subchat_of("i")])
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="子会话 r") is Some(_))
  guard t.query(Button, label=done_label()) is Some(head) else { fail("expected \{done_label()}") }
  assert_eq(head.expanded, Some(false))
  assert_true(t.query(Button, label="子会话 d") is None, msg="done folded")
  assert_true(t.query(Button, label="子会话 i") is None, msg="idle folded with done")
  // Nothing at work any more: the group opens, there being nothing above it.
  opened.set([subchat_of("r", lead="done"), subchat_of("d", lead="done"), subchat_of("i")])
  t.run_for(@ui.move_most_ms)
  assert_eq(t.query(Button, label=done_label()).unwrap().expanded, Some(true))
  assert_true(t.query(Button, label="子会话 i") is Some(_))
  // Pressed, it keeps the person's choice whatever comes after.
  t.click(Button, label=done_label())
  t.run_for(@ui.move_most_ms)
  assert_eq(t.query(Button, label=done_label()).unwrap().expanded, Some(false))
  opened.set([subchat_of("r", lead="done"), subchat_of("d", lead="done"), subchat_of("i"), subchat_of("n", lead="done")])
  t.run_for(@ui.move_most_ms)
  assert_eq(t.query(Button, label=done_label()).unwrap().expanded, Some(false))
  assert_true(t.query(Button, label="子会话 n") is None)
}
