// A chat's page made as nodes (chat_page_body_node) as the core's keyed deltas change its chat (src/core delta.mbt
// apply_delta, as a device applies them): an in-place edit patched into its last message, a message put at its end.
// What the tree does for each (bindings looked at, nodes made and let go, laid out and measured) is that of the rows the
// change reached, the same in a chat of 50 messages as in one of 500: nothing along the way (the delta, chat_read,
// chat_view_of, its entries, chat_body_rows, each row's computed) works through the chat's other messages again
// so as to wake what shows them.

///|
/// The chat these tests open (chat_page_body_node's `r`).
// kept across runs: a value
let scale_ref : ChatRef = { station: "ws1/st1", session: "s-scale", title: "很长的对话", station_name: "Willow" }

///|
/// Message `seq` of a long chat: a line of the viewer's or of an agent's in turn, `words` its words (and its Markdown,
/// as the core says every message's: body_md).
fn scale_message(seq : Int, words : String) -> Json {
  let mine = seq % 2 == 0
  Json::object({
    "seq": Json::number(seq.to_double()),
    "ts": Json::string("t" + seq.to_string()),
    "authorKind": Json::string(if mine { "person" } else { "agent" }),
    "author": Json::string(if mine { "me@x.com" } else { "Claude" }),
    "text": Json::string(words),
    "md": body_md(words),
    "mine": Json::boolean(mine),
    "by": Json::object({ "name": Json::string(if mine { "我" } else { "Claude" }) }),
  })
}

///|
/// A chat of `n` messages as the core's `chat` topic says it, each saying how far it is from the last (what shows at
/// its end the same words in a chat of any length).
fn scale_chat(n : Int) -> Json {
  Json::object({
    "title": Json::string("很长的对话"),
    "me": Json::object({ "email": Json::string("me@x.com") }),
    "thread": Json::object({ "id": Json::number(9.0) }),
    "agents": Json::array([]),
    "people": Json::array([]),
    "messages": Json::array(Array::makei(n, fn(i) { scale_message(i + 1, scale_words(n - 1 - i)) })),
  })
}

///|
/// The words of a message `back` from a chat's last (0: the last).
fn scale_words(back : Int) -> String {
  "倒数第 \{back} 条"
}

///|
/// The last message's words after an in-place edit.
// kept across runs: a value
let scale_patched : String = "倒数第 0 条，已编辑"

///|
/// The words of the message put at a chat's end.
// kept across runs: a value
let scale_put : String = "新来的一条"

///|
/// A message's key in the chat's keyed ops (client/core-ts collections.ts: `seq` and `outgoing`, none of these sent
/// from here).
fn scale_key(seq : Int) -> Json {
  Json::array([Json::number(seq.to_double()), Json::null()])
}

///|
/// What the tree did (Tree::work) as it stands.
fn scale_work() -> @view.Work {
  @ui.view_tree().unwrap().work()
}

///|
/// What the tree did from `a` to `b`, of what a change costs: bindings looked at, nodes made and let go, laid out and
/// measured.
fn scale_did(a : @view.Work, b : @view.Work) -> (Int, Int, Int, Int, Int) {
  (b.bound - a.bound, b.made - a.made, b.let_go - a.let_go, b.laid - a.laid, b.measured - a.measured)
}

///|
/// What the tree did as a chat of `n` messages, open on 小屏 at its end, took an in-place edit to its last message
/// and then a message put at its end, each as the core's delta says it.
fn scale_run(n : Int) -> ((Int, Int, Int, Int, Int), (Int, Int, Int, Int, Int)) raise {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  let chat = @signals.signal(scale_chat(n))
  let src : Source = {
    ..@sfbase.made_source(call=fn(_, _, done) { done(Ok(Json::null())) }),
    topic_read: fn(name, _) {
      if name == "chat" {
        { value: Some(chat.get()), error: None, version: 1 }
      } else {
        { value: None, error: None, version: 0 }
      }
    },
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
  // an in-place edit to the last message: its words patched, its lines as many
  let w0 = scale_work()
  chat.set(
    @core.apply_delta(chat.get(), [
      Json::object({
        "path": Json::array([Json::string("messages")]),
        "key": Json::array([Json::string("seq"), Json::string("outgoing")]),
        "patch": scale_key(n),
        "ops": Json::array([
          Json::object({ "path": Json::array([Json::string("text")]), "set": Json::string(scale_patched) }),
          Json::object({ "path": Json::array([Json::string("md")]), "set": body_md(scale_patched) }),
        ]),
      }),
    ]),
  )
  t.run_for(@ui.move_most_ms)
  let patched = scale_did(w0, scale_work())
  assert_true(t.find(scale_patched) is Some(_), msg="\{n}: the patched text shown")
  // a message put at its end
  let w1 = scale_work()
  chat.set(
    @core.apply_delta(chat.get(), [
      Json::object({
        "path": Json::array([Json::string("messages")]),
        "key": Json::array([Json::string("seq"), Json::string("outgoing")]),
        "put": scale_message(n + 1, scale_put),
      }),
    ]),
  )
  t.run_for(@ui.move_most_ms)
  let put = scale_did(w1, scale_work())
  assert_true(t.find(scale_put) is Some(_), msg="\{n}: the message put shown")
  (patched, put)
}

///|
test "an in-place edit to a chat's last message and a message put at its end do the same work in a chat of 50 messages as in one of 500" {
  let (patched50, put50) = scale_run(50)
  let (patched500, put500) = scale_run(500)
  // (bound, made, let go, laid, measured)
  assert_true(patched500 == patched50, msg="an in-place edit: 500 messages \{Repr(patched500)}, 50 \{Repr(patched50)}")
  // (a message put: the same but for the list's scroll bar, whose thumb grows shorter with the chat while it is longer
  // than its least (50 messages: its three nodes laid out again), at its least in a chat of 500)
  assert_true(
    put500.0 == put50.0 && put500.1 == put50.1 && put500.2 == put50.2 && put500.4 == put50.4 && put500.3 <= put50.3,
    msg="a message put: 500 messages \{Repr(put500)}, 50 \{Repr(put50)}",
  )
  // (only what showed the patched message looked at again: none made, none let go)
  assert_eq(patched50.1, 0, msg="an in-place edit made \{patched50.1} nodes")
  assert_eq(patched50.2, 0, msg="an in-place edit let go \{patched50.2} nodes")
}

///|
test "an in-place edit to a chat's last message reads that message alone again: the rest of the chat's view as it was" {
  @sfbase.reset()
  reset()
  let chat = @signals.signal(scale_chat(50))
  let src : Source = {
    ..@sfbase.made_source(),
    topic_read: fn(name, _) {
      if name == "chat" {
        { value: Some(chat.get()), error: None, version: 1 }
      } else {
        { value: None, error: None, version: 0 }
      }
    },
  }
  let read = @signals.computed(fn(_) { @sfbase.view_of_chat(src, scale_ref) })
  let watch = @signals.watch(fn() {  })
  let (v0, list0, _) = watch.read(fn() { read.get() })
  guard v0 is Some(v0) else { fail("no view") }
  chat.set(
    @core.apply_delta(chat.get(), [
      Json::object({
        "path": Json::array([Json::string("messages")]),
        "key": Json::array([Json::string("seq"), Json::string("outgoing")]),
        "patch": scale_key(50),
        "ops": Json::array([
          Json::object({ "path": Json::array([Json::string("text")]), "set": Json::string(scale_patched) }),
          Json::object({ "path": Json::array([Json::string("md")]), "set": body_md(scale_patched) }),
        ]),
      }),
    ]),
  )
  let (v1, list1, _) = watch.read(fn() { read.get() })
  watch.stop()
  guard v1 is Some(v1) else { fail("no view after") }
  assert_eq(v1.messages.length(), 50)
  assert_eq(v1.messages[49].text, scale_patched)
  for i in 0..<49 {
    assert_true(physical_equal(v1.messages[i], v0.messages[i]), msg="message \{i} read again")
  }
  assert_true(physical_equal(v1.people, v0.people) && physical_equal(v1.agents, v0.agents), msg="people, agents read again")
  assert_eq(list1.length(), list0.length())
  for i, e in list1 {
    match (e, list0[i]) {
      (Said(a), Said(b)) if a.seq == 50.0 => assert_true(!physical_equal(a, b) && a.text == scale_patched)
      (Said(a), Said(b)) => assert_true(physical_equal(a, b), msg="entry \{i} made again")
      _ => ()
    }
  }
}
