// The chat's page made as nodes over a core that keeps its messages by key (the app's own client of a made-up core:
// sffixture's round_trip_again, a change sent as the core's keyed ops), as a device reads it: left, the core told it
// shows no more and where it was left, and told it shows again as it is opened again (its head alone was read: sfbase's
// chat_head keeps it for the page as it is left); a new chat become its chat keeps what was sent from here as the
// core's view of it comes and as it is the new chat's no more (sfpages' chat_body_node going on by key); words streamed
// into its last message on 大屏, its side panel open or not, read none of the chat whole (sfbase's chat_read_made) and
// that message alone once a word (chat_messages_read): its bar, its composer, its side panel read its head alone.

///|
/// The pictures the fixture's chats hold handed over (chat_opens_whole_wbtest's): what the Testers here hold at most.
fn init {
  @ui.host_image_bytes_known([("src/sfapp/chat_nodes_lifecycle_stream_wbtest.mbt", 159102)])
}

///|
/// The fixture's chat (s-c1) as the core holds it once read: its value as changes make it, how many changes, what
/// reads it told as one is made, the ops of the last (what the core sends its subscription).
priv struct LsHeld {
  mut value : Json?
  mut version : Int
  changes : @signals.Signal[Int]
  mut ops : Array[Json]?
}

///|
let ls_ref : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }

///|
/// Whether a topic's params are chat s-c1's.
fn ls_mine(name : String, params : Map[String, Json]) -> Bool {
  name == "chat" && text(Some(Json::object(params)), "session") == ls_ref.session
}

///|
/// `base` with chat s-c1 as `h` holds it, through the app's own client of a made-up core answering at once, each change
/// sent as its ops; what the core is told of where a chat is (`client.focus`, `chat.place`) recorded in `told`.
fn ls_source(base : Source, h : LsHeld, told : Array[(String, Json)]) -> Source {
  let held : Source = {
    ..base,
    topic_read: fn(name, params) {
      let t = (base.topic_read)(name, params)
      guard ls_mine(name, params) else { return t }
      h.changes.get() |> ignore
      if h.value is None {
        h.value = t.value
      }
      match h.value {
        Some(v) => { value: Some(v), error: None, version: 1 + h.version }
        None => t
      }
    },
  }
  let rt = round_trip_again(held, 0.0, delta_of=fn(name, params) { if ls_mine(name, params) { h.ops } else { None } })
  {
    ..rt,
    call: fn(name, args, done) {
      if name == "chat.place" || name == "client.focus" {
        told.push((name, args))
      }
      (rt.call)(name, args, done)
    },
  }
}

///|
/// Chat s-c1 changed by `ops`, as the core changes it.
fn ls_change(h : LsHeld, ops : Array[Json]) -> Unit {
  guard h.value is Some(v) else { return }
  h.value = Some(@core.apply_delta(v, ops))
  h.ops = Some(ops)
  h.version += 1
  h.changes.set(h.version)
}

///|
/// The fixture `mode`'s chat s-c1 opened on `screen` with its page made as nodes, its messages by key, at rest.
fn ls_open(mode : String, screen : (String, Double, Double, Int)) -> (@ui.Tester, Source, LsHeld, Array[(String, Json)]) {
  let (_, w, h, platform) = screen
  new_run()
  @sf.presenters_reset()
  @sfbase.hold_chat_page_nodes(Some(true))
  let held : LsHeld = { value: None, version: 0, changes: @signals.signal(0), ops: None }
  let told : Array[(String, Json)] = []
  let src = ls_source(fixture(mode), held, told)
  open_chat(ls_ref)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, begun=fn() {
    @sfbase.window_tall.val = h
  })
  t.run_for(long_rest_ms * 2.0)
  (t, src, held, told)
}

///|
/// What chat s-c1 was told from the `from`th call on: that it shows (`client.focus {chat}`), that it was left
/// (`client.focus {left}`), where it is (`chat.place`).
fn ls_told(told : Array[(String, Json)], from : Int) -> (Int, Int, Int) {
  let mut shows = 0
  let mut lefts = 0
  let mut places = 0
  for i = from; i < told.length(); i = i + 1 {
    let (name, args) = told[i]
    if name == "client.focus" {
      if text(field(Some(args), "chat"), "session") == ls_ref.session {
        shows += 1
      }
      if text(field(Some(args), "left"), "session") == ls_ref.session {
        lefts += 1
      }
    } else if text(Some(args), "station") == ls_ref.station {
      places += 1
    }
  }
  (shows, lefts, places)
}

///|
test "the chat's page made as nodes read by key, 小屏 and 大屏: left, the core told it shows no more and where it was left; opened again, told it shows" {
  for screen in cr_screens {
    let name = screen.0
    let (t, src, held, told) = ls_open("chat", screen)
    assert_true(held.value is Some(_), msg="\{name}: the chat never read")
    assert_true(
      @sfbase.chat_messages(@sfbase.page_source_for_chat(src, ls_ref), ls_ref) is Some(_),
      msg="\{name}: its messages not kept by key",
    )
    let (shows, _, _) = ls_told(told, 0)
    assert_true(shows > 0, msg="\{name}: opened, not told it shows")
    // read up a little and come to rest
    rs_up(t, screen, screen.2 * 0.3)
    t.run_for(long_rest_ms * 2.0)
    // left
    let k = ls_ref.station + "\u{1}" + ls_ref.session
    @sfbase.kept_places.remove(k)
    let before = told.length()
    @ui.view_tree().unwrap().event(t.time(), fn() { home() })
    t.run_for(long_rest_ms * 2.0)
    let (shows, lefts, _) = ls_told(told, before)
    assert_eq(lefts, 1, msg="\{name}: left, told so \{lefts} times: \{Repr(told[before:].to_owned().map(fn(x) { x.1.stringify() }))}")
    assert_eq(shows, 0, msg="\{name}: told it shows once left")
    match @sfbase.kept_places.get(k) {
      Some(p) => assert_true(p.top >= 0.0, msg="\{name}: where it was left kept with no message at its top")
      None => fail("\{name}: where it was left not kept")
    }
    // opened again: told it shows again
    let again = told.length()
    @ui.view_tree().unwrap().event(t.time(), fn() { open_chat(ls_ref) })
    t.run_for(long_rest_ms * 2.0)
    let (shows, lefts, _) = ls_told(told, again)
    assert_true(shows > 0, msg="\{name}: opened again, not told it shows")
    assert_eq(lefts, 0, msg="\{name}: opened again, told it was left")
  }
}

///|
test "a new chat become its chat, its page made as nodes read by key, 小屏 and 大屏: what was sent stays as the core's view of it comes and as it is the new chat's no more" {
  for screen in cr_screens {
    let (name, w, h, platform) = screen
    new_run()
    @sf.presenters_reset()
    @sfbase.hold_chat_page_nodes(Some(true))
    let src = round_trip_again(fixture("home"), 0.0)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
    // (Home answered by the made-up core first)
    t.run_for(long_rest_ms)
    let words = "看下进度"
    let r = made_new_chat_sent(t, name == "小屏", words)
    t.run_for(long_rest_ms)
    assert_true(made_words_at(t, words) is Some(_), msg="\{name}: what was sent not seen")
    assert_true(made_by_nodes(t, words), msg="\{name}: not the new page's: \{t.sources_of(words)}")
    let page = @sfbase.page_source_for_chat(src, r)
    match @sfbase.chat_messages(page, r) {
      Some(ms) => assert_true(ms.count() > 0, msg="\{name}: the core's view of it holds no message")
      None => fail("\{name}: its messages not kept by key")
    }
    // the new chat's no more (another new chat begun elsewhere: sfbase's fresh_reset), its page as it was
    @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.fresh_reset() })
    t.run_for(long_rest_ms)
    assert_true(made_words_at(t, words) is Some(_), msg="\{name}: what was sent gone as it is the new chat's no more")
    assert_true(made_by_nodes(t, words), msg="\{name}: not the new page's once the new chat's no more")
  }
}

///|
/// The last message of chat value `v`: its key as the core keys it (`seq`, `outgoing`) and its words.
fn ls_last(v : Json?) -> (Json, String)? {
  let ms = items(v, "messages")
  guard ms.last() is Some(Object(m)) else { return None }
  let key = Json::array([m.get("seq").unwrap_or(Json::null()), m.get("outgoing").unwrap_or(Json::null())])
  Some((key, text(Some(Json::object(m)), "text")))
}

///|
/// The fixture `mode`'s chat on `screen`, `words` words streamed into its last message as the core sends them: how
/// many times it was worked out whole, how many messages were read, and its last message's words as the page's source
/// keeps them by key.
fn ls_stream(mode : String, screen : (String, Double, Double, Int), words : Int) -> (Int, Int, String?) raise {
  let (t, src, held, _) = ls_open(mode, screen)
  guard ls_last(held.value) is Some((key, first)) else { fail("\{mode} \{screen.0}: no message") }
  let whole0 = @sfbase.chat_read_made.val
  let read0 = @sfbase.chat_messages_read.val
  let mut said = first
  for i in 0..<words {
    said = said + "字\{i}"
    ls_change(held, [
      Json::object({
        "path": Json::array([Json::string("messages")]),
        "key": Json::array([Json::string("seq"), Json::string("outgoing")]),
        "patch": key,
        // (its words and their Markdown as the core sends both: none asked of the core to read)
        "ops": Json::array([
          Json::object({ "path": Json::array([Json::string("text")]), "set": Json::string(said) }),
          Json::object({
            "path": Json::array([Json::string("md")]),
            "set": Json::array([Json::array([Json::string("p"), Json::array([Json::string(said)])])]),
          }),
        ]),
      }),
    ])
    t.run_for(@ui.frame_period_default)
  }
  t.run_for(@ui.move_most_ms)
  let whole = @sfbase.chat_read_made.val - whole0
  let read = @sfbase.chat_messages_read.val - read0
  let page = @sfbase.page_source_for_chat(src, ls_ref)
  let last = match @sfbase.chat_messages(page, ls_ref) {
    Some(ms) =>
      match ms.peek_keys().last() {
        Some(k) => ms.peek(k).map(fn(m) { m.text })
        None => None
      }
    None => None
  }
  assert_true(last == Some(said), msg="\{mode} \{screen.0}: the words streamed in not taken: \{Repr(last)}")
  (whole, read, last)
}

///|
test "words streamed into the last message of a chat's page made as nodes, 大屏 with its side panel shut, on 往来 and on 文件, and 小屏: none of the chat read whole, that message alone once a word" {
  let cases = [("chat", cr_screens[1]), ("chat-letters-side", cr_screens[1]), ("chat-things-side", cr_screens[1]), ("chat", cr_screens[0])]
  for case in cases {
    let (mode, screen) = case
    let (whole, read, _) = ls_stream(mode, screen, 10)
    assert_eq(whole, 0, msg="\{mode} \{screen.0}: the chat worked out whole \{whole} times")
    assert_eq(read, 10, msg="\{mode} \{screen.0}: \{read} messages read for 10 words")
  }
}
