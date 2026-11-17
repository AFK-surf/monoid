// What is worked out of the chats' list beside its rows (the stations at a glance, what the rail's stations' place
// says) tells what reads it only where it comes out otherwise: a chat of the list changed wakes none of it.

///|
fn chats_all_sub(client : @core.Client, ws : String) -> @core.Sub {
  client.peek_topic("chats", params={ "scope": Json::string(ws), "mine": Json::boolean(false) }).unwrap()
}

///|
test "the stations at a glance wake nothing as a chat of the list changes" {
  fresh_app()
  let client = @core.Client::new(fn(_) {  })
  let src = signal_client_source(client)
  let glance = Ref(0)
  let label = Ref(0)
  let stop_glance = @signals.effect(fn() {
    @sfbase.stations_at_glance(src, "w1") |> ignore
    glance.val += 1
  })
  let stop_label = @signals.effect(fn() {
    @sfdesk.rail_stations_label(src, "w1") |> ignore
    label.val += 1
  })
  let sub = chats_all_sub(client, "w1")
  let id = Json::number(sub.id.to_double())
  client.receive_json({
    "id": id,
    "value": {
      "glyph": { "online": 1, "dim": 0, "label": "1 台在线", "summary": "1 台在线" },
      "items": [{ "id": "a", "title": "first", "unread": false }],
    },
  })
  let (g0, l0) = (glance.val, label.val)
  assert_eq(@sfbase.stations_at_glance(src, "w1").0.online, 1)
  // a chat's title and its unread: the list changed, not its glyph nor its trouble
  client.receive_json({ "id": id, "delta": [{ "path": ["items", 0, "title"], "set": "second" }] })
  client.receive_json({ "id": id, "delta": [{ "path": ["items", 0, "unread"], "set": true }] })
  assert_eq(glance.val, g0, msg="the glance read again for a chat's change")
  assert_eq(label.val, l0, msg="the rail's words read again for a chat's change")
  // a station more online: both told
  client.receive_json({ "id": id, "delta": [{ "path": ["glyph", "online"], "set": 2 }] })
  assert_eq(glance.val, g0 + 1)
  assert_eq(@sfbase.stations_at_glance(src, "w1").0.online, 2)
  client.receive_json({ "id": id, "delta": [{ "path": ["glyph", "summary"], "set": "2 台在线" }] })
  assert_eq(label.val, l0 + 1)
  assert_eq(@sfdesk.rail_stations_label(src, "w1"), "2 台在线")
  stop_glance()
  stop_label()
}

///|
test "a chat's row made anew the same is the same row" {
  let row = @sfbase.chat_item({ "id": "a", "session": "s", "title": "first", "agents": [{ "key": "k", "maker": "m" }] })
  let again = { ..row, agents: row.agents.map(fn(a) { { ..a } }) }
  assert_true(!physical_equal(row, again))
  assert_true(row == again, msg="a row made again of the same said the same")
  assert_true(row != { ..row, title: "second" })
}
