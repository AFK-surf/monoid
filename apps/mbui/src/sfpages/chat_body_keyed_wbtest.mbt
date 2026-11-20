// A chat's list by key (chat_body_keyed) against the same chat's rows made whole (chat_body_rows): the same keys in the
// same order, each the same row; and its page as the core changes a message by key: what reads the chat whole
// (chat_read) not worked out at all, one message read again for each word streamed in, the same in a chat of 50
// messages as in one of 150.

///|
/// Chat value `chat`'s messages by key, as a subscription keeps them (@core.Sub::keyed: each by its `seq` and
/// `outgoing`'s JSON text).
fn keyed_of(chat : Json) -> @signals.KeyedList[String, Json] {
  let list : @signals.KeyedList[String, Json] = @signals.keyed_list()
  let keys : Array[String] = []
  let vals : Map[String, Json] = Map([])
  for m in items(Some(chat), "messages") {
    let k = keyed_key(m)
    keys.push(k)
    vals[k] = m
  }
  list.reset(keys, vals)
  list
}

///|
/// A message's key's text, as the core keys it.
fn keyed_key(m : Json) -> String {
  let f = fn(name : String) {
    match m {
      Object(o) => o.get(name).unwrap_or(Json::null())
      _ => Json::null()
    }
  }
  Json::array([f("seq"), f("outgoing")]).stringify()
}

///|
/// Where chat_body_keyed's rows of chat value `chat` are not chat_body_rows' of it made whole.
fn keyed_faults(chat : Json, name : String, sending? : Array[@sfbase.LocalSent] = []) -> Array[String] {
  let whole = @sfbase.chat_view_made(chat)
  let head = { ..whole, messages: [] }
  let msgs = @sfbase.chat_messages_of(keyed_of(chat))
  let era = @signals.computed(fn(_) { 0 })
  let keyed = chat_body_keyed({ sent: {}, sent_as: {}, here: {} }, era, fn() { head }, msgs, sending=fn() { sending })
  let made = chat_body_rows({ sent: {}, sent_as: {}, here: {} }, whole, @sfbase.entries_of(whole), sending)
  let watch = @signals.watch(fn() {  })
  let faults : Array[String] = []
  watch.read(fn() {
    let keys = (keyed.keys)()
    if keys != made.keys {
      faults.push("\{name}: keys \{Repr(keys)} for \{Repr(made.keys)}")
    }
    for k in made.keys {
      match ((keyed.row)(k), made.rows.get(k)) {
        (Some(a), Some(b)) => {
          let followed = fn(e : Entry) {
            match e {
              Said(m) => m.followed
              Out(o) => o.followed
              _ => false
            }
          }
          if !(a.gap == b.gap && a.slices == b.slices && a.entry.id() == b.entry.id() && followed(a.entry) == followed(b.entry)) {
            faults.push("\{name}: row \{k} otherwise (gap \{a.gap == b.gap}, slices \{a.slices == b.slices}, followed \{followed(a.entry)} \{followed(b.entry)}, \{a.entry.id()} \{b.entry.id()})")
          }
        }
        _ => faults.push("\{name}: row \{k} missing")
      }
      // (how many slices each is drawn in, worked out of its JSON alone, as of it read whole)
      let n = (keyed.slices)(k)
      let want = made.rows.get(k).map_or(1, fn(r) { r.slices })
      if n != want {
        faults.push("\{name}: row \{k} in \{n} slices, \{want} made whole")
      }
    }
  })
  watch.stop()
  faults
}

///|
/// Chat value `chat` with `fields` set.
fn keyed_with(chat : Json, fields : Map[String, Json]) -> Json {
  guard chat is Object(o) else { return chat }
  let out = o.copy()
  for k, v in fields {
    out[k] = v
  }
  Json::object(out)
}

///|
test "a chat's rows by key are its rows made whole" {
  @sfbase.reset()
  reset()
  let chat = scale_chat(12)
  let long = "第一段\n\n第二段\n\n第三段"
  let md = Json::array([body_para("第一段"), body_para("第二段"), body_para("第三段")])
  guard chat is Object(o) && o.get("messages") is Some(Array(ms)) else { fail("no messages") }
  let ms = ms.copy()
  // (an agent's long answer in pieces, one joined to the one before, one with what went elsewhere after it)
  guard ms[5] is Object(m5) && ms[7] is Object(m7) && ms[3] is Object(m3) else { fail("no message") }
  let m5 = m5.copy()
  m5["text"] = Json::string(long)
  m5["md"] = md
  ms[5] = Json::object(m5)
  let m7 = m7.copy()
  m7["joined"] = Json::boolean(true)
  ms[7] = Json::object(m7)
  let m3 = m3.copy()
  m3["elsewhere"] = Json::array([Json::object({ "key": Json::string("e1"), "text": Json::string("去了 Slack") })])
  ms[3] = Json::object(m3)
  // (agents' long answers: one in pieces of its paragraphs, one of a table's rows, its pieces worked out of its JSON
  // as of it read whole; one a card is drawn in the place of, and a system line, in none)
  let long_of = fn(i : Int, fields : Map[String, Json]) raise {
    guard ms[i] is Object(m) else { fail("no message \{i}") }
    let m = m.copy()
    m["text"] = Json::string(long)
    m["md"] = md
    for k, v in fields {
      m[k] = v
    }
    ms[i] = Json::object(m)
  }
  long_of(8, {})
  let row = fn(n : Int) -> Json { ["tr", [["td", ["格\{n}"]]]] }
  long_of(6, { "md": [["p", ["表前"]], ["table", Json::array(Array::makei(9, row))]] })
  long_of(10, { "card": { "type": "vault", "vaultAsk": { "name": "钥匙" } } })
  long_of(4, { "system": true })
  let base = keyed_with(chat, { "messages": Json::array(ms) })
  // (those in slices in it, and those not: a key each all the same)
  let whole = chat_body_rows({ sent: {}, sent_as: {}, here: {} }, @sfbase.chat_view_made(base), @sfbase.entries_of(@sfbase.chat_view_made(base)), [])
  let slices = fn(k : String) { whole.rows.get(k).map_or(0, fn(r) { r.slices }) }
  assert_true(slices("m:t9") >= 3 && slices("m:t7") >= 4, msg="\{slices("m:t9")} \{slices("m:t7")}")
  assert_eq((slices("m:t11"), slices("m:t5"), slices("m:t6")), (1, 1, 1))
  assert_true(!whole.keys.iter().any(fn(k) { k.contains("#") }), msg="\{Repr(whole.keys)}")
  let faults : Array[String] = []
  faults.append(keyed_faults(base, "plain"))
  faults.append(keyed_faults(keyed_with(base, { "unreadLine": Json::number(6.0) }), "unread line"))
  faults.append(keyed_faults(keyed_with(base, { "unreadLine": Json::number(1.0) }), "unread line first"))
  faults.append(keyed_faults(keyed_with(base, { "more": Json::boolean(true) }), "more"))
  faults.append(keyed_faults(keyed_with(base, { "more": Json::boolean(true), "older": Json::string("failed"), "olderFailed": Json::string("x") }), "older failed"))
  faults.append(keyed_faults(keyed_with(base, { "newer": Json::boolean(true) }), "newer"))
  faults.append(keyed_faults(keyed_with(base, { "stateText": Json::string("等你"), "stateLead": Json::string("need") }), "state"))
  faults.append(
    keyed_faults(
      keyed_with(base, {
        "agents": Json::array([
          Json::object({ "key": Json::string("a1"), "name": Json::string("Claude"), "status": Json::string("running") }),
        ]),
      }),
      "at work",
    ),
  )
  faults.append(keyed_faults(keyed_with(base, { "messages": Json::array([]) }), "empty"))
  faults.append(
    keyed_faults(
      keyed_with(base, { "elsewhere": Json::array([Json::object({ "key": Json::string("e0"), "text": Json::string("前") })]) }),
      "elsewhere before",
    ),
  )
  // (what was sent from here: on its way, after the outbox; taken over by the core's message after the newest there
  // as it was sent; taken over by the core's outbox entry; one joined, the row before it followed)
  let sent = fn(id : String, newest : Double, joined : Bool) -> @sfbase.LocalSent {
    { row: { ..chat_body_no_out, id, text: "刚发的", joined, state: "sending" }, before: Map([]), newest }
  }
  let outbox = Json::array([
    Json::object({ "id": Json::string("out1"), "text": Json::string("发件箱里的"), "state": Json::string("sending"), "createdAt": Json::number(0.0) }),
  ])
  faults.append(keyed_faults(base, "sending", sending=[sent("local:1", 12.0, false)]))
  faults.append(keyed_faults(base, "sending joined", sending=[sent("local:1", 12.0, true), sent("local:2", 12.0, true)]))
  faults.append(keyed_faults(keyed_with(base, { "outbox": outbox }), "outbox"))
  faults.append(keyed_faults(keyed_with(base, { "outbox": outbox }), "outbox taken", sending=[sent("local:1", 12.0, false)]))
  faults.append(keyed_faults(base, "taken by a message", sending=[sent("local:1", 10.0, false)]))
  assert_eq(faults, [])
}

///|
/// What a chat of `n` messages took, open on 小屏 on a source that keeps its messages by key, for `words` words
/// streamed into its last message, each a change as the core's: the times it was worked out whole (chat_read), the
/// messages read again, and what the tree did (bound, made, let go, laid, measured).
fn keyed_run(n : Int, words : Int) -> (Int, Int, (Int, Int, Int, Int, Int)) raise {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  let chat = @signals.signal(scale_chat(n))
  let list = keyed_of(chat.untracked())
  let src : Source = {
    ..@sfbase.made_source(call=fn(_, _, done) { done(Ok(Json::null())) }),
    topic_read: fn(name, _) {
      if name == "chat" {
        { value: Some(chat.get()), error: None, version: 1 }
      } else {
        { value: None, error: None, version: 0 }
      }
    },
    topic_keyed: fn(name, _, _, _) { if name == "chat" { Some(list) } else { None } },
  }
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(f) {
        f.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chat_page_body_node(f, src, scale_ref, tips~, stint=fn() { 0 }, shows=fn() { true })
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=844.0,
    platform=2,
  )
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(scale_words(0)) is Some(_), msg="\{n}: its last message shown")
  let whole0 = @sfbase.chat_read_made.val
  let read0 = @sfbase.chat_messages_read.val
  let w0 = scale_work()
  let mut said = scale_words(0)
  for i in 0..<words {
    said = said + "字\{i}"
    let ops = [
      Json::object({ "path": Json::array([Json::string("text")]), "set": Json::string(said) }),
      Json::object({ "path": Json::array([Json::string("md")]), "set": body_md(said) }),
    ]
    let k = keyed_key(scale_message(n, ""))
    // (as the core's delta changes the value whole, and its keyed list by key: @core.Sub's)
    @signals.start_batch()
    chat.set(
      @core.apply_delta(chat.untracked(), [
        Json::object({
          "path": Json::array([Json::string("messages")]),
          "key": Json::array([Json::string("seq"), Json::string("outgoing")]),
          "patch": scale_key(n),
          "ops": Json::array(ops),
        }),
      ]),
    )
    list.put(k, @core.apply_delta(list.peek(k).unwrap(), ops))
    @signals.end_batch()
    t.run_for(@ui.frame_period_default)
  }
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(said) is Some(_), msg="\{n}: the words streamed in shown")
  (@sfbase.chat_read_made.val - whole0, @sfbase.chat_messages_read.val - read0, scale_did(w0, scale_work()))
}

///|
test "words streamed into a chat's last message read that message alone, by key, the same in a chat of 50 as of 150" {
  let (whole50, read50, did50) = keyed_run(50, 5)
  let (whole150, read150, did150) = keyed_run(150, 5)
  // (nothing reads the chat whole: its head and that message alone)
  assert_eq((whole50, whole150), (0, 0))
  // (each word: the message it came into read once)
  assert_eq((read50, read150), (5, 5))
  assert_true(did150 == did50, msg="150 messages \{Repr(did150)}, 50 \{Repr(did50)}")
}

///|
/// The chat's messages by key the source keeps another list of (its chat read again: sfbase's chat_messages, by the
/// list's object): the page's list goes on by that one, what came in it shown, not the list given first.
test "a chat's messages by key given anew by its source: the page's list goes on by the new one, its message shown" {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  let first = scale_chat(3)
  let chat = @signals.signal(first)
  // (a list held by its object, as the source holds it: another one given is the change)
  let list = @signals.signal_ref(keyed_of(first))
  let src : Source = {
    ..@sfbase.made_source(call=fn(_, _, done) { done(Ok(Json::null())) }),
    topic_read: fn(name, _) {
      if name == "chat" {
        { value: Some(chat.get()), error: None, version: 1 }
      } else {
        { value: None, error: None, version: 0 }
      }
    },
    topic_keyed: fn(name, _, _, _) { if name == "chat" { Some(list.get()) } else { None } },
  }
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(f) {
        f.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chat_page_body_node(f, src, scale_ref, tips~, stint=fn() { 0 }, shows=fn() { true })
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=844.0,
    platform=2,
  )
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(scale_words(0)) is Some(_))
  // (read again: another list, a message more in it, and the head another with it)
  let again = keyed_with(scale_chat(3), {
    "title": Json::string("很长的对话（又读了一遍）"),
    "messages": Json::array(
      items(Some(scale_chat(3)), "messages") + [scale_message(4, scale_put)],
    ),
  })
  @signals.start_batch()
  list.set(keyed_of(again))
  chat.set(again)
  @signals.end_batch()
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(scale_put) is Some(_), msg="the message in the list given anew not shown")
}

///|
test "where it stood, the turn before's: gone in the frame words are sent from here; kept offline, what was sent waiting" {
  @sfbase.reset()
  reset()
  let base = keyed_with(scale_chat(12), { "stateText": Json::string("已完成：用户选择了「不需要部署」"), "stateLead": Json::string("done") })
  let sending : Array[@sfbase.LocalSent] = [
    { row: { ..chat_body_no_out, id: "local:1", text: "刚发的", state: "sending" }, before: Map([]), newest: 12.0 },
  ]
  let states = fn(chat : Json, sending : Array[@sfbase.LocalSent]) {
    let v = @sfbase.chat_view_made(chat)
    let made = chat_body_rows({ sent: {}, sent_as: {}, here: {} }, v, @sfbase.entries_of(v), sending)
    made.keys.filter(fn(k) { made.rows.get(k).map_or(false, fn(r) { r.entry is State(_, _, _) }) }).length()
  }
  // (nothing on its way: where it stands shown)
  assert_eq(states(base, []), 1)
  // (words sent from here, the station up: gone with them, by key as made whole)
  assert_eq(states(base, sending), 0)
  // (its station down: kept, what was sent waiting to go)
  let offline = keyed_with(base, { "offline": Json::boolean(true) })
  assert_eq(states(offline, sending), 1)
  let faults : Array[String] = []
  faults.append(keyed_faults(base, "state, sending", sending~))
  faults.append(keyed_faults(offline, "state, sending offline", sending~))
  assert_eq(faults, [])
}
