// A chat shown short of its end, newer messages not brought in (the core's `newer`; sfpages' chat_list.mbt to_latest):
// the way to its end says how many new messages wait there, and pressed asks the core for the chat's latest page
// (chat.latest), not a glide over what is in the list.

///|
test "a chat short of its end: its way to the end says how many new messages wait (3 条新消息); pressed, the core is asked for its latest page" {
  let calls : Array[Made] = []
  let t = fake_core(calls, over=fn(name, tp) {
    guard name == "chat" && tp.value is Some(Object(m)) else { return tp }
    let o = m.copy()
    o["newer"] = Json::boolean(true)
    o["thread"] = { "id": 7, "unread": 3 }
    { ..tp, value: Some(Json::object(o)) }
  })
  t.run_for(@ui.move_most_ms)
  guard t.find("3 条新消息") is Some((x, y)) else { fail("\{Repr(t.words().map(fn(w) { w.0 }))}") }
  assert_eq(named(calls, "chat.latest").length(), 0)
  t.tap(x, y)
  t.draw()
  let made = named(calls, "chat.latest")
  assert_eq(made.length(), 1)
  assert_eq(text(Some(made[0].params), "station"), "ws1/st1")
  assert_eq(number(Some(made[0].params), "thread"), 7.0)
}

///|
test "a chat at its end with nothing newer: no count of new messages on the way to its end" {
  let calls : Array[Made] = []
  let t = fake_core(calls, over=fn(name, tp) {
    guard name == "chat" && tp.value is Some(Object(m)) else { return tp }
    let o = m.copy()
    o["thread"] = { "id": 7, "unread": 3 }
    { ..tp, value: Some(Json::object(o)) }
  })
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("3 条新消息") is None)
}

///|
test "at the end of a window short of the chat's end, the page after is asked for (chat.newer) once, not again each frame" {
  let calls : Array[Made] = []
  let t = fake_core(calls, over=fn(name, tp) {
    guard name == "chat" && tp.value is Some(Object(m)) else { return tp }
    let o = m.copy()
    o["newer"] = Json::boolean(true)
    { ..tp, value: Some(Json::object(o)) }
  })
  t.run_for(@ui.move_most_ms)
  t.run_for(@ui.move_most_ms)
  let made = named(calls, "chat.newer")
  assert_eq(made.length(), 1)
  assert_eq(number(Some(made[0].params), "thread"), 7.0)
  // its answer failed: asked again
  (made[0].done)(Err({ "message": "连不上" }))
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.newer").length(), 2)
}

///|
test "the page before asked for as the reader nears the chat's top (chat.older), once; its answer failed, asked again" {
  let calls : Array[Made] = []
  let t = fake_core(calls)
  t.run_for(@ui.move_most_ms)
  t.move_to(195.0, 400.0)
  for _ in 0..<6 {
    t.wheel(195.0, 400.0, -900.0)
    t.run_for(@ui.move_most_ms)
  }
  let asked = named(calls, "chat.older")
  assert_eq(asked.length(), 1)
  assert_eq(number(Some(asked[0].params), "thread"), 7.0)
  (asked[0].done)(Err({ "message": "连不上" }))
  t.wheel(195.0, 400.0, 300.0)
  t.run_for(@ui.move_most_ms)
  t.wheel(195.0, 400.0, -900.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.older").length(), 2)
}

///|
/// A chat short of its end (3 new messages waiting there) on its page made as nodes, its calls kept in `calls`; the
/// core's `doing` saying its latest page is under way while `coming` does. Opened, at rest.
fn latest_nodes_open(calls : Array[Made], coming : Ref[Bool]) -> @ui.Tester {
  let t = fake_core(calls, over=fn(name, tp) {
    match name {
      "chat" =>
        match tp.value {
          Some(Object(m)) => {
            let o = m.copy()
            o["newer"] = Json::boolean(true)
            o["thread"] = { "id": 7, "unread": 3 }
            { ..tp, value: Some(Json::object(o)) }
          }
          _ => tp
        }
      "doing" if coming.val =>
        {
          ..tp,
          value: Some({
            "doing": [{ "call": "chat.latest", "stage": "sent", "params": { "station": "ws1/st1", "thread": "7" } }],
          }),
        }
      _ => tp
    }
  })
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "a chat short of its end on its page made as nodes: its latest page asked and still coming (the core's doing), its way to the end turns, pressed no more, and asks nothing again, as the old page's to_latest" {
  let calls : Array[Made] = []
  let t = latest_nodes_open(calls, Ref(true))
  guard t.query(Button, label="跳到最新") is Some(b) else { fail("\{Repr(t.words().map(fn(w) { w.0 }))}") }
  assert_true(b.disabled, msg="pressed while its latest page comes")
  guard t.find("3 条新消息") is Some((x, y)) else { fail("\{Repr(t.words().map(fn(w) { w.0 }))}") }
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.latest").length(), 0)
}

///|
test "a chat short of its end on its page made as nodes: its way to the end pressed twice before its latest page comes asks for it once; turning meanwhile, pressed again once its ask failed" {
  let calls : Array[Made] = []
  let t = latest_nodes_open(calls, Ref(false))
  guard t.find("3 条新消息") is Some((x, y)) else { fail("\{Repr(t.words().map(fn(w) { w.0 }))}") }
  assert_true(t.query(Button, label="跳到最新") is Some({ disabled: false, .. }))
  t.tap(x, y)
  t.run_for(@ui.frame_period_default)
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  let made = named(calls, "chat.latest")
  assert_eq(made.length(), 1)
  assert_true(t.query(Button, label="跳到最新") is Some({ disabled: true, .. }), msg="not turning while it comes")
  // (its ask failed: pressed again, asked again)
  (made[0].done)(Err({ "message": "连不上" }))
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="跳到最新") is Some({ disabled: false, .. }), msg="still turning once it failed")
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  assert_eq(named(calls, "chat.latest").length(), 2)
}
