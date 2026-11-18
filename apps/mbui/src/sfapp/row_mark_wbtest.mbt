// A chats list row's mark following what the core says of its chat (sfpages' chat_mark_node.mbt): a red dot (需要处理)
// come as its chat needs handling, gone as it no longer does; its way in a pop (chat_mark_pop_wbtest.mbt).

///|
test "a row's mark comes as the core says its chat needs handling (需要处理), and goes as it no longer does" {
  new_run()
  let tone = @signals.signal("")
  let changes = @signals.signal(0)
  let base = fixture("home")
  let first_id = Ref("")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let tp = base.topic(name, params).get().snapshot()
      guard name == "chats" && tp.value is Some(Object(v)) else { return tp }
      let days = items(tp.value, "days").copy()
      guard days.length() > 0 && days[0] is Object(d) else { return tp }
      let rows = items(Some(days[0]), "items").copy()
      guard rows.length() > 0 && rows[0] is Object(r) else { return tp }
      first_id.val = text(Some(rows[0]), "title")
      let r = r.copy()
      r["tone"] = Json::string(tone.get())
      r["state"] = Json::string("")
      r["unread"] = Json::boolean(false)
      rows[0] = Json::object(r)
      let d = d.copy()
      d["items"] = Json::array(rows)
      days[0] = Json::object(d)
      let o = v.copy()
      o["days"] = Json::array(days)
      { ..tp, value: Some(Json::object(o)), version: tp.version + changes.get() }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  let alerts = fn() { t.all(Image).filter(fn(s) { s.label == "需要处理" }).length() }
  let was = alerts()
  tone.set("alert")
  changes.set(1)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq(alerts(), was + 1, msg=first_id.val)
  tone.set("")
  changes.set(2)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq(alerts(), was)
}

///|
/// The pieces of lines drawn and seen now (a working mark's spokes are 8).
fn row_mark_lines_seen(t : @ui.Tester) -> Int {
  t.drawn_lines().filter(fn(l) { (l.5 & 0xFFL) > 0L }).length()
}

///|
test "a row's mark come while a page covers Home (工作中 as a chat opened over it works): nothing asked for it meanwhile, seen whole once Home is back" {
  for (over, said, back_ms) in [(@sfbase.Settings, "设置", 50.0), (@sfbase.Settings, "设置", 1000.0), (@sfbase.NewChat, "新对话", 50.0), (@sfbase.NewChat, "新对话", 1000.0)] {
    new_run()
    let tone = @signals.signal("")
    let changes = @signals.signal(0)
    let base = fixture("home")
    let src : Source = {
      ..base,
      topic_read: fn(name, params) {
        let tp = base.topic(name, params).get().snapshot()
        guard name == "chats" && tp.value is Some(Object(v)) else { return tp }
        let days = items(tp.value, "days").copy()
        guard days.length() > 0 && days[0] is Object(d) else { return tp }
        let rows = items(Some(days[0]), "items").copy()
        guard rows.length() > 0 && rows[0] is Object(r) else { return tp }
        let r = r.copy()
        r["tone"] = Json::string(tone.get())
        r["state"] = Json::string("")
        r["unread"] = Json::boolean(false)
        rows[0] = Json::object(r)
        let d = d.copy()
        d["items"] = Json::array(rows)
        days[0] = Json::object(d)
        let o = v.copy()
        o["days"] = Json::array(days)
        { ..tp, value: Some(Json::object(o)), version: tp.version + changes.get() }
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
    t.run_for(@ui.move_most_ms)
    assert_eq(row_mark_lines_seen(t), 0)
    @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.open_page(over) })
    t.run_for(kept_switch_over_ms)
    let rest_was = t.rest_why()
    tone.set("busy")
    changes.set(1)
    t.draw()
    // (under the page over it: its mark made at once, no way of it asking for frames)
    assert_eq(t.rest_why(), rest_was, msg="over \{said}")
    t.run_for(back_ms)
    @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.go_back() |> ignore })
    t.run_for(kept_switch_over_ms)
    assert_eq(row_mark_lines_seen(t), 8, msg="the spokes drawn, over \{said}, back after \{back_ms}")
  }
}
