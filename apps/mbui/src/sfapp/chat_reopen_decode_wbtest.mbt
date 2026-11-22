// What a chat costs to open again, in messages read as Messages (sfbase's message_of, counted by messages_decoded):
// what opens waits on a chat (sfbase's chat_opens) again and again as each other thing it waits on comes, reading
// none of its posts as a Message, and asking what it asked before (each face, each link's card, each login's); and a
// chat's page opened, left for Home and opened again over the core's client keeping the chat's value as it let it go
// (@core.Client::keep: the made-up core answering `same`), on the page the app ships and on the page made as nodes:
// none of its messages read again, and only the one come since where one came.

///|
/// The pictures the fixture's chats hold handed over (chat_nodes_lifecycle_keyed_wbtest's, the same chat opened the
/// same ways): what the Testers here hold at most.
fn init {
  @ui.host_image_bytes_known([("src/sfapp/chat_reopen_decode_wbtest.mbt", 159102)])
}

///|
/// A chat of 30 posts as the core gives it: a person's with a link to a screen in its runs, an agent's with a link to a
/// terminal in its runs and one with a login's card under it (an active login's every other), each with its face.
fn rd_chat() -> Json {
  let messages : Array[Json] = []
  for i in 0..<10 {
    let other : Json = if i % 3 == 0 { "st2" } else { "" }
    messages.push({
      "seq": Json::number((3 * i + 1).to_double()),
      "ts": Json::string("t\{3 * i + 1}"),
      "authorKind": "person",
      "author": "ada@example.com",
      "text": Json::string("看下屏幕 \{i}"),
      "words": [
        { "text": "看下" },
        {
          "text": Json::string("屏幕 \{i}"),
          "link": Json::string("stillfail://screen/\{i}"),
          "to": { "card": "screen", "station": "ws1/st1", "screen": Json::string("scr-\{i}") },
        },
      ],
      "by": { "name": "Ada", "picture": Json::string("face-\{i % 4}") },
    })
    messages.push({
      "seq": Json::number((3 * i + 2).to_double()),
      "ts": Json::string("t\{3 * i + 2}"),
      "authorKind": "agent",
      "author": "claude",
      "text": Json::string("终端 \{i}"),
      "words": [
        {
          "text": Json::string("终端 \{i}"),
          "link": Json::string("stillfail://terminal/\{i}"),
          "to": { "card": "terminal", "station": "ws1/st1", "terminal": Json::string("term-\{i}") },
        },
        // (a link to no station: no card asked)
        { "text": "文档", "link": "https://example.com/doc", "to": {} },
      ],
      "by": { "name": "Claude", "agent": "claude", "picture": "agent-face" },
    })
    messages.push({
      "seq": Json::number((3 * i + 3).to_double()),
      "ts": Json::string("t\{3 * i + 3}"),
      "authorKind": "agent",
      "author": "claude",
      "text": "请登录",
      "card": {
        "type": "login",
        "login": Json::string("login-\{i}"),
        "station": other,
      },
      "by": { "name": "Claude", "agent": "claude" },
    })
  }
  {
    "title": "整理发布清单",
    "people": [{ "email": "ada@example.com", "name": "Ada", "picture": "face-0" }, { "email": "bo@example.com", "picture": "face-9" }],
    "messages": Json::array(messages),
  }
}

///|
/// What chat_opens asked of chat `r` with value `v` before it read the chat's value once (as it was till then: each
/// post read as a Message every time), in order: each topic asked and each face waited for.
fn rd_asks_before(r : ChatRef, v : Json) -> Array[String] {
  let out : Array[String] = []
  let ask = fn(name : String, params : Map[String, Json]) { out.push(name + " " + Json::object(params).stringify()) }
  ask("chat", chat_params(r))
  let faces = items(Some(v), "people").map(fn(p) { person_of(p).picture })
  for m in items(Some(v), "messages") {
    if !["agent", "station", "ember", "stillfail"].contains(text(Some(m), "authorKind")) {
      faces.push(by_of(Some(m)).picture)
    }
  }
  let seen : Map[String, Bool] = Map([])
  for f in faces {
    if f != "" && !seen.contains(f) {
      seen[f] = true
      out.push("face " + f)
    }
  }
  for m in items(Some(v), "messages") {
    let links = if field(Some(m), "notice") is None && text(Some(m), "authorKind") != "ember" {
      @sfbase.message_links_to(@sfbase.message_of(m), told=true)
    } else {
      Map([])
    }
    for _, to in links {
      match @sfbase.link_card_ask(to) {
        Some((name, params)) if to.station != "" => ask(name, params)
        _ => ()
      }
    }
    let card = field(Some(m), "card")
    let id = text(card, "login")
    if text(card, "type") != "login" || id == "" {
      continue
    }
    let station = @sfbase.card_login_station(r.station, text(card, "station"))
    let (name, params) = @sfbase.machine_login_ask(station, id)
    ask(name, params)
    if rd_login_active(id) {
      let (name, params) = @sfbase.machine_logins_ask(station)
      ask(name, params)
    }
  }
  out
}

///|
/// Whether login `id` of rd_chat is under way (its station's logins asked too): every other.
fn rd_login_active(id : String) -> Bool {
  id.has_suffix("0") || id.has_suffix("2") || id.has_suffix("4") || id.has_suffix("6") || id.has_suffix("8")
}

///|
test "what opens waits on a chat, asked again and again with the chat's value the same, reads none of its posts as a Message and asks what it asked before" {
  fresh_app()
  let r : ChatRef = { station: "ws1/st1", session: "s-rd", title: "整理发布清单", station_name: "Willow" }
  let v = rd_chat()
  let expected = rd_asks_before(r, v)
  let asked : Array[String] = []
  let src : Source = {
    ..fixture("home"),
    picture_waits: fn(url) {
      asked.push("face " + url)
      false
    },
  }
  let ask = fn(name : String, params : Map[String, Json]) -> @sfbase.TopicState {
    asked.push(name + " " + Json::object(params).stringify())
    let value : Json = match name {
      "chat" => v
      "machineLogin" => { "active": Json::boolean(rd_login_active(text(Some(Json::object(params)), "id"))) }
      _ => { "title": "card" }
    }
    { value: Some(value), error: None, version: 1, waiting: false }
  }
  // (the faces waited for as a page's read_now says: its source's)
  @sfbase.read_now(src) |> ignore
  let before = @sfbase.messages_decoded.val
  for i in 0..<5 {
    asked.clear()
    assert_true(@sfbase.chat_opens(r, ask), msg="check \{i}: not all answered")
    assert_eq(asked, expected, msg="check \{i}: asked otherwise than before")
  }
  let decoded = @sfbase.messages_decoded.val - before
  println("chat_opens, 30 posts checked 5 times: \{decoded} messages read as Messages")
  assert_eq(decoded, 0, msg="posts read as Messages by what opens waits on")
}

///|
/// Chat s-c1 of the fixture's "chat" opened on `screen` (its page made as nodes where `nodes`), left for Home and opened
/// again over the core's client keeping the chat's value as it lets it go; where `one_more`, a message comes as it is
/// opened again (the core's first answer `same`, what came sent after as what changed). How many messages were read as
/// Messages as it was first opened and as it was opened again, and whether what the page read opened again is the core's
/// value read anew.
fn rd_reopen(one_more : Bool, screen : (String, Double, Double, Int)) -> (Int, Int, Int) raise {
  let (name, w, h, platform) = screen
  let label = "\{name} nodes\{if one_more { " +1" } else { "" }}"
  new_run()
  @sf.presenters_reset()
  let held : LsHeld = { value: None, version: 0, changes: @signals.signal(0), ops: None }
  let told : Array[(String, Json)] = []
  // (its unread line over a message in its middle, so its rows hold one)
  let base = fixture("chat")
  let lined : Source = {
    ..base,
    topic_read: fn(name, params) {
      let t = (base.topic_read)(name, params)
      guard ls_mine(name, params) && t.value is Some(Object(o)) else { return t }
      let ms = items(t.value, "messages")
      guard ms.length() > 1 else { return t }
      let v = o.copy()
      v["unreadLine"] = Json::number(number(Some(ms[ms.length() / 2]), "seq"))
      { ..t, value: Some(Json::object(v)) }
    },
  }
  let src = ls_source(lined, held, told)
  let first0 = @sfbase.messages_decoded.val
  open_chat(ls_ref)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, begun=fn() {
    @sfbase.window_tall.val = h
  })
  // (what is counted here is what is read, not how it moves: the chat's pages' motion is their own tests', and the old
  // view's pane on 大屏 goes as it goes on main)
  t.motion_unjudged(true)
  // (the core's client keeping a chat's value as it lets it go, as src/stillfail's main has it)
  @core.client.keep(@sfbase.topic_kept)
  t.run_for(long_rest_ms * 2.0)
  let first = @sfbase.messages_decoded.val - first0
  let count = items(held.value, "messages").length()
  assert_true(opt_number(held.value, "unreadLine") is Some(_), msg="\{label}: no unread line")
  // left for Home
  @ui.view_tree().unwrap().event(t.time(), fn() { home() })
  t.run_for(long_rest_ms * 2.0)
  // opened again
  let again0 = @sfbase.messages_decoded.val
  @ui.view_tree().unwrap().event(t.time(), fn() { open_chat(ls_ref) })
  if one_more {
    // (the core's first answer, `same`, taken; then a message comes, sent as what changed)
    t.run_for(@ui.frame_period_default * 2.0)
    let seq = 1000.0
    ls_change(held, [
      Json::object({
        "path": Json::array([Json::string("messages")]),
        "key": Json::array([Json::string("seq"), Json::string("outgoing")]),
        "put": Json::object({
          "seq": Json::number(seq),
          "ts": Json::string("t-more"),
          "authorKind": Json::string("agent"),
          "author": Json::string("claude"),
          "text": Json::string("又来了一条"),
          "by": Json::object({ "name": Json::string("Claude"), "agent": Json::string("claude") }),
        }),
      }),
    ])
  }
  t.run_for(long_rest_ms * 2.0)
  let again = @sfbase.messages_decoded.val - again0
  // what the page read opened again is the core's value read anew
  let page = @sfbase.page_source_for_chat(src, ls_ref)
  let wanted = items(held.value, "messages").map(@sfbase.message_of)
  assert_eq(wanted.length(), count + (if one_more { 1 } else { 0 }), msg="\{label}: the message come not in the core's value")
  match @sfbase.chat_messages(page, ls_ref) {
    Some(ms) => {
      let keys = ms.peek_keys()
      assert_eq(keys.length(), wanted.length(), msg="\{label}: its messages by key")
      for i, k in keys {
        assert_true(ms.peek(k) == Some(wanted[i]), msg="\{label}: message \{i} not as the core's value says it")
      }
    }
    None => fail("\{label}: its messages not kept by key")
  }
  match @sfbase.chat_head(page, ls_ref).0 {
    Some(v) =>
      assert_eq(v.unread_line, opt_number(held.value, "unreadLine"), msg="\{label}: its unread line")
    None => fail("\{label}: no head opened again")
  }
  @core.client.keep(fn(_, _) { 0 })
  println("\{label}: \{count} messages, read as Messages first opened \{first}, opened again \{again}")
  (count, first, again)
}

///|
test "a chat's page opened again over the core's client keeping its value, on the page the app ships and the page made as nodes, 小屏 and 大屏: none of its messages read again, the one come since alone" {
  // (every case run before any is judged, so a failure says all of them)
  let faults : Array[String] = []
  for screen in cr_screens {
    let label = "\{screen.0}"
    let (count, first, again) = rd_reopen(false, screen)
    if count < 10 || first < count {
      faults.push("\{label}: \{count} messages, \{first} read first")
    }
    if again != 0 {
      faults.push("\{label}: \{again} messages read again opened again")
    }
    let (_, _, again) = rd_reopen(true, screen)
    if again != 1 {
      faults.push("\{label}: \{again} messages read opened again, one come")
    }
  }
  assert_eq(faults, [])
}
