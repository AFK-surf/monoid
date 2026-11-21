// What is sent is on screen first (sfbase's sent.mbt LocalSent, flight.mbt): in the list the frame it is sent,
// whatever the core, the list or anything else in it is doing; the core's row goes on from it once it comes.

///|
/// The keys of chat s-c1's rows as last built.
fn sent_rows() -> Array[String] {
  sending_of("ws1/st1\u{1}s-c1").map(fn(l) { "o:" + l.row.id })
}

///|
test "words sent from a window short of the chat's end: its latest page asked for, the list at its end as it comes" {
  let short = @signals.signal(true)
  let calls : Array[Made] = []
  let t = fake_core(calls, over=fn(name, tp) {
    if name != "chat" || !short.get() {
      return tp
    }
    match tp.value {
      Some(Object(m)) => {
        let o = m.copy()
        o["newer"] = Json::boolean(true)
        { ..tp, value: Some(Json::object(o)), version: tp.version + 1 }
      }
      _ => tp
    }
  })
  t.tap_text("发消息")
  t.type_text("先上屏")
  tap_send(t)
  assert_eq(named(calls, "chat.latest").length(), 1)
  // read up there meanwhile; the latest page comes: the list at its end
  t.move_to(195.0, 400.0)
  t.wheel(195.0, 400.0, -900.0)
  assert_true(!t.at_end())
  short.set(false)
  t.draw()
  t.draw()
  assert_true(t.at_end())
}

///|
test "refused by the core: what was sent leaves the list, the words back in the field" {
  let calls : Array[Made] = []
  let t = fake_core(calls)
  t.tap_text("发消息")
  t.type_text("先上屏")
  tap_send(t)
  assert_eq(sent_rows(), ["o:local:1"])
  (named(calls, "chat.send")[0].done)(
    Err({ "code": Json::string("invalid_params"), "message": Json::string("太长了") }),
  )
  t.draw()
  assert_eq(sent_rows(), [])
  let (_, words, _, _) = t.ime()
  assert_eq(words, "先上屏")
}

///|
test "words sent are seen every frame from the field to their bubble: not gone the frame their row is laid out" {
  let calls : Array[Made] = []
  let t = fake_core(calls)
  t.tap_text("发消息")
  t.type_text("先上屏")
  t.draw()
  tap_send(t)
  let sent = t.time()
  while t.time() < sent + flight_ms + 50.0 {
    t.frame()
    seen_once(t, "先上屏") |> ignore
  }
  assert_true(send_flight.get() is None)
}
