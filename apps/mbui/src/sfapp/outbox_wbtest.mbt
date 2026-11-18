// What was sent from here and is not in the chat yet (sfpages' chat_rows.mbt outbox_row, outbox_unsent): 正在发送 a
// while after it went (or what it waits on), its time once the station has it, and what did not go: 未发送 with 重试 (or,
// refused as it is, 编辑: its words back in the composer) and 删除, each asking the core by the chat's thread; what is
// held till its station is reached (连上后发出) taken back the same way, 编辑 or 删除 beside it.

///|
/// The fixture's chat with `out` (the core's ChatView `outbox`) after its messages, its calls kept in `calls`;
/// `offline`: its station not reached.
fn outbox_chat(calls : Array[Made], out : Json, offline? : Bool = false, nodes? : Bool = false) -> @ui.Tester {
  // (dropped once the core is asked to (chat.discard, by its id), as the core drops it: a signal, so the chat's topic
  // read over it is told)
  let gone = @signals.signal(false)
  let id = text(Some(out), "id")
  fake_core(calls, nodes~, on_call=fn(name, params) {
    if name == "chat.discard" && text(Some(params), "id") == id {
      gone.set(true)
    }
  }, over=fn(name, tp) {
    guard name == "chat" && tp.value is Some(Object(m)) else { return tp }
    let o = m.copy()
    if !gone.get() {
      o["outbox"] = Json::array([out])
    }
    o["askClear"] = Json::boolean(false)
    if offline {
      o["offline"] = Json::boolean(true)
    }
    { ..tp, value: Some(Json::object(o)) }
  })
}

///|
fn outgoing(
  state : String,
  refused? : Bool = false,
  error? : String = "",
  waits? : String = "",
  held? : Bool = false,
  unsure? : Bool = false,
  at? : Double = 0.0,
  quotes? : Array[Json] = [],
) -> Json {
  {
    "held": Json::boolean(held),
    "unsure": Json::boolean(unsure),
    "id": "o-1",
    "text": "这条还在路上",
    "quotes": Json::array(quotes),
    "state": Json::string(state),
    "final": Json::boolean(refused),
    "error": Json::string(error),
    "waits": Json::string(waits),
    "createdAt": Json::number(at),
    "time": { "createdAt": { "at": 0, "ago": "刚刚", "full": "10/19 06:40:00", "until": "", "past": true } },
  }
}

///|
/// Whether `words` are drawn and seen (not at nothing).
fn outbox_seen(t : @ui.Tester, words : String) -> Bool {
  t.words().iter().any(fn(w) { w.0 == words && w.5 > 0.0 })
}

///|
fn unsent_press(t : @ui.Tester, label : String) -> Unit raise {
  guard t.query(Button, label~) is Some(b) else { fail("no \{label}") }
  let (x, y, w, h) = b.rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.draw()
}

///|
test "what did not go says 未发送 under it; 重试 asks the core to send it again, 删除 to drop it, each by the chat's thread" {
  let calls : Array[Made] = []
  let t = outbox_chat(calls, outgoing("failed", error="连不上 Willow"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("这条还在路上") is Some(_))
  assert_true(t.find("未发送") is Some(_))
  assert_true(t.find("编辑") is None)
  unsent_press(t, "重试")
  let made = named(calls, "chat.retry")
  assert_eq(made.length(), 1)
  assert_eq(text(Some(made[0].params), "id"), "o-1")
  assert_eq(text(Some(made[0].params), "station"), "ws1/st1")
  assert_eq(number(Some(made[0].params), "thread"), 7.0)
  unsent_press(t, "删除")
  let made = named(calls, "chat.discard")
  assert_eq(made.length(), 1)
  assert_eq(text(Some(made[0].params), "id"), "o-1")
}

///|
test "what was refused as it is says why, and 编辑 in place of 重试 puts its words back in the composer as it drops it" {
  let calls : Array[Made] = []
  let t = outbox_chat(calls, outgoing("failed", refused=true, error="a.jpg 的上传源已丢失"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("发送失败：a.jpg 的上传源已丢失") is Some(_))
  assert_true(t.query(Button, label="重试") is None)
  unsent_press(t, "编辑")
  assert_eq(named(calls, "chat.discard").length(), 1)
  assert_eq(named(calls, "chat.retry").length(), 0)
  // (dropped from the list as it is from the core: its bubble and why it was refused gone)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("发送失败：a.jpg 的上传源已丢失") is None)
  assert_true(t.find("a.jpg 的上传源已丢失") is None)
  // (its words in the composer's field, to be sent anew)
  let typed = named(calls, "composer.text").map(fn(m) { text(Some(m.params), "text") })
  assert_true(typed.contains("这条还在路上"), msg="\{Repr(typed)}")
}

///|
test "its station not reached, what did not go cannot be sent again from here (重试 not pressed); 删除 still drops it" {
  let calls : Array[Made] = []
  let t = outbox_chat(calls, outgoing("failed"), offline=true)
  t.run_for(@ui.move_most_ms)
  unsent_press(t, "重试")
  assert_eq(named(calls, "chat.retry").length(), 0)
  unsent_press(t, "删除")
  assert_eq(named(calls, "chat.discard").length(), 1)
}

///|
test "正在发送 shows under what is on its way only once it has been a while (800 ms), what it waits on in its place where the core says" {
  let calls : Array[Made] = []
  let t = outbox_chat(calls, outgoing("sending"))
  t.draw()
  assert_true(!outbox_seen(t, "正在发送"))
  t.run_for(@sfpages.sending_shows_ms)
  assert_true(outbox_seen(t, "正在发送"))
  let calls : Array[Made] = []
  let t = outbox_chat(calls, outgoing("sending", waits="正在上传 2 个文件"))
  t.run_for(@sfpages.sending_shows_ms)
  assert_true(outbox_seen(t, "正在上传 2 个文件"))
  assert_true(!outbox_seen(t, "正在发送"))
}

///|
test "a chat opened on what has been on its way a while says 正在发送 under it at once, its wait counted from when it was sent" {
  let calls : Array[Made] = []
  // (sent 5 s before the source's time of day: the fixture's, 0)
  let t = outbox_chat(calls, outgoing("sending", at=-5000.0))
  t.draw()
  assert_true(outbox_seen(t, "正在发送"))
}

///|
test "once the station has it, what was sent says its time under it, not 正在发送, till its message takes its place" {
  let calls : Array[Made] = []
  let t = outbox_chat(calls, outgoing("sent"))
  t.run_for(@sfpages.sending_shows_ms)
  assert_true(!outbox_seen(t, "正在发送"))
  assert_true(outbox_seen(t, "刚刚"), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  assert_true(t.find("未发送") is None)
}

///|
/// 编辑 once lost what was refused (2026-11-17): its words were told the core alone, the field's own words (none, or
/// a draft begun) told back over them as the composer was next built, its quotes not put back at all.
test "编辑 on what was refused puts its words after the draft begun and its quotes back in the composer, on both pages, and they stay" {
  for nodes in [false, true] {
    let calls : Array[Made] = []
    let quote : Json = {
      "author": "Claude",
      "text": "引用的那一段",
      "comment": "再看看",
      "ts": "1.0",
      "role": "agent",
    }
    let t = outbox_chat(
      calls,
      outgoing("failed", refused=true, error="a.jpg 的上传源已丢失", quotes=[quote]),
      nodes~,
    )
    t.run_for(@ui.move_most_ms)
    t.tap_text("发消息")
    t.type_text("刚写的草稿")
    unsent_press(t, "编辑")
    t.run_for(@ui.move_most_ms)
    let merged = "刚写的草稿\n这条还在路上"
    // (in the field, as the composer has been built again since, and as the core keeps it)
    let (active, words, _, _) = t.ime()
    assert_true(active, msg="nodes=\{nodes}")
    assert_eq(words, merged)
    let typed = named(calls, "composer.text")
    assert_eq(text(Some(typed[typed.length() - 1].params), "text"), merged)
    // its quote put back as it was said
    let quoted = named(calls, "composer.quote")
    assert_eq(quoted.length(), 1, msg="nodes=\{nodes}")
    let q = field(Some(quoted[0].params), "quote")
    assert_eq(text(q, "text"), "引用的那一段")
    assert_eq(text(q, "comment"), "再看看")
    assert_eq(text(q, "ts"), "1.0")
    assert_eq(named(calls, "chat.discard").length(), 1)
    assert_true(t.find("发送失败：a.jpg 的上传源已丢失") is None, msg="nodes=\{nodes}")
    assert_true(t.find("a.jpg 的上传源已丢失") is None, msg="nodes=\{nodes}")
  }
}

///|
test "what is held till its station is reached says 连上后发出 with 编辑 and 删除 beside it, on both pages, pressed with the station not reached" {
  for nodes in [false, true] {
    let calls : Array[Made] = []
    let t = outbox_chat(calls, outgoing("sending", waits="连上后发出", held=true, at=-5000.0), offline=true, nodes~)
    t.run_for(@ui.move_most_ms)
    assert_true(outbox_seen(t, "连上后发出"), msg="nodes=\{nodes}")
    assert_true(t.find("未发送") is None)
    assert_true(t.query(Button, label="重试") is None)
    unsent_press(t, "删除")
    let made = named(calls, "chat.discard")
    assert_eq(made.length(), 1, msg="nodes=\{nodes}")
    assert_eq(text(Some(made[0].params), "id"), "o-1")
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("这条还在路上") is None, msg="nodes=\{nodes}")
    assert_true(!outbox_seen(t, "连上后发出"), msg="nodes=\{nodes}")
    // 编辑: its words back in the composer as it is dropped
    let calls : Array[Made] = []
    let t = outbox_chat(calls, outgoing("sending", waits="连上后发出", held=true, at=-5000.0), offline=true, nodes~)
    t.run_for(@ui.move_most_ms)
    unsent_press(t, "编辑")
    t.run_for(@ui.move_most_ms)
    assert_eq(named(calls, "chat.discard").length(), 1, msg="nodes=\{nodes}")
    let (_, words, _, _) = t.ime()
    assert_eq(words, "这条还在路上", msg="nodes=\{nodes}")
  }
}

///|
test "what is on its way and not held (its station updating) has nothing beside its wait to take it back" {
  let calls : Array[Made] = []
  let t = outbox_chat(calls, outgoing("sending", waits="station 更新完后发出", at=-5000.0))
  t.run_for(@ui.move_most_ms)
  assert_true(outbox_seen(t, "station 更新完后发出"))
  assert_true(t.query(Button, label="删除") is None)
  assert_true(t.query(Button, label="编辑") is None)
}

///|
test "what did not go after it went out with no answer (it may be the station's already) has 重试 and no 删除, on both pages" {
  for nodes in [false, true] {
    let calls : Array[Made] = []
    let t = outbox_chat(calls, outgoing("failed", error="连接断开", unsure=true), nodes~)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("未发送") is Some(_), msg="nodes=\{nodes}")
    assert_true(t.query(Button, label="删除") is None, msg="nodes=\{nodes}")
    unsent_press(t, "重试")
    assert_eq(named(calls, "chat.retry").length(), 1, msg="nodes=\{nodes}")
  }
}
